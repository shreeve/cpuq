#!/bin/bash
# loop.sh TEST N [TIMEOUT]: run one e2e test N times; on a hang, sample its processes.
T=$1; N=$2; TO=${3:-40}; S=$(dirname "$0"); out=$S/loop.$T; mkdir -p $out; pass=0; fail=0; hang=0
desc() { local c; for c in $(pgrep -P $1); do echo $c; desc $c; done; }
for i in $(seq $N); do
  TMPDIR=$out test/run.sh $T >$out/log.$i 2>&1 & p=$!
  k=0; while kill -0 $p 2>/dev/null && [ $k -lt $((TO*10)) ]; do sleep 0.1; k=$((k+1)); done
  if kill -0 $p 2>/dev/null; then
    hang=$((hang+1)); echo "iteration $i HUNG"
    for c in $(desc $p); do ps -o pid=,ppid=,stat=,command= -p $c | cut -c1-200; done | tee $out/hang.$i.ps
    for c in $(desc $p); do [ "$(ps -o comm= -p $c)" != "${CPUQ:-$PWD/bin/cpuq}" ] && [ "$(basename "$(ps -o comm= -p $c)")" != cpuq ] && continue; sample $c 1 -file $out/hang.$i.sample.$c >/dev/null 2>&1; done
    for c in $(desc $p); do kill -KILL $c 2>/dev/null; done; kill $p
  fi
  wait $p && pass=$((pass+1)) || { fail=$((fail+1)); grep -h "FAIL" $out/log.$i; }
done
echo "$T: $pass passed, $fail failed, $hang hung of $N"
