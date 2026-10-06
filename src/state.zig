//! The state directory. Every hold is a flock(2) on a file here, so the
//! kernel releases it when the last process holding the descriptor exits:
//!
//!   admission.lock      the admission lock; queue scans, token acquisition,
//!                       lease bookkeeping and every probe happen under it
//!   seq                 the last ticket number handed out
//!   valve               the load safety valve's state
//!   queue/P-NNNNNNNNNN  one ticket per waiter (P: 0 high, 1 normal, 2 low),
//!                       exclusively locked by its waiter while it waits
//!   tokens/NNNN         one file per core; an exclusive lock is a held core
//!   leases/NNNNNNNNNN   one record per running job, locked like its tokens
//!                       (suffix .x for an exclusive run)
//!
//! A file whose lock can be taken has no live holder: its waiter or job is
//! gone, and whoever finds it removes it. Probes take a shared lock and run
//! only under the admission lock, so a probe never makes a free token look
//! busy to the head of the queue. Token files are never removed.
const std = @import("std");
const Io = std.Io;
const policy = @import("policy.zig");

pub const State = struct {
    io: Io,
    path: []const u8,
    dir: Io.Dir,
    queue: Io.Dir,
    tokens: Io.Dir,
    leases: Io.Dir,
    admission: Io.File,

    pub fn open(io: Io, path: []const u8) !State {
        const cwd = Io.Dir.cwd();
        try cwd.createDirPath(io, path);
        const dir = try cwd.openDir(io, path, .{ .iterate = true });
        return .{
            .io = io,
            .path = path,
            .dir = dir,
            .queue = try subdir(io, dir, "queue"),
            .tokens = try subdir(io, dir, "tokens"),
            .leases = try subdir(io, dir, "leases"),
            .admission = try createShared(io, dir, "admission.lock"),
        };
    }

    /// Creates or opens a file that other processes may be creating at the
    /// same moment. macOS can fail such a racing open(O_CREAT) with ENOENT
    /// although the directory exists; it succeeds when retried.
    pub fn createShared(io: Io, dir: Io.Dir, name: []const u8) !Io.File {
        var tries: u32 = 0;
        while (true) : (tries += 1) {
            return dir.createFile(io, name, .{ .truncate = false }) catch |err| switch (err) {
                error.FileNotFound => if (tries < 100) {
                    io.sleep(.fromMilliseconds(1), .awake) catch {};
                    continue;
                } else err,
                else => err,
            };
        }
    }

    fn subdir(io: Io, dir: Io.Dir, name: []const u8) !Io.Dir {
        try dir.createDirPath(io, name);
        return dir.openDir(io, name, .{ .iterate = true });
    }

    pub fn lock(s: *State) !void {
        try s.admission.lock(s.io, .exclusive);
    }

    pub fn unlock(s: *State) void {
        s.admission.unlock(s.io);
    }

    /// The next ticket number: above both `seq` and every ticket and lease
    /// on disk, so a lost or garbled `seq` never hands out a live number.
    /// `seq` is replaced by a rename, never left half-written. Call with the
    /// admission lock held.
    pub fn nextTicket(s: *State) !u64 {
        var buf: [32]u8 = undefined;
        var last: u64 = blk: {
            const text = s.dir.readFile(s.io, "seq", &buf) catch |err| switch (err) {
                error.FileNotFound => break :blk 0,
                else => return err,
            };
            break :blk std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0;
        };
        last = @max(last, try highestNumber(s.io, s.queue), try highestNumber(s.io, s.leases));
        var out: [32]u8 = undefined;
        try s.dir.writeFile(s.io, .{ .sub_path = "seq.new", .data = try std.mem.print(&out, "{d}\n", .{last + 1}) });
        try s.dir.rename("seq.new", s.dir, "seq", s.io);
        return last + 1;
    }

    /// The highest ticket number among a directory's names: tickets
    /// (P-NNNNNNNNNN, .new-N) and leases (NNNNNNNNNN, NNNNNNNNNN.x).
    fn highestNumber(io: Io, dir: Io.Dir) !u64 {
        var high: u64 = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            var name = entry.name;
            if (std.mem.cutPrefix(u8, name, ".new-")) |rest| name = rest;
            if (std.mem.cutSuffix(u8, name, ".x")) |rest| name = rest;
            if (std.mem.findScalar(u8, name, '-')) |i| name = name[i + 1 ..];
            high = @max(high, std.fmt.parseInt(u64, name, 10) catch continue);
        }
        return high;
    }

    pub fn readValve(s: *State) policy.Valve {
        var buf: [128]u8 = undefined;
        const text = s.dir.readFile(s.io, "valve", &buf) catch return .{};
        return policy.Valve.parse(text);
    }

    /// The measured use of each holder, by lease name ("usage": one line
    /// each, `name avg idle_since at_ms cpu_ns`). Call with the admission
    /// lock held.
    pub fn readUsage(s: *State, arena: std.mem.Allocator) std.StringHashMapUnmanaged(policy.Use) {
        var map: std.StringHashMapUnmanaged(policy.Use) = .empty;
        const text = s.dir.readFileAlloc(s.io, "usage", arena, .limited(1 << 20)) catch return map;
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var f = std.mem.tokenizeScalar(u8, line, ' ');
            const name = f.next() orelse continue;
            const u: policy.Use = .{
                .avg = std.fmt.parseFloat(f64, f.next() orelse continue) catch continue,
                .idle_since = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue,
                .at_ms = std.fmt.parseInt(i64, f.next() orelse continue, 10) catch continue,
                .cpu_ns = std.fmt.parseInt(u64, f.next() orelse continue, 10) catch continue,
            };
            map.put(arena, name, u) catch {};
        }
        return map;
    }

    pub fn writeUsage(s: *State, arena: std.mem.Allocator, map: std.StringHashMapUnmanaged(policy.Use)) void {
        var out: std.ArrayList(u8) = .empty;
        var it = map.iterator();
        while (it.next()) |e| {
            const u = e.value_ptr.*;
            out.print(arena, "{s} {d:.3} {d} {d} {d}\n", .{ e.key_ptr.*, u.avg, u.idle_since, u.at_ms, u.cpu_ns }) catch return;
        }
        s.dir.writeFile(s.io, .{ .sub_path = "usage", .data = out.items }) catch {};
    }

    /// A hand-given order for a waiter (`cpuq first`, `start`, `cancel`),
    /// left as "control-TICKET" for the waiter to take; null when none.
    pub fn takeControl(s: *State, ticket: []const u8) ?[]const u8 {
        var name_buf: [96]u8 = undefined;
        const name = std.mem.print(&name_buf, "control-{s}", .{ticket}) catch return null;
        var buf: [16]u8 = undefined;
        const text = s.dir.readFile(s.io, name, &buf) catch return null;
        s.dir.deleteFile(s.io, name) catch {};
        const t = std.mem.trim(u8, text, " \n");
        inline for (.{ "first", "start", "cancel" }) |known| if (std.mem.eql(u8, t, known)) return known;
        return null;
    }

    pub fn giveControl(s: *State, ticket: []const u8, action: []const u8) void {
        var name_buf: [96]u8 = undefined;
        const name = std.mem.print(&name_buf, "control-{s}", .{ticket}) catch return;
        s.dir.writeFile(s.io, .{ .sub_path = name, .data = action }) catch {};
    }

    /// Whether a holder is paused by hand (`cpuq pause`): "paused-LEASE".
    pub fn isPaused(s: *State, lease: []const u8) bool {
        var name_buf: [96]u8 = undefined;
        const name = std.mem.print(&name_buf, "paused-{s}", .{lease}) catch return false;
        _ = s.dir.statFile(s.io, name, .{}) catch return false;
        return true;
    }

    pub fn setPaused(s: *State, lease: []const u8, on: bool) void {
        var name_buf: [96]u8 = undefined;
        const name = std.mem.print(&name_buf, "paused-{s}", .{lease}) catch return;
        if (on) s.dir.writeFile(s.io, .{ .sub_path = name, .data = "" }) catch {} else s.dir.deleteFile(s.io, name) catch {};
    }

    pub fn writeValve(s: *State, v: policy.Valve) void {
        var out: [128]u8 = undefined;
        const text = std.mem.print(&out, "{d} {d} {d} {d}\n", .{ @intFromBool(v.tripped), v.calm_since, v.last_admit, v.last_check }) catch return;
        s.dir.writeFile(s.io, .{ .sub_path = "valve", .data = text }) catch {};
    }

    /// Enqueues a waiter: the ticket is created under a temporary name,
    /// locked and written, then renamed into place, so no reaper ever sees
    /// it unlocked. Call with the admission lock held.
    pub fn createTicket(s: *State, r: Record, name: []const u8) !Io.File {
        var tmp_buf: [64]u8 = undefined;
        const tmp = try std.mem.print(&tmp_buf, ".new-{d}", .{r.ticket});
        const f = try s.queue.createFile(s.io, tmp, .{ .lock = .exclusive, .truncate = true });
        errdefer f.close(s.io);
        try writeRecord(s.io, f, r);
        try s.queue.rename(tmp, s.queue, name, s.io);
        return f;
    }

    /// Creates a job's lease, exclusively locked. A name some live job
    /// already holds fails with error.WouldBlock rather than waiting (it
    /// would wait under the admission lock) and is left untouched. Call with
    /// the admission lock held.
    pub fn createLease(s: *State, r: Record, name: []const u8) !Io.File {
        const f = try s.leases.createFile(s.io, name, .{ .lock = .exclusive, .lock_nonblocking = true, .truncate = false });
        errdefer f.close(s.io);
        try f.setLength(s.io, 0);
        try writeRecord(s.io, f, r);
        return f;
    }
};

