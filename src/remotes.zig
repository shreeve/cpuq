//! Work on another machine: `cpuq run --on HOST` copies the repo there and runs the job through
//! its cpuq; `cpuq lease --host HOST` holds a lease there.
const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");
const gitship = @import("gitship.zig");
const history = @import("history.zig");
const layout = @import("layout.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");
const repos = @import("repos.zig");
const joblog = @import("joblog.zig");
const runner = @import("runner.zig");
const leasing = @import("leasing.zig");
const statusjson = @import("statusjson.zig");

const exit_timeout = main.exit_timeout;
const exit_failure = main.exit_failure;
const exit_noexec = main.exit_noexec;
const exit_notfound = main.exit_notfound;
const Ctx = main.Ctx;
const fail = main.fail;
const stateDir = main.stateDir;
const RunOptions = runopts.RunOptions;
const findExecutable = runopts.findExecutable;
const repoPath = runopts.repoPath;
const repoOf = repos.repoOf;
const safeName = repos.safeName;
const gitTop = repos.gitTop;
const JobLog = joblog.JobLog;
const nowFloat = joblog.nowFloat;
const historyPath = joblog.historyPath;
const newJobLog = joblog.newJobLog;
const logEvent = joblog.logEvent;
const armLastWords = joblog.armLastWords;
const logAndArm = joblog.logAndArm;
const logEnded = joblog.logEnded;
const runHere = runner.runHere;
const addLeaseEnv = leasing.addLeaseEnv;
const untilStdinCloses = leasing.untilStdinCloses;
const JsonStatus = statusjson.JsonStatus;

/// `cpuq run --on HOST`: runs on HOST whatever this machine's state: there at once
/// when it has room, else in its queue; started first if it is stopped and has a `remote_start`
/// command. A host that cannot be reached or started is an error (exit 125), not a quiet run
/// somewhere else: HOST was asked for by name.
pub fn runOn(ctx: *Ctx, o: RunOptions, host: []const u8) u8 {
    switch (probeHost(ctx, host)) {
        .room => return sendTo(ctx, o, host, a2(ctx, "--on {s}", host)),
        .full => |f| return sendTo(ctx, o, host, ctx.arena.print("--on {s}: it {s}, so the job queues there", .{ host, f.why }) catch f.why),
        .gone => {
            if (ctx.cfg.remoteStart(host) == null) {
                std.debug.print("cpuq: --on {s}: it does not answer, and the config has no remote_start.{s} to start it\n", .{ host, host });
                return exit_failure;
            }
            std.debug.print("cpuq: --on {s}: it is stopped; starting it\n", .{host});
            if (!startHost(ctx, host)) {
                std.debug.print("cpuq: --on {s}: could not start it\n", .{host});
                return exit_failure;
            }
            return sendTo(ctx, o, host, a2(ctx, "--on {s}", host));
        },
    }
}

/// A formatted line in the arena, for messages.
fn a2(ctx: *Ctx, comptime fmt: []const u8, arg: []const u8) []const u8 {
    return ctx.arena.print(fmt, .{arg}) catch arg;
}

/// A remote as `cpuq status` there describes it.
const Probe = union(enum) {
    /// Its CPUs.
    room: u32,
    /// Why not (someone waiting, its load, its gate), and its CPUs.
    full: struct { why: []const u8, cpus: u32 },
    /// No answer: down, stopped, or an older cpuq.
    gone,
};

