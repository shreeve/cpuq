# fair.py [SECONDS]: time to a fair share, and an urgent run's start, on a full pool.
#
# Project aaa fills the pool with a long run of short tasks at overload 3. A tenth of the way
# in, project bbb arrives with tasks of a second; a fifth of the way in, an urgent one-task run
# from ccc arrives. Status is sampled every 0.2 s. It reports how long bbb took to reach its
# fair share (within one CPU of aaa), and how long the urgent run waited for its CPU.
#
# `CPUQ=path` picks the binary, CPUQ_BUDGET the pool (default every CPU). Runs in a scratch
# state dir of its own; run it outside any cpuq job.
import json, os, shutil, subprocess, sys, tempfile, time

cpuq = os.environ.get("CPUQ", os.path.join(os.getcwd(), "bin/cpuq"))
secs = float(sys.argv[1]) if len(sys.argv) > 1 else 60.0
work = tempfile.mkdtemp(prefix="cpuq-fair-")
os.makedirs(work + "/home", exist_ok=True)
with open(work + "/config", "w") as f:
    f.write("min_disk = off\npressure_check = off\noutside_check = off\n")
    if "CPUQ_BUDGET" in os.environ:
        f.write("budget = %s\n" % os.environ["CPUQ_BUDGET"])
env = dict(os.environ, CPUQ_DIR=work + "/state", CPUQ_CONFIG=work + "/config", HOME=work + "/home")
for k in ("CPUQ_CPU", "CPUQ_OP"):
    env.pop(k, None)

spin = "perl -MTime::HiRes=time -e 'my $e = time + %s; 1 while time < $e'"
t0 = time.time()
a = subprocess.Popen([cpuq, "run", "--label", "aaa:fill", "-n", "100000", "-x", "3", "-t", "60", "--", "sh", "-c", spin % "0.2"],
                     cwd=work, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
samples = []
b = u = None
urgent_wait = None
while time.time() - t0 < secs:
    now = time.time() - t0
    if b is None and now >= secs / 10:
        b_at = now
        b = subprocess.Popen([cpuq, "run", "--label", "bbb:suite", "-n", "100000", "-t", "60", "--", "sh", "-c", spin % "1"],
                             cwd=work, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if u is None and now >= secs / 5:
        u_at = time.time()
        u = subprocess.Popen([cpuq, "run", "--urgent", "--label", "ccc:build", "--", "sh", "-c", "echo started"],
                             cwd=work, env=env, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    if u is not None and urgent_wait is None and u.poll() is not None:
        urgent_wait = time.time() - u_at
    out = subprocess.run([cpuq, "status", "--json", "--no-usage"], env=env, capture_output=True, text=True).stdout
    try:
        s = json.loads(out)
    except ValueError:
        continue
    held = {h["label"].split(":")[0]: h.get("cores", 0) for h in s.get("holders", [])}
    samples.append((round(now, 2), held.get("aaa", 0), held.get("bbb", 0), s.get("budget", 0)))
    time.sleep(0.2)
for p in (a, b, u):
    if p is not None and p.poll() is None:
        p.terminate()
for p in (a, b, u):
    if p is not None:
        p.wait()

pool = max((x[3] for x in samples), default=0)
fair_at = next((t for t, ha, hb, _ in samples if b is not None and t >= b_at and hb >= pool // 2 - 1 and abs(ha - hb) <= 1), None)
late = [(ha, hb) for t, ha, hb, _ in samples if fair_at is not None and t >= fair_at + 2]
spread = max((abs(ha - hb) for ha, hb in late), default=None)
print("fair: pool %d; bbb arrived at %.1fs" % (pool, b_at if b is not None else -1))
print("bbb reached its share (within one CPU of aaa) %s" % ("%.2fs after arriving" % (fair_at - b_at) if fair_at is not None else "never"))
print("afterwards aaa and bbb stayed within %s CPU(s) of each other" % spread)
print("urgent run's wait for a CPU: %s" % ("%.3fs" % urgent_wait if urgent_wait is not None else "it never ran"))
with open(work + "/samples.tsv", "w") as f:
    f.write("t\taaa\tbbb\tpool\n" + "".join("%s\t%s\t%s\t%s\n" % x for x in samples))
print("samples: " + work + "/samples.tsv")

if not os.environ.get("KEEP"):
    shutil.rmtree(work, ignore_errors=True)
