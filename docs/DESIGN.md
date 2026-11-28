# cpuq design

How cpuq works inside. The [README](../README.md) says how to use it; this file says how each
decision is made, for anyone changing the code or wondering why a run waited. The words below are
the code's own: a `cpuq run` is an *operation* (its record is an `Op`), the pool's CPUs are
*capacity* T, a project's *fair share* is T by its weight, and the CPUs a task keeps *busy* are
measured, never reserved.

The rule in one line: cpuq decides how many tasks run, never which CPU they hold. CPUs are
contested, not owned: the kernel shares CPU time among the running tasks, a task that waits (on
a disk, a socket, a child, a sleep) uses nothing, and others take the time.

## No daemon

Nothing admits, holds or decides for `cpuq run` but the `cpuq` processes of the operations
themselves. The optional recorder (`cpuq record`) only samples: no command waits on it or needs
it, so a machine without one works the same, and one that dies takes nothing with it. Jobs of
task files (`cpuq jobs`) have an optional agent of their own (below): without it each runs at the
workers it was given.

Every operation's record is a file its cpuq holds a `flock(2)` on, so the kernel releases it when
the last process holding the descriptor exits, however it exits. Only `flock(2)` is used, never
fcntl locks: an flock belongs to the open file description, survives fork and exec, and is not
dropped when some other descriptor of the file closes.

## The state directory

`CPUQ_DIR`, else `/tmp/cpuq-UID` with `/tmp` resolved (`/private/tmp` on macOS): a literal path,
so every session of one user agrees on it whatever its `TMPDIR`. If it cannot be created or
written, cpuq fails; it never falls back to another directory.

The pool lives under a versioned folder, `v3/`, so a cpuq of another version never reads these
files as its own (src/pool.zig):

    v3/lock             the pool's lock: every scan, start and record write happens under it;
                        its text, `PID MS`, names the last process to take it and when
    v3/seq              the last ticket number handed out
    v3/ops/C-TICKET     one per running operation, exclusively locked by its cpuq for its whole
                        life (C: 0 urgent, 1 normal); its text is the operation's record
    v3/wake/TICKET      the operation's FIFO: whoever frees room for it writes a byte there
    v3/limits/PID       `cpuq limit`'s request: the run's new -c
    v3/sample           the last measure of the machine: its busy CPUs (kernel ticks) and each
                        task's busy CPUs
    v3/sample.lock      keeps the sample's renewal to one cpuq at a time
    named/NAME/         a named lease: a queue of its own (src/state.zig)
    scopes-ok           whether systemd user scopes work here, probed at most every 10 min

Nothing under the pool's lock waits on another process for long: it takes other locks only by
trying (the op records) or on files no one holds exclusively (a new record under a temporary
name), and waits at most 200 ms for a dead holder's leftover tasks to go. A holder that broke
this would stop every cpuq on the machine, so `cpuq status` waits for the lock at most 5 s, then
names the holder from the lock file's note and exits 125.

An operation's record is `key=value` lines: `pid`, `urgent`, `served` (it has started a task),
`drain`, `all`, `single`, `stopped` (Ctrl-Z), `project`, `label`, `weight`, `limit` (`-c`, worked
out; a drain's CPUs), `tasks`, `done`, `failed`, `running` (its tasks running, those cpuq has
stopped included), `waiting` (tasks it could start now: none while stopped or at its `-c`),
`cpus` and `dstart` (a drain's isolated CPUs and when isolation began), `since`, `tlimit`, `why`
(what holds it back, for status), `now` (its tasks running: number, try, pid, the process's
start time, when it started, when it last started or continued, whether cpuq has it stopped) and
`cmd`. Records are written in place and read only under the pool's lock, as they are written, so
no reader sees one half written.

**Dead files.** A file whose lock can be taken has no live holder: whoever finds it so, while
scanning under the pool's lock, ends what it left (below) and removes it (an operation's record
and FIFO). Nothing depends on a pid being alive, and every kill checks the start time first.

