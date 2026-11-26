//! `cpuq lease NAME`: named leases, a pool of `--slots` places that commands wait their turn for,
//! first come first served, with no machine gates; and holds for another machine (`--hold`).
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");
const joblog = @import("joblog.zig");
const runner = @import("runner.zig");
const remotes = @import("remotes.zig");
const texts = @import("texts.zig");

const exit_usage = main.exit_usage;
const exit_timeout = main.exit_timeout;
const exit_noexec = main.exit_noexec;
const exit_notfound = main.exit_notfound;
const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const loadConfig = main.loadConfig;
const stateDir = main.stateDir;
const findExecutable = runopts.findExecutable;
const joinCommand = runopts.joinCommand;
const JobLog = joblog.JobLog;
const logEvent = joblog.logEvent;
const logAndArm = joblog.logAndArm;
const armLastWords = joblog.armLastWords;
const logEnded = joblog.logEnded;

/// `cpuq lease`'s command line.
pub const LeaseOptions = struct {
    name: []const u8,
    /// `--slots N`: how many may hold the lease at once.
    slots: u32 = 1,
    label: []const u8 = "",
    /// `--wait-max S`: give up (exit 75) when no slot comes within S seconds; 0: now or not.
    wait_max: ?u32 = null,
    /// `--host HOST`: hold the lease on HOST's cpuq over ssh.
    host: ?[]const u8 = null,
    /// `--hold`: once admitted, say so and hold until stdin closes (the other end of `--host`).
    hold: bool = false,
    cmd: []const [:0]const u8 = &.{},
};

/// A held slot of a named lease.
pub const Lease = struct {
    record: state.Record,
    name: []const u8,
    file: Io.File,
    slot: Io.File,
    job: JobLog,
};

/// How long a hold whose holder sends heartbeats waits without one before
/// it takes them for gone: six missed beats (CPUQ_HOLD_QUIET, in seconds).
var hold_quiet_ms: i64 = 60_000;

/// A lease name: letters, digits, `.`, `_` and `-`.
pub fn validLeaseName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.' or name[0] == '-') return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// The state of the named lease NAME, in the state directory.
fn openNamed(ctx: *Ctx, name: []const u8) state.State {
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

/// Parses `cpuq lease NAME`'s options; null after saying what is wrong.
fn parseLease(name: []const u8, args: []const [:0]const u8) ?LeaseOptions {
    var o: LeaseOptions = .{ .name = name };
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            o.cmd = args[i + 1 ..];
            return o;
        }
        if (a.len == 0 or a[0] != '-') {
            o.cmd = args[i..];
            return o;
        }
        const opt, const inline_value = std.mem.cutScalar(u8, a, '=') orelse .{ a, null };
        if (std.mem.eql(u8, opt, "--hold")) {
            if (inline_value != null) {
                _ = usageError("--hold takes no value", .{});
                return null;
            }
            o.hold = true;
            continue;
        }
        const known = for ([_][]const u8{ "--slots", "--label", "--wait-max", "--host" }) |k| {
            if (std.mem.eql(u8, opt, k)) break true;
        } else false;
        if (!known) {
            _ = usageError("unknown lease option '{s}' (lease takes --slots, --label, --wait-max, --host and --hold)", .{a});
            return null;
        }
        const value = inline_value orelse blk: {
            i += 1;
            if (i >= args.len) {
                _ = usageError("{s} needs a value", .{opt});
                return null;
            }
            break :blk args[i];
        };
        if (std.mem.eql(u8, opt, "--slots")) {
            o.slots = policy.parseCount(value) orelse {
                _ = usageError("--slots needs a whole number, at least 1, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, opt, "--label")) {
            if (!policy.validLabel(value)) {
                _ = usageError("--label is project:task, of lowercase letters, digits, '.', '_' and '-', not '{s}'", .{value});
                return null;
            }
            o.label = value;
        } else if (std.mem.eql(u8, opt, "--wait-max")) {
            o.wait_max = policy.parseWhole(u32, value) orelse {
                _ = usageError("--wait-max needs whole seconds, not '{s}'", .{value});
                return null;
            };
        } else {
            if (value.len == 0 or value[0] == '-') {
                _ = usageError("--host needs a host name", .{});
                return null;
            }
            o.host = value;
        }
    }
    return o;
}

pub fn cmdLease(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (args.len == 0 or args[0].len == 0 or args[0][0] == '-') return usageError("lease needs a name", .{});
    const name = args[0];
    if (!validLeaseName(name)) return usageError("a lease name is letters, digits, '.', '_' and '-', not '{s}'", .{name});
    if (runner.removedOption(args[1..], true)) |msg| {
        std.debug.print("cpuq: {s}\n", .{msg});
        return exit_usage;
    }
    const o = parseLease(name, args[1..]) orelse return exit_usage;
    if (o.hold) {
        if (o.cmd.len != 0) return usageError("--hold takes no command", .{});
    } else if (o.cmd.len == 0) return usageError("lease needs a command", .{});

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
    // On another host, that host's cpuq holds it.
    if (o.host) |host| return remotes.runRemote(ctx, o, host);
    const exe: [:0]const u8 = if (o.hold) "" else findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return exit_notfound;
    };
    // Held for someone else: watch for them going, while waiting too.
    if (o.hold) {
        if (ctx.env.get("CPUQ_HOLD_QUIET")) |q| if (std.fmt.parseInt(u32, q, 10)) |secs| {
            hold_quiet_ms = @as(i64, secs) * 1000;
        } else |_| {};
        sys.StdinWatch.start();
    }
    var st = openNamed(ctx, name);
    const lease = waitTurn(ctx, &st, o);
    if (o.hold) return holdAdmitted(ctx, &st, o, lease);
    return runLeased(ctx, &st, o, exe, lease);
}

