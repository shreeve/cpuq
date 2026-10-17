//! Admission: a run waits in the queue for its cores (or a named lease's slot), takes its
//! grant, and gives it back.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");
const history = @import("history.zig");
const place = @import("place.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");
const repos = @import("repos.zig");
const joblog = @import("joblog.zig");
const texts = @import("texts.zig");
const runner = @import("runner.zig");
const leasing = @import("leasing.zig");
const runtimes = @import("runtimes.zig");
const statusjson = @import("statusjson.zig");

const exit_timeout = main.exit_timeout;
const Ctx = main.Ctx;
const fail = main.fail;
const nowSeconds = main.nowSeconds;
const reloadConfig = main.reloadConfig;
const machine = main.machine;
const budgetNow = main.budgetNow;
const RunOptions = runopts.RunOptions;
const joinCommand = runopts.joinCommand;
const jobWorkKey = repos.jobWorkKey;
const Lease = joblog.Lease;
const JobLog = joblog.JobLog;
const nowFloat = joblog.nowFloat;
const newJobLog = joblog.newJobLog;
const logEvent = joblog.logEvent;
const logAndArm = joblog.logAndArm;
const className = texts.className;
const ordinal = texts.ordinal;
const age = texts.age;
const gateText = texts.gateText;
const exclusiveOff = leasing.exclusiveOff;
const jobUses = runtimes.jobUses;
const useOf = runtimes.useOf;
const RunTimes = runtimes.RunTimes;
const estimate = runtimes.estimate;
const JsonWaiter = statusjson.JsonWaiter;
const toHolders = statusjson.toHolders;

pub fn lockOrFail(st: *state.State) void {
    st.lock() catch |err| fail("admission lock: {t}", .{err});
}

