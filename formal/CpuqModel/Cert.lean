/-
Certificates: the search's liveness checks as proofs, for one configuration at a time.

The search (`Explore.lean`) runs as compiled code and proves nothing. Here a certificate the
search writes (`CertGen.lean`) is checked by Lean's kernel (`decide +kernel`), and a theorem
(`served_of_cert`) says what a certificate that checks proves: in every weakly fair run of
`moveX` from the start, the waiting condition (`wait`, e.g. `starving cfg · w`) never holds
forever.

A certificate is a graph and a ranking:
- the graph (`Row`s, in a tree the kernel searches in few steps, `RTree`): every state `moveX`
  reaches, each with its successor under every action of `actsAll` (by row number). `graphOk`
  checks that row 0 is `init`, and that for every state and every action, `moveX` gives exactly
  the successor listed. `shapeOk` and `moveX_acts` show
  that no action outside `actsAll` is ever enabled, so the graph holds every reachable state
  (`reach_in`).
- a ranking (in each row, one per waiting condition): for every state where `wait` holds, a rank
  and a helpful action of a weakly fair
  class, enabled there. `rankOk` checks that every step from a waiting state to a waiting state
  either lowers the rank, or keeps it, keeps the helpful action, and is not of its class. In a run
  that waits forever the rank settles; from then on one helpful action stays enabled and is never
  taken, which weak fairness forbids.

This is the standard proof rule for a response property under weak fairness, with the search's
graph as the set of reachable states. It covers the configuration it is given, no other.
-/
import CpuqModel.Fifo

namespace Cpuq

/-! ### Every action -/

/-- `actions` with a failing exit for every task, also of operations without `-r`: every action
that can be enabled (`moveX_acts`). -/
def actsAll (cfg : Cfg) : List Act :=
  actions cfg ++ (opIds cfg).flatMap (fun o => (List.range (cfg.op o).tasks).map (fun i => Act.exit o i false))

/-- What `moveX_acts` needs of a state: the sizes the configuration gives, and no pool lock, owed
SIGCONT or pending Ctrl-Z of an operation outside it. -/
def shapeOk (cfg : Cfg) (s : St) : Bool :=
  s.cpus.length == cfg.cpus && s.ops.length == cfg.ops.length &&
  (List.range cfg.ops.length).all (fun o => (s.op o).tasks.length == (cfg.op o).tasks) &&
  (match s.poolLock with
   | none => true
   | some o => decide (o < cfg.ops.length)) &&
  decide (s.held < 2 ^ cfg.ops.length) && decide (s.tstp < 2 ^ cfg.ops.length)

/-! ### Certificates -/

def pack (b : Nat) (l : List Nat) : Nat := l.foldr (fun d acc => d + b * acc) 0

/-- Exactly `k` digits of `n` in base `b`. -/
def unpackN (b : Nat) : Nat → Nat → List Nat
  | 0, _ => []
  | k + 1, n => n % b :: unpackN b k (n / b)

/-- A state of the graph; its successor under each action of `actsAll` (index + 1, or 0 when
the action is not enabled), packed in base `succBase`; and for each waiting condition of the
certificate, `rank * 256 + help`, `help` the index in `actsAll` of a helpful action. -/
structure Row where
  st : St
  succ : Nat
  rank : List Nat
  deriving Inhabited

def succBase : Nat := 65536

def Row.next (cfg : Cfg) (r : Row) : List Nat := unpackN succBase (actsAll cfg).length r.succ

/-- The rows, as a Braun tree: row 0 at the root, row `2k + 1` at `k` of the left subtree, row
`2k + 2` at `k` of the right. The kernel finds a row in as many steps as the tree is deep. -/
inductive RTree where
  | leaf
  | node (x : Row) (l r : RTree)
  deriving Inhabited

namespace RTree

def getImpl : RTree → Nat → Option Row
  | leaf, _ => none
  | node x l r, n => if n == 0 then some x else if n % 2 == 1 then l.getImpl (n / 2) else r.getImpl (n / 2 - 1)

def allImpl (p : Row → Bool) : RTree → Bool
  | leaf => true
  | node x l r => p x && l.allImpl p && r.allImpl p

/-- Row `n`. Written with the recursor, not by structural recursion: the kernel then takes one
step per level, where `brecOn`'s bookkeeping costs it milliseconds a lookup. -/
@[implemented_by getImpl]
def get (t : RTree) : Nat → Option Row :=
  RTree.rec (motive := fun _ => Nat → Option Row) (fun _ => none)
    (fun x _ _ gl gr n => if n == 0 then some x else if n % 2 == 1 then gl (n / 2) else gr (n / 2 - 1)) t

