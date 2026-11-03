//! `cpuq status`: this machine's and other hosts', as JSON or as boxed tables.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");
const table = @import("table.zig");

const main = @import("main.zig");
const texts = @import("texts.zig");
const admission = @import("admission.zig");
const leasing = @import("leasing.zig");
const control = @import("control.zig");
const records = @import("records.zig");
const runtimes = @import("runtimes.zig");
const statusjson = @import("statusjson.zig");
const jobs_mod = @import("jobs.zig");

const version = main.version;
const exit_failure = main.exit_failure;
const Ctx = main.Ctx;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const openState = main.openState;
const machine = main.machine;
const budgetNow = main.budgetNow;
const age = texts.age;
const gateText = texts.gateText;
const pad = texts.pad;
const dash = texts.dash;
const lockOrFail = admission.lockOrFail;
const targetCpus = admission.targetCpus;
const servedOrder = admission.servedOrder;
const openNamed = leasing.openNamed;
const namedLeases = control.namedLeases;
const recorderRunning = records.recorderRunning;
const RunTimes = runtimes.RunTimes;
const estimate = runtimes.estimate;
const estimateIn = runtimes.estimateIn;
const JsonHolder = statusjson.JsonHolder;
const readProgress = statusjson.readProgress;
const JsonWaiter = statusjson.JsonWaiter;
const JsonLease = statusjson.JsonLease;
const toHolders = statusjson.toHolders;
const toWaiters = statusjson.toWaiters;
const JsonStatus = statusjson.JsonStatus;
const JsonOutside = statusjson.JsonOutside;

/// How long a job has run, with how far it has got and how long it has left when known:
/// "12m · 4210/12629 33% · ~9m left", or "12m · ~34m left" from its label's history.
fn sinceText(a: std.mem.Allocator, h: JsonHolder, now: i64) []const u8 {
    var b: [16]u8 = undefined;
    const ran = age(&b, now - h.since);
    const how = progressText(a, h);
    if (how.len == 0) return a.dupe(u8, ran) catch "?";
    return a.print("{s} · {s}", .{ ran, how }) catch "?";
}

/// How far a running job is, "4210/12629 33% · 3 failing · ~9m left" from its own
/// count, "~9m left" from its label's history; "" when neither is known.
fn progressText(a: std.mem.Allocator, h: JsonHolder) []const u8 {
    var lb: [16]u8 = undefined;
    const left = if (h.left) |l| a.print("~{s} left", .{age(&lb, @intFromFloat(l))}) catch "" else "";
    if (h.progress) |p| {
        const pct = p.done * 100 / @max(p.total, 1);
        const failing = if (p.failing != 0) a.print(" · {d} failing", .{p.failing}) catch "" else "";
        return a.print("{d}/{d} {d}%{s}{s}{s}", .{ p.done, p.total, pct, failing, if (left.len != 0) " · " else "", left }) catch "";
    }
    // From history alone: an estimate, so it says what it's from.
    const typical = h.typical orelse return "";
    var tb: [16]u8 = undefined;
    const usual = age(&tb, @intFromFloat(typical));
    if (h.left) |l| if (l >= 1) return a.print("{s} (usually {s})", .{ left, usual }) catch "";
    return a.print("over its usual {s}", .{usual}) catch "";
}

/// A label with its note after it, when it has one: "rig:corpus  #224 markers".
fn withNote(a: std.mem.Allocator, label: []const u8, why: []const u8) []const u8 {
    if (why.len == 0) return dash(label);
    return a.print("{s}  {s}", .{ dash(label), why }) catch dash(label);
}

