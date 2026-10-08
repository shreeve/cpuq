//! The operating-system layer: live machine signals, spawning the command
//! in its scheduling class, signal forwarding and descriptor inheritance.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const c = std.c;
const policy = @import("policy.zig");

const os = builtin.target.os.tag;
const is_darwin = os.isDarwin();

extern "c" fn sysctl(name: [*]c_int, namelen: c_uint, oldp: ?*anyopaque, oldlenp: ?*usize, newp: ?*anyopaque, newlen: usize) c_int;
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

extern "c" fn mach_host_self() c_uint;
extern "c" fn host_statistics(host: c_uint, flavor: c_int, info: [*]c_uint, count: *c_uint) c_int;

/// The machine's CPU time so far, in ticks: busy (user, system, nice) and
/// total. Two readings give the share of all CPUs busy between them. macOS
/// host_statistics HOST_CPU_LOAD_INFO; Linux the first line of /proc/stat.
pub const Ticks = struct { busy: u64, total: u64 };

pub fn cpuTicks(io: Io) ?Ticks {
    if (is_darwin) {
        var info: [4]c_uint = undefined; // user, system, idle, nice
        var count: c_uint = info.len;
        if (host_statistics(mach_host_self(), 3, &info, &count) != 0) return null;
        const busy: u64 = @as(u64, info[0]) + info[1] + info[3];
        return .{ .busy = busy, .total = busy + info[2] };
    }
    var buf: [512]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/stat", &buf) catch return null;
    const line = std.mem.sliceTo(text, '\n');
    var f = std.mem.tokenizeScalar(u8, line, ' ');
    if (!std.mem.eql(u8, f.next() orelse return null, "cpu")) return null;
    var total: u64 = 0;
    var idle: u64 = 0;
    var i: usize = 0;
    // user nice system idle iowait irq softirq steal: idle and iowait are not busy.
    while (f.next()) |v| : (i += 1) {
        if (i >= 8) break;
        const n = std.fmt.parseInt(u64, v, 10) catch 0;
        total += n;
        if (i == 3 or i == 4) idle += n;
    }
    return .{ .busy = total - idle, .total = total };
}

/// The share of all CPUs busy between two readings, 0 to 1.
pub fn busyBetween(a: Ticks, b: Ticks) ?f64 {
    if (b.total <= a.total) return null;
    return @as(f64, @floatFromInt(b.busy -| a.busy)) / @as(f64, @floatFromInt(b.total - a.total));
}

/// Memory available for new work, in bytes: Linux /proc/meminfo
/// MemAvailable; macOS the kernel's free share (kern.memorystatus_level, the
/// percentage `memory_pressure` prints) of hw.memsize. Null when unreadable.
pub fn memAvailable(io: Io) ?u64 {
    if (is_darwin) {
        var level: c_int = 0;
        var len: usize = @sizeOf(c_int);
        if (c.sysctlbyname("kern.memorystatus_level", &level, &len, null, 0) != 0) return null;
        var total: u64 = 0;
        len = @sizeOf(u64);
        if (c.sysctlbyname("hw.memsize", &total, &len, null, 0) != 0) return null;
        return total / 100 * @as(u64, @intCast(std.math.clamp(level, 0, 100)));
    }
    var buf: [4096]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/meminfo", &buf) catch return null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "MemAvailable:")) continue;
        var f = std.mem.tokenizeScalar(u8, line["MemAvailable:".len..], ' ');
        const kb = std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null;
        return kb * 1024;
    }
    return null;
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
/// The signals last words catch: hangup, ^C, ^\ and kill.
const fatal = [_]c.SIG{ .HUP, .INT, .QUIT, .TERM };

/// Blocks `sigs` in the calling thread; returns the mask to restore.
fn hold(sigs: []const c.SIG) c.sigset_t {
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    for (sigs) |sig| _ = c.sigaddset(&set, sig);
    var before: c.sigset_t = undefined;
    _ = c.sigprocmask(c.SIG.BLOCK, &set, &before);
    return before;
}

/// Holds the fatal signals in the calling thread until `restoreSignals`:
/// one that arrives meanwhile is delivered then.
pub fn holdFatal() c.sigset_t {
    return hold(&fatal);
}

