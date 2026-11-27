#!/bin/bash
# test/run.sh [TEST...]: the end-to-end tests. Each test gets its own state directory, config and
# HOME, and runs in a folder of its own (not a repo, so a run's project is its label's). The pool
# is small (budget 2 unless a test says otherwise) and the memory and disk gates are off, so the
# tests depend neither on the machine's size nor on its memory. The outside-load gate, which
# reads the real machine, is off too, except where a test says otherwise (t_narrow).
# CPUQ=/path/to/cpuq tests another binary.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
CPUQ=${CPUQ:-$PWD/bin/cpuq}
[ -x "$CPUQ" ] || { echo "no $CPUQ; run zig build first"; exit 2; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cpuq-test.XXXXXX")
# On exit, end every process the tests started, children's children
# included, so none outlives the run holding its output open.
killtree() { local p; for p in $(pgrep -P "$1"); do killtree "$p"; kill "$p" 2>/dev/null; done; }
# The pids under $1, children's children included, to end by pid once $1 is gone.
descendants() { local p; for p in $(pgrep -P "$1"); do echo "$p"; descendants "$p"; done; }
# 0 if a pid in the file $1 still runs.
alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
trap 'killtree $$; rm -rf "$ROOT"' EXIT
# Linux: the suite runs with every CPU the machine's init may use, even when started inside a
# narrower CPU set (an outer `cpuq run` pins its job), so each task can be pinned to its pool CPU.
if [ "$(uname)" = Linux ]; then
  SUITE_PID=$$ python3 -c 'import os, re
m = re.search(r"Cpus_allowed_list:\s*(\S+)", open("/proc/1/status").read())
cpus = set()
for part in m.group(1).split(","):
    a, _, b = part.partition("-"); cpus.update(range(int(a), int(b or a) + 1))
os.sched_setaffinity(int(os.environ["SUITE_PID"]), cpus)' 2>/dev/null
fi
PASS=0
FAIL=0
KNOWN=0
FAILED=""

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED $CUR"; echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
# known BUG DESCRIPTION CONDITION: a check that fails for a known cpuq bug (written up where the
# suite was last rewritten). Counted apart, so the suite still passes; once it passes, drop the mark.
known() { if eval "$3"; then ok "$2 (known bug $1 did not show: drop the mark once fixed)"; else KNOWN=$((KNOWN + 1)); echo "  KNOWN $2 [bug: $1]"; fi; }

# setup NAME [config lines...]: a fresh state dir, config and HOME for one test, and cd there.
setup() {
  CUR=$1; shift
  T=$ROOT/$CUR
  mkdir -p "$T/home"
  export CPUQ_DIR=$T/state CPUQ_CONFIG=$T/config HOME=$T/home
  unset CPUQ_BUDGET CPUQ_CPU CPUQ_OP CPUQ_TASK CPUQ_TASKS CPUQ_ATTEMPT CPUQ_ATTEMPTS CPUQ_PROGRESS \
    CPUQ_PROGRESS_AT CPUQ_LEASES CPUQ_TOKEN CPUQ_CORES CPUQ_HISTORY MAKEFLAGS XDG_STATE_HOME
  # Each key at most once: a line given here replaces the default for its key.
  local line keys=" "
  for line in "$@"; do keys="$keys${line%% *} "; done
  {
    for line in "budget = 2" "min_disk = off" "pressure_check = off" "outside_check = off"; do
      case $keys in *" ${line%% *} "*) ;; *) echo "$line" ;; esac
    done
    for line in "$@"; do echo "$line"; done
  } >"$CPUQ_CONFIG"
  cd "$T" || exit 2
  echo "== $CUR"
}

# dfl CMD...: exec CMD with SIGINT, SIGQUIT and SIGTSTP at their defaults. A `&` job in a script
# starts with SIGINT and SIGQUIT ignored, and cpuq (like any command) keeps an ignored signal
# ignored.
dfl() { exec python3 -c 'import os, signal, sys
for s in (signal.SIGINT, signal.SIGQUIT, signal.SIGTSTP): signal.signal(s, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }

# sj EXPR: EXPR in Python over `cpuq status --json --no-usage`, as s.
sj() { "$CPUQ" status --json --no-usage | python3 -c 'import json, sys; s = json.load(sys.stdin); print(eval(sys.argv[1]))' "$1"; }
held() { sj 's["held"]'; }
waiting() { sj 'len(s["waiters"])'; }
# The pool's CPUs, by the machine's numbers, space-separated.
poolcpus() { sj '" ".join(map(str, s["pool"]))'; }
now() { python3 -c 'import time; print("%.3f" % time.time())'; }
since() { python3 -c "import time; print('%.2f' % (time.time() - $1))"; }
# fl EXPR: 0 when the Python expression is true (float comparisons).
fl() { python3 -c "import sys; sys.exit(0 if $1 else 1)"; }

# tmo SECONDS CMD...: CMD with a time limit (macOS has no timeout(1)): 124 when it ran out and
# ended on SIGTERM, 137 when it then needed SIGKILL (5 s later); else CMD's status.
tmo() { python3 -c 'import subprocess, sys
p = subprocess.Popen(sys.argv[2:])
def rc(r): return 128 - r if r < 0 else r
try: sys.exit(rc(p.wait(float(sys.argv[1]))))
except subprocess.TimeoutExpired: pass
p.terminate()
try: p.wait(5); sys.exit(124)
except subprocess.TimeoutExpired: p.kill(); p.wait(); sys.exit(137)' "$@"; }
# poll SECONDS CONDITION: until CONDITION (evaluated) holds, about every 0.05 s; 1 if it never does.
poll() { local i=0 n=$(($1 * 20)); until eval "$2"; do i=$((i + 1)); [ $i -ge $n ] && return 1; sleep 0.05; done; }
holds() { "$CPUQ" status --json --no-usage | python3 -c 'import json, sys
s = json.load(sys.stdin)
sys.exit(0 if any(h["label"] == sys.argv[1] and h["cores"] > 0 for h in s["holders"]) else 1)' "$1"; }
# wait_held N [seconds]: until N CPUs are held.
wait_held() { poll "${2:-10}" "[ \"\$(held)\" = $1 ]"; }
# wait_holder LABEL [seconds]: until a run labelled LABEL holds a CPU.
wait_holder() { poll "${2:-10}" "holds '$1'"; }
# wait_waiters N [seconds]: until the line holds N runs.
wait_waiters() { poll "${2:-10}" "[ \"\$(waiting)\" = $1 ]"; }
# wait_file PATH [seconds]: until PATH exists and is not empty.
wait_file() { poll "${2:-10}" "[ -s '$1' ]"; }
# wait_line PATH LINE [seconds]: until PATH has the line LINE.
wait_line() { poll "${3:-10}" "grep -qx '$2' '$1' 2>/dev/null"; }
# lease_waiters NAME: how many wait for the named lease.
lease_waiters() { ls "$CPUQ_DIR/named/$1/queue" 2>/dev/null | wc -l | tr -d ' '; }
# reap PID: its exit status once it has really ended (bash's wait also returns when a child stops).
reap() { local rc; while :; do wait "$1"; rc=$?; kill -0 "$1" 2>/dev/null || return $rc; sleep 0.05; done; }
# The output folder of a run of tasks with the label's project PROJECT (the newest).
rundir() { ls -td "$HOME/.local/state/cpuq/runs/$1"/* 2>/dev/null | head -1; }
# An ssh stand-in: drops its options and the host, and runs the remote command here, so the
# "remote" cpuq shares this test's pool. In $T/bin, with cpuq beside it.
fake_ssh() {
  mkdir -p "$T/bin"
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\nexec sh -c "$*"\n' >"$T/bin/ssh"
  chmod +x "$T/bin/ssh"
  ln -sf "$CPUQ" "$T/bin/cpuq"
}

# --- The pool: CPUs, tasks, packing ----------------------------------------------------------

t_budget() {
  # The pool never hands out more CPUs than it has: 12 runs and a run of 6 tasks on a pool of 2.
  setup budget
  local pids=() i p
  for i in $(seq 12); do "$CPUQ" run -- sleep 0.3 & pids+=($!); done
  "$CPUQ" run -n 6 -- sleep 0.3 2>/dev/null & pids+=($!)
  local max=0 samples=0 h any=1
  while [ $any = 1 ] && [ $samples -lt 200 ]; do
    h=$(held); samples=$((samples + 1))
    [ -n "$h" ] && [ "$h" -gt "$max" ] && max=$h
    any=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && any=1; done
  done
  local rc=0
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  check "never more than the pool's 2 CPUs held (most $max over $samples looks), and every run passed (rc $rc)" "[ $max -le 2 ] && [ $max -gt 0 ] && [ $rc = 0 ]"
  local b1 b2; b1=$("$CPUQ" budget); b2=$(CPUQ_BUDGET=1 "$CPUQ" budget)
  check "cpuq budget prints the pool's size: budget 2 ($b1), CPUQ_BUDGET=1 ($b2)" "[ '$b1' = 2 ] && [ '$b2' = 1 ]"
}

t_tasks() {
  # -n M: M tasks, each with CPUQ_TASK, CPUQ_TASKS, CPUQ_CPU (one of the pool's), CPUQ_OP and
  # CPUQ_ATTEMPT, stdin from /dev/null, and its output (both streams) in a file of its own; a plan
  # line first; 0 when every task passed, 1 when any failed, with the failed task's last lines.
  setup tasks
  local pool; pool=$(poolcpus)
  "$CPUQ" run -n 5 --label t:env -- sh -c 'echo "$CPUQ_TASK/$CPUQ_TASKS $CPUQ_CPU op=$CPUQ_OP try=$CPUQ_ATTEMPT"; echo err >&2; cat' 2>"$T/err"; local rc=$?
  local d; d=$(rundir t)
  local files; files=$(ls "$d" 2>/dev/null | sort -n | tr '\n' ' ')
  local good=0 i cpu
  for i in 1 2 3 4 5; do
    cpu=$(sed -n 's/^[0-9]*\/5 \([0-9]*\) op=[0-9][0-9]* try=1$/\1/p' "$d/$i" 2>/dev/null)
    [ -n "$cpu" ] && [[ " $pool " == *" $cpu "* ]] && grep -qx err "$d/$i" && good=$((good + 1))
  done
  check "5 tasks, each with its own output file ($files) holding its variables, a CPU of the pool ($pool) and its stderr ($good of 5); rc $rc" "[ $rc = 0 ] && [ '$files' = '1 2 3 4 5 ' ] && [ $good = 5 ]"
  check "a plan line first, then the summary ('$(head -1 "$T/err")' ... '$(tail -1 "$T/err" | cut -c1-40)')" \
    "grep -q '^cpuq: 5 tasks, up to 2 CPUs, overload 1, timeout 3600s\$' '$T/err' && grep -q '^cpuq: 5 of 5 tasks passed, in .*; output in $d\$' '$T/err'"
  "$CPUQ" run -n 4 --label u:fail -- sh -c 'echo "line of $CPUQ_TASK"; [ "$CPUQ_TASK" != 3 ] || exit 7' 2>"$T/err2"; rc=$?
  check "a failed task makes it 1 (rc $rc), and the summary names it with its last lines" \
    "[ $rc = 1 ] && grep -q '3 of 4 tasks passed, 1 failed' '$T/err2' && grep -q 'task 3 (attempt 1) exited 7' '$T/err2' && grep -qx '    line of 3' '$T/err2'"
}

t_pack() {
  # -x K: up to K tasks share a CPU, and a CPU fills to K before the next is taken: 5 tasks at -x 3
  # put 3 on one CPU and 2 on another; 3 tasks at -x 3 hold one CPU.
  setup pack
  "$CPUQ" run -n 5 -x 3 --label p:five -- sh -c 'echo "$CPUQ_CPU" >"$1/five.$CPUQ_TASK"; sleep 0.5' sh "$T" 2>/dev/null; local rc=$?
  local per first
  per=$(cat "$T"/five.* | sort | uniq -c | awk '{print $1}' | sort -rn | tr '\n' ' ')
  first=$(cat "$T/five.1" "$T/five.2" "$T/five.3" | sort -u | wc -l | tr -d ' ')
  check "5 tasks at -x 3: tasks 1-3 share a CPU, 4-5 another (tasks per CPU: $per; CPUs of 1-3: $first; rc $rc)" "[ $rc = 0 ] && [ '$per' = '3 2 ' ] && [ $first = 1 ]"
  "$CPUQ" run -n 3 -x 3 --label p:three -- sh -c 'echo "$CPUQ_CPU" >"$1/three.$CPUQ_TASK"; sleep 0.6' sh "$T" 2>"$T/err" & local p=$!
  local max=0 h
  while kill -0 $p 2>/dev/null; do h=$(held); [ -n "$h" ] && [ "$h" -gt "$max" ] && max=$h; done
  wait $p; rc=$?
  local cpus; cpus=$(cat "$T"/three.* | sort -u | wc -l | tr -d ' ')
  check "3 tasks at -x 3 hold one CPU (most held $max, CPUs used $cpus, '$(head -1 "$T/err")')" "[ $rc = 0 ] && [ $max = 1 ] && [ $cpus = 1 ] && grep -q 'up to 1 CPU, overload 3' '$T/err'"
}

t_cpus_limit() {
  # -c C or -c P%: the most CPUs a run holds, against the pool (here 4, named, so a machine with
  # fewer CPUs has the same pool), at least 1, and never more than its tasks need; the plan line
  # says it, and the tasks keep to it.
  setup cpus-limit "budget = 4" "cpus = 0-3"
  local got="" spread=1 c n
  for c in 1 2 50% 25% 10% 100% 9; do
    n=$("$CPUQ" run -n 8 -c "$c" --label c:x -- sh -c 'echo "$CPUQ_CPU" >>"$1"; sleep 0.1' sh "$T/cpus.$c" 2>&1 >/dev/null | sed -n 's/^cpuq: 8 tasks, up to \([0-9]*\) CPUs*,.*/\1/p')
    got="$got$c:$n "
    [ "$(sort -u "$T/cpus.$c" | wc -l | tr -d ' ')" -le "${n:-0}" ] || spread=0
  done
  local few; few=$("$CPUQ" run -n 3 --label c:few -- true 2>&1 | sed -n 's/^cpuq: 3 tasks, up to \([0-9]*\) CPUs*,.*/\1/p')
  local x; x=$("$CPUQ" run -n 8 -x 3 -c 100% --label c:x3 -- true 2>&1 | sed -n 's/^cpuq: 8 tasks, up to \([0-9]*\) CPUs*,.*/\1/p')
  check "-c on a pool of 4: a count, a percentage (at least 1), clamped to the pool ($got); never more than the tasks need (3 tasks: $few; 8 at -x 3: $x); the tasks keep to it ($spread)" \
    "[ '$got' = '1:1 2:2 50%:2 25%:1 10%:1 100%:4 9:4 ' ] && [ '$few' = 3 ] && [ '$x' = 3 ] && [ $spread = 1 ]"
  local bad=0 v
  for v in 0 101% x 2.5; do "$CPUQ" run -c "$v" -- true 2>/dev/null; [ $? = 2 ] || bad=$((bad + 1)); done
  check "a -c of 0, over 100%, or not a whole number is a usage error (wrong: $bad)" "[ $bad = 0 ]"
}

t_timeout() {
  # -t T: a task over its time limit gets SIGTERM, then SIGKILL 5 s later; one task exits 124;
  # in a run of many, its place frees and the run ends 1. The config's `timeout` is the default.
  setup timeout
  local t0 rc dt
  t0=$(now); "$CPUQ" run -t 1s -- sleep 30 2>"$T/err"; rc=$?; dt=$(since "$t0")
  check "one task over -t 1s: 124 after ${dt}s, said so ($(cat "$T/err"))" "[ $rc = 124 ] && fl '$dt < 3' && grep -q 'stopped at its time limit' '$T/err'"
  t0=$(now)
  "$CPUQ" run -t 1s -- python3 -c 'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)' 2>/dev/null; rc=$?
  dt=$(since "$t0")
  check "a task that ignores SIGTERM gets SIGKILL 5 s after it: 124 after ${dt}s" "[ $rc = 124 ] && fl '5.5 < $dt < 12'"
  t0=$(now)
  "$CPUQ" run -n 3 -t 1s --label t:many -- sh -c '[ "$CPUQ_TASK" != 2 ] || sleep 30' 2>"$T/err"; rc=$?
  dt=$(since "$t0")
  check "in a run of 3 the task over its limit fails as 124, the others pass: rc $rc after ${dt}s" \
    "[ $rc = 1 ] && fl '$dt < 3' && grep -q '2 of 3 tasks passed, 1 failed (1 at the time limit)' '$T/err' && grep -q 'task 2 (attempt 1) exited 124' '$T/err'"
  setup timeout-config "timeout = 1s"
  t0=$(now)
  "$CPUQ" run -n 1 -- sleep 30 2>"$T/err"; rc=$?
  dt=$(since "$t0")
  check "the config's timeout is the default (rc $rc after ${dt}s, '$(head -1 "$T/err")')" "[ $rc = 1 ] && fl '$dt < 3' && grep -q 'timeout 1s' '$T/err'"
}

t_retry() {
  # -r N: a failed task is tried up to N more times, with CPUQ_ATTEMPT and CPUQ_ATTEMPTS, its
  # output in a file per attempt; a retry goes behind the run's other tasks; a timeout counts as
  # a failure; the summary counts the retried.
  setup retry
  "$CPUQ" run -n 3 -r 2 --label r:x -- sh -c 'echo "try $CPUQ_ATTEMPT of $CPUQ_ATTEMPTS"
case $CPUQ_TASK in 1) exit 0 ;; 2) [ "$CPUQ_ATTEMPT" = 3 ] ;; 3) exit 1 ;; esac' 2>"$T/err"; local rc=$?
  local d; d=$(rundir r)
  local files; files=$(ls "$d" | sort | tr '\n' ' ')
  check "task 2 passes on its third try, task 3 fails all three: rc $rc, a file per attempt ($files), each with its try ($(cat "$d/2.3" 2>/dev/null))" \
    "[ $rc = 1 ] && [ '$files' = '1 2 2.2 2.3 3 3.2 3.3 ' ] && [ \"\$(cat '$d/2.3')\" = 'try 3 of 3' ] && grep -q 'passed or ended on a retry' '$T/err' && grep -q 'task 3 (attempt 3) exited 1' '$T/err'"
  "$CPUQ" run -n 3 -c 1 -r 1 --label r:order -- sh -c 'echo "$CPUQ_TASK.$CPUQ_ATTEMPT" >>"$1"; [ "$CPUQ_TASK" != 1 ] || [ "$CPUQ_ATTEMPT" = 2 ]' sh "$T/order" 2>/dev/null; rc=$?
  local order; order=$(tr '\n' ' ' <"$T/order")
  # op.zig's place() starts a waiting retry before the run's next new task (FINAL-PLAN: "A retry
  # goes to the back of the operation's own tasks, so one flaky task never holds up the rest").
  check "a retry goes behind the run's other tasks (order: $order; rc $rc)" "[ $rc = 0 ] && [ '$order' = '1.1 2.1 3.1 1.2 ' ]"
  local t0 dt; t0=$(now)
  "$CPUQ" run -n 1 -t 1s -r 1 --label r:slow -- sh -c '[ "$CPUQ_ATTEMPT" = 2 ] || sleep 30' 2>/dev/null; rc=$?
  dt=$(since "$t0")
  "$CPUQ" run -r 1 -- sh -c 'exit $((2 - CPUQ_ATTEMPT))'; local single=$?
  check "a timeout is retried (rc $rc after ${dt}s); one task is retried too (rc $single)" "[ $rc = 0 ] && fl '$dt < 4' && [ $single = 0 ]"
}

