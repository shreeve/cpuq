# cpuq design

How cpuq works inside. The [README](../README.md) says how to use it; this file says how each
decision is made, for anyone changing the code or wondering why a job waited. The words below
are the code's own: a waiter holds a *ticket*, a running job holds a *lease* and *tokens*, and
the waiter at the front of the queue is the *head*.

## No daemon

Every hold is a `flock(2)` on a file in a state directory, so the kernel releases it when the
last process holding the descriptor exits, however it exits. Only `flock(2)` is used, never
fcntl locks: an flock belongs to the open file description, survives fork and exec, and is not
dropped when some other descriptor of the file closes.

## The state directory

`CPUQ_DIR`, else `/tmp/cpuq-UID` with `/tmp` resolved (`/private/tmp` on macOS): a literal path,
so every session of one user agrees on it whatever its `TMPDIR`. If it cannot be created or
written, cpuq fails; it never falls back to another directory.

    admission.lock      the admission lock; scans, grants and probes happen under it
    seq                 the last ticket number handed out
    valve               the load valve's state
    usage               each running job's measured use, carried from one head to the next
    window-ended        when the last exclusive run ended (for window_gap)
    control-TICKET      an order for a waiter from `cpuq first`, `start` or `cancel`
    paused-LEASE        a job paused by hand (empty), or frozen by the timing window it names
    lending             the timing window lending the machine now (window_lend)
    queue/P-NNNNNNNNNN  one ticket per waiter (P: 0 high, 1 normal, 2 low)
    tokens/NNNN         one file per core handed out; an exclusive lock is a held core
    leases/NNNNNNNNNN   one record per running job (suffix .x: an exclusive run)
    named/NAME/         a named lease: a state directory of its own, one token per slot

There are as many token files as the most cores ever handed out at once: the machine's CPUs,
the budget, or under measured admission up to four times `target`. Token files are never
removed. The history file lives elsewhere (see the README), outside `/tmp`, so it outlives a
reboot.

## The queue

A waiter creates its ticket under a temporary name, locks it exclusively, writes its record and
renames it into place, all under the admission lock, and holds that lock while it waits.
Waiters are ordered by `cpuq first` (moved waiters go ahead of the rest), then class (priority
after aging), then ticket number.

A waiter that is not the head blocks on the ticket just ahead of it: a blocking shared flock
that returns when that waiter is admitted or dies, so a long queue costs nothing. The head polls
every `poll` seconds: under the admission lock it reads the gates and, if they are open, tries
to take its tokens, all of them or none (on failure it releases what it took). Every grant is
all or nothing under the admission lock, so two waiters can never each hold part of what they
need.

The first eight waiters, the head included, also look every 2 seconds: for a hand-given order
(`cpuq first`, `start`, `cancel`, left as `control-TICKET`) and for room to start ahead of the
head. The rest wake when the waiter ahead of them leaves, or at their next once-a-minute note.

## Measured admission (`admit = measured`)

The tokens still number the cores handed out (for `CPUQ_CORES`, the jobserver and the app), but
their pool is only a sanity cap: four times `target`, at least 4. What counts against the
machine is each running job's measured demand.

**What a running job counts for.** Each head that needs to decide measures every running job's
command tree: its CPU time between looks, smoothed with a time constant of half of `settle`
(about ten seconds by default), kept in `usage` so the next head carries on. For its first
`settle` seconds (20) a job counts at its expected use: the 75th percentile of its label's last
64 finished runs' average active cores, at most what it holds, or all it holds when the label
has fewer than three runs. After that it counts at what it is measured asking of the CPUs,
however little, never under a twentieth of a CPU.

Demand is the CPU time a job gets. While the CPUs are at least 90% busy it is the larger of
that and the threads it has ready to run (at most twice what it holds), so a job that a
contended machine slows still counts in full. With CPUs idle, ready threads are waiting on
something else (a pool of workers, a burst of short processes) and do not count. A job paused
by hand counts for nothing. While an exclusive run holds the machine nothing is measured and
nothing is admitted.

**The head** starts when the running jobs count for nothing (none run, or all are paused), or
when its own expected use fits in the room (`target` less what the running jobs count for) and
the CPUs are not measured 97% busy or more. The machine gates apply; the load valve only to an
exclusive run.

**Behind the head**, a waiter starts at once, while there is no memory pressure, when its
expected use fits the room and either the head's expected use still fits after it, or the head
has waited less than `patience` seconds. Behind an exclusive head, only backfill (below) lets
anything start.

