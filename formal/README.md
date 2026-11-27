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

`lake build` checks every proof and runs every search in `Checks.lean` (the searches take about
a minute and a half; a clean build checks the proofs first, several minutes more). Every warning is an error. A search whose result changes
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
| `CpuqModel/Line.lean` | Every holder has been served; a head holding nothing is never blocked |
| `CpuqModel/Backfill.lean` | Backfill: the rules' arithmetic in real time (the shadow never grows), the window closes, a gathering drain is served, no CPU runs two operations |

## The model

State, all finite: per CPU the token's flock holder (`lock`), the grant file (`grant`) and the
token file's record (`slot`: owner and whether it drains); per operation its phase (waiting,
alive, stopped, dead, over) and its tasks (pending, running on CPU c, timed out, done, failed,
gone; attempt number; a dying earlier attempt); the tickets in order; the shared drain count;
the pool lock's holder while a drain registers; the drains holding the drain mark; per
operation a Ctrl-Z not yet acted on, a SIGCONT still owed, whether the kernel has stopped it, and
whether it has held a CPU (the record's `served`).

Actions (`Act`): arrive, a task's exit (pass or fail, with `-r` retries), timeout (TERM) and the
dying attempt's exit, refill, release, the hand-out pass, accept a grant, drain, undrain,
consolidate (rule 7), `cpuq kill`, SIGKILL of a parent (the kernel drops its flocks, its tasks
run on), a Ctrl-Z arriving (`tstp`), the parent acting on it (`stop`), the parent raising
SIGSTOP on itself (`halt`), SIGCONT (`cont`), finish, and a drain's registration: it takes the
pool lock (`enter`), then its mark (`mark`).

Backfill (0.32.0) adds time, as little of it as the rules need: each operation's `-t` in ticks
(`OpCfg.tlimit`, 0 for none), and a window (`St.window`): the ticks left before the gathering
drain could start, src/pool.zig's `shadow` less the time now. A drain's registration opens it
(`Cfg.window`, the longest the search tries); time passing (`tick`, weakly fair) only shrinks it.

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
a SIGCONT continues it; a SIGCONT before the loop acts cancels the Ctrl-Z, and one after it
keeps the parent from raising SIGSTOP (`haltChecks`).

`cpuq drain` (`OpCfg.drain`) is an urgent operation with one command. It wants every CPU of the
pool while its command waits, starts it only holding them all, and keeps them while it runs.
While it holds the drain mark every other operation empties its CPUs. A stopped drain lets its
mark go and takes it again when continued (`drainLets`). Every free CPU goes to the drain that
wants one and holds or is promised the most, then the older ticket (`drainMost`); in 0.30.3, to
the first drain in ticket order that wants one; before that, to the first living drain, and to no
one while it wants none. Before backfill a drain never gives a CPU.

Backfill (`backfill`, 0.32.0). The shadow stands (`shadowed`) while exactly one drain gathers
(wants CPUs), no other drain holds a CPU, some other operation holds CPUs and runs tasks, and
every such operation has a time limit. Then an operation's task fits (`fits`) when it is no
drain and its limit is within the window. While a drain gathers, a free CPU goes first to the
best waiter in line that fits (`fitHead`), else to the drain as before; an operation that fits
keeps refilling instead of emptying its CPUs for the mark; and the gathering drain lends its
idle CPUs (`lends`): it marks one draining while what the waiters that fit still want is more
than it already empties, and gives it back without renewing its ticket. The line's own drains
go on as before: while the drain is first in line, the giver `giverOf` picks empties a CPU for
it, and the CPU goes to whoever fits.

An urgent operation goes ahead of the line only until it first holds a CPU (`urgentOnce`); before
0.30.3 it went ahead whenever it held none.

`Rules` switches between FINAL-REPORT-1's rules (`report1`, as review2-formal reads them),
FINAL-PLAN's (`plan`), the plan read loosely (`planLoose`), the plan with this model's two fixes
(`fixed`), the rules of the code on branch `slots` (`pool`), those with this model's fixes 4 to 6
(`poolFixed`, the code at 8f997ec), the code at 0d315ed (`pool0d315ed`), the code at 0.30.2
(`code0302`: the mark shared, a SIGCONT cancels a Ctrl-Z not yet acted on), the code at 0.30.3
(`code0303`: `code0302` with the fixes of Findings 7, 8 and 9, `urgentOnce`, `haltChecks` and
`drainLets`), the code at 0.30.5 and 0.31 (`code0305`: `code0303` with the fix of Finding 10,
`drainMost`), and the code as released in 0.32.0 (`released`: `code0305` with `backfill`).

`pool` differs from `fixed` where the code does what the plan doesn't say: the giver's ticket is
renewed when it gives its CPU back, not when it starts to drain (`renewAtRelease`); one giver
is chosen as `giver` chooses (`oneGiver`); a drain is never cancelled (`undrains` off); dead
operations don't count in the line (`liveCounts`); a stopped operation stays in the line
(`stoppedWaits`); a Ctrl-Z is received as the code receives it (`haltChecks` off). The plan's
rules say nothing of how a Ctrl-Z is received, so they have `haltChecks` on.

## What is proved

No `sorry`. `#print axioms` of `Reach.inv`, `lock_released`, `drain_served`, `Reach.servedOk`,
`zero_head_unblocked`, `window_closes`, `drain_served_backfill`, `one_op_per_cpu` and
`Timed.ends_by` lists only `propext`, `Classical.choice`, `Quot.sound` (`Reach.servedOk` and
`Timed.ends_by` not even `Classical.choice`).

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
| Under `urgentOnce`, every operation holding a CPU's flock has been served, in every reachable state | `Reach.servedOk` |
| Under the code's rules, with no drain living, a head holding nothing is never blocked: a CPU is unlocked, or one is being emptied, or some holder may start emptying one for it | `zero_head_unblocked` |
| Backfill, in real time: every task that starts fits the shadow, so the shadow never grows and every task the drain waits for ends by the first shadow `S`: the drain starts by `S` | `Timed.ends_by` |
| Backfill: with no new drain, in a weakly fair run the window closes and stays closed | `window_closes` |
| Backfill: once the window has closed, a gathering drain is served (`drain_served` for `released`) | `drain_served_backfill` |
| Backfill never puts two operations' tasks on one CPU (with `k_bound`, at most K of one) | `one_op_per_cpu` |

`drain_served` holds for the code's rules (`CodeRules`: `released`, `code0305`, `code0303`,
`code0302`), from a time at which backfill is shut (`Shut`: off, or its window closed). A run
(`Run`) is a sequence of moves and stutters from a reachable state; it is weakly fair
(`Run.Fair`) when every step class the search calls fair (`fairKey`: a task's exit whether it
passes or fails, refill, release, the pass, accept, drain, undrain, consolidate, stop, halt,
continue, finish, mark, a tick) that is enabled from some time on is taken from then on. The theorem
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

