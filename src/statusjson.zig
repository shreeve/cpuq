//! `cpuq status --json`: the shapes it prints, which Cpuq.app and other machines' cpuq read back.
const std = @import("std");
const sys = @import("sys.zig");

const main = @import("main.zig");

const version = main.version;

/// A run with tasks running (or a drain holding its CPUs' tokens).
pub const JsonRun = struct {
    /// Its ticket: its turn in the line, and its name for `cpuq kill` and `cpuq limit`.
    ticket: u64 = 0,
    /// Its cpuq's pid: the run's one loop.
    pid: i32 = 0,
    /// The project it counts for, and that project's weight.
    project: []const u8 = "",
    weight: u32 = 1,
    /// The most tokens it holds at once (-c, worked out); a drain's CPUs.
    limit: u32 = 1,
    tasks: u32 = 0,
    done: u32 = 0,
    failed: u32 = 0,
    /// Its tasks running, each holding a token (a drain: its command).
    running: u32 = 0,
    /// Its tasks cpuq has stopped, holding no token: after a Ctrl-Z, until each holds one again
    /// (a drain's command, until its drain's turn comes again).
    paused: u32 = 0,
    /// Linux: its tasks waiting on a disk or other device (a process in state D); null when not
    /// measured (--no-usage, macOS).
    io_wait: ?u32 = null,
    /// Only its running tasks are left (its tail), and when the oldest of them started (Unix
    /// seconds; 0 when none runs).
    tail: bool = false,
    oldest: i64 = 0,
    /// Tasks it could start now (waiting in the line).
    waiting: u32 = 0,
    /// Its tasks running now: the task's number, its try, its pid, when it started (Unix
    /// seconds), whether cpuq has it stopped, and the CPU whose token it holds (pinned there on
    /// Linux).
    running_tasks: []const JsonTask = &.{},
    /// Its cpuq is stopped (Ctrl-Z): its tasks are stopped, and it counts in no share.
    stopped: bool = false,
    /// `cpuq run --driver`: a test runner, no task of its own, and the CPUs its own process tree
    /// keeps busy, the runs it starts left out (counted against its project's share from 0.5).
    driver: bool = false,
    driver_busy: f64 = 0,
    /// `cpuq drain`: the CPUs its command runs on (`pin`), the CPUs it isolates (those with their
    /// SMT siblings: it holds their tokens), and the busy CPUs work from outside it keeps on them
    /// (Linux), with the busiest such process ("name (pid)").
    drain: bool = false,
    pin: []const u32 = &.{},
    cpus: []const u32 = &.{},
    noise: f64 = 0,
    noisy_top: []const u8 = "",
    urgent: bool = false,
    /// CPUs its tasks kept busy over the sample, its own cpuq left out; null with --no-usage.
    using: ?f64 = null,
    /// What deserves a look: "over_cpu" (its tasks keep more than 1.2 CPUs busy each: a task
    /// runs more than one job), "stopped" (its cpuq is stopped), "capped" (tasks queued under
    /// its own -c while tokens are free: `cpuq limit` raises it); for a drain, "idle_drain"
    /// (its command keeps under 0.25 CPUs busy), "long_drain" (past config `drain_timeout`) and
    /// "noisy" (work from outside it keeps 0.1 CPUs or more busy on its CPUs); for a driver,
    /// "driver_cpu" (its own tree keeps 0.5 CPUs or more busy).
    flags: []const []const u8 = &.{},
    /// Its tasks ended (passed or failed) of all, with those that failed.
    progress: ?JsonProgress = null,
    /// Seconds left at its rate so far (`left_from` "progress"); null until a task has ended.
    left: ?f64 = null,
    left_from: []const u8 = "",
    label: []const u8 = "",
    command: []const u8 = "",
    since: i64 = 0,
};

pub const JsonTask = struct { task: u32 = 0, attempt: u32 = 1, pid: i32 = 0, since: i64 = 0, paused: bool = false, cpu: u32 = 0 };

pub const JsonProgress = struct { done: u64 = 0, total: u64 = 0, failing: u64 = 0 };

/// A run with tasks waiting to start, or a drain waiting for its turn.
pub const JsonWaiter = struct {
    /// Its place in the line, from 1: the order the runs start their next task if nothing else
    /// changes (`pool.lineOrder`); drains follow, in their order.
    order: usize = 0,
    ticket: u64 = 0,
    pid: i32 = 0,
    project: []const u8 = "",
    /// Tasks it could start now, those it runs, and the most it runs at once.
    waiting: u32 = 0,
    running: u32 = 0,
    max: u32 = 0,
    /// `cpuq drain` waiting for its turn (`max`: the CPUs it times on).
    drain: bool = false,
    urgent: bool = false,
    /// Why it waits, for people: "1st in line; every token is held".
    why: []const u8 = "",
    label: []const u8 = "",
    command: []const u8 = "",
    since: i64 = 0,
};

