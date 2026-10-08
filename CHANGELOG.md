# Changelog

User-visible changes to cpuq. Each version's section is its release notes.

## 0.8.11 — 2026-10-08

- Under measured admission, a job behind the first waiter starts ahead of it only when the
  machine's checks allow, as they do for the first: not under memory pressure or low memory
  (`min_available`), not while the CPUs are measured 97% busy, and not with `backfill = off`.
  Before, such a job could start beside full CPUs or low memory.
- Wait estimates (`eta` in `cpuq status --json`, and the boxed view) under measured admission
  count what jobs use against `target`, as admission does, instead of cores held against the
  budget, which made them far too short or too long.
- `cpuq status` shows the load valve only where it holds anything: under `admit = cores`, or
  with an exclusive run first in line. The gate in `--json` carries `available` (bytes) when
  memory is low, and `cpuq status --host` shows a remote host closed for low memory as
  closed, not open.
- `cpuq --help` is reorganized: run and lease options in two columns, the real `--cores`
  default, every exit status, and a short block for agents and scripts. The README is
  rewritten around measured admission, with AGENTS.md for coding agents and docs/DESIGN.md
  for the internals.

## 0.8.10 — 2026-10-08

- `window_gap` (config, seconds, off by default): for that long after a quiet window
  (`--exclusive`) ends, windows still waiting go behind the other waiters, so the work queued
  during a window gets its turn before the next one empties the machine. On pup, 299 windows a
  day held or drained the machine about 45% of the time, and other work waited behind them;
  with a 5-minute gap after windows of a few minutes, they take at most about a third.

## 0.8.9 — 2026-10-08

- An exclusive run that opens beside a job paused by hand borrows nothing. It counted the paused
  job's cores as lent: it said it ran "on cores lent by jobs that leave them idle, at background
  priority", which made a clean timing window look like a shared one, and on Linux it really
  ran at background priority.

## 0.8.8 — 2026-10-08

- The first eight waiters, of every kind, look every 2 seconds for a hand-given order, so
  `cpuq cancel`, `first` and `start` take effect at once. An exclusive waiter behind another
  waiter slept up to a minute on the one ahead, and a cancel sat unseen meanwhile.

## 0.8.7 — 2026-10-08

- A run or lease killed the moment it shows in the queue is recorded as having given up, not as
  lost: its `queued` line and its last words are in place before its ticket appears. One killed
  just as it starts is recorded as ended, not as having given up.
- A wait behind another waiter starts a helper thread, and a kill could reach that thread while
  the main one held signals to re-arm its last words, so the job died with none written and
  read as lost (the kit's release, which closes a hold's stdin and kills it at once, lands
  exactly then). cpuq's signals now always go to its main thread.
- macOS: a signal some process sends to cpuq while the same signal is being handled is
  forwarded to the command. macOS gives it no sender, and cpuq took it for the terminal's
  and kept it from the command. Only in a terminal's foreground is a signal with no sender
  the terminal's, and cpuq asks whether it is in the foreground each time (`fg`, `bg`).
