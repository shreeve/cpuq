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

/// The machine's cores: one token file each.
pub fn totalCpus() u32 {
    if (is_darwin) {
        var n: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (c.sysctlbyname("hw.ncpu", &n, &len, null, 0) == 0 and n > 0) return @intCast(n);
        return 1;
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
/// command.
pub fn installForwarding() void {
    var sa: c.Sigaction = .{
        .handler = .{ .sigaction = onSignal },
        .mask = undefined,
        .flags = c.SA.SIGINFO | c.SA.RESTART,
    };
    _ = c.sigemptyset(&sa.mask);
    for (forwarded) |sig| _ = c.sigaction(sig, &sa, null);
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
