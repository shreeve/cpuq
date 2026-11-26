#!/usr/bin/env python3
"""test/stress/tok.py: cpuq tok under load, on a private pool.

Hundreds of one-token jobs, a few 8- and 32-token jobs and a few `cpuq run` jobs share a
pool of POOL tokens (32 by default) in a state directory of their own, so the machine's
queue is never touched. Some tools are killed with SIGKILL: running ones (their command
runs on, holding its tokens), running ones with their command's group, and waiting ones.

Each job logs when its command starts and ends; a command runs only while its tokens are
held, so at no moment may the commands running hold more than POOL tokens between them.
It checks that, that every job not killed while waiting ran, that nothing waited past
LIMIT seconds (no deadlock, no starvation), and that every token is free at the end.

    CPUQ=bin/cpuq POOL=32 SINGLES=300 test/stress/tok.py

The jobs sleep, so the run keeps about one CPU busy, mostly starting Python.
"""
import json
import os
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time

CPUQ = os.path.abspath(os.environ.get("CPUQ", "bin/cpuq"))
POOL = int(os.environ.get("POOL", "32"))
SINGLES = int(os.environ.get("SINGLES", "300"))
EIGHTS = int(os.environ.get("EIGHTS", "4"))
WIDE = int(os.environ.get("WIDE", "2"))
RUNS = int(os.environ.get("RUNS", "6"))
SPREAD = float(os.environ.get("SPREAD", "6"))
LIMIT = float(os.environ.get("LIMIT", "300"))
SEED = int(os.environ.get("SEED", str(int(time.time()))))

JOB = r"""
import os, sys, time
ident, n, dur, ev = sys.argv[1:5]
cores = os.environ.get("CPUQ_CORES", "0")
def log(kind):
    fd = os.open(ev, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    os.write(fd, ("%s %.6f %s %s %s %d\n" % (kind, time.time(), ident, n, cores, os.getpid())).encode())
    os.close(fd)
log("start")
time.sleep(float(dur))
log("end")
"""


