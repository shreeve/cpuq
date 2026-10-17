//! The jobs folder, cpuq's only state: one folder per job, one per submission, one file per task.
//!
//!     ~/.local/state/cpuq/jobs/{job}/stop          present: no new picks from this job
//!     ~/.local/state/cpuq/jobs/{job}/{stamp}/      one submission, e.g. 20261017-112241
//!         base   cpuq's keys, `key: value` a line, up to the first blank line; the job's own
//!                setup config after it, for its base process
//!         log    what its base process prints
//!         todo/ live/ done/ died/   one file per task
//!
//! A task file's data is everything before its first blank line; after it, its record, appended
//! and never truncated: per attempt a start line, the task's output, an end line. Only the
//! driver renames task files. Whatever runs a task holds an exclusive flock on its file, the
//! open file that is the task's stdout and stderr, so a file in live/ whose lock is free is run
//! by nothing. Names starting with a dot are being written, and are never read.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const policy = @import("policy.zig");
const cap = @import("cap.zig");
const pool = @import("pool.zig");
const Allocator = std.mem.Allocator;

pub const states = [_][]const u8{ "todo", "live", "done", "died" };

/// The jobs folder: CPUQ_JOBS, or ~/.local/state/cpuq/jobs.
pub fn root(a: Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("CPUQ_JOBS")) |r| return r;
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.local/state/cpuq/jobs", .{home}) catch null;
}

/// A submission's settings, from its `base` file.
pub const Base = struct {
    /// The command: `fork: yes`, the base itself, given the base file's path; `fork: no`, run
    /// once per task, given the task file's path.
    cmd: []const []const u8 = &.{},
    dir: []const u8 = "",
    env: []const []const u8 = &.{},
    fork: bool = false,
    job: pool.Config = .{},
    limits: cap.Limits = .{},
};

/// Reads a base file's keys over `prev`: a line that can't be read keeps the value it had,
/// and is named in `bad` (when given). A line is `key: value`; the keys end at the first blank
/// line. `cmd` is a JSON array of strings; `env` (NAME=VALUE) may repeat.
pub fn parseBase(a: Allocator, text: []const u8, prev: Base, bad: ?*std.ArrayList([]const u8)) Base {
    var b = prev;
    var env: std.ArrayList([]const u8) = .empty;
    var saw_env = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) break;
        const key, const rest = std.mem.cutScalar(u8, line, ':') orelse {
            note(a, bad, line);
            continue;
        };
        const v = std.mem.trim(u8, rest, " \t");
        const ok = blk: {
            if (eq(key, "cmd")) {
                const parsed = std.json.parseFromSliceLeaky([]const []const u8, a, v, .{}) catch break :blk false;
                if (parsed.len == 0) break :blk false;
                b.cmd = parsed;
            } else if (eq(key, "dir")) {
                b.dir = a.dupe(u8, v) catch break :blk false;
            } else if (eq(key, "env")) {
                if (std.mem.findScalar(u8, v, '=') == null) break :blk false;
                saw_env = true;
                env.append(a, a.dupe(u8, v) catch break :blk false) catch break :blk false;
            } else if (eq(key, "fork")) {
                b.fork = if (eq(v, "yes")) true else if (eq(v, "no")) false else break :blk false;
            } else if (eq(key, "weight")) {
                const w = std.fmt.parseFloat(f64, v) catch break :blk false;
                if (!(w > 0) or w > 1e6) break :blk false;
                b.job.weight = w;
            } else if (eq(key, "max")) {
                b.job.max = std.fmt.parseInt(u32, v, 10) catch break :blk false;
                if (b.job.max == 0) break :blk false;
            } else if (eq(key, "cores")) {
                b.job.cores = std.fmt.parseInt(u32, v, 10) catch break :blk false;
                if (b.job.cores == 0) break :blk false;
            } else if (eq(key, "delay")) {
                b.job.delay = parseDelay(v) orelse break :blk false;
            } else if (eq(key, "mem")) {
                b.limits.mem = policy.parseBytes(v) orelse break :blk false;
            } else if (eq(key, "time")) {
                b.limits.time_ms = cap.parseDuration(v) orelse break :blk false;
            } else if (eq(key, "output")) {
                b.limits.output = policy.parseBytes(v) orelse break :blk false;
            } else if (eq(key, "pids")) {
                b.limits.pids = std.fmt.parseInt(u64, v, 10) catch break :blk false;
            } else break :blk false;
            break :blk true;
        };
        if (!ok) note(a, bad, line);
    }
    if (saw_env) b.env = env.items;
    return b;
}

