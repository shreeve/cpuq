//! The pool: which task starts next, and how many run. A pure core: the driver feeds it what it
//! sees (jobs' settings, task names, a load sample each second, tasks' ends) and does what it
//! says. No I/O and no clock of its own, so a test runs hours of a host in milliseconds.
//!
//! - Pick: the job with the fewest running per unit of weight that is not stopped, has a task
//!   and is under its `max`; ties go to the job whose submission is oldest.
//! - Count: a target in workers (a task counts as its job's `cores`), moved each second by the
//!   load R̄ (runnable threads, averaged over the second) against the target L:
//!   more than 0.5 below L it grows by ½·(L − R̄)/d, at most doubling; above L + b for 3 ticks
//!   in a row it falls by as much, and finished tasks aren't refilled until the count is under
//!   it. Nothing is ever killed. b = max(0.5, 5% of L); d = the jobs' CPU ÷ wall per task.
//! - Floors: each job with work runs at least one, unless memory is short or the pool holds.
//! - Ceilings: the tasks left, each job's `max`, and free memory ÷ the p95 peak of its tasks.
const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const Delay = union(enum) { none, rand, task, secs: f64 };

/// A job's settings, from its `base` file.
pub const Config = struct {
    weight: f64 = 1,
    max: u32 = std.math.maxInt(u32),
    /// Workers each task counts as: 1 for a pool task, K for `cpuq run --cores K`.
    cores: u32 = 1,
    delay: Delay = .none,
    stopped: bool = false,
    /// When it was submitted (its stamp), in ms: ties go to the oldest.
    since: i64 = 0,
    /// CPU ÷ wall per task from history, until its own tasks say.
    d: f64 = 1,
};

/// What the driver measured over the last second.
pub const Sample = struct {
    /// The load target: the host's cores, or `cpuq driver --load L`.
    target: f64,
    /// Runnable threads, averaged over the second, the driver's own left out.
    runnable: f64,
    /// Memory free for tasks, bytes.
    free: u64 = std.math.maxInt(u64),
};

pub const Start = struct {
    job: []const u8,
    task: []const u8,
    /// 1, 2, …: the lowest free in its job (`CPUQ_SLOT`).
    slot: u32,
    /// How long it waits before it runs (`--delay`, first wave only); it holds its slot meanwhile.
    delay_ms: u64,
};

/// A task's end, from `wait4` or its base.
pub const End = struct {
    ok: bool,
    cpu_ms: u64 = 0,
    wall_ms: u64 = 0,
    peak: u64 = 0,
};

const peaks_kept = 64;

const Job = struct {
    cfg: Config,
    /// Owns the task names.
    names: std.heap.ArenaAllocator,
    todo: std.ArrayList([]const u8) = .empty,
    head: usize = 0,
    /// Names in todo or running, so a rescan adds only new ones.
    known: std.StringHashMapUnmanaged(void) = .empty,
    /// Per slot (index = slot − 1): the running task and when it started, or null.
    slots: std.ArrayList(?Running) = .empty,
    running: u32 = 0,
    started: u64 = 0,
    /// The first wave's size, fixed at the job's first start (`--delay`).
    wave: u64 = 0,
    d: f64,
    peaks: [peaks_kept]u64 = undefined,
    peaks_n: usize = 0,
    /// Base deaths since a task last finished.
    deaths: u32 = 0,

    const Running = struct { task: []const u8, at: i64 };

    fn left(j: *const Job) usize {
        return j.todo.items.len - j.head;
    }

    fn eligible(j: *const Job) bool {
        return !j.cfg.stopped and j.left() > 0 and j.running < j.cfg.max;
    }

    fn p95(j: *const Job) ?u64 {
        if (j.peaks_n == 0) return null;
        const n: usize = @min(j.peaks_n, peaks_kept);
        var copy: [peaks_kept]u64 = undefined;
        @memcpy(copy[0..n], j.peaks[0..n]);
        std.mem.sort(u64, copy[0..n], {}, std.sort.asc(u64));
        return copy[(n * 95 - 1) / 100];
    }
};

