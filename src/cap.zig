//! `cpuq cap`: one program under limits on its memory, its time and its output, for a test
//! runner that starts thousands of them.
//!
//! Inside a cpuq job on Linux (`CPUQ_CGROUP` names the job's delegated cgroup), the program is
//! born in a cgroup of its own beside the job's: `clone3(CLONE_INTO_CGROUP)`, with no write to
//! `cgroup.procs` (which takes a lock that stalls every fork on the machine). The kernel enforces
//! the memory limit (`memory.max`, no swap, the whole cgroup killed), `memory.events.local` says
//! whether it did, and `cgroup.kill` stops everything the program started.
//!
//! Elsewhere (macOS, or Linux outside a job) the program gets its own process group, its memory is
//! read once a second from its own process tree, never from a list of every process on the
//! machine, and stopping it freezes, walks and kills that tree until nothing is left.
//!
//! Either way the program's end wakes cpuq at once (SIGCHLD through a pipe), the time limit is a
//! timer, and a program that ends quickly costs a fork and an exec.

const std = @import("std");
const builtin = @import("builtin");
const policy = @import("policy.zig");
const sys = @import("sys.zig");
const c = std.c;

const is_linux = builtin.os.tag == .linux;
const linux = std.os.linux;

/// Stopped for printing too much, for memory, for time.
pub const exit_output: u8 = 121;
pub const exit_memory: u8 = 122;
pub const exit_time: u8 = 124;
const exit_failure: u8 = 125;
const exit_usage: u8 = 2;

pub const usage =
    \\usage: cpuq cap [--mem SIZE] [--time DURATION] [--output SIZE] [--pids N] [--] PROGRAM [ARGS...]
    \\  --mem SIZE        stop PROGRAM when it and everything it started use more memory (2G, 512M)
    \\  --time DURATION   stop it after this long (120, 120s, 2m, 1h, 500ms)
    \\  --output SIZE     stop it when it has written more than this to stdout and stderr, which
    \\                    must be files or /dev/null (1M)
    \\  --pids N          at most N processes and threads at once (inside a cpuq job on Linux)
    \\exit: PROGRAM's own (death by a signal passed on as one); stopped by cpuq: 122 memory,
    \\124 time, 121 output, each with a line on stderr; 125 cpuq failed; 127 PROGRAM not found
    \\
;

pub const Limits = struct {
    mem: u64 = 0,
    time_ms: u64 = 0,
    output: u64 = 0,
    pids: u64 = 0,
};

/// A duration: a number of seconds, or a number with ms, s, m or h; fractions allowed.
pub fn parseDuration(s: []const u8) ?u64 {
    const units = [_]struct { suffix: []const u8, ms: f64 }{
        .{ .suffix = "ms", .ms = 1 },
        .{ .suffix = "s", .ms = 1000 },
        .{ .suffix = "m", .ms = 60_000 },
        .{ .suffix = "h", .ms = 3_600_000 },
    };
    var num = s;
    var scale: f64 = 1000;
    for (units) |u| {
        if (std.mem.endsWith(u8, s, u.suffix)) {
            num = s[0 .. s.len - u.suffix.len];
            scale = u.ms;
            break;
        }
    }
    if (num.len == 0) return null;
    const v = std.fmt.parseFloat(f64, num) catch return null;
    if (!(v > 0) or v * scale > 1e15) return null;
    return @intFromFloat(@max(v * scale, 1));
}

