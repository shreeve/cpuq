//! `cpuq status`: the runs and their tasks running, the runs waiting and why, each project's
//! tasks against its fair share of the tokens, and the machine's busy CPUs and gates. This
//! machine's and other hosts', as JSON or as boxed tables.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const policy = @import("policy.zig");
const op_mod = @import("op.zig");
const sys = @import("sys.zig");
const table = @import("table.zig");
const pool_mod = @import("pool.zig");

const main = @import("main.zig");
const texts = @import("texts.zig");
const records = @import("records.zig");
const statusjson = @import("statusjson.zig");

const Pool = pool_mod.Pool;
const Op = pool_mod.Op;
const version = main.version;
const exit_failure = main.exit_failure;
const Ctx = main.Ctx;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const age = texts.age;
const dash = texts.dash;
const JsonRun = statusjson.JsonRun;
const JsonWaiter = statusjson.JsonWaiter;
const JsonProject = statusjson.JsonProject;
const JsonStatus = statusjson.JsonStatus;
const JsonGate = statusjson.JsonGate;
const JsonOutside = statusjson.JsonOutside;
const JsonWork = statusjson.JsonWork;

/// How long `cpuq status` watches the runs' tasks to measure what they keep busy.
const sample_ms = 500;

/// Over this busy per task running, a run's tasks run more than one job each.
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

