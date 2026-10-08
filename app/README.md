# Cpuq.app

The cpuq menu-bar companion for macOS 14 and later on Apple silicon.

- **The chip** in the menu bar fills a cell per quarter of the core budget handed out (none when
  idle, all four when the budget is full).
- **The menu** shows what runs (cores in use and active), what waits and when it should start,
  the named leases, and any load outside cpuq. Each running job has Pause or Resume and Stop, and
  each waiting job Move to Front, Start Now and Cancel. **Open Live View in Terminal** (⌘L) runs
  `cpuq status --watch`.
- **Show Graphs** (⌘G) opens a window on the Mac's active CPUs. Its **Now** tab leads with the
  CPUs busy right now ("8.4 / 10") and two verdicts: whether the Mac is working at full capacity,
  and whether anyone waits, fairly (the CPUs are full) or needlessly (CPUs sit idle while jobs
  wait, the one case worth hunting). Beside them, a glass cell per CPU fills with each project's
  color, then other work; the jobs waiting sit in a tray, and when they wait beside idle CPUs the
  empty glass glows rose.
- **The last hour**, under them on the same scale, is **Stacked** by project (⌘1) or **Per Core**
  (⌘2), a lane per CPU with the performance cores above the efficiency cores, with rose where
  jobs waited while CPUs sat idle and a strip of how many waited. Pointing at any moment replays
  it in the cells.
- **Every job** comes last: the CPU it uses, the cores it holds, how long it has run, and for each
  waiting job what it asks for and why it waits. A right click offers the menu's job actions.
  The toolbar shows cpuq's gate, memory pressure and the load.
- **The History tab** sums `cpuq history` per project.

The app only reads `cpuq status --json` (every 3 seconds) and `cpuq history --json`, so cpuq
works the same with or without it. It finds cpuq where install.sh and Homebrew put it
(`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`), since an app does not inherit a shell's
`PATH`.

## Install

    brew install --cask shreeve/tap/cpuq-app

or download `Cpuq-X.Y.Z.zip` from the latest `app-v*` release and move Cpuq.app to
`/Applications`. It updates itself in place (Check for Updates in its menu, and a daily check).

## Building

Swift 6.2 or later (Xcode 26 or its command-line tools):

    swift build && swift test             # CpuqCore's unit tests
    scripts/package-app.sh                # .build/Cpuq.app, signed; CONFIG=release for a release build
    open .build/Cpuq.app

Every build is signed with the Developer ID `Developer ID Application: Steve Shreeve
(SD6N7Z8P9P)`, inner pieces first, with the hardened runtime; `SIGN=-` signs ad hoc on a Mac
without it, and such a bundle runs only where it was built. Sparkle (2.10, a Swift package) is
embedded at `Contents/Frameworks`, thinned to arm64 without its headers. The updater runs only
from a bundle, so a binary run from the build folder never offers to replace itself. The icon is
`../assets/cpuq-icon.svg`; the menu-bar chip is drawn in code from the geometry of
`../assets/menubar/cpuqTemplate-N.svg`.

## Updates

Sparkle reads one fixed feed, `appcast.xml` on the release **`cpuq-app-updates`**, which also
holds every archive on the feed. It is a prerelease and never the latest release, so
`/releases/latest` stays the CLI's and `install.sh` and the formula never see it. Each version
also gets its own release, `app-vX.Y.Z`, holding `Cpuq-X.Y.Z.zip` for the cask and for people,
likewise never the latest.

Two signatures, for two jobs: Gatekeeper accepts the app because it is signed with the Developer
ID and notarized, with the ticket stapled into the bundle; Sparkle accepts an update when its code
signature is valid and its EdDSA signature matches `SUPublicEDKey` in the installed copy.

Setting up the signing keys and cutting a release are described in
[docs/RELEASING.md](../docs/RELEASING.md#cpuqapp).
