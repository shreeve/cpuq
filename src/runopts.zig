//! A run's options: `cpuq run`'s and `cpuq lease`'s command line, and the command it runs.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");

const main = @import("main.zig");

const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;

pub const RunOptions = struct {
    request: policy.Request = .{ .min = 2, .max = 2 },
    /// Whether --cores was given; under measured admission, without it the
    /// label's history picks the count.
    cores_given: bool = false,
    priority: policy.Priority = .normal,
    exclusive: bool = false,
    label: []const u8 = "",
    /// What the job is for (`--note "#224 markers"`), shown beside the label; never sized by.
    note: []const u8 = "",
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
    /// Queue at the front, as `cpuq first` would put it: the cores of a
    /// lease taken `--exclusive`, a timing window that goes next once
    /// running work drains, not behind a stream of later arrivals.
    first: bool = false,
    /// `--opaque`: the command's real work runs where cpuq cannot see or
    /// stop it (inside a container or a VM): counted at its whole grant,
    /// never lent a timing window it could not be frozen out of.
    hidden: bool = false,
    /// `--on HOST`: run on HOST, one of this machine's remotes.
    on: ?[]const u8 = null,
    /// `--return PATH` (with --on): copied back from HOST after.
    returns: [max_returns][]const u8 = undefined,
    return_count: u8 = 0,
    /// `--include PATH` (with --on): copied there although gitignored (or .git).
    includes: [max_returns][]const u8 = undefined,
    include_count: u8 = 0,
    /// `--tethered` (internal, what --on runs on HOST): stdin carries the caller's heartbeats;
    /// when they stop, the job stops.
    tethered: bool = false,
    /// `--repo NAME` (internal, what --on passes on): the repository the job's copy came
    /// from, for its history.
    repo: ?[]const u8 = null,
};

const max_returns = 8;

pub fn parseRun(args: []const [:0]const u8) ?RunOptions {
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
        const takes_value = for ([_][]const u8{ "--cores", "--priority", "--label", "--note", "--max-wait", "--qos", "--host", "--slots", "--return", "--on", "--include", "--repo" }) |v| {
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
        for ([_][]const u8{ "--cores", "--no-load-check", "--qos", "--opaque", "--return", "--tethered", "--on", "--include", "--repo" }) |r| {
            if (std.mem.eql(u8, name, r)) o.run_only = r;
        }
        if (std.mem.eql(u8, name, "--cores")) {
            o.cores_given = true;
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
        } else if (std.mem.eql(u8, name, "--note")) {
            o.note = value;
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
        } else if (std.mem.eql(u8, name, "--opaque")) {
            o.hidden = true;
        } else if (std.mem.eql(u8, name, "--host")) {
            o.host = value;
        } else if (std.mem.eql(u8, name, "--slots")) {
            o.slots = policy.parseCount(value) orelse {
                _ = usageError("--slots needs a whole number, at least 1, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "--hold")) {
            o.hold = true;
        } else if (std.mem.eql(u8, name, "--on")) {
            if (value.len == 0) {
                _ = usageError("--on needs a host", .{});
                return null;
            }
            o.on = value;
        } else if (std.mem.eql(u8, name, "--tethered")) {
            o.tethered = true;
        } else if (std.mem.eql(u8, name, "--repo")) {
            o.repo = value;
        } else if (std.mem.eql(u8, name, "--include")) {
            if (!repoPath(value)) {
                _ = usageError("--include needs a path inside the repo, not '{s}'", .{value});
                return null;
            }
            if (o.include_count == max_returns) {
                _ = usageError("at most {d} --include paths", .{max_returns});
                return null;
            }
            o.includes[o.include_count] = value;
            o.include_count += 1;
        } else if (std.mem.eql(u8, name, "--return")) {
            if (value.len == 0 or value[0] == '/' or std.mem.find(u8, value, "..") != null) {
                _ = usageError("--return needs a path inside the repo, not '{s}'", .{value});
                return null;
            }
            if (o.return_count == max_returns) {
                _ = usageError("at most {d} --return paths", .{max_returns});
                return null;
            }
            o.returns[o.return_count] = value;
            o.return_count += 1;
        } else if (std.mem.eql(u8, name, "--spill")) {
            _ = usageError("--spill is gone: cpuq run runs here; --on HOST sends it to one of this machine's remotes", .{});
            return null;
        } else if (std.mem.eql(u8, name, "--local")) {
            _ = usageError("--local is gone: cpuq run always runs here", .{});
            return null;
        } else if (std.mem.eql(u8, name, "--ship")) {
            _ = usageError("--ship is now --include (and the repo's .cpuq-spill is now .cpuqinclude)", .{});
            return null;
        } else {
            _ = usageError("unknown option '{s}'", .{a});
            return null;
        }
    }
    return o;
}

/// Finds CMD the way a shell does: a name with a slash as is, else along PATH.
pub fn findExecutable(ctx: *Ctx, name: []const u8) ?[:0]const u8 {
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

pub fn joinCommand(ctx: *Ctx, cmd: []const [:0]const u8) []const u8 {
    var list: std.ArrayList(u8) = .empty;
    for (cmd, 0..) |a, i| {
        if (i != 0) list.append(ctx.arena, ' ') catch {};
        list.appendSlice(ctx.arena, a) catch {};
    }
    return list.items;
}

/// A path inside the repo: relative, with no `..`.
pub fn repoPath(p: []const u8) bool {
    return p.len != 0 and p[0] != '/' and std.mem.find(u8, p, "..") == null;
}
