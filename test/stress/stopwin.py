# SIGSTOP `sh -c 'sleep 20'` at a random moment soon after spawning it (as it
# execs sleep); count processes that never stop.
import os, random, signal, subprocess, sys, time, collections
c = collections.Counter(); lost = []
for i in range(int(sys.argv[1])):
    p = subprocess.Popen(["sh", "-c", "sleep 20.371"])
    d = random.uniform(0, 0.006)
    t = time.perf_counter()
    while time.perf_counter() - t < d: pass
    os.kill(p.pid, signal.SIGSTOP)
    st = ""
    for _ in range(20):
        time.sleep(0.02)
        st = subprocess.run(["ps", "-o", "stat=", "-p", str(p.pid)], capture_output=True, text=True).stdout.strip()
        if st.startswith("T"): break
    c["stopped" if st.startswith("T") else "not stopped"] += 1
    if not st.startswith("T"): lost.append("%.2fms %s" % (d * 1000, st))
    os.kill(p.pid, signal.SIGKILL); os.kill(p.pid, signal.SIGCONT); p.wait()
print(dict(c), lost[:10])
