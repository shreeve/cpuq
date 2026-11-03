//! `cpuq agent`: keeps this machine at its target load, shared among its jobs by weight.
//!
//! It listens on host.sock in cpuq's state dir. Each job driver (`cpuq jobs run`) connects and
//! says `hello PATH pid P`, then `state STATE WEIGHT WORKERS GAP TODO LIVE DONE FAIL AVG_MS WSRC
//! GSRC` on each change, then `bye`; the agent answers with `workers N` and `gap MS`. It keeps no
//! state file: what it knows comes from the drivers connected now.
//!
//! Each second it measures the machine's busy CPU, its run queue and each job's CPU (its driver's
//! process tree), then:
//!   cost     a job's CPU per busy worker, an EWMA over about 15 s (1.0 to start), not updated
//!            while the machine is over target, where a starved job looks cheap;
//!   budget   the target less what runs outside the jobs, cut fast while the run queue stays
//!            over target or memory is short, grown at most 1.5 times a second;
//!   shares   the budget water-filled by weight: each job gets min(what it can use, λ × weight),
//!            what it can use being its cost × its todo and live tasks; a job whose workers a user
//!            set keeps them, and its cost comes off the budget first;
//!   knobs    workers = its share ÷ its cost, rounded up (at least 1 while it has work, at most
//!            twice the last count), and a gap after each task for the fraction rounded up.
//! A new count is pushed when it differs by 10% or more, a gap when it moves by 10% or more.
//!
//! `cpuq attach` joins its stdin and stdout to host.sock: `jobs` lists the jobs (`job …` lines,
//! then `end`), and `to PATH COMMAND` relays a driver command (`set workers 4`, `pause`, `resume`,
//! `stop`), answered `ok` or `error …`.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const Io = std.Io;
const sys = @import("sys.zig");
const lines = @import("lines.zig");
const jobs = @import("jobs.zig");
const main = @import("main.zig");
const admission = @import("admission.zig");
const Allocator = std.mem.Allocator;

const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;

/// Seconds a cost's EWMA spans.
const cost_span_s = 15.0;
/// A job's cost before it has been measured: one CPU per worker.
const cost_start = 1.0;
/// The most workers the agent gives a job.
const workers_max = 4096;

// --- The formula -----------------------------------------------------------------------------

/// The budget: CPUs the jobs may use now.
pub const Budget = struct {
    value: ?f64 = null,
    /// Ticks in a row the run queue has been over target.
    over: u32 = 0,

    /// The budget for this tick: the target less outside load, cut by target ÷ run queue once the
    /// run queue has been over target two ticks running, or by a quarter while memory is short;
    /// otherwise grown at most 1.5 times (by at least one CPU).
    pub fn step(b: *Budget, target: f64, outside: f64, runq: f64, memory_short: bool) f64 {
        const room = @max(target - outside, 0);
        b.over = if (runq > target) b.over + 1 else 0;
        const was = b.value orelse room;
        const next = if (memory_short)
            was * 0.75
        else if (b.over >= 2)
            was * target / runq
        else
            @max(was * 1.5, was + 1);
        b.value = @min(room, next);
        return b.value.?;
    }
};

/// One job as the formula sees it.
pub const Job = struct {
    weight: u32 = 1,
    todo: u64 = 0,
    live: u64 = 0,
    workers: u32 = 1,
    /// A user set its workers: they hold.
    pinned: bool = false,
    /// CPUs per busy worker.
    cost: f64 = cost_start,
    /// Its tasks' usual time, for the gap; 0 when unknown.
    avg_ms: u64 = 0,
};

/// What the formula gives a job.
pub const Knobs = struct {
    /// CPUs it may use.
    share: f64 = 0,
    workers: u32 = 1,
    gap_ms: u32 = 0,
};

/// Water-fills `budget` among `js` by weight; `out` gets each job's share and knobs.
pub fn shares(budget: f64, js: []const Job, out: []Knobs) void {
    var left = budget;
    for (js, out) |j, *o| if (j.pinned) {
        o.* = .{ .share = j.cost * @as(f64, @floatFromInt(@min(j.workers, j.todo + j.live))), .workers = j.workers };
        left -= o.share;
    };
    left = @max(left, 0);
    // Each job's demand: what it can use. λ rises until the budget is spent or every demand met.
    var lambda: f64 = 0;
    var sum_w: f64 = 0;
    var fixed: f64 = 0;
    var done: [256]bool = @splat(false);
    for (js, 0..) |j, i| {
        if (j.pinned or i >= done.len) continue;
        if (demand(j) == 0) done[i] = true else sum_w += @floatFromInt(j.weight);
    }
    while (sum_w > 0) {
        lambda = (left - fixed) / sum_w;
        var settled = false;
        for (js, 0..) |j, i| {
            if (j.pinned or i >= done.len or done[i]) continue;
            const d = demand(j);
            if (d <= lambda * @as(f64, @floatFromInt(j.weight))) {
                done[i] = true;
                fixed += d;
                sum_w -= @floatFromInt(j.weight);
                settled = true;
            }
        }
        if (!settled) break;
    }
    for (js, out, 0..) |j, *o, i| {
        if (j.pinned) continue;
        const s = if (i < done.len and done[i]) demand(j) else @max(lambda, 0) * @as(f64, @floatFromInt(j.weight));
        o.* = knobs(j, s);
    }
}

