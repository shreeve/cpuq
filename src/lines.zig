//! Plain-line Unix sockets: each job's driver and the host agent talk in lines of text, one
//! connection each, held open. A socket is named relative to its directory, so its path fits the
//! address's 104 bytes however deep the directory is.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const Allocator = std.mem.Allocator;

const is_linux = builtin.os.tag == .linux;

/// Listens on `name` in the directory `dir`, non-blocking. A socket already there is removed
/// first: the caller holds the lock that makes it stale.
pub fn listen(dir: c.fd_t, name: [:0]const u8) !c.fd_t {
    const fd = try open();
    errdefer _ = c.close(fd);
    var addr = try address(name);
    try at(dir, struct {
        fn f(n: [:0]const u8, s: c.fd_t, ad: *const c.sockaddr.un) bool {
            _ = c.unlink(n);
            return c.bind(s, @ptrCast(ad), @sizeOf(c.sockaddr.un)) == 0;
        }
    }.f, .{ name, fd, &addr });
    if (c.listen(fd, 64) != 0) return error.ListenFailed;
    nonblock(fd);
    return fd;
}

/// Connects to `name` in `dir`; null when nothing listens there.
pub fn connect(dir: c.fd_t, name: [:0]const u8) ?c.fd_t {
    const fd = open() catch return null;
    const addr = address(name) catch {
        _ = c.close(fd);
        return null;
    };
    at(dir, struct {
        fn f(s: c.fd_t, ad: *const c.sockaddr.un) bool {
            return c.connect(s, @ptrCast(ad), @sizeOf(c.sockaddr.un)) == 0;
        }
    }.f, .{ fd, &addr }) catch {
        _ = c.close(fd);
        return null;
    };
    return fd;
}

/// A waiting connection, non-blocking; null when there is none.
pub fn accept(listener: c.fd_t) ?c.fd_t {
    const fd = c.accept(listener, null, null);
    if (fd < 0) return null;
    cloexec(fd);
    nosigpipe(fd);
    nonblock(fd);
    return fd;
}

fn open() !c.fd_t {
    const fd = c.socket(c.AF.UNIX, c.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    cloexec(fd);
    nosigpipe(fd);
    return fd;
}

fn address(name: [:0]const u8) !c.sockaddr.un {
    var addr: c.sockaddr.un = .{ .path = @splat(0) };
    if (name.len >= addr.path.len) return error.NameTooLong;
    @memcpy(addr.path[0..name.len], name);
    return addr;
}

/// Runs `f` in `dir`, then returns to where this process was.
fn at(dir: c.fd_t, comptime f: anytype, args: anytype) !void {
    const here = c.open(".", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (here < 0) return error.NoCwd;
    defer _ = c.close(here);
    if (c.fchdir(dir) != 0) return error.NoDir;
    const ok = @call(.auto, f, args);
    _ = c.fchdir(here);
    if (!ok) return error.Failed;
}

pub fn cloexec(fd: c.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
}

pub fn nonblock(fd: c.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFL, c.fcntl(fd, c.F.GETFL, @as(c_int, 0)) | @as(c_int, @bitCast(c.O{ .NONBLOCK = true })));
}

fn nosigpipe(fd: c.fd_t) void {
    if (is_linux) return; // each send says MSG.NOSIGNAL
    const one: c_int = 1;
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, &one, @sizeOf(c_int));
}

