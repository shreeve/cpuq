//! cpuq: a machine-wide CPU pool. Each task of a run gets one CPU of the pool, handed out
//! through a fair line shared by every run on the machine. There is no daemon: every hold is a
//! flock(2) in the state directory.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const sys = @import("sys.zig");
const layout = @import("layout.zig");
const cap = @import("cap.zig");
const submit = @import("submit.zig");
const cpus = @import("cpus.zig");
const op = @import("op.zig");
const runner = @import("runner.zig");
const leasing = @import("leasing.zig");
const records = @import("records.zig");
const status = @import("status.zig");
const tasks = @import("tasks.zig");

test {
    _ = tasks;
    _ = cap;
    _ = submit;
    _ = @import("hook.zig");
    _ = policy;
    _ = @import("state.zig");
    _ = @import("history.zig");
    _ = @import("table.zig");
    _ = @import("gitship.zig");
    _ = @import("packs.zig");
    _ = @import("clean.zig");
    _ = @import("place.zig");
    _ = sys;
    _ = @import("pool.zig");
    _ = op;
    _ = cpus;
    _ = layout;
    _ = @import("runopts.zig");
    _ = @import("repos.zig");
    _ = @import("joblog.zig");
    _ = @import("texts.zig");
    _ = runner;
    _ = leasing;
    _ = @import("remotes.zig");
    _ = records;
    _ = @import("runtimes.zig");
    _ = @import("statusjson.zig");
    _ = status;
}

pub const version = @import("build_options").version;

