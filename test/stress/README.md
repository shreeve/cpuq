Stress harnesses for the signal races fixed in cpuq 0.8.7. Each repeats one narrow race many
times, so a regression shows as a count rather than a rare CI failure. Not part of
`test/run.sh`: run them by hand, old binary against new.

Run each inside `nice cpuq run --cores 1 --qos none --label cpuq:test -- ...`.
`CPUQ=path` picks the binary; the first argument is a scratch directory.

- stress_waiter.sh DIR N: SIGTERM a waiter the moment its ticket shows; counts gave_up/lost.
  0.8.4: 4 lost of 300; 0.8.6: 2 of 150. 0.8.7: 0.
- stress_release.sh DIR N: a --hold lease that waited behind another waiter (2 threads),
  closed and killed at once (the kit's release); counts ended/lost. 0.8.7: 125 of 125 ended.
  The harness itself can deadlock on its fifo (a round's background open of `in$i` never
  returns, on any cpuq version); if `out$i` never appears, stop it and count what finished.
- stress_pause.sh DIR N: pause a run as soon as it can be; counts commands that never stopped.
  0.8.6: 15 of 150 still running. 0.8.7: 0 of 150.
- stress_int.sh DIR N: kill -INT a `cpuq run` at random moments after exec; reports hangs.
- loop.sh TEST N [TIMEOUT]: run one e2e test N times, sampling any hung cpuq.
- trapwin3.py N: INT aimed at the moment /bin/sh sets its trap; 2 of 4000 hung (bash 3.2 SIG_IGN window).
- stopwin.py N: SIGSTOP in the first 6 ms of `sh -c 'sleep 20'`; 115 of 400 lost.
- termwin.py N: SIGTERM in the same window; 0 of 400 lost.
- selfint.py DIR N [P] [ign] [dfl]: t_exit_status's `cpuq run -- sh -c 'kill -INT $$'` from
  python, N times, P at once; counts cpuq's ends (-2 right). Under load: 4600 of 4600 -2, no
  race. `ign` (started as a `&` job is): 600 of 600 end 0, as the suite once failed; `ign dfl`
  (the test since its fix resets SIGINT): 600 of 600 -2.