fn note(a: Allocator, bad: ?*std.ArrayList([]const u8), line: []const u8) void {
    if (bad) |list| list.append(a, line) catch {};
}

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

/// `rand`, `task` or seconds (vete's `--delay`).
pub fn parseDelay(v: []const u8) ?pool.Delay {
    if (eq(v, "rand")) return .rand;
    if (eq(v, "task")) return .task;
    if (eq(v, "none")) return .none;
    const secs = std.fmt.parseFloat(f64, v) catch return null;
    return if (secs >= 0 and secs < 3600) .{ .secs = secs } else null;
}

/// A stamp's ordering key: its digits as a number (20261017-112241 → 20261017112241).
pub fn stampKey(stamp: []const u8) i64 {
    var n: i64 = 0;
    for (stamp) |ch| if (ch >= '0' and ch <= '9') {
        n = n *| 10 +| (ch - '0');
    };
    return n;
}

/// A stamp for now: YYYYMMDD-HHMMSS, UTC.
pub fn stampNow(buf: *[15]u8, now_s: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(now_s, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}{d:0>2}{d:0>2}-{d:0>2}{d:0>2}{d:0>2}", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// Whether a name in a jobs folder is one to read: not a dot-name (being written).
pub fn visible(name: []const u8) bool {
    return name.len != 0 and name[0] != '.';
}

// --- Task files ------------------------------------------------------------------------------

/// Opens a task file to append, holding its lock: free only once this descriptor, and every
/// copy of it (dups, forks), is closed. Null if it is gone or another holds the lock.
pub fn lockTask(path: [*:0]const u8) ?c.fd_t {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true });
    if (fd < 0) return null;
    if (c.flock(fd, c.LOCK.EX | c.LOCK.NB) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

/// Whether `fd` is still the file at `path` (no one moved it between the open and the lock).
pub fn stillAt(fd: c.fd_t, path: [*:0]const u8) bool {
    var a: c.Stat = undefined;
    var b: c.Stat = undefined;
    if (c.fstat(fd, &a) != 0 or c.stat(path, &b) != 0) return false;
    return a.ino == b.ino and a.dev == b.dev;
}

/// Appends a start line to a task file, first ending its data with a blank line if it has
/// none, so output can never become data. Returns the attempt: 1 + the start lines before.
pub fn startRecord(path: [*:0]const u8, host: []const u8, slot: u32, now_s: i64) ?u32 {
    const fd = c.open(path, .{ .ACCMODE = .RDWR, .APPEND = true, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    // One pass: whether the data has ended (a blank line, or an empty first line), the last
    // byte, and the start lines so far, each found whole across reads by carrying its length.
    const mark = "\n" ++ start_mark;
    var attempt: u32 = 1;
    var blank = false;
    var size: usize = 0;
    var last: u8 = '\n';
    var buf: [16384 + mark.len]u8 = undefined;
    var carried: usize = 0;
    while (true) {
        const n = c.read(fd, buf[carried..].ptr, buf.len - carried);
        if (n <= 0) break;
        const got = buf[0 .. carried + @as(usize, @intCast(n))];
        if (size == 0 and got[0] == '\n') blank = true;
        if (std.mem.find(u8, got, "\n\n") != null) blank = true;
        attempt += @intCast(std.mem.count(u8, got, mark));
        size += @intCast(n);
        last = got[got.len - 1];
        carried = @min(got.len, mark.len - 1);
        std.mem.copyForwards(u8, buf[0..carried], got[got.len - carried ..]);
    }
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    if (!blank) {
        w.writeAll(if (size == 0 or last == '\n') "\n" else "\n\n") catch {};
    }
    var ts: [20]u8 = undefined;
    w.print(start_mark ++ " {s} {s} attempt {d} slot {d}\n", .{ isoTime(&ts, now_s), host, attempt, slot }) catch {};
    writeAll(fd, w.buffered());
    return attempt;
}

pub const start_mark = "==cpuq== start";

/// Appends a task's end line, on a line of its own.
pub fn endRecord(path: [*:0]const u8, status: u8, wall_ms: u64, cpu_ms: u64, peak: u64) void {
    const fd = c.open(path, .{ .ACCMODE = .RDWR, .APPEND = true, .CLOEXEC = true });
    if (fd < 0) return;
    defer _ = c.close(fd);
    var st: c.Stat = undefined;
    var nl = false;
    if (c.fstat(fd, &st) == 0 and st.size > 0) {
        var b: [1]u8 = undefined;
        nl = c.pread(fd, &b, 1, st.size - 1) == 1 and b[0] != '\n';
    }
    var out: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    if (nl) w.writeAll("\n") catch {};
    w.print("==cpuq== end status {d} wall {d}.{d:0>3}s cpu {d}.{d:0>3}s peak {d}\n", .{ status, wall_ms / 1000, wall_ms % 1000, cpu_ms / 1000, cpu_ms % 1000, peak }) catch {};
    writeAll(fd, w.buffered());
}

fn writeAll(fd: c.fd_t, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (n <= 0) return;
        i += @intCast(n);
    }
}

fn isoTime(buf: *[20]u8, now_s: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(now_s, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

test "a base file's keys; a bad line keeps the value it had" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var bad: std.ArrayList([]const u8) = .empty;
    const b = parseBase(a,
        \\cmd: ["./test/run", "--one"]
        \\dir: /repo
        \\env: A=1
        \\env: B=2
        \\weight: 3
        \\max: 50
        \\delay: rand
        \\fork: yes
        \\time: 2m
        \\mem: 2G
        \\
        \\cmd: ignored, the job's own
    , .{}, &bad);
    try std.testing.expectEqualStrings("--one", b.cmd[1]);
    try std.testing.expectEqualStrings("/repo", b.dir);
    try std.testing.expectEqual(2, b.env.len);
    try std.testing.expectEqual(3, b.job.weight);
    try std.testing.expectEqual(50, b.job.max);
    try std.testing.expectEqual(pool.Delay.rand, b.job.delay);
    try std.testing.expect(b.fork);
    try std.testing.expectEqual(120_000, b.limits.time_ms);
    try std.testing.expectEqual(0, bad.items.len);
    const b2 = parseBase(a, "weight: lots\nmax: 7\nnonsense\n", b, &bad);
    try std.testing.expectEqual(3, b2.job.weight);
    try std.testing.expectEqual(7, b2.job.max);
    try std.testing.expectEqual(2, bad.items.len);
    try std.testing.expectEqual(2, b2.env.len);
}

test "stamps" {
    var buf: [15]u8 = undefined;
    try std.testing.expectEqualStrings("20261017-112241", stampNow(&buf, 1792236161));
    try std.testing.expectEqual(20261017112241, stampKey("20261017-112241"));
}

test "a task's record: its data ends at a blank line, then a start and an end line per attempt" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [256]u8 = undefined;
    const n = try tmp.dir.realPathFile(io, ".", &dir_buf);
    var path_buf: [300]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buf, "{s}/t", .{dir_buf[0..n]}, 0);
    try tmp.dir.writeFile(io, .{ .sub_path = "t", .data = "seed: 7" });
    const fd = lockTask(path).?;
    try std.testing.expect(stillAt(fd, path));
    try std.testing.expectEqual(null, lockTask(path)); // a second open can't take the lock
    try std.testing.expectEqual(1, startRecord(path, "pop", 3, 1792236161));
    writeAll(fd, "out");
    endRecord(path, 1, 1500, 250, 4096);
    try std.testing.expectEqual(2, startRecord(path, "pup", 0, 1792236162));
    endRecord(path, 0, 7, 0, 0);
    _ = c.close(fd);
    const fd2 = lockTask(path).?; // closing was the release
    _ = c.close(fd2);
    const text = try tmp.dir.readFileAlloc(io, "t", std.testing.allocator, .limited(1 << 16));
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        \\seed: 7
        \\
        \\==cpuq== start 2026-10-17T11:22:41Z pop attempt 1 slot 3
        \\out
        \\==cpuq== end status 1 wall 1.500s cpu 0.250s peak 4096
        \\==cpuq== start 2026-10-17T11:22:42Z pup attempt 2 slot 0
        \\==cpuq== end status 0 wall 0.007s cpu 0.000s peak 0
        \\
    , text);
}
