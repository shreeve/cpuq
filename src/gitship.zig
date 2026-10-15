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
    if (c.term.success()) return null;
    return a.print("git: {s}", .{std.mem.trim(u8, c.stderr, " \n")}) catch "git: rsync failed";
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