/// What a short look at every process found.
const Measured = struct {
    /// CPUs each operation's tasks kept busy, as `ops` lists them; null when not measured.
    using: []?f64,
    /// Whether each operation's cpuq is stopped.
    stopped: []bool,
    /// Linux: each operation's tasks waiting on a disk or other device (a process of its tree in
    /// state D); null when not measured.
    io: []?u32,
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
    const io_wait = a.alloc(?u32, ops.len) catch main.fail("out of memory", .{});
    @memset(io_wait, null);
    var m: Measured = .{ .using = using, .stopped = stopped, .io = io_wait };
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
    // Linux: a task waits on I/O while a process of its tree is in state D.
    if (builtin.os.tag == .linux) for (ops, io_wait) |o, *w| {
        var n: u32 = 0;
        for (o.tasks_now) |t| {
            const in_tree = a.alloc(bool, after.len) catch break;
            @memset(in_tree, false);
            sys.markTree(after, t.pid, in_tree);
            for (after, in_tree) |p, yes| if (yes and p.blocked) {
                n += 1;
                break;
            };
        }
        w.* = n;
    };
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

/// The runs waiting, as tickets in the line's order (`pool.lineOrder`: the first in line, then
/// the first of the rest, and so on); then drains, by ticket.
fn lineOrder(a: std.mem.Allocator, ops: []const Op, t: u32) []const u64 {
    var out: std.ArrayList(u64) = .empty;
    out.appendSlice(a, pool_mod.lineOrder(a, ops, t)) catch {};
    for (ops) |o| if (o.drain and o.waiting != 0 and !o.stopped) {
        out.append(a, o.ticket) catch {};
    };
    return out.items;
}

/// The gate as status shows it: the machine's memory and disk gates.
fn gateNow(ctx: *Ctx, a: std.mem.Allocator) JsonGate {
    const m = main.machine(ctx);
    const g = policy.gate(ctx.cfg, m);
    var buf: [256]u8 = undefined;
    switch (g) {
        .open => {},
        .pressure => return .{ .state = "pressure", .text = "closed: memory pressure" },
        .low_memory => |av| return .{ .state = "low_memory", .available = av, .text = a.dupe(u8, texts.gateText(&buf, g)) catch "closed: memory low" },
        .low_disk => |d| return .{ .state = "low_disk", .disk_free = d.free, .disk_path = d.path, .text = a.dupe(u8, texts.gateText(&buf, g)) catch "closed: disk low" },
    }
    return .{ .state = "open", .text = "open" };
}

/// Why a waiter waits, for people: its place in line, then what its cpuq last found.
fn whyText(a: std.mem.Allocator, place: usize, o: Op) []const u8 {
    var ob: [16]u8 = undefined;
    const pos = texts.ordinal(&ob, place);
    if (o.why.len != 0) return a.print("{s} in line; {s}", .{ pos, o.why }) catch o.why;
    return a.print("{s} in line; starts at its next look", .{pos}) catch "";
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
    const now_ms = sys.monoMs();
    const dir = main.stateDir(ctx);
    const pool_cpus = op_mod.poolCpus(ctx);
    const ncpu = op_mod.onlineCpus(io);
    var pool = Pool.open(io, a, dir) catch |err| main.fail("pool {s}/v4: {t}", .{ dir, err });
    const toks = @import("cpus.zig").tokens(io, a, pool_cpus, ctx.cfg.reserve);
    const n: u32 = @intCast(toks.len);

    if (!pool.lockWithin(5000)) lockStuck(ctx, &pool);
    const ops = pool.scan(a);
    pool.unlock();
    pool.renewSample(a, ops, ncpu);
    const sample = pool.readSample(a);

    const m = measureOps(io, a, ops, ncpu, measure);
    const busy = m.busy orelse if (sample) |sm| sm.machine else null;
    const gate = gateNow(ctx, a);
    const held_back = pool_mod.heldBack(a, ops, sample, ctx.cfg.outside_check, ncpu, n, now_ms);
    const free = pool_mod.freeTokens(ops, n, held_back, now_ms);

    var running: u32 = 0;
    var paused: u32 = 0;
    var waiting: u32 = 0;
    // The runs: every run with a task running, or a drain isolating.
    var runs: std.ArrayList(JsonRun) = .empty;
    for (ops, m.using, m.stopped, m.io) |o, using, stopped, io_n| {
        if (o.counts() or o.drain) {
            running += o.running;
            paused += o.paused();
            waiting += if (o.drain) 0 else o.waiting;
        }
        if (o.running == 0 and !(o.drain and o.dstart != 0) and !o.driver) continue;
        var flags: std.ArrayList([]const u8) = .empty;
        if (o.drain and o.dstart != 0 and now - o.since >= @as(i64, ctx.cfg.drain_timeout_s)) flags.append(a, "long_drain") catch {};
        if (o.drain and o.dstart != 0 and o.noise >= op_mod.noisy_min) flags.append(a, "noisy") catch {};
        if (using) |u| if (o.drain and o.running != 0 and now - o.since >= 5) {
            if (u < op_mod.drain_idle_busy) flags.append(a, "idle_drain") catch {};
        } else if (!o.drain and o.running > o.paused() and now - o.since >= 5) {
            if (u / @as(f64, @floatFromInt(o.running - o.paused())) > over_use) flags.append(a, "over_cpu") catch {};
        };
        if (stopped or o.stopped) flags.append(a, "stopped") catch {};
        if (o.driver and o.dbusy >= pool_mod.driver_min) flags.append(a, "driver_cpu") catch {};
        // Held back by its own -c: tasks queued while the machine has room.
        if (!o.drain and o.running >= o.limit and o.tasks > o.done + o.failed + o.running and free > 0) flags.append(a, "capped") catch {};
        const ended = o.done + o.failed;
        const ran: f64 = @floatFromInt(@max(now - o.since, 0));
        runs.append(a, .{
            .ticket = o.ticket,
            .pid = o.pid,
            .project = o.project,
            .weight = o.weight,
            .limit = o.limit,
            .width = o.width,
            .tasks = o.tasks,
            .done = o.done,
            .failed = o.failed,
            .running = o.running,
            .paused = o.paused(),
            .waiting = if (o.drain) 0 else o.waiting,
            .running_tasks = tasksJson(a, o.tasks_now),
            .io_wait = io_n,
            .tail = !o.drain and !o.driver and o.running != 0 and o.done + o.failed + o.running >= o.tasks,
            .oldest = oldestOf(o),
            .stopped = stopped or o.stopped,
            .driver = o.driver,
            .driver_busy = o.dbusy,
            .drain = o.drain,
            .pin = o.pin,
            .cpus = o.cpus,
            .noise = o.noise,
            .noisy_top = o.noisy_top,
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

    // The line, in its order.
    var waiters: std.ArrayList(JsonWaiter) = .empty;
    for (lineOrder(a, ops, n), 1..) |tk, place| {
        const o = for (ops) |o| {
            if (o.ticket == tk) break o;
        } else continue;
        waiters.append(a, .{
            .order = place,
            .ticket = o.ticket,
            .pid = o.pid,
            .project = o.project,
            .waiting = o.waiting,
            .running = o.running,
            .max = o.limit,
            .drain = o.drain,
            .urgent = o.urgent,
            .why = whyText(a, place, o),
            .label = o.label,
            .command = o.cmd,
            .since = o.since,
        }) catch {};
    }

    // Each project's tasks against its fair share.
    var projects: std.ArrayList(JsonProject) = .empty;
    for (ops) |o| {
        if (o.drain) continue;
        const k = for (projects.items, 0..) |q, k| {
            if (std.mem.eql(u8, q.name, o.project)) break k;
        } else projects.items.len;
        if (k == projects.items.len) projects.append(a, .{ .name = o.project }) catch continue;
        const p = &projects.items[k];
        p.weight = @max(p.weight, o.weight);
        p.runs += 1;
        if (o.counts()) {
            p.running += o.running;
            p.waiting += o.waiting;
        }
    }
    for (projects.items) |*p| p.fair = pool_mod.fairShare(a, ops, p.name, n);

    const pressure = if (ctx.cfg.pressure_check) sys.memoryPressure(io, ctx.cfg.pressure_psi) else .off;
    return .{
        .dir = pool.path,
        .pool = pool_cpus,
        .tokens = n,
        .token_cpus = toks,
        .reserve = @as(u32, @intCast(pool_cpus.len)) - n,
        .held = pool_mod.heldCount(ops, now_ms),
        .held_back = held_back,
        .free = free,
        .isolated = pool_mod.isolated(a, ops, now_ms),
        .cores = sys.totalCpus(io),
        .active_cores = ncpu,
        .running = running,
        .paused = paused,
        .waiting = waiting,
        .busy = busy,
        .tasks_busy = m.tasks,
        .load = sys.loadAverage(),
        .memory_pressure = @tagName(pressure),
        .memory = sys.memory(io),
        .gate = gate,
        .runs = runs.items,
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

/// How far a run is: "12/20 done · 1 failed" ("none failed" too); with only its running tasks left, the tail: "last
/// task, running 32m", "last 3 tasks, oldest running 32m"; a single task, "running 32m".
fn tasksText(a: std.mem.Allocator, h: JsonRun, now: i64) []const u8 {
    var b: [16]u8 = undefined;
    const ran = if (h.oldest != 0) age(&b, now - h.oldest) else "";
    if (h.tasks <= 1) return if (h.running != 0) (a.print("running {s}", .{ran}) catch "running") else "starting";
    // Failed always, "none" too: "206/208 done" with nothing after it reads as two lost.
    const failed = if (h.failed != 0) a.print(" · {d} failed", .{h.failed}) catch "" else " · none failed";
    if (h.tail) {
        if (h.running == 1) return a.print("last task, running {s}{s}", .{ ran, failed }) catch "last task";
        return a.print("last {d} tasks, oldest running {s}{s}", .{ h.running, ran, failed }) catch "last tasks";
    }
    return a.print("{d}/{d} done{s}", .{ h.done + h.failed, h.tasks, failed }) catch "?";
}

/// When a run's oldest running task started (Unix seconds); 0 when none runs.
fn oldestOf(o: Op) i64 {
    var oldest: i64 = 0;
    for (o.tasks_now) |t| if (t.since != 0 and (oldest == 0 or t.since < oldest)) {
        oldest = t.since;
    };
    return oldest;
}

/// Its tasks running and the CPUs whose tokens they hold, its -c, or a drain's CPUs: "3 on 0-2",
/// "2 of -c 2 on 4,5", "drain 6-7".
fn runText(a: std.mem.Allocator, h: JsonRun) []const u8 {
    if (h.driver) return a.print("driver · {d:.1} busy itself", .{h.driver_busy}) catch "driver";
    if (h.drain) {
        const iso = if (h.cpus.len > h.pin.len) a.print(" (isolates {s})", .{cpuText(a, h.cpus)}) catch "" else "";
        return a.print("drain {s}{s}", .{ cpuText(a, h.pin), iso }) catch "drain";
    }
    var on: std.ArrayList(u32) = .empty;
    for (h.running_tasks) |t| if (!t.paused) on.appendSlice(a, t.cpus) catch break;
    std.mem.sort(u32, on.items, {}, std.sort.asc(u32));
    const where = if (on.items.len != 0) a.print(" on {s}", .{cpuText(a, on.items)}) catch "" else "";
    const stopped = if (h.paused != 0) a.print(" · {d} stopped", .{h.paused}) catch "" else "";
    const io = if (h.io_wait) |n| (if (n != 0) a.print(" · {d} on I/O", .{n}) catch "" else "") else "";
    const c = if (h.running >= h.limit and h.tasks > 1) a.print(" of -c {d}", .{h.limit}) catch "" else "";
    // A run of -j K: the tokens its tasks hold ("2 on 41,89 · -j 2").
    if (h.width > 1) return a.print("{d}{s}{s} · -j {d}{s}{s}", .{ h.running * h.width, c, where, h.width, stopped, io }) catch "?";
    return a.print("{d}{s}{s}{s}{s}", .{ h.running, c, where, stopped, io }) catch "?";
}

/// How long it has run, with the time left at its rate so far: "2m10s · ~1m left".
fn sinceText(a: std.mem.Allocator, h: JsonRun, now: i64) []const u8 {
    var b: [16]u8 = undefined;
    const ran = a.dupe(u8, age(&b, now - h.since)) catch "?";
    // Once only its last tasks run, the quick ones' rate says nothing of them: the tail says
    // how long they've run instead.
    if (h.tail) return ran;
    const l = h.left orelse return ran;
    var lb: [16]u8 = undefined;
    return a.print("{s} · ~{s} left", .{ ran, age(&lb, @intFromFloat(@ceil(l))) }) catch ran;
}

/// A pid as text: a signed number printed in a padded field shows its sign.
fn pidText(a: std.mem.Allocator, pid: i32) []const u8 {
    return a.print("{d}", .{pid}) catch "?";
}

fn whoText(a: std.mem.Allocator, h: JsonRun) []const u8 {
    return a.print("run {d} ({s})", .{ h.ticket, dash(h.label) }) catch "run";
}

/// A line for each flag on each run: what deserves a look, and what to do about it.
fn flagNotes(a: std.mem.Allocator, runs: []const JsonRun) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (runs) |h| for (h.flags) |f| {
        const per = if (h.using) |u| u / @as(f64, @floatFromInt(@max(h.running -| h.paused, 1))) else 0;
        const line = if (std.mem.eql(u8, f, "over_cpu"))
            a.print("{s}: {d:.2} CPUs busy per task: a task runs more than one job (give it -j1, or split it into tasks)", .{ whoText(a, h), per })
        else if (std.mem.eql(u8, f, "capped"))
            a.print("{s}: {d} tasks queued under its -c {d} while the machine has room; raise it with cpuq limit {d} -c N", .{ whoText(a, h), h.tasks -| (h.done + h.failed + h.running), h.limit, h.ticket })
        else if (std.mem.eql(u8, f, "idle_drain"))
            a.print("{s}: a drain whose command keeps {d:.2} CPUs busy; under {d:.2} for `drain_idle` while others wait, it is stopped", .{ whoText(a, h), h.using orelse 0, op_mod.drain_idle_busy })
        else if (std.mem.eql(u8, f, "driver_cpu"))
            a.print("{s}: driver computes {d:.1} CPUs itself; run its work as tasks (it counts against its project's share meanwhile)", .{ whoText(a, h), h.driver_busy })
        else if (std.mem.eql(u8, f, "noisy"))
            a.print("{s}: work from outside it keeps {d:.2} CPUs busy on its CPUs{s}{s}: its timing is noisy", .{ whoText(a, h), h.noise, if (h.noisy_top.len != 0) ", most " else "", h.noisy_top })
        else if (std.mem.eql(u8, f, "long_drain"))
            a.print("{s}: a drain past config `drain_timeout`; it ends at its -t (at most 2h)", .{whoText(a, h)})
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

/// Work someone ran: started by an agent, ssh, a terminal or cron, or detached in a folder of its
/// own (`nohup make &` keeps the folder it was started in). An app or a system service runs
/// detached in `/`; it counts in the load but isn't listed as work to move under cpuq.
fn ranBySomeone(wk: JsonWork) bool {
    const detached = std.mem.eql(u8, wk.via, "launchd") or std.mem.eql(u8, wk.via, "systemd") or std.mem.eql(u8, wk.via, "init");
    return !detached or !(wk.cwd.len == 0 or std.mem.eql(u8, wk.cwd, "/"));
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

    // The pool: the tokens, tasks running and waiting, the machine busy, and the gate.
    const high = std.mem.eql(u8, st.memory_pressure, "high");
    const mem: C = if (st.memory) |m| .{
        .text = a.print("{s}{s}", .{ ofGb(a, m.used, m.total), if (high) ", pressure" else "" }) catch "?",
        .tint = if (high) .bad else if (std.mem.eql(u8, st.memory_pressure, "normal")) .good else null,
    } else .{ .text = if (st.memory_pressure.len != 0) st.memory_pressure else "-", .tint = if (high) .bad else .dim };
    const busy: C = if (st.busy) |b| .{ .text = a.print("{d:.1} of {d}", .{ b, st.active_cores }) catch "?" } else .{ .text = "-", .tint = .dim };
    const tasks: C = if (st.tasks_busy) |t| .{ .text = a.print("{d:.1}", .{t}) catch "?" } else .{ .text = "-", .tint = .dim };
    const outside: C = if (st.busy) |b| if (st.tasks_busy) |t| blk: {
        const o = @max(0, b - t);
        break :blk .{ .text = a.print("{d:.1}", .{o}) catch "?", .tint = if (o >= 1) .warn else null };
    } else .{ .text = "-", .tint = .dim } else .{ .text = "-", .tint = .dim };
    const gate_open = std.mem.eql(u8, st.gate.state, "open");
    const cap: C = .{
        .text = a.print("{d} · {d} reserved", .{ st.tokens, st.reserve }) catch "?",
    };
    const free: C = .{
        .text = if (st.held_back != 0) a.print("{d} · {d} held back", .{ st.free, st.held_back }) catch "?" else a.print("{d}", .{st.free}) catch "?",
        .tint = if (st.held_back != 0) .warn else if (st.free == 0) .dim else null,
    };
    const summary: table.Table = .{
        .title = a.print("cpuq {s}{s}{s}", .{ st.version, if (short_host.len != 0) " · " else "", short_host }) catch "cpuq",
        .columns = &.{
            .{ .head = "TOKENS", .alignment = .right },
            .{ .head = "FREE", .alignment = .right },
            .{ .head = "RUNNING", .alignment = .right },
            .{ .head = "WAITING", .alignment = .right },
            .{ .head = "BUSY", .sub = "CPUs", .alignment = .right },
            .{ .head = "TASKS", .alignment = .right },
            .{ .head = "OUTSIDE", .alignment = .right },
            .{ .head = "LOAD", .sub = "1 5 15" },
            .{ .head = "MEMORY" },
            .{ .head = "GATE" },
        },
        .rows = &.{&.{
            cap,
            free,
            .{ .text = if (st.paused != 0) a.print("{d} · {d} stopped", .{ st.running, st.paused }) catch "?" else a.print("{d}", .{st.running}) catch "?", .tint = if (st.running != 0) .accent else null },
            .{ .text = a.print("{d}", .{st.waiting}) catch "?", .tint = if (st.waiting != 0 and st.free > 0) .warn else null },
            busy,
            tasks,
            outside,
            loadCell(a, st.load, st.active_cores),
            mem,
            .{ .text = st.gate.text, .tint = if (gate_open) .good else .bad },
        }},
    };
    summary.boxed(a, w, width, color) catch {};

    // The runs and their tasks.
    if (st.runs.len != 0) {
        var rows: std.ArrayList([]const C) = .empty;
        for (st.runs) |h| {
            const flagged = h.flags.len != 0;
            const using: C = if (h.using) |u| .{
                .text = a.print("{d:.2}", .{u}) catch "?",
                .tint = if (flagged) .warn else null,
            } else .{ .text = "-", .tint = .dim };
            rows.append(a, a.dupe(C, &.{
                .{ .text = a.print("{d}", .{h.ticket}) catch "?", .tint = .dim },
                .{ .text = dash(h.project) },
                .{ .text = dash(h.label), .tint = .accent },
                .{ .text = tasksText(a, h, now), .tint = if (h.failed != 0) .warn else null },
                .{ .text = runText(a, h), .tint = if (h.paused != 0) .warn else null },
                using,
                .{ .text = sinceText(a, h, now) },
                .{ .text = a.print("{d}", .{h.pid}) catch "?", .tint = if (h.stopped) .bad else .dim },
                .{ .text = h.command },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("running: {d} task{s} in {d} run{s}", .{ st.running, if (st.running == 1) "" else "s", st.runs.len, if (st.runs.len == 1) "" else "s" }) catch "running",
            .columns = &.{
                .{ .head = "RUN", .alignment = .right },
                .{ .head = "PROJECT" },
                .{ .head = "LABEL" },
                .{ .head = "TASKS" },
                .{ .head = "RUNNING" },
                .{ .head = "BUSY", .sub = "CPUs", .alignment = .right },
                .{ .head = "SINCE" },
                .{ .head = "PID", .alignment = .right },
                .{ .head = "COMMAND", .flexible = true },
            },
            .rows = rows.items,
            .notes = flagNotes(a, st.runs),
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
                .{ .text = a.print("{d}", .{q.running}) catch "?" },
                .{ .text = if (q.drain) a.print("drain {d}", .{q.max}) catch "?" else a.print("{d}", .{q.waiting}) catch "?", .tint = if (q.drain or q.urgent) .warn else null },
                .{ .text = a.dupe(u8, age(&b, now - q.since)) catch "?" },
                .{ .text = q.why },
                .{ .text = q.command },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("waiting ({d})", .{st.waiters.len}) catch "waiting",
            .columns = &.{
                .{ .head = "#", .alignment = .right },
                .{ .head = "RUN", .alignment = .right },
                .{ .head = "PROJECT" },
                .{ .head = "LABEL" },
                .{ .head = "RUNNING", .alignment = .right },
                .{ .head = "WAITING", .alignment = .right },
                .{ .head = "SINCE" },
                .{ .head = "WHY" },
                .{ .head = "COMMAND", .flexible = true },
            },
            .rows = rows.items,
        };
        w.writeAll("\n") catch {};
        t.boxed(a, w, width, color) catch {};
    }

    // Each project's tasks against its fair share.
    if (st.projects.len != 0) {
        var rows: std.ArrayList([]const C) = .empty;
        for (st.projects) |p| {
            const r: f64 = @floatFromInt(p.running);
            rows.append(a, a.dupe(C, &.{
                .{ .text = dash(p.name), .tint = .accent },
                .{ .text = a.print("{d}", .{p.weight}) catch "?" },
                .{ .text = a.print("{d}", .{p.runs}) catch "?" },
                // Under its share while tasks wait: something (a gate, a -c) holds it back.
                .{ .text = a.print("{d}", .{p.running}) catch "?", .tint = if (p.waiting != 0 and r < p.fair) .warn else null },
                .{ .text = a.print("{d}", .{p.waiting}) catch "?" },
                .{ .text = a.print("{d:.1}", .{p.fair}) catch "?" },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("projects: tasks running against the fair share of {d} tokens by weight", .{st.tokens}) catch "projects",
            .columns = &.{
                .{ .head = "PROJECT" },
                .{ .head = "WEIGHT", .alignment = .right },
                .{ .head = "RUNS", .alignment = .right },
                .{ .head = "RUNNING", .alignment = .right },
                .{ .head = "WAITING", .alignment = .right },
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
            if (!ranBySomeone(wk)) continue;
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
    if (st.runs.len == 0 and st.waiters.len == 0) notes.append(a, "nothing running or waiting") catch {};
    if (st.waiting != 0 and st.free > 0 and gate_open) notes.append(a, a.print("{d} token{s} free: the first in line takes one at its next look", .{ st.free, if (st.free == 1) "" else "s" }) catch "") catch {};
    if (st.runs.len != 0) notes.append(a, "end a run: cpuq kill RUN · for scripts: cpuq status --json") catch {} else notes.append(a, "for scripts: cpuq status --json") catch {};
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
    w.print("pool    {d} CPUs ({s}); {d} tokens, {d} reserved; {d} held, {d} free", .{ st.pool.len, cpuText(a, st.pool), st.tokens, st.reserve, st.held, st.free }) catch {};
    if (st.held_back != 0) w.print(" ({d} held back for work outside cpuq)", .{st.held_back}) catch {};
    if (st.isolated.len != 0) w.print(" ({s} isolated by drains)", .{cpuText(a, st.isolated)}) catch {};
    w.print("; running {d}", .{st.running}) catch {};
    if (st.paused != 0) w.print(" ({d} stopped)", .{st.paused}) catch {};
    w.print(", waiting {d}\n", .{st.waiting}) catch {};
    if (st.busy) |bz| {
        w.print("busy    {d:.1} of {d} CPUs online", .{ bz, st.active_cores }) catch {};
        if (st.tasks_busy) |t| w.print("; cpuq's tasks {d:.1}, outside {d:.1}", .{ t, @max(0, bz - t) }) catch {};
        w.writeAll("\n") catch {};
    }
    w.print("load    {d:.2} {d:.2} {d:.2}; memory pressure {s}; gate {s}\n", .{ st.load[0], st.load[1], st.load[2], st.memory_pressure, st.gate.text }) catch {};
    if (st.memory) |mem| w.print("memory  {s}\n", .{memoryText(a, mem)}) catch {};
    if (showOutside(st)) {
        var listed: usize = 0;
        for (st.outside_work) |wk| listed += @intFromBool(ranBySomeone(wk));
        w.print("outside {d:.1} CPUs busy outside cpuq{s}\n", .{ st.outside_total, if (listed == 0) ", by apps and services" else ", by what started it:" }) catch {};
        for (st.outside_work) |wk| if (ranBySomeone(wk)) w.print("  {d:>5.1}  {s}  (pid {d} via {s}, {d} process{s}, in {s})\n", .{
            wk.using, workCommand(wk), wk.pid, if (wk.via.len == 0) "?" else wk.via, wk.procs, if (wk.procs == 1) "" else "es", if (wk.cwd.len == 0) "?" else wk.cwd,
        }) catch {};
    }

    w.print("\nrunning ({d})\n", .{st.runs.len}) catch {};
    if (st.runs.len != 0) w.writeAll("  RUN    PID      PROJECT      LABEL                TASKS        RUNNING          BUSY  SINCE    COMMAND\n") catch {};
    for (st.runs) |h| {
        var ub: [16]u8 = undefined;
        const using = if (h.using) |u| std.mem.print(&ub, "{d:.2}", .{u}) catch "?" else "-";
        w.print("  {d:<6} {s:<8} {s:<12} {s:<20} {s:<12} {s:<16} {s:<5} {s:<8} {s}\n", .{
            h.ticket, pidText(a, h.pid), dash(h.project), dash(h.label), tasksText(a, h, now), runText(a, h), using, age(&b, now - h.since), h.command,
        }) catch {};
    }
    for (flagNotes(a, st.runs)) |n| w.print("  flag: {s}\n", .{n}) catch {};

    w.print("\nwaiting ({d})\n", .{st.waiters.len}) catch {};
    if (st.waiters.len != 0) w.writeAll("  #    RUN    PID      PROJECT      LABEL                RUNNING WAITING WHY\n") catch {};
    for (st.waiters) |q| {
        var cb: [16]u8 = undefined;
        const wants = if (q.drain) std.mem.print(&cb, "d{d}", .{q.max}) catch "?" else std.mem.print(&cb, "{d}", .{q.waiting}) catch "?";
        w.print("  {d:<4} {d:<6} {s:<8} {s:<12} {s:<20} {d:<7} {s:<7} {s}\n", .{ q.order, q.ticket, pidText(a, q.pid), dash(q.project), dash(q.label), q.running, wants, q.why }) catch {};
    }

    if (st.projects.len != 0) {
        w.writeAll("\nprojects\n  PROJECT      WEIGHT RUNS RUNNING WAITING FAIR\n") catch {};
        for (st.projects) |p| w.print("  {s:<12} {d:<6} {d:<4} {d:<7} {d:<7} {d:.1}\n", .{ dash(p.name), p.weight, p.runs, p.running, p.waiting, p.fair }) catch {};
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

test "the line's order: under their share first, then by project share, drains last" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Capacity 4: rig runs 3, trig 1 with tasks waiting, rip none yet; a drain waits.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 3, .waiting = 5 },
        .{ .ticket = 2, .project = "trig", .running = 1, .waiting = 5 },
        .{ .ticket = 3, .project = "rip", .waiting = 2 },
        .{ .ticket = 4, .drain = true, .limit = 1, .waiting = 1 },
        .{ .ticket = 5, .project = "emdb", .running = 1 },
    };
    // Shares of 4 among 4 projects: 1 each. rip (0 of 1) is under its share; then trig (1),
    // then rig (3); the drain last.
    try std.testing.expectEqualSlices(u64, &.{ 3, 2, 1, 4 }, lineOrder(a, &ops, 4));
}

fn tasksJson(a: std.mem.Allocator, now: []const pool_mod.TaskNow) []const statusjson.JsonTask {
    const out = a.alloc(statusjson.JsonTask, now.len) catch return &.{};
    for (now, out) |t, *j| j.* = .{ .task = t.task, .attempt = t.attempt, .pid = t.pid, .since = t.since, .paused = t.paused, .cpu = if (t.cpus.len != 0) t.cpus[0] else 0, .cpus = t.cpus };
    return out;
}

test "agentCommand: the command out of Claude Code's wrapper" {
    const wrapped = "/bin/zsh -c source /x/snapshot.sh 2>/dev/null || true && \\builtin setopt NO_EQUALS 2>/dev/null || true && eval 'cd ~/w && zig build' \\< /dev/null && pwd -P >| /tmp/cwd";
    try std.testing.expectEqualStrings("cd ~/w && zig build", agentCommand(wrapped));
    try std.testing.expectEqualStrings("make -j8", agentCommand("make -j8"));
}

test "ranBySomeone: apps and services in / are not work someone ran" {
    try std.testing.expect(ranBySomeone(.{ .via = "claude", .cwd = "/" }));
    try std.testing.expect(ranBySomeone(.{ .via = "sshd-session", .cwd = "/home/s" }));
    try std.testing.expect(!ranBySomeone(.{ .via = "launchd", .cwd = "/" }));
    try std.testing.expect(!ranBySomeone(.{ .via = "systemd", .cwd = "" }));
    try std.testing.expect(ranBySomeone(.{ .via = "init", .cwd = "/home/s/emdb" }));
}
