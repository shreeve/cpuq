//! cpuq: a machine-wide CPU core queue. Jobs wait their turn for a number
//! of cores out of a budget, then run in the foreground holding them. There
//! is no daemon: every hold is a flock(2) in the state directory.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const history = @import("history.zig");
const table = @import("table.zig");

test {
    _ = policy;
    _ = state;
    _ = history;
    _ = table;
}

const version = @import("build_options").version;

const usage =
    \\usage: cpuq run [options] [--] CMD [ARGS...]
    \\       cpuq lease NAME [--slots N] [--host HOST] [lease options] [--] CMD [ARGS...]
    \\       cpuq wait --label PATTERN [--max-wait SECONDS]
    \\       cpuq status [--host HOST]... [--json] [--no-usage] [--watch[=SECONDS]]
    \\       cpuq history [--label PATTERN] [--limit N] [--json]
    \\       cpuq first|start|cancel LABEL|PID [--all]    (a waiting job)
    \\       cpuq pause|resume|stop LABEL|PID [--all]     (a running job)
    \\       cpuq budget
    \\       cpuq qos
    \\
    \\run options:
    \\  --cores K|MIN-MAX     cores to hold: exactly K, or MIN to MAX of what is
    \\                        free (default 2; clamped to the budget)
    \\  --priority P          high, normal (default) or low
    \\  --exclusive           take the whole budget once running work drains
    \\  --label TEXT          a name shown by `cpuq status`
    \\  --max-wait SECONDS    give up (exit 75) after waiting this long
    \\  --no-load-check       ignore the load safety valve
    \\  --qos none            leave the command's scheduling class unchanged
    \\
    \\lease: a first-come, first-served lock on NAME (letters, digits, . _ -),
    \\with --priority, --label and --max-wait as for run; --slots N lets N
    \\hold it at once (default 1). --host HOST holds it on HOST's cpuq over ssh
    \\while CMD runs here. CMD gets CPUQ_LEASES. --host HOST --hold, with no
    \\command, prints `held NAME@HOST ENTRY` once granted (ENTRY: a CPUQ_LEASES
    \\entry) and holds the lease until stdin closes, for a script. --exclusive
    \\also takes the machine's whole budget once running work drains, and
    \\keeps it while the lease is held: a timing window (with --host, on HOST).
    \\wait: until no job whose label matches (PATTERN* for a prefix) holds or
    \\waits.
    \\
    \\environment: CPUQ_DIR (state directory), CPUQ_BUDGET, CPUQ_CONFIG
    \\(default ~/.config/cpuq/config). A run gets CPUQ_CORES, CPUQ_TOKEN and
    \\a GNU make jobserver in MAKEFLAGS.
    \\
;

/// Exit statuses of cpuq itself (a command's own status passes through).
const exit_usage = 2;
const exit_timeout = 75;
const exit_failure = 125;
const exit_noexec = 126;
const exit_notfound = 127;

const Ctx = struct {
    io: Io,
    arena: std.mem.Allocator,
    /// `status --watch`'s line under the tables.
    watch_note: ?[]const u8 = null,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    cfg: policy.Config = .{},
    cfg_path: []const u8 = "",
    /// The config file's modification time when last read (0: none read).
    cfg_mtime: i96 = 0,
};

pub fn main(init: std.process.Init) void {
    const io = init.io;
    var out_buf: [8192]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buf);
    var ctx: Ctx = .{ .io = io, .arena = init.arena.allocator(), .env = init.environ_map, .out = &out.interface };
    const args = init.minimal.args.toSlice(ctx.arena) catch fail("out of memory", .{});
    const code = dispatch(&ctx, args[1..]);
    ctx.out.flush() catch {};
    std.process.exit(code);
}

fn dispatch(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (args.len == 0) return usageError("no command given", .{});
    const cmd = args[0];
    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        ctx.out.writeAll(usage) catch {};
        return 0;
    }
    if (std.mem.eql(u8, cmd, "--version")) {
        ctx.out.writeAll("cpuq " ++ version ++ "\n") catch {};
        return 0;
    }
    if (std.mem.eql(u8, cmd, "run")) return cmdRun(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "lease")) return cmdLease(ctx, args[1..]);
    loadConfig(ctx);
    if (std.mem.eql(u8, cmd, "status")) return cmdStatus(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "wait")) return cmdWait(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "history")) return cmdHistory(ctx, args[1..]);
    inline for (.{ "first", "start", "cancel", "pause", "resume", "stop" }) |action| {
        if (std.mem.eql(u8, cmd, action)) return cmdControl(ctx, action, args[1..]);
    }
    if (std.mem.eql(u8, cmd, "budget")) {
        const m = machine(ctx);
        ctx.out.print("{d}\n", .{budgetNow(ctx, m)}) catch {};
        return 0;
    }
    if (std.mem.eql(u8, cmd, "qos")) {
        var buf: [32]u8 = undefined;
        ctx.out.print("{s}\n", .{sys.currentQos(&buf)}) catch {};
        return 0;
    }
    return usageError("unknown command '{s}'", .{cmd});
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cpuq: " ++ fmt ++ "\n", args);
    std.process.exit(exit_failure);
}

fn usageError(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("cpuq: " ++ fmt ++ "\n" ++ usage, args);
    return exit_usage;
}

fn nowSeconds(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

fn loadConfig(ctx: *Ctx) void {
    const path = ctx.env.get("CPUQ_CONFIG") orelse blk: {
        const home = ctx.env.get("HOME") orelse return;
        break :blk std.mem.concat(ctx.arena, u8, &.{ home, "/.config/cpuq/config" }) catch fail("out of memory", .{});
    };
    ctx.cfg_path = path;
    if (Io.Dir.cwd().statFile(ctx.io, path, .{})) |st| ctx.cfg_mtime = st.mtime.nanoseconds else |_| {}
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, path, ctx.arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => fail("{s}: {t}", .{ path, err }),
    };
    var diag: policy.Diagnostic = .{};
    policy.parseConfig(text, &ctx.cfg, &diag) catch {
        std.debug.print("cpuq: {s}:{d}: {s} ({s})\n", .{ path, diag.line, diag.message, diag.key });
        std.process.exit(exit_usage);
    };
}

/// Re-reads the config file when it has changed since it was read, so a run
/// already waiting takes up a new budget or margin. An invalid file keeps
/// the settings in force, and says so once.
fn reloadConfig(ctx: *Ctx) void {
    if (ctx.cfg_path.len == 0) return;
    const st = Io.Dir.cwd().statFile(ctx.io, ctx.cfg_path, .{}) catch {
        // Gone: back to the defaults, once.
        if (ctx.cfg_mtime != 0) {
            ctx.cfg = .{};
            ctx.cfg_mtime = 0;
        }
        return;
    };
    if (st.mtime.nanoseconds == ctx.cfg_mtime) return;
    ctx.cfg_mtime = st.mtime.nanoseconds;
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, ctx.cfg_path, ctx.arena, .limited(1 << 20)) catch return;
    var cfg: policy.Config = .{};
    var diag: policy.Diagnostic = .{};
    policy.parseConfig(text, &cfg, &diag) catch {
        std.debug.print("cpuq: {s}:{d}: {s} ({s}); keeping the settings in force\n", .{ ctx.cfg_path, diag.line, diag.message, diag.key });
        return;
    };
    ctx.cfg = cfg;
}

/// The state directory: CPUQ_DIR, else /tmp/cpuq-UID with /tmp resolved
/// (/private/tmp on macOS), so every session on the machine agrees on it
/// whatever its TMPDIR.
fn stateDir(ctx: *Ctx) []const u8 {
    if (ctx.env.get("CPUQ_DIR")) |d| {
        if (d.len == 0 or d[0] != '/') fail("CPUQ_DIR must be an absolute path, not '{s}'", .{d});
        return d;
    }
    const tmp = Io.Dir.realPathFileAbsoluteAlloc(ctx.io, "/tmp", ctx.arena) catch "/tmp";
    return ctx.arena.print("{s}/cpuq-{d}", .{ tmp, sys.getuid() }) catch fail("out of memory", .{});
}

fn openState(ctx: *Ctx) state.State {
    const dir = stateDir(ctx);
    return state.State.open(ctx.io, dir) catch |err| fail("state directory {s}: {t}", .{ dir, err });
}

fn machine(ctx: *Ctx) policy.Machine {
    return .{
        .active = sys.activeCpus(),
        .load1 = sys.loadAverage()[0],
        .pressure = if (ctx.cfg.pressure_check) sys.memoryPressure(ctx.io, ctx.cfg.pressure_psi) else .off,
    };
}

fn envBudget(ctx: *Ctx) ?u32 {
    const s = ctx.env.get("CPUQ_BUDGET") orelse return null;
    return policy.parseCount(s) orelse fail("CPUQ_BUDGET must be a whole number of cores, at least 1, not '{s}'", .{s});
}

fn budgetNow(ctx: *Ctx, m: policy.Machine) u32 {
    return policy.effectiveBudget(envBudget(ctx), ctx.cfg, m.active);
}

const RunOptions = struct {
    request: policy.Request = .{ .min = 2, .max = 2 },
    priority: policy.Priority = .normal,
    exclusive: bool = false,
    label: []const u8 = "",
    max_wait: ?i64 = null,
    load_check: bool = true,
    qos: bool = true,
    cmd: []const [:0]const u8 = &.{},
    /// A named lease's name; null for cores.
    lease: ?[]const u8 = null,
    /// `cpuq lease --host HOST`: hold the lease on HOST's cpuq over ssh.
    host: ?[]const u8 = null,
    /// `cpuq lease --hold`: once admitted, say so and hold until stdin
    /// closes (the other end of `--host`).
    hold: bool = false,
    /// `cpuq lease --slots N`: how many may hold the lease at once.
    slots: u32 = 1,
    /// Options only `cpuq run` takes, to reject them for a lease.
    run_only: ?[]const u8 = null,
};

