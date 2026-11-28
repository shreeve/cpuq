//! The pool: the machine's tokens, and the line that decides which run takes a freed one. A
//! machine has N tokens, one per CPU of the pool less the reserve (config `reserve`, 2 by
//! default; at least one token). A task holds one token while it runs, on Linux pinned to that
//! token's CPU, and gives it back the moment it ends: at most N tasks run at once, ever. A drain
//! takes the tokens of the whole cores it isolates, all at once, and holds none while it waits.
//! Everything lives under a versioned folder in the state directory, so a cpuq of another version
//! never reads these files as its own:
//!
//!   v4/lock          the pool's lock: every scan, start and record write happens under it
//!   v4/seq           the last ticket number handed out
//!   v4/ops/C-TICKET  one per live run, exclusively locked by its cpuq for its whole life (C: 0
//!                    urgent, 1 normal). Its text says what it runs, what it could start, and its
//!                    tasks (pid, start time and token CPU), so whoever finds it dead ends its
//!                    leftovers
//!   v4/wake/TICKET   the run's FIFO: whoever frees a token for it writes a byte there
//!   v4/limits/PID    `cpuq limit`'s request: the run's new -c
//!   v4/sample        the last measure of the machine: its busy CPUs (kernel ticks) and each
//!                    task's (its process tree's CPU time), renewed at most once a second by
//!                    whichever cpuq finds it old (v4/sample.lock keeps it to one at a time)
//!
//! A file whose lock can be taken has no live holder: whoever finds it so ends what it left
//! running and removes it, under the pool's lock.
//!
//! The rules, as pure functions over the records (`mayStart`, `drainMayStart`):
//!   - Tokens free: N, less those held back for work outside cpuq beyond the CPUs it leaves to
//!     it (`heldBack`), less those held (each running task's, each isolating drain's).
//!   - A project's fair share: N × its weight ÷ the weights of the projects running or waiting.
//!   - Within a project, its first waiter goes first: an urgent run's first task, then the run
//!     running the fewest tasks, then the older turn (when its last task started, or, for a run
//!     that has started none, when it arrived), then ticket.
//!   - One line for every free token, among the projects' first waiters: projects under their
//!     share first, then an urgent run's first task, then the project running the fewest for its
//!     weight, then the run running the fewest, then ticket. Only the first in line takes it.
//!   - Hard limits: a run's -c, the memory, disk and pressure gates.
//!   - No stream of arrivals starves a waiting run (formal/, `run_starts_fixed`): new runs of its
//!     project come after it, and every freed token goes to the first in line.
const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");

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
        const path = try std.fmt.allocPrint(a, "{s}/v4", .{state_dir});
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
/// (monotonic ms), whether cpuq has it stopped (after a Ctrl-Z, until it holds a token again),
/// and the CPU whose token it holds (on Linux, the CPU it is pinned to). A stopped task holds no
/// token.
pub const TaskNow = struct {
    task: u32 = 0,
    attempt: u32 = 1,
    pid: i32 = 0,
    start: u64 = 0,
    since: i64 = 0,
    fresh: i64 = 0,
    paused: bool = false,
    cpu: u32 = 0,
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
    /// When it entered the line (monotonic ms): its turn within its project until it starts a
    /// task.
    arrived: i64 = 0,
    /// `cpuq drain`: isolates `limit` CPUs (with their SMT siblings) for its command, once its
    /// turn comes.
    drain: bool = false,
    /// One task, sharing its cpuq's process group (`cpuq run -- CMD`).
    single: bool = false,
    /// `cpuq run --driver`: a test runner, no task of its own; `dbusy` is the CPUs its own process
    /// tree keeps busy, the runs it starts left out (measured by its cpuq once a second). It
    /// counts against its project's share.
    driver: bool = false,
    dbusy: f64 = 0,
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
    /// Its tasks running, each holding a token (those cpuq has stopped left out); a drain: its
    /// command.
    running: u32 = 0,
    /// Tasks it could start now (none while stopped, or at its -c); a drain waiting: 1.
    waiting: u32 = 0,
    /// A drain: the CPUs it isolates, once it has started.
    cpus: []const u32 = &.{},
    /// A drain: the CPUs its command runs on (CPUQ_CPUS), and how many of `cpus` are tokens: the
    /// tokens it holds.
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
        try w.print("pid={d}\nurgent={d}\nserved={d}\ndrain={d}\nsingle={d}\ndriver={d}\ndbusy={d:.3}\nstopped={d}\nproject={s}\nlabel={s}\nweight={d}\nlimit={d}\ntasks={d}\ndone={d}\nfailed={d}\nrunning={d}\nwaiting={d}\ncpus=", .{
            r.pid,     @intFromBool(r.urgent), @intFromBool(r.served), @intFromBool(r.drain), @intFromBool(r.single), @intFromBool(r.driver), r.dbusy,  @intFromBool(r.stopped),
            r.project, r.label,                r.weight,               r.limit,               r.tasks,                r.done,                 r.failed, r.running,
            r.waiting,
        });
        for (r.cpus, 0..) |cpu, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", cpu });
        try w.writeAll("\npin=");
        for (r.pin, 0..) |cpu, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", cpu });
        try w.print("\nnpool={d}\nnoise={d:.3}\nnoisy_top={s}\nlast={d}\narrived={d}\ndstart={d}\nsince={d}\ntlimit={d}\nwhy={s}\nnow=", .{ r.npool, r.noise, r.noisy_top, r.last, r.arrived, r.dstart, r.since, r.tlimit, r.why });
        for (r.tasks_now, 0..) |t, i| try w.print("{s}{d}:{d}:{d}:{d}:{d}:{d}:{d}:{d}", .{ if (i == 0) "" else ",", t.task, t.attempt, t.pid, t.start, t.since, t.fresh, @intFromBool(t.paused), t.cpu });
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
            if (eq(k, "driver")) r.driver = eq(v, "1");
            if (eq(k, "dbusy")) r.dbusy = std.fmt.parseFloat(f64, v) catch 0;
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
            if (eq(k, "arrived")) r.arrived = std.fmt.parseInt(i64, v, 10) catch 0;
            if (eq(k, "dstart")) r.dstart = std.fmt.parseInt(i64, v, 10) catch 0;
            if (eq(k, "since")) r.since = std.fmt.parseInt(i64, v, 10) catch 0;
            if (eq(k, "tlimit")) r.tlimit = n;
            if (eq(k, "why")) r.why = v;
            if (eq(k, "now")) r.tasks_now = parseTasks(a, v);
            if (eq(k, "cmd")) r.cmd = v;
        }
        return r;
    }

    /// Its tasks cpuq has stopped: after a Ctrl-Z, until each holds a token again.
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
            .cpu = std.fmt.parseInt(u32, f.next() orelse "0", 10) catch 0,
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

