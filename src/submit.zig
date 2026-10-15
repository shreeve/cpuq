//! `cpuq submit`: a job described by a spec in its repo, run on a machine cpuq picks, owned by
//! that machine, and followed from here. docs/SUBMIT.md is the design; in short:
//!
//!   here (the submitting machine)            the host (here too, for "here")
//!   cpuq submit SPEC: digests, attach rules
//!   _supervise ID (detached): place  ──────> _start ID PAYLOAD: files, then _job ID (detached)
//!                                            _job ID: job lock, copy lock, "ready"
//!                              rsync ──────> the copy; _synced ID GEN
//!                                            _job: tools, cpuq run -- cpuq cap -- sh -c ...
//!                    poll _peek ID <──────── state, progress, result.json
//!                    fetch result, tail, return
//!   cpuq job ID --wait: follows the local state the supervisor writes
//!
//! Every file lives under the state directory (`~/.local/state/cpuq/jobs/ID/`), on both sides.

const std = @import("std");
const Io = std.Io;
const c = std.c;
const policy = @import("policy.zig");
const sys = @import("sys.zig");

pub const Cx = struct {
    io: Io,
    a: std.mem.Allocator,
    env: *std.process.Environ.Map,
    out: *Io.Writer,
    version: []const u8,
    cfg: *const policy.Config,
    /// This binary's path, to run its own helpers here.
    self: []const u8,
};

/// The oldest cpuq a host may run to take submitted jobs (it has _start, _job, _peek).
const host_min = [3]u32{ 0, 18, 0 };

// --- Exit codes: verdicts, never the job's own ----------------------------------------------

const Verdict = enum {
    pass,
    fail,
    timeout,
    oom,
    not_run,
    not_started,
    lost,
    cancelled,
    cpuq_error,
    running,

    fn word(v: Verdict) []const u8 {
        return switch (v) {
            .pass => "PASS",
            .fail => "FAIL",
            .timeout => "TIMEOUT",
            .oom => "OOM",
            .not_run => "NOT RUN",
            .not_started => "NOT STARTED",
            .lost => "LOST",
            .cancelled => "CANCELLED",
            .cpuq_error => "CPUQ ERROR",
            .running => "RUNNING",
        };
    }

    fn exit(v: Verdict) u8 {
        return switch (v) {
            .pass => 0,
            .fail => 1,
            .not_started => 2,
            .running => 3,
            .lost => 69,
            .not_run => 75,
            .cancelled => 76,
            .oom => 122,
            .timeout => 124,
            .cpuq_error => 125,
        };
    }

    fn parse(s: []const u8) Verdict {
        return std.meta.stringToEnum(Verdict, s) orelse .cpuq_error;
    }
};

// --- The spec ------------------------------------------------------------------------------

const Map = std.json.ArrayHashMap([]const u8);

const Spec = struct {
    label: []const u8,
    run: []const u8,
    setup: ?[]const u8 = null,
    cores: ?[]const u8 = null,
    on: []const []const u8 = &.{"here"},
    time: ?[]const u8 = null,
    mem: ?[]const u8 = null,
    tools: ?Map = null,
    env: ?Map = null,
    exclude: []const []const u8 = &.{},
    deps: ?Map = null,
    caches: ?Map = null,
    report: ?[]const u8 = null,
    @"return": []const []const u8 = &.{},
};

/// What goes to the host: the spec as this job runs it, resolved.
const Payload = struct {
    id: []const u8,
    label: []const u8,
    note: []const u8 = "",
    project: []const u8,
    setup: ?[]const u8 = null,
    run: []const u8,
    cores: ?[]const u8 = null,
    time: ?[]const u8 = null,
    mem: ?[]const u8 = null,
    tools: ?Map = null,
    env: ?Map = null,
    caches: ?Map = null,
    report: ?[]const u8 = null,
    args: []const []const u8 = &.{},
    /// The copy, relative to the host's home: cpuq-spill/w/PROJECT/ID12.
    copy: []const u8,
    generation: []const u8,
    digest: []const u8,
    attempt: u32 = 1,
};

/// The job as the submitting machine keeps it (job.json).
const Record = struct {
    id: []const u8,
    label: []const u8,
    note: []const u8 = "",
    spec: []const u8,
    dir: []const u8,
    digest: []const u8,
    snapshot: []const u8,
    host: ?[]const u8 = null,
    created: i64,
    attempt: u32 = 1,
    copy: []const u8,
    exclude: []const []const u8 = &.{},
    @"return": []const []const u8 = &.{},
    deps: ?Map = null,
    on: []const []const u8 = &.{},
    payload: []const u8,
};

const Failure = struct {
    id: []const u8 = "",
    reason: []const u8 = "",
    artifact: []const u8 = "",
};

/// result.json: what a finished job comes to.
const Result = struct {
    verdict: []const u8,
    label: []const u8 = "",
    digest: []const u8 = "",
    host: []const u8 = "",
    code: ?i64 = null,
    seconds: f64 = 0,
    cores: []const u8 = "",
    total: u64 = 0,
    ok: u64 = 0,
    failed: u64 = 0,
    failures: []const Failure = &.{},
    detail: []const u8 = "",
};

// --- Small helpers ---------------------------------------------------------------------------

fn fail2(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("cpuq submit: " ++ fmt ++ "\n", args);
    return 2;
}

fn now(io: Io) i64 {
    return @intCast(@divTrunc(Io.Clock.real.now(io).toNanoseconds(), std.time.ns_per_s));
}

fn sleepMs(io: Io, ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

fn stateRoot(cx: Cx) []const u8 {
    if (cx.env.get("XDG_STATE_HOME")) |x| return cx.a.print("{s}/cpuq", .{x}) catch "";
    return cx.a.print("{s}/.local/state/cpuq", .{cx.env.get("HOME") orelse "/tmp"}) catch "";
}

fn jobDir(cx: Cx, id: []const u8) []const u8 {
    return cx.a.print("{s}/jobs/{s}", .{ stateRoot(cx), id }) catch "";
}

fn jobFile(cx: Cx, id: []const u8, name: []const u8) []const u8 {
    return cx.a.print("{s}/{s}", .{ jobDir(cx, id), name }) catch "";
}

fn home(cx: Cx) []const u8 {
    return cx.env.get("HOME") orelse "/tmp";
}

fn readFile(cx: Cx, path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(cx.io, path, cx.a, .limited(64 << 20)) catch null;
}

/// Writes by a rename, so a reader never sees half a file.
fn writeFile(cx: Cx, path: []const u8, data: []const u8) void {
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(cx.io, d) catch {};
    const tmp = cx.a.print("{s}.new", .{path}) catch return;
    cwd.writeFile(cx.io, .{ .sub_path = tmp, .data = data }) catch return;
    cwd.rename(tmp, cwd, path, cx.io) catch {};
}

fn jsonString(cx: Cx, value: anytype) []const u8 {
    var w: Io.Writer.Allocating = .init(cx.a);
    std.json.Stringify.value(value, .{}, &w.writer) catch return "{}";
    return w.written();
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 32) return false;
    for (id) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

/// A path inside the directory: relative, no `..`, not empty.
fn inside(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/') return false;
    var it = std.mem.splitScalar(u8, p, '/');
    while (it.next()) |part| if (std.mem.eql(u8, part, "..")) return false;
    return true;
}

fn hex(cx: Cx, bytes: []const u8) []const u8 {
    const out = cx.a.alloc(u8, bytes.len * 2) catch return "";
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[2 * i] = digits[b >> 4];
        out[2 * i + 1] = digits[b & 15];
    }
    return out;
}

fn sha(cx: Cx, parts: []const []const u8) []const u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    for (parts) |p| {
        h.update(p);
        h.update("\x00");
    }
    var d: [32]u8 = undefined;
    h.final(&d);
    return hex(cx, &d);
}

const Ran = struct { ok: bool, code: u8, out: []const u8, err: []const u8 };

fn run(cx: Cx, argv: []const []const u8, cwd: ?[]const u8) Ran {
    const r = std.process.run(cx.a, cx.io, .{
        .argv = argv,
        .cwd = if (cwd) |d| .{ .path = d } else .inherit,
    }) catch |err| return .{ .ok = false, .code = 127, .out = "", .err = @errorName(err) };
    const code: u8 = switch (r.term) {
        .exited => |x| x,
        else => 128,
    };
    return .{ .ok = code == 0, .code = code, .out = r.stdout, .err = r.stderr };
}

/// A shell script on `host`: over ssh, or here with sh. ssh's own failure is 255.
fn onHost(cx: Cx, host: []const u8, script: []const u8) Ran {
    if (std.mem.eql(u8, host, "here")) return run(cx, &.{ "/bin/sh", "-c", script }, null);
    return run(cx, &.{ "ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, script }, null);
}

/// The cpuq to call on `host`: this binary here, `cpuq` on the host's PATH there.
fn cpuqOn(cx: Cx, host: []const u8) []const u8 {
    return if (std.mem.eql(u8, host, "here")) quote(cx, cx.self) else "cpuq";
}

fn quote(cx: Cx, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(cx.a, '\'') catch return "''";
    for (s) |ch| {
        if (ch == '\'') out.appendSlice(cx.a, "'\\''") catch {} else out.append(cx.a, ch) catch {};
    }
    out.append(cx.a, '\'') catch {};
    return out.items;
}

fn rsyncPath(cx: Cx) []const u8 {
    for ([_][]const u8{ "/opt/homebrew/bin/rsync", "/usr/local/bin/rsync", "/usr/bin/rsync" }) |p| {
        Io.Dir.cwd().access(cx.io, p, .{ .execute = true }) catch continue;
        return p;
    }
    return "rsync";
}

/// "here", or "host:" for rsync.
fn remotePrefix(cx: Cx, host: []const u8) []const u8 {
    return if (std.mem.eql(u8, host, "here")) "" else cx.a.print("{s}:", .{host}) catch "";
}

/// A copy path as rsync on this side names it: absolute here, relative to home there.
fn copyTarget(cx: Cx, host: []const u8, rel: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "here")) return cx.a.print("{s}/{s}", .{ home(cx), rel }) catch "";
    return cx.a.print("{s}:{s}", .{ host, rel }) catch "";
}

