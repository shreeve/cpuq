# cpuq for agents

Working on cpuq itself? Read [HANDOFF.md](HANDOFF.md) first. A change to how the pool shares
CPUs (the line in src/pool.zig, the stop, drain and give-back in src/op.zig) updates the Lean
model in `formal/` and passes its search before release.

This machine is shared by several agent sessions. Run every heavy command (a build, a test suite,
a benchmark, a fuzzer, anything that keeps a CPU busy for more than ~10 seconds) under cpuq. Not
git, grep, editors or quick one-off commands.

## Shape

    cpuq run --label PROJECT:TASK [-n M] [-x K] [-t T] [-r N] -- CMD ARGS...

Every task gets one CPU. `cpuq run -- CMD` is one task: CMD runs with your terminal, and its exit
status is cpuq's. Run it at one job:

    cpuq run --label app:build -- zig build -j1
    cpuq run --label app:build -- make                    # no -j
    cpuq run --label rs:build  -- cargo build -j 1
    cpuq run --label go:build  -- go build -p 1 ./...
    cpuq run --label sw:build  -- swift build -j 1
    cpuq run --label py:test   -- pytest                  # no -n
    cpuq run --label app:unit  -- ./single_threaded_tests

A bare `zig build`, `cargo`, `go build` or `swift build` starts a job per CPU of the machine, all on
one task's CPU. Always give the one-job option. Linux pins a task to its CPU; macOS can't.

## Parallel work: -n M tasks

Split parallel work into tasks. `-n M` runs CMD M times, each task on a CPU of its own, as many at
once as the pool gives. Each gets `CPUQ_TASK` (1 to M) and `CPUQ_TASKS` to pick its piece. cpuq sets
them for CMD, not for your shell: use `sh -c` with SINGLE quotes.

    cpuq run --label app:test -n 16 -- sh -c './test/shard "$CPUQ_TASK" "$CPUQ_TASKS"'
    cpuq run --label app:fuzz -n 500 -t 2m -- sh -c './fuzz "$(sed -n "${CPUQ_TASK}p" cases.txt)"'

- Each task's output goes to a file of its own. The summary at the end names the failed tasks with
  their last lines, and the folder. Exit 0 when every task passed, else 1.
- `-x K`: K tasks share each CPU. Only for work that mostly waits (network, sleep, a server):
  K = 1 + time waiting ÷ time computing. Never for computing.
- `-t T`: each task's time limit, about ten times its usual time (`-t 30s`; default 1h).
- `-r N`: try a failed task up to N more times (`CPUQ_ATTEMPT` says which try). Flaky work only.
- `-c C`: hold at most C CPUs, or `-c 25%`. Usually leave it out.
- One run per phase: build with one task, then test with `-n M`.

## Labels

`project:task`, lowercase, the same on every run (`app:test`, `db:build`). No run ids, dates or
branch names: history is kept by label.

## Waiting

- Usually under a second; can be minutes. Your tool's timeout may kill the wait: run long jobs
  in the background, or pass `--wait-max SECONDS` below your tool's timeout.
- `--wait-max` gives up with exit 75, and the command never ran. Rerun it later; never retry in
  a loop.
- `cpuq status` shows who holds which CPU and why each waiter waits; `--json` for programs.
- `cpuq wait --label 'proj:*' --max-wait 600` waits until no run with a matching label runs or
  waits.
- `--urgent` puts a run's first CPU ahead of the line: only for a rebuild a human is waiting on.

## Timing

    cpuq drain --label app:bench --max 10m -- ./bench

Every run gives its CPUs back as its tasks end; then CMD runs alone, unpinned, and the CPUs go back
when it ends. `--max` gives up with exit 75. While it waits, a task whose `-t` ends before the
drain could start runs on its idle CPUs (backfill): a short `-t` gets work through. It stops
everyone else: only for real timing.

## Another machine

`cpuq run` always runs here. `--on HOST` sends it to HOST, one of this machine's remotes
(`grep remotes ~/.config/cpuq/config`), for work too big for this machine, not to skip its line:

    cpuq run --on burst --label app:build -- zig build -j1
    cpuq run --on burst --label app:test -n 64 -t 10m -- sh -c './test/shard "$CPUQ_TASK" 64'

The repo is copied there by rsync, the run waits in HOST's own line, a stopped cloud machine is
started first, and its output and exit status come back as usual. The copy persists, so the second
run finds the first's build. The command must stay inside the repo: absolute paths here (a
scratchpad file) don't exist there. `--return zig-out` copies a build's output back. Gitignored
inputs the job needs (a vendored tree, `.git` for `git ls-files`) go in the repo's `.cpuqinclude`
(beside `.gitignore`, a path a line), or `--include PATH`. `.git` goes trimmed to git's own parts,
a worktree's included. Environment variables set here don't travel, so set them inside the command.
A task's output file stays on HOST.

Never run work on another machine outside cpuq (`ssh HOST 'make'`): its line can't share what it
doesn't see.

