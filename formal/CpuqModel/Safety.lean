/-
The safety invariant: one inductive invariant `Inv`, true of `init` and kept by every step,
crashes included, under any rules that keep the three safety switches on (`Safe`).
-/
import CpuqModel.Lemmas

namespace Cpuq

attribute [-simp] List.getD_eq_getElem?_getD

/-- The switches safety needs: reclaim on take (F5), a timed-out task retried only after its
attempt exits, and a slot with a dying attempt not empty. The liveness switches (standing,
ledger, share rule, valid grants, zero first, giver behind) can be anything. -/
structure Safe (r : Rules) : Prop where
  reclaim : r.reclaim = true
  retryAtReap : r.retryAtReap = true
  releaseWaitsDying : r.releaseWaitsDying = true

structure Inv (cfg : Cfg) (s : St) : Prop where
  /-- The pool never changes size. -/
  len : s.cpus.length = cfg.cpus
  /-- A token's flock is held only by a living operation, and its record names that holder. -/
  lockOwner : ∀ c o, (s.cpu c).lock = some o → ownsC o (s.cpu c) = true ∧ (s.op o).phase = .alive
  /-- A record whose owner lives is backed by that owner's flock. -/
  ownerLock : ∀ c sl, (s.cpu c).slot = some sl → (s.op sl.owner).phase = .alive →
    (s.cpu c).lock = some sl.owner
  /-- A record names a living operation, or a dead one whose leftovers are not yet reclaimed. -/
  ownerPhase : ∀ c sl, (s.cpu c).slot = some sl →
    (s.op sl.owner).phase = .alive ∨ (s.op sl.owner).phase = .dead
  /-- A grant is only on a token no one holds, to an operation that has started. -/
  grantFree : ∀ c h, (s.cpu c).grant = some h → (s.cpu c).lock = none ∧ (s.op h).phase ≠ .waiting
  /-- Never more than K processes per slot (S4). -/
  kBound : ∀ c sl, (s.cpu c).slot = some sl → s.runningOn sl.owner c ≤ (cfg.op sl.owner).K
  /-- Never more than C slots, granted ones included (S3). -/
  capBound : ∀ o, ((s.op o).phase = .alive ∨ (s.op o).phase = .stopped) →
    s.owned o + s.grants o ≤ (cfg.op o).cap
  /-- The shared drain count is the number of draining slots. -/
  drainCount : s.drains = s.cpus.countP drainingC
  /-- A dying attempt belongs to a task waiting on it, never to one running again (S5). -/
  dyingTimedOut : ∀ o i, (s.task o i).dying ≠ none → (s.task o i).st = .timedOut
  /-- Every process on CPU c is its holder's, or a dead operation's while no one holds c (S1'). -/
  pinned : ∀ o i c, ((s.task o i).st = .running c ∨ (s.task o i).dying = some c) →
    ((s.op o).phase = .alive ∧ (s.cpu c).lock = some o) ∨
    ((s.op o).phase = .dead ∧ (s.cpu c).lock = none)

/-! ### Small facts -/

theorem ownsC_iff (o : Nat) (x : Cpu) : ownsC o x = true ↔ ∃ d, x.slot = some ⟨o, d⟩ := by
  unfold ownsC
  cases x.slot with
  | none => simp
  | some sl =>
    obtain ⟨ow, d⟩ := sl
    constructor
    · intro h; exact ⟨d, by simp at h; rw [h]⟩
    · rintro ⟨d', h⟩; simp at h; simp [h.1]

theorem ownsC_of_slot {o : Nat} {x : Cpu} {sl : Slot} (h : x.slot = some sl) (e : sl.owner = o) :
    ownsC o x = true := by
  unfold ownsC; rw [h]; simp [e]

@[simp] theorem St.cpu_setTask (s : St) (o i c : Nat) (t : Task) : (s.setTask o i t).cpu c = s.cpu c := rfl
@[simp] theorem St.cpu_setPhase (s : St) (o c : Nat) (p : Phase) : (s.setPhase o p).cpu c = s.cpu c := rfl
@[simp] theorem St.cpu_mapTasks (s : St) (o c : Nat) (f : Task → Task) : (s.mapTasks o f).cpu c = s.cpu c := rfl

theorem ownsC_empty (o : Nat) : ownsC o {} = false := rfl
theorem drainingC_empty : drainingC {} = false := rfl

theorem St.op_default (s : St) (o : Nat) (h : ¬ o < s.ops.length) : s.op o = {} := by
  simp [St.op, List.getD_eq_getElem?_getD, List.getElem?_eq_none (Nat.le_of_not_lt h)]

theorem St.lt_of_phase (s : St) (o : Nat) (h : (s.op o).phase ≠ .over) : o < s.ops.length :=
  Classical.byContradiction fun hn => h (by rw [s.op_default o hn])

theorem St.cpu_default (s : St) (c : Nat) (h : ¬ c < s.cpus.length) : s.cpu c = {} := by
  simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_none (Nat.le_of_not_lt h)]

theorem St.task_default (s : St) (o i : Nat) (h : ¬ i < (s.op o).tasks.length) :
    s.task o i = { st := .gone } := by
  simp [St.task, List.getD_eq_getElem?_getD, List.getElem?_eq_none (Nat.le_of_not_lt h)]

theorem St.lt_of_task (s : St) (o i : Nat) (h : (s.task o i).st ≠ .gone) :
    i < (s.op o).tasks.length :=
  Classical.byContradiction fun hn => h (by rw [s.task_default o i hn])

theorem St.lt_of_task_op (s : St) (o i : Nat) (h : (s.task o i).st ≠ .gone) : o < s.ops.length := by
  refine Classical.byContradiction fun hn => h ?_
  simp [St.task, s.op_default o hn]

theorem St.lt_of_slot (s : St) (c : Nat) (h : (s.cpu c).slot ≠ none) : c < s.cpus.length :=
  Classical.byContradiction fun hn => h (by rw [s.cpu_default c hn])

theorem St.lt_of_grant (s : St) (c : Nat) (h : (s.cpu c).grant ≠ none) : c < s.cpus.length :=
  Classical.byContradiction fun hn => h (by rw [s.cpu_default c hn])

/-- Counting after one entry of a list changes. -/
theorem countP_setCpu (p : Cpu → Bool) (s : St) (c : Nat) (x : Cpu) (h : c < s.cpus.length) :
    (s.cpus.set c x).countP p + (if p (s.cpu c) then 1 else 0) =
      s.cpus.countP p + (if p x then 1 else 0) :=
  countP_set' p s.cpus c x {} h

theorem runningOn_setTask (s : St) (o i c : Nat) (t : Task) (ho : o < s.ops.length)
    (hi : i < (s.op o).tasks.length) :
    (s.setTask o i t).runningOn o c + (if runningC c (s.task o i) then 1 else 0) =
      s.runningOn o c + (if runningC c t then 1 else 0) := by
  simp only [St.runningOn, St.setTask, St.op_set, ho, and_self, ite_true, St.task]
  exact countP_set' _ _ i t _ hi

theorem runningOn_setTask_ne (s : St) (o i o' c : Nat) (t : Task) (h : o ≠ o') :
    (s.setTask o i t).runningOn o' c = s.runningOn o' c := by
  simp [St.runningOn, St.tasks_setTask_ne _ _ _ _ _ h]