/-- Every row has `p`; with the recursor, as `get`. -/
@[implemented_by allImpl]
def all (p : Row → Bool) (t : RTree) : Bool :=
  RTree.rec (motive := fun _ => Bool) true (fun x _ _ al ar => p x && al && ar) t

theorem get_leaf (n : Nat) : leaf.get n = none := rfl
theorem get_node (x : Row) (l r : RTree) (n : Nat) :
    (node x l r).get n = if n == 0 then some x else if n % 2 == 1 then l.get (n / 2) else r.get (n / 2 - 1) :=
  rfl
theorem all_leaf (p : Row → Bool) : leaf.all p = true := rfl
theorem all_node (p : Row → Bool) (x : Row) (l r : RTree) :
    (node x l r).all p = (p x && l.all p && r.all p) := rfl

inductive Mem : Row → RTree → Prop
  | here {x : Row} {l r : RTree} : Mem x (node x l r)
  | left {y x : Row} {l r : RTree} : Mem y l → Mem y (node x l r)
  | right {y x : Row} {l r : RTree} : Mem y r → Mem y (node x l r)

theorem get_mem : ∀ {t : RTree} {n : Nat} {x : Row}, t.get n = some x → Mem x t
  | leaf, _, _, h => by rw [get_leaf] at h; cases h
  | node y l r, n, x, h => by
    rw [get_node] at h
    split at h
    · cases h; exact .here
    · split at h
      · exact .left (get_mem h)
      · exact .right (get_mem h)

theorem all_mem {p : Row → Bool} : ∀ {t : RTree}, t.all p = true → ∀ x, Mem x t → p x = true
  | leaf, _, x, hx => by cases hx
  | node y l r, h, x, hx => by
    rw [all_node] at h
    simp only [Bool.and_eq_true] at h
    cases hx with
    | here => exact h.1.1
    | left hx => exact all_mem h.1.2 x hx
    | right hx => exact all_mem h.2 x hx

end RTree

/-- One row of the graph: its state has the configuration's shape, and its successor under every
action of `actsAll` is the row listed. -/
def graphRow (cfg : Cfg) (T : RTree) (r : Row) : Bool :=
  shapeOk cfg r.st &&
  ((actsAll cfg).zip (r.next cfg)).all (fun (a, j) =>
    match moveX cfg r.st a with
    | none => j == 0
    | some t =>
      j != 0 &&
        match T.get (j - 1) with
        | some r' => r'.st == t
        | none => false)

/-- Row 0 is `init`. -/
def rootOk (cfg : Cfg) (T : RTree) : Bool :=
  match T.get 0 with
  | some r => r.st == init cfg
  | none => false

/-- The graph holds `init` (row 0), and every state's successors under every action of
`actsAll`. -/
def graphOk (cfg : Cfg) (T : RTree) : Bool := rootOk cfg T && T.all (graphRow cfg T)

/-- One row of the `c`th ranking, for `wait`. -/
def rankRow (cfg : Cfg) (T : RTree) (wait : St → Bool) (c : Nat) (r : Row) : Bool :=
  !wait r.st ||
    (let rh := r.rank.getD c 0
     let k := rh % 256
     let h := (actsAll cfg).getD k .handout
     (fairKey h).isSome && (r.next cfg).getD k 0 != 0 &&
     ((actsAll cfg).zip (r.next cfg)).all (fun (a, j) =>
       j == 0 ||
         match T.get (j - 1) with
         | none => false
         | some r' =>
           let rh' := r'.rank.getD c 0
           !wait r'.st || decide (rh' / 256 < rh / 256) ||
             (rh' / 256 == rh / 256 && rh' % 256 == k && fairKey a != fairKey h)))

/-- The `c`th ranking of the rows is one for `wait`. -/
def rankOk (cfg : Cfg) (T : RTree) (wait : St → Bool) (c : Nat) : Bool := T.all (rankRow cfg T wait c)

/-! ### Runs and weak fairness, for `moveX` -/

/-- Weak fairness of every step class (`fairKey`) in a run of `moveX`, as `Run.Fair` for `move`. -/
def RunX.Fair {cfg : Cfg} (r : RunX cfg) : Prop :=
  ∀ a, (fairKey a).isSome = true → ∀ n, (∀ m, n ≤ m → (moveX cfg (r.st m) a).isSome = true) →
    ∃ m, n ≤ m ∧ ∃ b, r.act m = some b ∧ fairKey b = fairKey a

/-! ### No action outside `actsAll` is enabled -/