- macOS: `cpuq pause` stops the whole tree even when a stop lands as a process starts. macOS
  drops a stop that arrives during exec (in a test, 115 of 400 sent in a command's first 6 ms),
  so pause now looks again every 50 ms for up to half a second and stops whatever still runs.
- The threads that watch a `--hold`'s stdin and send its heartbeat (0.8.6) start with cpuq's
  signals held too, so the kit's close-and-kill always finds the hold's last words in place.

## 0.8.6 — 2026-10-07

- A job's threads ready to run count toward its demand only while the CPUs are at least 90%
  busy. With CPUs idle they are waiting on something else, and counting them held the queue: a
  6-core job using 5.6 CPUs was charged 12, more than the Mac, and ten jobs waited 23 minutes
  behind it with 4 CPUs idle.
- A lease held over ssh (`cpuq lease NAME --host HOST`) no longer outlives a dropped connection.
  The client sends a heartbeat down the connection every 10 seconds; the hold on HOST ends when
  its stdin closes or, once heartbeats have come, when they stop for a minute
  (`CPUQ_HOLD_QUIET`). This holds while it waits too: a waiting hold whose holder has gone gives
  up rather than taking the lease for nobody. Twice in a day a dropped connection left pup held
  or queued for nobody.

## 0.8.5 — 2026-10-07

- An `--exclusive` run (a quiet window, on `cpuq run` or a lease) opens beside jobs paused by
  hand: their processes are stopped, so the window stays quiet. It used to wait for their cores,
  so pausing a long job to let a timing run through deadlocked: on pup a timing window waited 30
  minutes behind a paused 12-core job while the machine sat idle.
- `cpuq start` on an exclusive waiter opens its window at once on the cores that are free,
  beside those still held. It used to do nothing.

## 0.8.4 — 2026-10-07

- Waiters no longer scan the processes while a quiet window (`--exclusive`) is held: nothing is
  admitted then, and each waiter's scan, twice a second, was kernel time taken from the
  benchmark the window is for.
- `exclusive = off` (config; on by default): `--exclusive`, on `cpuq run` or a local `cpuq lease`,
  runs as an ordinary job alongside the others instead of draining the machine, and says so on
  stderr; `cpuq status` notes it. On this Mac 46 exclusive timing runs in two hours left the CPUs
  mostly idle while everyone else queued: 89% of all waiting happened while one drained or held
  the machine. Timing runs go to a machine that allows them; `--host HOST` leases follow HOST's
  config.

## 0.8.2 — 2026-10-07

- Every job's peak memory is recorded: the most its processes used together, looked at every 2
  seconds, or for a job too quick to look at, the most any one of them held (the kernel's
  maxrss). It is `peak` (bytes) in `cpuq history --json` and a MEMORY column in `cpuq history`,
  so a label's real memory use can be read off its runs.
- A command's end is noticed within a tenth of a second (it was up to 2 seconds with
  `max_memory` set), so its cores go to the next job sooner.

## 0.8.1 — 2026-10-07

- `min_available` (config, off by default, e.g. `min_available = 6G`): admit nothing while the
  memory the kernel says is available falls under it (Linux MemAvailable; macOS the kernel's free
  share of memory, as `memory_pressure` prints it). The gate reads "closed: memory low (N GB
  available)", state `low_memory`. Linux's pressure gate reacts only once processes stall on
  memory, too late for a swap that fills (pup's 8 GB of swap kept filling under concurrent
  builds and benchmarks).

## 0.8.0 — 2026-10-07

- Measured admission, the new default (`admit = measured`): jobs are admitted by the CPU they
  ask of the machine, not by the cores they hold. A running job counts at its expected use
  from history for its first `settle` seconds (20), then at its measured demand: the larger of
  the CPU time it gets and the threads it has ready to run, so a job a contended machine slows
  still counts in full. The head starts when its expected use fits under `target` (the active
  CPUs) and the CPUs are not measured at 97% busy; one behind it starts when it fits and leaves
  the head room. Idle reservations no longer block anyone, so lending and an overbooked budget
  are not needed. Replayed on 42 hours of this Mac's jobs: mean wait about 1 s, against 223 s
  for the old budget of 10 and 15 s for 14 with lending.
- Without `--cores`, under measured admission the label's history picks the count (its 75th
  percentile of use plus 0.3, at most half the CPUs; 2 with fewer than three runs), and a range
  gives way toward its minimum when the CPUs are nearly full.
- `admit = cores` restores the reservation model (budget, lending, load valve, right-sizing).
- `cpuq status` names the admission in force; `--json` adds `admit` and `target`.
- Processes carry their runnable threads (macOS pti_numrunning; Linux state R).

## 0.7.14 — 2026-10-07

