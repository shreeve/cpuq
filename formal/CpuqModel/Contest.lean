/-
cpuq 0.40.0: contested CPUs (DESIGN-0.40.md). cpuq decides how many tasks run, never which CPU
they hold; the kernel shares CPU time. This file models the admission rules and proves the
design's five properties for every configuration (no search).

What a state is: per run (`cpuq run -n M -c C`) its arrival and ticket, its tasks waiting
(`pend`), and its running tasks, each starting (started since the last tick: the design's
"started in the last 2 s"), computing or blocked (waiting on I/O, a sleep, a child); its `-c`.
Per drain (`cpuq drain -c N`): absent, waiting, started (its N CPUs isolated) or over; its ticket;
whether its command computes; how long it has been isolated (`age`) and idle (`idle`), in ticks.
Machine-wide: whether the gates (memory, disk, pressure) are open, and the CPUs busy outside cpuq.

Measured busy is abstract: a computing task is one CPU busy, a blocked one none, and which it is
changes at any time (`block`, `wake`), as a drain's command (`dbusy`). The kernel's sharing of
CPU time (cgroup weights, macOS SIGSTOP balancing) is below this model: it decides who runs on
the CPUs, not how many tasks are admitted.

Each action is one atomic step and ends with the admission pass (`pass`): every waiter that may
start starts, the drains first, until none may. That is "starts at once": in the code a waiter
checks for itself, and the pass is the closure of those checks.

The rules as admission (`canStart`, `canDrain`):
- capacity T (`capT`): the pool less the CPUs isolated by started drains;
- fair share: project p is under share when `running_p × W < T × w_p` (W: the weights of the
  projects with tasks running or waiting), and then it starts its next task at once;
- within a project only its first waiter (an urgent run's first task, then fewest tasks running,
  then the oldest last start, a run that never started first, then ticket: `projFirst`) takes a
  start;
- over share, a run starts a task only while there is room, `busy + starting < T − 0.5`, which
  for whole CPUs is `busy + starting + 1 ≤ T` (`room`), and only the first in line among the
  projects' first waiters (an urgent run's first task, then project running ÷ weight, then fewer
  tasks running, then ticket: `head`) takes it;
- hard limits: the gates, a run's `-c`, and running tasks machine-wide < 4T at each start;
- a drain starts when no older drain waits, at most `drainMax` CPUs are then isolated, the gates are
  open and (with `Rules.drainFifo`) no older run that holds nothing waits; its N CPUs are
  isolated at once, with no collecting; it ends at its limit plus grace (`tick`), when its
  command ends or when it idles while others wait (`idleMax` ticks).

`Rules.design` is DESIGN-0.40.md read literally; `Rules.fixed` has the two rule changes the
proofs need (`busyAll` off: busy counts the CPUs no drain isolates; `drainFifo` on).
`Rules.nostarve` adds the two no-starvation fixes (`Stream.lean`): within a project a run that
never started counts its arrival as its last start (`arrivalKey`), and every start goes to the
first in one line, projects under share first (`oneLine`).
-/

namespace Cpuq.Contest

/-! ## Sums and products over `0 … n-1` -/

def rsum : Nat → (Nat → Nat) → Nat
  | 0, _ => 0
  | n + 1, f => rsum n f + f n

def rprod : Nat → (Nat → Nat) → Nat
  | 0, _ => 1
  | n + 1, f => rprod n f * f n

theorem rsum_congr {n : Nat} {f g : Nat → Nat} (h : ∀ i < n, f i = g i) : rsum n f = rsum n g := by
  induction n with
  | zero => rfl
  | succ n ih => simp only [rsum]; rw [ih (fun i hi => h i (by omega)), h n (by omega)]

theorem rsum_le {n : Nat} {f g : Nat → Nat} (h : ∀ i < n, f i ≤ g i) : rsum n f ≤ rsum n g := by
  induction n with
  | zero => exact Nat.le_refl _
  | succ n ih =>
    simp only [rsum]
    have h1 := ih (fun i hi => h i (by omega))
    have h2 := h n (by omega)
    omega

theorem rsum_le_eq {n : Nat} {f g : Nat → Nat} (h : ∀ i < n, f i ≤ g i) (e : rsum n f = rsum n g) :
    ∀ i < n, f i = g i := by
  induction n with
  | zero => intro i hi; omega
  | succ n ih =>
    simp only [rsum] at e
    have h1 := rsum_le (fun i (hi : i < n) => h i (by omega))
    have h2 := h n (by omega)
    have e1 : rsum n f = rsum n g := by omega
    intro i hi
    rcases Nat.lt_succ_iff_lt_or_eq.1 hi with hi | hi
    · exact ih (fun i hi => h i (by omega)) e1 i hi
    · subst hi; omega

theorem rsum_eq_zero {n : Nat} {f : Nat → Nat} : rsum n f = 0 ↔ ∀ i < n, f i = 0 := by
  induction n with
  | zero => simp [rsum]
  | succ n ih =>
    simp only [rsum]
    constructor
    · intro h i hi
      have h1 : rsum n f = 0 := by omega
      rcases Nat.lt_succ_iff_lt_or_eq.1 hi with hi | hi
      · exact ih.1 h1 i hi
      · subst hi; omega
    · intro h
      have h1 := ih.2 (fun i hi => h i (by omega))
      have h2 := h n (by omega)
      omega

theorem le_rsum {n i : Nat} {f : Nat → Nat} (hi : i < n) : f i ≤ rsum n f := by
  induction n with
  | zero => omega
  | succ n ih =>
    simp only [rsum]
    rcases Nat.lt_succ_iff_lt_or_eq.1 hi with h | h
    · have := ih h; omega
    · subst h; omega

/-- Changing one term changes the sum by the difference. -/
theorem rsum_upd {n i : Nat} {f g : Nat → Nat} (hi : i < n) (h : ∀ j, j ≠ i → g j = f j) :
    rsum n g + f i = rsum n f + g i := by
  induction n with
  | zero => omega
  | succ n ih =>
    simp only [rsum]
    by_cases hn : i = n
    · subst hn
      rw [rsum_congr (fun j (hj : j < i) => h j (by omega))]
      omega
    · have := ih (by omega)
      rw [h n (fun e => hn e.symm)]
      omega

/-- The least value of `f` over the `i` with `P i`. -/
theorem exists_min (P : Nat → Prop) (f : Nat → Nat) (h : ∃ i, P i) :
    ∃ j, P j ∧ ∀ k, P k → f j ≤ f k := by
  have key : ∀ v i, f i = v → P i → ∃ j, P j ∧ ∀ k, P k → f j ≤ f k := by
    intro v
    induction v using Nat.strongRecOn with
    | _ v ih =>
      intro i hv hi
      by_cases hm : ∀ k, P k → f i ≤ f k
      · exact ⟨i, hi, hm⟩
      · have : ∃ k, P k ∧ f k < f i := by
          apply Classical.byContradiction
          intro hn
          apply hm
          intro k hk
          apply Classical.byContradiction
          intro hlt
          exact hn ⟨k, hk, by omega⟩
        obtain ⟨k, hk, hlt⟩ := this
        exact ih (f k) (by omega) k rfl hk
  obtain ⟨i, hi⟩ := h
  exact key _ i rfl hi

/-! ## Configuration -/

structure RunCfg where
  proj : Nat := 0
  /-- `-n`: how many tasks. -/
  tasks : Nat := 1
  /-- `-c`: at most this many tasks of the run at once (at least 1). -/
  cap : Nat := 1
  /-- `--urgent`: its first task goes ahead of the line. -/
  urgent : Bool := false
  deriving Repr

structure DrainCfg where
  /-- `-c N`: the CPUs it isolates, SMT siblings of the chosen CPUs included; which CPUs
  (`--cpus`) is left abstract. 0.40.0 has no `--all`. -/
  size : Nat := 1
  /-- `-t`, in ticks (at most `Cfg.ceil`). -/
  limit : Nat := 1
  deriving Repr