const usage =
    \\usage: cpuq run [-n M] [-c C] [-t T] [-r N] [run options] [--] CMD [ARGS...]
    \\       cpuq drain -c N | --cpus LIST [--prefer fast] [--quiet-max X] [--max T] [-t T] [--label L] [--] CMD [ARGS...]
    \\       cpuq kill TICKET|PID|LABEL
    \\       cpuq limit TICKET|PID|LABEL -c C [--host HOST]
    \\       cpuq lease NAME [--slots N] [--label L] [--wait-max S] [--host HOST] [--] CMD [ARGS...]
    \\       cpuq lease NAME --host HOST --hold [--slots N] [--label L] [--wait-max S]
    \\       cpuq wait --label PATTERN [--max-wait S]
    \\       cpuq status [--host HOST]... [--json] [--no-usage] [--watch[=SECONDS]]
    \\       cpuq history [--label PATTERN] [--limit N] [--json]
    \\       cpuq clean [--dry-run] [--older AGE] [--host HOST]
    \\       cpuq record [--interval SECONDS] | --install | --uninstall
    \\       cpuq samples [--since UNIX-SECONDS]
    \\       cpuq cap [--mem SIZE] [--time DURATION] [--output SIZE] [--pids N] -- PROGRAM [ARGS...]
    \\       cpuq submit SPEC [--note TEXT] [--env K=V]... [--replace | --again] [-- ARGS]
    \\       cpuq test SPEC [--on HOST] [--note TEXT] [--env K=V]... [--again] [-- ARGS]
    \\       cpuq packs [--host HOST] | cpuq packs install NAME@VERSION... [--host HOST]
    \\       cpuq jobs [--all]
    \\       cpuq job [ID|last] [--wait [--max-wait S]] [--tail N] [--json] [--cancel]
    \\       cpuq hook                (an agent harness's pre-command hook)
    \\       cpuq budget | --version | --help
    \\
    \\run: M tasks of CMD (none: one, with the terminal), each counting as one CPU. A run starts
    \\a task at once while its project runs under its fair share of the pool, else when the
    \\machine has room (a task that waits on I/O leaves room); the kernel shares the CPUs:
    \\  -n M                  M tasks; each gets CPUQ_TASK (1..M) and CPUQ_TASKS, and its
    \\                        output goes to a file of its own
    \\  -c C | -c P%          run at most C tasks at once, or P% of the pool (default: as the
    \\                        line allows)
    \\  -t T                  each task's time limit, counting only time it runs (30s, 10m,
    \\                        2h; config `timeout`, 1h)
    \\  -r N                  try a failed task up to N more times (CPUQ_ATTEMPT says which)
    \\  --label PROJECT:TASK  the run's name in status and history
    \\  --note TEXT           what the run is for, kept beside its label
    \\  --urgent              its first task goes ahead of the line (a rebuild someone waits on)
    \\  --wait-max S          give up (exit 75) if no task starts within S seconds
    \\  --driver              a test runner that starts `cpuq run`s of its own: no task itself
    \\  --on HOST             run on HOST, one of this machine's remotes (config `remotes`):
    \\                        the repo is copied there with rsync; it waits in HOST's line, and
    \\                        a stopped HOST is started (config `remote_start.HOST`)
    \\  --return PATH         with --on: copy PATH back here afterwards
    \\  --include PATH        with --on: copy PATH there too, gitignored or not,
    \\                        .git included (also listed in the repo's .cpuqinclude)
    \\
    \\commands:
    \\  drain                 for timing: after the runs queued before it that run nothing yet,
    \\                        N whole cores (-c N, their SMT siblings too, at most drain_max,
    \\                        half the pool by default) are isolated for CMD at once: pinned on Linux (CPUQ_CPUS
    \\                        lists them), others' tasks kept off them; macOS stops others'
    \\                        tasks while they would crowd the rest. --cpus LIST names them,
    \\                        --prefer fast takes performance cores first; --quiet-max X
    \\                        (Linux) starts CMD once outside work keeps at most X CPUs busy
    \\                        there; --max T gives up (exit 75); -t T ends CMD (exit 124;
    \\                        default 20m, at most 2h, counted from the isolation)
    \\  kill                  end a run here: SIGTERM to its tasks, SIGKILL 5 s later
    \\  limit                 change a running run's -c (a count or 50%): raised, it starts
    \\                        more as the line allows; lowered, it starts none till fewer run
    \\  lease                 hold one of NAME's --slots places (default 1) while CMD runs, first
    \\                        come first served; --host holds it on HOST over ssh, --hold prints
    \\                        `held NAME@HOST ENTRY` and holds until stdin closes
    \\  wait                  until no run whose label matches (PATTERN* a prefix) runs or waits
    \\  status                running and waiting tasks per project against fair share, the
    \\                        machine's busy CPUs, why each run waits; --json for programs,
    \\                        --watch on a terminal, --host HOST
    \\  history               newest first: --label PATTERN, --limit N (20), --json
    \\  record                sample this machine every 3 s (CPUs busy, load, tasks running,
    \\                        runs waiting, gate) into a day of samples beside the history;
    \\                        --install keeps it running (launchd / systemd --user)
    \\  samples               the recorded samples since a time, one JSON line each
    \\  cap                   run one program under limits on its memory, time and output:
    \\                        for a test runner, around each program it starts (exit 122
    \\                        memory, 124 time, 121 output); on Linux under --driver, a cgroup
    \\                        of its own; elsewhere its process tree read once a second
    \\  hook                  Claude Code PreToolUse hook: refuses heavy commands
    \\                        outside cpuq or misusing it (exit 2, fix on stderr)
    \\  budget                print the pool's size in CPUs
    \\
    \\environment: CPUQ_DIR (state directory), CPUQ_CONFIG (~/.config/cpuq/config),
    \\CPUQ_BUDGET (the pool's size), CPUQ_HISTORY. A task gets CPUQ_TASK, CPUQ_TASKS, CPUQ_OP,
    \\CPUQ_ATTEMPT and CPUQ_ATTEMPTS; a lease's command gets CPUQ_LEASES.
    \\
    \\exit: one task: its own status, 124 at its time limit; many: 0 when every task
    \\passed, else 1; 128+N killed by signal N; 75 gave up waiting (nothing ran);
    \\125 cpuq failed; 126/127 not executable/not found; 2 usage or config error.
    \\
    \\for agents and scripts:
    \\  a build is one task, one job: cpuq run --label app:build -- zig build -j1
    \\  many independent pieces run as tasks: cpuq run -n 40 -- sh -c 'test/one "$CPUQ_TASK"'
    \\  exit 75: nothing ran; run it again later, not in a loop.
    \\  see AGENTS.md: https://github.com/shreeve/cpuq/blob/main/AGENTS.md
    \\
;

/// Exit statuses of cpuq itself (a command's own status passes through).
pub const exit_usage = 2;

pub const exit_timeout = 75;

pub const exit_failure = 125;

pub const exit_noexec = 126;

pub const exit_notfound = 127;

pub const Ctx = struct {
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
    /// The paths `min_disk` watches, found on first use (a waiter reads the
    /// gates twice a second, for hours).
    disk_paths: ?[3]?[:0]const u8 = null,
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
    if (std.mem.eql(u8, cmd, "hook")) return runner.cmdHook(ctx);
    if (std.mem.eql(u8, cmd, "_job")) return runner.cmdJob(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "_task")) return tasks.cmdTask(ctx.io, ctx.arena, ctx.env, args[1..]);
    if (std.mem.eql(u8, cmd, "cap")) return cap.main(ctx.arena, args[1..], ctx.env.get("CPUQ_CGROUP"), ctx.env.get("PATH"));
    if (std.mem.eql(u8, cmd, "run")) return runner.cmdRun(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "drain")) return op.cmdDrain(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "lease")) return leasing.cmdLease(ctx, args[1..]);
    loadConfig(ctx);
    if (std.mem.eql(u8, cmd, "status")) return status.cmdStatus(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "jobs")) {
        // The submitted jobs: this worktree's, or --all.
        const rest = args[1..];
        if (rest.len != 0 and !std.mem.eql(u8, rest[0], "--all")) {
            std.debug.print("cpuq: jobs {s} is gone: a test's tasks run one per CPU of the pool (cpuq test), and tasks of your own with cpuq run -n M; cpuq jobs lists submitted jobs\n", .{rest[0]});
            return exit_usage;
        }
        return submit.cmdJobs(submitCx(ctx), rest);
    }
    if (std.mem.eql(u8, cmd, "wait")) return runner.cmdWait(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "kill")) return op.cmdKill(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "limit")) return op.cmdLimit(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "history")) return records.cmdHistory(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "record")) return records.cmdRecord(ctx, args[1..]);
    inline for (.{
        .{ "submit", submit.cmdSubmit },
        .{ "test", submit.cmdTest },
        .{ "job", submit.cmdJob },
        .{ "_supervise", submit.cmdSupervise },
        .{ "_start", submit.cmdStart },
        .{ "_runjob", submit.cmdHostJob },
        .{ "_peek", submit.cmdPeek },
        .{ "_synced", submit.cmdSynced },
        .{ "_cancel", submit.cmdHostCancel },
        .{ "_pack", submit.cmdPack },
        .{ "packs", submit.cmdPacks },
    }) |entry| {
        if (std.mem.eql(u8, cmd, entry[0])) {
            return entry[1](submitCx(ctx), args[1..]);
        }
    }
    if (std.mem.eql(u8, cmd, "samples")) return records.cmdSamples(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "clean")) return records.cmdClean(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "budget")) {
        ctx.out.print("{d}\n", .{poolCpus(ctx).len}) catch {};
        return 0;
    }
    for (removed_commands) |r| if (std.mem.eql(u8, cmd, r[0])) {
        std.debug.print("cpuq: {s}\n", .{r[1]});
        return exit_usage;
    };
    return usageError("unknown command '{s}'", .{cmd});
}

