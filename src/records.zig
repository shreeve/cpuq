//! `cpuq record`, `cpuq samples` and `cpuq history`: what this machine and its jobs did.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");
const clean = @import("clean.zig");
const history = @import("history.zig");
const table = @import("table.zig");

const main = @import("main.zig");
const joblog = @import("joblog.zig");
const texts = @import("texts.zig");
const admission = @import("admission.zig");
const runtimes = @import("runtimes.zig");

const exit_failure = main.exit_failure;
const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;
const nowSeconds = main.nowSeconds;
const reloadConfig = main.reloadConfig;
const openState = main.openState;
const machine = main.machine;
const budgetNow = main.budgetNow;
const nowFloat = joblog.nowFloat;
const historyPath = joblog.historyPath;
const bytesText = texts.bytesText;
const duration = texts.duration;
const age = texts.age;
const pad = texts.pad;
const dash = texts.dash;
const lockOrFail = admission.lockOrFail;
const aliveForHistory = runtimes.aliveForHistory;

/// The recorder's samples, beside the history: a day or more of the machine every few seconds.
fn samplesPath(ctx: *Ctx) []const u8 {
    const h = historyPath(ctx);
    const dir = std.fs.path.dirname(h) orelse return "";
    return std.mem.concat(ctx.arena, u8, &.{ dir, "/samples.jsonl" }) catch "";
}

/// Past this size the samples file moves to samples.jsonl.1 (one kept), so the two hold at
/// least a day even for a 96-CPU machine sampled every 3 s, and never grow past twice this.
const samples_rotate_bytes = 12 << 20;

const JsonJob = struct {
    id: []const u8,
    state: []const u8,
    pool: []const u8,
    host: ?[]const u8,
    label: []const u8,
    note: []const u8,
    command: []const u8,
    priority: []const u8,
    exclusive: bool,
    min: u32,
    max: u32,
    cores: ?u32,
    slots: ?[]const u32,
    queued: f64,
    started: ?f64,
    ended: ?f64,
    waited: ?f64,
    ran: ?f64,
    used: ?f64,
    exit: ?u8,
    signal: ?u32,
    /// Stopped by cpuq for using this many bytes of memory.
    memory: ?u64 = null,
    /// The most memory it used at once, in bytes.
    peak: ?u64 = null,
    /// A timing window's: CPUs of other work beside it, on average and at
    /// most.
    noise: ?f64 = null,
    noise_peak: ?f64 = null,
    /// The most cores it kept busy over a 2-second look.
    cpu_peak: ?f64 = null,
};

