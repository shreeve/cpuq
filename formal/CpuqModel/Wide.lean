import CpuqModel.Token

/-!
cpuq 0.43.0: tasks that hold several tokens (`cpuq run -j K`, `RunCfg.width`, `Cfg.wd`).

Each task of a run holds `K` tokens while it runs (`tokT`, so `used`); it takes them in one step
when `K` are free (`used + K ≤ capTok`) and gives all `K` back when it ends. The line is 0.41's
and 0.42's. A wide task first in line that does not fit:
- rule 4(a), `Rules.hold` (`Rules.wide043a`): holds the line; freed tokens go to no one else;
- rule 4(b), no hold (`Rules.wide043b`): the line skips it (`cand`), and the next that fits starts.

With every `K = 1` both are 0.42 (`Token.lean`). Tokens are counted, not named: which CPUs a task
gets (whole cores, the fewest cores) is not modelled.
-/

namespace Cpuq.Contest

/-! ## 1. Tokens held, with tasks of any `K` -/

/-- **Property 1.** With tokens and tasks of any `K`, in every reachable state at most `pool`
tokens are held (each running task's `K`, plus the started drains' cores), and every start of the
pass leaves at most `capTok ≤ N` held: "no token has two holders" is that the holders' tokens
never number more than the tokens. (`tok_within` and `tok_over_no_start` hold for any `K` too.) -/
theorem wide_within {cfg : Cfg} (htk : cfg.rules.tokens = true) :
    (∀ s, ReachS cfg s → used cfg s = rsum cfg.nr (fun r => (s.run r).running * cfg.wd r) + iso cfg s ∧
      used cfg s ≤ cfg.pool) ∧
    (∀ s t, pass1 cfg s = some t → used cfg t ≤ capTok cfg t ∧ capTok cfg t ≤ capN cfg t) :=
  ⟨fun _ h => ⟨rfl, tok_le_pool htk h⟩, fun _ _ e => tok_start_within htk e⟩

/-! ## 2. All at once -/

theorem used_fin {cfg : Cfg} {s u : St} {r : Nat} (hr : r < cfg.nr) (hd : u.drain = s.drain)
    (ho : ∀ j, j ≠ r → u.run j = s.run j) (he : (u.run r).running + 1 = (s.run r).running) :
    used cfg u + cfg.wd r = used cfg s := by
  have h1 := rsum_upd (f := fun j => (s.run j).running * cfg.wd j) (g := fun j => (u.run j).running * cfg.wd j) hr
    (fun j hj => by simp only [ho j hj])
  have h2 : (s.run r).running * cfg.wd r = (u.run r).running * cfg.wd r + cfg.wd r := by rw [← he, Nat.succ_mul]
  have hi : iso cfg u = iso cfg s := by unfold iso; rw [hd]
  unfold used tokT; try dsimp only at h1
  omega

/-- **Property 2: a wide task takes its `K` tokens at once and gives them back at once.** The tokens
a run holds are `K` for each task running: a waiting task holds none, so no task holds part of its
`K`. A start (in the pass) takes exactly `K`; a task's end gives back exactly `K`. -/
theorem wide_all_at_once {cfg : Cfg} :
    (∀ s, used cfg s = rsum cfg.nr (fun r => (s.run r).running * cfg.wd r) + iso cfg s) ∧
    (∀ s r, r < cfg.nr → used cfg (admit s r) = used cfg s + cfg.wd r) ∧
    (∀ s u r a, finOf r a → act cfg s a = some u → used cfg u + cfg.wd r = used cfg s) := by
  refine ⟨fun _ => rfl, fun _ _ hr => used_admit hr, fun s u r a hf h => ?_⟩
  have hg := act_guard h
  have hd : u.drain = s.drain := by
    funext d; rw [act_drain h d]
    cases a <;> simp only [finOf] at hf <;> rfl
  cases a <;> simp only [finOf] at hf <;> subst hf <;> dsimp only at hg <;>
    refine used_fin hg.1 hd (fun j hj => by rw [act_run h j]; simp [runAfter, Ne.symm hj]) ?_ <;>
    rw [act_run h] <;> simp only [runAfter, ite_true, RunSt.running] <;> omega

