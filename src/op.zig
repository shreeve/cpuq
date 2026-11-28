//! A run: `cpuq run [-n M] [-c C] [-t T] [-r N] -- CMD`, M tasks of CMD. This process is the
//! run's one loop. Each task holds one of the machine's tokens while it runs, pinned to that
//! token's CPU on Linux; the run takes a freed token whenever it is first in line (pool.zig), up
//! to C at once. It never sleeps while the line would let it take a token.
//!
//!   reap ended tasks -> retry or record them -> under the pool's lock: take the tokens the line
//!   gives (a drain: its whole cores at once, its turn come and their tokens free), wake the runs
//!   that may take one now -> sleep until a task ends, a wake comes, or a look is due
const std = @import("std");
const Io = std.Io;
const builtin = @import("builtin");
const sys = @import("sys.zig");
const policy = @import("policy.zig");
const pool_mod = @import("pool.zig");
const cpus_mod = @import("cpus.zig");
const main = @import("main.zig");
const repos = @import("repos.zig");
const joblog = @import("joblog.zig");

const Pool = pool_mod.Pool;
const Op = pool_mod.Op;
const Ctx = main.Ctx;
const c = std.c;
const is_linux = builtin.os.tag == .linux;

pub const Opts = struct {
    /// -n: how many tasks; 0 means one, with the terminal (`cpuq run -- CMD`).
    tasks: u32 = 0,
    /// -c: the most tokens it holds at once: a count, or a percentage of the tokens; 0: no limit
    /// of its own (as the line allows).
    cpus: u32 = 0,
    cpus_percent: bool = false,
    /// -t: each task's time limit, in seconds of running; null takes the machine's (`timeout`).
    timeout_s: ?u32 = null,
    /// -r: how many times a failed task is tried again.
    retries: u32 = 0,
    urgent: bool = false,
    label: []const u8 = "",
    /// --note, and the repository it runs in: for its history.
    note: []const u8 = "",
    repo: ?[]const u8 = null,
    /// --wait-max: give up (exit 75) when no task started in this many seconds.
    wait_max_s: ?u32 = null,
    /// `cpuq drain`: once its turn comes, isolate `cpus` CPUs (with their SMT siblings) for the
    /// command: those named (`drain_cpus`, --cpus), else from the pool's end or fastest first
    /// (`prefer_fast`, --prefer fast). With `quiet_max` (--quiet-max), the command starts once
    /// work from outside keeps no more than that many CPUs busy on them.
    drain: bool = false,
    drain_cpus: []const u32 = &.{},
    prefer_fast: bool = false,
    quiet_max: ?f64 = null,
    /// Whether it runs inside a task (`nested`), when the caller has looked already.
    nested: ?bool = null,
    cmd: []const [:0]const u8 = &.{},
};

const Task = struct {
    index: u32,
    attempt: u32,
    pid: c.pid_t = 0,
    /// Its process's start time (sys.procStart), so a reused pid is never taken for it.
    pstart: u64 = 0,
    /// When it started (monotonic ms), moved on by every stretch it was stopped: its time limit
    /// counts only time running.
    start_ms: i64 = 0,
    /// When it last started or continued (monotonic ms).
    fresh_ms: i64 = 0,
    /// When cpuq stopped it (monotonic ms): after a Ctrl-Z, until it holds a token again (a
    /// drain's command, until its drain's turn comes again); 0 while it runs. It holds none.
    paused_ms: i64 = 0,
    /// The CPU whose token it holds (pinned there on Linux); a drain's command, its first CPU.
    cpu: u32 = 0,
    /// When TERM was sent for its time limit (0: not yet).
    term_ms: i64 = 0,
    /// When it started, in Unix seconds (for status).
    since_s: i64 = 0,
    timed_out: bool = false,
    out: []const u8 = "",
};

const Outcome = struct { index: u32, attempt: u32, code: u8, timed_out: bool, out: []const u8, stopped: bool = false };

// Signals: the handler only records them and writes a byte to the self-pipe, which the loop
// sleeps on with the wake FIFO.
var self_pipe: [2]c.fd_t = .{ -1, -1 };
var got_signal = std.atomic.Value(u32).init(0);

fn onChild(_: c.SIG) callconv(.c) void {
    _ = c.write(self_pipe[1], "c", 1);
}

fn onStop(sig: c.SIG) callconv(.c) void {
    got_signal.store(@intCast(@backingInt(sig)), .release);
    _ = c.write(self_pipe[1], "s", 1);
}

var got_tstp = std.atomic.Value(bool).init(false);
/// Continues received, and their count when the last stop came: a continue after the stop it
/// answers has moved the count.
var conts = std.atomic.Value(u32).init(0);
var tstp_conts = std.atomic.Value(u32).init(0);

fn onTstp(_: c.SIG) callconv(.c) void {
    tstp_conts.store(conts.load(.acquire), .release);
    got_tstp.store(true, .release);
    _ = c.write(self_pipe[1], "z", 1);
}

/// A continue cancels a stop not yet acted on: the shell (or whoever sent both) now counts the
/// run as running, so stopping after it would leave the run stopped for good. A stop already
/// being acted on sees the count move and doesn't stop cpuq (`suspend_`).
fn onCont(_: c.SIG) callconv(.c) void {
    _ = conts.fetchAdd(1, .acq_rel);
    got_tstp.store(false, .release);
    _ = c.write(self_pipe[1], "g", 1);
}

fn installStop() void {
    var sa: c.Sigaction = .{ .handler = .{ .handler = onTstp }, .mask = undefined, .flags = c.SA.RESTART };
    _ = c.sigemptyset(&sa.mask);
    var old: c.Sigaction = undefined;
    if (c.sigaction(.TSTP, null, &old) == 0 and old.handler.handler == c.SIG.IGN) return;
    _ = c.sigaction(.TSTP, &sa, null);
    var sc: c.Sigaction = .{ .handler = .{ .handler = onCont }, .mask = undefined, .flags = c.SA.RESTART };
    _ = c.sigemptyset(&sc.mask);
    _ = c.sigaction(.CONT, &sc, null);
}