/// Holds every signal cpuq handles in the calling thread until
/// `restoreSignals`. A thread started meanwhile keeps them blocked for good,
/// so they all go to the main thread, and a handler never runs beside the
/// main thread's own work: last words half re-armed, or the command's pid
/// half recorded. (The kernel gives a process's signal to any thread that
/// has it unblocked: while the main thread holds it, a worker.)
pub fn holdHandled() c.sigset_t {
    return hold(&forwarded);
}

pub fn restoreSignals(before: c.sigset_t) void {
    _ = c.sigprocmask(c.SIG.SETMASK, &before, null);
}

var child_pid = std.atomic.Value(c.pid_t).init(0);
/// cpuq's terminal, if it has one: while cpuq is in its foreground process
/// group, the terminal delivers ^C, ^\ and hangup to the command itself.
var tty_fd: c_int = -1;
extern "c" fn tcgetpgrp(fd: c_int) c.pid_t;
extern "c" fn getpgrp() c.pid_t;
var pending_signal = std.atomic.Value(u32).init(0);

/// Last words: the history line cpuq appends if a signal kills it while it
/// waits, or holds a lease with no command, so the job reads as ended and
/// not as lost. The line is `head`, the time, `tail` and (when asked) the
/// signal, rendered ahead of time so the handler only writes. There are two
/// slots: a lease taken `--exclusive` is two jobs, the lease and the cores.
const Words = struct {
    head: [256]u8 = undefined,
    head_len: usize = 0,
    tail: [64]u8 = undefined,
    tail_len: usize = 0,
    signal: bool = false,
    armed: std.atomic.Value(bool) = .init(false),
};
var last_path: [1024]u8 = undefined;
var last_words: [2]Words = .{ .{}, .{} };

/// Arms slot `slot`'s last words, catching hangup, ^C, ^\ and kill; arming
/// it again replaces them. A signal cpuq was started with ignored stays
/// ignored.
pub fn armLastWords(slot: u1, path: []const u8, head: []const u8, tail: []const u8, with_signal: bool) void {
    // A fatal signal arriving while the line is rewritten waits until it is
    // in place: the kit closes a hold's stdin and kills it at once, which
    // lands exactly as cpuq re-arms.
    const before = holdFatal();
    defer restoreSignals(before);
    const w = &last_words[slot];
    w.armed.store(false, .release);
    if (path.len >= last_path.len or head.len > w.head.len or tail.len > w.tail.len) return;
    @memcpy(last_path[0..path.len], path);
    last_path[path.len] = 0;
    @memcpy(w.head[0..head.len], head);
    w.head_len = head.len;
    @memcpy(w.tail[0..tail.len], tail);
    w.tail_len = tail.len;
    w.signal = with_signal;
    w.armed.store(true, .release);
    var sa: c.Sigaction = .{ .handler = .{ .handler = onFatal }, .mask = undefined, .flags = 0 };
    _ = c.sigemptyset(&sa.mask);
    for (fatal) |sig| {
        var old: c.Sigaction = undefined;
        if (c.sigaction(sig, null, &old) == 0 and old.handler.handler == c.SIG.IGN) continue;
        _ = c.sigaction(sig, &sa, null);
    }
}

