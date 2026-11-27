/-
The exhaustive searches `lake build` runs, each with the result it gave, so a change to the model
or the rules that changes what is found shows here. Names of the checks: `Explore.lean`.

Scenarios: up to 3 CPUs, 3 operations, K ≤ 2, with crashes (SIGKILL of a parent), timeouts and
retries, Ctrl-Z, `cpuq kill`, an urgent operation, project weights and `cpuq drain`. `forever`
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
`Rules.released` (0.30.3) fixes all three; each row below with "without" takes one fix out. -/

/--
info: two drains, before 0.30.1: FAILED (791 states): CS stuck, L2 idle, L3 never
Ctrl-Z, before 0.30.2: FAILED (3417 states): Z stuck
Ctrl-Z, 0.30.2: FAILED (2655 states): Z stuck
drain, Ctrl-Z, 0.30.2: FAILED (1017 states): Z stuck, L2 idle, L3 never
urgent holds, 0.30.2: FAILED (187 states): L3 never, L3 fair
Ctrl-Z, without the stop check: FAILED (3801 states): Z stuck
drain, Ctrl-Z, without letting go: FAILED (1130 states): L2 idle
urgent holds, without urgent once: FAILED (187 states): L3 never, L3 fair
-/
#guard_msgs in
#eval do
  row "two drains, before 0.30.1" (twoDrains .poolFixed)
  row "Ctrl-Z, before 0.30.2" (ctrlZ .poolFixed)
  row "Ctrl-Z, 0.30.2" (ctrlZ .code0302)
  row "drain, Ctrl-Z, 0.30.2" (drainZ .code0302)
  row "urgent holds, 0.30.2" (urgentHolds .code0302)
  row "Ctrl-Z, without the stop check" (ctrlZ { Rules.released with haltChecks := false })
  row "drain, Ctrl-Z, without letting go" (drainZ { Rules.released with drainLets := false })
  row "urgent holds, without urgent once" (urgentHolds { Rules.released with urgentOnce := false })

-- The code as released (0.30.3), on every scenario: every one passes but two drains with a Ctrl-Z
-- (Finding 10, below).
/--
info: two drains: ok: 2091 states, 4931 steps
drain, crash: ok: 40538 states, 121758 steps
Ctrl-Z: ok: 3199 states, 11710 steps
drain, Ctrl-Z: ok: 1667 states, 5277 steps
two drains, Ctrl-Z: FAILED (26071 states): L3 never
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
  row "two drains" (twoDrains .released)
  row "drain, crash" (drainCrash .released)
  row "Ctrl-Z" (ctrlZ .released)
  row "drain, Ctrl-Z" (drainZ .released)
  row "two drains, Ctrl-Z" (twoDrainsZ .released)
  row "urgent holds" (urgentHolds .released)
  row "two CPUs" (twoCpus .released)
  row "odd split" (oddSplit .released)
  row "crash" (crash .released)
  row "strand" (strand .released)
  row "timeout" (timeout .released)
  row "herd" (herd .released)
  row "urgent" (urgent .released)

-- A drain stopped and continued while a newer drain holds part of the pool: each waits for the
-- other's CPUs (Finding 10). `drainMost`, the proposed fix, sends free CPUs to the drain that
-- holds the most.
/--
info: two drains, Ctrl-Z, most: ok: 26047 states, 88828 steps
two drains, most: ok: 2091 states, 4931 steps
drain, crash, most: ok: 40538 states, 121758 steps
drain, Ctrl-Z, most: ok: 1667 states, 5277 steps
-/
#guard_msgs in
#eval do
  row "two drains, Ctrl-Z, most" (twoDrainsZ { Rules.released with drainMost := true })
  row "two drains, most" (twoDrains { Rules.released with drainMost := true })
  row "drain, crash, most" (drainCrash { Rules.released with drainMost := true })
  row "drain, Ctrl-Z, most" (drainZ { Rules.released with drainMost := true })

end Cpuq.Checks
