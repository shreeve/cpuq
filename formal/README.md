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
fails the build. The certificates (`CpuqModel/Certs/`) are checked by the kernel, which takes
about six minutes more (one to two minutes each, up to 3 GB; they check one at a time). After a change to the model or the rules, write them again:

```bash
cd formal && cpuq run --label cpuq:lean -t 20m -- lake env lean --run scripts/GenCerts.lean
```

It fails if a ranking no longer exists (a weakly fair run that starves, the search's `L3 fair`).

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
| `CpuqModel/DrainCap.lean` | A drain's time limit: under 0.32.0 nothing bounds a drain's run; with the limit it holds CPUs at most limit + grace; FIFO lets no drain pass an older waiter holding nothing |
| `CpuqModel/Fifo.lean` | How a step changes the tickets; while a waiter holds nothing, a drain that queued after it never takes a CPU ahead of it (every configuration) |
| `CpuqModel/Cert.lean` | Certificates: the search's graph and a ranking, checked by the kernel; `served_of_cert`, what one proves (the response rule under weak fairness); no action outside `actsAll` is ever enabled |
| `CpuqModel/CertGen.lean`, `scripts/GenCerts.lean` | Writes the certificates from the search (compiled code; nothing it does is trusted) |
| `CpuqModel/Certs/*.lean` | The certificates, written by `scripts/GenCerts.lean`, each with the theorems the kernel checks |
| `CpuqModel/Served.lean` | Waiters and drains served, proved for the configurations certified |
| `CpuqModel/Contest.lean` | 0.40.0, contested CPUs: the admission rules; the five properties proved for every configuration with two rule changes, and the gaps of the design as written as reachable states |
| `CpuqModel/Contest035.lean` | The slot rules before 0.40.0 hold a CPU idle while a task waits (a reachable state of `moveX` under `Rules.released`) |

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

A drain's time limit (`drainCap`, after 0.32.0) adds a clock per drain (`St.clock`): its
command's start sets it to the limit and the grace (`drainLimit`: `-t`, else `Cfg.drainDefault`,
at most `Cfg.drainCeil`, never off; `Cfg.grace`), each tick counts it down, TERM comes when only
the grace is left and KILL at 0, and while an alive drain holds CPUs with its clock out or its
command ended, time doesn't pass (`due`): it gives its CPUs back first. The idle stop is an
earlier TERM (`timeout` on a drain, at any time), so it is only a sooner end. A stream of drains
(`OpCfg.again`): a drain that finishes arrives again later, with a new ticket. These live in
`moveX`, `move` with the extensions, which the search runs; with none on, `moveX` is `move`.

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
`drainMost`), the code at 0.32.0 (`code0320`: `code0305` with `backfill`), at 0.33.0
(`code0330`: with the drain's time limit), and as released in 0.34.0 (`released`: `code0330` with
FIFO, `drainFifo`, and drain sizes, `drainSize`). FIFO: while a drain gathers, a free CPU goes
first to the best waiter that is no drain, holds nothing (no CPU, no promise) and has an older
ticket than the oldest gathering drain (`olderHead`, src/pool.zig's `before`); the CPU it accepts
runs a task before it empties for a drain (`place`, as `emptyForDrain` marks only slots that have
run a task); its give-back renews its ticket. Drain sizes: `-c N` gathers `N` CPUs (`cap`) and is
owed them by the line's giver; only a gathering `--all` drain (`OpCfg.all`) makes the operations
that have started empty their CPUs (`markOn`) and has backfill; `-c N` may run 2 hours, `--all` 20
minutes (`drainCeil`, `drainCeilAll`). Two rules tried on the way, searched only: `turn2087`
(drain-turn at 2087ebe: a drain takes its turn behind older runs that have yet to start a task,
`drainTurn`) and `turnEfa` (efa0af3: that with drain sizes and `placeFirst`).

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
`Timed.ends_by` not even `Classical.choice`). The same for `hold_bound`, `released_hold_bound`,
`released_holds_forever`, `code0305_holds_forever`, `code0320_stream_starves`,
`code0305_stream_starves`, `fifo_no_pass` and `released_fifo_no_pass`, and for
`released_no_younger_pass`, `served_of_cert` and the theorems of `Served.lean` (pinned in
`Served.lean` by `#print axioms`). The certificates are checked by `decide +kernel`, which adds no
axiom (no `native_decide`).

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
| Backfill: once the window has closed, a gathering drain is served (`drain_served` for `code0320`) | `drain_served_backfill` |
| Backfill never puts two operations' tasks on one CPU (with `k_bound`, at most K of one) | `one_op_per_cpu` |
| 0.31 and 0.32.0: a drain whose command runs holds the pool while a waiter waits, and only the command's own end is enabled; the run that stays there is weakly fair for every other class, so only A-term ends it | `code0305_holds_forever`, `released_holds_forever` |
| 0.31 and 0.32.0: two drains taking turns starve a one-task run on 1 CPU: a weakly fair lasso (a cycle of moves back to its start, the run waiting holding nothing throughout, every step class enabled throughout taken in it) | `code0305_stream_starves`, `code0320_stream_starves` |
| 0.34.0: `hold_bound` (limit + grace, the limit at most its ceiling) and `fifo_no_pass` for the released rules | `released_hold_bound`, `released_fifo_no_pass` |
| With the drain's limit: through any stretch in which a drain is alive, holds a CPU and has started its command, at most limit + grace ticks pass | `hold_bound` |
| … its start sets the clock to limit + grace, no step raises it, and an idle stop only lowers it | `moveX_start`, `ReachX.clk_le`, `moveX_clk` |
| … once its command has ended, no time passes before it has given every CPU back | `ended_no_tick` |
| FIFO: a free CPU goes to a drain only if every waiter that holds nothing and is no drain has a younger ticket | `fifo_no_pass` |

