import CpuqModel.Stream

/-!
Two runs of the model with leaving (`Stream.lean`) in which a run waits forever while arrivals
go on. Each is an infinite run, built from a finite cycle of moves repeated forever and checked
by Lean's kernel (`decide +kernel`, no axiom added). The cycle does not come back to the same
state: tickets and the tick count grow. It comes back to the same state up to renaming them
(`Sh`), and the model cannot tell renamed states apart: comparisons of tickets and of start
stamps are all it reads of them (`Sh.stepS_`).

- `same_project_starves`: new runs of the waiting run's own project keep arriving. Every other
  assumption of `run_starts` holds, the backstop included.
- `backstop_starves`: no run of its project arrives, its project is under share at every step and
  the gates are always open, but 4T tasks run at every step: under-share starts at the backstop
  race, and the others always win.
-/

namespace Cpuq.Contest

/-! ## Renaming tickets and start stamps -/

/-- Values below `k` stay; the others move up by `c`. -/
def ren (k c x : Nat) : Nat := if x < k then x else x + c

theorem ren_lt (k c x y : Nat) : ren k c x < ren k c y ↔ x < y := by
  unfold ren; split <;> split <;> omega

theorem ren_comp (k c c' x : Nat) : ren k c' (ren k c x) = ren k (c + c') x := by
  unfold ren
  by_cases hx : x < k
  · simp [hx]
  · have : ¬ x + c < k := by omega
    simp [hx, this]; omega

theorem ren_succ {k c x : Nat} (h : k ≤ x) : ren k c (x + 1) = ren k c x + 1 := by
  unfold ren; split <;> split <;> omega

theorem ren_zero (k x : Nat) : ren k 0 x = x := by unfold ren; split <;> omega

theorem dec_iff {p q : Prop} [Decidable p] [Decidable q] (h : p ↔ q) : decide p = decide q := by
  by_cases hp : p
  · rw [decide_eq_true hp, decide_eq_true (h.1 hp)]
  · rw [decide_eq_false hp, decide_eq_false (fun hq => hp (h.2 hq))]

/-- A map that keeps the order keeps every comparison. -/
theorem mono_dec {f : Nat → Nat} (hf : ∀ a b, f a < f b ↔ a < b) (a b : Nat) :
    decide (f a < f b) = decide (a < b) ∧ decide (f a = f b) = decide (a = b) := by
  refine ⟨dec_iff (hf a b), dec_iff ⟨fun h => ?_, fun h => by rw [h]⟩⟩
  have h1 := hf a b; have h2 := hf b a; omega

structure Ren where
  /-- Tickets below `kt` stay, the others move up by `ct`. -/
  kt : Nat
  ct : Nat
  /-- Tick counts and start stamps below `ks` stay, the others move up by `cs`. -/
  ks : Nat
  cs : Nat

/-- Last start keys: `0` stays, a stamp is renamed. -/
def renK (R : Ren) (v : Nat) : Nat := if v = 0 then 0 else ren R.ks R.cs (v - 1) + 1

theorem renK_lt (R : Ren) (a b : Nat) : renK R a < renK R b ↔ a < b := by
  unfold renK
  have := ren_lt R.ks R.cs (a - 1) (b - 1)
  split <;> split <;> omega

structure RSh (R : Ren) (ak : Bool) (x y : RunSt) : Prop where
  here : y.here = x.here
  pend : y.pend = x.pend
  start : y.start = x.start
  comp : y.comp = x.comp
  blk : y.blk = x.blk
  cap : y.cap = x.cap
  ran : y.ran = x.ran
  ticket : x.here = true → y.ticket = ren R.kt R.ct x.ticket
  last : x.here = true → (x.ran || ak) = true → y.last = ren R.ks R.cs x.last

structure DSh (R : Ren) (x y : DrainSt) : Prop where
  ph : y.ph = x.ph
  busy : y.busy = x.busy
  age : y.age = x.age
  idle : y.idle = x.idle
  ticket : x.ph ≠ .absent → y.ticket = ren R.kt R.ct x.ticket

/-- `t` is `s` with tickets and stamps renamed. -/
structure Sh (cfg : Cfg) (R : Ren) (s t : St) : Prop where
  run : ∀ r < cfg.nr, RSh R cfg.rules.arrivalKey (s.run r) (t.run r)
  drain : ∀ d < cfg.nd, DSh R (s.drain d) (t.drain d)
  gate : t.gate = s.gate
  outside : t.outside = s.outside
  next : t.next = ren R.kt R.ct s.next
  nextk : R.kt ≤ s.next
  now : t.now = ren R.ks R.cs s.now
  nowk : R.ks ≤ s.now

theorem RSh.lk_ {R : Ren} {ak : Bool} {x y : RunSt} (h : RSh R ak x y) (hx : x.here = true) :
    lkOf ak y = renK R (lkOf ak x) := by
  unfold lkOf renK
  rw [h.ran]
  cases e : (x.ran || ak)
  · rfl
  · simp [h.last hx e]

theorem RSh.running_ {R : Ren} {ak : Bool} {x y : RunSt} (h : RSh R ak x y) : y.running = x.running := by
  simp only [RunSt.running, h.start, h.comp, h.blk]

theorem anyLT_congr {n : Nat} {p q : Nat → Bool} (h : ∀ i < n, p i = q i) : anyLT n p = anyLT n q := by
  cases e : anyLT n q
  · exact anyLT_false.2 (fun i hi => by rw [h i hi]; exact anyLT_false.1 e i hi)
  · obtain ⟨i, hi, hq⟩ := anyLT_iff.1 e; exact anyLT_iff.2 ⟨i, hi, by rw [h i hi]; exact hq⟩

theorem find?_congr {p q : Nat → Bool} : ∀ (l : List Nat), (∀ x ∈ l, p x = q x) → l.find? p = l.find? q
  | [], _ => rfl
  | a :: l, h => by
    simp only [List.find?_cons]
    rw [h a (by simp), find?_congr l (fun x hx => h x (by simp [hx]))]

theorem pick_congr {p q : Nat → Bool} {lt lt' : Nat → Nat → Bool} (L : List Nat)
    (hp : ∀ i ∈ L, p i = q i) (hl : ∀ i ∈ L, ∀ j ∈ L, p i = true → p j = true → lt i j = lt' i j) :
    ∀ (l : List Nat) (acc : Option Nat), (∀ x ∈ l, x ∈ L) → (∀ j, acc = some j → j ∈ L ∧ p j = true) →
      l.foldl (pickStep p lt) acc = l.foldl (pickStep q lt') acc
  | [], _, _, _ => rfl
  | i :: l, acc, hs, ha => by
    simp only [List.foldl_cons]
    have hi : i ∈ L := hs i (by simp)
    have e : pickStep p lt acc i = pickStep q lt' acc i := by
      have hq := hp i hi
      cases hpi : p i
      · rw [pickStep_f hpi, pickStep_f (hq ▸ hpi)]
      · have hqi : q i = true := hq ▸ hpi
        cases acc with
        | none => rw [pickStep_none_t hpi, pickStep_none_t hqi]
        | some j =>
          have hl' := hl i hi j (ha j rfl).1 hpi (ha j rfl).2
          cases hij : lt i j
          · rw [pickStep_nlt hij, pickStep_nlt (hl' ▸ hij)]
          · rw [pickStep_lt hpi hij, pickStep_lt hqi (hl' ▸ hij)]
    rw [← e]
    apply pick_congr L hp hl l _ (fun x hx => hs x (by simp [hx]))
    intro j hj
    cases hpi : p i
    · rw [pickStep_f hpi] at hj; exact ha j hj
    · cases acc with
      | none => rw [pickStep_none_t hpi] at hj; cases hj; exact ⟨hi, hpi⟩
      | some j' =>
        cases hij : lt i j'
        · rw [pickStep_nlt hij] at hj; exact ha j hj
        · rw [pickStep_lt hpi hij] at hj; cases hj; exact ⟨hi, hpi⟩

/-! ## Renamed states look alike to the rules -/

section
variable {cfg : Cfg} {R : Ren} {s t : St}

theorem Sh.running_ (h : Sh cfg R s t) {r : Nat} (hr : r < cfg.nr) : (t.run r).running = (s.run r).running :=
  (h.run r hr).running_

theorem Sh.total_ (h : Sh cfg R s t) : total cfg t = total cfg s := rsum_congr (fun _ hr => h.running_ hr)

theorem Sh.projRun_ (h : Sh cfg R s t) (p : Nat) : projRun cfg t p = projRun cfg s p :=
  rsum_congr (fun _ hr => by rw [h.running_ hr])

theorem Sh.taskBusy_ (h : Sh cfg R s t) : taskBusy cfg t = taskBusy cfg s :=
  rsum_congr (fun r hr => (h.run r hr).comp)

theorem Sh.startingN_ (h : Sh cfg R s t) : startingN cfg t = startingN cfg s :=
  rsum_congr (fun r hr => (h.run r hr).start)

theorem Sh.iso_ (h : Sh cfg R s t) : iso cfg t = iso cfg s :=
  rsum_congr (fun d hd => by simp only [isoF, (h.drain d hd).ph])

theorem Sh.drainLoad_ (h : Sh cfg R s t) : drainLoad cfg t = drainLoad cfg s :=
  rsum_congr (fun d hd => by simp only [(h.drain d hd).ph, (h.drain d hd).busy])

theorem Sh.capT_ (h : Sh cfg R s t) : capT cfg t = capT cfg s := by unfold capT; rw [h.iso_]

theorem Sh.busyM_ (h : Sh cfg R s t) : busyM cfg t = busyM cfg s := by
  unfold busyM; rw [h.taskBusy_, h.outside, h.drainLoad_]

theorem Sh.room_ (h : Sh cfg R s t) : room cfg t ↔ room cfg s := by
  unfold room; rw [h.busyM_, h.startingN_, h.capT_]

theorem Sh.activeP_ (h : Sh cfg R s t) (p : Nat) : activeP cfg t p = activeP cfg s p :=
  anyLT_congr (fun i hi => by simp only [(h.run i hi).here, (h.run i hi).pend, h.running_ hi])

theorem Sh.W_ (h : Sh cfg R s t) : W cfg t = W cfg s := rsum_congr (fun p _ => by rw [h.activeP_ p])

theorem Sh.under_ (h : Sh cfg R s t) (r : Nat) : under cfg t r ↔ under cfg s r := by
  unfold under; rw [h.projRun_, h.W_, h.capT_]

theorem Sh.eligible_ (h : Sh cfg R s t) {r : Nat} (hr : r < cfg.nr) : eligible t r = eligible s r := by
  simp only [eligible, (h.run r hr).here, (h.run r hr).pend, (h.run r hr).cap, h.running_ hr]

theorem Sh.emptyWaiter_ (h : Sh cfg R s t) {r : Nat} (hr : r < cfg.nr) : emptyWaiter t r = emptyWaiter s r := by
  simp only [emptyWaiter, (h.run r hr).here, (h.run r hr).pend, h.running_ hr]

theorem Sh.urg_ (h : Sh cfg R s t) {r : Nat} (hr : r < cfg.nr) : urg cfg t r = urg cfg s r := by
  simp only [urg, (h.run r hr).ran]

theorem Sh.key_ (h : Sh cfg R s t) (r : Nat) : key cfg t r = key cfg s r := by
  simp only [key, h.projRun_]

theorem here_of_eligible {s : St} {r : Nat} (e : eligible s r = true) : (s.run r).here = true := by
  simp only [eligible, Bool.and_eq_true] at e; exact e.1.1

theorem Sh.before_ (h : Sh cfg R s t) {i j : Nat} (hi : i < cfg.nr) (hj : j < cfg.nr)
    (ei : (s.run i).here = true) (ej : (s.run j).here = true) : before cfg t i j = before cfg s i j := by
  unfold before
  rw [h.urg_ hi, h.urg_ hj, h.key_ i, h.key_ j, h.running_ hi, h.running_ hj, (h.run i hi).ticket ei,
    (h.run j hj).ticket ej, (mono_dec (ren_lt R.kt R.ct) _ _).1]

theorem Sh.pbefore_ (h : Sh cfg R s t) {i j : Nat} (hi : i < cfg.nr) (hj : j < cfg.nr)
    (ei : (s.run i).here = true) (ej : (s.run j).here = true) : pbefore cfg t i j = pbefore cfg s i j := by
  have ki : lastKey cfg t i = renK R (lastKey cfg s i) := (h.run i hi).lk_ ei
  have kj : lastKey cfg t j = renK R (lastKey cfg s j) := (h.run j hj).lk_ ej
  unfold pbefore
  rw [h.urg_ hi, h.urg_ hj, h.running_ hi, h.running_ hj, ki, kj, (h.run i hi).ticket ei,
    (h.run j hj).ticket ej, (mono_dec (ren_lt R.kt R.ct) _ _).1, (mono_dec (renK_lt R) _ _).1,
    (mono_dec (renK_lt R) _ _).2]

theorem Sh.projFirst_ (h : Sh cfg R s t) {r : Nat} (hr : r < cfg.nr) (er : (s.run r).here = true) :
    projFirst cfg t r = projFirst cfg s r := by
  unfold projFirst
  rw [anyLT_congr (fun i hi => ?_)]
  rw [h.eligible_ hi]
  cases e : eligible s i
  · rfl
  · rw [h.pbefore_ hi hr (here_of_eligible e) er]

theorem Sh.front_ (h : Sh cfg R s t) {r : Nat} (hr : r < cfg.nr) : front cfg t r = front cfg s r := by
  unfold front
  rw [h.eligible_ hr]
  cases e : eligible s r
  · rfl
  · rw [h.projFirst_ hr (here_of_eligible e)]

theorem Sh.head_ (h : Sh cfg R s t) : head cfg t = head cfg s := by
  unfold head pick
  symm
  apply pick_congr (List.range cfg.nr)
    (fun i hi => (h.front_ (List.mem_range.1 hi)).symm)
    (fun i hi j hj ei ej => by
      have h1 : eligible s i = true := by simp only [front, Bool.and_eq_true] at ei; exact ei.1
      have h2 : eligible s j = true := by simp only [front, Bool.and_eq_true] at ej; exact ej.1
      exact (h.before_ (List.mem_range.1 hi) (List.mem_range.1 hj) (here_of_eligible h1)
        (here_of_eligible h2)).symm)
    _ _ (fun x hx => hx) (fun j hj => by cases hj)

theorem Sh.before2_ (h : Sh cfg R s t) {i j : Nat} (hi : i < cfg.nr) (hj : j < cfg.nr)
    (ei : (s.run i).here = true) (ej : (s.run j).here = true) : before2 cfg t i j = before2 cfg s i j := by
  unfold before2
  rw [dec_iff (h.under_ i), dec_iff (h.under_ j), h.before_ hi hj ei ej]

theorem Sh.head2_ (h : Sh cfg R s t) : head2 cfg t = head2 cfg s := by
  unfold head2 pick
  symm
  apply pick_congr (List.range cfg.nr)
    (fun i hi => (h.front_ (List.mem_range.1 hi)).symm)
    (fun i hi j hj ei ej => by
      have h1 : eligible s i = true := by simp only [front, Bool.and_eq_true] at ei; exact ei.1
      have h2 : eligible s j = true := by simp only [front, Bool.and_eq_true] at ej; exact ej.1
      exact (h.before2_ (List.mem_range.1 hi) (List.mem_range.1 hj) (here_of_eligible h1)
        (here_of_eligible h2)).symm)
    _ _ (fun x hx => hx) (fun j hj => by cases hj)

theorem Sh.canStart_ (h : Sh cfg R s t) {r : Nat} (hr : r < cfg.nr) : canStart cfg t r = canStart cfg s r := by
  unfold canStart
  rw [h.eligible_ hr]
  cases e : eligible s r
  · rfl
  · rw [h.gate, h.total_, h.capT_, h.projFirst_ hr (here_of_eligible e), h.head_, h.head2_, dec_iff (h.under_ r),
      dec_iff h.room_]

theorem Sh.olderDrainWaits_ (h : Sh cfg R s t) {d : Nat} (hd : d < cfg.nd) (na : (s.drain d).ph ≠ .absent) :
    olderDrainWaits cfg t d = olderDrainWaits cfg s d := by
  unfold olderDrainWaits
  apply anyLT_congr
  intro e he
  rw [(h.drain e he).ph]
  by_cases w : (s.drain e).ph = .waiting
  · rw [(h.drain e he).ticket (by rw [w]; simp), (h.drain d hd).ticket na,
      (mono_dec (ren_lt R.kt R.ct) _ _).1]
  · simp [w]

theorem Sh.olderEmptyWaits_ (h : Sh cfg R s t) {d : Nat} (hd : d < cfg.nd) (na : (s.drain d).ph ≠ .absent) :
    olderEmptyWaits cfg t d = olderEmptyWaits cfg s d := by
  unfold olderEmptyWaits
  apply anyLT_congr
  intro r hr
  rw [h.emptyWaiter_ hr]
  cases e : emptyWaiter s r
  · rfl
  · have : (s.run r).here = true := by simp only [emptyWaiter, Bool.and_eq_true] at e; exact e.1.1
    rw [(h.run r hr).ticket this, (h.drain d hd).ticket na, (mono_dec (ren_lt R.kt R.ct) _ _).1]

theorem Sh.canDrain_ (h : Sh cfg R s t) {d : Nat} (hd : d < cfg.nd) : canDrain cfg t d = canDrain cfg s d := by
  unfold canDrain
  rw [(h.drain d hd).ph]
  by_cases w : (s.drain d).ph = .waiting
  · have na : (s.drain d).ph ≠ .absent := by rw [w]; simp
    rw [h.gate, h.iso_, h.olderDrainWaits_ hd na, h.olderEmptyWaits_ hd na]
  · simp [w]

theorem Sh.work_ (h : Sh cfg R s t) : work cfg t = work cfg s := by
  have e1 : rsum cfg.nr (fun r => (t.run r).pend) = rsum cfg.nr (fun r => (s.run r).pend) :=
    rsum_congr (fun r hr => (h.run r hr).pend)
  have e2 : rsum cfg.nd (fun d => isWaiting (t.drain d)) = rsum cfg.nd (fun d => isWaiting (s.drain d)) :=
    rsum_congr (fun d hd => by simp only [isWaiting, (h.drain d hd).ph])
  unfold work; rw [e1, e2]

theorem Sh.anyWait_ (h : Sh cfg R s t) : anyWait cfg t = anyWait cfg s := by
  have e1 : anyLT cfg.nr (fun r => decide (0 < (t.run r).pend)) = anyLT cfg.nr (fun r => decide (0 < (s.run r).pend)) :=
    anyLT_congr (fun r hr => by rw [(h.run r hr).pend])
  have e2 : anyLT cfg.nd (fun d => decide ((t.drain d).ph = .waiting)) =
      anyLT cfg.nd (fun d => decide ((s.drain d).ph = .waiting)) :=
    anyLT_congr (fun d hd => by rw [(h.drain d hd).ph])
  unfold anyWait; rw [e1, e2]

theorem Sh.setRun_ (h : Sh cfg R s t) {r : Nat} {x y : RunSt} (hx : RSh R cfg.rules.arrivalKey x y) :
    Sh cfg R (setRun s r x) (setRun t r y) :=
  { h with
    run := fun j hj => by
      by_cases hjr : j = r
      · subst hjr; simpa using hx
      · simpa [hjr] using h.run j hj }

theorem Sh.setDrain_ (h : Sh cfg R s t) {d : Nat} {x y : DrainSt} (hx : DSh R x y) :
    Sh cfg R (setDrain s d x) (setDrain t d y) :=
  { h with
    drain := fun j hj => by
      by_cases hjd : j = d
      · subst hjd; simpa using hx
      · simpa [hjd] using h.drain j hj }
end

/-- Two optional states, both absent or both present and renamed. -/
def OSh (cfg : Cfg) (R : Ren) : Option St → Option St → Prop
  | none, none => True
  | some a, some b => Sh cfg R a b
  | _, _ => False

section
variable {cfg : Cfg} {R : Ren} {s t : St}

theorem Sh.startD_ (h : Sh cfg R s t) {d : Nat} (hd : d < cfg.nd) (hw : (s.drain d).ph = .waiting) :
    Sh cfg R (startD s d) (startD t d) := by
  have x := h.drain d hd
  exact h.setDrain_ ⟨by simp [startDr], by simp [startDr], by simp [startDr], by simp [startDr],
    fun _ => by simp only [startDr]; exact x.ticket (by rw [hw]; simp)⟩

theorem Sh.admit_ (h : Sh cfg R s t) {r : Nat} (hr : r < cfg.nr) : Sh cfg R (admit s r) (admit t r) := by
  have x := h.run r hr
  exact h.setRun_ ⟨by simp [admitR, x.here], by simp [admitR, x.pend], by simp [admitR, x.start],
    by simp [admitR, x.comp], by simp [admitR, x.blk], by simp [admitR, x.cap], by simp [admitR],
    fun e => by simp only [admitR] at e ⊢; exact x.ticket e, fun _ _ => by simp only [admitR]; exact h.now⟩

theorem Sh.pass1_ (h : Sh cfg R s t) : OSh cfg R (pass1 cfg s) (pass1 cfg t) := by
  have e1 : (List.range cfg.nd).find? (canDrain cfg t) = (List.range cfg.nd).find? (canDrain cfg s) :=
    find?_congr _ (fun d hd => h.canDrain_ (List.mem_range.1 hd))
  have e2 : (List.range cfg.nr).find? (canStart cfg t) = (List.range cfg.nr).find? (canStart cfg s) :=
    find?_congr _ (fun r hr => h.canStart_ (List.mem_range.1 hr))
  unfold pass1
  rw [e1, e2]
  cases hd : (List.range cfg.nd).find? (canDrain cfg s) with
  | some d =>
    have hc := List.find?_some hd
    have hm := List.mem_range.1 (List.mem_of_find?_eq_some hd)
    simp only [canDrain, Bool.and_eq_true, decide_eq_true_eq] at hc
    exact h.startD_ hm hc.1.1.1.1
  | none =>
    cases hr : (List.range cfg.nr).find? (canStart cfg s) with
    | none => trivial
    | some r => exact h.admit_ (List.mem_range.1 (List.mem_of_find?_eq_some hr))

theorem Sh.passN_ : ∀ (k : Nat) {s t : St}, Sh cfg R s t → Sh cfg R (passN cfg k s) (passN cfg k t)
  | 0, _, _, h => h
  | k + 1, s, t, h => by
    have h1 := h.pass1_
    simp only [Contest.passN]
    cases e1 : Contest.pass1 cfg s <;> cases e2 : Contest.pass1 cfg t <;> rw [e1, e2] at h1
    · exact h
    · exact h1.elim
    · exact h1.elim
    · exact Sh.passN_ k h1

theorem Sh.pass_ (h : Sh cfg R s t) : Sh cfg R (pass cfg s) (pass cfg t) := by
  unfold Contest.pass; rw [h.work_]; exact h.passN_ _

theorem DSh.tickD_ {R : Ren} {x y : DrainSt} (hx : DSh R x y) (w : Bool) (d : Nat) :
    DSh R (tickD cfg w d x) (tickD cfg w d y) := by
  obtain ⟨h1, h2, h3, h4, h5⟩ := hx
  have ho : overdue cfg w d y ↔ overdue cfg w d x := by simp only [overdue, idleNext, h2, h3, h4]
  unfold tickD
  rw [h1]
  by_cases hs : x.ph = .started
  · have na : x.ph ≠ .absent := by rw [hs]; simp
    rw [ite_t hs, ite_t hs]
    by_cases hov : overdue cfg w d x
    · rw [ite_t hov, ite_t (ho.2 hov)]
      exact ⟨rfl, h2, h3, h4, fun _ => h5 na⟩
    · rw [ite_f hov, ite_f (fun h => hov (ho.1 h))]
      exact ⟨rfl, h2, by simp [h3], by simp [idleNext, h2, h4], fun _ => h5 na⟩
  · rw [ite_f hs, ite_f hs]; exact ⟨h1, h2, h3, h4, h5⟩

/-- A record change that leaves presence, ticket, `ran` and last start alone. -/
theorem RSh.frame {R : Ren} {ak : Bool} {x y x' y' : RunSt} (hx : RSh R ak x y)
    (a1 : x'.here = x.here) (a2 : y'.here = y.here) (a3 : x'.ticket = x.ticket) (a4 : y'.ticket = y.ticket)
    (a5 : x'.ran = x.ran) (a6 : y'.ran = y.ran) (a7 : x'.last = x.last) (a8 : y'.last = y.last)
    (b1 : y'.pend = x'.pend) (b2 : y'.start = x'.start) (b3 : y'.comp = x'.comp) (b4 : y'.blk = x'.blk)
    (b5 : y'.cap = x'.cap) : RSh R ak x' y' :=
  ⟨by rw [a1, a2, hx.here], b1, b2, b3, b4, b5, by rw [a5, a6, hx.ran],
    fun e => by rw [a4, a3]; exact hx.ticket (by rw [← a1]; exact e),
    fun eh er => by rw [a8, a7]; exact hx.last (by rw [← a1]; exact eh) (by rw [← a5]; exact er)⟩

theorem Sh.act_ (h : Sh cfg R s t) (a : Act) : OSh cfg R (act cfg s a) (act cfg t a) := by
  cases a with
  | arrive r =>
    simp only [Contest.act]
    by_cases hr : r < cfg.nr
    · have x := h.run r hr
      rw [x.here]
      by_cases hh : (s.run r).here = false
      · rw [ite_t ⟨hr, hh⟩, ite_t ⟨hr, hh⟩]
        have h2 := h.setRun_ (r := r)
          (x := { here := true, ticket := s.next, pend := (cfg.run r).tasks, cap := max 1 (cfg.run r).cap, last := s.now })
          (y := { here := true, ticket := t.next, pend := (cfg.run r).tasks, cap := max 1 (cfg.run r).cap, last := t.now })
          ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, fun _ => h.next, fun _ _ => h.now⟩
        exact { h2 with
          next := by show t.next + 1 = ren R.kt R.ct (s.next + 1); rw [h.next, ren_succ h.nextk]
          nextk := by show R.kt ≤ s.next + 1; have := h.nextk; omega }
      · rw [ite_f (fun c => hh c.2), ite_f (fun c => hh c.2)]; trivial
    · rw [ite_f (fun c => hr c.1), ite_f (fun c => hr c.1)]; trivial
  | arriveD d =>
    simp only [Contest.act]
    by_cases hd : d < cfg.nd
    · have x := h.drain d hd
      rw [x.ph]
      by_cases ha : (s.drain d).ph = .absent
      · rw [ite_t ⟨hd, ha⟩, ite_t ⟨hd, ha⟩]
        have h2 := h.setDrain_ (d := d) (x := { ph := .waiting, ticket := s.next })
          (y := { ph := .waiting, ticket := t.next }) ⟨rfl, rfl, rfl, rfl, fun _ => h.next⟩
        exact { h2 with
          next := by show t.next + 1 = ren R.kt R.ct (s.next + 1); rw [h.next, ren_succ h.nextk]
          nextk := by show R.kt ≤ s.next + 1; have := h.nextk; omega }
      · rw [ite_f (fun c => ha c.2), ite_f (fun c => ha c.2)]; trivial
    · rw [ite_f (fun c => hd c.1), ite_f (fun c => hd c.1)]; trivial
  | finS r | finC r | finB r | block r | wake r =>
    simp only [Contest.act]
    by_cases hr : r < cfg.nr
    · have x := h.run r hr
      rw [x.start, x.comp, x.blk]
      split
      · exact h.setRun_ (x.frame rfl rfl rfl rfl rfl rfl rfl rfl (by simp [x.pend]) (by simp)
          (by simp) (by simp) (by simp [x.cap]))
      · trivial
    · rw [ite_f (fun c => hr c.1), ite_f (fun c => hr c.1)]; trivial
  | limit r c =>
    simp only [Contest.act]
    by_cases hr : r < cfg.nr
    · have x := h.run r hr
      have hg : (r < cfg.nr ∧ (t.run r).here = true ∧ 0 < c) ↔ (r < cfg.nr ∧ (s.run r).here = true ∧ 0 < c) := by
        rw [x.here]
      by_cases hc : r < cfg.nr ∧ (s.run r).here = true ∧ 0 < c
      · rw [ite_t hc, ite_t (hg.2 hc)]
        exact h.setRun_ (x.frame rfl rfl rfl rfl rfl rfl rfl rfl (by simp [x.pend]) (by simp [x.start])
          (by simp [x.comp]) (by simp [x.blk]) rfl)
      · rw [ite_f hc, ite_f (fun c' => hc (hg.1 c'))]; trivial
    · rw [ite_f (fun c => hr c.1), ite_f (fun c => hr c.1)]; trivial
  | dbusy d b | dend d =>
    simp only [Contest.act]
    by_cases hd : d < cfg.nd
    · have x := h.drain d hd
      rw [x.ph]
      split
      · rename_i hc
        exact h.setDrain_ ⟨by simp, by simp [x.busy], by simp [x.age], by simp [x.idle],
          fun _ => by simp only; exact x.ticket (by rw [hc.2]; simp)⟩
      · trivial
    · rw [ite_f (fun c => hd c.1), ite_f (fun c => hd c.1)]; trivial
  | tick =>
    simp only [Contest.act, tickSt]
    exact {
      run := fun r hr => (h.run r hr).frame rfl rfl rfl rfl rfl rfl rfl rfl (h.run r hr).pend rfl
        (by simp [(h.run r hr).comp, (h.run r hr).start]) (h.run r hr).blk (h.run r hr).cap
      drain := fun d hd => by rw [h.anyWait_]; exact (h.drain d hd).tickD_ _ d
      gate := h.gate
      outside := h.outside
      next := h.next
      nextk := h.nextk
      now := by show t.now + 1 = ren R.ks R.cs (s.now + 1); rw [h.now, ren_succ h.nowk]
      nowk := by show R.ks ≤ s.now + 1; have := h.nowk; omega }
  | gate b => exact { h with gate := rfl }
  | load k => exact { h with outside := rfl }

theorem Sh.stepS_ (h : Sh cfg R s t) (m : Move) : OSh cfg R (stepS cfg s m) (stepS cfg t m) := by
  cases m with
  | act a =>
    simp only [Contest.stepS, step]
    have h1 := h.act_ a
    cases e1 : Contest.act cfg s a <;> cases e2 : Contest.act cfg t a <;> rw [e1, e2] at h1
    · trivial
    · exact h1.elim
    · exact h1.elim
    · exact h1.pass_
  | leave r =>
    simp only [Contest.stepS]
    have hl : leaveOk cfg t r ↔ leaveOk cfg s r := by
      unfold leaveOk
      constructor
      · rintro ⟨hr, a, b, c⟩
        exact ⟨hr, by rw [← (h.run r hr).here]; exact a, by rw [← (h.run r hr).pend]; exact b,
          by rw [← h.running_ hr]; exact c⟩
      · rintro ⟨hr, a, b, c⟩
        exact ⟨hr, by rw [(h.run r hr).here]; exact a, by rw [(h.run r hr).pend]; exact b,
          by rw [h.running_ hr]; exact c⟩
    by_cases hc : leaveOk cfg s r
    · rw [ite_t hc, ite_t (hl.2 hc)]
      exact (h.setRun_ ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, (fun e => by cases e), (fun e _ => by cases e)⟩).pass_
    · rw [ite_f hc, ite_f (fun c => hc (hl.1 c))]; trivial
  | leaveD d =>
    simp only [Contest.stepS]
    by_cases hd : d < cfg.nd
    · rw [(h.drain d hd).ph]
      split
      · exact (h.setDrain_ ⟨rfl, rfl, rfl, rfl, fun e => absurd rfl e⟩).pass_
      · trivial
    · rw [ite_f (fun c => hd c.1), ite_f (fun c => hd c.1)]; trivial

theorem Sh.trans_ {cfg : Cfg} {kt ct ct' ks cs cs' : Nat} {a b c : St}
    (h1 : Sh cfg ⟨kt, ct, ks, cs⟩ a b) (h2 : Sh cfg ⟨kt, ct', ks, cs'⟩ b c) :
    Sh cfg ⟨kt, ct + ct', ks, cs + cs'⟩ a c where
  run r hr := by
    have x := h1.run r hr; have y := h2.run r hr
    exact ⟨by rw [y.here, x.here], by rw [y.pend, x.pend], by rw [y.start, x.start], by rw [y.comp, x.comp],
      by rw [y.blk, x.blk], by rw [y.cap, x.cap], by rw [y.ran, x.ran],
      fun e => by rw [y.ticket (by rw [x.here]; exact e), x.ticket e]; exact ren_comp _ _ _ _,
      fun eh er => by rw [y.last (by rw [x.here]; exact eh) (by rw [x.ran]; exact er), x.last eh er]; exact ren_comp _ _ _ _⟩
  drain d hd := by
    have x := h1.drain d hd; have y := h2.drain d hd
    exact ⟨by rw [y.ph, x.ph], by rw [y.busy, x.busy], by rw [y.age, x.age], by rw [y.idle, x.idle],
      fun e => by rw [y.ticket (by rw [x.ph]; exact e), x.ticket e]; exact ren_comp _ _ _ _⟩
  gate := by rw [h2.gate, h1.gate]
  outside := by rw [h2.outside, h1.outside]
  next := by rw [h2.next, h1.next]; exact ren_comp _ _ _ _
  nextk := h1.nextk
  now := by rw [h2.now, h1.now]; exact ren_comp _ _ _ _
  nowk := h1.nowk

theorem Sh.refl_ {cfg : Cfg} {kt ks : Nat} {s : St} (h1 : kt ≤ s.next) (h2 : ks ≤ s.now) :
    Sh cfg ⟨kt, 0, ks, 0⟩ s s where
  run _ _ := ⟨rfl, rfl, rfl, rfl, rfl, rfl, rfl, fun _ => (ren_zero _ _).symm, fun _ _ => (ren_zero _ _).symm⟩
  drain _ _ := ⟨rfl, rfl, rfl, rfl, fun _ => (ren_zero _ _).symm⟩
  gate := rfl
  outside := rfl
  next := (ren_zero _ _).symm
  nextk := h1
  now := (ren_zero _ _).symm
  nowk := h2
end

/-! ## A cycle repeated forever -/

def allLT (n : Nat) (p : Nat → Bool) : Bool := (List.range n).all p

theorem allLT_iff {n : Nat} {p : Nat → Bool} : allLT n p = true ↔ ∀ i < n, p i = true := by
  simp [allLT]

def RShB (R : Ren) (ak : Bool) (x y : RunSt) : Bool :=
  y.here == x.here && y.pend == x.pend && y.start == x.start && y.comp == x.comp && y.blk == x.blk &&
    y.cap == x.cap && y.ran == x.ran && (!x.here || y.ticket == ren R.kt R.ct x.ticket) &&
    (!x.here || !(x.ran || ak) || y.last == ren R.ks R.cs x.last)

def DShB (R : Ren) (x y : DrainSt) : Bool :=
  y.ph == x.ph && y.busy == x.busy && y.age == x.age && y.idle == x.idle &&
    (x.ph == .absent || y.ticket == ren R.kt R.ct x.ticket)

def ShB (cfg : Cfg) (R : Ren) (s t : St) : Bool :=
  allLT cfg.nr (fun r => RShB R cfg.rules.arrivalKey (s.run r) (t.run r)) && allLT cfg.nd (fun d => DShB R (s.drain d) (t.drain d)) &&
    t.gate == s.gate && t.outside == s.outside && t.next == ren R.kt R.ct s.next && decide (R.kt ≤ s.next) &&
    t.now == ren R.ks R.cs s.now && decide (R.ks ≤ s.now)

instance : DecidableEq DPh := inferInstance

theorem ShB_sound {cfg : Cfg} {R : Ren} {s t : St} (h : ShB cfg R s t = true) : Sh cfg R s t := by
  simp only [ShB, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at h
  obtain ⟨⟨⟨⟨⟨⟨⟨hr, hd⟩, hg⟩, ho⟩, hn⟩, hnk⟩, hw⟩, hwk⟩ := h
  refine ⟨fun r hr' => ?_, fun d hd' => ?_, hg, ho, hn, hnk, hw, hwk⟩
  · have := allLT_iff.1 hr r hr'
    simp only [RShB, Bool.and_eq_true, beq_iff_eq, Bool.or_eq_true, Bool.not_eq_true'] at this
    obtain ⟨⟨⟨⟨⟨⟨⟨⟨a1, a2⟩, a3⟩, a4⟩, a5⟩, a6⟩, a7⟩, a8⟩, a9⟩ := this
    refine ⟨a1, a2, a3, a4, a5, a6, a7, fun e => ?_, fun eh er => ?_⟩
    · rcases a8 with x | x
      · rw [e] at x; cases x
      · exact x
    · rcases a9 with (x | x) | x
      · rw [eh] at x; cases x
      · rw [er] at x; cases x
      · exact x
  · have := allLT_iff.1 hd d hd'
    simp only [DShB, Bool.and_eq_true, beq_iff_eq, Bool.or_eq_true] at this
    obtain ⟨⟨⟨⟨a1, a2⟩, a3⟩, a4⟩, a5⟩ := this
    refine ⟨a1, a2, a3, a4, fun e => ?_⟩
    rcases a5 with x | x
    · exact absurd x e
    · exact x

/-- The move at position `i` of the cycle. -/
def cmv (cyc : List Move) (i : Nat) : Move := cyc.getD (i % cyc.length) (.act .tick)

/-- The run that repeats `cyc` from `s0` (a stuck move would leave the state as it is). -/
def cst (cfg : Cfg) (s0 : St) (cyc : List Move) : Nat → St
  | 0 => s0
  | k + 1 => (stepS cfg (cst cfg s0 cyc k) (cmv cyc k)).getD (cst cfg s0 cyc k)

/-- Walk one round of the cycle: each state meets `P`, each move goes, and the last state is the
first renamed by `R`. -/
def cycGo (cfg : Cfg) (R : Ren) (P : St → Bool) (s0 : St) (cyc : List Move) : Nat → Nat → St → Bool
  | 0, _, s => ShB cfg R s0 s
  | n + 1, i, s => P s && match stepS cfg s (cmv cyc i) with
    | some u => cycGo cfg R P s0 cyc n (i + 1) u
    | none => false

def cycOk (cfg : Cfg) (R : Ren) (P : St → Bool) (s0 : St) (cyc : List Move) : Bool :=
  cycGo cfg R P s0 cyc cyc.length 0 s0

theorem cycGo_sound {cfg : Cfg} {R : Ren} {P : St → Bool} {s0 : St} {cyc : List Move} :
    ∀ n i, i + n = cyc.length → cycGo cfg R P s0 cyc n i (cst cfg s0 cyc i) = true →
      (∀ j, i ≤ j → j < cyc.length → P (cst cfg s0 cyc j) = true ∧
        stepS cfg (cst cfg s0 cyc j) (cmv cyc j) = some (cst cfg s0 cyc (j + 1))) ∧
      ShB cfg R s0 (cst cfg s0 cyc cyc.length) = true
  | 0, i, hi, h => by
    simp only [cycGo] at h
    rw [show i = cyc.length by omega] at h
    exact ⟨fun j h1 h2 => by omega, h⟩
  | n + 1, i, hi, h => by
    simp only [cycGo, Bool.and_eq_true] at h
    obtain ⟨hp, hm⟩ := h
    cases e : stepS cfg (cst cfg s0 cyc i) (cmv cyc i) with
    | none => rw [e] at hm; cases hm
    | some u =>
      rw [e] at hm
      have hu : cst cfg s0 cyc (i + 1) = u := by simp [cst, e]
      rw [← hu] at hm
      obtain ⟨ih1, ih2⟩ := cycGo_sound n (i + 1) (by omega) hm
      refine ⟨fun j h1 h2 => ?_, ih2⟩
      rcases Nat.lt_or_eq_of_le h1 with h1 | h1
      · exact ih1 j h1 h2
      · subst h1; exact ⟨hp, by rw [e, hu]⟩

/-- **A cycle repeated forever is a run.** If one round from a reachable `s0` goes, each state of
it meets `P`, and it ends at `s0` renamed, then repeating it forever is a run of the model, and
each of its states is a state of the first round renamed. -/
theorem cycle_run {cfg : Cfg} {kt ct ks cs : Nat} {P : St → Bool} {s0 : St} {cyc : List Move}
    (hr : ReachS cfg s0) (hne : 0 < cyc.length) (hok : cycOk cfg ⟨kt, ct, ks, cs⟩ P s0 cyc = true) :
    ∃ ρ : RunS cfg, (∀ k, ρ.mv k = cmv cyc k) ∧
      ∀ k, P (cst cfg s0 cyc (k % cyc.length)) = true ∧ ∃ R, Sh cfg R (cst cfg s0 cyc (k % cyc.length)) (ρ.st k) := by
  obtain ⟨hw, hb⟩ := cycGo_sound (cfg := cfg) (R := ⟨kt, ct, ks, cs⟩) (P := P) (s0 := s0) (cyc := cyc)
    cyc.length 0 (by omega) hok
  have hb' := ShB_sound hb
  let L := cyc.length
  -- one move of the repeated cycle copies the first round's move, renamed
  have go : ∀ k, Sh cfg ⟨kt, (k / L) * ct, ks, (k / L) * cs⟩ (cst cfg s0 cyc (k % L)) (cst cfg s0 cyc k) →
      stepS cfg (cst cfg s0 cyc k) (cmv cyc k) = some (cst cfg s0 cyc (k + 1)) ∧
      Sh cfg ⟨kt, (k / L) * ct, ks, (k / L) * cs⟩ (cst cfg s0 cyc (k % L + 1)) (cst cfg s0 cyc (k + 1)) := by
    intro k ih
    have hkL : k % L < L := Nat.mod_lt _ hne
    have hstep := (hw (k % L) (Nat.zero_le _) hkL).2
    have hmv : cmv cyc (k % L) = cmv cyc k := by simp [cmv, L]
    rw [hmv] at hstep
    have hs := ih.stepS_ (cmv cyc k)
    rw [hstep] at hs
    cases e : stepS cfg (cst cfg s0 cyc k) (cmv cyc k) with
    | none => rw [e] at hs; exact hs.elim
    | some t' =>
      rw [e] at hs
      have ht : cst cfg s0 cyc (k + 1) = t' := by simp [cst, e]
      rw [ht]
      exact ⟨rfl, hs⟩
  have rel : ∀ k, Sh cfg ⟨kt, (k / L) * ct, ks, (k / L) * cs⟩ (cst cfg s0 cyc (k % L)) (cst cfg s0 cyc k) := by
    intro k
    induction k with
    | zero => simpa [cst] using Sh.refl_ (cfg := cfg) (s := s0) hb'.nextk hb'.nowk
    | succ k ih =>
      have hs := (go k ih).2
      have hdm := Nat.div_add_mod k L
      have hkL : k % L < L := Nat.mod_lt _ hne
      have hk : k + 1 = (k % L + 1) + L * (k / L) := by omega
      have m1 : (k + 1) % L = (k % L + 1) % L := by rw [hk, Nat.add_mul_mod_self_left]
      have m2 : (k + 1) / L = (k % L + 1) / L + k / L := by rw [hk, Nat.add_mul_div_left _ _ hne]
      by_cases hlast : k % L + 1 < L
      · rw [m1, m2, Nat.mod_eq_of_lt hlast, Nat.div_eq_of_lt hlast, Nat.zero_add]
        exact hs
      · have hL : k % L + 1 = L := by omega
        rw [m1, m2, hL, Nat.mod_self, Nat.div_self hne]
        rw [hL] at hs
        have := hb'.trans_ hs
        rw [show (1 + k / L) * ct = ct + k / L * ct by rw [Nat.add_mul, Nat.one_mul],
          show (1 + k / L) * cs = cs + k / L * cs by rw [Nat.add_mul, Nat.one_mul]]
        exact this
  refine ⟨⟨cst cfg s0 cyc, cmv cyc, hr, fun k => (go k (rel k)).1⟩, fun _ => rfl, fun k => ⟨?_, _, rel k⟩⟩
  exact (hw (k % L) (Nat.zero_le _) (Nat.mod_lt _ hne)).1

/-! ## Reading a repeated cycle -/

def runMoves (cfg : Cfg) : St → List Move → Option St
  | s, [] => some s
  | s, m :: ms => (stepS cfg s m).bind (runMoves cfg · ms)

theorem runMoves_reach {cfg : Cfg} : ∀ {s t : St} (ms : List Move), ReachS cfg s → runMoves cfg s ms = some t →
    ReachS cfg t
  | _, _, [], r, e => by simp only [runMoves, Option.some.injEq] at e; subst e; exact r
  | s, _, m :: ms, r, e => by
    simp only [runMoves] at e
    cases hm : stepS cfg s m with
    | none => rw [hm] at e; cases e
    | some u => rw [hm] at e; exact runMoves_reach ms (.step m r hm) e

/-- `m` ends a task of run `b`. -/
def finB (b : Nat) : Move → Bool
  | .act (.finS x) | .act (.finC x) | .act (.finB x) => x == b
  | _ => false

theorem finB_sound {b : Nat} {m : Move} (h : finB b m = true) : finOfM b m := by
  cases m with
  | act a => cases a <;> simp_all [finB, finOfM, finOf]
  | leave _ | leaveD _ => simp [finB] at h

/-- `m` is the arrival of a run of project `p`. -/
def arrB (cfg : Cfg) (p : Nat) : Move → Bool
  | .act (.arrive b) => (cfg.run b).proj == p
  | _ => false

theorem isTick_eq {m : Move} (h : m.isTick = true) : m = .act .tick := by
  cases m with
  | act a => cases a <;> simp_all [Move.isTick, Act.isTick]
  | leave _ | leaveD _ => simp [Move.isTick] at h

theorem cmv_mem {cyc : List Move} (hne : 0 < cyc.length) (k : Nat) : cmv cyc k ∈ cyc := by
  have h := Nat.mod_lt k hne
  simp [cmv, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem h]

/-- A move of the cycle comes again and again. -/
theorem hits {cyc : List Move} (hne : 0 < cyc.length) {p : Move → Bool} (h : cyc.any p = true) :
    ∀ k, ∃ k' ≥ k, p (cmv cyc k') = true := by
  obtain ⟨x, hx, hp⟩ := List.any_eq_true.1 h
  obtain ⟨j, hj, e⟩ := List.mem_iff_getElem.1 hx
  intro k
  have hdm := Nat.div_add_mod k cyc.length
  have hkL := Nat.mod_lt k hne
  refine ⟨(k / cyc.length + 1) * cyc.length + j, ?_, ?_⟩
  · rw [Nat.add_mul, Nat.one_mul]
    have : cyc.length * (k / cyc.length) = k / cyc.length * cyc.length := Nat.mul_comm _ _
    omega
  · have hm : ((k / cyc.length + 1) * cyc.length + j) % cyc.length = j := by
      rw [Nat.add_comm, Nat.add_mul_mod_self_right, Nat.mod_eq_of_lt hj]
    simp only [cmv, hm, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hj, Option.getD_some, e]
    exact hp

/-! ## Counterexample 1: new runs of the waiting run's own project -/

/-- 1 CPU, one project: run 0 (two tasks, `-c 1`) and two slots for one-task runs. -/
def sameCfg : Cfg :=
  { pool := 1, drainMax := 0,
    runs := [{ proj := 0, tasks := 2, cap := 1 }, { proj := 0, tasks := 1, cap := 1 },
             { proj := 0, tasks := 1, cap := 1 }] }

/-- Run 0 starts and its task ends; a new run, never started, goes first. -/
def samePre : List Move := [.act (.arrive 0), .act .tick, .act (.arrive 1), .act (.finC 0)]

/-- Each round: a new run arrives while the other's task runs; that task ends, the new run (never
started) goes before run 0 and starts; the finished run leaves; a tick. -/
def sameCyc : List Move :=
  [.act .tick, .act (.arrive 2), .act (.finC 1), .leave 1,
   .act .tick, .act (.arrive 1), .act (.finC 2), .leave 2]

def sameS0 : St := (runMoves sameCfg init samePre).getD init

def sameP (s : St) : Bool :=
  (s.run 0).here && (s.run 0).pend == 1 && eligible s 0 && s.gate &&
    decide (total sameCfg s < 4 * capT sameCfg s) &&
    allLT sameCfg.nr (fun b => (s.run b).running == 0 || sameCyc.any (finB b))

theorem same_ok : (runMoves sameCfg init samePre).isSome = true ∧
    cycOk sameCfg ⟨1, 2, 1, 2⟩ sameP sameS0 sameCyc = true ∧ sameCyc.any Move.isTick = true ∧
    sameCyc.any (arrB sameCfg 0) = true := by
  decide +kernel

/-- **New runs of its own project starve a waiting run.** An infinite run of the model: run 0
waits with a task to start and its `-c` allowing it, and never starts it. Every task ends, ticks
keep coming, the gates are always open and fewer than 4T tasks run at every step: every
assumption of `run_starts` holds but one, and runs of run 0's project keep arriving. Each new run
has never started, so it goes before run 0, which has. -/
theorem same_project_starves : ∃ ρ : RunS sameCfg,
    (∀ k, ((ρ.st k).run 0).here = true ∧ ((ρ.st k).run 0).pend = 1 ∧ eligible (ρ.st k) 0 = true) ∧
    (∀ k b, b < sameCfg.nr → 0 < ((ρ.st k).run b).running → ∃ k' ≥ k, finOfM b (ρ.mv k')) ∧
    (∀ k, ∃ k' ≥ k, ρ.mv k' = .act .tick) ∧
    (∀ k, (ρ.st k).gate = true ∧ total sameCfg (ρ.st k) < 4 * capT sameCfg (ρ.st k)) ∧
    (∀ k, ∃ k' ≥ k, ∃ b, ρ.mv k' = .act (.arrive b) ∧ (sameCfg.run b).proj = (sameCfg.run 0).proj) := by
  obtain ⟨h1, h2, h3, h4⟩ := same_ok
  obtain ⟨t, ht⟩ := Option.isSome_iff_exists.1 h1
  have hs0 : sameS0 = t := by simp [sameS0, ht]
  have hr : ReachS sameCfg sameS0 := by rw [hs0]; exact runMoves_reach _ .init ht
  have hne : 0 < sameCyc.length := by decide
  obtain ⟨ρ, hmv, hk⟩ := cycle_run hr hne h2
  have get : ∀ k, ∃ R, Sh sameCfg R (cst sameCfg sameS0 sameCyc (k % sameCyc.length)) (ρ.st k) ∧
      sameP (cst sameCfg sameS0 sameCyc (k % sameCyc.length)) = true :=
    fun k => let ⟨hp, R, h⟩ := hk k; ⟨R, h, hp⟩
  have h0 : 0 < sameCfg.nr := by decide
  refine ⟨ρ, fun k => ?_, fun k b hb hrun => ?_, fun k => ?_, fun k => ?_, fun k => ?_⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [sameP, Bool.and_eq_true, beq_iff_eq] at hp
    exact ⟨by rw [(h.run 0 h0).here]; exact hp.1.1.1.1.1,
      by rw [(h.run 0 h0).pend]; exact hp.1.1.1.1.2, by rw [h.eligible_ h0]; exact hp.1.1.1.2⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [sameP, Bool.and_eq_true] at hp
    have := allLT_iff.1 hp.2 b hb
    rw [← h.running_ hb] at this
    simp only [Bool.or_eq_true, beq_iff_eq] at this
    rcases this with x | x
    · omega
    · obtain ⟨k', hk', hf⟩ := hits hne x k
      exact ⟨k', hk', by rw [hmv]; exact finB_sound hf⟩
  · obtain ⟨k', hk', hf⟩ := hits hne h3 k
    exact ⟨k', hk', by rw [hmv]; exact isTick_eq hf⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [sameP, Bool.and_eq_true, decide_eq_true_eq] at hp
    exact ⟨by rw [h.gate]; exact hp.1.1.2, by rw [h.total_, h.capT_]; exact hp.1.2⟩
  · obtain ⟨k', hk', hf⟩ := hits hne h4 k
    rw [← hmv] at hf
    refine ⟨k', hk', ?_⟩
    revert hf
    cases ρ.mv k' with
    | act a => cases a <;> simp [arrB, sameCfg, Cfg.run]
    | leave _ | leaveD _ => simp [arrB]

/-! ## Counterexample 2: the backstop race -/

/-- 1 CPU, five projects: runs 0 … 7 are two slots for each of projects 0 … 3, one-task runs;
run 8, of project 4, waits. -/
def raceCfg : Cfg :=
  { pool := 1, drainMax := 0,
    runs := [{ proj := 0 }, { proj := 0 }, { proj := 1 }, { proj := 1 },
             { proj := 2 }, { proj := 2 }, { proj := 3 }, { proj := 3 }, { proj := 4 }] }

/-- Run 8 arrives first (the gates closed), then a run of each other project and a second one
behind it; the gates open: each of projects 0 … 3 starts one task (under share), 4 = 4T run, and
run 8 waits at the backstop. -/
def racePre : List Move :=
  [.act (.gate false), .act (.arrive 8), .act (.arrive 0), .act (.arrive 2), .act (.arrive 4),
   .act (.arrive 6), .act (.arrive 1), .act (.arrive 3), .act (.arrive 5), .act (.arrive 7),
   .act (.gate true)]

/-- Each task that ends frees a place under 4T. Run 8 and the next run of the same project both
may take it (both under share); the other, first in the pass, takes it. The finished run leaves
and its slot arrives again. -/
def raceCyc : List Move :=
  [.act (.finS 0), .leave 0, .act (.arrive 0), .act (.finS 2), .leave 2, .act (.arrive 2),
   .act (.finS 4), .leave 4, .act (.arrive 4), .act (.finS 6), .leave 6, .act (.arrive 6),
   .act .tick,
   .act (.finC 1), .leave 1, .act (.arrive 1), .act (.finC 3), .leave 3, .act (.arrive 3),
   .act (.finC 5), .leave 5, .act (.arrive 5), .act (.finC 7), .leave 7, .act (.arrive 7)]

def raceS0 : St := (runMoves raceCfg init racePre).getD init

def raceP (s : St) : Bool :=
  (s.run 8).here && (s.run 8).pend == 1 && eligible s 8 && s.gate && decide (under raceCfg s 8) &&
    decide (4 * capT raceCfg s ≤ total raceCfg s) &&
    allLT raceCfg.nr (fun b => (s.run b).running == 0 || raceCyc.any (finB b))

theorem race_ok : (runMoves raceCfg init racePre).isSome = true ∧
    cycOk raceCfg ⟨1, 8, 0, 1⟩ raceP raceS0 raceCyc = true ∧ raceCyc.any Move.isTick = true ∧
    raceCyc.all (fun m => !arrB raceCfg 4 m) = true := by
  decide +kernel

/-- **The backstop race starves a waiting run.** An infinite run of the model: run 8 waits with a
task to start, its `-c` allowing it, its project under share at every step, the gates always
open, no run of its project arriving; every task ends and ticks keep coming. It never starts:
4T tasks run at every step, and each place that frees under 4T is taken by another project's
run, also under share, that the pass reaches first. Every assumption of `run_starts` holds but
the backstop's (again and again fewer than 4T running while the gates are open). -/
theorem backstop_starves : ∃ ρ : RunS raceCfg,
    (∀ k, ((ρ.st k).run 8).here = true ∧ ((ρ.st k).run 8).pend = 1 ∧ eligible (ρ.st k) 8 = true ∧
      under raceCfg (ρ.st k) 8 ∧ (ρ.st k).gate = true ∧ 4 * capT raceCfg (ρ.st k) ≤ total raceCfg (ρ.st k)) ∧
    (∀ k b, b < raceCfg.nr → 0 < ((ρ.st k).run b).running → ∃ k' ≥ k, finOfM b (ρ.mv k')) ∧
    (∀ k, ∃ k' ≥ k, ρ.mv k' = .act .tick) ∧
    (∀ k b, ρ.mv k = .act (.arrive b) → (raceCfg.run b).proj ≠ (raceCfg.run 8).proj) := by
  obtain ⟨h1, h2, h3, h4⟩ := race_ok
  obtain ⟨t, ht⟩ := Option.isSome_iff_exists.1 h1
  have hs0 : raceS0 = t := by simp [raceS0, ht]
  have hr : ReachS raceCfg raceS0 := by rw [hs0]; exact runMoves_reach _ .init ht
  have hne : 0 < raceCyc.length := by decide
  obtain ⟨ρ, hmv, hk⟩ := cycle_run hr hne h2
  have get : ∀ k, ∃ R, Sh raceCfg R (cst raceCfg raceS0 raceCyc (k % raceCyc.length)) (ρ.st k) ∧
      raceP (cst raceCfg raceS0 raceCyc (k % raceCyc.length)) = true :=
    fun k => let ⟨hp, R, h⟩ := hk k; ⟨R, h, hp⟩
  have h8 : 8 < raceCfg.nr := by decide
  refine ⟨ρ, fun k => ?_, fun k b hb hrun => ?_, fun k => ?_, fun k b hb => ?_⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [raceP, Bool.and_eq_true, beq_iff_eq, decide_eq_true_eq] at hp
    exact ⟨by rw [(h.run 8 h8).here]; exact hp.1.1.1.1.1.1, by rw [(h.run 8 h8).pend]; exact hp.1.1.1.1.1.2,
      by rw [h.eligible_ h8]; exact hp.1.1.1.1.2, (h.under_ 8).2 hp.1.1.2,
      by rw [h.gate]; exact hp.1.1.1.2, by rw [h.total_, h.capT_]; exact hp.1.2⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [raceP, Bool.and_eq_true] at hp
    have := allLT_iff.1 hp.2 b hb
    rw [← h.running_ hb] at this
    simp only [Bool.or_eq_true, beq_iff_eq] at this
    rcases this with x | x
    · omega
    · obtain ⟨k', hk', hf⟩ := hits hne x k
      exact ⟨k', hk', by rw [hmv]; exact finB_sound hf⟩
  · obtain ⟨k', hk', hf⟩ := hits hne h3 k
    exact ⟨k', hk', by rw [hmv]; exact isTick_eq hf⟩
  · have hm := List.all_eq_true.1 h4 _ (cmv_mem hne k)
    rw [← hmv, hb] at hm
    have e8 : (raceCfg.run 8).proj = 4 := by decide
    rw [e8]
    simpa [arrB] using hm

/-! ## On the fixed rules the waiting run starts -/

/-- A configuration with the two no-starvation fixes (`Rules.nostarve`). -/
def withFixes (c : Cfg) : Cfg := { c with rules := .nostarve }

/-- **Fix 1 at work.** The prefix of `same_project_starves`: under the rules as shipped run 0
waits, the newcomer having gone first; with the fixes run 0, whose last start is older than the
newcomer's arrival, starts its task. -/
theorem same_fixed : ((runMoves sameCfg init samePre).map fun s => (s.run 0).pend) = some 1 ∧
    ((runMoves (withFixes sameCfg) init samePre).map fun s => (s.run 0).pend) = some 0 := by
  decide +kernel

/-- The backstop race with run 8 arriving last, its ticket the newest at the start. -/
def racePreLate : List Move :=
  [.act (.gate false), .act (.arrive 0), .act (.arrive 2), .act (.arrive 4), .act (.arrive 6),
   .act (.arrive 1), .act (.arrive 3), .act (.arrive 5), .act (.arrive 7), .act (.arrive 8),
   .act (.gate true)]

/-- **Fix 2 at work.** Under the rules as shipped run 8 waits through a whole round of the race;
with the fixes the places freed go in line: first to the four runs older than run 8, then, at the
fifth, to run 8 (the next runs of those projects arrived after it). -/
theorem race_fixed : ((runMoves raceCfg init (racePreLate ++ raceCyc)).map fun s => (s.run 8).pend) = some 1 ∧
    ((runMoves (withFixes raceCfg) init (racePreLate ++ raceCyc.take 14)).map fun s => (s.run 8).pend) = some 0 := by
  decide +kernel

/-- Both counterexample configurations satisfy `run_starts_fixed`'s conditions on the
configuration: with the fixes, every run of them in which no urgent run arrives, every task ends,
a tick passes and the gates reopen starts every waiting run's task. -/
theorem fixes_apply : (withFixes sameCfg).rules.arrivalKey = true ∧ (withFixes sameCfg).rules.oneLine = true ∧
    (withFixes sameCfg).drainMax < (withFixes sameCfg).pool ∧
    (withFixes raceCfg).rules.arrivalKey = true ∧ (withFixes raceCfg).rules.oneLine = true ∧
    (withFixes raceCfg).drainMax < (withFixes raceCfg).pool := by decide

/-! ## Axioms: only the standard three -/

/-- info: 'Cpuq.Contest.same_project_starves' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms same_project_starves

/-- info: 'Cpuq.Contest.backstop_starves' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms backstop_starves

/-- info: 'Cpuq.Contest.race_fixed' depends on axioms: [propext] -/
#guard_msgs in #print axioms race_fixed

end Cpuq.Contest
