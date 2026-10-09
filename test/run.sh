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
    echo "admit = cores" # the reservation model; t_measured tests the default
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
  # A distinctive duration, so the cleanup below can only match this one.
  "$CPUQ" run --cores 9 -- sh -c 'sleep 30.417 >/dev/null 2>&1 & exit 0'
  local h; h=$(held)
  local t0; t0=$(now)
  "$CPUQ" run --cores 9 -- true; local rc=$?
  local dt; dt=$(python3 -c "print('%.2f' % ($(now) - $t0))")
  echo "  after the command exits leaving 'sleep 30.417' behind: held $h; next run took ${dt}s"
  check "a background descendant does not keep the cores" "[ '$h' = 0 ] && [ $rc = 0 ] && python3 -c 'import sys; sys.exit(0 if $dt < 1 else 1)'"
  pkill -f '^sleep 30.417$' 2>/dev/null
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
  # Signal only once the trap is set: the shell ignores SIGINT for a moment
  # while it sets one, and on a slow runner the command can still be
  # starting long after cpuq holds its cores.
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
  setup no-starvation "backfill = off"
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
  check "with backfill off, a 9-core head is served before later small jobs" "[ -z '$early' ] && [[ '$got' == 'big '* ]] && [ \$(wc -l <'$f') = 3 ]"
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

t_exclusive_off() {
  setup exclusive-off "exclusive = off"
  # With exclusive runs off, --exclusive runs at once beside the work already
  # running, says why, and so does a lease taken --exclusive.
  local f=$T/log
  "$CPUQ" run --cores 3 -- sh -c "sleep 1; echo held-end >>$f" & wait_held 3
  "$CPUQ" run --exclusive --label race -- sh -c "echo excl-start >>$f" 2>"$T/err"
  "$CPUQ" lease bench --exclusive -- sh -c "echo lease-start >>$f" 2>"$T/err2"
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  local note; note=$("$CPUQ" status --no-usage | grep -c 'exclusive runs are off')
  check "exclusive = off: --exclusive runs alongside, and says so (got: $got)" "[ '$got' = 'excl-start lease-start held-end ' ] && grep -q 'race: --exclusive is off' '$T/err' && grep -q 'exclusive is off' '$T/err2' && [ $note = 1 ]"
}

t_exclusive_paused() {
  setup exclusive-paused
  # A job paused by hand runs nothing, so a quiet window opens beside it,
  # borrowing nothing (a budget under the CPUs, so the window takes more
  # cores than the budget); and an exclusive run started by hand opens
  # beside a job still running.
  export CPUQ_BUDGET=2
  "$CPUQ" run --cores 2 --label held -- sleep 30 & local h=$!
  wait_held 2
  "$CPUQ" pause held >/dev/null
  local t0; t0=$(now)
  "$CPUQ" run --exclusive --max-wait 4 --label window -- true 2>"$T/err"; local rc=$?
  local dt; dt=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  "$CPUQ" resume held >/dev/null
  "$CPUQ" run --exclusive --label forced -- true & local f=$!
  wait_waiters 1
  "$CPUQ" start forced >/dev/null
  local t1; t1=$(now)
  wait $f; local rf=$?
  local df; df=$(python3 -c "print('%.1f' % ($(now) - $t1))")
  "$CPUQ" stop held >/dev/null; wait $h 2>/dev/null
  check "an exclusive run opens beside a paused job (rc $rc, ${dt}s), borrowing nothing, and, started by hand, beside a running one (rc $rf, ${df}s)" "[ $rc = 0 ] && [ $rf = 0 ] && ! grep -q 'lent by' '$T/err' && python3 -c 'import sys; sys.exit(0 if $dt < 3 and $df < 3 else 1)'"
}

t_hold_gone() {
  setup hold-gone
  # A hold for someone who goes away ends, waiting or holding: when its stdin
  # closes, or when the heartbeats it had stop (a dropped connection).
  "$CPUQ" lease bench --hold --label first < <(sleep 30) >/dev/null & local h=$!
  wait_lease_holder bench
  mkfifo "$T/w"
  "$CPUQ" lease bench --hold --label waiter <"$T/w" >/dev/null 2>"$T/err" & local w=$!
  exec 7>"$T/w"
  wait_waiters 1
  local t0; t0=$(now)
  exec 7>&-
  wait $w; local rw=$?
  local dw; dw=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  kill $h 2>/dev/null; wait $h 2>/dev/null
  # Heartbeats, then silence with the pipe still open: the hold ends after
  # CPUQ_HOLD_QUIET seconds.
  mkfifo "$T/b"
  CPUQ_HOLD_QUIET=1 "$CPUQ" lease bench --hold --label quiet <"$T/b" >"$T/out" & local q=$!
  exec 6>"$T/b"
  echo >&6
  wait_lease_holder bench
  local t1; t1=$(now)
  wait $q; local rq=$?
  local dq; dq=$(python3 -c "print('%.1f' % ($(now) - $t1))")
  exec 6>&-
  check "a waiting hold whose stdin closes gives up (rc $rw, ${dw}s); a held one whose heartbeats stop ends (rc $rq, ${dq}s)" "[ $rw = 75 ] && [ $rq = 0 ] && grep -q 'has gone' '$T/err' && python3 -c 'import sys; sys.exit(0 if $dw < 3 and $dq < 4 else 1)'"
}

