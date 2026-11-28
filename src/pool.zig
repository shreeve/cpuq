//! The pool: how many of cpuq's tasks run on this machine, and the line that decides which run
//! starts its next task. cpuq bounds how many tasks run; it never decides which CPU a task runs
//! on. The kernel shares CPU time among the running tasks (on Linux by each project's weight), and
//! a task that waits (on a disk, a socket, a child, a sleep) uses nothing while others take the
//! time. Everything lives under a versioned folder in the state directory, so a cpuq of another
//! version never reads these files as its own:
//!
//!   v3/lock          the pool's lock: every scan, start and record write happens under it
//!   v3/seq           the last ticket number handed out
//!   v3/ops/C-TICKET  one per live run, exclusively locked by its cpuq for its whole life (C: 0
//!                    urgent, 1 normal). Its text says what it runs, what it could start, and its
//!                    tasks (pid and start time), so whoever finds it dead ends its leftovers
//!   v3/wake/TICKET   the run's FIFO: whoever frees room for it writes a byte there
//!   v3/limits/PID    `cpuq limit`'s request: the run's new -c
//!   v3/sample        the last measure of the machine: its busy CPUs (kernel ticks) and each
//!                    task's (its process tree's CPU time), renewed at most once a second by
//!                    whichever cpuq finds it old (v3/sample.lock keeps it to one at a time)
//!
//! A file whose lock can be taken has no live holder: whoever finds it so ends what it left
//! running and removes it, under the pool's lock.
//!
//! The rules, as pure functions over the records (`mayStart`, `drainMayStart`, `pausePlan`):
//!   - Capacity T: the pool's CPUs less those drains isolate.
//!   - A project's fair share: T × its weight ÷ the weights of the projects running or waiting.
//!   - Within a project, its first waiter goes first: an urgent run's first task, then the run
//!     running the fewest tasks, then the run whose last task started longest ago (one that has
//!     started none first, by ticket).
//!   - A project under its share starts its next task at once, however busy the machine.
//!   - Over its share, a run starts a task only while the machine has room (busy + starting <
//!     T − 0.5), and only the first such waiter in the line (the project running the fewest for
//!     its weight, then as within a project) takes it.
//!   - Hard limits: a run's -c, the memory, disk and pressure gates, and 4T tasks running.
const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");

/// Tasks started (or continued) this recently count as one busy CPU each: the sample can't have
/// seen them yet.
pub const fresh_ms: i64 = 2000;
/// Room the machine keeps: a waiter over its share starts only while busy + starting < T − this.
pub const headroom: f64 = 0.5;
/// Running tasks machine-wide are kept to this many times T: a backstop for when every task
/// that waited wakes at once.
pub const backstop: u32 = 4;
/// A drain isolates CPUs at most this long past its own time limit: a drain's cpuq that is stuck
/// or gone stops counting then, whatever its record says.
pub const drain_grace_s: i64 = 60;

