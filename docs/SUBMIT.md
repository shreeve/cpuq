# Submitting work: a directory and a spec, and cpuq does the rest

Status: design v4, 2026-10-15: the contract for cpuq 0.18.

v3 went through three rounds with seven reviewers:
- GCP, AWS, Linux systems, distributed systems, build/CI, security and agent experience.

v4 takes their final round. "Decided against or later", at the end, lists what 0.18 deliberately
leaves out.

## The idea

An agent names a spec kept in its repo:

    cpuq submit cpuq/matrix.json

cpuq does the rest:

- picks a machine;
- syncs a snapshot of the work there, moving only what changed;
- runs it there, owned by that machine;
- shows progress;
- brings back a verdict that names the code it tested, with a short failure report;
- cleans up.

## Identity

- **The snapshot digest** is a hash of what the job sees:
  - `git ls-files -s`;
  - the content of modified and untracked files that ship;
  - size and mtime of ignored files that ship;
  - the same for each `deps` source.

  Outside git, it covers every file's path, size and mtime. It's taken before the sync and checked
  again after it; an edit made during the sync means syncing again.
- **The job digest** is the snapshot digest plus the spec, `-- ARGS`, `--env` and `tools`.
- **A copy's generation** is the snapshot digest it holds (`.cpuq-generation` in the copy).

Each digest has its own use:

| Use | Rule |
|---|---|
| Attach | a resubmit for the same worktree and label attaches to the job queued or running only when the **job digests** match. Otherwise it ends `NOT STARTED`, exit 2: `--replace` cancels the old job and starts this one; `--again` queues it behind |
| Copy | jobs on one copy run **one at a time**, under the copy's lock. A job's sync happens under that lock |
| Retry | after host loss it reruns on the host's copy only if the copy still holds the job's generation, with no new sync |
| Verdicts | every verdict and `result.json` name the job digest |

## Specs

Specs are kept in the repo (`cpuq/*.json`). The cpuq session writes them; agents run them and
never write them.

```json
{
  "label": "rig:matrix",
  "setup": "(cd deps/nexus && zig build -Doptimize=safe -p \"$NEXUS_OUT\") && zig build -j$CPUQ_CORES -Dnexus=$NEXUS_OUT/bin/nexus",
  "run": "python3 test/matrix.py -j $CPUQ_CORES --delta \"$@\"",
  "cores": "8-32",
  "on": ["burst", "pup"],
  "time": "90m",
  "mem": "96G",
  "tools": { "zig": "0.17.0" },
  "env": { "JSON_REQUIRE_DATA": "1" },
  "exclude": [".git", ".zig-cache", "zig-out"],
  "deps": { "deps/nexus": "../nexus" },
  "caches": { "RIG_RESULTS_CACHE": "rig-results", "NEXUS_OUT": "nexus" },
  "report": "test/results.jsonl",
  "return": ["test/results.jsonl", "test/failures"]
}
```

