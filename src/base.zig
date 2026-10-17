//! `cpuq _base BASEFILE`: the base process of a `fork: no` job, which runs the job's command once
//! per task under `cpuq cap` with the job's limits. It speaks the one protocol every base does,
//! on fd 3: the driver writes `SLOT PATH` a line for each task; the base writes back
//! `STATUS CPU_MS PEAK PATH` when it ends (STATUS 128+N: killed by signal N; PEAK in bytes).
//! End of file on fd 3 means stop: it exits at once. Each task's cap watches a link whose write
//! end only the base holds, so its tasks end with it however it ends, its own cap killed or not;
//! each runs in its own process group, out of reach of the base's cap.
//!
//! Before it forks a task's child, the base opens the task file and takes its lock, and checks
//! that the file is still where it was sent; if not, it runs nothing and answers `- 0 0 PATH`.
//! The child makes that file its stdout and stderr, so the lock lasts as long as anything the
//! task started.
const std = @import("std");
const c = std.c;
const jobs = @import("jobs.zig");
const sys = @import("sys.zig");
const Allocator = std.mem.Allocator;

const proto: c.fd_t = 3;

var wake: [2]c.fd_t = .{ -1, -1 };

fn onChild(_: c.SIG) callconv(.c) void {
    const saved = std.c._errno().*;
    defer std.c._errno().* = saved;
    _ = c.write(wake[1], "x", 1);
}

