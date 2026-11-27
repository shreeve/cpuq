/-
cpuq's CPU-sharing protocol (FINAL-PLAN.md, "How CPUs are shared" and "Robustness"), as one
executable step function over finite data.

The same `move` is searched exhaustively at small sizes (`Explore.lean`, `Checks.lean`) and
proved about in general (`Safety.lean`, `Liveness.lean`, `Locks.lean`, `Drains.lean`). `Rules`
switches between the rules FINAL-REPORT-1 wrote (review2-formal.md's state machine, which its
counterexamples break), FINAL-PLAN's rules, the fixes this model found they need, and the
code's rules (`Rules.pool` and after; `Rules.released` is the code as released).

What a CPU is here: its token file's flock (`lock`, the parent that holds it), its grant file
(`grant`, the waiter it was handed to), and its record (`slot`: the operation the token file
names, and whether that slot is draining). An operation's tasks carry their own state; the
processes in a slot are the tasks whose state is `running c`. A task's `dying` is an earlier
attempt that was sent TERM by its timeout and has not yet exited.

Each action is one atomic step. `step` is the effect of one critical section under the pool
lock, or of a parent's own step (refill, reap); a critical section publishes under the lock or
by one rename, so an atomic step is faithful to it while nothing in it waits for another
process. `move` adds the pool lock, a drain's mark and Ctrl-Z as the code receives them: the one
critical section that takes a second lock, a drain's registration, is two moves (`enter`,
`mark`), so a wait inside it shows. `moveX` adds what `DrainCap.lean` covers: a drain's time
limit, a stream of drains, and the FIFO rule's accept; with none of them on it is `move`.
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
  /-- The pool lock's holder while a drain takes its mark (`enter`, then `mark`). Every other
  step that touches the pool is one critical section, atomic here, and needs the lock free. -/
  poolLock : Option Nat := none
  /-- The drains holding the drain mark (`v2/drain`), as bits by operation. -/
  marks : Nat := 0
  /-- A Ctrl-Z the loop has not yet acted on (`got_tstp`), as bits by operation. -/
  tstp : Nat := 0
  /-- Stopped in the eyes of whoever sent the Ctrl-Z: a SIGCONT is still to come, as bits. -/
  held : Nat := 0
  /-- Stopped by the kernel: the parent raised SIGSTOP on itself, as bits. -/
  halted : Nat := 0
  /-- How many more Ctrl-Z the search may send. -/
  zs : Nat := 0
  /-- Has held a CPU (the record's `served`), as bits by operation. -/
  served : Nat := 0
  /-- With backfill, the ticks left before the gathering drain could start (src/pool.zig's
  `shadow` less the time now). A drain's registration opens it (`Cfg.window`); time passing
  (`Act.tick`) only shrinks it, so a task that fits never ends after it. -/
  window : Nat := 0
  /-- With `drainCap`, each drain's clock (by operation; missing is 0): the ticks left before
  its command is killed. Its start sets it to the limit and the grace (`drainLimit`, `Cfg.grace`);
  time passing (`moveX`'s tick) counts it down: TERM when only the grace is left, KILL at 0. -/
  clock : List Nat := []
  /-- With `drainTurn`, has run a task (src/pool.zig's `running + done + failed > 0`), as bits. -/
  ran : Nat := 0
  deriving DecidableEq, Repr, Hashable, Inhabited

/-- Sets of operations as bits. -/
def bit (n o : Nat) : Bool := n.testBit o
def setBit (n o : Nat) : Nat := n ||| 2 ^ o
def clrBit (n o : Nat) : Nat := if n.testBit o then n ^^^ 2 ^ o else n

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
  /-- `cpuq drain`: one command, urgent. It wants every CPU of the pool while its command waits,
  starts it only holding them all, and keeps them while it runs; while it lives (it holds the
  drain mark) every other operation empties its CPUs, and every free CPU goes to the first
  drain in ticket order. -/
  drain : Bool := false
  /-- `-t`: how long a task of it may run, in the model's ticks (`Act.tick`), the time a kill
  takes included; 0: no limit. Read only by backfill (`fits`). -/
  tlimit : Nat := 0
  /-- A stream of drains: when this drain finishes, the same drain arrives again with a new
  ticket (another `cpuq drain` from the same place). Read only by `moveX`. -/
  again : Bool := false
  /-- With `drainSize`, a drain of the whole pool (`--all`); else of `cap` CPUs (`-c N`). -/
  all : Bool := false
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
  /-- A `cpuq drain` holds its mark with a shared lock, so a second drain never waits for the
  first under the pool lock. Off: an exclusive lock, which a second drain waits for while it
  holds the pool lock. -/
  markShared : Bool := false
  /-- A SIGCONT cancels a Ctrl-Z the loop has not yet acted on (`onCont`). -/
  contCancels : Bool := false
  /-- Right before it raises SIGSTOP on itself, a stopping parent checks whether a SIGCONT came
  since it took the Ctrl-Z, and if one did, goes on instead. The plan's rules have it: they say
  nothing of how a Ctrl-Z is received, and the code's race is not theirs. -/
  haltChecks : Bool := true
  /-- An operation is urgent only until it first holds a CPU (the record's `served`): holding
  none again, it is not urgent again. Off: urgent whenever it holds none. -/
  urgentOnce : Bool := false
  /-- A stopped drain lets its mark go (and takes it again when continued), and free CPUs go
  to the first drain that wants some. Off: a stopped drain keeps its mark, and free CPUs go to
  the first living drain, or to no one while it wants none. -/
  drainLets : Bool := false
  /-- With `drainLets`, free CPUs go to the drain wanting some that holds or was granted the
  most, then the older ticket, so at most one drain ever holds a CPU. Off: to the first in
  ticket order. -/
  drainMost : Bool := false
  /-- Backfill (0.32.0). While one `cpuq drain` gathers the pool and every other operation holding
  CPUs and running tasks has a time limit (`shadowed`), a task that ends before the latest of
  those could (`fits`) may still start: a free CPU goes first to the line's best waiter that
  fits, an operation that fits keeps refilling its CPUs, and the drain lends its idle CPUs to
  the waiters that fit (`lends`), giving them back without renewing its ticket. Off: while a
  drain gathers, every free CPU goes to it and every other operation empties its CPUs. -/
  backfill : Bool := false
  /-- A drain's command has a time limit (`drainLimit`: `-t`, else a default, at most a ceiling,
  never off): TERM when it is reached, KILL a grace later, and the drain gives its CPUs back
  before time passes again (`moveX`). The idle stop (under 0.25 CPU busy for 5 minutes while
  another run waits) is an earlier TERM, which `cpuq drain`'s command may get at any time. -/
  drainCap : Bool := false
  /-- No drain passes an older waiter that holds nothing: a free CPU goes to the best such waiter
  with an older ticket than the gathering drain's before it goes to the drain (`olderHead`), and
  the CPU a waiter accepts runs one of its tasks before it empties for the drain (src/op.zig's
  `place` runs before its next settle; `moveX`). A proposed fix, not in src/. -/
  drainFifo : Bool := false
  /-- A drain takes its turn (0.34.0): while a drain gathers, a free CPU goes first, in line
  order, to an operation that queued before the oldest gathering drain (`turnOf`) and has yet to
  start a task (`starting`: no task of it has run, and it wants or holds CPUs); such an operation
  keeps its CPUs (it is not made to empty them) until its first task runs. Then backfill, then
  the drain. Operations that have started empty their CPUs for a gathering drain as before. -/
  drainTurn : Bool := false
  /-- A drain's size (0.34.0): `-c N` (`cap`, `OpCfg.all` off) or `--all`. It starts holding its
  `cap` CPUs, and holds only those. Only a gathering `--all` drain makes the operations that have
  started empty their CPUs (`markOn`, src/pool.zig's `drainWantsAll`) and only it has backfill
  (`shadowed`); a `-c N` drain is owed its CPUs by the line's giver, one at a time. A `-c N`
  drain may run 2 hours at most, an `--all` drain 20 minutes (`drainCeil`, `drainCeilAll`). -/
  drainSize : Bool := false
  /-- The CPU an operation accepts runs one of its waiting tasks at once, before the operation
  looks at drains or the line again (src/op.zig's `place` runs before its next settle; `moveX`).
  Off: the accept and the refill are two steps, and a drain or the line's giver may come
  between. -/
  placeFirst : Bool := false
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
               undrains := false, haltChecks := false }

/-- `pool` with the fixes this model proposes for it (README, "Findings" 4, 5 and 6), which is
the code on `slots` at 8f997ec:
`behindAfter` compares with the ticket the giver will have once it gives the CPU back, and a
stopped operation is out of the line. -/
def poolFixed : Rules := { pool with behindFresh := true, stoppedWaits := false }

/-- The code at 0d315ed: a stopped operation wants nothing, but a grant made to it before it
stopped stays valid. (8f997ec drops those grants: the code there is `poolFixed`.) -/
def pool0d315ed : Rules := { poolFixed with stoppedGrants := true }

/-- The code at 0.30.2: `poolFixed`, with a drain's mark held shared and a SIGCONT cancelling
a Ctrl-Z not yet acted on. -/
def code0302 : Rules := { poolFixed with markShared := true, contCancels := true }

/-- The code at 0.30.3: `code0302` with the fixes of README's Findings 7, 8 and 9: urgent only
until served, the stop check before SIGSTOP, and a stopped drain letting the pool go. -/
def code0303 : Rules :=
  { code0302 with urgentOnce := true, haltChecks := true, drainLets := true }

/-- The code at 0.30.5 (and 0.31): `code0303` with the fix of README's Finding 10, free CPUs to
the drain holding the most. -/
def code0305 : Rules := { code0303 with drainMost := true }

/-- The code at 0.32.0: `code0305` with backfill. -/
def code0320 : Rules := { code0305 with backfill := true }

/-- The code at 0.33.0: `code0320` with the drain's time limit. -/
def code0330 : Rules := { code0320 with drainCap := true }

/-- `code0330` with a drain taking its turn (drain-turn at 2087ebe, before drain sizes). -/
def turn2087 : Rules := { code0330 with drainTurn := true }

/-- drain-turn at efa0af3: a drain takes its turn, and has a size. -/
def turnEfa : Rules := { turn2087 with drainSize := true, placeFirst := true }

/-- `code0330` with FIFO between drains and waiters holding nothing (`drainFifo`). -/
def fifo : Rules := { code0330 with drainFifo := true }

/-- The code as released (0.34.0): the time limit, FIFO between drains and waiters holding
nothing, and a drain's size (`-c N` or `--all`). -/
def released : Rules := { fifo with drainSize := true }

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
  /-- With `stops`, how many Ctrl-Z the search may send. -/
  ctrlZ : Nat := 1
  kills : Bool := false
  timeouts : Bool := false
  /-- With backfill, the time a drain's gathering may take at most, in ticks: the window
  (`St.window`) a drain's registration opens. -/
  window : Nat := 0
  /-- Also search `L3 hold` (a run in which a drain's command never ends). -/
  hold : Bool := false
  /-- With `drainCap`, a drain's limit when it gives no `-t` (src/op.zig: 20 minutes), in ticks. -/
  drainDefault : Nat := 1
  /-- With `drainCap`, the most a drain's `-t` may ask (src/op.zig: 2 hours), in ticks. -/
  drainCeil : Nat := 2
  /-- With `drainSize`, the most an `--all` drain may run (src/op.zig: 20 minutes), in ticks. -/
  drainCeilAll : Nat := 1
  /-- With `drainCap`, the ticks from TERM to KILL (src/op.zig: 5 s). -/
  grace : Nat := 1

/-! ## Reading the state -/

namespace St
def cpu (s : St) (c : Nat) : Cpu := s.cpus.getD c {}
def op (s : St) (o : Nat) : Op := s.ops.getD o {}
def task (s : St) (o i : Nat) : Task := (s.op o).tasks.getD i { st := .gone }
end St

def Cfg.op (cfg : Cfg) (o : Nat) : OpCfg := cfg.ops.getD o {}
def Cfg.w (cfg : Cfg) (p : Nat) : Nat := cfg.weights.getD p 1
def drainOp (cfg : Cfg) (o : Nat) : Bool := (cfg.op o).drain

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
/-- Some task of `o` runs. -/
def busy (s : St) (o : Nat) : Bool :=
  (s.op o).tasks.any (fun t => match t.st with | .running _ => true | _ => false)
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
    if drainOp cfg o then
      (if !s.busy o && decide (s.pendingN o > 0) then (cfg.op o).cap - (s.owned o + s.grants o)
       else 0)
    else
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
  (cfg.op o).urgent && !(cfg.rules.urgentOnce && bit s.served o) && (opIds cfg).all (fun o' =>
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

/-- The first `cpuq drain` in ticket order that has started and not ended (alive or stopped:
its record stays while it is stopped). -/
def firstDrain (cfg : Cfg) (s : St) : Option Nat :=
  s.order.find? (fun o => drainOp cfg o && ((s.op o).phase == .alive || (s.op o).phase == .stopped))

/-- The drain free tokens go to: with `drainLets`, the first in ticket order that wants some
(with `drainMost`, the one of those holding the most); else the first that has started and not
ended. -/
def drainer (cfg : Cfg) (s : St) : Option Nat :=
  if cfg.rules.drainLets then
    if cfg.rules.drainMost then
      s.order.foldl (fun best o =>
        if drainOp cfg o && decide (demand cfg s o > 0) then
          match best with
          | none => some o
          | some b => if s.owned o + s.grants o > s.owned b + s.grants b then some o else best
        else best) none
    else s.order.find? (fun o => drainOp cfg o && decide (demand cfg s o > 0))
  else firstDrain cfg s

/-- A `cpuq drain` that wants CPUs: it gathers the pool. -/
def gathers (cfg : Cfg) (s : St) (o : Nat) : Bool := drainOp cfg o && decide (demand cfg s o > 0)

/-- In the pool's scan: alive or stopped (a dead operation's record is dropped). -/
def scanned (s : St) (o : Nat) : Bool := (s.op o).phase == .alive || (s.op o).phase == .stopped

/-- An operation the gathering drain waits for: not a drain, holding CPUs, running tasks. -/
def shades (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  !drainOp cfg o && scanned s o && decide (s.owned o > 0) && s.busy o

/-- src/pool.zig's `shadow` is not null: with `backfill`, exactly one drain gathers, no other drain
holds a CPU, some operation it waits for runs tasks, and every such has a time limit. How long
until the latest of their tasks may end is `St.window`. -/
def shadowed (cfg : Cfg) (s : St) : Bool :=
  cfg.rules.backfill && (opIds cfg).countP (gathers cfg s) == 1 &&
  (opIds cfg).all (fun o => !(drainOp cfg o && scanned s o) || gathers cfg s o || s.owned o == 0) &&
  (opIds cfg).any (shades cfg s) &&
  (opIds cfg).all (fun o => !shades cfg s o || (cfg.op o).tlimit != 0) &&
  (!cfg.rules.drainSize || (opIds cfg).all (fun o => !gathers cfg s o || (cfg.op o).all))

/-- src/pool.zig's `fits`: a task of `o` started now ends before the gathering drain could start. -/
def fits (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  shadowed cfg s && !drainOp cfg o && (cfg.op o).tlimit != 0 && decide ((cfg.op o).tlimit ≤ s.window)

/-- The best waiter in line that fits, if any. -/
def fitHead (cfg : Cfg) (s : St) : Option Nat :=
  s.order.foldl (fun best o =>
    if waiter cfg s o && fits cfg s o then
      match best with
      | none => some o
      | some b => if before cfg s o b then some o else best
    else best) none

/-- src/pool.zig's `starting`: no drain, no task of it has run yet, and it wants or holds CPUs. -/
def starting (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  !drainOp cfg o && liveOp cfg s o && !bit s.ran o &&
    (decide (demand cfg s o > 0) || decide (s.owned o + s.grants o > 0))

/-- src/pool.zig's `turnOf`: the oldest gathering drain. -/
def turnOf (cfg : Cfg) (s : St) : Option Nat := s.order.find? (gathers cfg s)

/-- src/pool.zig's `before`: with `drainTurn`, `o` queued before the oldest gathering drain and has
yet to start. -/
def beforeT (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  cfg.rules.drainTurn && starting cfg s o &&
    match turnOf cfg s with
    | some t => decide (s.order.findIdx (· == o) < s.order.findIdx (· == t))
    | none => false

/-- The best waiter in line that goes before the gathering drain (`beforeT`). -/
def turnHead (cfg : Cfg) (s : St) : Option Nat :=
  s.order.foldl (fun best o =>
    if waiter cfg s o && beforeT cfg s o then
      match best with
      | none => some o
      | some b => if before cfg s o b then some o else best
    else best) none

/-- Where the oldest gathering drain stands in the tickets (0 when none gathers). -/
def turnIdx (cfg : Cfg) (s : St) : Nat :=
  match turnOf cfg s with
  | some t => s.order.findIdx (· == t)
  | none => 0

/-- With `drainFifo`, the best waiter that holds nothing, is no drain, and has an older ticket than
the oldest gathering drain (src/pool.zig's `before`). -/
def olderHead (cfg : Cfg) (s : St) : Option Nat :=
  s.order.foldl (fun best o =>
    if cfg.rules.drainFifo && waiter cfg s o && !drainOp cfg o && s.owned o + s.grants o == 0 &&
       decide (s.order.findIdx (· == o) < turnIdx cfg s) then
      match best with
      | none => some o
      | some b => if before cfg s o b then some o else best
    else best) none

/-- Who a free token goes to: while there is a drainer, (with `drainFifo`) the best older waiter
holding nothing, else (with `drainTurn`) the best waiter that goes before the drain, else the best
waiter that fits (backfill), else the drainer alone (and no one
while it wants nothing); with no drainer, the head of the line. -/
def target (cfg : Cfg) (s : St) : Option Nat :=
  match drainer cfg s with
  | some d =>
    if decide (demand cfg s d > 0) then
      match olderHead cfg s with
      | some w => some w
      | none =>
      match turnHead cfg s with
      | some w => some w
      | none =>
      match fitHead cfg s with
      | some f => some f
      | none => some d
    else none
  | none => head cfg s

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

/-- With `urgentOnce`, taking a CPU marks the operation served. -/
def serve (cfg : Cfg) (n o : Nat) : Nat := if cfg.rules.urgentOnce then setBit n o else n

/-- `o` takes token `c`: first kills a dead operation's leftovers on it (with `reclaim`), then
holds its flock with a fresh, empty slot (and, with `urgentOnce`, is served). -/
def takeTok (cfg : Cfg) (s : St) (o c : Nat) : St :=
  let s1 := if cfg.rules.reclaim then { s with ops := reclaimOps c s.ops } else s
  { s1 with
    cpus := s1.cpus.set c { lock := some o, grant := none, slot := some { owner := o } }
    drains := s1.drains - (if drainingC (s.cpu c) then 1 else 0)
    served := serve cfg s1.served o }

def firstFree (cfg : Cfg) (s : St) : Option Nat :=
  (List.range s.cpus.length).find? (fun c => freeC cfg s (s.cpu c))

def firstPending (s : St) (o : Nat) : Option Nat :=
  (List.range (s.op o).tasks.length).find? (fun i => pendingT (s.task o i))

/-- Hand token `c` to the head, if it is free and someone waits (one grant of a pass). -/
def grantOne (cfg : Cfg) (s : St) (c : Nat) : St :=
  if freeC cfg s (s.cpu c) then
    match target cfg s with
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
  s.isAlive o && h != o && !drainOp cfg o &&
  (drainOp cfg h ||
   (yieldTo cfg s o h &&
    (!cfg.rules.giverBehind ||
      (let s2 := drainEff cfg s o c
       ahead cfg (if cfg.rules.behindFresh then { s2 with order := renewed s2 o } else s2) h o))))

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

/-- What the waiters that fit still want (src/pool.zig's `lends`). -/
def fitWant (cfg : Cfg) (s : St) : Nat :=
  (opIds cfg).foldl (fun acc o => if fits cfg s o then acc + demand cfg s o else acc) 0

/-- Backfill: the gathering drain `o` lends one more idle CPU, while what the waiters that fit
still want is more than it already empties for them. -/
def lends (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  gathers cfg s o && shadowed cfg s && decide (s.drainOf o < fitWant cfg s)

/-- A drain's mark makes everyone else empty CPUs: some drain holds it (with `drainTurn`, and
some drain gathers: src/pool.zig's `drainWants`). -/
def markOn (cfg : Cfg) (s : St) : Bool :=
  s.marks != 0 && (!(cfg.rules.drainTurn || cfg.rules.drainSize) ||
    (opIds cfg).any (fun d => gathers cfg s d && (!cfg.rules.drainSize || (cfg.op d).all)))

/-- Drain on demand (rule 6): may `o` mark its slot `c` draining now? While a `cpuq drain` holds
its mark every other operation does, unless it fits (backfill); the gathering drain lends. -/
def canDrain (cfg : Cfg) (s : St) (o c : Nat) : Bool :=
  s.isAlive o && (s.cpu c).slot == some { owner := o } &&
  (markOn cfg s && !drainOp cfg o && !fits cfg s o && !beforeT cfg s o || lends cfg s o ||
  if cfg.rules.ledger then
    match head cfg s with
    | none => false
    | some h =>
      decide (s.drains < need cfg s) && mayGive cfg s o h c &&
      (!cfg.rules.oneGiver || giverOf cfg s h == some o)
  else
    s.order.any (fun w => w != o && waiter cfg s w && before cfg s w o && yieldTo cfg s o w))

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
  /-- The parent acts on a Ctrl-Z: its tasks stop and it gives every CPU back. -/
  | stop (o : Nat)
  /-- A SIGCONT. -/
  | cont (o : Nat)
  | finish (o : Nat)
  /-- A drain arriving takes the pool lock. -/
  | enter (o : Nat)
  /-- A drain holding the pool lock takes its mark, registers, and lets the lock go. -/
  | mark (o : Nat)
  /-- A Ctrl-Z (SIGTSTP) arrives; the handler only notes it. -/
  | tstp (o : Nat)
  /-- A parent that has given its CPUs back for a Ctrl-Z raises SIGSTOP on itself. -/
  | halt (o : Nat)
  /-- Time passes: with backfill, the window shrinks by a tick. -/
  | tick
  deriving DecidableEq, Repr, Hashable, Inhabited

/-- A drain holds all it gathers: every CPU of the pool, or (with `drainSize`) its `cap`. -/
def drainFull (cfg : Cfg) (s : St) (o : Nat) : Bool :=
  s.owned o == (if cfg.rules.drainSize then (cfg.op o).cap else s.cpus.length)

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
       decide (s.runningOn o c < (cfg.op o).K) && !anyDrain cfg s o &&
       (!drainOp cfg o || drainFull cfg s o) then
      match firstPending s o with
      | some i => some (s.setTask o i { s.task o i with st := .running c })
      | none => none
    else none
  | .release o c =>
    match (s.cpu c).slot with
    | some sl =>
      if s.isAlive o && sl.owner == o && s.runningOn o c == 0 &&
         (!cfg.rules.releaseWaitsDying || (s.op o).tasks.all (fun t => t.dying != some c)) &&
         (sl.draining || s.pendingN o == 0) && !(drainOp cfg o && s.busy o) then
        some (handout cfg { s.setCpu c {} with
          drains := s.drains - (if sl.draining then 1 else 0)
          order := if cfg.rules.renewAtRelease && !(cfg.rules.backfill && drainOp cfg o) then
            renewed s o else s.order })
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
      some (handout cfg (s.setPhase o .over))
    else none
  | .enter _ | .mark _ | .tstp _ | .halt _ | .tick => none

/-- Steps that touch the pool, under its lock. -/
def needsLock : Act → Bool
  | .arrive _ | .release _ _ | .handout | .accept _ _ | .drain _ _ | .undrain _ _ | .kill _
  | .stop _ | .finish _ | .enter _ => true
  | _ => false

/-- Leaving: the kernel drops what the parent held (its drain mark), and its signals no longer
matter. -/
def leave (s : St) (o : Nat) : St :=
  { s with marks := clrBit s.marks o, tstp := clrBit s.tstp o, held := clrBit s.held o,
           halted := clrBit s.halted o }

/-- With `drainLets`, a drain stopping lets its mark go. -/
def letsGo (cfg : Cfg) (o : Nat) : Bool := cfg.rules.drainLets && drainOp cfg o

/-- A drain continued takes its mark again (`suspend_`): under the pool lock, but a shared lock
waits for no one, so here it is part of the continue. -/
def retake (cfg : Cfg) (s : St) (o : Nat) : St :=
  if letsGo cfg o then { s with marks := setBit s.marks o } else s

/-- A step with its locks and signals. `step` is the effect of each critical section on the
pool; `move` adds the pool lock (a drain takes its mark while holding it), the drain mark, and
Ctrl-Z as the code receives it: the handler notes it, the loop acts on it, the parent then
raises SIGSTOP on itself, and a SIGCONT continues it. -/
def move (cfg : Cfg) (s : St) (a : Act) : Option St :=
  if needsLock a && s.poolLock.isSome then none else
  match a with
  | .arrive o => if drainOp cfg o then none else step cfg s a
  | .enter o =>
    if drainOp cfg o && (s.op o).phase == .waiting then some { s with poolLock := some o } else none
  | .mark o =>
    if s.poolLock == some o && (cfg.rules.markShared || s.marks == 0) then
      (step cfg s (.arrive o)).map fun s' =>
        { s' with poolLock := none, marks := setBit s'.marks o, window := cfg.window }
    else none
  | .crash o =>
    (step cfg s a).map fun s' =>
      { leave s' o with poolLock := if s.poolLock == some o then none else s.poolLock }
  | .kill o => (step cfg s a).map (leave · o)
  | .finish o => (step cfg s a).map (leave · o)
  | .tstp o =>
    if cfg.stops && decide (s.zs > 0) && !bit s.held o &&
       ((s.op o).phase == .alive || (s.op o).phase == .stopped) then
      some { s with tstp := setBit s.tstp o, held := setBit s.held o, zs := s.zs - 1 }
    else none
  | .stop o =>
    if bit s.tstp o then
      (step cfg s a).map fun s' =>
        { s' with tstp := clrBit s'.tstp o,
                  marks := if letsGo cfg o then clrBit s'.marks o else s'.marks }
    else none
  | .halt o =>
    if (s.op o).phase == .stopped && !bit s.halted o then
      if cfg.rules.haltChecks && !bit s.held o then (step cfg s (.cont o)).map (retake cfg · o)
      else some { s with halted := setBit s.halted o }
    else none
  | .cont o =>
    if bit s.held o then
      if bit s.halted o then
        (step cfg s a).map fun s' =>
          retake cfg { s' with held := clrBit s'.held o, halted := clrBit s'.halted o } o
      else
        some { s with held := clrBit s.held o,
                      tstp := if cfg.rules.contCancels then clrBit s.tstp o else s.tstp }
    else none
  | .tick => if cfg.rules.backfill && decide (s.window > 0) then some { s with window := s.window - 1 } else none
  | a => step cfg s a

def init (cfg : Cfg) : St :=
  { cpus := List.replicate cfg.cpus {}
    ops := cfg.ops.map (fun oc => { phase := .waiting, tasks := List.replicate oc.tasks {} })
    order := []
    drains := 0
    crashes := cfg.crashes
    zs := if cfg.stops then cfg.ctrlZ else 0 }

/-- Every action worth trying in a state (`step` decides which are enabled). -/
def actions (cfg : Cfg) : List Act :=
  let os := opIds cfg
  let cs := List.range cfg.cpus
  os.flatMap (fun o => [.arrive o, .kill o, .crash o, .stop o, .cont o, .finish o, .enter o,
    .mark o, .tstp o, .halt o]) ++ [.tick] ++
  os.flatMap (fun o => (List.range (cfg.op o).tasks).flatMap (fun i =>
    [.exit o i true, .timeout o i, .gone o i] ++
    (if (cfg.op o).retries > 0 then [.exit o i false] else []) ++
    cs.map (.consolidate o i ·))) ++
  os.flatMap (fun o => cs.flatMap (fun c =>
    [.refill o c, .release o c, .accept o c, .drain o c, .undrain o c])) ++
  [.handout]

/-! ## The drain's time limit, a stream of drains, and FIFO (`moveX`)

`move` with what the proofs before `DrainCap.lean` leave out: with `Rules.drainCap` a drain's
command has a clock, with `OpCfg.again` a drain comes back, with `Rules.drainFifo` an accepted
CPU runs a task first. With none of them, `moveX` is `move` (`moveX_plain`). -/

/-- A drain's limit in ticks: `-t`, else the default, at most the ceiling; never off. -/
def drainCeilOf (cfg : Cfg) (o : Nat) : Nat :=
  if cfg.rules.drainSize && (cfg.op o).all then cfg.drainCeilAll else cfg.drainCeil

def drainLimit (cfg : Cfg) (o : Nat) : Nat :=
  min (if (cfg.op o).tlimit == 0 then cfg.drainDefault else (cfg.op o).tlimit) (drainCeilOf cfg o)

/-- A clock with nothing left is the empty list, so equal clocks are equal states. -/
def normClock (l : List Nat) : List Nat := if l.all (· == 0) then [] else l

namespace St
def clk (s : St) (o : Nat) : Nat := s.clock.getD o 0
def setClk (s : St) (o n : Nat) : St :=
  { s with clock := normClock ((List.range (max s.clock.length (o + 1))).map
      (fun j => if j = o then n else s.clk j)) }
end St

/-- Every task has ended (as `finish` asks). -/
def ended (s : St) (o : Nat) : Bool :=
  (s.op o).tasks.all (fun t => (t.st == .done || t.st == .failed || t.st == .gone) && t.dying == none)

/-- With `drainCap`, time may not pass: an alive drain holds CPUs, its command has started (no
task of it waits), and its clock has run out or its command has ended: the KILL, or giving its
CPUs back, comes first. -/
def due (cfg : Cfg) (s : St) : Bool :=
  (opIds cfg).any (fun o => drainOp cfg o && s.isAlive o && decide (s.owned o > 0) &&
    s.pendingN o == 0 && (s.clk o == 0 || ended s o))

/-- TERM to every running task of `o` (the limit is reached), as a timeout sends it. -/
def termAll (cfg : Cfg) (s : St) (o : Nat) : St :=
  (List.range (s.op o).tasks.length).foldl
    (fun u i => (step { cfg with timeouts := true } u (.timeout o i)).getD u) s

/-- KILL to every dying attempt of `o` (the grace is over): it exits now. -/
def killAll (cfg : Cfg) (s : St) (o : Nat) : St :=
  (List.range (s.op o).tasks.length).foldl (fun u i => (step cfg u (.gone o i)).getD u) s

/-- A tick with `drainCap`: the window and every clock count down; a drain whose clock reaches
the grace gets TERM, and one whose clock reaches 0 gets KILL. -/
def tickX (cfg : Cfg) (s : St) : St :=
  let s1 := { s with window := s.window - 1, clock := normClock (s.clock.map (· - 1)) }
  (opIds cfg).foldl (fun u o =>
    if drainOp cfg o && s.isAlive o && decide (s.clk o > 0) then
      let u1 := if s.clk o - 1 ≤ cfg.grace then termAll cfg u o else u
      if s.clk o - 1 == 0 then killAll cfg u1 o else u1
    else u) s1

/-- With `drainFifo`: the CPU `c` that `o` just accepted runs `o`'s first waiting task. -/
def place (cfg : Cfg) (o c : Nat) (s : St) : St :=
  if drainOp cfg o || !decide (s.runningOn o c < (cfg.op o).K) then s else
  match firstPending s o with
  | some i => { s.setTask o i { s.task o i with st := .running c } with ran := setBit s.ran o }
  | none => s

/-- A drain of a stream (`again`) that finished arrives again later, as a new drain. -/
def respawn (cfg : Cfg) (o : Nat) (s : St) : St :=
  { (s.setClk o 0) with
    ops := s.ops.set o { phase := .waiting, tasks := List.replicate (cfg.op o).tasks {} }
    order := s.order.filter (· != o)
    served := clrBit s.served o
    ran := clrBit s.ran o }

/-- Some extension is on. -/
def extended (cfg : Cfg) : Bool :=
  cfg.rules.drainCap || cfg.rules.drainFifo || cfg.rules.drainTurn || cfg.rules.placeFirst ||
    cfg.ops.any (·.again)

/-- `move` with the drain's time limit, a stream of drains, and FIFO's accept. -/
def moveX (cfg : Cfg) (s : St) (a : Act) : Option St :=
  if !extended cfg then move cfg s a else
  match a with
  | .tick =>
    if cfg.rules.drainCap then
      if ((cfg.rules.backfill && decide (s.window > 0)) || s.clock.any (fun n => decide (n > 0))) && !due cfg s then
        some (tickX cfg s)
      else none
    else move cfg s a
  | .refill o _ =>
    (move cfg s a).map fun t =>
      let t := if cfg.rules.drainTurn then { t with ran := setBit t.ran o } else t
      if cfg.rules.drainCap && drainOp cfg o && !s.busy o then
        t.setClk o (drainLimit cfg o + cfg.grace)
      else t
  | .timeout o _ =>
    if cfg.rules.drainCap && drainOp cfg o then
      (step { cfg with timeouts := true } s a).map (·.setClk o (min (s.clk o) cfg.grace))
    else move cfg s a
  | .accept o c => (move cfg s a).map fun t =>
    if cfg.rules.drainFifo || cfg.rules.placeFirst then place cfg o c t else t
  | .finish o => (move cfg s a).map fun t => if (cfg.op o).again then respawn cfg o t else t
  | a => move cfg s a

theorem moveX_plain {cfg : Cfg} (h : extended cfg = false) (s : St) (a : Act) :
    moveX cfg s a = move cfg s a := by
  simp [moveX, h]

def next (cfg : Cfg) (s : St) : List (Act × St) :=
  (actions cfg).filterMap (fun a => (moveX cfg s a).map (a, ·))

end Cpuq
