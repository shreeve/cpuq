#!/bin/bash
# stress_release.sh DIR N: a --hold lease that waited behind another waiter
# (so cpuq has a worker thread) is closed and killed at once; count how
# history records it.
CPUQ=${CPUQ:-$PWD/bin/cpuq}
R=$1/release.$$; mkdir -p $R
export CPUQ_DIR=$R/state CPUQ_CONFIG=$R/config CPUQ_BUDGET=9
printf 'load_check = off\npressure_check = off\npoll = 0.2\nactive_cap = off\nadmit = cores\n' >$CPUQ_CONFIG
for i in $(seq $2); do
  "$CPUQ" lease L --label h -- sleep 1.3 & h=$!
  until "$CPUQ" status --json --no-usage | grep -q '"child": [1-9]'; do sleep 0.05; done
  "$CPUQ" lease L --max-wait 1 --label x -- true 2>/dev/null & x=$!
  sleep 0.2
  mkfifo $R/in$i
  "$CPUQ" lease L --hold --label b$i <$R/in$i >$R/out$i 2>/dev/null & b=$!
  exec 7>$R/in$i
  until grep -q held $R/out$i 2>/dev/null; do sleep 0.01; done
  [ $i = 1 ] && echo "threads in b: $(($(ps -M -p $b | wc -l) - 1))"
  exec 7>&-; kill -TERM $b
  wait $b $h $x 2>/dev/null
done
python3 - $CPUQ_DIR/history.jsonl $2 <<'PY'
import json, sys, collections
ev = collections.defaultdict(list)
for line in open(sys.argv[1]):
    e = json.loads(line); ev[e["id"]].append(e)
c = collections.Counter(); seen = 0
for es in ev.values():
    q = [e for e in es if e["event"] == "queued"]
    if not q or not q[0].get("label", "").startswith("b"): continue
    seen += 1
    kinds = [e["event"] for e in es]
    c["gave_up" if "gave_up" in kinds else "ended" if "ended" in kinds else "lost"] += 1
c["absent"] = int(sys.argv[2]) - seen
print(dict(c))
PY
