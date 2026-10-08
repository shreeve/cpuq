# selfint.py DIR N [P] [ign] [dfl]: t_exit_status's SIGINT case, `cpuq run -- sh -c
# 'kill -INT $$'` from python, N times, P at once; counts how cpuq ended (-2 is right).
# `ign` starts as a `&` job in a script does, SIGINT ignored; `dfl` then resets it the
# way the test does since 0.8.9, so the command is not handed it ignored.
import collections, os, signal, subprocess, sys, threading
cpuq = os.environ.get("CPUQ", os.path.join(os.getcwd(), "bin/cpuq"))
d = os.path.join(sys.argv[1], "selfint.%d" % os.getpid()); n = int(sys.argv[2])
par = int(sys.argv[3]) if len(sys.argv) > 3 else 4
if "ign" in sys.argv[4:]: signal.signal(signal.SIGINT, signal.SIG_IGN)
if "dfl" in sys.argv[4:]: signal.signal(signal.SIGINT, signal.SIG_DFL)
os.makedirs(d, exist_ok=True)
cfg = os.path.join(d, "config")
with open(cfg, "w") as f:
    f.write("load_check = off\npressure_check = off\npoll = 0.2\nactive_cap = off\nadmit = cores\n")
env = dict(os.environ, CPUQ_DIR=os.path.join(d, "state"), CPUQ_CONFIG=cfg, CPUQ_BUDGET="64")
for k in ("CPUQ_TOKEN", "CPUQ_CORES", "MAKEFLAGS"): env.pop(k, None)
out = collections.Counter(); lock = threading.Lock(); left = [n]
def worker():
    while True:
        with lock:
            if left[0] == 0: return
            left[0] -= 1
        r = subprocess.run([cpuq, "run", "--", "sh", "-c", "kill -INT $$"], env=env, stderr=subprocess.PIPE)
        with lock:
            out[r.returncode] += 1
            if r.returncode != -2 and out[r.returncode] <= 3: print("got", r.returncode, r.stderr.decode().strip(), flush=True)
ts = [threading.Thread(target=worker) for _ in range(par)]
for t in ts: t.start()
for t in ts: t.join()
print(dict(out))