attribute [-simp] List.getD_eq_getElem?_getD

theorem op_oob {s : St} {o : Nat} (h : s.ops.length ≤ o) : s.op o = {} := by
  simp [St.op, List.getD_eq_getElem?_getD, List.getElem?_eq_none h]

theorem cpu_oob {s : St} {c : Nat} (h : s.cpus.length ≤ c) : s.cpu c = {} := by
  simp [St.cpu, List.getD_eq_getElem?_getD, List.getElem?_eq_none h]

theorem task_oob {s : St} {o i : Nat} (h : (s.op o).tasks.length ≤ i) : s.task o i = { st := .gone } := by
  simp [St.task, List.getD_eq_getElem?_getD, List.getElem?_eq_none h]

theorem mem_opActs {cfg : Cfg} {o : Nat} (ho : o < cfg.ops.length) {a : Act}
    (ha : a ∈ [Act.arrive o, .kill o, .crash o, .stop o, .cont o, .finish o, .enter o, .mark o,
      .tstp o, .halt o]) : a ∈ actsAll cfg := by
  unfold actsAll actions
  simp only [List.mem_append, List.mem_flatMap]
  exact Or.inl (Or.inl (Or.inl (Or.inl (Or.inl ⟨o, List.mem_range.2 ho, ha⟩))))

theorem mem_taskActs {cfg : Cfg} {o i : Nat} (ho : o < cfg.ops.length) (hi : i < (cfg.op o).tasks)
    {a : Act} (ha : a ∈ [Act.exit o i true, .timeout o i, .gone o i] ∨
      ∃ d, d < cfg.cpus ∧ a = .consolidate o i d) : a ∈ actsAll cfg := by
  unfold actsAll actions
  simp only [List.mem_append, List.mem_flatMap]
  refine Or.inl (Or.inl (Or.inl (Or.inr ⟨o, List.mem_range.2 ho, i, List.mem_range.2 hi, ?_⟩)))
  simp only [List.mem_map, List.mem_range]
  rcases ha with ha | ⟨d, hd, rfl⟩
  · exact Or.inl (Or.inl ha)
  · exact Or.inr ⟨d, hd, rfl⟩

theorem mem_exitFalse {cfg : Cfg} {o i : Nat} (ho : o < cfg.ops.length) (hi : i < (cfg.op o).tasks) :
    Act.exit o i false ∈ actsAll cfg := by
  unfold actsAll
  simp only [List.mem_append, List.mem_flatMap, List.mem_map, List.mem_range]
  exact Or.inr ⟨o, List.mem_range.2 ho, i, hi, rfl⟩

theorem mem_cpuActs {cfg : Cfg} {o c : Nat} (ho : o < cfg.ops.length) (hc : c < cfg.cpus) {a : Act}
    (ha : a ∈ [Act.refill o c, .release o c, .accept o c, .drain o c, .undrain o c]) :
    a ∈ actsAll cfg := by
  unfold actsAll actions
  simp only [List.mem_append, List.mem_flatMap]
  exact Or.inl (Or.inl (Or.inr ⟨o, List.mem_range.2 ho, c, List.mem_range.2 hc, ha⟩))

theorem mem_tick (cfg : Cfg) : Act.tick ∈ actsAll cfg := by
  unfold actsAll actions; simp

theorem mem_handout (cfg : Cfg) : Act.handout ∈ actsAll cfg := by
  unfold actsAll actions; simp

structure Shape (cfg : Cfg) (s : St) : Prop where
  cpus : s.cpus.length = cfg.cpus
  ops : s.ops.length = cfg.ops.length
  tasks : ∀ o, o < cfg.ops.length → (s.op o).tasks.length = (cfg.op o).tasks
  lock : ∀ o, s.poolLock = some o → o < cfg.ops.length
  held : s.held < 2 ^ cfg.ops.length
  tstp : s.tstp < 2 ^ cfg.ops.length

theorem shape_of {cfg : Cfg} {s : St} (h : shapeOk cfg s = true) : Shape cfg s := by
  simp only [shapeOk, Bool.and_eq_true, beq_iff_eq, List.all_eq_true, List.mem_range,
    decide_eq_true_eq] at h
  obtain ⟨⟨⟨⟨⟨h1, h2⟩, h3⟩, h4⟩, h5⟩, h6⟩ := h
  refine ⟨h1, h2, h3, fun o ho => ?_, h5, h6⟩
  rw [ho] at h4; simpa using h4