pub const Pool = struct {
    io: Io,
    path: []const u8,
    dir: Io.Dir,
    ops: Io.Dir,
    wake: Io.Dir,
    /// `cpuq limit`'s requests: a file named by the run's pid, holding its new -c.
    limits: Io.Dir,
    lock_file: Io.File,

    /// Opens (making it if need be) the pool under `state_dir`.
    pub fn open(io: Io, a: std.mem.Allocator, state_dir: []const u8) !Pool {
        const path = try std.fmt.allocPrint(a, "{s}/v3", .{state_dir});
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, path);
        const dir = try cwd.openDir(io, path, .{ .iterate = true });
        return .{
            .io = io,
            .path = path,
            .dir = dir,
            .ops = try subdir(io, dir, "ops"),
            .wake = try subdir(io, dir, "wake"),
            .limits = try subdir(io, dir, "limits"),
            .lock_file = try createShared(io, dir, "lock"),
        };
    }

    fn subdir(io: Io, dir: Io.Dir, name: []const u8) !Io.Dir {
        try dir.createDirPath(io, name);
        return dir.openDir(io, name, .{ .iterate = true });
    }

    /// Creates or opens a file other processes may be creating at the same moment. macOS can
    /// fail such a racing open(O_CREAT) with ENOENT although the directory exists; a retry works.
    pub fn createShared(io: Io, dir: Io.Dir, name: []const u8) !Io.File {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            return dir.createFile(io, name, .{ .read = true, .truncate = false }) catch |err| switch (err) {
                error.FileNotFound => if (tries < 100) {
                    io.sleep(.fromMilliseconds(1), .awake) catch {};
                    continue;
                } else err,
                else => err,
            };
        }
    }

    pub fn lock(p: *Pool) void {
        p.lock_file.lock(p.io, .exclusive) catch |err| std.debug.panic("cpuq: the pool's lock: {t}", .{err});
        p.noteHolder();
    }

    /// Takes the lock if it comes within `ms` milliseconds. Every step under the lock is
    /// short, so a lock held longer means its holder is stuck: see `holder`.
    pub fn lockWithin(p: *Pool, ms: i64) bool {
        const end = sys.monoMs() + ms;
        while (true) {
            if (p.lock_file.tryLock(p.io, .exclusive) catch false) {
                p.noteHolder();
                return true;
            }
            if (sys.monoMs() >= end) return false;
            p.io.sleep(.fromMilliseconds(20), .awake) catch {};
        }
    }

    /// Who took the lock last, and when: the lock file's one line, `PID MS` (milliseconds of
    /// the real clock), written by each holder as it takes the lock.
    pub const Holder = struct { pid: i32, since_ms: i64 };

    fn noteHolder(p: *Pool) void {
        var buf: [40]u8 = undefined;
        const ms = Io.Clock.real.now(p.io).toMilliseconds();
        const line = std.fmt.bufPrint(&buf, "{d:>12} {d:>16}\n", .{ std.c.getpid(), ms }) catch return;
        _ = std.c.pwrite(p.lock_file.handle, line.ptr, line.len, 0);
    }

    /// The lock's holder as its note says; null when there is no note.
    pub fn holder(p: *Pool) ?Holder {
        var buf: [40]u8 = undefined;
        const n = std.c.pread(p.lock_file.handle, &buf, buf.len, 0);
        if (n <= 0) return null;
        var it = std.mem.tokenizeAny(u8, buf[0..@intCast(n)], " \n");
        const pid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
        const ms = std.fmt.parseInt(i64, it.next() orelse return null, 10) catch return null;
        return .{ .pid = pid, .since_ms = ms };
    }

    pub fn unlock(p: *Pool) void {
        p.lock_file.unlock(p.io);
    }

    /// The next ticket number, above `seq` and every run's ticket, so a lost `seq` never hands
    /// out a live number. Under the lock.
    pub fn nextTicket(p: *Pool) !u64 {
        var buf: [32]u8 = undefined;
        var last: u64 = blk: {
            const text = p.dir.readFile(p.io, "seq", &buf) catch break :blk 0;
            break :blk std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0;
        };
        var it = p.ops.iterate();
        while (try it.next(p.io)) |e| last = @max(last, ticketOf(e.name) orelse continue);
        var out: [32]u8 = undefined;
        try p.dir.writeFile(p.io, .{ .sub_path = "seq.new", .data = try std.fmt.bufPrint(&out, "{d}\n", .{last + 1}) });
        try p.dir.rename("seq.new", p.dir, "seq", p.io);
        return last + 1;
    }

    /// Enters a run: its file, written and locked under a temporary name and renamed into place
    /// (so no scan sees it unlocked), and its FIFO. Under the lock. The returned file stays
    /// locked for the run's life; its ticket is set in `r`.
    pub fn enter(p: *Pool, r: *Op) !Io.File {
        r.ticket = try p.nextTicket();
        var tmp_buf: [48]u8 = undefined;
        const tmp = try std.fmt.bufPrint(&tmp_buf, ".new-{d}", .{r.ticket});
        const f = try p.ops.createFile(p.io, tmp, .{ .lock = .exclusive, .truncate = true });
        errdefer f.close(p.io);
        try p.write(f, r.*);
        var name_buf: [48]u8 = undefined;
        try p.ops.rename(tmp, p.ops, opName(&name_buf, r.*), p.io);
        var fifo_buf: [1024]u8 = undefined;
        const fifo = try std.fmt.bufPrintSentinel(&fifo_buf, "{s}/wake/{d}", .{ p.path, r.ticket }, 0);
        _ = std.c.unlink(fifo);
        if (mkfifo(fifo, 0o600) != 0) return error.FifoFailed;
        return f;
    }

    /// Opens the run's FIFO to read, without blocking: it is open before the run first looks
    /// for room, so a wake sent after that look always finds it open.
    pub fn openWake(p: *Pool, ticket: u64) !std.c.fd_t {
        var buf: [1024]u8 = undefined;
        const fifo = try std.fmt.bufPrintSentinel(&buf, "{s}/wake/{d}", .{ p.path, ticket }, 0);
        // Read and write, so the FIFO never reads as closed (EOF) while no writer has it.
        const fd = std.c.open(fifo, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) return error.FifoFailed;
        return fd;
    }

    /// Asks the run whose cpuq is `pid` to run at most `n` tasks at once from now on (`cpuq
    /// limit`): a file named by its pid, written whole by a rename.
    pub fn askLimit(p: *Pool, pid: i32, n: u32) !void {
        var name_buf: [24]u8 = undefined;
        var tmp_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "{d}", .{pid});
        const tmp = try std.fmt.bufPrint(&tmp_buf, ".{d}.tmp", .{pid});
        var text_buf: [16]u8 = undefined;
        try p.limits.writeFile(p.io, .{ .sub_path = tmp, .data = try std.fmt.bufPrint(&text_buf, "{d}\n", .{n}) });
        try p.limits.rename(tmp, p.limits, name, p.io);
    }

    /// The new limit asked for the run whose cpuq is `pid`, if any: read once and removed.
    pub fn takeLimit(p: *Pool, pid: i32) ?u32 {
        var name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}", .{pid}) catch return null;
        var buf: [32]u8 = undefined;
        const text = p.limits.readFile(p.io, name, &buf) catch return null;
        p.limits.deleteFile(p.io, name) catch {};
        return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch null;
    }

    /// Wakes a run: one byte to its FIFO, never blocking. A full FIFO already holds a wake.
    pub fn wakeOp(p: *Pool, ticket: u64) void {
        var buf: [1024]u8 = undefined;
        const fifo = std.fmt.bufPrintSentinel(&buf, "{s}/wake/{d}", .{ p.path, ticket }, 0) catch return;
        const fd = std.c.open(fifo, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, "w", 1);
    }

    /// Rewrites a run's record in place. Readers read only under the lock, as the writer
    /// writes, so none sees it half written.
    pub fn write(p: *Pool, f: Io.File, r: Op) !void {
        var buf: [32 << 10]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        r.format(&w) catch return error.RecordTooLong;
        const text = w.buffered();
        if (std.c.pwrite(f.handle, text.ptr, text.len, 0) != @as(isize, @intCast(text.len))) return error.WriteFailed;
        try f.setLength(p.io, text.len);
    }

    /// Leaves the pool: removes the run's file and FIFO, then closes the file (its lock goes
    /// with it). Under the lock.
    pub fn leave(p: *Pool, f: Io.File, r: Op) void {
        var name_buf: [48]u8 = undefined;
        p.ops.deleteFile(p.io, opName(&name_buf, r)) catch {};
        var fifo_buf: [32]u8 = undefined;
        p.wake.deleteFile(p.io, std.fmt.bufPrint(&fifo_buf, "{d}", .{r.ticket}) catch "") catch {};
        f.close(p.io);
    }

    /// Every live run, in ticket order. A dead one's leftover tasks are ended and its files
    /// removed. Under the lock.
    pub fn scan(p: *Pool, a: std.mem.Allocator) []Op {
        var list: std.ArrayList(Op) = .empty;
        var it = p.ops.iterate();
        while (it.next(p.io) catch null) |e| {
            if (e.name[0] == '.') continue;
            const ticket = ticketOf(e.name) orelse continue;
            const f = p.ops.openFile(p.io, e.name, .{}) catch continue;
            defer f.close(p.io);
            var rd = f.reader(p.io, &.{});
            if (f.tryLock(p.io, .shared) catch false) {
                // Nobody holds it: its run has ended, however it ended. What it left running
                // (macOS has no parent-death signal) is ended before anyone counts the room.
                const text = rd.interface.allocRemaining(a, .limited(64 << 10)) catch "";
                killLeftovers(Op.parse(a, text));
                p.ops.deleteFile(p.io, e.name) catch {};
                var fifo_buf: [32]u8 = undefined;
                p.wake.deleteFile(p.io, std.fmt.bufPrint(&fifo_buf, "{d}", .{ticket}) catch "") catch {};
                f.unlock(p.io);
                continue;
            }
            const text = rd.interface.allocRemaining(a, .limited(64 << 10)) catch continue;
            var op = Op.parse(a, text);
            op.ticket = ticket;
            list.append(a, op) catch break;
        }
        std.mem.sort(Op, list.items, {}, struct {
            fn less(_: void, x: Op, y: Op) bool {
                return x.ticket < y.ticket;
            }
        }.less);
        return list.items;
    }

    /// The last sample of the machine, or null when there is none.
    pub fn readSample(p: *Pool, a: std.mem.Allocator) ?Sample {
        const text = p.dir.readFileAlloc(p.io, "sample", a, .limited(4 << 20)) catch return null;
        return Sample.parse(a, text);
    }

    /// Renews the sample when it is at least a second old: the machine's busy CPUs from the
    /// kernel's ticks, and each running task's busy CPUs from its process tree's CPU time. One
    /// cpuq at a time does it (`sample.lock`, never waited for), outside the pool's lock: a
    /// process listing takes milliseconds. `ops` names the tasks; `ncpu` is the machine's CPUs.
    pub fn renewSample(p: *Pool, a: std.mem.Allocator, ops: []const Op, ncpu: u32) void {
        const now = sys.monoMs();
        const prev = p.readSample(a);
        if (prev) |s| if (now - s.ms < 1000 and now >= s.ms) return;
        const lf = createShared(p.io, p.dir, "sample.lock") catch return;
        defer lf.close(p.io);
        if (!(lf.tryLock(p.io, .exclusive) catch false)) return;
        defer lf.unlock(p.io);
        // Someone may have renewed it while this one took the lock.
        const last = p.readSample(a);
        if (last) |s| if (now - s.ms < 1000 and now >= s.ms) return;
        var has_tasks = false;
        for (ops) |o| if (o.tasks_now.len != 0) {
            has_tasks = true;
        };
        const procs: []const sys.Proc = if (has_tasks) sys.processes(p.io, a) else &.{};
        var per: std.ArrayList(TaskBusy) = .empty;
        var total: f64 = 0;
        var drains: f64 = 0;
        for (ops) |o| for (o.tasks_now) |t| {
            const cum = sys.treeCpu(procs, t.pid);
            var busy: f64 = 0;
            const before: ?TaskBusy = if (last) |s| s.find(t.pid, t.start) else null;
            if (before) |b| {
                const ms = @max(now - last.?.ms, 1);
                busy = @as(f64, @floatFromInt(cum -| b.cum)) / 1e6 / @as(f64, @floatFromInt(ms));
            } else if (t.fresh != 0) {
                busy = @as(f64, @floatFromInt(cum)) / 1e6 / @as(f64, @floatFromInt(@max(now - t.fresh, 1)));
            }
            if (t.paused) busy = 0;
            total += busy;
            if (o.drain) drains += busy;
            per.append(a, .{ .pid = t.pid, .start = t.start, .cum = cum, .busy = busy }) catch break;
        };
        const ticks = sys.cpuTicks(p.io);
        var machine: ?f64 = null;
        if (ticks) |t| if (last) |s| if (s.ticks_total != 0 and t.total > s.ticks_total and t.busy >= s.ticks_busy) {
            machine = @as(f64, @floatFromInt(t.busy - s.ticks_busy)) / @as(f64, @floatFromInt(t.total - s.ticks_total)) * @as(f64, @floatFromInt(ncpu));
        };
        // Linux: each CPU's busy share too, so busy can leave out the CPUs drains isolate.
        var cpus: std.ArrayList(CpuBusy) = .empty;
        if (sys.numberedTicks(p.io, a)) |nt| for (nt) |t| {
            var frac: f64 = 0;
            if (last) |s| for (s.cpus) |q| if (q.cpu == t.cpu and t.total > q.total) {
                frac = @as(f64, @floatFromInt(t.busy -| q.busy)) / @as(f64, @floatFromInt(t.total - q.total));
            };
            cpus.append(a, .{ .cpu = t.cpu, .busy = t.busy, .total = t.total, .frac = frac }) catch break;
        };
        const s: Sample = .{
            .ms = now,
            .ticks_busy = if (ticks) |t| t.busy else 0,
            .ticks_total = if (ticks) |t| t.total else 0,
            .machine = machine,
            .tasks = total,
            .drains = drains,
            .per = per.items,
            .cpus = cpus.items,
        };
        var out: std.ArrayList(u8) = .empty;
        s.format(a, &out) catch return;
        p.dir.writeFile(p.io, .{ .sub_path = "sample.new", .data = out.items }) catch return;
        p.dir.rename("sample.new", p.dir, "sample", p.io) catch {};
    }
};

