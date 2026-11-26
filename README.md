<p align="center">
  <img src="assets/cpuq-icon.svg" width="160" alt="The cpuq icon: a chip with four cores, three in use and one free">
</p>

<h1 align="center">cpuq</h1>

<p align="center">
  A machine-wide CPU pool for builds, tests, benchmarks and coding agents, on macOS and Linux.
</p>

cpuq is a CPU queue (say "CPU queue" or, lovingly, "see puke"). Every task started under it, from
any shell, session or agent, gets one CPU of the machine's pool, handed out through one fair line.
One binary, no daemon: every hold is a `flock(2)` on a file, so the kernel releases it however its
holder dies.

The pool is per user. "Machine-wide" means across every process that user runs on the machine;
another user on the same machine has a pool of their own.

<p align="center">
  <img src="assets/screenshots/cpuq-app.gif" width="760" alt="Cpuq.app's window, live: ten CPU cells filling with each project's color, the last hour stacked by project with rose where a job waited beside idle CPUs, and the running jobs with what each uses and reserves">
  <br><sub>Cpuq.app, the menu-bar companion (see <a href="#cpuqapp-macos">Cpuq.app</a>)</sub>
</p>

## Quick start

    curl -fsSL https://raw.githubusercontent.com/shreeve/cpuq/main/install.sh | bash

    cpuq run --label app:build -- zig build -j1
    cpuq run --label app:test -n 40 -- sh -c './test/shard "$CPUQ_TASK" 40'
    cpuq status

The first is one task: it waits for a CPU, then runs the build on it, at one job, with the
terminal. The second runs 40 tasks, each on a CPU of its own, as many at once as the pool gives;
each learns which it is from `$CPUQ_TASK`, which cpuq sets for the command, so it is expanded
inside `sh -c '…'`, in single quotes. The third shows who holds which CPU and who waits, and why.

Agents: read [AGENTS.md](AGENTS.md).

### Install

`install.sh` downloads the latest release for macOS or Linux (arm64 or x86-64), checks it
against the release's sha256 checksums and installs `cpuq` to `~/.local/bin`, or to
`/usr/local/bin` as root (`BIN=DIR` picks another). `| bash -s v0.1.0` pins a version and
`| bash -s -- --uninstall` removes it. On a machine with several users, one copy on everyone's
`PATH` is enough: `curl … | sudo bash`. The Linux binaries are static.

With Homebrew: `brew install shreeve/tap/cpuq`. From source, with Zig 0.17.0:
`zig build install -Doptimize=safe -p ~/.local`. In a checkout, `zig build` writes `bin/cpuq`,
`zig build test` runs the unit tests and `test/run.sh` the end-to-end tests against `bin/cpuq`.

## Why

A job knows how much parallel work it has. It cannot know how many CPUs it should use, because
that depends on everything else the machine runs, and no single process sees that.

- **Each job tuning itself to the CPU count** assumes it owns every CPU. With several sessions
  and agents each starting `-j10` builds on a 10-CPU machine, that is 30 or more threads on 10
  CPUs, and every job crawls.
- **Each job reserving cores by guess** leaves them idle: a job that asks for 16 and keeps 2 busy
  holds 14 that nobody else may use.

cpuq gives each task exactly one CPU, for as long as the task runs, and no more. Parallel work is
many tasks. A task can't hold a CPU it doesn't use for long, since its CPU goes back when it ends,
and the CPUs a run holds are always the CPUs its running tasks are on. Runs share the pool through
one line, by project, and a run with more tasks than CPUs gives a CPU back at a task boundary
whenever someone else is owed one.

**Hasn't someone solved this already?** Pieces of it, many times over: global make jobservers,
job spoolers, Google's Borg, Meta's Buck2, benchmark locks, and in 2026 a wave of build locks for
AI agents. [docs/PRIOR-ART.md](docs/PRIOR-ART.md) surveys them all: what each does, what cpuq
borrows, and what is new here.

## Words

