//! The operating-system layer: live machine signals, spawning the command
//! in its scheduling class, signal forwarding and descriptor inheritance.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const c = std.c;
const policy = @import("policy.zig");

const os = builtin.target.os.tag;
const is_darwin = os.isDarwin();

extern "c" fn getloadavg(loadavg: [*]f64, nelem: c_int) c_int;
extern "c" fn getpriority(which: c_int, who: c_uint) c_int;
extern "c" fn setpriority(which: c_int, who: c_uint, prio: c_int) c_int;
extern "c" fn posix_spawnattr_setsigmask(attr: *c.posix_spawnattr_t, mask: *const c.sigset_t) c_int;
extern "c" fn posix_spawnattr_set_qos_class_np(attr: *c.posix_spawnattr_t, qos: c_uint) c_int;
extern "c" fn qos_class_self() c_uint;

const PRIO_PROCESS = 0;
const QOS_CLASS_UTILITY = 0x11;
const QOS_CLASS_BACKGROUND = 0x09;

/// Cores the OS has active now: macOS hw.activecpu (it drops under thermal
/// limits); Linux the CPUs in this process's affinity mask.
pub fn activeCpus() u32 {
    if (is_darwin) {
        var n: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (c.sysctlbyname("hw.activecpu", &n, &len, null, 0) == 0 and n > 0) return @intCast(n);
        return 1;
    }
    const n = std.Thread.getCpuCount() catch return 1;
    return @intCast(@max(n, 1));
}

/// The machine's cores: one token file each. On Linux this is every CPU the
/// machine has, not the caller's affinity, so that runs confined to fewer
/// CPUs (taskset, a cpuset) agree with everyone else on the token set.
pub fn totalCpus(io: Io) u32 {
    if (is_darwin) {
        var n: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (c.sysctlbyname("hw.ncpu", &n, &len, null, 0) == 0 and n > 0) return @intCast(n);
        return 1;
    }
    for ([_][]const u8{ "/sys/devices/system/cpu/present", "/sys/devices/system/cpu/possible" }) |path| {
        var buf: [256]u8 = undefined;
        const text = Io.Dir.cwd().readFile(io, path, &buf) catch continue;
        if (policy.cpuListCount(text)) |n| return n;
    }
    const n = std.Thread.getCpuCount() catch return 1;
    return @intCast(@max(n, 1));
}

pub fn loadAverage() [3]f64 {
    var l: [3]f64 = .{ 0, 0, 0 };
    if (getloadavg(&l, 3) != 3) return .{ 0, 0, 0 };
    return l;
}

/// macOS kern.memorystatus_vm_pressure_level; Linux /proc/pressure/memory
/// when present.
pub fn memoryPressure(io: Io, psi_threshold: f64) policy.Pressure {
    if (is_darwin) {
        var level: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (c.sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, null, 0) != 0) return .unknown;
        return policy.macPressure(level);
    }
    var buf: [512]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/pressure/memory", &buf) catch return .unknown;
    return policy.psiPressure(text, psi_threshold);
}

/// The scheduling class of the calling process, for `cpuq qos`.
pub fn currentQos(buf: []u8) []const u8 {
    if (is_darwin) {
        return switch (qos_class_self()) {
            0x21 => "user-interactive",
            0x19 => "user-initiated",
            0x15 => "default",
            QOS_CLASS_UTILITY => "utility",
            QOS_CLASS_BACKGROUND => "background",
            0x00 => "unspecified",
            else => |q| std.mem.print(buf, "qos 0x{x}", .{q}) catch "qos ?",
        };
    }
    return std.mem.print(buf, "nice {d}", .{getpriority(PRIO_PROCESS, 0)}) catch "nice ?";
}

/// A pipe whose descriptors the command inherits, holding `tokens` bytes:
/// a GNU make jobserver.
pub fn jobserverPipe(tokens: u32) ![2]c.fd_t {
    var fds: [2]c.fd_t = undefined;
    if (c.pipe(&fds) != 0) return error.PipeFailed;
    var buf: [256]u8 = @splat('+');
    writeAll(fds[1], buf[0..@min(tokens, buf.len)]);
    return fds;
}

pub fn writeAll(fd: c.fd_t, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const n = c.write(fd, bytes[i..].ptr, bytes.len - i);
        if (n <= 0) return;
        i += @intCast(n);
    }
}

pub fn closeFd(fd: c.fd_t) void {
    _ = c.close(fd);
}

/// Lets a descriptor survive exec, so the command and its descendants share
/// the open file description and with it the flock.
pub fn inherit(fd: c.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, 0));
}

pub const SpawnError = error{ SpawnFailed, AccessDenied, FileNotFound };