fn onFatal(sig: c.SIG) callconv(.c) void {
    for (&last_words) |*w| {
        if (!w.armed.swap(false, .acq_rel)) continue;
        var buf: [256 + 64 + 64]u8 = undefined;
        var n: usize = 0;
        @memcpy(buf[n..][0..w.head_len], w.head[0..w.head_len]);
        n += w.head_len;
        var ts: c.timespec = undefined;
        _ = c.clock_gettime(.REALTIME, &ts);
        n += putUint(buf[n..], @intCast(ts.sec));
        const ms: u64 = @intCast(@divTrunc(ts.nsec, 1_000_000));
        buf[n..][0..4].* = .{ '.', '0' + @as(u8, @intCast(ms / 100)), '0' + @as(u8, @intCast(ms / 10 % 10)), '0' + @as(u8, @intCast(ms % 10)) };
        n += 4;
        @memcpy(buf[n..][0..w.tail_len], w.tail[0..w.tail_len]);
        n += w.tail_len;
        if (w.signal) {
            const key = ",\"signal\":";
            @memcpy(buf[n..][0..key.len], key);
            n += key.len;
            n += putUint(buf[n..], @backingInt(sig));
        }
        buf[n..][0..2].* = "}\n".*;
        n += 2;
        const fd = c.open(@ptrCast(&last_path), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
        if (fd >= 0) {
            _ = c.write(fd, &buf, n);
            _ = c.close(fd);
        }
    }
    dieBySignal(sig);
}

/// Writes `v` in decimal at the start of `out`; returns its length.
fn putUint(out: []u8, v: u64) usize {
    var digits: [20]u8 = undefined;
    var i: usize = digits.len;
    var x = v;
    while (true) {
        i -= 1;
        digits[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
        if (x == 0) break;
    }
    const len = digits.len - i;
    @memcpy(out[0..len], digits[i..]);
    return len;
}

fn senderPid(info: *const c.siginfo_t) c.pid_t {
    if (is_darwin) return info.pid;
    return info.fields.common.first.piduid.pid;
}

fn onSignal(sig: c.SIG, info: *const c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    // In the foreground of a terminal, a signal with no sending process came
    // from the kernel's terminal driver (^C, ^\, hangup), which sent it to
    // the whole foreground process group, the command included; like
    // system(3), cpuq lets the command handle it alone. ^C and ^\ there are
    // the terminal's whatever sender they show: macOS can name the process
    // that wrote the keystroke to a pseudo-terminal, and passing them on
    // would deliver them twice. Any other signal some process sent to cpuq
    // goes on to the command, with or without a sender: macOS keeps one
    // sender per process, filled in only when the signal can be taken at
    // once, so a kill that lands while that signal is blocked (its handler
    // running for an earlier one, say) arrives with none. Whether cpuq is in
    // the foreground is asked each time, since a shell can move it (fg, bg).
    if (tty_fd >= 0 and tcgetpgrp(tty_fd) == getpgrp()) {
        if (senderPid(info) == 0 or sig == .INT or sig == .QUIT) return;
    }
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
    for ([_]c_int{ 0, 1, 2 }) |fd| {
        if (std.c.isatty(fd) == 0) continue;
        tty_fd = fd;
        break;
    }
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

/// How a command ended, and the CPU seconds it and the descendants it
/// reaped used (the kernel's own total, from wait4).
pub const Waited = struct {
    exit: Exit,
    cpu_s: f64 = 0,
    /// Set when cpuq stopped the command for its memory: what it used, in bytes.
    memory: ?u64 = null,
    /// The most memory it used at once, in bytes: the larger of the most its
    /// processes used together when looked at, and the most any one of them
    /// held (wait4's maxrss), which catches a job too quick to be looked at.
    peak: u64 = 0,
};

pub fn waitChild(pid: c.pid_t) Waited {
    return waitFor(pid, true).?;
}

/// The child's end if it has ended, without waiting; null while it runs.
pub fn reapChild(pid: c.pid_t) ?Waited {
    return waitFor(pid, false);
}

fn waitFor(pid: c.pid_t, block: bool) ?Waited {
    var status: c_int = 0;
    var ru: c.rusage = undefined;
    while (true) {
        const r = c.wait4(pid, &status, if (block) 0 else 1, &ru); // WNOHANG = 1
        if (r == pid) break;
        if (r == 0) return null;
        if (r < 0 and c.errno(r) == .INTR) continue;
        return .{ .exit = .{ .code = 125 } };
    }
    const cpu_s = seconds(ru.utime) + seconds(ru.stime);
    // maxrss is in bytes on macOS, kilobytes on Linux.
    const rss: u64 = @intCast(@max(ru.maxrss, 0));
    const peak = if (is_darwin) rss else rss * 1024;
    const s: u32 = @bitCast(status);
    if (c.W.IFEXITED(s)) return .{ .exit = .{ .code = c.W.EXITSTATUS(s) }, .cpu_s = cpu_s, .peak = peak };
    if (c.W.IFSIGNALED(s)) return .{ .exit = .{ .signal = c.W.TERMSIG(s) }, .cpu_s = cpu_s, .peak = peak };
    return .{ .exit = .{ .code = 125 }, .cpu_s = cpu_s, .peak = peak };
}

fn seconds(tv: c.timeval) f64 {
    return @as(f64, @floatFromInt(tv.sec)) + @as(f64, @floatFromInt(tv.usec)) / 1e6;
}

/// When this machine last booted, in Unix seconds: macOS kern.boottime;
/// Linux now minus /proc/uptime (/proc/stat's btime follows lines that run
/// to many kilobytes on a big machine).
pub fn bootTime(io: Io) f64 {
    if (is_darwin) {
        var tv: c.timeval = undefined;
        var len: usize = @sizeOf(c.timeval);
        if (c.sysctlbyname("kern.boottime", &tv, &len, null, 0) != 0) return 0;
        return seconds(tv);
    }
    var buf: [128]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/proc/uptime", &buf) catch return 0;
    const first = std.mem.sliceTo(text, ' ');
    const up = std.fmt.parseFloat(f64, first) catch return 0;
    const now: f64 = @floatFromInt(Io.Clock.real.now(io).toNanoseconds());
    return now / 1e9 - up;
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
    /// The program's short name (macOS pbi_name or pbi_comm, Linux comm).
    name: []const u8 = "",
    /// CPU time used so far, user plus system, in nanoseconds: the
    /// process's own and that of its children it has already reaped, so the
    /// many short processes a build or test run starts are counted too.
    cpu_ns: u64,
    /// The process's own CPU time alone, in nanoseconds. Work outside cpuq
    /// is measured by this: a parent's reaped-children time arrives all at
    /// once when it reaps (launchd reaps every orphan), though those
    /// children were already counted while they ran.
    own_ns: u64 = 0,
    /// Memory it uses, in bytes: macOS's physical footprint (what Activity
    /// Monitor and top call Memory, compressed pages included), Linux's
    /// resident set.
    mem: u64 = 0,
    /// Threads running or ready to run now (macOS pti_numrunning; Linux, 1
    /// when the process is in state R).
    running: u32 = 0,
    /// Stopped (SIGSTOP), or a zombie, which runs no more either.
    stopped: bool = false,
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
            var ru: [144]u8 align(8) = undefined;
            if (proc_pid_rusage(pid, 1, &ru) != 0) continue;
            var ticks: u64 = 0;
            for ([_]usize{ 16, 24, 96, 104 }) |at| ticks +%= std.mem.readInt(u64, ru[at..][0..8], .little);
            var own: u64 = 0;
            for ([_]usize{ 16, 24 }) |at| own +%= std.mem.readInt(u64, ru[at..][0..8], .little);
            // ri_phys_footprint, at 72.
            const mem = std.mem.readInt(u64, ru[72..80], .little);
            // struct proc_taskinfo (PROC_PIDTASKINFO, 96 bytes): pti_numrunning at 88.
            var task: [96]u8 align(8) = undefined;
            const running: u32 = if (proc_pidinfo(pid, 4, 0, &task, task.len) == task.len)
                @intCast(@max(std.mem.readInt(i32, task[88..92], .little), 0))
            else
                0;
            var bsd: [136]u8 align(8) = undefined;
            var ppid: i32 = undefined;
            var name: []const u8 = "";
            var stopped = true;
            if (proc_pidinfo(pid, 3, 0, &bsd, bsd.len) == bsd.len) {
                // pbi_status at 4: SSTOP is 4.
                stopped = std.mem.readInt(u32, bsd[4..8], .little) == 4;
                ppid = @bitCast(std.mem.readInt(u32, bsd[16..20], .little));
                // pbi_name (32 bytes at 64) when set, else pbi_comm (16 at 48).
                const long = std.mem.sliceTo(bsd[64..96], 0);
                name = if (long.len != 0) long else std.mem.sliceTo(bsd[48..64], 0);
            } else {
                // A zombie: exited, not yet reaped, and invisible to
                // proc_pidinfo. Its CPU still counts until its parent reaps
                // it and takes it over as child time; left out, a job's
                // CPU would leap by the zombie's whole lifetime at the reap.
                ppid = zombieParent(pid) orelse continue;
            }
            list.append(arena, .{
                .pid = pid,
                .ppid = ppid,
                .name = arena.dupe(u8, name) catch "",
                .cpu_ns = @intCast(@as(u128, ticks) * tb.numer / tb.denom),
                .own_ns = @intCast(@as(u128, own) * tb.numer / tb.denom),
                .mem = mem,
                .running = running,
                .stopped = stopped,
            }) catch break;
        }
        return list.items;
    }
    const tick_hz: u64 = @intCast(@max(sysconf(2), 1)); // _SC_CLK_TCK
    const page: u64 = @intCast(@max(sysconf(30), 4096)); // _SC_PAGESIZE
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
        const open = std.mem.findScalar(u8, text, '(') orelse continue;
        var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
        var ppid: i32 = 0;
        var ticks: u64 = 0;
        var own: u64 = 0;
        var rss: u64 = 0;
        var running: u32 = 0;
        var stopped = false;
        var i: usize = 0;
        while (fields.next()) |f| : (i += 1) {
            switch (i) {
                0 => {
                    running = if (std.mem.eql(u8, f, "R")) 1 else 0;
                    // T stopped, t stopped by a tracer, Z a zombie.
                    stopped = f.len == 1 and (f[0] == 'T' or f[0] == 't' or f[0] == 'Z');
                },
                1 => ppid = std.fmt.parseInt(i32, f, 10) catch 0,
                11, 12 => {
                    const t = std.fmt.parseInt(u64, f, 10) catch 0;
                    ticks += t;
                    own += t;
                },
                13, 14 => ticks += std.fmt.parseInt(u64, f, 10) catch 0,
                // rss, in pages (the 24th field).
                21 => rss = std.fmt.parseInt(u64, f, 10) catch 0,
                else => {},
            }
            if (i == 21) break;
        }
        list.append(arena, .{ .pid = pid, .ppid = ppid, .name = arena.dupe(u8, text[open + 1 .. close]) catch "", .cpu_ns = ticks * std.time.ns_per_s / tick_hz, .own_ns = own * std.time.ns_per_s / tick_hz, .mem = rss * page, .running = running, .stopped = stopped }) catch break;
    }
    return list.items;
}