test "durations" {
    try std.testing.expectEqual(@as(?u64, 120_000), parseDuration("120"));
    try std.testing.expectEqual(@as(?u64, 120_000), parseDuration("120s"));
    try std.testing.expectEqual(@as(?u64, 120_000), parseDuration("2m"));
    try std.testing.expectEqual(@as(?u64, 3_600_000), parseDuration("1h"));
    try std.testing.expectEqual(@as(?u64, 500), parseDuration("500ms"));
    try std.testing.expectEqual(@as(?u64, 1500), parseDuration("1.5s"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("soon"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("0"));
    try std.testing.expectEqual(@as(?u64, null), parseDuration("s"));
}

fn bad(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("cpuq cap: " ++ fmt ++ "\n" ++ usage, args);
    return exit_usage;
}

// --- Signals: the program's end and cpuq's own signals wake the wait through a pipe ----------

var wake: [2]c.fd_t = .{ -1, -1 };
var child_pid = std.atomic.Value(c.pid_t).init(0);

const passed_on = [_]c.SIG{ .HUP, .INT, .QUIT, .TERM };

fn onSignal(sig: c.SIG, _: *const c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const saved = std.c._errno().*;
    defer std.c._errno().* = saved;
    // The program gets cpuq's own signals, as from `cpuq run`; its end decides cpuq's.
    if (sig != .CHLD) {
        const pid = child_pid.load(.acquire);
        if (pid > 0) _ = c.kill(pid, sig);
    }
    if (wake[1] >= 0) _ = c.write(wake[1], "x", 1);
}

fn sigset(sigs: []const c.SIG) c.sigset_t {
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    for (sigs) |s| _ = c.sigaddset(&set, s);
    return set;
}

const handled = [_]c.SIG{ .CHLD, .HUP, .INT, .QUIT, .TERM };

fn installSignals() bool {
    if (c.pipe(&wake) != 0) return false;
    for (wake) |fd| {
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        const fl = c.fcntl(fd, c.F.GETFL, @as(c_int, 0));
        _ = c.fcntl(fd, c.F.SETFL, fl | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }
    var sa: c.Sigaction = .{ .handler = .{ .sigaction = onSignal }, .mask = undefined, .flags = c.SA.SIGINFO | c.SA.RESTART | c.SA.NOCLDSTOP };
    _ = c.sigemptyset(&sa.mask);
    _ = c.sigaction(.CHLD, &sa, null);
    for (passed_on) |sig| {
        var old: c.Sigaction = undefined;
        if (c.sigaction(sig, null, &old) == 0 and old.handler.handler == c.SIG.IGN) continue;
        _ = c.sigaction(sig, &sa, null);
    }
    return true;
}

fn drainWake() void {
    var buf: [64]u8 = undefined;
    while (c.read(wake[0], &buf, buf.len) > 0) {}
}

// --- Small files: cgroup controls and /proc entries, read and written whole ------------------

/// Reads `path` into `buf`, to EOF or until `buf` is full; null when it can't be opened.
fn readInto(path: [*:0]const u8, buf: []u8) ?[]const u8 {
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var n: usize = 0;
    while (n < buf.len) {
        const r = c.read(fd, buf[n..].ptr, buf.len - n);
        if (r < 0 and c.errno(r) == .INTR) continue;
        if (r <= 0) break;
        n += @intCast(r);
    }
    return buf[0..n];
}

fn writeFile(path: [*:0]const u8, value: []const u8) bool {
    const fd = c.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    if (fd < 0) return false;
    defer _ = c.close(fd);
    return c.write(fd, value.ptr, value.len) == @as(isize, @intCast(value.len));
}

fn pathZ(buf: []u8, comptime fmt: []const u8, args: anytype) ?[*:0]const u8 {
    const s = std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch return null;
    return s.ptr;
}

fn sleepMs(ms: u32) void {
    var fds = [_]c.pollfd{};
    _ = c.poll(&fds, 0, @intCast(ms));
}

// --- The program's cgroup (Linux, inside a cpuq job) ----------------------------------------

const Cgroup = struct {
    path_buf: [512]u8 = undefined,
    len: usize = 0,
    /// An O_PATH descriptor of the cgroup, for clone3.
    fd: c.fd_t = -1,

    fn path(cg: *const Cgroup) []const u8 {
        return cg.path_buf[0..cg.len];
    }

    fn file(cg: *const Cgroup, buf: []u8, name: []const u8) ?[*:0]const u8 {
        return pathZ(buf, "{s}/{s}", .{ cg.path(), name });
    }

    fn set(cg: *const Cgroup, name: []const u8, value: []const u8) bool {
        var b: [600]u8 = undefined;
        return writeFile(cg.file(&b, name) orelse return false, value);
    }

    /// The value of `key` in a flat keyed file (memory.events.local, cgroup.events).
    fn field(cg: *const Cgroup, name: []const u8, key: []const u8) u64 {
        var b: [600]u8 = undefined;
        var text_buf: [1024]u8 = undefined;
        const text = readInto(cg.file(&b, name) orelse return 0, &text_buf) orelse return 0;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            if (!std.mem.eql(u8, f.next() orelse continue, key)) continue;
            return std.fmt.parseInt(u64, f.next() orelse return 0, 10) catch 0;
        }
        return 0;
    }

    /// A cgroup for one program beside the job's own `job/`, limited as `limits` say. Null when
    /// it can't have one: no parent, this process not inside it, or the memory controller not
    /// enabled for the parent's children.
    fn make(parent: []const u8, limits: Limits) ?Cgroup {
        if (!is_linux or parent.len == 0) return null;
        if (!insideOf(parent)) return null;
        var b: [600]u8 = undefined;
        var ctl_buf: [256]u8 = undefined;
        const control = readInto(pathZ(&b, "{s}/cgroup.subtree_control", .{parent}) orelse return null, &ctl_buf) orelse return null;
        if (std.mem.find(u8, control, "memory") == null) return null;
        var cg: Cgroup = .{};
        // The pid and the start time: a cgroup left by an earlier cap with this pid, which was
        // never removed, can't make this one fail.
        const name = std.fmt.bufPrint(&cg.path_buf, "{s}/cap-{d}-{d}", .{ parent, sys.getpid(), sys.monoMs() }) catch return null;
        cg.len = name.len;
        const dir = pathZ(&b, "{s}", .{cg.path()}) orelse return null;
        if (c.mkdir(dir, 0o755) != 0) return null;
        var ok = true;
        if (limits.mem != 0) {
            var num: [24]u8 = undefined;
            ok = cg.set("memory.max", std.fmt.bufPrint(&num, "{d}", .{limits.mem}) catch unreachable);
            _ = cg.set("memory.swap.max", "0");
            _ = cg.set("memory.oom.group", "1");
        }
        if (ok and limits.pids != 0) {
            var num: [24]u8 = undefined;
            ok = cg.set("pids.max", std.fmt.bufPrint(&num, "{d}", .{limits.pids}) catch unreachable);
        }
        cg.fd = c.open(dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .PATH = true });
        if (!ok or cg.fd < 0) {
            cg.remove();
            return null;
        }
        return cg;
    }

    /// Kills everything still in it, waits until it is empty, and removes it.
    fn remove(cg: *const Cgroup) void {
        if (cg.fd >= 0) _ = c.close(cg.fd);
        if (cg.field("cgroup.events", "populated") != 0) _ = cg.set("cgroup.kill", "1");
        var b: [600]u8 = undefined;
        const dir = pathZ(&b, "{s}", .{cg.path()}) orelse return;
        // Killed processes leave as the kernel tears them down: a few milliseconds.
        var i: usize = 0;
        while (c.rmdir(dir) != 0 and i < 400) : (i += 1) {
            reapAll();
            sleepMs(5);
        }
    }
};

/// Whether this process is in `parent` or below it: a stale CPUQ_CGROUP from some other job
/// must not get cgroups made in it.
fn insideOf(parent: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const text = readInto("/proc/self/cgroup", &buf) orelse return false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::")) continue;
        var full: [600]u8 = undefined;
        const own = std.fmt.bufPrint(&full, "/sys/fs/cgroup{s}", .{line[3..]}) catch return false;
        return std.mem.startsWith(u8, own, parent) and (own.len == parent.len or own[parent.len] == '/');
    }
    return false;
}

