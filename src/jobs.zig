//! A job is a folder of task files, run by its own driver: `cpuq jobs run`, in the folder.
//!
//!     ~/.local/state/cpuq/jobs/{name}/{stamp}/     e.g. jobs/rig.large-character-size/20261017-180000/
//!         todo/ live/ done/ fail/    one file per task
//!         jobs.sock                  the running driver's: status, watch, set, pause, resume, stop
//!
//! A task file is the work: its text up to the first blank line runs with `sh -c`. Each run
//! appends its output, then one line: `== TIME HOST pass|fail|died: REASON SECS`. Exit 0 goes to
//! done/, exit 1 to fail/; anything else is a death, back to todo/, and the third goes to fail/.
//!
//! The driver is the only process that moves its folder's files, and it holds the folder's flock
//! while it runs. Each task runs under `cpuq cap --link`, in a process group of its own, with its
//! file (locked) as its stdout and stderr, so a file in live/ whose lock is free runs nowhere, and
//! every task ends when its driver does. Names starting with a dot are being written: never read.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const Io = std.Io;
const sys = @import("sys.zig");
const policy = @import("policy.zig");
const lines = @import("lines.zig");
const table = @import("table.zig");
const main = @import("main.zig");
const Allocator = std.mem.Allocator;

const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;

pub const folders = [_][:0]const u8{ "todo", "live", "done", "fail" };
/// A task's scheduling class: a normal job's (on macOS the caller's, so a task may use the
/// performance cores; nice 5 on Linux).
const task_qos = policy.qosFor(.normal, false, true);
/// The death that sends a task to fail/.
pub const deaths_max = 3;
/// Each new worker starts this long after the last, give or take half.
const stagger_ms = 50;
/// The longest work a task file holds (it is one argument to sh).
const work_max = 256 << 10;
/// Display and watchers: at most this often while something changes, else once a second.
const frame_ms = 300;

// --- Paths and names -------------------------------------------------------------------------

/// cpuq's state on this host: CPUQ_STATE, or ~/.local/state/cpuq. It holds jobs/ and the
/// agent's host.sock.
pub fn stateDir(a: Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("CPUQ_STATE")) |d| return d;
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.local/state/cpuq", .{home}) catch null;
}

/// A job's name: `[a-z0-9._-]`, not starting with a dot.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    for (name) |ch| switch (ch) {
        'a'...'z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// Whether a name in a job's folder is one to read: not a dot-name (being written).
pub fn visible(name: []const u8) bool {
    return name.len != 0 and name[0] != '.';
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

fn isoTime(buf: *[20]u8, now_s: i64) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(now_s, 0)) };
    const day = es.getEpochDay().calculateYearDay();
    const md = day.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        day.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), ds.getMinutesIntoHour(), ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

/// 12.3s, 2m14s, 1h02m.
fn duration(buf: []u8, ms: u64) []const u8 {
    if (ms < 60_000) return std.fmt.bufPrint(buf, "{d}.{d}s", .{ ms / 1000, ms % 1000 / 100 }) catch "";
    if (ms < 3_600_000) return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ ms / 60_000, ms % 60_000 / 1000 }) catch "";
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ ms / 3_600_000, ms % 3_600_000 / 60_000 }) catch "";
}

// --- Task files ------------------------------------------------------------------------------

/// Where a task file's work ends: the blank line after it (the work is `text[0..i]`), or null
/// when it has none (a file never run, all of it work).
pub fn workEnd(text: []const u8) ?usize {
    if (text.len > 0 and text[0] == '\n') return 0;
    return std.mem.find(u8, text, "\n\n");
}

/// Opens a task file to read and append, holding its lock: free only once this descriptor and
/// every copy of it (dups, forks) is closed. Null if it is gone or another holds the lock.
pub fn lockTask(path: [*:0]const u8) ?c.fd_t {
    const fd = c.open(path, .{ .ACCMODE = .RDWR, .APPEND = true, .CLOEXEC = true });
    if (fd < 0) return null;
    if (c.flock(fd, c.LOCK.EX | c.LOCK.NB) != 0) {
        _ = c.close(fd);
        return null;
    }
    return fd;
}

/// The work of the task file open at `fd`, ending the file's work with a blank line first if
/// it has none, so output can never become work.
pub fn takeWork(a: Allocator, fd: c.fd_t) ![:0]u8 {
    const buf = try a.alloc(u8, work_max + 2);
    defer a.free(buf);
    var got: usize = 0;
    while (got < buf.len) {
        const n = c.pread(fd, buf[got..].ptr, buf.len - got, @intCast(got));
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) break;
        got += @intCast(n);
    }
    const text = buf[0..got];
    if (workEnd(text)) |end| return a.dupeSentinel(u8, text[0..end], 0);
    if (got > work_max) return error.WorkTooLong;
    const end: []const u8 = if (got == 0 or text[got - 1] == '\n') "\n" else "\n\n";
    sys.writeAll(fd, end);
    return a.dupeSentinel(u8, std.mem.trimEnd(u8, text, "\n"), 0);
}

/// What a task file's runs say, read as it streams by: its deaths, and its last line of output.
pub const Tally = struct {
    deaths: u32 = 0,
    in_work: bool = true,
    line: [200]u8 = undefined,
    len: usize = 0,
    last: [200]u8 = undefined,
    last_len: usize = 0,
    /// The file's last byte.
    end: u8 = '\n',

    pub fn feed(t: *Tally, bytes: []const u8) void {
        for (bytes) |b| {
            if (b == '\n') {
                t.endLine();
            } else if (t.len < t.line.len) {
                t.line[t.len] = b;
                t.len += 1;
            }
        }
        if (bytes.len > 0) t.end = bytes[bytes.len - 1];
    }

    pub fn finish(t: *Tally) void {
        if (t.len > 0) t.endLine();
    }

    fn endLine(t: *Tally) void {
        defer t.len = 0;
        const l = t.line[0..t.len];
        if (t.in_work) {
            if (l.len == 0) t.in_work = false;
            return;
        }
        if (std.mem.startsWith(u8, l, "== ")) {
            var words = std.mem.tokenizeScalar(u8, l, ' ');
            _ = words.next(); // ==
            _ = words.next(); // the time
            _ = words.next(); // the host
            if (std.mem.startsWith(u8, words.next() orelse "", "died")) t.deaths += 1;
        } else if (std.mem.trim(u8, l, " \t\r").len > 0) {
            @memcpy(t.last[0..l.len], l);
            t.last_len = l.len;
        }
    }

    pub fn lastLine(t: *const Tally) []const u8 {
        return t.last[0..t.last_len];
    }
};

fn tally(path: [*:0]const u8) Tally {
    var t: Tally = .{};
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return t;
    defer _ = c.close(fd);
    var buf: [65536]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) break;
        t.feed(buf[0..@intCast(n)]);
    }
    t.finish();
    return t;
}

/// How a run ended.
pub const Outcome = union(enum) {
    pass,
    fail,
    /// Ended by `stop`: back to todo/, no death.
    stopped,
    died: []const u8,

    /// From cap's exit status (128+N: signal N).
    pub fn of(buf: []u8, status: u32, stopping: bool) Outcome {
        return switch (status) {
            0 => .pass,
            1 => .fail,
            121 => .{ .died = "output limit" },
            122 => .{ .died = "memory limit" },
            123 => if (stopping) .stopped else .{ .died = "driver gone" },
            124 => .{ .died = "time limit" },
            125 => .{ .died = "cap failed" },
            126 => .{ .died = "can't run" },
            127 => .{ .died = "not found" },
            else => .{ .died = if (status > 128)
                std.fmt.bufPrint(buf, "signal {d}", .{status - 128}) catch "signal"
            else
                std.fmt.bufPrint(buf, "exit {d}", .{status}) catch "exit" },
        };
    }
};

/// The line a run appends: `== TIME HOST pass 1.234s`, `… died: time limit 120.000s`,
/// `… died: lost` (no time: its driver was gone).
fn endLine(w: *Io.Writer, now_s: i64, host: []const u8, out: Outcome, ms: ?u64) void {
    var ts: [20]u8 = undefined;
    w.print("== {s} {s} ", .{ isoTime(&ts, now_s), host }) catch {};
    switch (out) {
        .pass => w.writeAll("pass") catch {},
        .fail => w.writeAll("fail") catch {},
        .stopped => w.writeAll("stopped") catch {},
        .died => |why| w.print("died: {s}", .{why}) catch {},
    }
    if (ms) |t| w.print(" {d}.{d:0>3}s", .{ t / 1000, t % 1000 }) catch {};
    w.writeAll("\n") catch {};
}

