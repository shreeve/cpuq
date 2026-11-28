//! `cpuq hook`: an agent's guard. A coding agent's harness (Claude Code's
//! PreToolUse hook) passes each shell command here before running it; a
//! command that would load the machine outside cpuq, or misuse it, is refused
//! with the corrected form, so the queue is enforced where agents act rather
//! than asked for in AGENTS.md.
//!
//! Every task of a `cpuq run` counts as one CPU, so what it runs is held to one job: `zig build
//! -j1`, `make` with no -j, `go build -p 1`, `pytest` with no -n. A build left to its own
//! parallelism takes a CPU for every job while the line counts one.
//!
//! It reads the command's text, and what the caller knows (through an Advisor): whether a `cpuq
//! run`'s work goes faster elsewhere. Nothing it cannot parse is refused. A line that ends in the
//! comment `# cpuq: skip` runs as it is.

const std = @import("std");

/// Why a command is refused, and what to run instead.
pub const Refusal = struct {
    reason: []const u8,
    instead: []const u8,
};

/// Judges a `cpuq run`'s work by its history: a refusal when it would finish far sooner elsewhere.
/// Asked only for a run on this machine (not --on or --tethered).
pub const Advisor = struct {
    ctx: *anyopaque,
    /// `cmd`: the command after `--`, its words joined by spaces.
    advise: *const fn (ctx: *anyopaque, cmd: []const u8) ?Refusal,
};

/// Whether the command points cpuq at a pool of its own (`CPUQ_DIR=...`): its runs then wait in
/// a line nobody else's are in, and the load they make falls on the machine's real line unseen.
pub fn privatePool(command: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, command, i, "CPUQ_DIR=")) |at| : (i = at + 1) {
        // The name alone, not the tail of another (MY_CPUQ_DIR=).
        if (at == 0 or !(std.ascii.isAlphanumeric(command[at - 1]) or command[at - 1] == '_')) return true;
    }
    return false;
}

test "a private pool is seen" {
    try std.testing.expect(privatePool("CPUQ_DIR=/tmp/x cpuq run -- ./burn"));
    try std.testing.expect(privatePool("export CPUQ_DIR=$TMP/pool; ./test/hunt"));
    try std.testing.expect(privatePool("env CPUQ_DIR=/tmp/p ./hunt.sh"));
    try std.testing.expect(!privatePool("MY_CPUQ_DIR=/tmp/x ./run"));
    try std.testing.expect(!privatePool("echo $CPUQ_DIR"));
}

/// Checks one shell command line. `project` names the job in suggested labels.
pub fn check(a: std.mem.Allocator, command: []const u8, project: []const u8, advisor: ?Advisor) ?Refusal {
    const ctx: Ctx = .{ .a = a, .project = project, .advisor = advisor };
    return ctx.script(command, null, 0);
}

/// The `cpuq run` and `cpuq lease` options that take a value (`-n 8`, or `--label=app:test`).
pub const run_value_options = [_][]const u8{ "--label", "--note", "--host", "--slots", "--return", "--on", "--include", "--repo", "-n", "-c", "-j", "-t", "-r", "--wait-max" };

/// The options `cpuq run` and `cpuq lease` don't take, each with what replaces it, as cpuq says
/// when given one.
pub const removed_options = [_][2][]const u8{
    .{ "--cores", "--cores is gone: every task counts as one CPU. Run M tasks with -n M (at most -c C at once); a build is one task, one job" },
    .{ "--priority", "--priority is gone: --urgent puts a run's first CPU ahead of the line; there is no low" },
    .{ "--max-wait", "--max-wait is now --wait-max" },
    .{ "--exclusive", "--exclusive is gone: `cpuq drain -c N -- CMD` times CMD on N CPUs of its own, isolated at once" },
    .{ "--no-load-check", "--no-load-check is gone: the pool limits CPU work, and outside load is measured" },
    .{ "--qos", "--qos is gone: tasks run as they are" },
    .{ "--opaque", "--opaque is gone: every task counts as one CPU, inside a container or not" },
    .{ "-x", "-x is gone: cpuq starts more tasks when its tasks wait (I/O, sleep, a server); drop -x" },
};

/// `--exclusive`, given to `cpuq lease`.
pub const lease_exclusive = "--exclusive is gone: `cpuq lease NAME -- cpuq drain -c N -- CMD` holds the lease and times CMD on N CPUs of its own";

/// The removed options that took a value: skipped with it.
const removed_value_options = [_][]const u8{ "--cores", "--priority", "--max-wait", "--qos", "-x" };

/// What one check knows: the project for suggested labels, and the advisor for the `cpuq run`s on
/// this machine.
const Ctx = struct {
    a: std.mem.Allocator,
    project: []const u8,
    advisor: ?Advisor,

    fn script(ctx: Ctx, text: []const u8, host: ?[]const u8, depth: u32) ?Refusal {
        if (depth > 3) return null;
        const cmds = split(ctx.a, text) catch return null;
        for (cmds) |cmd| if (!cmd.skip) if (ctx.simple(cmd, host, depth)) |r| return r;
        return null;
    }

    fn simple(ctx: Ctx, cmd: Simple, host: ?[]const u8, depth: u32) ?Refusal {
        const a = ctx.a;
        const w = stripWrappers(cmd.words);
        if (w.len == 0) return null;
        const prog = std.fs.path.basename(w[0]);
        if (std.mem.eql(u8, prog, "cpuq")) return checkCpuq(a, cmd, w, if (host == null) ctx.advisor else null);
        if (std.mem.eql(u8, prog, "ssh")) {
            const remote = sshRemote(a, w) orelse return null;
            // `ssh HOST <<EOF`: the heredoc is the script HOST runs.
            const body = if (remote.command.len == 0) cmd.heredoc orelse return null else remote.command;
            return ctx.script(body, remote.host, depth + 1);
        }
        if (isShell(prog)) {
            if (shellScript(w)) |s| return ctx.script(s, host, depth + 1);
            if (cmd.heredoc) |body| return ctx.script(body, host, depth + 1);
        }
        // A benchmark outside cpuq: other work shares its CPUs, so its numbers are noise.
        if (benchName(a, w)) |what| return .{
            .reason = a.print("`{s}` is a benchmark run outside cpuq: other work shares its CPUs and skews its numbers, and it is scheduled around nothing", .{what}) catch "a benchmark runs outside cpuq",
            .instead = a.print("cpuq drain -c 1 -t 20m --label {s}:bench -- {s} (-c as many CPUs as it times on; -t about ten times its run)", .{ if (ctx.project.len != 0) ctx.project else "proj", joinQuoted(a, w) }) catch "cpuq drain -c N -t T -- CMD",
        };
        const heavy_prog = heavyName(w) orelse return null;
        // "zig build", "cargo test": the program and its subcommand.
        const heavy = if (std.mem.eql(u8, heavy_prog, prog)) toolLabel(a, w) else heavy_prog;
        const where = if (host) |h| a.print(" on {s}, through {s}'s cpuq", .{ h, h }) catch "" else "";
        return .{
            .reason = a.print("`{s}` runs outside cpuq{s}, so the other sessions' work can't be scheduled around it, and it uses as many CPUs as it likes", .{ heavy, where }) catch "a heavy command runs outside cpuq",
            .instead = suggest(a, w, ctx.project, host),
        };
    }
};

/// A simple command: its words, unquoted, and its text as written.
const Simple = struct {
    words: []const []const u8,
    text: []const u8,
    /// The body of a heredoc (`<<EOF` … `EOF`) on its line: data, checked only when a shell or
    /// ssh reads it as a script (`sh <<EOF`, `ssh host <<EOF`).
    heredoc: ?[]const u8 = null,
    /// On a line that ends in the comment `# cpuq: skip`: not checked.
    skip: bool = false,
};