**The grant.** A fixed `--cores K` stands. A range is capped near the label's use, as
right-sizing does (75th percentile plus 0.3, rounded, never below its minimum), and then gives
way to the room there is, down to its minimum. With no `--cores`, a label with three or more
finished runs gets 1 up to its 75th percentile plus 0.3, rounded, at most half the machine's
CPUs, as room allows; any other gets 2.

## Reservation mode (`admit = cores`)

Each job counts at the cores it holds, against the budget.

**The admission rule.** Once the head's minimum fits beside the cores held, it takes up to its
maximum of what is free, but leaves the next waiter's minimum free when it can still get its
own, so a wide request does not stall the job behind it. Lowering the budget below what is held
only stops admissions.

**Right-sizing.** A grant is fixed for the whole run, so a range that takes everything free
wastes cores whenever the job uses fewer. Once a label has three finished runs, `--cores
MIN-MAX` takes at most the 75th percentile of their average active cores plus 0.3, rounded,
never below MIN: a test that keeps 0.8 of a core busy and asks for `1-4` gets 1, a build that
uses 3.5 keeps `1-4`. It says so when it caps. `right_size = off` turns it off.

**Backfill.** Cores the head cannot use yet need not sit idle. A waiter behind it may start at
once, taking what is free up to its maximum, when its minimum fits, nobody ahead of it may go
first (the head if it fits, or an earlier waiter backfill would also let go), and either:

- history knows both run times, and the waiter's typical run ends before the head is expected
  to start, so the head loses nothing; or
- history cannot say, and the head has waited less than its patience: half its own typical run,
  from `patience` seconds (30) to 5 minutes. After that nothing goes ahead, and cores that free
  up are kept for the head.

A wrong estimate delays the head by at most one job's overrun, and patience bounds how long
others may go ahead, so the head never starves. Behind an exclusive head (in either mode) only
the first rule applies: a job goes ahead only when history says it ends before the running work
does. Named leases stay strictly in order. A job that went ahead says so and is marked
`"ahead": true` in history. `backfill = off` keeps strict order. A head waiting for an exact
count while fewer cores are free says once that a range would start it now.

**Lending.** A job that holds cores it does not use keeps others waiting for nothing. A head
that cannot start measures each running job's command tree, averaged over half of `lend_after`
seconds. Cores a job has left wholly idle for `lend_after` (60) are lent to the head on top of
the budget: a job holding 3 cores and keeping 1 busy for a minute lends 1 (a quarter of a core
is kept as slack). Only idle cores are lent, so the work running stays within the budget, and
nothing is taken from the lender; if it gets busy again the machine runs over the budget until
someone finishes, and the load valve holds further admissions meanwhile. Lending goes only into
CPUs the machine has to spare, judged by the load and the CPUs' measured busy share, so it never
pushes the load past the CPU count. A job paused by hand lends all its cores at once. Nothing is
lent to an exclusive run or a named lease.

A job started on lent cores says so, and history marks how many (`"lent": N`). On Linux it runs
at nice 15, so a lender that gets busy again has its CPUs back at once. On macOS it keeps its
class: background QoS would hold it to Apple silicon's efficiency cores, with throttled I/O, for
its whole run.

## The machine gates

The head admits nothing while one of these is closed:

- **Memory pressure.** macOS `kern.memorystatus_vm_pressure_level` at 4 (critical). The warn
  level (2) can last many minutes with half the memory free, so it does not count; a runaway
  job is `max_memory`'s to stop. Linux `/proc/pressure/memory` `some avg10` at `pressure_psi` or
  more, when the file exists. `pressure_check = off` turns it off.
- **Low memory.** With `min_available` set, available memory under it: Linux `MemAvailable`,
  macOS the kernel's free share (`kern.memorystatus_level`) of `hw.memsize`.
- **The load valve** (`load_check`, or `--no-load-check` per run). Under measured admission it
  gates exclusive runs only; under `admit = cores`, every job. It reads the machine's whole
  1-minute load, cpuq's own jobs included, so it catches load from outside cpuq and jobs that use
  more CPUs than they were granted alike. It trips when the load exceeds budget + `load_margin`
  and the CPUs are measured at least 90% busy (the load average counts threads and lags a
  minute, so a high load with CPUs to spare does not trip it). It reopens as soon as the CPUs
  fall below 75% busy, or once the load has stayed at or under budget + `load_margin`/2 (10 for
  a budget of 8) for 15 seconds. While the load is above the budget it admits at most one job
  per 10 seconds (`spacing`), so waiters never stampede into a lagging average. A tripped valve
  nobody has checked for over a minute reopens at once when the load is at or under that level,
  since the 1-minute average already covers that calm.

