import CpuqModel.Contest

/-!
cpuq 0.40: no starvation while arrivals never stop.

`Contest.lean`'s runs and drains each arrive once, so every run of that model has a last arrival
(`Run.calm`). Here a run or drain that is done may also leave (`leave`, `leaveD`), and its slot
may then arrive again as a new run or drain with a new ticket (`arrive`, `arriveD`, unchanged).
So arrivals of runs and drains go on forever, while at most `nr` runs and `nd` drains are
present at once; every configuration, so every such bound, is covered. Each move still ends with
the admission pass.

`run_starts` proves the strongest form of no-starvation that holds: a waiting run starts a task
if no new run of its own project arrives, its project's tasks end, one tick passes, and again and
again the gates are open while fewer than 4T tasks run. `StreamCex.lean` shows each of the last
two conditions on arrivals and the backstop is needed: without them a run waits forever while
every other condition holds.
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

theorem runAfter_last (cfg : Cfg) (s : St) (a : Act) (r : Nat) : (runAfter cfg s a r).last ≤ (s.run r).last := by
  cases a <;> dsimp only [runAfter] <;> (try split) <;> simp

theorem pre_last {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) (hl : ∀ r, (s.run r).last ≤ s.now) :
    ∀ r, (u.run r).last ≤ u.now := by
  intro r
  have hn := pre_now h
  have hnow : s.now ≤ u.now := by rw [hn]; omega
  cases m with
  | act a =>
    rw [act_run h r]
    have := runAfter_last cfg s a r
    have := hl r
    omega
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

/-- When last run `r` started a task (0 if never): `lastKey` of its record. -/
def lk (x : RunSt) : Nat := if x.ran then x.last + 1 else 0

/-- A move before the pass, for a run that waits: it stays, its waiting tasks and its last start
stay, its running tasks only go down, and one of its tasks ending lowers them. -/
theorem pre_waiting {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) {r : Nat}
    (hh : (s.run r).here = true) (hp : 0 < (s.run r).pend) :
    (u.run r).here = true ∧ (u.run r).pend = (s.run r).pend ∧ lk (u.run r) = lk (s.run r) ∧
      (u.run r).running ≤ (s.run r).running ∧ (finOfM r m → (u.run r).running < (s.run r).running) := by
  cases m with
  | act a =>
    have hg := act_guard h
    rw [act_run h r]
    cases a with
    | arrive e =>
      dsimp only [runAfter]; split
      · rename_i her; subst her; dsimp only at hg; rw [hh] at hg; cases hg.2
      · exact ⟨hh, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
    | finS e | finC e | finB e =>
      dsimp only at hg
      dsimp only [runAfter]; split
      · rename_i her; subst her
        refine ⟨hh, rfl, rfl, ?_, fun _ => ?_⟩ <;> simp only [RunSt.running] <;> omega
      · rename_i her
        exact ⟨hh, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf; exact absurd hf her⟩
    | block e | wake e | limit e c =>
      dsimp only [runAfter]; split
      · rename_i her; subst her
        refine ⟨hh, rfl, rfl, ?_, fun hf => by simp [finOfM, finOf] at hf⟩
        dsimp only at hg; simp only [RunSt.running]; omega
      · exact ⟨hh, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
    | tick =>
      dsimp only [runAfter]
      exact ⟨hh, rfl, rfl, by simp only [RunSt.running]; omega, fun hf => by simp [finOfM, finOf] at hf⟩
    | _ => exact ⟨hh, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
  | leave e =>
    obtain ⟨hc, rfl⟩ := h
    have her : r ≠ e := by rintro rfl; have := hc.2.2.1; omega
    rw [setRun_run, ite_f her]
    exact ⟨hh, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩
  | leaveD d =>
    obtain ⟨_, rfl⟩ := h
    exact ⟨hh, rfl, rfl, Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩

/-! ## The measure: the project's running tasks, and its runs that may still go first -/