pub const Pool = struct {
    gpa: Allocator,
    jobs: std.array_hash_map.String(Job) = .empty,
    /// The count to run, in workers.
    count: f64 = 0,
    over: u8 = 0,
    /// No new picks, floors included (an `--exclusive` waiting for the running to finish).
    hold: bool = false,
    /// Memory too short for even one more task of some job: floors are off.
    short: bool = false,
    free: u64 = std.math.maxInt(u64),

    pub fn init(gpa: Allocator) Pool {
        return .{ .gpa = gpa };
    }

    pub fn deinit(p: *Pool) void {
        for (p.jobs.values()) |*j| p.freeJob(j);
        for (p.jobs.keys()) |k| p.gpa.free(k);
        p.jobs.deinit(p.gpa);
    }

    fn freeJob(p: *Pool, j: *Job) void {
        j.todo.deinit(p.gpa);
        j.known.deinit(p.gpa);
        j.slots.deinit(p.gpa);
        j.names.deinit();
    }

    /// Adds a job, or changes its settings live.
    pub fn configure(p: *Pool, name: []const u8, cfg: Config) !void {
        if (p.jobs.getPtr(name)) |j| {
            j.cfg = cfg;
            return;
        }
        const key = try p.gpa.dupe(u8, name);
        errdefer p.gpa.free(key);
        try p.jobs.put(p.gpa, key, .{ .cfg = cfg, .names = .init(p.gpa), .d = cfg.d });
    }

    /// Forgets a job (its folder is gone): the driver closes its base, whose cap ends its tree.
    pub fn remove(p: *Pool, name: []const u8) void {
        const kv = p.jobs.fetchOrderedRemove(name) orelse return;
        var j = kv.value;
        p.freeJob(&j);
        p.gpa.free(kv.key);
    }

    /// Queues a task found in todo/; one it already knows is left as it is.
    pub fn add(p: *Pool, name: []const u8, task: []const u8) !void {
        const j = p.jobs.getPtr(name) orelse return error.NoSuchJob;
        if (j.known.contains(task)) return;
        const owned = try j.names.allocator().dupe(u8, task);
        try j.todo.append(p.gpa, owned);
        try j.known.put(p.gpa, owned, {});
    }

    /// Each second: moves the count toward the load target.
    pub fn tick(p: *Pool, now: i64, s: Sample) void {
        const b = @max(0.5, 0.05 * s.target);
        // R̄ averages the second just past, so a task under a second old is only partly in it:
        // what it will add is the rest.
        var r = s.runnable;
        var d_sum: f64 = 0;
        var w_sum: f64 = 0;
        var ceiling: f64 = 0;
        var room: f64 = 0;
        p.short = false;
        // Free memory less what tasks under a second old have yet to take: their job's p95.
        p.free = s.free;
        for (p.jobs.values()) |*j| if (j.p95()) |peak| for (j.slots.items) |slot| if (slot) |run| {
            if (now - run.at < 1000) p.free -|= peak;
        };
        for (p.jobs.values()) |*j| {
            const cores: f64 = @floatFromInt(j.cfg.cores);
            for (j.slots.items) |slot| if (slot) |run| {
                const age = @as(f64, @floatFromInt(now - run.at)) / 1000;
                if (age < 1) r += j.d * cores * (1 - @max(age, 0));
            };
            if (j.cfg.stopped) continue;
            const can = @min(@as(u64, j.cfg.max), j.left() + j.running);
            ceiling += @as(f64, @floatFromInt(can)) * cores;
            if (j.left() > 0) {
                d_sum += j.d * j.cfg.weight;
                w_sum += j.cfg.weight;
            }
            if (j.p95()) |peak| {
                const fits = p.free / @max(peak, 1);
                if (j.left() > 0 and fits == 0) p.short = true;
                room += @as(f64, @floatFromInt(@min(fits, j.left()) + j.running)) * cores;
            } else room += @as(f64, @floatFromInt(j.left() + j.running)) * cores;
        }
        const d = if (w_sum > 0) @max(d_sum / w_sum, 0.05) else 1;
        const gap = s.target - r;
        if (gap > 0.5) {
            p.over = 0;
            p.count += @min(@ceil(0.5 * gap / d), @max(p.count, 1));
        } else if (-gap > b) {
            p.over +|= 1;
            if (p.over >= 3) p.count = @max(0, p.count - @ceil(0.5 * -gap / d));
        } else p.over = 0;
        p.count = @min(p.count, @min(ceiling, room));
    }

    /// The next task to start, or null for none now: call until null after each tick and end.
    pub fn next(p: *Pool, now: i64, rand: std.Random) !?Start {
        if (p.hold) return null;
        const busy = p.units();
        var best: ?usize = null;
        var floor = false;
        for (p.jobs.values(), 0..) |*j, i| {
            if (!j.eligible()) continue;
            if (j.p95()) |peak| if (p.free / @max(peak, 1) == 0) continue;
            // A job with work and none running starts regardless of the count, unless memory is
            // short.
            const is_floor = j.running == 0 and !p.short;
            if (!is_floor and busy + @as(f64, @floatFromInt(j.cfg.cores)) > p.count + 1e-9) continue;
            if (best) |k| {
                if (floor and !is_floor) continue;
                if (is_floor == floor and !before(j, &p.jobs.values()[k])) continue;
            }
            best = i;
            floor = is_floor;
        }
        const i = best orelse return null;
        const j = &p.jobs.values()[i];
        const task = j.todo.items[j.head];
        j.head += 1;
        if (j.head == j.todo.items.len) {
            j.todo.clearRetainingCapacity();
            j.head = 0;
        }
        const slot = for (j.slots.items, 0..) |s, k| {
            if (s == null) break k;
        } else blk: {
            try j.slots.append(p.gpa, null);
            break :blk j.slots.items.len - 1;
        };
        j.slots.items[slot] = .{ .task = task, .at = now };
        j.running += 1;
        if (j.started == 0) j.wave = @min(@as(u64, j.cfg.max), @max(@as(u64, @intFromFloat(p.count)), 1));
        const index = j.started;
        j.started += 1;
        return .{ .job = p.jobs.keys()[i], .task = task, .slot = @intCast(slot + 1), .delay_ms = delayMs(j.cfg.delay, index, j.wave, rand) };
    }

    /// A task's end: its slot is free, and its CPU and memory tune d and the memory ceiling.
    pub fn ended(p: *Pool, name: []const u8, slot: u32, end: End) void {
        const j = p.jobs.getPtr(name) orelse return;
        const run = j.slots.items[slot - 1] orelse return;
        j.slots.items[slot - 1] = null;
        j.running -= 1;
        _ = j.known.remove(run.task);
        j.deaths = 0;
        if (end.wall_ms > 0) {
            const d = @as(f64, @floatFromInt(end.cpu_ms)) / @as(f64, @floatFromInt(end.wall_ms));
            j.d = 0.8 * j.d + 0.2 * d;
        }
        if (end.peak > 0) {
            j.peaks[j.peaks_n % peaks_kept] = end.peak;
            j.peaks_n += 1;
        }
    }

    /// A base died: its running tasks go back to the front of todo/ (they didn't fail). True
    /// means restart it; false, it died twice with no task finished between, so stop the job.
    pub fn baseDied(p: *Pool, name: []const u8) !bool {
        const j = p.jobs.getPtr(name) orelse return false;
        var back: std.ArrayList([]const u8) = .empty;
        defer back.deinit(p.gpa);
        for (j.slots.items) |*slot| if (slot.*) |run| {
            try back.append(p.gpa, run.task);
            slot.* = null;
        };
        j.running = 0;
        try j.todo.insertSlice(p.gpa, j.head, back.items);
        j.deaths += 1;
        return j.deaths < 2;
    }

    /// Running workers, in all.
    pub fn units(p: *const Pool) f64 {
        var n: f64 = 0;
        for (p.jobs.values()) |*j| n += @floatFromInt(j.running * j.cfg.cores);
        return n;
    }

    pub fn running(p: *const Pool, name: []const u8) u32 {
        return if (p.jobs.getPtr(name)) |j| j.running else 0;
    }

    pub fn left(p: *const Pool, name: []const u8) usize {
        return if (p.jobs.getPtr(name)) |j| j.left() else 0;
    }
};