fn installHandlers(forward_terminal: bool) void {
    if (c.pipe(&self_pipe) != 0) main.fail("pipe failed", .{});
    for (self_pipe) |fd| {
        _ = c.fcntl(fd, c.F.SETFL, @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    }
    var sa: c.Sigaction = .{ .handler = .{ .handler = onChild }, .mask = undefined, .flags = c.SA.RESTART | c.SA.NOCLDSTOP };
    _ = c.sigemptyset(&sa.mask);
    _ = c.sigaction(.CHLD, &sa, null);
    installStop();
    if (forward_terminal) {
        var st: c.Sigaction = .{ .handler = .{ .handler = onStop }, .mask = undefined, .flags = c.SA.RESTART };
        _ = c.sigemptyset(&st.mask);
        for ([_]c.SIG{ .INT, .TERM, .HUP, .QUIT }) |sig| {
            var old: c.Sigaction = undefined;
            if (c.sigaction(sig, null, &old) == 0 and old.handler.handler == c.SIG.IGN) continue;
            _ = c.sigaction(sig, &st, null);
        }
    }
}

const Run = struct {
    ctx: *Ctx,
    a: std.mem.Allocator,
    o: Opts,
    pool: Pool,
    pool_cpus: []const u32,
    /// The machine's CPUs online, whatever this process's CPU set.
    ncpu: u32,
    rec: Op,
    file: Io.File = undefined,
    wake_fd: c.fd_t = -1,
    running: std.ArrayList(Task) = .empty,
    retry: std.ArrayList(Task) = .empty,
    /// The record's list of running tasks, rebuilt at each write.
    now_buf: std.ArrayList(pool_mod.TaskNow) = .empty,
    next_index: u32 = 1,
    total: u32,
    single: bool,
    limit: u32,
    timeout_ms: i64,
    outcomes: std.ArrayList(Outcome) = .empty,
    out_dir: []const u8 = "",
    stopping_since: i64 = 0,
    stop_signal: u32 = 0,
    exe: [:0]const u8,
    gave_up: bool = false,
    started_ms: i64,
    first_start_ms: i64 = 0,
    /// When its first task started, by the real clock (Unix seconds), as history records it.
    first_start_t: f64 = 0,
    last_wait: ?sys.Waited = null,
    /// Stopped by Ctrl-Z: it starts nothing, and its tasks are stopped, until continued.
    stopped: bool = false,
    /// A task ended, a signal or a wake came: look at the pool now.
    event: bool = true,
    /// Something here freed room for others (a task ended, tasks stopped): wake them.
    freed: bool = false,
    /// When the next look is due (monotonic ms).
    next_look: i64 = 0,
    /// The machine's tokens as last seen: the pool's first CPUs less the reserve, which the config
    /// may change while it runs.
    toks: []const u32 = &.{},
    /// Tasks ended when it last wrote its progress.
    last_progress: u32 = std.math.maxInt(u32),
    /// Its history: the record, when it entered the line, and the most tasks run at once.
    job: joblog.JobLog = undefined,
    queued_t: f64 = 0,
    peak_running: u32 = 0,
    /// A drain: when it first isolated its CPUs (real clock, Unix seconds), and the most CPUs it
    /// isolated. History counts its task-hours as those CPUs over the time it held them.
    iso_t: f64 = 0,
    iso_n: u32 = 0,
    /// A drain's watch on its command's CPU: the last sample (monotonic ms, task-tree CPU ns),
    /// since when it has kept under `drain_idle_busy` while others wait, and whether it was
    /// warned or stopped for it.
    idle_at_ms: i64 = 0,
    idle_cpu_ns: u64 = 0,
    idle_since_ms: i64 = 0,
    idle_warned: bool = false,
    idle_stopped: bool = false,
    /// Ended at config `drain_timeout` because others waited (its own -t was longer).
    long_stopped: bool = false,
    long_at_ms: i64 = 0,
    /// Why it waits, as the record says it: kept here, so it outlives each look.
    why_buf: [256]u8 = undefined,
    /// A drain: the pool's cores (its CPUs' SMT siblings).
    topo: []const cpus_mod.Core = &.{},
    /// A drain's watch on work from outside it on its CPUs (Linux): the last per-CPU ticks and
    /// own CPU time, the last process listing (for the busiest outsider), and the totals while
    /// its command ran (busy CPUs summed over the looks, the looks, the most, and the busiest
    /// outsider when it was most).
    noise_at_ms: i64 = 0,
    noise_ticks: std.ArrayList(sys.NumberedTicks) = .empty,
    noise_own_ns: u64 = 0,
    noise_procs: std.AutoHashMapUnmanaged(i32, u64) = .empty,
    noise_sum: f64 = 0,
    noise_n: u32 = 0,
    noise_max: f64 = 0,
    noise_top: []const u8 = "",
    top_buf: [160]u8 = undefined,
    max_top_buf: [160]u8 = undefined,
    /// A drain that never found its CPUs quiet enough (--quiet-max) in time, and whether a look
    /// has measured them (not only taken a first reading) since its isolation began.
    never_quiet: bool = false,
    noise_measured: bool = false,

    fn setWhy(r: *Run, text: []const u8) void {
        const n = @min(text.len, r.why_buf.len);
        @memcpy(r.why_buf[0..n], text[0..n]);
        r.rec.why = r.why_buf[0..n];
    }

    fn pending(r: *const Run) u32 {
        if (r.stopping_since != 0) return 0;
        return @as(u32, @intCast(r.retry.items.len)) + (r.total + 1 - r.next_index);
    }

    /// Tasks it could start or continue now, each taking a token: none while stopped; a drain,
    /// its one command until its turn comes.
    fn waitingNow(r: *const Run) u32 {
        if (r.stopped) return 0;
        if (r.rec.drain) return if (r.rec.dstart == 0 and (r.pending() > 0 or r.running.items.len > 0)) 1 else 0;
        return @min(r.pending() + r.pausedCount(), r.limit -| r.holding());
    }

    /// Its tasks holding a token: those running, not stopped by cpuq.
    fn holding(r: *const Run) u32 {
        return @as(u32, @intCast(r.running.items.len)) - r.pausedCount();
    }

    fn pausedCount(r: *const Run) u32 {
        var n: u32 = 0;
        for (r.running.items) |t| n += @intFromBool(t.paused_ms != 0);
        return n;
    }

    /// Brings the record up to date (in memory).
    fn refresh(r: *Run) void {
        r.rec.running = if (r.rec.drain) @intCast(r.running.items.len) else r.holding();
        r.rec.waiting = r.waitingNow();
        r.rec.stopped = r.stopped;
        r.rec.limit = r.limit;
        if (r.running.items.len != 0) r.rec.served = true;
        r.peak_running = @max(r.peak_running, r.rec.running);
        r.now_buf.clearRetainingCapacity();
        for (r.running.items) |t| r.now_buf.append(r.a, .{
            .task = t.index,
            .attempt = t.attempt,
            .pid = t.pid,
            .start = t.pstart,
            .since = t.since_s,
            .fresh = t.fresh_ms,
            .paused = t.paused_ms != 0,
            .cpu = t.cpu,
        }) catch break;
        r.rec.tasks_now = r.now_buf.items;
    }

    /// Writes the record. Under the lock.
    fn syncRecord(r: *Run) void {
        r.refresh();
        r.pool.write(r.file, r.rec) catch {};
        // A run of many reports its own progress where its caller asked (CPUQ_PROGRESS):
        // `DONE TOTAL FAILING`, whole, by a rename.
        if (!r.single) if (r.ctx.env.get("CPUQ_PROGRESS")) |path| writeProgress(r, path);
    }
};

fn writeProgress(r: *Run, path: []const u8) void {
    const ended = r.rec.done + r.rec.failed;
    if (ended == r.last_progress) return;
    r.last_progress = ended;
    var buf: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d} {d} {d}\n", .{ ended, r.total, r.rec.failed }) catch return;
    const tmp = std.fmt.allocPrint(r.a, "{s}.tmp", .{path}) catch return;
    Io.Dir.cwd().writeFile(r.ctx.io, .{ .sub_path = tmp, .data = text }) catch return;
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), path, r.ctx.io) catch {};
}

/// The pool's CPUs, as this machine's config sets them.
pub fn poolCpus(ctx: *Ctx) []const u32 {
    return cpus_mod.list(ctx.io, ctx.arena, if (ctx.cfg.cpus.len != 0) ctx.cfg.cpus else null);
}

/// The machine's CPUs online, whatever this process's CPU set.
pub fn onlineCpus(io: Io) u32 {
    return if (is_linux) onlineCount(io) orelse sys.activeCpus(io) else sys.activeCpus(io);
}

/// Runs a run and returns its exit status (or dies by its command's signal).
pub fn run(ctx: *Ctx, o: Opts) u8 {
    const a = ctx.arena;
    const exe = @import("runopts.zig").findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return main.exit_notfound;
    };
    // Inside a task already: run within it, with no line to wait in.
    if (!o.drain and (o.nested orelse nested(ctx))) return runNested(ctx, o, exe);

    const dir = main.stateDir(ctx);
    const pool = Pool.open(ctx.io, a, dir) catch |err| main.fail("pool {s}/v3: {t}", .{ dir, err });
    const pool_cpus = poolCpus(ctx);
    const toks = pool_mod.tokens(pool_cpus, ctx.cfg.reserve);
    const ntok: u32 = @intCast(toks.len);
    const single = o.tasks == 0;
    const total: u32 = if (single) 1 else o.tasks;
    const asked: u32 = if (o.cpus == 0) total else if (o.cpus_percent) @max(1, @as(u32, @intCast((@as(u64, ntok) * o.cpus) / 100))) else o.cpus;
    const limit: u32 = if (o.drain)
        (if (o.drain_cpus.len != 0) @as(u32, @intCast(o.drain_cpus.len)) else @max(1, @min(o.cpus, ntok)))
    else
        @max(1, @min(asked, total));
    const timeout_s = o.timeout_s orelse ctx.cfg.timeout_s;
    const timeout_ms: i64 = if (timeout_s == 0) std.math.maxInt(i64) / 2 else @as(i64, timeout_s) * 1000;

    var r: Run = .{
        .ctx = ctx,
        .a = a,
        .o = o,
        .pool = pool,
        .pool_cpus = pool_cpus,
        .toks = toks,
        .ncpu = onlineCpus(ctx.io),
        .total = total,
        .single = single,
        .limit = limit,
        .timeout_ms = timeout_ms,
        .exe = exe,
        .started_ms = sys.monoMs(),
        .rec = .{
            .urgent = o.urgent,
            .drain = o.drain,
            .single = single,
            .pid = sys.getpid(),
            .project = projectOf(ctx, o),
            .label = if (o.label.len != 0) o.label else std.fs.path.basename(o.cmd[0]),
            .weight = weightOf(ctx, projectOf(ctx, o)),
            .limit = limit,
            .tasks = total,
            .since = main.nowSeconds(ctx.io),
            .arrived = sys.monoMs(),
            // A task's limit, the 5 s a kill may take after it, and a few for ending and starting.
            .tlimit = if (timeout_s == 0) 0 else timeout_s +| 10,
            .cmd = @import("runopts.zig").joinCommand(ctx, o.cmd),
        },
    };
    if (!single) r.out_dir = outDir(ctx, r.rec.project) catch |err| main.fail("output folder: {t}", .{err});
    if (o.drain) r.topo = cpus_mod.cores(ctx.io, a, pool_cpus);

    installHandlers(!single);
    if (single) sys.installForwarding();

    r.pool.lock();
    r.refresh();
    r.file = r.pool.enter(&r.rec) catch |err| main.fail("pool {s}: {t}", .{ r.pool.path, err });
    r.wake_fd = r.pool.openWake(r.rec.ticket) catch |err| main.fail("pool {s}: {t}", .{ r.pool.path, err });
    r.pool.unlock();
    const repo = o.repo orelse repos.repoAt(ctx, std.process.currentPathAlloc(ctx.io, a) catch "");
    r.job = joblog.newJobLog(ctx, .{ .pool = "cpus", .repo = repo, .project = r.rec.project, .label = r.rec.label, .note = o.note, .cmd = r.rec.cmd, .tasks = if (single) null else total });
    r.queued_t = joblog.nowFloat(ctx.io);
    joblog.logEvent(ctx, r.job, "queued", .{ .t = r.queued_t });

    if (!single) std.debug.print("cpuq: {d} tasks, up to {d} at once, timeout {d}s{s}\n", .{
        total, limit, timeout_s, if (o.retries > 0) retryNote(a, o.retries) else "",
    });

    loop(&r);

    // Gone from the line: whoever may start now is woken.
    r.pool.lock();
    r.running.clearRetainingCapacity();
    r.pool.leave(r.file, r.rec);
    {
        var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer arena.deinit();
        const ops = r.pool.scan(arena.allocator());
        wakeReady(&r, arena.allocator(), ops, r.pool.readSample(arena.allocator()));
    }
    r.pool.unlock();

    logEnd(&r);
    return finish(&r);
}

