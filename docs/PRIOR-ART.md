# Everyone built pieces; nobody shipped cpuq

No one has shipped what cpuq does, but almost every piece of it has been built before. People have attacked this problem, many independent clients sharing one workstation's CPUs, since at least Linux autogroup in 2010. Each serious attempt was either abandoned or solved only within a narrower boundary:

- **one build system:** BitBake's PSI throttling, Buck2's resource control;
- **one Linux distribution:** Gentoo's CUSE-based `steve` jobserver, shipped November 2025;
- **one datacenter that owns every machine:** Borg, Autopilot;
- **one benchmark lock:** perflock.

Parallel coding agents made the problem acute in 2025-2026. An October 2026 GitHub issue describes cpuq's exact scenario: a 10-core Mac, six Claude runtimes, load 113-175, and builds stretching from 2-4 minutes to 25-47. Its fix was a count-based "build lease" ([alexec/Agents#234](https://github.com/alexec/Agents/issues/234)). Vendors cap the number of agents, not the CPU they use.

What is genuinely new in cpuq is the combination: a rootless, daemonless, macOS-capable queue that admits uncoordinated processes by measured CPU, sizes them from per-label history, and hands each one a jobserver of its grant. Two pieces have no peer found anywhere: direct measurement of other processes' CPU during a timing window, and lending an idle window to waiting jobs. Everything else has a precedent worth copying. The highest payoffs, in order:

1. Enforce the queue at the agent's tool boundary with a PreToolUse hook.
2. Automate Mac-to-Linux placement with icecream-style scoring and Sparrow-style late binding.
3. Stop mapping low priority to background QoS on Apple silicon.
4. Size the settle period from load-weighted peaks instead of averages.

These conclusions rest on searches of public sources. Small private scripts in people's dotfiles almost certainly exist and were not searchable.

## Fifteen years of "the build ate my machine" ended in fragments

The problem is old, well understood, and has never been solved in general. The Linux autogroup patch (2010) was written because "parallel kbuild has a negative impact on desktop interactivity". It gives each terminal session its own scheduler group, so one session's `make -j` competes as a single unit ([autogroup commit](https://gitea.osmocom.org/dect/linux-2.6/commit/5091faa449ee0b7d73bc296a93bca9540fc51d0a)). Later attempts followed the same pattern: each was stalled, scoped down or abandoned.

