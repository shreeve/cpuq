/-
The line under the code's rules: a waiter that holds nothing is never blocked.

`zero_head_unblocked`: in every reachable state under the rules of the code as released
(`LineRules`), when no `cpuq drain` lives and the head of the line holds nothing, a CPU is
unlocked (a hand-out pass gives it, or its grant is being taken), or a CPU is being emptied, or
some holder may start emptying one for the head (`canDrain`). Before 0.30.3 this was false: an
urgent operation holding nothing again was urgent again, so it could not give, and a holder of
another project could not give either (README, Finding 7). What makes it true is `urgentOnce`:
every holder has been served (`ServedOk`), so a holder that gives is never urgent again.
-/
import CpuqModel.Drains

namespace Cpuq

attribute [-simp] List.getD_eq_getElem?_getD

/-! ### Every holder has been served -/

theorem bit_setBit_self (n o : Nat) : bit (setBit n o) o = true := by
  simp [bit, setBit, Nat.testBit_or]

theorem bit_setBit_of {n o p : Nat} (h : bit n p = true) : bit (setBit n o) p = true := by
  simp only [bit, setBit, Nat.testBit_or] at *; simp [h]

/-- From `s` to `t`: an operation served stays served, and each lock of `t` was `s`'s or is held
by an operation served in `t`. -/
def Grows (s t : St) : Prop :=
  (∀ o, bit s.served o = true → bit t.served o = true) ∧
  ∀ c o, (t.cpu c).lock = some o → (s.cpu c).lock = some o ∨ bit t.served o = true

theorem Grows.trans {s t u : St} (a : Grows s t) (b : Grows t u) : Grows s u := by
  refine ⟨fun o h => b.1 o (a.1 o h), fun c o h => ?_⟩
  rcases b.2 c o h with h' | h'
  · rcases a.2 c o h' with h'' | h''
    · exact .inl h''
    · exact .inr (b.1 o h'')
  · exact .inr h'

theorem Grows.congr {s t u : St} (h : Grows s u) (hc : t.cpus = u.cpus) (hs : t.served = u.served) :
    Grows s t := by
  refine ⟨fun o ho => by rw [hs]; exact h.1 o ho, fun c o ho => ?_⟩
  have e : t.cpu c = u.cpu c := by simp [St.cpu, hc]
  rw [e] at ho; rw [hs]; exact h.2 c o ho

/-- No new lock, and the served bits kept. -/
theorem Grows.locks {s t : St} (hs : t.served = s.served)
    (h : ∀ c, (t.cpu c).lock = none ∨ (t.cpu c).lock = (s.cpu c).lock) : Grows s t := by
  refine ⟨fun o ho => by rw [hs]; exact ho, fun c o ho => ?_⟩
  rcases h c with e | e
  · rw [e] at ho; cases ho
  · exact .inl (e ▸ ho)

theorem Grows.same {s t : St} (hs : t.served = s.served) (hc : t.cpus = s.cpus) : Grows s t :=
  Grows.locks hs (fun c => .inr (by simp [St.cpu, hc]))

theorem Grows.setCpu {s : St} {c : Nat} {x : Cpu} (hx : x.lock = none ∨ x.lock = (s.cpu c).lock) :
    Grows s (s.setCpu c x) :=
  Grows.locks rfl (fun c' => by
    rw [St.cpu_setCpu]; split
    · rename_i h; obtain ⟨rfl, -⟩ := h; exact hx
    · exact .inr rfl)

theorem Grows.mapped {s t : St} {f : Cpu → Cpu} (hc : t.cpus = s.cpus.map f) (hs : t.served = s.served)
    (hf : ∀ x, (f x).lock = none ∨ (f x).lock = x.lock) (h0 : f {} = {}) : Grows s t :=
  Grows.locks hs (fun c => by
    show (t.cpus.getD c {}).lock = none ∨ (t.cpus.getD c {}).lock = (s.cpus.getD c {}).lock
    rw [hc, getD_map s.cpus f c {} {} h0]; exact hf _)

theorem Grows.setCpu' {s t : St} {c : Nat} {x : Cpu} (hc : t.cpus = s.cpus.set c x)
    (hs : t.served = s.served) (hx : x.lock = none ∨ x.lock = (s.cpu c).lock) : Grows s t :=
  Grows.congr (Grows.setCpu hx) hc hs