The history file lives elsewhere (see the README), outside `/tmp`, so it outlives a reboot.

## The pool

The pool's CPUs, and their order, come from src/cpus.zig, which every cpuq on the machine works
out the same way: the config's `cpus` list; else on Linux the CPUs online, less those in
`/sys/devices/system/cpu/isolated`, within pid 1's `Cpus_allowed_list` (a container's CPU set),
the lowest thread of each core first, then their siblings; else 0 to the active count less one
(macOS). `budget` or `CPUQ_BUDGET` keeps the first N. The order matters only to a drain, which
isolates CPUs from its end.

## An operation's loop

One process per operation, its cpuq, starts the tasks and watches them (src/op.zig). It holds no
CPU, and it never sleeps while the line would let it start a task. Each turn:

1. **Reap** every ended task: record its outcome, or queue it for a retry (`-r`). For a run of
   many tasks, kill whatever the task left in its process group.
2. **Signals and time limits:** pass a TERM, INT, HUP or QUIT to every task group; TERM a task at
   its limit (time it has run: time stopped doesn't count) and KILL it 5 s later; KILL what is
   left 5 s after a signal.
3. **`cpuq limit`:** take a new `-c` from `v3/limits/PID`. A drain instead checks it is not idle.
4. **Ctrl-Z**, if one came (below).
5. **Look**, when something happened here (a task ended, a signal or a wake came) or when one is
   due (below): renew the sample if it is a second old, then, under the pool's lock, write the
   record, scan the operations, and
   - follow the drains (below): stop its tasks for an `--all` drain, keep them off the CPUs a
     `-c` drain isolates;
   - on macOS, follow the pause plan for its own tasks;
   - start tasks while `mayStart` says go (retries behind the tasks not yet started), the gates
     are open and it is under its `-c`; write the record after each start;
   - wake every other operation that may start now (`wakeReady`), and every drain whose turn has
     come.
6. **Sleep** in `poll()` on its self-pipe (SIGCHLD and the stop and terminal signals write a byte)
   and its wake FIFO, until the next look, the next time limit, or a wake. The next look is a
   second away while the operation is first in line for spare room, held back by something that
   can change without a word (the room, a gate, a drain), keeping its tasks off isolated CPUs, or
   (macOS) has tasks running, which the pause plan watches; else 10 s. A wake comes when room
   frees, so a long line costs little: a waiter wakes for its turn, not to look.

`limit` is `-c` worked out against the pool when the run starts (a percentage of the pool, at
least 1), at most the tasks, and at most 4 × the pool. With no `-c` it is the tasks, within that
bound. `cpuq limit` changes it, within the same bound; lowered, it starts none until fewer run
and kills nothing.

A run of one task (`cpuq run -- CMD`) starts its task in cpuq's own process group, with the
terminal, and its exit status, signal or 124 is cpuq's. A run of many (`-n M`) starts each task as
the leader of a group of its own, with stdin `/dev/null` and stdout and stderr to
`~/.local/state/cpuq/runs/PROJECT/STAMP-PID/N` (`N.ATTEMPT` for a retry), and ends with a summary
and exit 0 or 1. Tasks are never pinned, except a drain's command.

## Admission

`mayStart` in src/pool.zig is a pure function over the operations' records and a few numbers
(the pool's size, the machine's busy CPUs, the time). It answers whether operation `me` starts
one more task now. The caller has checked the gates and the operation's `-c`.

- **Capacity T** is the pool's CPUs less the CPUs `-c` drains isolate; 0 while an `--all` drain
  runs.
- **A project's fair share** is F = T × w ÷ Σw, over the projects with tasks running or waiting
  (a project's weight is the largest of its operations'; stopped operations and drains don't
  count).
- **Within a project, its first waiter goes first** (`projectFirst`): an urgent operation that
  has not yet started a task, then the operation running the fewest tasks, then the one whose last
  task started longest ago (`last`; one that has started none first), then the older ticket.
  Only it starts the project's next task, under the share or in spare room, so a long run that
  ends a task never takes its project's share back before a newer run of the project starts one.
- **Under its share** (running × Σw < T × w, compared without division), the project's first
  waiter starts its next task at once, however busy the machine is. The kernel weights give its tasks
  their share of CPU time; nobody's task is stopped for it.
- **Over its share**, an operation starts a task only while `busy + starting < T − 0.5`, and
  only the first such waiter in line takes it (`firstWaiter`). The line, in order: an urgent
  operation that has not yet started a task, the project running the fewest tasks for its weight,
  the operation running the fewest, the one whose last task started longest ago, the older ticket. Operations with a task of their own stopped for sharing are not in the line.
- **Hard limits:** the operation's `-c`, the gates, and 4T tasks running machine-wide (the
  backstop, for when every waiting task wakes at once).