// --- Tokens ---------------------------------------------------------------------------------

/// The machine's tokens: the pool's first N CPUs in its order, N = the pool less `reserve`, at
/// least one. The reserve is the pool's last CPUs, never handed out.
pub fn tokens(pool: []const u32, reserve: u32) []const u32 {
    if (pool.len == 0) return pool;
    return pool[0..@max(1, pool.len -| reserve)];
}

/// Whether task `t` of run `o` holds a token: a running task of a run, not stopped by cpuq. A
/// drain's command holds none of its own: the drain holds its CPUs' tokens.
fn holds(o: Op, t: TaskNow) bool {
    return !o.drain and !t.paused;
}

/// Tokens held: one per task running, and each isolating drain's (`npool`).
pub fn heldCount(ops: []const Op, now_ms: i64) u32 {
    var n: u32 = 0;
    for (ops) |o| {
        if (isolating(o, now_ms)) n += o.npool;
        for (o.tasks_now) |t| n += @intFromBool(holds(o, t));
    }
    return n;
}

/// The CPUs whose tokens are held: each running task's, and every CPU drains isolate.
pub fn heldCpus(a: std.mem.Allocator, ops: []const Op, now_ms: i64) []const u32 {
    var out: std.ArrayList(u32) = .empty;
    out.appendSlice(a, isolated(a, ops, now_ms)) catch {};
    for (ops) |o| for (o.tasks_now) |t| if (holds(o, t)) {
        out.append(a, t.cpu) catch break;
    };
    return out.items;
}

/// Tokens free: `n` (the machine's), less those held back for work outside cpuq, less those held.
pub fn freeTokens(ops: []const Op, n: u32, held_back: u32, now_ms: i64) u32 {
    return (n -| held_back) -| heldCount(ops, now_ms);
}

/// A free token's CPU: the first of `toks` (in the pool's order) no task holds and no drain
/// isolates. Null when every one is held.
pub fn freeCpu(a: std.mem.Allocator, toks: []const u32, ops: []const Op, now_ms: i64) ?u32 {
    const held = heldCpus(a, ops, now_ms);
    for (toks) |cpu| if (std.mem.findScalar(u32, held, cpu) == null) return cpu;
    return null;
}

pub const DrainWait = enum {
    /// Its turn: it isolates now.
    go,
    /// A run that queued before it waits with no task running: a drain passes no such waiter.
    older_waiter,
    /// An older drain waits too: drains go in their order.
    older_drain,
    /// Its CPUs would take the drains' isolation past `drain_max` (half the tokens by default).
    half_pool,
    /// Its turn has come, but fewer tokens are free than it needs.
    full,
    /// The CPUs it names, or enough whole cores for it, are another drain's.
    taken,
};