pub const Record = struct {
    ticket: u64 = 0,
    pid: i32 = 0,
    child: i32 = 0,
    cores: u32 = 0,
    /// A waiter's maximum (its minimum is `cores`); a lease's `cores` is its grant.
    max: u32 = 0,
    priority: policy.Priority = .normal,
    exclusive: bool = false,
    since: i64 = 0,
    label: []const u8 = "",
    cmd: []const u8 = "",
    /// The core tokens a holder took, by number, comma-separated ("0,1,2"):
    /// which of the budget's cores are its own.
    slots: []const u8 = "",
    /// A waiter moved to the front by hand (`cpuq first`): it goes ahead of
    /// every waiter not so moved.
    first: bool = false,

    pub fn write(r: Record, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("ticket={d}\npid={d}\nchild={d}\ncores={d}\nmax={d}\npriority={t}\nexclusive={d}\nsince={d}\n", .{
            r.ticket, r.pid, r.child, r.cores, r.max, r.priority, @intFromBool(r.exclusive), r.since,
        });
        try w.writeAll("label=");
        try writeLine(w, r.label);
        try w.writeAll("cmd=");
        try writeLine(w, r.cmd);
        if (r.slots.len != 0) try w.print("slots={s}\n", .{r.slots});
        if (r.first) try w.writeAll("first=1\n");
    }

    fn writeLine(w: *Io.Writer, text: []const u8) Io.Writer.Error!void {
        for (text) |ch| try w.writeByte(if (ch < 0x20 or ch == 0x7f) ' ' else ch);
        try w.writeByte('\n');
    }

    pub fn parse(text: []const u8) Record {
        var r: Record = .{};
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const k, const v = std.mem.cutScalar(u8, line, '=') orelse continue;
            if (std.mem.eql(u8, k, "ticket")) r.ticket = std.fmt.parseInt(u64, v, 10) catch 0;
            if (std.mem.eql(u8, k, "pid")) r.pid = std.fmt.parseInt(i32, v, 10) catch 0;
            if (std.mem.eql(u8, k, "child")) r.child = std.fmt.parseInt(i32, v, 10) catch 0;
            if (std.mem.eql(u8, k, "cores")) r.cores = std.fmt.parseInt(u32, v, 10) catch 0;
            if (std.mem.eql(u8, k, "max")) r.max = std.fmt.parseInt(u32, v, 10) catch 0;
            if (std.mem.eql(u8, k, "priority")) r.priority = policy.Priority.parse(v) orelse .normal;
            if (std.mem.eql(u8, k, "exclusive")) r.exclusive = std.mem.eql(u8, v, "1");
            if (std.mem.eql(u8, k, "since")) r.since = std.fmt.parseInt(i64, v, 10) catch 0;
            if (std.mem.eql(u8, k, "label")) r.label = v;
            if (std.mem.eql(u8, k, "cmd")) r.cmd = v;
            if (std.mem.eql(u8, k, "slots")) r.slots = v;
            if (std.mem.eql(u8, k, "first")) r.first = std.mem.eql(u8, v, "1");
        }
        return r;
    }

    /// `slots` as numbers.
    pub fn slotList(r: Record, a: std.mem.Allocator) []u32 {
        var out: std.ArrayList(u32) = .empty;
        var it = std.mem.tokenizeScalar(u8, r.slots, ',');
        while (it.next()) |n| out.append(a, std.fmt.parseInt(u32, n, 10) catch continue) catch break;
        return out.items;
    }
};

