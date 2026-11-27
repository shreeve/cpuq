//! `cpuq status`: who holds which of the pool's CPUs, the line for the next one and why each
//! waiter waits, each project's CPUs against its fair share, and the machine's busy CPUs and
//! gates. This machine's and other hosts', as JSON or as boxed tables.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const policy = @import("policy.zig");
const sys = @import("sys.zig");
const table = @import("table.zig");
const pool_mod = @import("pool.zig");

const main = @import("main.zig");
const texts = @import("texts.zig");
const records = @import("records.zig");
const statusjson = @import("statusjson.zig");

const Pool = pool_mod.Pool;
const Op = pool_mod.Op;
const Promise = pool_mod.Promise;
const version = main.version;
const exit_failure = main.exit_failure;
const Ctx = main.Ctx;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const age = texts.age;
const dash = texts.dash;
const JsonHolder = statusjson.JsonHolder;
const JsonWaiter = statusjson.JsonWaiter;
const JsonProject = statusjson.JsonProject;
const JsonStatus = statusjson.JsonStatus;
const JsonGate = statusjson.JsonGate;
const JsonOutside = statusjson.JsonOutside;
const JsonWork = statusjson.JsonWork;

/// How long `cpuq status` watches the operations' tasks to measure what they keep busy.
const sample_ms = 500;

/// An operation's held CPUs averaging under this busy each are worth packing tighter (-x).
const low_use = 0.5;
/// Over this busy per held CPU, its tasks run beyond their CPUs.
const over_use = 1.2;

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
    // Redraw in place until ^C, on the terminal's alternate screen (as top does: the scrollback
    // is left alone and the view goes on exit), each round on its own scratch memory.
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
        // Home, then each line over the last frame's, its rest erased, and everything below the
        // new frame erased: no clear, so no flicker and nothing pushed into scrollback.
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

/// `cpuq status` for each of `hosts` in turn (`local` is this machine), or this machine alone
/// when none are given. With --json and several hosts, one object keyed by host.
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

fn statusOnce(ctx: *Ctx, json: bool, measure: bool) u8 {
    const st = collect(ctx, measure);
    const w = ctx.out;
    if (json) {
        std.json.Stringify.value(st, .{ .whitespace = .indent_2 }, w) catch {};
        w.writeAll("\n") catch {};
    } else if (std.c.isatty(1) != 0) {
        boxed(ctx, st, null);
    } else plain(ctx, st);
    return 0;
}