| word | meaning |
|---|---|
| CPU | a logical processor, as the OS counts them |
| pool | the CPUs cpuq hands out: by default every CPU online (see [The pool](#the-pool)) |
| run | one `cpuq run` (status calls it an operation, `OP`): M tasks of one command |
| task | one process of a run, on one CPU of the pool |
| place | room for one task on a held CPU: one per CPU, or K with `-x K` |
| line | the order in which waiting runs get the next free CPU |
| ticket | a run's number in the line, renewed each time it gives a CPU up |
| project | the repo a run is started in (a worktree counts as its repo), else its label's project |
| weight | a project's share of the pool, relative to others (config `weights`; default 1) |
| emptying | a held CPU its run fills no more, to give it up once its tasks end |
| label | a run's name, `project:task`; history is kept by label |
| gate | a machine check that holds every free CPU: memory pressure, low memory, low disk |
| drain | `cpuq drain`: the whole machine, emptied, for one command, for timing |
| named lease | a queue for something that is not CPUs: a database, a device, another machine |

## cpuq run

    cpuq run [-n M] [-c C] [-x K] [-t T] [-r N] [--label PROJECT:TASK] [--note TEXT]
             [--urgent] [--wait-max S] [--driver] [--on HOST ...] [--] CMD ARGS...

| option | meaning |
|---|---|
| `-n M` | M tasks of CMD; each gets `CPUQ_TASK` (1 to M) and `CPUQ_TASKS`, and its output goes to a file of its own. Without `-n`, one task, with the terminal |
| `-c C`, `-c P%` | hold at most C CPUs, or P% of the pool (at least 1); default 100% |
| `-x K` | K tasks per CPU, for tasks that mostly wait (default 1) |
| `-t T` | each task's time limit: `30s`, `10m`, `2h`, or `off`; default the config's `timeout` (1h) |
| `-r N` | try a failed task up to N more times; `CPUQ_ATTEMPT` says which try it is |
| `--label PROJECT:TASK` | the run's name in status and history |
| `--note TEXT` | what the run is for, kept beside its label in history |
| `--urgent` | its first CPU goes ahead of the line: a rebuild someone is waiting on |
| `--wait-max S` | give up (exit 75) if no CPU comes within S seconds; nothing runs. `0`: now or not |
| `--driver` | a test runner that starts `cpuq run`s of its own: it holds no CPU |
| `--on HOST` | run on HOST, one of this machine's remotes (see [Other machines](#other-machines---on-host)) |

### One task

`cpuq run -- CMD` waits for a CPU, then runs CMD on it in the foreground: stdin, stdout and stderr
are inherited (a terminal stays a terminal), it shares cpuq's process group (so `^C` reaches it),
signals sent to cpuq are forwarded, and CMD's exit status is cpuq's. When CMD dies by a signal,
cpuq dies by the same one. At its time limit CMD gets SIGTERM, and cpuq exits 124.

A task has one CPU, so run what it runs at one job:

| tool | after `cpuq run --label … --` |
|---|---|
| zig | `zig build -j1` |
| make | `make` (no `-j`) |
| cargo | `cargo build -j 1` |
| go | `go build -p 1 ./...` |
| swift | `swift build -j 1` |
| ninja | `ninja -j 1` |
| pytest | `pytest` (no `-n`) |

A bare `zig build`, `cargo`, `go build` or `swift build` starts a job for every CPU of the machine.
On Linux they all share the task's one CPU, since a task is pinned to it; macOS can't pin, so there
they take CPUs from every other task. Parallel work is tasks: `-n M`.

### Many tasks: -n M

`cpuq run -n M -- CMD` runs CMD M times. It holds up to `-c` CPUs, fills each to K tasks (`-x K`)
before taking another, and starts the next task the moment a place frees, until all M have run:

    cpuq run --label app:test -n 40 -- sh -c './test/shard "$CPUQ_TASK" 40'
    cpuq run --label app:fuzz -n 500 -t 2m -r 1 -- sh -c './fuzz "$(sed -n "${CPUQ_TASK}p" cases.txt)"'
    cpuq run --label app:fetch -n 200 -x 4 -- sh -c 'curl -fsS "$(sed -n "${CPUQ_TASK}p" urls)" >/dev/null'

- **Before it starts** it says what it will do, so a misread `-n` shows at once:
  `cpuq: 40 tasks, up to 10 CPUs, overload 1, timeout 3600s`.
- **Each task** runs in a process group of its own, with stdin from `/dev/null` and stdout and
  stderr to `~/.local/state/cpuq/runs/PROJECT/STAMP-PID/N` (a retry's to `N.ATTEMPT`). When a task
  ends, whatever it left running in its group is killed.
- **At the end** it prints a summary on stderr, then each failed task's last five lines (the first
  five failed tasks):

      cpuq: 38 of 40 tasks passed, 2 failed (1 at the time limit), in 41.3s; output in ~/.local/state/cpuq/runs/app/1795675001-92874
      cpuq: task 17 (attempt 1) exited 1; the end of ~/.local/state/cpuq/runs/app/1795675001-92874/17:
          ...

- **Exit status:** 0 when every task passed, else 1. A run stopped by a signal (`^C`, `cpuq kill`)
  passes it to every task, kills what is left 5 seconds later, and dies by that signal.
- **`-x K`** puts K tasks on each CPU, for work that mostly waits (network, a server, sleeps):
  about 1 + time waiting ÷ time computing. Tasks that compute only slow each other at K > 1.
- **`-t T`** limits each task: at T it gets SIGTERM, then SIGKILL 5 seconds later; it counts as
  failed (124), and its place goes to the next task. A run's time stopped (Ctrl-Z) doesn't count.
  A sensible T is about ten times the task's usual time. With no `-t`, the config's `timeout`
  (1 hour) applies, so no task holds a CPU forever.
- **`-r N`** tries a task that failed (non-zero exit or its time limit) up to N more times, at the
  next free place, before tasks not yet started. Tasks stopped by a signal are not tried again.
- **`-c C`** caps the CPUs held, as a count or a percentage of the pool, worked out when the run
  starts. It is a ceiling, never a claim: a run never holds more CPUs than it has tasks to put on
  them.

### Environment

Each task gets `CPUQ_TASK` (1 to M, 1 for a single task), `CPUQ_TASKS`, `CPUQ_CPU` (the CPU it
runs on), `CPUQ_OP` (its run's ticket), `CPUQ_ATTEMPT` and `CPUQ_ATTEMPTS` (`-r` + 1). On Linux each
task is pinned to its CPU (`sched_setaffinity`) before it runs, and everything it starts inherits
that. macOS can't pin: `CPUQ_CPU` there only names the place.

### --wait-max, --urgent

`--wait-max S` gives up after S seconds while the run holds no CPU and runs no task, with exit 75;
the command never ran. `--wait-max 0` starts now or not at all.

`--urgent` puts the run's first CPU ahead of everything else in the line, once per project at a
time (while another of its project's urgent runs holds a CPU, it waits its turn). It never takes a
CPU from a running task: it gets the next one that frees, and while none is free, a CPU is emptied
for it at the next task boundary. Use it for a rebuild someone is waiting on.

### --driver: a test runner

A test runner that starts a `cpuq run` per test (swarm, a `test/run` script) runs under
`--driver`: it holds no CPU and takes no turn, and each run it starts takes its own. It runs with
the terminal, and its exit status (or signal) is cpuq's. On Linux, with `cgroups` (on by default),
it runs in a delegated systemd user scope of its own, its command in the scope's `job/`, and
`$CPUQ_CGROUP` names the scope, so `cpuq cap` can give each program it starts a cgroup beside
`job/`, with limits the kernel enforces. Whatever it leaves in the scope is killed when it ends.
Where `systemd-run --user` doesn't work, it runs as it is, and `cpuq cap` watches the slow way.

`cpuq hook` accepts `--driver` only for a test runner (swarm, rip, a script named `run`, `run.sh`
or `run-tests*`, or one under `test/` or `tests/`): a build under it would hold no CPU.

### Nested runs

A `cpuq run` inside a task (`CPUQ_CPU` and `CPUQ_OP` naming a live run, or, when the environment
was cleared, an ancestor process that is a run's cpuq) starts at once on that task's CPU, with no
line. One task replaces the nested cpuq (exec); `-n M` runs its M tasks `-x` at a time on that one
CPU, with the terminal, and exits 0 when all passed, else 1. So a script run under cpuq may call
others that use cpuq. Parallel work goes at the top: `cpuq run -n M`, or `--driver`.

### Labels

Give every run a label, `project:task`, the same on every run: `app:build`, `app:test`,
`site:deploy`. A label is parts split by `:`, each of lowercase letters, digits, `.`, `_` and `-`,
none starting with `.`; anything else is a usage error. History is kept by label, so a label with a
run id, date or branch name in it never has a history. A run with no label is named after its
command.

## How CPUs are shared

### The pool

The pool is the CPUs cpuq hands out, in a fixed order that every cpuq on the machine works out the
same way:

- `cpus = LIST` in the config (a Linux CPU list, `12-19,2`) is the pool, in that order: on pup, its
  E-cores, say.
- Otherwise, on Linux: the CPUs online, less those isolated from the scheduler, within the CPUs the
  machine's init may use (a container's CPU set); one hyperthread of each physical core first,
  then their siblings. On macOS: CPU 0 to the active count less one.
- `budget = N` (or `CPUQ_BUDGET`) keeps the first N. `cpuq budget` prints the pool's size.

Each pool CPU is a token file; a run holds a CPU by an exclusive flock on its token. Only the run's
own cpuq holds it (the descriptor is close-on-exec), never its tasks, so no leftover process can
keep a CPU after its run is gone.

### The line

A free CPU goes to the first run in the line that wants one, in this order:

1. **Urgent:** an `--urgent` run's first CPU, while its project holds no urgent CPU.
2. **Holding nothing:** a run with no CPU goes before every run that holds one.
3. **The project's share:** the project holding the fewest CPUs for its weight.
4. **The run's own share:** the run holding the fewest CPUs.
5. **The ticket:** the older first.

CPUs are handed out one at a time and the line is ranked again after each, so free CPUs spread
over the projects by weight. Whoever frees a CPU hands it out at once, under the pool's lock, as a
promise to the first in line, and wakes that run; a promise to a run that has since died is void.
A run that wants no more CPUs is not in the line.

Weights are per project, `weights = rig:2 trig:1` in the config: rig's runs together get twice
trig's share while both want more than the pool has. A project not named weighs 1.

### Giving CPUs back at task boundaries

A run never stops a task to give its CPU away. While nobody waits, it keeps every CPU it holds
full. When the first run in the line wants a CPU and none is free, one run is chosen to give one
up: it stops filling one of its CPUs, and when that CPU's last task ends, the CPU goes to the
first in line.

- **Who may give:** a run whose project, after giving one, still holds at least as many for its
  weight as the waiter's would after taking it: (waiter's + 1) ÷ its weight ≤ (giver's − 1) ÷ the
  giver's weight. A waiter that holds nothing may take from anyone. A run never gives a CPU that
  would come straight back to it: the waiter must stay ahead of it in the line after the move.
- **Which one:** of those, the run whose project holds the most for its weight, then the one
  holding the most CPUs, then the newest.
- **How many:** CPUs owed are counted across every run, so many runs don't all empty a CPU for
  one waiter: at most as many are emptied as the first waiter still wants.
- **Which CPU:** an empty one if there is one, else the one with the fewest tasks, then the one
  whose newest task started longest ago, so it frees soonest.
- **A fresh ticket:** a run that gives a CPU back takes a new ticket, behind every other, so runs
  that hold one CPU each take turns with a newcomer.
- **Consolidation:** while a CPU is being emptied, a place freeing on another of the run's CPUs
  takes a task from it (Linux moves the task's processes there), so the emptied CPU frees sooner.

So ten runs of one task each on a ten-CPU Mac give a newcomer a CPU when the first of them ends,
and a 5,000-task run that fills a machine gives way, a CPU at a time, to a second project, until
the two hold their fair shares.

### Outside load and the gates

**Outside load.** cpuq hands out a free CPU only when the machine has one idle: it hands out at
most the CPUs online less the larger of the CPUs busy (from the kernel's CPU ticks, over the last
second or so) and the CPUs held. So work cpuq doesn't run (Spotlight, a build typed outside cpuq)
holds back CPUs while it runs, and so does a task that uses more than its one CPU (which macOS
can't stop). It never reads the load average, which counts threads waiting on I/O and lags a
minute.

**The gates** hold every free CPU while they are closed; runs keep the CPUs they hold, and keep
filling them:

- **memory pressure** (`pressure_check`): macOS's critical level; on Linux, `some avg10` in
  `/proc/pressure/memory` at `pressure_psi` (10) or more;
- **low memory** (`min_available`, off by default): available memory under that size;
- **low disk** (`min_disk`, 5G): less than that free on the filesystem holding `$HOME`, the one
  holding cpuq's state directory (the temp directory), or, where it is a filesystem of its own,
  `~/cpuq`, where jobs sent here keep their copies, caches and scratch. A full disk fails every
  task and every tool that writes a file, so the pool holds new ones until there is room.

### Ctrl-Z, kill and a dead run

- **Ctrl-Z** on a run stops every task, gives back every CPU (and every CPU promised to it), and
  then stops cpuq. While stopped it wants nothing, so the line passes it by. Continued (`fg`), it
  joins the line again, and each stopped task continues once it has a place on a CPU (on Linux,
  pinned there). Time stopped doesn't count against a task's limit.
- **`cpuq kill TICKET|PID|LABEL`** ends a run on this machine, waiting or running: its cpuq gets
  SIGTERM, passes it to every task, and kills what is left 5 seconds later. A label that names
  several runs lists them, to be named by ticket. It acts on anyone's runs, not only the caller's.
- **A run whose cpuq dies** (SIGKILL, a tool's timeout) loses its CPUs at once: the kernel drops
  its flocks. On Linux each task dies with it (`PR_SET_PDEATHSIG`). Each CPU's token names the
  process groups running on it, with each leader's start time; whoever takes the CPU next first
  kills those groups still running (a group whose leader has a different start time is someone
  else's by now), so a CPU is never shared with an orphan.

## cpuq drain: timing

    cpuq drain [--max T] [--label L] [--] CMD ARGS...

For timing, nothing else. A drain goes first in the line. While it waits, every run stops filling
its CPUs and gives each back as its tasks end, and every CPU freed goes to the drain. Once it holds
the whole pool, CMD runs alone, unpinned, with no time limit, and the CPUs go back when it ends,
however it ends. `--max T` (`90s`, `10m`) gives up if the machine isn't empty by then (exit 75),
and nothing runs. Its own builds and helpers run inside it as nested runs. A drain that spans
several commands wraps them in one: `cpuq drain --label app:bench -- ./bench.sh`.

Draining a busy machine stops everyone, so time where that is fair: a quiet machine, or another
machine through a named lease (`cpuq lease bench --host buildbox -- ssh buildbox 'cd repo && cpuq
drain -- ./bench'`). Work outside cpuq (system services) still runs; `cpuq status` shows it.

## Watching

### cpuq status

    cpuq status [--host HOST]... [--json] [--no-usage] [--watch[=SECONDS]]

`cpuq status` shows the pool and who holds which CPU, the line and why each run in it waits:

- **The machine:** the pool (its size and CPUs), CPUs held, free and being emptied; CPUs busy of
  those online, split into cpuq's tasks and work outside; the load, memory pressure and the gate;
  memory and swap. When work outside cpuq uses a CPU or more, or a gate is closed, the busiest
  such processes.
- **Held:** each running run's ticket (`OP`), pid, project, label, tasks done of total and failed,
  tasks running, its CPUs (`×K` with `-x`, and how many it is emptying), CPU busy per CPU held, how
  long, an estimate of the time left, and its command. A note under it flags a run whose CPUs are
  under half busy (`-x could be higher`, for a run of many tasks), one over 1.2 CPUs per CPU held,
  and one stopped (Ctrl-Z).
- **Waiting:** in line order, each run's ticket, project, label, the CPUs it holds and still wants,
  and why it waits: `1st in line; 1 CPU is being emptied for it`, a closed gate, outside load.
- **Projects:** each project's weight, runs, CPUs held and wanted, and its fair share.

On a terminal it draws boxed tables in color (`NO_COLOR` drops the color); anywhere else, plain
lines.

- `--json` is for programs (below). `--watch` redraws on a terminal every 2 seconds
  (`--watch=N`: every N) until `^C`; it refuses to run without a terminal or with `--json`.
- `--no-usage` skips the half-second sample of what each run uses.
- `--host HOST` shows HOST's status, fetched over ssh; it repeats, and `--host local` is this
  machine, so `cpuq status --host local --host buildbox` is one view of both.

`cpuq status --json` is one object (with several `--host`s, one per host, keyed by host). Its
`schema` (2) changes only when a field is removed or changes meaning; new fields may appear.

| field | meaning |
|---|---|
| `schema`, `version`, `dir`, `admit` | 2, cpuq's version, the pool's directory, and `pool` |
| `pool`, `budget` | the pool's CPUs, and its size |
| `held`, `free`, `promised`, `emptying` | CPUs held, free, promised to a waiter, and being emptied |
| `busy`, `tasks_busy` | CPUs busy on the machine, and of those, cpuq's tasks |
| `cores`, `active_cores` | the machine's CPUs, and those active now |
| `load`, `memory_pressure` | the 1-, 5- and 15-minute load; `normal`, `high`, `unknown` or `off` |
| `memory` | bytes: `total`, `used`, `swap_total`, `swap_used`; null when unreadable |
| `gate` | `state` (`open`, `pressure`, `low_memory`, `low_disk`, `drain` or `outside_load`), `load`, `available`, `disk_free`, `disk_path`, `text` |
| `next_free` | seconds until a CPU is expected to free, when none is free |
| `holders[]` | running runs: `ticket`, `pid` (its cpuq), `project`, `weight`, `label`, `command`, `since`, `cpus` (held), `cores` (how many), `slots` (their places in the pool), `emptying`, `want`, `overload`, `limit`, `tasks`, `done`, `failed`, `running`, `using` (CPUs busy), `urgent`, `paused` (stopped), `exclusive` (a drain), `progress`, `left`, `left_from`, `flags` |
| `waiters[]` | in line order: `order` (1 first), `ticket`, `pid`, `project`, `label`, `command`, `since`, `holds`, `cores` (CPUs it waits for), `max` (its limit), `urgent`, `exclusive` (a drain), `why`, `gate`, `eta` (the first's, seconds) |
| `projects[]` | `name`, `weight`, `ops`, `held`, `want`, `fair` |
| `outside[]`, `outside_total` | the busiest processes outside cpuq (`pid`, `name`, `using`), and their total |
| `cpu_ticks` | each CPU's time so far, `[busy, total]`, cumulative: two statuses give each CPU's use between them |
| `boot_time` | when the machine booted, Unix seconds |
| `recorder` | whether `cpuq record` is sampling this machine |

### cpuq history

    cpuq history [--label PATTERN] [--limit N] [--json]

Every run is recorded as it enters the line, starts and ends, in
`~/.local/state/cpuq/history.jsonl` (`$XDG_STATE_HOME/cpuq/` when set; beside the state directory
when `CPUQ_DIR` is set; `CPUQ_HISTORY` names the file outright). `cpuq history` lists the last 20
runs (`--limit N`), newest first: label, pool (`cpus`, a lease's name, or `remote` for `--on`), the
most CPUs it held at once, tasks done of total (and failed), how long it waited and ran, its active
CPUs (its tasks' CPU time over its run time), and how it ended: an exit status, `signal N`,
`gave up` (`--wait-max`), or `lost` (its cpuq died uncaught, or the machine restarted). A summary
follows: the median and longest wait, and CPUs busy against CPUs held on average. `--label` filters
(`app:*` for a prefix), and `--json` gives the runs to a program.

### cpuq record

    cpuq record [--interval SECONDS]      # foreground; --install keeps one running
    cpuq record --install | --uninstall
    cpuq samples [--since UNIX-SECONDS]   # default: the last hour

An optional recorder. Every 3 seconds it writes one JSON line to `samples.jsonl` beside the
history: each CPU's busy share since the last line, the 1-minute load, the pool's CPUs held, runs
waiting, and the gate. The file moves to `samples.jsonl.1` past 12 MB, so the two together hold at
least a day even for 96 CPUs. Only one recorder runs per machine; a second exits at once.
`cpuq status --json` says whether one is running (`recorder`). It only watches: nothing waits on
it, and every other command works the same without it.

`--install` keeps one running as a launchd agent (macOS) or a systemd user service (Linux,
lingering where `loginctl` allows, so it runs without a login), restarted if it stops. It exits
when its binary is replaced, so an upgrade restarts it on the new one. It also runs `cpuq clean`
every hour. Cpuq.app reads its samples to draw the hour before the app was opened, on each machine.

### cpuq cap

    cpuq cap [--mem SIZE] [--time DURATION] [--output SIZE] [--pids N] -- PROGRAM [ARGS...]

For a test runner that starts thousands of programs: it runs one under limits, so the runner
needn't watch each one itself. A runner that lists every process (`ps`) for each program it runs
can spend a large part of a big machine doing nothing else: one did, about 17 of 96 CPUs. cap takes
no CPU of the pool: put it inside `cpuq run` (`cpuq run -- cpuq cap --time 2m -- PROGRAM`), never
around it, where its `--time` would count the time spent waiting.

| limit | what happens |
|---|---|
| `--mem SIZE` | PROGRAM and everything it started are stopped above SIZE (`2G`, `512M`) |
| `--time DURATION` | stopped after DURATION (`120`, `120s`, `2m`, `500ms`) |
| `--output SIZE` | stopped once it has written more than SIZE to stdout and stderr, which must be files or `/dev/null`; a pipe is refused. Checked about every 0.1 s |
| `--pids N` | at most N processes and threads at once, inside a `--driver` runner on Linux; elsewhere not enforced |
| `--link FD` | stopped at once, exit 123, when the other end of the pipe whose read end is FD closes: whoever started it (a job's driver) is gone |
| `--no-crash-report` | no crash report when PROGRAM crashes on purpose, a test that panics. macOS: cap answers PROGRAM's crashes itself, so neither the user's ReportCrash (~/Library/Logs/DiagnosticReports) nor the system's (/Library/Logs/DiagnosticReports) files one, and cap exits 128+N for a death by signal N rather than dying by it (a shell sees the same status). Linux: a core limit of exactly 1, so the kernel passes it to no `core_pattern` handler (Ubuntu's apport, seconds per crash); it still dies by its signal. What PROGRAM starts inherits it, so wrap the program meant to crash, never a compiler before it |

`cpuq cap --protocol` prints what cap does as a number that changes only when that does (its
limits, how it stops a program, its exit statuses, `--no-crash-report`): a test runner that caches
results keys them on it, not on cpuq's version, so a release that leaves cap alone keeps them.

A limit of 0 is refused: no limit is the option left out.

- **Exit status:** PROGRAM's own, or death by its signal. When cpuq stopped it, it's 122 for
  memory, 124 for time and 121 for output, each with one line on stderr. 2 is a usage error,
  125 cap's own failure, 126 PROGRAM can't be run, 127 PROGRAM wasn't found. PROGRAM can exit
  with any of these itself; the stderr line is what tells them apart.
- **Inside a `--driver` runner on Linux** (its scope in `$CPUQ_CGROUP`): PROGRAM is born in a
  cgroup of its own beside the runner's (`clone3` into it, with no write to `cgroup.procs`, which
  would stall every fork on the machine). The cgroup has `memory.max`, no swap and
  `memory.oom.group`, so the kernel stops it at the limit: within milliseconds, with nothing
  polling. Everything it started is stopped with it, even what left its process group. A cap
  killed before it could clean up (SIGKILL) leaves its cgroup; the runner's next cap removes it,
  with whatever is still running in it.
- **Elsewhere** (macOS, or Linux outside such a runner): PROGRAM gets its own process group, and
  its memory is read once a second from its own process tree, never from a list of every process.
  Stopping it kills that tree, then the group. On Linux cap is the tree's subreaper, so orphans
  stay in it; macOS has none, so a process that leaves both the tree and the group (a double fork
  with `setsid`) is out of cap's reach, its memory uncounted and left running.
- **Either way:** PROGRAM's end wakes cpuq at once, and anything PROGRAM left running is stopped.
  It costs about half a millisecond a call.

### Progress

`cpuq status` shows a run of many tasks with its tasks done of total, failing, and the time left
at its rate so far: `4210/12629 33% · 3 failing · ~9m left`.

A submitted job (`cpuq submit`) that knows how much work it has can say how far it is: its command
gets a file, `$CPUQ_PROGRESS`, to write one line to, `DONE TOTAL FAILING`:

    printf '%d %d %d\n' "$done" "$total" "$failing" > "$CPUQ_PROGRESS.tmp" && mv "$CPUQ_PROGRESS.tmp" "$CPUQ_PROGRESS"

Write it whole, to `.tmp` and renamed over, at most once a second and once more at the end.
`cpuq submit` prints it as it follows the job, and `cpuq job` shows it.

### Cpuq.app (macOS)

[`app/`](app/) holds Cpuq.app. Its window has a page per machine: this Mac (⌘1), then each remote
in the config (⌘2, ⌘3…), read over ssh while the window is open. Each page shows the CPUs
busy right now with each project's share and who waits and why; the last hour, Stacked by project
and Per Core (one lane per CPU) together, rose where runs waited beside idle CPUs; the runs, with
their actions on right-click; and `cpuq history` summed by project. Every section's height drags.
While the window is open it is an ordinary app (Dock icon, menu bar, ⌘Tab); closed, only its
menu bar chip remains, which stays calm while all is well, turns orange when the gate is shut or
runs wait beside idle CPUs, and shows ☁ with uptime and this month's hours while a cloud machine
runs. It notifies, once each, when the gate stays shut, runs wait beside idle CPUs, heavy work
runs outside cpuq, a run looks stuck, a machine is overloaded while another has room, or a cloud
machine sits idle and billing; the urgent ones are also texted. It reads `cpuq status`, `history`
and `samples`. Install it with `brew install --cask shreeve/tap/cpuq-app`.

## Jobs: a folder of task files

A job too big for one command, such as a test suite of thousands of programs, is a folder that a
driver of its own runs:

    ~/.local/state/cpuq/jobs/NAME/STAMP/     e.g. jobs/rig/20261017-180000/
      todo/  live/  done/  fail/  jobs.sock

NAME is `[a-z0-9._-]`, not starting with a dot; the part before its first dot is its project.
A task file is its work: its text up to the first blank line runs with `sh`. Each run appends its
output, then one line, `== TIME HOST pass|fail|died: REASON SECS`. Exit 0 moves it to `done/`,
exit 1 to `fail/`; anything else (a signal, a limit, a driver gone) is a death, back to `todo/`,
and the third death goes to `fail/`. Retrying is running again: `mv fail/* todo/`.

| in the folder | |
|---|---|
| `cpuq jobs run [--workers N] [--weight W] [--gap MS]` | runs `todo/`, N tasks at once (half the CPUs; the agent's count when one runs), W a whole number (1), each new worker 50 ms after the last and MS after its last task; live on a terminal. Exit 0 when all are done, 1 otherwise, after the failures' output |
| `cpuq jobs status` / `watch` | the job once, or live until it ends with its result and exit status |
| `cpuq jobs set workers N` / `weight W` / `gap MS` | changes the running job; a count you set holds |
| `cpuq jobs pause` / `resume` / `stop` | `stop` puts the running tasks back in `todo/`, with no death |
| `cpuq jobs reset` | every file back in `todo/` holding only its work; refused while it runs |

`cpuq jobs` lists every job folder on this host, then this worktree's submitted jobs (`--all`:
every worktree's). Each task runs under `cpuq cap --link` in a process group of its own, with its
file (locked) as its stdout and stderr: every task ends with its driver, and a driver started
again files what a dead one left in `live/` as `died: lost`. A job's driver takes no CPU of the
pool.

**The agent** (`cpuq agent`, kept running by `cpuq agent --install`) keeps the machine at its
target load and shares it among the running jobs by weight: each second it measures what each
job's workers cost in CPU and sets every job's workers and gap so the jobs together use what the
work outside them leaves. A count you set with `cpuq jobs set workers N` holds; the others share
the rest. Without an agent each job runs at the workers it was given. `cpuq attach` joins a
terminal (or `ssh HOST cpuq attach`) to the agent: `jobs` lists the jobs, and
`to FOLDER set workers 4` (or `pause`, `resume`, `stop`) steers one. How it decides is in
[docs/DESIGN.md](docs/DESIGN.md), "The agent".

## Other machines: --on HOST

    cpuq run --on HOST [run options] [--return PATH]... [--include PATH]... -- CMD ARGS...

`cpuq run` always runs here. `--on HOST` runs it on HOST instead, one of this machine's remotes,
whatever this machine's state, with the same options (`-n`, `-x`, `-t`, `-r`, `--urgent`,
`--driver`, `--wait-max`). Each machine's own config lists the machines it can reach and send work
to:

    remotes = burst, pup
    remote_start.burst = ~/Data/Code/runbooks/host-gcp-burst/start
    remote_env.pup = PATH=$HOME/.local/bin:$PATH

So the Mac may list burst and pup, pup only burst, and burst (a cloud machine that can see
neither) none. `--on` this machine itself runs here; a host not listed is a usage error. The run
waits in HOST's line; HOST is started first when it is stopped and has a `remote_start` command. A
HOST that neither answers nor can be started is an error (exit 125), never a quiet run here.

`cpuq hook` refuses a spec's work run as `cpuq run` when it is long (ten minutes or more here)
and would finish in half the time elsewhere, with each host's time by the spec's results and the
`cpuq submit` line. Heavy work typed over `ssh HOST` is pointed to `cpuq run --on HOST`.

Before the run starts there, the repo (git's top level, else the working directory) is copied to
`HOST:cpuq/worktrees/PROJECT/NAME-HASH` (PROJECT the repo's name, NAME its directory here, one
copy per repo or worktree here) with rsync, honoring `.gitignore` and leaving `.git` behind.
Each repo and worktree keeps its own copy there, so build caches stay warm between runs. A new
worktree's first copy starts, on a filesystem that clones (ZFS, btrfs), as a clone of the
project's most recently used copy there (a `cpuq run --on`'s or a `cpuq submit`'s: they share
the folder), so rsync sends only what differs: a Rig copy to burst took 5 s
instead of 33. Each file of the clone is dated 30 years back (each still apart from the others),
so rsync compares every file it ships, and an output another branch built there (a make or cargo
target) is older than every source and is built again; a cache that goes by content (zig's)
stays warm. The run
starts in the same subdirectory, with the same options; its output streams back, and its exit
status is cpuq's. A task's output file (`-n`) stays on HOST. `--return PATH` copies a path
(relative to the working directory) back afterwards, for a build's output; it repeats.

- **Gitignored paths a run needs** (a vendored tree its tests read, or `.git` for `git ls-files`)
  go too when listed in `.cpuqinclude` at the repo's top (beside `.gitignore`), a path a line
  (`#` comments), or given with `--include PATH`. A gitignored path not listed never ships, and never leaves the host's copy
  either, whether or not it's here: a build cache there (`.zig-cache`) stays warm from one run to
  the next. "Gitignored" is
  as git reads it (in a git repo, cpuq asks git): a file a `!` line brings back ships, and so does
  a tracked file a pattern happens to match.
- **`.git` ships as a git of the copy's own:** a `.git` directory with only git's parts of the
  repo's (objects, refs, packed-refs, config, info, shallow) and the worktree's own HEAD and index.
  A worktree's `.git` file, a path on this machine, becomes a repo there, and whatever else a
  repo keeps under `.git` (build stores, caches, notes) stays here. After the first copy rsync
  sends only what changed. `git ls-files`, `diff` and `log` work there; the first `git status`
  rehashes the files once, as their times differ.
- **The copy is read back** by each file's checksum after rsync makes it. rsync's own quick check
  (size and mtime) never sends again a file damaged there that kept both, so a run would go on
  using it. A file that differs is sent again and checked once more; if the copy still differs,
  the run doesn't start there (it fails with exit 125), and
  stderr names the files.
- **Tools under `~/.local`** are off the PATH of a command run over ssh, whose shell reads no login
  profile. `remote_env.HOST = PATH=$HOME/.local/go/bin:$PATH` in the config is exported on HOST
  before the run: shell assignments, expanded there.
- **The command must not reach outside the repo.** Absolute paths here (a scratch directory, a
  file in another checkout) do not exist on the other machine, and nothing writes back except
  `--return`.
- **The run stays tied to this cpuq.** It sends heartbeats down the connection, and the run on the
  other machine stops when they stop: when this cpuq is killed, or the connection is lost.
- **A machine that goes away mid-run** (a Spot VM reclaimed, the network down) is noticed: when
  the connection fails or the run dies by a signal and the machine then stops answering, HOST is
  started again and the run reruns there once; if HOST can't be brought back, the run ends with
  exit 125, and never falls back to this machine, since a run sized for HOST would swamp it.
- **Only work that doesn't need this OS** belongs on `--on`: the other machine may run Linux.
- The other machines need this version of cpuq, and ssh to them must work without a prompt.

### cpuq submit: a spec, and cpuq does the rest

    cpuq submit SPEC [-- ARGS] [--on HOST] [--env K=V]... [--note TEXT] [--replace | --again] [--max-wait S]
    cpuq jobs [--all]
    cpuq job [ID | last] [--wait [--max-wait S]] [--tail N] [--json] [--cancel]

A spec in the repo (`cpuq/matrix.json`) says what a job runs and needs, never where: the machine
that submits it picks the host. cpuq does the rest:

- **places it** among this machine's remotes (here when it has none) where it should finish
  first, by the spec's past results on each (another host's scaled by its CPUs when it has none
  there): a host that's up and free before a paid one that must be started, which is started only
  for work of ten minutes or more and only when clearly sooner. Work never seen goes to the first
  host with room, else the first stopped one, started. A host is passed over when it has too
  little memory for the job, or when a cache the spec `needs` is empty there. `--on HOST` names
  the host (one of the remotes, or this machine); a full host queues it;
- **runs a test suite as a job of task files** with `cpuq test SPEC` and a spec whose `tasks`
  command (after `setup`) writes a file per test into `$CPUQ_TODO`: the host runs them with
  `cpuq jobs run` (see [Jobs](#jobs-a-folder-of-task-files)), its agent sharing the machine, each
  task with `$CPUQ_CODE`, the copy's path. A worktree has one test at a time: the same code
  attaches to it, changed code replaces it. The failures are listed by name with their last line,
  and their files come back to `.cpuq/fail/`, which git ignores;
- **syncs a snapshot** of the work there with rsync, moving only what changed, then reads the copy
  back by checksum (as `cpuq run --on` does);
- **runs it, owned by that host,** as one task (`cpuq run -- cpuq cap ...`), so the agent's
  session, or this machine sleeping, doesn't stop it;
- **reports:** progress while it runs, then a verdict that names the code it tested.

```json
{
  "label": "proj:suite",
  "run": "./test/run \"$@\"",
  "setup": "zig build -j1",
  "time": "60m",
  "exclude": [".zig-cache", "zig-out"],
  "caches": { "PROJ_RESULTS_CACHE": "results" },
  "report": "test/results.jsonl",
  "return": ["test/results.jsonl"]
}
```

- **The last line is always a verdict,** with an exit code that is never the job's own:

  | verdict | exit | meaning |
  |---|---|---|
  | PASS | 0 | |
  | FAIL | 1 | the job's own code is in the line |
  | NOT STARTED | 2 | another snapshot of this worktree is running: `--replace` or `--again` |
  | RUNNING | 3 | `--max-wait` passed and the job still runs |
  | LOST | 69 | its host went away twice |
  | NOT RUN | 75 | no host could take it |
  | CANCELLED | 76 | |
  | OOM | 122 | |
  | TIMEOUT | 124 | |
  | CPUQ ERROR | 125 | |

  A FAIL lists the report's first failures (or the output's last lines) above the verdict.
- **Identity:** a resubmit of the same code, spec and arguments attaches to the job already
  running.
- **A worktree's jobs at once:** a host keeps up to `submit_slots` (3) copies of a worktree, and
  each job takes the first free one, so a gate's suite, corpus and matrix run side by side, not
  one after another. A copy never synced is first seeded on the host from the project's most
  recently synced copy (a free one if there is one; the filesystem's cheap copy where it has one),
  so the sync sends only what differs and build caches start warm. Its files are dated 30 years
  back, as a `cpuq run --on` copy's are. `submit_slots = 1` runs a
  worktree's jobs one after another on a single copy.
- **Where the time goes:** each job's supervisor log (`~/.local/state/cpuq/jobs/ID/supervisor.log`)
  has a line with each phase's seconds: start, waiting for a copy, packs, copy, check, marked.
- **Supervised:** killing `cpuq submit` never stops the job. `cpuq job ID --wait` follows it
  again.
- **Returned paths start empty:** each `return` path is emptied in the copy before the job runs, so
  what comes back is this job's alone.
- **What ran, by git:** once its copy is synced and checked unchanged, the job records `shipped`:
  the worktree's `head`, the `tree` of its content as it was (HEAD's with its changes and the
  untracked files git doesn't ignore), and `clean` (no changes, no untracked files: the tree is
  HEAD's). `cpuq job ID --json` includes it, finished or not, so a tool can bind a verdict to
  cpuq's own record of what ran.
- **The note:** `--note`, or else the worktree's branch, shows beside the label everywhere.
- **What travels:**
  - everything in the repo but `exclude` and `.git`;
  - `"git": true` ships the repo's git, git's own parts only (a worktree's too), for a job that
    runs `git ls-files` and the like;
  - a directory holding something like a credential (`.env`, `*.pem`, `id_*`) is refused;
  - `caches` live on the host, outside the copy, shared by all of a project's runs; `needs`
    names those that must already hold files there;
  - `deps` ship a sibling repo's tracked files.

#### Packs: tool versions on each host

A job can ask for the tools it runs with, by version, and each host keeps them in a store, as
mise does:

    ~/cpuq/packs/zig/0.17.0/          zig's own release, its sha256 checked
    ~/cpuq/packs/nexus/c28bef1a4d28/  built from that commit
    ~/cpuq/packs/nexus/latest -> c28bef1a4d28
    ~/cpuq/packs/rig/0.2.9/           built from the tag v0.2.9
    ~/cpuq/packs/rig/stable -> 0.2.9

```json
"packs": { "zig": "0.17.0", "rig": "latest" }
```

- **Versions:** `latest` is the default branch's head, `stable` the newest release tag
  (vX.Y.Z), `0.2.9` that tag, and a hash that commit, pushed or not. Each is resolved when the job
  is submitted, so the job's identity holds the exact version and `latest` moves as main does.
- **In the job:** each pack is on `PATH` and in `$NAME`, its binary (`$RIG`, `$ZIG`, `$GO`).
- **Installed once, by the first job that needs it,** inside that job's task, on its CPU, and
  under a lock per version: zig downloaded from ziglang.org, any other built from the source of
  its commit, which cpuq ships from its checkout here (`git archive`) when the host lacks it. A
  version never changes after; `latest` and `stable` are links to what they last were.
- **Recipes** say how to build each, in `~/.config/cpuq/packs.json` beside the config:

  ```json
  {
    "nexus": { "git": "https://github.com/shreeve/nexus", "local": "~/Data/Code/nexus",
               "build": "zig build -Doptimize=safe -j1", "bin": "bin/nexus",
               "packs": { "zig": "0.17.0" } },
    "rig":   { "git": "https://github.com/shreeve/rig", "local": "~/Data/Code/rig",
               "build": "zig build -j1 -Dnexus=\"$NEXUS\"", "bin": "bin/rig",
               "packs": { "zig": "0.17.0", "nexus": "latest" } }
  }
  ```

  A recipe's `packs` are installed first and are on its build's PATH. zig, go and bun need no
  recipe: their releases are downloaded (ziglang.org, go.dev, Bun's GitHub releases) and checked
  against the sha256 each publishes. One version of each pack per job: the job's own request wins
  over a recipe's.
- **On PATH** goes each pack's bin directory, so go brings gofmt.
- **`cpuq packs [--host HOST]`** lists a store; **`cpuq packs install rig@stable --host burst`**
  installs ahead of a job, in that host's line.

The full design, fields and rules are in [docs/SUBMIT.md](docs/SUBMIT.md).

### Big jobs on a cloud host

A test suite that takes an hour on a laptop takes minutes on a 96-CPU cloud machine, if its tests
go there as tasks, keep their caches warm, and clean up after themselves. This is how an agent
sends one:

    cpuq run --on burst --label proj:build -t 30m -- zig build -j1
    cpuq run --on burst --label proj:matrix -n 4000 -t 5m --return .zig-cache/fail -- sh -c '
      mkdir -p "$HOME/cpuq/caches/proj/results" .zig-cache/fail
      PROJ_RESULTS_CACHE=$HOME/cpuq/caches/proj/results ./test/one "$CPUQ_TASK" >.zig-cache/out-$CPUQ_TASK 2>&1
      rc=$?; [ $rc = 0 ] || cp .zig-cache/out-$CPUQ_TASK .zig-cache/fail/
      rm -f .zig-cache/out-$CPUQ_TASK; exit $rc'

- **The same label every time** (`proj:build`, `proj:matrix`): history is kept by label. Never a
  branch name.
- **One run per phase:** the build is one task; the tests are `-n` tasks, each on a CPU of its own,
  as many at once as the host's line gives. The copy persists between runs, so the second run
  finds the first's build.
- **Caches outside the copy.** Each worktree gets its own copy on the host, so a cache inside it
  is cold for every new branch. A path under `$HOME/cpuq/caches/PROJECT/`, outside every copy,
  is shared by all of a project's runs there. A results cache keyed by content then carries a
  pass from one branch to the next.
  - That's sound only when the key covers everything that decides a result: the inputs, the
    compiler's own hash, flags, and toolchain.
  - Entries are written by renaming into place, since runs share the cache.
  - Nothing evicts these caches yet, so watch their size (`du -sh ~/cpuq/caches/*` on the host).
- **A time limit on each task** (`-t`): a hung test otherwise keeps a billing machine busy, and its
  idle stop never comes.
- **Scratch deleted at the end**, after the status is saved, in the same command. The copy
  persists between runs, so whatever a run leaves stays on the host's disk. Paths are relative to
  the copy: never `rm -rf "$X/…"` with a variable that might be empty.
- **A short report:** the summary names the failed tasks with their last lines. `--return` brings
  more back; otherwise it stays on the host.
- **Run it as a background command.** It waits in the host's line, then runs as long as it
  takes, often past an agent tool's timeout.
- **Tools the host lacks** are built there, pinned, under the project's cache
  (`$HOME/cpuq/caches/PROJECT/tools/NAME-COMMIT`), so later runs find them already built, and no
  branch can swap in a different one.
  - Fetched by commit or checksum, never by a branch or tag that can move.
  - A private source is sent from here with `--include`: never put a token on the host to clone
    it.
- **Per-program limits** in a test runner come from `cpuq cap`, never from a watchdog listing
  every process.
- **Only work that doesn't need this OS** goes there.
- **The first run of a branch is cold:** it copies the repo and builds from scratch. Later runs
  move only what changed.

The host itself (burst here) is a Spot VM that starts on demand and stops itself after 10 idle
minutes. It has no cloud service account, so nothing running on it can act on the cloud
project. Copies and caches sit on a ZFS dataset with lz4 compression and a size quota.

## Cleaning up: cpuq clean

    cpuq clean [--dry-run] [--older AGE] [--host HOST]

A machine that takes jobs from others (`cpuq run --on`, `cpuq submit`) keeps their copies, so the next run of the same
worktree syncs only what changed, and keeps pack versions. Left alone they pile up: every agent
worktree ever sent there leaves a copy of up to tens of GB. `cpuq clean` removes them once
unused for `clean_after` (3 days); `cpuq record`, where it's installed, runs it every hour.

- **Copies of repos** (`~/cpuq/worktrees/PROJECT/…`) go by when a `cpuq run --on` run last ran in one or
  a submitted job last synced it, never while a job holds the copy's lock.
- **Submitted jobs' scratch** (`~/cpuq/tmp/ID`, their TMPDIR) that a killed job left behind.
- **Pack versions** go by when a job last used one, never one `latest` or `stable` names.
- **Submitted jobs' records** go a week after they ended.
- **Never anything a process is working in**, and never the caches (`~/cpuq/caches`), which are
  the jobs' own to bound.

`--dry-run` lists what would go and how much; `--older 1d` overrides the age.

## Named leases

    cpuq lease NAME [--slots N] [--label L] [--wait-max S] [--] CMD ARGS...
    cpuq lease NAME --host HOST [--slots N] [--label L] [--wait-max S] [--] CMD ARGS...
    cpuq lease NAME --host HOST --hold [--slots N] [--label L] [--wait-max S]

`cpuq lease NAME -- CMD` runs CMD holding NAME, a first-come, first-served lock on anything that
is not CPUs: a benchmark machine, a database, one build per cache. One holder at a time, or N with
`--slots N` (every caller of one lease passes the same N), strictly in order, and the kernel frees
the lease however its holder ends. `--wait-max S` gives up with 75. A lease checks no gates and
holds no CPU: work CMD runs goes under `cpuq run` inside it. A name is letters, digits, `.`, `_` and
`-`. CMD gets `CPUQ_LEASES`, the leases it runs inside, so a `cpuq lease` of the same name within it
starts at once.

**On another machine.** `--host HOST` holds the lease on HOST's cpuq and runs CMD here: cpuq
starts `ssh HOST cpuq lease NAME --hold`, waits for HOST to grant the lease, runs CMD, then closes
the connection, which gives the lease back. If cpuq dies or the connection drops, HOST's kernel
frees the lease, so a crashed pipeline never strands it. A script here that drives work on HOST
over ssh and work started on HOST itself then share one queue:

    cpuq lease bench --host buildbox --label app:bench -- ./bench-over-ssh.sh

HOST needs cpuq on the `PATH` of a non-interactive ssh command, and an ssh login that does not
ask for a password. A `cpuq lease NAME --host HOST` inside CMD starts at once, and a command on
HOST that carries CMD's `CPUQ_LEASES` sees the lease as its own. For timing on HOST, hold the lease
and drain HOST inside it:

    cpuq lease bench --host buildbox -- ssh buildbox 'cd repo && cpuq drain --label app:bench -- ./bench'

**Held by a script.** `--hold` with `--host` and no command takes the lease for a script that
holds it partway through its run. Once HOST grants the lease, cpuq prints
`held NAME@HOST ENTRY`, where ENTRY is the `CPUQ_LEASES` entry (`NAME@HOST=ID:PID`) that makes
runs inside see the lease as theirs, and holds it until its stdin closes or it dies. A newline
every 10 seconds down the connection is its heartbeat, so a hold whose connection drops without
closing ends within a minute (`CPUQ_HOLD_QUIET`). In any bash, 3.2 included:

    d=$(mktemp -d); mkfifo "$d/in" "$d/out"
    cpuq lease bench --host buildbox --hold <"$d/in" >"$d/out" & hold=$!
    exec 8>"$d/in"
    read -r word name entry <"$d/out"; rm -rf "$d"
    export CPUQ_LEASES="$entry${CPUQ_LEASES:+ $CPUQ_LEASES}"
    ...                                   # every step on buildbox, one lease
    exec 8>&-; wait $hold                 # give it back (or just exit)

Inside a hold of the same lease, `--hold` prints the entry already held and holds nothing, so a
script can take the lease without knowing whether its caller already has.

**Waiting for others.** `cpuq wait --label PATTERN [--max-wait SECONDS]` returns once no run
whose label matches (`PATTERN*` for a prefix) runs or waits, so a script can wait for another
session's work without polling `cpuq status`. `--max-wait` gives up with 75.

## The agent hook

    cpuq hook

`cpuq hook` is a Claude Code PreToolUse hook: it reads the tool call on stdin and, for a shell
command that would load the machine outside cpuq or misuse it, prints why and the command to run
instead, and exits 2, which refuses the command and shows the agent the fix. It refuses:

- a heavy command (`zig build`, `cargo build/test/…`, `make`, `ninja`, `cmake --build`,
  `xcodebuild`, `swift build/test`, `go build/test`, `pytest`, `gradle`, `mvn`, `bazel`,
  `buck2`) outside `cpuq run`, here or through `ssh HOST`, with the run that does it at one job
  (`cpuq run --label app:build -- zig build -j1`);
- a `cpuq run` whose command would start more than one job: a jobs count above 1, no limit
  (`make -j`, `-n auto`), or a tool that uses every CPU without its one-job option, with the fix
  "or split the work into tasks with -n M";
- a removed option (`--cores`, `--priority`, `--max-wait`, `--exclusive`, `--no-load-check`,
  `--qos`, `--opaque`) or `$CPUQ_CORES`, with the command rewritten;
- `--driver` on anything but a test runner.

Help, version, dry-run and listing invocations pass, as does any command marked `# cpuq: skip`,
everything inside a task, and everything when `CPUQ_HOOK=off`. It reads only the command's text;
anything it can't parse passes. Install it for every session in `~/.claude/settings.json`:

    {"hooks": {"PreToolUse": [{"matcher": "Bash",
       "hooks": [{"type": "command", "command": "cpuq hook"}]}]}}

## Where things live

Every machine is laid out the same way, the Mac you work on and the hosts it sends work to alike:

```
~/.local/bin/cpuq        the binary
~/.config/cpuq/config    the config, same shape; only lines about that machine differ
~/.local/state/cpuq/     cpuq's own records (history, samples, job logs, runs/: tasks' output)
~/cpuq/packs/            tools jobs ask for (zig, rig, nexus)
~/cpuq/worktrees/        copies of repos sent from another machine
~/cpuq/caches/PROJECT/   build caches shared across branches
~/cpuq/tmp/              scratch
/tmp/cpuq-UID/v2/        the pool: its lock, token files, runs and promises
```

Work started on a machine runs in its own checkout, not a copy: `~/cpuq/worktrees/` there holds
only what another machine sent it.

## Configuration

The config file is `CPUQ_CONFIG`, default `~/.config/cpuq/config`: `key = value` lines, each key
at most once. `#` starts a comment at the start of a line or after a space or tab, so a value may
hold one (`a#b`). Numbers are plain decimal digits, within a range the error gives. HOST in
`remote_start.HOST` and `remote_env.HOST` is one of `remotes`. An invalid line is an error naming
the file and line (exit 2); a removed key's error names what replaces it. A long-running cpuq
(the recorder) re-reads the file when it changes; an invalid edit keeps the settings in force and
says so.

| key | default | meaning |
|---|---|---|
| `budget` | every pool CPU | keep only the first this many CPUs of the pool (`CPUQ_BUDGET` overrides) |
| `cpus` | worked out | the pool's CPUs, in order, as a Linux CPU list (`12-19,2`) |
| `timeout` | 1h | each task's time limit when a run gives no `-t`; off: none |
| `weights` | none | project weights for sharing the pool, `rig:2 trig:1`; a project not named weighs 1 |
| `pressure_check` | on | hand out no CPU under memory pressure |
| `pressure_psi` | 10 | Linux: the `some avg10` percentage that counts as pressure |
| `min_available` | off | hand out no CPU while available memory is under this (e.g. `6G`) |
| `min_disk` | 5G | hand out no CPU while `$HOME`'s, the temp directory's or `~/cpuq`'s filesystem has less free than this; off turns it off |
| `cgroups` | on | Linux: run each `--driver` runner in a delegated systemd scope, its command in `job/`, for `cpuq cap` |
| `clean_after` | 3d | what jobs left on this machine (copies of jobs sent here, pack versions no link names, job records after a week) is removed once unused this long, by `cpuq record` hourly and `cpuq clean`; off keeps everything |
| `remotes` | none | ssh hosts this machine sends work to (`cpuq run --on`, `cpuq submit`), in order (commas or spaces) |
| `submit_slots` | 3 | copies of a worktree a submitted job may use on its host (1–8): so many of its jobs run at once |
| `submit_roots` | `~/Data/Code` | directories `cpuq submit` may ship and take `deps` from (commas or spaces) |
| `remote_start.HOST` | none | a command (run with sh) that starts HOST when it is stopped; it returns once ssh works |
| `remote_env.HOST` | none | shell assignments a job sent there exports on HOST, e.g. `PATH=$HOME/.local/go/bin:$PATH` |

## Environment and exit status

| variable | meaning |
|---|---|
| `CPUQ_DIR` | the state directory, an absolute path (default `/tmp/cpuq-UID`) |
| `CPUQ_CONFIG` | the config file (default `~/.config/cpuq/config`) |
| `CPUQ_BUDGET` | keep only the first this many CPUs of the pool, over the config file |
| `CPUQ_HISTORY` | the history file |
| `CPUQ_HOLD_QUIET` | seconds a `--hold` that has had heartbeats waits for the next before it ends (60) |
| `CPUQ_HOOK` | `off` turns `cpuq hook` off |
| `NO_COLOR` | draw `cpuq status` and `cpuq history` without color |
| `CPUQ_TASK`, `CPUQ_TASKS` | set for each task: which task it is (1 to M), and M |
| `CPUQ_CPU` | set for each task: the pool CPU it runs on |
| `CPUQ_OP` | set for each task: its run's ticket, which makes runs inside it nested |
| `CPUQ_ATTEMPT`, `CPUQ_ATTEMPTS` | set for each task: which try this is (1 first), and `-r` + 1 |
| `CPUQ_CGROUP` | set for a `--driver` runner on Linux: its delegated scope, for `cpuq cap` |
| `CPUQ_PROGRESS` | set for a submitted job's command: a file it may write `DONE TOTAL FAILING` to |
| `CPUQ_LEASES` | set for a lease's CMD: the named leases it runs inside, `NAME=ID` here and `NAME@HOST=ID:PID` on HOST |

| status | meaning |
|---|---|
| CMD's own | one task ran; its exit status passes through |
| 124 | one task reached its time limit (`-t`) |
| 0 or 1 | `-n M`: every task passed, or not |
| 128+N | the command was killed by signal N (cpuq dies by the same signal) |
| 75 | gave up waiting (`--wait-max`, `drain --max`, a `--hold` whose holder went away); the command never ran |
| 125 | cpuq itself failed (the state directory, `status --host`) |
| 126, 127 | the command is not executable, or not found |
| 2 | a usage error, an invalid config file, or a removed option, key or command |

`cpuq --version` prints the version.

## Removed

Each removed option, config key, spec field and command fails with one line naming its
replacement (exit 2), so a script or an agent's notes that still use one learn what to write
instead. The removed variables are simply not set; `cpuq hook` rewrites a `cpuq run` that uses
`$CPUQ_CORES`.

| removed | instead |
|---|---|
| `--cores K`, `--cores MIN-MAX` | one CPU per task; parallel work as `-n M` tasks, at most `-c C` CPUs at once |
| `$CPUQ_CORES`, `$CPUQ_CPUS`, `$CPUQ_TOKEN`, the make jobserver in `MAKEFLAGS` | one job per task (`zig build -j1`, `make`); `CPUQ_TASK` picks a task's work |
| `--priority high\|normal\|low` | `--urgent` for a run's first CPU; no low |
| `--max-wait` (run, lease) | `--wait-max` |
| `--exclusive` (run) | `cpuq drain -- CMD` |
| `--exclusive` (lease) | `cpuq lease NAME -- cpuq drain -- CMD` |
| `--no-load-check` | outside load is measured, never the load average |
| `--qos` | tasks run as they are |
| `--opaque` | every task holds its one CPU, in a container or not |
| `cpuq first` | `--urgent` |
| `cpuq start` | a free CPU goes to the first in the line |
| `cpuq cancel`, `cpuq stop` | `cpuq kill TICKET` |
| `cpuq pause`, `cpuq resume` | Ctrl-Z on a run, then `fg` |
| `cpuq note` | `cpuq run --note TEXT` |
| `cpuq doctor` | `cpuq status` flags runs over or under their CPUs, and work outside cpuq |
| `cpuq qos` | tasks run as they are |
| config `admit`, `target`, `settle`, `right_size`, `poll`, `aging`, `note`, `backfill`, `window_backfill`, `patience`, `lend`, `lend_after` | the pool hands out one CPU per task through the line (`weights` for shares) |
| config `exclusive`, `window_gap`, `window_lend` | `cpuq drain` |
| config `cpu_weights`, `affinity` | each task is pinned to its own CPU on Linux |
| config `load_check`, `load_margin` | outside load is measured |
| config `active_cap` | the pool is the CPUs online; `budget` or `cpus` narrows it |
| config `qos` | tasks run as they are |
| config `max_memory` | `cpuq cap --mem` |
| spec `cores` | a spec's job runs as one task |

## Limits

- Cooperative: cpuq hands out CPUs to what runs under it. Work not run under cpuq is seen only as
  outside load. On macOS a task that starts more threads than its one CPU takes CPUs from other
  tasks; `cpuq status` flags it, and the hook refuses the common cases.
- Per user: the state directory is `/tmp/cpuq-UID`, so two users on one machine each have their
  own pool, and neither sees the other's runs except as outside load.
- One machine: the state directory must be on a local file system with working `flock(2)`.
- One pool per `/tmp`: a container has its own `/tmp`, and with it its own pool. Containers
  share the host's pool only through a common `CPUQ_DIR` on a bind mount.
- On macOS, a task that outlives a SIGKILLed cpuq runs until the next run takes its CPU and kills
  it.

## More

- [AGENTS.md](AGENTS.md): how a coding agent should use cpuq.
- [HANDOFF.md](HANDOFF.md): working on cpuq itself: where things stand, building, testing, house rules.
- [docs/DESIGN.md](docs/DESIGN.md): how it works inside.
- [docs/PRIOR-ART.md](docs/PRIOR-ART.md): who else has tackled this, and what cpuq borrows or does differently.
- [CHANGELOG.md](CHANGELOG.md): what changed in each version, and why.
- [docs/RELEASING.md](docs/RELEASING.md): cutting a release.
- [test/stress/mix.py](test/stress/mix.py) and [test/stress/pool.py](test/stress/pool.py): a mixed
  load replayed with CPUs granted against busy each second, and three projects sharing the pool
  under SIGKILLs, checked from each task's log.