// --- The snapshot: what the display, `watch` and `status` show --------------------------------

pub const Src = enum { start, agent, set };

pub const Snap = struct {
    name: []const u8,
    stamp: []const u8,
    host: []const u8,
    /// running, paused or stopping.
    state: []const u8,
    workers: u32,
    wsrc: Src,
    weight: f64,
    gap: u32,
    gsrc: Src,
    elapsed_ms: u64,
    todo: u64,
    live: u64,
    done: u64,
    fail: u64,
    /// Deaths this run.
    died: u64,
    /// Tasks this run finished (done or failed): the rate.
    finished: u64,
    /// The driver's pid: its tree is the job's work.
    pid: i32 = 0,
    lives: []const Live = &.{},
    fails: []const Note = &.{},

    pub const Live = struct { ms: u64, name: []const u8 };
    pub const Note = struct { name: []const u8, line: []const u8 };

    /// `snap NAME STAMP HOST STATE WORKERS WSRC WEIGHT GAP GSRC ELAPSED_MS TODO LIVE DONE FAIL
    /// DIED FINISHED PID`, then `live MS NAME` and `fail NAME<tab>LINE` lines, then `end`.
    pub fn write(s: Snap, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("snap {s} {s} {s} {s} {d} {t} {d} {d} {t} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
            s.name,       s.stamp, s.host, s.state, s.workers, s.wsrc, s.weight,   s.gap, s.gsrc,
            s.elapsed_ms, s.todo,  s.live, s.done,  s.fail,    s.died, s.finished, s.pid,
        });
        for (s.lives) |l| try w.print("live {d} {s}\n", .{ l.ms, l.name });
        for (s.fails) |f| try w.print("fail {s}\t{s}\n", .{ f.name, f.line });
        try w.writeAll("end\n");
    }

    /// Reads one snapshot's lines (from `snap` to `end`); null if they aren't one.
    pub fn parse(a: Allocator, text: []const []const u8) ?Snap {
        if (text.len == 0) return null;
        var f = std.mem.tokenizeScalar(u8, text[0], ' ');
        if (!std.mem.eql(u8, f.next() orelse "", "snap")) return null;
        var s: Snap = undefined;
        s.name = f.next() orelse return null;
        s.stamp = f.next() orelse return null;
        s.host = f.next() orelse return null;
        s.state = f.next() orelse return null;
        s.workers = int(u32, f.next()) orelse return null;
        s.wsrc = std.meta.stringToEnum(Src, f.next() orelse "") orelse return null;
        s.weight = std.fmt.parseFloat(f64, f.next() orelse "") catch return null;
        s.gap = int(u32, f.next()) orelse return null;
        s.gsrc = std.meta.stringToEnum(Src, f.next() orelse "") orelse return null;
        inline for (.{ "elapsed_ms", "todo", "live", "done", "fail", "died", "finished" }) |field| {
            @field(s, field) = int(u64, f.next()) orelse return null;
        }
        s.pid = int(i32, f.next()) orelse return null;
        var lives: std.ArrayList(Live) = .empty;
        var fails: std.ArrayList(Note) = .empty;
        for (text[1..]) |line| {
            if (std.mem.startsWith(u8, line, "live ")) {
                const ms, const name = std.mem.cutScalar(u8, line[5..], ' ') orelse continue;
                lives.append(a, .{ .ms = int(u64, ms) orelse 0, .name = name }) catch {};
            } else if (std.mem.startsWith(u8, line, "fail ")) {
                const name, const why = std.mem.cutScalar(u8, line[5..], '\t') orelse .{ line[5..], "" };
                fails.append(a, .{ .name = name, .line = why }) catch {};
            }
        }
        s.lives = lives.items;
        s.fails = fails.items;
        return s;
    }

    /// The display: `height` lines at most, each cut to `width` columns.
    pub fn render(s: Snap, a: Allocator, w: *Io.Writer, width: usize, height: usize, color: bool) void {
        const bold = if (color) "\x1b[1m" else "";
        const dim = if (color) "\x1b[2m" else "";
        const red = if (color) "\x1b[31m" else "";
        const off = if (color) "\x1b[0m" else "";
        var rows: std.ArrayList([]const u8) = .empty;
        const add = struct {
            fn f(al: Allocator, list: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) void {
                list.append(al, std.fmt.allocPrint(al, fmt, args) catch return) catch {};
            }
        }.f;
        var b1: [16]u8 = undefined;
        add(a, &rows, "{s}{s}{s}  {s}  {s}  {s}  {s}", .{ bold, s.name, off, s.stamp, s.host, duration(&b1, s.elapsed_ms), s.state });
        add(a, &rows, "workers {d}{s}  weight {d}  gap {d}ms{s}", .{ s.workers, srcNote(s.wsrc), s.weight, s.gap, srcNote(s.gsrc) });
        const total = s.todo + s.live + s.done + s.fail;
        const ended = s.done + s.fail;
        const pct = if (total == 0) 0 else ended * 100 / total;
        const bar_w: usize = std.math.clamp(width -| 40, 10, 40);
        const filled: usize = if (total == 0) 0 else @intCast(ended * bar_w / total);
        var bar: std.ArrayList(u8) = .empty;
        for (0..bar_w) |i| bar.appendSlice(a, if (i < filled) "█" else "░") catch {};
        var b2: [16]u8 = undefined;
        const left: []const u8 = if (s.finished > 0 and s.elapsed_ms > 0) blk: {
            const eta = (s.todo + s.live) * s.elapsed_ms / s.finished;
            break :blk std.fmt.allocPrint(a, "  ~{s} left", .{duration(&b2, eta)}) catch "";
        } else "";
        add(a, &rows, "{s}  {d}/{d}  {d}%{s}", .{ bar.items, ended, total, pct, left });
        add(a, &rows, "todo {d}  live {d}  done {d}  {s}fail {d}{s}  died {d}", .{ s.todo, s.live, s.done, if (s.fail > 0) red else "", s.fail, off, s.died });
        const fail_rows: usize = if (s.fails.len > 0) s.fails.len + 2 else 0;
        const room = height -| rows.items.len -| fail_rows -| 2;
        if (s.lives.len > 0 and room > 0) {
            add(a, &rows, "", .{});
            add(a, &rows, "{s}live{s}", .{ bold, off });
            const shown = if (s.lives.len > room) room -| 1 else s.lives.len;
            for (s.lives[0..shown]) |l| {
                var b3: [16]u8 = undefined;
                add(a, &rows, "  {s:>7}  {s}", .{ duration(&b3, l.ms), l.name });
            }
            if (shown < s.lives.len) add(a, &rows, "  {s}… and {d} more{s}", .{ dim, s.lives.len - shown, off });
        }
        if (s.fails.len > 0) {
            add(a, &rows, "", .{});
            add(a, &rows, "{s}{s}fail{s}", .{ bold, red, off });
            for (s.fails) |f| add(a, &rows, "  {s}  {s}{s}{s}", .{ f.name, dim, f.line, off });
        }
        for (rows.items[0..@min(rows.items.len, height)], 0..) |row, i| {
            if (i > 0) w.writeAll(if (color) "\x1b[K\n" else "\n") catch {};
            w.writeAll(cut(row, width)) catch {};
        }
        if (color) w.writeAll(off) catch {};
    }
};

fn srcNote(s: Src) []const u8 {
    return switch (s) {
        .start => "",
        .agent => " (agent)",
        .set => " (set)",
    };
}

/// `text` cut to `width` columns, counting a code point as one and an escape as none.
fn cut(text: []const u8, width: usize) []const u8 {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            while (i < text.len and text[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        if (cols == width) return text[0..i];
        i += std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        cols += 1;
    }
    return text;
}

fn int(comptime T: type, s: ?[]const u8) ?T {
    return std.fmt.parseInt(T, s orelse return null, 10) catch null;
}

// --- The result ------------------------------------------------------------------------------

/// The folder's counts, read from disk.
const Counts = struct { todo: u64 = 0, live: u64 = 0, done: u64 = 0, fail: u64 = 0 };

fn countFolders(io: Io) Counts {
    var n: Counts = .{};
    inline for (folders) |f| @field(n, f) = countFiles(io, f);
    return n;
}

fn countFiles(io: Io, sub: []const u8) u64 {
    var dir = Io.Dir.cwd().openDir(io, sub, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var n: u64 = 0;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .file and visible(e.name)) n += 1;
    }
    return n;
}

