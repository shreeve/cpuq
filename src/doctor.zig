//! `cpuq hook` and `cpuq doctor`: what keeps work under cpuq, and what cpuq sees but cannot stop.
const std = @import("std");
const state = @import("state.zig");
const sys = @import("sys.zig");
const hook = @import("hook.zig");
const submit = @import("submit.zig");
const place = @import("place.zig");

const main = @import("main.zig");
const repos = @import("repos.zig");
const admission = @import("admission.zig");
const runner = @import("runner.zig");
const runtimes = @import("runtimes.zig");
const status = @import("status.zig");

const version = main.version;
const exit_failure = main.exit_failure;
const Ctx = main.Ctx;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const openState = main.openState;
const machine = main.machine;
const repoAt = repos.repoAt;
const gitTopAt = repos.gitTopAt;
const lockOrFail = admission.lockOrFail;
const nestedGrant = runner.nestedGrant;
const RunTimes = runtimes.RunTimes;
const sample = status.sample;

/// `cpuq hook`: Claude Code's PreToolUse hook. Reads the tool call (JSON) on
/// stdin; a shell command that would load the machine outside cpuq, or misuse
/// it, is refused: the reason and the command to run instead on stderr, exit
/// 2, which the agent sees. Everything else, and anything it cannot read,
/// passes (exit 0). CPUQ_HOOK=off turns it off.
pub fn cmdHook(ctx: *Ctx) u8 {
    if (ctx.env.get("CPUQ_HOOK")) |v| if (std.mem.eql(u8, v, "off")) return 0;
    // Inside a cpuq job already: runs nest within its grant.
    if (nestedGrant(ctx)) return 0;
    const a = ctx.arena;
    var input: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (input.items.len < 1 << 22) {
        const n = std.c.read(0, &buf, buf.len);
        if (n > 0) {
            input.appendSlice(a, buf[0..@intCast(n)]) catch return 0;
            continue;
        }
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        break;
    }
    const Call = struct {
        tool_name: []const u8 = "",
        tool_input: struct { command: []const u8 = "" } = .{},
        cwd: []const u8 = "",
    };
    const call = std.json.parseFromSliceLeaky(Call, a, input.items, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return 0;
    if (!std.mem.eql(u8, call.tool_name, "Bash") or call.tool_input.command.len == 0) return 0;
    const project = std.fs.path.basename(call.cwd);
    var advisor: HookAdvisor = .{ .ctx = ctx, .cwd = call.cwd };
    const r = hook.check(a, call.tool_input.command, sys.totalCpus(ctx.io), project, advisor.it()) orelse return 0;
    std.debug.print("cpuq: {s}.\nRun instead: {s}\n(See AGENTS.md in the cpuq repo. A command that must run as it is can end with `# cpuq: skip`.)\n", .{ r.reason, r.instead });
    return 2;
}

/// What the hook knows of a `cpuq run`'s work: its runs here and elsewhere, and the repo's specs.
/// Long work (over place.long_s here) is refused when another place runs it in half the time:
/// a spec's work (one needing its packs or caches) through `cpuq submit`.
const HookAdvisor = struct {
    ctx: *Ctx,
    cwd: []const u8,

    fn it(h: *HookAdvisor) hook.Advisor {
        return .{ .ctx = h, .advise = advise };
    }

    fn advise(p: *anyopaque, cmd: []const u8) ?hook.Refusal {
        const h: *HookAdvisor = @ptrCast(@alignCast(p));
        const ctx = h.ctx;
        const a = ctx.arena;
        if (h.cwd.len == 0) return null;
        const repo = repoAt(ctx, h.cwd) orelse return null;
        const top = gitTopAt(ctx, h.cwd);
        const found = if (top) |root| submit.specFor(a, ctx.io, root, cmd) else null;
        // Not a spec's work: placement sends it where it finishes first.
        const spec = found orelse return null;
        if (!spec.needs) return null;
        const rt = RunTimes.load(ctx, a);
        const key = place.workKey(a, repo, cmd);
        const here = rt.workStats(a, null, key);
        if (here.runs == 0 or here.ran < place.long_s) return null;
        var hb: [32]u8 = undefined;
        const here_txt = place.approx(&hb, here.ran);
        const self = std.process.executablePathAlloc(ctx.io, a) catch "cpuq";
        const cx: submit.Cx = .{ .io = ctx.io, .a = a, .env = ctx.env, .out = ctx.out, .version = version, .cfg = &ctx.cfg, .self = self };
        var times: std.ArrayList(u8) = .empty;
        var fastest: ?f64 = null;
        for (submit.specTimes(cx, spec.label)) |t| {
            var b: [32]u8 = undefined;
            times.print(a, ", {s} on {s}", .{ place.approx(&b, t.seconds), t.host }) catch {};
            fastest = @min(fastest orelse t.seconds, t.seconds);
        }
        const f = fastest orelse return null;
        if (f * 2 > here.ran) return null;
        return .{
            .reason = a.print("this is {s}'s work: {s} here{s}", .{ spec.path, here_txt, times.items }) catch "this is a spec's work",
            .instead = a.print("cpuq submit {s}{s}{s} (in the background: it ends with a verdict line)", .{ spec.path, if (spec.rest.len != 0) " -- " else "", spec.rest }) catch "cpuq submit",
        };
    }
};

/// `cpuq doctor [--host HOST]`: what goes wrong that cpuq can see but not
/// stop. Heavy work outside cpuq, jobs using far more CPU than they were
/// granted, jobs idle for long while holding cores, requests too big to start
/// on a busy machine, and waiters held beside idle CPUs. One line each; exit
/// 1 when there is anything to fix, 0 when not.
pub fn cmdDoctor(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var host: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--host") and i + 1 < args.len) {
            host = args[i + 1];
            i += 1;
        } else return usageError("doctor takes only --host HOST", .{});
    }
    const io = ctx.io;
    if (host) |h| {
        var child = std.process.spawn(io, .{ .argv = &.{ "ssh", "-o", "BatchMode=yes", h, "cpuq", "doctor" }, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit }) catch return exit_failure;
        const term = child.wait(io) catch return exit_failure;
        return switch (term) {
            .exited => |code| code,
            else => exit_failure,
        };
    }
    const a = ctx.arena;
    var st = openState(ctx);
    const m = machine(ctx);
    const now = nowSeconds(io);
    lockOrFail(&st);
    const leases = state.scanLeases(&st, a, false) catch @as([]state.Entry, &.{});
    const queue = state.scanQueue(&st, a, null, .{}, now, ctx.cfg.aging_s) catch @as([]state.Entry, &.{});
    const uses = st.readUsage(a);
    st.unlock();
    const smp = sample(io, a, leases, true);
    // Threads ready to run show a job that starts more than its grant even
    // when a crowded machine gives them little CPU.
    const procs = sys.processes(io, a);
    const cpus = sys.totalCpus(io);
    const w = ctx.out;
    var found: u32 = 0;
    for (smp.outside) |o| if (o.using >= 1.0) {
        found += 1;
        w.print("warn    {s} (pid {d}) uses {d:.1} CPUs outside cpuq: run heavy work through `cpuq run`; if it is an --opaque job's hidden work, nothing to do\n", .{ o.name, o.pid, o.using }) catch {};
    };
    for (leases, smp.busy) |l, busy| {
        const r = l.record;
        if (r.exclusive or r.hidden) continue;
        const who = if (r.label.len != 0) r.label else r.cmd;
        const cores: f64 = @floatFromInt(r.cores);
        const ready: u32 = if (r.child > 0) sys.treeRunning(procs, r.child) else 0;
        const u = busy orelse 0;
        if (u >= cores * 1.5 and u - cores >= 1) {
            found += 1;
            w.print("warn    {s} (pid {d}) uses {d:.1} CPUs on a grant of {d}: pass the grant on (-j\"$CPUQ_CORES\")\n", .{ who, r.pid, u, r.cores }) catch {};
        } else if (ready >= 2 * r.cores + 2) {
            found += 1;
            w.print("warn    {s} (pid {d}) has {d} threads ready to run on a grant of {d}: pass the grant on (-j\"$CPUQ_CORES\")\n", .{ who, r.pid, ready, r.cores }) catch {};
        }
        if (uses.get(l.name)) |use| if (use.at_ms != 0 and use.avg < 0.05 and now - r.since > 600) {
            found += 1;
            w.print("warn    {s} (pid {d}) has held {d} {s} for {d} min using almost no CPU: parked? It blocks timing windows\n", .{ who, r.pid, r.cores, if (r.cores == 1) "core" else "cores", @divFloor(now - r.since, 60) }) catch {};
        };
    }
    const busy_share = m.busy orelse 1;
    for (queue) |e| {
        const r = e.record;
        const who = if (r.label.len != 0) r.label else r.cmd;
        if (!r.exclusive and r.cores > @max(cpus / 2, 1)) {
            found += 1;
            w.print("warn    {s} (pid {d}) asks for at least {d} cores on {d} CPUs: it waits for a nearly empty machine; ask for a range such as --cores 2-6\n", .{ who, r.pid, r.cores, cpus }) catch {};
        }
        if (now - r.since > 300 and busy_share < 0.6 and m.pressure != .high) {
            found += 1;
            w.print("warn    {s} (pid {d}) has waited {d} min while the CPUs are {d:.0}% busy\n", .{ who, r.pid, @divFloor(now - r.since, 60), busy_share * 100 }) catch {};
        }
    }
    if (found == 0) w.writeAll("ok      nothing to fix\n") catch {};
    w.flush() catch {};
    return if (found == 0) 0 else 1;
}