theorem grows_grantOne (cfg : Cfg) (s : St) (c : Nat) : Grows s (grantOne cfg s c) := by
  unfold grantOne; split
  · split
    · exact Grows.setCpu (.inr rfl)
    · exact Grows.same rfl rfl
  · exact Grows.same rfl rfl

theorem grows_handoutOver (cfg : Cfg) : ∀ (s : St) (cs : List Nat), Grows s (handoutOver cfg s cs)
  | _, [] => Grows.same rfl rfl
  | s, c :: cs => (grows_grantOne cfg s c).trans (grows_handoutOver cfg _ cs)

theorem grows_handout (cfg : Cfg) (s : St) : Grows s (handout cfg s) := grows_handoutOver cfg s _

theorem Grows.handout {cfg : Cfg} {s u : St} (h : Grows s u) : Grows s (handout cfg u) :=
  h.trans (grows_handout cfg u)

theorem grows_releaseAll (s : St) (o : Nat) : Grows s (releaseAll s o) :=
  Grows.mapped (f := fun x => if ownsC o x then {} else x) rfl rfl
    (fun x => by split <;> simp) (by simp [ownsC_empty])

/-- Every operation holding a CPU's flock has been served. -/
def ServedOk (s : St) : Prop := ∀ c o, (s.cpu c).lock = some o → bit s.served o = true

theorem ServedOk.grows {s t : St} (h : ServedOk s) (g : Grows s t) : ServedOk t := fun c o ho =>
  (g.2 c o ho).elim (fun h' => g.1 o (h c o h')) id

theorem ServedOk.same {s t : St} (h : ServedOk s) (e : Same s t) : ServedOk t :=
  h.grows (Grows.same e.2.2.2.2 e.1)

section
variable {cfg : Cfg} (hu : cfg.rules.urgentOnce = true)
include hu

theorem grows_takeTok (s : St) (o c : Nat) : Grows s (takeTok cfg s o c) := by
  have hs : (takeTok cfg s o c).served = setBit s.served o := by
    unfold takeTok serve; simp only [hu, ite_true]; split <;> rfl
  have hc : (takeTok cfg s o c).cpus =
      s.cpus.set c { lock := some o, grant := none, slot := some { owner := o } } := by
    unfold takeTok; split <;> rfl
  refine ⟨fun p hp => by rw [hs]; exact bit_setBit_of hp, fun c' p hp => ?_⟩
  have e : (takeTok cfg s o c).cpu c' =
      (s.cpus.set c { lock := some o, grant := none, slot := some { owner := o } }).getD c' {} := by
    simp [St.cpu, hc]
  rw [e, getD_set] at hp
  split at hp
  · simp only [Option.some.injEq] at hp; subst hp; right; rw [hs]; exact bit_setBit_self ..
  · exact .inl hp

theorem grows_tryOnce (s : St) (o : Nat) : Grows s (tryOnce cfg s o) := by
  unfold tryOnce; split
  · split
    · exact grows_takeTok hu ..
    · exact Grows.same rfl rfl
  · exact Grows.same rfl rfl

theorem grows_reap (s : St) (o i : Nat) (ok : Bool) : Grows s (reap cfg s o i ok) := by
  unfold reap
  exact (Grows.same (t := s.setTask o i _) rfl rfl).trans (grows_tryOnce hu _ o)