fn probeHost(ctx: *Ctx, host: []const u8) Probe {
    const a = ctx.arena;
    const argv = [_][]const u8{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", host, "cpuq status --json --no-usage" };
    const result = std.process.run(a, ctx.io, .{ .argv = &argv }) catch return .gone;
    if (!result.term.success()) return .gone;
    const st = std.json.parseFromSliceLeaky(JsonStatus, a, result.stdout, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return .gone;
    const cpus = st.active_cores;
    if (st.waiters.len != 0) return .{ .full = .{ .why = a.print("has {d} waiting", .{st.waiters.len}) catch "is full", .cpus = cpus } };
    if (st.load_check and st.load[0] > @as(f64, @floatFromInt(st.active_cores))) return .{ .full = .{ .why = a.print("is at load {d:.1} on {d} CPUs", .{ st.load[0], st.active_cores }) catch "is full", .cpus = cpus } };
    if (!std.mem.eql(u8, st.gate.state, "open")) return .{ .full = .{ .why = "has its gate shut", .cpus = cpus } };
    return .{ .room = cpus };
}

/// Runs `host`'s `remote_start` command, one start at a time: a second
/// --on waits for the first's start and finds the host up.
fn startHost(ctx: *Ctx, host: []const u8) bool {
    const io = ctx.io;
    const a = ctx.arena;
    const cmd = ctx.cfg.remoteStart(host) orelse return false;
    const lock_path = a.print("{s}/remote-start-{s}", .{ stateDir(ctx), host }) catch return false;
    const lock = Io.Dir.cwd().createFile(io, lock_path, .{ .lock = .exclusive, .truncate = false }) catch null;
    defer if (lock) |f| f.close(io);
    if (probeHost(ctx, host) != .gone) return true;
    // Its output is about the start, not the job: to stderr.
    const script = a.print("{s} 1>&2", .{cmd}) catch return false;
    var child = std.process.spawn(io, .{ .argv = &.{ "sh", "-c", script }, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit }) catch return false;
    const term = child.wait(io) catch return false;
    return term.success();
}

/// Copies the repo to `host` and runs the job there through its cpuq.
fn sendTo(ctx: *Ctx, o: RunOptions, host: []const u8, why: []const u8) u8 {
    const io = ctx.io;
    const a = ctx.arena;
    const cwd = std.process.currentPathAlloc(io, a) catch fail("current directory: cannot read it", .{});
    const root = gitTop(ctx) orelse cwd;
    const rel = if (std.mem.startsWith(u8, cwd, root)) cwd[root.len..] else "";
    const trip_t = nowFloat(io);
    const repo_named = repoOf(ctx, o);
    const repo = repo_named orelse std.fs.path.basename(root);
    // The copy's place on the host: one per repo (and worktree) here, named by it, so each keeps
    // its own build caches between runs; beside its project's other copies, so a first one is
    // seeded from them.
    const project = if (safeName(repo)) repo else std.fs.path.basename(root);
    const dir = a.print("{s}/{s}/{s}-{x:0>8}", .{ layout.worktrees, project, std.fs.path.basename(root), @as(u32, @truncate(std.hash.Wyhash.hash(0, a.print("{s}\x00{s}", .{ shortHost(a), root }) catch root))) }) catch fail("out of memory", .{});
    std.debug.print("cpuq: {s}; running {s} on {s}\n", .{ why, if (o.label.len != 0) o.label else o.cmd[0], host });

    // What goes beyond the tracked files: --include paths and the repo's .cpuqinclude list, each
    // included (with the folders above it) ahead of the rules that leave out .git and what
    // .gitignore names; rsync takes the first rule that matches.
    var sync: std.ArrayList([]const u8) = .empty;
    sync.appendSlice(a, &.{ "rsync", "-a", "--delete" }) catch fail("out of memory", .{});
    var ship_git = false;
    for (includeList(ctx, root, o)) |path| {
        // `.git` ships as a git of the copy's own (shipGit), never as it is here.
        if (std.mem.eql(u8, path, ".git")) {
            ship_git = true;
            continue;
        }
        var parts = std.mem.splitScalar(u8, path, '/');
        var above: std.ArrayList(u8) = .empty;
        while (parts.next()) |part| {
            if (parts.peek() == null) break;
            above.print(a, "/{s}", .{part}) catch {};
            sync.append(a, a.print("--include={s}/", .{above.items}) catch "") catch {};
        }
        const is_dir = if (Io.Dir.cwd().statFile(io, a.print("{s}/{s}", .{ root, path }) catch "", .{})) |st| st.kind == .directory else |_| true;
        sync.append(a, a.print("--include=/{s}{s}", .{ path, if (is_dir) "/***" else "" }) catch "") catch {};
    }
    sync.appendSlice(a, &.{ "--exclude=/.git", "--exclude=/.cpuq-used" }) catch fail("out of memory", .{});
    // What .gitignore leaves out: in a git repo, as git itself reads it (its `!` lines, nested
    // .gitignore files, the global excludes; a tracked file ships whatever matches it), which
    // rsync's own .gitignore filter gets wrong; elsewhere, that filter.
    const excludes = if (gitTop(ctx) != null) gitIgnored(ctx, root) else null;
    defer if (excludes) |f| Io.Dir.cwd().deleteFile(io, f) catch {};
    sync.append(a, if (excludes) |f| a.print("--exclude-from={s}", .{f}) catch "" else "--filter=:- .gitignore") catch fail("out of memory", .{});
    // And there, what .gitignore names stays, though it isn't here: the build cache made there
    // by the last run (or brought by a new copy's clone).
    const keeps = if (excludes != null) gitKept(ctx, root) else null;
    defer if (keeps) |f| Io.Dir.cwd().deleteFile(io, f) catch {};
    const keep_at = sync.items.len;
    if (keeps) |f| sync.append(a, a.print("--filter=merge {s}", .{f}) catch "") catch {};
    sync.appendSlice(a, &.{
        // A first copy there starts as a clone of another of this repo's (gitship.seedPath).
        a.print("--rsync-path={s}", .{gitship.seedPath(a, dir, ship_git)}) catch "", a.print("{s}/", .{root}) catch "",
        a.print("{s}:{s}/", .{ host, dir }) catch "",
    }) catch fail("out of memory", .{});
    var copied = std.process.run(a, io, .{ .argv = sync.items }) catch |err| fail("rsync: {t}", .{err});
    // What's kept there can stand in the way (a folder there where a file is here), which only
    // a sync that keeps none of it clears.
    if (!gitship.copied(copied.term) and keeps != null) {
        _ = sync.orderedRemove(keep_at);
        copied = std.process.run(a, io, .{ .argv = sync.items }) catch |err| fail("rsync: {t}", .{err});
    }
    const failed: ?[]const u8 = if (!gitship.copied(copied.term)) std.mem.trim(u8, copied.stderr, " \n") else if (shipChecked(ctx, sync.items, host)) |e| e else if (ship_git) shipGit(ctx, root, host, dir) else null;
    if (failed) |err_text| {
        // Sent there by name, a job never runs here: it was sized for that host.
        if (o.on != null) {
            std.debug.print("cpuq: could not copy {s} to {s}: {s}; --on runs it nowhere else\n", .{ root, host, err_text });
            return exit_failure;
        }
        std.debug.print("cpuq: could not copy {s} to {s}: {s}; running here\n", .{ root, host, err_text });
        return runHere(ctx, o);
    }

    // ssh joins its arguments into one line for the remote shell, so
    // everything is quoted for it.
    var remote: std.ArrayList(u8) = .empty;
    // `.cpuq-used`: when a job last ran in the copy, which `cpuq clean` goes by, and whose copy
    // it is, for the next new copy of that repo to start from.
    remote.print(a, "cd {s} && printf %s {s} >|.cpuq-used && ", .{ shellQuote(a, dir), shellQuote(a, repo) }) catch fail("out of memory", .{});
    if (rel.len != 0) remote.print(a, "cd {s} && ", .{shellQuote(a, a.print(".{s}", .{rel}) catch ".")}) catch {};
    // `remote_env.HOST`: the user's own shell assignments, expanded there (an ssh command's
    // shell reads no login profile, so ~/.local tools are off its PATH).
    if (ctx.cfg.remoteEnv(host)) |env| remote.print(a, "export {s} && ", .{env}) catch {};
    // The repo's name for its history there (the copy's folder is named by the worktree).
    if (repo_named) |r| remote.print(a, "export CPUQ_REPO={s} && ", .{shellQuote(a, r)}) catch {};
    remote.print(a, "exec cpuq run --tethered --priority {t}", .{o.priority}) catch fail("out of memory", .{});
    if (o.label.len != 0) remote.print(a, " --label {s}", .{shellQuote(a, o.label)}) catch {};
    // Without --note, the worktree it came from: every job on another machine says what it's for.
    const job_note = if (o.note.len != 0) o.note else std.fs.path.basename(root);
    if (job_note.len != 0) remote.print(a, " --note {s}", .{shellQuote(a, job_note)}) catch {};
    if (o.cores_given) remote.print(a, " --cores {d}-{d}", .{ o.request.min, o.request.max }) catch {};
    if (o.max_wait) |mw| remote.print(a, " --max-wait {d}", .{mw}) catch {};
    if (!o.load_check) remote.appendSlice(a, " --no-load-check") catch {};
    if (!o.qos) remote.appendSlice(a, " --qos none") catch {};
    if (o.hidden) remote.appendSlice(a, " --opaque") catch {};
    remote.appendSlice(a, " --") catch {};
    for (o.cmd) |arg| remote.print(a, " {s}", .{shellQuote(a, arg)}) catch {};
    // Kept here too, as pool "spill": how long the trip took (copy, queue and run), which
    // placement goes by next time.
    var job = newJobLog(ctx, o);
    job.base.pool = "spill";
    job.base.host = host;
    job.base.repo = repo_named;
    logSpill(ctx, job, "queued", trip_t, null);
    logSpill(ctx, job, "started", trip_t, null);
    const argv = [_][]const u8{ "ssh", "-o", "BatchMode=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", host, remote.items };
    var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .pipe, .stdout = .inherit, .stderr = .inherit }) catch |err|
        fail("ssh {s}: {t}", .{ host, err });
    // Heartbeats down the connection: the run on the host stops its job
    // when they stop, as when this cpuq is killed or the connection dies.
    var heart: sys.Heartbeat = .{ .fd = child.stdin.?.handle };
    heart.start();
    const term = child.wait(io) catch std.process.Child.Term{ .unknown = 0 };
    heart.stop();
    const code: u8 = switch (term) {
        .exited => |c| c,
        else => exit_failure,
    };
    // Its own status is the command's; 75, 125 and 255 are cpuq's or ssh's, not a run.
    logSpill(ctx, job, if (code == exit_timeout or code == exit_failure or code == 255) "gave_up" else "ended", nowFloat(io), code);
    // 255 is ssh's own failure; a death by signal can be the host shutting
    // down under the job (a Spot reclaim powers the VM off gracefully, and
    // the shutdown kills the job before the connection drops). Either way,
    // give a host that is going a moment to go, and if it has, run the job
    // again, on that host or nowhere.
    if ((code == 255 or code > 128) and hostWentAway(ctx, host)) {
        const who = if (o.label.len != 0) o.label else o.cmd[0];
        // Sent there by name: start it again and run there once more, as a Spot VM reclaimed is
        // usually back a minute later. Never here: a job sized for that host (--cores 8-48 for 96
        // CPUs) would swamp this machine.
        if (!runner.send_retried and ctx.cfg.remoteStart(host) != null) {
            std.debug.print("cpuq: lost {s} while {s} ran there; starting it again\n", .{ host, who });
            runner.send_retried = true;
            if (startHost(ctx, host)) return sendTo(ctx, o, host, "running again");
        }
        std.debug.print("cpuq: lost {s} while {s} ran there, and --on runs it nowhere else: run it again when {s} is back\n", .{ host, who, host });
        return exit_failure;
    }
    for (o.returns[0..o.return_count]) |path| {
        const back = [_][]const u8{ "rsync", "-a", "--relative", a.print("{s}:{s}{s}/./{s}", .{ host, dir, rel, path }) catch "", "./" };
        const r = std.process.run(a, io, .{ .argv = &back }) catch null;
        if (r == null or !gitship.copied(r.?.term)) std.debug.print("cpuq: could not copy {s} back from {s}\n", .{ path, host });
    }
    return code;
}