/// `cpuq record`: samples this machine every few seconds into samples.jsonl beside the
/// history, one JSON line each: `t` (Unix seconds), `cpu` (each CPU's busy share since the last
/// sample, in percent, in the kernel's order), `load` (1-minute), `held` (cores handed out),
/// `wait` (jobs waiting) and `gate`. It only watches: nothing in cpuq waits on it or reads it but
/// `cpuq samples`, and every command works the same without it. One runs per machine (a lock
/// beside the file); it exits when its own binary is replaced, so the service that keeps it
/// running starts the new one. `--install` sets up that service: a launchd agent on macOS, a
/// systemd user service on Linux.
pub fn cmdRecord(ctx: *Ctx, args: []const [:0]const u8) u8 {
    const io = ctx.io;
    var interval_ms: u64 = 3000;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (std.mem.eql(u8, x, "--install")) return installRecorder(ctx, true);
        if (std.mem.eql(u8, x, "--uninstall")) return installRecorder(ctx, false);
        if (std.mem.eql(u8, x, "--interval") and i + 1 < args.len) {
            i += 1;
            const secs = std.fmt.parseFloat(f64, args[i]) catch return usageError("--interval needs seconds, not '{s}'", .{args[i]});
            if (secs < 0.1 or secs > 3600) return usageError("--interval must be between 0.1 and 3600 seconds", .{});
            interval_ms = @intFromFloat(secs * 1000);
        } else return usageError("unknown option '{s}'", .{x});
    }
    const path = samplesPath(ctx);
    if (path.len == 0) fail("no HOME, so nowhere to keep samples", .{});
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| cwd.createDirPath(io, d) catch |err| fail("{s}: {t}", .{ d, err });
    const lock_path = ctx.arena.print("{s}.lock", .{path}) catch fail("out of memory", .{});
    const lock = cwd.createFile(io, lock_path, .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false }) catch |err| switch (err) {
        error.WouldBlock => {
            std.debug.print("cpuq: a recorder is already sampling this machine ({s})\n", .{path});
            return 0;
        },
        else => fail("{s}: {t}", .{ lock_path, err }),
    };
    defer lock.close(io);

    // Replaced on upgrade: exit, and launchd or systemd starts the new one.
    const exe = std.process.executablePathAlloc(io, ctx.arena) catch null;
    const born: i96 = if (exe) |e| (if (cwd.statFile(io, e, .{})) |st| st.mtime.nanoseconds else |_| 0) else 0;

    var st = openState(ctx);
    var prev = sys.perCpuTicks(io, ctx.arena);
    var n: u64 = 0;
    std.debug.print("cpuq: recording this machine every {d:.1} s into {s}\n", .{ @as(f64, @floatFromInt(interval_ms)) / 1000, path });
    // `cpuq clean` once an hour, the first a minute in.
    const clean_every: u64 = @max(3600 * 1000 / @max(interval_ms, 1), 1);
    const clean_first: u64 = @max(60 * 1000 / @max(interval_ms, 1), 1);
    while (true) : (n += 1) {
        io.sleep(.fromMilliseconds(@intCast(interval_ms)), .awake) catch {};
        var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const now = nowSeconds(io);
        if (n % clean_every == clean_first % clean_every and ctx.cfg.clean_after_s != 0)
            _ = clean.run(a, io, ctx.env, now, .{ .older_s = ctx.cfg.clean_after_s }, ctx.out);
        const ticks = sys.perCpuTicks(io, a);
        var line: std.ArrayList(u8) = .empty;
        line.print(a, "{{\"t\":{d},\"cpu\":[", .{now}) catch continue;
        if (prev != null and ticks != null and prev.?.len == ticks.?.len) {
            for (prev.?, ticks.?, 0..) |p, q, k| {
                const pct: u32 = if (sys.busyBetween(p, q)) |b| @intFromFloat(@round(b * 100)) else 0;
                line.print(a, "{s}{d}", .{ if (k == 0) "" else ",", pct }) catch {};
            }
        }
        // The next sample's baseline outlives this pass's arena.
        if (ticks) |t| prev = ctx.arena.dupe(sys.Ticks, t) catch prev;
        lockOrFail(&st);
        const queue = state.scanQueue(&st, a, null, .{}, now, ctx.cfg.aging_s) catch @as([]state.Entry, &.{});
        const held = state.heldTokens(&st) catch 0;
        st.unlock();
        const m = machine(ctx);
        const g = policy.gate(ctx.cfg, m, budgetNow(ctx, m), null, now);
        line.print(a, "],\"load\":{d:.2},\"held\":{d},\"wait\":{d},\"gate\":\"{t}\"}}\n", .{ sys.loadAverage()[0], held, queue.len, g }) catch continue;
        history.appendLine(io, path, line.items, samples_rotate_bytes);
        if (n % 20 == 19) {
            if (exe) |e| {
                const now_mtime: i96 = if (cwd.statFile(io, e, .{})) |s2| s2.mtime.nanoseconds else |_| 0;
                if (now_mtime != born) {
                    std.debug.print("cpuq: {s} was replaced; exiting for the new one\n", .{e});
                    return 0;
                }
            }
            reloadConfig(ctx);
        }
    }
}

