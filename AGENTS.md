# cpuq for agents

This machine is shared by several agent sessions. Run every heavy command (a build, a test suite,
a benchmark, a fuzzer, anything that keeps more than one CPU busy for more than ~10 seconds)
under cpuq. Not git, grep, editors or quick one-off commands.

## Shape

    cpuq run --label PROJECT:TASK [--cores N | --cores MIN-MAX] -- CMD ARGS...

cpuq sets `$CPUQ_CORES` (the cores granted) for CMD, not for your shell. Pass it inside
`sh -c` with SINGLE quotes; your shell must not expand it (it is unset there, and `make -j` with
nothing after it has no limit):

    cpuq run --label app:build --cores 2-6 -- sh -c 'zig build -j"$CPUQ_CORES" test'
    cpuq run --label app:build --cores 2-6 -- make         # plain make: it uses cpuq's jobserver
    cpuq run --label rs:build  --cores 2-6 -- sh -c 'cargo build -j "$CPUQ_CORES"'
    cpuq run --label py:test   --cores 2-6 -- sh -c 'pytest -n "$CPUQ_CORES"'
    cpuq run --label sw:build  --cores 2-6 -- sh -c 'swift build -j "$CPUQ_CORES"'
    cpuq run --label go:build  --cores 2-6 -- sh -c 'go build -p "$CPUQ_CORES" ./...'
    cpuq run --label app:unit  --cores 1   -- ./single_threaded_tests

A bare `zig build` uses every CPU: always give it `-j"$CPUQ_CORES"`.

Work that runs inside a container or VM (`incus exec`, `docker exec`) is invisible to cpuq's
measurements: add `--opaque` and a fixed `--cores`, so it counts at its whole grant.

## Cores

- Same label, run before: omit `--cores`; its history sizes the job.
- Single-threaded: `--cores 1`. Parallel: a range, `--cores 2-6`.
- Never more than half the CPUs; never a big fixed count "to be safe".
- One job per phase: compile with `--cores 2-6`, then test with `--cores 1`.

## Labels

`project:task`, lowercase, the same on every run (`app:test`, `db:build`). No run ids, dates or
branch names: history sizes jobs and estimates waits by label.

## Waiting

- Usually under a second; can be minutes. Your tool's timeout may kill the wait: run long jobs
  in the background, or pass `--max-wait SECONDS` below your tool's timeout.
- `--max-wait` gives up with exit 75, and the command never ran. Rerun it later; never retry in
  a loop.
- `cpuq status --json` shows the queue and each waiter's `eta` in seconds.
- `cpuq wait --label 'proj:*' --max-wait 600` waits until no job with a matching label runs or
  waits.

## Another machine

Where `spill` is configured (`grep spill ~/.config/cpuq/config`), add `--spill` to any job
that doesn't need this OS (builds, test suites of portable code):

    cpuq run --spill --label app:build --cores 2-6 -- sh -c 'zig build -j"$CPUQ_CORES" test'

It runs here while there's room; when this machine is full it runs on a spill host with room,
starting a stopped cloud machine if need be, with the repo copied there by rsync. Its output and
exit status come back as usual. The command must stay inside the repo: absolute paths here (a
scratchpad file) don't exist there. `--return zig-out` copies a build's output back. Gitignored
inputs the job needs (a vendored tree, `.git`) go in the repo's `.cpuq-spill`, a path a line, or
`--ship PATH`; environment variables set here don't travel, so set them inside the command. To send a job
to a given machine whatever the state here, use `--spill-to HOST` instead (it starts a stopped
cloud machine): for work too big for this one, not to skip its queue.

Without `spill` configured, send work by hand when this machine is full (anyone waiting, or the
1-minute load above its CPU count) and another has room (`cpuq status --host HOST`), through
that machine's own cpuq:

    ssh HOST 'cd repo && cpuq run --label app:build --cores 2-8 -- sh -c "make -j\"\$CPUQ_CORES\""'

Never run it there outside cpuq: its queue can't share what it doesn't see.

## Test runners

A runner that starts many programs limits each with `cpuq cap` rather than watching them itself
(never a `ps` of the whole machine per program):

    cpuq cap --mem 2G --time 120s --output 1M -- PROGRAM ARGS...

It exits with PROGRAM's status, or 122 (memory), 124 (time) or 121 (output) when it stopped it.
stdout and stderr must be files for `--output`.

## Exit status

- CMD's own status passes through; 128+N: CMD was killed by signal N.
- 75: gave up waiting (`--max-wait`, or `cpuq cancel`); CMD never ran.
- 125: cpuq itself failed. 126/127: CMD is not executable / not found. 2: usage or config error.

## Timing (benchmarks only)

`--exclusive` drains the machine and holds it alone; use it only for real timing. If cpuq warns
that work outside the window is using CPUs (stderr, and `noise` in `cpuq history --json`), the
timings may be noisy: rerun them. Where
`exclusive = off`, it runs as an ordinary job (it says so on stderr) and your numbers are not
quiet; `cpuq status --no-usage | grep 'exclusive runs are off'` finds out first. Time on a
machine that allows it:

    ssh buildbox 'cd repo && cpuq run --exclusive --label app:bench -- ./bench'

## The hook

Where `cpuq hook` is installed (Claude Code's PreToolUse hook), a heavy command run outside cpuq,
or a misused `cpuq run`, is refused with the corrected command: run that instead. Mark a command
`# cpuq: skip` only when it truly must run as it is.

## Don't

- `--priority high` (except a release gate a human is waiting on), `--no-load-check`,
  `--qos none`.
- `cpuq first`/`start`/`cancel`/`pause`/`resume`/`stop` on jobs you did not start; they act on
  anyone's. Never `start` or `first` your own job to skip the queue.
- Kill a waiting cpuq to retry it, or wrap a whole session or interactive shell in `cpuq run`.

A `cpuq run` inside a running one starts at once, within the parent's grant: its `--cores` is
ignored and `$CPUQ_CORES` stays the parent's. More: [README.md](README.md).