/// Ends what a dead run left running: each task whose process still has the start time noted
/// gets SIGKILL (its whole group, unless it shared its cpuq's group: a single run's task), and is
/// waited for, at most 200 ms each.
fn killLeftovers(o: Op) void {
    for (o.tasks_now) |t| {
        if (t.pid <= 1 or t.start == 0) continue;
        if (sys.procStart(t.pid) != t.start) continue;
        _ = std.c.kill(if (o.single) t.pid else -t.pid, .KILL);
        var waited: u32 = 0;
        while (waited < 100 and sys.procStart(t.pid) == t.start) : (waited += 1) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
    }
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

/// A task running now: its number, its try, its pid and that process's start time (so a reused
/// pid is never taken for it), when it started (Unix seconds), when it last started or continued
/// (monotonic ms: fresh for `fresh_ms`), and whether cpuq has it stopped (macOS sharing, or a
/// drain of the whole machine).
pub const TaskNow = struct {
    task: u32 = 0,
    attempt: u32 = 1,
    pid: i32 = 0,
    start: u64 = 0,
    since: i64 = 0,
    fresh: i64 = 0,
    paused: bool = false,
};

/// One task's measure in the sample: its process tree's CPU time so far (ns) and its busy CPUs
/// over the last interval.
pub const TaskBusy = struct { pid: i32, start: u64, cum: u64, busy: f64 };

/// The machine as last measured (`v3/sample`).
pub const Sample = struct {
    /// When (monotonic ms).
    ms: i64 = 0,
    /// The kernel's CPU ticks then, busy and total.
    ticks_busy: u64 = 0,
    ticks_total: u64 = 0,
    /// The machine's busy CPUs over the interval before it; null for a first sample.
    machine: ?f64 = null,
    /// cpuq's tasks' busy CPUs over that interval, all of them, and those of drains' commands.
    tasks: f64 = 0,
    drains: f64 = 0,
    per: []const TaskBusy = &.{},
    /// Linux: each online CPU's ticks then, and its busy share over the interval.
    cpus: []const CpuBusy = &.{},

    pub fn find(s: Sample, pid: i32, start: u64) ?TaskBusy {
        for (s.per) |t| if (t.pid == pid and t.start == start) return t;
        return null;
    }

    fn format(s: Sample, a: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        try out.print(a, "{d} {d} {d} ", .{ s.ms, s.ticks_busy, s.ticks_total });
        if (s.machine) |m| try out.print(a, "{d:.3}", .{m}) else try out.append(a, '-');
        try out.print(a, " {d:.3} {d:.3}\n", .{ s.tasks, s.drains });
        for (s.per) |t| try out.print(a, "{d} {d} {d} {d:.3}\n", .{ t.pid, t.start, t.cum, t.busy });
        for (s.cpus) |c| try out.print(a, "c {d} {d} {d} {d:.3}\n", .{ c.cpu, c.busy, c.total, c.frac });
    }

    fn parse(a: std.mem.Allocator, text: []const u8) ?Sample {
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        var f = std.mem.tokenizeScalar(u8, lines.next() orelse return null, ' ');
        var s: Sample = .{};
        s.ms = std.fmt.parseInt(i64, f.next() orelse return null, 10) catch return null;
        s.ticks_busy = std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null;
        s.ticks_total = std.fmt.parseInt(u64, f.next() orelse return null, 10) catch return null;
        const m = f.next() orelse return null;
        s.machine = std.fmt.parseFloat(f64, m) catch null;
        s.tasks = std.fmt.parseFloat(f64, f.next() orelse "0") catch 0;
        s.drains = std.fmt.parseFloat(f64, f.next() orelse "0") catch 0;
        var per: std.ArrayList(TaskBusy) = .empty;
        var cpus: std.ArrayList(CpuBusy) = .empty;
        while (lines.next()) |line| {
            var g = std.mem.tokenizeScalar(u8, line, ' ');
            if (std.mem.startsWith(u8, line, "c ")) {
                _ = g.next();
                cpus.append(a, .{
                    .cpu = std.fmt.parseInt(u32, g.next() orelse continue, 10) catch continue,
                    .busy = std.fmt.parseInt(u64, g.next() orelse continue, 10) catch continue,
                    .total = std.fmt.parseInt(u64, g.next() orelse continue, 10) catch continue,
                    .frac = std.fmt.parseFloat(f64, g.next() orelse continue) catch continue,
                }) catch break;
                continue;
            }
            per.append(a, .{
                .pid = std.fmt.parseInt(i32, g.next() orelse continue, 10) catch continue,
                .start = std.fmt.parseInt(u64, g.next() orelse continue, 10) catch continue,
                .cum = std.fmt.parseInt(u64, g.next() orelse continue, 10) catch continue,
                .busy = std.fmt.parseFloat(f64, g.next() orelse continue) catch continue,
            }) catch break;
        }
        s.per = per.items;
        s.cpus = cpus.items;
        return s;
    }
};

/// One CPU in the sample (Linux): its ticks then, and its busy share over the interval.
pub const CpuBusy = struct { cpu: u32, busy: u64, total: u64, frac: f64 };

fn ticketOf(name: []const u8) ?u64 {
    const dash = std.mem.findScalar(u8, name, '-') orelse return null;
    return std.fmt.parseInt(u64, name[dash + 1 ..], 10) catch null;
}

fn opName(buf: []u8, r: Op) []const u8 {
    return std.fmt.bufPrint(buf, "{d}-{d}", .{ @intFromBool(!r.urgent), r.ticket }) catch "";
}

/// A run, as its file records it.
pub const Op = struct {
    ticket: u64 = 0,
    /// "Rebuild first": its first task goes ahead of the line.
    urgent: bool = false,
    /// It has started a task: urgent no more.
    served: bool = false,
    /// When it last started a task (monotonic ms); 0: never. Of runs running as many, the one
    /// that started longest ago goes first, so a run that ends a task and would start the next
    /// takes its turn behind the others.
    last: i64 = 0,
    /// `cpuq drain`: isolates `limit` CPUs (with their SMT siblings) for its command, once its
    /// turn comes.
    drain: bool = false,
    /// One task, sharing its cpuq's process group (`cpuq run -- CMD`).
    single: bool = false,
    /// Its cpuq is stopped (Ctrl-Z): its tasks are stopped, and it starts none.
    stopped: bool = false,
    pid: i32 = 0,
    project: []const u8 = "",
    label: []const u8 = "",
    weight: u32 = 1,
    /// The most tasks it runs at once (-c, worked out); a drain's CPUs.
    limit: u32 = 1,
    tasks: u32 = 1,
    done: u32 = 0,
    failed: u32 = 0,
    /// Its tasks running, those cpuq has stopped included.
    running: u32 = 0,
    /// Tasks it could start now (none while stopped, or at its -c); a drain waiting: 1.
    waiting: u32 = 0,
    /// A drain: the CPUs it isolates, once it has started.
    cpus: []const u32 = &.{},
    /// A drain: the CPUs its command runs on (CPUQ_CPUS), and how many of `cpus` are the pool's.
    pin: []const u32 = &.{},
    npool: u32 = 0,
    /// A drain: the busy CPUs work from outside it kept on its CPUs over the last second
    /// (Linux), and the busiest such process ("name (pid)"); 0 and empty when quiet.
    noise: f64 = 0,
    noisy_top: []const u8 = "",
    /// A drain: when its isolation began (monotonic ms); 0 while it waits for its turn.
    dstart: i64 = 0,
    since: i64 = 0,
    /// The longest a task of it may run, in seconds, with the time a kill takes; 0: no limit.
    tlimit: u32 = 0,
    /// Why it waits, for status ("memory pressure"); empty when it isn't held back.
    why: []const u8 = "",
    /// Its tasks running now.
    tasks_now: []const TaskNow = &.{},
    cmd: []const u8 = "",

    pub fn format(r: Op, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("pid={d}\nurgent={d}\nserved={d}\ndrain={d}\nsingle={d}\nstopped={d}\nproject={s}\nlabel={s}\nweight={d}\nlimit={d}\ntasks={d}\ndone={d}\nfailed={d}\nrunning={d}\nwaiting={d}\ncpus=", .{
            r.pid,     @intFromBool(r.urgent), @intFromBool(r.served), @intFromBool(r.drain), @intFromBool(r.single), @intFromBool(r.stopped),
            r.project, r.label,                r.weight,               r.limit,               r.tasks,                r.done,
            r.failed,  r.running,              r.waiting,
        });
        for (r.cpus, 0..) |cpu, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", cpu });
        try w.writeAll("\npin=");
        for (r.pin, 0..) |cpu, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", cpu });
        try w.print("\nnpool={d}\nnoise={d:.3}\nnoisy_top={s}\nlast={d}\ndstart={d}\nsince={d}\ntlimit={d}\nwhy={s}\nnow=", .{ r.npool, r.noise, r.noisy_top, r.last, r.dstart, r.since, r.tlimit, r.why });
        for (r.tasks_now, 0..) |t, i| try w.print("{s}{d}:{d}:{d}:{d}:{d}:{d}:{d}", .{ if (i == 0) "" else ",", t.task, t.attempt, t.pid, t.start, t.since, t.fresh, @intFromBool(t.paused) });
        try w.writeAll("\ncmd=");
        // The command is for people reading status: its first 1,000 bytes are plenty.
        for (r.cmd[0..@min(r.cmd.len, 1000)]) |ch| try w.writeByte(if (ch == '\n' or ch == '\t') ' ' else ch);
        try w.writeByte('\n');
    }

    pub fn parse(a: std.mem.Allocator, text: []const u8) Op {
        var r: Op = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const k, const v = std.mem.cutScalar(u8, line, '=') orelse continue;
            const n = std.fmt.parseInt(u32, v, 10) catch 0;
            if (eq(k, "pid")) r.pid = std.fmt.parseInt(i32, v, 10) catch 0;
            if (eq(k, "urgent")) r.urgent = eq(v, "1");
            if (eq(k, "served")) r.served = eq(v, "1");
            if (eq(k, "drain")) r.drain = eq(v, "1");
            if (eq(k, "single")) r.single = eq(v, "1");
            if (eq(k, "stopped")) r.stopped = eq(v, "1");
            if (eq(k, "project")) r.project = v;
            if (eq(k, "label")) r.label = v;
            if (eq(k, "weight")) r.weight = @max(1, n);
            if (eq(k, "limit")) r.limit = n;
            if (eq(k, "tasks")) r.tasks = n;
            if (eq(k, "done")) r.done = n;
            if (eq(k, "failed")) r.failed = n;
            if (eq(k, "running")) r.running = n;
            if (eq(k, "waiting")) r.waiting = n;
            if (eq(k, "cpus")) r.cpus = parseList(a, v);
            if (eq(k, "pin")) r.pin = parseList(a, v);
            if (eq(k, "npool")) r.npool = n;
            if (eq(k, "noise")) r.noise = std.fmt.parseFloat(f64, v) catch 0;
            if (eq(k, "noisy_top")) r.noisy_top = v;
            if (eq(k, "last")) r.last = std.fmt.parseInt(i64, v, 10) catch 0;
            if (eq(k, "dstart")) r.dstart = std.fmt.parseInt(i64, v, 10) catch 0;
            if (eq(k, "since")) r.since = std.fmt.parseInt(i64, v, 10) catch 0;
            if (eq(k, "tlimit")) r.tlimit = n;
            if (eq(k, "why")) r.why = v;
            if (eq(k, "now")) r.tasks_now = parseTasks(a, v);
            if (eq(k, "cmd")) r.cmd = v;
        }
        return r;
    }

    /// Its tasks cpuq has stopped (macOS sharing, a drain of the whole machine).
    pub fn paused(r: Op) u32 {
        var n: u32 = 0;
        for (r.tasks_now) |t| n += @intFromBool(t.paused);
        return n;
    }

    /// Whether it counts in the line: a run, not a drain, whose cpuq isn't stopped.
    pub fn counts(r: Op) bool {
        return !r.drain and !r.stopped;
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseTasks(a: std.mem.Allocator, v: []const u8) []const TaskNow {
    var out: std.ArrayList(TaskNow) = .empty;
    var it = std.mem.tokenizeScalar(u8, v, ',');
    while (it.next()) |item| {
        var f = std.mem.tokenizeScalar(u8, item, ':');
        out.append(a, .{
            .task = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue,
            .attempt = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue,
            .pid = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue,
            .start = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue,
            .since = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue,
            .fresh = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue,
            .paused = eq(f.next() orelse "0", "1"),
        }) catch break;
    }
    return out.items;
}

fn parseList(a: std.mem.Allocator, v: []const u8) []const u32 {
    var out: std.ArrayList(u32) = .empty;
    var it = std.mem.tokenizeScalar(u8, v, ',');
    while (it.next()) |s| out.append(a, std.fmt.parseInt(u32, s, 10) catch continue) catch break;
    return out.items;
}

// --- Drains: which CPUs are isolated, and whose turn it is ----------------------------------

/// Whether drain `o` isolates now: started, its cpuq not stopped, and within its time limit
/// plus `drain_grace_s` (a stuck or vanished drain's record never holds the machine longer).
pub fn isolating(o: Op, now_ms: i64) bool {
    if (!o.drain or o.stopped or o.dstart == 0) return false;
    if (o.tlimit == 0) return true;
    return now_ms - o.dstart <= (@as(i64, o.tlimit) + drain_grace_s) * 1000;
}

/// The CPUs drains isolate now (their commands' CPUs and those CPUs' SMT siblings), in no order.
pub fn isolated(a: std.mem.Allocator, ops: []const Op, now_ms: i64) []const u32 {
    var out: std.ArrayList(u32) = .empty;
    for (ops) |o| if (isolating(o, now_ms)) for (o.cpus) |c| {
        if (std.mem.findScalar(u32, out.items, c) == null) out.append(a, c) catch break;
    };
    return out.items;
}

/// The capacity the line shares: the pool's CPUs less those drains isolate (those of the pool).
pub fn capacity(ops: []const Op, pool_n: u32, now_ms: i64) u32 {
    var iso: u32 = 0;
    for (ops) |o| if (isolating(o, now_ms)) {
        iso += o.npool;
    };
    return pool_n -| iso;
}

/// The most of the pool's CPUs drains may isolate at once: half the pool, at least one.
pub fn drainRoom(pool_n: u32) u32 {
    return @max(1, pool_n / 2);
}

pub const DrainWait = enum {
    /// Its turn: it isolates now.
    go,
    /// A run that queued before it waits with no task running: a drain passes no such waiter.
    older_waiter,
    /// An older drain waits too: drains go in their order.
    older_drain,
    /// Its CPUs would take the drains' isolation past half the pool.
    half_pool,
    /// The CPUs it names, or enough whole cores for it, are another drain's.
    taken,
};

/// Whether drain `me` may begin isolating now, isolating `need` of the pool's CPUs (its own and
/// their siblings).
pub fn drainMayStart(ops: []const Op, me: u64, pool_n: u32, now_ms: i64, need: u32) DrainWait {
    var iso: u32 = 0;
    for (ops) |o| {
        if (o.ticket == me) continue;
        // 0.34's turn: a run that queued before it and waits holding nothing (no task running)
        // goes first; one already running tasks takes the rest of its turn beside the drain.
        if (o.ticket < me and o.counts() and o.waiting > 0 and o.running == 0) return .older_waiter;
        if (o.ticket < me and o.drain and !o.stopped and o.dstart == 0) return .older_drain;
        if (isolating(o, now_ms)) iso += o.npool;
    }
    if (iso + need > drainRoom(pool_n)) return .half_pool;
    return .go;
}

/// What a drain isolates: the CPUs its command runs on (`pin`), and those with their SMT
/// siblings (`cpus`), so no other work shares their cores.
pub const Pick = struct { pin: []const u32, cpus: []const u32 };

fn siblingsOf(topo: []const @import("cpus.zig").Core, cpu: u32) []const u32 {
    for (topo) |t| if (t.cpu == cpu) return t.siblings;
    return &.{};
}

/// The CPUs a drain isolates: `named` if it names them (null when any of them, or a sibling, is
/// another drain's), else `n` whole cores' worth from `order` (the pool's order from its end, or
/// fastest first), skipping any CPU whose core is partly `taken`. Null when there aren't enough.
pub fn pickDrain(a: std.mem.Allocator, order: []const u32, topo: []const @import("cpus.zig").Core, taken: []const u32, n: u32, named: []const u32) ?Pick {
    var pin: std.ArrayList(u32) = .empty;
    var all: std.ArrayList(u32) = .empty;
    const free = struct {
        fn core(tp: []const @import("cpus.zig").Core, busy: []const u32, used: []const u32, cpu: u32) bool {
            if (std.mem.findScalar(u32, busy, cpu) != null or std.mem.findScalar(u32, used, cpu) != null) return false;
            for (siblingsOf(tp, cpu)) |s| if (std.mem.findScalar(u32, busy, s) != null) return false;
            return true;
        }
    };
    const want = if (named.len != 0) named else order;
    for (want) |cpu| {
        if (named.len == 0 and pin.items.len >= n) break;
        if (!free.core(topo, taken, all.items, cpu)) {
            if (named.len != 0) return null;
            continue;
        }
        pin.append(a, cpu) catch return null;
        if (std.mem.findScalar(u32, all.items, cpu) == null) all.append(a, cpu) catch return null;
        for (siblingsOf(topo, cpu)) |sib| if (std.mem.findScalar(u32, all.items, sib) == null) {
            all.append(a, sib) catch return null;
        };
    }
    if (named.len == 0 and pin.items.len < n) return null;
    return .{ .pin = pin.items, .cpus = all.items };
}

/// How many of `cpus` are the pool's.
pub fn inPool(cpus: []const u32, pool: []const u32) u32 {
    var n: u32 = 0;
    for (cpus) |c| n += @intFromBool(std.mem.findScalar(u32, pool, c) != null);
    return n;
}

// --- The line: pure decisions over the runs' records ----------------------------------------

/// What a decision knows besides the records.
pub const Cx = struct {
    /// The pool's CPUs.
    pool_n: u32,
    /// The machine's busy CPUs as admission counts them (`busyNow`).
    busy: f64 = 0,
    /// Monotonic ms now.
    now_ms: i64 = 0,
};

pub const Wait = enum {
    /// It starts a task now.
    go,
    /// Tasks cpuq has stopped (its own, or others') continue before a task starts in spare room.
    paused,
    /// Running tasks are at `backstop` × T.
    backstop,
    /// Over its share, and the machine has no room.
    busy,
    /// Over its share, and another waiter goes first for the room.
    behind,
    /// Another run of its project goes first.
    project,
    /// Nothing to start.
    idle,
};

/// A project's running tasks and weight, among those running or waiting.
const Proj = struct { running: u32 = 0, weight: u32 = 1 };

fn projects(a: std.mem.Allocator, ops: []const Op) std.StringArrayHashMapUnmanaged(Proj) {
    var m: std.StringArrayHashMapUnmanaged(Proj) = .empty;
    for (ops) |o| {
        if (!o.counts() or (o.running == 0 and o.waiting == 0)) continue;
        const gop = m.getOrPut(a, o.project) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{ .weight = o.weight };
        gop.value_ptr.running += o.running;
        gop.value_ptr.weight = @max(gop.value_ptr.weight, o.weight);
    }
    return m;
}

fn weights(m: std.StringArrayHashMapUnmanaged(Proj)) u64 {
    var w: u64 = 0;
    for (m.values()) |p| w += p.weight;
    return @max(w, 1);
}

/// A project's fair share of capacity `t`: t × its weight ÷ the weights of the projects running
/// or waiting.
pub fn fairShare(a: std.mem.Allocator, ops: []const Op, project: []const u8, t: u32) f64 {
    const m = projects(a, ops);
    const p = m.get(project) orelse return 0;
    return @as(f64, @floatFromInt(t)) * @as(f64, @floatFromInt(p.weight)) / @as(f64, @floatFromInt(weights(m)));
}

/// Whether the project's running tasks are under its share: running × Σw < t × w, without
/// division.
fn under(m: std.StringArrayHashMapUnmanaged(Proj), project: []const u8, t: u32) bool {
    const p = m.get(project) orelse return t > 0;
    return @as(u64, p.running) * weights(m) < @as(u64, t) * p.weight;
}

/// Tasks started or continued in the last `fresh_ms`, which the sample can't have measured yet.
pub fn starting(ops: []const Op, now_ms: i64) u32 {
    var n: u32 = 0;
    for (ops) |o| if (o.counts()) for (o.tasks_now) |t| {
        if (!t.paused and t.fresh != 0 and now_ms - t.fresh < fresh_ms) n += 1;
    };
    return n;
}

/// Whether any run's task is stopped by cpuq for sharing (not for a drain of the whole machine).
fn anyPaused(ops: []const Op) bool {
    for (ops) |o| if (o.counts() and o.paused() > 0) return true;
    return false;
}

/// Whether `x` goes ahead of `y` for spare room: an urgent run's first task, then the project
/// running the fewest tasks for its weight, then the run running the fewest, then the run whose
/// last task started longest ago (one that has started none first), then the older ticket.
fn ahead(m: std.StringArrayHashMapUnmanaged(Proj), x: Op, y: Op) bool {
    const ux = x.urgent and !x.served;
    const uy = y.urgent and !y.served;
    if (ux != uy) return ux;
    const px = m.get(x.project) orelse Proj{};
    const py = m.get(y.project) orelse Proj{};
    const lx = @as(u64, px.running) * py.weight;
    const ly = @as(u64, py.running) * px.weight;
    if (lx != ly) return lx < ly;
    if (x.running != y.running) return x.running < y.running;
    if (x.last != y.last) return x.last < y.last;
    return x.ticket < y.ticket;
}

/// A project's first waiter: of its runs with tasks waiting and none of their own stopped by
/// cpuq, the one `ahead` puts first (within one project: an urgent run's first task, the run
/// running the fewest, the one whose last task started longest ago, the older ticket). Only it starts the project's next task.
pub fn projectFirst(a: std.mem.Allocator, ops: []const Op, project: []const u8) ?u64 {
    const m = projects(a, ops);
    var best: ?Op = null;
    for (ops) |o| {
        if (!o.counts() or o.waiting == 0 or o.paused() > 0) continue;
        if (!std.mem.eql(u8, o.project, project)) continue;
        if (best == null or ahead(m, o, best.?)) best = o;
    }
    return if (best) |b| b.ticket else null;
}

/// The first run in the line for spare room: of the runs with tasks waiting, over their share,
/// none of their own stopped by cpuq. Null when there is none.
pub fn firstWaiter(a: std.mem.Allocator, ops: []const Op, t: u32) ?u64 {
    const m = projects(a, ops);
    var best: ?Op = null;
    for (ops) |o| {
        if (!o.counts() or o.waiting == 0 or o.paused() > 0) continue;
        if (under(m, o.project, t)) continue;
        if (best == null or ahead(m, o, best.?)) best = o;
    }
    return if (best) |b| b.ticket else null;
}

/// Whether run `me` may start one more task now. The caller has checked the gates and its -c
/// (`waiting` > 0).
pub fn mayStart(a: std.mem.Allocator, ops: []const Op, me: u64, cx: Cx) Wait {
    const o = for (ops) |o| {
        if (o.ticket == me) break o;
    } else return .idle;
    if (!o.counts() or o.waiting == 0) return .idle;
    if (o.paused() > 0) return .paused;
    const t = capacity(ops, cx.pool_n, cx.now_ms);
    var total: u32 = 0;
    for (ops) |x| if (x.counts()) {
        total += x.running;
    };
    if (total >= backstop * t) return .backstop;
    if (projectFirst(a, ops, o.project) != me) return .project;
    const m = projects(a, ops);
    if (under(m, o.project, t)) return .go;
    if (anyPaused(ops)) return .paused;
    const room = @as(f64, @floatFromInt(t)) - headroom;
    if (cx.busy + @as(f64, @floatFromInt(starting(ops, cx.now_ms))) >= room) return .busy;
    if (firstWaiter(a, ops, t) != me) return .behind;
    return .go;
}

/// The machine's busy CPUs as admission counts them: the running tasks' busy CPUs from the
/// sample (tasks that ended since count no more; tasks cpuq stopped use nothing), plus, with the
/// outside check on, the load outside cpuq beyond the CPUs the pool leaves to it (`ncpu` −
/// `pool_n`). What drains isolate is left out: their commands, and on Linux every tick of their
/// CPUs (other tasks are kept off them), as those CPUs are out of the capacity.
pub fn busyNow(a: std.mem.Allocator, ops: []const Op, s: ?Sample, outside_check: bool, ncpu: u32, pool_n: u32, now_ms: i64) f64 {
    const sample = s orelse return 0;
    var tasks: f64 = 0;
    for (ops) |o| if (o.counts()) for (o.tasks_now) |t| {
        if (t.paused) continue;
        if (sample.find(t.pid, t.start)) |b| tasks += b.busy;
    };
    if (!outside_check) return tasks;
    var outside: f64 = 0;
    if (sample.cpus.len != 0) {
        // Linux: the CPUs not isolated, less the tasks that run there (all but drains').
        const iso = isolated(a, ops, now_ms);
        var machine: f64 = 0;
        for (sample.cpus) |c| if (std.mem.findScalar(u32, iso, c.cpu) == null) {
            machine += c.frac;
        };
        outside = @max(0, machine - (sample.tasks - sample.drains));
    } else {
        // macOS: the whole machine, less every task (drains' commands included).
        const machine = sample.machine orelse return tasks;
        outside = @max(0, machine - sample.tasks);
    }
    const spill = @max(0, outside - @as(f64, @floatFromInt(ncpu -| pool_n)));
    return tasks + spill;
}

// --- macOS: sharing time by stopping and continuing tasks -----------------------------------

/// One step of the plan: stop or continue one task.
pub const Step = struct { ticket: u64, pid: i32, pause: bool };

/// A task's busy CPUs for the plan: one while fresh or unmeasured, else the sample's.
fn load(t: TaskNow, s: ?Sample, now_ms: i64) f64 {
    if (t.fresh == 0 or now_ms - t.fresh < fresh_ms) return 1;
    const sample = s orelse return 1;
    const b = sample.find(t.pid, t.start) orelse return 1;
    return b.busy;
}

const Live = struct { ticket: u64, task: TaskNow, project: []const u8, load: f64 };

/// macOS, where nothing shares CPU time by project: while cpuq's runnable tasks keep more than
/// T + `headroom` CPUs busy, stop the newest tasks of the project furthest over its share until
/// they keep no more than that; while they keep less than T and tasks are stopped, continue the
/// oldest stopped task of the project furthest under its share, while one more fits within T.
/// A project at or under its share is never stopped. Every cpuq computes the same plan from the
/// records and carries out the steps for its own tasks.
pub fn pausePlan(a: std.mem.Allocator, ops: []const Op, s: ?Sample, cx: Cx) []const Step {
    var out: std.ArrayList(Step) = .empty;
    const t = capacity(ops, cx.pool_n, cx.now_ms);
    const m = projects(a, ops);
    // Each project's share, and its tasks running unstopped.
    var run: std.StringArrayHashMapUnmanaged(f64) = .empty;
    var live: std.ArrayList(Live) = .empty;
    var stopped: std.ArrayList(Live) = .empty;
    var r: f64 = 0;
    for (ops) |o| if (o.counts()) for (o.tasks_now) |task| {
        const l: Live = .{ .ticket = o.ticket, .task = task, .project = o.project, .load = load(task, s, cx.now_ms) };
        const gop = run.getOrPut(a, o.project) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = 0;
        if (task.paused) {
            stopped.append(a, l) catch {};
        } else {
            gop.value_ptr.* += 1;
            live.append(a, l) catch {};
            r += l.load;
        }
    };
    const tf: f64 = @floatFromInt(t);
    const w: f64 = @floatFromInt(weights(m));
    const share = struct {
        fn of(mm: std.StringArrayHashMapUnmanaged(Proj), p: []const u8, tt: f64, ww: f64) f64 {
            const pr = mm.get(p) orelse return 0;
            return tt * @as(f64, @floatFromInt(pr.weight)) / ww;
        }
    };
    if (r > tf + headroom) {
        while (r > tf + headroom) {
            // The project furthest over its share, by tasks running unstopped.
            var worst: ?[]const u8 = null;
            var worst_by: f64 = 0;
            for (run.keys(), run.values()) |p, n| {
                const by = n - share.of(m, p, tf, w);
                if (by <= 0) continue;
                if (worst == null or by > worst_by or (by == worst_by and std.mem.order(u8, p, worst.?) == .lt)) {
                    worst = p;
                    worst_by = by;
                }
            }
            const p = worst orelse break;
            // Its newest task running.
            var pick: ?usize = null;
            for (live.items, 0..) |l, i| {
                if (!std.mem.eql(u8, l.project, p)) continue;
                if (pick == null or l.task.fresh > live.items[pick.?].task.fresh) pick = i;
            }
            const i = pick orelse break;
            const l = live.swapRemove(i);
            out.append(a, .{ .ticket = l.ticket, .pid = l.task.pid, .pause = true }) catch break;
            r -= l.load;
            run.getPtr(p).?.* -= 1;
        }
        return out.items;
    }
    while (stopped.items.len > 0 and r + 1 <= tf) {
        // The project furthest under its share, of those with a task stopped.
        var best: ?[]const u8 = null;
        var best_by: f64 = 0;
        for (stopped.items) |l| {
            const by = (run.get(l.project) orelse 0) - share.of(m, l.project, tf, w);
            if (best == null or by < best_by or (by == best_by and std.mem.order(u8, l.project, best.?) == .lt)) {
                best = l.project;
                best_by = by;
            }
        }
        const p = best.?;
        var pick: ?usize = null;
        for (stopped.items, 0..) |l, i| {
            if (!std.mem.eql(u8, l.project, p)) continue;
            if (pick == null or l.task.fresh < stopped.items[pick.?].task.fresh) pick = i;
        }
        const l = stopped.swapRemove(pick.?);
        out.append(a, .{ .ticket = l.ticket, .pid = l.task.pid, .pause = false }) catch break;
        r += 1;
        run.getPtr(p).?.* += 1;
    }
    return out.items;
}

// --- Tests ----------------------------------------------------------------------------------

fn tk(pid: i32, fresh: i64) TaskNow {
    return .{ .pid = pid, .start = @intCast(pid), .fresh = fresh, .since = 1 };
}

test "an op record round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const now = [_]TaskNow{.{ .task = 17, .attempt = 2, .pid = 4242, .start = 99, .since = 1700000000, .fresh = 12345, .paused = true }};
    const r: Op = .{ .tasks_now = &now, .pid = 7, .project = "rig", .label = "rig:test", .weight = 2, .waiting = 3, .cpus = &.{ 4, 9 }, .pin = &.{4}, .npool = 2, .noise = 0.25, .noisy_top = "dd (77)", .dstart = 77, .limit = 8, .tasks = 100, .done = 5, .single = true, .cmd = "a\tb\nc" };
    try r.format(&w);
    const p = Op.parse(arena.allocator(), w.buffered());
    try std.testing.expectEqualStrings("rig", p.project);
    try std.testing.expectEqualSlices(u32, &.{ 4, 9 }, p.cpus);
    try std.testing.expectEqualSlices(u32, &.{4}, p.pin);
    try std.testing.expectEqual(2, p.npool);
    try std.testing.expectEqual(0.25, p.noise);
    try std.testing.expectEqualStrings("dd (77)", p.noisy_top);
    try std.testing.expectEqual(77, p.dstart);
    try std.testing.expectEqual(3, p.waiting);
    try std.testing.expect(p.single);
    try std.testing.expectEqualStrings("a b c", p.cmd);
    try std.testing.expectEqual(1, p.tasks_now.len);
    try std.testing.expectEqual(17, p.tasks_now[0].task);
    try std.testing.expectEqual(4242, p.tasks_now[0].pid);
    try std.testing.expectEqual(99, p.tasks_now[0].start);
    try std.testing.expectEqual(12345, p.tasks_now[0].fresh);
    try std.testing.expect(p.tasks_now[0].paused);
    try std.testing.expectEqual(1, p.paused());
}

test "a sample round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const s: Sample = .{ .ms = 5, .ticks_busy = 10, .ticks_total = 20, .machine = 3.5, .tasks = 1.25, .per = &.{.{ .pid = 4, .start = 8, .cum = 1000, .busy = 0.75 }} };
    var out: std.ArrayList(u8) = .empty;
    try s.format(a, &out);
    const p = Sample.parse(a, out.items).?;
    try std.testing.expectEqual(5, p.ms);
    try std.testing.expectEqual(3.5, p.machine.?);
    try std.testing.expectEqual(0.75, p.find(4, 8).?.busy);
    try std.testing.expectEqual(null, p.find(4, 9));
}