/// Whether drain `me` may begin isolating now, taking `need` tokens (its CPUs and their siblings
/// that are tokens), where drains together hold at most `room` (config `drain_max`) and `free`
/// tokens are free. Its whole cores being free of every holder is the caller's (`pickDrain`).
pub fn drainMayStart(ops: []const Op, me: u64, room: u32, now_ms: i64, need: u32, free: u32) DrainWait {
    var iso: u32 = 0;
    for (ops) |o| {
        if (o.ticket == me) continue;
        // 0.34's turn: a run that queued before it and waits holding nothing (no task running)
        // goes first; one already running tasks takes the rest of its turn beside the drain.
        if (o.ticket < me and o.counts() and o.waiting > 0 and o.running == 0) return .older_waiter;
        if (o.ticket < me and o.drain and !o.stopped and o.dstart == 0) return .older_drain;
        if (isolating(o, now_ms)) iso += o.npool;
    }
    if (iso + need > room) return .half_pool;
    if (need > free) return .full;
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
        // A named CPU that is a sibling of one named before it is this drain's already.
        if (named.len != 0 and std.mem.findScalar(u32, all.items, cpu) != null) {
            pin.append(a, cpu) catch return null;
            continue;
        }
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

test "a named drain takes both threads of a core" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Core = @import("cpus.zig").Core;
    // pup: 0 and 5 share a core, 1-2, 3-4 likewise; 13 has none.
    const topo = [_]Core{
        .{ .cpu = 0, .siblings = &.{5} }, .{ .cpu = 5, .siblings = &.{0} },
        .{ .cpu = 1, .siblings = &.{2} }, .{ .cpu = 2, .siblings = &.{1} },
        .{ .cpu = 3, .siblings = &.{4} }, .{ .cpu = 4, .siblings = &.{3} },
        .{ .cpu = 13, .siblings = &.{} },
    };
    const p = pickDrain(a, &.{}, &topo, &.{}, 7, &.{ 0, 1, 2, 3, 4, 5, 13 }).?;
    try std.testing.expectEqual(7, p.pin.len);
    try std.testing.expectEqual(7, p.cpus.len);
    // Naming one thread of a core isolates its sibling too.
    const q = pickDrain(a, &.{}, &topo, &.{}, 2, &.{ 0, 1 }).?;
    try std.testing.expectEqual(4, q.cpus.len);
    // A named CPU another drain holds: none.
    try std.testing.expectEqual(null, pickDrain(a, &.{}, &topo, &.{2}, 1, &.{1}));
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
    /// The machine's tokens (N).
    n: u32,
    /// Tokens held back for work outside cpuq (`heldBack`).
    held_back: u32 = 0,
    /// Monotonic ms now.
    now_ms: i64 = 0,
};

pub const Wait = enum {
    /// It takes a token and starts a task now.
    go,
    /// No token is free.
    full,
    /// Another run is first in line for the next free token.
    behind,
    /// Another run of its project goes first.
    project,
    /// Nothing to start.
    idle,
};

/// A project's running tasks and weight, among those running or waiting.
/// A project's running tasks, the CPUs its drivers keep busy themselves (`extra`), and its
/// weight, among those running or waiting.
const Proj = struct { running: u32 = 0, extra: f64 = 0, weight: u32 = 1 };

/// A driver whose own tree keeps at least this many CPUs busy computes, and counts: against its
/// project's share, and in status's flag.
pub const driver_min: f64 = 0.5;

fn projects(a: std.mem.Allocator, ops: []const Op) std.StringArrayHashMapUnmanaged(Proj) {
    var m: std.StringArrayHashMapUnmanaged(Proj) = .empty;
    for (ops) |o| {
        const computes = o.driver and o.dbusy >= driver_min;
        if (!o.counts() or (o.running == 0 and o.waiting == 0 and !computes)) continue;
        const gop = m.getOrPut(a, o.project) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{ .weight = o.weight };
        gop.value_ptr.running += o.running;
        if (computes) gop.value_ptr.extra += o.dbusy;
        gop.value_ptr.weight = @max(gop.value_ptr.weight, o.weight);
    }
    return m;
}

/// A project's load for the line: its tasks running and its drivers' own busy CPUs.
fn loadOf(p: Proj) f64 {
    return @as(f64, @floatFromInt(p.running)) + p.extra;
}

fn weights(m: std.StringArrayHashMapUnmanaged(Proj)) u64 {
    var w: u64 = 0;
    for (m.values()) |p| w += p.weight;
    return @max(w, 1);
}

