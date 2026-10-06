# Changelog

User-visible changes to Cpuq.app, the menu-bar companion. Each version's section is its release
notes, shown by the update dialog too.

## 0.1.0 — 2026-10-05

The first release, for macOS 14 and later on Apple silicon.

- A chip in the menu bar fills a cell per quarter of the core budget in use.
- Its menu lists what runs (cores in use and active), what waits (with an ETA), the leases, and
  any load outside cpuq, and opens the live view, `cpuq status --watch`, in Terminal.
- Show Graphs: the last hour of cores in use, active and load against the budget, in use by
  project, and from `cpuq history`, each project's active cores against its cores in use and
  the latest waits.
- Signed with a Developer ID and notarized; updates itself in place (Check for Updates).