test "admission: under its share a project starts at once, however busy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pool of 4; rig runs 4 tasks, the machine is full; trig arrives with 2 waiting.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 4, .waiting = 6, .tasks_now = &.{ tk(1, 0), tk(2, 0), tk(3, 0), tk(4, 0) } },
        .{ .ticket = 2, .project = "trig", .waiting = 2 },
    };
    const cx: Cx = .{ .pool_n = 4, .busy = 4, .now_ms = 100_000 };
    try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 2, cx));
    try std.testing.expectEqual(Wait.busy, mayStart(a, &ops, 1, cx));
    // trig at 2 of its share of 2: no longer under it, and the machine is busy.
    var two = ops;
    two[1].running = 2;
    try std.testing.expectEqual(Wait.busy, mayStart(a, &two, 2, cx));
    // Weights: trig 3 to rig's 1 has a share of 3.
    two[1].weight = 3;
    try std.testing.expectEqual(Wait.go, mayStart(a, &two, 2, cx));
}

test "admission: spare room goes to the first waiter over its share" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pool of 4, both projects over their share of 2, the machine half idle (tasks waiting on I/O).
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 3, .waiting = 5 },
        .{ .ticket = 2, .project = "trig", .running = 2, .waiting = 5 },
    };
    const cx: Cx = .{ .pool_n = 4, .busy = 1.0, .now_ms = 100_000 };
    // trig runs fewer for its weight: it goes first; rig waits behind it.
    try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 2, cx));
    try std.testing.expectEqual(Wait.behind, mayStart(a, &ops, 1, cx));
    try std.testing.expectEqual(2, firstWaiter(a, &ops, 4).?);
    // Room is busy + starting < T - 0.5: three tasks just started fill it.
    var fresh = ops;
    fresh[0].tasks_now = &.{ tk(1, 99_000), tk(2, 99_500), tk(3, 99_900) };
    try std.testing.expectEqual(Wait.busy, mayStart(a, &fresh, 2, cx));
    // An urgent run's first task goes ahead of the line.
    var urgent = ops;
    urgent[0].urgent = true;
    try std.testing.expectEqual(Wait.go, mayStart(a, &urgent, 1, cx));
}

