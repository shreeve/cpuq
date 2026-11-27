/-
The exhaustive searches `lake build` runs, each with the result it gave, so a change to the model
or the rules that changes what is found shows here. Names of the checks: `Explore.lean`.

Scenarios: up to 4 CPUs, 3 operations, K ≤ 2, with crashes (SIGKILL of a parent), timeouts and
retries, Ctrl-Z, `cpuq kill`, an urgent operation, project weights, `cpuq drain`, backfill, a
drain's time limit and streams of drains. `forever`
operations never run out of work, so a waiter that is not served is starved, not merely late.
Rule sets: `Rules.report1` (FINAL-REPORT-1, as review2-formal read it), `Rules.plan`
(FINAL-PLAN), `Rules.planLoose` (FINAL-PLAN with the unsafe reading of "its place frees at
once"), `Rules.fixed` (FINAL-PLAN with the two fixes the search found it needs), FINAL-PLAN
with one fix taken out at a time, and the code's rules (`Rules.pool` and after).
-/
import CpuqModel.Explore

namespace Cpuq.Checks

/-- 2 CPUs, three projects with endless work (review2-formal F2's shape). -/
def twoCpus (r : Rules) : Cfg :=
  { cpus := 2, rules := r
    ops := [{ proj := 0, tasks := 2, forever := true }, { proj := 1, tasks := 2, forever := true },
            { proj := 2, tasks := 1, forever := true }] }

/-- 3 CPUs, P holds two, Q one and wants more, and P's second operation arrives. -/
def oddSplit (r : Rules) : Cfg :=
  { cpus := 3, rules := r
    ops := [{ proj := 0, tasks := 3, forever := true }, { proj := 1, tasks := 2, forever := true },
            { proj := 0, tasks := 1, forever := true }] }

/-- 3 CPUs, a K = 2 operation and two singles, one parent may be killed by SIGKILL. -/
def crash (r : Rules) : Cfg :=
  { cpus := 3, rules := r, crashes := 1
    ops := [{ proj := 0, tasks := 2, K := 2 }, { proj := 1, tasks := 1 }, { proj := 2, tasks := 1 }] }

/-- 2 CPUs, a waiter that may be killed after its grant (F4's shape). -/
def strand (r : Rules) : Cfg :=
  { cpus := 2, rules := r, crashes := 1
    ops := [{ proj := 0, tasks := 2, forever := true }, { proj := 1, tasks := 1, forever := true },
            { proj := 2, tasks := 1, forever := true }] }

/-- 2 CPUs, timeouts on, a K = 2 operation with one retry. -/
def timeout (r : Rules) : Cfg :=
  { cpus := 2, rules := r, timeouts := true
    ops := [{ proj := 0, tasks := 2, K := 2, retries := 1 }, { proj := 1, tasks := 1 }] }

/-- 3 CPUs, a K = 2 holder, a K = 1 holder and a newcomer (F1's herd). -/
def herd (r : Rules) : Cfg :=
  { cpus := 3, rules := r
    ops := [{ proj := 0, tasks := 2, K := 2, forever := true },
            { proj := 1, tasks := 2, forever := true }, { proj := 2, tasks := 1, forever := true }] }

/-- 3 CPUs, weights 2 and 1, an urgent build, Ctrl-Z and `cpuq kill`. -/
def urgent (r : Rules) : Cfg :=
  { cpus := 3, rules := r, weights := [2, 1], stops := true, kills := true
    ops := [{ proj := 0, tasks := 3, forever := true }, { proj := 1, tasks := 2, forever := true },
            { proj := 1, tasks := 1, urgent := true }] }

/-- A `cpuq drain` on a pool of `n` CPUs. -/
def drainOn (n proj : Nat) : OpCfg := { proj, tasks := 1, urgent := true, drain := true, cap := n }

/-- 2 CPUs, an operation with endless work and two `cpuq drain`s (the deadlock of 2026-11-26). -/
def twoDrains (r : Rules) : Cfg :=
  { cpus := 2, rules := r
    ops := [{ proj := 0, tasks := 2, forever := true }, drainOn 2 1, drainOn 2 2] }

/-- 3 CPUs, a drain among a K = 2 operation and a single; one parent may be killed by SIGKILL. -/
def drainCrash (r : Rules) : Cfg :=
  { cpus := 3, rules := r, crashes := 1
    ops := [{ proj := 0, tasks := 2, K := 2, forever := true }, drainOn 3 1,
            { proj := 2, tasks := 1, forever := true }] }

/-- 2 CPUs, an operation with endless work and a drain, one Ctrl-Z. -/
def drainZ (r : Rules) : Cfg :=
  { cpus := 2, rules := r, stops := true
    ops := [{ proj := 0, tasks := 2, forever := true }, drainOn 2 1] }

/-- 2 CPUs, an operation with endless work and two drains, one Ctrl-Z. -/
def twoDrainsZ (r : Rules) : Cfg :=
  { cpus := 2, rules := r, stops := true
    ops := [{ proj := 0, tasks := 2, forever := true }, drainOn 2 1, drainOn 2 2] }

/-- 3 CPUs, weights 2, 1 and 1, three projects with endless work. -/
def weighted3 (r : Rules) : Cfg :=
  { cpus := 3, rules := r, weights := [2, 1, 1]
    ops := [{ proj := 0, tasks := 3, forever := true }, { proj := 1, tasks := 2, forever := true },
            { proj := 2, tasks := 1, forever := true }] }

/-- 4 CPUs, two operations of one project and one of another, all with endless work. -/
def fourCpus (r : Rules) : Cfg :=
  { cpus := 4, rules := r
    ops := [{ proj := 0, tasks := 3, forever := true }, { proj := 1, tasks := 2, forever := true },
            { proj := 0, tasks := 1, forever := true }] }

/-- 4 CPUs, weights 1 and 2, one operation of the first project and two of the second. -/
def fourWeighted (r : Rules) : Cfg :=
  { cpus := 4, rules := r, weights := [1, 2]
    ops := [{ proj := 0, tasks := 3, forever := true }, { proj := 1, tasks := 2, forever := true },
            { proj := 1, tasks := 1, forever := true }] }

/-- 2 CPUs, two operations with endless work, two Ctrl-Z. -/
def ctrlZ (r : Rules) : Cfg :=
  { cpus := 2, rules := r, stops := true, ctrlZ := 2
    ops := [{ proj := 0, tasks := 2, forever := true }, { proj := 1, tasks := 1, forever := true }] }

/-- 2 CPUs: an urgent operation with endless work holds one CPU of project P, an operation of
project Q the other, and P's second operation waits. -/
def urgentHolds (r : Rules) : Cfg :=
  { cpus := 2, rules := r
    ops := [{ proj := 0, tasks := 1, urgent := true, forever := true },
            { proj := 1, tasks := 1, forever := true }, { proj := 0, tasks := 1, forever := true }] }

/-! Backfill: a `cpuq drain` gathers while operations with time limits (`tlimit`, in ticks) run
and wait; a drain's registration opens a window of `window` ticks. -/

/-- 2 CPUs: A (limit 2) holds and runs, B (limit 1) waits, and a drain arrives. -/
def backfill (r : Rules) : Cfg :=
  { cpus := 2, rules := r, window := 2
    ops := [{ proj := 0, tasks := 2, forever := true, tlimit := 2 },
            { proj := 1, tasks := 1, forever := true, tlimit := 1 }, drainOn 2 2] }

/-- As `backfill`, but A has no time limit: no shadow, no backfill. -/
def backfillOpen (r : Rules) : Cfg :=
  { cpus := 2, rules := r, window := 2
    ops := [{ proj := 0, tasks := 2, forever := true },
            { proj := 1, tasks := 1, forever := true, tlimit := 1 }, drainOn 2 2] }

/-- 3 CPUs, a K = 2 operation, one parent may be killed by SIGKILL. -/
def backfillCrash (r : Rules) : Cfg :=
  { cpus := 3, rules := r, window := 2, crashes := 1
    ops := [{ proj := 0, tasks := 2, K := 2, forever := true, tlimit := 2 },
            { proj := 1, tasks := 1, forever := true, tlimit := 1 }, drainOn 3 2] }

/-- `backfill` with one Ctrl-Z. -/
def backfillZ (r : Rules) : Cfg := { backfill r with stops := true }

/-- 2 CPUs, an operation with a limit and two drains, one Ctrl-Z. -/
def backfillTwoZ (r : Rules) : Cfg :=
  { cpus := 2, rules := r, window := 2, stops := true
    ops := [{ proj := 0, tasks := 2, forever := true, tlimit := 1 }, drainOn 2 1, drainOn 2 2] }

/-- Timeouts and retries, a K = 2 operation. -/
def backfillTimeout (r : Rules) : Cfg :=
  { cpus := 2, rules := r, window := 2, timeouts := true
    ops := [{ proj := 0, tasks := 2, K := 2, retries := 1, tlimit := 2 },
            { proj := 1, tasks := 1, retries := 1, tlimit := 1 }, drainOn 2 2] }

/-- 3 CPUs, a window of 3 ticks. -/
def backfill3 (r : Rules) : Cfg :=
  { cpus := 3, rules := r, window := 3
    ops := [{ proj := 0, tasks := 3, forever := true, tlimit := 3 },
            { proj := 1, tasks := 2, forever := true, tlimit := 1 }, drainOn 3 2] }

/-- An urgent operation that fits, and `cpuq kill`. -/
def backfillUrgent (r : Rules) : Cfg :=
  { cpus := 2, rules := r, window := 2, kills := true
    ops := [{ proj := 0, tasks := 2, forever := true, tlimit := 2 },
            { proj := 0, tasks := 1, urgent := true, tlimit := 1 }, drainOn 2 1] }

/-! A drain's time limit, drain sizes, and streams of drains. `drainOn n` is a drain of `n` CPUs:
before `drainSize` every drain takes the pool; with it (0.34.0) `drainOn n` is `-c n` and
`wholeOn n` is `--all`. -/

/-- `cpuq drain --all` on a pool of `n` CPUs (0.34.0). -/
def wholeOn (n proj : Nat) : OpCfg := { drainOn n proj with all := true }

/-- 2 CPUs: an operation with endless work, the drain `dr`, and another; the drain's command may
run forever (`hold`: `L3 hold` searched). -/
def drainHold (r : Rules) (dr : OpCfg := drainOn 2 1) : Cfg :=
  { cpus := 2, rules := r, hold := true
    ops := [{ proj := 0, tasks := 1, forever := true }, dr, { proj := 2, tasks := 1, forever := true }] }

/-- `n` CPUs: the waiter `w` and two drains made by `mk` that come back each time they finish. -/
def streamOf (n : Nat) (w : OpCfg) (mk : Nat → Nat → OpCfg) (r : Rules) : Cfg :=
  { cpus := n, rules := r, ops := [w, { mk n 1 with again := true }, { mk n 2 with again := true }] }

/-- A waiter with endless work, and a one-task waiter. -/
def endless : OpCfg := { proj := 0, tasks := 1, forever := true }
def oneTask : OpCfg := { proj := 0, tasks := 1 }

/-- 1 CPU: a waiter with endless work and a stream of drains. -/
def drainStream (r : Rules) : Cfg := streamOf 1 endless drainOn r

/-- 2 CPUs: one-task runs that keep coming, and the drain `dr`. -/
def waiterStream (r : Rules) (dr : OpCfg := drainOn 2 1) : Cfg :=
  { cpus := 2, rules := r
    ops := [dr, { proj := 0, tasks := 1, again := true }, { proj := 2, tasks := 1, again := true }] }

/-- 3 CPUs: an operation with endless work, a `-c 1` drain, and another with endless work. -/
def drainSide (r : Rules) : Cfg :=
  { cpus := 3, rules := r
    ops := [{ proj := 0, tasks := 2, forever := true }, drainOn 1 1, { proj := 2, tasks := 1, forever := true }] }

/-- 2 CPUs: an operation with endless work, the drain `dr`, and a one-task run. -/
def olderWaiter (r : Rules) (dr : OpCfg) : Cfg :=
  { cpus := 2, rules := r, ops := [{ proj := 0, tasks := 2, forever := true }, dr, { proj := 2, tasks := 1 }] }

/-- 2 CPUs, an operation with endless work and the drains `d1`, `d2`, one Ctrl-Z. -/
def drainsZ (r : Rules) (d1 d2 : OpCfg) : Cfg :=
  { cpus := 2, rules := r, stops := true, ops := [{ proj := 0, tasks := 2, forever := true }, d1, d2] }

/-- `backfill` with an `--all` drain. -/
def backfillAll (r : Rules) : Cfg :=
  { backfill r with ops := [{ proj := 0, tasks := 2, forever := true, tlimit := 2 },
                            { proj := 1, tasks := 1, forever := true, tlimit := 1 }, wholeOn 2 2] }

def row (name : String) (cfg : Cfg) : IO Unit :=
  IO.println s!"{name}: {(explore cfg).summary}"

/-! ## review2-formal's counterexamples, on FINAL-REPORT-1's rules -/

-- F1 (herd, drains not owed), F2 (tie starvation: L3), F3 (idle tokens: L2),
-- F4 (stranded grant: L2 and L3 after a waiter's crash), F5 (orphans share a CPU: S1'),
-- F6 (a drain not for the head).
/--
info: F1 herd: FAILED (1765 states): F1 drain not owed
F2 two CPUs: FAILED (696 states): F1 drain not owed, L3 never, L3 fair
F3 F6 odd split: FAILED (8754 states): F1 drain not owed, F6 drain not for the head, L2 idle
F4 strand: FAILED (4288 states): L2 idle, F1 drain not owed, S1' shared, L3 never, L3 fair
F5 crash: FAILED (22056 states): S1' shared
-/
#guard_msgs in
#eval do
  row "F1 herd" (herd .report1)
  row "F2 two CPUs" (twoCpus .report1)
  row "F3 F6 odd split" (oddSplit .report1)
  row "F4 strand" (strand .report1)
  row "F5 crash" (crash .report1)

/-! ## Each of FINAL-PLAN's fixes is needed: take one out and its counterexample returns -/

/--
info: no standing line: FAILED (10175 states): F6 giver ahead, L2 idle, L3 fair
no ledger: FAILED (2825 states): F1 drain not owed
no share rule: FAILED (628 states): L3 never, L3 fair
grants outlive their waiter: FAILED (5390 states): L2 idle, L3 never
no reclaim: FAILED (22194 states): S1' shared
-/
#guard_msgs in
#eval do
  row "no standing line" (oddSplit { Rules.plan with standing := false })
  row "no ledger" (herd { Rules.plan with ledger := false })
  row "no share rule" (twoCpus { Rules.plan with shareRule := false })
  row "grants outlive their waiter" (strand { Rules.plan with validGrant := false })
  row "no reclaim" (crash { Rules.plan with reclaim := false })

/-! ## FINAL-PLAN as written -/

-- It passes these.
/--
info: two CPUs: ok: 1060 states, 2818 steps
crash: ok: 20258 states, 52798 steps
strand: ok: 5360 states, 14411 steps
timeout: ok: 2347 states, 6536 steps
herd: ok: 1395 states, 5286 steps
-/
#guard_msgs in
#eval do
  row "two CPUs" (twoCpus .plan)
  row "crash" (crash .plan)
  row "strand" (strand .plan)
  row "timeout" (timeout .plan)
  row "herd" (herd .plan)

-- Two liveness counterexamples (README, Findings 1 and 2), and the loose reading of
-- "its place frees at once" breaks safety (Finding 3).
/--
info: odd split: FAILED (11005 states): F6 giver ahead, L3 fair, L3 never
urgent: FAILED (426821 states): F6 giver ahead, L3 fair
loose timeout: FAILED (4248 states): S5 twice, S1' unheld, S1' shared
-/
#guard_msgs in
#eval do
  row "odd split" (oddSplit .plan)
  row "urgent" (urgent .plan)
  row "loose timeout" (timeout .planLoose)

-- Each of the two fixes alone still fails one of them.
/--
info: zero first only, odd split: FAILED (11251 states): F6 giver ahead, L3 fair
giver behind only, odd split: FAILED (9862 states): L3 never, L3 fair
zero first only, urgent: FAILED (491551 states): F6 giver ahead, L3 fair
-/
#guard_msgs in
#eval do
  row "zero first only, odd split" (oddSplit { Rules.plan with zeroFirst := true })
  row "giver behind only, odd split" (oddSplit { Rules.plan with giverBehind := true })
  row "zero first only, urgent" (urgent { Rules.plan with zeroFirst := true })

/-! ## FINAL-PLAN with both fixes: every scenario passes -/

/--
info: two CPUs: ok: 1060 states, 2818 steps
odd split: ok: 9862 states, 35977 steps
crash: ok: 20258 states, 52798 steps
strand: ok: 5360 states, 14411 steps
timeout: ok: 2347 states, 6536 steps
herd: ok: 1395 states, 5286 steps
urgent: ok: 314964 states, 2135829 steps
-/
#guard_msgs in
#eval do
  row "two CPUs" (twoCpus .fixed)
  row "odd split" (oddSplit .fixed)
  row "crash" (crash .fixed)
  row "strand" (strand .fixed)
  row "timeout" (timeout .fixed)
  row "herd" (herd .fixed)
  row "urgent" (urgent .fixed)

/-! ## src/pool.zig and src/op.zig on branch `slots` (ba33a16)

`Rules.pool`: FINAL-PLAN with both fixes, plus what the code does that the plan doesn't say: the
giver's ticket is renewed when it gives its CPU back, one giver is chosen as `giver` chooses,
a drain is never cancelled, dead operations don't count, and a stopped operation stays in the
line. It fails two scenarios (README, Findings 4 and 5). `Rules.poolFixed`, the code at 8f997ec,
passes them; it fails only on a SIGCONT lost while a parent stops (`Z stuck`, Finding 8). -/

/--
info: two CPUs: FAILED (664 states): L3 never, L3 fair
strand: FAILED (3198 states): L3 never, L3 fair
urgent: FAILED (335938 states): L2 idle, Z stuck, L3 never
-/
#guard_msgs in
#eval do
  row "two CPUs" (twoCpus .pool)
  row "strand" (strand .pool)
  row "urgent" (urgent .pool)

/--
info: two CPUs: ok: 1002 states, 2618 steps
odd split: ok: 9805 states, 34340 steps
crash: ok: 20030 states, 52516 steps
strand: ok: 6358 states, 16733 steps
timeout: ok: 2347 states, 6536 steps
herd: ok: 1607 states, 6037 steps
urgent: FAILED (410930 states): Z stuck
-/
#guard_msgs in
#eval do
  row "two CPUs" (twoCpus .poolFixed)
  row "odd split" (oddSplit .poolFixed)
  row "crash" (crash .poolFixed)
  row "strand" (strand .poolFixed)
  row "timeout" (timeout .poolFixed)
  row "herd" (herd .poolFixed)
  row "urgent" (urgent .poolFixed)

-- The code at 0d315ed: a grant made to an operation before it stops still idles its CPU while it
-- is stopped (README, Finding 6). 8f997ec fixes it; the code there is `poolFixed`, above.
/--
info: urgent: FAILED (442296 states): L2 idle, Z stuck, L3 never
-/
#guard_msgs in
#eval row "urgent" (urgent .pool0d315ed)

/-! ## `cpuq drain`, the pool lock, and Ctrl-Z as the code receives them

`Rules.poolFixed` is the code before 0.30.1: a drain takes its mark with an exclusive lock while
it holds the pool lock, so a second drain waits for the first under the pool lock, and the
first waits for the pool lock to leave: every cpuq stops (`CS stuck`). `Rules.code0302` is the
code at 0.30.2, with the mark shared. It has three faults (README, Findings 7, 8 and 9):
an urgent operation with endless work starves an operation of its own project (`L3`); a
SIGCONT that comes after the parent took the Ctrl-Z and before it raised SIGSTOP on itself is
lost (`Z stuck`); and a stopped drain idles the pool until it continues (`L2 idle`).
`Rules.code0303` fixes all three, and has a fourth: a drain stopped and continued while a newer
drain holds part of the pool waits for that drain's CPUs while it waits for its own (Finding 10).
`Rules.code0305` (0.30.5) fixes it; each row below with "without" takes one fix out of it.
Re-pinned for 0.32.0: the search now also checks that a gathering drain is served (`D never`,
`D fair`); the rows whose drains never get the pool show `D never` too. -/

/--
info: two drains, before 0.30.1: FAILED (791 states): CS stuck, L2 idle, L3 never, D never
Ctrl-Z, before 0.30.2: FAILED (3417 states): Z stuck
Ctrl-Z, 0.30.2: FAILED (2655 states): Z stuck
drain, Ctrl-Z, 0.30.2: FAILED (1017 states): Z stuck, L2 idle, L3 never
urgent holds, 0.30.2: FAILED (187 states): L3 never, L3 fair
two drains, Ctrl-Z, 0.30.3: FAILED (26071 states): L3 never, D never
Ctrl-Z, without the stop check: FAILED (3801 states): Z stuck
drain, Ctrl-Z, without letting go: FAILED (1130 states): L2 idle
urgent holds, without urgent once: FAILED (187 states): L3 never, L3 fair
two drains, Ctrl-Z, without drain most: FAILED (26071 states): L3 never, D never
-/
#guard_msgs in
#eval do
  row "two drains, before 0.30.1" (twoDrains .poolFixed)
  row "Ctrl-Z, before 0.30.2" (ctrlZ .poolFixed)
  row "Ctrl-Z, 0.30.2" (ctrlZ .code0302)
  row "drain, Ctrl-Z, 0.30.2" (drainZ .code0302)
  row "urgent holds, 0.30.2" (urgentHolds .code0302)
  row "two drains, Ctrl-Z, 0.30.3" (twoDrainsZ .code0303)
  row "Ctrl-Z, without the stop check" (ctrlZ { Rules.code0305 with haltChecks := false })
  row "drain, Ctrl-Z, without letting go" (drainZ { Rules.code0305 with drainLets := false })
  row "urgent holds, without urgent once" (urgentHolds { Rules.code0305 with urgentOnce := false })
  row "two drains, Ctrl-Z, without drain most" (twoDrainsZ { Rules.code0305 with drainMost := false })

-- The code at 0.30.5, on every scenario.
/--
info: two drains: ok: 2091 states, 4931 steps
drain, crash: ok: 40538 states, 121758 steps
Ctrl-Z: ok: 3199 states, 11710 steps
drain, Ctrl-Z: ok: 1667 states, 5277 steps
two drains, Ctrl-Z: ok: 26047 states, 88828 steps
urgent holds: ok: 348 states, 800 steps
two CPUs: ok: 1754 states, 4320 steps
odd split: ok: 11889 states, 40983 steps
crash: ok: 20796 states, 53974 steps
strand: ok: 10030 states, 25893 steps
timeout: ok: 2347 states, 6536 steps
herd: ok: 2273 states, 8404 steps
urgent: ok: 716391 states, 4334356 steps
-/
#guard_msgs in
#eval do
  row "two drains" (twoDrains .code0305)
  row "drain, crash" (drainCrash .code0305)
  row "Ctrl-Z" (ctrlZ .code0305)
  row "drain, Ctrl-Z" (drainZ .code0305)
  row "two drains, Ctrl-Z" (twoDrainsZ .code0305)
  row "urgent holds" (urgentHolds .code0305)
  row "two CPUs" (twoCpus .code0305)
  row "odd split" (oddSplit .code0305)
  row "crash" (crash .code0305)
  row "strand" (strand .code0305)
  row "timeout" (timeout .code0305)
  row "herd" (herd .code0305)
  row "urgent" (urgent .code0305)

/-! ## Backfill (0.32.0)

`Rules.code0320`: 0.30.5 with backfill. Every scenario with a drain, then backfill's own. The
scenarios without a drain are 0.30.5's: backfill acts only while a drain gathers. A drain now
gives its CPUs back without renewing its ticket, so the drain scenarios reach fewer states. -/

/--
info: two drains: ok: 1523 states, 3561 steps
drain, crash: ok: 20174 states, 59943 steps
drain, Ctrl-Z: ok: 1435 states, 4475 steps
two drains, Ctrl-Z: ok: 20955 states, 70174 steps
backfill: ok: 3969 states, 11825 steps
backfill, no limit: ok: 2816 states, 8527 steps
backfill, crash: ok: 298711 states, 1216651 steps
backfill, Ctrl-Z: ok: 55185 states, 225546 steps
backfill, two drains, Ctrl-Z: ok: 69253 states, 280266 steps
backfill, timeouts: ok: 392587 states, 1408246 steps
backfill, 3 CPUs: ok: 114994 states, 488685 steps
backfill, urgent, kill: ok: 28077 states, 117536 steps
backfill off: ok: 1512 states, 3708 steps
-/
#guard_msgs in
#eval do
  row "two drains" (twoDrains .code0320)
  row "drain, crash" (drainCrash .code0320)
  row "drain, Ctrl-Z" (drainZ .code0320)
  row "two drains, Ctrl-Z" (twoDrainsZ .code0320)
  row "backfill" (backfill .code0320)
  row "backfill, no limit" (backfillOpen .code0320)
  row "backfill, crash" (backfillCrash .code0320)
  row "backfill, Ctrl-Z" (backfillZ .code0320)
  row "backfill, two drains, Ctrl-Z" (backfillTwoZ .code0320)
  row "backfill, timeouts" (backfillTimeout .code0320)
  row "backfill, 3 CPUs" (backfill3 .code0320)
  row "backfill, urgent, kill" (backfillUrgent .code0320)
  row "backfill off" (backfill .code0305)




/-! ## A drain's time limit, drain sizes, streams of drains (0.33.0, 0.34.0)

Under 0.31 and 0.32.0 a drain holds the pool for as long as its command runs (`L3 hold`: its
command need not end), and two drains taking turns starve a waiter (`L3 fair`; README Findings 11
and 12, both also proved in `DrainCap.lean`). The time limit (0.33.0) ends each drain but not the
stream. The turn rule of 2087ebe protects a run only until its first task. The released rules
(0.34.0: FIFO and drain sizes) pass every stream, `--all` and `-c N`, against one-task and
endless-work waiters, and serve a drain against a stream of new runs. `T pass` on the Ctrl-Z
scenarios: a run stopped by Ctrl-Z while the drain gathered wants nothing then, so the CPUs go to
the drain; continued, it waits for that drain. -/

/--
info: drain holds, 0.31: FAILED (1143 states): L3 hold
drain holds, 0.32.0: FAILED (591 states): L3 hold
drain holds, 0.33.0: ok: 1873 states, 5509 steps
drain holds, --all: ok: 1957 states, 5727 steps
drain holds, -c 1: ok: 2761 states, 8307 steps
drain stream, 0.31: FAILED (340 states): L3 fair
drain stream, 0.32.0: FAILED (324 states): L3 fair
drain stream, 0.33.0: FAILED (1746 states): L3 fair
drain stream, 2087ebe: FAILED (1809 states): L3 fair
drain stream, --all: ok: 881 states, 2530 steps
drain stream, one task, 0.31: FAILED (533 states): L3 fair
drain stream, one task, --all: ok: 1699 states, 4982 steps
drain stream, 2 CPUs, 0.33.0: FAILED (6668 states): L3 fair
drain stream, 2 CPUs, --all: ok: 2635 states, 8141 steps
drain stream, 2 CPUs, -c 1: ok: 9405 states, 33285 steps
drain stream, 2 CPUs, -c 2: ok: 2635 states, 8141 steps
waiter stream, --all: ok: 4355 states, 14075 steps
waiter stream, -c 1: ok: 6714 states, 22011 steps
-c 1 beside, 3 CPUs: ok: 8717 states, 35061 steps
older waiter, --all: ok: 3718 states, 11576 steps
older waiter, -c 1: ok: 5750 states, 18885 steps
two drains, Ctrl-Z, --all: FAILED (109049 states): T pass
two drains, Ctrl-Z, -c 1 and --all: FAILED (146712 states): T pass
backfill, --all: ok: 9758 states, 31168 steps
-/
#guard_msgs in
#eval do
  row "drain holds, 0.31" (drainHold .code0305)
  row "drain holds, 0.32.0" (drainHold .code0320)
  row "drain holds, 0.33.0" (drainHold .code0330)
  row "drain holds, --all" (drainHold .released (wholeOn 2 1))
  row "drain holds, -c 1" (drainHold .released (drainOn 1 1))
  row "drain stream, 0.31" (drainStream .code0305)
  row "drain stream, 0.32.0" (drainStream .code0320)
  row "drain stream, 0.33.0" (drainStream .code0330)
  row "drain stream, 2087ebe" (streamOf 1 endless wholeOn .turn2087)
  row "drain stream, --all" (streamOf 1 endless wholeOn .released)
  row "drain stream, one task, 0.31" (streamOf 1 oneTask drainOn .code0305)
  row "drain stream, one task, --all" (streamOf 1 oneTask wholeOn .released)
  row "drain stream, 2 CPUs, 0.33.0" (streamOf 2 endless drainOn .code0330)
  row "drain stream, 2 CPUs, --all" (streamOf 2 endless wholeOn .released)
  row "drain stream, 2 CPUs, -c 1" (streamOf 2 endless (fun _ p => drainOn 1 p) .released)
  row "drain stream, 2 CPUs, -c 2" (streamOf 2 endless drainOn .released)
  row "waiter stream, --all" (waiterStream .released (wholeOn 2 1))
  row "waiter stream, -c 1" (waiterStream .released (drainOn 1 1))
  row "-c 1 beside, 3 CPUs" (drainSide .released)
  row "older waiter, --all" (olderWaiter .released (wholeOn 2 1))
  row "older waiter, -c 1" (olderWaiter .released (drainOn 1 1))
  row "two drains, Ctrl-Z, --all" (drainsZ .released (wholeOn 2 1) (wholeOn 2 2))
  row "two drains, Ctrl-Z, -c 1 and --all" (drainsZ .released (drainOn 1 1) (wholeOn 2 2))
  row "backfill, --all" (backfillAll .released)

-- Larger: 4 CPUs, and weights over three projects.
/--
info: weights 2 1 1: ok: 16807 states, 56795 steps
four CPUs: ok: 26048 states, 117012 steps
four CPUs, weights 1 2: ok: 34414 states, 148680 steps
-/
#guard_msgs in
#eval do
  row "weights 2 1 1" (weighted3 .code0320)
  row "four CPUs" (fourCpus .code0320)
  row "four CPUs, weights 1 2" (fourWeighted .code0320)

end Cpuq.Checks
