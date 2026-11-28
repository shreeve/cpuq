import CpuqModel.Contest

/-!
cpuq 0.40: no starvation while arrivals never stop.

`Contest.lean`'s runs and drains each arrive once, so every run of that model has a last arrival
(`Run.calm`). Here a run or drain that is done may also leave (`leave`, `leaveD`), and its slot
may then arrive again as a new run or drain with a new ticket (`arrive`, `arriveD`, unchanged).
So arrivals of runs and drains go on forever, while at most `nr` runs and `nd` drains are
present at once; every configuration, so every such bound, is covered. Each move still ends with
the admission pass.

On the rules as shipped, `run_starts` proves the strongest form of no-starvation that holds: a
waiting run starts a task if no new run of its own project arrives, its project's tasks end, one
tick passes, and again and again the gates are open while fewer than 4T tasks run.
`StreamCex.lean` shows the conditions on arrivals and the backstop are needed: without them a run
waits forever while every other condition holds.

With the two fixes (`Rules.arrivalKey`, `Rules.oneLine`; `Rules.nostarve`), `run_starts_fixed`
proves no-starvation under fairness alone: no urgent run arriving, every task ending, one tick,
gates reopening, and `drain_max` < pool. New runs of the waiting run's project may arrive forever.
-/

namespace Cpuq.Contest

/-! ## Moves: the actions, and leaving -/

inductive Move where
  | act (a : Act)
  /-- A run that is done (no task waiting or running) leaves; its slot may arrive again. -/
  | leave (r : Nat)
  /-- A drain that is over leaves; its slot may arrive again. -/
  | leaveD (d : Nat)
  deriving Repr

def Move.isTick : Move → Bool
  | .act a => a.isTick
  | _ => false

def leaveOk (cfg : Cfg) (s : St) (r : Nat) : Prop :=
  r < cfg.nr ∧ (s.run r).here = true ∧ (s.run r).pend = 0 ∧ (s.run r).running = 0

instance (cfg : Cfg) (s : St) (r : Nat) : Decidable (leaveOk cfg s r) := by
  unfold leaveOk; infer_instance

/-- One move: an action, or a leave, then the admission pass. -/
def stepS (cfg : Cfg) (s : St) : Move → Option St
  | .act a => step cfg s a
  | .leave r => if leaveOk cfg s r then some (pass cfg (setRun s r {})) else none
  | .leaveD d => if d < cfg.nd ∧ (s.drain d).ph = .over then some (pass cfg (setDrain s d {})) else none

inductive ReachS (cfg : Cfg) : St → Prop where
  | init : ReachS cfg init
  | step {s t : St} (m : Move) : ReachS cfg s → stepS cfg s m = some t → ReachS cfg t

/-- A run of the model with leaving: arrivals of runs and drains may go on forever. -/
structure RunS (cfg : Cfg) where
  st : Nat → St
  mv : Nat → Move
  start : ReachS cfg (st 0)
  steps : ∀ n, stepS cfg (st n) (mv n) = some (st (n + 1))

theorem RunS.reach {cfg : Cfg} (ρ : RunS cfg) : ∀ n, ReachS cfg (ρ.st n)
  | 0 => ρ.start
  | n + 1 => .step _ (ρ.reach n) (ρ.steps n)

/-- `m` ends a task of run `b`. -/
def finOfM (b : Nat) : Move → Prop
  | .act a => finOf b a
  | _ => False

/-- What a move does before the pass. -/
def pre (cfg : Cfg) (s : St) : Move → St → Prop
  | .act a, u => act cfg s a = some u
  | .leave r, u => leaveOk cfg s r ∧ u = setRun s r {}
  | .leaveD d, u => (d < cfg.nd ∧ (s.drain d).ph = .over) ∧ u = setDrain s d {}

theorem stepS_pre {cfg : Cfg} {s t : St} {m : Move} (h : stepS cfg s m = some t) :
    ∃ u, pre cfg s m u ∧ t = pass cfg u := by
  cases m with
  | act a =>
    simp only [stepS, step] at h
    cases hu : act cfg s a with
    | none => rw [hu] at h; cases h
    | some u => rw [hu] at h; cases h; exact ⟨u, hu, rfl⟩
  | leave r =>
    simp only [stepS] at h; split at h
    · rename_i hc; cases h; exact ⟨_, ⟨hc, rfl⟩, rfl⟩
    · cases h
  | leaveD d =>
    simp only [stepS] at h; split at h
    · rename_i hc; cases h; exact ⟨_, ⟨hc, rfl⟩, rfl⟩
    · cases h

/-! ## The invariant holds with leaving -/

theorem inv_pre {cfg : Cfg} {s u : St} {m : Move} (i : Inv cfg s) (h : pre cfg s m u) : Inv cfg u := by
  cases m with
  | act a => exact inv_act i h
  | leave r =>
    obtain ⟨hc, rfl⟩ := h
    refine ⟨fun j hj => ?_, fun j hj => ?_, i.half, i.clock, ?_⟩
    · by_cases hjr : j = r
      · subst hjr; simp [RunSt.running]
      · simp only [setRun_run, hjr, ite_false] at hj ⊢; exact i.here j hj
    · by_cases hjr : j = r
      · subst hjr; simp at hj
      · simp only [setRun_run, hjr, ite_false] at hj ⊢; exact i.cap j hj
    · refine Nat.le_trans (total_le (fun j => ?_)) i.tot
      by_cases hjr : j = r
      · subst hjr; simp [RunSt.running]
      · simp [hjr]
  | leaveD d =>
    obtain ⟨hc, rfl⟩ := h
    have hle : iso cfg (setDrain s d {}) ≤ iso cfg s :=
      iso_le (fun e he => by
        by_cases hed : e = d
        · subst hed; simp at he
        · simpa [hed] using he)
    refine ⟨i.here, i.cap, Nat.le_trans hle i.half, fun e he => ?_, i.tot⟩
    by_cases hed : e = d
    · subst hed; simp at he
    · simp only [setDrain_drain, hed, ite_false] at he ⊢; exact i.clock e he

theorem reachS_inv {cfg : Cfg} {s : St} (r : ReachS cfg s) : Inv cfg s ∧ pass1 cfg s = none := by
  induction r with
  | init => exact reach_inv .init
  | step m _ hs ih =>
    obtain ⟨u, hu, rfl⟩ := stepS_pre hs
    exact ⟨inv_passN _ (inv_pre ih.1 hu), pass_closed cfg u⟩

theorem reachS_start {cfg : Cfg} {s : St} (h : ReachS cfg s) {r : Nat} (hr : r < cfg.nr) :
    canStart cfg s r = false :=
  (closed_iff.1 (reachS_inv h).2).2 r hr

theorem reachS_drain {cfg : Cfg} {s : St} (h : ReachS cfg s) {d : Nat} (hd : d < cfg.nd) :
    canDrain cfg s d = false :=
  (closed_iff.1 (reachS_inv h).2).1 d hd

/-! ## Time: start stamps are never in the future -/

theorem act_now {cfg : Cfg} {s u : St} {a : Act} (h : act cfg s a = some u) :
    u.now = s.now + (if a.isTick then 1 else 0) := by
  cases a <;> simp only [act] at h <;> (try split at h) <;> (try cases h) <;> rfl

theorem PassPath.now {cfg : Cfg} {s u : St} (p : PassPath cfg s u) : u.now = s.now := by
  induction p with
  | refl => rfl
  | drain _ _ _ ih => exact ih
  | admit _ _ _ ih => exact ih

theorem PassPath.last {cfg : Cfg} {s u : St} (p : PassPath cfg s u) (h : ∀ r, (s.run r).last ≤ s.now) :
    ∀ r, (u.run r).last ≤ u.now := by
  induction p with
  | refl => exact h
  | drain _ _ _ ih => exact ih h
  | @admit s' _ r' _ _ ih =>
    apply ih
    intro j
    by_cases hj : j = r'
    · subst hj; simp [Contest.admit, admitR, setRun]
    · simp only [Contest.admit, setRun_run, hj, ite_false]; exact h j

theorem pre_now {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) :
    u.now = s.now + (if m.isTick then 1 else 0) := by
  cases m with
  | act a =>
    rw [act_now h]; rfl
  | leave r => obtain ⟨_, rfl⟩ := h; rfl
  | leaveD d => obtain ⟨_, rfl⟩ := h; rfl

theorem runAfter_last (cfg : Cfg) (s : St) (a : Act) (r : Nat) :
    (runAfter cfg s a r).last ≤ (s.run r).last ∨ (runAfter cfg s a r).last = s.now := by
  cases a <;> dsimp only [runAfter] <;> (try split) <;> simp

theorem pre_last {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) (hl : ∀ r, (s.run r).last ≤ s.now) :
    ∀ r, (u.run r).last ≤ u.now := by
  intro r
  have hn := pre_now h
  have hnow : s.now ≤ u.now := by rw [hn]; omega
  cases m with
  | act a =>
    rw [act_run h r]
    have := hl r
    rcases runAfter_last cfg s a r with x | x <;> omega
  | leave e =>
    obtain ⟨_, rfl⟩ := h
    by_cases hr : r = e
    · subst hr; simp
    · simp only [setRun_run, hr, ite_false]; exact hl r
  | leaveD d => obtain ⟨_, rfl⟩ := h; exact hl r

theorem reachS_last {cfg : Cfg} {s : St} (r : ReachS cfg s) : ∀ j, (s.run j).last ≤ s.now := by
  induction r with
  | init => intro j; exact Nat.le_refl _
  | step m _ hs ih =>
    obtain ⟨u, hu, rfl⟩ := stepS_pre hs
    exact (pass_path cfg u).last (pre_last hu ih)

theorem stepS_now {cfg : Cfg} {s t : St} {m : Move} (h : stepS cfg s m = some t) :
    t.now = s.now + (if m.isTick then 1 else 0) := by
  obtain ⟨u, hu, rfl⟩ := stepS_pre h
  rw [(pass_path cfg u).now, pre_now hu]

/-! ## A waiting run that does not start -/

/-- The pass leaves a run whose waiting tasks it did not lower untouched. -/
theorem PassPath.untouched {cfg : Cfg} {s u : St} (p : PassPath cfg s u) {r : Nat}
    (h : (u.run r).pend = (s.run r).pend) : u.run r = s.run r := by
  induction p with
  | refl => rfl
  | drain _ _ _ ih => exact ih h
  | @admit s' u' r' hc p ih =>
    have fr := (p.frame.1 r).1
    by_cases hr : r = r'
    · subst hr
      simp only [canStart, eligible, Bool.and_eq_true, decide_eq_true_eq] at hc
      have := hc.1.1.1.1.2
      simp only [Contest.admit, admitR, setRun_run, ite_true] at fr
      omega
    · have e : (Contest.admit s' r').run r = s'.run r := by simp [Contest.admit, hr]
      rw [← e]; exact ih (by rw [e]; exact h)

