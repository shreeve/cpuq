//! The repository a job runs in: its name for history, and the git work tree around it.
const std = @import("std");
const Io = std.Io;
const place = @import("place.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");

const Ctx = main.Ctx;
const RunOptions = runopts.RunOptions;
const joinCommand = runopts.joinCommand;

/// This job's work, for history (place.workKey): its repo, else its label's project, and its
/// command.
pub fn jobWorkKey(ctx: *Ctx, o: RunOptions) []const u8 {
    return place.workKey(ctx.arena, repoOf(ctx, o) orelse std.mem.sliceTo(o.label, ':'), joinCommand(ctx, o.cmd));
}

/// The repository a job runs in, by name (its history's `repo`): `--repo`, else CPUQ_REPO, else
/// the folder holding the main `.git` above the working directory, so each worktree of a repo
/// has the repo's name. Null outside a repo. No git is run: a job's start stays quick.
pub fn repoOf(ctx: *Ctx, o: RunOptions) ?[]const u8 {
    if (o.repo) |r| return r;
    if (ctx.env.get("CPUQ_REPO")) |r| if (r.len != 0) return r;
    return repoAt(ctx, std.process.currentPathAlloc(ctx.io, ctx.arena) catch return null);
}

/// Whether `name` is one plain path component: a folder name on another machine.
pub fn safeName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '.') return false;
    return std.mem.findAny(u8, name, "/\\\x00") == null;
}

/// The name of the repo `start` is in (a worktree's, its main repo's), by the `.git` above it.
pub fn repoAt(ctx: *Ctx, start: []const u8) ?[]const u8 {
    const a = ctx.arena;
    var dir = start;
    while (true) {
        const git = a.print("{s}/.git", .{dir}) catch return null;
        if (Io.Dir.cwd().statFile(ctx.io, git, .{})) |st| {
            if (st.kind == .directory) return std.fs.path.basename(dir);
            // A worktree's `.git` file: `gitdir: /path/repo/.git/worktrees/NAME`.
            const text = Io.Dir.cwd().readFileAlloc(ctx.io, git, a, .limited(4096)) catch return std.fs.path.basename(dir);
            const at = std.mem.find(u8, text, "/.git/") orelse return std.fs.path.basename(dir);
            const top = std.mem.trim(u8, text[0..at], " \t\n");
            const name = std.fs.path.basename(if (std.mem.startsWith(u8, top, "gitdir:")) std.mem.trim(u8, top["gitdir:".len..], " ") else top);
            return if (name.len != 0 and !std.mem.eql(u8, name, "..") and !std.mem.eql(u8, name, ".")) name else std.fs.path.basename(dir);
        } else |_| {}
        dir = std.fs.path.dirname(dir) orelse return null;
    }
}

/// The top of the git work tree holding the working directory, if any.
pub fn gitTop(ctx: *Ctx) ?[]const u8 {
    return gitTopAt(ctx, ".");
}

pub fn gitTopAt(ctx: *Ctx, dir: []const u8) ?[]const u8 {
    const r = std.process.run(ctx.arena, ctx.io, .{ .argv = &.{ "git", "-C", dir, "rev-parse", "--show-toplevel" } }) catch return null;
    if (!r.term.success()) return null;
    const top = std.mem.trim(u8, r.stdout, " \n");
    return if (top.len == 0) null else top;
}
