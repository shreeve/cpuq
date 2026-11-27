//! The pool: this machine's CPUs as token files, the operations that hold them, and the line
//! that decides which operation gets the next one. Everything lives under a versioned folder in
//! the state directory, so a cpuq of another version never reads these files as its own:
//!
//!   v2/lock          the pool's lock: every scan, take, promise and release happens under it
//!   v2/seq           the last ticket number handed out
//!   v2/ops/C-TICKET  one per running operation, exclusively locked by its cpuq for its whole
//!                    life (C: 0 urgent, 1 normal). Its text says what it holds and wants. Its
//!                    ticket is renewed (the file renamed) each time it gives a CPU up, so it
//!                    takes its turn again behind the others
//!   v2/wake/TICKET   the operation's FIFO: whoever promises it a CPU writes a byte there
//!   v2/cpus/N        one per pool CPU, named by the CPU's number. An exclusive lock is a held
//!                    CPU. Only an operation's own cpuq holds it (close-on-exec), never its
//!                    tasks, so no leftover process can keep a CPU. Its text names the task
//!                    groups running on it, so whoever takes it next can end a dead
//!                    operation's leftovers first
//!   v2/grants/N      a promise of CPU N to one waiting operation (its ticket), valid while that
//!                    operation's file is still locked
//!   v2/drain         present while `cpuq drain` waits for or holds the machine
//!   v2/ticks         the last sample of the machine's CPU ticks, for the outside-load gate
//!
//! A file whose lock can be taken has no live holder: whoever finds it so removes it, under the
//! pool's lock. Nothing depends on a pid being alive except killing a dead operation's leftover
//! processes, and that checks each group leader's start time first.
const std = @import("std");
const Io = std.Io;
const sys = @import("sys.zig");

