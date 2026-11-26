//! A test's tasks (`cpuq test`, a spec with `tasks`): a folder of task files, run through the
//! pool one task per CPU.
//!
//!     ~/.local/state/cpuq/jobs/{job}/{stamp}/    one per submitted test
//!         todo/ done/ fail/                      one file per task
//!         manifest                               the names in todo/, sorted, one a line
//!
//! The spec's `tasks` command writes the files into todo/. The host then lists them in the
//! manifest and runs `cpuq run -n COUNT -- cpuq _task FOLDER`: task N runs the file named on
//! line N. A file's work is its text up to the first blank line, run by /bin/sh -c in the
//! folder; its output is appended to the file, then `== TIME HOST OUTCOME SECONDS`, and the file
//! moves to done/ (exit 0) or fail/ (anything else). Only that task touches its file. A task cut
//! off leaves its file in todo/.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const c = std.c;
const sys = @import("sys.zig");

/// cpuq's state on this host: CPUQ_STATE, or ~/.local/state/cpuq. It holds jobs/.
pub fn stateDir(a: Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("CPUQ_STATE")) |d| return d;
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.local/state/cpuq", .{home}) catch null;
}

/// Whether a name in a task folder is one to read: not a dot-name (being written).
pub fn visible(name: []const u8) bool {
    return name.len != 0 and name[0] != '.';
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

/// A task file's last line of output (after its work and before or between its `==` lines),
/// read as it streams by.
pub const Tally = struct {
    in_work: bool = true,
    line: [200]u8 = undefined,
    len: usize = 0,
    last: [200]u8 = undefined,
    last_len: usize = 0,

    pub fn feed(t: *Tally, bytes: []const u8) void {
        for (bytes) |b| {
            if (b == '\n') {
                t.endLine();
            } else if (t.len < t.line.len) {
                t.line[t.len] = b;
                t.len += 1;
            }
        }
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
        if (std.mem.startsWith(u8, l, "== ")) return;
        if (std.mem.trim(u8, l, " \t\r").len > 0) {
            @memcpy(t.last[0..l.len], l);
            t.last_len = l.len;
        }
    }

    pub fn lastLine(t: *const Tally) []const u8 {
        return t.last[0..t.last_len];
    }
};

/// Writes the folder's manifest: the names in todo/, sorted. Returns how many.
pub fn manifest(io: Io, a: Allocator, folder: []const u8) usize {
    var names: std.ArrayList([]const u8) = .empty;
    const todo = std.fmt.allocPrint(a, "{s}/todo", .{folder}) catch return 0;
    var dir = Io.Dir.cwd().openDir(io, todo, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file or !visible(e.name)) continue;
        names.append(a, a.dupe(u8, e.name) catch continue) catch {};
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    for (names.items) |n| out.print(a, "{s}\n", .{n}) catch {};
    const path = std.fmt.allocPrint(a, "{s}/manifest", .{folder}) catch return 0;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch return 0;
    for ([_][]const u8{ "done", "fail" }) |sub| {
        Io.Dir.cwd().createDirPath(io, std.fmt.allocPrint(a, "{s}/{s}", .{ folder, sub }) catch continue) catch {};
    }
    return names.items.len;
}

/// `cpuq _task FOLDER`: runs the task named on line $CPUQ_TASK of the folder's manifest. Exit 0
/// for a pass, 1 for a failure, 125 when the task can't be found or run.
pub fn cmdTask(io: Io, a: Allocator, env: *std.process.Environ.Map, args: []const [:0]const u8) u8 {
    if (args.len != 1) {
        std.debug.print("cpuq: _task needs a task folder\n", .{});
        return 2;
    }
    const folder = args[0];
    const n = std.fmt.parseInt(usize, env.get("CPUQ_TASK") orelse "", 10) catch {
        std.debug.print("cpuq: _task runs as a task of cpuq run -n (CPUQ_TASK)\n", .{});
        return 2;
    };
    const list = Io.Dir.cwd().readFileAlloc(io, std.fmt.allocPrint(a, "{s}/manifest", .{folder}) catch return 125, a, .limited(64 << 20)) catch {
        std.debug.print("cpuq: {s}: no manifest\n", .{folder});
        return 125;
    };
    var lines = std.mem.tokenizeScalar(u8, list, '\n');
    var i: usize = 1;
    const name = while (lines.next()) |l| : (i += 1) {
        if (i == n) break l;
    } else {
        std.debug.print("cpuq: {s}: no task {d}\n", .{ folder, n });
        return 125;
    };
    const path = std.fmt.allocPrint(a, "{s}/todo/{s}", .{ folder, name }) catch return 125;
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16 << 20)) catch {
        // Gone from todo/: an earlier run filed it.
        return 0;
    };
    const work = if (std.mem.find(u8, text, "\n\n")) |cut| text[0..cut] else std.mem.trimEnd(u8, text, "\n");
    const pathz = a.dupeSentinel(u8, path, 0) catch return 125;
    const fd = c.open(pathz, .{ .ACCMODE = .WRONLY, .APPEND = true, .CLOEXEC = true });
    if (fd < 0) return 125;
    defer _ = c.close(fd);
    // The work ends with a blank line, so what it prints reads as output.
    if (std.mem.find(u8, text, "\n\n") == null) sys.writeAll(fd, if (std.mem.endsWith(u8, text, "\n")) "\n" else "\n\n");

    const workz = a.dupeSentinel(u8, work, 0) catch return 125;
    const argv = [_:null]?[*:0]const u8{ "/bin/sh", "-c", workz };
    const envp = env.createPosixBlock(a, .{}) catch return 125;
    const folderz = a.dupeSentinel(u8, folder, 0) catch return 125;
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    const dups = [_][2]c.fd_t{ .{ null_fd, 0 }, .{ fd, 1 }, .{ fd, 2 } };
    const t0 = sys.monoMs();
    const pid = sys.spawn("/bin/sh", &argv, @ptrCast(envp.slice.ptr), .unchanged, .{ .dups = &dups, .dir = folderz, .pdeath = true }) catch return 125;
    if (null_fd >= 0) _ = c.close(null_fd);
    sys.setChild(pid);
    sys.installForwarding();
    const w = sys.waitChild(pid);
    const ms: u64 = @intCast(@max(sys.monoMs() - t0, 0));

    var host_buf: [256]u8 = undefined;
    const host = hostName(&host_buf);
    var ts: [20]u8 = undefined;
    var line_buf: [512]u8 = undefined;
    var lw: Io.Writer = .fixed(&line_buf);
    const pass = switch (w.exit) {
        .code => |code| code == 0,
        .signal => false,
    };
    lw.print("== {s} {s} ", .{ isoTime(&ts, std.Io.Clock.real.now(io).toSeconds()), host }) catch {};
    switch (w.exit) {
        .code => |code| switch (code) {
            0 => lw.writeAll("pass") catch {},
            1 => lw.writeAll("fail") catch {},
            else => lw.print("died: exit {d}", .{code}) catch {},
        },
        .signal => |sig| lw.print("died: signal {d}", .{@backingInt(sig)}) catch {},
    }
    lw.print(" {d}.{d:0>3}s\n", .{ ms / 1000, ms % 1000 }) catch {};
    sys.writeAll(fd, lw.buffered());
    const to = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ folder, if (pass) "done" else "fail", name }) catch return 125;
    Io.Dir.cwd().rename(path, Io.Dir.cwd(), to, io) catch return 125;
    return if (pass) 0 else 1;
}