fn parseRun(args: []const [:0]const u8) ?RunOptions {
    var o: RunOptions = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--")) {
            o.cmd = args[i + 1 ..];
            return o;
        }
        if (a.len == 0 or a[0] != '-') {
            o.cmd = args[i..];
            return o;
        }
        var name: []const u8 = a;
        var inline_value: ?[]const u8 = null;
        if (std.mem.cutScalar(u8, a, '=')) |kv| {
            name = kv[0];
            inline_value = kv[1];
        }
        const takes_value = for ([_][]const u8{ "--cores", "--priority", "--label", "--max-wait", "--qos", "--host", "--slots" }) |v| {
            if (std.mem.eql(u8, name, v)) break true;
        } else false;
        var value: []const u8 = "";
        if (takes_value) {
            if (inline_value) |v| value = v else {
                i += 1;
                if (i >= args.len) {
                    _ = usageError("{s} needs a value", .{name});
                    return null;
                }
                value = args[i];
            }
        } else if (inline_value != null) {
            _ = usageError("{s} takes no value", .{name});
            return null;
        }
        for ([_][]const u8{ "--cores", "--no-load-check", "--qos" }) |r| {
            if (std.mem.eql(u8, name, r)) o.run_only = r;
        }
        if (std.mem.eql(u8, name, "--cores")) {
            o.request = policy.Request.parse(value) orelse {
                _ = usageError("--cores needs K or MIN-MAX, whole numbers of at least 1, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "--priority")) {
            o.priority = policy.Priority.parse(value) orelse {
                _ = usageError("--priority is high, normal or low, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "--label")) {
            o.label = value;
        } else if (std.mem.eql(u8, name, "--max-wait")) {
            o.max_wait = std.fmt.parseInt(i64, value, 10) catch {
                _ = usageError("--max-wait needs whole seconds, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "--qos")) {
            if (std.mem.eql(u8, value, "none")) o.qos = false else if (std.mem.eql(u8, value, "auto")) o.qos = true else {
                _ = usageError("--qos is none or auto, not '{s}'", .{value});
                return null;
            }
        } else if (std.mem.eql(u8, name, "--exclusive")) {
            o.exclusive = true;
        } else if (std.mem.eql(u8, name, "--no-load-check")) {
            o.load_check = false;
        } else if (std.mem.eql(u8, name, "--host")) {
            o.host = value;
        } else if (std.mem.eql(u8, name, "--slots")) {
            o.slots = policy.parseCount(value) orelse {
                _ = usageError("--slots needs a whole number, at least 1, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "--hold")) {
            o.hold = true;
        } else {
            _ = usageError("unknown option '{s}'", .{a});
            return null;
        }
    }
    return o;
}

/// Finds CMD the way a shell does: a name with a slash as is, else along PATH.
fn findExecutable(ctx: *Ctx, name: []const u8) ?[:0]const u8 {
    const cwd = Io.Dir.cwd();
    if (std.mem.findScalar(u8, name, '/') != null) {
        _ = cwd.statFile(ctx.io, name, .{}) catch return null;
        return ctx.arena.dupeSentinel(u8, name, 0) catch fail("out of memory", .{});
    }
    const path = ctx.env.get("PATH") orelse "/usr/bin:/bin";
    var dirs = std.mem.splitScalar(u8, path, ':');
    while (dirs.next()) |d| {
        const full = std.mem.concat(ctx.arena, u8, &.{ if (d.len == 0) "." else d, "/", name }) catch fail("out of memory", .{});
        const st = cwd.statFile(ctx.io, full, .{}) catch continue;
        if (st.kind != .file) continue;
        cwd.access(ctx.io, full, .{ .execute = true }) catch continue;
        return ctx.arena.dupeSentinel(u8, full, 0) catch fail("out of memory", .{});
    }
    return null;
}

fn joinCommand(ctx: *Ctx, cmd: []const [:0]const u8) []const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (cmd, 0..) |a, i| {
        if (i != 0) list.append(ctx.arena, ' ') catch {};
        list.appendSlice(ctx.arena, a) catch {};
    }
    return list.items;
}

/// True when CPUQ_TOKEN names a lease that is still held, i.e. this run is
/// inside a running one.
fn nestedGrant(ctx: *Ctx) bool {
    const token = ctx.env.get("CPUQ_TOKEN") orelse return false;
    if (token.len == 0 or std.mem.findScalar(u8, token, '/') != null) return false;
    const path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/leases/", token }) catch return false;
    const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch return false;
    defer f.close(ctx.io);
    const free = f.tryLock(ctx.io, .shared) catch return false;
    if (free) f.unlock(ctx.io);
    return !free;
}

fn cmdRun(ctx: *Ctx, args: []const [:0]const u8) u8 {
    const o = parseRun(args) orelse return exit_usage;
    if (o.cmd.len == 0) return usageError("run needs a command", .{});
    if (o.host != null or o.hold or o.slots != 1) return usageError("--host, --hold and --slots are options of `cpuq lease`", .{});

    if (nestedGrant(ctx)) {
        // Inside a running job: run at once within its grant, everything
        // passed through untouched.
        const err = std.process.replace(ctx.io, .{ .argv = @ptrCast(o.cmd) });
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        return if (err == error.FileNotFound) exit_notfound else exit_noexec;
    }
    _ = ctx.env.swapRemove("CPUQ_TOKEN");

    loadConfig(ctx);
    const exe = findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return exit_notfound;
    };
    var st = openState(ctx);
    const lease = waitTurn(ctx, &st, o);
    return runAdmitted(ctx, &st, o, exe, lease);
}

const Lease = struct {
    record: state.Record,
    name: []const u8,
    file: Io.File,
    tokens: []Io.File,
    job: JobLog,
    /// Cores of the grant lent by holders that leave them idle: the command
    /// then runs at background priority, so a lender that gets busy again
    /// has its CPUs back at once.
    borrowed: u32 = 0,
};

/// The history's record of the job this cpuq runs: its id and the fields
/// every one of its events carries.
const JobLog = struct {
    id: []const u8,
    base: history.Event,
};

/// Unix time in seconds, with a fraction.
fn nowFloat(io: Io) f64 {
    return @as(f64, @floatFromInt(Io.Clock.real.now(io).toNanoseconds())) / 1e9;
}

/// The history file: CPUQ_HISTORY; else beside an explicit CPUQ_DIR, so a
/// separate queue keeps a separate history; else under XDG_STATE_HOME or
/// ~/.local/state, outside /tmp, so it outlives a reboot.
fn historyPath(ctx: *Ctx) []const u8 {
    if (ctx.env.get("CPUQ_HISTORY")) |p| return p;
    if (ctx.env.get("CPUQ_DIR")) |d| return std.mem.concat(ctx.arena, u8, &.{ d, "/history.jsonl" }) catch "";
    if (ctx.env.get("XDG_STATE_HOME")) |x| return std.mem.concat(ctx.arena, u8, &.{ x, "/cpuq/history.jsonl" }) catch "";
    const home = ctx.env.get("HOME") orelse return "";
    return std.mem.concat(ctx.arena, u8, &.{ home, "/.local/state/cpuq/history.jsonl" }) catch "";
}

fn newJobLog(ctx: *Ctx, o: RunOptions) JobLog {
    const pid = sys.getpid();
    const t = nowFloat(ctx.io);
    return .{
        .id = ctx.arena.print("{d}-{d}", .{ pid, @as(i64, @intFromFloat(t * 1000)) }) catch "0",
        .base = .{
            .pid = pid,
            .pool = o.lease orelse "cores",
            .host = o.host,
            .label = o.label,
            .cmd = joinCommand(ctx, o.cmd),
            .priority = @tagName(o.priority),
            .exclusive = o.exclusive,
            .min = o.request.min,
            .max = o.request.max,
        },
    };
}

const EventExtra = struct {
    cores: ?u32 = null,
    /// Started ahead of the head of the queue (backfill).
    ahead: ?bool = null,
    /// Cores of the grant lent by holders that leave them idle.
    lent: ?u32 = null,
    /// Started by hand past the queue (`cpuq start`).
    forced: ?bool = null,
    slots: ?[]const u32 = null,
    exit: ?u8 = null,
    signal: ?u32 = null,
    cpu: ?f64 = null,
};

fn logEvent(ctx: *Ctx, job: JobLog, event: []const u8, extra: EventExtra) void {
    const path = historyPath(ctx);
    if (path.len == 0) return;
    var ev = job.base;
    ev.event = event;
    ev.id = job.id;
    ev.t = nowFloat(ctx.io);
    ev.cores = extra.cores;
    ev.exit = extra.exit;
    ev.signal = extra.signal;
    ev.cpu = extra.cpu;
    ev.slots = extra.slots;
    ev.ahead = extra.ahead;
    ev.lent = extra.lent;
    ev.forced = extra.forced;
    history.append(ctx.io, path, ev);
}

/// Arms the line a fatal signal leaves in history in place of cpuq's own
/// next one: `gave_up` while it waits, `ended` once it holds. With `done`,
/// the job's work is over (a hold's stdin closed): it ended with status 0,
/// whatever signal then stops cpuq. Each event is logged before the next
/// line is armed, so no moment is left without one; a second line for the
/// same event is harmless.
fn armLastWords(ctx: *Ctx, job: JobLog, event: []const u8, cores: ?u32, done: bool) void {
    const path = historyPath(ctx);
    if (path.len == 0) return;
    var head_buf: [256]u8 = undefined;
    const head = std.mem.print(&head_buf, "{{\"v\":1,\"event\":\"{s}\",\"id\":\"{s}\",\"t\":", .{ event, job.id }) catch return;
    var tail_buf: [64]u8 = undefined;
    var tw: Io.Writer = .fixed(&tail_buf);
    tw.print(",\"pid\":{d}", .{job.base.pid}) catch return;
    if (cores) |k| tw.print(",\"cores\":{d}", .{k}) catch return;
    if (done) tw.writeAll(",\"exit\":0") catch return;
    sys.armLastWords(words_slot, path, head, tw.buffered(), !done);
}

/// Which last-words slot the job being waited for or run uses: 1 for the
/// cores of a lease taken `--exclusive`, so its two jobs each get a line.
var words_slot: u1 = 0;

/// Logs how a command ended.
fn logEnded(ctx: *Ctx, job: JobLog, cores: u32, w: sys.Waited) void {
    switch (w.exit) {
        .code => |code| logEvent(ctx, job, "ended", .{ .cores = cores, .exit = code, .cpu = w.cpu_s }),
        .signal => |sig| logEvent(ctx, job, "ended", .{ .cores = cores, .signal = @intCast(@backingInt(sig)), .cpu = w.cpu_s }),
    }
}

fn lockOrFail(st: *state.State) void {
    st.lock() catch |err| fail("admission lock: {t}", .{err});
}

/// Queues this run and returns once it holds its cores, or for a named
/// lease, one of its slots: a pool of `--slots` (1 by default), with no
/// machine gates.
fn waitTurn(ctx: *Ctx, st: *state.State, asked: RunOptions) Lease {
    const io = ctx.io;
    var cfg = ctx.cfg;
    var o = asked;
    const named = o.lease != null;
    // Run times from history, read once when right-sizing or backfill first
    // needs them.
    var run_times: ?RunTimes = null;
    // Right-sizing: a range request capped near what its label has used.
    if (!named and !o.exclusive and cfg.right_size and !o.request.fixed() and o.label.len != 0) {
        run_times = RunTimes.load(ctx, ctx.arena);
        if (run_times.?.uses.get(o.label)) |uses| {
            const sized = policy.rightSize(o.request, uses.items);
            if (sized.max < o.request.max) {
                std.debug.print("cpuq: asked for {d}-{d} cores; {s} has used about {d:.1}, so up to {d}\n", .{ o.request.min, o.request.max, o.label, history.median(uses.items), sized.max });
                o.request = sized;
            }
        }
    }
    // The CPUs' busy share is measured between polls.
    var ticks = sys.cpuTicks(io);
    const cores: u32 = if (named) o.slots else sys.totalCpus(io);
    const start = nowSeconds(io);

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
        .cmd = joinCommand(ctx, o.cmd),
    };
    var name_buf: [32]u8 = undefined;
    const ticket_name = state.ticketName(&name_buf, o.priority, rec.ticket);
    const ticket = st.createTicket(rec, ticket_name) catch |err| fail("ticket: {t}", .{err});
    st.unlock();
    const job = newJobLog(ctx, o);
    logEvent(ctx, job, "queued", .{});
    armLastWords(ctx, job, "gave_up", null, false);

    var next_note = start + cfg.note_s;
    var last_gate: policy.Gate = .open;
    var hinted = false;
    var hinted_fixed = false;
    while (true) {
        reloadConfig(ctx);
        cfg = ctx.cfg;
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
        const queue = state.scanQueue(st, a, ticket_name, rec, now, cfg.aging_s) catch |err| fail("queue: {t}", .{err});
        const pos = for (queue, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, ticket_name)) break i;
        } else fail("ticket {s} vanished from the queue", .{ticket_name});

        // A hand-given order (`cpuq first`, `start`, `cancel`).
        if (!named) if (st.takeControl(ticket_name)) |action| {
            if (std.mem.eql(u8, action, "cancel")) {
                std.debug.print("cpuq: cancelled by hand\n", .{});
                giveUp(ctx, st, ticket_name, now - start, job);
            } else if (std.mem.eql(u8, action, "first")) {
                rec.first = true;
                rewriteRecord(io, ticket, rec);
                std.debug.print("cpuq: moved to the front by hand\n", .{});
            } else if (std.mem.eql(u8, action, "start")) {
                // Past the queue, the budget and the gates, but never into an
                // exclusive run: that is a timing window.
                if ((state.scanLeases(st, a, true) catch @as([]state.Entry, &.{})).len != 0) {
                    std.debug.print("cpuq: not started by hand: an exclusive run holds the machine; still waiting\n", .{});
                } else {
                    const over: u32 = @intCast(heldCores(st, a) + o.request.max);
                    const got = state.takeTokens(st, ctx.arena, o.request, o.exclusive, over, @max(cores, over), false, 0) catch |err| fail("tokens: {t}", .{err});
                    if (got) |grant| {
                        std.debug.print("cpuq: started by hand on {d} {s}, past the queue\n", .{ grant.files.len, if (grant.files.len == 1) "core" else "cores" });
                        forced_now = true;
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

        if (pos > 0) {
            // Behind the head: start now if backfill allows (never for a
            // named lease or an exclusive run, and only through an open
            // gate), else block on the waiter just ahead until it is
            // admitted or gone.
            if (!named and !o.exclusive and cfg.backfill) {
                const budget: u32 = budgetNow(ctx, mach);
                var v = st.readValve();
                const g = policy.gate(cfg, mach, budget, if (o.load_check) &v else null, now);
                if (g == .open) if (goAhead(ctx, st, a, o, queue, pos, budget, now, &run_times)) |req| {
                    const got = state.takeTokens(st, ctx.arena, req, false, budget, @max(cores, budget), false, 0) catch |err| fail("tokens: {t}", .{err});
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
                // The first few waiters look again every 2 seconds; the rest
                // keep sleeping on the one ahead, so a long queue costs little.
                if (pos < 8) wake_ms = @min(wake_ms, 2000);
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
        last_gate = if (named) .open else policy.gate(cfg, mach, budget, if (o.load_check) &valve else null, now);
        const check_load = !named and o.load_check and cfg.load_check;
        if (check_load) st.writeValve(valve);
        if (last_gate == .open) {
            const exclusive_running = (state.scanLeases(st, a, true) catch @as([]state.Entry, &.{})).len != 0;
            // Leave the next waiter's minimum free when this grant can spare it.
            const reserve: u32 = if (queue.len > 1 and !queue[1].record.exclusive) @min(queue[1].record.cores, budget) else 0;
            const held_before = heldCores(st, a);
            var got = state.takeTokens(st, ctx.arena, o.request, o.exclusive, budget, @max(cores, budget), exclusive_running, reserve) catch |err| fail("tokens: {t}", .{err});
            // Not enough free: borrow the cores the holders have left idle for
            // a minute, on top of the budget. Only idle cores are lent, so the
            // work running stays within the budget; should a lender get busy
            // again, the load valve holds further admissions. Measuring takes a
            // process snapshot, so only a head that cannot start does it.
            if (got == null and !named and !o.exclusive and cfg.lend) {
                // Only into CPUs the machine really has to spare: by the load,
                // and by the measured busy share when there is one (the load
                // checks, so not with load_check off or --no-load-check).
                const cpus = sys.activeCpus();
                var room: u32 = std.math.maxInt(u32);
                if (cfg.load_check and o.load_check) {
                    room = policy.lendRoom(mach.load1, cpus);
                    if (mach.busy) |b| room = @min(room, @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(cpus)) * (1 - b)))));
                }
                const lent = @min(measureIdle(ctx, st, a), room);
                if (lent > 0) got = state.takeTokens(st, ctx.arena, o.request, o.exclusive, budget + lent, @max(cores, budget) + lent, exclusive_running, reserve) catch |err| fail("tokens: {t}", .{err});
            }
            if (got) |grant| {
                valve.last_admit = now;
                if (check_load) st.writeValve(valve);
                const borrowed: u32 = @intCast(@min(grant.files.len, (held_before + grant.files.len) -| budget));
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
    lent_now = lent;
    var lease = admitted(ctx, st, o, rec, grant, ticket, ticket_name, job, now, false);
    lease.borrowed = lent;
    return lease;
}

/// The cores the grant being logged borrowed (read by `admitted`).
var lent_now: u32 = 0;
/// Whether the grant being logged was given by hand (read by `admitted`).
var forced_now = false;

/// Takes the grant: writes the lease, leaves the queue, and logs the start.
/// Call with the admission lock held; returns with it released.
fn admitted(ctx: *Ctx, st: *state.State, o: RunOptions, rec: *state.Record, grant: state.Grant, ticket: Io.File, ticket_name: []const u8, job: JobLog, now: i64, ahead: bool) Lease {
    const io = ctx.io;
    rec.cores = @intCast(grant.files.len);
    rec.slots = grant.slotText(ctx.arena);
    rec.since = now;
    // The lease is named by the ticket number; should a live job hold that
    // name anyway, take a fresh number rather than wait.
    var lease_name: []const u8 = undefined;
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
    logEvent(ctx, job, "started", .{ .cores = rec.cores, .slots = grant.slots, .ahead = if (ahead) true else null, .lent = if (lent_now > 0) lent_now else null, .forced = if (forced_now) true else null });
    armLastWords(ctx, job, "ended", rec.cores, false);
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
    // An exclusive head waits for the machine to drain: nobody goes ahead.
    if (head.exclusive) return null;
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
        fn of(t: RunTimes, label: []const u8, eta: ?f64, waited: f64, typical: ?f64, least: u32) bool {
            return policy.backfill(t.typical(label), eta, waited, typical, least);
        }
    };
    for (queue[1..pos]) |e| {
        if (e.record.exclusive or fits.need(e.record, budget) > free) continue;
        if (rule.of(times, e.record.label, ahead[0].eta, head_waited, head_typical, ctx.cfg.patience_s)) return null;
    }
    const min = fits.need(.{ .cores = o.request.min }, budget);
    if (!rule.of(times, o.label, ahead[0].eta, head_waited, head_typical, ctx.cfg.patience_s)) return null;
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
    var fut = io.concurrent(watch, .{ io, f, &sem }) catch {
        io.sleep(.fromMilliseconds(@min(ms, 1000)), .awake) catch {};
        return;
    };
    sem.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }) catch {};
    fut.cancel(io) catch {};
}

fn className(class: u2) []const u8 {
    return switch (class) {
        0 => "high",
        1 => "normal",
        else => "low",
    };
}

fn ordinal(buf: []u8, n: usize) []const u8 {
    const suffix = if (n % 100 >= 11 and n % 100 <= 13) "th" else switch (n % 10) {
        1 => "st",
        2 => "nd",
        3 => "rd",
        else => "th",
    };
    return std.mem.print(buf, "{d}{s}", .{ n, suffix }) catch "?";
}

/// A duration: tenths of a second under 10 s, else as `age` puts it.
fn duration(buf: []u8, seconds: f64) []const u8 {
    if (seconds < 10) return std.mem.print(buf, "{d:.1}s", .{@max(seconds, 0)}) catch "?";
    return age(buf, @intFromFloat(seconds));
}

fn age(buf: []u8, seconds: i64) []const u8 {
    const s = @max(seconds, 0);
    if (s < 60) return std.mem.print(buf, "{d}s", .{s}) catch "?";
    if (s < 3600) return std.mem.print(buf, "{d}m{d:0>2}s", .{ @divTrunc(s, 60), @mod(s, 60) }) catch "?";
    return std.mem.print(buf, "{d}h{d:0>2}m", .{ @divTrunc(s, 3600), @divTrunc(@mod(s, 3600), 60) }) catch "?";
}

fn gateText(buf: []u8, g: policy.Gate, budget: u32) []const u8 {
    return switch (g) {
        .open => "open",
        .pressure => "closed: memory pressure",
        .load => |l| std.mem.print(buf, "closed: load {d:.1} (valve tripped; budget {d})", .{ l, budget }) catch "closed: load",
        .spacing => |l| std.mem.print(buf, "spacing admissions: load {d:.1} over budget {d}", .{ l, budget }) catch "spacing",
    };
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

/// Writes a lease's record over the old one, from the start. A record has no
/// size limit (a command can be a long inline script), so it goes through a
/// positional writer rather than a fixed buffer, which once dropped records
/// over 1 KB and left their child pid unknown.
fn rewriteRecord(io: Io, f: Io.File, r: state.Record) void {
    f.setLength(io, 0) catch return;
    var buf: [1024]u8 = undefined;
    var fw = f.writer(io, &buf);
    r.write(&fw.interface) catch return;
    fw.interface.flush() catch {};
}

fn runAdmitted(ctx: *Ctx, st: *state.State, o: RunOptions, exe: [:0]const u8, lease_in: Lease) u8 {
    const io = ctx.io;
    var lease = lease_in;
    const k = lease.record.cores;

    // The command and its descendants share the token and lease locks, so a
    // SIGKILLed cpuq does not hand the cores on while the command runs.
    for (lease.tokens) |t| sys.inherit(t.handle);
    sys.inherit(lease.file.handle);

    // A lease adds itself to CPUQ_LEASES and leaves the cores, the
    // jobserver and the scheduling class as they are.
    var pipe: [2]std.c.fd_t = .{ -1, -1 };
    if (o.lease) |name| {
        addLeaseEnv(ctx, name, lease.name);
        // Holding the machine's cores too (`--exclusive`): the command's own
        // `cpuq run`s start at once inside them, as nested runs.
        if (exclusive_cores) |x| {
            for (x.lease.tokens) |t| sys.inherit(t.handle);
            sys.inherit(x.lease.file.handle);
            var num: [16]u8 = undefined;
            ctx.env.put("CPUQ_CORES", std.mem.print(&num, "{d}", .{x.lease.record.cores}) catch "1") catch fail("out of memory", .{});
            ctx.env.put("CPUQ_TOKEN", x.lease.name) catch fail("out of memory", .{});
        }
    } else {
        var num: [16]u8 = undefined;
        ctx.env.put("CPUQ_CORES", std.mem.print(&num, "{d}", .{k}) catch "1") catch fail("out of memory", .{});
        ctx.env.put("CPUQ_TOKEN", lease.name) catch fail("out of memory", .{});
        pipe = sys.jobserverPipe(k - 1) catch |err| fail("jobserver: {t}", .{err});
        const flags = policy.makeflags(ctx.arena, ctx.env.get("MAKEFLAGS"), pipe[0], pipe[1]) catch fail("out of memory", .{});
        ctx.env.put("MAKEFLAGS", flags) catch fail("out of memory", .{});
    }
    const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch fail("out of memory", .{});

    const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch fail("out of memory", .{});
    for (o.cmd, 0..) |a, i| argv[i] = a.ptr;

    sys.installForwarding();
    const qos_enabled = ctx.cfg.qos and o.qos and o.lease == null;
    const qos: policy.Qos = if (lease.borrowed > 0 and qos_enabled) .background else policy.qosFor(o.priority, o.exclusive, qos_enabled);
    const spawned = sys.spawn(exe, argv.ptr, @ptrCast(envp.slice.ptr), qos);
    if (pipe[0] >= 0) sys.closeFd(pipe[0]);
    if (pipe[1] >= 0) sys.closeFd(pipe[1]);
    const waited: sys.Waited = if (spawned) |pid| blk: {
        sys.setChild(pid);
        lease.record.child = pid;
        rewriteRecord(io, lease.file, lease.record);
        if (exclusive_cores) |*x| {
            x.lease.record.child = pid;
            rewriteRecord(io, x.lease.file, x.lease.record);
        }
        break :blk sys.waitChild(pid);
    } else |err| blk: {
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        break :blk .{ .exit = .{ .code = if (err == error.FileNotFound) exit_notfound else exit_noexec } };
    };

    releaseExclusiveCores(ctx, waited);
    release(io, st, lease);
    logEnded(ctx, lease.job, k, waited);
    ctx.out.flush() catch {};
    switch (waited.exit) {
        .code => |c| return c,
        .signal => |sig| sys.dieBySignal(sig),
    }
}

/// Gives a lease back. LOCK_UN releases each lock for every holder of the
/// open file, so a descendant that kept a descriptor (a build server, a
/// nohup'd helper) does not keep the cores. It all happens under the
/// admission lock, so no waiter sees a lease half given back: some of its
/// cores free while the lease still counts them.
fn release(io: Io, st: *state.State, lease: Lease) void {
    lockOrFail(st);
    for (lease.tokens) |t| {
        t.unlock(io);
        t.close(io);
    }
    lease.file.unlock(io);
    lease.file.close(io);
    st.leases.deleteFile(io, lease.name) catch {};
    st.setPaused(lease.name, false);
    st.unlock();
}

/// A lease name: letters, digits, `.`, `_` and `-`.
fn validLeaseName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64 or name[0] == '.' or name[0] == '-') return false;
    for (name) |ch| switch (ch) {
        'a'...'z', 'A'...'Z', '0'...'9', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

/// The state of the named lease NAME: a pool of one in the state directory.
fn openNamed(ctx: *Ctx, name: []const u8) state.State {
    const dir = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/named/", name }) catch fail("out of memory", .{});
    return state.State.open(ctx.io, dir) catch |err| fail("state directory {s}: {t}", .{ dir, err });
}

/// Adds an entry to CPUQ_LEASES, the leases a command runs inside: `NAME=ID`
/// for a lease held on this machine, `NAME@HOST=ID:PID` for one held on
/// HOST by the local cpuq PID.
fn addLeaseEnv(ctx: *Ctx, name: []const u8, id: []const u8) void {
    const old = ctx.env.get("CPUQ_LEASES") orelse "";
    const entry = ctx.arena.print("{s}{s}{s}={s}", .{ old, if (old.len == 0) "" else " ", name, id }) catch fail("out of memory", .{});
    ctx.env.put("CPUQ_LEASES", entry) catch fail("out of memory", .{});
}

/// True when this run is inside a holder of the lease NAME (on HOST, for
/// `--host`), so it must not queue behind itself. A local entry counts
/// while its lease file is still held here, which also covers an entry
/// passed through ssh to the host that holds it; a remote entry counts
/// while the local cpuq holding it lives.
fn nestedLease(ctx: *Ctx, name: []const u8, host: ?[]const u8) bool {
    const leases = ctx.env.get("CPUQ_LEASES") orelse return false;
    var entries = std.mem.tokenizeScalar(u8, leases, ' ');
    while (entries.next()) |entry| {
        const key, const val = std.mem.cutScalar(u8, entry, '=') orelse continue;
        const entry_name, const entry_host = std.mem.cutScalar(u8, key, '@') orelse .{ key, "" };
        if (!std.mem.eql(u8, entry_name, name)) continue;
        const id, const pid_text = std.mem.cutScalar(u8, val, ':') orelse .{ val, "" };
        if (host) |h| {
            if (std.mem.eql(u8, entry_host, h)) {
                const pid = std.fmt.parseInt(i32, pid_text, 10) catch continue;
                if (sys.processAlive(pid)) return true;
            }
            continue;
        }
        if (id.len == 0 or std.mem.findScalar(u8, id, '/') != null) continue;
        const path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/named/", name, "/leases/", id }) catch continue;
        const f = Io.Dir.cwd().openFile(ctx.io, path, .{}) catch continue;
        defer f.close(ctx.io);
        const free = f.tryLock(ctx.io, .shared) catch continue;
        if (free) f.unlock(ctx.io) else return true;
    }
    return false;
}

fn cmdLease(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (args.len == 0 or args[0].len == 0 or args[0][0] == '-') return usageError("lease needs a name", .{});
    const name = args[0];
    if (!validLeaseName(name)) return usageError("a lease name is letters, digits, '.', '_' and '-', not '{s}'", .{name});
    var o = parseRun(args[1..]) orelse return exit_usage;
    o.lease = name;
    o.request = .{ .min = 1, .max = 1 };
    if (o.run_only) |r| return usageError("{s} is an option of `cpuq run`, not `cpuq lease`", .{r});
    if (o.hold) {
        if (o.cmd.len != 0) return usageError("--hold takes no command", .{});
    } else if (o.cmd.len == 0) return usageError("lease needs a command", .{});
    if (o.host) |h| if (h.len == 0 or h[0] == '-') return usageError("--host needs a host name", .{});

    // `--hold --host` inside a hold of the same lease: say so, hold nothing.
    if (o.hold) if (o.host) |host| if (heldEntry(ctx, name, host)) |entry| {
        ctx.out.print("held {s}@{s} {s}\n", .{ name, host, entry }) catch {};
        ctx.out.flush() catch {};
        untilStdinCloses();
        return 0;
    };

    if (!o.hold and nestedLease(ctx, name, o.host)) {
        const err = std.process.replace(ctx.io, .{ .argv = @ptrCast(o.cmd) });
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        return if (err == error.FileNotFound) exit_notfound else exit_noexec;
    }
    loadConfig(ctx);
    if (o.host) |host| return runRemote(ctx, o, host);
    const exe: [:0]const u8 = if (o.hold) "" else findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return exit_notfound;
    };
    var st = openNamed(ctx, name);
    var named = o;
    named.exclusive = false;
    const lease = waitTurn(ctx, &st, named);
    // `--exclusive`: the machine's cores too, once running work drains, held
    // with the lease, so nothing else runs while it is held: a timing window.
    // The lease comes first, so two holders never wait on each other.
    var cst: state.State = undefined;
    if (o.exclusive) {
        cst = openState(ctx);
        var co = o;
        co.lease = null;
        co.hold = false;
        co.slots = 1;
        co.request = .{ .min = 1, .max = 1 };
        words_slot = 1;
        exclusive_cores = .{ .st = &cst, .lease = waitTurn(ctx, &cst, co) };
        words_slot = 0;
    }
    if (o.hold) return holdAdmitted(ctx, &st, o, lease);
    return runAdmitted(ctx, &st, o, exe, lease);
}

/// The machine's cores held with a lease taken `--exclusive`, given back with it.
var exclusive_cores: ?struct { st: *state.State, lease: Lease } = null;

/// Gives back the cores held with an `--exclusive` lease, if any, and logs
/// their end as the lease's own: `done` when the lease ended normally.
fn releaseExclusiveCores(ctx: *Ctx, ended: ?sys.Waited) void {
    const x = exclusive_cores orelse return;
    exclusive_cores = null;
    release(ctx.io, x.st, x.lease);
    if (ended) |w| logEnded(ctx, x.lease.job, x.lease.record.cores, w) else logEvent(ctx, x.lease.job, "ended", .{ .cores = x.lease.record.cores, .exit = 0 });
}

/// Blocks until stdin reaches its end: the holder of a `--hold` closed it,
/// or died.
fn untilStdinCloses() void {
    var buf: [256]u8 = undefined;
    while (true) {
        const n = std.c.read(0, &buf, buf.len);
        if (n > 0) continue;
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        break;
    }
}

/// The CPUQ_LEASES entry by which this run already holds NAME on HOST
/// (`NAME@HOST=ID:PID`, its cpuq alive), if it does.
fn heldEntry(ctx: *Ctx, name: []const u8, host: []const u8) ?[]const u8 {
    const leases = ctx.env.get("CPUQ_LEASES") orelse return null;
    var entries = std.mem.tokenizeScalar(u8, leases, ' ');
    while (entries.next()) |entry| {
        const key, const val = std.mem.cutScalar(u8, entry, '=') orelse continue;
        const entry_name, const entry_host = std.mem.cutScalar(u8, key, '@') orelse continue;
        if (!std.mem.eql(u8, entry_name, name) or !std.mem.eql(u8, entry_host, host)) continue;
        _, const pid_text = std.mem.cutScalar(u8, val, ':') orelse continue;
        const pid = std.fmt.parseInt(i32, pid_text, 10) catch continue;
        if (sys.processAlive(pid)) return entry;
    }
    return null;
}

/// The far end of `cpuq lease --host`: once admitted, prints `held NAME ID`
/// and holds the lease until stdin closes. If the connection dies instead,
/// this process dies with it and the kernel frees the lease.
fn holdAdmitted(ctx: *Ctx, st: *state.State, o: RunOptions, lease: Lease) u8 {
    ctx.out.print("held {s} {s}\n", .{ o.lease.?, lease.name }) catch {};
    ctx.out.flush() catch {};
    untilStdinCloses();
    armLastWords(ctx, lease.job, "ended", lease.record.cores, true);
    if (exclusive_cores) |x| {
        words_slot = 1;
        armLastWords(ctx, x.lease.job, "ended", x.lease.record.cores, true);
        words_slot = 0;
    }
    releaseExclusiveCores(ctx, null);
    release(ctx.io, st, lease);
    logEvent(ctx, lease.job, "ended", .{ .cores = lease.record.cores, .exit = 0 });
    return 0;
}

/// `cpuq lease NAME --host HOST -- CMD`: holds NAME on HOST's cpuq through
/// `ssh HOST cpuq lease NAME --hold` and runs CMD here meanwhile. Closing
/// the connection gives the lease back, and so does the connection dying.
///
/// With `--hold` and no command, it holds the lease for a script instead:
/// once granted it prints `held NAME@HOST ENTRY`, ENTRY being the
/// CPUQ_LEASES entry (`NAME@HOST=ID:PID`) that makes runs inside see the
/// lease as theirs, and holds it until its stdin closes or it dies.
fn runRemote(ctx: *Ctx, o: RunOptions, host: []const u8) u8 {
    const io = ctx.io;
    const a = ctx.arena;
    const exe: [:0]const u8 = if (o.hold) "" else findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return exit_notfound;
    };
    // ssh joins its arguments into one command line for the remote shell,
    // so everything after the host is quoted for it.
    var remote: std.ArrayList(u8) = .empty;
    remote.print(a, "cpuq lease {s} --hold --slots {d} --priority {t}", .{ o.lease.?, o.slots, o.priority }) catch fail("out of memory", .{});
    if (o.exclusive) remote.appendSlice(a, " --exclusive") catch fail("out of memory", .{});
    if (o.label.len != 0) remote.print(a, " --label {s}", .{shellQuote(a, o.label)}) catch fail("out of memory", .{});
    if (o.max_wait) |mw| remote.print(a, " --max-wait {d}", .{mw}) catch fail("out of memory", .{});
    const argv = [_][]const u8{ "ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", host, remote.items };
    const job = newJobLog(ctx, o);
    logEvent(ctx, job, "queued", .{});
    armLastWords(ctx, job, "gave_up", null, false);
    var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) catch |err|
        fail("ssh {s}: {t}", .{ host, err });

    // The held line: `held NAME ID`.
    var rbuf: [256]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &rbuf);
    const line = r.interface.takeDelimiterExclusive('\n') catch "";
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const word = words.next() orelse "";
    _ = words.next();
    const id = words.next() orelse "";
    if (!std.mem.eql(u8, word, "held") or id.len == 0) {
        if (child.stdin) |f| f.close(io);
        child.stdin = null;
        const term = child.wait(io) catch std.process.Child.Term{ .unknown = 0 };
        const code: u8 = switch (term) {
            .exited => |c| if (c == 0) exit_failure else c,
            else => exit_failure,
        };
        if (code == exit_timeout) {
            logEvent(ctx, job, "gave_up", .{});
        } else {
            std.debug.print("cpuq: could not hold lease {s} on {s} (ssh exit {d})\n", .{ o.lease.?, host, code });
            logEvent(ctx, job, "ended", .{ .exit = code });
        }
        return code;
    }

    logEvent(ctx, job, "started", .{ .cores = 1 });
    armLastWords(ctx, job, "ended", 1, false);
    var pid_buf: [16]u8 = undefined;
    const val = std.mem.concat(a, u8, &.{ id, ":", std.mem.print(&pid_buf, "{d}", .{sys.getpid()}) catch "0" }) catch fail("out of memory", .{});
    if (o.hold) {
        ctx.out.print("held {s}@{s} {s}@{s}={s}\n", .{ o.lease.?, host, o.lease.?, host, val }) catch {};
        ctx.out.flush() catch {};
        // Killed while it holds, it still ends the job in history; ssh,
        // its stdin gone with it, ends the remote hold. Once stdin closes
        // the hold is over, and a kill that follows at once (the kit's
        // release does) still records it as ended normally.
        untilStdinCloses();
        armLastWords(ctx, job, "ended", 1, true);
        if (child.stdin) |f| f.close(io);
        child.stdin = null;
        _ = child.wait(io) catch {};
        logEvent(ctx, job, "ended", .{ .cores = 1, .exit = 0 });
        return 0;
    }
    addLeaseEnv(ctx, std.mem.concat(a, u8, &.{ o.lease.?, "@", host }) catch fail("out of memory", .{}), val);
    const envp = ctx.env.createPosixBlock(a, .{}) catch fail("out of memory", .{});
    const cargv = a.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch fail("out of memory", .{});
    for (o.cmd, 0..) |arg, i| cargv[i] = arg.ptr;

    sys.installForwarding();
    const waited: sys.Waited = if (sys.spawn(exe, cargv.ptr, @ptrCast(envp.slice.ptr), .unchanged)) |pid| blk: {
        sys.setChild(pid);
        break :blk sys.waitChild(pid);
    } else |err| blk: {
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        break :blk .{ .exit = .{ .code = if (err == error.FileNotFound) exit_notfound else exit_noexec } };
    };
    // Closing ssh's stdin ends the remote hold.
    if (child.stdin) |f| f.close(io);
    child.stdin = null;
    _ = child.wait(io) catch {};
    logEnded(ctx, job, 1, waited);
    ctx.out.flush() catch {};
    switch (waited.exit) {
        .code => |c| return c,
        .signal => |sig| sys.dieBySignal(sig),
    }
}

/// `s` in single quotes for a POSIX shell.
fn shellQuote(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '\'') catch fail("out of memory", .{});
    for (s) |ch| {
        if (ch == '\'') out.appendSlice(a, "'\\''") catch fail("out of memory", .{}) else out.append(a, ch) catch fail("out of memory", .{});
    }
    out.append(a, '\'') catch fail("out of memory", .{});
    return out.items;
}

