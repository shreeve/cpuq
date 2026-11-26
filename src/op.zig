//! An operation: `cpuq run [-n M] [-c C] [-x K] [-t T] [-r N] -- CMD`, M tasks of CMD, each
//! run on one CPU of the pool. This process is the operation's one loop: it holds the CPUs (the
//! tasks never do), puts up to K tasks on each, starts the next task the moment a place frees,
//! and gives a CPU back when it has nothing left for it or the line is owed one. It never
//! sleeps while a held CPU has an empty place and a task is waiting.
//!
//!   reap ended tasks -> retry or record them -> place waiting tasks on held CPUs (fullest
//!   first) -> give back empty CPUs -> under the pool's lock: hand free CPUs to the line, take
//!   those promised to this operation, empty one more if this operation is the giver ->
//!   sleep until a task ends, a promise comes, or a timeout is due
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const sys = @import("sys.zig");
const policy = @import("policy.zig");
const pool_mod = @import("pool.zig");
const cpus_mod = @import("cpus.zig");
const main = @import("main.zig");
const repos = @import("repos.zig");

const Pool = pool_mod.Pool;
const Op = pool_mod.Op;
const Ctx = main.Ctx;
const c = std.c;
const is_linux = builtin.os.tag == .linux;

pub const Opts = struct {
    /// -n: how many tasks; 0 means one, with the terminal (`cpuq run -- CMD`).
    tasks: u32 = 0,
    /// -c: the most CPUs it may hold: a count, or a percentage of the pool.
    cpus: u32 = 100,
    cpus_percent: bool = true,
    /// -x: processes per CPU.
    overload: u32 = 1,
    /// -t: each task's time limit, in seconds; null takes the machine's (`timeout`).
    timeout_s: ?u32 = null,
    /// -r: how many times a failed task is tried again.
    retries: u32 = 0,
    urgent: bool = false,
    label: []const u8 = "",
    /// --wait-max: give up (exit 75) when no CPU came in this many seconds.
    wait_max_s: ?u32 = null,
    cmd: []const [:0]const u8 = &.{},
};

const Task = struct {
    index: u32,
    attempt: u32,
    pid: c.pid_t = 0,
    start_ms: i64 = 0,
    slot: usize = 0,
    /// When TERM was sent for its time limit (0: not yet).
    term_ms: i64 = 0,
    timed_out: bool = false,
    out: []const u8 = "",
};

const Slot = struct {
    cpu: u32,
    file: Io.File,
    used: u32 = 0,
    draining: bool = false,
    /// When its newest task started: the slot to empty is the one whose newest is oldest.
    newest_ms: i64 = 0,
};

const Outcome = struct { index: u32, attempt: u32, code: u8, timed_out: bool, out: []const u8 };

// Signals: the handler only records them and writes a byte to the self-pipe, which the loop
// sleeps on with the wake FIFO.
var self_pipe: [2]c.fd_t = .{ -1, -1 };
var got_signal = std.atomic.Value(u32).init(0);

fn onChild(_: c.SIG) callconv(.c) void {
    _ = c.write(self_pipe[1], "c", 1);
}

fn onStop(sig: c.SIG) callconv(.c) void {
    got_signal.store(@intCast(@backingInt(sig)), .release);
    _ = c.write(self_pipe[1], "s", 1);
}

fn installHandlers(forward_terminal: bool) void {
    if (c.pipe(&self_pipe) != 0) main.fail("pipe failed", .{});
    for (self_pipe) |fd| {
        _ = c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    }
    var sa: c.Sigaction = .{ .handler = .{ .handler = onChild }, .mask = undefined, .flags = c.SA.RESTART | c.SA.NOCLDSTOP };
    _ = c.sigemptyset(&sa.mask);
    _ = c.sigaction(.CHLD, &sa, null);
    if (forward_terminal) {
        var st: c.Sigaction = .{ .handler = .{ .handler = onStop }, .mask = undefined, .flags = c.SA.RESTART };
        _ = c.sigemptyset(&st.mask);
        for ([_]c.SIG{ .INT, .TERM, .HUP, .QUIT }) |sig| {
            var old: c.Sigaction = undefined;
            if (c.sigaction(sig, null, &old) == 0 and old.handler.handler == c.SIG.IGN) continue;
            _ = c.sigaction(sig, &st, null);
        }
    }
}