- **While any task is stopped for sharing** (macOS), no task starts in spare room: the stopped
  ones continue first.
- **While an `--all` drain runs,** nothing starts.

Each look starts tasks one at a time, asking `mayStart` again after each start, since a start
changes the count and the room. `Wait` says why not (a drain, stopped tasks, the backstop, a busy
machine, another waiter first); `whyText` turns it into the record's `why`, which status shows.

**Busy.** `busyNow` adds the busy CPUs of the running tasks (from the sample; tasks that ended
since count no more, tasks cpuq stopped use nothing) and, with `outside_check` on, the load
outside cpuq beyond the CPUs the pool leaves to it: (the machine's busy CPUs less the tasks')
less (the CPUs online less the pool). A drain's command is left out: its CPUs are out of the
capacity. **Starting** counts each task started or continued in the last 2 s as 1 CPU, since the
sample can't have seen it. It never reads the load average, which counts threads waiting on I/O
and lags a minute.

**The sample** (`v3/sample`) is the machine measured: its busy CPUs from the kernel's CPU ticks
since the last sample, and each running task's busy CPUs from its process tree's CPU time. It is
renewed at most once a second, by whichever cpuq finds it old and takes `v3/sample.lock` by
trying, outside the pool's lock, since listing processes takes milliseconds. A cpuq that can't
take the lock reads the sample as it is. Every operation so shares one measure.

**Work-conserving.** A task that waits is busy for almost no CPU time, so `busy` falls, `room`
opens, and the first waiter starts a task: the cost of a blocked task is one process, not a CPU.
Each operation that frees room wakes the operations that may use it (`wakeReady`), under the
lock, so a wake isn't waited for.

**Wake FIFOs.** An operation opens its FIFO, read and write and non-blocking, before it first
looks, so a wake sent after that look always finds it open, and a wake never blocks its writer (a
full FIFO already holds a wake). A started or ended task, a Ctrl-Z, an operation's end and a
drain's start or end wake the others that may start.

## Sharing the time

Admission bounds how many tasks run; sharing their CPU time is the kernel's on Linux and cpuq's
own plan on macOS.

**Linux.** Each `cpuq run` that is not inside a task and not a `--driver` re-executes itself
(`enterSlice`) as

    systemd-run --user --scope --quiet --collect --expand-environment=no
        --slice=cpuq-PROJECT.slice --property=Delegate=yes --property=OOMPolicy=continue
        --unit=cpuq-run-PID -- cpuq _job -- cpuq run ARGS...

so the run is in the scope `cpuq-run-PID.scope`, delegated so `cpuq cap` can give each program a
cgroup beside it, in its project's slice. The pid, terminal and signals stay as they are
(`systemd-run` and `cpuq _job` exec in place); `CPUQ_SCOPE` marks the run inside, which never
passes it on. The project's name is escaped as `systemd-escape` does, so a dash doesn't nest the
slice inside another. Inside its scope, a run sets the slice's `CPUWeight` to 100 × the project's
weight with `systemctl --user set-property --runtime`, only when it differs (weight 1 is the
default). CFS then shares CPU time among whatever is runnable: among the projects by weight, and
among a project's tasks equally. A run that can't enter a scope (config `cgroups` off, no
`systemd-run`, scopes probed not working) runs as it is, and the kernel shares CPUs among tasks
alike. A `--driver`'s runner runs in its own scope, `cpuq-driver-PID`, in its project's slice, and
the runs it starts stay in that scope.

