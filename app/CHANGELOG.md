# Changelog

User-visible changes to Cpuq.app, the menu-bar companion. Each version's section is its release
notes, shown by the update dialog too.

## 0.13.5 — 2026-10-08

- A right click on the last hour offers Clear Prior Data, which forgets what the window shows
  from before the moment under the pointer, and Keep Only the Last 5 Minutes. cpuq's history
  is untouched.

## 0.13.4 — 2026-10-07

- Running jobs line up at the left of the job list with the waiting ones; with a job waiting,
  they had been pushed toward the middle.
- The hour's columns are pinned to the clock, each covering the same seconds from one refresh to
  the next, so a short wait no longer flickers between rose and blank as the columns shift.
- The wait strip lines up with the chart above it: every chart in the card has labels of one
  width, so their plots start at the same point (Per core's had been far out of line).

## 0.13.3 — 2026-10-07

- A stretch of needless waiting one column long fills rose like any other, rather than showing
  only its top edge.

## 0.13.2 — 2026-10-07

- No line from the waiting tray to the cells: the tray and the rose cells say it already.
- A stretch of needless waiting that began and ended in the same minute reads "7 min ago", not
  "7–7 min ago".

## 0.13.1 — 2026-10-07

- The Per core lanes call the fast cores Performance, as most people do, not by the name macOS
  gives them on this chip (Super).

## 0.13.0 — 2026-10-07

A new Now tab, from the "Beautiful and alive" design.

- The CPUs busy right now, large ("8.4 / 10"), with two verdicts: working at full capacity,
  partly busy or quiet; and nobody waiting, a fair wait (the CPUs are full) or a needless one
  (CPUs idle while jobs wait), with the longest wait.
- The Mac's ten CPUs as glass cells that fill with each project's color, then other work, with a
  gentle wave on the surface. Jobs waiting sit in a tray beside them and flow toward the first
  free cell; when they wait beside idle CPUs, the empty glass glows rose and says so. A right
  click on a waiting job moves it to the front, starts it or cancels it.
- The last hour on the same 0-to-10 scale: stacked by project, a white line along each band, or a
  lane per CPU (performance cores above efficiency cores). Rose marks where jobs waited while
  CPUs sat idle, with how many and for how long; a strip under it counts who waited, grey when
  the wait was fair. Pointing at any moment replays it in the cells. The time axis is even.
- Every job in one list: the CPU it uses, the cores it holds, how long it has run, and for each
  waiting job what it asks for and why it waits. More than fit scroll inside the list.
- The toolbar shows cpuq's gate, memory pressure and the load.
- Gone: the reserved-core lanes, the four view toggles, the key, the project table and the
  uneven time axis.
- A project's color is reassigned when another on screen shares it.
- The project colors follow the design, in its order (blue, green, purple, orange, teal), which is
  also the stacking order; em, nexis, emdb, rig and cpuq take them, and other projects keep the
  color they had where the palette still has it. Busy cells bubble gently and glow underneath.

## 0.12.0 — 2026-10-07

Under cpuq 0.8's measured admission, every view now speaks of the Mac's real CPUs; what cpuq
reserves for jobs (it hands out more than the Mac has, since idle reservations cost nothing) is
a detail.

- The top line leads with the CPUs busy: "8.4 of 10 CPUs busy · 6 jobs · 1 waiting".
- Stacked is the CPU each project keeps busy, on the Mac's own scale: no reserved-but-idle cores
  piled on top, and a job not yet measured counts for nothing rather than for what it reserved.
- Lanes become Jobs: one row per job, solid while it keeps a CPU busy, pale while it idles, so
  there are only as many rows as jobs ran at once, never one per reserved core.
- The job table shows what each project reserves and the CPUs it keeps busy, without the
  efficiency ratio, which no longer costs anyone anything.

## 0.11.0 — 2026-10-07

- The window keeps the size you give it, and everything in it always fits: nothing scrolls and
  nothing is cut off at the bottom. The charts share the height there is, compressed alike
  when the window is short (it goes no shorter than they can take); the lanes and the stacked
  chart number fewer lines when they are squeezed.
- The table of jobs is always five rows tall, so the charts never jump as jobs come and go;
  more than five scroll inside it.
- The window remembers its size and place.
- Brown is gone from the project colors (pale, it read as the gate shut); a lime takes its
  place.

## 0.10.0 — 2026-10-07

From a design review of the window, and for cpuq 0.8's measured admission.

- The views scroll when the window is too short for all of them, so the top line and the toggles
  always show; given room, the stacked chart and the lanes share it.
- The key lists only what the views on screen draw (and no valve when there is none, no borrowed
  cores under measured admission).
- Past 16 lanes, every fourth is numbered, so their labels no longer pile up.
- Shut stretches close together share one name.
- Under cpuq 0.8's measured admission the budget limits nothing: Stacked marks the CPUs alone,
  and the lanes show each job on its own cores (nothing is lent).
- The line under the verdict is empty until there is something under the pointer.
- A gate shut by cpuq 0.8.1's `min_available` (memory low) is shaded and named like memory
  pressure.

## 0.9.1 — 2026-10-07

- Stretches the gate was shut are named only where there is room: the start of one at least
  four columns wide, well clear of the last name, so two close together no longer print over
  each other.

## 0.9.0 — 2026-10-07

- Per CPU, a new view (off until you turn it on at the top right): every one of the Mac's CPUs
  as a thin row over time, darker the busier, the performance cores on top and the efficiency
  cores under them. Pointing at a cell names the CPU and how busy it was. It shows what All
  CPUs adds up: whether the work lands on the fast cores, or which ones sit idle.

## 0.8.3 — 2026-10-06

- With a budget over the CPU count (cpuq handing out more cores than the Mac has, since held
  cores are partly idle), All CPUs no longer prints the budget's label above its top, over the
  hint line: its ceiling is the CPUs, labelled so. Stacked leaves out the tick numbers beside
  its budget and CPU lines, where they ran into those lines' labels.

## 0.8.2 — 2026-10-06

- No more stripes: a held but idle core is a pale tint of its project's color (a little
  stronger than before 0.8.0, so it never reads as a free core), filling in as it gets busy.