const Run = struct {
    ctx: *Ctx,
    a: std.mem.Allocator,
    o: Opts,
    pool: Pool,
    pool_cpus: []const u32,
    rec: Op,
    file: Io.File = undefined,
    wake_fd: c.fd_t = -1,
    slots: std.ArrayList(Slot) = .empty,
    running: std.ArrayList(Task) = .empty,
    retry: std.ArrayList(Task) = .empty,
    next_index: u32 = 1,
    total: u32,
    single: bool,
    limit: u32,
    timeout_ms: i64,
    outcomes: std.ArrayList(Outcome) = .empty,
    out_dir: []const u8 = "",
    stopping_since: i64 = 0,
    stop_signal: u32 = 0,
    exe: [:0]const u8,
    gave_up: bool = false,
    started_ms: i64,
    first_cpu_ms: i64 = 0,
    last_wait: ?sys.Waited = null,

    fn pending(r: *const Run) u32 {
        if (r.stopping_since != 0) return 0;
        return @as(u32, @intCast(r.retry.items.len)) + (r.total + 1 - r.next_index);
    }

    fn wantMore(r: *const Run) u32 {
        // Places free on CPUs held and kept, against tasks waiting.
        var free_places: u32 = 0;
        for (r.slots.items) |s| if (!s.draining) {
            free_places += r.o.overload - s.used;
        };
        const waiting = r.pending();
        if (waiting <= free_places) return 0;
        const need = std.math.divCeil(u32, waiting - free_places, r.o.overload) catch 0;
        const room = r.limit -| @as(u32, @intCast(r.slots.items.len));
        return @min(need, room);
    }

    fn syncRecord(r: *Run) void {
        var held: std.ArrayList(u32) = .empty;
        var draining: u32 = 0;
        for (r.slots.items) |s| {
            held.append(r.a, s.cpu) catch {};
            if (s.draining) draining += 1;
        }
        r.rec.held = held.items;
        r.rec.draining = draining;
        r.rec.want = r.wantMore();
        r.rec.running = @intCast(r.running.items.len);
        r.pool.write(r.file, r.rec) catch {};
    }
};

