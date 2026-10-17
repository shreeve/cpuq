//! `cpuq run`: runs a command here once admitted, watches it, and ends its job; and the
//! state of the one job this cpuq waits for or runs.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");
const joblog = @import("joblog.zig");
const admission = @import("admission.zig");
const leasing = @import("leasing.zig");
const timing = @import("timing.zig");
const remotes = @import("remotes.zig");
const statusjson = @import("statusjson.zig");

const exit_usage = main.exit_usage;
const exit_noexec = main.exit_noexec;
const exit_notfound = main.exit_notfound;
const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const loadConfig = main.loadConfig;
const stateDir = main.stateDir;
const openState = main.openState;
const RunOptions = runopts.RunOptions;
const parseRun = runopts.parseRun;
const findExecutable = runopts.findExecutable;
const Lease = joblog.Lease;
const nowFloat = joblog.nowFloat;
const logEnded = joblog.logEnded;
const waitTurn = admission.waitTurn;
const keepNote = admission.keepNote;
const rewriteRecord = admission.rewriteRecord;
const release = admission.release;
const addLeaseEnv = leasing.addLeaseEnv;
const exclusiveWindow = leasing.exclusiveWindow;
const exclusiveOff = leasing.exclusiveOff;
const releaseExclusiveCores = leasing.releaseExclusiveCores;
const Noise = timing.Noise;
const keepFrozen = timing.keepFrozen;
const runOn = remotes.runOn;
const isSelf = remotes.isSelf;
const readProgress = statusjson.readProgress;

// The one job this cpuq waits for or runs: its state, which admission, leasing,
// timing and remotes share as runner.NAME.

/// Whether this run is tethered to a caller over ssh (`--tethered`).
pub var tethered = false;

/// A run sent to a host by name and lost there is started again and rerun only once.
pub var send_retried = false;

/// Which last-words slot the job being waited for or run uses: 1 for the
/// cores of a lease taken `--exclusive`, so its two jobs each get a line.
pub var words_slot: u1 = 0;

/// The cores the grant being logged borrowed (read by `admitted`).
pub var lent_now: u32 = 0;

/// Whether the grant being logged was given by hand (read by `admitted`).
pub var forced_now = false;

/// The lease this run holds and its state, for watchChild's look at the job's progress.
var counting_lease: ?*Lease = null;

var counting_state: ?*state.State = null;

/// The progress file this run made for its job, removed when the job ends.
var own_progress: ?[]const u8 = null;

/// The machine's cores held with a lease taken `--exclusive`, given back with it.
pub var exclusive_cores: ?struct { st: *state.State, lease: Lease } = null;

/// How long a hold whose holder sends heartbeats waits without one before
/// it takes them for gone: six missed beats (CPUQ_HOLD_QUIET, in seconds).
pub var hold_quiet_ms: i64 = 60_000;

/// The most cores the command's tree kept busy over one look (`watchChild`).
pub var cpu_peak: f64 = 0;

/// The running timing window's `Noise`, if this cpuq holds one.
pub var window_noise: ?Noise = null;

/// The lease of the ordinary job this cpuq runs, so that it keeps its own
/// command frozen while a timing window says so (`keepFrozen`).
pub var own_lease: ?struct { st: *state.State, name: []const u8 } = null;

/// True when CPUQ_TOKEN names a lease that is still held, i.e. this run is
/// inside a running one.
pub fn nestedGrant(ctx: *Ctx) bool {
    const token = ctx.env.get("CPUQ_TOKEN") orelse return false;
    if (token.len == 0 or std.mem.findScalar(u8, token, '/') != null) return false;
    const path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/leases/", token }) catch return false;
    const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return false;
    defer f.close(ctx.io);
    const free = f.tryLock(ctx.io, .shared) catch return false;
    if (free) f.unlock(ctx.io);
    return !free;
}