With backfill on, the proof starts once the window has closed: then nothing fits, a free CPU
goes to the drain as before, and the drain lends nothing, so `drain_frame` holds unchanged.
`window_closes` gives that time in every weakly fair run (a tick is a fair step, and only a
drain's registration opens the window). What is not proved is the stretch between: while the
window is open a CPU may move away from the drain (to a waiter that fits, or lent by the
drain), so the ranks can rise, and `DCtx` asks that the drain has every CPU it lent back. That
the lent CPUs come back (each is an empty slot being emptied, given back by a fair release) and
that the context holds through the open window is argued, and searched (`D never`, `D fair`,
below), not proved. The real-time bound is the rules' own arithmetic (`Timed.ends_by`): a task
starts only if it ends by the shadow, so the shadow never grows and the drain starts by the
first `S` it had. In the step function time is the window only, and a task may outlast it; that
over-approximation only widens what the search covers.

**Liveness, searched, not proved.** "Every waiter is eventually served" (L3) for ordinary
waiters is checked by the search, in two forms, for every scenario: `L3 never` (no state from
which no run serves a waiter that holds nothing) and `L3 fair` (no weakly fair run, with no more
crashes, kills or Ctrl-Z, that never serves one). The search finds counterexamples to FINAL-PLAN
(Findings 1 and 2) and to the code (Findings 4, 5, 7 and 10). On `released` every scenario
passes. For each `cpuq drain`, the search checks the same two forms over the states where it
gathers, whatever it holds: `D never` and `D fair`.

**L3 for ordinary waiters: what is proved, and what is left.** Up to 0.30.2, L3 was false for
the code (Finding 7). The proof of `zero_head_unblocked` shows what `urgentOnce` changes: a
holder that gives a CPU has been served (`ServedOk`), so it is not urgent again, and the head,
holding nothing, ranks ahead of it after the drain whenever the giver is of the head's project or
the head's project holds nothing. Such a giver always exists once every CPU is a slot not being
emptied, and `giverOf` then picks one. So the line never stalls with a waiter holding nothing at
its head and nothing under way for it.

What a proof of L3 still needs, under `released` with no drain living, no Ctrl-Z and no
`cpuq kill`, from a time after which no operation arrives or crashes:

1. The head is served. If `h` is the head and holds nothing at every step from some time on,
   some step gives `h` a CPU. `zero_head_unblocked` gives, in every such state, a CPU unlocked,
   a CPU being emptied, or an enabled drain for `h`. What is left is the ranking over CPUs that
   turns this into progress under `Run.Fair`, in `drain_frame`'s pattern. Free CPUs go to the
   head at the next pass. A grant to another operation is accepted (or dropped when its holder
   ends), and no new one is made while `h` is head. A CPU being emptied is released to the head.
   The drain `giverOf` picks stays enabled until a CPU is unlocked or starts emptying.
2. The head is reached. A waiter `w` holding nothing becomes the head and stays the head until
   it is served. Tickets only move back (a release renews the giver's), and an urgent operation
   goes ahead only until its first CPU. But each time an operation of a project with a lower
   share is served, the shares move, and so does the order among holders of nothing. Shown
   neither that this ends nor that it can't cycle: a measure over project shares is needed
   (Lemma P's Φ is the candidate, as `drain_is_transfer` makes each share-clause drain a
   transfer).
3. Phases settle. With no arrivals, crashes, kills or Ctrl-Z, each operation changes phase at
   most once more (alive to over), so from some time the phases hold still.

The drain proof's machinery (`Run`, `Run.Fair`, `Run.Calm`, the pass, accept and release
lemmas, `drain_frame`) carries over to 1. Item 2 is the open mathematical step. Lemma P does
not bound it as it stands: a head that holds nothing may take a CPU from any holder of two,
whatever the shares, so a drain for it is not always a share-clause transfer, and Φ can rise.
A measure for item 2 must use what `giverOf` picks (the giver whose project holds the most for
its weight) and the ticket order among holders of nothing together.

The timed bound (L4) is not done.

## What is assumed

- **Critical sections end.** Each critical section is one step except a drain's registration,
  which the model splits at its second lock. That is faithful while nothing else under the pool
  lock waits for another process. In the code (0.30.3): the pool lock itself (`lock`, blocking,
  taken outside any other lock); the drain mark (`markDrain`, a shared lock, which no one holds
  exclusively across a wait: `draining()` takes it exclusively with `tryLock` and lets it go at
  once; a drain continued takes it again under the pool lock, shared, so waiting for no
  one); tokens, op files and promises (`take`, `isFree`, `scan`, `promises`: `tryLock`, never a
  wait); a dead holder's leftovers (`killLeftovers`: SIGKILL, then at most 200 ms for each leader
  to be gone); file I/O. `cpuq status` takes the lock with `lockWithin(5000)` and gives up after
  5 s. A new lock taken under the pool lock must be split in the model the same way, as
  `enter` and `mark`; `CS stuck` and `lock_released` then cover it.