/// True when a label matches a `cpuq wait --label` pattern: exactly, or by
/// prefix when the pattern ends in `*`.
fn labelMatches(pattern: []const u8, label: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) return std.mem.startsWith(u8, label, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, label);
}

/// The names of the named leases in the state directory.
fn namedLeases(ctx: *Ctx, a: std.mem.Allocator) []const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    const path = std.mem.concat(a, u8, &.{ stateDir(ctx), "/named" }) catch return &.{};
    var dir = Io.Dir.cwd().openDir(ctx.io, path, .{ .iterate = true }) catch return &.{};
    defer dir.close(ctx.io);
    var it = dir.iterate();
    while (it.next(ctx.io) catch null) |e| {
        if (e.kind != .directory or !validLeaseName(e.name)) continue;
        names.append(a, a.dupe(u8, e.name) catch continue) catch continue;
    }
    std.mem.sortUnstable([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.less);
    return names.items;
}

/// `cpuq wait --label PATTERN [--max-wait S]`: blocks until no job whose
/// label matches holds cores or a lease, or waits for either.
/// `cpuq first|start|cancel|pause|resume|stop TARGET [--all]`: a hand at the
/// queue. TARGET is a label (`PATTERN*` for a prefix) or a cpuq pid. first,
/// start and cancel act on waiters: each leaves an order its waiter takes at
/// its next look (the head looks every `poll`, the next waiters every 2
/// seconds). pause, resume and stop act on running jobs: SIGSTOP or SIGCONT
/// to the command's whole process tree, or SIGTERM to its cpuq, which passes
/// it on. A paused job's cores count as idle, so they are lent at once.
/// Nothing touches an exclusive run. Several matches need --all.
fn cmdControl(ctx: *Ctx, comptime action: []const u8, args: []const [:0]const u8) u8 {
    var target: ?[]const u8 = null;
    var all = false;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--all")) all = true else if (target == null) target = arg else return usageError("{s} takes one label or pid", .{action});
    }
    const t = target orelse return usageError("{s} needs a label (PATTERN* for a prefix) or a cpuq pid", .{action});
    const pid: ?i32 = std.fmt.parseInt(i32, t, 10) catch null;
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var st = openState(ctx);
    lockOrFail(&st);
    defer st.unlock();
    const for_waiters = comptime (std.mem.eql(u8, action, "first") or std.mem.eql(u8, action, "start") or std.mem.eql(u8, action, "cancel"));
    const entries = if (for_waiters)
        state.scanQueue(&st, a, null, .{}, nowSeconds(ctx.io), ctx.cfg.aging_s) catch @as([]state.Entry, &.{})
    else
        state.scanLeases(&st, a, false) catch @as([]state.Entry, &.{});
    var hits: std.ArrayList(state.Entry) = .empty;
    for (entries) |e| {
        const matched = if (pid) |p| e.record.pid == p else labelMatches(t, e.record.label);
        if (matched) hits.append(a, e) catch {};
    }
    if (hits.items.len == 0) {
        std.debug.print("cpuq: no {s} job matches '{s}'\n", .{ if (for_waiters) "waiting" else "running", t });
        return exit_failure;
    }
    if (hits.items.len > 1 and !all) {
        std.debug.print("cpuq: '{s}' matches {d} jobs; name one, or add --all:\n", .{ t, hits.items.len });
        for (hits.items) |e| std.debug.print("  {d}  {s}\n", .{ e.record.pid, e.record.label });
        return exit_usage;
    }
    const procs = if (for_waiters) &[_]sys.Proc{} else sys.processes(ctx.io, a);
    for (hits.items) |e| {
        const r = e.record;
        const who = if (r.label.len != 0) r.label else r.cmd;
        if (for_waiters) {
            st.giveControl(e.name, action);
            ctx.out.print("{s}: {s} (pid {d})\n", .{ action, who, r.pid }) catch {};
            continue;
        }
        if (r.exclusive) {
            std.debug.print("cpuq: {s} is an exclusive run, a timing window; left alone\n", .{who});
            continue;
        }
        if (r.child > 0) {
            // The command's whole process tree, not just its first process: a
            // shell's children would otherwise run on, or be left orphaned.
            const in_tree = a.alloc(bool, procs.len) catch continue;
            @memset(in_tree, false);
            sys.markTree(procs, r.child, in_tree);
            const stop = comptime std.mem.eql(u8, action, "stop");
            for (procs, in_tree) |p, mine| if (mine) {
                if (stop) {
                    // A paused process acts on SIGTERM only once continued.
                    _ = std.c.kill(p.pid, .TERM);
                    _ = std.c.kill(p.pid, .CONT);
                } else _ = std.c.kill(p.pid, if (comptime std.mem.eql(u8, action, "pause")) .STOP else .CONT);
            };
            st.setPaused(e.name, comptime std.mem.eql(u8, action, "pause"));
        } else if (comptime std.mem.eql(u8, action, "stop")) {
            _ = std.c.kill(r.pid, .TERM);
        }
        ctx.out.print("{s}: {s} (pid {d})\n", .{ action, who, r.pid }) catch {};
    }
    ctx.out.flush() catch {};
    return 0;
}