pub const Pool = struct {
    io: Io,
    path: []const u8,
    dir: Io.Dir,
    cpus: Io.Dir,
    ops: Io.Dir,
    wake: Io.Dir,
    grants: Io.Dir,
    lock_file: Io.File,

    /// Opens (making it if need be) the pool under `state_dir`.
    pub fn open(io: Io, a: std.mem.Allocator, state_dir: []const u8) !Pool {
        const path = try std.fmt.allocPrint(a, "{s}/v2", .{state_dir});
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, path);
        const dir = try cwd.openDir(io, path, .{ .iterate = true });
        return .{
            .io = io,
            .path = path,
            .dir = dir,
            .cpus = try subdir(io, dir, "cpus"),
            .ops = try subdir(io, dir, "ops"),
            .wake = try subdir(io, dir, "wake"),
            .grants = try subdir(io, dir, "grants"),
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

    /// The next ticket number, above `seq` and every operation's ticket, so a lost `seq` never
    /// hands out a live number. Under the lock.
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

    /// Enters an operation: its file, written and locked under a temporary name and renamed
    /// into place (so no scan sees it unlocked), and its FIFO. Under the lock. The returned file
    /// stays locked for the operation's life; its ticket is set in `r`.
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

    /// Opens the operation's FIFO to read, without blocking: it is open before the operation
    /// first looks for a CPU, so a promise made after that look always finds it open.
    pub fn openWake(p: *Pool, ticket: u64) !std.c.fd_t {
        var buf: [1024]u8 = undefined;
        const fifo = try std.fmt.bufPrintSentinel(&buf, "{s}/wake/{d}", .{ p.path, ticket }, 0);
        // Read and write, so the FIFO never reads as closed (EOF) while no writer has it.
        const fd = std.c.open(fifo, .{ .ACCMODE = .RDWR, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) return error.FifoFailed;
        return fd;
    }

    /// Wakes a waiting operation: one byte to its FIFO, never blocking. A full FIFO already
    /// holds a wake.
    pub fn wakeOp(p: *Pool, ticket: u64) void {
        var buf: [1024]u8 = undefined;
        const fifo = std.fmt.bufPrintSentinel(&buf, "{s}/wake/{d}", .{ p.path, ticket }, 0) catch return;
        const fd = std.c.open(fifo, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .CLOEXEC = true });
        if (fd < 0) return;
        defer _ = std.c.close(fd);
        _ = std.c.write(fd, "w", 1);
    }

    /// Gives the operation a new ticket, behind every other: it renames its file and FIFO. The
    /// open file keeps its lock. Under the lock.
    pub fn renew(p: *Pool, f: Io.File, r: *Op) !void {
        var old_buf: [48]u8 = undefined;
        const old = opName(&old_buf, r.*);
        var old_fifo_buf: [64]u8 = undefined;
        const old_fifo = try std.fmt.bufPrint(&old_fifo_buf, "{d}", .{r.ticket});
        r.ticket = try p.nextTicket();
        var new_buf: [48]u8 = undefined;
        try p.ops.rename(old, p.ops, opName(&new_buf, r.*), p.io);
        var new_fifo_buf: [64]u8 = undefined;
        try p.wake.rename(old_fifo, p.wake, try std.fmt.bufPrint(&new_fifo_buf, "{d}", .{r.ticket}), p.io);
        try p.write(f, r.*);
    }

    /// Rewrites an operation's record in place. Readers read only under the lock, as the
    /// writer writes, so none sees it half written.
    pub fn write(p: *Pool, f: Io.File, r: Op) !void {
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        r.format(&w) catch return error.RecordTooLong;
        const text = w.buffered();
        if (std.c.pwrite(f.handle, text.ptr, text.len, 0) != @as(isize, @intCast(text.len))) return error.WriteFailed;
        try f.setLength(p.io, text.len);
    }

    /// Leaves the pool: removes the operation's file and FIFO, then closes the file (its lock
    /// goes with it). Under the lock.
    pub fn leave(p: *Pool, f: Io.File, r: Op) void {
        var name_buf: [48]u8 = undefined;
        p.ops.deleteFile(p.io, opName(&name_buf, r)) catch {};
        var fifo_buf: [32]u8 = undefined;
        p.wake.deleteFile(p.io, std.fmt.bufPrint(&fifo_buf, "{d}", .{r.ticket}) catch "") catch {};
        f.close(p.io);
    }

    /// Every live operation, in ticket order. A dead one's files are removed. Under the lock.
    pub fn scan(p: *Pool, a: std.mem.Allocator) []Op {
        var list: std.ArrayList(Op) = .empty;
        var it = p.ops.iterate();
        while (it.next(p.io) catch null) |e| {
            if (e.name[0] == '.') continue;
            const ticket = ticketOf(e.name) orelse continue;
            const f = p.ops.openFile(p.io, e.name, .{}) catch continue;
            defer f.close(p.io);
            if (f.tryLock(p.io, .shared) catch false) {
                // Nobody holds it: its operation has ended, however it ended.
                p.ops.deleteFile(p.io, e.name) catch {};
                var fifo_buf: [32]u8 = undefined;
                p.wake.deleteFile(p.io, std.fmt.bufPrint(&fifo_buf, "{d}", .{ticket}) catch "") catch {};
                f.unlock(p.io);
                continue;
            }
            var rd = f.reader(p.io, &.{});
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

    /// The promises in force: CPU to ticket. A promise to an operation no longer live, or of
    /// a CPU no longer in the pool, is dropped. Under the lock.
    pub fn promises(p: *Pool, a: std.mem.Allocator, live: []const Op, pool_cpus: []const u32) []Promise {
        var list: std.ArrayList(Promise) = .empty;
        var it = p.grants.iterate();
        while (it.next(p.io) catch null) |e| {
            if (e.name[0] == '.') continue;
            const cpu = std.fmt.parseInt(u32, e.name, 10) catch continue;
            var buf: [32]u8 = undefined;
            const text = p.grants.readFile(p.io, e.name, &buf) catch continue;
            const ticket = std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0;
            const valid = ticket != 0 and std.mem.findScalar(u32, pool_cpus, cpu) != null and for (live) |o| {
                if (o.ticket == ticket) break true;
            } else false;
            if (!valid) {
                p.grants.deleteFile(p.io, e.name) catch {};
                continue;
            }
            list.append(a, .{ .cpu = cpu, .ticket = ticket }) catch break;
        }
        return list.items;
    }

    /// Promises CPU `cpu` to the operation `ticket`, by rename, so the promise is never seen
    /// half written. Under the lock.
    pub fn promise(p: *Pool, cpu: u32, ticket: u64) void {
        var tmp_buf: [32]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, ".g{d}", .{cpu}) catch return;
        var text_buf: [32]u8 = undefined;
        p.grants.writeFile(p.io, .{ .sub_path = tmp, .data = std.fmt.bufPrint(&text_buf, "{d}\n", .{ticket}) catch return }) catch return;
        var name_buf: [16]u8 = undefined;
        p.grants.rename(tmp, p.grants, std.fmt.bufPrint(&name_buf, "{d}", .{cpu}) catch return, p.io) catch {};
    }

    pub fn dropPromise(p: *Pool, cpu: u32) void {
        var name_buf: [16]u8 = undefined;
        p.grants.deleteFile(p.io, std.fmt.bufPrint(&name_buf, "{d}", .{cpu}) catch return) catch {};
    }

    /// Whether CPU `cpu`'s token is free: nobody holds its lock. Under the lock, so a probe never
    /// makes a free CPU look held to anyone deciding.
    pub fn isFree(p: *Pool, cpu: u32) bool {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}", .{cpu}) catch return false;
        const f = createShared(p.io, p.cpus, name) catch return false;
        defer f.close(p.io);
        if (f.tryLock(p.io, .exclusive) catch false) {
            f.unlock(p.io);
            return true;
        }
        return false;
    }

    /// Takes CPU `cpu`: locks its token, first ending what a dead holder left running on it.
    /// The descriptor is close-on-exec, so only this process holds the CPU. Null when someone
    /// holds it. Under the lock.
    pub fn take(p: *Pool, a: std.mem.Allocator, cpu: u32) ?Io.File {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}", .{cpu}) catch return null;
        const f = createShared(p.io, p.cpus, name) catch return null;
        if (!(f.tryLock(p.io, .exclusive) catch false)) {
            f.close(p.io);
            return null;
        }
        var rd = f.reader(p.io, &.{});
        const text = rd.interface.allocRemaining(a, .limited(64 << 10)) catch "";
        killLeftovers(text);
        f.setLength(p.io, 0) catch {};
        return f;
    }

    /// Notes on a held CPU's token the task groups running on it, as `PGID START` lines (the
    /// group leader's start time), so a next holder can end them if this operation dies.
    pub fn noteGroups(f: Io.File, groups: []const Group) void {
        var buf: [4096]u8 = undefined;
        var w: Io.Writer = .fixed(&buf);
        for (groups) |g| w.print("{d} {d}{s}\n", .{ g.pgid, g.start, if (g.alone) " p" else "" }) catch break;
        const text = w.buffered();
        _ = std.c.pwrite(f.handle, text.ptr, text.len, 0);
        _ = std.c.ftruncate(f.handle, @intCast(text.len));
    }

    /// Gives a CPU back: clears its notes, then unlocks and closes it. Under the lock.
    pub fn release(p: *Pool, f: Io.File) void {
        f.setLength(p.io, 0) catch {};
        f.unlock(p.io);
        f.close(p.io);
    }

    /// The machine's busy CPUs over the last second or so, from the kernel's CPU ticks: the
    /// sample in `ticks` is renewed once at least a second old, so every operation shares one
    /// measure. Null until two samples exist. Under the lock.
    pub fn machineBusy(p: *Pool, cpus: u32) ?f64 {
        const now = sys.monoMs();
        const t = sys.cpuTicks(p.io) orelse return null;
        var buf: [128]u8 = undefined;
        var last_busy: ?f64 = null;
        var prev: ?struct { busy: u64, total: u64, ms: i64 } = null;
        if (p.dir.readFile(p.io, "ticks", &buf)) |text| {
            var f = std.mem.tokenizeScalar(u8, std.mem.trim(u8, text, " \n"), ' ');
            const b = std.fmt.parseInt(u64, f.next() orelse "", 10) catch 0;
            const tot = std.fmt.parseInt(u64, f.next() orelse "", 10) catch 0;
            const ms = std.fmt.parseInt(i64, f.next() orelse "", 10) catch 0;
            if (f.next()) |lb| last_busy = std.fmt.parseFloat(f64, lb) catch null;
            if (tot != 0) prev = .{ .busy = b, .total = tot, .ms = ms };
        } else |_| {}
        if (prev) |q| if (now - q.ms < 1000 and now >= q.ms) return last_busy;
        var busy = last_busy;
        if (prev) |q| if (t.total > q.total and t.busy >= q.busy) {
            busy = @as(f64, @floatFromInt(t.busy - q.busy)) / @as(f64, @floatFromInt(t.total - q.total)) * @as(f64, @floatFromInt(cpus));
        };
        var out: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&out, "{d} {d} {d} {d:.2}\n", .{ t.busy, t.total, now, busy orelse 0 }) catch return busy;
        p.dir.writeFile(p.io, .{ .sub_path = "ticks.new", .data = text }) catch return busy;
        p.dir.rename("ticks.new", p.dir, "ticks", p.io) catch {};
        return if (prev != null) busy else null;
    }

    /// Marks that `cpuq drain` waits for the machine: a `drain` file each drain holds a shared
    /// lock on for its life, so any number of drains hold it at once and none waits for
    /// another here, under the pool's lock. Under the lock.
    pub fn markDrain(p: *Pool) !Io.File {
        return p.dir.createFile(p.io, "drain", .{ .lock = .shared, .truncate = false });
    }

    /// Whether `cpuq drain` is waiting for or holding the machine: some drain holds the `drain`
    /// file's lock.
    pub fn draining(p: *Pool) bool {
        const f = p.dir.openFile(p.io, "drain", .{}) catch return false;
        defer f.close(p.io);
        if (f.tryLock(p.io, .exclusive) catch false) {
            f.unlock(p.io);
            return false;
        }
        return true;
    }
};