/// struct clone_args, up to `cgroup` (CLONE_ARGS_SIZE_VER2).
const CloneArgs = extern struct {
    flags: u64 = 0,
    pidfd: u64 = 0,
    child_tid: u64 = 0,
    parent_tid: u64 = 0,
    exit_signal: u64 = 0,
    stack: u64 = 0,
    stack_size: u64 = 0,
    tls: u64 = 0,
    set_tid: u64 = 0,
    set_tid_size: u64 = 0,
    cgroup: u64 = 0,
};

/// fork(2), but with the child born in the cgroup `cg_fd`: 0 in the child, its pid in the
/// parent, -errno on failure.
fn forkInto(cg_fd: c.fd_t) isize {
    var args: CloneArgs = .{ .flags = linux.CLONE.INTO_CGROUP, .exit_signal = @intFromEnum(c.SIG.CHLD), .cgroup = @intCast(cg_fd) };
    const rc = linux.syscall2(.clone3, @intFromPtr(&args), @sizeOf(CloneArgs));
    if (linux.errno(rc) != .SUCCESS) return -@as(isize, @intCast(@intFromEnum(linux.errno(rc))));
    return @intCast(rc);
}

// --- The program's own process tree ---------------------------------------------------------

extern "c" fn proc_listchildpids(ppid: c_int, buffer: ?*anyopaque, size: c_int) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *anyopaque) c_int;
extern "c" fn prctl(option: c_int, ...) c_int;

