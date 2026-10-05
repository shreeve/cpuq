# Changelog

User-visible changes to cpuq. Each version's section is its release notes.

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