/// Commands cpuq does not take, each with what does that work.
const removed_commands = [_][2][]const u8{
    .{ "first", "first is gone: --urgent puts a run's first CPU ahead of the line" },
    .{ "start", "start is gone: a free CPU goes to the first in the line" },
    .{ "cancel", "cancel is gone: `cpuq kill TICKET` ends a run, waiting or running" },
    .{ "pause", "pause is gone: Ctrl-Z on a run gives its CPUs back until it continues" },
    .{ "resume", "resume is gone: a run continued after Ctrl-Z takes CPUs again" },
    .{ "stop", "stop is gone: `cpuq kill TICKET` ends a run" },
    .{ "note", "note is gone: `cpuq run --note TEXT` keeps a note beside the label" },
    .{ "doctor", "doctor is gone: cpuq status flags runs over or under their CPUs, and work outside cpuq" },
    .{ "qos", "qos is gone: tasks run as they are" },
    .{ "agent", "agent is gone: the pool shares the machine by itself; stop an installed agent with launchctl bootout gui/$UID/com.github.shreeve.cpuq.agent (macOS) or systemctl --user disable --now cpuq-agent (Linux)" },
    .{ "attach", "attach is gone: cpuq status --json shows every run" },
};

fn submitCx(ctx: *Ctx) submit.Cx {
    const self = std.process.executablePathAlloc(ctx.io, ctx.arena) catch fail("can't find this binary's path", .{});
    return .{ .io = ctx.io, .a = ctx.arena, .env = ctx.env, .out = ctx.out, .version = version, .cfg = &ctx.cfg, .self = self };
}

