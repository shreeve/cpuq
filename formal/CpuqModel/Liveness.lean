/-
Liveness, the parts proved in general:

- `handout_conserves` (L2, work conservation): right after a hand-out pass no token is free
  while anyone is in line. Every step that frees a token (release, kill, stop) and every arrival
  runs the pass in the same atomic step; tokens a crash frees wait only for the next pass (the
  1 s fallback, `Act.handout`, assumed weakly fair).
- `standing_line`: with a standing line (FINAL-PLAN rule 4), "no one in line" means no living
  operation wants a slot, so L2 says no CPU idles while anyone has work.
- `zero_head_can_drain` (no tie-rule starvation, F2 fixed): under FINAL-PLAN's rules, when the
  head of the line holds nothing and no drain is yet owed for it, every other alive holder may
  drain a slot for it.
- `drain_is_transfer`: a drain under the share clause is a transfer `Transfers.shareOk` allows,
  so Lemma P (`Transfers.run_bounded`, `Transfers.no_reverse`) bounds them and rules out
  ping-pong.

What is not proved here, but searched (`Checks.lean`, `L3 never` and `L3 fair`), is that every
waiter is eventually served under weak fairness; README says why.
-/
import CpuqModel.Safety
import CpuqModel.Transfers

namespace Cpuq

attribute [-simp] List.getD_eq_getElem?_getD

/-! ### A hand-out pass -/

theorem grantOne_of_head_none {cfg : Cfg} {s : St} {c : Nat} (h : head cfg s = none) :
    grantOne cfg s c = s := by
  unfold grantOne; split
  · rw [h]
  · rfl

theorem handoutOver_of_head_none {cfg : Cfg} {s : St} (h : head cfg s = none) (cs : List Nat) :
    handoutOver cfg s cs = s := by
  induction cs with
  | nil => rfl
  | cons c cs ih => simp only [handoutOver, grantOne_of_head_none h, ih]

theorem grantOne_ops (cfg : Cfg) (s : St) (c : Nat) : (grantOne cfg s c).ops = s.ops := by
  unfold grantOne; split
  · split <;> rfl
  · rfl

theorem grantOne_len (cfg : Cfg) (s : St) (c : Nat) : (grantOne cfg s c).cpus.length = s.cpus.length := by
  unfold grantOne; split
  · split
    · simp
    · rfl
  · rfl

theorem isAlive_congr {s t : St} (h : s.ops = t.ops) (o : Nat) : s.isAlive o = t.isAlive o := by
  simp [St.isAlive, St.op, h]

theorem liveOp_congr {cfg : Cfg} {s t : St} (h : s.ops = t.ops) (o : Nat) : liveOp cfg s o = liveOp cfg t o := by
  simp [liveOp, St.isAlive, St.op, h]

theorem validGrantC_congr {cfg : Cfg} {s t : St} (h : s.ops = t.ops) (x : Cpu) :
    validGrantC cfg s x = validGrantC cfg t x := by
  unfold validGrantC; split
  · rfl
  · rw [liveOp_congr h]

theorem freeC_congr {cfg : Cfg} {s t : St} (h : s.ops = t.ops) (x : Cpu) :
    freeC cfg s x = freeC cfg t x := by
  simp only [freeC, validGrantC_congr h]

/-- A token that is not free stays as it is through a grant. -/
theorem grantOne_keeps {cfg : Cfg} {s : St} {c c' : Nat} (hf : freeC cfg s (s.cpu c') = false) :
    (grantOne cfg s c).cpu c' = s.cpu c' := by
  unfold grantOne; split
  · rename_i f
    split
    · rw [St.cpu_setCpu]; split
      · rename_i e; obtain ⟨rfl, -⟩ := e; rw [f] at hf; cases hf
      · rfl
    · rfl
  · rfl

