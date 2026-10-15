# Submitting work: a directory and a spec, and cpuq does the rest

Status: design v3, 2026-10-15. It has been through two rounds of review by seven reviewers:
- a GCP engineer and an AWS engineer;
- a Linux systems engineer;
- a distributed-systems professor;
- a build/CI infrastructure engineer;
- a security engineer;
- an agent-experience designer.

In both rounds every reviewer's verdict was "build with changes". Round two's findings are in
"What round two changed", at the end. Some systemd behaviour was checked on pup itself, not
assumed.

## The idea

An agent names a spec kept in its repo:

    cpuq submit cpuq/matrix.json

cpuq does the rest:

- picks a machine that can run the job;
- syncs a snapshot of the work there, moving only what changed;
- runs it under limits, owned by that machine;
- shows progress;
- brings back a verdict that names exactly which code it tested, with a short failure report;
- cleans up.

The agent never names cores, `-j`, hosts, ssh, rsync or cleanup.

## Identity: the input digest

Every job has an **input digest**, a hash of:

- the snapshot: for a git work tree, `git ls-files -s` plus the hashes of modified and untracked
  files that will be shipped; otherwise the contents;
- the `deps`;
- the spec;
- the `-- ARGS` and `--env`;
- the declared `tools` versions.

It's computed before the sync and checked again after (an edit made during the sync means
syncing again). Each sync of a copy records its **generation**, the digest it holds.

Everything that could otherwise give a verdict for the wrong code uses the digest:

- **A resubmit** attaches to a queued or running job only when the digests match. Otherwise it
  stops with exit 2: `an older snapshot is running (7f3a, 12m in): --replace to cancel it and
  start this one, --again to run both`.
- **A retry** after host loss reruns the same generation, already on the host, with no new sync
  and no need for the Mac.
- **Every verdict line and `result.json`** name the digest, so a PASS says which code passed.

## Specs

Specs live in the repo (`cpuq/*.json`). The cpuq session writes and maintains them; agents run
them and never write them. The project decides which specs a change must pass.

```json
{
  "label": "rig:matrix",
  "setup": "zig build -j$CPUQ_CORES -Dnexus=$NEXUS_BIN",
  "run": "python3 test/matrix.py -j $CPUQ_CORES --delta \"$@\"",
  "cores": "8-32",
  "on": ["burst", "pup"],
  "time": "90m",
  "mem": "96G",
  "tools": { "zig": "0.17.0" },
  "env": { "JSON_REQUIRE_DATA": "1" },
  "exclude": [".git", ".zig-cache", "zig-out"],
  "deps": { "deps/nexus-src": "../nexus" },
  "caches": { "RIG_RESULTS_CACHE": "rig-results", "RIG_BUILD_STORE": "rig-build-store", "ZIG_GLOBAL_CACHE_DIR": "zig", "NEXUS_OUT": "nexus" },
  "report": "test/results.jsonl",
  "return": ["test/results.jsonl", "test/failures"],
  "replaces": ["./test/run", "test/matrix.py"]
}
```

| field | meaning | default |
|---|---|---|
| `label` | `project:task`: the job's name in queues, history and `cpuq jobs` | required |
| `run` | `sh -c RUN cpuq ARGS...` at the copy's top, with `$CPUQ_CORES`; `cpuq submit SPEC -- ARGS` passes ARGS as `"$@"` | required |
| `setup` | run first, in the same job and place (a build); a failure is a FAIL | none |
| `cores` | `N` or `MIN-MAX`, sized from that host's own history | history, else 2 |
| `on` | hosts in order of preference: `"here"`, host names, `"linux"`, `"macos"`. A host that bills (one with `spill_start`) is started only when named here | `["here"]` |
| `time` | wall time once admitted, enforced by the host's cpuq; required on a host that bills | 2h there |
| `mem` | the whole job's memory: `MemoryMax`, with swap off | none |
| `tools` | versions checked on the host before the run; a mismatch is NOT RUN | none |
| `env` | variables, sent over the ssh connection, never in a command line; keys `[A-Z_][A-Z0-9_]*` | none |
| `exclude` | paths that never travel; patterns `[A-Za-z0-9._/*?-]`, always passed as `--exclude=/PAT` | none |
| `deps` | `"path in copy": "path outside dir"`: sources from outside the directory, copied with their mtimes. Under the same path rules as `dir`. Binaries don't travel between OSes; build them on the host with `setup` into a cache | none |
| `caches` | `"ENV": "name"`: a directory on each host per project and name, shared by that project's copies, never synced and never deleted by a sync, exported as `ENV`. Each has a size budget, and eviction renames entries into a trash directory, never `rm` under a running job | none |
| `report` | JSON lines appended as the job goes: `{"id", "ok": bool, "status": "<the runner's own word>", "reason", "duration_ms", "attempt", "artifact"}`. Progress and the failure report come from it. The exit status decides the verdict and the report explains it | none |
| `return` | paths copied back when the job ends, pass or fail; excluded from the sync; `--safe-links`; size-capped | none |
| `replaces` | commands this spec stands for: `cpuq hook` refuses them and names the spec. A repro line uses the spec (`cpuq submit cpuq/suite.json -- proof.loan.3`) | none |