/// Its last lines in history: when its first task started, then how it ended (or that it gave
/// up waiting), with the CPU its tasks used (every child reaped: wait4's figures, summed).
fn logEnd(r: *Run) void {
    const ctx = r.ctx;
    if (r.gave_up) return joblog.logEvent(ctx, r.job, "gave_up", .{});
    // A drain holds its CPUs from its isolation, its command's quiet wait included: it starts
    // then, and counts as the CPUs it isolated.
    const held = r.rec.drain and r.iso_t != 0;
    if (held) {
        joblog.logEvent(ctx, r.job, "started", .{ .t = r.iso_t, .cores = r.iso_n });
    } else if (r.first_start_ms != 0) joblog.logEvent(ctx, r.job, "started", .{ .t = r.first_start_t });
    var extra: joblog.EventExtra = .{ .cores = if (held) r.iso_n else r.peak_running, .cpu = sys.childrenCpu(), .done = r.rec.done, .failed = r.rec.failed };
    if (r.noise_max >= noisy_min) extra.noisy = .{ .cpus = r.noise_sum / @as(f64, @floatFromInt(@max(r.noise_n, 1))), .max = r.noise_max, .top = r.noise_top };
    if (r.single) {
        const last: ?Outcome = if (r.outcomes.items.len != 0) r.outcomes.items[r.outcomes.items.len - 1] else null;
        if (last == null) {
            extra.exit = 125;
        } else if (last.?.timed_out) {
            extra.exit = 124;
            extra.stopped = if (r.long_stopped) "drain_timeout, others waiting" else if (r.idle_stopped) "idle" else "time limit";
        } else if (r.last_wait) |w| switch (w.exit) {
            .code => |code| extra.exit = code,
            .signal => |sig| extra.signal = @intCast(@backingInt(sig)),
        } else extra.exit = last.?.code;
    } else if (r.stop_signal != 0) {
        extra.signal = r.stop_signal;
    } else {
        extra.exit = if (r.rec.failed != 0 or r.rec.done < r.total) 1 else 0;
    }
    joblog.logEvent(ctx, r.job, "ended", extra);
}

fn retryNote(a: std.mem.Allocator, n: u32) []const u8 {
    return std.fmt.allocPrint(a, ", up to {d} retr{s}", .{ n, if (n == 1) "y" else "ies" }) catch "";
}

fn loop(r: *Run) void {
    const wait_deadline: ?i64 = if (r.o.wait_max_s) |s| r.started_ms + @as(i64, s) * 1000 else null;
    while (true) {
        reap(r);
        signals(r);
        timeouts(r);
        if (r.rec.drain) {
            idleDrain(r);
            noiseDrain(r);
        } else if (r.pool.takeLimit(r.rec.pid)) |n| setLimit(r, n);
        if (r.running.items.len == 0 and (r.pending() == 0 or r.stopping_since != 0)) break;
        if (got_tstp.swap(false, .acq_rel)) suspend_(r);
        // A single run's signal while it waits ends it: nothing runs.
        if (r.single and r.running.items.len == 0) {
            const sig = sys.takePending();
            if (sig != 0) {
                r.stop_signal = sig;
                break;
            }
        }
        const now = sys.monoMs();
        if (r.event or now >= r.next_look) {
            r.event = false;
            look(r);
        }
        if (wait_deadline) |d| if (r.first_start_ms == 0 and r.running.items.len == 0 and sys.monoMs() >= d) {
            r.gave_up = true;
            r.never_quiet = r.rec.dstart != 0;
            break;
        };
        // A drain waiting for quiet CPUs waits no longer than its time limit, which counts from
        // its isolation.
        if (r.rec.drain and r.rec.dstart != 0 and r.first_start_ms == 0 and sys.monoMs() - r.rec.dstart >= r.timeout_ms) {
            r.gave_up = true;
            r.never_quiet = true;
            break;
        }
        sleep(r);
    }
}

fn sleep(r: *Run) void {
    const now = sys.monoMs();
    var timeout: i64 = @max(0, @min(r.next_look - now, 10_000));
    for (r.running.items) |t| {
        if (t.paused_ms != 0) continue;
        const due = if (t.term_ms != 0) t.term_ms + 5000 else t.start_ms + r.timeout_ms;
        timeout = @min(timeout, @max(0, due - now));
    }
    if (r.stopping_since != 0) timeout = @min(timeout, @max(0, r.stopping_since + 5000 - now));
    var fds = [_]c.pollfd{
        .{ .fd = self_pipe[0], .events = c.POLL.IN, .revents = 0 },
        .{ .fd = r.wake_fd, .events = c.POLL.IN, .revents = 0 },
    };
    _ = c.poll(&fds, fds.len, @intCast(timeout));
    var buf: [64]u8 = undefined;
    for (fds) |f| if (f.revents != 0) {
        r.event = true;
        while (c.read(f.fd, &buf, buf.len) > 0) {}
    };
}

fn signals(r: *Run) void {
    const sig = got_signal.swap(0, .acq_rel);
    if (sig == 0) return;
    if (r.stopping_since == 0) r.stopping_since = sys.monoMs();
    r.stop_signal = sig;
    // Each task leads a group of its own: pass the signal to the whole group, and continue a
    // stopped one so it can act on it.
    for (r.running.items) |*t| {
        _ = c.kill(-t.pid, @fromBackingInt(@intCast(sig)));
        if (t.paused_ms != 0) {
            signalTree(r, t.*, .CONT);
            t.paused_ms = 0;
        }
    }
}

fn timeouts(r: *Run) void {
    const now = sys.monoMs();
    for (r.running.items) |*t| {
        if (t.paused_ms != 0) continue;
        if (t.term_ms == 0 and now - t.start_ms >= r.timeout_ms) {
            t.term_ms = now;
            t.timed_out = true;
            signalTask(r, t.*, .TERM);
        } else if (t.term_ms != 0 and now - t.term_ms >= 5000) {
            signalTask(r, t.*, .KILL);
        }
    }
    if (r.stopping_since != 0 and now - r.stopping_since >= 5000) {
        for (r.running.items) |t| signalTask(r, t, .KILL);
    }
}

/// A drain takes CPUs from everyone else, so it must use them: every few seconds it samples its
/// task tree's CPU time. Kept under `drain_idle_busy` CPUs for `drain_idle` while another run
/// waits, it is warned halfway, then stopped as at its time limit.
fn idleDrain(r: *Run) void {
    longDrain(r);
    const window: i64 = @as(i64, r.ctx.cfg.drain_idle_s) * 1000;
    if (window == 0 or r.running.items.len == 0 or r.idle_stopped or r.rec.dstart == 0) return;
    const now = sys.monoMs();
    const every = @min(@as(i64, 30_000), @max(@divTrunc(window, 4), 500));
    if (r.idle_at_ms != 0 and now - r.idle_at_ms < every) return;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const me = sys.getpid();
    const procs = sys.processes(r.ctx.io, a);
    var own: u64 = 0;
    for (procs) |p| if (p.pid == me) {
        own = p.own_ns;
    };
    const cpu = sys.treeCpu(procs, me) -| own;
    const prev_at = r.idle_at_ms;
    const prev_cpu = r.idle_cpu_ns;
    r.idle_at_ms = now;
    r.idle_cpu_ns = cpu;
    if (prev_at == 0) return;
    const busy = @as(f64, @floatFromInt(cpu -| prev_cpu)) / 1e6 / @as(f64, @floatFromInt(@max(now - prev_at, 1)));
    r.pool.lock();
    const ops = r.pool.scan(a);
    r.pool.unlock();
    var others = false;
    for (ops) |o| if (o.ticket != r.rec.ticket and o.waiting > 0) {
        others = true;
    };
    if (busy >= drain_idle_busy or !others) {
        r.idle_since_ms = 0;
        r.idle_warned = false;
        return;
    }
    if (r.idle_since_ms == 0) r.idle_since_ms = prev_at;
    const idle = now - r.idle_since_ms;
    if (!r.idle_warned and idle * 2 >= window) {
        r.idle_warned = true;
        std.debug.print("cpuq: this drain's command has kept under {d:.2} CPUs busy for {d}s while others wait; it is stopped at {d}s\n", .{ drain_idle_busy, @divTrunc(idle, 1000), @divTrunc(window, 1000) });
    }
    if (idle < window) return;
    r.idle_stopped = true;
    for (r.running.items) |*t| if (t.term_ms == 0) {
        t.term_ms = now;
        t.timed_out = true;
        signalTask(r, t.*, .TERM);
    };
}

/// `cpuq limit`: hold at most `n` tokens at once from now on. Raised, it starts more as the line
/// allows; lowered, it starts none until fewer than `n` run. Nothing is killed.
fn setLimit(r: *Run, n_in: u32) void {
    const n = @max(1, n_in);
    if (!r.single) std.debug.print("cpuq: now up to {d} at once (was {d}), by cpuq limit\n", .{ n, r.limit });
    r.limit = n;
    r.event = true;
}

/// A drain holds its cores at most config `drain_timeout` while anyone waits, whatever its own
/// -t: a longer -t runs on only on an otherwise idle machine. Looked at every 2 s.
fn longDrain(r: *Run) void {
    if (r.running.items.len == 0 or r.idle_stopped or r.rec.dstart == 0) return;
    const now = sys.monoMs();
    if (now - r.rec.dstart < @as(i64, r.ctx.cfg.drain_timeout_s) * 1000) return;
    if (r.long_at_ms != 0 and now - r.long_at_ms < 2000) return;
    r.long_at_ms = now;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    r.pool.lock();
    const ops = r.pool.scan(arena.allocator());
    r.pool.unlock();
    var others = false;
    for (ops) |o| {
        if (o.ticket != r.rec.ticket and o.waiting > 0) others = true;
    }
    if (!others) return;
    r.long_stopped = true;
    r.idle_stopped = true;
    std.debug.print("cpuq: drain stopped: it held its CPUs past drain_timeout ({d}s) while others waited\n", .{r.ctx.cfg.drain_timeout_s});
    for (r.running.items) |*t| if (t.term_ms == 0) {
        t.term_ms = now;
        t.timed_out = true;
        signalTask(r, t.*, .TERM);
    };
}

fn signalTask(r: *Run, t: Task, sig: c.SIG) void {
    // A single task shares cpuq's group (the terminal's); a task of many leads its own.
    _ = c.kill(if (r.single) t.pid else -t.pid, sig);
}

/// Stops or continues a task with everything it started: a task of many by its process group;
/// a single task (which shares cpuq's group, and the terminal's) by its process tree.
fn signalTree(r: *Run, t: Task, sig: c.SIG) void {
    if (!r.single) {
        _ = c.kill(-t.pid, sig);
        return;
    }
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const procs = sys.processes(r.ctx.io, a);
    const in_tree = a.alloc(bool, procs.len) catch return;
    @memset(in_tree, false);
    sys.markTree(procs, t.pid, in_tree);
    _ = c.kill(t.pid, sig);
    for (procs, in_tree) |p, yes| if (yes and p.pid != t.pid) {
        _ = c.kill(p.pid, sig);
    };
}