theorem owned_setTask (s : St) (o i o' : Nat) (t : Task) : (s.setTask o i t).owned o' = s.owned o' := rfl
theorem grants_setTask (s : St) (o i o' : Nat) (t : Task) : (s.setTask o i t).grants o' = s.grants o' := rfl

/-! ### One task changes -/

theorem Inv.setTask {cfg : Cfg} {s : St} {o i : Nat} {t : Task} (h : Inv cfg s)
    (ho : o < s.ops.length) (hi : i < (s.op o).tasks.length)
    (hdy : t.dying ≠ none → t.st = .timedOut)
    (hpin : ∀ c, (t.st = .running c ∨ t.dying = some c) →
      ((s.op o).phase = .alive ∧ (s.cpu c).lock = some o) ∨
      ((s.op o).phase = .dead ∧ (s.cpu c).lock = none))
    (hk : ∀ c, ownsC o (s.cpu c) = true → runningC c t = true → runningC c (s.task o i) = false →
      s.runningOn o c < (cfg.op o).K) :
    Inv cfg (s.setTask o i t) where
  len := h.len
  lockOwner c o' hl := by
    have := h.lockOwner c o' hl
    exact ⟨this.1, by rw [St.phase_setTask]; exact this.2⟩
  ownerLock c sl hs ha := h.ownerLock c sl hs (by rwa [St.phase_setTask] at ha)
  ownerPhase c sl hs := by rw [St.phase_setTask]; exact h.ownerPhase c sl hs
  grantFree c h' hg := by rw [St.phase_setTask]; exact h.grantFree c h' hg
  kBound c sl hs := by
    obtain ⟨ow, d⟩ := sl
    simp only [St.cpu_setTask] at hs
    show (s.setTask o i t).runningOn ow c ≤ (cfg.op ow).K
    by_cases e : o = ow
    · subst e
      have h1 := runningOn_setTask s o i c t ho hi
      have h2 : s.runningOn o c ≤ (cfg.op o).K := h.kBound c _ hs
      have hown : ownsC o (s.cpu c) = true := ownsC_of_slot hs rfl
      cases r1 : runningC c t <;> cases r0 : runningC c (s.task o i) <;> simp [r1, r0] at h1
      · omega
      · omega
      · have := hk c hown r1 r0; omega
      · omega
    · rw [runningOn_setTask_ne _ _ _ _ _ _ e]; exact h.kBound c _ hs
  capBound o' hp := by
    rw [St.phase_setTask] at hp
    rw [owned_setTask, grants_setTask]; exact h.capBound o' hp
  drainCount := h.drainCount
  dyingTimedOut o' i' := by
    rw [St.task_setTask]
    split
    · exact hdy
    · exact h.dyingTimedOut o' i'
  pinned o' i' c := by
    rw [St.task_setTask, St.phase_setTask]
    split
    · rename_i e; obtain ⟨rfl, rfl, -, -⟩ := e; exact hpin c
    · exact h.pinned o' i' c

/-! ### Taking a token, with reclaim -/

/-- The state after reclaim on CPU `c`. -/
def reclaimed (s : St) (c : Nat) : St := { s with ops := reclaimOps c s.ops }

theorem reclaimed_op (s : St) (c o : Nat) :
    (reclaimed s c).op o =
      if (s.op o).phase == .dead then { s.op o with tasks := (s.op o).tasks.map (killOn c) }
      else s.op o := by
  simp only [reclaimed, St.op, reclaimOps, List.getD_eq_getElem?_getD, List.getElem?_map]
  cases s.ops[o]? <;> rfl

theorem reclaimed_phase (s : St) (c o : Nat) : ((reclaimed s c).op o).phase = (s.op o).phase := by
  rw [reclaimed_op]; split <;> rfl

theorem killOn_default (c : Nat) : killOn c { st := .gone } = { st := .gone } := by
  simp [killOn]

theorem reclaimed_task (s : St) (c o i : Nat) :
    (reclaimed s c).task o i =
      if (s.op o).phase = .dead then killOn c (s.task o i) else s.task o i := by
  simp only [St.task, reclaimed_op]
  by_cases hd : (s.op o).phase = .dead
  · rw [ite_eq_left (by simpa using hd), ite_eq_left hd]
    exact getD_map _ (killOn c) i ({ st := .gone } : Task) ({ st := .gone } : Task) (killOn_default c)
  · rw [ite_eq_right (by simpa using hd), ite_eq_right hd]


theorem reclaimed_runningOn_le (s : St) (c o c' : Nat) :
    (reclaimed s c).runningOn o c' ≤ s.runningOn o c' := by
  simp only [St.runningOn, reclaimed_op]
  split
  · rw [List.countP_map]
    apply List.countP_mono_left
    intro t _ ht
    simp only [Function.comp, runningC, killOn] at ht ⊢
    by_cases e : t.st = .running c <;> simp_all
  · exact Nat.le_refl _

theorem countP_zero_of {α} {p : α → Bool} {l : List α} (h : ∀ x ∈ l, p x = false) : l.countP p = 0 :=
  List.countP_eq_zero.2 (fun x hx => by simp [h x hx])

theorem mem_tasks_task {s : St} {o : Nat} {t : Task} (h : t ∈ (s.op o).tasks) : ∃ i, s.task o i = t := by
  obtain ⟨i, hi, e⟩ := List.getElem_of_mem h
  exact ⟨i, by simp [St.task, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi, e]⟩

/-- An alive operation has no process on a CPU it does not hold. -/
theorem Inv.runningOn_zero {cfg : Cfg} {s : St} {o c : Nat} (h : Inv cfg s)
    (ha : (s.op o).phase = .alive) (hl : (s.cpu c).lock ≠ some o) : s.runningOn o c = 0 := by
  apply countP_zero_of
  intro t ht
  obtain ⟨i, rfl⟩ := mem_tasks_task ht
  cases r : runningC c (s.task o i)
  · rfl
  · have : (s.task o i).st = .running c := by simpa [runningC] using r
    rcases h.pinned o i c (.inl this) with ⟨_, e⟩ | ⟨_, e⟩
    · exact absurd e hl
    · rename_i hd; rw [ha] at hd; cases hd

/-- The token record a take writes. -/
def takenCpu (o : Nat) : Cpu := { lock := some o, grant := none, slot := some { owner := o } }

/-- The state after `o` takes token `c` with reclaim. -/
def taken (s : St) (o c : Nat) : St :=
  St.mk (s.cpus.set c (takenCpu o)) (reclaimOps c s.ops) s.order
    (s.drains - (if drainingC (s.cpu c) then 1 else 0)) s.crashes s.poolLock s.marks s.tstp s.held
    s.halted s.zs

theorem takeTok_eq (cfg : Cfg) (s : St) (o c : Nat) (hr : cfg.rules.reclaim = true) :
    takeTok cfg s o c = taken s o c := by
  simp [takeTok, hr, taken, takenCpu]

theorem taken_op (s : St) (o c o' : Nat) : (taken s o c).op o' = (reclaimed s c).op o' := rfl
theorem taken_task (s : St) (o c o' i : Nat) : (taken s o c).task o' i = (reclaimed s c).task o' i := rfl
theorem taken_runningOn (s : St) (o c o' c' : Nat) :
    (taken s o c).runningOn o' c' = (reclaimed s c).runningOn o' c' := rfl

theorem Inv.takeTok {cfg : Cfg} {s : St} {o c : Nat} (h : Inv cfg s) (hr : cfg.rules.reclaim = true)
    (ha : (s.op o).phase = .alive) (hc : c < s.cpus.length) (hl : (s.cpu c).lock = none)
    (hcap : s.owned o + s.grants o + (if (s.cpu c).grant = some o then 0 else 1) ≤ (cfg.op o).cap) :
    Inv cfg (takeTok cfg s o c) := by
  rw [takeTok_eq cfg s o c hr]
  -- How the new state reads.
  have hcpu : ∀ c', (taken s o c).cpu c' = if c = c' then takenCpu o else s.cpu c' := by
    intro c'; simp only [St.cpu, taken, getD_set, hc, and_true]
  -- The old record is not a living operation's.
  have hold : ∀ sl, (s.cpu c).slot = some sl → (s.op sl.owner).phase ≠ .alive := by
    intro sl hs ha'; have := h.ownerLock c sl hs ha'; rw [hl] at this; cases this
  have hnotown : ownsC o (s.cpu c) = false := by
    cases e : ownsC o (s.cpu c)
    · rfl
    · obtain ⟨d, hd⟩ := (ownsC_iff _ _).1 e
      exact absurd ha (hold _ hd)
  refine
  { len := by simp [taken, h.len]
    lockOwner := ?_, ownerLock := ?_, ownerPhase := ?_, grantFree := ?_, kBound := ?_,
    capBound := ?_, drainCount := ?_, dyingTimedOut := ?_, pinned := ?_ }
  · intro c' o' hlo
    rw [hcpu] at hlo ⊢
    rw [taken_op, reclaimed_phase]
    by_cases e : c = c'
    · rw [ite_eq_left e] at hlo ⊢; simp [takenCpu] at hlo; subst hlo; simp [takenCpu, ownsC, ha]
    · rw [ite_eq_right e] at hlo ⊢; exact h.lockOwner c' o' hlo
  · intro c' sl hs hal
    rw [hcpu] at hs ⊢
    rw [taken_op, reclaimed_phase] at hal
    by_cases e : c = c'
    · rw [ite_eq_left e] at hs ⊢; simp [takenCpu] at hs; subst hs; simp [takenCpu]
    · rw [ite_eq_right e] at hs ⊢; exact h.ownerLock c' sl hs hal
  · intro c' sl hs
    rw [hcpu] at hs
    rw [taken_op, reclaimed_phase]
    by_cases e : c = c'
    · rw [ite_eq_left e] at hs; simp [takenCpu] at hs; subst hs; exact .inl ha
    · rw [ite_eq_right e] at hs; exact h.ownerPhase c' sl hs
  · intro c' h' hg
    rw [hcpu] at hg ⊢
    rw [taken_op, reclaimed_phase]
    by_cases e : c = c'
    · rw [ite_eq_left e] at hg; simp [takenCpu] at hg
    · rw [ite_eq_right e] at hg ⊢; exact h.grantFree c' h' hg
  · intro c' sl hs
    rw [hcpu] at hs
    rw [taken_runningOn]
    split at hs
    · simp [takenCpu] at hs; subst hs
      have := reclaimed_runningOn_le s c o c'
      rename_i e; subst e
      have z := h.runningOn_zero ha (by rw [hl]; simp)
      simp only at this ⊢; omega
    · exact Nat.le_trans (reclaimed_runningOn_le s c sl.owner c') (h.kBound c' sl hs)
  · intro o' hp
    rw [taken_op, reclaimed_phase] at hp
    have h0 := h.capBound o' hp
    show (s.cpus.set c (takenCpu o)).countP (ownsC o') + (s.cpus.set c (takenCpu o)).countP (grantedC o') ≤ _
    have e1 := countP_setCpu (ownsC o') s c (takenCpu o) hc
    have e2 := countP_setCpu (grantedC o') s c (takenCpu o) hc
    simp only [St.owned, St.grants] at h0 hcap
    have gt : grantedC o' (takenCpu o) = false := by simp [takenCpu, grantedC]
    have go : grantedC o' (s.cpu c) = decide ((s.cpu c).grant = some o') := by
      unfold grantedC; by_cases g : (s.cpu c).grant = some o' <;> simp [g]
    rw [gt, go] at e2
    by_cases eo : o' = o
    · subst eo
      have ot : ownsC o' (takenCpu o') = true := by simp [takenCpu, ownsC]
      rw [hnotown, ot] at e1
      by_cases g : (s.cpu c).grant = some o'
      · simp [g] at e2 hcap; simp at e1; omega
      · simp [g] at e2 hcap; simp at e1; omega
    · have ot : ownsC o' (takenCpu o) = false := by simp [takenCpu, ownsC]; exact Ne.symm eo
      rw [ot] at e1
      simp only [Bool.false_eq_true, ite_false, Nat.add_zero] at e1 e2
      have : (s.cpus.set c (takenCpu o)).countP (ownsC o') ≤ s.cpus.countP (ownsC o') := by
        split at e1 <;> omega
      have : (s.cpus.set c (takenCpu o)).countP (grantedC o') ≤ s.cpus.countP (grantedC o') := by
        split at e2 <;> omega
      omega
  · show s.drains - (if drainingC (s.cpu c) then 1 else 0) = (s.cpus.set c (takenCpu o)).countP drainingC
    have e := countP_setCpu drainingC s c (takenCpu o) hc
    have dt : drainingC (takenCpu o) = false := rfl
    rw [dt, ← h.drainCount] at e
    cases hd : drainingC (s.cpu c) <;> simp [hd] at e ⊢ <;> omega
  · intro o' i hd
    rw [taken_task, reclaimed_task] at hd ⊢
    split
    · rename_i hdead; rw [ite_eq_left hdead] at hd
      simp only [killOn] at hd ⊢
      have : (s.task o' i).dying ≠ none := by intro e; simp [e] at hd
      have := h.dyingTimedOut o' i this
      simp [this]
    · rename_i hdead; rw [ite_eq_right hdead] at hd; exact h.dyingTimedOut o' i hd
  · intro o' i c'' hon
    rw [taken_op, reclaimed_phase, hcpu]
    rw [taken_task, reclaimed_task] at hon
    -- c'' is not c: nothing of anyone is left on c.
    have hne : c ≠ c'' := by
      intro e; subst e
      split at hon
      · simp only [killOn] at hon
        rcases hon with hon | hon
        · by_cases q : (s.task o' i).st = .running c <;> simp [q] at hon
        · by_cases q : (s.task o' i).dying = some c <;> simp [q] at hon
      · rcases h.pinned o' i c hon with ⟨hp, e⟩ | ⟨hp, _⟩
        · rw [hl] at e; cases e
        · contradiction
    rw [ite_eq_right hne]
    apply h.pinned o' i c''
    split at hon
    · simp only [killOn] at hon
      rcases hon with hon | hon
      · left; by_cases q : (s.task o' i).st = .running c <;> simp [q] at hon <;> exact hon
      · right; by_cases q : (s.task o' i).dying = some c <;> simp [q] at hon <;> exact hon
    · exact hon

/-! ### One token record changes -/

/-- `s` with CPU `c`'s record replaced, the drain count and the tickets given. -/
def withCpu (s : St) (c : Nat) (x : Cpu) (d : Nat) (ord : List Nat) : St :=
  St.mk (s.cpus.set c x) s.ops ord d s.crashes s.poolLock s.marks s.tstp s.held s.halted s.zs

theorem withCpu_cpu (s : St) (c : Nat) (x : Cpu) (d : Nat) (ord : List Nat) (c' : Nat)
    (hc : c < s.cpus.length) : (withCpu s c x d ord).cpu c' = if c = c' then x else s.cpu c' := by
  simp only [St.cpu, withCpu, getD_set, hc, and_true]

theorem withCpu_op (s : St) (c : Nat) (x : Cpu) (d : Nat) (ord : List Nat) (o : Nat) :
    (withCpu s c x d ord).op o = s.op o := rfl
theorem withCpu_task (s : St) (c : Nat) (x : Cpu) (d : Nat) (ord : List Nat) (o i : Nat) :
    (withCpu s c x d ord).task o i = s.task o i := rfl
theorem withCpu_runningOn (s : St) (c : Nat) (x : Cpu) (d : Nat) (ord : List Nat) (o c' : Nat) :
    (withCpu s c x d ord).runningOn o c' = s.runningOn o c' := rfl

def b2n (b : Bool) : Nat := if b then 1 else 0

theorem Inv.withCpu {cfg : Cfg} {s : St} {c : Nat} {x : Cpu} {d : Nat} {ord : List Nat}
    (h : Inv cfg s) (hc : c < s.cpus.length)
    (hlo : ∀ o, x.lock = some o → ownsC o x = true ∧ (s.op o).phase = .alive)
    (hol : ∀ sl, x.slot = some sl → (s.op sl.owner).phase = .alive → x.lock = some sl.owner)
    (hop : ∀ sl, x.slot = some sl → (s.op sl.owner).phase = .alive ∨ (s.op sl.owner).phase = .dead)
    (hgr : ∀ g, x.grant = some g → x.lock = none ∧ (s.op g).phase ≠ .waiting)
    (hk : ∀ sl, x.slot = some sl → s.runningOn sl.owner c ≤ (cfg.op sl.owner).K)
    (hcap : ∀ o, ((s.op o).phase = .alive ∨ (s.op o).phase = .stopped) →
      s.owned o + s.grants o + b2n (ownsC o x) + b2n (grantedC o x) ≤
        (cfg.op o).cap + b2n (ownsC o (s.cpu c)) + b2n (grantedC o (s.cpu c)))
    (hd : d + b2n (drainingC (s.cpu c)) = s.drains + b2n (drainingC x))
    (hpin : ∀ o i, ((s.task o i).st = .running c ∨ (s.task o i).dying = some c) →
      ((s.op o).phase = .alive ∧ x.lock = some o) ∨ ((s.op o).phase = .dead ∧ x.lock = none)) :
    Inv cfg (withCpu s c x d ord) := by
  have hcpu := fun c' => withCpu_cpu s c x d ord c' hc
  refine
  { len := by show (s.cpus.set c x).length = _; rw [List.length_set]; exact h.len
    lockOwner := ?_, ownerLock := ?_, ownerPhase := ?_, grantFree := ?_, kBound := ?_,
    capBound := ?_, drainCount := ?_, dyingTimedOut := h.dyingTimedOut, pinned := ?_ }
  · intro c' o hl; rw [hcpu] at hl ⊢; rw [withCpu_op]
    by_cases e : c = c'
    · rw [ite_eq_left e] at hl ⊢; exact hlo o hl
    · rw [ite_eq_right e] at hl ⊢; exact h.lockOwner c' o hl
  · intro c' sl hs ha; rw [hcpu] at hs ⊢; rw [withCpu_op] at ha
    by_cases e : c = c'
    · rw [ite_eq_left e] at hs ⊢; exact hol sl hs ha
    · rw [ite_eq_right e] at hs ⊢; exact h.ownerLock c' sl hs ha
  · intro c' sl hs; rw [hcpu] at hs; rw [withCpu_op]
    by_cases e : c = c'
    · rw [ite_eq_left e] at hs; exact hop sl hs
    · rw [ite_eq_right e] at hs; exact h.ownerPhase c' sl hs
  · intro c' g hg; rw [hcpu] at hg ⊢; rw [withCpu_op]
    by_cases e : c = c'
    · rw [ite_eq_left e] at hg ⊢; exact hgr g hg
    · rw [ite_eq_right e] at hg ⊢; exact h.grantFree c' g hg
  · intro c' sl hs; rw [hcpu] at hs; rw [withCpu_runningOn]
    by_cases e : c = c'
    · rw [ite_eq_left e] at hs; subst e; exact hk sl hs
    · rw [ite_eq_right e] at hs; exact h.kBound c' sl hs
  · intro o hp
    rw [withCpu_op] at hp
    have := hcap o hp
    have e1 := countP_setCpu (ownsC o) s c x hc
    have e2 := countP_setCpu (grantedC o) s c x hc
    have := h.capBound o hp
    show (s.cpus.set c x).countP (ownsC o) + (s.cpus.set c x).countP (grantedC o) ≤ _
    simp only [St.owned, St.grants, b2n] at *
    omega
  · show d = (s.cpus.set c x).countP drainingC
    have e := countP_setCpu drainingC s c x hc
    have := h.drainCount
    simp only [b2n] at hd
    omega
  · intro o i c' hon; rw [hcpu, withCpu_op]
    by_cases e : c = c'
    · rw [ite_eq_left e]; subst e; exact hpin o i hon
    · rw [ite_eq_right e]; exact h.pinned o i c' hon

/-! ### The line and hand-out -/

theorem foldl_head_waiter (cfg : Cfg) (s : St) (l : List Nat) (init : Option Nat)
    (hi : ∀ b, init = some b → waiter cfg s b = true) (h : Nat)
    (e : l.foldl (fun best o =>
      if waiter cfg s o then
        match best with
        | none => some o
        | some b => if before cfg s o b then some o else best
      else best) init = some h) : waiter cfg s h = true := by
  induction l generalizing init with
  | nil => exact hi h e
  | cons o l ih =>
    simp only [List.foldl_cons] at e
    refine ih _ ?_ e
    intro b hb
    by_cases w : waiter cfg s o = true
    · rw [ite_eq_left w] at hb
      cases init with
      | none => simp at hb; subst hb; exact w
      | some b' =>
        simp only at hb
        split at hb
        · simp at hb; subst hb; exact w
        · exact hi b hb
    · rw [ite_eq_right w] at hb; exact hi b hb

/-- The head is in the line (rule 5). -/
theorem head_waiter {cfg : Cfg} {s : St} {h : Nat} (e : head cfg s = some h) : waiter cfg s h = true :=
  foldl_head_waiter cfg s s.order none (by simp) h e

theorem liveOp_phase {cfg : Cfg} {s : St} {h : Nat} (l : liveOp cfg s h = true) :
    (s.op h).phase = .alive ∨ (s.op h).phase = .stopped := by
  simp only [liveOp, St.isAlive, Bool.or_eq_true, Bool.and_eq_true, beq_iff_eq] at l
  rcases l with l | l
  · exact .inl l
  · exact .inr l.2

theorem waiter_live {cfg : Cfg} {s : St} {h : Nat} (w : waiter cfg s h = true) : liveOp cfg s h = true := by
  simp only [waiter, Bool.and_eq_true] at w; exact w.1.1

theorem demand_room {cfg : Cfg} {s : St} {h : Nat} (d : demand cfg s h > 0) :
    s.owned h + s.grants h < (cfg.op h).cap := by
  unfold demand at d
  split at d
  · split at d
    · split at d
      · omega
      · exact absurd d (Nat.lt_irrefl 0)
    · have := Nat.lt_of_lt_of_le d (Nat.min_le_left _ _); omega
  · exact absurd d (Nat.lt_irrefl 0)

theorem demand_live {cfg : Cfg} {s : St} {h : Nat} (d : demand cfg s h > 0) : liveOp cfg s h = true := by
  unfold demand at d
  split at d
  · assumption
  · exact absurd d (Nat.lt_irrefl 0)

theorem waiter_room {cfg : Cfg} {s : St} {h : Nat} (w : waiter cfg s h = true) :
    s.owned h + s.grants h < (cfg.op h).cap := by
  simp only [waiter, Bool.and_eq_true, decide_eq_true_eq] at w
  exact demand_room w.1.2

/-- A free token goes only to a living operation with room under its ceiling. -/
theorem target_ok {cfg : Cfg} {s : St} {g : Nat} (e : target cfg s = some g) :
    liveOp cfg s g = true ∧ s.owned g + s.grants g < (cfg.op g).cap := by
  unfold target at e
  split at e
  · split at e
    · rename_i hd; cases e; simp only [decide_eq_true_eq] at hd
      exact ⟨demand_live hd, demand_room hd⟩
    · cases e
  · have w := head_waiter e; exact ⟨waiter_live w, waiter_room w⟩

theorem freeC_lock {cfg : Cfg} {s : St} {x : Cpu} (f : freeC cfg s x = true) : x.lock = none := by
  simp only [freeC, Bool.and_eq_true, Option.isNone_iff_eq_none] at f; exact f.1

theorem freeC_grant {cfg : Cfg} {s : St} {x : Cpu} {g : Nat} (f : freeC cfg s x = true)
    (hg : x.grant = some g) : grantLive cfg s g = false := by
  cases l : grantLive cfg s g
  · rfl
  · simp only [freeC, validGrantC, hg, l, Bool.and_eq_true, Bool.not_eq_true', Bool.or_true] at f
    exact absurd f.2 (by decide)

theorem setCpu_eq (s : St) (c : Nat) (x : Cpu) : s.setCpu c x = withCpu s c x s.drains s.order := rfl

theorem setCpu_of_ge (s : St) (c : Nat) (x : Cpu) (hc : ¬ c < s.cpus.length) : s.setCpu c x = s := by
  simp only [St.setCpu, set_of_ge _ _ _ hc]

theorem Inv.grantOne {cfg : Cfg} {s : St} (h : Inv cfg s) (c : Nat) : Inv cfg (Cpuq.grantOne cfg s c) := by
  unfold Cpuq.grantOne
  split
  · rename_i f
    split
    · rename_i g hh
      by_cases hc : c < s.cpus.length
      · rw [setCpu_eq]
        have hl := freeC_lock f
        obtain ⟨hlive, hroom⟩ := target_ok hh
        have hold : (s.cpu c).grant ≠ some g := fun e => by
          have := freeC_grant f e; simp [grantLive, hlive] at this
        apply h.withCpu hc
        · intro o e; simp [hl] at e
        · intro sl hs hal; have := h.ownerLock c sl hs hal; rw [hl] at this; cases this
        · intro sl hs; exact h.ownerPhase c sl hs
        · intro g' e; cases e
          exact ⟨hl, by rcases liveOp_phase hlive with x | x <;> rw [x] <;> decide⟩
        · intro sl hs; exact h.kBound c sl hs
        · intro o hp
          have := h.capBound o hp
          have own : ownsC o { s.cpu c with grant := some g } = ownsC o (s.cpu c) := rfl
          rw [own]
          by_cases eo : o = g
          · subst eo
            have : grantedC o (s.cpu c) = false := by simp [grantedC, hold]
            simp [b2n, grantedC] at *; omega
          · have : grantedC o { s.cpu c with grant := some g } = false := by
              simp [grantedC]; exact Ne.symm eo
            rw [this]; simp only [b2n, Bool.false_eq_true, ite_false]; omega
        · rfl
        · intro o i hon
          rcases h.pinned o i c hon with ⟨_, e⟩ | ⟨hp, e⟩
          · rw [hl] at e; cases e
          · exact .inr ⟨hp, hl⟩
      · rw [setCpu_of_ge _ _ _ hc]; exact h
    · exact h
  · exact h

theorem Inv.handoutOver {cfg : Cfg} {s : St} (h : Inv cfg s) (cs : List Nat) :
    Inv cfg (Cpuq.handoutOver cfg s cs) := by
  induction cs generalizing s with
  | nil => exact h
  | cons c cs ih => exact ih (h.grantOne c)

theorem Inv.handout {cfg : Cfg} {s : St} (h : Inv cfg s) : Inv cfg (Cpuq.handout cfg s) :=
  h.handoutOver _

/-! ### Release, drain, undrain -/

theorem St.task_mem (s : St) (o i : Nat) (hi : i < (s.op o).tasks.length) : s.task o i ∈ (s.op o).tasks := by
  simp [St.task, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi]

theorem runningOn_pos {s : St} {o i c : Nat} (hr : (s.task o i).st = .running c) : 0 < s.runningOn o c := by
  have hi := s.lt_of_task o i (by rw [hr]; simp)
  exact List.countP_pos_iff.2 ⟨_, s.task_mem o i hi, by simp [runningC, hr]⟩

theorem drains_pos {cfg : Cfg} {s : St} {c : Nat} (h : Inv cfg s) (hd : drainingC (s.cpu c) = true) :
    1 ≤ s.drains := by
  have hc : c < s.cpus.length := by
    refine Classical.byContradiction fun hn => ?_
    rw [s.cpu_default c hn] at hd; cases hd
  rw [h.drainCount]
  have e : s.cpu c = s.cpus[c] := by
    simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc]
  exact List.countP_pos_iff.2 ⟨_, List.getElem_mem hc, by rw [← e]; exact hd⟩

theorem Inv.release {cfg : Cfg} {s : St} {c o : Nat} {sl : Slot} {ord : List Nat} (h : Inv cfg s)
    (hs : (s.cpu c).slot = some sl) (ho : sl.owner = o) (ha : (s.op o).phase = .alive)
    (hr0 : s.runningOn o c = 0) (hdy : ∀ i, (s.task o i).dying ≠ some c) :
    Inv cfg (Cpuq.withCpu s c {} (s.drains - (if sl.draining then 1 else 0)) ord) := by
  have hc := s.lt_of_slot c (by rw [hs]; simp)
  have hl : (s.cpu c).lock = some o := by
    have := h.ownerLock c sl hs (by rw [ho]; exact ha); rwa [ho] at this
  apply h.withCpu hc
  · intro o' e; cases e
  · intro sl' e; cases e
  · intro sl' e; cases e
  · intro g e; cases e
  · intro sl' e; cases e
  · intro o' hp; have := h.capBound o' hp; simp only [b2n, ownsC_empty, grantedC]; simp; omega
  · have hdr : drainingC (s.cpu c) = sl.draining := by simp [drainingC, hs]
    rw [hdr]; simp only [b2n, drainingC_empty]
    cases e : sl.draining
    · simp
    · have := drains_pos h (by rw [hdr, e]); simp; omega
  · intro o' i hon
    rcases h.pinned o' i c hon with ⟨_, e⟩ | ⟨_, e⟩
    · rw [hl] at e; cases e
      rcases hon with hon | hon
      · have := runningOn_pos hon; omega
      · exact absurd hon (hdy i)
    · rw [hl] at e; cases e

theorem Inv.setDraining {cfg : Cfg} {s : St} {c o : Nat} {b b' : Bool} {d : Nat} {ord : List Nat}
    (h : Inv cfg s) (hs : (s.cpu c).slot = some ⟨o, b⟩) (ha : (s.op o).phase = .alive)
    (hd : d + b2n b = s.drains + b2n b') :
    Inv cfg (Cpuq.withCpu s c { s.cpu c with slot := some ⟨o, b'⟩ } d ord) := by
  have hc := s.lt_of_slot c (by rw [hs]; simp)
  have hl : (s.cpu c).lock = some o := h.ownerLock c _ hs ha
  have own : ∀ o', ownsC o' { s.cpu c with slot := some ⟨o, b'⟩ } = ownsC o' (s.cpu c) := by
    intro o'; simp [ownsC, hs]
  apply h.withCpu hc
  · intro o' e; rw [own]; exact h.lockOwner c o' e
  · intro sl e _; cases e; exact hl
  · intro sl e; cases e; exact .inl ha
  · intro g e; exact h.grantFree c g e
  · intro sl e; cases e; exact h.kBound c ⟨o, b⟩ hs
  · intro o' hp; rw [own]; have := h.capBound o' hp
    have : grantedC o' { s.cpu c with slot := some ⟨o, b'⟩ } = grantedC o' (s.cpu c) := rfl
    rw [this]; omega
  · have : drainingC (s.cpu c) = b := by simp [drainingC, hs]
    rw [this]; exact hd
  · intro o' i hon; exact h.pinned o' i c hon

/-! ### An operation's phase changes -/

theorem Inv.order {cfg : Cfg} {s : St} (h : Inv cfg s) (x : List Nat) : Inv cfg { s with order := x } :=
  ⟨h.len, h.lockOwner, h.ownerLock, h.ownerPhase, h.grantFree, h.kBound, h.capBound, h.drainCount,
    h.dyingTimedOut, h.pinned⟩

theorem St.op_setPhase_ne (s : St) (o o' : Nat) (p : Phase) (e : o ≠ o') :
    ((s.setPhase o p).op o').phase = (s.op o').phase := by
  simp [St.setPhase, St.op_set, e]

theorem Inv.setPhase {cfg : Cfg} {s : St} {o : Nat} {p : Phase} (h : Inv cfg s) (ho : o < s.ops.length)
    (hlock : ∀ c, (s.cpu c).lock = some o → p = .alive)
    (hslot : ∀ c sl, (s.cpu c).slot = some sl → sl.owner = o →
      (p = .alive → (s.cpu c).lock = some o) ∧ (p = .alive ∨ p = .dead))
    (hgrant : ∀ c, (s.cpu c).grant = some o → p ≠ .waiting)
    (hcap : (p = .alive ∨ p = .stopped) → s.owned o + s.grants o ≤ (cfg.op o).cap)
    (hpin : ∀ i c, ((s.task o i).st = .running c ∨ (s.task o i).dying = some c) →
      (p = .alive ∧ (s.cpu c).lock = some o) ∨ (p = .dead ∧ (s.cpu c).lock = none)) :
    Inv cfg (s.setPhase o p) := by
  have ph := fun o' => St.phase_setPhase s o o' p ho
  refine
  { len := h.len, lockOwner := ?_, ownerLock := ?_, ownerPhase := ?_, grantFree := ?_,
    kBound := ?_, capBound := ?_, drainCount := h.drainCount, dyingTimedOut := ?_, pinned := ?_ }
  · intro c o' hl
    simp only [St.cpu_setPhase] at hl ⊢; rw [ph]
    have := h.lockOwner c o' hl
    by_cases e : o = o'
    · subst e; simp [hlock c hl, this.1]
    · simp [e, this]
  · intro sl c' hs ha
    simp only [St.cpu_setPhase] at hs ⊢; rw [ph] at ha
    by_cases e : o = c'.owner
    · simp [e] at ha; exact (hslot sl c' hs e.symm).1 ha ▸ (by rw [e])
    · simp [e] at ha; exact h.ownerLock sl c' hs ha
  · intro c sl hs
    simp only [St.cpu_setPhase] at hs; rw [ph]
    by_cases e : o = sl.owner
    · simp [e]; exact (hslot c sl hs e.symm).2
    · simp [e]; exact h.ownerPhase c sl hs
  · intro c g hg
    simp only [St.cpu_setPhase] at hg ⊢; rw [ph]
    refine ⟨(h.grantFree c g hg).1, ?_⟩
    by_cases e : o = g
    · subst e; simp [hgrant c hg]
    · simp [e, (h.grantFree c g hg).2]
  · intro c sl hs
    simp only [St.cpu_setPhase] at hs
    show List.countP _ ((s.setPhase o p).op sl.owner).tasks ≤ _
    rw [St.tasks_setPhase]; exact h.kBound c sl hs
  · intro o' hp
    rw [ph] at hp
    show (s.setPhase o p).owned o' + (s.setPhase o p).grants o' ≤ _
    have e1 : (s.setPhase o p).owned o' = s.owned o' := rfl
    have e2 : (s.setPhase o p).grants o' = s.grants o' := rfl
    rw [e1, e2]
    by_cases e : o = o'
    · subst e; simp at hp; exact hcap hp
    · simp [e] at hp; exact h.capBound o' hp
  · intro o' i hd; rw [St.task_setPhase] at hd ⊢; exact h.dyingTimedOut o' i hd
  · intro o' i c hon
    rw [St.task_setPhase] at hon; rw [ph]; simp only [St.cpu_setPhase]
    by_cases e : o = o'
    · subst e; simp; exact hpin i c hon
    · simp [e]; exact h.pinned o' i c hon

/-- An operation that has not started holds nothing and runs nothing. -/
theorem Inv.idle_of {cfg : Cfg} {s : St} {o : Nat} (h : Inv cfg s)
    (hp : (s.op o).phase ≠ .alive ∧ (s.op o).phase ≠ .dead) :
    (∀ c, (s.cpu c).lock ≠ some o) ∧ (∀ c sl, (s.cpu c).slot = some sl → sl.owner ≠ o) ∧
    (∀ i c, ¬((s.task o i).st = .running c ∨ (s.task o i).dying = some c)) := by
  refine ⟨fun c e => hp.1 (h.lockOwner c o e).2, fun c sl hs e => ?_, fun i c hon => ?_⟩
  · subst e; rcases h.ownerPhase c sl hs with x | x
    · exact hp.1 x
    · exact hp.2 x
  · rcases h.pinned o i c hon with ⟨x, _⟩ | ⟨x, _⟩
    · exact hp.1 x
    · exact hp.2 x

theorem countP_zero_owned {s : St} {o : Nat} (hs : ∀ c sl, (s.cpu c).slot = some sl → sl.owner ≠ o) :
    s.owned o = 0 := by
  apply countP_zero_of
  intro x hx
  obtain ⟨c, hc, rfl⟩ := List.getElem_of_mem hx
  have e : s.cpu c = s.cpus[c] := by
    simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc]
  cases w : ownsC o s.cpus[c]
  · rfl
  · obtain ⟨d, hd⟩ := (ownsC_iff _ _).1 w
    exact absurd rfl (hs c _ (by rw [e]; exact hd))

theorem countP_zero_grants {s : St} {o : Nat} (hs : ∀ c, (s.cpu c).grant ≠ some o) : s.grants o = 0 := by
  apply countP_zero_of
  intro x hx
  obtain ⟨c, hc, rfl⟩ := List.getElem_of_mem hx
  have e : s.cpu c = s.cpus[c] := by
    simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc]
  have := hs c; rw [e] at this
  simp [grantedC, this]

theorem Inv.arrive {cfg : Cfg} {s : St} {o : Nat} (h : Inv cfg s) (hw : (s.op o).phase = .waiting) :
    Inv cfg (s.setPhase o .alive) := by
  have ho := s.lt_of_phase o (by rw [hw]; decide)
  obtain ⟨hl, hs, hr⟩ := h.idle_of (o := o) (by rw [hw]; decide)
  apply h.setPhase ho
  · intro c e; exact absurd e (hl c)
  · intro c sl e eo; exact absurd eo (hs c sl e)
  · intro _ _; decide
  · intro _
    have g : ∀ c, (s.cpu c).grant ≠ some o := fun c e => (h.grantFree c o e).2 hw
    rw [countP_zero_owned hs, countP_zero_grants g]; exact Nat.zero_le _
  · intro i c e; exact absurd e (hr i c)

theorem Inv.cont {cfg : Cfg} {s : St} {o : Nat} (h : Inv cfg s) (hw : (s.op o).phase = .stopped) :
    Inv cfg (s.setPhase o .alive) := by
  have ho := s.lt_of_phase o (by rw [hw]; decide)
  obtain ⟨hl, hs, hr⟩ := h.idle_of (o := o) (by rw [hw]; decide)
  apply h.setPhase ho
  · intro c e; exact absurd e (hl c)
  · intro c sl e eo; exact absurd eo (hs c sl e)
  · intro _ _; decide
  · intro _; exact h.capBound o (.inr hw)
  · intro i c e; exact absurd e (hr i c)

theorem Inv.finish {cfg : Cfg} {s : St} {o : Nat} (h : Inv cfg s) (ha : (s.op o).phase = .alive)
    (hown : s.owned o = 0) (hidle : ∀ i c, ¬((s.task o i).st = .running c ∨ (s.task o i).dying = some c)) :
    Inv cfg (s.setPhase o .over) := by
  have ho := s.lt_of_phase o (by rw [ha]; decide)
  have hs : ∀ c sl, (s.cpu c).slot = some sl → sl.owner ≠ o := by
    intro c sl e eo
    have hc := s.lt_of_slot c (by rw [e]; simp)
    have : 0 < s.owned o := by
      have ec : s.cpu c = s.cpus[c] := by
        simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc]
      exact List.countP_pos_iff.2 ⟨_, List.getElem_mem hc, by rw [← ec]; exact ownsC_of_slot e eo⟩
    omega
  apply h.setPhase ho
  · intro c e
    have := (h.lockOwner c o e).1
    obtain ⟨d, hd⟩ := (ownsC_iff _ _).1 this
    exact absurd rfl (hs c _ hd)
  · intro c sl e eo; exact absurd eo (hs c sl e)
  · intro _ _; decide
  · intro x; simp at x
  · intro i c e; exact absurd e (hidle i c)

/-! ### A parent killed by SIGKILL -/

def dropLock (o : Nat) (x : Cpu) : Cpu := if x.lock == some o then { x with lock := none } else x

def crashed (s : St) (o : Nat) : St :=
  St.mk (s.cpus.map (dropLock o)) (s.setPhase o .dead).ops s.order s.drains (s.crashes - 1)
    s.poolLock s.marks s.tstp s.held s.halted s.zs

theorem crashed_cpu (s : St) (o c : Nat) : (crashed s o).cpu c = dropLock o (s.cpu c) := by
  simp only [St.cpu, crashed]
  exact getD_map _ _ _ _ _ (by simp [dropLock])

theorem crashed_op (s : St) (o o' : Nat) : (crashed s o).op o' = (s.setPhase o .dead).op o' := rfl
theorem crashed_task (s : St) (o o' i : Nat) : (crashed s o).task o' i = s.task o' i := by
  show (s.setPhase o .dead).task o' i = _; exact St.task_setPhase ..

@[simp] theorem dropLock_slot (o : Nat) (x : Cpu) : (dropLock o x).slot = x.slot := by
  unfold dropLock; split <;> rfl
@[simp] theorem dropLock_grant (o : Nat) (x : Cpu) : (dropLock o x).grant = x.grant := by
  unfold dropLock; split <;> rfl
theorem dropLock_lock (o : Nat) (x : Cpu) :
    (dropLock o x).lock = if x.lock = some o then none else x.lock := by
  unfold dropLock; by_cases e : x.lock = some o <;> simp [e]

theorem crashed_count (s : St) (o : Nat) (p : Cpu → Bool) (hp : ∀ x, p (dropLock o x) = p x) :
    (crashed s o).cpus.countP p = s.cpus.countP p := by
  show (s.cpus.map (dropLock o)).countP p = _
  rw [List.countP_map]; exact List.countP_congr (fun x _ => by simp [hp])

theorem Inv.crash {cfg : Cfg} {s : St} {o : Nat} (h : Inv cfg s)
    (hp : (s.op o).phase = .alive ∨ (s.op o).phase = .stopped) : Inv cfg (crashed s o) := by
  have ho := s.lt_of_phase o (by rcases hp with e | e <;> rw [e] <;> decide)
  have ph : ∀ o', ((crashed s o).op o').phase = if o = o' then .dead else (s.op o').phase := by
    intro o'; rw [crashed_op]; exact St.phase_setPhase s o o' _ ho
  have own : ∀ o' x, ownsC o' (dropLock o x) = ownsC o' x := by intro o' x; simp [ownsC]
  have gr : ∀ o' x, grantedC o' (dropLock o x) = grantedC o' x := by intro o' x; simp [grantedC]
  have dr : ∀ x, drainingC (dropLock o x) = drainingC x := by intro x; simp [drainingC]
  refine
  { len := by show (s.cpus.map _).length = _; rw [List.length_map]; exact h.len
    lockOwner := ?_, ownerLock := ?_, ownerPhase := ?_, grantFree := ?_, kBound := ?_,
    capBound := ?_, drainCount := ?_, dyingTimedOut := ?_, pinned := ?_ }
  · intro c o' hl
    rw [crashed_cpu, dropLock_lock] at hl; rw [crashed_cpu, own, ph]
    by_cases e : (s.cpu c).lock = some o
    · simp [e] at hl
    · simp only [e, ite_false] at hl
      have := h.lockOwner c o' hl
      have : o ≠ o' := by intro x; subst x; exact e hl
      simp only [this, ite_false]; exact ⟨(h.lockOwner c o' hl).1, (h.lockOwner c o' hl).2⟩
  · intro c sl hs ha
    rw [crashed_cpu, dropLock_slot] at hs; rw [ph] at ha; rw [crashed_cpu, dropLock_lock]
    by_cases e : o = sl.owner
    · simp [e] at ha
    · simp only [e, ite_false] at ha
      have l := h.ownerLock c sl hs ha
      have : (s.cpu c).lock ≠ some o := by rw [l]; intro x; cases x; exact e rfl
      rw [ite_eq_right this]; exact l
  · intro c sl hs
    rw [crashed_cpu, dropLock_slot] at hs; rw [ph]
    by_cases e : o = sl.owner
    · simp [e]
    · simp only [e, ite_false]; exact h.ownerPhase c sl hs
  · intro c g hg
    rw [crashed_cpu, dropLock_grant] at hg; rw [crashed_cpu, dropLock_lock, ph]
    have := h.grantFree c g hg
    refine ⟨by simp [this.1], ?_⟩
    by_cases e : o = g
    · simp [e]
    · simp [e, this.2]
  · intro c sl hs
    rw [crashed_cpu, dropLock_slot] at hs
    show List.countP _ ((crashed s o).op sl.owner).tasks ≤ _
    rw [crashed_op, St.tasks_setPhase]; exact h.kBound c sl hs
  · intro o' hp'
    rw [ph] at hp'
    by_cases e : o = o'
    · simp [e] at hp'
    · simp only [e, ite_false] at hp'
      show (crashed s o).cpus.countP _ + (crashed s o).cpus.countP _ ≤ _
      rw [crashed_count s o _ (own o'), crashed_count s o _ (gr o')]
      exact h.capBound o' hp'
  · show s.drains = _; rw [crashed_count s o _ dr]; exact h.drainCount
  · intro o' i hd; rw [crashed_task] at hd ⊢; exact h.dyingTimedOut o' i hd
  · intro o' i c hon
    rw [crashed_task] at hon; rw [ph, crashed_cpu, dropLock_lock]
    by_cases e : o = o'
    · subst e
      rcases h.pinned o i c hon with ⟨_, l⟩ | ⟨d, _⟩
      · right; simp [l]
      · rcases hp with x | x <;> rw [x] at d <;> cases d
    · simp only [e, ite_false]
      rcases h.pinned o' i c hon with ⟨a, l⟩ | ⟨d, l⟩
      · left; refine ⟨a, ?_⟩; have : some o' ≠ some o := by intro x; cases x; exact e rfl
        simp [l, this]
      · right; simp [d, l]

/-! ### `cpuq kill` and Ctrl-Z: release every slot, end or stop every task -/

def clearOf (o : Nat) (x : Cpu) : Cpu := if ownsC o x then {} else x

def retired (s : St) (o : Nat) (g : Task → Task) (p : Phase) : St :=
  St.mk (s.cpus.map (clearOf o)) (s.ops.set o { phase := p, tasks := (s.op o).tasks.map g }) s.order
    (s.drains - s.drainOf o) s.crashes s.poolLock s.marks s.tstp s.held s.halted s.zs

theorem retire_eq (s : St) (o : Nat) (g : Task → Task) (p : Phase) (ho : o < s.ops.length) :
    ((releaseAll s o).mapTasks o g).setPhase o p = retired s o g p := by
  simp only [St.setPhase, St.mapTasks, releaseAll, retired]
  have e : ∀ v : Op, ((s.ops.set o v).getD o {}) = v := by
    intro v; rw [getD_set]; simp [ho]
  simp only [St.op, e, List.set_set]
  rfl

theorem countP_split {α} (p q : α → Bool) (l : List α) :
    l.countP (fun x => p x && !q x) + l.countP (fun x => q x && p x) = l.countP p := by
  induction l with
  | nil => rfl
  | cons x l ih =>
    simp only [List.countP_cons]
    cases p x <;> cases q x <;> simp <;> omega

/-- What a task becomes when its operation is killed or stopped. -/
structure Retires (g : Task → Task) : Prop where
  dying : ∀ t, (g t).dying = none
  notRunning : ∀ t c, (g t).st ≠ .running c
  default : g { st := .gone } = { st := .gone }

theorem killTask_retires : Retires killTask where
  dying t := by unfold killTask; split <;> rfl
  notRunning t c := by unfold killTask; split <;> simp_all
  default := rfl

theorem stopTask_retires (cfg : Cfg) (o : Nat) : Retires (stopTask cfg o) where
  dying t := by unfold stopTask; split <;> rfl
  notRunning t c := by
    unfold stopTask afterFail; split
    · simp
    · split <;> simp
    · simp_all
  default := rfl

theorem Inv.retired {cfg : Cfg} {s : St} {o : Nat} {g : Task → Task} {p : Phase} (h : Inv cfg s)
    (ha : (s.op o).phase = .alive) (hg : Retires g) (hp : p = .over ∨ p = .stopped) :
    Inv cfg (Cpuq.retired s o g p) := by
  have ho := s.lt_of_phase o (by rw [ha]; decide)
  have hcpu : ∀ c, (Cpuq.retired s o g p).cpu c = clearOf o (s.cpu c) := by
    intro c; simp only [St.cpu, Cpuq.retired]; exact getD_map _ _ _ _ _ (by simp [clearOf, ownsC_empty])
  have hop : ∀ o', (Cpuq.retired s o g p).op o' =
      if o = o' then { phase := p, tasks := (s.op o).tasks.map g } else s.op o' := by
    intro o'; simp only [St.op, Cpuq.retired, getD_set, ho, and_true]
  have ph : ∀ o', ((Cpuq.retired s o g p).op o').phase = if o = o' then p else (s.op o').phase := by
    intro o'; rw [hop]; split <;> rfl
  have htask : ∀ o' i, (Cpuq.retired s o g p).task o' i = if o = o' then g (s.task o i) else s.task o' i := by
    intro o' i; simp only [St.task, hop]
    split
    · rename_i e; subst e; exact getD_map _ _ _ _ _ hg.default
    · rfl
  have hrun : ∀ o' c, o ≠ o' → (Cpuq.retired s o g p).runningOn o' c = s.runningOn o' c := by
    intro o' c e; simp only [St.runningOn, hop, e, ite_false]
  -- A cleared CPU was `o`'s and held by it: no grant, lock `o`.
  have hcl : ∀ c, ownsC o (s.cpu c) = true → (s.cpu c).lock = some o ∧ (s.cpu c).grant = none := by
    intro c w
    obtain ⟨d, hd⟩ := (ownsC_iff _ _).1 w
    have l := h.ownerLock c _ hd ha
    refine ⟨l, ?_⟩
    cases e : (s.cpu c).grant with
    | none => rfl
    | some g' => have := (h.grantFree c g' e).1; rw [l] at this; cases this
  have notp : p ≠ .waiting := by rcases hp with e | e <;> rw [e] <;> decide
  have memc : ∀ x ∈ s.cpus, ∃ c, s.cpu c = x := by
    intro x hx
    obtain ⟨c, hc, rfl⟩ := List.getElem_of_mem hx
    exact ⟨c, by simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc]⟩
  refine
  { len := by show (s.cpus.map _).length = _; rw [List.length_map]; exact h.len
    lockOwner := ?_, ownerLock := ?_, ownerPhase := ?_, grantFree := ?_, kBound := ?_,
    capBound := ?_, drainCount := ?_, dyingTimedOut := ?_, pinned := ?_ }
  · intro c o' hl
    rw [hcpu] at hl ⊢; rw [ph]; unfold clearOf at hl ⊢
    split at hl
    · cases hl
    · rename_i w
      have := h.lockOwner c o' hl
      have e : o ≠ o' := by intro x; subst x; rw [this.1] at w; exact w rfl
      rw [ite_eq_right w]; simp only [e, ite_false]; exact this
  · intro c sl hs hal
    rw [hcpu] at hs ⊢; rw [ph] at hal; unfold clearOf at hs ⊢
    split at hs
    · cases hs
    · rename_i w
      have e : o ≠ sl.owner := by intro x; exact w (ownsC_of_slot hs x.symm)
      rw [ite_eq_right w]; simp only [e, ite_false] at hal; exact h.ownerLock c sl hs hal
  · intro c sl hs
    rw [hcpu] at hs; rw [ph]; unfold clearOf at hs
    split at hs
    · cases hs
    · rename_i w
      have e : o ≠ sl.owner := by intro x; exact w (ownsC_of_slot hs x.symm)
      simp only [e, ite_false]; exact h.ownerPhase c sl hs
  · intro c g' hgr
    rw [hcpu] at hgr ⊢; rw [ph]; unfold clearOf at hgr ⊢
    split at hgr
    · cases hgr
    · rename_i w
      rw [ite_eq_right w]
      refine ⟨(h.grantFree c g' hgr).1, ?_⟩
      by_cases e : o = g'
      · simp [e] at notp ⊢; exact notp
      · simp only [e, ite_false]; exact (h.grantFree c g' hgr).2
  · intro c sl hs
    rw [hcpu] at hs; unfold clearOf at hs
    split at hs
    · cases hs
    · rename_i w
      have e : o ≠ sl.owner := by intro x; exact w (ownsC_of_slot hs x.symm)
      rw [hrun _ _ e]; exact h.kBound c sl hs
  · intro o' hp'
    rw [ph] at hp'
    show (s.cpus.map (clearOf o)).countP _ + (s.cpus.map (clearOf o)).countP _ ≤ _
    rw [List.countP_map, List.countP_map]
    have hgr : (s.cpus.countP (grantedC o' ∘ clearOf o)) = s.grants o' := by
      apply List.countP_congr
      intro x hx
      obtain ⟨c, rfl⟩ := memc x hx
      simp only [Function.comp, clearOf]
      split
      · rename_i w; simp [grantedC, (hcl c w).2]
      · exact Iff.rfl
    rw [hgr]
    by_cases e : o = o'
    · subst e
      have z : s.cpus.countP (ownsC o ∘ clearOf o) = 0 := by
        apply countP_zero_of; intro x _
        simp only [Function.comp, clearOf]; split
        · exact ownsC_empty o
        · rename_i w; simpa using w
      rw [z]; have := h.capBound o (.inl ha); omega
    · simp only [e, ite_false] at hp'
      have : s.cpus.countP (ownsC o' ∘ clearOf o) = s.owned o' := by
        apply List.countP_congr
        intro x _
        simp only [Function.comp, clearOf]
        split
        · rename_i w
          obtain ⟨d, hd⟩ := (ownsC_iff _ _).1 w
          simp only [ownsC_empty, Bool.false_eq_true, false_iff]
          intro w'; obtain ⟨d', hd'⟩ := (ownsC_iff _ _).1 w'; rw [hd] at hd'; cases hd'; exact e rfl
        · exact Iff.rfl
      rw [this]; exact h.capBound o' hp'
  · show s.drains - s.drainOf o = (s.cpus.map (clearOf o)).countP drainingC
    rw [List.countP_map]
    have hsp := countP_split drainingC (ownsC o) s.cpus
    have : s.cpus.countP (drainingC ∘ clearOf o) = s.cpus.countP (fun x => drainingC x && !ownsC o x) := by
      apply List.countP_congr; intro x _
      simp only [Function.comp, clearOf]
      cases w : ownsC o x <;> simp [drainingC_empty]
    rw [this, h.drainCount]; simp only [St.drainOf] at *
    omega
  · intro o' i hd
    rw [htask] at hd ⊢
    split at hd
    · exact absurd (hg.dying _) hd
    · rename_i e; rw [ite_eq_right e]; exact h.dyingTimedOut o' i hd
  · intro o' i c hon
    rw [htask] at hon; rw [ph, hcpu]
    split at hon
    · rcases hon with x | x
      · exact absurd x (hg.notRunning _ _)
      · rw [hg.dying] at x; cases x
    · rename_i e
      simp only [e, ite_false]
      unfold clearOf
      rcases h.pinned o' i c hon with ⟨a, l⟩ | ⟨d, l⟩
      · left; refine ⟨a, ?_⟩
        have w : ownsC o (s.cpu c) = false := by
          cases w : ownsC o (s.cpu c)
          · rfl
          · have := (hcl c w).1; rw [l] at this; cases this; exact absurd rfl e
        rw [w]; exact l
      · right; refine ⟨d, ?_⟩; split
        · rfl
        · exact l

/-! ### Every step keeps the invariant -/

theorem all_task {s : St} {o : Nat} {P : Task → Bool} (ha : (s.op o).tasks.all P = true)
    (hd : P { st := .gone } = true) (i : Nat) : P (s.task o i) = true := by
  by_cases hi : i < (s.op o).tasks.length
  · exact List.all_eq_true.1 ha _ (s.task_mem o i hi)
  · rw [s.task_default o i hi]; exact hd

theorem firstPending_spec {s : St} {o i : Nat} (e : firstPending s o = some i) :
    (s.task o i).st = .pending := by
  unfold firstPending at e
  have := List.find?_some e
  simpa [pendingT] using this

theorem firstFree_spec {cfg : Cfg} {s : St} {c : Nat} (e : firstFree cfg s = some c) :
    freeC cfg s (s.cpu c) = true ∧ c < s.cpus.length := by
  unfold firstFree at e
  have h1 := List.find?_some e
  exact ⟨by simpa using h1, List.mem_range.1 (List.mem_of_find?_eq_some e)⟩

theorem dying_none_of_running {cfg : Cfg} {s : St} {o i c : Nat} (h : Inv cfg s)
    (hr : (s.task o i).st = .running c) : (s.task o i).dying = none := by
  cases e : (s.task o i).dying with
  | none => rfl
  | some _ => have := h.dyingTimedOut o i (by rw [e]; simp); rw [hr] at this; cases this

theorem dying_none_of_pending {cfg : Cfg} {s : St} {o i : Nat} (h : Inv cfg s)
    (hr : (s.task o i).st = .pending) : (s.task o i).dying = none := by
  cases e : (s.task o i).dying with
  | none => rfl
  | some _ => have := h.dyingTimedOut o i (by rw [e]; simp); rw [hr] at this; cases this

theorem afterFail_dying (cfg : Cfg) (o : Nat) (t : Task) : (afterFail cfg o t).dying = t.dying := by
  unfold afterFail; split <;> rfl
theorem afterOk_dying (cfg : Cfg) (o : Nat) (t : Task) : (afterOk cfg o t).dying = t.dying := by
  unfold afterOk; split <;> rfl
theorem afterFail_st (cfg : Cfg) (o : Nat) (t : Task) (c : Nat) : (afterFail cfg o t).st ≠ .running c := by
  unfold afterFail; split <;> simp
theorem afterOk_st (cfg : Cfg) (o : Nat) (t : Task) (c : Nat) : (afterOk cfg o t).st ≠ .running c := by
  unfold afterOk; split <;> simp

/-- A task that stops running and has no dying attempt. -/
theorem Inv.settle {cfg : Cfg} {s : St} {o i : Nat} {t : Task} (h : Inv cfg s)
    (ho : o < s.ops.length) (hi : i < (s.op o).tasks.length)
    (hd : t.dying = none) (hr : ∀ c, t.st ≠ .running c) : Inv cfg (s.setTask o i t) := by
  apply h.setTask ho hi
  · intro x; exact absurd hd x
  · intro c x; rcases x with x | x
    · exact absurd x (hr c)
    · rw [hd] at x; cases x
  · intro c _ x; simp [runningC, hr c] at x

theorem Inv.tryOnce {cfg : Cfg} {s : St} {o : Nat} (hs : Safe cfg.rules) (h : Inv cfg s)
    (ha : (s.op o).phase = .alive) : Inv cfg (Cpuq.tryOnce cfg s o) := by
  unfold Cpuq.tryOnce
  by_cases g : tryCond cfg s o = true
  · rw [ite_eq_left g]
    simp only [tryCond, Bool.and_eq_true, decide_eq_true_eq] at g
    cases hf : firstFree cfg s with
    | none => exact h
    | some c =>
      obtain ⟨hfree, hc⟩ := firstFree_spec hf
      apply h.takeTok hs.reclaim ha hc (freeC_lock hfree)
      have hroom : s.owned o + s.grants o < (cfg.op o).cap := demand_room g.1.2
      split <;> omega
  · rw [ite_eq_right g]; exact h

theorem Inv.step {cfg : Cfg} {s s' : St} {a : Act} (hs : Safe cfg.rules) (h : Inv cfg s)
    (e : step cfg s a = some s') : Inv cfg s' := by
  cases a with
  | arrive o =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i hw; cases e
      exact ((h.arrive (by simpa using hw)).order _).handout
    · cases e
  | exit o i ok =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i c hr
      have hi := s.lt_of_task o i (by rw [hr]; simp)
      have ho := s.lt_of_task_op o i (by rw [hr]; simp)
      have hd := dying_none_of_running h hr
      split at e
      · rename_i ha
        have ha : (s.op o).phase = .alive := by simpa using ha
        cases e
        unfold reap
        apply Inv.tryOnce hs _ (by rw [St.phase_setTask]; exact ha)
        apply h.settle ho hi
        · split
          · rw [afterOk_dying, hd]
          · rw [afterFail_dying, hd]
        · intro c'; split
          · exact afterOk_st _ _ _ _
          · exact afterFail_st _ _ _ _
      · split at e
        · cases e
          exact h.settle ho hi hd (by intro c'; simp)
        · cases e
    · cases e
  | timeout o i =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i c hr
      split at e
      · rename_i g
        simp only [Bool.and_eq_true, beq_iff_eq] at g
        simp only [hs.retryAtReap, ite_true] at e
        cases e
        have hi := s.lt_of_task o i (by rw [hr]; simp)
        have ho := s.lt_of_task_op o i (by rw [hr]; simp)
        apply h.setTask ho hi
        · intro _; rfl
        · intro c' x
          rcases x with x | x
          · cases x
          · simp at x; subst x; exact h.pinned o i c (.inl hr)
        · intro c' _ x; simp [runningC] at x
      · cases e
    · cases e
  | gone o i =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i c hdy
      cases e
      have ht := h.dyingTimedOut o i (by rw [hdy]; simp)
      have hi := s.lt_of_task o i (by rw [ht]; simp)
      have ho := s.lt_of_task_op o i (by rw [ht]; simp)
      apply h.settle ho hi
      · split
        · rw [afterFail_dying]
        · rfl
      · intro c'; split
        · exact afterFail_st _ _ _ _
        · show (s.task o i).st ≠ _; rw [ht]; simp
    · cases e
  | refill o c =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq, Bool.not_eq_true'] at g
      obtain ⟨⟨⟨⟨ha, hsl⟩, hk⟩, -⟩, -⟩ := g
      split at e
      · rename_i i hp
        cases e
        have hpe := firstPending_spec hp
        have hi := s.lt_of_task o i (by rw [hpe]; simp)
        have ho := s.lt_of_task_op o i (by rw [hpe]; simp)
        have hd := dying_none_of_pending h hpe
        have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
        apply h.setTask ho hi
        · intro x; exact absurd hd x
        · intro c' x
          rcases x with x | x
          · simp at x; subst x; exact .inl ⟨ha', h.ownerLock _ _ hsl ha'⟩
          · rw [hd] at x; cases x
        · intro c' _ x _
          simp [runningC] at x; subst x; exact hk
      · cases e
    · cases e
  | release o c =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i sl hsl
      split at e
      · rename_i g
        simp only [Bool.and_eq_true, beq_iff_eq, Bool.or_eq_true, Bool.not_eq_true'] at g
        obtain ⟨⟨⟨⟨⟨ha, hown⟩, hr0⟩, hdy⟩, -⟩, -⟩ := g
        cases e
        have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
        apply Inv.handout
        apply h.release hsl hown ha' hr0
        intro i
        rcases hdy with x | x
        · simp [hs.releaseWaitsDying] at x
        · have := all_task x (by simp) i; simpa using this
      · cases e
    · cases e
  | handout =>
    simp only [Cpuq.step] at e
    split at e
    · cases e; exact h.handout
    · cases e
  | accept o c =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true, beq_iff_eq, Option.isNone_iff_eq_none] at g
      obtain ⟨⟨ha, hg⟩, hl⟩ := g
      cases e
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
      have hc := s.lt_of_grant c (by rw [hg]; simp)
      apply h.takeTok hs.reclaim ha' hc hl
      simp only [hg, ite_true, Nat.add_zero]; exact h.capBound o (.inl ha')
    · cases e
  | drain o c =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      cases e
      unfold canDrain at g
      simp only [Bool.and_eq_true, beq_iff_eq] at g
      obtain ⟨⟨ha, hsl⟩, -⟩ := g
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
      exact h.setDraining (b := false) (b' := true) hsl ha' (by simp [b2n])
    · cases e
  | undrain o c =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at g
      obtain ⟨⟨⟨-, ha⟩, hsl⟩, hgt⟩ := g
      cases e
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
      exact h.setDraining (b := true) (b' := false) hsl ha' (by simp [b2n]; omega)
    · cases e
  | consolidate o i d =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i c hr
      split at e
      · rename_i g
        simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at g
        obtain ⟨⟨⟨ha, -⟩, hsd⟩, hk⟩ := g
        cases e
        have hi := s.lt_of_task o i (by rw [hr]; simp)
        have ho := s.lt_of_task_op o i (by rw [hr]; simp)
        have hd := dying_none_of_running h hr
        have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
        apply h.setTask ho hi
        · intro x; exact absurd hd x
        · intro c' x
          rcases x with x | x
          · simp at x; subst x; exact .inl ⟨ha', h.ownerLock _ _ hsd ha'⟩
          · rw [hd] at x; cases x
        · intro c' _ x _
          simp [runningC] at x; subst x; exact hk
      · cases e
    · cases e
  | kill o =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true] at g
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using g.2
      cases e
      have ho := s.lt_of_phase o (by rw [ha']; decide)
      rw [retire_eq _ _ _ _ ho]
      exact (h.retired ha' killTask_retires (.inl rfl)).handout
    · cases e
  | crash o =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at g
      cases e
      exact h.crash g.2
    · cases e
  | stop o =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true] at g
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using g.2
      cases e
      have ho := s.lt_of_phase o (by rw [ha']; decide)
      rw [retire_eq _ _ _ _ ho]
      exact (h.retired ha' (stopTask_retires cfg o) (.inr rfl)).handout
    · cases e
  | cont o =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g; cases e; exact h.cont (by simpa using g)
    · cases e
  | finish o =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true, beq_iff_eq] at g
      obtain ⟨⟨ha, hown⟩, hall⟩ := g
      cases e
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
      apply Inv.handout
      apply h.finish ha' hown
      intro i c x
      have := all_task hall (by decide) i
      simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at this
      rcases x with x | x
      · rw [x] at this; simp at this
      · rw [x] at this; simp at this
    · cases e
  | enter o | mark o | tstp o | halt o => simp [Cpuq.step] at e

/-! ### Locks and signals -/

/-- Two states that agree on everything the pool's rules read but the pool lock, the drain mark
and the signals. -/
def Same (s t : St) : Prop := t.cpus = s.cpus ∧ t.ops = s.ops ∧ t.order = s.order ∧ t.drains = s.drains

theorem Same.rfl' (s : St) : Same s s := ⟨rfl, rfl, rfl, rfl⟩

theorem Inv.congr {cfg : Cfg} {s t : St} (h : Inv cfg s) (e : Same s t) : Inv cfg t := by
  obtain ⟨hc, ho, -, hd⟩ := e
  cases s; cases t
  simp only at hc ho hd; subst hc ho hd
  exact ⟨h.len, h.lockOwner, h.ownerLock, h.ownerPhase, h.grantFree, h.kBound, h.capBound,
    h.drainCount, h.dyingTimedOut, h.pinned⟩

/-- What `move` adds to `step` touches only the pool lock, the drain mark and the signals. -/
theorem move_cases {cfg : Cfg} {s s' : St} {a : Act} (e : move cfg s a = some s') :
    Same s s' ∨ ∃ b t, step cfg s b = some t ∧ Same t s' := by
  have viaMap : ∀ (b : Act) (f : St → St), (∀ t, Same t (f t)) →
      (step cfg s b).map f = some s' → ∃ b t, step cfg s b = some t ∧ Same t s' := by
    intro b f hf e
    obtain ⟨t, ht, rfl⟩ := Option.map_eq_some_iff.1 e
    exact ⟨b, t, ht, hf t⟩
  unfold move at e
  split at e
  · cases e
  · split at e
    · split at e
      · cases e
      · exact .inr ⟨_, _, e, Same.rfl' _⟩
    · split at e
      · cases e; exact .inl ⟨rfl, rfl, rfl, rfl⟩
      · cases e
    · split at e
      · exact .inr (viaMap _ _ (fun _ => by exact ⟨rfl, rfl, rfl, rfl⟩) e)
      · cases e
    · exact .inr (viaMap _ _ (fun _ => by exact ⟨rfl, rfl, rfl, rfl⟩) e)
    · exact .inr (viaMap _ _ (fun _ => by exact ⟨rfl, rfl, rfl, rfl⟩) e)
    · exact .inr (viaMap _ _ (fun _ => by exact ⟨rfl, rfl, rfl, rfl⟩) e)
    · split at e
      · cases e; exact .inl ⟨rfl, rfl, rfl, rfl⟩
      · cases e
    · split at e
      · exact .inr (viaMap _ _ (fun _ => by exact ⟨rfl, rfl, rfl, rfl⟩) e)
      · cases e
    · split at e
      · split at e
        · exact .inr ⟨_, _, e, Same.rfl' _⟩
        · cases e; exact .inl ⟨rfl, rfl, rfl, rfl⟩
      · cases e
    · split at e
      · split at e
        · exact .inr (viaMap _ _ (fun _ => by exact ⟨rfl, rfl, rfl, rfl⟩) e)
        · cases e; exact .inl ⟨rfl, rfl, rfl, rfl⟩
      · cases e
    · exact .inr ⟨_, _, e, Same.rfl' _⟩

theorem Inv.move {cfg : Cfg} {s s' : St} {a : Act} (hs : Safe cfg.rules) (h : Inv cfg s)
    (e : move cfg s a = some s') : Inv cfg s' := by
  rcases move_cases e with x | ⟨b, t, hb, x⟩
  · exact h.congr x
  · exact (h.step hs hb).congr x

/-! ### The initial state, and every state reached -/

theorem Inv.init (cfg : Cfg) : Inv cfg (Cpuq.init cfg) := by
  have hcpu : ∀ c, (Cpuq.init cfg).cpu c = {} := by
    intro c; simp only [St.cpu, Cpuq.init, List.getD_eq_getElem?_getD, List.getElem?_replicate]
    split <;> rfl
  have hop : ∀ o, (Cpuq.init cfg).op o = {} ∨ (Cpuq.init cfg).op o =
      { phase := .waiting, tasks := List.replicate (cfg.op o).tasks {} } := by
    intro o
    simp only [St.op, Cpuq.init, Cfg.op, List.getD_eq_getElem?_getD, List.getElem?_map]
    cases cfg.ops[o]? <;> simp
  have htask : ∀ o i, (Cpuq.init cfg).task o i = {} ∨ (Cpuq.init cfg).task o i = { st := .gone } := by
    intro o i
    simp only [St.task]
    rcases hop o with e | e <;> rw [e]
    · right; rfl
    · simp only [List.getD_eq_getElem?_getD, List.getElem?_replicate]; split
      · left; rfl
      · right; rfl
  refine
  { len := by simp [Cpuq.init]
    lockOwner := ?_, ownerLock := ?_, ownerPhase := ?_, grantFree := ?_, kBound := ?_,
    capBound := ?_, drainCount := ?_, dyingTimedOut := ?_, pinned := ?_ }
  · intro c o e; rw [hcpu] at e; cases e
  · intro c sl e; rw [hcpu] at e; cases e
  · intro c sl e; rw [hcpu] at e; cases e
  · intro c g e; rw [hcpu] at e; cases e
  · intro c sl e; rw [hcpu] at e; cases e
  · intro o hp; rcases hop o with e | e <;> rw [e] at hp <;> simp at hp
  · show 0 = (List.replicate cfg.cpus ({} : Cpu)).countP drainingC
    simp [List.countP_replicate, drainingC_empty]
  · intro o i x; rcases htask o i with e | e <;> rw [e] at x ⊢ <;> simp at x
  · intro o i c x; rcases htask o i with e | e <;> rw [e] at x <;> simp at x

/-- The states the protocol can reach from its start. -/
inductive Reach (cfg : Cfg) : St → Prop where
  | init : Reach cfg (Cpuq.init cfg)
  | step {s s' : St} (a : Act) : Reach cfg s → move cfg s a = some s' → Reach cfg s'

theorem Reach.inv {cfg : Cfg} {s : St} (hs : Safe cfg.rules) (r : Reach cfg s) : Inv cfg s := by
  induction r with
  | init => exact Inv.init cfg
  | step a _ e ih => exact ih.move hs e

/-! ### The guarantees, in every reachable state -/

section
variable {cfg : Cfg} {s : St} (hs : Safe cfg.rules) (r : Reach cfg s)
include hs r

/-- S1: each token is held by at most one operation (its flock), that operation is alive, and the
token's record names it; a granted token is held by no one. -/
theorem one_holder (c o : Nat) (hl : (s.cpu c).lock = some o) :
    (s.op o).phase = .alive ∧ ∃ d, (s.cpu c).slot = some ⟨o, d⟩ ∧ (s.cpu c).grant = none := by
  have h := r.inv hs
  obtain ⟨w, ha⟩ := h.lockOwner c o hl
  obtain ⟨d, hd⟩ := (ownsC_iff _ _).1 w
  refine ⟨ha, d, hd, ?_⟩
  cases e : (s.cpu c).grant with
  | none => rfl
  | some g => have := (h.grantFree c g e).1; rw [hl] at this; cases this

/-- S2: never more CPUs held than the pool. -/
theorem pool_bound : s.cpus.countP (fun x => x.lock.isSome) ≤ cfg.cpus := by
  rw [← (r.inv hs).len]; exact List.countP_le_length

/-- S3: an alive (or stopped) operation never holds more than C slots, grants included. -/
theorem cap_bound (o : Nat) (hp : (s.op o).phase = .alive ∨ (s.op o).phase = .stopped) :
    s.owned o + s.grants o ≤ (cfg.op o).cap := (r.inv hs).capBound o hp

/-- S4: never more than K processes in a slot. -/
theorem k_bound (c : Nat) (sl : Slot) (e : (s.cpu c).slot = some sl) :
    s.runningOn sl.owner c ≤ (cfg.op sl.owner).K := (r.inv hs).kBound c sl e

/-- S5: no task runs twice at once: an attempt still dying from its timeout means the task is
not running again. -/
theorem no_double (o i c : Nat) (e : (s.task o i).dying ≠ none) : (s.task o i).st ≠ .running c := by
  rw [(r.inv hs).dyingTimedOut o i e]; simp

/-- S1': a CPU is never shared: every process on CPU c belongs to the operation holding c, or to
a dead operation while no one holds c (its next taker kills it first). -/
theorem not_shared (o i c : Nat) (hon : (s.task o i).st = .running c ∨ (s.task o i).dying = some c) :
    ((s.op o).phase = .alive ∧ (s.cpu c).lock = some o) ∨
    ((s.op o).phase = .dead ∧ (s.cpu c).lock = none) := (r.inv hs).pinned o i c hon

/-- The drain count is the number of draining slots. -/
theorem drain_count : s.drains = s.cpus.countP drainingC := (r.inv hs).drainCount

end

/-- S8: a hand-out grant goes only to the first in line, or, while a `cpuq drain` is in the
line, to the first drain. -/
theorem grantOne_head (cfg : Cfg) (s : St) (c c' g : Nat)
    (e : ((Cpuq.grantOne cfg s c).cpu c').grant = some g) :
    (s.cpu c').grant = some g ∨ target cfg s = some g := by
  unfold Cpuq.grantOne at e
  split at e
  · split at e
    · rename_i h hh
      rw [St.cpu_setCpu] at e
      split at e
      · rename_i x; obtain ⟨rfl, -⟩ := x; simp at e; subst e; exact .inr hh
      · exact .inl e
    · exact .inl e
  · exact .inl e

end Cpuq
