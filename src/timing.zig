//! Timing windows (`--exclusive`): the noise beside one, and the jobs it lends the machine to,
//! frozen while its owner works.
const std = @import("std");
const Io = std.Io;
const state = @import("state.zig");
const sys = @import("sys.zig");

const main = @import("main.zig");
const joblog = @import("joblog.zig");
const admission = @import("admission.zig");
const runner = @import("runner.zig");
const leasing = @import("leasing.zig");
const control = @import("control.zig");

const Ctx = main.Ctx;
const stateDir = main.stateDir;
const EventExtra = joblog.EventExtra;
const lockOrFail = admission.lockOrFail;
const heldRecord = leasing.heldRecord;
const stopTree = control.stopTree;

/// CPU used beside a timing window by everything but the window's own
/// work: what disturbs its timings. Fed the process snapshots the window
/// takes anyway, so it costs no more looks; `report` says what it saw.
pub const Noise = struct {
    /// Each process's own CPU time at the last look, by pid.
    prev: std.AutoHashMapUnmanaged(i32, u64) = .empty,
    cur: std.AutoHashMapUnmanaged(i32, u64) = .empty,
    /// CPU seconds by program name, for naming the worst.
    names: std.StringHashMapUnmanaged(f64) = .empty,
    last_ms: i64 = 0,
    cpu_s: f64 = 0,
    wall_s: f64 = 0,
    peak: f64 = 0,
    warned: bool = false,

    const gpa = std.heap.page_allocator;

    /// One look. `own` marks the window's own processes (and cpuq); with
    /// `count` off, it only keeps its place (while a window lends, other
    /// work is meant to run).
    pub fn observe(n: *Noise, procs: []const sys.Proc, own: []const bool, count: bool, label: []const u8) void {
        const now = sys.monoMs();
        const first = n.last_ms == 0;
        n.cur.clearRetainingCapacity();
        var sum_ns: u64 = 0;
        var top: [3]struct { name: []const u8 = "", ns: u64 = 0 } = @splat(.{});
        for (procs, own) |p, mine| {
            if (mine) continue;
            n.cur.put(gpa, p.pid, p.own_ns) catch {};
            if (first or !count) continue;
            // A process new since the last look did all its work since.
            const d = p.own_ns -| (n.prev.get(p.pid) orelse 0);
            if (d == 0) continue;
            sum_ns += d;
            const e = n.names.getOrPut(gpa, p.name) catch continue;
            if (!e.found_existing) {
                e.key_ptr.* = gpa.dupe(u8, p.name) catch "?";
                e.value_ptr.* = 0;
            }
            e.value_ptr.* += @as(f64, @floatFromInt(d)) / 1e9;
            var i: usize = top.len;
            while (i > 0 and top[i - 1].ns < d) : (i -= 1) {
                if (i < top.len) top[i] = top[i - 1];
            }
            if (i < top.len) top[i] = .{ .name = p.name, .ns = d };
        }
        std.mem.swap(std.AutoHashMapUnmanaged(i32, u64), &n.prev, &n.cur);
        defer n.last_ms = now;
        if (first or !count) return;
        const wall = @as(f64, @floatFromInt(now - n.last_ms)) / 1000;
        if (wall <= 0) return;
        const rate = @as(f64, @floatFromInt(sum_ns)) / 1e9 / wall;
        n.cpu_s += @as(f64, @floatFromInt(sum_ns)) / 1e9;
        n.wall_s += wall;
        n.peak = @max(n.peak, rate);
        if (n.warned or rate < 1.0) return;
        n.warned = true;
        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        for (top, 0..) |t, k| if (t.ns != 0) {
            w.print("{s}{s} {d:.1}", .{ if (k != 0) ", " else "", t.name, @as(f64, @floatFromInt(t.ns)) / 1e9 / wall }) catch break;
        };
        std.debug.print("cpuq: {s}{s}work outside this timing window is using {d:.1} CPUs ({s}): its timings may be noisy\n", .{ label, if (label.len != 0) ": " else "", rate, w.buffered() });
    }

    fn mean(n: Noise) ?f64 {
        return if (n.wall_s > 0) n.cpu_s / n.wall_s else null;
    }

    /// Says how much other work ran beside the window, when it was enough
    /// to matter (half a CPU at some look), naming the busiest programs.
    pub fn report(n: *Noise, label: []const u8) void {
        const avg = n.mean() orelse return;
        if (n.peak < 0.5) return;
        var best: [3]struct { name: []const u8 = "", s: f64 = 0 } = @splat(.{});
        var it = n.names.iterator();
        while (it.next()) |e| {
            var i: usize = best.len;
            while (i > 0 and best[i - 1].s < e.value_ptr.*) : (i -= 1) {
                if (i < best.len) best[i] = best[i - 1];
            }
            if (i < best.len) best[i] = .{ .name = e.key_ptr.*, .s = e.value_ptr.* };
        }
        var buf: [256]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        for (best, 0..) |b, k| if (b.s > 0) {
            w.print("{s}{s} {d:.1}", .{ if (k != 0) ", " else "", b.name, b.s / n.wall_s }) catch break;
        };
        std.debug.print("cpuq: {s}{s}work outside this timing window used {d:.1} CPUs on average, {d:.1} at most ({s})\n", .{ label, if (label.len != 0) ": " else "", avg, n.peak, w.buffered() });
    }
};

