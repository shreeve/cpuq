//! `cpuq status --json`: the shapes it prints, which other machines' cpuq read back.
const std = @import("std");
const Io = std.Io;
const state = @import("state.zig");
const sys = @import("sys.zig");

const main = @import("main.zig");
const texts = @import("texts.zig");

const version = main.version;
const className = texts.className;

pub const JsonHolder = struct {
    ticket: u64 = 0,
    pid: i32 = 0,
    holder_alive: bool = false,
    child: i32 = 0,
    cores: u32 = 0,
    /// The core tokens it holds, by number: which of the budget's cores.
    slots: []const u32 = &.{},
    /// Paused by hand (`cpuq pause`), or frozen by a timing window.
    paused: bool = false,
    /// Frozen by a timing window whose owner works again (`window_lend`).
    frozen: bool = false,
    /// A timing window lending the machine while its owner idles.
    lending: bool = false,
    /// `--opaque`: its work runs where cpuq cannot see it; counted whole.
    @"opaque": bool = false,
    /// Cores the command's process tree kept busy over the sample: CPU time
    /// over wall time; null when there is no command to measure.
    using: ?f64 = null,
    /// What the job reported in its CPUQ_PROGRESS file, if it did.
    progress: ?JsonProgress = null,
    /// Seconds left: from its progress when it reports some, else from its label's typical run
    /// time (`left_from` says which); null when neither is known.
    left: ?f64 = null,
    left_from: []const u8 = "",
    /// How long its label's runs typically take, in seconds, from history.
    typical: ?f64 = null,
    priority: []const u8 = "",
    exclusive: bool = false,
    label: []const u8 = "",
    /// What the job is for, as `--note` gave it.
    note: []const u8 = "",
    command: []const u8 = "",
    since: i64 = 0,
};

const JsonProgress = struct { done: u64 = 0, total: u64 = 0, failing: u64 = 0 };

/// A CPUQ_PROGRESS file's one line, `DONE TOTAL [FAILING]`; null when it says nothing usable.
pub fn readProgress(io: Io, path: []const u8) ?JsonProgress {
    if (path.len == 0) return null;
    var buf: [128]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, path, &buf) catch return null;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const done = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const total = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const failing = std.fmt.parseInt(u64, it.next() orelse "0", 10) catch 0;
    if (total == 0) return null;
    return .{ .done = @min(done, total), .total = total, .failing = failing };
}

pub const JsonWaiter = struct {
    /// Seconds until it is expected to start, from the history of jobs
    /// with its holders' and the waiters ahead's labels; null when unknown.
    eta: ?f64 = null,
    order: usize = 0,
    ticket: u64 = 0,
    pid: i32 = 0,
    /// The request: at least `cores`, up to `max`.
    cores: u32 = 0,
    max: u32 = 0,
    priority: []const u8 = "",
    class: []const u8 = "",
    exclusive: bool = false,
    label: []const u8 = "",
    /// What the job is for, as `--note` gave it.
    note: []const u8 = "",
    command: []const u8 = "",
    since: i64 = 0,
};

/// The gate in a form a program can act on: `state` is open, pressure,
/// low_memory, low_disk, load (the valve is tripped) or spacing (one
/// admission per 10 s), and `load` is
/// the 1-minute load behind a load or spacing state.
const JsonGate = struct {
    state: []const u8 = "",
    load: ?f64 = null,
    /// With `state` low_memory: the bytes of memory available.
    available: ?u64 = null,
    /// With `state` low_disk: the bytes free, and a path on that filesystem.
    disk_free: ?u64 = null,
    disk_path: ?[]const u8 = null,
    text: []const u8 = "",
    /// The load valve's thresholds, when the load check is on: it trips above
    /// `trip` while the CPUs are at least `busy_trip` busy, and reopens at
    /// `reopen` (or as soon as they are under three quarters busy).
    trip: ?f64 = null,
    reopen: ?f64 = null,
    busy_trip: ?f64 = null,
};

