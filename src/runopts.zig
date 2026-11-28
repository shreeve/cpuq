//! `cpuq run`'s command line, and finding and joining the command it runs.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");

const main = @import("main.zig");

const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;

pub const RunOptions = struct {
    label: []const u8 = "",
    /// What the run is for (`--note "#224 markers"`), kept beside its label in history; never
    /// matched by.
    note: []const u8 = "",
    cmd: []const [:0]const u8 = &.{},
    /// `--on HOST`: run on HOST, one of this machine's remotes.
    on: ?[]const u8 = null,
    /// `--return PATH` (with --on): copied back from HOST after.
    returns: [max_returns][]const u8 = undefined,
    return_count: u8 = 0,
    /// `--include PATH` (with --on): copied there although gitignored (or .git).
    includes: [max_returns][]const u8 = undefined,
    include_count: u8 = 0,
    /// `--tethered` (internal, what --on runs on HOST): stdin carries the caller's heartbeats;
    /// when they stop, the run stops.
    tethered: bool = false,
    /// `--repo NAME` (internal, what --on passes on): the repository the run's copy came
    /// from, for its history.
    repo: ?[]const u8 = null,
    /// `-n M`: a run of M tasks (0: one task, with the terminal).
    tasks: u32 = 0,
    /// `-c C` or `-c P%`: the most tasks the run runs at once; 0: no limit of its own.
    cpus: u32 = 0,
    cpus_percent: bool = false,
    /// `-t T`: each task's time limit, in seconds.
    timeout_s: ?u32 = null,
    /// `-r N`: tries again for a task that failed.
    retries: u32 = 0,
    /// `--urgent`: its first task goes ahead of the line ("rebuild first").
    urgent: bool = false,
    /// `--driver`: a runner that only starts other `cpuq run`s: it is no task itself.
    driver: bool = false,
    /// `--wait-max S`: give up (exit 75) when no task starts within S seconds; 0: start now or not.
    wait_max: ?u32 = null,
};

const max_returns = 8;

/// The options `cpuq run` takes a value for.
const value_options = [_][]const u8{ "--label", "--note", "--return", "--on", "--include", "--repo", "-n", "-c", "-t", "-r", "--wait-max" };

/// Parses `cpuq run`'s command line; null after saying what is wrong.
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
        const name, const inline_value = std.mem.cutScalar(u8, a, '=') orelse .{ a, null };
        const takes_value = for (value_options) |v| {
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
        if (std.mem.eql(u8, name, "-n")) {
            o.tasks = policy.parseCount(value) orelse {
                _ = usageError("-n needs a whole number of tasks, at least 1, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "-c")) {
            const pct = std.mem.endsWith(u8, value, "%");
            const n = policy.parseCount(if (pct) value[0 .. value.len - 1] else value) orelse {
                _ = usageError("-c needs a whole number of tasks or a percentage of the pool (50%), not '{s}'", .{value});
                return null;
            };
            if (pct and n > 100) {
                _ = usageError("-c takes at most 100%, not '{s}'", .{value});
                return null;
            }
            o.cpus = n;
            o.cpus_percent = pct;
        } else if (std.mem.eql(u8, name, "-t")) {
            o.timeout_s = policy.parseAge(value) orelse {
                _ = usageError("-t needs a time limit such as 30s, 10m or 2h (off: none), not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "-r")) {
            o.retries = policy.parseWhole(u32, value) orelse {
                _ = usageError("-r needs a whole number of retries, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "--urgent")) {
            o.urgent = true;
        } else if (std.mem.eql(u8, name, "--driver")) {
            o.driver = true;
        } else if (std.mem.eql(u8, name, "--wait-max")) {
            o.wait_max = policy.parseWhole(u32, value) orelse {
                _ = usageError("--wait-max needs whole seconds, not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "--label")) {
            if (!policy.validLabel(value)) {
                _ = usageError("--label is project:task, of lowercase letters, digits, '.', '_' and '-', not '{s}'", .{value});
                return null;
            }
            o.label = value;
        } else if (std.mem.eql(u8, name, "--note")) {
            o.note = value;
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
            if (!repoPath(value)) {
                _ = usageError("--return needs a path inside the repo, not '{s}'", .{value});
                return null;
            }
            if (o.return_count == max_returns) {
                _ = usageError("at most {d} --return paths", .{max_returns});
                return null;
            }
            o.returns[o.return_count] = value;
            o.return_count += 1;
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
