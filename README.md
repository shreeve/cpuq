# cpuq

A machine-wide CPU core queue. Heavy jobs (builds, test suites, benchmarks)
started from many shells, sessions and agents wait their turn for a number of
cores out of a shared budget, then run in the foreground holding them. One
binary, no daemon: every hold is a `flock(2)` on a file in a state directory,
so the kernel releases it when its holder dies, however it dies.

## Install

Zig 0.17.0:

    zig build install -Doptimize=ReleaseSafe -p ~/.local

`zig build` writes `bin/cpuq` in the checkout; `zig build test` runs the unit
tests and `test/run.sh` the end-to-end tests against `bin/cpuq`.

## Usage

    cpuq run [--cores K] [--priority high|normal|low] [--exclusive] [--label TEXT]
             [--max-wait SECONDS] [--no-load-check] [--qos none] -- CMD ARGS...
    cpuq status [--json]
    cpuq budget
    cpuq qos

`cpuq run` waits its turn, then runs CMD in the foreground: stdin, stdout and
stderr are inherited (a terminal stays a terminal), signals are forwarded and
the exit status passes through (a command killed by signal N kills cpuq with
the same signal, so the shell sees 128+N and a `^C` stops a shell loop).
K defaults to 2 and is clamped to the budget. `--exclusive` takes the whole
budget: it waits at the head of the queue for running work to drain and
blocks everything behind it while it runs. While queued, cpuq prints a line
to stderr about once a minute (who it waits behind), and `--max-wait` gives
up with status 75.

CMD gets `CPUQ_CORES=K`, `CPUQ_TOKEN` (its lease) and a GNU make jobserver.
`CPUQ_CORES` is advisory: tools use every core unless told otherwise, so pass
it on: `zig build -j$CPUQ_CORES`, `cargo build -j$CPUQ_CORES`, `ninja
-j$CPUQ_CORES`. For make, run plain `make`: it takes its job slots from the
jobserver in MAKEFLAGS (below). `zig build -jN` limits the build runner to N
concurrent steps; it has no jobserver client and does not pass `-j` on to the
compiler processes it starts.

A `cpuq run` inside a running one (a valid `CPUQ_TOKEN` in its environment)
starts at once within its parent's grant and passes everything through
untouched (it execs CMD). If the token's lease is no longer held, the
variable is ignored and the run queues normally.

`cpuq status` shows the state directory, the budget, the held and free cores,
the load, memory pressure and the admission gate, every holder (pid, the
command's pid, label, command, cores, since) and every waiter (order,
priority, waiting time). A holder marked `*` is a lease whose cpuq is gone
while its command still runs and holds the cores. `cpuq budget` prints the
budget in force; `cpuq qos` prints the calling process's scheduling class.

### Quiet windows

A benchmark that needs the machine to itself runs under `--exclusive`: it
waits for running work to drain, nothing else is admitted while it runs, and
the window ends when it exits, however it exits. Its own builds and helpers
run inside it as nested runs. A window that spans several commands wraps
them in one: `cpuq run --exclusive --label bench -- ./bench.sh`, or an
interactive `cpuq run --exclusive -- $SHELL`. cpuq has no separate hold
command: a hold not tied to a running process would need a file that outlives
its owner, which is the thing cpuq exists to avoid.

### Environment

| variable | meaning |
|---|---|
| `CPUQ_DIR` | the state directory (an absolute path) |
| `CPUQ_BUDGET` | the budget in cores, over the config file |
| `CPUQ_CONFIG` | the config file, default `~/.config/cpuq/config` |
| `CPUQ_CORES` | set for CMD: the cores it holds |
| `CPUQ_TOKEN` | set for CMD: its lease, which makes runs inside it nested |

### Budget and configuration

The budget is the cores cpuq hands out: `CPUQ_BUDGET`, else `budget` in the
config file, else the active core count minus 2 (8 on a 10-core Mac), leaving
a reserve for the owner's own work. It is capped by the cores active now and
by the machine's core count. The config file is `CPUQ_CONFIG`, default
`~/.config/cpuq/config`, with `key = value` lines (`#` comments):

| key | default | meaning |
|---|---|---|
| `budget` | active cores - 2 | cores to hand out |
| `active_cap` | on | cap the budget by the cores active now |
| `load_check` | on | the load safety valve (below) |
| `load_margin` | 4 | the valve trips above budget + margin |
| `pressure_check` | on | admit nothing under memory pressure |
| `pressure_psi` | 10 | Linux: `some avg10` percentage that counts as pressure |
| `qos` | on | map priorities to scheduling classes |
| `aging` | 600 | seconds of waiting per one-class promotion; 0 turns it off |
| `poll` | 0.5 | seconds between the head's re-checks |
| `note` | 60 | seconds between "waiting" lines |

An invalid line is an error naming the file and line.

### Priority and scheduling class

Waiters are served high before normal before low, in arrival order within a
class. A waiter is promoted one class per `aging` seconds of waiting, so low
is never starved. The command also runs in a scheduling class: on macOS,
high leaves it unchanged, normal runs it at utility QoS and low at background
QoS (on Apple Silicon background work stays on the efficiency cores, with
throttled I/O), set with `posix_spawnattr_set_qos_class_np`; on Linux, nice 0,
5 and 15. Children inherit it. `--exclusive` runs (they time benchmarks) and
`--qos none` never change it.

### The machine gates

The head of the queue admits nothing while:

- the OS reports memory pressure: macOS `kern.memorystatus_vm_pressure_level`
  at 2 (warn) or more; Linux `/proc/pressure/memory` `some avg10` at
  `pressure_psi` or more, when the file exists (`pressure_check = off`);
- the load safety valve is closed (`load_check = off`, or `--no-load-check`
  per run). The budget is what schedules work; the valve only guards against
  load from outside cpuq. It trips when the 1-minute load exceeds budget +
  `load_margin`, reopens only after the load has stayed at or under the
  budget for 30 seconds, and while the load is above the budget it admits at
  most one job per 10 seconds, so waiters never stampede into a lagging load
  average.

The budget is capped by the cores active now (macOS `hw.activecpu`, Linux the
process's CPU affinity). On Apple Silicon `hw.activecpu` does not appear to
drop under thermal throttling, so this cap is a safeguard, not a thermal
signal.

### GNU make jobserver

CMD gets a jobserver: a pipe holding K-1 tokens whose descriptors it
inherits, and MAKEFLAGS with ` -j --jobserver-auth=R,W --jobserver-fds=R,W`,
the form GNU make hands its own sub-makes (make 4.2 and later read
`--jobserver-auth`, macOS's /usr/bin/make 3.81 reads `--jobserver-fds`).
Existing MAKEFLAGS flags are kept; their `-j` and jobserver options are
replaced. So `make` under `cpuq run --cores 3` runs at most 3 recipes at
once, with GNU make 3.81 and 4.4 alike, and so does `make -j` with 3.81.
GNU make 4.x lets a `-j` on its own command line override any jobserver (it
warns "-jN forced in submake"): `make -jN` then runs N at once, and a bare
`make -j` is unlimited. A nested run leaves MAKEFLAGS as it is.

## Design

**State directory.** `CPUQ_DIR`, else `/tmp/cpuq-UID` with `/tmp` resolved
(`/private/tmp` on macOS), a literal path so that every session agrees on it
whatever its `TMPDIR`. If it cannot be created or written, cpuq fails; it
never falls back to another directory.

    admission.lock      the admission lock
    seq                 the last ticket number
    valve               the load valve's state
    queue/P-NNNNNNNNNN  one ticket per waiter (P: 0 high, 1 normal, 2 low)
    tokens/NNNN         one file per core of the machine
    leases/NNNNNNNNNN   one record per running job (.x: exclusive)

Only `flock(2)` is used, never fcntl locks: an flock belongs to the open file
description, survives fork and exec, and is not dropped when some other
descriptor of the file closes.

**The queue.** A waiter creates its ticket under a temporary name, locks it
exclusively, writes its record and renames it into place, all under the
admission lock, and holds that lock while it waits. Waiters are ordered by
class (priority after aging), then ticket number. A waiter that is not at
the head blocks on the ticket just ahead of it (a blocking shared flock
that returns when that waiter is admitted or dies), so a long queue costs
nothing. Only the head polls, every `poll` seconds: under the admission lock
it reads the gates and, if they are open, tries to take its k tokens, all of
them or none (on failure it releases what it took). Since only the head
takes tokens, two waiters can never each hold part of what they need.

**Fairness.** Strict order, no backfill: the head waits for its k cores and
nothing behind it overtakes it, even a small job that would fit now. Without
run-time estimates any backfill could delay the head. `--exclusive` is k =
the whole budget at the head (and no admission while an exclusive lease is
alive). Lowering the budget below what is held only stops admissions.

**Holds.** A job's tokens and its lease are exclusively flocked, and the
command inherits those descriptors (they are not close-on-exec; every other
descriptor is). If cpuq itself is SIGKILLed, the command and its children
keep the cores until they exit; `cpuq status` shows such a lease with its
holder gone. When the command exits, cpuq unlocks every token (`LOCK_UN`
releases the lock for every process sharing the descriptor) before closing
it, so a descendant that kept a descriptor (a build server, a `nohup`'d
helper) does not keep the cores.

**Dead files.** Any file whose lock can be taken has no holder. Probes take a
shared lock, and only under the admission lock, so a probe never makes a
free token look busy to the head; a dead ticket or lease found this way is
removed (after checking that the path still names the probed inode). Token
files are never removed. Nothing depends on pids: they are recorded for
`cpuq status` only.

**Kill and reboot.** A SIGKILLed waiter's ticket lock is released by the
kernel: the waiter behind it wakes at once, and the dead ticket is removed
by the next scan. A SIGKILLed job (cpuq and its command) releases its tokens
the moment the last process holding them exits. A reboot releases
everything; the leftover files are dead and are cleaned as they are found.

**Signals.** While the command runs, cpuq forwards HUP, INT, QUIT, TERM, USR1
and USR2 that a process sends it (`kill -INT <cpuq>` reaches the command).
A signal from the terminal driver (`^C`, `^\`, hangup) has no sending pid
(`si_pid` 0); the terminal already sent it to the whole foreground process
group, the command included, so cpuq does not send it again (as with
`system(3)`). A process that signals the whole process group (`kill -INT
-PGID`) has a pid, so the command receives such a signal twice.

## Limits

- Cooperative only: cpuq holds cores by convention. Work that does not run
  under cpuq is seen only through the load valve, and a job uses as many
  cores as its tools take; `CPUQ_CORES` and the jobserver are how a job
  keeps to its grant.
- `zig build` has no jobserver client; pass `-j$CPUQ_CORES`. A `-j` on GNU
  make 4.x's command line overrides the jobserver.
- A descendant that outlives a SIGKILLed cpuq keeps the cores until it exits.
- One machine: the state directory must be on a local file system with
  working `flock(2)`.