fn resumeTask(r: *Run, t: *Task, now: i64) void {
    if (t.paused_ms == 0) return;
    // The time stopped doesn't count against its time limit.
    t.start_ms += now - t.paused_ms;
    t.paused_ms = 0;
    t.fresh_ms = now;
    signalTree(r, t.*, .CONT);
}

fn reap(r: *Run) void {
    while (sys.reapAny()) |ended| {
        const pid, const w = ended;
        const i = for (r.running.items, 0..) |t, i| {
            if (t.pid == pid) break i;
        } else continue;
        const t = r.running.swapRemove(i);
        r.freed = true;
        r.event = true;
        if (!r.single) _ = c.kill(-t.pid, .KILL); // what the task left behind in its group
        const code: u8 = switch (w.exit) {
            .code => |n| n,
            .signal => |sig| 128 +| @as(u8, @intCast(@backingInt(sig))),
        };
        const failed = code != 0 or t.timed_out;
        const cut_off = r.stopping_since != 0 and !t.timed_out;
        if (failed and !cut_off and t.attempt <= r.o.retries and !r.rec.drain) {
            r.retry.append(r.a, .{ .index = t.index, .attempt = t.attempt + 1 }) catch {};
        } else {
            const stopped = failed and cut_off;
            r.outcomes.append(r.a, .{ .index = t.index, .attempt = t.attempt, .code = if (t.timed_out) 124 else code, .timed_out = t.timed_out, .out = t.out, .stopped = stopped }) catch {};
            if (stopped) {} else if (failed) r.rec.failed += 1 else r.rec.done += 1;
            if (r.single) r.last_wait = w;
        }
    }
}

/// CPUs as a comma-separated list, for `CPUQ_CPUS` (what taskset -c takes).
fn cpuListText(a: std.mem.Allocator, cpus: []const u32) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cpus, 0..) |cpu, i| out.print(a, "{s}{d}", .{ if (i == 0) "" else ",", cpu }) catch {};
    return out.items;
}

/// Starts the next task (a retry goes behind the tasks not yet started), holding the token of
/// `cpu` (pinned there on Linux). A drain's command runs on its CPUs (pinned on Linux), with
/// CPUQ_CPUS naming them.
fn startTask(r: *Run, a: std.mem.Allocator, cpu: u32) void {
    const t_in: Task = if (r.next_index <= r.total) blk: {
        defer r.next_index += 1;
        break :blk .{ .index = r.next_index, .attempt = 1 };
    } else r.retry.orderedRemove(0);
    var t = t_in;
    const ctx = r.ctx;
    var num: [2][16]u8 = undefined;
    ctx.env.put("CPUQ_TASK", std.fmt.bufPrint(&num[0], "{d}", .{t.index}) catch "1") catch {};
    ctx.env.put("CPUQ_TASKS", std.fmt.bufPrint(&num[1], "{d}", .{r.total}) catch "1") catch {};
    var att: [2][16]u8 = undefined;
    ctx.env.put("CPUQ_ATTEMPT", std.fmt.bufPrint(&att[0], "{d}", .{t.attempt}) catch "1") catch {};
    ctx.env.put("CPUQ_ATTEMPTS", std.fmt.bufPrint(&att[1], "{d}", .{r.o.retries + 1}) catch "1") catch {};
    var opn: [24]u8 = undefined;
    ctx.env.put("CPUQ_OP", std.fmt.bufPrint(&opn, "{d}", .{r.rec.ticket}) catch "") catch {};
    if (r.rec.drain) ctx.env.put("CPUQ_CPUS", cpuListText(a, r.rec.pin)) catch {};
    const envp = ctx.env.createPosixBlock(a, .{}) catch main.fail("out of memory", .{});
    const argv = a.allocSentinel(?[*:0]const u8, r.o.cmd.len, null) catch main.fail("out of memory", .{});
    for (r.o.cmd, 0..) |arg, k| argv[k] = arg.ptr;

    var dups: std.ArrayList([2]c.fd_t) = .empty;
    if (!r.single) {
        t.out = if (t.attempt == 1)
            std.fmt.allocPrint(r.a, "{s}/{d}", .{ r.out_dir, t.index }) catch ""
        else
            std.fmt.allocPrint(r.a, "{s}/{d}.{d}", .{ r.out_dir, t.index, t.attempt }) catch "";
        const path = a.dupeSentinel(u8, t.out, 0) catch "";
        const out_fd = c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
        const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (null_fd >= 0) dups.append(a, .{ null_fd, 0 }) catch {};
        if (out_fd >= 0) {
            dups.append(a, .{ out_fd, 1 }) catch {};
            dups.append(a, .{ out_fd, 2 }) catch {};
        }
    }
    const one = [_]u32{cpu};
    const pin: []const u32 = if (!is_linux) &.{} else if (r.rec.drain) r.rec.pin else &one;
    const spawned = sys.spawn(r.exe, argv.ptr, @ptrCast(envp.slice.ptr), .unchanged, .{
        .cpus = pin,
        .dups = dups.items,
        .group = !r.single,
        .pdeath = true,
    });
    for (dups.items) |d| if (d[1] == 0 or d[1] == 1) {
        _ = c.close(d[0]);
    };
    const pid = spawned catch |err| {
        std.debug.print("cpuq: {s}: {t}\n", .{ r.o.cmd[0], err });
        r.outcomes.append(r.a, .{ .index = t.index, .attempt = t.attempt, .code = if (err == error.FileNotFound) main.exit_notfound else main.exit_noexec, .timed_out = false, .out = t.out }) catch {};
        r.rec.failed += 1;
        return;
    };
    if (r.single) sys.setChild(pid);
    const now = sys.monoMs();
    t.pid = pid;
    t.cpu = cpu;
    t.pstart = sys.procStart(pid) orelse 0;
    t.start_ms = now;
    t.fresh_ms = now;
    t.since_s = main.nowSeconds(ctx.io);
    if (r.first_start_ms == 0) {
        r.first_start_ms = now;
        r.first_start_t = joblog.nowFloat(ctx.io);
    }
    r.rec.last = now;
    r.running.append(r.a, t) catch {};
}

/// Ctrl-Z: stops every task and gives back its tokens (they count against its project's share
/// no more), then stops cpuq itself (unless a continue has come meanwhile). Continued, each task
/// continues once it holds a token again, as the line allows (a shell continues the whole group:
/// they are stopped again till then); a drain takes its turn again before its command continues.
fn suspend_(r: *Run) void {
    const at = sys.monoMs();
    for (r.running.items) |*t| if (t.paused_ms == 0) {
        signalTree(r, t.*, .STOP);
        t.paused_ms = at;
    };
    r.stopped = true;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    r.pool.lock();
    r.syncRecord();
    const ops = r.pool.scan(arena.allocator());
    wakeReady(r, arena.allocator(), ops, r.pool.readSample(arena.allocator()));
    r.pool.unlock();
    // SIGSTOP, not TSTP: a TSTP to a process outside job control (an agent's shell) is dropped.
    // Not once a continue has come since the stop: nothing would continue cpuq after it. Only a
    // continue between this check and the raise is still lost.
    if (conts.load(.acquire) == tstp_conts.load(.acquire)) _ = c.raise(.STOP);
    // Continued: its isolation, if a drain, went with the stop; its tasks wait for tokens.
    r.stopped = false;
    if (r.rec.drain) r.rec.dstart = 0;
    for (r.running.items) |t| signalTree(r, t, .STOP);
    r.event = true;
}

/// One look at the pool: start (or continue) what the line allows, a drain's turn, and wake the
/// runs that may start now.
fn look(r: *Run) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A change to the config (the reserve, drain_max) is in force at once.
    main.reloadConfig(r.ctx);
    r.toks = pool_mod.tokens(r.pool_cpus, r.ctx.cfg.reserve);
    // The sample (for the outside-load gate) is renewed outside the pool's lock, by one cpuq at a
    // time.
    if (r.waitingNow() > 0 and r.ctx.cfg.outside_check) {
        const s = r.pool.readSample(a);
        if (s == null or sys.monoMs() - s.?.ms >= 1000) {
            r.pool.lock();
            r.syncRecord();
            const ops = r.pool.scan(a);
            r.pool.unlock();
            r.pool.renewSample(a, ops, r.ncpu);
        }
    }
    const why = gate(r, a);
    r.pool.lock();
    r.syncRecord();
    const ops = r.pool.scan(a);
    const me = for (ops, 0..) |o, i| {
        if (o.ticket == r.rec.ticket) break i;
    } else {
        // Its record is gone (someone removed the folder): enter again.
        r.pool.unlock();
        return;
    };
    const now = sys.monoMs();
    const sample = r.pool.readSample(a);
    const cx = context(r, a, ops, sample, now);
    var began = false;
    var head = false;
    var blocked = false;
    var started = false;
    if (r.rec.drain) {
        began = drainStep(r, a, ops, why, cx);
    } else if (!r.stopped) {
        r.refresh();
        ops[me] = r.rec;
        // Start (or continue) what the line allows, each on a free token's CPU.
        r.setWhy("");
        if (why.len != 0) {
            r.setWhy(why);
            blocked = r.waitingNow() > 0;
        } else while (r.waitingNow() > 0) {
            const w = pool_mod.mayStart(a, ops, r.rec.ticket, cx);
            if (w != .go) {
                r.setWhy(whyText(w, cx));
                // Held back for outside work, which changes without a word: look each second.
                blocked = w == .full and cx.held_back != 0;
                break;
            }
            const cpu = pool_mod.freeCpu(a, r.toks, ops, now) orelse break;
            takeToken(r, a, cpu, now);
            started = true;
            r.refresh();
            ops[me] = r.rec;
        }
        if (r.waitingNow() > 0) {
            head = pool_mod.lineFirst(a, ops, cx.n) == r.rec.ticket;
        } else if (r.pending() > 0 and r.holding() >= r.limit) {
            r.setWhy(a.print("at its -c ({d})", .{r.limit}) catch "at its -c");
        }
    }
    r.refresh();
    ops[me] = r.rec;
    // A token freed here, a drain began, or a start here passed the turn to another run (of its
    // project, or the next in line): wake whoever may start now.
    if (r.freed or began or started) {
        r.freed = false;
        wakeReady(r, a, ops, sample);
    }
    r.syncRecord();
    r.pool.unlock();
    // When to look again: each second while first in line, held back by something that can
    // change without a word (a gate, outside work), or a drain (waiting for its turn or its
    // cores; holding them, its idle and noise watches sample each second); else every 10 s (a wake
    // comes when a token frees).
    var every: i64 = 10_000;
    if (head or blocked or r.rec.drain) every = 1000;
    r.next_look = sys.monoMs() + every;
}