- Orange, cyan and mint are back among the project colors; only red and pink stay out, since
  red means waiting.

## 0.8.1 — 2026-10-06

- Back to the bright system colors for projects, as before 0.8.0, still without red, orange,
  pink, teal or cyan (red and orange mean waiting and a shut gate; teal and cyan sit too near
  blue), and still assigned so the projects on screen together never share one.
- The top line fits: memory shows only when its pressure is high, CPUs read as a bare
  percentage, and the line shrinks a little before it would cut off.
- The waiting row counts jobs again ("waiting jobs"), its bars hanging down from the line, with
  the bare number under each stretch wide enough to hold it, so the counts no longer collide;
  pointing at it names who waited and for how many cores.
- "1 core", not "1 cores".

## 0.8.0 — 2026-10-06

A redesign from three reviews of the window (visual design, prior art, and the questions it is
opened to answer). If it reads worse than 0.7.2, it goes back.

- The top line always says whether cpuq is admitting work: "● admitting", or "● gate shut:
  memory pressure for 5m" with the reason, then cores in use and active, who waits, the load
  against the load valve's trip level, how busy the CPUs are, and memory pressure. What is under
  the pointer goes on a line of its own below it instead of replacing it.
- Stretches the gate was shut (by memory pressure or the load valve) are shaded across every
  view and named where they start, so a wait inside one explains itself.
- All CPUs adds the 1-minute load as a line, the valve's trip level dashed, and a red edge while
  memory pressure is high (needs cpuq 0.7.7 for the valve line).
- Held but idle cores are striped in the project's color instead of pale, so waste stands
  apart from free cores; in the lanes a core fills in as far as its job keeps it busy.
- Stacked puts every project's busy cores first, from the floor, and the idle ones above, so
  the busy total reads off one edge and the waste sits on top; other work is left to All CPUs.
- Waiting shows the cores the waiting jobs ask for, hanging down from the line.
- New project colors: distinct hues with no red or orange (which mean waiting and a shut gate)
  and only one blue, assigned so the projects on screen together never share one. The key
  draws states in grey.
- The table's Share is now Efficiency.

## 0.7.2 — 2026-10-06

- The Mac strip is now called All CPUs and leads the page: the views run from widest to
  narrowest, all the CPUs (cpuq's jobs and other work), cpuq's cores by project, which cores,
  and who waits, with the time labels under the waiting row.

## 0.7.1 — 2026-10-06

- More room between the views: a clear gap under the stacked chart and under the lanes, so the
  stacked chart's 0 no longer meets the top lane's 10 and each view reads as its own.

## 0.7.0 — 2026-10-06

- One page instead of a switch: the stacked chart on top, the lanes under it, then the waiting
  row and the Mac strip, all over one time axis, with one pointer line through them all. Each
  of Stacked, Lanes and Mac can be turned off at the top right (remembered); the waiting row
  always shows. Pointing at the Mac strip says how many CPUs cpuq's jobs and other work kept
  busy then.

## 0.6.0 — 2026-10-06

- Jobs can be handled from the app (with cpuq 0.7.1 or later). In the menu, each running job has
  Pause or Resume and Stop, and each waiting job has Move to Front, Start Now and Cancel. In the
  graphs window, right-click a running job's cores, or a waiting job in the table. Start Now
  (past the budget, so the load goes up) and Stop (its work is lost) ask first.
- A paused job says so in the menu.
- Work over the budget whose lenders have finished is drawn on a free lane, not past the budget.

## 0.5.0 — 2026-10-06

- Lent cores are drawn where they really run. When cpuq lends a job's idle cores, the work over
  the budget no longer shows as extra lanes past the budget, which the Mac does not have: it is
  drawn on the lender's idle cores, in the borrower's color with an edge in the owner's color.
  Pointing at one says whose core it is and who has borrowed it.

## 0.4.3 — 2026-10-06

- When the budget is the CPU count, the chart draws one line, "budget 10 = CPUs", instead of
  two labels on top of each other.

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