/// One event of a spilled job's record here, at `t`.
fn logSpill(ctx: *Ctx, job: JobLog, event: []const u8, t: f64, code: ?u8) void {
    const path = historyPath(ctx);
    if (path.len == 0) return;
    var ev = job.base;
    ev.event = event;
    ev.id = job.id;
    ev.t = t;
    if (std.mem.eql(u8, event, "ended")) ev.exit = code;
    history.append(ctx.io, path, ev);
}

/// Whether `host` stopped answering after a job there ended badly: looked
/// at twice, 5 seconds apart, since a host shutting down can still answer
/// at first.
fn hostWentAway(ctx: *Ctx, host: []const u8) bool {
    for (0..2) |_| {
        ctx.io.sleep(.fromSeconds(5), .awake) catch {};
        if (probeHost(ctx, host) == .gone) return true;
    }
    return false;
}

/// The copy `sync` made on `host`, read back by checksum (gitship.check): the error text when it
/// still differs from here, else null. A file that differed and was mended is said on stderr.
fn shipChecked(ctx: *Ctx, sync: []const []const u8, host: []const u8) ?[]const u8 {
    return switch (gitship.check(ctx.arena, ctx.io, sync)) {
        .same => null,
        .repaired => |names| {
            std.debug.print("cpuq: the copy on {s} differed from here ({s}): sent again, and now the same\n", .{ host, names });
            return null;
        },
        .differs => |names| ctx.arena.print("the copy there still differs from here after sending it again ({s}); its disk may be damaging files, not your code", .{names}) catch "the copy there differs from here",
    };
}