/// What a decision knows besides the records: the tokens, and those held back for outside work.
fn context(r: *Run, a: std.mem.Allocator, ops: []const Op, sample: ?pool_mod.Sample, now: i64) pool_mod.Cx {
    const n: u32 = @intCast(r.toks.len);
    return .{ .n = n, .held_back = pool_mod.heldBack(a, ops, sample, r.ctx.cfg.outside_check, r.ncpu, n, now), .now_ms = now };
}

/// Takes the token of `cpu`: continues a task cpuq stopped (after a Ctrl-Z) on that CPU, else
/// starts the next task there.
fn takeToken(r: *Run, a: std.mem.Allocator, cpu: u32, now: i64) void {
    for (r.running.items) |*t| if (t.paused_ms != 0) {
        t.cpu = cpu;
        if (is_linux) repinTree(r, a, t.pid, &.{cpu});
        resumeTask(r, t, now);
        return;
    };
    startTask(r, a, cpu);
}

/// Wakes every other run that may take a token now, and every drain whose turn has come. Under
/// the lock.
fn wakeReady(r: *Run, a: std.mem.Allocator, ops: []const Op, sample: ?pool_mod.Sample) void {
    const now = sys.monoMs();
    const cx = context(r, a, ops, sample, now);
    const free = pool_mod.freeTokens(ops, cx.n, cx.held_back, now);
    for (ops) |o| {
        if (o.ticket == r.rec.ticket or o.waiting == 0 or o.stopped) continue;
        // A drain is woken when its turn may have come (it works out its cores itself).
        const ready = if (o.drain) pool_mod.drainMayStart(ops, o.ticket, policy.drainMax(r.ctx.cfg, cx.n), now, 0, free) == .go else pool_mod.mayStart(a, ops, o.ticket, cx) == .go;
        if (ready) r.pool.wakeOp(o.ticket);
    }
}

/// A drain's look: once its turn comes and the tokens of whole cores enough are free, it takes
/// them all at once, isolating those CPUs, and starts its command (once they are quiet, with
/// --quiet-max), or continues it after a Ctrl-Z. Until then it holds nothing. Returns whether it
/// began isolating now. Under the lock.
fn drainStep(r: *Run, a: std.mem.Allocator, ops: []Op, why: []const u8, cx: pool_mod.Cx) bool {
    const now = cx.now_ms;
    if (r.stopped) return false;
    if (r.rec.dstart != 0) {
        // Isolating, and waiting for its CPUs to quiet (--quiet-max): the command starts once a
        // look since the isolation began found work from outside under the bound.
        if (r.o.quiet_max) |q| if (r.running.items.len == 0 and r.pending() > 0 and r.noise_measured) {
            if (r.rec.noise <= q) {
                r.setWhy("");
                startTask(r, a, r.rec.pin[0]);
                // Its time limit counts from the isolation, the quiet wait included.
                for (r.running.items) |*t| t.start_ms = r.rec.dstart;
                r.syncRecord();
            } else {
                r.setWhy(a.print("waits for its CPUs to quiet: {d:.2} busy from outside{s}{s} (--quiet-max {d:.2})", .{ r.rec.noise, if (r.rec.noisy_top.len != 0) ", most " else "", r.rec.noisy_top, q }) catch "waits for its CPUs to quiet");
            }
        };
        return false;
    }
    if (r.pending() == 0 and r.running.items.len == 0) return false;
    if (why.len != 0) {
        r.setWhy(why);
        return false;
    }
    const room = policy.drainMax(r.ctx.cfg, cx.n);
    const free = pool_mod.freeTokens(ops, cx.n, cx.held_back, now);
    // Its turn first: older drains, older runs waiting holding nothing, and drain_max.
    const turn = pool_mod.drainMayStart(ops, r.rec.ticket, room, now, @min(r.limit, room), cx.n);
    if (turn != .go) {
        r.setWhy(switch (turn) {
            .older_waiter => "runs queued before it go first",
            .older_drain => "an older drain goes first",
            .half_pool => "drains hold drain_max of the tokens already",
            .full, .taken, .go => "",
        });
        return false;
    }
    // Then whole cores whose tokens are all free: every task holds its own CPU's.
    const order = drainOrder(r.ctx, r.toks, r.o.prefer_fast);
    const pick = pool_mod.pickDrain(a, order, r.topo, pool_mod.heldCpus(a, ops, now), r.limit, r.o.drain_cpus) orelse {
        r.setWhy(if (r.o.drain_cpus.len != 0)
            "waits for the CPUs it names (and their siblings) to be free"
        else
            a.print("waits for {d} whole core{s} to be free (tasks hold every token but {d})", .{ r.limit, if (r.limit == 1) "" else "s", free }) catch "waits for whole cores to be free");
        return false;
    };
    const need = pool_mod.inPool(pick.cpus, r.toks);
    const w = pool_mod.drainMayStart(ops, r.rec.ticket, room, now, need, free);
    if (w != .go) {
        r.setWhy(switch (w) {
            .half_pool => "drains hold drain_max of the tokens already",
            .full => a.print("waits for {d} free tokens ({d} free)", .{ need, free }) catch "waits for free tokens",
            else => "",
        });
        return false;
    }
    r.setWhy("");
    r.rec.cpus = r.a.dupe(u32, pick.cpus) catch pick.cpus;
    r.rec.pin = r.a.dupe(u32, pick.pin) catch pick.pin;
    r.rec.npool = need;
    r.rec.dstart = now;
    if (r.iso_t == 0) r.iso_t = joblog.nowFloat(r.ctx.io);
    r.iso_n = @max(r.iso_n, @as(u32, @intCast(pick.cpus.len)));
    r.rec.noise = 0;
    r.rec.noisy_top = "";
    r.noise_measured = false;
    if (r.running.items.len == 0) {
        if (r.o.quiet_max == null) startTask(r, a, r.rec.pin[0]) else r.setWhy("measures its CPUs for --quiet-max");
    } else {
        // Continued after a Ctrl-Z: onto its CPUs (perhaps others than before), then on.
        for (r.running.items) |*t| {
            if (is_linux) repinTree(r, a, t.pid, r.rec.pin);
            resumeTask(r, t, now);
        }
    }
    r.syncRecord();
    return true;
}

/// Whether process `p` may be what crowds a drain: on Linux last seen on its CPUs; on macOS any.
fn onDrainCpus(r: *const Run, p: sys.Proc) bool {
    if (!is_linux) return true;
    const cpu = p.last_cpu orelse return false;
    return std.mem.findScalar(u32, r.rec.cpus, cpu) != null;
}

/// Busy CPUs from outside a drain on its CPUs at which history and status call it noisy.
pub const noisy_min: f64 = 0.1;

/// While a drain isolates: once a second, the work from outside it on its CPUs. Linux: the busy
/// share of each of its CPUs (kernel ticks) less its own command's CPU time (kernel threads,
/// interrupts, processes cpuq doesn't run). macOS, where no CPU is its own: the machine's busy
/// CPUs less its command's, beyond the CPUs it leaves to everything else. Noted in its record for
/// status; while its command runs, summed for history; above `noisy_min`, the busiest such
/// process (on Linux, last seen on its CPUs) is named.
fn noiseDrain(r: *Run) void {
    if (r.rec.dstart == 0 or r.stopped) return;
    const now = sys.monoMs();
    if (r.noise_at_ms >= r.rec.dstart and now - r.noise_at_ms < 1000) return;
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // macOS: the machine's ticks, as one entry for CPU 0 standing for all.
    const ticks: []const sys.NumberedTicks = if (is_linux) sys.numberedTicks(r.ctx.io, a) orelse return else blk: {
        const t = sys.cpuTicks(r.ctx.io) orelse return;
        const one = a.alloc(sys.NumberedTicks, 1) catch return;
        one[0] = .{ .cpu = 0, .busy = t.busy, .total = t.total };
        break :blk one;
    };
    const procs = sys.processes(r.ctx.io, a);
    const me = sys.getpid();
    var own_self: u64 = 0;
    for (procs) |p| if (p.pid == me) {
        own_self = p.own_ns;
    };
    const own = sys.treeCpu(procs, me) -| own_self;
    const in_tree = a.alloc(bool, procs.len) catch return;
    @memset(in_tree, false);
    sys.markTree(procs, me, in_tree);
    const fresh = r.noise_at_ms < r.rec.dstart;
    var busy_on: f64 = 0;
    if (!fresh) for (ticks) |t| {
        if (is_linux and std.mem.findScalar(u32, r.rec.cpus, t.cpu) == null) continue;
        for (r.noise_ticks.items) |q| if (q.cpu == t.cpu and t.total > q.total) {
            busy_on += @as(f64, @floatFromInt(t.busy -| q.busy)) / @as(f64, @floatFromInt(t.total - q.total));
        };
    };
    // macOS: the machine's share busy, in CPUs, and what it leaves to others.
    const others: f64 = if (is_linux) 0 else @floatFromInt(r.ncpu -| @as(u32, @intCast(r.rec.pin.len)));
    if (!is_linux) busy_on *= @floatFromInt(r.ncpu);
    const dt: f64 = @floatFromInt(@max(now - r.noise_at_ms, 1));
    const own_busy = if (fresh) 0 else @as(f64, @floatFromInt(own -| r.noise_own_ns)) / 1e6 / dt;
    const outside = if (fresh) 0 else @max(0, busy_on - own_busy - others);
    // The busiest process outside it last seen on its CPUs, by its CPU time since the last look.
    var top: []const u8 = "";
    if (!fresh and outside >= noisy_min) {
        var best: u64 = 0;
        for (procs, in_tree) |p, mine| {
            if (mine or !onDrainCpus(r, p)) continue;
            const was = r.noise_procs.get(p.pid) orelse continue;
            const used = p.own_ns -| was;
            if (used > best) {
                best = used;
                top = std.fmt.bufPrint(&r.top_buf, "{s} ({d})", .{ p.name, p.pid }) catch "";
            }
        }
    }
    r.noise_procs.clearRetainingCapacity();
    for (procs, in_tree) |p, mine| if (!mine and onDrainCpus(r, p)) {
        r.noise_procs.put(r.a, p.pid, p.own_ns) catch {};
    };
    r.noise_ticks.clearRetainingCapacity();
    r.noise_ticks.appendSlice(r.a, ticks) catch {};
    r.noise_own_ns = own;
    r.noise_at_ms = now;
    if (fresh) return;
    r.noise_measured = true;
    r.rec.noise = outside;
    r.rec.noisy_top = if (outside >= noisy_min) top else "";
    if (r.running.items.len != 0 and r.first_start_ms != 0) {
        r.noise_sum += outside;
        r.noise_n += 1;
        if (outside > r.noise_max) {
            r.noise_max = outside;
            const n = @min(top.len, r.max_top_buf.len);
            @memcpy(r.max_top_buf[0..n], top[0..n]);
            r.noise_top = r.max_top_buf[0..n];
        }
    }
}