/// A task group running on a CPU: its process group and its leader's start time.
/// A task running on a CPU: its process group (or, `alone`, its process: a single task shares
/// cpuq's group) and the leader's start time.
pub const Group = struct { pgid: i32, start: u64, alone: bool = false };

/// Ends the task groups a dead holder noted on a CPU's token: each whose leader still runs with
/// the same start time (a pgid alone may name another group by now) gets SIGKILL, and is waited
/// for.
fn killLeftovers(text: []const u8) void {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var f = std.mem.tokenizeScalar(u8, line, ' ');
        const pgid = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue;
        const start = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue;
        if (pgid <= 1) continue;
        if (sys.procStart(pgid) != start) continue;
        const alone = if (f.next()) |m| std.mem.eql(u8, m, "p") else false;
        _ = std.c.kill(if (alone) pgid else -pgid, .KILL);
        // A kill lands a moment later: wait for the leader to be gone (at most 200 ms), so the
        // CPU's next task never shares it with what is left.
        var waited: u32 = 0;
        while (waited < 100 and sys.procStart(pgid) == start) : (waited += 1) {
            var ts: std.c.timespec = .{ .sec = 0, .nsec = 2 * std.time.ns_per_ms };
            _ = std.c.nanosleep(&ts, null);
        }
    }
}