test "record round trip" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const r: Record = .{ .ticket = 42, .pid = 7, .cores = 3, .priority = .low, .exclusive = true, .since = 1700000000, .label = "heavy", .cmd = "zig build\ttest\n-x", .slots = "0,3,4" };
    try r.write(&w);
    const p = Record.parse(w.buffered());
    try std.testing.expectEqual(42, p.ticket);
    try std.testing.expectEqual(policy.Priority.low, p.priority);
    try std.testing.expect(p.exclusive);
    try std.testing.expectEqualStrings("heavy", p.label);
    try std.testing.expectEqualStrings("zig build test -x", p.cmd);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 4 }, p.slotList(arena.allocator()));
}

pub fn writeRecord(io: Io, file: Io.File, r: Record) !void {
    var buf: [1024]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    try r.write(&fw.interface);
    try fw.interface.flush();
}

fn readAll(io: Io, arena: std.mem.Allocator, file: Io.File) []const u8 {
    var buf: [1024]u8 = undefined;
    var fr = file.reader(io, &buf);
    return fr.interface.allocRemaining(arena, .limited(64 << 10)) catch "";
}

/// True when the file open as `file` is still the one named `name`: a lock
/// taken through a path is worthless once that path names another inode or
/// none.
pub fn samePath(io: Io, dir: Io.Dir, name: []const u8, file: Io.File) bool {
    const a = file.stat(io) catch return false;
    const b = dir.statFile(io, name, .{}) catch return false;
    return a.inode == b.inode;
}