/// Queues this run and returns once it holds its cores, or for a named
/// lease, one of its slots: a pool of `--slots` (1 by default), with no
/// machine gates.
pub fn waitTurn(ctx: *Ctx, st: *state.State, asked: RunOptions) Lease {
    const io = ctx.io;
    var cfg = ctx.cfg;
    var o = asked;
    const named = o.lease != null;
    // Run times from history, read once when right-sizing or backfill first
    // needs them.
    var run_times: ?RunTimes = null;
    // Right-sizing: a range request capped near what its label has used.
    if (!named and !o.exclusive and cfg.admit == .cores and cfg.right_size and !o.request.fixed() and o.label.len != 0) {
        run_times = RunTimes.load(ctx, ctx.arena);
        if (run_times.?.uses.get(o.label)) |uses| {
            const sized = policy.rightSize(o.request, uses.items);
            if (sized.max < o.request.max) {
                std.debug.print("cpuq: asked for {d}-{d} cores; {s} has used about {d:.1}, so up to {d}\n", .{ o.request.min, o.request.max, o.label, history.median(uses.items), sized.max });
                o.request = sized;
            }
        }
    }
    // A small fixed count for work that takes its width from cpuq and used all it had: widened
    // (place.widen), as a count written in for a small machine starves it on any other.
    // The job's work, as history keys it: found once, not on every poll.
    const work_key = jobWorkKey(ctx, o);
    if (!named and !o.exclusive and !o.hidden and o.cores_given and o.request.fixed() and place.scales(joinCommand(ctx, o.cmd))) {
        if (run_times == null) run_times = RunTimes.load(ctx, ctx.arena);
        const work = run_times.?.workStats(ctx.arena, null, work_key);
        const w = place.widen(o.request.max, true, work, sys.totalCpus(io));
        if (w.max > o.request.max) {
            std.debug.print("cpuq: asked for {d} cores; this work has kept {d:.1} busy, so {d}-{d}\n", .{ o.request.max, work.used, w.min, w.max });
            o.request = .{ .min = w.min, .max = w.max };
        }
    }
    // The CPUs' busy share is measured between polls.
    var ticks = sys.cpuTicks(io);
    const cores: u32 = if (named) o.slots else sys.totalCpus(io);
    const start = nowSeconds(io);
    // In history, and its last words armed, before its ticket shows it
    // waiting: killed as soon as it is seen in the queue, it gave up.
    const job = newJobLog(ctx, o);
    logAndArm(ctx, job, "queued", .{}, "gave_up", null);

    lockOrFail(st);
    var rec: state.Record = .{
        .ticket = st.nextTicket() catch |err| fail("ticket: {t}", .{err}),
        .pid = sys.getpid(),
        .cores = o.request.min,
        .max = o.request.max,
        .priority = o.priority,
        .exclusive = o.exclusive,
        .since = start,
        .label = o.label,
        .note = o.note,
        .cmd = joinCommand(ctx, o.cmd),
        .first = o.first,
        .hidden = o.hidden,
    };
    var name_buf: [32]u8 = undefined;
    const ticket_name = state.ticketName(&name_buf, o.priority, rec.ticket);
    const ticket = st.createTicket(rec, ticket_name) catch |err| fail("ticket: {t}", .{err});
    st.unlock();

    var next_note = start + cfg.note_s;
    var last_gate: policy.Gate = .open;
    var hinted = false;
    var hinted_fixed = false;
    while (true) {
        reloadConfig(ctx);
        cfg = ctx.cfg;
        // `exclusive = off` set while it waits: it waits on as an ordinary job, no longer
        // draining the machine for a window it won't get.
        if (o.exclusive and !cfg.exclusive) {
            o.exclusive = exclusiveOff(o.label);
            lockOrFail(st);
            rec.exclusive = false;
            keepNote(ctx.arena, io, ticket, &rec);
            rewriteRecord(io, ticket, rec);
            st.unlock();
        }
        const now_ticks = sys.cpuTicks(io);
        var mach = machine(ctx);
        if (ticks) |t0| if (now_ticks) |t1| {
            mach.busy = sys.busyBetween(t0, t1);
        };
        ticks = now_ticks;
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        lockOrFail(st);
        const now = nowSeconds(io);
        const queue = servedOrder(ctx, st, a, state.scanQueue(st, a, ticket_name, rec, now, cfg.aging_s) catch |err| fail("queue: {t}", .{err}), now, !named);
        const pos = for (queue, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, ticket_name)) break i;
        } else fail("ticket {s} vanished from the queue", .{ticket_name});

        // Waiting to hold a lease for someone who has gone (their
        // connection dropped): give up rather than hold it for nobody.
        if (sys.StdinWatch.gone(runner.hold_quiet_ms)) {
            std.debug.print("cpuq: whoever this {s} was for has gone; giving up\n", .{if (runner.tethered) "run" else "hold"});
            giveUp(ctx, st, ticket_name, now - start, job);
        }

        // A hand-given order (`cpuq first`, `start`, `cancel`).
        if (!named) if (st.takeControl(ticket_name)) |action| {
            if (std.mem.eql(u8, action, "cancel")) {
                std.debug.print("cpuq: cancelled by hand\n", .{});
                giveUp(ctx, st, ticket_name, now - start, job);
            } else if (std.mem.eql(u8, action, "first")) {
                rec.first = true;
                keepNote(a, io, ticket, &rec);
                rewriteRecord(io, ticket, rec);
                std.debug.print("cpuq: moved to the front by hand\n", .{});
            } else if (std.mem.eql(u8, action, "start")) {
                // Past the queue, the budget and the gates, but never into an
                // exclusive run: that is a timing window.
                if ((state.scanLeases(st, a, true) catch @as([]state.Entry, &.{})).len != 0) {
                    std.debug.print("cpuq: not started by hand: an exclusive run holds the machine; still waiting\n", .{});
                } else {
                    // An exclusive run started by hand opens its window on the
                    // cores that are free, beside those still held.
                    const over: u32 = @intCast(heldCores(st, a) + o.request.max);
                    const all = @max(cores, over);
                    const got = state.takeTokens(st, ctx.arena, o.request, o.exclusive, if (o.exclusive) all else over, all, false, 0, if (o.exclusive) std.math.maxInt(u32) else 0) catch |err| fail("tokens: {t}", .{err});
                    if (got) |grant| {
                        std.debug.print("cpuq: started by hand on {d} {s}, past the queue\n", .{ grant.files.len, if (grant.files.len == 1) "core" else "cores" });
                        runner.forced_now = true;
                        return admitted(ctx, st, o, &rec, grant, ticket, ticket_name, job, now, false);
                    }
                }
            }
        };

        // Out of time: give up, but only after the head has tried once, so
        // --max-wait 0 takes what is free now and otherwise gives up.
        const out_of_time = if (o.max_wait) |mw| now - start >= mw else false;
        if (out_of_time and pos > 0) giveUp(ctx, st, ticket_name, now - start, job);
        if (now >= next_note) {
            note(ctx, st, a, now - start, queue, pos, last_gate, o.lease);
            // A program waiting without --max-wait (an agent's tool call, a
            // script) may be killed by its own timeout first: say so once.
            if (!hinted and o.max_wait == null and std.c.isatty(0) == 0) {
                std.debug.print("cpuq: no --max-wait: if this caller has a timeout, it may end this wait before the job starts\n", .{});
                hinted = true;
            }
            next_note = now + cfg.note_s;
        }
        var wake_ms: i64 = @min(next_note - now, 60) * 1000;
        if (o.max_wait) |mw| wake_ms = @min(wake_ms, (start + mw - now) * 1000);
        wake_ms = @max(wake_ms, 100);
        // The first few waiters, of every kind, look again every 2 seconds
        // for a hand-given order (`cpuq cancel`, `first`, `start`) and for
        // room; an exclusive waiter behind the head used to sleep up to a
        // minute on the one ahead, and a cancel sat unseen meanwhile. The
        // rest keep sleeping on the one ahead, so a long queue costs little.
        if (pos < 8) wake_ms = @min(wake_ms, 2000);

        if (pos > 0) {
            // Behind the head, under measured admission: start now if this
            // job fits the room the running ones leave and the head, which
            // goes first, still fits after it (or has waited less than its
            // patience); behind an exclusive head, only as backfill allows.
            // The machine's checks hold it as they hold the head: memory
            // pressure, low memory, CPUs measured all but full; and with
            // backfill off, nothing starts ahead of the head.
            const saturated = cfg.load_check and o.load_check and if (mach.busy) |b| b >= 0.97 else false;
            const machine_open = policy.gate(cfg, mach, 0, null, now) == .open and !saturated;
            if (!named and !o.exclusive and cfg.admit == .measured and cfg.backfill and !queue[0].record.exclusive and machine_open) {
                if (run_times == null) run_times = RunTimes.load(ctx, ctx.arena);
                const m = measuredLoad(ctx, st, a, &run_times.?, mach.busy, mach.active);
                // Work cpuq cannot freeze never starts in a lending window.
                if (!m.exclusive and !(o.hidden and m.lent)) {
                    const room = targetCpus(ctx) - m.charged;
                    const req = policy.measuredGrant(o.request, o.cores_given, if (o.hidden) &.{} else jobUses(ctx, run_times.?, work_key, o), room, cores);
                    const mine = policy.charge(useOf(run_times.?, o.label), null, 0, 1, req.max);
                    const head = queue[0].record;
                    const head_need = policy.charge(useOf(run_times.?, head.label), null, 0, 1, @max(head.cores, 1));
                    const head_waited: f64 = @floatFromInt(now - head.since);
                    if (mine <= room and (mine + head_need <= room or head_waited < @as(f64, @floatFromInt(cfg.patience_s)))) {
                        if (state.takeTokens(st, ctx.arena, req, false, poolCap(ctx), poolCap(ctx), false, 0, 0) catch |err| fail("tokens: {t}", .{err})) |grant| {
                            std.debug.print("cpuq: starting ahead of {s} on {d} {s}: the CPUs have room\n", .{ if (head.label.len != 0) head.label else head.cmd, grant.files.len, if (grant.files.len == 1) "core" else "cores" });
                            return admitted(ctx, st, o, &rec, grant, ticket, ticket_name, job, now, true);
                        }
                    }
                }
            } else if (!named and !o.exclusive and cfg.backfill and (cfg.window_backfill or !queue[0].record.exclusive)) {
                const budget: u32 = budgetNow(ctx, mach);
                var v = st.readValve();
                const g = policy.gate(cfg, mach, budget, if (o.load_check) &v else null, now);
                if (g == .open) if (goAhead(ctx, st, a, o, queue, pos, budget, now, &run_times)) |req| {
                    const got = state.takeTokens(st, ctx.arena, req, false, budget, @max(cores, budget), false, 0, 0) catch |err| fail("tokens: {t}", .{err});
                    if (got) |grant| {
                        const head = queue[0].record;
                        std.debug.print("cpuq: starting ahead of {s}, which waits for {d} cores, on {d} of the free ones\n", .{ if (head.label.len != 0) head.label else head.cmd, head.cores, grant.files.len });
                        if (o.load_check and cfg.load_check) {
                            v.last_admit = now;
                            st.writeValve(v);
                        }
                        return admitted(ctx, st, o, &rec, grant, ticket, ticket_name, job, now, true);
                    }
                };
            }
            const pred = st.queue.openFile(io, queue[pos - 1].name, .{}) catch null;
            st.unlock();
            if (pred) |f| {
                waitOn(io, f, wake_ms);
                f.close(io);
            }
            continue;
        }

        var valve = st.readValve();
        const budget: u32 = if (named) o.slots else budgetNow(ctx, mach);
        // Measured admission has no load valve: it reads the CPUs directly.
        const valved = o.load_check and cfg.admit == .cores;
        last_gate = if (named) .open else policy.gate(cfg, mach, budget, if (valved or o.exclusive and o.load_check) &valve else null, now);
        const check_load = !named and o.load_check and cfg.load_check and (cfg.admit == .cores or o.exclusive);
        if (check_load) st.writeValve(valve);
        if (last_gate == .open and !named and !o.exclusive and cfg.admit == .measured) {
            // Measured admission: count each running job at what it uses (at
            // its expected use while it settles) and start while that leaves
            // room for this one, unless the CPUs are measured all but full.
            if (run_times == null) run_times = RunTimes.load(ctx, ctx.arena);
            const m = measuredLoad(ctx, st, a, &run_times.?, mach.busy, mach.active);
            const target = targetCpus(ctx);
            const room = target - m.charged;
            const req = policy.measuredGrant(o.request, o.cores_given, if (o.hidden) &.{} else jobUses(ctx, run_times.?, work_key, o), room, cores);
            const mine = policy.charge(useOf(run_times.?, o.label), null, 0, 1, req.max);
            // `load_check = off` (or --no-load-check) ignores the machine's load here too.
            const saturated = ctx.cfg.load_check and o.load_check and if (mach.busy) |b| b >= 0.97 else false;
            if (!m.exclusive and !(o.hidden and m.lent) and (m.charged == 0 or (mine <= room and !saturated))) {
                if (state.takeTokens(st, ctx.arena, req, false, poolCap(ctx), poolCap(ctx), false, 0, 0) catch |err| fail("tokens: {t}", .{err})) |grant| {
                    if (o.cores_given == false and grant.files.len != 2) std.debug.print("cpuq: {d} {s} for {s}, from its history\n", .{ grant.files.len, if (grant.files.len == 1) "core" else "cores", if (o.label.len != 0) o.label else "this job" });
                    return admitted(ctx, st, o, &rec, grant, ticket, ticket_name, job, now, false);
                }
            }
        } else if (last_gate == .open) {
            const exclusive_running = (state.scanLeases(st, a, true) catch @as([]state.Entry, &.{})).len != 0;
            // Leave the next waiter's minimum free when this grant can spare it.
            const reserve: u32 = if (queue.len > 1 and !queue[1].record.exclusive) @min(queue[1].record.cores, budget) else 0;
            const held_before = heldCores(st, a);
            // A job paused by hand runs nothing: a quiet window may open beside it.
            const paused_cores: u32 = if (o.exclusive) pausedCores(st, a) else 0;
            var got = state.takeTokens(st, ctx.arena, o.request, o.exclusive, budget, @max(cores, budget), exclusive_running, reserve, paused_cores) catch |err| fail("tokens: {t}", .{err});
            // Not enough free: borrow the cores the holders have left idle for
            // a minute, on top of the budget. Only idle cores are lent, so the
            // work running stays within the budget; should a lender get busy
            // again, the load valve holds further admissions. Measuring takes a
            // process snapshot, so only a head that cannot start does it.
            if (got == null and !named and !o.exclusive and cfg.lend) {
                // Only into CPUs the machine really has to spare: by the load,
                // and by the measured busy share when there is one (the load
                // checks, so not with load_check off or --no-load-check).
                const cpus = sys.activeCpus(ctx.io);
                var room: u32 = std.math.maxInt(u32);
                if (cfg.load_check and o.load_check) {
                    room = policy.lendRoom(mach.load1, cpus);
                    if (mach.busy) |b| room = @min(room, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(cpus)) * (1 - b)))));
                }
                const lent = @min(measureIdle(ctx, st, a), room);
                if (lent > 0) got = state.takeTokens(st, ctx.arena, o.request, o.exclusive, budget + lent, @max(cores, budget) + lent, exclusive_running, reserve, paused_cores) catch |err| fail("tokens: {t}", .{err});
            }
            if (got) |grant| {
                valve.last_admit = now;
                if (check_load) st.writeValve(valve);
                // An exclusive run borrows nothing: the cores it sits beside are
                // a paused job's, set aside, not lent. Counting them made a
                // timing window say it ran on lent cores, and on Linux run it
                // at background priority.
                const borrowed: u32 = if (o.exclusive) 0 else @intCast(@min(grant.files.len, (held_before + grant.files.len) -| budget));
                if (borrowed > 0) std.debug.print("cpuq: starting on {d} {s} lent by jobs that leave them idle, at background priority so the lenders come first\n", .{ borrowed, if (borrowed == 1) "core" else "cores" });
                return admittedLent(ctx, st, o, &rec, grant, ticket, ticket_name, job, now, borrowed);
            }
            // First in line for a fixed count while fewer cores sit free: say
            // once what would start it now.
            if (!named and !hinted_fixed and pos == 0 and o.request.fixed() and o.request.min > 1) {
                var held: u32 = 0;
                for (state.scanLeases(st, a, false) catch &.{}) |l| held += l.record.cores;
                const free = budget -| held;
                if (free > 0 and free < o.request.min) {
                    std.debug.print("cpuq: waiting for {d} cores while {d} {s} free; --cores {d}-{d} would start now (size the job from $CPUQ_CORES)\n", .{ o.request.min, free, if (free == 1) "is" else "are", free, o.request.min });
                    hinted_fixed = true;
                }
            }
        }
        if (out_of_time) giveUp(ctx, st, ticket_name, now - start, job);
        st.unlock();
        io.sleep(.fromMilliseconds(cfg.poll_ms), .awake) catch {};
    }
}