pub fn cmdRun(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var o = parseRun(args) orelse return exit_usage;
    if (o.cmd.len == 0) return usageError("run needs a command", .{});
    if (o.host != null or o.hold or o.slots != 1) return usageError("--host, --hold and --slots are options of `cpuq lease`", .{});

    if (nestedGrant(ctx)) {
        // Inside a running job: run at once within its grant, everything
        // passed through untouched.
        const err = std.process.replace(ctx.io, .{ .argv = @ptrCast(o.cmd) });
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        return if (err == error.FileNotFound) exit_notfound else exit_noexec;
    }
    if (exclusiveWindow(ctx)) |token| {
        // Inside a lease held `--exclusive` on this machine (its CPUQ_LEASES
        // entry passed through ssh): the window is this run's own, so it
        // starts at once with the cores it asked for, at most.
        var num: [16]u8 = undefined;
        ctx.env.put("CPUQ_CORES", std.mem.print(&num, "{d}", .{o.request.max}) catch "1") catch fail("out of memory", .{});
        ctx.env.put("CPUQ_TOKEN", token) catch fail("out of memory", .{});
        const err = std.process.replace(ctx.io, .{ .argv = @ptrCast(o.cmd), .environ_map = ctx.env });
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        return if (err == error.FileNotFound) exit_notfound else exit_noexec;
    }
    _ = ctx.env.swapRemove("CPUQ_TOKEN");

    loadConfig(ctx);
    if (o.exclusive and !ctx.cfg.exclusive) o.exclusive = exclusiveOff(o.label);
    if ((o.return_count != 0 or o.include_count != 0) and o.on == null) return usageError("--return and --include go with --on", .{});
    // `--on` this machine itself runs here; any other host must be one of this machine's remotes.
    if (o.on) |h| {
        if (isSelf(ctx.arena, h)) {
            o.on = null;
            o.return_count = 0;
            o.include_count = 0;
        } else if (!ctx.cfg.isRemote(h)) {
            return usageError("--on {s}: not one of this machine's remotes (config remotes = {s})", .{ h, if (ctx.cfg.remotes.len == 0) "none" else ctx.cfg.remotes });
        }
    }
    if (o.tethered) tether();
    if (o.on) |h| {
        if (o.exclusive) return usageError("--on sends ordinary jobs, not --exclusive ones (time on the machine you mean)", .{});
        return runOn(ctx, o, h);
    }
    return runHere(ctx, o);
}

/// Waits its turn on this machine and runs the command.
pub fn runHere(ctx: *Ctx, o: RunOptions) u8 {
    const exe = findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return exit_notfound;
    };
    var st = openState(ctx);
    const lease = waitTurn(ctx, &st, o);
    return runAdmitted(ctx, &st, o, exe, lease);
}

/// `--tethered`: the caller (a `cpuq run --on` on another machine)
/// sends heartbeats down stdin. A waiting run gives up once they stop, and a
/// running one stops its command, as when the caller is killed or loses the
/// connection. The command gets /dev/null for stdin.
fn tether() void {
    tethered = true;
    // Heartbeats come every 10 s; three missed is gone.
    hold_quiet_ms = 35_000;
    sys.StdinWatch.startAside();
}