/// A `cpuq run` (or lease): no removed option and no `$CPUQ_CORES`, one job for each task (one
/// CPU), and `--driver` only for a test runner.
fn checkCpuq(a: std.mem.Allocator, cmd: Simple, w: []const []const u8, advisor: ?Advisor) ?Refusal {
    if (w.len < 2) return null;
    const lease = std.mem.eql(u8, w[1], "lease");
    if (!lease and !std.mem.eql(u8, w[1], "run")) return null;
    var removed: ?[]const u8 = null;
    var elsewhere = false;
    var tethered = false;
    var driver = false;
    // `-j K`: each task holds K tokens, so its command may run K jobs.
    var width: u32 = 1;
    // A lease's name comes first.
    var i: usize = if (lease) 3 else 2;
    while (i < w.len) : (i += 1) {
        const o = w[i];
        if (std.mem.eql(u8, o, "--")) {
            i += 1;
            break;
        }
        if (o.len == 0 or o[0] != '-') break;
        const name = std.mem.sliceTo(o, '=');
        if (removed == null) removed = removedWhy(name, lease);
        // Sent to another machine, or what --on runs there: not this machine's history.
        if (std.mem.eql(u8, name, "--on")) elsewhere = true;
        if (std.mem.eql(u8, name, "--tethered")) tethered = true;
        if (std.mem.eql(u8, name, "--driver")) driver = true;
        if (!lease and std.mem.eql(u8, name, "-j")) {
            const v = if (name.len < o.len) o[name.len + 1 ..] else if (i + 1 < w.len) w[i + 1] else "";
            width = std.fmt.parseInt(u32, v, 10) catch 1;
        }
        // Options that take a value skip it.
        if (name.len == o.len and takesValue(name)) i += 1;
    }
    if (removed) |why| return .{ .reason = why, .instead = fixRun(a, w, false).text };
    if (mentionsCores(cmd.text)) return .{
        .reason = "cpuq counts each task as one CPU; there is no $CPUQ_CORES",
        .instead = fixRun(a, w, false).text,
    };
    if (i >= w.len) return null;
    const inner = stripWrappers(w[i..]);
    if (inner.len == 0) return null;
    const cmds = innerCommands(a, inner, cmd.heredoc) orelse return null;
    if (driver) {
        if (checkDriver(a, w, inner)) |r| return r;
    } else for (cmds) |ic| {
        const iw = stripWrappers(ic.words);
        if (iw.len == 0 or heavyName(iw) == null) continue;
        const what = tooParallel(a, iw, width) orelse continue;
        const fixed = fixRun(a, w, false);
        const more = " (or split the work into tasks with -n M)";
        return .{
            .reason = if (width > 1)
                a.print("{s}, but each task holds {d} CPUs (-j {d})", .{ what, width, width }) catch "a task holds -j CPUs"
            else
                a.print("{s}, but a task counts as one CPU", .{what}) catch "a task counts as one CPU",
            .instead = if (fixed.whole)
                a.print("{s}{s}", .{ fixed.text, more }) catch fixed.text
            else
                a.print("`{s}` in its script{s}", .{ joinQuoted(a, oneJob(a, iw)), more }) catch "one job: -j1",
        };
    }
    // Long work that finishes far sooner elsewhere, of a run that may move.
    if (advisor) |ad| if (!lease and !elsewhere and !tethered) {
        return ad.advise(ad.ctx, std.mem.join(a, " ", inner) catch return null);
    };
    return null;
}

/// What cpuq says of a removed option, or null.
fn removedWhy(name: []const u8, lease: bool) ?[]const u8 {
    if (lease and std.mem.eql(u8, name, "--exclusive")) return lease_exclusive;
    for (removed_options) |r| if (std.mem.eql(u8, name, r[0])) return r[1];
    return null;
}

fn takesValue(name: []const u8) bool {
    for (run_value_options) |v| if (std.mem.eql(u8, name, v)) return true;
    for (removed_value_options) |v| if (std.mem.eql(u8, name, v)) return true;
    return false;
}

/// Whether a command uses `$CPUQ_CORES` (or `${CPUQ_CORES}`), quoted or not.
fn mentionsCores(text: []const u8) bool {
    return std.mem.find(u8, text, "$CPUQ_CORES") != null or std.mem.find(u8, text, "${CPUQ_CORES") != null;
}

/// A word with every `$CPUQ_CORES` in it, quoted or not, made 1: one job.
fn noCores(a: std.mem.Allocator, x: []const u8) []const u8 {
    var out = x;
    for ([_][]const u8{ "\"$CPUQ_CORES\"", "\"${CPUQ_CORES}\"", "${CPUQ_CORES}", "$CPUQ_CORES" }) |form| {
        if (std.mem.find(u8, out, form) == null) continue;
        out = std.mem.replaceOwned(u8, a, out, form, "1") catch return out;
    }
    return out;
}

/// The simple commands a run's command is: a shell's script (`sh -c '…'`, `sh <<EOF`), else
/// the command itself.
fn innerCommands(a: std.mem.Allocator, inner: []const []const u8, heredoc: ?[]const u8) ?[]const Simple {
    if (isShell(std.fs.path.basename(inner[0]))) {
        if (shellScript(inner)) |s| return split(a, s) catch null;
        if (inner.len == 1) if (heredoc) |body| return split(a, body) catch null;
    }
    const one = a.alloc(Simple, 1) catch return null;
    one[0] = .{ .words = inner, .text = "" };
    return one;
}

/// `--driver`: a runner that starts its own `cpuq run`s, and is no task itself. Any command may
/// be one: what it computes itself counts against its project's share (status flags it). Only a
/// bare build directly under it is refused: a build is a task, and belongs in the line as one.
fn checkDriver(a: std.mem.Allocator, w: []const []const u8, inner: []const []const u8) ?Refusal {
    const prog = std.fs.path.basename(inner[0]);
    const builds = for ([_][]const u8{ "zig", "cargo", "make", "gmake", "go", "swift", "xcodebuild" }) |b| {
        if (std.mem.eql(u8, prog, b)) break true;
    } else false;
    if (!builds or heavyName(inner) == null) return null;
    return .{
        .reason = a.print("`{s}` directly under --driver: a build is a task, not a runner, so run it as one", .{toolLabel(a, inner)}) catch "a build under --driver: run it as a task",
        .instead = fixRun(a, w, true).text,
    };
}

/// How a heavy command runs more jobs at once than its task's `width` tokens (one, unless the run
/// has -j K), or null when it runs no more (or sets a count it can't read, such as `-j"$N"`).
fn tooParallel(a: std.mem.Allocator, w: []const []const u8, width: u32) ?[]const u8 {
    const tool = toolOf(w);
    var i: usize = 1;
    while (i < w.len) : (i += 1) {
        if (std.mem.eql(u8, w[i], "--")) break;
        const j = jobsAt(tool, w, i) orelse continue;
        const text = std.mem.join(a, " ", w[i .. i + j.words]) catch w[i];
        if (std.fmt.parseInt(u32, j.value, 10)) |n| {
            // `pytest -n 0` runs the tests in its own process.
            if ((n >= 1 and n <= width) or (n == 0 and isSerial(tool))) return null;
            if (n == 0) return a.print("`{s}` sets no limit on jobs", .{text}) catch text;
            return a.print("`{s}` runs {d} jobs at once", .{ text, n }) catch text;
        } else |_| {
            if (j.value.len == 0 or std.mem.eql(u8, j.value, "auto") or std.mem.eql(u8, j.value, "logical"))
                return a.print("`{s}` sets no limit on jobs", .{text}) catch text;
            return null;
        }
    }
    const oj = oneJobOption(w) orelse return null;
    return a.print("`{s}` without {s} runs a job for every CPU", .{ toolLabel(a, w), std.mem.join(a, " ", oj.option) catch "-j1" }) catch "a job for every CPU";
}

/// "zig build", "cargo test", "cmake --build": the program and its subcommand, for messages.
fn toolLabel(a: std.mem.Allocator, w: []const []const u8) []const u8 {
    const prog = std.fs.path.basename(w[0]);
    if (w.len > 1 and w[1].len > 0 and (isSubTool(prog) and w[1][0] != '-' or std.mem.eql(u8, prog, "cmake")))
        return a.print("{s} {s}", .{ prog, w[1] }) catch prog;
    return prog;
}

/// The tool a heavy command runs: `pytest` for `python3 -m pytest`, else the program.
fn toolOf(w: []const []const u8) []const u8 {
    const prog = std.fs.path.basename(w[0]);
    if (isPython(prog) and w.len >= 3 and std.mem.eql(u8, w[1], "-m")) return w[2];
    return prog;
}

/// A tool that runs one job unless told otherwise: its jobs option is dropped, not set to 1.
fn isSerial(tool: []const u8) bool {
    for ([_][]const u8{ "make", "gmake", "pytest", "py.test", "ctest" }) |t| if (std.mem.eql(u8, tool, t)) return true;
    return false;
}

/// A tool that runs a job for every CPU unless told otherwise: the option that holds it to one,
/// and whether it goes right after the subcommand (`go build -p 1 ./...`) or at the end.
const OneJob = struct { tool: []const u8, sub: []const u8 = "", option: []const []const u8, after_sub: bool = false };

const one_job = [_]OneJob{
    .{ .tool = "zig", .sub = "build", .option = &.{"-j1"} },
    .{ .tool = "cargo", .option = &.{ "-j", "1" }, .after_sub = true },
    .{ .tool = "swift", .option = &.{ "-j", "1" }, .after_sub = true },
    .{ .tool = "go", .option = &.{ "-p", "1" }, .after_sub = true },
    .{ .tool = "bazel", .option = &.{"--jobs=1"}, .after_sub = true },
    .{ .tool = "bazelisk", .option = &.{"--jobs=1"}, .after_sub = true },
    .{ .tool = "meson", .sub = "compile", .option = &.{ "-j", "1" }, .after_sub = true },
    .{ .tool = "ninja", .option = &.{ "-j", "1" } },
    .{ .tool = "cmake", .option = &.{ "-j", "1" } },
    .{ .tool = "xcodebuild", .option = &.{ "-jobs", "1" } },
};

fn oneJobOption(w: []const []const u8) ?OneJob {
    const tool = toolOf(w);
    for (one_job) |oj| {
        if (!std.mem.eql(u8, oj.tool, tool)) continue;
        if (oj.sub.len != 0 and !(w.len > 1 and std.mem.eql(u8, w[1], oj.sub))) continue;
        return oj;
    }
    return null;
}