// --- The snapshot: what a job sees, and its digest ------------------------------------------

fn excluded(path: []const u8, excludes: []const []const u8) bool {
    for (excludes) |e| {
        const ex = std.mem.trimEnd(u8, e, "/");
        if (std.mem.eql(u8, path, ex)) return true;
        if (path.len > ex.len and std.mem.startsWith(u8, path, ex) and path[ex.len] == '/') return true;
    }
    return false;
}

const secret_names = [_][]const u8{ ".netrc", ".npmrc" };

fn looksSecret(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, base, ".env")) return true;
    if (std.mem.endsWith(u8, base, ".pem")) return true;
    if (std.mem.startsWith(u8, base, "id_") and !std.mem.endsWith(u8, base, ".pub") and std.mem.findScalar(u8, base, '.') == null) return true;
    for (secret_names) |n| if (std.mem.eql(u8, base, n)) return true;
    return false;
}

fn splitZ(text: []const u8) std.mem.SplitIterator(u8, .scalar) {
    return std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\x00"), 0);
}

/// The digest of a directory as a job would see it, and whether it holds something that looks
/// like a credential. Git: the index (`git ls-files -s`), the contents of modified and untracked
/// files, and the size and mtime of ignored ones; else every file's path, size and mtime.
fn snapshot(cx: Cx, dir: []const u8, excludes: []const []const u8, tracked_only: bool) struct { digest: []const u8, secret: ?[]const u8 } {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var secret: ?[]const u8 = null;
    const git = run(cx, &.{ "git", "-C", dir, "ls-files", "-s", "-z" }, null);
    if (git.ok) {
        var it = splitZ(git.out);
        while (it.next()) |line| {
            const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
            const path = line[tab + 1 ..];
            if (excluded(path, excludes)) continue;
            if (secret == null and looksSecret(path)) secret = path;
            h.update(line);
            h.update("\x00");
        }
        // Modified tracked files, and untracked ones that ship, by content.
        const changed = run(cx, &.{ "git", "-C", dir, "diff", "--name-only", "-z", "HEAD" }, null);
        const untracked = if (tracked_only) Ran{ .ok = true, .code = 0, .out = "", .err = "" } else run(cx, &.{ "git", "-C", dir, "ls-files", "-o", "--exclude-standard", "-z" }, null);
        for ([_][]const u8{ changed.out, untracked.out }) |list| {
            var files = splitZ(list);
            while (files.next()) |path| {
                if (path.len == 0 or excluded(path, excludes)) continue;
                if (secret == null and looksSecret(path)) secret = path;
                const full = cx.a.print("{s}/{s}", .{ dir, path }) catch continue;
                h.update(path);
                h.update(Io.Dir.cwd().readFileAlloc(cx.io, full, cx.a, .limited(256 << 20)) catch "(gone)");
                h.update("\x00");
            }
        }
        if (!tracked_only) {
            // Ignored files that still ship: by size and mtime (they're often large).
            const ignored = run(cx, &.{ "git", "-C", dir, "ls-files", "-o", "-i", "--exclude-standard", "-z" }, null);
            var files = splitZ(ignored.out);
            while (files.next()) |path| {
                if (path.len == 0 or excluded(path, excludes)) continue;
                if (secret == null and looksSecret(path)) secret = path;
                const full = cx.a.print("{s}/{s}", .{ dir, path }) catch continue;
                const st = Io.Dir.cwd().statFile(cx.io, full, .{}) catch continue;
                h.update(cx.a.print("{s} {d} {d}\x00", .{ path, st.size, st.mtime.toNanoseconds() }) catch "");
            }
        }
    } else {
        var d = Io.Dir.cwd().openDir(cx.io, dir, .{ .iterate = true }) catch return .{ .digest = "", .secret = null };
        defer d.close(cx.io);
        var walker = d.walk(cx.a) catch return .{ .digest = "", .secret = null };
        defer walker.deinit();
        var paths: std.ArrayList([]const u8) = .empty;
        while (walker.next(cx.io) catch null) |entry| {
            if (entry.kind != .file) continue;
            const path = cx.a.dupe(u8, entry.path) catch continue;
            if (excluded(path, excludes)) continue;
            paths.append(cx.a, path) catch {};
        }
        std.mem.sortUnstable([]const u8, paths.items, {}, struct {
            fn lt(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.lessThan(u8, x, y);
            }
        }.lt);
        for (paths.items) |path| {
            if (secret == null and looksSecret(path)) secret = path;
            const full = cx.a.print("{s}/{s}", .{ dir, path }) catch continue;
            const st = Io.Dir.cwd().statFile(cx.io, full, .{}) catch continue;
            h.update(cx.a.print("{s} {d} {d}\x00", .{ path, st.size, st.mtime.toNanoseconds() }) catch "");
        }
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return .{ .digest = hex(cx, &out), .secret = secret };
}

// --- cpuq submit ----------------------------------------------------------------------------

pub fn cmdSubmit(cx: Cx, args: []const [:0]const u8) u8 {
    var spec_path: ?[]const u8 = null;
    var extra_env: std.ArrayList([]const u8) = .empty;
    var job_args: []const []const u8 = &.{};
    var replace = false;
    var again = false;
    var max_wait: ?i64 = null;
    var note: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            const rest = cx.a.alloc([]const u8, args.len - i - 1) catch return 125;
            for (args[i + 1 ..], 0..) |x, k| rest[k] = x;
            job_args = rest;
            break;
        } else if (std.mem.eql(u8, arg, "--replace")) {
            replace = true;
        } else if (std.mem.eql(u8, arg, "--again")) {
            again = true;
        } else if (std.mem.eql(u8, arg, "--max-wait") and i + 1 < args.len) {
            i += 1;
            max_wait = std.fmt.parseInt(i64, args[i], 10) catch return fail2("--max-wait needs whole seconds, not '{s}'", .{args[i]});
        } else if (std.mem.eql(u8, arg, "--note") and i + 1 < args.len) {
            i += 1;
            note = args[i];
        } else if (std.mem.eql(u8, arg, "--env") and i + 1 < args.len) {
            i += 1;
            if (std.mem.findScalar(u8, args[i], '=') == null) return fail2("--env needs NAME=VALUE, not '{s}'", .{args[i]});
            extra_env.append(cx.a, args[i]) catch {};
        } else if (spec_path == null and !std.mem.startsWith(u8, arg, "-")) {
            spec_path = arg;
        } else return fail2("unknown option '{s}'", .{arg});
    }
    if (replace and again) return fail2("--replace and --again don't go together", .{});
    const sp = spec_path orelse return fail2("usage: cpuq submit SPEC [-- ARGS] [--env K=V]... [--note TEXT] [--replace | --again] [--max-wait S]", .{});

    // The spec, and the directory it's for: the git top of the spec's repo.
    const spec_abs = realpath(cx, sp) orelse return fail2("{s}: not found", .{sp});
    const text = readFile(cx, spec_abs) orelse return fail2("{s}: can't be read", .{sp});
    const spec = std.json.parseFromSliceLeaky(Spec, cx.a, text, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |err|
        return fail2("spec {s}: {t} (fields: label, run, setup, cores, on, time, mem, tools, env, exclude, deps, caches, report, return)", .{ sp, err });
    const top_run = run(cx, &.{ "git", "-C", std.fs.path.dirname(spec_abs) orelse ".", "rev-parse", "--show-toplevel" }, null);
    const dir = if (top_run.ok) std.mem.trim(u8, top_run.out, " \n") else (std.fs.path.dirname(spec_abs) orelse ".");
    if (std.mem.findScalar(u8, spec.label, ':') == null) return fail2("spec {s}: \"label\" must be project:task, not '{s}'", .{ sp, spec.label });
    if (spec.on.len == 0) return fail2("spec {s}: \"on\" names no host", .{sp});
    if (spec.cores) |cr| if (policy.Request.parse(cr) == null) return fail2("spec {s}: \"cores\" must be N or MIN-MAX, not '{s}'", .{ sp, cr });
    if (spec.time) |t| if (@import("cap.zig").parseDuration(t) == null) return fail2("spec {s}: \"time\" must be a duration like 90m, not '{s}'", .{ sp, t });
    if (spec.mem) |m| if (policy.parseBytes(m) == null) return fail2("spec {s}: \"mem\" must be a size like 64G, not '{s}'", .{ sp, m });
    for (spec.exclude) |p| if (!inside(p)) return fail2("spec {s}: \"exclude\" paths are relative, without .., not '{s}'", .{ sp, p });
    for (spec.@"return") |p| if (!inside(p)) return fail2("spec {s}: \"return\" paths are relative, without .., not '{s}'", .{ sp, p });
    if (spec.report) |p| if (!inside(p)) return fail2("spec {s}: \"report\" is relative, without .., not '{s}'", .{ sp, p });
    if (!underRoots(cx, dir)) return fail2("{s} isn't under submit_roots ({s})", .{ dir, roots(cx) });

    // Deps: sources under the roots, targets inside the copy.
    var excludes: std.ArrayList([]const u8) = .empty;
    excludes.appendSlice(cx.a, spec.exclude) catch {};
    excludes.appendSlice(cx.a, spec.@"return") catch {};
    excludes.append(cx.a, ".cpuq-generation") catch {};
    var dep_digests: std.ArrayList([]const u8) = .empty;
    if (spec.deps) |deps| {
        var it = deps.map.iterator();
        while (it.next()) |e| {
            if (!inside(e.key_ptr.*)) return fail2("spec {s}: a \"deps\" target is relative, without .., not '{s}'", .{ sp, e.key_ptr.* });
            const src = cx.a.print("{s}/{s}", .{ dir, e.value_ptr.* }) catch continue;
            const abs = realpath(cx, src) orelse return fail2("spec {s}: deps source {s} not found", .{ sp, e.value_ptr.* });
            if (!underRoots(cx, abs)) return fail2("deps source {s} isn't under submit_roots ({s})", .{ abs, roots(cx) });
            excludes.append(cx.a, e.key_ptr.*) catch {};
            const s = snapshot(cx, abs, &.{}, true);
            if (s.secret) |p| return fail2("deps source {s} holds {s}, which looks like a credential", .{ abs, p });
            dep_digests.append(cx.a, cx.a.print("{s}={s}", .{ e.key_ptr.*, s.digest }) catch "") catch {};
        }
    }
    const snap = snapshot(cx, dir, excludes.items, false);
    if (snap.digest.len == 0) return fail2("{s}: can't read it", .{dir});
    if (snap.secret) |p| return fail2("{s} holds {s}, which looks like a credential: add it to \"exclude\" (cpuq never ships credentials)", .{ dir, p });

    const snapshot_digest = sha(cx, &.{ snap.digest, std.mem.join(cx.a, "\x01", dep_digests.items) catch "" });
    const job_digest = sha(cx, &.{ snapshot_digest, text, std.mem.join(cx.a, "\x01", job_args) catch "", std.mem.join(cx.a, "\x01", extra_env.items) catch "" });

    // Attach, or not.
    const project = spec.label[0 .. std.mem.findScalar(u8, spec.label, ':') orelse spec.label.len];
    for (listJobs(cx)) |j| {
        if (!std.mem.eql(u8, j.rec.dir, dir) or !std.mem.eql(u8, j.rec.label, spec.label)) continue;
        if (j.finished) continue;
        if (std.mem.eql(u8, j.rec.digest, job_digest)) {
            cx.out.print("job {s} (attached: the same code is already {s})\n", .{ j.rec.id, j.state }) catch {};
            cx.out.flush() catch {};
            return follow(cx, j.rec.id, max_wait);
        }
        if (replace) {
            _ = cancelJob(cx, j.rec);
        } else if (!again) {
            const age = now(cx.io) - j.rec.created;
            cx.out.print("NOT STARTED  {s}  {s}  older snapshot running ({s}, {d}m in): --replace to cancel it and start this one, or --again to run both\n", .{ spec.label, job_digest[0..8], j.rec.id, @divTrunc(age, 60) }) catch {};
            return Verdict.not_started.exit();
        }
    }

    // A new job.
    const id = sha(cx, &.{ job_digest, cx.a.print("{d} {d}", .{ Io.Clock.real.now(cx.io).toNanoseconds(), sys.getpid() }) catch "" })[0..8];
    const origin = sha(cx, &.{ hostname(cx), dir })[0..12];
    const copy = cx.a.print("cpuq-spill/w/{s}/{s}", .{ project, origin }) catch return 125;
    var env_map: Map = .{};
    if (spec.env) |e| {
        var it = e.map.iterator();
        while (it.next()) |kv| env_map.map.put(cx.a, kv.key_ptr.*, kv.value_ptr.*) catch {};
    }
    for (extra_env.items) |kv| {
        const eq = std.mem.findScalar(u8, kv, '=').?;
        env_map.map.put(cx.a, kv[0..eq], kv[eq + 1 ..]) catch {};
    }
    // What the job is for, beside its label everywhere it shows: --note, else the branch.
    const why = note orelse branch(cx, dir);
    const payload: Payload = .{
        .id = id,
        .label = spec.label,
        .note = why,
        .project = project,
        .setup = spec.setup,
        .run = spec.run,
        .cores = spec.cores,
        .time = spec.time,
        .mem = spec.mem,
        .tools = spec.tools,
        .env = env_map,
        .caches = spec.caches,
        .report = spec.report,
        .args = job_args,
        .copy = copy,
        .generation = snapshot_digest,
        .digest = job_digest,
    };
    const rec: Record = .{
        .id = id,
        .label = spec.label,
        .note = why,
        .spec = spec_abs,
        .dir = dir,
        .digest = job_digest,
        .snapshot = snapshot_digest,
        .created = now(cx.io),
        .copy = copy,
        .exclude = excludes.items,
        .@"return" = spec.@"return",
        .deps = spec.deps,
        .on = spec.on,
        .payload = jsonString(cx, payload),
    };
    writeFile(cx, jobFile(cx, id, "job.json"), jsonString(cx, rec));
    setState(cx, id, "submitted", "");
    if (!spawnDetached(cx, &.{ cx.self, "_supervise", id }, jobFile(cx, id, "supervisor.log"))) {
        std.debug.print("cpuq submit: could not start the supervisor\n", .{});
        return Verdict.cpuq_error.exit();
    }
    cx.out.print("job {s}\n", .{id}) catch {};
    cx.out.flush() catch {};
    return follow(cx, id, max_wait);
}

