/-
The slot rules before 0.40.0 hold a CPU idle while a task waits (property 5 of DESIGN-0.40.md
fails), shown in this model's own step function (`moveX` under `Rules.released`, the pool rules
of 0.34.0; 0.35.0 added only `cpuq limit`, which changes a run's `-c` and none of this).

The configuration: 2 CPUs, a two-task run P, a `cpuq drain -c 2`, and a one-task run W. P
arrives and takes both CPUs; the drain registers; P's first task ends and P gives CPU 0 back;
the drain takes it; W arrives. Now the drain holds CPU 0 and waits for a second CPU before its
command starts, while W waits holding nothing: a CPU reserved and unused while a task waits.
(W queued after the drain, so FIFO does not put it first.) Under 0.40.0 no state holds a CPU
for a drain that has not started (`Contest.withheld`).
-/
import CpuqModel.DrainCap

namespace Cpuq.Contest035
open Cpuq

def cfg035 : Cfg :=
  { cpus := 2, rules := .released
    ops := [{ proj := 0, tasks := 2, cap := 2 },
            { proj := 1, tasks := 1, urgent := true, drain := true, cap := 2 },
            { proj := 2, tasks := 1 }] }

def trace035 : List Act :=
  [.arrive 0, .accept 0 0, .accept 0 1, .enter 1, .mark 1, .exit 0 0 true, .release 0 0, .accept 1 0, .arrive 2]

theorem walk_reach {cfg : Cfg} {as : List Act} (h : (walkX cfg (init cfg) as).isSome = true) :
    ReachX cfg ((walkX cfg (init cfg) as).get h).2 := by
  have e : walkX cfg (init cfg) as = some ((walkX cfg (init cfg) as).get h) := by simp
  exact (walkX_reach as .init e).1

/-- **0.35.0 breaks property 5.** A reachable state in which the drain holds a CPU, wants
another and has not started its command, while run W is alive, wants a CPU and holds none (no
CPU, no grant), and every CPU is taken (P runs its second task on CPU 1). -/
theorem idle_hold_035 :
    ∃ s, ReachX cfg035 s ∧ gathering cfg035 s 1 = true ∧ 0 < s.owned 1 ∧
      ((s.op 1).tasks.all (fun t => t.st == .pending)) = true ∧ starving cfg035 s 2 = true ∧
      s.cpus.all (fun c => c.lock.isSome && c.grant.isNone) = true :=
  ⟨_, walk_reach (as := trace035) (by decide), by decide⟩

end Cpuq.Contest035
