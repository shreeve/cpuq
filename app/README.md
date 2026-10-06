# Cpuq.app

The cpuq menu-bar companion for macOS 14 and later. The chip in the menu bar
fills a cell per quarter of the core budget in use (none when idle, all four
when the budget is full); its menu shows what runs, what waits and for how
long, the named leases, and any load outside cpuq. **Open Live View in
Terminal** runs `cpuq status --watch`.

It only reads `cpuq status --json` every 3 seconds, so cpuq works the same
with or without it. It finds cpuq where install.sh and Homebrew put it
(`~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`), since an app does not
inherit a shell's `PATH`.

Build and run (Xcode 27 or its command-line tools):

    swift build -c release
    .build/release/Cpuq &

`CpuqCore` (decoding the status, the meter rule) has unit tests:
`swift test`. The icon is drawn in code from the geometry of
`../assets/menubar/cpuqTemplate-N.svg`.