/// Waits for the command, looking at the memory it and its descendants use
/// every 2 seconds and keeping the most, for history. With `max_memory` set,
/// over the limit the whole tree is asked to stop (SIGTERM), and made to
/// (SIGKILL) if any of it is still there 10 seconds on: one job that balloons
/// would otherwise fill the swap and shut the memory gate on everyone. It
/// checks for the end every tenth of a second, so the cores go on promptly.
fn watchChild(ctx: *Ctx, pid: std.c.pid_t, label: []const u8) sys.Waited {
    const limit = ctx.cfg.max_memory;
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    var stopped: ?u64 = null;
    var stopped_at: f64 = 0;
    // A tethered run whose caller has gone: when its command was stopped.
    var abandoned_at: ?f64 = null;
    var peak: u64 = 0;
    var last_cpu: u64 = 0;
    var last_ms: i64 = 0;
    const start_ms = sys.monoMs();
    var tick: u32 = 0;
    while (true) : (tick += 1) {
        if (sys.reapChild(pid)) |w| return lastLook(ctx, &arena_state, peakAtLeastAverage(withMemory(w, stopped, peak), start_ms), label);
        ctx.io.sleep(.fromMilliseconds(100), .awake) catch {};
        // The first look at half a second, then every 2.
        if (tick < 5 or (tick - 5) % 20 != 0) continue;
        if (sys.reapChild(pid)) |w| return lastLook(ctx, &arena_state, peakAtLeastAverage(withMemory(w, stopped, peak), start_ms), label);
        markCounting(ctx);
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        const procs = sys.processes(ctx.io, a);
        if (window_noise) |*n| {
            // A timing window: everything but its own command (and cpuq) is
            // other work beside it.
            const own = a.alloc(bool, procs.len) catch continue;
            @memset(own, false);
            sys.markTree(procs, pid, own);
            const self = sys.getpid();
            for (procs, own) |p, *o| if (p.pid == self) {
                o.* = true;
            };
            n.observe(procs, own, true, label);
        }
        keepFrozen(ctx, a, procs, pid);
        if (abandoned_at) |t| {
            if (nowFloat(ctx.io) - t >= 10) signalTree(a, procs, pid, .KILL);
        } else if (tethered and sys.StdinWatch.gone(hold_quiet_ms)) {
            std.debug.print("cpuq: whoever ran {s} here has gone (killed, or the connection lost); stopping it\n", .{if (label.len != 0) label else "this job"});
            abandoned_at = nowFloat(ctx.io);
            signalTree(a, procs, pid, .TERM);
        }
        if (stopped != null) {
            if (nowFloat(ctx.io) - stopped_at >= 10) signalTree(a, procs, pid, .KILL);
            continue;
        }
        // The busiest stretch: the tree's CPU over each look of a second or
        // more (`cpu_peak` in history, which sizes the label's next runs).
        const cpu_now = sys.treeCpu(procs, pid);
        const now_ms = sys.monoMs();
        if (last_ms != 0 and now_ms - last_ms >= 1000 and cpu_now >= last_cpu)
            cpu_peak = @max(cpu_peak, @as(f64, @floatFromInt(cpu_now - last_cpu)) / @as(f64, @floatFromInt((now_ms - last_ms) * 1_000_000)));
        last_cpu = cpu_now;
        last_ms = now_ms;
        const used = sys.treeMem(procs, pid);
        peak = @max(peak, used);
        if (limit == 0 or used <= limit) continue;
        const gb = 1 << 30;
        std.debug.print("cpuq: stopping {s}: its processes use {d:.2} GB of memory, over max_memory ({d:.2} GB)\n", .{
            if (label.len != 0) label else "the command", @as(f64, @floatFromInt(used)) / gb, @as(f64, @floatFromInt(limit)) / gb,
        });
        stopped = used;
        stopped_at = nowFloat(ctx.io);
        signalTree(a, procs, pid, .TERM);
    }
}

/// The peak is never below the run's average: a run too short, or a machine
/// too slow, for two looks a second apart still records its use.
fn peakAtLeastAverage(w: sys.Waited, start_ms: i64) sys.Waited {
    const ms = sys.monoMs() - start_ms;
    if (ms > 0) cpu_peak = @max(cpu_peak, w.cpu_s / (@as(f64, @floatFromInt(ms)) / 1000));
    return w;
}

/// A timing window's last look at the work beside it, as its command ends,
/// so even a short window, or one on a slow machine, gets one interval.
fn lastLook(ctx: *Ctx, arena_state: *std.heap.ArenaAllocator, w: sys.Waited, label: []const u8) sys.Waited {
    const n = if (window_noise) |*n| n else return w;
    _ = arena_state.reset(.retain_capacity);
    const a = arena_state.allocator();
    const procs = sys.processes(ctx.io, a);
    const own = a.alloc(bool, procs.len) catch return w;
    const self = sys.getpid();
    for (procs, own) |p, *o| o.* = p.pid == self;
    n.observe(procs, own, true, label);
    return w;
}

fn withMemory(w: sys.Waited, stopped: ?u64, peak: u64) sys.Waited {
    var out = w;
    out.memory = stopped;
    out.peak = @max(w.peak, peak);
    return out;
}

