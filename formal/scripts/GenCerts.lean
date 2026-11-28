/-
Writes the certificates in `CpuqModel/Certs/`: for each configuration, the search's graph and a
ranking for each waiting condition, with the theorems that check them (`decide +kernel`).

    cd formal && cpuq run --label cpuq:lean -t 20m -- lake env lean --run scripts/GenCerts.lean

Run it after a change to the model or the rules; then `lake build` checks what it wrote.
-/
import CpuqModel.CertGen
import CpuqModel.Checks

open Cpuq Cpuq.CertGen Cpuq.Checks

/-- A waiting condition: its name in the file, its source, and the function. -/
structure Wait where
  name : String
  src : String
  f : St → Bool

structure Spec where
  /-- The module name under `CpuqModel.Certs`. -/
  name : String
  doc : String
  /-- The configuration's source (it must elaborate in the generated file) and its value. -/
  src : String
  cfg : Cfg
  waits : List Wait

def L3 (cfg : Cfg) (w : Nat) : Wait :=
  { name := s!"L3_{w}", src := s!"(starving cfg · {w})", f := (starving cfg · w) }

def D (cfg : Cfg) (d : Nat) : Wait :=
  { name := s!"D_{d}", src := s!"(gathering cfg · {d})", f := (gathering cfg · d) }

def spec (name doc src : String) (cfg : Cfg) (l3 dr : List Nat) : Spec :=
  { name, doc, src, cfg, waits := l3.map (L3 cfg) ++ dr.map (D cfg) }

def waiterStream1 : Cfg :=
  { cpus := 1, rules := .released
    ops := [drainOn 1 1, { proj := 0, tasks := 1, again := true }, { proj := 2, tasks := 1, again := true }] }

/-- The certificates, in the order they import each other (one at a time: each takes the kernel
minutes and gigabytes). -/
def specs : List Spec := [
  spec "StreamOne" "1 CPU: a one-task run and two `-c 1` drains that come back after each finish (`streamCfg`, the\nconfiguration of `code0320_stream_starves`), under the released rules."
    "streamCfg .released" (streamCfg .released) [0] [1, 2],
  spec "StreamAll" "1 CPU: a run with endless work and two `--all` drains that come back after each finish."
    "Checks.streamOf 1 Checks.endless Checks.wholeOn .released" (streamOf 1 endless wholeOn .released) [0] [1, 2],
  spec "WaiterStream" "1 CPU: a `-c 1` drain and one-task runs that come back after each finish."
    "{ cpus := 1, rules := .released, ops := [Checks.drainOn 1 1, { proj := 0, tasks := 1, again := true }, { proj := 2, tasks := 1, again := true }] }"
    waiterStream1 [1, 2] [0],
  spec "UrgentHolds" "2 CPUs, no drain: an urgent operation with endless work holds a CPU of project P, an operation\nof project Q the other, and P's second operation waits (Finding 7's shape: it starves under\n0.30.2), under the released rules."
    "Checks.urgentHolds .released" (urgentHolds .released) [0, 1, 2] []
]

