# formal: cpuq's CPU sharing in Lean 4

A model of the CPU-sharing protocol in the approved plan (`FINAL-PLAN.md`, "How CPUs are shared"
and "Robustness", decision 7) and of the rules the code implements (`src/pool.zig`,
`src/op.zig`), with an exhaustive search at small sizes and proofs of its guarantees. It models
the protocol, not the Zig code.

## Build

Lean comes from elan, which reads `lean-toolchain` (Lean 4.35.0, as Rig's `formal/`). There are
no other dependencies.

```bash
cd formal && cpuq run --label cpuq:lean -- lake build
```

`lake build` checks every proof and runs every search in `Checks.lean` (about 8 minutes on pop,
most of it the `urgent` scenarios). Every warning is an error. A search whose result changes
fails the build.

## Layout

| File | What it holds |
|---|---|
| `CpuqModel/Model.lean` | The state, the rule switches (`Rules`), `step : Cfg → St → Act → Option St` (one critical section per action) and `move` (`step` with the pool lock, the drain mark and Ctrl-Z as the code receives it) |
| `CpuqModel/Explore.lean` | The search: every reachable state, breadth first, and the checks run on each state, step and on the whole graph |
| `CpuqModel/Checks.lean` | The searches `lake build` runs, each with its pinned result |
| `CpuqModel/Lemmas.lean` | List and accessor lemmas |
| `CpuqModel/Safety.lean` | The invariant `Inv`, `Inv.init`, `Inv.step`, `Inv.move`, `Reach.inv`, and the guarantees as theorems |
| `CpuqModel/Transfers.lean` | Lemma P: the potential Σ nₚ²/wₚ |
| `CpuqModel/Liveness.lean` | Work conservation, drains for a head that holds nothing, drains as Lemma P transfers |
| `CpuqModel/Locks.lean` | The pool lock is always let go: no critical section waits forever |
| `CpuqModel/Drains.lean` | Runs and weak fairness; `cpuq drain` is served |

## The model

State, all finite: per CPU the token's flock holder (`lock`), the grant file (`grant`) and the
token file's record (`slot`: owner and whether it drains); per operation its phase (waiting,
alive, stopped, dead, over) and its tasks (pending, running on CPU c, timed out, done, failed,
gone; attempt number; a dying earlier attempt); the tickets in order; the shared drain count;
the pool lock's holder while a drain registers; the drains holding the drain mark; per
operation a Ctrl-Z not yet acted on, a SIGCONT still owed, and whether the kernel has stopped it.

Actions (`Act`): arrive, a task's exit (pass or fail, with `-r` retries), timeout (TERM) and the
dying attempt's exit, refill, release, the hand-out pass, accept a grant, drain, undrain,
consolidate (rule 7), `cpuq kill`, SIGKILL of a parent (the kernel drops its flocks, its tasks
run on), a Ctrl-Z arriving (`tstp`), the parent acting on it (`stop`), the parent raising
SIGSTOP on itself (`halt`), SIGCONT (`cont`), finish, and a drain's registration: it takes the
pool lock (`enter`), then its mark (`mark`).

`step` is the effect of one critical section: each runs under the pool lock (or is a parent's
own step) and publishes by one rename or under the lock, so an atomic step is faithful to it
while nothing in it waits for another process. A release, `cpuq kill`, a stop, a finish and an
arrival end with a hand-out pass in the same step, as "whoever frees tokens grants them all in
one pass" says. A crash frees tokens with no pass; the next pass (the 1 s fallback,
`Act.handout`) hands them out.

`move` is `step` with the locks and signals the code has. Every step that touches the pool
needs the pool lock free. A drain's registration takes the pool lock, then the drain mark (a
shared lock, or before 0.30.1 an exclusive one), then lets the pool lock go: two moves, so a
wait inside that critical section shows. Ctrl-Z is received as the code receives it: the handler
notes it, the loop acts on it (gives every CPU back), the parent raises SIGSTOP on itself, and
a SIGCONT continues it; a SIGCONT before the loop acts cancels the Ctrl-Z (0.30.2).

`cpuq drain` (`OpCfg.drain`) is an urgent operation with one command. It wants every CPU of the
pool while its command waits, starts it only holding them all, and keeps them while it runs.
While it lives it holds the drain mark, and every other operation empties its CPUs; every free
CPU goes to the first drain in ticket order, and to no one while that drain wants none. A drain
never gives a CPU.

