//! What history says of a job: its typical run time and use, and the queue played forward to
//! each waiter's ETA.
const std = @import("std");
const policy = @import("policy.zig");
const sys = @import("sys.zig");
const history = @import("history.zig");
const place = @import("place.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");
const joblog = @import("joblog.zig");
const statusjson = @import("statusjson.zig");

const Ctx = main.Ctx;
const RunOptions = runopts.RunOptions;
const historyPath = joblog.historyPath;
const JsonHolder = statusjson.JsonHolder;
const JsonWaiter = statusjson.JsonWaiter;

/// What sizes a job: its own work's runs here (place.workKey), when three or more, else its
/// label's.
pub fn jobUses(ctx: *Ctx, rt: RunTimes, key: []const u8, o: RunOptions) []const f64 {
    const uses = rt.workUses(ctx.arena, key);
    return if (uses.len >= 3) uses else labelUses(rt, o.label);
}

/// A label's last runs' average active cores (`history.used`).
fn labelUses(rt: RunTimes, label: []const u8) []const f64 {
    if (label.len == 0) return &.{};
    return if (rt.uses.get(label)) |u| u.items else &.{};
}

/// A label's expected use: the 75th percentile of its last runs; null with
/// fewer than three.
pub fn useOf(rt: RunTimes, label: []const u8) ?f64 {
    return policy.typicalUse(labelUses(rt, label));
}

pub fn aliveForHistory(pid: i32) bool {
    return sys.processAlive(pid);
}

/// Typical run times from the history: the median run of finished jobs by
/// label, and by project (the label up to its first ':').
pub const RunTimes = struct {
    by_label: std.StringHashMapUnmanaged(f64) = .empty,
    by_project: std.StringHashMapUnmanaged(f64) = .empty,
    /// Each label's finished runs' use, oldest first: the most cores a run
    /// kept busy over a 2-second look, else (older history) its average.
    /// Sizing from peaks counts a build that fans out briefly at what it
    /// fans out to, not at its average.
    uses: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty,
    /// Each command's median run time, by label and the command's shape (`shape`).
    by_command: std.StringHashMapUnmanaged(f64) = .empty,
    /// Each kind of work's runs (place.workKey: repo and command, whatever its label), here and
    /// on each host it was sent to, by `workAt`'s key.
    work: std.StringHashMapUnmanaged(place.Runs) = .empty,

    pub fn load(ctx: *Ctx, a: std.mem.Allocator) RunTimes {
        var rt: RunTimes = .{};
        const jobs = history.load(ctx.io, a, historyPath(ctx), sys.bootTime(ctx.io), &aliveForHistory);
        var label_runs: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty;
        var project_runs: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty;
        var command_runs: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty;
        for (jobs) |j| {
            const r = j.ran() orelse continue;
            const spilled = std.mem.eql(u8, j.pool, "spill");
            // A work's times are its runs that did it: one that failed early (a missing input on
            // another OS, a compile error) would make the place it failed look quick.
            const did = j.signal == null and (j.exit orelse 1) == 0;
            if (did and (spilled or std.mem.eql(u8, j.pool, "cores"))) {
                const key = workAt(a, if (spilled) j.host orelse continue else "", workKeyOf(a, j));
                const gop = rt.work.getOrPut(a, key) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .{};
                gop.value_ptr.add(a, r, if (spilled) null else j.cpu_peak orelse j.used(), if (spilled) null else j.cores);
            }
            if (j.label.len == 0 or !std.mem.eql(u8, j.pool, "cores")) continue;
            {
                const gop = command_runs.getOrPut(a, shape(a, j.label, j.cmd)) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(a, r) catch {};
            }
            if (j.cpu_peak orelse j.used()) |u| {
                const gop = rt.uses.getOrPut(a, j.label) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(a, u) catch {};
            }
            for ([_]struct { m: *std.StringHashMapUnmanaged(std.ArrayList(f64)), k: []const u8 }{
                .{ .m = &label_runs, .k = j.label },
                .{ .m = &project_runs, .k = std.mem.sliceTo(j.label, ':') },
            }) |e| {
                const gop = e.m.getOrPut(a, e.k) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(a, r) catch {};
            }
        }
        var it = label_runs.iterator();
        while (it.next()) |e| rt.by_label.put(a, e.key_ptr.*, history.median(e.value_ptr.items)) catch {};
        var it2 = project_runs.iterator();
        while (it2.next()) |e| rt.by_project.put(a, e.key_ptr.*, history.median(e.value_ptr.items)) catch {};
        var it3 = command_runs.iterator();
        while (it3.next()) |e| rt.by_command.put(a, e.key_ptr.*, history.median(e.value_ptr.items)) catch {};
        return rt;
    }

    /// The last 20 runs of one kind of work (`workKey`): here (`host` null) or sent to `host`.
    pub fn workStats(rt: RunTimes, a: std.mem.Allocator, host: ?[]const u8, key: []const u8) place.Stats {
        const runs = rt.work.getPtr(workAt(a, host orelse "", key)) orelse return .{};
        return runs.stats(a, 20);
    }

    /// The cores one kind of work's runs here kept busy, oldest first.
    fn workUses(rt: RunTimes, a: std.mem.Allocator, key: []const u8) []const f64 {
        const runs = rt.work.getPtr(workAt(a, "", key)) orelse return &.{};
        return runs.used.items;
    }

    fn workAt(a: std.mem.Allocator, host: []const u8, key: []const u8) []const u8 {
        return std.mem.concat(a, u8, &.{ host, "\x01", key }) catch key;
    }

    /// A past job's work key: older history has no repo, and its label's project stands in.
    fn workKeyOf(a: std.mem.Allocator, j: history.Job) []const u8 {
        return place.workKey(a, j.repo orelse std.mem.sliceTo(j.label, ':'), j.cmd);
    }

    /// A job's usual run time by earlier runs of its own command: what a running job's time is
    /// judged by. A label can cover different work (a one-minute check and a three-hour model),
    /// so a command not run before has none.
    pub fn typicalFor(rt: RunTimes, a: std.mem.Allocator, label: []const u8, cmd: []const u8) ?f64 {
        if (label.len == 0) return null;
        return rt.by_command.get(shape(a, label, cmd));
    }

    /// A label and a command, its numbers as `#`: runs differing only in a count, a seed or a
    /// limit (`-- 20 --seed 100`) are the same work.
    fn shape(a: std.mem.Allocator, label: []const u8, cmd: []const u8) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(a, label) catch return label;
        out.append(a, 0) catch return label;
        var in_number = false;
        for (cmd[0..@min(cmd.len, history.max_cmd)]) |ch| {
            if (std.ascii.isDigit(ch)) {
                if (!in_number) out.append(a, '#') catch return label;
                in_number = true;
            } else {
                in_number = false;
                out.append(a, ch) catch return label;
            }
        }
        return out.items;
    }

    pub fn typical(rt: RunTimes, label: []const u8) ?f64 {
        if (label.len == 0) return null;
        return rt.by_label.get(label) orelse rt.by_project.get(std.mem.sliceTo(label, ':'));
    }
};

