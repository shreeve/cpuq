/-
Liveness of `cpuq drain`, proved in general: under weak fairness, once no more operations
arrive or crash, the first drain in ticket order is given every CPU of the pool
(`drain_served`). With `lock_released` (no critical section waits forever), two drains can
neither deadlock on their locks nor starve each other in the line: the first is served, and
when it ends, the next is first.

Runs and weak fairness are defined here (`Run`, `Run.Fair`), as the search reads them
(`Explore.fairKey`): every enabled step class is weakly fair, a task's exit being one class
whether it passes or fails (A-term).

The proof: every CPU has a rank, its distance from the drain d (held by d 0, granted to d 1,
free 2, being emptied for d 3, kept by another 4, granted to another 5). No step raises a CPU's
rank; while a CPU is being emptied, the processes on it only leave. In every state some fair
step lowers the rank of each CPU not yet d's, and stays enabled until it is taken or the rank
falls: d accepts a grant, a pass grants a free CPU to d, another operation accepts its grant
or empties its CPU for the drain, a process on a CPU being emptied ends or moves, and an
empty CPU being emptied is given back. A CPU d holds stays d's. So every CPU ends up d's.

Scope of the proof: no Ctrl-Z (`Cfg.stops` off) and no `cpuq kill` (`Cfg.kills` off) in the
run; timeouts and retries may be on; crashes and arrivals may happen before the time the
theorem starts from. The search covers Ctrl-Z, kills and drains together at small sizes.
-/
import CpuqModel.Locks
import CpuqModel.Explore

namespace Cpuq

attribute [-simp] List.getD_eq_getElem?_getD

/-! ### Phases, precisely -/

/-- How a step changes an operation's phase: not at all, or by one of its own steps. -/
theorem step_phase_new {cfg : Cfg} {s t : St} {a : Act} (e : step cfg s a = some t) (p : Nat) :
    (t.op p).phase = (s.op p).phase ∨
    (a = .arrive p ∧ (t.op p).phase = .alive) ∨ (a = .kill p ∧ (t.op p).phase = .over) ∨
    (a = .crash p ∧ (t.op p).phase = .dead) ∨ (a = .stop p ∧ (t.op p).phase = .stopped) ∨
    (a = .cont p ∧ (t.op p).phase = .alive) ∨ (a = .finish p ∧ (t.op p).phase = .over) := by
  have keepTask : ∀ (u : St) o i (x : Task), ((u.setTask o i x).op p).phase = (u.op p).phase :=
    fun u o i x => St.phase_setTask u o i p x
  have setPh : ∀ (u : St) o (ph : Phase), o < u.ops.length →
      ((u.setPhase o ph).op p).phase = if o = p then ph else (u.op p).phase :=
    fun u o ph h => St.phase_setPhase u o p ph h
  cases a with
  | arrive o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i hw; cases e
      have ho : o < s.ops.length := s.lt_of_phase o (by simp at hw; rw [hw]; decide)
      have key : ((handout cfg { s.setPhase o .alive with order := s.order ++ [o] }).op p).phase =
          if o = p then .alive else (s.op p).phase := by
        rw [phase_of_ops (handout_order_ops cfg _).2]; exact setPh _ _ _ ho
      rw [key]
      by_cases eo : o = p
      · subst eo; simp
      · simp [eo]
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
      · subst eo; simp
      · simp [eo]
    · cases e
  | crash o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at g
      have ho := s.lt_of_phase o (by rcases g.2 with x | x <;> rw [x] <;> decide)
      have key : (({ s.setPhase o .dead with
          cpus := s.cpus.map (fun x => if x.lock == some o then { x with lock := none } else x)
          crashes := s.crashes - 1 } : St).op p).phase =
          if o = p then .dead else (s.op p).phase := setPh _ _ _ ho
      rw [key]
      by_cases eo : o = p
      · subst eo; simp
      · simp [eo]
    · cases e
  | stop o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      have ha : (s.op o).phase = .alive := by simp [St.isAlive] at g; exact g.2
      have ho := s.lt_of_phase o (by rw [ha]; decide)
      rw [phase_of_ops (handout_order_ops cfg _).2, retire_eq _ _ _ _ ho, retired_phase _ _ _ _ _ ho]
      by_cases eo : o = p
      · subst eo; simp
      · simp [eo]
    · cases e
  | cont o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      have ho := s.lt_of_phase o (by simp at g; rw [g]; decide)
      rw [setPh _ _ _ ho]
      by_cases eo : o = p
      · subst eo; simp
      · simp [eo]
    · cases e
  | finish o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e
      have ho := s.lt_of_phase o (by simp [St.isAlive] at g; rw [g.1.1]; decide)
      rw [phase_of_ops (handout_order_ops cfg _).2, setPh _ _ _ ho]
      by_cases eo : o = p
      · subst eo; simp
      · simp [eo]
    · cases e
  | enter o | mark o | tstp o | halt o => simp [Cpuq.step] at e

/-! ### Without Ctrl-Z, nothing is ever stopped -/

theorem clrBit_zero (o : Nat) : clrBit 0 o = 0 := by simp [clrBit]

/-- With `Cfg.stops` off: no Ctrl-Z is pending, no SIGCONT is owed, nothing is stopped. -/
def NoStops (s : St) : Prop := s.tstp = 0 ∧ s.held = 0 ∧ ∀ o, (s.op o).phase ≠ .stopped

theorem NoStops.move {cfg : Cfg} {s t : St} {a : Act} (hc : cfg.stops = false) (h : NoStops s)
    (e : move cfg s a = some t) : NoStops t := by
  obtain ⟨h1, h2, h3⟩ := h
  have viaStep : ∀ {b u}, step cfg s b = some u → (∀ p, b ≠ .stop p) →
      u.tstp = 0 ∧ u.held = 0 ∧ ∀ o, (u.op o).phase ≠ .stopped := by
    intro b u eb hb
    have ex := step_extras eb
    simp only [extras, Prod.mk.injEq] at ex
    refine ⟨by rw [ex.2.2.1, h1], by rw [ex.2.2.2.1, h2], fun o => ?_⟩
    rcases step_phase_new eb o with x | x | x | x | x | x | x
    · rw [x]; exact h3 o
    all_goals first
      | (rw [x.2]; decide)
      | exact absurd x.1 (hb o)
  unfold Cpuq.move at e
  split at e
  · cases e
  · cases a with
    | arrive o =>
      dsimp only at e; split at e
      · cases e
      · exact viaStep e (fun p x => Act.noConfusion x)
    | enter o =>
      dsimp only at e; split at e
      · cases e; exact ⟨h1, h2, h3⟩
      · cases e
    | mark o =>
      dsimp only at e; split at e
      · obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
        obtain ⟨a1, a2, a3⟩ := viaStep (b := .arrive o) hu (fun p x => Act.noConfusion x); exact ⟨a1, a2, a3⟩
      · cases e
    | crash o =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      obtain ⟨a1, a2, a3⟩ := viaStep hu (fun p x => Act.noConfusion x)
      exact ⟨by simp [leave, a1, clrBit_zero], by simp [leave, a2, clrBit_zero], a3⟩
    | kill o =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      obtain ⟨a1, a2, a3⟩ := viaStep hu (fun p x => Act.noConfusion x)
      exact ⟨by simp [leave, a1, clrBit_zero], by simp [leave, a2, clrBit_zero], a3⟩
    | finish o =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      obtain ⟨a1, a2, a3⟩ := viaStep hu (fun p x => Act.noConfusion x)
      exact ⟨by simp [leave, a1, clrBit_zero], by simp [leave, a2, clrBit_zero], a3⟩
    | tstp o =>
      dsimp only at e; simp [hc] at e
    | stop o =>
      dsimp only at e; simp [bit, h1] at e
    | halt o =>
      dsimp only at e; simp [h3 o] at e
    | cont o =>
      dsimp only at e; simp [bit, h2] at e
    | exit o i ok => exact viaStep e (fun p x => Act.noConfusion x)
    | timeout o i => exact viaStep e (fun p x => Act.noConfusion x)
    | gone o i => exact viaStep e (fun p x => Act.noConfusion x)
    | refill o c => exact viaStep e (fun p x => Act.noConfusion x)
    | consolidate o i d => exact viaStep e (fun p x => Act.noConfusion x)
    | release o c => exact viaStep e (fun p x => Act.noConfusion x)
    | handout => exact viaStep e (fun p x => Act.noConfusion x)
    | accept o c => exact viaStep e (fun p x => Act.noConfusion x)
    | drain o c => exact viaStep e (fun p x => Act.noConfusion x)
    | undrain o c => exact viaStep e (fun p x => Act.noConfusion x)