`drain_served` holds for the code's rules up to 0.32.0 (`CodeRules`: `code0320`, `code0305`, `code0303`,
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

**Liveness for fixed configurations, proved** (`Cert.lean`, `Served.lean`, `CpuqModel/Certs/`).
The search's `L3 fair` and `D fair` become proofs for the configuration they search. A certificate
is the search's whole graph over every action that can be enabled (`actsAll`: the search's actions
and a failing exit for every task; `moveX_acts` shows no other action is ever enabled) and, for a
waiting condition, a rank and a helpful action of a weakly fair class for each waiting state. The
kernel checks it (`decide +kernel`): every state's successors under every action are what `moveX`
gives (`graphOk`, so every reachable state is in the graph: `reach_in`), and every step between
waiting states lowers the rank, or keeps it, keeps the helpful action enabled and is not of its
class (`rankOk`). `served_of_cert` proves what that means: in every weakly fair run of `moveX`
(`RunX.Fair`: `Run.Fair` for `moveX`), the condition never holds forever. This is the standard
proof rule for a response property under weak fairness; `scripts/GenCerts.lean` writes the
certificates from the search (`CertGen.lean`), and nothing it does is trusted.

| Statement | Theorem |
|---|---|
| A certificate that checks proves the waiting condition never holds forever, in every weakly fair run | `served_of_cert` |
| No action outside `actsAll` is ever enabled (from a state of the configuration's shape) | `moveX_acts` |
| 0.34.0, 1 CPU, a one-task run and two `-c 1` drains that come back after each finish (the configuration where 0.31 and 0.32.0 starve the run, `code0320_stream_starves`): the run never waits holding nothing forever | `released_stream_served` |
| … and each drain never gathers forever | `released_stream_drains_served` |
| 0.34.0, 1 CPU, a run with endless work and two `--all` drains in a stream: the run and each drain are served | `released_stream_all_served` |
| 0.34.0, 1 CPU, a `-c 1` drain against one-task runs that come back after each finish: the drain starts, and each run is served | `released_waiter_stream_served` |
| 0.34.0, no drain, 2 CPUs, Finding 7's configuration (an urgent operation with endless work; 0.30.2 starves P's second operation there): no operation waits holding nothing forever (L3 without drains, for this configuration) | `released_urgent_holds_served` |