def main():
    rnd = random.Random(SEED)
    root = tempfile.mkdtemp(prefix="cpuq-tok-stress.")
    state = os.path.join(root, "state")
    events = os.path.join(root, "events")
    job_py = os.path.join(root, "job.py")
    with open(job_py, "w") as f:
        f.write(JOB)
    with open(os.path.join(root, "config"), "w") as f:
        # A pool of POOL tokens whatever the machine's load: the rules are tested, not the gates.
        f.write("admit = cores\nload_check = off\npressure_check = off\nmin_disk = off\n"
                "active_cap = off\naffinity = off\ncgroups = off\ncpu_weights = off\npoll = 0.2\n")
    env = dict(os.environ)
    for k in ("CPUQ_TOKEN", "CPUQ_CORES", "CPUQ_CPUS", "CPUQ_LEASES", "MAKEFLAGS", "CPUQ_CGROUP"):
        env.pop(k, None)
    env.update(CPUQ_DIR=state, CPUQ_CONFIG=os.path.join(root, "config"), CPUQ_BUDGET=str(POOL),
               CPUQ_HISTORY=os.path.join(root, "history"))
    print("pool %d, %d one-token jobs, %d of 8, %d of %d, %d runs; seed %d; %s"
          % (POOL, SINGLES, EIGHTS, WIDE, POOL, RUNS, SEED, root))

    # The jobs: (id, kind, tokens, seconds, when to start).
    jobs = []
    for i in range(SINGLES):
        jobs.append(("s%d" % i, "tok", 1, rnd.uniform(0.05, 0.4), rnd.uniform(0, SPREAD)))
    for i in range(EIGHTS):
        jobs.append(("e%d" % i, "tok", 8, rnd.uniform(0.5, 1.5), rnd.uniform(0, SPREAD * 0.7)))
    for i in range(WIDE):
        jobs.append(("w%d" % i, "tok", POOL, rnd.uniform(0.5, 1.5), SPREAD * (0.15 + 0.4 * i)))
    for i in range(RUNS):
        jobs.append(("r%d" % i, "run", 4 if i % 2 == 0 else 0, rnd.uniform(0.5, 1.5), rnd.uniform(0, SPREAD)))
    jobs.sort(key=lambda j: j[4])

    procs = {}
    launched = {}
    killed_waiting, killed_running, killed_group = set(), set(), {}
    peak = [0]
    stop = threading.Event()

    def sample():
        # How many tokens are out, as the directories say (a rough, informative view).
        while not stop.is_set():
            try:
                n = len(os.listdir(os.path.join(state, "tok/live"))) + len(os.listdir(os.path.join(state, "tok/runs")))
                peak[0] = max(peak[0], n)
            except OSError:
                pass
            time.sleep(0.01)

    threading.Thread(target=sample, daemon=True).start()

    def started():
        out = {}
        try:
            with open(events) as f:
                for line in f:
                    p = line.split()
                    if p[0] == "start":
                        out[p[2]] = int(p[5])
        except OSError:
            pass
        return out

    def ended():
        out = set()
        try:
            with open(events) as f:
                for line in f:
                    p = line.split()
                    if p[0] == "end":
                        out.add(p[2])
        except OSError:
            pass
        return out

    t0 = time.time()
    # Kills, from 30% of the spread on, a few at a time until each quota is met: waiting tools
    # (a multi-token one first: it may hold part of its tokens), running tools alone (their
    # commands run on, holding their tokens), and running tools with their commands' groups.
    quota = {"waiting": 10, "multi": 2, "running": 10, "group": 5}
    kill_from, kill_until = t0 + SPREAD * 0.3, t0 + SPREAD * 1.5
    next_kill = kill_from
    devnull = open(os.devnull, "w")
    pending = list(jobs)
    while pending or (any(quota.values()) and time.time() < kill_until):
        now = time.time()
        while pending and t0 + pending[0][4] <= now:
            ident, kind, n, dur, _ = pending.pop(0)
            cmd = ["python3", job_py, ident, str(n), "%.3f" % dur, events]
            if kind == "tok":
                argv = [CPUQ, "tok", str(n), "--label", "stress:tok", "--"] + cmd
            else:
                argv = [CPUQ, "run", "--label", "stress:run", "--cores", "4" if n else "2-8", "--"] + cmd
            procs[ident] = subprocess.Popen(argv, env=env, stdout=devnull, stderr=subprocess.PIPE)
            launched[ident] = time.time()
        if now >= next_kill and now < kill_until and any(quota.values()):
            next_kill = now + 0.3
            run = started()
            done = ended()
            toks = [i for i in procs if not i.startswith("r") and procs[i].poll() is None
                    and i not in killed_waiting and i not in killed_running and i not in killed_group]
            running = [i for i in toks if i in run and i not in done]
            waiting = [i for i in toks if i not in run]
            rnd.shuffle(running)
            rnd.shuffle(waiting)
            for i in [i for i in waiting if not i.startswith("s")][:min(1, quota["multi"])]:
                procs[i].send_signal(signal.SIGKILL)
                killed_waiting.add(i)
                quota["multi"] -= 1
            for i in [i for i in waiting if i.startswith("s")][:min(2, quota["waiting"])]:
                procs[i].send_signal(signal.SIGKILL)
                killed_waiting.add(i)
                quota["waiting"] -= 1
            take = min(2, quota["running"])
            for i in running[:take]:
                procs[i].send_signal(signal.SIGKILL)
                killed_running.add(i)
                quota["running"] -= 1
            for i in running[take:take + min(1, quota["group"])]:
                procs[i].send_signal(signal.SIGKILL)
                try:
                    os.killpg(run[i], signal.SIGKILL)
                except OSError:
                    pass
                killed_group[i] = time.time()
                quota["group"] -= 1
        time.sleep(0.01)

    deadline = t0 + LIMIT
    hung = []
    for ident, p in procs.items():
        left = deadline - time.time()
        try:
            p.wait(timeout=max(left, 0.1))
        except subprocess.TimeoutExpired:
            hung.append(ident)
    # Orphaned commands (their tool killed) end by themselves; wait for their end lines.
    while time.time() < deadline and not (killed_running & set(started())) <= ended():
        time.sleep(0.1)
    stop.set()
    took = time.time() - t0

    if hung:
        print("FAIL: still waiting after %ds: %s" % (LIMIT, " ".join(sorted(hung)[:20])))
        subprocess.run([CPUQ, "status"], env=env)
        for p in procs.values():
            if p.poll() is None:
                p.kill()

    # The commands running at once, by the tokens each held.
    marks = []
    starts, waits, bad_cores = {}, {}, []
    with open(events) as f:
        lines = [l.split() for l in f]
    for kind, ts, ident, n, cores, pid in lines:
        ts = float(ts)
        held = int(cores)
        if kind == "start":
            starts[ident] = ts
            waits[ident] = ts - launched[ident]
            if not ident.startswith("r") and held != int(n):
                bad_cores.append(ident)
            marks.append((ts, 1, held, ident))
        else:
            marks.append((ts, 0, held, ident))
    held_by = {}
    for kind, ts, ident, n, cores, pid in lines:
        if kind == "start":
            held_by[ident] = int(cores)
    for ident, ts in killed_group.items():
        if ident in starts:
            marks.append((ts, 0, held_by[ident], ident))
    marks.sort(key=lambda m: (m[0], m[1]))  # ends before starts at the same instant
    out, most, open_ = 0, 0, set()
    for ts, is_start, held, ident in marks:
        if is_start:
            out += held
            open_.add(ident)
        elif ident in open_:
            out -= held
            open_.discard(ident)
        most = max(most, out)

    expected = set(procs) - killed_waiting
    missing = sorted(expected - set(starts))
    ran = len(set(starts))
    codes = {}
    for ident, p in procs.items():
        if ident in killed_waiting or ident in killed_running or ident in killed_group:
            continue
        codes.setdefault(p.returncode, []).append(ident)

    # Every token free at the end: the status's look gives back what killed holders left.
    status = json.loads(subprocess.run([CPUQ, "status", "--json", "--no-usage"], env=env,
                                       capture_output=True, text=True).stdout)
    pool = status.get("tok") or {}
    leftover = [d for d in ("live", "runs", "wait", "held") if os.listdir(os.path.join(state, "tok", d))]

    def worst(prefix):
        w = [waits[i] for i in waits if i.startswith(prefix)]
        return "%.1fs" % max(w) if w else "-"

    print("ran %d of %d jobs in %.1fs (killed: %d waiting, %d running, %d with their group)"
          % (ran, len(procs), took, len(killed_waiting), len(killed_running), len(killed_group)))
    print("most tokens held by running commands at once: %d of %d (directories' peak %d)" % (most, POOL, peak[0]))
    print("longest wait: one-token %s, 8-token %s, %d-token %s, runs %s"
          % (worst("s"), worst("e"), POOL, worst("w"), worst("r")))
    print("pool at the end: %s free of %s, leftover files in %s"
          % (pool.get("free"), pool.get("tokens"), " ".join(leftover) or "none"))

    failures = []
    if most > POOL:
        failures.append("more tokens held at once than exist: %d > %d" % (most, POOL))
    if missing:
        failures.append("never ran: %s" % " ".join(missing[:20]))
    if bad_cores:
        failures.append("CPUQ_CORES differs from the tokens asked for: %s" % " ".join(bad_cores[:10]))
    if set(codes) - {0}:
        failures.append("exit statuses: %s" % {k: len(v) for k, v in codes.items()})
    if hung:
        failures.append("hung: %d jobs" % len(hung))
    if pool.get("free") != POOL or leftover:
        failures.append("tokens not all back: %s free, leftovers %s" % (pool.get("free"), leftover))
    for f in failures:
        print("FAIL: " + f)
    if not failures:
        print("PASS")
        shutil.rmtree(root, ignore_errors=True)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