section
variable (cfg : Cfg) (r L : Nat)

/-- Run `b` of `r`'s project, other than `r`, present, whose last start is no later than `L`:
one that may still come before `r` in its project's order. -/
def mayPass (b : Nat) (x : RunSt) : Prop :=
  b ≠ r ∧ (cfg.run b).proj = (cfg.run r).proj ∧ x.here = true ∧ lk x ≤ L

instance (b : Nat) (x : RunSt) : Decidable (mayPass cfg r L b x) := by unfold mayPass; infer_instance

def phiF (b : Nat) (x : RunSt) : Nat :=
  (if (cfg.run b).proj = (cfg.run r).proj then x.running else 0) + 2 * (if mayPass cfg r L b x then 1 else 0)

/-- The tasks of `r`'s project running, and twice its runs that may still come before `r`. -/
def phi (s : St) : Nat := rsum cfg.nr (fun b => phiF cfg r L b (s.run b))
end

/-- Before the pass, no move raises the measure while no run of `r`'s project arrives, and a
task of the project ending lowers it. -/
theorem pre_phi {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) {r L : Nat}
    (noNew : ∀ b, m = .act (.arrive b) → (cfg.run b).proj ≠ (cfg.run r).proj) :
    phi cfg r L u ≤ phi cfg r L s ∧
      (∀ b < cfg.nr, finOfM b m → (cfg.run b).proj = (cfg.run r).proj → phi cfg r L u < phi cfg r L s) := by
  -- each run's term only goes down; the one whose task ends goes down by one
  have key : ∀ b, phiF cfg r L b (u.run b) ≤ phiF cfg r L b (s.run b) ∧
      (finOfM b m → (cfg.run b).proj = (cfg.run r).proj → phiF cfg r L b (u.run b) < phiF cfg r L b (s.run b)) := by
    intro b
    -- the same presence and last start, and fewer or as many running
    have same : ∀ x y : RunSt, y.here = x.here → lk y = lk x → y.running ≤ x.running →
        phiF cfg r L b y ≤ phiF cfg r L b x ∧
        (y.running < x.running → (cfg.run b).proj = (cfg.run r).proj → phiF cfg r L b y < phiF cfg r L b x) := by
      intro x y e1 e2 e3
      have em : mayPass cfg r L b y ↔ mayPass cfg r L b x := by simp only [mayPass, e1, e2]
      unfold phiF
      by_cases hq : mayPass cfg r L b x
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
          have hp := noNew e rfl
          have z : ∀ x, phiF cfg r L e x = 0 := fun x => by
            unfold phiF; rw [ite_f hp, ite_f (fun hx : mayPass cfg r L e x => hp hx.2.1)]
          rw [z, z]
          exact ⟨Nat.le_refl _, fun _ h => absurd h hp⟩
        · exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
      | finS e | finC e | finB e =>
        dsimp only at hg
        dsimp only [runAfter]; split
        · rename_i heb; subst heb
          exact ⟨(same (s.run e) _ (by rfl) (by rfl) (by simp only [RunSt.running]; omega)).1,
            fun _ hp => (same (s.run e) _ (by rfl) (by rfl) (by simp only [RunSt.running]; omega)).2
              (by simp only [RunSt.running]; omega) hp⟩
        · rename_i heb
          exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf; exact absurd hf heb⟩
      | block e | wake e | limit e c =>
        dsimp only [runAfter]; split
        · rename_i heb; subst heb
          exact ⟨(same (s.run e) _ (by rfl) (by rfl) (by dsimp only at hg; simp only [RunSt.running]; omega)).1,
            fun hf => by simp [finOfM, finOf] at hf⟩
        · exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
      | tick =>
        dsimp only [runAfter]
        exact ⟨(same (s.run b) _ (by rfl) (by rfl) (by simp only [RunSt.running]; omega)).1,
          fun hf => by simp [finOfM, finOf] at hf⟩
      | _ => exact ⟨Nat.le_refl _, fun hf => by simp [finOfM, finOf] at hf⟩
    | leave e =>
      obtain ⟨hc, rfl⟩ := h
      by_cases heb : b = e
      · subst heb
        refine ⟨?_, fun hf => by simp [finOfM] at hf⟩
        have e0 : phiF cfg r L b {} = 0 := by simp [phiF, mayPass, RunSt.running]
        simp only [setRun_run, ite_true, e0]
        exact Nat.zero_le _
      · simp only [setRun_run, heb, ite_false]
        exact ⟨Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩
    | leaveD d =>
      obtain ⟨_, rfl⟩ := h
      exact ⟨Nat.le_refl _, fun hf => by simp [finOfM] at hf⟩
  refine ⟨rsum_le (fun b _ => (key b).1), fun b hb hf hp => rsum_lt (fun j _ => (key j).1) hb ((key b).2 hf hp)⟩