/// The history fields of a lease of `o`.
pub fn leaseJob(ctx: *Ctx, o: LeaseOptions) JobLog {
    return joblog.newJobLog(ctx, .{ .pool = o.name, .host = o.host, .label = o.label, .cmd = joinCommand(ctx, o.cmd) });
}

fn lockOrFail(st: *state.State) void {
    st.lock() catch |err| fail("lease lock: {t}", .{err});
}

/// Queues this run and returns once it holds one of the lease's slots. A queued run prints its
/// place once a minute, so a long wait never looks like a hang.
fn waitTurn(ctx: *Ctx, st: *state.State, o: LeaseOptions) Lease {
    const io = ctx.io;
    const start = nowSeconds(io);
    // In history, and its last words armed, before its ticket shows it
    // waiting: killed as soon as it is seen in the queue, it gave up.
    const job = leaseJob(ctx, o);
    logAndArm(ctx, job, "queued", .{}, "gave_up", null);

    lockOrFail(st);
    const rec: state.Record = .{
        .ticket = st.nextTicket() catch |err| fail("ticket: {t}", .{err}),
        .pid = sys.getpid(),
        .since = start,
        .label = o.label,
        .cmd = joinCommand(ctx, o.cmd),
    };
    var name_buf: [32]u8 = undefined;
    const ticket_name = state.ticketName(&name_buf, rec.ticket);
    const ticket = st.createTicket(rec, ticket_name) catch |err| fail("ticket: {t}", .{err});
    st.unlock();

    var next_note = start + 60;
    while (true) {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        lockOrFail(st);
        const now = nowSeconds(io);
        const queue = state.scanQueue(st, a, ticket_name, rec) catch |err| fail("queue: {t}", .{err});
        const pos = for (queue, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, ticket_name)) break i;
        } else fail("ticket {s} vanished from the queue", .{ticket_name});

        // Waiting to hold a lease for someone who has gone (their
        // connection dropped): give up rather than hold it for nobody.
        if (sys.StdinWatch.gone(hold_quiet_ms)) {
            std.debug.print("cpuq: whoever this hold was for has gone; giving up\n", .{});
            giveUp(ctx, st, ticket_name, now - start, job);
        }
        if (pos == 0) if (state.takeSlot(st, o.slots) catch |err| fail("slots: {t}", .{err})) |slot| {
            return admitted(ctx, st, rec, slot, ticket, ticket_name, job);
        };
        // Out of time: give up, but only after trying once, so --wait-max 0 takes a free slot
        // now and otherwise gives up.
        if (o.wait_max) |mw| if (now - start >= mw) giveUp(ctx, st, ticket_name, now - start, job);
        if (now >= next_note) {
            note(st, a, o.name, now - start, pos);
            next_note = now + 60;
        }
        var wake_ms: i64 = if (pos == 0) 250 else 2000;
        if (o.wait_max) |mw| wake_ms = @max(@min(wake_ms, (start + mw - now) * 1000), 100);
        const pred = if (pos > 0) st.queue.openFile(io, queue[pos - 1].name, .{}) catch null else null;
        st.unlock();
        if (pred) |f| {
            waitOn(io, f, wake_ms);
            f.close(io);
        } else io.sleep(.fromMilliseconds(wake_ms), .awake) catch {};
    }
}

/// Takes the slot: writes the lease, leaves the queue, and logs the start.
/// Call with the lock held; returns with it released.
fn admitted(ctx: *Ctx, st: *state.State, rec_in: state.Record, slot: Io.File, ticket: Io.File, ticket_name: []const u8, job: JobLog) Lease {
    const io = ctx.io;
    var rec = rec_in;
    rec.since = nowSeconds(io);
    // The lease is named by the ticket number; should a live holder have that
    // name anyway, take a fresh number rather than wait.
    var lease_name: []const u8 = undefined;
    const file = for (0..3) |_| {
        lease_name = state.ticketName(ctx.arena.alloc(u8, 16) catch fail("out of memory", .{}), rec.ticket);
        break st.createLease(rec, lease_name) catch |err| switch (err) {
            error.WouldBlock => {
                rec.ticket = st.nextTicket() catch |e| fail("ticket: {t}", .{e});
                continue;
            },
            else => fail("lease: {t}", .{err}),
        };
    } else fail("lease: no free lease name", .{});
    st.queue.deleteFile(io, ticket_name) catch {};
    ticket.close(io);
    st.unlock();
    logAndArm(ctx, job, "started", .{ .cores = 1 }, "ended", 1);
    return .{ .record = rec, .name = lease_name, .file = file, .slot = slot, .job = job };
}

