# Cpuq.app

The cpuq menu-bar companion for macOS 14 and later on Apple silicon: a chip in the menu bar, and
a window with a page per machine.

## The chip and its menu

The chip fills a cell per quarter of the core budget handed out. It stays calm while all is well,
turns orange while cpuq's gate is shut or jobs wait beside idle CPUs, is struck through while cpuq
cannot be read, and shows "☁ 23m" while a cloud machine runs.

Its menu has the app's and cpuq's versions, one line of how it stands ("6 of 10 cores in use · 2
waiting"), a line for each thing wrong (only then), and **Open Cpuq** (⌘G), **What's Happening?**,
**Settings…**, **Check for Updates…** and **Quit Cpuq**. While the window is open the app is an
ordinary one, with a Dock icon and a menu bar; closed, only the chip remains.

## The window

One page per machine: this Mac, then each remote in cpuq's config (`remotes`, started with
`remote_start.HOST` when it is a cloud machine). ⌘1 to ⌘9 pick a page, ⌘T the next theme, ⌘M
Automatic, Light or Dark. A stopped cloud machine's page offers to start it. Each page, top to
bottom, its sections' heights dragged to taste:

- **Right Now:** a glass cell per CPU, filled with each project's color, then other work; the jobs
  waiting sit in a tray beside them, and when they wait beside idle CPUs the empty glass glows
  rose. cpuq's gate, memory and the load sit at the right.
- **Last Hour:** stacked by project and per core (a lane per CPU, performance cores above
  efficiency cores) on one time axis, with rose where jobs waited while CPUs sat idle and a strip
  of how many waited. Pointing at a moment replays it in the cells. A right click forgets what is
  older than that moment, or than five minutes ago.
- **Jobs:** each running job's progress, CPU of the cores it reserved, and how long it has run. A
  right click pauses or resumes it, or stops it; a waiting job moves to the front, starts now or
  is cancelled. Stop, Start Now and Cancel ask first.
- **History:** `cpuq history` summed per project.

**View ▸ Open Live View in Terminal** (⌘L) runs `cpuq status --watch`. Theme ▸ Visual Effects
turns off the moving water and bubbles; they run at ten frames a second while the window shows
and the Mac is not strained, thirty while the mouse moves in it.

## Notifications and texts

Once each time it happens and lasts, on any machine watched: cpuq's gate shut (30 seconds), jobs
waiting beside idle CPUs (a minute), --opaque jobs holding cores while others wait (2 minutes),
heavy work outside cpuq (3 minutes), a job that looks stuck or a machine overloaded while another
has room (10 minutes), and a cloud machine up with nothing to do (15 minutes), with a button to
stop it. A stuck job, an overloaded machine, idle --opaque jobs and an idle cloud machine are also
texted, at most once every 30 minutes, with `~/bin/send-imessage` (the `textCommand` default)
when it is there. **What's Happening?** says what is wrong now, then
what was found in the last hour, each with its age; a text that failed to go shows there too.

**Settings** shows or hides the chip, keeps the Dock icon always, turns notifications and texts on
or off, and opens the app at login.

## What it runs

cpuq works the same with or without the app. The app runs:

- `cpuq status --json` every 3 seconds while the window is open and every 10 while it is closed;
- `cpuq history --json`, and `cpuq samples` once for the last hour when status says the recorder
  runs;
- `cpuq first`, `start`, `cancel`, `pause`, `resume` and `stop` from the Jobs actions;
- the same over `ssh -o BatchMode=yes HOST` for each remote while the window is open, each cloud
  machine once a minute while it is closed, and `journalctl --list-boots` there for its hours
  this month;
- a cloud machine's `remote_start.HOST` command, the `stop` beside it from a notification's Stop
  button, and the text command.

It finds cpuq where install.sh and Homebrew put it (`~/.local/bin`, `/opt/homebrew/bin`,
`/usr/local/bin`), since an app does not inherit a shell's `PATH`.

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