/// Adds the window's noise to its `ended` line.
pub fn noiseInto(extra: *EventExtra) void {
    const n = runner.window_noise orelse return;
    const avg = n.mean() orelse return;
    extra.noise = @round(avg * 100) / 100;
    extra.noise_peak = @round(n.peak * 100) / 100;
}

/// Whether the timing window `window` (a lease in the cores' state) is
/// still held.
fn windowHeld(ctx: *Ctx, window: []const u8) bool {
    const path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/leases/", window }) catch return true;
    return heldRecord(ctx, path) != null;
}

/// A job frozen by a timing window stays frozen while the window works,
/// even a child that started as it froze; once the window lends again or
/// is gone (its holder killed), the job thaws itself.
pub fn keepFrozen(ctx: *Ctx, a: std.mem.Allocator, procs: []const sys.Proc, root: std.c.pid_t) void {
    const o = runner.own_lease orelse return;
    var buf: [128]u8 = undefined;
    const window = o.st.frozenBy(o.name, &buf) orelse return;
    var lend_buf: [128]u8 = undefined;
    const lending = o.st.lendingWindow(&lend_buf);
    const in_tree = a.alloc(bool, procs.len) catch return;
    @memset(in_tree, false);
    sys.markTree(procs, root, in_tree);
    if (!windowHeld(ctx, window) or (lending != null and std.mem.eql(u8, lending.?, window))) {
        for (procs, in_tree) |p, mine| if (mine) {
            _ = std.c.kill(p.pid, .CONT);
        };
        o.st.setPaused(o.name, false);
        return;
    }
    for (procs, in_tree) |p, mine| if (mine and !p.stopped) {
        _ = std.c.kill(p.pid, .STOP);
    };
}

/// Sends `sig` (STOP or CONT) to a process tree, and nothing else.
fn sendTree(a: std.mem.Allocator, procs: []const sys.Proc, root: std.c.pid_t, sig: std.c.SIG) void {
    const in_tree = a.alloc(bool, procs.len) catch return;
    @memset(in_tree, false);
    sys.markTree(procs, root, in_tree);
    for (procs, in_tree) |p, mine| if (mine) {
        _ = std.c.kill(p.pid, sig);
    };
}

/// Thaws every job the timing window `window` froze. Call with the
/// admission lock held.
fn thawFrozen(ctx: *Ctx, st: *state.State, a: std.mem.Allocator, window: []const u8) u32 {
    var procs: ?[]sys.Proc = null;
    var n: u32 = 0;
    for (state.scanLeases(st, a, false) catch &.{}) |l| {
        var buf: [128]u8 = undefined;
        const by = st.frozenBy(l.name, &buf) orelse continue;
        if (!std.mem.eql(u8, by, window)) continue;
        if (l.record.child > 0) {
            if (procs == null) procs = sys.processes(ctx.io, a);
            sendTree(a, procs.?, l.record.child, .CONT);
        }
        st.setPaused(l.name, false);
        n += 1;
    }
    return n;
}

/// Freezes every ordinary job running beside the timing window `window`:
/// they were admitted while it lent the machine, and its owner works again.
/// Ends the lending first, so nothing more starts.
fn freezeBeside(ctx: *Ctx, st: *state.State, a: std.mem.Allocator, window: []const u8) u32 {
    lockOrFail(st);
    st.setLending(null);
    var roots: std.ArrayList(std.c.pid_t) = .empty;
    const procs = sys.processes(ctx.io, a);
    for (state.scanLeases(st, a, false) catch &.{}) |l| {
        if (l.record.exclusive or l.record.hidden or st.isPaused(l.name)) continue;
        // Marked even before its command starts: the job freezes itself then.
        st.setFrozen(l.name, window);
        if (l.record.child <= 0) continue;
        sendTree(a, procs, l.record.child, .STOP);
        roots.append(a, l.record.child) catch {};
    }
    st.unlock();
    // macOS drops a SIGSTOP that lands mid-exec: look again (stopTree).
    for (roots.items) |r| stopTree(ctx, a, r);
    return @intCast(roots.items.len);
}

