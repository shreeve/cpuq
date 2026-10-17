//! A hand at the queue: `cpuq first|start|cancel|pause|resume|stop`, `note`, `clean` and `wait`.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");
const clean = @import("clean.zig");

const main = @import("main.zig");
const admission = @import("admission.zig");
const leasing = @import("leasing.zig");
const remotes = @import("remotes.zig");

const exit_usage = main.exit_usage;
const exit_timeout = main.exit_timeout;
const exit_failure = main.exit_failure;
const Ctx = main.Ctx;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const stateDir = main.stateDir;
const openState = main.openState;
const lockOrFail = admission.lockOrFail;
const rewriteRecord = admission.rewriteRecord;
const servedOrder = admission.servedOrder;
const validLeaseName = leasing.validLeaseName;
const openNamed = leasing.openNamed;
const shellQuote = remotes.shellQuote;

/// True when a label matches a `cpuq wait --label` pattern: exactly, or by
/// prefix when the pattern ends in `*`.
fn labelMatches(pattern: []const u8, label: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) return std.mem.startsWith(u8, label, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, label);
}

/// The names of the named leases in the state directory.
pub fn namedLeases(ctx: *Ctx, a: std.mem.Allocator) []const []const u8 {
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

/// `cpuq clean [--dry-run] [--older AGE] [--host HOST]`: removes what jobs left here (copies,
/// pack versions, job records) once unused for AGE (the config's `clean_after`, 3d).
pub fn cmdClean(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var dry = false;
    var older: ?u32 = null;
    var host: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--dry-run")) {
            dry = true;
        } else if (std.mem.eql(u8, arg, "--older") and i + 1 < args.len) {
            i += 1;
            older = policy.parseAge(args[i]) orelse return usageError("--older takes a time such as 3d, 36h or 90m, not '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            host = args[i];
        } else return usageError("clean takes --dry-run, --older AGE and --host HOST", .{});
    }
    if (host) |h| return onHost(ctx, h, ctx.arena.print("cpuq clean{s}{s}", .{ if (dry) " --dry-run" else "", if (older) |o| ctx.arena.print(" --older {d}", .{o}) catch "" else "" }) catch return exit_failure);
    const after = older orelse ctx.cfg.clean_after_s;
    if (after == 0) {
        ctx.out.writeAll("cpuq clean: clean_after is off here; --older AGE to clean anyway\n") catch {};
        ctx.out.flush() catch {};
        return 0;
    }
    _ = clean.run(ctx.arena, ctx.io, ctx.env, nowSeconds(ctx.io), .{ .older_s = after, .dry_run = dry }, ctx.out);
    return 0;
}

/// `cpuq note PID|LABEL TEXT [--all] [--host HOST]`: sets what a running or waiting job is for,
/// after it started (its PR opened later, say). Only the note changes: not its label, nor how
/// it's sized or timed.
pub fn cmdNote(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var target: ?[]const u8 = null;
    var text: ?[]const u8 = null;
    var all = false;
    var host: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            host = args[i];
        } else if (target == null) target = arg else if (text == null) text = arg else return usageError("note takes a job (pid or label) and the text", .{});
    }
    const t = target orelse return usageError("note needs a job: a cpuq pid or a label (PATTERN* for a prefix), then the text", .{});
    const note_text = text orelse return usageError("note needs the text: cpuq note {s} \"#229 inline\"", .{t});
    if (host) |h| return onHost(ctx, h, ctx.arena.print("cpuq note {s} {s}{s}", .{ shellQuote(ctx.arena, t), shellQuote(ctx.arena, note_text), if (all) " --all" else "" }) catch return exit_failure);
    const pid: ?i32 = std.fmt.parseInt(i32, t, 10) catch null;
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    var st = openState(ctx);
    lockOrFail(&st);
    defer st.unlock();
    const Hit = struct { dir: Io.Dir, e: state.Entry };
    var hits: std.ArrayList(Hit) = .empty;
    const leases = state.scanLeases(&st, a, false) catch @as([]state.Entry, &.{});
    const queue = state.scanQueue(&st, a, null, .{}, nowSeconds(ctx.io), ctx.cfg.aging_s) catch @as([]state.Entry, &.{});
    for (leases) |e| if (if (pid) |p| e.record.pid == p else labelMatches(t, e.record.label)) hits.append(a, .{ .dir = st.leases, .e = e }) catch {};
    for (queue) |e| if (if (pid) |p| e.record.pid == p else labelMatches(t, e.record.label)) hits.append(a, .{ .dir = st.queue, .e = e }) catch {};
    if (hits.items.len == 0) {
        std.debug.print("cpuq: no running or waiting job matches '{s}'\n", .{t});
        return exit_failure;
    }
    if (hits.items.len > 1 and !all) {
        std.debug.print("cpuq: '{s}' matches {d} jobs; name one by pid, or add --all:\n", .{ t, hits.items.len });
        for (hits.items) |h| std.debug.print("  {d}  {s}  {s}\n", .{ h.e.record.pid, h.e.record.label, h.e.record.note });
        return exit_usage;
    }
    for (hits.items) |h| {
        var r = h.e.record;
        r.note = note_text;
        const f = h.dir.openFile(ctx.io, h.e.name, .{ .mode = .read_write }) catch continue;
        defer f.close(ctx.io);
        rewriteRecord(ctx.io, f, r);
        ctx.out.print("note: {s} (pid {d}): {s}\n", .{ if (r.label.len != 0) r.label else r.cmd, r.pid, note_text }) catch {};
    }
    return 0;
}