/// The tree below `root`, `root` excluded, into `out`; returns how many. Linux reads each
/// process's own children (/proc/PID/task/TID/children); macOS asks for them
/// (proc_listchildpids). Only the tree is visited, however many processes the machine runs.
fn descendants(root: c.pid_t, out: []c.pid_t) usize {
    var n: usize = 0;
    var next: usize = 0; // out[next..n] are yet to be expanded; root first.
    var expand_root = true;
    while (expand_root or next < n) {
        const pid = if (expand_root) root else out[next];
        if (!expand_root) next += 1;
        expand_root = false;
        if (is_linux) {
            var tb: [64]u8 = undefined;
            const tasks = pathZ(&tb, "/proc/{d}/task", .{pid}) orelse continue;
            const dir = c.opendir(tasks) orelse continue;
            defer _ = c.closedir(dir);
            while (c.readdir(dir)) |entry| {
                const tname = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
                if (tname.len == 0 or tname[0] == '.') continue;
                var cb: [96]u8 = undefined;
                var text_buf: [16384]u8 = undefined;
                const text = readInto(pathZ(&cb, "/proc/{d}/task/{s}/children", .{ pid, tname }) orelse continue, &text_buf) orelse continue;
                // A full buffer may end in the middle of a pid: drop the last word then.
                const whole = if (text.len == text_buf.len) text[0 .. std.mem.findScalarLast(u8, text, ' ') orelse 0] else text;
                var it = std.mem.tokenizeAny(u8, whole, " \n");
                while (it.next()) |w| {
                    if (n == out.len) return n;
                    out[n] = std.fmt.parseInt(c.pid_t, w, 10) catch continue;
                    n += 1;
                }
            }
        } else {
            var kids: [2048]c_int = undefined;
            const k = proc_listchildpids(pid, &kids, @intCast(@sizeOf(@TypeOf(kids))));
            if (k <= 0) continue;
            for (kids[0..@min(@as(usize, @intCast(k)), kids.len)]) |kid| {
                if (n == out.len) return n;
                out[n] = kid;
                n += 1;
            }
        }
    }
    return n;
}