/// A project's fair share of `t` tokens: t × its weight ÷ the weights of the projects running
/// or waiting.
pub fn fairShare(a: std.mem.Allocator, ops: []const Op, project: []const u8, t: u32) f64 {
    const m = projects(a, ops);
    const p = m.get(project) orelse return 0;
    return @as(f64, @floatFromInt(t)) * @as(f64, @floatFromInt(p.weight)) / @as(f64, @floatFromInt(weights(m)));
}

/// Whether the project's load (running tasks, and its drivers' own busy CPUs) is under its
/// share: load × Σw < t × w.
fn under(m: std.StringArrayHashMapUnmanaged(Proj), project: []const u8, t: u32) bool {
    const p = m.get(project) orelse return t > 0;
    return loadOf(p) * @as(f64, @floatFromInt(weights(m))) < @as(f64, @floatFromInt(@as(u64, t) * p.weight));
}

/// A run's turn within its project: when it last started a task, or, if it has started none,
/// when it arrived. Of a project's runs running as many, the older turn goes first, so a stream
/// of new runs goes behind a run that started before them and waits.
fn turn(o: Op) i64 {
    return if (o.last != 0) o.last else o.arrived;
}

fn urgentFirst(o: Op) bool {
    return o.urgent and !o.served;
}

/// Within one project, whether `x` goes before `y`: an urgent run's first task, then the run
/// running the fewest, then the older turn (last start, or arrival if it has started none), then
/// the older ticket.
fn pbefore(x: Op, y: Op) bool {
    if (urgentFirst(x) != urgentFirst(y)) return urgentFirst(x);
    if (x.running != y.running) return x.running < y.running;
    if (turn(x) != turn(y)) return turn(x) < turn(y);
    return x.ticket < y.ticket;
}

/// In the line among the projects' first waiters, whether `x` goes before `y`: a project under
/// its share first, then an urgent run's first task, then the project running the fewest for its
/// weight, then the run running the fewest, then the older ticket.
fn lineBefore(m: std.StringArrayHashMapUnmanaged(Proj), t: u32, x: Op, y: Op) bool {
    const ux = under(m, x.project, t);
    const uy = under(m, y.project, t);
    if (ux != uy) return ux;
    if (urgentFirst(x) != urgentFirst(y)) return urgentFirst(x);
    const px = m.get(x.project) orelse Proj{};
    const py = m.get(y.project) orelse Proj{};
    const lx = loadOf(px) * @as(f64, @floatFromInt(py.weight));
    const ly = loadOf(py) * @as(f64, @floatFromInt(px.weight));
    if (lx != ly) return lx < ly;
    if (x.running != y.running) return x.running < y.running;
    return x.ticket < y.ticket;
}

/// Whether a run waits in the line: a run (not a drain) with tasks it could start, its cpuq not
/// stopped.
fn waits(o: Op) bool {
    return o.counts() and o.waiting > 0;
}

/// A project's first waiter among `ops`: of its runs waiting in the line, the one `pbefore` puts
/// first. Only it may start the project's next task.
pub fn projectFirst(ops: []const Op, project: []const u8) ?u64 {
    var best: ?Op = null;
    for (ops) |o| {
        if (!waits(o) or !std.mem.eql(u8, o.project, project)) continue;
        if (best == null or pbefore(o, best.?)) best = o;
    }
    return if (best) |b| b.ticket else null;
}

/// The first in line among `cand` (runs that wait): of the projects' first waiters, the one
/// `lineBefore` puts first, the projects' loads read from `ops`.
fn firstOf(m: std.StringArrayHashMapUnmanaged(Proj), cand: []const Op, t: u32) ?usize {
    var best: ?usize = null;
    for (cand, 0..) |o, i| {
        if (projectFirst(cand, o.project) != o.ticket) continue;
        if (best == null or lineBefore(m, t, o, cand[best.?])) best = i;
    }
    return best;
}

/// The first in the line: of the projects' first waiters, the one `lineBefore` puts first. Every
/// start is its: a run starts a task only when it is first here. Null when nothing waits.
pub fn lineFirst(a: std.mem.Allocator, ops: []const Op, t: u32) ?u64 {
    const i = firstOf(projects(a, ops), ops, t) orelse return null;
    return ops[i].ticket;
}

/// The runs waiting, as tickets in the order the line serves them if nothing else changes: the
/// first in line, then the first in line of the rest, and so on.
pub fn lineOrder(a: std.mem.Allocator, ops: []const Op, t: u32) []const u64 {
    const m = projects(a, ops);
    var rest: std.ArrayList(Op) = .empty;
    for (ops) |o| if (waits(o)) rest.append(a, o) catch {};
    var out: std.ArrayList(u64) = .empty;
    while (firstOf(m, rest.items, t)) |i| {
        out.append(a, rest.items[i].ticket) catch {};
        _ = rest.orderedRemove(i);
    }
    return out.items;
}

