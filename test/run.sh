#!/bin/bash
# test/run.sh [TEST...]: the end-to-end tests. Each test gets its own state directory, config and
# HOME, and runs in a folder of its own (not a repo, so a run's project is its label's). The pool
# has 2 tokens unless a test says otherwise (`tokens = N`: setup sets the reserve to leave N) and
# the memory and disk gates are off, so the tests depend neither on the machine's size nor on its
# memory. The outside-load gate, which reads the real machine, is off too. A task holds its token
# whatever it does: a sleeping task holds one as a burner does.
# CPUQ=/path/to/cpuq tests another binary.
set -u
cd "$(dirname "$0")/.."
REPO=$PWD
CPUQ=${CPUQ:-$PWD/bin/cpuq}
[ -x "$CPUQ" ] || { echo "no $CPUQ; run zig build first"; exit 2; }
# The tests run git in scratch folders: git found through the caller's environment (a GIT_DIR
# set by whoever started the suite) would be another repository, and its commits and config would
# land there.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CEILING_DIRECTORIES GIT_CONFIG GIT_CONFIG_GLOBAL
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cpuq-test.XXXXXX")
# The scratch folder must be in no repository, or a test's git would write into that one.
if found=$(git -C "$ROOT" rev-parse --absolute-git-dir 2>/dev/null); then
  echo "refusing to run: git in $ROOT finds the repository $found"; rm -rf "$ROOT"; exit 2
fi
# On exit, end every process the tests started, children's children
# included, so none outlives the run holding its output open.
killtree() { local p; for p in $(pgrep -P "$1"); do killtree "$p"; kill "$p" 2>/dev/null; done; }
# The pids under $1, children's children included, to end by pid once $1 is gone.
descendants() { local p; for p in $(pgrep -P "$1"); do echo "$p"; descendants "$p"; done; }
# 0 if a pid in the file $1 still runs.
alive() { [ -s "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }
trap 'killtree $$; rm -rf "$ROOT"' EXIT
# Linux: the suite runs with every CPU the machine's init may use, even when started inside a
# narrower CPU set (an outer drain's isolation), so a drain's pinning is seen against all of them.
if [ "$(uname)" = Linux ]; then
  SUITE_PID=$$ python3 -c 'import os, re
m = re.search(r"Cpus_allowed_list:\s*(\S+)", open("/proc/1/status").read())
cpus = set()
for part in m.group(1).split(","):
    a, _, b = part.partition("-"); cpus.update(range(int(a), int(b or a) + 1))
os.sched_setaffinity(int(os.environ["SUITE_PID"]), cpus)' 2>/dev/null
fi
# burn [-K] SECONDS: keeps a CPU busy for SECONDS of its own CPU time; burn [-K] --until PATH
# [SECONDS]: busy until PATH exists (at most SECONDS, default 60). -K burns in K processes, so a
# task holding the pool busy shows busy even on a loaded machine that gives each less than a CPU.
BURN=$ROOT/burn
cat >"$BURN" <<'EOF'
#!/usr/bin/env python3
import os, sys, time
args = sys.argv[1:]
kids = []
if args[0][:1] == "-" and args[0][1:].isdigit():
    for _ in range(int(args[0][1:]) - 1):
        pid = os.fork()
        if pid == 0:
            kids = []
            break
        kids.append(pid)
    args = args[1:]
if args[0] == "--until":
    end = time.time() + float(args[2] if len(args) > 2 else 60)
    while not os.path.exists(args[1]) and time.time() < end:
        for _ in range(20000): pass
else:
    t = time.process_time() + float(args[0])
    while time.process_time() < t: pass
for pid in kids:
    os.waitpid(pid, 0)
EOF
chmod +x "$BURN"
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
  unset CPUQ_CPU CPUQ_OP CPUQ_SCOPE CPUQ_TASK CPUQ_TASKS CPUQ_ATTEMPT CPUQ_ATTEMPTS CPUQ_PROGRESS \
    CPUQ_PROGRESS_AT CPUQ_LEASES CPUQ_TOKEN CPUQ_CORES CPUQ_HISTORY MAKEFLAGS XDG_STATE_HOME
  # Each key at most once: a line given here replaces the default for its key. `tokens = N` is
  # the suite's own: the pool's last N CPUs as the pool (all of it when it has fewer), no reserve,
  # so no test depends on the machine's size, nor sits on the CPUs its own cpuq pins tasks to.
  local line keys=" " toks=2 lines=()
  for line in "$@"; do
    case $line in "tokens = "*) toks=${line#tokens = } ;; *) keys="$keys${line%% *} "; lines+=("$line") ;; esac
  done
  {
    for line in "min_disk = off" "pressure_check = off" "outside_check = off"; do
      case $keys in *" ${line%% *} "*) ;; *) echo "$line" ;; esac
    done
    for line in ${lines[@]+"${lines[@]}"}; do echo "$line"; done
  } >"$T/config.base"
  case $keys in
    *" reserve "*) cp "$T/config.base" "$CPUQ_CONFIG" ;;
    *" cpus "*) { cat "$T/config.base"; echo "reserve = 0"; } >"$CPUQ_CONFIG" ;;
    *)
      { cat "$T/config.base"; echo "reserve = 0"; } >"$CPUQ_CONFIG"
      # The pool's last N: a machine's own cpuq pins its tasks to its first CPUs.
      local last; last=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; p = json.load(sys.stdin)["pool"]; print(",".join(map(str, p[max(0, len(p) - int(sys.argv[1])):])))' "$toks")
      { cat "$T/config.base"; echo "reserve = 0"; echo "cpus = $last"; } >"$CPUQ_CONFIG" ;;
  esac
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
running() { sj 's["running"]'; }
waiting() { sj 'len(s["waiters"])'; }
# The pool's CPUs, and its tokens' CPUs, by the machine's numbers, space-separated.
poolcpus() { sj '" ".join(map(str, s["pool"]))'; }
tokcpus() { sj '" ".join(map(str, s["token_cpus"]))'; }
# tokcores: how many cores the tokens' CPUs are on (Linux: by thread_siblings_list; else each CPU).
tokcores() { sj 'len({open("/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list" % c).read().strip() if __import__("os").path.exists("/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list" % c) else str(c) for c in s["token_cpus"]})'; }
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
runs() { "$CPUQ" status --json --no-usage | python3 -c 'import json, sys
s = json.load(sys.stdin)
sys.exit(0 if any(h["label"] == sys.argv[1] and h["running"] > 0 for h in s["runs"]) else 1)' "$1"; }
# wait_running N [seconds]: until N tasks run.
wait_running() { poll "${2:-10}" "[ \"\$(running)\" = $1 ]"; }
# wait_run LABEL [seconds]: until a run labelled LABEL runs a task.
wait_run() { poll "${2:-10}" "runs '$1'"; }
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

# --- The pool: admission, tasks, the line -----------------------------------------------------

t_tokens() {
  # Tokens: at most N tasks run at once, ever, whatever they do: 6 single runs and a run of 6,
  # all asleep, on 2 tokens never run more than 2. And cpuq reserve prints them.
  setup tokens
  local pids=() i p
  for i in $(seq 6); do "$CPUQ" run -- sleep 1 & pids+=($!); done
  "$CPUQ" run -n 6 -- sleep 1 2>/dev/null & pids+=($!)
  local max=0 samples=0 h any=1
  while [ $any = 1 ] && [ $samples -lt 400 ]; do
    h=$(running); samples=$((samples + 1))
    [ -n "$h" ] && [ "$h" -gt "$max" ] && max=$h
    any=0; for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && any=1; done
    sleep 0.1
  done
  local rc=0
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  check "12 sleeping tasks on 2 tokens: never more than 2 at once (most $max over $samples looks), and every run passed (rc $rc)" "[ $max = 2 ] && [ $rc = 0 ]"
  local said budget; said=$("$CPUQ" reserve); budget=$("$CPUQ" budget)
  check "cpuq reserve prints the tokens and the reserve ($said); cpuq budget prints the tokens ($budget)" "[[ '$said' == '2 tokens, '*' reserved' ]] && [ '$budget' = 2 ]"
  # A config with a remote's lines, read twice by a command that loads it again, reads cleanly.
  printf 'remotes = h\nremote_start.h = true\n' >>"$CPUQ_CONFIG"
  local twice; twice=$( { "$CPUQ" budget; "$CPUQ" reserve; "$CPUQ" limit none -c 1; } 2>&1 | grep -c 'set twice')
  check "budget, reserve and limit read a config with remote lines once (set twice: $twice)" "[ '$twice' = 0 ]"
}

t_reserve() {
  # cpuq reserve N sets aside N CPUs (the slowest whole cores), in the config, in force at once:
  # sleepers hold 4 tokens; raised to leave 2 (or 1, whole cores), the running finish and no more
  # than that run; lowered again, more start at once. At least one token always; the old budget
  # key points to reserve.
  setup reserve "reserve = 0"
  local pool; pool=$(poolcpus | wc -w | tr -d ' ')
  if [ "$pool" -lt 4 ]; then echo "  skipped: needs a pool of 4"; return; fi
  "$CPUQ" reserve $((pool - 4)) >/dev/null
  local four; four=$("$CPUQ" budget)
  "$CPUQ" run -n 12 --label r:sleep -- sleep 1.5 2>/dev/null & local r=$!
  wait_running "$four"
  local out; out=$("$CPUQ" reserve $((pool - 2)))
  local two; two=$("$CPUQ" budget)
  local conf; conf=$(grep -c "^reserve = $((pool - 2))\$" "$CPUQ_CONFIG")
  sleep 1.8
  local max=0 h k
  for k in $(seq 20); do h=$(running); [ "$h" -gt "$max" ] && max=$h; sleep 0.1; done
  "$CPUQ" reserve $((pool - 4)) >/dev/null
  local up=no; wait_running "$four" 5 && up=yes
  wait $r; local rr=$?
  local none; "$CPUQ" reserve "$pool" 2>/dev/null; none=$?
  local tj; tj=$(sj '"%d %d" % (s["tokens"], s["tokens"] + s["reserve"])')
  local old=no; echo "budget = 2" >"$T/c.old"; CPUQ_CONFIG=$T/c.old "$CPUQ" run -- true 2>&1 | grep -q 'budget is gone: reserve = N' && old=yes
  check "reserve $((pool - 2)) ($out; in the config: $conf) leaves $two tokens: once the running finish, at most that many run (most $max); lowered, $four run again ($up); all passed (rc $rr)" \
    "[[ '$out' == '$two tokens, '* ]] && [ '$two' -ge 1 ] && [ '$two' -le 2 ] && [ $conf = 1 ] && [ $max = $two ] && [ $up = yes ] && [ $rr = 0 ]"
  check "a reserve of the whole pool is refused (rc $none); status says the tokens and the pool ($tj); budget is gone, saying reserve ($old)" \
    "[ $none = 2 ] && [ '$tj' = '$four $pool' ] && [ $old = yes ]"
}

t_tasks() {
  # -n M: M tasks, each with CPUQ_TASK, CPUQ_TASKS, CPUQ_OP and CPUQ_ATTEMPT (and no CPUQ_CPU),
  # stdin from /dev/null, and its output (both streams) in a file of its own; a plan line first; 0
  # when every task passed, 1 when any failed, with the failed task's last lines.
  setup tasks
  "$CPUQ" run -n 5 --label t:env -- sh -c 'echo "$CPUQ_TASK/$CPUQ_TASKS ${CPUQ_CPU-unset} op=$CPUQ_OP try=$CPUQ_ATTEMPT"; echo err >&2; cat' 2>"$T/err"; local rc=$?
  local d; d=$(rundir t)
  local files; files=$(ls "$d" 2>/dev/null | sort -n | tr '\n' ' ')
  local good=0 i
  for i in 1 2 3 4 5; do
    grep -qx "$i/5 unset op=[0-9][0-9]* try=1" "$d/$i" 2>/dev/null && grep -qx err "$d/$i" && good=$((good + 1))
  done
  check "5 tasks, each with its own output file ($files) holding its variables, no CPUQ_CPU, and its stderr ($good of 5); rc $rc" "[ $rc = 0 ] && [ '$files' = '1 2 3 4 5 ' ] && [ $good = 5 ]"
  check "a plan line first, then the summary ('$(head -1 "$T/err")' ... '$(tail -1 "$T/err" | cut -c1-40)')" \
    "grep -q '^cpuq: 5 tasks, up to 5 at once, timeout 3600s\$' '$T/err' && grep -q '^cpuq: 5 of 5 tasks passed, in .*; output in $d\$' '$T/err'"
  "$CPUQ" run -n 4 --label u:fail -- sh -c 'echo "line of $CPUQ_TASK"; [ "$CPUQ_TASK" != 3 ] || exit 7' 2>"$T/err2"; rc=$?
  check "a failed task makes it 1 (rc $rc), and the summary names it with its last lines" \
    "[ $rc = 1 ] && grep -q '3 of 4 tasks passed, 1 failed' '$T/err2' && grep -q 'task 3 (attempt 1) exited 7' '$T/err2' && grep -qx '    line of 3' '$T/err2'"
}

t_io() {
  # A task holds its token whatever it does, waiting on I/O (here a sleep) included: 3 sleepers
  # of 1 s on 1 token take turns. Burners too: the second starts once the first ends.
  setup io "tokens = 1"
  local t0 rc dt; t0=$(now)
  "$CPUQ" run -n 3 --label io:sleep -- sleep 1 2>/dev/null; rc=$?
  dt=$(since "$t0")
  check "3 sleepers of 1 s on 1 token take turns: ${dt}s, not 1 (rc $rc)" "[ $rc = 0 ] && fl '$dt >= 2.9'"
  "$CPUQ" run -n 2 --label io:burn -- sh -c 'echo "s$CPUQ_TASK" >>"$1"; "$2" -2 1.5; echo "e$CPUQ_TASK" >>"$1"' sh "$T/burn" "$BURN" 2>/dev/null; rc=$?
  local order; order=$(tr '\n' ' ' <"$T/burn")
  check "2 burners on 1 token take turns: the second starts once the first ends (got $order; rc $rc)" "[ $rc = 0 ] && [ '$order' = 's1 e1 s2 e2 ' ]"
}

t_cpus_limit() {
  # -c C or -c P%: the most tokens a run holds at once: a count, or a share of the tokens (here
  # 4, named, so a machine with fewer CPUs has the same pool), at least 1, and never more than its
  # tasks; none given, as the line allows. The plan line says it, and the tasks keep to it.
  setup cpus-limit "cpus = 0-3" "reserve = 0"
  local got="" c n
  for c in 1 2 50% 25% 10% 100% 9 99; do
    n=$("$CPUQ" run -n 20 -c "$c" --label c:x -- true 2>&1 >/dev/null | sed -n 's/^cpuq: 20 tasks, up to \([0-9]*\) at once,.*/\1/p')
    got="$got$c:$n "
  done
  local few; few=$("$CPUQ" run -n 3 --label c:few -- true 2>&1 | sed -n 's/^cpuq: 3 tasks, up to \([0-9]*\) at once,.*/\1/p')
  local many; many=$("$CPUQ" run -n 40 --label c:many -- true 2>&1 | sed -n 's/^cpuq: 40 tasks, up to \([0-9]*\) at once,.*/\1/p')
  check "-c on 4 tokens: a count, a share of the tokens (at least 1), at most its tasks ($got); none given: its tasks (3 tasks: $few; 40: $many)" \
    "[ '$got' = '1:1 2:2 50%:2 25%:1 10%:1 100%:4 9:9 99:20 ' ] && [ '$few' = 3 ] && [ '$many' = 40 ]"
  "$CPUQ" run -n 6 -c 2 --label c:keep -- sleep 2.5 2>/dev/null & local p=$!
  local max=0 h
  while kill -0 $p 2>/dev/null; do h=$(running); [ -n "$h" ] && [ "$h" -gt "$max" ] && max=$h; done
  wait $p; local rc=$?
  check "6 sleepers at -c 2 run 2 at once, never more, though tokens are free (most $max, rc $rc)" "[ $max = 2 ] && [ $rc = 0 ]"
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
  # --wait-max S: no task started within S seconds and the run gives up with 75, nothing run; 0
  # starts at once or gives up at once. The waiters wait for the one token, held.
  setup wait-max "tokens = 1"
  "$CPUQ" run --label w:hold -- "$BURN" -2 4 & local h=$!
  wait_running 1
  local t0 rc0 rc1 dt0 dt1 rcn
  t0=$(now); "$CPUQ" run --wait-max 0 --label w:x -- touch "$T/ran" 2>"$T/err"; rc0=$?; dt0=$(since "$t0")
  t0=$(now); "$CPUQ" run --wait-max 1 --label w:x -- touch "$T/ran" 2>/dev/null; rc1=$?; dt1=$(since "$t0")
  "$CPUQ" run -n 3 --wait-max 0 --label w:x -- touch "$T/ran" 2>/dev/null; rcn=$?
  wait $h
  "$CPUQ" run --wait-max 0 --label w:x -- true; local free=$?
  local ran=no; [ -e "$T/ran" ] && ran=yes
  check "the pool busy: --wait-max 0 gives up at once (rc $rc0 after ${dt0}s, '$(cat "$T/err")'), --wait-max 1 after a second (rc $rc1 after ${dt1}s), a run of 3 too (rc $rcn), nothing ran ($ran); the pool idle: 0 runs (rc $free)" \
    "[ $rc0 = 75 ] && fl '$dt0 < 1' && [ $rc1 = 75 ] && fl '0.9 < $dt1 < 3' && [ $rcn = 75 ] && [ $ran = no ] && [ $free = 0 ] && grep -q 'nothing ran' '$T/err'"
}

t_share() {
  # A freed token goes to a project under its share first: a holds both tokens with burners; b
  # comes; the first token a frees goes to b, not to a's next task. Then each keeps its share of
  # 1: in every status snapshot (one consistent read of the records), b never holds 2 tokens while
  # a has a task waiting: the line gives b a second token only once a waits for none.
  setup share
  local f=$T/starts
  # a's first two tasks end 1.5 s apart, so a freed token's taker is never a race.
  "$CPUQ" run -n 4 --label a:work -- sh -c 'echo "a$CPUQ_TASK" >>"$1"; "$2" "$(( CPUQ_TASK == 2 ? 3 : 1 ))"' sh "$f" "$BURN" 2>/dev/null & local a=$!
  wait_running 2
  "$CPUQ" run -n 6 --label b:work -- sh -c 'echo "b$CPUQ_TASK" >>"$1"; "$2" 0.5' sh "$f" "$BURN" 2>/dev/null & local b=$!
  wait_waiters 2
  local bad=0 both=0 looks=0 line
  while kill -0 $b 2>/dev/null && kill -0 $a 2>/dev/null && [ $looks -lt 300 ]; do
    line=$(sj '" ".join("%s=%d/%d" % (p["name"], p["running"], p["waiting"]) for p in sorted(s["projects"], key=lambda p: p["name"]))')
    looks=$((looks + 1))
    case " $line " in *" a=1/"*" b=1/"*) both=$((both + 1)) ;; esac
    case " $line " in *" a="[0-9]"/"[1-9]*" b=2/"*) bad=$((bad + 1)); echo "  b holds 2 while a waits: $line" ;; esac
  done
  wait $a; local ra=$?; wait $b; local rb=$?
  local got; got=$(head -3 "$f" | tr '\n' ' ')
  check "the first token a frees goes to b, under its share (starts: $got)" "[[ '$got' == 'a'[12]' a'[12]' b1 ' ]]"
  check "b never holds 2 tokens while a has a task waiting ($bad of $looks snapshots); each holds one in $both; both finish (rc $ra $rb)" "[ $bad = 0 ] && [ $both -ge 2 ] && [ $ra = 0 ] && [ $rb = 0 ]"
}