/// Runs an operation and returns its exit status (or dies by its command's signal).
pub fn run(ctx: *Ctx, o: Opts) u8 {
    const a = ctx.arena;
    const exe = @import("runopts.zig").findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return main.exit_notfound;
    };
    // Inside a task already: run on that task's CPU, with no line to wait in.
    if (nestedCpu(ctx)) |cpu| return runNested(ctx, o, exe, cpu);

    const dir = main.stateDir(ctx);
    var pool = Pool.open(ctx.io, a, dir) catch |err| main.fail("pool {s}/v2: {t}", .{ dir, err });
    const pool_cpus = cpus_mod.list(ctx.io, a, if (ctx.cfg.cpus.len != 0) ctx.cfg.cpus else null, envBudget(ctx) orelse ctx.cfg.budget);
    const single = o.tasks == 0;
    const total: u32 = if (single) 1 else o.tasks;
    const asked: u32 = if (o.cpus_percent) @max(1, @as(u32, @intCast((@as(u64, pool_cpus.len) * o.cpus) / 100))) else o.cpus;
    const limit = @max(1, @min(@min(asked, @as(u32, @intCast(pool_cpus.len))), std.math.divCeil(u32, total, o.overload) catch 1));
    const timeout_s = o.timeout_s orelse ctx.cfg.timeout_s;
    const timeout_ms: i64 = if (timeout_s == 0) std.math.maxInt(i64) / 2 else @as(i64, timeout_s) * 1000;

    var r: Run = .{
        .ctx = ctx,
        .a = a,
        .o = o,
        .pool = pool,
        .pool_cpus = pool_cpus,
        .total = total,
        .single = single,
        .limit = limit,
        .timeout_ms = timeout_ms,
        .exe = exe,
        .started_ms = sys.monoMs(),
        .rec = .{
            .urgent = o.urgent,
            .pid = sys.getpid(),
            .project = projectOf(ctx, o),
            .label = if (o.label.len != 0) o.label else std.fs.path.basename(o.cmd[0]),
            .weight = weightOf(ctx, projectOf(ctx, o)),
            .overload = o.overload,
            .limit = limit,
            .tasks = total,
            .since = main.nowSeconds(ctx.io),
            .cmd = @import("runopts.zig").joinCommand(ctx, o.cmd),
        },
    };
    _ = &pool;
    if (!single) r.out_dir = outDir(ctx, r.rec.project) catch |err| main.fail("output folder: {t}", .{err});

    installHandlers(!single);
    if (single) sys.installForwarding();

    r.pool.lock();
    r.rec.want = r.wantMore();
    r.file = r.pool.enter(&r.rec) catch |err| main.fail("pool {s}: {t}", .{ r.pool.path, err });
    r.wake_fd = r.pool.openWake(r.rec.ticket) catch |err| main.fail("pool {s}: {t}", .{ r.pool.path, err });
    r.pool.unlock();

    if (!single) std.debug.print("cpuq: {d} tasks, up to {d} CPU{s}, overload {d}, timeout {d}s{s}\n", .{
        total, limit, if (limit == 1) "" else "s", o.overload, timeout_s, if (o.retries > 0) retryNote(a, o.retries) else "",
    });

    loop(&r);

    // Gone from the line, with every CPU handed on.
    r.pool.lock();
    for (r.slots.items) |s| r.pool.release(s.file);
    r.slots.clearRetainingCapacity();
    r.pool.leave(r.file, r.rec);
    settleOthers(&r);
    r.pool.unlock();

    return finish(&r);
}

fn retryNote(a: std.mem.Allocator, n: u32) []const u8 {
    return std.fmt.allocPrint(a, ", up to {d} retr{s}", .{ n, if (n == 1) "y" else "ies" }) catch "";
}

fn loop(r: *Run) void {
    const wait_deadline: ?i64 = if (r.o.wait_max_s) |s| r.started_ms + @as(i64, s) * 1000 else null;
    while (true) {
        reap(r);
        signals(r);
        timeouts(r);
        if (r.running.items.len == 0 and (r.pending() == 0 or r.stopping_since != 0)) break;
        place(r);
        const released = giveBackEmpty(r);
        const took = settle(r, released);
        if (took) continue;
        if (wait_deadline) |d| if (r.slots.items.len == 0 and r.running.items.len == 0 and sys.monoMs() >= d) {
            r.gave_up = true;
            break;
        };
        sleep(r);
    }
}

fn sleep(r: *Run) void {
    var timeout: i64 = 1000;
    const now = sys.monoMs();
    for (r.running.items) |t| {
        const due = if (t.term_ms != 0) t.term_ms + 5000 else t.start_ms + r.timeout_ms;
        timeout = @min(timeout, @max(0, due - now));
    }
    if (r.stopping_since != 0) timeout = @min(timeout, @max(0, r.stopping_since + 5000 - now));
    var fds = [_]c.pollfd{
        .{ .fd = self_pipe[0], .events = c.POLL.IN, .revents = 0 },
        .{ .fd = r.wake_fd, .events = c.POLL.IN, .revents = 0 },
    };
    _ = c.poll(&fds, fds.len, @intCast(timeout));
    var buf: [64]u8 = undefined;
    for (fds) |f| if (f.revents != 0) {
        while (c.read(f.fd, &buf, buf.len) > 0) {}
    };
}

fn signals(r: *Run) void {
    const sig = got_signal.swap(0, .acq_rel);
    if (sig == 0) return;
    if (r.stopping_since == 0) r.stopping_since = sys.monoMs();
    r.stop_signal = sig;
    // Each task leads a group of its own: pass the signal to the whole group.
    for (r.running.items) |t| _ = c.kill(-t.pid, @fromBackingInt(@intCast(sig)));
}

