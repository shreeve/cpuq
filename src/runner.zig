//! `cpuq run`: options checked, then an operation here (op.zig), a run on another machine
//! (`--on`), or a test runner that starts runs of its own (`--driver`); `cpuq wait` for runs to
//! end; and `cpuq hook`, which keeps heavy commands under `cpuq run`.
const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const hook = @import("hook.zig");
const history = @import("history.zig");
const submit = @import("submit.zig");
const place = @import("place.zig");
const pool_mod = @import("pool.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");
const repos = @import("repos.zig");
const remotes = @import("remotes.zig");
const runtimes = @import("runtimes.zig");
const op = @import("op.zig");

const exit_usage = main.exit_usage;
const exit_timeout = main.exit_timeout;
const exit_noexec = main.exit_noexec;
const exit_notfound = main.exit_notfound;
const version = main.version;
const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const loadConfig = main.loadConfig;
const stateDir = main.stateDir;
const RunOptions = runopts.RunOptions;
const parseRun = runopts.parseRun;
const findExecutable = runopts.findExecutable;

/// A run sent to a host by name and lost there is started again and rerun only once.
pub var send_retried = false;

pub fn cmdRun(ctx: *Ctx, args: []const [:0]const u8) u8 {
    if (removedOption(args, false)) |msg| {
        std.debug.print("cpuq: {s}\n", .{msg});
        return exit_usage;
    }
    var o = parseRun(args) orelse return exit_usage;
    if (o.cmd.len == 0) return usageError("run needs a command", .{});
    loadConfig(ctx);
    if ((o.return_count != 0 or o.include_count != 0) and o.on == null) return usageError("--return and --include go with --on", .{});
    // `--on` this machine itself runs here; any other host must be one of this machine's remotes.
    if (o.on) |h| {
        if (remotes.isSelf(ctx.arena, h)) {
            o.on = null;
            o.return_count = 0;
            o.include_count = 0;
        } else if (!ctx.cfg.isRemote(h)) {
            return usageError("--on {s}: not one of this machine's remotes (config remotes = {s})", .{ h, if (ctx.cfg.remotes.len == 0) "none" else ctx.cfg.remotes });
        }
    }
    if (o.on) |h| {
        if (o.tethered) tether();
        return remotes.runOn(ctx, o, h);
    }
    const inside = !o.driver and op.nested(ctx);
    if (o.tethered) tether();
    if (o.driver) return runDriver(ctx, o);
    // Where the command may report its progress (`DONE TOTAL FAILING`): the file `cpuq submit`
    // chose for its job. A CPUQ_PROGRESS inherited from another run is that run's, never this one's.
    _ = ctx.env.swapRemove("CPUQ_PROGRESS");
    if (ctx.env.get("CPUQ_PROGRESS_AT")) |at| {
        // A copy: removing the variable frees the string the map held.
        const path = ctx.arena.dupe(u8, at) catch fail("out of memory", .{});
        _ = ctx.env.swapRemove("CPUQ_PROGRESS_AT");
        ctx.env.put("CPUQ_PROGRESS", path) catch fail("out of memory", .{});
    }
    return op.run(ctx, .{
        .tasks = o.tasks,
        .cpus = o.cpus,
        .cpus_percent = o.cpus_percent,
        .width = o.width,
        .timeout_s = o.timeout_s,
        .retries = o.retries,
        .urgent = o.urgent,
        .label = o.label,
        .note = o.note,
        .repo = repos.repoOf(ctx, o),
        .wait_max_s = o.wait_max,
        .nested = inside,
        .cmd = o.cmd,
    });
}

/// The cgroup folder of a unit in this user's systemd under `cpuq.slice`.
fn unitCgroup(a: std.mem.Allocator, unit: []const u8) ?[:0]const u8 {
    const uid = std.c.getuid();
    return a.printSentinel("/sys/fs/cgroup/user.slice/user-{d}.slice/user@{d}.service/cpuq.slice/{s}", .{ uid, uid, unit }, 0) catch null;
}