theorem Reach.noStops {cfg : Cfg} {s : St} (hc : cfg.stops = false) (r : Reach cfg s) : NoStops s := by
  induction r with
  | init =>
    refine ⟨rfl, rfl, fun o => ?_⟩
    simp only [St.op, Cpuq.init, List.getD_eq_getElem?_getD, List.getElem?_map]
    cases cfg.ops[o]? <;> simp
  | step a _ e ih => exact ih.move hc e

/-! ### Runs and weak fairness -/

/-- A run: a state at each time, each the `move` of an action from the one before, or the same
state (time passes while tasks run). -/
structure Run (cfg : Cfg) where
  st : Nat → St
  act : Nat → Option Act
  start : Reach cfg (st 0)
  moves : ∀ n a, act n = some a → move cfg (st n) a = some (st (n + 1))
  stays : ∀ n, act n = none → st (n + 1) = st n

theorem Run.reach {cfg : Cfg} (r : Run cfg) (n : Nat) : Reach cfg (r.st n) := by
  induction n with
  | zero => exact r.start
  | succ n ih =>
    cases h : r.act n with
    | none => rw [r.stays n h]; exact ih
    | some a => exact .step a ih (r.moves n a h)

def Enabled (cfg : Cfg) (s : St) (a : Act) : Prop := (move cfg s a).isSome = true

/-- Weak fairness of every step class (`fairKey`): a step enabled at every time from some time
on is taken, or one of its class is, at some time from then on. -/
def Run.Fair {cfg : Cfg} (r : Run cfg) : Prop :=
  ∀ a, (fairKey a).isSome = true → ∀ n, (∀ m, n ≤ m → Enabled cfg (r.st m) a) →
    ∃ m, n ≤ m ∧ ∃ b, r.act m = some b ∧ fairKey b = fairKey a

/-- From time `T` on, no operation arrives and no parent is killed by SIGKILL. -/
def Run.Calm {cfg : Cfg} (r : Run cfg) (T : Nat) : Prop :=
  ∀ m, T ≤ m → ∀ a, r.act m = some a →
    (∀ o, a ≠ .arrive o) ∧ (∀ o, a ≠ .enter o) ∧ (∀ o, a ≠ .mark o) ∧ (∀ o, a ≠ .crash o)

/-! ### The rules and the drain's context -/

/-- The rules the drain proof needs; the code's rules have them (`CodeRules.released`). -/
structure CodeRules (r : Rules) : Prop where
  safe : Safe r
  standing : r.standing = true
  validGrant : r.validGrant = true
  stoppedGrants : r.stoppedGrants = false
  stoppedWaits : r.stoppedWaits = false
  undrains : r.undrains = false
  markShared : r.markShared = true
  ledger : r.ledger = true
  renewAtRelease : r.renewAtRelease = true

theorem CodeRules.released : CodeRules Rules.released :=
  ⟨⟨rfl, rfl, rfl⟩, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩
theorem CodeRules.releasedFixed : CodeRules Rules.releasedFixed :=
  ⟨⟨rfl, rfl, rfl⟩, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

theorem bit_clrBit {n o d : Nat} (h : d ≠ o) : bit (clrBit n o) d = bit n d := by
  unfold clrBit bit; split
  · rw [Nat.testBit_xor, Nat.testBit_two_pow]; simp [Ne.symm h]
  · rfl

set_option linter.unusedSimpArgs false in
theorem find?_renew {p : Nat → Bool} {l : List Nat} {d o : Nat} (h : l.find? p = some d)
    (ho : p o = false) : (l.filter (· != o) ++ [o]).find? p = some d := by
  induction l with
  | nil => simp at h
  | cons x l ih =>
    by_cases hx : p x = true
    · simp only [List.find?_cons, hx, Option.some.injEq] at h; subst h
      have ne : x ≠ o := fun e => by subst e; simp [ho] at hx
      simp [List.filter_cons, ne, List.find?_cons, hx]
    · simp only [List.find?_cons, hx] at h
      have := ih h
      by_cases e : x = o
      · subst e; simpa [List.filter_cons] using this
      · simp [List.filter_cons, e, List.find?_cons, hx, this]

set_option linter.unusedSimpArgs false in
theorem find?_mono {p q : Nat → Bool} {l : List Nat} {d : Nat} (h : l.find? p = some d)
    (hd : q d = true) (hq : ∀ a, q a = true → p a = true) : l.find? q = some d := by
  induction l with
  | nil => simp at h
  | cons x l ih =>
    by_cases hx : p x = true
    · simp only [List.find?_cons, hx, Option.some.injEq] at h; subst h
      simp [List.find?_cons, hd]
    · simp only [List.find?_cons, hx] at h
      have hqx : q x = false := by
        cases e : q x
        · rfl
        · exact absurd (hq x e) hx
      simp [List.find?_cons, hqx, ih h]

/-- Renewing a ticket that is not a drain's leaves the first drain where it is. -/
theorem drainer_renew {cfg : Cfg} {s : St} {d o : Nat} (hdr : drainer cfg s = some d)
    (ho : drainOp cfg o = false) : drainer cfg { s with order := renewed s o } = some d := by
  show (renewed s o).find? (fun a => drainOp cfg a &&
    ((s.op a).phase == .alive || (s.op a).phase == .stopped)) = some d
  exact find?_renew hdr (by simp [ho])

/-- The first drain stays first when its phase holds, no ticket moves, and no operation starts
to count as a drain. -/
theorem drainer_mono {cfg : Cfg} {s t : St} {d : Nat} (hdr : drainer cfg s = some d)
    (hr : t.order = s.order) (hd : (t.op d).phase = (s.op d).phase)
    (hp : ∀ o, drainOp cfg o = true → ((t.op o).phase = .alive ∨ (t.op o).phase = .stopped) →
      ((s.op o).phase = .alive ∨ (s.op o).phase = .stopped)) :
    drainer cfg t = some d := by
  unfold drainer at *
  rw [hr]
  have hpd := (List.find?_eq_some_iff_append.1 hdr).1
  apply find?_mono hdr
  · rw [hd]; exact hpd
  · intro a ha
    simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at ha ⊢
    exact ⟨ha.1, hp a ha.1 ha.2⟩

theorem countP_or {α} (p q : α → Bool) (l : List α) (h : ∀ x ∈ l, ¬(p x = true ∧ q x = true)) :
    l.countP p + l.countP q = l.countP (fun x => p x || q x) := by
  induction l with
  | nil => rfl
  | cons x l ih =>
    have hx := h x (List.mem_cons_self ..)
    have ih := ih (fun y hy => h y (List.mem_cons_of_mem _ hy))
    simp only [List.countP_cons]
    cases hp : p x <;> cases hq : q x <;> simp_all <;> omega

theorem countP_lt {α} (p : α → Bool) (l : List α) {x : α} (hx : x ∈ l) (hp : p x = false) :
    l.countP p < l.length := by
  have e := List.length_eq_countP_add_countP (l := l) p
  have : 0 < l.countP (fun a => ¬p a) := List.countP_pos_iff.2 ⟨x, hx, by simp [hp]⟩
  omega

theorem busy_congr {s t : St} (h : s.ops = t.ops) (o : Nat) : s.busy o = t.busy o := by
  simp [St.busy, St.op, h]

theorem pendingN_congr {s t : St} (h : s.ops = t.ops) (o : Nat) : s.pendingN o = t.pendingN o := by
  simp [St.pendingN, St.op, h]

section
variable {cfg : Cfg} (hR : CodeRules cfg.rules)
include hR

