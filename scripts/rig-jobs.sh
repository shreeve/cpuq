#!/bin/sh
#
# rig-jobs.sh — Rig's test suite as a cpuq job, on this machine
#
#   scripts/rig-jobs.sh RIG_DIR [test/run options and filters...]
#
# RIG_DIR is a Rig checkout whose test/run writes its tests as a job folder when RIG_JOBS_DIR is
# set: jobs/rig/STAMP/todo/, a task file each, run by `cpuq jobs run`. This builds Rig, then runs
# its test/run that way under `cpuq run`, its grant the job's workers, with this checkout's
# bin/cpuq as the job's driver. Rig's report and exit status are test/run's; the folder stays
# under jobs/rig/ for `cpuq jobs` and a look at done/ and fail/.
set -eu
[ $# -ge 1 ] || { sed -n '5p' "$0" | sed 's/^# *//' >&2; exit 2; }
rig=$(cd "$1" && pwd); shift
cpuq_bin=$(cd "$(dirname "$0")/.." && pwd)/bin/cpuq
[ -x "$cpuq_bin" ] || { echo "rig-jobs: no $cpuq_bin: run zig build first" >&2; exit 2; }
grep -q RIG_JOBS_DIR "$rig/test/run" || { echo "rig-jobs: $rig/test/run writes no job folder (RIG_JOBS_DIR)" >&2; exit 2; }
state=${CPUQ_STATE:-$HOME/.local/state/cpuq}
cd "$rig"
# test/run builds Rig with no -j: built here first, on the grant, its build is cached there.
exec cpuq run --label rig:jobs --cores 2-5 -- env RIG_JOBS_DIR="$state/jobs" CPUQ_BIN="$cpuq_bin" sh -c '
  zig build -j"$CPUQ_CORES" -Dself-check=true && exec ./test/run -j "$CPUQ_CORES" "$@"' rig-jobs "$@"
