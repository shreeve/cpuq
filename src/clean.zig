//! `cpuq clean`: what jobs left on a host and no longer use, removed once unused for
//! `clean_after` (3 days by default):
//!
//! - copies of repos sent from other machines (~/cpuq/worktrees/PROJECT/NAME), by when a job
//!   last ran in one (`.cpuq-used`, a `cpuq run --on`'s) or last synced it (`.cpuq-generation`, a
//!   submitted job's), never while a job holds one's lock;
//! - submitted jobs' scratch (~/cpuq/tmp/ID) that outlived them;
//! - pack versions (~/cpuq/packs/NAME/VERSION), by when a job last used one, never one that
//!   `latest` or `stable` names;
//! - submitted jobs' records (~/.local/state/cpuq/jobs/ID), a week after they ended.
//!
//! Never anything a process is working in. Caches (~/cpuq/caches) are the jobs' own to bound.
//! `cpuq record` runs it hourly; `cpuq clean --dry-run` says what it would remove.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const layout = @import("layout.zig");

pub const Options = struct {
    /// Unused this long (seconds) and it goes.
    older_s: i64,
    dry_run: bool = false,
};

const Cx = struct {
    a: std.mem.Allocator,
    io: Io,
    now: i64,
    o: Options,
    out: *Io.Writer,
    /// Where processes are working (Linux: /proc/PID/cwd), so nothing in use goes.
    cwds: []const []const u8,
    removed: u32 = 0,
    bytes: u64 = 0,
    kept: u32 = 0,
};

/// Cleans this machine's leftovers; the number of things removed (or that would be).
pub fn run(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, now: i64, o: Options, out: *Io.Writer) u32 {
    const home = env.get("HOME") orelse return 0;
    var cx: Cx = .{ .a = a, .io = io, .now = now, .o = o, .out = out, .cwds = workingDirs(a, io) };
    const state = if (env.get("XDG_STATE_HOME")) |x| a.print("{s}/cpuq/jobs", .{x}) catch return 0 else a.print("{s}/.local/state/cpuq/jobs", .{home}) catch return 0;
    worktrees(&cx, a.print("{s}/{s}", .{ home, layout.worktrees }) catch return 0);
    scratch(&cx, a.print("{s}/{s}", .{ home, layout.tmp }) catch return 0, state);
    packs(&cx, a.print("{s}/{s}", .{ home, layout.packs }) catch return 0);
    records(&cx, state);
    if (cx.removed != 0 or o.dry_run)
        out.print("cpuq clean: {s} {d} ({s}){s}\n", .{ if (o.dry_run) "would remove" else "removed", cx.removed, size(a, cx.bytes), if (cx.kept != 0) a.print("; {d} kept in use", .{cx.kept}) catch "" else "" }) catch {};
    out.flush() catch {};
    return cx.removed;
}

/// ~/cpuq/worktrees/PROJECT/NAME: by the later of its markers, `.cpuq-used` (each `cpuq run --on`
/// touches it) and `.cpuq-generation` (each submitted job's sync writes it), else by when it
/// changed; never while its lock (NAME.lock, a submitted job's) is held.
fn worktrees(cx: *Cx, root: []const u8) void {
    for (children(cx, root, .directory)) |project| {
        const pdir = cx.a.print("{s}/{s}", .{ root, project }) catch continue;
        for (children(cx, pdir, .directory)) |name| {
            const dir = cx.a.print("{s}/{s}", .{ pdir, name }) catch continue;
            const lock = cx.a.print("{s}.lock", .{dir}) catch continue;
            if (locked(cx, lock)) {
                cx.kept += 1;
                continue;
            }
            const used = @max(touched(cx, dir, ".cpuq-used"), touched(cx, dir, ".cpuq-generation"));
            consider(cx, dir, if (used != 0) used else changed(cx, dir), &.{lock});
        }
        removeIfEmpty(cx, pdir);
    }
}

/// ~/cpuq/tmp/ID: a submitted job's TMPDIR, which it removes when it ends; one left by a job
/// that was killed goes by when it changed, never while that job's record says it runs.
fn scratch(cx: *Cx, root: []const u8, jobs: []const u8) void {
    for (children(cx, root, .directory)) |id| {
        if (locked(cx, cx.a.print("{s}/{s}/running.lock", .{ jobs, id }) catch continue)) continue;
        const dir = cx.a.print("{s}/{s}", .{ root, id }) catch continue;
        consider(cx, dir, changed(cx, dir), &.{});
    }
}

/// ~/cpuq/packs/NAME/VERSION: by its `.cpuq-used` (each job using it touches it), else when it
/// was installed; never one a link (latest, stable) names, nor one being installed.
fn packs(cx: *Cx, root: []const u8) void {
    for (children(cx, root, .directory)) |name| {
        const ndir = cx.a.print("{s}/{s}", .{ root, name }) catch continue;
        var named: std.ArrayList([]const u8) = .empty;
        var d = Io.Dir.cwd().openDir(cx.io, ndir, .{ .iterate = true }) catch continue;
        defer d.close(cx.io);
        var it = d.iterate();
        while (it.next(cx.io) catch null) |e| if (e.kind == .sym_link) {
            var buf: [256]u8 = undefined;
            const n = d.readLink(cx.io, e.name, &buf) catch continue;
            named.append(cx.a, cx.a.dupe(u8, std.mem.trimEnd(u8, buf[0..n], "/")) catch continue) catch {};
        };
        for (children(cx, ndir, .directory)) |version| {
            if (version[0] == '.') continue;
            var is_named = false;
            for (named.items) |v| if (std.mem.eql(u8, v, version)) {
                is_named = true;
            };
            const lock = cx.a.print("{s}/.{s}.lock", .{ ndir, version }) catch continue;
            if (is_named or locked(cx, lock)) continue;
            const dir = cx.a.print("{s}/{s}", .{ ndir, version }) catch continue;
            const used = lastUse(cx, dir, ".cpuq-used");
            consider(cx, dir, if (used != 0) used else lastUse(cx, dir, ".cpuq-installed"), &.{lock});
        }
    }
}

