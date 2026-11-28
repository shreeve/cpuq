//! The pool's CPUs, and in what order: a task takes the first free token, and a drain isolates
//! CPUs from the tokens' end. The reserve, never handed out, is the pool's slowest whole cores. Every cpuq on the machine works the list out the
//! same way, so they agree on it.
//!
//! - `cpus = LIST` in the config (a Linux CPU list, "12-19,2") is the pool, in that order.
//! - Otherwise, Linux: the CPUs online, less those isolated from the scheduler, within the CPUs
//!   the machine's init may use (a container's CPU set), one hyperthread of each physical core
//!   first, then their siblings. macOS: 0 to the active CPU count less one (it cannot pin, so
//!   the numbers only count).
//! - `reserve = N` keeps N CPUs out of the tokens (`tokens`): the slowest first (low-power and
//!   efficiency cores before performance cores), whole cores at a time, so no core is split
//!   between a token and the reserve; among equals, from the pool's end.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const policy = @import("policy.zig");
const sys = @import("sys.zig");

pub fn list(io: Io, a: std.mem.Allocator, configured: ?[]const u8) []const u32 {
    var cpus: []const u32 = if (configured) |text|
        policy.cpuList(a, text) catch &.{}
    else if (builtin.os.tag == .linux) linuxOrder(io, a) else &.{};
    if (cpus.len == 0) {
        const n = sys.activeCpus(io);
        const all = a.alloc(u32, n) catch return &.{0};
        for (all, 0..) |*c, i| c.* = @intCast(i);
        cpus = all;
    }
    return cpus;
}

fn readSmall(io: Io, a: std.mem.Allocator, path: []const u8) []const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 16)) catch "";
}

fn linuxOrder(io: Io, a: std.mem.Allocator) []const u32 {
    const online = policy.cpuList(a, std.mem.trim(u8, readSmall(io, a, "/sys/devices/system/cpu/online"), " \n")) catch return &.{};
    const isolated = policy.cpuList(a, std.mem.trim(u8, readSmall(io, a, "/sys/devices/system/cpu/isolated"), " \n")) catch &.{};
    const allowed = allowedCpus(io, a);
    var keep: std.ArrayList(u32) = .empty;
    for (online) |c| {
        if (std.mem.findScalar(u32, isolated, c) != null) continue;
        if (allowed.len != 0 and std.mem.findScalar(u32, allowed, c) == null) continue;
        keep.append(a, c) catch return online;
    }
    // A CPU is a first thread when it is the lowest of its siblings.
    var first: std.ArrayList(u32) = .empty;
    var rest: std.ArrayList(u32) = .empty;
    for (keep.items) |c| {
        const path = std.fmt.allocPrint(a, "/sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list", .{c}) catch continue;
        const sibs = policy.cpuList(a, std.mem.trim(u8, readSmall(io, a, path), " \n")) catch &.{};
        const lowest = if (sibs.len == 0) c else std.mem.min(u32, sibs);
        (if (lowest == c) &first else &rest).append(a, c) catch {};
    }
    first.appendSlice(a, rest.items) catch {};
    return first.items;
}

/// The CPUs the machine's init may use (`Cpus_allowed_list` of pid 1, else of this process):
/// a container's CPU set, the same for every process in it.
fn allowedCpus(io: Io, a: std.mem.Allocator) []const u32 {
    for ([_][]const u8{ "/proc/1/status", "/proc/self/status" }) |path| {
        const text = readSmall(io, a, path);
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const rest = std.mem.cutPrefix(u8, line, "Cpus_allowed_list:") orelse continue;
            return policy.cpuList(a, std.mem.trim(u8, rest, " \t")) catch &.{};
        }
    }
    return &.{};
}

/// A CPU and its SMT siblings (the other hardware threads of its core), itself left out.
pub const Core = struct { cpu: u32, siblings: []const u32 };

/// Linux: each of `cpus` with its siblings (`topology/thread_siblings_list`). Elsewhere, and for
/// a CPU whose list can't be read, none: macOS has no SMT on Apple silicon, and names no CPU.
pub fn cores(io: Io, a: std.mem.Allocator, cpus: []const u32) []const Core {
    var out: std.ArrayList(Core) = .empty;
    for (cpus) |c| {
        var sibs: std.ArrayList(u32) = .empty;
        if (builtin.os.tag == .linux) {
            const path = std.fmt.allocPrint(a, "/sys/devices/system/cpu/cpu{d}/topology/thread_siblings_list", .{c}) catch "";
            const all = policy.cpuList(a, std.mem.trim(u8, readSmall(io, a, path), " \n")) catch &.{};
            for (all) |s| if (s != c) sibs.append(a, s) catch {};
        }
        out.append(a, .{ .cpu = c, .siblings = sibs.items }) catch break;
    }
    return out.items;
}

