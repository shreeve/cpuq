import CpuqModel.StreamCex

/-!
Drain backfill (`Rules.backfill`, on in `Rules.drainfill`).

A drain names its cores (`--cpus`) or takes `-c N` of the pool's free cores (`pickCpus`); a core
here is a CPU with its SMT siblings. Every drain start needs its cores free (`fits`: no started
drain isolates them), as the shipped code's `taken` wait. With backfill, a drain `D` may start
while older drains wait, when:
- its cores are free and none is named by an older waiting drain (`fits`; a `-c` drain picks
  around those cores);
- the isolation stays within `drain_max` counting every older waiting drain's cores too
  (`iso + |D| + olderSum ≤ drain_max`);
- (with `drainFifo`) no run older than `D` waits holding nothing.

`fill_inv` is the invariant this keeps: started drains hold disjoint cores, each as many as it
asked; no started drain holds a core an older waiting drain names; and for every started drain,
the isolation plus every older waiting drain's cores stays within `drain_max`.
`older_unhindered` is what that buys: removing every started drain younger than a waiting drain
never makes it startable. A younger drain that started by backfill never stands in an older
drain's way: not by its cores, not by `drain_max`.
-/

namespace Cpuq.Contest

/-! ## Moves change drains only so -/

/-- How a move before the pass may change drain `e`: its phase, ticket and cores stay; a started
drain is over (same ticket); an over drain leaves; or an absent one arrives with ticket `next`. -/
def DMove (s u : St) (e : Nat) : Prop :=
  ((u.drain e).ph = (s.drain e).ph ∧ (u.drain e).ticket = (s.drain e).ticket ∧ (u.drain e).held = (s.drain e).held) ∨
  ((s.drain e).ph = .started ∧ (u.drain e).ph = .over ∧ (u.drain e).ticket = (s.drain e).ticket) ∨
  ((s.drain e).ph = .over ∧ (u.drain e).ph = .absent) ∨
  ((s.drain e).ph = .absent ∧ (u.drain e).ph = .waiting ∧ (u.drain e).ticket = s.next ∧ s.next < u.next)

theorem pre_dmove {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) :
    s.next ≤ u.next ∧ (∀ e, DMove s u e) ∧
      (∀ e f, (s.drain e).ph = .absent → (u.drain e).ph = .waiting →
        (s.drain f).ph = .absent → (u.drain f).ph = .waiting → e = f) ∧
      (∀ e, (s.drain e).ph = .absent → (u.drain e).ph = .waiting → e < cfg.nd) := by
  cases m with
  | act a =>
    have hu : act cfg s a = some u := h
    have hg := act_guard hu
    have hn : s.next ≤ u.next := by
      cases a <;> simp only [act] at hu <;> (try split at hu) <;> (try cases hu) <;> (try exact Nat.le_refl _) <;>
        (show s.next ≤ s.next + 1; omega)
    refine ⟨hn, fun e => ?_, fun e f he hu' hf hu'' => ?_, fun e he hu' => ?_⟩
    · rw [DMove, act_drain hu e]
      cases a with
      | arriveD d =>
        dsimp only [drainAfter]; split
        · rename_i hde; subst hde
          dsimp only at hg
          have hnx : u.next = s.next + 1 := by
            simp only [act] at hu; rw [ite_t hg] at hu; cases hu; rfl
          exact Or.inr (Or.inr (Or.inr ⟨hg.2, rfl, rfl, by omega⟩))
        · exact Or.inl ⟨rfl, rfl, rfl⟩
      | dbusy d b =>
        dsimp only [drainAfter]; split
        · rename_i hde; subst hde
          exact Or.inl ⟨rfl, rfl, rfl⟩
        · exact Or.inl ⟨rfl, rfl, rfl⟩
      | dend d =>
        dsimp only [drainAfter]; split
        · rename_i hde; subst hde; dsimp only at hg
          exact Or.inr (Or.inl ⟨hg.2, rfl, rfl⟩)
        · exact Or.inl ⟨rfl, rfl, rfl⟩
      | tick =>
        dsimp only [drainAfter]
        unfold tickD
        split
        · rename_i hst
          split
          · exact Or.inr (Or.inl ⟨hst, rfl, rfl⟩)
          · exact Or.inl ⟨rfl, rfl, rfl⟩
        · exact Or.inl ⟨rfl, rfl, rfl⟩
      | _ => exact Or.inl ⟨rfl, rfl, rfl⟩
    · rw [act_drain hu e] at hu'; rw [act_drain hu f] at hu''
      cases a with
      | arriveD d =>
        dsimp only [drainAfter] at hu' hu''
        split at hu'
        · split at hu''
          · rename_i h1 h2; rw [← h1, ← h2]
          · rename_i h2; rw [hf] at hu''; cases hu''
        · rename_i h1; rw [he] at hu'; cases hu'
      | tick =>
        dsimp only [drainAfter] at hu'
        rcases tickD_ph cfg (anyWait cfg s) e (s.drain e) with x | x <;> rw [x] at hu' <;> (try rw [he] at hu') <;> cases hu'
      | dbusy d b | dend d =>
        dsimp only [drainAfter] at hu'
        split at hu' <;> simp_all
      | _ => dsimp only [drainAfter] at hu'; rw [he] at hu'; cases hu'
    · rw [act_drain hu e] at hu'
      cases a with
      | arriveD d =>
        dsimp only [drainAfter] at hu'
        split at hu'
        · rename_i h1; subst h1; dsimp only at hg; exact hg.1
        · rw [he] at hu'; cases hu'
      | tick =>
        dsimp only [drainAfter] at hu'
        rcases tickD_ph cfg (anyWait cfg s) e (s.drain e) with x | x <;> rw [x] at hu' <;> (try rw [he] at hu') <;> cases hu'
      | dbusy d b | dend d =>
        dsimp only [drainAfter] at hu'
        split at hu' <;> simp_all
      | _ => dsimp only [drainAfter] at hu'; rw [he] at hu'; cases hu'
  | leave r =>
    obtain ⟨_, rfl⟩ := h
    exact ⟨Nat.le_refl _, fun e => Or.inl ⟨rfl, rfl, rfl⟩, fun e f he hu => by simp [he] at hu,
      fun e he hu => by simp [he] at hu⟩
  | leaveD d =>
    obtain ⟨hc, rfl⟩ := h
    refine ⟨Nat.le_refl _, fun e => ?_, fun e f he hu => ?_, fun e he hu => ?_⟩
    · by_cases hed : e = d
      · subst hed; exact Or.inr (Or.inr (Or.inl ⟨hc.2, by simp⟩))
      · exact Or.inl (by simp [hed])
    · by_cases hed : e = d
      · subst hed; simp at hu
      · simp [hed, he] at hu
    · by_cases hed : e = d
      · subst hed; simp at hu
      · simp [hed, he] at hu


/-! ## The invariant backfill keeps -/

structure FillInv (cfg : Cfg) (s : St) : Prop where
  /-- Present drains have tickets below `next`, all different, and are in the configuration. -/
  tk : ∀ e, (s.drain e).ph ≠ .absent → (s.drain e).ticket < s.next
  dist : ∀ d e, d ≠ e → (s.drain d).ph ≠ .absent → (s.drain e).ph ≠ .absent →
    (s.drain d).ticket ≠ (s.drain e).ticket
  bnd : ∀ e, (s.drain e).ph ≠ .absent → e < cfg.nd
  /-- Started drains hold disjoint cores, each as many as it asked. -/
  disj : ∀ d e, d ≠ e → (s.drain d).ph = .started → (s.drain e).ph = .started →
    ∀ c ∈ (s.drain d).held, c ∉ (s.drain e).held
  len : ∀ d, (s.drain d).ph = .started → (s.drain d).held.length = cfg.dsize d
  /-- No started drain holds a core an older waiting drain names. -/
  named : ∀ d o, (s.drain d).ph = .started → (s.drain o).ph = .waiting →
    (s.drain o).ticket < (s.drain d).ticket → ∀ c ∈ (cfg.drain o).cpus, c ∉ (s.drain d).held
  /-- For every started drain, the isolation and every older waiting drain's cores fit. -/
  budget : ∀ d, (s.drain d).ph = .started → iso cfg s + olderSum cfg s d ≤ cfg.drainMax

