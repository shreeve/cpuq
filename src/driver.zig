//! `cpuq driver [--load L] [--until-done] [--install | --uninstall]`: the one owner of this
//! host's jobs folder. It runs each job's base process under cap, hands it tasks by moving their
//! files from todo/ to live/ and writing `SLOT PATH` on the base's fd 3, and files each answer
//! (`STATUS CPU_MS PEAK PATH`) in done/ or died/. Which task starts next, and how many run, is
//! pool.zig's to say; this is the I/O around it, one thread in one poll().
//!
//! Every base's cap watches the link, a pipe whose only write end the driver holds, so every
//! tree dies with the driver. A file in live/ that this driver isn't running is try-locked each
//! second: free means nothing runs it, and it goes back to todo/ (a base that died, or a driver
//! before this one); held means its old run is still ending.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const Io = std.Io;
const jobs = @import("jobs.zig");
const pool_mod = @import("pool.zig");
const sys = @import("sys.zig");
const main = @import("main.zig");
const Allocator = std.mem.Allocator;

const Ctx = main.Ctx;
const usageError = main.usageError;
const fail = main.fail;

const is_linux = builtin.os.tag == .linux;

/// A task handed out: its file in live/, its slot, and when it was (or will be) sent.
const Live = struct {
    slot: u32,
    /// Absolute, in live/; also its key in `Stamp.live`.
    path: [:0]u8,
    /// Monotonic ms: when to send it (`--delay`), then when it was sent.
    due: i64,
    sent: bool = false,
};

/// A running base: its cap's pid, and the driver's end of its fd 3.
const Proc = struct {
    pid: c.pid_t,
    sock: c.fd_t,
    out: std.ArrayList(u8) = .empty,
    in: std.ArrayList(u8) = .empty,
};

/// One submission the driver follows: a job's newest, or an older one whose tasks still run.
const Stamp = struct {
    /// `job/stamp`, the pool's name for it.
    key: []u8,
    job: []const u8,
    name: []const u8,
    dir: []u8,
    arena: std.heap.ArenaAllocator,
    base: jobs.Base = .{},
    base_mtime: i96 = -1,
    todo_mtime: i96 = -1,
    proc: ?Proc = null,
    live: std.StringArrayHashMapUnmanaged(Live) = .empty,
    seen: bool = false,
};