fn listFiles(io: Io, a: Allocator, sub: []const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, sub, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .file and visible(e.name)) out.append(a, a.dupe(u8, e.name) catch continue) catch {};
    }
    return out.items;
}

/// The verdict, last, after up to 20 of fail/'s files, each with its last 20 lines. Its exit
/// status: 0 PASS, else 1.
fn verdict(io: Io, a: Allocator, out: *std.ArrayList([]const u8), elapsed_ms: ?u64, stopped: bool) u8 {
    const n = countFolders(io);
    const add = struct {
        fn f(al: Allocator, list: *std.ArrayList([]const u8), comptime fmt: []const u8, args: anytype) void {
            list.append(al, std.fmt.allocPrint(al, fmt, args) catch return) catch {};
        }
    }.f;
    var b: [16]u8 = undefined;
    const took: []const u8 = if (elapsed_ms) |ms| std.fmt.allocPrint(a, " in {s}", .{duration(&b, ms)}) catch "" else "";
    if (stopped) {
        add(a, out, "STOPPED: {d} in todo/, {d} done, {d} failed", .{ n.todo + n.live, n.done, n.fail });
        return 1;
    }
    if (n.fail > 0) {
        const names = listFiles(io, a, "fail");
        std.mem.sort([]const u8, names, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (names[0..@min(names.len, 20)]) |name| {
            add(a, out, "fail/{s}:", .{name});
            const path = std.fmt.allocPrint(a, "fail/{s}", .{name}) catch continue;
            for (tail(io, a, path, 20)) |line| add(a, out, "    {s}", .{line});
        }
        if (names.len > 20) add(a, out, "… and {d} more in fail/", .{names.len - 20});
        add(a, out, "FAIL: {d} failed, {d} done{s}{s}", .{ n.fail, n.done, if (n.todo > 0) std.fmt.allocPrint(a, ", {d} in todo/", .{n.todo}) catch "" else "", took });
        return 1;
    }
    if (n.done == 0 and n.todo == 0 and n.live == 0) {
        add(a, out, "FAIL: no tasks", .{});
        return 1;
    }
    if (n.todo + n.live > 0) {
        add(a, out, "FAIL: {d} in todo/, {d} done{s}", .{ n.todo + n.live, n.done, took });
        return 1;
    }
    add(a, out, "PASS: {d} done{s}", .{ n.done, took });
    return 0;
}

/// A file's last `n` lines.
fn tail(io: Io, a: Allocator, path: []const u8, n: usize) []const []const u8 {
    var file = Io.Dir.cwd().openFile(io, path, .{}) catch return &.{};
    defer file.close(io);
    const size = (file.stat(io) catch return &.{}).size;
    const from = size -| 16384;
    const buf = a.alloc(u8, @intCast(size - from)) catch return &.{};
    const got = file.readPositionalAll(io, buf, from) catch return &.{};
    var text = std.mem.trimEnd(u8, buf[0..got], "\n");
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (out.items.len == n) break;
        out.append(a, line) catch break;
    }
    text = "";
    std.mem.reverse([]const u8, out.items);
    return out.items;
}

// --- The driver ------------------------------------------------------------------------------

const Slot = struct { busy: bool = false, free_at: i64 = 0 };

const Task = struct { name: []u8, slot: u32, start_ms: i64 };

const Client = struct { conn: lines.Conn, watch: bool = false, done: bool = false };

const State = enum { running, paused, stopping };