/// HOST's status over ssh: drawn here in boxes on a terminal, else HOST's own output passed
/// through.
fn statusRemote(ctx: *Ctx, host: []const u8, json: bool, measure: bool) u8 {
    const a = ctx.arena;
    const draw = !json and std.c.isatty(1) != 0;
    var remote: std.ArrayList(u8) = .empty;
    remote.appendSlice(a, "cpuq status") catch {};
    if (json or draw) remote.appendSlice(a, " --json") catch {};
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
    if (!draw) {
        ctx.out.writeAll(result.stdout) catch {};
        return 0;
    }
    const st = std.json.parseFromSliceLeaky(JsonStatus, a, result.stdout, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
    if (st == null or st.?.schema != (JsonStatus{}).schema) {
        std.debug.print("cpuq: {s} answered in another format; give it this cpuq ({s})\n", .{ host, version });
        return exit_failure;
    }
    boxed(ctx, st.?, host);
    return 0;
}

// --- Collecting: the pool, the line, the machine --------------------------------------------

/// The pool's CPUs nobody holds or is promised. Under the pool's lock.
fn freeCpus(p: *Pool, a: std.mem.Allocator, pool_cpus: []const u32, ops: []const Op, given: []const Promise) []const u32 {
    var out: std.ArrayList(u32) = .empty;
    outer: for (pool_cpus) |cpu| {
        for (ops) |o| if (std.mem.findScalar(u32, o.held, cpu) != null) continue :outer;
        for (given) |g| if (g.cpu == cpu) continue :outer;
        if (!p.isFree(cpu)) continue;
        out.append(a, cpu) catch break;
    }
    return out.items;
}

/// What a short look at every process found.
const Measured = struct {
    /// CPUs each operation's tasks kept busy, as `ops` lists them; null when not measured.
    using: []?f64,
    /// Whether each operation's cpuq is stopped.
    stopped: []bool,
    /// CPUs the whole machine kept busy, and all the operations' tasks together.
    busy: ?f64 = null,
    tasks: ?f64 = null,
    /// The busiest processes outside every operation, busiest first, and all of them in all.
    outside: []JsonOutside = &.{},
    outside_total: f64 = 0,
    /// The same load by what started it, busiest first.
    work: []JsonWork = &.{},
};

/// Programs that start work rather than do it: busy work outside cpuq is put down to the top
/// of its tree just below one of these.
const starters = [_][]const u8{ "claude", "sshd", "sshd-session", "launchd", "systemd", "init", "tmux", "tmux: server", "screen", "login", "cron", "Terminal", "iTerm2" };

/// The top of `procs[i]`'s tree below its starter (or below a parent that can't be seen), and
/// the starter's name.
fn workRoot(procs: []const sys.Proc, at: *const std.AutoHashMapUnmanaged(i32, usize), i: usize) struct { i: usize, via: []const u8 } {
    var cur = i;
    for (0..64) |_| {
        const pp = procs[cur].ppid;
        const j = at.get(pp) orelse return .{ .i = cur, .via = if (pp == 1) (if (builtin.os.tag == .macos) "launchd" else "init") else "" };
        for (starters) |s| if (std.mem.eql(u8, procs[j].name, s)) return .{ .i = cur, .via = s };
        if (pp <= 1) return .{ .i = cur, .via = procs[j].name };
        cur = j;
    }
    return .{ .i = cur, .via = "" };
}

/// An operation's task tree's CPU time: everything under its cpuq, the tasks it has reaped
/// included (their time is in its children's count), its cpuq's own left out.
fn tasksCpu(procs: []const sys.Proc, pid: i32) u64 {
    var own: u64 = 0;
    for (procs) |p| if (p.pid == pid) {
        own = p.own_ns;
    };
    return sys.treeCpu(procs, pid) -| own;
}

/// Watches every process and the machine's CPU ticks for `sample_ms`: what each operation's
/// tasks keep busy, whether its cpuq is stopped, and the busiest processes no operation runs.
/// Nothing is sampled when `measure` is off.
fn measureOps(io: Io, a: std.mem.Allocator, ops: []const Op, ncpu: u32, measure: bool) Measured {
    const using = a.alloc(?f64, ops.len) catch main.fail("out of memory", .{});
    @memset(using, null);
    const stopped = a.alloc(bool, ops.len) catch main.fail("out of memory", .{});
    @memset(stopped, false);
    var m: Measured = .{ .using = using, .stopped = stopped };
    if (!measure) return m;
    const t0 = Io.Clock.awake.now(io);
    const ticks0 = sys.cpuTicks(io);
    const before = sys.processes(io, a);
    io.sleep(.fromMilliseconds(sample_ms), .awake) catch {};
    const after = sys.processes(io, a);
    const ticks1 = sys.cpuTicks(io);
    const wall_ns: f64 = @floatFromInt(t0.durationTo(Io.Clock.awake.now(io)).toNanoseconds());
    if (wall_ns <= 0) return m;
    if (ticks0) |q| if (ticks1) |t| if (t.total > q.total and t.busy >= q.busy) {
        m.busy = @as(f64, @floatFromInt(t.busy - q.busy)) / @as(f64, @floatFromInt(t.total - q.total)) * @as(f64, @floatFromInt(ncpu));
    };
    var tasks: f64 = 0;
    for (ops, using, stopped) |o, *u, *s| {
        if (o.pid <= 0) continue;
        const used = tasksCpu(after, o.pid) -| tasksCpu(before, o.pid);
        u.* = @as(f64, @floatFromInt(used)) / wall_ns;
        tasks += u.*.?;
        for (after) |p| if (p.pid == o.pid) {
            s.* = p.stopped;
        };
    }
    m.tasks = tasks;
    // Everything else, but this process: outside load. A process's own CPU only: its reaped
    // children were counted while they ran (see sys.Proc.own_ns).
    const in_op = a.alloc(bool, after.len) catch return m;
    @memset(in_op, false);
    for (ops) |o| if (o.pid > 0) sys.markTree(after, o.pid, in_op);
    var cpu_before: std.AutoHashMapUnmanaged(i32, u64) = .empty;
    for (before) |p| cpu_before.put(a, p.pid, p.own_ns) catch {};
    const self = sys.getpid();
    var outside: std.ArrayList(JsonOutside) = .empty;
    var at: std.AutoHashMapUnmanaged(i32, usize) = .empty;
    for (after, 0..) |p, i| at.put(a, p.pid, i) catch {};
    var work: std.AutoArrayHashMapUnmanaged(i32, JsonWork) = .empty;
    for (after, 0..) |p, i| {
        if (in_op[i] or p.pid == self) continue;
        const was = cpu_before.get(p.pid) orelse continue;
        const rate = @as(f64, @floatFromInt(p.own_ns -| was)) / wall_ns;
        if (rate >= 0.3) outside.append(a, .{ .pid = p.pid, .name = p.name, .using = rate }) catch {};
        if (rate < 0.02) continue;
        const root = workRoot(after, &at, i);
        const gop = work.getOrPut(a, after[root.i].pid) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{ .pid = after[root.i].pid, .via = root.via };
        gop.value_ptr.using += rate;
        gop.value_ptr.procs += 1;
    }
    var busy_work: std.ArrayList(JsonWork) = .empty;
    for (work.values()) |wk| if (wk.using >= 0.3) busy_work.append(a, wk) catch {};
    std.mem.sortUnstable(JsonWork, busy_work.items, {}, struct {
        fn busier(_: void, x: JsonWork, y: JsonWork) bool {
            return x.using > y.using;
        }
    }.busier);
    m.work = busy_work.items[0..@min(busy_work.items.len, 5)];
    for (m.work) |*wk| {
        wk.command = agentCommand(sys.procCommand(a, io, wk.pid, 4000));
        wk.command = wk.command[0..@min(wk.command.len, 300)];
        wk.cwd = sys.procCwd(a, io, wk.pid);
    }
    std.mem.sortUnstable(JsonOutside, outside.items, {}, struct {
        fn busier(_: void, x: JsonOutside, y: JsonOutside) bool {
            return x.using > y.using;
        }
    }.busier);
    for (outside.items) |o| m.outside_total += o.using;
    m.outside = outside.items[0..@min(outside.items.len, 5)];
    for (m.outside) |*o| {
        o.command = sys.procCommand(a, io, o.pid, 300);
        o.cwd = sys.procCwd(a, io, o.pid);
    }
    return m;
}

/// How many promises in `given` are to operation `ticket`.
fn promisedTo(given: []const Promise, ticket: u64) u32 {
    var n: u32 = 0;
    for (given) |g| if (g.ticket == ticket) {
        n += 1;
    };
    return n;
}

/// The operations still wanting a CPU, as tickets in the order the next free CPUs would go to
/// them: `handOut` run one CPU at a time, each CPU counted as promised before the next. An
/// operation's place is where it first gets one. A `cpuq drain` takes every CPU it wants, so
/// once placed it leaves the rest of the line to the others.
fn lineOrder(a: std.mem.Allocator, ops: []const Op, given: []const Promise) []const u64 {
    var order: std.ArrayList(u64) = .empty;
    var work: std.ArrayList(Op) = .empty;
    work.appendSlice(a, ops) catch return order.items;
    var promised: std.ArrayList(Promise) = .empty;
    promised.appendSlice(a, given) catch return order.items;
    var waiting: usize = 0;
    for (ops) |o| {
        if (o.want > promisedTo(given, o.ticket)) waiting += 1;
    }
    var n: u32 = 0;
    while (order.items.len < waiting and n < 4096) : (n += 1) {
        const fake = [_]u32{std.math.maxInt(u32) - n};
        const got = pool_mod.handOut(a, work.items, promised.items, &fake);
        if (got.len == 0) break;
        const t = got[0].ticket;
        if (std.mem.findScalar(u64, order.items, t) == null) order.append(a, t) catch break;
        promised.append(a, got[0]) catch break;
        for (work.items, 0..) |o, i| if (o.ticket == t and o.drain) {
            _ = work.orderedRemove(i);
            break;
        };
    }
    return order.items;
}

/// Each project's share of `pool` CPUs by weight, as `projects` lists them: a project wanting
/// less than its share keeps what it wants, and what it leaves is shared among the others by
/// weight, until every share is settled.
fn fairShares(a: std.mem.Allocator, projects: []JsonProject, pool: u32) void {
    const settled = a.alloc(bool, projects.len) catch return;
    for (projects, settled) |*p, *s| {
        p.fair = 0;
        s.* = p.held + p.want == 0;
    }
    var left: f64 = @floatFromInt(pool);
    while (true) {
        var weights: f64 = 0;
        for (projects, settled) |p, s| if (!s) {
            weights += @floatFromInt(p.weight);
        };
        if (weights == 0) return;
        var any = false;
        for (projects, settled) |*p, *s| if (!s.*) {
            const demand: f64 = @floatFromInt(p.held + p.want);
            if (demand <= left * @as(f64, @floatFromInt(p.weight)) / weights) {
                p.fair = demand;
                left -= demand;
                s.* = true;
                any = true;
            }
        };
        if (any) continue;
        for (projects, settled) |*p, s| if (!s) {
            p.fair = left * @as(f64, @floatFromInt(p.weight)) / weights;
        };
        return;
    }
}

/// When a held CPU will next free, in seconds, about: an operation gives CPUs back as its tasks
/// end while it is emptying one for the line or has no task left to start, and its tasks so far
/// took about (time running × tasks running ÷ tasks ended) each, so one running now has about
/// half that left. Null when no operation is giving CPUs back or none has a task ended yet.
fn nextFree(ops: []const Op, now: i64) ?f64 {
    var best: ?f64 = null;
    for (ops) |o| {
        const ended = o.done + o.failed;
        if (ended == 0 or o.running == 0 or o.held.len == 0 or o.drain) continue;
        const pending = o.tasks -| ended -| o.running;
        if (o.draining == 0 and pending != 0) continue;
        const ran: f64 = @floatFromInt(@max(now - o.since, 0));
        const each = ran * @as(f64, @floatFromInt(o.running)) / @as(f64, @floatFromInt(ended));
        const soon = each / 2;
        if (best == null or soon < best.?) best = soon;
    }
    return best;
}

/// The gate as status shows it: the machine's memory and disk gates, then a `cpuq drain`, then
/// outside load (the machine's busy CPUs beyond those cpuq holds leave fewer idle than are free),
/// worked out as each operation's cpuq works it out. Returns it with the free CPUs it leaves
/// usable.
fn gateNow(ctx: *Ctx, a: std.mem.Allocator, drain: bool, drain_holds: bool, busy: ?f64, tasks: ?f64, held: u32, free: u32, ncpu: u32) struct { JsonGate, u32 } {
    const m = main.machine(ctx);
    const g = policy.gate(ctx.cfg, m);
    var buf: [256]u8 = undefined;
    switch (g) {
        .open => {},
        .pressure => return .{ .{ .state = "pressure", .text = "closed: memory pressure" }, 0 },
        .low_memory => |av| return .{ .{ .state = "low_memory", .available = av, .text = a.dupe(u8, texts.gateText(&buf, g)) catch "closed: memory low" }, 0 },
        .low_disk => |d| return .{ .{ .state = "low_disk", .disk_free = d.free, .disk_path = d.path, .text = a.dupe(u8, texts.gateText(&buf, g)) catch "closed: disk low" }, 0 },
    }
    if (drain) return .{ .{ .state = "drain", .text = if (drain_holds) "closed: cpuq drain holds the machine" else "closed: cpuq drain waits for the machine" }, 0 };
    const b = busy orelse return .{ .{ .state = "open", .text = "open" }, free };
    const used = @max(b, @as(f64, @floatFromInt(held)));
    const room: u32 = @intFromFloat(@max(0, @floor(@as(f64, @floatFromInt(ncpu)) - used + 0.25)));
    if (room >= free) return .{ .{ .state = "open", .text = "open" }, free };
    const outside = @max(0, b - (tasks orelse @as(f64, @floatFromInt(held))));
    const text = if (room == 0)
        a.print("closed: outside load ({d:.1} CPUs busy outside cpuq)", .{outside}) catch "closed: outside load"
    else
        a.print("outside load leaves {d} of {d} free CPUs idle ({d:.1} busy outside cpuq)", .{ room, free, outside }) catch "outside load";
    return .{ .{ .state = "outside_load", .load = outside, .text = text }, room };
}

/// Why a waiter waits, for people: its place in line, then what holds it back.
fn whyText(a: std.mem.Allocator, place: usize, o: Op, pool: u32, gate: JsonGate, usable: u32, emptying: u32, next_free: ?f64) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var ob: [16]u8 = undefined;
    out.print(a, "{s} in line", .{texts.ordinal(&ob, place)}) catch {};
    if (o.drain) {
        out.print(a, "; waits for every CPU ({d} of {d} held)", .{ o.held.len, pool }) catch {};
    } else if (o.why.len != 0) {
        out.print(a, "; {s}", .{o.why}) catch {};
    } else if (!std.mem.eql(u8, gate.state, "open") and usable == 0) {
        out.print(a, "; {s}", .{gate.text}) catch {};
    } else if (usable != 0) {
        out.appendSlice(a, "; a CPU is free: it takes one at its next look") catch {};
    } else if (place == 1 and emptying != 0) {
        out.print(a, "; {d} CPU{s} being emptied for it", .{ emptying, if (emptying == 1) " is" else "s are" }) catch {};
    } else {
        out.appendSlice(a, "; every CPU is held") catch {};
    }
    if (usable == 0) if (next_free) |s| {
        var b: [16]u8 = undefined;
        out.print(a, "; next CPU frees in about {s}", .{age(&b, @intFromFloat(@ceil(s)))}) catch {};
    };
    return out.items;
}