- Backfill behind an exclusive head: while a timing window waits for running work to drain, a
  waiter may use the free cores if its history says it ends before that work does (both run
  times known; no patience fallback, so the window is never delayed on a guess). A short timing
  check once waited 17 minutes behind one long job while 9 of the Mac's cores sat free and three
  jobs queued behind it.

## 0.7.13 — 2026-10-07

- On macOS the memory gate shuts at the kernel's critical level only, not at warn. Warn can last
  many minutes with half the memory free: it shut the gate for 8 minutes with 46-49% free and
  under 1 GB of swap in use, holding up to 4 jobs while the CPUs sat mostly idle. A runaway job
  is `max_memory`'s to stop.

## 0.7.12 — 2026-10-07

- On macOS a job started on lent cores keeps its scheduling class too. It ran at background QoS
  so that a lender getting busy again had its CPUs back at once, but on Apple silicon that held
  the whole job to the efficiency cores, with throttled I/O, for its entire run: on this Mac 29%
  of jobs started on lent cores, and Cpuq.app's Per CPU view showed the 6 efficiency cores
  pinned while the 4 performance cores sat partly idle. Linux keeps nice 15 for borrowers.

## 0.7.11 — 2026-10-07

- On macOS a normal-priority job keeps its scheduling class (high and normal alike; low still
  runs at background QoS, and so does a job on lent cores). It ran at utility QoS, which on
  Apple silicon keeps work mostly on the efficiency cores: four normal jobs took about 3 of the
  Mac's 6 efficiency cores while its 4 performance cores sat idle, and ran about 20% slower
  than at the default class. Cpuq.app's Per CPU view showed it. Linux keeps nice 5 for normal.

## 0.7.10 — 2026-10-06

- A lease taken `--exclusive` goes next: its claim on the machine's cores queues at the
  front (as `cpuq first` would put it), so the window opens once running work drains, not
  behind a stream of later arrivals. On pup, a 5-minute timing check waited over an hour
  behind other work and timed out.
- Work the holder of an `--exclusive` lease starts on that machine over ssh runs inside the
  window: a `cpuq run` whose CPUQ_LEASES names an exclusive lease held there starts at once
  (with the cores it asked for, at most), instead of queueing behind its own holder forever.
  Pass CPUQ_LEASES through ssh: `ssh HOST "CPUQ_LEASES='$CPUQ_LEASES' …"`.

## 0.7.9 — 2026-10-06

- `max_memory` (config, off by default, e.g. `max_memory = 16G`): a running job's cpuq watches
  the memory its command and descendants use, every 2 seconds, and stops the whole tree once
  it passes the limit (SIGTERM, then SIGKILL 10 s later), recording the job as stopped for its
  memory. Three runaway jobs (64, 42 and 63 GB) filled the Mac's swap on 2026-10-06 and shut
  the memory gate on every other job until they were stopped by hand.

## 0.7.8 — 2026-10-06

- `cpuq lease NAME --exclusive`: a named lease that is also a quiet window. Once it has the
  lease, it takes the machine's whole budget as running work drains, and holds both until it
  ends; nothing else is admitted meanwhile, while the lease's own command runs its `cpuq run`s
  inside. With `--host HOST --hold` the window is on HOST, so a script timing work over ssh
  keeps HOST quiet for as long as it holds the lease (the kit's pup-bench lease, for one).
- Fix: a job whose command line passed 1 KB (an inline script) had its child pid left unrecorded,
  so cpuq could not measure it, lend its idle cores, or pause or stop its process tree.

## 0.7.7 — 2026-10-06

- `cpuq status --json` gives the load valve's thresholds in `gate`: `trip` (the load above
  which it trips while the CPUs are busy), `reopen` and `busy_trip`, so a display can show how
  near the valve the load is. Cpuq.app 0.8.0 draws them.

## 0.7.6 — 2026-10-06

