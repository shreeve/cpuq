/-
The exhaustive searches `lake build` runs, each with the result it gave, so a change to the model
or the rules that changes what is found shows here. Names of the checks: `Explore.lean`.

Scenarios: up to 3 CPUs, 3 operations, K ≤ 2, with crashes (SIGKILL of a parent), timeouts and
retries, Ctrl-Z stops, `cpuq kill`, an urgent operation and project weights. `forever`
operations never run out of work, so a waiter that is not served is starved, not merely late.
Rule sets: `Rules.report1` (FINAL-REPORT-1, as review2-formal read it), `Rules.plan`
(FINAL-PLAN), `Rules.planLoose` (FINAL-PLAN with the unsafe reading of "its place frees at
once"), `Rules.fixed` (FINAL-PLAN with the two fixes the search found it needs), and FINAL-PLAN
with one fix taken out at a time.
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
urgent: FAILED (198187 states): F6 giver ahead, L3 fair
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
zero first only, urgent: FAILED (227713 states): F6 giver ahead, L3 fair
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
urgent: ok: 141740 states, 1086544 steps
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
line. It fails two scenarios (README, Findings 4 and 5); `Rules.poolFixed` passes all. -/

/--
info: two CPUs: FAILED (664 states): L3 never, L3 fair
strand: FAILED (3198 states): L3 never, L3 fair
urgent: FAILED (78346 states): L2 idle
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
urgent: ok: 186614 states, 1389637 steps
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

-- The code with both fixes as they landed (d14d347, 0d315ed): a grant made to an operation
-- before it stops still idles its CPU while it is stopped (README, Finding 6).
/--
info: urgent: FAILED (202583 states): L2 idle
-/
#guard_msgs in
#eval row "urgent" (urgent .poolNow)

end Cpuq.Checks