**macOS** has no cgroups, so `pausePlan` shares time by stopping and continuing tasks. Once a
second every operation with tasks computes the same plan from the records and the sample, and
carries out the steps for its own tasks (each step names a ticket and a pid):

- while cpuq's runnable tasks keep more than T + 0.5 CPUs busy, `SIGSTOP` the newest task of the
  project furthest over its share, until they keep no more; a project at or under its share is
  never stopped;
- else while they keep less than T and tasks are stopped, `SIGCONT` the oldest stopped task of
  the project furthest under its share, while one more fits within T.

A task counts one CPU while fresh or unmeasured, else the sample's figure. A stopped task is
marked in its operation's record (`paused`), so every operation sees the same state, and its time
doesn't count against its `-t`. Continuing a task renews its `fresh` time, so `starting` counts it.

## The gates

Before starting a task, an operation reads the machine gates (src/policy.zig `gate`); while one is
closed nothing starts, and `why` says which. Running tasks keep running.

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

A `cpuq run` inside a task runs within that task, with no line (`nested`): when `CPUQ_OP` names a
live operation, or else when one of this process's ancestors (up to 64 hops, by parent pid) is a
live operation's cpuq, which no `env -i` can hide. The environment is only the fast path. One task
execs the command in cpuq's place; `-n M` starts its M tasks one at a time, with the terminal, and
exits 0 or 1. `-c`, `-t`, `-r` and `--urgent` don't apply there. Nothing in it enters a scope: it
is in its task's.

## Parent death and leftovers

Every task is started with `PR_SET_PDEATHSIG` = SIGKILL on Linux, so it dies with its operation's
cpuq however that dies (a check after the call covers a parent that died first). That reaches the
task's own process; what it started may outlive it, and on macOS nothing reaches the task at all.