def emit (sp : Spec) (prev : Option String) : IO Unit := do
  match build sp.cfg with
  | .error e => throw (IO.userError s!"{sp.name}: {e}")
  | .ok g =>
    match sane sp.cfg g with
    | .error e => throw (IO.userError s!"{sp.name}: {e}")
    | .ok _ => pure ()
    let n := g.states.size
    let mut ranks : Array (Array Nat) := #[]
    for w in sp.waits do
      match rank sp.cfg g w.f with
      | .error e => throw (IO.userError s!"{sp.name} {w.name}: {e}")
      | .ok R => ranks := ranks.push R
    let rowAt (i : Nat) : Row :=
      { st := g.states[i]!, succ := succOf g i, rank := (ranks.map (·[i]!)).toList }
    let rows := (Array.range n).map rowAt
    let T := braun rows 0 1 n
    if !graphOk sp.cfg T then throw (IO.userError s!"{sp.name}: graphOk fails")
    for (w, c) in sp.waits.zipIdx do
      if !rankOk sp.cfg T w.f c then throw (IO.userError s!"{sp.name} {w.name}: rankOk fails")
    let rowSrc (r : Row) : String := s!"⟨{stSrc r.st}, {r.succ}, {natsSrc r.rank}⟩"
    let mut src := s!"/-\n{sp.doc}\n\nWritten by `scripts/GenCerts.lean`: the search's graph ({n} states, every action of\n`actsAll`) and a ranking for each waiting condition. Do not edit; regenerate.\n-/\nimport CpuqModel.Cert\nimport CpuqModel.Checks\n{match prev with | some p => s!"import CpuqModel.Certs.{p}\n" | none => ""}\nnamespace Cpuq.Certs.{sp.name}\n\nset_option maxRecDepth 100000\nset_option maxHeartbeats 0\nset_option linter.unusedSimpArgs false\n\n"
    src := src ++ s!"def cfg : Cfg := {sp.src}\n\n"
    -- Cut the tree so each piece holds about 200 rows.
    let mut depth := 0
    while n / 2 ^ depth > 200 do depth := depth + 1
    let (defs, pieces, expr) := splitSrc (rows.map rowSrc) 0 1 n depth "o"
    for d in defs do src := src ++ d ++ "\n"
    src := src ++ s!"noncomputable def T : RTree :=\n  {expr}\n\n"
    -- `T.all p` from each piece.
    let hyp (i : Nat) (pc : Bool × String) : String :=
      if pc.1 then s!"(h{i} : p {pc.2} = true)" else s!"(h{i} : {pc.2}.all p = true)"
    let hyps := " ".intercalate ((pieces.zipIdx.map fun (pc, i) => hyp i pc).toList)
    let hnames := ", ".intercalate ((pieces.zipIdx.map fun (_, i) => s!"h{i}").toList)
    src := src ++ s!"theorem all_T \{p : Row → Bool} {hyps} :\n    T.all p = true := by\n  simp only [T, RTree.all_node, RTree.all_leaf, {hnames}, Bool.and_true]\n\n"
    let pieceThms (pre pred : String) : String := Id.run do
      let mut out := ""
      for (pc, i) in pieces.zipIdx do
        let stmt := if pc.1 then s!"{pred} {pc.2} = true" else s!"{pc.2}.all ({pred}) = true"
        out := out ++ s!"theorem {pre}{i} : {stmt} := by decide +kernel\n"
      return out
    let args (pre : String) : String := " ".intercalate ((pieces.zipIdx.map fun (_, i) => s!"{pre}{i}").toList)
    src := src ++ pieceThms "g" "graphRow cfg T"
    src := src ++ "\ntheorem root : rootOk cfg T = true := by decide +kernel\n\n"
    src := src ++ s!"theorem graph : graphOk cfg T = true := by\n  rw [graphOk, root, Bool.true_and]\n  exact all_T {args "g"}\n"
    for (w, c) in sp.waits.zipIdx do
      src := src ++ "\n" ++ pieceThms s!"r{c}_" s!"rankRow cfg T {w.src} {c}"
      src := src ++ s!"\ntheorem rank_{w.name} : rankOk cfg T {w.src} {c} = true :=\n  all_T {args s!"r{c}_"}\n"
    src := src ++ s!"\nend Cpuq.Certs.{sp.name}\n"
    IO.FS.writeFile s!"CpuqModel/Certs/{sp.name}.lean" src
    IO.println s!"{sp.name}: {n} states, {(actsAll sp.cfg).length} actions, {sp.waits.length} rankings"

def main (args : List String) : IO Unit := do
  let mut prev : Option String := none
  for sp in specs do
    if args.isEmpty || args.contains sp.name then emit sp prev
    prev := some sp.name
