/-
cpuq's CPU-sharing protocol (FINAL-PLAN.md, "How CPUs are shared" and "Robustness"), as one
executable step function over finite data.

The same `step` is searched exhaustively at small sizes (`Explore.lean`, `Checks.lean`) and
proved about in general (`Safety.lean`, `Liveness.lean`). `Rules` switches between the rules
FINAL-REPORT-1 wrote (review2-formal.md's state machine, which its counterexamples break),
FINAL-PLAN's rules, and two further fixes this model found it needs.

What a CPU is here: its token file's flock (`lock`, the parent that holds it), its grant file
(`grant`, the waiter it was handed to), and its record (`slot`: the operation the token file
names, and whether that slot is draining). An operation's tasks carry their own state; the
processes in a slot are the tasks whose state is `running c`. A task's `dying` is an earlier
attempt that was sent TERM by its timeout and has not yet exited.

Each action is one atomic step. Steps that change shared state run under the admission lock in
cpuq, and their on-disk effect is a single rename, so atomic steps are faithful to them; a
parent's own steps (refill, reap) are atomic in that parent.
-/

namespace Cpuq

/-- Where an operation's parent is: not yet started, running its loop, stopped by Ctrl-Z,
killed (SIGKILL: no clean-up of its own), or finished (its work done, or `cpuq kill`). -/
inductive Phase where
  | waiting | alive | stopped | dead | over
  deriving DecidableEq, Repr, Hashable

/-- A task's state. `timedOut`: its attempt was sent TERM and is still dying (`Task.dying`);
whether it is retried is decided when it exits. `gone`: killed with its operation. -/
inductive TS where
  | pending | running (c : Nat) | timedOut | done | failed | gone
  deriving DecidableEq, Repr, Hashable

structure Task where
  st : TS := .pending
  attempt : Nat := 1
  /-- The CPU of an earlier attempt that was sent TERM and has not exited yet. -/
  dying : Option Nat := none
  deriving DecidableEq, Repr, Hashable

structure Op where
  phase : Phase := .over
  tasks : List Task := []
  deriving DecidableEq, Repr, Hashable

/-- A token file's record: the operation that holds the slot, and whether it drains. -/
structure Slot where
  owner : Nat
  draining : Bool := false
  deriving DecidableEq, Repr, Hashable

structure Cpu where
  /-- The parent holding the token's flock. The kernel drops it when that parent dies. -/
  lock : Option Nat := none
  /-- The grant file: the waiter this free token was handed to. -/
  grant : Option Nat := none
  /-- The token file's record. It outlives a parent killed by SIGKILL (its orphans). -/
  slot : Option Slot := none
  deriving DecidableEq, Repr, Hashable

structure St where
  cpus : List Cpu
  ops : List Op
  /-- Tickets: the operations that arrived, oldest ticket first. -/
  order : List Nat
  /-- The shared count of slots draining (rule 6), kept under the admission lock. -/
  drains : Nat
  /-- How many more crashes (SIGKILL of a parent) the search may take. -/
  crashes : Nat
  deriving DecidableEq, Repr, Hashable, Inhabited

/-- One operation: `cpuq run -n tasks -c cap -x K -r retries`, its project, whether it is
urgent, and `forever`: each task that passes starts over, so the work never runs out (a
stand-in for an operation with far more tasks than the run is long). -/
structure OpCfg where
  proj : Nat := 0
  cap : Nat := 3
  K : Nat := 1
  tasks : Nat := 1
  retries : Nat := 0
  urgent : Bool := false
  forever : Bool := false
  deriving Repr

/-- The rule set. Each switch is one fix; `Rules.report1` has them all off. -/
structure Rules where
  /-- Every operation with work left stays in the line and takes every token it may (team 2,
  F3; FINAL-PLAN rule 4). Off: only an operation with no slot registers, and an operation with
  slots tries once for a free token after a reap. -/
  standing : Bool
  /-- One shared count of drains owed, drain only for the head, a draining slot counts as given
  up, the giver gets a fresh ticket (F1, F6; rule 6). Off: an operation drains whenever some
  waiter outranks it by the tie rule. -/
  ledger : Bool
  /-- The yield rule on project shares after the transfer, or the waiter holds nothing (F2;
  rule 6). Off: "a waiter at least 2 slots behind". -/
  shareRule : Bool
  /-- A grant is valid only while its waiter is alive (F4; rule 5). Off: a grant stays. -/
  validGrant : Bool
  /-- Whoever takes a token first kills a dead operation's leftovers on it (F5; Robustness). -/
  reclaim : Bool
  /-- A timed-out task is retried when its attempt has exited, not when TERM is sent. -/
  retryAtReap : Bool
  /-- A slot is empty only when its timed-out attempts have exited too. -/
  releaseWaitsDying : Bool
  /-- An operation holding nothing ranks before every holder (after urgent). -/
  zeroFirst : Bool
  /-- An operation drains only if the waiter still ranks before it after the drain. -/
  giverBehind : Bool
  /-- The giver's ticket is renewed when it gives a CPU back (release), not when it starts to
  drain (`giveBackEmpty` in src/op.zig). -/
  renewAtRelease : Bool := false
  /-- `giverBehind` compares as if the giver already had its renewed ticket. -/
  behindFresh : Bool := false
  /-- A stopped operation stays in the line with what it wants, and a grant to it stays valid
  (its file stays locked while it is stopped). -/
  stoppedWaits : Bool := false
  /-- The line counts only living (alive or stopped) operations; a dead one's leftovers don't
  count (the pool's scan drops it). -/
  liveCounts : Bool := false
  /-- One giver, as src/pool.zig's `giver` picks it: the project holding the most for its
  weight, then the operation keeping the most, then the newest ticket. -/
  oneGiver : Bool := false
  /-- A grant to a stopped operation stays valid (its file stays locked), even when it is out of
  the line. -/
  stoppedGrants : Bool := false
  /-- A drain no longer owed is cancelled (`Act.undrain`). src/pool.zig never cancels one. -/
  undrains : Bool := true
  deriving Repr

namespace Rules

/-- FINAL-REPORT-1's rules, as review2-formal.md reads them. -/
def report1 : Rules :=
  { standing := false, ledger := false, shareRule := false, validGrant := false,
    reclaim := false, retryAtReap := true, releaseWaitsDying := true,
    zeroFirst := false, giverBehind := false }

/-- FINAL-PLAN's rules. Where the plan is silent (when a timed-out task is retried, whether a
slot with a dying attempt is empty) this takes the safe reading; `planLoose` takes the other. -/
def plan : Rules :=
  { standing := true, ledger := true, shareRule := true, validGrant := true,
    reclaim := true, retryAtReap := true, releaseWaitsDying := true,
    zeroFirst := false, giverBehind := false }

/-- FINAL-PLAN read loosely: "its place frees at once" taken to mean the retry may start and
the slot may be given back while the timed-out attempt is still dying. -/
def planLoose : Rules := { plan with retryAtReap := false, releaseWaitsDying := false }

/-- FINAL-PLAN with the two fixes this model found it needs (README, "Findings"). -/
def fixed : Rules := { plan with zeroFirst := true, giverBehind := true }

/-- The rules of src/pool.zig and src/op.zig on branch `slots` (ba33a16). -/
def pool : Rules :=
  { fixed with renewAtRelease := true, stoppedWaits := true, liveCounts := true, oneGiver := true,
               undrains := false }

/-- `pool` with the fixes this model proposes for it (README, "Findings" 4, 5 and 6), which is
the code on `slots` at 8f997ec:
`behindAfter` compares with the ticket the giver will have once it gives the CPU back, and a
stopped operation is out of the line. -/
def poolFixed : Rules := { pool with behindFresh := true, stoppedWaits := false }

/-- The code at 0d315ed: a stopped operation wants nothing, but a grant made to it before it
stopped stays valid. (8f997ec drops those grants: the code there is `poolFixed`.) -/
def pool0d315ed : Rules := { poolFixed with stoppedGrants := true }

end Rules

structure Cfg where
  cpus : Nat
  /-- Project weights, by project number; a missing weight is 1. -/
  weights : List Nat := []
  ops : List OpCfg
  rules : Rules
  /-- Crash budget: how many parents the search may kill with SIGKILL. -/
  crashes : Nat := 0
  stops : Bool := false
  kills : Bool := false
  timeouts : Bool := false

/-! ## Reading the state -/

namespace St
def cpu (s : St) (c : Nat) : Cpu := s.cpus.getD c {}
def op (s : St) (o : Nat) : Op := s.ops.getD o {}
def task (s : St) (o i : Nat) : Task := (s.op o).tasks.getD i { st := .gone }
end St

def Cfg.op (cfg : Cfg) (o : Nat) : OpCfg := cfg.ops.getD o {}
def Cfg.w (cfg : Cfg) (p : Nat) : Nat := cfg.weights.getD p 1

def ownsC (o : Nat) (x : Cpu) : Bool :=
  match x.slot with
  | some sl => sl.owner == o
  | none => false

def drainingC (x : Cpu) : Bool :=
  match x.slot with
  | some sl => sl.draining
  | none => false

def grantedC (o : Nat) (x : Cpu) : Bool := x.grant == some o
def runningC (c : Nat) (t : Task) : Bool := t.st == .running c
def pendingT (t : Task) : Bool := t.st == .pending

namespace St
/-- Slots whose record names `o`. -/
def owned (s : St) (o : Nat) : Nat := s.cpus.countP (ownsC o)
def drainOf (s : St) (o : Nat) : Nat := s.cpus.countP (fun x => ownsC o x && drainingC x)
def grants (s : St) (o : Nat) : Nat := s.cpus.countP (grantedC o)
/-- `o`'s processes on CPU `c`. -/
def runningOn (s : St) (o c : Nat) : Nat := (s.op o).tasks.countP (runningC c)
def pendingN (s : St) (o : Nat) : Nat := (s.op o).tasks.countP pendingT
def isAlive (s : St) (o : Nat) : Bool := (s.op o).phase == .alive
end St

/-- In the line's eyes: alive, or (with `stoppedWaits`) stopped. -/
def liveOp (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  s.isAlive o || (cfg.rules.stoppedWaits && (s.op o).phase == .stopped)

/-- Free places in `o`'s slots that are not draining, and in the tokens granted to it. -/
def room (cfg : Cfg) (s : St) (o : Nat) : Nat :=
  (List.range s.cpus.length).foldl (fun acc c =>
    let x := s.cpu c
    if ownsC o x && !drainingC x then acc + ((cfg.op o).K - s.runningOn o c) else acc)
    ((cfg.op o).K * s.grants o)

def ceilDiv (a b : Nat) : Nat := (a + b - 1) / b

/-- A grant to `h` still counts: `h` is in the line's eyes, or (with `stoppedGrants`) stopped. -/
def grantLive (cfg : Cfg) (s : St) (h : Nat) : Bool :=
  liveOp cfg s h || (cfg.rules.stoppedGrants && (s.op h).phase == .stopped)

/-- Slots `o` wants: no more than its ceiling C allows (slots and grants count), and no more
than its pending tasks need beyond the room it has (packing, rule 3). -/
def demand (cfg : Cfg) (s : St) (o : Nat) : Nat :=
  if liveOp cfg s o then
    min ((cfg.op o).cap - (s.owned o + s.grants o))
        (ceilDiv (s.pendingN o - room cfg s o) (cfg.op o).K)
  else 0

def validGrantC (cfg : Cfg) (s : St) (x : Cpu) : Bool :=
  match x.grant with
  | none => false
  | some h => !cfg.rules.validGrant || grantLive cfg s h

/-- A token anyone may hand out: no flock, and no grant that still counts. -/
def freeC (cfg : Cfg) (s : St) (x : Cpu) : Bool := x.lock.isNone && !validGrantC cfg s x
def freeN (cfg : Cfg) (s : St) : Nat := s.cpus.countP (freeC cfg s)

/-- Slots `o` holds as the line counts them: a draining slot counts as given up under the
ledger, and a grant counts as held. -/
def eff (cfg : Cfg) (s : St) (o : Nat) : Nat :=
  if cfg.rules.liveCounts && !((s.op o).phase == .alive || (s.op o).phase == .stopped) then 0
  else s.owned o - (if cfg.rules.ledger then s.drainOf o else 0) + s.grants o

def opIds (cfg : Cfg) : List Nat := List.range cfg.ops.length

def projEff (cfg : Cfg) (s : St) (p : Nat) : Nat :=
  (opIds cfg).foldl (fun acc o => if (cfg.op o).proj == p then acc + eff cfg s o else acc) 0

/-- Urgent class: an urgent operation while no urgent operation of its project holds a slot. -/
def urgentFirst (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  (cfg.op o).urgent && (opIds cfg).all (fun o' =>
    !((cfg.op o').urgent && (cfg.op o').proj == (cfg.op o).proj) || eff cfg s o' == 0)

/-- In the line: alive and wanting a slot (and, without `standing`, holding none). -/
def waiter (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  liveOp cfg s o && decide (demand cfg s o > 0) && (cfg.rules.standing || s.owned o == 0)

/-- `a` ranks strictly before `b` (rule 5): urgent class, then (with `zeroFirst`) holding
nothing, then project slots ÷ weight, then own slots. Ties go to the older ticket. -/
def before (cfg : Cfg) (s : St) (a b : Nat) : Bool :=
  let ua := if urgentFirst cfg s a then 0 else 1
  let ub := if urgentFirst cfg s b then 0 else 1
  let za := if cfg.rules.zeroFirst && eff cfg s a == 0 then 0 else 1
  let zb := if cfg.rules.zeroFirst && eff cfg s b == 0 then 0 else 1
  let pa := projEff cfg s (cfg.op a).proj * cfg.w (cfg.op b).proj
  let pb := projEff cfg s (cfg.op b).proj * cfg.w (cfg.op a).proj
  if ua != ub then ua < ub
  else if za != zb then za < zb
  else if pa != pb then pa < pb
  else eff cfg s a < eff cfg s b

/-- `a` is ahead of `b` in line: it ranks before, or ties and has the older ticket. -/
def ahead (cfg : Cfg) (s : St) (a b : Nat) : Bool :=
  before cfg s a b ||
    (!before cfg s b a && decide (s.order.findIdx (· == a) < s.order.findIdx (· == b)))

/-- The first waiter in line. -/
def head (cfg : Cfg) (s : St) : Option Nat :=
  s.order.foldl (fun best o =>
    if waiter cfg s o then
      match best with
      | none => some o
      | some b => if before cfg s o b then some o else best
    else best) none

/-- Drains still owed to the head: what it wants beyond the free tokens it will be handed. -/
def need (cfg : Cfg) (s : St) : Nat :=
  match head cfg s with
  | none => 0
  | some h => demand cfg s h - freeN cfg s

/-- The yield rule: may `o` give a slot to `h`? -/
def yieldTo (cfg : Cfg) (s : St) (o h : Nat) : Bool :=
  if cfg.rules.shareRule then
    let p := (cfg.op o).proj
    let q := (cfg.op h).proj
    let a := projEff cfg s p
    let b := projEff cfg s q
    (decide (a ≥ 1) && decide ((b + 1) * cfg.w p ≤ (a - 1) * cfg.w q)) || eff cfg s h == 0
  else decide (eff cfg s o ≥ eff cfg s h + 2)

/-! ## Changing the state -/

namespace St
def setCpu (s : St) (c : Nat) (x : Cpu) : St := { s with cpus := s.cpus.set c x }
def setTask (s : St) (o i : Nat) (t : Task) : St :=
  { s with ops := s.ops.set o { s.op o with tasks := (s.op o).tasks.set i t } }
def setPhase (s : St) (o : Nat) (p : Phase) : St :=
  { s with ops := s.ops.set o { s.op o with phase := p } }
def mapTasks (s : St) (o : Nat) (f : Task → Task) : St :=
  { s with ops := s.ops.set o { s.op o with tasks := (s.op o).tasks.map f } }
end St

/-- A failed attempt: retried (`-r`) while attempts are left, else final. -/
def afterFail (cfg : Cfg) (o : Nat) (t : Task) : Task :=
  if t.attempt ≤ (cfg.op o).retries then { t with st := .pending, attempt := t.attempt + 1 }
  else { t with st := .failed }

def afterOk (cfg : Cfg) (o : Nat) (t : Task) : Task :=
  if (cfg.op o).forever then { t with st := .pending, attempt := 1 } else { t with st := .done }

/-- Kill a dead operation's processes on CPU `c`. -/
def killOn (c : Nat) (t : Task) : Task :=
  { st := if t.st == .running c then .gone else t.st
    attempt := t.attempt
    dying := if t.dying == some c then none else t.dying }

def reclaimOps (c : Nat) (ops : List Op) : List Op :=
  ops.map (fun op => if op.phase == .dead then { op with tasks := op.tasks.map (killOn c) } else op)

/-- `o` takes token `c`: first kills a dead operation's leftovers on it (with `reclaim`), then
holds its flock with a fresh, empty slot. -/
def takeTok (cfg : Cfg) (s : St) (o c : Nat) : St :=
  let s1 := if cfg.rules.reclaim then { s with ops := reclaimOps c s.ops } else s
  { s1 with
    cpus := s1.cpus.set c { lock := some o, grant := none, slot := some { owner := o } }
    drains := s1.drains - (if drainingC (s.cpu c) then 1 else 0) }

def firstFree (cfg : Cfg) (s : St) : Option Nat :=
  (List.range s.cpus.length).find? (fun c => freeC cfg s (s.cpu c))

def firstPending (s : St) (o : Nat) : Option Nat :=
  (List.range (s.op o).tasks.length).find? (fun i => pendingT (s.task o i))

/-- Hand token `c` to the head, if it is free and someone waits (one grant of a pass). -/
def grantOne (cfg : Cfg) (s : St) (c : Nat) : St :=
  if freeC cfg s (s.cpu c) then
    match head cfg s with
    | some h => s.setCpu c { s.cpu c with grant := some h }
    | none => s
  else s

/-- One hand-out pass under the admission lock (rule 5): every free token in turn goes to the
head, and the line is re-ranked after each grant. -/
def handoutOver (cfg : Cfg) : St → List Nat → St
  | s, [] => s
  | s, c :: cs => handoutOver cfg (grantOne cfg s c) cs

def handout (cfg : Cfg) (s : St) : St := handoutOver cfg s (List.range s.cpus.length)

/-- Mark `o`'s slot `c` draining; under the ledger, count it and give `o` a fresh ticket. -/
def drainEff (cfg : Cfg) (s : St) (o c : Nat) : St :=
  { s.setCpu c { s.cpu c with slot := some { owner := o, draining := true } } with
    drains := s.drains + 1
    order := if cfg.rules.ledger && !cfg.rules.renewAtRelease then s.order.filter (· != o) ++ [o]
      else s.order }

/-- `o` with the newest ticket. -/
def renewed (s : St) (o : Nat) : List Nat := s.order.filter (· != o) ++ [o]

/-- May `o` give a slot to the head `h` (rule 6, and the switches)? -/
def mayGive (cfg : Cfg) (s : St) (o h c : Nat) : Bool :=
  s.isAlive o && h != o && yieldTo cfg s o h &&
  (!cfg.rules.giverBehind ||
    (let s2 := drainEff cfg s o c
     ahead cfg (if cfg.rules.behindFresh then { s2 with order := renewed s2 o } else s2) h o))

/-- An operation's best not-draining slot to give, if any (the lowest CPU). -/
def keptSlot (s : St) (o : Nat) : Option Nat :=
  (List.range s.cpus.length).find? (fun c => (s.cpu c).slot == some { owner := o })

/-- src/pool.zig's `giver`: of those who may give, the project holding the most for its weight,
then the operation keeping the most, then the newest ticket. -/
def giverOf (cfg : Cfg) (s : St) (h : Nat) : Option Nat :=
  let ok := s.order.filter (fun g =>
    match keptSlot s g with
    | some c => mayGive cfg s g h c
    | none => false)
  let better (g b : Nat) : Bool :=
    let lg := projEff cfg s (cfg.op g).proj * cfg.w (cfg.op b).proj
    let lb := projEff cfg s (cfg.op b).proj * cfg.w (cfg.op g).proj
    decide (lg > lb) || (lg == lb && (decide (eff cfg s g > eff cfg s b) || eff cfg s g == eff cfg s b))
  ok.foldl (fun best g => match best with
    | none => some g
    | some b => if better g b then some g else best) none

/-- Drain on demand (rule 6): may `o` mark its slot `c` draining now? -/
def canDrain (cfg : Cfg) (s : St) (o c : Nat) : Bool :=
  s.isAlive o && (s.cpu c).slot == some { owner := o } &&
  if cfg.rules.ledger then
    match head cfg s with
    | none => false
    | some h =>
      decide (s.drains < need cfg s) && mayGive cfg s o h c &&
      (!cfg.rules.oneGiver || giverOf cfg s h == some o)
  else
    s.order.any (fun w => w != o && waiter cfg s w && before cfg s w o && yieldTo cfg s o w)

def anyDrain (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  (List.range s.cpus.length).any (canDrain cfg s o)

/-- Clear every slot `o` holds (a clean exit: `cpuq kill`, or a stop). -/
def releaseAll (s : St) (o : Nat) : St :=
  { s with
    cpus := s.cpus.map (fun x => if ownsC o x then {} else x)
    drains := s.drains - s.drainOf o }

/-- Ctrl-Z: the stop goes to the tasks (they hold no CPU while stopped and take a place again
on continue); an attempt being stopped by its timeout gets KILL now. -/
def stopTask (cfg : Cfg) (o : Nat) (t : Task) : Task :=
  match t.st with
  | .running _ => { t with st := .pending, dying := none }
  | .timedOut => { afterFail cfg o t with dying := none }
  | _ => { t with dying := none }

def killTask (t : Task) : Task :=
  match t.st with
  | .running _ | .pending | .timedOut => { t with st := .gone, dying := none }
  | _ => { t with dying := none }

/-- Without a standing registration (FINAL-REPORT-1), a holder tries once for a free token
after a reap; with one, it waits for the hand-out like everyone else. -/
def tryCond (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  !cfg.rules.standing && decide (s.owned o ≥ 1) && decide (demand cfg s o > 0) &&
    (match head cfg s with | none => true | some h => h == o)

def tryOnce (cfg : Cfg) (s : St) (o : Nat) : St :=
  if tryCond cfg s o then
    match firstFree cfg s with
    | some c => takeTok cfg s o c
    | none => s
  else s

/-- An alive parent reaps a task's exit: passed, failed and retried, or failed for good. -/
def reap (cfg : Cfg) (s : St) (o i : Nat) (ok : Bool) : St :=
  let t := s.task o i
  tryOnce cfg (s.setTask o i (if ok then afterOk cfg o t else afterFail cfg o t)) o

inductive Act where
  /-- An operation starts and takes a ticket. -/
  | arrive (o : Nat)
  /-- A task's process ends (passed or failed); its alive parent reaps it at once. -/
  | exit (o i : Nat) (ok : Bool)
  /-- A task overruns `-t`: TERM (KILL later). -/
  | timeout (o i : Nat)
  /-- A timed-out attempt finally exits. -/
  | gone (o i : Nat)
  | refill (o c : Nat)
  | release (o c : Nat)
  /-- A hand-out pass on its own: the 1 s fallback, or a waiter's own check. -/
  | handout
  /-- The waiter takes the flock of a token granted to it. -/
  | accept (o c : Nat)
  | drain (o c : Nat)
  | undrain (o c : Nat)
  /-- Rule 7: a free place in a slot takes a process from the operation's draining slot. -/
  | consolidate (o i d : Nat)
  /-- `cpuq kill`. -/
  | kill (o : Nat)
  /-- SIGKILL of the parent: the kernel drops its flocks; its tasks run on. -/
  | crash (o : Nat)
  | stop (o : Nat)
  | cont (o : Nat)
  | finish (o : Nat)
  deriving DecidableEq, Repr, Hashable, Inhabited

def step (cfg : Cfg) (s : St) : Act → Option St
  | .arrive o =>
    if (s.op o).phase == .waiting then
      some (handout cfg { s.setPhase o .alive with order := s.order ++ [o] })
    else none
  | .exit o i ok =>
    match (s.task o i).st with
    | .running _ =>
      if (s.op o).phase == .alive then some (reap cfg s o i ok)
      else if (s.op o).phase == .dead then some (s.setTask o i { s.task o i with st := .gone })
      else none
    | _ => none
  | .timeout o i =>
    match (s.task o i).st with
    | .running c =>
      if cfg.timeouts && (s.op o).phase == .alive then
        let t := s.task o i
        let t' : Task :=
          if cfg.rules.retryAtReap then { t with st := .timedOut, dying := some c }
          else { afterFail cfg o t with dying := some c }
        some (s.setTask o i t')
      else none
    | _ => none
  | .gone o i =>
    match (s.task o i).dying with
    | some _ =>
      let t := s.task o i
      let t1 : Task := { t with dying := none }
      let t2 := if (s.op o).phase == .alive && t.st == .timedOut then afterFail cfg o t1 else t1
      some (s.setTask o i t2)
    | none => none
  | .refill o c =>
    if s.isAlive o && (s.cpu c).slot == some { owner := o } &&
       decide (s.runningOn o c < (cfg.op o).K) && !anyDrain cfg s o then
      match firstPending s o with
      | some i => some (s.setTask o i { s.task o i with st := .running c })
      | none => none
    else none
  | .release o c =>
    match (s.cpu c).slot with
    | some sl =>
      if s.isAlive o && sl.owner == o && s.runningOn o c == 0 &&
         (!cfg.rules.releaseWaitsDying || (s.op o).tasks.all (fun t => t.dying != some c)) &&
         (sl.draining || s.pendingN o == 0) then
        some (handout cfg { s.setCpu c {} with
          drains := s.drains - (if sl.draining then 1 else 0)
          order := if cfg.rules.renewAtRelease then renewed s o else s.order })
      else none
    | none => none
  | .handout =>
    let s' := handout cfg s
    if s' != s then some s' else none
  | .accept o c =>
    if s.isAlive o && (s.cpu c).grant == some o && (s.cpu c).lock.isNone then
      some (takeTok cfg s o c)
    else none
  | .drain o c =>
    if canDrain cfg s o c then some (drainEff cfg s o c) else none
  | .undrain o c =>
    if cfg.rules.ledger && cfg.rules.undrains && s.isAlive o &&
       (s.cpu c).slot == some { owner := o, draining := true } && decide (s.drains > need cfg s) then
      some { s.setCpu c { s.cpu c with slot := some { owner := o } } with drains := s.drains - 1 }
    else none
  | .consolidate o i d =>
    match (s.task o i).st with
    | .running c =>
      if s.isAlive o && (s.cpu c).slot == some { owner := o, draining := true } &&
         (s.cpu d).slot == some { owner := o } && decide (s.runningOn o d < (cfg.op o).K) then
        some (s.setTask o i { s.task o i with st := .running d })
      else none
    | _ => none
  | .kill o =>
    if cfg.kills && s.isAlive o then
      some (handout cfg (((releaseAll s o).mapTasks o killTask).setPhase o .over))
    else none
  | .crash o =>
    let ph := (s.op o).phase
    if decide (s.crashes > 0) && (ph == .alive || ph == .stopped) then
      some { s.setPhase o .dead with
        cpus := s.cpus.map (fun x => if x.lock == some o then { x with lock := none } else x)
        crashes := s.crashes - 1 }
    else none
  | .stop o =>
    if cfg.stops && s.isAlive o then
      some (handout cfg (((releaseAll s o).mapTasks o (stopTask cfg o)).setPhase o .stopped))
    else none
  | .cont o =>
    if (s.op o).phase == .stopped then some (s.setPhase o .alive) else none
  | .finish o =>
    if s.isAlive o && s.owned o == 0 &&
       (s.op o).tasks.all (fun t =>
         (t.st == .done || t.st == .failed || t.st == .gone) && t.dying == none) then
      some (s.setPhase o .over)
    else none

def init (cfg : Cfg) : St :=
  { cpus := List.replicate cfg.cpus {}
    ops := cfg.ops.map (fun oc => { phase := .waiting, tasks := List.replicate oc.tasks {} })
    order := []
    drains := 0
    crashes := cfg.crashes }

/-- Every action worth trying in a state (`step` decides which are enabled). -/
def actions (cfg : Cfg) : List Act :=
  let os := opIds cfg
  let cs := List.range cfg.cpus
  os.flatMap (fun o => [.arrive o, .kill o, .crash o, .stop o, .cont o, .finish o]) ++
  os.flatMap (fun o => (List.range (cfg.op o).tasks).flatMap (fun i =>
    [.exit o i true, .timeout o i, .gone o i] ++
    (if (cfg.op o).retries > 0 then [.exit o i false] else []) ++
    cs.map (.consolidate o i ·))) ++
  os.flatMap (fun o => cs.flatMap (fun c =>
    [.refill o c, .release o c, .accept o c, .drain o c, .undrain o c])) ++
  [.handout]

def next (cfg : Cfg) (s : St) : List (Act × St) :=
  (actions cfg).filterMap (fun a => (step cfg s a).map (a, ·))

end Cpuq