const Driver = struct {
    gpa: Allocator,
    io: Io,
    root: []const u8,
    host: []const u8,
    exe: [:0]const u8,
    env: []const [:0]const u8,
    load: ?f64,
    pool: pool_mod.Pool,
    stamps: std.StringArrayHashMapUnmanaged(*Stamp) = .empty,
    /// Bases the driver closed: their end is no death.
    closing: std.AutoHashMapUnmanaged(c.pid_t, void) = .empty,
    link: c.fd_t,
    prng: std.Random.DefaultPrng,
    sum: f64 = 0,
    samples: u32 = 0,
    ticked: bool = false,

    fn print(d: *Driver, comptime fmt: []const u8, args: anytype) [:0]u8 {
        return std.fmt.allocPrintSentinel(d.gpa, fmt, args, 0) catch oom();
    }

    fn cfgOf(st: *const Stamp, stopped: bool) pool_mod.Config {
        var cfg = st.base.job;
        cfg.stopped = stopped or st.base.cmd.len == 0;
        cfg.since = jobs.stampKey(st.name);
        return cfg;
    }

    // --- The folders, once a second ----------------------------------------------------------

    fn scan(d: *Driver, scratch: Allocator) void {
        for (d.stamps.values()) |st| st.seen = false;
        for (children(d.io, scratch, d.root, .directory)) |job| {
            if (!jobs.visible(job)) continue;
            const job_dir = std.fmt.allocPrint(scratch, "{s}/{s}", .{ d.root, job }) catch continue;
            const stop = exists(d.io, scratch, job_dir, "stop");
            const names = children(d.io, scratch, job_dir, .directory);
            var newest: ?[]const u8 = null;
            for (names) |n| if (jobs.visible(n) and jobs.stampKey(n) > 0) {
                if (newest == null or jobs.stampKey(n) > jobs.stampKey(newest.?)) newest = n;
            };
            for (names) |n| {
                if (!jobs.visible(n) or jobs.stampKey(n) <= 0) continue;
                const is_newest = n.ptr == newest.?.ptr;
                const key = std.fmt.allocPrint(scratch, "{s}/{s}", .{ job, n }) catch continue;
                const tracked = d.stamps.get(key);
                const busy = if (tracked) |st| st.live.count() > 0 else false;
                if (!is_newest and !busy and !hasFiles(d.io, scratch, d.root, key, "live")) continue;
                const st = tracked orelse d.track(key) orelse continue;
                st.seen = true;
                d.follow(scratch, st, stop or !is_newest);
            }
        }
        // What wasn't seen is gone, or old and idle.
        var i: usize = d.stamps.count();
        while (i > 0) {
            i -= 1;
            const st = d.stamps.values()[i];
            if (st.seen) continue;
            const gone = Io.Dir.cwd().statFile(d.io, st.dir, .{}) == error.FileNotFound;
            d.untrack(st, gone);
        }
    }

    fn track(d: *Driver, key: []const u8) ?*Stamp {
        const st = d.gpa.create(Stamp) catch oom();
        const owned = d.gpa.dupe(u8, key) catch oom();
        const slash = std.mem.findScalar(u8, owned, '/').?;
        st.* = .{
            .key = owned,
            .job = owned[0..slash],
            .name = owned[slash + 1 ..],
            .dir = std.fmt.allocPrint(d.gpa, "{s}/{s}", .{ d.root, owned }) catch oom(),
            .arena = .init(d.gpa),
        };
        d.stamps.put(d.gpa, owned, st) catch oom();
        d.pool.configure(owned, cfgOf(st, true)) catch oom();
        return st;
    }

    /// Stops following a submission: its base is closed (and, when its folder is gone, its tree
    /// ended now), and the pool forgets it.
    fn untrack(d: *Driver, st: *Stamp, gone: bool) void {
        if (st.proc) |p| {
            d.closeBase(st);
            if (gone) _ = c.kill(p.pid, .TERM); // cap passes it on, then ends the tree
        }
        for (st.live.values()) |l| d.gpa.free(l.path);
        st.live.deinit(d.gpa);
        d.pool.remove(st.key);
        _ = d.stamps.swapRemove(st.key);
        st.arena.deinit();
        d.gpa.free(st.dir);
        d.gpa.free(st.key);
        d.gpa.destroy(st);
    }

    /// One submission's second: its base file if it changed, its live/ swept, its todo/ read if
    /// it changed.
    fn follow(d: *Driver, scratch: Allocator, st: *Stamp, stopped: bool) void {
        const io = d.io;
        const cwd = Io.Dir.cwd();
        const base_path = std.fmt.allocPrint(scratch, "{s}/base", .{st.dir}) catch return;
        const base_mtime = if (cwd.statFile(io, base_path, .{})) |bs| bs.mtime.nanoseconds else |_| st.base_mtime;
        if (base_mtime != st.base_mtime) {
            st.base_mtime = base_mtime;
            const a = st.arena.allocator();
            if (cwd.readFileAlloc(io, base_path, a, .limited(1 << 20))) |text| {
                var bad: std.ArrayList([]const u8) = .empty;
                st.base = jobs.parseBase(a, text, st.base, &bad);
                for (bad.items) |line| std.debug.print("cpuq driver: {s}/base: can't read '{s}': kept what it had\n", .{ st.key, line });
            } else |_| {}
        }
        d.pool.configure(st.key, cfgOf(st, stopped)) catch oom();

        const live_dir = std.fmt.allocPrint(scratch, "{s}/live", .{st.dir}) catch return;
        for (children(io, scratch, live_dir, .file)) |n| {
            if (!jobs.visible(n)) continue;
            const path = std.fmt.allocPrintSentinel(scratch, "{s}/{s}", .{ live_dir, n }, 0) catch continue;
            if (st.live.contains(path)) continue;
            const fd = jobs.lockTask(path) orelse continue;
            defer _ = c.close(fd);
            const to = std.fmt.allocPrintSentinel(scratch, "{s}/todo/{s}", .{ st.dir, n }, 0) catch continue;
            _ = c.rename(path, to);
        }

        const todo_dir = std.fmt.allocPrint(scratch, "{s}/todo", .{st.dir}) catch return;
        // The folder's time before its names: a file added after the listing changes it again.
        const s = cwd.statFile(io, todo_dir, .{}) catch return;
        if (s.mtime.nanoseconds == st.todo_mtime) return;
        st.todo_mtime = s.mtime.nanoseconds;
        const New = struct { name: []const u8, at: i96 };
        var fresh: std.ArrayList(New) = .empty;
        var dir = cwd.openDir(io, todo_dir, .{ .iterate = true }) catch return;
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |e| {
            if (e.kind != .file or !jobs.visible(e.name) or d.pool.knows(st.key, e.name)) continue;
            const at = if (dir.statFile(io, e.name, .{})) |fs| fs.mtime.nanoseconds else |_| 0;
            fresh.append(scratch, .{ .name = scratch.dupe(u8, e.name) catch continue, .at = at }) catch continue;
        }
        std.mem.sort(New, fresh.items, {}, struct {
            fn lt(_: void, x: New, y: New) bool {
                return x.at < y.at or (x.at == y.at and std.mem.lessThan(u8, x.name, y.name));
            }
        }.lt);
        for (fresh.items) |f| d.pool.add(st.key, f.name) catch oom();
    }

    // --- Starting tasks ----------------------------------------------------------------------

    fn schedule(d: *Driver) void {
        const now = sys.monoMs();
        while (d.pool.next(now, d.prng.random()) catch oom()) |s| d.start(s, now);
    }

    fn start(d: *Driver, s: pool_mod.Start, now: i64) void {
        const st = d.stamps.get(s.job).?;
        const from = d.print("{s}/todo/{s}", .{ st.dir, s.task });
        defer d.gpa.free(from);
        const path = d.print("{s}/live/{s}", .{ st.dir, s.task });
        if (c.rename(from, path) != 0) {
            d.gpa.free(path);
            d.pool.dropped(st.key, s.slot);
            return;
        }
        _ = jobs.startRecord(path, d.host, s.slot, main.nowSeconds(d.io));
        if (st.proc == null) d.startBase(st) catch |err| {
            std.debug.print("cpuq driver: {s}: its base can't start: {t}\n", .{ st.key, err });
            _ = c.rename(path, from);
            d.gpa.free(path);
            d.pool.dropped(st.key, s.slot);
            d.stopJob(st, "its base could not start");
            return;
        };
        st.live.put(d.gpa, path, .{ .slot = s.slot, .path = path, .due = now + @as(i64, @intCast(s.delay_ms)) }) catch oom();
        if (s.delay_ms == 0) d.send(st, st.live.getPtr(path).?, now);
    }

    fn send(d: *Driver, st: *Stamp, l: *Live, now: i64) void {
        const p = &st.proc.?;
        p.out.print(d.gpa, "{d} {s}\n", .{ l.slot, l.path }) catch oom();
        l.sent = true;
        l.due = now;
        flush(p);
    }

    fn sendDue(d: *Driver, now: i64) i64 {
        var soonest: i64 = std.math.maxInt(i64);
        for (d.stamps.values()) |st| {
            if (st.proc == null) continue;
            for (st.live.values()) |*l| if (!l.sent) {
                if (l.due <= now) d.send(st, l, now) else soonest = @min(soonest, l.due);
            };
        }
        return soonest;
    }

    /// Starts a submission's base under cap: `fork: yes`, its own command; else `cpuq _base`.
    fn startBase(d: *Driver, st: *Stamp) !void {
        const a = st.arena.allocator();
        var sv: [2]c.fd_t = undefined;
        if (c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &sv) != 0) return error.SocketFailed;
        for (sv) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        _ = c.fcntl(sv[0], c.F.SETFL, c.fcntl(sv[0], c.F.GETFL, @as(c_int, 0)) | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
        if (builtin.os.tag.isDarwin()) {
            const one: c_int = 1;
            _ = c.setsockopt(sv[0], c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
        }
        defer _ = c.close(sv[1]);
        errdefer _ = c.close(sv[0]);
        const log_path = d.print("{s}/log", .{st.dir});
        defer d.gpa.free(log_path);
        const log = c.open(log_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, @as(c.mode_t, 0o644));
        if (log < 0) return error.NoLog;
        defer _ = c.close(log);

        var argv: std.ArrayList(?[*:0]const u8) = .empty;
        const link_arg = try std.fmt.allocPrintSentinel(a, "{d}", .{d.link}, 0);
        try argv.appendSlice(a, &.{ d.exe.ptr, "cap", "--link", link_arg.ptr, "--" });
        const base_path = try std.fmt.allocPrintSentinel(a, "{s}/base", .{st.dir}, 0);
        if (st.base.fork) {
            for (st.base.cmd) |arg| try argv.append(a, (try a.dupeSentinel(u8, arg, 0)).ptr);
        } else try argv.appendSlice(a, &.{ d.exe.ptr, "_base" });
        try argv.append(a, base_path.ptr);
        try argv.append(a, null);

        // Its own settings first, so they win over the driver's of the same name.
        var envp: std.ArrayList(?[*:0]const u8) = .empty;
        var names: std.StringHashMapUnmanaged(void) = .empty;
        const ours = [_][:0]const u8{
            try std.fmt.allocPrintSentinel(a, "CPUQ_CORES={d}", .{st.base.job.cores}, 0),
            try std.fmt.allocPrintSentinel(a, "CPUQ_JOB={s}", .{st.job}, 0),
        };
        for (ours) |e| try addEnv(a, &envp, &names, e);
        for (st.base.env) |e| try addEnv(a, &envp, &names, try a.dupeSentinel(u8, e, 0));
        for (d.env) |e| if (!std.mem.startsWith(u8, e, "CPUQ_SLOT=")) try addEnv(a, &envp, &names, e);
        try envp.append(a, null);

        const dir = if (st.base.dir.len != 0) try a.dupeSentinel(u8, st.base.dir, 0) else try a.dupeSentinel(u8, st.dir, 0);
        // Log onto 1 and 2 before the socket onto 3, which may be the log's own number.
        const pid = try sys.spawn(d.exe, @ptrCast(argv.items.ptr), @ptrCast(envp.items.ptr), .utility, .{
            .dups = &.{ .{ log, 1 }, .{ log, 2 }, .{ sv[1], 3 }, .{ d.link, d.link } },
            .dir = dir.ptr,
        });
        st.proc = .{ .pid = pid, .sock = sv[0] };
    }

    // --- Answers and ends --------------------------------------------------------------------

    fn readBase(d: *Driver, st: *Stamp) void {
        const p = &st.proc.?;
        var buf: [16384]u8 = undefined;
        while (true) {
            const n = c.read(p.sock, &buf, buf.len);
            if (n < 0) switch (c.errno(n)) {
                .INTR => continue,
                .AGAIN => break,
                else => return d.lostSocket(st),
            };
            if (n == 0) return d.lostSocket(st);
            p.in.appendSlice(d.gpa, buf[0..@intCast(n)]) catch oom();
        }
        var from: usize = 0;
        while (std.mem.findScalarPos(u8, p.in.items, from, '\n')) |end| {
            d.answer(st, p.in.items[from..end]);
            from = end + 1;
        }
        const rest = p.in.items.len - from;
        std.mem.copyForwards(u8, p.in.items[0..rest], p.in.items[from..]);
        p.in.shrinkRetainingCapacity(rest);
    }

    /// The base's end of fd 3 closed: it is ending; its reap says how.
    fn lostSocket(_: *Driver, st: *Stamp) void {
        const p = &st.proc.?;
        if (p.sock >= 0) _ = c.close(p.sock);
        p.sock = -1;
    }

    /// `STATUS [CPU_MS PEAK] PATH`; STATUS `-`: the base couldn't take the file's lock, so it ran
    /// nothing, and the sweep sees to the file.
    fn answer(d: *Driver, st: *Stamp, line: []const u8) void {
        const at = std.mem.find(u8, line, " /") orelse return;
        const path = line[at + 1 ..];
        var f = std.mem.tokenizeScalar(u8, line[0..at], ' ');
        const status_text = f.next() orelse return;
        const cpu_ms = std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0;
        const peak = std.fmt.parseInt(u64, f.next() orelse "0", 10) catch 0;
        const kv = st.live.fetchSwapRemove(path) orelse return;
        const l = kv.value;
        defer d.gpa.free(l.path);
        if (std.mem.eql(u8, status_text, "-")) {
            d.pool.dropped(st.key, l.slot);
            return;
        }
        const status: u8 = @intCast(@min(std.fmt.parseInt(u32, status_text, 10) catch 125, 255));
        const wall: u64 = @intCast(@max(sys.monoMs() - l.due, 0));
        jobs.endRecord(l.path, status, wall, cpu_ms, peak);
        const to = d.print("{s}/{s}/{s}", .{ st.dir, if (status == 0) "done" else "died", std.fs.path.basename(l.path) });
        defer d.gpa.free(to);
        _ = c.rename(l.path, to);
        d.pool.ended(st.key, l.slot, .{ .ok = status == 0, .cpu_ms = cpu_ms, .wall_ms = wall, .peak = peak });
    }

    fn reap(d: *Driver) void {
        while (sys.reapAny()) |r| {
            const pid, const w = r;
            if (d.closing.remove(pid)) continue;
            for (d.stamps.values()) |st| if (st.proc) |p| if (p.pid == pid) {
                d.baseDied(st, w);
                break;
            };
        }
    }

    /// Its tasks are let go: their files stay in live/ until the sweep finds them unlocked.
    fn baseDied(d: *Driver, st: *Stamp, w: sys.Waited) void {
        var p = st.proc.?;
        if (p.sock >= 0) _ = c.close(p.sock);
        p.out.deinit(d.gpa);
        p.in.deinit(d.gpa);
        st.proc = null;
        const n = st.live.count();
        for (st.live.values()) |l| d.gpa.free(l.path);
        st.live.clearRetainingCapacity();
        var how_buf: [32]u8 = undefined;
        const how = switch (w.exit) {
            .code => |code| std.fmt.bufPrint(&how_buf, "status {d}", .{code}) catch "",
            .signal => |sig| std.fmt.bufPrint(&how_buf, "signal {d}", .{@backingInt(sig)}) catch "",
        };
        std.debug.print("cpuq driver: {s}: its base ended ({s}) with {d} task{s} out; see {s}/log\n", .{ st.key, how, n, if (n == 1) "" else "s", st.dir });
        if (!d.pool.baseDied(st.key)) {
            const why = std.fmt.allocPrint(d.gpa, "its base ended twice with no task finished between ({s}); see {s}/log", .{ how, st.dir }) catch oom();
            defer d.gpa.free(why);
            d.stopJob(st, why);
        }
    }

    fn stopJob(d: *Driver, st: *Stamp, why: []const u8) void {
        const path = d.print("{s}/{s}/stop", .{ d.root, st.job });
        defer d.gpa.free(path);
        Io.Dir.cwd().writeFile(d.io, .{ .sub_path = path, .data = why }) catch {};
        std.debug.print("cpuq driver: {s}: stopped: {s}\n", .{ st.job, why });
    }

    fn closeBase(d: *Driver, st: *Stamp) void {
        var p = st.proc orelse return;
        if (p.sock >= 0) _ = c.close(p.sock);
        p.out.deinit(d.gpa);
        p.in.deinit(d.gpa);
        d.closing.put(d.gpa, p.pid, {}) catch oom();
        st.proc = null;
    }

    // --- The second --------------------------------------------------------------------------

    fn sample(d: *Driver) void {
        const r = sys.runnable(d.io) orelse return;
        d.sum += if (is_linux) @max(r - 1, 0) else r; // Linux counts the reader
        d.samples += 1;
    }

    fn tick(d: *Driver, scratch: Allocator) void {
        d.scan(scratch);
        const r = if (d.samples > 0) d.sum / @as(f64, @floatFromInt(d.samples)) else 0;
        d.sum = 0;
        d.samples = 0;
        const target = d.load orelse @as(f64, @floatFromInt(sys.activeCpus(d.io)));
        d.pool.tick(sys.monoMs(), .{ .target = target, .runnable = r, .free = sys.memAvailable(d.io) orelse std.math.maxInt(u64) });
        // A base with nothing to do is closed; the next task starts another.
        for (d.stamps.values()) |st| if (st.proc != null and st.live.count() == 0 and d.pool.left(st.key) == 0) d.closeBase(st);
        d.ticked = true;
    }

    fn idle(d: *Driver) bool {
        if (!d.ticked or d.closing.count() > 0) return false;
        for (d.stamps.values()) |st| if (st.proc != null or st.live.count() > 0 or d.pool.left(st.key) > 0) return false;
        return true;
    }
};

fn addEnv(a: Allocator, envp: *std.ArrayList(?[*:0]const u8), names: *std.StringHashMapUnmanaged(void), e: [:0]const u8) !void {
    const name = e[0 .. std.mem.findScalar(u8, e, '=') orelse e.len];
    if ((try names.getOrPut(a, name)).found_existing) return;
    try envp.append(a, e.ptr);
}

fn flush(p: *Proc) void {
    while (p.out.items.len > 0 and p.sock >= 0) {
        const n = if (is_linux) c.send(p.sock, p.out.items.ptr, p.out.items.len, c.MSG.NOSIGNAL) else c.write(p.sock, p.out.items.ptr, p.out.items.len);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return; // full (poll says when), or the base is gone (its reap says so)
        }
        const done: usize = @intCast(n);
        std.mem.copyForwards(u8, p.out.items[0 .. p.out.items.len - done], p.out.items[done..]);
        p.out.shrinkRetainingCapacity(p.out.items.len - done);
    }
}