The certificates are the searches' graphs over `actsAll`, so they cover more runs than the pinned
searches (a task of an operation without `-r` may also fail): 3788, 2686, 3314 and 3683 states.
Under 0.32.0 the stream configuration has no ranking for the run (`CertGen` finds the weakly fair
run that starves it, as `code0320_stream_starves` proves), and under 0.30.2 Finding 7's has none for
P's second operation.

**Drains that queued after a waiter never pass it, proved in general** (`Fifo.lean`). While a
waiter `w` (no drain) waits holding nothing, the tickets keep their order around it: an arrival
queues behind it, a give-back moves only the one giving back to the back, a finished drain of a
stream leaves the line and comes back behind it (`moveX_order`, `behind_step`, `behind_run`). With
`fifo_no_pass`: at any time while `w` waits holding nothing, a free CPU goes to a drain only while
some drain that held a ticket ahead of `w`'s when `w` started waiting gathers
(`released_no_younger_pass`), for every configuration. A stream of drains that come back after `w`
queued never takes a CPU ahead of it on its own. This is not liveness: it says nothing of the
drains that queued before `w` (finitely many, each bounded once its command starts by
`released_hold_bound`, but not proved to start), or of the line's own order among waiters (L3).

**Liveness, searched, not proved in general.** "Every waiter is eventually served" (L3) for ordinary
waiters is checked by the search, in two forms, for every scenario: `L3 never` (no state from
which no run serves a waiter that holds nothing) and `L3 fair` (no weakly fair run, with no more
crashes, kills or Ctrl-Z, that never serves one). The search finds counterexamples to FINAL-PLAN
(Findings 1 and 2) and to the code (Findings 4, 5, 7 and 10). On `released` every scenario
passes. For each `cpuq drain`, the search checks the same two forms over the states where it
gathers, whatever it holds: `D never` and `D fair`. `L3 fair` and `D fair` are proved for the
configurations certified (above); for every other scenario they are searched, and for
configurations past the search's sizes nothing is proved.

**L3 for ordinary waiters: what is proved, and what is left.** Up to 0.30.2, L3 was false for
the code (Finding 7). The proof of `zero_head_unblocked` shows what `urgentOnce` changes: a
holder that gives a CPU has been served (`ServedOk`), so it is not urgent again, and the head,
holding nothing, ranks ahead of it after the drain whenever the giver is of the head's project or
the head's project holds nothing. Such a giver always exists once every CPU is a slot not being
emptied, and `giverOf` then picks one. So the line never stalls with a waiter holding nothing at
its head and nothing under way for it.

L3 for `released` with no drain is proved for one configuration, Finding 7's
(`released_urgent_holds_served`, by certificate), and searched for the others. What a proof of L3
for every configuration still needs, under `released` with no drain living, no Ctrl-Z and no
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

With drains, a general proof needs these and two more pieces: that a drain that queued before
`w` starts (`drain_served` covers the rules up to 0.32.0; under 0.34.0 it is proved only by
certificate), and that each finishes in bounded time once started (`released_hold_bound`); a drain
that queued after `w` never passes it (`released_no_younger_pass`). A certificate does not help
past the search's sizes: the kernel checks one in minutes and gigabytes for a few thousand states.

The timed bound (L4) is not done.

## 0.40.0: contested CPUs (`Contest.lean`)

DESIGN-0.40.md replaces slots with admission: cpuq decides how many tasks run, never which CPU
they hold. `Contest.lean` is a model of its own, smaller than the slot model: per run its tasks
waiting and its running tasks, each starting, computing or blocked; per drain waiting, started
(its CPUs isolated) or over, its age and idle count in ticks; the gates; the CPUs busy outside
cpuq. Busy is abstract: a computing task is one CPU, a blocked one none, and which it is changes
at any time (`block`, `wake`), as a drain's command (`dbusy`). The kernel's sharing of time
(cgroup weights, macOS SIGSTOP balancing) is below the model.

