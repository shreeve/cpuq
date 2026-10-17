//! `cpuq lease`: named leases, the cores of a lease taken `--exclusive`, and holds for
//! another machine (`--hold`).
const std = @import("std");
const Io = std.Io;
const state = @import("state.zig");
const sys = @import("sys.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");
const joblog = @import("joblog.zig");
const admission = @import("admission.zig");
const runner = @import("runner.zig");
const timing = @import("timing.zig");
const remotes = @import("remotes.zig");

const exit_usage = main.exit_usage;
const exit_noexec = main.exit_noexec;
const exit_notfound = main.exit_notfound;
const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;
const loadConfig = main.loadConfig;
const stateDir = main.stateDir;
const openState = main.openState;
const RunOptions = runopts.RunOptions;
const parseRun = runopts.parseRun;
const findExecutable = runopts.findExecutable;
const Lease = joblog.Lease;
const EventExtra = joblog.EventExtra;
const logEvent = joblog.logEvent;
const armLastWords = joblog.armLastWords;
const logEnded = joblog.logEnded;
const waitTurn = admission.waitTurn;
const release = admission.release;
const runAdmitted = runner.runAdmitted;
const noiseInto = timing.noiseInto;
const watchWindow = timing.watchWindow;
const runRemote = remotes.runRemote;

/// A lease name: letters, digits, `.`, `_` and `-`.
pub fn validLeaseName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.' or name[0] == '-') return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// The state of the named lease NAME: a pool of one in the state directory.
pub fn openNamed(ctx: *Ctx, name: []const u8) state.State {
    const dir = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/named/", name }) catch fail("out of memory", .{});
    return state.State.open(ctx.io, dir) catch |err| fail("state directory {s}: {t}", .{ dir, err });
}

/// Adds an entry to CPUQ_LEASES, the leases a command runs inside: `NAME=ID`
/// for a lease held on this machine, `NAME@HOST=ID:PID` for one held on
/// HOST by the local cpuq PID.
pub fn addLeaseEnv(ctx: *Ctx, name: []const u8, id: []const u8) void {
    const old = ctx.env.get("CPUQ_LEASES") orelse "";
    const entry = ctx.arena.print("{s}{s}{s}={s}", .{ old, if (old.len == 0) "" else " ", name, id }) catch fail("out of memory", .{});
    ctx.env.put("CPUQ_LEASES", entry) catch fail("out of memory", .{});
}

/// True when this run is inside a holder of the lease NAME (on HOST, for
/// `--host`), so it must not queue behind itself. A local entry counts
/// while its lease file is still held here, which also covers an entry
/// passed through ssh to the host that holds it; a remote entry counts
/// while the local cpuq holding it lives.
fn nestedLease(ctx: *Ctx, name: []const u8, host: ?[]const u8) bool {
    const leases = ctx.env.get("CPUQ_LEASES") orelse return false;
    var entries = std.mem.tokenizeScalar(u8, leases, ' ');
    while (entries.next()) |entry| {
        const key, const val = std.mem.cutScalar(u8, entry, '=') orelse continue;
        const entry_name, const entry_host = std.mem.cutScalar(u8, key, '@') orelse .{ key, "" };
        if (!std.mem.eql(u8, entry_name, name)) continue;
        const id, const pid_text = std.mem.cutScalar(u8, val, ':') orelse .{ val, "" };
        if (host) |h| {
            if (std.mem.eql(u8, entry_host, h)) {
                const pid = std.fmt.parseInt(i32, pid_text, 10) catch continue;
                if (sys.processAlive(pid)) return true;
            }
            continue;
        }
        if (id.len == 0 or std.mem.findScalar(u8, id, '/') != null) continue;
        const path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/named/", name, "/leases/", id }) catch continue;
        const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch continue;
        defer f.close(ctx.io);
        const free = f.tryLock(ctx.io, .shared) catch continue;
        if (free) f.unlock(ctx.io) else return true;
    }
    return false;
}

