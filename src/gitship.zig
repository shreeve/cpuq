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

/// rsync's `--rsync-path` for a copy at `dir` on another machine (relative to its home): the
/// command that makes the folder before rsync runs. A copy not there yet starts as a block clone
/// (`cp --reflink=always`: ZFS's or btrfs's, sharing the blocks) of the last used other copy in
/// the same folder, so rsync sends only what differs: seconds, where a first copy takes half a
/// minute. With `marker`, a copy counts only when its `.cpuq-used` holds that text (copies of one
/// repo among others'). Every file of the clone is dated back by 30 years (`aged`): rsync then
/// compares each one it ships, and an output the build left there (a make or cargo target from
/// another branch) is older than every source, so it's built again; a cache that goes by
/// content (zig's) stays warm. (`.cpuq-used` is dated now, so `cpuq clean` keeps the new copy.)
/// The clone's `.git` is left out unless `keep_git` (git ships after, sending what differs).
/// Where the filesystem can't clone, or the dates can't be moved, the copy starts empty, as
/// without this.
pub fn seedPath(a: std.mem.Allocator, dir: []const u8, marker: ?[]const u8, keep_git: bool) []const u8 {
    const parent = quote(a, std.fs.path.dirname(dir) orelse ".");
    // Run by `sh`: the login shell there may be zsh, which doesn't split `$(ls)` into words.
    const same = if (marker) |m| a.print("[ \"$(cat \"$u\" 2>/dev/null)\" = {s} ] || continue; ", .{quote(a, m)}) catch "" else "";
    const script = a.print(
        "d={s}; if [ ! -d \"$d\" ]; then t=\"$d.seed.$$\"; mkdir -p {s}; " ++
            "for u in $(ls -t {s}/*/.cpuq-used 2>/dev/null); do s=${{u%/.cpuq-used}}; case $s in *.seed.*) continue;; esac; {s}" ++
            "cp -a --reflink=always \"$s\" \"$t\" 2>/dev/null || rm -rf \"$t\"; break; done; " ++
            "if [ -d \"$t\" ]; then {s}{s} || rm -rf \"$t\"; fi; " ++
            // A copy made meanwhile by another first sync stays; this clone isn't moved into it.
            "if [ -d \"$t\" ]; then touch \"$t/.cpuq-used\"; [ -d \"$d\" ] || mv \"$t\" \"$d\" 2>/dev/null; rm -rf \"$d/${{t##*/}}\"; fi; " ++
            "rm -rf \"$t\"; mkdir -p \"$d\"; fi",
        .{ quote(a, dir), parent, parent, same, if (keep_git) "" else "rm -rf \"$t/.git\"; ", aged(a, "\"$t\"") },
    ) catch return "rsync";
    return a.print("sh -c {s} && rsync", .{quote(a, script)}) catch "rsync";
}

/// A shell command that dates everything in folder `path` (as the shell reads it; a symlink
/// itself isn't) back by 1e9 seconds, 30 years, never to before the epoch's second day. Each
/// file's time stays apart from the others': zig's install skips a file whose size and time
/// match, and two builds' outputs dated the same could pass for each other. It fails when a date
/// can't be moved.
pub fn aged(a: std.mem.Allocator, path: []const u8) []const u8 {
    return a.print("find {s} ! -type l -exec perl -e 'for (@ARGV) {{ @s = stat or exit 1; $m = $s[9] - 1000000000; utime $s[8], ($m > 86400 ? $m : 86400), $_ or exit 1 }}' {{}} +", .{path}) catch "false";
}

