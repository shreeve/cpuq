//! A named lease's state directory (`cpuq lease NAME`): a pool of `--slots` places, held by
//! flock(2), so the kernel releases a hold when the last process holding its descriptor exits:
//!
//!   admission.lock      the lease's lock; queue scans, slot taking and lease bookkeeping
//!                       happen under it
//!   seq                 the last ticket number handed out
//!   queue/NNNNNNNNNN    one ticket per waiter, exclusively locked by its waiter while it waits
//!   tokens/NNNN         one file per slot; an exclusive lock is a held slot
//!   leases/NNNNNNNNNN   one record per holder, locked like its slot
//!
//! A file whose lock can be taken has no live holder: its waiter or holder is gone, and whoever
//! finds it removes it. Probes take a shared lock and run only under the lock, so a probe never
//! makes a free slot look held to the head of the queue. Slot files are never removed.
const std = @import("std");
const Io = std.Io;

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
    /// lock held.
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

    /// The highest ticket number among a directory's names: tickets and leases
    /// (NNNNNNNNNN, .new-N).
    fn highestNumber(io: Io, dir: Io.Dir) !u64 {
        var high: u64 = 0;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            var name = entry.name;
            if (std.mem.cutPrefix(u8, name, ".new-")) |rest| name = rest;
            high = @max(high, std.fmt.parseInt(u64, name, 10) catch continue);
        }
        return high;
    }

    /// Enqueues a waiter: the ticket is created under a temporary name,
    /// locked and written, then renamed into place, so no reaper ever sees
    /// it unlocked. Call with the lock held.
    pub fn createTicket(s: *State, r: Record, name: []const u8) !Io.File {
        var tmp_buf: [64]u8 = undefined;
        const tmp = try std.mem.print(&tmp_buf, ".new-{d}", .{r.ticket});
        const f = try s.queue.createFile(s.io, tmp, .{ .lock = .exclusive, .truncate = true });
        errdefer f.close(s.io);
        try writeRecord(s.io, f, r);
        try s.queue.rename(tmp, s.queue, name, s.io);
        return f;
    }

    /// Creates a holder's lease, exclusively locked. A name some live holder
    /// already holds fails with error.WouldBlock rather than waiting (it
    /// would wait under the lock) and is left untouched. Call with the lock
    /// held.
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
    since: i64 = 0,
    label: []const u8 = "",
    cmd: []const u8 = "",

    pub fn write(r: Record, w: *Io.Writer) Io.Writer.Error!void {
        try w.print("ticket={d}\npid={d}\nsince={d}\n", .{ r.ticket, r.pid, r.since });
        try w.writeAll("label=");
        try writeLine(w, r.label);
        try w.writeAll("cmd=");
        try writeLine(w, r.cmd);
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
            if (std.mem.eql(u8, k, "since")) r.since = std.fmt.parseInt(i64, v, 10) catch 0;
            if (std.mem.eql(u8, k, "label")) r.label = v;
            if (std.mem.eql(u8, k, "cmd")) r.cmd = v;
        }
        return r;
    }
};

test "record round trip" {
    var buf: [512]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const r: Record = .{ .ticket = 42, .pid = 7, .since = 1700000000, .label = "heavy", .cmd = "zig build\ttest\n-x" };
    try r.write(&w);
    const p = Record.parse(w.buffered());
    try std.testing.expectEqual(42, p.ticket);
    try std.testing.expectEqual(7, p.pid);
    try std.testing.expectEqualStrings("heavy", p.label);
    try std.testing.expectEqualStrings("zig build test -x", p.cmd);
}

pub fn writeRecord(io: Io, file: Io.File, r: Record) !void {
    var buf: [1024]u8 = undefined;
    var fw = file.writerStreaming(io, &buf);
    try r.write(&fw.interface);
    try fw.interface.flush();
}

fn readAll(io: Io, arena: std.mem.Allocator, file: Io.File) []const u8 {
    var fr = recordReader(io, file);
    return fr.interface.allocRemaining(arena, .limited(64 << 10)) catch "";
}