test "admission: within a project, the run running the fewest goes first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // rig's long run (1) holds rig's share; it ends a task, so rig is under its share again. A
    // newer rig run (3) running nothing takes that start, not the long run.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 1, .waiting = 20 },
        .{ .ticket = 2, .project = "trig", .running = 2, .waiting = 5 },
        .{ .ticket = 3, .project = "rig", .waiting = 1 },
    };
    const cx: Cx = .{ .pool_n = 4, .busy = 4, .now_ms = 100_000 };
    try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 3, cx));
    try std.testing.expectEqual(Wait.project, mayStart(a, &ops, 1, cx));
    try std.testing.expectEqual(3, projectFirst(a, &ops, "rig").?);
    // Running the same, the older ticket; an urgent run's first task before either.
    var even = ops;
    even[2].running = 1;
    try std.testing.expectEqual(1, projectFirst(a, &even, "rig").?);
    even[2].urgent = true;
    try std.testing.expectEqual(3, projectFirst(a, &even, "rig").?);
    // The long run has just ended its task: running none, as the newer run, it takes its turn
    // behind it (its last start is the newer).
    var tie = ops;
    tie[0].running = 0;
    tie[0].last = 90_000;
    try std.testing.expectEqual(3, projectFirst(a, &tie, "rig").?);
    tie[2].last = 95_000;
    try std.testing.expectEqual(1, projectFirst(a, &tie, "rig").?);
    // For spare room too: over their shares, the newer rig run (running 0) is first in line.
    const over = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 3, .waiting = 20 },
        .{ .ticket = 2, .project = "trig", .running = 3, .waiting = 5 },
        .{ .ticket = 3, .project = "rig", .waiting = 1 },
    };
    try std.testing.expectEqual(3, firstWaiter(a, &over, 4).?);
}