/// Whether job `a` is picked before `b`: fewer running per unit of weight, then the older.
fn before(a: *const Job, b: *const Job) bool {
    const ra = @as(f64, @floatFromInt(a.running)) / @max(a.cfg.weight, 1e-9);
    const rb = @as(f64, @floatFromInt(b.running)) / @max(b.cfg.weight, 1e-9);
    if (ra != rb) return ra < rb;
    return a.cfg.since < b.cfg.since;
}

/// vete's `--delay` for the task at `index`: rand(wave) s, index s, or index × SECS, for the
/// first wave only.
fn delayMs(delay: Delay, index: u64, wave: u64, rand: std.Random) u64 {
    if (index >= wave) return 0;
    return switch (delay) {
        .none => 0,
        .rand => rand.uintLessThan(u64, wave) * 1000,
        .task => index * 1000,
        .secs => |s| @intFromFloat(@as(f64, @floatFromInt(index)) * s * 1000),
    };
}

// --- Tests: a simulated host ---------------------------------------------------------------

/// A host on a simulated clock: tasks run for their given time, each using d cores, and the load
/// the pool sees is what the running tasks used over the last second.
const Sim = struct {
    pool: Pool,
    rng: std.Random.DefaultPrng = .init(1),
    now: i64 = 0,
    live: std.ArrayList(Live) = .empty,
    done: u32 = 0,
    died: u32 = 0,
    /// The task's run time in ms and its d, by job.
    shape: *const fn (job: []const u8, task: []const u8, r: std.Random) Shape,
    outside: f64 = 0,

    const Shape = struct { ms: i64, d: f64 = 1, ok: bool = true, peak: u64 = 0 };
    const Live = struct { job: []const u8, task: []const u8, slot: u32, from: i64, to: i64, d: f64, ok: bool, peak: u64 };

    fn deinit(s: *Sim) void {
        s.live.deinit(testing.allocator);
        s.pool.deinit();
    }

    fn fill(s: *Sim) !void {
        while (try s.pool.next(s.now, s.rng.random())) |st| {
            const sh = s.shape(st.job, st.task, s.rng.random());
            const from = s.now + @as(i64, @intCast(st.delay_ms));
            try s.live.append(testing.allocator, .{ .job = st.job, .task = st.task, .slot = st.slot, .from = from, .to = from + sh.ms, .d = sh.d, .ok = sh.ok, .peak = sh.peak });
        }
    }

    /// One second, in steps of 10 ms: tasks end and are refilled as they do; then a tick.
    /// `mem`: the memory tasks may use, less what the running took.
    fn second(s: *Sim, target: f64, mem: u64) !void {
        var used: f64 = 0;
        for (0..100) |_| {
            s.now += 10;
            var k: usize = 0;
            while (k < s.live.items.len) {
                const l = s.live.items[k];
                if (l.to <= s.now) {
                    s.pool.ended(l.job, l.slot, .{ .ok = l.ok, .cpu_ms = @intFromFloat(@as(f64, @floatFromInt(l.to - l.from)) * l.d), .wall_ms = @intCast(l.to - l.from), .peak = l.peak });
                    if (l.ok) s.done += 1 else s.died += 1;
                    _ = s.live.swapRemove(k);
                    try s.fill();
                } else k += 1;
            }
            for (s.live.items) |l| {
                if (l.from <= s.now) used += l.d * @as(f64, @floatFromInt(s.pool.jobs.getPtr(l.job).?.cfg.cores));
            }
        }
        var free = mem;
        for (s.live.items) |l| if (l.from <= s.now) {
            free -|= l.peak;
        };
        s.pool.tick(s.now, .{ .target = target, .runnable = used / 100 + s.outside, .free = free });
        try s.fill();
    }
};

