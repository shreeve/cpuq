//! The job history: one JSON line per event, appended to a file outside the
//! state directory so it survives a reboot. A job writes `queued`, then
//! `started` once admitted, then `ended` (or `gave_up` at --max-wait). A
//! line under 4 KB written with O_APPEND lands whole however many processes
//! append at once, so no lock is needed. A job with neither `ended` nor
//! `gave_up` whose process is gone, or which was queued before the machine
//! last booted, was lost.
const std = @import("std");
const Io = std.Io;
const c = std.c;

/// One line of the history file. Fields an event does not carry are left
/// out of the line.
pub const Event = struct {
    v: u32 = 1,
    /// queued, started, ended or gave_up
    event: []const u8 = "",
    /// The job: its cpuq's pid and the moment it queued, so one job's events
    /// share it.
    id: []const u8 = "",
    /// Unix time in seconds.
    t: f64 = 0,
    pid: i32 = 0,
    /// "cores", or the lease's name for a named lease.
    pool: []const u8 = "cores",
    /// The host a `--host` lease is held on.
    host: ?[]const u8 = null,
    label: []const u8 = "",
    cmd: []const u8 = "",
    priority: []const u8 = "normal",
    exclusive: bool = false,
    /// The request: at least `min`, up to `max`.
    min: u32 = 0,
    max: u32 = 0,
    /// The grant (started, ended).
    cores: ?u32 = null,
    /// How the command ended (ended): its exit status, or the signal that
    /// killed it.
    exit: ?u8 = null,
    signal: ?u32 = null,
    /// CPU seconds the command and the descendants it reaped used (ended).
    cpu: ?f64 = null,
    /// The core tokens it took, by number (started).
    slots: ?[]const u32 = null,
    /// It started ahead of the head of the queue, on cores the head could
    /// not use yet (started).
    ahead: ?bool = null,
    /// How many of its cores were lent by holders that left them idle
    /// (started).
    lent: ?u32 = null,
    /// Started by hand past the queue and its gates (`cpuq start`).
    forced: ?bool = null,
};

/// The longest command kept in a line, so a line stays well under 4 KB.
const max_cmd = 1024;
/// The file is rotated to `.1` when it passes this size.
const rotate_bytes = 4 << 20;

/// Appends one event. History is a record, not a duty: a failure here never
/// fails the job, so errors are dropped.
pub fn append(io: Io, path: []const u8, ev: Event) void {
    var e = ev;
    if (e.cmd.len > max_cmd) e.cmd = e.cmd[0..max_cmd];
    var buf: [4000]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    std.json.Stringify.value(e, .{ .emit_null_optional_fields = false }, &w) catch return;
    w.writeByte('\n') catch return;

    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |dir| cwd.createDirPath(io, dir) catch {};
    if (cwd.statFile(io, path, .{})) |st| {
        if (st.size > rotate_bytes) {
            var old_buf: [1024]u8 = undefined;
            const old = std.mem.print(&old_buf, "{s}.1", .{path}) catch return;
            cwd.rename(path, cwd, old, io) catch {};
        }
    } else |_| {}

    var path_buf: [1024]u8 = undefined;
    if (path.len >= path_buf.len) return;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;
    const fd = c.open(path_buf[0..path.len :0], .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = c.close(fd);
    _ = c.write(fd, w.buffered().ptr, w.buffered().len);
}

pub const State = enum { done, gave_up, lost, active };

/// A job, assembled from its events.
pub const Job = struct {
    id: []const u8,
    pid: i32,
    pool: []const u8,
    host: ?[]const u8,
    label: []const u8,
    cmd: []const u8,
    priority: []const u8,
    exclusive: bool,
    min: u32,
    max: u32,
    cores: ?u32 = null,
    queued: f64,
    started: ?f64 = null,
    ended: ?f64 = null,
    exit: ?u8 = null,
    signal: ?u32 = null,
    cpu: ?f64 = null,
    slots: ?[]const u32 = null,
    state: State = .active,

    /// Seconds spent waiting: until admitted, or until it gave up.
    pub fn waited(j: Job) ?f64 {
        if (j.started) |s| return s - j.queued;
        if (j.state == .gave_up) if (j.ended) |e| return e - j.queued;
        return null;
    }

    /// Seconds the command ran.
    pub fn ran(j: Job) ?f64 {
        const s = j.started orelse return null;
        if (j.state != .done) return null;
        return (j.ended orelse return null) - s;
    }

    /// The cores the command kept busy on average: its CPU time over its
    /// run time.
    pub fn used(j: Job) ?f64 {
        const r = j.ran() orelse return null;
        const cpu = j.cpu orelse return null;
        return if (r > 0.05) cpu / r else null;
    }

    /// When it last changed: ended, else started, else queued.
    pub fn last(j: Job) f64 {
        return j.ended orelse j.started orelse j.queued;
    }
};

/// Every job in the history (the rotated file first), oldest first. `alive`
/// tells whether a pid still runs; `boot` is when the machine last booted.
pub fn load(io: Io, a: std.mem.Allocator, path: []const u8, boot: f64, alive: *const fn (i32) bool) []Job {
    var jobs: std.ArrayList(Job) = .empty;
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    const old = std.mem.concat(a, u8, &.{ path, ".1" }) catch return &.{};
    for ([_][]const u8{ old, path }) |p| {
        const text = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(64 << 20)) catch continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const ev = std.json.parseFromSliceLeaky(Event, a, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
            if (ev.id.len == 0) continue;
            const gop = index.getOrPut(a, ev.id) catch continue;
            if (!gop.found_existing) {
                gop.value_ptr.* = jobs.items.len;
                jobs.append(a, .{
                    .id = ev.id,
                    .pid = ev.pid,
                    .pool = ev.pool,
                    .host = ev.host,
                    .label = ev.label,
                    .cmd = ev.cmd,
                    .priority = ev.priority,
                    .exclusive = ev.exclusive,
                    .min = ev.min,
                    .max = ev.max,
                    .queued = ev.t,
                }) catch continue;
            }
            const j = &jobs.items[gop.value_ptr.*];
            if (std.mem.eql(u8, ev.event, "queued")) {
                j.queued = ev.t;
            } else if (std.mem.eql(u8, ev.event, "started")) {
                j.started = ev.t;
                j.cores = ev.cores;
                j.slots = ev.slots;
            } else if (std.mem.eql(u8, ev.event, "ended")) {
                j.ended = ev.t;
                j.exit = ev.exit;
                j.signal = ev.signal;
                j.cpu = ev.cpu;
                if (ev.cores) |k| j.cores = k;
                j.state = .done;
            } else if (std.mem.eql(u8, ev.event, "gave_up")) {
                j.ended = ev.t;
                j.signal = ev.signal;
                j.state = .gave_up;
            }
        }
    }
    for (jobs.items) |*j| {
        if (j.state != .active) continue;
        if (j.queued < boot or !alive(j.pid)) j.state = .lost;
    }
    return jobs.items;
}