/// A reader for a record another process may still be writing. It has no
/// buffer of its own: a buffered reader can read past the size it took at
/// its first look, if the file has grown since, and the standard library's
/// arithmetic then overflows (a panic, which killed waiters).
fn recordReader(io: Io, file: Io.File) Io.File.Reader {
    return file.reader(io, &.{});
}

test "a record that grows while it is read" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "r", .data = "ticket 1\n" });
    const f = try tmp.dir.openFile(io, "r", .{});
    defer f.close(io);
    var fr = recordReader(io, f);
    _ = try fr.getSize();
    // Its owner writes the rest after the reader has looked at the size.
    var long: [3000]u8 = undefined;
    @memset(&long, 'x');
    @memcpy(long[0..9], "ticket 1\n");
    try tmp.dir.writeFile(io, .{ .sub_path = "r", .data = &long });
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = fr.interface.allocRemaining(arena.allocator(), .limited(64 << 10)) catch "";
    try std.testing.expect(std.mem.startsWith(u8, got, "ticket 1\n"));
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
};

/// Opens `name` and probes it. Alive: returns its record. Dead: removes it
/// and returns null. Call with the lock held.
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

/// Live entries of `dir` (the queue or the leases) in ticket order; dead ones are removed on the
/// way. `own` is read from `own_record`, not probed. Call with the lock held.
fn scan(s: *State, dir: Io.Dir, arena: std.mem.Allocator, own: ?[]const u8, own_record: Record) ![]Entry {
    var list: std.ArrayList(Entry) = .empty;
    var it = dir.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .file) continue;
        if (entry.name[0] == '.') {
            // A temporary ticket left by a crash between its creation and its
            // rename (both happen under the lock).
            _ = probe(s.io, arena, dir, entry.name);
            continue;
        }
        const name = try arena.dupe(u8, entry.name);
        const record = if (own != null and std.mem.eql(u8, own.?, name))
            own_record
        else
            probe(s.io, arena, dir, name) orelse continue;
        try list.append(arena, .{ .name = name, .record = record });
    }
    std.mem.sortUnstable(Entry, list.items, {}, struct {
        fn less(_: void, a: Entry, b: Entry) bool {
            return a.record.ticket < b.record.ticket;
        }
    }.less);
    return list.items;
}

/// Live waiters, first come first served. Call with the lock held.
pub fn scanQueue(s: *State, arena: std.mem.Allocator, own: []const u8, own_record: Record) ![]Entry {
    return scan(s, s.queue, arena, own, own_record);
}

/// Live holders. Call with the lock held.
pub fn scanLeases(s: *State, arena: std.mem.Allocator) ![]Entry {
    return scan(s, s.leases, arena, null, .{});
}

pub fn ticketName(buf: []u8, ticket: u64) []const u8 {
    return std.mem.print(buf, "{d:0>10}", .{ticket}) catch unreachable;
}

/// Takes one free slot of `slots`, locked exclusively, or null when all are held. Every slot file
/// in the directory counts, beyond the first `slots` too, so a holder started with more slots is
/// seen by every waiter. Call with the lock held.
pub fn takeSlot(s: *State, slots: u32) !?Io.File {
    var n = slots;
    var it = s.tokens.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .file) continue;
        const i = std.fmt.parseInt(u32, entry.name, 10) catch continue;
        n = @max(n, i + 1);
    }
    var held: u32 = 0;
    var free: ?Io.File = null;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        var buf: [16]u8 = undefined;
        const name = std.mem.print(&buf, "{d:0>4}", .{i}) catch unreachable;
        const f = if (i < slots)
            try State.createShared(s.io, s.tokens, name)
        else
            s.tokens.openFile(s.io, name, .{}) catch continue;
        if (try f.tryLock(s.io, .exclusive)) {
            if (free == null) free = f else {
                f.unlock(s.io);
                f.close(s.io);
            }
        } else {
            held += 1;
            f.close(s.io);
        }
    }
    if (free) |f| {
        if (held < slots) return f;
        f.unlock(s.io);
        f.close(s.io);
    }
    return null;
}
