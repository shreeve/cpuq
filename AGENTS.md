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
inputs the job needs (a vendored tree, `.git` for `git ls-files`) go in the repo's `.cpuq-spill`,
a path a line, or `--ship PATH`. `.git` ships trimmed to git's own parts, a worktree's included.
Environment variables set here don't travel, so set them inside the command. To send a job to a
given machine whatever the state here, use `--spill-to HOST` instead (it starts a stopped cloud
machine): for work too big for this one, not to skip its queue.

Without `spill` configured, send work by hand when this machine is full (anyone waiting, or the
1-minute load above its CPU count) and another has room (`cpuq status --host HOST`), through
that machine's own cpuq:

    ssh HOST 'cd repo && cpuq run --label app:build --cores 2-8 -- sh -c "make -j\"\$CPUQ_CORES\""'

Never run it there outside cpuq: its queue can't share what it doesn't see.

A big job for a cloud host, run in the background:

    cpuq run --spill-to burst --label proj:matrix --cores 8-32 --return .zig-cache/gate.log -- sh -c '
      : >.zig-cache/gate.log; mkdir -p "$HOME/cpuq-spill/c/proj/results"
      zig build -j"$CPUQ_CORES" >>.zig-cache/gate.log 2>&1 &&
      PROJ_RESULTS_CACHE=$HOME/cpuq-spill/c/proj/results timeout 90m ./test/run -j "$CPUQ_CORES" >>.zig-cache/gate.log 2>&1
      rc=$?; grep -E "^(fail|FAIL)" .zig-cache/gate.log | head -20; tail -2 .zig-cache/gate.log
      rm -rf .zig-cache/proj-test; exit $rc'

- **The label** stays the same on every run, never a branch name.
- **The cores:** at most a third of the host's CPUs.
- **Caches** go under `$HOME/cpuq-spill/c/PROJECT/`, outside the per-worktree copy, so every
  branch shares them.
- **A time limit** inside the command.
- **Scratch** is deleted at the end, with relative paths.
- **Tools the host lacks** are pinned by commit under that cache, never fetched unpinned.

More: README's "Big jobs on a cloud host".

## Submitting a spec

Where a repo keeps specs in `cpuq/*.json`, heavy work goes through them:

    cpuq submit cpuq/suite.json [-- TEST FILTER]

- **Run it in the background.** You're notified when it ends.
- **The last line is the verdict, and the exit status matches it:**
  - PASS 0 and FAIL 1 are your code; the failures are printed above the verdict.
  - TIMEOUT and OOM are limits, often a hang or a leak in your change: `cpuq job ID --tail 100`.
  - NOT RUN, LOST, CANCELLED and CPUQ ERROR aren't your code: follow the hint on the line.
- **Read a log** with `cpuq job ID --tail N`, never by cat.
- **After compaction:** `cpuq jobs`, then `cpuq job ID --wait` in the background.
- **Resubmitting:** the same code attaches to the job already running. After edits use
  `--replace`. For a repro beside a full run, use `--again`.
- **Tools a spec names in `packs`** (zig, rig, nexus at a version) are on the job's PATH there;
  `cpuq packs --host burst` lists what a host has.
- **Never** edit or write specs, add -j, --cores, hosts or rm -rf to them, loop on a verdict
  that isn't about your code, or cancel another worktree's job.

## Test runners

A runner that starts many programs limits each with `cpuq cap`, never with a watchdog that lists
every process (`ps`):

    cpuq run --label proj:test --cores 2-6 -- sh -c './test/run -j "$CPUQ_CORES"'
    cpuq cap --mem 2G --time 120s --output 1M --pids 512 -- PROGRAM ARGS...   # in the runner, per program

- **cap is a limit, not a queue:** it takes no cores, and the hook judges what it runs as if typed
  alone.
- **Put it inside `cpuq run`, never around it:** its `--time` would count the time spent queued.
- **Exit:**
  - PROGRAM's own status, or 128+N if signal N killed it;
  - 122 memory, 124 time (as GNU timeout) or 121 output when cap stopped it, each with one stderr
    line;
  - 2 on bad usage, before PROGRAM runs.
- **`--output`** needs stdout and stderr redirected to files or /dev/null. A pipe (`| tee`) exits
  2: don't count that as a test failure.
- **`--mem` on Linux inside a job** counts page cache and tmpfs too, so a limit tuned on the Mac
  can trip on Linux.

A runner that knows its test count reports progress, so status shows how far it is and the time
left (`4210/12629 33% · 3 failing · ~9m left`): one line, `DONE TOTAL FAILING`, written whole at
most once a second and once at the end:

    printf '%d %d %d\n' "$done" "$total" "$failing" > "$CPUQ_PROGRESS.tmp" && mv "$CPUQ_PROGRESS.tmp" "$CPUQ_PROGRESS"

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
