//! cpuq: a machine-wide CPU core queue. Jobs wait their turn for a number
//! of cores out of a budget, then run in the foreground holding them. There
//! is no daemon: every hold is a flock(2) in the state directory.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

test {
    _ = policy;
    _ = state;
}

const version = @import("build_options").version;

const usage =
    \\usage: cpuq run [options] [--] CMD [ARGS...]
    \\       cpuq status [--json]
    \\       cpuq budget
    \\       cpuq qos
    \\
    \\run options:
    \\  --cores K             cores to hold (default 2; clamped to the budget)
    \\  --priority P          high, normal (default) or low
    \\  --exclusive           take the whole budget once running work drains
    \\  --label TEXT          a name shown by `cpuq status`
    \\  --max-wait SECONDS    give up (exit 75) after waiting this long
    \\  --no-load-check       ignore the load safety valve
    \\  --qos none            leave the command's scheduling class unchanged
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
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    cfg: policy.Config = .{},
    cfg_path: []const u8 = "",
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
    loadConfig(ctx);
    if (std.mem.eql(u8, cmd, "status")) return cmdStatus(ctx, args[1..]);
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
    return policy.effectiveBudget(envBudget(ctx), ctx.cfg, m.active, sys.totalCpus(ctx.io));
}

const RunOptions = struct {
    cores: u32 = 2,
    priority: policy.Priority = .normal,
    exclusive: bool = false,
    label: []const u8 = "",
    max_wait: ?i64 = null,
    load_check: bool = true,
    qos: bool = true,
    cmd: []const [:0]const u8 = &.{},
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
        const takes_value = for ([_][]const u8{ "--cores", "--priority", "--label", "--max-wait", "--qos" }) |v| {
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
        if (std.mem.eql(u8, name, "--cores")) {
            o.cores = policy.parseCount(value) orelse {
                _ = usageError("--cores needs a whole number, at least 1, not '{s}'", .{value});
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
};

fn lockOrFail(st: *state.State) void {
    st.lock() catch |err| fail("admission lock: {t}", .{err});
}

/// Queues this run and returns once it holds its cores.
fn waitTurn(ctx: *Ctx, st: *state.State, o: RunOptions) Lease {
    const io = ctx.io;
    const cfg = ctx.cfg;
    const cores = sys.totalCpus(io);
    const start = nowSeconds(io);

    lockOrFail(st);
    var rec: state.Record = .{
        .ticket = st.nextTicket() catch |err| fail("ticket: {t}", .{err}),
        .pid = sys.getpid(),
        .cores = o.cores,
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

    var next_note = start + cfg.note_s;
    var last_gate: policy.Gate = .open;
    while (true) {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        const a = scratch.allocator();

        lockOrFail(st);
        const now = nowSeconds(io);
        const queue = state.scanQueue(st, a, ticket_name, rec, now, cfg.aging_s) catch |err| fail("queue: {t}", .{err});
        const pos = for (queue, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, ticket_name)) break i;
        } else fail("ticket {s} vanished from the queue", .{ticket_name});

        if (o.max_wait) |mw| if (now - start >= mw) {
            st.queue.deleteFile(io, ticket_name) catch {};
            st.unlock();
            std.debug.print("cpuq: gave up after waiting {d}s\n", .{now - start});
            std.process.exit(exit_timeout);
        };
        if (now >= next_note) {
            note(ctx, st, a, now - start, queue, pos, last_gate);
            next_note = now + cfg.note_s;
        }
        var wake_ms: i64 = @min(next_note - now, 60) * 1000;
        if (o.max_wait) |mw| wake_ms = @min(wake_ms, (start + mw - now) * 1000);
        wake_ms = @max(wake_ms, 100);

        if (pos > 0) {
            // Not at the head: block on the waiter just ahead until it is
            // admitted or gone.
            const pred = st.queue.openFile(io, queue[pos - 1].name, .{}) catch null;
            st.unlock();
            if (pred) |f| {
                waitOn(io, f, wake_ms);
                f.close(io);
            }
            continue;
        }

        const m = machine(ctx);
        const budget = budgetNow(ctx, m);
        var valve = st.readValve();
        last_gate = policy.gate(cfg, m, budget, if (o.load_check) &valve else null, now);
        if (o.load_check and cfg.load_check) st.writeValve(valve);
        if (last_gate == .open) {
            const k = policy.grant(o.cores, o.exclusive, budget);
            const exclusive_running = (state.scanLeases(st, a, true) catch @as([]state.Entry, &.{})).len != 0;
            const got = state.takeTokens(st, ctx.arena, k, o.exclusive, budget, cores, exclusive_running) catch |err| fail("tokens: {t}", .{err});
            if (got) |tokens| {
                rec.cores = k;
                rec.since = now;
                // The lease is named by the ticket number; should a live job
                // hold that name anyway, take a fresh number rather than wait.
                var lease_name: []const u8 = undefined;
                const lease = for (0..3) |_| {
                    lease_name = state.leaseName(ctx.arena.alloc(u8, 16) catch fail("out of memory", .{}), rec.ticket, o.exclusive);
                    break st.createLease(rec, lease_name) catch |err| switch (err) {
                        error.WouldBlock => {
                            rec.ticket = st.nextTicket() catch |e| fail("ticket: {t}", .{e});
                            continue;
                        },
                        else => fail("lease: {t}", .{err}),
                    };
                } else fail("lease: no free lease name", .{});
                valve.last_admit = now;
                if (o.load_check and cfg.load_check) st.writeValve(valve);
                st.queue.deleteFile(io, ticket_name) catch {};
                ticket.close(io);
                st.unlock();
                return .{ .record = rec, .name = lease_name, .file = lease, .tokens = tokens };
            }
        }
        st.unlock();
        io.sleep(.fromMilliseconds(cfg.poll_ms), .awake) catch {};
    }
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
fn note(ctx: *Ctx, st: *state.State, a: std.mem.Allocator, waited: i64, queue: []const state.Entry, pos: usize, g: policy.Gate) void {
    var w_buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&w_buf);
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var b3: [128]u8 = undefined;
    const m = machine(ctx);
    const budget = budgetNow(ctx, m);
    const held = state.heldTokens(st) catch 0;
    w.print("cpuq: waiting {s}: {s} in {s}", .{ age(&b1, waited), ordinal(&b2, pos + 1), className(queue[pos].class) }) catch {};
    if (pos == 0 and g != .open) w.print(", {s}", .{gateText(&b3, g, budget)}) catch {};
    w.print("; {d}/{d} cores held", .{ held, budget }) catch {};
    const leases = state.scanLeases(st, a, false) catch @as([]state.Entry, &.{});
    for (leases, 0..) |l, i| {
        w.print("{s} {s} (pid {d}, {d})", .{
            if (i == 0) " by" else ",",
            if (l.record.label.len != 0) l.record.label else std.mem.sliceTo(l.record.cmd, ' '),
            l.record.pid,
            l.record.cores,
        }) catch break;
    }
    std.debug.print("{s}\n", .{w.buffered()});
}

fn rewriteRecord(io: Io, f: Io.File, r: state.Record) void {
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    r.write(&w) catch return;
    f.setLength(io, 0) catch return;
    f.writePositionalAll(io, w.buffered(), 0) catch {};
}

fn runAdmitted(ctx: *Ctx, st: *state.State, o: RunOptions, exe: [:0]const u8, lease_in: Lease) u8 {
    const io = ctx.io;
    var lease = lease_in;
    const k = lease.record.cores;

    // The command and its descendants share the token and lease locks, so a
    // SIGKILLed cpuq does not hand the cores on while the command runs.
    for (lease.tokens) |t| sys.inherit(t.handle);
    sys.inherit(lease.file.handle);

    var num: [16]u8 = undefined;
    ctx.env.put("CPUQ_CORES", std.mem.print(&num, "{d}", .{k}) catch "1") catch fail("out of memory", .{});
    ctx.env.put("CPUQ_TOKEN", lease.name) catch fail("out of memory", .{});
    const pipe = sys.jobserverPipe(k - 1) catch |err| fail("jobserver: {t}", .{err});
    const flags = policy.makeflags(ctx.arena, ctx.env.get("MAKEFLAGS"), pipe[0], pipe[1]) catch fail("out of memory", .{});
    ctx.env.put("MAKEFLAGS", flags) catch fail("out of memory", .{});
    const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch fail("out of memory", .{});

    const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch fail("out of memory", .{});
    for (o.cmd, 0..) |a, i| argv[i] = a.ptr;

    sys.installForwarding();
    const qos = policy.qosFor(o.priority, o.exclusive, ctx.cfg.qos and o.qos);
    const spawned = sys.spawn(exe, argv.ptr, @ptrCast(envp.slice.ptr), qos);
    sys.closeFd(pipe[0]);
    sys.closeFd(pipe[1]);
    const exit: sys.Exit = if (spawned) |pid| blk: {
        sys.setChild(pid);
        lease.record.child = pid;
        rewriteRecord(io, lease.file, lease.record);
        break :blk sys.waitChild(pid);
    } else |err| blk: {
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        break :blk .{ .code = if (err == error.FileNotFound) exit_notfound else exit_noexec };
    };

    // LOCK_UN releases each lock for every holder of the open file, so a
    // descendant that kept a descriptor (a build server, a nohup'd helper)
    // does not keep the cores.
    for (lease.tokens) |t| {
        t.unlock(io);
        t.close(io);
    }
    lease.file.unlock(io);
    lease.file.close(io);
    lockOrFail(st);
    st.leases.deleteFile(io, lease.name) catch {};
    st.unlock();

    ctx.out.flush() catch {};
    switch (exit) {
        .code => |c| return c,
        .signal => |sig| sys.dieBySignal(sig),
    }
}

const JsonHolder = struct {
    ticket: u64,
    pid: i32,
    holder_alive: bool,
    child: i32,
    cores: u32,
    priority: []const u8,
    exclusive: bool,
    label: []const u8,
    command: []const u8,
    since: i64,
};

const JsonWaiter = struct {
    order: usize,
    ticket: u64,
    pid: i32,
    cores: u32,
    priority: []const u8,
    class: []const u8,
    exclusive: bool,
    label: []const u8,
    command: []const u8,
    since: i64,
};

/// The gate in a form a program can act on: `state` is open, pressure, load
/// (the valve is tripped) or spacing (one admission per 10 s), and `load` is
/// the 1-minute load behind a load or spacing state.
const JsonGate = struct {
    state: []const u8,
    load: ?f64,
    text: []const u8,
};

/// `cpuq status --json`. `schema` changes only when a field is removed or
/// changes meaning; new fields may appear in any version.
const JsonStatus = struct {
    schema: u32 = 1,
    version: []const u8 = version,
    dir: []const u8,
    budget: u32,
    cores: u32,
    active_cores: u32,
    held: u32,
    free: u32,
    load: [3]f64,
    memory_pressure: []const u8,
    gate: JsonGate,
    holders: []const JsonHolder,
    waiters: []const JsonWaiter,
};

fn cmdStatus(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var json = false;
    for (args) |a| {
        if (std.mem.eql(u8, a, "--json")) json = true else return usageError("unknown status option '{s}'", .{a});
    }
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

    var holders: std.ArrayList(JsonHolder) = .empty;
    for (leases) |l| {
        const r = l.record;
        holders.append(a, .{
            .ticket = r.ticket,
            .pid = r.pid,
            .holder_alive = sys.processAlive(r.pid),
            .child = r.child,
            .cores = r.cores,
            .priority = @tagName(r.priority),
            .exclusive = r.exclusive,
            .label = r.label,
            .command = r.cmd,
            .since = r.since,
        }) catch {};
    }
    var waiters: std.ArrayList(JsonWaiter) = .empty;
    for (queue, 0..) |e, i| {
        const r = e.record;
        waiters.append(a, .{
            .order = i + 1,
            .ticket = r.ticket,
            .pid = r.pid,
            .cores = r.cores,
            .priority = @tagName(r.priority),
            .class = className(e.class),
            .exclusive = r.exclusive,
            .label = r.label,
            .command = r.cmd,
            .since = r.since,
        }) catch {};
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
            },
            .holders = holders.items,
            .waiters = waiters.items,
        };
        std.json.Stringify.value(s, .{ .whitespace = .indent_2 }, w) catch {};
        w.writeAll("\n") catch {};
        return 0;
    }
    w.print("dir     {s}\n", .{st.path}) catch {};
    w.print("budget  {d} cores ({d} active of {d}); held {d}, free {d}\n", .{ budget, m.active, sys.totalCpus(ctx.io), held, budget -| held }) catch {};
    w.print("load    {d:.2} {d:.2} {d:.2}; memory pressure {s}; gate {s}\n", .{ load[0], load[1], load[2], pressure, gate_text }) catch {};
    var b1: [16]u8 = undefined;
    w.print("\nholders ({d})\n", .{holders.items.len}) catch {};
    if (holders.items.len != 0) w.writeAll("  PID      CMD-PID  CORES  PRIO    SINCE    LABEL         COMMAND\n") catch {};
    for (holders.items) |h| {
        var pid_buf: [16]u8 = undefined;
        const pid_text = std.mem.print(&pid_buf, "{d}{s}", .{ h.pid, if (h.holder_alive) "" else "*" }) catch "?";
        var child_buf: [16]u8 = undefined;
        const child_text = std.mem.print(&child_buf, "{d}", .{h.child}) catch "?";
        w.print("  {s:<8} {s:<8} {d:<6} {s:<7} {s:<8} {s:<13} {s}{s}\n", .{
            pid_text,                child_text,    h.cores,   if (h.exclusive) "excl" else h.priority,
            age(&b1, now - h.since), dash(h.label), h.command, if (h.holder_alive) "" else "  (cpuq gone; the command still holds the cores)",
        }) catch {};
    }
    w.print("\nwaiters ({d})\n", .{waiters.items.len}) catch {};
    if (waiters.items.len != 0) w.writeAll("  #    PID      CORES  PRIO    WAITING  LABEL         COMMAND\n") catch {};
    for (waiters.items) |q| {
        var prio_buf: [24]u8 = undefined;
        const prio = if (q.exclusive) "excl" else if (std.mem.eql(u8, q.class, q.priority)) q.priority else std.mem.print(&prio_buf, "{s}>{s}", .{ q.priority, q.class }) catch q.priority;
        var pid_buf: [16]u8 = undefined;
        const pid_text = std.mem.print(&pid_buf, "{d}", .{q.pid}) catch "?";
        w.print("  {d:<4} {s:<8} {d:<6} {s:<7} {s:<8} {s:<13} {s}\n", .{ q.order, pid_text, q.cores, prio, age(&b1, now - q.since), dash(q.label), q.command }) catch {};
    }
    return 0;
}

fn dash(s: []const u8) []const u8 {
    return if (s.len == 0) "-" else s;
}