/// Where a tool's subcommand is: `cargo +nightly build` has its toolchain first.
fn subAt(w: []const []const u8) usize {
    return if (std.mem.eql(u8, std.fs.path.basename(w[0]), "cargo") and w.len >= 2 and std.mem.startsWith(u8, w[1], "+")) 2 else 1;
}

/// The words the tool's jobs option takes at `w[i]` (`-j8`: 1, `-j 8`: 2), with its value; null
/// when `w[i]` is none. A bare `-j` (make's no limit) has the value "".
const Jobs = struct {
    words: usize,
    value: []const u8,
    flag: []const u8,
    form: enum { equals, attached, separate, bare },

    /// The same option set to one job.
    fn one(j: Jobs, a: std.mem.Allocator) []const []const u8 {
        const joined = switch (j.form) {
            .equals => a.print("{s}=1", .{j.flag}) catch return &.{},
            .attached => a.print("{s}1", .{j.flag}) catch return &.{},
            .separate, .bare => if (std.mem.eql(u8, j.flag, "-j")) "-j1" else return a.dupe([]const u8, &.{ j.flag, "1" }) catch &.{},
        };
        return a.dupe([]const u8, &.{joined}) catch &.{};
    }
};

fn jobsAt(tool: []const u8, w: []const []const u8, i: usize) ?Jobs {
    const x = w[i];
    const Flag = struct { tool: []const u8, flag: []const u8 };
    const flags = [_]Flag{
        .{ .tool = "go", .flag = "-p" },
        .{ .tool = "pytest", .flag = "-n" },
        .{ .tool = "pytest", .flag = "--numprocesses" },
        .{ .tool = "xcodebuild", .flag = "-jobs" },
        .{ .tool = "cmake", .flag = "--parallel" },
        .{ .tool = "ctest", .flag = "--parallel" },
        .{ .tool = "", .flag = "-j" },
        .{ .tool = "", .flag = "--jobs" },
    };
    for (flags) |f| {
        if (f.tool.len != 0 and !std.mem.eql(u8, f.tool, tool)) continue;
        if (!std.mem.startsWith(u8, x, f.flag)) continue;
        const rest = x[f.flag.len..];
        if (rest.len != 0) {
            // `-j8`, `--jobs=8`; a short flag's value may be attached, a long one's follows `=`.
            if (rest[0] == '=') return .{ .words = 1, .value = rest[1..], .flag = f.flag, .form = .equals };
            if (f.flag[1] != '-' and f.flag.len == 2) return .{ .words = 1, .value = rest, .flag = f.flag, .form = .attached };
            continue;
        }
        // The value in the next word, unless that is another option or (for -j) a target.
        if (i + 1 < w.len and w[i + 1].len != 0 and w[i + 1][0] != '-') {
            const v = w[i + 1];
            const numeric = std.fmt.parseInt(u32, v, 10) catch null;
            if (numeric != null or mentionsCores(v) or !std.mem.eql(u8, f.flag, "-j")) return .{ .words = 2, .value = v, .flag = f.flag, .form = .separate };
        }
        return .{ .words = 1, .value = "", .flag = f.flag, .form = .bare };
    }
    return null;
}

/// A heavy command held to one job: its jobs option dropped (make, pytest: one job is their
/// own default) or set to 1, or the option that holds it to one added.
fn oneJob(a: std.mem.Allocator, w: []const []const u8) []const []const u8 {
    const tool = toolOf(w);
    var out: std.ArrayList([]const u8) = .empty;
    var found = false;
    var args_end: ?usize = null;
    var i: usize = 0;
    while (i < w.len) : (i += 1) {
        if (i > 0 and args_end == null) if (jobsAt(tool, w, i)) |j| {
            found = true;
            i += j.words - 1;
            if (!isSerial(tool)) out.appendSlice(a, j.one(a)) catch {};
            continue;
        };
        if (args_end == null and std.mem.eql(u8, w[i], "--")) args_end = out.items.len;
        out.append(a, w[i]) catch return w;
    }
    if (!found) if (oneJobOption(w)) |oj| {
        // Before the redirections (`zig build >log 2>&1`) and the arguments after `--`.
        const end = @min(firstRedirect(out.items), args_end orelse out.items.len);
        const at = if (oj.after_sub) @min(subAt(w) + 1, end) else end;
        out.insertSlice(a, at, oj.option) catch return w;
    };
    return out.items;
}

/// A corrected `cpuq run` (or lease): its removed options dropped or replaced (`--exclusive`
/// becomes `cpuq drain`), `$CPUQ_CORES` made 1, and its command held to one job. `whole`: the
/// command itself was corrected, not left in a script of several commands.
const FixedRun = struct { text: []const u8, whole: bool };

fn fixRun(a: std.mem.Allocator, w: []const []const u8, drop_driver: bool) FixedRun {
    const lease = std.mem.eql(u8, w[1], "lease");
    var opts: std.ArrayList([]const u8) = .empty;
    var drain = false;
    var label: ?[]const u8 = null;
    var wait: ?[]const u8 = null;
    var i: usize = if (lease) @min(3, w.len) else 2;
    while (i < w.len) : (i += 1) {
        const o = w[i];
        if (std.mem.eql(u8, o, "--")) {
            i += 1;
            break;
        }
        if (o.len == 0 or o[0] != '-') break;
        const name = std.mem.sliceTo(o, '=');
        const attached = name.len != o.len;
        var value: ?[]const u8 = if (attached) o[name.len + 1 ..] else null;
        if (!attached and takesValue(name) and i + 1 < w.len) {
            i += 1;
            value = w[i];
        }
        if (std.mem.eql(u8, name, "--exclusive")) {
            drain = true;
            continue;
        }
        if (std.mem.eql(u8, name, "--max-wait")) {
            wait = value;
            if (value) |v| opts.appendSlice(a, &.{ "--wait-max", v }) catch {};
            continue;
        }
        if (removedWhy(name, false) != null) continue;
        if (drop_driver and std.mem.eql(u8, name, "--driver")) continue;
        if (std.mem.eql(u8, name, "--label")) label = value;
        opts.append(a, o) catch {};
        if (!attached) if (value) |v| opts.append(a, v) catch {};
    }
    const fixed = fixInner(a, w[i..]);
    var words: std.ArrayList([]const u8) = .empty;
    if (drain and !lease) {
        // A run held alone: `cpuq drain`, which takes a label and a time to wait.
        words.appendSlice(a, &.{ "cpuq", "drain", "-c", "1" }) catch {};
        if (label) |l| words.appendSlice(a, &.{ "--label", l }) catch {};
        if (wait) |s| words.appendSlice(a, &.{ "--max", a.print("{s}s", .{s}) catch s }) catch {};
    } else {
        words.appendSlice(a, w[0..if (lease) @min(3, w.len) else 2]) catch {};
        words.appendSlice(a, opts.items) catch {};
    }
    if (fixed.words.len != 0) {
        words.append(a, "--") catch {};
        if (drain and lease) words.appendSlice(a, &.{ "cpuq", "drain", "-c", "1", "--" }) catch {};
        words.appendSlice(a, fixed.words) catch {};
    }
    return .{ .text = joinQuoted(a, words.items), .whole = fixed.whole };
}

const FixedCommand = struct { words: []const []const u8, whole: bool };

/// A run's command with `$CPUQ_CORES` made 1 and held to one job. A script of one plain command
/// (`sh -c 'zig build test'`) is unwrapped to it; a script of several is kept.
fn fixInner(a: std.mem.Allocator, cmd: []const []const u8) FixedCommand {
    const out = a.alloc([]const u8, cmd.len) catch return .{ .words = cmd, .whole = false };
    for (cmd, out) |x, *o| o.* = noCores(a, x);
    const inner = stripWrappers(out);
    if (inner.len == 0) return .{ .words = out, .whole = true };
    const prefix = out[0 .. out.len - inner.len];
    if (isShell(std.fs.path.basename(inner[0]))) {
        const s = shellScript(inner) orelse return .{ .words = out, .whole = true };
        const words = unwrapped(a, s) orelse return .{ .words = out, .whole = false };
        const f = fixInner(a, words);
        return .{ .words = std.mem.concat(a, []const u8, &.{ prefix, f.words }) catch out, .whole = f.whole };
    }
    if (heavyName(inner) == null) return .{ .words = out, .whole = true };
    return .{ .words = std.mem.concat(a, []const u8, &.{ prefix, oneJob(a, inner) }) catch out, .whole = true };
}

/// The words of a script that is one command and nothing else the shell would expand or join to
/// it, or null.
fn unwrapped(a: std.mem.Allocator, script: []const u8) ?[]const []const u8 {
    if (std.mem.findAny(u8, script, "$`*?[~{\n") != null) return null;
    const cmds = split(a, script) catch return null;
    if (cmds.len != 1 or cmds[0].heredoc != null) return null;
    // `a &`, `a # note`: more than the command.
    if (!std.mem.eql(u8, std.mem.trim(u8, cmds[0].text, " \t"), std.mem.trim(u8, script, " \t"))) return null;
    return cmds[0].words;
}