fn timeouts(r: *Run) void {
    const now = sys.monoMs();
    for (r.running.items) |*t| {
        if (t.term_ms == 0 and now - t.start_ms >= r.timeout_ms) {
            t.term_ms = now;
            t.timed_out = true;
            signalTask(r, t.*, .TERM);
        } else if (t.term_ms != 0 and now - t.term_ms >= 5000) {
            signalTask(r, t.*, .KILL);
        }
    }
    if (r.stopping_since != 0 and now - r.stopping_since >= 5000) {
        for (r.running.items) |t| signalTask(r, t, .KILL);
    }
}

fn signalTask(r: *Run, t: Task, sig: c.SIG) void {
    // A single task shares cpuq's group (the terminal's); a task of many leads its own.
    _ = c.kill(if (r.single) t.pid else -t.pid, sig);
}

fn reap(r: *Run) void {
    while (sys.reapAny()) |ended| {
        const pid, const w = ended;
        const i = for (r.running.items, 0..) |t, i| {
            if (t.pid == pid) break i;
        } else continue;
        const t = r.running.swapRemove(i);
        const s = &r.slots.items[t.slot];
        s.used -= 1;
        if (!r.single) _ = c.kill(-t.pid, .KILL); // what the task left behind in its group
        const code: u8 = switch (w.exit) {
            .code => |n| n,
            .signal => |sig| 128 +| @as(u8, @intCast(@backingInt(sig))),
        };
        const failed = code != 0 or t.timed_out;
        const cut_off = r.stopping_since != 0 and !t.timed_out;
        if (failed and !cut_off and t.attempt <= r.o.retries) {
            r.retry.append(r.a, .{ .index = t.index, .attempt = t.attempt + 1 }) catch {};
        } else {
            r.outcomes.append(r.a, .{ .index = t.index, .attempt = t.attempt, .code = if (t.timed_out) 124 else code, .timed_out = t.timed_out, .out = t.out }) catch {};
            if (failed) r.rec.failed += 1 else r.rec.done += 1;
            if (r.single) r.last_wait = w;
        }
        noteGroups(r, t.slot);
    }
}

fn noteGroups(r: *Run, slot: usize) void {
    var groups: std.ArrayList(pool_mod.Group) = .empty;
    for (r.running.items) |t| if (t.slot == slot) {
        groups.append(r.a, .{ .pgid = t.pid, .start = sys.procStart(t.pid) orelse 0 }) catch {};
    };
    Pool.noteGroups(r.slots.items[slot].file, groups.items);
}

/// Puts waiting tasks on held CPUs with room, the fullest first, so CPUs fill to K before
/// another is used and empty ones can go back.
fn place(r: *Run) void {
    while (r.pending() > 0) {
        var best: ?usize = null;
        for (r.slots.items, 0..) |s, i| {
            if (s.draining or s.used >= r.o.overload) continue;
            if (best == null or s.used > r.slots.items[best.?].used) best = i;
        }
        const i = best orelse return;
        const t: Task = if (r.retry.items.len != 0) r.retry.orderedRemove(0) else blk: {
            defer r.next_index += 1;
            break :blk .{ .index = r.next_index, .attempt = 1 };
        };
        start(r, t, i);
    }
}