- Fix: a `--hold` lease released the way a script naturally does it (close
  its stdin, then kill it at once) was still often recorded as lost: the
  kill landed while cpuq was ending the hold, after it had stopped
  guarding against signals and before it logged the end. It now records
  the hold as ended normally, and at every step from queueing to the end a
  fatal signal leaves the job's next line in the history.
- Fix: a job ending gave its cores back one at a time before taking the
  admission lock, so a waiter could see it half released, some of its
  cores free while it still counted them: a wide request then took fewer
  cores than it should, and could report cores as lent that were not. The
  release now happens under the lock.

## 0.7.5 — 2026-10-06

- Fix: cpuq could panic (integer overflow) while it read another job's
  lease or ticket as that job was still writing it, the file growing
  between two of the reader's looks. A waiter that hit it died and was
  recorded as lost. Records are now read without a read-ahead buffer.

## 0.7.4 — 2026-10-06

- Fix: a job paused by hand and then killed by other means than `cpuq
  stop` left its pause marker behind, and an order (`cpuq first`) given to
  a waiter in the moment it started was never taken; both now go with the
  job.

## 0.7.3 — 2026-10-06

- A job killed while it waits (hangup, ^C, ^\ or SIGTERM) is recorded in
  the history as `gave up`, with the signal, and a `--hold` lease killed
  while held as ended by that signal, here and on the remote host. Both
  read as `lost` before, as if cpuq had crashed; `lost` now means a cpuq
  that died uncaught (SIGKILL, a crash) or a restart.

## 0.7.2 — 2026-10-06

- Fix: a range request (`--cores 1-2`) whose label had 44 or more runs in
  the history panicked with an integer overflow while right-sizing. The
  sample count was held in an integer too narrow for the percentile's index
  arithmetic.
- Fix: ^C (or ^\) at a terminal could reach the command twice. macOS can
  name the process that wrote the keystroke to a pseudo-terminal as its
  sender, and cpuq passed such a signal on; in the foreground of a terminal
  cpuq now leaves ^C and ^\ to the terminal, which delivers them to the
  command itself.
- `cpuq stop` ends the command's whole process tree, as `pause` stops it,
  not only its first process: a shell's children were left running.

## 0.7.1 — 2026-10-06

- Right-sizing: a range request is capped near what jobs with its label
  have used (the 75th percentile of their average active cores plus 0.3,
  rounded), once the label has three finished runs. A fixed count is never
  changed. Config: `right_size = on|off`.
- Lending only into spare CPUs: by the load and by the CPUs' measured busy
  share, so lending never pushes the load past the CPU count.
- Borrowers yield: a job started on lent cores runs at background priority
  (macOS QoS background, Linux nice 15), so a lender that gets busy again
  has its CPUs back at once.
- The load valve looks at the CPUs as well: it trips only when they are
  measured at least 90% busy, and reopens as soon as they fall below 75%,
  since the load average counts threads and lags a minute.
- A hand at the queue: `cpuq first|start|cancel` for a waiting job (move it
  to the front, start it now past the queue and gates, take it out), and
  `cpuq pause|resume|stop` for a running one (its whole process tree). A
  paused job's cores are lent at once; nothing touches an exclusive run;
  history marks a forced start, status a paused job.

## 0.7.0 — 2026-10-06

- `cpuq lease NAME --host HOST --hold`, with no command, holds a lease on
  another machine for a script: once granted it prints `held NAME@HOST
  ENTRY` (ENTRY is the `CPUQ_LEASES` entry runs inside need) and holds the
  lease until its stdin closes or it dies. A script can then hold one lease
  across a whole series of steps, from any point in its run; inside a hold
  of the same lease it holds nothing. The README shows the bash 3.2 idiom.

## 0.6.2 — 2026-10-06

- A run already waiting re-reads the config file when it changes, so a new
  budget or margin applies at once instead of only to runs started after
  it. An invalid file keeps the settings in force and says so.

## 0.6.1 — 2026-10-06

