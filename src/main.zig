//! cpuq: a machine-wide CPU core queue. Jobs wait their turn for a number
//! of cores out of a budget, then run in the foreground holding them. There
//! is no daemon: every hold is a flock(2) in the state directory.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");
const gitship = @import("gitship.zig");
const clean = @import("clean.zig");
const packs_mod = @import("packs.zig");

const history = @import("history.zig");
const layout = @import("layout.zig");
const hook = @import("hook.zig");
const table = @import("table.zig");
const cap = @import("cap.zig");
const submit = @import("submit.zig");
const place = @import("place.zig");

const runopts = @import("runopts.zig");
const repos = @import("repos.zig");
const joblog = @import("joblog.zig");
const texts = @import("texts.zig");
const admission = @import("admission.zig");
const runner = @import("runner.zig");
const leasing = @import("leasing.zig");
const timing = @import("timing.zig");
const remotes = @import("remotes.zig");
const control = @import("control.zig");
const doctor = @import("doctor.zig");
const records = @import("records.zig");
const runtimes = @import("runtimes.zig");
const statusjson = @import("statusjson.zig");
const status = @import("status.zig");

const cmdRun = runner.cmdRun;
const cmdJob = runner.cmdJob;
const cmdLease = leasing.cmdLease;
const cmdClean = control.cmdClean;
const cmdNote = control.cmdNote;
const cmdControl = control.cmdControl;
const cmdWait = control.cmdWait;
const cmdHook = doctor.cmdHook;
const cmdDoctor = doctor.cmdDoctor;
const cmdRecord = records.cmdRecord;
const cmdSamples = records.cmdSamples;
const cmdHistory = records.cmdHistory;
const cmdStatus = status.cmdStatus;

test {
    _ = cap;
    _ = submit;
    _ = hook;
    _ = policy;
    _ = state;
    _ = history;
    _ = table;
    _ = gitship;
    _ = packs_mod;
    _ = clean;
    _ = place;
    _ = sys;
    _ = layout;
    _ = runopts;
    _ = repos;
    _ = joblog;
    _ = texts;
    _ = admission;
    _ = runner;
    _ = leasing;
    _ = timing;
    _ = remotes;
    _ = control;
    _ = doctor;
    _ = records;
    _ = runtimes;
    _ = statusjson;
    _ = status;
}

pub const version = @import("build_options").version;