t_wait_max() {
  # --wait-max S: no CPU within S seconds and the run gives up with 75, nothing run; 0 takes a
  # free CPU at once or gives up at once.
  setup wait-max "budget = 1"
  "$CPUQ" run --label w:hold -- sleep 3 & local h=$!
  wait_held 1
  local t0 rc0 rc1 dt0 dt1 rcn
  t0=$(now); "$CPUQ" run --wait-max 0 -- touch "$T/ran" 2>"$T/err"; rc0=$?; dt0=$(since "$t0")
  t0=$(now); "$CPUQ" run --wait-max 1 -- touch "$T/ran" 2>/dev/null; rc1=$?; dt1=$(since "$t0")
  "$CPUQ" run -n 3 --wait-max 0 -- touch "$T/ran" 2>/dev/null; rcn=$?
  wait $h
  "$CPUQ" run --wait-max 0 -- true; local free=$?
  local ran=no; [ -e "$T/ran" ] && ran=yes
  check "the pool full: --wait-max 0 gives up at once (rc $rc0 after ${dt0}s, '$(cat "$T/err")'), --wait-max 1 after a second (rc $rc1 after ${dt1}s), a run of 3 too (rc $rcn), nothing ran ($ran); a free CPU: 0 runs (rc $free)" \
    "[ $rc0 = 75 ] && fl '$dt0 < 1' && [ $rc1 = 75 ] && fl '0.9 < $dt1 < 3' && [ $rcn = 75 ] && [ $ran = no ] && [ $free = 0 ] && grep -q 'nothing ran' '$T/err'"
}

t_share() {
  # Two operations of different projects share a pool of 2: a holds both until b comes; then, as
  # a's tasks end, b gets a CPU, and each holds one while both run; both finish.
  setup share
  "$CPUQ" run -n 16 --label a:work -- sleep 0.4 2>/dev/null & local a=$!
  wait_held 2
  "$CPUQ" run -n 6 --label b:work -- sleep 0.4 2>/dev/null & local b=$!
  local both=0 most_b=0 looks=0 line
  while kill -0 $b 2>/dev/null && [ $looks -lt 200 ]; do
    line=$(sj '" ".join("%s=%d" % (p["name"], p["held"]) for p in sorted(s["projects"], key=lambda p: p["name"]))')
    looks=$((looks + 1))
    case " $line " in *" a=1 b=1 "*) both=$((both + 1)) ;; esac
    case " $line " in *" b=2 "*) most_b=2 ;; esac
  done
  wait $a; local ra=$?; wait $b; local rb=$?
  check "while both run each project holds a CPU ($both of $looks looks), b never both ($most_b), both finish (rc $ra $rb)" "[ $both -ge 3 ] && [ $most_b = 0 ] && [ $ra = 0 ] && [ $rb = 0 ]"
}

t_fair() {
  # The line takes turns by project: with two CPUs freeing, b's one run starts beside a's first,
  # before a's second and third (all came before b's).
  setup fair
  local f=$T/order n k=0
  "$CPUQ" run -n 2 --label h:x -- sh -c "while [ ! -e $T/go ]; do sleep 0.05; done" 2>/dev/null & wait_held 2
  for n in a1 a2 a3 b1; do
    "$CPUQ" run --label "${n:0:1}:x" -- sh -c "echo $n >>$f; sleep 2" &
    k=$((k + 1)); wait_waiters $k
  done
  touch "$T/go"
  wait
  local got first; got=$(tr '\n' ' ' <"$f"); first=$(head -2 "$f" | sort | tr '\n' ' ')
  check "projects take turns: b's run starts with a's first, before a's second (got: $got)" "[ '$first' = 'a1 b1 ' ]"
}

t_order() {
  # The line: an --urgent run first, then the others in the order they came (each its own
  # project, all holding nothing).
  setup order "budget = 1"
  local f=$T/order k=0 n
  "$CPUQ" run --label h:x -- sh -c "while [ ! -e $T/go ]; do sleep 0.05; done" & wait_held 1
  for n in a b c d; do
    "$CPUQ" run --label "$n:x" -- sh -c "echo $n >>$f" &
    k=$((k + 1)); wait_waiters $k
  done
  "$CPUQ" run --urgent --label u:x -- sh -c "echo U >>$f" & wait_waiters 5
  touch "$T/go"
  wait
  local got; got=$(tr -d '\n' <"$f")
  check "--urgent goes first, then first come first served (got $got)" "[ '$got' = Uabcd ]"
  # --urgent counts for an operation's first CPU only: an urgent run with long work that holds
  # one CPU gives it up for a waiter of its own project, rather than rank first again.
  setup urgent-once "budget = 2"
  "$CPUQ" run -n 30 --label q:b -- sleep 0.5 2>/dev/null & local b=$!
  wait_held 2
  "$CPUQ" run --urgent -n 30 --label p:u -- sleep 0.5 2>/dev/null & local u=$!
  poll 5 '[ "$(sj "len([h for h in s[\"holders\"] if h[\"cores\"]])")" = 2 ]'
  local t0 rc dt; t0=$(now)
  "$CPUQ" run --wait-max 6 --label p:c -- true; rc=$?; dt=$(since "$t0")
  kill -TERM $u $b; reap $u; reap $b
  check "an urgent run holding a CPU gives way to a waiter of its project (rc $rc after ${dt}s)" "[ $rc = 0 ] && fl '$dt < 4'"
}

t_drain() {
  # cpuq drain -- CMD: every run stops taking CPUs and gives them back as its tasks end; once the
  # drain holds the whole pool, CMD runs alone; what waited runs after it. --max gives up (75).
  setup drain
  local f=$T/log
  "$CPUQ" run -n 4 --label d:a -- sh -c "echo a\$CPUQ_TASK-start >>$f; sleep 1; echo a\$CPUQ_TASK-end >>$f" 2>/dev/null & local a=$!
  wait_held 2
  "$CPUQ" drain --max 20s --label d:timing -- sh -c "echo drain-start >>$f; \"$CPUQ\" status --json --no-usage | python3 -c 'import json, sys; s = json.load(sys.stdin); print(\"drain-held\", s[\"held\"], \" \".join(h[\"label\"] for h in s[\"holders\"] if h[\"cores\"]))' >>$f; sleep 1; echo drain-end >>$f" & local d=$!
  wait_waiters 1
  "$CPUQ" run --label d:late -- sh -c "echo late >>$f" & local l=$!
  wait $a $d $l
  local got; got=$(tr '\n' ' ' <"$f")
  echo "  $got"
  python3 - "$f" <<'EOF' >"$T/verdict"
import sys
lines = [l.strip() for l in open(sys.argv[1])]
at = {l: i for i, l in enumerate(lines)}
ok = (at["drain-start"] > max(at["a1-end"], at["a2-end"])
      and "drain-held 2 d:timing" in lines and at["late"] > at["drain-end"])
held_back = at["a3-start"] > at["drain-end"] and at["a4-start"] > at["drain-end"]
print("ok" if ok else "wrong", "held-back" if held_back else "refilled")
EOF
  local verdict; verdict=$(cat "$T/verdict")
  check "the drain's command starts once the running tasks end, holds the pool alone, and what waited runs after it" "[ '${verdict% *}' = ok ]"
  # An operation asleep in poll() hears of the drain only at its next settle(), and on waking it
  # place()s its next task on the freed CPU first (seen on pup: a3 started after a1 ended).
  check "a run stops starting tasks once a drain waits (${verdict#* })" "[ '${verdict#* }' = held-back ]"
  "$CPUQ" run --label d:long -- sleep 3 & local h=$!
  wait_held 1
  local t0 rc dt; t0=$(now)
  "$CPUQ" drain --max 1s -- touch "$T/ran" 2>/dev/null; rc=$?; dt=$(since "$t0")
  wait $h
  local ran=no; [ -e "$T/ran" ] && ran=yes
  check "drain --max 1s gives up with 75 while a task runs on (rc $rc after ${dt}s, ran: $ran)" "[ $rc = 75 ] && [ $ran = no ] && fl '$dt < 2.5'"
  # Two drains at once: the second waits in the line, never on the first's hold of the drain
  # mark under the pool's lock (that deadlocked every cpuq on the machine). Each runs alone, in
  # turn, and a run behind them follows.
  local g=$T/two
  "$CPUQ" drain --max 20s --label d:one -- sh -c "echo one-start >>$g; sleep 1; echo one-end >>$g" & local d1=$!
  wait_line "$g" one-start
  "$CPUQ" drain --max 20s --label d:two -- sh -c "echo two-start >>$g; sleep 1; echo two-end >>$g" & local d2=$!
  "$CPUQ" run --wait-max 20 --label d:after -- sh -c "echo after >>$g" & local d3=$!
  local r1 r2 r3; wait $d1; r1=$?; wait $d2; r2=$?; wait $d3; r3=$?
  local order; order=$(tr '\n' ' ' <"$g" 2>/dev/null)
  local alone=no
  case "$order" in "one-start one-end two-start two-end "*|"two-start two-end one-start one-end "*) alone=yes ;; esac
  check "two drains at once each run alone, in turn, and a run follows (rc $r1 $r2 $r3: $order)" \
    "[ $r1 = 0 ] && [ $r2 = 0 ] && [ $r3 = 0 ] && [ $alone = yes ]"
}

t_lock_stuck() {
  # A process stuck holding the pool's lock stops every cpuq on the machine. cpuq status waits
  # for the lock at most 5 s, then names the holder (from the note each holder writes) and fails
  # (125, cpuq itself failed).
  setup lock-stuck
  "$CPUQ" status >/dev/null
  python3 -c 'import fcntl, os, sys, time
f = open(sys.argv[1], "r+")
fcntl.flock(f, fcntl.LOCK_EX)
os.pwrite(f.fileno(), ("%12d %16d\n" % (os.getpid(), int(time.time() * 1000) - 60000)).encode(), 0)
open(sys.argv[2], "w").write("%d" % os.getpid())
time.sleep(30)' "$CPUQ_DIR/v2/lock" "$T/holder" & local h=$!
  wait_file "$T/holder"
  local t0 out rc dt; t0=$(now)
  out=$(tmo 20 "$CPUQ" status 2>&1); rc=$?; dt=$(since "$t0")
  kill $h; wait $h 2>/dev/null
  echo "  $out"
  check "status names a stuck holder of the pool's lock and fails (rc $rc after ${dt}s)" \
    "[ $rc = 125 ] && fl '4.5 < $dt < 8' && [[ \"\$out\" == *'held by pid $(cat "$T/holder") for 6'?'s ('* ]]"
  local r2; "$CPUQ" status >/dev/null; r2=$?
  check "once the holder is gone, status works (rc $r2)" "[ $r2 = 0 ]"
}

t_storm() {
  # Everything at once on a pool of 2, for about 10 s: runs of tasks, single and urgent runs,
  # drains (two at a time), kills, Ctrl-Z and continue, and status every 0.3 s. Nothing may hang
  # (each command has 60 s; a hang ends in 124, or 137 when it ignores the TERM), status always answers, and the pool ends empty.
  setup storm
  local L=$T/rc; : >"$L"
  # t CMD...: run CMD with a 60 s limit, noting a hang.
  t() { tmo 60 "$@" >/dev/null 2>&1; local rc=$?; case $rc in 124|137) echo "hang: $*" >>"$L" ;; esac; return 0; }
  local end=$(( $(date +%s) + 10 )) pids=""
  ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" run -n 3 -t 20s --label s:many -- sh -c 'sleep 0.$((CPUQ_TASK * 2))'; done ) & pids="$pids $!"
  ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" run --label s:one -- sleep 0.1; done ) & pids="$pids $!"
  ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" run --urgent --label s:urgent -- sleep 0.2; sleep 0.5; done ) & pids="$pids $!"
  for d in 1 2; do
    ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" drain --max 30s --label s:drain$d -- sleep 0.3; sleep 0.7; done ) & pids="$pids $!"
  done
  ( while [ "$(date +%s)" -lt $end ]; do
      "$CPUQ" run --label s:victim -- sleep 5 >/dev/null 2>&1 & local v=$!
      sleep 0.4; t "$CPUQ" kill s:victim; wait $v 2>/dev/null
    done ) & pids="$pids $!"
  ( while [ "$(date +%s)" -lt $end ]; do
      dfl "$CPUQ" run -n 2 --label s:tstp -- sleep 0.5 >/dev/null 2>&1 & local z=$!
      sleep 0.3; kill -TSTP $z 2>/dev/null; sleep 0.3; kill -CONT $z 2>/dev/null
      reap $z
    done ) & pids="$pids $!"
  local polls=0 stuck=0
  while [ "$(date +%s)" -lt $end ]; do
    tmo 10 "$CPUQ" status --json --no-usage >/dev/null 2>&1 || stuck=$((stuck + 1))
    polls=$((polls + 1)); sleep 0.3
  done
  local t0; t0=$(now)
  wait $pids
  local tail; tail=$(since "$t0")
  local h w; h=$(held); w=$(waiting)
  local hangs; hangs=$(wc -l <"$L" | tr -d ' ')
  [ "$hangs" = 0 ] || head -5 "$L"
  check "everything at once: no command hung ($hangs), status answered $((polls - stuck)) of $polls, all done ${tail}s after the end, pool empty (held $h, waiting $w)" \
    "[ $hangs = 0 ] && [ $stuck = 0 ] && fl '$tail < 30' && [ '$h' = 0 ] && [ '$w' = 0 ]"
}

t_kill() {
  # cpuq kill OP, by label or ticket: SIGTERM to the run's cpuq, which ends its tasks; the run
  # exits by the signal. A label of two runs, or of none, is refused.
  setup kill
  "$CPUQ" run --label k:one -- sh -c 'echo $$ >"$1"; exec sleep 30' sh "$T/one" & local p=$!
  wait_file "$T/one"
  local said; said=$("$CPUQ" kill k:one); local rk=$?
  wait $p 2>/dev/null; local rp=$?
  sleep 0.2
  local left=no; alive "$T/one" && left=yes
  check "kill by label ends a single run (kill $rk: '$said'; run $rp; task left: $left)" "[ $rk = 0 ] && [ $rp = 143 ] && [ $left = no ] && [[ '$said' == 'stopping '*'k:one'* ]]"
  "$CPUQ" run -n 4 --label k:many -- sh -c 'echo $$ >"$1.$CPUQ_TASK"; sleep 30' sh "$T/many" 2>"$T/err" & p=$!
  wait_held 2; wait_file "$T/many.1"; wait_file "$T/many.2"
  local ticket; ticket=$(sj '[h["ticket"] for h in s["holders"] if h["label"] == "k:many"][0]')
  "$CPUQ" kill "$ticket" >/dev/null; rk=$?
  wait $p 2>/dev/null; rp=$?
  sleep 0.2
  left=no; alive "$T/many.1" && left=yes; alive "$T/many.2" && left=yes
  check "kill by ticket ends a run of tasks, tasks stopped, not failed (kill $rk; run $rp; left: $left)" "[ $rk = 0 ] && [ $rp = 143 ] && [ $left = no ] && grep -q '2 stopped, 2 not run' '$T/err'"
  "$CPUQ" run --label k:two -- sleep 3 & local a=$!
  "$CPUQ" run --label k:two -- sleep 3 & local b=$!
  wait_held 2
  local two; two=$("$CPUQ" kill k:two 2>&1); local r2=$?
  local none; none=$("$CPUQ" kill k:none 2>&1); local rn=$?
  kill $a $b 2>/dev/null; wait $a $b 2>/dev/null
  check "a label of two runs is refused with both listed (rc $r2), one of none too (rc $rn: '$none')" "[ $r2 = 1 ] && [[ '$two' == *'2 operations are k:two'* ]] && [ $rn = 1 ] && [[ '$none' == *'no operation here is k:none'* ]]"
}

