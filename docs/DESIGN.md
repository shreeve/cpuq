# cpuq design

How cpuq works inside. The [README](../README.md) says how to use it; this file says how each
decision is made, for anyone changing the code or wondering why a run waited. The words below are
the code's own: a `cpuq run` is an *operation* (its record is an `Op`), each pool CPU has a
*token*, a CPU held by an operation is a *slot* with K *places*, a CPU promised to a waiting
operation is a *promise* (a grant file), and an operation emptying a CPU for the line is
*draining* it.

## No daemon

Nothing hands out, holds or decides for `cpuq run` but the `cpuq` processes of the operations
themselves. The optional recorder (`cpuq record`) only samples: no command waits on it or needs
it, so a machine without one works the same, and one that dies takes nothing with it. Jobs of
task files (`cpuq jobs`) have an optional agent of their own (below): without it each runs at the
workers it was given.

Every hold is a `flock(2)` on a file in a state directory, so the kernel releases it when the
last process holding the descriptor exits, however it exits. Only `flock(2)` is used, never
fcntl locks: an flock belongs to the open file description, survives fork and exec, and is not
dropped when some other descriptor of the file closes.

## The state directory

`CPUQ_DIR`, else `/tmp/cpuq-UID` with `/tmp` resolved (`/private/tmp` on macOS): a literal path,
so every session of one user agrees on it whatever its `TMPDIR`. If it cannot be created or
written, cpuq fails; it never falls back to another directory.

The pool lives under a versioned folder, `v2/`, so a cpuq of another version never reads these
files as its own, and an old and a new cpuq never hand out the same CPU (src/pool.zig):

    v2/lock             the pool's lock: every scan, take, promise and release happens under it
    v2/seq              the last ticket number handed out
    v2/ops/C-TICKET     one per running operation, exclusively locked by its cpuq for its whole
                        life (C: 0 urgent, 1 normal); its text is the operation's record
    v2/wake/TICKET      the operation's FIFO: whoever promises it a CPU writes a byte there
    v2/cpus/N           one per pool CPU, named by the CPU's number; an exclusive lock is a
                        held CPU; its text names the task groups running on it
    v2/grants/N         a promise of CPU N to one operation: its ticket
    v2/drain            locked while `cpuq drain` waits for or holds the machine
    v2/ticks            the last sample of the machine's CPU ticks, for the outside-load gate
    named/NAME/         a named lease: a queue of its own (src/state.zig)
    scopes-ok           whether systemd user scopes work here, probed at most every 10 min

An operation's record is `key=value` lines: `pid`, `urgent`, `drain`, `project`, `label`,
`weight`, `want` (CPUs it could use now beyond those it holds), `held` (its CPUs, by number),
`draining` (how many of those it is emptying), `overload` (`-x`), `limit` (`-c`, worked out),
`tasks`, `done`, `failed`, `running`, `since`, `why` (what holds it back, for status) and `cmd`.
Records are written in place and read only under the pool's lock, as they are written, so no
reader sees one half written.

**Dead files.** A file whose lock can be taken has no live holder: whoever finds it so, under the
pool's lock, removes it (an operation's record and FIFO), or treats it as free (a token). A
promise is valid only while its operation's record is locked and its CPU is in the pool; any other
is removed by the next scan. So a waiter killed mid-promise strands nothing. Nothing depends on a
pid being alive except killing a dead operation's leftover processes, and that checks each group
leader's start time first.

The history file lives elsewhere (see the README), outside `/tmp`, so it outlives a reboot.

## The pool