/// Whether a recorder holds the samples lock now.
pub fn recorderRunning(ctx: *Ctx) bool {
    const path = samplesPath(ctx);
    if (path.len == 0) return false;
    const lock_path = ctx.arena.print("{s}.lock", .{path}) catch return false;
    const f = Io.Dir.cwd().openFile(ctx.io, lock_path, .{}) catch return false;
    defer f.close(ctx.io);
    const free = f.tryLock(ctx.io, .shared) catch return false;
    if (free) f.unlock(ctx.io);
    return !free;
}

/// `cpuq samples [--since T]`: the recorded samples from T (Unix seconds; default the last hour)
/// on, oldest first, one JSON line each, from samples.jsonl.1 and samples.jsonl.
pub fn cmdSamples(ctx: *Ctx, args: []const [:0]const u8) u8 {
    const io = ctx.io;
    const a = ctx.arena;
    var since: i64 = nowSeconds(io) - 3600;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--since") and i + 1 < args.len) {
            i += 1;
            since = std.fmt.parseInt(i64, args[i], 10) catch return usageError("--since needs Unix seconds, not '{s}'", .{args[i]});
        } else return usageError("unknown option '{s}'", .{args[i]});
    }
    const path = samplesPath(ctx);
    for ([_][]const u8{ a.print("{s}.1", .{path}) catch "", path }) |p| {
        const text = Io.Dir.cwd().readFileAlloc(io, p, a, .limited(64 << 20)) catch continue;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const head = "{\"t\":";
            if (!std.mem.startsWith(u8, line, head)) continue;
            const end = std.mem.findScalar(u8, line[head.len..], ',') orelse continue;
            const t = std.fmt.parseInt(i64, line[head.len..][0..end], 10) catch continue;
            if (t < since) continue;
            ctx.out.writeAll(line) catch return exit_failure;
            ctx.out.writeAll("\n") catch return exit_failure;
        }
    }
    ctx.out.flush() catch {};
    return 0;
}

