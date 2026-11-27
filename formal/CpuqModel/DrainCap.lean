/-
A drain's time limit (`Rules.drainCap`), a stream of drains (`OpCfg.again`), and FIFO between
drains and waiters holding nothing (`Rules.drainFifo`), on `moveX`.

- `released_holds_forever`: under the 0.32.0 rules (`code0320`), a drain whose command runs holds
  every CPU while a waiter waits, and no rule moves it: of every action, only the command's own
  end is enabled. A run that stays there forever is weakly fair for every other step class, so
  only A-term (the assumption that every task ends) ends the hold. Nothing bounds it.
- `hold_bound`: with the limit, through any stretch of a run in which a drain is alive, holds a
  CPU and has started its command, at most `drainLimit + grace` ticks pass. Its start sets its
  clock to that (`moveX_start`), no step raises it (`ReachX.clk_le`), and while it holds CPUs time
  passes only with clock left (`clk_pos`). Once its command has ended, no time passes before it
  has given every CPU back (`ended_no_tick`). The idle stop is an earlier TERM: it only lowers
  the clock (`moveX_clk`).
- `fifo_no_pass`: with FIFO, a free CPU goes to a drain only if every waiter that holds nothing
  and is no drain queued after the oldest gathering drain. `released_fifo_no_pass` and
  `released_hold_bound`: both for the released rules (0.34.0).
-/
import CpuqModel.Backfill

namespace Cpuq

attribute [-simp] List.getD_eq_getElem?_getD

/-! ### What leaves the clock alone -/

theorem grantOne_clock (cfg : Cfg) (s : St) (c : Nat) : (grantOne cfg s c).clock = s.clock := by
  unfold grantOne; split
  · split <;> rfl
  · rfl

theorem handoutOver_clock (cfg : Cfg) (s : St) (cs : List Nat) :
    (handoutOver cfg s cs).clock = s.clock := by
  induction cs generalizing s with
  | nil => rfl
  | cons c cs ih => simp only [handoutOver]; rw [ih, grantOne_clock]

theorem handout_clock (cfg : Cfg) (s : St) : (handout cfg s).clock = s.clock :=
  handoutOver_clock cfg s _

theorem takeTok_clock (cfg : Cfg) (s : St) (o c : Nat) : (takeTok cfg s o c).clock = s.clock := by
  unfold takeTok; split <;> rfl

theorem tryOnce_clock (cfg : Cfg) (s : St) (o : Nat) : (tryOnce cfg s o).clock = s.clock := by
  unfold tryOnce; split
  · split
    · exact takeTok_clock ..
    · rfl
  · rfl

theorem reap_clock (cfg : Cfg) (s : St) (o i : Nat) (ok : Bool) :
    (reap cfg s o i ok).clock = s.clock := by
  unfold reap; rw [tryOnce_clock]; rfl