`Rules` switches between FINAL-REPORT-1's rules (`report1`, as review2-formal reads them),
FINAL-PLAN's (`plan`), the plan read loosely (`planLoose`), the plan with this model's two fixes
(`fixed`), the rules of the code on branch `slots` (`pool`), those with this model's fixes 4 to 6
(`poolFixed`, the code at 8f997ec), the code at 0d315ed (`pool0d315ed`), the code as released in
0.30.2 (`released`: the mark shared, a SIGCONT cancels a Ctrl-Z not yet acted on), and that with
this model's fix 8 (`releasedFixed`).

`pool` differs from `fixed` where the code does what the plan doesn't say: the giver's ticket is
renewed when it gives its CPU back, not when it starts to drain (`renewAtRelease`); one giver
is chosen as `giver` chooses (`oneGiver`); a drain is never cancelled (`undrains` off); dead
operations don't count in the line (`liveCounts`); a stopped operation stays in the line
(`stoppedWaits`); a Ctrl-Z is received as the code receives it (`haltChecks` off). The plan's
rules say nothing of how a Ctrl-Z is received, so they have `haltChecks` on.

## What is proved

No `sorry`. `#print axioms` of `Reach.inv`, `lock_released` and `drain_served` lists only
`propext`, `Classical.choice`, `Quot.sound`.

**Safety** (`Safety.lean`). `Inv` holds initially and every move keeps it, crashes, kills, stops,
drains and the pool lock included, for any rules with the three safety switches on (`Safe`:
reclaim on take; retry a timed-out task only after its attempt exits; a slot with a dying
attempt is not empty). The liveness switches don't matter to safety. In every reachable state
(`Reach.inv`):

