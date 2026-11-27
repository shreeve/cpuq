/-
Backfill (0.32.0): while one `cpuq drain` gathers the pool, a task that ends before the drain
could start anyway may still start.

The step function (`Model.lean`) models the rules untimed, with the time left before the drain
could start as a window (`St.window`) that a drain's registration opens and time passing
(`Act.tick`) only shrinks; a task fits while its limit is within the window (`fits`). Here:

- `Timed`: the rules' own arithmetic, in real time. src/pool.zig's `shadow` is the latest end
  over the tasks the drain waits for; a task starts only if it ends by it (`fits`). Then the
  shadow never grows (`shadow_le`), and every task running from then on ends by the first
  shadow (`ends_by`): the drain starts by the first `S` it had.
- `window_closes`: in every weakly fair run with no new drain, the window closes.
- `drain_served_backfill`: from then on, a gathering drain is served (`drain_served`).
- `one_op_per_cpu`: backfill never puts two operations' tasks on one CPU (the safety invariant
  holds for `Rules.released`).
-/
import CpuqModel.Drains

namespace Cpuq

/-! ### The rules' arithmetic, in real time -/

namespace Timed

/-- A task the drain waits for: when it started, and its limit (src/op.zig's `tlimit`: `-t`
and the time a kill takes; 0, none). It ends by `start + limit`. -/
structure RTask where
  start : Nat
  limit : Nat

/-- Its latest end. -/
def RTask.ends (t : RTask) : Nat := t.start + t.limit

/-- src/pool.zig's `shadow`: the latest end over the tasks the drain waits for, or none when one
has no limit or none runs. -/
def shadow (ts : List RTask) : Option Nat :=
  if ts.isEmpty || ts.any (·.limit == 0) then none else some (ts.foldl (fun m t => max m t.ends) 0)

/-- src/pool.zig's `fits`: a task with limit `l` started at `now` ends by the shadow `S`. -/
def fits (l now S : Nat) : Bool := l != 0 && decide (now + l ≤ S)

/-- What may happen while the drain gathers: a task that fits starts (`now` is the time; it
never runs backwards: `step` takes it as an argument and the trace orders it), or a task ends. -/
inductive Step : List RTask → List RTask → Prop where
  | start (ts : List RTask) (l now S : Nat) : shadow ts = some S → fits l now S = true →
      Step ts (ts ++ [{ start := now, limit := l }])
  | stop (ts us : List RTask) (t : RTask) : Step (ts ++ t :: us) (ts ++ us)

theorem foldl_max_le {ts : List RTask} {m S : Nat} (hm : m ≤ S) (h : ∀ t ∈ ts, t.ends ≤ S) :
    ts.foldl (fun m t => max m t.ends) m ≤ S := by
  induction ts generalizing m with
  | nil => exact hm
  | cons t ts ih =>
    simp only [List.foldl_cons]
    exact ih (Nat.max_le.2 ⟨hm, h t (List.mem_cons_self ..)⟩) (fun u hu => h u (List.mem_cons_of_mem _ hu))

theorem le_foldl_max {ts : List RTask} {m : Nat} : m ≤ ts.foldl (fun m t => max m t.ends) m := by
  induction ts generalizing m with
  | nil => exact Nat.le_refl _
  | cons t ts ih => simp only [List.foldl_cons]; exact Nat.le_trans (Nat.le_max_left _ _) ih

theorem ends_le_foldl {ts : List RTask} {m : Nat} {t : RTask} (ht : t ∈ ts) :
    t.ends ≤ ts.foldl (fun m t => max m t.ends) m := by
  induction ts generalizing m with
  | nil => cases ht
  | cons u ts ih =>
    simp only [List.foldl_cons]
    rcases List.mem_cons.1 ht with e | e
    · subst e; exact Nat.le_trans (Nat.le_max_right _ _) le_foldl_max
    · exact ih e

/-- Any number of steps. -/
inductive Steps : List RTask → List RTask → Prop where
  | refl (ts : List RTask) : Steps ts ts
  | tail {ts us vs : List RTask} : Steps ts us → Step us vs → Steps ts vs

