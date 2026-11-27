//! A job's lines in the history file: its record, each event, and the last words a fatal
//! signal leaves.
const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const history = @import("history.zig");

const main = @import("main.zig");

const Ctx = main.Ctx;

/// The history's record of the job this cpuq runs: its id and the fields
/// every one of its events carries.
pub const JobLog = struct {
    id: []const u8,
    base: history.Event,
};

/// Unix time in seconds, with a fraction.
pub fn nowFloat(io: Io) f64 {
    return @as(f64, @floatFromInt(Io.Clock.real.now(io).toNanoseconds())) / 1e9;
}

/// The history file: CPUQ_HISTORY; else beside an explicit CPUQ_DIR, so a
/// separate queue keeps a separate history; else under XDG_STATE_HOME or
/// ~/.local/state, outside /tmp, so it outlives a reboot.
pub fn historyPath(ctx: *Ctx) []const u8 {
    if (ctx.env.get("CPUQ_HISTORY")) |p| return p;
    if (ctx.env.get("CPUQ_DIR")) |d| return std.mem.concat(ctx.arena, u8, &.{ d, "/history.jsonl" }) catch "";
    if (ctx.env.get("XDG_STATE_HOME")) |x| return std.mem.concat(ctx.arena, u8, &.{ x, "/cpuq/history.jsonl" }) catch "";
    const home = ctx.env.get("HOME") orelse return "";
    return std.mem.concat(ctx.arena, u8, &.{ home, "/.local/state/cpuq/history.jsonl" }) catch "";
}

/// A new job's record: `base` with this cpuq's pid and a fresh id.
pub fn newJobLog(ctx: *Ctx, base: history.Event) JobLog {
    const pid = sys.getpid();
    const t = nowFloat(ctx.io);
    var b = base;
    b.pid = pid;
    return .{ .id = ctx.arena.print("{d}-{d}", .{ pid, @as(i64, @intFromFloat(t * 1000)) }) catch "0", .base = b };
}

/// What an event carries beyond the job's own fields.
pub const EventExtra = struct {
    /// The CPUs or slots it held (started), or the most it held at once (ended).
    cores: ?u32 = null,
    exit: ?u8 = null,
    signal: ?u32 = null,
    /// Why cpuq stopped it: "time limit" or "idle".
    stopped: ?[]const u8 = null,
    cpu: ?f64 = null,
    done: ?u32 = null,
    failed: ?u32 = null,
    /// When the event happened, if not now.
    t: ?f64 = null,
};

pub fn logEvent(ctx: *Ctx, job: JobLog, event: []const u8, extra: EventExtra) void {
    const path = historyPath(ctx);
    if (path.len == 0) return;
    var ev = job.base;
    ev.event = event;
    ev.id = job.id;
    ev.t = extra.t orelse nowFloat(ctx.io);
    ev.cores = extra.cores;
    ev.exit = extra.exit;
    ev.signal = extra.signal;
    ev.stopped = extra.stopped;
    ev.cpu = extra.cpu;
    ev.done = extra.done;
    ev.failed = extra.failed;
    history.append(ctx.io, path, ev);
}

/// Arms the line a fatal signal leaves in history in place of cpuq's own
/// next one: `gave_up` while it waits, `ended` once it holds. With `done`,
/// the job's work is over (a hold's stdin closed): it ended with status 0,
/// whatever signal then stops cpuq. `logAndArm` logs each event and arms
/// the line after it as one step; a second line for the same event is
/// harmless.
pub fn armLastWords(ctx: *Ctx, job: JobLog, event: []const u8, cores: ?u32, done: bool) void {
    const path = historyPath(ctx);
    if (path.len == 0) return;
    var head_buf: [256]u8 = undefined;
    const head = std.mem.print(&head_buf, "{{\"v\":1,\"event\":\"{s}\",\"id\":\"{s}\",\"t\":", .{ event, job.id }) catch return;
    var tail_buf: [64]u8 = undefined;
    var tw: Io.Writer = .fixed(&tail_buf);
    tw.print(",\"pid\":{d}", .{job.base.pid}) catch return;
    if (cores) |k| tw.print(",\"cores\":{d}", .{k}) catch return;
    if (done) tw.writeAll(",\"exit\":0") catch return;
    sys.armLastWords(path, head, tw.buffered(), !done);
}

/// Logs `event` and arms the line a fatal signal leaves next (`armed`, as
/// `armLastWords` takes it) as one step: a signal that lands between the two
/// waits until the new line is armed, so the job never dies with nothing
/// armed, or with the line for the step before (`gave_up` once `started`
/// is logged).
pub fn logAndArm(ctx: *Ctx, job: JobLog, event: []const u8, extra: EventExtra, armed: []const u8, cores: ?u32) void {
    const before = sys.holdFatal();
    defer sys.restoreSignals(before);
    logEvent(ctx, job, event, extra);
    armLastWords(ctx, job, armed, cores, false);
}

/// Logs how a command ended.
pub fn logEnded(ctx: *Ctx, job: JobLog, cores: u32, w: sys.Waited) void {
    var extra: EventExtra = .{ .cores = cores, .cpu = w.cpu_s };
    switch (w.exit) {
        .code => |code| extra.exit = code,
        .signal => |sig| extra.signal = @intCast(@backingInt(sig)),
    }
    logEvent(ctx, job, "ended", extra);
}