theorem fill_init (cfg : Cfg) : FillInv cfg Contest.init where
  tk e h := absurd rfl h
  dist _ _ _ h := absurd rfl h
  bnd e h := absurd rfl h
  disj _ _ _ h := by cases h
  len _ h := by cases h
  named _ _ h := by cases h
  budget _ h := by cases h

/-- Over a move before the pass. -/
theorem pre_fill {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) (i : FillInv cfg s) : FillInv cfg u := by
  obtain ⟨hn, hd, hone, hnd⟩ := pre_dmove h
  -- a drain present after was present before with its ticket, or is the one that arrived
  have old : ∀ e, (u.drain e).ph ≠ .absent →
      ((s.drain e).ph ≠ .absent ∧ (u.drain e).ticket = (s.drain e).ticket) ∨
      ((s.drain e).ph = .absent ∧ (u.drain e).ph = .waiting ∧ (u.drain e).ticket = s.next ∧ s.next < u.next) := by
    intro e he
    rcases hd e with ⟨h1, h2, _⟩ | ⟨h1, _, h3⟩ | ⟨_, h2⟩ | h4
    · exact Or.inl ⟨by rw [← h1]; exact he, h2⟩
    · exact Or.inl ⟨by rw [h1]; simp, h3⟩
    · exact absurd h2 he
    · exact Or.inr h4
  have st : ∀ e, (u.drain e).ph = .started → (s.drain e).ph = .started ∧
      (u.drain e).ticket = (s.drain e).ticket ∧ (u.drain e).held = (s.drain e).held := by
    intro e he
    rcases hd e with ⟨h1, h2, h3⟩ | ⟨_, h2, _⟩ | ⟨_, h2⟩ | ⟨_, h2, _⟩
    · exact ⟨by rw [← h1]; exact he, h2, h3⟩
    all_goals (rw [h2] at he; cases he)
  have wt : ∀ e, (u.drain e).ph = .waiting →
      ((s.drain e).ph = .waiting ∧ (u.drain e).ticket = (s.drain e).ticket) ∨
      ((s.drain e).ph = .absent ∧ (u.drain e).ticket = s.next) := by
    intro e he
    rcases hd e with ⟨h1, h2, _⟩ | ⟨_, h2, _⟩ | ⟨_, h2⟩ | ⟨h1, _, h3, _⟩
    · exact Or.inl ⟨by rw [← h1]; exact he, h2⟩
    · rw [h2] at he; cases he
    · rw [h2] at he; cases he
    · exact Or.inr ⟨h1, h3⟩
  have hiso : iso cfg u ≤ iso cfg s := iso_le (fun e he => (st e he).1)
  have hos : ∀ d, (u.drain d).ph = .started → olderSum cfg u d ≤ olderSum cfg s d := by
    intro d hdst
    obtain ⟨s1, s2, _⟩ := st d hdst
    have htd := i.tk d (by rw [s1]; simp)
    apply rsum_le
    intro e _
    by_cases hc : (u.drain e).ph = .waiting ∧ (u.drain e).ticket < (u.drain d).ticket
    · rw [ite_t hc]
      rcases wt e hc.1 with ⟨w1, w2⟩ | ⟨_, w2⟩
      · rw [ite_t ⟨w1, by rw [← w2, ← s2]; exact hc.2⟩]; exact Nat.le_refl _
      · have := hc.2; rw [w2, s2] at this; omega
    · rw [ite_f hc]; exact Nat.zero_le _
  refine ⟨fun e he => ?_, fun d e hde hd' he => ?_, fun e he => ?_, fun d e hde hd' he => ?_, fun d hd' => ?_,
    fun d o hd' ho hlt => ?_, fun d hd' => ?_⟩
  · rcases old e he with ⟨h1, h2⟩ | ⟨_, _, h3, h4⟩
    · rw [h2]; have := i.tk e h1; omega
    · rw [h3]; exact h4
  · rcases old d hd' with ⟨d1, d2⟩ | ⟨d1, d2, d3, _⟩ <;> rcases old e he with ⟨e1, e2⟩ | ⟨e1, e2, e3, _⟩
    · rw [d2, e2]; exact i.dist d e hde d1 e1
    · rw [d2, e3]; have := i.tk d d1; omega
    · rw [d3, e2]; have := i.tk e e1; omega
    · exact absurd (hone d e d1 d2 e1 e2) hde
  · rcases old e he with ⟨h1, _⟩ | ⟨h1, h2, _, _⟩
    · exact i.bnd e h1
    · exact hnd e h1 h2
  · obtain ⟨a1, _, a3⟩ := st d hd'; obtain ⟨b1, _, b3⟩ := st e he
    rw [a3, b3]; exact i.disj d e hde a1 b1
  · obtain ⟨a1, _, a3⟩ := st d hd'; rw [a3]; exact i.len d a1
  · obtain ⟨a1, a2, a3⟩ := st d hd'
    rw [a3]
    rcases wt o ho with ⟨o1, o2⟩ | ⟨_, o2⟩
    · exact i.named d o a1 o1 (by rw [← o2, ← a2]; exact hlt)
    · have := i.tk d (by rw [a1]; simp); rw [o2, a2] at hlt; omega
  · have := i.budget d (st d hd').1; have := hos d hd'; omega

/-- A drain starts by the pass. -/
theorem startD_fill {cfg : Cfg} {s : St} {d : Nat} (hd : d < cfg.nd) (hc : canDrain cfg s d = true)
    (i : FillInv cfg s) : FillInv cfg (startD cfg s d) := by
  have hc' := hc
  simp only [canDrain, Bool.and_eq_true, decide_eq_true_eq, Bool.or_eq_true, Bool.not_eq_true'] at hc'
  obtain ⟨⟨⟨⟨hw, hg⟩, hb⟩, hfit⟩, hmode, _⟩ := hc'
  have hfit' := hfit
  simp only [fits, Bool.and_eq_true, List.all_eq_true, beq_iff_eq, Bool.not_eq_true'] at hfit'
  obtain ⟨hall, hlen⟩ := hfit'
  have hpd : ∀ c ∈ pickCpus cfg s d, heldBy cfg s c = false ∧ reserved cfg s d c = false := by
    intro c hcm; have := hall c hcm; simpa using this
  have dd : (startD cfg s d).drain d = startDr (s.drain d) (pickCpus cfg s d) := by simp [startD]
  have de : ∀ e, e ≠ d → (startD cfg s d).drain e = s.drain e := fun e he => by simp [startD, he]
  have hiso := iso_startD (cfg := cfg) hd hw
  have hwd : (s.drain d).ph ≠ .absent := by rw [hw]; simp
  -- the older waiting drains' sum, for `d` itself and for another started drain
  have osd : olderSum cfg (startD cfg s d) d = olderSum cfg s d := by
    apply rsum_congr; intro e _
    by_cases hed : e = d
    · subst hed; simp [startD, startDr]
    · simp [startD, startDr, hed]
  have os0 : olderDrainWaits cfg s d = false → olderSum cfg s d = 0 := by
    intro ho
    apply rsum_eq_zero.2; intro e he
    have := anyLT_false.1 ho e he
    simp only [Bool.and_eq_false_iff, decide_eq_false_iff_not] at this
    exact ite_f (fun ⟨a, b⟩ => this.elim (· a) (· b)) _ _
  -- a waiting drain older than `D` (started, older than `d`) is older than `d`
  have osub : ∀ D, (s.drain D).ticket < (s.drain d).ticket → olderSum cfg s D ≤ olderSum cfg s d := by
    intro D hD
    apply rsum_le; intro e _
    by_cases h1 : (s.drain e).ph = .waiting ∧ (s.drain e).ticket < (s.drain D).ticket
    · rw [ite_t h1, ite_t ⟨h1.1, by omega⟩]; exact Nat.le_refl _
    · rw [ite_f h1]; exact Nat.zero_le _
  have osD : ∀ D, D ≠ d → olderSum cfg (startD cfg s d) D +
      (if (s.drain d).ticket < (s.drain D).ticket then cfg.dsize d else 0) = olderSum cfg s D := by
    intro D hDd
    let F : Nat → DrainSt → Nat := fun e y => if y.ph = .waiting ∧ y.ticket < (s.drain D).ticket then cfg.dsize e else 0
    have hsum := sum_setDrain F s (startDr (s.drain d) (pickCpus cfg s d)) hd
    have e1 : olderSum cfg (startD cfg s d) D =
        rsum cfg.nd (fun j => F j ((setDrain s d (startDr (s.drain d) (pickCpus cfg s d))).drain j)) := by
      unfold olderSum; rw [de D hDd]; rfl
    have e2 : olderSum cfg s D = rsum cfg.nd (fun j => F j (s.drain j)) := rfl
    have e3 : F d (startDr (s.drain d) (pickCpus cfg s d)) = 0 := by simp [F, startDr]
    have e4 : F d (s.drain d) = (if (s.drain d).ticket < (s.drain D).ticket then cfg.dsize d else 0) := by
      simp only [F, hw, true_and]
    rw [e3] at hsum
    rw [e1, e2, ← e4]; omega
  refine ⟨fun e he => ?_, fun a e hae ha he => ?_, fun e he => ?_, fun a e hae ha he => ?_, fun a ha => ?_,
    fun a o ha ho hlt => ?_, fun a ha => ?_⟩
  · by_cases hed : e = d
    · subst hed; rw [dd]; exact i.tk e hwd
    · rw [de e hed] at he ⊢; exact i.tk e he
  · have ta : ((startD cfg s d).drain a).ticket = (s.drain a).ticket ∧ (s.drain a).ph ≠ .absent := by
      by_cases had : a = d
      · subst had; rw [dd]; exact ⟨rfl, hwd⟩
      · rw [de a had] at ha ⊢; exact ⟨rfl, ha⟩
    have te : ((startD cfg s d).drain e).ticket = (s.drain e).ticket ∧ (s.drain e).ph ≠ .absent := by
      by_cases hed : e = d
      · subst hed; rw [dd]; exact ⟨rfl, hwd⟩
      · rw [de e hed] at he ⊢; exact ⟨rfl, he⟩
    rw [ta.1, te.1]; exact i.dist a e hae ta.2 te.2
  · by_cases hed : e = d
    · rw [hed]; exact hd
    · rw [de e hed] at he; exact i.bnd e he
  · -- the new drain's cores are free; two old ones were disjoint
    intro c hca hce
    by_cases had : a = d
    · subst had
      have hed : e ≠ a := fun h => hae h.symm
      rw [dd] at hca; rw [de e hed] at he hce
      have := (hpd c hca).1
      have := anyLT_false.1 this e (i.bnd e (by rw [he]; simp))
      simp [he, hce] at this
    · by_cases hed : e = d
      · subst hed
        rw [dd] at hce; rw [de a had] at ha hca
        have := (hpd c hce).1
        have := anyLT_false.1 this a (i.bnd a (by rw [ha]; simp))
        simp [ha, hca] at this
      · rw [de a had] at ha hca; rw [de e hed] at he hce
        exact i.disj a e hae ha he c hca hce
  · by_cases had : a = d
    · subst had; rw [dd]; simpa [startDr] using hlen
    · rw [de a had] at ha ⊢; exact i.len a ha
  · have hod : o ≠ d := fun h => by rw [h, dd] at ho; simp [startDr] at ho
    rw [de o hod] at ho hlt
    intro c hco hca
    by_cases had : a = d
    · subst had
      rw [dd] at hca hlt; simp only [startDr] at hca hlt
      have := (hpd c hca).2
      have := anyLT_false.1 this o (i.bnd o (by rw [ho]; simp))
      simp [ho, hlt, hco] at this
    · rw [de a had] at ha hca hlt
      exact i.named a o ha ho hlt c hco hca
  · rw [hiso]
    by_cases had : a = d
    · subst had; rw [osd]
      rcases hmode with ho | ⟨_, hbf⟩
      · rw [os0 ho]; omega
      · omega
    · rw [de a had] at ha
      have hsum := osD a had
      have ib := i.budget a ha
      by_cases ht : (s.drain d).ticket < (s.drain a).ticket
      · rw [ite_t ht] at hsum; omega
      · rw [ite_f ht] at hsum
        have hne := i.dist a d had (by rw [ha]; simp) hwd
        have hlt : (s.drain a).ticket < (s.drain d).ticket := by omega
        rcases hmode with ho | ⟨_, hbf⟩
        · have : olderSum cfg s a = 0 := Nat.le_zero.1 (by rw [← os0 ho]; exact osub a hlt)
          omega
        · have := osub a hlt; omega

theorem pass1_fill {cfg : Cfg} {s t : St} (h : pass1 cfg s = some t) (i : FillInv cfg s) : FillInv cfg t := by
  unfold pass1 at h
  split at h
  · rename_i d hd
    cases h
    exact startD_fill (List.mem_range.1 (List.mem_of_find?_eq_some hd)) (List.find?_some hd) i
  · cases hf : (List.range cfg.nr).find? (canStart cfg s) with
    | none => rw [hf] at h; cases h
    | some r =>
      rw [hf] at h; cases h
      exact { tk := i.tk, dist := i.dist, bnd := i.bnd, disj := i.disj, len := i.len, named := i.named,
              budget := i.budget }

theorem passN_fill {cfg : Cfg} : ∀ (k : Nat) {s : St}, FillInv cfg s → FillInv cfg (passN cfg k s)
  | 0, _, i => i
  | k + 1, s, i => by
    simp only [passN]
    cases e : pass1 cfg s with
    | none => exact i
    | some t => exact passN_fill k (pass1_fill e i)

/-- **The backfill invariant** holds in every reachable state, under any rules. -/
theorem reachS_fill {cfg : Cfg} {s : St} (r : ReachS cfg s) : FillInv cfg s := by
  induction r with
  | init => exact fill_init cfg
  | step m _ hs ih =>
    obtain ⟨u, hu, rfl⟩ := stepS_pre hs
    exact passN_fill _ (pre_fill hu ih)


/-! ## Counting free cores -/

theorem filter_or_len (p q : Nat → Bool) : ∀ l : List Nat,
    (l.filter (fun c => p c || q c)).length ≤ (l.filter p).length + (l.filter q).length
  | [] => Nat.le_refl _
  | a :: l => by
    have ih := filter_or_len p q l
    simp only [List.filter_cons]
    cases hp : p a <;> cases hq : q a <;> simp <;> omega

theorem filter_not_len (p : Nat → Bool) : ∀ l : List Nat,
    (l.filter (fun c => !p c)).length + (l.filter p).length = l.length
  | [] => rfl
  | a :: l => by
    have ih := filter_not_len p l
    simp only [List.filter_cons]
    cases hp : p a <;> simp <;> omega

theorem anyLT_succ (m : Nat) (p : Nat → Bool) : anyLT (m + 1) p = (anyLT m p || p m) := by
  simp [anyLT, List.range_succ, List.any_append]

theorem filter_anyLT_len (n : Nat) (g : Nat → Nat → Bool) : ∀ m,
    ((List.range n).filter (fun c => anyLT m (fun e => g e c))).length ≤
      rsum m (fun e => ((List.range n).filter (g e)).length)
  | 0 => by simp [anyLT, rsum]
  | m + 1 => by
    have ih := filter_anyLT_len n g m
    have h := filter_or_len (fun c => anyLT m (fun e => g e c)) (g m) (List.range n)
    simp only [anyLT_succ, rsum]
    omega

theorem nodup_sub_len : ∀ (X L : List Nat), X.Nodup → (∀ x ∈ X, x ∈ L) → X.length ≤ L.length
  | [], _, _, _ => Nat.zero_le _
  | x :: X, L, hn, hs => by
    have hx : x ∈ L := hs x (by simp)
    have hn' := List.nodup_cons.1 hn
    have ih := nodup_sub_len X (L.erase x) hn'.2 (fun y hy => by
      have : y ≠ x := fun e => hn'.1 (e ▸ hy)
      exact (List.mem_erase_of_ne this).2 (hs y (by simp [hy])))
    rw [List.length_erase_of_mem hx] at ih
    have : 0 < L.length := List.length_pos_of_mem hx
    simp only [List.length_cons]; omega

theorem filter_mem_len (n : Nat) (L : List Nat) : ((List.range n).filter (fun c => L.contains c)).length ≤ L.length :=
  nodup_sub_len _ _ (List.nodup_range.filter _) (fun x hx => by simpa using (List.mem_filter.1 hx).2)

/-- The pool's cores isolated now are at most the cores isolated. -/
theorem held_count {cfg : Cfg} {s : St} (i : FillInv cfg s) :
    ((List.range cfg.pool).filter (heldBy cfg s)).length ≤ iso cfg s := by
  have h := filter_anyLT_len cfg.pool (fun e c => decide ((s.drain e).ph = .started) && (s.drain e).held.contains c) cfg.nd
  refine Nat.le_trans h (rsum_le (fun e _ => ?_))
  by_cases hs : (s.drain e).ph = .started
  · simp only [isoF, hs, decide_true, Bool.true_and, ite_true]
    rw [← i.len e hs]; exact filter_mem_len _ _
  · simp [isoF, hs]

/-- The pool's cores named by drains older than `d` that wait are at most their cores. -/
theorem reserved_count {cfg : Cfg} {s : St} (d : Nat) :
    ((List.range cfg.pool).filter (reserved cfg s d)).length ≤ olderSum cfg s d := by
  have h := filter_anyLT_len cfg.pool (fun e c => decide ((s.drain e).ph = .waiting) &&
    decide ((s.drain e).ticket < (s.drain d).ticket) && (cfg.drain e).cpus.contains c) cfg.nd
  refine Nat.le_trans h (rsum_le (fun e _ => ?_))
  by_cases hw : (s.drain e).ph = .waiting ∧ (s.drain e).ticket < (s.drain d).ticket
  · rw [ite_t hw]
    simp only [hw.1, hw.2, decide_true, Bool.true_and]
    refine Nat.le_trans (filter_mem_len _ _) ?_
    unfold Cfg.dsize; split
    · rename_i h0; simp [h0]
    · exact Nat.le_refl _
  · rw [ite_f hw]
    simp
    intro a _ h1 h2; exact absurd ⟨h1, h2⟩ hw

/-- A `-c` drain fits when the isolation plus the older waiting drains' cores leave its count. -/
theorem fits_count {cfg : Cfg} {s : St} {o : Nat} (i : FillInv cfg s) (hc : (cfg.drain o).cpus = [])
    (hroom : iso cfg s + olderSum cfg s o + (cfg.drain o).size ≤ cfg.pool) : fits cfg s o = true := by
  have h1 := held_count i
  have h2 := reserved_count (cfg := cfg) (s := s) o
  have h3 := filter_or_len (heldBy cfg s) (reserved cfg s o) (List.range cfg.pool)
  have h4 := filter_not_len (fun c => heldBy cfg s c || reserved cfg s o c) (List.range cfg.pool)
  have e : (fun c => !(heldBy cfg s c || reserved cfg s o c)) = (fun c => !heldBy cfg s c && !reserved cfg s o c) := by
    funext c; cases heldBy cfg s c <;> cases reserved cfg s o c <;> rfl
  rw [e] at h4
  simp only [List.length_range] at h4
  unfold fits pickCpus
  rw [ite_t hc]
  simp only [Bool.and_eq_true, List.all_eq_true, beq_iff_eq]
  refine ⟨fun c hc' => by simpa using (List.mem_filter.1 (List.mem_of_mem_take hc')).2, ?_⟩
  simp only [List.length_take, Cfg.dsize, hc, ite_true]
  omega