fn cmdWait(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var pattern: ?[]const u8 = null;
    var max_wait: ?i64 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const name, const inline_value = std.mem.cutScalar(u8, arg, '=') orelse .{ arg, null };
        const is_label = std.mem.eql(u8, name, "--label");
        const is_wait = std.mem.eql(u8, name, "--max-wait");
        if (!is_label and !is_wait) return usageError("unknown wait option '{s}'", .{arg});
        const value = inline_value orelse blk: {
            i += 1;
            if (i >= args.len) return usageError("{s} needs a value", .{name});
            break :blk args[i];
        };
        if (is_label) pattern = value else max_wait = std.fmt.parseInt(i64, value, 10) catch
            return usageError("--max-wait needs whole seconds, not '{s}'", .{value});
    }
    const pat = pattern orelse return usageError("wait needs --label PATTERN", .{});
    const io = ctx.io;
    const start = nowSeconds(io);
    while (true) {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();
        var found = false;
        var pools: std.ArrayList(state.State) = .empty;
        pools.append(a, openState(ctx)) catch {};
        for (namedLeases(ctx, a)) |n| pools.append(a, openNamed(ctx, n)) catch {};
        const now = nowSeconds(io);
        for (pools.items) |*st| {
            lockOrFail(st);
            const leases = state.scanLeases(st, a, false) catch @as([]state.Entry, &.{});
            const queue = state.scanQueue(st, a, null, .{}, now, ctx.cfg.aging_s) catch @as([]state.Entry, &.{});
            st.unlock();
            for (leases) |e| found = found or labelMatches(pat, e.record.label);
            for (queue) |e| found = found or labelMatches(pat, e.record.label);
        }
        if (!found) return 0;
        if (max_wait) |mw| if (now - start >= mw) {
            std.debug.print("cpuq: gave up after waiting {d}s for '{s}'\n", .{ now - start, pat });
            return exit_timeout;
        };
        io.sleep(.fromMilliseconds(1000), .awake) catch {};
    }
}