/// Whether run `me` may take a token and start (or continue) one more task now. The caller has
/// checked the gates and its -c (`waiting` > 0). Every free token goes to the first in line
/// (`lineFirst`), so no two runs race for one.
pub fn mayStart(a: std.mem.Allocator, ops: []const Op, me: u64, cx: Cx) Wait {
    const o = for (ops) |o| {
        if (o.ticket == me) break o;
    } else return .idle;
    if (!waits(o)) return .idle;
    if (freeTokens(ops, cx.n, cx.held_back, cx.now_ms) == 0) return .full;
    if (projectFirst(ops, o.project) != me) return .project;
    if (lineFirst(a, ops, cx.n) != me) return .behind;
    return .go;
}

/// The CPUs work outside cpuq keeps busy, from the sample: on Linux the CPUs drains don't
/// isolate less the tasks that run there; on macOS the whole machine less every task. 0 with no
/// sample yet.
fn outsideBusy(a: std.mem.Allocator, ops: []const Op, sample: Sample, now_ms: i64) f64 {
    if (sample.cpus.len != 0) {
        const iso = isolated(a, ops, now_ms);
        var machine: f64 = 0;
        for (sample.cpus) |c| if (std.mem.findScalar(u32, iso, c.cpu) == null) {
            machine += c.frac;
        };
        return @max(0, machine - (sample.tasks - sample.drains));
    }
    const machine = sample.machine orelse return 0;
    return @max(0, machine - sample.tasks);
}

/// Tokens held back for work outside cpuq (the outside-load gate, `outside_check`): the whole
/// CPUs it keeps busy beyond those cpuq leaves to it (`ncpu` − `n`: the reserve and any CPU
/// outside the pool).
pub fn heldBack(a: std.mem.Allocator, ops: []const Op, s: ?Sample, outside_check: bool, ncpu: u32, n: u32, now_ms: i64) u32 {
    if (!outside_check) return 0;
    const sample = s orelse return 0;
    const spill = outsideBusy(a, ops, sample, now_ms) - @as(f64, @floatFromInt(ncpu -| n));
    return if (spill >= 1) @intFromFloat(@floor(spill)) else 0;
}

/// The machine's busy CPUs, for status: the running tasks' busy CPUs from the sample (tasks
/// that ended since count no more; tasks cpuq stopped use nothing), and the work outside cpuq.
pub fn busyNow(a: std.mem.Allocator, ops: []const Op, s: ?Sample, now_ms: i64) f64 {
    const sample = s orelse return 0;
    var tasks: f64 = 0;
    for (ops) |o| if (o.counts()) for (o.tasks_now) |t| {
        if (t.paused) continue;
        if (sample.find(t.pid, t.start)) |b| tasks += b.busy;
    };
    return tasks + outsideBusy(a, ops, sample, now_ms);
}

// --- Tests ----------------------------------------------------------------------------------

test "an op record round trip" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const now = [_]TaskNow{.{ .task = 17, .attempt = 2, .pid = 4242, .start = 99, .since = 1700000000, .fresh = 12345, .paused = true, .cpu = 5 }};
    const r: Op = .{ .tasks_now = &now, .pid = 7, .project = "rig", .label = "rig:test", .weight = 2, .waiting = 3, .cpus = &.{ 4, 9 }, .pin = &.{4}, .npool = 2, .noise = 0.25, .noisy_top = "dd (77)", .dstart = 77, .arrived = 66, .limit = 8, .tasks = 100, .done = 5, .single = true, .cmd = "a\tb\nc" };
    try r.format(&w);
    const p = Op.parse(arena.allocator(), w.buffered());
    try std.testing.expectEqualStrings("rig", p.project);
    try std.testing.expectEqualSlices(u32, &.{ 4, 9 }, p.cpus);
    try std.testing.expectEqualSlices(u32, &.{4}, p.pin);
    try std.testing.expectEqual(2, p.npool);
    try std.testing.expectEqual(0.25, p.noise);
    try std.testing.expectEqualStrings("dd (77)", p.noisy_top);
    try std.testing.expectEqual(77, p.dstart);
    try std.testing.expectEqual(66, p.arrived);
    try std.testing.expectEqual(3, p.waiting);
    try std.testing.expect(p.single);
    try std.testing.expectEqualStrings("a b c", p.cmd);
    try std.testing.expectEqual(1, p.tasks_now.len);
    try std.testing.expectEqual(17, p.tasks_now[0].task);
    try std.testing.expectEqual(4242, p.tasks_now[0].pid);
    try std.testing.expectEqual(99, p.tasks_now[0].start);
    try std.testing.expectEqual(12345, p.tasks_now[0].fresh);
    try std.testing.expect(p.tasks_now[0].paused);
    try std.testing.expectEqual(5, p.tasks_now[0].cpu);
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