The directory is the git top of the spec's repo. `cpuq submit` prints it, with the file count,
before the first sync. A spec error is one line naming the field, exit 2.

## Submitting and following

    cpuq submit SPEC [-- ARGS] [--env K=V] [--replace | --again]
    cpuq jobs                          this worktree's jobs, newest first; --all for all
    cpuq job [ID|last] [--label L]     state, host, CPUs, memory, progress, digest, verdict
    cpuq job ... --wait [--max-wait S]
    cpuq job ... --tail N              part of its output; logs are never printed whole
    cpuq job ... --cancel              another worktree's job also needs --force

- **Every submit is supervised.**
  - `cpuq submit` prints the job id on its first line, then waits.
  - Killing its client never stops the job. Agents run it in the background and are notified when
    it ends.
  - After compaction, `cpuq job last --wait` finds the job again.
  - `cpuq hook` refuses a foreground `cpuq submit`, and `job --wait` without `--max-wait`, by
    reading `run_in_background`.
- **The last line is always a verdict:**

      PASS        rig:matrix  7f3a1c  38m40s  burst  32 cores  11409: 6840 ok, 4569 rejected
      FAIL        rig:matrix  7f3a1c  exit 1  38m40s  burst  3 of 11409 failed
      TIMEOUT     rig:matrix  7f3a1c  stopped at the 90m limit: a limit, may be a hang in your change
      OOM         rig:matrix  7f3a1c  stopped at the 96G limit: a limit, may be a leak in your change
      NOT RUN     rig:matrix  7f3a1c  burst over today's budget until 00:00: not your code, don't resubmit before then
      LOST        rig:matrix  7f3a1c  burst preempted twice: not your code, resubmit once
      CANCELLED   rig:matrix  7f3a1c  by cpuq job --cancel: not your code
      CPUQ ERROR  rig:matrix  7f3a1c  rsync to burst failed (…): not your code, report it
      RUNNING     rig:matrix  7f3a1c  41m on burst: still running; cpuq job last --wait

  - On FAIL, the lines before the verdict are the first 20 failures from `report` (id, reason,
    repro, artifact), or else the output's last 30 lines.
  - Secrets are redacted from all of it.
- **Exit status:**

  | verdict | exit |
  |---|---|
  | PASS | 0 |
  | FAIL | 1, always; the job's own code is in the verdict and in `--json` |
  | TIMEOUT | 124 |
  | OOM | 122 |
  | NOT RUN | 75 |
  | CANCELLED | 76 |
  | LOST | 69 |
  | CPUQ ERROR | 125 |
  | RUNNING | 3 |

  These numbers never pass through from the job, so each means only what cpuq says.
- **Progress** goes on stderr. Off a terminal: one line at each state change, and every 5
  minutes, under 100 characters:

      rig:matrix  running  burst  12m  27.8 CPUs  41G  4210/12034  3 failing

## How a job runs

1. **Place.** The first host in `on`'s order that's feasible and has room now.
   - *Feasible* means up or startable, the right OS, `mem` within its RAM, its copies quota with
     room, `tools` matching, and under budget.
   - *If none has room:* start the first named billing host, under budget, re-checking
     feasibility against the shape it actually started as.
   - *Otherwise* queue at the first feasible host that's up.
   - A host stays held with a lease from placement until the job is queued there, so its idle
     stop can't intervene.