/// Marks `root` and all its descendants in `in_tree` (indexed like `procs`).
pub fn markTree(procs: []const Proc, root: i32, in_tree: []bool) void {
    var frontier: [512]i32 = undefined;
    var len: usize = 1;
    frontier[0] = root;
    var seen: usize = 0;
    while (seen < len) : (seen += 1) {
        const pid = frontier[seen];
        for (procs, 0..) |p, i| {
            if (p.pid == pid) in_tree[i] = true;
            if (p.ppid == pid and p.pid != pid and len < frontier.len) {
                frontier[len] = p.pid;
                len += 1;
            }
        }
    }
}

/// The CPU time of `root` and all its descendants in a snapshot.
/// The parent of a macOS process, zombies included, from sysctl's
/// kern.proc.pid: struct kinfo_proc (648 bytes), e_ppid at 560.
fn zombieParent(pid: c_int) ?i32 {
    var mib = [4]c_int{ 1, 14, 1, pid }; // CTL_KERN, KERN_PROC, KERN_PROC_PID
    var info: [648]u8 align(8) = undefined;
    var len: usize = info.len;
    if (sysctl(&mib, mib.len, &info, &len, null, 0) != 0 or len != info.len) return null;
    return @bitCast(std.mem.readInt(u32, info[560..564], .little));
}