The pool's CPUs, and their order, come from src/cpus.zig, which every cpuq on the machine works
out the same way: the config's `cpus` list; else on Linux the CPUs online, less those in
`/sys/devices/system/cpu/isolated`, within pid 1's `Cpus_allowed_list` (a container's CPU set),
the lowest thread of each core first, then their siblings; else 0 to the active count less one
(macOS, which can't pin, so the numbers only name places). `budget` or `CPUQ_BUDGET` keeps the
first N.

A token is held by its operation's cpuq alone. The descriptor is close-on-exec, so no task, and
nothing a task leaves behind, holds a CPU. Taking a token (`Pool.take`) is a non-blocking
exclusive flock under the pool's lock; it first ends what a dead holder left running there
(below), then empties the token's text. Giving it back clears the text, unlocks and closes it.

## An operation's loop

One process per operation, its cpuq, holds the CPUs and starts the tasks (src/op.zig). It holds
no CPU itself, and it never sleeps while a held CPU has an empty place and a task is waiting.
Each turn:

1. **Reap** every ended task: record its outcome, or queue it for a retry (`-r`); free its place.
   For a run of many tasks, kill whatever the task left in its process group.
2. **Signals and time limits:** pass a TERM, INT, HUP or QUIT to every task group; TERM a task at
   its limit and KILL it 5 s later; KILL what is left 5 s after a signal.
3. **Ctrl-Z**, if one came (below).
4. **Consolidate:** move tasks from a draining CPU into free places on its other CPUs (below).
5. **Continue stopped tasks** that have a place again.
6. **Place** waiting tasks (retries behind the tasks not yet started) into free places of held, non-draining CPUs, the
   fullest first, so CPUs fill to K before another is used and empty ones can go back.
7. **Give back** each held CPU that is empty and has nothing coming (no task waits, or it is
   draining). Giving any back renews the operation's ticket and hands the CPUs to the line, under
   the lock.
8. **Settle**, under the lock, when something happened here (a task ended, a signal or a promise
   came, a CPU went back) or on its timer: every second for the head of the line, which catches
   CPUs freed without a word (a SIGKILLed holder) and gates that reopen, every 10 s for the
   rest. Write the record; scan the operations and promises; hand every free
   CPU to the line (`handOut`), writing promises and waking their operations; take each CPU
   promised to this operation that it still wants, and drop the rest; if it took none and it is
   the line's giver (`giver`), mark one of its CPUs draining; if a drain waits, mark all of them.
9. **Sleep** in `poll()` on its self-pipe (SIGCHLD and the stop and terminal signals write a byte)
   and its wake FIFO, for at most a second, or until the next time limit is due. A long line
   costs little: a waiter wakes for its promise, not to look.

The record's `want` is what the line reads: the tasks waiting (stopped ones included) less the
free places on CPUs it keeps, divided by K and rounded up, at most `limit` less the CPUs held.
A stopped operation wants nothing.

`limit` is `-c` worked out against the pool when the run starts (a percentage of the pool, at
least 1), at most the pool, and at most the tasks ÷ K rounded up, so a run never holds more CPUs
than it has tasks for.

A run of one task (`cpuq run -- CMD`) starts its task in cpuq's own process group, with the
terminal, and its exit status, signal or 124 is cpuq's. A run of many (`-n M`) starts each task as
the leader of a group of its own, with stdin `/dev/null` and stdout and stderr to
`~/.local/state/cpuq/runs/PROJECT/STAMP-PID/N` (`N.ATTEMPT` for a retry), and ends with a summary
and exit 0 or 1.

## Promises and wake FIFOs

Whoever frees a CPU, or finds one free, hands it out at once: `handOut` decides, and for each CPU
it writes `grants/N` by rename (never seen half written) and writes a byte to the promised
operation's FIFO. An operation opens its FIFO, read and write and non-blocking, before it first
looks for a CPU, so a promise made after that look always finds it open, and a wake never blocks
its writer (a full FIFO already holds a wake). The promised operation takes the CPU in its next
settle. A CPU promised to an operation that no longer wants it is dropped, and the next hand-out
gives it to the next in line.

While CPUs are free the 1-second poll timeout is the fallback: any operation's settle hands out
what a crash freed without a hand-out.

## The line

`ahead(x, y)` in src/pool.zig decides who gets the next CPU. Each operation's *has* is the CPUs it
keeps (held less draining) plus those promised to it; a project's count is the sum of its
operations'. In order:

1. **Urgent:** an urgent operation that has nothing, while its project holds no urgent CPU, goes
   first. So urgency is for an operation's first CPU, one per project at a time.
2. **Holding nothing:** an operation with nothing goes before every operation with something, so
   it can't starve behind a head nobody may give to.
3. **The project's share:** the lower project count ÷ weight (compared without division).
4. **The operation's share:** the lower *has*.
5. **The ticket:** the lower first.

`handOut` gives free CPUs, in the pool's order, one at a time, counting each promise as held at
once and ranking the line again before the next, so free CPUs spread over projects by weight.
Only operations with `want` left are in the line. While a drain is in the line, every CPU goes to
it. `firstWaiter` is the head of the same order once every promise is counted.

An operation's ticket is renewed (its record and FIFO renamed, under the lock) each time it gives
a CPU back, so it takes its turn behind every other: runs that hold one CPU each take turns with
a newcomer.

## Giving CPUs back

No operation ever stops a task to give its CPU away. When the head of the line wants a CPU and
none is free, `giver` names at most one operation to empty one CPU, and each operation checks, in
its settle, whether that is itself:

- **Drains owed:** the CPUs being emptied, summed over every operation's `draining`, under the
  lock. While they are as many as the head still wants, nobody else drains, so twelve operations
  don't all empty a CPU for one waiter. A draining CPU counts as given up already (it isn't in
  *has*). There is no separate count to drift: a dead operation's drains vanish with its record.
