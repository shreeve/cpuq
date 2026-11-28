/-
Waiters and drains are served, proved for fixed configurations (0.34.0).

Each theorem here is `served_of_cert` (Cert.lean) applied to a certificate the kernel checks
(`CpuqModel/Certs/`): the search's whole graph for the configuration, over every action that can
be enabled (`actsAll`: the search's actions and a failing exit for every task), and a ranking for
the waiting condition. Each is about every weakly fair run of `moveX` from the start
(`RunX.Fair`: a step class the search calls fair is taken once it stays enabled; arrivals, a
drain's `enter`, timeouts, crashes, kills and Ctrl-Z are forced by nothing). Drains and runs of a
stream (`again`) come back as often as the run likes, or never.

"Never waits forever" (`starving` false at some later time, from any time on) is the search's
`L3 fair`; for a drain, `gathering` false is `D fair`: it has started its command (or left).

These are proofs for the configurations named, not for every configuration: the general statement
(any number of CPUs, operations and projects) is not proved. `Fifo.lean` proves the part that
holds in general: a drain that queued after a waiter never takes a CPU ahead of it.
-/
import CpuqModel.Cert
import CpuqModel.Fifo
import CpuqModel.Certs.UrgentHolds

namespace Cpuq

/-! ### The starvation case: a stream of drains against a one-task run -/

/-- **A stream of drains no longer starves a waiter** (0.34.0). On 1 CPU, with a one-task run and
two `-c 1` drains that come back after each finish (the configuration in which 0.31 and 0.32.0
starve the run forever: `code0320_stream_starves`, `code0305_stream_starves`), in every weakly fair
run the run never waits holding nothing forever. -/
theorem released_stream_served (r : RunX (streamCfg .released)) (fair : r.Fair) (t0 : Nat) :
    ∃ m, t0 ≤ m ∧ starving (streamCfg .released) (r.st m) 0 = false :=
  served_of_cert Certs.StreamOne.graph Certs.StreamOne.rank_L3_0 r fair t0

/-- In the same configuration each drain of the stream never gathers forever: it starts its
command, however often the other drain and the run come first. -/
theorem released_stream_drains_served (r : RunX (streamCfg .released)) (fair : r.Fair) (t0 : Nat) :
    (∃ m, t0 ≤ m ∧ gathering (streamCfg .released) (r.st m) 1 = false) ∧
    (∃ m, t0 ≤ m ∧ gathering (streamCfg .released) (r.st m) 2 = false) :=
  ⟨served_of_cert Certs.StreamOne.graph Certs.StreamOne.rank_D_1 r fair t0,
   served_of_cert Certs.StreamOne.graph Certs.StreamOne.rank_D_2 r fair t0⟩

/-- 1 CPU, a run with endless work and two `--all` drains that come back after each finish: the
run is served again and again (it never waits holding nothing forever), and each drain starts. -/
theorem released_stream_all_served (r : RunX Certs.StreamAll.cfg) (fair : r.Fair) (t0 : Nat) :
    (∃ m, t0 ≤ m ∧ starving Certs.StreamAll.cfg (r.st m) 0 = false) ∧
    (∃ m, t0 ≤ m ∧ gathering Certs.StreamAll.cfg (r.st m) 1 = false) ∧
    (∃ m, t0 ≤ m ∧ gathering Certs.StreamAll.cfg (r.st m) 2 = false) :=
  ⟨served_of_cert Certs.StreamAll.graph Certs.StreamAll.rank_L3_0 r fair t0,
   served_of_cert Certs.StreamAll.graph Certs.StreamAll.rank_D_1 r fair t0,
   served_of_cert Certs.StreamAll.graph Certs.StreamAll.rank_D_2 r fair t0⟩

/-! ### A drain against a stream of new runs -/

/-- **A drain is served despite a stream of new runs** (0.34.0). On 1 CPU, a `-c 1` drain and
two one-task runs that come back after each finish: the drain never gathers forever, and neither
run waits holding nothing forever. -/
theorem released_waiter_stream_served (r : RunX Certs.WaiterStream.cfg) (fair : r.Fair) (t0 : Nat) :
    (∃ m, t0 ≤ m ∧ gathering Certs.WaiterStream.cfg (r.st m) 0 = false) ∧
    (∃ m, t0 ≤ m ∧ starving Certs.WaiterStream.cfg (r.st m) 1 = false) ∧
    (∃ m, t0 ≤ m ∧ starving Certs.WaiterStream.cfg (r.st m) 2 = false) :=
  ⟨served_of_cert Certs.WaiterStream.graph Certs.WaiterStream.rank_D_0 r fair t0,
   served_of_cert Certs.WaiterStream.graph Certs.WaiterStream.rank_L3_1 r fair t0,
   served_of_cert Certs.WaiterStream.graph Certs.WaiterStream.rank_L3_2 r fair t0⟩

/-! ### The line without drains -/

/-- **L3 without drains, for Finding 7's configuration** (0.34.0). 2 CPUs: an urgent operation with
endless work and an operation of each project with endless work (`Checks.urgentHolds`, where
0.30.2 starves P's second operation): no operation waits holding nothing forever. -/
theorem released_urgent_holds_served (r : RunX (Checks.urgentHolds .released)) (fair : r.Fair)
    (t0 : Nat) :
    (∃ m, t0 ≤ m ∧ starving (Checks.urgentHolds .released) (r.st m) 0 = false) ∧
    (∃ m, t0 ≤ m ∧ starving (Checks.urgentHolds .released) (r.st m) 1 = false) ∧
    (∃ m, t0 ≤ m ∧ starving (Checks.urgentHolds .released) (r.st m) 2 = false) :=
  ⟨served_of_cert Certs.UrgentHolds.graph Certs.UrgentHolds.rank_L3_0 r fair t0,
   served_of_cert Certs.UrgentHolds.graph Certs.UrgentHolds.rank_L3_1 r fair t0,
   served_of_cert Certs.UrgentHolds.graph Certs.UrgentHolds.rank_L3_2 r fair t0⟩

/-! ### Axioms: only the standard three (`decide +kernel` adds none) -/

/-- info: 'Cpuq.served_of_cert' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms served_of_cert

/-- info: 'Cpuq.moveX_acts' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms moveX_acts

/-- info: 'Cpuq.released_no_younger_pass' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms released_no_younger_pass

/-- info: 'Cpuq.released_stream_served' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms released_stream_served

/-- info: 'Cpuq.released_stream_drains_served' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms released_stream_drains_served

/-- info: 'Cpuq.released_stream_all_served' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms released_stream_all_served

/-- info: 'Cpuq.released_waiter_stream_served' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms released_waiter_stream_served

/-- info: 'Cpuq.released_urgent_holds_served' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms released_urgent_holds_served

end Cpuq