/// The CPUs' worth of use measured admission fills: `target`, else the
/// active CPUs.
pub fn targetCpus(ctx: *Ctx) f64 {
    return ctx.cfg.target orelse @floatFromInt(sys.activeCpus(ctx.io));
}

/// Under measured admission the tokens only number the cores handed out (for
/// CPUQ_CORES, the jobserver and the app's lanes); their pool is just a
/// sanity cap, four times the target.
fn poolCap(ctx: *Ctx) u32 {
    return @intFromFloat(@max(@ceil(targetCpus(ctx) * 4), 4));
}

/// What the running jobs count for under measured admission, and whether an
/// exclusive run holds the machine. Each job is measured (its command tree's
/// CPU, averaged over about half of `settle`), the measurements kept in the
/// state directory so the next head carries on from them. Call with the
/// admission lock held.
fn measuredLoad(ctx: *Ctx, st: *state.State, a: std.mem.Allocator, rt: *const RunTimes, busy: ?f64, cpus: u32) struct { charged: f64, exclusive: bool, lent: bool = false } {
    // Threads ready to run mean a job is short of CPU only when the CPUs are
    // full; with CPUs idle they are waiting on something else (a pool of
    // workers, a burst of short processes), and counting them held the
    // queue: a 6-core job using 5.6 CPUs was charged 12 with 4 CPUs idle,
    // and ten jobs waited 23 minutes behind it.
    const contended = (busy orelse 1) >= 0.9;
    const leases = state.scanLeases(st, a, false) catch return .{ .charged = 0, .exclusive = false };
    // While a quiet window is held nothing is admitted, so nothing is
    // measured: every waiter's scan of the processes would only disturb it.
    // A window lending the machine (`window_lend`) holds nothing back.
    var lend_buf: [128]u8 = undefined;
    const lending = st.lendingWindow(&lend_buf);
    var lent = false;
    for (leases) |l| if (l.record.exclusive) {
        if (lending) |w| if (std.mem.eql(u8, w, l.name)) {
            lent = true;
            continue;
        };
        return .{ .charged = std.math.inf(f64), .exclusive = true };
    };
    const procs = sys.processes(ctx.io, a);
    const old = st.readUsage(a);
    var fresh: std.StringHashMapUnmanaged(policy.Use) = .empty;
    const now_ms: i64 = @intFromFloat(nowFloat(ctx.io) * 1000);
    const now_s = @divFloor(now_ms, 1000);
    var charged: f64 = 0;
    // Settled --opaque jobs, counted together after the rest (policy.hiddenCharge), and what the
    // other jobs are measured to use, which the machine's busy CPUs hold too.
    var hidden_grants: std.ArrayList(u32) = .empty;
    var hidden_seen: std.ArrayList(f64) = .empty;
    var seen_total: f64 = 0;
    for (leases) |l| {
        if (l.record.exclusive or st.isPaused(l.name)) continue;
        // Work cpuq cannot see counts at its whole grant while it settles, or with the CPUs'
        // busy time unmeasured.
        if (l.record.hidden and (busy == null or l.record.child <= 0 or now_s - l.record.since < ctx.cfg.settle_s)) {
            charged += @floatFromInt(l.record.cores);
            continue;
        }
        const expected = useOf(rt.*, l.record.label);
        if (l.record.child <= 0) {
            charged += policy.charge(expected, null, 0, ctx.cfg.settle_s, l.record.cores);
            continue;
        }
        var u = old.get(l.name) orelse policy.Use{};
        const before_ms = u.at_ms;
        u.observe(sys.treeCpu(procs, l.record.child), now_ms, l.record.cores, ctx.cfg.settle_s);
        u.observeRunnable(sys.treeRunning(procs, l.record.child), if (before_ms == 0) 0 else @as(f64, @floatFromInt(now_ms - before_ms)) / 1000, ctx.cfg.settle_s);
        fresh.put(a, l.name, u) catch {};
        if (l.record.hidden) {
            hidden_grants.append(a, l.record.cores) catch {};
            hidden_seen.append(a, if (u.at_ms != 0) u.avg else 0) catch {};
            continue;
        }
        if (u.at_ms != 0) seen_total += u.avg;
        // What it asks of the CPUs: what it gets, or on a contended machine
        // the threads it has ready to run, whichever is more (at most twice
        // what it holds, so a burst of short processes cannot swamp it).
        const asks = if (contended) @max(u.avg, @min(u.runnable, 2 * @as(f64, @floatFromInt(l.record.cores)))) else u.avg;
        const measured: ?f64 = if (u.at_ms != 0) asks else null;
        charged += policy.charge(expected, measured, now_s - l.record.since, ctx.cfg.settle_s, l.record.cores);
    }
    if (hidden_grants.items.len != 0) {
        const unexplained = (busy orelse 1) * @as(f64, @floatFromInt(cpus)) - seen_total;
        charged += policy.hiddenCharge(hidden_grants.items, hidden_seen.items, unexplained);
    }
    st.writeUsage(a, fresh);
    return .{ .charged = charged, .exclusive = false, .lent = lent };
}