const Driver = struct {
    gpa: Allocator,
    io: Io,
    out: *Io.Writer,
    path: []const u8,
    name: []const u8,
    stamp: []const u8,
    host: []const u8,
    exe: [:0]const u8,
    state_dir: ?[]const u8,
    link_r: c.fd_t,
    link_w: c.fd_t,
    null_fd: c.fd_t,
    listener: c.fd_t,
    prng: std.Random.DefaultPrng,
    started_ms: i64,

    workers: u32,
    wsrc: Src = .start,
    weight: f64,
    gap: u32,
    gsrc: Src = .start,
    state: State = .running,

    slots: std.ArrayList(Slot) = .empty,
    stagger_at: i64 = 0,
    queue: std.ArrayList([]u8) = .empty,
    head: usize = 0,
    queued: std.StringHashMapUnmanaged(void) = .empty,
    todo_mtime: i96 = -1,
    fail_mtime: i96 = -1,
    tasks: std.AutoArrayHashMapUnmanaged(c.pid_t, Task) = .empty,
    /// Files in live/ that this driver isn't running and whose lock is held: an old tree ending.
    held: u32 = 0,
    done: u64 = 0,
    fail: u64 = 0,
    died: u64 = 0,
    finished: u64 = 0,
    avg_ms: f64 = 0,
    notes: std.ArrayList(Snap.Note) = .empty,

    clients: std.ArrayList(*Client) = .empty,
    agent: ?lines.Conn = null,
    agent_try: i64 = 0,
    agent_line: std.ArrayList(u8) = .empty,
    agent_sent: i64 = 0,

    tty: bool,
    version: u64 = 1,
    shown: u64 = 0,
    shown_ms: i64 = 0,
    resized: bool = false,

    fn print(d: *Driver, comptime fmt: []const u8, args: anytype) [:0]u8 {
        return std.fmt.allocPrintSentinel(d.gpa, fmt, args, 0) catch oom();
    }

    fn queueLen(d: *const Driver) usize {
        return d.queue.items.len - d.head;
    }

    // --- The folder ----------------------------------------------------------------------

    /// Adds what's new in todo/ to the queue, oldest first, when the folder has changed.
    fn rescan(d: *Driver, force: bool) void {
        const io = d.io;
        // The folder's time before its names: a file added after the listing changes it again.
        const st = Io.Dir.cwd().statFile(io, "todo", .{}) catch return;
        if (!force and st.mtime.nanoseconds == d.todo_mtime) return;
        d.todo_mtime = st.mtime.nanoseconds;
        var dir = Io.Dir.cwd().openDir(io, "todo", .{ .iterate = true }) catch return;
        defer dir.close(io);
        const New = struct { name: []u8, at: i96 };
        var fresh: std.ArrayList(New) = .empty;
        defer fresh.deinit(d.gpa);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file or !visible(e.name) or d.queued.contains(e.name)) continue;
            const at = if (dir.statFile(io, e.name, .{})) |fs| fs.mtime.nanoseconds else |_| 0;
            fresh.append(d.gpa, .{ .name = d.gpa.dupe(u8, e.name) catch oom(), .at = at }) catch oom();
        }
        std.mem.sort(New, fresh.items, {}, struct {
            fn lt(_: void, x: New, y: New) bool {
                return x.at < y.at or (x.at == y.at and std.mem.lessThan(u8, x.name, y.name));
            }
        }.lt);
        if (d.head > 0 and d.head * 2 > d.queue.items.len) {
            const rest = d.queueLen();
            std.mem.copyForwards([]u8, d.queue.items[0..rest], d.queue.items[d.head..]);
            d.queue.shrinkRetainingCapacity(rest);
            d.head = 0;
        }
        for (fresh.items) |f| {
            d.queue.append(d.gpa, f.name) catch oom();
            d.queued.put(d.gpa, f.name, {}) catch oom();
        }
        if (fresh.items.len > 0) d.version += 1;
    }

    /// Files each file in live/ this driver isn't running whose lock is free: its run died with
    /// a driver before this one. Counts those still held.
    fn sweep(d: *Driver) void {
        var arena: std.heap.ArenaAllocator = .init(d.gpa);
        defer arena.deinit();
        d.held = 0;
        outer: for (listFiles(d.io, arena.allocator(), "live")) |name| {
            for (d.tasks.values()) |t| if (std.mem.eql(u8, t.name, name)) continue :outer;
            const path = d.print("live/{s}", .{name});
            defer d.gpa.free(path);
            const fd = lockTask(path) orelse {
                d.held += 1;
                continue;
            };
            _ = c.close(fd);
            d.file(name, .{ .died = "lost" }, null);
        }
    }

    /// Ends a run: its line appended, its file moved to where its outcome says.
    fn file(d: *Driver, name: []const u8, out: Outcome, ms: ?u64) void {
        const path = d.print("live/{s}", .{name});
        defer d.gpa.free(path);
        const t = tally(path);
        var buf: [512]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        if (t.end != '\n') w.writeAll("\n") catch {};
        endLine(&w, main.nowSeconds(d.io), d.host, out, ms);
        const fd = c.open(path, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true });
        if (fd >= 0) {
            sys.writeAll(fd, w.buffered());
            _ = c.close(fd);
        }
        const dest: []const u8 = switch (out) {
            .pass => "done",
            .fail => "fail",
            .stopped => "todo",
            .died => if (t.deaths + 1 >= deaths_max) "fail" else "todo",
        };
        const to = d.print("{s}/{s}", .{ dest, name });
        defer d.gpa.free(to);
        _ = c.rename(path, to);
        if (out == .died) d.died += 1;
        if (std.mem.eql(u8, dest, "done")) d.done += 1;
        if (std.mem.eql(u8, dest, "fail")) {
            d.fail += 1;
            const line = if (t.last_len > 0) t.lastLine() else switch (out) {
                .died => |why| why,
                else => "",
            };
            d.note(name, line);
        }
        if (out == .pass or out == .fail or std.mem.eql(u8, dest, "fail")) d.finished += 1;
        if (ms) |m| if (out == .pass or out == .fail) {
            const x: f64 = @floatFromInt(m);
            d.avg_ms = if (d.avg_ms == 0) x else d.avg_ms * 0.8 + x * 0.2;
        };
        d.version += 1;
    }

    /// The five latest fails, newest last.
    fn note(d: *Driver, name: []const u8, line: []const u8) void {
        if (d.notes.items.len == 5) {
            const old = d.notes.orderedRemove(0);
            d.gpa.free(old.name);
            d.gpa.free(old.line);
        }
        d.notes.append(d.gpa, .{ .name = d.gpa.dupe(u8, name) catch oom(), .line = d.gpa.dupe(u8, line) catch oom() }) catch oom();
    }

    // --- Workers ---------------------------------------------------------------------------

    /// When the next new worker may start: 50 ms after the last, give or take 25.
    fn stagger(d: *Driver, now: i64) i64 {
        const at = @max(now, d.stagger_at);
        d.stagger_at = at + stagger_ms / 2 + d.prng.random().intRangeLessThan(i64, 0, stagger_ms);
        return at;
    }

    /// A drop lets the workers above `n` finish their tasks; a rise staggers the new ones.
    fn setWorkers(d: *Driver, n: u32, src: Src) void {
        d.wsrc = src;
        if (n == d.workers) return;
        const now = sys.monoMs();
        while (d.slots.items.len < n) d.slots.append(d.gpa, .{}) catch oom();
        for (d.slots.items[@min(d.workers, n)..n]) |*s| if (!s.busy) {
            s.free_at = d.stagger(now);
        };
        d.workers = n;
        d.version += 1;
    }

    fn startDue(d: *Driver, now: i64) void {
        if (d.state != .running) return;
        for (d.slots.items[0..d.workers], 0..) |*s, i| {
            if (d.queueLen() == 0) return;
            if (!s.busy and s.free_at <= now) d.start(@intCast(i), now);
        }
    }

    /// When the next idle worker may start a task.
    fn nextDue(d: *const Driver) i64 {
        var soonest: i64 = std.math.maxInt(i64);
        if (d.state != .running or d.queueLen() == 0) return soonest;
        for (d.slots.items[0..d.workers]) |s| if (!s.busy) {
            soonest = @min(soonest, s.free_at);
        };
        return soonest;
    }

    /// Starts the queue's next task in `slot`, skipping names no longer in todo/.
    fn start(d: *Driver, slot: u32, now: i64) void {
        while (d.queueLen() > 0) {
            const name = d.queue.items[d.head];
            d.head += 1;
            _ = d.queued.remove(name);
            const from = d.print("todo/{s}", .{name});
            defer d.gpa.free(from);
            const path = d.print("live/{s}", .{name});
            defer d.gpa.free(path);
            if (c.rename(from, path) != 0) {
                d.gpa.free(name);
                continue;
            }
            d.version += 1;
            const fd = lockTask(path) orelse {
                d.gpa.free(name);
                continue; // the sweep sees to it
            };
            defer _ = c.close(fd);
            const work = takeWork(d.gpa, fd) catch |err| {
                d.file(name, .{ .died = if (err == error.WorkTooLong) "work too long" else "can't read" }, 0);
                d.gpa.free(name);
                continue;
            };
            defer d.gpa.free(work);
            const link = d.print("{d}", .{d.link_r});
            defer d.gpa.free(link);
            const argv = [_:null]?[*:0]const u8{ d.exe, "cap", "--link", link, "--", "/bin/sh", "-c", work };
            const pid = sys.spawn(d.exe, &argv, @ptrCast(c.environ), task_qos, .{
                .dups = &.{ .{ d.null_fd, 0 }, .{ fd, 1 }, .{ fd, 2 }, .{ d.link_r, d.link_r } },
                .group = true,
            }) catch {
                d.file(name, .{ .died = "can't start" }, 0);
                d.gpa.free(name);
                continue;
            };
            d.tasks.put(d.gpa, pid, .{ .name = name, .slot = slot, .start_ms = now }) catch oom();
            d.slots.items[slot].busy = true;
            return;
        }
    }

    fn reap(d: *Driver) void {
        while (sys.reapAny()) |r| {
            const pid, const w = r;
            const kv = d.tasks.fetchSwapRemove(pid) orelse continue;
            const t = kv.value;
            const now = sys.monoMs();
            const status: u32 = switch (w.exit) {
                .code => |code| code,
                .signal => |sig| 128 + @as(u32, @intCast(@backingInt(sig))),
            };
            var buf: [32]u8 = undefined;
            d.file(t.name, Outcome.of(&buf, status, d.state == .stopping), @intCast(@max(now - t.start_ms, 0)));
            d.gpa.free(t.name);
            d.slots.items[t.slot] = .{ .free_at = now + d.gap };
        }
    }

    /// Every task's cap sees the link close and ends its tree (123): they go back to todo/.
    fn stop(d: *Driver) void {
        if (d.state == .stopping) return;
        d.state = .stopping;
        if (d.link_w >= 0) _ = c.close(d.link_w);
        d.link_w = -1;
        d.version += 1;
    }

    fn over(d: *Driver) bool {
        if (d.tasks.count() > 0 or d.held > 0) return false;
        if (d.state == .stopping) return true;
        if (d.queueLen() > 0) return false;
        d.rescan(true);
        return d.queueLen() == 0;
    }

    // --- Commands, from jobs.sock or relayed by the agent ----------------------------------

    /// Null when done, else why not.
    fn command(d: *Driver, line: []const u8) ?[]const u8 {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = f.next() orelse return "empty command";
        const arg = f.next();
        if (std.mem.eql(u8, verb, "set")) {
            const value = f.next() orelse return "set needs a knob and a value";
            const knob = arg.?;
            if (std.mem.eql(u8, knob, "workers")) {
                const n = int(u32, value) orelse return "workers must be a whole number";
                if (n < 1 or n > 4096) return "workers must be 1 to 4096";
                d.setWorkers(n, .set);
            } else if (std.mem.eql(u8, knob, "weight")) {
                const w = std.fmt.parseFloat(f64, value) catch return "weight must be a number";
                if (!(w >= 0 and w <= 1e6)) return "weight must be 0 to 1000000";
                d.weight = if (w == 0) 1 else w;
            } else if (std.mem.eql(u8, knob, "gap")) {
                const ms = int(u32, value) orelse return "gap must be whole milliseconds";
                if (ms > 600_000) return "gap must be at most 600000 ms";
                d.gap = ms;
                d.gsrc = .set;
            } else return "the knobs are workers, weight and gap";
        } else if (std.mem.eql(u8, verb, "pause")) {
            if (d.state == .running) d.state = .paused;
        } else if (std.mem.eql(u8, verb, "resume")) {
            if (d.state == .paused) d.state = .running;
        } else if (std.mem.eql(u8, verb, "stop")) {
            d.stop();
        } else return "unknown command";
        d.version += 1;
        return null;
    }

    /// The agent's pushes: they give way to a knob a user set.
    fn fromAgent(d: *Driver, line: []const u8) void {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const verb = f.next() orelse return;
        if (std.mem.eql(u8, verb, "workers")) {
            const n = int(u32, f.next()) orelse return;
            if (d.wsrc != .set and n >= 1 and n <= 4096) d.setWorkers(n, .agent);
        } else if (std.mem.eql(u8, verb, "gap")) {
            const ms = int(u32, f.next()) orelse return;
            if (d.gsrc != .set and ms <= 600_000) {
                d.gap = ms;
                d.gsrc = .agent;
                d.version += 1;
            }
        } else _ = d.command(line);
    }

    fn serve(d: *Driver, cl: *Client, scratch: Allocator) void {
        cl.conn.fill(d.gpa);
        while (cl.conn.next()) |line| {
            if (cl.done or cl.watch) continue;
            if (std.mem.eql(u8, line, "status") or std.mem.eql(u8, line, "watch")) {
                d.sendSnap(&cl.conn, scratch);
                cl.watch = line[0] == 'w';
                cl.done = !cl.watch;
            } else {
                if (d.command(line)) |why| cl.conn.print(d.gpa, "error {s}\n", .{why}) else cl.conn.print(d.gpa, "ok\n", .{});
                cl.done = true;
            }
        }
    }

    // --- What others see -------------------------------------------------------------------

    fn snap(d: *Driver, a: Allocator, now: i64) Snap {
        const lives = a.alloc(Snap.Live, d.tasks.count()) catch oom();
        for (d.tasks.values(), lives) |t, *l| l.* = .{ .ms = @intCast(@max(now - t.start_ms, 0)), .name = t.name };
        std.mem.sort(Snap.Live, lives, {}, struct {
            fn lt(_: void, x: Snap.Live, y: Snap.Live) bool {
                return x.ms > y.ms;
            }
        }.lt);
        return .{
            .name = d.name,
            .stamp = d.stamp,
            .host = d.host,
            .state = @tagName(d.state),
            .workers = d.workers,
            .wsrc = d.wsrc,
            .weight = d.weight,
            .gap = d.gap,
            .gsrc = d.gsrc,
            .elapsed_ms = @intCast(@max(now - d.started_ms, 0)),
            .todo = d.queueLen(),
            .live = d.tasks.count(),
            .done = d.done,
            .fail = d.fail,
            .died = d.died,
            .finished = d.finished,
            .pid = sys.getpid(),
            .lives = lives,
            .fails = d.notes.items,
        };
    }

    fn sendSnap(d: *Driver, conn: *lines.Conn, scratch: Allocator) void {
        var buf: Io.Writer.Allocating = .init(scratch);
        d.snap(scratch, sys.monoMs()).write(&buf.writer) catch return;
        conn.print(d.gpa, "{s}", .{buf.written()});
    }

    /// Redraws the display and updates the watchers: at most every 300 ms while something
    /// changes, else once a second (the times move), at once on a resize.
    fn publish(d: *Driver, scratch: Allocator, now: i64) void {
        const due = (d.version != d.shown and now - d.shown_ms >= frame_ms) or now - d.shown_ms >= 1000 or d.resized;
        if (due) {
            d.shown = d.version;
            d.shown_ms = now;
            d.resized = false;
            const s = d.snap(scratch, now);
            if (d.tty) draw(s, scratch, d.out);
            var buf: Io.Writer.Allocating = .init(scratch);
            s.write(&buf.writer) catch {};
            for (d.clients.items) |cl| if (cl.watch) cl.conn.print(d.gpa, "{s}", .{buf.written()});
        }
        if (d.agent) |*ag| {
            var line: Io.Writer.Allocating = .init(scratch);
            const ended = d.done + d.fail;
            line.writer.print("state {t} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{ d.state, d.weight, d.workers, d.gap, d.queueLen(), d.tasks.count(), ended, d.fail, @as(u64, @intFromFloat(d.avg_ms)) }) catch {};
            if (!std.mem.eql(u8, line.written(), d.agent_line.items) and now - d.agent_sent >= 250) {
                d.agent_line.clearRetainingCapacity();
                d.agent_line.appendSlice(d.gpa, line.written()) catch {};
                d.agent_sent = now;
                ag.print(d.gpa, "{s}", .{line.written()});
            }
        }
    }

    fn tryAgent(d: *Driver, now: i64) void {
        if (d.agent != null or now < d.agent_try) return;
        d.agent_try = now + 1000;
        const dir_path = d.state_dir orelse return;
        const dz = d.print("{s}", .{dir_path});
        defer d.gpa.free(dz);
        const dir = c.open(dz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (dir < 0) return;
        defer _ = c.close(dir);
        const fd = lines.connect(dir, "host.sock") orelse return;
        lines.nonblock(fd);
        d.agent = .{ .fd = fd };
        d.agent_line.clearRetainingCapacity();
        d.agent.?.print(d.gpa, "hello {s} pid {d}\n", .{ d.path, sys.getpid() });
    }

    fn readAgent(d: *Driver) void {
        const ag = &d.agent.?;
        ag.fill(d.gpa);
        while (ag.next()) |line| d.fromAgent(line);
        if (ag.closed) {
            ag.deinit(d.gpa);
            d.agent = null; // its last counts stand
        }
    }
};

fn draw(s: Snap, a: Allocator, out: *Io.Writer) void {
    var ws: c.winsize = undefined;
    const ok = c.ioctl(1, c.T.IOCGWINSZ, &ws) == 0 and ws.col > 0 and ws.row > 0;
    const width: usize = if (ok) ws.col else 100;
    const height: usize = if (ok) ws.row else 40;
    out.writeAll("\x1b[H") catch {};
    s.render(a, out, width, height, true);
    out.writeAll("\x1b[K\x1b[J") catch {};
    out.flush() catch {};
}

const screen_on = "\x1b[?1049h\x1b[?25l";
const screen_off = "\x1b[?25h\x1b[?1049l";

fn oom() noreturn {
    fail("out of memory", .{});
}

// --- Signals ---------------------------------------------------------------------------------

var wake: [2]c.fd_t = .{ -1, -1 };
var interrupts: u32 = 0;
var on_screen = false;

fn onSignal(sig: c.SIG) callconv(.c) void {
    const saved = std.c._errno().*;
    defer std.c._errno().* = saved;
    const byte: u8 = switch (sig) {
        .CHLD => 'c',
        .WINCH => 'w',
        .INT => blk: {
            interrupts += 1;
            if (interrupts >= 2) {
                // A second ^C: out now. The tasks end with the link; a restart files them.
                if (on_screen) _ = c.write(1, screen_off, screen_off.len);
                c._exit(1);
            }
            break :blk 's';
        },
        else => 's',
    };
    _ = c.write(wake[1], @ptrCast(&byte), 1);
}

fn pipeFds(fds: *[2]c.fd_t) void {
    if (c.pipe(fds) != 0) fail("no pipes", .{});
}

// --- `cpuq jobs …` ---------------------------------------------------------------------------

pub fn cmdJobs(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (args.len == 0) return listJobs(ctx);
    const sub = args[0];
    const rest = args[1..];
    if (std.mem.eql(u8, sub, "run")) return run(ctx, rest);
    if (std.mem.eql(u8, sub, "status")) return show(ctx, rest, false);
    if (std.mem.eql(u8, sub, "watch")) return show(ctx, rest, true);
    if (std.mem.eql(u8, sub, "reset")) return reset(ctx, rest);
    if (std.mem.eql(u8, sub, "set")) {
        if (rest.len != 2) return usageError("usage: cpuq jobs set workers N | weight W | gap MS", .{});
        return request(ctx, ctx.arena.print("set {s} {s}", .{ rest[0], rest[1] }) catch oom());
    }
    inline for (.{ "pause", "resume", "stop" }) |verb| {
        if (std.mem.eql(u8, sub, verb)) {
            if (rest.len != 0) return usageError("cpuq jobs {s} takes no arguments", .{verb});
            return request(ctx, verb);
        }
    }
    return usageError("unknown jobs command '{s}'", .{sub});
}

/// The folder this runs in: its absolute path, its name and its stamp.
fn here(a: Allocator) struct { []const u8, []const u8, []const u8 } {
    var buf: [4096]u8 = undefined;
    const p = c.getcwd(&buf, buf.len) orelse fail("can't read this folder's path", .{});
    const path = a.dupe(u8, std.mem.sliceTo(p, 0)) catch oom();
    const stamp = std.fs.path.basename(path);
    const name = std.fs.path.basename(std.fs.path.dirname(path) orelse "");
    return .{ path, name, stamp };
}

fn run(ctx: *Ctx, args: []const [:0]const u8) u8 {
    const io = ctx.io;
    var workers: u32 = @max(1, sys.activeCpus(io) / 2);
    var weight: f64 = 1;
    var gap: u32 = 0;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        const v: []const u8 = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, x, "--workers")) {
            workers = int(u32, v) orelse return usageError("--workers needs a whole number, not '{s}'", .{v});
            if (workers < 1 or workers > 4096) return usageError("--workers must be 1 to 4096", .{});
        } else if (std.mem.eql(u8, x, "--weight")) {
            weight = std.fmt.parseFloat(f64, v) catch return usageError("--weight needs a number, not '{s}'", .{v});
            if (!(weight >= 0 and weight <= 1e6)) return usageError("--weight must be 0 to 1000000", .{});
            if (weight == 0) weight = 1;
        } else if (std.mem.eql(u8, x, "--gap")) {
            gap = int(u32, v) orelse return usageError("--gap needs whole milliseconds, not '{s}'", .{v});
            if (gap > 600_000) return usageError("--gap must be at most 600000 ms", .{});
        } else return usageError("unknown option '{s}'", .{x});
        i += 1;
    }
    const path, const name, const stamp = here(ctx.arena);
    if (!validName(name)) fail("'{s}' is not a job's name: [a-z0-9._-], not starting with a dot (run in jobs/NAME/STAMP)", .{name});
    if (!visible(stamp)) fail("'{s}' is being written (a dot-name)", .{stamp});
    for (folders) |f| _ = c.mkdir(f, 0o755);
    // 0, 1 and 2 open, so nothing made below takes their numbers.
    for (0..3) |fd| if (c.fcntl(@intCast(fd), c.F.GETFD) < 0) {
        _ = c.open("/dev/null", .{ .ACCMODE = .RDWR });
    };
    const dir_fd = c.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir_fd < 0) fail("can't open this folder", .{});
    if (c.flock(dir_fd, c.LOCK.EX | c.LOCK.NB) != 0) fail("a driver already runs {s}", .{path});

    var link: [2]c.fd_t = undefined;
    pipeFds(&link);
    pipeFds(&wake);
    // The read end high, so it is never a task's 0, 1 or 2; every cap inherits it.
    const link_r = c.fcntl(link[0], c.F.DUPFD, @as(c_int, 10));
    _ = c.close(link[0]);
    lines.cloexec(link[1]);
    for (wake) |fd| {
        lines.cloexec(fd);
        lines.nonblock(fd);
    }
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    const listener = lines.listen(dir_fd, "jobs.sock") catch |err| fail("jobs.sock: {t}", .{err});
    var sa: c.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = undefined, .flags = c.SA.RESTART | c.SA.NOCLDSTOP };
    _ = c.sigemptyset(&sa.mask);
    for ([_]c.SIG{ .CHLD, .INT, .TERM, .HUP, .WINCH }) |sig| _ = c.sigaction(sig, &sa, null);

    var host_buf: [256]u8 = undefined;
    const host = if (c.gethostname(&host_buf, host_buf.len) == 0) std.mem.sliceTo(std.mem.sliceTo(&host_buf, 0), '.') else "here";
    const exe = std.process.executablePathAlloc(io, ctx.arena) catch |err| fail("cannot find this cpuq: {t}", .{err});
    const gpa = std.heap.c_allocator;
    const now0 = sys.monoMs();
    var d: Driver = .{
        .gpa = gpa,
        .io = io,
        .out = ctx.out,
        .path = path,
        .name = name,
        .stamp = stamp,
        .host = host,
        .exe = ctx.arena.dupeSentinel(u8, exe, 0) catch oom(),
        .state_dir = stateDir(ctx.arena, ctx.env),
        .link_r = link_r,
        .link_w = link[1],
        .null_fd = null_fd,
        .listener = listener,
        .prng = .init(@bitCast(now0)),
        .started_ms = now0,
        .workers = 0,
        .weight = weight,
        .gap = gap,
        .tty = c.isatty(1) == 1,
    };
    d.sweep();
    const n = countFolders(io);
    d.done = n.done;
    d.fail = n.fail;
    d.rescan(true);
    d.setWorkers(workers, .start);
    d.tryAgent(now0);
    if (d.tty) {
        _ = c.write(1, screen_on, screen_on.len);
        on_screen = true;
    }

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    var fds: std.ArrayList(c.pollfd) = .empty;
    var next_tick = now0 + 1000;
    while (true) {
        _ = scratch.reset(.retain_capacity);
        var now = sys.monoMs();
        if (now >= next_tick) {
            next_tick = now + 1000;
            d.rescan(false);
            if (d.held > 0) d.sweep();
            if (Io.Dir.cwd().statFile(io, "fail", .{})) |st| {
                if (st.mtime.nanoseconds != d.fail_mtime) {
                    d.fail_mtime = st.mtime.nanoseconds;
                    d.fail = countFiles(io, "fail"); // a user may have moved them back to todo/
                }
            } else |_| {}
            d.tryAgent(now);
        }
        d.startDue(now);
        if (d.over()) break;
        d.publish(scratch.allocator(), now);

        now = sys.monoMs();
        const frame: i64 = if (d.version != d.shown) d.shown_ms + frame_ms else d.shown_ms + 1000;
        const until = @min(@min(next_tick, d.nextDue()), frame);
        const wait = std.math.clamp(until - now, 0, 1000);
        fds.clearRetainingCapacity();
        fds.append(gpa, .{ .fd = wake[0], .events = c.POLL.IN, .revents = 0 }) catch oom();
        fds.append(gpa, .{ .fd = listener, .events = c.POLL.IN, .revents = 0 }) catch oom();
        const agent_fd: c.fd_t = if (d.agent) |ag| ag.fd else -1;
        const agent_out: i16 = if (d.agent != null and d.agent.?.out.items.len > 0) c.POLL.OUT else 0;
        fds.append(gpa, .{ .fd = agent_fd, .events = c.POLL.IN | agent_out, .revents = 0 }) catch oom();
        for (d.clients.items) |cl| {
            const out: i16 = if (cl.conn.out.items.len > 0) c.POLL.OUT else 0;
            fds.append(gpa, .{ .fd = cl.conn.fd, .events = c.POLL.IN | out, .revents = 0 }) catch oom();
        }
        _ = c.poll(fds.items.ptr, @intCast(fds.items.len), @intCast(wait));

        if (fds.items[0].revents != 0) {
            var got: [64]u8 = undefined;
            while (true) {
                const r = c.read(wake[0], &got, got.len);
                if (r <= 0) break;
                for (got[0..@intCast(r)]) |b| switch (b) {
                    's' => d.stop(),
                    'w' => d.resized = true,
                    else => {},
                };
            }
            d.reap();
        }
        if (fds.items[1].revents != 0) {
            while (lines.accept(listener)) |fd| {
                const cl = gpa.create(Client) catch oom();
                cl.* = .{ .conn = .{ .fd = fd } };
                d.clients.append(gpa, cl) catch oom();
            }
        }
        if (d.agent != null and fds.items[2].revents != 0) {
            if (fds.items[2].revents & c.POLL.OUT != 0) d.agent.?.flush();
            if (fds.items[2].revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) d.readAgent();
        }
        const polled = fds.items[3..];
        var k: usize = d.clients.items.len;
        while (k > 0) {
            k -= 1;
            const cl = d.clients.items[k];
            if (k < polled.len and polled[k].revents != 0) {
                if (polled[k].revents & c.POLL.OUT != 0) cl.conn.flush();
                if (polled[k].revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) d.serve(cl, scratch.allocator());
            }
            if (cl.conn.closed or (cl.done and cl.conn.out.items.len == 0)) {
                cl.conn.deinit(gpa);
                gpa.destroy(cl);
                _ = d.clients.orderedRemove(k);
            }
        }
    }

    // The result: to each watcher, then on the terminal (which may be gone), and as the exit
    // status.
    _ = c.unlink("jobs.sock");
    _ = c.close(listener);
    var out_lines: std.ArrayList([]const u8) = .empty;
    const code = verdict(io, ctx.arena, &out_lines, @intCast(sys.monoMs() - d.started_ms), d.state == .stopping);
    for (d.clients.items) |cl| if (cl.watch) {
        const flags = c.fcntl(cl.conn.fd, c.F.GETFL, @as(c_int, 0));
        _ = c.fcntl(cl.conn.fd, c.F.SETFL, flags & ~@as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        for (out_lines.items) |line| cl.conn.send(gpa, "out {s}\n", .{line});
        cl.conn.send(gpa, "exit {d}\n", .{code});
    };
    if (d.agent) |*ag| {
        ag.print(gpa, "bye\n", .{});
        ag.deinit(gpa);
    }
    if (on_screen) {
        _ = c.write(1, screen_off, screen_off.len);
        on_screen = false;
    }
    for (out_lines.items) |line| ctx.out.print("{s}\n", .{line}) catch {};
    ctx.out.flush() catch {};
    return code;
}