/// The worktree's branch, or its commit when detached.
fn branch(cx: Cx, dir: []const u8) []const u8 {
    const b = run(cx, &.{ "git", "-C", dir, "rev-parse", "--abbrev-ref", "HEAD" }, null);
    const name = std.mem.trim(u8, b.out, " \n");
    if (b.ok and name.len != 0 and !std.mem.eql(u8, name, "HEAD")) return name;
    const c2 = run(cx, &.{ "git", "-C", dir, "rev-parse", "--short", "HEAD" }, null);
    return if (c2.ok) std.mem.trim(u8, c2.out, " \n") else "";
}

fn realpath(cx: Cx, p: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const z = cx.a.dupeSentinel(u8, p, 0) catch return null;
    const r = c.realpath(z, &buf) orelse return null;
    return cx.a.dupe(u8, std.mem.sliceTo(r, 0)) catch null;
}

fn hostname(cx: Cx) []const u8 {
    var buf: [256]u8 = undefined;
    if (c.gethostname(&buf, buf.len) != 0) return "here";
    return cx.a.dupe(u8, std.mem.sliceTo(&buf, 0)) catch "here";
}

fn roots(cx: Cx) []const u8 {
    if (cx.cfg.submit_roots.len != 0) return cx.cfg.submit_roots;
    return cx.a.print("{s}/Data/Code", .{home(cx)}) catch "";
}

fn underRoots(cx: Cx, path: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, roots(cx), ", \t");
    while (it.next()) |r0| {
        const r = if (std.mem.startsWith(u8, r0, "~/")) cx.a.print("{s}/{s}", .{ home(cx), r0[2..] }) catch continue else r0;
        const real = realpath(cx, r) orelse continue;
        if (std.mem.eql(u8, path, real)) return true;
        if (path.len > real.len and std.mem.startsWith(u8, path, real) and path[real.len] == '/') return true;
    }
    return false;
}

/// Runs argv in its own session, with stdin from /dev/null and output to `log`; it outlives
/// this process and the terminal or agent tool that started it.
fn spawnDetached(cx: Cx, argv: []const []const u8, log: []const u8) bool {
    const argz = cx.a.allocSentinel(?[*:0]const u8, argv.len, null) catch return false;
    for (argv, 0..) |x, k| argz[k] = (cx.a.dupeSentinel(u8, x, 0) catch return false).ptr;
    const logz = cx.a.dupeSentinel(u8, log, 0) catch return false;
    const envp = cx.env.createPosixBlock(cx.a, .{}) catch return false;
    if (std.fs.path.dirname(log)) |d| Io.Dir.cwd().createDirPath(cx.io, d) catch {};
    const pid = c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        _ = c.setsid();
        // A second fork, so the job is no child of a shell that would wait for it.
        const p2 = c.fork();
        if (p2 != 0) c._exit(0);
        const null_fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY });
        if (null_fd >= 0) _ = c.dup2(null_fd, 0);
        const log_fd = c.open(logz, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, @as(c.mode_t, 0o600));
        if (log_fd >= 0) {
            _ = c.dup2(log_fd, 1);
            _ = c.dup2(log_fd, 2);
        }
        _ = c.execve(argz[0].?, argz.ptr, @ptrCast(envp.slice.ptr));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    return true;
}

// --- Local job state -------------------------------------------------------------------------

