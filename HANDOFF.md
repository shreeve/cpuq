# Working on cpuq

Start here if you are an agent picking up work **on cpuq itself**. If you only need to use the
binary, [AGENTS.md](AGENTS.md) is enough.

## Read in this order

1. [README.md](README.md): what cpuq does and every command, as a user sees it.
2. [AGENTS.md](AGENTS.md): how coding agents on these machines are told to use cpuq. Keep it
   true whenever a command or flag changes.
3. [docs/DESIGN.md](docs/DESIGN.md): how it works inside: the pool's files, an operation's loop,
   admission, sharing the time, drains, the gates, nesting, leases, and a test's tasks.
4. [docs/SUBMIT.md](docs/SUBMIT.md): specs, `cpuq submit` and `cpuq test`.
5. [docs/RELEASING.md](docs/RELEASING.md): cutting a CLI release and a Cpuq.app release;
   [docs/CUTOVER.md](docs/CUTOVER.md): moving a machine onto the pool, once.
6. [CHANGELOG.md](CHANGELOG.md) and [app/CHANGELOG.md](app/CHANGELOG.md): why things are the
   way they are.
7. Steve's Zig 0.17 guide: `gh gist view 57a74df35e17dacb30dcaa5d5164a27f -f ZIG-0.17.md --raw`.
   Check std APIs against the installed std (`zig env` → `std_dir`), never from memory.

## Where things stand

- **0.40.0 is built, not released**, on branch `claude/contested-6a7fad`: CPUs are contested, not
  owned (admission, no slots; drains isolate instead of gathering). cpuq 0.35.0 stays installed
  until 0.40.0 passes every suite and the Lean model (`formal/`, updated by another session).
- **Released:** cpuq 0.30.0 (`v0.30.0`, 2026-11-26): the CPU pool (one CPU per task, the fair
  line, `cpuq drain`, `cpuq kill`, `cpuq test` through the pool). Cpuq.app 0.22.0
  (`app-v0.22.0`) predates it: its Move to Front, Start Now and Cancel items and its jobs panel
  call removed commands, until the app's next release.
