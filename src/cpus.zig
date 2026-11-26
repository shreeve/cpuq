//! The pool's CPUs: which of this machine's CPUs cpuq hands out, and in what order. Every cpuq
//! on the machine works the list out the same way, so they agree on it.
//!
//! - `cpus = LIST` in the config (a Linux CPU list, "12-19,2") is the pool, in that order.
//! - Otherwise, Linux: the CPUs online, less those isolated from the scheduler, within the CPUs
//!   the machine's init may use (a container's CPU set), one hyperthread of each physical core
//!   first, then their siblings. macOS: 0 to the active CPU count less one (it cannot pin, so
//!   the numbers only name slots).
//! - `budget = N` (or CPUQ_BUDGET) keeps the first N.
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const policy = @import("policy.zig");
const sys = @import("sys.zig");

pub fn list(io: Io, a: std.mem.Allocator, configured: ?[]const u8, budget: ?u32) []const u32 {
    var cpus: []const u32 = if (configured) |text|
        policy.cpuList(a, text) catch &.{}
    else if (builtin.os.tag == .linux) linuxOrder(io, a) else &.{};
    if (cpus.len == 0) {
        const n = sys.activeCpus(io);
        const all = a.alloc(u32, n) catch return &.{0};
        for (all, 0..) |*c, i| c.* = @intCast(i);
        cpus = all;
    }
    if (budget) |b| if (b >= 1 and b < cpus.len) return cpus[0..b];
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
