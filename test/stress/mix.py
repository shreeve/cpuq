# mix.py MODE [SCALE] [SECONDS]: emdb's burst mix (2026-11-26 04:53 UTC), replayed, with CPUs
# granted against CPUs busy recorded each second.
#
#   MODE    blocks: each job asks for a block of cores, as cpuq did (`cpuq run --cores N`);
#           slots:  the same work as tasks, one CPU each (`cpuq run -n M`).
#   SCALE   job sizes as a share of burst's 94-CPU budget (default 1.0; 0.1 fits the Mac).
#   SECONDS how long the long jobs run (default 600).
#
# Run it outside any cpuq job: it starts its jobs through cpuq itself. `CPUQ=path` picks the
# binary. It writes mix-MODE.tsv (one line a second: t, held, busy, waiters) beside itself
# and prints the summary: granted minus busy, and CPU-seconds left idle while a job waited.
#
# The jobs, as emdb saw them (asked, then kept busy):
#   crash3      asks 16: 16 busy for a fifth of the run, then 2 busy
#   suites      asks 24: 2 busy
#   measure x2  ask 8 each: 1 busy
#   rigbuild    asks 16: 1 busy
#   walk        arrives a tenth of the way in, asks 32-96: 60 busy for half the run
#   stream      one-CPU tasks of 2 seconds, 4 at a time, the whole run
import json, os, subprocess, sys, threading, time

cpuq = os.environ.get("CPUQ", "cpuq")
mode = sys.argv[1]
scale = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
secs = float(sys.argv[3]) if len(sys.argv) > 3 else 600.0
if mode not in ("blocks", "slots"):
    sys.exit("usage: mix.py blocks|slots [SCALE] [SECONDS]")

def n(x):  # a size at this scale, at least 1
    return max(1, round(x * scale))

def burn(t):  # one CPU busy for t seconds, then exit 0
    return ["perl", "-e", "my $e=time+%.1f; 1 while time<$e" % t]

def burns(k, t):  # k CPUs busy for t seconds, as one shell
    one = "perl -e 'my $e=time+%.1f; 1 while time<$e'" % t
    return ["sh", "-c", " & ".join([one] * k) + "; wait"]

def run(label, cores, cmd):  # block mode: one job holding `cores`
    return [cpuq, "run", "--label", label, "--cores", str(cores), "--"] + cmd

def tasks(label, m, cmd):  # slot mode: m tasks, each its own CPU
    return [cpuq, "run", "--label", label, "-n", str(m), "--"] + cmd

fan, long = secs / 5, secs
jobs = []  # (start delay, argv)
sh_q = lambda s: "'" + s.replace("'", "'\\''") + "'"

def chain(*argvs):  # one shell running argvs one after another
    return ["sh", "-c", " && ".join(" ".join(sh_q(a) for a in v) for v in argvs)]

if mode == "blocks":
    # crash3 holds its 16 for the whole run: one job, fan-out then 2 busy.
    jobs.append((0, run("emdb:model", n(16), ["sh", "-c", " ".join(sh_q(a) for a in burns(n(16), fan)) + " && " + " ".join(sh_q(a) for a in burns(n(2), long - fan))])))
    jobs.append((0, run("trig:suites", n(24), burns(n(2), long))))
    jobs.append((0, run("trig:pr-measure", n(8), burn(long))))
    jobs.append((0, run("trig:pr-measure", n(8), burn(long))))
    jobs.append((0, run("trig:rigbuild", n(16), burn(long))))
    jobs.append((secs / 10, [cpuq, "run", "--label", "emdb:walk", "--cores", "%d-%d" % (n(32), n(96)), "--"] + burns(n(60), long / 2)))
    stream = lambda: run("rig:test", 1, burn(2))
else:
    jobs.append((0, chain(tasks("emdb:model", n(16), burn(fan)), tasks("emdb:model", n(2), burn(long - fan)))))
    jobs.append((0, tasks("trig:suites", n(2), burn(long))))
    jobs.append((0, tasks("trig:pr-measure", 1, burn(long))))
    jobs.append((0, tasks("trig:pr-measure", 1, burn(long))))
    jobs.append((0, tasks("trig:rigbuild", 1, burn(long))))
    jobs.append((secs / 10, tasks("emdb:walk", n(60), burn(long / 2))))
    stream = lambda: tasks("rig:test", 1, burn(2))

stop = threading.Event()
procs = []

def start(delay, argv):
    if stop.wait(delay):
        return
    procs.append(subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

def streamer():  # 4 at a time, each a fresh job, until the end
    live = []
    while not stop.is_set():
        live = [p for p in live if p.poll() is None]
        while len(live) < 4:
            live.append(subprocess.Popen(stream(), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
        time.sleep(0.2)
    for p in live:
        p.wait()

def status():
    out = subprocess.run([cpuq, "status", "--json"], capture_output=True, text=True).stdout
    return json.loads(out)

threads = [threading.Thread(target=start, args=j) for j in jobs] + [threading.Thread(target=streamer)]
for t in threads:
    t.start()

rows, prev, t0 = [], None, time.time()
while time.time() - t0 < secs + 30 and (time.time() - t0 < secs / 10 + 5 or any(p.poll() is None for p in procs)):
    s = status()
    ticks = [sum(x) for x in zip(*s.get("cpu_ticks") or [[0, 0]])]
    if prev:
        total = ticks[1] - prev[1]
        busy = (ticks[0] - prev[0]) / total * len(s["cpu_ticks"]) if total else 0
        rows.append((round(time.time() - t0, 1), s["held"], round(busy, 1), len(s["waiters"]), s.get("budget") or 0))
    prev = ticks
    if time.time() - t0 >= secs:
        stop.set()
    time.sleep(1)
stop.set()
for t in threads:
    t.join()

path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "mix-%s.tsv" % mode)
with open(path, "w") as f:
    f.write("t\theld\tbusy\twaiters\tbudget\n")
    for r in rows:
        f.write("\t".join(map(str, r)) + "\n")

gap = [max(0, h - b) for _, h, b, _, _ in rows]
waiting = [r for r in rows if r[3] > 0]
idle_waiting = sum(max(0, bud - h) for _, h, _, _, bud in waiting)
pool_secs = sum(r[4] for r in rows) or 1
print("%s: %d samples; held minus busy: mean %.1f, peak %.1f CPUs" % (mode, len(rows), sum(gap) / max(1, len(gap)), max(gap or [0])))
print("seconds with a waiter: %d; CPUs free while one waited: %.0f CPU-s (%.1f%% of the pool's time)"
      % (len(waiting), idle_waiting, 100 * idle_waiting / pool_secs))
print("written: " + path)