test "admission: hard limits" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The backstop: 4T tasks running, even a project under its share waits.
    const full = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 8, .waiting = 1 },
        .{ .ticket = 2, .project = "trig", .waiting = 1 },
    };
    try std.testing.expectEqual(Wait.backstop, mayStart(a, &full, 2, .{ .pool_n = 2 }));
    // A run with nothing to start, or stopped, is idle.
    const idle = [_]Op{ .{ .ticket = 1, .project = "rig" }, .{ .ticket = 2, .project = "q", .waiting = 1, .stopped = true } };
    try std.testing.expectEqual(Wait.idle, mayStart(a, &idle, 1, .{ .pool_n = 2 }));
    try std.testing.expectEqual(Wait.idle, mayStart(a, &idle, 2, .{ .pool_n = 2 }));
    // A run whose tasks cpuq has stopped starts none; others take no spare room meanwhile.
    var p = [_]TaskNow{tk(5, 0)};
    p[0].paused = true;
    const paused = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 3, .waiting = 1, .tasks_now = &p },
        .{ .ticket = 2, .project = "trig", .running = 3, .waiting = 1 },
    };
    try std.testing.expectEqual(Wait.paused, mayStart(a, &paused, 1, .{ .pool_n = 4 }));
    try std.testing.expectEqual(Wait.paused, mayStart(a, &paused, 2, .{ .pool_n = 4 }));
}