theorem bit_oob {n o k : Nat} (h : n < 2 ^ k) (ho : k ≤ o) : bit n o = false :=
  Nat.testBit_lt_two_pow (Nat.lt_of_lt_of_le h (Nat.pow_le_pow_right (by decide) ho))

theorem op_lt {cfg : Cfg} {s : St} {o : Nat} (hs : Shape cfg s) (h : (s.op o).phase ≠ .over) :
    o < cfg.ops.length := by
  refine Classical.byContradiction fun hn => h ?_
  rw [op_oob (by rw [hs.ops]; omega)]

theorem alive_lt {cfg : Cfg} {s : St} {o : Nat} (hs : Shape cfg s) (h : s.isAlive o = true) :
    o < cfg.ops.length :=
  op_lt hs (by simp only [St.isAlive, beq_iff_eq] at h; rw [h]; decide)

theorem cpu_lt {cfg : Cfg} {s : St} {c : Nat} (hs : Shape cfg s) (h : (s.cpu c) ≠ {}) :
    c < cfg.cpus := by
  refine Classical.byContradiction fun hn => h ?_
  exact cpu_oob (by rw [hs.cpus]; omega)

theorem slot_lt {cfg : Cfg} {s : St} {c : Nat} {x : Slot} (hs : Shape cfg s) (h : (s.cpu c).slot = some x) :
    c < cfg.cpus := cpu_lt hs (fun e => by rw [e] at h; cases h)

theorem grant_lt {cfg : Cfg} {s : St} {c o : Nat} (hs : Shape cfg s) (h : (s.cpu c).grant = some o) :
    c < cfg.cpus := cpu_lt hs (fun e => by rw [e] at h; cases h)

theorem task_lt {cfg : Cfg} {s : St} {o i : Nat} (hs : Shape cfg s) (h : s.task o i ≠ { st := .gone }) :
    o < cfg.ops.length ∧ i < (cfg.op o).tasks := by
  have ho : o < cfg.ops.length := by
    refine Classical.byContradiction fun hn => h ?_
    apply task_oob; rw [op_oob (by rw [hs.ops]; omega)]; simp
  refine ⟨ho, Classical.byContradiction fun hn => h ?_⟩
  exact task_oob (by rw [hs.tasks o ho]; omega)

theorem running_lt {cfg : Cfg} {s : St} {o i c : Nat} (hs : Shape cfg s) (h : (s.task o i).st = .running c) :
    o < cfg.ops.length ∧ i < (cfg.op o).tasks := task_lt hs (fun e => by rw [e] at h; cases h)

