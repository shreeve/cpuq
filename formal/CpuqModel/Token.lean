import CpuqModel.StreamCex

/-!
cpuq 0.42.0: a strict token pool (`Rules.tokens`, on in `Rules.tokens042`).

`N = pool − reserve` tokens (`capN`); `cpuq reserve k` (`Act.reserve`) changes the reserve at any
time, always leaving one token. Tokens are handed out up to `capTok`: `N` less what outside load
past the reserve keeps busy. A task holds one token while it runs; a started drain holds its
cores' tokens (`iso`); `used` is all of them. A task starts only on a free token
(`used + 1 ≤ capTok`) and only as the first in the one line (0.41's order, the share of `N`). A
drain takes its `k` tokens in one step on its turn (0.41's: the oldest waiting drain, passing no
older run that waits holding nothing), when `k` tokens are free and within `drain_max`.

Tokens are counted, not named: "no token has two holders" is that the holders never number more
than the tokens (any such count can be given distinct tokens). Which token a task gets (its CPU)
and whole-core placement of a drain's tokens are not modelled.
-/

namespace Cpuq.Contest

section
variable {cfg : Cfg}

theorem wd_pos (cfg : Cfg) (r : Nat) : 1 ≤ cfg.wd r := by unfold Cfg.wd; omega

theorem tokT_admit {s : St} {r : Nat} (hr : r < cfg.nr) : tokT cfg (admit s r) = tokT cfg s + cfg.wd r := by
  have h1 := sum_setRun (fun j x => x.running * cfg.wd j) s (admitR s.now (s.run r)) hr
  try dsimp only at h1
  have e1 : (admitR s.now (s.run r)).running * cfg.wd r = (s.run r).running * cfg.wd r + cfg.wd r := by
    show ((s.run r).start + 1 + (s.run r).comp + (s.run r).blk) * cfg.wd r = _
    rw [show (s.run r).start + 1 + (s.run r).comp + (s.run r).blk = (s.run r).running + 1 by
      simp only [RunSt.running]; omega, Nat.succ_mul]
  unfold tokT admit
  omega

/-- A start takes exactly its task's `K` tokens. -/
theorem used_admit {s : St} {r : Nat} (hr : r < cfg.nr) : used cfg (admit s r) = used cfg s + cfg.wd r := by
  unfold used; rw [tokT_admit hr]; have : iso cfg (admit s r) = iso cfg s := rfl; omega

theorem used_startD {s : St} {d : Nat} (hd : d < cfg.nd) (hw : (s.drain d).ph = .waiting) :
    used cfg (startD s d) = used cfg s + (cfg.drain d).size := by
  unfold used; rw [iso_startD hd hw]; have : tokT cfg (startD s d) = tokT cfg s := rfl; omega

theorem capTok_le (s : St) : capTok cfg s ≤ cfg.pool := by
  unfold capTok capN; omega

/-- With tokens, a start of the pass leaves at most `capTok` tokens held. -/
theorem pass1_tok (htk : cfg.rules.tokens = true) {s t : St} (h : pass1 cfg s = some t) :
    used cfg t ≤ capTok cfg t := by
  unfold pass1 at h
  split at h
  · rename_i d hd
    cases h
    have hc := List.find?_some hd
    have hm := List.mem_range.1 (List.mem_of_find?_eq_some hd)
    simp only [canDrain, htk, Bool.and_eq_true, decide_eq_true_eq, Bool.not_true, Bool.false_or] at hc
    rw [used_startD hm hc.1.1.1.1.1]
    exact hc.2
  · cases hf : (List.range cfg.nr).find? (canStart cfg s) with
    | none => rw [hf] at h; cases h
    | some r =>
      rw [hf] at h; cases h
      have hc := List.find?_some hf
      have hm := List.mem_range.1 (List.mem_of_find?_eq_some hf)
      simp only [canStart, htk, Bool.and_eq_true, ↓reduceIte, decide_eq_true_eq] at hc
      rw [used_admit hm]
      exact hc.1.2

theorem passN_tok (htk : cfg.rules.tokens = true) : ∀ (k : Nat) {s : St}, used cfg s ≤ capTok cfg s →
    used cfg (passN cfg k s) ≤ capTok cfg (passN cfg k s)
  | 0, _, h => h
  | k + 1, s, h => by
    simp only [passN]
    cases e : pass1 cfg s with
    | none => exact h
    | some t => exact passN_tok htk k (pass1_tok htk e)

/-- Before the pass, no move raises the tokens held. -/
theorem pre_used {s u : St} {m : Move} (h : pre cfg s m u) : used cfg u ≤ used cfg s := by
  have ht : tokT cfg u ≤ tokT cfg s := rsum_le (fun b _ => Nat.mul_le_mul_right _ (pre_running h b).1)
  have hi : iso cfg u ≤ iso cfg s := by
    apply iso_le
    intro e he
    cases m with
    | act a =>
      have hu : act cfg s a = some u := h
      rw [act_drain hu e] at he
      cases a with
      | arriveD d => dsimp only [drainAfter] at he; split at he
                     · simp at he
                     · exact he
      | dbusy d b => dsimp only [drainAfter] at he; split at he
                     · simpa using he
                     · exact he
      | dend d => dsimp only [drainAfter] at he; split at he
                  · simp at he
                  · exact he
      | tick =>
        dsimp only [drainAfter] at he
        rcases tickD_ph cfg (anyWait cfg s) e (s.drain e) with x | x
        · rw [← x]; exact he
        · rw [x] at he; cases he
      | _ => exact he
    | leave r => obtain ⟨_, rfl⟩ := h; exact he
    | leaveD d =>
      obtain ⟨_, rfl⟩ := h
      by_cases hed : e = d
      · subst hed; simp at he
      · simpa [hed] using he
  unfold used; omega

/-- A move other than `cpuq reserve` and outside load keeps `capTok`. -/
theorem pre_capTok {s u : St} {m : Move} (h : pre cfg s m u)
    (hr : ∀ k, m ≠ .act (.reserve k)) (hl : ∀ k, m ≠ .act (.load k)) : capTok cfg u = capTok cfg s := by
  cases m with
  | act a =>
    have hu : act cfg s a = some u := h
    cases a with
    | reserve k => exact absurd rfl (hr k)
    | load k => exact absurd rfl (hl k)
    | _ => simp only [act] at hu <;> (try split at hu) <;> (try cases hu) <;> rfl
  | leave r => obtain ⟨_, rfl⟩ := h; rfl
  | leaveD d => obtain ⟨_, rfl⟩ := h; rfl
end

/-! ## 1. Tokens held -/

/-- **Property 1a.** With tokens, in every reachable state at most `pool` tokens are held (tasks
running plus started drains' cores), whatever `cpuq reserve` and outside load did. -/
theorem tok_le_pool {cfg : Cfg} (htk : cfg.rules.tokens = true) {s : St} (r : ReachS cfg s) :
    used cfg s ≤ cfg.pool := by
  induction r with
  | init =>
    have : used cfg init = 0 := by
      unfold used
      have a1 : tokT cfg init = 0 := rsum_eq_zero.2 (fun r _ => by simp [Contest.init, RunSt.running])
      have a2 : iso cfg init = 0 := rsum_eq_zero.2 (fun d _ => by simp [Contest.init, isoF])
      omega
    omega
  | step m _ hs ih =>
    obtain ⟨u, hu, rfl⟩ := stepS_pre hs
    have h1 := pre_used hu
    unfold pass
    generalize work cfg u = k
    induction k generalizing u with
    | zero => simp only [passN]; omega
    | succ k ihk =>
      simp only [passN]
      cases e : pass1 cfg u with
      | none => simp only; omega
      | some t =>
        simp only
        have := passN_tok htk k (pass1_tok htk e)
        have := capTok_le (cfg := cfg) (passN cfg k t)
        omega

/-- **Property 1b.** With tokens, every start (task or drain) leaves at most `capTok ≤ N` tokens
held: the pass never takes more than `N` (less what outside load keeps busy). -/
theorem tok_start_within {cfg : Cfg} (htk : cfg.rules.tokens = true) {s t : St} (h : pass1 cfg s = some t) :
    used cfg t ≤ capTok cfg t ∧ capTok cfg t ≤ capN cfg t :=
  ⟨pass1_tok htk h, Nat.sub_le _ _⟩

/-- **Property 1c.** With tokens, a move other than `cpuq reserve` or a rise in outside load keeps
"at most `capTok` tokens held". -/
theorem tok_within {cfg : Cfg} (htk : cfg.rules.tokens = true) {s t : St} {m : Move} (h : stepS cfg s m = some t)
    (hr : ∀ k, m ≠ .act (.reserve k)) (hl : ∀ k, m ≠ .act (.load k)) (hs : used cfg s ≤ capTok cfg s) :
    used cfg t ≤ capTok cfg t := by
  obtain ⟨u, hu, rfl⟩ := stepS_pre h
  have h1 := pre_used hu
  have h2 := pre_capTok hu hr hl
  exact passN_tok htk _ (by omega)

/-- **Property 1d.** With tokens, while the tokens held are `capTok` or more (after `cpuq reserve`
raised the reserve, or outside load rose), no task starts and no drain that needs a token starts:
the running tasks finish, and fewer start until the count is under the new `N`. -/
theorem tok_over_no_start {cfg : Cfg} (htk : cfg.rules.tokens = true) {s : St} (hover : capTok cfg s ≤ used cfg s) :
    (∀ r, canStart cfg s r = false) ∧ (∀ d, 0 < (cfg.drain d).size → canDrain cfg s d = false) := by
  refine ⟨fun r => ?_, fun d hd => ?_⟩
  · cases hc : canStart cfg s r
    · rfl
    · simp only [canStart, htk, Bool.and_eq_true, ↓reduceIte, decide_eq_true_eq] at hc
      have := wd_pos cfg r; omega
  · cases hc : canDrain cfg s d
    · rfl
    · simp only [canDrain, htk, Bool.and_eq_true, decide_eq_true_eq, Bool.not_true, Bool.false_or] at hc; omega

/-! ## 2. Work-conserving over tokens -/

/-- **Property 2.** With tokens and every task of one token (0.42), in every reachable state, if a
run waits (not held by its `-c`) and the gates are open, no token is free to hand out:
`used + 1 > capTok`. A waiting drain holds no token and keeps none free. -/
theorem tok_work_conserving {cfg : Cfg} (htk : cfg.rules.tokens = true) (hw : ∀ x < cfg.nr, cfg.wd x = 1)
    {s : St} (h : ReachS cfg s) {r : Nat}
    (hr : r < cfg.nr) (he : eligible s r = true) (hg : s.gate = true) : capTok cfg s < used cfg s + 1 := by
  apply Classical.byContradiction; intro hn
  have hfree : used cfg s + 1 ≤ capTok cfg s := by omega
  have hce : cand cfg s r = true := by
    simp only [cand, fits, he, hw r hr, hfree, decide_true, Bool.or_true, Bool.and_self]
  obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head2_isSome hr hce)
  obtain ⟨hxn, hxe⟩ := head2_some hx
  have hc := reachS_start h hxn
  simp only [front, Bool.and_eq_true] at hxe
  have hxel := cand_elig hxe.1
  have hfx : used cfg s + cfg.wd x ≤ capTok cfg s := by rw [hw x hxn]; exact hfree
  simp [canStart, hxel, hxe.2, hg, hfx, hx, htk] at hc

/-! ## 3. No starvation of runs -/

/-- **Property 3.** On the 0.42 rules (`tokens`, `arrivalKey`, `oneLine`), with arrivals that never
stop, a waiting run starts a task if from then on no urgent run arrives, every task ends, one tick
passes, and again and again the gates are open while outside load is within the reserve and
`drain_max` < `N`. New runs of every project may keep arriving, and `cpuq reserve` may change. -/
theorem tok_run_starts {cfg : Cfg} (_htk : cfg.rules.tokens = true) (hak : cfg.rules.arrivalKey = true)
    (hol : cfg.rules.oneLine = true) (hhold : cfg.rules.hold = true) (hw : ∀ x < cfg.nr, cfg.wd x = 1)
    (ρ : RunS cfg) {n r : Nat} (hr : r < cfg.nr)
    (hh : ((ρ.st n).run r).here = true) (hp : 0 < ((ρ.st n).run r).pend)
    (noUrgent : ∀ m ≥ n, ∀ b, ρ.mv m = .act (.arrive b) → (cfg.run b).urgent = false)
    (ends : ∀ m b, b < cfg.nr → 0 < ((ρ.st m).run b).running → ∃ m' ≥ m, finOfM b (ρ.mv m'))
    (htime : ∃ m ≥ n, ρ.mv m = .act .tick)
    (gates : ∀ m, ∃ m' ≥ m, (ρ.st m').gate = true ∧ (ρ.st m').outside ≤ (ρ.st m').reserve ∧
      cfg.drainMax < cfg.pool - (ρ.st m').reserve) :
    ∃ m ≥ n, ((ρ.st m).run r).pend < ((ρ.st n).run r).pend := by
  have hD : cfg.drainMax < cfg.pool := by obtain ⟨m, _, _, _, h⟩ := gates 0; omega
  exact run_starts_fixed hak hol hD ρ hr hh hp noUrgent ends htime (.inr hhold)
    (fun m => let ⟨m', hm, hg, ho, hd⟩ := gates m; ⟨m', hm, hg, fun _ => ⟨ho, fun x hx => by rw [hw x hx]; omega⟩⟩)

/-! ## 4, 5. Drains -/

/-- **Property 4.** A drain holds tokens only when started: the tokens held are the tasks running
plus the started drains' cores, and a waiting drain counts none. -/
theorem tok_waiting_drain_holds_none {cfg : Cfg} (s : St) {d : Nat} (hw : (s.drain d).ph = .waiting) :
    isoF cfg d (s.drain d) = 0 ∧ used cfg s = tokT cfg s + rsum cfg.nd (fun e => isoF cfg e (s.drain e)) := by
  exact ⟨by simp [isoF, hw], rfl⟩

/-- **Property 5.** In every reachable state a started drain has held its tokens at most its limit
plus grace ticks, its limit at most the ceiling (any rules, `cpuq reserve` included). -/
theorem tok_hold {cfg : Cfg} {s : St} (h : ReachS cfg s) {d : Nat} (hs : (s.drain d).ph = .started) :
    (s.drain d).age ≤ cfg.limitOf d + cfg.grace ∧ cfg.limitOf d ≤ cfg.ceil :=
  ⟨((reachS_inv h).1.clock d hs).1, Nat.min_le_right _ _⟩

/-! ## 6. A drain may wait forever while runs keep every token busy -/

/-- 3 tokens, `drain_max` 2: slots 0 … 3 for one-task runs of one project; drain 0 needs 2. -/
def busyTokCfg : Cfg :=
  { pool := 3, drainMax := 2, rules := .tokens042,
    runs := [{ proj := 0 }, { proj := 0 }, { proj := 0 }, { proj := 0 }],
    drains := [{ size := 2, limit := 4 }] }

/-- Three runs take the three tokens; the drain arrives and waits (1 token is never enough); a
fourth run waits; then one round of the cycle, so every run present arrived after the drain. -/
def busyTokPre : List Move :=
  [.act (.arrive 0), .act (.arrive 1), .act (.arrive 2), .act .tick, .act (.arriveD 0), .act (.arrive 3),
   .act (.finC 0), .leave 0, .act (.arrive 0), .act .tick,
   .act (.finC 1), .leave 1, .act (.arrive 1), .act .tick,
   .act (.finC 2), .leave 2, .act (.arrive 2), .act .tick,
   .act (.finC 3), .leave 3, .act (.arrive 3), .act .tick]

/-- A task ends and frees one token; the drain needs two, so the waiting run takes it; the
finished run leaves and comes back to wait; a tick. -/
def busyTokCyc : List Move :=
  [.act (.finC 0), .leave 0, .act (.arrive 0), .act .tick,
   .act (.finC 1), .leave 1, .act (.arrive 1), .act .tick,
   .act (.finC 2), .leave 2, .act (.arrive 2), .act .tick,
   .act (.finC 3), .leave 3, .act (.arrive 3), .act .tick]

def busyTokS0 : St := (runMoves busyTokCfg init busyTokPre).getD init

def busyTokP (s : St) : Bool :=
  decide ((s.drain 0).ph = .waiting) && s.gate && decide (s.outside ≤ s.reserve) &&
    decide (used busyTokCfg s = capN busyTokCfg s) &&
    allLT busyTokCfg.nr (fun b => (s.run b).running == 0 || busyTokCyc.any (finB b))

theorem busyTok_ok : (runMoves busyTokCfg init busyTokPre).isSome = true ∧
    cycOk busyTokCfg ⟨4, 4, 0, 4⟩ busyTokP busyTokS0 busyTokCyc = true ∧ busyTokCyc.any Move.isTick = true := by
  decide +kernel

theorem Sh.ph0 {cfg : Cfg} {R : Ren} {s t : St} (h : Sh cfg R s t) {d : Nat} (hd : d < cfg.nd) :
    (t.drain d).ph = (s.drain d).ph := (h.drain d hd).ph

/-- **Property 6: a drain may wait without bound.** An infinite run of the 0.42 rules: the drain
(2 of 3 tokens, within `drain_max`) waits at every step and never starts. Every task ends, ticks
keep coming, the gates are always open, outside load is within the reserve, and runs hold every
token at every step: each freed token goes to a waiting run, because the drain needs two free at
once. Nothing in the rules bounds the wait; in practice `--max` does (the drain gives up with
exit 75), and status and history say why it waits. -/
theorem drain_waits_forever : ∃ ρ : RunS busyTokCfg,
    (∀ k, ((ρ.st k).drain 0).ph = .waiting ∧ (ρ.st k).gate = true ∧ (ρ.st k).outside ≤ (ρ.st k).reserve ∧
      used busyTokCfg (ρ.st k) = capN busyTokCfg (ρ.st k)) ∧
    (∀ k b, b < busyTokCfg.nr → 0 < ((ρ.st k).run b).running → ∃ k' ≥ k, finOfM b (ρ.mv k')) ∧
    (∀ k, ∃ k' ≥ k, ρ.mv k' = .act .tick) ∧
    busyTokCfg.drainMax < busyTokCfg.pool ∧ (busyTokCfg.drain 0).size ≤ busyTokCfg.drainMax := by
  obtain ⟨h1, h2, h3⟩ := busyTok_ok
  obtain ⟨t, ht⟩ := Option.isSome_iff_exists.1 h1
  have hs0 : busyTokS0 = t := by simp [busyTokS0, ht]
  have hr : ReachS busyTokCfg busyTokS0 := by rw [hs0]; exact runMoves_reach _ .init ht
  have hne : 0 < busyTokCyc.length := by decide
  obtain ⟨ρ, hmv, hk⟩ := cycle_run hr hne h2
  have get : ∀ k, ∃ R, Sh busyTokCfg R (cst busyTokCfg busyTokS0 busyTokCyc (k % busyTokCyc.length)) (ρ.st k) ∧
      busyTokP (cst busyTokCfg busyTokS0 busyTokCyc (k % busyTokCyc.length)) = true :=
    fun k => let ⟨hp, R, h⟩ := hk k; ⟨R, h, hp⟩
  refine ⟨ρ, fun k => ?_, fun k b hb hrun => ?_, fun k => ?_, by decide, by decide⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [busyTokP, Bool.and_eq_true, decide_eq_true_eq] at hp
    exact ⟨by rw [h.ph0 (by decide)]; exact hp.1.1.1.1, by rw [h.gate]; exact hp.1.1.1.2,
      by rw [h.outside, h.reserve]; exact hp.1.1.2, by rw [h.used_, h.capN_]; exact hp.1.2⟩
  · obtain ⟨R, h, hp⟩ := get k
    simp only [busyTokP, Bool.and_eq_true] at hp
    have := allLT_iff.1 hp.2 b hb
    rw [← h.running_ hb] at this
    simp only [Bool.or_eq_true, beq_iff_eq] at this
    rcases this with x | x
    · omega
    · obtain ⟨k', hk', hf⟩ := hits hne x k
      exact ⟨k', hk', by rw [hmv]; exact finB_sound hf⟩
  · obtain ⟨k', hk', hf⟩ := hits hne h3 k
    exact ⟨k', hk', by rw [hmv]; exact isTick_eq hf⟩