/// Cores held by jobs paused by hand.
fn pausedCores(st: *state.State, a: std.mem.Allocator) u32 {
    var n: u32 = 0;
    for (state.scanLeases(st, a, false) catch &.{}) |l| if (st.isPaused(l.name)) {
        n += l.record.cores;
    };
    return n;
}

/// Cores held by every lease now.
fn heldCores(st: *state.State, a: std.mem.Allocator) usize {
    var held: usize = 0;
    for (state.scanLeases(st, a, false) catch &.{}) |l| held += l.record.cores;
    return held;
}

/// Measures each holder's command tree and returns the whole cores they
/// have left idle for a minute (`policy.Use`), keeping the measurements in
/// the state directory so the next head carries on from them. Call with the
/// admission lock held.
fn measureIdle(ctx: *Ctx, st: *state.State, a: std.mem.Allocator) u32 {
    const leases = state.scanLeases(st, a, false) catch return 0;
    const procs = sys.processes(ctx.io, a);
    const old = st.readUsage(a);
    var fresh: std.StringHashMapUnmanaged(policy.Use) = .empty;
    const now_ms: i64 = @intFromFloat(nowFloat(ctx.io) * 1000);
    var lent: u32 = 0;
    for (leases) |l| {
        if (l.record.child <= 0 or l.record.exclusive) continue;
        // Paused by hand: every core it holds is idle now.
        if (st.isPaused(l.name)) {
            lent += l.record.cores;
            continue;
        }
        var u = old.get(l.name) orelse policy.Use{};
        u.observe(sys.treeCpu(procs, l.record.child), now_ms, l.record.cores, ctx.cfg.lend_after_s);
        fresh.put(a, l.name, u) catch {};
        lent += u.lendable(l.record.cores, @divFloor(now_ms, 1000), ctx.cfg.lend_after_s);
    }
    st.writeUsage(a, fresh);
    return lent;
}