pub const Entry = struct {
    name: []const u8,
    record: Record,
    class: u2 = 0,
};

/// Opens `name` and probes it. Alive: returns its record. Dead: removes it
/// and returns null. Call with the admission lock held.
fn probe(io: Io, arena: std.mem.Allocator, dir: Io.Dir, name: []const u8) ?Record {
    const f = dir.openFile(io, name, .{}) catch return null;
    defer f.close(io);
    const free = f.tryLock(io, .shared) catch false;
    if (free) {
        if (samePath(io, dir, name, f)) dir.deleteFile(io, name) catch {};
        f.unlock(io);
        return null;
    }
    return Record.parse(readAll(io, arena, f));
}

/// Live waiters in service order: effective class (priority after aging),
/// then ticket. Dead tickets are removed on the way. Call with the
/// admission lock held.
pub fn scanQueue(s: *State, arena: std.mem.Allocator, own: ?[]const u8, own_record: Record, now: i64, aging_s: u32) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var it = s.queue.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name[0] == '.') {
            // A temporary ticket left by a crash between its creation and its
            // rename (both happen under the admission lock).
            _ = probe(s.io, arena, s.queue, entry.name);
            continue;
        }
        const name = try arena.dupe(u8, entry.name);
        const record = if (own != null and std.mem.eql(u8, own.?, name))
            own_record
        else
            probe(s.io, arena, s.queue, name) orelse continue;
        try list.append(arena, .{
            .name = name,
            .record = record,
            .class = policy.effectiveClass(record.priority, now - record.since, aging_s),
        });
    }
    std.mem.sortUnstable(Entry, list.items, {}, lessEntry);
    return list.items;
}

