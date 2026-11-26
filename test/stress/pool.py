# pool.py [TASKS] [MS] [KILLS]: three projects share the pool, with SIGKILLs, and every task's
# start and end on its CPU is logged, then checked:
#
#   - never more tasks running than the pool has CPUs (overload 1), and never two tasks on one
#     CPU at once
#   - hand-off: from a task ending on a CPU to the next starting there, while tasks wait
#     (median and p99)
#   - fairness: each project's share of the busy CPU time while all three have work
#   - nothing left behind: no op records, every CPU free, no task process alive
#
#   TASKS  tasks per project (default 100)
#   MS     each task's CPU time in milliseconds (default 50)
#   KILLS  how many processes the harness SIGKILLs at random: tasks, and one project's cpuq
#          (default 10)
#
# `CPUQ=path` picks the binary. It runs in a scratch state dir of its own (CPUQ_DIR), with
# `budget` CPUs from CPUQ_BUDGET (default: every CPU). Run it outside any cpuq job.
import glob, os, random, shutil, signal, subprocess, sys, tempfile, time

cpuq = os.environ.get("CPUQ", os.path.join(os.getcwd(), "bin/cpuq"))
tasks = int(sys.argv[1]) if len(sys.argv) > 1 else 100
ms = int(sys.argv[2]) if len(sys.argv) > 2 else 50
kills = int(sys.argv[3]) if len(sys.argv) > 3 else 10
work = tempfile.mkdtemp(prefix="cpuq-pool-")
os.makedirs(work + "/home", exist_ok=True)
log = work + "/log"
with open(work + "/config", "w") as f:
    f.write("min_disk = off\npressure_check = off\n" + ("budget = %s\n" % os.environ["CPUQ_BUDGET"] if "CPUQ_BUDGET" in os.environ else ""))
env = dict(os.environ, CPUQ_DIR=work + "/state", CPUQ_CONFIG=work + "/config", HOME=work + "/home")
for k in ("CPUQ_CPU", "CPUQ_OP"):
    env.pop(k, None)

# Each task: log S, keep one CPU busy for MS, log E. One write each (O_APPEND lands whole).
task = ("perl -MTime::HiRes=time -e '"
        "open(my $f, \">>\", $ENV{L}); my $t0 = time; syswrite $f, sprintf(\"S %%.6f %%s %%s %%s %%s\\n\", $t0, $ENV{CPUQ_CPU}, $ENV{P}, $ENV{CPUQ_TASK}, $$);"
        "1 while time < $t0 + %f; syswrite $f, sprintf(\"E %%.6f %%s %%s %%s %%s\\n\", time, $ENV{CPUQ_CPU}, $ENV{P}, $ENV{CPUQ_TASK}, $$);'") % (ms / 1000)