const usage =
    \\usage: cpuq run [run options] [--] CMD [ARGS...]
    \\       cpuq lease NAME [lease options] [--] CMD [ARGS...]
    \\       cpuq lease NAME --host HOST --hold [lease options]
    \\       cpuq wait --label PATTERN [--max-wait SECONDS]
    \\       cpuq status [--host HOST]... [--json] [--no-usage] [--watch[=SECONDS]]
    \\       cpuq history [--label PATTERN] [--limit N] [--json]
    \\       cpuq first|start|cancel|pause|resume|stop LABEL|PID [--all] [--host HOST]
    \\       cpuq doctor [--host HOST]
    \\       cpuq clean [--dry-run] [--older AGE] [--host HOST]
    \\       cpuq record [--interval SECONDS] | --install | --uninstall
    \\       cpuq samples [--since UNIX-SECONDS]
    \\       cpuq cap [--mem SIZE] [--time DURATION] [--output SIZE] [--pids N] -- PROGRAM [ARGS...]
    \\       cpuq note PID|LABEL TEXT [--all] [--host HOST]
    \\       cpuq submit SPEC [--note TEXT] [--env K=V]... [--replace | --again] [-- ARGS]
    \\       cpuq packs [--host HOST] | cpuq packs install NAME@VERSION... [--host HOST]
    \\       cpuq jobs [--all]
    \\       cpuq job [ID|last] [--wait [--max-wait S]] [--tail N] [--json] [--cancel]
    \\       cpuq hook                (an agent harness's pre-command hook)
    \\       cpuq budget | qos | --version | --help
    \\
    \\run options:
    \\  --cores K             exactly K cores
    \\  --cores MIN-MAX       MIN to MAX, as many as there is room for
    \\                        (none: sized from the label's history, else 2)
    \\  --label PROJECT:TASK  the job's name; history sizes and times jobs by it
    \\  --priority P          high, normal (default) or low
    \\  --max-wait SECONDS    give up after this long (exit 75); 0: start now or
    \\                        give up
    \\  --exclusive           hold the machine alone once it drains (timing only)
    \\  --opaque              its work runs where cpuq can't see it (a container,
    \\                        a VM): counted at its whole grant; give --cores
    \\  --no-load-check       ignore the load valve
    \\  --qos none|auto       none: leave the command's scheduling class alone
    \\  --on HOST             run on HOST, one of this machine's remotes (config
    \\                        `remotes`), or this machine itself: the repo is copied
    \\                        there with rsync; it queues there if HOST is busy, and
    \\                        a stopped HOST is started (config `remote_start.HOST`)
    \\  --return PATH         with --on: copy PATH back here afterwards
    \\  --include PATH        with --on: copy PATH there too, gitignored or not,
    \\                        .git included (also listed in the repo's .cpuqinclude)
    \\
    \\lease options (NAME: letters, digits, . _ -):
    \\  --slots N             let N hold NAME at once (default 1)
    \\  --host HOST           hold NAME on HOST's cpuq over ssh while CMD runs here
    \\  --hold                with --host and no CMD: once granted, print
    \\                        `held NAME@HOST ENTRY` and hold until stdin closes
    \\  --exclusive           also hold the machine alone (HOST's, with --host)
    \\  --priority, --label, --max-wait   as for run
    \\
    \\commands:
    \\  wait                  until no job whose label matches runs or waits
    \\  status                --json for programs, --watch on a terminal, --host HOST
    \\  history               newest first: --label PATTERN, --limit N (20), --json
    \\  first                 move a waiting job to the front
    \\  start                 start a waiting job now, past the queue and the gates
    \\  cancel                take a waiting job out of the queue (it exits 75)
    \\  pause | resume        SIGSTOP | SIGCONT a running job's process tree
    \\  stop                  SIGTERM a running job's process tree
    \\  doctor                what's wrong that cpuq sees but can't stop: work
    \\                        outside it, jobs over their grant, parked jobs,
    \\                        requests too big to start; exit 1 if any
    \\  record                sample this machine every 3 s (CPUs busy, load, cores held,
    \\                        waiting, gate) into a day of samples beside the history;
    \\                        --install keeps it running (launchd / systemd --user)
    \\  samples               the recorded samples since a time, one JSON line each
    \\  cap                   run one program under limits on its memory, time and output:
    \\                        for a test runner, around each program it starts (exit 122
    \\                        memory, 124 time, 121 output); a cgroup of its own inside a job
    \\                        on Linux, its own process tree read once a second elsewhere
    \\  hook                  Claude Code PreToolUse hook: refuses heavy commands
    \\                        outside cpuq or misusing it (exit 2, fix on stderr)
    \\  budget | qos          print the budget | this process's scheduling class
    \\  (a LABEL ending in * is a prefix; several matches need --all)
    \\
    \\environment: CPUQ_DIR (state directory), CPUQ_CONFIG (~/.config/cpuq/config),
    \\CPUQ_BUDGET, CPUQ_HISTORY. A run's command gets CPUQ_CORES (its grant),
    \\CPUQ_TOKEN and a GNU make jobserver in MAKEFLAGS; a lease's gets CPUQ_LEASES.
    \\
    \\exit: the command's own status; 128+N killed by signal N; 75 gave up waiting
    \\(the command never ran); 125 cpuq failed; 126/127 not executable/not found;
    \\2 usage or config error.
    \\
    \\for agents and scripts:
    \\  pass the grant in single quotes, so it is expanded after cpuq sets it:
    \\    cpuq run --label app:build --cores 2-6 -- sh -c 'zig build -j"$CPUQ_CORES"'
    \\  plain `make` needs no -j: it takes its slots from the jobserver.
    \\  exit 75: the command never ran; run it again later, not in a loop.
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
    if (std.mem.eql(u8, cmd, "hook")) return cmdHook(ctx);
    if (std.mem.eql(u8, cmd, "_job")) return cmdJob(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "cap")) return cap.main(ctx.arena, args[1..], ctx.env.get("CPUQ_CGROUP"), ctx.env.get("PATH"));
    if (std.mem.eql(u8, cmd, "run")) return cmdRun(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "lease")) return cmdLease(ctx, args[1..]);
    loadConfig(ctx);
    if (std.mem.eql(u8, cmd, "status")) return cmdStatus(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "wait")) return cmdWait(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "history")) return cmdHistory(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "doctor")) return cmdDoctor(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "record")) return cmdRecord(ctx, args[1..]);
    inline for (.{
        .{ "submit", submit.cmdSubmit },
        .{ "jobs", submit.cmdJobs },
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
            const self = std.process.executablePathAlloc(ctx.io, ctx.arena) catch fail("can't find this binary's path", .{});
            const cx: submit.Cx = .{ .io = ctx.io, .a = ctx.arena, .env = ctx.env, .out = ctx.out, .version = version, .cfg = &ctx.cfg, .self = self };
            return entry[1](cx, args[1..]);
        }
    }
    if (std.mem.eql(u8, cmd, "samples")) return cmdSamples(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "note")) return cmdNote(ctx, args[1..]);
    if (std.mem.eql(u8, cmd, "clean")) return cmdClean(ctx, args[1..]);
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

/// Re-reads the config file when it has changed since it was read, so a run
/// already waiting takes up a new budget or margin. An invalid file keeps
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

pub fn openState(ctx: *Ctx) state.State {
    const dir = stateDir(ctx);
    return state.State.open(ctx.io, dir) catch |err| fail("state directory {s}: {t}", .{ dir, err });
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

fn envBudget(ctx: *Ctx) ?u32 {
    const s = ctx.env.get("CPUQ_BUDGET") orelse return null;
    return policy.parseCount(s) orelse fail("CPUQ_BUDGET must be a whole number of cores, at least 1, not '{s}'", .{s});
}

pub fn budgetNow(ctx: *Ctx, m: policy.Machine) u32 {
    return policy.effectiveBudget(envBudget(ctx), ctx.cfg, m.active);
}
