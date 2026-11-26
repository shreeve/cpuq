# formal: cpuq's CPU sharing in Lean 4

A model of the CPU-sharing protocol in the approved plan (`FINAL-PLAN.md`, "How CPUs are shared"
and "Robustness", decision 7), with an exhaustive search at small sizes and proofs of its
guarantees. It models the protocol, not the Zig code.

## Build

Lean comes from elan, which reads `lean-toolchain` (Lean 4.35.0, as Rig's `formal/`). There are
no other dependencies.

```bash
cd formal && cpuq run --label cpuq:lean --cores 1 -- lake build
```

`lake build` checks every proof and runs every search in `Checks.lean` (about 30 s on pop).
Every warning is an error. A search whose result changes fails the build.

## Layout

| File | What it holds |
|---|---|
| `CpuqModel/Model.lean` | The state, the rule switches (`Rules`), and `step : Cfg → St → Act → Option St`, one constructor per action |
| `CpuqModel/Explore.lean` | The search: every reachable state, breadth first, and the checks run on each state, step and on the whole graph |
| `CpuqModel/Checks.lean` | The searches `lake build` runs, each with its pinned result |
| `CpuqModel/Lemmas.lean` | List and accessor lemmas |
| `CpuqModel/Safety.lean` | The invariant `Inv`, `Inv.init`, `Inv.step`, `Reach.inv`, and the guarantees as theorems |
| `CpuqModel/Transfers.lean` | Lemma P: the potential Σ nₚ²/wₚ |
| `CpuqModel/Liveness.lean` | Work conservation, drains for a head that holds nothing, drains as Lemma P transfers |

## The model

State, all finite: per CPU the token's flock holder (`lock`), the grant file (`grant`) and the
token file's record (`slot`: owner and whether it drains); per operation its phase (waiting,
alive, stopped, dead, over) and its tasks (pending, running on CPU c, timed out, done, failed,
gone; attempt number; a dying earlier attempt); the tickets in order; the shared drain count.

Actions (`Act`): arrive, a task's exit (pass or fail, with `-r` retries), timeout (TERM) and the
dying attempt's exit, refill, release, the hand-out pass, accept a grant, drain, undrain,
consolidate (rule 7), `cpuq kill`, SIGKILL of a parent (the kernel drops its flocks, its tasks
run on), Ctrl-Z stop and continue, finish.

Each action is one atomic step. Steps that change shared state run under the admission lock and
publish by one rename, so atomic steps are faithful to them. A release, `cpuq kill`, a stop and
an arrival end with a hand-out pass in the same step, as "whoever frees tokens grants them all in
one pass" says. A crash frees tokens with no pass; the next pass (the 1 s fallback, `Act.handout`)
hands them out.

`Rules` switches between FINAL-REPORT-1's rules (`report1`, as review2-formal reads them),
FINAL-PLAN's (`plan`), the plan read loosely (`planLoose`), the plan with this model's two
fixes (`fixed`), the rules the code implements on branch `slots` (`pool`, from `ahead`,
`handOut`, `firstWaiter`, `giver` and `behindAfter` in src/pool.zig, and the loop in src/op.zig),
those with this model's fixes for the code (`poolFixed`, which is the code on `slots` at
8f997ec), and the code at 0d315ed (`pool0d315ed`).

`pool` differs from `fixed` where the code does what the plan doesn't say: the giver's ticket is
renewed when it gives its CPU back, not when it starts to drain (`renewAtRelease`); one giver
is chosen as `giver` chooses (`oneGiver`); a drain is never cancelled (`undrains` off); dead
operations don't count in the line (`liveCounts`); a stopped operation stays in the line
(`stoppedWaits`).

## What is proved

No `sorry`. `#print axioms Cpuq.Reach.inv` lists only `propext`, `Classical.choice`, `Quot.sound`.

**Safety** (`Safety.lean`). `Inv` holds initially and every step keeps it, crashes, kills and
stops included, for any rules with the three safety switches on (`Safe`: reclaim on take; retry
a timed-out task only after its attempt exits; a slot with a dying attempt is not empty). The
liveness switches don't matter to safety. In every reachable state (`Reach.inv`):