/// Words joined into a line the shell reads back as them.
fn joinQuoted(a: std.mem.Allocator, words: []const []const u8) []const u8 {
    var line: std.ArrayList(u8) = .empty;
    for (words, 0..) |x, n| {
        if (n != 0) line.append(a, ' ') catch {};
        line.appendSlice(a, quoteWord(a, x)) catch {};
    }
    return line.items;
}

/// The heavy command a simple command is, by its program and first word;
/// null for anything else, and for a heavy program asked only for help, a
/// version or a dry run.
fn heavyName(w: []const []const u8) ?[]const u8 {
    const prog = std.fs.path.basename(w[0]);
    // `cargo +nightly build`: the toolchain comes before the subcommand.
    const sub_at: usize = if (std.mem.eql(u8, prog, "cargo") and w.len >= 2 and std.mem.startsWith(u8, w[1], "+")) 2 else 1;
    const sub = if (w.len > sub_at) w[sub_at] else "";
    // Help, a version, a dry run or a listing: no work.
    const make_like = std.mem.eql(u8, prog, "make") or std.mem.eql(u8, prog, "gmake");
    const no_work: []const []const u8 = if (make_like)
        &.{ "-n", "--dry-run", "--just-print", "--recon", "-q", "--question", "-p", "--print-data-base" }
    else if (std.mem.eql(u8, prog, "ninja"))
        &.{ "-n", "-t" }
    else if (std.mem.eql(u8, prog, "xcodebuild"))
        &.{ "-list", "-showsdks", "-showBuildSettings", "-showdestinations", "-version", "-showTestPlans" }
    else if (std.mem.eql(u8, prog, "swift"))
        &.{ "--show-bin-path", "--show-codecov-path" }
    else
        &.{};
    for (w[1..]) |x| {
        for ([_][]const u8{ "--help", "-h", "--version", "-version" }) |q| if (std.mem.eql(u8, x, q)) return null;
        for (no_work) |q| if (std.mem.eql(u8, x, q)) return null;
    }
    const Heavy = struct { prog: []const u8, subs: []const []const u8 };
    const table = [_]Heavy{
        .{ .prog = "zig", .subs = &.{ "build", "test", "build-exe", "build-lib", "build-obj" } },
        .{ .prog = "cargo", .subs = &.{ "build", "b", "test", "t", "check", "c", "clippy", "run", "r", "bench", "nextest", "doc", "install", "miri" } },
        .{ .prog = "swift", .subs = &.{ "build", "test", "run" } },
        .{ .prog = "go", .subs = &.{ "build", "test", "install" } },
        .{ .prog = "bazel", .subs = &.{ "build", "test", "run", "coverage" } },
        .{ .prog = "bazelisk", .subs = &.{ "build", "test", "run", "coverage" } },
        .{ .prog = "buck2", .subs = &.{ "build", "test", "run" } },
        .{ .prog = "cmake", .subs = &.{"--build"} },
        .{ .prog = "meson", .subs = &.{ "compile", "test" } },
        .{ .prog = "python", .subs = &.{"-m"} },
    };
    // python, python3, python3.12: one entry.
    const name = if (isPython(prog)) "python" else prog;
    for (table) |h| if (std.mem.eql(u8, name, h.prog)) {
        for (h.subs) |s| if (std.mem.eql(u8, sub, s)) {
            if (std.mem.eql(u8, s, "-m")) {
                if (w.len >= 3 and std.mem.eql(u8, w[2], "pytest")) return "python -m pytest";
                return null;
            }
            return prog;
        };
        return null;
    };
    for ([_][]const u8{ "make", "gmake", "ninja", "xcodebuild", "pytest", "py.test", "gradle", "gradlew", "mvn", "mvnw", "ctest", "tox" }) |p| {
        if (std.mem.eql(u8, prog, p)) return p;
    }
    return null;
}

/// A program that runs the command after its options: its short options that take a value, its
/// long ones that do, whether one more word (a duration, a CPU list) comes before the command,
/// and the short options that only look a command up or report (`command -v`, `sudo -l`).
const Wrapper = struct {
    name: []const u8,
    /// Only with this first word (`uv run`).
    sub: []const u8 = "",
    takes: []const u8 = "",
    long: []const []const u8 = &.{},
    positional: bool = false,
    lookup: []const u8 = "",
};

const wrappers = [_]Wrapper{
    .{ .name = "nice", .takes = "n", .long = &.{"--adjustment"} },
    .{ .name = "time", .takes = "fo", .long = &.{ "--format", "--output" } },
    .{ .name = "env", .takes = "uCPS", .long = &.{ "--unset", "--chdir", "--split-string" } },
    .{ .name = "exec", .takes = "a" },
    .{ .name = "command", .lookup = "vV" },
    .{ .name = "nohup" },
    .{ .name = "caffeinate", .takes = "tw" },
    .{ .name = "stdbuf", .takes = "ioe", .long = &.{ "--input", "--output", "--error" } },
    .{ .name = "timeout", .takes = "ks", .long = &.{ "--kill-after", "--signal" }, .positional = true },
    .{ .name = "nocache" },
    .{ .name = "ionice", .takes = "cnp", .long = &.{ "--class", "--classdata" } },
    .{ .name = "chrt", .takes = "TPD", .positional = true, .lookup = "p" },
    .{ .name = "taskset", .positional = true, .lookup = "p" },
    .{ .name = "unbuffer" },
    .{ .name = "sudo", .takes = "ugCDprtUT", .long = &.{ "--user", "--group", "--chdir", "--prompt", "--role", "--type", "--other-user" }, .lookup = "lvVK" },
    .{ .name = "doas", .takes = "uC" },
    .{ .name = "xargs", .takes = "IdELnPsa", .long = &.{ "--delimiter", "--max-args", "--max-procs", "--arg-file" } },
    .{ .name = "xcrun", .long = &.{ "--sdk", "--toolchain" }, .lookup = "f" },
    .{ .name = "uv", .sub = "run", .long = &.{ "--with", "--python", "--project", "--directory", "--package" } },
    .{ .name = "poetry", .sub = "run" },
    .{ .name = "pipenv", .sub = "run" },
};

/// Words that begin a command without being one: shell keywords and groupings.
const keywords = [_][]const u8{ "if", "then", "elif", "else", "do", "while", "until", "!", "{" };

/// Skips what only wraps a command: shell keywords (`if`, `{`, `!`), variable assignments, and
/// the wrappers above with their options. A lookup (`command -v make`) leaves nothing.
fn stripWrappers(words: []const []const u8) []const []const u8 {
    var w = words;
    outer: while (w.len > 0) {
        const x = w[0];
        if (isAssignment(x)) {
            w = w[1..];
            continue;
        }
        for (keywords) |k| if (std.mem.eql(u8, x, k)) {
            w = w[1..];
            continue :outer;
        };
        const prog = std.fs.path.basename(x);
        // `cpuq cap` limits one program but neither queues it nor takes cores:
        // what it runs is judged as if typed alone.
        if (std.mem.eql(u8, prog, "cpuq") and w.len > 1 and std.mem.eql(u8, w[1], "cap")) {
            w = w[2..];
            while (w.len > 0 and w[0].len > 1 and w[0][0] == '-') {
                const opt = w[0];
                w = w[1..];
                if (std.mem.eql(u8, opt, "--")) break;
                for ([_][]const u8{ "--mem", "--time", "--output", "--pids" }) |takes| {
                    if (std.mem.eql(u8, opt, takes) and w.len > 0) w = w[1..];
                }
            }
            continue;
        }
        const wr = for (wrappers) |wr| {
            if (!std.mem.eql(u8, prog, wr.name)) continue;
            if (wr.sub.len != 0 and !(w.len > 1 and std.mem.eql(u8, w[1], wr.sub))) continue;
            break wr;
        } else break;
        w = w[if (wr.sub.len != 0) 2 else 1..];
        while (w.len > 0 and w[0].len > 1 and (w[0][0] == '-' or (std.mem.eql(u8, wr.name, "env") and isAssignment(w[0])))) {
            const opt = w[0];
            w = w[1..];
            if (std.mem.eql(u8, opt, "--")) break;
            if (opt[0] != '-') continue;
            if (opt[1] == '-') {
                for (wr.long) |l| if (std.mem.eql(u8, opt, l) and w.len > 0) {
                    w = w[1..];
                };
                continue;
            }
            // A cluster of short options: one that takes a value ends it, with the value
            // attached or in the next word.
            for (opt[1..], 1..) |ch, k| {
                if (std.mem.findScalar(u8, wr.lookup, ch) != null) return &.{};
                if (std.mem.findScalar(u8, wr.takes, ch) != null) {
                    if (k == opt.len - 1 and w.len > 0) w = w[1..];
                    break;
                }
            }
        }
        // env's assignments after its options.
        while (w.len > 0 and isAssignment(w[0])) w = w[1..];
        if (wr.positional and w.len > 0) w = w[1..];
    }
    return w;
}

/// Programs whose first word is a subcommand (`cargo test`).
fn isSubTool(prog: []const u8) bool {
    for ([_][]const u8{ "zig", "cargo", "swift", "go", "bazel", "bazelisk", "buck2" }) |p| if (std.mem.eql(u8, prog, p)) return true;
    return false;
}

