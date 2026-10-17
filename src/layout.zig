//! Where cpuq keeps things, the same on every machine. Paths here are relative to the home
//! directory: rsync and ssh name them so on another machine.
//!
//!     ~/.local/bin/cpuq        the binary
//!     ~/.config/cpuq/config    the config
//!     ~/.local/state/cpuq/     cpuq's own records (history, samples, job logs)
//!     ~/cpuq/packs/            tools jobs ask for (zig, rig, nexus)
//!     ~/cpuq/worktrees/        copies of repos sent from another machine
//!     ~/cpuq/caches/PROJECT/   build caches shared across branches
//!     ~/cpuq/tmp/              scratch

/// Everything cpuq keeps for jobs: the disk `min_disk` watches.
pub const root = "cpuq";
/// Tools jobs ask for (packs.zig): NAME/VERSION.
pub const packs = "cpuq/packs";
/// Copies of repos sent from another machine: PROJECT/NAME, one folder per project, so a new
/// copy is seeded from another of its project's.
pub const worktrees = "cpuq/worktrees";
/// A spec's `caches`: PROJECT/NAME, shared by every branch, never synced or deleted by a sync.
pub const caches = "cpuq/caches";
/// Scratch: a submitted job's TMPDIR is ID here, removed when it ends.
pub const tmp = "cpuq/tmp";