2. **Sync.**
   - *Where:* the copy is `~/cpuq-spill/w/PROJECT/ID`, the same absolute path on pup and burst
     (both `/home/shreeve`; burst's is the ZFS dataset, with lz4 and dedup). ID is a hash of the
     origin host and the directory's realpath, so worktrees with the same name in different
     places never share a copy.
   - *What:* `rsync -a --delete` of the snapshot, less `exclude` and `return`, plus `deps`.
     "here" is a local copy too, so a job always runs a snapshot.
   - *Locking:* each copy has a readers–writer lock where a waiting sync goes ahead of new
     readers. A job joins a copy only at its own generation, re-checked after taking the shared
     lock. Eviction takes the exclusive lock.
   - *The wait:* time spent waiting for the copy lock counts in the queue estimate. A short job
     stuck behind a long one on an older generation gets a second copy.
3. **Run, owned by the host.**
   - *The unit.* On Linux each job is a transient systemd **service** of the host's cpuq (scopes
     ignore `DelegateSubgroup`, as checked on pup's systemd 259). It has
     `DelegateSubgroup=sup`, `OOMPolicy=continue`, `MemoryMax`, `MemorySwapMax=0`, and
     `StandardOutput=append:` to the job's log. `RuntimeMaxSec` is only a backstop, set to the
     longest wait plus `time`.
   - *cpuq run* sits in `sup/`. It holds the lease, takes the cores, enables `+memory +pids` for
     the unit's children, and starts the command into `job/` with `clone3(CLONE_INTO_CGROUP)`.
     It enforces `time` from admission. It watches CPU and memory from the cgroups, with no
     process walk. At the end it kills `job/` and any caps (never `sup/`), then writes the
     verdict.
   - *Cleanup:* `ExecStopPost` removes the job's `TMPDIR`.
   - *State:* the state, output and report live on the host in `~/.local/state/cpuq/jobs/ID/`
     (0700). The supervisor on the submitting machine owns the job's life before that (placing,
     starting the host, syncing) and after it (fetching results, retrying). Each phase is a state
     written by atomic rename, under the supervisor's own flock. A job whose flock nobody holds is
     reconciled by the next `cpuq job`: reattach, fetch, or mark LOST.
4. **Finish.**
   - *On the host:* the verdict goes into `result.json`, with `report` read and secrets redacted.
   - *The supervisor* fetches `result.json`, `return` and the output's tail at once, so nothing
     has to start a stopped VM to read a verdict. Until it does, the host's idle stop sees a
     "results waiting" lease, capped at 30 minutes.
   - *History* records the spec path, label, digest and host, not the expanded command.
5. **Host lost.**
   - A unit ordered before `user@.service` stops records why the host stopped, *before* any job
     is stopped. The reasons are preemption (`instance/preempted`), `--max-run-duration`, the idle
     stop, or a shutdown.
   - A verdict is written only after checking that record. So any stop the job didn't cause is
     host loss, never FAIL.
   - The supervisor restarts the host (when the budget allows) and reruns the same generation
     once, then gives LOST. With no supervisor alive, or with secrets that were never stored,
     it's LOST at once.

## `cpuq cap`, for each program a runner starts

    cpuq cap [--mem SIZE] [--time DURATION] [--output SIZE] [--pids N] -- PROGRAM ARGS...

- **Linux, inside a job (`CPUQ_CGROUP`):**
  - *Birth:* PROGRAM is born in a cgroup of its own beside `job/`, by
    `clone3(CLONE_INTO_CGROUP)`, with `exit_signal` SIGCHLD. Before exec the child makes only
    async-signal-safe calls. It falls back to fork and a move on ENOSYS, EACCES or EBUSY.
  - *Limits:* the cgroup has `memory.max`, `memory.swap.max=0`, `memory.oom.group=1` and
    `pids.max`.
  - *Blame:* "stopped for memory" is read from the cap's own `memory.events.local`.
  - *Stopping:* `cgroup.kill`.
  - *No escape:* `CPUQ_CGROUP` isn't passed on, so a nested cap can't escape its parent.