/// Memory one process uses, in bytes: Linux's resident set, macOS's physical footprint.
fn processMem(pid: c.pid_t) u64 {
    if (is_linux) {
        var pb: [48]u8 = undefined;
        var text_buf: [128]u8 = undefined;
        const text = readInto(pathZ(&pb, "/proc/{d}/statm", .{pid}) orelse return 0, &text_buf) orelse return 0;
        var f = std.mem.tokenizeScalar(u8, text, ' ');
        _ = f.next();
        const pages = std.fmt.parseInt(u64, f.next() orelse return 0, 10) catch return 0;
        return pages * std.heap.pageSize();
    }
    // struct rusage_info_v1: ri_phys_footprint at 72.
    var ru: [144]u8 align(8) = undefined;
    if (proc_pid_rusage(pid, 1, &ru) != 0) return 0;
    return std.mem.readInt(u64, ru[72..80], .little);
}

var tree_buf: [8192]c.pid_t = undefined;

/// The memory of everything below this process: the program, its descendants, and on Linux any
/// orphan of theirs (this process is their subreaper).
fn treeMem() u64 {
    const n = descendants(sys.getpid(), &tree_buf);
    var total: u64 = 0;
    for (tree_buf[0..n]) |pid| total += processMem(pid);
    return total;
}

/// Stops everything below this process: freezes the tree so it can't grow while it is walked,
/// kills it, and repeats until a walk finds nothing; then the program's group, for what left it.
fn killTree(pgid: c.pid_t) void {
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        const n = descendants(sys.getpid(), &tree_buf);
        if (n == 0) break;
        for (tree_buf[0..n]) |pid| _ = c.kill(pid, .STOP);
        for (tree_buf[0..n]) |pid| _ = c.kill(pid, .KILL);
        reapAll();
    }
    if (pgid > 0) _ = c.kill(-pgid, .KILL);
}

/// Reaps every child that has ended, without waiting.
fn reapAll() void {
    var status: c_int = 0;
    while (c.waitpid(-1, &status, 1) > 0) {} // WNOHANG = 1
}

// --- File facts: stat where libc has it (macOS), statx where Zig's Linux libc doesn't --------

const ifmt = 0o170000;
const ifreg = 0o100000;
const ifchr = 0o020000;

const Info = struct { mode: u32, size: i64, dev: u64, ino: u64 };

fn infoOf(fd: c.fd_t, path: ?[*:0]const u8) ?Info {
    if (is_linux) {
        var stx: linux.Statx = undefined;
        const rc = if (path) |p| linux.statx(linux.AT.FDCWD, p, 0, linux.STATX.BASIC_STATS, &stx) else linux.statx(fd, "", linux.AT.EMPTY_PATH, linux.STATX.BASIC_STATS, &stx);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .mode = stx.mode, .size = @intCast(stx.size), .dev = (@as(u64, stx.dev_major) << 32) | stx.dev_minor, .ino = stx.ino };
    }
    var st: c.Stat = undefined;
    const rc = if (path) |p| c.stat(p, &st) else c.fstat(fd, &st);
    if (rc != 0) return null;
    return .{ .mode = @intCast(st.mode), .size = @intCast(st.size), .dev = @intCast(st.dev), .ino = @intCast(st.ino) };
}

// --- Output: what the program has written to stdout and stderr, when they are files ----------

const Output = struct {
    files: [2]struct { fd: c.fd_t, start: i64 } = undefined,
    count: usize = 0,

    /// Notes fds 1 and 2 when they are files (once if they are the same one). A pipe or socket
    /// can't be measured without passing everything through cpuq, so it is refused.
    fn init(o: *Output) ?[]const u8 {
        var seen: [2]struct { dev: u64, ino: u64 } = undefined;
        for ([_]c.fd_t{ 1, 2 }) |fd| {
            const st = infoOf(fd, null) orelse continue;
            const kind = st.mode & ifmt;
            if (kind == ifchr) continue; // /dev/null, a terminal
            if (kind != ifreg) return "--output counts what PROGRAM writes to files; its stdout or stderr is a pipe or a socket";
            var dup = false;
            for (seen[0..o.count]) |s| dup = dup or (s.dev == st.dev and s.ino == st.ino);
            if (dup) continue;
            seen[o.count] = .{ .dev = st.dev, .ino = st.ino };
            o.files[o.count] = .{ .fd = fd, .start = st.size };
            o.count += 1;
        }
        return null;
    }

    fn written(o: *const Output) u64 {
        var total: u64 = 0;
        for (o.files[0..o.count]) |f| {
            const st = infoOf(f.fd, null) orelse continue;
            total += @intCast(@max(st.size - f.start, 0));
        }
        return total;
    }
};