| Guarantee | Theorem |
|---|---|
| S1 one holder per token: the flock holder is alive, the record names it, a held token has no grant | `one_holder` |
| S2 never more CPUs held than the pool | `pool_bound` |
| S3 never more than C slots per operation, grants included | `cap_bound` |
| S4 never more than K processes per slot | `k_bound` |
| S5 no task running twice at once | `no_double` |
| S1' no CPU shared: a process runs only on its holder's CPU, or (a dead operation's) on a CPU no one holds | `not_shared` |
| The drain count equals the number of draining slots | `drain_count` |
| S8 a grant goes only to the first in line, or while a drain is in the line to the first drain | `grantOne_head` |

S8 covers grants. That a token's flock is taken only by its grantee under a standing line is by
the definition of `accept` (its guard); the only other take, `tryOnce`, runs only without a
standing line.

**No critical section waits forever** (`Locks.lean`). The pool lock is held across moves only
by a drain registering (`LockOk`, in every reachable state). With the mark shared, whoever holds
the pool lock can take its mark, register and let the pool lock go in one move, whatever anyone
else holds (`lock_released`). With the mark exclusive, a second drain waits for the first's mark
under the pool lock while the first waits for the pool lock: the search finds that deadlock
(`CS stuck`, "two drains, before 0.30.1").

**Liveness, proved** (`Transfers.lean`, `Liveness.lean`, `Drains.lean`):

| Statement | Theorem |
|---|---|
| Lemma P: a share-clause transfer lowers Φ = Σ nₚ²/wₚ by at least one step | `Transfers.phi_drops` |
| From any allocation at most Φ share-clause transfers happen in a row | `Transfers.run_bounded` |
| The transfer back is never allowed right after (no ping-pong) | `Transfers.no_reverse` |
| A share-clause drain is a transfer of Lemma P | `drain_is_transfer` |
| L2 work conservation: right after any hand-out pass, no token is free while there is someone to give it to | `handout_conserves` |
| … and with a standing line and no drain in it, in every reachable state, no token is free while an alive operation wants a slot | `work_conserving` |
| No tie-rule starvation: under FINAL-PLAN's rules, when the head holds nothing and a drain is owed, every other alive holder may drain | `zero_head_can_drain` |
| L3 for `cpuq drain`: in a weakly fair run, the first drain is given every CPU of the pool | `drain_served` |

`drain_served` holds for the code's rules (`CodeRules`: `released`, `releasedFixed`). A run
(`Run`) is a sequence of moves and stutters from a reachable state; it is weakly fair
(`Run.Fair`) when every step class the search calls fair (`fairKey`: a task's exit whether it
passes or fails, refill, release, the pass, accept, drain, undrain, consolidate, stop, halt,
continue, finish, mark) that is enabled from some time on is taken from then on. The theorem
starts from a time `T` after which no operation arrives or crashes (`Run.Calm`), at which the
drain `d` is first among drains, alive and waiting to run, holds its mark, the pool lock is free,
and no later drain holds or is granted a CPU (`DCtx`). The pool has no Ctrl-Z and no `cpuq kill`
(`Cfg.stops`, `Cfg.kills` off); timeouts and retries may be on. The proof ranks each CPU by its
distance from `d` (held by `d`, granted to `d`, free, being emptied by another, kept by another,
granted to another), shows no move raises a rank and the processes on a CPU being emptied only
leave (`drain_frame`), and that in every state some fair step lowers each CPU not yet `d`'s and
stays enabled until taken.

With `lock_released`, this covers the class of bug the model missed before: two drains can
neither deadlock on their locks nor starve each other in the line. The first is served; when its
command ends (A-term) it gives every CPU back and finishes (both fair), and the next drain is
first. That hand-on is argued, not proved.

**Liveness, searched, not proved.** "Every waiter is eventually served" (L3) for ordinary
waiters is checked by the search, in two forms, for every scenario: `L3 never` (no state from
which no run serves a waiter that holds nothing) and `L3 fair` (no weakly fair run, with no more
crashes, kills or Ctrl-Z, that never serves one). The search finds counterexamples to FINAL-PLAN
(Findings 1 and 2) and to the code (Findings 4, 5 and 7).

L3 in general is not proved for ordinary waiters, and as stated it is false for the code
(Finding 7): an urgent operation with endless work that holds one CPU starves a waiter of its own
project. A general proof needs A-urgent in a stronger form (every urgent operation's work ends)
or the fix of Finding 7, and then a ranking over the line that the drain proof does not need,
because a drain's target is fixed while an ordinary waiter's place moves. What that ranking must
show, with the drain proof's lemmas reusable for each step (the pass, accept and release
lemmas, `drain_frame`'s pattern, `Run.Fair`):

1. The head is served: once a waiter `w` holding nothing is the head, it gets a CPU. Free
   tokens go to the head at the next pass; with no urgent holder, some alive holder may give to
   `w` (any holder of two CPUs, or of `w`'s project, or of a project that stays at or above
   `w`'s share), its drain is owed, and the emptied CPU goes to the head when it is released.
   Open: the head at the release may be the giver itself, renewed only at release; `behindFresh`
   checked at the drain must be shown to still hold at the release.
2. The head is reached: tickets only move back (renewals), so the operations with older tickets
   than `w` only leave that set; each ranks ahead of `w` at most while it waits for its first
   CPU and while it holds only CPUs it is giving up. Open: project shares change as others are
   served, so an operation of a lower-share project can rank ahead of `w` again; a measure over
   project shares (Lemma P's Φ is the candidate) must bound how often.
3. Phases settle: with no more arrivals, crashes, kills or Ctrl-Z, each operation changes phase
   finitely often, so from some time they hold still.

The timed bound (L4) is not done.

## What is assumed

- **Critical sections end.** Each critical section is one step except a drain's registration,
  which the model splits at its second lock. That is faithful while nothing else under the pool
  lock waits for another process. In the code (0.30.2): the pool lock itself (`lock`, blocking,
  taken outside any other lock); the drain mark (`markDrain`, a shared lock, which no one holds
  exclusively across a wait: `draining()` takes it exclusively with `tryLock` and lets it go at
  once); tokens, op files and promises (`take`, `isFree`, `scan`, `promises`: `tryLock`, never a
  wait); a dead holder's leftovers (`killLeftovers`: SIGKILL, then at most 200 ms for each leader
  to be gone); file I/O. `cpuq status` takes the lock with `lockWithin(5000)` and gives up after
  5 s. A new lock taken under the pool lock must be split in the model the same way, as
  `enter` and `mark`; `CS stuck` and `lock_released` then cover it.
- **The three safety switches** (`Safe`). FINAL-PLAN states the first; it is silent on the other
  two (Finding 3).
- **For liveness:** every task ends (A-term: `-t`, the 1 h machine default); no process is
  stopped holding the pool lock (A-sched); urgent operations are finite in number and in work
  (A-urgent; Finding 7 shows the second half is needed); no task waits on a `cpuq run` outside
  its own tree (A-nest: nesting is not modelled); the fallback hand-out pass happens (A-wake:
  the head looks every second, everyone else every 10 s); whoever sends a Ctrl-Z sends a SIGCONT
  (A-cont); no more crashes, kills or Ctrl-Z after some time. The fair-run check makes every
  enabled step class weakly fair, as `Run.Fair` does.
- **Small scope** for the search: up to 3 CPUs, 3 operations, K ≤ 2, 3 tasks per operation, one
  crash, one or two Ctrl-Z.

## Not modelled

- flock itself: the kernel's release is the crash step's atomic effect; NFS, fork/exec sharing
  of the open file, `LOCK_UN` vs close.
- Pinning and affinity, escapes, macOS (no pinning), `PR_SET_PDEATHSIG`, process groups and
  leftovers beyond a task's own processes.
- The Zig code, its files and their formats; `cpuq status`.
- The outside-load, memory and disk gates; pool changes (CPU offline, config edits); `-c` as a
  percentage (C is a whole number here).
- Nesting, the build jobserver, the event log, output files, `--max` on a drain.
- A drain's mark outliving its record: the code closes the mark when `run` returns, just after it
  leaves the line; the model drops both at once.
- Which slot drains ("youngest process oldest"): any slot may. Retry order ("behind the tasks
  not yet started"): the lowest pending task runs first. Both choices only widen what the search
  covers for safety.
- Time. Liveness is untimed; the timed bound is not done.

## What the search checks, and finds

Checks on every state: `S1 holder`, `S1 grant`, `S3 cap`, `S4 K`, `S5 twice`, `S1' shared`,
`S1' unheld`, `D count`, `L2 idle` (a CPU no one holds while an operation wants one, and no
pass or accept can run until some task ends), `CS stuck` (the pool lock's holder waits for a
lock only the pool lock lets go), `Z stuck` (a parent the kernel stopped that no SIGCONT will
continue). On every drain: `F1 drain not owed`, `F6 drain not for the head`, `F6 giver ahead`
(not for the emptying a live `cpuq drain` asks of everyone). On the graph: `L3 never`,
`L3 fair`.

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
and fails three scenarios (Findings 4, 5). The code at 8f997ec (`poolFixed`) passes them, and
fails on two drains (`CS stuck`, the deadlock of 2026-11-26) and on a lost SIGCONT (`Z stuck`,
Finding 8). The released code (`released`) passes two drains and a drain beside a crash, and
still fails `Z stuck`. With the stop check (`releasedFixed`), every earlier scenario passes.
Finding 7's scenario fails on all of them, and a drain stopped by Ctrl-Z idles the pool
(Finding 9).

## Findings

Sent to the cpuq lead and Rig - Final on 2026-11-25 (1 to 6) and 2026-11-26 (7 to 9). Traces:
`narrate` in `Explore.lean` prints any failure step by step.

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

**6. (src/op.zig) A promise made before a stop still idles its CPU.** A stopped operation wants
nothing and gets no new promises. But `promises` keeps any promise to an operation whose file is
locked, and `suspend_` didn't drop the operation's own. A waits; B releases a CPU and promises it
to A; A is stopped before its loop takes it; the CPU idles until A continues (`pool0d315ed`, the
urgent scenario). Fix: in `suspend_`, under the lock and before the hand-out, drop every promise
to the operation's ticket. Landed in 8f997ec.

**7. (src/pool.zig) An urgent operation with endless work starves a waiter of its own
project.** 2 CPUs. U (project P, urgent, endless work) holds one CPU, B (project Q) the other, and
C (project P) waits holding nothing; C is head. U may not give: holding nothing it would be
urgent again (`urgentNow` checks only that it holds nothing) and rank before C, so
`behindAfter` refuses it. B may not give: Q would hold 0 and P 1, so B would rank before C. No
one gives, and C waits as long as U has work (`urgentHolds`, every code rule set). P holds its
fair share through U, so this is fair to projects but not to C. Proposed fix, not checked: an
operation is urgent only until it first holds a CPU ("urgent only for an operation's first CPU",
as `ahead`'s comment says). Else A-urgent must say every urgent operation's work ends.

**8. (src/op.zig) A SIGCONT is lost while a parent stops.** 0.30.2 cancels a Ctrl-Z the loop has
not yet acted on. But once the loop takes it, `suspend_` gives the CPUs back under the pool
lock and only then raises SIGSTOP; a SIGCONT in between finds the parent running, does nothing,
and the parent then stops with no SIGCONT to come. A shell sees the stop and can continue it
again; a sender outside job control (an agent's `kill -TSTP; kill -CONT`) leaves the run stopped
for good (`Z stuck`, the Ctrl-Z scenario, before 0.30.2 and since). Fix (`haltChecks`): `onCont`
counts continues; `suspend_` notes the count when it takes the Ctrl-Z and skips the SIGSTOP if
the count has moved. That leaves only the instructions between the check and the raise, which a
raise of SIGSTOP cannot close.

**9. (src/pool.zig, src/op.zig) A stopped drain idles the pool.** While a `cpuq drain` is in the
line, `handOut` gives every free CPU to the first drain, and to no one while that drain wants
none. A drain stopped by Ctrl-Z wants nothing, its record stays, and it still holds the drain
mark, so every other operation keeps emptying its CPUs and every freed CPU idles until the drain
continues (2 CPUs, the drain and one operation with endless work: `L2 idle`, "drain, Ctrl-Z").
Proposed fix, not checked: `suspend_` lets the drain mark go and the continue takes it again (a
shared lock, so it waits for no one), and `handOut` passes over a stopped drain.