fn isAssignment(x: []const u8) bool {
    const eq = std.mem.findScalar(u8, x, '=') orelse return false;
    if (eq == 0) return false;
    for (x[0..eq]) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return false;
    return !std.ascii.isDigit(x[0]);
}

/// A benchmark, named as the hook refuses it outside cpuq: `hyperfine`, `cargo bench`, `zig build
/// bench`, or a script with "bench" in its name run by node, bun, deno or python; else null.
fn benchName(a: std.mem.Allocator, w: []const []const u8) ?[]const u8 {
    const prog = std.fs.path.basename(w[0]);
    for (w[1..]) |x| for ([_][]const u8{ "--help", "-h", "--version" }) |q| if (std.mem.eql(u8, x, q)) return null;
    if (std.mem.eql(u8, prog, "hyperfine")) return "hyperfine";
    if (std.mem.eql(u8, prog, "cargo")) {
        const at: usize = if (w.len >= 2 and std.mem.startsWith(u8, w[1], "+")) 2 else 1;
        if (w.len > at and std.mem.eql(u8, w[at], "bench")) return "cargo bench";
        return null;
    }
    if (std.mem.eql(u8, prog, "zig")) {
        if (w.len < 2 or !std.mem.eql(u8, w[1], "build")) return null;
        for (w[2..]) |x| if (std.mem.eql(u8, x, "bench")) return "zig build bench";
        return null;
    }
    const runner = isPython(prog) or std.mem.eql(u8, prog, "node") or std.mem.eql(u8, prog, "bun") or std.mem.eql(u8, prog, "deno");
    if (!runner) return null;
    // The script: the first word that is no option (bun's and deno's `run` passed over).
    for (w[1..]) |x| {
        if (x.len == 0 or x[0] == '-') continue;
        if (std.mem.eql(u8, x, "run") and !isPython(prog) and !std.mem.eql(u8, prog, "node")) continue;
        // The script's own name, not its folder: tools/bench/score only reads results.
        if (std.mem.indexOf(u8, std.fs.path.basename(x), "bench") == null) return null;
        return a.print("{s} {s}", .{ prog, x }) catch prog;
    }
    return null;
}

fn isPython(prog: []const u8) bool {
    if (!std.mem.startsWith(u8, prog, "python")) return false;
    for (prog["python".len..]) |ch| if (!std.ascii.isDigit(ch) and ch != '.') return false;
    return true;
}

fn isShell(prog: []const u8) bool {
    for ([_][]const u8{ "sh", "bash", "zsh", "dash" }) |s| if (std.mem.eql(u8, prog, s)) return true;
    return false;
}

/// The script of `sh -c SCRIPT` (or -lc, -ec, `-o pipefail -c` …).
fn shellScript(w: []const []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < w.len) : (i += 1) {
        const x = w[i];
        if (std.mem.eql(u8, x, "-o") or std.mem.eql(u8, x, "+o")) {
            i += 1;
            continue;
        }
        if (x.len > 1 and x[0] == '-' and std.mem.findScalar(u8, x, 'c') != null and x[1] != '-') return if (i + 1 < w.len) w[i + 1] else null;
        if (x.len == 0 or (x[0] != '-' and x[0] != '+')) return null;
    }
    return null;
}

const Remote = struct { host: []const u8, command: []const u8 };

/// `ssh [options] HOST COMMAND…`: the host and the command it runs there.
fn sshRemote(a: std.mem.Allocator, w: []const []const u8) ?Remote {
    var i: usize = 1;
    while (i < w.len) : (i += 1) {
        const x = w[i];
        if (x.len > 1 and x[0] == '-') {
            // Options that take a value.
            if (x.len == 2 and std.mem.findScalar(u8, "BbcDEeFIiJLlmOoPpQRSWw", x[1]) != null) i += 1;
            continue;
        }
        // No command: a login, or a script on stdin (a heredoc).
        if (i + 1 >= w.len) return .{ .host = x, .command = "" };
        return .{ .host = x, .command = std.mem.join(a, " ", w[i + 1 ..]) catch return null };
    }
    return null;
}

/// The index of the first word that redirects (`>log`, `2>`, `<in`, `&>x`), or `w.len`.
fn firstRedirect(w: []const []const u8) usize {
    for (w, 0..) |x, i| {
        var j: usize = 0;
        while (j < x.len and std.ascii.isDigit(x[j])) j += 1;
        if (j < x.len and (x[j] == '>' or x[j] == '<')) return i;
        if (std.mem.startsWith(u8, x, "&>")) return i;
    }
    return w.len;
}

/// A word as the shell reads it back: bare when it needs no quotes, else in double quotes (or
/// single, when it holds what double quotes expand).
fn quoteWord(a: std.mem.Allocator, x: []const u8) []const u8 {
    const plain = x.len != 0 and for (x) |ch| {
        if (!(std.ascii.isAlphanumeric(ch) or std.mem.findScalar(u8, "_-./=:,+@%^~<>&", ch) != null)) break false;
    } else true;
    if (plain) return x;
    if (std.mem.findAny(u8, x, "\"$`\\") == null) return a.print("\"{s}\"", .{x}) catch x;
    return singleQuoted(a, x);
}

/// `text` in single quotes, each `'` in it written `'\''`.
fn singleQuoted(a: std.mem.Allocator, text: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.append(a, '\'') catch return text;
    for (text) |ch| {
        if (ch == '\'') out.appendSlice(a, "'\\''") catch return text else out.append(a, ch) catch return text;
    }
    out.append(a, '\'') catch return text;
    return out.items;
}

/// What to run instead: the command under cpuq, held to one job for its task (one CPU).
fn suggest(a: std.mem.Allocator, w: []const []const u8, project: []const u8, host: ?[]const u8) []const u8 {
    const tool = toolOf(w);
    const testing = std.mem.eql(u8, tool, "pytest") or std.mem.eql(u8, tool, "py.test") or std.mem.eql(u8, tool, "ctest") or for (w[1..@min(w.len, 4)]) |x| {
        if (std.mem.eql(u8, x, "test") or std.mem.eql(u8, x, "t") or std.mem.eql(u8, x, "nextest")) break true;
    } else false;
    const label = a.print("{s}:{s}", .{ if (project.len != 0) project else "proj", if (testing) "test" else "build" }) catch "proj:build";
    const inner = joinQuoted(a, oneJob(a, w));
    const run = a.print("cpuq run --label {s} -- {s}", .{ label, inner }) catch "cpuq run --label P:T -- CMD";
    // On another machine: sent there by cpuq, the repo copied over, or through that machine's own.
    const h = host orelse return run;
    return a.print("cpuq run --on {s} --label {s} -- {s} (it copies this repo to {s}; or ssh {s} 'cd … && {s}', the inner quotes as needed)", .{ h, label, inner, h, h, run }) catch run;
}

/// A heredoc opened on a line (`<<EOF`, `<<-EOF`, `<<'EOF'`, `<<"EOF"`): where its delimiter
/// word ends, and the line that closes it.
const Heredoc = struct { end: usize, delim: []const u8, strip_tabs: bool };

/// The heredoc whose `<<` is at `i`, if it is one: not a here-string (`<<<`), and a delimiter
/// that is a word (letters, digits, _ . -, not starting with a digit, not followed by `)`), so
/// an arithmetic shift such as `$((1<<2))` is not taken for one.
fn heredocAt(script: []const u8, i: usize) ?Heredoc {
    var j = i + 2;
    if (j < script.len and script[j] == '<') return null;
    const strip = j < script.len and script[j] == '-';
    if (strip) j += 1;
    while (j < script.len and (script[j] == ' ' or script[j] == '\t')) : (j += 1) {}
    if (j >= script.len) return null;
    const quote: ?u8 = if (script[j] == '\'' or script[j] == '"') script[j] else null;
    if (quote != null) j += 1;
    const from = j;
    while (j < script.len and (std.ascii.isAlphanumeric(script[j]) or script[j] == '_' or script[j] == '.' or script[j] == '-')) : (j += 1) {}
    const delim = script[from..j];
    if (delim.len == 0 or std.ascii.isDigit(delim[0])) return null;
    if (quote) |q| {
        if (j >= script.len or script[j] != q) return null;
        j += 1;
    }
    if (j < script.len and script[j] == ')') return null;
    return .{ .end = j, .delim = delim, .strip_tabs = strip };
}

/// The end of the command substitution whose text starts at `from` (just past `$(` or a
/// backquote): the index of its `)` or closing backquote, or `script.len`.
fn substitutionEnd(script: []const u8, from: usize, backquote: bool) usize {
    var depth: usize = 0;
    var i = from;
    while (i < script.len) : (i += 1) {
        switch (script[i]) {
            '\\' => i += 1,
            '`' => if (backquote) return i,
            '(' => depth += 1,
            ')' => if (!backquote) {
                if (depth == 0) return i;
                depth -= 1;
            },
            else => {},
        }
    }
    return script.len;
}