So each operation's record names its tasks, one `PID START` each (the process's start time, from
the kernel), rewritten whenever a task starts, ends, stops or continues. When an operation dies,
the kernel drops its flock. Whoever next scans the pool finds the record unlocked and SIGKILLs
each noted task whose process still runs with the same start time (its whole group, unless it
shared its cpuq's group), waits for it at most 200 ms, and removes the record and FIFO. A reused
pid is someone else's and left alone. A dead operation's history reads `lost`.

## Ctrl-Z

cpuq takes SIGTSTP (unless it was started with it ignored). It SIGSTOPs every task, marks itself
stopped (its record counts in no share and starts nothing), wakes the others that may start in the
room it left, and then stops itself with SIGSTOP (a TSTP to a process outside job control, an
agent's shell, would be dropped). A continue that comes before cpuq acts on the stop cancels it;
one that comes meanwhile moves a count of continues, and cpuq then doesn't stop itself (only a
continue between that check and the raise is still lost). Continued, cpuq adds the time stopped to
each task's start so it doesn't count against its limit, and continues its tasks, except those it
had stopped for sharing (a shell continues the whole job's group, so it stops those again). A
stopped drain ends its isolation; continued, it takes its turn again before its command continues.

## cpuq drain

`cpuq drain` is an operation with `drain` set, `limit` its CPUs (the pool for `--all`) and a time
limit. It gathers nothing and holds nothing while it waits; it takes its turn, and then isolates
at once. `drainMayStart` answers:

- **`older_waiter`:** an operation queued before it waits with no task running: a drain passes
  no such waiter (an operation already running tasks takes the rest of its turn beside the
  drain, so a long run never holds a drain back).
- **`older_drain`:** an older drain waits too: drains go in their order.
- **`half_pool`:** its CPUs would take all `-c` drains' isolation past half the pool
  (`drainRoom`: at least one). `cpuq drain -c N` with N above half the pool is a usage error.
- **`other_drain`:** a drain isolates and either is `--all` or this one is.

Otherwise it goes. Its CPUs are the first N free of the end of the pool's order (`pickDrainCpus`);
its record names them with the start time. From then:

- **Capacity** drops by N for everyone (`capacity`).
- **Linux:** its command is pinned to its CPUs (`CPUQ_CPUS` lists them), and every other cpuq
  task's threads get an affinity without them. The drain does that at once (`isolateOthers`: it
  reads the tasks from the records and re-pins every thread of each task's process tree), and
  wakes every operation; each operation follows for its own tasks (`repinOwn`) whenever the
  isolated set changes, and starts new tasks with that mask. When no drain isolates any CPU, an
  operation's tasks return to cpuq's own CPU set.
- **macOS:** the capacity drop makes the pause plan stop others' tasks as needed.
- **`--all`:** it waits for any other drain to end, then SIGSTOPs every other cpuq task (the
  drain does it at once; each operation keeps its own stopped while the drain runs, continues
  them when it ends, on macOS through the pause plan, as room allows). Capacity is 0 meanwhile.

A drain isolates at most its limit plus 60 s (`drain_grace_s`) whatever its record says, so a
stuck or vanished drain never holds the machine. The 20-minute bound on `--all` is its `-t` limit.
Its command's `-t` (default 20 m, at most 2 h; `--all` at most 20 m) and an idle stop (under 0.25
CPUs busy for `drain_idle` while another run waits; its command's process tree's CPU time,
sampled by the drain's own cpuq every few seconds) end it as before. `--max` gives up (exit 75)
while its turn hasn't come.

Since nothing is gathered, a drain costs the machine only the CPUs it isolates, and only once its
command runs.

## cpuq kill

`cpuq kill` finds the operation by ticket, its cpuq's pid or its label (several matches: it lists
them and does nothing) and sends its cpuq SIGTERM. A run of many tasks passes it to every task
group and kills what is left 5 seconds later; a run of one forwards it to its command. Its tasks
are recorded as stopped, not failed, and never retried.

## --driver

A `--driver` run is no task and has no record in the pool: it runs its command with the
terminal, `CPUQ_OP` removed so the runs it starts aren't nested, and its exit
status or signal is cpuq's. On Linux with `cgroups` it runs as

    systemd-run --user --scope --quiet --collect --expand-environment=no
        --property=Delegate=yes --property=OOMPolicy=continue
        --slice=cpuq-PROJECT.slice --unit=cpuq-driver-PID -- cpuq _job -- CMD...

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
A lease is no task.

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

**Status** (src/status.zig) reads the pool under its lock: the operations, the capacity, the
sample. Its own sample of usage (skipped with `--no-usage`) watches every process and the
machine's CPU ticks for half a second: each operation's tasks' CPU is its cpuq's process tree's CPU
time over the sample, less cpuq's own, with tasks reaped meanwhile counted through cpuq's children
time; processes outside every operation's tree at 0.3 of a CPU or more are outside work. Outside
work is also put down to what started it: each busy process (0.02 of a CPU or more) counts toward
the top of its tree just below a starter (`claude`, `sshd`, `sshd-session`, `launchd`, `systemd`,
`init`, `tmux`, `screen`, `login`, `cron`, a terminal) or below a parent it can't see; trees at 0.3
of a CPU or more are `outside_work`, with the top's command (an agent's own, out of Claude Code's
`eval '...'` wrapper) and working directory. The line's order is `ahead` over the waiters' records;
a waiter's `why` says what holds it (a gate, a drain, its share and the room, its place in line).
`room` is T − 0.5 − busy (as admission counts it) − starting: positive, the first waiter over its
share starts at its next look. A run's time left comes from its tasks ended so far. A project's
`fair` is its share of the capacity by weight, among the projects running or waiting. Flags come
only after a run's first five seconds, and only when measured: `over_cpu` (over 1.2 CPUs busy per
task running), `capped` (tasks queued under its own `-c` while there is room), `stopped`
(Ctrl-Z); a drain's `idle_drain` and `long_drain`. `--json` is schema 3 (src/statusjson.zig):
`runs[]`, `waiters[]` and `projects[]` with `capacity`, `isolated`, `running`, `paused`,
`waiting`, `busy`, `tasks_busy`, `room` and `gate` (open, pressure, low_memory, low_disk, drain).

