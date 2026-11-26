# Working on cpuq

Start here if you are an agent picking up work **on cpuq itself**. If you only need to use the
binary, [AGENTS.md](AGENTS.md) is enough.

## Read in this order

1. [README.md](README.md): what cpuq does and every command, as a user sees it.
2. [AGENTS.md](AGENTS.md): how coding agents on these machines are told to use cpuq. Keep it
   true whenever a command or flag changes.
3. [docs/DESIGN.md](docs/DESIGN.md): how it works inside: the state directory, admission, the
   gates, leases, jobs of task files and the agent.
4. [docs/SUBMIT.md](docs/SUBMIT.md): specs, `cpuq submit` and `cpuq test`.
5. [docs/RELEASING.md](docs/RELEASING.md): cutting a CLI release and a Cpuq.app release.
6. [CHANGELOG.md](CHANGELOG.md) and [app/CHANGELOG.md](app/CHANGELOG.md): why things are the
   way they are.
7. Steve's Zig 0.17 guide: `gh gist view 57a74df35e17dacb30dcaa5d5164a27f -f ZIG-0.17.md --raw`.
   Check std APIs against the installed std (`zig env` → `std_dir`), never from memory.

## Where things stand

- **Released:** cpuq 0.29.0 (`v0.29.0`) and Cpuq.app 0.22.0 (`app-v0.22.0`), both on
  2026-11-03, with the Homebrew formula and cask bumped. `main` matches `origin/main`.
- **pop** (Steve's Mac): `~/.local/bin/cpuq` and brew's are 0.29.0. The agent and the recorder
  run under launchd (`com.github.shreeve.cpuq.agent`, `com.github.shreeve.cpuq.record`).
- **pup:** 0.29.0, with the agent as the systemd user service `cpuq-agent` (linger on).
- **burst:** 0.28.0, and usually stopped. The next time it is up for other work, upgrade it and
  run `cpuq agent --install`. Steve approved this, but never start burst just to do it.
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

    cpuq run --label cpuq:build --cores 2-4 -- sh -c 'zig build -j"$CPUQ_CORES"'   # bin/cpuq
    cpuq run --label cpuq:build --cores 2-4 -- sh -c 'zig build -j"$CPUQ_CORES" test fmt'
    cpuq run --label cpuq:test --cores 1 -- test/run.sh                  # all 99, about 9 min on pop
    cpuq run --label cpuq:test --cores 1 -- test/run.sh t_job_affinity   # one test by name

- `zig build test` replays cached results when nothing changed. To prove the tests really ran,
  give it a fresh `--cache-dir`.
- `test/run.sh` tests `bin/cpuq`, or `$CPUQ`. Each test gets its own state directory and config,
  so it doesn't depend on the machine's load. Run it on pup too when a change touches Linux
  (affinity, cgroups, `cap`, `/proc`).
- The app: `cd app && swift build`, under `cpuq run --label cpuq:app-build`.
  `scripts/release.sh` already wraps itself in cpuq.
- CI: `.github/workflows/ci.yml` (CLI), `app.yml` (app) and `release.yml` (tags).

## Source map (src/, about 17.4k lines)

| Area | Files |
|---|---|
| Entry and options | `main.zig`, `runopts.zig`, `texts.zig`, `table.zig`, `layout.zig` |
| The queue | `admission.zig` (waiting, granting), `state.zig` (flock holds), `policy.zig` (config, budget, pure decisions), `runner.zig` (`cpuq run`), `leasing.zig`, `timing.zig` (`--exclusive`), `control.zig` (first/start/cancel/…) |
| Machine signals | `sys.zig` (load, memory, spawning, affinity), `records.zig` (record, samples, history), `history.zig`, `joblog.zig`, `runtimes.zig` |
| Jobs of task files | `jobs.zig` (the driver, `cpuq jobs`), `agent.zig` (`cpuq agent`, `attach`), `lines.zig` (line sockets), `cap.zig` |
| Other machines | `remotes.zig` (`--on`), `submit.zig` (`submit`, `test`, `job`), `gitship.zig`, `place.zig`, `packs.zig`, `repos.zig` |
| Showing and guarding | `status.zig`, `statusjson.zig`, `doctor.zig`, `hook.zig`, `clean.zig` |

Each file's `//!` header says what it owns.

## House rules

- **Only Steve approves.** An approval passed on by another session is not his. Never push, tag
  or release without his yes, and run the full `test/run.sh` before tagging.
- **No AI attribution** in commits, PRs or releases: no `Co-Authored-By`, no "Generated with".
- **Timeless text.** Code comments, help, errors, README, AGENTS and DESIGN state how things are,
  as if they had always been so: never "now", "no longer" or "instead of the old …". Only the
  changelogs and commit messages tell the story of a change.
- **No compatibility.** No aliases, shims, grace periods or error branches for removed flags,
  keys or paths. Cut over at once, then tell the projects it breaks.
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

- **Tune the agent once it runs real work:** the ×2-per-step cap, the 10% deadband, "cut fast"
  (two ticks over: × target/runq), and memory-short × 0.75. A new job's cost starts at 1.0. It
  could come from its label's history instead, but that isn't built.
- **Not decided. Don't build these without Steve's yes:**
  1. Run longest tasks first, by each task's last duration (this needs durations per task).
  2. On Linux, autogroup nice (`/proc/PID/autogroup`) and ionice best-effort 7 for job tasks.
  3. A hook in Rig's test/run (`RIG_JOBS_DIR`) that writes one task file per test;
     `scripts/rig-jobs.sh` expects it.