/// The first option given that cpuq does not take (hook.removed_options: `cpuq run`'s and
/// `cpuq lease`'s alike), with what replaces it; null when none is.
pub fn removedOption(args: []const [:0]const u8, lease: bool) ?[]const u8 {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--")) return null;
        if (arg.len == 0 or arg[0] != '-') return null;
        const name = std.mem.sliceTo(arg, '=');
        if (lease and std.mem.eql(u8, name, "--exclusive")) return hook.lease_exclusive;
        for (hook.removed_options) |g| if (std.mem.eql(u8, name, g[0])) return g[1];
    }
    return null;
}

/// `--driver`: a runner that only starts other `cpuq run`s (a test runner, swarm). It holds no
/// CPU and takes no turn: each run it starts takes its own. It runs with the terminal, and its
/// exit status (or signal) is the run's. On Linux, with `cgroups`, it runs in a delegated systemd
/// scope of its own, so `cpuq cap` can give each program it starts a cgroup of its own
/// (CPUQ_CGROUP); whatever it leaves there is stopped when it ends.
fn runDriver(ctx: *Ctx, o: RunOptions) u8 {
    const exe = findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return exit_notfound;
    };
    _ = ctx.env.swapRemove("CPUQ_OP");
    const argv = ctx.arena.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch fail("out of memory", .{});
    for (o.cmd, 0..) |a, i| argv[i] = a.ptr;
    const unit = ctx.arena.print("cpuq-driver-{d}", .{sys.getpid()}) catch fail("out of memory", .{});
    const scoped = if (ctx.cfg.cgroups) scopedArgv(ctx, exe, argv, unit) else null;
    // After scopedArgv, which may give the environment the user's XDG_RUNTIME_DIR.
    const envp = ctx.env.createPosixBlock(ctx.arena, .{}) catch fail("out of memory", .{});
    // Where that scope's cgroup is: when the runner ends, whatever it left in it is stopped.
    const kill_path: ?[:0]const u8 = if (scoped != null) unitCgroup(ctx.arena, ctx.arena.print("{s}.scope/cgroup.kill", .{unit}) catch "") else null;
    sys.installForwarding();
    const spawned = if (scoped) |sv| sys.spawn(sv[0].?, sv, @ptrCast(envp.slice.ptr), .unchanged, .{ .pdeath = true }) else sys.spawn(exe, argv.ptr, @ptrCast(envp.slice.ptr), .unchanged, .{ .pdeath = true });
    const pid = spawned catch |err| {
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        return if (err == error.FileNotFound) exit_notfound else exit_noexec;
    };
    sys.setChild(pid);
    const w = op.watchDriver(ctx, o.label, runopts.joinCommand(ctx, o.cmd), pid);
    if (kill_path) |kp| _ = writeSmall(kp, "1");
    switch (w.exit) {
        .code => |c| return c,
        .signal => |sig| sys.dieBySignal(sig),
    }
}

/// `--tethered`: the caller (a `cpuq run --on` on another machine) sends heartbeats down stdin.
/// Once they stop (the caller killed, or the connection lost), the run is ended as if by SIGTERM:
/// a waiting run gives up, a running one stops its tasks. The command gets /dev/null for stdin.
fn tether() void {
    sys.StdinWatch.startAside();
    // Started with cpuq's signals held, so they never reach this thread.
    const before = sys.holdHandled();
    defer sys.restoreSignals(before);
    const t = std.Thread.spawn(.{}, untether, .{}) catch return;
    t.detach();
}

fn untether() void {
    // Heartbeats come every 10 s; three missed is gone.
    sys.StdinWatch.untilGone(35_000);
    std.debug.print("cpuq: whoever ran this here has gone (killed, or the connection lost); stopping it\n", .{});
    _ = std.c.kill(sys.getpid(), .TERM);
}

