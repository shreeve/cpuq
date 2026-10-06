# Cpuq.app

The cpuq menu-bar companion for macOS 14 and later on Apple silicon. The chip in the menu bar
fills a cell per quarter of the core budget in use (none when idle, all four when the budget is
full). Its menu shows what runs (cores in use and active), what waits and when it should start,
the named leases, and any load outside cpuq. **Show Graphs** (⌘G) opens a window with the last
hour as two stacks of one band per project: the cores in use against the budget, and the cores
active with the machine's load over them, averaged over 30 seconds. From `cpuq history` it shows
each project's active cores against its cores in use and the latest waits. **Open Live View in Terminal** runs `cpuq status --watch`.

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

### One-time setup

- The Developer ID and the notarytool keychain profile `notary-tool` are the ones Shotts,
  Transfer and DuckTable use:

      security find-identity -v -p codesigning   # lists "Developer ID Application: Steve Shreeve (SD6N7Z8P9P)"
      xcrun notarytool history --keychain-profile notary-tool

- The update key is an ed25519 key of Cpuq's own, under the keychain account `cpuq` (Shotts uses
  `shotts`, DuckTable `ducktable`, Transfer the default account; never delete or export a key by
  service alone, which would take them all). Its public half is `Support/sparkle-public-key.txt`
  and `SUPublicEDKey` in `Support/Info.plist`. The tools are in `.build/artifacts` after a build:

      bin=$(find .build/artifacts -type d -path '*Sparkle/bin' | head -1)
      $bin/generate_keys --account cpuq -p                      # must print Support/sparkle-public-key.txt
      $bin/generate_keys --account cpuq -x /tmp/cpuq-key        # export, to back it up; then rm /tmp/cpuq-key
      $bin/generate_keys --account cpuq -f /tmp/cpuq-key        # import it on another Mac

  Keep a backup of the private key in a password manager. Losing it strands every installed copy
  on its version, since an app trusts only the key it shipped with; anyone who has it can sign an
  update every installed copy will accept.

## Releasing

Add the version's `## X.Y.Z — date` section to `CHANGELOG.md` (it is the release notes, and what
the update dialog shows), land it on `main`, then:

    scripts/release.sh X.Y.Z --dry-run   # builds, notarizes, staples, zips and signs the feed; publishes nothing
    scripts/release.sh X.Y.Z             # publishes app-vX.Y.Z and refreshes the cpuq-app-updates feed
    scripts/update-cask.sh X.Y.Z         # opens the tap's pull request for the cask; merge it

The release refuses to run without the Developer ID, the notary profile, a keychain key that
matches `Support/sparkle-public-key.txt`, or the changelog section; a real release also needs a
clean `main` in step with `origin/main`, a signed-in `gh`, and a version higher than the last
`app-v*` tag. Versions only go up: Sparkle orders updates by `CFBundleVersion`, which the release
sets to the version. A bad release is fixed by a higher one; deleting a release rolls no one back.