/-- Every task ends by `S`, and has a limit. -/
def AllBy (S : Nat) (ts : List RTask) : Prop := ∀ t ∈ ts, t.limit ≠ 0 ∧ t.ends ≤ S

/-- The shadow bounds every task's end. -/
theorem allBy_shadow {ts : List RTask} {S : Nat} (h : shadow ts = some S) : AllBy S ts := by
  unfold shadow at h
  split at h
  · cases h
  · rename_i hn
    cases h
    intro t ht
    refine ⟨fun z => hn ?_, ends_le_foldl ht⟩
    simp only [Bool.or_eq_true, List.any_eq_true, beq_iff_eq]
    exact .inr ⟨t, ht, z⟩

/-- While every task ends by `S`, so does the shadow. -/
theorem shadow_le {ts : List RTask} {S S' : Nat} (h : AllBy S ts) (e : shadow ts = some S') : S' ≤ S := by
  unfold shadow at e
  split at e
  · cases e
  · cases e; exact foldl_max_le (Nat.zero_le _) (fun t ht => (h t ht).2)

/-- Each step keeps every task ending by the first shadow: a task that starts fits a shadow no
later than it, and a task that ends leaves. -/
theorem Step.allBy {ts us : List RTask} {S : Nat} (st : Step ts us) (h : AllBy S ts) : AllBy S us := by
  cases st with
  | start _ l now S' hs hf =>
    intro t ht
    rcases List.mem_append.1 ht with x | x
    · exact h t x
    · simp only [List.mem_singleton] at x; subst x
      simp only [fits, Bool.and_eq_true, bne_iff_ne, ne_eq, decide_eq_true_eq] at hf
      exact ⟨hf.1, Nat.le_trans hf.2 (shadow_le h hs)⟩
  | stop ts us t =>
    intro u hu
    exact h u (List.mem_append.2 ((List.mem_append.1 hu).imp id (List.mem_cons_of_mem _)))

/-- The key property: from the first shadow `S`, through any steps, every task ends by `S` and
the shadow never grows past it. With every task ending by its own `ends` (each has a limit),
nothing the drain waits for runs at time `S`: the drain starts by the first `S` it had. -/
theorem ends_by {ts : List RTask} {S : Nat} (h0 : shadow ts = some S) {us : List RTask}
    (run : Steps ts us) :
    AllBy S us ∧ ∀ S', shadow us = some S' → S' ≤ S := by
  have : AllBy S us := by
    induction run with
    | refl => exact allBy_shadow h0
    | tail _ st ih => exact st.allBy ih
  exact ⟨this, fun _ e => shadow_le this e⟩

end Timed

/-! ### The window closes -/

theorem window_chain {cfg : Cfg} (r : Run cfg) {T : Nat} (calm : r.Calm T) :
    ∀ n k, T ≤ n → (r.st (n + k)).window ≤ (r.st n).window := by
  intro n k hn
  induction k with
  | zero => exact Nat.le_refl _
  | succ k ih =>
    rw [← Nat.add_assoc]
    cases ha : r.act (n + k) with
    | none => rw [r.stays _ ha]; exact ih
    | some a => exact Nat.le_trans (move_window (r.moves _ a ha) (calm _ (by omega) a ha).2.2.1) ih