/// The running driver's socket here, or null.
fn connectHere() ?lines.Conn {
    const dir = c.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) return null;
    defer _ = c.close(dir);
    return .{ .fd = lines.connect(dir, "jobs.sock") orelse return null };
}

/// `set`, `pause`, `resume`, `stop`: sent to the driver running here.
fn request(ctx: *Ctx, line: []const u8) u8 {
    const a = ctx.arena;
    var conn = connectHere() orelse fail("no job runs here (no driver on ./jobs.sock)", .{});
    conn.send(a, "{s}\n", .{line});
    const reply = conn.wait(a) orelse fail("the driver closed without answering", .{});
    if (std.mem.eql(u8, reply, "ok")) return 0;
    std.debug.print("cpuq jobs: {s}\n", .{if (std.mem.startsWith(u8, reply, "error ")) reply[6..] else reply});
    return 2;
}

/// `status` (once) and `watch` (until the job ends, then its result and exit status). A job
/// not running shows its folders; `watch` then its verdict when nothing is left to run.
fn show(ctx: *Ctx, args: []const [:0]const u8, watch: bool) u8 {
    if (args.len != 0) return usageError("cpuq jobs {s} takes no arguments", .{if (watch) "watch" else "status"});
    const io = ctx.io;
    const a = ctx.arena;
    const tty = c.isatty(1) == 1;
    var conn = connectHere() orelse {
        const n = countFolders(io);
        _, const name, const stamp = here(a);
        if (!watch or n.todo + n.live > 0) {
            ctx.out.print("{s}  {s}  not running  todo {d}  live {d}  done {d}  fail {d}\n", .{ name, stamp, n.todo, n.live, n.done, n.fail }) catch {};
            return if (watch) 1 else 0;
        }
        var out: std.ArrayList([]const u8) = .empty;
        const code = verdict(io, a, &out, null, false);
        for (out.items) |line| ctx.out.print("{s}\n", .{line}) catch {};
        return code;
    };
    conn.send(a, "{s}\n", .{if (watch) "watch" else "status"});
    var snap_lines: std.ArrayList([]const u8) = .empty;
    var result: std.ArrayList([]const u8) = .empty;
    var frame: std.heap.ArenaAllocator = .init(std.heap.c_allocator);
    if (watch and tty) {
        _ = c.write(1, screen_on, screen_on.len);
        on_screen = true;
        var sa: c.Sigaction = .{ .handler = .{ .handler = leaveWatch }, .mask = undefined, .flags = 0 };
        _ = c.sigemptyset(&sa.mask);
        for ([_]c.SIG{ .INT, .TERM, .HUP }) |sig| _ = c.sigaction(sig, &sa, null);
    }
    defer if (on_screen) {
        _ = c.write(1, screen_off, screen_off.len);
        on_screen = false;
    };
    while (conn.wait(a)) |raw| {
        const line = a.dupe(u8, raw) catch oom();
        if (std.mem.startsWith(u8, line, "out ")) {
            result.append(a, line[4..]) catch oom();
        } else if (std.mem.startsWith(u8, line, "exit ")) {
            if (on_screen) {
                _ = c.write(1, screen_off, screen_off.len);
                on_screen = false;
            }
            for (result.items) |r| ctx.out.print("{s}\n", .{r}) catch {};
            return int(u8, line[5..]) orelse 1;
        } else if (std.mem.eql(u8, line, "end")) {
            _ = frame.reset(.retain_capacity);
            const s = Snap.parse(frame.allocator(), snap_lines.items) orelse fail("the driver sent what isn't a snapshot", .{});
            if (!watch) {
                s.render(frame.allocator(), ctx.out, table.terminalWidth(1) orelse 100, std.math.maxInt(usize), tty);
                ctx.out.writeAll("\n") catch {};
                return 0;
            }
            if (tty) draw(s, frame.allocator(), ctx.out);
            snap_lines.clearRetainingCapacity();
        } else snap_lines.append(a, line) catch oom();
    }
    if (on_screen) {
        _ = c.write(1, screen_off, screen_off.len);
        on_screen = false;
    }
    fail("the driver ended without a result", .{});
}

