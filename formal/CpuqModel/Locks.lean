/-
The pool lock and the drain mark: no critical section waits forever.

Every step of `step` is one critical section of the code, atomic here: nothing in it waits for
another process. The one critical section `move` spreads over two steps is a drain's
registration: it takes the pool lock (`Act.enter`), then the drain mark (`Act.mark`), then lets
the pool lock go. Before 0.30.1 the mark was exclusive, so a second drain waited for it under
the pool lock while the first drain, which holds the mark for its life, waited for the pool lock:
every cpuq stopped (`CS stuck` in `Checks.lean`). With the mark shared (`Rules.markShared`),
`lock_released` says the holder of the pool lock can always finish in one step.
-/
import CpuqModel.Liveness

namespace Cpuq

attribute [-simp] List.getD_eq_getElem?_getD

/-! ### What `step` leaves alone -/

/-- The parts of the state only `move` changes: the pool lock, the drain mark, the signals. -/
def extras (s : St) : Option Nat × Nat × Nat × Nat × Nat × Nat :=
  (s.poolLock, s.marks, s.tstp, s.held, s.halted, s.zs)

theorem grantOne_extras (cfg : Cfg) (s : St) (c : Nat) : extras (grantOne cfg s c) = extras s := by
  unfold grantOne; split
  · split <;> rfl
  · rfl

theorem handoutOver_extras (cfg : Cfg) (s : St) (cs : List Nat) :
    extras (handoutOver cfg s cs) = extras s := by
  induction cs generalizing s with
  | nil => rfl
  | cons c cs ih => simp only [handoutOver]; rw [ih, grantOne_extras]

theorem handout_extras (cfg : Cfg) (s : St) : extras (handout cfg s) = extras s :=
  handoutOver_extras cfg s _

theorem takeTok_extras (cfg : Cfg) (s : St) (o c : Nat) : extras (takeTok cfg s o c) = extras s := by
  unfold takeTok; split <;> rfl

theorem tryOnce_extras (cfg : Cfg) (s : St) (o : Nat) : extras (tryOnce cfg s o) = extras s := by
  unfold tryOnce; split
  · split
    · exact takeTok_extras ..
    · rfl
  · rfl

theorem reap_extras (cfg : Cfg) (s : St) (o i : Nat) (ok : Bool) :
    extras (reap cfg s o i ok) = extras s := by
  unfold reap; rw [tryOnce_extras]; rfl