/// Linux: sets every thread of the task's processes to `cpus`.
fn repinTree(r: *Run, a: std.mem.Allocator, root: c.pid_t, cpus: []const u32) void {
    if (cpus.len == 0) return;
    const procs = sys.processes(r.ctx.io, a);
    const in_tree = a.alloc(bool, procs.len) catch return;
    @memset(in_tree, false);
    sys.markTree(procs, root, in_tree);
    for (procs, in_tree) |p, yes| if (yes) sys.setThreads(r.ctx.io, a, p.pid, cpus);
}

/// Why a run waits, in words, for status.
fn whyText(w: pool_mod.Wait, cx: pool_mod.Cx) []const u8 {
    return switch (w) {
        .go, .idle => "",
        .full => if (cx.held_back != 0) "every token is held (some held back for work outside cpuq)" else "every token is held",
        .behind => "another run is first in line",
        .project => "another run of its project goes first",
    };
}

/// Linux: how many CPUs are online (/sys/devices/system/cpu/online), whatever this process's
/// CPU set.
fn onlineCount(io: Io) ?u32 {
    var buf: [1024]u8 = undefined;
    const text = Io.Dir.cwd().readFile(io, "/sys/devices/system/cpu/online", &buf) catch return null;
    return policy.cpuListCount(std.mem.trim(u8, text, " \n"));
}

/// Why no task may start now, or "" when one may: the machine's memory and disk gates.
fn gate(r: *Run, a: std.mem.Allocator) []const u8 {
    const m = main.machine(r.ctx);
    return switch (policy.gate(r.ctx.cfg, m)) {
        .open => "",
        .pressure => "memory pressure",
        .low_memory => "low memory",
        .low_disk => |d| std.fmt.allocPrint(a, "low disk on {s}", .{d.path}) catch "low disk",
    };
}

fn finish(r: *Run) u8 {
    if (r.gave_up) {
        if (r.never_quiet)
            std.debug.print("cpuq: the drain's CPUs never quieted under --quiet-max {d:.2} in time (last {d:.2} busy from outside{s}{s}); nothing ran\n", .{ r.o.quiet_max orelse 0, r.rec.noise, if (r.rec.noisy_top.len != 0) ", most " else "", r.rec.noisy_top })
        else
            std.debug.print("cpuq: no task started within --wait-max; nothing ran\n", .{});
        return 75;
    }
    if (r.single) {
        if (r.outcomes.items.len == 0) {
            // Stopped by a signal before it ran: end the same way.
            if (r.stop_signal != 0) sys.dieBySignal(@fromBackingInt(@intCast(r.stop_signal)));
            return 125;
        }
        const out = r.outcomes.items[r.outcomes.items.len - 1];
        if (out.timed_out) {
            if (r.long_stopped)
                std.debug.print("cpuq: drain stopped at drain_timeout ({d}s): others waited for its CPUs\n", .{r.ctx.cfg.drain_timeout_s})
            else if (r.idle_stopped)
                std.debug.print("cpuq: drain stopped: its command kept under {d:.2} CPUs busy for {d}s while others waited\n", .{ drain_idle_busy, r.ctx.cfg.drain_idle_s })
            else
                std.debug.print("cpuq: stopped at its time limit\n", .{});
            return 124;
        }
        if (r.last_wait) |w| switch (w.exit) {
            .signal => |sig| sys.dieBySignal(sig),
            .code => |code| return code,
        };
        return out.code;
    }
    return summary(r);
}

fn summary(r: *Run) u8 {
    var failed: std.ArrayList(Outcome) = .empty;
    var timed: u32 = 0;
    var retried: u32 = 0;
    var stopped: u32 = 0;
    for (r.outcomes.items) |o| {
        if (o.stopped) {
            stopped += 1;
            continue;
        }
        if (o.code != 0) failed.append(r.a, o) catch {};
        if (o.timed_out) timed += 1;
        if (o.attempt > 1) retried += 1;
    }
    const secs = @as(f64, @floatFromInt(sys.monoMs() - r.started_ms)) / 1000;
    const not_run = r.total -| @as(u32, @intCast(r.outcomes.items.len));
    std.debug.print("cpuq: {d} of {d} tasks passed", .{ r.outcomes.items.len - failed.items.len - stopped, r.total });
    if (failed.items.len != 0) std.debug.print(", {d} failed", .{failed.items.len});
    if (timed != 0) std.debug.print(" ({d} at the time limit)", .{timed});
    if (retried != 0) std.debug.print(", {d} passed or ended on a retry", .{retried});
    if (stopped != 0) std.debug.print(", {d} stopped", .{stopped});
    if (not_run != 0) std.debug.print(", {d} not run", .{not_run});
    std.debug.print(", in {d:.1}s; output in {s}\n", .{ secs, r.out_dir });
    for (failed.items, 0..) |o, i| {
        if (i == 5) {
            std.debug.print("cpuq: ... and {d} more failed\n", .{failed.items.len - 5});
            break;
        }
        std.debug.print("cpuq: task {d} (attempt {d}) exited {d}; the end of {s}:\n", .{ o.index, o.attempt, o.code, o.out });
        printTail(r, o.out, 5);
    }
    if (r.stop_signal != 0) sys.dieBySignal(@fromBackingInt(@intCast(r.stop_signal)));
    return if (failed.items.len != 0 or not_run != 0 or stopped != 0) 1 else 0;
}

fn printTail(r: *Run, path: []const u8, lines: usize) void {
    const text = Io.Dir.cwd().readFileAlloc(r.ctx.io, path, r.a, .limited(1 << 20)) catch return;
    const body = std.mem.trimEnd(u8, text, "\n");
    if (body.len == 0) {
        std.debug.print("    (no output)\n", .{});
        return;
    }
    var from: usize = body.len;
    var n: usize = 0;
    while (from > 0 and n < lines) {
        from -= 1;
        if (body[from] == '\n') n += 1;
    }
    if (n == lines) from += 1;
    var it = std.mem.splitScalar(u8, body[from..], '\n');
    while (it.next()) |l| std.debug.print("    {s}\n", .{l});
}

/// Where a run of many tasks keeps each task's output: ~/.local/state/cpuq/runs/PROJECT/STAMP.
fn outDir(ctx: *Ctx, project: []const u8) ![]const u8 {
    const home = ctx.env.get("HOME") orelse return error.NoHome;
    const now = main.nowSeconds(ctx.io);
    const path = try std.fmt.allocPrint(ctx.arena, "{s}/.local/state/cpuq/runs/{s}/{d}-{d}", .{ home, if (project.len == 0) "-" else project, now, sys.getpid() });
    try Io.Dir.cwd().createDirPath(ctx.io, path);
    return path;
}

/// The project a run counts for: the repo it runs in (each worktree counts as its repo), else
/// its label's project, else "-".
/// A run's project: its label's (`project:task`), else the repository it runs in, else "-". The
/// label comes first: on burst every run sits inside the home folder, itself a repository, which
/// made every project one.
pub fn projectOf(ctx: *Ctx, o: Opts) []const u8 {
    if (o.label.len != 0) return std.mem.sliceTo(o.label, ':');
    const cwd = std.process.currentPathAlloc(ctx.io, ctx.arena) catch "";
    if (repos.repoAt(ctx, cwd)) |name| return name;
    return "-";
}

fn weightOf(ctx: *Ctx, project: []const u8) u32 {
    return policy.weightFor(ctx.cfg, project);
}

// --- Drivers -------------------------------------------------------------------------------