extern "c" fn mkfifo(path: [*:0]const u8, mode: std.c.mode_t) c_int;

pub const Promise = struct { cpu: u32, ticket: u64 };

/// A task running now: its number, its try, the CPU it runs on, its pid, and when it started
/// (Unix seconds).
pub const TaskNow = struct { task: u32, attempt: u32, cpu: u32, pid: i32, since: i64 };

fn ticketOf(name: []const u8) ?u64 {
    const dash = std.mem.findScalar(u8, name, '-') orelse return null;
    return std.fmt.parseInt(u64, name[dash + 1 ..], 10) catch null;
}

fn opName(buf: []u8, r: Op) []const u8 {
    return std.fmt.bufPrint(buf, "{d}-{d}", .{ @intFromBool(!r.urgent), r.ticket }) catch "";
}

/// An operation, as its file records it.
pub const Op = struct {
    ticket: u64 = 0,
    /// "Rebuild first": its first CPU goes ahead of the line.
    urgent: bool = false,
    /// It has held a CPU: urgent no more, even holding none again.
    served: bool = false,
    /// `cpuq drain`: waits for every CPU, and takes the machine.
    drain: bool = false,
    pid: i32 = 0,
    project: []const u8 = "",
    label: []const u8 = "",
    weight: u32 = 1,
    /// CPUs it could use now beyond those it holds (promises to it count against this when
    /// CPUs are handed out).
    want: u32 = 0,
    /// The CPUs it holds, by number.
    held: []const u32 = &.{},
    /// How many of those it is emptying to give up.
    draining: u32 = 0,
    /// Processes per CPU (-x), and the most CPUs it may hold (-c, worked out).
    overload: u32 = 1,
    limit: u32 = 1,
    tasks: u32 = 1,
    done: u32 = 0,
    failed: u32 = 0,
    running: u32 = 0,
    since: i64 = 0,
    /// Why it waits, for status ("gate: memory pressure"); empty when it isn't held back.
    why: []const u8 = "",
    /// Its tasks running now, for status: at most 256, the oldest first.
    tasks_now: []const TaskNow = &.{},
    cmd: []const u8 = "",

    pub fn format(r: Op, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("pid={d}\nurgent={d}\nserved={d}\ndrain={d}\nproject={s}\nlabel={s}\nweight={d}\nwant={d}\nheld=", .{
            r.pid, @intFromBool(r.urgent), @intFromBool(r.served), @intFromBool(r.drain), r.project, r.label, r.weight, r.want,
        });
        for (r.held, 0..) |cpu, i| try w.print("{s}{d}", .{ if (i == 0) "" else ",", cpu });
        try w.print("\ndraining={d}\noverload={d}\nlimit={d}\ntasks={d}\ndone={d}\nfailed={d}\nrunning={d}\nsince={d}\nwhy={s}\nnow=", .{
            r.draining, r.overload, r.limit, r.tasks, r.done, r.failed, r.running, r.since, r.why,
        });
        for (r.tasks_now[0..@min(r.tasks_now.len, 256)], 0..) |t, i| try w.print("{s}{d}:{d}:{d}:{d}:{d}", .{ if (i == 0) "" else ",", t.task, t.attempt, t.cpu, t.pid, t.since });
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
            if (eq(k, "project")) r.project = v;
            if (eq(k, "label")) r.label = v;
            if (eq(k, "weight")) r.weight = @max(1, n);
            if (eq(k, "want")) r.want = n;
            if (eq(k, "held")) r.held = parseList(a, v);
            if (eq(k, "draining")) r.draining = n;
            if (eq(k, "overload")) r.overload = @max(1, n);
            if (eq(k, "limit")) r.limit = n;
            if (eq(k, "tasks")) r.tasks = n;
            if (eq(k, "done")) r.done = n;
            if (eq(k, "failed")) r.failed = n;
            if (eq(k, "running")) r.running = n;
            if (eq(k, "since")) r.since = std.fmt.parseInt(i64, v, 10) catch 0;
            if (eq(k, "why")) r.why = v;
            if (eq(k, "now")) r.tasks_now = parseTasks(a, v);
            if (eq(k, "cmd")) r.cmd = v;
        }
        return r;
    }

    /// CPUs it keeps: held, less those it is giving up.
    pub fn keeps(r: Op) u32 {
        return @intCast(r.held.len -| r.draining);
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
            .cpu = std.fmt.parseInt(u32, f.next() orelse continue, 10) catch continue,
            .pid = std.fmt.parseInt(i32, f.next() orelse continue, 10) catch continue,
            .since = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue,
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

// --- The line: pure decisions over the operations' records ----------------------------------

/// One operation's standing in the line while CPUs are handed out.
const Standing = struct {
    op: *const Op,
    /// CPUs it keeps plus those promised to it so far.
    has: u32,
    /// CPUs it may still be promised.
    left: u32,
};

/// Whether `x` goes ahead of `y` for the next CPU: urgent first (only for an operation's first
/// CPU, so once it has held one it is urgent no more, and only while its project holds no
/// urgent CPU), then an operation holding nothing, then the project holding the fewest CPUs for
/// its weight, then the operation holding the fewest, then the older ticket.
fn ahead(projects: *const std.StringHashMapUnmanaged(Count), x: Standing, y: Standing) bool {
    const ux = urgentNow(projects, x);
    const uy = urgentNow(projects, y);
    if (ux != uy) return ux;
    // An operation holding nothing goes before every holder, so it can't starve behind a head
    // nobody may give to.
    if ((x.has == 0) != (y.has == 0)) return x.has == 0;
    const px = projects.get(x.op.project) orelse Count{};
    const py = projects.get(y.op.project) orelse Count{};
    // px.cpus / x.weight < py.cpus / y.weight, without division.
    const lx = @as(u64, px.cpus) * y.op.weight;
    const ly = @as(u64, py.cpus) * x.op.weight;
    if (lx != ly) return lx < ly;
    if (x.has != y.has) return x.has < y.has;
    return x.op.ticket < y.op.ticket;
}

fn urgentNow(projects: *const std.StringHashMapUnmanaged(Count), s: Standing) bool {
    if (!s.op.urgent or s.op.served or s.has != 0) return false;
    const c = projects.get(s.op.project) orelse return true;
    return c.urgent == 0;
}

const Count = struct { cpus: u32 = 0, urgent: u32 = 0 };

fn countProjects(a: std.mem.Allocator, ops: []const Op, given: []const Promise) std.StringHashMapUnmanaged(Count) {
    var m: std.StringHashMapUnmanaged(Count) = .empty;
    for (ops) |o| {
        const gop = m.getOrPut(a, o.project) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .{};
        var has = o.keeps();
        for (given) |g| if (g.ticket == o.ticket) {
            has += 1;
        };
        gop.value_ptr.cpus += has;
        if (o.urgent and has != 0) gop.value_ptr.urgent += 1;
    }
    return m;
}

/// Hands out `free` CPUs (in the pool's order) to the line, one at a time, re-ranking after
/// each: the CPUs already promised (`given`) count as held by their operation. Returns the new
/// promises. While a `cpuq drain` wants CPUs, every CPU goes to a drain alone: the one holding
/// or promised the most, then the older, so two drains never each hold part of the pool waiting
/// for the other's. A stopped one (which wants none) is passed over.
pub fn handOut(a: std.mem.Allocator, ops: []const Op, given: []const Promise, free: []const u32) []Promise {
    var out: std.ArrayList(Promise) = .empty;
    if (free.len == 0) return out.items;
    var all: std.ArrayList(Promise) = .empty;
    all.appendSlice(a, given) catch return out.items;
    const standings = a.alloc(Standing, ops.len) catch return out.items;
    var drains = false;
    for (ops, standings) |*o, *s| {
        var promised: u32 = 0;
        for (given) |g| if (g.ticket == o.ticket) {
            promised += 1;
        };
        s.* = .{ .op = o, .has = o.keeps() + promised, .left = o.want -| promised };
        if (o.drain and o.want > 0) drains = true;
    }
    for (free) |cpu| {
        var projects = countProjects(a, ops, all.items);
        var best: ?usize = null;
        if (drains) {
            var d: ?usize = null;
            for (standings, 0..) |s, i| {
                if (!s.op.drain or s.op.want == 0) continue;
                const ds = if (d) |j| standings[j] else null;
                if (ds == null or s.has > ds.?.has or (s.has == ds.?.has and s.op.ticket < ds.?.op.ticket)) d = i;
            }
            if (standings[d.?].left > 0) best = d;
        } else for (standings, 0..) |s, i| {
            if (s.left == 0) continue;
            if (best == null or ahead(&projects, s, standings[best.?])) best = i;
        }
        const b = best orelse break;
        const p: Promise = .{ .cpu = cpu, .ticket = standings[b].op.ticket };
        out.append(a, p) catch break;
        all.append(a, p) catch break;
        standings[b].has += 1;
        standings[b].left -= 1;
    }
    return out.items;
}

/// The first operation in the line still wanting a CPU once every promise is counted, if any.
pub fn firstWaiter(a: std.mem.Allocator, ops: []const Op, given: []const Promise) ?Standing {
    var projects = countProjects(a, ops, given);
    var best: ?Standing = null;
    for (ops) |*o| {
        var promised: u32 = 0;
        for (given) |g| if (g.ticket == o.ticket) {
            promised += 1;
        };
        const s: Standing = .{ .op = o, .has = o.keeps() + promised, .left = o.want -| promised };
        if (s.left == 0) continue;
        if (best == null or ahead(&projects, s, best.?)) best = s;
    }
    return best;
}

/// Whether waiter `wt` goes ahead of `gt` in the line once `gt` has given one CPU up (and
/// wants one again).
fn behindAfter(a: std.mem.Allocator, ops: []const Op, given: []const Promise, wt: u64, gt: u64) bool {
    const after = a.dupe(Op, ops) catch return false;
    var wi: ?usize = null;
    var gi: ?usize = null;
    for (after, 0..) |*o, i| {
        if (o.ticket == wt) wi = i;
        if (o.ticket == gt) {
            gi = i;
            o.draining += 1;
        }
    }
    const w = wi orelse return false;
    const g = gi orelse return false;
    // Giving a CPU up renews the giver's ticket (`renew`): it takes its turn behind everyone.
    var newest: u64 = 0;
    for (after) |o| newest = @max(newest, o.ticket);
    after[g].ticket = newest + 1;
    var projects = countProjects(a, after, given);
    const sw = standing(&after[w], given);
    var sg = standing(&after[g], given);
    sg.left = @max(sg.left, 1);
    return ahead(&projects, sw, sg);
}

fn standing(o: *const Op, given: []const Promise) Standing {
    var promised: u32 = 0;
    for (given) |p| if (p.ticket == o.ticket) {
        promised += 1;
    };
    return .{ .op = o, .has = o.keeps() + promised, .left = o.want -| promised };
}

/// Which operation should empty one of its CPUs for the first waiter, if any: drains are owed
/// to the first waiter alone, at most as many as it still wants, counted over every operation
/// (so twelve don't all drain for one). A giver qualifies when the waiter holds nothing, or when
/// after the move the waiter's project would still hold no more than the giver's for their
/// weights: (waiter's + 1) / its weight <= (giver's - 1) / the giver's. Of those, the one whose
/// project holds the most for its weight gives, then the one keeping the most, then the newest.
/// A CPU being emptied counts as given up already. While a `cpuq drain` waits, every operation
/// gives.
pub fn giver(a: std.mem.Allocator, ops: []const Op, given: []const Promise) ?u64 {
    const w = firstWaiter(a, ops, given) orelse return null;
    var owed: u32 = 0;
    for (ops) |o| owed += o.draining;
    if (owed >= w.left) return null;
    var projects = countProjects(a, ops, given);
    const wp = (projects.get(w.op.project) orelse Count{}).cpus;
    var best: ?*const Op = null;
    for (ops) |*g| {
        if (g.ticket == w.op.ticket or g.drain or g.keeps() == 0) continue;
        const gp = (projects.get(g.project) orelse Count{}).cpus;
        const fits = w.op.drain or w.has == 0 or
            (@as(u64, wp + 1) * g.weight <= @as(u64, gp -| 1) * w.op.weight and gp >= 1);
        if (!fits) continue;
        // Only if the waiter still goes ahead of the giver once the giver holds one fewer:
        // else the freed CPU would come straight back to the giver.
        if (!w.op.drain and !behindAfter(a, ops, given, w.op.ticket, g.ticket)) continue;
        if (best) |b| {
            const bp = (projects.get(b.project) orelse Count{}).cpus;
            const lg = @as(u64, gp) * b.weight;
            const lb = @as(u64, bp) * g.weight;
            if (lg < lb) continue;
            if (lg == lb) {
                if (g.keeps() < b.keeps()) continue;
                if (g.keeps() == b.keeps() and g.ticket < b.ticket) continue;
            }
        }
        best = g;
    }
    return if (best) |b| b.ticket else null;
}

test "the line: urgent only until served; a stopped drain is passed over" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // U (urgent, served) and B (another project) hold one CPU each; C, of U's project, holds
    // nothing. U gives: holding nothing again it is not urgent, so C still goes ahead of it.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "q", .held = &.{0}, .want = 9 },
        .{ .ticket = 2, .project = "p", .urgent = true, .served = true, .held = &.{1}, .want = 9 },
        .{ .ticket = 3, .project = "p", .want = 1 },
    };
    try std.testing.expectEqual(2, giver(a, &ops, &.{}).?);
    // Not yet served, an urgent op holding nothing still goes first.
    const fresh = [_]Op{ ops[0], .{ .ticket = 5, .project = "p", .urgent = true, .want = 1 } };
    try std.testing.expectEqual(5, handOut(a, &fresh, &.{}, &.{2})[0].ticket);
    // A stopped drain wants nothing: free CPUs go to the line, not to no one.
    const stopped = [_]Op{ .{ .ticket = 1, .project = "q", .want = 2 }, .{ .ticket = 2, .project = "x", .drain = true } };
    const got = handOut(a, &stopped, &.{}, &.{ 0, 1 });
    try std.testing.expectEqual(2, got.len);
    try std.testing.expectEqual(1, got[0].ticket);
}