/-! ## A younger drain never stands in an older one's way -/

/-- `s` with every started drain younger than `o` over. -/
def dropYounger (s : St) (o : Nat) : St :=
  { s with drain := fun e => if (s.drain e).ph = .started ∧ (s.drain o).ticket < (s.drain e).ticket
      then { s.drain e with ph := .over } else s.drain e }

theorem dropYounger_waiting {s : St} {o : Nat} (e : Nat) :
    ((dropYounger s o).drain e).ph = .waiting ↔ (s.drain e).ph = .waiting := by
  simp only [dropYounger]; split
  · rename_i h; simp [h.1]
  · exact Iff.rfl

theorem dropYounger_ticket {s : St} {o : Nat} (e : Nat) :
    ((dropYounger s o).drain e).ticket = (s.drain e).ticket := by
  simp only [dropYounger]; split <;> rfl

theorem olderSum_sub {cfg : Cfg} {s : St} {o D : Nat} (ho : o < cfg.nd) (hw : (s.drain o).ph = .waiting)
    (hlt : (s.drain o).ticket < (s.drain D).ticket) :
    olderSum cfg s o + cfg.dsize o ≤ olderSum cfg s D := by
  have key : ∀ e, (if (s.drain e).ph = .waiting ∧ (s.drain e).ticket < (s.drain o).ticket then cfg.dsize e else 0) +
      (if e = o then cfg.dsize o else 0) ≤
      (if (s.drain e).ph = .waiting ∧ (s.drain e).ticket < (s.drain D).ticket then cfg.dsize e else 0) := by
    intro e
    by_cases heo : e = o
    · subst heo; rw [ite_f (by omega), ite_t rfl, ite_t ⟨hw, hlt⟩]; omega
    · rw [ite_f heo]
      by_cases h1 : (s.drain e).ph = .waiting ∧ (s.drain e).ticket < (s.drain o).ticket
      · rw [ite_t h1, ite_t ⟨h1.1, by omega⟩]; omega
      · rw [ite_f h1]; omega
  have hs : ∀ n, o < n → rsum n (fun e => if e = o then cfg.dsize o else 0) = cfg.dsize o := by
    intro n hn
    induction n with
    | zero => omega
    | succ n ih =>
      simp only [rsum]
      by_cases hon : o = n
      · subst hon
        rw [rsum_eq_zero.2 (fun j hj => by simp; omega)]; simp
      · rw [ih (by omega)]; simp [Ne.symm hon]
  have hsplit : ∀ n, rsum n (fun e => (if (s.drain e).ph = .waiting ∧ (s.drain e).ticket < (s.drain o).ticket then cfg.dsize e else 0) +
      (if e = o then cfg.dsize o else 0)) = rsum n (fun e => if (s.drain e).ph = .waiting ∧
        (s.drain e).ticket < (s.drain o).ticket then cfg.dsize e else 0) + rsum n (fun e => if e = o then cfg.dsize o else 0) := by
    intro n; induction n with
    | zero => rfl
    | succ n ih => simp only [rsum]; rw [ih]; omega
  have := rsum_le (n := cfg.nd) (fun e _ => key e)
  rw [hsplit, hs _ ho] at this
  unfold olderSum; omega