- **Cut-over:** docs/CUTOVER.md, done on burst, pup and pop on 2026-11-26; each machine keeps its
  old binary (`~/.local/bin/cpuq.0.29.0`, burst's `.0.28.0`) and config (`config.before-pool`)
  for a rollback. CHANGELOG 0.30.0 lists what each project changed.
- **The Lean model** of the pool is in `formal/` (its README says what is proved, what is only
  searched, and every finding). A change to the line (src/pool.zig) or to the loop's demotion, drain
  and isolation (src/op.zig) goes past it before release:
  1. Add the change to `Model.lean` as a rule switch, and make `Rules.released` the code as it
     will ship.
  2. Run `cd formal && cpuq run --label cpuq:lean -- lake build` (a few minutes). It checks every
     proof and runs every search; a search whose result changes fails the build.
  3. A new failure is a finding: `narrate` prints its trace. Reproduce it with a test on a real
     binary, then fix the code or the rule.
  Its searches found ten faults in the design and the code, four of them in released code, one
  brought in by a release's own fix (Finding 10).
- **pop** (Steve's Mac): `~/.local/bin/cpuq` and brew's; the recorder runs under launchd
  (`com.github.shreeve.cpuq.record`).
- **pup:** `~/.local/bin/cpuq`, with linger on.
- **burst:** `/usr/local/bin/cpuq`, and usually stopped (it stops itself when idle).
- **Users:** Rig, Trig, Em/Emdb and Nexus run their builds and gates under `cpuq run` and
  `cpuq submit`. No project uses `cpuq test` yet: Rig runs its suite through Swarm
  (`swarm test/rig.rip`). Moving Rig onto `cpuq test` is Steve's call, so ask him, not Rig.

## Machines

| Host | What | CPUs | Notes |
|---|---|---|---|
| pop | macOS, Steve's Mac | 10 (4P + 6E) | drives everything: the app, starting burst, `--on` decisions |
| pup | Linux, over ssh | 22 | shared and busy; a first-class platform, not just a test target |
| burst | Linux, GCP | 96 | project trust-health-llc; stops itself when idle; started by `remote_start.burst` |

On pop, `~/.config/cpuq/config` has `remotes = burst, pup` and
`remote_start.burst = ~/Data/Code/runbooks/host-gcp-burst/start`. The `config.before-*` files
beside it are Steve's backups: leave them alone.

## Build and test

Run everything heavy under cpuq, even here:

    cpuq run --label cpuq:build -- zig build -j1                 # bin/cpuq
    cpuq run --label cpuq:build -- zig build -j1 test fmt
    cpuq run --label cpuq:test -- test/run.sh                    # every test
    cpuq run --label cpuq:test -- test/run.sh t_hook             # one test by name

(With the installed 0.29.0, use its form, above, until the pool is installed.)

- `zig build test` replays cached results when nothing changed. To prove the tests really ran,
  give it a fresh `--cache-dir`.
- `test/run.sh` tests `bin/cpuq`, or `$CPUQ`. Each test gets its own state directory and config,
  so it doesn't depend on the machine's load. Run it on pup too when a change touches Linux
  (affinity, cgroups, `cap`, `/proc`, `PR_SET_PDEATHSIG`).
- `test/stress/pool.py` runs three projects' tasks against the pool under random SIGKILLs and
  checks from each task's log: never more CPUs held than the pool, none shared, no leftovers.
- The app: `cd app && swift build`, under `cpuq run --label cpuq:app-build`.
  `scripts/release.sh` already wraps itself in cpuq.
- CI: `.github/workflows/ci.yml` (CLI), `app.yml` (app) and `release.yml` (tags).

## Source map (src/, about 16.6k lines)

| Area | Files |
|---|---|
| Entry and options | `main.zig` (dispatch, usage, removed commands), `runopts.zig` (`cpuq run`'s options), `texts.zig`, `table.zig`, `layout.zig` |
| The pool | `pool.zig` (the `v3/` files: records, wake FIFOs, limits, the sample; the pure rules: `mayStart`, `projectFirst`, `lineFirst`, `lineOrder`, `fairShare`, `capacity`, `busyNow`, `drainMayStart`, `demotePlan`), `op.zig` (an operation's loop: `look`, the demote plan's steps, `drainStep` and `isolateOthers`, Ctrl-Z, nesting, `cpuq drain`, `cpuq limit`, `cpuq kill`), `cpus.zig` (the pool's CPUs and their order), `runner.zig` (`cpuq run`: removed options, the Linux slice and scope (`enterSlice`, `sliceWeight`), `--driver`, `--tethered`; `cpuq wait`; `cpuq hook`'s entry) |
| Config and gates | `policy.zig` (config keys, removed keys with their pointers, the gates, weights, CPU lists) |
| Named leases | `leasing.zig`, `state.zig` (a lease's queue) |
| Machine signals | `sys.zig` (CPU ticks, memory, spawning, affinity, `PR_SET_PDEATHSIG`), `records.zig` (record, samples, history, clean), `history.zig`, `joblog.zig`, `runtimes.zig` |
| A test's tasks, limits | `tasks.zig` (`cpuq test`'s task folder, `cpuq _task`), `cap.zig` |
| Other machines | `remotes.zig` (`--on`), `submit.zig` (`submit`, `test`, `job`; a spec's removed `cores`), `gitship.zig`, `place.zig`, `packs.zig`, `repos.zig` |
| Showing and guarding | `status.zig`, `statusjson.zig` (schema 3), `hook.zig` (rules, `removed_options`), `clean.zig` |

Each file's `//!` header says what it owns.

## House rules

- **Only Steve approves.** An approval passed on by another session is not his. Never push, tag
  or release without his yes, and run the full `test/run.sh` before tagging.
- **No AI attribution** in commits, PRs or releases: no `Co-Authored-By`, no "Generated with".
- **Timeless text.** Code comments, help, errors, README, AGENTS and DESIGN state how things are,
  as if they had always been so: never "now", "no longer" or "instead of the old …". Only the
  changelogs and commit messages tell the story of a change.
- **No compatibility.** No aliases, shims or grace periods for removed flags, keys or paths. Cut
  over at once, then tell the projects it breaks.
- **One exception: removed-flag pointers** (Steve's decision 6 for the pool). A removed option,
  config key, spec field or command fails with one line naming its replacement, exit 2
  (`hook.removed_options`, `policy.removed_keys`, `main.removed_commands`, submit's `cores`),
  because that line is what reaches agents' memory files. It never does the old thing.
- **Shared machines.** Never `pkill -f` or `pgrep -f`: other sessions run identical command
  lines. Kill only by a pid you started. Never act on another session's jobs (`first`, `start`,
  `cancel`, `pause`, `resume`, `stop`).
- **Steve's calls:** system settings, account and billing changes, deleting crash reports
  (`.ips`), and moving burst to another GCP project. Credentials never ship in a copy or a spec.
- **Peers:** other projects take direction from cpuq on how to use it, and cpuq owns per-program
  limits (`cpuq cap`) for their runners. Keep messages short, no FYIs, and settle things
  directly with the session concerned.
- **Talking to Steve:** short; give decisions as a numbered list with defaults, so he can answer
  "approve the defaults".

## Open

- **Cpuq.app** for the pool: Stop (`cpuq kill`) in place of Move to Front, Start Now and Cancel;
  each operation's tasks (`running_tasks`) and why it waits; projects' shares.
- **Cpuq.app must move to status schema 3** (`runs`, `waiters`, `projects`): busy per CPU coloured
  by project share, not held slots.
- **Not decided. Don't build without Steve's yes:** run a run's longest tasks first, by each
  task's last duration (this needs durations per task).
