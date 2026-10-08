#!/bin/bash
# stress_waiter.sh DIR N: SIGTERM a waiter as soon as its ticket shows; count
# how history records it.
CPUQ=${CPUQ:-$PWD/bin/cpuq}
R=$1/waiter.$$; mkdir -p $R
export CPUQ_DIR=$R/state CPUQ_CONFIG=$R/config CPUQ_BUDGET=9
printf 'load_check = off\npressure_check = off\npoll = 0.2\nactive_cap = off\nadmit = cores\n' >$CPUQ_CONFIG
"$CPUQ" run --cores 9 --label holder -- sleep 600.731 & holder=$!
until "$CPUQ" status --json --no-usage | grep -q '"held": 9'; do sleep 0.1; done
for i in $(seq $2); do
  "$CPUQ" run --cores 2 --label w$i -- true & w=$!
  # Kill at a random moment around the ticket appearing.
  if [ $((i % 2)) = 0 ]; then
    until ls $CPUQ_DIR/queue 2>/dev/null | grep -qv '^\.'; do :; done
  else
    until [ "$("$CPUQ" status --json --no-usage | grep -c '"order"')" = 1 ]; do :; done
  fi
  kill -TERM $w; wait $w
  rm -f $CPUQ_DIR/queue/[0-9]*
done
kill $holder; wait $holder
python3 - $CPUQ_DIR/history.jsonl $2 <<'PY'
import json, sys, collections
ev = collections.defaultdict(list)
for line in open(sys.argv[1]):
    e = json.loads(line); ev[e["id"]].append(e)
c = collections.Counter(); seen = 0
for es in ev.values():
    q = [e for e in es if e["event"] == "queued"]
    if not q or not q[0].get("label", "").startswith("w"): continue
    seen += 1
    kinds = [e["event"] for e in es]
    c["gave_up" if "gave_up" in kinds else "ended" if "ended" in kinds else "lost"] += 1
c["absent"] = int(sys.argv[2]) - seen
print(dict(c))
PY
