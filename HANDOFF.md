# Working on cpuq

Start here if you are an agent picking up work **on cpuq itself**. If you only need to use the
binary, [AGENTS.md](AGENTS.md) is enough.

## Read in this order

1. [README.md](README.md): what cpuq does and every command, as a user sees it.
2. [AGENTS.md](AGENTS.md): how coding agents on these machines are told to use cpuq. Keep it
   true whenever a command or flag changes.
3. [docs/DESIGN.md](docs/DESIGN.md): how it works inside: the pool's files, an operation's loop,
   the line, giving CPUs back, the gates, nesting, leases, and a test's tasks.
4. [docs/SUBMIT.md](docs/SUBMIT.md): specs, `cpuq submit` and `cpuq test`.
5. [docs/RELEASING.md](docs/RELEASING.md): cutting a CLI release and a Cpuq.app release;
   [docs/CUTOVER.md](docs/CUTOVER.md): moving a machine onto the pool, once.
6. [CHANGELOG.md](CHANGELOG.md) and [app/CHANGELOG.md](app/CHANGELOG.md): why things are the
   way they are.
7. Steve's Zig 0.17 guide: `gh gist view 57a74df35e17dacb30dcaa5d5164a27f -f ZIG-0.17.md --raw`.
   Check std APIs against the installed std (`zig env` → `std_dir`), never from memory.

## Where things stand

- **Released:** cpuq 0.29.0 (`v0.29.0`) and Cpuq.app 0.22.0 (`app-v0.22.0`), both on
  2026-11-03, with the Homebrew formula and cask bumped. `main` matches `origin/main`.
- **The CPU pool** (one CPU per task, the fair line, `cpuq drain`, `cpuq kill`) is on branch
  `slots`, draft PR #7: not released, not installed anywhere. Every machine runs 0.29.0 (burst
  0.28.0), which takes the old form: `cpuq run --label L --cores 2-4 -- sh -c 'zig build
  -j"$CPUQ_CORES"'`. `test/run.sh` is being rewritten for the pool, so CI fails on the branch
  until it lands. CHANGELOG's "Unreleased" lists what each project must change before a machine is
  cut over; cut over one machine at a time (burst, then pup, then pop), each with a rollback.
- **The Lean model** of the pool is in `formal/` on the `lean-model` worktree (its README says what
  is proved and what is only searched). Changes to the line (src/pool.zig) or the loop's stop and
  give-back (src/op.zig) go past it.
- **pop** (Steve's Mac): `~/.local/bin/cpuq` and brew's are 0.29.0. The 0.29 agent and the
  recorder run under launchd (`com.github.shreeve.cpuq.agent`, `com.github.shreeve.cpuq.record`);
  the agent's service goes at the cut-over (docs/CUTOVER.md).
- **pup:** 0.29.0, with the 0.29 agent as the systemd user service `cpuq-agent` (linger on), which
  goes at the cut-over.
- **burst:** 0.28.0, and usually stopped (it stops itself when idle).
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
| The pool | `pool.zig` (the `v2/` files: tokens, records, promises, wake FIFOs; the line: `ahead`, `handOut`, `firstWaiter`, `giver`, `behindAfter`; the outside-load sample), `op.zig` (an operation's loop, Ctrl-Z, consolidation, nesting, `cpuq drain`, `cpuq kill`), `cpus.zig` (the pool's CPUs and their order), `runner.zig` (`cpuq run`: removed options, `--driver`, `--tethered`; `cpuq wait`; `cpuq hook`'s entry) |
| Config and gates | `policy.zig` (config keys, removed keys with their pointers, the gates, weights, CPU lists) |
| Named leases | `leasing.zig`, `state.zig` (a lease's queue) |
| Machine signals | `sys.zig` (CPU ticks, memory, spawning, affinity, `PR_SET_PDEATHSIG`), `records.zig` (record, samples, history, clean), `history.zig`, `joblog.zig`, `runtimes.zig` |
| A test's tasks, limits | `tasks.zig` (`cpuq test`'s task folder, `cpuq _task`), `cap.zig` |
| Other machines | `remotes.zig` (`--on`), `submit.zig` (`submit`, `test`, `job`; a spec's removed `cores`), `gitship.zig`, `place.zig`, `packs.zig`, `repos.zig` |
| Showing and guarding | `status.zig`, `statusjson.zig` (schema 2), `hook.zig` (rules, `removed_options`), `clean.zig` |

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

- **The pool, before release:** the projects' edits (CHANGELOG, Unreleased) and the cut-over
  (docs/CUTOVER.md); the app follows in PR C.
- **Not decided. Don't build without Steve's yes:** run a run's longest tasks first, by each
  task's last duration (this needs durations per task).