fn protoShape(_: []const u8, task: []const u8, r: std.Random) Sim.Shape {
    return .{ .ms = 3000 + @as(i64, r.uintLessThan(u32, 4000)), .ok = std.mem.indexOf(u8, task, "bad") == null };
}

test "weights 1:3 at a target of 50 run 12.5 and 37.5; every task ends once" {
    var s: Sim = .{ .pool = .init(testing.allocator), .shape = protoShape };
    defer s.deinit();
    try s.pool.configure("a", .{ .weight = 1 });
    try s.pool.configure("b", .{ .weight = 3, .since = 1 });
    var buf: [16]u8 = undefined;
    for (0..300) |i| {
        try s.pool.add("a", try std.fmt.bufPrint(&buf, "{s}{d}", .{ if (i == 7) "bad" else "t", i }));
        try s.pool.add("b", try std.fmt.bufPrint(&buf, "{s}{d}", .{ if (i == 9) "bad" else "t", i }));
    }
    try s.pool.add("a", "t3"); // already queued: ignored
    try s.fill();
    var sum_a: f64 = 0;
    var sum_b: f64 = 0;
    var n: f64 = 0;
    var t: u32 = 0;
    while (s.done + s.died < 600) : (t += 1) {
        try s.second(50, std.math.maxInt(u64));
        if (t >= 10 and s.pool.left("a") > 0 and s.pool.left("b") > 0) {
            sum_a += @floatFromInt(s.pool.running("a"));
            sum_b += @floatFromInt(s.pool.running("b"));
            n += 1;
        }
        try testing.expect(t < 600);
    }
    try testing.expect(n > 10);
    try testing.expectApproxEqRel(12.5, sum_a / n, 0.15);
    try testing.expectApproxEqRel(37.5, sum_b / n, 0.15);
    try testing.expectEqual(598, s.done);
    try testing.expectEqual(2, s.died);
    try testing.expectEqual(0, s.pool.left("a") + s.pool.left("b"));
}

fn ioShape(_: []const u8, _: []const u8, r: std.Random) Sim.Shape {
    return .{ .ms = 1000 + @as(i64, r.uintLessThan(u32, 1000)), .d = 0.02 };
}