/// Leaves the queue and exits 75. Call with the lock held.
fn giveUp(ctx: *Ctx, st: *state.State, ticket_name: []const u8, waited: i64, job: JobLog) noreturn {
    st.queue.deleteFile(ctx.io, ticket_name) catch {};
    st.unlock();
    logEvent(ctx, job, "gave_up", .{});
    std.debug.print("cpuq: gave up after waiting {d}s\n", .{waited});
    std.process.exit(exit_timeout);
}

/// The once-a-minute line a queued lease prints. Call with the lock held.
fn note(st: *state.State, a: std.mem.Allocator, name: []const u8, waited: i64, pos: usize) void {
    var w_buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&w_buf);
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    w.print("cpuq: waiting {s} for lease {s}: {s} in line", .{ texts.age(&b1, waited), name, texts.ordinal(&b2, pos + 1) }) catch {};
    for (state.scanLeases(st, a) catch &.{}, 0..) |l, i| {
        w.print("{s} {s} (pid {d})", .{
            if (i == 0) ", held by" else ",",
            if (l.record.label.len != 0) l.record.label else std.mem.sliceTo(l.record.cmd, ' '),
            l.record.pid,
        }) catch break;
    }
    std.debug.print("{s}\n", .{w.buffered()});
}

fn watch(io: Io, f: Io.File, sem: *Io.Semaphore) Io.Cancelable!void {
    f.lock(io, .shared) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
    f.unlock(io);
    sem.post(io);
}

/// Blocks until `f`'s exclusive holder lets go, or `ms` pass.
fn waitOn(io: Io, f: Io.File, ms: i64) void {
    var sem: Io.Semaphore = .{};
    // The worker thread this may start never takes cpuq's signals.
    const before = sys.holdHandled();
    const started = io.concurrent(watch, .{ io, f, &sem });
    sys.restoreSignals(before);
    var fut = started catch {
        io.sleep(.fromMilliseconds(@min(ms, 1000)), .awake) catch {};
        return;
    };
    sem.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }) catch {};
    fut.cancel(io) catch {};
}

/// Gives a lease back. LOCK_UN releases each lock for every holder of the open file, so a
/// descendant that kept a descriptor (a build server, a nohup'd helper) does not keep the slot.
/// It happens under the lock, so no waiter sees a lease half given back.
fn release(io: Io, st: *state.State, lease: Lease) void {
    lockOrFail(st);
    lease.slot.unlock(io);
    lease.slot.close(io);
    lease.file.unlock(io);
    lease.file.close(io);
    st.leases.deleteFile(io, lease.name) catch {};
    st.unlock();
}

/// Runs the command holding the lease, and gives it back when the command ends.
fn runLeased(ctx: *Ctx, st: *state.State, o: LeaseOptions, exe: [:0]const u8, lease: Lease) u8 {
    // The command and its descendants share the slot's and the lease's locks, so a SIGKILLed
    // cpuq does not hand the slot on while the command runs.
    sys.inherit(lease.slot.handle);
    sys.inherit(lease.file.handle);
    addLeaseEnv(ctx, o.name, lease.name);
    const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch fail("out of memory", .{});
    const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch fail("out of memory", .{});
    for (o.cmd, 0..) |a, i| argv[i] = a.ptr;
    sys.installForwarding();
    const waited: sys.Waited = if (sys.spawn(exe, argv.ptr, @ptrCast(envp.slice.ptr), .unchanged, .{})) |pid| blk: {
        sys.setChild(pid);
        break :blk sys.waitChild(pid);
    } else |err| blk: {
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        break :blk .{ .exit = .{ .code = if (err == error.FileNotFound) exit_notfound else exit_noexec } };
    };
    release(ctx.io, st, lease);
    logEnded(ctx, lease.job, 1, waited);
    ctx.out.flush() catch {};
    switch (waited.exit) {
        .code => |c| return c,
        .signal => |sig| sys.dieBySignal(sig),
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
fn holdAdmitted(ctx: *Ctx, st: *state.State, o: LeaseOptions, lease: Lease) u8 {
    ctx.out.print("held {s} {s}\n", .{ o.name, lease.name }) catch {};
    ctx.out.flush() catch {};
    sys.StdinWatch.untilGone(hold_quiet_ms);
    armLastWords(ctx, lease.job, "ended", 1, true);
    release(ctx.io, st, lease);
    logEvent(ctx, lease.job, "ended", .{ .cores = 1, .exit = 0 });
    return 0;
}