/// Submitted jobs' records: a week after they last changed, once no job runs from one.
fn records(cx: *Cx, root: []const u8) void {
    const week: i64 = 7 * 86400;
    for (children(cx, root, .directory)) |id| {
        const dir = cx.a.print("{s}/{s}", .{ root, id }) catch continue;
        if (locked(cx, cx.a.print("{s}/running.lock", .{dir}) catch continue)) continue;
        const age = cx.now - changed(cx, dir);
        if (age < @max(cx.o.older_s, week)) continue;
        if (!cx.o.dry_run) Io.Dir.cwd().deleteTree(cx.io, dir) catch continue;
        cx.removed += 1;
    }
}

/// Removes `dir` (and `also`) when it's been unused long enough and no process works in it.
fn consider(cx: *Cx, dir: []const u8, used: i64, also: []const []const u8) void {
    if (used == 0 or cx.now - used < cx.o.older_s) return;
    for (cx.cwds) |w| if (std.mem.eql(u8, w, dir) or (std.mem.startsWith(u8, w, dir) and w.len > dir.len and w[dir.len] == '/')) {
        cx.kept += 1;
        return;
    };
    const bytes = du(cx, dir);
    cx.out.print("  {s} {s}  (unused {s}, {s})\n", .{ if (cx.o.dry_run) "would remove" else "removed", dir, days(cx.a, cx.now - used), size(cx.a, bytes) }) catch {};
    cx.removed += 1;
    cx.bytes += bytes;
    if (cx.o.dry_run) return;
    Io.Dir.cwd().deleteTree(cx.io, dir) catch {};
    for (also) |f| Io.Dir.cwd().deleteFile(cx.io, f) catch {};
}

fn children(cx: *Cx, dir: []const u8, kind: Io.File.Kind) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(cx.io, dir, .{ .iterate = true }) catch return &.{};
    defer d.close(cx.io);
    var it = d.iterate();
    while (it.next(cx.io) catch null) |e| if (e.kind == kind) out.append(cx.a, cx.a.dupe(u8, e.name) catch continue) catch {};
    return out.items;
}

/// When a marker inside `dir` was last touched (seconds), else when `dir` itself changed.
fn lastUse(cx: *Cx, dir: []const u8, marker: []const u8) i64 {
    const t = touched(cx, dir, marker);
    return if (t != 0) t else changed(cx, dir);
}

/// When a marker inside `dir` was last touched (seconds); 0 when it isn't there.
fn touched(cx: *Cx, dir: []const u8, marker: []const u8) i64 {
    const path = cx.a.print("{s}/{s}", .{ dir, marker }) catch return 0;
    const st = Io.Dir.cwd().statFile(cx.io, path, .{}) catch return 0;
    return @intCast(@divTrunc(st.mtime.nanoseconds, std.time.ns_per_s));
}

/// When `dir` itself last changed (its ctime: a sync setting its times, an entry added).
fn changed(cx: *Cx, dir: []const u8) i64 {
    const st = Io.Dir.cwd().statFile(cx.io, dir, .{}) catch return 0;
    return @intCast(@divTrunc(@max(st.ctime.nanoseconds, st.mtime.nanoseconds), std.time.ns_per_s));
}

/// Whether another process holds `path`'s lock (a job on that copy, a pack being installed).
fn locked(cx: *Cx, path: []const u8) bool {
    const f = Io.Dir.cwd().openFile(cx.io, path, .{}) catch return false;
    defer f.close(cx.io);
    const free = f.tryLock(cx.io, .exclusive) catch return true;
    if (free) f.unlock(cx.io);
    return !free;
}

fn removeIfEmpty(cx: *Cx, dir: []const u8) void {
    if (cx.o.dry_run) return;
    Io.Dir.cwd().deleteDir(cx.io, dir) catch {};
}

/// The working directories of this machine's processes (Linux); empty elsewhere.
fn workingDirs(a: std.mem.Allocator, io: Io) []const []const u8 {
    if (builtin.os.tag != .linux) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var d = Io.Dir.cwd().openDir(io, "/proc", .{ .iterate = true }) catch return &.{};
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .directory or !std.ascii.isDigit(e.name[0])) continue;
        var buf: [4096]u8 = undefined;
        const n = d.readLink(io, a.print("{s}/cwd", .{e.name}) catch continue, &buf) catch continue;
        out.append(a, a.dupe(u8, buf[0..n]) catch continue) catch {};
    }
    return out.items;
}

fn du(cx: *Cx, dir: []const u8) u64 {
    const r = std.process.run(cx.a, cx.io, .{ .argv = &.{ "du", "-sk", dir } }) catch return 0;
    const kb = std.fmt.parseInt(u64, std.mem.sliceTo(r.stdout, '\t'), 10) catch return 0;
    return kb * 1024;
}

fn size(a: std.mem.Allocator, bytes: u64) []const u8 {
    const g = @as(f64, @floatFromInt(bytes)) / (1 << 30);
    if (g >= 1) return a.print("{d:.1}G", .{g}) catch "?";
    return a.print("{d}M", .{bytes >> 20}) catch "?";
}

fn days(a: std.mem.Allocator, s: i64) []const u8 {
    if (s >= 86400) return a.print("{d}d", .{@divTrunc(s, 86400)}) catch "?";
    return a.print("{d}h", .{@divTrunc(s, 3600)}) catch "?";
}