fn leaveWatch(_: c.SIG) callconv(.c) void {
    _ = c.write(1, screen_off, screen_off.len);
    c._exit(130);
}

/// Every file back in todo/, holding only its work; refused while the job runs.
fn reset(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (args.len != 0) return usageError("cpuq jobs reset takes no arguments", .{});
    const io = ctx.io;
    const a = ctx.arena;
    const dir_fd = c.open(".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir_fd < 0) fail("can't open this folder", .{});
    defer _ = c.close(dir_fd);
    if (c.flock(dir_fd, c.LOCK.EX | c.LOCK.NB) != 0) fail("refused: the job runs (stop it first)", .{});
    var moved: u64 = 0;
    for (folders) |f| {
        for (listFiles(io, a, f)) |name| {
            const path = a.dupeSentinel(u8, ctx.arena.print("{s}/{s}", .{ f, name }) catch oom(), 0) catch oom();
            const fd = c.open(path, .{ .ACCMODE = .RDWR, .CLOEXEC = true });
            if (fd < 0) continue;
            defer _ = c.close(fd);
            var buf: [work_max + 2]u8 = undefined;
            const got = c.pread(fd, &buf, buf.len, 0);
            if (got > 0) if (workEnd(buf[0..@intCast(got)])) |end| {
                _ = c.ftruncate(fd, @intCast(end + 1));
            };
            if (!std.mem.eql(u8, f, "todo")) {
                const to = a.dupeSentinel(u8, ctx.arena.print("todo/{s}", .{name}) catch oom(), 0) catch oom();
                if (c.rename(path, to) != 0) continue;
            }
            moved += 1;
        }
    }
    ctx.out.print("{d} in todo/\n", .{moved}) catch {};
    return 0;
}

/// The snapshot of the driver running in the folder open at `dir`; null when none answers within
/// a second.
pub fn snapAt(a: Allocator, dir: c.fd_t) ?Snap {
    var conn: lines.Conn = .{ .fd = lines.connect(dir, "jobs.sock") orelse return null };
    defer conn.deinit(a);
    lines.nonblock(conn.fd);
    conn.print(a, "status\n", .{});
    const deadline = sys.monoMs() + 1000;
    var got: std.ArrayList([]const u8) = .empty;
    while (true) {
        while (conn.next()) |line| {
            if (std.mem.eql(u8, line, "end")) return Snap.parse(a, got.items);
            got.append(a, a.dupe(u8, line) catch return null) catch return null;
        }
        const left = deadline - sys.monoMs();
        if (conn.closed or left <= 0) return null;
        const out: i16 = if (conn.out.items.len > 0) c.POLL.OUT else 0;
        var pfd = [_]c.pollfd{.{ .fd = conn.fd, .events = c.POLL.IN | out, .revents = 0 }};
        _ = c.poll(&pfd, 1, @intCast(left));
        if (pfd[0].revents & c.POLL.OUT != 0) conn.flush();
        conn.fill(a);
    }
}

/// A running job: its folder and its driver's snapshot.
pub const Running = struct { path: []const u8, snap: Snap };

/// Every job running on this host, by name then stamp.
pub fn running(io: Io, a: Allocator, env: *const std.process.Environ.Map) []Running {
    var out: std.ArrayList(Running) = .empty;
    const state = stateDir(a, env) orelse return &.{};
    const root = a.print("{s}/jobs", .{state}) catch return &.{};
    for (subdirs(io, a, root)) |name| {
        if (!validName(name)) continue;
        const job_dir = a.print("{s}/{s}", .{ root, name }) catch continue;
        for (subdirs(io, a, job_dir)) |stamp| {
            if (!visible(stamp)) continue;
            const path = a.dupeSentinel(u8, a.print("{s}/{s}", .{ job_dir, stamp }) catch continue, 0) catch continue;
            const dir = c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
            if (dir < 0) continue;
            defer _ = c.close(dir);
            const s = snapAt(a, dir) orelse continue;
            out.append(a, .{ .path = path, .snap = s }) catch {};
        }
    }
    return out.items;
}

/// `cpuq jobs`: every job folder on this host, its running driver's snapshot or its folders'
/// counts; nothing when there are none.
fn listJobs(ctx: *Ctx) u8 {
    const io = ctx.io;
    const a = ctx.arena;
    const state = stateDir(a, ctx.env) orelse fail("no HOME, so no jobs folder", .{});
    const root = a.print("{s}/jobs", .{state}) catch oom();
    var rows: std.ArrayList([]const table.Cell) = .empty;
    const names = subdirs(io, a, root);
    for (names) |name| {
        if (!validName(name)) continue;
        const job_dir = a.print("{s}/{s}", .{ root, name }) catch oom();
        const stamps = subdirs(io, a, job_dir);
        std.mem.sort([]const u8, stamps, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return stampKey(x) < stampKey(y);
            }
        }.lt);
        for (stamps) |stamp| {
            if (!visible(stamp)) continue;
            const dir_path = a.dupeSentinel(u8, a.print("{s}/{s}", .{ job_dir, stamp }) catch oom(), 0) catch oom();
            const dir = c.open(dir_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
            if (dir < 0) continue;
            defer _ = c.close(dir);
            const s = snapAt(a, dir);
            const cell = struct {
                fn f(al: Allocator, comptime fmt: []const u8, args: anytype) table.Cell {
                    return .{ .text = std.fmt.allocPrint(al, fmt, args) catch "" };
                }
            }.f;
            if (s) |x| {
                rows.append(a, a.dupe(table.Cell, &.{
                    .{ .text = name },                                                                   .{ .text = stamp },                                 .{ .text = x.state, .tint = .good },
                    cell(a, "{d}", .{x.weight}),                                                         cell(a, "{d}{s}", .{ x.workers, srcNote(x.wsrc) }), cell(a, "{d}", .{x.gap}),
                    cell(a, "{d}", .{x.todo}),                                                           cell(a, "{d}", .{x.live}),                          cell(a, "{d}", .{x.done}),
                    .{ .text = cell(a, "{d}", .{x.fail}).text, .tint = if (x.fail > 0) .bad else null },
                }) catch oom()) catch oom();
            } else {
                const n = countAt(io, a, dir_path);
                rows.append(a, a.dupe(table.Cell, &.{
                    .{ .text = name },                                                                   .{ .text = stamp },        .{ .text = "-", .tint = .dim },
                    .{ .text = "-" },                                                                    .{ .text = "-" },          .{ .text = "-" },
                    cell(a, "{d}", .{n.todo}),                                                           cell(a, "{d}", .{n.live}), cell(a, "{d}", .{n.done}),
                    .{ .text = cell(a, "{d}", .{n.fail}).text, .tint = if (n.fail > 0) .bad else null },
                }) catch oom()) catch oom();
            }
        }
    }
    if (rows.items.len == 0) return 0;
    const t: table.Table = .{
        .title = "jobs",
        .columns = &.{
            .{ .head = "JOB", .tint = .accent, .flexible = true }, .{ .head = "STAMP" },                        .{ .head = "STATE" },
            .{ .head = "WEIGHT", .alignment = .right },            .{ .head = "WORKERS", .alignment = .right }, .{ .head = "GAP", .sub = "ms", .alignment = .right },
            .{ .head = "TODO", .alignment = .right },              .{ .head = "LIVE", .alignment = .right },    .{ .head = "DONE", .alignment = .right },
            .{ .head = "FAIL", .alignment = .right },
        },
        .rows = rows.items,
    };
    t.boxed(a, ctx.out, table.terminalWidth(1), c.isatty(1) == 1) catch {};
    return 0;
}