fn start(r: *Run, t_in: Task, slot: usize) void {
    var t = t_in;
    const ctx = r.ctx;
    const s = &r.slots.items[slot];
    var num: [3][16]u8 = undefined;
    ctx.env.put("CPUQ_TASK", std.fmt.bufPrint(&num[0], "{d}", .{t.index}) catch "1") catch {};
    ctx.env.put("CPUQ_TASKS", std.fmt.bufPrint(&num[1], "{d}", .{r.total}) catch "1") catch {};
    ctx.env.put("CPUQ_CPU", std.fmt.bufPrint(&num[2], "{d}", .{s.cpu}) catch "0") catch {};
    var att: [2][16]u8 = undefined;
    ctx.env.put("CPUQ_ATTEMPT", std.fmt.bufPrint(&att[0], "{d}", .{t.attempt}) catch "1") catch {};
    ctx.env.put("CPUQ_ATTEMPTS", std.fmt.bufPrint(&att[1], "{d}", .{r.o.retries + 1}) catch "1") catch {};
    var opn: [24]u8 = undefined;
    ctx.env.put("CPUQ_OP", std.fmt.bufPrint(&opn, "{d}", .{r.rec.ticket}) catch "") catch {};
    const envp = ctx.env.createPosixBlock(r.a, .{}) catch main.fail("out of memory", .{});
    const argv = r.a.allocSentinel(?[*:0]const u8, r.o.cmd.len, null) catch main.fail("out of memory", .{});
    for (r.o.cmd, 0..) |arg, k| argv[k] = arg.ptr;

    var dups: std.ArrayList([2]c.fd_t) = .empty;
    var out_fd: c.fd_t = -1;
    if (!r.single) {
        t.out = if (t.attempt == 1)
            std.fmt.allocPrint(r.a, "{s}/{d}", .{ r.out_dir, t.index }) catch ""
        else
            std.fmt.allocPrint(r.a, "{s}/{d}.{d}", .{ r.out_dir, t.index, t.attempt }) catch "";
        const path = r.a.dupeSentinel(u8, t.out, 0) catch "";
        out_fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
        const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (null_fd >= 0) dups.append(r.a, .{ null_fd, 0 }) catch {};
        if (out_fd >= 0) {
            dups.append(r.a, .{ out_fd, 1 }) catch {};
            dups.append(r.a, .{ out_fd, 2 }) catch {};
        }
    }
    const pin: []const u32 = if (is_linux) &.{s.cpu} else &.{};
    const spawned = sys.spawn(r.exe, argv.ptr, @ptrCast(envp.slice.ptr), .unchanged, .{
        .cpus = pin,
        .dups = dups.items,
        .group = !r.single,
        .pdeath = true,
    });
    for (dups.items) |d| if (d[1] == 0 or d[1] == 1) {
        _ = c.close(d[0]);
    };
    const pid = spawned catch |err| {
        std.debug.print("cpuq: {s}: {t}\n", .{ r.o.cmd[0], err });
        r.outcomes.append(r.a, .{ .index = t.index, .attempt = t.attempt, .code = if (err == error.FileNotFound) main.exit_notfound else main.exit_noexec, .timed_out = false, .out = t.out }) catch {};
        r.rec.failed += 1;
        return;
    };
    if (r.single) sys.setChild(pid);
    t.pid = pid;
    t.start_ms = sys.monoMs();
    t.slot = slot;
    s.used += 1;
    s.newest_ms = t.start_ms;
    if (r.first_cpu_ms == 0) r.first_cpu_ms = t.start_ms;
    r.running.append(r.a, t) catch {};
    noteGroups(r, slot);
}

/// Gives back each held CPU that is empty and has nothing coming: no task waits, or it is
/// being emptied for the line. Returns whether any went.
fn giveBackEmpty(r: *Run) bool {
    var any = false;
    var i: usize = 0;
    while (i < r.slots.items.len) {
        const s = r.slots.items[i];
        if (s.used == 0 and (s.draining or r.pending() == 0)) {
            if (!any) r.pool.lock();
            any = true;
            r.pool.release(s.file);
            _ = r.slots.orderedRemove(i);
            // Slots after it moved down one: fix the tasks' slot numbers.
            for (r.running.items) |*t| if (t.slot > i) {
                t.slot -= 1;
            };
            continue;
        }
        i += 1;
    }
    if (any) {
        // Given up for the line: take a new turn behind the others.
        r.pool.renew(r.file, &r.rec) catch {};
        r.syncRecord();
        settleOthers(r);
        r.pool.unlock();
    }
    return any;
}

/// Hands free CPUs to the line and wakes those promised one. Under the lock; leaves this
/// operation's own promises for `settle` to take.
fn settleOthers(r: *Run) void {
    const a = r.a;
    const ops = r.pool.scan(a);
    const given = r.pool.promises(a, ops, r.pool_cpus);
    const free = freeCpus(r, ops, given);
    for (pool_mod.handOut(a, ops, given, free)) |p| {
        r.pool.promise(p.cpu, p.ticket);
        if (p.ticket != r.rec.ticket) r.pool.wakeOp(p.ticket);
    }
}