theorem step_grows {s t : St} {a : Act} (e : step cfg s a = some t) : Grows s t := by
  cases a with
  | arrive o =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact Grows.handout (Grows.same rfl rfl)
    · cases e
  | exit o i ok =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; exact grows_reap hu ..
      · split at e
        · cases e; exact Grows.same rfl rfl
        · cases e
    · cases e
  | timeout o i =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; exact Grows.same rfl rfl
      · cases e
    · cases e
  | gone o i =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact Grows.same rfl rfl
    · cases e
  | refill o c =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; exact Grows.same rfl rfl
      · cases e
    · cases e
  | release o c =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e
        exact Grows.handout (Grows.setCpu' rfl rfl (.inl rfl))
      · cases e
    · cases e
  | handout =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact grows_handout ..
    · cases e
  | accept o c =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact grows_takeTok hu ..
    · cases e
  | drain o c =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact Grows.setCpu' rfl rfl (.inr rfl)
    · cases e
  | undrain o c =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact Grows.setCpu' rfl rfl (.inr rfl)
    · cases e
  | consolidate o i d =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; exact Grows.same rfl rfl
      · cases e
    · cases e
  | kill o =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact Grows.handout ((grows_releaseAll s o).trans (Grows.same rfl rfl))
    · cases e
  | crash o =>
    simp only [Cpuq.step] at e; split at e
    · cases e
      exact Grows.mapped (f := fun x => if x.lock == some o then { x with lock := none } else x) rfl rfl
        (fun x => by split <;> simp) (by simp)
    · cases e
  | stop o =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact Grows.handout ((grows_releaseAll s o).trans (Grows.same rfl rfl))
    · cases e
  | cont o =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact Grows.same rfl rfl
    · cases e
  | finish o =>
    simp only [Cpuq.step] at e; split at e
    · cases e; exact Grows.handout (Grows.same rfl rfl)
    · cases e
  | enter o | mark o | tstp o | halt o | tick => simp [Cpuq.step] at e

theorem ServedOk.move {s t : St} {a : Act} (h : ServedOk s) (e : move cfg s a = some t) :
    ServedOk t := by
  rcases move_cases e with x | ⟨b, u, hb, x⟩
  · exact h.same x
  · exact (h.grows (step_grows hu hb)).same x

theorem Reach.servedOk {s : St} (r : Reach cfg s) : ServedOk s := by
  induction r with
  | init => intro c o hl; simp [St.cpu, Cpuq.init, List.getD_eq_getElem?_getD, List.getElem?_replicate] at hl
            split at hl <;> simp at hl
  | step a _ e ih => exact ih.move hu e

end

/-! ### Who goes ahead after a drain -/

theorem findIdx_app_lt {L : List Nat} {h g : Nat} (hm : h ∈ L) (hg : g ∉ L) :
    (L ++ [g]).findIdx (· == h) < (L ++ [g]).findIdx (· == g) := by
  induction L with
  | nil => cases hm
  | cons x L ih =>
    have hxg : x ≠ g := fun e => hg (e ▸ List.mem_cons_self ..)
    by_cases hx : x = h
    · subst hx; simp [List.findIdx_cons, hxg]
    · have hm' : h ∈ L := by
        rcases List.mem_cons.1 hm with e | e
        · exact absurd e.symm hx
        · exact e
      have := ih hm' (fun e => hg (List.mem_cons_of_mem _ e))
      have e1 : (x == h) = false := by simp [hx]
      have e2 : (x == g) = false := by simp [hxg]
      simp only [List.cons_append, List.findIdx_cons, e1, e2]
      simp only [Bool.false_eq_true, ite_false]
      omega

/-- `h`, holding nothing, goes ahead of `g`: `g` is not urgent, `h`'s project holds no more for
its weight than `g`'s, and `h` has the older ticket. -/
theorem ahead_of {cfg : Cfg} {u : St} {h g : Nat} (hz : cfg.rules.zeroFirst = true)
    (hug : urgentFirst cfg u g = false) (hh : eff cfg u h = 0)
    (hp : projEff cfg u (cfg.op h).proj * cfg.w (cfg.op g).proj ≤
      projEff cfg u (cfg.op g).proj * cfg.w (cfg.op h).proj)
    (hi : u.order.findIdx (· == h) < u.order.findIdx (· == g)) : ahead cfg u h g = true := by
  unfold ahead before
  by_cases hu : urgentFirst cfg u h = true
  · simp [hu, hug]
  · simp only [Bool.not_eq_true] at hu
    by_cases he : eff cfg u g = 0
    · by_cases hq : projEff cfg u (cfg.op h).proj * cfg.w (cfg.op g).proj =
          projEff cfg u (cfg.op g).proj * cfg.w (cfg.op h).proj
      · simp [hu, hug, hz, hh, he, hq, hi]
      · have : projEff cfg u (cfg.op h).proj * cfg.w (cfg.op g).proj <
            projEff cfg u (cfg.op g).proj * cfg.w (cfg.op h).proj := Nat.lt_of_le_of_ne hp hq
        simp [hu, hug, hz, hh, he, hq, this]
    · simp [hu, hug, hz, hh, he]

theorem projEff_zero {cfg : Cfg} {u : St} {p : Nat} (h : ∀ o, (cfg.op o).proj = p → eff cfg u o = 0) :
    projEff cfg u p = 0 := by
  unfold projEff
  suffices ∀ (l : List Nat) (a : Nat),
      l.foldl (fun acc o => if (cfg.op o).proj == p then acc + eff cfg u o else acc) a = a from
    this _ 0
  intro l
  induction l with
  | nil => intro a; rfl
  | cons x l ih =>
    intro a
    have e : (if (cfg.op x).proj == p then a + eff cfg u x else a) = a := by
      split
      · rename_i e; rw [h x (by simpa using e)]; rfl
      · rfl
    simp only [List.foldl]; rw [e]; exact ih a

/-- The giver the code picks, if any may give. -/
theorem foldl_pick {F : Option Nat → Nat → Option Nat}
    (hF : ∀ b x, F b x = some x ∨ F b x = b) (hF0 : ∀ x, F none x = some x) :
    ∀ (l : List Nat) (b : Option Nat), (l ≠ [] ∨ b ≠ none) →
      ∃ x, l.foldl F b = some x ∧ (b = some x ∨ x ∈ l) := by
  intro l
  induction l with
  | nil =>
    intro b hb
    rcases hb with hb | hb
    · exact absurd rfl hb
    · obtain ⟨x, rfl⟩ := Option.ne_none_iff_exists'.1 hb; exact ⟨x, rfl, .inl rfl⟩
  | cons y l ih =>
    intro b _
    have hy : F b y ≠ none := by
      rcases hF b y with e | e
      · rw [e]; simp
      · cases b with
        | none => rw [hF0]; simp
        | some _ => rw [e]; simp
    obtain ⟨x, hx, hm⟩ := ih (F b y) (.inr hy)
    refine ⟨x, hx, ?_⟩
    rcases hm with hm | hm
    · rcases hF b y with e | e
      · rw [e] at hm; cases hm; exact .inr (List.mem_cons_self ..)
      · rw [e] at hm; exact .inl hm
    · exact .inr (List.mem_cons_of_mem _ hm)

theorem giverOf_some {cfg : Cfg} {s : St} {h g : Nat} (hm : g ∈ s.order) {c : Nat}
    (hk : keptSlot s g = some c) (hg : mayGive cfg s g h c = true) :
    ∃ g' c', giverOf cfg s h = some g' ∧ keptSlot s g' = some c' ∧ mayGive cfg s g' h c' = true := by
  let ok := s.order.filter (fun g =>
    match keptSlot s g with
    | some c => mayGive cfg s g h c
    | none => false)
  have hmem : g ∈ ok := List.mem_filter.2 ⟨hm, by simp [hk, hg]⟩
  obtain ⟨x, hx, hxm⟩ := foldl_pick (l := ok) (b := none)
    (F := fun best g => match best with
      | none => some g
      | some b =>
        if (decide (projEff cfg s (cfg.op g).proj * cfg.w (cfg.op b).proj >
              projEff cfg s (cfg.op b).proj * cfg.w (cfg.op g).proj) ||
            (projEff cfg s (cfg.op g).proj * cfg.w (cfg.op b).proj ==
              projEff cfg s (cfg.op b).proj * cfg.w (cfg.op g).proj &&
            (decide (eff cfg s g > eff cfg s b) || eff cfg s g == eff cfg s b))) then some g else best)
    (fun b x => by cases b <;> simp only <;> (try split) <;> simp)
    (fun x => rfl) (.inl (List.ne_nil_of_mem hmem))
  rcases hxm with hxm | hxm
  · cases hxm
  · have := (List.mem_filter.1 hxm).2
    cases e : keptSlot s x with
    | none => rw [e] at this; cases this
    | some c' => rw [e] at this; exact ⟨x, c', hx, e, this⟩

theorem keptSlot_slot {s : St} {g c : Nat} (h : keptSlot s g = some c) :
    (s.cpu c).slot = some { owner := g } := by
  have := (List.find?_eq_some_iff_append.1 h).1
  simpa using this

theorem keptSlot_some {s : St} {g c : Nat} (hc : c < s.cpus.length)
    (h : (s.cpu c).slot = some { owner := g }) : ∃ c', keptSlot s g = some c' := by
  cases e : keptSlot s g with
  | some c' => exact ⟨c', rfl⟩
  | none =>
    unfold keptSlot at e
    rw [List.find?_eq_none] at e
    exact absurd (by simpa using h) (e c (List.mem_range.2 hc))

/-! ### A head holding nothing is never blocked -/

/-- The rules this needs; the code as released has them. -/
structure LineRules (r : Rules) : Prop where
  safe : Safe r
  ledger : r.ledger = true
  shareRule : r.shareRule = true
  zeroFirst : r.zeroFirst = true
  giverBehind : r.giverBehind = true
  behindFresh : r.behindFresh = true
  oneGiver : r.oneGiver = true
  urgentOnce : r.urgentOnce = true
  stoppedWaits : r.stoppedWaits = false
  renewAtRelease : r.renewAtRelease = true

theorem LineRules.released : LineRules Rules.released :=
  ⟨⟨rfl, rfl, rfl⟩, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl, rfl⟩

/-- The state a drain of `g`'s slot `c` leads to, as `mayGive` reads it. -/
abbrev afterDrain (cfg : Cfg) (s : St) (g c : Nat) : St :=
  { drainEff cfg s g c with order := renewed (drainEff cfg s g c) g }

theorem afterDrain_cpu (cfg : Cfg) (s : St) (g c c' : Nat) :
    (afterDrain cfg s g c).cpu c' = if c = c' ∧ c < s.cpus.length then
      { s.cpu c with slot := some { owner := g, draining := true } } else s.cpu c' :=
  St.cpu_setCpu s c c' _

/-- After the drain, an operation other than `g` holding no slot and no grant holds nothing. -/
theorem afterDrain_eff_zero {cfg : Cfg} {s : St} {g c o : Nat}
    (ho : ∀ c' sl, (s.cpu c').slot = some sl → sl.owner ≠ o) (hne : o ≠ g)
    (hng : ∀ c', (s.cpu c').grant = none) : eff cfg (afterDrain cfg s g c) o = 0 := by
  have h1 : (afterDrain cfg s g c).owned o = 0 := by
    apply countP_zero_owned
    intro c' sl hs
    rw [afterDrain_cpu] at hs
    split at hs
    · simp only [Option.some.injEq] at hs; subst hs; exact Ne.symm hne
    · exact ho c' sl hs
  have h2 : (afterDrain cfg s g c).grants o = 0 := by
    apply countP_zero_grants
    intro c'
    rw [afterDrain_cpu]
    split
    · simp [hng c]
    · simp [hng c']
  unfold eff; split
  · rfl
  · rw [h1, h2]; simp

section
variable {cfg : Cfg} (hR : LineRules cfg.rules)
include hR

omit hR in
/-- No CPU unlocked and none being emptied: each is a slot of the living operation holding
its flock, with no grant. -/
theorem full_cpu {s : St} (inv : Inv cfg s)
    (hfree : ∀ c, c < s.cpus.length → (s.cpu c).lock ≠ none)
    (hdr : ∀ c, drainingC (s.cpu c) = false) (c : Nat) (hc : c < s.cpus.length) :
    ∃ o, (s.cpu c).lock = some o ∧ (s.cpu c).slot = some { owner := o } ∧
      (s.op o).phase = .alive ∧ (s.cpu c).grant = none := by
  cases e : (s.cpu c).lock with
  | none => exact absurd e (hfree c hc)
  | some o =>
    obtain ⟨ho, ha⟩ := inv.lockOwner c o e
    obtain ⟨d, hd⟩ := (ownsC_iff _ _).1 ho
    have : d = false := by have := hdr c; simp [drainingC, hd] at this; exact this
    subst this
    refine ⟨o, rfl, hd, ha, ?_⟩
    cases eg : (s.cpu c).grant with
    | none => rfl
    | some h' => have := (inv.grantFree c h' eg).1; rw [e] at this; cases this