- **The label** stays the same on every run, never a branch name.
- **Caches** go under `$HOME/cpuq/caches/PROJECT/`, outside the per-worktree copy, so every
  branch shares them.
- **A time limit:** `-t` on every run there.
- **Scratch** is deleted at the end, with relative paths.
- **Tools the host lacks** are pinned by commit under that cache, never fetched unpinned.

More: README's "Big jobs on a cloud host".

## Submitting a spec

Where a repo keeps specs in `cpuq/*.json`, heavy work goes through them:

    cpuq submit cpuq/suite.json [--on HOST] [--note "#PR branch"] [-- TEST FILTER]

- **A spec with `tasks`** (a test suite run as a job of task files) goes through
  `cpuq test SPEC [--on HOST] [-- TEST FILTER]` instead; everything below holds for it too, and
  its failed tests come back to `.cpuq/fail/`.
- **Run it in the background.** You're notified when it ends.
- **The spec comes from your own worktree** (`cpuq/*.json` there): it ships the repo it sits in.
- **The host:** this machine's remotes, where it should finish first; `--on HOST` picks one
  (or this machine). A spec names no host.
- **`--note "#PR branch"`** shows beside the label everywhere; without it, the branch.
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
- **Never** edit or write specs, add -j, hosts or rm -rf to them, loop on a verdict that isn't
  about your code, or cancel another worktree's job.

## Test runners

A runner whose tests are independent runs them as tasks:

    cpuq run --label proj:test -n "$(./test/count)" -t 2m -- sh -c './test/one "$CPUQ_TASK"'

A runner that starts a `cpuq run` per test (swarm, `test/run`) runs under `--driver`: it holds no
CPU, and each run it starts takes its own. Limit each program it starts with `cpuq cap`, never with
a watchdog that lists every process (`ps`):

    cpuq run --label proj:test --driver -- ./test/run
    cpuq run --label proj:case -- cpuq cap --mem 2G --time 120s --output 1M --pids 512 -- PROGRAM ARGS...   # in the runner

- **`--driver` is for a test runner only.** A build under it holds no CPU; the hook refuses it.
  One exception: `rig build` with `RIG_UNIT_LAUNCHER='cpuq run --'` set on it, so each unit's
  compile takes a CPU of its own (`cpuq run --driver -- env RIG_UNIT_LAUNCHER='cpuq run --' rig build …`).
- **cap is a limit, not a queue:** it takes no CPU, and the hook judges what it runs as if typed
  alone.
- **Put it inside `cpuq run`, never around it:** its `--time` would count the time spent waiting.
- **Exit:**
  - PROGRAM's own status, or 128+N if signal N killed it (with `--no-crash-report` on macOS, cap
    exits 128+N itself rather than dying by the signal);
  - 122 memory, 124 time (as GNU timeout) or 121 output when cap stopped it, each with one stderr
    line;
  - 2 on bad usage, before PROGRAM runs.
- **`--output`** needs stdout and stderr redirected to files or /dev/null. A pipe (`| tee`) exits
  2: don't count that as a test failure.
- **`--mem` on Linux** inside a `--driver` runner is the kernel's limit, and counts page cache and
  tmpfs too, so a limit tuned on the Mac can trip on Linux. Elsewhere cap reads memory once a
  second.
- **A test that panics on purpose:** add `--no-crash-report`, so no crash report is made for it
  (macOS's .ips, Linux's apport, which takes seconds a crash). Only on the program meant to
  crash: what it starts inherits it, and a real crash there (a compiler's) must still be
  reported.

Inside a submitted job, a runner that knows its test count reports progress, so status shows how
far it is and the time left: one line, `DONE TOTAL FAILING`, written whole at most once a second
and once at the end:

    printf '%d %d %d\n' "$done" "$total" "$failing" > "$CPUQ_PROGRESS.tmp" && mv "$CPUQ_PROGRESS.tmp" "$CPUQ_PROGRESS"

## Exit status

- One task: CMD's own status passes through; 128+N: CMD was killed by signal N; 124: CMD reached
  its time limit (`-t`).
- `-n M`: 0 when every task passed, else 1.
- 75: gave up waiting (`--wait-max`); CMD never ran.
- 125: cpuq itself failed. 126/127: CMD is not executable / not found. 2: usage or config error,
  or a removed option (the line names its replacement).

## The hook

Where `cpuq hook` is installed (Claude Code's PreToolUse hook), a heavy command run outside cpuq,
a removed option, or a `cpuq run` whose command would start more than one job, is refused with
the corrected command: run that instead. Mark a command `# cpuq: skip` only when it truly must
run as it is.

## Don't

- `--urgent` (except a rebuild a human is waiting on), `cpuq drain` for anything but timing.
- `cpuq kill` on runs you did not start: it acts on anyone's.
- Kill a waiting cpuq to retry it, or wrap a whole session or interactive shell in `cpuq run`.

A `cpuq run` inside a task starts at once on that task's CPU: `-n M` there runs its tasks `-x` at
a time on that one CPU. More: [README.md](README.md).