/// Tasks running on `cpus`, one each (pids from 100), for tests.
fn on(a: std.mem.Allocator, cpus: []const u32) []TaskNow {
    const out = a.alloc(TaskNow, cpus.len) catch unreachable;
    for (out, cpus, 0..) |*t, cpu, i| t.* = .{ .task = @intCast(i + 1), .pid = @intCast(100 + cpu), .start = 1, .since = 1, .cpu = cpu };
    return out;
}

test "tokens: N is the pool less the reserve, at least one, the reserve its last CPUs" {
    const pool = [_]u32{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, tokens(&pool, 2));
    try std.testing.expectEqual(10, tokens(&pool, 0).len);
    try std.testing.expectEqualSlices(u32, &.{0}, tokens(&pool, 10));
    try std.testing.expectEqualSlices(u32, &.{0}, tokens(&pool, 99));
}

test "tokens: at most N run, and a freed token goes to the first in line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // N = 2, both held by rig: trig waits however far under its share.
    var ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 2, .waiting = 6, .tasks_now = on(a, &.{ 0, 1 }) },
        .{ .ticket = 2, .project = "trig", .waiting = 2 },
    };
    const cx: Cx = .{ .n = 2, .now_ms = 100_000 };
    try std.testing.expectEqual(2, heldCount(&ops, cx.now_ms));
    try std.testing.expectEqual(0, freeTokens(&ops, 2, 0, cx.now_ms));
    try std.testing.expectEqual(Wait.full, mayStart(a, &ops, 2, cx));
    try std.testing.expectEqual(Wait.full, mayStart(a, &ops, 1, cx));
    try std.testing.expectEqual(null, freeCpu(a, &.{ 0, 1 }, &ops, cx.now_ms));
    // rig's task on CPU 0 ends: trig, under its share, takes that token; rig waits behind it.
    ops[0].running = 1;
    ops[0].tasks_now = on(a, &.{1});
    try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 2, cx));
    try std.testing.expectEqual(Wait.behind, mayStart(a, &ops, 1, cx));
    try std.testing.expectEqual(0, freeCpu(a, &.{ 0, 1 }, &ops, cx.now_ms).?);
    // A task cpuq has stopped (after a Ctrl-Z) holds no token.
    var stopped = ops;
    const t = on(a, &.{ 0, 1 });
    t[0].paused = true;
    stopped[0].tasks_now = t;
    try std.testing.expectEqual(1, heldCount(&stopped, cx.now_ms));
    try std.testing.expectEqual(0, freeCpu(a, &.{ 0, 1 }, &stopped, cx.now_ms).?);
    // Over their shares alike, the project running fewer for its weight goes first.
    const over = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 3, .waiting = 5 },
        .{ .ticket = 2, .project = "trig", .running = 2, .waiting = 5 },
    };
    try std.testing.expectEqual(2, lineFirst(a, &over, 4).?);
    try std.testing.expectEqual(Wait.behind, mayStart(a, &over, 1, .{ .n = 8 }));
    // An urgent run's first task goes ahead of other projects not under their share.
    var urgent = over;
    urgent[0].urgent = true;
    try std.testing.expectEqual(Wait.go, mayStart(a, &urgent, 1, .{ .n = 8 }));
}

test "tokens: held back while work outside cpuq keeps more than the CPUs it leaves busy" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ops = [_]Op{.{ .ticket = 1, .project = "rig", .running = 5, .waiting = 5, .tasks_now = on(a, &.{ 0, 1, 2, 3, 4 }) }};
    // 10 CPUs, N = 8: work outside keeps 7 − 1.5 = 5.5 busy, 2 left to it: 3 tokens held back.
    const s: Sample = .{ .ms = 1, .machine = 7.0, .tasks = 1.5 };
    try std.testing.expectEqual(3, heldBack(a, &ops, s, true, 10, 8, 0));
    try std.testing.expectEqual(0, heldBack(a, &ops, s, false, 10, 8, 0));
    try std.testing.expectEqual(0, heldBack(a, &ops, null, true, 10, 8, 0));
    try std.testing.expectEqual(0, freeTokens(&ops, 8, 3, 0));
    try std.testing.expectEqual(Wait.full, mayStart(a, &ops, 1, .{ .n = 8, .held_back = 3 }));
    try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 1, .{ .n = 8 }));
    // Under a whole CPU over: nothing held back.
    const s2: Sample = .{ .ms = 1, .machine = 4.4, .tasks = 1.5 };
    try std.testing.expectEqual(0, heldBack(a, &ops, s2, true, 10, 8, 0));
    // busy for status: the tasks' and the outside's.
    const per = [_]TaskBusy{ .{ .pid = 100, .start = 1, .cum = 0, .busy = 1.0 }, .{ .pid = 101, .start = 1, .cum = 0, .busy = 0.5 } };
    const s3: Sample = .{ .ms = 1, .machine = 7.0, .tasks = 1.5, .per = &per };
    try std.testing.expectApproxEqAbs(7.0, busyNow(a, &ops, s3, 0), 1e-9);
}