theorem liveOp_eq (s : St) (o : Nat) : liveOp cfg s o = s.isAlive o := by
  simp [liveOp, hR.stoppedWaits]

theorem freeC_iff (s : St) (x : Cpu) :
    freeC cfg s x = true ↔ x.lock = none ∧ ∀ h, x.grant = some h → s.isAlive h = false := by
  simp only [freeC, validGrantC, grantLive, liveOp, hR.validGrant, hR.stoppedGrants,
    hR.stoppedWaits, Bool.and_eq_true, Option.isNone_iff_eq_none, Bool.not_eq_true']
  constructor
  · rintro ⟨hl, hg⟩; refine ⟨hl, fun h e => ?_⟩; rw [e] at hg; simpa using hg
  · rintro ⟨hl, hg⟩; refine ⟨hl, ?_⟩
    cases e : x.grant with
    | none => rfl
    | some h => simpa using hg h e

/-- While a CPU is free, `d` (alive) neither holds it nor has it granted: so `d` holds or has
been granted fewer than all of them. -/
theorem owned_grants_lt {d : Nat} {s : St} (h : Inv cfg s) (ha : (s.op d).phase = .alive) {c : Nat}
    (hc : c < s.cpus.length) (hf : freeC cfg s (s.cpu c) = true) :
    s.owned d + s.grants d < s.cpus.length := by
  have ec : s.cpu c = s.cpus[c] := by
    simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc]
  have disj : ∀ x ∈ s.cpus, ¬(ownsC d x = true ∧ grantedC d x = true) := by
    intro x hx ⟨ho, hg⟩
    obtain ⟨j, hj, rfl⟩ := List.mem_iff_getElem.1 hx
    have ej : s.cpu j = s.cpus[j] := by
      simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hj]
    rw [← ej] at ho hg
    obtain ⟨b, hb⟩ := (ownsC_iff _ _).1 ho
    have hl := h.ownerLock j _ hb ha
    have := (h.grantFree j d (by simpa [grantedC] using hg)).1
    rw [hl] at this; cases this
  rw [St.owned, St.grants, countP_or _ _ _ disj]
  apply countP_lt _ _ (List.getElem_mem hc)
  rw [← ec]
  obtain ⟨hl, hg⟩ := (freeC_iff hR s _).1 hf
  cases ho : ownsC d (s.cpu c)
  · cases hgr : grantedC d (s.cpu c)
    · rfl
    · have := hg d (by simpa [grantedC] using hgr); simp [St.isAlive, ha] at this
  · obtain ⟨b, hb⟩ := (ownsC_iff _ _).1 ho
    have := h.ownerLock c _ hb ha; rw [hl] at this; cases this

/-- `d`, the first drain, alive and still waiting to run: a free token goes to it. -/
theorem target_d {d : Nat} (hd : drainOp cfg d = true) (hcap : (cfg.op d).cap = cfg.cpus) {s : St}
    (h : Inv cfg s) (hdr : drainer cfg s = some d) (ha : (s.op d).phase = .alive)
    (hi : s.busy d = false) (hw : 0 < s.pendingN d) {c : Nat} (hc : c < s.cpus.length)
    (hf : freeC cfg s (s.cpu c) = true) : target cfg s = some d := by
  have hlt := owned_grants_lt hR h ha hc hf
  rw [h.len] at hlt
  have hdm : demand cfg s d > 0 := by
    simp only [demand, liveOp_eq hR, St.isAlive, ha, beq_self_eq_true, ite_true, hd, hi,
      Bool.not_false, Bool.true_and, decide_eq_true_eq, hw, hcap]
    omega
  simp [target, hdr, hdm]

