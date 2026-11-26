# Cutting a machine over to the pool

How to move a machine from block grants (0.29 and earlier) to the pool. It is a one-time job, done
by hand with Steve's yes. There is no compatibility layer, so the client and its remotes switch in
one sitting: an old cpuq refuses `-n`, and a new one refuses `--cores`.

## Before

1. **The projects' edits are ready** (CHANGELOG, "Unreleased": Rig, Trig, Rip's swarm, Em/emdb,
   Nexus's pack recipe). Each lands right after its machines switch. Tell each session the time.
2. **A release binary per machine,** built from the release tag on that machine (or the release's
   tarball): `zig build -Doptimize=ReleaseSafe`, then `bin/cpuq --version`.
3. **Old work drained.** Old and new pools are separate files: the new one lives in
   `$CPUQ_DIR/v2/`, so an old run still holding cores beside new runs would let both hand out the
   same CPUs. On each machine, wait until the old cpuq shows no holders and no waiters
   (`cpuq status`), or `cpuq wait --label '*' --max-wait 3600`. Work outside cpuq doesn't matter
   here (the new pool measures it as outside load).

## Each machine

The order is burst, pup, then pop, minutes apart, in one sitting.

### 1. Keep the old binary and config

    cp ~/.local/bin/cpuq ~/.local/bin/cpuq.$(cpuq --version | cut -d' ' -f2)
    cp ~/.config/cpuq/config ~/.config/cpuq/config.before-pool

### 2. Edit the config

Remove the keys the pool has no use for; cpuq refuses each, with what replaces it:

| machine | remove | keep |
|---|---|---|
| burst | `admit`, `cpu_weights`, `exclusive` | (add `budget = 94` to keep two CPUs for logins, else the pool is all 96) |
| pup | `max_memory` (use `cpuq cap --mem`), `window_gap`, `window_lend`, `window_backfill`, `cpu_weights` | `min_available` |
| pop | `admit`, `target`, `active_cap`, `load_check`, `lend_after`, `patience`, `max_memory`, `exclusive` | `pressure_check`, `remotes`, `remote_start.*`, `remote_env.*`, `submit_roots`; set `budget = 10` (14 is more than the Mac has) |

On pop, `~/.config/cpuq/packs.json`'s build recipes say `-j"$CPUQ_CORES"`, which no longer
exists: make them `-j1` (a build is one task on one CPU).

### 3. Stop the 0.29 agent

    launchctl bootout gui/$UID/com.github.shreeve.cpuq.agent      # pop
    systemctl --user disable --now cpuq-agent                       # pup

burst runs none. The recorder (`com.github.shreeve.cpuq.record`) stays.

### 4. Install and check

    install -m 755 bin/cpuq ~/.local/bin/cpuq
    cpuq --version
    cpuq status                                  # the pool, no errors from the config
    cpuq run -- true; echo $?                    # 0
    cpuq run -n 8 -- sh -c 'echo $CPUQ_TASK'     # 8 of 8 passed
    echo '{"tool_input":{"command":"zig build"}}' | cpuq hook; echo $?   # refused (2), with the fix

On pop also check the remotes once all three are switched:

    cpuq run --on pup -- true; cpuq run --on burst -- true

### 5. Brew

At the release, the formula and cask are bumped as usual (docs/RELEASING.md). A machine that runs
brew's cpuq gets the same binary there.

## Rollback

On one machine:

    install -m 755 ~/.local/bin/cpuq.0.29.0 ~/.local/bin/cpuq     # (0.28.0 on burst)
    cp ~/.config/cpuq/config.before-pool ~/.config/cpuq/config
    launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.github.shreeve.cpuq.agent.plist   # pop
    systemctl --user enable --now cpuq-agent                                                   # pup

The old state files were never touched, and the new pool's `v2/` folder is ignored by the old
cpuq. Roll back the client and its remotes together, as they switched.