theorem step_clock {cfg : Cfg} {s t : St} {a : Act} (e : step cfg s a = some t) :
    t.clock = s.clock := by
  cases a <;> simp only [Cpuq.step] at e <;> (repeat' split at e) <;>
    (first | cases e | skip) <;>
    first
    | rfl
    | exact reap_clock ..
    | exact handout_clock ..
    | exact takeTok_clock ..
    | (rw [handout_clock]; rfl)
    | simp at e

/-- `move` never touches a clock: only `moveX` does. -/
theorem move_clock {cfg : Cfg} {s t : St} {a : Act} (e : move cfg s a = some t) :
    t.clock = s.clock := by
  have viaMap : ∀ (b : Act) (f : St → St), (∀ u, (f u).clock = u.clock) →
      (step cfg s b).map f = some t → t.clock = s.clock := by
    intro b f hf e
    obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
    rw [hf, step_clock hu]
  unfold move at e
  split at e
  · cases e
  · cases a
    all_goals (dsimp only at e; repeat' split at e)
    all_goals first
      | (cases e; done)
      | exact step_clock e
      | exact viaMap _ _ (fun u => by first | rfl | (unfold retake; split <;> rfl)) e
      | (cases e; rfl)

/-! ### Clock arithmetic -/

theorem getD_normClock (l : List Nat) (p : Nat) : (normClock l).getD p 0 = l.getD p 0 := by
  unfold normClock; split
  · rename_i h
    rw [List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD]
    cases e : l[p]? with
    | none => simp
    | some x =>
      have := List.all_eq_true.1 h x (List.mem_of_getElem? e)
      simp at this; simp [this]
  · rfl

theorem clk_setClk (s : St) (o n p : Nat) :
    (s.setClk o n).clk p = if p = o then n else s.clk p := by
  simp only [St.clk, St.setClk, getD_normClock]
  rw [List.getD_eq_getElem?_getD, List.getElem?_map]
  by_cases hp : p < max s.clock.length (o + 1)
  · rw [List.getElem?_range hp]; simp
  · rw [List.getElem?_eq_none (by simpa using hp)]
    have h1 : ¬ p = o := by omega
    have h2 : s.clock.length ≤ p := by omega
    simp [h1, List.getD_eq_getElem?_getD, List.getElem?_eq_none h2]

theorem foldl_clock {α} (f : St → α → St) (hf : ∀ u x, (f u x).clock = u.clock) (l : List α)
    (s : St) : (l.foldl f s).clock = s.clock := by
  induction l generalizing s with
  | nil => rfl
  | cons x l ih => simp only [List.foldl_cons]; rw [ih, hf]

theorem getD_step_clock (cfg : Cfg) (u : St) (a : Act) : ((step cfg u a).getD u).clock = u.clock := by
  cases e : step cfg u a with
  | none => rfl
  | some v => exact step_clock e

theorem termAll_clock (cfg : Cfg) (s : St) (o : Nat) : (termAll cfg s o).clock = s.clock :=
  foldl_clock _ (fun u _ => getD_step_clock _ u _) _ _

theorem killAll_clock (cfg : Cfg) (s : St) (o : Nat) : (killAll cfg s o).clock = s.clock :=
  foldl_clock _ (fun u _ => getD_step_clock _ u _) _ _

/-- A tick counts every clock down by one. -/
theorem tickX_clk (cfg : Cfg) (s : St) (p : Nat) : (tickX cfg s).clk p = s.clk p - 1 := by
  unfold tickX
  rw [St.clk, foldl_clock]
  · rw [getD_normClock, St.clk, List.getD_eq_getElem?_getD, List.getD_eq_getElem?_getD,
      List.getElem?_map]
    cases s.clock[p]? <;> rfl
  · intro u o
    dsimp only
    split
    · split
      · rw [killAll_clock]; split
        · exact termAll_clock ..
        · rfl
      · split
        · exact termAll_clock ..
        · rfl
    · rfl

theorem place_clock (cfg : Cfg) (o c : Nat) (s : St) : (place cfg o c s).clock = s.clock := by
  unfold place; split
  · rfl
  · split <;> rfl

theorem respawn_clk (cfg : Cfg) (o : Nat) (s : St) (p : Nat) :
    (respawn cfg o s).clk p = if p = o then 0 else s.clk p :=
  clk_setClk s o 0 p

/-- Only a drain's start raises its clock, to its limit and the grace; every other step keeps a
clock or lowers it (a tick by one, an idle stop's TERM to the grace). -/
theorem moveX_clk {cfg : Cfg} {s t : St} {a : Act} (e : moveX cfg s a = some t) (p : Nat) :
    t.clk p ≤ s.clk p ∨ ∃ c, a = .refill p c ∧ t.clk p = drainLimit cfg p + cfg.grace := by
  have ofMove : ∀ {b : Act} {u : St}, move cfg s b = some u → u.clk p = s.clk p := by
    intro b u e; simp only [St.clk, move_clock e]
  unfold moveX at e
  split at e
  · exact .inl (Nat.le_of_eq (ofMove e))
  · cases a with
    | tick =>
      dsimp only at e
      split at e
      · split at e
        · cases e; rw [tickX_clk]; exact .inl (Nat.sub_le _ _)
        · cases e
      · exact .inl (Nat.le_of_eq (ofMove e))
    | refill o c =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      have hu' : (if cfg.rules.drainTurn then { u with ran := setBit u.ran o } else u).clk p =
          s.clk p := by
        have := ofMove hu
        split
        · exact this
        · exact this
      split
      · rw [clk_setClk]; split
        · rename_i hpo; subst hpo; exact .inr ⟨c, rfl, rfl⟩
        · exact .inl (Nat.le_of_eq hu')
      · exact .inl (Nat.le_of_eq hu')
    | timeout o i =>
      dsimp only at e
      split at e
      · obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
        rw [clk_setClk]; split
        · rename_i hpo; subst hpo; exact .inl (Nat.min_le_left _ _)
        · exact .inl (Nat.le_of_eq (by simp only [St.clk, step_clock hu]))
      · exact .inl (Nat.le_of_eq (ofMove e))
    | accept o c =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      split
      · exact .inl (Nat.le_of_eq (by simp only [St.clk, place_clock, move_clock hu]))
      · exact .inl (Nat.le_of_eq (ofMove hu))
    | finish o =>
      dsimp only at e
      obtain ⟨u, hu, rfl⟩ := Option.map_eq_some_iff.1 e
      split
      · rw [respawn_clk]; split
        · exact .inl (Nat.zero_le _)
        · exact .inl (Nat.le_of_eq (ofMove hu))
      · exact .inl (Nat.le_of_eq (ofMove hu))
    | _ => exact .inl (Nat.le_of_eq (ofMove e))

/-- A drain's command starts with its limit and the grace on its clock. -/
theorem moveX_start {cfg : Cfg} {s t : St} {d c : Nat} (hc : cfg.rules.drainCap = true)
    (hd : drainOp cfg d = true) (hb : s.busy d = false) (e : moveX cfg s (.refill d c) = some t) :
    t.clk d = drainLimit cfg d + cfg.grace := by
  have hx : extended cfg = true := by simp [extended, hc]
  simp only [moveX, hx, Bool.not_true, Bool.false_eq_true, ite_false] at e
  obtain ⟨u, -, rfl⟩ := Option.map_eq_some_iff.1 e
  simp [hc, hd, hb, clk_setClk]

/-- A tick with the limit on: allowed only when nothing is due. -/
theorem moveX_tick {cfg : Cfg} {s t : St} (hc : cfg.rules.drainCap = true)
    (e : moveX cfg s .tick = some t) : due cfg s = false ∧ t = tickX cfg s := by
  have hx : extended cfg = true := by simp [extended, hc]
  simp only [moveX, hx, hc, Bool.not_true, Bool.false_eq_true, ite_false, ite_true] at e
  split at e
  · rename_i h; cases e
    simp only [Bool.and_eq_true, Bool.not_eq_true'] at h; exact ⟨h.2, rfl⟩
  · cases e

theorem firstPending_pos {s : St} {o i : Nat} (e : firstPending s o = some i) : 0 < s.pendingN o := by
  have hp := firstPending_spec e
  have hi : i < (s.op o).tasks.length := St.lt_of_task s o i (by rw [hp]; simp)
  exact List.countP_pos_iff.2 ⟨_, St.task_mem s o i hi, by simp [pendingT, hp]⟩

/-- A refill needs a task waiting to start. -/
theorem moveX_refill_pending {cfg : Cfg} {s t : St} {o c : Nat}
    (e : moveX cfg s (.refill o c) = some t) : 0 < s.pendingN o := by
  have hm : ∃ u, move cfg s (.refill o c) = some u := by
    unfold moveX at e; split at e
    · exact ⟨t, e⟩
    · obtain ⟨u, hu, -⟩ := Option.map_eq_some_iff.1 e; exact ⟨u, hu⟩
  obtain ⟨u, hu⟩ := hm
  have hs : step cfg s (.refill o c) = some u := by simpa [move, needsLock] using hu
  simp only [Cpuq.step] at hs
  split at hs
  · split at hs
    · rename_i i hi; exact firstPending_pos hi
    · cases hs
  · cases hs

/-! ### The bound -/

/-- `d` is an alive drain holding a CPU whose command has started (no task of it waits). -/
def InSeg (cfg : Cfg) (d : Nat) (s : St) : Prop :=
  drainOp cfg d = true ∧ s.isAlive d = true ∧ 0 < s.owned d ∧ s.pendingN d = 0

theorem drainOp_lt {cfg : Cfg} {d : Nat} (h : drainOp cfg d = true) : d < cfg.ops.length := by
  refine Classical.byContradiction fun hn => ?_
  simp [drainOp, Cfg.op, List.getD_eq_getElem?_getD, List.getElem?_eq_none (Nat.le_of_not_lt hn)] at h

/-- While `d` holds CPUs with its command started, time passes only with clock left. -/
theorem clk_pos {cfg : Cfg} {d : Nat} {s : St} (hs : InSeg cfg d s) (hd : due cfg s = false) :
    0 < s.clk d := by
  obtain ⟨h1, h2, h3, h4⟩ := hs
  have := List.any_eq_false.1 hd d (List.mem_range.2 (drainOp_lt h1))
  simp only [h1, h2, h3, h4, Bool.true_and, decide_true, beq_self_eq_true, Bool.or_eq_true,
    beq_iff_eq] at this
  omega

/-- Once its command has ended, no time passes before the drain has given every CPU back. -/
theorem ended_no_tick {cfg : Cfg} {d : Nat} {s : St} (hc : cfg.rules.drainCap = true)
    (hs : InSeg cfg d s) (he : ended s d = true) : moveX cfg s .tick = none := by
  cases e : moveX cfg s .tick with
  | none => rfl
  | some t =>
    have hd := (moveX_tick hc e).1
    obtain ⟨h1, h2, h3, h4⟩ := hs
    have := List.any_eq_false.1 hd d (List.mem_range.2 (drainOp_lt h1))
    simp [h1, h2, h3, h4, he] at this

/-- The states `moveX` reaches. -/
inductive ReachX (cfg : Cfg) : St → Prop where
  | init : ReachX cfg (Cpuq.init cfg)
  | step {s s' : St} (a : Act) : ReachX cfg s → moveX cfg s a = some s' → ReachX cfg s'

/-- No clock is ever above its drain's limit and the grace. -/
theorem ReachX.clk_le {cfg : Cfg} {s : St} (r : ReachX cfg s) (p : Nat) :
    s.clk p ≤ drainLimit cfg p + cfg.grace := by
  induction r with
  | init => simp [St.clk, Cpuq.init]
  | step a _ e ih => rcases moveX_clk e p with h | ⟨_, _, h⟩ <;> omega

/-- A run of `moveX`. -/
structure RunX (cfg : Cfg) where
  st : Nat → St
  act : Nat → Option Act
  start : ReachX cfg (st 0)
  moves : ∀ n a, act n = some a → moveX cfg (st n) a = some (st (n + 1))
  stays : ∀ n, act n = none → st (n + 1) = st n

theorem RunX.reach {cfg : Cfg} (r : RunX cfg) (n : Nat) : ReachX cfg (r.st n) := by
  induction n with
  | zero => exact r.start
  | succ n ih =>
    cases h : r.act n with
    | none => rw [r.stays n h]; exact ih
    | some a => exact .step a ih (r.moves n a h)

/-- The ticks among the `k` steps from time `n`. -/
def RunX.ticks {cfg : Cfg} (r : RunX cfg) (n : Nat) : Nat → Nat
  | 0 => 0
  | k + 1 => r.ticks n k + (if r.act (n + k) = some .tick then 1 else 0)

theorem hold_clock {cfg : Cfg} {d : Nat} (hc : cfg.rules.drainCap = true) (r : RunX cfg) (n : Nat) :
    ∀ k, (∀ j, j ≤ k → InSeg cfg d (r.st (n + j))) →
      r.ticks n k + (r.st (n + k)).clk d ≤ (r.st n).clk d := by
  intro k
  induction k with
  | zero => intro _; simp [RunX.ticks]
  | succ k ih =>
    intro hs
    have ih := ih (fun j hj => hs j (by omega))
    have sk := hs k (by omega)
    simp only [RunX.ticks]
    rw [show n + (k + 1) = (n + k) + 1 by omega]
    cases ha : r.act (n + k) with
    | none => rw [r.stays _ ha]; simp only [reduceCtorEq, ite_false]; omega
    | some a =>
      have e := r.moves _ a ha
      by_cases hat : a = .tick
      · subst hat
        obtain ⟨hd, ht⟩ := moveX_tick hc e
        have := clk_pos sk hd
        rw [ht, tickX_clk]; simp only [ite_true]; omega
      · have ne : (if some a = some Act.tick then 1 else 0) = 0 := by simp [hat]
        rw [ne]
        rcases moveX_clk e d with le | ⟨c, rfl, -⟩
        · omega
        · have := moveX_refill_pending e; have := sk.2.2.2; omega

/-- With the drain's time limit: through any stretch of a run in which `d` is alive, holds a CPU
and has started its command, at most its limit and the grace pass, in ticks. The stretch ends
when it gives its last CPU back (or stops for a Ctrl-Z, which gives every CPU back, or dies). -/
theorem hold_bound {cfg : Cfg} {d : Nat} (hc : cfg.rules.drainCap = true) (r : RunX cfg) (n k : Nat)
    (hs : ∀ j, j ≤ k → InSeg cfg d (r.st (n + j))) : r.ticks n k ≤ drainLimit cfg d + cfg.grace := by
  have := hold_clock hc r n k hs
  have := (r.reach n).clk_le d
  omega

/-- The limit is at most its ceiling (`--all`: `drainCeilAll`, else `drainCeil`); never off. -/
theorem drainLimit_le (cfg : Cfg) (o : Nat) : drainLimit cfg o ≤ drainCeilOf cfg o :=
  Nat.min_le_right _ _

/-! ### Under the released rules, nothing bounds a drain's run -/

/-- 1 CPU: a `cpuq drain` (operation 0) and a one-task run (operation 1). -/
def holdCfg (r : Rules) : Cfg :=
  { cpus := 1, rules := r
    ops := [{ proj := 1, tasks := 1, urgent := true, drain := true, cap := 1 }, { proj := 0, tasks := 1 }] }

def runActs (cfg : Cfg) : St → List Act → Option St
  | s, [] => some s
  | s, a :: as => (move cfg s a).bind (runActs cfg · as)

theorem runActs_reach {cfg : Cfg} : ∀ {s t : St} (as : List Act), Reach cfg s →
    runActs cfg s as = some t → Reach cfg t
  | _, _, [], r, e => by simp only [runActs, Option.some.injEq] at e; subst e; exact r
  | s, _, a :: as, r, e => by
    simp only [runActs] at e
    cases hm : move cfg s a with
    | none => rw [hm] at e; cases e
    | some u => rw [hm] at e; exact runActs_reach as (.step a r hm) e

/-- The drain registers, takes the CPU and starts its command; then the run arrives. -/
def holdTrace : List Act := [.enter 0, .mark 0, .accept 0 0, .refill 0 0, .arrive 1]

def holdSt (r : Rules) : St := (runActs (holdCfg r) (init (holdCfg r)) holdTrace).getD default

/-- The drain holds the only CPU with its command running while a waiter waits, and of every
action only the command's own end is enabled: the run that stays there forever is weakly fair
for every other step class. -/
def HoldsForever (r : Rules) : Prop := ∃ run : Run (holdCfg r),
    (∀ n, (run.st n).owned 0 = (holdCfg r).cpus ∧ ((run.st n).task 0 0).st = .running 0 ∧
      starving (holdCfg r) (run.st n) 1 = true) ∧
    (∀ a ∈ actions (holdCfg r), a ≠ .exit 0 0 true →
      ∀ n, ¬ ∀ m, n ≤ m → Enabled (holdCfg r) (run.st m) a)

theorem holdsForever_of {r : Rules}
    (heq : runActs (holdCfg r) (init (holdCfg r)) holdTrace = some (holdSt r))
    (hfacts : (holdSt r).owned 0 = (holdCfg r).cpus ∧ ((holdSt r).task 0 0).st = .running 0 ∧
      starving (holdCfg r) (holdSt r) 1 = true)
    (hx : extended (holdCfg r) = false)
    (hnext : (next (holdCfg r) (holdSt r)).map (·.1) = [.exit 0 0 true]) : HoldsForever r := by
  have reach : Reach (holdCfg r) (holdSt r) := runActs_reach holdTrace .init heq
  refine ⟨{ st := fun _ => holdSt r, act := fun _ => none, start := reach,
            moves := fun _ _ h => (by cases h), stays := fun _ _ => rfl }, ?_, ?_⟩
  · intro _; exact hfacts
  · intro a ha hne n hen
    have en := hen n (Nat.le_refl _)
    have : a ∈ (next (holdCfg r) (holdSt r)).map (·.1) := by
      simp only [next, List.mem_map, List.mem_filterMap, moveX_plain hx]
      obtain ⟨t, ht⟩ := Option.isSome_iff_exists.1 en
      exact ⟨(a, t), ⟨a, ha, by rw [ht]; rfl⟩, rfl⟩
    rw [hnext] at this
    exact hne (List.mem_singleton.1 this)

/-- Under the 0.32.0 rules (`code0320`) nothing bounds a drain's run: only A-term ends it. -/
theorem released_holds_forever : HoldsForever .code0320 :=
  holdsForever_of (by decide) (by decide) (by decide) (by decide)

/-- The same under the 0.30.5 and 0.31 rules (`code0305`). -/
theorem code0305_holds_forever : HoldsForever .code0305 :=
  holdsForever_of (by decide) (by decide) (by decide) (by decide)

/-! ### FIFO: no drain passes an older waiter that holds nothing -/

theorem foldl_pick_spec (p : Nat → Bool) (better : Nat → Nat → Prop) [DecidableRel better] (l : List Nat)
    (init : Option Nat) (h : Nat)
    (e : l.foldl (fun best o => if p o then
        match best with
        | none => some o
        | some b => if better o b then some o else best
      else best) init = some h) : init = some h ∨ (h ∈ l ∧ p h = true) := by
  induction l generalizing init with
  | nil => exact .inl e
  | cons o l ih =>
    simp only [List.foldl_cons] at e
    rcases ih _ e with x | x
    · split at x
      · rename_i hp
        cases init with
        | none => simp at x; subst x; exact .inr ⟨List.mem_cons_self .., hp⟩
        | some b =>
          simp only at x; split at x
          · simp at x; subst x; exact .inr ⟨List.mem_cons_self .., hp⟩
          · exact .inl x
      · exact .inl x
    · exact .inr ⟨List.mem_cons_of_mem _ x.1, x.2⟩

theorem foldl_pick_none (p : Nat → Bool) (better : Nat → Nat → Prop) [DecidableRel better] (l : List Nat)
    (init : Option Nat)
    (e : l.foldl (fun best o => if p o then
        match best with
        | none => some o
        | some b => if better o b then some o else best
      else best) init = none) : init = none ∧ ∀ x ∈ l, p x = false := by
  induction l generalizing init with
  | nil => exact ⟨e, by simp⟩
  | cons o l ih =>
    simp only [List.foldl_cons] at e
    obtain ⟨h1, h2⟩ := ih _ e
    refine ⟨?_, ?_⟩
    · split at h1
      · cases init with
        | none => simp at h1
        | some b => simp only at h1; split at h1 <;> simp at h1
      · exact h1
    · intro x hx
      rcases List.mem_cons.1 hx with rfl | hx
      · cases hp : p x
        · rfl
        · simp only [hp, ↓reduceIte] at h1
          cases init with
          | none => simp at h1
          | some b => simp only at h1; split at h1 <;> simp at h1
      · exact h2 x hx

/-- With `drainLets`, no drainer means no drain in the tickets wants a CPU. -/
theorem drainer_none_lets {cfg : Cfg} {s : St} (hl : cfg.rules.drainLets = true)
    (e : drainer cfg s = none) (o : Nat) (ho : o ∈ s.order) (hd : drainOp cfg o = true) :
    demand cfg s o = 0 := by
  unfold drainer at e
  simp only [hl, ↓reduceIte] at e
  refine Classical.byContradiction fun hz => ?_
  have hp : (drainOp cfg o && decide (demand cfg s o > 0)) = true := by simp [hd]; omega
  split at e
  · exact absurd hp (by rw [(foldl_pick_none (fun o => drainOp cfg o && decide (demand cfg s o > 0))
      (fun o b => s.owned o + s.grants o > s.owned b + s.grants b) s.order none e).2 o ho]; simp)
  · have := List.find?_eq_none.1 e o ho; rw [hp] at this; simp at this

/-- With FIFO, a free CPU goes to a drain `g` only if every waiter that holds nothing and is no
drain has a ticket no older than the oldest gathering drain's (`turnIdx`): no drain passes such a
waiter that queued before it. -/
theorem fifo_no_pass {cfg : Cfg} {s : St} {g w : Nat} (hf : cfg.rules.drainFifo = true)
    (hl : cfg.rules.drainLets = true) (e : target cfg s = some g) (hg : drainOp cfg g = true)
    (hw : w ∈ s.order) (hww : waiter cfg s w = true) (hwd : drainOp cfg w = false)
    (h0 : s.owned w + s.grants w = 0) :
    turnIdx cfg s ≤ s.order.findIdx (· == w) := by
  unfold target at e
  split at e
  · rename_i d hdr
    split at e
    · split at e
      · rename_i x hx
        cases e
        have := foldl_pick_spec _ (fun o b => before cfg s o b = true) s.order none g hx
        simp only [reduceCtorEq, false_or] at this
        simp [hg] at this
      · rename_i hx
        split at e
        · rename_i f hth
          cases e
          have := (turnHead_waiter hth).2
          simp [beforeT, starting, hg] at this
        split at e
        · rename_i f hfh
          cases e
          have := (fitHead_waiter hfh).2
          simp [fits, hg] at this
        · cases e
          refine Nat.le_of_not_lt fun lt => ?_
          have := (foldl_pick_none _ (fun o b => before cfg s o b = true) s.order none hx).2 w hw
          simp [hf, hww, hwd, h0, lt] at this
    · cases e
  · rename_i hdr
    rcases foldl_pick_spec _ (fun o b => before cfg s o b = true) s.order none g e with x | ⟨hm, hp⟩
    · cases x
    · have := drainer_none_lets hl hdr g hm hg
      simp only [waiter, Bool.and_eq_true, decide_eq_true_eq] at hp
      omega

/-! ### The released rules (0.34.0) -/

/-- `hold_bound` for the released rules: a drain holds CPUs with its command started for at most
its limit (2h at most for `-c N`, 20m for `--all`) and the grace. -/
theorem released_hold_bound {cfg : Cfg} {d : Nat} (hr : cfg.rules = Rules.released) (r : RunX cfg)
    (n k : Nat) (hs : ∀ j, j ≤ k → InSeg cfg d (r.st (n + j))) :
    r.ticks n k ≤ drainLimit cfg d + cfg.grace ∧ drainLimit cfg d ≤ drainCeilOf cfg d :=
  ⟨hold_bound (by rw [hr]; rfl) r n k hs, drainLimit_le cfg d⟩

/-- `fifo_no_pass` for the released rules. -/
theorem released_fifo_no_pass {cfg : Cfg} {s : St} {g w : Nat} (hr : cfg.rules = Rules.released)
    (e : target cfg s = some g) (hg : drainOp cfg g = true)
    (hw : w ∈ s.order) (hww : waiter cfg s w = true) (hwd : drainOp cfg w = false)
    (h0 : s.owned w + s.grants w = 0) : turnIdx cfg s ≤ s.order.findIdx (· == w) :=
  fifo_no_pass (by rw [hr]; rfl) (by rw [hr]; rfl) e hg hw hww hwd h0

/-! ### A stream of drains starves a waiter (0.30.5 to 0.33.0) -/

/-- 1 CPU: a one-task run (operation 0) and two drains that come back after each finish. -/
def streamCfg (r : Rules) : Cfg :=
  { cpus := 1, rules := r
    ops := [{ proj := 0, tasks := 1 },
            { proj := 1, tasks := 1, urgent := true, drain := true, cap := 1, again := true },
            { proj := 2, tasks := 1, urgent := true, drain := true, cap := 1, again := true }] }

/-- The states before each action of `as` from `s`, and the state after the last; none if an
action is not enabled. -/
def walkX (cfg : Cfg) : St → List Act → Option (List St × St)
  | s, [] => some ([], s)
  | s, a :: as => (moveX cfg s a).bind fun t => (walkX cfg t as).map fun (l, e) => (s :: l, e)

theorem walkX_reach {cfg : Cfg} : ∀ {s : St} (as : List Act) {l : List St} {e : St},
    ReachX cfg s → walkX cfg s as = some (l, e) → ReachX cfg e ∧ ∀ u ∈ l, ReachX cfg u
  | _, [], _, _, r, h => by simp only [walkX, Option.some.injEq, Prod.mk.injEq] at h; obtain ⟨rfl, rfl⟩ := h; simp [r]
  | s, a :: as, l, e, r, h => by
    simp only [walkX] at h
    cases hm : moveX cfg s a with
    | none => rw [hm] at h; cases h
    | some t =>
      rw [hm] at h; dsimp only [Option.bind] at h
      cases hw : walkX cfg t as with
      | none => rw [hw] at h; cases h
      | some p =>
        rw [hw] at h
        simp only [Option.map_some, Option.some.injEq, Prod.mk.injEq] at h
        obtain ⟨rfl, rfl⟩ := h
        obtain ⟨h1, h2⟩ := walkX_reach as (.step a r hm) hw
        refine ⟨h1, ?_⟩
        intro u hu
        rcases List.mem_cons.1 hu with rfl | hu
        · exact r
        · exact h2 u hu

/-- A weakly fair lasso in which `w` never gets a CPU: `pre` reaches `s0` from the start, `cyc`
leads from `s0` back to `s0`, in every state of the cycle `w` waits holding nothing, and every
step class (`fairKey`) of the actions there are enabled in every state of the cycle is taken in
it. Going round forever is a weakly fair run (`Run.Fair`, with `moveX`) that never serves `w`. -/
def FairLasso (cfg : Cfg) (w : Nat) (pre cyc : List Act) : Prop :=
  ∃ s0 l0 l, walkX cfg (init cfg) pre = some (l0, s0) ∧ walkX cfg s0 cyc = some (l, s0) ∧
    l ≠ [] ∧ (∀ u ∈ l, starving cfg u w = true) ∧
    ∀ a ∈ actions cfg, (fairKey a).isSome = true → (∀ u ∈ l, (moveX cfg u a).isSome = true) →
      ∃ b ∈ cyc, fairKey b = fairKey a

def streamPre : List Act :=
  [.enter 1, .mark 1, .arrive 0, .enter 2, .mark 2, .accept 1 0, .refill 1 0, .exit 1 0 true,
   .release 1 0, .finish 1]

def streamCyc : List Act :=
  [.accept 2 0, .enter 1, .mark 1, .refill 2 0, .exit 2 0 true, .release 2 0, .finish 2,
   .enter 2, .mark 2, .accept 1 0, .refill 1 0, .exit 1 0 true, .release 1 0, .finish 1]

/-- `FairLasso`, as a computation. -/
def lassoOk (cfg : Cfg) (w : Nat) (pre cyc : List Act) : Bool :=
  match walkX cfg (init cfg) pre with
  | none => false
  | some (_, s0) =>
    match walkX cfg s0 cyc with
    | none => false
    | some (l, e) =>
      e == s0 && !l.isEmpty && l.all (starving cfg · w) &&
      (actions cfg).all (fun a => (fairKey a).isNone || !l.all (fun u => (moveX cfg u a).isSome) ||
        cyc.any (fun b => fairKey b == fairKey a))

theorem lassoOk_sound {cfg : Cfg} {w : Nat} {pre cyc : List Act} (h : lassoOk cfg w pre cyc = true) :
    FairLasso cfg w pre cyc := by
  unfold lassoOk at h
  split at h
  · cases h
  · rename_i l0 s0 h0
    split at h
    · cases h
    · rename_i l e h1
      simp only [Bool.and_eq_true, beq_iff_eq, Bool.not_eq_true', List.isEmpty_eq_false_iff,
        List.all_eq_true, Bool.or_eq_true, Option.isNone_iff_eq_none, List.any_eq_true] at h
      obtain ⟨⟨⟨he, hne⟩, hst⟩, hf⟩ := h
      subst he
      refine ⟨e, l0, l, h0, h1, hne, hst, ?_⟩
      intro a ha hk hen
      rcases hf a ha with (x | x) | ⟨b, hb, hbk⟩
      · simp [x] at hk
      · exfalso
        have h2 : (l.all fun u => (moveX cfg u a).isSome) = true := List.all_eq_true.2 hen
        rw [h2] at x; cases x
      · exact ⟨b, hb, hbk⟩

/-- Under the 0.32.0 rules, two drains taking turns on 1 CPU starve a one-task run forever, in a
weakly fair run: the run registers after the first drain and before the second, and every CPU
goes to a drain from then on. -/
theorem code0320_stream_starves : FairLasso (streamCfg .code0320) 0 streamPre streamCyc :=
  lassoOk_sound (by decide)

/-- The same under the 0.30.5 and 0.31 rules. -/
theorem code0305_stream_starves : FairLasso (streamCfg .code0305) 0 streamPre streamCyc :=
  lassoOk_sound (by decide)

end Cpuq
