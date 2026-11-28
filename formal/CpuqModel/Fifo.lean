/-
No drain that queued after a waiter takes a CPU ahead of it (0.34.0), for every configuration.

`fifo_no_pass` (DrainCap.lean) is one hand-out: a free CPU goes to a drain only if the oldest
gathering drain queued before every waiter that holds nothing. Here that becomes a statement
about runs. While a waiter `w` waits holding nothing, the tickets keep their order around it:
an arrival queues behind it, a give-back moves only the one giving back (never `w`, which holds
nothing) to the back, and a finished drain of a stream leaves the line and comes back behind it
(`moveX_order`, `behind_step`). So a drain that queued after `w` stays behind it, and at any
time from then on, a free CPU goes to a drain only while some drain that queued before `w`
gathers (`released_no_younger_pass`). Drains that queued after `w` never pass it.

This is the part of "drains don't starve anyone" that holds whatever the configuration. It is not
liveness: it does not say `w` is served (the line's own liveness, L3, and the bound on the drains
that queued before `w` are not proved in general; `Served.lean` proves the whole response
property for fixed configurations).
-/
import CpuqModel.DrainCap

namespace Cpuq

attribute [-simp] List.getD_eq_getElem?_getD

/-- Induction from `m` up (Mathlib's `Nat.le_induction`). -/
theorem le_induction {m : Nat} {P : ∀ n, m ≤ n → Prop} (base : P m (Nat.le_refl m))
    (succ : ∀ n hmn, P n hmn → P (n + 1) (Nat.le_succ_of_le hmn)) : ∀ n hmn, P n hmn := by
  intro n hmn
  obtain ⟨j, rfl⟩ := Nat.exists_eq_add_of_le hmn
  induction j with
  | zero => exact base
  | succ j ih => exact succ (m + j) (Nat.le_add_right m j) (ih (Nat.le_add_right m j))

/-! ### How a step changes the tickets -/

/-- What a step may do to the tickets: nothing, queue one more at the back, move one that holds
a CPU to the back (a give-back, or a drain's renewal), or drop one whose tasks have all ended
(a finished drain of a stream). -/
def OrderStep (s : St) (l : List Nat) : Prop :=
  l = s.order ∨ (∃ o, l = s.order ++ [o]) ∨ (∃ o, 0 < s.owned o ∧ l = renewed s o) ∨
  (∃ o, ended s o = true ∧ l = s.order.filter (· != o))

theorem owned_pos_of_slot {s : St} {c o : Nat} {sl : Slot} (h : (s.cpu c).slot = some sl)
    (e : sl.owner = o) : 0 < s.owned o := by
  have hc : c < s.cpus.length := s.lt_of_slot c (by rw [h]; simp)
  unfold St.owned
  rw [List.countP_pos_iff]
  refine ⟨s.cpus[c], List.getElem_mem hc, ?_⟩
  have : s.cpu c = s.cpus[c] := by
    rw [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_getElem hc, Option.getD_some]
  rw [← this]
  exact ownsC_of_slot h e

theorem setTask_order (s : St) (o i : Nat) (t : Task) : (s.setTask o i t).order = s.order := rfl
theorem setPhase_order (s : St) (o : Nat) (p : Phase) : (s.setPhase o p).order = s.order := rfl

theorem step_order {cfg : Cfg} {s t : St} {a : Act} (e : step cfg s a = some t) :
    OrderStep s t.order := by
  cases a with
  | arrive o =>
    simp only [step] at e; split at e
    · cases e; right; left; exact ⟨o, (handout_order_ops cfg _).1⟩
    · cases e
  | exit o i ok =>
    simp only [step] at e; split at e
    · split at e
      · cases e; left; exact (reap_phase_order cfg s o i 0 ok).2
      · split at e
        · cases e; left; rfl
        · cases e
    · cases e
  | timeout o i =>
    simp only [step] at e; split at e
    · split at e
      · cases e; left; rfl
      · cases e
    · cases e
  | gone o i =>
    simp only [step] at e; split at e
    · cases e; left; rfl
    · cases e
  | refill o c =>
    simp only [step] at e; split at e
    · split at e
      · cases e; left; rfl
      · cases e
    · cases e
  | release o c =>
    simp only [step] at e; split at e
    · rename_i sl hsl
      split at e
      · rename_i hg
        cases e
        rw [(handout_order_ops cfg _).1]
        simp only [Bool.and_eq_true, beq_iff_eq] at hg
        dsimp only
        split
        · right; right; left; exact ⟨o, owned_pos_of_slot hsl hg.1.1.1.1.2, rfl⟩
        · left; rfl
      · cases e
    · cases e
  | handout =>
    simp only [step] at e; split at e
    · cases e; left; exact (handout_order_ops cfg s).1
    · cases e
  | accept o c =>
    simp only [step] at e; split at e
    · cases e; left; exact (takeTok_phase_order cfg s o c 0).2
    · cases e
  | drain o c =>
    simp only [step] at e; split at e
    · rename_i hg
      cases e
      simp only [canDrain, Bool.and_eq_true, beq_iff_eq] at hg
      show OrderStep s (if cfg.rules.ledger && !cfg.rules.renewAtRelease then _ else _)
      split
      · right; right; left; exact ⟨o, owned_pos_of_slot hg.1.2 rfl, rfl⟩
      · left; rfl
    · cases e
  | undrain o c =>
    simp only [step] at e; split at e
    · cases e; left; rfl
    · cases e
  | consolidate o i d =>
    simp only [step] at e; split at e
    · split at e
      · cases e; left; rfl
      · cases e
    · cases e
  | kill o =>
    simp only [step] at e; split at e
    · cases e; left; exact (handout_order_ops cfg _).1
    · cases e
  | crash o =>
    simp only [step] at e; split at e
    · cases e; left; rfl
    · cases e
  | stop o =>
    simp only [step] at e; split at e
    · cases e; left; exact (handout_order_ops cfg _).1
    · cases e
  | cont o =>
    simp only [step] at e; split at e
    · cases e; left; rfl
    · cases e
  | finish o =>
    simp only [step] at e; split at e
    · cases e; left; exact (handout_order_ops cfg _).1
    · cases e
  | enter o | mark o | tstp o | halt o | tick => simp [step] at e

theorem move_order {cfg : Cfg} {s t : St} {a : Act} (e : move cfg s a = some t) :
    OrderStep s t.order := by
  rcases move_cases e with x | ⟨b, u, hb, x⟩
  · exact .inl x.2.2.1
  · have h := step_order hb
    obtain ⟨-, -, ho, -, -⟩ := x
    rw [ho]
    exact h

theorem foldl_order {α : Type} (f : St → α → St) (hf : ∀ u x, (f u x).order = u.order) (l : List α)
    (s : St) : (l.foldl f s).order = s.order := by
  induction l generalizing s with
  | nil => rfl
  | cons x xs ih => rw [List.foldl_cons, ih, hf]

theorem getD_step_order (cfg : Cfg) (u : St) (a : Act) (ha : ∀ t, step cfg u a = some t → t.order = u.order) :
    ((step cfg u a).getD u).order = u.order := by
  cases h : step cfg u a with
  | none => rfl
  | some t => exact ha t h

theorem step_timeout_order (cfg : Cfg) (u : St) (o i : Nat) (t : St)
    (e : step cfg u (.timeout o i) = some t) : t.order = u.order := by
  simp only [step] at e; split at e
  · split at e
    · cases e; rfl
    · cases e
  · cases e

theorem step_gone_order (cfg : Cfg) (u : St) (o i : Nat) (t : St)
    (e : step cfg u (.gone o i) = some t) : t.order = u.order := by
  simp only [step] at e; split at e
  · cases e; rfl
  · cases e

theorem tickX_order (cfg : Cfg) (s : St) : (tickX cfg s).order = s.order := by
  unfold tickX
  refine (foldl_order _ (fun u o => ?_) _ _).trans rfl
  split
  · have h1 : (termAll cfg u o).order = u.order :=
      foldl_order _ (fun v i => getD_step_order _ v _ (step_timeout_order _ v o i)) _ u
    have h2 : ∀ v, (killAll cfg v o).order = v.order := fun v =>
      foldl_order _ (fun v' i => getD_step_order _ v' _ (step_gone_order _ v' o i)) _ v
    split
    · split
      · rw [h2, h1]
      · exact h1
    · split
      · exact h2 u
      · rfl
  · rfl

theorem place_order (cfg : Cfg) (o c : Nat) (s : St) : (place cfg o c s).order = s.order := by
  unfold place; split
  · rfl
  · split <;> rfl

theorem finish_move {cfg : Cfg} {s t : St} {o : Nat} (e : move cfg s (.finish o) = some t) :
    t.order = s.order ∧ ended s o = true := by
  unfold move at e
  split at e
  · cases e
  dsimp only at e
  obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
  simp only [step] at hu
  split at hu
  · rename_i hg
    cases hu
    simp only [Bool.and_eq_true] at hg
    exact ⟨(handout_order_ops cfg _).1, hg.2⟩
  · cases hu

/-- How a step of `moveX` changes the tickets: as `step` does, or a finished drain of a stream
leaves the line. -/
theorem moveX_order {cfg : Cfg} {s t : St} {a : Act} (e : moveX cfg s a = some t) :
    OrderStep s t.order := by
  unfold moveX at e
  split at e
  · exact move_order e
  cases a with
  | tick =>
    dsimp only at e
    split at e
    · split at e
      · cases e; left; exact tickX_order cfg s
      · cases e
    · exact move_order e
  | refill o c =>
    dsimp only at e
    obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
    have := move_order hu
    split <;> (split <;> exact this)
  | timeout o i =>
    dsimp only at e
    split at e
    · obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      exact .inl (step_timeout_order _ s o i u hu)
    · exact move_order e
  | accept o c =>
    dsimp only at e
    obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
    have := move_order hu
    split
    · rw [place_order]; exact this
    · exact this
  | finish o =>
    dsimp only at e
    obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
    obtain ⟨h1, h2⟩ := finish_move hu
    split
    · right; right; right; exact ⟨o, h2, by simp [respawn, St.setClk, h1]⟩
    · exact .inl h1
  | _ => exact move_order e

/-! ### Behind a waiter that holds nothing -/

/-- `d` is behind `w` in the tickets `l`, or has none. -/
def Behind (l : List Nat) (w d : Nat) : Prop :=
  d ∉ l ∨ l.findIdx (· == w) < l.findIdx (· == d)

theorem findIdx_lt_of_mem {l : List Nat} {w : Nat} (h : w ∈ l) : l.findIdx (· == w) < l.length :=
  List.findIdx_lt_length_of_exists ⟨w, h, by simp⟩

theorem findIdx_append_mem {l : List Nat} {w o : Nat} (h : w ∈ l) :
    (l ++ [o]).findIdx (· == w) = l.findIdx (· == w) := by
  rw [List.findIdx_append]
  simp [h]

theorem findIdx_append_not {l : List Nat} {o : Nat} (h : o ∉ l) :
    (l ++ [o]).findIdx (· == o) = l.length := by
  rw [List.findIdx_append]
  simp [h]

theorem findIdx_cons_ne {x a : Nat} {l : List Nat} (h : x ≠ a) :
    (x :: l).findIdx (· == a) = l.findIdx (· == a) + 1 := by
  simp [List.findIdx_cons, h]

theorem findIdx_cons_eq {a : Nat} {l : List Nat} : (a :: l).findIdx (· == a) = 0 := by
  simp [List.findIdx_cons]

theorem findIdx_ne {l : List Nat} {a b : Nat} (ha : a ∈ l) (hab : a ≠ b) :
    l.findIdx (· == a) ≠ l.findIdx (· == b) := by
  induction l with
  | nil => cases ha
  | cons x xs ih =>
    by_cases hxa : x = a
    · subst hxa; rw [findIdx_cons_eq, findIdx_cons_ne hab]; omega
    · have ha' : a ∈ xs := (List.mem_cons.1 ha).resolve_left (fun e => hxa e.symm)
      rw [findIdx_cons_ne hxa]
      by_cases hxb : x = b
      · subst hxb; rw [findIdx_cons_eq]; omega
      · rw [findIdx_cons_ne hxb]; have := ih ha'; omega

theorem findIdx_filter_lt (q : Nat → Bool) {w d : Nat} (hw : q w = true) (hd : q d = true) :
    ∀ {l : List Nat}, w ∈ l → l.findIdx (· == w) < l.findIdx (· == d) →
      (l.filter q).findIdx (· == w) < (l.filter q).findIdx (· == d)
  | [], h, _ => by cases h
  | x :: xs, hm, hlt => by
    by_cases hxw : x = w
    · subst hxw
      have hdx : x ≠ d := fun e => by subst e; omega
      simp only [List.filter_cons, hw, ite_true]
      rw [findIdx_cons_eq, findIdx_cons_ne hdx]; omega
    · have hxd : x ≠ d := by
        intro e; subst e; rw [findIdx_cons_eq] at hlt; omega
      have hm' : w ∈ xs := (List.mem_cons.1 hm).resolve_left (fun e => hxw e.symm)
      rw [findIdx_cons_ne hxw, findIdx_cons_ne hxd] at hlt
      have ih := findIdx_filter_lt q hw hd hm' (by omega)
      simp only [List.filter_cons]
      split
      · rw [findIdx_cons_ne hxw, findIdx_cons_ne hxd]; omega
      · exact ih

theorem mem_filter_ne {l : List Nat} {w o : Nat} (h : w ∈ l) (ne : w ≠ o) : w ∈ l.filter (· != o) :=
  List.mem_filter.2 ⟨h, by simp [ne]⟩

/-- A step that neither renews nor drops `w`'s ticket keeps `w` in the line and every ticket
behind it behind it. -/
theorem behind_step {s : St} {l : List Nat} {w : Nat} (h : OrderStep s l) (hw : w ∈ s.order)
    (hown : s.owned w = 0) (hend : ended s w = false) :
    w ∈ l ∧ ∀ d, Behind s.order w d → Behind l w d := by
  rcases h with rfl | ⟨o, rfl⟩ | ⟨o, ho, rfl⟩ | ⟨o, ho, rfl⟩
  · exact ⟨hw, fun _ x => x⟩
  · refine ⟨List.mem_append_left _ hw, fun d hd => ?_⟩
    unfold Behind
    rw [findIdx_append_mem hw]
    by_cases hdl : d ∈ s.order
    · rcases hd with x | x
      · exact absurd hdl x
      · right; rw [findIdx_append_mem hdl]; exact x
    · by_cases hdo : d = o
      · subst hdo; right; rw [findIdx_append_not hdl]; exact findIdx_lt_of_mem hw
      · left; simp [hdl, hdo]
  · have hwo : w ≠ o := fun e => by subst e; omega
    have hwf : w ∈ s.order.filter (· != o) := mem_filter_ne hw hwo
    refine ⟨List.mem_append_left _ hwf, fun d hd => ?_⟩
    unfold Behind renewed
    rw [findIdx_append_mem hwf]
    by_cases hdo : d = o
    · subst hdo
      right
      have hdf : d ∉ s.order.filter (· != d) := by simp
      rw [findIdx_append_not hdf]
      exact findIdx_lt_of_mem hwf
    · by_cases hdl : d ∈ s.order
      · rcases hd with x | x
        · exact absurd hdl x
        · right
          have hdf : d ∈ s.order.filter (· != o) := mem_filter_ne hdl hdo
          rw [findIdx_append_mem hdf]
          exact findIdx_filter_lt _ (by simp [hwo]) (by simp [hdo]) hw x
      · left; simp [hdl, hdo]
  · have hwo : w ≠ o := fun e => by subst e; rw [hend] at ho; cases ho
    refine ⟨mem_filter_ne hw hwo, fun d hd => ?_⟩
    unfold Behind
    by_cases hdo : d = o
    · subst hdo; left; simp
    · rcases hd with x | x
      · left; intro hm; exact x (List.mem_filter.1 hm).1
      · right; exact findIdx_filter_lt _ (by simp [hwo]) (by simp [hdo]) hw x

/-! ### A waiter that holds nothing is not done -/

theorem ceilDiv_pos {a b : Nat} (h : 0 < ceilDiv a b) : 0 < a := by
  unfold ceilDiv at h
  refine Nat.pos_of_ne_zero fun e => ?_
  subst e
  simp only [Nat.zero_add] at h
  rcases Nat.eq_zero_or_pos b with hb | hb
  · subst hb; simp at h
  · have : (b - 1) / b = 0 := Nat.div_eq_of_lt (by omega)
    omega

theorem pendingN_pos {cfg : Cfg} {s : St} {w : Nat} (hwd : drainOp cfg w = false)
    (h : 0 < demand cfg s w) : 0 < s.pendingN w := by
  unfold demand at h
  split at h
  · rw [hwd] at h
    simp only [Bool.false_eq_true, ite_false] at h
    have := ceilDiv_pos (Nat.lt_of_lt_of_le h (Nat.min_le_right _ _))
    omega
  · cases h

theorem ended_false {cfg : Cfg} {s : St} {w : Nat} (hwd : drainOp cfg w = false)
    (h : starving cfg s w = true) : ended s w = false := by
  simp only [starving, Bool.and_eq_true, decide_eq_true_eq] at h
  have hp := pendingN_pos hwd h.1.2
  unfold St.pendingN at hp
  rw [List.countP_pos_iff] at hp
  obtain ⟨t, ht, htp⟩ := hp
  cases he : ended s w
  · rfl
  · unfold ended at he
    have := List.all_eq_true.1 he t ht
    simp only [pendingT, beq_iff_eq] at htp
    simp [htp] at this

theorem owned_zero {cfg : Cfg} {s : St} {w : Nat} (h : starving cfg s w = true) : s.owned w = 0 := by
  simp only [starving, Bool.and_eq_true, beq_iff_eq] at h
  omega

/-! ### Drains that queued after a waiter never pass it -/

/-- While `w` (no drain) waits holding nothing from time `T` to time `m`, it keeps its ticket and
every ticket that was behind it at `T` (or that came later) stays behind it. -/
theorem behind_run {cfg : Cfg} (r : RunX cfg) {w T : Nat} (hwd : drainOp cfg w = false)
    (hwT : w ∈ (r.st T).order) :
    ∀ m, T ≤ m → (∀ k, T ≤ k → k < m → starving cfg (r.st k) w = true) →
      w ∈ (r.st m).order ∧ ∀ d, Behind (r.st T).order w d → Behind (r.st m).order w d := by
  intro m hm
  induction m, hm using le_induction with
  | base => exact fun _ => ⟨hwT, fun _ x => x⟩
  | succ m hm ih =>
    intro hst
    obtain ⟨h1, h2⟩ := ih (fun k hk hkm => hst k hk (by omega))
    have hs := hst m hm (by omega)
    cases ha : r.act m with
    | none => rw [r.stays m ha]; exact ⟨h1, h2⟩
    | some a =>
      have e := r.moves m a ha
      obtain ⟨h3, h4⟩ := behind_step (moveX_order e) h1 (owned_zero hs) (ended_false hwd hs)
      exact ⟨h3, fun d hd => h4 d (h2 d hd)⟩

theorem drainer_spec {cfg : Cfg} {s : St} {d : Nat} (hl : cfg.rules.drainLets = true)
    (hm : cfg.rules.drainMost = true) (e : drainer cfg s = some d) :
    d ∈ s.order ∧ gathers cfg s d = true := by
  unfold drainer at e
  rw [hl, hm] at e
  simp only [ite_true] at e
  rcases foldl_pick_spec (fun o => drainOp cfg o && decide (demand cfg s o > 0))
      (fun o b => s.owned o + s.grants o > s.owned b + s.grants b) s.order none d e with x | ⟨h1, h2⟩
  · cases x
  · exact ⟨h1, h2⟩

/-- **No younger drain passes a waiter** (0.34.0, every configuration). In a run of `moveX` under
the released rules, let `w` (no drain) wait holding nothing from time `T` through time `m`, with
a ticket at `T`. If at `m` a free CPU would go to a drain (`target`), then some drain that gathers
at `m` queued before `w`: it held a ticket ahead of `w`'s at `T`. A drain that queued after `w`,
or came back after `T`, never takes a CPU ahead of it, alone. -/
theorem released_no_younger_pass {cfg : Cfg} (hr : cfg.rules = Rules.released) (r : RunX cfg)
    {w T m g : Nat} (hwd : drainOp cfg w = false) (hwT : w ∈ (r.st T).order) (hm : T ≤ m)
    (hst : ∀ k, T ≤ k → k ≤ m → starving cfg (r.st k) w = true)
    (htg : target cfg (r.st m) = some g) (hg : drainOp cfg g = true) :
    ∃ d, gathers cfg (r.st m) d = true ∧ d ∈ (r.st T).order ∧
      (r.st T).order.findIdx (· == d) < (r.st T).order.findIdx (· == w) := by
  have hl : cfg.rules.drainLets = true := by rw [hr]; rfl
  have hmo : cfg.rules.drainMost = true := by rw [hr]; rfl
  obtain ⟨hwm, hbeh⟩ := behind_run r hwd hwT m hm (fun k hk hkm => hst k hk (by omega))
  have hsw := hst m hm (Nat.le_refl _)
  have hww : waiter cfg (r.st m) w = true := by
    simp only [starving, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hsw
    simp only [waiter, liveOp, hsw.1.1, Bool.true_or, Bool.true_and, decide_eq_true_eq, hsw.1.2,
      Bool.and_eq_true, true_and]
    rw [hr]; rfl
  have h0 : (r.st m).owned w + (r.st m).grants w = 0 := by
    simp only [starving, Bool.and_eq_true, beq_iff_eq] at hsw; exact hsw.2
  have hfifo := fifo_no_pass (by rw [hr]; rfl) hl htg hg hwm hww hwd h0
  -- The oldest gathering drain.
  have hd : ∃ t, turnOf cfg (r.st m) = some t := by
    cases hdr : drainer cfg (r.st m) with
    | some d =>
      obtain ⟨hdm, hdg⟩ := drainer_spec hl hmo hdr
      cases ht : turnOf cfg (r.st m) with
      | some t => exact ⟨t, rfl⟩
      | none =>
        exact absurd (List.find?_eq_none.1 ht d hdm) (by simp [hdg])
    | none =>
      exfalso
      unfold target at htg
      rw [hdr] at htg
      rcases foldl_pick_spec _ (fun o b => before cfg (r.st m) o b = true) (r.st m).order none g htg
        with x | ⟨hm', hp⟩
      · cases x
      · have := drainer_none_lets hl hdr g hm' hg
        simp only [waiter, Bool.and_eq_true, decide_eq_true_eq] at hp
        omega
  obtain ⟨t, ht⟩ := hd
  have htg' : gathers cfg (r.st m) t = true := List.find?_some ht
  have htm : t ∈ (r.st m).order := List.mem_of_find?_eq_some ht
  have hidx : turnIdx cfg (r.st m) = (r.st m).order.findIdx (· == t) := by simp [turnIdx, ht]
  rw [hidx] at hfifo
  have htw : t ≠ w := fun e => by subst e; simp [gathers, hwd] at htg'
  refine ⟨t, htg', Classical.byContradiction fun hn => ?_⟩
  -- `t` is not behind `w` now, so it was behind `w` at `T`: a contradiction.
  have hb : Behind (r.st T).order w t := by
    by_cases htT : t ∈ (r.st T).order
    · right
      have hne := findIdx_ne htT htw
      have : ¬ (r.st T).order.findIdx (· == t) < (r.st T).order.findIdx (· == w) :=
        fun x => hn ⟨htT, x⟩
      omega
    · left; exact htT
  rcases hbeh t hb with x | x
  · exact x htm
  · have hne := findIdx_ne htm htw
    omega

end Cpuq