/// rsync protect rules (`P`, one a line) for what a `.gitignore` in folder `dir` of the repo ("" at
/// its top) names: what a build made on the other machine (a cache, an output), kept there by
/// `--delete` whether or not it's here. A rule that can't be read as rsync's (a `\`) is skipped,
/// and a file with a `!` line keeps nothing (`*` then `!*.go` would keep every file there): it
/// only means less is kept.
pub fn kept(a: std.mem.Allocator, dir: []const u8, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| if (std.mem.startsWith(u8, std.mem.trimStart(u8, raw, " \t"), "!")) return "";
    lines.reset();
    while (lines.next()) |raw| {
        var line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or std.mem.findScalar(u8, line, '\\') != null) continue;
        const folder_only = line[line.len - 1] == '/';
        line = std.mem.trimEnd(u8, line, "/");
        if (std.mem.startsWith(u8, line, "**/")) line = line[3..];
        if (line.len == 0) continue;
        // A `/` before the end ties it to the .gitignore's folder; else it matches at any depth.
        const tied = std.mem.findScalar(u8, line, '/') != null;
        line = std.mem.trimStart(u8, line, "/");
        const tail = if (folder_only) "/" else "";
        if (tied) {
            out.print(a, "P /{s}{s}{s}{s}\n", .{ dir, if (dir.len == 0) "" else "/", line, tail }) catch break;
        } else if (dir.len == 0) {
            out.print(a, "P {s}{s}\n", .{ line, tail }) catch break;
        } else {
            out.print(a, "P /{s}/{s}{s}\nP /{s}/**/{s}{s}\n", .{ dir, line, tail, dir, line, tail }) catch break;
        }
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

test "a new copy starts as a clone of another copy of its repo, else empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try tmp.dir.realPathFileAlloc(io, ".", a);
    // A copy of the same repo, and a newer one of another.
    try tmp.dir.createDirPath(io, "s/rig-1/.git");
    try tmp.dir.writeFile(io, .{ .sub_path = "s/rig-1/.cpuq-used", .data = "rig" });
    try tmp.dir.writeFile(io, .{ .sub_path = "s/rig-1/a", .data = "x" });
    try tmp.dir.createDirPath(io, "s/other-1");
    try tmp.dir.writeFile(io, .{ .sub_path = "s/other-1/.cpuq-used", .data = "other" });
    try tmp.dir.writeFile(io, .{ .sub_path = "s/other-1/b", .data = "y" });
    // As rsync runs it, with its own arguments after: `true` stands in for rsync.
    const script = seedPath(a, "s/rig-2", "rig", false);
    const sh = try std.mem.concat(a, u8, &.{ script[0 .. script.len - "rsync".len], "true" });
    // By zsh where there is one, as a login shell there may be.
    const shell = if (Io.Dir.cwd().access(io, "/bin/zsh", .{})) |_| "/bin/zsh" else |_| "/bin/sh";
    const r = try std.process.run(a, io, .{ .argv = &.{ shell, "-c", sh }, .cwd = .{ .path = top } });
    try std.testing.expect(r.term.success());
    // Cloned where the filesystem can, else empty: never the other repo's, never the clone's
    // .git, and no scratch left beside it.
    try std.testing.expect((try tmp.dir.statFile(io, "s/rig-2", .{})).kind == .directory);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "s/rig-2/b", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "s/rig-2/.git", .{}));
    if (tmp.dir.access(io, "s/rig-2/a", .{})) |_| {
        const used = (try tmp.dir.statFile(io, "s/rig-2/.cpuq-used", .{})).mtime.nanoseconds;
        try std.testing.expect((try tmp.dir.statFile(io, "s/rig-2/a", .{})).mtime.nanoseconds < used - 29 * 365 * std.time.ns_per_day);
    } else |_| {}
    var it = (try tmp.dir.openDir(io, "s", .{ .iterate = true })).iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try std.testing.expectEqual(@as(usize, 3), n);
    // There already, a copy is left as it is.
    try tmp.dir.writeFile(io, .{ .sub_path = "s/rig-2/c", .data = "z" });
    const again = try std.process.run(a, io, .{ .argv = &.{ shell, "-c", sh }, .cwd = .{ .path = top } });
    try std.testing.expect(again.term.success());
    try tmp.dir.access(io, "s/rig-2/c", .{});
}

test "a seeded copy's files are dated 30 years back, each still apart" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const top = try tmp.dir.realPathFileAlloc(io, ".", a);
    try tmp.dir.createDirPath(io, "c/d");
    try tmp.dir.writeFile(io, .{ .sub_path = "c/d/x", .data = "x" });
    try tmp.dir.writeFile(io, .{ .sub_path = "c/y", .data = "y" });
    const sh = try std.mem.concat(a, u8, &.{ "touch -t 202601010000 c/d/x && touch -t 202601010001 c/y && ", aged(a, "c") });
    const r = try std.process.run(a, io, .{ .argv = &.{ "/bin/sh", "-c", sh }, .cwd = .{ .path = top } });
    try std.testing.expect(r.term.success());
    const x = (try tmp.dir.statFile(io, "c/d/x", .{})).mtime.nanoseconds;
    const y = (try tmp.dir.statFile(io, "c/y", .{})).mtime.nanoseconds;
    try std.testing.expectEqual(@as(i96, 60 * std.time.ns_per_s), y - x);
    try std.testing.expect(y < 800_000_000 * std.time.ns_per_s);
}

test "what .gitignore names is kept on the other machine" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("P .zig-cache/\nP /zig-out/\nP *.o\nP /a/b\nP node_modules\n", kept(a, "", "# caches\n.zig-cache/\n/zig-out/\n*.o  \na/b\n**/node_modules\n\\#x\n"));
    try std.testing.expectEqualStrings("", kept(a, "", "*\n!*.go\n!*/\n"));
    try std.testing.expectEqualStrings("P /app/build/\nP /app/**/build/\nP /app/x/y\n", kept(a, "app", "build/\n/x/y\n"));
}