/// Starts `path` with an empty signal mask, in the given scheduling class.
pub fn spawn(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    qos: policy.Qos,
) SpawnError!c.pid_t {
    if (is_darwin) {
        var attr: c.posix_spawnattr_t = undefined;
        if (c.posix_spawnattr_init(&attr) != 0) return error.SpawnFailed;
        defer _ = c.posix_spawnattr_destroy(&attr);
        const empty: c.sigset_t = 0;
        _ = posix_spawnattr_setsigmask(&attr, &empty);
        _ = c.posix_spawnattr_setflags(&attr, .{ .SETSIGMASK = true });
        switch (qos) {
            .unchanged => {},
            .utility => _ = posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_UTILITY),
            .background => _ = posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_BACKGROUND),
        }
        var pid: c.pid_t = 0;
        return switch (c.posix_spawn(&pid, path, null, &attr, argv, envp)) {
            0 => pid,
            @backingInt(c.E.NOENT) => error.FileNotFound,
            @backingInt(c.E.ACCES), @backingInt(c.E.PERM) => error.AccessDenied,
            else => error.SpawnFailed,
        };
    }
    const nice: c_int = switch (qos) {
        .unchanged => 0,
        .utility => 5,
        .background => 15,
    };
    const pid = c.fork();
    if (pid < 0) return error.SpawnFailed;
    if (pid == 0) {
        var empty: c.sigset_t = undefined;
        _ = c.sigemptyset(&empty);
        _ = c.sigprocmask(c.SIG.SETMASK, &empty, null);
        if (nice > getpriority(PRIO_PROCESS, 0)) _ = setpriority(PRIO_PROCESS, 0, nice);
        const rc = c.execve(path, argv, envp);
        const msg = "cpuq: exec failed\n";
        _ = c.write(2, msg, msg.len);
        c._exit(if (c.errno(rc) == .NOENT) 127 else 126);
    }
    return pid;
}

/// Signals forwarded to the command once it runs.
pub const forwarded = [_]c.SIG{ .HUP, .INT, .QUIT, .TERM, .USR1, .USR2 };

var child_pid = std.atomic.Value(c.pid_t).init(0);
var pending_signal = std.atomic.Value(u32).init(0);

fn senderPid(info: *const c.siginfo_t) c.pid_t {
    if (is_darwin) return info.pid;
    return info.fields.common.first.piduid.pid;
}

fn onSignal(sig: c.SIG, info: *const c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // A signal with no sending process came from the kernel's terminal
    // driver (^C, ^\, hangup), which sent it to the whole foreground process
    // group, the command included; like system(3), cpuq lets the command
    // handle it alone. A signal some process sent to cpuq goes on to the
    // command.
    if (senderPid(info) == 0) return;
    const pid = child_pid.load(.acquire);
    if (pid > 0) {
        _ = c.kill(pid, sig);
    } else {
        pending_signal.store(@intCast(@backingInt(sig)), .release);
    }
}

/// Installs the forwarding handlers. Exec resets them to the default in the
/// command. A signal cpuq was started with ignored (`nohup`, a `&` job in a
/// script) is left ignored, so the command inherits it ignored, as it would
/// without cpuq.
pub fn installForwarding() void {
    var sa: c.Sigaction = .{
        .handler = .{ .sigaction = onSignal },
        .mask = undefined,
        .flags = c.SA.SIGINFO | c.SA.RESTART,
    };
    _ = c.sigemptyset(&sa.mask);
    for (forwarded) |sig| {
        var old: c.Sigaction = undefined;
        if (c.sigaction(sig, null, &old) == 0 and old.handler.handler == c.SIG.IGN) continue;
        _ = c.sigaction(sig, &sa, null);
    }
}

/// Records the command's pid for the handlers and delivers any signal that
/// arrived while it was being started.
pub fn setChild(pid: c.pid_t) void {
    child_pid.store(pid, .release);
    const sig = pending_signal.swap(0, .acq_rel);
    if (sig != 0) _ = c.kill(pid, @fromBackingInt(@intCast(sig)));
}

pub const Exit = union(enum) { code: u8, signal: c.SIG };

pub fn waitChild(pid: c.pid_t) Exit {
    var status: c_int = 0;
    while (true) {
        const r = c.waitpid(pid, &status, 0);
        if (r == pid) break;
        if (r < 0 and c.errno(r) == .INTR) continue;
        return .{ .code = 125 };
    }
    const s: u32 = @bitCast(status);
    if (c.W.IFEXITED(s)) return .{ .code = c.W.EXITSTATUS(s) };
    if (c.W.IFSIGNALED(s)) return .{ .signal = c.W.TERMSIG(s) };
    return .{ .code = 125 };
}

/// Ends this process the way the command ended: by the same signal, so the
/// caller's shell reports it (128 + N), without a core dump.
pub fn dieBySignal(sig: c.SIG) noreturn {
    const no_core: c.rlimit = .{ .cur = 0, .max = 0 };
    _ = c.setrlimit(.CORE, &no_core);
    var sa: c.Sigaction = .{ .handler = .{ .handler = c.SIG.DFL }, .mask = undefined, .flags = 0 };
    _ = c.sigemptyset(&sa.mask);
    _ = c.sigaction(sig, &sa, null);
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigaddset(&set, sig);
    _ = c.sigprocmask(c.SIG.UNBLOCK, &set, null);
    _ = c.raise(sig);
    c._exit(128 + @as(u8, @intCast(@backingInt(sig))));
}