const JsonJob = struct {
    id: []const u8,
    state: []const u8,
    pool: []const u8,
    host: ?[]const u8,
    label: []const u8,
    command: []const u8,
    priority: []const u8,
    exclusive: bool,
    min: u32,
    max: u32,
    cores: ?u32,
    slots: ?[]const u32,
    queued: f64,
    started: ?f64,
    ended: ?f64,
    waited: ?f64,
    ran: ?f64,
    used: ?f64,
    exit: ?u8,
    signal: ?u32,
};

fn aliveForHistory(pid: i32) bool {
    return sys.processAlive(pid);
}

/// `cpuq history [--label PATTERN] [--limit N] [--json]`: finished, lost and
/// running jobs from the history file, newest first, with a summary.
fn cmdHistory(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var pattern: ?[]const u8 = null;
    var limit: usize = 20;
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        const name, const inline_value = std.mem.cutScalar(u8, arg, '=') orelse .{ arg, null };
        const is_label = std.mem.eql(u8, name, "--label");
        const is_limit = std.mem.eql(u8, name, "--limit");
        if (!is_label and !is_limit) return usageError("unknown history option '{s}'", .{arg});
        const value = inline_value orelse blk: {
            i += 1;
            if (i >= args.len) return usageError("{s} needs a value", .{name});
            break :blk args[i];
        };
        if (is_label) pattern = value else limit = std.fmt.parseInt(usize, value, 10) catch
            return usageError("--limit needs a whole number, not '{s}'", .{value});
    }
    const io = ctx.io;
    const a = ctx.arena;
    const path = historyPath(ctx);
    const all = history.load(io, a, path, sys.bootTime(io), &aliveForHistory);

    // Newest first, filtered, limited.
    var picked: std.ArrayList(history.Job) = .empty;
    var k = all.len;
    while (k > 0 and picked.items.len < limit) {
        k -= 1;
        const j = all[k];
        if (pattern) |p| if (!history.labelMatches(p, j.label)) continue;
        picked.append(a, j) catch break;
    }
    std.mem.sortUnstable(history.Job, picked.items, {}, struct {
        fn newer(_: void, x: history.Job, y: history.Job) bool {
            return x.last() > y.last();
        }
    }.newer);

    const w = ctx.out;
    if (json) {
        var out: std.ArrayList(JsonJob) = .empty;
        for (picked.items) |j| out.append(a, .{
            .id = j.id,
            .state = @tagName(j.state),
            .pool = j.pool,
            .host = j.host,
            .label = j.label,
            .command = j.cmd,
            .priority = j.priority,
            .exclusive = j.exclusive,
            .min = j.min,
            .max = j.max,
            .cores = j.cores,
            .slots = j.slots,
            .queued = j.queued,
            .started = j.started,
            .ended = j.ended,
            .waited = j.waited(),
            .ran = j.ran(),
            .used = j.used(),
            .exit = j.exit,
            .signal = j.signal,
        }) catch {};
        std.json.Stringify.value(out.items, .{ .whitespace = .indent_2 }, w) catch {};
        w.writeAll("\n") catch {};
        return 0;
    }
    if (picked.items.len == 0) {
        w.print("no jobs in {s}{s}\n", .{ path, if (pattern != null) " with that label" else "" }) catch {};
        return 0;
    }

    const now = nowFloat(io);
    const boxed = std.c.isatty(1) != 0;
    const color = boxed and ctx.env.get("NO_COLOR") == null;
    var trows: std.ArrayList([]const table.Cell) = .empty;
    var lw: usize = 5;
    var pw: usize = 4;
    for (picked.items) |j| {
        lw = @max(lw, @min(dash(j.label).len, 32));
        pw = @max(pw, @min(j.pool.len, 20));
    }
    var lbuf: [40]u8 = undefined;
    var pbuf: [24]u8 = undefined;
    if (!boxed) w.print("  WHEN     {s} {s} IN USE WAITED   RAN      ACTIVE EXIT\n", .{ pad(&lbuf, "LABEL", lw), pad(&pbuf, "POOL", pw) }) catch {};
    for (picked.items) |j| {
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        var b3: [16]u8 = undefined;
        var b4: [16]u8 = undefined;
        var b5: [16]u8 = undefined;
        var b6: [24]u8 = undefined;
        const cores_text = if (j.cores) |c| std.mem.print(&b2, "{d}", .{c}) catch "?" else if (j.max > j.min) std.mem.print(&b2, "{d}-{d}", .{ j.min, j.max }) catch "?" else "-";
        const waited_text = if (j.waited()) |x| duration(&b3, x) else "-";
        const ran_text = if (j.ran()) |x| duration(&b4, x) else "-";
        const used_text = if (j.used()) |x| std.mem.print(&b5, "{d:.1}", .{x}) catch "?" else "-";
        const exit_text: []const u8 = switch (j.state) {
            .done => if (j.signal) |sig| std.mem.print(&b6, "signal {d}", .{sig}) catch "signal" else std.mem.print(&b6, "{d}", .{j.exit orelse 0}) catch "?",
            .gave_up => "gave up",
            .lost => "lost",
            .active => if (j.started != null) "running" else "waiting",
        };
        if (boxed) {
            const exit_tint: table.Tint = switch (j.state) {
                .done => if (j.signal == null and (j.exit orelse 0) == 0) .good else .bad,
                .gave_up => .warn,
                .lost => .bad,
                .active => .accent,
            };
            const used_tint: ?table.Tint = if (j.used()) |u| (if (j.cores) |c| (if (c >= 2 and u * 2 < @as(f64, @floatFromInt(c))) table.Tint.warn else null) else null) else .dim;
            trows.append(a, a.dupe(table.Cell, &.{
                .{ .text = a.dupe(u8, age(&b1, @intFromFloat(now - j.last()))) catch "?", .tint = .dim },
                .{ .text = dash(j.label), .tint = .accent },
                .{ .text = j.pool },
                .{ .text = a.dupe(u8, cores_text) catch "?" },
                .{ .text = a.dupe(u8, waited_text) catch "?" },
                .{ .text = a.dupe(u8, ran_text) catch "?" },
                .{ .text = a.dupe(u8, used_text) catch "?", .tint = used_tint },
                .{ .text = a.dupe(u8, exit_text) catch "?", .tint = exit_tint },
            }) catch continue) catch {};
            continue;
        }
        w.print("  {s:<8} {s} {s} {s:<6} {s:<8} {s:<8} {s:<6} {s}\n", .{
            age(&b1, @intFromFloat(now - j.last())), pad(&lbuf, dash(j.label), lw), pad(&pbuf, j.pool, pw),
            cores_text,                              waited_text,                   ran_text,
            used_text,                               exit_text,
        }) catch {};
    }

    // The summary: how long jobs waited, and what they used of what they got.
    var waits: std.ArrayList(f64) = .empty;
    var granted: f64 = 0;
    var used: f64 = 0;
    var measured: usize = 0;
    var lost: usize = 0;
    for (picked.items) |j| {
        if (j.waited()) |x| waits.append(a, x) catch {};
        if (j.state == .lost) lost += 1;
        if (j.used()) |u| if (j.cores) |c| if (std.mem.eql(u8, j.pool, "cores")) {
            used += u;
            granted += @floatFromInt(c);
            measured += 1;
        };
    }
    var longest: f64 = 0;
    for (waits.items) |x| longest = @max(longest, x);
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var sum: std.ArrayList(u8) = .empty;
    sum.print(a, "{d} jobs; waited {s} median, {s} longest", .{ picked.items.len, duration(&b1, history.median(waits.items)), duration(&b2, longest) }) catch {};
    if (measured != 0) {
        const m: f64 = @floatFromInt(measured);
        sum.print(a, "; {d:.1} active of {d:.1} cores in use on average", .{ used / m, granted / m }) catch {};
    }
    if (lost != 0) sum.print(a, "; {d} lost (the machine restarted or cpuq was killed)", .{lost}) catch {};
    if (boxed) {
        const t: table.Table = .{
            .title = if (pattern) |p| a.print("history · {s}", .{p}) catch "history" else "history",
            .columns = &.{
                .{ .head = "WHEN" },
                .{ .head = "LABEL" },
                .{ .head = "POOL" },
                .{ .head = "IN USE", .alignment = .right },
                .{ .head = "WAITED", .alignment = .right },
                .{ .head = "RAN", .alignment = .right },
                .{ .head = "ACTIVE", .alignment = .right },
                .{ .head = "EXIT", .flexible = true },
            },
            .rows = trows.items,
            .notes = &.{sum.items},
        };
        t.boxed(a, w, table.terminalWidth(1), color) catch {};
        return 0;
    }
    w.print("\n{s}\n", .{sum.items}) catch {};
    return 0;
}