/// `.git` included (`--include .git`, or a `.git` line in `.cpuqinclude`): the copy gets a git of
/// its own, git's parts only (gitship.zig). The error text when it fails, else null.
fn shipGit(ctx: *Ctx, root: []const u8, host: []const u8, dir: []const u8) ?[]const u8 {
    const a = ctx.arena;
    const e = gitship.ship(a, ctx.io, "rsync", root, host, a.print("{s}/.git", .{dir}) catch return "out of memory") orelse return null;
    return a.print("--include .git: {s}", .{e}) catch e;
}

/// The paths a job sent with --on takes beyond the tracked files: its --include paths, then the
/// repo's `.cpuqinclude` list (a path a line, `#` comments), each inside the repo. Trailing slashes are
/// dropped; anything else is said and skipped.
fn includeList(ctx: *Ctx, root: []const u8, o: RunOptions) []const []const u8 {
    const a = ctx.arena;
    var out: std.ArrayList([]const u8) = .empty;
    for (o.includes[0..o.include_count]) |p| out.append(a, std.mem.trimEnd(u8, p, "/")) catch {};
    const list = a.print("{s}/.cpuqinclude", .{root}) catch return out.items;
    const text = Io.Dir.cwd().readFileAlloc(ctx.io, list, a, .limited(1 << 16)) catch return out.items;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, std.mem.trim(u8, if (std.mem.findScalar(u8, raw, '#')) |i| raw[0..i] else raw, " \t\r"), "/");
        if (line.len == 0) continue;
        if (!repoPath(line)) {
            std.debug.print("cpuq: .cpuqinclude: '{s}' is not a path inside the repo; skipped\n", .{line});
            continue;
        }
        out.append(a, line) catch {};
    }
    return out.items;
}