Each action is one atomic step and ends with the admission pass (`pass`): drains, then runs,
start until none may (`canDrain`, `canStart`). A run starts a task when it waits, its `-c`
allows, the gates are open, fewer than 4T run, it is its project's first waiter (an urgent run's
first task, then fewest tasks running, then the oldest last start with a run that never started
first, then ticket: `projFirst`), and its project is under share (`running_p × W < T × w_p`)
or there is room (`busy + starting + 1 ≤ T`, which is `< T − 0.5` in whole CPUs) and it is first
in line among the projects' first waiters (an urgent run's first task, then project running ÷
weight, then fewer tasks running, then ticket: `head`). A drain starts when no older drain waits, at
most half the pool is then isolated, the gates are open, and (`drainFifo`) no older run waits
holding nothing. A tick measures every started task (starting → computing) and ages every
started drain; past limit + grace, or idle more than `idleMax` ticks in a row while something
waits, it is over.

`Rules.design` is the design as written; `Rules.fixed` has the two rule changes the proofs need:
busy counts only the CPUs no drain isolates (`busyAll` off), and a drain waits for older runs
that hold nothing (`drainFifo`). Every theorem below holds for every configuration, by proof; no
search is involved. Axioms: `propext`, `Classical.choice`, `Quot.sound` (pinned at the end of the
file).

| Property | Theorem | Holds |
|---|---|---|
| Invariant: nothing that may start waits; ≤ half the pool isolated; a started drain's age ≤ limit + grace and idle ≤ `idleMax`; ≤ 4 × pool running | `reach_inv`, `pass_closed` | any rules |
| 1 Work-conserving: a task that waits, not held by the gates, the backstop or its `-c`, is at or over share and busy + starting ≥ T − 0.5 | `work_conserving` | `busyAll` off |
| 1 fails as written: busy over the whole machine counts a drain's own command against a T that already excludes its CPUs; a task waits beside an idle CPU | `design_not_work_conserving` | (counterexample) |
| 2 No wait under share: under share, a waiting task waits only on the gates or the 4T backstop (and its `-c`) | `no_wait_under` | any rules |
| 2 as written ("only a gate or its `-c`") fails: 4T blocked tasks hold an under-share run | `backstop_blocks_under` | (counterexample) |
| 3 No starvation: after the last arrival, if every task ends, the gates reopen and time passes, every task and every drain starts | `no_starvation` | any rules, drains ≤ half the pool |
| 3 … for every run of the model: each run and drain arrives at most once, so there is always a last arrival | `Run.calm`, `no_starvation_all` | any rules, drains ≤ half the pool |
| 4 Isolation bounded: through any stretch a drain stays started, ≤ limit + grace ticks pass, limit ≤ ceiling | `hold_bound` | any rules |
| 4 FIFO: a drain starts only after every older run that waited holding nothing has a task running, and every older waiting drain has started | `drain_no_pass` | `drainFifo` |
| 4 A waiting drain waits only on the gates, the half-pool bound, an older drain, or (`drainFifo`) an older run holding nothing | `drain_waits_for` | any rules |
| 4 as written ("waits only for older drains and the half-pool bound") passes an older waiter | `design_drain_passes` | (counterexample) |
| 4 A drain larger than half the pool never starts | `big_drain_never` | any rules |
| 5 No idle hold: the CPUs withheld from tasks are exactly the started drains' sizes, ≤ half the pool; nothing waiting holds one | `withheld` | any rules |
| 5 A started drain whose command idles while something waits keeps its CPUs ≤ `idleMax` ticks; a started task counts as starting until the next tick | `idle_bound`, `tick_settles` | any rules |
| 5 fails under 0.35.0: a gathering drain holds a CPU, its command not started, while a run waits holding nothing | `Contest035.idle_hold_035` | (counterexample, slot model) |
| The line: a run starts only as its project's first waiter; over share, only with room and first in line among the projects' first waiters | `line_order` | any rules |
| Within a project a run never starts a task while a waiter of its project comes before it: a newer run holding nothing goes before a long run, and a run that has just started goes behind the others holding nothing | `project_turn` | any rules |
| … the long run's task ends and the newer run, never started, goes first | `newer_run_turn` | (trace) |
| … each new run of a project goes before a run of the project that started before and waits holding nothing; a stream of new runs would hold it as long as the stream lasts | `newcomers_first` | (trace) |