t_fair() {
  # The fair line: on 2 tokens held by h, a1, a2, a3 and b1 all wait (nothing runs beside h); as
  # tokens free, a1 goes first (the oldest, both projects at 0), then b1 (b under its share, a at
  # it), then a2 and a3. Judged by history's start times: h's two tasks end together, and two runs
  # started in the same instant may write in either order.
  setup fair
  local f=$T/order n
  "$CPUQ" run -n 2 --label h:x -- "$BURN" -2 --until "$T/go" 2>/dev/null & local h=$!
  wait_running 2
  local k=0
  for n in a1 a2 a3 b1; do
    "$CPUQ" run --label "${n:0:1}:$n" -- sh -c "echo $n >>$f; sleep 0.5" &
    k=$((k + 1)); wait_waiters $k
  done
  sleep 0.5
  local early; early=$(sort "$f" 2>/dev/null | tr '\n' ' ')
  touch "$T/go"
  wait
  local got; got=$("$CPUQ" history --json | python3 -c 'import json, sys
j = [x for x in json.load(sys.stdin) if x["label"][:2] in ("a:", "b:")]
print(" ".join(x["label"][2:] for x in sorted(j, key=lambda x: (x["started"], x["label"]))))')
  check "nothing starts beside h's tokens (early: '$early'); then a1, b1 (under its share), a2, a3, by history (got $got)" "[ -z '$early' ] && [[ '$got' == 'a1 b1 a2 a3' || '$got' == 'a1 b1 a3 a2' ]]"
}

t_order() {
  # The line: within a project an --urgent run's first task first, then the runs in the order
  # they came; across projects the one running fewer for its weight.
  setup order "tokens = 1"
  local f=$T/order k=0 n
  "$CPUQ" run --label p:h -- "$BURN" -2 --until "$T/go" & wait_running 1
  for n in a b c d; do
    "$CPUQ" run --label "p:$n" -- sh -c "echo $n >>$f" &
    k=$((k + 1)); wait_waiters $k
  done
  "$CPUQ" run --urgent --label p:u -- sh -c "echo U >>$f" & wait_waiters 5
  touch "$T/go"
  wait
  local got; got=$(tr -d '\n' <"$f")
  check "--urgent goes first, then first come first served (got $got)" "[ '$got' = Uabcd ]"
  # Within a project the run running the fewest goes first: a newer run of an urgent run's
  # project starts before the urgent run's next task.
  setup urgent-once
  "$CPUQ" run -n 30 --label q:b -- "$BURN" -2 0.3 2>/dev/null & local b=$!
  wait_running 2
  "$CPUQ" run --urgent -n 30 --label p:u -- "$BURN" -2 0.3 2>/dev/null & local u=$!
  poll 5 '[ "$(sj "len([h for h in s[\"runs\"] if h[\"label\"] == \"p:u\" and h[\"running\"]])")" = 1 ]'
  local t0 rc dt; t0=$(now)
  "$CPUQ" run --wait-max 6 --label p:c -- true; rc=$?; dt=$(since "$t0")
  kill -TERM $u $b; reap $u; reap $b
  check "a newer run of a busy project starts before that project's long run takes another (rc $rc after ${dt}s)" "[ $rc = 0 ] && fl '$dt < 4'"
}

t_stream() {
  # No stream of arrivals starves a waiting run. Within a project, a run that has started goes
  # before new runs that arrived after its last start: on a pool of 1, a's second task starts
  # before b1, b2 and b3, which arrive while a's first runs (each new run once went first).
  setup stream "tokens = 1"
  local f=$T/order n
  "$CPUQ" run -n 2 --label p:a -- sh -c "echo a\$CPUQ_TASK >>$f; \"$BURN\" 1.5" 2>/dev/null & local a=$!
  wait_line "$f" a1
  for n in b1 b2 b3; do
    "$CPUQ" run --label "p:$n" -- sh -c "echo $n >>$f; \"$BURN\" 0.2" &
    sleep 0.2
  done
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "a run that started goes before newer runs of its project that arrived after its last start (got $got)" "[ '$got' = 'a1 a2 b1 b2 b3 ' ]"
}

t_first() {
  # A freed token goes to the first in line, not to whichever run looks first: on 3 tokens,
  # sleepers of b, c and x hold them; e queues, then a new run of x. Both are under their share.
  # When x's task ends, e (older in line) takes its token; x's new run waits for the next, when b
  # or c ends.
  setup first "tokens = 3"
  if [ "$(tokcpus | wc -w | tr -d ' ')" -lt 3 ]; then echo "  skipped: needs 3 tokens"; return; fi
  local f=$T/order n
  for n in b c; do "$CPUQ" run --label "$n:s" -- sh -c "sleep 6; echo $n-end >>$f" & done
  "$CPUQ" run --label x:s -- sh -c "sleep 2; echo x-end >>$f" &
  wait_running 3
  "$CPUQ" run --label e:s -- sh -c "echo e-start >>$f; sleep 6" & wait_waiters 1
  "$CPUQ" run --label x:new -- sh -c "echo x2-start >>$f" & wait_waiters 2
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "the token x's task frees goes to e, first in line; x's new run starts once b or c ends (got $got)" \
    "[[ '$got' == 'x-end e-start '[bc]-end' '*x2-start* ]]"
}

t_drain() {
  # cpuq drain -c N: after the runs queued before it, once N whole cores' tokens are free, it takes
  # them at once for its command, and the rest of the machine keeps working; CPUQ_CPUS names them
  # (the last of the tokens). Its -t, its idle stop and --max hold.
  setup drain "tokens = 3"
  if [ "$(tokcores)" -lt 3 ]; then echo "  skipped: needs 3 tokens on 3 cores (here $(tokcpus))"; return; fi
  local f=$T/log
  "$CPUQ" run -n 2 --label d:a -- sh -c "echo a\$CPUQ_TASK-start >>$f; \"$BURN\" -2 3; echo a\$CPUQ_TASK-end >>$f" 2>/dev/null & local a=$!
  wait_running 2
  local t0; t0=$(now)
  "$CPUQ" drain -c 1 --max 20s --label d:timing -- sh -c "echo drain-start \$CPUQ_CPUS >>$f; sleep 0.5; echo drain-end >>$f"; local rd=$?
  local dt; dt=$(since "$t0")
  wait $a; local ra=$?
  local last; last=$(tokcpus); last=${last##* }
  echo "  $(tr '\n' ' ' <"$f")"
  check "a drain of 1 CPU takes a free token at once beside running tasks (${dt}s; rc $rd), the tokens' last CPU ($(grep drain-start "$f")), and they finish (rc $ra)" \
    "[ $rd = 0 ] && [ $ra = 0 ] && fl '$dt < 2' && grep -qx 'drain-start $last' '$f' && [ \$(grep -n drain-end '$f' | cut -d: -f1) -lt \$(grep -n a1-end '$f' | cut -d: -f1) ]"
  # A drain passes no run that queued before it: with one waiting, --max gives up (75).
  "$CPUQ" run -n 3 --label d:hold -- "$BURN" -2 4 2>/dev/null & local h=$!
  wait_running 3
  "$CPUQ" run --label d:older -- touch "$T/older" & local o=$!
  wait_waiters 1
  local t1 rc dt1; t1=$(now)
  "$CPUQ" drain -c 1 --max 1s -- touch "$T/ran" 2>/dev/null; rc=$?; dt1=$(since "$t1")
  wait $h $o
  local ran=no; [ -e "$T/ran" ] && ran=yes
  check "a drain behind an older waiter, with --max 1s, gives up with 75 (rc $rc after ${dt1}s, ran: $ran)" "[ $rc = 75 ] && [ $ran = no ] && fl '$dt1 < 2.5'"
  local rt; t1=$(now)
  "$CPUQ" drain -c 1 --max 20s -t 1s -- sleep 30 2>/dev/null; rt=$?; dt1=$(since "$t1")
  check "drain -t 1s ends its command with 124 (rc $rt after ${dt1}s)" "[ $rt = 124 ] && fl '$dt1 < 10'"
  local bad; bad=$("$CPUQ" drain -c 1 -t off -- true 2>&1 >/dev/null; echo "rc $?")
  local half; half=$("$CPUQ" drain -c 2 -- true 2>&1 >/dev/null; echo "rc $?")
  check "a drain has no -t off, -t goes no higher than 2h, and -c takes at most half the tokens (${bad##*rc } ${half##*rc })" \
    "[ '${bad##*rc }' = 2 ] && [ '${half##*rc }' = 2 ] && \"$CPUQ\" drain -t 3h -c 1 -- true 2>/dev/null; [ \$? = 2 ]"
  local none; none=$("$CPUQ" drain -- true 2>&1 >/dev/null; echo "rc $?")
  local all; all=$("$CPUQ" drain --all -- touch "$T/ran-all" 2>&1 >/dev/null; echo "rc $?")
  check "a drain needs -c N or --cpus (${none##*rc }); --all is gone and says -c N, running nothing (${all})" "[ '${none##*rc }' = 2 ] && [[ '$all' == *'--all is gone: use -c N'*'rc 2' ]] && [ ! -e '$T/ran-all' ]"
  # A drain whose command idles while others wait is stopped (drain_idle); one that computes,
  # even on a single CPU, runs on.
  echo "drain_idle = 3s" >>"$CPUQ_CONFIG"
  local w=$T/idle
  "$CPUQ" drain -c 1 --max 20s --label d:idle -- sh -c "echo idle-start >>$w; sleep 30; echo idle-end >>$w" 2>"$T/idle.err" & local di=$!
  wait_line "$w" idle-start
  "$CPUQ" run -n 2 --label q:hold -- "$BURN" -2 6 2>/dev/null & local qh=$!
  wait_run q:hold
  "$CPUQ" run --wait-max 30 --label q:waiter -- sh -c "echo waiter >>$w" & local dw=$!
  local ri rw; wait $di; ri=$?; wait $dw; rw=$?; wait $qh
  local hist; hist=$("$CPUQ" history --label d:idle --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0].get("stopped"))')
  check "an idle drain with a run waiting is stopped (rc $ri, history: $hist), and the run follows (rc $rw: $(tr '\n' ' ' <"$w"))" \
    "[ $ri = 124 ] && [ $rw = 0 ] && [ '$hist' = idle ] && grep -q waiter $w && ! grep -q idle-end $w && grep -q 'kept under' $T/idle.err"
  local u=$T/busy
  "$CPUQ" drain -c 1 --max 20s --label d:busy -- python3 -c "import time
open('$u','a').write('busy-start\n')
e = time.time() + 6
while time.time() < e: pass
open('$u','a').write('busy-end\n')" & local db=$!
  wait_line "$u" busy-start
  "$CPUQ" run -n 2 --label r:hold -- "$BURN" -2 7 2>/dev/null & local rh=$!
  wait_run r:hold
  "$CPUQ" run --wait-max 30 --label r:waiter2 -- sh -c "echo waiter2 >>$u" & local dw2=$!
  local rb rw2; wait $db; rb=$?; wait $dw2; rw2=$?; wait $rh
  check "a drain computing on one CPU runs on with a run waiting (rc $rb $rw2: $(tr '\n' ' ' <"$u"))" \
    "[ $rb = 0 ] && [ $rw2 = 0 ] && grep -q busy-end $u"
}

t_drain_cpus() {
  # A drain names its CPUs (--cpus), or picks whole cores (--prefer fast: performance cores
  # first); all its drains together hold at most half the tokens, so a second waits for the
  # first. On Linux a drain isolates its CPUs' SMT siblings too.
  setup drain-cpus
  local first last; first=$(tokcpus); last=${first##* }; first=${first%% *}
  local got; got=$("$CPUQ" drain --cpus "$first" --max 20s -- sh -c 'echo "$CPUQ_CPUS"')
  local fast; fast=$("$CPUQ" drain -c 1 --prefer fast --max 20s -- sh -c 'echo "$CPUQ_CPUS"')
  local bad=""
  "$CPUQ" drain -c 2 --cpus "$first" -- true 2>/dev/null; bad="$bad$? "
  "$CPUQ" drain --cpus 4095 -- true 2>/dev/null; bad="$bad$? "
  "$CPUQ" drain -c 1 --prefer slow -- true 2>/dev/null; bad="$bad$? "
  "$CPUQ" drain --cpus "$first" --prefer fast -- true 2>/dev/null; bad="$bad$? "
  check "--cpus $first names its CPU ($got); --prefer fast takes one of the tokens ($fast: $(tokcpus)); a -c that disagrees, a CPU not a token, --prefer other than fast, --prefer with --cpus are usage errors ($bad)" \
    "[ '$got' = '$first' ] && [[ ' $(tokcpus) ' == *\" $fast \"* ]] && [ '$bad' = '2 2 2 2 ' ]"
  # Two drains of 1 on 2 tokens: half the tokens is 1, so they run one at a time, in turn.
  local g=$T/two
  "$CPUQ" drain -c 1 --max 20s --label g:one -- sh -c "echo one-start >>$g; sleep 1; echo one-end >>$g" & local d1=$!
  wait_line "$g" one-start
  "$CPUQ" drain -c 1 --max 20s --label g:two -- sh -c "echo two-start >>$g; sleep 0.3; echo two-end >>$g" & local d2=$!
  local r1 r2; wait $d1; r1=$?; wait $d2; r2=$?
  local order; order=$(tr '\n' ' ' <"$g")
  check "two drains of 1 CPU on 2 tokens run one at a time (rc $r1 $r2: $order)" "[ $r1 = 0 ] && [ $r2 = 0 ] && [ '$order' = 'one-start one-end two-start two-end ' ]"
  if [ "$(uname)" != Linux ]; then
    # macOS measures the machine's work beyond what the drain leaves to it: under a bound it
    # meets (8 CPUs past the rest of the machine), the command starts once measured.
    local q; "$CPUQ" drain -c 1 --quiet-max 8 --max 20s -- touch "$T/ran-mac"; q=$?
    check "--quiet-max on macOS starts the command under a bound it meets (rc $q)" "[ $q = 0 ] && [ -e '$T/ran-mac' ]"
    return
  fi
  # Linux: a drain of 1 isolates its CPU's SMT siblings too.
  local sib; sib=$("$CPUQ" drain -c 1 --max 20s -- sh -c '"$1" status --json --no-usage | python3 -c "import json, sys; print(\",\".join(map(str, sorted(json.load(sys.stdin)[\"isolated\"]))))"; cat /sys/devices/system/cpu/cpu$CPUQ_CPUS/topology/thread_siblings_list' sh "$CPUQ" | tr '\n' ' ')
  local want; want=$(python3 -c "
import sys
t = '${sib#* }'.strip()
s = set()
for p in t.split(','):
    if p:
        a, _, b = p.partition('-'); s.update(range(int(a), int(b or a) + 1))
print(','.join(map(str, sorted(s))))")
  check "a drain isolates its CPU with its SMT siblings (isolated ${sib%% *}; siblings $want)" "[ '${sib%% *}' = '$want' ]"
  # Linux: work from outside on a drain's CPU (a burner pinned there, which cpuq doesn't run)
  # makes it noisy: status flags it live and history records it; --quiet-max holds the command
  # until the CPU is quiet, and gives up at --max.
  if ! command -v taskset >/dev/null; then echo "  skipped: noise needs taskset"; return; fi
  taskset -c "$last" "$BURN" --until "$T/quiet" 30 & local noise=$!
  sleep 0.5
  "$CPUQ" drain --cpus "$last" --max 20s --label n:noisy -- sh -c 'sleep 2.5; "$1" status --json --no-usage | python3 -c "import json, sys; print(\" \".join(f for h in json.load(sys.stdin)[\"runs\"] for f in h[\"flags\"]))"' sh "$CPUQ" >"$T/flags"; local rn=$?
  local t0 rq dq; t0=$(now)
  "$CPUQ" drain --cpus "$last" --quiet-max 0.2 --max 3s --label n:quiet -- touch "$T/ran-loud" 2>"$T/quiet.err"; rq=$?; dq=$(since "$t0")
  touch "$T/quiet"; wait $noise
  # Under a bound it meets (a shared machine's own work may stay on the core: 8 CPUs is more than
  # any core holds), the command starts once measured.
  local rq2; "$CPUQ" drain --cpus "$last" --quiet-max 8 --max 20s --label n:quiet2 -- touch "$T/ran-quiet"; rq2=$?
  local hist; hist=$("$CPUQ" history --label n:noisy --json | python3 -c 'import json,sys; n = json.load(sys.stdin)[0].get("noisy") or {}; print("%.1f %s" % (n.get("max", 0), n.get("top", "-")))')
  # The busiest process named is the burner, or on a shared host another one on that CPU.
  check "outside work on its CPU: status flags the drain noisy ($(cat "$T/flags"); rc $rn) and history records it ($hist)" "[ $rn = 0 ] && grep -qw noisy '$T/flags' && fl \"${hist%% *} >= 0.5\" && [[ '$hist' == *'('*')'* ]]"
  check "--quiet-max waits for a quiet CPU and gives up at --max (rc $rq after ${dq}s: $(cat "$T/quiet.err"), ran: $([ -e "$T/ran-loud" ] && echo yes || echo no)); under a bound it meets it runs (rc $rq2)" \
    "[ $rq = 75 ] && [ ! -e '$T/ran-loud' ] && fl '2.5 < $dq < 6' && grep -q 'never quieted' '$T/quiet.err' && [ $rq2 = 0 ] && [ -e '$T/ran-quiet' ]"
}

t_drain_turn() {
  # A drain takes its turn: a run that queued before it and waits starts first; the drain then
  # starts at once, with no task ending for it.
  setup drain_turn "tokens = 1"
  local f=$T/log
  "$CPUQ" run --label t:busy -- sh -c "\"$BURN\" -2 3; echo busy-end >>$f" & local b=$!
  wait_running 1
  "$CPUQ" run --label t:older -- sh -c "echo older-start >>$f; \"$BURN\" 0.5; echo older-end >>$f" & local o=$!
  wait_waiters 1
  "$CPUQ" drain -c 1 --max 30s --label t:drain -- sh -c "echo drain-start >>$f; sleep 0.5; echo drain-end >>$f" & local d=$!
  wait_waiters 2
  local why; why=$("$CPUQ" status --no-usage | grep 't:drain' | grep -o 'runs queued before it go first' | head -1)
  wait $b $o $d
  local got; got=$(tr '\n' ' ' <"$f")
  # By history's start times: the older run takes the one token first; the drain, its turn come,
  # takes it once the older run's task ends.
  local order; order=$("$CPUQ" history --json | python3 -c 'import json, sys
j = {x["label"]: x for x in json.load(sys.stdin)}
print("ok" if j["t:older"]["started"] < j["t:drain"]["started"] else "wrong")')
  check "an older run starts before the drain (${why:-no turn shown}; by history $order: $got)" "[ '$order' = ok ] && [ -n '$why' ]"
  # Drains hold at most drain_max of the tokens together (half by default), a drain's CPUs
  # counting with their SMT siblings that are tokens: a second drain that would pass it waits for
  # the first, and starts once it ends. On 4 tokens, its size is set from what the first holds (1
  # CPU, or a whole core of 2), so it always needs the cap's room. On Linux with SMT, again on a
  # pool of two whole cores.
  half_case drain_half "tokens = 4"
  if [ "$(uname)" = Linux ]; then
    local cores; cores=$(python3 -c '
import glob, re
seen, out = set(), []
def cpus(t):
    s = []
    for p in t.split(","):
        a, _, b = p.partition("-"); s += range(int(a), int(b or a) + 1)
    return s
for f in sorted(glob.glob("/sys/devices/system/cpu/cpu[0-9]*/topology/thread_siblings_list"), key=lambda f: int(re.search(r"cpu(\d+)/", f).group(1))):
    sib = tuple(cpus(open(f).read().strip()))
    if len(sib) >= 2 and sib not in seen:
        seen.add(sib); out.append(sib[:2])
    if len(out) == 2: break
if len(out) == 2: print(",".join(str(c) for c in (out[0][0], out[1][0], out[0][1], out[1][1])))')
    if [ -n "$cores" ]; then half_case drain_half_smt "cpus = $cores" "reserve = 0"; else echo "  skipped: no SMT here"; fi
  fi
}

# half_case NAME [config lines]: drain_turn's half-pool case on the pool its config makes.
half_case() {
  local name=$1; shift
  setup "$name" "$@"
  if [ "$(tokcpus | wc -w | tr -d ' ')" -lt 4 ]; then echo "  skipped: needs 4 tokens"; return; fi
  local g=$T/half
  "$CPUQ" drain -c 1 --max 20s --label h:first -- sh -c "echo first-start >>$g; sleep 2; echo first-end \$(python3 -c 'import time; print(time.time())') >>$g" & local d1=$!
  wait_line "$g" first-start
  local k; k=$(sj 'len(set(s["isolated"]) & set(s["token_cpus"]))')
  local c2=2; [ "${k:-1}" -ge 2 ] && c2=1
  "$CPUQ" drain -c $c2 --max 20s --label h:second -- sh -c "echo second-start \$(python3 -c 'import time; print(time.time())') >>$g" & local d2=$!
  local r1 r2; wait $d1; r1=$?; wait $d2; r2=$?
  local order gap; order=$(cut -d' ' -f1 <"$g" | tr '\n' ' ')
  gap=$(python3 -c "
import sys
t = {l.split()[0]: float(l.split()[1]) for l in open('$g') if len(l.split()) > 1}
print('%.1f' % (t['second-start'] - t['first-end']) if len(t) == 2 else 'none')")
  check "drains hold at most drain_max: the first holds $k of the tokens ($(tokcpus)), a second of -c $c2 waits for it, and starts ${gap}s after it ends (rc $r1 $r2: $order)" \
    "[ $r1 = 0 ] && [ $r2 = 0 ] && [ '$order' = 'first-start first-end second-start ' ] && fl '$gap < 2.5'"
}

t_drain_cap() {
  # A waiting drain takes up a raised drain_max: a second drain waits at the cap beside a first,
  # and starts once the cap is raised, the first still running. History counts each drain's
  # task-hours as the CPUs it isolated.
  local big="tokens = 4"; [ "$(getconf _NPROCESSORS_ONLN)" -ge 8 ] && big="tokens = 8"
  setup drain_cap "$big"
  local p g=$T/cap; p=$(tokcpus | wc -w | tr -d ' ')
  if [ "$p" -lt 4 ]; then echo "  skipped: needs 4 tokens"; return; fi
  "$CPUQ" drain -c 1 --max 20s --label c:first -- sh -c "echo first-start >>$g; sleep 6; echo first-end >>$g" & local d1=$!
  wait_line "$g" first-start
  # The first holds k (its core's threads that are tokens); the second takes whole cores of k,
  # enough to pass the cap of half the tokens beside the first but fit under p - 1.
  local k cap c2 j n1 n2; k=$(sj 'len(set(s["isolated"]) & set(s["token_cpus"]))'); cap=$((p / 2))
  n1=$(sj 'len(s["isolated"])')
  c2=$(((cap - k) / k + 1)); j=$((c2 * k))
  if [ $j -gt $cap ] || [ $((k + j)) -gt $((p - 1)) ]; then kill $d1; wait $d1; echo "  skipped: no second drain fits (pool $p, $k a core)"; return; fi
  "$CPUQ" drain -c $c2 --max 20s --label c:second -- sh -c "echo second-start >>$g; sleep 1" & local d2=$!
  poll 10 '"$CPUQ" status --no-usage | grep c:second | grep -q drain_max'
  local held; held=$("$CPUQ" status --no-usage | grep c:second | grep -o 'drain_max' | head -1)
  sleep 1.5
  echo "drain_max = $((p - 1))" >>"$CPUQ_CONFIG"
  wait_line "$g" second-start
  n2=$(($(sj 'len(s["isolated"])') - n1))
  local r1 r2; wait $d2; r2=$?; wait $d1; r1=$?
  local got; got=$(tr '\n' ' ' <"$g")
  check "a drain waiting at drain_max (${held:-not shown}) starts once it is raised, beside the first (rc $r1 $r2: $got)" \
    "[ -n '$held' ] && [ $r1 = 0 ] && [ $r2 = 0 ] && [ '$got' = 'first-start second-start first-end ' ]"
  local cores; cores=$("$CPUQ" history --json | python3 -c 'import json, sys
j = {x["label"]: x for x in json.load(sys.stdin)}
print(j["c:first"]["cores"], j["c:second"]["cores"])')
  # Every CPU a drain isolates counts, its SMT siblings outside the pool too: they are kept free.
  check "history counts a drain as the CPUs it isolated (want $n1 $n2, got $cores)" "[ '$cores' = '$n1 $n2' ]"
}

t_drain_hold() {
  # A drain holds nothing while it waits: on 4 tokens held by a's tasks (ending a second apart), a
  # drain of 2 waits holding none, and the tokens a frees go to b, a newer run, as usual. Once two
  # whole cores' tokens are free together, it takes them in one step.
  setup drain_hold "tokens = 4"
  if [ "$(tokcpus | wc -w | tr -d ' ')" -lt 4 ]; then echo "  skipped: needs 4 tokens"; return; fi
  local f=$T/log
  "$CPUQ" run -n 4 --label a:x -- sh -c '"$1" -2 "$CPUQ_TASK"' sh "$BURN" 2>/dev/null & local a=$!
  wait_running 4
  "$CPUQ" drain -c 2 --max 30s --label d:two -- sh -c 'echo drain-start >>"$2"; "$1" status --json --no-usage >"$3"; sleep 0.5' sh "$CPUQ" "$f" "$T/during.json" 2>"$T/d.err" & local d=$!
  local why=""; poll 5 '"$CPUQ" status --no-usage | grep d:two | grep -q "whole core"' && why=$("$CPUQ" status --no-usage | grep d:two | grep -o 'waits for 2 whole cores' | head -1)
  local held; held=$(sj 's["held"]')
  "$CPUQ" run -n 4 --label b:x -- sh -c 'echo "b$CPUQ_TASK" >>"$1"; sleep 0.3' sh "$f" 2>/dev/null & local b=$!
  wait $a $b; wait $d; local rd=$?
  if [ $rd = 2 ] && grep -q drain_max "$T/d.err"; then echo "  skipped: a drain of 2 whole cores takes more than drain_max here ($(cat "$T/d.err"))"; return; fi
  local got; got=$(tr '\n' ' ' <"$f")
  local took; took=$(python3 -c 'import json, sys
s = json.load(open(sys.argv[1]))
d = [h for h in s["runs"] if h["drain"]][0]
print(s["held"] - sum(h["running"] for h in s["runs"] if not h["drain"]), len(set(d["cpus"]) & set(s["token_cpus"])))' "$T/during.json" 2>/dev/null)
  check "a waiting drain holds no token (held $held, all a's; ${why:-why not shown}); a's first freed token goes to b ($got); then it takes 2 tokens at once (held then: $took; rc $rd)" \
    "[ '$held' = 4 ] && [ -n '$why' ] && [[ '$got' == b1* ]] && [[ '$got' == *drain-start* ]] && [ '$took' = '2 2' ] && [ $rd = 0 ]"
}

t_drain_part() {
  # Linux: a task is pinned to its token's CPU, as status says; a drain takes a free whole core,
  # pinning its command there, and moves no task: the task stays on its CPU throughout.
  setup drain_part "tokens = 3"
  if [ "$(uname)" != Linux ]; then echo "  skipped: Linux only"; return; fi
  if [ "$(tokcores)" -lt 2 ]; then echo "  skipped: needs tokens on 2 cores (here $(tokcpus))"; return; fi
  local list='sed -n "s/^Cpus_allowed_list:[[:space:]]*//p" /proc/self/status'
  "$CPUQ" run -n 1 --label p:watch -- sh -c "while [ ! -e $T/stop ]; do $list >$T/cpu.new; mv $T/cpu.new $T/cpu; sleep 0.05; done" 2>/dev/null & local w=$!
  wait_file "$T/cpu"
  local before; before=$(cat "$T/cpu")
  local said; said=$(sj '[t["cpu"] for h in s["runs"] if h["label"] == "p:watch" for t in h["running_tasks"]][0]')
  "$CPUQ" drain -c 1 --max 20s --label p:drain -- sh -c "echo \$CPUQ_CPUS >$T/drain; $list >$T/drain.own; sleep 1; cat $T/cpu >$T/during"
  local after; after=$(cat "$T/cpu")
  touch "$T/stop"; reap $w
  local cpu own during; cpu=$(cat "$T/drain"); own=$(cat "$T/drain.own"); during=$(cat "$T/during")
  check "a task is pinned to its token's CPU ($before; status: $said); a drain pins its command to CPU $cpu ($own), and the task stays on its CPU (during: $during, after: $after)" \
    "[ '$before' = '$said' ] && [ '$own' = '$cpu' ] && [ '$cpu' != '$before' ] && [ '$during' = '$before' ] && [ '$after' = '$before' ]"
}

t_drain_long() {
  # A drain holds its cores at most drain_timeout while anyone waits, whatever its own -t.
  setup drain_long "drain_timeout = 3s"
  local t0 rc dt; t0=$(now)
  "$CPUQ" drain -c 1 -t 1h --label d:long -- sh -c 'end=$(($(date +%s)+30)); while [ $(date +%s) -lt $end ]; do :; done' 2>"$T/err" & local d=$!
  wait_line_any() { :; }
  sleep 1
  "$CPUQ" drain -c 1 --max 60s -t 10s --label d:next -- true & local n=$!
  wait $d; rc=$?; dt=$(since "$t0"); wait $n; local rn=$?
  check "a drain past drain_timeout is stopped while another waits (rc $rc after ${dt}s; next rc $rn)" "[ $rc = 124 ] && fl '$dt < 15' && [ $rn = 0 ] && grep -q 'drain_timeout' '$T/err'"
}

t_limit() {
  # cpuq limit RUN -c C: a running run's -c changes. Raised, it starts more at once (here under
  # its share); lowered, it starts none until fewer run, killing none. Status flags a run held back
  # by its -c while tokens are free.
  setup limit "tokens = 4"
  "$CPUQ" run -n 12 -c 1 -t 1h --label l:many -- sleep 1 2>/dev/null & local r=$!
  wait_running 1
  local flag; flag=$("$CPUQ" status --json --no-usage | python3 -c 'import json,sys; s=json.load(sys.stdin); print(",".join(f for h in s["runs"] for f in h["flags"]))')
  local out; out=$("$CPUQ" limit l:many -c 3); local rc=$?
  local up=no; wait_running 3 5 && up=yes
  "$CPUQ" limit l:many -c 25% >/dev/null
  local down=no; wait_running 1 5 && down=yes
  wait $r; local rr=$?
  check "cpuq limit raises a run's -c at once and lowers it as tasks end, killing none (flag: $flag; $out; up: $up, down: $down, rc $rr)" \
    "[ $rc = 0 ] && [ $up = yes ] && [ $down = yes ] && [ $rr = 0 ] && [ '$flag' = capped ]"
  local miss; miss=$("$CPUQ" limit l:nothing -c 2 2>&1; echo "rc $?")
  local bad; bad=$("$CPUQ" limit l:many 2>&1 >/dev/null; echo "rc $?")
  check "cpuq limit names no run: 1; no -c: 2 (${miss##*rc } ${bad##*rc })" "[ '${miss##*rc }' = 1 ] && [ '${bad##*rc }' = 2 ]"
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
time.sleep(30)' "$CPUQ_DIR/v4/lock" "$T/holder" & local h=$!
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
  # Everything at once on 2 tokens, for about 10 s: runs of tasks, single and urgent runs,
  # drains (two of 1 CPU, taking turns), kills, Ctrl-Z and continue, and status every 0.3 s.
  # Nothing may hang (each command has 60 s; a hang ends in 124, or 137 when it ignores the TERM),
  # status always answers, and the pool ends empty.
  setup storm
  local L=$T/rc; : >"$L"
  # t CMD...: run CMD with a 60 s limit, noting a hang.
  t() { tmo 60 "$@" >/dev/null 2>&1; local rc=$?; case $rc in 124|137) echo "hang: $*" >>"$L" ;; esac; return 0; }
  local end=$(( $(date +%s) + 10 )) pids=""
  ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" run -n 3 -t 20s --label s:many -- sh -c 'sleep 0.$((CPUQ_TASK * 2))'; done ) & pids="$pids $!"
  ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" run --label s:one -- "$BURN" 0.1; done ) & pids="$pids $!"
  ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" run --urgent --label s:urgent -- sleep 0.2; sleep 0.5; done ) & pids="$pids $!"
  ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" drain -c 1 --max 30s --label s:drain1 -- sleep 0.3; sleep 0.7; done ) & pids="$pids $!"
  ( while [ "$(date +%s)" -lt $end ]; do t "$CPUQ" drain -c 1 --max 30s --label s:drain2 -- sleep 0.3; sleep 0.7; done ) & pids="$pids $!"
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
  local h w; h=$(running); w=$(waiting)
  local hangs; hangs=$(wc -l <"$L" | tr -d ' ')
  [ "$hangs" = 0 ] || head -5 "$L"
  check "everything at once: no command hung ($hangs), status answered $((polls - stuck)) of $polls, all done ${tail}s after the end, pool empty (running $h, waiting $w)" \
    "[ $hangs = 0 ] && [ $stuck = 0 ] && fl '$tail < 30' && [ '$h' = 0 ] && [ '$w' = 0 ]"
}

t_kill() {
  # cpuq kill RUN, by label or ticket: SIGTERM to the run's cpuq, which ends its tasks; the run
  # exits by the signal. A label of two runs, or of none, is refused.
  setup kill
  "$CPUQ" run --label k:one -- sh -c 'echo $$ >"$1"; exec sleep 30' sh "$T/one" & local p=$!
  wait_file "$T/one"
  local said; said=$("$CPUQ" kill k:one); local rk=$?
  wait $p 2>/dev/null; local rp=$?
  sleep 0.2
  local left=no; alive "$T/one" && left=yes
  check "kill by label ends a single run (kill $rk: '$said'; run $rp; task left: $left)" "[ $rk = 0 ] && [ $rp = 143 ] && [ $left = no ] && [[ '$said' == 'stopping '*'k:one'* ]]"
  "$CPUQ" run -n 4 -c 2 --label k:many -- sh -c 'echo $$ >"$1.$CPUQ_TASK"; sleep 30' sh "$T/many" 2>"$T/err" & p=$!
  wait_running 2; wait_file "$T/many.1"; wait_file "$T/many.2"
  local ticket; ticket=$(sj '[h["ticket"] for h in s["runs"] if h["label"] == "k:many"][0]')
  "$CPUQ" kill "$ticket" >/dev/null; rk=$?
  wait $p 2>/dev/null; rp=$?
  sleep 0.2
  left=no; alive "$T/many.1" && left=yes; alive "$T/many.2" && left=yes
  check "kill by ticket ends a run of tasks, tasks stopped, not failed (kill $rk; run $rp; left: $left)" "[ $rk = 0 ] && [ $rp = 143 ] && [ $left = no ] && grep -q '2 stopped, 2 not run' '$T/err'"
  "$CPUQ" run --label k:two -- sleep 3 & local a=$!
  "$CPUQ" run --label k:two -- sleep 3 & local b=$!
  wait_running 2
  local two; two=$("$CPUQ" kill k:two 2>&1); local r2=$?
  local none; none=$("$CPUQ" kill k:none 2>&1); local rn=$?
  kill $a $b 2>/dev/null; wait $a $b 2>/dev/null
  check "a label of two runs is refused with both listed (rc $r2), one of none too (rc $rn: '$none')" "[ $r2 = 1 ] && [[ '$two' == *'2 runs are k:two'* ]] && [ $rn = 1 ] && [[ '$none' == *'no run here is k:none'* ]]"
}

t_ctrl_z() {
  # Ctrl-Z (SIGTSTP to cpuq): its tasks stop and give back their tokens, so a newcomer of its
  # project starts at once; continued, each task goes on once it holds a token again, and they
  # finish. For a run of tasks and for one task.
  setup ctrl-z
  dfl "$CPUQ" run -n 2 --label z:a -- sh -c 'echo $$ >"$1.$CPUQ_TASK"; "$2" 1.5' sh "$T/pid" "$BURN" 2>/dev/null & local a=$!
  wait_running 2; wait_file "$T/pid.1"; wait_file "$T/pid.2"
  kill -TSTP $a
  local freed=no; poll 5 '[ "$(running)" = 0 ]' && freed=yes
  local st; st=$(ps -o stat= -p "$(cat "$T/pid.1")" | tr -d ' ')
  local t0 rb dt; t0=$(now)
  "$CPUQ" run --wait-max 5 --label z:b -- true; rb=$?; dt=$(since "$t0")
  kill -CONT $a
  reap $a; local ra=$?
  check "a run of tasks stopped counts no more (freed: $freed), its tasks stopped ($st); a newcomer runs (rc $rb after ${dt}s); continued, it finishes (rc $ra)" \
    "[ $freed = yes ] && [[ '$st' == T* ]] && [ $rb = 0 ] && fl '$dt < 2' && [ $ra = 0 ]"
  setup ctrl-z-single "tokens = 1"
  dfl "$CPUQ" run --label z:one -- sh -c '"$2" 1; echo finished >"$1"' sh "$T/done" "$BURN" & a=$!
  wait_running 1
  kill -TSTP $a
  freed=no; poll 5 '[ "$(running)" = 0 ]' && freed=yes
  "$CPUQ" run --wait-max 5 --label z:b -- true; rb=$?
  kill -CONT $a
  reap $a; ra=$?
  check "one task stopped counts no more (freed: $freed), a newcomer runs (rc $rb), and continued it finishes (rc $ra, $(cat "$T/done" 2>/dev/null))" \
    "[ $freed = yes ] && [ $rb = 0 ] && [ $ra = 0 ] && [ \"\$(cat '$T/done' 2>/dev/null)\" = finished ]"
  # A stop and a continue that both land while cpuq is busy (here: blocked on the pool's lock,
  # held from outside), as from Ctrl-Z then a quick fg: the continue cancels the stop, and the
  # run goes on to finish once the lock and room come.
  "$CPUQ" run --label z:hold -- "$BURN" -2 4 & local h=$!
  wait_running 1
  dfl "$CPUQ" run -n 2 --label z:race -- true 2>/dev/null & a=$!
  wait_waiters 1
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "r+"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").write("1"); time.sleep(2.5)' "$CPUQ_DIR/v4/lock" "$T/locked" & local p=$!
  wait_file "$T/locked"
  sleep 1.5  # the waiter's 1 s look blocks on the lock
  # Apart, so cpuq's handler takes the stop first (a continue discards a stop still pending).
  kill -TSTP $a; sleep 0.2; kill -CONT $a
  wait $p
  local ended=no st2=""
  if poll 8 "! kill -0 $a 2>/dev/null"; then ended=yes; else st2=$(ps -o stat= -p $a | tr -d ' '); kill -CONT $a; fi
  reap $a; wait $h
  check "a stop then a continue while cpuq is busy leave the run running: it finishes (ended: $ended $st2)" "[ $ended = yes ]"
  # A continue that lands after cpuq has taken the stop, while it leaves the line's count (here:
  # blocked on the pool's lock, held from outside), as from an agent's `kill -TSTP; kill -CONT`:
  # cpuq doesn't stop itself after it, and the run finishes.
  dfl "$CPUQ" run --label z:lost -- sh -c 'sleep 1; echo finished >"$1"' sh "$T/lost" 2>/dev/null & a=$!
  wait_running 1
  python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "r+"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").write("1"); time.sleep(1.5)' "$CPUQ_DIR/v4/lock" "$T/locked2" & p=$!
  wait_file "$T/locked2"
  kill -TSTP $a; sleep 0.4; kill -CONT $a
  wait $p
  ended=no; st2=""
  if poll 8 "! kill -0 $a 2>/dev/null"; then ended=yes; else st2=$(ps -o stat= -p $a | tr -d ' '); kill -CONT $a; fi
  reap $a
  check "a continue while cpuq leaves the line's count for a stop leaves the run running: it finishes (ended: $ended $st2, $(cat "$T/lost" 2>/dev/null))" \
    "[ $ended = yes ] && [ \"\$(cat '$T/lost' 2>/dev/null)\" = finished ]"
  # A drain stopped by Ctrl-Z gives back its tokens. Continued, it takes its turn again, takes its
  # tokens again, and its command runs.
  setup ctrl-z-drain
  dfl "$CPUQ" drain -c 1 --max 30s --label z:drain -- sh -c 'sleep 1; touch "$1"' sh "$T/drained" 2>/dev/null & a=$!
  local on=no; poll 5 '[ "$(sj "s[\"held\"]")" = 1 ]' && on=yes
  kill -TSTP $a
  local back=no; poll 5 '[ "$(sj "s[\"held\"]")" = 0 ]' && back=yes
  kill -CONT $a
  local again=no; poll 5 '[ "$(sj "s[\"held\"]")" = 1 ]' && again=yes
  local rd; reap $a; rd=$?
  check "a drain holds its token (held 1: $on); stopped, it gives it back (0: $back); continued, it takes it again ($again) and runs (rc $rd, ran: $([ -e "$T/drained" ] && echo yes || echo no))" \
    "[ $on = yes ] && [ $back = yes ] && [ $again = yes ] && [ $rd = 0 ] && [ -e '$T/drained' ]"
}

t_nested() {
  # A run inside a task runs within that task at once, with no line, even with the pool busy:
  # found by CPUQ_OP, or, with it cleared (env -i), by its ancestor's run. A CPUQ_OP naming no
  # live run is ignored. The hook stands down inside a task.
  setup nested "tokens = 1"
  local t0 out dt
  t0=$(now)
  out=$("$CPUQ" run -- sh -c '"$1" run --wait-max 0 -- sh -c "echo inner \$CPUQ_OP"; echo "outer $CPUQ_OP"' sh "$CPUQ")
  dt=$(since "$t0")
  local same=no; set -- $out; [ $# = 4 ] && [ "$2" = "$4" ] && same=yes
  check "a run inside a task starts at once in a busy pool, within its run (${dt}s: $(echo $out))" "[ $same = yes ] && fl '$dt < 1'"
  out=$("$CPUQ" run -- sh -c '"$1" run -n 3 --wait-max 0 -- sh -c "echo t\$CPUQ_TASK"' sh "$CPUQ" 2>/dev/null | tr '\n' ' ')
  check "a run of 3 tasks inside a task runs them there, one at a time (got $out)" "[ '$out' = 't1 t2 t3 ' ]"
  out=$("$CPUQ" run -- env -i PATH="$PATH" HOME="$HOME" CPUQ_DIR="$CPUQ_DIR" CPUQ_CONFIG="$CPUQ_CONFIG" "$CPUQ" run --wait-max 0 -- sh -c 'echo "env-i ${CPUQ_OP:-none}"'); local rc=$?
  check "under env -i, the ancestor's run is found: it runs at once (rc $rc, '$out')" "[ $rc = 0 ] && [ '$out' = 'env-i none' ]"
  "$CPUQ" run --label n:hold -- "$BURN" -2 3 & local h=$!
  wait_running 1
  CPUQ_OP=99999 "$CPUQ" run --wait-max 0 --label n:x -- true 2>/dev/null; rc=$?
  wait $h
  check "a CPUQ_OP of no live run is ignored: the run waits its turn (rc $rc)" "[ $rc = 75 ]"
  local call='printf "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"make -j8\"}}" | "$1" hook 2>/dev/null; echo $?'
  local inside outside; inside=$("$CPUQ" run -- sh -c "$call" sh "$CPUQ"); outside=$(sh -c "$call" sh "$CPUQ")
  check "the hook stands down inside a task (rc $inside), not outside (rc $outside)" "[ '$inside' = 0 ] && [ '$outside' = 2 ]"
}

t_driver() {
  # --driver: a runner that is no task, with the terminal; each `cpuq run` it starts is admitted
  # on its own; an enclosing task's CPUQ_OP doesn't reach it; its exit is its own.
  setup driver "tokens = 1"
  local out rc
  "$CPUQ" run --driver --label d:runner -- sh -c '"$1" status --json --no-usage | python3 -c "import json, sys; print(\"running\", json.load(sys.stdin)[\"running\"])"; "$1" run --label d:case -- sh -c "echo case \${CPUQ_OP:+op}"; exit 3' sh "$CPUQ" >"$T/out"; rc=$?
  out=$(tr '\n' ' ' <"$T/out")
  local inner; inner=$(CPUQ_OP=1 "$CPUQ" run --driver -- sh -c 'echo "${CPUQ_OP:-none}"')
  check "a driver is no task, its runs are their own, its exit is its command's (got '$out', rc $rc); CPUQ_OP stays out ($inner)" \
    "[ '$out' = 'running 0 case op ' ] && [ $rc = 3 ] && [ '$inner' = 'none' ]"
  # A driver that computes itself counts against its project's share: on 2 tokens held by q
  # (weight 3), with dr's runner keeping CPUs busy itself (flagged), dr's run and another project's
  # wait; the first token q frees goes to the other project's run, under its share, not to dr's,
  # over it, though dr's came first.
  setup driver-cpu "weights = q:3"
  "$CPUQ" run --label q:h1 -- "$BURN" -2 --until "$T/stop1" 40 & local q1=$!
  "$CPUQ" run --label q:h2 -- "$BURN" -2 --until "$T/stop2" 40 & local q2=$!
  wait_running 2
  "$CPUQ" run --driver --label dr:runner -- "$BURN" -2 --until "$T/stop2" 40 & local d=$!
  poll 20 '[ "$(sj "[h[\"driver_busy\"] for h in s[\"runs\"] if h[\"driver\"]][0] >= 0.6" 2>/dev/null)" = True ]'
  local db; db=$(sj '"%.2f" % ([h["driver_busy"] for h in s["runs"] if h["driver"]] or [-1])[0]')
  local flags; flags=$(sj '" ".join(f for h in s["runs"] for f in h["flags"])')
  "$CPUQ" run --label dr:task -- sh -c "echo dr >>$T/order" & local rw=$!
  wait_waiters 1
  "$CPUQ" run --label other:task -- sh -c "echo other >>$T/order; sleep 1" & local ro=$!
  wait_waiters 2
  touch "$T/stop1"
  wait_file "$T/order"
  local first; first=$(head -1 "$T/order")
  touch "$T/stop2"; wait $d $q1 $q2 $rw $ro
  check "a driver computing CPUs itself ($db) is flagged ($flags); the first freed token goes to another project's run, under its share, before its own project's (got $first, then $(tail -1 "$T/order"))" \
    "[[ '$flags' == *driver_cpu* ]] && [ '$first' = other ]"
}

t_removed() {
  # A removed flag, command or config key fails at once (2) with a line saying what does its
  # work, and runs nothing.
  setup removed
  local wrong="" out rc f
  for f in "--cores 2" "--cores 2-6" "--priority high" "--max-wait 5" "--exclusive" "--qos none" "--opaque" "--no-load-check" "-x 2"; do
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
  for f in admit budget target settle poll aging backfill patience exclusive lend affinity load_check active_cap qos max_memory cpu_weights; do
    echo "$f = x" >"$T/c.$f"
    out=$(CPUQ_CONFIG=$T/c.$f "$CPUQ" run -- touch "$T/ran" 2>&1); rc=$?
    { [ $rc = 2 ] && [[ "$out" == *": $f is gone: "* ]]; } || wrong="$wrong [key $f: $rc $out]"
  done
  out=$("$CPUQ" lease bench --exclusive -- touch "$T/ran" 2>&1); rc=$?
  { [ $rc = 2 ] && [[ "$out" == *'cpuq drain'* ]]; } || wrong="$wrong [lease --exclusive: $rc $out]"
  local ran=no; [ -e "$T/ran" ] && ran=yes
  check "each removed flag, command and key fails with its pointer, running nothing (ran: $ran; wrong:${wrong:- none})" "[ -z '$wrong' ] && [ $ran = no ]"
}

# --- Losing runs and waiters -----------------------------------------------------------------

t_kill_holder() {
  # SIGKILL of a run's cpuq takes its task with it and frees its share at once: a waiter runs.
  setup kill-holder "tokens = 1"
  "$CPUQ" run -n 1 --label k:holder -- sh -c 'echo $$ >"$1"; exec "$2" -2 30' sh "$T/task" "$BURN" 2>/dev/null & local holder=$!
  wait_running 1; wait_file "$T/task"
  "$CPUQ" run --label k:waiter -- true & local waiter=$!
  wait_waiters 1
  local t0; t0=$(now)
  kill -9 $holder
  wait $waiter; local rc=$?
  local dt; dt=$(since "$t0")
  local left=no; alive "$T/task" && { left=yes; kill -9 "$(cat "$T/task")" 2>/dev/null; }
  check "a SIGKILLed run's task is ended and its share frees at once: the waiter ran ${dt}s after (rc $rc, task left: $left)" "[ $rc = 0 ] && fl '$dt < 2' && [ $left = no ]"
}

t_leftovers() {
  # A SIGKILLed run's tasks don't run on: on Linux they die with their cpuq (PR_SET_PDEATHSIG);
  # on macOS whoever next looks at the pool ends the tasks its record names.
  setup leftovers "tokens = 1"
  local mode got="" p
  for mode in single tasks; do
    local n=""; [ $mode = tasks ] && n="-n 1"
    rm -f "$T/task"
    "$CPUQ" run $n --label l:$mode -- sh -c 'echo $$ >"$1"; exec sleep 30' sh "$T/task" 2>/dev/null & p=$!
    wait_file "$T/task"
    kill -9 $p; wait $p 2>/dev/null
    sleep 0.3
    [ "$(uname)" = Linux ] || "$CPUQ" status --no-usage >/dev/null
    sleep 0.2
    if alive "$T/task"; then got="$got$mode:left "; kill -9 "$(cat "$T/task")"; else got="$got$mode:gone "; fi
  done
  check "a SIGKILLed run's tasks end, one task or many (got $got)" "[ '$got' = 'single:gone tasks:gone ' ]"
}

t_leaked_descendant() {
  # What a task leaves running in the background keeps no CPU: the next run starts at once; and a
  # task of many takes its process group with it.
  setup leaked-descendant "tokens = 1"
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
  # A SIGKILLed waiter doesn't hold up the line. (One burner: on Linux the task is pinned to its
  # token's CPU, so two would share it.)
  setup kill-waiter "tokens = 1"
  "$CPUQ" run --label w:hold -- "$BURN" 1.5 & local holder=$!
  wait_running 1
  "$CPUQ" run --label w:one -- true & local w1=$!
  wait_waiters 1
  "$CPUQ" run --label w:two -- true & local w2=$!
  wait_waiters 2
  kill -9 $w1
  local t0; t0=$(now)
  wait $w2; local rc=$?
  local dt; dt=$(since "$t0")
  wait $holder
  check "the second waiter ran ${dt}s after the first was SIGKILLed (the holder had about 1.5 s left; rc $rc)" "[ $rc = 0 ] && fl '$dt < 3.5'"
}

t_term_waiting() {
  # A run killed while it waits in the line gives up at once by the signal (143) and never starts
  # its command.
  setup term-waiting "tokens = 1"
  "$CPUQ" run --label w:hold -- "$BURN" -2 3 & local h=$!
  wait_running 1
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
  check "a waiting single run killed by SIGTERM ends at once by it (rc $rs after ${ds}s), running nothing ($single)" "[ $rs = 143 ] && fl '$ds < 1' && [ $single = no ]"
}

t_lost_seq() {
  # A lost ticket counter never hands out a live ticket.
  setup lost-seq
  "$CPUQ" run --label p:a -- "$BURN" -2 2 & "$CPUQ" run --label p:b -- "$BURN" -2 2 &
  wait_running 2
  "$CPUQ" run --label p:c -- true & wait_waiters 1
  rm -f "$CPUQ_DIR/v4/seq"
  "$CPUQ" run --label p:d -- true & wait_waiters 2
  local tickets; tickets=$(sj '" ".join(str(t) for t in sorted({h["ticket"] for h in s["runs"]} | {w["ticket"] for w in s["waiters"]}))')
  local rc=0 p; for p in $(jobs -p); do wait "$p" || rc=1; done
  check "with seq deleted the tickets stay distinct ($tickets) and every run completes (rc $rc)" "[ \$(echo $tickets | wc -w) = 4 ] && [ $rc = 0 ]"
}

t_long_command() {
  # A command line of 5000 bytes (an inline script) runs, and status shows its first 1000 bytes.
  setup long-command
  local pad; pad=$(printf 'x%.0s' $(seq 2000))
  "$CPUQ" run --label l:mid -- sh -c "sleep 1 # $pad" & local p=$!
  wait_running 1
  local shown; shown=$(sj '[len(h["command"]) for h in s["runs"]][0]')
  wait $p; local rc=$?
  check "a 2000-byte command runs and status shows its first 1000 bytes (rc $rc, $shown bytes)" "[ $rc = 0 ] && [ '$shown' = 1000 ]"
  pad=$(printf 'x%.0s' $(seq 5000))
  local out; out=$("$CPUQ" run -- sh -c "echo ran # $pad" 2>"$T/err"); rc=$?
  check "a 5000-byte command runs (rc $rc, '$out' $(cut -c1-60 "$T/err"))" "[ $rc = 0 ] && [ '$out' = ran ]"
}

t_waiters_cpu() {
  # A hundred runs waiting in the line use almost no CPU.
  setup waiters-cpu "tokens = 1"
  "$CPUQ" run --label w:hold -- "$BURN" -2 --until "$T/go" 30 & local h=$!
  wait_running 1
  local pids=() i
  for i in $(seq 100); do "$CPUQ" run --label w:x -- true & pids+=($!); done
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
  touch "$T/go"
  local rc=0 p
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  wait $h
  check "100 waiters were in the line while measured ($queued)" "[ $queued = yes ]"
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

# --- status, history, wait -------------------------------------------------------------------

t_status() {
  setup status
  "$CPUQ" run -n 4 -c 2 --label s:build -- "$BURN" -2 5 2>/dev/null & local sb=$!; wait_running 2
  "$CPUQ" run --label s:big -- true & wait_waiters 1
  local s; s=$("$CPUQ" status --no-usage)
  local j; j=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
m = s["memory"]
h = s["runs"][0]; w = s["waiters"][0]
print(s["schema"], s["version"] == sys.argv[1].split()[1], s["admit"], s["tokens"], len(s["token_cpus"]), s["reserve"] == len(s["pool"]) - 2, s["held"], s["free"], s["running"], s["gate"]["state"], s["memory_pressure"],
      0 < m["used"] <= m["total"], h["label"], h["tasks"], h["running"], sorted(t["cpu"] for t in h["running_tasks"]) == sorted(s["token_cpus"]), w["label"], w["order"], w["why"].startswith("1st in line"),
      " ".join(sorted("%s:%.1f" % (p["name"], p["fair"]) for p in s["projects"])))' "$("$CPUQ" --version)")
  kill -TERM $sb 2>/dev/null; wait
  echo "$s" | sed 's/^/  | /'
  check "status shows the pool, its tokens, the run on its token CPUs and the waiter with why it waits" "[[ '$s' == *\"dir     $CPUQ_DIR/v4\"* && '$s' == *'2 tokens, '*' reserved; 2 held, 0 free'* && '$s' == *s:build* && '$s' == *'2 of -c 2 on '* && '$s' == *s:big* && '$s' == *'1st in line; every token is held'* && '$s' == *'memory  '*' GB used'* ]]"
  check "status --json: schema 4, the tokens, runs on their token CPUs, waiters and projects with their share (got '$j')" "[ '$j' = '4 True tokens 2 2 True 2 0 2 open off True s:build 4 2 True s:big 1 True s:2.0' ]"
}

t_progress() {
  # A run of tasks shows its progress (tasks ended of all, with those failed) and the time left
  # in status.
  setup progress
  "$CPUQ" run -n 8 -c 1 --label p:count -- sh -c 'sleep 0.3; [ "$CPUQ_TASK" != 1 ]' 2>/dev/null & local p=$!
  sleep 1.4
  local got; got=$(sj '[(h["progress"]["done"] >= 2, h["progress"]["total"], h["progress"]["failing"], h["left"] is not None and h["left"] > 0, h["left_from"]) for h in s["runs"]][0]')
  local text; text=$("$CPUQ" status --no-usage | grep 'p:count')
  wait $p
  check "status shows a run's progress and time left (got $got; '$(echo $text)')" "[ \"$got\" = \"(True, 8, 1, True, 'progress')\" ] && [[ '$text' == *'/8'* ]]"
  # With only its running tasks left, status shows the tail: how long the oldest has run.
  "$CPUQ" run -n 2 --label p:tail -- sleep 3 2>/dev/null & p=$!
  wait_running 2; sleep 1.1
  local tail; tail=$("$CPUQ" status --no-usage | grep 'p:tail')
  local tj; tj=$(sj '[(h["tail"], h["oldest"] > 0) for h in s["runs"] if h["label"] == "p:tail"][0]')
  wait $p
  check "status shows a run's tail: 'last 2 tasks, oldest running ...' ($(echo $tail); $tj)" "[[ '$tail' == *'last 2 tasks, oldest running '* ]] && [ \"$tj\" = '(True, True)' ]"
}

t_usage() {
  # status measures what each run's tasks use: a 1-CPU spinner about 1. Three spinners in one task:
  # on Linux the task is pinned to its token's CPU, so they share it (about 1, no flag); on macOS,
  # which can't pin, about 3, and after 5 s status flags the run whose tasks keep more than one CPU
  # busy each. (A loaded machine gives each spinner less: the measure is judged against the
  # other's.)
  setup usage
  "$CPUQ" run --label u:spin -- python3 -c 'import time
e = time.time() + 9
while time.time() < e: pass' &
  "$CPUQ" run --label u:triple -- sh -c 'spin() { python3 -c "import time
e = time.time() + 9
while time.time() < e: pass"; }; spin & spin & spin; wait' &
  wait_running 2
  sleep 1
  # Three looks, each run's busiest: a shared CI runner can starve a spinner for one half-second
  # sample, never for three.
  local u; u=$(for k in 1 2 3; do "$CPUQ" status --json; done | python3 -c 'import json, sys
best = {}
for line in sys.stdin.read().replace("}\n{", "}\0{").split("\0"):
    for h in json.loads(line)["runs"]:
        best[h["label"]] = max(best.get(h["label"], 0), h["using"] or 0)
print(" ".join("%s=%.2f" % (k, v) for k, v in sorted(best.items())))')
  sleep 2.8
  local flags; flags=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
print(" ".join("%s:%s" % (h["label"], ",".join(h["flags"]) or "-") for h in sorted(s["runs"], key=lambda h: h["label"])))')
  wait
  echo "  measured use: $u; flags: $flags"
  if [ "$(uname)" = Linux ]; then
    check "status measures use: a spinner about 1, three in one pinned task about 1 too ($u)" "python3 -c '
import sys
u = dict(p.split(\"=\") for p in \"$u\".split())
s, t = float(u[\"u:spin\"]), float(u[\"u:triple\"])
sys.exit(0 if 0.3 < s < 1.3 and 0.3 < t < 1.3 else 1)'"
    check "a pinned task keeps one CPU busy at most: no run flagged ($flags)" "[ '$flags' = 'u:spin:- u:triple:-' ]"
  else
    check "status measures use: a spinner about 1, three in one task well over it, as CPUs allow ($u)" "python3 -c '
import sys
u = dict(p.split(\"=\") for p in \"$u\".split())
s, t = float(u[\"u:spin\"]), float(u[\"u:triple\"])
sys.exit(0 if 0.3 < s < 1.3 and 1.5 * s < t < 3.6 else 1)'"
    check "status flags the run whose task keeps three CPUs busy, not the other ($flags)" "[ '$flags' = 'u:spin:- u:triple:over_cpu' ]"
  fi
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
  wait_running 1
  local top=0 u
  while kill -0 $job 2>/dev/null; do
    u=$("$CPUQ" status --json | python3 -c 'import json, sys; print(max([h.get("using") or 0 for h in json.load(sys.stdin)["runs"]] or [0]))')
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
  wait_running 1
  sleep 0.5
  local mine; mine="$op $(descendants $op | tr '\n' ' ')"
  local got; got=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
stray = int(sys.argv[1]); mine = {int(p) for p in sys.argv[2].split()}
out = s["outside"]
pids = [o["pid"] for o in out]
named = stray in pids or len(out) >= 5
own_out = not (mine & set(pids))
used = sum(h["using"] or 0 for h in s["runs"])
print("named" if named else "missed", "own-out" if own_out else "own-listed", "%.1f" % used)' "$stray" "$mine")
  wait
  echo "  $got (stray pid $stray)"
  check "status names an outside process and leaves the operation's own out ($got)" "[[ '$got' == 'named own-out '* ]] && fl '${got##* } > 0.1'"
  # Outside work by what started it: a detached shell running two busy programs is one entry,
  # with the shell's command, its two processes and their CPUs together.
  ( sh -c 'busy() { python3 -c "import time
e = time.time() + 3
while time.time() < e: pass"; }; busy & busy & wait # cpuq-test-work' & )
  sleep 0.5
  got=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
w = [x for x in s["outside_work"] if "cpuq-test-work" in x["command"]]
print("found %d %.1f %s" % (w[0]["procs"], w[0]["using"], w[0]["via"] or "-") if w else "missing", len(s["outside_work"]))')
  sleep 2.6
  check "status puts outside work down to what started it: one entry, its command, 2 processes (got $got)" "[[ '$got' == 'found 2 '* ]] && fl \"\$(echo '$got' | cut -d' ' -f3) > 1.0\""
}

t_status_host() {
  setup status-host
  fake_ssh
  "$CPUQ" run -n 2 --label far:job -- sleep 2 2>/dev/null & wait_running 2
  local got; got=$(PATH="$T/bin:$PATH" "$CPUQ" status --json --no-usage --host local --host far | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(" ".join("%s:%d" % (h, d[h]["running"]) for h in sorted(d)))')
  check "status --host gives one JSON object keyed by host (got $got)" "[ '$got' = 'far:2 local:2' ]"
  local text; text=$(PATH="$T/bin:$PATH" "$CPUQ" status --no-usage --host far)
  check "status --host passes the host's own text through when piped" "[[ '$text' == *'running 2'* ]]"
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
  "$CPUQ" run -n 2 --label h:hog -- sleep 1.5 2>/dev/null & wait_running 2
  "$CPUQ" run --label h:impatient --wait-max 0 -- true 2>/dev/null
  wait
  "$CPUQ" run --label h:crash -- sleep 30.583 & local p=$!
  wait_running 1
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

t_project() {
  # A run's project is its label's, before the repository it runs in: a run labelled x:y inside a
  # repository named z is project x; with no label it is the repository's, z.
  setup project
  mkdir -p "$T/z" && git -C "$T/z" init -q
  local q='"$1" status --json --no-usage | python3 -c "import json, sys; print([h[\"project\"] for h in json.load(sys.stdin)[\"runs\"]][0])"'
  local labelled bare
  labelled=$(cd "$T/z" && "$CPUQ" run --label x:y -- sh -c "$q" sh "$CPUQ")
  bare=$(cd "$T/z" && "$CPUQ" run -- sh -c "$q" sh "$CPUQ")
  check "a run labelled x:y in repository z is project x ($labelled); unlabelled, z ($bare)" "[ '$labelled' = x ] && [ '$bare' = z ]"
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
  wait_run job:a
  local t0; t0=$(now)
  "$CPUQ" wait --label 'job:*'; local rc=$?
  local dt; dt=$(since "$t0")
  check "cpuq wait --label 'job:*' returns when the last matching run ends (exit $rc after ${dt}s)" "[ $rc = 0 ] && fl '1 < $dt < 5'"
  "$CPUQ" run --label long -- sleep 3 & wait_run long
  "$CPUQ" wait --label long --max-wait 1; rc=$?
  check "cpuq wait --max-wait gives up with 75 (got $rc)" "[ $rc = 75 ]"
  wait
}

t_record() {
  # cpuq record samples the machine into samples.jsonl beside the history; one runs at a time,
  # status says whether one does, and cpuq samples gives its lines from a time on.
  setup record
  export CPUQ_HISTORY=$T/history.jsonl
  "$CPUQ" run -n 2 --label held -- sleep 2 2>/dev/null & wait_running 2
  "$CPUQ" record --interval 0.2 2>/dev/null & local r=$!
  sleep 1.2
  "$CPUQ" record --interval 0.2 2>/dev/null; local second=$?
  local on; on=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; print(json.load(sys.stdin)["recorder"])')
  kill $r; wait $r 2>/dev/null; wait
  local got; got=$("$CPUQ" samples --since 0 | python3 -c 'import json, sys
s = [json.loads(l) for l in sys.stdin]
print(len(s), all(x["gate"] == "open" for x in s), max(x["running"] for x in s), len(s[-1]["cpu"]) > 0)')
  local future; future=$("$CPUQ" samples --since 9999999999 | wc -l | tr -d ' ')
  unset CPUQ_HISTORY
  check "record samples while another refuses to start (rc $second), status sees it ($on), and samples gives them from a time on (count, gate open, running, cpus: $got; none from the future: $future)" \
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
  check "--driver passes for a test runner (rc $driver) and any other command (rc $drvother), not around a bare build (rc $drvbuild)" \
    "[ $driver = 0 ] && [ $drvbuild = 2 ] && grep -q 'directly under --driver' '$T/drvbuild' && [ $drvother = 0 ]"
  local rigl rigbare
  rigl=$(call rigl Bash "cpuq run --driver --label rig:build -- env RIG_UNIT_LAUNCHER='cpuq run --' rig build --units=8 a.rig")
  rigbare=$(call rigbare Bash 'cpuq run --driver --label rig:build -- rig build --units=8 a.rig')
  check "--driver passes rig build, its units cpuq runs or not (what it computes counts against rig's share): rc $rigl $rigbare" \
    "[ $rigl = 0 ] && [ $rigbare = 0 ]"
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
  local h; h=$(running)
  check "a lease runs no task of the pool (running $h)" "[ '$h' = 0 ]"
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
  # Linux with a user systemd: a plain run has no scope (the kernel shares nothing by project:
  # each task has its token's CPU). A --driver's runner runs in a delegated scope in cpuq.slice,
  # and a cap inside it gets a cgroup of its own the kernel stops at the limit; the runs it starts
  # stay in its scope.
  setup cgroups
  local plain; plain=$(env -u CPUQ_CGROUP "$CPUQ" run --label plain:x -- sh -c 'echo "cg=${CPUQ_CGROUP:-none}"')
  check "a plain run has no scope of its own (got $plain)" "[ '$plain' = 'cg=none' ]"
  if [ "$(uname)" != Linux ] || ! systemd-run --user --scope --quiet true 2>/dev/null; then
    local got; got=$(env -u CPUQ_CGROUP "$CPUQ" run --driver --label plain -- sh -c 'echo "cg=${CPUQ_CGROUP:-none}"')
    check "without a user systemd a driver runs as it is (got $got)" "[ '$got' = 'cg=none' ]"
    return
  fi
  local got; got=$("$CPUQ" run --driver --label delegated -- sh -c 'echo "$(cut -d: -f3 /proc/self/cgroup) $CPUQ_CGROUP $(cat "$CPUQ_CGROUP/cgroup.subtree_control")"')
  local t0; t0=$(now)
  "$CPUQ" run --driver --label capped -- "$CPUQ" cap --mem 64M -- python3 -c 'import time; x = bytearray(256 << 20); time.sleep(10)' 2>/dev/null; local rc=$?
  local dt; dt=$(since "$t0")
  check "a driver runs in its scope's job/ in cpuq.slice, with CPUQ_CGROUP and memory for its children (got $got); a cap there is stopped by the kernel ($rc after ${dt}s)" "[[ '$got' == *'/cpuq.slice/cpuq-driver-'*'.scope/job /sys/fs/cgroup/'*'.scope '*memory* ]] && [ $rc = 122 ] && fl '$dt < 0.9'"
  local drv; drv=$("$CPUQ" run --driver --label drv:x -- sh -c '"$1" run --label drv:case -- sh -c "cut -d: -f3 /proc/self/cgroup"' sh "$CPUQ")
  check "a run a driver starts stays in the driver's scope (got $drv)" "[[ '$drv' == *'/cpuq-driver-'*'.scope/job' ]]"
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
  local lit2; lit2=$(env -u CPUQ_CGROUP "$CPUQ" run --label literal:x -- sh -c 'x=abc/job; echo "${x%/job}"' 2>&1)
  check "a command's \${x%/job} reaches its shell, under a driver (got '$lit') and a run (got '$lit2')" "[ '$lit' = abc ] && [ '$lit2' = abc ]"
  local off; off=$(echo "cgroups = off" >>"$CPUQ_CONFIG" && env -u CPUQ_CGROUP "$CPUQ" run --driver --label plain -- sh -c 'echo "cg=${CPUQ_CGROUP:-none}"')
  local off2; off2=$(env -u CPUQ_CGROUP "$CPUQ" run --label plain:x -- sh -c 'echo "cg=${CPUQ_CGROUP:-none}"')
  check "cgroups = off leaves a driver and a run as they are (got $off $off2)" "[ '$off' = 'cg=none' ] && [ '$off2' = 'cg=none' ]"
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
  # A test's tasks share the tokens: 4 tasks of 1 s on 2 tokens take about 2 s or less.
  setup test-pool
  export XDG_STATE_HOME=$T/xdg
  mkdir -p "$T/roots/repo/cpuq"
  echo "submit_roots = $T/roots" >> "$CPUQ_CONFIG"
  (
    cd "$T/roots/repo" || exit 1
    git init -q && git config user.email t@t && git config user.name t
    printf '%s\n' 'for i in 1 2 3 4; do echo "sleep 1" > "$CPUQ_TODO/t$i"; done' > mk.sh
    printf '%s\n' '{ "label": "t:pool", "tasks": "sh mk.sh" }' > cpuq/pool.json
    git add -A && git commit -qm init
    local t0; t0=$(now)
    "$CPUQ" test cpuq/pool.json >"$T/pool" 2>&1; echo "rc=$? took=$(since "$t0")"
  ) >"$T/out" 2>&1
  local got; got=$(cat "$T/out")
  local done_dir; done_dir=$(ls -d "$T"/xdg/cpuq/jobs/*/*/done "$HOME"/.local/state/cpuq/jobs/*/*/done 2>/dev/null | head -1)
  local secs; secs=$(grep -o 'PASS .* \([0-9]*\)s ' "$T/pool" | grep -o ' [0-9]*s ' | tail -1 | tr -d ' s')
  check "test: 4 tasks of 1 s on 2 tokens take about 2 s or less ($got; $(count "$done_dir") done; the job ${secs}s)" \
    "[[ '$got' == rc=0* ]] && [ \"\$(count '$done_dir')\" = 4 ] && [ '${secs:-99}' -le 4 ]"
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
  # its host too, so it holds the worktree's copy no longer: the next job runs at once. Its own
  # verdict is CPUQ ERROR (125), or CANCELLED (76) when the host's cancel is recorded first (seen
  # on a slow macOS runner): either way the copy is free. And a job
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
    "[[ '$got' =~ ^broken=(125|76)\ next=0\ next_s=1?[0-9]\ queued=76\ $ ]]"
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

TESTS=${*:-tokens reserve tasks io cpus_limit timeout retry wait_max share fair order stream first drain drain_cpus drain_turn drain_cap drain_hold drain_part drain_long limit lock_stuck storm kill ctrl_z nested driver removed \
  kill_holder leftovers leaked_descendant kill_waiter term_waiting lost_seq long_command waiters_cpu \
  exit_status direct_sigint terminal_sigint tasks_sigint ignored_signals stack_limit \
  status progress usage zombie outside status_host history project note wait record min_available min_disk hook \
  lease lease_host lease_host_hold hold_gone last_words on include_git on_check on_gitignore tethered \
  cap cap_quiet_crash cap_link cgroups submit test test_pool submit_moved submit_abandon submit_slots submit_on \
  submit_needs submit_mem submit_tmp submit_cancel_running submit_progress packs clean}
for t in $TESTS; do
  if declare -F "t_$t" >/dev/null; then "t_$t"; else echo "no such test: $t"; FAIL=$((FAIL+1)); FAILED+=" $t?"; fi
done
echo
echo "$PASS passed, $FAIL failed${FAILED:+:$FAILED}$([ $KNOWN = 0 ] || echo ", $KNOWN known: cpuq bugs, marked KNOWN above")"
[ $FAIL = 0 ] && [ $PASS != 0 ]