/// A file of rsync protect rules for what the repo's .gitignore files (and .git/info/exclude)
/// name (gitship.kept), or null when there are none.
fn gitKept(ctx: *Ctx, root: []const u8) ?[]const u8 {
    const a = ctx.arena;
    var out: std.ArrayList(u8) = .empty;
    const r = std.process.run(a, ctx.io, .{ .argv = &.{ "git", "-C", root, "ls-files", "-z", "--", "*.gitignore" } }) catch return null;
    if (r.term.success()) {
        var paths = std.mem.splitScalar(u8, r.stdout, 0);
        while (paths.next()) |path| {
            if (!std.mem.eql(u8, std.fs.path.basename(path), ".gitignore")) continue;
            const text = Io.Dir.cwd().readFileAlloc(ctx.io, a.print("{s}/{s}", .{ root, path }) catch continue, a, .limited(1 << 20)) catch continue;
            out.appendSlice(a, gitship.kept(a, std.fs.path.dirname(path) orelse "", text)) catch {};
        }
    }
    const info = std.process.run(a, ctx.io, .{ .argv = &.{ "git", "-C", root, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude" } }) catch null;
    if (info) |i| if (i.term.success()) {
        if (Io.Dir.cwd().readFileAlloc(ctx.io, std.mem.trim(u8, i.stdout, " \n"), a, .limited(1 << 20))) |text| out.appendSlice(a, gitship.kept(a, "", text)) catch {} else |_| {}
    };
    if (out.items.len == 0) return null;
    const tmp = ctx.env.get("TMPDIR") orelse "/tmp";
    const file = a.print("{s}/cpuq-send-{d}.keep", .{ std.mem.trimEnd(u8, tmp, "/"), sys.getpid() }) catch return null;
    Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = file, .data = out.items }) catch return null;
    return file;
}

/// The untracked files git ignores in the repo at `root`, as an rsync exclude file of anchored
/// patterns (an ignored folder whole, as `dir/`), written to a temporary file the caller deletes;
/// null when git can't say.
fn gitIgnored(ctx: *Ctx, root: []const u8) ?[]const u8 {
    const a = ctx.arena;
    const r = std.process.run(a, ctx.io, .{ .argv = &.{ "git", "-C", root, "ls-files", "-o", "-i", "--exclude-standard", "--directory", "-z" } }) catch return null;
    if (!r.term.success()) return null;
    var out: std.ArrayList(u8) = .empty;
    var paths = std.mem.splitScalar(u8, r.stdout, 0);
    while (paths.next()) |path| {
        if (path.len == 0 or std.mem.findScalar(u8, path, '\n') != null) continue;
        out.append(a, '/') catch return null;
        // A wildcard in a name is matched as itself: rsync reads `\` before one as a plain char.
        const wild = std.mem.findAny(u8, path, "*?[\\") != null;
        for (path) |ch| {
            if (wild and std.mem.findScalar(u8, "*?[\\", ch) != null) out.append(a, '\\') catch return null;
            out.append(a, ch) catch return null;
        }
        // An ignored folder (git's `dir/`), with all it holds: a path shipped from inside it
        // (--include) is included by an earlier rule, and the rest stays behind.
        if (path[path.len - 1] == '/') out.appendSlice(a, "***") catch return null;
        out.append(a, '\n') catch return null;
    }
    const tmp = ctx.env.get("TMPDIR") orelse "/tmp";
    const file = a.print("{s}/cpuq-send-{d}.exclude", .{ std.mem.trimEnd(u8, tmp, "/"), sys.getpid() }) catch return null;
    Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = file, .data = out.items }) catch return null;
    return file;
}

