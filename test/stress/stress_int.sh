#!/bin/bash
# stress_int.sh DIR N: kill -INT a `cpuq run` at random moments; report hangs.
CPUQ=${CPUQ:-$PWD/bin/cpuq}
R=$1/int.$$; mkdir -p $R
export CPUQ_DIR=$R/state CPUQ_CONFIG=$R/config CPUQ_BUDGET=9
printf 'load_check = off\npressure_check = off\npoll = 0.2\nactive_cap = off\nadmit = cores\n' >$CPUQ_CONFIG
for i in $(seq $2); do
  f=$R/ints; rm -f $f
  python3 -c 'import os,signal,sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])' "$CPUQ" run -- sh -c "trap 'echo INT >>$f; exit 3' INT; while :; do sleep 0.05; done" & p=$!
  until [ "$(ps -o comm= -p $p)" = "$CPUQ" ] || [ "$(basename "$(ps -o comm= -p $p)")" = cpuq ]; do :; done
  d=${3:-$((RANDOM % 25))}
  python3 -c "import time; time.sleep($d/1000)"
  kill -INT $p
  for j in $(seq 50); do kill -0 $p 2>/dev/null || break; sleep 0.1; done
  if kill -0 $p 2>/dev/null; then
    echo "HUNG at delay ${d}ms pid $p"; ps -o pid,ppid,stat,command -g $(ps -o pgid= -p $p) 2>/dev/null | head
    sample $p 1 -file $R/sample.$p.txt >/dev/null 2>&1; echo "sample: $R/sample.$p.txt"
    for c in $(pgrep -P $p); do kill -KILL $c; done; kill -KILL $p
  fi
  wait $p; rc=$?
  n=$(wc -l <$f 2>/dev/null | tr -d ' ')
  k="rc=$rc n=${n:-0}"; echo "$k" >>$R/outcomes
  [ "$k" != "rc=3 n=1" ] && echo "delay ${d}ms: $k"
done
sort $R/outcomes | uniq -c
