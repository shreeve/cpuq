/-
Exhaustive search of the model: every state `step` reaches from `init`, breadth first, with
what must hold of each state, of each step, and two liveness checks over the whole graph.

It runs when `lake build` elaborates `Checks.lean` (`#eval`), not as a proof: it covers the
configurations it is given and says nothing past them. The proofs (`Safety.lean`,
`Liveness.lean`) say the general case.

The checks, by name (README lists which guarantee each one is):
- state: `S1 holder`, `S1 grant`, `S3 cap`, `S4 K`, `S5 twice`, `S1' shared`, `S1' unheld`,
  `D count`, `L2 idle` (a CPU no one holds while an operation wants one, and no pass or
  accept can happen until some task ends; a release, a finish and a drain's registration
  run a pass), `CS stuck` (the pool lock's holder waits for a lock
  that only the pool lock lets go: a deadlock) and `Z stuck` (a parent stopped by the kernel
  that no SIGCONT will continue);
- step: `F1 drain not owed`,
  `F6 drain not for the head`, `F6 giver ahead` (after the drain the giver ranks before the
  waiter it drained for, so the token may come back to the giver);
- graph: `L3 never` (from some state, no run at all gets a waiter that holds nothing a CPU) and
  `L3 fair` (a weakly fair run, with no more crashes, where such a waiter never gets one).
-/
import CpuqModel.Model
import Std.Data.HashMap

namespace Cpuq

def cpuIds (cfg : Cfg) : List Nat := List.range cfg.cpus

def taskIds (cfg : Cfg) (o : Nat) : List Nat := List.range (cfg.op o).tasks

/-- A CPU no one holds and no living waiter was handed. -/
def physFree (s : St) (x : Cpu) : Bool :=
  x.lock.isNone && match x.grant with
    | none => true
    | some h => !s.isAlive h

def stateFails (cfg : Cfg) (s : St) (enabled : List (Act × St)) : List String :=
  let cs := cpuIds cfg
  let os := opIds cfg
  let holder := cs.all (fun c =>
    let x := s.cpu c
    (match x.lock with
     | some o => ownsC o x && s.isAlive o
     | none => true) &&
    (match x.slot with
     | some sl => !s.isAlive sl.owner || x.lock == some sl.owner
     | none => true))
  let grant := cs.all (fun c => (s.cpu c).grant.isNone || (s.cpu c).lock.isNone)
  let cap := os.all (fun o =>
    !((s.op o).phase == .alive || (s.op o).phase == .stopped) ||
    decide (s.owned o + s.grants o ≤ (cfg.op o).cap))
  let kb := cs.all (fun c => match (s.cpu c).slot with
    | some sl => decide (s.runningOn sl.owner c ≤ (cfg.op sl.owner).K)
    | none => true)
  let count := s.drains == s.cpus.countP drainingC
  let onCpu (o i c : Nat) : Bool :=
    (s.task o i).st == .running c || (s.task o i).dying == some c
  let twice := os.all (fun o => (taskIds cfg o).all (fun i =>
    (s.task o i).dying.isNone || !(cs.any (fun c => (s.task o i).st == .running c))))
  let shared := os.all (fun o => (taskIds cfg o).all (fun i => cs.all (fun c =>
    !onCpu o i c || match (s.cpu c).lock with
      | some o' => o' == o
      | none => true)))
  let unheld := os.all (fun o => (taskIds cfg o).all (fun i => cs.all (fun c =>
    !onCpu o i c || (s.isAlive o && (s.cpu c).lock == some o) ||
      ((s.op o).phase == .dead && (s.cpu c).lock != some o))))
  let idle :=
    cs.any (fun c => physFree s (s.cpu c)) &&
    os.any (fun o => s.isAlive o && decide (demand cfg s o > 0)) &&
    !enabled.any (fun (a, _) => match a with
      | .handout | .accept _ _ | .release _ _ | .finish _ | .mark _ => true
      | _ => false)
  let csStuck := s.poolLock.isSome && !enabled.any (fun (a, _) => match a with
      | .mark _ => true
      | _ => false)
  let zStuck := os.any (fun o => bit s.halted o && !bit s.held o)
  (if holder then [] else ["S1 holder"]) ++
  (if grant then [] else ["S1 grant"]) ++
  (if cap then [] else ["S3 cap"]) ++
  (if kb then [] else ["S4 K"]) ++
  (if count then [] else ["D count"]) ++
  (if twice then [] else ["S5 twice"]) ++
  (if shared then [] else ["S1' shared"]) ++
  (if unheld then [] else ["S1' unheld"]) ++
  (if idle then ["L2 idle"] else []) ++
  (if csStuck then ["CS stuck"] else []) ++
  (if zStuck then ["Z stuck"] else [])