/// Splits a script into simple commands: at unquoted ; & | && || newlines,
/// ( ) and the edges of $( … ) and backquotes, with each word unquoted. The
/// commands of a `$( … )` or backquotes inside double quotes come too. A
/// heredoc's body is set aside, never split: it is data (`python3 - <<EOF`),
/// unless the command that reads it is a shell (Ctx.simple).
fn split(a: std.mem.Allocator, script: []const u8) ![]Simple {
    var out: std.ArrayList(Simple) = .empty;
    // The commands on the current line start here: a `# cpuq: skip` at its end marks them.
    var line_first: usize = 0;
    var pending: std.ArrayList(Heredoc) = .empty;
    var words: std.ArrayList([]const u8) = .empty;
    var word: std.ArrayList(u8) = .empty;
    var in_word = false;
    var start: usize = 0;
    var i: usize = 0;
    const flushWord = struct {
        fn f(al: std.mem.Allocator, ws: *std.ArrayList([]const u8), wd: *std.ArrayList(u8), in: *bool) !void {
            if (in.*) try ws.append(al, try wd.toOwnedSlice(al));
            in.* = false;
        }
    }.f;
    const flushCmd = struct {
        fn f(al: std.mem.Allocator, o: *std.ArrayList(Simple), ws: *std.ArrayList([]const u8), text: []const u8) !void {
            if (ws.items.len != 0) try o.append(al, .{ .words = try ws.toOwnedSlice(al), .text = text });
        }
    }.f;
    while (i < script.len) : (i += 1) {
        const ch = script[i];
        switch (ch) {
            '\'' => {
                in_word = true;
                i += 1;
                while (i < script.len and script[i] != '\'') : (i += 1) try word.append(a, script[i]);
            },
            '"' => {
                in_word = true;
                i += 1;
                while (i < script.len and script[i] != '"') : (i += 1) {
                    const backquote = script[i] == '`';
                    if (backquote or (script[i] == '$' and i + 1 < script.len and script[i + 1] == '(')) {
                        // A substitution runs its commands: they are checked, its text kept in the word.
                        const from = i + @as(usize, if (backquote) 1 else 2);
                        const end = substitutionEnd(script, from, backquote);
                        try out.appendSlice(a, try split(a, script[from..end]));
                        try word.appendSlice(a, script[i..@min(end + 1, script.len)]);
                        i = @min(end, script.len - 1);
                        continue;
                    }
                    if (script[i] == '\\' and i + 1 < script.len) i += 1;
                    try word.append(a, script[i]);
                }
            },
            '\\' => {
                in_word = true;
                if (i + 1 < script.len) {
                    i += 1;
                    if (script[i] != '\n') try word.append(a, script[i]);
                }
            },
            '#' => if (!in_word) {
                try flushWord(a, &words, &word, &in_word);
                try flushCmd(a, &out, &words, script[start..i]);
                const eol = std.mem.findScalarPos(u8, script, i, '\n') orelse script.len;
                if (std.mem.eql(u8, std.mem.trim(u8, script[i..eol], " \t\r"), "# cpuq: skip")) {
                    for (out.items[line_first..]) |*cmd| cmd.skip = true;
                }
                // The newline, if any, ends the line as ever: it starts the line's heredocs.
                start = eol;
                i = eol - 1;
            } else try word.append(a, ch),
            ' ', '\t' => try flushWord(a, &words, &word, &in_word),
            '<' => if (if (i + 1 < script.len and script[i + 1] == '<') heredocAt(script, i) else null) |h| {
                // The redirection ends the word before it (`cat<<EOF`) and is no word itself.
                try flushWord(a, &words, &word, &in_word);
                try pending.append(a, h);
                i = h.end - 1;
            } else {
                in_word = true;
                try word.append(a, ch);
            },
            '\n' => {
                try flushWord(a, &words, &word, &in_word);
                try flushCmd(a, &out, &words, script[start..i]);
                // The bodies of the line's heredocs follow it, each up to its delimiter line.
                var p = i + 1;
                var bodies: std.ArrayList(u8) = .empty;
                for (pending.items) |h| {
                    const from = p;
                    var body_end = script.len;
                    var next = script.len;
                    while (p < script.len) {
                        const eol = std.mem.findScalarPos(u8, script, p, '\n') orelse script.len;
                        const line = if (h.strip_tabs) std.mem.trimStart(u8, script[p..eol], "\t") else script[p..eol];
                        if (std.mem.eql(u8, line, h.delim)) {
                            body_end = p;
                            next = @min(eol + 1, script.len);
                            break;
                        }
                        p = eol + 1;
                    }
                    try bodies.appendSlice(a, script[from..@min(body_end, script.len)]);
                    p = next;
                }
                if (pending.items.len != 0) {
                    // The line's last command reads them (`cat <<EOF | sh`: sh).
                    if (out.items.len > line_first) out.items[out.items.len - 1].heredoc = bodies.items;
                    pending.clearRetainingCapacity();
                    i = p - 1;
                }
                start = i + 1;
                line_first = out.items.len;
            },
            // `2>&1`, `>&2`, `&>log`: a redirection, part of the word.
            '&' => if ((in_word and word.items.len != 0 and word.items[word.items.len - 1] == '>') or (i + 1 < script.len and script[i + 1] == '>')) {
                in_word = true;
                try word.append(a, ch);
            } else {
                try flushWord(a, &words, &word, &in_word);
                try flushCmd(a, &out, &words, script[start..i]);
                start = i + 1;
            },
            ';', '|', '(', ')', '`' => {
                try flushWord(a, &words, &word, &in_word);
                try flushCmd(a, &out, &words, script[start..i]);
                start = i + 1;
            },
            '$' => if (i + 1 < script.len and script[i + 1] == '(') {
                try flushWord(a, &words, &word, &in_word);
                try flushCmd(a, &out, &words, script[start..i]);
                i += 1;
                start = i + 1;
            } else {
                in_word = true;
                try word.append(a, ch);
            },
            else => {
                in_word = true;
                try word.append(a, ch);
            },
        }
    }
    try flushWord(a, &words, &word, &in_word);
    try flushCmd(a, &out, &words, script[start..]);
    return out.items;
}

fn refused(command: []const u8) bool {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    return check(arena.allocator(), command, "app", null) != null;
}

fn refusal(a: std.mem.Allocator, command: []const u8) Refusal {
    return check(a, command, "app", null) orelse .{ .reason = "", .instead = "" };
}

test "heavy commands outside cpuq are refused" {
    try std.testing.expect(refused("zig build test"));
    try std.testing.expect(refused("cd x && cargo test --release"));
    try std.testing.expect(refused("FOO=1 nice -n 5 make -j8"));
    try std.testing.expect(refused("make"));
    try std.testing.expect(refused("xcodebuild test -scheme App"));
    try std.testing.expect(refused("python3 -m pytest -q"));
    try std.testing.expect(refused("ssh pup 'cd repo && zig build'"));
    try std.testing.expect(refused("echo $(make all)"));
}

test "light and wrapped commands pass" {
    try std.testing.expect(!refused("git status && ls -la"));
    try std.testing.expect(!refused("zig build --help"));
    try std.testing.expect(!refused("make -n"));
    try std.testing.expect(!refused("xcodebuild -list"));
    try std.testing.expect(!refused("swift build --show-bin-path"));
    try std.testing.expect(!refused("cargo fmt"));
    try std.testing.expect(!refused("cpuq status --json"));
    try std.testing.expect(!refused("cpuq drain -- ./bench"));
    try std.testing.expect(!refused("cpuq lease pup-bench --host pup -- cpuq drain -- ./bench.sh"));
    try std.testing.expect(!refused("echo 'zig build'"));
    try std.testing.expect(!refused("grep -r 'cargo build' ."));
    try std.testing.expect(!refused("grep -rn CPUQ_CORES src/"));
    try std.testing.expect(!refused("zig build # cpuq: skip"));
    try std.testing.expect(!refused("cpuq run --label app:build -- zig build -j1 test"));
    try std.testing.expect(!refused("cpuq run --label app:build -- make"));
    try std.testing.expect(!refused("ssh pup 'cd repo && cpuq run --label app:build -- make'"));
    try std.testing.expect(!refused("cpuq run --on burst --label proj:matrix -n 32 -- sh -c 'zig build -j1 -Dcase=\"$CPUQ_TASK\"'"));
    // cpuq cap limits a program but doesn't queue it: heavy work inside it is still refused.
    try std.testing.expect(refused("cpuq cap --time 600s -- zig build test"));
    try std.testing.expect(refused("cpuq cap --mem=2G -- make"));
    try std.testing.expect(!refused("cpuq cap --mem 2G --time 120s -- ./a.out"));
    try std.testing.expect(!refused("cpuq run --label app:test -- cpuq cap --mem 2G -- ./a.out"));
}