/// `cpuq lease NAME --host HOST -- CMD`: holds NAME on HOST's cpuq through
/// `ssh HOST cpuq lease NAME --hold` and runs CMD here meanwhile. Closing
/// the connection gives the lease back, and so does the connection dying.
///
/// With `--hold` and no command, it holds the lease for a script instead:
/// once granted it prints `held NAME@HOST ENTRY`, ENTRY being the
/// CPUQ_LEASES entry (`NAME@HOST=ID:PID`) that makes runs inside see the
/// lease as theirs, and holds it until its stdin closes or it dies.
pub fn runRemote(ctx: *Ctx, o: RunOptions, host: []const u8) u8 {
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
    logAndArm(ctx, job, "queued", .{}, "gave_up", null);
    var child = std.process.spawn(io, .{ .argv = &argv, .stdin = .pipe, .stdout = .pipe, .stderr = .inherit }) catch |err|
        fail("ssh {s}: {t}", .{ host, err });
    // Heartbeats down the connection, so the hold on HOST knows this end is
    // here, waiting or holding, and gives up when they stop.
    var heart: sys.Heartbeat = .{ .fd = child.stdin.?.handle };
    heart.start();

    // The held line: `held NAME ID`.
    var rbuf: [256]u8 = undefined;
    var r = child.stdout.?.readerStreaming(io, &rbuf);
    const line = r.interface.takeDelimiterExclusive('\n') catch "";
    var words = std.mem.tokenizeScalar(u8, line, ' ');
    const word = words.next() orelse "";
    _ = words.next();
    const id = words.next() orelse "";
    if (!std.mem.eql(u8, word, "held") or id.len == 0) {
        heart.stop();
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

    logAndArm(ctx, job, "started", .{ .cores = 1 }, "ended", 1);
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
        heart.stop();
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
    heart.stop();
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
pub fn shellQuote(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '\'') catch fail("out of memory", .{});
    for (s) |ch| {
        if (ch == '\'') out.appendSlice(a, "'\\''") catch fail("out of memory", .{}) else out.append(a, ch) catch fail("out of memory", .{});
    }
    out.append(a, '\'') catch fail("out of memory", .{});
    return out.items;
}

/// `cpuq first|start|cancel|pause|resume|stop TARGET [--all] [--host HOST]`: a hand at the
/// queue. TARGET is a label (`PATTERN*` for a prefix) or a cpuq pid. first,
pub fn isSelf(a: std.mem.Allocator, host: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, shortHost(a));
}

fn shortHost(a: std.mem.Allocator) []const u8 {
    var buf: [256]u8 = undefined;
    if (std.c.gethostname(&buf, buf.len) != 0) return "here";
    const full = std.mem.sliceTo(&buf, 0);
    return a.dupe(u8, full[0 .. std.mem.findScalar(u8, full, '.') orelse full.len]) catch "here";
}