test "drains: isolation, the half-pool bound, and the turn" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: i64 = 1_000_000;
    // A drain of 2 isolating CPUs 6 and 7 of 8: capacity 6.
    const d1: Op = .{ .ticket = 1, .drain = true, .limit = 2, .cpus = &.{ 6, 7 }, .npool = 2, .dstart = now - 1000, .tlimit = 600 };
    try std.testing.expectEqual(6, capacity(&.{d1}, 8, now));
    try std.testing.expectEqualSlices(u32, &.{ 6, 7 }, isolated(a, &.{d1}, now));
    // Past its limit and grace, it isolates nothing.
    try std.testing.expectEqual(8, capacity(&.{d1}, 8, now + 700_000));
    // A second drain needing 3 would pass half the pool (4): it waits; one needing 2 goes.
    const d2: Op = .{ .ticket = 2, .drain = true, .limit = 3, .waiting = 1 };
    try std.testing.expectEqual(DrainWait.half_pool, drainMayStart(&.{ d1, d2 }, 2, 8, now, 3));
    try std.testing.expectEqual(DrainWait.go, drainMayStart(&.{ d1, d2 }, 2, 8, now, 2));
    // A run older than the drain waiting with no task running goes first; one running tasks
    // already, or a newer one, doesn't hold it.
    const old: Op = .{ .ticket = 1, .project = "rig", .waiting = 1 };
    const young: Op = .{ .ticket = 3, .project = "rig", .waiting = 1 };
    try std.testing.expectEqual(DrainWait.older_waiter, drainMayStart(&.{ old, d2 }, 2, 8, now, 1));
    try std.testing.expectEqual(DrainWait.go, drainMayStart(&.{ d2, young }, 2, 8, now, 1));
    var busy_old = old;
    busy_old.running = 3;
    try std.testing.expectEqual(DrainWait.go, drainMayStart(&.{ busy_old, d2 }, 2, 8, now, 1));
    // An older drain waiting goes first.
    const w1: Op = .{ .ticket = 1, .drain = true, .limit = 1, .waiting = 1 };
    try std.testing.expectEqual(DrainWait.older_drain, drainMayStart(&.{ w1, d2 }, 2, 8, now, 1));
    // A stopped drain isolates nothing.
    var stopped = d1;
    stopped.stopped = true;
    try std.testing.expectEqual(8, capacity(&.{stopped}, 8, now));
}