- Lending is no longer capped at the CPU count: only idle cores are lent,
  so the work running stays within the budget, and the load valve guards
  the rest. A budget equal to the CPU count can now lend too.

## 0.6.0 — 2026-10-06

- Lending: the head of the queue measures what each running job actually
  uses, and the cores a job has left wholly idle for a minute are lent to
  the head on top of the budget, up to the CPU count. The lender loses
  nothing; if it gets busy again, the load valve holds new admissions until
  the machine settles. A job started on lent cores says so, and history
  records how many (`"lent": N`). Config: `lend = on|off`,
  `lend_after = SECONDS`.

## 0.5.1 — 2026-10-05

- The load valve reopens sooner: once the load has stayed at or under
  budget + `load_margin`/2 (10 for a budget of 8) for 15 seconds, where it
  waited for the budget itself for 30. The 1-minute load lags, so the old
  rule kept free cores idle for a minute or two after a spike. Above the
  budget it still admits one job per 10 seconds.
- Work outside cpuq is measured by each process's own CPU. Counting the
  children a process reaps made a parent (launchd reaps every orphan) leap
  by a child's whole lifetime at once.

## 0.5.0 — 2026-10-05

- Backfill: a waiter behind the head starts at once on cores the head
  cannot use yet, taking what is free up to its maximum, when its minimum
  fits and nobody ahead of it may go first, and either history says it will
  be done before the head could start, or (without run times to judge by)
  the head has waited less than its patience: half its typical run, 30
  seconds to 5 minutes. After that, freed cores are kept for the head.
  Nothing goes ahead of an `--exclusive` head; named leases stay in order.
  A job that goes ahead says so and is marked `"ahead": true` in history.
  Config: `backfill = on|off`, `patience = SECONDS`.
- A head waiting for an exact count while fewer cores are free says once
  that a range (`--cores 2-3`) would start it now.

## 0.4.5 — 2026-10-05

- cpuq records which of the budget's cores each job holds, by number, and
  reports them: `slots` for each holder in `cpuq status --json`, and for
  each job in `cpuq history --json`. A job takes the lowest-numbered free
  cores, as it always has; Cpuq.app draws them as lanes.

## 0.4.4 — 2026-10-05

- A job's active cores on macOS no longer leap when it reaps a child: a
  child that has exited but not been reaped (a zombie) is invisible to
  proc_pidinfo, so its CPU dropped out of the job's tree and then returned
  all at once in the parent's reaped-children time. A 1-core job could show
  5 cores active, and a 4-core one 14. Zombies now count until reaped.

## 0.4.3 — 2026-10-05

- `cpuq status` fades the load averages with age: the 1-minute load bold and
  colored, the 5-minute plain, the 15-minute dim.

## 0.4.2 — 2026-10-05

- `cpuq status` shows the current (1-minute) load in bold, green under half
  the CPUs online, yellow up to one and a half times them, red beyond, with
  the 5- and 15-minute loads dim.
- Cpuq.app ships on its own: `brew install --cask shreeve/tap/cpuq-app`, or
  the `app-v*` releases; it updates itself through Sparkle (see app/README.md).

## 0.4.1 — 2026-10-05

- `cpuq status --watch` draws in place on the terminal's alternate screen,
  as `top` does: each refresh overwrites the last, nothing piles up in the
  scrollback (Terminal.app pushed every cleared screen there), the cursor is
  hidden, and ^C, a kill or a hangup puts the terminal back.

## 0.4.0 — 2026-10-05

- History: every job is recorded as it queues, starts and ends, outside
  `/tmp` so it outlives a reboot. `cpuq history [--label X] [--limit N]
  [--json]` lists how long jobs waited and ran, the cores they kept active
  (their CPU time, from the kernel) against the cores in use, and how they
  ended,
  including jobs lost to a killed cpuq or a restart; a summary says how to
  size `--cores`.