const StatusView = struct {
    /// The cores use is counted against: under measured admission the CPUs
    /// online (`budget` there only sizes an exclusive run, and may be set
    /// above the CPU count); under `admit = cores`, the budget.
    budget: u32,
    /// Whether `budget` is the CPUs online (measured admission).
    cpus: bool = false,
    held: u32,
    load: [3]f64,
    pressure: policy.Pressure,
    gate: policy.Gate,
    gate_text: []const u8,
    holders: []const JsonHolder,
    waiters: []const JsonWaiter,
    leases: []const JsonLease,
    outside: []const JsonOutside,
    now: i64,
    /// The CPUs online: what the load is measured against.
    online: u32 = 0,
    /// Memory and swap, when readable.
    memory: ?sys.Memory = null,
    /// For another host's status: its name and its cpuq's version.
    host: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

/// Whether outside load is worth showing: a core or more of it, or a gate
/// that is not open.
fn showOutside(outside: []const JsonOutside, g: policy.Gate) bool {
    if (outside.len == 0) return false;
    var total: f64 = 0;
    for (outside) |o| total += o.using;
    return total >= 1.0 or g != .open;
}

/// The load averages: the 1-minute one bold, in green under half the CPUs
/// online, yellow up to one and a half times them, red beyond; the 5-minute
/// one plain and the 15-minute one dim, fading with age.
fn loadCell(a: std.mem.Allocator, load: [3]f64, online: u32) table.Cell {
    const cpus: f64 = @floatFromInt(@max(online, 1));
    const tint: table.Tint = if (load[0] < 0.5 * cpus) .good else if (load[0] <= 1.5 * cpus) .warn else .bad;
    const now = a.print("{d:.1}", .{load[0]}) catch "?";
    const five = a.print(" {d:.1}", .{load[1]}) catch "";
    const fifteen = a.print(" {d:.1}", .{load[2]}) catch "";
    return .{
        .text = std.mem.concat(a, u8, &.{ now, five, fifteen }) catch now,
        .parts = a.dupe(table.Part, &.{
            .{ .text = now, .tint = tint, .bold = true },
            .{ .text = five },
            .{ .text = fifteen, .tint = .dim },
        }) catch null,
    };
}

/// `cpuq status` on a terminal: boxed tables, colored unless NO_COLOR is set.
fn statusBoxed(ctx: *Ctx, v: StatusView) void {
    const a = ctx.arena;
    const w = ctx.out;
    const color = ctx.env.get("NO_COLOR") == null;
    const width = table.terminalWidth(1);
    var host_buf: [256]u8 = undefined;
    const host = if (std.c.gethostname(&host_buf, host_buf.len) == 0) std.mem.sliceTo(&host_buf, 0) else "";
    const short_host = v.host orelse std.mem.sliceTo(host, '.');
    const C = table.Cell;

    // Memory in use, tinted by the kernel's pressure; the word alone when it cannot be read.
    const mem: C = if (v.memory) |m| .{
        .text = a.print("{s}{s}", .{ ofGb(a, m.used, m.total), if (v.pressure == .high) ", pressure" else "" }) catch "?",
        .tint = switch (v.pressure) {
            .normal => .good,
            .high => .bad,
            .unknown, .off => null,
        },
    } else switch (v.pressure) {
        .normal => .{ .text = "normal", .tint = .good },
        .high => .{ .text = "pressure", .tint = .bad },
        .unknown => .{ .text = "unknown", .tint = .dim },
        .off => .{ .text = "off", .tint = .dim },
    };
    const swap: C = if (v.memory) |m| (if (m.swap_total == 0)
        .{ .text = "none", .tint = .dim }
    else
        .{ .text = ofGb(a, m.swap_used, m.swap_total), .tint = if (m.swap_used * 2 > m.swap_total) .warn else null }) else .{ .text = "-", .tint = .dim };
    const gate: C = .{ .text = switch (v.gate) {
        .open => "open",
        .pressure => "closed: memory",
        .low_memory => |av| a.print("closed: {d:.1} GB free", .{@as(f64, @floatFromInt(av)) / (1 << 30)}) catch "closed: memory",
        .low_disk => |d| a.print("closed: disk {d:.1} GB", .{@as(f64, @floatFromInt(d.free)) / (1 << 30)}) catch "closed: disk",
        .load => |l| a.print("closed: load {d:.1}", .{l}) catch "closed",
        .spacing => |l| a.print("spacing: load {d:.1}", .{l}) catch "spacing",
    }, .tint = switch (v.gate) {
        .open => .good,
        .spacing => .warn,
        .load, .pressure, .low_memory, .low_disk => .bad,
    } };
    const free = v.budget -| v.held;
    const summary: table.Table = .{
        .title = a.print("cpuq {s}{s}{s}", .{ v.version orelse version, if (short_host.len != 0) " · " else "", short_host }) catch "cpuq",
        .columns = &.{
            .{ .head = if (v.cpus) "CPUS" else "BUDGET", .alignment = .right },
            .{ .head = "IN USE", .alignment = .right },
            .{ .head = "FREE", .alignment = .right },
            .{ .head = "LOAD", .sub = "1 5 15" },
            .{ .head = "MEMORY" },
            .{ .head = "SWAP" },
            .{ .head = "GATE" },
        },
        .rows = &.{&.{
            .{ .text = a.print("{d}", .{v.budget}) catch "?" },
            .{ .text = a.print("{d}", .{v.held}) catch "?", .tint = if (v.held != 0) .accent else null },
            .{ .text = a.print("{d}", .{free}) catch "?", .tint = if (free == 0) .warn else .good },
            loadCell(a, v.load, v.online),
            mem,
            swap,
            gate,
        }},
    };
    summary.boxed(a, w, width, color) catch {};

    if (v.holders.len != 0) {
        var rows: std.ArrayList([]const C) = .empty;
        for (v.holders) |h| {
            const using: C = if (h.using) |u| .{
                .text = a.print("{d:.1}", .{u}) catch "?",
                // Using less than half the grant: the request is too big.
                .tint = if (h.cores >= 2 and u * 2 < @as(f64, @floatFromInt(h.cores))) .warn else null,
            } else .{ .text = "-", .tint = .dim };
            rows.append(a, a.dupe(C, &.{
                .{ .text = withNote(a, h.label, h.note), .tint = .accent },
                .{ .text = a.print("{d}", .{h.cores}) catch "?" },
                using,
                .{ .text = if (h.exclusive) "exclusive" else h.priority, .tint = if (h.exclusive) .warn else null },
                .{ .text = sinceText(a, h, v.now) },
                .{ .text = a.print("{d}{s}", .{ h.pid, if (h.holder_alive) "" else "*" }) catch "?", .tint = .dim },
                .{ .text = h.command },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("in use: {d} of {d} {s}", .{ v.held, v.budget, if (v.cpus) "CPUs" else "cores" }) catch "in use",
            .columns = &.{
                .{ .head = "LABEL" },
                .{ .head = "IN USE", .alignment = .right },
                .{ .head = "ACTIVE", .alignment = .right },
                .{ .head = "PRIO" },
                .{ .head = "SINCE" },
                .{ .head = "PID", .alignment = .right },
                .{ .head = "COMMAND", .flexible = true },
            },
            .rows = rows.items,
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    if (v.waiters.len != 0) {
        var rows: std.ArrayList([]const C) = .empty;
        for (v.waiters) |q| {
            var b: [16]u8 = undefined;
            const prio = if (q.exclusive) "exclusive" else if (std.mem.eql(u8, q.class, q.priority)) q.priority else a.print("{s}>{s}", .{ q.priority, q.class }) catch q.priority;
            rows.append(a, a.dupe(C, &.{
                .{ .text = a.print("{d}", .{q.order}) catch "?", .tint = .dim },
                .{ .text = withNote(a, q.label, q.note), .tint = .accent },
                .{ .text = if (q.max > q.cores) a.print("{d}-{d}", .{ q.cores, q.max }) catch "?" else a.print("{d}", .{q.cores}) catch "?" },
                .{ .text = prio },
                .{ .text = a.dupe(u8, age(&b, v.now - q.since)) catch "?" },
                if (q.eta) |e| (if (e < 1) C{ .text = "now", .tint = .good } else C{ .text = a.print("~{s}", .{age(&b, @intFromFloat(e))}) catch "?" }) else C{ .text = "?", .tint = .dim },
                .{ .text = q.command },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("waiting ({d})", .{v.waiters.len}) catch "waiting",
            .columns = &.{
                .{ .head = "#", .alignment = .right },
                .{ .head = "LABEL" },
                .{ .head = "CORES", .alignment = .right },
                .{ .head = "PRIO" },
                .{ .head = "WAITING" },
                .{ .head = "ETA" },
                .{ .head = "COMMAND", .flexible = true },
            },
            .rows = rows.items,
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    if (v.leases.len != 0) {
        var rows: std.ArrayList([]const C) = .empty;
        for (v.leases) |l| {
            var held_by: std.ArrayList(u8) = .empty;
            for (l.holders, 0..) |h, k| {
                var b: [16]u8 = undefined;
                held_by.print(a, "{s}{s} ({s})", .{ if (k == 0) "" else ", ", dash(h.label), age(&b, v.now - h.since) }) catch {};
            }
            var next: std.ArrayList(u8) = .empty;
            for (l.waiters, 0..) |q, k| next.print(a, "{s}{s}", .{ if (k == 0) "" else ", ", dash(q.label) }) catch {};
            rows.append(a, a.dupe(C, &.{
                .{ .text = l.name, .tint = .accent },
                .{ .text = if (held_by.items.len != 0) held_by.items else "free", .tint = if (held_by.items.len != 0) null else .good },
                .{ .text = a.print("{d}", .{l.waiters.len}) catch "?" },
                .{ .text = if (next.items.len != 0) next.items else "-", .tint = if (next.items.len != 0) null else .dim },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = "leases",
            .columns = &.{
                .{ .head = "NAME" },
                .{ .head = "HELD BY" },
                .{ .head = "WAITING", .alignment = .right },
                .{ .head = "NEXT", .flexible = true },
            },
            .rows = rows.items,
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    if (showOutside(v.outside, v.gate)) {
        var rows: std.ArrayList([]const C) = .empty;
        var total: f64 = 0;
        for (v.outside) |o| {
            total += o.using;
            rows.append(a, a.dupe(C, &.{
                .{ .text = o.name, .tint = .accent },
                .{ .text = a.print("{d}", .{o.pid}) catch "?", .tint = .dim },
                .{ .text = a.print("{d:.1}", .{o.using}) catch "?", .tint = if (o.using >= 1) .warn else null },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("outside cpuq: {d:.1} cores active", .{total}) catch "outside cpuq",
            .columns = &.{ .{ .head = "PROCESS", .flexible = true }, .{ .head = "PID", .alignment = .right }, .{ .head = "ACTIVE", .alignment = .right } },
            .rows = rows.items,
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    // Notes: each project's share (labels before their first ':'), and where
    // to look next.
    var notes: std.ArrayList([]const u8) = .empty;
    if (v.holders.len != 0) {
        var groups: std.StringArrayHashMapUnmanaged(u32) = .empty;
        for (v.holders) |h| {
            const key = if (h.label.len == 0) "-" else std.mem.sliceTo(h.label, ':');
            const gop = groups.getOrPut(a, key) catch continue;
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += h.cores;
        }
        var line: std.ArrayList(u8) = .empty;
        line.appendSlice(a, "cores in use by project:") catch {};
        for (groups.keys(), groups.values(), 0..) |k, n, i| line.print(a, "{s} {s} {d}", .{ if (i == 0) "" else " ·", k, n }) catch {};
        notes.append(a, line.items) catch {};
    }
    if (v.holders.len == 0 and v.waiters.len == 0 and v.leases.len == 0) notes.append(a, "nothing in use or waiting") catch {};
    notes.append(a, "past jobs: cpuq history · for scripts: cpuq status --json") catch {};
    if (ctx.watch_note) |n| notes.append(a, n) catch {};
    w.writeAll("\n") catch {};
    for (notes.items) |n| {
        w.writeAll("  ") catch {};
        if (color) w.print("\x1b[2m{s}\x1b[0m\n", .{n}) catch {} else w.print("{s}\n", .{n}) catch {};
    }
}

/// How long `cpuq status` watches the holders to measure their use.
const sample_ms = 500;

const Sample = struct {
    /// Cores each lease's command keeps busy; null for one with no command.
    busy: []?f64,
    /// CPUs each job's driver tree keeps busy, as `drivers` lists them.
    jobs: []f64 = &.{},
    /// The busiest processes outside every cpuq job, busiest first.
    outside: []JsonOutside = &.{},
    /// CPUs busy outside every cpuq job, all of them (not only the five listed).
    outside_total: f64 = 0,
};

/// Watches every process for `sample_ms`: what each lease's command tree and each job's driver
/// tree keep busy, and the busiest processes no cpuq job accounts for. Nothing is sampled when
/// `measure` is off.
pub fn sample(io: Io, a: std.mem.Allocator, leases: []const state.Entry, drivers: []const i32, measure: bool) Sample {
    const busy = nullUsage(a, leases.len);
    if (!measure) return .{ .busy = busy };
    const t0 = Io.Clock.awake.now(io);
    const before = sys.processes(io, a);
    io.sleep(.fromMilliseconds(sample_ms), .awake) catch {};
    const after = sys.processes(io, a);
    const wall_ns: f64 = @floatFromInt(t0.durationTo(Io.Clock.awake.now(io)).toNanoseconds());
    if (wall_ns <= 0) return .{ .busy = busy };
    for (leases, busy) |l, *u| {
        if (l.record.child <= 0) continue;
        const used = sys.treeCpu(after, l.record.child) -| sys.treeCpu(before, l.record.child);
        u.* = @as(f64, @floatFromInt(used)) / wall_ns;
    }
    const jobs = a.alloc(f64, drivers.len) catch return .{ .busy = busy };
    for (drivers, jobs) |pid, *u| {
        const used = sys.treeCpu(after, pid) -| sys.treeCpu(before, pid);
        u.* = @as(f64, @floatFromInt(used)) / wall_ns;
    }
    // Everything else: cpuq's jobs (their cpuq and command trees) and this
    // process are accounted for; what is left is outside load.
    const in_job = a.alloc(bool, after.len) catch return .{ .busy = busy };
    @memset(in_job, false);
    for (leases) |l| {
        sys.markTree(after, l.record.pid, in_job);
        if (l.record.child > 0) sys.markTree(after, l.record.child, in_job);
    }
    for (drivers) |pid| sys.markTree(after, pid, in_job);
    // A process's own CPU only: its reaped children were counted while they
    // ran (see sys.Proc.own_ns).
    var cpu_before: std.AutoHashMapUnmanaged(i32, u64) = .empty;
    for (before) |p| cpu_before.put(a, p.pid, p.own_ns) catch {};
    const self = sys.getpid();
    var outside: std.ArrayList(JsonOutside) = .empty;
    for (after, 0..) |p, i| {
        if (in_job[i] or p.pid == self) continue;
        const was = cpu_before.get(p.pid) orelse continue;
        const rate = @as(f64, @floatFromInt(p.own_ns -| was)) / wall_ns;
        if (rate >= 0.3) outside.append(a, .{ .pid = p.pid, .name = p.name, .using = rate }) catch {};
    }
    std.mem.sortUnstable(JsonOutside, outside.items, {}, struct {
        fn busier(_: void, x: JsonOutside, y: JsonOutside) bool {
            return x.using > y.using;
        }
    }.busier);
    var total: f64 = 0;
    for (outside.items) |o| total += o.using;
    const top = outside.items[0..@min(outside.items.len, 5)];
    for (top) |*o| {
        o.command = sys.procCommand(a, io, o.pid, 300);
        o.cwd = sys.procCwd(a, io, o.pid);
    }
    return .{ .busy = busy, .jobs = jobs, .outside = top, .outside_total = total };
}

fn nullUsage(a: std.mem.Allocator, n: usize) []?f64 {
    const out = a.alloc(?f64, n) catch return &.{};
    @memset(out, null);
    return out;
}

pub fn cmdStatus(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var json = false;
    var measure = true;
    var watch_s: ?u32 = null;
    var hosts: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--host") or std.mem.startsWith(u8, a, "--host=")) {
            const h = if (std.mem.cutPrefix(u8, a, "--host=")) |v| v else blk: {
                i += 1;
                if (i >= args.len) return usageError("--host needs a host name", .{});
                break :blk args[i];
            };
            if (h.len == 0 or h[0] == '-') return usageError("--host needs a host name", .{});
            hosts.append(ctx.arena, h) catch {};
        } else if (std.mem.eql(u8, a, "--json")) {
            json = true;
        } else if (std.mem.eql(u8, a, "--no-usage")) {
            measure = false;
        } else if (std.mem.eql(u8, a, "--watch")) {
            watch_s = 2;
        } else if (std.mem.cutPrefix(u8, a, "--watch=")) |v| {
            watch_s = policy.parseCount(v) orelse return usageError("--watch=SECONDS needs a whole number, at least 1, not '{s}'", .{v});
        } else return usageError("unknown status option '{s}'", .{a});
    }
    const every = watch_s orelse return statusHosts(ctx, hosts.items, json, measure);
    if (json or std.c.isatty(1) == 0) return usageError("--watch draws on a terminal; for a program, poll `cpuq status --json`", .{});
    // Redraw in place until ^C, on the terminal's alternate screen (as top
    // does: the scrollback is left alone and the view goes on exit), each
    // round on its own scratch memory.
    watchScreen(true);
    const process_arena = ctx.arena;
    while (true) {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        ctx.arena = scratch.allocator();
        ctx.watch_note = ctx.arena.print("refreshing every {d}s · ^C to stop", .{every}) catch null;
        var buf: Io.Writer.Allocating = .init(ctx.arena);
        const out = ctx.out;
        ctx.out = &buf.writer;
        _ = statusHosts(ctx, hosts.items, false, measure);
        ctx.out = out;
        // Home, then each line over the last frame's, its rest erased, and
        // everything below the new frame erased: no clear, so no flicker
        // and nothing pushed into scrollback.
        out.writeAll("\x1b[H") catch {};
        var lines = std.mem.splitScalar(u8, buf.written(), '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) out.writeAll("\x1b[K\n") catch {};
            out.writeAll(line) catch {};
            first = false;
        }
        out.writeAll("\x1b[K\x1b[J") catch {};
        out.flush() catch {};
        ctx.arena = process_arena;
        ctx.io.sleep(.fromSeconds(every), .awake) catch {};
    }
}

/// `cpuq status` for each of `hosts` in turn (`local` is this machine), or
/// this machine alone when none are given. With --json and several hosts,
/// one object keyed by host.
fn statusHosts(ctx: *Ctx, hosts: []const []const u8, json: bool, measure: bool) u8 {
    if (hosts.len == 0) return statusOnce(ctx, json, measure);
    var rc: u8 = 0;
    if (json and hosts.len > 1) ctx.out.writeAll("{\n") catch {};
    for (hosts, 0..) |h, k| {
        if (json and hosts.len > 1) ctx.out.print("{s}\"{s}\": ", .{ if (k == 0) "" else ",\n", h }) catch {};
        if (!json and k != 0) ctx.out.writeAll("\n") catch {};
        const local = std.mem.eql(u8, h, "local");
        const r = if (local) statusOnce(ctx, json, measure) else statusRemote(ctx, h, json, measure);
        if (r != 0) rc = r;
    }
    if (json and hosts.len > 1) ctx.out.writeAll("}\n") catch {};
    return rc;
}

/// "USED of TOTAL GB": a decimal when the total is below 10 GB, whole above
/// ("97 of 128 GB", "1.3 of 2.0 GB").
fn ofGb(a: std.mem.Allocator, used: u64, total: u64) []const u8 {
    const u = @as(f64, @floatFromInt(used)) / (1 << 30);
    const t = @as(f64, @floatFromInt(total)) / (1 << 30);
    return (if (t < 9.95) a.print("{d:.1} of {d:.1} GB", .{ u, t }) else a.print("{d:.0} of {d:.0} GB", .{ u, t })) catch "?";
}

/// "97 of 128 GB used; swap 24 of 32 GB" (or "no swap").
fn memoryText(a: std.mem.Allocator, m: sys.Memory) []const u8 {
    const used = ofGb(a, m.used, m.total);
    if (m.swap_total == 0) return a.print("{s} used; no swap", .{used}) catch used;
    return a.print("{s} used; swap {s}", .{ used, ofGb(a, m.swap_used, m.swap_total) }) catch used;
}

fn bootSeconds(io: Io) ?i64 {
    const t = sys.bootTime(io);
    return if (t > 0) @intFromFloat(t) else null;
}

fn cpuTicksJson(io: Io, a: std.mem.Allocator) ?[]const [2]u64 {
    const ticks = sys.perCpuTicks(io, a) orelse return null;
    const out = a.alloc([2]u64, ticks.len) catch return null;
    for (ticks, out) |t, *o| o.* = .{ t.busy, t.total };
    return out;
}

/// HOST's status over ssh: drawn here in boxes on a terminal, else HOST's
/// own output passed through.
fn statusRemote(ctx: *Ctx, host: []const u8, json: bool, measure: bool) u8 {
    const a = ctx.arena;
    const boxed = !json and std.c.isatty(1) != 0;
    var remote: std.ArrayList(u8) = .empty;
    remote.appendSlice(a, "cpuq status") catch {};
    if (json or boxed) remote.appendSlice(a, " --json") catch {};
    if (!measure) remote.appendSlice(a, " --no-usage") catch {};
    const argv = [_][]const u8{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, remote.items };
    const result = std.process.run(a, ctx.io, .{ .argv = &argv }) catch |err| {
        std.debug.print("cpuq: ssh {s}: {t}\n", .{ host, err });
        return exit_failure;
    };
    if (!result.term.success()) {
        std.debug.print("cpuq: status on {s} failed: {s}\n", .{ host, std.mem.trim(u8, result.stderr, " \n") });
        return exit_failure;
    }
    if (!boxed) {
        ctx.out.writeAll(result.stdout) catch {};
        return 0;
    }
    const st = std.json.parseFromSliceLeaky(JsonStatus, a, result.stdout, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        std.debug.print("cpuq: {s} answered in an older format; upgrade its cpuq\n", .{host});
        return exit_failure;
    };
    const gate: policy.Gate = if (std.mem.eql(u8, st.gate.state, "pressure"))
        .pressure
    else if (std.mem.eql(u8, st.gate.state, "load"))
        .{ .load = st.gate.load orelse 0 }
    else if (std.mem.eql(u8, st.gate.state, "spacing"))
        .{ .spacing = st.gate.load orelse 0 }
    else if (std.mem.eql(u8, st.gate.state, "low_memory"))
        .{ .low_memory = st.gate.available orelse 0 }
    else if (std.mem.eql(u8, st.gate.state, "low_disk"))
        .{ .low_disk = .{ .free = st.gate.disk_free orelse 0, .path = st.gate.disk_path orelse "" } }
    else
        .open;
    const waiters = a.dupe(JsonWaiter, st.waiters) catch st.waiters;
    const remote_cpus = std.mem.eql(u8, st.admit, "measured") and st.active_cores > 0;
    statusBoxed(ctx, .{
        .budget = if (remote_cpus) st.active_cores else st.budget,
        .cpus = remote_cpus,
        .held = st.held,
        .load = st.load,
        .pressure = std.meta.stringToEnum(policy.Pressure, st.memory_pressure) orelse .unknown,
        .memory = st.memory,
        .gate = gate,
        .gate_text = st.gate.text,
        .holders = st.holders,
        .waiters = waiters,
        .leases = st.leases,
        .outside = st.outside,
        .now = nowSeconds(ctx.io),
        .online = st.active_cores,
        .host = host,
        .version = st.version,
    });
    return 0;
}

/// Enters (or leaves) the alternate screen with the cursor hidden. Leaving
/// happens on ^C, a kill or a hangup too, so the terminal is never left on
/// the alternate screen.
fn watchScreen(enter: bool) void {
    const on = "\x1b[?1049h\x1b[?25l";
    const off = "\x1b[?25h\x1b[?1049l";
    if (!enter) {
        _ = std.c.write(1, off, off.len);
        return;
    }
    _ = std.c.write(1, on, on.len);
    var sa: std.c.Sigaction = .{ .handler = .{ .handler = leaveWatch }, .mask = undefined, .flags = 0 };
    _ = std.c.sigemptyset(&sa.mask);
    for ([_]std.c.SIG{ .INT, .TERM, .HUP, .QUIT }) |sig| _ = std.c.sigaction(sig, &sa, null);
}

fn leaveWatch(_: std.c.SIG) callconv(.c) void {
    const off = "\x1b[?25h\x1b[?1049l";
    _ = std.c.write(1, off, off.len);
    std.c._exit(0);
}

fn statusOnce(ctx: *Ctx, json: bool, measure: bool) u8 {
    const io = ctx.io;
    const a = ctx.arena;
    var st = openState(ctx);
    const m = machine(ctx);
    const budget = budgetNow(ctx, m);
    const load = sys.loadAverage();
    const now = nowSeconds(io);

    lockOrFail(&st);
    const held = state.heldTokens(&st) catch 0;
    const leases = state.scanLeases(&st, a, false) catch @as([]state.Entry, &.{});
    const queue = servedOrder(ctx, &st, a, state.scanQueue(&st, a, null, .{}, now, ctx.cfg.aging_s) catch @as([]state.Entry, &.{}), now, true);
    var valve = st.readValve();
    st.unlock();
    // Under measured admission the load valve gates only an exclusive run.
    const valved = ctx.cfg.admit == .cores or (queue.len != 0 and queue[0].record.exclusive);
    const g = policy.gate(ctx.cfg, m, budget, if (valved) &valve else null, now);
    var gbuf: [256]u8 = undefined;
    const gate_text = gateText(&gbuf, g, budget);

    // What each holder actually uses: its command's process tree, CPU time
    // over wall time between two snapshots.
    const running = jobs_mod.running(io, a, ctx.env);
    const drivers = a.alloc(i32, running.len) catch main.fail("out of memory", .{});
    for (running, drivers) |r, *pid| pid.* = r.snap.pid;
    const smp = sample(io, a, leases, drivers, measure);
    const busy = smp.busy;

    const holders = toHolders(a, leases, busy);
    var lend_buf: [128]u8 = undefined;
    const lending = st.lendingWindow(&lend_buf);
    var lending_label: ?[]const u8 = null;
    for (holders, leases) |*h, l| {
        h.paused = st.isPaused(l.name);
        var fbuf: [128]u8 = undefined;
        h.frozen = st.frozenBy(l.name, &fbuf) != null;
        h.lending = l.record.exclusive and lending != null and std.mem.eql(u8, lending.?, l.name);
        h.@"opaque" = l.record.hidden;
        if (h.lending) lending_label = if (l.record.label.len != 0) l.record.label else "a timing window";
    }
    const waiters = toWaiters(a, queue);
    // How far each job has got, and how long it has left: from what it reports, else its label's
    // typical run time.
    const rt_all: ?RunTimes = if (holders.len + waiters.len != 0) RunTimes.load(ctx, a) else null;
    for (holders, leases) |*h, l| {
        h.progress = readProgress(ctx.io, l.record.progress);
        h.typical = if (rt_all) |rt| rt.typicalFor(a, l.record.label, l.record.cmd) else null;
        const ran: f64 = @floatFromInt(@max(now - l.record.since, 0));
        // The rate since it began counting (its build before that is no guide), or, from a
        // cpuq that doesn't note when that was, since it started.
        const counting: f64 = if (l.record.progress_since != 0) @floatFromInt(@max(now - l.record.progress_since, 0)) else ran;
        const base: u64 = if (l.record.progress_since != 0) l.record.progress_base else 0;
        if (h.progress) |p| if (p.done > base and counting > 0) {
            h.left = counting * @as(f64, @floatFromInt(p.total -| p.done)) / @as(f64, @floatFromInt(p.done - base));
            h.left_from = "progress";
        };
        if (h.left == null) if (h.typical) |t| {
            h.left = @max(t - ran, 0);
            h.left_from = "history";
        };
    }
    if (waiters.len != 0) {
        const rt = rt_all.?;
        if (ctx.cfg.admit == .measured) {
            const target = targetCpus(ctx);
            estimateIn(rt, target, target, holders, waiters, now);
        } else estimate(rt, budget, holders, waiters, now);
    }

    // The named leases: each a pool of one with its own holder and waiters.
    var named: std.ArrayList(JsonLease) = .empty;
    for (namedLeases(ctx, a)) |name| {
        var ns = openNamed(ctx, name);
        lockOrFail(&ns);
        const nl = state.scanLeases(&ns, a, false) catch @as([]state.Entry, &.{});
        const nq = state.scanQueue(&ns, a, null, .{}, now, ctx.cfg.aging_s) catch @as([]state.Entry, &.{});
        ns.unlock();
        if (nl.len == 0 and nq.len == 0) continue;
        const nh = toHolders(a, nl, nullUsage(a, nl.len));
        named.append(a, .{ .name = name, .holders = nh, .waiters = toWaiters(a, nq) }) catch {};
    }
    const pressure = @tagName(m.pressure);
    const w = ctx.out;
    if (json) {
        const s: JsonStatus = .{
            .dir = st.path,
            .admit = @tagName(ctx.cfg.admit),
            .target = if (ctx.cfg.admit == .measured) targetCpus(ctx) else null,
            .budget = budget,
            .cores = sys.totalCpus(ctx.io),
            .active_cores = m.active,
            .held = held,
            .free = budget -| held,
            .load = load,
            .load_check = ctx.cfg.load_check,
            .memory_pressure = pressure,
            .memory = sys.memory(ctx.io),
            .gate = .{
                .state = @tagName(g),
                .load = switch (g) {
                    .load, .spacing => |l| l,
                    .open, .pressure, .low_memory, .low_disk => null,
                },
                .available = switch (g) {
                    .low_memory => |av| av,
                    else => null,
                },
                .disk_free = switch (g) {
                    .low_disk => |d| d.free,
                    else => null,
                },
                .disk_path = switch (g) {
                    .low_disk => |d| d.path,
                    else => null,
                },
                .text = gate_text,
                .trip = if (ctx.cfg.load_check) @as(f64, @floatFromInt(budget)) + ctx.cfg.load_margin else null,
                .reopen = if (ctx.cfg.load_check) @as(f64, @floatFromInt(budget)) + ctx.cfg.load_margin / 2 else null,
                .busy_trip = if (ctx.cfg.load_check) 0.9 else null,
            },
            .holders = holders,
            .waiters = waiters,
            .jobs = statusjson.toJobs(a, running, smp.jobs, now),
            .leases = named.items,
            .outside = smp.outside,
            .outside_total = smp.outside_total,
            .cpu_ticks = cpuTicksJson(ctx.io, a),
            .boot_time = bootSeconds(ctx.io),
            .recorder = recorderRunning(ctx),
        };
        std.json.Stringify.value(s, .{ .whitespace = .indent_2 }, w) catch {};
        w.writeAll("\n") catch {};
        return 0;
    }
    if (std.c.isatty(1) != 0) {
        const by_cpus = ctx.cfg.admit == .measured;
        statusBoxed(ctx, .{
            .budget = if (by_cpus) m.active else budget,
            .cpus = by_cpus,
            .held = held,
            .load = load,
            .pressure = m.pressure,
            .gate = g,
            .gate_text = gate_text,
            .holders = holders,
            .waiters = waiters,
            .leases = named.items,
            .outside = smp.outside,
            .now = now,
            .online = m.active,
            .memory = sys.memory(ctx.io),
        });
        return 0;
    }
    w.print("dir     {s}\n", .{st.path}) catch {};
    if (ctx.cfg.admit == .measured) {
        w.print("admit   by measured use, up to {d} CPUs; {d} cores handed out ({d} online of {d})\n", .{ targetCpus(ctx), held, m.active, sys.totalCpus(ctx.io) }) catch {};
    } else w.print("budget  {d} cores ({d} online of {d}); in use {d}, free {d}\n", .{ budget, m.active, sys.totalCpus(ctx.io), held, budget -| held }) catch {};
    w.print("load    {d:.2} {d:.2} {d:.2}; memory pressure {s}; gate {s}\n", .{ load[0], load[1], load[2], pressure, gate_text }) catch {};
    if (sys.memory(ctx.io)) |mem| w.print("memory  {s}\n", .{memoryText(a, mem)}) catch {};
    if (!ctx.cfg.exclusive) w.writeAll("note    exclusive runs are off here: --exclusive runs as an ordinary job\n") catch {};
    if (lending_label) |l| w.print("note    {s} is idle: its timing window lends the machine until it is used again\n", .{l}) catch {};
    if (showOutside(smp.outside, g)) {
        w.writeAll("outside") catch {};
        for (smp.outside, 0..) |o, k| w.print("{s} {s} (pid {d}, {d:.1})", .{ if (k == 0) "" else ",", o.name, o.pid, o.using }) catch {};
        w.writeAll("\n") catch {};
    }
    // The label column fits the longest label, within reason.
    var lw: usize = 5;
    for (holders) |h| lw = @max(lw, @min(withNote(ctx.arena, h.label, h.note).len, 40));
    for (waiters) |q| lw = @max(lw, @min(withNote(ctx.arena, q.label, q.note).len, 40));
    var b1: [16]u8 = undefined;
    w.print("\nholders ({d})\n", .{holders.len}) catch {};
    var lbuf: [40]u8 = undefined;
    if (holders.len != 0) w.print("  PID      CMD-PID  IN USE ACTIVE PRIO    SINCE    {s} COMMAND\n", .{pad(&lbuf, "LABEL", lw)}) catch {};
    for (holders) |h| {
        var pid_buf: [16]u8 = undefined;
        const pid_text = std.mem.print(&pid_buf, "{d}{s}", .{ h.pid, if (h.holder_alive) "" else "*" }) catch "?";
        var child_buf: [16]u8 = undefined;
        const child_text = std.mem.print(&child_buf, "{d}", .{h.child}) catch "?";
        var using_buf: [16]u8 = undefined;
        const using_text = if (h.using) |u| std.mem.print(&using_buf, "{d:.1}", .{u}) catch "?" else "-";
        w.print("  {s:<8} {s:<8} {d:<6} {s:<6} {s:<7} {s:<8} {s} {s}{s}\n", .{
            pid_text,                child_text,                                           h.cores,   using_text,                                                                   if (h.exclusive) "excl" else h.priority,
            age(&b1, now - h.since), pad(&lbuf, withNote(ctx.arena, h.label, h.note), lw), h.command, if (h.holder_alive) "" else "  (cpuq gone; the command still has the cores)",
        }) catch {};
        // How far it is, on a line of its own under the job, so the columns keep their places.
        const how = progressText(ctx.arena, h);
        if (how.len != 0) w.print("  {s:<8} {s}\n", .{ "", how }) catch {};
    }
    w.print("\nwaiters ({d})\n", .{waiters.len}) catch {};
    if (waiters.len != 0) w.print("  #    PID      CORES  PRIO    WAITING  {s} COMMAND\n", .{pad(&lbuf, "LABEL", lw)}) catch {};
    for (waiters) |q| {
        var prio_buf: [24]u8 = undefined;
        const prio = if (q.exclusive) "excl" else if (std.mem.eql(u8, q.class, q.priority)) q.priority else std.mem.print(&prio_buf, "{s}>{s}", .{ q.priority, q.class }) catch q.priority;
        var pid_buf: [16]u8 = undefined;
        const pid_text = std.mem.print(&pid_buf, "{d}", .{q.pid}) catch "?";
        var cores_buf: [24]u8 = undefined;
        const cores_text = if (q.max > q.cores) std.mem.print(&cores_buf, "{d}-{d}", .{ q.cores, q.max }) catch "?" else std.mem.print(&cores_buf, "{d}", .{q.cores}) catch "?";
        w.print("  {d:<4} {s:<8} {s:<6} {s:<7} {s:<8} {s} {s}\n", .{ q.order, pid_text, cores_text, prio, age(&b1, now - q.since), pad(&lbuf, withNote(ctx.arena, q.label, q.note), lw), q.command }) catch {};
    }
    if (named.items.len != 0) {
        w.print("\nleases ({d})\n", .{named.items.len}) catch {};
        var nw: usize = 4;
        for (named.items) |l| nw = @max(nw, l.name.len);
        var nbuf: [80]u8 = undefined;
        w.print("  {s} HELD BY (PID, SINCE)  WAITING\n", .{pad(&nbuf, "NAME", nw)}) catch {};
        for (named.items) |l| {
            w.print("  {s} ", .{pad(&nbuf, l.name, nw)}) catch {};
            for (l.holders, 0..) |h, k| {
                w.print("{s}{s} ({d}{s}, {s})", .{ if (k == 0) "" else ", ", dash(h.label), h.pid, if (h.holder_alive) "" else "*", age(&b1, now - h.since) }) catch {};
            }
            if (l.holders.len == 0) w.writeAll("-") catch {};
            w.print("  {d}", .{l.waiters.len}) catch {};
            for (l.waiters, 0..) |q, k| w.print("{s}{s}", .{ if (k == 0) ": " else ", ", dash(q.label) }) catch {};
            w.writeAll("\n") catch {};
        }
    }
    return 0;
}
