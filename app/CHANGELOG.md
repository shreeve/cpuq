# Changelog

User-visible changes to Cpuq.app, the menu-bar companion. Each version's section is its release
notes, shown by the update dialog too.

## 0.4.2 — 2026-10-05

- Right-click the chart to clear what is older than the point clicked, or to keep only the last
  5 minutes. It trims only what the window shows (cpuq's history is untouched), and holds after
  a relaunch.

## 0.4.1 — 2026-10-05

- The waiting row turns orange when cpuq's gate (the load valve, memory pressure or spacing)
  is why jobs wait, rather than a full budget, and the top line says "gate shut".
- A key under the chart names each mark: free, held and idle, busy, held but not measured,
  waiting, waiting with the gate shut.
- Work outside cpuq is capped at what the CPUs can do, so one bad reading cannot flatten the
  chart; the waiting row sits lower, clear of the counts above it.
- The release build uses only the cores cpuq granted it.

## 0.4.0 — 2026-10-05

- Two views of the same hour, switched with Lanes | Stacked at the top right (remembered):
  - Lanes: one lane per core of the budget, and under the waiting row a strip of the Mac's CPUs
    busy, cpuq's jobs dark and other work grey, against the budget and the CPU count.
  - Stacked: each column's cores stacked by project, solid where busy and pale where held but
    idle, other work grey on top, with the budget and the CPU count marked.
- Every column is the same width; how long it lasts sets the squeeze (5 seconds for the last 2
  minutes, then 15 and 30 seconds, and a minute beyond half an hour), so nothing changes shape.
- A stretch a job ran before the app watched it is a thin bar, not idle; once the job ends, its
  average from history fills it in.
- The menu no longer leaves blank rows: while it is open, its lines are retitled in place, and
  any added or removed wait until it closes.

## 0.3.1 — 2026-10-05

- The lanes' columns are fixed stretches of the clock (5 seconds for the last 2 minutes, then 15,
  30 and 60 seconds further back), so a column shows the same thing from one refresh to the
  next: the picture only slides left and narrows, merging columns as they age, instead of
  changing shape.
- The waiting row is a bar as tall as the count, one, two or three and more, with the count
  written once over each stretch of more than one.
- Pointing at a moment adds cpuq's cores in use and active and the load then.

## 0.3.0 — 2026-10-05

The graphs window shows the budget's cores as lanes.

- One lane per core, and time cut into columns: each cell is empty while that core is free,
  pale in the project's color while a job holds it, and solid while it is busy. A job keeps its
  lowest cores busy first, so 2.5 active of 4 is two solid cells, one half, one pale.
- With cpuq 0.4.5 and later, a lane is the very core cpuq handed out; with an older cpuq, the
  window places each job on the lowest cores free when it started.
- A waiting row under the lanes: red while anyone waits, with the count when more than one.
- The time axis spans what there is to show, 5 minutes to an hour, nearly even near now and
  squeezed toward the left, with ticks at round ages.
- Pointing at a cell names the job holding that core then, its cores, how busy it was and how
  long it ran; pointing at the waiting row names who waited. Either way the line ends with the
  machine then: cpuq's cores in use and active, and the load (for any moment the app watched).
- The lines and the stacked steps are gone; the top line still gives the totals now.

## 0.2.2 — 2026-10-05

- Every red bar wide enough to hold it says how many waited at once ("2 waiting").
- The active and outside lines are smooth curves, averaged over at least 15 seconds, instead of
  jittering with each 3-second reading; the cores in use stay exact steps.

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