/-- **A younger drain never stands in an older one's way.** In every reachable state, if a waiting
drain `o` could start were every started drain younger than it over, it can start now. Under any
rules; for a `-c` drain, `drain_max` ≤ pool. Backfill lets a drain start only so: its cores are
none an older waiting drain names, and the isolation leaves room for every older waiting drain. -/
theorem older_unhindered {cfg : Cfg} (hDp : cfg.drainMax ≤ cfg.pool) {s : St} (h : ReachS cfg s) {o : Nat}
    (ho : o < cfg.nd) (hw : (s.drain o).ph = .waiting) (hc : canDrain cfg (dropYounger s o) o = true) :
    canDrain cfg s o = true := by
  have i := reachS_fill h
  by_cases hy : ∃ D, (s.drain D).ph = .started ∧ (s.drain o).ticket < (s.drain D).ticket
  · obtain ⟨D, hDs, hDt⟩ := hy
    have hb := i.budget D hDs
    have hsub := olderSum_sub (cfg := cfg) ho hw hDt
    have hdo : (dropYounger s o).drain o = s.drain o := by
      simp only [dropYounger]; rw [ite_f (by rw [hw]; simp)]
    -- what reads only waiting drains, tickets and runs is the same
    have ew : ∀ e, decide (((dropYounger s o).drain e).ph = .waiting) = decide ((s.drain e).ph = .waiting) :=
      fun e => dec_iff (dropYounger_waiting e)
    have odw : olderDrainWaits cfg (dropYounger s o) o = olderDrainWaits cfg s o := by
      unfold olderDrainWaits; apply anyLT_congr; intro e _
      rw [ew e, dropYounger_ticket, dropYounger_ticket]
    have oew : olderEmptyWaits cfg (dropYounger s o) o = olderEmptyWaits cfg s o := by
      unfold olderEmptyWaits; apply anyLT_congr; intro e _; rw [dropYounger_ticket]; rfl
    have res : ∀ c, reserved cfg (dropYounger s o) o c = reserved cfg s o c := by
      intro c; unfold reserved; apply anyLT_congr; intro e _
      rw [ew e, dropYounger_ticket, dropYounger_ticket]
    have hg : (dropYounger s o).gate = s.gate := rfl
    have hfit : fits cfg s o = true := by
      by_cases hcn : (cfg.drain o).cpus = []
      · apply fits_count i hcn
        have : cfg.dsize o = (cfg.drain o).size := by simp [Cfg.dsize, hcn]
        omega
      · -- named: a younger started drain holds none of its cores; an older one is kept
        have hf := hc
        simp only [canDrain, Bool.and_eq_true] at hf
        have hf2 := hf.1.2
        unfold fits pickCpus at hf2 ⊢
        rw [ite_f hcn] at hf2 ⊢
        simp only [Bool.and_eq_true, List.all_eq_true, Bool.not_eq_true', beq_iff_eq] at hf2 ⊢
        refine ⟨fun c hcm => ?_, hf2.2⟩
        have hc2 := hf2.1 c hcm
        try simp only [Bool.and_eq_true, Bool.not_eq_true'] at hc2
        rw [res c] at hc2
        refine ⟨?_, hc2.2⟩
        apply anyLT_false.2
        intro e he
        by_cases hes : (s.drain e).ph = .started
        · by_cases het : (s.drain o).ticket < (s.drain e).ticket
          · have := i.named e o hes hw het c hcm
            simp [hes, this]
          · have := anyLT_false.1 hc2.1 e he
            simp only [dropYounger] at this
            rw [ite_f (fun x => het x.2)] at this
            exact this
        · simp [hes]
    simp only [canDrain, Bool.and_eq_true, decide_eq_true_eq, Bool.or_eq_true, Bool.not_eq_true'] at hc ⊢
    obtain ⟨⟨⟨⟨_, hgt⟩, _⟩, _⟩, hmode, hfifo⟩ := hc
    rw [hdo] at *
    refine ⟨⟨⟨⟨hw, by rw [← hg]; exact hgt⟩, by omega⟩, hfit⟩, ?_, by rw [← oew]; exact hfifo⟩
    rcases hmode with h1 | ⟨h1, _⟩
    · left; rw [← odw]; exact h1
    · right; exact ⟨h1, by omega⟩
  · -- no younger drain is started: nothing changes
    have heq : dropYounger s o = s := by
      cases s with
      | mk run drain gate outside next now =>
        simp only [dropYounger, St.mk.injEq, true_and, and_true]
        funext e
        rw [ite_f (fun x => hy ⟨e, x⟩)]
    rw [heq] at hc; exact hc

/-! ## Through runs, backfill can delay an older drain -/

/-- 6 cores, `drain_max` 5. Runs: `R` (project 0, two tasks, `-c 1`), `Q` (project 0, two tasks),
`P` (project 1, three tasks). Drains: `E` names core 0, `O` names cores 0 and 1, `D` is `-c 2`. -/
def delayCfg (r : Rules) : Cfg :=
  { pool := 6, drainMax := 5, rules := r, ceil := 9,
    runs := [{ proj := 0, tasks := 2, cap := 1 }, { proj := 0, tasks := 2, cap := 2 }, { proj := 1, tasks := 3, cap := 3 }],
    drains := [{ cpus := [0], limit := 9 }, { cpus := [0, 1], limit := 9 }, { size := 2, limit := 9 }] }

/-- `E` starts; `R`, `Q`, `P` start tasks; `O` arrives and waits for core 0; `D` arrives (with
backfill it starts on cores 2 and 3); `R`'s task ends; `E` ends. -/
def delayMoves : List Move :=
  [.act (.arriveD 0), .act (.arrive 0), .act (.arrive 1), .act (.arrive 2), .act .tick, .act (.arriveD 1),
   .act (.arriveD 2), .act (.finC 0), .act (.dend 0)]

/-- **Backfill can delay an older drain, through runs.** The same moves under `Rules.nostarve` and
under `Rules.drainfill`. Without backfill, `E`'s end lets `O` start. With backfill, `D` started
earlier on cores `O` does not name, within `drain_max` with `O` counted. Its isolation leaves
`R`'s project over share with no room, so `R`, older than `O`, waits holding nothing when its
task ends, and `O`, which passes no such run (`drainFifo`), waits. -/
theorem backfill_delays :
    ((runMoves (delayCfg .nostarve) init delayMoves).map fun s => (s.drain 1).ph) = some .started ∧
    ((runMoves (delayCfg .drainfill) init delayMoves).map fun s => (s.drain 1).ph) = some .waiting := by
  decide +kernel

/-! ## Drains are served -/

/-- One step for a drain: waiting after means waiting before with the same ticket, or a new
arrival; started after means started or waiting before with the same ticket, or a new arrival;
waiting before means waiting or started after, with the same ticket. -/
theorem step_drain {cfg : Cfg} {s t : St} {m : Move} (h : stepS cfg s m = some t) (e : Nat) :
    ((t.drain e).ph = .waiting → ((s.drain e).ph = .waiting ∧ (t.drain e).ticket = (s.drain e).ticket) ∨
      (t.drain e).ticket = s.next) ∧
    ((t.drain e).ph = .started → (((s.drain e).ph = .started ∨ (s.drain e).ph = .waiting) ∧
      (t.drain e).ticket = (s.drain e).ticket) ∨ (t.drain e).ticket = s.next) ∧
    ((s.drain e).ph = .waiting → ((t.drain e).ph = .waiting ∨ (t.drain e).ph = .started) ∧
      (t.drain e).ticket = (s.drain e).ticket) := by
  obtain ⟨u, hu, rfl⟩ := stepS_pre h
  have pp := pass_path cfg u
  have fr := pp.frame
  have htk : ((pass cfg u).drain e).ticket = (u.drain e).ticket := fr.2.2.2.2 e
  obtain ⟨_, hd, _, _⟩ := pre_dmove hu
  refine ⟨fun hw => ?_, fun hs => ?_, fun hw => ?_⟩
  · have hwu := fr.2.1 e hw
    rw [htk]
    rcases hd e with ⟨h1, h2, _⟩ | ⟨_, h2, _⟩ | ⟨_, h2⟩ | ⟨_, _, h3, _⟩
    · exact Or.inl ⟨by rw [← h1]; exact hwu, h2⟩
    · rw [h2] at hwu; cases hwu
    · rw [h2] at hwu; cases hwu
    · exact Or.inr h3
  · rw [htk]
    by_cases hwu : (u.drain e).ph = .waiting
    · rcases hd e with ⟨h1, h2, _⟩ | ⟨_, h2, _⟩ | ⟨_, h2⟩ | ⟨_, _, h3, _⟩
      · exact Or.inl ⟨Or.inr (by rw [← h1]; exact hwu), h2⟩
      · rw [h2] at hwu; cases hwu
      · rw [h2] at hwu; cases hwu
      · exact Or.inr h3
    · have hsu : (u.drain e).ph = .started := by rw [← fr.2.2.1 e hwu]; exact hs
      rcases hd e with ⟨h1, h2, _⟩ | ⟨_, h2, _⟩ | ⟨_, h2⟩ | ⟨_, h2, _⟩
      · exact Or.inl ⟨Or.inl (by rw [← h1]; exact hsu), h2⟩
      all_goals (rw [h2] at hsu; cases hsu)
  · have hwu : (u.drain e).ph = .waiting ∧ (u.drain e).ticket = (s.drain e).ticket := by
      rcases hd e with ⟨h1, h2, _⟩ | ⟨h1, _, _⟩ | ⟨h1, _⟩ | ⟨h1, _, _, _⟩
      · exact ⟨by rw [h1]; exact hw, h2⟩
      all_goals (rw [h1] at hw; cases hw)
    exact ⟨pp.waiting hwu.1, by rw [htk, hwu.2]⟩

/-- One step for a run older than ticket `T`, with a task waiting: it was such a run before. -/
theorem step_run_old {cfg : Cfg} {s t : St} {m : Move} (h : stepS cfg s m = some t) {x T : Nat}
    (hT : T ≤ s.next) (hh : (t.run x).here = true) (hp : 0 < (t.run x).pend) (ht : (t.run x).ticket < T) :
    (s.run x).here = true ∧ 0 < (s.run x).pend ∧ (s.run x).ticket = (t.run x).ticket := by
  obtain ⟨u, hu, rfl⟩ := stepS_pre h
  have fr := ((pass_path cfg u).frame.1 x)
  rw [fr.2.2.2] at hh; rw [fr.2.2.1] at ht ⊢
  have hpu : 0 < (u.run x).pend := by have := fr.1; omega
  cases m with
  | act a =>
    have hu' : act cfg s a = some u := hu
    rw [act_run hu' x] at hh hpu ht ⊢
    cases a with
    | arrive e =>
      dsimp only [runAfter] at hh hpu ht ⊢; split at ht
      · simp at ht; omega
      · rename_i hne; rw [ite_f hne] at hh hpu ⊢; exact ⟨hh, hpu, rfl⟩
    | finS e | finC e | finB e | block e | wake e | limit e c =>
      dsimp only [runAfter] at hh hpu ht ⊢; split at hh <;> simp_all
    | tick => dsimp only [runAfter] at hh hpu ht ⊢; exact ⟨hh, hpu, rfl⟩
    | _ => dsimp only [runAfter] at hh hpu ht ⊢; exact ⟨hh, hpu, rfl⟩
  | leave e =>
    obtain ⟨_, rfl⟩ := hu
    by_cases hxe : x = e
    · subst hxe; simp at hh
    · rw [setRun_run, ite_f hxe] at hh hpu ht ⊢; exact ⟨hh, hpu, rfl⟩
  | leaveD d => obtain ⟨_, rfl⟩ := hu; exact ⟨hh, hpu, rfl⟩

/-- A started drain stays started through a step, ageing by one on a tick, or it is not started. -/
theorem step_started_age {cfg : Cfg} {s t : St} {m : Move} (h : stepS cfg s m = some t) {e : Nat}
    (h1 : (s.drain e).ph = .started) (h2 : (t.drain e).ph = .started) :
    (t.drain e).age = (s.drain e).age + (if m.isTick then 1 else 0) := by
  obtain ⟨u, hu, rfl⟩ := stepS_pre h
  have fr := (pass_path cfg u).frame
  cases m with
  | act a =>
    have hu' : act cfg s a = some u := hu
    rcases act_started hu' h1 with ⟨e1, e2, _⟩ | e1
    · rw [fr.2.2.1 e (by rw [e1]; simp), e2]; rfl
    · rw [fr.2.2.1 e (by rw [e1]; simp), e1] at h2; cases h2
  | leave r =>
    obtain ⟨_, rfl⟩ := hu
    rw [fr.2.2.1 e (by simp [h1])]; simp [Move.isTick]
  | leaveD d =>
    obtain ⟨hc, rfl⟩ := hu
    have hed : e ≠ d := fun h => by rw [h, hc.2] at h1; cases h1
    rw [fr.2.2.1 e (by simp [hed, h1])]; simp [hed, Move.isTick]

/-- With ticks again and again, a started drain is not started at some later time. -/
theorem started_ends {cfg : Cfg} (ρ : RunS cfg) (time : ∀ m, ∃ m' ≥ m, ρ.mv m' = .act .tick) {e m : Nat}
    (_hs : ((ρ.st m).drain e).ph = .started) : ∃ m' ≥ m, ((ρ.st m').drain e).ph ≠ .started := by
  apply Classical.byContradiction; intro hn
  have stay : ∀ k, ((ρ.st (m + k)).drain e).ph = .started := fun k =>
    Classical.byContradiction fun h => hn ⟨m + k, by omega, h⟩
  have grow : ∀ c, ∃ k, c ≤ ((ρ.st (m + k)).drain e).age := by
    intro c
    induction c with
    | zero => exact ⟨0, Nat.zero_le _⟩
    | succ c ih =>
      obtain ⟨k, hk⟩ := ih
      obtain ⟨t, ht, htk⟩ := time (m + k)
      have mono : ∀ j, ((ρ.st (m + k)).drain e).age ≤ ((ρ.st (m + k + j)).drain e).age := by
        intro j
        induction j with
        | zero => exact Nat.le_refl _
        | succ j ih' =>
          have := step_started_age (ρ.steps (m + k + j)) (stay (k + j) |> fun x => by rwa [show m + (k + j) = m + k + j by omega] at x)
            (stay (k + j + 1) |> fun x => by rwa [show m + (k + j + 1) = m + k + j + 1 by omega] at x)
          rw [show m + k + (j + 1) = m + k + j + 1 by omega, this]; omega
      have h1 := step_started_age (ρ.steps t) (by have := stay (t - m); rwa [show m + (t - m) = t by omega] at this)
        (by have := stay (t + 1 - m); rwa [show m + (t + 1 - m) = t + 1 by omega] at this)
      rw [htk] at h1; simp only [Move.isTick, Act.isTick, ite_true] at h1
      have h2 := mono (t - (m + k)); rw [show m + k + (t - (m + k)) = t by omega] at h2
      exact ⟨t + 1 - m, by rw [show m + (t + 1 - m) = t + 1 by omega, h1]; omega⟩
  obtain ⟨k, hk⟩ := grow (cfg.limitOf e + cfg.grace + 1)
  have := ((reachS_inv (ρ.reach (m + k))).1.clock e (stay k)).1
  omega

/-- A property that, once false, stays false, and that some time makes false, is false from some
time on, for every index below a bound. -/
theorem eventually_all {P : Nat → Nat → Prop} (N n : Nat)
    (stable : ∀ e m, m ≥ n → P e (m + 1) → P e m) (ev : ∀ e < N, ∃ m ≥ n, ¬ P e m) :
    ∃ T ≥ n, ∀ m ≥ T, ∀ e < N, ¬ P e m := by
  have forever : ∀ e m, m ≥ n → ¬ P e m → ∀ k, ¬ P e (m + k) := by
    intro e m hm h k
    induction k with
    | zero => exact h
    | succ k ih => exact fun hp => ih (stable e _ (by omega) hp)
  induction N with
  | zero => exact ⟨n, Nat.le_refl _, fun _ _ e he => absurd he (Nat.not_lt_zero _)⟩
  | succ N ih =>
    obtain ⟨T, hT, hall⟩ := ih (fun e he => ev e (by omega))
    obtain ⟨mN, hmN, hNf⟩ := ev N (by omega)
    refine ⟨max T mN, by omega, fun m hm e he => ?_⟩
    rcases Nat.lt_succ_iff_lt_or_eq.1 he with he | he
    · exact hall m (by omega) e he
    · subst he; have := forever e mN hmN hNf (m - mN); rwa [show mN + (m - mN) = m by omega] at this

/-- The drains older than `d` (by ticket) that wait. -/
def olderCount (cfg : Cfg) (s : St) (d : Nat) : Nat :=
  rsum cfg.nd (fun e => if (s.drain e).ph = .waiting ∧ (s.drain e).ticket < (s.drain d).ticket then 1 else 0)

theorem olderCount_lt {cfg : Cfg} {s : St} {d e : Nat} (he : e < cfg.nd) (hw : (s.drain e).ph = .waiting)
    (hlt : (s.drain e).ticket < (s.drain d).ticket) : olderCount cfg s e < olderCount cfg s d := by
  apply rsum_lt (i := e)
  · intro j _
    by_cases h1 : (s.drain j).ph = .waiting ∧ (s.drain j).ticket < (s.drain e).ticket
    · rw [ite_t h1, ite_t ⟨h1.1, by omega⟩]; exact Nat.le_refl _
    · rw [ite_f h1]; exact Nat.zero_le _
  · exact he
  · rw [ite_f (fun h => by omega), ite_t ⟨hw, hlt⟩]; omega

/-- A drain whose older waiting drains all start, starts. -/
theorem served_of_older {cfg : Cfg} (hak : cfg.rules.arrivalKey = true) (hol : cfg.rules.oneLine = true)
    (hD : cfg.drainMax < cfg.pool) (hsz : ∀ e < cfg.nd, cfg.dsize e ≤ cfg.drainMax) (ρ : RunS cfg)
    (noUrgent : ∀ m b, ρ.mv m = .act (.arrive b) → (cfg.run b).urgent = false)
    (ends : ∀ m b, b < cfg.nr → 0 < ((ρ.st m).run b).running → ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (time : ∀ m, ∃ m' ≥ m, ρ.mv m' = .act .tick)
    (gates : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true)
    {n d : Nat} (hd : d < cfg.nd) (hw : ((ρ.st n).drain d).ph = .waiting)
    (older : ∀ e < cfg.nd, ((ρ.st n).drain e).ph = .waiting → ((ρ.st n).drain e).ticket < ((ρ.st n).drain d).ticket →
      ∃ m ≥ n, ((ρ.st m).drain e).ph = .started) :
    ∃ m ≥ n, ((ρ.st m).drain d).ph = .started := by
  apply Classical.byContradiction; intro hno
  have nst : ∀ m ≥ n, ((ρ.st m).drain d).ph ≠ .started := fun m hm h => hno ⟨m, hm, h⟩
  obtain ⟨Td, hTd0⟩ : ∃ x, ((ρ.st n).drain d).ticket = x := ⟨_, rfl⟩
  -- `d` waits forever with its ticket
  have dw : ∀ k, ((ρ.st (n + k)).drain d).ph = .waiting ∧ ((ρ.st (n + k)).drain d).ticket = Td := by
    intro k
    induction k with
    | zero => exact ⟨hw, hTd0⟩
    | succ k ih =>
      have := (step_drain (ρ.steps (n + k)) d).2.2 ih.1
      rw [show n + (k + 1) = n + k + 1 by omega]
      rcases this.1 with h1 | h1
      · exact ⟨h1, this.2.trans ih.2⟩
      · exact absurd h1 (nst _ (by omega))
  have dw' : ∀ m ≥ n, ((ρ.st m).drain d).ph = .waiting ∧ ((ρ.st m).drain d).ticket = Td :=
    fun m hm => by have := dw (m - n); rwa [show n + (m - n) = m by omega] at this
  have hTd : ∀ m ≥ n, Td < (ρ.st m).next := by
    intro m hm
    have h1 := (reachS_fill (ρ.reach n)).tk d (by rw [hw]; simp)
    have h2 := nextMono ρ n (m - n); rw [show n + (m - n) = m by omega] at h2
    rw [hTd0] at h1; omega
  -- the older waiting drains start, and none comes back older
  obtain ⟨T1, hT1, h1⟩ := eventually_all (P := fun e m => ((ρ.st m).drain e).ph = .waiting ∧
      ((ρ.st m).drain e).ticket < Td) cfg.nd n
    (fun e m hm hp => by
      rcases (step_drain (ρ.steps m) e).1 hp.1 with ⟨a, b⟩ | b
      · exact ⟨a, by rw [← b]; exact hp.2⟩
      · have := hTd m hm; have := hp.2; rw [b] at this; omega)
    (fun e he => by
      by_cases hp : ((ρ.st n).drain e).ph = .waiting ∧ ((ρ.st n).drain e).ticket < Td
      · obtain ⟨m, hm, hs⟩ := older e he hp.1 (by rw [hTd0]; exact hp.2)
        exact ⟨m, hm, fun x => by rw [hs] at x; cases x.1⟩
      · exact ⟨n, Nat.le_refl _, hp⟩)
  -- the older started drains end, and none starts again
  obtain ⟨T2, hT2, h2⟩ := eventually_all (P := fun e m => ((ρ.st m).drain e).ph = .started ∧
      ((ρ.st m).drain e).ticket < Td) cfg.nd T1
    (fun e m hm hp => by
      rcases (step_drain (ρ.steps m) e).2.1 hp.1 with ⟨a | a, b⟩ | b
      · exact ⟨a, by rw [← b]; exact hp.2⟩
      · exact absurd ⟨a, by rw [← b]; exact hp.2⟩ (h1 m hm e ((reachS_fill (ρ.reach m)).bnd e (by rw [a]; simp)))
      · have := hTd m (by omega); have := hp.2; rw [b] at this; omega)
    (fun e _ => by
      by_cases hp : ((ρ.st T1).drain e).ph = .started
      · obtain ⟨m, hm, hn⟩ := started_ends ρ time hp
        exact ⟨m, hm, fun x => hn x.1⟩
      · exact ⟨T1, Nat.le_refl _, fun x => hp x.1⟩)
  -- the older runs start all their tasks
  have runDone : ∀ x < cfg.nr, ∀ p m, m ≥ n → ((ρ.st m).run x).pend ≤ p →
      ((ρ.st m).run x).here = true ∧ 0 < ((ρ.st m).run x).pend ∧ ((ρ.st m).run x).ticket < Td →
      ∃ m' ≥ m, ¬ (((ρ.st m').run x).here = true ∧ 0 < ((ρ.st m').run x).pend ∧ ((ρ.st m').run x).ticket < Td) := by
    intro x hx p
    induction p with
    | zero => intro m _ hp h; omega
    | succ p ih =>
      intro m hm hp h
      obtain ⟨m1, hm1, hlt⟩ := run_starts_fixed hak hol hD ρ hx h.1 h.2.1 (fun k _ b hb => noUrgent k b hb) ends
        (time m) gates
      by_cases h' : ((ρ.st m1).run x).here = true ∧ 0 < ((ρ.st m1).run x).pend ∧ ((ρ.st m1).run x).ticket < Td
      · obtain ⟨m2, hm2, hn⟩ := ih m1 (by omega) (by omega) h'
        exact ⟨m2, by omega, hn⟩
      · exact ⟨m1, hm1, h'⟩
  obtain ⟨T3, hT3, h3⟩ := eventually_all (P := fun x m => ((ρ.st m).run x).here = true ∧
      0 < ((ρ.st m).run x).pend ∧ ((ρ.st m).run x).ticket < Td) cfg.nr T2
    (fun x m hm hp => by
      obtain ⟨a, b, c⟩ := step_run_old (ρ.steps m) (T := Td) (by have := hTd m (by omega); omega) hp.1 hp.2.1 hp.2.2
      exact ⟨a, b, by rw [c]; exact hp.2.2⟩)
    (fun x hx => by
      by_cases hp : ((ρ.st T2).run x).here = true ∧ 0 < ((ρ.st T2).run x).pend ∧ ((ρ.st T2).run x).ticket < Td
      · exact runDone x hx _ T2 (by omega) (Nat.le_refl _) hp
      · exact ⟨T2, Nat.le_refl _, hp⟩)
  -- at open gates nothing older stands in its way
  obtain ⟨m, hm, hg⟩ := gates T3
  have hmn : m ≥ n := by omega
  obtain ⟨hdw, hdt⟩ := dw' m hmn
  have h1m : ∀ e < cfg.nd, ¬ (((ρ.st m).drain e).ph = .waiting ∧ ((ρ.st m).drain e).ticket < Td) :=
    fun e he => h1 m (by omega) e he
  have h2m : ∀ e < cfg.nd, ¬ (((ρ.st m).drain e).ph = .started ∧ ((ρ.st m).drain e).ticket < Td) :=
    fun e he => h2 m (by omega) e he
  have h3m : ∀ x < cfg.nr, ¬ (((ρ.st m).run x).here = true ∧ 0 < ((ρ.st m).run x).pend ∧
      ((ρ.st m).run x).ticket < Td) := fun x hx => h3 m (by omega) x hx
  have hr := ρ.reach m
  generalize ρ.st m = s at h1m h2m h3m hdw hdt hg hr
  have i := reachS_fill hr
  have hdo : (dropYounger s d).drain d = s.drain d := by
    simp only [dropYounger]; rw [ite_f (by rw [hdw]; simp)]
  have nost : ∀ e < cfg.nd, ((dropYounger s d).drain e).ph ≠ .started := by
    intro e he hs
    simp only [dropYounger] at hs
    split at hs
    · simp at hs
    · rename_i hny
      have hed : e ≠ d := fun h => by rw [h, hdw] at hs; cases hs
      have hne := i.dist e d hed (by rw [hs]; simp) (by rw [hdw]; simp)
      have hlt : (s.drain e).ticket < Td := by
        have : ¬ (s.drain d).ticket < (s.drain e).ticket := fun x => hny ⟨hs, x⟩
        rw [hdt] at this hne; omega
      exact h2m e he ⟨hs, hlt⟩
  have hiso : iso cfg (dropYounger s d) = 0 :=
    rsum_eq_zero.2 (fun e he => by simp [isoF, nost e he])
  have hodw : olderDrainWaits cfg (dropYounger s d) d = false := by
    apply anyLT_false.2; intro e he
    rw [dec_iff (dropYounger_waiting e), dropYounger_ticket, dropYounger_ticket]
    by_cases hwe : (s.drain e).ph = .waiting
    · have : ¬ (s.drain e).ticket < (s.drain d).ticket := fun x =>
        h1m e he ⟨hwe, by rw [hdt] at x; exact x⟩
      simp [this]
    · simp [hwe]
  have hoew : olderEmptyWaits cfg (dropYounger s d) d = false := by
    apply anyLT_false.2; intro x hx
    rw [hdo]
    cases he : emptyWaiter (dropYounger s d) x
    · rfl
    · simp only [emptyWaiter, Bool.and_eq_true, decide_eq_true_eq] at he
      have : ¬ ((dropYounger s d).run x).ticket < (s.drain d).ticket := fun x' =>
        h3m x hx ⟨he.1.1, he.1.2, by rw [hdt] at x'; exact x'⟩
      simp [this]
  have hfit : fits cfg (dropYounger s d) d = true :=
    fits_free nost hodw (Nat.le_trans (hsz d hd) (Nat.le_of_lt hD))
  have hc : canDrain cfg (dropYounger s d) d = true := by
    have hb : iso cfg (dropYounger s d) + cfg.dsize d ≤ cfg.drainMax := by rw [hiso]; have := hsz d hd; omega
    have hg' : (dropYounger s d).gate = true := hg
    simp [canDrain, hdo, hdw, hodw, hoew, hfit, hg', hb]
  have := older_unhindered (Nat.le_of_lt hD) hr hd hdw hc
  rw [reachS_drain hr hd] at this
  cases this

/-- **Drains are served, with arrivals that never stop**, on the fixed rules (`arrivalKey`,
`oneLine`), with or without backfill. A drain `d` waits at `n`. Suppose `drain_max` < pool, every
drain asks at most `drain_max` cores, and: no urgent run arrives; every task ends; ticks keep
coming; the gates are open again and again. Then `d` starts. The drains older than it that wait
start first (induction on how many there are); the started ones older than it end (their limit);
the runs older than it start all their tasks (`run_starts_fixed`); none of these comes back with
its old ticket. Then at open gates nothing older stands in its way, and younger started drains
never do (`older_unhindered`). -/
theorem drain_starts {cfg : Cfg} (hak : cfg.rules.arrivalKey = true) (hol : cfg.rules.oneLine = true)
    (hD : cfg.drainMax < cfg.pool) (hsz : ∀ e < cfg.nd, cfg.dsize e ≤ cfg.drainMax) (ρ : RunS cfg)
    (noUrgent : ∀ m b, ρ.mv m = .act (.arrive b) → (cfg.run b).urgent = false)
    (ends : ∀ m b, b < cfg.nr → 0 < ((ρ.st m).run b).running → ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (time : ∀ m, ∃ m' ≥ m, ρ.mv m' = .act .tick)
    (gates : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true)
    {n d : Nat} (hd : d < cfg.nd) (hw : ((ρ.st n).drain d).ph = .waiting) :
    ∃ m ≥ n, ((ρ.st m).drain d).ph = .started := by
  have key : ∀ k n d, d < cfg.nd → ((ρ.st n).drain d).ph = .waiting → olderCount cfg (ρ.st n) d ≤ k →
      ∃ m ≥ n, ((ρ.st m).drain d).ph = .started := by
    intro k
    induction k with
    | zero =>
      intro n d hd hw hc
      refine served_of_older hak hol hD hsz ρ noUrgent ends time gates hd hw (fun e he hwe hlt => ?_)
      have := olderCount_lt (cfg := cfg) he hwe hlt; omega
    | succ k ih =>
      intro n d hd hw hc
      refine served_of_older hak hol hD hsz ρ noUrgent ends time gates hd hw (fun e he hwe hlt => ?_)
      exact ih n e he hwe (by have := olderCount_lt (cfg := cfg) he hwe hlt; omega)
  exact key _ n d hd hw (Nat.le_refl _)

/-- info: 'Cpuq.Contest.drain_starts' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms drain_starts

/-- info: 'Cpuq.Contest.older_unhindered' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms older_unhindered

/-- info: 'Cpuq.Contest.reachS_fill' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms reachS_fill

end Cpuq.Contest