/// The pool's CPUs nobody holds or is promised, if the gates are open and nobody but a drain
/// waits for the machine.
fn freeCpus(r: *Run, ops: []const Op, given: []const pool_mod.Promise) []const u32 {
    const why = gate(r);
    r.rec.why = why;
    if (why.len != 0) return &.{};
    var out: std.ArrayList(u32) = .empty;
    outer: for (r.pool_cpus) |cpu| {
        for (ops) |o| if (std.mem.findScalar(u32, o.held, cpu) != null) continue :outer;
        for (given) |g| if (g.cpu == cpu) continue :outer;
        for (r.slots.items) |s| if (s.cpu == cpu) continue :outer;
        if (!r.pool.isFree(cpu)) continue;
        out.append(r.a, cpu) catch break;
    }
    return out.items;
}

/// Why no CPU may be handed out now, or "" when one may: the machine's memory and disk gates.
fn gate(r: *Run) []const u8 {
    const m = main.machine(r.ctx);
    return switch (policy.gate(r.ctx.cfg, m, 0, null, 0)) {
        .open => "",
        .pressure => "memory pressure",
        .low_memory => "low memory",
        .low_disk => |d| std.fmt.allocPrint(r.a, "low disk on {s}", .{d.path}) catch "low disk",
        .load, .spacing => "load",
    };
}

/// Under the lock: hands out what is free, takes what is promised to this operation, and
/// empties one CPU if this operation is the line's giver. Returns whether it took any.
fn settle(r: *Run, released: bool) bool {
    _ = released;
    const a = r.a;
    const want = r.wantMore();
    // Nothing to ask for and nobody to give to: skip the lock, unless the line may want a CPU
    // from this operation (it checks at each task's end, when a place frees).
    r.pool.lock();
    defer r.pool.unlock();
    r.syncRecord();
    var ops = r.pool.scan(a);
    var given = r.pool.promises(a, ops, r.pool_cpus);
    const free = freeCpus(r, ops, given);
    var fresh: std.ArrayList(pool_mod.Promise) = .empty;
    for (pool_mod.handOut(a, ops, given, free)) |p| {
        r.pool.promise(p.cpu, p.ticket);
        fresh.append(a, p) catch {};
        if (p.ticket != r.rec.ticket) r.pool.wakeOp(p.ticket);
    }
    var took = false;
    var taken: u32 = 0;
    for ([_][]const pool_mod.Promise{ given, fresh.items }) |list| for (list) |p| {
        if (p.ticket != r.rec.ticket) continue;
        if (taken >= want or r.slots.items.len >= r.limit) {
            // No longer needed: hand it on.
            r.pool.dropPromise(p.cpu);
            continue;
        }
        const f = r.pool.take(a, p.cpu) orelse {
            r.pool.dropPromise(p.cpu);
            continue;
        };
        r.pool.dropPromise(p.cpu);
        r.slots.append(a, .{ .cpu = p.cpu, .file = f }) catch {
            r.pool.release(f);
            continue;
        };
        took = true;
        taken += 1;
    };
    if (took) {
        r.syncRecord();
        return true;
    }
    // Owed to the line: empty one CPU, if this operation is the giver.
    ops = r.pool.scan(a);
    given = r.pool.promises(a, ops, r.pool_cpus);
    if (pool_mod.giver(a, ops, given)) |t| if (t == r.rec.ticket) drainOne(r);
    if (r.pool.draining()) for (r.slots.items) |*s| {
        s.draining = true;
    };
    r.syncRecord();
    return false;
}

/// Marks one held CPU to be emptied: an empty one if there is one, else the one whose newest
/// task is oldest, so it frees soonest.
fn drainOne(r: *Run) void {
    var best: ?usize = null;
    for (r.slots.items, 0..) |s, i| {
        if (s.draining) continue;
        if (best == null) {
            best = i;
            continue;
        }
        const b = r.slots.items[best.?];
        if (s.used < b.used or (s.used == b.used and s.newest_ms < b.newest_ms)) best = i;
    }
    if (best) |i| r.slots.items[i].draining = true;
}