/// `admitted`, logging the cores lent to it.
fn admittedLent(ctx: *Ctx, st: *state.State, o: RunOptions, rec: *state.Record, grant: state.Grant, ticket: Io.File, ticket_name: []const u8, job: JobLog, now: i64, lent: u32) Lease {
    runner.lent_now = lent;
    var lease = admitted(ctx, st, o, rec, grant, ticket, ticket_name, job, now, false);
    lease.borrowed = lent;
    return lease;
}

/// Linux, with `affinity`: the CPUs a starting job of `cores` is confined to
/// (`policy.pickCpus`), as a CPU list. Empty, so it may use every CPU, for an exclusive or
/// --opaque run, a lease, and a job of a cpuq itself confined to fewer CPUs than are online
/// (taskset, a cpuset), whose job keeps that. Call with the admission lock held.
fn jobCpus(ctx: *Ctx, st: *state.State, o: RunOptions, cores: u32, now: i64) []const u8 {
    if (builtin.os.tag != .linux or !ctx.cfg.affinity or o.exclusive or o.hidden or o.lease != null) return "";
    const a = ctx.arena;
    const online = sys.onlineCpus(ctx.io, a);
    if (online.len == 0 or sys.activeCpus(ctx.io) < online.len) return "";
    // Each job at what it is measured to use once settled, else at its whole grant.
    const usage = st.readUsage(a);
    var placed: std.ArrayList(policy.Placed) = .empty;
    for (state.scanLeases(st, a, false) catch &.{}) |l| {
        const cpus = policy.cpuList(a, l.record.cpus) catch continue;
        const u = usage.get(l.name) orelse policy.Use{};
        const settled = u.at_ms != 0 and now - l.record.since >= ctx.cfg.settle_s;
        placed.append(a, .{ .cpus = cpus, .use = if (settled) u.avg else @floatFromInt(l.record.cores) }) catch break;
    }
    return policy.cpuListText(a, policy.pickCpus(a, online, placed.items, cores) catch return "");
}