/// A project's tasks against its fair share of the tokens by weight.
pub const JsonProject = struct {
    name: []const u8 = "",
    weight: u32 = 1,
    /// Its runs, their tasks running and the tasks they could start now.
    runs: u32 = 0,
    running: u32 = 0,
    waiting: u32 = 0,
    /// Its share of the tokens: N × its weight ÷ the weights of the projects running or waiting
    /// (0 when it does neither). Under it, a project is first in line for a freed token.
    fair: f64 = 0,
};

/// What holds every start back: `state` is open, pressure, low_memory or low_disk.
pub const JsonGate = struct {
    state: []const u8 = "",
    /// With `state` low_memory: the bytes of memory available.
    available: ?u64 = null,
    /// With `state` low_disk: the bytes free, and a path on that filesystem.
    disk_free: ?u64 = null,
    disk_path: ?[]const u8 = null,
    text: []const u8 = "",
};

/// `cpuq status --json`. `schema` changes only when a field is removed or changes meaning; new
/// fields may appear in any version.
pub const JsonStatus = struct {
    schema: u32 = 4,
    version: []const u8 = version,
    /// The pool's folder.
    dir: []const u8 = "",
    /// How CPUs are shared: "tokens", one per CPU of the pool less the reserve; a task holds one
    /// while it runs.
    admit: []const u8 = "tokens",
    /// The pool's CPUs by the machine's numbers, in its order.
    pool: []const u32 = &.{},
    /// The machine's tokens (N: at most N tasks run at once), their CPUs (the pool's first N), and
    /// the reserve (the pool's last CPUs, never handed out; config `reserve`).
    tokens: u32 = 0,
    token_cpus: []const u32 = &.{},
    reserve: u32 = 0,
    /// Tokens held (by tasks running and by drains), held back while work outside cpuq keeps
    /// more than the CPUs cpuq leaves it busy, and free.
    held: u32 = 0,
    held_back: u32 = 0,
    free: u32 = 0,
    /// The CPUs drains isolate (their tokens, and siblings outside the tokens).
    isolated: []const u32 = &.{},
    /// The machine's CPUs, and those online.
    cores: u32 = 0,
    active_cores: u32 = 0,
    /// cpuq's tasks running (each holding a token), stopped by it (holding none), and waiting to
    /// start.
    running: u32 = 0,
    paused: u32 = 0,
    waiting: u32 = 0,
    /// CPUs the machine kept busy over the sample, all of them, and those of cpuq's tasks;
    /// `tasks_busy` is null with --no-usage.
    busy: ?f64 = null,
    tasks_busy: ?f64 = null,
    load: [3]f64 = .{ 0, 0, 0 },
    memory_pressure: []const u8 = "",
    /// Memory and swap in bytes: `used` is what Activity Monitor calls Memory Used on macOS,
    /// the total less MemAvailable on Linux.
    memory: ?sys.Memory = null,
    gate: JsonGate = .{},
    runs: []const JsonRun = &.{},
    waiters: []const JsonWaiter = &.{},
    projects: []const JsonProject = &.{},
    /// The busiest processes outside every run (empty with --no-usage).
    outside: []const JsonOutside = &.{},
    /// CPUs busy outside every run, in all (0 with --no-usage).
    outside_total: f64 = 0,
    /// The same load by what started it, busiest first (empty with --no-usage).
    outside_work: []const JsonWork = &.{},
    /// Each CPU's time so far, `[busy, total]` in clock ticks, in the kernel's order: cumulative,
    /// so a reader takes the difference between two statuses. Cpuq.app draws another machine's
    /// CPUs from it.
    cpu_ticks: ?[]const [2]u64 = null,
    /// When the machine booted, in Unix seconds: how long a cloud machine has been up (and
    /// billing).
    boot_time: ?i64 = null,
    /// Whether `cpuq record` is sampling this machine (`cpuq samples` has its past).
    recorder: bool = false,
};

/// Busy work outside every run, by what started it: the top of a process tree just
/// below its starter (an agent's harness, an ssh session, a terminal, a service manager), so
/// `ssh HOST 'make -j'` or a detached loop of builds shows as one entry with its command.
pub const JsonWork = struct {
    /// The tree's top process, and its command line (cut at 300 bytes) and working directory.
    pid: i32 = 0,
    command: []const u8 = "",
    cwd: []const u8 = "",
    /// What started it: the starter's program name (`claude`, `sshd-session`, `systemd`, ...).
    via: []const u8 = "",
    /// The tree's busy processes, and the CPUs they keep busy together.
    procs: u32 = 0,
    using: f64 = 0,
};

/// A busy process that is not part of any run.
pub const JsonOutside = struct {
    pid: i32 = 0,
    name: []const u8 = "",
    using: f64 = 0,
    /// Its command line (cut at 300 bytes) and working directory, so the work can be traced
    /// to whoever started it.
    command: []const u8 = "",
    cwd: []const u8 = "",
};