/// Holds a timing window that runs no command of its own (`--hold
/// --exclusive`, as a remote window is held) until its holder goes, looking
/// at the machine every few seconds. It measures the other work beside the
/// window (`Noise`), and with `window_lend` it lends the machine to waiting
/// jobs once the window's owner has done nothing for that long, freezing
/// them the moment the owner works again.
///
/// The owner's work is this user's processes that started after the window
/// opened, other than the jobs it lent to: a remote window's work arrives
/// through ssh, outside any cpuq. CPUQ_WINDOW_OWNER=PID makes it that
/// process's tree instead (a local script holding a window). Idle means under 0.1 CPU and nothing
/// waiting on a disk at every look; working again, 0.2 CPU or a process
/// waiting on a disk at a look a second apart.
pub fn watchWindow(ctx: *Ctx, st: *state.State, window: []const u8, label: []const u8) void {
    const lend_ms: i64 = if (ctx.cfg.admit == .measured) @as(i64, ctx.cfg.window_lend_s) * 1000 else 0;
    const gpa = std.heap.page_allocator;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const me = sys.getuid();
    const self = sys.getpid();
    const owner: ?i32 = if (ctx.env.get("CPUQ_WINDOW_OWNER")) |t| std.fmt.parseInt(i32, t, 10) catch null else null;
    // Whatever ran when the window opened is not its owner's work.
    var before: std.AutoHashMapUnmanaged(i32, void) = .empty;
    defer before.deinit(gpa);
    for (sys.processes(ctx.io, arena_state.allocator())) |p| before.put(gpa, p.pid, {}) catch {};
    var prev: std.AutoHashMapUnmanaged(i32, u64) = .empty;
    var cur: std.AutoHashMapUnmanaged(i32, u64) = .empty;
    defer prev.deinit(gpa);
    defer cur.deinit(gpa);
    runner.window_noise = .{};
    var lending = false;
    var lent_from: i64 = 0;
    var lent_ms: i64 = 0;
    var lends: u32 = 0;
    var frozen: u32 = 0;
    var last = sys.monoMs();
    var idle_since = last;
    const slow: i32 = if (lend_ms > 0) @intCast(std.math.clamp(@divFloor(lend_ms, 4), 500, 5000)) else 5000;
    while (!sys.StdinWatch.waitGone(runner.hold_quiet_ms, if (lending) 1000 else slow)) {
        _ = arena_state.reset(.retain_capacity);
        const a = arena_state.allocator();
        const procs = sys.processes(ctx.io, a);
        const now = sys.monoMs();
        // The jobs lent the machine, and cpuq's own processes, are not the
        // owner's work.
        const lent = a.alloc(bool, procs.len) catch continue;
        @memset(lent, false);
        lockOrFail(st);
        const leases = state.scanLeases(st, a, false) catch &.{};
        st.unlock();
        for (leases) |l| if (!l.record.exclusive) {
            sys.markTree(procs, l.record.pid, lent);
            if (l.record.child > 0) sys.markTree(procs, l.record.child, lent);
        };
        const own = a.alloc(bool, procs.len) catch continue;
        @memset(own, false);
        if (owner) |root| sys.markTree(procs, root, own);
        var own_ns: u64 = 0;
        var blocked = false;
        cur.clearRetainingCapacity();
        for (procs, own, lent) |p, *o, l| {
            cur.put(gpa, p.pid, p.own_ns) catch {};
            if (owner == null) o.* = p.uid == me and !l and !before.contains(p.pid);
            o.* = o.* or p.pid == self;
            if (!o.* or p.pid == self) continue;
            own_ns += p.own_ns -| (prev.get(p.pid) orelse 0);
            blocked = blocked or p.blocked;
        }
        std.mem.swap(std.AutoHashMapUnmanaged(i32, u64), &prev, &cur);
        const wall_s = @as(f64, @floatFromInt(@max(now - last, 1))) / 1000;
        last = now;
        const owner_cpu = @as(f64, @floatFromInt(own_ns)) / 1e9 / wall_s;
        runner.window_noise.?.observe(procs, own, !lending, label);
        if (lend_ms == 0) continue;
        if (lending) {
            if (owner_cpu < 0.2 and !blocked) continue;
            lending = false;
            lent_ms += now - lent_from;
            idle_since = now;
            frozen += freezeBeside(ctx, st, a, window);
        } else if (owner_cpu >= 0.1 or blocked) {
            idle_since = now;
        } else if (now - idle_since >= lend_ms) {
            lockOrFail(st);
            _ = thawFrozen(ctx, st, a, window);
            st.setLending(window);
            st.unlock();
            lending = true;
            lent_from = now;
            lends += 1;
            if (lends == 1) std.debug.print("cpuq: {s}{s}the timing window is idle: lending the machine to waiting jobs, which freeze the moment it is used again\n", .{ label, if (label.len != 0) ": " else "" });
        }
    }
    if (lending) lent_ms += sys.monoMs() - lent_from;
    lockOrFail(st);
    var lend_buf: [128]u8 = undefined;
    if (st.lendingWindow(&lend_buf)) |w| if (std.mem.eql(u8, w, window)) st.setLending(null);
    _ = thawFrozen(ctx, st, arena_state.allocator(), window);
    st.unlock();
    if (lends > 0) std.debug.print("cpuq: {s}{s}lent the machine {d} {s}, {d:.0} s in all; froze {d} {s} when the window was used again\n", .{
        label,                                   if (label.len != 0) ": " else "",
        lends,                                   if (lends == 1) "time" else "times",
        @as(f64, @floatFromInt(lent_ms)) / 1000, frozen,
        if (frozen == 1) "job" else "jobs",
    });
    runner.window_noise.?.report(label);
}