test "drains: whole cores, from the pool's end, fastest first, or as named" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Core = @import("cpus.zig").Core;
    // 4 cores of 2 threads: 0+4, 1+5, 2+6, 3+7; the pool's order puts first threads first.
    const topo = [_]Core{
        .{ .cpu = 0, .siblings = &.{4} }, .{ .cpu = 1, .siblings = &.{5} }, .{ .cpu = 2, .siblings = &.{6} }, .{ .cpu = 3, .siblings = &.{7} },
        .{ .cpu = 4, .siblings = &.{0} }, .{ .cpu = 5, .siblings = &.{1} }, .{ .cpu = 6, .siblings = &.{2} }, .{ .cpu = 7, .siblings = &.{3} },
    };
    const from_end = [_]u32{ 7, 6, 5, 4, 3, 2, 1, 0 };
    const p = pickDrain(a, &from_end, &topo, &.{}, 1, &.{}).?;
    try std.testing.expectEqualSlices(u32, &.{7}, p.pin);
    try std.testing.expectEqualSlices(u32, &.{ 7, 3 }, p.cpus);
    // Two: two whole cores, never both threads of one as two CPUs.
    const two = pickDrain(a, &from_end, &topo, &.{}, 2, &.{}).?;
    try std.testing.expectEqualSlices(u32, &.{ 7, 6 }, two.pin);
    try std.testing.expectEqualSlices(u32, &.{ 7, 3, 6, 2 }, two.cpus);
    // A core partly another drain's is skipped.
    const skip = pickDrain(a, &from_end, &topo, &.{3}, 1, &.{}).?;
    try std.testing.expectEqualSlices(u32, &.{6}, skip.pin);
    // Named: exactly those, or none while one of them (or a sibling) is taken.
    const named = pickDrain(a, &from_end, &topo, &.{}, 2, &.{ 0, 1 }).?;
    try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, named.pin);
    try std.testing.expectEqualSlices(u32, &.{ 0, 4, 1, 5 }, named.cpus);
    try std.testing.expectEqual(null, pickDrain(a, &from_end, &topo, &.{5}, 2, &.{ 0, 1 }));
    // Not enough whole cores free.
    try std.testing.expectEqual(null, pickDrain(a, &from_end, &topo, &.{ 0, 1, 2 }, 2, &.{}));
    // No SMT (macOS, or siblings unknown): just the CPUs.
    const flat = pickDrain(a, &from_end, &.{}, &.{}, 2, &.{}).?;
    try std.testing.expectEqualSlices(u32, &.{ 7, 6 }, flat.cpus);
    try std.testing.expectEqual(2, inPool(two.cpus, &.{ 0, 1, 6, 7 }));
}

test "busy: tasks from the sample, outside load beyond the CPUs left to it, isolated CPUs left out" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ops = [_]Op{.{ .ticket = 1, .project = "rig", .running = 2, .tasks_now = &.{ tk(1, 0), tk(2, 0) } }};
    const s: Sample = .{ .ms = 1, .machine = 7.0, .tasks = 1.5, .per = &.{ .{ .pid = 1, .start = 1, .cum = 0, .busy = 1.0 }, .{ .pid = 2, .start = 2, .cum = 0, .busy = 0.5 }, .{ .pid = 3, .start = 3, .cum = 0, .busy = 1 } } };
    // Outside: 7 - 1.5 = 5.5 busy, the pool leaves 2 of 10 CPUs to it: 3.5 spills in.
    try std.testing.expectApproxEqAbs(5.0, busyNow(a, &ops, s, true, 10, 8, 0), 1e-9);
    try std.testing.expectApproxEqAbs(1.5, busyNow(a, &ops, s, false, 10, 8, 0), 1e-9);
    try std.testing.expectEqual(0, busyNow(a, &ops, null, true, 10, 8, 0));
    // Linux, 4 CPUs all in the pool: a drain isolates CPU 3 and keeps it busy. Its command's
    // CPU and CPU 3's ticks count for no one: busy is the tasks' 1.5 and nothing outside.
    const d: Op = .{ .ticket = 2, .drain = true, .limit = 1, .cpus = &.{3}, .npool = 1, .dstart = 1, .tlimit = 600, .running = 1, .tasks_now = &.{tk(3, 0)} };
    const lin: Sample = .{ .ms = 1, .tasks = 2.5, .drains = 1.0, .per = s.per, .cpus = &.{
        .{ .cpu = 0, .busy = 0, .total = 0, .frac = 1.0 }, .{ .cpu = 1, .busy = 0, .total = 0, .frac = 0.5 },
        .{ .cpu = 2, .busy = 0, .total = 0, .frac = 0.0 }, .{ .cpu = 3, .busy = 0, .total = 0, .frac = 1.0 },
    } };
    try std.testing.expectApproxEqAbs(1.5, busyNow(a, &.{ ops[0], d }, lin, true, 4, 4, 2), 1e-9);
}

test "pause plan: stop the newest of the project furthest over its share, continue when room returns" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: i64 = 100_000;
    // Pool of 2: rig runs 3 busy tasks, trig 1: rig is over its share of 1 by 2.
    const busy = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 3, .tasks_now = &.{ tk(1, 10_000), tk(2, 20_000), tk(3, 30_000) } },
        .{ .ticket = 2, .project = "trig", .running = 1, .tasks_now = &.{tk(4, 10_000)} },
    };
    const plan = pausePlan(a, &busy, null, .{ .pool_n = 2, .now_ms = now });
    try std.testing.expectEqual(2, plan.len);
    try std.testing.expectEqual(3, plan[0].pid);
    try std.testing.expect(plan[0].pause);
    try std.testing.expectEqual(2, plan[1].pid);
    // Tasks waiting on I/O keep no CPU busy: nothing stops.
    const s: Sample = .{ .ms = 1, .per = &.{ .{ .pid = 1, .start = 1, .cum = 0, .busy = 0.1 }, .{ .pid = 2, .start = 2, .cum = 0, .busy = 0.1 }, .{ .pid = 3, .start = 3, .cum = 0, .busy = 0.1 }, .{ .pid = 4, .start = 4, .cum = 0, .busy = 1 } } };
    try std.testing.expectEqual(0, pausePlan(a, &busy, s, .{ .pool_n = 2, .now_ms = now }).len);
    // Room again (trig's task ended): rig's oldest stopped task continues, one per CPU free.
    var p = [_]TaskNow{ tk(1, 10_000), tk(2, 20_000), tk(3, 30_000) };
    p[1].paused = true;
    p[2].paused = true;
    const room = [_]Op{.{ .ticket = 1, .project = "rig", .running = 3, .tasks_now = &p }};
    const back = pausePlan(a, &room, null, .{ .pool_n = 2, .now_ms = now });
    try std.testing.expectEqual(1, back.len);
    try std.testing.expectEqual(2, back[0].pid);
    try std.testing.expect(!back[0].pause);
}