- **The share rule:** a giver qualifies when the head holds nothing, or when after the move the
  head's project still holds no more than the giver's for their weights:
  (head's + 1) × giver's weight ≤ (giver's − 1) × head's weight.
- **Guard 1, holding nothing first:** the line's second key means a head that holds nothing is
  head, and the share rule lets anyone give to it.
- **Guard 2, the waiter must stay ahead:** a giver qualifies only if the head still goes ahead of
  it once it holds one fewer and has its renewed ticket, the newest (`behindAfter`). Without this,
  a giver holding nothing, or urgent, would rank first again and take the freed CPU straight back.
- **Which giver:** of those that qualify, the operation whose project holds the most for its
  weight, then the one keeping the most, then the newest ticket. A drain (`cpuq drain`) never
  gives; while it waits, every operation drains every CPU.
- **Which CPU:** an empty one, else the one with the fewest tasks, then the one whose newest task
  started longest ago (`drainOne`).

A draining CPU gets no new task. When its last task ends, the operation gives it back (step 7 of
the loop), renews its ticket, and hands it out; the head, being first, gets it.

**Consolidation.** While a CPU drains, a free place on another of the operation's CPUs takes the
draining CPU's newest task, the one likely to run longest. On Linux every thread of that task's
processes is re-pinned there (`sched_setaffinity` per thread); on macOS only the counts move. The
draining CPU frees sooner, and half-empty CPUs are rare.

## Outside load

`Pool.machineBusy` reads the kernel's CPU ticks (busy and total, every CPU) and keeps one sample in
`v2/ticks`, renewed once it is a second old, so every operation shares one measure over the last
second or so. In `freeCpus`, the CPUs handed out are cut to

    room = floor(active CPUs − max(busy, CPUs held) + 0.25)

so a CPU goes out only when one is idle. Held CPUs count as busy even when idle, so a burst of
task starts never looks like room; busy beyond the CPUs held is work cpuq doesn't run, or tasks
using more than their CPU (which macOS can't stop). It never reads the load average, which counts
threads, so `-x` overload would trip it, and lags a minute. With no room, the operation's `why`
says `outside load`.

## The gates

Before handing out any CPU, `freeCpus` reads the machine gates (src/policy.zig `gate`); while one
is closed nothing is handed out, and `why` says which. Runs keep the CPUs they hold, and keep
filling them.

- **Memory pressure.** macOS `kern.memorystatus_vm_pressure_level` at 4 (critical). The warn
  level (2) can last many minutes with half the memory free, so it does not count; a runaway task
  is `cpuq cap --mem`'s to stop. Linux `/proc/pressure/memory` `some avg10` at `pressure_psi` or
  more, when the file exists. `pressure_check = off` turns it off.
- **Low memory.** With `min_available` set, available memory under it: Linux `MemAvailable`,
  macOS the kernel's free share (`kern.memorystatus_level`) of `hw.memsize`.
- **Low disk.** Less than `min_disk` (5G by default) free to an ordinary user (`f_bavail`) on the
  filesystem holding `$HOME`, the one holding the state directory (the temp directory where
  builds and agents keep scratch files), or `~/cpuq`, where jobs sent here keep their copies and
  caches, which a host may give its own filesystem (burst's is a ZFS dataset with a quota); status
  names the fullest. It is on by default because a full disk breaks everything at once: on
  2026-10-11 one session's scratch copies of a database filled this Mac's disk to its last byte,
  and every session's builds and tool calls failed. It cannot stop a running task from filling the
  disk; it keeps new ones from piling on.

## Nesting

A `cpuq run` inside a task runs on that task's CPU, with no line (`nestedCpu`): when `CPUQ_CPU`
and `CPUQ_OP` are set and `CPUQ_OP` names a live operation, or else when one of this process's
ancestors (up to 64 hops, by parent pid) is a live operation's cpuq, which no `env -i` can hide.
The environment is only the fast path. One task execs the command in cpuq's place; `-n M` starts
M tasks `-x` at a time, with the terminal, and exits 0 or 1. `-c`, `-t`, `-r` and `--urgent` don't
apply there.

## Parent death

Every task is started with `PR_SET_PDEATHSIG` = SIGKILL on Linux, so it dies with its operation's
cpuq however that dies (a check after the call covers a parent that died first). That reaches the
task's own process; what it started may outlive it, and on macOS nothing reaches the task at all.

So each held CPU's token names the task groups running on it, one `PGID START` line each (the
group leader's start time, from the kernel), rewritten whenever a task starts, ends or moves.
When an operation dies, the kernel drops its flocks and its CPUs are free at once. Whoever takes
such a CPU next reads the token first and SIGKILLs each group whose leader still runs with the
same start time (a pgid alone may name someone else's group by now). So a CPU is never shared
with an orphan. A dead operation's history reads `lost`.

## Ctrl-Z

cpuq takes SIGTSTP (unless it was started with it ignored). It SIGSTOPs every task, gives back
every CPU, marks itself stopped (its record wants nothing, so the line passes it by), drops every
promise made to it, hands the freed CPUs to the line, and then stops itself with SIGSTOP (a TSTP
to a process outside job control, an agent's shell, would be dropped). Continued, it stops the
tasks again (a shell continues the whole job's group, and a single task shares cpuq's), adds the
time stopped to each task's start so it doesn't count against its limit, and the loop asks the
line for CPUs again: each stopped task gets a place, is re-pinned there on Linux, and gets SIGCONT.

## cpuq drain

`cpuq drain` is an operation with `drain` and `urgent` set, `want` the whole pool while its
command hasn't started, and no time limit. It holds `v2/drain` locked for its life. While it is
in the line every CPU handed out goes to it (`handOut`), and every other operation, seeing
`v2/drain` held, marks all its CPUs draining: it starts nothing new and gives each CPU back as its
tasks end. Once the drain holds every pool CPU its command runs, unpinned, and the CPUs go back
when it ends. `--max` gives up (exit 75) while it holds less than the pool.

## cpuq kill

`cpuq kill` finds the operation by ticket, its cpuq's pid or its label (several matches: it lists
them and does nothing) and sends its cpuq SIGTERM. A run of many tasks passes it to every task
group and kills what is left 5 seconds later; a run of one forwards it to its command. Its tasks
are recorded as stopped, not failed, and never retried.

## --driver

A `--driver` run holds no CPU and has no record in the pool: it runs its command with the
terminal, `CPUQ_CPU` and `CPUQ_OP` removed so the runs it starts aren't nested, and its exit
status or signal is cpuq's. On Linux with `cgroups` it runs as

    systemd-run --user --scope --quiet --collect --expand-environment=no
        --property=Delegate=yes --property=OOMPolicy=continue
        --unit=cpuq-driver-PID -- cpuq _job -- CMD...

- **The pid:** systemd-run moves itself into the new scope and execs; `cpuq _job` then moves itself
  into the scope's `job/`, enables `+memory +pids` for the scope's children (allowed only once the
  scope's own cgroup holds no process), exports the scope as `CPUQ_CGROUP`, and execs CMD. So the
  pid cpuq tracks stays the command's.
- **`--expand-environment=no`:** systemd 254 and later expand `$VAR` and `${VAR}` in the command
  line themselves, before CMD's shell sees it: `sh -c 'echo ${x%/job}'` failed with "Invalid
  environment variable name". The flag stops that. Older systemd, which lacks it, didn't expand.
- **Probing:** whether scopes work, and with which flag, is probed once and kept in `scopes-ok`
  for ten minutes (a failure for one). Without them, or off Linux, CMD starts as it is.
- **`OOMPolicy=continue`:** a capped program's cgroup running out of memory is that program's end,
  not the runner's.
- **The end:** when the runner exits, whatever it left in the scope is killed (`cgroup.kill`).

## Named leases

A named lease (`cpuq lease NAME`) is a queue of its own under `named/NAME/`, older than the pool
and unchanged by it: `--slots` token files, one ticket per waiter (exclusively locked while it
waits), one record per holder, strictly first come first served, no gates. A waiter that is not
the head blocks on the ticket just ahead of it; the head takes a free slot under the lease's lock.
A lease holds no CPU.

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

A run of one task forwards HUP, INT, QUIT, TERM, USR1 and USR2 that a process sends cpuq to its
command (`kill -INT <cpuq>` reaches it). While cpuq is in its terminal's foreground, INT and QUIT
are always the terminal's (`^C`, `^\`), as is any signal with no sending pid (`si_pid` 0, the
terminal driver's hangup): the terminal already sent them to the whole foreground process group,
the command included, so cpuq does not send them again (as with `system(3)`). macOS can name the
process that wrote a keystroke to a pseudo-terminal as the sender of `^C`, so INT and QUIT are not
judged by their sender. Elsewhere a signal with no sending pid is still forwarded: macOS records a
sender only for a signal that can be taken at once, so a kill that lands while cpuq is handling
the same signal arrives without one.

A run of many tasks takes INT, TERM, HUP and QUIT itself (each task leads its own group, out of
the terminal's reach), passes the signal to every task group, and kills what is left 5 seconds
later.

A signal cpuq was started with ignored (`nohup`, a `&` job in a script) is left ignored, so the
command inherits it ignored. When the command dies by a signal, cpuq dies by the same signal
(without a core dump), so the caller's shell sees 128+N and a `^C` stops a shell loop.

## Status and history

**Status** (src/status.zig) reads the pool under its lock: the operations, the promises, the free
CPUs and whether a drain waits. Its sample (skipped with `--no-usage`) watches every process and
the machine's CPU ticks for half a second: each operation's tasks' CPU is its cpuq's process tree's
CPU time over the sample, less cpuq's own, with tasks reaped meanwhile counted through cpuq's
children time; processes outside every operation's tree at 0.3 of a CPU or more are outside work.
The line's order is `handOut` played one CPU at a time; a waiter's place is where it first gets
one, and its `why` says what holds it (a gate, outside load, a CPU being emptied for it, its place
in line). A run's time left comes from its tasks ended so far; the next CPU to free, from the
operations giving CPUs back and their mean task time. A project's fair share is water-filled by
weight over each project's demand (held plus wanted). Flags come only after a run's first five
seconds, and only when measured: under half a CPU busy per CPU held, over 1.2, stopped.

**History.** Each operation appends `queued` when it enters the line, then at its end `started`
(dated at its first task's start) and `ended`, or `gave_up` for `--wait-max`. The end line holds
the most CPUs it held at once, its tasks' CPU time (`wait4`'s figures summed over every child),
tasks done and failed, and its exit status or signal. A line under 4 KB written with `O_APPEND`
lands whole, so no lock is needed. An operation with neither `ended` nor `gave_up` whose cpuq is
gone, or which queued before the machine last booted, is `lost`.

## What the Lean model checks

A Lean 4 model of the protocol lives in `formal/` on the `lean-model` worktree. It models the
protocol, not the Zig code: one step function over finite state (each CPU's flock holder, promise
and record; each operation's phase and tasks; the tickets; the drain count), with the rules of
src/pool.zig and the loop of src/op.zig as one of its rule sets (`Rules.poolFixed`, the code at
8f997ec).

- **Proved, safety,** in every reachable state, crashes, kills and stops included: one holder per
  token, and a held token has no promise; never more CPUs held than the pool; never more than C
  CPUs per operation, promises included; never more than K processes per CPU; no task running
  twice at once; no CPU shared (a process runs only on its holder's CPU, or, a dead operation's,
  on a CPU nobody holds); the drain count equals the draining CPUs; a promise goes only to the
  first in line.
- **Proved, liveness parts:** right after any hand-out, no CPU is free while anyone is in line;
  each share-rule transfer lowers Σ nₚ²/wₚ, so transfers can't go back and forth; and a head that
  holds nothing may take from every holder.
- **Searched, not proved:** that every waiter is eventually served, by exhaustive search at small
  sizes (up to 3 CPUs, 3 operations, K ≤ 2, 3 tasks each, one crash), under its assumptions: every
  task ends (`-t`, the 1-hour default), no process stops holding the pool's lock, finitely many
  urgent arrivals, no task waits on a `cpuq run` outside its own tree, the fallback hand-out runs,
  and crashes, kills and stops end. The search found the line's earlier faults (a waiter holding
  nothing starved; a giver taking its CPU back; the giver weighed at its old ticket; a stopped run
  kept first in line), each fixed in the code with its scenario as a unit test.
- **Not modelled:** flock itself, pinning, macOS, process groups and leftovers beyond a task's own
  processes, the gates and outside load, `-c` as a percentage, nesting, `cpuq drain`, output
  files, and time: no timed bound is proved.

## The hook

`cpuq hook` (src/hook.zig) never touches state or config, except to stand down inside a task
(`CPUQ_OP` naming a live operation). It splits the command at `;`, `&`, `|`, newlines, parentheses
and `$(…)`, unquotes words, skips assignments and wrappers (`nice`, `env`, `time`, `timeout`…),
follows `sh -c` scripts, heredocs and `ssh HOST CMD`, strips `cpuq cap`, and checks each simple
command:

1. A heavy command outside cpuq is refused with `cpuq run --label PROJECT:build|test -- CMD` at one
   job: zig build `-j1`, cargo and swift `-j 1`, go `-p 1`, bazel `--jobs=1`, ninja and cmake
   `-j 1`, xcodebuild `-jobs 1`; make, pytest and ctest with their `-j`/`-n` dropped; a jobs
   option already given set to 1. Over ssh, with `--on HOST`.
2. A removed option is refused with cpuq's own line for it (`hook.removed_options`, the list
   `cpuq run` and `cpuq lease` use) and the command rewritten.
3. `$CPUQ_CORES` in a run is refused, with the variable made 1, a one-command `sh -c` unwrapped,
   and the command at one job.
4. `--driver` passes for swarm, rip, or a script named `run`, `run.sh` or `run-tests*`, or under
   `test/` or `tests/`; a build under it is refused (it would hold no CPU).
5. Inside `cpuq run` or `cpuq lease`, a jobs count above 1, no limit (`make -j`, `-j0`,
   `-n auto`), or a tool whose default is every CPU without its one-job option, is refused, with
   the fix at one job "or split the work into tasks with -n M". A count it can't read passes.

A `cpuq run` here (not `--on`) is also put to the advisor: long spec work that another host runs
in half the time is sent to `cpuq submit`.

## A test's tasks

`cpuq test` on a spec with `tasks` (src/tasks.zig, src/submit.zig's `_runjob`): after `setup`, the
spec's `tasks` command writes one file per task into the job's folder,
`~/.local/state/cpuq/jobs/JOB/STAMP/todo/`. The host then writes `manifest`, the names in `todo/`
sorted, one a line, and runs, under `cpuq cap` with the spec's `time` and `mem` for them all:

    cpuq run --label LABEL -n COUNT -t off -- cpuq _task FOLDER

So the tasks are an operation like any other: one CPU each, in the same line, packed and handed
back as any run's. Task N (`CPUQ_TASK`) runs the file on line N of the manifest: its text up to the
first blank line, by `/bin/sh -c` in the folder, with `$CPUQ_CODE` the copy's path, its output
appended to the file. It then appends `== TIME HOST pass|fail|died: REASON SECS` and renames the
file into `done/` (exit 0) or `fail/` (anything else). Only that task touches its file, so no two
renames of one file race. A task cut off leaves its file in `todo/`; the folder's verdict
(`PASS: N done`, `FAIL: F failed, N done[, T in todo/]`, `FAIL: no tasks`) follows the run's lines
in the job's log, and `fail/`'s files come back to the worktree's `.cpuq/fail/`. A run of many
writes its progress (`DONE TOTAL FAILING`) to `CPUQ_PROGRESS` as its tasks end, which
`cpuq job` shows while it runs.