test "the line: of two drains, the one holding the most takes the free CPUs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // B (older) holds nothing, C holds one: the free CPU goes to C, not to B.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "x", .drain = true, .urgent = true, .want = 2 },
        .{ .ticket = 2, .project = "x", .drain = true, .urgent = true, .held = &.{0}, .want = 1 },
    };
    try std.testing.expectEqual(2, handOut(a, &ops, &.{}, &.{1})[0].ticket);
    // Holding the same, the older goes first.
    const even = [_]Op{ .{ .ticket = 1, .project = "x", .drain = true, .want = 2 }, .{ .ticket = 2, .project = "x", .drain = true, .want = 2 } };
    try std.testing.expectEqual(1, handOut(a, &even, &.{}, &.{0})[0].ticket);
}

test "the line: projects take turns, by weight" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // rig holds 3, trig 1, a newcomer from rip none; 3 CPUs free.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .held = &.{ 0, 1, 2 }, .want = 10 },
        .{ .ticket = 2, .project = "trig", .held = &.{3}, .want = 10 },
        .{ .ticket = 3, .project = "rip", .want = 10 },
    };
    const got = handOut(a, &ops, &.{}, &.{ 4, 5, 6 });
    try std.testing.expectEqual(3, got.len);
    try std.testing.expectEqual(3, got[0].ticket); // rip 0 -> 1
    // rip 1 and trig 1 tie: the fewer the op holds, then the older ticket: trig (ticket 2).
    try std.testing.expectEqual(2, got[1].ticket);
    try std.testing.expectEqual(3, got[2].ticket);
}