The budget is capped by the cores active now (macOS `hw.activecpu`, Linux the process's CPU
affinity). On Apple silicon `hw.activecpu` does not appear to drop under thermal throttling, so
this cap is a safeguard, not a thermal signal.

## Exclusive runs

An exclusive run waits, at its turn, until no core is held, then takes the budget's worth of
cores. While it holds them nothing is admitted. `start` never starts a job into one, and pause,
resume and stop leave one alone. A run opens beside jobs paused by hand (their processes are
stopped, so the window stays quiet), and one started by hand opens at once on the cores that are
free, beside those still held. Neither counts those cores as lent.

`cpuq lease NAME --exclusive` takes NAME first, then the machine's cores, so two holders never
wait on each other. Its claim on the cores queues at the front, as `cpuq first` would put it.
A `cpuq run` on the same machine whose `CPUQ_LEASES` names that lease's holder runs inside the
window at once, with `CPUQ_CORES` set to its maximum request.

With `window_gap` set, for that many seconds after an exclusive run ends (`window-ended`) the
exclusive waiters are served after every other waiter.

## Noise and lending in a timing window

A timing window's cpuq looks at every process while the window runs: the one running a command
in its 2-second checks (the same look that tracks peak memory), a `--hold` window every 5 seconds
(every second while it lends). Everything but the window's own work counts as noise: its CPU over
each interval, summed, gives the peak and the mean that go into history, and the programs that
used the most. A process that appeared since the last look counts in full; one that came and went
between looks is missed.

`window_lend` applies to a window held with no command (`--hold --exclusive`): the remote end of
a kit's lease. Its owner's work arrives over ssh outside any cpuq, so the owner is taken to be
this user's processes that started after the window opened, less the jobs it lent to
(`CPUQ_WINDOW_OWNER` names a process tree instead). Lending writes `lending` (the window's lease
name); `measuredLoad` then counts the window for nothing and admits as usual. When the owner works
again the window removes `lending` and freezes every ordinary job: it writes `paused-LEASE` with
its own name, then SIGSTOPs each job's tree. A frozen job's own cpuq keeps its tree stopped in its
2-second checks (a child started as it froze), and thaws itself when the window lends again or
is no longer held, so a window killed outright leaves nothing stopped. A clean end thaws them all
at once. A hand `cpuq pause` overwrites the marker as a hand pause, which only `cpuq resume`
ends.

cpuq has no separate hold command: a window is always tied to a running process. A hold not
tied to one would need a file that outlives its owner, which is the thing cpuq exists to avoid.

## Holds