/// `systemd-run --user --scope -p Delegate=yes ... -- cpuq _job -- EXE ARGS...` when this is
/// Linux with a user systemd that can make scopes; else null, and the command runs as it is.
/// systemd-run and `cpuq _job` exec the command in place, so its pid stays the same. Whether
/// scopes work is probed once and remembered for ten minutes ("scopes-ok" in the state
/// directory), so a run never fails for want of one.
fn scopedArgv(ctx: *Ctx, exe: [:0]const u8, argv: [:null]?[*:0]const u8, unit: []const u8) ?[*:null]const ?[*:0]const u8 {
    if (@import("builtin").os.tag != .linux) return null;
    const run = findExecutable(ctx, "systemd-run") orelse return null;
    const scopes = scopesWork(ctx, run);
    if (scopes == .none) return null;
    const a = ctx.arena;
    const self = selfExe(a) orelse return null;
    var head: std.ArrayList([]const u8) = .empty;
    head.appendSlice(a, &.{ run, "--user", "--scope", "--quiet", "--collect" }) catch return null;
    // systemd 254 and later expand $VAR and ${VAR} in the command line themselves, before
    // the command's shell sees it: `sh -c 'echo ${x%/job}'` would fail, or quietly change.
    if (scopes == .literal) head.append(a, "--expand-environment=no") catch return null;
    // A cgroup OOM inside it (a capped program's) is the program's business: the runner goes on.
    head.appendSlice(a, &.{ "--property=Delegate=yes", "--property=OOMPolicy=continue", "--slice=cpuq.slice" }) catch return null;
    head.append(a, a.print("--unit={s}", .{unit}) catch return null) catch return null;
    head.appendSlice(a, &.{ "--", self, "_job", "--" }) catch return null;
    const out = a.allocSentinel(?[*:0]const u8, head.items.len + 1 + argv.len - 1, null) catch return null;
    for (head.items, 0..) |h, i| out[i] = (a.dupeSentinel(u8, h, 0) catch return null).ptr;
    out[head.items.len] = exe.ptr;
    for (argv[1..], 0..) |v, i| out[head.items.len + 1 + i] = v;
    return out.ptr;
}

/// This binary's own path (Linux: /proc/self/exe), for `cpuq _job`. A cpuq
/// replaced while this one waited in the queue reads "PATH (deleted)": the
/// new binary at PATH runs `_job` as well.
fn selfExe(a: std.mem.Allocator) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const n = std.c.readlink("/proc/self/exe", &buf, buf.len);
    if (n <= 0) return null;
    const path = buf[0..@intCast(n)];
    return a.dupe(u8, if (std.mem.endsWith(u8, path, " (deleted)")) path[0 .. path.len - " (deleted)".len] else path) catch null;
}

/// `cpuq _job -- EXE ARGS...`, run by systemd-run inside a `--driver`'s delegated
/// scope: moves itself into the scope's `job/`, enables the memory and pids
/// controllers for the scope's children (which needs the scope's own cgroup
/// empty of processes, hence the move), exports the scope as CPUQ_CGROUP for
/// `cpuq cap`, and execs the command in place. If any of that fails, the
/// command runs anyway, without CPUQ_CGROUP: caps then watch the slow way.
pub fn cmdJob(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var i: usize = 0;
    if (i < args.len and std.mem.eql(u8, args[i], "--")) i += 1;
    if (i >= args.len) return usageError("_job needs -- EXE [ARGS...]", .{});
    const a = ctx.arena;
    if (@import("builtin").os.tag == .linux) delegate: {
        var buf: [1024]u8 = undefined;
        const fd = std.c.open("/proc/self/cgroup", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) break :delegate;
        const n = std.c.read(fd, &buf, buf.len);
        _ = std.c.close(fd);
        if (n <= 0) break :delegate;
        const text: []const u8 = buf[0..@intCast(n)];
        const line = std.mem.sliceTo(text[(std.mem.find(u8, text, "0::") orelse break :delegate) + 3 ..], '\n');
        const scope = a.print("/sys/fs/cgroup{s}", .{line}) catch break :delegate;
        const job = a.printSentinel("{s}/job", .{scope}, 0) catch break :delegate;
        if (std.c.mkdir(job, 0o755) != 0 and std.c.errno(-1) != .EXIST) break :delegate;
        if (!writeSmall(a.printSentinel("{s}/job/cgroup.procs", .{scope}, 0) catch break :delegate, "0")) break :delegate;
        if (!writeSmall(a.printSentinel("{s}/cgroup.subtree_control", .{scope}, 0) catch break :delegate, "+memory +pids")) break :delegate;
        ctx.env.put("CPUQ_CGROUP", scope) catch break :delegate;
    }
    const argv = a.allocSentinel(?[*:0]const u8, args.len - i, null) catch fail("out of memory", .{});
    for (args[i..], 0..) |v, k| argv[k] = v.ptr;
    const envp = ctx.env.createPosixBlock(a, .{}) catch fail("out of memory", .{});
    _ = std.c.execve(args[i].ptr, argv.ptr, @ptrCast(envp.slice.ptr));
    std.debug.print("cpuq: {s}: can't be run\n", .{args[i]});
    return if (std.c.errno(-1) == .NOENT) exit_notfound else exit_noexec;
}