const JsonHolder = struct {
    ticket: u64 = 0,
    pid: i32 = 0,
    holder_alive: bool = false,
    child: i32 = 0,
    cores: u32 = 0,
    /// The core tokens it holds, by number: which of the budget's cores.
    slots: []const u32 = &.{},
    /// Paused by hand (`cpuq pause`).
    paused: bool = false,
    /// Cores the command's process tree kept busy over the sample: CPU time
    /// over wall time; null when there is no command to measure.
    using: ?f64 = null,
    priority: []const u8 = "",
    exclusive: bool = false,
    label: []const u8 = "",
    command: []const u8 = "",
    since: i64 = 0,
};

const JsonWaiter = struct {
    /// Seconds until it is expected to start, from the history of jobs
    /// with its holders' and the waiters ahead's labels; null when unknown.
    eta: ?f64 = null,
    order: usize = 0,
    ticket: u64 = 0,
    pid: i32 = 0,
    /// The request: at least `cores`, up to `max`.
    cores: u32 = 0,
    max: u32 = 0,
    priority: []const u8 = "",
    class: []const u8 = "",
    exclusive: bool = false,
    label: []const u8 = "",
    command: []const u8 = "",
    since: i64 = 0,
};

/// The gate in a form a program can act on: `state` is open, pressure, load
/// (the valve is tripped) or spacing (one admission per 10 s), and `load` is
/// the 1-minute load behind a load or spacing state.
const JsonGate = struct {
    state: []const u8 = "",
    load: ?f64 = null,
    text: []const u8 = "",
    /// The load valve's thresholds, when the load check is on: it trips above
    /// `trip` while the CPUs are at least `busy_trip` busy, and reopens at
    /// `reopen` (or as soon as they are under three quarters busy).
    trip: ?f64 = null,
    reopen: ?f64 = null,
    busy_trip: ?f64 = null,
};