| field | meaning | default |
|---|---|---|
| `label` | `project:task` | required |
| `run` | `sh -c RUN cpuq ARGS...` at the copy's top, with `$CPUQ_CORES`; `-- ARGS` become `"$@"` | required |
| `setup` | run first, in the same job | none |
| `cores` | `N` or `MIN-MAX` | that host's history, else 2 |
| `on` | hosts in order: `"here"` or host names. A host with `spill_start` is started only when named here | `["here"]` |
| `time` | wall time from admission, enforced by `cpuq cap --time` around setup and run; required on a host with `spill_start` | 2h there, none here |
| `mem` | memory of the whole job, by `cpuq cap --mem` (the kernel's memory.max inside a Linux job) | none |
| `tools` | `{"zig": "0.17.0"}`: `zig version` etc. checked on the host before the run; a mismatch is NOT RUN | none |
| `env` | variables for setup and run, written to the job's own files on the host, never on a command line | none |
| `exclude` | path prefixes in the directory that never travel | none |
| `deps` | `"target in copy": "source outside"`: a source directory's tracked files (`git ls-files`), with mtimes. Binaries are built on the host by `setup` | none |
| `caches` | `"ENV": "name"`: `~/cpuq-spill/c/PROJECT/name` on the host, created, exported as `ENV`, never synced or deleted by a sync | none |
| `report` | JSON lines the job appends: `{"id", "ok", "status", "reason", "artifact"}`. Truncated at each attempt's start. It drives progress counts and the failure list | none |
| `return` | paths copied back into the directory when the job ends; excluded from the sync | none |
| `packs` | `{"zig": "0.17.0", "rig": "latest"}`: tool versions from the host's store, `~/cpuq/packs/NAME/VERSION`, installed by the first job that needs one (README, "Packs"). Each is on PATH and in `$NAME`. Versions: `latest`, `stable`, `X.Y.Z` (a tag) or a commit | none |
| `git` | `true`: the copy gets the repo's git as `.git`, git's own parts only (objects, refs, packed-refs, config, info, shallow, and the worktree's HEAD and index). `.git` as it is here never syncs | `false` |

- **Defaults:** the directory is the git top of the spec's repo, and its realpath must be under
  `submit_roots` (default `~/Data/Code`).
- **Spec errors:** one line naming the field, exit 2.
- **Refused directories:** one holding `.env*`, `*.pem`, `id_*`, `.netrc` or `.npmrc` that isn't
  excluded.

## Commands

    cpuq submit SPEC [-- ARGS] [--env K=V]... [--replace | --again]
    cpuq jobs [--all]                    this worktree's jobs, newest first
    cpuq job [ID | last] [--label L]     state, host, progress, verdict
    cpuq job ... --wait [--max-wait S]   wait, then exit as the job did
    cpuq job ... --tail N                the output's last N lines
    cpuq job ... --json                  everything, as fields
    cpuq job ... --cancel                stop it (another worktree's job also needs --force)

- **`cpuq submit` and the job are independent.**
  - It prints `job ID` on its first line, starts a supervisor that outlives it, and then waits.
  - Killing it never stops the job.
  - Agents run it in the background. After compaction: `cpuq jobs`, then `cpuq job ID --wait`, in
    the background.
  - `cpuq job last` names the other jobs of the worktree that are running, if any.
- **The last line is always a verdict.**

      PASS         rig:matrix  9c1e5f2a  38m40s  burst  32 cores  11409: 6840 ok, 4569 rejected
      FAIL         rig:matrix  9c1e5f2a  exit 1  38m40s  burst  3 of 11409 failed
      TIMEOUT      rig:matrix  9c1e5f2a  stopped at 90m: a limit, may be a hang in your change
      OOM          rig:matrix  9c1e5f2a  stopped at 96G: a limit, may be a leak in your change
      NOT RUN      rig:matrix  9c1e5f2a  no host could take it (burst: zig 0.16.0, wanted 0.17.0): not your code
      NOT STARTED  rig:matrix  9c1e5f2a  older snapshot running (4be1, 12m in): --replace or --again
      LOST         rig:matrix  9c1e5f2a  burst went away twice: not your code, resubmit once
      CANCELLED    rig:matrix  9c1e5f2a  by cpuq job --cancel: not your code
      CPUQ ERROR   rig:matrix  9c1e5f2a  rsync to burst failed (...): not your code, report it
      RUNNING      rig:matrix  9c1e5f2a  41m on burst: still running; cpuq job 9c1e --wait

  - On FAIL, the lines before the verdict are the first 20 failures from `report` (id, reason,
    artifact), else the output's last 30 lines.
- **Exit codes:**

  | verdict | exit |
  |---|---|
  | PASS | 0 |
  | FAIL | 1 (the job's own exit code is in the line and in `--json`) |
  | NOT STARTED | 2 |
  | RUNNING | 3 |
  | LOST | 69 |
  | NOT RUN | 75 |
  | CANCELLED | 76 |
  | OOM | 122 |
  | TIMEOUT | 124 |
  | CPUQ ERROR | 125 |

  None of these is ever the job's own exit code.
- **Progress:** on stderr, one line at each state change and every 5 minutes, under 100
  characters.

      rig:matrix  running  burst  12m  4210 done  3 failing

## How a job runs

1. **Place.** Take the first host in `on` that is reachable, has room (nobody waiting, load under
   its CPUs, gate open), and has the RAM for `mem`.
   - If none has room, queue at the first one that's reachable.
   - If none is reachable, start the first one named with a `spill_start` command.
   - A host whose cpuq is older than this one is refused, with the install command.
2. **Start, owned by the host.** The spec, env, ARGS and the job's identity go to
   `~/.local/state/cpuq/jobs/ID/` on the host, by ssh stdin. Then:
   - **Linux:** `systemd-run --user --unit cpuq-job-ID --collect --expand-environment=no
     -p RuntimeMaxSec=… cpuq _job ID`. The unit name makes a repeated start (a lost connection,
     a retry) refuse instead of doubling the job.
   - **macOS** (`here` on the Mac): `cpuq _job ID` in its own session.
3. **Lock and sync.**
   - `_job` takes the copy's lock: `~/cpuq-spill/w/PROJECT/ID12`, where ID12 is a hash of the
     origin machine and the directory's realpath.
   - It says "ready". The supervisor rsyncs the snapshot (`-a --delete`, less `exclude`,
     `return`, the `deps` targets and `.cpuq-generation`), then each dep's tracked files, then
     writes the generation. `_job` checks it.
4. **Run.**
   - `cpuq run --label L --cores C -- cpuq cap --time T --mem M -- sh -c 'SETUP && RUN' cpuq ARGS`,
     in the copy.
   - The environment: `env`, `caches` and a `TMPDIR` of the job's own.
   - Output goes to the job's `output.log`, and the report is truncated first.
   - `tools` are checked before anything runs.
   - The job is cpuq run's like any other: it queues there, takes cores, gets a cgroup that is
     killed when the command ends, and lands in history. cap enforces `time` from admission, and
     `mem` as the kernel's limit inside the job.
5. **Finish on the host.**
   - The verdict comes from the exit code and cap's last line, with the report read for counts and
     failures.
   - It's written to `result.json`, and `TMPDIR` is removed.
   - The lock is released, then the unit ends.
6. **Fetch.** The supervisor polls the host's state every 5 seconds over ssh. At the end it copies
   back `result.json`, the output's last 200 lines and `return`. A host's idle stop counts a job
   whose results haven't been fetched yet, for at most 30 minutes.
7. **Host lost.**
   - The supervisor owns retries. When the host stops answering, it checks three times, 5
     seconds apart.
   - It then starts the host again (`spill_start`), and reruns `_job ID` once, but only if the copy
     still holds the job's generation.
   - Otherwise, or after a second loss, the job is LOST.
   - With no supervisor left, the next `cpuq job` reconciles: it finds the result on the host, or
     the job still running, or marks it LOST.

## State

- **On the submitting machine:** `~/.local/state/cpuq/jobs/ID/`, holding `job.json` (spec path,
  label, worktree, digests, host, attempts), `state` (written by atomic rename), `progress`,
  `result.json` and `tail.log`.
  - The supervisor holds `lock` with flock for as long as it lives. An unlocked job that hasn't
    finished is reconciled by whoever next finds it.
- **On the host:** `~/.local/state/cpuq/jobs/ID/`, holding `spec.json`, `env` (0600), `state`,
  `output.log` and `result.json`.
- **Retention:** records are kept 14 days. Copies and caches are listed by `cpuq copies` and
  removed by `cpuq copies --clean`.

## Safety

- **Paths:** `dir` and every `deps` source must be under `submit_roots`, by realpath.
  - Targets, `return`, `exclude` and `report` are relative, with no `..`.
  - A copy is always `w/PROJECT/ID12`.
  - Job ids are hex.
  - rsync runs from an absolute path. `return` uses `--safe-links`.
- **Cost:** a host that bills is started only when named. Every job there has a `time`, and the
  VM has `--max-run-duration` (6h) as a backstop.
- **Trust:** everything on a host runs as one user, who has sudo on burst. A cgroup limits
  resources but contains nothing: these are guardrails against accidents, not against an attacker.
  burst has no cloud service account and blocks project-wide ssh keys.

## Decided against or later

| item | decision | why |
|---|---|---|
| A results cache in cpuq | **no** | unsound at job level; the project's own per-test cache is right (it lives in `caches`) |
| `secrets` | **later** | no spec needs one yet; until then a directory holding key files is refused |
| Redacting output and returned files | later, with `secrets` | |
| A readers–writer copy lock and a second copy | **no** | one job at a time per copy, under one lock, is enough; the copy-lock wait is part of the queue |
| Cache size budgets and eviction | later | `cpuq copies --clean` and the dataset quota until then |
| Auto-installing cpuq on hosts | **no** | refused with the install command instead |
| Placement scoring and cost weights | **no** | `on` order, for three machines |
| `spill_budget` hours | later (0.18.x) | the 6h VM backstop and `time` cover it until then |
| The hook reading `replaces` | later | the brief says it until then |
| Preemption marker unit on the host | later (runbook) | until then any lost host counts as lost, with one retry |
| ZFS dedup on burst | **kept**, measured | 1.40× on new writes at about zero kernel CPU so far; revisit if write latency shows |

## For agents (the brief)

```
Heavy work goes through repo specs in cpuq/*.json; don't edit, copy or write specs.
Start one with Bash run_in_background:  cpuq submit cpuq/suite.json [-- TEST FILTER]
You're notified at the end. The last line is the verdict, and the exit status matches it:
  PASS 0 | FAIL 1: your code; failures and their repro commands are printed above it.
  TIMEOUT / OOM: a limit, often a hang or leak in your change: cpuq job ID --tail 100.
  NOT RUN / LOST / CANCELLED / CPUQ ERROR: not your code; follow the hint on the line.
Never cat logs. After compaction: cpuq jobs, then cpuq job ID --wait in the background.
Same code resubmitted attaches. After edits, --replace; a repro beside a full run, --again.
Never add -j, --cores, hosts, ssh or rm -rf; never cancel another worktree's job.
Never loop on a non-code verdict.
```