theorem step_extras {cfg : Cfg} {s t : St} {a : Act} (e : step cfg s a = some t) :
    extras t = extras s := by
  cases a <;> simp only [Cpuq.step] at e <;> (repeat' split at e) <;>
    (first | cases e | skip) <;>
    first
    | rfl
    | exact reap_extras ..
    | exact handout_extras ..
    | exact takeTok_extras ..
    | (rw [handout_extras]; rfl)
    | simp at e

/-! ### The backfill window: only a drain's registration opens it, and time only shrinks it -/

theorem grantOne_window (cfg : Cfg) (s : St) (c : Nat) : (grantOne cfg s c).window = s.window := by
  unfold grantOne; split
  · split <;> rfl
  · rfl

theorem handoutOver_window (cfg : Cfg) (s : St) (cs : List Nat) :
    (handoutOver cfg s cs).window = s.window := by
  induction cs generalizing s with
  | nil => rfl
  | cons c cs ih => simp only [handoutOver]; rw [ih, grantOne_window]

theorem handout_window (cfg : Cfg) (s : St) : (handout cfg s).window = s.window :=
  handoutOver_window cfg s _

theorem takeTok_window (cfg : Cfg) (s : St) (o c : Nat) : (takeTok cfg s o c).window = s.window := by
  unfold takeTok; split <;> rfl

theorem tryOnce_window (cfg : Cfg) (s : St) (o : Nat) : (tryOnce cfg s o).window = s.window := by
  unfold tryOnce; split
  · split
    · exact takeTok_window ..
    · rfl
  · rfl

theorem reap_window (cfg : Cfg) (s : St) (o i : Nat) (ok : Bool) :
    (reap cfg s o i ok).window = s.window := by
  unfold reap; rw [tryOnce_window]; rfl

theorem step_window {cfg : Cfg} {s t : St} {a : Act} (e : step cfg s a = some t) :
    t.window = s.window := by
  cases a <;> simp only [Cpuq.step] at e <;> (repeat' split at e) <;>
    (first | cases e | skip) <;>
    first
    | rfl
    | exact reap_window ..
    | exact handout_window ..
    | exact takeTok_window ..
    | (rw [handout_window]; rfl)
    | simp at e

/-- No move but a drain's registration widens the window. -/
theorem move_window {cfg : Cfg} {s t : St} {a : Act} (e : move cfg s a = some t)
    (hm : ∀ o, a ≠ .mark o) : t.window ≤ s.window := by
  have viaMap : ∀ (b : Act) (f : St → St), (∀ u, (f u).window = u.window) →
      (step cfg s b).map f = some t → t.window ≤ s.window := by
    intro b f hf e
    obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
    rw [hf, step_window hu]; exact Nat.le_refl _
  unfold move at e
  split at e
  · cases e
  · cases a
    case mark => exact absurd rfl (hm _)
    all_goals (dsimp only at e; repeat' split at e)
    all_goals first
      | (cases e; done)
      | exact Nat.le_of_eq (step_window e)
      | exact viaMap _ _ (fun u => by first | rfl | (unfold retake; split <;> rfl)) e
      | (cases e; exact Nat.le_refl _)
      | (cases e; exact Nat.sub_le _ _)

/-! ### Phases -/

/-- A step never makes an operation waiting, and makes a waiting one start only by its arrival. -/
theorem step_phase {cfg : Cfg} {s t : St} {a : Act} (e : step cfg s a = some t) (p : Nat) :
    (t.op p).phase = (s.op p).phase ∨
    ((s.op p).phase ≠ .waiting ∧ (t.op p).phase ≠ .waiting) ∨ a = .arrive p := by
  have keepTask : ∀ (u : St) o i (x : Task), ((u.setTask o i x).op p).phase = (u.op p).phase :=
    fun u o i x => St.phase_setTask u o i p x
  have setPh : ∀ o (ph : Phase), (s.op o).phase ≠ .waiting → (s.op o).phase ≠ .over →
      ph ≠ .waiting →
      ((s.setPhase o ph).op p).phase = (s.op p).phase ∨
      ((s.op p).phase ≠ .waiting ∧ ((s.setPhase o ph).op p).phase ≠ .waiting) := by
    intro o ph ho hov hph
    by_cases eo : o = p
    · subst eo
      have hl := s.lt_of_phase o hov
      right; exact ⟨ho, by rw [St.phase_setPhase _ _ _ _ hl]; simpa using hph⟩
    · left; rw [St.op_setPhase_ne _ _ _ _ eo]
  cases a with
  | arrive o =>
    by_cases eo : o = p
    · subst eo; exact .inr (.inr rfl)
    · left
      simp only [Cpuq.step] at e; split at e
      · cases e
        rw [phase_of_ops (handout_order_ops cfg _).2]
        show ((s.setPhase o .alive).op p).phase = _
        rw [St.op_setPhase_ne _ _ _ _ eo]
      · cases e
  | exit o i ok =>
    left; simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; exact (reap_phase_order cfg s o i p ok).1
      · split at e
        · cases e; exact keepTask ..
        · cases e
    · cases e
  | timeout o i =>
    left; simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; exact keepTask ..
      · cases e
    · cases e
  | gone o i =>
    left; simp only [Cpuq.step] at e; split at e
    · cases e; exact keepTask ..
    · cases e
  | refill o c =>
    left; simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; exact keepTask ..
      · cases e
    · cases e
  | release o c =>
    left; simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; rw [phase_of_ops (handout_order_ops cfg _).2]; rfl
      · cases e
    · cases e
  | handout =>
    left; simp only [Cpuq.step] at e; split at e
    · cases e; exact phase_of_ops (handout_order_ops cfg s).2 p
    · cases e
  | accept o c =>
    left; simp only [Cpuq.step] at e; split at e
    · cases e; exact (takeTok_phase_order cfg s o c p).1
    · cases e
  | drain o c =>
    left; simp only [Cpuq.step] at e; split at e
    · cases e; rfl
    · cases e
  | undrain o c =>
    left; simp only [Cpuq.step] at e; split at e
    · cases e; rfl
    · cases e
  | consolidate o i d =>
    left; simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; exact keepTask ..
      · cases e
    · cases e
  | kill o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      have ha : (s.op o).phase = .alive := by simp [St.isAlive] at g; exact g.2
      have ho := s.lt_of_phase o (by rw [ha]; decide)
      rw [phase_of_ops (handout_order_ops cfg _).2, retire_eq _ _ _ _ ho, retired_phase _ _ _ _ _ ho]
      by_cases eo : o = p
      · subst eo; right; left; simp [ha]
      · left; simp [eo]
    · cases e
  | crash o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at g
      have hw : (s.op o).phase ≠ .waiting := by rcases g.2 with x | x <;> rw [x] <;> decide
      have hv : (s.op o).phase ≠ .over := by rcases g.2 with x | x <;> rw [x] <;> decide
      rcases setPh o .dead hw hv (by decide) with x | x
      · exact .inl x
      · exact .inr (.inl x)
    · cases e
  | stop o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      have ha : (s.op o).phase = .alive := by simp [St.isAlive] at g; exact g.2
      have ho := s.lt_of_phase o (by rw [ha]; decide)
      rw [phase_of_ops (handout_order_ops cfg _).2, retire_eq _ _ _ _ ho, retired_phase _ _ _ _ _ ho]
      by_cases eo : o = p
      · subst eo; right; left; simp [ha]
      · left; simp [eo]
    · cases e
  | cont o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      have hw : (s.op o).phase ≠ .waiting := by simp at g; rw [g]; decide
      have hv : (s.op o).phase ≠ .over := by simp at g; rw [g]; decide
      rcases setPh o .alive hw hv (by decide) with x | x
      · exact .inl x
      · exact .inr (.inl x)
    · cases e
  | finish o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      have hw : (s.op o).phase ≠ .waiting := by
        simp [St.isAlive] at g; rw [g.1.1]; decide
      have hv : (s.op o).phase ≠ .over := by
        simp [St.isAlive] at g; rw [g.1.1]; decide
      rw [phase_of_ops (handout_order_ops cfg _).2]
      rcases setPh o .over hw hv (by decide) with x | x
      · exact .inl x
      · exact .inr (.inl x)
    · cases e
  | enter o | mark o | tstp o | halt o | tick => simp [Cpuq.step] at e

/-! ### The pool lock -/

/-- The pool lock is held across steps only by a drain that is registering. -/
def LockOk (cfg : Cfg) (s : St) : Prop :=
  ∀ o, s.poolLock = some o → drainOp cfg o = true ∧ (s.op o).phase = .waiting

theorem LockOk.retake {cfg : Cfg} {u : St} {o : Nat} (h : LockOk cfg u) :
    LockOk cfg (Cpuq.retake cfg u o) := by
  unfold Cpuq.retake; split
  · exact h
  · exact h

theorem LockOk.move {cfg : Cfg} {s t : St} {a : Act} (h : LockOk cfg s)
    (e : move cfg s a = some t) : LockOk cfg t := by
  -- After a step that needs the lock, the lock is free (it was, and `step` keeps it).
  have viaStep : ∀ {b u}, step cfg s b = some u → s.poolLock = none → u.poolLock = none := by
    intro b u eb hn
    have := congrArg Prod.fst (step_extras eb); simp only [extras] at this; rw [this, hn]
  -- After a step that doesn't, the holder is the same and still waiting.
  have keep : ∀ {b u}, step cfg s b = some u → (∀ p, b ≠ .arrive p) → LockOk cfg u := by
    intro b u eb hb p hp
    have e1 := congrArg Prod.fst (step_extras eb); simp only [extras] at e1
    rw [e1] at hp
    obtain ⟨hd, hw⟩ := h p hp
    refine ⟨hd, ?_⟩
    rcases step_phase eb p with x | x | x
    · rw [x, hw]
    · exact absurd hw x.1
    · exact absurd x (hb p)
  unfold Cpuq.move at e
  split at e
  · cases e
  · rename_i hlk
    simp only [Bool.and_eq_true, Option.isSome_iff_exists, not_and, not_exists] at hlk
    have free : needsLock a = true → s.poolLock = none := by
      intro nl
      cases x : s.poolLock with
      | none => rfl
      | some q => exact absurd x (hlk nl q)
    have viaFree : ∀ {b u}, needsLock a = true → step cfg s b = some u → LockOk cfg u := by
      intro b u nl eb p hp
      rw [viaStep eb (free nl)] at hp; cases hp
    cases a with
    | arrive o =>
      dsimp only at e
      split at e
      · cases e
      · exact viaFree rfl e
    | enter o =>
      dsimp only at e
      split at e
      · rename_i g; cases e
        intro p hp; cases hp
        simp only [Bool.and_eq_true, beq_iff_eq] at g; exact g
      · cases e
    | mark o =>
      dsimp only at e
      split at e
      · obtain ⟨u, -, rfl⟩ := Option.map_eq_some_iff.1 e
        intro p hp; cases hp
      · cases e
    | crash o =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      intro p hp
      simp only at hp
      split at hp
      · cases hp
      · obtain ⟨hd, hw⟩ := h p hp
        refine ⟨hd, ?_⟩
        rcases step_phase hu p with x | x | x
        · show (u.op p).phase = _; rw [x, hw]
        · exact absurd hw x.1
        · cases x
    | kill o =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      intro p hp
      have := viaStep hu (free rfl); simp only [leave] at hp; rw [this] at hp; cases hp
    | finish o =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      intro p hp
      have := viaStep hu (free rfl); simp only [leave] at hp; rw [this] at hp; cases hp
    | tstp o =>
      dsimp only at e
      split at e
      · cases e; exact h
      · cases e
    | stop o =>
      dsimp only at e
      split at e
      · obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
        intro p hp
        have := viaStep hu (free rfl); simp only at hp; rw [this] at hp; cases hp
      · cases e
    | halt o =>
      dsimp only at e
      split at e
      · split at e
        · obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
          exact (keep hu (by intro p x; cases x)).retake
        · cases e; exact h
      · cases e
    | cont o =>
      dsimp only at e
      split at e
      · split at e
        · obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
          exact LockOk.retake (fun p hp => keep (b := .cont o) hu (by intro p x; cases x) p hp)
        · cases e; exact h
      · cases e
    | exit o i ok => exact keep e (by intro p x; cases x)
    | timeout o i => exact keep e (by intro p x; cases x)
    | gone o i => exact keep e (by intro p x; cases x)
    | refill o c => exact keep e (by intro p x; cases x)
    | consolidate o i d => exact keep e (by intro p x; cases x)
    | release o c => exact viaFree rfl e
    | handout => exact viaFree rfl e
    | accept o c => exact viaFree rfl e
    | drain o c => exact viaFree rfl e
    | undrain o c => exact viaFree rfl e
    | tick =>
      dsimp only at e
      split at e
      · cases e; exact h
      · cases e

theorem Reach.lockOk {cfg : Cfg} {s : St} (r : Reach cfg s) : LockOk cfg s := by
  induction r with
  | init => intro o hp; simp [Cpuq.init] at hp
  | step a _ e ih => exact ih.move e

/-- No critical section waits forever: with the drain mark shared, whoever holds the pool lock
can take its mark, register and let the lock go, in one step, whatever anyone else holds. -/
theorem lock_released {cfg : Cfg} {s : St} (r : Reach cfg s) (hm : cfg.rules.markShared = true)
    {o : Nat} (hl : s.poolLock = some o) :
    ∃ t, move cfg s (.mark o) = some t ∧ t.poolLock = none := by
  obtain ⟨-, hw⟩ := r.lockOk o hl
  have hs : step cfg s (.arrive o) =
      some (handout cfg { s.setPhase o .alive with order := s.order ++ [o] }) := by
    simp only [Cpuq.step, hw, beq_self_eq_true, ite_true]
  refine ⟨{ handout cfg { s.setPhase o .alive with order := s.order ++ [o] } with
      poolLock := none,
      marks := setBit (handout cfg { s.setPhase o .alive with order := s.order ++ [o] }).marks o,
      window := cfg.window },
    ?_, rfl⟩
  simp only [Cpuq.move, needsLock, Bool.false_and, Bool.false_eq_true, ite_false, hl, beq_self_eq_true,
    hm, Bool.true_or, Bool.and_self, ite_true, hs, Option.map_some]

end Cpuq
