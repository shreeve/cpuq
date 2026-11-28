/-
Writes the certificates `Cert.lean` checks: the search's graph over `actsAll`, and a ranking for
a waiting condition, as Lean source. Compiled code that proves nothing; `graphOk` and `rankOk`
check what it writes. `scripts/GenCerts.lean` runs it.

The ranking: the waiting states' strongly connected components (every step counts), in
topological order; a component's rank is its distance from the end of that order, so a step to a
later component lowers it. A component's helpful action is one of a weakly fair class enabled in
every state of it whose class no step inside it takes. A component with none is a weakly fair
run that waits forever (the search's `L3 fair`); then there is no certificate.
-/
import CpuqModel.Cert
import Std.Data.HashMap

namespace Cpuq.CertGen

structure Graph where
  states : Array St
  succ : Array (Array (Option Nat))

/-- Every state `moveX` reaches, with each one's successor under each action of `actsAll`. -/
def build (cfg : Cfg) (limit : Nat := 200000) : Except String Graph := Id.run do
  let acts := (actsAll cfg).toArray
  let s0 := init cfg
  let mut index : Std.HashMap St Nat := {}
  index := index.insert s0 0
  let mut states : Array St := #[s0]
  let mut succ : Array (Array (Option Nat)) := #[]
  let mut i := 0
  while i < states.size do
    let s := states[i]!
    let mut out : Array (Option Nat) := #[]
    for a in acts do
      match moveX cfg s a with
      | none => out := out.push none
      | some t =>
        match index.get? t with
        | some j => out := out.push (some j)
        | none =>
          let j := states.size
          index := index.insert t j
          states := states.push t
          out := out.push (some j)
    succ := succ.push out
    if states.size > limit then return .error "too many states"
    i := i + 1
  return .ok { states, succ }

/-- Strongly connected components of the states `inSub` keeps, by every step between them
(Kosaraju, iterative). The components come out in topological order: `order[k]` is the k-th. -/
def sccs (n : Nat) (inSub : Array Bool) (succ : Array (Array Nat)) : Array Nat × Nat := Id.run do
  let mut visited := Array.replicate n false
  let mut order : Array Nat := #[]
  for root in [0:n] do
    if inSub[root]! && !visited[root]! then
      visited := visited.set! root true
      let mut stack : Array (Nat × Nat) := #[(root, 0)]
      while !stack.isEmpty do
        let (u, k) := stack.back!
        let es := succ[u]!
        if k < es.size then
          stack := stack.set! (stack.size - 1) (u, k + 1)
          let v := es[k]!
          if inSub[v]! && !visited[v]! then
            visited := visited.set! v true
            stack := stack.push (v, 0)
        else
          order := order.push u
          stack := stack.pop
  let mut pred : Array (Array Nat) := Array.replicate n #[]
  for u in [0:n] do
    if inSub[u]! then
      for v in succ[u]! do
        if inSub[v]! then pred := pred.modify v (·.push u)
  let none := n
  let mut comp := Array.replicate n none
  let mut count := 0
  let mut idx := order.size
  while idx > 0 do
    idx := idx - 1
    let root := order[idx]!
    if comp[root]! == none then
      comp := comp.set! root count
      let mut work : Array Nat := #[root]
      while !work.isEmpty do
        let u := work.back!
        work := work.pop
        for v in pred[u]! do
          if comp[v]! == none then
            comp := comp.set! v count
            work := work.push v
      count := count + 1
  return (comp, count)

/-- A ranking for `wait`, by state (`rank * 256 + help`), or the component with no helpful action. -/
def rank (cfg : Cfg) (g : Graph) (wait : St → Bool) : Except String (Array Nat) := Id.run do
  let acts := (actsAll cfg).toArray
  let n := g.states.size
  let waits := g.states.map wait
  let succIdx : Array (Array Nat) := g.succ.map (·.filterMap id)
  let (comp, count) := sccs n waits succIdx
  -- Components in topological order: a step between two goes from a lower number to a higher.
  let mut members : Array (Array Nat) := Array.replicate count #[]
  for u in [0:n] do
    if waits[u]! then members := members.modify comp[u]! (·.push u)
  let mut help : Array Nat := Array.replicate count 0
  for c in [0:count] do
    let us := members[c]!
    -- Classes taken by a step inside the component.
    let mut taken : Array Act := #[]
    for u in us do
      for k in [0:acts.size] do
        if let some v := g.succ[u]![k]! then
          if waits[v]! && comp[v]! == c then
            if let some key := fairKey acts[k]! then
              if !taken.contains key then taken := taken.push key
    let ok (k : Nat) : Bool :=
      match fairKey acts[k]! with
      | none => false
      | some key => !taken.contains key && us.all (fun u => g.succ[u]![k]!.isSome)
    match (List.range acts.size).find? ok with
    | some k => help := help.set! c k
    | none => return .error s!"no helpful action: a weakly fair run waits forever ({us.size} states)"
  let mut out : Array Nat := #[]
  for u in [0:n] do
    if waits[u]! then
      let c := comp[u]!
      out := out.push ((count - c) * 256 + help[c]!)
    else out := out.push 0
  return .ok out

/-- A row's successors under `actsAll`, packed as `Row.succ`. -/
def succOf (g : Graph) (i : Nat) : Nat :=
  pack succBase ((g.succ[i]!).toList.map (fun o => match o with | some j => j + 1 | none => 0))

/-- Lean source for a list, `perLine` items a line. -/
def listSrc (items : Array String) (perLine : Nat := 8) : String := Id.run do
  let mut out := "["
  let mut k := 0
  for x in items do
    if k > 0 then out := out ++ (if k % perLine == 0 then ",\n  " else ", ")
    out := out ++ x
    k := k + 1
  return out ++ "]"

/-- Checks the sizes fit their bases. -/
def sane (cfg : Cfg) (g : Graph) : Except String Unit := do
  if (actsAll cfg).length ≥ 256 then throw "too many actions"
  if g.states.size ≥ succBase then throw "too many states"

/-! ### States as Lean terms -/

def optSrc : Option Nat → String
  | none => "none"
  | some n => s!"(some {n})"

def natsSrc (l : List Nat) : String := "[" ++ ", ".intercalate (l.map toString) ++ "]"

def phaseSrc : Phase → String
  | .waiting => ".waiting" | .alive => ".alive" | .stopped => ".stopped" | .dead => ".dead"
  | .over => ".over"

def tsSrc : TS → String
  | .pending => ".pending" | .running c => s!"(.running {c})" | .timedOut => ".timedOut"
  | .done => ".done" | .failed => ".failed" | .gone => ".gone"

def taskSrc (t : Task) : String := s!"⟨{tsSrc t.st}, {t.attempt}, {optSrc t.dying}⟩"

def cpuSrc (x : Cpu) : String :=
  let sl := match x.slot with
    | none => "none"
    | some sl => s!"(some ⟨{sl.owner}, {sl.draining}⟩)"
  s!"⟨{optSrc x.lock}, {optSrc x.grant}, {sl}⟩"

def opSrc (o : Op) : String :=
  s!"⟨{phaseSrc o.phase}, [" ++ ", ".intercalate (o.tasks.map taskSrc) ++ "]⟩"

/-- A state as a Lean term (`St.mk`, every field). -/
def stSrc (s : St) : String :=
  "⟨[" ++ ", ".intercalate (s.cpus.map cpuSrc) ++ "], [" ++ ", ".intercalate (s.ops.map opSrc) ++
  s!"], {natsSrc s.order}, {s.drains}, {s.crashes}, {optSrc s.poolLock}, {s.marks}, {s.tstp}, " ++
  s!"{s.held}, {s.halted}, {s.zs}, {s.served}, {s.window}, {natsSrc s.clock}, {s.ran}⟩"

/-- The rows `a + b * k` (`k < count`) of `rows` as a Braun tree (`RTree`): row `a` at the root,
the odd ones to the left, the even ones to the right. -/
partial def braunSrc (rows : Array String) (a b count : Nat) : String :=
  if count == 0 then ".leaf" else
  s!"(.node {rows[a]!}\n {braunSrc rows (a + b) (2 * b) (count / 2)}\n {braunSrc rows (a + 2 * b) (2 * b) ((count - 1) / 2)})"

/-- The same tree as a value, to check it before writing it. -/
partial def braun (rows : Array Row) (a b count : Nat) : RTree :=
  if count == 0 then .leaf else
  .node rows[a]! (braun rows (a + b) (2 * b) (count / 2)) (braun rows (a + 2 * b) (2 * b) ((count - 1) / 2))

/-- The tree cut at `depth` levels: each node above the cut a named row (`R_path`), each subtree at
the cut a named tree (`T_path`), so the kernel checks each piece as a theorem of its own and keeps
little in memory at a time. Gives the definitions, the pieces (`true` for a row), and the tree's
expression over the names. -/
partial def splitSrc (rows : Array String) (a b count depth : Nat) (path : String) :
    Array String × Array (Bool × String) × String :=
  if count == 0 then (#[], #[], ".leaf")
  else if depth == 0 then
    (#[s!"noncomputable def T_{path} : RTree :=\n  {braunSrc rows a b count}\n"], #[(false, s!"T_{path}")], s!"T_{path}")
  else
    let (dl, pl, el) := splitSrc rows (a + b) (2 * b) (count / 2) (depth - 1) (path ++ "l")
    let (dr, pr, er) := splitSrc rows (a + 2 * b) (2 * b) ((count - 1) / 2) (depth - 1) (path ++ "r")
    (#[s!"noncomputable def R_{path} : Row :=\n  {rows[a]!}\n"] ++ dl ++ dr,
     #[(true, s!"R_{path}")] ++ pl ++ pr, s!"(.node R_{path} {el} {er})")

end Cpuq.CertGen