// --- Finding PROGRAM, and its environment -----------------------------------------------------

/// PROGRAM's path: as given when it has a slash, else the first executable on PATH.
fn findProgram(a: std.mem.Allocator, name: []const u8, path_env: ?[]const u8) ?[:0]const u8 {
    if (std.mem.findScalar(u8, name, '/') != null) return a.dupeSentinel(u8, name, 0) catch null;
    var dirs = std.mem.splitScalar(u8, path_env orelse "/usr/local/bin:/usr/bin:/bin", ':');
    while (dirs.next()) |d| {
        const full = a.printSentinel("{s}/{s}", .{ if (d.len == 0) "." else d, name }, 0) catch return null;
        const st = infoOf(-1, full) orelse continue;
        if (st.mode & ifmt != ifreg) continue;
        if (c.access(full, c.X_OK) == 0) return full;
    }
    return null;
}

/// This process's environment less CPUQ_CGROUP: a cap PROGRAM starts can't make cgroups beside
/// this one's, outside its limits.
fn childEnv(a: std.mem.Allocator) ?[*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (c.environ[i]) |e| : (i += 1) {
        if (std.mem.startsWith(u8, std.mem.sliceTo(e, 0), "CPUQ_CGROUP=")) continue;
        list.append(a, e) catch return null;
    }
    const out = a.allocSentinel(?[*:0]const u8, list.items.len, null) catch return null;
    @memcpy(out, list.items);
    return out.ptr;
}

// --- The command --------------------------------------------------------------------------

const Stop = enum { none, memory, time, output };