/// Takes the grant: writes the lease, leaves the queue, and logs the start.
/// Call with the admission lock held; returns with it released.
fn admitted(ctx: *Ctx, st: *state.State, o: RunOptions, rec: *state.Record, grant: state.Grant, ticket: Io.File, ticket_name: []const u8, job: JobLog, now: i64, ahead: bool) Lease {
    const io = ctx.io;
    rec.cores = @intCast(grant.files.len);
    rec.slots = grant.slotText(ctx.arena);
    rec.since = now;
    rec.cpus = jobCpus(ctx, st, o, rec.cores, now);
    // The lease is named by the ticket number; should a live job hold that
    // name anyway, take a fresh number rather than wait.
    var lease_name: []const u8 = undefined;
    keepNote(ctx.arena, io, ticket, rec);
    const lease = for (0..3) |_| {
        lease_name = state.leaseName(ctx.arena.alloc(u8, 16) catch fail("out of memory", .{}), rec.ticket, o.exclusive);
        break st.createLease(rec.*, lease_name) catch |err| switch (err) {
            error.WouldBlock => {
                rec.ticket = st.nextTicket() catch |e| fail("ticket: {t}", .{e});
                continue;
            },
            else => fail("lease: {t}", .{err}),
        };
    } else fail("lease: no free lease name", .{});
    st.queue.deleteFile(io, ticket_name) catch {};
    st.dropControl(ticket_name);
    ticket.close(io);
    st.unlock();
    logAndArm(ctx, job, "started", .{ .cores = rec.cores, .slots = grant.slots, .ahead = if (ahead) true else null, .lent = if (runner.lent_now > 0) runner.lent_now else null, .forced = if (runner.forced_now) true else null }, "ended", rec.cores);
    return .{ .record = rec.*, .name = lease_name, .file = lease, .tokens = grant.files, .job = job };
}