/// The pool's status, from the operations' records, the line's order and a short look at what
/// their tasks keep busy.
/// The pool's lock didn't come within 5 s. Each step under it takes milliseconds, so its
/// holder is stuck, and every cpuq on the machine waits behind it: name the holder, and exit.
fn lockStuck(ctx: *Ctx, pool: *Pool) noreturn {
    const h = pool.holder() orelse main.fail("the pool's lock ({s}/lock) is held past 5 s by a process that left no note: every cpuq here waits for it", .{pool.path});
    const held_s = @divTrunc(Io.Clock.real.now(ctx.io).toMilliseconds() - h.since_ms, 1000);
    const cmd = ctx.arena.dupe(u8, sys.procCommand(ctx.arena, ctx.io, h.pid, 160)) catch main.fail("out of memory", .{});
    for (cmd) |*ch| if (ch.* == '\n' or ch.* == '\t') {
        ch.* = ' ';
    };
    main.fail("the pool's lock is held by pid {d} for {d}s{s}{s}{s}: every cpuq here waits for it, so that process is stuck. Report this line; ending that process frees the pool (its owner's call)", .{
        h.pid, held_s, if (cmd.len != 0) " (" else "", cmd, if (cmd.len != 0) ")" else " (gone)",
    });
}

fn collect(ctx: *Ctx, measure: bool) JsonStatus {
    const io = ctx.io;
    const a = ctx.arena;
    const now = nowSeconds(io);
    const dir = main.stateDir(ctx);
    const pool_cpus = main.poolCpus(ctx);
    const pool_n: u32 = @intCast(pool_cpus.len);
    const ncpu = sys.activeCpus(io);
    var pool = Pool.open(io, a, dir) catch |err| main.fail("pool {s}/v2: {t}", .{ dir, err });

    if (!pool.lockWithin(5000)) lockStuck(ctx, &pool);
    const ops = pool.scan(a);
    const given = pool.promises(a, ops, pool_cpus);
    const free = freeCpus(&pool, a, pool_cpus, ops, given);
    const drain = pool.draining();
    const last_busy = pool.machineBusy(ncpu);
    pool.unlock();

    const m = measureOps(io, a, ops, ncpu, measure);
    const busy = m.busy orelse last_busy;

    var held: u32 = 0;
    var emptying: u32 = 0;
    var drain_holds = false;
    for (ops) |o| {
        held += @intCast(o.held.len);
        emptying += o.draining;
        if (o.drain and o.held.len >= pool_n) drain_holds = true;
    }
    const gate, const usable = gateNow(ctx, a, drain, drain_holds, busy, m.tasks, held, @intCast(free.len), ncpu);
    const next_free = if (free.len == 0 or usable == 0) nextFree(ops, now) else null;

    // The holders: every operation holding a CPU or running a task.
    var holders: std.ArrayList(JsonHolder) = .empty;
    for (ops, m.using, m.stopped) |o, using, stopped| {
        if (o.held.len == 0 and o.running == 0) continue;
        var slots: std.ArrayList(u32) = .empty;
        for (o.held) |cpu| if (std.mem.findScalar(u32, pool_cpus, cpu)) |k| slots.append(a, @intCast(k)) catch {};
        var flags: std.ArrayList([]const u8) = .empty;
        if (using) |u| if (o.held.len != 0 and now - o.since >= 5) {
            const per = u / @as(f64, @floatFromInt(o.held.len));
            if (per < low_use) flags.append(a, "low_use") catch {};
            if (per > over_use) flags.append(a, "over_cpu") catch {};
        };
        if (stopped) flags.append(a, "stopped") catch {};
        const ended = o.done + o.failed;
        const ran: f64 = @floatFromInt(@max(now - o.since, 0));
        holders.append(a, .{
            .ticket = o.ticket,
            .pid = o.pid,
            .project = o.project,
            .weight = o.weight,
            .cores = @intCast(o.held.len),
            .slots = slots.items,
            .cpus = o.held,
            .emptying = o.draining,
            .want = o.want -| promisedTo(given, o.ticket),
            .overload = o.overload,
            .limit = o.limit,
            .tasks = o.tasks,
            .done = o.done,
            .failed = o.failed,
            .running = o.running,
            .running_tasks = tasksJson(a, o.tasks_now),
            .paused = stopped,
            .exclusive = o.drain,
            .urgent = o.urgent,
            .using = using,
            .flags = flags.items,
            .progress = if (o.tasks > 1) .{ .done = ended, .total = o.tasks, .failing = o.failed } else null,
            .left = if (ended != 0 and o.tasks > ended) ran * @as(f64, @floatFromInt(o.tasks - ended)) / @as(f64, @floatFromInt(ended)) else null,
            .left_from = if (ended != 0 and o.tasks > ended) "progress" else "",
            .label = o.label,
            .command = o.cmd,
            .since = o.since,
        }) catch {};
    }

    // The line, in the order free CPUs go.
    var waiters: std.ArrayList(JsonWaiter) = .empty;
    for (lineOrder(a, ops, given), 1..) |t, place| {
        const o = for (ops) |o| {
            if (o.ticket == t) break o;
        } else continue;
        waiters.append(a, .{
            .order = place,
            .ticket = o.ticket,
            .pid = o.pid,
            .project = o.project,
            .cores = o.want -| promisedTo(given, o.ticket),
            .max = o.limit,
            .holds = @intCast(o.held.len),
            .exclusive = o.drain,
            .urgent = o.urgent,
            .why = whyText(a, place, o, pool_n, gate, usable, emptying, next_free),
            .gate = o.why,
            .eta = if (place == 1 and usable == 0) next_free else null,
            .label = o.label,
            .command = o.cmd,
            .since = o.since,
        }) catch {};
    }

    // Each project's CPUs against its fair share.
    var projects: std.ArrayList(JsonProject) = .empty;
    for (ops) |o| {
        const k = for (projects.items, 0..) |q, k| {
            if (std.mem.eql(u8, q.name, o.project)) break k;
        } else projects.items.len;
        if (k == projects.items.len) projects.append(a, .{ .name = o.project }) catch continue;
        const p = &projects.items[k];
        p.weight = @max(p.weight, o.weight);
        p.ops += 1;
        p.held += @intCast(o.held.len);
        p.want += o.want -| promisedTo(given, o.ticket);
    }
    fairShares(a, projects.items, pool_n);

    const pressure = if (ctx.cfg.pressure_check) sys.memoryPressure(io, ctx.cfg.pressure_psi) else .off;
    return .{
        .dir = pool.path,
        .budget = pool_n,
        .pool = pool_cpus,
        .cores = sys.totalCpus(io),
        .active_cores = ncpu,
        .held = held,
        .emptying = emptying,
        .promised = @intCast(given.len),
        .free = @intCast(free.len),
        .busy = busy,
        .tasks_busy = m.tasks,
        .next_free = next_free,
        .load = sys.loadAverage(),
        .memory_pressure = @tagName(pressure),
        .memory = sys.memory(io),
        .gate = gate,
        .holders = holders.items,
        .waiters = waiters.items,
        .projects = projects.items,
        .outside = m.outside,
        .outside_total = m.outside_total,
        .outside_work = m.work,
        .cpu_ticks = cpuTicksJson(io, a),
        .boot_time = bootSeconds(io),
        .recorder = records.recorderRunning(ctx),
    };
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

// --- Showing -----------------------------------------------------------------------------------

/// "USED of TOTAL GB": a decimal when the total is below 10 GB, whole above ("97 of 128 GB",
/// "1.3 of 2.0 GB").
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

/// CPU numbers as a short list: "0-3,8".
fn cpuText(a: std.mem.Allocator, cpus: []const u32) []const u8 {
    if (cpus.len == 0) return "-";
    return policy.cpuListText(a, cpus);
}

/// How far an operation is: "12/20 · 1 failed", or "running" for a single task.
fn tasksText(a: std.mem.Allocator, h: JsonHolder) []const u8 {
    if (h.tasks <= 1) return if (h.running != 0) "running" else "starting";
    const failed = if (h.failed != 0) a.print(" · {d} failed", .{h.failed}) catch "" else "";
    return a.print("{d}/{d}{s}", .{ h.done + h.failed, h.tasks, failed }) catch "?";
}

/// The CPUs an operation holds, with those it is emptying and its overload: "0-3 ×2 · 1 emptying".
fn heldText(a: std.mem.Allocator, h: JsonHolder) []const u8 {
    const x = if (h.overload > 1) a.print(" ×{d}", .{h.overload}) catch "" else "";
    const e = if (h.emptying != 0) a.print(" · {d} emptying", .{h.emptying}) catch "" else "";
    return a.print("{s}{s}{s}", .{ cpuText(a, h.cpus), x, e }) catch "?";
}

/// How long it has run, with the time left at its rate so far: "2m10s · ~1m left".
fn sinceText(a: std.mem.Allocator, h: JsonHolder, now: i64) []const u8 {
    var b: [16]u8 = undefined;
    const ran = a.dupe(u8, age(&b, now - h.since)) catch "?";
    const l = h.left orelse return ran;
    var lb: [16]u8 = undefined;
    return a.print("{s} · ~{s} left", .{ ran, age(&lb, @intFromFloat(@ceil(l))) }) catch ran;
}

/// A pid as text: a signed number printed in a padded field shows its sign.
fn pidText(a: std.mem.Allocator, pid: i32) []const u8 {
    return a.print("{d}", .{pid}) catch "?";
}

fn whoText(a: std.mem.Allocator, h: JsonHolder) []const u8 {
    return a.print("op {d} ({s})", .{ h.ticket, dash(h.label) }) catch "op";
}

/// A line for each flag on each holder: what deserves a look, and what to do about it.
fn flagNotes(a: std.mem.Allocator, holders: []const JsonHolder) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (holders) |h| for (h.flags) |f| {
        const per = if (h.using) |u| u / @as(f64, @floatFromInt(@max(h.cores, 1))) else 0;
        const line = if (std.mem.eql(u8, f, "low_use"))
            (if (h.tasks > 1)
                a.print("{s}: its CPUs average {d:.2} busy each; -x could be higher", .{ whoText(a, h), per })
            else
                a.print("{s}: its CPU averages {d:.2} busy", .{ whoText(a, h), per }))
        else if (std.mem.eql(u8, f, "over_cpu"))
            a.print("{s}: {d:.2} busy per CPU held: its tasks run beyond their CPUs", .{ whoText(a, h), per })
        else if (std.mem.eql(u8, f, "stopped"))
            a.print("{s}: its cpuq (pid {d}) is stopped", .{ whoText(a, h), h.pid })
        else
            a.print("{s}: {s}", .{ whoText(a, h), f });
        out.append(a, line catch continue) catch {};
    };
    return out.items;
}