/// Sends `sig` to `root` and all its descendants, continuing any that are
/// stopped (paused by hand) so they can act on it.
fn signalTree(a: std.mem.Allocator, procs: []const sys.Proc, root: std.c.pid_t, sig: std.c.SIG) void {
    const in_tree = a.alloc(bool, procs.len) catch return;
    @memset(in_tree, false);
    sys.markTree(procs, root, in_tree);
    for (procs, in_tree) |p, mine| if (mine) {
        _ = std.c.kill(p.pid, sig);
        _ = std.c.kill(p.pid, .CONT);
    };
}

/// The job's first count: when it came and what it said, kept in its record, so its time left
/// is reckoned from its rate since it began counting, not from its start (a build first, say).
fn markCounting(ctx: *Ctx) void {
    const l = counting_lease orelse return;
    if (l.record.progress_since != 0 or l.record.progress.len == 0) return;
    const p = readProgress(ctx.io, l.record.progress) orelse return;
    const st = counting_state orelse return;
    st.lock() catch return;
    defer st.unlock();
    l.record.progress_since = nowSeconds(ctx.io);
    l.record.progress_base = p.done;
    keepNote(ctx.arena, ctx.io, l.file, &l.record);
    rewriteRecord(ctx.io, l.file, l.record);
}

pub fn runAdmitted(ctx: *Ctx, st: *state.State, o: RunOptions, exe: [:0]const u8, lease_in: Lease) u8 {
    const io = ctx.io;
    var lease = lease_in;
    const k = lease.record.cores;

    // The command and its descendants share the token and lease locks, so a
    // SIGKILLed cpuq does not hand the cores on while the command runs.
    for (lease.tokens) |t| sys.inherit(t.handle);
    sys.inherit(lease.file.handle);

    // A lease adds itself to CPUQ_LEASES and leaves the cores, the
    // jobserver and the scheduling class as they are.
    var pipe: [2]std.c.fd_t = .{ -1, -1 };
    if (o.lease) |name| {
        addLeaseEnv(ctx, name, lease.name);
        // Holding the machine's cores too (`--exclusive`): the command's own
        // `cpuq run`s start at once inside them, as nested runs.
        if (exclusive_cores) |x| {
            for (x.lease.tokens) |t| sys.inherit(t.handle);
            sys.inherit(x.lease.file.handle);
            var num: [16]u8 = undefined;
            ctx.env.put("CPUQ_CORES", std.mem.print(&num, "{d}", .{x.lease.record.cores}) catch "1") catch fail("out of memory", .{});
            ctx.env.put("CPUQ_TOKEN", x.lease.name) catch fail("out of memory", .{});
        }
    } else {
        var num: [16]u8 = undefined;
        ctx.env.put("CPUQ_CORES", std.mem.print(&num, "{d}", .{k}) catch "1") catch fail("out of memory", .{});
        ctx.env.put("CPUQ_TOKEN", lease.name) catch fail("out of memory", .{});
        // Where the job may report its progress (`DONE TOTAL FAILING`): one cpuq submit chose
        // (CPUQ_PROGRESS_AT), else one of its own beside the queue, removed when it ends. A
        // CPUQ_PROGRESS inherited from another job is that job's, never this one's.
        if (ctx.env.get("CPUQ_PROGRESS_AT")) |at| {
            // A copy: removing the variable frees the string the map held.
            const p = ctx.arena.dupe(u8, at) catch "";
            lease.record.progress = p;
            ctx.env.put("CPUQ_PROGRESS", p) catch {};
            _ = ctx.env.swapRemove("CPUQ_PROGRESS_AT");
        } else {
            const p = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/progress-", lease.name }) catch "";
            Io.Dir.cwd().deleteFile(io, p) catch {};
            ctx.env.put("CPUQ_PROGRESS", p) catch {};
            lease.record.progress = p;
            own_progress = p;
        }
        pipe = sys.jobserverPipe(k - 1) catch |err| fail("jobserver: {t}", .{err});
        const flags = policy.makeflags(ctx.arena, ctx.env.get("MAKEFLAGS"), pipe[0], pipe[1]) catch fail("out of memory", .{});
        ctx.env.put("MAKEFLAGS", flags) catch fail("out of memory", .{});
    }
    const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch fail("out of memory", .{});

    const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch fail("out of memory", .{});
    for (o.cmd, 0..) |a, i| argv[i] = a.ptr;

    sys.installForwarding();
    // A timing window watches what other work runs beside it; an ordinary
    // job keeps itself frozen while a window says so.
    if (lease.record.exclusive or exclusive_cores != null) window_noise = .{};
    if (o.lease == null and !lease.record.exclusive) own_lease = .{ .st = st, .name = lease.name };
    const qos_enabled = ctx.cfg.qos and o.qos and o.lease == null;
    const qos: policy.Qos = if (lease.borrowed > 0 and qos_enabled and policy.borrowersYield()) .background else policy.qosFor(o.priority, o.exclusive, qos_enabled);
    // Linux: the job runs in a systemd user scope of its own. With `cgroups`
    // the scope is delegated, and the command runs in its `job/`, so
    // `cpuq cap` can make cgroups beside it (CPUQ_CGROUP); with `cpu_weights`
    // it is weighted by its grant, so a crowded machine's CPU time divides by
    // grant however many threads a job starts.
    const weighted: ?[*:null]const ?[*:0]const u8 = if (o.lease == null and !lease.record.exclusive and (ctx.cfg.cpu_weights or ctx.cfg.cgroups)) weightedArgv(ctx, exe, argv, k, lease.name) else null;
    // Where that scope's cgroup is: when the command ends, whatever it left in it is stopped.
    const scope_dir: ?[:0]const u8 = if (weighted != null) ctx.arena.printSentinel("/sys/fs/cgroup/user.slice/user-{d}.slice/user@{d}.service/app.slice/cpuq-{s}-{d}.scope", .{ std.c.getuid(), std.c.getuid(), lease.name, sys.getpid() }, 0) catch null else null;
    const spawned = if (weighted) |wv| sys.spawn(wv[0].?, wv, @ptrCast(envp.slice.ptr), qos) else sys.spawn(exe, argv.ptr, @ptrCast(envp.slice.ptr), qos);
    if (pipe[0] >= 0) sys.closeFd(pipe[0]);
    if (pipe[1] >= 0) sys.closeFd(pipe[1]);
    const waited: sys.Waited = if (spawned) |pid| blk: {
        sys.setChild(pid);
        // Under the lock `cpuq note` takes, so a note it sets now is kept, not written over.
        st.lock() catch {};
        lease.record.child = pid;
        keepNote(ctx.arena, io, lease.file, &lease.record);
        rewriteRecord(io, lease.file, lease.record);
        if (exclusive_cores) |*x| {
            x.lease.record.child = pid;
            keepNote(ctx.arena, io, x.lease.file, &x.lease.record);
            rewriteRecord(io, x.lease.file, x.lease.record);
        }
        st.unlock();
        counting_lease = &lease;
        counting_state = st;
        const w = watchChild(ctx, pid, lease.job.base.label);
        counting_lease = null;
        // The command is done: what it left behind in its scope (a daemon, a test program a
        // killed runner started) goes too, so nothing runs on unaccounted. systemd removes
        // the emptied scope.
        if (scope_dir) |d| {
            if (ctx.arena.printSentinel("{s}/cgroup.kill", .{d}, 0)) |kp| _ = writeSmall(kp, "1") else |_| {}
        }
        break :blk w;
    } else |err| blk: {
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        break :blk .{ .exit = .{ .code = if (err == error.FileNotFound) exit_notfound else exit_noexec } };
    };

    if (window_noise) |*n| n.report(lease.job.base.label);
    own_lease = null;
    releaseExclusiveCores(ctx, waited);
    if (own_progress) |p| Io.Dir.cwd().deleteFile(io, p) catch {};
    release(io, st, lease);
    logEnded(ctx, lease.job, k, waited);
    ctx.out.flush() catch {};
    switch (waited.exit) {
        .code => |c| return c,
        .signal => |sig| sys.dieBySignal(sig),
    }
}