fn lessEntry(_: void, a: Entry, b: Entry) bool {
    if (a.record.first != b.record.first) return a.record.first;
    if (a.class != b.class) return a.class < b.class;
    return a.record.ticket < b.record.ticket;
}

/// Live leases; dead ones are removed. Call with the admission lock held.
pub fn scanLeases(s: *State, arena: std.mem.Allocator, only_exclusive: bool) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var it = s.leases.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .file) continue;
        if (only_exclusive and !std.mem.endsWith(u8, entry.name, ".x")) continue;
        const name = try arena.dupe(u8, entry.name);
        const record = probe(s.io, arena, s.leases, name) orelse continue;
        try list.append(arena, .{ .name = name, .record = record });
    }
    std.mem.sortUnstable(Entry, list.items, {}, lessEntry);
    return list.items;
}

/// The number of held tokens. Call with the admission lock held.
pub fn heldTokens(s: *State) !u32 {
    var held: u32 = 0;
    var it = s.tokens.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .file) continue;
        const f = s.tokens.openFile(s.io, entry.name, .{}) catch continue;
        defer f.close(s.io);
        if (try f.tryLock(s.io, .shared)) f.unlock(s.io) else held += 1;
    }
    return held;
}

pub fn ticketName(buf: []u8, priority: policy.Priority, ticket: u64) []const u8 {
    return std.mem.print(buf, "{d}-{d:0>10}", .{ @backingInt(priority), ticket }) catch unreachable;
}

pub fn leaseName(buf: []u8, ticket: u64, exclusive: bool) []const u8 {
    return std.mem.print(buf, "{d:0>10}{s}", .{ ticket, if (exclusive) ".x" else "" }) catch unreachable;
}

fn tokenName(buf: []u8, i: u32) []const u8 {
    return std.mem.print(buf, "{d:0>4}", .{i}) catch unreachable;
}

/// The token files a grant holds, and their numbers.
pub const Grant = struct {
    files: []Io.File,
    slots: []u32,

    /// The numbers as a record writes them: "0,1,2".
    pub fn slotText(g: Grant, a: std.mem.Allocator) []const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (g.slots, 0..) |n, i| out.print(a, "{s}{d}", .{ if (i == 0) "" else ",", n }) catch break;
        return out.items;
    }
};

/// The head's all-or-nothing acquisition: it locks every free token, counts
/// the held ones, asks `policy.admit` how many to take, keeps that many of
/// the lowest-numbered free tokens and releases the rest, or all of them
/// when the answer is to wait. Every token file in the directory counts,
/// beyond the first `cores` too, so every run sees every hold whatever core
/// count it was started with. Call with the admission lock held.
pub fn takeTokens(s: *State, arena: std.mem.Allocator, req: policy.Request, exclusive: bool, budget: u32, cores: u32, exclusive_running: bool, reserve: u32) !?Grant {
    var n = cores;
    var it = s.tokens.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .file) continue;
        const i = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        n = @max(n, i + 1);
    }
    var free: std.ArrayList(Io.File) = .empty;
    var numbers: std.ArrayList(u32) = .empty;
    var held: u32 = 0;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var buf: [16]u8 = undefined;
        const name = tokenName(&buf, i);
        const f = if (i < cores)
            try State.createShared(s.io, s.tokens, name)
        else
            s.tokens.openFile(s.io, name, .{}) catch continue;
        if (try f.tryLock(s.io, .exclusive)) {
            try free.append(arena, f);
            try numbers.append(arena, i);
        } else {
            held += 1;
            f.close(s.io);
        }
    }
    const k = policy.admit(req, exclusive, budget, held, exclusive_running, reserve) orelse 0;
    const keep = @min(k, free.items.len);
    for (free.items[keep..]) |f| {
        f.unlock(s.io);
        f.close(s.io);
    }
    if (keep == 0 or keep < k) {
        for (free.items[0..keep]) |f| {
            f.unlock(s.io);
            f.close(s.io);
        }
        return null;
    }
    return .{ .files = free.items[0..keep], .slots = numbers.items[0..keep] };
}