/// Runs a cpuq command line on HOST through ssh, for a job sent there: its output and
/// exit status come back as its own.
fn onHost(ctx: *Ctx, host: []const u8, remote: []const u8) u8 {
    const r = std.process.run(ctx.arena, ctx.io, .{ .argv = &.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, remote } }) catch return exit_failure;
    ctx.out.writeAll(r.stdout) catch {};
    ctx.out.flush() catch {};
    std.debug.print("{s}", .{r.stderr});
    return switch (r.term) {
        .exited => |c| c,
        else => exit_failure,
    };
}

/// start and cancel act on waiters: each leaves an order its waiter takes at
/// its next look (the head looks every `poll`, the next waiters every 2
/// seconds). pause, resume and stop act on running jobs: SIGSTOP or SIGCONT
/// to the command's whole process tree, or SIGTERM to its cpuq, which passes
/// it on. A paused job's cores count as idle, so they are lent at once.
/// Nothing touches an exclusive run. Several matches need --all.
/// This machine's name, short (`pop`, not pop.local).
/// Whether `host` names this machine (its short hostname, any case): `--on` it runs here.
pub fn cmdControl(ctx: *Ctx, comptime action: []const u8, args: []const [:0]const u8) u8 {
    var target: ?[]const u8 = null;
    var all = false;
    var host: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--all")) {
            all = true;
        } else if (std.mem.eql(u8, arg, "--host") and i + 1 < args.len) {
            i += 1;
            host = args[i];
        } else if (target == null) target = arg else return usageError("{s} takes one label or pid", .{action});
    }
    const t = target orelse return usageError("{s} needs a label (PATTERN* for a prefix) or a cpuq pid", .{action});
    if (host) |h| return onHost(ctx, h, ctx.arena.print("cpuq {s} {s}{s}", .{ action, shellQuote(ctx.arena, t), if (all) " --all" else "" }) catch return exit_failure);
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
    var procs = if (for_waiters) &[_]sys.Proc{} else sys.processes(ctx.io, a);
    for (hits.items) |e| {
        var r = e.record;
        // A job admitted a moment ago has its lease before its command: the
        // child pid is written once the command has started, so wait for it.
        if (!for_waiters and r.child <= 0) {
            var tries: u32 = 0;
            while (r.child <= 0 and tries < 20) : (tries += 1) {
                // Unlocked meanwhile: the job takes the lock to write its child pid.
                st.unlock();
                ctx.io.sleep(.fromMilliseconds(50), .awake) catch {};
                lockOrFail(&st);
                r = state.leaseRecord(&st, a, e.name) orelse break;
            }
            if (tries != 0) procs = sys.processes(ctx.io, a);
        }
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
        if (r.hidden and !comptime std.mem.eql(u8, action, "resume"))
            std.debug.print("cpuq: {s} runs its work where cpuq cannot reach it (--opaque): {s} reaches only the command cpuq started\n", .{ who, action });
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
            if (comptime std.mem.eql(u8, action, "pause")) stopTree(ctx, a, r.child);
            st.setPaused(e.name, comptime std.mem.eql(u8, action, "pause"));
        } else if (comptime std.mem.eql(u8, action, "stop")) {
            _ = std.c.kill(r.pid, .TERM);
        }
        ctx.out.print("{s}: {s} (pid {d})\n", .{ action, who, r.pid }) catch {};
    }
    ctx.out.flush() catch {};
    return 0;
}

/// Looks at a paused job's tree again until every process in it is stopped,
/// stopping any still running, for up to half a second. macOS drops a
/// SIGSTOP that lands while a process execs (it suspends the task, and exec
/// replaces the task), and a child its parent starts just as the parent
/// stops is not there to be stopped.
pub fn stopTree(ctx: *Ctx, a: std.mem.Allocator, root: std.c.pid_t) void {
    for (0..10) |_| {
        ctx.io.sleep(.fromMilliseconds(50), .awake) catch {};
        const procs = sys.processes(ctx.io, a);
        const in_tree = a.alloc(bool, procs.len) catch return;
        @memset(in_tree, false);
        sys.markTree(procs, root, in_tree);
        var running = false;
        for (procs, in_tree) |p, mine| if (mine and !p.stopped) {
            _ = std.c.kill(p.pid, .STOP);
            running = true;
        };
        if (!running) return;
    }
}

/// `cpuq wait --label PATTERN [--max-wait S]`: blocks until no job whose
/// label matches holds cores or a lease, or waits for either.
pub fn cmdWait(ctx: *Ctx, args: []const [:0]const u8) u8 {
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
            const queue = servedOrder(ctx, st, a, state.scanQueue(st, a, null, .{}, now, ctx.cfg.aging_s) catch @as([]state.Entry, &.{}), now, false);
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