/-- A move before the pass, for a run that waits: it stays, its waiting tasks, `ran`, last start
and ticket stay, its running tasks only go down, and one of its tasks ending lowers them. -/
theorem pre_waiting {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) {r : Nat}
    (hh : (s.run r).here = true) (hp : 0 < (s.run r).pend) :
    (u.run r).here = true ∧ (u.run r).pend = (s.run r).pend ∧ (u.run r).ran = (s.run r).ran ∧
      (u.run r).last = (s.run r).last ∧ (u.run r).ticket = (s.run r).ticket ∧
      (u.run r).running ≤ (s.run r).running ∧ (finOfM r m → (u.run r).running < (s.run r).running) := by
  cases m with
  | act a =>
    have hg := act_guard h
    rw [act_run h r]
    cases a with
    | arrive e =>
      dsimp only [runAfter]; split
      · rename_i her; subst her; dsimp only at hg; rw [hh] at hg; cases hg.2
      · exact ⟨hh, rfl, rfl, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
    | finS e | finC e | finB e =>
      dsimp only at hg
      dsimp only [runAfter]; split
      · rename_i her; subst her
        refine ⟨hh, rfl, rfl, rfl, rfl, ?_, fun _ => ?_⟩ <;> simp only [RunSt.running] <;> omega
      · rename_i her
        exact ⟨hh, rfl, rfl, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf; exact absurd hf her⟩
    | block e | wake e | limit e c =>
      dsimp only [runAfter]; split
      · rename_i her; subst her
        refine ⟨hh, rfl, rfl, rfl, rfl, ?_, fun hf => by simp [finOfM, finOf] at hf⟩
        dsimp only at hg; simp only [RunSt.running]; omega
      · exact ⟨hh, rfl, rfl, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
    | tick =>
      dsimp only [runAfter]
      exact ⟨hh, rfl, rfl, rfl, rfl, by simp only [RunSt.running]; omega, fun hf => by simp [finOfM, finOf] at hf⟩
    | _ => exact ⟨hh, rfl, rfl, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
  | leave e =>
    obtain ⟨hc, rfl⟩ := h
    have her : r ≠ e := by rintro rfl; have := hc.2.2.1; omega
    rw [setRun_run, ite_f her]
    exact ⟨hh, rfl, rfl, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩
  | leaveD d =>
    obtain ⟨_, rfl⟩ := h
    exact ⟨hh, rfl, rfl, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩

/-- Before the pass, no run's running tasks go up, and a task ending lowers its run's. -/
theorem pre_running {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) (b : Nat) :
    (u.run b).running ≤ (s.run b).running ∧ (finOfM b m → (u.run b).running < (s.run b).running) := by
  cases m with
  | act a =>
    have hg := act_guard h
    rw [act_run h b]
    cases a with
    | arrive e =>
      dsimp only [runAfter]; split
      · exact ⟨by simp [RunSt.running], fun hf => by simp [finOfM, finOf] at hf⟩
      · exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
    | finS e | finC e | finB e =>
      dsimp only at hg
      dsimp only [runAfter]; split
      · rename_i her; subst her
        refine ⟨?_, fun _ => ?_⟩ <;> simp only [RunSt.running] <;> omega
      · rename_i her
        exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf; exact absurd hf her⟩
    | block e | wake e | limit e c =>
      dsimp only [runAfter]; split
      · rename_i her; subst her
        refine ⟨?_, fun hf => by simp [finOfM, finOf] at hf⟩
        dsimp only at hg; simp only [RunSt.running]; omega
      · exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
    | tick =>
      dsimp only [runAfter]
      exact ⟨by simp only [RunSt.running]; omega, fun hf => by simp [finOfM, finOf] at hf⟩
    | _ => exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
  | leave e =>
    obtain ⟨hc, rfl⟩ := h
    by_cases hb : b = e
    · subst hb; exact ⟨by simp [RunSt.running], fun hf => by simp [finOfM] at hf⟩
    · rw [setRun_run, ite_f hb]; exact ⟨Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩
  | leaveD d =>
    obtain ⟨_, rfl⟩ := h
    exact ⟨Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩

/-! ## Tickets: below `next`, and different for different runs -/

/-- Every present run's ticket is below `next`, and two present runs have different tickets. -/
def Tickets (s : St) : Prop :=
  (∀ i, (s.run i).here = true → (s.run i).ticket < s.next) ∧
    ∀ i j, i ≠ j → (s.run i).here = true → (s.run j).here = true → (s.run i).ticket ≠ (s.run j).ticket

theorem PassPath.next {cfg : Cfg} {s u : St} (p : PassPath cfg s u) : u.next = s.next := by
  induction p with
  | refl => rfl
  | drain _ _ _ ih => exact ih
  | admit _ _ _ ih => exact ih

theorem PassPath.tickets {cfg : Cfg} {s u : St} (p : PassPath cfg s u) (h : Tickets s) : Tickets u := by
  have fr := p.frame.1
  refine ⟨fun i hi => ?_, fun i j hij hi hj => ?_⟩
  · rw [(fr i).2.2.1, p.next]; exact h.1 i (by rw [← (fr i).2.2.2]; exact hi)
  · rw [(fr i).2.2.1, (fr j).2.2.1]
    exact h.2 i j hij (by rw [← (fr i).2.2.2]; exact hi) (by rw [← (fr j).2.2.2]; exact hj)