fn setState(cx: Cx, id: []const u8, state: []const u8, progress: []const u8) void {
    writeFile(cx, jobFile(cx, id, "state"), cx.a.print("{s}\n{d}\n{s}\n", .{ state, now(cx.io), progress }) catch return);
}

const Known = struct { rec: Record, state: []const u8, finished: bool };

fn loadRecord(cx: Cx, id: []const u8) ?Record {
    const text = readFile(cx, jobFile(cx, id, "job.json")) orelse return null;
    return std.json.parseFromSliceLeaky(Record, cx.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn readState(cx: Cx, id: []const u8) struct { state: []const u8, since: i64, progress: []const u8 } {
    const text = readFile(cx, jobFile(cx, id, "state")) orelse return .{ .state = "unknown", .since = 0, .progress = "" };
    var lines = std.mem.splitScalar(u8, text, '\n');
    const st = lines.next() orelse "unknown";
    const since = std.fmt.parseInt(i64, lines.next() orelse "0", 10) catch 0;
    return .{ .state = st, .since = since, .progress = lines.next() orelse "" };
}

/// The jobs kept here, newest first.
fn listJobs(cx: Cx) []Known {
    var out: std.ArrayList(Known) = .empty;
    const jd = cx.a.print("{s}/jobs", .{stateRoot(cx)}) catch return &.{};
    var d = Io.Dir.cwd().openDir(cx.io, jd, .{ .iterate = true }) catch return &.{};
    defer d.close(cx.io);
    var it = d.iterate();
    while (it.next(cx.io) catch null) |e| {
        if (e.kind != .directory or !validId(e.name)) continue;
        const id = cx.a.dupe(u8, e.name) catch continue;
        const rec = loadRecord(cx, id) orelse continue;
        const st = readState(cx, id);
        out.append(cx.a, .{ .rec = rec, .state = st.state, .finished = std.mem.eql(u8, st.state, "done") }) catch {};
    }
    std.mem.sortUnstable(Known, out.items, {}, struct {
        fn lt(_: void, x: Known, y: Known) bool {
            return x.rec.created > y.rec.created;
        }
    }.lt);
    return out.items;
}

fn loadResult(cx: Cx, id: []const u8) ?Result {
    const text = readFile(cx, jobFile(cx, id, "result.json")) orelse return null;
    return std.json.parseFromSliceLeaky(Result, cx.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

/// Whether a supervisor holds this job (its lock is taken).
fn supervised(cx: Cx, id: []const u8) bool {
    const f = Io.Dir.cwd().openFile(cx.io, jobFile(cx, id, "lock"), .{}) catch return false;
    defer f.close(cx.io);
    const free = f.tryLock(cx.io, .exclusive) catch return true;
    if (free) f.unlock(cx.io);
    return !free;
}

// --- Following a job: progress, the verdict, its exit --------------------------------------

fn follow(cx: Cx, id: []const u8, max_wait: ?i64) u8 {
    const start = now(cx.io);
    var last_state: []const u8 = "";
    var last_print: i64 = 0;
    const tty = c.isatty(2) != 0;
    var unsupervised_since: ?i64 = null;
    while (true) {
        const st = readState(cx, id);
        if (std.mem.eql(u8, st.state, "done")) return printVerdict(cx, id);
        const t = now(cx.io);
        if (!std.mem.eql(u8, st.state, last_state) or t - last_print >= 300 or (tty and t - last_print >= 10)) {
            const rec = loadRecord(cx, id);
            std.debug.print("{s}  {s}  {s}  {s}  {s}\n", .{
                if (rec) |r| r.label else "?",
                st.state,
                if (rec) |r| r.host orelse "-" else "-",
                ageText(cx, t - (if (rec) |r| r.created else t)),
                st.progress,
            });
            last_state = cx.a.dupe(u8, st.state) catch "";
            last_print = t;
        }
        // A job nobody supervises is picked up again: the supervisor reconciles it with its host.
        if (!supervised(cx, id)) {
            if (unsupervised_since == null) unsupervised_since = t;
            if (t - unsupervised_since.? >= 3) {
                _ = spawnDetached(cx, &.{ cx.self, "_supervise", id }, jobFile(cx, id, "supervisor.log"));
                unsupervised_since = null;
            }
        } else unsupervised_since = null;
        if (max_wait) |mw| if (t - start >= mw) {
            const rec = loadRecord(cx, id);
            cx.out.print("RUNNING      {s}  {s}  {s} on {s}: still running; cpuq job {s} --wait\n", .{
                if (rec) |r| r.label else "?", if (rec) |r| r.digest[0..8] else "", ageText(cx, t - (if (rec) |r| r.created else t)), if (rec) |r| r.host orelse "-" else "-", id,
            }) catch {};
            cx.out.flush() catch {};
            return Verdict.running.exit();
        };
        sleepMs(cx.io, 1000);
    }
}

fn ageText(cx: Cx, s: i64) []const u8 {
    if (s < 60) return cx.a.print("{d}s", .{s}) catch "";
    if (s < 3600) return cx.a.print("{d}m{d:0>2}s", .{ @divTrunc(s, 60), @mod(s, 60) }) catch "";
    return cx.a.print("{d}h{d:0>2}m", .{ @divTrunc(s, 3600), @divTrunc(@mod(s, 3600), 60) }) catch "";
}

fn printVerdict(cx: Cx, id: []const u8) u8 {
    const r = loadResult(cx, id) orelse {
        cx.out.print("CPUQ ERROR   job {s} ended without a result: not your code, report it\n", .{id}) catch {};
        cx.out.flush() catch {};
        return Verdict.cpuq_error.exit();
    };
    const v = Verdict.parse(r.verdict);
    const w = cx.out;
    if (v == .fail) {
        if (r.failures.len != 0) {
            for (r.failures) |f| w.print("  fail  {s}  {s}{s}{s}\n", .{ f.id, f.reason, if (f.artifact.len != 0) "  " else "", f.artifact }) catch {};
        } else if (readFile(cx, jobFile(cx, id, "tail.log"))) |tail| {
            var lines: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, tail, "\n"), '\n');
            while (it.next()) |l| lines.append(cx.a, l) catch {};
            const from = lines.items.len -| 30;
            for (lines.items[from..]) |l| w.print("  {s}\n", .{l}) catch {};
        }
    }
    const word = v.word();
    // The words line up: the longest, NOT STARTED, has 11 letters.
    w.print("{s}{s}  {s}  {s}  ", .{ word, "           "[0 .. 11 -| word.len], r.label, r.digest[0..@min(8, r.digest.len)] }) catch {};
    switch (v) {
        .pass => w.print("{s}  {s}  {s} cores{s}\n", .{ ageText(cx, @intFromFloat(r.seconds)), r.host, r.cores, countsText(cx, r) }) catch {},
        .fail => w.print("exit {d}  {s}  {s}{s}\n", .{ r.code orelse -1, ageText(cx, @intFromFloat(r.seconds)), r.host, countsText(cx, r) }) catch {},
        else => w.print("{s}\n", .{r.detail}) catch {},
    }
    w.flush() catch {};
    return v.exit();
}

fn countsText(cx: Cx, r: Result) []const u8 {
    if (r.total == 0) return "";
    return cx.a.print("  {d} tests: {d} ok, {d} failed", .{ r.total, r.ok, r.failed }) catch "";
}

// --- The supervisor: place, start, sync, follow, fetch, retry -------------------------------

pub fn cmdSupervise(cx: Cx, args: []const [:0]const u8) u8 {
    if (args.len < 1 or !validId(args[0])) return 2;
    const id: []const u8 = args[0];
    const lock = Io.Dir.cwd().createFile(cx.io, jobFile(cx, id, "lock"), .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false }) catch return 0;
    defer lock.close(cx.io);
    var rec = loadRecord(cx, id) orelse return 2;
    if (std.mem.eql(u8, readState(cx, id).state, "done")) return 0;
    var payload = std.json.parseFromSliceLeaky(Payload, cx.a, rec.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return 2;

    // A job already placed (a restarted supervisor) is reconciled with its host first.
    if (rec.host) |h| {
        const p = peek(cx, h, id);
        if (p) |pk| {
            if (std.mem.eql(u8, pk.state, "done")) return finish(cx, &rec, h);
            if (!std.mem.eql(u8, pk.state, "none")) return watch(cx, &rec, &payload, h);
        }
        // Not there: start it again on the same host, below.
    }

    setState(cx, id, "placing", "");
    const host = rec.host orelse (place(cx, &rec) orelse return done(cx, id, rec, .not_run, null, placeDetail(cx), ""));
    rec.host = host;
    writeFile(cx, jobFile(cx, id, "job.json"), jsonString(cx, rec));
    return startAndWatch(cx, &rec, &payload, host);
}

var place_notes: std.ArrayList([]const u8) = .empty;

fn placeDetail(cx: Cx) []const u8 {
    const notes = std.mem.join(cx.a, "; ", place_notes.items) catch "";
    return cx.a.print("no host could take it ({s}): not your code", .{notes}) catch "no host could take it: not your code";
}

const Probe = struct { reachable: bool, room: bool, mem_total: u64, note: []const u8 };

fn probe(cx: Cx, host: []const u8) Probe {
    const r = onHost(cx, host, cx.a.print("{s} status --json --no-usage", .{cpuqOn(cx, host)}) catch "");
    if (!r.ok) return .{ .reachable = false, .room = false, .mem_total = 0, .note = cx.a.print("{s}: no answer", .{host}) catch "" };
    const St = struct {
        version: []const u8 = "",
        waiters: []const std.json.Value = &.{},
        load: [3]f64 = .{ 0, 0, 0 },
        active_cores: u32 = 0,
        gate: struct { state: []const u8 = "open" } = .{},
        memory: ?struct { total: u64 = 0 } = null,
    };
    const st = std.json.parseFromSliceLeaky(St, cx.a, r.out, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch
        return .{ .reachable = false, .room = false, .mem_total = 0, .note = cx.a.print("{s}: its cpuq answered in a form this one can't read", .{host}) catch "" };
    if (!versionAtLeast(st.version, host_min)) return .{ .reachable = false, .room = false, .mem_total = 0, .note = cx.a.print("{s} runs cpuq {s}, and submit needs {d}.{d} (curl -fsSL https://raw.githubusercontent.com/shreeve/cpuq/main/install.sh | bash, on {s})", .{ host, st.version, host_min[0], host_min[1], host }) catch "" };
    const room = st.waiters.len == 0 and st.load[0] < @as(f64, @floatFromInt(st.active_cores)) and std.mem.eql(u8, st.gate.state, "open");
    return .{ .reachable = true, .room = room, .mem_total = if (st.memory) |m| m.total else 0, .note = "" };
}

fn versionAtLeast(v: []const u8, min: [3]u32) bool {
    var parts: [3]u32 = .{ 0, 0, 0 };
    var it = std.mem.splitScalar(u8, v, '.');
    for (&parts) |*p| p.* = std.fmt.parseInt(u32, it.next() orelse "0", 10) catch 0;
    for (parts, min) |p, m| {
        if (p != m) return p > m;
    }
    return true;
}

/// The first host in `on` that answers, fits `mem` and has room; else the first that answers;
/// else the first that can be started.
fn place(cx: Cx, rec: *const Record) ?[]const u8 {
    const payload = std.json.parseFromSliceLeaky(Payload, cx.a, rec.payload, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return null;
    const need: u64 = if (payload.mem) |m| policy.parseBytes(m) orelse 0 else 0;
    var first_up: ?[]const u8 = null;
    for (rec.on) |host| {
        const p = probe(cx, host);
        if (!p.reachable) {
            place_notes.append(cx.a, p.note) catch {};
            continue;
        }
        if (need != 0 and p.mem_total != 0 and need > p.mem_total) {
            place_notes.append(cx.a, cx.a.print("{s}: {d} GB of RAM, the job wants {d}", .{ host, p.mem_total >> 30, need >> 30 }) catch "") catch {};
            continue;
        }
        if (p.room) return host;
        if (first_up == null) first_up = host;
    }
    if (first_up) |h| return h;
    for (rec.on) |host| {
        const start = cx.cfg.spillStart(host) orelse continue;
        setState(cx, rec.id, "starting", cx.a.print("starting {s}", .{host}) catch "");
        const r = run(cx, &.{ "/bin/sh", "-c", cx.a.print("{s} 1>&2", .{start}) catch continue }, null);
        if (!r.ok) {
            place_notes.append(cx.a, cx.a.print("{s}: its start command failed", .{host}) catch "") catch {};
            continue;
        }
        if (probe(cx, host).reachable) return host;
    }
    return null;
}

const Peeked = struct {
    state: []const u8 = "none",
    done: u64 = 0,
    failing: u64 = 0,
    last: []const u8 = "",
};

fn peek(cx: Cx, host: []const u8, id: []const u8) ?Peeked {
    const r = onHost(cx, host, cx.a.print("{s} _peek {s}", .{ cpuqOn(cx, host), id }) catch "");
    if (!r.ok) return null;
    return std.json.parseFromSliceLeaky(Peeked, cx.a, r.out, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn startAndWatch(cx: Cx, rec: *Record, payload: *Payload, host: []const u8) u8 {
    const id = rec.id;
    if (host_has_time_rule(cx, host) and payload.time == null) payload.time = "2h";
    payload.attempt = rec.attempt;
    setState(cx, id, "starting", cx.a.print("on {s}", .{host}) catch "");
    const b64 = base64(cx, jsonString(cx, payload.*));
    const started = onHost(cx, host, cx.a.print("{s} _start {s} {s}", .{ cpuqOn(cx, host), id, b64 }) catch "");
    if (!started.ok) return done(cx, id, rec.*, .cpuq_error, null, cx.a.print("couldn't start it on {s}: {s}: not your code, report it", .{ host, std.mem.trim(u8, started.err, " \n") }) catch "", host);

    // The host's _job takes the copy's lock, then says "ready": sync while it holds it.
    var waited: u32 = 0;
    while (true) {
        const p = peek(cx, host, id) orelse return lostOrRetry(cx, rec, payload, host);
        if (std.mem.eql(u8, p.state, "ready")) break;
        if (std.mem.eql(u8, p.state, "done")) return finish(cx, rec, host);
        setState(cx, id, "queued", if (std.mem.eql(u8, p.state, "waiting-copy")) "waiting for its copy (another job of this worktree runs on it)" else "");
        waited += 1;
        sleepMs(cx.io, 1000);
    }
    setState(cx, id, "syncing", cx.a.print("to {s}", .{host}) catch "");
    var tries: u32 = 0;
    while (true) : (tries += 1) {
        if (!sync(cx, rec, host)) return done(cx, id, rec.*, .cpuq_error, null, cx.a.print("rsync to {s} failed: not your code, report it", .{host}) catch "", host);
        // The worktree must not have changed while it was copied.
        const again = resnapshot(cx, rec);
        if (std.mem.eql(u8, again, rec.snapshot)) break;
        if (tries == 2) return done(cx, id, rec.*, .cpuq_error, null, "the worktree kept changing while it was copied: resubmit when it's still", host);
        rec.snapshot = again;
        payload.generation = again;
    }
    const marked = onHost(cx, host, cx.a.print("{s} _synced {s} {s}", .{ cpuqOn(cx, host), id, rec.snapshot }) catch "");
    if (!marked.ok) return done(cx, id, rec.*, .cpuq_error, null, cx.a.print("couldn't mark the copy on {s}: not your code, report it", .{host}) catch "", host);
    writeFile(cx, jobFile(cx, id, "job.json"), jsonString(cx, rec.*));
    return watch(cx, rec, payload, host);
}

fn host_has_time_rule(cx: Cx, host: []const u8) bool {
    return cx.cfg.spillStart(host) != null;
}

fn resnapshot(cx: Cx, rec: *const Record) []const u8 {
    var dep_digests: std.ArrayList([]const u8) = .empty;
    if (rec.deps) |deps| {
        var it = deps.map.iterator();
        while (it.next()) |e| {
            const src = realpath(cx, cx.a.print("{s}/{s}", .{ rec.dir, e.value_ptr.* }) catch continue) orelse continue;
            dep_digests.append(cx.a, cx.a.print("{s}={s}", .{ e.key_ptr.*, snapshot(cx, src, &.{}, true).digest }) catch "") catch {};
        }
    }
    return sha(cx, &.{ snapshot(cx, rec.dir, rec.exclude, false).digest, std.mem.join(cx.a, "\x01", dep_digests.items) catch "" });
}

fn sync(cx: Cx, rec: *const Record, host: []const u8) bool {
    const rsync = rsyncPath(cx);
    const dest = copyTarget(cx, host, rec.copy);
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(cx.a, &.{ rsync, "-a", "--delete" }) catch return false;
    if (!std.mem.eql(u8, host, "here")) argv.append(cx.a, cx.a.print("--rsync-path=mkdir -p {s} && rsync", .{quote(cx, rec.copy)}) catch return false) catch return false;
    for (rec.exclude) |e| argv.append(cx.a, cx.a.print("--exclude=/{s}", .{std.mem.trimEnd(u8, e, "/")}) catch continue) catch {};
    argv.append(cx.a, cx.a.print("{s}/", .{rec.dir}) catch return false) catch return false;
    argv.append(cx.a, cx.a.print("{s}/", .{dest}) catch return false) catch return false;
    if (std.mem.eql(u8, host, "here")) Io.Dir.cwd().createDirPath(cx.io, cx.a.print("{s}/{s}", .{ home(cx), rec.copy }) catch "") catch {};
    if (!run(cx, argv.items, null).ok) return false;
    // Each dep's tracked files, with their mtimes.
    if (rec.deps) |deps| {
        var it = deps.map.iterator();
        while (it.next()) |e| {
            const src = realpath(cx, cx.a.print("{s}/{s}", .{ rec.dir, e.value_ptr.* }) catch continue) orelse return false;
            const list = run(cx, &.{ "git", "-C", src, "ls-files" }, null);
            const files = cx.a.print("{s}/deps-{s}.list", .{ jobDir(cx, rec.id), hex(cx, e.key_ptr.*) }) catch return false;
            writeFile(cx, files, if (list.ok) list.out else "");
            const target = cx.a.print("{s}/{s}/", .{ dest, e.key_ptr.* }) catch return false;
            var dargv: std.ArrayList([]const u8) = .empty;
            dargv.appendSlice(cx.a, &.{ rsync, "-a" }) catch return false;
            if (!std.mem.eql(u8, host, "here")) {
                dargv.append(cx.a, cx.a.print("--rsync-path=mkdir -p {s} && rsync", .{quote(cx, cx.a.print("{s}/{s}", .{ rec.copy, e.key_ptr.* }) catch "")}) catch "") catch {};
            } else Io.Dir.cwd().createDirPath(cx.io, cx.a.print("{s}/{s}/{s}", .{ home(cx), rec.copy, e.key_ptr.* }) catch "") catch {};
            if (list.ok) dargv.append(cx.a, cx.a.print("--files-from={s}", .{files}) catch "") catch {};
            dargv.append(cx.a, cx.a.print("{s}/", .{src}) catch "") catch {};
            dargv.append(cx.a, target) catch {};
            if (!run(cx, dargv.items, null).ok) return false;
        }
    }
    return true;
}

fn watch(cx: Cx, rec: *Record, payload: *Payload, host: []const u8) u8 {
    const id = rec.id;
    var misses: u32 = 0;
    while (true) {
        const p = peek(cx, host, id) orelse {
            misses += 1;
            if (misses >= 3) return lostOrRetry(cx, rec, payload, host);
            sleepMs(cx.io, 5000);
            continue;
        };
        misses = 0;
        if (std.mem.eql(u8, p.state, "done")) return finish(cx, rec, host);
        if (std.mem.eql(u8, p.state, "none")) return lostOrRetry(cx, rec, payload, host);
        const progress = if (p.done != 0)
            cx.a.print("{d} done  {d} failing  {s}", .{ p.done, p.failing, p.last[0..@min(p.last.len, 60)] }) catch ""
        else
            p.last[0..@min(p.last.len, 80)];
        setState(cx, id, p.state, progress);
        sleepMs(cx.io, 5000);
    }
}

/// The host stopped answering, or lost the job: start it again and rerun once, on the copy it
/// already holds, else LOST.
fn lostOrRetry(cx: Cx, rec: *Record, payload: *Payload, host: []const u8) u8 {
    const id = rec.id;
    if (rec.attempt >= 2) return done(cx, id, rec.*, .lost, null, cx.a.print("{s} went away twice: not your code, resubmit once", .{host}) catch "", host);
    if (!probe(cx, host).reachable) {
        const start = cx.cfg.spillStart(host) orelse return done(cx, id, rec.*, .lost, null, cx.a.print("{s} went away: not your code, resubmit once", .{host}) catch "", host);
        setState(cx, id, "starting", cx.a.print("{s} went away; starting it again", .{host}) catch "");
        if (!run(cx, &.{ "/bin/sh", "-c", cx.a.print("{s} 1>&2", .{start}) catch "" }, null).ok)
            return done(cx, id, rec.*, .lost, null, cx.a.print("{s} went away and couldn't be started: not your code, resubmit once", .{host}) catch "", host);
    }
    if (peek(cx, host, id)) |p| {
        if (std.mem.eql(u8, p.state, "done")) return finish(cx, rec, host);
        if (!std.mem.eql(u8, p.state, "none")) return watch(cx, rec, payload, host);
    }
    rec.attempt += 1;
    writeFile(cx, jobFile(cx, id, "job.json"), jsonString(cx, rec.*));
    return startAndWatch(cx, rec, payload, host);
}

/// The job is done on the host: bring back its result, its output's end and `return`.
fn finish(cx: Cx, rec: *const Record, host: []const u8) u8 {
    const id = rec.id;
    setState(cx, id, "fetching", "");
    const res = onHost(cx, host, cx.a.print("cat {s}", .{quote(cx, hostJobFile(cx, host, id, "result.json"))}) catch "");
    const tail = onHost(cx, host, cx.a.print("tail -n 200 {s}", .{quote(cx, hostJobFile(cx, host, id, "output.log"))}) catch "");
    if (tail.ok) writeFile(cx, jobFile(cx, id, "tail.log"), tail.out);
    for (rec.@"return") |p| {
        const src = cx.a.print("{s}/{s}/./{s}", .{ copyTarget(cx, host, rec.copy), "", p }) catch continue;
        _ = run(cx, &.{ rsyncPath(cx), "-a", "--relative", "--safe-links", src, cx.a.print("{s}/", .{rec.dir}) catch continue }, null);
    }
    if (!res.ok) return done(cx, id, rec.*, .cpuq_error, null, cx.a.print("its result couldn't be read on {s}: not your code, report it", .{host}) catch "", host);
    // Here, the host's job directory is this one: result.json is already in place.
    if (!std.mem.eql(u8, host, "here")) writeFile(cx, jobFile(cx, id, "result.json"), res.out);
    setState(cx, id, "done", "");
    return 0;
}

fn hostJobFile(cx: Cx, host: []const u8, id: []const u8, name: []const u8) []const u8 {
    if (std.mem.eql(u8, host, "here")) return jobFile(cx, id, name);
    return cx.a.print(".local/state/cpuq/jobs/{s}/{s}", .{ id, name }) catch "";
}

/// Ends a job here with a verdict cpuq reached itself (never ran, lost, cpuq failed).
fn done(cx: Cx, id: []const u8, rec: Record, v: Verdict, code: ?i64, detail: []const u8, host: []const u8) u8 {
    const r: Result = .{ .verdict = @tagName(v), .label = rec.label, .digest = rec.digest, .host = host, .code = code, .detail = detail };
    writeFile(cx, jobFile(cx, id, "result.json"), jsonString(cx, r));
    setState(cx, id, "done", "");
    return 0;
}

fn base64(cx: Cx, s: []const u8) []const u8 {
    const enc = std.base64.standard.Encoder;
    const out = cx.a.alloc(u8, enc.calcSize(s.len)) catch return "";
    return enc.encode(out, s);
}

fn unbase64(cx: Cx, s: []const u8) ?[]const u8 {
    const dec = std.base64.standard.Decoder;
    const n = dec.calcSizeForSlice(s) catch return null;
    const out = cx.a.alloc(u8, n) catch return null;
    dec.decode(out, s) catch return null;
    return out;
}

// --- On the host: _start, _job, _peek, _synced, _cancel --------------------------------------

/// `_start ID PAYLOAD`: keeps the job's spec, then runs `_job ID` in its own session, unless
/// one already runs (its lock is held): starting twice never runs a job twice.
pub fn cmdStart(cx: Cx, args: []const [:0]const u8) u8 {
    if (args.len < 2 or !validId(args[0])) return 2;
    const id: []const u8 = args[0];
    const json = unbase64(cx, args[1]) orelse return 2;
    _ = std.json.parseFromSliceLeaky(Payload, cx.a, json, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return 2;
    if (jobRunning(cx, id)) {
        cx.out.writeAll("running\n") catch {};
        return 0;
    }
    writeFile(cx, jobFile(cx, id, "payload.json"), json);
    // A rerun starts clean: no state, result or cancel from the attempt before.
    for ([_][]const u8{ "state", "result.json", "cancel", "synced" }) |f| Io.Dir.cwd().deleteFile(cx.io, jobFile(cx, id, f)) catch {};
    if (!spawnDetached(cx, &.{ cx.self, "_runjob", id }, jobFile(cx, id, "job.log"))) return 125;
    // Wait until _job holds its lock, so a peek right after sees it.
    var i: usize = 0;
    while (i < 50 and !jobRunning(cx, id)) : (i += 1) sleepMs(cx.io, 100);
    cx.out.writeAll("started\n") catch {};
    return 0;
}

fn jobRunning(cx: Cx, id: []const u8) bool {
    const f = Io.Dir.cwd().openFile(cx.io, jobFile(cx, id, "running.lock"), .{}) catch return false;
    defer f.close(cx.io);
    const free = f.tryLock(cx.io, .exclusive) catch return true;
    if (free) f.unlock(cx.io);
    return !free;
}

var job_child = std.atomic.Value(c.pid_t).init(0);

fn onTerm(sig: c.SIG, _: *const c.siginfo_t, _: ?*anyopaque) callconv(.c) void {
    const pid = job_child.load(.acquire);
    if (pid > 0) _ = c.kill(pid, sig);
}

/// `_runjob ID`, on the host: the job's whole life there.
pub fn cmdHostJob(cx: Cx, args: []const [:0]const u8) u8 {
    if (args.len < 1 or !validId(args[0])) return 2;
    const id: []const u8 = args[0];
    const me = Io.Dir.cwd().createFile(cx.io, jobFile(cx, id, "running.lock"), .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false }) catch return 0;
    defer me.close(cx.io);
    const text = readFile(cx, jobFile(cx, id, "payload.json")) orelse return 2;
    const p = std.json.parseFromSliceLeaky(Payload, cx.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return 2;
    const started = now(cx.io);
    hostState(cx, id, "waiting-copy");

    // One job at a time on a copy.
    const copy = cx.a.print("{s}/{s}", .{ home(cx), p.copy }) catch return 125;
    Io.Dir.cwd().createDirPath(cx.io, copy) catch {};
    const copy_lock = Io.Dir.cwd().createFile(cx.io, cx.a.print("{s}.lock", .{copy}) catch "", .{ .lock = .exclusive, .truncate = false }) catch
        return hostDone(cx, id, p, .cpuq_error, null, "the copy's lock couldn't be taken: not your code, report it", started);
    defer copy_lock.close(cx.io);
    hostState(cx, id, "ready");

    // The supervisor syncs, then marks it: wait for that, up to an hour.
    var waited: u32 = 0;
    while (readFile(cx, jobFile(cx, id, "synced")) == null) : (waited += 1) {
        if (cancelled(cx, id)) return hostDone(cx, id, p, .cancelled, null, "by cpuq job --cancel: not your code", started);
        if (waited > 3600 * 5) return hostDone(cx, id, p, .cpuq_error, null, "its copy was never synced: not your code, report it", started);
        sleepMs(cx.io, 200);
    }
    const gen = std.mem.trim(u8, readFile(cx, cx.a.print("{s}/.cpuq-generation", .{copy}) catch "") orelse "", " \n");
    if (!std.mem.eql(u8, gen, p.generation)) return hostDone(cx, id, p, .cpuq_error, null, "the copy doesn't hold the code this job was for: not your code, report it", started);

    // Tools, before anything runs.
    if (p.tools) |tools| {
        var it = tools.map.iterator();
        while (it.next()) |t| {
            const got = run(cx, &.{ "/bin/sh", "-c", cx.a.print("{s} version 2>/dev/null || {s} --version 2>/dev/null", .{ t.key_ptr.*, t.key_ptr.* }) catch "" }, null);
            if (std.mem.find(u8, got.out, t.value_ptr.*) == null)
                return hostDone(cx, id, p, .not_run, null, cx.a.print("{s} here has {s} {s}, the spec wants {s}: not your code", .{ hostname(cx), t.key_ptr.*, std.mem.trim(u8, std.mem.sliceTo(got.out, '\n'), " "), t.value_ptr.* }) catch "", started);
        }
    }

    // The environment: the job's own variables, its caches, a TMPDIR of its own.
    var env = cx.env.clone(cx.a) catch return 125;
    if (p.env) |e| {
        var it = e.map.iterator();
        while (it.next()) |kv| env.put(kv.key_ptr.*, kv.value_ptr.*) catch {};
    }
    if (p.caches) |caches| {
        var it = caches.map.iterator();
        while (it.next()) |kv| {
            if (!inside(kv.value_ptr.*)) continue;
            const dir = cx.a.print("{s}/cpuq-spill/c/{s}/{s}", .{ home(cx), p.project, kv.value_ptr.* }) catch continue;
            Io.Dir.cwd().createDirPath(cx.io, dir) catch {};
            env.put(kv.key_ptr.*, dir) catch {};
        }
    }
    const tmp = jobFile(cx, id, "tmp");
    Io.Dir.cwd().createDirPath(cx.io, tmp) catch {};
    env.put("TMPDIR", tmp) catch {};
    if (p.report) |r| if (inside(r)) Io.Dir.cwd().deleteFile(cx.io, cx.a.print("{s}/{s}", .{ copy, r }) catch "") catch {};

    // cpuq run takes the cores and the job's cgroup; cap enforces time from admission, and memory.
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(cx.a, &.{ cx.self, "run", "--label", p.label }) catch return 125;
    if (p.note.len != 0) argv.appendSlice(cx.a, &.{ "--note", p.note }) catch {};
    if (p.cores) |cr| argv.appendSlice(cx.a, &.{ "--cores", cr }) catch {};
    argv.appendSlice(cx.a, &.{ "--", cx.self, "cap" }) catch {};
    if (p.time) |t| argv.appendSlice(cx.a, &.{ "--time", t }) catch {};
    if (p.mem) |m| argv.appendSlice(cx.a, &.{ "--mem", m }) catch {};
    const script = if (p.setup) |s| cx.a.print("{{ {s}\n}} && {{ {s}\n}}", .{ s, p.run }) catch p.run else p.run;
    argv.appendSlice(cx.a, &.{ "--", "/bin/sh", "-c", script, "cpuq" }) catch {};
    argv.appendSlice(cx.a, p.args) catch {};
    hostState(cx, id, "running");

    const log = jobFile(cx, id, "output.log");
    const code = runLogged(cx, argv.items, &env, copy, log);
    Io.Dir.cwd().deleteTree(cx.io, tmp) catch {};

    // The verdict: cap's own last line says when it stopped the job; the exit code says the rest.
    const last = lastLine(cx, log);
    const capped = std.mem.startsWith(u8, last, "cpuq cap: stopped");
    if (cancelled(cx, id)) return hostDone(cx, id, p, .cancelled, code, "by cpuq job --cancel: not your code", started);
    if (code) |x| {
        if (x == 0) return hostDone(cx, id, p, .pass, 0, "", started);
        if (capped and x == 124) return hostDone(cx, id, p, .timeout, x, cx.a.print("stopped at the {s} limit: a limit, may be a hang in your change", .{p.time orelse "?"}) catch "", started);
        if (capped and x == 122) return hostDone(cx, id, p, .oom, x, cx.a.print("stopped at the {s} limit: a limit, may be a leak in your change", .{p.mem orelse "?"}) catch "", started);
        if (x == 125 and std.mem.startsWith(u8, last, "cpuq")) return hostDone(cx, id, p, .cpuq_error, x, cx.a.print("{s}: not your code, report it", .{last}) catch "", started);
        return hostDone(cx, id, p, .fail, x, "", started);
    }
    return hostDone(cx, id, p, .fail, null, "killed by a signal", started);
}

fn cancelled(cx: Cx, id: []const u8) bool {
    return readFile(cx, jobFile(cx, id, "cancel")) != null;
}

fn hostState(cx: Cx, id: []const u8, state: []const u8) void {
    writeFile(cx, jobFile(cx, id, "host-state"), state);
}

fn lastLine(cx: Cx, path: []const u8) []const u8 {
    const f = Io.Dir.cwd().openFile(cx.io, path, .{}) catch return "";
    defer f.close(cx.io);
    const size = (f.stat(cx.io) catch return "").size;
    const take: u64 = @min(size, 4096);
    const buf = cx.a.alloc(u8, take) catch return "";
    const n = f.readPositionalAll(cx.io, buf, size - take) catch return "";
    const text = std.mem.trimEnd(u8, buf[0..n], "\n");
    const nl = std.mem.findScalarLast(u8, text, '\n');
    return if (nl) |k| text[k + 1 ..] else text;
}

/// Runs the job with its output in `log`, passing cpuq's termination on to it; its exit code,
/// or null when a signal ended it.
fn runLogged(cx: Cx, argv: []const []const u8, env: *std.process.Environ.Map, cwd: []const u8, log: []const u8) ?i64 {
    const argz = cx.a.allocSentinel(?[*:0]const u8, argv.len, null) catch return null;
    for (argv, 0..) |x, k| argz[k] = (cx.a.dupeSentinel(u8, x, 0) catch return null).ptr;
    const envp = env.createPosixBlock(cx.a, .{}) catch return null;
    const cwdz = cx.a.dupeSentinel(u8, cwd, 0) catch return null;
    const logz = cx.a.dupeSentinel(u8, log, 0) catch return null;
    var sa: c.Sigaction = .{ .handler = .{ .sigaction = onTerm }, .mask = undefined, .flags = c.SA.SIGINFO | c.SA.RESTART };
    _ = c.sigemptyset(&sa.mask);
    for ([_]c.SIG{ .TERM, .INT, .HUP }) |s| _ = c.sigaction(s, &sa, null);
    const pid = c.fork();
    if (pid < 0) return null;
    if (pid == 0) {
        if (c.chdir(cwdz) != 0) c._exit(125);
        const fd = c.open(logz, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c.mode_t, 0o600));
        if (fd >= 0) {
            _ = c.dup2(fd, 1);
            _ = c.dup2(fd, 2);
        }
        _ = c.execve(argz[0].?, argz.ptr, @ptrCast(envp.slice.ptr));
        c._exit(127);
    }
    job_child.store(pid, .release);
    var status: c_int = 0;
    while (c.waitpid(pid, &status, 0) < 0) {}
    job_child.store(0, .release);
    const s: u32 = @bitCast(status);
    if (c.W.IFEXITED(s)) return c.W.EXITSTATUS(s);
    return null;
}

/// The job's end on the host: its result, from its exit and its report.
fn hostDone(cx: Cx, id: []const u8, p: Payload, v: Verdict, code: ?i64, detail: []const u8, started: i64) u8 {
    var r: Result = .{
        .verdict = @tagName(v),
        .label = p.label,
        .digest = p.digest,
        .host = hostname(cx),
        .code = code,
        .seconds = @floatFromInt(now(cx.io) - started),
        .cores = p.cores orelse "",
        .detail = detail,
    };
    if (p.report) |rp| if (inside(rp)) {
        const path = cx.a.print("{s}/{s}/{s}", .{ home(cx), p.copy, rp }) catch "";
        if (readFile(cx, path)) |text| {
            var fails: std.ArrayList(Failure) = .empty;
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |line| {
                if (std.mem.trim(u8, line, " \r").len == 0) continue;
                const Line = struct { id: []const u8 = "", ok: bool = true, reason: []const u8 = "", artifact: []const u8 = "" };
                const l = std.json.parseFromSliceLeaky(Line, cx.a, line, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch continue;
                r.total += 1;
                if (l.ok) r.ok += 1 else {
                    r.failed += 1;
                    if (fails.items.len < 20) fails.append(cx.a, .{ .id = l.id, .reason = l.reason, .artifact = l.artifact }) catch {};
                }
            }
            r.failures = fails.items;
        }
    };
    writeFile(cx, jobFile(cx, id, "result.json"), jsonString(cx, r));
    hostState(cx, id, "done");
    return 0;
}

/// `_peek ID`: the job's state on this host, as one line of JSON.
pub fn cmdPeek(cx: Cx, args: []const [:0]const u8) u8 {
    if (args.len < 1 or !validId(args[0])) return 2;
    const id: []const u8 = args[0];
    var p: Peeked = .{};
    const st = readFile(cx, jobFile(cx, id, "host-state"));
    if (st) |s| p.state = std.mem.trim(u8, s, " \n");
    // A job that isn't done and whose _job no longer runs is gone (the host restarted under it).
    if (st != null and !std.mem.eql(u8, p.state, "done") and !jobRunning(cx, id)) p.state = "none";
    if (std.mem.eql(u8, p.state, "running")) {
        p.last = lastLine(cx, jobFile(cx, id, "output.log"));
        if (readFile(cx, jobFile(cx, id, "payload.json"))) |text| {
            if (std.json.parseFromSliceLeaky(Payload, cx.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always })) |pl| {
                if (pl.report) |rp| if (inside(rp)) {
                    if (readFile(cx, cx.a.print("{s}/{s}/{s}", .{ home(cx), pl.copy, rp }) catch "")) |rep| {
                        var lines = std.mem.splitScalar(u8, rep, '\n');
                        while (lines.next()) |line| {
                            if (line.len == 0) continue;
                            p.done += 1;
                            if (std.mem.find(u8, line, "\"ok\":false") != null or std.mem.find(u8, line, "\"ok\": false") != null) p.failing += 1;
                        }
                    }
                };
            } else |_| {}
        }
    }
    cx.out.print("{s}\n", .{jsonString(cx, p)}) catch {};
    return 0;
}

/// `_synced ID GEN`: the copy holds generation GEN; the waiting _job may run.
pub fn cmdSynced(cx: Cx, args: []const [:0]const u8) u8 {
    if (args.len < 2 or !validId(args[0])) return 2;
    const id: []const u8 = args[0];
    const text = readFile(cx, jobFile(cx, id, "payload.json")) orelse return 2;
    const p = std.json.parseFromSliceLeaky(Payload, cx.a, text, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch return 2;
    writeFile(cx, cx.a.print("{s}/{s}/.cpuq-generation", .{ home(cx), p.copy }) catch return 2, args[1]);
    writeFile(cx, jobFile(cx, id, "synced"), args[1]);
    return 0;
}

/// `_cancel ID`, on the host: marks the job cancelled and stops its command.
pub fn cmdHostCancel(cx: Cx, args: []const [:0]const u8) u8 {
    if (args.len < 1 or !validId(args[0])) return 2;
    const id: []const u8 = args[0];
    writeFile(cx, jobFile(cx, id, "cancel"), "cancel");
    // _job passes SIGTERM on to cpuq run, which stops the job's whole tree.
    const r = run(cx, &.{ "/bin/sh", "-c", cx.a.print("pid=$(cat {s} 2>/dev/null) && [ -n \"$pid\" ] && kill -TERM \"$pid\"", .{quote(cx, jobFile(cx, id, "job.pid"))}) catch "" }, null);
    _ = r;
    return 0;
}

fn cancelJob(cx: Cx, rec: Record) bool {
    const host = rec.host orelse {
        _ = done(cx, rec.id, rec, .cancelled, null, "by cpuq job --cancel, before it started: not your code", "-");
        return true;
    };
    return onHost(cx, host, cx.a.print("{s} _cancel {s}", .{ cpuqOn(cx, host), rec.id }) catch "").ok;
}

// --- cpuq jobs, cpuq job ---------------------------------------------------------------------

fn worktree(cx: Cx) []const u8 {
    const r = run(cx, &.{ "git", "rev-parse", "--show-toplevel" }, null);
    if (r.ok) return std.mem.trim(u8, r.out, " \n");
    var buf: [4096]u8 = undefined;
    return cx.a.dupe(u8, std.mem.sliceTo(c.getcwd(&buf, buf.len) orelse return "", 0)) catch "";
}

pub fn cmdJobs(cx: Cx, args: []const [:0]const u8) u8 {
    const all = args.len > 0 and std.mem.eql(u8, args[0], "--all");
    const here = worktree(cx);
    const t = now(cx.io);
    var n: usize = 0;
    for (listJobs(cx)) |j| {
        if (!all and !std.mem.eql(u8, j.rec.dir, here)) continue;
        const r = if (j.finished) loadResult(cx, j.rec.id) else null;
        cx.out.print("{s}  {s:<36}  {s:<11}  {s:<8}  {s} ago{s}{s}\n", .{
            j.rec.id,
            if (j.rec.note.len != 0) cx.a.print("{s}  {s}", .{ j.rec.label, j.rec.note }) catch j.rec.label else j.rec.label,
            if (r) |x| Verdict.parse(x.verdict).word() else j.state,
            j.rec.host orelse "-",
            ageText(cx, t - j.rec.created),
            if (all) "  " else "",
            if (all) j.rec.dir else "",
        }) catch {};
        n += 1;
    }
    if (n == 0) cx.out.writeAll(if (all) "no jobs\n" else "no jobs for this worktree (cpuq jobs --all for every one)\n") catch {};
    return 0;
}

pub fn cmdJob(cx: Cx, args: []const [:0]const u8) u8 {
    var which: []const u8 = "last";
    var label: ?[]const u8 = null;
    var wait = false;
    var max_wait: ?i64 = null;
    var tail: ?usize = null;
    var as_json = false;
    var cancel = false;
    var force = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a: []const u8 = args[i];
        if (std.mem.eql(u8, a, "--wait")) wait = true
        else if (std.mem.eql(u8, a, "--json")) as_json = true
        else if (std.mem.eql(u8, a, "--cancel")) cancel = true
        else if (std.mem.eql(u8, a, "--force")) force = true
        else if (std.mem.eql(u8, a, "--max-wait") and i + 1 < args.len) {
            i += 1;
            max_wait = std.fmt.parseInt(i64, args[i], 10) catch return fail2("--max-wait needs whole seconds", .{});
        } else if (std.mem.eql(u8, a, "--tail") and i + 1 < args.len) {
            i += 1;
            tail = std.fmt.parseInt(usize, args[i], 10) catch return fail2("--tail needs a number of lines", .{});
        } else if (std.mem.eql(u8, a, "--label") and i + 1 < args.len) {
            i += 1;
            label = args[i];
        } else if (!std.mem.startsWith(u8, a, "-")) which = a else return fail2("unknown option '{s}'", .{a});
    }
    const here = worktree(cx);
    const jobs = listJobs(cx);
    var found: ?Known = null;
    var others: usize = 0;
    for (jobs) |j| {
        if (std.mem.eql(u8, which, "last")) {
            if (!std.mem.eql(u8, j.rec.dir, here)) continue;
            if (label) |l| if (!std.mem.eql(u8, j.rec.label, l)) continue;
            if (found == null) found = j else if (!j.finished) others += 1;
        } else if (std.mem.startsWith(u8, j.rec.id, which)) {
            found = j;
            break;
        }
    }
    const j = found orelse return fail2("no job {s}{s}", .{ which, if (std.mem.eql(u8, which, "last")) " for this worktree" else "" });
    const id = j.rec.id;
    if (cancel) {
        if (!std.mem.eql(u8, j.rec.dir, here) and !force) return fail2("job {s} is another worktree's ({s}): --force to cancel it anyway", .{ id, j.rec.dir });
        if (j.finished) return fail2("job {s} has already ended", .{id});
        if (!cancelJob(cx, j.rec)) return fail2("job {s}: its host didn't answer", .{id});
        cx.out.print("job {s}: cancelling\n", .{id}) catch {};
        return 0;
    }
    if (tail) |n| {
        const text = if (j.finished) readFile(cx, jobFile(cx, id, "tail.log")) orelse "" else blk: {
            const host = j.rec.host orelse break :blk "";
            const r = onHost(cx, host, cx.a.print("tail -n {d} {s}", .{ n, quote(cx, hostJobFile(cx, host, id, "output.log")) }) catch "");
            break :blk r.out;
        };
        var lines: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
        while (it.next()) |l| lines.append(cx.a, l) catch {};
        for (lines.items[lines.items.len -| n ..]) |l| cx.out.print("{s}\n", .{l}) catch {};
        return 0;
    }
    if (as_json) {
        cx.out.print("{s}\n", .{readFile(cx, jobFile(cx, id, if (j.finished) "result.json" else "job.json")) orelse "{}"}) catch {};
        return 0;
    }
    if (std.mem.eql(u8, which, "last") and others != 0) std.debug.print("(this worktree has {d} other job{s} running: cpuq jobs)\n", .{ others, if (others == 1) "" else "s" });
    if (wait or j.finished) {
        cx.out.print("job {s}\n", .{id}) catch {};
        cx.out.flush() catch {};
        return follow(cx, id, if (wait) max_wait else 0);
    }
    const st = readState(cx, id);
    cx.out.print("job {s}  {s}  {s}  {s}  {s}  {s}\n", .{ id, j.rec.label, st.state, j.rec.host orelse "-", ageText(cx, now(cx.io) - j.rec.created), st.progress }) catch {};
    return Verdict.running.exit();
}