fn writeSmall(path: [:0]const u8, value: []const u8) bool {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    return std.c.write(fd, value.ptr, value.len) == @as(isize, @intCast(value.len));
}

const Scopes = enum {
    none,
    /// Scopes work, and systemd-run passes the command line as it is.
    plain,
    /// Scopes work, with `--expand-environment=no` (systemd 254 and later, which expand
    /// variables in the command line otherwise).
    literal,
};

/// Whether `systemd-run --user --scope` works here, and how to keep it from
/// expanding variables in a command line: tried once, the answer kept ten
/// minutes ("scopes-ok" in the state directory, holding "literal" or
/// "plain").
fn scopesWork(ctx: *Ctx, run: [:0]const u8) Scopes {
    const io = ctx.io;
    // systemd-run --user reaches the user's systemd through XDG_RUNTIME_DIR. A cleaned
    // environment (a kit's ssh, a cron job) lacks it: take the user's own runtime directory when
    // its bus is there, else no scopes, whatever another environment found and kept.
    if (ctx.env.get("XDG_RUNTIME_DIR") == null) {
        const dir = ctx.arena.print("/run/user/{d}", .{std.c.getuid()}) catch return .none;
        const bus = ctx.arena.print("{s}/bus", .{dir}) catch return .none;
        Io.Dir.cwd().access(io, bus, .{}) catch return .none;
        ctx.env.put("XDG_RUNTIME_DIR", dir) catch return .none;
    }
    const path = std.mem.concat(ctx.arena, u8, &.{ stateDir(ctx), "/scopes-ok" }) catch return .none;
    const cwd = Io.Dir.cwd();
    if (cwd.statFile(io, path, .{})) |st| {
        const age_ns = Io.Clock.real.now(io).toNanoseconds() - st.mtime.toNanoseconds();
        var buf: [16]u8 = undefined;
        const kept = cwd.readFile(io, path, &buf) catch "";
        // A failure is kept a minute only: one probe from a shell without the user's systemd, or
        // during a hiccup, must not take every job's cgroup away for long.
        const none = std.mem.startsWith(u8, kept, "none");
        const keep_s: i96 = if (none) 60 else 600;
        if (age_ns >= 0 and age_ns < keep_s * std.time.ns_per_s) {
            if (none) return .none;
            return if (std.mem.startsWith(u8, kept, "plain")) .plain else .literal;
        }
    } else |_| {}
    const tries = [_]struct { scopes: Scopes, argv: []const []const u8 }{
        .{ .scopes = .literal, .argv = &.{ run, "--user", "--scope", "--quiet", "--collect", "--expand-environment=no", "true" } },
        .{ .scopes = .plain, .argv = &.{ run, "--user", "--scope", "--quiet", "--collect", "true" } },
    };
    for (tries) |t| {
        var child = std.process.spawn(io, .{ .argv = t.argv, .stdin = .ignore, .stdout = .ignore, .stderr = .ignore }) catch return .none;
        const term = child.wait(io) catch return .none;
        const ok = switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!ok) continue;
        cwd.writeFile(io, .{ .sub_path = path, .data = @tagName(t.scopes) }) catch {};
        return t.scopes;
    }
    // Remembered for a minute, where the user's systemd is set up (a session without
    // XDG_RUNTIME_DIR simply can't reach it, and says nothing about the machine).
    if (ctx.env.get("XDG_RUNTIME_DIR") != null) {
        cwd.writeFile(io, .{ .sub_path = path, .data = "none" }) catch {};
        if (ctx.cfg.cgroups) std.debug.print("cpuq: systemd user scopes don't work here, so test runners run without a cgroup of their own (cpuq cap then reads memory once a second)\n", .{});
    }
    return .none;
}