fn countAt(io: Io, a: Allocator, dir: []const u8) Counts {
    var n: Counts = .{};
    inline for (folders) |f| @field(n, f) = countFiles(io, a.print("{s}/{s}", .{ dir, f }) catch oom());
    return n;
}

fn subdirs(io: Io, a: Allocator, path: []const u8) [][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .directory) out.append(a, a.dupe(u8, e.name) catch continue) catch {};
    }
    std.mem.sort([]const u8, out.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return out.items;
}

// --- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "names and stamps" {
    try testing.expect(validName("rig.large-character-size"));
    try testing.expect(!validName(".rig"));
    try testing.expect(!validName("Rig"));
    try testing.expect(!validName("a b"));
    var buf: [15]u8 = undefined;
    try testing.expectEqualStrings("20261017-112241", stampNow(&buf, 1792236161));
    try testing.expectEqual(20261017112241, stampKey("20261017-112241"));
}

test "a task file's work ends at its first blank line" {
    try testing.expectEqual(null, workEnd("make test"));
    try testing.expectEqual(9, workEnd("make test\n\nout\n== x").?);
    try testing.expectEqual(0, workEnd("\nout").?);
}

test "taking the work ends it with a blank line, once" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "t", .data = "echo hi" });
    const fd = c.openat(tmp.dir.handle, "t", .{ .ACCMODE = .RDWR, .APPEND = true });
    defer _ = c.close(fd);
    const w1 = try takeWork(testing.allocator, fd);
    defer testing.allocator.free(w1);
    try testing.expectEqualStrings("echo hi", w1);
    sys.writeAll(fd, "hi\n");
    const w2 = try takeWork(testing.allocator, fd);
    defer testing.allocator.free(w2);
    try testing.expectEqualStrings("echo hi", w2);
    const text = try tmp.dir.readFileAlloc(io, "t", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("echo hi\n\nhi\n", text);
}