/// True when a label matches a pattern: exactly, or by prefix when the
/// pattern ends in `*`.
pub fn labelMatches(pattern: []const u8, label: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) return std.mem.startsWith(u8, label, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, label);
}

/// The middle value of `xs` (sorted in place); 0 when empty.
pub fn median(xs: []f64) f64 {
    if (xs.len == 0) return 0;
    std.mem.sortUnstable(f64, xs, {}, std.sort.asc(f64));
    return xs[xs.len / 2];
}

const testing = std.testing;

fn aliveNone(_: i32) bool {
    return false;
}

fn aliveAll(_: i32) bool {
    return true;
}

test "events assemble into jobs: done, gave up, lost" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    const path = try std.mem.concat(a, u8, &.{ dir, "/history.jsonl" });

    append(testing.io, path, .{ .event = "queued", .id = "1-100", .t = 100, .pid = 1, .label = "build", .min = 2, .max = 4 });
    append(testing.io, path, .{ .event = "started", .id = "1-100", .t = 103, .pid = 1, .cores = 3 });
    append(testing.io, path, .{ .event = "ended", .id = "1-100", .t = 113, .pid = 1, .cores = 3, .exit = 0, .cpu = 20 });
    append(testing.io, path, .{ .event = "queued", .id = "2-200", .t = 200, .pid = 2, .label = "test" });
    append(testing.io, path, .{ .event = "gave_up", .id = "2-200", .t = 230, .pid = 2 });
    append(testing.io, path, .{ .event = "queued", .id = "3-300", .t = 300, .pid = 3, .label = "lost" });
    append(testing.io, path, .{ .event = "started", .id = "3-300", .t = 301, .pid = 3, .cores = 2 });

    const jobs = load(testing.io, a, path, 0, &aliveNone);
    try testing.expectEqual(3, jobs.len);
    try testing.expectEqual(State.done, jobs[0].state);
    try testing.expectEqual(3.0, jobs[0].waited().?);
    try testing.expectEqual(10.0, jobs[0].ran().?);
    try testing.expectEqual(2.0, jobs[0].used().?);
    try testing.expectEqual(3, jobs[0].cores.?);
    try testing.expectEqualStrings("build", jobs[0].label);
    try testing.expectEqual(State.gave_up, jobs[1].state);
    try testing.expectEqual(30.0, jobs[1].waited().?);
    try testing.expectEqual(State.lost, jobs[2].state);

    // A live process queued after the last boot is still active.
    const live = load(testing.io, a, path, 0, &aliveAll);
    try testing.expectEqual(State.active, live[2].state);
    // One queued before the last boot is lost, alive pid or not.
    const rebooted = load(testing.io, a, path, 350, &aliveAll);
    try testing.expectEqual(State.lost, rebooted[2].state);
}

test "label patterns and medians" {
    try testing.expect(labelMatches("rig:*", "rig:matrix"));
    try testing.expect(!labelMatches("rig:*", "nexis:build"));
    try testing.expect(labelMatches("gate", "gate"));
    try testing.expect(!labelMatches("gate", "gate2"));
    var xs = [_]f64{ 5, 1, 3 };
    try testing.expectEqual(3.0, median(&xs));
}