fn finish(r: *Run) u8 {
    if (r.gave_up) {
        std.debug.print("cpuq: no CPU within --wait-max; nothing ran\n", .{});
        return 75;
    }
    if (r.single) {
        if (r.outcomes.items.len == 0) return 125;
        const out = r.outcomes.items[r.outcomes.items.len - 1];
        if (out.timed_out) {
            std.debug.print("cpuq: stopped at its time limit\n", .{});
            return 124;
        }
        if (r.last_wait) |w| switch (w.exit) {
            .signal => |sig| sys.dieBySignal(sig),
            .code => |code| return code,
        };
        return out.code;
    }
    return summary(r);
}

fn summary(r: *Run) u8 {
    var failed: std.ArrayList(Outcome) = .empty;
    var timed: u32 = 0;
    var retried: u32 = 0;
    for (r.outcomes.items) |o| {
        if (o.code != 0) failed.append(r.a, o) catch {};
        if (o.timed_out) timed += 1;
        if (o.attempt > 1) retried += 1;
    }
    const secs = @as(f64, @floatFromInt(sys.monoMs() - r.started_ms)) / 1000;
    const not_run = r.total -| @as(u32, @intCast(r.outcomes.items.len));
    std.debug.print("cpuq: {d} of {d} tasks passed", .{ r.outcomes.items.len - failed.items.len, r.total });
    if (failed.items.len != 0) std.debug.print(", {d} failed", .{failed.items.len});
    if (timed != 0) std.debug.print(" ({d} at the time limit)", .{timed});
    if (retried != 0) std.debug.print(", {d} passed or ended on a retry", .{retried});
    if (not_run != 0) std.debug.print(", {d} not run", .{not_run});
    std.debug.print(", in {d:.1}s; output in {s}\n", .{ secs, r.out_dir });
    for (failed.items, 0..) |o, i| {
        if (i == 5) {
            std.debug.print("cpuq: ... and {d} more failed\n", .{failed.items.len - 5});
            break;
        }
        std.debug.print("cpuq: task {d} (attempt {d}) exited {d}; the end of {s}:\n", .{ o.index, o.attempt, o.code, o.out });
        printTail(r, o.out, 5);
    }
    if (r.stop_signal != 0) sys.dieBySignal(@fromBackingInt(@intCast(r.stop_signal)));
    return if (failed.items.len != 0 or not_run != 0) 1 else 0;
}

fn printTail(r: *Run, path: []const u8, lines: usize) void {
    const text = Io.Dir.cwd().readFileAlloc(r.ctx.io, path, r.a, .limited(1 << 20)) catch return;
    const body = std.mem.trimEnd(u8, text, "\n");
    var from: usize = body.len;
    var n: usize = 0;
    while (from > 0 and n < lines) {
        from -= 1;
        if (body[from] == '\n') n += 1;
    }
    if (n == lines) from += 1;
    var it = std.mem.splitScalar(u8, body[from..], '\n');
    while (it.next()) |l| std.debug.print("    {s}\n", .{l});
}

/// Where a run of many tasks keeps each task's output: ~/.local/state/cpuq/runs/PROJECT/STAMP.
fn outDir(ctx: *Ctx, project: []const u8) ![]const u8 {
    const home = ctx.env.get("HOME") orelse return error.NoHome;
    const now = main.nowSeconds(ctx.io);
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/.local/state/cpuq/runs/{s}/{d}-{d}", .{ home, if (project.len == 0) "-" else project, now, sys.getpid() });
    try Io.Dir.cwd().createDirPath(ctx.io, path);
    return path;
}

/// The project an operation counts for: the repo it runs in (each worktree counts as its repo),
/// else its label's project, else "-".
fn projectOf(ctx: *Ctx, o: Opts) []const u8 {
    const cwd = std.process.currentPathAlloc(ctx.io, ctx.arena) catch "";
    if (repos.repoAt(ctx, cwd)) |name| return name;
    if (o.label.len != 0) return std.mem.sliceTo(o.label, ':');
    return "-";
}