theorem handoutOver_keeps {cfg : Cfg} {s : St} {c' : Nat} (cs : List Nat)
    (hf : freeC cfg s (s.cpu c') = false) :
    (handoutOver cfg s cs).cpu c' = s.cpu c' ∧ (handoutOver cfg s cs).ops = s.ops := by
  induction cs generalizing s with
  | nil => exact ⟨rfl, rfl⟩
  | cons c cs ih =>
    simp only [handoutOver]
    have k := grantOne_keeps (c := c) hf
    have o := grantOne_ops cfg s c
    have hf' : freeC cfg (grantOne cfg s c) ((grantOne cfg s c).cpu c') = false := by
      rw [k, freeC_congr o]; exact hf
    obtain ⟨a, b⟩ := ih hf'
    exact ⟨a.trans k, b.trans o⟩

/-- L2: after a pass over `cs`, a token of `cs` is free only if no one is in line. -/
theorem handoutOver_conserves {cfg : Cfg} (cs : List Nat) :
    ∀ (s : St) (c : Nat), c ∈ cs → c < s.cpus.length →
      freeC cfg (handoutOver cfg s cs) ((handoutOver cfg s cs).cpu c) = true →
      head cfg (handoutOver cfg s cs) = none := by
  induction cs with
  | nil => intro s c hc; cases hc
  | cons c0 cs ih =>
    intro s c hc hlen hf
    simp only [handoutOver] at hf ⊢
    rcases List.mem_cons.1 hc with e | e
    · subst e
      -- What the grant did to c.
      cases hh : head cfg s with
      | none =>
        rw [grantOne_of_head_none hh, handoutOver_of_head_none hh]; exact hh
      | some h =>
        by_cases f0 : freeC cfg s (s.cpu c) = true
        · -- c is granted to h, a living waiter: no longer free, and it stays so.
          have ha : liveOp cfg s h = true := waiter_live (head_waiter hh)
          have g1 : (grantOne cfg s c).cpu c = { s.cpu c with grant := some h } := by
            unfold grantOne; rw [ite_eq_left f0, hh]; simp only
            rw [St.cpu_setCpu]; simp [hlen]
          have nf : freeC cfg (grantOne cfg s c) ((grantOne cfg s c).cpu c) = false := by
            rw [g1]; simp [freeC, validGrantC, liveOp_congr (grantOne_ops cfg s c), ha]
          obtain ⟨k, _⟩ := handoutOver_keeps cs nf
          rw [k, freeC_congr (handoutOver_keeps cs nf).2, nf] at hf; cases hf
        · have nf : freeC cfg (grantOne cfg s c) ((grantOne cfg s c).cpu c) = false := by
            rw [grantOne_keeps (by simpa using f0), freeC_congr (grantOne_ops cfg s c)]
            simpa using f0
          obtain ⟨k, _⟩ := handoutOver_keeps cs nf
          rw [k, freeC_congr (handoutOver_keeps cs nf).2, nf] at hf; cases hf
    · exact ih _ c e (by rw [grantOne_len]; exact hlen) hf

/-- L2, work conservation: right after a hand-out pass, a token is free only if no one is in
line. -/
theorem handout_conserves (cfg : Cfg) (s : St) (c : Nat) (hc : c < s.cpus.length)
    (hf : freeC cfg (handout cfg s) ((handout cfg s).cpu c) = true) : head cfg (handout cfg s) = none :=
  handoutOver_conserves _ s c (List.mem_range.2 hc) hc hf

/-! ### The line -/

theorem foldl_head_some (cfg : Cfg) (s : St) (l : List Nat) (init : Option Nat)
    (hi : init.isSome) :
    (l.foldl (fun best o =>
      if waiter cfg s o then
        match best with
        | none => some o
        | some b => if before cfg s o b then some o else best
      else best) init).isSome := by
  induction l generalizing init with
  | nil => exact hi
  | cons o l ih =>
    simp only [List.foldl_cons]; apply ih
    split
    · cases init with
      | none => cases hi
      | some b => simp only; split <;> rfl
    · exact hi

/-- If anyone in the tickets is a waiter, the line has a head. -/
theorem head_some {cfg : Cfg} {s : St} {o : Nat} (ho : o ∈ s.order) (w : waiter cfg s o = true) :
    (head cfg s).isSome := by
  unfold head
  obtain ⟨l1, l2, e⟩ := List.append_of_mem ho
  rw [e, List.foldl_append, List.foldl_cons]
  apply foldl_head_some
  rw [ite_eq_left w]
  split <;> (try split) <;> simp_all

/-- With a standing line, no head means no living operation that has arrived wants a slot. -/
theorem standing_line {cfg : Cfg} {s : St} (hst : cfg.rules.standing = true) (h : head cfg s = none)
    (o : Nat) (ho : o ∈ s.order) (ha : (s.op o).phase = .alive) : demand cfg s o = 0 := by
  refine Classical.byContradiction fun hd => ?_
  have w : waiter cfg s o = true := by
    have l : liveOp cfg s o = true := by simp [liveOp, St.isAlive, ha]
    simp only [waiter, l, hst, Bool.and_eq_true, Bool.true_or, decide_eq_true_eq, and_true, true_and]
    omega
  have := head_some ho w
  rw [h] at this; cases this

/-! ### Drains -/

/-- No tie-rule starvation (F2): under FINAL-PLAN's ledger and share rule, when the head holds
nothing and a drain is still owed, any other alive operation may drain any slot it holds that
is not draining. -/
theorem zero_head_can_drain {cfg : Cfg} {s : St} {h o c : Nat}
    (hl : cfg.rules.ledger = true) (hsh : cfg.rules.shareRule = true)
    (hgb : cfg.rules.giverBehind = false) (hog : cfg.rules.oneGiver = false)
    (hh : head cfg s = some h) (hz : eff cfg s h = 0) (hne : h ≠ o)
    (ha : (s.op o).phase = .alive) (hsl : (s.cpu c).slot = some { owner := o })
    (hneed : s.drains < need cfg s) : canDrain cfg s o c = true := by
  unfold canDrain mayGive yieldTo
  simp [St.isAlive, ha, hsl, hl, hh, hsh, hz, hgb, hog, hne, hneed]

/-- A drain under the share clause is a transfer Lemma P counts: between the giver's project p
and the head's project q, measured in slots held as the line counts them. -/
theorem drain_is_transfer {cfg : Cfg} {s : St} {h o c : Nat}
    (hl : cfg.rules.ledger = true) (hsh : cfg.rules.shareRule = true)
    (hd : canDrain cfg s o c = true) (hh : head cfg s = some h) (hz : eff cfg s h ≠ 0) :
    Transfers.shareOk cfg.w (projEff cfg s) (cfg.op o).proj (cfg.op h).proj := by
  have m : mayGive cfg s o h c = true := by
    unfold canDrain at hd
    simp only [hl, hh, ite_true, Bool.and_eq_true] at hd
    exact hd.2.1.2
  unfold mayGive at m
  simp only [Bool.and_eq_true] at m
  have y := m.1.2
  simp only [yieldTo, hsh, ite_true, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
    beq_iff_eq, hz, or_false] at y
  exact y

/-! ### Every operation that started holds a ticket -/

/-- Started and not finished. -/
def started (p : Phase) : Prop := p = .alive ∨ p = .stopped ∨ p = .dead

theorem grantOne_order (cfg : Cfg) (s : St) (c : Nat) : (grantOne cfg s c).order = s.order := by
  unfold grantOne; split
  · split <;> rfl
  · rfl

theorem handout_order_ops (cfg : Cfg) (s : St) :
    (handout cfg s).order = s.order ∧ (handout cfg s).ops = s.ops := by
  unfold handout
  generalize List.range s.cpus.length = cs
  induction cs generalizing s with
  | nil => exact ⟨rfl, rfl⟩
  | cons c cs ih =>
    obtain ⟨a, b⟩ := ih (grantOne cfg s c)
    exact ⟨a.trans (grantOne_order cfg s c), b.trans (grantOne_ops cfg s c)⟩

theorem phase_of_ops {s t : St} (h : s.ops = t.ops) (o : Nat) : (s.op o).phase = (t.op o).phase := by
  simp [St.op, h]

theorem takeTok_phase_order (cfg : Cfg) (s : St) (o c o' : Nat) :
    ((takeTok cfg s o c).op o').phase = (s.op o').phase ∧ (takeTok cfg s o c).order = s.order := by
  unfold takeTok
  cases cfg.rules.reclaim
  · exact ⟨rfl, rfl⟩
  · exact ⟨reclaimed_phase s c o', rfl⟩

theorem tryOnce_phase_order (cfg : Cfg) (s : St) (o o' : Nat) :
    ((tryOnce cfg s o).op o').phase = (s.op o').phase ∧ (tryOnce cfg s o).order = s.order := by
  unfold tryOnce
  split
  · split
    · exact takeTok_phase_order ..
    · exact ⟨rfl, rfl⟩
  · exact ⟨rfl, rfl⟩

theorem reap_phase_order (cfg : Cfg) (s : St) (o i o' : Nat) (ok : Bool) :
    ((reap cfg s o i ok).op o').phase = (s.op o').phase ∧ (reap cfg s o i ok).order = s.order := by
  unfold reap
  obtain ⟨a, b⟩ := tryOnce_phase_order cfg (s.setTask o i _) o o'
  exact ⟨a.trans (St.phase_setTask ..), b⟩

theorem retired_phase (s : St) (o : Nat) (g : Task → Task) (p : Phase) (o' : Nat)
    (ho : o < s.ops.length) :
    ((retired s o g p).op o').phase = if o = o' then p else (s.op o').phase := by
  simp only [St.op, retired, getD_set, ho, and_true]; split <;> rfl

theorem mem_renewed {s : St} {o x : Nat} (h : x ∈ s.order ∨ x = o) : x ∈ renewed s o := by
  unfold renewed
  by_cases e : x = o
  · subst e; simp
  · rcases h with h | h
    · exact List.mem_append_left _ (List.mem_filter.2 ⟨h, by simp [e]⟩)
    · exact absurd h e

/-- Tickets are never taken away, and a step makes an operation started only by its arrival
(which takes a ticket) or by a phase change of one already started. -/
theorem step_tickets {cfg : Cfg} {s s' : St} {a : Act} (e : step cfg s a = some s')
    (hold : ∀ o, started (s.op o).phase → o ∈ s.order) :
    ∀ o, started (s'.op o).phase → o ∈ s'.order := by
  -- Phases are kept by everything except setPhase; tickets only grow.
  have keepTask : ∀ (t : St) o i (x : Task) o', ((t.setTask o i x).op o').phase = (t.op o').phase :=
    fun t o i x o' => St.phase_setTask t o i o' x
  cases a with
  | arrive o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i hw; cases e
      intro o' hs
      obtain ⟨ho1, ho2⟩ := handout_order_ops cfg { s.setPhase o .alive with order := s.order ++ [o] }
      rw [ho1]; rw [phase_of_ops ho2] at hs
      have ho : o < s.ops.length := s.lt_of_phase o (by simp at hw; rw [hw]; decide)
      have e1 : (({ s.setPhase o .alive with order := s.order ++ [o] } : St).op o').phase =
          if o = o' then .alive else (s.op o').phase := St.phase_setPhase s o o' _ ho
      rw [e1] at hs
      by_cases eo : o = o'
      · subst eo; simp
      · simp only [eo, ite_false] at hs; exact List.mem_append_left _ (hold o' hs)
    · cases e
  | exit o i ok =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; intro o' hs
        obtain ⟨p1, p2⟩ := reap_phase_order cfg s o i o' ok
        rw [p1] at hs; rw [p2]; exact hold o' hs
      · split at e
        · cases e; intro o' hs; rw [keepTask] at hs; exact hold o' hs
        · cases e
    · cases e
  | timeout o i =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; intro o' hs; rw [keepTask] at hs; exact hold o' hs
      · cases e
    · cases e
  | gone o i =>
    simp only [Cpuq.step] at e; split at e
    · cases e; intro o' hs; rw [keepTask] at hs; exact hold o' hs
    · cases e
  | refill o c =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; intro o' hs; rw [keepTask] at hs; exact hold o' hs
      · cases e
    · cases e
  | release o c =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; intro o' hs
        rw [(handout_order_ops cfg _).1]; rw [phase_of_ops (handout_order_ops cfg _).2] at hs
        have := hold o' hs
        show o' ∈ (if cfg.rules.renewAtRelease then renewed s _ else s.order)
        split
        · exact mem_renewed (.inl this)
        · exact this
      · cases e
    · cases e
  | handout =>
    simp only [Cpuq.step] at e; split at e
    · cases e; intro o' hs
      obtain ⟨ho1, ho2⟩ := handout_order_ops cfg s
      rw [ho1]; rw [phase_of_ops ho2] at hs; exact hold o' hs
    · cases e
  | accept o c =>
    simp only [Cpuq.step] at e; split at e
    · cases e; intro o' hs
      obtain ⟨p1, p2⟩ := takeTok_phase_order cfg s o c o'
      rw [p1] at hs; rw [p2]; exact hold o' hs
    · cases e
  | drain o c =>
    simp only [Cpuq.step] at e; split at e
    · cases e; intro o' hs
      change (s.op o').phase = _ ∨ _ at hs
      have := hold o' hs
      show o' ∈ (if cfg.rules.ledger && !cfg.rules.renewAtRelease then _ else _)
      split
      · exact mem_renewed (.inl this)
      · exact this
    · cases e
  | undrain o c =>
    simp only [Cpuq.step] at e; split at e
    · cases e; intro o' hs; exact hold o' hs
    · cases e
  | consolidate o i d =>
    simp only [Cpuq.step] at e; split at e
    · split at e
      · cases e; intro o' hs; rw [keepTask] at hs; exact hold o' hs
      · cases e
    · cases e
  | kill o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e; intro o' hs
      have ha : (s.op o).phase = .alive := by simp [St.isAlive] at g; exact g.2
      have ho := s.lt_of_phase o (by rw [ha]; decide)
      rw [(handout_order_ops cfg _).1]; rw [phase_of_ops (handout_order_ops cfg _).2] at hs
      rw [retire_eq _ _ _ _ ho] at hs ⊢
      rw [retired_phase _ _ _ _ _ ho] at hs
      show o' ∈ s.order
      by_cases eo : o = o'
      · subst eo; simp [started] at hs
      · simp only [eo, ite_false] at hs; exact hold o' hs
    · cases e
  | crash o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e; intro o' hs
      have hs : started ((s.setPhase o .dead).op o').phase := hs
      by_cases eo : o = o'
      · subst eo
        simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at g
        exact hold o (by rcases g.2 with x | x <;> simp [started, x])
      · rw [St.op_setPhase_ne _ _ _ _ eo] at hs; exact hold o' hs
    · cases e
  | stop o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e; intro o' hs
      have ha : (s.op o).phase = .alive := by simp [St.isAlive] at g; exact g.2
      have ho := s.lt_of_phase o (by rw [ha]; decide)
      rw [(handout_order_ops cfg _).1]; rw [phase_of_ops (handout_order_ops cfg _).2] at hs
      rw [retire_eq _ _ _ _ ho] at hs ⊢
      rw [retired_phase _ _ _ _ _ ho] at hs
      show o' ∈ s.order
      by_cases eo : o = o'
      · subst eo; exact hold o (by simp [started, ha])
      · simp only [eo, ite_false] at hs; exact hold o' hs
    · cases e
  | cont o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e; intro o' hs
      by_cases eo : o = o'
      · subst eo; exact hold o (by simp at g; simp [started, g])
      · rw [St.op_setPhase_ne _ _ _ _ eo] at hs; exact hold o' hs
    · cases e
  | finish o =>
    simp only [Cpuq.step] at e; split at e
    · rename_i g; cases e; intro o' hs
      by_cases eo : o = o'
      · subst eo
        have ho : o < s.ops.length := s.lt_of_phase o (by
          simp [St.isAlive] at g; rw [g.1.1]; decide)
        rw [St.phase_setPhase _ _ _ _ ho] at hs; simp [started] at hs
      · rw [St.op_setPhase_ne _ _ _ _ eo] at hs; exact hold o' hs
    · cases e

theorem Reach.tickets {cfg : Cfg} {s : St} (r : Reach cfg s) :
    ∀ o, started (s.op o).phase → o ∈ s.order := by
  induction r with
  | init =>
    intro o hs
    exfalso
    simp only [St.op, Cpuq.init, List.getD_eq_getElem?_getD, List.getElem?_map] at hs
    cases h : cfg.ops[o]? <;> simp [h, started] at hs
  | step a _ e ih => exact step_tickets e ih

/-- L2 for every reachable state under a standing line: right after a hand-out pass, if a token
is free then no living operation wants a slot. -/
theorem work_conserving {cfg : Cfg} {s : St} (r : Reach cfg s) (hst : cfg.rules.standing = true)
    (c : Nat) (hc : c < s.cpus.length)
    (hf : freeC cfg (handout cfg s) ((handout cfg s).cpu c) = true)
    (o : Nat) (ha : ((handout cfg s).op o).phase = .alive) : demand cfg (handout cfg s) o = 0 := by
  have hh := handout_conserves cfg s c hc hf
  obtain ⟨ho1, ho2⟩ := handout_order_ops cfg s
  apply standing_line hst hh o _ ha
  rw [ho1]; rw [phase_of_ops ho2] at ha
  exact r.tickets o (by simp [started, ha])

end Cpuq
