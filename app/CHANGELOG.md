# Changelog

User-visible changes to Cpuq.app, the menu-bar companion. Each version's section is its release
notes, shown by the update dialog too.

## 0.1.2 — 2026-10-05

- The live charts are smooth: they average the 3-second samples over 30 seconds and draw soft
  (monotone) curves through them, so a brief job or a one-poll spike blends into its neighbours
  instead of drawing a spike, and nothing overshoots below 0 or above a real peak.

## 0.1.1 — 2026-10-05

- In use by project stacks at every moment: a project that stops drops to 0 at once, where it
  sloped down to the next sample that named it, and both live charts share one time axis.
- Cores in use step from one value to the next, as cores are handed out.
- History draws each project's active cores over its cores in use, from 0, instead of after
  them, with the figures past both bars ("1 job", not "1 jobs").
- With cpuq 0.4.4 the active line no longer leaps when a job reaps a finished child.

## 0.1.0 — 2026-10-05

The first release, for macOS 14 and later on Apple silicon.

- A chip in the menu bar fills a cell per quarter of the core budget in use.
- Its menu lists what runs (cores in use and active), what waits (with an ETA), the leases, and
  any load outside cpuq, and opens the live view, `cpuq status --watch`, in Terminal.
- Show Graphs: the last hour of cores in use, active and load against the budget, in use by
  project, and from `cpuq history`, each project's active cores against its cores in use and
  the latest waits.
- Signed with a Developer ID and notarized; updates itself in place (Check for Updates).