- On a terminal, `cpuq status` and `cpuq history` draw boxed tables in
  color: the gate and memory by state, jobs keeping under half their cores
  active in yellow, and cores in use per project. `cpuq status --watch`
  redraws in place.
- Status reads in two words: cores *in use* (handed out to jobs) and cores
  *active* (the CPU they keep busy). The JSON fields keep their names.
- `cpuq status` names the busiest processes outside cpuq when they add up to
  a core or more, or the gate is closed (`--json`: `outside`).
- Waiters get an ETA from the history's typical run times (`--json`: `eta`).
- `cpuq status --host HOST` shows another machine's queue over ssh;
  `--host local --host pup` shows both.
- A program that waits without `--max-wait` and without a terminal is told
  once that its own timeout may end the wait first.
- Cpuq.app (in `app/`, macOS 14+): a menu-bar meter, the chip filling a cell
  per quarter of the budget in use, with a menu of what runs, waits and
  holds leases, and a live view in Terminal.

## 0.3.0 — 2026-10-05

- Named leases: `cpuq lease NAME -- CMD` is a first-come, first-served lock
  on anything that is not cores (a benchmark machine, a database), with
  priorities, aging, `--max-wait`, `cpuq status`, and holds the kernel frees
  however their holder ends. `--slots N` lets N hold it at once. CMD gets
  `CPUQ_LEASES`, so a lease of the same name inside it starts at once.
- `cpuq lease NAME --host HOST -- CMD` holds the lease on HOST's cpuq over
  ssh while CMD runs here; ending, crashing or losing the connection gives it
  back. Pipelines that drive another machine and that machine's own work
  share one queue.
- `cpuq wait --label PATTERN` blocks until no matching job holds or waits.
- `cpuq status` lists the named leases with their holders and waiters, and
  `--json` adds `leases`.
- `--max-wait 0` takes what is free now and gives up at once otherwise; it
  used to give up before trying.

## 0.2.0 — 2026-10-05

- Elastic grants: `cpuq run --cores MIN-MAX` starts as soon as MIN cores
  are free and takes up to MAX of what is free, so cores no longer sit idle
  while a job waits for a fixed count. `CPUQ_CORES` and the make jobserver
  carry the grant. A wide request leaves the next waiter's minimum free.
  `--cores K` still asks for exactly K.
- `cpuq status` shows the cores each holder actually uses beside its grant,
  measured over its whole process tree (the short-lived compilers and test
  processes it starts included), and each waiter's request as MIN-MAX.
  `--json` adds `using` to holders and `max` to waiters.

## 0.1.0 — 2026-10-05

The first release: one binary for macOS (arm64, x86-64) and Linux (x86-64,
arm64, static), no daemon.

- `cpuq run [--cores K] [--priority high|normal|low] [--exclusive] [--label
  TEXT] [--max-wait S] -- CMD` waits its turn for K cores out of a
  machine-wide budget (default: the active cores minus 2), then runs CMD in
  the foreground: stdio inherited, signals passed on the way a shell does,
  the exit status passed through.
- Every hold is a `flock(2)` on a file in `/tmp/cpuq-UID`, so the kernel
  frees it when its holder dies, however it dies. A SIGKILLed cpuq leaves its
  cores with the running command until the command ends.
- Strict order within a priority, no backfill, and aging that promotes a
  waiter one class per 10 minutes, so nothing starves. `--exclusive` drains
  the machine for a benchmark and holds it for the length of the command.
- Gates on memory pressure and a load safety valve with hysteresis, so
  waiters never stampede into a lagging load average.
- CMD gets `CPUQ_CORES`, a GNU make jobserver in `MAKEFLAGS` (make 3.81 and
  4.x), and a scheduling class from its priority: macOS QoS, Linux nice.
- `cpuq status [--json]`, `cpuq budget`, `cpuq qos`.
- Install with `install.sh` or `brew install shreeve/tap/cpuq`.