/// Fills in each waiter's ETA by playing the queue forward: holders free
/// their cores at their typical end, and each waiter, in order, starts once
/// its minimum fits and then holds it for its own typical run. An unknown
/// run time ahead of a waiter leaves its ETA unknown.
pub fn estimate(rt: RunTimes, budget: u32, holders: []const JsonHolder, waiters: []JsonWaiter, now: i64) void {
    estimateIn(rt, @floatFromInt(budget), null, holders, waiters, now);
}

/// Plays the queue forward: each running job ends at its label's typical run
/// time, and each waiter starts, in order, once what it needs is free. Under
/// `admit = cores` (`target` null) the room is the budget and a job takes its
/// cores; under measured admission the room is the target, a running job
/// takes what it is measured using (its label's typical use until measured)
/// and a waiter what its label typically uses, as admission charges them.
pub fn estimateIn(rt: RunTimes, capacity: f64, target: ?f64, holders: []const JsonHolder, waiters: []JsonWaiter, now: i64) void {
    const Release = struct { at: ?f64, units: f64 };
    var pending: [256]Release = undefined;
    var n: usize = 0;
    var free: f64 = capacity;
    for (holders) |h| {
        const cores = h.cores;
        const units: f64 = if (target != null) policy.charge(useOf(rt, h.label), h.using, 1, 0, @max(cores, 1)) else @floatFromInt(cores);
        free -= units;
        if (n == pending.len) return;
        const at: ?f64 = if (rt.typical(h.label)) |t| @max(@as(f64, @floatFromInt(h.since)) + t - @as(f64, @floatFromInt(now)), 0) else null;
        pending[n] = .{ .at = at, .units = units };
        n += 1;
    }
    var clock: f64 = 0;
    var known = true;
    for (waiters) |*q| {
        const cores = @max(q.cores, 1);
        // An exclusive run waits for the whole machine to drain.
        const need: f64 = if (q.exclusive) capacity else if (target != null)
            policy.charge(useOf(rt, q.label), null, 0, 1, cores)
        else
            @min(@as(f64, @floatFromInt(cores)), capacity);
        while (n != 0 and (free < need - 1e-9 or q.exclusive)) {
            // The next release: the earliest known one; an unknown one only
            // when no known one is left.
            var pick: usize = 0;
            for (pending[0..n], 0..) |r, i| {
                const best = pending[pick].at;
                if (r.at) |at| {
                    if (best == null or at < best.?) pick = i;
                }
            }
            const r = pending[pick];
            pending[pick] = pending[n - 1];
            n -= 1;
            if (r.at) |at| clock = @max(clock, at) else known = false;
            free += r.units;
        }
        if (free < need - 1e-9 or !known) {
            q.eta = null;
            known = false;
            continue;
        }
        q.eta = clock;
        free -= need;
        if (n < pending.len) {
            pending[n] = .{ .at = if (rt.typical(q.label)) |t| clock + t else null, .units = need };
            n += 1;
        }
    }
}