| Guarantee | Theorem |
|---|---|
| S1 one holder per token: the flock holder is alive, the record names it, a held token has no grant | `one_holder` |
| S2 never more CPUs held than the pool | `pool_bound` |
| S3 never more than C slots per operation, grants included | `cap_bound` |
| S4 never more than K processes per slot | `k_bound` |
| S5 no task running twice at once | `no_double` |
| S1' no CPU shared: a process runs only on its holder's CPU, or (a dead operation's) on a CPU no one holds | `not_shared` |
| The drain count equals the number of draining slots | `drain_count` |
| S8 a grant goes only to the first in line | `grantOne_head` |

S8 covers grants. That a token's flock is taken only by its grantee under a standing line is by
the definition of `accept` (its guard); the only other take, `tryOnce`, runs only without a
standing line.

**Liveness, proved** (`Transfers.lean`, `Liveness.lean`):

| Statement | Theorem |
|---|---|
| Lemma P: a share-clause transfer lowers Φ = Σ nₚ²/wₚ by at least one step | `Transfers.phi_drops` |
| From any allocation at most Φ share-clause transfers happen in a row | `Transfers.run_bounded` |
| The transfer back is never allowed right after (no ping-pong) | `Transfers.no_reverse` |
| A share-clause drain is a transfer of Lemma P | `drain_is_transfer` |
| L2 work conservation: right after any hand-out pass, no token is free while anyone is in line | `handout_conserves` |
| … and with a standing line, in every reachable state, no token is free while an alive operation wants a slot | `work_conserving` |
| No tie-rule starvation: under FINAL-PLAN's rules, when the head holds nothing and a drain is owed, every other alive holder may drain | `zero_head_can_drain` |

**Liveness, searched, not proved.** "Every waiter is eventually served" (L3) is checked by the
search, in two forms, for every scenario: `L3 never` (no state from which no run serves a waiter
that holds nothing) and `L3 fair` (no weakly fair run, with no more crashes, that never serves
one). The search finds counterexamples to FINAL-PLAN here (Findings 1 and 2); with the fixes it
finds none. A general proof needs a ranking argument over fair traces; not done. The timed bound
(L4) is not done.

## What is assumed

- **Atomic critical sections.** Each shared-state step is atomic: in cpuq it runs under the
  admission lock and publishes by one rename. If the drain count and a token file are written
  separately, a parent killed between them would leave the count wrong; recount under the lock
  (count draining records of living owners) to keep the model's atomicity true.
- **The three safety switches** (`Safe`). FINAL-PLAN states the first; it is silent on the other
  two (Finding 3).
- **For liveness:** every task ends (A-term: `-t`, the 1 h machine default); no process is
  stopped holding the admission lock (A-sched); urgent arrivals are finite (A-urgent: the
  scenarios have finitely many operations); no task waits on a `cpuq run` outside its own tree
  (A-nest: nesting is not modelled); the fallback hand-out pass happens (A-wake); no more
  crashes, kills or stops after some time. The fair-run check makes every enabled step class
  weakly fair: a task's exit, refill, release, the pass, accept, drain, undrain, consolidate,
  continue, finish.
- **Small scope** for the search: up to 3 CPUs, 3 operations, K ≤ 2, 3 tasks per operation, one
  crash.

## Not modelled

- flock itself: the kernel's release is the crash step's atomic effect; NFS, fork/exec sharing
  of the open file, `LOCK_UN` vs close.
- Pinning and affinity, escapes, macOS (no pinning), `PR_SET_PDEATHSIG`, process groups and
  leftovers beyond a task's own processes.
- The Zig code, its files and their formats.
- The outside-load, memory and disk gates; pool changes (CPU offline, config edits); `-c` as a
  percentage (C is a whole number here).
- Nesting, the build jobserver, `cpuq drain`, the event log, output files.
- Which slot drains ("youngest process oldest"): any slot may. Retry order ("back of the
  operation's tasks"): the lowest pending task runs first. Both choices only widen what the
  search covers for safety.
- Time. Liveness is untimed; the timed bound is not done.

## What the search checks, and finds

Checks on every state: `S1 holder`, `S1 grant`, `S3 cap`, `S4 K`, `S5 twice`, `S1' shared`,
`S1' unheld`, `D count`, `L2 idle` (a CPU no one holds while an operation wants one, and no pass
or accept can run). On every drain: `F1 drain not owed`, `F6 drain not for the head`,
`F6 giver ahead`. On the graph: `L3 never`, `L3 fair`.

review2-formal's counterexamples, on FINAL-REPORT-1's rules (`Checks.lean`):

| review2 | Found as | Result |
|---|---|---|
| F1 drains herd for one waiter | `F1 drain not owed` | reproduced |
| F2 tie rule starves a waiter holding nothing | `L3 never`, `L3 fair` | reproduced |
| F3 free tokens idle while a holder has work | `L2 idle` | reproduced |
| F4 grant stranded by a waiter's crash | `L2 idle`, `L3 never` | reproduced |
| F5 a dead parent's tasks share a CPU with the next holder | `S1' shared` | reproduced |
| F6 a drain whose token goes to someone else | `F6 drain not for the head` | reproduced |

Each of FINAL-PLAN's fixes is needed: take out the standing line, the ledger, the share rule,
valid-only grants, or reclaim, and that counterexample returns.

FINAL-PLAN as written passes the crash, strand, timeout, herd and two-CPU scenarios, and fails
two liveness scenarios (Findings 1, 2). With both fixes, every scenario passes.

The code on branch `slots` (`pool`) has Findings 1 and 2 fixed and Finding 3's safe reading,
and fails three scenarios (Findings 4, 5). With the two fixes (`poolFixed`), every scenario
passes.

## Findings

Sent to the cpuq lead and Rig - Final on 2026-11-25. Traces: `narrate` in `Explore.lean`
prints any failure step by step.

**1. A waiter holding nothing starves behind a head no one may yield to.** 3 CPUs. A (project
P, 3 tasks) holds 2, B (project Q) holds 1 and wants more, C (project P) holds 0. B is head
(Q 1 < P 2). No one may yield to B: (1+1)/1 ≤ (2−1)/1 is false and B holds something. The
"holds nothing" clause applies only to the first waiter, so C waits until A or B runs out of
work. It happens whenever the split is one apart that way (odd pools, weights).
Fix (`zeroFirst`): an operation holding nothing ranks before every holder, after urgent.

**2. A giver drains for the head, then ranks ahead of it and takes the token back.** An urgent
operation (or one whose project share drops below the head's) drains its slot for the head;
holding nothing again, it is urgent class (or the lower share) and ranks first; the freed token
is granted back to it; repeat. A weakly fair run in which the head is never served. The fresh
ticket doesn't help: the ticket is the last key. Fix (`giverBehind`): drain only if the waiter
still ranks ahead of the giver after the drain. For the share clause across projects this always
holds; it bites only for the "holds nothing" clause and the urgent class.

Each fix alone still fails one of the two scenarios; both together pass all seven.

**3. "Its place frees at once" on a timeout.** Read loosely, the timed-out task's retry may start
while its TERMed attempt still runs (the task runs twice, S5), and a slot whose only process is
dying may be released and taken by another operation (the CPU is shared, S1'). The safety proof
assumes the plan states: retry a timed-out task only after its attempt has exited, and a slot
with a dying attempt is not empty. The place may still free at once for a different task.

The cpuq lead has fixes 1 and 2 in src/pool.zig, with these scenarios as unit tests, and src/op.zig
already had finding 3's safe reading.

**4. (src/pool.zig) `behindAfter` compares with the giver's old ticket.** The giver's ticket is
renewed only when it gives its CPU back (`giveBackEmpty`). On 2 CPUs, C and B hold one each in
different projects and A arrives holding nothing. Each giver, once it holds one fewer, ties A on
every key, and its older ticket wins, so `behindAfter` is false for both. No one gives, and A
waits until B or C runs out of work: review2's F2 again (the Mac's ten one-CPU runs and a
newcomer). Fix (`behindFresh`): compare with the ticket the giver will have, the newest.
Renewing the ticket when the drain starts also passes.

**5. (src/op.zig) A stopped operation stays first in line.** On Ctrl-Z, `suspend_` gives its CPUs
back, but its record still wants CPUs (`wantMore` counts the stopped tasks as waiting) and its
file stays locked, so promises to it stay valid. Holding nothing, it ranks first: the hand-out
in the same step promises its CPUs back to it, and later hand-outs and drains go to it too. On 3
CPUs, A holds all three and is stopped, B arrives, and the three CPUs idle until A continues.
Fix (`stoppedWaits` off): a stopped operation wants nothing until it continues.

The doc comment on `Op.want` says "beyond those it holds and is promised". `wantMore` leaves
promises out, and the line subtracts them, so the code is right and the comment is wrong.

Both landed: finding 4 in d14d347, finding 5 in 0d315ed.

**6. (src/op.zig) A promise made before a stop still idles its CPU.** Since 0d315ed a stopped
operation wants nothing and gets no new promises. But `promises` keeps any promise to an
operation whose file is locked, and `suspend_` doesn't drop the operation's own. A waits; B
releases a CPU and promises it to A; A is stopped before its loop takes it; the CPU idles until A
continues (`pool0d315ed`, the urgent scenario). Fix: in `suspend_`, under the lock and before the
hand-out, drop every promise to the operation's ticket. Landed in 8f997ec: with it, the code is
`poolFixed`, and every scenario passes.