test "tokens: a driver that computes counts against its project's share" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // N = 4: rig's driver keeps 2.5 CPUs busy itself, so rig is over its share of 2 with no task
    // running; trig, under its share, takes the next token. The driver holds none.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .driver = true, .dbusy = 2.5 },
        .{ .ticket = 2, .project = "rig", .waiting = 4 },
        .{ .ticket = 3, .project = "trig", .waiting = 4 },
    };
    const cx: Cx = .{ .n = 4, .now_ms = 100_000 };
    try std.testing.expectEqual(Wait.behind, mayStart(a, &ops, 2, cx));
    try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 3, cx));
    try std.testing.expectApproxEqAbs(2.0, fairShare(a, &ops, "rig", 4), 1e-9);
    // A driver under 0.5 CPUs is a runner that only waits: it counts for nothing.
    var idle = ops;
    idle[0].dbusy = 0.2;
    try std.testing.expectEqual(Wait.go, mayStart(a, &idle, 2, cx));
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
    const cx: Cx = .{ .n = 4, .now_ms = 100_000 };
    try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 3, cx));
    try std.testing.expectEqual(Wait.project, mayStart(a, &ops, 1, cx));
    try std.testing.expectEqual(3, projectFirst(&ops, "rig").?);
    // Running the same, the older ticket; an urgent run's first task before either.
    var even = ops;
    even[2].running = 1;
    try std.testing.expectEqual(1, projectFirst(&even, "rig").?);
    even[2].urgent = true;
    try std.testing.expectEqual(3, projectFirst(&even, "rig").?);
    // The long run has just ended its task, running none as the newer run does: the older turn
    // goes first, its last start against the newer run's arrival.
    var tie = ops;
    tie[0].running = 0;
    tie[0].last = 90_000;
    tie[2].arrived = 80_000;
    try std.testing.expectEqual(3, projectFirst(&tie, "rig").?);
    tie[2].arrived = 95_000;
    try std.testing.expectEqual(1, projectFirst(&tie, "rig").?);
    // Once the newer run has started a task, its last start is its turn.
    tie[2].last = 85_000;
    try std.testing.expectEqual(3, projectFirst(&tie, "rig").?);
    // In the line too: over their shares, the newer rig run (running 0) is first.
    const over = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 3, .waiting = 20 },
        .{ .ticket = 2, .project = "trig", .running = 3, .waiting = 5 },
        .{ .ticket = 3, .project = "rig", .waiting = 1 },
    };
    try std.testing.expectEqual(3, lineFirst(a, &over, 4).?);
}

test "admission: a stream of new runs of a project never passes a run that started before" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pool of 1, one project. Run 1 last started a task at 50 s and waits for its next. Each new
    // run arrives while the last runs; when that one ends, run 1 is first, not the newcomer.
    const cx: Cx = .{ .n = 1, .now_ms = 200_000 };
    var arrived: i64 = 60_000;
    while (arrived < 160_000) : (arrived += 10_000) {
        const ops = [_]Op{
            .{ .ticket = 1, .project = "rig", .last = 50_000, .arrived = 10_000, .waiting = 5 },
            .{ .ticket = 2 + @as(u64, @intCast(arrived)), .project = "rig", .arrived = arrived, .waiting = 1 },
        };
        try std.testing.expectEqual(1, projectFirst(&ops, "rig").?);
        try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 1, cx));
        try std.testing.expectEqual(Wait.project, mayStart(a, &ops, ops[1].ticket, cx));
    }
}

test "tokens: a freed token goes to the first in line, not to whoever looks first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // N = 4: projects b, c, d hold a token each, so one is free. Two runs under their share want
    // it: r (project e, waiting since ticket 1) and project f's new run (ticket 9). The older is
    // first in line and takes it; the other may not.
    var ops = [_]Op{
        .{ .ticket = 1, .project = "e", .arrived = 1_000, .waiting = 1 },
        .{ .ticket = 2, .project = "b", .running = 1, .last = 2_000, .tasks_now = on(a, &.{0}) },
        .{ .ticket = 3, .project = "c", .running = 1, .last = 3_000, .tasks_now = on(a, &.{1}) },
        .{ .ticket = 4, .project = "d", .running = 1, .last = 4_000, .tasks_now = on(a, &.{2}) },
        .{ .ticket = 9, .project = "f", .arrived = 9_000, .waiting = 1 },
    };
    const cx: Cx = .{ .n = 4, .now_ms = 10_000 };
    try std.testing.expectEqual(Wait.go, mayStart(a, &ops, 1, cx));
    try std.testing.expectEqual(Wait.behind, mayStart(a, &ops, 9, cx));
    try std.testing.expectEqual(3, freeCpu(a, &.{ 0, 1, 2, 3 }, &ops, cx.now_ms).?);
    // r has taken it: every token is held, and the other waits for the next.
    ops[0].running = 1;
    ops[0].waiting = 0;
    ops[0].tasks_now = on(a, &.{3});
    try std.testing.expectEqual(Wait.full, mayStart(a, &ops, 9, cx));
}

