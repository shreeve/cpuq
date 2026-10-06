# Changelog

User-visible changes to Cpuq.app, the menu-bar companion. Each version's section is its release
notes, shown by the update dialog too.

## 0.2.1 — 2026-10-05

- The chart labels its own lines and bars: the active line ends in "4.2 active", the dotted one
  in "0.5 outside cpuq" (when there is any), and the latest red bar says how many wait. The key
  under the chart is gone.
- The hour is full from launch: the cores in use and the waits before the app started come from
  `cpuq history`. History records no measurements, so the active lines start at launch.
- The table's columns have fixed widths, so its numbers no longer shift as they change.
- Pointing at an empty part of the chart shows the present, not the nearest sample.

## 0.2.0 — 2026-10-05

The graphs window, redone to read at a glance.

- Now leads with one line: cores in use of the budget, cores active, how many wait, and the load.
- One chart instead of two: the cores each project has in use as stacked steps (cores are handed
  out whole) against the budget, the cores active in cpuq's jobs as one line, those active
  outside cpuq as a dotted one, and a red bar above the budget while anyone waits.
- The time axis shows the whole hour with the recent past wide on the right and the older past
  narrow on the left: the last minute takes an eighth of the width, the last 15 minutes half.
- Under the chart, a table of what each project has in use now, how much of it is active (the
  share), and who waits for how many cores and how long. It is the legend too.
- Pointing at the chart shows that moment in the top line.
- A project keeps its color for good, assigned when first seen; colors no longer shift as
  projects come and go.
- History is a table per project: jobs, core-hours in use and active, the share active, the
  median and longest wait.
- Gone: the second chart, the shading, the load line (load is a number in the top line, as it
  counts waiting threads rather than CPU) and the History charts.

## 0.1.4 — 2026-10-05

- Each project's band of cores in use is shaded along time by how busy those cores are: its own
  color where cores active match cores in use, lighter toward idle, darker toward twice as busy
  (more threads than cores).
- The menu's status lines are in full color, not grayed out, and open the graphs when chosen.

## 0.1.3 — 2026-10-05

- The live tab is two charts, each a stack of one band per project in the same colors: the cores
  in use against the budget, and the cores active with the machine's load as one dashed line over
  them. Nothing is drawn over anything else.
- Projects get distinct colors (a dozen before any repeats).

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