t_window_lend() {
  # window_lend: an exclusive hold whose owner idles lends the machine to a
  # waiting job, freezes it while the owner works, and thaws it once the
  # owner idles again. The owner's work here is one process tree
  # (CPUQ_WINDOW_OWNER): idle 6 s, busy 3 s, then idle.
  setup window-lend "admit = measured" "target = 4" "settle = 1" "window_lend = 2"
  local f=$T/ticks
  sh -c 'sleep 6; python3 -c "import time
e = time.time() + 3
while time.time() < e: pass"; sleep 60' & local owner=$!
  mkfifo "$T/in"
  CPUQ_WINDOW_OWNER=$owner "$CPUQ" lease bench --hold --exclusive --label win <"$T/in" >/dev/null 2>"$T/hold" & local h=$!
  exec 7>"$T/in"
  wait_lease_holder bench
  # Ticks every 0.1 s, 100 of them: about 10 s of work once lent the machine.
  "$CPUQ" run --cores 1 --label lent --max-wait 8 -- python3 -c 'import time
for _ in range(100):
    open("'"$f"'", "a").write("%.3f\n" % time.time()); time.sleep(0.1)' & local j=$!
  wait $j; local rc=$?
  local gap; gap=$(python3 -c 'import sys
t = [float(x) for x in open(sys.argv[1])]
print("%.1f" % max(b - a for a, b in zip(t, t[1:])))' "$f" 2>/dev/null || echo 0)
  # Its holder closes the hold's stdin, as the kit does: the hold ends.
  exec 7>&-
  wait $h
  kill $owner 2>/dev/null; wait $owner 2>/dev/null
  # Off, the same job waits the window out.
  setup window-lend-off "admit = measured" "target = 4" "settle = 1"
  "$CPUQ" lease bench --hold --exclusive --label win < <(sleep 30) >/dev/null & h=$!
  wait_lease_holder bench
  "$CPUQ" run --cores 1 --label lent --max-wait 4 -- true 2>/dev/null; local rc_off=$?
  kill $h 2>/dev/null; wait $h 2>/dev/null
  check "an idle window lends the machine (rc $rc), freezes the job while its owner works (longest pause ${gap}s) and thaws it; with window_lend off the job waits (rc $rc_off)" "[ $rc = 0 ] && [ $rc_off = 75 ] && python3 -c 'import sys; sys.exit(0 if 2 <= $gap <= 8 else 1)' && grep -q 'lending the machine' '$T/../window-lend/hold' && grep -q 'froze 1 job' '$T/../window-lend/hold'"
}

t_window_noise() {
  # A timing window measures the other work beside it: it warns while that
  # passes a CPU, says how much there was at the end, and keeps it in history.
  setup window-noise
  local i
  for i in 1 2; do python3 -c 'import time
e = time.time() + 5
while time.time() < e: pass' & done
  "$CPUQ" run --exclusive --label timed -- sleep 4 2>"$T/err"; local rc=$?
  wait
  local noise; noise=$("$CPUQ" history --json --label timed | python3 -c 'import json, sys; j = json.load(sys.stdin)[0]; print("%s %s" % (j.get("noise"), j.get("noise_peak")))')
  check "an exclusive run reports the work beside it (rc $rc, noise and peak $noise)" "[ $rc = 0 ] && grep -q 'work outside this timing window is using' '$T/err' && grep -q 'used .* CPUs on average' '$T/err' && python3 -c 'import sys; a, b = (float(x) for x in \"$noise\".split()); sys.exit(0 if a >= 1 and b >= 1.5 else 1)'"
}

t_cancel_exclusive() {
  setup cancel-exclusive
  # An exclusive waiter behind another waiter takes a cancel within seconds.
  "$CPUQ" run --cores 9 --label held -- sleep 30 & local h=$!
  wait_held 9
  "$CPUQ" run --cores 2 --label ahead -- true & local a=$!
  wait_waiters 1
  "$CPUQ" run --exclusive --label window -- true 2>/dev/null & local x=$!
  wait_waiters 2
  local t0; t0=$(now)
  "$CPUQ" cancel window >/dev/null
  wait $x; local rx=$?
  local dt; dt=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  "$CPUQ" stop held >/dev/null; wait $h $a 2>/dev/null
  check "an exclusive waiter behind another takes a cancel at once (rc $rx, ${dt}s)" "[ $rx = 75 ] && python3 -c 'import sys; sys.exit(0 if $dt < 4 else 1)'"
}

t_window_gap() {
  setup window-gap "window_gap = 5"
  # Just after a timing window ends, the next one waits behind other work;
  # without the gap it would go first (see t_exclusive).
  local f=$T/log
  "$CPUQ" run --exclusive --label w1 -- sh -c "echo w1 >>$f"
  "$CPUQ" run --cores 9 --label hold -- sleep 1.5 & wait_held 9
  "$CPUQ" run --exclusive --label w2 -- sh -c "echo w2 >>$f" & wait_waiters 1
  "$CPUQ" run --cores 2 --label small -- sh -c "echo small >>$f" & wait_waiters 2
  local shown; shown=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; print(" ".join(w["label"] for w in sorted(json.load(sys.stdin)["waiters"], key=lambda w: w["order"])))')
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "in the window_gap a waiting window goes behind other work, and status shows it so (got: $got; queue: $shown)" "[ '$got' = 'w1 small w2 ' ] && [ '$shown' = 'small w2' ]"
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
    # A second of CPU time each, however busy the machine is.
    e = time.process_time() + 1
    while time.process_time() < e: pass
if os.fork() == 0: spin(); os._exit(0)
spin(); os.wait()'
  "$CPUQ" run --label h:fail -- sh -c 'exit 3'
  "$CPUQ" run --cores 9 --label h:hog -- sleep 1.5 & wait_held 9
  "$CPUQ" run --label h:impatient --max-wait 0 -- true 2>/dev/null
  wait
  "$CPUQ" run --label h:crash -- sleep 30.583 & local p=$!
  wait_held 2
  kill -9 $p; pkill -f '^sleep 30.583$' 2>/dev/null; sleep 0.2
  local got; got=$("$CPUQ" history --json | python3 -c 'import json, sys
j = {x["label"]: x for x in json.load(sys.stdin)}
b = j["h:build"]
print(b["state"], b["cores"], "%.1f" % ((b["used"] or 0) * (b["ran"] or 0)), j["h:fail"]["exit"], j["h:impatient"]["state"], j["h:crash"]["state"], j["h:hog"]["exit"])')
  echo "  history: $got"
  check "history records grant, CPU time (both spinners, about 2 s), exit, give-up and loss (got: $got)" "python3 -c '
import sys
f = \"$got\".split()
ok = f[0] == \"done\" and f[1] == \"4\" and 1.7 < float(f[2]) < 2.6 and f[3:] == [\"3\", \"gave_up\", \"lost\", \"0\"]
sys.exit(0 if ok else 1)'"
  local n; n=$("$CPUQ" history --label 'h:b*' --json | python3 -c 'import json, sys; print(len(json.load(sys.stdin)))')
  check "history --label filters by prefix (got $n)" "[ '$n' = 1 ]"
  local text; text=$("$CPUQ" history)
  check "history prints a summary with the lost job" "[[ '$text' == *'5 jobs; waited'* && '$text' == *'1 lost'* ]]"
}

t_fixed_hint() {
  setup fixed_hint
  # A fixed request first in line while fewer cores are free says once what
  # would start it now; a range does not.
  "$CPUQ" run --cores 7 -- sleep 2 & wait_held 7
  local fixed range
  fixed=$("$CPUQ" run --cores 3 -- true 2>&1 | grep -c 'would start now')
  wait
  "$CPUQ" run --cores 7 -- sleep 1 & wait_held 7
  range=$("$CPUQ" run --cores 1-3 -- true 2>&1 | grep -c 'would start now')
  wait
  check "a blocking fixed request is told once to ask for a range (got $fixed, range $range)" "[ '$fixed' = 1 ] && [ '$range' = 0 ]"
}

t_backfill() {
  setup backfill "patience = 2"
  local f=$T/order
  # 7 of 9 held; the head wants 3, so 2 sit free.
  "$CPUQ" run --cores 7 -- sleep 4 & wait_held 7
  "$CPUQ" run --cores 3 --label head -- sh -c "echo head >>$f" & wait_waiters 1
  # Behind it, a 1-3 request with no run time to judge by goes ahead at once,
  # within the head's patience, taking the 2 free.
  local t0; t0=$(now)
  "$CPUQ" run --cores 1-3 --label small -- sh -c "echo small \$CPUQ_CORES >>$f"
  local dt; dt=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  # Past the head's patience, the next one waits in line.
  sleep 2.5
  "$CPUQ" run --cores 1 --label late -- sh -c "echo late >>$f" &
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  echo "  order: $got (small started after ${dt}s)"
  check "a small job goes ahead on the free cores, taking them all (got: $got)" "[[ '$got' == 'small 2 '* ]] && python3 -c 'import sys; sys.exit(0 if $dt < 3 else 1)'"
  # head and late start together once the holder ends, so their order in the
  # file is a race: history says whether late went ahead.
  local late_ahead; late_ahead=$(grep '"event":"started"' "$CPUQ_DIR/history.jsonl" | grep '"label":"late"' | grep -c '"ahead":true')
  check "after the head's patience, nobody goes ahead (late went ahead: $late_ahead)" "[ '$late_ahead' = 0 ]"
  local ahead; ahead=$("$CPUQ" history --json | python3 -c 'import json, sys; print(sum(1 for j in json.load(sys.stdin) if j["label"] == "small"))')
  check "history keeps the job that went ahead" "[ '$ahead' = 1 ]"
}

t_backfill_known() {
  setup backfill_known "patience = 0"
  local f=$T/order h=$CPUQ_DIR/history.jsonl
  mkdir -p "$CPUQ_DIR"
  # History's run times: hold 3 s, quick 0.2 s, slow a minute.
  ev() { printf '{"v":1,"event":"%s","id":"%s","t":%s,"pid":1,"label":"%s","cores":%s,"min":%s,"max":%s,"exit":0}\n' "$@" >>"$h"; }
  ev started 1 1 hold 7 7 7; ev ended 1 4 hold 7 7 7
  ev started 2 1 quick 1 1 1; ev ended 2 1.2 quick 1 1 1
  ev started 3 1 slow 1 1 1; ev ended 3 61 slow 1 1 1
  "$CPUQ" run --cores 7 --label hold -- sleep 3 & wait_held 7
  "$CPUQ" run --cores 3 --label head -- sh -c "echo head >>$f" & wait_waiters 1
  # With patience 0, only a job known to finish before the head can start
  # goes ahead, with all that is free; a slow one waits, and does not hold
  # up the quick one behind it.
  "$CPUQ" run --cores 1 --label slow -- sh -c "echo slow >>$f" & wait_waiters 2
  "$CPUQ" run --cores 1-2 --label quick -- sh -c "echo quick \$CPUQ_CORES >>$f" &
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  # Who went ahead, from history: head and slow start together once hold
  # ends, so their order in the file is a race.
  local ahead; ahead=$(grep '"event":"started"' "$h" | grep '"ahead":true' | sed 's/.*"label":"\([^"]*\)".*/\1/' | tr '\n' ' ')
  echo "  order: $got; went ahead: $ahead"
  check "a job known to be quick goes ahead with all that is free; a slow one waits (got: $got; ahead: $ahead)" "[[ '$got' == 'quick 2 '* ]] && [ '$ahead' = 'quick ' ]"
}

t_lend() {
  setup lend "lend_after = 2"
  # A budget under the CPU count, so there are CPUs to lend on.
  export CPUQ_BUDGET=2
  # The holder takes the whole budget and leaves it idle.
  "$CPUQ" run --cores 2 --label idle -- sleep 12 & local h=$!
  wait_held 2
  local t0; t0=$(now)
  local out; out=$("$CPUQ" run --cores 1 --label borrower -- "$CPUQ" qos 2>&1)
  local dt; dt=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  kill $h 2>/dev/null; wait $h 2>/dev/null
  local lent; lent=$(grep '"event":"started"' "$CPUQ_DIR/history.jsonl" | grep '"label":"borrower"' | sed -n 's/.*"lent":\([0-9]*\).*/\1/p')
  echo "  borrower started after ${dt}s, lent $lent; said: $(echo "$out" | grep lent)"
  check "a core a holder leaves idle is lent to the head (after ${dt}s, lent $lent)" "[ '$lent' = 1 ] && python3 -c 'import sys; sys.exit(0 if $dt < 9 else 1)'"
  local qos; qos=$(echo "$out" | tail -1)
  if [ "$(uname)" = Darwin ]; then
    # Background QoS would hold it to the efficiency cores for its whole run.
    check "on macOS a borrower keeps its class, so it can use the performance cores (got: $qos)" "[ '$qos' = '$("$CPUQ" qos)' ]"
  else
    check "a borrower runs at a lower priority, so the lender comes first (got: $qos)" "[ '$qos' = 'nice 19' ] || [ '$qos' = 'nice 15' ] || [ '$qos' = 'nice 10' ]"
  fi
  export CPUQ_BUDGET=9
}

t_config_reload() {
  setup config_reload "budget = 9"
  # A waiter takes up a budget raised while it waits (from the config, not
  # CPUQ_BUDGET, which the environment would fix for the run).
  unset CPUQ_BUDGET
  "$CPUQ" run --cores 9 -- sleep 6 & local h=$!
  wait_held 9
  local t0; t0=$(now)
  "$CPUQ" run --cores 2 -- true & local w=$!
  wait_waiters 1
  sleep 0.6
  echo "budget = 11" >>"$CPUQ_CONFIG"
  wait $w
  local dt; dt=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  kill $h 2>/dev/null; wait $h 2>/dev/null
  export CPUQ_BUDGET=9
  echo "  the waiter started after ${dt}s (the holder runs 6s)"
  check "a waiter takes up a budget raised in the config while it waits (${dt}s)" "python3 -c 'import sys; sys.exit(0 if $dt < 4 else 1)'"
}

t_lease_host_hold() {
  setup lease-host-hold
  local bin=$T/bin
  mkdir -p "$bin"
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\nexec sh -c "$*"\n' >"$bin/ssh"
  chmod +x "$bin/ssh"
  ln -sf "$CPUQ" "$bin/cpuq"
  # A script holds the lease from the middle of its run: a coprocess that
  # prints the CPUQ_LEASES entry once granted and holds until closed.
  local out
  out=$(PATH="$bin:$PATH" /bin/bash -c '
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
    CPUQ_LEASES= "$1" lease bench --max-wait 1 -- true 2>/dev/null; echo "other $?"
    exec 8>&-; wait $hold
    CPUQ_LEASES= "$1" lease bench --max-wait 3 -- true; echo "after $?"
    rm -rf "$d"
  ' _ "$CPUQ")
  echo "$out" | sed 's/^/  /'
  check "--hold --host prints the held entry" "echo '$out' | grep -qE '^held bench@far bench@far=[0-9]+:[0-9]+\$'"
  check "inside the hold, the lease starts at once, and holding it again holds nothing" "echo '$out' | grep -qx nested && echo '$out' | grep -qE '^again held bench@far bench@far='"
  check "others wait while it is held, and get it once it is closed" "echo '$out' | grep -qx 'other 75' && echo '$out' | grep -qx 'after 0'"
}

t_last_words() {
  setup last-words
  local bin=$T/bin
  mkdir -p "$bin"
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\nexec sh -c "$*"\n' >"$bin/ssh"
  chmod +x "$bin/ssh"
  ln -sf "$CPUQ" "$bin/cpuq"
  "$CPUQ" run --cores 9 --label holder -- sleep 30.731 & local holder=$!
  wait_held 9
  # Killed while it waits, a run gave up.
  "$CPUQ" run --cores 2 --label waiter -- true & local w=$!
  wait_waiters 1
  kill -TERM $w; wait $w; local rc_w=$?
  # Killed while they hold, a hold here and one on a host ended by the signal.
  mkfifo "$T/in1" "$T/in2"
  "$CPUQ" lease near --hold --label near <"$T/in1" >/dev/null & local h1=$!
  exec 7>"$T/in1"
  wait_lease_holder near
  kill -HUP $h1; wait $h1; local rc_h1=$?
  exec 7>&-
  PATH="$bin:$PATH" "$CPUQ" lease far --host far --hold --label far <"$T/in2" >/dev/null & local h2=$!
  exec 6>"$T/in2"
  wait_lease_holder far
  kill -TERM $h2; wait $h2; local rc_h2=$?
  exec 6>&-
  # The kit's release: close the hold's stdin, then kill it at once.
  local n
  for n in 1 2 3 4 5; do
    mkfifo "$T/k$n"
    if [ $((n % 2)) = 1 ]; then
      "$CPUQ" lease near --hold --label kit <"$T/k$n" >/dev/null & h1=$!
    else
      PATH="$bin:$PATH" "$CPUQ" lease far --host far --hold --label kit@far <"$T/k$n" >/dev/null & h1=$!
    fi
    exec 7>"$T/k$n"
    if [ $((n % 2)) = 1 ]; then wait_lease_holder near; else wait_lease_holder far; fi
    exec 7>&-; kill $h1 2>/dev/null; wait $h1 2>/dev/null
  done
  kill $holder; wait $holder
  local i=0
  while "$CPUQ" status --json --no-usage | grep -q '"holders": \[$'; do i=$((i + 1)); [ $i -gt 50 ] && break; sleep 0.1; done
  local got; got=$("$CPUQ" history --json | python3 -c 'import json, sys
print(" ".join("%s%s:%s:%s" % (j["label"], "@" + j["host"] if j["host"] else "", j["state"], j["signal"]) for j in sorted(json.load(sys.stdin), key=lambda j: j["queued"])))')
  echo "  exits $rc_w $rc_h1 $rc_h2; history: $got"
  check "killed while waiting, a run exits by the signal and gave up (not lost)" "[ $rc_w = 143 ] && [[ '$got' == *'waiter:gave_up:15'* ]]"
  check "killed while held, a --hold lease ends by the signal, here and on a host" "[ $rc_h1 = 129 ] && [ $rc_h2 = 143 ] && [[ '$got' == *'near:done:1 '* && '$got' == *'far@far:done:15'* ]]"
  local kit; kit=$(echo "$got" | tr ' ' '\n' | grep -cE '^kit(@far@far)?:done:')
  check "closed and killed at once (the kit's release), a hold still ends, 5 of 5 (got $kit)" "[ '$kit' = 5 ]"
  check "nothing is lost" "[[ '$got' != *lost* ]]"
}

t_measured() {
  # Measured admission, the default: a job counts at what it uses once it has
  # run a second (settle), so idle holders leave room and busy ones do not.
  setup measured "admit = measured" "target = 2" "settle = 1"
  local f=$T/order h=$CPUQ_DIR/history.jsonl
  mkdir -p "$CPUQ_DIR"
  # Two holders of 4 cores each that sleep: they settle near 0.
  "$CPUQ" run --cores 4 --label idle1 -- sleep 5 & local i1=$!
  "$CPUQ" run --cores 4 --label idle2 -- sleep 5 & local i2=$!
  local t0; t0=$(now)
  sleep 2.5
  "$CPUQ" run --cores 1 --label small -- true; local rc=$?
  local dt; dt=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  wait $i1 $i2
  check "beside 8 held but idle cores a job starts at once (after ${dt}s, rc $rc)" "[ $rc = 0 ] && python3 -c 'import sys; sys.exit(0 if $dt < 4.5 else 1)'"
  # A holder keeping 2 CPUs busy fills the target: the next waits for it.
  "$CPUQ" run --cores 2 --label spin -- python3 -c 'import os, time
e = time.time() + 3
if os.fork() == 0:
    while time.time() < e: pass
    os._exit(0)
while time.time() < e: pass
os.wait()
open("'"$f"'", "a").write("spin-done\n")' & local s=$!
  sleep 1.5
  "$CPUQ" run --cores 1 --label after -- sh -c "echo after >>$f"
  wait $s
  check "a job waits while busy holders fill the target (got: $(tr '\n' ' ' <"$f"))" "[ \"\$(tr '\n' ' ' <'$f')\" = 'spin-done after ' ]"
  # No --cores: the label's history picks the count (75th percentile + 0.3).
  setup measured-sized "admit = measured" "target = 10" "settle = 1"
  h=$CPUQ_DIR/history.jsonl
  mkdir -p "$CPUQ_DIR"
  ev() { printf '{"v":1,"event":"%s","id":"%s","t":%s,"pid":1,"label":"%s","cores":%s,"cpu":%s,"exit":0}\n' "$@" >>"$h"; }
  for n in 1 2 3; do ev started $n 1 sized 4 0; ev ended $n 11 sized 4 27; done
  local got; got=$("$CPUQ" run --label sized -- sh -c 'echo $CPUQ_CORES')
  # 3 from history, at most half the CPUs (a CI runner may have only 3 or 4).
  local want; want=$(python3 -c 'import os; print(min(3, max(os.cpu_count() // 2, 1)))')
  check "without --cores a label's history picks the cores (got $got, want $want)" "[ '$got' = '$want' ]"
}

t_measured_backfill() {
  # Measured admission: a job behind the head starts ahead of it only while
  # backfill is on. An idle holder settles near 0; the head (4 cores) needs
  # more than the target of 2 leaves; a 1-core job fits beside it.
  local mode rc out=""
  for mode in on off; do
    setup "measured-backfill-$mode" "admit = measured" "target = 2" "settle = 1" "backfill = $mode"
    "$CPUQ" run --cores 1 --label idle -- sleep 4 & local i=$!
    sleep 1.5
    "$CPUQ" run --cores 4 --label big -- true & local b=$!
    wait_waiters 1
    "$CPUQ" run --cores 1 --max-wait 1 --label tiny -- true 2>/dev/null; rc=$?
    out="$out$mode:$rc "
    wait $i $b
  done
  check "behind the head a job starts ahead with backfill on, not off (got $out)" "[ '$out' = 'on:0 off:75 ' ]"
}

t_eta_measured() {
  # Under measured admission ETAs count CPUs of use against the target, not
  # cores against the budget: two 2-CPU jobs on a target of 2 go one at a time.
  setup eta-measured "admit = measured" "target = 2" "settle = 1"
  local h=$CPUQ_DIR/history.jsonl
  mkdir -p "$CPUQ_DIR"
  ev() { printf '{"v":1,"event":"%s","id":"%s","t":%s,"pid":1,"label":"%s","cores":%s,"cpu":%s,"exit":0}\n' "$@" >>"$h"; }
  for n in 1 2 3; do ev started $n 1 build 2 0; ev ended $n 2 build 2 2; done
  "$CPUQ" run --cores 2 --label build -- sleep 2 & wait_held 2
  "$CPUQ" run --cores 2 --label build -- true & wait_waiters 1
  "$CPUQ" run --cores 2 --label build -- true & wait_waiters 2
  local got; got=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys
print(" ".join("%.1f" % w["eta"] if w["eta"] is not None else "none" for w in json.load(sys.stdin)["waiters"]))')
  wait
  check "measured ETAs: one 2-CPU job after another on a target of 2 (got $got)" "python3 -c '
import sys
a, b = (float(x) for x in \"$got\".split())
sys.exit(0 if 0 <= a <= 1.5 and 0.8 <= b - a <= 1.5 else 1)'"
}

t_backfill_exclusive() {
  setup backfill_exclusive
  local f=$T/order h=$CPUQ_DIR/history.jsonl
  mkdir -p "$CPUQ_DIR"
  ev() { printf '{"v":1,"event":"%s","id":"%s","t":%s,"pid":1,"label":"%s","cores":%s,"min":%s,"max":%s,"exit":0}\n' "$@" >>"$h"; }
  # History: hold runs 4 s, quick 0.2 s; unknown has no history.
  ev started 1 1 hold 3 3 3; ev ended 1 5 hold 3 3 3
  ev started 2 1 quick 1 1 1; ev ended 2 1.2 quick 1 1 1
  "$CPUQ" run --cores 3 --label hold -- sleep 4 & wait_held 3
  "$CPUQ" run --exclusive --label timing -- sh -c "echo timing >>$f" & wait_waiters 1
  # Behind an exclusive head, only a job known to end before the machine
  # drains uses the free cores meanwhile; one with no history waits.
  "$CPUQ" run --cores 1 --label unknown -- sh -c "echo unknown >>$f" & wait_waiters 2
  "$CPUQ" run --cores 1 --label quick -- sh -c "echo quick >>$f" &
  wait
  local got; got=$(tr '\n' ' ' <"$f")
  check "behind an exclusive head a job known to be quick uses the free cores; an unknown one waits for the window (got: $got)" "[ '$got' = 'quick timing unknown ' ]"
}

t_lease_exclusive() {
  setup lease-exclusive
  local bin=$T/bin f=$T/log
  mkdir -p "$bin"
  printf '#!/bin/sh\nwhile [ "$1" = -o ]; do shift 2; done\nshift\nexec sh -c "$*"\n' >"$bin/ssh"
  chmod +x "$bin/ssh"
  ln -sf "$CPUQ" "$bin/cpuq"
  # A run holds 2 cores; the exclusive lease waits for it to end, then holds
  # the machine: a run started meanwhile waits for the lease, and a run
  # inside the lease's command starts at once.
  "$CPUQ" run --cores 9 --label busy -- sh -c "sleep 1.5; echo busy-done >>$f" & local b=$!
  wait_held 9
  # A high-priority run queued first still goes after the timing window.
  "$CPUQ" run --cores 2 --priority high --label early -- sh -c "echo early >>$f" & local e=$!
  wait_waiters 1
  "$CPUQ" lease bench --exclusive --label timing -- sh -c "echo timing >>$f; \"$CPUQ\" run --cores 1 -- sh -c 'echo inner >>$f'; sleep 1.5; echo timing-done >>$f" & local l=$!
  wait_lease_holder bench
  "$CPUQ" run --cores 1 --label late -- sh -c "echo late >>$f" & local r=$!
  wait $b $l $r $e
  local got; got=$(tr '\n' ' ' <"$f")
  check "an exclusive lease goes next once running work drains, ahead of earlier waiters, and nothing else runs until it ends, but its own runs do (got: $got)" "[ '$got' = 'busy-done timing inner timing-done early late ' ] || [ '$got' = 'busy-done timing inner timing-done late early ' ]"
  # Held with --hold on a host: other runs there wait; closed and killed at
  # once, it frees the machine and leaves nothing lost.
  mkfifo "$T/in"
  PATH="$bin:$PATH" "$CPUQ" lease bench --host far --hold --exclusive --label kit <"$T/in" >/dev/null & local h=$!
  exec 7>"$T/in"
  wait_held 9
  "$CPUQ" run --cores 1 --max-wait 1 -- true 2>/dev/null; local rc=$?
  exec 7>&-; kill $h 2>/dev/null; wait $h 2>/dev/null
  "$CPUQ" run --cores 1 --max-wait 3 -- true; local after=$?
  local lost; lost=$("$CPUQ" history --json | python3 -c 'import json, sys; print(sum(1 for j in json.load(sys.stdin) if j["state"] == "lost"))')
  check "while an exclusive --hold holds the machine others wait (rc $rc); after it, they run (rc $after); nothing lost ($lost)" "[ $rc = 75 ] && [ $after = 0 ] && [ '$lost' = 0 ]"
  # The holder's own work over ssh, with its CPUQ_LEASES entry passed along,
  # runs inside the window at once; without it, it waits.
  mkfifo "$T/in2" "$T/out2"
  PATH="$bin:$PATH" "$CPUQ" lease bench --host far --hold --exclusive --label kit <"$T/in2" >"$T/out2" & h=$!
  exec 6>"$T/in2"
  local word name entry
  read -r word name entry <"$T/out2"
  local inside; inside=$(CPUQ_LEASES="$entry" "$CPUQ" run --cores 2-3 --max-wait 2 -- sh -c 'echo "$CPUQ_CORES"'); local rc_in=$?
  "$CPUQ" run --cores 1 --max-wait 1 -- true 2>/dev/null; local rc_out=$?
  exec 6>&-; kill $h 2>/dev/null; wait $h 2>/dev/null
  check "inside an exclusive lease (its entry passed along) a run starts at once (rc $rc_in, cores '$inside'); outside it waits (rc $rc_out)" "[ $rc_in = 0 ] && [ '$inside' = 3 ] && [ $rc_out = 75 ]"
}

t_controls() {
  setup controls
  local f=$T/order
  # first: b moves ahead of a.
  # The holder outlasts the waiters' next look (every 2 s behind the head).
  "$CPUQ" run --cores 9 -- sleep 5 & wait_held 9
  "$CPUQ" run --cores 2 --label ctl:a -- sh -c "echo a >>$f" & wait_waiters 1
  "$CPUQ" run --cores 2 --label ctl:b -- sh -c "echo b >>$f" & wait_waiters 2
  "$CPUQ" first ctl:b >/dev/null
  wait
  # Both fit once the holder ends, so their lines in the file race; the
  # admission lock orders their starts, which history records.
  local order; order=$(grep '"event":"started"' "$CPUQ_DIR/history.jsonl" | grep '"label":"ctl:[ab]"' | python3 -c 'import json, sys
print(" ".join(e["label"][4:] for e in sorted((json.loads(l) for l in sys.stdin), key=lambda e: e["t"])))')
  check "first moves a waiter ahead (started: $order)" "[ '$order' = 'b a' ]"
  # start: past a full budget, at once; cancel: out of the queue with 75.
  "$CPUQ" run --cores 9 -- sleep 6 & local h=$!
  wait_held 9
  local t0; t0=$(now)
  "$CPUQ" run --cores 2 --label ctl:now -- true & local s=$!
  "$CPUQ" run --cores 2 --label ctl:never -- true 2>/dev/null & local c=$!
  wait_waiters 2
  "$CPUQ" start ctl:now >/dev/null; "$CPUQ" cancel ctl:never >/dev/null
  wait $s; local rs=$?; wait $c; local rc=$?
  local dt; dt=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  kill $h 2>/dev/null; wait $h 2>/dev/null
  local forced; forced=$(grep '"event":"started"' "$CPUQ_DIR/history.jsonl" | grep '"label":"ctl:now"' | grep -c '"forced":true')
  check "start runs a waiter past a full budget at once, cancel takes one out (start $rs, cancel $rc, ${dt}s, forced $forced)" "[ $rs = 0 ] && [ $rc = 75 ] && [ '$forced' = 1 ] && python3 -c 'import sys; sys.exit(0 if $dt < 4 else 1)'"
  # pause and resume a running job's whole tree; stop ends it.
  "$CPUQ" run --cores 1 --label ctl:spin -- sh -c 'sleep 20' & local p=$!
  wait_held 1
  "$CPUQ" pause ctl:spin >/dev/null
  # The job's own sleep: the command child its cpuq recorded.
  local child; child=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; print(json.load(sys.stdin)["holders"][0]["child"])')
  # A stop is delivered asynchronously: give it a moment to show.
  local paused i=0
  while paused=$(ps -o stat= -p "$child" | tr -d ' '); [[ "$paused" != T* ]] && [ $i -lt 20 ]; do i=$((i + 1)); sleep 0.1; done
  local flag; flag=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; print(json.load(sys.stdin)["holders"][0]["paused"])')
  "$CPUQ" resume ctl:spin >/dev/null
  local resumed; i=0
  while resumed=$(ps -o stat= -p "$child" | tr -d ' '); [[ "$resumed" == T* ]] && [ $i -lt 20 ]; do i=$((i + 1)); sleep 0.1; done
  "$CPUQ" stop ctl:spin >/dev/null
  wait $p; local rp=$?
  sleep 0.3
  local left; left=$(ps -o pid= -p "$child" | tr -d ' ')
  check "stop ends the job's whole tree, leaving nothing behind (left: '$left')" "[ -z '$left' ]"
  echo "  sleep while paused: $paused, after resume: $resumed; status paused: $flag; stopped with $rp"
  check "pause stops the job's tree and status says so; resume continues it; stop ends it" "[[ '$paused' == T* ]] && [[ '$resumed' != T* ]] && [ '$flag' = True ] && [ $rp != 0 ]"
  # Killed while paused, a job leaves no marker behind.
  "$CPUQ" run --cores 1 --label ctl:nap -- sleep 30.917 & p=$!
  wait_held 1
  "$CPUQ" pause ctl:nap >/dev/null
  child=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; print(json.load(sys.stdin)["holders"][0]["child"])')
  kill -9 "$child"
  wait $p
  local litter; litter=$(ls "$CPUQ_DIR" | grep -E '^(control|paused)-' | tr '\n' ' ')
  check "no hand-given order or pause marker outlives its job (left: '$litter')" "[ -z '$litter' ]"
}

t_right_size() {
  setup right_size
  local h=$CPUQ_DIR/history.jsonl
  mkdir -p "$CPUQ_DIR"
  # History: "serial" uses about 0.8 of a core, "wide" about 3.5.
  local i
  for i in 1 2 3; do
    printf '{"v":1,"event":"started","id":"s%s","t":1,"pid":1,"label":"serial","cores":4}\n{"v":1,"event":"ended","id":"s%s","t":11,"pid":1,"label":"serial","cores":4,"exit":0,"cpu":8}\n' $i $i >>"$h"
    printf '{"v":1,"event":"started","id":"w%s","t":1,"pid":1,"label":"wide","cores":4}\n{"v":1,"event":"ended","id":"w%s","t":11,"pid":1,"label":"wide","cores":4,"exit":0,"cpu":35}\n' $i $i >>"$h"
  done
  local serial wide fixed
  serial=$("$CPUQ" run --cores 1-4 --label serial -- sh -c 'echo $CPUQ_CORES' 2>/dev/null)
  wide=$("$CPUQ" run --cores 1-4 --label wide -- sh -c 'echo $CPUQ_CORES' 2>/dev/null)
  fixed=$("$CPUQ" run --cores 3 --label serial -- sh -c 'echo $CPUQ_CORES' 2>/dev/null)
  check "a range is capped near its label's measured use (serial $serial, wide $wide), a fixed count stands ($fixed)" "[ '$serial' = 1 ] && [ '$wide' = 4 ] && [ '$fixed' = 3 ]"
}

t_zombie() {
  setup zombie
  # A child spins a second, then waits as a zombie until its parent reaps
  # it. Its CPU must count while it is a zombie: missed, the parent's
  # reaped-children time leaps by the child's whole second at the reap.
  "$CPUQ" run --cores 1 --label zombie -- python3 -c 'import os, time
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
  echo "  zombie: highest active $top"
  check "a reaped zombie's CPU does not leap into its parent's (got $top)" "python3 -c 'import sys; sys.exit(0 if $top < 1.6 else 1)'"
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
  check "status names an outside process and leaves the job's own out" "[[ ' ${got%%|*} ' == *' $stray '* ]] && python3 -c 'import sys; sys.exit(0 if float(\"${got##*| }\") > 0.4 else 1)'"
}

t_eta() {
  setup eta
  "$CPUQ" run --cores 9 --label build -- sleep 1
  "$CPUQ" run --cores 9 --label build -- sleep 1
  # Runs of 1 s are recorded a little long (the end is seen within 0.1 s) and
  # longer on a slow runner: the bounds allow for it.
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
sys.exit(0 if 0 <= a <= 1.5 and 0.8 <= b - a <= 1.5 else 1)'"
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
  # second fits in the 4 free and goes ahead of first (backfill).
  "$CPUQ" run --cores 4 --label second -- sleep 1 & local x=$!
  wait_held 9
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
    check "low runs at background QoS; normal keeps the class, so it can use the performance cores" "[ '$low' = background ] && [ '$normal' = '$outside' ]"
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

t_long_command() {
  setup long-command
  # A command line over 1 KB (an inline script): its record must still carry
  # the child pid, which pause, stop and lending all go by.
  local pad; pad=$(printf 'x%.0s' $(seq 2000))
  "$CPUQ" run --cores 1 --label long -- sh -c "sleep 30.239 # $pad" & local p=$!
  wait_held 1
  local child; child=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; print(json.load(sys.stdin)["holders"][0]["child"])')
  "$CPUQ" stop long >/dev/null; wait $p
  check "a job whose command is over 1 KB still has its child pid recorded (got $child)" "[ '$child' -gt 0 ]"
}

t_max_memory() {
  setup max-memory "max_memory = 300M"
  # A job that keeps allocating (50 MB every 0.2 s, up to 2.5 GB) is stopped
  # once its processes pass 300 MB; a small one runs as usual.
  "$CPUQ" run --cores 1 --label small -- true; local small=$?
  local t0; t0=$(now)
  "$CPUQ" run --cores 1 --label hog -- python3 -c '
import time
a = []
for _ in range(50):
    a.append(b"x" * (50 << 20))
    time.sleep(0.2)
' 2>"$T/err"; local rc=$?
  local dt; dt=$(python3 -c "print('%.1f' % ($(now) - $t0))")
  local got; got=$("$CPUQ" history --json | python3 -c 'import json, sys
j = {x["label"]: x for x in json.load(sys.stdin)}
h = j["hog"]
print(h["signal"], "%.1f" % ((h.get("memory") or 0) / 2**30), j["small"]["exit"])')
  echo "  hog: exit $rc after ${dt}s; history: $got; $(cat "$T/err")"
  check "a job over max_memory is stopped and recorded so; a small one is not (rc $rc, $got)" "[ $small = 0 ] && [ $rc = 143 ] && [[ '$got' == '15 0.'* ]] && [[ '$got' == *' 0' ]] && grep -q 'over max_memory' '$T/err'"
}

t_peak_memory() {
  setup peak-memory
  # Two processes holding 150 MB each for 1.5 s: the peak counts them together.
  # A quick one is too quick to look at; wait4's maxrss still gives its peak.
  # A command that ends at once frees its cores at once.
  "$CPUQ" run --cores 1 --label pair -- bash -c '
p() { python3 -c "import time; b = bytearray(150 << 20); b[::4096] = b\"x\" * len(b[::4096]); time.sleep(1.5)"; }
p & p & wait'
  "$CPUQ" run --cores 1 --label quick -- python3 -c 'b = bytearray(100 << 20); b[::4096] = b"x" * len(b[::4096])'
  "$CPUQ" run --cores 1 --label instant -- true
  local got; got=$("$CPUQ" history --json | python3 -c 'import json, sys
j = {x["label"]: x for x in json.load(sys.stdin)}
print(j["pair"].get("peak", 0) >> 20, j["quick"].get("peak", 0) >> 20, "%.2f" % j["instant"]["ran"])')
  local pair quick ran; read -r pair quick ran <<<"$got"
  check "history keeps each job's peak memory, its processes together (pair ${pair}M, quick ${quick}M, true ran ${ran}s)" "[ $pair -ge 280 ] && [ $quick -ge 95 ] && python3 -c 'import sys; sys.exit(0 if $ran < 0.5 else 1)'"
}

t_min_available() {
  setup min-available "min_available = 1000000G"
  "$CPUQ" run --cores 1 --max-wait 1 -- true 2>/dev/null; local rc=$?
  local state; state=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; g = json.load(sys.stdin)["gate"]; print(g["state"], "with-available" if (g.get("available") or 0) > 0 else "no-available")')
  setup min-available-low "min_available = 1M"
  "$CPUQ" run --cores 1 --max-wait 1 -- true; local rc2=$?
  check "under min_available nothing starts (rc $rc, gate $state); above it, it does (rc $rc2)" "[ $rc = 75 ] && [ '$state' = 'low_memory with-available' ] && [ $rc2 = 0 ]"
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

TESTS=${*:-budget affinity kill_holder kill_cpuq_only leaked_descendant kill_waiter exit_status direct_sigint terminal_sigint ignored_signals order aging no_starvation exclusive exclusive_off exclusive_paused cancel_exclusive window_gap window_lend window_noise nested elastic reserve usage lease lease_host lease_host_hold hold_gone last_words measured measured_backfill eta_measured backfill_exclusive lease_exclusive wait history zombie fixed_hint backfill backfill_known lend config_reload controls right_size outside eta status_host lost_seq max_wait waiters_cpu qos jobserver long_command max_memory peak_memory min_available status}
for t in $TESTS; do "t_$t"; done
echo
echo "$PASS passed, $FAIL failed${FAILED:+:$FAILED}"
[ $FAIL = 0 ]
