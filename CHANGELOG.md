# Changelog

User-visible changes to cpuq. Each version's section is its release notes.

## 0.4.0 — 2026-10-05

- History: every job is recorded as it queues, starts and ends, outside
  `/tmp` so it outlives a reboot. `cpuq history [--label X] [--limit N]
  [--json]` lists how long jobs waited and ran, the cores they kept busy
  (their CPU time, from the kernel) against their grant, and how they ended,
  including jobs lost to a killed cpuq or a restart; a summary says how to
  size `--cores`.
- On a terminal, `cpuq status` and `cpuq history` draw boxed tables in
  color: the gate and memory by state, holders using under half their grant
  in yellow, and cores held per project. `cpuq status --watch` redraws in
  place.
- `cpuq status` names the busiest processes outside cpuq when they add up to
  a core or more, or the gate is closed (`--json`: `outside`).
- Waiters get an ETA from the history's typical run times (`--json`: `eta`).
- `cpuq status --host HOST` shows another machine's queue over ssh;
  `--host local --host pup` shows both.
- A program that waits without `--max-wait` and without a terminal is told
  once that its own timeout may end the wait first.
- Cpuq.app (in `app/`, macOS 14+): a menu-bar meter, the chip filling a cell
  per quarter of the budget in use, with a menu of what runs, waits and
  holds leases, and a live view in Terminal.

## 0.3.0 — 2026-10-05

- Named leases: `cpuq lease NAME -- CMD` is a first-come, first-served lock
  on anything that is not cores (a benchmark machine, a database), with
  priorities, aging, `--max-wait`, `cpuq status`, and holds the kernel frees
  however their holder ends. `--slots N` lets N hold it at once. CMD gets
  `CPUQ_LEASES`, so a lease of the same name inside it starts at once.
- `cpuq lease NAME --host HOST -- CMD` holds the lease on HOST's cpuq over
  ssh while CMD runs here; ending, crashing or losing the connection gives it
  back. Pipelines that drive another machine and that machine's own work
  share one queue.
- `cpuq wait --label PATTERN` blocks until no matching job holds or waits.
- `cpuq status` lists the named leases with their holders and waiters, and
  `--json` adds `leases`.
- `--max-wait 0` takes what is free now and gives up at once otherwise; it
  used to give up before trying.

## 0.2.0 — 2026-10-05

- Elastic grants: `cpuq run --cores MIN-MAX` starts as soon as MIN cores
  are free and takes up to MAX of what is free, so cores no longer sit idle
  while a job waits for a fixed count. `CPUQ_CORES` and the make jobserver
  carry the grant. A wide request leaves the next waiter's minimum free.
  `--cores K` still asks for exactly K.
- `cpuq status` shows the cores each holder actually uses beside its grant,
  measured over its whole process tree (the short-lived compilers and test
  processes it starts included), and each waiter's request as MIN-MAX.
  `--json` adds `using` to holders and `max` to waiters.

## 0.1.0 — 2026-10-05

The first release: one binary for macOS (arm64, x86-64) and Linux (x86-64,
arm64, static), no daemon.

- `cpuq run [--cores K] [--priority high|normal|low] [--exclusive] [--label
  TEXT] [--max-wait S] -- CMD` waits its turn for K cores out of a
  machine-wide budget (default: the active cores minus 2), then runs CMD in
  the foreground: stdio inherited, signals passed on the way a shell does,
  the exit status passed through.
- Every hold is a `flock(2)` on a file in `/tmp/cpuq-UID`, so the kernel
  frees it when its holder dies, however it dies. A SIGKILLed cpuq leaves its
  cores with the running command until the command ends.
- Strict order within a priority, no backfill, and aging that promotes a
  waiter one class per 10 minutes, so nothing starves. `--exclusive` drains
  the machine for a benchmark and holds it for the length of the command.
- Gates on memory pressure and a load safety valve with hysteresis, so
  waiters never stampede into a lagging load average.
- CMD gets `CPUQ_CORES`, a GNU make jobserver in `MAKEFLAGS` (make 3.81 and
  4.x), and a scheduling class from its priority: macOS QoS, Linux nice.
- `cpuq status [--json]`, `cpuq budget`, `cpuq qos`.
- Install with `install.sh` or `brew install shreeve/tap/cpuq`.