/// `cpuq wait --label PATTERN [--max-wait S]`: blocks until no operation here whose label
/// matches (exactly, or by prefix for a PATTERN ending in `*`) runs or waits.
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
    var pool = pool_mod.Pool.open(io, ctx.arena, stateDir(ctx)) catch |err| fail("pool: {t}", .{err});
    const start = nowSeconds(io);
    while (true) {
        var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
        defer scratch.deinit();
        pool.lock();
        const ops = pool.scan(scratch.allocator());
        pool.unlock();
        const found = for (ops) |o| {
            if (history.labelMatches(pat, o.label)) break true;
        } else false;
        if (!found) return 0;
        const now = nowSeconds(io);
        if (max_wait) |mw| if (now - start >= mw) {
            std.debug.print("cpuq: gave up after waiting {d}s for '{s}'\n", .{ now - start, pat });
            return exit_timeout;
        };
        io.sleep(.fromMilliseconds(1000), .awake) catch {};
    }
}

/// True when CPUQ_OP names a live operation here: this process runs inside one of its tasks.
fn insideOp(ctx: *Ctx) bool {
    const text = ctx.env.get("CPUQ_OP") orelse return false;
    const ticket = std.fmt.parseInt(u64, text, 10) catch return false;
    var pool = pool_mod.Pool.open(ctx.io, ctx.arena, stateDir(ctx)) catch return false;
    pool.lock();
    defer pool.unlock();
    for (pool.scan(ctx.arena)) |o| if (o.ticket == ticket) return true;
    return false;
}

/// `cpuq hook`: Claude Code's PreToolUse hook. Reads the tool call (JSON) on
/// stdin; a shell command that would load the machine outside cpuq, or misuse
/// it, is refused: the reason and the command to run instead on stderr, exit
/// 2, which the agent sees. Everything else, and anything it cannot read,
/// passes (exit 0). CPUQ_HOOK=off turns it off.
pub fn cmdHook(ctx: *Ctx) u8 {
    if (ctx.env.get("CPUQ_HOOK")) |v| if (std.mem.eql(u8, v, "off")) return 0;
    // Inside a task already: a `cpuq run` there runs on the task's CPU.
    if (insideOp(ctx)) return 0;
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
    // A pool of its own hides its load from this machine's line, except cpuq's own suite's.
    if (hook.privatePool(call.tool_input.command) and std.mem.indexOf(u8, call.tool_input.command, "# cpuq: skip") == null and !cpuqRepo(ctx, call.cwd)) {
        std.debug.print("cpuq: this command gives cpuq a pool of its own (CPUQ_DIR=...): its runs would wait in a line no one else is in, and the load they make would land on this machine's real line unseen.\nRun instead: the same command without CPUQ_DIR, so its runs share this machine's pool.\n(A command that must run as it is can end with `# cpuq: skip`.)\n", .{});
        return 2;
    }
    var advisor: HookAdvisor = .{ .ctx = ctx, .cwd = call.cwd };
    const r = hook.check(a, call.tool_input.command, project, advisor.it()) orelse return 0;
    std.debug.print("cpuq: {s}.\nRun instead: {s}\n(See AGENTS.md in the cpuq repo. A command that must run as it is can end with `# cpuq: skip`.)\n", .{ r.reason, r.instead });
    return 2;
}

/// Whether `cwd` is in a checkout of cpuq itself, whose suite runs on pools of its own.
fn cpuqRepo(ctx: *Ctx, cwd: []const u8) bool {
    var dir: []const u8 = cwd;
    while (dir.len > 1) : (dir = std.fs.path.dirname(dir) orelse return false) {
        const p = std.fs.path.join(ctx.arena, &.{ dir, "src", "hook.zig" }) catch return false;
        const t = std.fs.path.join(ctx.arena, &.{ dir, "test", "run.sh" }) catch return false;
        Io.Dir.cwd().access(ctx.io, p, .{}) catch continue;
        Io.Dir.cwd().access(ctx.io, t, .{}) catch continue;
        return true;
    }
    return false;
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
        const repo = repos.repoAt(ctx, h.cwd) orelse return null;
        const top = repos.gitTopAt(ctx, h.cwd);
        const found = if (top) |root| submit.specFor(a, ctx.io, root, cmd) else null;
        // Not a spec's work: placement sends it where it finishes first.
        const spec = found orelse return null;
        if (!spec.needs) return null;
        const rt = runtimes.RunTimes.load(ctx, a);
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