pub fn main(a: Allocator, io: std.Io, args: []const [:0]const u8) u8 {
    if (args.len != 1) {
        std.debug.print("usage: cpuq _base BASEFILE (started by cpuq's driver, fd 3 its link)\n", .{});
        return 2;
    }
    const text = std.Io.Dir.cwd().readFileAlloc(io, args[0], a, .limited(1 << 20)) catch |err| {
        std.debug.print("cpuq _base: {s}: {t}\n", .{ args[0], err });
        return 125;
    };
    const base = jobs.parseBase(a, text, .{}, null);
    if (base.cmd.len == 0) {
        std.debug.print("cpuq _base: {s}: no cmd\n", .{args[0]});
        return 2;
    }
    const self = std.process.executablePathAlloc(io, a) catch return 125;
    // argv: cpuq cap LIMITS -- CMD... PATH, the last filled per task.
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    argv.append(a, (a.dupeSentinel(u8, self, 0) catch return 125).ptr) catch return 125;
    argv.append(a, "cap") catch return 125;
    var link: [2]c.fd_t = undefined;
    if (c.pipe(&link) != 0) return 125;
    _ = c.fcntl(link[1], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    argv.append(a, "--link") catch return 125;
    argv.append(a, (std.fmt.allocPrintSentinel(a, "{d}", .{link[0]}, 0) catch return 125).ptr) catch return 125;
    const l = base.limits;
    if (l.mem != 0) addFlag(a, &argv, "--mem={d}", l.mem);
    if (l.time_ms != 0) addFlag(a, &argv, "--time={d}ms", l.time_ms);
    if (l.output != 0) addFlag(a, &argv, "--output={d}", l.output);
    if (l.pids != 0) addFlag(a, &argv, "--pids={d}", l.pids);
    argv.append(a, "--") catch return 125;
    for (base.cmd) |arg| argv.append(a, (a.dupeSentinel(u8, arg, 0) catch return 125).ptr) catch return 125;
    const path_at = argv.items.len;
    argv.append(a, null) catch return 125;
    argv.append(a, null) catch return 125;
    // envp: this one's, plus CPUQ_SLOT, filled per task.
    var envp: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (c.environ[i]) |e| : (i += 1) {
        if (!std.mem.startsWith(u8, std.mem.span(e), "CPUQ_SLOT=")) envp.append(a, e) catch return 125;
    }
    const slot_at = envp.items.len;
    envp.append(a, null) catch return 125;
    envp.append(a, null) catch return 125;

    if (c.pipe(&wake) != 0) return 125;
    for (wake) |fd| {
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        _ = c.fcntl(fd, c.F.SETFL, c.fcntl(fd, c.F.GETFL, @as(c_int, 0)) | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }
    var sa: c.Sigaction = .{ .handler = .{ .handler = onChild }, .mask = undefined, .flags = c.SA.RESTART | c.SA.NOCLDSTOP };
    _ = c.sigemptyset(&sa.mask);
    _ = c.sigaction(.CHLD, &sa, null);
    _ = c.fcntl(proto, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));

    var kids: std.AutoHashMapUnmanaged(c.pid_t, [:0]const u8) = .empty;
    var in: std.ArrayList(u8) = .empty;
    while (true) {
        var fds = [_]c.pollfd{
            .{ .fd = proto, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = wake[0], .events = c.POLL.IN, .revents = 0 },
        };
        _ = c.poll(&fds, fds.len, -1);
        if (fds[1].revents != 0) {
            var junk: [64]u8 = undefined;
            while (c.read(wake[0], &junk, junk.len) > 0) {}
            while (sys.reapAny()) |r| {
                const path = (kids.fetchRemove(r[0]) orelse continue).value;
                const w = r[1];
                const status: u32 = switch (w.exit) {
                    .code => |code| code,
                    .signal => |sig| 128 + @as(u32, @intCast(@backingInt(sig))),
                };
                var line: std.ArrayList(u8) = .empty;
                line.print(a, "{d} {d} {d} {s}\n", .{ status, @as(u64, @intFromFloat(w.cpu_s * 1000)), w.peak, path }) catch return 125;
                sys.writeAll(proto, line.items);
                line.deinit(a);
                a.free(path);
            }
        }
        if (fds[0].revents == 0) continue;
        var buf: [4096]u8 = undefined;
        const n = c.read(proto, &buf, buf.len);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) return 0; // the driver closed it: stop; cap ends the tasks still running
        in.appendSlice(a, buf[0..@intCast(n)]) catch return 125;
        while (std.mem.findScalar(u8, in.items, '\n')) |end| {
            const line = in.items[0..end];
            if (std.mem.cutScalar(u8, line, ' ')) |parts| {
                const path = a.dupeSentinel(u8, parts[1], 0) catch return 125;
                const slot = std.fmt.allocPrintSentinel(a, "CPUQ_SLOT={s}", .{parts[0]}, 0) catch return 125;
                argv.items[path_at] = path.ptr;
                envp.items[slot_at] = slot.ptr;
                const fd = jobs.lockTask(path);
                const ok = if (fd) |f| jobs.stillAt(f, path) else false;
                const pid = if (ok) start(fd.?, argv.items[0].?, @ptrCast(argv.items.ptr), @ptrCast(envp.items.ptr)) else -1;
                if (fd) |f| _ = c.close(f);
                a.free(slot);
                if (pid > 0) kids.put(a, pid, path) catch return 125 else {
                    var msg: std.ArrayList(u8) = .empty;
                    msg.print(a, "{s} 0 0 {s}\n", .{ if (ok) "125" else "-", path }) catch return 125;
                    sys.writeAll(proto, msg.items);
                    a.free(path);
                }
            }
            const rest = in.items.len - end - 1;
            std.mem.copyForwards(u8, in.items[0..rest], in.items[end + 1 ..]);
            in.shrinkRetainingCapacity(rest);
        }
    }
}

fn addFlag(a: Allocator, argv: *std.ArrayList(?[*:0]const u8), comptime fmt: []const u8, v: u64) void {
    const s = std.fmt.allocPrintSentinel(a, fmt, .{v}, 0) catch return;
    argv.append(a, s.ptr) catch {};
}

/// Forks the task's child: only async-signal-safe calls between the fork and the exec.
/// `fd` is the task file, locked: the child's stdout and stderr.
fn start(fd: c.fd_t, exe: [*:0]const u8, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c.pid_t {
    const pid = c.fork();
    if (pid != 0) return pid;
    // Its own group: the base's cap, ending the base's group, must not end a task's cap halfway
    // through ending its tree. The link ends the task.
    _ = c.setpgid(0, 0);
    _ = c.dup2(fd, 1);
    _ = c.dup2(fd, 2);
    const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
    if (null_fd > 0) {
        _ = c.dup2(null_fd, 0);
        _ = c.close(null_fd);
    }
    var dfl: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = undefined, .flags = 0 };
    _ = c.sigemptyset(&dfl.mask);
    _ = c.sigaction(.CHLD, &dfl, null);
    _ = c.execve(exe, argv, envp);
    c._exit(127);
}