/// When CPUQ_LEASES names a lease held here whose holder also holds the
/// machine's cores exclusively (`cpuq lease --exclusive`), the name of that
/// exclusive grant: work the holder starts here over ssh, passing its
/// CPUQ_LEASES along, runs inside the window instead of queueing behind it.
pub fn exclusiveWindow(ctx: *Ctx) ?[]const u8 {
    const leases = ctx.env.get("CPUQ_LEASES") orelse return null;
    const io = ctx.io;
    const cwd = Io.Dir.cwd();
    var entries = std.mem.tokenizeScalar(u8, leases, ' ');
    while (entries.next()) |entry| {
        const key, const val = std.mem.cutScalar(u8, entry, '=') orelse continue;
        const name, _ = std.mem.cutScalar(u8, key, '@') orelse .{ key, "" };
        const id, _ = std.mem.cutScalar(u8, val, ':') orelse .{ val, "" };
        if (!validLeaseName(name) or id.len == 0 or std.mem.findScalar(u8, id, '/') != null) continue;
        const path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/named/", name, "/leases/", id }) catch continue;
        const holder = heldRecord(ctx, path) orelse continue;
        // The exclusive grant the same cpuq holds.
        const dir_path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/leases" }) catch continue;
        var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (!std.mem.endsWith(u8, e.name, ".x")) continue;
            const x_path = std.mem.concat(ctx.arena, u8, &.{ dir_path, "/", e.name }) catch continue;
            const r = heldRecord(ctx, x_path) orelse continue;
            if (r.pid == holder.pid) return ctx.arena.dupe(u8, e.name) catch null;
        }
    }
    return null;
}

/// The record in a lease file that its holder still holds.
pub fn heldRecord(ctx: *Ctx, path: []const u8) ?state.Record {
    const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return null;
    defer f.close(ctx.io);
    const free = f.tryLock(ctx.io, .shared) catch return null;
    if (free) {
        f.unlock(ctx.io);
        return null;
    }
    var buf: [8192]u8 = undefined;
    const n = f.readPositionalAll(ctx.io, &buf, 0) catch return null;
    return state.Record.parse(buf[0..n]);
}

pub fn cmdLease(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (args.len == 0 or args[0].len == 0 or args[0][0] == '-') return usageError("lease needs a name", .{});
    const name = args[0];
    if (!validLeaseName(name)) return usageError("a lease name is letters, digits, '.', '_' and '-', not '{s}'", .{name});
    var o = parseRun(args[1..]) orelse return exit_usage;
    o.lease = name;
    o.request = .{ .min = 1, .max = 1 };
    if (o.run_only) |r| return usageError("{s} is an option of `cpuq run`, not `cpuq lease`", .{r});
    if (o.hold) {
        if (o.cmd.len != 0) return usageError("--hold takes no command", .{});
    } else if (o.cmd.len == 0) return usageError("lease needs a command", .{});
    if (o.host) |h| if (h.len == 0 or h[0] == '-') return usageError("--host needs a host name", .{});

    // `--hold --host` inside a hold of the same lease: say so, hold nothing.
    if (o.hold) if (o.host) |host| if (heldEntry(ctx, name, host)) |entry| {
        ctx.out.print("held {s}@{s} {s}\n", .{ name, host, entry }) catch {};
        ctx.out.flush() catch {};
        untilStdinCloses();
        return 0;
    };

    if (!o.hold and nestedLease(ctx, name, o.host)) {
        const err = std.process.replace(ctx.io, .{ .argv = @ptrCast(o.cmd) });
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        return if (err == error.FileNotFound) exit_notfound else exit_noexec;
    }
    loadConfig(ctx);
    // On another host, that host's config decides.
    if (o.host) |host| return runRemote(ctx, o, host);
    if (o.exclusive and !ctx.cfg.exclusive) o.exclusive = exclusiveOff(o.label);
    const exe: [:0]const u8 = if (o.hold) "" else findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return exit_notfound;
    };
    // Held for someone else: watch for them going, while waiting too.
    if (o.hold) {
        if (ctx.env.get("CPUQ_HOLD_QUIET")) |q| if (std.fmt.parseInt(u32, q, 10)) |secs| {
            runner.hold_quiet_ms = @as(i64, secs) * 1000;
        } else |_| {};
        sys.StdinWatch.start();
    }
    var st = openNamed(ctx, name);
    var named = o;
    named.exclusive = false;
    const lease = waitTurn(ctx, &st, named);
    // `--exclusive`: the machine's cores too, once running work drains, held
    // with the lease, so nothing else runs while it is held: a timing window.
    // The lease comes first, so two holders never wait on each other.
    var cst: state.State = undefined;
    if (o.exclusive) {
        cst = openState(ctx);
        var co = o;
        co.lease = null;
        co.hold = false;
        co.slots = 1;
        co.request = .{ .min = 1, .max = 1 };
        co.first = true;
        runner.words_slot = 1;
        runner.exclusive_cores = .{ .st = &cst, .lease = waitTurn(ctx, &cst, co) };
        runner.words_slot = 0;
    }
    if (o.hold) return holdAdmitted(ctx, &st, o, lease);
    return runAdmitted(ctx, &st, o, exe, lease);
}

