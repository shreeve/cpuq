import os, random, signal, subprocess, sys, time, collections
c = collections.Counter()
for i in range(int(sys.argv[1])):
    p = subprocess.Popen(["sh", "-c", "sleep 20.371"])
    d = random.uniform(0, 0.006)
    t = time.perf_counter()
    while time.perf_counter() - t < d: pass
    os.kill(p.pid, signal.SIGTERM)
    try: rc = p.wait(timeout=1)
    except subprocess.TimeoutExpired: rc = "survived"; p.kill(); p.wait()
    c[rc] += 1
print(dict(c))