theorem step_acts {cfg : Cfg} {s : St} {a : Act} (hs : Shape cfg s) (h : (step cfg s a).isSome = true) :
    a ∈ actsAll cfg := by
  cases a with
  | arrive o =>
    simp only [step] at h; split at h
    · rename_i hp; exact mem_opActs (op_lt hs (by simp at hp; rw [hp]; decide)) (by simp)
    · cases h
  | exit o i ok =>
    simp only [step] at h; split at h
    · rename_i c hc
      obtain ⟨ho, hi⟩ := running_lt hs hc
      cases ok
      · exact mem_exitFalse ho hi
      · exact mem_taskActs ho hi (Or.inl (by simp))
    · cases h
  | timeout o i =>
    simp only [step] at h; split at h
    · rename_i c hc; obtain ⟨ho, hi⟩ := running_lt hs hc; exact mem_taskActs ho hi (Or.inl (by simp))
    · cases h
  | gone o i =>
    simp only [step] at h; split at h
    · rename_i c hc
      obtain ⟨ho, hi⟩ := task_lt hs (fun e => by rw [e] at hc; cases hc)
      exact mem_taskActs ho hi (Or.inl (by simp))
    · cases h
  | refill o c =>
    simp only [step] at h; split at h
    · rename_i hg
      simp only [Bool.and_eq_true, beq_iff_eq] at hg
      exact mem_cpuActs (alive_lt hs hg.1.1.1.1) (slot_lt hs hg.1.1.1.2) (by simp)
    · cases h
  | release o c =>
    simp only [step] at h; split at h
    · rename_i sl hsl; split at h
      · rename_i hg
        simp only [Bool.and_eq_true] at hg
        exact mem_cpuActs (alive_lt hs hg.1.1.1.1.1) (slot_lt hs hsl) (by simp)
      · cases h
    · cases h
  | handout => exact mem_handout cfg
  | accept o c =>
    simp only [step] at h; split at h
    · rename_i hg
      simp only [Bool.and_eq_true, beq_iff_eq] at hg
      exact mem_cpuActs (alive_lt hs hg.1.1) (grant_lt hs hg.1.2) (by simp)
    · cases h
  | drain o c =>
    simp only [step] at h; split at h
    · rename_i hg
      simp only [canDrain, Bool.and_eq_true, beq_iff_eq] at hg
      exact mem_cpuActs (alive_lt hs hg.1.1) (slot_lt hs hg.1.2) (by simp)
    · cases h
  | undrain o c =>
    simp only [step] at h; split at h
    · rename_i hg
      simp only [Bool.and_eq_true, beq_iff_eq] at hg
      exact mem_cpuActs (alive_lt hs hg.1.1.2) (slot_lt hs hg.1.2) (by simp)
    · cases h
  | consolidate o i d =>
    simp only [step] at h; split at h
    · rename_i c hc; split at h
      · rename_i hg
        simp only [Bool.and_eq_true, beq_iff_eq] at hg
        obtain ⟨ho, hi⟩ := running_lt hs hc
        exact mem_taskActs ho hi (Or.inr ⟨d, slot_lt hs hg.1.2, rfl⟩)
      · cases h
    · cases h
  | kill o =>
    simp only [step] at h; split at h
    · rename_i hg; simp only [Bool.and_eq_true] at hg
      exact mem_opActs (alive_lt hs hg.2) (by simp)
    · cases h
  | crash o =>
    simp only [step] at h; split at h
    · rename_i hg; simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at hg
      exact mem_opActs (op_lt hs (by rcases hg.2 with e | e <;> rw [e] <;> decide)) (by simp)
    · cases h
  | stop o =>
    simp only [step] at h; split at h
    · rename_i hg; simp only [Bool.and_eq_true] at hg
      exact mem_opActs (alive_lt hs hg.2) (by simp)
    · cases h
  | cont o =>
    simp only [step] at h; split at h
    · rename_i hg; simp only [beq_iff_eq] at hg
      exact mem_opActs (op_lt hs (by rw [hg]; decide)) (by simp)
    · cases h
  | finish o =>
    simp only [step] at h; split at h
    · rename_i hg; simp only [Bool.and_eq_true] at hg
      exact mem_opActs (alive_lt hs hg.1.1) (by simp)
    · cases h
  | enter o => simp [step] at h
  | mark o => simp [step] at h
  | tstp o => simp [step] at h
  | halt o => simp [step] at h
  | tick => exact mem_tick cfg

theorem move_acts {cfg : Cfg} {s : St} {a : Act} (hs : Shape cfg s) (h : (move cfg s a).isSome = true) :
    a ∈ actsAll cfg := by
  unfold move at h
  split at h
  · cases h
  cases a with
  | arrive o =>
    dsimp only at h; split at h
    · cases h
    · exact step_acts hs h
  | enter o =>
    dsimp only at h; split at h
    · rename_i hg; simp only [Bool.and_eq_true] at hg
      exact mem_opActs (drainOp_lt hg.1) (by simp)
    · cases h
  | mark o =>
    dsimp only at h; split at h
    · rename_i hg; simp only [Bool.and_eq_true, beq_iff_eq] at hg
      exact mem_opActs (hs.lock o hg.1) (by simp)
    · cases h
  | crash o =>
    dsimp only at h; rw [Option.isSome_map] at h; exact step_acts hs h
  | kill o =>
    dsimp only at h; rw [Option.isSome_map] at h; exact step_acts hs h
  | finish o =>
    dsimp only at h; rw [Option.isSome_map] at h; exact step_acts hs h
  | tstp o =>
    dsimp only at h; split at h
    · rename_i hg; simp only [Bool.and_eq_true, Bool.or_eq_true, beq_iff_eq] at hg
      exact mem_opActs (op_lt hs (by rcases hg.2 with e | e <;> rw [e] <;> decide)) (by simp)
    · cases h
  | stop o =>
    dsimp only at h; split at h
    · rw [Option.isSome_map] at h; exact step_acts hs h
    · cases h
  | halt o =>
    dsimp only at h; split at h
    · rename_i hg; simp only [Bool.and_eq_true, beq_iff_eq] at hg
      exact mem_opActs (op_lt hs (by rw [hg.1]; decide)) (by simp)
    · cases h
  | cont o =>
    dsimp only at h; split at h
    · rename_i hb
      refine mem_opActs (o := o) (Classical.byContradiction fun hn => ?_) (by simp)
      rw [bit_oob hs.held (by omega)] at hb; cases hb
    · cases h
  | tick => exact mem_tick cfg
  | exit o i ok => exact step_acts hs h
  | timeout o i => exact step_acts hs h
  | gone o i => exact step_acts hs h
  | refill o c => exact step_acts hs h
  | release o c => exact step_acts hs h
  | handout => exact step_acts hs h
  | accept o c => exact step_acts hs h
  | drain o c => exact step_acts hs h
  | undrain o c => exact step_acts hs h
  | consolidate o i d => exact step_acts hs h

