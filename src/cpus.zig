//! The pool's CPUs, and in what order: tokens are its first CPUs (the reserve is its last, never
//! handed out), a task takes the first free token, and a drain isolates CPUs from the tokens' end. Every cpuq on the machine works the list out the
//! same way, so they agree on it.
//!
//! - `cpus = LIST` in the config (a Linux CPU list, "12-19,2") is the pool, in that order.
//! - Otherwise, Linux: the CPUs online, less those isolated from the scheduler, within the CPUs
//!   the machine's init may use (a container's CPU set), one hyperthread of each physical core
//!   first, then their siblings. macOS: 0 to the active CPU count less one (it cannot pin, so
//!   the numbers only count).
//! - `reserve = N` keeps the last N out of the tokens (pool.tokens).
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

/// `cpus` fastest first (Linux): a hybrid CPU's performance cores (`/sys/devices/cpu_core/cpus`)
/// before its efficiency cores, then by `cpu_capacity`, then by top clock (`cpuinfo_max_freq`),
/// else in their order. Elsewhere as they are.
pub fn fastFirst(io: Io, a: std.mem.Allocator, cpus: []const u32) []const u32 {
    const out = a.dupe(u32, cpus) catch return cpus;
    if (builtin.os.tag != .linux) return out;
    const p_cores = policy.cpuList(a, std.mem.trim(u8, readSmall(io, a, "/sys/devices/cpu_core/cpus"), " \n")) catch &.{};
    const Key = struct { cpu: u32, p: bool, cap: u64, freq: u64, at: usize };
    const keys = a.alloc(Key, out.len) catch return out;
    for (out, keys, 0..) |c, *k, i| {
        const num = struct {
            fn of(io2: Io, a2: std.mem.Allocator, cpu: u32, file: []const u8) u64 {
                const path = std.fmt.allocPrint(a2, "/sys/devices/system/cpu/cpu{d}/{s}", .{ cpu, file }) catch return 0;
                return std.fmt.parseInt(u64, std.mem.trim(u8, readSmall(io2, a2, path), " \n"), 10) catch 0;
            }
        };
        k.* = .{
            .cpu = c,
            .p = std.mem.findScalar(u32, p_cores, c) != null,
            .cap = num.of(io, a, c, "cpu_capacity"),
            .freq = num.of(io, a, c, "cpufreq/cpuinfo_max_freq"),
            .at = i,
        };
    }
    std.mem.sort(Key, keys, {}, struct {
        fn faster(_: void, x: Key, y: Key) bool {
            if (x.p != y.p) return x.p;
            if (x.cap != y.cap) return x.cap > y.cap;
            if (x.freq != y.freq) return x.freq > y.freq;
            return x.at < y.at;
        }
    }.faster);
    for (out, keys) |*c, k| c.* = k.cpu;
    return out;
}