/-! ## 7. Changing the reserve -/

/-- 3 CPUs, one project: three one-task runs and a fourth waiting; `cpuq reserve 2` while three
run. -/
def reserveCfg : Cfg :=
  { pool := 3, drainMax := 1, rules := .tokens042,
    runs := [{ proj := 0 }, { proj := 0 }, { proj := 0 }, { proj := 0 }] }

def reserveMoves : List Move :=
  [.act (.arrive 0), .act (.arrive 1), .act (.arrive 2), .act (.arrive 3), .act (.reserve 2)]

/-- **Property 7, what changing `N` keeps.** `cpuq reserve` takes effect at once and preempts
nothing, so right after raising the reserve more tasks hold tokens than `N` (3 run, `N` = 1) and the
waiting run does not start; after two tasks end, still none starts (2 held, 1 token); after the
third, one does. So 1 holds as `tok_le_pool`, `tok_start_within`, `tok_within` (except across a
reserve raise) and `tok_over_no_start`; 2–5 hold in every reachable state with any reserve
changes (`tok_work_conserving`, `tok_waiting_drain_holds_none`, `tok_hold`), and 3 with the reserve
leaving `drain_max` < `N` at the open-gate times (`tok_run_starts`). -/
theorem reserve_shrinks :
    ((runMoves reserveCfg init reserveMoves).map fun s => (used reserveCfg s, capN reserveCfg s, (s.run 3).pend)) =
      some (3, 1, 1) ∧
    ((runMoves reserveCfg init (reserveMoves ++ [.act (.finS 0), .act (.finS 1)])).map
      fun s => (used reserveCfg s, (s.run 3).pend)) = some (1, 1) ∧
    ((runMoves reserveCfg init (reserveMoves ++ [.act (.finS 0), .act (.finS 1), .act (.finS 2)])).map
      fun s => (used reserveCfg s, (s.run 3).pend)) = some (1, 0) := by
  decide +kernel

/-! ## Axioms: only the standard three -/

/-- info: 'Cpuq.Contest.tok_le_pool' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms tok_le_pool

/-- info: 'Cpuq.Contest.tok_work_conserving' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms tok_work_conserving

/-- info: 'Cpuq.Contest.tok_run_starts' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms tok_run_starts

/-- info: 'Cpuq.Contest.drain_waits_forever' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms drain_waits_forever

end Cpuq.Contest