fn demand(j: Job) f64 {
    return j.cost * @as(f64, @floatFromInt(@min(j.todo + j.live, workers_max)));
}

/// Workers for a share, rounded up, and the gap that takes the rounding back.
fn knobs(j: Job, s: f64) Knobs {
    const x = s / @max(j.cost, 0.01);
    var n: u32 = @intFromFloat(@min(@ceil(x - 1e-9), workers_max));
    n = @max(n, 1);
    n = @min(n, @max(j.workers, 1) * 2);
    const duty = @min(x / @as(f64, @floatFromInt(n)), 1);
    const gap: f64 = if (duty <= 0.01 or duty >= 0.999 or j.avg_ms == 0)
        0
    else
        @as(f64, @floatFromInt(j.avg_ms)) * (1 - duty) / duty;
    return .{ .share = s, .workers = n, .gap_ms = @intFromFloat(@round(@min(gap, 600_000))) };
}

/// Whether a new value moved 10% or more from the last pushed (any move from or to 0).
pub fn moved(was: u32, now: u32) bool {
    if (was == now) return false;
    if (was == 0 or now == 0) return true;
    const d: f64 = @floatFromInt(@max(was, now) - @min(was, now));
    return d >= 0.1 * @as(f64, @floatFromInt(was));
}

/// A cost's next value: the EWMA moved toward this tick's CPU per busy worker.
pub fn nextCost(cost: f64, cpu_s: f64, busy_worker_s: f64, dt_s: f64) f64 {
    if (busy_worker_s < 0.5) return cost;
    const sample = std.math.clamp(cpu_s / busy_worker_s, 0.05, 64);
    return cost + @min(dt_s / cost_span_s, 1) * (sample - cost);
}

// --- The agent -------------------------------------------------------------------------------

const Conn = struct {
    conn: lines.Conn,
    /// A driver: its folder (from `hello`); null for an attach client.
    path: ?[]u8 = null,
    pid: c.pid_t = 0,
    hello: bool = false,
    state: [16]u8 = undefined,
    state_len: usize = 0,
    job: Job = .{},
    done: u64 = 0,
    fail: u64 = 0,
    gap: u32 = 0,
    gap_pinned: bool = false,
    /// What was pushed last.
    pushed_workers: u32 = 0,
    pushed_gap: u32 = 0,
    knobs: Knobs = .{},
    /// CPU measured: its tree's total last tick, and its rate.
    tree_ns: ?u64 = null,
    cpu: f64 = 0,
};

