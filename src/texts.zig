//! Short text for people: sizes, durations, ordinals, the gate, padded fields.
const std = @import("std");
const policy = @import("policy.zig");

/// Bytes as a short size: 340M, 1.2G.
pub fn bytesText(buf: []u8, n: u64) []const u8 {
    const f: f64 = @floatFromInt(n);
    if (f >= 1 << 30) return std.mem.print(buf, "{d:.1}G", .{f / (1 << 30)}) catch "?";
    return std.mem.print(buf, "{d:.0}M", .{f / (1 << 20)}) catch "?";
}

pub fn className(class: u2) []const u8 {
    return switch (class) {
        0 => "high",
        1 => "normal",
        else => "low",
    };
}

pub fn ordinal(buf: []u8, n: usize) []const u8 {
    const suffix = if (n % 100 >= 11 and n % 100 <= 13) "th" else switch (n % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
    return std.mem.print(buf, "{d}{s}", .{ n, suffix }) catch "?";
}

/// A duration: tenths of a second under 10 s, else as `age` puts it.
pub fn duration(buf: []u8, seconds: f64) []const u8 {
    if (seconds < 10) return std.mem.print(buf, "{d:.1}s", .{@max(seconds, 0)}) catch "?";
    return age(buf, @intFromFloat(seconds));
}

pub fn age(buf: []u8, seconds: i64) []const u8 {
    const s = @max(seconds, 0);
    if (s < 60) return std.mem.print(buf, "{d}s", .{s}) catch "?";
    if (s < 3600) return std.mem.print(buf, "{d}m{d:0>2}s", .{ @divTrunc(s, 60), @mod(s, 60) }) catch "?";
    return std.mem.print(buf, "{d}h{d:0>2}m", .{ @divTrunc(s, 3600), @divTrunc(@mod(s, 3600), 60) }) catch "?";
}

pub fn gateText(buf: []u8, g: policy.Gate, budget: u32) []const u8 {
    return switch (g) {
        .open => "open",
        .pressure => "closed: memory pressure",
        .low_memory => |av| std.mem.print(buf, "closed: memory low ({d:.1} GB available)", .{@as(f64, @floatFromInt(av)) / (1 << 30)}) catch "closed: memory low",
        .low_disk => |d| std.mem.print(buf, "closed: disk low ({d:.1} GB free on {s})", .{ @as(f64, @floatFromInt(d.free)) / (1 << 30), d.path }) catch "closed: disk low",
        .load => |l| std.mem.print(buf, "closed: load {d:.1} (valve tripped; budget {d})", .{ l, budget }) catch "closed: load",
        .spacing => |l| std.mem.print(buf, "spacing admissions: load {d:.1} over budget {d}", .{ l, budget }) catch "spacing",
    };
}

/// `s` left-aligned in a field of `width` (a longer `s` is cut to fit).
pub fn pad(buf: []u8, s: []const u8, width: usize) []const u8 {
    const w = @min(width, buf.len);
    const n = @min(s.len, w);
    @memcpy(buf[0..n], s[0..n]);
    @memset(buf[n..w], ' ');
    return buf[0..w];
}

pub fn dash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}