/-- With backfill, the window closes: in a weakly fair run in which no drain registers after
`T`, the window reaches 0 and stays there (time passes: a tick is weakly fair). -/
theorem window_closes {cfg : Cfg} (hb : cfg.rules.backfill = true) (r : Run cfg) (fair : r.Fair)
    {T : Nat} (calm : r.Calm T) : ∃ m, T ≤ m ∧ ∀ k, (r.st (m + k)).window = 0 := by
  have key : ∀ w n, T ≤ n → (r.st n).window ≤ w → ∃ m, T ≤ m ∧ (r.st m).window = 0 := by
    intro w
    induction w with
    | zero => intro n hn hw; exact ⟨n, hn, by omega⟩
    | succ w ih =>
      intro n hn hw
      refine Classical.byContradiction fun hz => ?_
      have hz' : ∀ m, n ≤ m → (r.st m).window ≠ 0 := fun m hm h0 => hz ⟨m, by omega, h0⟩
      have en : ∀ m, n ≤ m → Enabled cfg (r.st m) .tick := by
        intro m hm
        have := hz' m hm
        unfold Enabled; simp [Cpuq.move, needsLock, hb]; omega
      obtain ⟨m, hm, b, hb', hk⟩ := fair .tick rfl n en
      have hbt : b = .tick := fairKey_class rfl (by intro o i ok w; cases w) hk
      subst hbt
      have e := r.moves m .tick hb'
      have hwm : (r.st m).window ≤ w + 1 := by
        have := window_chain r calm n (m - n) hn
        rw [show n + (m - n) = m by omega] at this; omega
      have hpos : (r.st m).window > 0 := Nat.pos_of_ne_zero (hz' m hm)
      simp only [Cpuq.move, needsLock, Bool.false_and, Bool.false_eq_true, ite_false, hb,
        Bool.true_and, decide_eq_true_eq, hpos, ite_true, Option.some.injEq] at e
      have : (r.st (m + 1)).window = (r.st m).window - 1 := by rw [← e]
      obtain ⟨m', hm', h0⟩ := ih (m + 1) (by omega) (by omega)
      exact hz ⟨m', by omega, h0⟩
  obtain ⟨m, hm, h0⟩ := key _ T (Nat.le_refl _) (Nat.le_refl _)
  exact ⟨m, hm, fun k => by have := window_chain r calm m k (by omega); omega⟩

/-! ### A gathering drain is served -/

/-- `cpuq drain` is served under the released rules, backfill on: once its window has closed
(which every weakly fair run reaches, `window_closes`) at a time it is first among drains,
waiting, with every CPU it lent back (`DCtx`), it ends up holding every CPU of the pool. -/
theorem drain_served_backfill {cfg : Cfg} {d : Nat} (hr : cfg.rules = Rules.released)
    (hd : drainOp cfg d = true) (hcap : (cfg.op d).cap = cfg.cpus) (hst : cfg.stops = false)
    (hk : cfg.kills = false) (r : Run cfg) (fair : r.Fair) {T : Nat} (calm : r.Calm T)
    (x0 : DCtx cfg d (r.st T)) (hw : (r.st T).window = 0) :
    ∃ m, T ≤ m ∧ (r.st m).owned d = cfg.cpus :=
  drain_served (by rw [hr]; exact CodeRules.released) hd hcap hst hk r fair calm x0 (.inr hw)

/-! ### Backfill never puts two operations on one CPU -/

theorem Safe.released : Safe Rules.released := ⟨rfl, rfl, rfl⟩

/-- Under the released rules (backfill on), in every reachable state: a process of a living
operation on CPU `c` means `c` is held by that operation, so every other process on `c` is that
operation's too (and `k_bound`: at most K of them). -/
theorem one_op_per_cpu {cfg : Cfg} {s : St} (hr : cfg.rules = Rules.released) (r : Reach cfg s)
    {o o' i i' c : Nat} (ha : (s.op o).phase = .alive)
    (h1 : (s.task o i).st = .running c ∨ (s.task o i).dying = some c)
    (h2 : (s.task o' i').st = .running c ∨ (s.task o' i').dying = some c) : o' = o := by
  have hs : Safe cfg.rules := by rw [hr]; exact Safe.released
  have p1 := not_shared hs r o i c h1
  have p2 := not_shared hs r o' i' c h2
  have l1 : (s.cpu c).lock = some o := by
    rcases p1 with x | x
    · exact x.2
    · rw [ha] at x; cases x.1
  rcases p2 with x | x
  · rw [l1] at x; exact (Option.some.inj x.2).symm
  · rw [l1] at x; cases x.2

end Cpuq