test "the line: weight, urgent, drain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .weight = 2, .held = &.{ 0, 1 }, .want = 5 },
        .{ .ticket = 2, .project = "trig", .held = &.{2}, .want = 5 },
        .{ .ticket = 3, .project = "trig", .urgent = true, .want = 5 },
    };
    // The urgent op's first CPU goes first; then rig (2/2 = 1) ties trig (2/1 = 2)? No: rig is lower.
    const got = handOut(a, &ops, &.{}, &.{ 3, 4 });
    try std.testing.expectEqual(3, got[0].ticket);
    try std.testing.expectEqual(1, got[1].ticket);
    // A drain takes every CPU.
    const with_drain = [_]Op{ ops[0], .{ .ticket = 9, .project = "x", .drain = true, .want = 8 } };
    const d = handOut(a, &with_drain, &.{}, &.{ 3, 4 });
    try std.testing.expectEqual(2, d.len);
    try std.testing.expectEqual(9, d[0].ticket);
    try std.testing.expectEqual(9, d[1].ticket);
}

test "the giver: yields only to the first waiter, once per CPU owed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // rig holds 8 over two ops; trig waits with nothing: rig's bigger op gives.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "rig", .held = &.{ 0, 1, 2, 3, 4 }, .want = 0 },
        .{ .ticket = 2, .project = "rig", .held = &.{ 5, 6, 7 }, .want = 0 },
        .{ .ticket = 3, .project = "trig", .want = 1 },
    };
    try std.testing.expectEqual(1, giver(a, &ops, &.{}).?);
    // One drain is already owed for trig's one CPU: nobody else drains.
    var owing = ops;
    owing[0].draining = 1;
    try std.testing.expectEqual(null, giver(a, &owing, &.{}));
    // Near a tie, nobody gives: trig 4, rig 5 -> (4 + 1) <= (5 - 1) fails.
    const close = [_]Op{
        .{ .ticket = 1, .project = "rig", .held = &.{ 0, 1, 2, 3, 4 } },
        .{ .ticket = 2, .project = "trig", .held = &.{ 5, 6, 7, 8 }, .want = 3 },
    };
    try std.testing.expectEqual(null, giver(a, &close, &.{}));
    // A promise already made to the waiter counts: it wants no more, so nobody drains.
    const promised = [_]Promise{.{ .cpu = 9, .ticket = 3 }};
    try std.testing.expectEqual(null, giver(a, &ops, &promised));
}