fn children(io: Io, a: Allocator, path: []const u8, kind: Io.File.Kind) []const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| if (e.kind == kind) out.append(a, a.dupe(u8, e.name) catch continue) catch {};
    return out.items;
}

fn exists(io: Io, a: Allocator, dir: []const u8, name: []const u8) bool {
    const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name }) catch return false;
    _ = Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn hasFiles(io: Io, a: Allocator, root: []const u8, key: []const u8, sub: []const u8) bool {
    const path = std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ root, key, sub }) catch return false;
    var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return false;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |e| if (jobs.visible(e.name)) return true;
    return false;
}

fn oom() noreturn {
    fail("out of memory", .{});
}

var wake: [2]c.fd_t = .{ -1, -1 };

fn onChild(_: c.SIG) callconv(.c) void {
    const saved = std.c._errno().*;
    defer std.c._errno().* = saved;
    _ = c.write(wake[1], "x", 1);
}

pub fn cmdDriver(ctx: *Ctx, args: []const [:0]const u8) u8 {
    const io = ctx.io;
    var load: ?f64 = null;
    var until_done = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const x = args[i];
        if (std.mem.eql(u8, x, "--install")) return @import("records.zig").installService(ctx, .driver, true);
        if (std.mem.eql(u8, x, "--uninstall")) return @import("records.zig").installService(ctx, .driver, false);
        if (std.mem.eql(u8, x, "--until-done")) {
            until_done = true;
        } else if (std.mem.eql(u8, x, "--load") and i + 1 < args.len) {
            i += 1;
            const l = std.fmt.parseFloat(f64, args[i]) catch return usageError("--load needs a number of cores, not '{s}'", .{args[i]});
            if (!(l > 0 and l <= 4096)) return usageError("--load must be above 0 and at most 4096", .{});
            load = l;
        } else return usageError("unknown option '{s}'", .{x});
    }
    const gpa = std.heap.c_allocator;
    const root = jobs.root(ctx.arena, ctx.env) orelse fail("no HOME, so no jobs folder", .{});
    Io.Dir.cwd().createDirPath(io, root) catch |err| fail("{s}: {t}", .{ root, err });
    const lock_path = std.fmt.allocPrint(ctx.arena, "{s}/.driver.lock", .{root}) catch oom();
    _ = Io.Dir.cwd().createFile(io, lock_path, .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false }) catch |err| switch (err) {
        error.WouldBlock => fail("a driver already runs {s}", .{root}),
        else => fail("{s}: {t}", .{ lock_path, err }),
    };
    // 0, 1 and 2 open, so nothing made below takes their numbers.
    for (0..3) |fd| if (c.fcntl(@intCast(fd), c.F.GETFD) < 0) {
        _ = c.open("/dev/null", .{ .ACCMODE = .RDWR });
    };

    var link: [2]c.fd_t = undefined;
    if (c.pipe(&link) != 0 or c.pipe(&wake) != 0) fail("no pipes", .{});
    // The read end high, so it is never the 1, 2 or 3 a base is given; every cap inherits it.
    const link_r = c.fcntl(link[0], c.F.DUPFD, @as(c_int, 10));
    _ = c.close(link[0]);
    _ = c.fcntl(link[1], c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    for (wake) |fd| {
        _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
        _ = c.fcntl(fd, c.F.SETFL, c.fcntl(fd, c.F.GETFL, @as(c_int, 0)) | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
    }
    var sa: c.Sigaction = .{ .handler = .{ .handler = onChild }, .mask = undefined, .flags = c.SA.RESTART | c.SA.NOCLDSTOP };
    _ = c.sigemptyset(&sa.mask);
    _ = c.sigaction(.CHLD, &sa, null);

    var env: std.ArrayList([:0]const u8) = .empty;
    var e: usize = 0;
    while (c.environ[e]) |entry| : (e += 1) env.append(ctx.arena, std.mem.span(entry)) catch oom();
    var host_buf: [256]u8 = undefined;
    const host = if (c.gethostname(&host_buf, host_buf.len) == 0) std.mem.sliceTo(std.mem.sliceTo(&host_buf, 0), '.') else "here";
    const exe = std.process.executablePathAlloc(io, ctx.arena) catch |err| fail("cannot find this cpuq: {t}", .{err});

    var d: Driver = .{
        .gpa = gpa,
        .io = io,
        .root = root,
        .host = host,
        .exe = ctx.arena.dupeSentinel(u8, exe, 0) catch oom(),
        .env = env.items,
        .load = load,
        .pool = .init(gpa),
        .link = link_r,
        .prng = .init(@bitCast(sys.monoMs())),
    };
    var scratch: std.heap.ArenaAllocator = .init(gpa);
    const period: i64 = if (is_linux) 50 else 100;
    var next_sample = sys.monoMs();
    var next_tick = next_sample;
    var fds: std.ArrayList(c.pollfd) = .empty;
    var owners: std.ArrayList(*Stamp) = .empty;
    while (true) {
        var now = sys.monoMs();
        if (now >= next_sample) {
            d.sample();
            next_sample = now + period;
        }
        if (now >= next_tick) {
            _ = scratch.reset(.retain_capacity);
            d.tick(scratch.allocator());
            d.schedule();
            next_tick = now + 1000;
            if (until_done and d.idle()) return 0;
        }
        now = sys.monoMs();
        const due = d.sendDue(now);
        const wait = @max(0, @min(@min(next_sample, next_tick), due) - now);

        fds.clearRetainingCapacity();
        owners.clearRetainingCapacity();
        fds.append(gpa, .{ .fd = wake[0], .events = c.POLL.IN, .revents = 0 }) catch oom();
        for (d.stamps.values()) |st| if (st.proc) |p| if (p.sock >= 0) {
            const out: i16 = if (p.out.items.len > 0) c.POLL.OUT else 0;
            fds.append(gpa, .{ .fd = p.sock, .events = c.POLL.IN | out, .revents = 0 }) catch oom();
            owners.append(gpa, st) catch oom();
        };
        _ = c.poll(fds.items.ptr, @intCast(fds.items.len), @intCast(wait));
        var ended = false;
        for (fds.items[1..], owners.items) |pfd, st| {
            if (pfd.revents == 0 or st.proc == null) continue;
            if (pfd.revents & c.POLL.OUT != 0) flush(&st.proc.?);
            if (pfd.revents & (c.POLL.IN | c.POLL.HUP | c.POLL.ERR) != 0) {
                d.readBase(st);
                ended = true;
            }
        }
        if (fds.items[0].revents != 0) {
            var junk: [64]u8 = undefined;
            while (c.read(wake[0], &junk, junk.len) > 0) {}
            d.reap();
        }
        if (ended) d.schedule();
    }
}