/// Threads ready to run in a process and its descendants.
pub fn treeRunning(procs: []const Proc, root: i32) u32 {
    var total: u32 = 0;
    var frontier: [512]i32 = undefined;
    var len: usize = 1;
    frontier[0] = root;
    var seen: usize = 0;
    while (seen < len) : (seen += 1) {
        const pid = frontier[seen];
        for (procs) |p| {
            if (p.pid == pid) total += p.running;
            if (p.ppid == pid and p.pid != pid and len < frontier.len) {
                frontier[len] = p.pid;
                len += 1;
            }
        }
    }
    return total;
}

/// The memory a process and its descendants use, in bytes.
pub fn treeMem(procs: []const Proc, root: i32) u64 {
    var total: u64 = 0;
    var frontier: [512]i32 = undefined;
    var len: usize = 1;
    frontier[0] = root;
    var seen: usize = 0;
    while (seen < len) : (seen += 1) {
        const pid = frontier[seen];
        for (procs) |p| {
            if (p.pid == pid) total += p.mem;
            if (p.ppid == pid and p.pid != pid and len < frontier.len) {
                frontier[len] = p.pid;
                len += 1;
            }
        }
    }
    return total;
}

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

/// Milliseconds on a clock that only moves forward.
pub fn monoMs() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

