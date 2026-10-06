#!/bin/bash
# test/run.sh [TEST...]: the end-to-end tests. Each test gets its own state
# directory and a config with the load and pressure gates and the active-core
# cap off, so the tests depend neither on the machine's load nor on its size.
# CPUQ=/path/to/cpuq tests another binary.
set -u
cd "$(dirname "$0")/.."
CPUQ=${CPUQ:-$PWD/bin/cpuq}
[ -x "$CPUQ" ] || { echo "no $CPUQ; run zig build first"; exit 2; }
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/cpuq-test.XXXXXX")
# On exit, end every process the tests started, children's children
# included, so none outlives the run holding its output open.
killtree() { local p; for p in $(pgrep -P "$1"); do killtree "$p"; kill "$p" 2>/dev/null; done; }
trap 'killtree $$; rm -rf "$ROOT"' EXIT
PASS=0
FAIL=0
FAILED=""

ok() { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED $CUR"; echo "  FAIL $1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

# setup NAME [config lines...]: a fresh state dir and config for one test.
setup() {
  CUR=$1; shift
  T=$ROOT/$CUR
  mkdir -p "$T"
  export CPUQ_DIR=$T/state CPUQ_CONFIG=$T/config CPUQ_BUDGET=9
  unset CPUQ_TOKEN MAKEFLAGS
  {
    echo "load_check = off"
    echo "pressure_check = off"
    echo "poll = 0.2"
    echo "active_cap = off" # a budget of 9 on a machine with fewer cores
    for line in "$@"; do echo "$line"; done
  } >"$CPUQ_CONFIG"
  echo "== $CUR"
}

# dfl CMD...: exec CMD with SIGINT and SIGQUIT at their defaults. A `&` job
# in a script starts with both ignored, and cpuq (like any command) keeps an
# ignored signal ignored.
dfl() { exec python3 -c 'import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$@"; }

held() { "$CPUQ" status --json --no-usage | sed -n 's/^  "held": \([0-9]*\),*/\1/p'; }
now() { python3 -c 'import time; print("%.3f" % time.time())'; }

# wait_held N [seconds]: until N cores are held.
wait_held() {
  local i=0
  while [ "$(held)" != "$1" ]; do
    i=$((i + 1)); [ $i -gt $((${2:-10} * 10)) ] && return 1
    sleep 0.1
  done
}

# wait_lease_holder NAME: until the named lease is held.
wait_lease_holder() {
  local i=0
  until "$CPUQ" status --json --no-usage | python3 -c 'import json, sys
s = json.load(sys.stdin)
sys.exit(0 if any(l["name"] == sys.argv[1] and l["holders"] for l in s["leases"]) else 1)' "$1"; do
    i=$((i + 1)); [ $i -gt 100 ] && return 1
    sleep 0.1
  done
}

# wait_lease_waiters NAME N: until the named lease has N waiters.
wait_lease_waiters() {
  local i=0
  until "$CPUQ" status --json --no-usage | python3 -c 'import json, sys
s = json.load(sys.stdin)
sys.exit(0 if sum(len(l["waiters"]) for l in s["leases"] if l["name"] == sys.argv[1]) == int(sys.argv[2]) else 1)' "$1" "$2"; do
    i=$((i + 1)); [ $i -gt 100 ] && return 1
    sleep 0.1
  done
}

# Wait until the queue holds N waiters.
wait_waiters() {
  local i=0
  while [ "$("$CPUQ" status --json --no-usage | grep -c '"order"')" != "$1" ]; do
    i=$((i + 1)); [ $i -gt 100 ] && return 1
    sleep 0.1
  done
}

t_budget() {
  setup budget
  local pids=() i
  for i in $(seq 20); do "$CPUQ" run --cores 3 -- sleep 1 & pids+=($!); done
  local max=0 samples=0 h
  while kill -0 "${pids[@]}" 2>/dev/null || [ -n "$(jobs -r)" ]; do
    h=$(held); samples=$((samples + 1))
    [ -n "$h" ] && [ "$h" -gt "$max" ] && max=$h
    sleep 0.2
    [ $samples -gt 200 ] && break
  done
  local rc=0
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  echo "  20 x --cores 3, budget 9: max held $max over $samples samples"
  check "never more than 9 cores held" "[ $max -le 9 ] && [ $max -gt 0 ]"
  check "all 20 finished with status 0" "[ $rc = 0 ]"
}

t_affinity() {
  setup affinity
  if ! command -v taskset >/dev/null || [ "$(getconf _NPROCESSORS_CONF)" -lt 6 ]; then
    echo "  skipped: needs Linux with taskset and 6 or more CPUs"
    return
  fi
  # Holds on tokens 2-5 only: A takes 0-1, B takes 2-5 (with a budget of 6),
  # then A ends.
  CPUQ_BUDGET=6 "$CPUQ" run --cores 2 -- sleep 1 & local a=$!
  wait_held 2
  CPUQ_BUDGET=6 "$CPUQ" run --cores 4 -- sleep 8 & local b=$!
  wait_held 6
  wait $a
  wait_held 4
  # Budget 4, all 4 held: a run confined to CPUs 0-1 sees tokens 0-1 free,
  # but must count the holds on 2-5 and wait.
  CPUQ_BUDGET=4 taskset -c 0,1 "$CPUQ" run --cores 2 --max-wait 2 -- true; local rc=$?
  kill $b 2>/dev/null; wait $b 2>/dev/null
  check "a run confined to 2 CPUs counts holds on every core and waits (exit $rc, want 75)" "[ $rc = 75 ]"
}

t_kill_holder() {
  setup kill-holder
  "$CPUQ" run --cores 9 -- sleep 30 & local holder=$!
  wait_held 9
  "$CPUQ" run --cores 9 -- true & local waiter=$!
  wait_waiters 1
  local t0; t0=$(now)
  pkill -9 -P $holder; kill -9 $holder
  wait $waiter; local rc=$?
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  echo "  waiter admitted ${dt}s after SIGKILL of the holder (cpuq and its command)"
  check "SIGKILL of the holder frees its cores at once" "[ $rc = 0 ] && python3 -c 'import sys; sys.exit(0 if $dt < 1.5 else 1)'"
}

t_kill_cpuq_only() {
  setup kill-cpuq-only
  "$CPUQ" run --cores 9 --label survivor -- sleep 4 & local holder=$!
  wait_held 9
  local t0; t0=$(now)
  kill -9 $holder
  sleep 1
  "$CPUQ" status
  local h1; h1=$(held)
  local gone; gone=$("$CPUQ" status --json --no-usage | grep -c '"holder_alive": false')
  "$CPUQ" run --cores 9 -- true; local rc=$?
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  echo "  after kill -9 of cpuq: held $h1; next run admitted ${dt}s after the kill (the sleep runs 4s)"
  check "the command keeps the cores after cpuq is SIGKILLed" "[ '$h1' = 9 ] && [ $gone = 1 ]"
  check "the cores free when the command ends" "[ $rc = 0 ] && python3 -c 'import sys; sys.exit(0 if 3.0 < $dt < 6 else 1)'"
}

t_leaked_descendant() {
  setup leaked-descendant
  "$CPUQ" run --cores 9 -- sh -c 'sleep 30 >/dev/null 2>&1 & exit 0'
  local h; h=$(held)
  local t0; t0=$(now)
  "$CPUQ" run --cores 9 -- true; local rc=$?
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  echo "  after the command exits leaving 'sleep 30' behind: held $h; next run took ${dt}s"
  check "a background descendant does not keep the cores" "[ '$h' = 0 ] && [ $rc = 0 ] && python3 -c 'import sys; sys.exit(0 if $dt < 1 else 1)'"
  pkill -f '^sleep 30$' 2>/dev/null
}

t_kill_waiter() {
  setup kill-waiter
  "$CPUQ" run --cores 9 -- sleep 2 & local holder=$!
  wait_held 9
  "$CPUQ" run --cores 9 -- true & local w1=$!
  wait_waiters 1
  "$CPUQ" run --cores 9 -- true & local w2=$!
  wait_waiters 2
  kill -9 $w1
  local t0; t0=$(now)
  wait $w2; local rc=$?
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  wait $holder
  echo "  second waiter admitted ${dt}s after the first was SIGKILLed (holder had <2s left)"
  check "a SIGKILLed waiter does not block the queue" "[ $rc = 0 ] && python3 -c 'import sys; sys.exit(0 if $dt < 3 else 1)'"
}

t_exit_status() {
  setup exit-status
  "$CPUQ" run -- sh -c 'exit 7'; local rc=$?
  check "exit 7 passes through as 7 (got $rc)" "[ $rc = 7 ]"
  "$CPUQ" run -- sh -c 'kill -TERM $$'; rc=$?
  check "a command killed by SIGTERM reports 143 (got $rc)" "[ $rc = 143 ]"
  local how
  how=$(python3 -c "
import subprocess
r = subprocess.run(['$CPUQ', 'run', '--', 'sh', '-c', 'kill -INT \$\$'])
print(r.returncode)")
  check "cpuq re-raises the command's SIGINT: the parent sees death by signal 2 (got $how)" "[ '$how' = -2 ]"
  "$CPUQ" run -- /nonexistent/cmd 2>/dev/null; rc=$?
  check "a missing command is 127 (got $rc)" "[ $rc = 127 ]"
}

t_direct_sigint() {
  setup direct-sigint
  local f=$T/ints
  dfl "$CPUQ" run -- sh -c "trap 'echo INT >>$f; exit 3' INT; while :; do sleep 0.05; done" & local p=$!
  wait_held 2
  sleep 0.3
  kill -INT $p
  wait $p; local rc=$?
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
    os.execv(cpuq, [cpuq, "run", "--", "sh", "-c",
        "trap 'echo INT >>%s' INT; i=0; while [ $i -lt 30 ]; do sleep 0.05; i=$((i+1)); done; exit 4" % f])
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

t_order() {
  setup order
  local f=$T/order
  "$CPUQ" run --cores 9 -- sleep 1.5 & local h=$!
  wait_held 9
  "$CPUQ" run --cores 9 --priority low -- sh -c "echo L >>$f" & wait_waiters 1
  "$CPUQ" run --cores 9 -- sh -c "echo A >>$f" & wait_waiters 2
  "$CPUQ" run --cores 9 -- sh -c "echo B >>$f" & wait_waiters 3
  "$CPUQ" run --cores 9 -- sh -c "echo C >>$f" & wait_waiters 4
  "$CPUQ" run --cores 9 --priority high -- sh -c "echo H >>$f" & wait_waiters 5
  "$CPUQ" status
  wait
  local got; got=$(tr -d '\n' <"$f")
  check "FIFO within a priority, high before normal before low (got $got)" "[ '$got' = HABCL ]"
}

t_aging() {
  setup aging "aging = 2"
  local f=$T/order
  "$CPUQ" run --cores 9 -- sleep 3 & local h=$!
  wait_held 9
  "$CPUQ" run --cores 9 --priority low -- sh -c "echo L >>$f" & wait_waiters 1
  sleep 2.5
  "$CPUQ" run --cores 9 -- sh -c "echo N >>$f" & wait_waiters 2
  wait
  local got; got=$(tr -d '\n' <"$f")
  check "a low waiter promoted by aging goes before a later normal one (got $got)" "[ '$got' = LN ]"
}

t_no_starvation() {
  setup no-starvation
  local f=$T/order
  "$CPUQ" run --cores 5 -- sleep 1.5 & wait_held 5
  "$CPUQ" run --cores 9 -- sh -c "echo big >>$f" & wait_waiters 1
  "$CPUQ" run --cores 2 -- sh -c "echo s1 >>$f" & wait_waiters 2
  "$CPUQ" run --cores 2 -- sh -c "echo s2 >>$f" & wait_waiters 3
  sleep 0.5
  local early; early=$(cat "$f" 2>/dev/null | tr '\n' ' ')
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  echo "  4 cores free while the 9-core head waits; ran early: '${early}'; order: $got"
  check "a 9-core head is served before later small jobs (no backfill)" "[ -z '$early' ] && [[ '$got' == 'big '* ]] && [ \$(wc -l <'$f') = 3 ]"
}

t_exclusive() {
  setup exclusive
  local f=$T/log
  "$CPUQ" run --cores 3 -- sh -c "sleep 1; echo held-end >>$f" & wait_held 3
  "$CPUQ" run --exclusive -- sh -c "echo excl-start >>$f; sleep 1; echo excl-end >>$f" & wait_waiters 1
  "$CPUQ" run --cores 1 -- sh -c "echo small >>$f" & wait_waiters 2
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "--exclusive waits for drain and blocks new work while it runs (got: $got)" "[ '$got' = 'held-end excl-start excl-end small ' ]"
}

t_nested() {
  setup nested
  local t0; t0=$(now)
  local out; out=$("$CPUQ" run --cores 9 -- sh -c "\"$CPUQ\" run --cores 9 -- sh -c 'echo nested \$CPUQ_CORES'")
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  check "a nested run starts at once within its parent's grant (${dt}s, '$out')" "[ '$out' = 'nested 9' ] && python3 -c 'import sys; sys.exit(0 if $dt < 1 else 1)'"
  out=$(CPUQ_TOKEN=0000099999 "$CPUQ" run --cores 2 -- sh -c 'echo $CPUQ_TOKEN')
  check "a stale CPUQ_TOKEN is ignored and the run queues normally (token now '$out')" "[ -n '$out' ] && [ '$out' != 0000099999 ]"
}

t_elastic() {
  setup elastic
  "$CPUQ" run --cores 7 -- sleep 2 & wait_held 7
  local t0; t0=$(now)
  local got; got=$("$CPUQ" run --cores 2-4 -- sh -c 'echo $CPUQ_CORES')
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  check "a 2-4 request starts at once beside 7 held of 9, with 2 (got $got in ${dt}s)" "[ '$got' = 2 ] && python3 -c 'import sys; sys.exit(0 if $dt < 1 else 1)'"
  local fixed; fixed=$("$CPUQ" run --cores 3 --max-wait 1 -- true; echo $?)
  check "a fixed 3 still waits for 3 (exit $fixed, want 75)" "[ '$fixed' = 75 ]"
  wait
  got=$("$CPUQ" run --cores 2-4 -- sh -c 'echo $CPUQ_CORES')
  check "on an idle machine a 2-4 request gets 4 (got $got)" "[ '$got' = 4 ]"
  got=$("$CPUQ" run --cores 1-20 -- sh -c 'echo $CPUQ_CORES')
  check "a maximum above the budget is clamped to it (got $got)" "[ '$got' = 9 ]"
}

t_reserve() {
  setup reserve
  local f=$T/log
  local stamp='python3 -c "import time; print(\"%.3f\" % time.time())"'
  "$CPUQ" run --cores 9 -- sleep 1.5 & wait_held 9
  "$CPUQ" run --cores 2-9 -- sh -c "echo wide \$CPUQ_CORES \$($stamp) >>$f; sleep 1" & wait_waiters 1
  "$CPUQ" run --cores 2-4 -- sh -c "echo next \$CPUQ_CORES \$($stamp) >>$f; sleep 1" & wait_waiters 2
  wait
  local got; got=$(sort "$f" | awk '{print $1, $2}' | tr '\n' ' ')
  local apart; apart=$(sort "$f" | awk '{print $3}' | python3 -c 'import sys; t = [float(x) for x in sys.stdin]; print("%.2f" % abs(t[0] - t[1]))')
  echo "  after the holder ends: $got; started ${apart}s apart"
  check "a wide request leaves the next waiter's minimum, and both start together" "[ '$got' = 'next 2 wide 7 ' ] && python3 -c 'import sys; sys.exit(0 if $apart < 0.5 else 1)'"
}

t_usage() {
  setup usage
  # --priority high leaves the class alone: at macOS utility QoS a busy
  # machine would give the spinner less than a CPU, and cpuq would rightly
  # measure that.
  "$CPUQ" run --cores 3 --priority high --label spin -- python3 -c 'import time
e = time.time() + 4
while time.time() < e: pass' &
  "$CPUQ" run --cores 2 --label idle -- sleep 4 &
  wait_held 5
  sleep 1
  local u; u=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
print(" ".join("%s=%.2f" % (h["label"], h["using"]) for h in sorted(s["holders"], key=lambda h: h["label"])))')
  wait
  echo "  measured use: $u"
  check "status measures use: a 1-CPU spinner granted 3 uses about 1, a sleeper about 0 ($u)" "python3 -c '
import sys
u = dict(p.split(\"=\") for p in \"$u\".split())
sys.exit(0 if 0.6 < float(u[\"spin\"]) < 1.3 and float(u[\"idle\"]) < 0.2 else 1)'"
}

t_lease() {
  setup lease
  local f=$T/log
  "$CPUQ" lease bench --label first -- sh -c "echo first >>$f; sleep 1; echo first-done >>$f" & wait_lease_holder bench
  "$CPUQ" lease bench --label second -- sh -c "echo second >>$f" & wait_lease_waiters bench 1
  "$CPUQ" lease bench --priority high --label urgent -- sh -c "echo urgent >>$f" & wait_lease_waiters bench 2
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "a named lease is one at a time, high before normal (got: $got)" "[ '$got' = 'first first-done urgent second ' ]"
  local env; env=$("$CPUQ" lease bench -- sh -c 'echo "$CPUQ_LEASES"')
  check "the command gets CPUQ_LEASES (got '$env')" "[[ '$env' == bench=* ]]"
  local t0; t0=$(now)
  local inner; inner=$("$CPUQ" lease bench -- "$CPUQ" lease bench -- sh -c 'echo inner')
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  check "a lease inside the same lease starts at once (${dt}s, '$inner')" "[ '$inner' = inner ] && python3 -c 'import sys; sys.exit(0 if $dt < 1 else 1)'"
  "$CPUQ" lease bench -- sleep 2 & wait_lease_holder bench
  "$CPUQ" lease bench --max-wait 1 -- true; local rc=$?
  check "--max-wait gives up on a held lease with 75 (got $rc)" "[ $rc = 75 ]"
  "$CPUQ" lease bench --cores 2 -- true 2>/dev/null; rc=$?
  check "run's options are refused for a lease (got $rc)" "[ $rc = 2 ]"
  local held; held=$(held)
  check "a lease holds no cores (held $held)" "[ '$held' = 0 ]"
  wait
  local g=$T/slots
  "$CPUQ" lease db --slots 2 -- sh -c "echo a >>$g; sleep 1" &
  "$CPUQ" lease db --slots 2 -- sh -c "echo b >>$g; sleep 1" &
  sleep 0.5
  local two; two=$(wc -l <"$g" | tr -d ' ')
  "$CPUQ" lease db --slots 2 --max-wait 0 -- true; rc=$?
  wait
  check "--slots 2 lets two hold at once and a third waits (holding: $two, third: $rc)" "[ '$two' = 2 ] && [ $rc = 75 ]"
}

t_lease_host() {
  setup lease-host
  # A stand-in ssh: drops its options and the host, and runs the remote
  # command here, so the "remote" cpuq shares this test's queue.
  local bin=$T/bin
  mkdir -p "$bin"
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\nexec sh -c "$*"\n' >"$bin/ssh"
  chmod +x "$bin/ssh"
  ln -sf "$CPUQ" "$bin/cpuq"
  local f=$T/log
  PATH="$bin:$PATH" "$CPUQ" lease bench --host far --label mac-gate -- sh -c "echo \"\$CPUQ_LEASES\" >$T/env; echo gate >>$f; sleep 1; echo gate-done >>$f" &
  wait_lease_holder bench
  "$CPUQ" lease bench --label far-local -- sh -c "echo far-local >>$f" & wait_lease_waiters bench 1
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "a lease held from another machine queues with that machine's own users (got: $got)" "[ '$got' = 'gate gate-done far-local ' ]"
  check "the command gets NAME@HOST=ID:PID in CPUQ_LEASES ($(cat $T/env))" "grep -q '^bench@far=[0-9]*:[0-9]*\$' $T/env"
  local t0; t0=$(now)
  local inner; inner=$(PATH="$bin:$PATH" "$CPUQ" lease bench --host far -- "$CPUQ" lease bench --host far -- sh -c 'echo inner')
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  check "a --host lease inside the same one starts at once (${dt}s, '$inner')" "[ '$inner' = inner ] && python3 -c 'import sys; sys.exit(0 if $dt < 2 else 1)'"
  PATH="$bin:$PATH" "$CPUQ" lease bench --host far -- sleep 30 & local p=$!
  wait_lease_holder bench
  t0=$(now)
  kill -9 $p
  "$CPUQ" lease bench --max-wait 5 -- true; local rc=$?
  dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  check "a killed --host holder frees the remote lease at once (exit $rc after ${dt}s)" "[ $rc = 0 ] && python3 -c 'import sys; sys.exit(0 if $dt < 2 else 1)'"
  pkill -f "$T" 2>/dev/null
  "$CPUQ" lease bench -- sleep 2 & wait_lease_holder bench
  PATH="$bin:$PATH" "$CPUQ" lease bench --host far --max-wait 1 -- true 2>/dev/null; rc=$?
  check "--max-wait on a --host lease gives 75 (got $rc)" "[ $rc = 75 ]"
  wait
}

t_wait() {
  setup wait
  "$CPUQ" run --cores 2 --label job:a -- sleep 1.5 &
  "$CPUQ" lease bench --label job:b -- sleep 0.5 &
  wait_held 2
  local t0; t0=$(now)
  "$CPUQ" wait --label 'job:*'; local rc=$?
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  check "cpuq wait --label 'job:*' returns when the last matching job ends (exit $rc after ${dt}s)" "[ $rc = 0 ] && python3 -c 'import sys; sys.exit(0 if 0.8 < $dt < 3 else 1)'"
  "$CPUQ" run --label long -- sleep 3 & wait_held 2
  "$CPUQ" wait --label long --max-wait 1; rc=$?
  check "cpuq wait --max-wait gives up with 75 (got $rc)" "[ $rc = 75 ]"
  wait
}

t_history() {
  setup history
  "$CPUQ" run --cores 2-4 --priority high --label h:build -- python3 -c 'import os, time
def spin():
    e = time.time() + 1
    while time.time() < e: pass
if os.fork() == 0: spin(); os._exit(0)
spin(); os.wait()'
  "$CPUQ" run --label h:fail -- sh -c 'exit 3'
  "$CPUQ" run --cores 9 --label h:hog -- sleep 1.5 & wait_held 9
  "$CPUQ" run --label h:impatient --max-wait 0 -- true 2>/dev/null
  wait
  "$CPUQ" run --label h:crash -- sleep 30 & local p=$!
  wait_held 2
  kill -9 $p; pkill -f '^sleep 30$' 2>/dev/null; sleep 0.2
  local got; got=$("$CPUQ" history --json | python3 -c 'import json, sys
j = {x["label"]: x for x in json.load(sys.stdin)}
b = j["h:build"]
print(b["state"], b["cores"], "%.1f" % (b["used"] or 0), j["h:fail"]["exit"], j["h:impatient"]["state"], j["h:crash"]["state"], j["h:hog"]["exit"])')
  echo "  history: $got"
  check "history records grant, use, exit, give-up and loss (got: $got)" "python3 -c '
import sys
f = \"$got\".split()
ok = f[0] == \"done\" and f[1] == \"4\" and 1.1 < float(f[2]) < 2.5 and f[3:] == [\"3\", \"gave_up\", \"lost\", \"0\"]
sys.exit(0 if ok else 1)'"
  local n; n=$("$CPUQ" history --label 'h:b*' --json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')
  check "history --label filters by prefix (got $n)" "[ '$n' = 1 ]"
  local text; text=$("$CPUQ" history)
  check "history prints a summary with the lost job" "[[ '$text' == *'5 jobs; waited'* && '$text' == *'1 lost'* ]]"
}

t_outside() {
  setup outside
  python3 -c 'import time
e = time.time() + 3
while time.time() < e: pass' & local stray=$!
  "$CPUQ" run --cores 2 --priority high --label inside -- python3 -c 'import time
e = time.time() + 3
while time.time() < e: pass' &
  wait_held 2
  sleep 0.5
  local got; got=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
print(" ".join(str(o["pid"]) for o in s["outside"]), "|", " ".join("%.1f" % h["using"] for h in s["holders"]))' )
  wait
  echo "  outside pids | holder use: $got (stray pid $stray)"
  check "status names an outside process and leaves the job's own out" "[[ ' ${got%%|*} ' == *' $stray '* ]] && python3 -c 'import sys; sys.exit(0 if float(\"${got##*| }\") > 0.6 else 1)'"
}

t_eta() {
  setup eta
  "$CPUQ" run --cores 9 --label build -- sleep 1
  "$CPUQ" run --cores 9 --label build -- sleep 1
  "$CPUQ" run --cores 9 --label build -- sleep 2 & wait_held 9
  "$CPUQ" run --cores 9 --label build -- true & wait_waiters 1
  "$CPUQ" run --cores 9 --label other -- true & wait_waiters 2
  local got; got=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys
print(" ".join("%.1f" % w["eta"] if w["eta"] is not None else "none" for w in json.load(sys.stdin)["waiters"]))')
  wait
  echo "  waiter ETAs: $got"
  check "waiters get ETAs from the history's typical run times (got $got)" "python3 -c '
import sys
a, b = (float(x) for x in \"$got\".split())
sys.exit(0 if 0 <= a <= 1.2 and 0.8 <= b - a <= 1.2 else 1)'"
}

t_status_host() {
  setup status-host
  local bin=$T/bin
  mkdir -p "$bin"
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\nexec sh -c "$*"\n' >"$bin/ssh"
  chmod +x "$bin/ssh"
  ln -sf "$CPUQ" "$bin/cpuq"
  "$CPUQ" run --cores 2 --label far:job -- sleep 2 & wait_held 2
  local got; got=$(PATH="$bin:$PATH" "$CPUQ" status --json --no-usage --host local --host far | python3 -c 'import json, sys
d = json.load(sys.stdin)
print(" ".join("%s:%d" % (h, d[h]["held"]) for h in sorted(d)))')
  check "status --host gives one JSON object keyed by host (got $got)" "[ '$got' = 'far:2 local:2' ]"
  local text; text=$(PATH="$bin:$PATH" "$CPUQ" status --no-usage --host far)
  check "status --host passes the host's own text through when piped" "[[ '$text' == *'in use 2'* ]]"
  "$CPUQ" status --watch >/dev/null 2>&1; local rc=$?
  check "status --watch refuses when not on a terminal (got $rc)" "[ $rc = 2 ]"
  wait
}

t_lost_seq() {
  setup lost-seq
  "$CPUQ" run --cores 5 --label holder -- sleep 2 & local h=$!
  wait_held 5
  "$CPUQ" run --cores 5 --label first -- true & local w=$!
  wait_waiters 1
  rm -f "$CPUQ_DIR/seq"
  "$CPUQ" run --cores 4 --label second -- sleep 1 & local x=$!
  wait_waiters 2 || wait_held 9
  local tickets; tickets=$("$CPUQ" status --json --no-usage | sed -n 's/^ *"ticket": \([0-9]*\),*/\1/p' | sort -n | tr '\n' ' ')
  local t0; t0=$(now)
  wait $h; wait $w; local rw=$?; wait $x; local rx=$?
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  echo "  tickets after seq was deleted: $tickets; the rest ran within ${dt}s"
  check "a lost seq never hands out a live ticket number" "[ \$(printf '%s\n' $tickets | sort -u | wc -l) = 3 ] && [ \$(printf '%s\n' $tickets | tail -1) = 3 ]"
  check "every run still completes (first $rw, second $rx)" "[ $rw = 0 ] && [ $rx = 0 ] && python3 -c 'import sys; sys.exit(0 if $dt < 5 else 1)'"
}

t_max_wait() {
  setup max-wait
  "$CPUQ" run --cores 9 -- sleep 3 & wait_held 9
  "$CPUQ" run --max-wait 1 -- true; local rc=$?
  wait
  check "--max-wait gives up with 75 (got $rc)" "[ $rc = 75 ]"
  "$CPUQ" run --max-wait 0 -- true; rc=$?
  check "--max-wait 0 takes free cores at once (got $rc)" "[ $rc = 0 ]"
}

t_waiters_cpu() {
  setup waiters-cpu "poll = 0.5"
  "$CPUQ" run --cores 9 -- sleep 12 & local h=$!
  wait_held 9
  local pids=() i
  for i in $(seq 100); do "$CPUQ" run --cores 1 -- true & pids+=($!); done
  local queued=no
  wait_waiters 100 && queued=yes
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
  sleep 5
  local c1; c1=$(cpu)
  local used; used=$(python3 -c "print('%.2f' % ($c1 - $c0))")
  echo "  100 waiters: CPU time ${c0}s after queueing, ${c1}s five seconds later: ${used}s used in 5s ($(python3 -c "print('%.2f' % ($used / 5 * 100))")% of one core)"
  kill $h 2>/dev/null
  local rc=0
  for p in "${pids[@]}"; do wait "$p" || rc=1; done
  check "100 waiters were queued while measured ($queued)" "[ $queued = yes ]"
  check "100 queued waiters use almost no CPU" "python3 -c 'import sys; sys.exit(0 if $used < 0.5 else 1)'"
  check "all 100 waiters ran" "[ $rc = 0 ]"
}

t_qos() {
  setup qos
  local outside low normal high excl
  outside=$("$CPUQ" qos)
  low=$("$CPUQ" run --priority low -- "$CPUQ" qos)
  normal=$("$CPUQ" run -- "$CPUQ" qos)
  high=$("$CPUQ" run --priority high -- "$CPUQ" qos)
  excl=$("$CPUQ" run --exclusive --priority low -- "$CPUQ" qos)
  none=$("$CPUQ" run --priority low --qos none -- "$CPUQ" qos)
  echo "  outside: $outside; low: $low; normal: $normal; high: $high; exclusive low: $excl; low --qos none: $none"
  if [ "$(uname)" = Darwin ]; then
    check "low runs at background QoS, normal at utility" "[ '$low' = background ] && [ '$normal' = utility ]"
  else
    check "low runs at nice 15, normal at nice 5" "[ '$low' = 'nice 15' ] && [ '$normal' = 'nice 5' ]"
  fi
  check "high, --exclusive and --qos none leave the class unchanged" "[ '$high' = '$outside' ] && [ '$excl' = '$outside' ] && [ '$none' = '$outside' ]"
}

t_jobserver() {
  setup jobserver
  local d=$T/make
  mkdir -p "$d/running"
  {
    printf 'J := 1 2 3 4 5 6 7 8 9 10\nall: $(addprefix job,$(J))\n'
    printf 'job%%:\n\t@touch running/$@; ls running | wc -l >> log; sleep 0.3; rm running/$@\n'
  } >"$d/Makefile"
  local make
  for make in /usr/bin/make $(command -v gmake); do
    local ver; ver=$("$make" --version | head -1)
    # GNU make 4.x lets a -j on its own command line override the jobserver
    # (it warns "-jN forced in submake"); make 3.81 keeps the jobserver for
    # a bare -j.
    local modes=('' '-j$CPUQ_CORES')
    case $ver in *" 3."*) modes+=('-j') ;; esac
    for mode in "${modes[@]}"; do
      rm -f "$d/log"
      (cd "$d" && "$CPUQ" run --cores 3 -- sh -c "$make -s $mode") || { bad "$make $mode failed"; continue; }
      local max; max=$(sort -n "$d/log" | tail -1 | tr -d ' ')
      local n; n=$(wc -l <"$d/log" | tr -d ' ')
      check "$ver, 'make $mode' under --cores 3: $n recipes, at most $max at once" "[ '$max' -le 3 ] && [ '$max' -ge 2 ] && [ $n = 10 ]"
    done
  done
  local mf; mf=$(MAKEFLAGS="k --no-print-directory -j8" "$CPUQ" run --cores 3 -- sh -c 'echo "$MAKEFLAGS"')
  echo "  MAKEFLAGS seen by the command: '$mf'"
  check "MAKEFLAGS keeps the caller's other flags" "[[ '$mf' == 'k --no-print-directory -j --jobserver-auth='*' --jobserver-fds='* ]]"
}

t_status() {
  setup status
  "$CPUQ" run --cores 4 --label build -- sleep 1.5 & wait_held 4
  "$CPUQ" run --cores 9 --label big -- true & wait_waiters 1
  "$CPUQ" status
  local s; s=$("$CPUQ" status)
  wait
  check "status shows the dir, the holder and the waiter" "[[ '$s' == *'dir     $CPUQ_DIR'* && '$s' == *build* && '$s' == *big* ]]"
  local j; j=$("$CPUQ" status --json | python3 -c 'import json, sys
s = json.load(sys.stdin)
print(s["schema"], s["version"] == sys.argv[1].split()[1], s["gate"]["state"], s["gate"]["load"], s["memory_pressure"])' "$("$CPUQ" --version)")
  check "status --json has schema 1, the version, a structured gate, and pressure off when unchecked (got '$j')" "[ '$j' = '1 True open None off' ]"
}

TESTS=${*:-budget affinity kill_holder kill_cpuq_only leaked_descendant kill_waiter exit_status direct_sigint terminal_sigint ignored_signals order aging no_starvation exclusive nested elastic reserve usage lease lease_host wait history outside eta status_host lost_seq max_wait waiters_cpu qos jobserver status}
for t in $TESTS; do "t_$t"; done
echo
echo "$PASS passed, $FAIL failed${FAILED:+:$FAILED}"
[ $FAIL = 0 ]
