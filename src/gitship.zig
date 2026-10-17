//! A repository's git, shipped to a copy of it on another machine (or here): a standalone `.git`
//! directory with only git's own parts of the common dir (objects, refs, packed-refs, config,
//! info, shallow) and the worktree's own HEAD and index. Whatever else a repo keeps under .git
//! (build stores, caches, notes) stays behind, and a worktree's `.git` file, a path on this
//! machine, becomes a repo there. After the first copy rsync sends only what changed.

const std = @import("std");
const Io = std.Io;

/// Ships the git of the repo at `root` to `git_dir`, the copy's `.git`: a path in HOST's home
/// when `host` is given, else a path here. The error text when it fails, else null.
pub fn ship(a: std.mem.Allocator, io: Io, rsync: []const u8, root: []const u8, host: ?[]const u8, git_dir: []const u8) ?[]const u8 {
    const r = std.process.run(a, io, .{ .argv = &.{ "git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir" } }) catch return "git: cannot run git";
    if (!r.term.success()) return "git: not a git repository";
    var lines = std.mem.tokenizeScalar(u8, r.stdout, '\n');
    const common = lines.next() orelse return "git: no git directory";
    const own = lines.next() orelse common;
    const in_worktree = !std.mem.eql(u8, common, own);
    const dest = (if (host) |h| a.print("{s}:{s}/", .{ h, git_dir }) else a.print("{s}/", .{git_dir})) catch return "out of memory";
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(a, &.{ rsync, "-a", "--delete" }) catch return "out of memory";
    // A `.git` file there (a worktree's, shipped as it was) gives way to the directory.
    if (host != null) {
        argv.append(a, a.print("--rsync-path=d={s}; [ -d \"$d\" ] || rm -f \"$d\"; mkdir -p \"$d\" && rsync", .{quote(a, git_dir)}) catch return "out of memory") catch return "out of memory";
    } else {
        if (Io.Dir.cwd().statFile(io, git_dir, .{})) |st| {
            if (st.kind != .directory) Io.Dir.cwd().deleteFile(io, git_dir) catch {};
        } else |_| {}
        Io.Dir.cwd().createDirPath(io, git_dir) catch return "git: cannot make the copy's .git";
    }
    argv.appendSlice(a, &.{ "--include=/config", "--include=/packed-refs", "--include=/shallow", "--include=/objects/***", "--include=/refs/***", "--include=/info/***" }) catch return "out of memory";
    if (!in_worktree) argv.appendSlice(a, &.{ "--include=/HEAD", "--include=/index" }) catch return "out of memory";
    argv.appendSlice(a, &.{ "--exclude=*", a.print("{s}/", .{common}) catch "", dest }) catch return "out of memory";
    if (failed(a, io, argv.items)) |e| return e;
    if (!in_worktree) return null;
    // The worktree's own: which commit it's on, and its index.
    var own_argv: std.ArrayList([]const u8) = .empty;
    own_argv.appendSlice(a, &.{ rsync, "-a", a.print("{s}/HEAD", .{own}) catch "" }) catch return "out of memory";
    const index = a.print("{s}/index", .{own}) catch "";
    if (Io.Dir.cwd().access(io, index, .{})) |_| own_argv.append(a, index) catch {} else |_| {}
    own_argv.append(a, dest) catch return "out of memory";
    return failed(a, io, own_argv.items);
}

fn failed(a: std.mem.Allocator, io: Io, argv: []const []const u8) ?[]const u8 {
    const c = std.process.run(a, io, .{ .argv = argv }) catch return "git: cannot run rsync";
    if (copied(c.term)) return null;
    return a.print("git: {s}", .{std.mem.trim(u8, c.stderr, " \n")}) catch "git: rsync failed";
}

/// Whether an rsync did its job: it exited 0, or 24, "some files vanished before they could be
/// transferred", a file deleted while it copied (a branch removed once merged, a build's scratch).
/// What vanished is gone here too, so the copy is no less right.
pub fn copied(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0 or code == 24,
        else => false,
    };
}

/// A copy rsync made, read back file by file.
pub const Checked = union(enum) {
    /// Every file there is the same as here.
    same,
    /// These differed and were sent again; now they are the same.
    repaired: []const u8,
    /// These still differ after being sent again: the copy is bad.
    differs: []const u8,
};

/// Checks a copy `argv` (an rsync, `argv[0]` its path) just made by each file's checksum, which
/// rsync's own quick check (size and mtime) never does: a file damaged there keeps both, and no
/// later copy would send it again. What differs is sent once more by checksum and checked again.
pub fn check(a: std.mem.Allocator, io: Io, argv: []const []const u8) Checked {
    const first = differing(a, io, argv, true) orelse return .{ .differs = "rsync could not compare the copy" };
    if (first.len == 0) return .same;
    if (differing(a, io, argv, false) == null) return .{ .differs = first };
    const again = differing(a, io, argv, true) orelse return .{ .differs = first };
    return if (again.len == 0) .{ .repaired = first } else .{ .differs = again };
}

/// With `dry`, the files whose checksums differ there, comma-separated ("" when none); without,
/// sends those files. Null when rsync fails.
fn differing(a: std.mem.Allocator, io: Io, argv: []const []const u8, dry: bool) ?[]const u8 {
    var by_sum: std.ArrayList([]const u8) = .empty;
    by_sum.append(a, argv[0]) catch return null;
    by_sum.appendSlice(a, if (dry) &.{ "-c", "-n", "--out-format=%i %n" } else &.{"-c"}) catch return null;
    by_sum.appendSlice(a, argv[1..]) catch return null;
    const r = std.process.run(a, io, .{ .argv = by_sum.items }) catch return null;
    if (!copied(r.term)) return null;
    return if (dry) sent(a, r.stdout) else "";
}

/// The files an `--out-format=%i %n` listing sends, comma-separated: `<f` to another machine,
/// `>f` to a path here.
fn sent(a: std.mem.Allocator, listing: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, listing, '\n');
    while (lines.next()) |line| {
        if (line.len < 2 or (line[0] != '<' and line[0] != '>') or line[1] != 'f') continue;
        const name = line[(std.mem.findScalar(u8, line, ' ') orelse continue) + 1 ..];
        out.print(a, "{s}{s}", .{ if (out.items.len == 0) "" else ", ", name }) catch break;
    }
    return out.items;
}

/// `s` in single quotes for a POSIX shell.
fn quote(a: std.mem.Allocator, s: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '\'') catch return s;
    for (s) |ch| {
        if (ch == '\'') out.appendSlice(a, "'\\''") catch return s else out.append(a, ch) catch return s;
    }
    out.append(a, '\'') catch return s;
    return out.items;
}

test "an rsync whose files vanished as it copied still copied" {
    try std.testing.expect(copied(.{ .exited = 0 }));
    try std.testing.expect(copied(.{ .exited = 24 }));
    try std.testing.expect(!copied(.{ .exited = 23 }));
    try std.testing.expect(!copied(.{ .exited = 255 }));
}

test "a checksum listing names the files it would send, not deletions or folders" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // openrsync's flags, then rsync 3's wider ones.
    try std.testing.expectEqualStrings("d/a, c", sent(arena.allocator(), "*deleting x\n.d..t.... d/\n>fc...... d/a\n>f+++++++ c\n"));
    try std.testing.expectEqualStrings("d/my file", sent(arena.allocator(), "*deleting   x\n<fc........ d/my file\ncL+++++++++ l\n"));
    try std.testing.expectEqualStrings("", sent(arena.allocator(), ""));
}