- **The three safety switches** (`Safe`). FINAL-PLAN states the first; it is silent on the other
  two (Finding 3).
- **For liveness:** every task ends (A-term: `-t`, the 1 h machine default); no process is
  stopped holding the pool lock (A-sched); urgent operations are finite in number and in work
  (A-urgent; with `urgentOnce` the line needs only the first half, Finding 7); no task waits on a `cpuq run` outside
  its own tree (A-nest: nesting is not modelled); the fallback hand-out pass happens (A-wake:
  the head looks every second, everyone else every 10 s); whoever sends a Ctrl-Z sends a SIGCONT
  (A-cont); no more crashes, kills or Ctrl-Z after some time. The fair-run check makes every
  enabled step class weakly fair, as `Run.Fair` does.
- **For backfill's real-time bound:** a task ends within its limit (`tlimit`: `-t` and the 10 s
  a kill and a restart may take), its whole tree included; every operation has seen the drain
  before it starts a task (an operation that looked just before the drain registered may still
  start one that doesn't fit, which the drain then waits for, as before backfill: in the model
  noticing the mark is atomic).
- **Small scope** for the search: up to 3 CPUs, 3 operations, K ≤ 2, 3 tasks per operation, one
  crash, one or two Ctrl-Z; on the released rules also 4 CPUs, weights over three projects, and
  backfill with windows of 2 and 3 ticks.

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
- A continued drain takes its mark again in its own critical section after the continue; the
  model does both in one step.
- A SIGCONT that continues a parent the kernel stopped also clears a Ctrl-Z noted meanwhile; in
  the model the parent acts on that Ctrl-Z once more, finds the continue, and goes on.