test "a heredoc's body is data unless a shell reads it" {
    // An apostrophe in a heredoc once opened a quote that swallowed the rest of the command.
    try std.testing.expect(!refused(
        \\python3 - <<'EOF'
        \\s = "the machine's load"
        \\EOF
        \\cpuq run --label cpuq:build -- sh -c 'zig build -j1 && zig build test -j1'
    ));
    // Documentation in a body is not a command.
    try std.testing.expect(!refused(
        \\python3 - <<'EOF'
        \\doc = "cpuq run --cores 2-6 -- make -j$CPUQ_CORES; zig build"
        \\EOF
    ));
    try std.testing.expect(!refused("cat <<-EOF\n\tzig build\n\tEOF\necho ok"));
    // What follows the closing line is checked as ever.
    try std.testing.expect(refused("cat <<EOF\nhi there's\nEOF\nzig build"));
    // A body a shell or ssh reads is a script, and checked.
    try std.testing.expect(refused("sh <<'EOF'\ncd x && zig build\nEOF"));
    try std.testing.expect(refused("cat <<EOF | bash\nmake -j8\nEOF"));
    try std.testing.expect(refused("ssh pup <<'EOF'\ncd repo && zig build\nEOF"));
    try std.testing.expect(!refused("ssh pup <<'EOF'\ncd repo && cpuq run --label a:b -- make\nEOF"));
    try std.testing.expect(refused("cpuq run --label a:b -- sh <<'EOF'\nmake -j8\nEOF"));
    // Not heredocs: a here-string, and an arithmetic shift.
    try std.testing.expect(!refused("cat <<< 'zig build'"));
    try std.testing.expect(refused("echo $((1<<2)); zig build"));
}

test "a suggestion runs the command as typed, under cpuq, at one job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "zig build", "cpuq run --label app:build -- zig build -j1" },
        .{ "zig build -j8 test", "cpuq run --label app:test -- zig build -j1 test" },
        .{ "zig build >/dev/null 2>&1", "cpuq run --label app:build -- zig build -j1 >/dev/null 2>&1" },
        .{ "zig build test -- --verbose", "cpuq run --label app:test -- zig build test -j1 -- --verbose" },
        .{ "make -j8 all", "cpuq run --label app:build -- make all" },
        .{ "make -j all", "cpuq run --label app:build -- make all" },
        .{ "cargo test 2>&1", "cpuq run --label app:test -- cargo test -j 1 2>&1" },
        .{ "cargo build -j16", "cpuq run --label app:build -- cargo build -j1" },
        .{ "go build ./...", "cpuq run --label app:build -- go build -p 1 ./..." },
        .{ "swift build -c release", "cpuq run --label app:build -- swift build -j 1 -c release" },
        .{ "pytest -n 8 -q", "cpuq run --label app:test -- pytest -q" },
        .{ "python3 -m pytest -n auto", "cpuq run --label app:test -- python3 -m pytest" },
        .{ "ninja -C out", "cpuq run --label app:build -- ninja -C out -j 1" },
        .{ "cmake --build build", "cpuq run --label app:build -- cmake --build build -j 1" },
        .{ "xcodebuild test -scheme App -jobs 8", "cpuq run --label app:test -- xcodebuild test -scheme App -jobs 1" },
        .{ "zig build -Dname='a b'", "cpuq run --label app:build -- zig build \"-Dname=a b\" -j1" },
        .{ "zig build '-Dx=$HOME'", "cpuq run --label app:build -- zig build '-Dx=$HOME' -j1" },
        .{ "zig build -j\"$CPUQ_CORES\"", "cpuq run --label app:build -- zig build -j1" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], refusal(a, c[0]).instead);
    // Each suggestion passes.
    for (cases) |c| try std.testing.expect(!refused(c[1]));
}

test "heavy work over ssh is pointed to --on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = refusal(arena.allocator(), "ssh burst 'cd repo && zig build test'");
    try std.testing.expect(std.mem.startsWith(u8, r.instead, "cpuq run --on burst --label app:test -- zig build test -j1 (it copies this repo to burst;"));
}

test "inside cpuq run, a task runs one job" {
    // More than one, or no limit.
    try std.testing.expect(refused("cpuq run --label a:b -- make -j8"));
    try std.testing.expect(refused("cpuq run --label a:b -- make -j"));
    try std.testing.expect(refused("cpuq run --label a:b -- make -j install"));
    try std.testing.expect(refused("cpuq run --label a:b -- sh -c 'zig build -j16 test'"));
    try std.testing.expect(refused("cpuq run --label a:b -- cargo build -j 16"));
    // -j K: each task holds K CPUs, so its command may run K jobs, and no more.
    try std.testing.expect(!refused("cpuq run -j 2 --label a:b -- zig build -j2"));
    try std.testing.expect(!refused("cpuq run -j=4 --label a:b -- make -j 3"));
    try std.testing.expect(refused("cpuq run -j 2 --label a:b -- zig build -j8"));
    try std.testing.expect(refused("cpuq run -j 2 --label a:b -- zig build"));
    try std.testing.expect(refused("cpuq run --label a:b -- pytest -n auto"));
    try std.testing.expect(refused("cpuq run --label a:b -- python3 -m pytest -n 4"));
    try std.testing.expect(refused("cpuq run --label a:b -- ninja -j0"));
    try std.testing.expect(refused("cpuq run --label a:b -- bazel build --jobs=8 //..."));
    // A tool that runs a job for every CPU unless told otherwise.
    try std.testing.expect(refused("cpuq run --label a:b -- zig build"));
    try std.testing.expect(refused("cpuq run --label a:b -- sh -c 'cd x; zig build test'"));
    try std.testing.expect(refused("cpuq run --label a:b -- env -u X sh -c 'zig build'"));
    try std.testing.expect(refused("cpuq run --label a:b -- go build ./..."));
    try std.testing.expect(refused("cpuq run --label a:b -- cargo test"));
    try std.testing.expect(refused("cpuq run --label a:b -- xcodebuild test -scheme App"));
    try std.testing.expect(refused("cpuq run --on burst --label a:b -- zig build"));
    // One job.
    try std.testing.expect(!refused("cpuq run --label a:b -- zig build -j1 test"));
    try std.testing.expect(!refused("cpuq run --label a:b -- sh -c 'cd x && zig build -j1 test'"));
    try std.testing.expect(!refused("cpuq run --label a:b -- make"));
    try std.testing.expect(!refused("cpuq run --label a:b -- make -j1"));
    try std.testing.expect(!refused("cpuq run --label a:b -- cargo build -j 1"));
    try std.testing.expect(!refused("cpuq run --label a:b -- go build -p 1 ./..."));
    try std.testing.expect(!refused("cpuq run --label a:b -- pytest -q"));
    try std.testing.expect(!refused("cpuq run --label a:b -- pytest -n 0"));
    try std.testing.expect(!refused("cpuq run --label a:b -- xcodebuild test -scheme App -jobs 1"));
    // A count it can't read is left alone.
    try std.testing.expect(!refused("cpuq run --label a:b -- sh -c 'make -j\"$N\"'"));
    // A lease's command is held to one job too.
    try std.testing.expect(refused("cpuq lease w -- make -j8"));
}

test "a run's every option value is skipped" {
    try std.testing.expect(refused("cpuq run -n 4 -c 50% -t 30s -r 1 --wait-max 9 --label a:b -- zig build"));
    try std.testing.expect(refused("cpuq run --note x --label a:b -- zig build"));
    try std.testing.expect(refused("cpuq run --repo X --urgent -- zig build"));
    try std.testing.expect(refused("cpuq run -c=4 --label=a:b -- zig build"));
    try std.testing.expect(!refused("cpuq run -n 8 -c 4 --label a:b -- sh -c './case \"$CPUQ_TASK\"'"));
    try std.testing.expect(!refused("cpuq lease w --host pup --slots 2 --label a:b -- ./bench"));
}

test "the fix for too many jobs is one job, or tasks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r = refusal(a, "cpuq run --label a:b -- zig build test");
    try std.testing.expectEqualStrings("`zig build` without -j1 runs a job for every CPU, but a task counts as one CPU", r.reason);
    try std.testing.expectEqualStrings("cpuq run --label a:b -- zig build test -j1 (or split the work into tasks with -n M)", r.instead);
    r = refusal(a, "cpuq run --label a:b -- make -j8 all");
    try std.testing.expectEqualStrings("`-j8` runs 8 jobs at once, but a task counts as one CPU", r.reason);
    try std.testing.expectEqualStrings("cpuq run --label a:b -- make all (or split the work into tasks with -n M)", r.instead);
    r = refusal(a, "cpuq run --label a:b -- sh -c 'zig build test -j 16'");
    try std.testing.expectEqualStrings("cpuq run --label a:b -- zig build test -j1 (or split the work into tasks with -n M)", r.instead);
    // In a script of several commands, the command to change.
    r = refusal(a, "cpuq run --label a:b -- sh -c 'cd x && go test ./...'");
    try std.testing.expectEqualStrings("`go test -p 1 ./...` in its script (or split the work into tasks with -n M)", r.instead);
}