/-! ## 3, 5. The hold: at most `K − 1` idle tokens, and only while a wide task heads the line -/

/-- **Properties 3 (idle tokens) and 5 (work-conserving but for the hold), rule 4(a).** In every
reachable state, if a run waits (not held by its `-c`) and the gates are open, the first in the
one line is some `x`, and fewer than its `K` tokens are free: `capTok − used ≤ K − 1`. So a token
stays idle only while a wide task (`K ≥ 2`) heads the line and fewer than `K` are free, and at
most `K − 1` do; with `K = 1` none does. -/
theorem wide_hold_bound {cfg : Cfg} (htk : cfg.rules.tokens = true) (hhold : cfg.rules.hold = true)
    {s : St} (h : ReachS cfg s) {r : Nat} (hr : r < cfg.nr) (he : eligible s r = true) (hg : s.gate = true) :
    ∃ x < cfg.nr, head2 cfg s = some x ∧ capTok cfg s < used cfg s + cfg.wd x := by
  obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head2_isSome hr (cand_of (.inr hhold) he))
  obtain ⟨hxn, hxe⟩ := head2_some hx
  refine ⟨x, hxn, hx, Classical.byContradiction fun hn => ?_⟩
  have hfx : used cfg s + cfg.wd x ≤ capTok cfg s := by omega
  have hc := reachS_start h hxn
  simp only [front, Bool.and_eq_true] at hxe
  have hxel := cand_elig hxe.1
  simp [canStart, hxel, hxe.2, hg, hfx, hx, htk] at hc

/-- Rule 4(b) is work-conserving outright: if a run waits with the gates open, its `K` tokens are
not free. -/
theorem nohold_conserving {cfg : Cfg} (htk : cfg.rules.tokens = true) (hhold : cfg.rules.hold = false)
    {s : St} (h : ReachS cfg s) {r : Nat} (hr : r < cfg.nr) (he : eligible s r = true) (hg : s.gate = true) :
    capTok cfg s < used cfg s + cfg.wd r := by
  apply Classical.byContradiction; intro hn
  have hce : cand cfg s r = true := by
    have : used cfg s + cfg.wd r ≤ capTok cfg s := by omega
    simp [cand, fits, he, hhold, htk, this]
  obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head2_isSome hr hce)
  obtain ⟨hxn, hxe⟩ := head2_some hx
  have hc := reachS_start h hxn
  simp only [front, Bool.and_eq_true] at hxe
  have hxel := cand_elig hxe.1
  have hfx : used cfg s + cfg.wd x ≤ capTok cfg s := by
    have := hxe.1
    simp only [cand, fits, htk, hhold, Bool.not_true, Bool.false_or, Bool.and_eq_true, decide_eq_true_eq] at this
    exact this.2
  simp [canStart, hxel, hxe.2, hg, hfx, hx, htk] at hc

/-! ## 3. No starvation with the hold -/