/// A `--driver`'s cpuq while its runner runs: in the pool as a record of its own (no task), it
/// measures once a second what the runner's process tree keeps busy itself, the trees of the runs
/// it starts left out, and notes it (`dbusy`) for the line, which counts it against the project's
/// share, and for status. Returns how the runner ended.
pub fn watchDriver(ctx: *Ctx, label: []const u8, cmd: []const u8, child: c.pid_t) sys.Waited {
    const a = ctx.arena;
    var pool = Pool.open(ctx.io, a, main.stateDir(ctx)) catch return sys.waitChild(child);
    const project = projectOf(ctx, .{ .label = label });
    var rec: Op = .{
        .driver = true,
        .pid = sys.getpid(),
        .project = project,
        .label = if (label.len != 0) label else "driver",
        .weight = weightOf(ctx, project),
        .tasks = 0,
        .limit = 0,
        .since = main.nowSeconds(ctx.io),
        .cmd = cmd,
    };
    pool.lock();
    const file = pool.enter(&rec) catch {
        pool.unlock();
        return sys.waitChild(child);
    };
    pool.unlock();
    var last_ms: i64 = 0;
    var last_ns: u64 = 0;
    while (true) {
        if (sys.reapChild(child)) |w| {
            pool.lock();
            pool.leave(file, rec);
            pool.unlock();
            return w;
        }
        const now = sys.monoMs();
        if (now - last_ms >= 1000) {
            var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer arena.deinit();
            const sa = arena.allocator();
            pool.lock();
            const ops = pool.scan(sa);
            pool.unlock();
            const own = driverCpu(sa, sys.processes(ctx.io, sa), child, ops);
            if (last_ms != 0) {
                rec.dbusy = @as(f64, @floatFromInt(own -| last_ns)) / 1e6 / @as(f64, @floatFromInt(@max(now - last_ms, 1)));
                pool.lock();
                pool.write(file, rec) catch {};
                pool.unlock();
            }
            last_ms = now;
            last_ns = own;
        }
        var ts: c.timespec = .{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
        _ = c.nanosleep(&ts, null);
    }
}

/// The CPU time (ns, each process's own) of the runner's process tree, less the trees of the runs
/// in it (`cpuq run`s it started, each a record in the pool). A process that ends between two
/// looks counts until it ends.
fn driverCpu(a: std.mem.Allocator, procs: []const sys.Proc, runner: c.pid_t, ops: []const Op) u64 {
    const in_tree = a.alloc(bool, procs.len) catch return 0;
    @memset(in_tree, false);
    sys.markTree(procs, runner, in_tree);
    const runs = a.alloc(bool, procs.len) catch return 0;
    @memset(runs, false);
    for (ops) |o| if (!o.driver) {
        const at = for (procs, 0..) |p, i| {
            if (p.pid == o.pid) break i;
        } else continue;
        if (in_tree[at]) sys.markTree(procs, o.pid, runs);
    };
    var total: u64 = 0;
    for (procs, in_tree, runs) |p, mine, theirs| if (mine and !theirs) {
        total += p.own_ns;
    };
    return total;
}

// --- Nested runs ---------------------------------------------------------------------------

/// Whether this process runs inside a task: CPUQ_OP names a live run, or else an ancestor
/// process is a live run's cpuq (which no `env -i` can hide).
pub fn nested(ctx: *Ctx) bool {
    const a = ctx.arena;
    var pool = Pool.open(ctx.io, a, main.stateDir(ctx)) catch return false;
    pool.lock();
    const ops = pool.scan(a);
    pool.unlock();
    if (ops.len == 0) return false;
    if (ctx.env.get("CPUQ_OP")) |op_text| {
        const ticket = std.fmt.parseInt(u64, op_text, 10) catch 0;
        for (ops) |o| if (o.ticket == ticket and !o.driver) return true;
    }
    // A driver's runs are runs of their own, not nested in it.
    var pid = c.getppid();
    var hops: u32 = 0;
    while (pid > 1 and hops < 64) : (hops += 1) {
        for (ops) |o| if (o.pid == pid and !o.driver) return true;
        pid = sys.parentOf(pid) orelse return false;
    }
    return false;
}

/// A run inside a task: within that task, with no line. One task runs in this process's place;
/// many run one at a time, as the task's own work.
fn runNested(ctx: *Ctx, o: Opts, exe: [:0]const u8) u8 {
    if (o.tasks == 0) {
        // Become the command: nothing to watch.
        const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch main.fail("out of memory", .{});
        const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch main.fail("out of memory", .{});
        for (o.cmd, 0..) |arg, k| argv[k] = arg.ptr;
        _ = c.execve(exe, argv.ptr, @ptrCast(envp.slice.ptr));
        std.debug.print("cpuq: {s}: exec failed\n", .{o.cmd[0]});
        return main.exit_noexec;
    }
    var failed: u32 = 0;
    var i: u32 = 1;
    while (i <= o.tasks) : (i += 1) {
        var num: [16]u8 = undefined;
        ctx.env.put("CPUQ_TASK", std.fmt.bufPrint(&num, "{d}", .{i}) catch "1") catch {};
        var tot: [16]u8 = undefined;
        ctx.env.put("CPUQ_TASKS", std.fmt.bufPrint(&tot, "{d}", .{o.tasks}) catch "1") catch {};
        const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch main.fail("out of memory", .{});
        const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch main.fail("out of memory", .{});
        for (o.cmd, 0..) |arg, k| argv[k] = arg.ptr;
        const pid = sys.spawn(exe, argv.ptr, @ptrCast(envp.slice.ptr), .unchanged, .{}) catch {
            failed += 1;
            continue;
        };
        var status: c_int = 0;
        if (c.waitpid(pid, &status, 0) <= 0) {
            failed += 1;
            continue;
        }
        const st: u32 = @bitCast(status);
        if (!(c.W.IFEXITED(st) and c.W.EXITSTATUS(st) == 0)) failed += 1;
    }
    return if (failed != 0) 1 else 0;
}

// --- cpuq drain, cpuq limit, cpuq kill ------------------------------------------------------

/// The longest a drain may run: `-t` and config `drain_timeout` go no higher.
pub const drain_ceiling_s: u32 = 2 * 3600;
/// A drain whose command keeps fewer CPUs than this busy (CPU seconds a second) for
/// `drain_idle` while another run waits is stopped: a timing run computes.
pub const drain_idle_busy: f64 = 0.25;

/// The order a drain takes its CPUs in: fastest first (`--prefer fast`), else from the pool's
/// end (on a machine with SMT, the second threads, whose cores are whole either way).
fn drainOrder(ctx: *Ctx, pool_cpus: []const u32, fast: bool) []const u32 {
    if (fast) return cpus_mod.fastFirst(ctx.io, ctx.arena, pool_cpus);
    const out = ctx.arena.dupe(u32, pool_cpus) catch return pool_cpus;
    std.mem.reverse(u32, out);
    return out;
}

/// `cpuq drain -c N [--cpus LIST] [--prefer fast] [--quiet-max X] [-t T] [--max T] [--label L]
/// -- CMD`: times CMD on CPUs of its own. It takes its turn in the line (it passes no run queued
/// before it that runs nothing yet), then, once the tokens of N whole cores (their SMT siblings
/// too) are free, takes them all at once for CMD, pinned there on Linux; no task is on them, as
/// every task is on its own token's CPU. Nothing is gathered or held while it waits. With --max,
/// a drain that hasn't started CMD by then gives up (exit 75).
pub fn cmdDrain(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var o: Opts = .{ .drain = true };
    var count: ?u32 = null;
    var named_text: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            o.cmd = args[i + 1 ..];
            break;
        }
        if (arg.len == 0 or arg[0] != '-') {
            o.cmd = args[i..];
            break;
        }
        if (std.mem.eql(u8, arg, "--all")) {
            std.debug.print("cpuq: --all is gone: use -c N; its N CPUs are isolated at once, and the rest of the machine keeps working\n", .{});
            return main.exit_usage;
        }
        if (i + 1 >= args.len) return main.usageError("{s} needs a value", .{arg});
        const v = args[i + 1];
        if (std.mem.eql(u8, arg, "--max")) {
            o.wait_max_s = policy.parseAge(v) orelse return main.usageError("--max needs a time such as 90s or 10m, not '{s}'", .{v});
        } else if (std.mem.eql(u8, arg, "--label")) {
            o.label = v;
        } else if (std.mem.eql(u8, arg, "-t")) {
            const t = policy.parseAge(v) orelse 0;
            if (t == 0 or t > drain_ceiling_s) return main.usageError("a drain's -t needs a time limit up to 2h, such as 20m or 1h, not '{s}'", .{v});
            o.timeout_s = t;
        } else if (std.mem.eql(u8, arg, "-c")) {
            count = policy.parseWhole(u32, v) orelse 0;
            if (count.? == 0) return main.usageError("a drain's -c needs the number of CPUs it times on, at least 1, not '{s}'", .{v});
        } else if (std.mem.eql(u8, arg, "--cpus")) {
            named_text = v;
        } else if (std.mem.eql(u8, arg, "--prefer")) {
            if (!std.mem.eql(u8, v, "fast")) return main.usageError("--prefer takes fast (performance cores first), not '{s}'", .{v});
            o.prefer_fast = true;
        } else if (std.mem.eql(u8, arg, "--quiet-max")) {
            const q = std.fmt.parseFloat(f64, v) catch -1;
            if (!(q >= 0)) return main.usageError("--quiet-max needs the busy CPUs from outside it allows, such as 0.1, not '{s}'", .{v});
            o.quiet_max = q;
        } else return main.usageError("unknown option '{s}'", .{arg});
        i += 1;
    }
    if (o.cmd.len == 0) return main.usageError("drain needs a command", .{});
    main.loadConfig(ctx);
    const pool_cpus = poolCpus(ctx);
    const toks = pool_mod.tokens(pool_cpus, ctx.cfg.reserve);
    if (named_text) |text| {
        o.drain_cpus = policy.cpuList(ctx.arena, text) catch return main.usageError("--cpus needs a CPU list such as 0-3 or 2,4, not '{s}'", .{text});
        if (o.drain_cpus.len == 0) return main.usageError("--cpus needs at least one CPU", .{});
        for (o.drain_cpus) |cpu| if (std.mem.findScalar(u32, toks, cpu) == null) return main.usageError("--cpus {s}: CPU {d} is not one of the tokens ({s}; the reserve and CPUs outside the pool are never handed out)", .{ text, cpu, policy.cpuListText(ctx.arena, toks) });
        if (count) |n| if (n != o.drain_cpus.len) return main.usageError("-c {d} and --cpus {s} ({d} CPUs) disagree; --cpus alone is enough", .{ n, text, o.drain_cpus.len });
        if (o.prefer_fast) return main.usageError("--prefer picks the CPUs; --cpus names them: give one", .{});
        count = @intCast(o.drain_cpus.len);
    }
    o.cpus = count orelse return main.usageError("a drain takes -c N, the CPUs it times on (or --cpus LIST, which names them); the rest of the machine keeps working", .{});
    o.cpus_percent = false;
    // N whole cores, siblings included, must fit in drain_max (half the tokens by default).
    const room = policy.drainMax(ctx.cfg, @intCast(toks.len));
    const pick = pool_mod.pickDrain(ctx.arena, drainOrder(ctx, toks, o.prefer_fast), cpus_mod.cores(ctx.io, ctx.arena, pool_cpus), &.{}, o.cpus, o.drain_cpus) orelse
        return main.usageError("the tokens have too few whole cores for a drain of {d}", .{o.cpus});
    const need = pool_mod.inPool(pick.cpus, toks);
    if (need > room) {
        if (need > o.cpus) return main.usageError("a drain of {d} CPU{s} takes {d} tokens with their SMT siblings, more than drain_max ({d} here)", .{ o.cpus, if (o.cpus == 1) "" else "s", need, room });
        return main.usageError("a drain takes at most drain_max of the tokens ({d} here)", .{room});
    }
    if (o.timeout_s == null) o.timeout_s = @min(@max(ctx.cfg.drain_timeout_s, 1), drain_ceiling_s);
    return run(ctx, o);
}