/// A CPU's speed: a hybrid CPU's performance core (`/sys/devices/cpu_core/cpus`), its
/// `cpu_capacity` and its top clock (`cpuinfo_max_freq`). All alike where unknown (macOS).
pub const Speed = struct { cpu: u32, p: bool = false, cap: u64 = 0, freq: u64 = 0 };

/// Linux: each of `cpus`'s speed. Elsewhere all alike.
pub fn speeds(io: Io, a: std.mem.Allocator, cpus: []const u32) []const Speed {
    const out = a.alloc(Speed, cpus.len) catch return &.{};
    for (out, cpus) |*k, c| k.* = .{ .cpu = c };
    if (builtin.os.tag != .linux) return out;
    const p_cores = policy.cpuList(a, std.mem.trim(u8, readSmall(io, a, "/sys/devices/cpu_core/cpus"), " \n")) catch &.{};
    const num = struct {
        fn of(io2: Io, a2: std.mem.Allocator, cpu: u32, file: []const u8) u64 {
            const path = std.fmt.allocPrint(a2, "/sys/devices/system/cpu/cpu{d}/{s}", .{ cpu, file }) catch return 0;
            return std.fmt.parseInt(u64, std.mem.trim(u8, readSmall(io2, a2, path), " \n"), 10) catch 0;
        }
    };
    for (out) |*k| {
        k.p = std.mem.findScalar(u32, p_cores, k.cpu) != null;
        k.cap = num.of(io, a, k.cpu, "cpu_capacity");
        k.freq = num.of(io, a, k.cpu, "cpufreq/cpuinfo_max_freq");
    }
    return out;
}

fn speedOf(sp: []const Speed, cpu: u32) Speed {
    for (sp) |k| if (k.cpu == cpu) return k;
    return .{ .cpu = cpu };
}

/// Whether `x` is faster than `y`: a performance core, then the greater capacity, then the higher
/// top clock.
fn faster(x: Speed, y: Speed) bool {
    if (x.p != y.p) return x.p;
    if (x.cap != y.cap) return x.cap > y.cap;
    return x.freq > y.freq;
}

/// `cpus` fastest first (Linux): a hybrid CPU's performance cores before its efficiency cores,
/// then by capacity, then by top clock, else in their order. Elsewhere as they are.
pub fn fastFirst(io: Io, a: std.mem.Allocator, cpus: []const u32) []const u32 {
    const out = a.dupe(u32, cpus) catch return cpus;
    const sp = speeds(io, a, cpus);
    std.mem.sort(u32, out, sp, struct {
        fn less(k: []const Speed, x: u32, y: u32) bool {
            return faster(speedOf(k, x), speedOf(k, y));
        }
    }.less);
    return out;
}

/// The machine's tokens: the pool less the reserve of `n` CPUs (`reserveOf`), in the pool's order.
pub fn tokens(io: Io, a: std.mem.Allocator, pool: []const u32, n: u32) []const u32 {
    if (n == 0) return pool;
    return tokensFrom(a, pool, cores(io, a, pool), speeds(io, a, pool), n);
}

/// `tokens` from the pool's cores and speeds.
pub fn tokensFrom(a: std.mem.Allocator, pool: []const u32, topo: []const Core, sp: []const Speed, n: u32) []const u32 {
    const res = reserveOf(a, pool, topo, sp, n);
    if (res.len == 0) return pool;
    var out: std.ArrayList(u32) = .empty;
    for (pool) |c| if (std.mem.findScalar(u32, res, c) == null) out.append(a, c) catch return pool;
    return out.items;
}