- **Elsewhere:**
  - PROGRAM gets its own process group.
  - Memory is read once a second from its own tree. On Linux that's
    `/proc/PID/task/TID/children`, read to EOF. On macOS it's `proc_listchildpids`.
  - Stopping repeats freeze, walk, SIGKILL and `killpg` until nothing is left. A Linux
    subreaper and PDEATHSIG (re-checked against `getppid` once armed) keep orphans in reach.
- **`--time` alone uses no cgroup.**
- **Waiting:** the program's end wakes cpuq at once, through a signal pipe. The handler saves
  errno, signals are blocked across the fork, and a deadline is a timer. Orphans are reaped as
  they end. Buffers are on the stack, so a long cap doesn't grow.
- **Exit:** PROGRAM's own, or death by its signal. 122 for memory, 124 for time and 121 for
  output each come with one line on stderr.
- **Measured on burst before Rig switches:**
  - 14,000 calls, for cost per call and for dying memcgs in `cgroup.stat` (slots are reused if
    those pile up);
  - Rig's 2048 MB limit, recalibrated, since `memory.max` counts page cache, tmpfs and kernel
    memory, which `ps` RSS didn't.

## Safety

- **Paths:**
  - `dir` and each `deps` source must resolve (realpath) under `submit_roots` (default
    `~/Data/Code`), never `$HOME` or above it.
  - Targets must be relative, with no `..` and no symlink on the way (lstat).
  - A copy is always `w/PROJECT/ID`, so `--delete` can only touch it.
  - Job ids are hex.
  - rsync is pinned by absolute path to a 3.x build, not macOS's `/usr/bin/rsync`.
- **Secrets:**
  - *Never shipped:* a directory isn't shipped if it holds `.env*`, `*.pem`, `id_*`, `.netrc`,
    `.npmrc` or `credentials*.json` (unless excluded). Its `deps` are checked the same way.
  - *Sources:* a `secrets` field gives the only way in: Keychain items named `cpuq-*`, or files
    under `~/.config/cpuq/secrets/`.
  - *Resolving:* in the foreground. A locked keychain fails at once, with no wait on a prompt.
  - *Delivery:* sent over ssh stdin into a 0600 file under `/run/user/UID/cpuq/ID` (tmpfs),
    which the job reads into its environment. Never in unit properties, a command line, the copy,
    history or a log. Deleted when the job ends.
  - *Redaction:* values of 8 characters or more are redacted when written on the host, from
    output, the report, `result.json` and returned files.
  - *Retries:* a retry with no supervisor alive can't have the secrets, so it's LOST.
- **Cost:**
  - A billing host is started only by a spec that names it, and every job there has a `time`.
  - The host keeps its own uptime ledger on its disk. `spill_budget.burst` (hours a month,
    matched to the $100 budget alert) is checked at every start and every submit, including
    retries.
  - `--max-run-duration` on the VM is a backstop.
  - Placement refuses a job whose `time` won't fit in the VM's remaining run time.
  - Each start is logged: by whom, for which spec, when, and for how long.
- **Hosts:**
  - burst has no service account; verify checks the metadata server gives no token.
  - `block-project-ssh-keys` is set.
  - ssh: a deny rule ranked above the project's allow, by secure tag, admits only the current
    egress addresses, and `start` updates them when they change.
  - Host keys are pinned from guest attributes.
- **Who may send work where:** a label allowlist per remote host (`submit_remote.burst = rig:*`),
  plus the cost caps. A cgroup controls resources but doesn't contain anything: it stops
  accidents, not attacks.

## Housekeeping

- **Copies** are evicted least-recently-used past 80% of the host's quota, under their lock.
  `cpuq copies [HOST]` lists them and `--clean` removes them.
- **Caches** are evicted by their own budgets.
- **Job records** are kept 14 days.
- **cpuq versions:** on each connect, a host's cpuq is checked. When it's older, the matching
  release for that host's OS and architecture is installed (checksum-verified), never the Mac's
  own binary.
- **systemd-tmpfiles** is kept out of `~/cpuq-spill`, which it doesn't touch today.