/// Typical run times from the history: the median run of finished jobs by
/// label, and by project (the label up to its first ':').
const RunTimes = struct {
    by_label: std.StringHashMapUnmanaged(f64) = .empty,
    by_project: std.StringHashMapUnmanaged(f64) = .empty,
    /// Each label's finished runs' average active cores, oldest first.
    uses: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty,

    fn load(ctx: *Ctx, a: std.mem.Allocator) RunTimes {
        var rt: RunTimes = .{};
        const jobs = history.load(ctx.io, a, historyPath(ctx), sys.bootTime(ctx.io), &aliveForHistory);
        var label_runs: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty;
        var project_runs: std.StringHashMapUnmanaged(std.ArrayList(f64)) = .empty;
        for (jobs) |j| {
            const r = j.ran() orelse continue;
            if (j.label.len == 0 or !std.mem.eql(u8, j.pool, "cores")) continue;
            if (j.used()) |u| {
                const gop = rt.uses.getOrPut(a, j.label) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(a, u) catch {};
            }
            for ([_]struct { m: *std.StringHashMapUnmanaged(std.ArrayList(f64)), k: []const u8 }{
                .{ .m = &label_runs, .k = j.label },
                .{ .m = &project_runs, .k = std.mem.sliceTo(j.label, ':') },
            }) |e| {
                const gop = e.m.getOrPut(a, e.k) catch continue;
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                gop.value_ptr.append(a, r) catch {};
            }
        }
        var it = label_runs.iterator();
        while (it.next()) |e| rt.by_label.put(a, e.key_ptr.*, history.median(e.value_ptr.items)) catch {};
        var it2 = project_runs.iterator();
        while (it2.next()) |e| rt.by_project.put(a, e.key_ptr.*, history.median(e.value_ptr.items)) catch {};
        return rt;
    }

    fn typical(rt: RunTimes, label: []const u8) ?f64 {
        if (label.len == 0) return null;
        return rt.by_label.get(label) orelse rt.by_project.get(std.mem.sliceTo(label, ':'));
    }
};

/// Fills in each waiter's ETA by playing the queue forward: holders free
/// their cores at their typical end, and each waiter, in order, starts once
/// its minimum fits and then holds it for its own typical run. An unknown
/// run time ahead of a waiter leaves its ETA unknown.
fn estimate(rt: RunTimes, budget: u32, holders: []const JsonHolder, waiters: []JsonWaiter, now: i64) void {
    const Release = struct { at: ?f64, cores: u32 };
    var pending: [256]Release = undefined;
    var n: usize = 0;
    var free: i64 = @intCast(budget);
    for (holders) |h| {
        free -= h.cores;
        if (n == pending.len) return;
        const at: ?f64 = if (rt.typical(h.label)) |t| @max(@as(f64, @floatFromInt(h.since)) + t - @as(f64, @floatFromInt(now)), 0) else null;
        pending[n] = .{ .at = at, .cores = h.cores };
        n += 1;
    }
    var clock: f64 = 0;
    var known = true;
    for (waiters) |*q| {
        const need: i64 = if (q.exclusive) @intCast(budget) else @min(q.cores, budget);
        while (free < need and n != 0) {
            // The next release: the earliest known one; an unknown one only
            // when no known one is left.
            var pick: usize = 0;
            for (pending[0..n], 0..) |r, i| {
                const best = pending[pick].at;
                if (r.at) |at| {
                    if (best == null or at < best.?) pick = i;
                }
            }
            const r = pending[pick];
            pending[pick] = pending[n - 1];
            n -= 1;
            if (r.at) |at| clock = @max(clock, at) else known = false;
            free += r.cores;
        }
        if (free < need or !known) {
            q.eta = null;
            known = false;
            continue;
        }
        q.eta = clock;
        free -= need;
        if (n < pending.len) {
            pending[n] = .{ .at = if (rt.typical(q.label)) |t| clock + t else null, .cores = @intCast(need) };
            n += 1;
        }
    }
}

/// `cpuq status --json`. `schema` changes only when a field is removed or
/// changes meaning; new fields may appear in any version.
/// A named lease in `cpuq status --json`: its holders (one per slot taken)
/// and waiters.
const JsonLease = struct {
    name: []const u8 = "",
    holders: []const JsonHolder = &.{},
    waiters: []const JsonWaiter = &.{},
};