- Which slot drains ("youngest process oldest"): any slot may. Retry order ("behind the tasks
  not yet started"): the lowest pending task runs first. Both choices only widen what the search
  covers for safety.
- Time, but for backfill's window and limits. Liveness is untimed; the timed bound (L4) is not
  done. A task's end is not tied to its limit in the step function (`Timed` does that apart).
- Which idle CPUs a drain lends, and when a waiter wakes it to (any idle slot, at any step).

## What the search checks, and finds

Checks on every state: `S1 holder`, `S1 grant`, `S3 cap`, `S4 K`, `S5 twice`, `S1' shared`,
`S1' unheld`, `D count`, `L2 idle` (a CPU no one holds while an operation wants one, and no
pass or accept can run until some task ends), `CS stuck` (the pool lock's holder waits for a
lock only the pool lock lets go), `Z stuck` (a parent the kernel stopped that no SIGCONT will
continue). On every drain: `F1 drain not owed`, `F6 drain not for the head`, `F6 giver ahead`
(not for the emptying a live `cpuq drain` asks of everyone, nor a drain's lending). On the
graph: `L3 never`, `L3 fair`, and for each drain `D never`, `D fair`.

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
Finding 8). The code at 0.30.2 (`code0302`) passes two drains, and fails Findings 7, 8 and 9.
The code at 0.30.3 (`code0303`) passes every scenario but two drains, one stopped and continued
(Finding 10). The code at 0.30.5 (`code0305`) passes every scenario. Each of the four fixes is
needed: take one out and its scenario fails again.

The code as released (`released`, 0.32.0, backfill) passes every scenario with a drain, and
eight of backfill's own: an operation with a limit running and one waiting that fits sooner, on
2 and 3 CPUs (windows of 2 and 3 ticks), with a crash, a Ctrl-Z, two drains and a Ctrl-Z,
timeouts and retries, an urgent operation and `cpuq kill`, and with no limit in the way (no
backfill). No safety check fails, and no drain goes unserved (`D never`, `D fair`) nor waiter
holding nothing (`L3`). Backfill reaches states the rules before it don't (3969 against 1512 on
the first scenario): CPUs go to waiters that fit, and the drain lends. A drain gives CPUs back
without renewing its ticket, so the old drain scenarios reach fewer states than on 0.30.5. The
scenarios without a drain are 0.30.5's: backfill acts only while a drain gathers.

Even with time taken out (a mutation in which a task fits whatever the window), the search
finds the drain served (on `backfill` and on two drains with a Ctrl-Z; not pinned): while the drain is first in line, the line's own drains (`giverOf`)
keep emptying CPUs for it, and once no task the drain waits for runs, nothing fits. The window
is what bounds the wait in real time (`Timed.ends_by`), not what the untimed model needs.

## Findings

Sent to the cpuq lead and Rig - Final on 2026-11-25 (1 to 6) and 2026-11-26 (7 to 10). Traces:
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
one gives, and C waits as long as U has work (`urgentHolds`). P holds its fair share through U,
so this is fair to projects but not to C. Fix (`urgentOnce`, 0.30.3): an operation is urgent only
until it first holds a CPU (the record's `served`).

**8. (src/op.zig) A SIGCONT is lost while a parent stops.** 0.30.2 cancels a Ctrl-Z the loop has
not yet acted on. But once the loop takes it, `suspend_` gives the CPUs back under the pool
lock and only then raises SIGSTOP; a SIGCONT in between finds the parent running, does nothing,
and the parent then stops with no SIGCONT to come. A shell sees the stop and can continue it
again; a sender outside job control (an agent's `kill -TSTP; kill -CONT`) leaves the run stopped
for good (`Z stuck`, the Ctrl-Z scenario, before 0.30.2 and since). Fix (`haltChecks`): `onCont`
counts continues; `suspend_` notes the count when it takes the Ctrl-Z and skips the SIGSTOP if
the count has moved. That leaves only the instructions between the check and the raise, which a
raise of SIGSTOP cannot close. In 0.30.3.

**9. (src/pool.zig, src/op.zig) A stopped drain idles the pool.** While a `cpuq drain` is in the
line, `handOut` gives every free CPU to the first drain, and to no one while that drain wants
none. A drain stopped by Ctrl-Z wants nothing, its record stays, and it still holds the drain
mark, so every other operation keeps emptying its CPUs and every freed CPU idles until the drain
continues (2 CPUs, the drain and one operation with endless work: `L2 idle`, "drain, Ctrl-Z").
Fix (`drainLets`, 0.30.3): `suspend_` lets the drain mark go and the continue takes it again (a
shared lock, so it waits for no one), and `handOut` gives free CPUs to the first drain that wants
some.

**10. (src/pool.zig) A drain stopped and continued while a newer drain holds part of the pool:
the two drains wait for each other.** 2 CPUs, an operation A with endless work, and drains B
and C (B older). B is stopped by Ctrl-Z and lets its mark go; C arrives and is the first drain
that wants CPUs, so A empties a CPU and it is promised to C. B is continued, takes its mark
again, and is first again (its ticket is older: `suspend_` doesn't renew it), so the next CPU A
empties goes to B. Each drain holds one CPU and waits for the other's; a drain never gives one
(`giver` passes over drains, and a waiting drain keeps its slots), and every other operation
keeps emptying for the marks. The pool idles until a drain's `--max` runs out, and for good
without one (`L3 never`, "two drains, Ctrl-Z, 0.30.3"). Fix (`drainMost`, 0.30.5): `handOut`
gives free CPUs to the drain that wants some and holds or is promised the most, then the older
ticket. A stopped drain gives every CPU back, so at most one drain ever holds a CPU, and it is
served first.