pub fn main(a: std.mem.Allocator, args: []const [:0]const u8, cgroup_parent: ?[]const u8, path_env: ?[]const u8) u8 {
    var limits: Limits = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (!std.mem.startsWith(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            return 0;
        }
        const eq = std.mem.findScalar(u8, arg, '=');
        const name = if (eq) |e| arg[0..e] else arg;
        const value: []const u8 = if (eq) |e| arg[e + 1 ..] else blk: {
            i += 1;
            if (i >= args.len) return bad("{s} needs a value", .{name});
            break :blk args[i];
        };
        if (std.mem.eql(u8, name, "--mem")) {
            limits.mem = policy.parseBytes(value) orelse return bad("--mem needs a size like 2G or 512M, not '{s}'", .{value});
        } else if (std.mem.eql(u8, name, "--time")) {
            limits.time_ms = parseDuration(value) orelse return bad("--time needs a duration like 120s or 2m, not '{s}'", .{value});
        } else if (std.mem.eql(u8, name, "--output")) {
            limits.output = policy.parseBytes(value) orelse return bad("--output needs a size like 1M, not '{s}'", .{value});
        } else if (std.mem.eql(u8, name, "--pids")) {
            limits.pids = std.fmt.parseInt(u64, value, 10) catch return bad("--pids needs a whole number, not '{s}'", .{value});
        } else return bad("unknown option '{s}'", .{name});
    }
    if (i >= args.len) return bad("no PROGRAM given", .{});
    const cmd = args[i..];

    const program = findProgram(a, cmd[0], path_env) orelse {
        std.debug.print("cpuq cap: {s}: not found\n", .{cmd[0]});
        return 127;
    };
    var output: Output = .{};
    if (limits.output != 0) {
        if (output.init()) |why| return bad("{s}", .{why});
    }
    const argv = a.allocSentinel(?[*:0]const u8, cmd.len, null) catch return exit_failure;
    for (cmd, 0..) |arg, k| argv[k] = arg.ptr;
    const envp = childEnv(a) orelse return exit_failure;
    if (!installSignals()) {
        std.debug.print("cpuq cap: no pipe for signals\n", .{});
        return exit_failure;
    }
    // Linux: orphans of the program become this process's children, so the tree still holds
    // them for the memory sum and the final kill.
    if (is_linux) _ = prctl(36, @as(c_ulong, 1)); // PR_SET_CHILD_SUBREAPER
    // Only memory and process limits need a cgroup; a time limit alone is a timer.
    var cgroup: ?Cgroup = if (limits.mem != 0 or limits.pids != 0) Cgroup.make(cgroup_parent orelse "", limits) else null;

    // The child reports a failed exec through a close-on-exec pipe: 'e' and errno.
    var report: [2]c.fd_t = undefined;
    if (c.pipe(&report) != 0) return exit_failure;
    for (report) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));

    // cpuq's own signals wait while the child is made, so none is lost between its birth and
    // child_pid naming it, and none runs a handler in the child.
    const blocked = sigset(&handled);
    var before: c.sigset_t = undefined;
    _ = c.sigprocmask(c.SIG.BLOCK, &blocked, &before);
    const parent = sys.getpid();
    var pid: isize = -1;
    if (cgroup) |cg| {
        pid = forkInto(cg.fd);
        if (pid < 0) {
            // ENOSYS (an old kernel), EACCES, EBUSY: no cgroup of its own; watched the slow way.
            cg.remove();
            cgroup = null;
        }
    }
    if (pid < 0) pid = c.fork();
    if (pid < 0) {
        _ = c.sigprocmask(c.SIG.SETMASK, &before, null);
        std.debug.print("cpuq cap: could not start {s}\n", .{cmd[0]});
        return exit_failure;
    }
    if (pid == 0) {
        // The child: only async-signal-safe calls until exec.
        _ = c.close(report[0]);
        var dfl: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = undefined, .flags = 0 };
        _ = c.sigemptyset(&dfl.mask);
        for (handled) |sig| {
            var old: c.Sigaction = undefined;
            if (c.sigaction(sig, null, &old) == 0 and old.handler.handler == c.SIG.IGN) continue;
            _ = c.sigaction(sig, &dfl, null);
        }
        _ = c.sigprocmask(c.SIG.SETMASK, &before, null);
        // Without a cgroup, its own process group, so the group can be killed whole.
        if (cgroup == null) _ = c.setpgid(0, 0);
        if (is_linux) {
            _ = prctl(1, @as(c_ulong, 9)); // PR_SET_PDEATHSIG, SIGKILL: dies with cpuq
            if (c.getppid() != parent) c._exit(exit_failure); // cpuq died before that was armed
        }
        _ = c.execve(program.ptr, argv.ptr, envp);
        const err: u8 = @intCast(@intFromEnum(c.errno(-1)));
        _ = c.write(report[1], &[_]u8{ 'e', err }, 2);
        c._exit(126);
    }
    const child: c.pid_t = @intCast(pid);
    if (cgroup == null) _ = c.setpgid(child, child);
    child_pid.store(child, .release);
    _ = c.sigprocmask(c.SIG.SETMASK, &before, null);
    _ = c.close(report[1]);
    var note: [2]u8 = .{ 0, 0 };
    var got: usize = 0;
    while (got < 2) {
        const n = c.read(report[0], note[got..].ptr, 2 - got);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) break;
        got += @intCast(n);
    }
    _ = c.close(report[0]);
    if (got == 2 and note[0] == 'e') {
        var status: c_int = 0;
        while (c.waitpid(child, &status, 0) < 0 and c.errno(-1) == .INTR) {}
        if (cgroup) |cg| cg.remove();
        std.debug.print("cpuq cap: {s}: can't be run\n", .{cmd[0]});
        return 126;
    }

    // Wait for the end, waking for the deadline and, when something must be read, once a second.
    const start = sys.monoMs();
    const sample_mem = limits.mem != 0 and cgroup == null;
    const sample = sample_mem or limits.output != 0;
    var next_sample = start + 1000;
    var stop: Stop = .none;
    var status: c_int = 0;
    var ended = false;
    while (!ended) {
        // Reap everything that has ended: the program, and orphans adopted as subreaper.
        while (true) {
            var s: c_int = 0;
            const r = c.waitpid(-1, &s, 1); // WNOHANG
            if (r <= 0) break;
            if (r == child) {
                status = s;
                ended = true;
            }
        }
        if (ended) break;
        const now = sys.monoMs();
        if (limits.time_ms != 0 and now - start >= @as(i64, @intCast(limits.time_ms))) {
            stop = .time;
        } else if (sample and now >= next_sample) {
            next_sample = now + 1000;
            if (limits.output != 0 and output.written() > limits.output) {
                stop = .output;
            } else if (sample_mem and treeMem() > limits.mem) {
                stop = .memory;
            }
        }
        if (stop != .none) {
            if (cgroup) |cg| _ = cg.set("cgroup.kill", "1") else killTree(child);
            while (c.waitpid(child, &status, 0) < 0 and c.errno(-1) == .INTR) {}
            break;
        }
        var timeout: i64 = -1;
        if (limits.time_ms != 0) timeout = start + @as(i64, @intCast(limits.time_ms)) - now;
        if (sample) timeout = if (timeout < 0) next_sample - now else @min(timeout, next_sample - now);
        var fds = [_]c.pollfd{.{ .fd = wake[0], .events = c.POLL.IN, .revents = 0 }};
        _ = c.poll(&fds, 1, @intCast(std.math.clamp(timeout, -1, 60_000)));
        drainWake();
    }
    child_pid.store(0, .release);

    // Whatever the program left running goes with it.
    if (cgroup) |cg| {
        // The cap's own limit, not the job's or the machine's: those count in memory.events.
        if (stop == .none and cg.field("memory.events.local", "oom_kill") != 0) stop = .memory;
        cg.remove();
    }
    killTree(if (cgroup == null) child else 0);
    reapAll();

    const s: u32 = @bitCast(status);
    switch (stop) {
        .memory => {
            std.debug.print("cpuq cap: stopped {s}: it used more than {s} (--mem)\n", .{ cmd[0], sizeText(a, limits.mem) });
            return exit_memory;
        },
        .time => {
            std.debug.print("cpuq cap: stopped {s}: it ran past {s} (--time)\n", .{ cmd[0], timeText(a, limits.time_ms) });
            return exit_time;
        },
        .output => {
            std.debug.print("cpuq cap: stopped {s}: it printed more than {s} (--output)\n", .{ cmd[0], sizeText(a, limits.output) });
            return exit_output;
        },
        .none => {},
    }
    if (c.W.IFEXITED(s)) return c.W.EXITSTATUS(s);
    if (c.W.IFSIGNALED(s)) sys.dieBySignal(c.W.TERMSIG(s));
    return exit_failure;
}

fn sizeText(a: std.mem.Allocator, bytes: u64) []const u8 {
    const units = [_]struct { n: u64, s: []const u8 }{ .{ .n = 1 << 30, .s = "GB" }, .{ .n = 1 << 20, .s = "MB" }, .{ .n = 1 << 10, .s = "KB" } };
    for (units) |u| {
        if (bytes >= u.n and bytes % u.n == 0) return a.print("{d} {s}", .{ bytes / u.n, u.s }) catch "?";
    }
    return a.print("{d} bytes", .{bytes}) catch "?";
}

fn timeText(a: std.mem.Allocator, ms: u64) []const u8 {
    if (ms % 1000 != 0) return a.print("{d} ms", .{ms}) catch "?";
    return a.print("{d} s", .{ms / 1000}) catch "?";
}