test "an op record round trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const now = [_]TaskNow{.{ .task = 17, .attempt = 2, .cpu = 9, .pid = 4242, .since = 1700000000 }};
    const r: Op = .{ .tasks_now = &now, .pid = 7, .project = "rig", .label = "rig:test", .weight = 2, .want = 3, .held = &.{ 4, 9 }, .draining = 1, .overload = 3, .limit = 8, .tasks = 100, .done = 5, .cmd = "a\tb\nc" };
    try r.format(&w);
    const p = Op.parse(arena.allocator(), w.buffered());
    try std.testing.expectEqualStrings("rig", p.project);
    try std.testing.expectEqualSlices(u32, &.{ 4, 9 }, p.held);
    try std.testing.expectEqual(3, p.overload);
    try std.testing.expectEqual(1, p.keeps());
    try std.testing.expectEqualStrings("a b c", p.cmd);
    try std.testing.expectEqual(1, p.tasks_now.len);
    try std.testing.expectEqual(17, p.tasks_now[0].task);
    try std.testing.expectEqual(4242, p.tasks_now[0].pid);
}

test "the line: a waiter holding nothing isn't starved behind a head nobody may give to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Lean counterexample 1: A (P) holds 2, B (Q) holds 1 and wants more, C (P) holds none.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "P", .held = &.{ 1, 2 }, .want = 1 },
        .{ .ticket = 2, .project = "Q", .held = &.{0}, .want = 1 },
        .{ .ticket = 3, .project = "P", .want = 1 },
    };
    try std.testing.expectEqual(3, firstWaiter(a, &ops, &.{}).?.op.ticket);
    try std.testing.expectEqual(1, giver(a, &ops, &.{}).?);
}