/// A named lease in `cpuq status --json`: its holders (one per slot taken)
/// and waiters.
pub const JsonLease = struct {
    name: []const u8 = "",
    holders: []const JsonHolder = &.{},
    waiters: []const JsonWaiter = &.{},
};

pub fn toHolders(a: std.mem.Allocator, leases: []const state.Entry, busy: []const ?f64) []JsonHolder {
    var out: std.ArrayList(JsonHolder) = .empty;
    for (leases, 0..) |l, i| {
        const r = l.record;
        out.append(a, .{
            .ticket = r.ticket,
            .pid = r.pid,
            .holder_alive = sys.processAlive(r.pid),
            .child = r.child,
            .cores = r.cores,
            .slots = r.slotList(a),
            .using = if (i < busy.len) busy[i] else null,
            .priority = @tagName(r.priority),
            .exclusive = r.exclusive,
            .label = r.label,
            .note = r.note,
            .command = r.cmd,
            .since = r.since,
        }) catch {};
    }
    return out.items;
}

pub fn toWaiters(a: std.mem.Allocator, queue: []const state.Entry) []JsonWaiter {
    var out: std.ArrayList(JsonWaiter) = .empty;
    for (queue, 0..) |e, i| {
        const r = e.record;
        out.append(a, .{
            .order = i + 1,
            .ticket = r.ticket,
            .pid = r.pid,
            .cores = r.cores,
            .max = @max(r.max, r.cores),
            .priority = @tagName(r.priority),
            .class = className(e.class),
            .exclusive = r.exclusive,
            .label = r.label,
            .note = r.note,
            .command = r.cmd,
            .since = r.since,
        }) catch {};
    }
    return out.items;
}

/// `cpuq status --json`. `schema` changes only when a field is removed or
/// changes meaning; new fields may appear in any version.
pub const JsonStatus = struct {
    schema: u32 = 1,
    version: []const u8 = version,
    dir: []const u8 = "",
    /// How jobs are admitted: "measured" (by the CPU they use, up to
    /// `target` CPUs) or "cores" (by the cores they hold, up to `budget`).
    admit: []const u8 = "",
    target: ?f64 = null,
    budget: u32 = 0,
    cores: u32 = 0,
    active_cores: u32 = 0,
    held: u32 = 0,
    free: u32 = 0,
    load: [3]f64 = .{ 0, 0, 0 },
    /// Whether this machine counts its load against admitting work (config `load_check`): a
    /// --on sending work here judges it by its load only when it does.
    load_check: bool = true,
    memory_pressure: []const u8 = "",
    /// Memory and swap in bytes: `used` is what Activity Monitor calls Memory
    /// Used on macOS, the total less MemAvailable on Linux.
    memory: ?sys.Memory = null,
    gate: JsonGate = .{},
    holders: []const JsonHolder = &.{},
    waiters: []const JsonWaiter = &.{},
    /// Named leases that are held or waited for.
    leases: []const JsonLease = &.{},
    /// The busiest processes outside every cpuq job (empty with --no-usage).
    outside: []const JsonOutside = &.{},
    /// CPUs busy outside every cpuq job, in all (0 with --no-usage).
    outside_total: f64 = 0,
    /// Each CPU's time so far, `[busy, total]` in clock ticks, in the
    /// kernel's order: cumulative, so a reader takes the difference between
    /// two statuses. Cpuq.app draws another machine's CPUs from it.
    cpu_ticks: ?[]const [2]u64 = null,
    /// When the machine booted, in Unix seconds: how long a cloud machine has
    /// been up (and billing).
    boot_time: ?i64 = null,
    /// Whether `cpuq record` is sampling this machine (`cpuq samples` has its past).
    recorder: bool = false,
};

/// A busy process that is not part of any cpuq job.
pub const JsonOutside = struct {
    pid: i32 = 0,
    name: []const u8 = "",
    using: f64 = 0,
    /// Its command line (cut at 300 bytes) and working directory, so the work can be traced
    /// to whoever started it.
    command: []const u8 = "",
    cwd: []const u8 = "",
};