t_ctrl_z() {
  # Ctrl-Z (SIGTSTP to cpuq): its tasks stop and its CPUs go back to the pool, for a newcomer;
  # continued, it takes CPUs again and its tasks finish. For a run of tasks and for one task.
  setup ctrl-z
  dfl "$CPUQ" run -n 2 --label z:a -- sh -c 'echo $$ >"$1.$CPUQ_TASK"; sleep 1.5' sh "$T/pid" 2>/dev/null & local a=$!
  wait_held 2; wait_file "$T/pid.1"; wait_file "$T/pid.2"
  kill -TSTP $a
  local freed=no; poll 5 '[ "$(held)" = 0 ]' && freed=yes
  local st; st=$(ps -o stat= -p "$(cat "$T/pid.1")" | tr -d ' ')
  local t0 rb dt; t0=$(now)
  "$CPUQ" run --wait-max 5 --label z:b -- true; rb=$?; dt=$(since "$t0")
  kill -CONT $a
  reap $a; local ra=$?
  check "a run of tasks stopped gives its CPUs back (freed: $freed), its tasks stopped ($st); a newcomer runs (rc $rb after ${dt}s); continued, it finishes (rc $ra)" \
    "[ $freed = yes ] && [[ '$st' == T* ]] && [ $rb = 0 ] && fl '$dt < 2' && [ $ra = 0 ]"
  setup ctrl-z-single "budget = 1"
  dfl "$CPUQ" run --label z:one -- sh -c 'sleep 1; echo finished >"$1"' sh "$T/done" & a=$!
  wait_held 1
  kill -TSTP $a
  freed=no; poll 5 '[ "$(held)" = 0 ]' && freed=yes
  "$CPUQ" run --wait-max 5 --label z:b -- true; rb=$?
  kill -CONT $a
  reap $a; ra=$?
  check "one task stopped gives its CPU back (freed: $freed), a newcomer runs (rc $rb), and continued it finishes (rc $ra, $(cat "$T/done" 2>/dev/null))" \
    "[ $freed = yes ] && [ $rb = 0 ] && [ $ra = 0 ] && [ \"\$(cat '$T/done' 2>/dev/null)\" = finished ]"
  # A stop and a continue that both land while cpuq is busy (here: blocked on the pool's lock,
  # held from outside), as from Ctrl-Z then a quick fg: the continue cancels the stop, and the
  # run goes on to finish once the lock and its CPU come.
  "$CPUQ" run --label z:hold -- sleep 4 & local h=$!
  wait_held 1
  dfl "$CPUQ" run -n 2 --label z:race -- true 2>/dev/null & a=$!
  wait_waiters 1
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "r+"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").write("1"); time.sleep(2.5)' "$CPUQ_DIR/v2/lock" "$T/locked" & local p=$!
  wait_file "$T/locked"
  sleep 1.5  # the waiter's 1 s settle blocks on the lock
  # Apart, so cpuq's handler takes the stop first (a continue discards a stop still pending).
  kill -TSTP $a; sleep 0.2; kill -CONT $a
  wait $p
  local ended=no st2=""
  if poll 8 "! kill -0 $a 2>/dev/null"; then ended=yes; else st2=$(ps -o stat= -p $a | tr -d ' '); kill -CONT $a; fi
  reap $a; wait $h
  check "a stop then a continue while cpuq is busy leave the run running: it finishes (ended: $ended $st2)" "[ $ended = yes ]"
  # A continue that lands after cpuq has taken the stop, while it gives its CPUs back (here:
  # blocked on the pool's lock, held from outside), as from an agent's `kill -TSTP; kill -CONT`:
  # cpuq doesn't stop itself after it, and the run finishes.
  dfl "$CPUQ" run --label z:lost -- sh -c 'sleep 1; echo finished >"$1"' sh "$T/lost" 2>/dev/null & a=$!
  wait_held 1
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "r+"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").write("1"); time.sleep(1.5)' "$CPUQ_DIR/v2/lock" "$T/locked2" & p=$!
  wait_file "$T/locked2"
  kill -TSTP $a; sleep 0.4; kill -CONT $a
  wait $p
  ended=no; st2=""
  if poll 8 "! kill -0 $a 2>/dev/null"; then ended=yes; else st2=$(ps -o stat= -p $a | tr -d ' '); kill -CONT $a; fi
  reap $a
  check "a continue while cpuq gives its CPUs back for a stop leaves the run running: it finishes (ended: $ended $st2, $(cat "$T/lost" 2>/dev/null))" \
    "[ $ended = yes ] && [ \"\$(cat '$T/lost' 2>/dev/null)\" = finished ]"
  # A drain stopped by Ctrl-Z lets the pool go: the CPUs it waited for go back to work, not idle
  # until it continues. Continued, it takes the pool again and its command runs.
  setup ctrl-z-drain "budget = 2"
  "$CPUQ" run -n 8 --label z:work -- sleep 1.5 2>/dev/null & local w=$!
  wait_held 2
  dfl "$CPUQ" drain --max 30s --label z:drain -- touch "$T/drained" 2>/dev/null & a=$!
  wait_waiters 1; sleep 0.2
  kill -TSTP $a
  sleep 2  # past the end of the tasks running when the drain came
  local busy=no; poll 4 '[ "$(held)" = 2 ]' && busy=yes
  kill -CONT $a
  local rd; reap $a; rd=$?
  wait $w; local rw=$?
  check "a stopped drain lets its CPUs go to work (busy: $busy); continued, it runs (rc $rd, ran: $([ -e "$T/drained" ] && echo yes || echo no)); the work ends (rc $rw)" \
    "[ $busy = yes ] && [ $rd = 0 ] && [ -e '$T/drained' ] && [ $rw = 0 ]"
  # Two drains, one stopped and continued while the other took part of the pool: the free CPUs
  # go to the drain holding the most, so it runs, then the other; they never wait on each other.
  setup ctrl-z-drains "budget = 2"
  "$CPUQ" run -n 4 --label z:work -- sh -c 'sleep $((CPUQ_TASK % 2 ? 1 : 3))' 2>/dev/null & w=$!
  wait_held 2
  dfl "$CPUQ" drain --max 15s --label z:b -- true 2>/dev/null & local b=$!
  wait_waiters 1; sleep 0.1
  kill -TSTP $b; sleep 0.2
  "$CPUQ" drain --max 15s --label z:c -- true 2>/dev/null & local cc=$!
  sleep 1.3  # the first CPU frees (at 1 s) and goes to c
  kill -CONT $b
  local t0 rb rc2 dt; t0=$(now)
  reap $b; rb=$?; reap $cc; rc2=$?; dt=$(since "$t0")
  wait $w
  check "two drains, one stopped and continued, don't wait on each other: both run (rc $rb $rc2 in ${dt}s)" "[ $rb = 0 ] && [ $rc2 = 0 ] && fl '$dt < 8'"
}