/// `exclusive = off`: says that `--exclusive` is not granted here and that
/// the job runs as an ordinary one; returns false, the flag's new value.
pub fn exclusiveOff(label: []const u8) bool {
    std.debug.print("cpuq: {s}{s}--exclusive is off on this machine (exclusive = off in the config): running as an ordinary job, alongside others; time it where exclusive runs are allowed\n", .{
        label, if (label.len != 0) ": " else "",
    });
    return false;
}

/// Gives back the cores held with an `--exclusive` lease, if any, and logs
/// their end as the lease's own: `done` when the lease ended normally.
pub fn releaseExclusiveCores(ctx: *Ctx, ended: ?sys.Waited) void {
    const x = runner.exclusive_cores orelse return;
    runner.exclusive_cores = null;
    release(ctx.io, x.st, x.lease);
    if (ended) |w| logEnded(ctx, x.lease.job, x.lease.record.cores, w) else {
        var extra: EventExtra = .{ .cores = x.lease.record.cores, .exit = 0 };
        noiseInto(&extra);
        logEvent(ctx, x.lease.job, "ended", extra);
    }
}

/// Blocks until stdin reaches its end: the holder of a `--hold` closed it,
/// or died.
pub fn untilStdinCloses() void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n > 0) continue;
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        break;
    }
}

/// The CPUQ_LEASES entry by which this run already holds NAME on HOST
/// (`NAME@HOST=ID:PID`, its cpuq alive), if it does.
fn heldEntry(ctx: *Ctx, name: []const u8, host: []const u8) ?[]const u8 {
    const leases = ctx.env.get("CPUQ_LEASES") orelse return null;
    var entries = std.mem.tokenizeScalar(u8, leases, ' ');
    while (entries.next()) |entry| {
        const key, const val = std.mem.cutScalar(u8, entry, '=') orelse continue;
        const entry_name, const entry_host = std.mem.cutScalar(u8, key, '@') orelse continue;
        if (!std.mem.eql(u8, entry_name, name) or !std.mem.eql(u8, entry_host, host)) continue;
        _, const pid_text = std.mem.cutScalar(u8, val, ':') orelse continue;
        const pid = std.fmt.parseInt(i32, pid_text, 10) catch continue;
        if (sys.processAlive(pid)) return entry;
    }
    return null;
}

/// The far end of `cpuq lease --host`: once admitted, prints `held NAME ID`
/// and holds the lease until stdin closes. If the connection dies instead,
/// this process dies with it and the kernel frees the lease.
fn holdAdmitted(ctx: *Ctx, st: *state.State, o: RunOptions, lease: Lease) u8 {
    ctx.out.print("held {s} {s}\n", .{ o.lease.?, lease.name }) catch {};
    ctx.out.flush() catch {};
    if (runner.exclusive_cores) |x| watchWindow(ctx, x.st, x.lease.name, o.label) else sys.StdinWatch.untilGone(runner.hold_quiet_ms);
    armLastWords(ctx, lease.job, "ended", lease.record.cores, true);
    if (runner.exclusive_cores) |x| {
        runner.words_slot = 1;
        armLastWords(ctx, x.lease.job, "ended", x.lease.record.cores, true);
        runner.words_slot = 0;
    }
    releaseExclusiveCores(ctx, null);
    release(ctx.io, st, lease);
    logEvent(ctx, lease.job, "ended", .{ .cores = lease.record.cores, .exit = 0 });
    return 0;
}