procs = {}
for p in ("aaa", "bbb", "ccc"):
    procs[p] = subprocess.Popen([cpuq, "run", "--label", p + ":t", "-n", str(tasks), "-t", "60", "--", "sh", "-c", task],
                                cwd=work, env=dict(env, L=log, P=p), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

killed = []
deadline = time.time() + 600
victim_parent = "ccc"
while any(pr.poll() is None for pr in procs.values()) and time.time() < deadline:
    time.sleep(random.uniform(0.05, 0.3))
    if len(killed) >= kills:
        continue
    if len(killed) == kills // 2 and procs[victim_parent].poll() is None:
        procs[victim_parent].send_signal(signal.SIGKILL)
        killed.append(("parent", procs[victim_parent].pid, time.time()))
        continue
    try:
        lines = open(log).read().splitlines()
    except FileNotFoundError:
        continue
    started = {l.split()[5] for l in lines if l.startswith("S")}
    ended = {l.split()[5] for l in lines if l.startswith("E")}
    live = sorted(started - ended)
    if live:
        pid = int(random.choice(live))
        try:
            os.kill(pid, signal.SIGKILL)
            killed.append(("task", pid, time.time()))
        except ProcessLookupError:
            pass
for pr in procs.values():
    if pr.poll() is None:
        pr.kill()
time.sleep(1.5)

# Check.
lines = [l.split() for l in open(log).read().splitlines()]
starts = {(l[3], l[4], l[5]): (float(l[1]), l[2]) for l in lines if l[0] == "S"}
ends = {(l[3], l[4], l[5]): float(l[1]) for l in lines if l[0] == "E"}
kill_at = {str(pid): t for kind, pid, t in killed if kind == "task"}
parent_kill = next((t for kind, _, t in killed if kind == "parent"), None)
intervals = []
t_first = min((t0 for t0, _ in starts.values()), default=0)
for key, (t0, cpu) in starts.items():
    proj, _, pid = key
    t1 = ends.get(key) or kill_at.get(pid)
    if t1 is None and proj == victim_parent and parent_kill is not None:
        t1 = parent_kill  # its tasks die with it (Linux), or by the next holder of the CPU
    if t1 is None:
        t1 = t0 + ms / 1000
    intervals.append((t0, t1, cpu, proj))

# Each pair of tasks that overlapped on one CPU, with how each ended.
how = {}
for (proj, task, pid), (t0, cpu) in starts.items():
    how[(t0, cpu, proj)] = "ended" if (proj, task, pid) in ends else ("killed" if pid in kill_at else ("parent killed" if proj == victim_parent else "no end"))
overlaps = []
by = {}
for iv in intervals:
    by.setdefault(iv[2], []).append(iv)
for cpu, ivs in by.items():
    ivs.sort()
    for x, y in zip(ivs, ivs[1:]):
        if y[0] < x[1]:
            overlaps.append((cpu, x, y))
events = sorted([(t0, 1, cpu, p) for t0, t1, cpu, p in intervals] + [(t1, -1, cpu, p) for t0, t1, cpu, p in intervals])
running, per_cpu, peak, shared = 0, {}, 0, 0
for t, d, cpu, p in events:
    running += d
    per_cpu[cpu] = per_cpu.get(cpu, 0) + d
    peak = max(peak, running)
    if per_cpu[cpu] > 1:
        shared += 1

by_cpu = {}
for t0, t1, cpu, p in intervals:
    by_cpu.setdefault(cpu, []).append((t0, t1))
gaps = []
last_start = max(t0 for t0, _, _, _ in intervals)
for cpu, iv in by_cpu.items():
    iv.sort()
    for (a0, a1), (b0, b1) in zip(iv, iv[1:]):
        if a1 < last_start - 0.5:
            gaps.append(max(0.0, b0 - a1) * 1000)
gaps.sort()

# Fairness while all three ran: busy CPU time per project inside [all started, first done].
first_end = min(max(t1 for t0, t1, c, p in intervals if p == q) for q in ("aaa", "bbb"))
all_on = max(min(t0 for t0, t1, c, p in intervals if p == q) for q in ("aaa", "bbb", "ccc"))
share = {}
for t0, t1, cpu, p in intervals:
    a, b = max(t0, all_on), min(t1, first_end if parent_kill is None else min(first_end, parent_kill))
    if b > a:
        share[p] = share.get(p, 0) + (b - a)
total = sum(share.values()) or 1

ops_left = glob.glob(work + "/state/v2/ops/*")
def alive_pid(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (ProcessLookupError, ValueError):
        return False
    except PermissionError:
        return True
alive = [pid for (_, _, pid) in starts if alive_pid(pid)]
print("pool: %d tasks of %d ms in 3 projects, %d kills (%s)" % (len(intervals), ms, len(killed), ", ".join(k for k, _, _ in killed)))
print("most running at once: %d; times two tasks shared a CPU: %d" % (peak, shared))
for cpu, x, y in overlaps[:5]:
    print("  CPU %s: %s from %.3f to %.3f (%s), %s from %.3f (%s): %.1f ms together" % (
        cpu, x[3], x[0] - t_first, x[1] - t_first, how[(x[0], x[2], x[3])], y[3], y[0] - t_first, how[(y[0], y[2], y[3])], 1000 * (x[1] - y[0])))
if gaps:
    print("hand-off: median %.1f ms, p99 %.1f ms, max %.1f ms (%d hand-offs)" % (gaps[len(gaps) // 2], gaps[int(len(gaps) * .99)], gaps[-1], len(gaps)))
print("shares while all ran: " + ", ".join("%s %.0f%%" % (p, 100 * v / total) for p, v in sorted(share.items())))
print("left behind: %d op records, %d task processes" % (len(ops_left), len(alive)))
print("work dir: " + work)

if not os.environ.get("KEEP"):
    shutil.rmtree(work, ignore_errors=True)
