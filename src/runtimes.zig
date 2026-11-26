//! What history says of a run's work: how long it took here, and on each host it was sent to.
const std = @import("std");
const sys = @import("sys.zig");
const history = @import("history.zig");
const place = @import("place.zig");

const main = @import("main.zig");
const joblog = @import("joblog.zig");

const Ctx = main.Ctx;
const historyPath = joblog.historyPath;

pub fn aliveForHistory(pid: i32) bool {
    return sys.processAlive(pid);
}

/// Each kind of work's runs (place.workKey: repo and command, whatever its label), here and on
/// each host it was sent to.
pub const RunTimes = struct {
    work: std.StringHashMapUnmanaged(place.Runs) = .empty,

    pub fn load(ctx: *Ctx, a: std.mem.Allocator) RunTimes {
        var rt: RunTimes = .{};
        const jobs = history.load(ctx.io, a, historyPath(ctx), sys.bootTime(ctx.io), &aliveForHistory);
        for (jobs) |j| {
            const r = j.ran() orelse continue;
            const sent = std.mem.eql(u8, j.pool, "remote");
            if (!sent and !std.mem.eql(u8, j.pool, "cpus")) continue;
            // A work's times are its runs that did it: one that failed early (a missing input on
            // another OS, a compile error) would make the place it failed look quick.
            if (j.signal != null or (j.exit orelse 1) != 0) continue;
            const key = workAt(a, if (sent) j.host orelse continue else "", workKeyOf(a, j));
            const gop = rt.work.getOrPut(a, key) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = .{};
            gop.value_ptr.add(a, r, if (sent) null else j.used(), if (sent) null else j.cores);
        }
        return rt;
    }

    /// The last 20 runs of one kind of work (`workKey`): here (`host` null) or sent to `host`.
    pub fn workStats(rt: RunTimes, a: std.mem.Allocator, host: ?[]const u8, key: []const u8) place.Stats {
        const runs = rt.work.getPtr(workAt(a, host orelse "", key)) orelse return .{};
        return runs.stats(a, 20);
    }

    fn workAt(a: std.mem.Allocator, host: []const u8, key: []const u8) []const u8 {
        return std.mem.concat(a, u8, &.{ host, "\x01", key }) catch key;
    }

    /// A past run's work key: a run with no repo counts its label's project instead.
    fn workKeyOf(a: std.mem.Allocator, j: history.Job) []const u8 {
        return place.workKey(a, j.repo orelse std.mem.sliceTo(j.label, ':'), j.cmd);
    }
};