/-- **Property 3, rule 4(a), when a task fits beside the largest drains.** On the 0.43 rules with
the hold, with arrivals that never stop, a waiting run (wide or not) starts a task if from then on
no urgent run arrives, every task ends, one tick passes, and again and again the gates are open
while outside load is within the reserve and every `K + drain_max ≤ N`. -/
theorem wide_run_starts_fit {cfg : Cfg} (_htk : cfg.rules.tokens = true) (hak : cfg.rules.arrivalKey = true)
    (hol : cfg.rules.oneLine = true) (hhold : cfg.rules.hold = true) (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (noUrgent : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).urgent = false)
    (ends : ∀ m b, b < cfg.nr → 0 < ((ρ.st m).run b).running → ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (htime : ∃ m ≥ n, ρ.mv m = .act .tick)
    (gates : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true ∧ (ρ.st m').outside ≤ (ρ.st m').reserve ∧
      ∀ x < cfg.nr, cfg.drainMax + cfg.wd x ≤ cfg.pool - (ρ.st m').reserve) :
    ∃ m ≥ n, ((ρ.st m).run r).pend < ((ρ.st n).run r).pend := by
  have hD : cfg.drainMax < cfg.pool := by
    obtain ⟨m, _, _, _, h⟩ := gates 0; have := h r hr; have := wd_pos cfg r; omega
  exact run_starts_fixed hak hol hD ρ hr hh hp noUrgent ends htime (.inr hhold)
    (fun m => let ⟨m', hm, hg, ho, hd⟩ := gates m; ⟨m', hm, hg, fun _ => ⟨ho, hd⟩⟩)

/-! The general case, `K ≤ drain_max < N`: a drain older than the waiting run may hold its cores
while every task has ended, so the wide task at the head needs them back. Ticks end it (its limit
and grace); drains newer than the run wait for it (0.41's turn). A measure over the drains: -/

section
variable (cfg : Cfg)

/-- A started drain: the ticks it may still hold its cores, plus one. A drain that waits with a
ticket no newer than `T0`: one more than the most a start gives it. Else 0. -/
def dvF (T0 d : Nat) (y : DrainSt) : Nat :=
  if y.ph = .started then cfg.limitOf d + cfg.grace + 1 - y.age
  else if y.ph = .waiting ∧ y.ticket ≤ T0 then cfg.limitOf d + cfg.grace + 2 else 0

def DQ (T0 : Nat) (s : St) : Nat := rsum cfg.nd (fun d => dvF cfg T0 d (s.drain d))
end

/-- What a move does to a drain before the pass. -/
theorem pre_drain {cfg : Cfg} {s u : St} {m : Move} (h : pre cfg s m u) (d : Nat) :
    ((s.drain d).ph = .started → ((u.drain d).ph = .started ∧
      (u.drain d).age = (s.drain d).age + (if m.isTick then 1 else 0)) ∨ (u.drain d).ph = .over) ∧
    ((s.drain d).ph = .waiting → (u.drain d).ph = .waiting ∧ (u.drain d).ticket = (s.drain d).ticket) ∧
    ((s.drain d).ph ≠ .started → (s.drain d).ph ≠ .waiting →
      (u.drain d).ph ≠ .started ∧ ((u.drain d).ph = .waiting → (u.drain d).ticket = s.next)) := by
  cases m with
  | act a =>
    have hu : act cfg s a = some u := h
    have hg := act_guard hu
    refine ⟨fun hs => ?_, fun hw => ?_, fun h1 h2 => ?_⟩
    · rcases act_started hu hs with ⟨e1, e2, _⟩ | e1
      · exact Or.inl ⟨e1, e2⟩
      · exact Or.inr e1
    · rw [act_drain hu d]
      cases a with
      | arriveD e =>
        dsimp only at hg; simp only [drainAfter]; split
        · rename_i hed; subst hed; rw [hw] at hg; cases hg.2
        · exact ⟨hw, rfl⟩
      | dbusy e b => simp only [drainAfter]; split <;> exact ⟨hw, rfl⟩
      | dend e =>
        dsimp only at hg; simp only [drainAfter]; split
        · rename_i hed; subst hed; rw [hw] at hg; cases hg.2
        · exact ⟨hw, rfl⟩
      | tick => simp [drainAfter, tickD, hw]
      | _ => exact ⟨hw, rfl⟩
    · rw [act_drain hu d]
      cases a with
      | arriveD e =>
        simp only [drainAfter]; split
        · exact ⟨by simp, fun _ => rfl⟩
        · exact ⟨h1, fun x => absurd x h2⟩
      | dbusy e b => simp only [drainAfter]; split <;> exact ⟨h1, fun x => absurd x h2⟩
      | dend e =>
        dsimp only at hg; simp only [drainAfter]; split
        · rename_i hed; subst hed; exact absurd hg.2 h1
        · exact ⟨h1, fun x => absurd x h2⟩
      | tick => simp only [drainAfter, tickD, h1, ite_false]; exact ⟨h1, fun x => absurd x h2⟩
      | _ => exact ⟨h1, fun x => absurd x h2⟩
  | leave r =>
    obtain ⟨_, rfl⟩ := h
    have e : (setRun s r {}).drain d = s.drain d := rfl
    rw [e]
    exact ⟨fun hs => Or.inl ⟨hs, by simp [Move.isTick]⟩, fun hw => ⟨hw, rfl⟩, fun h1 h2 => ⟨h1, fun x => absurd x h2⟩⟩
  | leaveD e =>
    obtain ⟨⟨_, ho⟩, rfl⟩ := h
    by_cases hde : d = e
    · subst hde
      refine ⟨fun hs => (by rw [hs] at ho; cases ho), fun hw => (by rw [hw] at ho; cases ho), fun _ _ => ?_⟩
      simp
    · have e : (setDrain s e {}).drain d = s.drain d := by simp [hde]
      rw [e]
      exact ⟨fun hs => Or.inl ⟨hs, by simp [Move.isTick]⟩, fun hw => ⟨hw, rfl⟩, fun h1 h2 => ⟨h1, fun x => absurd x h2⟩⟩

/-- One step, for one drain, while run `r` (ticket `T0`) waits holding nothing and holds nothing
after the step: the measure does not go up; it goes down when a started drain ages (a tick) or
stops, and when a drain starts (only one no newer than `T0` may, `drainFifo`). -/
theorem dv_step {cfg : Cfg} (hf : cfg.rules.drainFifo = true) {s u : St} {m : Move} (h : pre cfg s m u)
    (i : Inv cfg s) {T0 r : Nat} (hr : r < cfg.nr) (hT : T0 < s.next) (hew : emptyWaiter u r = true)
    (htr : (u.run r).ticket = T0) (h0 : ((pass cfg u).run r).running = 0) (d : Nat) :
    dvF cfg T0 d ((pass cfg u).drain d) ≤ dvF cfg T0 d (s.drain d) ∧
    ((s.drain d).ph = .started → (m.isTick = true ∨ ((pass cfg u).drain d).ph ≠ .started) →
      dvF cfg T0 d ((pass cfg u).drain d) < dvF cfg T0 d (s.drain d)) ∧
    ((s.drain d).ph ≠ .started → ((pass cfg u).drain d).ph = .started →
      dvF cfg T0 d ((pass cfg u).drain d) < dvF cfg T0 d (s.drain d)) := by
  have fr := (pass_path cfg u).frame
  have keep : (u.drain d).ph ≠ .waiting → (pass cfg u).drain d = u.drain d := fr.2.2.1 d
  have tkt : ((pass cfg u).drain d).ticket = (u.drain d).ticket := fr.2.2.2.2 d
  have small : (u.drain d).ph = .waiting → ((pass cfg u).drain d).ph = .started → (u.drain d).ticket ≤ T0 := by
    intro hw hs
    have := ((pass_path cfg u).fifo hf hw hs).1 r hr hew
    apply Nat.not_lt.1; intro hlt; have := this (by rw [htr]; exact hlt); omega
  have it : Inv cfg (pass cfg u) := inv_passN _ (inv_pre i h)
  have pd := pre_drain h d
  -- a started drain after the step: at most `limit + grace + 1`
  have cap : ((pass cfg u).drain d).ph = .started →
      dvF cfg T0 d ((pass cfg u).drain d) ≤ cfg.limitOf d + cfg.grace + 1 := by
    intro hs; simp only [dvF, hs, ite_true]; omega
  by_cases hs : (s.drain d).ph = .started
  · have hsa := (i.clock d hs).1
    have ev : dvF cfg T0 d (s.drain d) = cfg.limitOf d + cfg.grace + 1 - (s.drain d).age := by
      simp only [dvF, hs, ite_true]
    rcases pd.1 hs with ⟨hu1, hu2⟩ | hu1
    · have e := keep (by rw [hu1]; simp)
      have ev' : dvF cfg T0 d ((pass cfg u).drain d) = cfg.limitOf d + cfg.grace + 1 - (u.drain d).age := by
        simp only [dvF, e, hu1, ite_true]
      rw [ev, ev', hu2]
      refine ⟨by split <;> omega, fun _ ht => ?_, fun x => absurd hs x⟩
      rcases ht with ht | ht
      · rw [ht, ite_t (rfl : true = true)]; omega
      · rw [e, hu1] at ht; exact absurd rfl ht
    · have e := keep (by rw [hu1]; simp)
      have ev' : dvF cfg T0 d ((pass cfg u).drain d) = 0 := by simp [dvF, e, hu1]
      rw [ev, ev']
      exact ⟨Nat.zero_le _, fun _ _ => by omega, fun x => absurd hs x⟩
  · by_cases hw : (s.drain d).ph = .waiting
    · obtain ⟨hu1, hu2⟩ := pd.2.1 hw
      by_cases hts : ((pass cfg u).drain d).ph = .started
      · have h1 := small hu1 hts
        have ev : dvF cfg T0 d (s.drain d) = cfg.limitOf d + cfg.grace + 2 := by
          simp only [dvF, hw]; simp [hu2 ▸ h1]
        have := cap hts
        rw [ev]
        exact ⟨by omega, fun x => absurd x hs, fun _ _ => by omega⟩
      · refine ⟨?_, fun x => absurd x hs, fun _ x => absurd x hts⟩
        simp only [dvF, hts, ite_false, hw, tkt, hu2]
        split
        · rename_i hc; simp [hc.2]
        · exact Nat.zero_le _
    · obtain ⟨hu1, hu2⟩ := pd.2.2 hs hw
      have ev : dvF cfg T0 d (s.drain d) = 0 := by simp [dvF, hs, hw]
      have z : ((pass cfg u).drain d).ph ≠ .started ∧
          dvF cfg T0 d ((pass cfg u).drain d) = 0 := by
        by_cases huw : (u.drain d).ph = .waiting
        · have hbig := hu2 huw
          have hts : ((pass cfg u).drain d).ph ≠ .started := fun x => by have := small huw x; omega
          refine ⟨hts, ?_⟩
          simp only [dvF, hts, ite_false, tkt, hbig]
          split
          · rename_i hc; omega
          · rfl
        · have e := keep huw
          rw [e]
          exact ⟨hu1, by simp [dvF, hu1, huw]⟩
      rw [ev, z.2]
      exact ⟨Nat.le_refl _, fun x => absurd x hs, fun _ x => absurd x z.1⟩

/-- **Property 3, rule 4(a).** On the 0.43 rules with the hold (`tokens`, `arrivalKey`,
`oneLine`, `drainFifo`, `hold`) and every `K ≤ drain_max`, with arrivals of runs and drains that
never stop, a waiting run (wide or not) starts a task if from then on no urgent run arrives, every
task ends, ticks keep coming, and again and again the gates are open while outside load is within
the reserve and `drain_max < N`. -/
theorem wide_run_starts {cfg : Cfg} (htk : cfg.rules.tokens = true) (hak : cfg.rules.arrivalKey = true)
    (hol : cfg.rules.oneLine = true) (hhold : cfg.rules.hold = true) (hf : cfg.rules.drainFifo = true)
    (hK : ∀ x < cfg.nr, cfg.wd x ≤ cfg.drainMax) (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (noUrgent : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).urgent = false)
    (ends : ∀ m b, b < cfg.nr → 0 < ((ρ.st m).run b).running → ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (ticks : ∀ m, ∃ m' ≥ m, ρ.mv m' = .act .tick)
    (gates : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true ∧ (ρ.st m').outside ≤ (ρ.st m').reserve ∧
      cfg.drainMax < cfg.pool - (ρ.st m').reserve) :
    ∃ m ≥ n, ((ρ.st m).run r).pend < ((ρ.st n).run r).pend := by
  apply Classical.byContradiction
  intro hno
  have hge : ∀ m ≥ n, ((ρ.st n).run r).pend ≤ ((ρ.st m).run r).pend := fun m hm =>
    Nat.not_lt.1 (fun h => hno ⟨m, hm, h⟩)
  have W := waits_on ρ hh hp hge
  obtain ⟨n5, hn5, hq⟩ := starts_stop hak hol (.inr hhold) ρ hr hh hp noUrgent ends (ticks n) hge
  obtain ⟨T0, hT0⟩ : ∃ x, ((ρ.st n).run r).ticket = x := ⟨_, rfl⟩
  have hTm : ∀ m ≥ n, ((ρ.st m).run r).ticket = T0 := fun m hm => (W m hm).2.2.2.2.1.trans hT0
  have hTk : ∀ m ≥ n, T0 < (ρ.st m).next := fun m hm => by
    have := (reachS_tickets (ρ.reach m)).1 r (W m hm).1; rwa [hTm m hm] at this
  -- after `n5`, the drain measure only goes down
  have Dstep : ∀ m ≥ n5, DQ cfg T0 (ρ.st (m + 1)) ≤ DQ cfg T0 (ρ.st m) ∧
      (∀ d < cfg.nd, ((ρ.st m).drain d).ph = .started →
        ((ρ.mv m).isTick = true ∨ ((ρ.st (m + 1)).drain d).ph ≠ .started) →
        DQ cfg T0 (ρ.st (m + 1)) < DQ cfg T0 (ρ.st m)) ∧
      (∀ d < cfg.nd, ((ρ.st m).drain d).ph ≠ .started → ((ρ.st (m + 1)).drain d).ph = .started →
        DQ cfg T0 (ρ.st (m + 1)) < DQ cfg T0 (ρ.st m)) := by
    intro m hm
    obtain ⟨u, hu, ht⟩ := stepS_pre (ρ.steps m)
    have hs := W m (by omega)
    obtain ⟨w1, w2, _, _, w5, w6, _⟩ := pre_waiting hu hs.1 (by rw [hs.2.1]; exact hp)
    have hew : emptyWaiter u r = true := by
      have := (hq m hm).1 r hr
      simp only [emptyWaiter, w1, Bool.true_and, Bool.and_eq_true, decide_eq_true_eq]
      exact ⟨by rw [w2, hs.2.1]; exact hp, by omega⟩
    have h0 : ((pass cfg u).run r).running = 0 := by rw [← ht]; exact (hq (m + 1) (by omega)).1 r hr
    have per := fun d => dv_step hf hu (reachS_inv (ρ.reach m)).1 hr (hTk m (by omega)) hew
      (w5.trans (hTm m (by omega))) h0 d
    rw [ht]
    refine ⟨rsum_le (fun d _ => (per d).1), fun d hd h1 h2 => ?_, fun d hd h1 h2 => ?_⟩
    · exact rsum_lt (fun j _ => (per j).1) hd ((per d).2.1 h1 h2)
    · exact rsum_lt (fun j _ => (per j).1) hd ((per d).2.2 h1 h2)
  obtain ⟨n6, hn6, hc6⟩ := eventually_const (fun m => DQ cfg T0 (ρ.st m)) n5 (fun m hm => (Dstep m hm).1)
  -- after `n6` no drain starts or stops, and a tick would lower the measure: none is started
  have stay : ∀ m ≥ n6, ∀ d < cfg.nd, ((ρ.st m).drain d).ph = .started →
      ∀ k, ((ρ.st (m + k)).drain d).ph = .started := by
    intro m hm d hd hs k
    induction k with
    | zero => exact hs
    | succ k ih =>
      apply Classical.byContradiction; intro hn
      have := (Dstep (m + k) (by omega)).2.1 d hd ih (Or.inr hn)
      have e1 := hc6 (m + k) (by omega); have e2 := hc6 (m + k + 1) (by omega)
      omega
  have noIso : ∀ m ≥ n6, iso cfg (ρ.st m) = 0 := by
    intro m hm
    apply rsum_eq_zero.2
    intro d hd
    by_cases hs : ((ρ.st m).drain d).ph = .started
    · obtain ⟨m', hm', htk'⟩ := ticks m
      have hs' := stay m hm d hd hs (m' - m)
      rw [show m + (m' - m) = m' by omega] at hs'
      have hti : (ρ.mv m').isTick = true := by rw [htk']; rfl
      have := (Dstep m' (by omega)).2.1 d hd hs' (Or.inl hti)
      have e1 := hc6 m' (by omega); have e2 := hc6 (m' + 1) (by omega)
      omega
    · simp [isoF, hs]
  -- at open gates, nothing held: the first in line fits and starts
  obtain ⟨m, hm, hg, ho, hD⟩ := gates n6
  have hs := W m (by omega)
  have i := (reachS_inv (ρ.reach m)).1
  have htokT : tokT cfg (ρ.st m) = 0 :=
    rsum_eq_zero.2 (fun b hb => by rw [(hq m (by omega)).1 b hb, Nat.zero_mul])
  have hused : used cfg (ρ.st m) = 0 := by unfold used; rw [htokT, noIso m hm]
  have hel : eligible (ρ.st m) r = true := by
    have h1 := i.cap r hs.1; have h2 := (hq m (by omega)).1 r hr
    simp only [eligible, hs.1, Bool.true_and, Bool.and_eq_true, decide_eq_true_eq]
    exact ⟨by rw [hs.2.1]; exact hp, by omega⟩
  obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head2_isSome hr (cand_of (.inr hhold) hel))
  obtain ⟨hxn, hxe⟩ := head2_some hx
  have hc := reachS_start (ρ.reach m) hxn
  simp only [front, Bool.and_eq_true] at hxe
  have hxel := cand_elig hxe.1
  have hfx : used cfg (ρ.st m) + cfg.wd x ≤ capTok cfg (ρ.st m) := by
    have := hK x hxn
    rw [hused]; unfold capTok capN; omega
  simp [canStart, hxel, hxe.2, hg, hfx, hx, htk] at hc

/-! ## 4. Without the hold, a wide task may wait forever -/

/-- 3 tokens, `drain_max` 2, rule 4(b): run 0 is wide (`K = 2`, project 1); slots 1 … 4 are
one-task, one-token runs of project 0. -/
def wideCfg : Cfg :=
  { pool := 3, drainMax := 2, rules := .wide043b,
    runs := [{ proj := 1, width := 2 }, { proj := 0 }, { proj := 0 }, { proj := 0 }, { proj := 0 }] }

/-- Three runs take the three tokens; the wide run arrives and waits; a fifth run waits; then one
round of the cycle, so every narrow run present arrived after the wide one. -/
def widePre : List Move :=
  [.act (.arrive 1), .act (.arrive 2), .act (.arrive 3), .act .tick, .act (.arrive 0), .act (.arrive 4),
   .act (.finC 1), .leave 1, .act (.arrive 1), .act .tick,
   .act (.finC 2), .leave 2, .act (.arrive 2), .act .tick,
   .act (.finC 3), .leave 3, .act (.arrive 3), .act .tick,
   .act (.finC 4), .leave 4, .act (.arrive 4), .act .tick]

/-- A task ends and frees one token; the wide task needs two, so the line skips it and the waiting
narrow run takes the token; the finished run leaves and comes back to wait; a tick. -/
def wideCyc : List Move :=
  [.act (.finC 1), .leave 1, .act (.arrive 1), .act .tick,
   .act (.finC 2), .leave 2, .act (.arrive 2), .act .tick,
   .act (.finC 3), .leave 3, .act (.arrive 3), .act .tick,
   .act (.finC 4), .leave 4, .act (.arrive 4), .act .tick]

def wideS0 : St := (runMoves wideCfg init widePre).getD init

def wideP (s : St) : Bool :=
  (s.run 0).here && (s.run 0).pend == 1 && s.gate && decide (s.outside ≤ s.reserve) &&
    allLT wideCfg.nr (fun b => (s.run b).running == 0 || wideCyc.any (finB b))

theorem wide_ok : (runMoves wideCfg init widePre).isSome = true ∧
    cycOk wideCfg ⟨4, 4, 2, 4⟩ wideP wideS0 wideCyc = true ∧ wideCyc.any Move.isTick = true := by
  decide +kernel

/-- **Property 4: without the hold (rule 4(b)) a wide task may wait forever.** An infinite run:
the wide task (`K = 2` of 3 tokens, within `drain_max`) waits at every step and never starts. Every
task ends, ticks keep coming, the gates are always open and outside load is within the reserve:
each freed token goes to a waiting one-token run, because the wide task needs two free at once
and the line skips it. -/
theorem wide_waits_forever : ∃ ρ : RunS wideCfg,
    (∀ k, ((ρ.st k).run 0).here = true ∧ ((ρ.st k).run 0).pend = 1 ∧ (ρ.st k).gate = true ∧
      (ρ.st k).outside ≤ (ρ.st k).reserve) ∧
    (∀ k b, b < wideCfg.nr → 0 < ((ρ.st k).run b).running → ∃ k' ≥ k, finOfM b (ρ.mv k')) ∧
    (∀ k, ∃ k' ≥ k, ρ.mv k' = .act .tick) ∧
    wideCfg.wd 0 = 2 ∧ wideCfg.wd 0 ≤ wideCfg.drainMax ∧ wideCfg.drainMax < wideCfg.pool := by
  obtain ⟨h1, h2, h3⟩ := wide_ok
  obtain ⟨t, ht⟩ := Option.isSome_iff_exists.1 h1
  have hs0 : wideS0 = t := by simp [wideS0, ht]
  have hr : ReachS wideCfg wideS0 := by rw [hs0]; exact runMoves_reach _ .init ht
  have hne : 0 < wideCyc.length := by decide
  obtain ⟨ρ, hmv, hk⟩ := cycle_run hr hne h2
  have get : ∀ k, ∃ R, Sh wideCfg R (cst wideCfg wideS0 wideCyc (k % wideCyc.length)) (ρ.st k) ∧
      wideP (cst wideCfg wideS0 wideCyc (k % wideCyc.length)) = true :=
    fun k => let ⟨hp, R, h⟩ := hk k; ⟨R, h, hp⟩
  refine ⟨ρ, fun k => ?_, fun k b hb hrun => ?_, fun k => ?_, by decide, by decide, by decide⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [wideP, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at hp
    have h0 : (0 : Nat) < wideCfg.nr := by decide
    exact ⟨by rw [(h.run 0 h0).here]; exact hp.1.1.1.1, by rw [(h.run 0 h0).pend]; exact hp.1.1.1.2,
      by rw [h.gate]; exact hp.1.1.2, by rw [h.outside, h.reserve]; exact hp.1.2⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [wideP, Bool.and_eq_true] at hp
    have := allLT_iff.1 hp.2 b hb
    rw [← h.running_ hb] at this
    simp only [Bool.or_eq_true, beq_iff_eq] at this
    rcases this with x | x
    · omega
    · obtain ⟨k', hk', hf⟩ := hits hne x k
      exact ⟨k', hk', by rw [hmv]; exact finB_sound hf⟩
  · obtain ⟨k', hk', hf⟩ := hits hne h3 k
    exact ⟨k', hk', by rw [hmv]; exact isTick_eq hf⟩

/-- With the hold (rule 4(a)) the same moves go otherwise: the first freed token is held for the
wide task, and at the second it starts. -/
def wideHoldCfg : Cfg := { wideCfg with rules := .wide043a }

theorem wide_hold_takes :
    ((runMoves wideHoldCfg init (widePre.take 7)).map fun s => ((s.run 0).pend, (s.run 4).pend, used wideHoldCfg s)) =
      some (1, 1, 2) ∧
    ((runMoves wideHoldCfg init (widePre.take 7 ++ [.act (.finC 2)])).map
      fun s => ((s.run 0).pend, (s.run 4).pend, used wideHoldCfg s)) = some (0, 1, 3) := by
  decide +kernel

/-! ## Axioms: only the standard three -/

/-- info: 'Cpuq.Contest.wide_within' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms wide_within

/-- info: 'Cpuq.Contest.wide_all_at_once' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms wide_all_at_once

/-- info: 'Cpuq.Contest.wide_hold_bound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms wide_hold_bound

/-- info: 'Cpuq.Contest.nohold_conserving' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms nohold_conserving

/-- info: 'Cpuq.Contest.wide_run_starts_fit' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms wide_run_starts_fit

/-- info: 'Cpuq.Contest.wide_run_starts' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms wide_run_starts

/-- info: 'Cpuq.Contest.wide_waits_forever' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms wide_waits_forever

/-- info: 'Cpuq.Contest.wide_hold_takes' depends on axioms: [propext] -/
#guard_msgs in #print axioms wide_hold_takes

end Cpuq.Contest