fn toHolders(a: std.mem.Allocator, leases: []const state.Entry, busy: []const ?f64) []JsonHolder {
    var out: std.ArrayList(JsonHolder) = .empty;
    for (leases, 0..) |l, i| {
        const r = l.record;
        out.append(a, .{
            .ticket = r.ticket,
            .pid = r.pid,
            .holder_alive = sys.processAlive(r.pid),
            .child = r.child,
            .cores = r.cores,
            .slots = r.slotList(a),
            .using = if (i < busy.len) busy[i] else null,
            .priority = @tagName(r.priority),
            .exclusive = r.exclusive,
            .label = r.label,
            .command = r.cmd,
            .since = r.since,
        }) catch {};
    }
    return out.items;
}

fn toWaiters(a: std.mem.Allocator, queue: []const state.Entry) []JsonWaiter {
    var out: std.ArrayList(JsonWaiter) = .empty;
    for (queue, 0..) |e, i| {
        const r = e.record;
        out.append(a, .{
            .order = i + 1,
            .ticket = r.ticket,
            .pid = r.pid,
            .cores = r.cores,
            .max = @max(r.max, r.cores),
            .priority = @tagName(r.priority),
            .class = className(e.class),
            .exclusive = r.exclusive,
            .label = r.label,
            .command = r.cmd,
            .since = r.since,
        }) catch {};
    }
    return out.items;
}

const JsonStatus = struct {
    schema: u32 = 1,
    version: []const u8 = version,
    dir: []const u8 = "",
    budget: u32 = 0,
    cores: u32 = 0,
    active_cores: u32 = 0,
    held: u32 = 0,
    free: u32 = 0,
    load: [3]f64 = .{ 0, 0, 0 },
    memory_pressure: []const u8 = "",
    gate: JsonGate = .{},
    holders: []const JsonHolder = &.{},
    waiters: []const JsonWaiter = &.{},
    /// Named leases that are held or waited for.
    leases: []const JsonLease = &.{},
    /// The busiest processes outside every cpuq job (empty with --no-usage).
    outside: []const JsonOutside = &.{},
};

const StatusView = struct {
    budget: u32,
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

    const mem: C = switch (v.pressure) {
        .normal => .{ .text = "normal", .tint = .good },
        .high => .{ .text = "pressure", .tint = .bad },
        .unknown => .{ .text = "unknown", .tint = .dim },
        .off => .{ .text = "off", .tint = .dim },
    };
    const gate: C = .{ .text = switch (v.gate) {
        .open => "open",
        .pressure => "closed: memory",
        .load => |l| a.print("closed: load {d:.1}", .{l}) catch "closed",
        .spacing => |l| a.print("spacing: load {d:.1}", .{l}) catch "spacing",
    }, .tint = switch (v.gate) {
        .open => .good,
        .spacing => .warn,
        .load, .pressure => .bad,
    } };
    const free = v.budget -| v.held;
    const summary: table.Table = .{
        .title = a.print("cpuq {s}{s}{s}", .{ v.version orelse version, if (short_host.len != 0) " · " else "", short_host }) catch "cpuq",
        .columns = &.{
            .{ .head = "BUDGET", .alignment = .right },
            .{ .head = "IN USE", .alignment = .right },
            .{ .head = "FREE", .alignment = .right },
            .{ .head = "LOAD", .sub = "1 5 15" },
            .{ .head = "MEMORY" },
            .{ .head = "GATE" },
        },
        .rows = &.{&.{
            .{ .text = a.print("{d}", .{v.budget}) catch "?" },
            .{ .text = a.print("{d}", .{v.held}) catch "?", .tint = if (v.held != 0) .accent else null },
            .{ .text = a.print("{d}", .{free}) catch "?", .tint = if (free == 0) .warn else .good },
            loadCell(a, v.load, v.online),
            mem,
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
            var b: [16]u8 = undefined;
            rows.append(a, a.dupe(C, &.{
                .{ .text = dash(h.label), .tint = .accent },
                .{ .text = a.print("{d}", .{h.cores}) catch "?" },
                using,
                .{ .text = if (h.exclusive) "exclusive" else h.priority, .tint = if (h.exclusive) .warn else null },
                .{ .text = a.dupe(u8, age(&b, v.now - h.since)) catch "?" },
                .{ .text = a.print("{d}{s}", .{ h.pid, if (h.holder_alive) "" else "*" }) catch "?", .tint = .dim },
                .{ .text = h.command },
            }) catch continue) catch {};
        }
        const t: table.Table = .{
            .title = a.print("in use: {d} of {d} cores", .{ v.held, v.budget }) catch "in use",
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
                .{ .text = dash(q.label), .tint = .accent },
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

/// A busy process that is not part of any cpuq job.
const JsonOutside = struct {
    pid: i32 = 0,
    name: []const u8 = "",
    using: f64 = 0,
};

const Sample = struct {
    /// Cores each lease's command keeps busy; null for one with no command.
    busy: []?f64,
    /// The busiest processes outside every cpuq job, busiest first.
    outside: []JsonOutside = &.{},
};

/// Watches every process for `sample_ms`: what each lease's command tree
/// keeps busy, and the busiest processes no cpuq job accounts for. Nothing
/// is sampled when `measure` is off.
fn sample(io: Io, a: std.mem.Allocator, leases: []const state.Entry, measure: bool) Sample {
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
    // Everything else: cpuq's jobs (their cpuq and command trees) and this
    // process are accounted for; what is left is outside load.
    const in_job = a.alloc(bool, after.len) catch return .{ .busy = busy };
    @memset(in_job, false);
    for (leases) |l| {
        sys.markTree(after, l.record.pid, in_job);
        if (l.record.child > 0) sys.markTree(after, l.record.child, in_job);
    }
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
    return .{ .busy = busy, .outside = outside.items[0..@min(outside.items.len, 5)] };
}

fn nullUsage(a: std.mem.Allocator, n: usize) []?f64 {
    const out = a.alloc(?f64, n) catch return &.{};
    @memset(out, null);
    return out;
}

fn cmdStatus(ctx: *Ctx, args: []const [:0]const u8) u8 {
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
    else
        .open;
    const waiters = a.dupe(JsonWaiter, st.waiters) catch st.waiters;
    statusBoxed(ctx, .{
        .budget = st.budget,
        .held = st.held,
        .load = st.load,
        .pressure = std.meta.stringToEnum(policy.Pressure, st.memory_pressure) orelse .unknown,
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
    const queue = state.scanQueue(&st, a, null, .{}, now, ctx.cfg.aging_s) catch @as([]state.Entry, &.{});
    var valve = st.readValve();
    st.unlock();
    const g = policy.gate(ctx.cfg, m, budget, &valve, now);
    var gbuf: [256]u8 = undefined;
    const gate_text = gateText(&gbuf, g, budget);

    // What each holder actually uses: its command's process tree, CPU time
    // over wall time between two snapshots.
    const smp = sample(io, a, leases, measure);
    const busy = smp.busy;

    const holders = toHolders(a, leases, busy);
    for (holders, leases) |*h, l| h.paused = st.isPaused(l.name);
    const waiters = toWaiters(a, queue);
    if (waiters.len != 0) estimate(RunTimes.load(ctx, a), budget, holders, waiters, now);

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
            .budget = budget,
            .cores = sys.totalCpus(ctx.io),
            .active_cores = m.active,
            .held = held,
            .free = budget -| held,
            .load = load,
            .memory_pressure = pressure,
            .gate = .{
                .state = @tagName(g),
                .load = switch (g) {
                    .load, .spacing => |l| l,
                    .open, .pressure => null,
                },
                .text = gate_text,
                .trip = if (ctx.cfg.load_check) @as(f64, @floatFromInt(budget)) + ctx.cfg.load_margin else null,
                .reopen = if (ctx.cfg.load_check) @as(f64, @floatFromInt(budget)) + ctx.cfg.load_margin / 2 else null,
                .busy_trip = if (ctx.cfg.load_check) 0.9 else null,
            },
            .holders = holders,
            .waiters = waiters,
            .leases = named.items,
            .outside = smp.outside,
        };
        std.json.Stringify.value(s, .{ .whitespace = .indent_2 }, w) catch {};
        w.writeAll("\n") catch {};
        return 0;
    }
    if (std.c.isatty(1) != 0) {
        statusBoxed(ctx, .{
            .budget = budget,
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
        });
        return 0;
    }
    w.print("dir     {s}\n", .{st.path}) catch {};
    w.print("budget  {d} cores ({d} online of {d}); in use {d}, free {d}\n", .{ budget, m.active, sys.totalCpus(ctx.io), held, budget -| held }) catch {};
    w.print("load    {d:.2} {d:.2} {d:.2}; memory pressure {s}; gate {s}\n", .{ load[0], load[1], load[2], pressure, gate_text }) catch {};
    if (showOutside(smp.outside, g)) {
        w.writeAll("outside") catch {};
        for (smp.outside, 0..) |o, k| w.print("{s} {s} (pid {d}, {d:.1})", .{ if (k == 0) "" else ",", o.name, o.pid, o.using }) catch {};
        w.writeAll("\n") catch {};
    }
    // The label column fits the longest label, within reason.
    var lw: usize = 5;
    for (holders) |h| lw = @max(lw, @min(dash(h.label).len, 32));
    for (waiters) |q| lw = @max(lw, @min(dash(q.label).len, 32));
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
            pid_text,                child_text,                    h.cores,   using_text,                                                                   if (h.exclusive) "excl" else h.priority,
            age(&b1, now - h.since), pad(&lbuf, dash(h.label), lw), h.command, if (h.holder_alive) "" else "  (cpuq gone; the command still has the cores)",
        }) catch {};
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
        w.print("  {d:<4} {s:<8} {s:<6} {s:<7} {s:<8} {s} {s}\n", .{ q.order, pid_text, cores_text, prio, age(&b1, now - q.since), pad(&lbuf, dash(q.label), lw), q.command }) catch {};
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

/// `s` left-aligned in a field of `width` (a longer `s` is cut to fit).
fn pad(buf: []u8, s: []const u8, width: usize) []const u8 {
    const w = @min(width, buf.len);
    const n = @min(s.len, w);
    @memcpy(buf[0..n], s[0..n]);
    @memset(buf[n..w], ' ');
    return buf[0..w];
}

fn dash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}
