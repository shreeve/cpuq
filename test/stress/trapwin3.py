# Aim INT at the moment sh installs its trap: track the boundary between
# "died of INT" and "trap ran" and keep sending around it; count hangs.
import os, random, signal, subprocess, sys, time, collections
n = int(sys.argv[1]); b = 0.004; out = collections.Counter()
for i in range(n):
    p = subprocess.Popen(["sh", "-c", "trap 'exit 3' INT; while :; do sleep 0.05; done"])
    d = b + random.uniform(-0.0002, 0.0002)
    t = time.perf_counter()
    while time.perf_counter() - t < d: pass
    os.kill(p.pid, signal.SIGINT)
    try:
        rc = p.wait(timeout=1)
    except subprocess.TimeoutExpired:
        rc = "hang"; p.kill(); p.wait()
    out[rc] += 1
    if rc == -2: b += 0.00003
    elif rc == 3: b -= 0.00003
print(dict(out), "boundary %.2f ms" % (b * 1000))