`no_starvation` assumes a time after which nothing arrives (`calm`), that a run with a task
running later sees one end (`ends`, A-term), that the gates are open at times without end
(`gates`) and that ticks keep coming (`time`), and a pool of at least one CPU. A configuration
has finitely many runs and drains and each arrives once, so `calm` always holds
(`no_starvation_all`). Arrivals that never stop (a stream of new runs) are not modelled and not
proved: the 4T backstop is a shared limit that under-share starts race for, and the pass takes
them in no order the design fixes, so a stream could take every opening ahead of one waiter.

What it does not cover: CPU time between running tasks (the kernel's part); measurement noise
and multi-threaded tasks (busy is exactly the computing tasks); separate cpuq processes racing
(the pass is atomic: each waiter's check is assumed to see the others' starts, as `starting`
provides); `--all`; retries; outside processes on isolated CPUs; the TERM before KILL (one end at
limit + grace); the idle stop's 0.25-CPU average (idle here is the command blocked for whole
ticks).

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
- Nesting, the build jobserver, the event log, output files, `--max` on a drain (a bound on its
  wait, not on its run). The idle stop's measure (0.25 CPU busy over 5 minutes while another run
  waits): it is only an earlier TERM.
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
graph: `L3 never`, `L3 fair`, and for each drain `D never`, `D fair`. With `drainCap`, on every
state: `T lock` (time may not pass and no step can be taken). Where a scenario asks (`Cfg.hold`),
on the graph: `L3 hold`, `L3 fair` with a drain's command not forced to end (no A-term for it),
and a run may stay in a state where no class is forced.

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

**11. (src/op.zig, 0.32.0) Nothing bounds a drain's run.** `--max` bounds a drain's wait only.
Once its command starts it holds every CPU until the command ends, however idle (pup: 22 CPUs for
2h51m at 0.09 busy while 8 runs waited). In the model the only step enabled is the command's
own end (`released_holds_forever`, 1 CPU; `L3 hold`, "drain holds, 0.32.0"). Fix (`drainCap`):
a time limit, TERM then KILL a grace later, and the idle stop as an earlier TERM. Proved: it
holds CPUs at most limit + grace per start (`hold_bound`); searched: `L3 hold` passes.

**12. (src/pool.zig, 0.32.0) A stream of drains starves a waiter.** While a drain wants CPUs every
free CPU goes to it, and a drain is urgent, so a drain that registers after a 1-CPU waiter still
goes first. Two drains taking turns (each registers while the other runs) get every CPU forever:
proved for 0.31 and 0.32.0 on 1 CPU with a one-task run (`code0305_stream_starves`,
`code0320_stream_starves`); searched: `L3 fair`, "drain stream" (pup showed drains 2173 to 2175
first in line ahead of 2142 to 2169). The time limit doesn't help ("drain stream, 0.33.0"): it
bounds each drain, not the stream.

Two fixes tried in src fail a stream: a drain due only once no older operation has never held a
CPU, and a drain that takes its turn behind older runs that have yet to start a task (`turn2087`,
`turnEfa`): both are once per operation, so a run with more tasks than one turn, served once, is
passed by every later drain (`L3 fair`, "drain stream, 2087ebe"). Fix (0.34.0, `drainFifo`): no
drain passes an older waiter that holds nothing, the CPU it takes runs a task first, and its
give-back renews its ticket, so after its turn it queues behind the drains that came meanwhile.
Proved: the hand-out never passes such a waiter (`released_fifo_no_pass`); in every
configuration, while it waits holding nothing, a drain that queued after it never takes a CPU
ahead of it (`released_no_younger_pass`: ticket order holds through the wait); each drain's hold is
bounded (`released_hold_bound`); and for the stream configurations certified (1 CPU, `-c 1` and
`--all` streams against a one-task and an endless-work run, and a `-c 1` drain against a stream of
new runs) the waiter is served and so is every drain, in every weakly fair run
(`released_stream_served`, `released_stream_drains_served`, `released_stream_all_served`,
`released_waiter_stream_served`). Searched only: the larger stream scenarios (2 CPUs, "waiter
stream" on 2 CPUs). Not proved in general: that the waiter is served (L3) in every configuration,
or a bound on its wait: the drains that queued before it (finitely many, each bounded once its
command starts, but not proved to start in general), plus the line's own wait (L3's open frame).