structure Rules where
  /-- Busy is the measured CPU of the whole machine, the drains' isolated CPUs included (the
  design as written). Off: busy counts only the CPUs no drain isolates. -/
  busyAll : Bool
  /-- A drain also waits for every older run that holds nothing and waits (0.34.0's FIFO).
  Off: it waits only for older drains, the `drainMax` bound and the gates (the design as
  written, property 4). -/
  drainFifo : Bool
  /-- Within a project, a run that has never started counts its arrival as its last start, so
  it goes behind runs whose last start is older (no-starvation fix 1). Off: it goes first. -/
  arrivalKey : Bool := false
  /-- One line for every start: a run starts a task only as the first in line among the
  projects' first waiters, projects under share first, then the line's order (no-starvation fix
  2). Off: a run under share starts without a turn, and only spare room is taken in line. -/
  oneLine : Bool := false
  deriving Repr

/-- DESIGN-0.40.md as written. -/
def Rules.design : Rules := { busyAll := true, drainFifo := false }
/-- The design with the two changes the proofs need. -/
def Rules.fixed : Rules := { busyAll := false, drainFifo := true }
/-- `fixed` with the two no-starvation fixes (`Stream.lean`). -/
def Rules.nostarve : Rules := { busyAll := false, drainFifo := true, arrivalKey := true, oneLine := true }

structure Cfg where
  /-- The pool's CPUs (the budget). -/
  pool : Nat
  /-- `drain_max`: the most CPUs drains may isolate at once (default half the pool). With
  `drainMax < pool` the other tasks always keep at least one CPU (`capT_pos`). -/
  drainMax : Nat := pool / 2
  /-- Project weights; a missing or zero weight is 1. -/
  weights : List Nat := []
  runs : List RunCfg := []
  drains : List DrainCfg := []
  /-- From TERM to KILL, in ticks. -/
  grace : Nat := 1
  /-- The longest limit a drain may ask (2 h). -/
  ceil : Nat := 4
  /-- The idle stop: a drain whose command is idle for more than this many ticks in a row while
  others wait is stopped. -/
  idleMax : Nat := 2
  rules : Rules := .fixed

namespace Cfg
def nr (c : Cfg) : Nat := c.runs.length
def nd (c : Cfg) : Nat := c.drains.length
def run (c : Cfg) (r : Nat) : RunCfg := c.runs.getD r {}
def drain (c : Cfg) (d : Nat) : DrainCfg := c.drains.getD d {}
def w (c : Cfg) (p : Nat) : Nat := max 1 (c.weights.getD p 1)
/-- The projects are `0 … np-1`. -/
def np (c : Cfg) : Nat := c.runs.foldr (fun x m => max (x.proj + 1) m) 0
/-- The product of the weights: dividing it by a project's weight is exact, so a project's
running count times it is its share ÷ weight in whole numbers. -/
def wprod (c : Cfg) : Nat := rprod c.np c.w
def limitOf (c : Cfg) (d : Nat) : Nat := min (c.drain d).limit c.ceil
end Cfg

theorem Cfg.w_pos (c : Cfg) (p : Nat) : 0 < c.w p := by
  unfold Cfg.w; omega

/-! ## State -/

structure RunSt where
  here : Bool := false
  ticket : Nat := 0
  pend : Nat := 0
  start : Nat := 0
  comp : Nat := 0
  blk : Nat := 0
  cap : Nat := 0
  /-- Has started a task. -/
  ran : Bool := false
  /-- When it last started a task (the tick count). -/
  last : Nat := 0
  deriving Repr

def RunSt.running (x : RunSt) : Nat := x.start + x.comp + x.blk

/-- A run's last start key: its last start (or, with `ak`, its arrival if it never started) plus
one, else 0. -/
def lkOf (ak : Bool) (x : RunSt) : Nat := if x.ran || ak then x.last + 1 else 0

inductive DPh where
  | absent | waiting | started | over
  deriving DecidableEq, Repr

structure DrainSt where
  ph : DPh := .absent
  ticket : Nat := 0
  /-- Its command computes (on its isolated CPUs). -/
  busy : Bool := false
  /-- Ticks since it started. -/
  age : Nat := 0
  /-- Ticks in a row its command has been idle while others wait. -/
  idle : Nat := 0
  deriving Repr

structure St where
  run : Nat → RunSt
  drain : Nat → DrainSt
  gate : Bool := true
  outside : Nat := 0
  next : Nat := 0
  /-- Ticks so far: the time a start is stamped with. -/
  now : Nat := 0

def upd {α : Type} (f : Nat → α) (i : Nat) (x : α) : Nat → α := fun j => if j = i then x else f j

@[simp] theorem upd_same {α : Type} (f : Nat → α) (i : Nat) (x : α) : upd f i x i = x := by simp [upd]
@[simp] theorem upd_other {α : Type} (f : Nat → α) {i j : Nat} (x : α) (h : j ≠ i) : upd f i x j = f j := by
  simp [upd, h]

def setRun (s : St) (r : Nat) (x : RunSt) : St := { s with run := upd s.run r x }
def setDrain (s : St) (d : Nat) (y : DrainSt) : St := { s with drain := upd s.drain d y }

def anyLT (n : Nat) (p : Nat → Bool) : Bool := (List.range n).any p

theorem anyLT_iff {n : Nat} {p : Nat → Bool} : anyLT n p = true ↔ ∃ i < n, p i = true := by
  simp [anyLT]

theorem anyLT_false {n : Nat} {p : Nat → Bool} : anyLT n p = false ↔ ∀ i < n, p i = false := by
  rw [← Bool.not_eq_true, anyLT_iff]
  constructor
  · intro h i hi
    cases e : p i
    · rfl
    · exact absurd ⟨i, hi, e⟩ h
  · rintro h ⟨i, hi, e⟩
    rw [h i hi] at e; cases e

theorem ite_t {α : Type} {c : Prop} [Decidable c] (h : c) (x y : α) : (if c then x else y) = x := by simp [h]
theorem ite_f {α : Type} {c : Prop} [Decidable c] (h : ¬c) (x y : α) : (if c then x else y) = y := by simp [h]

/-! ## What the rules read -/

section
variable (cfg : Cfg)

def total (s : St) : Nat := rsum cfg.nr (fun r => (s.run r).running)
def projRun (s : St) (p : Nat) : Nat :=
  rsum cfg.nr (fun r => if (cfg.run r).proj = p then (s.run r).running else 0)
def taskBusy (s : St) : Nat := rsum cfg.nr (fun r => (s.run r).comp)
def startingN (s : St) : Nat := rsum cfg.nr (fun r => (s.run r).start)
def isoF (d : Nat) (y : DrainSt) : Nat := if y.ph = .started then (cfg.drain d).size else 0
/-- The CPUs isolated: the sizes of the started drains. -/
def iso (s : St) : Nat := rsum cfg.nd (fun d => isoF cfg d (s.drain d))
/-- What the started drains' commands keep busy. -/
def drainLoad (s : St) : Nat :=
  rsum cfg.nd (fun d => if (s.drain d).ph = .started ∧ (s.drain d).busy = true then (cfg.drain d).size else 0)
/-- Capacity T. -/
def capT (s : St) : Nat := cfg.pool - iso cfg s
/-- Busy as the rules measure it. -/
def busyM (s : St) : Nat :=
  taskBusy cfg s + s.outside + (if cfg.rules.busyAll then drainLoad cfg s else 0)
/-- Spare room: `busy + starting < T − 0.5`, in whole CPUs. -/
def room (s : St) : Prop := busyM cfg s + startingN cfg s + 1 ≤ capT cfg s

def activeP (s : St) (p : Nat) : Bool :=
  anyLT cfg.nr (fun r => decide ((cfg.run r).proj = p) && (s.run r).here &&
    (decide (0 < (s.run r).pend) || decide (0 < (s.run r).running)))
/-- The weights of the projects with tasks running or waiting. -/
def W (s : St) : Nat := rsum cfg.np (fun p => if activeP cfg s p then cfg.w p else 0)
/-- Under its fair share `T × w_p / W`. -/
def under (s : St) (r : Nat) : Prop :=
  projRun cfg s (cfg.run r).proj * W cfg s < capT cfg s * cfg.w (cfg.run r).proj

instance (s : St) : Decidable (room cfg s) := by unfold room; infer_instance
instance (s : St) (r : Nat) : Decidable (under cfg s r) := by unfold under; infer_instance

/-- Arrived, a task waiting, and not held by its own `-c`. -/
def eligible (s : St) (r : Nat) : Bool :=
  (s.run r).here && decide (0 < (s.run r).pend) && decide ((s.run r).running < (s.run r).cap)

/-- 0 for an urgent run's first task, else 1. -/
def urg (s : St) (r : Nat) : Nat := if (cfg.run r).urgent && !(s.run r).ran then 0 else 1

/-- Project running ÷ weight, scaled by the product of the weights so it is whole. -/
def key (s : St) (r : Nat) : Nat := projRun cfg s (cfg.run r).proj * (cfg.wprod / cfg.w (cfg.run r).proj)

/-- The line's order for spare room: an urgent run's first task, then project running ÷ weight,
then the run with fewer tasks running, then ticket. -/
def before (s : St) (i j : Nat) : Bool :=
  decide (urg cfg s i < urg cfg s j) || (decide (urg cfg s i = urg cfg s j) &&
  (decide (key cfg s i < key cfg s j) || (decide (key cfg s i = key cfg s j) &&
  (decide ((s.run i).running < (s.run j).running) || (decide ((s.run i).running = (s.run j).running) &&
    decide ((s.run i).ticket < (s.run j).ticket))))))

/-- When a run last started a task (with `arrivalKey`, when it arrived if it never started), one
more; 0 for a run that never started without `arrivalKey`, so it goes first. -/
def lastKey (s : St) (r : Nat) : Nat := lkOf cfg.rules.arrivalKey (s.run r)

/-- The order within a project: an urgent run's first task, then fewer tasks running, then the
oldest last start (a run that never started first), then ticket. -/
def pbefore (s : St) (i j : Nat) : Bool :=
  decide (urg cfg s i < urg cfg s j) || (decide (urg cfg s i = urg cfg s j) &&
  (decide ((s.run i).running < (s.run j).running) || (decide ((s.run i).running = (s.run j).running) &&
  (decide (lastKey cfg s i < lastKey cfg s j) || (decide (lastKey cfg s i = lastKey cfg s j) &&
    decide ((s.run i).ticket < (s.run j).ticket))))))

/-- The project's first waiter: no waiter of its project comes before it. -/
def projFirst (s : St) (r : Nat) : Bool :=
  !anyLT cfg.nr (fun i => eligible s i && decide ((cfg.run i).proj = (cfg.run r).proj) && pbefore cfg s i r)

/-- A waiter that may take a start: waiting, and its project's first waiter. -/
def front (s : St) (r : Nat) : Bool := eligible s r && projFirst cfg s r
end

/-- The first of `l` by `lt` among those with `p`. -/
def pickStep (p : Nat → Bool) (lt : Nat → Nat → Bool) (acc : Option Nat) (i : Nat) : Option Nat :=
  if p i then
    match acc with
    | none => some i
    | some j => if lt i j then some i else some j
  else acc

def pick (p : Nat → Bool) (lt : Nat → Nat → Bool) (l : List Nat) : Option Nat :=
  l.foldl (pickStep p lt) none

section
variable (cfg : Cfg)

/-- The first in line among the projects' first waiters. -/
def head (s : St) : Option Nat := pick (front cfg s) (before cfg s) (List.range cfg.nr)

/-- The one line (`oneLine`): projects under share first, then the line's order. -/
def before2 (s : St) (i j : Nat) : Bool :=
  (decide (under cfg s i) && !decide (under cfg s j)) ||
    (decide (under cfg s i) == decide (under cfg s j) && before cfg s i j)

/-- The first in the one line among the projects' first waiters. -/
def head2 (s : St) : Option Nat := pick (front cfg s) (before2 cfg s) (List.range cfg.nr)

/-- A run may start a task: it waits, not held by its `-c`; the gates are open and fewer than
4T tasks run; it is its project's first waiter; and its project is under share, or there is room
and it is the first in line. With `oneLine`: it is the first in the one line, and under share or
with room. -/
def canStart (s : St) (r : Nat) : Bool :=
  eligible s r && s.gate && decide (total cfg s < 4 * capT cfg s) &&
    (projFirst cfg s r && (if cfg.rules.oneLine then head2 cfg s == some r && (decide (under cfg s r) || decide (room cfg s))
      else decide (under cfg s r) || (decide (room cfg s) && head cfg s == some r)))

def olderDrainWaits (s : St) (d : Nat) : Bool :=
  anyLT cfg.nd (fun e => decide ((s.drain e).ph = .waiting) && decide ((s.drain e).ticket < (s.drain d).ticket))

/-- A run that waits holding nothing. -/
def emptyWaiter (s : St) (r : Nat) : Bool :=
  (s.run r).here && decide (0 < (s.run r).pend) && decide ((s.run r).running = 0)

def olderEmptyWaits (s : St) (d : Nat) : Bool :=
  anyLT cfg.nr (fun r => emptyWaiter s r && decide ((s.run r).ticket < (s.drain d).ticket))

/-- A drain may start: it waits, no older drain waits, at most `drainMax` CPUs are then isolated,
the gates are open, and (with `drainFifo`) no older run that holds nothing waits. -/
def canDrain (s : St) (d : Nat) : Bool :=
  decide ((s.drain d).ph = .waiting) && s.gate && decide (iso cfg s + (cfg.drain d).size ≤ cfg.drainMax) &&
    !olderDrainWaits cfg s d && !(cfg.rules.drainFifo && olderEmptyWaits cfg s d)

def admitR (t : Nat) (x : RunSt) : RunSt := { x with pend := x.pend - 1, start := x.start + 1, ran := true, last := t }
def startDr (y : DrainSt) : DrainSt := { y with ph := .started, age := 0, idle := 0, busy := true }

def admit (s : St) (r : Nat) : St := setRun s r (admitR s.now (s.run r))

def startD (s : St) (d : Nat) : St := setDrain s d (startDr (s.drain d))

/-- One start of the pass: a drain if one may start, else a run. -/
def pass1 (s : St) : Option St :=
  match (List.range cfg.nd).find? (canDrain cfg s) with
  | some d => some (startD s d)
  | none => ((List.range cfg.nr).find? (canStart cfg s)).map (admit s)

def passN : Nat → St → St
  | 0, s => s
  | k + 1, s =>
    match pass1 cfg s with
    | some t => passN k t
    | none => s

def isWaiting (y : DrainSt) : Nat := if y.ph = .waiting then 1 else 0

/-- What is left to start: tasks waiting and drains waiting. Each start lowers it by one. -/
def work (s : St) : Nat := rsum cfg.nr (fun r => (s.run r).pend) + rsum cfg.nd (fun d => isWaiting (s.drain d))

/-- The admission pass: start until nothing may start. -/
def pass (s : St) : St := passN cfg (work cfg s) s

/-! ## Actions -/

/-- Someone waits: a task, or a drain. -/
def anyWait (s : St) : Bool :=
  anyLT cfg.nr (fun r => decide (0 < (s.run r).pend)) || anyLT cfg.nd (fun d => decide ((s.drain d).ph = .waiting))

/-- The idle count after a tick: one more while the command idles and others wait, else 0. -/
def idleNext (wait : Bool) (y : DrainSt) : Nat := if !y.busy && wait then y.idle + 1 else 0

/-- Past its limit and grace (KILL), or idle too long while others wait (the idle stop). -/
def overdue (wait : Bool) (d : Nat) (y : DrainSt) : Prop :=
  y.age + 1 > cfg.limitOf d + cfg.grace ∨ idleNext wait y > cfg.idleMax

instance (wait : Bool) (d : Nat) (y : DrainSt) : Decidable (overdue cfg wait d y) := by
  unfold overdue; infer_instance

/-- A tick for one drain: a started drain ages; overdue, it is over. -/
def tickD (wait : Bool) (d : Nat) (y : DrainSt) : DrainSt :=
  if y.ph = .started then
    if overdue cfg wait d y then { y with ph := .over }
    else { y with age := y.age + 1, idle := idleNext wait y }
  else y

/-- Time passes: every started task is now measured (computing; it may block later), and every
started drain ages. -/
def tickSt (s : St) : St :=
  { s with
    run := fun r => { s.run r with start := 0, comp := (s.run r).comp + (s.run r).start }
    drain := fun d => tickD cfg (anyWait cfg s) d (s.drain d)
    now := s.now + 1 }
end

theorem tickD_ph (cfg : Cfg) (w : Bool) (d : Nat) (y : DrainSt) :
    (tickD cfg w d y).ph = y.ph ∨ (tickD cfg w d y).ph = .over := by
  unfold tickD
  split
  · split
    · exact Or.inr rfl
    · exact Or.inl rfl
  · exact Or.inl rfl

theorem tickD_started {cfg : Cfg} {w : Bool} {d : Nat} {y : DrainSt} (h : (tickD cfg w d y).ph = .started) :
    y.ph = .started ∧ (tickD cfg w d y).age = y.age + 1 ∧ (tickD cfg w d y).age ≤ cfg.limitOf d + cfg.grace ∧
      (tickD cfg w d y).idle ≤ cfg.idleMax ∧ (tickD cfg w d y).ticket = y.ticket := by
  unfold tickD at h ⊢
  split at h
  · rename_i h1
    split at h
    · cases h
    · rename_i h2
      rw [ite_t h1, ite_f h2]
      simp only [overdue, not_or] at h2
      exact ⟨h1, rfl, (by show y.age + 1 ≤ _; omega), (by show idleNext w y ≤ _; omega), rfl⟩
  · rename_i h1; exact absurd h h1

theorem tickD_ticket (cfg : Cfg) (w : Bool) (d : Nat) (y : DrainSt) : (tickD cfg w d y).ticket = y.ticket := by
  unfold tickD; split
  · split <;> rfl
  · rfl

inductive Act where
  /-- A run arrives and takes a ticket. -/
  | arrive (r : Nat)
  /-- A drain arrives and takes a ticket. -/
  | arriveD (d : Nat)
  /-- A task ends: one starting, computing or blocked. -/
  | finS (r : Nat)
  | finC (r : Nat)
  | finB (r : Nat)
  /-- A computing task waits (I/O, a sleep, a child), or a waiting one computes again. -/
  | block (r : Nat)
  | wake (r : Nat)
  /-- A drain's command computes or idles. -/
  | dbusy (d : Nat) (b : Bool)
  /-- A drain ends before its limit: its command ends, the idle stop, Ctrl-C. -/
  | dend (d : Nat)
  | tick
  /-- The gates (memory, disk, pressure) open or close. -/
  | gate (b : Bool)
  /-- The CPUs busy outside cpuq. -/
  | load (k : Nat)
  /-- `cpuq limit`: a run's `-c` changes. -/
  | limit (r c : Nat)
  deriving Repr

def act (cfg : Cfg) (s : St) : Act → Option St
  | .arrive r =>
    if r < cfg.nr ∧ (s.run r).here = false then
      some { setRun s r { here := true, ticket := s.next, pend := (cfg.run r).tasks, cap := max 1 (cfg.run r).cap, last := s.now }
             with next := s.next + 1 }
    else none
  | .arriveD d =>
    if d < cfg.nd ∧ (s.drain d).ph = .absent then
      some { setDrain s d { ph := .waiting, ticket := s.next } with next := s.next + 1 }
    else none
  | .finS r =>
    if r < cfg.nr ∧ 0 < (s.run r).start then some (setRun s r { s.run r with start := (s.run r).start - 1 }) else none
  | .finC r =>
    if r < cfg.nr ∧ 0 < (s.run r).comp then some (setRun s r { s.run r with comp := (s.run r).comp - 1 }) else none
  | .finB r =>
    if r < cfg.nr ∧ 0 < (s.run r).blk then some (setRun s r { s.run r with blk := (s.run r).blk - 1 }) else none
  | .block r =>
    if r < cfg.nr ∧ 0 < (s.run r).comp then
      some (setRun s r { s.run r with comp := (s.run r).comp - 1, blk := (s.run r).blk + 1 })
    else none
  | .wake r =>
    if r < cfg.nr ∧ 0 < (s.run r).blk then
      some (setRun s r { s.run r with comp := (s.run r).comp + 1, blk := (s.run r).blk - 1 })
    else none
  | .dbusy d b =>
    if d < cfg.nd ∧ (s.drain d).ph = .started then some (setDrain s d { s.drain d with busy := b }) else none
  | .dend d =>
    if d < cfg.nd ∧ (s.drain d).ph = .started then some (setDrain s d { s.drain d with ph := .over }) else none
  | .tick => some (tickSt cfg s)
  | .gate b => some { s with gate := b }
  | .load k => some { s with outside := k }
  | .limit r c =>
    if r < cfg.nr ∧ (s.run r).here = true ∧ 0 < c then some (setRun s r { s.run r with cap := c }) else none

/-- One move: an action, then the admission pass. -/
def step (cfg : Cfg) (s : St) (a : Act) : Option St := (act cfg s a).map (pass cfg)

def init : St := { run := fun _ => {}, drain := fun _ => {} }

inductive Reach (cfg : Cfg) : St → Prop where
  | init : Reach cfg init
  | step {s t : St} (a : Act) : Reach cfg s → step cfg s a = some t → Reach cfg t

/-! ## Frame lemmas -/

@[simp] theorem setRun_run {s : St} {r j : Nat} {x : RunSt} : (setRun s r x).run j = if j = r then x else s.run j := rfl
@[simp] theorem setRun_drain {s : St} {r : Nat} {x : RunSt} : (setRun s r x).drain = s.drain := rfl
@[simp] theorem setRun_gate {s : St} {r : Nat} {x : RunSt} : (setRun s r x).gate = s.gate := rfl
@[simp] theorem setRun_outside {s : St} {r : Nat} {x : RunSt} : (setRun s r x).outside = s.outside := rfl
@[simp] theorem setDrain_drain {s : St} {d j : Nat} {y : DrainSt} : (setDrain s d y).drain j = if j = d then y else s.drain j := rfl
@[simp] theorem setDrain_run {s : St} {d : Nat} {y : DrainSt} : (setDrain s d y).run = s.run := rfl
@[simp] theorem setDrain_gate {s : St} {d : Nat} {y : DrainSt} : (setDrain s d y).gate = s.gate := rfl

theorem sum_setRun {n r : Nat} (F : Nat → RunSt → Nat) (s : St) (x : RunSt) (hr : r < n) :
    rsum n (fun j => F j ((setRun s r x).run j)) + F r (s.run r) = rsum n (fun j => F j (s.run j)) + F r x := by
  have h := rsum_upd (f := fun j => F j (s.run j)) (g := fun j => F j ((setRun s r x).run j)) hr
    (fun j hj => by simp [hj])
  have e : F r ((setRun s r x).run r) = F r x := by simp
  rw [e] at h; exact h

theorem sum_setDrain {n d : Nat} (F : Nat → DrainSt → Nat) (s : St) (y : DrainSt) (hd : d < n) :
    rsum n (fun j => F j ((setDrain s d y).drain j)) + F d (s.drain d) = rsum n (fun j => F j (s.drain j)) + F d y := by
  have h := rsum_upd (f := fun j => F j (s.drain j)) (g := fun j => F j ((setDrain s d y).drain j)) hd
    (fun j hj => by simp [hj])
  have e : F d ((setDrain s d y).drain d) = F d y := by simp
  rw [e] at h; exact h

/-! ## The pass ends with nothing that may start -/

theorem pass1_work {cfg : Cfg} {s t : St} (h : pass1 cfg s = some t) : work cfg t + 1 = work cfg s := by
  unfold pass1 at h
  split at h
  · rename_i d hd
    cases h
    have hc := List.find?_some hd
    have hm := List.mem_range.1 (List.mem_of_find?_eq_some hd)
    simp only [canDrain, Bool.and_eq_true, decide_eq_true_eq] at hc
    have hw := hc.1.1.1.1
    have h1 := sum_setDrain (fun _ y => isWaiting y) s (startDr (s.drain d)) hm
    try dsimp only at h1
    have e1 : isWaiting (s.drain d) = 1 := by simp [isWaiting, hw]
    have e2 : isWaiting (startDr (s.drain d)) = 0 := by simp [isWaiting, startDr]
    rw [e1, e2] at h1
    unfold work startD
    simp only [setDrain_run]
    omega
  · cases hf : (List.range cfg.nr).find? (canStart cfg s) with
    | none => rw [hf] at h; cases h
    | some r =>
      rw [hf] at h; cases h
      have hc := List.find?_some hf
      have hm := List.mem_range.1 (List.mem_of_find?_eq_some hf)
      simp only [canStart, eligible, Bool.and_eq_true, decide_eq_true_eq] at hc
      have hp := hc.1.1.1.1.2
      have h1 := sum_setRun (fun _ x => x.pend) s (admitR s.now (s.run r)) hm
      try dsimp only at h1
      have e1 : (admitR s.now (s.run r)).pend + 1 = (s.run r).pend := by simp only [admitR]; omega
      unfold work admit
      simp only [setRun_drain]
      omega

theorem passN_closed {cfg : Cfg} : ∀ (k : Nat) (s : St), work cfg s ≤ k → pass1 cfg (passN cfg k s) = none
  | 0, s, h => by
    cases e : pass1 cfg s with
    | none => simpa [passN] using e
    | some t => have := pass1_work e; omega
  | k + 1, s, h => by
    simp only [passN]
    cases e : pass1 cfg s with
    | none => simpa using e
    | some t => have := pass1_work e; exact passN_closed k t (by omega)

theorem pass_closed (cfg : Cfg) (s : St) : pass1 cfg (pass cfg s) = none :=
  passN_closed _ s (Nat.le_refl _)

/-- A closed state: no drain and no run may start. -/
theorem closed_iff {cfg : Cfg} {s : St} :
    pass1 cfg s = none ↔ (∀ d < cfg.nd, canDrain cfg s d = false) ∧ (∀ r < cfg.nr, canStart cfg s r = false) := by
  unfold pass1
  constructor
  · intro h
    split at h
    · cases h
    · rename_i hd
      have h1 := List.find?_eq_none.1 hd
      have h2 : (List.range cfg.nr).find? (canStart cfg s) = none := by
        cases e : (List.range cfg.nr).find? (canStart cfg s) with
        | none => rfl
        | some r => rw [e] at h; cases h
      have h3 := List.find?_eq_none.1 h2
      refine ⟨fun d hd => ?_, fun r hr => ?_⟩
      · simpa using h1 d (List.mem_range.2 hd)
      · simpa using h3 r (List.mem_range.2 hr)
  · rintro ⟨h1, h2⟩
    have e1 : (List.range cfg.nd).find? (canDrain cfg s) = none :=
      List.find?_eq_none.2 (fun d hd => by simp [h1 d (List.mem_range.1 hd)])
    have e2 : (List.range cfg.nr).find? (canStart cfg s) = none :=
      List.find?_eq_none.2 (fun r hr => by simp [h2 r (List.mem_range.1 hr)])
    rw [e1, e2]; rfl

theorem iso_le {cfg : Cfg} {s t : St} (h : ∀ d, (t.drain d).ph = .started → (s.drain d).ph = .started) :
    iso cfg t ≤ iso cfg s := by
  unfold iso; apply rsum_le; intro d _
  by_cases ht : (t.drain d).ph = .started
  · simp [isoF, ht, h d ht]
  · simp [isoF, ht]

theorem iso_startD {cfg : Cfg} {s : St} {d : Nat} (hd : d < cfg.nd) (hw : (s.drain d).ph = .waiting) :
    iso cfg (startD s d) = iso cfg s + (cfg.drain d).size := by
  have h := sum_setDrain (isoF cfg) s (startDr (s.drain d)) hd
  have e1 : isoF cfg d (s.drain d) = 0 := by simp [isoF, hw]
  have e2 : isoF cfg d (startDr (s.drain d)) = (cfg.drain d).size := by
    simp [isoF, startDr]
  rw [e1, e2] at h
  show rsum cfg.nd (fun j => isoF cfg j ((setDrain s d _).drain j)) = rsum cfg.nd (fun j => isoF cfg j (s.drain j)) + _
  omega

theorem total_le {cfg : Cfg} {s t : St} (h : ∀ r, (t.run r).running ≤ (s.run r).running) :
    total cfg t ≤ total cfg s := rsum_le (fun r _ => h r)

theorem total_admit {cfg : Cfg} {s : St} {r : Nat} (hr : r < cfg.nr) : total cfg (admit s r) = total cfg s + 1 := by
  have h1 := sum_setRun (fun _ x => x.running) s (admitR s.now (s.run r)) hr
  try dsimp only at h1
  have e1 : (admitR s.now (s.run r)).running = (s.run r).running + 1 := by simp only [admitR, RunSt.running]; omega
  unfold total admit
  omega

/-! ## The invariant -/

structure Inv (cfg : Cfg) (s : St) : Prop where
  here : ∀ r, (s.run r).here = false → (s.run r).pend = 0 ∧ (s.run r).running = 0
  cap : ∀ r, (s.run r).here = true → 1 ≤ (s.run r).cap
  /-- At most `drainMax` CPUs are isolated. -/
  half : iso cfg s ≤ cfg.drainMax
  /-- A started drain has run at most its limit plus grace, and idled at most `idleMax`. -/
  clock : ∀ d, (s.drain d).ph = .started → (s.drain d).age ≤ cfg.limitOf d + cfg.grace ∧ (s.drain d).idle ≤ cfg.idleMax
  /-- The backstop: never more than 4 × the pool running. -/
  tot : total cfg s ≤ 4 * cfg.pool

theorem inv_init (cfg : Cfg) : Inv cfg Contest.init where
  here _ _ := ⟨rfl, rfl⟩
  cap _ h := by cases h
  half := by
    have : iso cfg Contest.init = 0 := rsum_eq_zero.2 (fun d _ => by simp [Contest.init, isoF])
    omega
  clock _ h := by cases h
  tot := by
    have : total cfg Contest.init = 0 := rsum_eq_zero.2 (fun r _ => by simp [Contest.init, RunSt.running])
    omega

theorem inv_pass1 {cfg : Cfg} {s t : St} (i : Inv cfg s) (h : pass1 cfg s = some t) : Inv cfg t := by
  unfold pass1 at h
  split at h
  · rename_i d hd
    cases h
    have hc := List.find?_some hd
    have hm := List.mem_range.1 (List.mem_of_find?_eq_some hd)
    simp only [canDrain, Bool.and_eq_true, decide_eq_true_eq] at hc
    have hw := hc.1.1.1.1
    have hh := hc.1.1.2
    have hiso := iso_startD hm hw
    refine ⟨i.here, i.cap, by omega, fun e he => ?_, i.tot⟩
    by_cases hed : e = d
    · subst hed; simp [startD, startDr]
    · simp only [startD, setDrain_drain, hed, ite_false] at he ⊢; exact i.clock e he
  · cases hf : (List.range cfg.nr).find? (canStart cfg s) with
    | none => rw [hf] at h; cases h
    | some r =>
      rw [hf] at h; cases h
      have hc := List.find?_some hf
      have hm := List.mem_range.1 (List.mem_of_find?_eq_some hf)
      simp only [canStart, eligible, Bool.and_eq_true, decide_eq_true_eq] at hc
      have hhere := hc.1.1.1.1.1
      have htot := hc.1.2
      have hcap : capT cfg s ≤ cfg.pool := Nat.sub_le _ _
      have ht := total_admit (s := s) hm
      refine ⟨fun j hj => ?_, fun j hj => ?_, i.half, i.clock, ?_⟩
      · by_cases hjr : j = r
        · subst hjr; simp [admit, admitR, hhere] at hj
        · simp only [admit, setRun_run, hjr, ite_false] at hj ⊢; exact i.here j hj
      · by_cases hjr : j = r
        · subst hjr; simp only [admit, admitR, setRun_run, ite_true]; exact i.cap j hhere
        · simp only [admit, setRun_run, hjr, ite_false] at hj ⊢; exact i.cap j hj
      · show total cfg (admit s r) ≤ _
        omega

theorem inv_passN {cfg : Cfg} : ∀ (k : Nat) {s : St}, Inv cfg s → Inv cfg (passN cfg k s)
  | 0, _, i => i
  | k + 1, s, i => by
    simp only [passN]
    cases e : pass1 cfg s with
    | none => exact i
    | some t => exact inv_passN k (inv_pass1 i e)

theorem inv_act {cfg : Cfg} {s u : St} {a : Act} (i : Inv cfg s) (h : act cfg s a = some u) : Inv cfg u := by
  -- Most actions touch one run or one drain; each keeps the running counts or lowers them.
  cases a with
  | arrive r =>
    simp only [act] at h; split at h
    · rename_i hc; cases h
      have h0 := i.here r hc.2
      refine ⟨fun j hj => ?_, fun j hj => ?_, i.half, i.clock, ?_⟩
      · by_cases hjr : j = r
        · subst hjr; simp at hj
        · simp only [setRun_run, hjr, ite_false] at hj ⊢; exact i.here j hj
      · by_cases hjr : j = r
        · subst hjr; simp only [setRun_run, ite_true]; omega
        · simp only [setRun_run, hjr, ite_false] at hj ⊢; exact i.cap j hj
      · have : total cfg { setRun s r { here := true, ticket := s.next, pend := (cfg.run r).tasks, cap := max 1 (cfg.run r).cap, last := s.now } with next := s.next + 1 } ≤ total cfg s :=
          total_le (fun j => by
            by_cases hjr : j = r
            · subst hjr; simp [RunSt.running]
            · simp [hjr])
        exact Nat.le_trans this i.tot
    · cases h
  | arriveD d =>
    simp only [act] at h; split at h
    · rename_i hc; cases h
      have hle : iso cfg { setDrain s d { ph := .waiting, ticket := s.next } with next := s.next + 1 } ≤ iso cfg s :=
        iso_le (fun e he => by
          by_cases hed : e = d
          · subst hed; simp at he
          · simpa [hed] using he)
      refine ⟨i.here, i.cap, Nat.le_trans hle i.half, fun e he => ?_, i.tot⟩
      by_cases hed : e = d
      · subst hed; simp at he
      · simp only [setDrain_drain, hed, ite_false] at he ⊢; exact i.clock e he
    · cases h
  | finS r | finC r | finB r | block r | wake r | limit r c =>
    simp only [act] at h; split at h
    · rename_i hc; cases h
      refine ⟨fun j hj => ?_, fun j hj => ?_, i.half, i.clock, ?_⟩
      · by_cases hjr : j = r
        · subst hjr
          have := i.here j
          simp_all [RunSt.running]
        · simp only [setRun_run, hjr, ite_false] at hj ⊢; exact i.here j hj
      · by_cases hjr : j = r
        · subst hjr
          simp only [setRun_run, ite_true] at hj ⊢
          first | exact i.cap _ hj | exact hc.2.2
        · simp only [setRun_run, hjr, ite_false] at hj ⊢; exact i.cap j hj
      · refine Nat.le_trans (total_le (fun j => ?_)) i.tot
        by_cases hjr : j = r
        · subst hjr; simp [RunSt.running] <;> omega
        · simp [hjr]
    · cases h
  | dbusy d b | dend d =>
    simp only [act] at h; split at h
    · rename_i hc; cases h
      have hle : ∀ y : DrainSt, (y.ph = .started → (s.drain d).ph = .started) →
          iso cfg (setDrain s d y) ≤ iso cfg s := fun y hy =>
        iso_le (fun e he => by
          by_cases hed : e = d
          · subst hed; simp at he; exact hy he
          · simpa [hed] using he)
      refine ⟨i.here, i.cap, Nat.le_trans (hle _ (fun _ => hc.2)) i.half,
        fun e he => ?_, i.tot⟩
      by_cases hed : e = d
      · subst hed; simp at he ⊢ <;> exact i.clock e hc.2
      · simp only [setDrain_drain, hed, ite_false] at he ⊢; exact i.clock e he
    · cases h
  | tick =>
    simp only [act] at h; cases h
    have hst : ∀ d, ((tickSt cfg s).drain d).ph = .started → (s.drain d).ph = .started := by
      intro d hd
      simp only [tickSt, tickD] at hd
      split at hd
      · assumption
      · exact hd
    refine ⟨fun j hj => ?_, fun j hj => i.cap j hj, Nat.le_trans (iso_le hst) i.half,
      fun d hd => ?_, ?_⟩
    · have := i.here j hj
      simp only [tickSt, RunSt.running] at this ⊢
      omega
    · simp only [tickSt] at hd ⊢
      obtain ⟨_, _, h3, h4, _⟩ := tickD_started hd
      exact ⟨h3, h4⟩
    · refine Nat.le_trans (total_le (fun j => ?_)) i.tot
      simp [tickSt, RunSt.running]; omega
  | gate b => simp only [act] at h; cases h; exact { i with }
  | load k => simp only [act] at h; cases h; exact { i with }

theorem reach_inv {cfg : Cfg} {s : St} (r : Reach cfg s) : Inv cfg s ∧ pass1 cfg s = none := by
  induction r with
  | init =>
    refine ⟨inv_init cfg, ?_⟩
    cases e : pass1 cfg init with
    | none => rfl
    | some t =>
      have := pass1_work e
      have h0 : work cfg Contest.init = 0 := by
        unfold work
        have a1 : rsum cfg.nr (fun r => (Contest.init.run r).pend) = 0 := rsum_eq_zero.2 (fun _ _ => rfl)
        have a2 : rsum cfg.nd (fun d => isWaiting (Contest.init.drain d)) = 0 :=
          rsum_eq_zero.2 (fun _ _ => by simp [isWaiting, Contest.init])
        omega
      omega
  | step a _ hs ih =>
    unfold step at hs
    cases hu : act cfg _ a with
    | none => rw [hu] at hs; cases hs
    | some u =>
      rw [hu] at hs; cases hs
      exact ⟨inv_passN _ (inv_act ih.1 hu), pass_closed cfg u⟩

/-! ## The line: `head` is the first waiter by share ÷ weight, then ticket -/

theorem pickStep_none_t {p : Nat → Bool} {lt : Nat → Nat → Bool} {i : Nat} (hp : p i = true) :
    pickStep p lt none i = some i := by simp [pickStep, hp]
theorem pickStep_lt {p : Nat → Bool} {lt : Nat → Nat → Bool} {i j : Nat} (hp : p i = true) (h : lt i j = true) :
    pickStep p lt (some j) i = some i := by simp [pickStep, hp, h]
theorem pickStep_nlt {p : Nat → Bool} {lt : Nat → Nat → Bool} {i j : Nat} (h : lt i j = false) :
    pickStep p lt (some j) i = some j := by
  unfold pickStep; cases p i <;> simp [h]
theorem pickStep_f {p : Nat → Bool} {lt : Nat → Nat → Bool} {i : Nat} {acc : Option Nat} (hp : p i = false) :
    pickStep p lt acc i = acc := by simp [pickStep, hp]

theorem foldl_pick_some (p : Nat → Bool) (lt : Nat → Nat → Bool) :
    ∀ (l : List Nat) (acc : Option Nat) (h : Nat), l.foldl (pickStep p lt) acc = some h →
      acc = some h ∨ (h ∈ l ∧ p h = true)
  | [], acc, h, e => Or.inl e
  | i :: l, acc, h, e => by
    simp only [List.foldl_cons] at e
    rcases foldl_pick_some p lt l _ h e with e1 | ⟨hm, hp⟩
    · cases hpi : p i
      · rw [pickStep_f hpi] at e1; exact Or.inl e1
      · cases acc with
        | none => rw [pickStep_none_t hpi] at e1; cases e1; exact Or.inr ⟨List.mem_cons_self, hpi⟩
        | some j =>
          cases hij : lt i j
          · rw [pickStep_nlt hij] at e1; exact Or.inl e1
          · rw [pickStep_lt hpi hij] at e1; cases e1; exact Or.inr ⟨List.mem_cons_self, hpi⟩
    · exact Or.inr ⟨List.mem_cons_of_mem _ hm, hp⟩

theorem foldl_pick_isSome (p : Nat → Bool) (lt : Nat → Nat → Bool) :
    ∀ (l : List Nat) (acc : Option Nat), (acc.isSome = true ∨ ∃ i ∈ l, p i = true) →
      (l.foldl (pickStep p lt) acc).isSome = true
  | [], acc, h => by
    rcases h with h | ⟨i, hi, _⟩
    · exact h
    · simp at hi
  | i :: l, acc, h => by
    simp only [List.foldl_cons]
    apply foldl_pick_isSome p lt l
    cases hpi : p i
    · rw [pickStep_f hpi]
      rcases h with h | ⟨j, hj, hpj⟩
      · exact Or.inl h
      · rcases List.mem_cons.1 hj with rfl | hj
        · rw [hpi] at hpj; cases hpj
        · exact Or.inr ⟨j, hj, hpj⟩
    · left
      cases acc with
      | none => rw [pickStep_none_t hpi]; rfl
      | some j => cases hij : lt i j
                  · rw [pickStep_nlt hij]; rfl
                  · rw [pickStep_lt hpi hij]; rfl

theorem foldl_pick_le (p : Nat → Bool) (lt : Nat → Nat → Bool)
    (tr : ∀ a b c, lt a b = true → lt b c = true → lt a c = true) :
    ∀ (l : List Nat) (j h : Nat), l.foldl (pickStep p lt) (some j) = some h → h = j ∨ lt h j = true
  | [], j, h, e => by cases e; exact Or.inl rfl
  | i :: l, j, h, e => by
    simp only [List.foldl_cons] at e
    cases hpi : p i
    · rw [pickStep_f hpi] at e; exact foldl_pick_le p lt tr l j h e
    · cases hij : lt i j
      · rw [pickStep_nlt hij] at e; exact foldl_pick_le p lt tr l j h e
      · rw [pickStep_lt hpi hij] at e
        rcases foldl_pick_le p lt tr l i h e with rfl | hh
        · exact Or.inr hij
        · exact Or.inr (tr _ _ _ hh hij)

theorem foldl_pick_min (p : Nat → Bool) (lt : Nat → Nat → Bool) (irr : ∀ a, lt a a = false)
    (tr : ∀ a b c, lt a b = true → lt b c = true → lt a c = true) :
    ∀ (l : List Nat) (acc : Option Nat) (h : Nat), l.foldl (pickStep p lt) acc = some h →
      (∀ j, acc = some j → lt j h = false) ∧ ∀ i ∈ l, p i = true → lt i h = false
  | [], acc, h, e => by
    refine ⟨fun j hj => ?_, fun i hi _ => absurd hi List.not_mem_nil⟩
    rw [hj] at e; cases e; exact irr _
  | i :: l, acc, h, e => by
    simp only [List.foldl_cons] at e
    have noCycle : ∀ a b, lt a b = true → lt b a = true → False := fun a b h1 h2 => by
      have := tr _ _ _ h1 h2; rw [irr] at this; cases this
    cases hpi : p i
    · rw [pickStep_f hpi] at e
      have ih := foldl_pick_min p lt irr tr l _ h e
      refine ⟨ih.1, fun i' hi' hp' => ?_⟩
      rcases List.mem_cons.1 hi' with rfl | hi'
      · rw [hpi] at hp'; cases hp'
      · exact ih.2 i' hi' hp'
    · cases acc with
      | none =>
        rw [pickStep_none_t hpi] at e
        have ih := foldl_pick_min p lt irr tr l _ h e
        refine ⟨fun j hj => (nomatch hj), fun i' hi' hp' => ?_⟩
        rcases List.mem_cons.1 hi' with rfl | hi'
        · exact ih.1 _ rfl
        · exact ih.2 i' hi' hp'
      | some j =>
        cases hij : lt i j
        · rw [pickStep_nlt hij] at e
          have ih := foldl_pick_min p lt irr tr l _ h e
          refine ⟨fun j' hj' => (by cases hj'; exact ih.1 _ rfl), fun i' hi' hp' => ?_⟩
          rcases List.mem_cons.1 hi' with rfl | hi'
          · cases hih : lt i' h
            · rfl
            · rcases foldl_pick_le p lt tr l j h e with rfl | hhj
              · rw [hih] at hij; cases hij
              · rw [tr _ _ _ hih hhj] at hij; cases hij
          · exact ih.2 i' hi' hp'
        · rw [pickStep_lt hpi hij] at e
          have ih := foldl_pick_min p lt irr tr l _ h e
          refine ⟨fun j' hj' => ?_, fun i' hi' hp' => ?_⟩
          · cases hj'
            cases hjh : lt j h
            · rfl
            · rcases foldl_pick_le p lt tr l i h e with rfl | hhi
              · exact (noCycle _ _ hij hjh).elim
              · exact (noCycle _ _ hij (tr _ _ _ hjh hhi)).elim
          · rcases List.mem_cons.1 hi' with rfl | hi'
            · exact ih.1 _ rfl
            · exact ih.2 i' hi' hp'

theorem before_irr (cfg : Cfg) (s : St) (a : Nat) : before cfg s a a = false := by
  simp [before]

theorem before_trans (cfg : Cfg) (s : St) (a b c : Nat) :
    before cfg s a b = true → before cfg s b c = true → before cfg s a c = true := by
  simp only [before, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
  omega

theorem head_some {cfg : Cfg} {s : St} {h : Nat} (e : head cfg s = some h) : h < cfg.nr ∧ front cfg s h = true := by
  rcases foldl_pick_some _ _ _ _ h e with e1 | ⟨hm, hp⟩
  · cases e1
  · exact ⟨List.mem_range.1 hm, hp⟩

theorem pbefore_irr (cfg : Cfg) (s : St) (a : Nat) : pbefore cfg s a a = false := by
  simp [pbefore]

theorem pbefore_trans (cfg : Cfg) (s : St) (a b c : Nat) :
    pbefore cfg s a b = true → pbefore cfg s b c = true → pbefore cfg s a c = true := by
  simp only [pbefore, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq]
  omega

/-- Every project with a waiter has a first waiter. -/
theorem first_exists {cfg : Cfg} {s : St} {r : Nat} (hr : r < cfg.nr) (he : eligible s r = true) :
    ∃ h < cfg.nr, (cfg.run h).proj = (cfg.run r).proj ∧ front cfg s h = true := by
  let p : Nat → Bool := fun i => eligible s i && decide ((cfg.run i).proj = (cfg.run r).proj)
  have hs := foldl_pick_isSome p (pbefore cfg s) (List.range cfg.nr) none
    (Or.inr ⟨r, List.mem_range.2 hr, by simp [p, he]⟩)
  obtain ⟨h, e⟩ := Option.isSome_iff_exists.1 hs
  rcases foldl_pick_some _ _ _ _ h e with e1 | ⟨hm, hp⟩
  · cases e1
  have hmin := (foldl_pick_min _ _ (pbefore_irr cfg s) (pbefore_trans cfg s) _ _ h e).2
  simp only [p, Bool.and_eq_true, decide_eq_true_eq] at hp
  refine ⟨h, List.mem_range.1 hm, hp.2, ?_⟩
  simp only [front, projFirst, hp.1, Bool.true_and, Bool.not_eq_true']
  apply anyLT_false.2
  intro i hi
  cases hei : eligible s i
  · rfl
  · by_cases hpi : (cfg.run i).proj = (cfg.run h).proj
    · have := hmin i (List.mem_range.2 hi) (by simp [p, hei, hpi, hp.2])
      simp [hpi, this]
    · simp [hpi]

theorem head_isSome {cfg : Cfg} {s : St} {r : Nat} (hr : r < cfg.nr) (he : eligible s r = true) :
    (head cfg s).isSome = true := by
  obtain ⟨h, hh, _, hf⟩ := first_exists hr he
  exact foldl_pick_isSome _ _ _ _ (Or.inr ⟨h, List.mem_range.2 hh, hf⟩)

/-- The head is first in line: no project's first waiter ranks before it. -/
theorem head_first {cfg : Cfg} {s : St} {h : Nat} (e : head cfg s = some h) :
    ∀ i < cfg.nr, front cfg s i = true → before cfg s i h = false :=
  fun i hi he => (foldl_pick_min _ _ (before_irr cfg s) (before_trans cfg s) _ _ h e).2 i (List.mem_range.2 hi) he

/-- Under share depends only on the project. -/
theorem under_proj {cfg : Cfg} {s : St} {r h : Nat} (hp : (cfg.run h).proj = (cfg.run r).proj) :
    under cfg s h ↔ under cfg s r := by
  unfold under; rw [hp]

theorem before2_irr (cfg : Cfg) (s : St) (a : Nat) : before2 cfg s a a = false := by
  simp [before2, before_irr]

theorem before2_trans (cfg : Cfg) (s : St) (a b c : Nat) :
    before2 cfg s a b = true → before2 cfg s b c = true → before2 cfg s a c = true := by
  intro h1 h2
  have bt := before_trans cfg s a b c
  unfold before2 at *
  cases ha : decide (under cfg s a) <;> cases hb : decide (under cfg s b) <;>
    cases hc : decide (under cfg s c) <;> simp only [ha, hb, hc] at h1 h2 ⊢ <;> simp_all

theorem head2_some {cfg : Cfg} {s : St} {h : Nat} (e : head2 cfg s = some h) : h < cfg.nr ∧ front cfg s h = true := by
  rcases foldl_pick_some _ _ _ _ h e with e1 | ⟨hm, hp⟩
  · cases e1
  · exact ⟨List.mem_range.1 hm, hp⟩

theorem head2_isSome {cfg : Cfg} {s : St} {r : Nat} (hr : r < cfg.nr) (he : eligible s r = true) :
    (head2 cfg s).isSome = true := by
  obtain ⟨h, hh, _, hf⟩ := first_exists hr he
  exact foldl_pick_isSome _ _ _ _ (Or.inr ⟨h, List.mem_range.2 hh, hf⟩)

theorem head2_first {cfg : Cfg} {s : St} {h : Nat} (e : head2 cfg s = some h) :
    ∀ i < cfg.nr, front cfg s i = true → before2 cfg s i h = false :=
  fun i hi he => (foldl_pick_min _ _ (before2_irr cfg s) (before2_trans cfg s) _ _ h e).2 i (List.mem_range.2 hi) he

/-- With `oneLine`, if a project's first waiter is under share, so is the first in the one line. -/
theorem head2_under {cfg : Cfg} {s : St} {h f : Nat} (e : head2 cfg s = some h) (hf : f < cfg.nr)
    (ff : front cfg s f = true) (hu : under cfg s f) : under cfg s h := by
  have := head2_first e f hf ff
  apply Classical.byContradiction; intro hn
  simp [before2, hu, hn] at this

/-! ## In every reachable state nothing that may start waits -/

theorem reach_start {cfg : Cfg} {s : St} (h : Reach cfg s) {r : Nat} (hr : r < cfg.nr) : canStart cfg s r = false :=
  (closed_iff.1 (reach_inv h).2).2 r hr

theorem reach_drain {cfg : Cfg} {s : St} (h : Reach cfg s) {d : Nat} (hd : d < cfg.nd) : canDrain cfg s d = false :=
  (closed_iff.1 (reach_inv h).2).1 d hd

/-- **Property 2, no wait under share.** A run under its fair share with a task waiting and not
held by its `-c` waits only on the gates or the 4T backstop. -/
theorem no_wait_under {cfg : Cfg} {s : St} (h : Reach cfg s) {r : Nat} (hr : r < cfg.nr)
    (he : eligible s r = true) (hu : under cfg s r) :
    s.gate = false ∨ 4 * capT cfg s ≤ total cfg s := by
  obtain ⟨f, hf, hpf, hff⟩ := first_exists hr he
  have hc := reach_start h hf
  have huf : under cfg s f := (under_proj hpf).2 hu
  cases hg : s.gate
  · exact Or.inl rfl
  · right
    apply Classical.byContradiction
    intro hlt
    have hlt' : total cfg s < 4 * capT cfg s := by omega
    cases ho : cfg.rules.oneLine
    · simp only [front, Bool.and_eq_true] at hff
      simp [canStart, hff.1, hff.2, hg, hlt', huf, ho] at hc
    · obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head2_isSome hr he)
      obtain ⟨hxn, hxe⟩ := head2_some hx
      have hxu := head2_under hx hf hff huf
      have hc' := reach_start h hxn
      simp only [front, Bool.and_eq_true] at hxe
      simp [canStart, hxe.1, hxe.2, hg, hlt', hxu, ho, hx] at hc' 

/-- **Property 1, work-conserving** (with busy counting only the CPUs no drain isolates). A
task that waits, not held by the gates, the backstop or its run's `-c`, waits only when its
project is at or over its share and the machine has no room: busy + starting ≥ T − 0.5. -/
theorem work_conserving {cfg : Cfg} {s : St} (h : Reach cfg s) (hb : cfg.rules.busyAll = false)
    {r : Nat} (hr : r < cfg.nr) (he : eligible s r = true) (hg : s.gate = true)
    (ht : total cfg s < 4 * capT cfg s) :
    ¬ under cfg s r ∧ capT cfg s ≤ taskBusy cfg s + s.outside + startingN cfg s := by
  refine ⟨fun hu => ?_, ?_⟩
  · rcases no_wait_under h hr he hu with x | x
    · rw [hg] at x; cases x
    · omega
  · apply Classical.byContradiction
    intro hn
    have hbm : busyM cfg s = taskBusy cfg s + s.outside := by simp [busyM, hb]
    have hroom : room cfg s := by
      unfold room; rw [hbm]; omega
    cases ho : cfg.rules.oneLine
    · obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head_isSome hr he)
      obtain ⟨hxn, hxe⟩ := head_some hx
      simp only [front, Bool.and_eq_true] at hxe
      have hc := reach_start h hxn
      simp [canStart, hxe.1, hxe.2, hg, ht, hroom, hx, ho] at hc
    · obtain ⟨x, hx⟩ := Option.isSome_iff_exists.1 (head2_isSome hr he)
      obtain ⟨hxn, hxe⟩ := head2_some hx
      simp only [front, Bool.and_eq_true] at hxe
      have hc := reach_start h hxn
      simp [canStart, hxe.1, hxe.2, hg, ht, hroom, hx, ho] at hc

/-- **The line.** A run starts a task only as its project's first waiter (no waiter of its
project has fewer tasks running, or as many and an older ticket); over its share, only with room
and first in line among the projects' first waiters (urgent first task, project running ÷
weight, fewer running, ticket). -/
theorem line_order {cfg : Cfg} {s : St} {r : Nat} (hc : canStart cfg s r = true) :
    projFirst cfg s r = true ∧
    (cfg.rules.oneLine = false → ¬ under cfg s r →
      room cfg s ∧ ∀ i < cfg.nr, front cfg s i = true → before cfg s i r = false) ∧
    (cfg.rules.oneLine = true →
      (under cfg s r ∨ room cfg s) ∧ ∀ i < cfg.nr, front cfg s i = true → before2 cfg s i r = false) := by
  simp only [canStart, Bool.and_eq_true] at hc
  refine ⟨hc.2.1, fun ho hu => ?_, fun ho => ?_⟩
  · have h2 := hc.2.2
    simp only [ho, Bool.false_eq_true, ↓reduceIte, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq,
      beq_iff_eq] at h2
    rcases h2 with hu' | ⟨hroom, hh⟩
    · exact absurd hu' hu
    · exact ⟨hroom, head_first hh⟩
  · have h2 := hc.2.2
    simp only [ho, ↓reduceIte, Bool.or_eq_true, Bool.and_eq_true, decide_eq_true_eq, beq_iff_eq] at h2
    exact ⟨h2.2, head2_first h2.1⟩

/-- Within a project: a run never starts a task while a waiter of its project comes before it
(an urgent first task; fewer tasks running; as many and an older last start, a run that never
started first; then ticket), so a run holding nothing goes before a long run of its project, and
a run that has just started a task goes behind the others holding nothing. -/
theorem project_turn {cfg : Cfg} {s : St} {r : Nat} (hc : canStart cfg s r = true) :
    ∀ i < cfg.nr, eligible s i = true → (cfg.run i).proj = (cfg.run r).proj → pbefore cfg s i r = false := by
  have := (line_order hc).1
  simp only [projFirst, Bool.not_eq_true'] at this
  intro i hi he hp
  have := anyLT_false.1 this i hi
  simpa [he, hp] using this

/-- **Property 4, what a drain waits for.** A waiting drain waits only on the gates, the
`drainMax` bound, an older drain that waits, or (with `drainFifo`) an older run that waits holding
nothing. -/
theorem drain_waits_for {cfg : Cfg} {s : St} (h : Reach cfg s) {d : Nat} (hd : d < cfg.nd)
    (hw : (s.drain d).ph = .waiting) :
    s.gate = false ∨ cfg.drainMax < iso cfg s + (cfg.drain d).size ∨ olderDrainWaits cfg s d = true ∨
      (cfg.rules.drainFifo = true ∧ olderEmptyWaits cfg s d = true) := by
  have hc := reach_drain h hd
  cases hg : s.gate
  · exact Or.inl rfl
  · right
    by_cases hp : cfg.drainMax < iso cfg s + (cfg.drain d).size
    · exact Or.inl hp
    · right
      cases ho : olderDrainWaits cfg s d
      · cases hf : cfg.rules.drainFifo <;> cases he : olderEmptyWaits cfg s d <;>
          simp_all [canDrain] <;> omega
      · exact Or.inl rfl

/-! ## Property 5: what is withheld from tasks -/

/-- **Property 5, no idle hold.** The CPUs withheld from tasks are exactly those the started
drains isolate: nothing waiting (a drain or a task) holds a CPU, and at most `drainMax` are
isolated. -/
theorem withheld {cfg : Cfg} {s : St} (h : Reach cfg s) (hD : cfg.drainMax ≤ cfg.pool) :
    cfg.pool - capT cfg s = iso cfg s ∧ iso cfg s ≤ cfg.drainMax := by
  have := (reach_inv h).1.half
  unfold capT; constructor <;> omega

/-- With `drainMax < pool`, the other tasks always keep at least `pool − drainMax ≥ 1` CPUs. -/
theorem capT_pos {cfg : Cfg} {s : St} (h : Reach cfg s) (hD : cfg.drainMax < cfg.pool) :
    cfg.pool - cfg.drainMax ≤ capT cfg s ∧ 0 < capT cfg s := by
  have := (reach_inv h).1.half
  unfold capT; constructor <;> omega

/-- A started drain has been isolated at most its limit plus grace (the limit at most the
ceiling), and its command has idled at most `idleMax` ticks in a row while others wait. -/
theorem drain_clock {cfg : Cfg} {s : St} (h : Reach cfg s) {d : Nat} (hs : (s.drain d).ph = .started) :
    (s.drain d).age ≤ cfg.limitOf d + cfg.grace ∧ cfg.limitOf d ≤ cfg.ceil ∧ (s.drain d).idle ≤ cfg.idleMax := by
  have := (reach_inv h).1.clock d hs
  exact ⟨this.1, Nat.min_le_right _ _, this.2⟩

/-- A drain larger than `drainMax` never starts: the rules must refuse it. -/
theorem big_drain_never {cfg : Cfg} {s : St} (h : Reach cfg s) {d : Nat} (hd : d < cfg.nd)
    (hb : cfg.drainMax < (cfg.drain d).size) : (s.drain d).ph ≠ .started := by
  intro hs
  have h1 := (reach_inv h).1.half
  have h2 : isoF cfg d (s.drain d) ≤ iso cfg s := le_rsum (f := fun j => isoF cfg j (s.drain j)) hd
  simp [isoF, hs] at h2
  omega

/-- A started task is counted as starting (one CPU busy, unmeasured) only until the next tick. -/
theorem tick_settles {cfg : Cfg} {s u : St} (h : act cfg s .tick = some u) : ∀ r, (u.run r).start = 0 := by
  simp only [act, Option.some.injEq] at h; subst h; intro r; rfl


/-! ## What one action does to a run and to a drain -/

def runAfter (cfg : Cfg) (s : St) (a : Act) (r : Nat) : RunSt :=
  match a with
  | .arrive e => if e = r then { here := true, ticket := s.next, pend := (cfg.run r).tasks, cap := max 1 (cfg.run r).cap, last := s.now } else s.run r
  | .finS e => if e = r then { s.run r with start := (s.run r).start - 1 } else s.run r
  | .finC e => if e = r then { s.run r with comp := (s.run r).comp - 1 } else s.run r
  | .finB e => if e = r then { s.run r with blk := (s.run r).blk - 1 } else s.run r
  | .block e => if e = r then { s.run r with comp := (s.run r).comp - 1, blk := (s.run r).blk + 1 } else s.run r
  | .wake e => if e = r then { s.run r with comp := (s.run r).comp + 1, blk := (s.run r).blk - 1 } else s.run r
  | .limit e c => if e = r then { s.run r with cap := c } else s.run r
  | .tick => { s.run r with start := 0, comp := (s.run r).comp + (s.run r).start }
  | _ => s.run r

def drainAfter (cfg : Cfg) (s : St) (a : Act) (d : Nat) : DrainSt :=
  match a with
  | .arriveD e => if e = d then { ph := .waiting, ticket := s.next } else s.drain d
  | .dbusy e b => if e = d then { s.drain d with busy := b } else s.drain d
  | .dend e => if e = d then { s.drain d with ph := .over } else s.drain d
  | .tick => tickD cfg (anyWait cfg s) d (s.drain d)
  | _ => s.drain d

theorem act_run {cfg : Cfg} {s u : St} {a : Act} (h : act cfg s a = some u) (r : Nat) : u.run r = runAfter cfg s a r := by
  cases a with
  | arriveD _ | dbusy _ _ | dend _ => simp only [act] at h; split at h <;> cases h; rfl
  | tick | gate _ | load _ => simp only [act, Option.some.injEq] at h; subst h; rfl
  | arrive e | finS e | finC e | finB e | block e | wake e | limit e _ =>
    simp only [act] at h; split at h
    · cases h
      by_cases hre : r = e
      · subst hre; simp [runAfter]
      · simp [runAfter, hre, Ne.symm hre]
    · cases h

theorem act_drain {cfg : Cfg} {s u : St} {a : Act} (h : act cfg s a = some u) (d : Nat) : u.drain d = drainAfter cfg s a d := by
  cases a with
  | arrive _ | finS _ | finC _ | finB _ | block _ | wake _ | limit _ _ =>
    simp only [act] at h; split at h <;> cases h; rfl
  | tick | gate _ | load _ => simp only [act, Option.some.injEq] at h; subst h; rfl
  | arriveD e | dbusy e _ | dend e =>
    simp only [act] at h; split at h
    · cases h
      by_cases hde : d = e
      · subst hde; simp [drainAfter]
      · simp [drainAfter, hde, Ne.symm hde]
    · cases h

/-! ## The pass as a path of starts -/

inductive PassPath (cfg : Cfg) : St → St → Prop where
  | refl (s : St) : PassPath cfg s s
  | drain {s u : St} (d : Nat) : canDrain cfg s d = true → PassPath cfg (startD s d) u → PassPath cfg s u
  | admit {s u : St} (r : Nat) : canStart cfg s r = true → PassPath cfg (admit s r) u → PassPath cfg s u

theorem pass1_path {cfg : Cfg} {s t u : St} (h : pass1 cfg s = some t) (p : PassPath cfg t u) : PassPath cfg s u := by
  unfold pass1 at h
  split at h
  · rename_i d hd; cases h; exact .drain d (List.find?_some hd) p
  · cases hf : (List.range cfg.nr).find? (canStart cfg s) with
    | none => rw [hf] at h; cases h
    | some r => rw [hf] at h; cases h; exact .admit r (List.find?_some hf) p

theorem passN_path (cfg : Cfg) : ∀ (k : Nat) (s : St), PassPath cfg s (passN cfg k s)
  | 0, s => .refl s
  | k + 1, s => by
    simp only [passN]
    cases e : pass1 cfg s with
    | none => exact .refl s
    | some t => exact pass1_path e (passN_path cfg k t)

theorem pass_path (cfg : Cfg) (s : St) : PassPath cfg s (pass cfg s) := passN_path cfg _ s

/-- The pass only starts: waiting tasks only go down, running only up, tickets and arrivals stay;
a drain only goes from waiting to started, and a drain not waiting is untouched. -/
theorem PassPath.frame {cfg : Cfg} {s u : St} (p : PassPath cfg s u) :
    (∀ r, (u.run r).pend ≤ (s.run r).pend ∧ (s.run r).running ≤ (u.run r).running ∧
      (u.run r).ticket = (s.run r).ticket ∧ (u.run r).here = (s.run r).here) ∧
    (∀ d, (u.drain d).ph = .waiting → (s.drain d).ph = .waiting) ∧
    (∀ d, (s.drain d).ph ≠ .waiting → u.drain d = s.drain d) ∧
    (∀ d, (s.drain d).ph = .started → (u.drain d).ph = .started) ∧
    (∀ d, (u.drain d).ticket = (s.drain d).ticket) := by
  induction p with
  | refl s => exact ⟨fun r => ⟨Nat.le_refl _, Nat.le_refl _, rfl, rfl⟩, fun _ h => h, fun _ _ => rfl, fun _ h => h, fun _ => rfl⟩
  | drain d hc _ ih =>
    obtain ⟨i1, i2, i3, i4, i5⟩ := ih
    simp only [startD, setDrain_run] at i1
    refine ⟨i1, fun e he => ?_, fun e he => ?_, fun e he => ?_, fun e => ?_⟩
    · have := i2 e he
      by_cases hed : e = d
      · subst hed; simp [startD, startDr] at this
      · simpa [startD, hed] using this
    · by_cases hed : e = d
      · subst hed
        simp only [canDrain, Bool.and_eq_true, decide_eq_true_eq] at hc
        exact absurd hc.1.1.1.1 he
      · rw [i3 e (by simpa [startD, hed] using he)]; simp [startD, hed]
    · apply i4
      by_cases hed : e = d
      · subst hed; simp [startD, startDr]
      · simpa [startD, hed] using he
    · rw [i5 e]
      by_cases hed : e = d
      · subst hed; simp [startD, startDr]
      · simp [startD, hed]
  | admit r hc _ ih =>
    obtain ⟨i1, i2, i3, i4, i5⟩ := ih
    simp only [Contest.admit, setRun_drain] at i2 i3 i4 i5
    refine ⟨fun j => ?_, i2, i3, i4, i5⟩
    obtain ⟨j1, j2, j3, j4⟩ := i1 j
    by_cases hjr : j = r
    · subst hjr
      simp only [Contest.admit, admitR, setRun_run, ite_true, RunSt.running] at j1 j2 j3 j4
      simp only [RunSt.running]
      refine ⟨by omega, by omega, j3, j4⟩
    · simp only [Contest.admit, setRun_run, hjr, ite_false] at j1 j2 j3 j4
      exact ⟨j1, j2, j3, j4⟩

/-! ## A measure that only arrivals raise -/

def mF (x : RunSt) : Nat := 2 * x.pend + x.running
def dval (y : DrainSt) : Nat := if y.ph = .waiting then 2 else if y.ph = .started then 1 else 0

def M (cfg : Cfg) (s : St) : Nat := rsum cfg.nr (fun r => mF (s.run r)) + rsum cfg.nd (fun d => dval (s.drain d))

theorem M_pass1 {cfg : Cfg} {s t : St} (h : pass1 cfg s = some t) : M cfg t + 1 = M cfg s := by
  unfold pass1 at h
  split at h
  · rename_i d hd
    cases h
    have hc := List.find?_some hd
    have hm := List.mem_range.1 (List.mem_of_find?_eq_some hd)
    simp only [canDrain, Bool.and_eq_true, decide_eq_true_eq] at hc
    have hw := hc.1.1.1.1
    have h1 := sum_setDrain (fun _ y => dval y) s (startDr (s.drain d)) hm
    have e1 : dval (s.drain d) = 2 := by simp [dval, hw]
    have e2 : dval (startDr (s.drain d)) = 1 := by simp [dval, startDr]
    try dsimp only at h1
    rw [e1, e2] at h1
    unfold M startD
    simp only [setDrain_run]
    omega
  · cases hf : (List.range cfg.nr).find? (canStart cfg s) with
    | none => rw [hf] at h; cases h
    | some r =>
      rw [hf] at h; cases h
      have hc := List.find?_some hf
      have hm := List.mem_range.1 (List.mem_of_find?_eq_some hf)
      simp only [canStart, eligible, Bool.and_eq_true, decide_eq_true_eq] at hc
      have hp := hc.1.1.1.1.2
      have h1 := sum_setRun (fun _ x => mF x) s (admitR s.now (s.run r)) hm
      have e1 : mF (admitR s.now (s.run r)) + 1 = mF (s.run r) := by
        simp only [mF, admitR, RunSt.running]; omega
      try dsimp only at h1
      unfold M admit
      simp only [setRun_drain]
      omega

theorem M_passN {cfg : Cfg} : ∀ (k : Nat) (s : St), M cfg (passN cfg k s) ≤ M cfg s ∧ (M cfg (passN cfg k s) = M cfg s → passN cfg k s = s)
  | 0, s => ⟨Nat.le_refl _, fun _ => rfl⟩
  | k + 1, s => by
    simp only [passN]
    cases e : pass1 cfg s with
    | none => exact ⟨Nat.le_refl _, fun _ => rfl⟩
    | some t =>
      dsimp only
      have h1 := M_pass1 e
      have h2 := (M_passN (cfg := cfg) k t).1
      exact ⟨by omega, fun h => by omega⟩

def Act.arrival : Act → Bool
  | .arrive _ | .arriveD _ => true
  | _ => false

/-- An action that ends a task or a drain. -/
def Act.ends : Act → Bool
  | .finS _ | .finC _ | .finB _ | .dend _ => true
  | _ => false

def Act.isTick : Act → Bool
  | .tick => true
  | _ => false

theorem rsum_lt {n i : Nat} {f g : Nat → Nat} (h : ∀ j < n, f j ≤ g j) (hi : i < n) (hlt : f i < g i) :
    rsum n f < rsum n g := by
  induction n with
  | zero => omega
  | succ n ih =>
    simp only [rsum]
    rcases Nat.lt_succ_iff_lt_or_eq.1 hi with hi | hi
    · have := ih (fun j hj => h j (by omega)) hi; have := h n (by omega); omega
    · subst hi; have := rsum_le (fun j (hj : j < i) => h j (by omega)); omega

theorem act_guard {cfg : Cfg} {s u : St} {a : Act} (h : act cfg s a = some u) :
    match a with
    | .finS r => r < cfg.nr ∧ 0 < (s.run r).start
    | .finC r => r < cfg.nr ∧ 0 < (s.run r).comp
    | .finB r => r < cfg.nr ∧ 0 < (s.run r).blk
    | .dend d => d < cfg.nd ∧ (s.drain d).ph = .started
    | .arriveD d => d < cfg.nd ∧ (s.drain d).ph = .absent
    | .arrive r => r < cfg.nr ∧ (s.run r).here = false
    | .block r => r < cfg.nr ∧ 0 < (s.run r).comp
    | .wake r => r < cfg.nr ∧ 0 < (s.run r).blk
    | _ => True := by
  cases a <;> simp only [act] at h <;> (try split at h) <;> (try cases h) <;> trivial

theorem M_act {cfg : Cfg} {s u : St} {a : Act} (ha : a.arrival = false) (h : act cfg s a = some u) :
    M cfg u ≤ M cfg s ∧ (a.ends = true → M cfg u < M cfg s) ∧
      (a.isTick = true → M cfg u = M cfg s → ∀ d < cfg.nd, (s.drain d).ph = .started → (u.drain d).ph = .started) := by
  have hg := act_guard h
  have hrun : ∀ r < cfg.nr, mF (u.run r) ≤ mF (s.run r) := by
    intro r _
    rw [act_run h r]
    cases a with
    | arrive _ | arriveD _ => simp [Act.arrival] at ha
    | finS e | finC e | finB e | block e | wake e | limit e _ =>
      simp only [runAfter]; split
      · rename_i her; subst her; dsimp only at hg; simp only [mF, RunSt.running]; omega
      · exact Nat.le_refl _
    | tick => simp only [runAfter, mF, RunSt.running]; omega
    | _ => exact Nat.le_refl _
  have hdr : ∀ d < cfg.nd, dval (u.drain d) ≤ dval (s.drain d) := by
    intro d _
    rw [act_drain h d]
    cases a with
    | arriveD _ => simp [Act.arrival] at ha
    | dbusy e b => simp only [drainAfter]; split <;> simp [dval]
    | dend e => simp only [drainAfter]; split <;> simp [dval]
    | tick =>
      simp only [drainAfter]
      rcases tickD_ph cfg (anyWait cfg s) d (s.drain d) with e | e
      · simp only [dval, e]; exact Nat.le_refl _
      · simp only [dval, e]; simp
    | _ => exact Nat.le_refl _
  have hle : M cfg u ≤ M cfg s := by
    unfold M; have := rsum_le hrun; have := rsum_le hdr; omega
  refine ⟨hle, fun he => ?_, fun ht he d hd hs => ?_⟩
  · have hr2 := rsum_le hrun
    have hd2 := rsum_le hdr
    cases a with
    | finS r | finC r | finB r =>
      dsimp only at hg
      have hlt : mF (u.run r) < mF (s.run r) := by
        rw [act_run h r]; simp only [runAfter, ite_true, mF, RunSt.running]; omega
      have := rsum_lt hrun hg.1 hlt
      unfold M; omega
    | dend d =>
      dsimp only at hg
      have hlt : dval (u.drain d) < dval (s.drain d) := by
        rw [act_drain h d]; simp [drainAfter, dval, hg.2]
      have := rsum_lt hdr hg.1 hlt
      unfold M; omega
    | _ => simp [Act.ends] at he
  · cases a <;> simp [Act.isTick] at ht
    have hr2 := rsum_le hrun
    have hd2 := rsum_le hdr
    have heq : rsum cfg.nd (fun d => dval (u.drain d)) = rsum cfg.nd (fun d => dval (s.drain d)) := by
      unfold M at he; omega
    have := rsum_le_eq hdr heq d hd
    rw [act_drain h d] at this ⊢
    simp only [drainAfter] at this ⊢
    rcases tickD_ph cfg (anyWait cfg s) d (s.drain d) with e | e
    · rw [e]; exact hs
    · simp [dval, e, hs] at this

theorem M_step {cfg : Cfg} {s t : St} {a : Act} (ha : a.arrival = false) (h : step cfg s a = some t) :
    M cfg t ≤ M cfg s ∧ (M cfg t = M cfg s → act cfg s a = some t ∧ a.ends = false ∧
      (a.isTick = true → ∀ d < cfg.nd, (s.drain d).ph = .started → (t.drain d).ph = .started)) := by
  unfold step at h
  cases hu : act cfg s a with
  | none => rw [hu] at h; cases h
  | some u =>
    rw [hu] at h; cases h
    obtain ⟨m1, m2, m3⟩ := M_act ha hu
    obtain ⟨p1, p2⟩ := M_passN (work cfg u) u
    refine ⟨Nat.le_trans p1 m1, fun e => ?_⟩
    have e1 : M cfg (pass cfg u) = M cfg u := by unfold pass at e ⊢; omega
    have e2 : pass cfg u = u := p2 e1
    rw [e2] at e ⊢
    refine ⟨rfl, ?_, fun ht => m3 ht e⟩
    cases hen : a.ends
    · rfl
    · have := m2 hen; omega

/-! ## Runs -/

structure Run (cfg : Cfg) where
  st : Nat → St
  act : Nat → Act
  start : Reach cfg (st 0)
  steps : ∀ n, step cfg (st n) (act n) = some (st (n + 1))

theorem Run.reach {cfg : Cfg} (ρ : Run cfg) : ∀ n, Reach cfg (ρ.st n)
  | 0 => ρ.start
  | n + 1 => .step _ (ρ.reach n) (ρ.steps n)

/-- Nothing waits: every task of every run that arrived has started, and every drain that
arrived has started. -/
def Quiet (cfg : Cfg) (s : St) : Prop :=
  (∀ r < cfg.nr, (s.run r).pend = 0) ∧ ∀ d < cfg.nd, (s.drain d).ph ≠ .waiting

/-- `a` ends a task of run `r`. -/
def finOf (r : Nat) : Act → Prop
  | .finS x | .finC x | .finB x => x = r
  | _ => False

theorem finOf_ends {r : Nat} {a : Act} (h : finOf r a) : a.ends = true := by
  cases a <;> simp_all [finOf, Act.ends]

theorem mono_le (f : Nat → Nat) (n0 : Nat) (h : ∀ n ≥ n0, f (n + 1) ≤ f n) : ∀ n ≥ n0, ∀ k, f (n + k) ≤ f n := by
  intro n hn k
  induction k with
  | zero => exact Nat.le_refl _
  | succ k ih => exact Nat.le_trans (h (n + k) (by omega)) ih

theorem eventually_const (f : Nat → Nat) (n0 : Nat) (h : ∀ n ≥ n0, f (n + 1) ≤ f n) :
    ∃ n1 ≥ n0, ∀ m ≥ n1, f m = f n1 := by
  have key : ∀ v n, n ≥ n0 → f n = v → ∃ n1 ≥ n0, ∀ m ≥ n1, f m = f n1 := by
    intro v
    induction v using Nat.strongRecOn with
    | _ v ih =>
      intro n hn hv
      by_cases hc : ∀ m ≥ n, f m = f n
      · exact ⟨n, hn, hc⟩
      · have : ∃ m ≥ n, f m ≠ f n := by
          apply Classical.byContradiction
          intro hx; apply hc; intro m hm
          apply Classical.byContradiction; intro hne; exact hx ⟨m, hm, hne⟩
        obtain ⟨m, hm, hne⟩ := this
        have hle := mono_le f n0 h n hn (m - n)
        rw [show n + (m - n) = m by omega] at hle
        exact ih (f m) (by omega) m (by omega) rfl
  exact key _ n0 (Nat.le_refl _) rfl

/-- After a calm point, a step that keeps the measure keeps a started drain started, and a
tick ages it by one. -/
theorem step_keeps {cfg : Cfg} {s t : St} {a : Act} (ha : a.arrival = false) (hs : step cfg s a = some t)
    (e : M cfg t = M cfg s) {d : Nat} (hd : d < cfg.nd) (hst : (s.drain d).ph = .started) :
    (t.drain d).ph = .started ∧ (t.drain d).age = (s.drain d).age + (if a.isTick then 1 else 0) := by
  obtain ⟨_, hk⟩ := M_step ha hs
  obtain ⟨hu, hen, htk⟩ := hk e
  have hdr := act_drain hu d
  cases a with
  | tick =>
    have h1 := htk rfl d hd hst
    refine ⟨h1, ?_⟩
    rw [hdr] at h1 ⊢
    simp only [drainAfter, Act.isTick, ite_true] at h1 ⊢
    unfold tickD at h1 ⊢
    rw [ite_t hst] at h1 ⊢
    split
    · rename_i hk; rw [ite_t hk] at h1; simp at h1
    · rfl
  | dend e => simp [Act.ends] at hen
  | arriveD e =>
    simp [Act.arrival] at ha
  | dbusy e b =>
    rw [hdr]; simp only [drainAfter, Act.isTick]
    split
    · simp [hst]
    · simp [hst]
  | _ =>
    rw [hdr]; simp [drainAfter, Act.isTick, hst]

/-- **Property 3, no starvation.** From a time after which nothing arrives, if every task ends
(every run holding a running task later sees one of them end), the gates are open again and
again, and time keeps passing, then from some time on nothing waits: every task and every
drain has started. Drains no larger than `drainMax`. -/
theorem no_starvation {cfg : Cfg} (hp : 0 < cfg.pool)
    (hsz : ∀ d < cfg.nd, (cfg.drain d).size ≤ cfg.drainMax)
    (ρ : Run cfg) (n0 : Nat) (calm : ∀ n ≥ n0, (ρ.act n).arrival = false)
    (ends : ∀ n r, r < cfg.nr → 0 < ((ρ.st n).run r).running → ∃ m ≥ n, finOf r (ρ.act m))
    (gates : ∀ n, ∃ m ≥ n, (ρ.st m).gate = true)
    (time : ∀ n, ∃ m ≥ n, ρ.act m = .tick) :
    ∃ n, ∀ m ≥ n, Quiet cfg (ρ.st m) := by
  have mono : ∀ n ≥ n0, M cfg (ρ.st (n + 1)) ≤ M cfg (ρ.st n) :=
    fun n hn => (M_step (calm n hn) (ρ.steps n)).1
  obtain ⟨n1, hn1, hc⟩ := eventually_const (fun n => M cfg (ρ.st n)) n0 mono
  have const : ∀ m ≥ n1, M cfg (ρ.st (m + 1)) = M cfg (ρ.st m) := by
    intro m hm; rw [hc m hm, hc (m + 1) (by omega)]
  have quietStep : ∀ m ≥ n1, act cfg (ρ.st m) (ρ.act m) = some (ρ.st (m + 1)) ∧ (ρ.act m).ends = false :=
    fun m hm => by
      obtain ⟨_, hk⟩ := M_step (calm m (by omega)) (ρ.steps m)
      obtain ⟨h1, h2, _⟩ := hk (const m hm)
      exact ⟨h1, h2⟩
  -- (A) nothing runs
  have noRun : ∀ m ≥ n1, ∀ r < cfg.nr, ((ρ.st m).run r).running = 0 := by
    intro m hm r hr
    apply Classical.byContradiction; intro hne
    obtain ⟨k, hk, hf⟩ := ends m r hr (by omega)
    have := (quietStep k (by omega)).2
    rw [finOf_ends hf] at this; cases this
  -- (B) no drain is isolated
  have noIso : ∀ m ≥ n1, ∀ d < cfg.nd, ((ρ.st m).drain d).ph ≠ .started := by
    intro m hm d hd hs
    have stay : ∀ j, ((ρ.st (m + j)).drain d).ph = .started := by
      intro j
      induction j with
      | zero => exact hs
      | succ j ih =>
        exact (step_keeps (calm (m + j) (by omega)) (ρ.steps (m + j)) (const (m + j) (by omega)) hd ih).1
    have ageStep : ∀ j, ((ρ.st (m + j + 1)).drain d).age =
        ((ρ.st (m + j)).drain d).age + (if (ρ.act (m + j)).isTick then 1 else 0) := fun j =>
      (step_keeps (calm (m + j) (by omega)) (ρ.steps (m + j)) (const (m + j) (by omega)) hd (stay j)).2
    have ageMono : ∀ j k, ((ρ.st (m + j)).drain d).age ≤ ((ρ.st (m + j + k)).drain d).age := by
      intro j k
      induction k with
      | zero => exact Nat.le_refl _
      | succ k ih =>
        have := ageStep (j + k)
        rw [show m + (j + k) = m + j + k by omega] at this
        rw [show m + j + (k + 1) = m + j + k + 1 by omega, this]
        omega
    have grow : ∀ k, ∃ j, k ≤ ((ρ.st (m + j)).drain d).age := by
      intro k
      induction k with
      | zero => exact ⟨0, Nat.zero_le _⟩
      | succ k ih =>
        obtain ⟨j, hj⟩ := ih
        obtain ⟨t, ht, htk⟩ := time (m + j)
        have h1 := ageStep (t - m)
        rw [show m + (t - m) = t by omega, htk] at h1
        simp only [Act.isTick, ite_true] at h1
        have h2 := ageMono j (t - m - j)
        rw [show m + j + (t - m - j) = t by omega] at h2
        exact ⟨t - m + 1, by rw [show m + (t - m + 1) = t + 1 by omega, h1]; omega⟩
    obtain ⟨j, hj⟩ := grow (cfg.limitOf d + cfg.grace + 1)
    have := (drain_clock (ρ.reach (m + j)) (stay j)).1
    omega
  -- (C) with the gates open, the closed state starts whatever waits
  obtain ⟨m, hm, hg⟩ := gates n1
  have hiso : iso cfg (ρ.st m) = 0 :=
    rsum_eq_zero.2 (fun d hd => by simp [isoF, noIso m hm d hd])
  have htot : total cfg (ρ.st m) = 0 := rsum_eq_zero.2 (fun r hr => noRun m hm r hr)
  have hcap : capT cfg (ρ.st m) = cfg.pool := by unfold capT; omega
  have inv := (reach_inv (ρ.reach m)).1
  have qm : Quiet cfg (ρ.st m) := by
    have pend0 : ∀ r < cfg.nr, ((ρ.st m).run r).pend = 0 := by
      intro r hr
      apply Classical.byContradiction; intro hne
      have hhere : ((ρ.st m).run r).here = true := by
        cases hh : ((ρ.st m).run r).here
        · exact absurd (inv.here r hh).1 hne
        · rfl
      have hcp := inv.cap r hhere
      have hel : eligible (ρ.st m) r = true := by
        simp [eligible, hhere, noRun m hm r hr]; omega
      have hpr : projRun cfg (ρ.st m) (cfg.run r).proj = 0 :=
        rsum_eq_zero.2 (fun j hj => by simp [noRun m hm j hj])
      have hu : under cfg (ρ.st m) r := by
        unfold under; rw [hpr, hcap]; simp only [Nat.zero_mul]
        exact Nat.mul_pos hp (Cfg.w_pos _ _)
      rcases no_wait_under (ρ.reach m) hr hel hu with x | x
      · rw [hg] at x; cases x
      · rw [htot, hcap] at x; omega
    refine ⟨pend0, fun d hd hw => ?_⟩
    obtain ⟨e, ⟨he, hew⟩, hmin⟩ := exists_min (fun e => e < cfg.nd ∧ ((ρ.st m).drain e).ph = .waiting)
      (fun e => ((ρ.st m).drain e).ticket) ⟨d, hd, hw⟩
    have hc := reach_drain (ρ.reach m) he
    have ho : olderDrainWaits cfg (ρ.st m) e = false := anyLT_false.2 (fun x hx => by
      have := hmin x
      cases hxw : decide (((ρ.st m).drain x).ph = .waiting) <;> simp_all <;> omega)
    have hoe : olderEmptyWaits cfg (ρ.st m) e = false := anyLT_false.2 (fun x hx => by
      simp [emptyWaiter, pend0 x hx])
    have hs := hsz e he
    simp [canDrain, hew, hg, hiso, ho, hoe, hs] at hc
  -- nothing waits from then on
  have all : ∀ j, Quiet cfg (ρ.st (m + j)) := by
    intro j
    induction j with
    | zero => exact qm
    | succ j ih =>
    have hs := ρ.steps (m + j)
    have hna := calm (m + j) (by omega)
    show Quiet cfg (ρ.st (m + j + 1))
    revert hs hna ih
    generalize m + j = k
    intro ih hs hna
    unfold step at hs
    cases hu : act cfg (ρ.st k) (ρ.act k) with
    | none => rw [hu] at hs; cases hs
    | some u =>
      rw [hu] at hs
      rw [← Option.some.inj hs]
      have fr := (pass_path cfg u).frame
      refine ⟨fun r hr => ?_, fun d hd hw => ?_⟩
      · have h1 := (fr.1 r).1
        have h2 : (u.run r).pend ≤ ((ρ.st k).run r).pend := by
          rw [act_run hu r]
          cases ha : ρ.act k <;> rw [ha] at hna <;> simp only [Act.arrival] at hna <;>
            (try (exfalso; exact Bool.false_ne_true hna.symm)) <;>
            simp only [runAfter] <;> (try split) <;> simp
        have := ih.1 r hr
        omega
      · have h1 := fr.2.1 d hw
        rw [act_drain hu d] at h1
        apply ih.2 d hd
        cases ha : ρ.act k <;> rw [ha] at hna h1 <;> simp only [Act.arrival] at hna <;>
          (try (exfalso; exact Bool.false_ne_true hna.symm)) <;>
          simp only [drainAfter] at h1
        all_goals first
          | exact h1
          | (split at h1 <;> simp_all)
          | (unfold tickD at h1; split at h1 <;> (try split at h1) <;> simp_all)

  refine ⟨m, fun k hk => ?_⟩
  have := all (k - m)
  rwa [show m + (k - m) = k by omega] at this

/-! ## Property 4: a drain passes no older waiter; its isolation is bounded -/

/-- Along the pass, a drain starts only after every older run that waited holding nothing has
started a task, and every older drain that waited has started. -/
theorem PassPath.fifo {cfg : Cfg} (hf : cfg.rules.drainFifo = true) {s u : St} (p : PassPath cfg s u)
    {d : Nat} (hw : (s.drain d).ph = .waiting) (hs : (u.drain d).ph = .started) :
    (∀ r < cfg.nr, emptyWaiter s r = true → (s.run r).ticket < (s.drain d).ticket → 0 < (u.run r).running) ∧
    (∀ e < cfg.nd, (s.drain e).ph = .waiting → (s.drain e).ticket < (s.drain d).ticket → (u.drain e).ph = .started) := by
  induction p with
  | refl _ => rw [hw] at hs; cases hs
  | @drain s' u' e hc p ih =>
    by_cases hed : e = d
    · subst hed
      simp only [canDrain, Bool.and_eq_true, Bool.not_eq_true', decide_eq_true_eq, hf, Bool.true_and] at hc
      obtain ⟨⟨_, ho⟩, hoe⟩ := hc
      refine ⟨fun r hr he ht => ?_, fun e' he' hw' ht' => ?_⟩
      · have : olderEmptyWaits cfg s' e = true := anyLT_iff.2 ⟨r, hr, by simp [he, ht]⟩
        rw [this] at hoe; cases hoe
      · have : olderDrainWaits cfg s' e = true := anyLT_iff.2 ⟨e', he', by simp [hw', ht']⟩
        rw [this] at ho; cases ho
    · have hw2 : ((startD s' e).drain d).ph = .waiting := by simp [startD, Ne.symm hed, hw]
      obtain ⟨i1, i2⟩ := ih hw2 hs
      have fr := p.frame
      refine ⟨fun r hr he ht => i1 r hr he (by simpa [startD, Ne.symm hed] using ht), fun e' he' hw' ht' => ?_⟩
      by_cases hee : e' = e
      · subst hee; exact fr.2.2.2.1 e' (by simp [startD, startDr])
      · exact i2 e' he' (by simpa [startD, hee] using hw') (by simpa [startD, hee, Ne.symm hed] using ht')
  | @admit s' u' r' hc p ih =>
    obtain ⟨i1, i2⟩ := ih hw hs
    have fr := p.frame
    refine ⟨fun r hr he ht => ?_, i2⟩
    by_cases hrr : r = r'
    · subst hrr
      have := (fr.1 r).2.1
      simp only [Contest.admit, admitR, setRun_run, ite_true, RunSt.running] at this
      simp only [RunSt.running]; omega
    · exact i1 r hr (by simpa [emptyWaiter, Contest.admit, hrr] using he) (by simpa [Contest.admit, hrr] using ht)

/-- **Property 4, FIFO** (with `drainFifo`). In a move whose pass starts drain `d`, every run
older than `d` that waited holding nothing has started a task, and every older drain that waited
has started. -/
theorem drain_no_pass {cfg : Cfg} (hf : cfg.rules.drainFifo = true) {s t u : St} {a : Act}
    (hu : act cfg s a = some u) (ht : step cfg s a = some t) {d : Nat}
    (hw : (u.drain d).ph = .waiting) (hs : (t.drain d).ph = .started) :
    (∀ r < cfg.nr, emptyWaiter u r = true → (u.run r).ticket < (u.drain d).ticket → 0 < (t.run r).running) ∧
    (∀ e < cfg.nd, (u.drain e).ph = .waiting → (u.drain e).ticket < (u.drain d).ticket → (t.drain e).ph = .started) := by
  unfold step at ht; rw [hu] at ht; cases ht
  exact (pass_path cfg u).fifo hf hw hs

/-- What one action does to a started drain: it stays started, a tick ages it by one and sets
its idle count, other actions keep both; or it is over. -/
theorem act_started {cfg : Cfg} {s u : St} {a : Act} (h : act cfg s a = some u) {d : Nat}
    (hs : (s.drain d).ph = .started) :
    ((u.drain d).ph = .started ∧ (u.drain d).age = (s.drain d).age + (if a.isTick then 1 else 0) ∧
      (u.drain d).idle = (if a.isTick then idleNext (anyWait cfg s) (s.drain d) else (s.drain d).idle)) ∨
    (u.drain d).ph = .over := by
  have hg := act_guard h
  rw [act_drain h d]
  cases a with
  | arriveD e =>
    dsimp only at hg
    simp only [drainAfter]; split
    · rename_i hed; subst hed; rw [hs] at hg; cases hg.2
    · exact Or.inl ⟨hs, by simp [Act.isTick], by simp [Act.isTick]⟩
  | dbusy e b =>
    simp only [drainAfter]; split
    · exact Or.inl ⟨hs, by simp [Act.isTick], by simp [Act.isTick]⟩
    · exact Or.inl ⟨hs, by simp [Act.isTick], by simp [Act.isTick]⟩
  | dend e =>
    simp only [drainAfter]; split
    · exact Or.inr rfl
    · exact Or.inl ⟨hs, by simp [Act.isTick], by simp [Act.isTick]⟩
  | tick =>
    simp only [drainAfter, Act.isTick, ite_true]
    rcases tickD_ph cfg (anyWait cfg s) d (s.drain d) with e | e
    · rw [hs] at e
      obtain ⟨_, h2, _⟩ := tickD_started e
      refine Or.inl ⟨e, h2, ?_⟩
      unfold tickD; rw [ite_t hs]
      unfold tickD at e; rw [ite_t hs] at e
      split
      · rename_i ho; rw [ite_t ho] at e; cases e
      · rfl
    · exact Or.inr e
  | _ => exact Or.inl ⟨hs, by simp [drainAfter, Act.isTick], by simp [drainAfter, Act.isTick]⟩

theorem step_started {cfg : Cfg} {s t : St} {a : Act} (h : step cfg s a = some t) {d : Nat}
    (h1 : (s.drain d).ph = .started) (h2 : (t.drain d).ph = .started) :
    (t.drain d).age = (s.drain d).age + (if a.isTick then 1 else 0) ∧
    (t.drain d).idle = (if a.isTick then idleNext (anyWait cfg s) (s.drain d) else (s.drain d).idle) := by
  unfold step at h
  cases hu : act cfg s a with
  | none => rw [hu] at h; cases h
  | some u =>
    rw [hu] at h; cases h
    have fr := (pass_path cfg u).frame
    rcases act_started hu h1 with ⟨e1, e2, e3⟩ | e1
    · rw [fr.2.2.1 d (by rw [e1]; simp)]; exact ⟨e2, e3⟩
    · rw [fr.2.2.1 d (by rw [e1]; simp), e1] at h2; cases h2

/-- The ticks among the actions `n … n+k-1` of a run. -/
def ticks {cfg : Cfg} (ρ : Run cfg) (n : Nat) : Nat → Nat
  | 0 => 0
  | k + 1 => ticks ρ n k + (if (ρ.act (n + k)).isTick then 1 else 0)

/-- **Property 4, the isolation is bounded.** Through any stretch of a run in which drain `d`
stays started, at most its limit plus grace ticks pass (its limit at most the ceiling). -/
theorem hold_bound {cfg : Cfg} (ρ : Run cfg) {d : Nat} (n k : Nat)
    (h : ∀ j ≤ k, ((ρ.st (n + j)).drain d).ph = .started) :
    ticks ρ n k ≤ cfg.limitOf d + cfg.grace ∧ cfg.limitOf d ≤ cfg.ceil := by
  have grow : ∀ j ≤ k, ticks ρ n j ≤ ((ρ.st (n + j)).drain d).age := by
    intro j hj
    induction j with
    | zero => exact Nat.zero_le _
    | succ j ih =>
      have := (step_started (ρ.steps (n + j)) (h j (by omega)) (h (j + 1) hj)).1
      simp only [ticks]
      rw [show n + (j + 1) = n + j + 1 by omega, this]
      have := ih (by omega)
      omega
  have hc := drain_clock (ρ.reach (n + k)) (h k (Nat.le_refl _))
  exact ⟨Nat.le_trans (grow k (Nat.le_refl _)) hc.1, hc.2.1⟩

/-- **Property 5, idle isolation is bounded.** Through any stretch in which drain `d` stays
started and at every tick its command idles while something waits, at most `idleMax` ticks pass
before the idle stop ends it. -/
theorem idle_bound {cfg : Cfg} (ρ : Run cfg) {d : Nat} (n k : Nat)
    (h : ∀ j ≤ k, ((ρ.st (n + j)).drain d).ph = .started)
    (hi : ∀ j < k, (ρ.act (n + j)).isTick = true →
      ((ρ.st (n + j)).drain d).busy = false ∧ anyWait cfg (ρ.st (n + j)) = true) :
    ticks ρ n k ≤ cfg.idleMax := by
  have grow : ∀ j ≤ k, ticks ρ n j ≤ ((ρ.st (n + j)).drain d).idle := by
    intro j hj
    induction j with
    | zero => exact Nat.zero_le _
    | succ j ih =>
      have := (step_started (ρ.steps (n + j)) (h j (by omega)) (h (j + 1) hj)).2
      simp only [ticks]
      rw [show n + (j + 1) = n + j + 1 by omega, this]
      have := ih (by omega)
      cases htk : (ρ.act (n + j)).isTick
      · simp only [ite_false, Bool.false_eq_true]; omega
      · obtain ⟨hb, hw⟩ := hi j (by omega) htk
        simp only [ite_true, idleNext, hb, hw, Bool.not_false, Bool.and_self]; omega
  exact Nat.le_trans (grow k (Nat.le_refl _)) (drain_clock (ρ.reach (n + k)) (h k (Nat.le_refl _))).2.2

/-! ## Counterexamples: the design as written -/

def runTrace (cfg : Cfg) : St → List Act → Option St
  | s, [] => some s
  | s, a :: as => (step cfg s a).bind (runTrace cfg · as)

theorem runTrace_reach {cfg : Cfg} : ∀ {s t : St} (as : List Act), Reach cfg s → runTrace cfg s as = some t → Reach cfg t
  | _, _, [], r, e => by simp only [runTrace, Option.some.injEq] at e; subst e; exact r
  | s, _, a :: as, r, e => by
    simp only [runTrace] at e
    cases hm : step cfg s a with
    | none => rw [hm] at e; cases e
    | some u => rw [hm] at e; exact runTrace_reach as (.step a r hm) e

/-- The state a trace from the start reaches (the start if an action is not enabled). -/
def final (cfg : Cfg) (as : List Act) : St := (runTrace cfg init as).getD init

theorem final_reach {cfg : Cfg} {as : List Act} (h : (runTrace cfg init as).isSome = true) :
    Reach cfg (final cfg as) := by
  obtain ⟨t, ht⟩ := Option.isSome_iff_exists.1 h
  have : final cfg as = t := by simp [final, ht]
  rw [this]; exact runTrace_reach as .init ht

/-- 2 CPUs, a `-c 1` drain, then a two-task run. -/
def busyCfg (r : Rules) : Cfg :=
  { pool := 2, runs := [{ proj := 0, tasks := 2, cap := 2 }], drains := [{ size := 1, limit := 3 }], rules := r }

/-- The drain starts (its command computes), the run's first task starts and then waits on I/O. -/
def busyTrace : List Act := [.arriveD 0, .arrive 0, .tick, .block 0]

/-- **Property 1 fails as written.** With busy measured over the whole machine, the drain's own
command counts against the capacity that already excludes its CPU: the run's second task waits
while a CPU no drain isolates is idle (busy + starting + 1 ≤ T). -/
theorem design_not_work_conserving :
    ∃ s, Reach (busyCfg .design) s ∧ eligible s 0 = true ∧ s.gate = true ∧
      total (busyCfg .design) s < 4 * capT (busyCfg .design) s ∧
      taskBusy (busyCfg .design) s + s.outside + startingN (busyCfg .design) s + 1 ≤ capT (busyCfg .design) s :=
  ⟨final _ busyTrace, final_reach (by decide), by decide⟩

/-- With busy over the CPUs no drain isolates, the second task starts. -/
theorem fixed_busy_starts : ((final (busyCfg .fixed) busyTrace).run 0).pend = 0 := by decide

/-- 2 CPUs: a two-task run, a later one-task run of the same project, then a `-c 1` drain. -/
def fifoCfg (r : Rules) : Cfg :=
  { pool := 2, runs := [{ proj := 0, tasks := 2, cap := 2 }, { proj := 0, tasks := 1, cap := 1 }],
    drains := [{ size := 1, limit := 3 }], rules := r }

def fifoTrace : List Act := [.arrive 0, .tick, .arrive 1, .arriveD 0]

/-- **Property 4 fails as written.** A drain that waits only for older drains and the `drainMax`
bound starts ahead of an older run that waits holding nothing. -/
theorem design_drain_passes :
    ∃ s, Reach (fifoCfg .design) s ∧ (s.drain 0).ph = .started ∧ emptyWaiter s 1 = true ∧
      (s.run 1).ticket < (s.drain 0).ticket :=
  ⟨final _ fifoTrace, final_reach (by decide), by decide⟩

/-- With `drainFifo` the drain waits for it. -/
theorem fixed_drain_waits : ((final (fifoCfg .fixed) fifoTrace).drain 0).ph = .waiting := by decide

/-- 1 CPU: a five-task run, then a one-task run of another project. -/
def backstopCfg : Cfg :=
  { pool := 1, runs := [{ proj := 0, tasks := 5, cap := 5 }, { proj := 1, tasks := 1, cap := 1 }] }

/-- Each started task waits on I/O, so there is room and the next starts, until 4 run. -/
def backstopTrace : List Act :=
  [.arrive 0, .tick, .block 0, .tick, .block 0, .tick, .block 0, .tick, .block 0, .arrive 1]

/-- **Property 2 needs the backstop named.** A run under its share, gates open, not held by its
`-c`, waits: 4T tasks run (all waiting on I/O). Under the rules this is the only other thing it
can wait on (`no_wait_under`). -/
theorem backstop_blocks_under :
    ∃ s, Reach backstopCfg s ∧ eligible s 1 = true ∧ under backstopCfg s 1 ∧ s.gate = true ∧
      4 * capT backstopCfg s ≤ total backstopCfg s :=
  ⟨final _ backstopTrace, final_reach (by decide), by decide⟩

/-! ## Arrivals are finite here: no-starvation needs no calm point -/

/-- Runs and drains yet to arrive. -/
def toArrive (cfg : Cfg) (s : St) : Nat :=
  rsum cfg.nr (fun r => if (s.run r).here then 0 else 1) +
    rsum cfg.nd (fun d => if (s.drain d).ph = .absent then 1 else 0)

theorem PassPath.waiting {cfg : Cfg} {s u : St} (p : PassPath cfg s u) {d : Nat}
    (hw : (s.drain d).ph = .waiting) : (u.drain d).ph = .waiting ∨ (u.drain d).ph = .started := by
  induction p with
  | refl => exact Or.inl hw
  | drain e _ p ih =>
    by_cases h' : d = e
    · subst h'; exact Or.inr (p.frame.2.2.2.1 d (by simp [startD, startDr]))
    · exact ih (by simpa [startD, h'] using hw)
  | admit r' _ _ ih => exact ih (by simpa [Contest.admit] using hw)

theorem PassPath.absent {cfg : Cfg} {s u : St} (p : PassPath cfg s u) {d : Nat}
    (e : (u.drain d).ph = .absent) : (s.drain d).ph = .absent := by
  by_cases hw : (s.drain d).ph = .waiting
  · rcases p.waiting hw with x | x <;> rw [x] at e <;> cases e
  · rw [← p.frame.2.2.1 d hw]; exact e

theorem toArrive_step {cfg : Cfg} {s t : St} {a : Act} (h : step cfg s a = some t) :
    toArrive cfg t ≤ toArrive cfg s ∧ (a.arrival = true → toArrive cfg t < toArrive cfg s) := by
  unfold step at h
  cases hu : act cfg s a with
  | none => rw [hu] at h; cases h
  | some u =>
    rw [hu] at h; cases h
    have pp := pass_path cfg u
    have fr := pp.frame
    have hg := act_guard hu
    have hr : ∀ r < cfg.nr, (if ((pass cfg u).run r).here then 0 else 1) ≤ (if (s.run r).here then 0 else 1) := by
      intro r _
      rw [(fr.1 r).2.2.2, act_run hu r]
      cases hh : (s.run r).here
      · simp only [Bool.false_eq_true, ite_false]; split <;> omega
      · cases a <;> simp only [runAfter] <;> (try split) <;> simp [hh]
    have hd : ∀ d < cfg.nd, (if ((pass cfg u).drain d).ph = .absent then 1 else 0) ≤
        (if (s.drain d).ph = .absent then 1 else 0) := by
      intro d _
      by_cases e : ((pass cfg u).drain d).ph = .absent
      · have e1 := pp.absent e
        rw [act_drain hu d] at e1
        have : (s.drain d).ph = .absent := by
          cases a with
          | tick =>
            simp only [drainAfter] at e1
            rcases tickD_ph cfg (anyWait cfg s) d (s.drain d) with x | x
            · rw [← x]; exact e1
            · rw [x] at e1; cases e1
          | arriveD e' | dbusy e' _ | dend e' =>
            simp only [drainAfter] at e1; split at e1
            · simp at e1 <;> exact e1
            · exact e1
          | _ => exact e1
        simp [e, this]
      · simp [e]
    refine ⟨by unfold toArrive; have := rsum_le hr; have := rsum_le hd; omega, fun har => ?_⟩
    cases a with
    | arrive r =>
      dsimp only at hg
      have hlt : (if ((pass cfg u).run r).here then 0 else 1) < (if (s.run r).here then 0 else 1) := by
        rw [(fr.1 r).2.2.2, act_run hu r]; simp [runAfter, hg.2]
      have := rsum_lt hr hg.1 hlt; have := rsum_le hd
      unfold toArrive; omega
    | arriveD d =>
      dsimp only at hg
      have hlt : (if ((pass cfg u).drain d).ph = .absent then 1 else 0) < (if (s.drain d).ph = .absent then 1 else 0) := by
        have h1 : (u.drain d).ph = .waiting := by rw [act_drain hu d]; simp [drainAfter]
        have h2 : ((pass cfg u).drain d).ph ≠ .absent := by
          intro e; rcases pp.waiting h1 with x | x <;> rw [x] at e <;> cases e
        simp [h2, hg.2]
      have := rsum_lt hd hg.1 hlt; have := rsum_le hr
      unfold toArrive; omega
    | _ => simp [Act.arrival] at har

/-- Every run of the model has a last arrival: each run and drain arrives at most once. -/
theorem Run.calm {cfg : Cfg} (ρ : Run cfg) : ∃ n0, ∀ n ≥ n0, (ρ.act n).arrival = false := by
  obtain ⟨n1, _, hc⟩ := eventually_const (fun n => toArrive cfg (ρ.st n)) 0
    (fun n _ => (toArrive_step (ρ.steps n)).1)
  refine ⟨n1, fun n hn => ?_⟩
  cases ha : (ρ.act n).arrival
  · rfl
  · have := (toArrive_step (ρ.steps n)).2 ha
    have e1 := hc n hn; have e2 := hc (n + 1) (by omega)
    omega

/-- **Property 3, for every run of the model.** Arrivals at any times (each run and drain of the
configuration arrives at most once): if every task ends, the gates reopen and time passes, then
from some time on nothing waits. -/
theorem no_starvation_all {cfg : Cfg} (hp : 0 < cfg.pool)
    (hsz : ∀ d < cfg.nd, (cfg.drain d).size ≤ cfg.drainMax) (ρ : Run cfg)
    (ends : ∀ n r, r < cfg.nr → 0 < ((ρ.st n).run r).running → ∃ m ≥ n, finOf r (ρ.act m))
    (gates : ∀ n, ∃ m ≥ n, (ρ.st m).gate = true)
    (time : ∀ n, ∃ m ≥ n, ρ.act m = .tick) :
    ∃ n, ∀ m ≥ n, Quiet cfg (ρ.st m) :=
  let ⟨n0, calm⟩ := ρ.calm
  no_starvation hp hsz ρ n0 calm ends gates time

/-! ## Within a project: the oldest last start goes first -/

/-- 1 CPU, one project: a four-task run, then a one-task run. -/
def tieCfg : Cfg := { pool := 1, runs := [{ proj := 0, tasks := 4, cap := 4 }, { proj := 0, tasks := 1, cap := 1 }] }

/-- The long run's first task ends: both runs hold nothing, and the newer one, which has never
started, goes first. (With "fewest running, then ticket" alone the long run won here every
time, until all its tasks had started.) -/
theorem newer_run_turn :
    ((final tieCfg [.arrive 0, .tick, .arrive 1, .finC 0]).run 1).pend = 0 ∧
      emptyWaiter (final tieCfg [.arrive 0, .tick, .arrive 1, .finC 0]) 0 = true := by decide

/-- 1 CPU, one project: a two-task run, then two one-task runs. -/
def newcomerCfg : Cfg :=
  { pool := 1, runs := [{ proj := 0, tasks := 2, cap := 2 }, { proj := 0, tasks := 1, cap := 1 },
                        { proj := 0, tasks := 1, cap := 1 }] }

def newcomerTrace : List Act := [.arrive 0, .tick, .arrive 1, .finC 0, .tick, .arrive 2, .finC 1]

/-- **Runs that never started go first**, so each new run of a project goes before a run of the
project that has started before and now waits holding nothing: here two newcomers start while it
waits. A stream of new runs of one project would hold it for as long as the stream lasts (streams
are not in this model, where each run arrives once). -/
theorem newcomers_first :
    ∃ s, Reach newcomerCfg s ∧ emptyWaiter s 0 = true ∧ (s.run 1).pend = 0 ∧ (s.run 2).pend = 0 :=
  ⟨final _ newcomerTrace, final_reach (by decide), by decide⟩

/-! ## Axioms: only the standard three -/

/-- info: 'Cpuq.Contest.work_conserving' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms work_conserving

/-- info: 'Cpuq.Contest.no_wait_under' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms no_wait_under

/-- info: 'Cpuq.Contest.no_starvation' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms no_starvation

/-- info: 'Cpuq.Contest.no_starvation_all' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms no_starvation_all

/-- info: 'Cpuq.Contest.drain_no_pass' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms drain_no_pass

/-- info: 'Cpuq.Contest.drain_waits_for' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms drain_waits_for

/-- info: 'Cpuq.Contest.hold_bound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms hold_bound

/-- info: 'Cpuq.Contest.idle_bound' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms idle_bound

/-- info: 'Cpuq.Contest.withheld' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms withheld

/-- info: 'Cpuq.Contest.capT_pos' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms capT_pos

/-- info: 'Cpuq.Contest.big_drain_never' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms big_drain_never

/-- info: 'Cpuq.Contest.line_order' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms line_order

/-- info: 'Cpuq.Contest.project_turn' depends on axioms: [propext, Classical.choice, Quot.sound] -/
#guard_msgs in #print axioms project_turn

/-- info: 'Cpuq.Contest.design_not_work_conserving' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms design_not_work_conserving

/-- info: 'Cpuq.Contest.design_drain_passes' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms design_drain_passes

/-- info: 'Cpuq.Contest.backstop_blocks_under' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms backstop_blocks_under

/-- info: 'Cpuq.Contest.newcomers_first' depends on axioms: [propext, Quot.sound] -/
#guard_msgs in #print axioms newcomers_first

end Cpuq.Contest