test "$CPUQ_CORES is refused, with the run at one job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "cpuq run --label a:b -- sh -c 'make -j\"$CPUQ_CORES\"'", "cpuq run --label a:b -- make" },
        .{ "cpuq run --label a:b -- sh -c 'zig build -j\"$CPUQ_CORES\" test'", "cpuq run --label a:b -- zig build -j1 test" },
        .{ "cpuq run --label a:b -- make -j$CPUQ_CORES", "cpuq run --label a:b -- make" },
        .{ "cpuq run --label a:b -- sh -c 'pytest -n \"${CPUQ_CORES}\" -q'", "cpuq run --label a:b -- pytest -q" },
        .{ "cpuq run --label a:b -- sh -c 'go build -p \"$CPUQ_CORES\" ./...'", "cpuq run --label a:b -- go build -p 1 ./..." },
        .{ "cpuq run --label a:b -- sh -c 'cd x && zig build -j\"$CPUQ_CORES\"'", "cpuq run --label a:b -- sh -c \"cd x && zig build -j1\"" },
    };
    for (cases) |c| {
        const r = refusal(a, c[0]);
        try std.testing.expectEqualStrings("cpuq counts each task as one CPU; there is no $CPUQ_CORES", r.reason);
        try std.testing.expectEqualStrings(c[1], r.instead);
        try std.testing.expect(!refused(c[1]));
    }
}

test "a benchmark outside cpuq is refused, with a drain to time it in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const r = refusal(a, "hyperfine 'zig-out/bin/app x'");
    try std.testing.expect(std.mem.startsWith(u8, r.reason, "`hyperfine` is a benchmark run outside cpuq"));
    try std.testing.expect(std.mem.startsWith(u8, r.instead, "cpuq drain -c 1 -t 20m --label "));
    try std.testing.expect(std.mem.endsWith(u8, r.instead, ":bench -- hyperfine \"zig-out/bin/app x\" (-c as many CPUs as it times on; -t about ten times its run)"));
    for ([_][]const u8{ "cargo bench", "cargo +nightly bench --bench x", "zig build bench -Doptimize=fast", "node scripts/bench.mjs", "bun run bench/render-bench.ts", "python3 tools/microbench.py -n 3", "deno run -A bench.ts" }) |cmd|
        try std.testing.expect(refused(cmd));
    for ([_][]const u8{ "node scripts/build.mjs", "python3 -m benchmark_lib --help", "hyperfine --version", "cpuq drain -c 1 -t 20m -- hyperfine x", "zig build test", "python3 tools/bench/score x.runs", "python3 tools/bench/race-score x.runs" }) |cmd| {
        const got = refusal(a, cmd);
        try std.testing.expect(!std.mem.startsWith(u8, got.reason, "`hyperfine`") and std.mem.indexOf(u8, got.reason, "benchmark") == null);
    }
}

test "removed options are refused as cpuq refuses them, with the run they become" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][3][]const u8{
        .{ "cpuq run --label app:build --cores 2-6 -- sh -c 'zig build -j\"$CPUQ_CORES\" test'", "--cores", "cpuq run --label app:build -- zig build -j1 test" },
        .{ "cpuq run --cores=4 -- make", "--cores", "cpuq run -- make" },
        .{ "cpuq run --priority high --label a:b -- ./x", "--priority", "cpuq run --label a:b -- ./x" },
        .{ "cpuq run --max-wait 60 --label a:b -- ./x", "--max-wait", "cpuq run --wait-max 60 --label a:b -- ./x" },
        .{ "cpuq run --exclusive --label rig:bench --max-wait 90 -- ./bench", "--exclusive", "cpuq drain -c 1 --label rig:bench --max 90s -- ./bench" },
        .{ "cpuq run --no-load-check -- ./x", "--no-load-check", "cpuq run -- ./x" },
        .{ "cpuq run --qos none -- ./x", "--qos", "cpuq run -- ./x" },
        .{ "cpuq run --label e:t --cores 4 --opaque -- incus exec c -- make", "--cores", "cpuq run --label e:t -- incus exec c -- make" },
        .{ "ssh pup 'cd repo && cpuq run --cores 2 -- make'", "--cores", "cpuq run -- make" },
        .{ "cpuq run -n 20 -x 4 --label a:fetch -- sh -c './fetch \"$CPUQ_TASK\"'", "-x", "cpuq run -n 20 --label a:fetch -- sh -c './fetch \"$CPUQ_TASK\"'" },
    };
    for (cases) |c| {
        const r = refusal(a, c[0]);
        // The first removed option given is the one named.
        try std.testing.expectEqualStrings(removedWhy(c[1], false).?, r.reason);
        try std.testing.expectEqualStrings(c[2], r.instead);
        try std.testing.expect(!refused(c[2]));
    }
    // A lease held alone: the lease, then cpuq drain inside it.
    const r = refusal(a, "cpuq lease w --host pup --exclusive -- ./bench");
    try std.testing.expectEqualStrings(lease_exclusive, r.reason);
    try std.testing.expectEqualStrings("cpuq lease w --host pup -- cpuq drain -c 1 -- ./bench", r.instead);
    try std.testing.expect(refused("cpuq lease w --priority low -- ./bench"));
    // After `--` an option is the command's.
    try std.testing.expect(!refused("cpuq run --label a:b -- ./x --cores 4"));
}

test "--driver takes any command but a bare build directly under it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_][]const u8{
        "cpuq run --driver --label rig:test -- swarm test/rig.rip",
        "cpuq run --driver -- ./test/run -j 8",
        "cpuq run --driver --label rig:light -- rig/tools/light",
        "cpuq run --driver --label a:b -- ./bench",
        "cpuq run --driver -- cc -O2 x.c",
        "cpuq run --driver -- sh -c './test/run && cargo test'",
        "cpuq run --driver --label rig:build -- env RIG_UNIT_LAUNCHER='cpuq run --' rig build --units=8 app.rig",
        "cpuq run --driver -- zig version",
    }) |cmd| try std.testing.expect(!refused(cmd));
    const r = refusal(a, "cpuq run --driver --label a:b -- zig build test");
    try std.testing.expectEqualStrings("`zig build` directly under --driver: a build is a task, not a runner, so run it as one", r.reason);
    try std.testing.expectEqualStrings("cpuq run --label a:b -- zig build test -j1", r.instead);
    for ([_][]const u8{ "cpuq run --driver -- make test", "cpuq run --driver -- cargo build", "cpuq run --driver -- go test ./...", "cpuq run --driver -- swift build", "cpuq run --driver -- xcodebuild -scheme App" }) |cmd|
        try std.testing.expect(refused(cmd));
}

test "a run here is put to the advisor, with its command; one sent elsewhere never is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Seen = struct {
        cmd: []const u8 = "",
        fn advise(p: *anyopaque, cmd: []const u8) ?Refusal {
            const s: *@This() = @ptrCast(@alignCast(p));
            s.cmd = cmd;
            return .{ .reason = "slow here", .instead = "cpuq submit cpuq/suite.json" };
        }
    };
    var seen: Seen = .{};
    const ad: Advisor = .{ .ctx = &seen, .advise = Seen.advise };
    const r = check(a, "cpuq run --driver --label rig:test -- sh -c './test/run -j 8'", "app", ad);
    try std.testing.expectEqualStrings("slow here", r.?.reason);
    try std.testing.expectEqualStrings("sh -c ./test/run -j 8", seen.cmd);
    // Sent elsewhere, or a lease: not asked.
    try std.testing.expect(check(a, "cpuq run --on burst --label rig:test -- make", "app", ad) == null);
    try std.testing.expect(check(a, "cpuq lease w --label rig:bench -- ./bench", "app", ad) == null);
    // On another machine, through its own cpuq: not this machine's history.
    try std.testing.expect(check(a, "ssh pup 'cd repo && cpuq run --label rig:test -- make'", "app", ad) == null);
}

test "shell keywords, groupings and substitutions in double quotes hide nothing" {
    try std.testing.expect(refused("if true; then zig build; fi"));
    try std.testing.expect(refused("{ zig build; }"));
    try std.testing.expect(refused("! zig build"));
    try std.testing.expect(refused("while true; do make; done"));
    try std.testing.expect(refused("echo \"$(zig build)\""));
    try std.testing.expect(refused("echo \"`make all`\""));
    try std.testing.expect(!refused("echo \"$(git rev-parse HEAD)\" done"));
}

test "wrappers are read with their own options" {
    try std.testing.expect(refused("taskset -c 0-3 make"));
    try std.testing.expect(refused("taskset 0x3 make"));
    try std.testing.expect(refused("env -u FOO make"));
    try std.testing.expect(refused("sudo -u builder make"));
    try std.testing.expect(refused("timeout -k 1 5 zig build"));
    try std.testing.expect(refused("uv run pytest"));
    try std.testing.expect(refused("cargo +nightly build"));
    try std.testing.expect(refused("python3.12 -m pytest"));
    try std.testing.expect(!refused("command -v make"));
    try std.testing.expect(!refused("taskset -p 1234"));
}

test "a skip comment counts only as a comment, for its own line" {
    try std.testing.expect(!refused("make && zig build # cpuq: skip"));
    try std.testing.expect(!refused("zig build   # cpuq: skip  "));
    try std.testing.expect(!refused("cpuq run --cores 4 -- make # cpuq: skip"));
    try std.testing.expect(refused("echo '# cpuq: skip'; zig build"));
    try std.testing.expect(refused("git log --grep='# cpuq: skip' && make"));
    try std.testing.expect(refused("ls # cpuq: skip\nmake"));
    // A comment on a heredoc's line still sets its body aside.
    try std.testing.expect(!refused("cat <<EOF # note\nmake\nEOF"));
    try std.testing.expect(refused("sh <<EOF # run it\nmake\nEOF"));
}