**History.** Each operation appends `queued` when it enters the line, then at its end `started`
(dated at its first task's start) and `ended`, or `gave_up` for `--wait-max`. The end line holds
the most tasks it ran at once, its tasks' CPU time (`wait4`'s figures summed over every child),
tasks done and failed, and its exit status or signal. A line under 4 KB written with `O_APPEND`
lands whole, so no lock is needed. An operation with neither `ended` nor `gave_up` whose cpuq is
gone, or which queued before the machine last booted, is `lost`.

## What the Lean model checks

A Lean 4 model of the protocol lives in `formal/` (its README has the whole account). It models
the protocol, not the Zig code: one step function over finite state, with the rules of
src/pool.zig and the loop of src/op.zig as its rule sets. The properties it holds the rules to:

1. **Work-conserving:** if a task waits (not gated, under its run's `-c`), then
   `busy + starting ≥ T − 0.5`, or its project is over its share and an earlier waiter has the
   room.
2. **No wait under share:** a project below its fair share never waits, except on a gate, its
   `-c`, or the 4T backstop.
3. **No starvation:** every waiting task starts, given that tasks end (`-t`) and gates reopen.
4. **Drain bounded:** an isolation lasts at most its limit plus the grace. A drain waits only for
   older drains, older runs waiting with no task running, and the half-pool bound, and never
   passes such a waiter.
5. **No idle hold:** no state where a CPU is reserved but unused while a task waits: nothing
   reserves one.

Not modelled: flock itself, the kernel's sharing, macOS signals beyond the pause plan's rule,
process groups and leftovers beyond a task's own processes, the gates and outside load as
measures, `-c` as a percentage, nesting, output files, and time: no timed bound is proved.

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
2. A removed option (`--cores`, `--priority`, `--max-wait`, `--exclusive`, `--no-load-check`,
   `--qos`, `--opaque`, `-x`) is refused with cpuq's own line for it (`hook.removed_options`, the
   list `cpuq run` and `cpuq lease` use) and the command rewritten.
3. `$CPUQ_CORES` in a run is refused, with the variable made 1, a one-command `sh -c` unwrapped,
   and the command at one job.
4. `--driver` passes for swarm, rip, or a script named `run`, `run.sh` or `run-tests*`, or under
   `test/` or `tests/`; a build under it is refused (it would be no task of its own).
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

So the tasks are an operation like any other, admitted through the same line. Task N (`CPUQ_TASK`) runs the file on line N of the manifest: its text up to the
first blank line, by `/bin/sh -c` in the folder, with `$CPUQ_CODE` the copy's path, its output
appended to the file. It then appends `== TIME HOST pass|fail|died: REASON SECS` and renames the
file into `done/` (exit 0) or `fail/` (anything else). Only that task touches its file, so no two
renames of one file race. A task cut off leaves its file in `todo/`; the folder's verdict
(`PASS: N done`, `FAIL: F failed, N done[, T in todo/]`, `FAIL: no tasks`) follows the run's lines
in the job's log, and `fail/`'s files come back to the worktree's `.cpuq/fail/`. A run of many
writes its progress (`DONE TOTAL FAILING`) to `CPUQ_PROGRESS` as its tasks end, which
`cpuq job` shows while it runs.