/// `systemd-run --user --scope [-p CPUWeight=W] [-p Delegate=yes ...] --
/// [cpuq _job --] EXE ARGS...` for a job of `cores`, when this is Linux with
/// a user systemd that can make scopes; else null, and the job runs as it is.
/// systemd-run and `cpuq _job` exec the command in place, so its pid stays
/// the job's. Whether scopes work is probed once and remembered for ten
/// minutes ("weights-ok" in the state directory), so a job never fails for
/// want of one.
fn weightedArgv(ctx: *Ctx, exe: [:0]const u8, argv: [:null]?[*:0]const u8, cores: u32, lease_name: []const u8) ?[*:null]const ?[*:0]const u8 {
    if (@import("builtin").os.tag != .linux) return null;
    const run = findExecutable(ctx, "systemd-run") orelse return null;
    const scopes = scopesWork(ctx, run);
    if (scopes == .none) return null;
    const a = ctx.arena;
    var head: std.ArrayList([]const u8) = .empty;
    head.appendSlice(a, &.{ run, "--user", "--scope", "--quiet", "--collect" }) catch return null;
    // systemd 254 and later expand $VAR and ${VAR} in the command line themselves, before
    // the command's shell sees it: `sh -c 'echo ${x%/job}'` would fail, or quietly change.
    if (scopes == .literal) head.append(a, "--expand-environment=no") catch return null;
    if (ctx.cfg.cpu_weights) {
        const weight = std.math.clamp(@as(u64, cores) * 100, 1, 10000);
        head.append(a, a.print("--property=CPUWeight={d}", .{weight}) catch return null) catch return null;
    }
    // A cgroup OOM inside the job (a capped program's) is the program's
    // business: the job goes on.
    const self: ?[]const u8 = if (ctx.cfg.cgroups) selfExe(a) else null;
    if (self != null) head.appendSlice(a, &.{ "--property=Delegate=yes", "--property=OOMPolicy=continue" }) catch return null;
    head.append(a, a.print("--unit=cpuq-{s}-{d}", .{ lease_name, sys.getpid() }) catch return null) catch return null;
    head.append(a, "--") catch return null;
    if (self) |s| head.appendSlice(a, &.{ s, "_job", "--" }) catch return null;
    const out = a.allocSentinel(?[*:0]const u8, head.items.len + 1 + argv.len - 1, null) catch return null;
    for (head.items, 0..) |h, i| out[i] = (a.dupeSentinel(u8, h, 0) catch return null).ptr;
    out[head.items.len] = exe.ptr;
    for (argv[1..], 0..) |v, i| out[head.items.len + 1 + i] = v;
    return out.ptr;
}