/// Whether outside load is worth showing: a CPU or more of it, or a gate that is not open.
/// The command an agent ran, out of its harness's wrapper (Claude Code's `zsh -c source
/// SNAPSHOT ... && eval 'COMMAND' < /dev/null && pwd -P ...`); any other command as it is.
fn agentCommand(cmd: []const u8) []const u8 {
    const mark = "&& eval '";
    const at = std.mem.indexOf(u8, cmd, mark) orelse return cmd;
    const rest = cmd[at + mark.len ..];
    for ([_][]const u8{ "' \\< /dev/null", "' < /dev/null", "' && pwd -P" }) |end|
        if (std.mem.indexOf(u8, rest, end)) |e| return rest[0..e];
    return rest;
}

/// A work tree's command for one line: its first 100 bytes, on one line.
fn workCommand(wk: JsonWork) []const u8 {
    const line = std.mem.sliceTo(wk.command, '\n');
    return line[0..@min(line.len, 100)];
}

fn showOutside(st: JsonStatus) bool {
    if (st.outside.len == 0 and st.outside_work.len == 0) return false;
    return st.outside_total >= 1.0 or !std.mem.eql(u8, st.gate.state, "open");
}

/// The load averages: the 1-minute one bold, in green under half the CPUs online, yellow up to
/// one and a half times them, red beyond; the 5-minute one plain and the 15-minute one dim.
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
fn boxed(ctx: *Ctx, st: JsonStatus, remote: ?[]const u8) void {
    const a = ctx.arena;
    const w = ctx.out;
    const color = ctx.env.get("NO_COLOR") == null;
    const width = table.terminalWidth(1);
    const now = nowSeconds(ctx.io);
    var host_buf: [256]u8 = undefined;
    const host = if (std.c.gethostname(&host_buf, host_buf.len) == 0) std.mem.sliceTo(&host_buf, 0) else "";
    const short_host = remote orelse std.mem.sliceTo(host, '.');
    const C = table.Cell;

    // The pool: granted against busy, free, and what holds the free back.
    const high = std.mem.eql(u8, st.memory_pressure, "high");
    const mem: C = if (st.memory) |m| .{
        .text = a.print("{s}{s}", .{ ofGb(a, m.used, m.total), if (high) ", pressure" else "" }) catch "?",
        .tint = if (high) .bad else if (std.mem.eql(u8, st.memory_pressure, "normal")) .good else null,
    } else .{ .text = if (st.memory_pressure.len != 0) st.memory_pressure else "-", .tint = if (high) .bad else .dim };
    const busy: C = if (st.busy) |b| .{ .text = a.print("{d:.1} of {d}", .{ b, st.active_cores }) catch "?" } else .{ .text = "-", .tint = .dim };
    // Granted far above busy is the waste the pool exists to stop: tasks idling on their CPUs.
    const tasks: C = if (st.tasks_busy) |t| .{
        .text = a.print("{d:.1}", .{t}) catch "?",
        .tint = if (st.held >= 2 and t * 2 < @as(f64, @floatFromInt(st.held))) .warn else null,
    } else .{ .text = "-", .tint = .dim };
    const outside: C = if (st.busy) |b| blk: {
        const o = @max(0, b - (st.tasks_busy orelse @as(f64, @floatFromInt(st.held))));
        break :blk .{ .text = a.print("{d:.1}", .{o}) catch "?", .tint = if (o >= 1) .warn else null };
    } else .{ .text = "-", .tint = .dim };
    const gate_open = std.mem.eql(u8, st.gate.state, "open");
    const summary: table.Table = .{
        .title = a.print("cpuq {s}{s}{s}", .{ st.version, if (short_host.len != 0) " · " else "", short_host }) catch "cpuq",
        .columns = &.{
            .{ .head = "POOL", .alignment = .right },
            .{ .head = "HELD", .alignment = .right },
            .{ .head = "FREE", .alignment = .right },
            .{ .head = "BUSY", .sub = "CPUs", .alignment = .right },
            .{ .head = "TASKS", .alignment = .right },
            .{ .head = "OUTSIDE", .alignment = .right },
            .{ .head = "LOAD", .sub = "1 5 15" },
            .{ .head = "MEMORY" },
            .{ .head = "GATE" },
        },
        .rows = &.{&.{
            .{ .text = a.print("{d}", .{st.budget}) catch "?" },
            .{ .text = a.print("{d}", .{st.held}) catch "?", .tint = if (st.held != 0) .accent else null },
            .{ .text = a.print("{d}", .{st.free}) catch "?", .tint = if (st.free == 0) .warn else .good },
            busy,
            tasks,
            outside,
            loadCell(a, st.load, st.active_cores),
            mem,
            .{ .text = st.gate.text, .tint = if (gate_open) .good else if (std.mem.eql(u8, st.gate.state, "outside_load") and st.free != 0) .warn else .bad },
        }},
    };
    summary.boxed(a, w, width, color) catch {};

    // Who holds which CPU.
    if (st.holders.len != 0) {
        var rows: std.ArrayList([]const C) = .empty;
        for (st.holders) |h| {
            const flagged = h.flags.len != 0;
            const per: C = if (h.using) |u| .{
                .text = a.print("{d:.2}", .{u / @as(f64, @floatFromInt(@max(h.cores, 1)))}) catch "?",
                .tint = if (flagged) .warn else null,
            } else .{ .text = "-", .tint = .dim };
            rows.append(a, a.dupe(C, &.{
                .{ .text = a.print("{d}", .{h.ticket}) catch "?", .tint = .dim },
                .{ .text = dash(h.project) },
                .{ .text = dash(h.label), .tint = .accent },
                .{ .text = tasksText(a, h), .tint = if (h.failed != 0) .warn else null },
                .{ .text = a.print("{d}", .{h.running}) catch "?" },
                .{ .text = heldText(a, h), .tint = if (h.emptying != 0) .warn else null },
                per,
                .{ .text = sinceText(a, h, now) },
                .{ .text = a.print("{d}", .{h.pid}) catch "?", .tint = if (h.paused) .bad else .dim },
                .{ .text = h.command },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("held: {d} of {d} CPUs{s}", .{ st.held, st.budget, if (st.emptying != 0) a.print(" · {d} emptying for the line", .{st.emptying}) catch "" else "" }) catch "held",
            .columns = &.{
                .{ .head = "OP", .alignment = .right },
                .{ .head = "PROJECT" },
                .{ .head = "LABEL" },
                .{ .head = "TASKS" },
                .{ .head = "RUN", .alignment = .right },
                .{ .head = "CPUS" },
                .{ .head = "BUSY", .sub = "/CPU", .alignment = .right },
                .{ .head = "SINCE" },
                .{ .head = "PID", .alignment = .right },
                .{ .head = "COMMAND", .flexible = true },
            },
            .rows = rows.items,
            .notes = flagNotes(a, st.holders),
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    // The line, and why each waits.
    if (st.waiters.len != 0) {
        var rows: std.ArrayList([]const C) = .empty;
        for (st.waiters) |q| {
            var b: [16]u8 = undefined;
            rows.append(a, a.dupe(C, &.{
                .{ .text = a.print("{d}", .{q.order}) catch "?", .tint = .dim },
                .{ .text = a.print("{d}", .{q.ticket}) catch "?", .tint = .dim },
                .{ .text = dash(q.project) },
                .{ .text = dash(q.label), .tint = .accent },
                .{ .text = a.print("{d}", .{q.holds}) catch "?" },
                .{ .text = if (q.exclusive) "all" else a.print("{d}", .{q.cores}) catch "?", .tint = if (q.exclusive or q.urgent) .warn else null },
                .{ .text = a.dupe(u8, age(&b, now - q.since)) catch "?" },
                .{ .text = q.why },
                .{ .text = q.command },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("waiting ({d})", .{st.waiters.len}) catch "waiting",
            .columns = &.{
                .{ .head = "#", .alignment = .right },
                .{ .head = "OP", .alignment = .right },
                .{ .head = "PROJECT" },
                .{ .head = "LABEL" },
                .{ .head = "HOLDS", .alignment = .right },
                .{ .head = "WANTS", .alignment = .right },
                .{ .head = "SINCE" },
                .{ .head = "WHY" },
                .{ .head = "COMMAND", .flexible = true },
            },
            .rows = rows.items,
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    // Each project's CPUs against its fair share.
    if (st.projects.len != 0) {
        var rows: std.ArrayList([]const C) = .empty;
        for (st.projects) |p| {
            const h: f64 = @floatFromInt(p.held);
            rows.append(a, a.dupe(C, &.{
                .{ .text = dash(p.name), .tint = .accent },
                .{ .text = a.print("{d}", .{p.weight}) catch "?" },
                .{ .text = a.print("{d}", .{p.ops}) catch "?" },
                // Under its share while it wants more: the line owes it CPUs.
                .{ .text = a.print("{d}", .{p.held}) catch "?", .tint = if (p.want != 0 and h + 0.5 < p.fair) .warn else null },
                .{ .text = a.print("{d}", .{p.want}) catch "?" },
                .{ .text = a.print("{d:.1}", .{p.fair}) catch "?" },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = "projects: CPUs held against the fair share by weight",
            .columns = &.{
                .{ .head = "PROJECT" },
                .{ .head = "WEIGHT", .alignment = .right },
                .{ .head = "OPS", .alignment = .right },
                .{ .head = "HELD", .alignment = .right },
                .{ .head = "WANTS", .alignment = .right },
                .{ .head = "FAIR", .alignment = .right },
            },
            .rows = rows.items,
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    if (showOutside(st)) {
        var rows: std.ArrayList([]const C) = .empty;
        for (st.outside_work) |wk| {
            rows.append(a, a.dupe(C, &.{
                .{ .text = workCommand(wk), .tint = .accent },
                .{ .text = wk.cwd, .tint = .dim },
                .{ .text = a.print("{s} {d}", .{ wk.via, wk.pid }) catch "?", .tint = .dim },
                .{ .text = a.print("{d}", .{wk.procs}) catch "?", .tint = .dim },
                .{ .text = a.print("{d:.1}", .{wk.using}) catch "?", .tint = if (wk.using >= 1) .warn else null },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("outside cpuq: {d:.1} CPUs busy, by what started it", .{st.outside_total}) catch "outside cpuq",
            .columns = &.{ .{ .head = "WORK", .flexible = true }, .{ .head = "WHERE", .flexible = true }, .{ .head = "VIA PID" }, .{ .head = "PROCS", .alignment = .right }, .{ .head = "BUSY", .alignment = .right } },
            .rows = rows.items,
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    var notes: std.ArrayList([]const u8) = .empty;
    if (st.holders.len == 0 and st.waiters.len == 0) notes.append(a, "nothing held or waiting") catch {};
    if (st.waiters.len != 0 and st.free != 0) {
        notes.append(a, a.print("{d} CPU{s} free while {d} wait{s}: {s}", .{
            st.free,                                                     if (st.free == 1) "" else "s", st.waiters.len, if (st.waiters.len == 1) "s" else "",
            if (gate_open) "taken at their next look" else st.gate.text,
        }) catch "") catch {};
    }
    if (st.holders.len != 0) notes.append(a, "end an operation: cpuq kill OP · for scripts: cpuq status --json") catch {} else notes.append(a, "for scripts: cpuq status --json") catch {};
    if (ctx.watch_note) |n| notes.append(a, n) catch {};
    w.writeAll("\n") catch {};
    for (notes.items) |n| {
        w.writeAll("  ") catch {};
        if (color) w.print("\x1b[2m{s}\x1b[0m\n", .{n}) catch {} else w.print("{s}\n", .{n}) catch {};
    }
}

/// `cpuq status` to a pipe or file: plain lines, a field each, for people and grep.
fn plain(ctx: *Ctx, st: JsonStatus) void {
    const a = ctx.arena;
    const w = ctx.out;
    const now = nowSeconds(ctx.io);
    var b: [16]u8 = undefined;
    w.print("dir     {s}\n", .{st.dir}) catch {};
    w.print("pool    {d} CPUs ({s}); held {d}, free {d}", .{ st.budget, cpuText(a, st.pool), st.held, st.free }) catch {};
    if (st.emptying != 0) w.print(", {d} emptying", .{st.emptying}) catch {};
    if (st.promised != 0) w.print(", {d} promised", .{st.promised}) catch {};
    w.writeAll("\n") catch {};
    if (st.busy) |bz| {
        w.print("busy    {d:.1} of {d} CPUs online", .{ bz, st.active_cores }) catch {};
        if (st.tasks_busy) |t| w.print("; cpuq's tasks {d:.1}, outside {d:.1}", .{ t, @max(0, bz - t) }) catch {};
        w.writeAll("\n") catch {};
    }
    w.print("load    {d:.2} {d:.2} {d:.2}; memory pressure {s}; gate {s}\n", .{ st.load[0], st.load[1], st.load[2], st.memory_pressure, st.gate.text }) catch {};
    if (st.memory) |mem| w.print("memory  {s}\n", .{memoryText(a, mem)}) catch {};
    if (showOutside(st)) {
        w.print("outside {d:.1} CPUs busy outside cpuq, by what started it:\n", .{st.outside_total}) catch {};
        for (st.outside_work) |wk| w.print("  {d:>5.1}  {s}  (pid {d} via {s}, {d} process{s}, in {s})\n", .{
            wk.using, workCommand(wk), wk.pid, if (wk.via.len == 0) "?" else wk.via, wk.procs, if (wk.procs == 1) "" else "es", if (wk.cwd.len == 0) "?" else wk.cwd,
        }) catch {};
    }

    w.print("\nheld ({d})\n", .{st.holders.len}) catch {};
    if (st.holders.len != 0) w.writeAll("  OP     PID      PROJECT      LABEL                TASKS        RUN  CPUS             BUSY  SINCE    COMMAND\n") catch {};
    for (st.holders) |h| {
        var ub: [16]u8 = undefined;
        const per = if (h.using) |u| std.mem.print(&ub, "{d:.2}", .{u / @as(f64, @floatFromInt(@max(h.cores, 1)))}) catch "?" else "-";
        w.print("  {d:<6} {s:<8} {s:<12} {s:<20} {s:<12} {d:<4} {s:<16} {s:<5} {s:<8} {s}\n", .{
            h.ticket, pidText(a, h.pid), dash(h.project), dash(h.label), tasksText(a, h), h.running, heldText(a, h), per, age(&b, now - h.since), h.command,
        }) catch {};
    }
    for (flagNotes(a, st.holders)) |n| w.print("  flag: {s}\n", .{n}) catch {};

    w.print("\nwaiting ({d})\n", .{st.waiters.len}) catch {};
    if (st.waiters.len != 0) w.writeAll("  #    OP     PID      PROJECT      LABEL                HOLDS WANTS WHY\n") catch {};
    for (st.waiters) |q| {
        var cb: [16]u8 = undefined;
        const wants = if (q.exclusive) "all" else std.mem.print(&cb, "{d}", .{q.cores}) catch "?";
        w.print("  {d:<4} {d:<6} {s:<8} {s:<12} {s:<20} {d:<5} {s:<5} {s}\n", .{ q.order, q.ticket, pidText(a, q.pid), dash(q.project), dash(q.label), q.holds, wants, q.why }) catch {};
    }

    if (st.projects.len != 0) {
        w.writeAll("\nprojects\n  PROJECT      WEIGHT OPS HELD WANTS FAIR\n") catch {};
        for (st.projects) |p| w.print("  {s:<12} {d:<6} {d:<3} {d:<4} {d:<5} {d:.1}\n", .{ dash(p.name), p.weight, p.ops, p.held, p.want, p.fair }) catch {};
    }
}

/// Enters (or leaves) the alternate screen with the cursor hidden. Leaving happens on ^C, a kill
/// or a hangup too, so the terminal is never left on the alternate screen.
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

// --- Tests -------------------------------------------------------------------------------------

test "the line's order: by project share, and a drain first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .held = &.{ 0, 1, 2 }, .want = 10 },
        .{ .ticket = 2, .project = "trig", .held = &.{3}, .want = 10 },
        .{ .ticket = 3, .project = "rip", .want = 2 },
        .{ .ticket = 4, .project = "emdb", .held = &.{4}, .want = 0 },
    };
    try std.testing.expectEqualSlices(u64, &.{ 3, 2, 1 }, lineOrder(a, &ops, &.{}));
    // A promise already made counts: rip, promised its two, waits no more.
    const given = [_]Promise{ .{ .cpu = 5, .ticket = 3 }, .{ .cpu = 6, .ticket = 3 } };
    try std.testing.expectEqualSlices(u64, &.{ 2, 1 }, lineOrder(a, &ops, &given));
    const drained = [_]Op{ ops[0], ops[1], .{ .ticket = 9, .project = "x", .drain = true, .want = 8 } };
    try std.testing.expectEqualSlices(u64, &.{ 9, 2, 1 }, lineOrder(a, &drained, &.{}));
}

test "fair shares by weight: a small demand keeps what it wants" {
    var ps = [_]JsonProject{
        .{ .name = "rig", .weight = 2, .held = 6, .want = 10 },
        .{ .name = "trig", .weight = 1, .held = 2, .want = 10 },
        .{ .name = "rip", .weight = 1, .held = 0, .want = 1 },
        .{ .name = "idle", .weight = 5 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    fairShares(arena.allocator(), &ps, 10);
    try std.testing.expectApproxEqAbs(1.0, ps[2].fair, 1e-9);
    try std.testing.expectApproxEqAbs(6.0, ps[0].fair, 1e-9);
    try std.testing.expectApproxEqAbs(3.0, ps[1].fair, 1e-9);
    try std.testing.expectEqual(0, ps[3].fair);
}

test "the next CPU frees from an operation giving CPUs back" {
    const ops = [_]Op{
        // Still starting tasks, and emptying nothing: gives nothing back.
        .{ .ticket = 1, .held = &.{ 0, 1 }, .tasks = 100, .done = 10, .running = 2, .since = 0 },
        // Emptying one: 2 running, 4 ended in 20 s, so about 10 s a task, about 5 s left.
        .{ .ticket = 2, .held = &.{ 2, 3 }, .draining = 1, .tasks = 100, .done = 4, .running = 2, .since = 0 },
    };
    try std.testing.expectApproxEqAbs(5.0, nextFree(&ops, 20).?, 1e-9);
    try std.testing.expectEqual(null, nextFree(ops[0..1], 20));
}

fn tasksJson(a: std.mem.Allocator, now: []const pool_mod.TaskNow) []const statusjson.JsonTask {
    const out = a.alloc(statusjson.JsonTask, now.len) catch return &.{};
    for (now, out) |t, *j| j.* = .{ .task = t.task, .attempt = t.attempt, .cpu = if (t.cpu == std.math.maxInt(u32)) null else t.cpu, .pid = t.pid, .since = t.since };
    return out;
}

test "agentCommand: the command out of Claude Code's wrapper" {
    const wrapped = "/bin/zsh -c source /x/snapshot.sh 2>/dev/null || true && \\builtin setopt NO_EQUALS 2>/dev/null || true && eval 'cd ~/w && zig build' \\< /dev/null && pwd -P >| /tmp/cwd";
    try std.testing.expectEqualStrings("cd ~/w && zig build", agentCommand(wrapped));
    try std.testing.expectEqualStrings("make -j8", agentCommand("make -j8"));
}
