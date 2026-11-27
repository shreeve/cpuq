//! `cpuq status --json`: the shapes it prints, which Cpuq.app and other machines' cpuq read back.
const std = @import("std");
const sys = @import("sys.zig");

const main = @import("main.zig");

const version = main.version;

/// An operation holding CPUs of the pool (or with tasks running).
pub const JsonHolder = struct {
    /// Its ticket: its turn in the line, and its name for `cpuq kill`.
    ticket: u64 = 0,
    /// Its cpuq's pid: the operation's one loop, which holds its CPUs.
    pid: i32 = 0,
    /// The project it counts for, and that project's weight.
    project: []const u8 = "",
    weight: u32 = 1,
    /// CPUs it holds.
    cores: u32 = 0,
    /// Which of the pool's CPUs it holds, by place in the pool from 0.
    slots: []const u32 = &.{},
    /// The CPUs it holds, by the machine's numbers.
    cpus: []const u32 = &.{},
    /// How many of those it is emptying to give to the line.
    emptying: u32 = 0,
    /// CPUs it could use now beyond those it holds and is promised.
    want: u32 = 0,
    /// Processes per CPU (-x), and the most CPUs it may hold (-c, worked out).
    overload: u32 = 1,
    limit: u32 = 1,
    tasks: u32 = 0,
    done: u32 = 0,
    failed: u32 = 0,
    running: u32 = 0,
    /// Its tasks running now: the task's number, its try, its CPU (by the machine's number;
    /// null while stopped with its operation), its pid and when it started (Unix seconds).
    running_tasks: []const JsonTask = &.{},
    /// Its cpuq is stopped (Ctrl-Z).
    paused: bool = false,
    /// `cpuq drain`: it takes the whole machine.
    exclusive: bool = false,
    urgent: bool = false,
    /// CPUs its tasks kept busy over the sample, its own cpuq left out; null with --no-usage.
    using: ?f64 = null,
    /// What deserves a look: "low_use" (its CPUs average under 0.5 busy), "over_cpu" (over 1.2
    /// busy per CPU), "stopped" (its cpuq is stopped); for a drain, "idle_drain" (its command
    /// keeps under 0.25 CPUs busy in all) and "long_drain" (held past config `drain_timeout`).
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

pub const JsonTask = struct { task: u32 = 0, attempt: u32 = 1, cpu: ?u32 = null, pid: i32 = 0, since: i64 = 0 };

pub const JsonProgress = struct { done: u64 = 0, total: u64 = 0, failing: u64 = 0 };

/// An operation in the line for a CPU: one that holds none yet, or one that could use more.
pub const JsonWaiter = struct {
    /// Its place in the line, from 1: the order the next free CPUs go in.
    order: usize = 0,
    ticket: u64 = 0,
    pid: i32 = 0,
    project: []const u8 = "",
    /// CPUs it waits for now, and the most it may hold.
    cores: u32 = 0,
    max: u32 = 0,
    /// CPUs it holds already.
    holds: u32 = 0,
    /// `cpuq drain`: it waits for every CPU.
    exclusive: bool = false,
    urgent: bool = false,
    /// Why it waits, for people: "2nd in line; every CPU is held; next CPU frees in about 4s".
    why: []const u8 = "",
    /// What its cpuq last found closed (a gate, outside load); empty when nothing was.
    gate: []const u8 = "",
    /// Seconds until the next CPU frees, about, from the running tasks' times so far; null
    /// when there is no such estimate, and for all but the first in line.
    eta: ?f64 = null,
    label: []const u8 = "",
    command: []const u8 = "",
    since: i64 = 0,
};

/// A project's CPUs against its fair share of the pool by weight.
pub const JsonProject = struct {
    name: []const u8 = "",
    weight: u32 = 1,
    /// Its operations, the CPUs they hold, and the CPUs they could use beyond those.
    ops: u32 = 0,
    held: u32 = 0,
    want: u32 = 0,
    /// Its share of the pool by weight, where a project wanting less than its share keeps what
    /// it wants and the rest is shared among the others.
    fair: f64 = 0,
};

/// What holds the pool's free CPUs back: `state` is open, pressure, low_memory, low_disk,
/// outside_load (busy work outside cpuq leaves too few CPUs idle) or drain (`cpuq drain` waits
/// for or holds the machine).
pub const JsonGate = struct {
    state: []const u8 = "",
    /// With `state` outside_load: the CPUs busy outside cpuq's tasks.
    load: ?f64 = null,
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
    schema: u32 = 2,
    version: []const u8 = version,
    /// The pool's folder.
    dir: []const u8 = "",
    /// How CPUs are handed out: "pool", one CPU per task from the pool's CPUs.
    admit: []const u8 = "pool",
    /// The pool's size, and its CPUs by the machine's numbers, in the order they are handed out.
    budget: u32 = 0,
    pool: []const u32 = &.{},
    /// The machine's CPUs, and those online.
    cores: u32 = 0,
    active_cores: u32 = 0,
    /// CPUs held by operations, being emptied for the line, promised to a waiter, and free.
    held: u32 = 0,
    emptying: u32 = 0,
    promised: u32 = 0,
    free: u32 = 0,
    /// CPUs the machine kept busy over the sample, all of them, and those of cpuq's tasks;
    /// `tasks_busy` is null with --no-usage.
    busy: ?f64 = null,
    tasks_busy: ?f64 = null,
    /// Seconds until the next held CPU frees, about; null when there is no estimate.
    next_free: ?f64 = null,
    load: [3]f64 = .{ 0, 0, 0 },
    memory_pressure: []const u8 = "",
    /// Memory and swap in bytes: `used` is what Activity Monitor calls Memory Used on macOS,
    /// the total less MemAvailable on Linux.
    memory: ?sys.Memory = null,
    gate: JsonGate = .{},
    holders: []const JsonHolder = &.{},
    waiters: []const JsonWaiter = &.{},
    projects: []const JsonProject = &.{},
    /// The busiest processes outside every operation (empty with --no-usage).
    outside: []const JsonOutside = &.{},
    /// CPUs busy outside every operation, in all (0 with --no-usage).
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

/// Busy work outside every operation, by what started it: the top of a process tree just
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

/// A busy process that is not part of any operation.
pub const JsonOutside = struct {
    pid: i32 = 0,
    name: []const u8 = "",
    using: f64 = 0,
    /// Its command line (cut at 300 bytes) and working directory, so the work can be traced
    /// to whoever started it.
    command: []const u8 = "",
    cwd: []const u8 = "",
};