extern "c" fn proc_listallpids(buffer: ?*anyopaque, size: c_int) c_int;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: ?*anyopaque) c_int;
extern "c" fn mach_timebase_info(info: *MachTimebase) c_int;
extern "c" fn sysconf(name: c_int) c_long;
const MachTimebase = extern struct { numer: u32, denom: u32 };

pub const Proc = struct {
    pid: i32,
    ppid: i32,
    /// CPU time used so far, user plus system, in nanoseconds: the
    /// process's own and that of its children it has already reaped, so the
    /// many short processes a build or test run starts are counted too.
    cpu_ns: u64,
};

/// Every process the caller can see, with its parent and its CPU time so
/// far: macOS proc_pidinfo and proc_pid_rusage, Linux /proc/PID/stat.
pub fn processes(io: Io, arena: std.mem.Allocator) []Proc {
    var list: std.ArrayList(Proc) = .empty;
    if (is_darwin) {
        // struct proc_bsdinfo (PROC_PIDTBSDINFO, 136 bytes): pbi_ppid at 16.
        // struct rusage_info_v1 (144 bytes): ri_user_time at 16,
        // ri_system_time at 24, ri_child_user_time at 96,
        // ri_child_system_time at 104, in Mach absolute time units.
        var tb: MachTimebase = .{ .numer = 1, .denom = 1 };
        _ = mach_timebase_info(&tb);
        const count = proc_listallpids(null, 0);
        if (count <= 0) return &.{};
        const pids = arena.alloc(c_int, @as(usize, @intCast(count)) + 64) catch return &.{};
        const n = proc_listallpids(pids.ptr, @intCast(pids.len * @sizeOf(c_int)));
        if (n <= 0) return &.{};
        for (pids[0..@min(@as(usize, @intCast(n)), pids.len)]) |pid| {
            var bsd: [136]u8 align(8) = undefined;
            if (proc_pidinfo(pid, 3, 0, &bsd, bsd.len) != bsd.len) continue;
            var ru: [144]u8 align(8) = undefined;
            if (proc_pid_rusage(pid, 1, &ru) != 0) continue;
            var ticks: u64 = 0;
            for ([_]usize{ 16, 24, 96, 104 }) |at| ticks +%= std.mem.readInt(u64, ru[at..][0..8], .little);
            list.append(arena, .{
                .pid = pid,
                .ppid = @bitCast(std.mem.readInt(u32, bsd[16..20], .little)),
                .cpu_ns = @intCast(@as(u128, ticks) * tb.numer / tb.denom),
            }) catch break;
        }
        return list.items;
    }
    const tick_hz: u64 = @intCast(@max(sysconf(2), 1)); // _SC_CLK_TCK
    var dir = Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        var path_buf: [32]u8 = undefined;
        const path = std.mem.print(&path_buf, "/proc/{d}/stat", .{pid}) catch continue;
        var buf: [1024]u8 = undefined;
        const text = Io.Dir.cwd().readFile(io, path, &buf) catch continue;
        // Fields after the command, which is in parentheses and may hold
        // spaces: state, ppid, ..., utime, stime, cutime, cstime (12th to
        // 15th; cutime and cstime are the reaped children's).
        const close = std.mem.findScalarLast(u8, text, ')') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
        var ppid: i32 = 0;
        var ticks: u64 = 0;
        var i: usize = 0;
        while (fields.next()) |f| : (i += 1) {
            switch (i) {
                1 => ppid = std.fmt.parseInt(i32, f, 10) catch 0,
                11, 12, 13, 14 => ticks += std.fmt.parseInt(u64, f, 10) catch 0,
                else => {},
            }
            if (i == 14) break;
        }
        list.append(arena, .{ .pid = pid, .ppid = ppid, .cpu_ns = ticks * std.time.ns_per_s / tick_hz }) catch break;
    }
    return list.items;
}

/// The CPU time of `root` and all its descendants in a snapshot.
pub fn treeCpu(procs: []const Proc, root: i32) u64 {
    var total: u64 = 0;
    var frontier: [512]i32 = undefined;
    var len: usize = 1;
    frontier[0] = root;
    var seen: usize = 0;
    while (seen < len) : (seen += 1) {
        const pid = frontier[seen];
        for (procs) |p| {
            if (p.pid == pid) total += p.cpu_ns;
            if (p.ppid == pid and p.pid != pid and len < frontier.len) {
                frontier[len] = p.pid;
                len += 1;
            }
        }
    }
    return total;
}

pub fn processAlive(pid: c.pid_t) bool {
    if (pid <= 0) return false;
    if (c.kill(pid, @fromBackingInt(@intCast(0))) == 0) return true;
    return c.errno(-1) == .PERM;
}

pub fn getpid() c.pid_t {
    return c.getpid();
}

pub fn getuid() u32 {
    return c.getuid();
}