/// The reserve: `n` of the pool's CPUs, the slowest first, whole cores at a time (a core's
/// threads in the pool together, so no core is split between a token and the reserve); among
/// equals, the core furthest along the pool's order first. A core that would take it past `n` is
/// taken whole. It never takes the whole pool: the last core it would empty is split, so one
/// token stays.
pub fn reserveOf(a: std.mem.Allocator, pool: []const u32, topo: []const Core, sp: []const Speed, n: u32) []const u32 {
    if (n == 0 or pool.len <= 1) return &.{};
    // Each core once: its threads in the pool, in the pool's order, and where its last one is.
    const Group = struct { cpus: []const u32, speed: Speed, last: usize };
    var groups: std.ArrayList(Group) = .empty;
    var seen: std.ArrayList(u32) = .empty;
    for (pool) |c| {
        if (std.mem.findScalar(u32, seen.items, c) != null) continue;
        var g: std.ArrayList(u32) = .empty;
        var last: usize = 0;
        for (pool, 0..) |d, i| {
            const same = d == c or for (topo) |t| {
                if (t.cpu == c) break std.mem.findScalar(u32, t.siblings, d) != null;
            } else false;
            if (!same) continue;
            g.append(a, d) catch return &.{};
            seen.append(a, d) catch return &.{};
            last = i;
        }
        groups.append(a, .{ .cpus = g.items, .speed = speedOf(sp, c), .last = last }) catch return &.{};
    }
    std.mem.sort(Group, groups.items, {}, struct {
        fn slower(_: void, x: Group, y: Group) bool {
            if (faster(y.speed, x.speed)) return true;
            if (faster(x.speed, y.speed)) return false;
            return x.last > y.last;
        }
    }.slower);
    var out: std.ArrayList(u32) = .empty;
    for (groups.items) |g| {
        if (out.items.len >= n) break;
        if (out.items.len + g.cpus.len >= pool.len) {
            // The last core it would empty: its threads from the pool's end, one token left.
            var k = g.cpus.len;
            while (k > 0 and out.items.len < n and out.items.len + 1 < pool.len) : (k -= 1) out.append(a, g.cpus[k - 1]) catch break;
            break;
        }
        out.appendSlice(a, g.cpus) catch break;
    }
    return out.items;
}

test "the reserve: the slowest whole cores, never a core split from its twin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A hybrid machine: performance cores 0-3 with twins 4-7, efficiency cores 8-11 (one thread
    // each). The pool's order, as Linux gives it: one thread of each core first, then twins.
    const pool = [_]u32{ 0, 1, 2, 3, 8, 9, 10, 11, 4, 5, 6, 7 };
    const topo = [_]Core{
        .{ .cpu = 0, .siblings = &.{4} }, .{ .cpu = 1, .siblings = &.{5} }, .{ .cpu = 2, .siblings = &.{6} }, .{ .cpu = 3, .siblings = &.{7} },
        .{ .cpu = 4, .siblings = &.{0} }, .{ .cpu = 5, .siblings = &.{1} }, .{ .cpu = 6, .siblings = &.{2} }, .{ .cpu = 7, .siblings = &.{3} },
        .{ .cpu = 8, .siblings = &.{} },  .{ .cpu = 9, .siblings = &.{} },  .{ .cpu = 10, .siblings = &.{} }, .{ .cpu = 11, .siblings = &.{} },
    };
    var sp: [12]Speed = undefined;
    for (&sp, 0..) |*k, i| k.* = .{ .cpu = @intCast(i), .p = i < 8, .cap = if (i < 8) 1024 else 512 };
    // Two: efficiency cores, from the pool's end, never the performance cores' twins (6, 7).
    try std.testing.expectEqualSlices(u32, &.{ 11, 10 }, reserveOf(a, &pool, &topo, &sp, 2));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 8, 9, 4, 5, 6, 7 }, tokensFrom(a, &pool, &topo, &sp, 2));
    // Five: the four efficiency cores, then a whole performance core (3 with its twin 7): six.
    try std.testing.expectEqualSlices(u32, &.{ 11, 10, 9, 8, 3, 7 }, reserveOf(a, &pool, &topo, &sp, 5));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 4, 5, 6 }, tokensFrom(a, &pool, &topo, &sp, 5));
    // All but one: the last core is split, one token left.
    try std.testing.expectEqualSlices(u32, &.{0}, tokensFrom(a, &pool, &topo, &sp, 11));
    try std.testing.expectEqualSlices(u32, &.{0}, tokensFrom(a, &pool, &topo, &sp, 99));
    try std.testing.expectEqual(12, tokensFrom(a, &pool, &topo, &sp, 0).len);
    // No topology and no speeds (macOS): from the pool's end.
    const flat = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, tokensFrom(a, &flat, &.{}, &.{}, 2));
    try std.testing.expectEqualSlices(u32, &.{0}, tokensFrom(a, &flat, &.{}, &.{}, 10));
    // Every core of two threads (burst): a reserve of 3 takes two whole cores.
    const smt = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7 };
    const smt_topo = [_]Core{
        .{ .cpu = 0, .siblings = &.{4} }, .{ .cpu = 1, .siblings = &.{5} }, .{ .cpu = 2, .siblings = &.{6} }, .{ .cpu = 3, .siblings = &.{7} },
        .{ .cpu = 4, .siblings = &.{0} }, .{ .cpu = 5, .siblings = &.{1} }, .{ .cpu = 6, .siblings = &.{2} }, .{ .cpu = 7, .siblings = &.{3} },
    };
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 4, 5 }, tokensFrom(a, &smt, &smt_topo, &.{}, 3));
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 4, 5, 6 }, tokensFrom(a, &smt, &smt_topo, &.{}, 2));
}