fn sleepMs(ms: u32) void {
    var ts: c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast(@as(u64, ms % 1000) * 1_000_000) };
    _ = c.nanosleep(&ts, &ts);
}

/// A lease held for someone else (`--hold`, as `cpuq lease --host` runs it
/// over ssh) watches its stdin from a thread of its own: the hold ends when
/// stdin closes, or, once the far end has sent heartbeats, when they stop.
/// A connection that drops without closing (the network gone, the client's
/// machine asleep) leaves the far end's stdin open but silent; without this
/// the lease, waiting or held, would outlive its holder.
pub const StdinWatch = struct {
    var started = false;
    var eof = std.atomic.Value(bool).init(false);
    /// Written when stdin closes, so a waiter wakes at once.
    var wake: [2]c.fd_t = .{ -1, -1 };
    /// When the last heartbeat came, in monoMs; 0 before the first.
    var beat = std.atomic.Value(i64).init(0);

    pub fn start() void {
        if (started) return;
        started = true;
        _ = c.pipe(&wake);
        // Started with cpuq's signals held, so they never reach this thread.
        const before = holdHandled();
        defer restoreSignals(before);
        const t = std.Thread.spawn(.{}, run, .{}) catch return;
        t.detach();
    }

    fn run() void {
        var buf: [64]u8 = undefined;
        while (true) {
            const n = c.read(0, &buf, buf.len);
            if (n > 0) {
                beat.store(monoMs(), .release);
                continue;
            }
            if (n < 0 and c.errno(n) == .INTR) continue;
            eof.store(true, .release);
            if (wake[1] >= 0) _ = c.write(wake[1], "x", 1);
            return;
        }
    }

    /// Returns once the holder is gone: at once when stdin closes (the kit
    /// closes a hold's stdin and kills it in the same breath), else within a
    /// second of the heartbeats stopping.
    pub fn untilGone(quiet_ms: i64) void {
        while (!gone(quiet_ms)) {
            var fds = [_]c.pollfd{.{ .fd = wake[0], .events = c.POLL.IN, .revents = 0 }};
            _ = c.poll(&fds, 1, 1000);
        }
    }

    /// The holder is gone: stdin closed, or heartbeats came and none for
    /// `quiet_ms`. Always false unless watching.
    pub fn gone(quiet_ms: i64) bool {
        if (!started) return false;
        if (eof.load(.acquire)) return true;
        const last = beat.load(.acquire);
        return last != 0 and monoMs() - last > quiet_ms;
    }
};

/// Sends a newline down `fd` (ssh's stdin, to a remote hold's StdinWatch)
/// now and every `every_ms` from a thread of its own, until stopped or the
/// pipe breaks.
pub const Heartbeat = struct {
    fd: c.fd_t,
    every_ms: u32 = 10_000,
    stopping: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    pub fn start(self: *Heartbeat) void {
        // Started with cpuq's signals held, so they never reach this thread.
        const before = holdHandled();
        defer restoreSignals(before);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch null;
    }

    fn run(self: *Heartbeat) void {
        // A broken pipe is an error here, never a signal that ends cpuq.
        var pipe: c.sigset_t = undefined;
        _ = c.sigemptyset(&pipe);
        _ = c.sigaddset(&pipe, .PIPE);
        _ = c.sigprocmask(c.SIG.BLOCK, &pipe, null);
        var since: u32 = self.every_ms;
        while (!self.stopping.load(.acquire)) {
            if (since >= self.every_ms) {
                since = 0;
                if (c.write(self.fd, "\n", 1) < 0) return;
            }
            sleepMs(100);
            since += 100;
        }
    }

    /// Stops sending; returns once the thread is done with `fd`.
    pub fn stop(self: *Heartbeat) void {
        self.stopping.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }
};
