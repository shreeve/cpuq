#!/bin/sh
#
# scenario.sh — synthetic work for this machine's cpuq, shaped like the real thing
#
# Submits stress-ng jobs through `cpuq run` for about MINUTES (default 10), sized to this
# machine's CPUs and memory, so cpuq's queue, its measured admission and Cpuq.app's charts can
# be watched under realistic load: more asked for than there is, of different shapes, from
# several projects. Every job ends on its own; nothing outlives it.
#
#   build    its grant at full (matrix math), then one core alone: a compile, then a link
#   tests    short bursts on its grant with pauses between: a test suite
#   greedy   three workers per core it was granted: a runner whose compilers outnumber its
#            cores, so the machine's demand climbs past its CPUs
#   memory   its grant at work while it holds and touches a few GB
#   lint     one core, briefly
#
# Labels are scen-alpha, scen-beta and scen-gamma, so the projects take different colors.
# Needs cpuq and stress-ng (apt install stress-ng; brew install stress-ng). Run it on the
# machine to load, detached so it outlives the connection:
#
#   scp scripts/scenario.sh HOST: && ssh HOST 'setsid -f ./scenario.sh 10 >scenario.log 2>&1 </dev/null'
#
# Usage: scenario.sh [MINUTES]

set -eu

minutes=${1:-10}
case $minutes in '' | *[!0-9]*) echo "usage: scenario.sh [MINUTES]" >&2; exit 2 ;; esac
command -v cpuq >/dev/null || { echo "scenario.sh: cpuq not found" >&2; exit 127; }
command -v stress-ng >/dev/null || { echo "scenario.sh: stress-ng not found (apt install stress-ng)" >&2; exit 127; }

cpus=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
mem_gb=$(awk '/MemTotal/ { print int($2 / 1048576) }' /proc/meminfo 2>/dev/null || echo 16)
# The biggest job asks for up to a third of the CPUs, the smallest from a quarter of that, so a
# few big jobs fill the machine and the queue is never empty for long.
hi=$((cpus / 3)); [ "$hi" -ge 2 ] || hi=2
lo=$((hi / 4)); [ "$lo" -ge 1 ] || lo=1
# A memory job holds a 24th of memory (8 GB on a 192 GB machine), in two workers.
vm_gb=$((mem_gb / 48)); [ "$vm_gb" -ge 1 ] || vm_gb=1

# A whole number from LO to HI, from /dev/urandom: awk's srand takes a seed it rounds, so seeds a
# moment apart gave the same numbers.
rand() { echo $(( $1 + $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % ($2 - $1 + 1) )); }

# One job, in the background: LABEL CORES SCRIPT (sh, with $CPUQ_CORES set by cpuq).
job() {
    printf '%s  %-22s --cores %-6s submitted\n' "$(date +%T)" "$1" "$2"
    cpuq run --label "$1" --cores "$2" -- sh -c "$3" >/dev/null 2>&1 &
}

end=$(($(date +%s) + minutes * 60))
n=0
echo "scenario: $minutes min on $cpus CPUs / ${mem_gb} GB; jobs ask --cores $lo-$hi"
while [ "$(date +%s)" -lt "$end" ]; do
    # At most 12 jobs in flight, running or waiting: the queue stays long, not endless.
    while [ "$(jobs -p | wc -l)" -ge 12 ]; do sleep 2; done
    n=$((n + 1))
    project=$(echo alpha beta gamma | cut -d' ' -f$(( (n % 3) + 1 )))
    t=$(rand 40 150)
    case $(rand 1 9) in
        1 | 2 | 3) job "scen-$project:build" "$lo-$hi" \
            "stress-ng -q --cpu \"\$CPUQ_CORES\" --cpu-method matrixprod --timeout ${t}s && stress-ng -q --cpu 1 --cpu-method fft --timeout $((t / 4))s" ;;
        4 | 5) job "scen-$project:tests" "$lo-$hi" \
            "i=0; while [ \$i -lt $((t / 6)) ]; do stress-ng -q --cpu \"\$CPUQ_CORES\" --timeout 4s; sleep 2; i=\$((i + 1)); done" ;;
        6) job "scen-$project:greedy" "$lo-$((hi / 2 > lo ? hi / 2 : lo))" \
            "stress-ng -q --cpu \$((CPUQ_CORES * 3)) --timeout ${t}s" ;;
        7) job "scen-$project:memory" "$lo-$hi" \
            "stress-ng -q --cpu \"\$CPUQ_CORES\" --vm 2 --vm-bytes ${vm_gb}G --vm-keep --timeout ${t}s" ;;
        *) job "scen-$project:lint" 1 "stress-ng -q --cpu 1 --timeout $(rand 15 45)s" ;;
    esac
    sleep "$(rand 3 15)"
done
echo "scenario: $n jobs submitted; waiting for the last to finish"
wait
echo "scenario: done"