/-- The yield rule of FINAL-PLAN rule 6, whatever the rules searched. -/
def yieldShare (cfg : Cfg) (s : St) (o h : Nat) : Bool :=
  yieldTo { cfg with rules := { cfg.rules with shareRule := true } } s o h

def stepFails (cfg : Cfg) (s : St) (a : Act) (s' : St) : List String :=
  match a with
  | .drain o _ =>
    -- While a `cpuq drain` lives, every other operation empties its CPUs: not a line drain.
    if s.marks != 0 && !drainOp cfg o then [] else
    (if decide (s.drains < need cfg s) then [] else ["F1 drain not owed"]) ++
    (match head cfg s with
     | some h =>
       (if h != o && yieldShare cfg s o h then [] else ["F6 drain not for the head"]) ++
       (if h != o && ahead cfg (if cfg.rules.renewAtRelease then { s' with order := renewed s' o } else s') o h
        then ["F6 giver ahead"] else [])
     | none => ["F6 drain not for the head"])
  | _ => []

/-- A waiter that holds nothing. -/
def starving (cfg : Cfg) (s : St) (w : Nat) : Bool :=
  s.isAlive w && decide (demand cfg s w > 0) && s.owned w + s.grants w == 0

/-- Steps of the environment that the liveness checks leave out: no more crashes, kills or
Ctrl-Z (FINAL-PLAN's liveness assumptions). A parent acting on a Ctrl-Z already received, and
the SIGCONT owed for it, are not left out. -/
def progressAct : Act → Bool
  | .crash _ | .kill _ | .tstp _ => false
  | _ => true

/-- The weak-fairness class of a step, or none for steps nothing forces: an arrival (a drain's
begins with `enter`), a timeout (optional), a crash, a kill, a Ctrl-Z. A task's exit is one class whether it passes or
fails (A-term: every task ends). A SIGCONT is weakly fair while one is owed (A-cont: whoever
sent a Ctrl-Z continues the run). -/
def fairKey : Act → Option Act
  | .exit o i _ => some (.exit o i true)
  | .timeout _ _ | .arrive _ | .enter _ | .crash _ | .kill _ | .tstp _ => none
  | a => some a

structure Report where
  states : Nat
  edges : Nat
  fails : Array (String × List Act)

def Report.names (r : Report) : List String := r.fails.toList.map (·.1)

def Report.summary (r : Report) : String :=
  if r.fails.isEmpty then s!"ok: {r.states} states, {r.edges} steps"
  else s!"FAILED ({r.states} states): " ++ String.intercalate ", " r.names

partial def traceOf (parent : Array (Nat × Option Act)) (i : Nat) : List Act :=
  match parent[i]! with
  | (_, none) => []
  | (p, some a) => traceOf parent p ++ [a]

/-- Strongly connected components of the subgraph on `inSub` (Kosaraju, iterative). -/
def sccs (n : Nat) (inSub : Array Bool) (succ : Array (Array (Nat × Act))) : Array Nat := Id.run do
  -- First pass: finishing order.
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
          let v := es[k]!.1
          if inSub[v]! && !visited[v]! && progressAct es[k]!.2 then
            visited := visited.set! v true
            stack := stack.push (v, 0)
        else
          order := order.push u
          stack := stack.pop
  -- Reverse edges.
  let mut pred : Array (Array Nat) := Array.replicate n #[]
  for u in [0:n] do
    if inSub[u]! then
      for (v, a) in succ[u]! do
        if inSub[v]! && progressAct a then pred := pred.modify v (·.push u)
  -- Second pass, in reverse finishing order.
  let none := n
  let mut comp := Array.replicate n none
  let mut idx := order.size
  while idx > 0 do
    idx := idx - 1
    let root := order[idx]!
    if comp[root]! == none then
      comp := comp.set! root root
      let mut work : Array Nat := #[root]
      while !work.isEmpty do
        let u := work.back!
        work := work.pop
        for v in pred[u]! do
          if comp[v]! == none then
            comp := comp.set! v root
            work := work.push v
  return comp

/-- A shortest run from `src` to `dst` through states `inside` accepts. -/
def pathIn (succ : Array (Array (Nat × Act))) (inside : Nat → Bool) (src dst : Nat) : List Act := Id.run do
  if src == dst then return []
  let mut back : Std.HashMap Nat (Nat × Act) := {}
  let mut q : Array Nat := #[src]
  let mut qi := 0
  while qi < q.size do
    let u := q[qi]!
    qi := qi + 1
    for (v, a) in succ[u]! do
      if inside v && progressAct a && !back.contains v && v != src then
        back := back.insert v (u, a)
        q := q.push v
    if back.contains dst then
      let mut x := dst
      let mut out : List Act := []
      while x != src do
        let (p, b) := back.getD x (src, .finish 0)
        out := b :: out
        x := p
      return out
  return []

def explore (cfg : Cfg) (limit : Nat := 4000000) : Report := Id.run do
  let s0 := init cfg
  let mut index : Std.HashMap St Nat := {}
  index := index.insert s0 0
  let mut states : Array St := #[s0]
  let mut parent : Array (Nat × Option Act) := #[(0, none)]
  let mut succ : Array (Array (Nat × Act)) := #[]
  let mut fails : Array (String × List Act) := #[]
  let mut edges := 0
  let mut i := 0
  while i < states.size do
    let s := states[i]!
    let ns := next cfg s
    for name in stateFails cfg s ns do
      if !fails.any (·.1 == name) then fails := fails.push (name, traceOf parent i)
    let mut out : Array (Nat × Act) := #[]
    for (a, n) in ns do
      edges := edges + 1
      for name in stepFails cfg s a n do
        if !fails.any (·.1 == name) then fails := fails.push (name, traceOf parent i ++ [a])
      match index.get? n with
      | some j => out := out.push (j, a)
      | none =>
        let j := states.size
        index := index.insert n j
        states := states.push n
        parent := parent.push (i, some a)
        out := out.push (j, a)
    succ := succ.push out
    if states.size > limit then
      return { states := states.size, edges, fails := fails.push ("too many states", []) }
    i := i + 1
  let n := states.size
  -- Liveness, for each operation `w`.
  for w in opIds cfg do
    let starve := states.map (starving cfg · w)
    -- L3 never: states from which no run without crashes, kills or stops serves w.
    let mut pred : Array (Array Nat) := Array.replicate n #[]
    for u in [0:n] do
      for (v, a) in succ[u]! do
        if progressAct a then pred := pred.modify v (·.push u)
    let mut can := starve.map (!·)
    let mut work : Array Nat := #[]
    for u in [0:n] do
      if can[u]! then work := work.push u
    while !work.isEmpty do
      let v := work.back!
      work := work.pop
      for u in pred[v]! do
        if !can[u]! then
          can := can.set! u true
          work := work.push u
    match (List.range n).find? (fun u => !can[u]!) with
    | some u =>
      if !fails.any (·.1 == "L3 never") then
        fails := fails.push ("L3 never", traceOf parent u ++ [.finish (1000 + w)])
    | none => pure ()
    -- L3 fair: a strongly connected set of starving states where every step class enabled
    -- in all of them is also taken inside it.
    let comp := sccs n starve succ
    let mut members : Std.HashMap Nat (Array Nat) := {}
    for u in [0:n] do
      if starve[u]! then members := members.insert comp[u]! ((members.getD comp[u]! #[]).push u)
    for (root, us) in members.toList do
      let inside (v : Nat) : Bool := starve[v]! && comp[v]! == root
      let mut taken : Array Act := #[]
      let mut loop := false
      for u in us do
        for (v, a) in succ[u]! do
          if inside v && progressAct a then
            loop := true
            if let some k := fairKey a then
              if !taken.contains k then taken := taken.push k
      if loop then
        let enabledAt (u : Nat) : Array Act := (succ[u]!.filterMap (fairKey ·.2))
        let mut always := enabledAt us[0]!
        for u in us do
          let e := enabledAt u
          always := always.filter (e.contains ·)
        if always.all (taken.contains ·) then
          if !fails.any (·.1 == "L3 fair") then
            -- The run: reach the set, then go round it taking every class enabled throughout.
            let u0 := us[0]!
            let mut cur := u0
            let mut cyc : List Act := []
            -- Every class enabled at the start is either taken on the way round or meets a
            -- state where it is not enabled; nothing else can be enabled all the way round.
            for k in enabledAt u0 do
              if taken.contains k then
                let mut edge : Option (Nat × Nat × Act) := none
                for u in us do
                  if edge.isNone then
                    for (v, a) in succ[u]! do
                      if edge.isNone && inside v && progressAct a && fairKey a == some k then
                        edge := some (u, v, a)
                if let some (x, v, a) := edge then
                  cyc := cyc ++ pathIn succ inside cur x ++ [a]
                  cur := v
              else
                if let some x := us.find? (fun x => !(enabledAt x).contains k) then
                  cyc := cyc ++ pathIn succ inside cur x
                  cur := x
            cyc := cyc ++ pathIn succ inside cur u0
            fails := fails.push ("L3 fair",
              traceOf parent u0 ++ [.finish (2000 + w), .finish 999] ++ cyc)
  return { states := n, edges, fails }

end Cpuq

namespace Cpuq

def opName (o : Nat) : String := String.singleton (Char.ofNat (65 + o))

/-- One line of a state: who holds each CPU, and the line. -/
def brief (cfg : Cfg) (s : St) : String :=
  let cs := (cpuIds cfg).map (fun c =>
    let x := s.cpu c
    let who := match x.slot with
      | some sl => opName sl.owner ++ (if sl.draining then "~" else "") ++
          (if x.lock == some sl.owner then "" else "(dead)") ++
          s!"[{s.runningOn sl.owner c}]"
      | none => "-"
    let g := match x.grant with
      | some h => s!" →{opName h}"
      | none => ""
    s!"cpu{c}:{who}{g}")
  let hd := match head cfg s with
    | some h => opName h
    | none => "none"
  let lk := match s.poolLock with
    | some o => s!", pool lock {opName o}"
    | none => ""
  let mk := if s.marks != 0 then s!", marks {s.marks}" else ""
  String.intercalate " " cs ++ s!" | head {hd}, drains {s.drains}{lk}{mk}"

def actName : Act → String
  | .arrive o => s!"{opName o} arrives"
  | .exit o i ok => s!"{opName o}{i+1} {if ok then "ends" else "fails"}"
  | .timeout o i => s!"{opName o}{i+1} times out"
  | .gone o i => s!"{opName o}{i+1}'s old attempt exits"
  | .refill o c => s!"{opName o} refills cpu{c}"
  | .release o c => s!"{opName o} releases cpu{c}"
  | .handout => "hand-out pass"
  | .accept o c => s!"{opName o} accepts cpu{c}"
  | .drain o c => s!"{opName o} drains cpu{c}"
  | .undrain o c => s!"{opName o} undrains cpu{c}"
  | .consolidate o i d => s!"{opName o}{i+1} moves to cpu{d}"
  | .kill o => s!"cpuq kill {opName o}"
  | .crash o => s!"{opName o}'s parent is SIGKILLed"
  | .stop o => s!"{opName o} gives its CPUs back for a Ctrl-Z"
  | .cont o => s!"SIGCONT to {opName o}"
  | .enter o => s!"{opName o} takes the pool lock"
  | .mark o => s!"{opName o} takes the drain mark and registers"
  | .tstp o => s!"Ctrl-Z to {opName o}"
  | .halt o => s!"{opName o} raises SIGSTOP on itself"
  | .finish o =>
    if o ≥ 2000 then s!"(a weakly fair run that never gets {opName (o - 2000)} a CPU:)"
    else if o ≥ 1000 then s!"(from here no run gets {opName (o - 1000)} a CPU)"
    else if o == 999 then "(then, forever:)" else s!"{opName o} finishes"

/-- A failure's run, step by step, with the state after each step. -/
def narrate (cfg : Cfg) (name : String) : String :=
  let r := explore cfg
  match r.fails.find? (·.1 == name) with
  | none => s!"{name}: not found"
  | some (_, tr) => Id.run do
    let mut s := init cfg
    let mut out := s!"{name}:\n"
    for a in tr do
      match move cfg s a with
      | some s' =>
        s := s'
        out := out ++ s!"  {actName a}: {brief cfg s}\n"
      | none => out := out ++ s!"  {actName a}\n"
    return out

end Cpuq