/// `cpuq limit OP -c C [--host HOST]`: changes how many tokens a running run of this user's
/// holds at once (its -c), named by its ticket, its cpuq's pid or its label: a count, or a
/// percentage of the tokens. Raised, it starts more as the line allows; lowered, it starts none until fewer
/// run.
pub fn cmdLimit(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var want: ?[]const u8 = null;
    var cpus: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if ((std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--host")) and i + 1 < args.len) {
            if (arg[1] == 'c') cpus = args[i + 1] else host = args[i + 1];
            i += 1;
        } else if (want == null and arg.len != 0 and arg[0] != '-') {
            want = arg;
        } else return main.usageError("limit takes one run (its ticket, pid or label) and -c C", .{});
    }
    const target = want orelse return main.usageError("limit needs the run: its ticket, pid or label (cpuq status shows them)", .{});
    const value = cpus orelse return main.usageError("limit needs -c C: the most tasks it runs at once, a count or a percentage of the tokens (50%)", .{});
    const pct = std.mem.endsWith(u8, value, "%");
    const count = policy.parseCount(if (pct) value[0 .. value.len - 1] else value) orelse return main.usageError("-c needs a whole number of tasks or a percentage (50%), not '{s}'", .{value});
    if (pct and count > 100) return main.usageError("-c takes at most 100%, not '{s}'", .{value});
    if (host) |h| return @import("records.zig").onHost(ctx, h, ctx.arena.print("cpuq limit {s} -c {s}", .{ target, value }) catch return 125);
    main.loadConfig(ctx);
    const a = ctx.arena;
    var pool = Pool.open(ctx.io, a, main.stateDir(ctx)) catch |err| main.fail("pool: {t}", .{err});
    const pool_cpus = poolCpus(ctx);
    pool.lock();
    const ops = pool.scan(a);
    pool.unlock();
    const n_num = std.fmt.parseInt(i64, target, 10) catch -1;
    var hits: std.ArrayList(Op) = .empty;
    for (ops) |o| {
        if ((n_num >= 0 and (o.ticket == @as(u64, @intCast(n_num)) or o.pid == n_num)) or std.mem.eql(u8, o.label, target)) hits.append(a, o) catch {};
    }
    if (hits.items.len == 0) {
        std.debug.print("cpuq: no run here is {s}\n", .{target});
        return 1;
    }
    if (hits.items.len > 1) {
        std.debug.print("cpuq: {d} runs are {s}; name one by its ticket:\n", .{ hits.items.len, target });
        for (hits.items) |o| std.debug.print("  {d}  pid {d}  {s}  -c {d}  {s}\n", .{ o.ticket, o.pid, o.label, o.limit, o.cmd });
        return 1;
    }
    const o = hits.items[0];
    if (o.drain) {
        std.debug.print("cpuq: {d} ({s}) is a drain: its CPUs are fixed when it starts\n", .{ o.ticket, o.label });
        return 1;
    }
    const ntok: u32 = @intCast(pool_mod.tokens(pool_cpus, ctx.cfg.reserve).len);
    const n = @max(1, if (pct) @as(u32, @intCast(@max(1, (@as(u64, ntok) * count) / 100))) else count);
    pool.askLimit(o.pid, n) catch |err| main.fail("pool: {t}", .{err});
    pool.wakeOp(o.ticket);
    ctx.out.print("{d} ({s}): up to {d} at once, was {d}\n", .{ o.ticket, o.label, n, o.limit }) catch {};
    ctx.out.flush() catch {};
    return 0;
}

/// `cpuq reserve [N] [--host HOST]`: sets aside the pool's last N CPUs, which cpuq never hands
/// out, in the machine's config (`reserve = N`). Every run takes it up at its next look, and is
/// woken for one now: running tasks finish, and fewer start until fewer than the new N run.
/// Alone, it prints the tokens and the reserve. There is always at least one token.
pub fn cmdReserve(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var want: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        } else if (want == null and arg.len != 0 and arg[0] != '-') {
            want = arg;
        } else return main.usageError("reserve takes the CPUs to set aside (N) and --host HOST", .{});
    }
    if (host) |h| return @import("records.zig").onHost(ctx, h, if (want) |w| ctx.arena.print("cpuq reserve {s}", .{w}) catch return 125 else "cpuq reserve");
    main.loadConfig(ctx);
    const pool_n: u32 = @intCast(poolCpus(ctx).len);
    const was = ctx.cfg.reserve;
    const show = struct {
        fn line(cx: *Ctx, n: u32, r: u32, before: ?u32) void {
            cx.out.print("{d} token{s}, {d} reserved", .{ n, if (n == 1) "" else "s", r }) catch {};
            if (before) |b| cx.out.print(" (was {d} reserved)", .{b}) catch {};
            cx.out.writeAll("\n") catch {};
            cx.out.flush() catch {};
        }
    };
    const pool_tokens = struct {
        fn of(pn: u32, r: u32) u32 {
            return @max(1, pn -| r);
        }
    };
    const text = want orelse {
        show.line(ctx, pool_tokens.of(pool_n, was), @min(was, pool_n -| 1), null);
        return 0;
    };
    const n = policy.parseWhole(u32, text) orelse return main.usageError("reserve needs a whole number of CPUs, such as 2, not '{s}'", .{text});
    if (n >= pool_n) return main.usageError("reserve {d} would leave no token: the pool has {d} CPUs, so at most {d}", .{ n, pool_n, pool_n -| 1 });
    if (ctx.cfg_path.len == 0) main.fail("no config file: set HOME or CPUQ_CONFIG", .{});
    const old = Io.Dir.cwd().readFileAlloc(ctx.io, ctx.cfg_path, ctx.arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => main.fail("{s}: {t}", .{ ctx.cfg_path, err }),
    };
    const new = policy.withKey(ctx.arena, old, "reserve", text) catch main.fail("out of memory", .{});
    // The new text must read as the old did, with the new reserve.
    var cfg: policy.Config = .{};
    var diag: policy.Diagnostic = .{};
    policy.parseConfig(new, &cfg, &diag) catch main.fail("{s}:{d}: {s} ({s}); left as it was", .{ ctx.cfg_path, diag.line, diag.message, diag.key });
    if (std.fs.path.dirname(ctx.cfg_path)) |dir| Io.Dir.cwd().createDirPath(ctx.io, dir) catch {};
    const tmp = ctx.arena.print("{s}.new", .{ctx.cfg_path}) catch main.fail("out of memory", .{});
    Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = tmp, .data = new }) catch |err| main.fail("{s}: {t}", .{ tmp, err });
    Io.Dir.cwd().rename(tmp, Io.Dir.cwd(), ctx.cfg_path, ctx.io) catch |err| main.fail("{s}: {t}", .{ ctx.cfg_path, err });
    // Every run looks at once: a raised reserve stops starts, a lowered one hands out more.
    var pool = Pool.open(ctx.io, ctx.arena, main.stateDir(ctx)) catch |err| main.fail("pool: {t}", .{err});
    pool.lock();
    for (pool.scan(ctx.arena)) |o| pool.wakeOp(o.ticket);
    pool.unlock();
    show.line(ctx, pool_tokens.of(pool_n, n), n, was);
    return 0;
}

/// `cpuq kill OP`: ends a run of this user's on this machine, named by its ticket, its cpuq's
/// pid or its label: its cpuq gets SIGTERM and passes it to every task, then kills what is left
/// 5 seconds later.
pub fn cmdKill(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (args.len != 1) return main.usageError("kill needs one run: its ticket, pid or label", .{});
    const want = args[0];
    const a = ctx.arena;
    var pool = Pool.open(ctx.io, a, main.stateDir(ctx)) catch |err| main.fail("pool: {t}", .{err});
    pool.lock();
    const ops = pool.scan(a);
    pool.unlock();
    const n = std.fmt.parseInt(i64, want, 10) catch -1;
    var hits: std.ArrayList(Op) = .empty;
    for (ops) |o| {
        if ((n >= 0 and (o.ticket == @as(u64, @intCast(n)) or o.pid == n)) or std.mem.eql(u8, o.label, want)) hits.append(a, o) catch {};
    }
    if (hits.items.len == 0) {
        std.debug.print("cpuq: no run here is {s}\n", .{want});
        return 1;
    }
    if (hits.items.len > 1) {
        std.debug.print("cpuq: {d} runs are {s}; name one by its ticket:\n", .{ hits.items.len, want });
        for (hits.items) |o| std.debug.print("  {d}  pid {d}  {s}  {s}\n", .{ o.ticket, o.pid, o.label, o.cmd });
        return 1;
    }
    const o = hits.items[0];
    if (c.kill(o.pid, .TERM) != 0) {
        std.debug.print("cpuq: can't signal pid {d}\n", .{o.pid});
        return 1;
    }
    ctx.out.print("stopping {d} ({s}, pid {d})\n", .{ o.ticket, o.label, o.pid }) catch {};
    return 0;
}