test "admission: the line's order, as status shows it" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Pool of 4: rig runs 3 (over its share of 2), trig 1 (under). trig's run goes first; then
    // rig's runs, its newer run (running none) before the long run.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .running = 3, .waiting = 5, .last = 5_000 },
        .{ .ticket = 2, .project = "trig", .running = 1, .waiting = 2, .last = 6_000 },
        .{ .ticket = 3, .project = "rig", .waiting = 1, .arrived = 7_000 },
        .{ .ticket = 4, .project = "q", .drain = true, .waiting = 1 },
    };
    try std.testing.expectEqualSlices(u64, &.{ 2, 3, 1 }, lineOrder(a, &ops, 4));
}

test "tokens: a run with nothing to start, or stopped, is idle" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const idle = [_]Op{ .{ .ticket = 1, .project = "rig" }, .{ .ticket = 2, .project = "q", .waiting = 1, .stopped = true } };
    try std.testing.expectEqual(Wait.idle, mayStart(a, &idle, 1, .{ .n = 2 }));
    try std.testing.expectEqual(Wait.idle, mayStart(a, &idle, 2, .{ .n = 2 }));
}

test "drains: tokens held, the drain_max bound, free tokens, and the turn" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now: i64 = 1_000_000;
    // A drain of 2 isolating CPUs 6 and 7 of 8 holds their 2 tokens.
    const d1: Op = .{ .ticket = 1, .drain = true, .limit = 2, .cpus = &.{ 6, 7 }, .npool = 2, .dstart = now - 1000, .tlimit = 600, .running = 1, .tasks_now = on(a, &.{6}) };
    try std.testing.expectEqual(2, heldCount(&.{d1}, now));
    try std.testing.expectEqualSlices(u32, &.{ 6, 7 }, isolated(a, &.{d1}, now));
    try std.testing.expectEqual(0, freeCpu(a, &.{ 0, 6, 7 }, &.{d1}, now).?);
    // Past its limit and grace, it holds nothing.
    try std.testing.expectEqual(0, heldCount(&.{d1}, now + 700_000));
    // A waiting drain holds nothing.
    const d2: Op = .{ .ticket = 2, .drain = true, .limit = 3, .waiting = 1 };
    try std.testing.expectEqual(0, heldCount(&.{d2}, now));
    // Needing 3 would pass drain_max (4): it waits; needing 2 it goes, with 2 tokens free; with
    // 1 free, its turn has come but it holds none until enough are.
    try std.testing.expectEqual(DrainWait.half_pool, drainMayStart(&.{ d1, d2 }, 2, 4, now, 3, 6));
    try std.testing.expectEqual(DrainWait.go, drainMayStart(&.{ d1, d2 }, 2, 4, now, 2, 2));
    try std.testing.expectEqual(DrainWait.full, drainMayStart(&.{ d1, d2 }, 2, 4, now, 2, 1));
    // A run older than the drain waiting with no task running goes first; one running tasks
    // already, or a newer one, doesn't hold it.
    const old: Op = .{ .ticket = 1, .project = "rig", .waiting = 1 };
    const young: Op = .{ .ticket = 3, .project = "rig", .waiting = 1 };
    try std.testing.expectEqual(DrainWait.older_waiter, drainMayStart(&.{ old, d2 }, 2, 4, now, 1, 8));
    try std.testing.expectEqual(DrainWait.go, drainMayStart(&.{ d2, young }, 2, 4, now, 1, 8));
    var busy_old = old;
    busy_old.running = 3;
    try std.testing.expectEqual(DrainWait.go, drainMayStart(&.{ busy_old, d2 }, 2, 4, now, 1, 8));
    // An older drain waiting goes first.
    const w1: Op = .{ .ticket = 1, .drain = true, .limit = 1, .waiting = 1 };
    try std.testing.expectEqual(DrainWait.older_drain, drainMayStart(&.{ w1, d2 }, 2, 4, now, 1, 8));
    // A stopped drain holds nothing.
    var stopped = d1;
    stopped.stopped = true;
    try std.testing.expectEqual(0, heldCount(&.{stopped}, now));
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