/// This binary's own path (Linux: /proc/self/exe), for `cpuq _job`. A cpuq
/// replaced while this one waited in the queue reads "PATH (deleted)": the
/// new binary at PATH runs `_job` as well.
fn selfExe(a: std.mem.Allocator) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return null;
    const path = buf[0..@intCast(n)];
    return a.dupe(u8, if (std.mem.endsWith(u8, path, " (deleted)")) path[0 .. path.len - " (deleted)".len] else path) catch null;
}

/// `cpuq _job -- EXE ARGS...`, run by systemd-run inside a job's delegated
/// scope: moves itself into the scope's `job/`, enables the memory and pids
/// controllers for the scope's children (which needs the scope's own cgroup
/// empty of processes, hence the move), exports the scope as CPUQ_CGROUP for
/// `cpuq cap`, and execs the command in place. If any of that fails, the
/// command runs anyway, without CPUQ_CGROUP: caps then watch the slow way.
pub fn cmdJob(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var i: usize = 0;
    if (i < args.len and std.mem.eql(u8, args[i], "--")) i += 1;
    if (i >= args.len) return usageError("_job needs -- EXE [ARGS...]", .{});
    const a = ctx.arena;
    if (@import("builtin").os.tag == .linux) delegate: {
        var buf: [1024]u8 = undefined;
        const fd = std.c.open("/proc/self/cgroup", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) break :delegate;
        const n = std.c.read(fd, &buf, buf.len);
        _ = std.c.close(fd);
        if (n <= 0) break :delegate;
        const text: []const u8 = buf[0..@intCast(n)];
        const line = std.mem.sliceTo(text[(std.mem.find(u8, text, "0::") orelse break :delegate) + 3 ..], '\n');
        const scope = a.print("/sys/fs/cgroup{s}", .{line}) catch break :delegate;
        const job = a.printSentinel("{s}/job", .{scope}, 0) catch break :delegate;
        if (std.c.mkdir(job, 0o755) != 0 and std.c.errno(-1) != .EXIST) break :delegate;
        if (!writeSmall(a.printSentinel("{s}/job/cgroup.procs", .{scope}, 0) catch break :delegate, "0")) break :delegate;
        if (!writeSmall(a.printSentinel("{s}/cgroup.subtree_control", .{scope}, 0) catch break :delegate, "+memory +pids")) break :delegate;
        ctx.env.put("CPUQ_CGROUP", scope) catch break :delegate;
    }
    const argv = a.allocSentinel(?[*:0]const u8, args.len - i, null) catch fail("out of memory", .{});
    for (args[i..], 0..) |v, k| argv[k] = v.ptr;
    const envp = ctx.env.createPosixBlock(a, .{}) catch fail("out of memory", .{});
    _ = std.c.execve(args[i].ptr, argv.ptr, @ptrCast(envp.slice.ptr));
    std.debug.print("cpuq: {s}: can't be run\n", .{args[i]});
    return if (std.c.errno(-1) == .NOENT) exit_notfound else exit_noexec;
}