t_nested() {
  # A run inside a task runs on that task's CPU at once, with no line, even with the pool full:
  # found by CPUQ_CPU and CPUQ_OP, or, with them cleared (env -i), by its ancestor's operation.
  # A CPUQ_OP naming no live operation is ignored. The hook stands down inside a task.
  setup nested "budget = 1"
  local t0 out dt
  t0=$(now)
  out=$("$CPUQ" run -- sh -c '"$1" run --wait-max 0 -- sh -c "echo inner \$CPUQ_CPU \$CPUQ_OP"; echo "outer $CPUQ_CPU $CPUQ_OP"' sh "$CPUQ")
  dt=$(since "$t0")
  local same=no; set -- $out; [ $# = 6 ] && [ "$2" = "$5" ] && [ "$3" = "$6" ] && same=yes
  check "a run inside a task starts at once in a full pool, on its CPU and operation (${dt}s: $(echo $out))" "[ $same = yes ] && fl '$dt < 1'"
  out=$("$CPUQ" run -- sh -c '"$1" run -n 3 --wait-max 0 -- sh -c "echo t\$CPUQ_TASK"' sh "$CPUQ" 2>/dev/null | sort | tr '\n' ' ')
  check "a run of 3 tasks inside a task runs them there (got $out)" "[ '$out' = 't1 t2 t3 ' ]"
  out=$("$CPUQ" run -- env -i PATH="$PATH" HOME="$HOME" CPUQ_DIR="$CPUQ_DIR" CPUQ_CONFIG="$CPUQ_CONFIG" "$CPUQ" run --wait-max 0 -- sh -c 'echo "env-i ${CPUQ_OP:-none}"'); local rc=$?
  check "under env -i, the ancestor's operation is found: it runs at once (rc $rc, '$out')" "[ $rc = 0 ] && [ '$out' = 'env-i none' ]"
  "$CPUQ" run --label n:hold -- sleep 2 & local h=$!
  wait_held 1
  CPUQ_CPU=0 CPUQ_OP=99999 "$CPUQ" run --wait-max 0 -- true 2>/dev/null; rc=$?
  wait $h
  check "a CPUQ_OP of no live operation is ignored: the run waits its turn (rc $rc)" "[ $rc = 75 ]"
  local call='printf "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make -j8\"}}" | "$1" hook 2>/dev/null; echo $?'
  local inside outside; inside=$("$CPUQ" run -- sh -c "$call" sh "$CPUQ"); outside=$(sh -c "$call" sh "$CPUQ")
  check "the hook stands down inside a task (rc $inside), not outside (rc $outside)" "[ '$inside' = 0 ] && [ '$outside' = 2 ]"
}

t_driver() {
  # --driver: a runner holding no CPU, with the terminal; each `cpuq run` it starts takes a CPU
  # of its own; an enclosing task's CPUQ_CPU and CPUQ_OP don't reach it; its exit is its own.
  setup driver "budget = 1"
  local out rc
  "$CPUQ" run --driver --label d:runner -- sh -c 'echo "cpu=${CPUQ_CPU:-none}"; "$1" status --json --no-usage | python3 -c "import json, sys; print(\"held\", json.load(sys.stdin)[\"held\"])"; "$1" run --label d:case -- sh -c "echo case \${CPUQ_OP:+op}"; exit 3' sh "$CPUQ" >"$T/out"; rc=$?
  out=$(tr '\n' ' ' <"$T/out")
  local inner; inner=$(CPUQ_CPU=0 CPUQ_OP=1 "$CPUQ" run --driver -- sh -c 'echo "${CPUQ_CPU:-none} ${CPUQ_OP:-none}"')
  check "a driver holds no CPU, its runs take their own, its exit is its command's (got '$out', rc $rc); CPUQ_CPU/CPUQ_OP stay out ($inner)" \
    "[ '$out' = 'cpu=none held 0 case op ' ] && [ $rc = 3 ] && [ '$inner' = 'none none' ]"
}

t_removed() {
  # A removed flag, command or config key fails at once (2) with a line saying what does its
  # work, and runs nothing.
  setup removed
  local wrong="" out rc f
  for f in "--cores 2" "--cores 2-6" "--priority high" "--max-wait 5" "--exclusive" "--qos none" "--opaque" "--no-load-check"; do
    out=$("$CPUQ" run $f -- touch "$T/ran" 2>&1); rc=$?
    { [ $rc = 2 ] && [ "$(echo "$out" | wc -l | tr -d ' ')" = 1 ] && [[ "$out" == *' is gone'* || "$out" == *'--wait-max'* ]]; } || wrong="$wrong [run $f: $rc $out]"
  done
  for f in first start cancel pause resume stop note doctor qos; do
    out=$("$CPUQ" $f x 2>&1); rc=$?
    { [ $rc = 2 ] && [[ "$out" == "cpuq: $f is gone: "* ]]; } || wrong="$wrong [$f: $rc $out]"
  done
  out=$("$CPUQ" jobs run 2>&1); rc=$?
  { [ $rc = 2 ] && [[ "$out" == "cpuq: jobs run is gone: "* ]]; } || wrong="$wrong [jobs run: $rc $out]"
  for f in agent attach; do
    out=$("$CPUQ" $f 2>&1); rc=$?
    { [ $rc = 2 ] && [[ "$out" == "cpuq: $f is gone: "* ]]; } || wrong="$wrong [$f: $rc $out]"
  done
  for f in admit target settle poll aging backfill patience exclusive lend affinity load_check active_cap qos max_memory cpu_weights; do
    echo "$f = x" >"$T/c.$f"
    out=$(CPUQ_CONFIG=$T/c.$f "$CPUQ" run -- touch "$T/ran" 2>&1); rc=$?
    { [ $rc = 2 ] && [[ "$out" == *": $f is gone: "* ]]; } || wrong="$wrong [key $f: $rc $out]"
  done
  out=$("$CPUQ" lease bench --exclusive -- touch "$T/ran" 2>&1); rc=$?
  { [ $rc = 2 ] && [[ "$out" == *'cpuq drain'* ]]; } || wrong="$wrong [lease --exclusive: $rc $out]"
  local ran=no; [ -e "$T/ran" ] && ran=yes
  check "each removed flag, command and key fails with its pointer, running nothing (ran: $ran; wrong:${wrong:- none})" "[ -z '$wrong' ] && [ $ran = no ]"
}

# --- Holding and losing CPUs -----------------------------------------------------------------

t_kill_holder() {
  # SIGKILL of an operation's cpuq gives its CPUs back at once: a waiter runs.
  setup kill-holder "budget = 1"
  "$CPUQ" run -n 1 --label k:holder -- sh -c 'echo $$ >"$1"; exec sleep 30' sh "$T/task" 2>/dev/null & local holder=$!
  wait_held 1; wait_file "$T/task"
  "$CPUQ" run --label k:waiter -- true & local waiter=$!
  wait_waiters 1
  local t0; t0=$(now)
  kill -9 $holder
  wait $waiter; local rc=$?
  local dt; dt=$(since "$t0")
  alive "$T/task" && kill -9 "$(cat "$T/task")" 2>/dev/null
  check "a SIGKILLed operation's CPU comes back at once: the waiter ran ${dt}s after (rc $rc)" "[ $rc = 0 ] && fl '$dt < 1.5'"
}

t_leftovers() {
  # A SIGKILLed operation's tasks don't run on beside the next holder of their CPU: on Linux they
  # die with their cpuq (PR_SET_PDEATHSIG); on macOS whoever takes the CPU next ends the task
  # groups its token names.
  setup leftovers "budget = 1"
  local mode got="" p
  for mode in single tasks; do
    local n=""; [ $mode = tasks ] && n="-n 1"
    rm -f "$T/task"
    "$CPUQ" run $n --label l:$mode -- sh -c 'echo $$ >"$1"; exec sleep 30' sh "$T/task" 2>/dev/null & p=$!
    wait_file "$T/task"
    kill -9 $p; wait $p 2>/dev/null
    sleep 0.3
    [ "$(uname)" = Linux ] || "$CPUQ" run --label l:next -- true
    sleep 0.2
    if alive "$T/task"; then got="$got$mode:left "; kill -9 "$(cat "$T/task")"; else got="$got$mode:gone "; fi
  done
  if [ "$(uname)" = Linux ]; then
    check "Linux: a SIGKILLed operation's tasks die with it, one task or many (got $got)" "[ '$got' = 'single:gone tasks:gone ' ]"
  else
    # Pool.take opens a CPU's token write-only (createShared), so it never reads the groups noted
    # there; and a single task shares cpuq's group, so its pid names no group to kill.
    check "the next holder of a SIGKILLed operation's CPU ends its leftover tasks (got $got)" "[ '$got' = 'single:gone tasks:gone ' ]"
  fi
}

t_leaked_descendant() {
  # What a task leaves running in the background keeps no CPU: the next run starts at once; and a
  # task of many takes its process group with it.
  setup leaked-descendant "budget = 1"
  "$CPUQ" run -- sh -c 'sleep 30.417 >/dev/null 2>&1 & echo $! >"$1"; exit 0' sh "$T/bg"
  local t0; t0=$(now)
  "$CPUQ" run --wait-max 2 -- true; local rc=$?
  local dt; dt=$(since "$t0")
  kill "$(cat "$T/bg")" 2>/dev/null
  check "a single task's background descendant keeps no CPU: the next run took ${dt}s (rc $rc)" "[ $rc = 0 ] && fl '$dt < 1'"
  "$CPUQ" run -n 1 -- sh -c 'sleep 30.418 >/dev/null 2>&1 & echo $! >"$1"; exit 0' sh "$T/bg2" 2>/dev/null
  sleep 0.2
  local left=no; alive "$T/bg2" && { left=yes; kill "$(cat "$T/bg2")"; }
  check "what a task of many leaves in its group ends with it (left: $left)" "[ $left = no ]"
}

t_kill_waiter() {
  # A SIGKILLed waiter doesn't hold up the line.
  setup kill-waiter "budget = 1"
  "$CPUQ" run -- sleep 1.5 & local holder=$!
  wait_held 1
  "$CPUQ" run --label w:one -- true & local w1=$!
  wait_waiters 1
  "$CPUQ" run --label w:two -- true & local w2=$!
  wait_waiters 2
  kill -9 $w1
  local t0; t0=$(now)
  wait $w2; local rc=$?
  local dt; dt=$(since "$t0")
  wait $holder
  check "the second waiter ran ${dt}s after the first was SIGKILLed (the holder had under 1.5 s left; rc $rc)" "[ $rc = 0 ] && fl '$dt < 3'"
}

t_term_waiting() {
  # A run killed while it waits in the line gives up at once by the signal (143) and never starts
  # its command.
  setup term-waiting "budget = 1"
  "$CPUQ" run --label w:hold -- sleep 3 & local h=$!
  wait_held 1
  "$CPUQ" run -n 2 --label w:many -- touch "$T/many-ran" 2>/dev/null & local m=$!
  wait_waiters 1
  local t0; t0=$(now)
  kill -TERM $m; wait $m 2>/dev/null; local rm=$?
  local dm; dm=$(since "$t0")
  "$CPUQ" run --label w:single -- touch "$T/single-ran" & local s=$!
  wait_waiters 1
  t0=$(now)
  kill -TERM $s; wait $s 2>/dev/null; local rs=$?
  local ds; ds=$(since "$t0")
  wait $h
  local many=no single=no; [ -e "$T/many-ran" ] && many=yes; [ -e "$T/single-ran" ] && single=yes
  check "a waiting run of tasks killed by SIGTERM ends at once by it (rc $rm after ${dm}s), running nothing ($many)" "[ $rm = 143 ] && fl '$dm < 1' && [ $many = no ]"
  # sys.installForwarding keeps the signal for a child not yet started: the run waits on for its
  # CPU, then starts the command and signals it, which may already have run (cpuq kill too).
  check "a waiting single run killed by SIGTERM ends at once by it (rc $rs after ${ds}s), running nothing ($single)" "[ $rs = 143 ] && fl '$ds < 1' && [ $single = no ]"
}

t_lost_seq() {
  # A lost ticket counter never hands out a live ticket.
  setup lost-seq
  "$CPUQ" run --label a:x -- sleep 2 & "$CPUQ" run --label b:x -- sleep 2 &
  wait_held 2
  "$CPUQ" run --label c:x -- true & wait_waiters 1
  rm -f "$CPUQ_DIR/v2/seq"
  "$CPUQ" run --label d:x -- true & wait_waiters 2
  local tickets; tickets=$(sj '" ".join(str(t) for t in sorted({h["ticket"] for h in s["holders"]} | {w["ticket"] for w in s["waiters"]}))')
  local rc=0 p; for p in $(jobs -p); do wait "$p" || rc=1; done
  check "with seq deleted the tickets stay distinct ($tickets) and every run completes (rc $rc)" "[ \$(echo $tickets | wc -w) = 4 ] && [ $rc = 0 ]"
}

t_long_command() {
  # A command line of 5000 bytes (an inline script) runs, and status shows its first 1000 bytes.
  setup long-command
  local pad; pad=$(printf 'x%.0s' $(seq 2000))
  "$CPUQ" run --label l:mid -- sh -c "sleep 1 # $pad" & local p=$!
  wait_held 1
  local shown; shown=$(sj '[len(h["command"]) for h in s["holders"]][0]')
  wait $p; local rc=$?
  check "a 2000-byte command runs and status shows its first 1000 bytes (rc $rc, $shown bytes)" "[ $rc = 0 ] && [ '$shown' = 1000 ]"
  pad=$(printf 'x%.0s' $(seq 5000))
  local out; out=$("$CPUQ" run -- sh -c "echo ran # $pad" 2>"$T/err"); rc=$?
  check "a 5000-byte command runs (rc $rc, '$out' $(cut -c1-60 "$T/err"))" "[ $rc = 0 ] && [ '$out' = ran ]"
}

t_waiters_cpu() {
  # A hundred runs waiting in the line use almost no CPU.
  setup waiters-cpu "budget = 1"
  "$CPUQ" run -- sleep 12 & local h=$!
  wait_held 1
  local pids=() i
  for i in $(seq 100); do "$CPUQ" run -- true & pids+=($!); done
  local queued=no
  wait_waiters 100 30 && queued=yes
  sleep 1
  local list; list=$(IFS=,; echo "${pids[*]}")
  # CPU seconds used by the waiters: /proc on Linux, ps elsewhere.
  cpu() { python3 - "$list" <<'EOF'
import os, subprocess, sys
pids = sys.argv[1].split(",")
t = 0.0
if os.path.isdir("/proc/self"):
    tick = os.sysconf("SC_CLK_TCK")
    for p in pids:
        try:
            f = open("/proc/%s/stat" % p).read().rsplit(")", 1)[1].split()
            t += (int(f[11]) + int(f[12])) / tick
        except OSError:
            pass
else:
    out = subprocess.run(["ps", "-o", "time=", "-p", sys.argv[1]], capture_output=True, text=True).stdout
    for line in out.split():
        parts = line.split(":")
        t += sum(float(x) * 60 ** i for i, x in enumerate(reversed(parts)))
print("%.2f" % t)
EOF
  }
  local c0; c0=$(cpu)
  sleep 4
  local c1; c1=$(cpu)
  local used; used=$(python3 -c "print('%.2f' % ($c1 - $c0))")
  echo "  100 waiters: ${used}s of CPU in 4s ($(python3 -c "print('%.1f' % ($used / 4 * 100))")% of one CPU)"
  kill $h 2>/dev/null
  local rc=0 p
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  check "100 waiters were in the line while measured ($queued)" "[ $queued = yes ]"
  # Each waiting run wakes every second (op.zig sleep: a 1000 ms poll) and rescans the whole pool
  # under its lock, so the line's cost grows with the square of its length (0.29: under 0.1 CPU).
  check "100 waiters use almost no CPU (${used}s in 4s)" "fl '$used < 0.5'"
  check "all 100 ran (rc $rc)" "[ $rc = 0 ]"
}

# --- Exit status and signals -----------------------------------------------------------------

t_exit_status() {
  setup exit-status
  "$CPUQ" run -- sh -c 'exit 7'; local rc=$?
  check "exit 7 passes through as 7 (got $rc)" "[ $rc = 7 ]"
  "$CPUQ" run -- sh -c 'kill -TERM $$'; rc=$?
  check "a command killed by SIGTERM reports 143 (got $rc)" "[ $rc = 143 ]"
  local bad
  bad=$("$CPUQ" run --label ../../x:y -- echo ran 2>&1); rc=$?
  check "a label outside project:task of [a-z0-9._-] is a usage error, never running (rc $rc: '$(echo "$bad" | head -1)')" "[[ \$rc = 2 && \"\$bad\" == *'lowercase letters'* ]] && ! grep -qx ran <<<\"\$bad\""
  local how
  # SIGINT at its default first: a suite started as a `&` job hands it down
  # ignored, cpuq keeps it ignored for the command, and sh survives its kill.
  how=$(python3 -c "
import signal, subprocess
signal.signal(signal.SIGINT, signal.SIG_DFL)
r = subprocess.run(['$CPUQ', 'run', '--', 'sh', '-c', 'kill -INT \$\$'])
print(r.returncode)")
  check "cpuq re-raises the command's SIGINT: the parent sees death by signal 2 (got $how)" "[ '$how' = -2 ]"
  "$CPUQ" run -- /nonexistent/cmd 2>/dev/null; rc=$?
  check "a missing command is 127 (got $rc)" "[ $rc = 127 ]"
}

t_direct_sigint() {
  setup direct-sigint
  local f=$T/ints
  dfl "$CPUQ" run -- sh -c "trap 'echo INT >>$f; exit 3' INT; : >$T/trapped; while :; do sleep 0.05; done" & local p=$!
  # Signal only once the trap is set: the shell ignores SIGINT for a moment while it sets one.
  local i=0
  until [ -e "$T/trapped" ]; do i=$((i + 1)); [ $i -gt 100 ] && break; sleep 0.1; done
  kill -INT $p
  # Never hang the suite: a lost signal fails here after 10 s.
  (i=0; while kill -0 $p 2>/dev/null && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done; kill -KILL $p 2>/dev/null) & local guard=$!
  wait $p; local rc=$?
  wait $guard
  local n; n=$(wc -l <"$f" 2>/dev/null | tr -d ' ')
  check "kill -INT to cpuq reaches the command once (got ${n:-0}, exit $rc)" "[ '$n' = 1 ] && [ $rc = 3 ]"
}

t_terminal_sigint() {
  setup terminal-sigint
  local f=$T/ints
  # A pty makes the run a foreground job; ^C goes to the whole process group.
  local out
  out=$(python3 - "$CPUQ" "$f" <<'EOF'
import os, pty, signal, sys, time
cpuq, f = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    # The command counts its own SIGINTs: no shell in between, whose handling
    # of a child killed by ^C depends on timing.
    os.execv(cpuq, [cpuq, "run", "--", sys.executable, "-c",
        "import signal, sys, time\n"
        "n = []\n"
        "signal.signal(signal.SIGINT, lambda *a: n.append(1))\n"
        "end = time.time() + 1.5\n"
        "while time.time() < end: time.sleep(0.05)\n"
        "open(%r, 'w').write('INT\\n' * len(n))\n"
        "sys.exit(4)\n" % f])
time.sleep(0.8)
os.write(fd, b"\x03")
deadline = time.time() + 10
status = None
while time.time() < deadline:
    try:
        os.read(fd, 1024)
    except OSError:
        pass
    p, st = os.waitpid(pid, os.WNOHANG)
    if p:
        status = os.waitstatus_to_exitcode(st)
        break
    time.sleep(0.05)
n = sum(1 for _ in open(f)) if os.path.exists(f) else 0
print(n, status)
EOF
)
  check "^C at a terminal reaches the command exactly once (ints, exit: $out)" "[ '$out' = '1 4' ]"
}

t_tasks_sigint() {
  # SIGINT to a run of tasks goes to each task's group; the run dies by it once they end.
  setup tasks-sigint
  local out
  out=$(python3 - "$CPUQ" "$T" <<'EOF'
import os, signal, subprocess, sys, time
cpuq, t = sys.argv[1], sys.argv[2]
p = subprocess.Popen([cpuq, "run", "-n", "2", "--", "sh", "-c", 'trap "echo INT >>$0/ints; exit 5" INT; : >$0/up.$CPUQ_TASK; while :; do sleep 0.05; done', t],
                     stderr=subprocess.DEVNULL, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
end = time.time() + 10
while time.time() < end and not (os.path.exists(t + "/up.1") and os.path.exists(t + "/up.2")): time.sleep(0.05)
time.sleep(0.2)
p.send_signal(signal.SIGINT)
try: rc = p.wait(10)
except subprocess.TimeoutExpired: p.kill(); rc = "hung"
n = sum(1 for _ in open(t + "/ints")) if os.path.exists(t + "/ints") else 0
print(n, rc)
EOF
)
  check "SIGINT to a run of 2 reaches each task once, and the run dies by it (ints, status: $out)" "[ '$out' = '2 -2' ]"
}

t_ignored_signals() {
  setup ignored-signals
  local sig base got
  for sig in HUP INT; do
    # What `nohup` or a `&` job in a script hands down: the signal ignored.
    base=$( (trap '' $sig; sh -c "kill -$sig \$\$; echo survived") )
    got=$( (trap '' $sig; "$CPUQ" run -- sh -c "kill -$sig \$\$; echo survived") )
    check "a SIG$sig ignored by the caller stays ignored for the command (without cpuq: '$base'; with: '$got')" "[ '$base' = survived ] && [ '$got' = survived ]"
  done
}

t_stack_limit() {
  # A task gets its caller's stack limit as it was: a Zig program raises its own to the stack it
  # was built with, which every task would inherit.
  setup stack-limit
  local got; got=$( (ulimit -s 4096 && "$CPUQ" run -- sh -c 'ulimit -s') 2>/dev/null)
  check "a task keeps its caller's stack limit (4096, got $got)" "[ '$got' = 4096 ]"
}

# --- Linux: pinning --------------------------------------------------------------------------

t_pin() {
  # Linux: each task is pinned to its CPU (CPUQ_CPU), one task or many; a drain's command has
  # every CPU this shell may use.
  setup pin
  if [ "$(uname)" != Linux ]; then echo "  skipped: Linux only"; return; fi
  local list='sed -n "s/^Cpus_allowed_list:[[:space:]]*//p" /proc/self/status'
  "$CPUQ" run -n 4 --label p:x -- sh -c "echo \$CPUQ_CPU=\$($list) >>$T/pins; sleep 0.2" 2>/dev/null
  local single; single=$("$CPUQ" run -- sh -c "echo \$CPUQ_CPU=\$($list)")
  local mine; mine=$(eval "$list")
  local drain; drain=$("$CPUQ" drain --max 20s -- sh -c "$list")
  local pinned; pinned=$(awk -F= '$1 == $2' "$T/pins" | wc -l | tr -d ' ')
  check "tasks pinned to their CPU ($(tr '\n' ' ' <"$T/pins"); $pinned of 4), one task too ($single); a drain's command unpinned ($drain, this shell: $mine)" \
    "[ $pinned = 4 ] && [ \"\${single%%=*}\" = \"\${single#*=}\" ] && [ '$drain' = '$mine' ]"
}

t_repin() {
  # Linux: a run stopped (Ctrl-Z) and continued on another CPU moves its task there.
  setup repin
  if [ "$(uname)" != Linux ]; then echo "  skipped: Linux only"; return; fi
  dfl "$CPUQ" run -n 1 --label r:a -- sh -c 'while [ ! -e "$1.stop" ]; do sed -n "s/^Cpus_allowed_list:[[:space:]]*//p" /proc/self/status >"$1.new"; mv "$1.new" "$1"; sleep 0.05; done' sh "$T/cpu" 2>/dev/null & local a=$!
  wait_file "$T/cpu"
  local before; before=$(cat "$T/cpu")
  kill -TSTP $a
  poll 5 '[ "$(held)" = 0 ]'
  "$CPUQ" run --label r:b -- sh -c 'echo $CPUQ_CPU >"$1"; sleep 3' sh "$T/b" & local b=$!
  wait_file "$T/b"
  kill -CONT $a
  local after; poll 5 '[ "$(cat "$T/cpu")" != "$before" ]'; after=$(cat "$T/cpu")
  touch "$T/cpu.stop"
  reap $a; local ra=$?
  wait $b
  check "stopped on CPU $before, which a newcomer took ($(cat "$T/b")), the task goes on pinned to CPU $after (rc $ra)" "[ '$before' = \"\$(cat '$T/b')\" ] && [ '$after' != '$before' ] && [ -n '$after' ] && [ $ra = 0 ]"
}

t_narrow() {
  # Linux: a run started inside a narrower CPU set (taskset, an outer cpuq's pin) still uses its
  # whole pool: 4 tasks of 0.5 s at -c 2 on a pool of 2 take about 1 s, and a drain gets the pool.
  setup narrow "outside_check = on"
  if [ "$(uname)" != Linux ] || ! command -v taskset >/dev/null; then echo "  skipped: Linux with taskset only"; return; fi
  local first; first=$(poolcpus); first=${first%% *}
  local t0 rc dt; t0=$(now)
  taskset -c "$first" "$CPUQ" run -n 4 --label n:x -- sleep 0.5 2>/dev/null; rc=$?
  dt=$(since "$t0")
  taskset -c "$first" "$CPUQ" drain --max 3s -- true 2>/dev/null; local rd=$?
  # The outside-load room counts the machine's CPUs, not the caller's CPU set.
  check "under taskset -c $first, a run of 4 uses the pool of 2 (rc $rc, ${dt}s) and a drain gets it (rc $rd)" "[ $rc = 0 ] && fl '$dt < 1.8' && [ $rd = 0 ]"
}

# --- status, history, wait -------------------------------------------------------------------

t_status() {
  setup status
  "$CPUQ" run -n 4 --label s:build -- sleep 1.5 2>/dev/null & wait_held 2
  "$CPUQ" run --label t:big -- true & wait_waiters 1
  local s; s=$("$CPUQ" status --no-usage)
  local j; j=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
m = s["memory"]
h = s["holders"][0]; w = s["waiters"][0]
print(s["schema"], s["version"] == sys.argv[1].split()[1], s["admit"], s["budget"], len(s["pool"]), s["held"], s["free"], s["gate"]["state"], s["memory_pressure"],
      0 < m["used"] <= m["total"], h["label"], h["tasks"], h["cores"], len(h["cpus"]), w["label"], w["order"], w["why"].startswith("1st in line"),
      " ".join(sorted(p["name"] for p in s["projects"])))' "$("$CPUQ" --version)")
  wait
  echo "$s" | sed 's/^/  | /'
  check "status shows the pool, the holder and the waiter with why it waits" "[[ '$s' == *\"dir     $CPUQ_DIR/v2\"* && '$s' == *'pool    2 CPUs'* && '$s' == *s:build* && '$s' == *t:big* && '$s' == *'1st in line'* && '$s' == *'memory  '*' GB used'* ]]"
  check "status --json: schema 2, the pool, holders, waiters and projects (got '$j')" "[ '$j' = '2 True pool 2 2 2 0 open off True s:build 4 2 2 t:big 1 True s t' ]"
}

t_progress() {
  # A run of tasks shows its progress (tasks ended of all, with those failed) and the time left
  # in status.
  setup progress
  "$CPUQ" run -n 8 -c 1 --label p:count -- sh -c 'sleep 0.3; [ "$CPUQ_TASK" != 1 ]' 2>/dev/null & local p=$!
  sleep 1.4
  local got; got=$(sj '[(h["progress"]["done"] >= 2, h["progress"]["total"], h["progress"]["failing"], h["left"] is not None and h["left"] > 0, h["left_from"]) for h in s["holders"]][0]')
  local text; text=$("$CPUQ" status --no-usage | grep 'p:count')
  wait $p
  check "status shows a run's progress and time left (got $got; '$(echo $text)')" "[ \"$got\" = \"(True, 8, 1, True, 'progress')\" ] && [[ '$text' == *'/8'* ]]"
}

t_usage() {
  # status measures what each run's tasks use: a 1-CPU spinner about 1, a sleeper about 0; after
  # 5 s it flags a run whose CPUs sit mostly idle.
  setup usage
  "$CPUQ" run --label u:spin -- python3 -c 'import time
e = time.time() + 9
while time.time() < e: pass' &
  "$CPUQ" run --label u:idle -- sleep 9 &
  wait_held 2
  sleep 1
  local u; u=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
print(" ".join("%s=%.2f" % (h["label"], h["using"]) for h in sorted(s["holders"], key=lambda h: h["label"])))')
  sleep 4.3
  local flags; flags=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
print(" ".join("%s:%s" % (h["label"], ",".join(h["flags"]) or "-") for h in sorted(s["holders"], key=lambda h: h["label"])))')
  wait
  echo "  measured use: $u; flags: $flags"
  check "status measures use: a spinner about 1, a sleeper about 0 ($u)" "python3 -c '
import sys
u = dict(p.split(\"=\") for p in \"$u\".split())
sys.exit(0 if 0.6 < float(u[\"u:spin\"]) < 1.3 and float(u[\"u:idle\"]) < 0.2 else 1)'"
  check "status flags the idle run, not the busy one ($flags)" "[[ '$flags' == *'u:idle:low_use'* && '$flags' != *'u:spin:low_use'* ]]"
}

t_zombie() {
  setup zombie
  # A child spins a second, then waits as a zombie until its parent reaps it. Its CPU must count
  # while it is a zombie: missed, the parent's reaped-children time leaps by the child's whole
  # second at the reap.
  "$CPUQ" run --label zombie -- python3 -c 'import os, time
for _ in range(3):
    pid = os.fork()
    if pid == 0:
        e = time.time() + 1
        while time.time() < e: pass
        os._exit(0)
    time.sleep(1.6)
    os.waitpid(pid, 0)' & local job=$!
  wait_held 1
  local top=0 u
  while kill -0 $job 2>/dev/null; do
    u=$("$CPUQ" status --json | python3 -c 'import json, sys; print(max([h.get("using") or 0 for h in json.load(sys.stdin)["holders"]] or [0]))')
    top=$(python3 -c "print(max($top, $u))")
  done
  echo "  zombie: highest use $top"
  check "a reaped zombie's CPU does not leap into its parent's (got $top)" "fl '$top < 1.6'"
}

t_outside() {
  # status names work outside cpuq and leaves an operation's own tasks out. It lists the five
  # busiest outside processes: on a busy machine a full list without the stray is right too.
  setup outside
  python3 -c 'import time
e = time.time() + 3
while time.time() < e: pass' & local stray=$!
  "$CPUQ" run --label inside -- python3 -c 'import time
e = time.time() + 3
while time.time() < e: pass' & local op=$!
  wait_held 1
  sleep 0.5
  local mine; mine="$op $(descendants $op | tr '\n' ' ')"
  local got; got=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
stray = int(sys.argv[1]); mine = {int(p) for p in sys.argv[2].split()}
out = s["outside"]
pids = [o["pid"] for o in out]
named = stray in pids or len(out) >= 5
own_out = not (mine & set(pids))
used = sum(h["using"] or 0 for h in s["holders"])
print("named" if named else "missed", "own-out" if own_out else "own-listed", "%.1f" % used)' "$stray" "$mine")
  wait
  echo "  $got (stray pid $stray)"
  check "status names an outside process and leaves the operation's own out ($got)" "[[ '$got' == 'named own-out '* ]] && fl '${got##* } > 0.1'"
}

t_status_host() {
  setup status-host
  fake_ssh
  "$CPUQ" run -n 2 --label far:job -- sleep 2 2>/dev/null & wait_held 2
  local got; got=$(PATH="$T/bin:$PATH" "$CPUQ" status --json --no-usage --host local --host far | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(" ".join("%s:%d" % (h, d[h]["held"]) for h in sorted(d)))')
  check "status --host gives one JSON object keyed by host (got $got)" "[ '$got' = 'far:2 local:2' ]"
  local text; text=$(PATH="$T/bin:$PATH" "$CPUQ" status --no-usage --host far)
  check "status --host passes the host's own text through when piped" "[[ '$text' == *'held 2'* ]]"
  "$CPUQ" status --watch >/dev/null 2>&1; local rc=$?
  check "status --watch refuses when not on a terminal (got $rc)" "[ $rc = 2 ]"
  wait
}

t_history() {
  setup history
  "$CPUQ" run --label h:build -- python3 -c 'import os, time
def spin():
    # A second of CPU time each, however busy the machine is.
    e = time.process_time() + 1
    while time.process_time() < e: pass
if os.fork() == 0: spin(); os._exit(0)
spin(); os.wait()'
  "$CPUQ" run --label h:fail -- sh -c 'exit 3'
  "$CPUQ" run -n 4 --label h:tasks -- sh -c '[ "$CPUQ_TASK" != 2 ]' 2>/dev/null
  "$CPUQ" run -n 2 --label h:hog -- sleep 1.5 2>/dev/null & wait_held 2
  "$CPUQ" run --label h:impatient --wait-max 0 -- true 2>/dev/null
  wait
  "$CPUQ" run --label h:crash -- sleep 30.583 & local p=$!
  wait_held 1
  local kids; kids=$(descendants $p)
  kill -9 $p; kill $kids 2>/dev/null; sleep 0.2
  local got; got=$("$CPUQ" history --json | python3 -c 'import json, sys
j = {x["label"]: x for x in json.load(sys.stdin)}
b = j["h:build"]; t = j["h:tasks"]
print(b["state"], b["cores"], "%.1f" % ((b["used"] or 0) * (b["ran"] or 0)), j["h:fail"]["exit"], "%s/%s/%s/%s" % (t["tasks"], t["done"], t["failed"], t["exit"]),
      j["h:hog"]["cores"], j["h:hog"]["exit"], j["h:impatient"]["state"], j["h:crash"]["state"])')
  echo "  history: $got"
  check "history records CPUs, CPU time (both spinners, about 2 s), exit, tasks, give-up and loss (got: $got)" "python3 -c '
import sys
f = \"$got\".split()
ok = f[0] == \"done\" and f[1] == \"1\" and 1.7 < float(f[2]) < 2.6 and f[3:] == [\"3\", \"4/3/1/1\", \"2\", \"0\", \"gave_up\", \"lost\"]
sys.exit(0 if ok else 1)'"
  local n; n=$("$CPUQ" history --label 'h:b*' --json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')
  check "history --label filters by prefix (got $n)" "[ '$n' = 1 ]"
  local text; text=$("$CPUQ" history)
  check "history prints a summary with the lost run" "[[ '$text' == *'6 runs; waited'* && '$text' == *'1 lost'* && '$text' == *'4/4 · 1 failed'* ]]"
}

t_note() {
  # --note travels beside the label into history.
  setup note
  "$CPUQ" run --label proj:build --note "#224 markers" -- true
  local hist; hist=$("$CPUQ" history --json | python3 -c 'import json, sys; j = json.load(sys.stdin)[0]; print(j["label"], "|", j["note"])')
  check "--note is kept beside the label (history: $hist)" "[ '$hist' = 'proj:build | #224 markers' ]"
}

t_wait() {
  setup wait
  "$CPUQ" run --label job:a -- sleep 2 &
  "$CPUQ" run -n 2 --label job:b -- sleep 0.5 2>/dev/null &
  wait_holder job:a
  local t0; t0=$(now)
  "$CPUQ" wait --label 'job:*'; local rc=$?
  local dt; dt=$(since "$t0")
  check "cpuq wait --label 'job:*' returns when the last matching run ends (exit $rc after ${dt}s)" "[ $rc = 0 ] && fl '1 < $dt < 5'"
  "$CPUQ" run --label long -- sleep 3 & wait_holder long
  "$CPUQ" wait --label long --max-wait 1; rc=$?
  check "cpuq wait --max-wait gives up with 75 (got $rc)" "[ $rc = 75 ]"
  wait
}

t_record() {
  # cpuq record samples the machine into samples.jsonl beside the history; one runs at a time,
  # status says whether one does, and cpuq samples gives its lines from a time on.
  setup record
  export CPUQ_HISTORY=$T/history.jsonl
  "$CPUQ" run -n 2 --label held -- sleep 2 2>/dev/null & wait_held 2
  "$CPUQ" record --interval 0.2 2>/dev/null & local r=$!
  sleep 1.2
  "$CPUQ" record --interval 0.2 2>/dev/null; local second=$?
  local on; on=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; print(json.load(sys.stdin)["recorder"])')
  kill $r; wait $r 2>/dev/null; wait
  local got; got=$("$CPUQ" samples --since 0 | python3 -c 'import json, sys
s = [json.loads(l) for l in sys.stdin]
print(len(s), all(x["gate"] == "open" for x in s), max(x["held"] for x in s), len(s[-1]["cpu"]) > 0)')
  local future; future=$("$CPUQ" samples --since 9999999999 | wc -l | tr -d ' ')
  unset CPUQ_HISTORY
  check "record samples while another refuses to start (rc $second), status sees it ($on), and samples gives them from a time on (count, gate open, held, cpus: $got; none from the future: $future)" \
    "[[ $second = 0 && $on = True && '$got' == *' True 2 True' && $future = 0 ]] && [ \$(echo '$got' | cut -d' ' -f1) -ge 3 ]"
}

# --- The gates -------------------------------------------------------------------------------

t_min_available() {
  setup min-available "min_available = 1000000G"
  "$CPUQ" run --wait-max 1 -- true 2>/dev/null; local rc=$?
  local state; state=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; g = json.load(sys.stdin)["gate"]; print(g["state"], "with-available" if (g.get("available") or 0) > 0 else "no-available")')
  setup min-available-low "min_available = 1M"
  "$CPUQ" run --wait-max 1 -- true; local rc2=$?
  check "under min_available nothing starts (rc $rc, gate $state); above it, it does (rc $rc2)" "[ $rc = 75 ] && [ '$state' = 'low_memory with-available' ] && [ $rc2 = 0 ]"
}

t_min_disk() {
  setup min-disk "min_disk = 1000000G"
  "$CPUQ" run --wait-max 1 -- true 2>/dev/null; local rc=$?
  local got; got=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; g = json.load(sys.stdin)["gate"]; print(g["state"], "with-free" if (g.get("disk_free") or 0) > 0 else "no-free", "with-path" if g.get("disk_path") else "no-path")')
  local text; text=$("$CPUQ" status --no-usage | grep '^load')
  setup min-disk-low "min_disk = 1M"
  "$CPUQ" run --wait-max 1 -- true; local rc2=$?
  check "under min_disk nothing starts (rc $rc, gate $got, '$text'); above it, it does (rc $rc2)" "[ $rc = 75 ] && [ '$got' = 'low_disk with-free with-path' ] && [[ '$text' == *'disk low'* ]] && [ $rc2 = 0 ]"
}

# --- The hook --------------------------------------------------------------------------------

t_hook() {
  # cpuq hook: Claude Code's PreToolUse hook refuses heavy commands outside cpuq and misuses of it
  # (exit 2, the fix on stderr), and passes everything else; --driver only for a test runner.
  setup hook
  call() { printf '{"tool_name":"%s","tool_input":{"command":%s},"cwd":"/x/app"}' "$2" "$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$3")" | "$CPUQ" hook 2>"$T/$1"; echo $?; }
  local bare good alljobs cores tasks light other off driver drvbuild drvother
  bare=$(call bare Bash 'cd x && zig build test')
  good=$(call good Bash 'cpuq run --label app:build -- zig build -j1')
  alljobs=$(call alljobs Bash 'cpuq run --label app:build -- zig build')
  cores=$(call cores Bash "cpuq run --label app:build --cores 2-6 -- sh -c 'zig build -j\"\$CPUQ_CORES\"'")
  tasks=$(call tasks Bash 'cpuq run -n 40 --label app:test -- ./test/one "$CPUQ_TASK"')
  light=$(call light Bash 'git status')
  other=$(call other Read 'zig build')
  off=$(printf '{"tool_name":"Bash","tool_input":{"command":"make"}}' | CPUQ_HOOK=off "$CPUQ" hook; echo $?)
  check "the hook refuses a bare build with the fix (rc $bare), passes a run at one job, a run of tasks, light commands, other tools and CPUQ_HOOK=off (rc $good $tasks $light $other $off)" \
    "[ $bare = 2 ] && grep -q 'Run instead: cpuq run --label app:test -- zig build test -j1' '$T/bare' && [ $good = 0 ] && [ $tasks = 0 ] && [ $light = 0 ] && [ $other = 0 ] && [ $off = 0 ]"
  check "inside cpuq run it refuses a build at every CPU (rc $alljobs) and --cores with \$CPUQ_CORES (rc $cores), each with the run at one job" \
    "[ $alljobs = 2 ] && grep -q 'Run instead: cpuq run --label app:build -- zig build -j1' '$T/alljobs' && [ $cores = 2 ] && grep -q -- '--cores is gone' '$T/cores' && grep -q 'Run instead: cpuq run --label app:build -- zig build -j1' '$T/cores'"
  driver=$(call driver Bash 'cpuq run --driver --label app:test -- test/run.sh')
  drvbuild=$(call drvbuild Bash 'cpuq run --driver --label app:build -- zig build -j1')
  drvother=$(call drvother Bash 'cpuq run --driver --label app:x -- ./foo')
  check "--driver passes for a test runner (rc $driver), not for a build (rc $drvbuild) or anything else (rc $drvother)" \
    "[ $driver = 0 ] && [ $drvbuild = 2 ] && grep -q 'under --driver' '$T/drvbuild' && [ $drvother = 2 ] && grep -q 'one task, on one CPU' '$T/drvother'"
}

# --- Leases ----------------------------------------------------------------------------------

t_lease() {
  setup lease
  local f=$T/log
  "$CPUQ" lease bench --label first -- sh -c "echo first >>$f; sleep 1; echo first-done >>$f" & wait_line "$f" first
  "$CPUQ" lease bench --label second -- sh -c "echo second >>$f" & poll 10 '[ "$(lease_waiters bench)" = 1 ]'
  "$CPUQ" lease bench --label third -- sh -c "echo third >>$f" & poll 10 '[ "$(lease_waiters bench)" = 2 ]'
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "a named lease is one at a time, first come first served (got: $got)" "[ '$got' = 'first first-done second third ' ]"
  local env; env=$("$CPUQ" lease bench -- sh -c 'echo "$CPUQ_LEASES"')
  check "the command gets CPUQ_LEASES (got '$env')" "[[ '$env' == bench=* ]]"
  local t0; t0=$(now)
  local inner; inner=$("$CPUQ" lease bench -- "$CPUQ" lease bench -- sh -c 'echo inner')
  local dt; dt=$(since "$t0")
  check "a lease inside the same lease starts at once (${dt}s, '$inner')" "[ '$inner' = inner ] && fl '$dt < 1'"
  "$CPUQ" lease bench -- sh -c "touch $T/up; sleep 2" & poll 5 "[ -e '$T/up' ]"
  "$CPUQ" lease bench --wait-max 1 -- true 2>/dev/null; local rc=$?
  check "--wait-max gives up on a held lease with 75 (got $rc)" "[ $rc = 75 ]"
  "$CPUQ" lease bench --cores 2 -- true 2>/dev/null; local rcores=$?
  "$CPUQ" lease bench --priority high -- true 2>/dev/null; local rprio=$?
  check "run's removed options are refused for a lease (--cores $rcores, --priority $rprio)" "[ $rcores = 2 ] && [ $rprio = 2 ]"
  local h; h=$(held)
  check "a lease holds no CPU of the pool (held $h)" "[ '$h' = 0 ]"
  wait
  local g=$T/slots
  "$CPUQ" lease db --slots 2 -- sh -c "echo a >>$g; sleep 1" &
  "$CPUQ" lease db --slots 2 -- sh -c "echo b >>$g; sleep 1" &
  poll 5 "[ \"\$(wc -l <'$g' 2>/dev/null | tr -d ' ')\" = 2 ]"
  local two; two=$(wc -l <"$g" | tr -d ' ')
  "$CPUQ" lease db --slots 2 --wait-max 0 -- true 2>/dev/null; rc=$?
  wait
  check "--slots 2 lets two hold at once and a third waits (holding: $two, third: $rc)" "[ '$two' = 2 ] && [ $rc = 75 ]"
}

t_lease_host() {
  setup lease-host
  fake_ssh
  local f=$T/log bin=$T/bin
  PATH="$bin:$PATH" "$CPUQ" lease bench --host far --label mac-gate -- sh -c "echo \"\$CPUQ_LEASES\" >$T/env; echo gate >>$f; sleep 1; echo gate-done >>$f" &
  wait_line "$f" gate
  "$CPUQ" lease bench --label far-local -- sh -c "echo far-local >>$f" & poll 10 '[ "$(lease_waiters bench)" = 1 ]'
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "a lease held from another machine queues with that machine's own users (got: $got)" "[ '$got' = 'gate gate-done far-local ' ]"
  check "the command gets NAME@HOST=ID:PID in CPUQ_LEASES ($(cat $T/env))" "grep -q '^bench@far=[0-9]*:[0-9]*\$' $T/env"
  local t0; t0=$(now)
  local inner; inner=$(PATH="$bin:$PATH" "$CPUQ" lease bench --host far -- "$CPUQ" lease bench --host far -- sh -c 'echo inner')
  local dt; dt=$(since "$t0")
  check "a --host lease inside the same one starts at once (${dt}s, '$inner')" "[ '$inner' = inner ] && fl '$dt < 2'"
  PATH="$bin:$PATH" "$CPUQ" lease bench --host far -- sh -c "touch $T/up; sleep 30" & local p=$!
  poll 10 "[ -e '$T/up' ]"
  local kids; kids=$(descendants $p)
  t0=$(now)
  kill -9 $p
  "$CPUQ" lease bench --wait-max 5 -- true; local rc=$?
  dt=$(since "$t0")
  check "a killed --host holder frees the remote lease at once (exit $rc after ${dt}s)" "[ $rc = 0 ] && fl '$dt < 2'"
  kill $kids 2>/dev/null
  rm -f "$T/up"
  "$CPUQ" lease bench -- sh -c "touch $T/up; sleep 2" & poll 10 "[ -e '$T/up' ]"
  PATH="$bin:$PATH" "$CPUQ" lease bench --host far --wait-max 1 -- true 2>/dev/null; rc=$?
  check "--wait-max on a --host lease gives 75 (got $rc)" "[ $rc = 75 ]"
  wait
}

t_lease_host_hold() {
  setup lease-host-hold
  fake_ssh
  # A script holds the lease from the middle of its run: a coprocess that
  # prints the CPUQ_LEASES entry once granted and holds until closed.
  local out
  out=$(PATH="$T/bin:$PATH" /bin/bash -c '
    # Two named pipes and a background cpuq: works in any bash, 3.2 included.
    d=$(mktemp -d); mkfifo "$d/in" "$d/out"
    "$1" lease bench --host far --hold <"$d/in" >"$d/out" & hold=$!
    exec 8>"$d/in"
    read -r word name entry <"$d/out"
    echo "$word $name $entry"
    export CPUQ_LEASES="$entry"
    # Inside it, the same lease starts at once ...
    "$1" lease bench --host far -- echo nested
    # ... and holding it again holds nothing.
    echo | "$1" lease bench --host far --hold | sed "s/^/again /"
    # Someone else waits for it.
    CPUQ_LEASES= "$1" lease bench --wait-max 1 -- true 2>/dev/null; echo "other $?"
    exec 8>&-; wait $hold
    CPUQ_LEASES= "$1" lease bench --wait-max 3 -- true; echo "after $?"
    rm -rf "$d"
  ' _ "$CPUQ")
  echo "$out" | sed 's/^/  /'
  check "--hold --host prints the held entry" "echo '$out' | grep -qE '^held bench@far bench@far=[0-9]+:[0-9]+\$'"
  check "inside the hold, the lease starts at once, and holding it again holds nothing" "echo '$out' | grep -qx nested && echo '$out' | grep -qE '^again held bench@far bench@far='"
  check "others wait while it is held, and get it once it is closed" "echo '$out' | grep -qx 'other 75' && echo '$out' | grep -qx 'after 0'"
}

t_hold_gone() {
  setup hold-gone
  # A hold for someone who goes away ends, waiting or holding: when its stdin
  # closes, or when the heartbeats it had stop (a dropped connection).
  "$CPUQ" lease bench --hold --label first < <(sleep 30) >"$T/first" & local h=$!
  wait_file "$T/first"
  mkfifo "$T/w"
  "$CPUQ" lease bench --hold --label waiter <"$T/w" >/dev/null 2>"$T/err" & local w=$!
  exec 7>"$T/w"
  poll 10 '[ "$(lease_waiters bench)" = 1 ]'
  local t0; t0=$(now)
  exec 7>&-
  wait $w; local rw=$?
  local dw; dw=$(since "$t0")
  kill $h 2>/dev/null; wait $h 2>/dev/null
  # Heartbeats, then silence with the pipe still open: the hold ends after
  # CPUQ_HOLD_QUIET seconds.
  mkfifo "$T/b"
  CPUQ_HOLD_QUIET=1 "$CPUQ" lease bench --hold --label quiet <"$T/b" >"$T/out" & local q=$!
  exec 6>"$T/b"
  echo >&6
  wait_file "$T/out"
  local t1; t1=$(now)
  wait $q; local rq=$?
  local dq; dq=$(since "$t1")
  exec 6>&-
  check "a waiting hold whose stdin closes gives up (rc $rw, ${dw}s); a held one whose heartbeats stop ends (rc $rq, ${dq}s)" "[ $rw = 75 ] && [ $rq = 0 ] && grep -q 'has gone' '$T/err' && fl '$dw < 3 and $dq < 4'"
}

t_last_words() {
  # Killed while they hold, a --hold lease here and one on a host end by the signal, kept so in
  # history; closed and killed at once (the kit's release), a hold still ends; nothing is lost.
  setup last-words
  fake_ssh
  local bin=$T/bin
  mkfifo "$T/in1" "$T/in2"
  "$CPUQ" lease near --hold --label near <"$T/in1" >"$T/o1" & local h1=$!
  exec 7>"$T/in1"
  wait_file "$T/o1"
  kill -HUP $h1; wait $h1; local rc_h1=$?
  exec 7>&-
  PATH="$bin:$PATH" "$CPUQ" lease far --host far --hold --label far <"$T/in2" >"$T/o2" & local h2=$!
  exec 6>"$T/in2"
  wait_file "$T/o2"
  kill -TERM $h2; wait $h2; local rc_h2=$?
  exec 6>&-
  local n
  for n in 1 2 3 4 5; do
    mkfifo "$T/k$n"
    if [ $((n % 2)) = 1 ]; then
      "$CPUQ" lease near --hold --label kit <"$T/k$n" >"$T/ko$n" & h1=$!
    else
      PATH="$bin:$PATH" "$CPUQ" lease far --host far --hold --label kit-far <"$T/k$n" >"$T/ko$n" & h1=$!
    fi
    exec 7>"$T/k$n"
    wait_file "$T/ko$n"
    exec 7>&-; kill $h1 2>/dev/null; wait $h1 2>/dev/null
  done
  sleep 0.3
  local got; got=$("$CPUQ" history --json | python3 -c 'import json, sys
print(" ".join("%s%s:%s:%s" % (j["label"], "@" + j["host"] if j["host"] else "", j["state"], j["signal"]) for j in sorted(json.load(sys.stdin), key=lambda j: j["queued"])))')
  echo "  exits $rc_h1 $rc_h2; history: $got"
  check "killed while held, a --hold lease ends by the signal, here and on a host" "[ $rc_h1 = 129 ] && [ $rc_h2 = 143 ] && [[ '$got' == *'near:done:1 '* && '$got' == *'far@far:done:15'* ]]"
  local kit; kit=$(echo "$got" | tr ' ' '\n' | grep -cE '^kit(-far@far)?:done:')
  check "closed and killed at once (the kit's release), a hold still ends, 5 of 5 (got $kit)" "[ '$kit' = 5 ]"
  check "nothing is lost" "[[ '$got' != *lost* ]]"
}

# --- Other machines --------------------------------------------------------------------------

t_on() {
  # --on HOST runs there whatever this machine's state; a host that neither answers nor has a
  # remote_start command is an error, not a quiet run here. HOST is one of this machine's
  # remotes, or this machine itself (which runs here).
  setup on "remotes = cpuq-test-nohost.invalid, x"
  cd "$REPO" || return
  local out rc
  out=$("$CPUQ" run --on cpuq-test-nohost.invalid -- echo ran-here 2>&1); rc=$?
  "$CPUQ" run --on x --include ../out -- true 2>/dev/null; local outside=$?
  "$CPUQ" run --include vendor -- true 2>/dev/null; local alone=$?
  check "--on an unreachable host without remote_start fails (rc $rc: '$out'), never running here; --include outside the repo (rc $outside) or without --on (rc $alone) is refused" \
    "[[ $rc = 125 && '$out' == *'does not answer'* && '$out' != *ran-here* && $outside = 2 && $alone = 2 ]]"
  local unknown urc self src
  unknown=$("$CPUQ" run --on cheese -- echo ran 2>&1); urc=$?
  self=$("$CPUQ" run --on "$(hostname -s)" -- echo ran-here 2>&1); src=$?
  unknown=$(printf '%s\n' "$unknown" | head -1)
  check "--on a host not among this machine's remotes is refused (rc $urc: '$unknown'); --on this machine runs here (rc $src: '$self')" \
    "[[ \$urc = 2 && \"\$unknown\" == *'not one of this machine'* && \$src = 0 && \$self = ran-here ]]"
  cd "$T" || return
}

t_include_git() {
  # `.git` in .cpuqinclude ships a standalone git: a worktree's commit and index, git's own parts,
  # and none of what else the repo keeps under .git.
  setup include-git "remotes = far"
  local bin=$T/bin far=$T/far
  mkdir -p "$bin" "$far"
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\ncd "%s" && exec sh -c "$*"\n' "$far" >"$bin/ssh"
  chmod +x "$bin/ssh"
  ln -sf "$CPUQ" "$bin/cpuq"
  (
    cd "$T" && git init -q repo && cd repo && git config user.email t@t && git config user.name t
    echo a > a.txt && echo b > b.txt && git add -A && git commit -qm one
    mkdir .git/big-cache && echo junk > .git/big-cache/x
    git worktree add -q "$T/wt" -b wt && cd "$T/wt" && echo c > c.txt && git add c.txt && git commit -qm two
    echo .git > .cpuqinclude
  ) >/dev/null 2>&1
  local want; want=$(git -C "$T/wt" rev-parse HEAD)
  local got; got=$(cd "$T/wt" && PATH="$bin:$PATH" "$CPUQ" run --on far -- sh -c 'test -d .git && echo dir; git rev-parse HEAD; git ls-files | tr "\n" " "; test -e .git/big-cache && echo junk || echo clean' 2>/dev/null | tr '\n' ' ')
  check "a worktree's .git ships as a git of its own (got '$got')" "[ '$got' = 'dir $want a.txt b.txt c.txt clean ' ]"
}

t_on_check() {
  # A copy sent with --on is read back by checksum: a file damaged there that kept its size and mtime
  # (rsync's quick check would never send it again) is sent again, and a copy that stays damaged
  # fails the run without running the job.
  setup on-check "remotes = far"
  local bin=$T/bin far=$T/far
  mkdir -p "$bin" "$far"
  # The far side, damaging a.txt after every connection while $T/rot exists.
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\n(cd "%s" && sh -c "$*"); rc=$?\nif [ -e "%s/rot" ]; then for f in $(find "%s" -name a.txt); do cp -p "$f" "%s/ref"; printf X | dd of="$f" conv=notrunc 2>/dev/null; touch -r "%s/ref" "$f"; done; fi\nexit $rc\n' "$far" "$T" "$far" "$T" "$T" >"$bin/ssh"
  chmod +x "$bin/ssh"
  ln -sf "$CPUQ" "$bin/cpuq"
  (cd "$T" && git init -q repo && cd repo && echo a > a.txt && git add a.txt) >/dev/null 2>&1
  (cd "$T/repo" && PATH="$bin:$PATH" "$CPUQ" run --on far -- true) >/dev/null 2>&1
  local copy; copy=$(find "$far" -name a.txt)
  cp -p "$copy" "$T/ref"; printf X | dd of="$copy" conv=notrunc 2>/dev/null; touch -r "$T/ref" "$copy"
  local mended; mended=$(cd "$T/repo" && PATH="$bin:$PATH" "$CPUQ" run --on far -- cat a.txt 2>&1)
  touch "$T/rot"
  local bad rc; bad=$(cd "$T/repo" && PATH="$bin:$PATH" "$CPUQ" run --on far -- echo ran 2>&1); rc=$?
  check "a copy damaged there is sent again ('$mended'); one that stays damaged fails, never running (rc $rc: '$bad')" \
    "[[ '$mended' == *'differed from here (a.txt)'*a && $rc = 125 && '$bad' == *'still differs from here'*a.txt* && '$bad' != *ran* ]]"
}

t_on_gitignore() {
  # A copy sent with --on leaves out what git ignores, as git reads .gitignore: a file its `!` line
  # brings back ships (rsync's own .gitignore filter dropped it), and a tracked file ships though
  # a pattern matches it; ignored files and folders stay behind.
  setup on-gitignore "remotes = far"
  local bin=$T/bin far=$T/far
  mkdir -p "$bin" "$far"
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\ncd "%s" && exec sh -c "$*"\n' "$far" >"$bin/ssh"
  chmod +x "$bin/ssh"
  ln -sf "$CPUQ" "$bin/cpuq"
  (
    cd "$T" && git init -q repo && cd repo && git config user.email t@t && git config user.name t
    printf 'data/*\n!data/keep.txt\nbuild/\n*.log\n' > .gitignore
    mkdir -p data build && echo k > data/keep.txt && echo d > data/drop.txt && echo x > build/x && echo s > build/ship.sh
    echo p > plain.txt && echo t > tracked.log && echo n > notes.log
    git add .gitignore plain.txt && git add -f tracked.log && git commit -qm one
  ) >/dev/null 2>&1
  local got; got=$(cd "$T/repo" && PATH="$bin:$PATH" "$CPUQ" run --on far -- sh -c 'find . -type f ! -path "./.git*" ! -name .cpuq-used | sort | tr "\n" " "' 2>/dev/null)
  check "a copy sent with --on takes what git ships: a \`!\` re-included file and a tracked one, none of the ignored (got '$got')" "[ '$got' = './data/keep.txt ./plain.txt ./tracked.log ' ]"
  # One file included from inside an ignored folder: it alone, not the rest of the folder.
  got=$(cd "$T/repo" && PATH="$bin:$PATH" "$CPUQ" run --on far --include build/ship.sh -- sh -c 'find ./build -type f | sort | tr "\n" " "' 2>/dev/null)
  check "--include of one file in an ignored folder takes it alone (got '$got')" "[ '$got' = './build/ship.sh ' ]"
}

t_tethered() {
  # --tethered (what --on runs on HOST): the command gets /dev/null for stdin, which carries the
  # caller's heartbeats, and is stopped when the caller goes (stdin closes), one task or many.
  setup tethered
  local out; out=$( (echo heartbeat; sleep 3) | "$CPUQ" run --tethered -- sh -c 'cat; echo done' 2>/dev/null)
  local t0 rc; t0=$(date +%s)
  (sleep 1) | "$CPUQ" run --tethered -- sleep 30 2>/dev/null; rc=$?
  local took=$(( $(date +%s) - t0 ))
  t0=$(date +%s)
  (sleep 1) | "$CPUQ" run -n 2 --tethered -- sleep 30 2>/dev/null; local rcn=$?
  local tookn=$(( $(date +%s) - t0 ))
  check "a tethered command reads /dev/null, not the heartbeats ('$out'), and stops once the caller goes (rc $rc after ${took}s; 2 tasks: rc $rcn after ${tookn}s)" \
    "[[ '$out' == done && $rc = 143 && $took -lt 10 && $rcn = 143 && $tookn -lt 10 ]]"
}

# --- cap and cgroups -------------------------------------------------------------------------

t_cap() {
  # cpuq cap: one program under limits; its own exit otherwise.
  setup cap
  "$CPUQ" cap -- sh -c 'exit 7'; local rc_exit=$?
  "$CPUQ" cap -- cpuq-test-no-such-program 2>/dev/null; local rc_missing=$?
  "$CPUQ" cap -- /cpuq-test/no/such/program 2>/dev/null; [ $? = 127 ] || rc_missing="$rc_missing, by path $?"
  local t0; t0=$(now)
  "$CPUQ" cap --time 1s -- sleep 30 2>/dev/null; local rc_time=$?
  local dt; dt=$(since "$t0")
  "$CPUQ" cap --mem 64M -- python3 -c 'import time; x = bytearray(256 << 20); time.sleep(10)' 2>/dev/null; local rc_mem=$?
  # A grandchild that leaves the group (": " keeps sh as its parent, not a group leader it became).
  "$CPUQ" cap --mem 64M -- sh -c 'python3 -c "import os, time; os.setsid(); x = bytearray(256 << 20); time.sleep(10)"; :' 2>/dev/null; local rc_escaped=$?
  t0=$(now)
  "$CPUQ" cap --output 1K -- sh -c 'head -c 100000 /dev/zero; sleep 10' >"$T/out" 2>"$T/err"; local rc_out=$?
  local dt_out; dt_out=$(since "$t0")
  "$CPUQ" cap --mem 0 -- true 2>/dev/null; local rc_zero=$?
  "$CPUQ" cap --pids off -- true 2>/dev/null; [ $? = 2 ] || rc_zero="$rc_zero, --pids off $?"
  "$CPUQ" cap --output 1K -- true 2>/dev/null | cat; local rc_pipe=${PIPESTATUS[0]}
  "$CPUQ" cap -- sh -c 'kill -TERM $$'; local rc_sig=$?
  "$CPUQ" cap --mem 1G -- sh -c 'sleep 77 & echo $! >"$1"; exit 0' sh "$T/bg"; sleep 0.3
  local left=0; alive "$T/bg" && left=1
  check "cap passes the exit on (7: $rc_exit), not found 127 ($rc_missing), time 124 ($rc_time after ${dt}s), memory 122 ($rc_mem; escaped the group: $rc_escaped), output 121 within 0.1 s or so ($rc_out after ${dt_out}s), a limit of 0 refused 2 ($rc_zero), a pipe refused 2 ($rc_pipe), a signal as itself 143 ($rc_sig), nothing left behind ($left)" "[ $rc_exit = 7 ] && [ $rc_missing = 127 ] && [ $rc_time = 124 ] && fl '$dt < 3' && [ $rc_mem = 122 ] && [ $rc_escaped = 122 ] && [ $rc_out = 121 ] && fl '$dt_out < 0.6' && [ $rc_zero = 2 ] && [ $rc_pipe = 2 ] && [ $rc_sig = 143 ] && [ $left = 0 ]"
  # Linux: cap is its tree's subreaper, so even an orphan that left the session goes with it
  # (macOS has none: that orphan is out of reach there, as cap's header says). A cap that was
  # meant to have a cgroup and couldn't says what that costs.
  [ "$(uname)" = Linux ] || return 0
  "$CPUQ" cap -- python3 -c 'import os, sys, time
if os.fork() == 0:
    os.setsid()
    if os.fork() == 0:
        open(sys.argv[1], "w").write(str(os.getpid())); time.sleep(77)
    os._exit(0)
os.wait(); time.sleep(0.3)' "$T/orphan"; sleep 0.3
  local orphan=0; alive "$T/orphan" && orphan=1
  local warn; warn=$(CPUQ_CGROUP=/sys/fs/cgroup/cpuq-none.scope "$CPUQ" cap --pids 5 -- true 2>&1)
  check "Linux: a setsid orphan goes with cap (left: $orphan); no cgroup is said ($warn)" "[ $orphan = 0 ] && [[ '$warn' == *'--pids is not enforced'* ]]"
}

t_cap_quiet_crash() {
  # cap --no-crash-report changes nothing about how PROGRAM dies: still by its signal (134 in a
  # shell), its stderr as it was; on macOS only the crash report is skipped.
  setup cap-quiet-crash
  local got; got=$(sh -c "\"$CPUQ\" cap --no-crash-report -- sh -c 'echo panic: on purpose >&2; kill -ABRT \$\$' 2>\"$T/err\"; echo \$?")
  check "cap --no-crash-report: PROGRAM still dies by its signal (status $got) with its stderr ($(cat "$T/err" | tr -d '\n'))" "[ '$got' = 134 ] && grep -q 'panic: on purpose' '$T/err'"
  # cpuq run passes a command's abort on as 134 too; on macOS by exit, as the shell sees it, not by
  # dying of it, which filed a crash report for cpuq in the system's folder.
  local run_rc; sh -c "\"$CPUQ\" run -- \"$CPUQ\" cap --no-crash-report -- sh -c 'kill -ABRT \$\$'" 2>/dev/null; run_rc=$?
  check "cpuq run passes a command's abort on as 134 (got $run_rc)" "[ $run_rc = 134 ]"
  local proto; proto=$("$CPUQ" cap --protocol)
  check "cap --protocol prints what cap does as a number (got '$proto')" "[[ '$proto' =~ ^[0-9]+\$ ]]"
  # Linux: PROGRAM's core limit is exactly 1, at which the kernel starts no core_pattern handler
  # (apport); without the flag it keeps the limit it was given.
  [ "$(uname)" = Linux ] || return 0
  local core='/^Max core file size/ { print $5, $6 }'
  local quiet plain want
  quiet=$("$CPUQ" cap --no-crash-report -- awk "$core" /proc/self/limits)
  plain=$("$CPUQ" cap -- awk "$core" /proc/self/limits)
  want=$(awk "$core" /proc/$$/limits)
  check "cap --no-crash-report on Linux: a core limit of 1 1 (got $quiet), and $want without it (got $plain)" "[ '$quiet' = '1 1' ] && [ '$plain' = '$want' ]"
}

t_cap_link() {
  # cap --link FD: when the pipe's write end closes (its driver died), cap stops the whole tree
  # at once, 123 with a line on stderr; bytes on the pipe mean nothing.
  setup cap-link
  local got; got=$(python3 - "$CPUQ" "$T" <<'PY'
import os, subprocess, sys, time
cpuq, t = sys.argv[1], sys.argv[2]
r, w = os.pipe()
p = subprocess.Popen([cpuq, "cap", "--link", str(r), "--", "sh", "-c", f"sleep 30 & echo $! > {t}/kid; sleep 30"],
                     pass_fds=[r], stderr=subprocess.PIPE, text=True)
os.close(r)
while not os.path.exists(f"{t}/kid") or not open(f"{t}/kid").read().strip(): time.sleep(0.02)
os.write(w, b"ping\n"); time.sleep(0.3)
alive = p.poll() is None
t0 = time.time(); os.close(w); rc = p.wait(); dt = time.time() - t0
kid = int(open(f"{t}/kid").read())
try: os.kill(kid, 0); gone = False
except ProcessLookupError: gone = True
print(alive, rc, dt < 1.5, gone, "driver is gone" in p.stderr.read())
PY
)
  check "cap --link: a byte changes nothing; the write end's close stops the tree at once with 123 (got '$got')" "[ '$got' = 'True 123 True True True' ]"
  local bad; "$CPUQ" cap --link 99 -- true 2>/dev/null; bad=$?
  check "cap --link refuses a closed descriptor with 2 (got $bad)" "[ $bad = 2 ]"
}

t_cgroups() {
  # (CPUQ_CGROUP is cleared where a check needs no scope around it: the suite may itself run inside
  # a cpuq job, whose scope a nested run rightly inherits.)
  # Linux with a user systemd: a --driver runs in a delegated scope, its command in job/, with
  # CPUQ_CGROUP naming the scope, and a cap inside it gets a cgroup of its own the kernel stops
  # at the limit (far sooner than the once-a-second read elsewhere). A plain run has no scope.
  setup cgroups
  local plain; plain=$(env -u CPUQ_CGROUP "$CPUQ" run --label plain -- sh -c 'echo "cg=${CPUQ_CGROUP:-none}"')
  check "a run of tasks has no scope of its own (got $plain)" "[ '$plain' = 'cg=none' ]"
  if [ "$(uname)" != Linux ] || ! systemd-run --user --scope --quiet true 2>/dev/null; then
    local got; got=$(env -u CPUQ_CGROUP "$CPUQ" run --driver --label plain -- sh -c 'echo "cg=${CPUQ_CGROUP:-none}"')
    check "without a user systemd a driver runs as it is (got $got)" "[ '$got' = 'cg=none' ]"
    return
  fi
  local got; got=$("$CPUQ" run --driver --label delegated -- sh -c 'echo "$(cut -d: -f3 /proc/self/cgroup) $CPUQ_CGROUP $(cat "$CPUQ_CGROUP/cgroup.subtree_control")"')
  local t0; t0=$(now)
  "$CPUQ" run --driver --label capped -- "$CPUQ" cap --mem 64M -- python3 -c 'import time; x = bytearray(256 << 20); time.sleep(10)' 2>/dev/null; local rc=$?
  local dt; dt=$(since "$t0")
  check "a driver runs in its scope's job/ with CPUQ_CGROUP and memory for its children (got $got); a cap there is stopped by the kernel ($rc after ${dt}s)" "[[ '$got' == *'.scope/job /sys/fs/cgroup/'*'.scope '*memory* ]] && [ $rc = 122 ] && fl '$dt < 0.9'"
  # --pids holds the program's tree to N tasks: python and 4 children of 20 asked for.
  local forks; forks=$("$CPUQ" run --driver --label pids -- "$CPUQ" cap --pids 5 -- python3 -c 'import os, time
n = 0
for i in range(20):
    try:
        if os.fork() == 0:
            time.sleep(1); os._exit(0)
        n += 1
    except OSError:
        pass
print(n)')
  # A cap SIGKILLed (a runner's own timeout) leaves its cgroup and what its program started; the
  # next cap in the scope removes both.
  cat >"$T/sweep" <<'EOF2'
"$1" cap --mem 64M -- sh -c 'sleep 66 & echo $! >"$1"; sleep 66' sh "$2" & cap=$!
sleep 0.5; kill -9 $cap; wait $cap 2>/dev/null
before=$(ls -d "$CPUQ_CGROUP"/cap-$cap-* 2>/dev/null | wc -l)
"$1" cap --mem 64M -- true
after=$(ls -d "$CPUQ_CGROUP"/cap-$cap-* 2>/dev/null | wc -l)
kill -0 "$(cat "$2")" 2>/dev/null && left=left || left=gone
echo "$before $after $left"
EOF2
  local swept; swept=$("$CPUQ" run --driver --label sweep -- sh "$T/sweep" "$CPUQ" "$T/stale")
  check "--pids 5 lets python start 4 of 20 (got $forks); a killed cap's cgroup and its sleep are swept by the next cap (got $swept)" "[ '$forks' = 4 ] && [ '$swept' = '1 0 gone' ]"
  # What a driver leaves running in its scope is stopped when it ends.
  "$CPUQ" run --driver --label leaver -- sh -c 'sleep 88 >/dev/null 2>&1 & echo $! >"$1"; exit 0' sh "$T/bg"; sleep 0.5
  local left=0; alive "$T/bg" && left=1
  check "what a driver leaves running in its scope is stopped when it ends (left: $left)" "[ $left = 0 ]"
  # A command's own ${...} reaches its shell untouched: systemd-run (254 and later) would expand it.
  local lit; lit=$("$CPUQ" run --driver --label literal -- sh -c 'x=abc/job; echo "${x%/job}"' 2>&1)
  check "a driver's \${x%/job} reaches its shell (got '$lit')" "[ '$lit' = abc ]"
  local off; off=$(echo "cgroups = off" >>"$CPUQ_CONFIG" && env -u CPUQ_CGROUP "$CPUQ" run --driver --label plain -- sh -c 'echo "cg=${CPUQ_CGROUP:-none}"')
  check "cgroups = off leaves a driver as it is (got $off)" "[ '$off' = 'cg=none' ]"
}

# --- Submitted jobs --------------------------------------------------------------------------

t_submit() {
  # cpuq submit, on "here": verdicts and their exits, report failures, return, attach, NOT STARTED
  # and --replace, and a credential refused.
  setup submit
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    echo hello > a.txt
    printf '%s\n' '{ "label": "t:pass", "run": "cat a.txt; echo \"args=$*\"" }' > cpuq/pass.json
    printf '%s\n' '{ "label": "t:fail", "run": "printf %s\\\\n \"{\\\"id\\\":\\\"t2\\\",\\\"ok\\\":false,\\\"reason\\\":\\\"boom\\\"}\" > r.jsonl; exit 3", "report": "r.jsonl" }' > cpuq/fail.json
    printf '%s\n' '{ "label": "t:slow", "run": "sleep 30", "time": "1s" }' > cpuq/slow.json
    printf '%s\n' '{ "label": "t:ret", "run": "mkdir -p out && echo made > out/x", "return": ["out"] }' > cpuq/ret.json
    printf '%s\n' '{ "label": "t:long", "run": "sleep 6" }' > cpuq/long.json
    printf '%s\n' '{ "label": "t:git", "run": "git rev-parse HEAD > gitsaw && git ls-files | wc -l >> gitsaw", "git": true, "return": ["gitsaw"] }' > cpuq/git.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/pass.json -- one two >"$T/pass" 2>/dev/null; echo "pass=$?"
    "$CPUQ" submit cpuq/fail.json >"$T/fail" 2>/dev/null; echo "fail=$?"
    "$CPUQ" submit cpuq/slow.json >/dev/null 2>&1; echo "slow=$?"
    "$CPUQ" submit cpuq/ret.json >/dev/null 2>&1; echo "ret=$?"; cat out/x 2>/dev/null
    # A return path starts empty each job: an earlier job's file there doesn't come back.
    printf '%s\n' '{ "label": "t:ret2", "run": "mkdir -p out && echo second > out/y", "return": ["out"] }' > cpuq/ret2.json
    rm -rf out; "$CPUQ" submit cpuq/ret2.json >/dev/null 2>&1; [ -f out/y ] && [ ! -f out/x ] && echo fresh
    "$CPUQ" submit cpuq/git.json >/dev/null 2>&1; echo "git=$?"
    [ "$(head -1 gitsaw 2>/dev/null)" = "$(git rev-parse HEAD)" ] && [ "$(tail -1 gitsaw | tr -d ' ')" = "$(git ls-files | wc -l | tr -d ' ')" ] && echo gitsaw
    # What shipped, by git: the finished job's --json has HEAD, the worktree's tree (HEAD's when
    # clean), and whether it was clean (here not: earlier jobs returned files into it).
    "$CPUQ" job last --json | python3 -c 'import json, subprocess, sys
s = json.load(sys.stdin).get("shipped") or {}
git = lambda *a: subprocess.run(["git", *a], capture_output=True, text=True).stdout.strip()
clean = git("status", "--porcelain") == ""
ok = s.get("head") == git("rev-parse", "HEAD") and s.get("clean") is clean and len(s.get("tree") or "") == 40 and (s.get("tree") == git("rev-parse", "HEAD^{tree}")) == clean
print("shipped" if ok else "shipped-wrong %s" % s)'
    "$CPUQ" submit cpuq/long.json >"$T/first" 2>/dev/null & local first=$!
    sleep 2
    "$CPUQ" submit cpuq/long.json --max-wait 1 2>/dev/null | head -1 | sed 's/^job [0-9a-f]* (attached.*/attached/'
    echo b > b.txt
    "$CPUQ" submit cpuq/long.json >/dev/null 2>&1; echo "changed=$?"
    "$CPUQ" submit cpuq/long.json --replace >/dev/null 2>&1; echo "replace=$?"
    wait $first; echo "replaced=$?"
    echo x > .env; "$CPUQ" submit cpuq/pass.json >/dev/null 2>&1; echo "secret=$?"
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' < "$T/out")
  local tail_ok=0; grep -q 'args=one two' "$HOME/.local/state/cpuq/jobs/"*/tail.log 2>/dev/null || grep -rq 'args=one two' "$T/xdg" && tail_ok=1
  check "submit: pass 0, fail 1, timeout 124, return copied (fresh each job), a spec's git there, what shipped by git, attach, changed code 2, --replace 0 and the old CANCELLED 76, a credential 2 (got: $got)" "[[ '$got' == 'pass=0 fail=1 slow=124 ret=0 made fresh git=0 gitsaw shipped attached changed=2 replace=0 replaced=76 secret=2 ' ]]"
  check "submit: the report's failure is listed, and the job got its arguments" "grep -q 'fail  t2  boom' '$T/fail' && [ $tail_ok = 1 ]"
}

t_test() {
  # cpuq test, on "here": setup, then the spec's tasks command fills $CPUQ_TODO and they run one
  # per CPU of the pool with $CPUQ_CODE; a failure is named with its last line and comes back to .cpuq/fail/;
  # changed code replaces the worktree's running test.
  setup test
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    echo hello > a.txt
    cat > mk.sh <<'EOF'
for i in 1 2 3 4; do echo 'cat "$CPUQ_CODE/a.txt"' > "$CPUQ_TODO/t$i"; done
[ "$1" = fail ] && printf 'echo boom\nexit 1\n' > "$CPUQ_TODO/t5"
[ "$1" = slow ] && for i in 1 2 3 4; do echo 'sleep 20' > "$CPUQ_TODO/s$i"; done
exit 0
EOF
    printf '%s\n' '{ "label": "t:ok", "setup": "echo built", "tasks": "sh mk.sh ok" }' > cpuq/ok.json
    printf '%s\n' '{ "label": "t:bad", "tasks": "sh mk.sh fail" }' > cpuq/bad.json
    printf '%s\n' '{ "label": "t:slow", "tasks": "sh mk.sh slow" }' > cpuq/slow.json
    git add -A && git commit -qm init
    "$CPUQ" test cpuq/bad.json >"$T/bad" 2>&1; echo "bad=$?"
    [ -f .cpuq/fail/t5 ] && [ "$(cat .cpuq/.gitignore)" = '*' ] && [ -z "$(git status --porcelain)" ] && echo back
    "$CPUQ" test cpuq/ok.json >"$T/ok" 2>&1; echo "ok=$?"
    "$CPUQ" submit cpuq/ok.json >/dev/null 2>&1; echo "submit=$?"
    "$CPUQ" test cpuq/slow.json >/dev/null 2>&1 & local first=$!
    sleep 3
    echo b > b.txt
    "$CPUQ" test cpuq/slow.json --max-wait 1 >/dev/null 2>&1; echo "replace=$?"
    wait $first; echo "replaced=$?"
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' < "$T/out")
  check "test: a failure 1 and back in .cpuq/fail (ignored), a pass 0, submit refuses a tasks spec 2, changed code replaces the running test (got: $got)" \
    "[[ '$got' == 'bad=1 back ok=0 submit=2 replace='*' replaced=76 ' ]]"
  check "test: the failed task is named with its last line, and the tasks saw \$CPUQ_CODE" \
    "grep -q 'fail  t5  boom' '$T/bad' && grep -q 'hello' \"\$(ls -d '$HOME'/.local/state/cpuq/jobs/t.repo/*/done '$T'/xdg/cpuq/jobs/t.repo/*/done 2>/dev/null | head -1)\"/t1"
}

count() { ls "$1" 2>/dev/null | wc -l | tr -d ' '; }

t_test_pool() {
  # A test's tasks share the pool, one per CPU: 4 tasks of 1 s on a pool of 2 take about 2 s.
  setup test-pool
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' 'for i in 1 2 3 4; do echo "echo cpu \$CPUQ_CPU; sleep 1" > "$CPUQ_TODO/t$i"; done' > mk.sh
    printf '%s\n' '{ "label": "t:pool", "tasks": "sh mk.sh" }' > cpuq/pool.json
    git add -A && git commit -qm init
    local t0; t0=$(now)
    "$CPUQ" test cpuq/pool.json >"$T/pool" 2>&1; echo "rc=$? took=$(since "$t0")"
  ) >"$T/out" 2>&1
  local got; got=$(cat "$T/out")
  local done_dir; done_dir=$(ls -d "$T"/xdg/cpuq/jobs/*/*/done "$HOME"/.local/state/cpuq/jobs/*/*/done 2>/dev/null | head -1)
  local cpus; cpus=$(cat "$done_dir"/* 2>/dev/null | grep -o '^cpu [0-9]*' | sort -u | wc -l | tr -d ' ')
  local secs; secs=$(grep -o 'PASS .* \([0-9]*\)s ' "$T/pool" | grep -o ' [0-9]*s ' | tail -1 | tr -d ' s')
  check "test: 4 tasks of 1 s on a pool of 2 run on both CPUs and the job takes about 2 s ($got; $(count "$done_dir") done on $cpus CPUs; the job ${secs}s)" \
    "[[ '$got' == rc=0* ]] && [ \"\$(count '$done_dir')\" = 4 ] && [ '$cpus' = 2 ] && [ '${secs:-99}' -le 4 ]"
}

t_submit_moved() {
  # A job waiting for its copy (another of the worktree's jobs on it) when the worktree changes
  # runs the worktree as it is when its copy syncs, not CPUQ ERROR.
  setup submit-moved
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_slots = 1" >> "$CPUQ_CONFIG"  # one copy: its jobs wait for it
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    echo one > v.txt
    printf '%s\n' '{ "label": "t:hold", "run": "sleep 4" }' > cpuq/hold.json
    printf '%s\n' '{ "label": "t:read", "run": "cat v.txt" }' > cpuq/read.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/hold.json >/dev/null 2>&1 & local h=$!
    sleep 1.5
    "$CPUQ" submit cpuq/read.json >"$T/read" 2>&1 & local r=$!
    sleep 1.5
    echo two > v.txt && git commit -qam two
    wait $r; echo "read=$?"; wait $h
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' < "$T/out")
  local saw; saw=$(cat "$HOME"/.local/state/cpuq/jobs/*/tail.log "$T"/xdg/cpuq/jobs/*/tail.log 2>/dev/null | grep -x 'one\|two' | tr '\n' ' ')
  check "submit: a job whose worktree moved while it waited for its copy runs it as it is then ($got, it read: $saw)" "[ '$got' = 'read=0 ' ] && [ '$saw' = 'two ' ]"
}

t_submit_abandon() {
  # A submitted job given up before its copy was synced (here, an rsync that fails) is cancelled on
  # its host too, so it holds the worktree's copy no longer: the next job runs at once. And a job
  # queued behind another on the copy ends when cancelled, while it waits.
  setup submit-abandon
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_slots = 1" >> "$CPUQ_CONFIG"  # one copy: its jobs wait for it
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' '{ "label": "t:quick", "run": "echo ran" }' > cpuq/quick.json
    printf '%s\n' '{ "label": "t:hold", "run": "sleep 6" }' > cpuq/hold.json
    git add -A && git commit -qm init
    CPUQ_RSYNC=/usr/bin/false "$CPUQ" submit cpuq/quick.json --max-wait 20 >/dev/null 2>&1; echo "broken=$?"
    local t0; t0=$(python3 -c 'import time; print(time.time())')
    "$CPUQ" submit cpuq/quick.json --again --max-wait 20 >/dev/null 2>&1; echo "next=$?"
    python3 -c "import time; print('next_s=%d' % (time.time() - $t0))"
    "$CPUQ" submit cpuq/hold.json >/dev/null 2>&1 & local h=$!
    sleep 2
    "$CPUQ" submit cpuq/quick.json --again >"$T/queued" 2>&1 & local q=$!
    sleep 2
    local id; id=$("$CPUQ" jobs | awk '/t:quick/ && /queued/ {print $1; exit}')
    "$CPUQ" job "$id" --cancel >/dev/null 2>&1
    wait $q; echo "queued=$?"
    wait $h
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' < "$T/out")
  check "submit: a job given up before its sync frees its copy (the next runs at once), and a queued job ends when cancelled ($got)" \
    "[[ '$got' == 'broken=125 next=0 next_s='[0-9]' queued=76 ' || '$got' == 'broken=125 next=0 next_s=1'[0-9]' queued=76 ' ]]"
}

t_submit_slots() {
  # A worktree's submitted jobs run at once, each on a copy of its own (submit_slots): the second
  # starts while the first runs, on a copy seeded from the first's, which keeps what the first
  # left there (a build's cache).
  setup submit-slots
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '.cache\n' > .gitignore
    printf '%s\n' '{ "label": "t:warm", "run": "mkdir -p .cache && echo built > .cache/x" }' > cpuq/warm.json
    printf '%s\n' '{ "label": "t:hold", "run": "sleep 15", "exclude": [".cache"] }' > cpuq/hold.json
    printf '%s\n' '{ "label": "t:peek", "run": "cat .cache/x", "exclude": [".cache"] }' > cpuq/peek.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/warm.json >/dev/null 2>&1; echo "warm=$?"
    rm -rf .cache
    "$CPUQ" submit cpuq/hold.json >/dev/null 2>&1 & local h=$!
    sleep 2
    "$CPUQ" submit cpuq/peek.json >"$T/peek" 2>&1; echo "peek=$?"
    kill -0 $h 2>/dev/null && echo "beside" || echo "after"
    wait $h; echo "hold=$?"
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' < "$T/out")
  check "submit: a worktree's second job runs at once on another copy, seeded warm from the first's (got $got)" \
    "[[ '$got' == 'warm=0 peek=0 beside hold=0 ' ]]"
}

t_submit_on() {
  # A spec with a field it doesn't know is refused, and one with "cores" says what does its work.
  # --on HOST is one of this machine's remotes, and --on this machine runs the job here.
  setup submit-on
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  printf 'submit_roots = %s\n' "$T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' '{ "label": "t:on", "run": "true", "host": "burst" }' > cpuq/on.json
    printf '%s\n' '{ "label": "t:cores", "run": "true", "cores": "2-8" }' > cpuq/cores.json
    printf '%s\n' '{ "label": "t:here", "run": "true" }' > cpuq/here.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/on.json >"$T/spec" 2>&1; echo "spec=$?"
    "$CPUQ" submit cpuq/cores.json >"$T/cores" 2>&1; echo "cores=$?"
    "$CPUQ" submit --on cheese cpuq/here.json >"$T/unknown" 2>&1; echo "unknown=$?"
    "$CPUQ" submit --on "$(hostname -s)" cpuq/here.json >/dev/null 2>&1; echo "self=$?"
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' <"$T/out")
  check "submit: a spec with an unknown field is refused ($(head -1 "$T/spec")), one with cores says what replaces it ($(head -1 "$T/cores")); --on a host not among the remotes is refused; --on this machine runs here (got $got)" \
    "[[ \"\$got\" == 'spec=2 cores=2 unknown=2 self=0 ' ]] && grep -q 'UnknownField' '$T/spec' && grep -q '\"cores\" is gone' '$T/cores' && grep -q 'not one of this machine' '$T/unknown'"
}

t_submit_needs() {
  # A spec's "needs" names caches that must hold files on a host: a host where one is empty is
  # passed over (NOT RUN when it's the only one, the reason given), and a "needs" that isn't one
  # of the spec's caches is refused.
  setup submit-needs
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  printf 'submit_roots = %s\n' "$T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' '{ "label": "t:needs", "run": "cat \"$DATA/x\" > saw", "caches": { "DATA": "data" }, "needs": ["DATA"], "return": ["saw"] }' > cpuq/needs.json
    printf '%s\n' '{ "label": "t:bad", "run": "true", "needs": ["DATA"] }' > cpuq/bad.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/bad.json >"$T/bad" 2>&1; echo "bad=$?"
    "$CPUQ" submit cpuq/needs.json >"$T/empty" 2>&1; echo "empty=$?"
    mkdir -p "$HOME/cpuq/caches/t/data" && echo filled > "$HOME/cpuq/caches/t/data/x"
    "$CPUQ" submit cpuq/needs.json >/dev/null 2>&1; echo "filled=$?"; cat saw
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' <"$T/out")
  check "submit: a \"needs\" outside the caches is refused, an empty one is NOT RUN with its reason ($(grep -o 'cpuq/caches/t/data is empty' "$T/empty" | head -1)), a filled one runs (got $got)" \
    "[[ \"\$got\" == 'bad=2 empty=75 filled=0 filled ' ]] && grep -q 'has no DATA' '$T/bad' && grep -q 'cpuq/caches/t/data is empty' '$T/empty'"
}

t_submit_mem() {
  # A host with less RAM than the spec's "mem" is passed over, unless --on names it: a run's
  # arguments can make the job far smaller than its spec's limit.
  setup submit-mem
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  printf 'submit_roots = %s\n' "$T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' '{ "label": "t:mem", "run": "true", "mem": "100000G" }' > cpuq/mem.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/mem.json >"$T/big" 2>&1; echo "placed=$?"
    "$CPUQ" submit --on here cpuq/mem.json >/dev/null 2>&1; echo "named=$?"
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' <"$T/out")
  check "submit: a host short of \"mem\" is passed over, but runs it when --on names it (got $got)" \
    "[[ \"\$got\" == 'placed=75 named=0 ' ]] && grep -q 'GB of RAM, the job wants 100000' '$T/big'"
}

t_submit_tmp() {
  # A submitted job's TMPDIR is a directory of its own under ~/cpuq/tmp, gone when the job ends.
  setup submit-tmp
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  printf 'submit_roots = %s\n' "$T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' '{ "label": "t:tmp", "run": "echo \"$TMPDIR\" > saw && touch \"$TMPDIR/x\"", "return": ["saw"] }' > cpuq/tmp.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/tmp.json >/dev/null 2>&1; echo "rc=$?"
  ) >"$T/out" 2>&1
  local saw; saw=$(cat "$T/roots/repo/saw" 2>/dev/null)
  local left; left=$(ls "$HOME/cpuq/tmp" | wc -l | tr -d ' ')
  check "a submitted job's TMPDIR was under ~/cpuq/tmp ($saw), and is gone after (left $left)" "[[ '$(cat "$T/out")' == 'rc=0' && '$saw' == '$HOME/cpuq/tmp/'* && $left = 0 ]]"
}

t_submit_cancel_running() {
  # A submitted job cancelled while its command runs stops at once (its whole tree), as CANCELLED,
  # not after the command ends of itself.
  setup submit-cancel-running
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' "{ \"label\": \"t:long\", \"run\": \"echo \$\$ > $T/pid; exec sleep 61\" }" > cpuq/long.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/long.json >/dev/null 2>&1 & local j=$!
    local id="" i
    for i in $(seq 1 100); do
      id=$("$CPUQ" jobs | awk '/t:long/ && /running/ {print $1; exit}')
      [ -n "$id" ] && [ -s "$T/pid" ] && break
      sleep 0.1
    done
    local t0; t0=$(python3 -c 'import time; print(time.time())')
    "$CPUQ" job "$id" --cancel >/dev/null 2>&1
    wait $j; echo "rc=$?"
    python3 -c "import time; print('s=%d' % (time.time() - $t0))"
    sleep 0.5
    kill -0 "$(cat "$T/pid")" 2>/dev/null && echo left || echo gone
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' < "$T/out")
  check "submit: a job cancelled while it runs stops at once, its command gone ($got)" "[[ '$got' == 'rc=76 s='[0-9]' gone ' ]]"
}

t_submit_progress() {
  # A submitted job's progress (CPUQ_PROGRESS) shows in cpuq job.
  setup submit-progress
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  local repo=$T/roots/repo
  (
    cd "$repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' '{ "label": "t:count", "run": "echo \"7 40 1\" > \"$CPUQ_PROGRESS.tmp\" && mv \"$CPUQ_PROGRESS.tmp\" \"$CPUQ_PROGRESS\" && sleep 9" }' > cpuq/c.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/c.json >/dev/null 2>&1
  ) & local s=$!
  local got=""
  poll 14 "got=\$(cd '$repo' && '$CPUQ' job last 2>/dev/null | grep -o '7/40 ([0-9]*%)  1 failing'); [ -n \"\$got\" ]"
  wait $s
  check "a submitted job's progress shows in cpuq job (got '$got')" "[ '$got' = '7/40 (17%)  1 failing' ]"
}

t_packs() {
  # Packs: a spec asks for a tool by version; the first job builds it into the store
  # (~/cpuq/packs/NAME/VERSION), later ones reuse it, `latest` links to it, and the job finds it
  # on its PATH and as NAME. Here the tool is a local git repo whose build counts its runs.
  setup packs
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq" "$T/roots/tool"
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/tool" && git init -q && git config user.email t@t && git config user.name t
    printf '#!/bin/sh\necho tool-one\n' > tool.sh && git add -A && git commit -qm one
  ) >/dev/null 2>&1
  printf '{ "tool": { "git": "%s", "local": "%s", "build": "mkdir -p bin && cp tool.sh bin/tool && chmod +x bin/tool && echo x >> %s/builds", "bin": "bin/tool" } }\n' \
    "$T/roots/tool" "$T/roots/tool" "$T" > "$(dirname "$CPUQ_CONFIG")/packs.json"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' '{ "label": "t:packs", "run": "tool; \"$TOOL\"", "packs": { "tool": "latest" } }' > cpuq/p.json
    git add -A && git commit -qm init
    "$CPUQ" submit cpuq/p.json >"$T/p1" 2>&1; echo "first=$?"
    echo again > again.txt
    "$CPUQ" submit cpuq/p.json >"$T/p2" 2>&1; echo "second=$?"
    (cd "$T/roots/tool" && printf '#!/bin/sh\necho tool-two\n' > tool.sh && git commit -qam two)
    echo third > again.txt
    "$CPUQ" submit cpuq/p.json >"$T/p3" 2>&1; echo "third=$?"
  ) >"$T/out" 2>&1
  local got; got=$(tr '\n' ' ' < "$T/out")
  local builds; builds=$(wc -l < "$T/builds" 2>/dev/null | tr -d ' ')
  local saw; saw=$(cat "$HOME"/.local/state/cpuq/jobs/*/tail.log "$T"/xdg/cpuq/jobs/*/tail.log 2>/dev/null | grep -c '^tool-')
  local latest; latest=$(readlink "$HOME/cpuq/packs/tool/latest")
  local versions; versions=$(ls "$HOME/cpuq/packs/tool" | grep -cv latest)
  local head; head=$(git -C "$T/roots/tool" rev-parse HEAD | cut -c1-12)
  local two; two=$(cat "$HOME"/.local/state/cpuq/jobs/*/tail.log "$T"/xdg/cpuq/jobs/*/tail.log 2>/dev/null | grep -c '^tool-two')
  check "packs: a job gets its tool on PATH and as TOOL ($got, $saw lines, $two of the new one), built once per version ($builds builds, $versions versions), latest -> the newest ($latest)" \
    "[ '$got' = 'first=0 second=0 third=0 ' ] && [ '$saw' = 6 ] && [ '$two' = 2 ] && [ '$builds' = 2 ] && [ '$versions' = 2 ] && [ '$latest' = '$head' ]"
}

t_clean() {
  # cpuq clean: copies, pack versions and job records unused for its age go; fresh ones, a
  # version a link names, and a copy a job holds the lock of stay; --dry-run removes nothing.
  setup clean
  local sp=$HOME/cpuq/worktrees pk=$HOME/cpuq/packs
  mkdir -p "$sp/p/old-1" "$sp/p/new-2" "$sp/p/oldcopy" "$sp/p/heldcopy" "$sp/p/newcopy" "$pk/tool/aaa" "$pk/tool/bbb" "$pk/tool/ccc"
  touch -t 202601010000 "$sp/p/old-1/.cpuq-used" "$sp/p/oldcopy/.cpuq-generation" "$sp/p/heldcopy/.cpuq-generation" "$pk/tool/aaa/.cpuq-used" "$pk/tool/bbb/.cpuq-used"
  touch "$sp/p/new-2/.cpuq-used" "$sp/p/newcopy/.cpuq-generation" "$pk/tool/ccc/.cpuq-used"
  ln -s bbb "$pk/tool/latest"
  touch "$sp/p/heldcopy.lock"
  # A job holding its copy's lock.
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[1]); fcntl.flock(f, fcntl.LOCK_EX); time.sleep(4)' "$sp/p/heldcopy.lock" & local holder=$!
  sleep 0.5
  "$CPUQ" clean --dry-run --older 1h >"$T/dry"
  local after_dry; after_dry=$(ls "$sp/p" "$pk/tool" | tr '\n' ' ')
  "$CPUQ" clean --older 1h >"$T/out"
  wait $holder
  local left; left=$(cd "$HOME" && find cpuq -mindepth 2 -maxdepth 3 -type d | sort | tr '\n' ' ')
  echo "  left: $left"
  check "clean: old copies and an unnamed old pack version go, fresh ones, a named one and a locked copy stay; --dry-run removes nothing ($(tail -1 "$T/dry"))" \
    "[[ '$after_dry' == *old-1* && '$left' != *old-1* && '$left' != *oldcopy* && '$left' != *tool/aaa* && '$left' == *new-2* && '$left' == *newcopy* && '$left' == *heldcopy* && '$left' == *tool/bbb* && '$left' == *tool/ccc* ]] && grep -q 'removed 3' '$T/out'"
  # Only what cpuq made goes: a folder made by hand in ~/cpuq/tmp, a plain clone straight under
  # ~/cpuq/worktrees, and a folder in a project's copies with no marker all stay, however old. A
  # job's scratch whose record is there goes.
  local tmp=$HOME/cpuq/tmp jobs=${XDG_STATE_HOME:-$HOME/.local/state}/cpuq/jobs
  mkdir -p "$tmp/setup1123" "$tmp/0123456789ab" "$jobs/0123456789ab" "$sp/trig-main/.git" "$sp/trig-main/src" "$sp/p/handmade"
  # A folder's age is its ctime too, which touch can't set back: age them by waiting instead.
  sleep 2
  "$CPUQ" clean --older 1s >"$T/out2"
  left=$(cd "$HOME" && find cpuq -mindepth 2 -maxdepth 3 -type d | sort | tr '\n' ' ')
  check "clean leaves what cpuq didn't make: a hand-made scratch folder, a plain clone, an unmarked copy; a job's old scratch goes ($(tail -1 "$T/out2"))" \
    "[[ '$left' == *tmp/setup1123* && '$left' == *trig-main/src* && '$left' == *p/handmade* && '$left' != *tmp/0123456789ab* ]]"
}

# --- cpuq jobs and the agent (until they go) -------------------------------------------------

TESTS=${*:-budget tasks pack cpus_limit timeout retry wait_max share fair order drain lock_stuck storm kill ctrl_z nested driver removed \
  kill_holder leftovers leaked_descendant kill_waiter term_waiting lost_seq long_command waiters_cpu \
  exit_status direct_sigint terminal_sigint tasks_sigint ignored_signals stack_limit pin repin narrow \
  status progress usage zombie outside status_host history note wait record min_available min_disk hook \
  lease lease_host lease_host_hold hold_gone last_words on include_git on_check on_gitignore tethered \
  cap cap_quiet_crash cap_link cgroups submit test test_pool submit_moved submit_abandon submit_slots submit_on \
  submit_needs submit_mem submit_tmp submit_cancel_running submit_progress packs clean}
for t in $TESTS; do
  if declare -F "t_$t" >/dev/null; then "t_$t"; else echo "no such test: $t"; FAIL=$((FAIL+1)); FAILED+=" $t?"; fi
done
echo
echo "$PASS passed, $FAIL failed${FAILED:+:$FAILED}$([ $KNOWN = 0 ] || echo ", $KNOWN known: cpuq bugs, marked KNOWN above")"
[ $FAIL = 0 ] && [ $PASS != 0 ]