/-- Every action `moveX` takes from a state of the right shape is in `actsAll`. -/
theorem moveX_acts {cfg : Cfg} {s t : St} {a : Act} (hs : shapeOk cfg s = true)
    (h : moveX cfg s a = some t) : a ∈ actsAll cfg := by
  have hs := shape_of hs
  have h' : (moveX cfg s a).isSome = true := by rw [h]; rfl
  unfold moveX at h'
  split at h'
  · exact move_acts hs h'
  cases a with
  | tick => exact mem_tick cfg
  | refill o c => dsimp only at h'; rw [Option.isSome_map] at h'; exact move_acts hs h'
  | timeout o i =>
    dsimp only at h'; split at h'
    · rw [Option.isSome_map] at h'; exact step_acts (cfg := { cfg with timeouts := true })
        ⟨hs.cpus, hs.ops, hs.tasks, hs.lock, hs.held, hs.tstp⟩ h'
    · exact move_acts hs h'
  | accept o c => dsimp only at h'; rw [Option.isSome_map] at h'; exact move_acts hs h'
  | finish o => dsimp only at h'; rw [Option.isSome_map] at h'; exact move_acts hs h'
  | _ => exact move_acts hs h'

/-! ### What a certificate proves -/

theorem length_unpackN (b : Nat) : ∀ k n, (unpackN b k n).length = k
  | 0, _ => rfl
  | k + 1, n => by simp [unpackN, length_unpackN b k]

theorem exists_zip {α β : Type} {a : α} : ∀ {l1 : List α} {l2 : List β}, a ∈ l1 →
    l1.length ≤ l2.length → ∃ b, (a, b) ∈ l1.zip l2
  | [], _, h, _ => by cases h
  | _ :: _, [], _, hl => by simp at hl
  | x :: xs, y :: ys, h, hl => by
    rcases List.mem_cons.1 h with rfl | h
    · exact ⟨y, by simp⟩
    · obtain ⟨b, hb⟩ := exists_zip (l2 := ys) h (by simpa using hl)
      exact ⟨b, by simp [hb]⟩

theorem mem_zip_getD {α : Type} {d : α} : ∀ {l1 : List α} {l2 : List Nat} {k : Nat},
    l1.length = l2.length → l2.getD k 0 ≠ 0 → (l1.getD k d, l2.getD k 0) ∈ l1.zip l2
  | [], [], _, _, h => by simp at h
  | [], _ :: _, _, hl, _ => by simp at hl
  | _ :: _, [], _, hl, _ => by simp at hl
  | _ :: _, _ :: _, 0, _, _ => by simp [List.getD_cons_zero]
  | _ :: xs, _ :: ys, k + 1, hl, h => by
    rw [List.getD_cons_succ] at h
    have := mem_zip_getD (d := d) (l1 := xs) (l2 := ys) (k := k) (by simpa using hl) h
    rw [List.getD_cons_succ, List.getD_cons_succ, List.zip_cons_cons]
    exact List.mem_cons_of_mem _ this

theorem next_length (cfg : Cfg) (r : Row) : (r.next cfg).length = (actsAll cfg).length := by
  rw [Row.next, length_unpackN]