/// Backfill: whether this waiter, behind the head, may start now on cores
/// the head cannot use yet (`policy.backfill`), and with how many: what is
/// free, up to its maximum. Its
/// minimum must fit in what is free, and no waiter ahead of it may start
/// first: neither the head, if it fits, nor one between that backfill would
/// also let go ahead. Call with the admission lock held.
fn goAhead(ctx: *Ctx, st: *state.State, a: std.mem.Allocator, o: RunOptions, queue: []const state.Entry, pos: usize, budget: u32, now: i64, rt: *?RunTimes) ?policy.Request {
    const leases = state.scanLeases(st, a, false) catch return null;
    var held: u32 = 0;
    for (leases) |l| {
        if (l.record.exclusive) return null;
        held += l.record.cores;
    }
    const head = queue[0].record;
    // An exclusive head waits for the machine to drain. The free cores may
    // still be used meanwhile, but only by a job whose history says it ends
    // before the running work does: a timing window is never delayed on a
    // guess. (A short check once waited 17 minutes behind one long job while
    // 9 cores sat free and 3 jobs queued behind it.)
    const strict = head.exclusive;
    const free = budget -| held;
    const fits = struct {
        fn need(r: state.Record, b: u32) u32 {
            return if (r.exclusive) b else @min(@max(r.cores, 1), b);
        }
    };
    if (fits.need(head, budget) <= free) return null;
    if (fits.need(.{ .cores = o.request.min }, budget) > free) return null;
    // Kept across passes of the wait, so read into the process's arena, not
    // the pass's scratch.
    if (rt.* == null) rt.* = RunTimes.load(ctx, ctx.arena);
    const times = rt.*.?;
    var ahead = [_]JsonWaiter{.{ .cores = head.cores, .exclusive = head.exclusive, .label = head.label }};
    estimate(times, budget, toHolders(a, leases, &.{}), &ahead, now);
    const head_waited: f64 = @floatFromInt(now - head.since);
    const head_typical = times.typical(head.label);
    const rule = struct {
        fn of(t: RunTimes, label: []const u8, eta: ?f64, waited: f64, typical: ?f64, least: u32, exact: bool) bool {
            if (exact) {
                const run = t.typical(label) orelse return false;
                return run <= (eta orelse return false);
            }
            return policy.backfill(t.typical(label), eta, waited, typical, least);
        }
    };
    for (queue[1..pos]) |e| {
        if (e.record.exclusive or fits.need(e.record, budget) > free) continue;
        if (rule.of(times, e.record.label, ahead[0].eta, head_waited, head_typical, ctx.cfg.patience_s, strict)) return null;
    }
    const min = fits.need(.{ .cores = o.request.min }, budget);
    if (!rule.of(times, o.label, ahead[0].eta, head_waited, head_typical, ctx.cfg.patience_s, strict)) return null;
    return .{ .min = min, .max = @max(min, @min(o.request.max, free)) };
}

/// Leaves the queue and exits 75. Call with the admission lock held.
fn giveUp(ctx: *Ctx, st: *state.State, ticket_name: []const u8, waited: i64, job: JobLog) noreturn {
    st.queue.deleteFile(ctx.io, ticket_name) catch {};
    st.dropControl(ticket_name);
    st.unlock();
    logEvent(ctx, job, "gave_up", .{});
    std.debug.print("cpuq: gave up after waiting {d}s\n", .{waited});
    std.process.exit(exit_timeout);
}

fn watch(io: Io, f: Io.File, sem: *Io.Semaphore) Io.Cancelable!void {
    f.lock(io, .shared) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
    f.unlock(io);
    sem.post(io);
}

/// Blocks until `f`'s exclusive holder lets go, or `ms` pass.
fn waitOn(io: Io, f: Io.File, ms: i64) void {
    var sem: Io.Semaphore = .{};
    // The worker thread this may start never takes cpuq's signals.
    const before = sys.holdHandled();
    const started = io.concurrent(watch, .{ io, f, &sem });
    sys.restoreSignals(before);
    var fut = started catch {
        io.sleep(.fromMilliseconds(@min(ms, 1000)), .awake) catch {};
        return;
    };
    sem.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }) catch {};
    fut.cancel(io) catch {};
}

/// The once-a-minute line a queued run prints, so a long wait never looks
/// like a hang. Call with the admission lock held.
fn note(ctx: *Ctx, st: *state.State, a: std.mem.Allocator, waited: i64, queue: []const state.Entry, pos: usize, g: policy.Gate, lease: ?[]const u8) void {
    var w_buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&w_buf);
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [128]u8 = undefined;
    w.print("cpuq: waiting {s}: {s} in {s}", .{ age(&b1, waited), ordinal(&b2, pos + 1), className(queue[pos].class) }) catch {};
    const leases = state.scanLeases(st, a, false) catch @as([]state.Entry, &.{});
    if (lease) |name| {
        w.print(" for lease {s}", .{name}) catch {};
    } else {
        const m = machine(ctx);
        const budget = budgetNow(ctx, m);
        const held = state.heldTokens(st) catch 0;
        if (pos == 0 and g != .open) w.print(", {s}", .{gateText(&b3, g, budget)}) catch {};
        w.print("; {d}/{d} cores in use", .{ held, budget }) catch {};
    }
    for (leases, 0..) |l, i| {
        w.print("{s} {s} (pid {d}", .{
            if (i == 0) (if (lease != null) ", held by" else " by") else ",",
            if (l.record.label.len != 0) l.record.label else std.mem.sliceTo(l.record.cmd, ' '),
            l.record.pid,
        }) catch break;
        if (lease == null) w.print(", {d}", .{l.record.cores}) catch break;
        w.writeAll(")") catch break;
    }
    std.debug.print("{s}\n", .{w.buffered()});
}