test "waiting tasks (d 0.02) stop at max, not at the load" {
    var s: Sim = .{ .pool = .init(testing.allocator), .shape = ioShape };
    defer s.deinit();
    try s.pool.configure("dl", .{ .max = 50 });
    var buf: [16]u8 = undefined;
    for (0..15000) |i| try s.pool.add("dl", try std.fmt.bufPrint(&buf, "{d}", .{i}));
    try s.fill();
    var most: u32 = 0;
    for (0..30) |_| {
        try s.second(10, std.math.maxInt(u64));
        most = @max(most, s.pool.running("dl"));
    }
    try testing.expectEqual(50, most);
}

fn cpuShape(_: []const u8, _: []const u8, r: std.Random) Sim.Shape {
    return .{ .ms = 2000 + @as(i64, r.uintLessThan(u32, 8000)), .d = 1 };
}

test "busy tasks hold the load near the target, and give way to work outside" {
    var s: Sim = .{ .pool = .init(testing.allocator), .shape = cpuShape };
    defer s.deinit();
    try s.pool.configure("cpu", .{});
    var buf: [16]u8 = undefined;
    for (0..5000) |i| try s.pool.add("cpu", try std.fmt.bufPrint(&buf, "{d}", .{i}));
    try s.fill();
    var within: u32 = 0;
    for (0..60) |t| {
        try s.second(96, std.math.maxInt(u64));
        if (t >= 15 and @abs(s.pool.units() - 96) <= 9.6) within += 1;
    }
    try testing.expect(within >= 36); // 80% of the 45 settled ticks
    // 40 cores of outside work: the pool falls back by attrition to about 56.
    s.outside = 40;
    for (0..30) |_| try s.second(96, std.math.maxInt(u64));
    try testing.expect(s.pool.units() >= 46 and s.pool.units() <= 66);
}

fn memShape(_: []const u8, _: []const u8, r: std.Random) Sim.Shape {
    return .{ .ms = 1000 + @as(i64, r.uintLessThan(u32, 500)), .d = 0.1, .peak = 1 << 30 };
}

test "tasks of 1 GiB stop at free memory" {
    var s: Sim = .{ .pool = .init(testing.allocator), .shape = memShape };
    defer s.deinit();
    try s.pool.configure("mem", .{});
    var buf: [16]u8 = undefined;
    for (0..200) |i| try s.pool.add("mem", try std.fmt.bufPrint(&buf, "{d}", .{i}));
    try s.fill();
    // 8 GiB for tasks: once it has seen a task's peak, the pool keeps to what fits.
    var most: u32 = 0;
    for (0..20) |t| {
        try s.second(22, 8 << 30);
        if (t >= 3) most = @max(most, s.pool.running("mem"));
    }
    try testing.expect(most >= 3 and most <= 8);
}

test "a build counts as its cores; a stopped job gets no picks; a base's death requeues" {
    var p: Pool = .init(testing.allocator);
    defer p.deinit();
    var prng: std.Random.DefaultPrng = .init(2);
    try p.configure("build", .{ .cores = 4 });
    try p.configure("pool", .{ .since = 1 });
    try p.add("build", "zig build");
    for (0..10) |i| {
        var buf: [8]u8 = undefined;
        try p.add("pool", try std.fmt.bufPrint(&buf, "{d}", .{i}));
    }
    p.count = 6;
    // Floors first: one each; then pool tasks up to 6 workers in all (the build is 4).
    const first = (try p.next(0, prng.random())).?;
    try testing.expectEqualStrings("build", first.job);
    while (try p.next(0, prng.random())) |_| {}
    try testing.expectEqual(6, p.units());
    try testing.expectEqual(2, p.running("pool"));
    // Its base died: both back to todo/, front first; a second death with none finished stops it.
    try testing.expect(try p.baseDied("pool"));
    try testing.expectEqual(10, p.left("pool"));
    try testing.expect(!try p.baseDied("pool"));
    try p.configure("pool", .{ .since = 1, .stopped = true });
    p.count = 100;
    try testing.expectEqual(null, try p.next(0, prng.random()));
}

test "--delay staggers the first wave only" {
    var prng: std.Random.DefaultPrng = .init(3);
    try testing.expectEqual(0, delayMs(.task, 0, 4, prng.random()));
    try testing.expectEqual(3000, delayMs(.task, 3, 4, prng.random()));
    try testing.expectEqual(0, delayMs(.task, 4, 4, prng.random()));
    try testing.expectEqual(1500, delayMs(.{ .secs = 0.5 }, 3, 4, prng.random()));
    try testing.expect(delayMs(.rand, 1, 4, prng.random()) < 4000);
}