## Releases

1. **Now: cpuq 0.16.3.** A failed sync under `--spill-to` exits 125 instead of running here.
2. **Now: the burst runbook.**
   - *No service account:* `set-service-account` on the stopped VM, so no rebuild.
   - *ssh:* `block-project-ssh-keys`, guest attributes on, and the deny-by-tag rule.
   - *`start`:* waits through STOPPING, resets the shape to -96, and falls back to -64 or -48
     when Spot capacity runs out.
   - *The idle stop:* counts leases, and needs three failed status reads in a row.
   - *Ordering:* the stop-reason unit runs before `user@.service`.
   - *The rest:* `--max-run-duration`, no unattended upgrades, `zfs sync=disabled`, labels on
     both disks, and a system drop-in that takes oomd's kill policy off `user@.service`.
3. **0.17.**
   - `cpuq cap` as above.
   - Each Linux `cpuq run` job gets a scope with `Delegate=yes`. A small helper moves the job
     into `job/` once, and enables `+memory +pids`, `OOMPolicy=continue` and `MemorySwapMax=0`.
   - CPU and memory are read from cgroups.
   - The 14,000-call measurement.
4. **0.18.** `cpuq submit`, `jobs` and `job` as above, with `cpuq hook`'s `replaces` and
   background checks (the agent brief depends on them).
5. **Later.** History keyed by host shape; a CPU-time limit for `cap`.

## For Rig

An agent's whole protocol, the brief:

```
Heavy work goes through repo specs in cpuq/*.json; don't edit, copy or write specs.
Start one with Bash run_in_background:  cpuq submit cpuq/suite.json [-- TEST FILTER]
You're notified at the end. The last line is the verdict, and the exit status matches it:
  PASS 0 | FAIL 1: your code; the failures and their repro commands are printed above it.
  TIMEOUT / OOM: a limit; often a hang or leak in your change; check cpuq job last --tail 100.
  NOT RUN / LOST / CANCELLED / CPUQ ERROR: not your code; follow the hint on the line.
Never cat logs; use cpuq job last --tail N.
After compaction: cpuq jobs, then cpuq job last --wait (in the background).
Resubmitting unchanged work attaches; after edits, use --replace. Never loop.
Never add -j, --cores, hosts, ssh or rm -rf; never cancel another worktree's job.
```

Rig decides which specs each kind of change must pass. Rig provides:

- `test/results.jsonl` from matrix.py and test/run;
- failing programs kept under `test/failures` (capped);
- nexus built from source by `setup` into its cache, keeping its path and mtime stable (or a
  synced `src/parser.zig` accepted when `rig.grammar` hasn't changed).

## What round two changed

| change | from |
|---|---|
| Attach and retry by input digest; verdicts name it (v2 could PASS code the agent no longer had) | AWS, professor, CI, agent DX |
| A retry reruns the same generation on the host, with no new sync | professor, CI |
| Supervisor phases as flock'd states, reconciled when found orphaned | professor |
| Results fetched at once, behind a "results waiting" lease | AWS, professor |
| The stop reason recorded before jobs are stopped; any stop the job didn't cause is host loss | GCP |
| Transient services, not scopes; cpuq enables the controllers; time from admission | Linux (tested on pup) |
| OOM read from `memory.events.local`; `OOMPolicy=continue`; swap off; oomd handled by a system drop-in | Linux |
| FAIL always exits 1; CANCELLED 76; a RUNNING verdict; TIMEOUT/OOM may be your code | agent DX |
| A secrets lifecycle that a host-owned job can keep, from restricted sources | security |
| Copies keyed by hash of origin and realpath; under home, not `/var/tmp` (tmpfiles ages that) | professor, security, Linux, CI |
| Placement by `on` order: first feasible with room, then start, then queue; no scoring | AWS, GCP, professor |
| `tools` versions; `deps` are sources, built on the host; caches with budgets | CI |
| Budget in hours a month from the host's own ledger, checked at every submit | GCP, security |
| Release binaries matched to each host, not the Mac's | AWS, security, professor |
| The copy lock gives a waiting sync priority and re-checks the generation; eviction takes the lock | professor, Linux |