test "a tally counts deaths and keeps the last line of output, across chunks" {
    const text =
        \\./test/run t1
        \\
        \\step one
        \\== 2026-10-17T18:00:00Z pop died: signal 9 1.000s
        \\retry
        \\== 2026-10-17T18:00:02Z pop died: time limit 120.000s
        \\last words
        \\== 2026-10-17T18:00:04Z pop fail 0.500s
        \\
    ;
    var t: Tally = .{};
    var i: usize = 0;
    while (i < text.len) : (i += 7) t.feed(text[i..@min(i + 7, text.len)]);
    t.finish();
    try testing.expectEqual(2, t.deaths);
    try testing.expectEqualStrings("last words", t.lastLine());
}

test "outcomes and their lines" {
    var buf: [32]u8 = undefined;
    try testing.expectEqual(Outcome.pass, Outcome.of(&buf, 0, false));
    try testing.expectEqual(Outcome.fail, Outcome.of(&buf, 1, false));
    try testing.expectEqual(Outcome.stopped, Outcome.of(&buf, 123, true));
    try testing.expectEqualStrings("driver gone", Outcome.of(&buf, 123, false).died);
    try testing.expectEqualStrings("signal 9", Outcome.of(&buf, 137, false).died);
    try testing.expectEqualStrings("exit 2", Outcome.of(&buf, 2, false).died);
    var out: [256]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    endLine(&w, 1792236161, "pop", .{ .died = "time limit" }, 120_000);
    endLine(&w, 1792236161, "pop", .{ .died = "lost" }, null);
    endLine(&w, 1792236161, "pop", .pass, 1234);
    try testing.expectEqualStrings(
        \\== 2026-10-17T11:22:41Z pop died: time limit 120.000s
        \\== 2026-10-17T11:22:41Z pop died: lost
        \\== 2026-10-17T11:22:41Z pop pass 1.234s
        \\
    , w.buffered());
}

test "a snapshot reads back as it was written, and renders" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Snap = .{
        .name = "rig.t",
        .stamp = "20261017-180000",
        .host = "pop",
        .state = "running",
        .workers = 6,
        .wsrc = .agent,
        .weight = 2.5,
        .gap = 40,
        .gsrc = .start,
        .elapsed_ms = 134_000,
        .todo = 8000,
        .live = 2,
        .done = 4200,
        .fail = 1,
        .died = 3,
        .finished = 4201,
        .pid = 4242,
        .lives = &.{ .{ .ms = 12_300, .name = "t 0042" }, .{ .ms = 800, .name = "t0043" } },
        .fails = &.{.{ .name = "t0007", .line = "expected 3, got 4" }},
    };
    var buf: Io.Writer.Allocating = .init(a);
    try s.write(&buf.writer);
    var got: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, buf.written(), "\n"), '\n');
    while (it.next()) |l| try got.append(a, l);
    const r = Snap.parse(a, got.items).?;
    try testing.expectEqualStrings("rig.t", r.name);
    try testing.expectEqual(Src.agent, r.wsrc);
    try testing.expectEqual(2.5, r.weight);
    try testing.expectEqual(4201, r.finished);
    try testing.expectEqual(4242, r.pid);
    try testing.expectEqualStrings("t 0042", r.lives[0].name);
    try testing.expectEqualStrings("expected 3, got 4", r.fails[0].line);
    var view: Io.Writer.Allocating = .init(a);
    r.render(a, &view.writer, 80, 40, false);
    try testing.expect(std.mem.find(u8, view.written(), "workers 6 (agent)  weight 2.5  gap 40ms") != null);
    try testing.expect(std.mem.find(u8, view.written(), "4201/12203  34%") != null);
    try testing.expect(std.mem.find(u8, view.written(), "    12.3s  t 0042") != null);
}