theorem graphOk_spec {cfg : Cfg} {T : RTree} (h : graphOk cfg T = true) :
    (∃ r0, T.get 0 = some r0 ∧ r0.st = init cfg) ∧
    ∀ r, T.Mem r → shapeOk cfg r.st = true ∧ ∀ p ∈ (actsAll cfg).zip (r.next cfg),
      (∀ t, moveX cfg r.st p.1 = some t → p.2 ≠ 0 ∧ ∃ r', T.get (p.2 - 1) = some r' ∧ r'.st = t) ∧
      (p.2 ≠ 0 → (moveX cfg r.st p.1).isSome = true) := by
  simp only [graphOk, rootOk, Bool.and_eq_true] at h
  obtain ⟨h0, h1⟩ := h
  refine ⟨?_, fun r hr => ?_⟩
  · cases e : T.get 0 with
    | none => rw [e] at h0; cases h0
    | some r0 => rw [e] at h0; exact ⟨r0, rfl, by simpa using h0⟩
  · have := RTree.all_mem h1 r hr
    simp only [graphRow, Bool.and_eq_true, List.all_eq_true] at this
    refine ⟨this.1, fun p hp => ?_⟩
    have hp' := this.2 p hp
    constructor
    · intro t ht
      rw [ht] at hp'
      simp only [Bool.and_eq_true, bne_iff_ne, ne_eq] at hp'
      refine ⟨hp'.1, ?_⟩
      revert hp'
      cases e : T.get (p.2 - 1) with
      | none => intro hp'; exact absurd hp'.2 (by simp)
      | some r' => intro hp'; exact ⟨r', rfl, by simpa using hp'.2⟩
    · intro hj
      cases hm : moveX cfg r.st p.1 with
      | some _ => rfl
      | none => rw [hm] at hp'; simp only [beq_iff_eq] at hp'; exact absurd hp' hj

/-- Every state `moveX` reaches is in a graph that checks. -/
theorem reach_in {cfg : Cfg} {T : RTree} (hg : graphOk cfg T = true) {s : St}
    (hr : ReachX cfg s) : ∃ r, T.Mem r ∧ r.st = s := by
  obtain ⟨⟨r0, h0, hi⟩, hall⟩ := graphOk_spec hg
  induction hr with
  | init => exact ⟨r0, RTree.get_mem h0, hi⟩
  | step a _ e ih =>
    obtain ⟨r, hr, rfl⟩ := ih
    obtain ⟨hsh, hp⟩ := hall r hr
    obtain ⟨j, hj⟩ := exists_zip (moveX_acts hsh e) (l2 := r.next cfg)
      (by rw [next_length]; exact Nat.le_refl _)
    obtain ⟨_, r', hr', hst⟩ := (hp _ hj).1 _ e
    exact ⟨r', RTree.get_mem hr', hst⟩

theorem rankOk_spec {cfg : Cfg} {T : RTree} {wait : St → Bool} {c : Nat}
    (h : rankOk cfg T wait c = true) {r : Row} (hr : T.Mem r) (hw : wait r.st = true) :
    (fairKey ((actsAll cfg).getD (r.rank.getD c 0 % 256) .handout)).isSome = true ∧
    (r.next cfg).getD (r.rank.getD c 0 % 256) 0 ≠ 0 ∧
    ∀ p ∈ (actsAll cfg).zip (r.next cfg), p.2 ≠ 0 → ∀ r', T.get (p.2 - 1) = some r' →
      wait r'.st = true →
      r'.rank.getD c 0 / 256 < r.rank.getD c 0 / 256 ∨
      (r'.rank.getD c 0 / 256 = r.rank.getD c 0 / 256 ∧
        r'.rank.getD c 0 % 256 = r.rank.getD c 0 % 256 ∧
        fairKey p.1 ≠ fairKey ((actsAll cfg).getD (r.rank.getD c 0 % 256) .handout)) := by
  have := RTree.all_mem h r hr
  simp only [rankRow, hw, Bool.not_true, Bool.false_or, Bool.and_eq_true, bne_iff_ne, ne_eq,
    List.all_eq_true, Bool.or_eq_true, beq_iff_eq] at this
  obtain ⟨⟨hk, hen⟩, hp⟩ := this
  refine ⟨hk, hen, fun p hp' hj r' hr' hwt => ?_⟩
  have := hp p hp'
  rw [hr'] at this
  simp only [hwt, Bool.not_true, Bool.false_or, Bool.or_eq_true, decide_eq_true_eq,
    Bool.and_eq_true, beq_iff_eq, bne_iff_ne, ne_eq] at this
  rcases this with e | e | ⟨⟨e1, e2⟩, e3⟩
  · exact absurd e hj
  · exact Or.inl e
  · exact Or.inr ⟨e1, e2, e3⟩

/-- **What a certificate proves.** If the graph and its `c`th ranking check, then in every
weakly fair run of `moveX` from the start, `wait` never holds forever: from any time on, some
later state has it false. -/
theorem served_of_cert {cfg : Cfg} {T : RTree} {wait : St → Bool} {c : Nat}
    (hg : graphOk cfg T = true) (hr : rankOk cfg T wait c = true)
    (r : RunX cfg) (fair : r.Fair) (t0 : Nat) : ∃ m, t0 ≤ m ∧ wait (r.st m) = false := by
  obtain ⟨_, hall⟩ := graphOk_spec hg
  refine Classical.byContradiction fun hcon => ?_
  have hw : ∀ m, t0 ≤ m → wait (r.st m) = true := fun m hm => by
    cases e : wait (r.st m)
    · exact absurd ⟨m, hm, e⟩ hcon
    · rfl
  -- A row's rank and helpful action for `wait`.
  let rk (x : Row) : Nat := x.rank.getD c 0
  let help (x : Row) : Act := (actsAll cfg).getD (rk x % 256) .handout
  -- One step of the run from a waiting state of the graph.
  have one : ∀ m x, t0 ≤ m → T.Mem x → x.st = r.st m →
      (r.act m = none ∧ x.st = r.st (m + 1)) ∨
      ∃ b y, r.act m = some b ∧ T.Mem y ∧ y.st = r.st (m + 1) ∧
        (rk y / 256 < rk x / 256 ∨
         (rk y / 256 = rk x / 256 ∧ rk y % 256 = rk x % 256 ∧ fairKey b ≠ fairKey (help x))) := by
    intro m x hm hx he
    cases ha : r.act m with
    | none => exact Or.inl ⟨rfl, by rw [r.stays m ha]; exact he⟩
    | some b =>
      right
      have e := r.moves m b ha
      rw [← he] at e
      obtain ⟨hsh, hp⟩ := hall x hx
      obtain ⟨j, hj⟩ := exists_zip (moveX_acts hsh e) (l2 := x.next cfg)
        (by rw [next_length]; exact Nat.le_refl _)
      obtain ⟨hj0, y, hy, hys⟩ := (hp _ hj).1 _ e
      have hwx : wait x.st = true := he ▸ hw m hm
      have hwy : wait y.st = true := hys ▸ hw (m + 1) (by omega)
      exact ⟨b, y, rfl, RTree.get_mem hy, hys, (rankOk_spec hr hx hwx).2.2 _ hj hj0 y hy hwy⟩
  have main : ∀ R0 m x, t0 ≤ m → T.Mem x → x.st = r.st m → rk x / 256 = R0 → False := by
    intro R0
    induction R0 using Nat.strongRecOn with
    | _ R0 ih =>
      intro m x hm hx he hR
      have inv : ∀ m', m ≤ m' → ∃ y, T.Mem y ∧ y.st = r.st m' ∧ rk y / 256 = R0 ∧
          rk y % 256 = rk x % 256 := by
        intro m' hm'
        induction m', hm' using le_induction with
        | base => exact ⟨x, hx, he, hR, rfl⟩
        | succ m' hm' ihm =>
          obtain ⟨y, hy, hey, hRy, hky⟩ := ihm
          rcases one m' y (by omega) hy hey with ⟨_, h2⟩ | ⟨b, z, _, hz, hez, hrk⟩
          · exact ⟨y, hy, h2, hRy, hky⟩
          · rcases hrk with hlt | ⟨h1, h2, _⟩
            · exact (ih _ (by omega) (m' + 1) z (by omega) hz hez rfl).elim
            · exact ⟨z, hz, hez, by omega, by omega⟩
      have never : ∀ m', m ≤ m' → ∀ b, r.act m' = some b → fairKey b ≠ fairKey (help x) := by
        intro m' hm' b hb
        obtain ⟨y, hy, hey, hRy, hky⟩ := inv m' hm'
        rcases one m' y (by omega) hy hey with ⟨h1, _⟩ | ⟨b', z, hb', hz, hez, hrk⟩
        · rw [h1] at hb; cases hb
        · rw [hb] at hb'; cases hb'
          rcases hrk with hlt | ⟨_, _, h3⟩
          · exact (ih _ (by omega) (m' + 1) z (by omega) hz hez rfl).elim
          · have : help y = help x := by simp only [help, hky]
            rw [← this]; exact h3
      have hwx : wait x.st = true := he ▸ hw m hm
      have hkey := (rankOk_spec hr hx hwx).1
      have hen : ∀ m', m ≤ m' → (moveX cfg (r.st m') (help x)).isSome = true := by
        intro m' hm'
        obtain ⟨y, hy, hey, _, hky⟩ := inv m' hm'
        have hwy : wait y.st = true := hey ▸ hw m' (by omega)
        have hen' := (rankOk_spec hr hy hwy).2.1
        have hz := mem_zip_getD (d := Act.handout) (l1 := actsAll cfg) (l2 := y.next cfg)
          (next_length cfg y).symm hen'
        have := ((hall y hy).2 _ hz).2 hen'
        have e : help y = help x := by simp only [help, hky]
        rw [← hey, ← e]
        exact this
      obtain ⟨m', hm', b, hb, hbk⟩ := fair _ hkey m hen
      exact never m' hm' b hb hbk
  obtain ⟨x, hx, he⟩ := reach_in hg (r.reach t0)
  exact main _ t0 x (Nat.le_refl _) hx he rfl

end Cpuq