/-- `r` comes before every run of its project whose last start is later than `L`, once `r` holds
nothing and its own last start is `L`. -/
theorem pbefore_late {cfg : Cfg} {s : St} {r b L : Nat} (h0 : (s.run r).running = 0)
    (hl : lk (s.run r) = L) (hb : L < lk (s.run b)) : pbefore cfg s r b = true := by
  have hran : (s.run b).ran = true := by
    cases e : (s.run b).ran
    · simp [lk, e] at hb
    · rfl
  have u1 : urg cfg s b = 1 := by simp [urg, hran]
  have u0 : urg cfg s r ≤ 1 := by unfold urg; split <;> omega
  have k1 : lastKey s r = L := hl
  have k2 : lastKey s b = lk (s.run b) := rfl
  simp only [pbefore, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
  rw [u1, k1, k2, h0]
  omega

/-- Along the pass, while `r` waits holding nothing and is not started, the measure only goes
down: a run of `r`'s project that starts may come before `r` (else `r` would go first), and
after its start it no longer may. -/
theorem pass_phi {cfg : Cfg} {u t : St} (p : PassPath cfg u t) {r L : Nat} (hr : r < cfg.nr)
    (hh : (u.run r).here = true) (hp : 0 < (u.run r).pend) (h0 : (u.run r).running = 0)
    (hc : 1 ≤ (u.run r).cap) (hl : lk (u.run r) = L) (hn : L ≤ u.now)
    (hk : (t.run r).pend = (u.run r).pend) : phi cfg r L t ≤ phi cfg r L u := by
  induction p with
  | refl => exact Nat.le_refl _
  | drain d _ _ ih => exact ih hh hp h0 hc hl hn hk
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
      (by rw [e]; exact hl) hn (by rw [e]; exact hk)
    refine Nat.le_trans ih' ?_
    by_cases hr' : r' < cfg.nr
    · have hsum := sum_setRun (phiF cfg r L) s (admitR s.now (s.run r')) hr'
      have hle : phiF cfg r L r' (admitR s.now (s.run r')) ≤ phiF cfg r L r' (s.run r') := by
        by_cases hpj : (cfg.run r').proj = (cfg.run r).proj
        · have hel : eligible s r = true := by
            simp only [eligible, hh, Bool.true_and, Bool.and_eq_true, decide_eq_true_eq]
            exact ⟨hp, by omega⟩
          have hpb : pbefore cfg s r r' = false := project_turn hs r hr hel hpj.symm
          have hm : mayPass cfg r L r' (s.run r') := by
            refine ⟨Ne.symm hrr, hpj, ?_, ?_⟩
            · simp only [canStart, eligible, Bool.and_eq_true] at hs; exact hs.1.1.1.1.1
            · apply Classical.byContradiction; intro hlt
              have := pbefore_late (cfg := cfg) h0 hl (by omega : L < lk (s.run r'))
              rw [this] at hpb; cases hpb
          have hm' : ¬ mayPass cfg r L r' (admitR s.now (s.run r')) := by
            intro hx; have := hx.2.2.2; simp [lk, admitR] at this; omega
          unfold phiF
          rw [ite_t hpj, ite_t hpj, ite_t hm, ite_f hm']
          simp only [admitR, RunSt.running]; omega
        · have z : ∀ x, phiF cfg r L r' x = 0 := fun x => by
            unfold phiF; rw [ite_f hpj, ite_f (fun hx : mayPass cfg r L r' x => hpj hx.2.1)]
          rw [z, z]; exact Nat.le_refl _
      show rsum cfg.nr (fun b => phiF cfg r L b ((setRun s r' (admitR s.now (s.run r'))).run b)) ≤
        rsum cfg.nr (fun b => phiF cfg r L b (s.run b))
      omega
    · have : phi cfg r L (Contest.admit s r') = phi cfg r L s :=
        rsum_congr (fun j hj => by
          have : j ≠ r' := by omega
          simp [Contest.admit, this])
      omega

/-! ## No starvation while arrivals go on -/

/-- **No starvation with endless arrivals.** Runs and drains arrive and leave forever. A run `r`
waits at time `n`. Suppose that from then on:
- no new run of `r`'s project arrives (runs of other projects and drains arrive freely);
- every task of `r`'s project that runs later ends (each `-t`);
- one tick passes;
- again and again the gates are open while fewer than 4T tasks run (the backstop).

Then `r` starts a task. No assumption on `-c` (once `r`'s tasks end, its `-c` ≥ 1 allows one),
on `drain_max`, on drains, or on other projects' tasks ending. Over share, `r` waits only while
its project holds tasks: they end, a run of its project that may still go first starts at most
once more, and then its project, holding nothing, is under share. `StreamCex.lean`: without the
first or the last assumption, a run waits forever. -/
theorem run_starts {cfg : Cfg} (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
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
  -- one step of `r` while it waits
  have one : ∀ m, ((ρ.st m).run r).here = true → 0 < ((ρ.st m).run r).pend →
      ((ρ.st (m + 1)).run r).here = true ∧ ((ρ.st (m + 1)).run r).pend ≤ ((ρ.st m).run r).pend ∧
      (((ρ.st (m + 1)).run r).pend = ((ρ.st m).run r).pend →
        lk ((ρ.st (m + 1)).run r) = lk ((ρ.st m).run r) ∧
        ((ρ.st (m + 1)).run r).running ≤ ((ρ.st m).run r).running ∧
        (finOfM r (ρ.mv m) → ((ρ.st (m + 1)).run r).running < ((ρ.st m).run r).running)) := by
    intro m h1 h2
    obtain ⟨u, hu, ht⟩ := stepS_pre (ρ.steps m)
    obtain ⟨w1, w2, w3, w4, w5⟩ := pre_waiting hu h1 h2
    have fr := (pass_path cfg u).frame.1 r
    rw [ht]
    refine ⟨by rw [fr.2.2.2]; exact w1, by rw [← w2]; exact fr.1, fun he => ?_⟩
    have e := (pass_path cfg u).untouched (r := r) (he.trans w2.symm)
    rw [e]
    exact ⟨w3, w4, w5⟩
  have stay : ∀ k, ((ρ.st (n + k)).run r).here = true ∧ ((ρ.st (n + k)).run r).pend = ((ρ.st n).run r).pend := by
    intro k
    induction k with
    | zero => exact ⟨hh, rfl⟩
    | succ k ih =>
      have h1 := one (n + k) ih.1 (by rw [ih.2]; exact hp)
      have h3 := hge (n + k + 1) (by omega)
      rw [show n + (k + 1) = n + k + 1 by omega]
      exact ⟨h1.1, by have := h1.2.1; omega⟩
  have stay' : ∀ m ≥ n, ((ρ.st m).run r).here = true ∧ ((ρ.st m).run r).pend = ((ρ.st n).run r).pend :=
    fun m hm => by have := stay (m - n); rwa [show n + (m - n) = m by omega] at this
  have facts : ∀ m ≥ n, lk ((ρ.st (m + 1)).run r) = lk ((ρ.st m).run r) ∧
      ((ρ.st (m + 1)).run r).running ≤ ((ρ.st m).run r).running ∧
      (finOfM r (ρ.mv m) → ((ρ.st (m + 1)).run r).running < ((ρ.st m).run r).running) := fun m hm =>
    (one m (stay' m hm).1 (by rw [(stay' m hm).2]; exact hp)).2.2
      (by rw [(stay' (m + 1) (by omega)).2, (stay' m hm).2])
  -- `r`'s own tasks end and it starts none: it holds nothing
  obtain ⟨n1, hn1, hc1⟩ := eventually_const (fun m => ((ρ.st m).run r).running) n
    (fun m hm => (facts m hm).2.1)
  have zero : ∀ m ≥ n1, ((ρ.st m).run r).running = 0 := by
    intro m hm
    apply Classical.byContradiction; intro hne
    obtain ⟨k, hk, hf⟩ := ends m r hr rfl (by omega)
    have := (facts k (by omega)).2.2 hf
    have e1 := hc1 k (by omega); have e2 := hc1 (k + 1) (by omega)
    omega
  -- its last start stays `L`
  have lkL : ∀ k, lk ((ρ.st (n + k)).run r) = lk ((ρ.st n).run r) := by
    intro k
    induction k with
    | zero => rfl
    | succ k ih => rw [show n + (k + 1) = n + k + 1 by omega, (facts (n + k) (by omega)).1, ih]
  have lkL' : ∀ m ≥ n, lk ((ρ.st m).run r) = lk ((ρ.st n).run r) :=
    fun m hm => by have := lkL (m - n); rwa [show n + (m - n) = m by omega] at this
  -- after a tick, any start is stamped later than `L`
  obtain ⟨mt, hmt, htk⟩ := htime
  have nowMono : ∀ m k, (ρ.st m).now ≤ (ρ.st (m + k)).now := by
    intro m k
    induction k with
    | zero => exact Nat.le_refl _
    | succ k ih =>
      have := stepS_now (ρ.steps (m + k))
      rw [show m + (k + 1) = m + k + 1 by omega, this]; omega
  have hL : ∀ m ≥ mt + 1, lk ((ρ.st n).run r) ≤ (ρ.st m).now := by
    intro m hm
    have h1 := stepS_now (ρ.steps mt)
    rw [htk] at h1
    simp only [Move.isTick, Act.isTick, ite_true] at h1
    have h2 := reachS_last (ρ.reach mt) r
    have h3 := lkL' mt hmt
    have h4 := nowMono (mt + 1) (m - (mt + 1))
    rw [show mt + 1 + (m - (mt + 1)) = m by omega] at h4
    have : lk ((ρ.st mt).run r) ≤ (ρ.st mt).now + 1 := by unfold lk; split <;> omega
    omega
  -- the measure only goes down, and a task of the project ending lowers it
  let L := lk ((ρ.st n).run r)
  have phiStep : ∀ m ≥ max n1 (mt + 1), phi cfg r L (ρ.st (m + 1)) ≤ phi cfg r L (ρ.st m) ∧
      (∀ b < cfg.nr, finOfM b (ρ.mv m) → (cfg.run b).proj = (cfg.run r).proj →
        phi cfg r L (ρ.st (m + 1)) < phi cfg r L (ρ.st m)) := by
    intro m hm
    have hmn : m ≥ n := by omega
    obtain ⟨u, hu, ht⟩ := stepS_pre (ρ.steps m)
    have hs := stay' m hmn
    obtain ⟨w1, w2, w3, w4, _⟩ := pre_waiting hu hs.1 (by rw [hs.2]; exact hp)
    have iu := inv_pre (reachS_inv (ρ.reach m)).1 hu
    have hp1 := pre_phi hu (r := r) (L := L) (fun b hb => noNew m hmn b hb)
    have hnow : (ρ.st m).now ≤ u.now := by rw [pre_now hu]; omega
    have h0 : (u.run r).running = 0 := by have := zero m (by omega); omega
    have hk : ((pass cfg u).run r).pend = (u.run r).pend := by
      rw [← ht, w2, (stay' (m + 1) (by omega)).2, hs.2]
    have hpp := pass_phi (pass_path cfg u) hr w1 (by rw [w2, hs.2]; exact hp) h0 (iu.cap r w1)
      (by rw [w3, lkL' m hmn]) (by have := hL m (by omega); omega) hk
    rw [ht]
    exact ⟨Nat.le_trans hpp hp1.1, fun b hb hf hpj => Nat.lt_of_le_of_lt hpp (hp1.2 b hb hf hpj)⟩
  obtain ⟨n3, hn3, hc3⟩ := eventually_const (fun m => phi cfg r L (ρ.st m)) (max n1 (mt + 1))
    (fun m hm => (phiStep m hm).1)
  -- so the project's tasks all end: it holds nothing
  have pz : ∀ m ≥ n3, projRun cfg (ρ.st m) (cfg.run r).proj = 0 := by
    intro m hm
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
  -- with the gates open under the backstop, the project, under share, starts a task
  obtain ⟨m, hm, hg, htot⟩ := hroom n3
  have hs := stay' m (by omega)
  have i := (reachS_inv (ρ.reach m)).1
  have hel : eligible (ρ.st m) r = true := by
    have h1 := i.cap r hs.1; have h2 := zero m (by omega)
    simp only [eligible, hs.1, Bool.true_and, Bool.and_eq_true, decide_eq_true_eq]
    exact ⟨by omega, by omega⟩
  have hu : under cfg (ρ.st m) r := by
    unfold under; rw [pz m (by omega), Nat.zero_mul]
    exact Nat.mul_pos (by omega) (Cfg.w_pos _ _)
  obtain ⟨f, hf, hpf, hff⟩ := first_exists hr hel
  have hc := reachS_start (ρ.reach m) hf
  have huf : under cfg (ρ.st m) f := (under_proj hpf).2 hu
  simp only [front, Bool.and_eq_true] at hff
  simp [canStart, hff.1, hff.2, hg, htot, huf] at hc

/-- The backstop condition of `run_starts` from a bound: if fewer than `4 × (pool − drain_max)`
tasks ever run at once, the backstop never holds a task, and gates open again and again suffice. -/
theorem run_starts_gates {cfg : Cfg} (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (noNew : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).proj ≠ (cfg.run r).proj)
    (ends : ∀ m b, b < cfg.nr → (cfg.run b).proj = (cfg.run r).proj → 0 < ((ρ.st m).run b).running →
      ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (htime : ∃ m ≥ n, ρ.mv m = .act .tick)
    (hbound : ∀ m, total cfg (ρ.st m) < 4 * (cfg.pool - cfg.drainMax))
    (gates : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true) :
    ∃ m ≥ n, ((ρ.st m).run r).pend < ((ρ.st n).run r).pend := by
  refine run_starts ρ hr hh hp noNew ends htime (fun m => ?_)
  obtain ⟨m', hm', hg⟩ := gates m
  refine ⟨m', hm', hg, ?_⟩
  have := (reachS_inv (ρ.reach m')).1.half
  have := hbound m'
  unfold capT; omega

/-- info: 'Cpuq.Contest.run_starts' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms run_starts

/-- info: 'Cpuq.Contest.run_starts_gates' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms run_starts_gates

end Cpuq.Contest