fn writeSmall(path: [:0]const u8, value: []const u8) bool {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    return std.c.write(fd, value.ptr, value.len) == @as(isize, @intCast(value.len));
}

const Scopes = enum {
    none,
    /// Scopes work, and systemd-run passes the command line as it is.
    plain,
    /// Scopes work, with `--expand-environment=no` (systemd 254 and later, which expand
    /// variables in the command line otherwise).
    literal,
};

/// Whether `systemd-run --user --scope` works here, and how to keep it from
/// expanding variables in a command line: tried once, the answer kept ten
/// minutes ("weights-ok" in the state directory, holding "literal" or
/// "plain").
fn scopesWork(ctx: *Ctx, run: [:0]const u8) Scopes {
    const io = ctx.io;
    const path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/weights-ok" }) catch return .none;
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, path, .{})) |st| {
        const age_ns = Io.Clock.real.now(io).toNanoseconds() - st.mtime.toNanoseconds();
        var buf: [16]u8 = undefined;
        const kept = cwd.readFile(io, path, &buf) catch "";
        // A failure is kept a minute only: one probe from a shell without the user's systemd, or
        // during a hiccup, must not take every job's cgroup away for long.
        const none = std.mem.startsWith(u8, kept, "none");
        const keep_s: i96 = if (none) 60 else 600;
        if (age_ns >= 0 and age_ns < keep_s * std.time.ns_per_s) {
            if (none) return .none;
            return if (std.mem.startsWith(u8, kept, "plain")) .plain else .literal;
        }
    } else |_| {}
    const tries = [_]struct { scopes: Scopes, argv: []const []const u8 }{
        .{ .scopes = .literal, .argv = &.{ run, "--user", "--scope", "--quiet", "--collect", "--expand-environment=no", "true" } },
        .{ .scopes = .plain, .argv = &.{ run, "--user", "--scope", "--quiet", "--collect", "true" } },
    };
    for (tries) |t| {
        var child = std.process.spawn(io, .{ .argv = t.argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return .none;
        const term = child.wait(io) catch return .none;
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) continue;
        cwd.writeFile(io, .{ .sub_path = path, .data = @tagName(t.scopes) }) catch {};
        return t.scopes;
    }
    // Remembered for a minute, where the user's systemd is set up (a session without
    // XDG_RUNTIME_DIR simply can't reach it, and says nothing about the machine).
    if (ctx.env.get("XDG_RUNTIME_DIR") != null) {
        cwd.writeFile(io, .{ .sub_path = path, .data = "none" }) catch {};
        if (ctx.cfg.cgroups) std.debug.print("cpuq: systemd user scopes don't work here, so jobs run without a cgroup of their own (cpuq cap then reads memory once a second)\n", .{});
    }
    return .none;
}