test "the giver: never one that would take the CPU straight back" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Lean counterexample 2: weights P=2, Q=1; C (Q, urgent) holds a CPU, A (P) holds none.
    // Were C to give it, C (urgent, holding nothing) would rank first and take it back.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "P", .weight = 2, .want = 3 },
        .{ .ticket = 2, .project = "Q", .held = &.{ 0, 1 } },
        .{ .ticket = 3, .project = "Q", .urgent = true, .held = &.{2}, .want = 1 },
    };
    // B (ticket 2) may give: A holding nothing stays ahead of B holding one.
    try std.testing.expectEqual(2, giver(a, &ops, &.{}).?);
    // With B gone, C alone could give, and would take it back: nobody gives.
    const just_c = [_]Op{ ops[0], ops[2] };
    try std.testing.expectEqual(null, giver(a, &just_c, &.{}));
}

test "the giver: a newcomer gets a CPU from equals, since a giver takes a new ticket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Lean finding 4: 2 CPUs, C and B hold one each (projects X, Y), A (Z) arrives with none.
    const ops = [_]Op{
        .{ .ticket = 1, .project = "X", .held = &.{0}, .want = 1 },
        .{ .ticket = 2, .project = "Y", .held = &.{1}, .want = 1 },
        .{ .ticket = 3, .project = "Z", .want = 1 },
    };
    try std.testing.expectEqual(3, firstWaiter(a, &ops, &.{}).?.op.ticket);
    try std.testing.expect(giver(a, &ops, &.{}) != null);
}