fn weightOf(ctx: *Ctx, project: []const u8) u32 {
    return policy.weightFor(ctx.cfg, project);
}

fn envBudget(ctx: *Ctx) ?u32 {
    const s = ctx.env.get("CPUQ_BUDGET") orelse return null;
    return policy.parseCount(s) orelse main.fail("CPUQ_BUDGET must be a whole number of CPUs, at least 1, not '{s}'", .{s});
}

// --- Nested runs ---------------------------------------------------------------------------

/// The CPU of the task this process runs in, when it is one: CPUQ_CPU with CPUQ_OP naming a
/// live operation, or else an ancestor process that is a live operation's cpuq (which no
/// `env -i` can hide). Null outside every task.
fn nestedCpu(ctx: *Ctx) ?u32 {
    const a = ctx.arena;
    var pool = Pool.open(ctx.io, a, main.stateDir(ctx)) catch return null;
    if (ctx.env.get("CPUQ_CPU")) |cpu_text| if (ctx.env.get("CPUQ_OP")) |op_text| {
        const cpu = std.fmt.parseInt(u32, cpu_text, 10) catch return null;
        const ticket = std.fmt.parseInt(u64, op_text, 10) catch return null;
        pool.lock();
        defer pool.unlock();
        for (pool.scan(a)) |o| if (o.ticket == ticket) return cpu;
        return null;
    };
    // No variables: look for an operation's cpuq among this process's ancestors.
    pool.lock();
    const ops = pool.scan(a);
    pool.unlock();
    if (ops.len == 0) return null;
    var pid = c.getppid();
    var hops: u32 = 0;
    while (pid > 1 and hops < 64) : (hops += 1) {
        for (ops) |o| if (o.pid == pid) return if (o.held.len != 0) o.held[0] else 0;
        pid = sys.parentOf(pid) orelse return null;
    }
    return null;
}

/// A run inside a task: on that task's CPU, with no line. One task runs in this process's
/// place; many run K at a time.
fn runNested(ctx: *Ctx, o: Opts, exe: [:0]const u8, cpu: u32) u8 {
    if (o.tasks == 0) {
        // Become the command: nothing to hold or watch.
        const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch main.fail("out of memory", .{});
        const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch main.fail("out of memory", .{});
        for (o.cmd, 0..) |arg, k| argv[k] = arg.ptr;
        _ = c.execve(exe, argv.ptr, @ptrCast(envp.slice.ptr));
        std.debug.print("cpuq: {s}: exec failed\n", .{o.cmd[0]});
        return main.exit_noexec;
    }
    _ = cpu;
    var failed: u32 = 0;
    var i: u32 = 1;
    var live: u32 = 0;
    while (i <= o.tasks or live != 0) {
        while (i <= o.tasks and live < o.overload) : (i += 1) {
            var num: [16]u8 = undefined;
            ctx.env.put("CPUQ_TASK", std.fmt.bufPrint(&num, "{d}", .{i}) catch "1") catch {};
            var tot: [16]u8 = undefined;
            ctx.env.put("CPUQ_TASKS", std.fmt.bufPrint(&tot, "{d}", .{o.tasks}) catch "1") catch {};
            const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch main.fail("out of memory", .{});
            const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch main.fail("out of memory", .{});
            for (o.cmd, 0..) |arg, k| argv[k] = arg.ptr;
            _ = sys.spawn(exe, argv.ptr, @ptrCast(envp.slice.ptr), .unchanged, .{}) catch {
                failed += 1;
                continue;
            };
            live += 1;
        }
        if (live == 0) break;
        var status: c_int = 0;
        const pid = c.waitpid(-1, &status, 0);
        if (pid <= 0) break;
        live -= 1;
        const st: u32 = @bitCast(status);
        if (!(c.W.IFEXITED(st) and c.W.EXITSTATUS(st) == 0)) failed += 1;
    }
    return if (failed != 0) 1 else 0;
}