/// One end of a connection: what came in, split into lines, and what waits to go out.
pub const Conn = struct {
    fd: c.fd_t,
    in: std.ArrayList(u8) = .empty,
    /// The start of the first line not yet taken.
    pos: usize = 0,
    out: std.ArrayList(u8) = .empty,
    /// The other end closed (or failed).
    closed: bool = false,

    pub fn deinit(conn: *Conn, a: Allocator) void {
        _ = c.close(conn.fd);
        conn.in.deinit(a);
        conn.out.deinit(a);
    }

    /// Queues a line (or lines) and sends what it can.
    pub fn print(conn: *Conn, a: Allocator, comptime fmt: []const u8, args: anytype) void {
        conn.out.print(a, fmt, args) catch return;
        conn.flush();
    }

    /// Sends what it can without blocking; poll for POLL.OUT while `out` holds more.
    pub fn flush(conn: *Conn) void {
        while (conn.out.items.len > 0 and !conn.closed) {
            const n = if (is_linux) c.send(conn.fd, conn.out.items.ptr, conn.out.items.len, c.MSG.NOSIGNAL) else c.write(conn.fd, conn.out.items.ptr, conn.out.items.len);
            if (n < 0) switch (c.errno(n)) {
                .INTR => continue,
                .AGAIN => return,
                else => {
                    conn.closed = true;
                    return;
                },
            };
            const done: usize = @intCast(n);
            std.mem.copyForwards(u8, conn.out.items[0 .. conn.out.items.len - done], conn.out.items[done..]);
            conn.out.shrinkRetainingCapacity(conn.out.items.len - done);
        }
    }

    /// Reads what has come; on a blocking descriptor, waits for some. Lines taken before are
    /// dropped, so a line `next` returned lasts until the next `fill`.
    pub fn fill(conn: *Conn, a: Allocator) void {
        const rest = conn.in.items.len - conn.pos;
        std.mem.copyForwards(u8, conn.in.items[0..rest], conn.in.items[conn.pos..]);
        conn.in.shrinkRetainingCapacity(rest);
        conn.pos = 0;
        var buf: [16384]u8 = undefined;
        while (!conn.closed) {
            const n = c.read(conn.fd, &buf, buf.len);
            if (n < 0) switch (c.errno(n)) {
                .INTR => continue,
                .AGAIN => return,
                else => {
                    conn.closed = true;
                    return;
                },
            };
            if (n == 0) {
                conn.closed = true;
                return;
            }
            conn.in.appendSlice(a, buf[0..@intCast(n)]) catch return;
            if (conn.in.items.len > 16 << 20) conn.closed = true; // no line is that long
            if (n < buf.len) return;
        }
    }

    /// The next whole line, without its newline.
    pub fn next(conn: *Conn) ?[]const u8 {
        const end = std.mem.findScalarPos(u8, conn.in.items, conn.pos, '\n') orelse return null;
        const line = conn.in.items[conn.pos..end];
        conn.pos = end + 1;
        return line;
    }

    /// For a blocking connection: the next line, waiting for it; null at the end.
    pub fn wait(conn: *Conn, a: Allocator) ?[]const u8 {
        while (true) {
            if (conn.next()) |line| return line;
            if (conn.closed) return null;
            conn.fill(a);
        }
    }

    /// For a blocking connection: sends everything queued.
    pub fn send(conn: *Conn, a: Allocator, comptime fmt: []const u8, args: anytype) void {
        conn.out.print(a, fmt, args) catch return;
        while (conn.out.items.len > 0 and !conn.closed) {
            conn.flush();
            if (conn.out.items.len > 0) {
                var pfd = [_]c.pollfd{.{ .fd = conn.fd, .events = c.POLL.OUT, .revents = 0 }};
                _ = c.poll(&pfd, 1, 1000);
            }
        }
    }
};

test "lines over a socket, a socket named relative to its directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir.handle;
    const l = try listen(dir, "t.sock");
    defer _ = c.close(l);
    const a = std.testing.allocator;
    var client: Conn = .{ .fd = connect(dir, "t.sock").? };
    defer client.deinit(a);
    var server: Conn = .{ .fd = accept(l).? };
    defer server.deinit(a);
    client.send(a, "hello one\nhello two\n", .{});
    var pfd = [_]c.pollfd{.{ .fd = server.fd, .events = c.POLL.IN, .revents = 0 }};
    _ = c.poll(&pfd, 1, 1000);
    server.fill(a);
    try std.testing.expectEqualStrings("hello one", server.next().?);
    try std.testing.expectEqualStrings("hello two", server.next().?);
    try std.testing.expectEqual(null, server.next());
    server.print(a, "ok\n", .{});
    try std.testing.expectEqualStrings("ok", client.wait(a).?);
    _ = c.close(server.fd);
    server.fd = -1;
    try std.testing.expectEqual(null, client.wait(a));
}