pub fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("cpuq: " ++ fmt ++ "\n", args);
    std.process.exit(exit_failure);
}

pub fn usageError(comptime fmt: []const u8, args: anytype) u8 {
    std.debug.print("cpuq: " ++ fmt ++ "\n" ++ usage, args);
    return exit_usage;
}

pub fn nowSeconds(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

pub fn loadConfig(ctx: *Ctx) void {
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

/// Re-reads the config file when it has changed since it was read, so a cpuq
/// that runs for long (the recorder) takes up a change. An invalid file keeps
/// the settings in force, and says so once.
pub fn reloadConfig(ctx: *Ctx) void {
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
pub fn stateDir(ctx: *Ctx) []const u8 {
    if (ctx.env.get("CPUQ_DIR")) |d| {
        if (d.len == 0 or d[0] != '/') fail("CPUQ_DIR must be an absolute path, not '{s}'", .{d});
        return d;
    }
    const tmp = Io.Dir.realPathFileAbsoluteAlloc(ctx.io, "/tmp", ctx.arena) catch "/tmp";
    return ctx.arena.print("{s}/cpuq-{d}", .{ tmp, sys.getuid() }) catch fail("out of memory", .{});
}

pub fn machine(ctx: *Ctx) policy.Machine {
    return .{
        .active = sys.activeCpus(ctx.io),
        .load1 = sys.loadAverage()[0],
        .pressure = if (ctx.cfg.pressure_check) sys.memoryPressure(ctx.io, ctx.cfg.pressure_psi) else .off,
        .available = if (ctx.cfg.min_available > 0) sys.memAvailable(ctx.io) else null,
        .disk = if (ctx.cfg.min_disk > 0) leastDisk(ctx) else null,
    };
}

/// The fuller of the filesystems `min_disk` watches: the one holding $HOME,
/// and the one holding the state directory (the temp directory, where
/// builds and agents keep scratch files).
fn leastDisk(ctx: *Ctx) ?policy.Disk {
    const paths = ctx.disk_paths orelse blk: {
        const home: ?[:0]const u8 = if (ctx.env.get("HOME")) |h| ctx.arena.dupeSentinel(u8, h, 0) catch null else null;
        const dir: ?[:0]const u8 = ctx.arena.dupeSentinel(u8, stateDir(ctx), 0) catch null;
        // ~/cpuq, where work sent here from other machines lands: on a machine that gives it its
        // own filesystem (burst's ZFS dataset), the one their copies and scratch fill.
        const root: ?[:0]const u8 = if (ctx.env.get("HOME")) |h| root: {
            const p = ctx.arena.print("{s}/{s}", .{ h, layout.root }) catch break :root null;
            break :root ctx.arena.dupeSentinel(u8, p, 0) catch null;
        } else null;
        ctx.disk_paths = .{ home, dir, root };
        break :blk ctx.disk_paths.?;
    };
    var least: ?policy.Disk = null;
    for (paths) |maybe| {
        const path = maybe orelse continue;
        const free = sys.diskFree(path) orelse continue;
        if (least == null or free < least.?.free) least = .{ .free = free, .path = path };
    }
    return least;
}

/// The pool's CPUs, in the order they are handed out (cpus.zig): the config's `cpus`, else
/// the machine's, the first CPUQ_BUDGET (else `budget`) of them.
pub fn poolCpus(ctx: *Ctx) []const u32 {
    const env_budget: ?u32 = if (ctx.env.get("CPUQ_BUDGET")) |s|
        policy.parseCount(s) orelse fail("CPUQ_BUDGET must be a whole number of CPUs, at least 1, not '{s}'", .{s})
    else
        null;
    return cpus.list(ctx.io, ctx.arena, if (ctx.cfg.cpus.len != 0) ctx.cfg.cpus else null, env_budget orelse ctx.cfg.budget);
}