pub fn cmdAgent(ctx: *Ctx, args: []const [:0]const u8) u8 {
    for (args) |x| {
        if (std.mem.eql(u8, x, "--install")) return @import("records.zig").installService(ctx, .agent, true);
        if (std.mem.eql(u8, x, "--uninstall")) return @import("records.zig").installService(ctx, .agent, false);
        return usageError("usage: cpuq agent [--install | --uninstall]", .{});
    }
    const io = ctx.io;
    const gpa = std.heap.c_allocator;
    const state = jobs.stateDir(ctx.arena, ctx.env) orelse fail("no HOME, so no state dir", .{});
    Io.Dir.cwd().createDirPath(io, state) catch |err| fail("{s}: {t}", .{ state, err });
    const dz = ctx.arena.dupeSentinel(u8, state, 0) catch fail("out of memory", .{});
    const dir = c.open(dz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) fail("can't open {s}", .{state});
    const lock = c.openat(dir, "agent.lock", .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
    if (lock < 0 or c.flock(lock, c.LOCK.EX | c.LOCK.NB) != 0) fail("an agent already runs here ({s}/host.sock)", .{state});
    const listener = lines.listen(dir, "host.sock") catch |err| fail("host.sock: {t}", .{err});

    var conns: std.ArrayList(*Conn) = .empty;
    var budget: Budget = .{};
    var ticks_was = sys.cpuTicks(io);
    var tick_at = sys.monoMs();
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    var fds: std.ArrayList(c.pollfd) = .empty;
    while (true) {
        const now = sys.monoMs();
        if (now - tick_at >= 1000) {
            _ = scratch.reset(.retain_capacity);
            const dt_s = @as(f64, @floatFromInt(now - tick_at)) / 1000;
            tick_at = now;
            const ticks = sys.cpuTicks(io);
            tick(ctx, scratch.allocator(), conns.items, &budget, ticks_was, ticks, dt_s);
            ticks_was = ticks;
        }
        fds.clearRetainingCapacity();
        fds.append(gpa, .{ .fd = listener, .events = c.POLL.IN, .revents = 0 }) catch {};
        for (conns.items) |k| {
            const out: i16 = if (k.conn.out.items.len > 0) c.POLL.OUT else 0;
            fds.append(gpa, .{ .fd = k.conn.fd, .events = c.POLL.IN | out, .revents = 0 }) catch {};
        }
        const wait = std.math.clamp(tick_at + 1000 - sys.monoMs(), 0, 1000);
        _ = c.poll(fds.items.ptr, @intCast(fds.items.len), @intCast(wait));
        if (fds.items[0].revents != 0) while (lines.accept(listener)) |fd| {
            const k = gpa.create(Conn) catch continue;
            k.* = .{ .conn = .{ .fd = fd } };
            conns.append(gpa, k) catch {};
        };
        const polled = fds.items[1..];
        var i: usize = conns.items.len;
        while (i > 0) {
            i -= 1;
            const k = conns.items[i];
            if (i < polled.len and polled[i].revents != 0) {
                if (polled[i].revents & c.POLL.OUT != 0) k.conn.flush();
                if (polled[i].revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) {
                    k.conn.fill(gpa);
                    while (k.conn.next()) |line| serve(gpa, conns.items, k, line);
                }
            }
            if (k.conn.closed) {
                k.conn.deinit(gpa);
                if (k.path) |p| gpa.free(p);
                gpa.destroy(k);
                _ = conns.orderedRemove(i);
            }
        }
    }
}

/// One line from a connection: a driver's hello, state or bye, or an attach client's request.
fn serve(gpa: Allocator, all: []const *Conn, k: *Conn, line: []const u8) void {
    var f = std.mem.tokenizeScalar(u8, line, ' ');
    const verb = f.next() orelse return;
    if (std.mem.eql(u8, verb, "hello")) {
        const path = f.next() orelse return;
        _ = f.next(); // pid
        k.pid = int(c.pid_t, f.next()) orelse 0;
        k.path = gpa.dupe(u8, path) catch null;
        k.hello = true;
    } else if (std.mem.eql(u8, verb, "state") and k.hello) {
        const st = f.next() orelse return;
        k.state_len = @min(st.len, k.state.len);
        @memcpy(k.state[0..k.state_len], st[0..k.state_len]);
        k.job.weight = @max(int(u32, f.next()) orelse 1, 1);
        k.job.workers = int(u32, f.next()) orelse k.job.workers;
        k.gap = int(u32, f.next()) orelse 0;
        k.job.todo = int(u64, f.next()) orelse 0;
        k.job.live = int(u64, f.next()) orelse 0;
        k.done = int(u64, f.next()) orelse 0;
        k.fail = int(u64, f.next()) orelse 0;
        k.job.avg_ms = int(u64, f.next()) orelse 0;
        k.job.pinned = std.mem.eql(u8, f.next() orelse "", "set");
        k.gap_pinned = std.mem.eql(u8, f.next() orelse "", "set");
        // The count a driver reports is the one to move from.
        if (k.pushed_workers == 0) k.pushed_workers = k.job.workers;
    } else if (std.mem.eql(u8, verb, "bye")) {
        k.conn.closed = true;
    } else if (std.mem.eql(u8, verb, "jobs")) {
        for (all) |j| if (j.hello) {
            k.conn.print(gpa, "job {s} {s} {d} {d} {d} {d} {d} {d} {d} {d:.2} {d:.2} {d:.2}\n", .{
                j.path orelse "-", j.state[0..j.state_len], j.job.weight, j.job.workers, j.gap,
                j.job.todo,        j.job.live,              j.done,       j.fail,        j.cpu,
                j.job.cost,        j.knobs.share,
            });
        };
        k.conn.print(gpa, "end\n", .{});
    } else if (std.mem.eql(u8, verb, "to")) {
        const given = f.next() orelse return k.conn.print(gpa, "error to needs a job's folder\n", .{});
        const rest = std.mem.trim(u8, f.rest(), " ");
        // As its driver names it: the real path, through any link.
        var zbuf: [4096]u8 = undefined;
        var rbuf: [4096]u8 = undefined;
        const path = if (given.len < zbuf.len) blk: {
            @memcpy(zbuf[0..given.len], given);
            zbuf[given.len] = 0;
            const r = c.realpath(@ptrCast(&zbuf), &rbuf) orelse break :blk given;
            break :blk std.mem.sliceTo(r, 0);
        } else given;
        for (all) |j| if (j.hello and j.path != null and std.mem.eql(u8, j.path.?, path)) {
            j.conn.print(gpa, "{s}\n", .{rest});
            return k.conn.print(gpa, "ok\n", .{});
        };
        k.conn.print(gpa, "error no job runs in {s}\n", .{given});
    } else k.conn.print(gpa, "error unknown request\n", .{});
}

/// A second's work: measure, set the budget, share it, push what changed.
fn tick(ctx: *Ctx, a: Allocator, conns: []const *Conn, budget: *Budget, was: ?sys.Ticks, now: ?sys.Ticks, dt_s: f64) void {
    const io = ctx.io;
    const cpus: f64 = @floatFromInt(sys.activeCpus(io));
    const target = admission.targetCpus(ctx);
    var busy: f64 = 0;
    if (was != null and now != null and now.?.total > was.?.total)
        busy = cpus * @as(f64, @floatFromInt(now.?.busy -| was.?.busy)) / @as(f64, @floatFromInt(now.?.total - was.?.total));
    const procs = sys.processes(io, a);
    var drivers: std.ArrayList(*Conn) = .empty;
    var jobs_cpu: f64 = 0;
    for (conns) |k| {
        if (!k.hello) continue;
        drivers.append(a, k) catch continue;
        const tree = sys.treeCpu(procs, k.pid);
        k.cpu = if (k.tree_ns) |t| @as(f64, @floatFromInt(tree -| t)) / 1e9 / dt_s else 0;
        k.tree_ns = tree;
        jobs_cpu += k.cpu;
    }
    if (drivers.items.len == 0) return;
    const over = busy > target;
    for (drivers.items) |k| if (!over) {
        k.job.cost = nextCost(k.job.cost, k.cpu * dt_s, @as(f64, @floatFromInt(k.job.live)) * dt_s, dt_s);
    };
    const m = main.machine(ctx);
    const short = m.pressure == .high or (ctx.cfg.min_available > 0 and (m.available orelse std.math.maxInt(u64)) < ctx.cfg.min_available);
    const runq = sys.runnable(io) orelse busy;
    const b = budget.step(target, @max(busy - jobs_cpu, 0), runq, short);
    const in = a.alloc(Job, drivers.items.len) catch return;
    const out = a.alloc(Knobs, drivers.items.len) catch return;
    for (drivers.items, in) |k, *j| j.* = k.job;
    shares(b, in, out);
    for (drivers.items, out) |k, o| {
        k.knobs = o;
        if (!k.job.pinned and k.job.todo + k.job.live > 0 and moved(k.pushed_workers, o.workers)) {
            k.conn.print(std.heap.c_allocator, "workers {d}\n", .{o.workers});
            k.pushed_workers = o.workers;
        }
        if (!k.gap_pinned and moved(k.pushed_gap, o.gap_ms)) {
            k.conn.print(std.heap.c_allocator, "gap {d}\n", .{o.gap_ms});
            k.pushed_gap = o.gap_ms;
        }
    }
}

/// `cpuq attach`: stdin and stdout joined to this machine's host.sock.
pub fn cmdAttach(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (args.len != 0) return usageError("cpuq attach takes no arguments", .{});
    const state = jobs.stateDir(ctx.arena, ctx.env) orelse fail("no HOME, so no state dir", .{});
    const dz = ctx.arena.dupeSentinel(u8, state, 0) catch fail("out of memory", .{});
    const dir = c.open(dz, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    const fd = (if (dir >= 0) lines.connect(dir, "host.sock") else null) orelse fail("no agent runs here ({s}/host.sock)", .{state});
    var buf: [65536]u8 = undefined;
    var in_open = true;
    while (true) {
        var pfd = [_]c.pollfd{
            .{ .fd = if (in_open) 0 else -1, .events = c.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = c.POLL.IN, .revents = 0 },
        };
        _ = c.poll(&pfd, 2, -1);
        if (pfd[0].revents != 0) {
            const n = c.read(0, &buf, buf.len);
            if (n <= 0) {
                in_open = false;
                _ = c.shutdown(fd, c.SHUT.WR);
            } else sys.writeAll(fd, buf[0..@intCast(n)]);
        }
        if (pfd[1].revents != 0) {
            const n = c.read(fd, &buf, buf.len);
            if (n <= 0) return 0;
            sys.writeAll(1, buf[0..@intCast(n)]);
        }
    }
}

fn int(comptime T: type, s: ?[]const u8) ?T {
    return std.fmt.parseInt(T, s orelse return null, 10) catch null;
}

// --- Tests -----------------------------------------------------------------------------------

const testing = std.testing;

test "the budget: room less outside load, cut fast when the run queue stays over, grown by half" {
    var b: Budget = .{};
    try testing.expectEqual(8, b.step(10, 2, 4, false));
    try testing.expectEqual(8, b.step(10, 2, 12, false)); // over once: held
    try testing.expectApproxEqAbs(8.0 * 10.0 / 15.0, b.step(10, 2, 15, false), 1e-9); // over twice: cut
    const cut = b.value.?;
    try testing.expectApproxEqAbs(@min(cut * 1.5, 8), b.step(10, 2, 4, false), 1e-9);
    try testing.expectApproxEqAbs(@min(cut * 1.5, 8) * 0.75, b.step(10, 2, 4, true), 1e-9);
    try testing.expectEqual(0, b.step(10, 12, 4, false)); // outside load past the target
}

test "shares water-fill by weight, a met demand's rest going to the others" {
    var out: [3]Knobs = undefined;
    // Two hungry jobs, weights 1 and 3: 2 and 6 of 8.
    shares(8, &.{ .{ .weight = 1, .todo = 100, .workers = 4 }, .{ .weight = 3, .todo = 100, .workers = 4 } }, out[0..2]);
    try testing.expectApproxEqAbs(2, out[0].share, 1e-9);
    try testing.expectApproxEqAbs(6, out[1].share, 1e-9);
    try testing.expectEqual(2, out[0].workers);
    try testing.expectEqual(6, out[1].workers);
    // A job that can use only 1 leaves the rest to the other.
    shares(8, &.{ .{ .weight = 3, .todo = 1, .workers = 1 }, .{ .weight = 1, .todo = 100, .workers = 8 } }, out[0..2]);
    try testing.expectApproxEqAbs(1, out[0].share, 1e-9);
    try testing.expectApproxEqAbs(7, out[1].share, 1e-9);
    // A job whose workers a user set keeps them, and its use comes off the budget first.
    shares(8, &.{ .{ .weight = 1, .todo = 100, .workers = 5, .pinned = true }, .{ .weight = 1, .todo = 100, .workers = 2 } }, out[0..2]);
    try testing.expectEqual(5, out[0].workers);
    try testing.expectApproxEqAbs(3, out[1].share, 1e-9);
    try testing.expectEqual(3, out[1].workers);
    // A job with nothing left gets nothing.
    shares(8, &.{ .{ .todo = 0, .live = 0 }, .{ .todo = 50, .workers = 8 } }, out[0..2]);
    try testing.expectEqual(0, out[0].share);
    try testing.expectApproxEqAbs(8, out[1].share, 1e-9);
}

test "knobs: workers rounded up, at most twice the last count, the rounding taken back as gap" {
    // 2.5 CPUs at cost 1: 3 workers, each idle 1/6 of the time: gap = 600 × (1 − 5/6) ÷ (5/6).
    const k = knobs(.{ .workers = 3, .avg_ms = 600 }, 2.5);
    try testing.expectEqual(3, k.workers);
    try testing.expectEqual(120, k.gap_ms);
    // A rise from 2 stops at 4, with no gap.
    const r = knobs(.{ .workers = 2, .avg_ms = 600 }, 10);
    try testing.expectEqual(4, r.workers);
    try testing.expectEqual(0, r.gap_ms);
    // At least one worker, however small the share.
    try testing.expectEqual(1, knobs(.{ .workers = 4 }, 0).workers);
    // A costlier job gets fewer workers for the same share.
    try testing.expectEqual(2, knobs(.{ .workers = 4, .cost = 2 }, 4).workers);
}

test "pushes only on a move of 10% or more, any move under 10" {
    try testing.expect(!moved(20, 21));
    try testing.expect(moved(20, 22));
    try testing.expect(moved(4, 5));
    try testing.expect(moved(0, 3));
    try testing.expect(!moved(7, 7));
}

test "cost: an EWMA toward CPU per busy worker, untouched without busy workers" {
    try testing.expectApproxEqAbs(1.0 + (1.0 / 15.0) * (0.6 - 1.0), nextCost(1, 3, 5, 1), 1e-9);
    try testing.expectEqual(1, nextCost(1, 3, 0.2, 1));
}
