#!/bin/sh
# burst.sh LOG [POOL] [SECONDS]: the CPU pool's tests at scale, for a quiet large machine (burst).
# Run it through cpuq on that machine, with a time limit:
#
#   cpuq run --on burst --label cpuq:stress --cores 32 --return .zig-cache/burst.log -- \
#     sh -c 'timeout 60m test/stress/burst.sh .zig-cache/burst.log'
#
# It builds a release cpuq, then, each in a scratch state dir of its own and with POOL CPUs
# (default 31, a third of burst):
#   1. emdb's 04:53 mix (mix.py), once on the machine's installed cpuq (blocks of cores, as
#      emdb saw it) and once on this one (one CPU per task): CPUs granted against busy
#   2. three projects under SIGKILLs (pool.py): never over the pool, none shared, hand-off
#   3. a newcomer's time to its fair share and an urgent run's wait (fair.py)
# The pool ignores outside load (outside_check = off) and mix.py counts its own processes'
# CPU, so the numbers hold beside other work, as long as the machine has room for the pool.
# Everything goes to LOG, the mix's samples to .zig-cache/mix-MODE.tsv; scratch is removed.
set -u
LOG=${1:?usage: burst.sh LOG [POOL] [SECONDS]}
POOL=${2:-31}
SECS=${3:-300}
mkdir -p "$(dirname "$LOG")" .zig-cache
: >"$LOG"
exec >>"$LOG" 2>&1
# Inside the outer cpuq job: its grant is not these tests' pool.
unset CPUQ_TOKEN CPUQ_CORES CPUQ_LEASES CPUQ_CPUS CPUQ_PROGRESS MAKEFLAGS CPUQ_CPU CPUQ_OP
OLD=$(command -v cpuq)
echo "== $(date -u +%FT%TZ) $(hostname), $(nproc) CPUs, pool $POOL, mix ${SECS}s; installed: $($OLD --version)"
zig build -Doptimize=ReleaseSafe -j"${CPUQ_CORES_BUILD:-4}" || exit 1
NEW=$PWD/bin/cpuq
echo "this cpuq: $($NEW --version)"
W=$(mktemp -d "${TMPDIR:-/tmp}/cpuq-burst.XXXXXX")
trap 'rm -rf "$W"' EXIT
uptime

for mode in blocks slots; do
  mkdir -p "$W/$mode/home"
  if [ $mode = blocks ]; then
    printf 'admit = cores\nbudget = %s\nmin_disk = off\nexclusive = off\n' "$POOL" >"$W/$mode/config"
    bin=$OLD
  else
    printf 'budget = %s\nmin_disk = off\noutside_check = off\n' "$POOL" >"$W/$mode/config"
    bin=$NEW
  fi
  echo "== 1. mix, $mode ($bin)"
  CPUQ=$bin CPUQ_DIR="$W/$mode/state" CPUQ_CONFIG="$W/$mode/config" CPUQ_HISTORY="$W/$mode/history" HOME="$W/$mode/home" \
    python3 test/stress/mix.py $mode "$(python3 -c "print($POOL / 94)")" "$SECS"
  mv test/stress/mix-$mode.tsv .zig-cache/ 2>/dev/null
  uptime
done

echo "== 2. kills: 3 projects x 300 tasks of 50 ms, 20 SIGKILLs"
CPUQ=$NEW CPUQ_BUDGET=$POOL python3 test/stress/pool.py 300 50 20
uptime

echo "== 3. fairness and urgent"
CPUQ=$NEW CPUQ_BUDGET=$POOL python3 test/stress/fair.py 60
echo "== done $(date -u +%FT%TZ)"