theorem pre_next {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) : s.next ≤ u.next := by
  cases m with
  | act a =>
    have h' : act cfg s a = some u := h
    cases a <;> simp only [act] at h' <;> (try split at h') <;> (try cases h') <;> (try exact Nat.le_refl _) <;>
      (show s.next ≤ s.next + 1; omega)
  | leave r => obtain ⟨_, rfl⟩ := h; exact Nat.le_refl _
  | leaveD d => obtain ⟨_, rfl⟩ := h; exact Nat.le_refl _

theorem pre_tickets {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) (ht : Tickets s) : Tickets u := by
  cases m with
  | act a =>
    have h' : act cfg s a = some u := h
    cases a with
    | arrive r =>
      simp only [act] at h'; split at h'
      · rename_i hc; cases h'
        refine ⟨fun i hi => ?_, fun i j hij hi hj => ?_⟩
        · show (if i = r then _ else s.run i).ticket < s.next + 1
          by_cases hir : i = r
          · simp [hir]
          · simp only [setRun_run, hir, ite_false] at hi ⊢; have := ht.1 i hi; omega
        · show (if i = r then _ else s.run i).ticket ≠ (if j = r then _ else s.run j).ticket
          by_cases hir : i = r
          · subst hir
            have hjr : j ≠ i := fun e => hij e.symm
            simp only [setRun_run, hjr, ite_false] at hj
            simp only [hjr, ite_true, ite_false]; have := ht.1 j hj; omega
          · by_cases hjr : j = r
            · subst hjr
              simp only [setRun_run, hir, ite_false] at hi
              simp only [hir, ite_true, ite_false]; have := ht.1 i hi; omega
            · simp only [setRun_run, hir, hjr, ite_false] at hi hj ⊢; exact ht.2 i j hij hi hj
      · cases h'
    | arriveD d =>
      simp only [act] at h'; split at h'
      · cases h'
        exact ⟨fun i hi => Nat.lt_succ_of_lt (ht.1 i hi), ht.2⟩
      · cases h'
    | _ =>
      have hn : u.next = s.next := by
        simp only [act] at h'; (try split at h') <;> (try cases h') <;> rfl
      have hr : ∀ i, (u.run i).here = (s.run i).here ∧ (u.run i).ticket = (s.run i).ticket := by
        intro i; rw [act_run h' i]; dsimp only [runAfter]; (try split) <;> exact ⟨rfl, rfl⟩
      exact ⟨fun i hi => by rw [(hr i).2, hn]; exact ht.1 i (by rw [← (hr i).1]; exact hi),
        fun i j hij hi hj => by
          rw [(hr i).2, (hr j).2]; exact ht.2 i j hij (by rw [← (hr i).1]; exact hi) (by rw [← (hr j).1]; exact hj)⟩
  | leave e =>
    obtain ⟨_, rfl⟩ := h
    refine ⟨fun i hi => ?_, fun i j hij hi hj => ?_⟩
    · by_cases hie : i = e
      · subst hie; simp at hi
      · simp only [setRun_run, hie, ite_false] at hi ⊢; exact ht.1 i hi
    · by_cases hie : i = e
      · subst hie; simp at hi
      · by_cases hje : j = e
        · subst hje; simp at hj
        · simp only [setRun_run, hie, hje, ite_false] at hi hj ⊢; exact ht.2 i j hij hi hj
  | leaveD d => obtain ⟨_, rfl⟩ := h; exact ht

theorem reachS_tickets {cfg : Cfg} {s : St} (r : ReachS cfg s) : Tickets s := by
  induction r with
  | init => exact ⟨fun i hi => by simp [Contest.init] at hi, fun i _ _ hi => by simp [Contest.init] at hi⟩
  | step m _ hs ih =>
    obtain ⟨u, hu, rfl⟩ := stepS_pre hs
    exact (pass_path cfg u).tickets (pre_tickets hu ih)

theorem stepS_next {cfg : Cfg} {s t : St} {m : Move} (h : stepS cfg s m = some t) : s.next ≤ t.next := by
  obtain ⟨u, hu, rfl⟩ := stepS_pre h
  rw [(pass_path cfg u).next]; exact pre_next hu

/-! ## The measure: the project's running tasks, and its runs that may still go first -/

/-- `urg` of a record: 0 for an urgent run's first task, else 1. -/
def urgOf (cfg : Cfg) (b : Nat) (x : RunSt) : Nat := if (cfg.run b).urgent && !x.ran then 0 else 1

section
variable (cfg : Cfg) (r U0 L T0 : Nat)

/-- Run `b` of `r`'s project, other than `r`, present, that comes before `r` on urgency, last
start and ticket (`U0`, `L`, `T0` are `r`'s): one that may still come before `r` in its
project's order. -/
def mayPass (b : Nat) (x : RunSt) : Prop :=
  b ≠ r ∧ (cfg.run b).proj = (cfg.run r).proj ∧ x.here = true ∧
    (urgOf cfg b x < U0 ∨ (urgOf cfg b x = U0 ∧ (lkOf cfg.rules.arrivalKey x < L ∨
      (lkOf cfg.rules.arrivalKey x = L ∧ x.ticket < T0))))

instance (b : Nat) (x : RunSt) : Decidable (mayPass cfg r U0 L T0 b x) := by unfold mayPass; infer_instance

def phiF (b : Nat) (x : RunSt) : Nat :=
  (if (cfg.run b).proj = (cfg.run r).proj then x.running else 0) +
    2 * (if mayPass cfg r U0 L T0 b x then 1 else 0)

/-- The tasks of `r`'s project running, and twice its runs that may still come before `r`. -/
def phi (s : St) : Nat := rsum cfg.nr (fun b => phiF cfg r U0 L T0 b (s.run b))
end

theorem mayPass_same {cfg : Cfg} {r U0 L T0 b : Nat} {x y : RunSt} (e1 : y.here = x.here) (e2 : y.ran = x.ran)
    (e3 : y.last = x.last) (e4 : y.ticket = x.ticket) :
    mayPass cfg r U0 L T0 b y ↔ mayPass cfg r U0 L T0 b x := by
  simp only [mayPass, urgOf, lkOf, e1, e2, e3, e4]

/-- A run of `r`'s project that arrives now, not urgent, with `arrivalKey`, does not come before
`r`: its arrival is no earlier than `r`'s last start and its ticket is newer. -/
theorem arrival_not_mayPass {cfg : Cfg} {s : St} {r U0 L T0 b : Nat} (hak : cfg.rules.arrivalKey = true)
    (hu : (cfg.run b).urgent = false) (hU : U0 ≤ 1) (hL : L ≤ s.now + 1) (hT : T0 < s.next) :
    ¬ mayPass cfg r U0 L T0 b
      { here := true, ticket := s.next, pend := (cfg.run b).tasks, cap := max 1 (cfg.run b).cap, last := s.now } := by
  simp only [mayPass, urgOf, lkOf, hu, hak, Bool.false_and, Bool.or_true, ite_true, Bool.false_eq_true, ite_false]
  omega

/-- Before the pass, no move raises the measure if every run of `r`'s project that arrives is
not urgent and arrives under `arrivalKey`, and a task of the project ending lowers it. -/
theorem pre_phi {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) {r U0 L T0 : Nat}
    (arrOk : ∀ b, m = .act (.arrive b) → (cfg.run b).proj = (cfg.run r).proj →
      cfg.rules.arrivalKey = true ∧ (cfg.run b).urgent = false)
    (hU : U0 ≤ 1) (hL : L ≤ s.now + 1) (hT : T0 < s.next) :
    phi cfg r U0 L T0 u ≤ phi cfg r U0 L T0 s ∧
      (∀ b < cfg.nr, finOfM b m → (cfg.run b).proj = (cfg.run r).proj → phi cfg r U0 L T0 u < phi cfg r U0 L T0 s) := by
  have key : ∀ b, phiF cfg r U0 L T0 b (u.run b) ≤ phiF cfg r U0 L T0 b (s.run b) ∧
      (finOfM b m → (cfg.run b).proj = (cfg.run r).proj →
        phiF cfg r U0 L T0 b (u.run b) < phiF cfg r U0 L T0 b (s.run b)) := by
    intro b
    -- the same presence, `ran`, last start and ticket, and fewer or as many running
    have same : ∀ x y : RunSt, y.here = x.here → y.ran = x.ran → y.last = x.last → y.ticket = x.ticket →
        y.running ≤ x.running →
        phiF cfg r U0 L T0 b y ≤ phiF cfg r U0 L T0 b x ∧
        (y.running < x.running → (cfg.run b).proj = (cfg.run r).proj →
          phiF cfg r U0 L T0 b y < phiF cfg r U0 L T0 b x) := by
      intro x y e1 e2 e3 e4 e5
      have em := mayPass_same (cfg := cfg) (r := r) (U0 := U0) (L := L) (T0 := T0) (b := b) e1 e2 e3 e4
      unfold phiF
      by_cases hq : mayPass cfg r U0 L T0 b x
      · rw [ite_t (em.2 hq), ite_t hq]
        by_cases hp : (cfg.run b).proj = (cfg.run r).proj
        · rw [ite_t hp, ite_t hp]; exact ⟨by omega, fun h _ => by omega⟩
        · rw [ite_f hp, ite_f hp]; exact ⟨Nat.le_refl _, fun _ h => absurd h hp⟩
      · rw [ite_f (fun h => hq (em.1 h)), ite_f hq]
        by_cases hp : (cfg.run b).proj = (cfg.run r).proj
        · rw [ite_t hp, ite_t hp]; exact ⟨by omega, fun h _ => by omega⟩
        · rw [ite_f hp, ite_f hp]; exact ⟨Nat.le_refl _, fun _ h => absurd h hp⟩
    cases m with
    | act a =>
      have hg := act_guard h
      rw [act_run h b]
      cases a with
      | arrive e =>
        dsimp only [runAfter]; split
        · rename_i heb; subst heb
          refine ⟨?_, fun hf => by simp [finOfM, finOf] at hf⟩
          by_cases hp : (cfg.run e).proj = (cfg.run r).proj
          · obtain ⟨hak, hu⟩ := arrOk e rfl hp
            have hm := arrival_not_mayPass (r := r) (b := e) hak hu hU hL hT
            unfold phiF
            rw [ite_f hm]; simp [RunSt.running]
          · have z : ∀ x, phiF cfg r U0 L T0 e x = 0 := fun x => by
              unfold phiF; rw [ite_f hp, ite_f (fun hx : mayPass cfg r U0 L T0 e x => hp hx.2.1)]
            rw [z, z]; exact Nat.le_refl _
        · exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
      | finS e | finC e | finB e =>
        dsimp only at hg
        dsimp only [runAfter]; split
        · rename_i heb; subst heb
          exact ⟨(same (s.run e) _ (by rfl) (by rfl) (by rfl) (by rfl) (by simp only [RunSt.running]; omega)).1,
            fun _ hp => (same (s.run e) _ (by rfl) (by rfl) (by rfl) (by rfl) (by simp only [RunSt.running]; omega)).2
              (by simp only [RunSt.running]; omega) hp⟩
        · rename_i heb
          exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf; exact absurd hf heb⟩
      | block e | wake e | limit e c =>
        dsimp only [runAfter]; split
        · rename_i heb; subst heb
          exact ⟨(same (s.run e) _ (by rfl) (by rfl) (by rfl) (by rfl)
            (by dsimp only at hg; simp only [RunSt.running]; omega)).1, fun hf => by simp [finOfM, finOf] at hf⟩
        · exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
      | tick =>
        dsimp only [runAfter]
        exact ⟨(same (s.run b) _ (by rfl) (by rfl) (by rfl) (by rfl) (by simp only [RunSt.running]; omega)).1,
          fun hf => by simp [finOfM, finOf] at hf⟩
      | _ => exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
    | leave e =>
      obtain ⟨hc, rfl⟩ := h
      by_cases heb : b = e
      · subst heb
        refine ⟨?_, fun hf => by simp [finOfM] at hf⟩
        have e0 : phiF cfg r U0 L T0 b {} = 0 := by simp [phiF, mayPass, RunSt.running]
        simp only [setRun_run, ite_true, e0]
        exact Nat.zero_le _
      · simp only [setRun_run, heb, ite_false]
        exact ⟨Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩
    | leaveD d =>
      obtain ⟨_, rfl⟩ := h
      exact ⟨Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩
  refine ⟨rsum_le (fun b _ => (key b).1), fun b hb hf hp => rsum_lt (fun j _ => (key j).1) hb ((key b).2 hf hp)⟩

/-- `r`, holding nothing, comes before every run of its project that does not come before it on
urgency, last start and ticket. -/
theorem pbefore_late {cfg : Cfg} {s : St} {r b U0 L T0 : Nat} (h0 : (s.run r).running = 0)
    (hu : urg cfg s r = U0) (hl : lastKey cfg s r = L) (ht : (s.run r).ticket = T0)
    (hne : (s.run b).ticket ≠ T0)
    (hm : ¬ (urgOf cfg b (s.run b) < U0 ∨ (urgOf cfg b (s.run b) = U0 ∧
      (lkOf cfg.rules.arrivalKey (s.run b) < L ∨ (lkOf cfg.rules.arrivalKey (s.run b) = L ∧ (s.run b).ticket < T0))))) :
    pbefore cfg s r b = true := by
  have e1 : urg cfg s b = urgOf cfg b (s.run b) := rfl
  have e2 : lastKey cfg s b = lkOf cfg.rules.arrivalKey (s.run b) := rfl
  simp only [pbefore, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
  rw [hu, hl, ht, h0, e1, e2]
  omega

theorem urg_le (cfg : Cfg) (s : St) (r : Nat) : urg cfg s r ≤ 1 := by unfold urg; split <;> omega

/-- Along the pass, while `r` waits holding nothing and is not started, the measure only goes
down: a run of `r`'s project that starts comes before `r` (else `r` would go first), and after its
start, stamped later than `r`'s last start, it no longer does. -/
theorem pass_phi {cfg : Cfg} (hhold : cfg.rules.tokens = false ∨ cfg.rules.hold = true) {u t : St}
    (p : PassPath cfg u t) {r U0 L T0 : Nat} (hr : r < cfg.nr)
    (hh : (u.run r).here = true) (hp : 0 < (u.run r).pend) (h0 : (u.run r).running = 0)
    (hc : 1 ≤ (u.run r).cap) (hU : urg cfg u r = U0) (hl : lastKey cfg u r = L) (htk : (u.run r).ticket = T0)
    (hn : L ≤ u.now) (hk : (t.run r).pend = (u.run r).pend) (ht : Tickets t) :
    phi cfg r U0 L T0 t ≤ phi cfg r U0 L T0 u := by
  induction p with
  | refl => exact Nat.le_refl _
  | drain d _ _ ih => exact ih hh hp h0 hc hU hl htk hn hk ht
  | @admit s s' r' hs p ih =>
    have fr := (p.frame.1 r).1
    have hrr : r ≠ r' := by
      rintro rfl
      simp only [canStart, eligible, Bool.and_eq_true, decide_eq_true_eq] at hs
      have := hs.1.1.1.1.2
      simp only [Contest.admit, admitR, setRun_run, ite_true] at fr
      omega
    have e : (Contest.admit s r').run r = s.run r := by simp [Contest.admit, hrr]
    have ih' := ih (by rw [e]; exact hh) (by rw [e]; exact hp) (by rw [e]; exact h0) (by rw [e]; exact hc)
      (by simp only [urg, e]; exact hU) (by simp only [lastKey, e]; exact hl) (by rw [e]; exact htk) hn
      (by rw [e]; exact hk) ht
    refine Nat.le_trans ih' ?_
    by_cases hr' : r' < cfg.nr
    · have hsum := sum_setRun (phiF cfg r U0 L T0) s (admitR s.now (s.run r')) hr'
      have hle : phiF cfg r U0 L T0 r' (admitR s.now (s.run r')) ≤ phiF cfg r U0 L T0 r' (s.run r') := by
        by_cases hpj : (cfg.run r').proj = (cfg.run r).proj
        · have hel : eligible s r = true := by
            simp only [eligible, hh, Bool.true_and, Bool.and_eq_true, decide_eq_true_eq]
            exact ⟨hp, by omega⟩
          have hpb : pbefore cfg s r r' = false := project_turn hs r hr (cand_of hhold hel) hpj.symm
          have her' : (s.run r').here = true := by
            simp only [canStart, eligible, Bool.and_eq_true] at hs; exact hs.1.1.1.1.1
          -- the tickets of `r'` and `r` differ (both present; the pass keeps tickets)
          have hne : (s.run r').ticket ≠ T0 := by
            have f1 := (p.frame.1 r').2.2
            have f2 := (p.frame.1 r).2.2
            have hd := ht.2 r' r (Ne.symm hrr) (by rw [f1.2]; simp [Contest.admit, admitR, her'])
              (by rw [f2.2, e]; exact hh)
            rw [f1.1, f2.1, e, htk] at hd
            simpa [Contest.admit, admitR] using hd
          have hm : mayPass cfg r U0 L T0 r' (s.run r') := by
            refine ⟨Ne.symm hrr, hpj, her', ?_⟩
            apply Classical.byContradiction; intro hlt
            have := pbefore_late (cfg := cfg) h0 hU hl htk hne hlt
            rw [this] at hpb; cases hpb
          have hU1 : U0 ≤ 1 := by rw [← hU]; exact urg_le cfg s r
          have hm' : ¬ mayPass cfg r U0 L T0 r' (admitR s.now (s.run r')) := by
            simp only [mayPass, urgOf, lkOf, admitR, Bool.not_true, Bool.and_false, Bool.true_or, ite_true,
              Bool.false_eq_true, ite_false]
            omega
          unfold phiF
          rw [ite_t hpj, ite_t hpj, ite_t hm, ite_f hm']
          simp only [admitR, RunSt.running]; omega
        · have z : ∀ x, phiF cfg r U0 L T0 r' x = 0 := fun x => by
            unfold phiF; rw [ite_f hpj, ite_f (fun hx : mayPass cfg r U0 L T0 r' x => hpj hx.2.1)]
          rw [z, z]; exact Nat.le_refl _
      show rsum cfg.nr (fun b => phiF cfg r U0 L T0 b ((setRun s r' (admitR s.now (s.run r'))).run b)) ≤
        rsum cfg.nr (fun b => phiF cfg r U0 L T0 b (s.run b))
      omega
    · have : phi cfg r U0 L T0 (Contest.admit s r') = phi cfg r U0 L T0 s :=
        rsum_congr (fun j hj => by
          have : j ≠ r' := by omega
          simp [Contest.admit, this])
      omega


/-! ## A run that never starts: its project empties -/

/-- A run that waits at `n` and never starts a task stays, with the same waiting tasks, `ran`,
last start and ticket; its running tasks only go down, and one ending lowers them. -/
theorem waits_on {cfg : Cfg} (ρ : RunS cfg) {n r : Nat} (hh : ((ρ.st n).run r).here = true)
    (hp : 0 < ((ρ.st n).run r).pend)
    (hge : ∀ m ≥ n, ((ρ.st n).run r).pend ≤ ((ρ.st m).run r).pend) :
    ∀ m ≥ n, ((ρ.st m).run r).here = true ∧ ((ρ.st m).run r).pend = ((ρ.st n).run r).pend ∧
      ((ρ.st m).run r).ran = ((ρ.st n).run r).ran ∧ ((ρ.st m).run r).last = ((ρ.st n).run r).last ∧
      ((ρ.st m).run r).ticket = ((ρ.st n).run r).ticket ∧
      ((ρ.st (m + 1)).run r).running ≤ ((ρ.st m).run r).running ∧
      (finOfM r (ρ.mv m) → ((ρ.st (m + 1)).run r).running < ((ρ.st m).run r).running) := by
  -- one step of `r` while it waits
  have one : ∀ m, ((ρ.st m).run r).here = true → 0 < ((ρ.st m).run r).pend →
      ((ρ.st (m + 1)).run r).here = true ∧ ((ρ.st (m + 1)).run r).pend ≤ ((ρ.st m).run r).pend ∧
      (((ρ.st (m + 1)).run r).pend = ((ρ.st m).run r).pend →
        ((ρ.st (m + 1)).run r).ran = ((ρ.st m).run r).ran ∧ ((ρ.st (m + 1)).run r).last = ((ρ.st m).run r).last ∧
        ((ρ.st (m + 1)).run r).ticket = ((ρ.st m).run r).ticket ∧
        ((ρ.st (m + 1)).run r).running ≤ ((ρ.st m).run r).running ∧
        (finOfM r (ρ.mv m) → ((ρ.st (m + 1)).run r).running < ((ρ.st m).run r).running)) := by
    intro m h1 h2
    obtain ⟨u, hu, ht⟩ := stepS_pre (ρ.steps m)
    obtain ⟨w1, w2, w3, w4, w5, w6, w7⟩ := pre_waiting hu h1 h2
    have fr := (pass_path cfg u).frame.1 r
    rw [ht]
    refine ⟨by rw [fr.2.2.2]; exact w1, by rw [← w2]; exact fr.1, fun he => ?_⟩
    have e := (pass_path cfg u).untouched (r := r) (he.trans w2.symm)
    rw [e]
    exact ⟨w3, w4, w5, w6, w7⟩
  have stay : ∀ k, ((ρ.st (n + k)).run r).here = true ∧ ((ρ.st (n + k)).run r).pend = ((ρ.st n).run r).pend ∧
      ((ρ.st (n + k)).run r).ran = ((ρ.st n).run r).ran ∧ ((ρ.st (n + k)).run r).last = ((ρ.st n).run r).last ∧
      ((ρ.st (n + k)).run r).ticket = ((ρ.st n).run r).ticket := by
    intro k
    induction k with
    | zero => exact ⟨hh, rfl, rfl, rfl, rfl⟩
    | succ k ih =>
      have h1 := one (n + k) ih.1 (by rw [ih.2.1]; exact hp)
      have h3 := hge (n + k + 1) (by omega)
      rw [show n + (k + 1) = n + k + 1 by omega]
      have hpe : ((ρ.st (n + k + 1)).run r).pend = ((ρ.st n).run r).pend := by have := h1.2.1; omega
      have h4 := h1.2.2 (by rw [hpe, ih.2.1])
      exact ⟨h1.1, hpe, h4.1.trans ih.2.2.1, h4.2.1.trans ih.2.2.2.1, h4.2.2.1.trans ih.2.2.2.2⟩
  intro m hm
  have s1 := stay (m - n); rw [show n + (m - n) = m by omega] at s1
  have s2 := stay (m + 1 - n); rw [show n + (m + 1 - n) = m + 1 by omega] at s2
  have h4 := (one m s1.1 (by rw [s1.2.1]; exact hp)).2.2 (by rw [s2.2.1, s1.2.1])
  exact ⟨s1.1, s1.2.1, s1.2.2.1, s1.2.2.2.1, s1.2.2.2.2, h4.2.2.2.1, h4.2.2.2.2⟩

theorem nowMono {cfg : Cfg} (ρ : RunS cfg) (m k : Nat) : (ρ.st m).now ≤ (ρ.st (m + k)).now := by
  induction k with
  | zero => exact Nat.le_refl _
  | succ k ih =>
    have := stepS_now (ρ.steps (m + k))
    rw [show m + (k + 1) = m + k + 1 by omega, this]; omega

theorem nextMono {cfg : Cfg} (ρ : RunS cfg) (m k : Nat) : (ρ.st m).next ≤ (ρ.st (m + k)).next := by
  induction k with
  | zero => exact Nat.le_refl _
  | succ k ih =>
    have := stepS_next (ρ.steps (m + k))
    rw [show m + (k + 1) = m + k + 1 by omega]; omega

theorem urg_eq {cfg : Cfg} {s t : St} {r : Nat} (h : (t.run r).ran = (s.run r).ran) : urg cfg t r = urg cfg s r := by
  simp only [urg, h]

theorem lastKey_eq {cfg : Cfg} {s t : St} {r : Nat} (h1 : (t.run r).ran = (s.run r).ran)
    (h2 : (t.run r).last = (s.run r).last) : lastKey cfg t r = lastKey cfg s r := by
  simp only [lastKey, lkOf, h1, h2]

theorem lastKey_le {cfg : Cfg} {s : St} (r : Nat) (h : (s.run r).last ≤ s.now) : lastKey cfg s r ≤ s.now + 1 := by
  simp only [lastKey, lkOf]; split <;> omega

/-- **The project empties.** A run `r` waits at `n` and never starts a task. If every run of its
project that arrives is not urgent and arrives under `arrivalKey` (or none arrives), every task
of the project ends and one tick passes, then from some time on the project holds nothing and
`r` waits holding nothing, its `-c` allowing a task. -/
theorem project_empties {cfg : Cfg} (hhold : cfg.rules.tokens = false ∨ cfg.rules.hold = true) (ρ : RunS cfg)
    {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (hge : ∀ m ≥ n, ((ρ.st n).run r).pend ≤ ((ρ.st m).run r).pend)
    (arrOk : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).proj = (cfg.run r).proj →
      cfg.rules.arrivalKey = true ∧ (cfg.run b).urgent = false)
    (ends : ∀ m b, b < cfg.nr → (cfg.run b).proj = (cfg.run r).proj → 0 < ((ρ.st m).run b).running →
      ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (htime : ∃ m ≥ n, ρ.mv m = .act .tick) :
    ∃ T ≥ n, ∀ m ≥ T, projRun cfg (ρ.st m) (cfg.run r).proj = 0 ∧ ((ρ.st m).run r).running = 0 := by
  have W := waits_on ρ hh hp hge
  -- `r`'s own tasks end and it starts none: it holds nothing
  obtain ⟨n1, hn1, hc1⟩ := eventually_const (fun m => ((ρ.st m).run r).running) n
    (fun m hm => (W m hm).2.2.2.2.2.1)
  have zero : ∀ m ≥ n1, ((ρ.st m).run r).running = 0 := by
    intro m hm
    apply Classical.byContradiction; intro hne
    obtain ⟨k, hk, hf⟩ := ends m r hr rfl (by omega)
    have := (W k (by omega)).2.2.2.2.2.2 hf
    have e1 := hc1 k (by omega); have e2 := hc1 (k + 1) (by omega)
    omega
  -- after a tick, any start is stamped later than `r`'s last start
  obtain ⟨mt, hmt, htk⟩ := htime
  obtain ⟨U0, hU0⟩ : ∃ x, urg cfg (ρ.st n) r = x := ⟨_, rfl⟩
  obtain ⟨L, hL0⟩ : ∃ x, lastKey cfg (ρ.st n) r = x := ⟨_, rfl⟩
  obtain ⟨T0, hT0⟩ : ∃ x, ((ρ.st n).run r).ticket = x := ⟨_, rfl⟩
  have hUm : ∀ m ≥ n, urg cfg (ρ.st m) r = U0 := fun m hm => (urg_eq (W m hm).2.2.1).trans hU0
  have hLm : ∀ m ≥ n, lastKey cfg (ρ.st m) r = L := fun m hm =>
    (lastKey_eq (W m hm).2.2.1 (W m hm).2.2.2.1).trans hL0
  have hTm : ∀ m ≥ n, ((ρ.st m).run r).ticket = T0 := fun m hm => (W m hm).2.2.2.2.1.trans hT0
  have hL : ∀ m ≥ mt + 1, L ≤ (ρ.st m).now := by
    intro m hm
    have h1 := stepS_now (ρ.steps mt)
    rw [htk] at h1
    simp only [Move.isTick, Act.isTick, ite_true] at h1
    have h2 := lastKey_le (cfg := cfg) r (reachS_last (ρ.reach mt) r)
    rw [hLm mt hmt] at h2
    have h4 := nowMono ρ (mt + 1) (m - (mt + 1))
    rw [show mt + 1 + (m - (mt + 1)) = m by omega] at h4
    omega
  have hU1 : U0 ≤ 1 := hU0 ▸ urg_le cfg _ r
  -- the measure only goes down, and a task of the project ending lowers it
  have phiStep : ∀ m ≥ max n1 (mt + 1), phi cfg r U0 L T0 (ρ.st (m + 1)) ≤ phi cfg r U0 L T0 (ρ.st m) ∧
      (∀ b < cfg.nr, finOfM b (ρ.mv m) → (cfg.run b).proj = (cfg.run r).proj →
        phi cfg r U0 L T0 (ρ.st (m + 1)) < phi cfg r U0 L T0 (ρ.st m)) := by
    intro m hm
    have hmn : m ≥ n := by omega
    obtain ⟨u, hu, ht⟩ := stepS_pre (ρ.steps m)
    have hs := W m hmn
    have hs' := W (m + 1) (by omega)
    obtain ⟨w1, w2, w3, w4, w5, w6, _⟩ := pre_waiting hu hs.1 (by rw [hs.2.1]; exact hp)
    have iu := inv_pre (reachS_inv (ρ.reach m)).1 hu
    have hT : T0 < (ρ.st m).next := by
      have := (reachS_tickets (ρ.reach m)).1 r hs.1; rw [hTm m hmn] at this; exact this
    have hp1 := pre_phi hu (r := r) (U0 := U0) (L := L) (T0 := T0)
      (fun b hb => arrOk m hmn b hb) hU1 (by have := hL m (by omega); omega) hT
    have hnow : (ρ.st m).now ≤ u.now := by rw [pre_now hu]; omega
    have h0 : (u.run r).running = 0 := by have := zero m (by omega); omega
    have hk : ((pass cfg u).run r).pend = (u.run r).pend := by
      rw [← ht, w2, hs'.2.1, hs.2.1]
    have hpp := pass_phi hhold (pass_path cfg u) hr w1 (by rw [w2, hs.2.1]; exact hp) h0 (iu.cap r w1)
      ((urg_eq w3).trans (hUm m hmn)) ((lastKey_eq w3 w4).trans (hLm m hmn))
      (w5.trans (hTm m hmn)) (by have := hL m (by omega); omega) hk
      (by rw [← ht]; exact reachS_tickets (ρ.reach (m + 1)))
    rw [ht]
    exact ⟨Nat.le_trans hpp hp1.1, fun b hb hf hpj => Nat.lt_of_le_of_lt hpp (hp1.2 b hb hf hpj)⟩
  obtain ⟨n3, hn3, hc3⟩ := eventually_const (fun m => phi cfg r U0 L T0 (ρ.st m)) (max n1 (mt + 1))
    (fun m hm => (phiStep m hm).1)
  -- so the project's tasks all end: it holds nothing
  refine ⟨n3, by omega, fun m hm => ⟨?_, zero m (by omega)⟩⟩
  apply rsum_eq_zero.2
  intro b hb
  split
  · rename_i hpb
    apply Classical.byContradiction; intro hne
    obtain ⟨k, hk, hf⟩ := ends m b hb hpb (by omega)
    have := (phiStep k (by omega)).2 b hb hf hpb
    have e1 := hc3 k (by omega); have e2 := hc3 (k + 1) (by omega)
    omega
  · rfl

/-! ## No starvation while arrivals go on -/

/-- **No starvation with endless arrivals** (any rules). Runs and drains arrive and leave
forever. A run `r` waits at time `n`. Suppose that from then on:
- no new run of `r`'s project arrives (runs of other projects and drains arrive freely);
- every task of `r`'s project that runs later ends (each `-t`);
- one tick passes;
- again and again the gates are open while fewer than 4T tasks run (the backstop).

Then `r` starts a task. No assumption on `-c` (once `r`'s tasks end, its `-c` ≥ 1 allows one),
on `drain_max`, on drains, or on other projects' tasks ending. Over share, `r` waits only while
its project holds tasks: they end, a run of its project that may still go first starts at most
once more, and then its project, holding nothing, is under share. `StreamCex.lean`: without the
first or the last assumption, a run waits forever. -/
theorem run_starts {cfg : Cfg} (htk : cfg.rules.tokens = false) (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (noNew : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).proj ≠ (cfg.run r).proj)
    (ends : ∀ m b, b < cfg.nr → (cfg.run b).proj = (cfg.run r).proj → 0 < ((ρ.st m).run b).running →
      ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (htime : ∃ m ≥ n, ρ.mv m = .act .tick)
    (hroom : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true ∧ total cfg (ρ.st m') < 4 * capT cfg (ρ.st m')) :
    ∃ m ≥ n, ((ρ.st m).run r).pend < ((ρ.st n).run r).pend := by
  apply Classical.byContradiction
  intro hno
  have hge : ∀ m ≥ n, ((ρ.st n).run r).pend ≤ ((ρ.st m).run r).pend := fun m hm =>
    Nat.not_lt.1 (fun h => hno ⟨m, hm, h⟩)
  have W := waits_on ρ hh hp hge
  obtain ⟨T, hT, hz⟩ := project_empties (.inl htk) ρ hr hh hp hge
    (fun m hm b hb hpb => absurd hpb (noNew m hm b hb)) ends htime
  -- with the gates open under the backstop, the project, under share, starts a task
  obtain ⟨m, hm, hg, htot⟩ := hroom T
  have hs := W m (by omega)
  have i := (reachS_inv (ρ.reach m)).1
  have hel : eligible (ρ.st m) r = true := by
    have h1 := i.cap r hs.1; have h2 := (hz m hm).2
    simp only [eligible, hs.1, Bool.true_and, Bool.and_eq_true, decide_eq_true_eq]
    exact ⟨by omega, by omega⟩
  have hu : under cfg (ρ.st m) r := by
    unfold under; rw [(hz m hm).1, Nat.zero_mul, shareCap_old htk]
    exact Nat.mul_pos (by omega) (Cfg.w_pos _ _)
  replace hel := cand_of (.inl htk) hel
  obtain ⟨f, hf, hpf, hff⟩ := first_exists hr hel
  have hc := reachS_start (ρ.reach m) hf
  have huf : under cfg (ρ.st m) f := (under_proj hpf).2 hu
  cases ho : cfg.rules.oneLine
  · simp only [front, cand, Bool.and_eq_true] at hff
    simp [canStart, hff.1, hff.2, hg, htot, huf, ho, htk] at hc
  · obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head2_isSome hr hel)
    obtain ⟨hxn, hxe⟩ := head2_some hx
    have hxu := head2_under hx hf hff huf
    have hc' := reachS_start (ρ.reach m) hxn
    simp only [front, cand, Bool.and_eq_true] at hxe
    simp [canStart, hxe.1, hxe.2, hg, htot, hxu, ho, hx, htk] at hc'

/-- The backstop condition of `run_starts` from a bound: if fewer than `4 × (pool − drain_max)`
tasks ever run at once, the backstop never holds a task, and gates open again and again suffice. -/
theorem run_starts_gates {cfg : Cfg} (htk : cfg.rules.tokens = false) (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (noNew : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).proj ≠ (cfg.run r).proj)
    (ends : ∀ m b, b < cfg.nr → (cfg.run b).proj = (cfg.run r).proj → 0 < ((ρ.st m).run b).running →
      ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (htime : ∃ m ≥ n, ρ.mv m = .act .tick)
    (hbound : ∀ m, total cfg (ρ.st m) < 4 * (cfg.pool - cfg.drainMax))
    (gates : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true) :
    ∃ m ≥ n, ((ρ.st m).run r).pend < ((ρ.st n).run r).pend := by
  refine run_starts htk ρ hr hh hp noNew ends htime (fun m => ?_)
  obtain ⟨m', hm', hg⟩ := gates m
  refine ⟨m', hm', hg, ?_⟩
  have := (reachS_inv (ρ.reach m')).1.half
  have := hbound m'
  unfold capT; omega


/-! ## The fixed rules: one line and arrival keys -/

theorem pbefore_total {cfg : Cfg} {s : St} {i j : Nat} (h : (s.run i).ticket ≠ (s.run j).ticket) :
    pbefore cfg s i j = true ∨ pbefore cfg s j i = true := by
  simp only [pbefore, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
  omega

theorem before_total {cfg : Cfg} {s : St} {i j : Nat} (h : (s.run i).ticket ≠ (s.run j).ticket) :
    before cfg s i j = true ∨ before cfg s j i = true := by
  simp only [before, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
  omega

theorem before2_total {cfg : Cfg} {s : St} {i j : Nat} (h : (s.run i).ticket ≠ (s.run j).ticket) :
    before2 cfg s i j = true ∨ before2 cfg s j i = true := by
  have := before_total (cfg := cfg) h
  unfold before2
  cases hi : decide (under cfg s i) <;> cases hj : decide (under cfg s j) <;> simp_all

theorem tickets_back {cfg : Cfg} {s t : St} (p : PassPath cfg s t) (ht : Tickets t) : Tickets s := by
  have fr := p.frame.1
  refine ⟨fun i hi => ?_, fun i j hij hi hj => ?_⟩
  · rw [← (fr i).2.2.1, ← p.next]; exact ht.1 i (by rw [(fr i).2.2.2]; exact hi)
  · rw [← (fr i).2.2.1, ← (fr j).2.2.1]
    exact ht.2 i j hij (by rw [(fr i).2.2.2]; exact hi) (by rw [(fr j).2.2.2]; exact hj)

theorem PassPath.projRun_le {cfg : Cfg} {s t : St} (p : PassPath cfg s t) (q : Nat) :
    projRun cfg s q ≤ projRun cfg t q :=
  rsum_le (fun b _ => by have := (p.frame.1 b).2.1; split <;> omega)

section
variable (cfg : Cfg) (q Tk : Nat)

/-- Run `x` of another project than `q`, present: its waiting tasks if its ticket is older than
`Tk`, and one more for an urgent first task to come. -/
def psiF (x : Nat) (y : RunSt) : Nat :=
  if (cfg.run x).proj ≠ q ∧ y.here = true then
    (if y.ticket < Tk then y.pend else 0) + (if (cfg.run x).urgent && !y.ran then 1 else 0)
  else 0

/-- The starts other projects may still take ahead of a waiter of project `q`. -/
def psi (s : St) : Nat := rsum cfg.nr (fun x => psiF cfg q Tk x (s.run x))
end

/-- Before the pass, no move raises `psi` while no urgent run arrives and new tickets are no
older than `Tk`. -/
theorem pre_psi {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) {q Tk : Nat}
    (noUrg : ∀ b, m = .act (.arrive b) → (cfg.run b).urgent = false) (hT : Tk ≤ s.next) :
    psi cfg q Tk u ≤ psi cfg q Tk s := by
  apply rsum_le
  intro x _
  have same : ∀ y : RunSt, y.here = (s.run x).here → y.ticket = (s.run x).ticket → y.pend = (s.run x).pend →
      y.ran = (s.run x).ran → psiF cfg q Tk x y ≤ psiF cfg q Tk x (s.run x) := by
    intro y e1 e2 e3 e4; simp only [psiF, e1, e2, e3, e4]; exact Nat.le_refl _
  cases m with
  | act a =>
    rw [act_run h x]
    cases a with
    | arrive e =>
      dsimp only [runAfter]; split
      · rename_i hex; subst hex
        have hu := noUrg e rfl
        simp only [psiF, hu, Bool.false_and, Bool.false_eq_true, ite_false]
        split
        · have : ¬ s.next < Tk := by omega
          simp [this]
        · exact Nat.zero_le _
      · exact Nat.le_refl _
    | finS e | finC e | finB e | block e | wake e | limit e c =>
      dsimp only [runAfter]; split
      · exact same _ rfl rfl rfl rfl
      · exact Nat.le_refl _
    | tick => dsimp only [runAfter]; exact same _ rfl rfl rfl rfl
    | _ => exact Nat.le_refl _
  | leave e =>
    obtain ⟨_, rfl⟩ := h
    by_cases hxe : x = e
    · subst hxe; simp [psiF]
    · rw [setRun_run, ite_f hxe]; exact Nat.le_refl _
  | leaveD d => obtain ⟨_, rfl⟩ := h; exact Nat.le_refl _

/-- **Along the pass, with one line**, while `r` waits holding nothing and its project holds
nothing: every start is another project's, and it is ahead of `r`'s project's first waiter in the
one line, so an urgent first task or a run with an older ticket than that waiter; each lowers
`psi`. So `psi` plus the tasks running does not go up. -/
theorem pass_psi {cfg : Cfg} (hol : cfg.rules.oneLine = true)
    (hhold : cfg.rules.tokens = false ∨ cfg.rules.hold = true) {u t : St} (p : PassPath cfg u t)
    {r U0 L T0 Tk : Nat} (hr : r < cfg.nr)
    (hh : (u.run r).here = true) (hp : 0 < (u.run r).pend) (h0 : (u.run r).running = 0)
    (hc : 1 ≤ (u.run r).cap) (hU : urg cfg u r = U0) (hl : lastKey cfg u r = L) (htk : (u.run r).ticket = T0)
    (hk : (t.run r).pend = (u.run r).pend) (ht : Tickets t)
    (hz : projRun cfg t (cfg.run r).proj = 0)
    (hmp : ∀ b < cfg.nr, mayPass cfg r U0 L T0 b (u.run b) → (u.run b).ticket < Tk) (hT0 : T0 < Tk) :
    psi cfg (cfg.run r).proj Tk t + total cfg t ≤ psi cfg (cfg.run r).proj Tk u + total cfg u := by
  induction p with
  | refl => exact Nat.le_refl _
  | drain d _ _ ih => exact ih hh hp h0 hc hU hl htk hk ht hz hmp
  | @admit s s' x hs p ih =>
    have fr := (p.frame.1 r).1
    have hrx : r ≠ x := by
      rintro rfl
      simp only [canStart, eligible, Bool.and_eq_true, decide_eq_true_eq] at hs
      have := hs.1.1.1.1.2
      simp only [Contest.admit, admitR, setRun_run, ite_true] at fr
      omega
    have e : (Contest.admit s x).run r = s.run r := by simp [Contest.admit, hrx]
    have hzs : projRun cfg s (cfg.run r).proj = 0 := by
      have h1 := p.projRun_le (cfg.run r).proj
      have h2 : projRun cfg s (cfg.run r).proj ≤ projRun cfg (Contest.admit s x) (cfg.run r).proj :=
        rsum_le (fun b _ => by
          by_cases hb : b = x
          · subst hb; simp only [Contest.admit, setRun_run, ite_true, admitR, RunSt.running]; split <;> omega
          · simp [Contest.admit, hb])
      omega
    have hxe : eligible s x = true := by
      simp only [canStart, Bool.and_eq_true] at hs; exact hs.1.1.1
    have hxh : (s.run x).here = true := by
      simp only [eligible, Bool.and_eq_true] at hxe; exact hxe.1.1
    by_cases hxn : x < cfg.nr
    · -- `x` is of another project: else its start would raise the project's running tasks
      have hxp : (cfg.run x).proj ≠ (cfg.run r).proj := by
        intro hpx
        have h1 := p.projRun_le (cfg.run r).proj
        have h2 : 1 ≤ projRun cfg (Contest.admit s x) (cfg.run r).proj := by
          have hle := le_rsum (f := fun b => if (cfg.run b).proj = (cfg.run r).proj then
            ((Contest.admit s x).run b).running else 0) hxn
          have hv : 1 ≤ (if (cfg.run x).proj = (cfg.run r).proj then ((Contest.admit s x).run x).running else 0) := by
            rw [ite_t hpx]; simp [Contest.admit, admitR, RunSt.running]; omega
          exact Nat.le_trans hv hle
        omega
      have hmp' : ∀ b < cfg.nr, mayPass cfg r U0 L T0 b ((Contest.admit s x).run b) →
          ((Contest.admit s x).run b).ticket < Tk := by
        intro b hbn hb
        by_cases hbx : b = x
        · subst hbx; exact absurd hb.2.1 hxp
        · simp only [Contest.admit, setRun_run, hbx, ite_false] at hb ⊢; exact hmp b hbn hb
      have ih' := ih (by rw [e]; exact hh) (by rw [e]; exact hp) (by rw [e]; exact h0) (by rw [e]; exact hc)
        (by simp only [urg, e]; exact hU) (by simp only [lastKey, e]; exact hl) (by rw [e]; exact htk)
        (by rw [e]; exact hk) ht hz hmp'
      refine Nat.le_trans ih' ?_
      -- `x` is ahead of `r`'s project's first waiter in the one line
      have hts := tickets_back (.admit x hs p) ht
      have hel : eligible s r = true := by
        simp only [eligible, hh, Bool.true_and, Bool.and_eq_true, decide_eq_true_eq]
        exact ⟨hp, by omega⟩
      replace hel := cand_of hhold hel
      obtain ⟨F, hF, hpF, hfF⟩ := first_exists hr hel
      have lo : 0 < shareCap cfg s ∧ ∀ i < cfg.nr, front cfg s i = true → before2 cfg s i x = false := by
        cases htk : cfg.rules.tokens
        · have l := (line_order hs).2.2.1 htk hol
          refine ⟨?_, l.2⟩
          rcases l.1 with hu | hroom
          · unfold under at hu; apply Nat.pos_of_ne_zero; intro h; rw [h, Nat.zero_mul] at hu; omega
          · rw [shareCap_old htk]; unfold room at hroom; omega
        · have l := (line_order hs).2.2.2 htk
          refine ⟨?_, l.2⟩
          rw [shareCap_tok htk]
          have h1 := l.1
          have h2 : capTok cfg s ≤ capN cfg s := Nat.sub_le _ _
          have h3 : 1 ≤ cfg.wd x := by unfold Cfg.wd; omega
          omega
      have hcap := lo.1
      have huF : under cfg s F := by
        unfold under; rw [hpF, hzs, Nat.zero_mul]; exact Nat.mul_pos hcap (Cfg.w_pos _ _)
      have hFx : before2 cfg s F x = false := lo.2 F hF hfF
      have hFh : (s.run F).here = true := by
        simp only [front, cand, eligible, Bool.and_eq_true] at hfF; exact hfF.1.1.1.1
      have hneF : F ≠ x := fun h => hxp (h ▸ hpF)
      have hxF : before2 cfg s x F = true := by
        rcases before2_total (cfg := cfg) (s := s) (hts.2 x F (Ne.symm hneF) hxh hFh) with h | h
        · exact h
        · rw [h] at hFx; cases hFx
      have hF0 : (s.run F).running = 0 := by
        have := (rsum_eq_zero.1 hzs) F hF
        simp only [hpF, ite_true] at this; exact this
      have hkF : key cfg s F = 0 := by simp only [key, hpF, hzs, Nat.zero_mul]
      have hbx : before cfg s x F = true := by
        unfold before2 at hxF
        simp only [decide_eq_true huF, Bool.not_true, Bool.and_false, Bool.false_or, Bool.and_eq_true,
          beq_iff_eq] at hxF
        exact hxF.2
      have hcase : urg cfg s x < urg cfg s F ∨ (s.run x).ticket < (s.run F).ticket := by
        simp only [before, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hbx
        rw [hkF, hF0] at hbx
        omega
      -- the first waiter's ticket is older than `Tk`
      have hFt : (s.run F).ticket < Tk := by
        by_cases hFr : F = r
        · rw [hFr, htk]; exact hT0
        · have hpb : pbefore cfg s r F = false := by
            have := hfF
            simp only [front, projFirst, Bool.and_eq_true, Bool.not_eq_true'] at this
            have := anyLT_false.1 this.2 r hr
            simpa [hel, hpF] using this
          have hFr' : pbefore cfg s F r = true := by
            rcases pbefore_total (cfg := cfg) (s := s) (hts.2 F r hFr hFh hh) with h | h
            · exact h
            · rw [h] at hpb; cases hpb
          apply hmp F hF
          refine ⟨hFr, hpF, hFh, ?_⟩
          have e1 : urg cfg s F = urgOf cfg F (s.run F) := rfl
          have e2 : lastKey cfg s F = lkOf cfg.rules.arrivalKey (s.run F) := rfl
          simp only [pbefore, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq] at hFr'
          rw [hU, hl, htk, h0, e1, e2] at hFr'
          omega
      have hsum := sum_setRun (psiF cfg (cfg.run r).proj Tk) s (admitR s.now (s.run x)) hxn
      have htot := total_admit (cfg := cfg) (s := s) hxn
      have hle : psiF cfg (cfg.run r).proj Tk x (admitR s.now (s.run x)) + 1 ≤
          psiF cfg (cfg.run r).proj Tk x (s.run x) := by
        have hpx : 0 < (s.run x).pend := by
          simp only [eligible, Bool.and_eq_true, decide_eq_true_eq] at hxe; exact hxe.1.2
        have hc1 : ((cfg.run x).proj ≠ (cfg.run r).proj ∧ (s.run x).here = true) := ⟨hxp, hxh⟩
        have hc2 : ((cfg.run x).proj ≠ (cfg.run r).proj ∧ (admitR s.now (s.run x)).here = true) := ⟨hxp, hxh⟩
        unfold psiF
        rw [ite_t hc1, ite_t hc2]
        simp only [admitR, Bool.not_true, Bool.and_false, Bool.false_eq_true, ite_false]
        rcases hcase with hu | htx
        · have hu0 : urg cfg s x = 0 := by have := urg_le cfg s F; omega
          have : ((cfg.run x).urgent && !(s.run x).ran) = true := by
            unfold urg at hu0; split at hu0
            · assumption
            · cases hu0
          rw [ite_t this]
          by_cases ht' : (s.run x).ticket < Tk <;> simp only [ht', ite_true, ite_false] <;> omega
        · have : (s.run x).ticket < Tk := by omega
          simp only [this, ite_true]; split <;> omega
      show rsum cfg.nr (fun b => psiF cfg (cfg.run r).proj Tk b ((setRun s x (admitR s.now (s.run x))).run b)) +
          total cfg (Contest.admit s x) ≤ psi cfg (cfg.run r).proj Tk s + total cfg s
      unfold psi
      omega
    · -- a run outside the configuration changes no sum
      have hmp' : ∀ b < cfg.nr, mayPass cfg r U0 L T0 b ((Contest.admit s x).run b) →
          ((Contest.admit s x).run b).ticket < Tk := by
        intro b hbn hb
        have hbx : b ≠ x := by omega
        simp only [Contest.admit, setRun_run, hbx, ite_false] at hb ⊢; exact hmp b hbn hb
      have ih' := ih (by rw [e]; exact hh) (by rw [e]; exact hp) (by rw [e]; exact h0) (by rw [e]; exact hc)
        (by simp only [urg, e]; exact hU) (by simp only [lastKey, e]; exact hl) (by rw [e]; exact htk)
        (by rw [e]; exact hk) ht hz hmp'
      have e1 : psi cfg (cfg.run r).proj Tk (Contest.admit s x) = psi cfg (cfg.run r).proj Tk s :=
        rsum_congr (fun j hj => by have : j ≠ x := by omega
                                   simp [Contest.admit, this])
      have e2 : total cfg (Contest.admit s x) = total cfg s :=
        rsum_congr (fun j hj => by have : j ≠ x := by omega
                                   simp [Contest.admit, this])
      omega


/-- Before the pass, a run that may come before `r` could already: arrivals of `r`'s project
(not urgent, under `arrivalKey`) come after it, and the others keep what `mayPass` reads. -/
theorem pre_shrink {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) {r U0 L T0 : Nat}
    (arrOk : ∀ b, m = .act (.arrive b) → (cfg.run b).proj = (cfg.run r).proj →
      cfg.rules.arrivalKey = true ∧ (cfg.run b).urgent = false)
    (hU : U0 ≤ 1) (hL : L ≤ s.now + 1) (hT : T0 < s.next) :
    ∀ b, mayPass cfg r U0 L T0 b (u.run b) →
      mayPass cfg r U0 L T0 b (s.run b) ∧ (u.run b).ticket = (s.run b).ticket := by
  intro b hb
  cases m with
  | act a =>
    rw [act_run h b] at hb ⊢
    cases a with
    | arrive e =>
      dsimp only [runAfter] at hb ⊢; split at hb
      · rename_i heb; subst heb
        obtain ⟨hak, hu⟩ := arrOk e rfl hb.2.1
        exact absurd hb (arrival_not_mayPass hak hu hU hL hT)
      · rename_i heb; rw [ite_f heb]; exact ⟨hb, rfl⟩
    | finS e | finC e | finB e | block e | wake e | limit e c =>
      dsimp only [runAfter] at hb ⊢; split at hb
      · rename_i heb; subst heb
        rw [ite_t rfl]
        exact ⟨(mayPass_same rfl rfl rfl rfl).1 hb, rfl⟩
      · rename_i heb; rw [ite_f heb]; exact ⟨hb, rfl⟩
    | tick => dsimp only [runAfter] at hb ⊢; exact ⟨(mayPass_same rfl rfl rfl rfl).1 hb, rfl⟩
    | _ => exact ⟨hb, rfl⟩
  | leave e =>
    obtain ⟨_, rfl⟩ := h
    by_cases hbe : b = e
    · subst hbe; simp [mayPass] at hb
    · rw [setRun_run, ite_f hbe] at hb ⊢; exact ⟨hb, rfl⟩
  | leaveD d => obtain ⟨_, rfl⟩ := h; exact ⟨hb, rfl⟩

/-- Along the pass, a run that may come before `r` could already: a start stamps its run with
the current tick, no earlier than any last start, so a run that did not come before `r` still
does not. -/
theorem pass_shrink {cfg : Cfg} {u t : St} (p : PassPath cfg u t) {r U0 L T0 : Nat}
    (hU : U0 ≤ 1) (hlast : ∀ x, (u.run x).last ≤ u.now)
    (hne : ∀ b, b ≠ r → (t.run b).here = true → (t.run b).ticket ≠ T0) :
    ∀ b, mayPass cfg r U0 L T0 b (t.run b) →
      mayPass cfg r U0 L T0 b (u.run b) ∧ (t.run b).ticket = (u.run b).ticket := by
  induction p with
  | refl => intro b hb; exact ⟨hb, rfl⟩
  | drain d _ _ ih => exact ih hlast hne
  | @admit s s' x hs p ih =>
    have hlast' : ∀ y, ((Contest.admit s x).run y).last ≤ (Contest.admit s x).now := by
      intro y
      by_cases hy : y = x
      · subst hy; simp [Contest.admit, admitR, setRun]
      · simp only [Contest.admit, setRun_run, hy, ite_false]; exact hlast y
    intro b hb
    obtain ⟨h1, h2⟩ := ih hlast' hne b hb
    by_cases hbx : b = x
    · subst hbx
      have e1 : ((Contest.admit s b).run b).ticket = (s.run b).ticket := by simp [Contest.admit, admitR]
      refine ⟨?_, h2.trans e1⟩
      apply Classical.byContradiction; intro hn
      have hbt : (s.run b).ticket ≠ T0 := by
        have := hne b hb.1 hb.2.2.1; rwa [h2, e1] at this
      have hb' := h1
      simp only [mayPass, urgOf, lkOf, Contest.admit, setRun_run, ite_true, admitR, Bool.not_true, Bool.and_false,
        Bool.true_or, Bool.false_eq_true, ite_false] at hb'
      have hh : (s.run b).here = true := hb'.2.2.1
      have hn' : ¬ (urgOf cfg b (s.run b) < U0 ∨ (urgOf cfg b (s.run b) = U0 ∧
          (lkOf cfg.rules.arrivalKey (s.run b) < L ∨ (lkOf cfg.rules.arrivalKey (s.run b) = L ∧
            (s.run b).ticket < T0)))) := fun c => hn ⟨hb.1, hb.2.1, hh, c⟩
      have hub : urgOf cfg b (s.run b) ≤ 1 := by unfold urgOf; split <;> omega
      have hkb : lkOf cfg.rules.arrivalKey (s.run b) ≤ s.now + 1 := by
        have := hlast b; unfold lkOf; split <;> omega
      omega
    · have e1 : (Contest.admit s x).run b = s.run b := by simp [Contest.admit, hbx]
      rw [e1] at h1 h2
      exact ⟨h1, h2⟩

/-- On the fixed rules (and with tokens, the hold), a run `r` that waits at `n` and never starts a
task: from some time on nothing runs and its project holds nothing (the first half of
`run_starts_fixed`). -/
theorem starts_stop {cfg : Cfg} (hak : cfg.rules.arrivalKey = true) (hol : cfg.rules.oneLine = true)
    (hhold : cfg.rules.tokens = false ∨ cfg.rules.hold = true) (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (noUrgent : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).urgent = false)
    (ends : ∀ m b, b < cfg.nr → 0 < ((ρ.st m).run b).running → ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (htime : ∃ m ≥ n, ρ.mv m = .act .tick)
    (hge : ∀ m ≥ n, ((ρ.st n).run r).pend ≤ ((ρ.st m).run r).pend) :
    ∃ n5 ≥ n, ∀ m ≥ n5, (∀ b < cfg.nr, ((ρ.st m).run b).running = 0) ∧
      projRun cfg (ρ.st m) (cfg.run r).proj = 0 := by
  have W := waits_on ρ hh hp hge
  have arrOk : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).proj = (cfg.run r).proj →
      cfg.rules.arrivalKey = true ∧ (cfg.run b).urgent = false := fun m hm b hb _ => ⟨hak, noUrgent m hm b hb⟩
  obtain ⟨T, hT, hz⟩ := project_empties hhold ρ hr hh hp hge arrOk (fun m b hb _ hrun => ends m b hb hrun) htime
  obtain ⟨U0, hU0⟩ : ∃ x, urg cfg (ρ.st n) r = x := ⟨_, rfl⟩
  obtain ⟨L, hL0⟩ : ∃ x, lastKey cfg (ρ.st n) r = x := ⟨_, rfl⟩
  obtain ⟨T0, hT0⟩ : ∃ x, ((ρ.st n).run r).ticket = x := ⟨_, rfl⟩
  obtain ⟨Tk, hTk⟩ : ∃ x, (ρ.st n).next = x := ⟨_, rfl⟩
  have hUm : ∀ m ≥ n, urg cfg (ρ.st m) r = U0 := fun m hm => (urg_eq (W m hm).2.2.1).trans hU0
  have hLm : ∀ m ≥ n, lastKey cfg (ρ.st m) r = L := fun m hm =>
    (lastKey_eq (W m hm).2.2.1 (W m hm).2.2.2.1).trans hL0
  have hTm : ∀ m ≥ n, ((ρ.st m).run r).ticket = T0 := fun m hm => (W m hm).2.2.2.2.1.trans hT0
  have hU1 : U0 ≤ 1 := hU0 ▸ urg_le cfg _ r
  have hT0k : T0 < Tk := by
    have := (reachS_tickets (ρ.reach n)).1 r hh; rw [hT0, hTk] at this; exact this
  have hLnow : ∀ m ≥ n, L ≤ (ρ.st m).now + 1 := fun m hm => by
    rw [← hLm m hm]; exact lastKey_le r (reachS_last (ρ.reach m) r)
  have hNext : ∀ m ≥ n, Tk ≤ (ρ.st m).next := fun m hm => by
    have := nextMono ρ n (m - n); rw [show n + (m - n) = m by omega, hTk] at this; exact this
  -- a run that may come before `r` was there at `n`: its ticket is older than `Tk`
  have stepShrink : ∀ m ≥ n, ∀ b, mayPass cfg r U0 L T0 b ((ρ.st (m + 1)).run b) →
      mayPass cfg r U0 L T0 b ((ρ.st m).run b) ∧ ((ρ.st (m + 1)).run b).ticket = ((ρ.st m).run b).ticket := by
    intro m hm b hb
    obtain ⟨u, hu, ht⟩ := stepS_pre (ρ.steps m)
    have hs1 := W (m + 1) (by omega)
    have htk1 := reachS_tickets (ρ.reach (m + 1))
    rw [ht] at hb htk1 hs1
    have hne : ∀ b, b ≠ r → ((pass cfg u).run b).here = true → ((pass cfg u).run b).ticket ≠ T0 := by
      intro b hbr hbh
      have := htk1.2 b r hbr hbh hs1.1
      rwa [hs1.2.2.2.2.1, hT0] at this
    obtain ⟨p1, p2⟩ := pass_shrink (pass_path cfg u) hU1 (pre_last hu (reachS_last (ρ.reach m))) hne b hb
    obtain ⟨q1, q2⟩ := pre_shrink hu (fun b hb' => arrOk m hm b hb') hU1 (hLnow m hm)
      (by have := hNext m hm; omega) b p1
    rw [ht]
    exact ⟨q1, p2.trans q2⟩
  have bound : ∀ k b, mayPass cfg r U0 L T0 b ((ρ.st (n + k)).run b) → ((ρ.st (n + k)).run b).ticket < Tk := by
    intro k
    induction k with
    | zero =>
      intro b hb
      have := (reachS_tickets (ρ.reach n)).1 b hb.2.2.1
      rw [hTk] at this; exact this
    | succ k ih =>
      intro b hb
      rw [show n + (k + 1) = n + k + 1 by omega] at hb ⊢
      obtain ⟨h1, h2⟩ := stepShrink (n + k) (by omega) b hb
      rw [h2]; exact ih b h1
  have bound' : ∀ m ≥ n, ∀ b, mayPass cfg r U0 L T0 b ((ρ.st m).run b) → ((ρ.st m).run b).ticket < Tk :=
    fun m hm b hb => by
      have := bound (m - n) b; rw [show n + (m - n) = m by omega] at this; exact this hb
  -- once the project holds nothing: starts ahead of it, then tasks, only go down
  have Sstep : ∀ m ≥ T, psi cfg (cfg.run r).proj Tk (ρ.st (m + 1)) + total cfg (ρ.st (m + 1)) ≤
      psi cfg (cfg.run r).proj Tk (ρ.st m) + total cfg (ρ.st m) ∧
      (∀ b < cfg.nr, finOfM b (ρ.mv m) → psi cfg (cfg.run r).proj Tk (ρ.st (m + 1)) + total cfg (ρ.st (m + 1)) <
        psi cfg (cfg.run r).proj Tk (ρ.st m) + total cfg (ρ.st m)) := by
    intro m hm
    have hmn : m ≥ n := by omega
    obtain ⟨u, hu, ht⟩ := stepS_pre (ρ.steps m)
    have hs := W m hmn
    have hs' := W (m + 1) (by omega)
    obtain ⟨w1, w2, w3, w4, w5, w6, _⟩ := pre_waiting hu hs.1 (by rw [hs.2.1]; exact hp)
    have iu := inv_pre (reachS_inv (ρ.reach m)).1 hu
    have hpsi := pre_psi hu (q := (cfg.run r).proj) (Tk := Tk) (fun b hb => noUrgent m hmn b hb) (hNext m hmn)
    have htot : total cfg u ≤ total cfg (ρ.st m) := rsum_le (fun b _ => (pre_running hu b).1)
    have htot' : ∀ b < cfg.nr, finOfM b (ρ.mv m) → total cfg u < total cfg (ρ.st m) := fun b hb hf =>
      rsum_lt (fun j _ => (pre_running hu j).1) hb ((pre_running hu b).2 hf)
    have h0 : (u.run r).running = 0 := by have := (hz m hm).2; omega
    have hk : ((pass cfg u).run r).pend = (u.run r).pend := by rw [← ht, w2, hs'.2.1, hs.2.1]
    have hmp : ∀ b < cfg.nr, mayPass cfg r U0 L T0 b (u.run b) → (u.run b).ticket < Tk := by
      intro b _ hb
      obtain ⟨h1, h2⟩ := pre_shrink hu (fun b hb' => arrOk m hmn b hb') hU1 (hLnow m hmn)
        (by have := hNext m hmn; omega) b hb
      rw [h2]; exact bound' m hmn b h1
    have hps := pass_psi hol hhold (pass_path cfg u) hr w1 (by rw [w2, hs.2.1]; exact hp) h0 (iu.cap r w1)
      ((urg_eq w3).trans (hUm m hmn)) ((lastKey_eq w3 w4).trans (hLm m hmn)) (w5.trans (hTm m hmn)) hk
      (by rw [← ht]; exact reachS_tickets (ρ.reach (m + 1))) (by rw [← ht]; exact (hz (m + 1) (by omega)).1)
      hmp hT0k
    rw [ht]
    exact ⟨by omega, fun b hb hf => by have := htot' b hb hf; omega⟩
  obtain ⟨n5, hn5, hc5⟩ := eventually_const (fun m => psi cfg (cfg.run r).proj Tk (ρ.st m) + total cfg (ρ.st m)) T
    (fun m hm => (Sstep m hm).1)
  -- so every task ends: nothing runs
  have tz : ∀ m ≥ n5, ∀ b < cfg.nr, ((ρ.st m).run b).running = 0 := by
    intro m hm b hb
    apply Classical.byContradiction; intro hne
    obtain ⟨k, hk, hf⟩ := ends m b hb (by omega)
    have := (Sstep k (by omega)).2 b hb hf
    have e1 := hc5 k (by omega); have e2 := hc5 (k + 1) (by omega)
    omega
  exact ⟨n5, by omega, fun m hm => ⟨tz m hm, (hz m (by omega)).1⟩⟩

/-- **No starvation with endless arrivals, on the fixed rules** (`arrivalKey`, `oneLine`, as in
`Rules.nostarve`). Runs and drains arrive and leave forever, runs of the waiting run's own project
included. A run `r` waits at time `n`. Suppose that from then on:
- no urgent run arrives;
- every task that runs later ends (each `-t`);
- one tick passes;
- the gates are open again and again;

and `drain_max` < pool. With tokens (0.42, 0.43): the hold (rule 4(a)), and at those open-gate times
outside load within the reserve and every task's `K + drain_max ≤ N`. Then `r` starts a task. No
assumption on `-c` or on drains. New runs of
`r`'s project come after it (their arrival is no earlier than its last start, their ticket newer);
its project empties as in `run_starts`; then every start is another project's, ahead of its first
waiter in the one line: an urgent first task or a run with an older ticket, finitely many. So
starts stop, every task ends, and at the next open gates the first in the one line, under share,
starts. -/
theorem run_starts_fixed {cfg : Cfg} (hak : cfg.rules.arrivalKey = true) (hol : cfg.rules.oneLine = true)
    (hD : cfg.drainMax < cfg.pool) (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (noUrgent : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).urgent = false)
    (ends : ∀ m b, b < cfg.nr → 0 < ((ρ.st m).run b).running → ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (htime : ∃ m ≥ n, ρ.mv m = .act .tick)
    (hhold : cfg.rules.tokens = false ∨ cfg.rules.hold = true)
    (gates : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true ∧ (cfg.rules.tokens = true →
      (ρ.st m').outside ≤ (ρ.st m').reserve ∧ ∀ x < cfg.nr, cfg.drainMax + cfg.wd x ≤ cfg.pool - (ρ.st m').reserve)) :
    ∃ m ≥ n, ((ρ.st m).run r).pend < ((ρ.st n).run r).pend := by
  apply Classical.byContradiction
  intro hno
  have hge : ∀ m ≥ n, ((ρ.st n).run r).pend ≤ ((ρ.st m).run r).pend := fun m hm =>
    Nat.not_lt.1 (fun h => hno ⟨m, hm, h⟩)
  have W := waits_on ρ hh hp hge
  obtain ⟨n5, hn5, hq⟩ := starts_stop hak hol hhold ρ hr hh hp noUrgent ends htime hge
  -- at open gates the first in the one line, under share, starts
  obtain ⟨m, hm, hg, htokg⟩ := gates n5
  have hs := W m (by omega)
  have i := (reachS_inv (ρ.reach m)).1
  have htot : total cfg (ρ.st m) = 0 := rsum_eq_zero.2 (fun b hb => (hq m hm).1 b hb)
  have htokT : tokT cfg (ρ.st m) = 0 := rsum_eq_zero.2 (fun b hb => by rw [(hq m hm).1 b hb, Nat.zero_mul])
  have hcap : 0 < shareCap cfg (ρ.st m) := by
    cases htk : cfg.rules.tokens
    · rw [shareCap_old htk]; have := i.half; unfold capT; omega
    · rw [shareCap_tok htk]; have := (htokg htk).2 r hr
      have : 1 ≤ cfg.wd r := by unfold Cfg.wd; omega
      unfold capN; omega
  have hel : eligible (ρ.st m) r = true := by
    have h1 := i.cap r hs.1; have h2 := (hq m hm).1 r hr
    simp only [eligible, hs.1, Bool.true_and, Bool.and_eq_true, decide_eq_true_eq]
    exact ⟨by rw [hs.2.1]; exact hp, by omega⟩
  have hu : under cfg (ρ.st m) r := by
    unfold under; rw [(hq m hm).2, Nat.zero_mul]
    exact Nat.mul_pos hcap (Cfg.w_pos _ _)
  replace hel := cand_of hhold hel
  obtain ⟨f, hf, hpf, hff⟩ := first_exists hr hel
  have huf : under cfg (ρ.st m) f := (under_proj hpf).2 hu
  obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head2_isSome hr hel)
  obtain ⟨hxn, hxe⟩ := head2_some hx
  have hxu := head2_under hx hf hff huf
  have hc := reachS_start (ρ.reach m) hxn
  simp only [front, cand, Bool.and_eq_true] at hxe
  cases htk : cfg.rules.tokens
  · have hc4 : 0 < capT cfg (ρ.st m) := by rw [← shareCap_old htk]; exact hcap
    have h4 : total cfg (ρ.st m) < 4 * capT cfg (ρ.st m) := by omega
    simp [canStart, hxe.1, hxe.2, hg, h4, hxu, hol, hx, htk] at hc
  · have h5 : used cfg (ρ.st m) + cfg.wd x ≤ capTok cfg (ρ.st m) := by
      have := (htokg htk).1; have := (htokg htk).2 x hxn; have := i.half
      unfold used capTok capN; omega
    simp [canStart, hxe.1, hxe.2, hg, h5, hx, htk] at hc

/-- info: 'Cpuq.Contest.run_starts_fixed' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms run_starts_fixed

/-- info: 'Cpuq.Contest.run_starts' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms run_starts

end Cpuq.Contest