/-- While `d` is the first drain and waits to run, a pass grants every free CPU to `d` and
changes nothing else. -/
theorem handout_to_d {d : Nat} (hd : drainOp cfg d = true) (hcap : (cfg.op d).cap = cfg.cpus)
    {s : St} (h : Inv cfg s) (hdr : drainer cfg s = some d) (ha : (s.op d).phase = .alive)
    (hi : s.busy d = false) (hw : 0 < s.pendingN d) {c : Nat} (hc : c < s.cpus.length) :
    (handout cfg s).cpu c =
      if freeC cfg s (s.cpu c) then { s.cpu c with grant := some d } else s.cpu c := by
  let F : Nat → Cpu := fun c' =>
    if freeC cfg s (s.cpu c') then { s.cpu c' with grant := some d } else s.cpu c'
  have key : ∀ (cs done : List Nat) (u : St), u.ops = s.ops → u.order = s.order → Inv cfg u →
      (∀ c', c' ∈ done → u.cpu c' = F c') → (∀ c', c' ∉ done → u.cpu c' = s.cpu c') →
      (∀ c' ∈ cs, c' ∉ done ∧ c' < s.cpus.length) → cs.Nodup →
      ∀ c', c' ∈ done ++ cs → (handoutOver cfg u cs).cpu c' = F c' := by
    intro cs
    induction cs with
    | nil => intro done u _ _ _ hd1 _ _ _ c' hc'; simp at hc'; exact hd1 c' hc'
    | cons c0 cs ih =>
      intro done u ho hr hu hd1 hd2 hcs hnd c' hc'
      have hc0 := hcs c0 (List.mem_cons_self ..)
      have hu0 : u.cpu c0 = s.cpu c0 := hd2 c0 hc0.1
      have hlen : u.cpus.length = s.cpus.length := by rw [hu.len, h.len]
      -- The grant of c0.
      have g0 : (grantOne cfg u c0).cpu c0 = F c0 := by
        show _ = if freeC cfg s (s.cpu c0) then _ else _
        by_cases hf : freeC cfg s (s.cpu c0) = true
        · have hfu : freeC cfg u (u.cpu c0) = true := by rw [hu0, freeC_congr ho]; exact hf
          have ht : target cfg u = some d :=
            target_d hR hd hcap hu (by rw [drainer_congr ho hr]; exact hdr)
              (by rw [phase_of_ops ho]; exact ha) (by rw [busy_congr ho]; exact hi)
              (by rw [pendingN_congr ho]; exact hw) (by rw [hlen]; exact hc0.2) hfu
          rw [ite_eq_left hf]
          unfold grantOne; rw [ite_eq_left hfu, ht]
          rw [St.cpu_setCpu, ite_eq_left (⟨rfl, by rw [hlen]; exact hc0.2⟩ : c0 = c0 ∧ c0 < u.cpus.length), hu0]
        · have hfu : freeC cfg u (u.cpu c0) = false := by
            rw [hu0, freeC_congr ho]; simpa using hf
          rw [ite_eq_right hf]
          unfold grantOne; rw [ite_eq_right (by simp [hfu]), hu0]
      have gk : ∀ c', c' ≠ c0 → (grantOne cfg u c0).cpu c' = u.cpu c' := by
        intro c' ne
        unfold grantOne; split
        · split
          · rw [St.cpu_setCpu, ite_eq_right (fun x => ne x.1.symm)]
          · rfl
        · rfl
      have hnd' := List.nodup_cons.1 hnd
      have := ih (done ++ [c0]) (grantOne cfg u c0) ((grantOne_ops ..).trans ho)
        ((grantOne_order ..).trans hr) (hu.grantOne c0)
        (by
          intro c'' hm
          rcases List.mem_append.1 hm with x | x
          · have ne : c'' ≠ c0 := fun e => hc0.1 (e ▸ x)
            rw [gk c'' ne]; exact hd1 c'' x
          · simp at x; subst x; exact g0)
        (by
          intro c'' hm
          have ne : c'' ≠ c0 := fun e => hm (by simp [e])
          rw [gk c'' ne]; exact hd2 c'' (fun x => hm (List.mem_append_left _ x)))
        (by
          intro c'' hm
          have := hcs c'' (List.mem_cons_of_mem _ hm)
          refine ⟨fun x => ?_, this.2⟩
          rcases List.mem_append.1 x with y | y
          · exact this.1 y
          · simp at y; subst y; exact hnd'.1 hm)
        hnd'.2 c' (by
          rcases List.mem_append.1 hc' with x | x
          · exact List.mem_append_left _ (List.mem_append_left _ x)
          · rcases List.mem_cons.1 x with y | y
            · subst y; exact List.mem_append_left _ (List.mem_append_right _ (List.mem_singleton_self _))
            · exact List.mem_append_right _ y)
      simpa only [handoutOver] using this
  exact key (List.range s.cpus.length) [] s rfl rfl h (by simp) (fun _ _ => rfl)
    (fun c' hm => ⟨by simp, List.mem_range.1 hm⟩) (List.nodup_range) c (by simp [hc])

end

/-! ### A CPU's distance from the drain -/

/-- How far CPU `c` is from being `d`'s: held by `d` 0, granted to `d` 1, free 2, being emptied by
another 3, kept by another 4, granted to another (alive) 5. -/
def rank (d : Nat) (s : St) (c : Nat) : Nat :=
  match (s.cpu c).lock with
  | some g => if g = d then 0 else if drainingC (s.cpu c) then 3 else 4
  | none =>
    match (s.cpu c).grant with
    | some h => if (s.op h).phase = .alive then (if h = d then 1 else 5) else 2
    | none => 2

/-- A task's weight on CPU `c`: 2 while it runs there, 1 while an attempt of it dies there. -/
def wOn (c : Nat) (t : Task) : Nat :=
  2 * (if runningC c t then 1 else 0) + (if t.dying == some c then 1 else 0)

/-- What is left to end on a CPU another operation empties: its tasks' weights there. -/
def inner (d : Nat) (s : St) (c : Nat) : Nat :=
  match (s.cpu c).lock with
  | some g => if g ≠ d ∧ drainingC (s.cpu c) = true then ((s.op g).tasks.map (wOn c)).sum else 0
  | none => 0

theorem rank_congr {d : Nat} {s t : St} {c : Nat} (hc : t.cpu c = s.cpu c)
    (hp : ∀ h, (t.op h).phase = (s.op h).phase) : rank d t c = rank d s c := by
  simp only [rank, hc, hp]

theorem inner_congr {d : Nat} {s t : St} {c : Nat} (hc : t.cpu c = s.cpu c)
    (ht : ∀ g, (s.cpu c).lock = some g → (t.op g).tasks = (s.op g).tasks) :
    inner d t c = inner d s c := by
  unfold inner; rw [hc]
  split
  · rename_i g hg; rw [ht g hg]
  · rfl

theorem sum_map_set {α} (f : α → Nat) (l : List α) (i : Nat) (x : α) (hi : i < l.length) :
    ((l.set i x).map f).sum + f l[i] = (l.map f).sum + f x := by
  induction l generalizing i with
  | nil => simp at hi
  | cons y l ih =>
    cases i with
    | zero => simp; omega
    | succ i =>
      simp only [List.set_cons_succ, List.map_cons, List.sum_cons, List.getElem_cons_succ]
      have := ih i (by simpa using hi); omega

/-- Replacing a task changes the inner count of its operation's CPUs by the change in weight. -/
theorem inner_setTask {d : Nat} {s : St} {o i : Nat} {x : Task} {c : Nat}
    (ho : o < s.ops.length) (hi : i < (s.op o).tasks.length) :
    inner d (s.setTask o i x) c + (if (s.cpu c).lock = some o ∧ o ≠ d ∧ drainingC (s.cpu c) = true
      then wOn c (s.task o i) else 0) =
    inner d s c + (if (s.cpu c).lock = some o ∧ o ≠ d ∧ drainingC (s.cpu c) = true
      then wOn c x else 0) := by
  unfold inner
  have hcpu : (s.setTask o i x).cpu c = s.cpu c := rfl
  rw [hcpu]
  split
  · rename_i g hg
    by_cases eg : g = o
    · subst eg
      simp only [hg, true_and]
      split
      · rename_i hh
        have e1 : ((s.setTask g i x).op g).tasks = (s.op g).tasks.set i x := by
          simp [St.setTask, St.op_set, ho]
        have e2 : s.task g i = (s.op g).tasks[i] := by
          simp [St.task, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi]
        rw [e1, e2]; exact sum_map_set _ _ _ _ hi
      · rfl
    · have : ((s.setTask o i x).op g).tasks = (s.op g).tasks := St.tasks_setTask_ne _ _ _ _ _ (Ne.symm eg)
      rw [this]; simp [hg, eg]
  · rename_i hg; simp [hg]

theorem tryOnce_standing {cfg : Cfg} (hs : cfg.rules.standing = true) (s : St) (o : Nat) :
    tryOnce cfg s o = s := by
  simp [tryOnce, tryCond, hs]

theorem busy_setTask {s : St} {o i : Nat} {x : Task} (hb : s.busy o = false)
    (hx : ∀ c, x.st ≠ .running c) : (s.setTask o i x).busy o = false := by
  simp only [St.busy, List.any_eq_false] at hb ⊢
  intro y hy
  have : y ∈ (s.op o).tasks ∨ y = x := by
    by_cases ho : o < s.ops.length
    · have e1 : ((s.setTask o i x).op o).tasks = (s.op o).tasks.set i x := by
        simp [St.setTask, St.op_set, ho]
      rw [e1] at hy; exact List.mem_or_eq_of_mem_set hy
    · have e0 : s.ops.set o { s.op o with tasks := (s.op o).tasks.set i x } = s.ops :=
        set_of_ge _ _ _ ho
      have e1 : (s.setTask o i x) = s := by simp only [St.setTask, e0]
      rw [e1] at hy; exact .inl hy
  rcases this with m | m
  · exact hb y m
  · subst m; cases e : y.st <;> simp_all

theorem pendingN_setTask {s : St} {o i : Nat} {x : Task} (ho : o < s.ops.length)
    (hi : i < (s.op o).tasks.length) (hp : pendingT (s.task o i) = true → pendingT x = true) :
    s.pendingN o ≤ (s.setTask o i x).pendingN o := by
  have e1 : ((s.setTask o i x).op o).tasks = (s.op o).tasks.set i x := by
    simp [St.setTask, St.op_set, ho]
  have e2 : s.task o i = (s.op o).tasks[i] := by
    simp [St.task, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi]
  have := countP_set' pendingT (s.op o).tasks i x {} hi
  simp only [St.pendingN, e1]
  rw [e2] at hp
  simp only [List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hi, Option.getD_some] at this
  split at this <;> split at this <;> simp_all <;> omega

theorem inner_congr' {d : Nat} {s t : St} {c : Nat} (hl : (t.cpu c).lock = (s.cpu c).lock)
    (hdr : drainingC (t.cpu c) = drainingC (s.cpu c))
    (ht : ∀ g, (s.cpu c).lock = some g → (t.op g).tasks = (s.op g).tasks) :
    inner d t c = inner d s c := by
  unfold inner; rw [hl, hdr]
  split
  · rename_i g hg; rw [ht g hg]
  · rfl

theorem busy_of_running {s : St} {o i c : Nat} (h : (s.task o i).st = .running c) : s.busy o = true := by
  have hi := s.lt_of_task o i (by rw [h]; simp)
  simp only [St.busy, List.any_eq_true]
  exact ⟨_, s.task_mem o i hi, by rw [h]⟩

theorem not_busy {s : St} {o i c : Nat} (hb : s.busy o = false) : (s.task o i).st ≠ .running c := by
  intro h; rw [busy_of_running h] at hb; cases hb

/-- A drain never empties its own CPUs (under the ledger). -/
theorem canDrain_not_drainOp {cfg : Cfg} {s : St} {o c : Nat} (hl : cfg.rules.ledger = true)
    (h : canDrain cfg s o c = true) : drainOp cfg o = false := by
  cases e : drainOp cfg o
  · rfl
  · unfold canDrain mayGive at h
    simp only [e, hl, Bool.not_true, Bool.and_false, Bool.false_or, ite_true, Bool.and_eq_true] at h
    obtain ⟨-, h⟩ := h
    split at h
    · cases h
    · simp at h

/-- A holder holds at least one slot. -/
theorem owned_pos {cfg : Cfg} {s : St} (h : Inv cfg s) {o c : Nat} (hl : (s.cpu c).lock = some o) :
    0 < s.owned o := by
  have hc : c < s.cpus.length := by
    cases Nat.lt_or_ge c s.cpus.length with
    | inl x => exact x
    | inr x => rw [St.cpu_default s c (by omega)] at hl; cases hl
  have ec : s.cpu c = s.cpus[c] := by
    simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc]
  exact List.countP_pos_iff.2 ⟨_, List.getElem_mem hc, by rw [← ec]; exact (h.lockOwner c o hl).1⟩

/-- The drain's context: what the proof keeps true from the time it starts. -/
structure DCtx (cfg : Cfg) (d : Nat) (s : St) : Prop where
  reach : Reach cfg s
  drainer : drainer cfg s = some d
  alive : (s.op d).phase = .alive
  idle : s.busy d = false
  work : 0 < s.pendingN d
  mark : bit s.marks d = true
  lockFree : s.poolLock = none
  others : ∀ g c, drainOp cfg g = true → g ≠ d → (s.cpu c).lock ≠ some g ∧ (s.cpu c).grant ≠ some g
  kept : ∀ c, (s.cpu c).slot ≠ some { owner := d, draining := true }

/-- What a step may do to one CPU: lower its rank, or keep it and not raise what is left on it. -/
def Better (d : Nat) (s t : St) : Prop :=
  ∀ c, rank d t c ≤ rank d s c ∧ (rank d t c = rank d s c → inner d t c ≤ inner d s c)

/-- A step that changes one task. -/
theorem taskStep_ctx {cfg : Cfg} {d : Nat} {s : St} {o i : Nat} {y : Task} (x : DCtx cfg d s)
    (rt : Reach cfg (s.setTask o i y)) (ho : o < s.ops.length) (hi : i < (s.op o).tasks.length)
    (hrun : o = d → ∀ c, y.st ≠ .running c)
    (hpend : o = d → pendingT (s.task o i) = true → pendingT y = true)
    (hw : ∀ c, (s.cpu c).lock = some o → o ≠ d → drainingC (s.cpu c) = true →
      wOn c y ≤ wOn c (s.task o i)) :
    DCtx cfg d (s.setTask o i y) ∧ Better d s (s.setTask o i y) := by
  have hph : ∀ p, ((s.setTask o i y).op p).phase = (s.op p).phase := fun p => St.phase_setTask ..
  refine ⟨⟨rt, Cpuq.drainer_mono x.drainer rfl (hph d) (fun p _ hp => by rw [hph] at hp; exact hp),
    by rw [hph]; exact x.alive, ?_, ?_, x.mark, x.lockFree, x.others, x.kept⟩, ?_⟩
  · by_cases e : o = d
    · subst e; exact busy_setTask x.idle (hrun rfl)
    · have : ((s.setTask o i y).op d).tasks = (s.op d).tasks := St.tasks_setTask_ne _ _ _ _ _ e
      simp only [St.busy, this]; exact x.idle
  · by_cases e : o = d
    · subst e; exact Nat.lt_of_lt_of_le x.work (pendingN_setTask ho hi (hpend rfl))
    · have : ((s.setTask o i y).op d).tasks = (s.op d).tasks := St.tasks_setTask_ne _ _ _ _ _ e
      simp only [St.pendingN, this]; exact x.work
  · intro c
    refine ⟨Nat.le_of_eq (rank_congr rfl hph), fun _ => ?_⟩
    have k := inner_setTask (d := d) (c := c) (x := y) ho hi
    split at k
    · rename_i hc; have := hw c hc.1 hc.2.1 hc.2.2; omega
    · omega

theorem handout_len (cfg : Cfg) (s : St) : (handout cfg s).cpus.length = s.cpus.length := by
  unfold Cpuq.handout; generalize List.range s.cpus.length = cs
  induction cs generalizing s with
  | nil => rfl
  | cons c' cs ih => simp only [handoutOver]; rw [ih, grantOne_len]

/-- With `d` waiting first among drains, a pass grants each free CPU to `d`: it lowers a free
CPU's rank to 1 and changes nothing else. -/
theorem rank_handout {cfg : Cfg} {d : Nat} (hR : CodeRules cfg.rules) (hd : drainOp cfg d = true)
    (hcap : (cfg.op d).cap = cfg.cpus) {s : St} (h : Inv cfg s) (hdr : drainer cfg s = some d)
    (ha : (s.op d).phase = .alive) (hi : s.busy d = false) (hw : 0 < s.pendingN d) (c : Nat) :
    rank d (handout cfg s) c = (if rank d s c = 2 ∧ c < s.cpus.length then 1 else rank d s c) ∧
    inner d (handout cfg s) c = inner d s c ∧
    ((handout cfg s).cpu c).lock = (s.cpu c).lock ∧
    ((handout cfg s).cpu c).slot = (s.cpu c).slot ∧
    (((handout cfg s).cpu c).grant = (s.cpu c).grant ∨ ((handout cfg s).cpu c).grant = some d) := by
  have hops := (handout_order_ops cfg s).2
  have hph : ∀ p, ((handout cfg s).op p).phase = (s.op p).phase := fun p => phase_of_ops hops p
  by_cases hc : c < s.cpus.length
  · have e := handout_to_d hR hd hcap h hdr ha hi hw hc
    have hfr : freeC cfg s (s.cpu c) = true ↔ rank d s c = 2 := by
      rw [freeC_iff hR]
      unfold rank
      constructor
      · rintro ⟨hl, hg⟩
        rw [hl]; simp only
        cases eg : (s.cpu c).grant with
        | none => rfl
        | some g' => have := hg g' eg; simp [St.isAlive] at this; simp [this]
      · intro hr
        cases el : (s.cpu c).lock with
        | some g' => rw [el] at hr; simp only at hr; split at hr <;> (try split at hr) <;> simp at hr
        | none =>
          refine ⟨rfl, fun g' eg => ?_⟩
          rw [el, eg] at hr; simp only at hr
          by_cases hal : (s.op g').phase = .alive
          · rw [ite_eq_left hal] at hr; split at hr <;> simp at hr
          · simp [St.isAlive, hal]
    by_cases f : freeC cfg s (s.cpu c) = true
    · have r2 := hfr.1 f
      have hl := ((freeC_iff hR _ _).1 f).1
      have e' : (handout cfg s).cpu c = { s.cpu c with grant := some d } := by rw [e, ite_eq_left f]
      refine ⟨?_, ?_, by rw [e'], by rw [e'], .inr (by rw [e'])⟩
      · rw [ite_eq_left (⟨r2, hc⟩ : rank d s c = 2 ∧ c < s.cpus.length)]
        unfold rank; rw [e']; simp [hl, hph, ha]
      · exact inner_congr' (by rw [e']) (by rw [e']; simp [drainingC])
          (fun g hg => by rw [hl] at hg; cases hg)
    · have e' : (handout cfg s).cpu c = s.cpu c := by rw [e, ite_eq_right f]
      have : ¬(rank d s c = 2 ∧ c < s.cpus.length) := fun x => f (hfr.2 x.1)
      rw [ite_eq_right this]
      exact ⟨rank_congr e' hph, inner_congr e' (fun g _ => by simp [St.op, hops]), by rw [e'],
        by rw [e'], .inl (by rw [e'])⟩
  · have hlen : (handout cfg s).cpus.length = s.cpus.length := handout_len cfg s
    have e1 : (handout cfg s).cpu c = {} := St.cpu_default _ _ (by rw [hlen]; exact hc)
    have e0 : s.cpu c = {} := St.cpu_default _ _ hc
    have : ¬(rank d s c = 2 ∧ c < s.cpus.length) := fun x => hc x.2
    rw [ite_eq_right this]
    exact ⟨rank_congr (by rw [e1, e0]) hph, inner_congr (by rw [e1, e0]) (fun g _ => by simp [St.op, hops]),
      by rw [e1, e0], by rw [e1, e0], .inl (by rw [e1, e0])⟩

theorem wOn_zero {c : Nat} {t : Task} (hs : ∀ c', t.st ≠ .running c') (hd : t.dying = none) :
    wOn c t = 0 := by
  have : runningC c t = false := by simp [runningC, hs c]
  simp [wOn, this, hd]

theorem taken_cpu (s : St) (o c c' : Nat) :
    (taken s o c).cpu c' = if c = c' ∧ c < s.cpus.length then takenCpu o else s.cpu c' := by
  simp only [St.cpu, taken]; exact getD_set ..

theorem rank_setPhase_le {d : Nat} {s : St} {o : Nat} (hne : o ≠ d) (c : Nat) :
    rank d (s.setPhase o .over) c ≤ rank d s c := by
  unfold rank
  have hcpu : (s.setPhase o .over).cpu c = s.cpu c := rfl
  rw [hcpu]
  split
  · exact Nat.le_refl _
  · split
    · rename_i h' _
      by_cases e : h' = o
      · subst e
        by_cases ho : h' < s.ops.length
        · rw [St.phase_setPhase _ _ _ _ ho]; simp only [ite_true]
          split <;> (try split) <;> simp_all
        · have : (s.setPhase h' .over) = s := by
            simp only [St.setPhase, set_of_ge _ _ _ ho]
          rw [this]; exact Nat.le_refl _
      · rw [St.op_setPhase_ne _ _ _ _ (Ne.symm e)]; exact Nat.le_refl _
    · exact Nat.le_refl _

/-- Every step of a calm run keeps the drain's context, and lowers or keeps each CPU's rank. -/
theorem drain_frame {cfg : Cfg} {d : Nat} (hR : CodeRules cfg.rules) (hd : drainOp cfg d = true)
    (hcap : (cfg.op d).cap = cfg.cpus) (hst : cfg.stops = false) (hk : cfg.kills = false)
    {s t : St} {a : Act} (x : DCtx cfg d s) (hfew : s.owned d < cfg.cpus)
    (calm : (∀ o, a ≠ .arrive o) ∧ (∀ o, a ≠ .enter o) ∧ (∀ o, a ≠ .mark o) ∧ (∀ o, a ≠ .crash o))
    (e : move cfg s a = some t) : DCtx cfg d t ∧ Better d s t := by
  have h := x.reach.inv hR.safe
  have ns := x.reach.noStops hst
  have rt : Reach cfg t := .step a x.reach e
  unfold Cpuq.move at e
  simp only [x.lockFree, Option.isSome_none, Bool.and_false, Bool.false_eq_true, ite_false] at e
  cases a with
  | arrive o => exact absurd rfl (calm.1 o)
  | enter o => exact absurd rfl (calm.2.1 o)
  | mark o => exact absurd rfl (calm.2.2.1 o)
  | crash o => exact absurd rfl (calm.2.2.2 o)
  | kill o => simp [Cpuq.step, hk] at e
  | tstp o => simp [hst] at e
  | stop o => simp [bit, ns.1] at e
  | halt o => simp [ns.2.2 o] at e
  | cont o => simp [bit, ns.2.1] at e
  | undrain o c => simp [Cpuq.step, hR.undrains] at e
  | exit o i ok =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i c0 hr
      have hi := s.lt_of_task o i (by rw [hr]; simp)
      have ho := s.lt_of_task_op o i (by rw [hr]; simp)
      have hdy := dying_none_of_running h hr
      split at e
      · cases e
        unfold reap at rt ⊢
        rw [tryOnce_standing hR.standing] at rt ⊢
        apply taskStep_ctx x rt ho hi
        · intro eo; subst eo; exact absurd hr (not_busy x.idle)
        · intro eo; subst eo; exact absurd hr (not_busy x.idle)
        · intro c _ _ _
          rw [wOn_zero]
          · exact Nat.zero_le _
          · intro c'; split
            · exact afterOk_st _ _ _ _
            · exact afterFail_st _ _ _ _
          · split
            · rw [afterOk_dying, hdy]
            · rw [afterFail_dying, hdy]
      · split at e
        · rename_i hdead
          cases e
          apply taskStep_ctx x rt ho hi
          · intro eo; subst eo; simp [x.alive] at hdead
          · intro eo; subst eo; simp [x.alive] at hdead
          · intro c hl _ _
            have := (h.lockOwner c o hl).2; simp [this] at hdead
        · cases e
    · cases e
  | timeout o i =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i c0 hr
      split at e
      · simp only [hR.safe.retryAtReap, ite_true] at e
        cases e
        have hi := s.lt_of_task o i (by rw [hr]; simp)
        have ho := s.lt_of_task_op o i (by rw [hr]; simp)
        have hdy := dying_none_of_running h hr
        apply taskStep_ctx x rt ho hi
        · intro eo; subst eo; exact absurd hr (not_busy x.idle)
        · intro eo; subst eo; exact absurd hr (not_busy x.idle)
        · intro c _ _ _
          by_cases ec : c0 = c
          · subst ec; simp [wOn, runningC, hr, hdy]
          · simp [wOn, runningC, hr, hdy, ec]
      · cases e
    · cases e
  | gone o i =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i c0 hdy
      cases e
      have ht := h.dyingTimedOut o i (by rw [hdy]; simp)
      have hi := s.lt_of_task o i (by rw [ht]; simp)
      have ho := s.lt_of_task_op o i (by rw [ht]; simp)
      have hst' : ∀ c', (if (s.op o).phase == .alive && (s.task o i).st == .timedOut
          then afterFail cfg o { s.task o i with dying := none } else { s.task o i with dying := none }).st ≠
          .running c' := by
        intro c'; split
        · exact afterFail_st _ _ _ _
        · show (s.task o i).st ≠ _; rw [ht]; simp
      apply taskStep_ctx x rt ho hi
      · intro _ c'; exact hst' c'
      · intro _ hp; simp [pendingT, ht] at hp
      · intro c _ _ _
        rw [wOn_zero hst' (by split; rw [afterFail_dying]; rfl)]
        exact Nat.zero_le _
    · cases e
  | refill o c0 =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq, Bool.not_eq_true'] at g
      obtain ⟨⟨⟨⟨ha, hsl⟩, hkk⟩, -⟩, hdo⟩ := g
      split at e
      · rename_i i hp
        cases e
        have hpe := firstPending_spec hp
        have hi := s.lt_of_task o i (by rw [hpe]; simp)
        have ho := s.lt_of_task_op o i (by rw [hpe]; simp)
        have hdy := dying_none_of_pending h hpe
        have notd : o ≠ d := by
          intro eo; subst eo
          simp only [hd, Bool.not_true, Bool.false_or, beq_iff_eq] at hdo
          rw [h.len] at hdo; omega
        apply taskStep_ctx x rt ho hi
        · intro eo; exact absurd eo notd
        · intro eo; exact absurd eo notd
        · intro c _ _ hdc
          have ne : c0 ≠ c := by intro ec; subst ec; simp [drainingC, hsl] at hdc
          simp [wOn, runningC, hdy, ne]
      · cases e
    · cases e
  | consolidate o i dd =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i c0 hr
      split at e
      · rename_i g
        simp only [Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at g
        obtain ⟨⟨⟨-, -⟩, hsd⟩, -⟩ := g
        cases e
        have hi := s.lt_of_task o i (by rw [hr]; simp)
        have ho := s.lt_of_task_op o i (by rw [hr]; simp)
        have hdy := dying_none_of_running h hr
        apply taskStep_ctx x rt ho hi
        · intro eo; subst eo; exact absurd hr (not_busy x.idle)
        · intro eo; subst eo; exact absurd hr (not_busy x.idle)
        · intro c _ _ hdc
          have ne : dd ≠ c := by intro ec; subst ec; simp [drainingC, hsd] at hdc
          by_cases ec : c0 = c
          · subst ec; simp [wOn, runningC, hdy, ne, hr]
          · simp [wOn, runningC, hdy, ne, hr, ec]
      · cases e
    · cases e
  | handout =>
    simp only [Cpuq.step] at e
    split at e
    · cases e
      have hops := (handout_order_ops cfg s).2
      have hord := (handout_order_ops cfg s).1
      have k := rank_handout hR hd hcap h x.drainer x.alive x.idle x.work
      have ex := handout_extras cfg s
      simp only [extras, Prod.mk.injEq] at ex
      refine ⟨⟨rt, by rw [drainer_congr hops hord]; exact x.drainer, by rw [phase_of_ops hops]; exact x.alive,
        by rw [busy_congr hops]; exact x.idle, by rw [pendingN_congr hops]; exact x.work,
        by rw [ex.2.1]; exact x.mark, by rw [ex.1]; exact x.lockFree, ?_, ?_⟩, ?_⟩
      · intro g c hg hne
        obtain ⟨-, -, hl, -, hgr⟩ := k c
        refine ⟨by rw [hl]; exact (x.others g c hg hne).1, ?_⟩
        rcases hgr with z | z
        · rw [z]; exact (x.others g c hg hne).2
        · rw [z]; intro w; cases w; exact hne rfl
      · intro c; obtain ⟨-, -, -, hsl, -⟩ := k c; rw [hsl]; exact x.kept c
      · intro c; obtain ⟨k1, k2, -⟩ := k c
        rw [k1, k2]
        split
        · rename_i z; rw [z.1]; exact ⟨by omega, fun w => by omega⟩
        · exact ⟨Nat.le_refl _, fun _ => Nat.le_refl _⟩
    · cases e
  | accept o c0 =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      simp only [Bool.and_eq_true, beq_iff_eq, Option.isNone_iff_eq_none] at g
      obtain ⟨⟨ha, hg⟩, hl⟩ := g
      cases e
      rw [takeTok_eq cfg s o c0 hR.safe.reclaim] at rt ⊢
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
      have hc0 := s.lt_of_grant c0 (by rw [hg]; simp)
      have hph : ∀ p, ((taken s o c0).op p).phase = (s.op p).phase := fun p => reclaimed_phase s c0 p
      have hopa : ∀ p, (s.op p).phase ≠ .dead → (taken s o c0).op p = s.op p := by
        intro p hp; show (reclaimed s c0).op p = _; rw [reclaimed_op]; simp [hp]
      have hdead : (s.op d).phase ≠ .dead := by rw [x.alive]; decide
      refine ⟨⟨rt, drainer_mono x.drainer rfl (hph d) (fun p _ hp => by rw [hph] at hp; exact hp),
        by rw [hph]; exact x.alive, by simp only [St.busy, hopa d hdead]; exact x.idle,
        by simp only [St.pendingN, hopa d hdead]; exact x.work, x.mark, x.lockFree, ?_, ?_⟩, ?_⟩
      · intro g' c hg' hne
        rw [taken_cpu]
        split
        · rename_i z; obtain ⟨rfl, -⟩ := z
          refine ⟨fun w => ?_, by simp [takenCpu]⟩
          simp only [takenCpu, Option.some.injEq] at w; subst w
          exact (x.others _ _ hg' hne).2 hg
        · exact x.others g' c hg' hne
      · intro c; rw [taken_cpu]
        split
        · simp [takenCpu]
        · exact x.kept c
      · intro c
        by_cases ec : c0 = c
        · subst ec
          have r1 : rank d s c0 = if o = d then 1 else 5 := by unfold rank; simp [hl, hg, ha']
          have r2 : rank d (taken s o c0) c0 = if o = d then 0 else 4 := by
            unfold rank; rw [taken_cpu, ite_eq_left (⟨rfl, hc0⟩ : c0 = c0 ∧ c0 < s.cpus.length)]; simp [takenCpu, drainingC]
          rw [r1, r2]; split <;> exact ⟨by omega, fun w => by omega⟩
        · have hc : (taken s o c0).cpu c = s.cpu c := by rw [taken_cpu, ite_eq_right (fun z => ec z.1)]
          refine ⟨Nat.le_of_eq (rank_congr hc hph), fun _ => Nat.le_of_eq (inner_congr hc ?_)⟩
          intro g' hg'
          rw [hopa g' (by rw [(h.lockOwner c g' hg').2]; decide)]
    · cases e
  | drain o c0 =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i g
      cases e
      have hnd := canDrain_not_drainOp hR.ledger g
      unfold canDrain at g
      simp only [Bool.and_eq_true, beq_iff_eq] at g
      obtain ⟨⟨ha, hsl⟩, -⟩ := g
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
      have hne : o ≠ d := fun eo => by rw [eo, hd] at hnd; cases hnd
      have hl : (s.cpu c0).lock = some o := h.ownerLock c0 _ hsl ha'
      have hc0 := s.lt_of_slot c0 (by rw [hsl]; simp)
      have hcpu : ∀ c', (drainEff cfg s o c0).cpu c' = if c0 = c' ∧ c0 < s.cpus.length then
          { s.cpu c0 with slot := some { owner := o, draining := true } } else s.cpu c' := by
        intro c'; exact St.cpu_setCpu ..
      have hord : (drainEff cfg s o c0).order = s.order := by simp [drainEff, hR.renewAtRelease]
      have hops : (drainEff cfg s o c0).ops = s.ops := rfl
      refine ⟨⟨rt, by rw [drainer_congr hops hord]; exact x.drainer, x.alive, x.idle, x.work,
        x.mark, x.lockFree, ?_, ?_⟩, ?_⟩
      · intro g' c hg' hne'
        rw [hcpu]; split
        · rename_i z; obtain ⟨rfl, -⟩ := z; exact x.others g' c0 hg' hne'
        · exact x.others g' c hg' hne'
      · intro c; rw [hcpu]; split
        · simp; intro w; exact hne w
        · exact x.kept c
      · intro c
        by_cases ec : c0 = c
        · subst ec
          have r1 : rank d s c0 = 4 := by unfold rank; simp [hl, hne, hsl, drainingC]
          have r2 : rank d (drainEff cfg s o c0) c0 = 3 := by
            unfold rank; rw [hcpu, ite_eq_left (⟨rfl, hc0⟩ : c0 = c0 ∧ c0 < s.cpus.length)]; simp [hl, hne, drainingC]
          rw [r1, r2]; exact ⟨by omega, fun w => by omega⟩
        · have hc : (drainEff cfg s o c0).cpu c = s.cpu c := by rw [hcpu, ite_eq_right (fun z => ec z.1)]
          exact ⟨Nat.le_of_eq (rank_congr hc (fun p => phase_of_ops hops p)),
            fun _ => Nat.le_of_eq (inner_congr hc (fun g' _ => by simp [St.op, hops]))⟩
    · cases e
  | release o c0 =>
    simp only [Cpuq.step] at e
    split at e
    · rename_i sl hsl
      split at e
      · rename_i g
        simp only [Bool.and_eq_true, beq_iff_eq, Bool.or_eq_true, Bool.not_eq_true'] at g
        obtain ⟨⟨⟨⟨⟨ha, hown⟩, hr0⟩, hdy⟩, hdp⟩, -⟩ := g
        cases e
        have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
        subst hown
        have hl : (s.cpu c0).lock = some sl.owner := h.ownerLock c0 sl hsl ha'
        have hc0 := s.lt_of_slot c0 (by rw [hsl]; simp)
        have hne : sl.owner ≠ d := by
          intro eo
          rcases hdp with dr | p0
          · apply x.kept c0; rw [hsl]; cases sl; simp_all
          · rw [eo] at p0; have := x.work; omega
        have hnd : drainOp cfg sl.owner = false := by
          cases e2 : drainOp cfg sl.owner
          · rfl
          · exact absurd hl (x.others _ c0 e2 hne).1
        have hdy' : ∀ i, (s.task sl.owner i).dying ≠ some c0 := by
          intro i; rcases hdy with z | z
          · simp [hR.safe.releaseWaitsDying] at z
          · have := all_task z (by simp) i; simpa using this
        simp only [hR.renewAtRelease, ite_true] at rt ⊢
        generalize hs1 : ({ s.setCpu c0 {} with
          drains := s.drains - (if sl.draining then 1 else 0), order := renewed s sl.owner } : St) = s1
          at rt ⊢
        have h1 : Inv cfg s1 := by rw [← hs1]; exact h.release hsl rfl ha' hr0 hdy'
        have hops1 : s1.ops = s.ops := by rw [← hs1]; rfl
        have hdr1 : drainer cfg s1 = some d := by
          rw [← hs1]
          show (renewed s sl.owner).find? _ = some d
          exact find?_renew x.drainer (by simp [hnd])
        have hc1 : ∀ c, s1.cpu c = if c0 = c ∧ c0 < s.cpus.length then {} else s.cpu c := by
          intro c; rw [← hs1]; exact St.cpu_setCpu ..
        have hex1 : s1.poolLock = s.poolLock ∧ s1.marks = s.marks := by rw [← hs1]; exact ⟨rfl, rfl⟩
        have hph1 : ∀ p, (s1.op p).phase = (s.op p).phase := fun p => phase_of_ops hops1 p
        have k := rank_handout hR hd hcap h1 hdr1 (by rw [hph1]; exact x.alive)
          (by rw [busy_congr hops1]; exact x.idle) (by rw [pendingN_congr hops1]; exact x.work)
        have hops := (handout_order_ops cfg s1).2
        have hord := (handout_order_ops cfg s1).1
        have ex := handout_extras cfg s1
        simp only [extras, Prod.mk.injEq] at ex
        have hlen1 : s1.cpus.length = s.cpus.length := by rw [← hs1]; simp
        refine ⟨⟨rt, by rw [drainer_congr hops hord]; exact hdr1,
          by rw [phase_of_ops hops, hph1]; exact x.alive,
          by rw [busy_congr hops, busy_congr hops1]; exact x.idle,
          by rw [pendingN_congr hops, pendingN_congr hops1]; exact x.work,
          by rw [ex.2.1, hex1.2]; exact x.mark, by rw [ex.1, hex1.1]; exact x.lockFree, ?_, ?_⟩, ?_⟩
        · intro g c hg hne'
          obtain ⟨-, -, hl', -, hgr⟩ := k c
          have o1 : (s1.cpu c).lock ≠ some g ∧ (s1.cpu c).grant ≠ some g := by
            rw [hc1]; split
            · simp
            · exact x.others g c hg hne'
          refine ⟨by rw [hl']; exact o1.1, ?_⟩
          rcases hgr with z | z
          · rw [z]; exact o1.2
          · rw [z]; intro w; cases w; exact hne' rfl
        · intro c; obtain ⟨-, -, -, hsl', -⟩ := k c; rw [hsl', hc1]
          split
          · simp
          · exact x.kept c
        · intro c
          obtain ⟨k1, k2, -⟩ := k c
          rw [k1, k2]
          by_cases ec : c0 = c
          · subst ec
            have r1 : rank d s1 c0 = 2 := by unfold rank; rw [hc1, ite_eq_left (⟨rfl, hc0⟩ : c0 = c0 ∧ c0 < s.cpus.length)]
            have r0 : 3 ≤ rank d s c0 := by
              unfold rank; simp only [hl, hne, ite_false]; split <;> omega
            rw [ite_eq_left (⟨r1, by rw [hlen1]; exact hc0⟩ : rank d s1 c0 = 2 ∧ c0 < s1.cpus.length)]
            exact ⟨by omega, fun w => by omega⟩
          · have hc : s1.cpu c = s.cpu c := by rw [hc1, ite_eq_right (fun z => ec z.1)]
            rw [rank_congr hc hph1, inner_congr hc (fun g _ => by simp [St.op, hops1])]
            split
            · rename_i z; rw [z.1]; exact ⟨by omega, fun w => by omega⟩
            · exact ⟨Nat.le_refl _, fun _ => Nat.le_refl _⟩
      · cases e
    · cases e
  | finish o =>
    obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
    simp only [Cpuq.step] at hu
    split at hu
    · rename_i g
      simp only [Bool.and_eq_true, beq_iff_eq] at g
      obtain ⟨⟨ha, hown⟩, hall⟩ := g
      cases hu
      have ha' : (s.op o).phase = .alive := by simpa [St.isAlive] using ha
      have hne : o ≠ d := by
        intro eo; subst eo
        obtain ⟨tk, htm, htp⟩ := List.countP_pos_iff.1 x.work
        have := List.all_eq_true.1 hall tk htm
        simp only [pendingT, beq_iff_eq] at htp; simp [htp] at this
      have hidle : ∀ i c, ¬((s.task o i).st = .running c ∨ (s.task o i).dying = some c) := by
        intro i c w
        have := all_task hall (by decide) i
        simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at this
        rcases w with w | w
        · rw [w] at this; simp at this
        · rw [w] at this; simp at this
      have ho := s.lt_of_phase o (by rw [ha']; decide)
      have h1 : Inv cfg (s.setPhase o .over) := h.finish ha' hown hidle
      have hph1 : ∀ p, ((s.setPhase o .over).op p).phase = if o = p then .over else (s.op p).phase :=
        fun p => St.phase_setPhase _ _ _ _ ho
      have hdr1 : drainer cfg (s.setPhase o .over) = some d := by
        apply drainer_mono (t := s.setPhase o .over) x.drainer rfl (by rw [hph1, ite_eq_right hne])
        intro p _ hp
        rw [hph1] at hp; split at hp
        · simp at hp
        · exact hp
      have hops1 : ∀ p, ((s.setPhase o .over).op p).tasks = (s.op p).tasks := fun p => St.tasks_setPhase ..
      have k := rank_handout hR hd hcap h1 hdr1 (by rw [hph1, ite_eq_right hne]; exact x.alive)
        (by simp only [St.busy, hops1]; exact x.idle) (by simp only [St.pendingN, hops1]; exact x.work)
      have hops := (handout_order_ops cfg (s.setPhase o .over)).2
      have hord := (handout_order_ops cfg (s.setPhase o .over)).1
      have ex := handout_extras cfg (s.setPhase o .over)
      simp only [extras, Prod.mk.injEq] at ex
      refine ⟨⟨rt, ?_, ?_, ?_, ?_, ?_, ?_, ?_, ?_⟩, ?_⟩
      · show drainer cfg (handout cfg (s.setPhase o .over)) = some d
        rw [drainer_congr hops hord]; exact hdr1
      · show ((handout cfg (s.setPhase o .over)).op d).phase = _
        rw [phase_of_ops hops, hph1, ite_eq_right hne]; exact x.alive
      · show (handout cfg (s.setPhase o .over)).busy d = false
        rw [busy_congr hops]; simp only [St.busy, hops1]; exact x.idle
      · show 0 < (handout cfg (s.setPhase o .over)).pendingN d
        rw [pendingN_congr hops]; simp only [St.pendingN, hops1]; exact x.work
      · show bit (clrBit (handout cfg (s.setPhase o .over)).marks o) d = true
        rw [bit_clrBit (Ne.symm hne), ex.2.1]; exact x.mark
      · show (handout cfg (s.setPhase o .over)).poolLock = none
        rw [ex.1]; exact x.lockFree
      · intro g c hg hne'
        obtain ⟨-, -, hl', -, hgr⟩ := k c
        show ((handout cfg (s.setPhase o .over)).cpu c).lock ≠ some g ∧
          ((handout cfg (s.setPhase o .over)).cpu c).grant ≠ some g
        refine ⟨by rw [hl']; exact (x.others g c hg hne').1, ?_⟩
        rcases hgr with z | z
        · rw [z]; exact (x.others g c hg hne').2
        · rw [z]; intro w; cases w; exact hne' rfl
      · intro c; obtain ⟨-, -, -, hsl', -⟩ := k c
        show ((handout cfg (s.setPhase o .over)).cpu c).slot ≠ _
        rw [hsl']; exact x.kept c
      · intro c
        obtain ⟨k1, k2, -⟩ := k c
        have le1 := rank_setPhase_le (d := d) (s := s) hne c
        have i1 : inner d (s.setPhase o .over) c = inner d s c :=
          inner_congr rfl (fun g _ => hops1 g)
        show rank d (handout cfg (s.setPhase o .over)) c ≤ rank d s c ∧
          (rank d (handout cfg (s.setPhase o .over)) c = rank d s c →
            inner d (handout cfg (s.setPhase o .over)) c ≤ inner d s c)
        rw [k1, k2, i1]
        split
        · rename_i z; rw [z.1] at le1; exact ⟨by omega, fun w => by omega⟩
        · exact ⟨le1, fun _ => Nat.le_refl _⟩
    · cases hu

end Cpuq