/// `cpuq record --install` (or --uninstall): keeps the recorder running for this user, started
/// at login (and at boot, where systemd allows lingering), restarted if it exits.
fn installRecorder(ctx: *Ctx, install: bool) u8 {
    const io = ctx.io;
    const a = ctx.arena;
    const home = ctx.env.get("HOME") orelse fail("no HOME", .{});
    const exe = std.process.executablePathAlloc(io, a) catch |err| fail("cannot find this cpuq: {t}", .{err});
    const cwd = Io.Dir.cwd();
    if (@import("builtin").os.tag.isDarwin()) {
        const label = "com.github.shreeve.cpuq.record";
        const plist = a.print("{s}/Library/LaunchAgents/{s}.plist", .{ home, label }) catch fail("out of memory", .{});
        const domain = a.print("gui/{d}", .{sys.getuid()}) catch fail("out of memory", .{});
        _ = std.process.run(a, io, .{ .argv = &.{ "launchctl", "bootout", a.print("{s}/{s}", .{ domain, label }) catch "" } }) catch {};
        if (!install) {
            cwd.deleteFile(io, plist) catch {};
            ctx.out.writeAll("cpuq record: uninstalled (launchd agent removed)\n") catch {};
            return 0;
        }
        cwd.createDirPath(io, std.fs.path.dirname(plist).?) catch {};
        const body = a.print(
            \\<?xml version="1.0" encoding="UTF-8"?>
            \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            \\<plist version="1.0">
            \\<dict>
            \\  <key>Label</key><string>{s}</string>
            \\  <key>ProgramArguments</key><array><string>{s}</string><string>record</string></array>
            \\  <key>RunAtLoad</key><true/>
            \\  <key>KeepAlive</key><true/>
            \\  <key>ProcessType</key><string>Background</string>
            \\  <key>StandardErrorPath</key><string>{s}/Library/Logs/cpuq-record.log</string>
            \\</dict>
            \\</plist>
            \\
        , .{ label, exe, home }) catch fail("out of memory", .{});
        cwd.writeFile(io, .{ .sub_path = plist, .data = body }) catch |err| fail("{s}: {t}", .{ plist, err });
        const r = std.process.run(a, io, .{ .argv = &.{ "launchctl", "bootstrap", domain, plist } }) catch |err| fail("launchctl: {t}", .{err});
        if (!r.term.success()) fail("launchctl bootstrap: {s}", .{std.mem.trim(u8, r.stderr, " \n")});
        ctx.out.print("cpuq record: installed as launchd agent {s}, running now\n", .{label}) catch {};
        return 0;
    }
    const unit_dir = a.print("{s}/.config/systemd/user", .{home}) catch fail("out of memory", .{});
    const unit = a.print("{s}/cpuq-record.service", .{unit_dir}) catch fail("out of memory", .{});
    if (!install) {
        _ = std.process.run(a, io, .{ .argv = &.{ "systemctl", "--user", "disable", "--now", "cpuq-record.service" } }) catch {};
        cwd.deleteFile(io, unit) catch {};
        _ = std.process.run(a, io, .{ .argv = &.{ "systemctl", "--user", "daemon-reload" } }) catch {};
        ctx.out.writeAll("cpuq record: uninstalled (systemd user service removed)\n") catch {};
        return 0;
    }
    cwd.createDirPath(io, unit_dir) catch {};
    const body = a.print(
        \\[Unit]
        \\Description=cpuq record: samples this machine for cpuq samples and Cpuq.app
        \\
        \\[Service]
        \\ExecStart={s} record
        \\Restart=always
        \\RestartSec=5
        \\Nice=10
        \\
        \\[Install]
        \\WantedBy=default.target
        \\
    , .{exe}) catch fail("out of memory", .{});
    cwd.writeFile(io, .{ .sub_path = unit, .data = body }) catch |err| fail("{s}: {t}", .{ unit, err });
    for ([_][]const []const u8{ &.{ "systemctl", "--user", "daemon-reload" }, &.{ "systemctl", "--user", "enable", "--now", "cpuq-record.service" } }) |argv| {
        const r = std.process.run(a, io, .{ .argv = argv }) catch |err| fail("systemctl: {t}", .{err});
        if (!r.term.success()) fail("{s}: {s}", .{ argv[2], std.mem.trim(u8, r.stderr, " \n") });
    }
    // Without lingering, user services stop at logout and start only at login.
    const user = ctx.env.get("USER") orelse "";
    const linger = std.process.run(a, io, .{ .argv = &.{ "loginctl", "enable-linger", user } }) catch null;
    const lingers = linger != null and linger.?.term.success();
    ctx.out.print("cpuq record: installed as systemd user service cpuq-record, running now{s}\n", .{if (lingers) " (lingering: it runs without a login)" else "; `loginctl enable-linger` failed, so it runs only while you are logged in"}) catch {};
    return 0;
}