/// Before a job rewrites its own record: the note on file, which `cpuq note` may have set since
/// (the job never changes its own).
pub fn keepNote(a: std.mem.Allocator, io: Io, f: Io.File, r: *state.Record) void {
    if (state.readRecord(io, a, f)) |on_file| r.note = on_file.note;
}

/// Writes a lease's record over the old one, from the start. A record has no
/// size limit (a command can be a long inline script), so it goes through a
/// positional writer rather than a fixed buffer, which once dropped records
/// over 1 KB and left their child pid unknown.
pub fn rewriteRecord(io: Io, f: Io.File, r: state.Record) void {
    f.setLength(io, 0) catch return;
    var buf: [1024]u8 = undefined;
    var fw = f.writer(io, &buf);
    r.write(&fw.interface) catch return;
    fw.interface.flush() catch {};
}

/// Gives a lease back. LOCK_UN releases each lock for every holder of the
/// open file, so a descendant that kept a descriptor (a build server, a
/// nohup'd helper) does not keep the cores. It all happens under the
/// admission lock, so no waiter sees a lease half given back: some of its
/// cores free while the lease still counts them.
pub fn release(io: Io, st: *state.State, lease: Lease) void {
    lockOrFail(st);
    for (lease.tokens) |t| {
        t.unlock(io);
        t.close(io);
    }
    lease.file.unlock(io);
    lease.file.close(io);
    st.leases.deleteFile(io, lease.name) catch {};
    st.setPaused(lease.name, false);
    if (lease.record.exclusive) st.markWindowEnded(nowSeconds(io));
    st.unlock();
}

/// The queue as it is served. The cores' queue takes turns by project (the
/// label before its colon) within each priority class (`fairOrder`). In the
/// `window_gap` after a timing window ends, waiting windows go behind the
/// other waiters, so other work gets a turn before the next window empties
/// the machine again.
pub fn servedOrder(ctx: *Ctx, st: *state.State, a: std.mem.Allocator, queue_in: []state.Entry, now: i64, fair: bool) []state.Entry {
    const queue = if (fair) fairOrder(st, a, queue_in) else queue_in;
    const gap = ctx.cfg.window_gap_s;
    if (gap == 0) return queue;
    const ended = st.windowEnded();
    if (ended == 0 or now - ended >= gap) return queue;
    var out: std.ArrayList(state.Entry) = .empty;
    for (queue) |e| if (!e.record.exclusive) out.append(a, e) catch return queue;
    for (queue) |e| if (e.record.exclusive) out.append(a, e) catch return queue;
    return out.items;
}

/// Takes turns by project within each priority class, so one project's ten
/// waiting jobs don't all go ahead of another project's one: a waiter's turn
/// is its project's jobs running plus those ahead of it in line, lowest
/// first, then by ticket. Jobs moved to the front by hand keep their place.
fn fairOrder(st: *state.State, a: std.mem.Allocator, queue: []state.Entry) []state.Entry {
    if (queue.len < 2) return queue;
    var count: std.StringHashMapUnmanaged(u32) = .empty;
    for (state.scanLeases(st, a, false) catch &.{}) |l| if (!l.record.exclusive) {
        const gop = count.getOrPut(a, std.mem.sliceTo(l.record.label, ':')) catch return queue;
        gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
    };
    const Turn = struct { e: state.Entry, turn: u32 };
    const turns = a.alloc(Turn, queue.len) catch return queue;
    for (queue, turns) |e, *t| {
        const gop = count.getOrPut(a, std.mem.sliceTo(e.record.label, ':')) catch return queue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        t.* = .{ .e = e, .turn = gop.value_ptr.* };
        gop.value_ptr.* += 1;
    }
    std.mem.sort(Turn, turns, {}, struct {
        fn less(_: void, x: Turn, y: Turn) bool {
            if (x.e.record.first != y.e.record.first) return x.e.record.first;
            if (x.e.class != y.e.class) return x.e.class < y.e.class;
            if (x.turn != y.turn) return x.turn < y.turn;
            return x.e.record.ticket < y.e.record.ticket;
        }
    }.less);
    const out = a.alloc(state.Entry, queue.len) catch return queue;
    for (turns, out) |t, *o| o.* = t.e;
    return out;
}