- **Yocto (2017).** A thread on servers hanging under high `-j` concluded that per-recipe limits were needed and that load checks don't fix the problem ([yocto list](https://docs.yoctoproject.org/pipermail/yocto/2017-August/037373.html)).
- **Portage (2019).** Gentoo bug 692576 asked for jobserver integration ([mgorny](https://blogs.gentoo.org/mgorny/?p=2439)).
- **NixOS (2021-2022).** PR 143820 (2021) never merged. In 2022 nixpkgs dropped `-l$NIX_BUILD_CORES` everywhere, called a shared jobserver "relatively complicated and only supports make", and told interactive users to use systemd limits instead ([nixpkgs commit](https://git.pub.solar/b12f/nixpkgs/commit/c2b898da7623a39e3c9b6265d311fe182aa526f0)).
- **GNU make (2022).** A proposal to add CPU-pressure limiting was rejected as non-portable. Howard Chu argued for a system-wide named-pipe jobserver instead ([bug-make](https://lists.endsoftwarepatents.org/archive/html/bug-make/2022-12/msg00063.html)).
- **Ninja.** Jobserver client support took **nine years and several failed PRs** (2016-2025). Its server ("pool") mode was merged only in September 2026 and is not yet released ([thebrokenrail.com](https://thebrokenrail.com/2025/06/30/ninja-jobserver.html); [ninja PR 2634](https://github.com/ninja-build/ninja/pull/2634)).
- **LLVM (2025).** Reviewers of the jobserver RFC warned that a token pool limits CPU, not RAM, so it cannot prevent ThinLTO linker OOMs ([LLVM Discourse](https://discourse.llvm.org/t/rfc-adding-gnu-make-jobserver-support-to-llvm-for-coordinated-parallelism/87034)).
- **Zig.** Issue #20274 is still open: nested thread pools each size themselves to the core count, so 2× the threads run ([zig #20274](https://github.com/ziglang/zig/issues/20274)).

These threads keep reaching the same four conclusions:

1. Per-build `-j` and `-l` don't compose. B concurrent builds at `-j C` run B×C jobs.
2. The load average lags. Chromium stopped passing `-l` to ninja because ninja keeps launching commands until the spike shows up in the load average, and `-l <cores>` made builds "much slower" on small machines ([depot_tools commit](https://git.morozoff.pro/aiden/depot_tools/commit/0db62fcf9c7e559f30b81073868f1a6d78a7f94a)).
3. A plain shared FIFO jobserver leaks tokens forever when a client is killed.
4. CPU tokens do not bound memory.

**The nearest relatives are two Gentoo jobservers from late 2025, and both are Linux-only.** Michał Górny's `steve` (in Gentoo as `dev-build/steve` 1.5.x) and amonakov's `guildmaster` each expose a GNU-make-compatible character device through CUSE. Every build on the box shares that one token pool. They needed a server rather than a FIFO for one reason: so tokens held by a dead client come back ([steve ebuild](https://ftp.fau.de/gentoo-portage/dev-build/steve/steve-1.5.2.ebuild); [guildmaster](https://codeberg.org/amonakov/guildmaster)). Górny's follow-up catalogs how badly clients behave:

- GNU make does not return tokens on SIGINT.
- GCC and make write back the wrong token character.
- **Cargo held every token for minutes while five other `emerge` processes waited.**
- pytest-xdist ignores the protocol entirely.

([mgorny, Sept 2026](https://blogs.gentoo.org/mgorny/?p=2734)). His original post also proposes a central jobserver that **"limits issuance based on system load"**. That is conceptually the closest anyone has come to cpuq's measured admission, and it remains a proposal: whether `steve` throttles by CPU pressure is an open Gentoo bug ([steve bugs](https://packages-cdn.gentoo.org/packages/dev-build/steve/bugs)).

The local job spoolers each cover one corner:

- **`nq`** is cpuq's direct structural ancestor. It has no daemon: each job holds a `flock` on its log file, inherited across exec, so the lock releases when the job dies. But it runs strictly one job at a time ([nq](https://github.com/leahneukirchen/nq)).
- **`sem`, task-spooler and pueue** offer fixed slot counts. pueue declares multi-user use out of scope ([pueue](https://github.com/Nukesor/pueue); [task-spooler](https://github.com/justanhduc/task-spooler)).
- **`batch`** admits by 1-minute load average with a compile-time default of 1.5. One user found batch jobs never ran on a 12-thread machine because load rarely fell that low ([Debian atd(8)](https://dyn.manpages.debian.org/trixie/at/atd.8); [llandsmeer](https://blog.llandsmeer.com/tech/2019/07/19/at-batch-unix.html)).
- **BitBake's `BB_PRESSURE_MAX_CPU/IO/MEMORY`** is the best shipped measured admitter. It holds new tasks while the per-second delta of the kernel's PSI stall counters exceeds a threshold. But it governs only BitBake's own tasks, and its docs admit "there is no algorithm" for choosing the threshold ([Yocto docs](https://docs.yoctoproject.org/_sources/dev-manual/limiting-resources.rst.txt); [bitbake patch](https://patchwork.yoctoproject.org/project/bitbake/patch/20220812151207.1616310-1-aryaman.gupta@windriver.com/raw/)).
- **Slurm and HTCondor** run fine on one machine. They need root, daemons and auth setup, and they reserve resources rather than measure them. Forum replies call this "a bit overkill" for one workstation ([Level1Techs](https://forum.level1techs.com/t/slurm-on-local-workstation/169116); [HTCondor](https://htcondor.readthedocs.io/en/23.0/man-pages/get_htcondor.html)).

| Tool | Coordination | Admission signal | History sizing | Memory gate | Timing windows | Cross-machine |
|---|---|---|---|---|---|---|
| [nq](https://github.com/leahneukirchen/nq) | flock files, no daemon | strict FIFO, one job | no | no | no | no |
| [sem / task-spooler / pueue](https://github.com/Nukesor/pueue) | semaphore files or a daemon | fixed slot count | no | GPU memory only (ts) | no | no |
| [at/batch](https://dyn.manpages.debian.org/trixie/at/atd.8) | atd daemon | 1-min load average | no | no | no | no |
| [BitBake](https://docs.yoctoproject.org/_sources/dev-manual/limiting-resources.rst.txt) | in-process, own tasks only | PSI deltas (Linux) | no | yes (PSI) | no | no |
| [steve / guildmaster](https://blogs.gentoo.org/mgorny/?p=2439) | root CUSE device (Linux) | fixed global token pool | no | no (requested) | no | no |
| [perflock](https://github.com/aclements/perflock) | root daemon | exclusive/shared lock | no | no | lock + governor pin | no |
| [agent-throttle](https://github.com/lucasrosati/agent-throttle) | semaphore + PreToolUse hook | slots from cores and RAM | suite p90 memory peak | yes | no | no |
| [RCH](https://github.com/Dicklesworthstone/remote_compilation_helper) | PreToolUse hook + SSH workers | worker slots, load, health | cache affinity | no | no | yes, automatic |
| [Buck2 resource control](https://github.com/facebook/buck2/blob/main/app/buck2_resource_control/src/scheduler.rs) | one daemon, cgroups | memory PSI, adaptive concurrency | learned memory budget | yes | no | races local vs RE |
| [icecream](https://raw.githubusercontent.com/icecc/icecream/master/scheduler/scheduler.cpp) | central scheduler | host load + slots | per-host speed | no | no | yes, automatic |
| cpuq | flock, no daemon | measured CPU per job tree | per-label p75 | yes | drain, noise, lend | manual (`--host` leases) |

## Parallel agents turned a nuisance into 25-minute builds

Every mainstream agent tool caps **agents, not CPU**:

- Claude Code allows 20 concurrent subagents by default (`CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS`), and that cap does not depend on hardware ([claude-code#80082](https://github.com/anthropics/claude-code/issues/80082)).
- Codex caps threads at a reported 6 via `max_threads` ([Morph](https://www.morphllm.com/codex-multi-agent)).
- Cursor runs up to 8 parallel agents in worktrees ([AgentPatterns.ai](https://www.agentpatterns.ai/tools/cursor/agents-window/)).

The only hardware-aware cap found is Claude Code's dynamic workflows, which allow 16 concurrent agents, "fewer on machines with limited CPU cores". Its formula is unverified ([Digital Applied](https://www.digitalapplied.com/blog/claude-code-subagent-depth-limits-budget-caps-2026)). An idle agent costs nothing. An agent running `xcodebuild` costs the whole machine. So a cap of 20 agents says nothing about load.

Cloud products avoid contention by duplicating machines. Codex cloud reportedly gives 2-4 vCPU per task ([SmartScope](https://smartscope.blog/en/blog/codex-cloud-environments-2026/)). The Copilot coding agent runs on a standard Actions runner ([GitHub docs](https://docs.github.com/en/copilot/how-tos/copilot-on-github/customize-copilot/customize-cloud-agent/customize-the-agent-environment)). E2B, Daytona and Modal sell 2-vCPU sandboxes by the hour ([bex.co](https://bex.co/blog/2026/09/09/e2b-daytona-modal-sandbox-pricing-self-hosted)). Every agent then pays for a cold build on a small machine, and of the sandbox providers surveyed, only Namespace offers macOS machines, so Xcode work stays on the Mac ([Upstash](https://upstash.com/blog/ai-agent-sandbox-providers-compared-2026)).

The field reports from the last two months look like cpuq's own design notes.

- **alexec/Agents #234 (October 2026).** On a 10-core / 16 GB Mac, six Claude runtimes and up to three concurrent `xcodebuild`s drove load to 113-175 and swap to 4.5 of 6 GB. A host build that took 2-4 minutes alone took 25-47 minutes when builds overlapped. The fix was to lower a count-based build lease from 3 to 2 and share a build cache. A cold build then took **205 s at load ~11 versus 313 s at load 134**, and "most of the gain came from lower machine load" ([alexec/Agents#234](https://github.com/alexec/Agents/issues/234)).
- **vfarcic/dot-agent-deck #863.** On a 16-core box, agents' Cargo builds pinned the disk while the CPU sat idle. An `ld`-triggered OOM killed system services, including chrony. The root cause was that "nothing bounds concurrent workspace builds" ([dot-agent-deck#863](https://github.com/vfarcic/dot-agent-deck/issues/863)).
- **mattshoe/mtg-api PR #43.** This project put a kernel `lockf` mutex around Gradle under the slogan "serialise the build, not the agents" ([mtg-api#43](https://github.com/mattshoe/mtg-api/pull/43)).
- **Tuist.** A test run spawned 78 concurrent `swift-frontend` processes on 6 cores, because "only the outermost layer is bounded" ([Tuist](https://hive.tuist.dev/forage/items/github-issue/08095955-9270-43b6-afac-ae2ebc35d838)).
- **kyleve/Stuff #141.** Agents raced each other to boot, install and erase the same iOS Simulator ([kyleve/Stuff#141](https://github.com/kyleve/Stuff/pull/141)). cpuq's named leases fit that resource directly.

The 2026 agent-coordination tools stop at mutexes and slot counts:

- **agent-lock** offers named `mkdir` mutexes with no counting and no CPU awareness ([agent-lock](https://github.com/fl4p/agent-lock)).
- **agent-throttle** has the most complete design. It provides a machine-wide `solo` semaphore whose slot count comes from cores and RAM. It also ships a Claude Code PreToolUse hook that blocks Jest, pytest and Playwright runs that lack an explicit worker count. Its motivation is cpuq's in one line: "no agent did anything wrong by its own instructions". It does not recognize `make`, and Codex has no hooks, so Codex users get only a rules file ([agent-throttle](https://github.com/lucasrosati/agent-throttle)).
- **RCH (remote_compilation_helper)** uses a PreToolUse hook to classify build commands and run them on SSH-reachable Linux workers, returning the artifacts. It chooses workers by speed, load, health and cache affinity, and falls back to local execution ([RCH](https://github.com/Dicklesworthstone/remote_compilation_helper)).

None of these admits by measured CPU, sizes jobs from history, or offers quiet windows for benchmarks. The field reached cpuq's premise independently, within weeks of each other, and has not yet gone past counting.

## Google, Microsoft and Meta solved measured admission by owning the machines

The algorithmic heart of cpuq, admitting work against measured use rather than declared reservations, is a well-published datacenter technique.

**Borg** sets each task's "reservation" equal to its request. After **300 s** of start-up, the reservation decays slowly toward actual usage plus a safety margin, and it rises quickly if usage exceeds it. Batch work is admitted into the reclaimed headroom, about 20% of a median cell's workload. Borg treats CPU (compressible) overshoot as throttling and memory (incompressible) overshoot as grounds for kills. An aggressive margin "increased slightly" the OOM rate, so Google deployed the medium setting ([Borg, EuroSys 2015](https://static.googleusercontent.com/media/research.google.com/en//pubs/archive/43438.pdf)).

**Autopilot** sizes jobs from their own history. It cut slack from 46% to 23% and severe OOMs tenfold. Its recipe:

- raise limits "swiftly" and lower them slowly;
- for batch CPU, use the mean;
- weight percentiles by load rather than by time: 9 units at load 1 plus 1 unit at load 10 gives a time-based p90 of 1 but a load-adjusted p90 of 10;
- add a 10-15% margin.

([Autopilot](https://homepages.dcc.ufmg.br/~cunha/teaching/20221/cloudcomp/readings/10-readings/rzadca20autopilot.pdf)). Microsoft's **Resource Central** found that naive 25% oversubscription caused 6× more resource exhaustion than prediction-informed oversubscription ([Cloud Intelligence keynote](https://cloudintelligenceworkshop.org/2020/content/Cloud%20Intelligence%20Keynote%20Public.pdf)).

For interference, the reference designs are CPI2 and Heracles. **CPI2** flags a task as anomalous only after 3 outliers in 5 minutes, and then hard-caps the antagonist for 5 minutes ([CPI2](https://static.googleusercontent.com/media/research.google.com/en//pubs/archive/40737.pdf)). **Heracles** reached 90% utilization with no SLO violations using graded thresholds: stop growing best-effort work below 10% slack, and reclaim cores below 5% ([Morning Paper](https://blog.acolyer.org/2015/06/16/heracles-improving-resource-efficiency-at-scale/)).

cpuq's design lines up with this literature point by point:

- its 20 s `settle` period is Borg's 300 s rule, rescaled;
- its "overcommit CPU, gate memory" split is Borg's compressible/incompressible split;
- `--opaque`, which counts a job at its whole grant forever, is Borg's prod-at-limit versus batch-at-reservation distinction in miniature.

None of this is new, but it is confirmation that cpuq rediscovered the right shape.

Big companies' *build* systems dodge cpuq's specific problem rather than solve it. Google's Forge sends every action through one central scheduler and queue to a pool of executors ([Bazel: Distributed Builds](https://bazel.build/basics/distributed-builds)). Locally, Bazel keeps a declared-resource ledger that defaults to all host CPUs and 67% of RAM. **Two Bazel servers on one machine each believe they own it** ([ExecutionOptions.java](https://github.com/bazelbuild/bazel/blob/master/src/main/java/com/google/devtools/build/lib/exec/ExecutionOptions.java)). Microsoft's CloudBuild (ICSE-SEIP 2016) and BuildXL publish caching and distribution, not CPU placement ([CloudBuild](https://www.microsoft.com/research/publication/cloudbuild-microsofts-distributed-and-caching-build-service/); [BuildXL](https://devblogs.microsoft.com/engineering-at-microsoft/large-scale-distributed-builds-with-microsoft-build-accelerator/)).

**Meta's Buck2** comes closest. Its cgroup-based resource control adapts local concurrency to memory pressure. It learns its memory budget as "the total memory in use by buck the last time we saw significant memory pressure", which implicitly accounts for non-Buck work. It freezes or kills and retries actions, but never suspends the oldest running action, so that progress is guaranteed ([buck2 scheduler.rs](https://github.com/facebook/buck2/blob/main/app/buck2_resource_control/src/scheduler.rs)). It is still a single daemon governing its own actions, not a referee between strangers.

The remote-execution vendors converged on lessons cpuq can borrow without adopting their protocol (REAPI):

- **Buildbarn** queues fairly per "invocation key", so every running build gets an equal share of workers. It learns size classes from history using a PageRank-style model ([Buildbarn scheduler.proto](https://github.com/buildbarn/bb-remote-execution/blob/master/pkg/proto/configuration/scheduler/scheduler.proto)).
- **NativeLink** types its matching properties as `exact` (OS) or `minimum` (CPU, memory). It offers `best_fit` placement, vetoes placements against live free memory because declared sizes are wrong, and fails fast on unsatisfiable work ([NativeLink schedulers.rs](https://github.com/TraceMachina/nativelink/blob/main/nativelink-config/src/schedulers.rs)).
- **BuildBuddy** tried round-robin, least-loaded and EWMA balancing, saw them fail, and adopted Sparrow: pick two random workers, enqueue on both, and let the first free one take the task ([BuildBuddy](https://www.buildbuddy.io/blog/distributed-scheduling-for-faster-builds)).

## Benchmark quiet windows have one ancestor and no peer

**perflock** is the only prior tool that serializes benchmarks on a *shared* host. It is a root daemon on a Unix socket. Exclusive commands exclude each other; "shared" commands (disturbers that are not benchmarks) may overlap each other. Exclusive holders get their CPU frequency pinned at 90% of the min-to-max range. It has 17 commits and no releases, it drains nothing it did not wrap, and it measures nothing ([perflock](https://github.com/aclements/perflock); [main.go](https://raw.githubusercontent.com/aclements/perflock/master/cmd/perflock/main.go)).

Every mature project instead assumes a dedicated machine:

- **pyperf** has `system tune`, which fixes the governor, disables Turbo and moves IRQs ([pyperf](https://pyperf.readthedocs.io/en/latest/system.html)).
- **LLVM** uses cset shields, turns off ASLR and SMT siblings, and expects under 0.1% variance ([LLVM](https://llvm.org/docs/Benchmarking.html)).
- **Go** reports only relative numbers taken in the same session, on consistent cloud VMs ([Go Wiki](https://go.dev/wiki/PerformanceMonitoring)).
- **Rust** gave up on wall time as its default metric. In one no-op change, user-space instruction counts moved at most about ±1.3% while wall time moved up to ±9.7% ([Rust internals](https://internals.rust-lang.org/t/what-is-perf-rust-lang-org-measuring-and-why-is-instructions-u-the-default/9815)).
- **CodSpeed** made Valgrind instruction counting its CI default because it is "immune to system load", and offers wall-time measurement only on its own bare-metal runners ([CodSpeed](https://codspeed.io/changelog/2024-11-06-walltime-instrument-and-codspeed-macro-runners)).

macOS makes isolation impossible rather than merely hard. In Tahoe, Spotlight and Siri cannot be fully disabled without turning off SIP ([Eclectic Light](https://eclecticlight.co/2026/01/16/can-you-disable-spotlight-and-siri-in-macos-tahoe/)). A 2026 study found that moving background work to E-cores at background QoS *increased* the slowdown of foreground work on Apple silicon by 13.9 percentage points ([NeurIPS 2026](https://neurips.cc/virtual/2026/170048)).

On a Mac, then, measuring and reporting noise is the realistic goal, and that is what cpuq does. **No timing tool found measures other processes' CPU during the run.** pyperf and hyperfine infer interference from the spread of their own samples, and Google Benchmark checks configuration ([hyperfine](https://github.com/sharkdp/hyperfine); [pyperf](https://pyperf.readthedocs.io/en/latest/analyze.html)). This is a negative result: pyperf's metadata fields were not fully checked.

The statistics literature adds a warning cpuq's docs should carry: a quiet machine is necessary but not sufficient. Mytkowicz et al. showed that changing only the size of the environment variables, or the link order, flipped conclusions about `-O3`. None of the 133 papers they surveyed controlled for this ([ASPLOS 2009](https://huang.isis.vanderbilt.edu/cs8395/readings/producing-wrong-data.pdf)). Kalibera and Jones show that repetitions belong at the level with the most variance, usually separate process executions rather than more iterations within one process ([Kent](https://kar.kent.ac.uk/33611/)).

## cpuq's novelty is the assembly, plus two pieces nobody shipped

So is the problem solved? **No. Nothing shipped coordinates CPU use across uncoordinated clients on a developer workstation, and certainly not on macOS.** Gentoo's partial solution is Linux-only and needs root, and it has existed for less than a year. The datacenter solutions work because one scheduler sees every task. The agent tools of 2026 are mutexes and slot counts, and their authors are still filing the incident reports that motivated cpuq.

The table judges each cpuq feature against its closest precedent.

| cpuq feature | Closest precedent | Verdict |
|---|---|---|
| flock state, no daemon, release on death | nq | inherited, extended to counting, priorities and history |
| measured-CPU admission across independent processes | BitBake PSI and Buck2 (in-process); atd and `make -l` (load average) | **new in scope**: no prior tool referees strangers by measured use |
| 20 s settle at expected use | Borg's 300 s reservation | rediscovered; correct shape |
| per-label history sizing of arbitrary commands | Autopilot, Buildbarn, Nx (inside their own systems) | **new outside a managed platform** |
| jobserver sized to each grant | steve and guildmaster (one global pool) | **new combination**; implicit slot already handled (k−1 tokens) |
| priorities, aging, backfill | Slurm, HTCondor | standard |
| memory gates and `max_memory` kill | BitBake, systemd-oomd, Buck2 | standard |
| exclusive windows that drain the queue | perflock, Slurm `--exclusive` | extended |
| direct noise measurement during windows | none found | **novel** |
| lending an idle window, freezing on reuse | Buck2 freezes actions under memory pressure; nothing for benchmarks | **novel application** |
| cgroup CPU weights | systemd `CPUWeight`, autogroup | standard; the right choice over quotas |
| `--opaque` | Borg prod-at-limit | rediscovered |
| cross-machine `--host` leases | icecream, RCH (automatic) | **behind prior art** |

cpuq's defensible novelty is not an algorithm; Borg published the core one in 2015. It is that cpuq works in a hostile setting, where the big systems would not:

- it runs without root;
- it runs on macOS, which has no PSI, no cgroups and no CUSE;
- it needs no daemon;
- it serves clients that never agreed to cooperate.

That is a niche the agent wave created, and nobody else occupies it yet.

## Nine things to copy, ranked by payoff

The ranking weighs evidence of real pain against implementation cost, and leaves out what cpuq already does: settle, `k−1` tokens, aging, backfill, PSI memory gates and `status --host`.

| Rank | Adopt | Source | Payoff | Cost |
|---|---|---|---|---|
| 1 | PreToolUse hook that blocks heavy commands run outside cpuq or without a worker count | agent-throttle, RCH | high | low |
| 2 | Automatic Mac↔Linux placement: exact-OS filter, local preference, late binding | icecream, Sparrow/BuildBuddy, NativeLink, Develocity | high | medium |
| 3 | Map `--priority low` to utility QoS or nice, not background QoS, on Apple silicon | Eclectic Light, NeurIPS 2026 | medium | trivial |
| 4 | Settle and ranges from load-weighted per-run peaks; rise fast, decay slow | Autopilot, Borg, VPA | medium-high | low |
| 5 | On Linux: PSI `cpu.pressure`, container cgroup `cpu.stat` for opaque work, `cgroup.freeze` for lending | BitBake, Buck2, kernel cgroup v2 | medium | medium |
| 6 | Jobserver hygiene: FIFO-style auth, token-return audit, hoarder log | steve, ninja `jobserver_pool.py` | medium | low |
| 7 | Per-session fairness within a priority class | Buildbarn invocation keys, icecream round-robin | medium | low |
| 8 | Timing-window statistics: per-label noise baseline, A/B interleaving, instruction-count fallback, Linux governor pin | rustc-perf, Go, Mytkowicz, perflock, pyperf | medium | low |
| 9 | Graded saturation response on Linux; never freeze the oldest job | Heracles, CPI2, Buck2 | low-medium | medium |

**1. Enforce the queue where agents act.** The most common failure in the field reports is an agent running a heavy command bare, or with unbounded inner parallelism: Tuist's 78 compilers on 6 cores, agent-throttle's Jest runs that pushed a 16 GB laptop past 27 GB. AGENTS.md is advice. A hook is enforcement. agent-throttle shows the shape: a PreToolUse hook that inspects the Bash command and refuses it with the corrected form. For cpuq, the hook would refuse `cargo build`, `zig build`, `xcodebuild`, `swift test`, `make`, `pytest` and similar when they run outside `cpuq run` and no `CPUQ_TOKEN` is set. It would also refuse those that appear inside `cpuq run` without `-j"$CPUQ_CORES"` ([agent-throttle](https://github.com/lucasrosati/agent-throttle)). Two gaps to cover: agent-throttle's guard misses `make`, so cpuq's must include it, and Codex still has no hooks, so AGENTS.md remains its only lever.

**2. Make "move it to the build box" automatic, at N=2.** RCH's 3,900 commits show the demand ([RCH](https://github.com/Dicklesworthstone/remote_compilation_helper)). cpuq already has the plumbing in `lease --host` and `status --host`. The policy to copy:

- **Capability filter.** Use an exact `os` property and default to macOS-only, because wrongly sending Mac work to Linux fails while wrongly keeping Linux work local only costs time ([REAPI platform lexicon](https://github.com/bazelbuild/remote-apis/blob/main/build/bazel/remote/execution/v2/platform.md)).
- **Fail fast.** Return an "unsatisfiable" error for a minimum no machine can ever meet ([NativeLink](https://github.com/TraceMachina/nativelink/blob/main/nativelink-config/src/schedulers.rs)).
- **Score hosts like icecream.** Use speed × free capacity, with a ×1.1 bonus for a lightly loaded local machine and a penalty when it is over its slots ([icecream scheduler](https://raw.githubusercontent.com/icecc/icecream/master/scheduler/scheduler.cpp)).
- **Late binding (Sparrow).** Queue on both machines and let the first grant cancel the other ([BuildBuddy](https://www.buildbuddy.io/blog/distributed-scheduling-for-faster-builds)).
- **Local stays eligible.** Prefer remote, with a wait timeout before falling back to local ([Develocity](https://docs.develocity.ai/test-distribution/)).
- **Back off dead hosts.** Skip an unreachable host for about 60 s ([distcc](https://www.distcc.org/man/distcc_1.html)).

The hard part is not scheduling but getting source to the build box and artifacts back. RCH returns artifacts "as if compiled locally". cpuq can initially require that the command be host-agnostic, such as a script that syncs its own tree.

**3. Stop sending low-priority builds to the E-cores.** cpuq runs `--priority low` at background QoS on macOS. On Apple silicon, threads at that QoS run only on E-cores and are never promoted, "even when P cores sit idle" ([Eclectic Light](https://eclecticlight.co/2022/01/24/how-you-cant-promote-threads-on-an-m1/)). The 2026 study found that E-core background work hurt foreground work *more* than the same work at normal QoS ([NeurIPS 2026](https://neurips.cc/virtual/2026/170048)). Utility QoS or nice keeps low-priority jobs work-conserving. This is a one-line change; benchmark it on the Mac before shipping.

**4. Size the settle period from peaks, not averages.** Today, expected use is the 75th percentile of each run's *average* active cores (docs/DESIGN.md). A build that averages 3 cores but fans out to 10 during compile or test phases counts as 3 during its settle period. That is exactly the time-based-percentile trap Autopilot's load-weighted percentiles were built to avoid ([Autopilot](https://homepages.dcc.ufmg.br/~cunha/teaching/20221/cloudcomp/readings/10-readings/rzadca20autopilot.pdf)). The fix has three parts:

- record a load-weighted per-run peak (for example, p90 of the 1-second samples);
- make the running estimate asymmetric, rising instantly and decaying over the current time constant;
- widen the estimate for labels with short history, as Kubernetes VPA's confidence multiplier does ([jorijn.com](https://jorijn.com/en/knowledge-base/kubernetes/monitoring/kubernetes-vertical-pod-autoscaler-vpa/)).

The history is already collected, so this is cheap.

**5. On the Linux box, let the kernel do the measuring.** Four Linux mechanisms fit cpuq:

- **CPU pressure.** PSI `cpu.pressure` "some", system-wide and per scope, is a kernel-measured "threads waiting for CPU" signal. BitBake has proved it as an admission input ([kernel PSI doc](https://docs.kernel.org/accounting/psi.html)).
- **Opaque work.** cpuq could read a container's `cpu.stat` directly and measure its real use instead of charging its whole grant. Docker and incus place containers in their own cgroups. This is an inference, untested.
- **Lending windows.** `cgroup.freeze` freezes a whole scope atomically, including children forked mid-freeze. That is cleaner than walking a process tree with SIGSTOP. Also an inference; verify it.
- **Learned capacity.** Buck2's idea of learning capacity as "use at the last pressure event" captures load from outside cpuq ([buck2](https://github.com/facebook/buck2/blob/main/app/buck2_resource_control/src/scheduler.rs)).

**6. Harden the jobserver.** cpuq hands out an anonymous pipe through `--jobserver-auth=R,W`. But ninja 1.13's POSIX client supports only the FIFO style ([thebrokenrail.com](https://thebrokenrail.com/2025/06/30/ninja-jobserver.html)). Anonymous-pipe descriptors also get lost when a sub-make is launched indirectly through Cargo ([servo/mozjs#375](https://github-redirect.dependabot.com/servo/mozjs/issues/375)). Exporting `fifo:PATH` for make 4.4+ and ninja, while keeping `--jobserver-fds` for macOS's make 3.81, would put one token pool behind both styles. At job exit, check that all k−1 tokens came back and log leakers per label, as ninja's `jobserver_pool.py` and `steve` do ([jobserver_pool.py](https://github.com/ninja-build/ninja/blob/master/misc/jobserver_pool.py); [mgorny](https://blogs.gentoo.org/mgorny/?p=2734)).

**7. Give each session a fair share.** Within a priority class cpuq is first-come, first-served, so one agent that fans out ten test jobs gets ahead of a single job from another agent. Buildbarn's invocation keys and icecream's round-robin by submitter give each client an equal share ([Buildbarn](https://github.com/buildbarn/bb-remote-execution/blob/master/pkg/proto/configuration/scheduler/scheduler.proto)).

**8. Make timing windows statistically honest.** Five additions, mostly documentation:

- Record the noise level of each window and flag runs that are outliers against the label's own history, using rustc-perf's Q3 + 3×IQR rule ([rustc-perf](https://raw.githubusercontent.com/rust-lang/rustc-perf/master/docs/comparison-analysis.md)).
- Recommend interleaved A/B runs within one window over stored baselines, following Go and Mytkowicz.
- Document the recipe `cpuq run --exclusive -- hyperfine --warmup 3`.
- Where `exclusive = off`, offer an instruction-count fallback (`perf stat -e instructions:u`).
- Pin the CPU governor on the Linux build box during windows, opt-in, as perflock and `pyperf system tune` do.

**9. Graduate the saturation response.** On Linux, Heracles' 10%/5% slack tiers and CPI2's debounced, time-boxed penalties suggest a second step beyond "stop admitting": lower the weight of the newest low-priority job, or set `cpu.idle` on it, when saturation persists. Never freeze the oldest job. That is Buck2's guarantee of progress.

Some things to decline. Slurm, HTCondor and REAPI farms need root and daemons, reserve rather than measure, and serve only Bazel-style clients. `steve` and guildmaster are Linux-only and give one global pool, not grants. Per-agent cloud VMs can't run Xcode, and alexec's measurements favor a shared warm machine. CPU quotas (`cpu.max`) stall bursty parallel jobs even below their limit ([jorijn.com](https://jorijn.com/en/knowledge-base/kubernetes/monitoring/kubernetes-cpu-throttling-pods-stall-low-utilisation/)).

## Conclusion

This survey changes where cpuq's risk lies. The admission algorithm is the least novel part, because Borg and Autopilot validated it at scale, so cpuq should copy their estimator details rather than tune its own. The real exposure is at the edges: clients that don't cooperate (Cargo hoarding tokens, `zig build` ignoring the jobserver, agents that skip the wrapper) and work cpuq can't see (containers, simulators, the other machine). Every serious prior attempt, from `steve` to Buck2 to agent-throttle, spent most of its effort on those edges, not on the scheduling math. That argues for spending cpuq's next releases on enforcement hooks, kernel-side measurement on Linux, and automatic placement, not on refining the admission policy.

The timing is unusual. Within six weeks in September and October 2026, at least four unrelated projects independently built mutexes or slot leases for agent builds. Each wrote up an incident cpuq's README could have described. The niche is real, unoccupied, and about to fill with simpler tools. cpuq's advantage is that it already handles measured use, history, memory and benchmark windows that those tools have not reached. It loses that advantage only if agents keep bypassing it, which is why the hook ranks first.