/// `cpuq history [--label PATTERN] [--limit N] [--json]`: finished, lost and
/// running jobs from the history file, newest first, with a summary.
pub fn cmdHistory(ctx: *Ctx, args: []const [:0]const u8) u8 {
    var pattern: ?[]const u8 = null;
    var limit: usize = 20;
    var json = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
            continue;
        }
        const name, const inline_value = std.mem.cutScalar(u8, arg, '=') orelse .{ arg, null };
        const is_label = std.mem.eql(u8, name, "--label");
        const is_limit = std.mem.eql(u8, name, "--limit");
        if (!is_label and !is_limit) return usageError("unknown history option '{s}'", .{arg});
        const value = inline_value orelse blk: {
            i += 1;
            if (i >= args.len) return usageError("{s} needs a value", .{name});
            break :blk args[i];
        };
        if (is_label) pattern = value else limit = std.fmt.parseInt(usize, value, 10) catch
            return usageError("--limit needs a whole number, not '{s}'", .{value});
    }
    const io = ctx.io;
    const a = ctx.arena;
    const path = historyPath(ctx);
    const all = history.load(io, a, path, sys.bootTime(io), &aliveForHistory);

    // Newest first, filtered, limited.
    var picked: std.ArrayList(history.Job) = .empty;
    var k = all.len;
    while (k > 0 and picked.items.len < limit) {
        k -= 1;
        const j = all[k];
        if (pattern) |p| if (!history.labelMatches(p, j.label)) continue;
        picked.append(a, j) catch break;
    }
    std.mem.sortUnstable(history.Job, picked.items, {}, struct {
        fn newer(_: void, x: history.Job, y: history.Job) bool {
            return x.last() > y.last();
        }
    }.newer);

    const w = ctx.out;
    if (json) {
        var out: std.ArrayList(JsonJob) = .empty;
        for (picked.items) |j| out.append(a, .{
            .id = j.id,
            .state = @tagName(j.state),
            .pool = j.pool,
            .host = j.host,
            .label = j.label,
            .note = j.note,
            .command = j.cmd,
            .priority = j.priority,
            .exclusive = j.exclusive,
            .min = j.min,
            .max = j.max,
            .cores = j.cores,
            .slots = j.slots,
            .queued = j.queued,
            .started = j.started,
            .ended = j.ended,
            .waited = j.waited(),
            .ran = j.ran(),
            .used = j.used(),
            .exit = j.exit,
            .signal = j.signal,
            .memory = j.memory,
            .peak = j.peak,
            .noise = j.noise,
            .noise_peak = j.noise_peak,
            .cpu_peak = j.cpu_peak,
        }) catch {};
        std.json.Stringify.value(out.items, .{ .whitespace = .indent_2 }, w) catch {};
        w.writeAll("\n") catch {};
        return 0;
    }
    if (picked.items.len == 0) {
        w.print("no jobs in {s}{s}\n", .{ path, if (pattern != null) " with that label" else "" }) catch {};
        return 0;
    }

    const now = nowFloat(io);
    const boxed = std.c.isatty(1) != 0;
    const color = boxed and ctx.env.get("NO_COLOR") == null;
    var trows: std.ArrayList([]const table.Cell) = .empty;
    var lw: usize = 5;
    var pw: usize = 4;
    for (picked.items) |j| {
        lw = @max(lw, @min(dash(j.label).len, 32));
        pw = @max(pw, @min(j.pool.len, 20));
    }
    var lbuf: [40]u8 = undefined;
    var pbuf: [24]u8 = undefined;
    if (!boxed) w.print("  WHEN     {s} {s} IN USE WAITED   RAN      ACTIVE MEMORY EXIT\n", .{ pad(&lbuf, "LABEL", lw), pad(&pbuf, "POOL", pw) }) catch {};
    for (picked.items) |j| {
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        var b3: [16]u8 = undefined;
        var b4: [16]u8 = undefined;
        var b5: [16]u8 = undefined;
        var b6: [24]u8 = undefined;
        var b7: [16]u8 = undefined;
        const mem_text = if (j.peak) |m| bytesText(&b7, m) else "-";
        const cores_text = if (j.cores) |c| std.mem.print(&b2, "{d}", .{c}) catch "?" else if (j.max > j.min) std.mem.print(&b2, "{d}-{d}", .{ j.min, j.max }) catch "?" else "-";
        const waited_text = if (j.waited()) |x| duration(&b3, x) else "-";
        const ran_text = if (j.ran()) |x| duration(&b4, x) else "-";
        const used_text = if (j.used()) |x| std.mem.print(&b5, "{d:.1}", .{x}) catch "?" else "-";
        const exit_text: []const u8 = switch (j.state) {
            .done => if (j.memory) |m| std.mem.print(&b6, "memory {d:.1}G", .{@as(f64, @floatFromInt(m)) / (1 << 30)}) catch "memory" else if (j.signal) |sig| std.mem.print(&b6, "signal {d}", .{sig}) catch "signal" else std.mem.print(&b6, "{d}", .{j.exit orelse 0}) catch "?",
            .gave_up => "gave up",
            .lost => "lost",
            .active => if (j.started != null) "running" else "waiting",
        };
        if (boxed) {
            const exit_tint: table.Tint = switch (j.state) {
                .done => if (j.signal == null and (j.exit orelse 0) == 0) .good else .bad,
                .gave_up => .warn,
                .lost => .bad,
                .active => .accent,
            };
            const used_tint: ?table.Tint = if (j.used()) |u| (if (j.cores) |c| (if (c >= 2 and u * 2 < @as(f64, @floatFromInt(c))) table.Tint.warn else null) else null) else .dim;
            trows.append(a, a.dupe(table.Cell, &.{
                .{ .text = a.dupe(u8, age(&b1, @intFromFloat(now - j.last()))) catch "?", .tint = .dim },
                .{ .text = dash(j.label), .tint = .accent },
                .{ .text = j.pool },
                .{ .text = a.dupe(u8, cores_text) catch "?" },
                .{ .text = a.dupe(u8, waited_text) catch "?" },
                .{ .text = a.dupe(u8, ran_text) catch "?" },
                .{ .text = a.dupe(u8, used_text) catch "?", .tint = used_tint },
                .{ .text = a.dupe(u8, mem_text) catch "?", .tint = if (j.peak == null) .dim else null },
                .{ .text = a.dupe(u8, exit_text) catch "?", .tint = exit_tint },
            }) catch continue) catch {};
            continue;
        }
        w.print("  {s:<8} {s} {s} {s:<6} {s:<8} {s:<8} {s:<6} {s:<6} {s}\n", .{
            age(&b1, @intFromFloat(now - j.last())), pad(&lbuf, dash(j.label), lw), pad(&pbuf, j.pool, pw),
            cores_text,                              waited_text,                   ran_text,
            used_text,                               mem_text,                      exit_text,
        }) catch {};
    }

    // The summary: how long jobs waited, and what they used of what they got.
    var waits: std.ArrayList(f64) = .empty;
    var granted: f64 = 0;
    var used: f64 = 0;
    var measured: usize = 0;
    var lost: usize = 0;
    for (picked.items) |j| {
        if (j.waited()) |x| waits.append(a, x) catch {};
        if (j.state == .lost) lost += 1;
        if (j.used()) |u| if (j.cores) |c| if (std.mem.eql(u8, j.pool, "cores")) {
            used += u;
            granted += @floatFromInt(c);
            measured += 1;
        };
    }
    var longest: f64 = 0;
    for (waits.items) |x| longest = @max(longest, x);
    var b1: [16]u8 = undefined;
    var b2: [16]u8 = undefined;
    var sum: std.ArrayList(u8) = .empty;
    sum.print(a, "{d} jobs; waited {s} median, {s} longest", .{ picked.items.len, duration(&b1, history.median(waits.items)), duration(&b2, longest) }) catch {};
    if (measured != 0) {
        const m: f64 = @floatFromInt(measured);
        sum.print(a, "; {d:.1} active of {d:.1} cores in use on average", .{ used / m, granted / m }) catch {};
    }
    if (lost != 0) sum.print(a, "; {d} lost (the machine restarted or cpuq was killed)", .{lost}) catch {};
    if (boxed) {
        const t: table.Table = .{
            .title = if (pattern) |p| a.print("history · {s}", .{p}) catch "history" else "history",
            .columns = &.{
                .{ .head = "WHEN" },
                .{ .head = "LABEL" },
                .{ .head = "POOL" },
                .{ .head = "IN USE", .alignment = .right },
                .{ .head = "WAITED", .alignment = .right },
                .{ .head = "RAN", .alignment = .right },
                .{ .head = "ACTIVE", .alignment = .right },
                .{ .head = "MEMORY", .alignment = .right },
                .{ .head = "EXIT", .flexible = true },
            },
            .rows = trows.items,
            .notes = &.{sum.items},
        };
        t.boxed(a, w, table.terminalWidth(1), color) catch {};
        return 0;
    }
    w.print("\n{s}\n", .{sum.items}) catch {};
    return 0;
}