A job's tokens and its lease are exclusively flocked, and the command inherits those
descriptors (they are not close-on-exec; every other descriptor is). If cpuq itself is
SIGKILLed, the command and its children keep the cores until they exit; `cpuq status` shows such
a job with its holder gone (`*`). When the command exits, cpuq unlocks every token (`LOCK_UN`
releases the lock for every process sharing the descriptor) before closing it, so a descendant
that kept a descriptor (a build server, a `nohup`'d helper) does not keep the cores.

**Dead files.** Any file whose lock can be taken has no holder. Probes take a shared lock, and
only under the admission lock, so a probe never makes a free token look busy to the head; a dead
ticket or lease found this way is removed (after checking that the path still names the probed
inode). Nothing depends on pids: they are recorded for `cpuq status` only.

**Kill and reboot.** A SIGKILLed waiter's ticket lock is released by the kernel: the waiter
behind it wakes at once, and the dead ticket is removed by the next scan. A SIGKILLed job (cpuq
and its command) releases its tokens the moment the last process holding them exits. A reboot
releases everything; the leftover files are dead and are cleaned as they are found.

## Named leases over ssh

`cpuq lease NAME --host HOST` starts `ssh HOST cpuq lease NAME --hold` (with `BatchMode=yes`
and server keepalives), waits for its `held` line, runs CMD here, then closes the connection,
which gives the lease back. If cpuq is killed or the connection drops, the far side's cpuq dies
with its session and HOST's kernel frees the lease. The connection carries a heartbeat, a
newline every 10 seconds; once heartbeats have come, a hold that hears none for
`CPUQ_HOLD_QUIET` seconds (60) ends, waiting or held, so a connection that drops without closing
(the network gone, a laptop asleep) does not hold HOST for nobody.

`CPUQ_LEASES` entries are `NAME=ID` for a lease held here and `NAME@HOST=ID:PID` for one held on
HOST by the local cpuq PID. A local entry counts while its lease file is still held here; a
remote one while that local cpuq lives.

## Signals

While the command runs, cpuq forwards HUP, INT, QUIT, TERM, USR1 and USR2 that a process sends
it (`kill -INT <cpuq>` reaches the command). While cpuq is in its terminal's foreground, INT and
QUIT are always the terminal's (`^C`, `^\`), as is any signal with no sending pid (`si_pid` 0,
the terminal driver's hangup): the terminal already sent them to the whole foreground process
group, the command included, so cpuq does not send them again (as with `system(3)`). macOS can
name the process that wrote a keystroke to a pseudo-terminal as the sender of `^C`, so INT and
QUIT are not judged by their sender. Elsewhere a signal with no sending pid is still forwarded:
macOS records a sender only for a signal that can be taken at once, so a kill that lands while
cpuq is handling the same signal arrives without one. A process that signals the whole process
group (`kill -INT -PGID`) has a pid, so the command receives such a signal twice.

A signal cpuq was started with ignored (`nohup`, a `&` job in a script) is left ignored, so the
command inherits it ignored. When the command dies by a signal, cpuq dies by the same signal
(without a core dump), so the caller's shell sees 128+N and a `^C` stops a shell loop.

## The GNU make jobserver

CMD gets a pipe holding K-1 tokens whose descriptors it inherits, and MAKEFLAGS with
` -j --jobserver-auth=R,W --jobserver-fds=R,W`, the form GNU make hands its own sub-makes (make
4.2 and later read `--jobserver-auth`, macOS's `/usr/bin/make` 3.81 reads `--jobserver-fds`).
The caller's other MAKEFLAGS are kept; their `-j` and jobserver options are replaced. So `make`
under `cpuq run --cores 3` runs at most 3 recipes at once, with GNU make 3.81 and 4.4 alike, and
so does `make -j` with 3.81. GNU make 4.x lets a `-j` on its own command line override any
jobserver (it warns "-jN forced in submake"): `make -jN` then runs N at once, and a bare
`make -j` is unlimited. A nested run leaves MAKEFLAGS as it is.

## Measuring

**Cores active** in `cpuq status` is the CPU time a command's whole process tree spends over
half a second, the short-lived processes it starts and reaps included. The same sample rates
every other process: the five busiest outside every cpuq job (each at 0.3 of a CPU or more) are
shown when together they use a CPU or more, or a gate is closed.

**ETA.** A waiter's ETA plays the queue forward: running jobs free their cores at their label's
typical end (the median run of its finished jobs, or its project's when the label is new), and
each waiter, in order, starts once its minimum fits the budget and then holds it for its own
typical run. An unknown run time ahead of a waiter leaves its ETA unknown (`?`).

**History.** Each job appends `queued`, `started`, then `ended` or `gave_up` lines to the history
file; a line under 4 KB written with `O_APPEND` lands whole, so no lock is needed. A job armed to
die writes its last line from the signal handler. A job with neither `ended` nor `gave_up` whose
cpuq is gone, or which queued before the machine last booted, is `lost`. A `--hold` lease killed
while held ends by that signal; one whose stdin closed first ends with status 0. A job's *active
cores* is its CPU time (from the kernel's `wait4`) over its run time.

**Memory.** Each running job's cpuq looks every 2 seconds at the memory its command and the
command's descendants use together (macOS's physical footprint, compressed pages included, as
Activity Monitor shows it; Linux's resident set) and records the most in history; a job too
quick to look at gets the most any one of its processes held. With `max_memory` set, over the
limit, it asks the whole tree to stop (SIGTERM), makes it (SIGKILL) 10 seconds later if any of it
remains, says so, and records the job as stopped for its memory (`memory` in `history --json`,
"memory 42.0G" in `cpuq history`). One job that balloons would otherwise fill the swap and shut
the memory gate on everyone.

## Scheduling class

On macOS, high and normal leave the command's QoS class unchanged and low runs it at background
QoS (`posix_spawnattr_set_qos_class_np`): on Apple silicon background work stays on the
efficiency cores, with throttled I/O. Utility QoS for normal would keep work mostly on the
efficiency cores too, and leave the performance cores idle. On Linux, where cores are alike,
high, normal and low run at nice 0, 5 and 15. Children inherit the class. Exclusive runs (they
time benchmarks), named leases and `--qos none` leave it unchanged.