/// The folder's verdict, appended to `log`: each failure's last lines (the first 20 failures),
/// then `PASS: N done`, `FAIL: F failed, N done[, T in todo/]` or `FAIL: no tasks`. Returns 0 for
/// a pass, 1 otherwise.
pub fn verdict(io: Io, a: Allocator, folder: []const u8, log: []const u8) u8 {
    var out: std.ArrayList(u8) = .empty;
    const counts = .{ count(io, a, folder, "done"), count(io, a, folder, "fail"), count(io, a, folder, "todo") };
    const done, const failed, const todo = counts;
    var code: u8 = 0;
    if (failed.len > 0) {
        for (failed[0..@min(failed.len, 20)]) |name| {
            out.print(a, "fail/{s}:\n", .{name}) catch {};
            const text = Io.Dir.cwd().readFileAlloc(io, std.fmt.allocPrint(a, "{s}/fail/{s}", .{ folder, name }) catch continue, a, .limited(16 << 20)) catch continue;
            var lines: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
            while (it.next()) |l| lines.append(a, l) catch {};
            const from = lines.items.len -| 20;
            for (lines.items[from..]) |l| out.print(a, "    {s}\n", .{l}) catch {};
        }
        if (failed.len > 20) out.print(a, "... and {d} more in fail/\n", .{failed.len - 20}) catch {};
    }
    if (done.len + failed.len + todo.len == 0) {
        out.appendSlice(a, "FAIL: no tasks\n") catch {};
        code = 1;
    } else if (failed.len > 0 or todo.len > 0) {
        out.print(a, "FAIL: {d} failed, {d} done", .{ failed.len, done.len }) catch {};
        if (todo.len > 0) out.print(a, ", {d} in todo/", .{todo.len}) catch {};
        out.appendSlice(a, "\n") catch {};
        code = 1;
    } else out.print(a, "PASS: {d} done\n", .{done.len}) catch {};
    const logz = a.dupeSentinel(u8, log, 0) catch return code;
    const fd = c.open(logz, .{ .ACCMODE = .WRONLY, .APPEND = true, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
    if (fd >= 0) {
        sys.writeAll(fd, out.items);
        _ = c.close(fd);
    }
    return code;
}

fn count(io: Io, a: Allocator, folder: []const u8, sub: []const u8) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, std.fmt.allocPrint(a, "{s}/{s}", .{ folder, sub }) catch return &.{}, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .file and visible(e.name)) names.append(a, a.dupe(u8, e.name) catch continue) catch {};
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return names.items;
}

fn hostName(buf: *[256]u8) []const u8 {
    if (c.gethostname(buf, buf.len) != 0) return "?";
    const name = std.mem.sliceTo(buf, 0);
    return name[0 .. std.mem.findScalar(u8, name, '.') orelse name.len];
}

test "Tally: the last line of output, past the work and the == lines" {
    var t: Tally = .{};
    t.feed("make check\n\nok 1\nnot ok 2 - boom\n== 2026-11-26T00:00:00Z pup fail 1.000s\n");
    t.finish();
    try std.testing.expectEqualStrings("not ok 2 - boom", t.lastLine());
}
