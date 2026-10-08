#!/bin/bash
# stress_pause.sh DIR N: pause a run as soon as it can be paused; count runs
# whose command did not stop.
CPUQ=${CPUQ:-$PWD/bin/cpuq}
R=$1/pause.$$; mkdir -p $R
export CPUQ_DIR=$R/state CPUQ_CONFIG=$R/config CPUQ_BUDGET=9
printf 'load_check = off\npressure_check = off\npoll = 0.2\nactive_cap = off\nadmit = cores\n' >$CPUQ_CONFIG
ok=0; bad=0
for i in $(seq $2); do
  "$CPUQ" run --cores 1 --label p -- sh -c 'sleep 20.373' & p=$!
  until "$CPUQ" pause p 2>/dev/null >/dev/null && [ -n "$(ls $CPUQ_DIR | grep '^paused-')" ]; do :; done
  child=$("$CPUQ" status --json --no-usage | python3 -c 'import json, sys; print(json.load(sys.stdin)["holders"][0]["child"])')
  sleep 0.6
  st=$(ps -o stat= -p $child | tr -d ' ')
  if [[ "$st" == T* ]]; then ok=$((ok+1)); else bad=$((bad+1)); fi
  "$CPUQ" stop p >/dev/null; wait $p
done
echo "stopped $ok, still running $bad"