/-- A head holding nothing is never blocked: some CPU is unlocked (a pass hands it out, or its
grant is being taken), or one is being emptied, or some holder may start emptying one for it. -/
theorem zero_head_unblocked {s : St} (r : Reach cfg s) (hcpu : 0 < cfg.cpus)
    (hd : firstDrain cfg s = none) {h : Nat} (hh : head cfg s = some h) (hz : eff cfg s h = 0) :
    (∃ c, c < s.cpus.length ∧ (s.cpu c).lock = none) ∨ (∃ c, drainingC (s.cpu c) = true) ∨
    ∃ g c, canDrain cfg s g c = true := by
  have inv := r.inv hR.safe
  have sv := r.servedOk hR.urgentOnce
  by_cases hfree : ∃ c, c < s.cpus.length ∧ (s.cpu c).lock = none
  · exact .inl hfree
  by_cases hdr : ∃ c, drainingC (s.cpu c) = true
  · exact .inr (.inl hdr)
  right; right
  have hfree' : ∀ c, c < s.cpus.length → (s.cpu c).lock ≠ none := fun c hc e => hfree ⟨c, hc, e⟩
  have hdr' : ∀ c, drainingC (s.cpu c) = false := fun c => by
    cases e : drainingC (s.cpu c)
    · rfl
    · exact absurd ⟨c, e⟩ hdr
  have full := full_cpu inv hfree' hdr'
  have hlen : s.cpus.length = cfg.cpus := inv.len
  -- The head.
  have hw := head_waiter hh
  have hlive := waiter_live hw
  have hha : (s.op h).phase = .alive := by
    simpa [liveOp, hR.stoppedWaits, St.isAlive] using hlive
  have hdem : demand cfg s h > 0 := by
    simp only [waiter, Bool.and_eq_true, decide_eq_true_eq] at hw; exact hw.1.2
  have hord : h ∈ s.order := r.tickets h (by simp [started, hha])
  -- Where a slot is, its owner holds the flock.
  have slotLock : ∀ c' sl, (s.cpu c').slot = some sl →
      c' < s.cpus.length ∧ (s.cpu c').lock = some sl.owner := by
    intro c' sl hs
    have hc' := s.lt_of_slot c' (by rw [hs]; simp)
    obtain ⟨o, hl, hs', -, -⟩ := full _ hc'
    rw [hs] at hs'; cases hs'; exact ⟨hc', hl⟩
  have hng : ∀ c', (s.cpu c').grant = none := by
    intro c'
    by_cases hc' : c' < s.cpus.length
    · obtain ⟨_, _, _, _, hg⟩ := full _ hc'; exact hg
    · rw [s.cpu_default c' hc']
  -- The head holds no slot.
  have hnoh : ∀ c' sl, (s.cpu c').slot = some sl → sl.owner ≠ h := by
    intro c' sl hs e
    subst e
    obtain ⟨hc', -⟩ := slotLock c' sl hs
    have hpos : 0 < s.owned sl.owner := by
      apply List.countP_pos_iff.2
      refine ⟨s.cpus[c'], List.getElem_mem hc', ?_⟩
      have ec : s.cpu c' = s.cpus[c'] := by
        simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc']
      rw [← ec]; exact ownsC_of_slot hs rfl
    have hd0 : s.drainOf sl.owner = 0 := by
      apply countP_zero_of; intro x hx
      obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hx
      have ej : s.cpu j = s.cpus[j] := by
        simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hj]
      have := hdr' j; rw [ej] at this; simp [this]
    have : eff cfg s sl.owner ≠ 0 := by
      unfold eff; rw [hd0]
      simp [hha]; omega
    exact this hz
  -- A drain of `g`'s slot `c` for the head is allowed, if `h`'s project holds no more for its
  -- weight than `g`'s once the drain is made.
  have give : ∀ g c, c < s.cpus.length → (s.cpu c).lock = some g →
      projEff cfg (afterDrain cfg s g c) (cfg.op h).proj * cfg.w (cfg.op g).proj ≤
        projEff cfg (afterDrain cfg s g c) (cfg.op g).proj * cfg.w (cfg.op h).proj →
      mayGive cfg s g h c = true := by
    intro g c hc hl hp
    obtain ⟨o, hl', hs, hga, -⟩ := full _ hc
    rw [hl] at hl'; cases hl'
    have hne : h ≠ g := fun e => hnoh c _ hs (by simp [e])
    have hdg : drainOp cfg g = false := by
      cases e : drainOp cfg g
      · rfl
      · exfalso
        unfold firstDrain at hd
        rw [List.find?_eq_none] at hd
        apply hd g (r.tickets g (by simp [started, hga]))
        simp [e, hga]
    have key : ahead cfg (afterDrain cfg s g c) h g = true := by
      apply ahead_of hR.zeroFirst
      · unfold urgentFirst
        have : bit (afterDrain cfg s g c).served g = true := sv c g hl
        simp [this, hR.urgentOnce]
      · exact afterDrain_eff_zero hnoh hne hng
      · exact hp
      · show (renewed (drainEff cfg s g c) g).findIdx (· == h) <
          (renewed (drainEff cfg s g c) g).findIdx (· == g)
        have ho : (drainEff cfg s g c).order = s.order := by
          simp [drainEff, hR.renewAtRelease]
        unfold renewed; rw [ho]
        exact findIdx_app_lt (List.mem_filter.2 ⟨hord, by simpa using hne⟩) (by simp)
    unfold mayGive yieldTo
    simp only [St.isAlive, hga, hdg, hR.shareRule, hz, hR.giverBehind, hR.behindFresh]
    simp only [afterDrain] at key
    simp [hne, key]
  -- Each holder's kept slot (the one `giverOf` looks at) is a CPU whose flock it holds.
  have pick : ∀ g c, c < s.cpus.length → (s.cpu c).lock = some g →
      ∃ cg, keptSlot s g = some cg ∧ cg < s.cpus.length ∧ (s.cpu cg).lock = some g := by
    intro g c hc hl
    obtain ⟨o, hl', hs, -, -⟩ := full _ hc
    rw [hl] at hl'; cases hl'
    obtain ⟨cg, hk⟩ := keptSlot_some hc hs
    obtain ⟨hcg, hlg⟩ := slotLock cg _ (keptSlot_slot hk)
    exact ⟨cg, hk, hcg, hlg⟩
  -- A giver: one of the head's project if any holds a CPU, else any holder.
  obtain ⟨g, cg, hk, hcg, hlg, hp⟩ : ∃ g cg, keptSlot s g = some cg ∧ cg < s.cpus.length ∧
      (s.cpu cg).lock = some g ∧
      projEff cfg (afterDrain cfg s g cg) (cfg.op h).proj * cfg.w (cfg.op g).proj ≤
        projEff cfg (afterDrain cfg s g cg) (cfg.op g).proj * cfg.w (cfg.op h).proj := by
    by_cases hP : ∃ c, c < s.cpus.length ∧ ∃ o, (s.cpu c).lock = some o ∧
        (cfg.op o).proj = (cfg.op h).proj
    · obtain ⟨c, hc, o, hl, hp⟩ := hP
      obtain ⟨cg, hk, hcg, hlg⟩ := pick o c hc hl
      exact ⟨o, cg, hk, hcg, hlg, by rw [hp]; exact Nat.le_refl _⟩
    · have hc0 : 0 < s.cpus.length := by omega
      obtain ⟨o, hl, -, -, -⟩ := full _ hc0
      obtain ⟨cg, hk, hcg, hlg⟩ := pick o 0 hc0 hl
      refine ⟨o, cg, hk, hcg, hlg, ?_⟩
      have hzero : projEff cfg (afterDrain cfg s o cg) (cfg.op h).proj = 0 := by
        apply projEff_zero
        intro o' ho'
        apply afterDrain_eff_zero _ _ hng
        · intro c' sl hs e
          obtain ⟨hc', hl'⟩ := slotLock c' sl hs
          exact hP ⟨c', hc', sl.owner, hl', by rw [e]; exact ho'⟩
        · intro e; subst e; exact hP ⟨0, hc0, o', hl, ho'⟩
      rw [hzero]; simp
  have hmay := give g cg hcg hlg hp
  have hgo : g ∈ s.order := by
    obtain ⟨o, hl', -, hga, -⟩ := full _ hcg
    rw [hlg] at hl'; cases hl'
    exact r.tickets g (by simp [started, hga])
  obtain ⟨g', c', hgv, hk', hmay'⟩ := giverOf_some hgo hk hmay
  refine ⟨g', c', ?_⟩
  -- The drain count is zero and the head still wants a CPU none hands it.
  have hdr0 : s.drains = 0 := by
    rw [inv.drainCount]
    apply countP_zero_of; intro x hx
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hx
    have ej : s.cpu j = s.cpus[j] := by
      simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hj]
    rw [← ej]; exact hdr' j
  have hfree0 : freeN cfg s = 0 := by
    apply countP_zero_of; intro x hx
    obtain ⟨j, hj, rfl⟩ := List.getElem_of_mem hx
    have ej : s.cpu j = s.cpus[j] := by
      simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hj]
    rw [← ej]
    have := hfree' j hj
    cases e : (s.cpu j).lock with
    | none => exact absurd e this
    | some _ => simp [freeC, e]
  have hneed : s.drains < need cfg s := by
    simp only [need, hh, hfree0, hdr0]; omega
  have hga' : s.isAlive g' = true := by
    unfold mayGive at hmay'
    simp only [Bool.and_eq_true] at hmay'
    exact hmay'.1.1.1
  unfold canDrain
  simp [hga', keptSlot_slot hk', hR.ledger, hh, hneed, hmay', hR.oneGiver, hgv]

end

end Cpuq
