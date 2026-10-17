//! `cpuq hook`: an agent's guard. A coding agent's harness (Claude Code's
//! PreToolUse hook) passes each shell command here before running it; a
//! command that would load the machine outside cpuq, or misuse it, is refused
//! with the corrected form, so the queue is enforced where agents act rather
//! than asked for in AGENTS.md.
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
/// Asked only for a run on this machine of a kind that could go elsewhere (not --on, --exclusive,
/// --opaque, …).
pub const Advisor = struct {
    ctx: *anyopaque,
    /// `cmd`: the command after `--`, its words joined by spaces.
    advise: *const fn (ctx: *anyopaque, cmd: []const u8) ?Refusal,
};

/// Checks one shell command line. `cpus` is the machine's CPU count, for
/// requests over half of it; `project` names the job in suggested labels.
pub fn check(a: std.mem.Allocator, command: []const u8, cpus: u32, project: []const u8, advisor: ?Advisor) ?Refusal {
    const ctx: Ctx = .{ .a = a, .cpus = cpus, .project = project, .advisor = advisor };
    return ctx.script(command, null, 0);
}

/// The largest fixed request (or minimum) that doesn't wait for a nearly empty machine: half the
/// CPUs, and at least 2, which fits even a small machine.
pub fn maxAsk(cpus: u32) u32 {
    return @max(cpus / 2, 2);
}

/// The `cpuq run` and `cpuq lease` options that take a value (`--cores 2-6`, or `--cores=2-6`).
pub const run_value_options = [_][]const u8{ "--cores", "--priority", "--label", "--note", "--max-wait", "--qos", "--host", "--slots", "--return", "--on", "--include", "--repo" };

/// What one check knows: the machine, the project for suggested labels, and the advisor for the
/// `cpuq run`s on this machine.
const Ctx = struct {
    a: std.mem.Allocator,
    cpus: u32,
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
        if (std.mem.eql(u8, prog, "cpuq")) return checkCpuq(a, cmd, w, ctx.cpus, if (host == null) ctx.advisor else null);
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
        const heavy_prog = heavyName(w) orelse return null;
        // "zig build", "cargo test": the program and its subcommand.
        const heavy = if (std.mem.eql(u8, heavy_prog, prog) and w.len > 1 and w[1].len > 0 and w[1][0] != '-' and isSubTool(prog))
            a.print("{s} {s}", .{ prog, w[1] }) catch heavy_prog
        else
            heavy_prog;
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

/// A `cpuq run` (or lease): the grant must reach the command, not the shell
/// that types it; a large fixed request waits for an empty machine; work in a
/// container or simulator needs --opaque.
fn checkCpuq(a: std.mem.Allocator, cmd: Simple, w: []const []const u8, cpus: u32, advisor: ?Advisor) ?Refusal {
    if (w.len < 2) return null;
    const sub = w[1];
    if (!std.mem.eql(u8, sub, "run") and !std.mem.eql(u8, sub, "lease")) return null;
    if (expandsEarly(cmd.text)) return .{
        .reason = "`$CPUQ_CORES` is expanded by your shell before cpuq sets it, so the command gets nothing there (and `make -j` with nothing after it has no limit)",
        .instead = quotedInside(a, cmd.text),
    };
    var opaque_flag = false;
    var elsewhere = false;
    var pinned = false;
    var min_cores: ?u32 = null;
    // A lease's name comes first.
    var i: usize = if (std.mem.eql(u8, sub, "lease")) 3 else 2;
    while (i < w.len) : (i += 1) {
        const o = w[i];
        if (std.mem.eql(u8, o, "--")) {
            i += 1;
            break;
        }
        if (o.len == 0 or o[0] != '-') break;
        if (std.mem.eql(u8, o, "--opaque")) opaque_flag = true;
        // Sent to another machine: its size, not this one's, judges the request.
        if (std.mem.eql(u8, o, "--on") or std.mem.startsWith(u8, o, "--on=")) elsewhere = true;
        // Of a kind that runs only here.
        if (std.mem.eql(u8, o, "--exclusive") or std.mem.eql(u8, o, "--opaque") or std.mem.eql(u8, o, "--tethered") or std.mem.eql(u8, o, "--hold")) pinned = true;
        const value: ?[]const u8 = if (std.mem.startsWith(u8, o, "--cores=")) o["--cores=".len..] else if (std.mem.eql(u8, o, "--cores") and i + 1 < w.len) w[i + 1] else null;
        if (value) |v| min_cores = std.fmt.parseInt(u32, std.mem.sliceTo(v, '-'), 10) catch null;
        // Options that take a value skip it.
        for (run_value_options) |takes| {
            if (std.mem.eql(u8, o, takes)) i += 1;
        }
    }
    if (min_cores) |m| if (!elsewhere and m > maxAsk(cpus)) return .{
        .reason = a.print("asking for at least {d} cores on a {d}-CPU machine: a request over half the CPUs waits until the machine is nearly empty", .{ m, cpus }) catch "too many cores asked for",
        .instead = "ask for a range the job can shrink to, such as --cores 2-6, and pass \"$CPUQ_CORES\" on; run big jobs on the larger machine",
    };
    if (i >= w.len) return null;
    const inner = stripWrappers(w[i..]);
    if (inner.len == 0) return null;
    const script: []const u8 = if (isShell(std.fs.path.basename(inner[0]))) shellScript(inner) orelse "" else std.mem.join(a, " ", inner) catch "";
    const inner_cmds = split(a, script) catch return null;
    for (inner_cmds) |ic| {
        const iw = stripWrappers(ic.words);
        if (iw.len == 0) continue;
        const prog = std.fs.path.basename(iw[0]);
        if (!opaque_flag and hidesWork(iw)) return .{
            .reason = a.print("`{s}` does its work in processes cpuq can't see (a container or a simulator), so it would count the job as idle and hand its cores out again", .{prog}) catch "hidden work",
            .instead = "add --opaque and a fixed --cores: cpuq run --label P:T --cores 4 --opaque -- …",
        };
        if (std.mem.eql(u8, prog, "zig") and iw.len >= 2 and std.mem.eql(u8, iw[1], "build") and !hasJobs(iw)) return .{
            .reason = "`zig build` without -j starts a thread for every CPU, however few cores the job was granted",
            .instead = "cpuq run --label P:T --cores 2-6 -- sh -c 'zig build -j\"$CPUQ_CORES\" …' (single quotes)",
        };
        if (heavyName(iw) != null) if (fixedJobs(iw, min_cores orelse 1)) |flag| return .{
            .reason = a.print("`{s}` fixes its own parallelism, however few cores the job was granted", .{flag}) catch "a fixed jobs count",
            .instead = if (std.mem.eql(u8, prog, "make") or std.mem.eql(u8, prog, "gmake"))
                "drop the -j: make takes its slots from cpuq's jobserver"
            else
                "pass the grant on, inside single quotes: sh -c '… -j\"$CPUQ_CORES\"' (or -n, -p, -jobs for the tool)",
        };
    }
    // Long work that finishes far sooner elsewhere, of a run that may move.
    if (advisor) |ad| if (std.mem.eql(u8, sub, "run") and !elsewhere and !pinned) {
        return ad.advise(ad.ctx, std.mem.join(a, " ", inner) catch return null);
    };
    return null;
}

/// The same `cpuq run` with its command moved inside `sh -c '…'`, so the
/// job's shell expands `$CPUQ_CORES`.
fn quotedInside(a: std.mem.Allocator, text: []const u8) []const u8 {
    const generic = "put the command in single quotes inside the job: cpuq run --label P:T --cores 2-6 -- sh -c 'make -j\"$CPUQ_CORES\"'";
    const at = std.mem.find(u8, text, " -- ") orelse return generic;
    const inner = std.mem.trim(u8, text[at + 4 ..], " ");
    if (std.mem.findScalar(u8, inner, '\'') != null or std.mem.startsWith(u8, inner, "sh ") or std.mem.startsWith(u8, inner, "bash ")) return generic;
    var fixed: std.ArrayList(u8) = .empty;
    var rest = inner;
    while (std.mem.find(u8, rest, "$CPUQ_CORES")) |i| {
        // Quoted for the inner shell: -j"$CPUQ_CORES".
        const bare = i == 0 or rest[i - 1] != '"';
        fixed.appendSlice(a, rest[0..i]) catch return generic;
        fixed.appendSlice(a, if (bare) "\"$CPUQ_CORES\"" else "$CPUQ_CORES") catch return generic;
        rest = rest[i + "$CPUQ_CORES".len ..];
    }
    fixed.appendSlice(a, rest) catch return generic;
    return a.print("{s} -- sh -c '{s}'", .{ std.mem.trimEnd(u8, text[0..at], " "), fixed.items }) catch generic;
}

/// Whether `$CPUQ_CORES` appears where the typing shell expands it: outside
/// single quotes and not escaped.
fn expandsEarly(text: []const u8) bool {
    var single = false;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (single) {
            if (ch == '\'') single = false;
            continue;
        }
        switch (ch) {
            '\\' => i += 1,
            '\'' => single = true,
            '$' => {
                const rest = text[i + 1 ..];
                if (std.mem.startsWith(u8, rest, "CPUQ_CORES") or std.mem.startsWith(u8, rest, "{CPUQ_CORES")) return true;
            },
            else => {},
        }
    }
    return false;
}

fn hasJobs(w: []const []const u8) bool {
    for (w) |x| if (std.mem.startsWith(u8, x, "-j")) return true;
    return false;
}

/// The tool a heavy command runs: `pytest` for `python3 -m pytest`, else the program.
fn toolOf(w: []const []const u8) []const u8 {
    const prog = std.fs.path.basename(w[0]);
    if (isPython(prog) and w.len >= 3 and std.mem.eql(u8, w[1], "-m")) return w[2];
    return prog;
}

/// The words the tool's jobs option takes at `w[i]` (`-j8`: 1, `-j 8`: 2), with its value; null
/// when `w[i]` is none. A bare `-j` (make's no limit) has the value "".
const Jobs = struct { words: usize, value: []const u8 };

fn jobsAt(tool: []const u8, w: []const []const u8, i: usize) ?Jobs {
    const x = w[i];
    const Flag = struct { tool: []const u8, flag: []const u8 };
    const flags = [_]Flag{
        .{ .tool = "go", .flag = "-p" },
        .{ .tool = "pytest", .flag = "-n" },
        .{ .tool = "pytest", .flag = "--numprocesses" },
        .{ .tool = "xcodebuild", .flag = "-jobs" },
        .{ .tool = "cmake", .flag = "--parallel" },
        .{ .tool = "", .flag = "-j" },
        .{ .tool = "", .flag = "--jobs" },
    };
    for (flags) |f| {
        if (f.tool.len != 0 and !std.mem.eql(u8, f.tool, tool)) continue;
        if (!std.mem.startsWith(u8, x, f.flag)) continue;
        const rest = x[f.flag.len..];
        if (rest.len != 0) {
            // `-j8`, `--jobs=8`; a short flag's value may be attached, a long one's follows `=`.
            if (rest[0] == '=') return .{ .words = 1, .value = rest[1..] };
            if (f.flag[1] != '-' and f.flag.len == 2) return .{ .words = 1, .value = rest };
            continue;
        }
        // The value in the next word, unless that is another option or (for -j) a target.
        if (i + 1 < w.len and w[i + 1].len != 0 and w[i + 1][0] != '-') {
            const v = w[i + 1];
            const numeric = std.fmt.parseInt(u32, v, 10) catch null;
            if (numeric != null or std.mem.find(u8, v, "CPUQ_CORES") != null or !std.mem.eql(u8, f.flag, "-j")) return .{ .words = 2, .value = v };
        }
        return .{ .words = 1, .value = "" };
    }
    return null;
}

/// A jobs option set to a fixed count over `allowed`, the least the job is granted (or to no
/// limit: a bare `make -j`, `ninja -j0`, `pytest -n auto`), which overrides the grant: its text,
/// else null.
fn fixedJobs(w: []const []const u8, allowed: u32) ?[]const u8 {
    const tool = toolOf(w);
    var i: usize = 1;
    while (i < w.len) : (i += 1) {
        if (std.mem.eql(u8, w[i], "--")) return null;
        const j = jobsAt(tool, w, i) orelse continue;
        const v = j.value;
        const fixed = if (std.fmt.parseInt(u32, v, 10)) |n| n == 0 or n > allowed else |_| v.len == 0 or std.mem.eql(u8, v, "auto") or std.mem.eql(u8, v, "logical");
        if (fixed) return w[i];
        i += j.words - 1;
    }
    return null;
}

/// Work done where cpuq's process-tree measurement can't see it.
fn hidesWork(w: []const []const u8) bool {
    const prog = std.fs.path.basename(w[0]);
    const sub = if (w.len >= 2) w[1] else "";
    for ([_][]const u8{ "incus", "lxc", "docker", "podman", "nerdctl" }) |c| {
        if (std.mem.eql(u8, prog, c) and (std.mem.eql(u8, sub, "exec") or std.mem.eql(u8, sub, "run"))) return true;
    }
    if (std.mem.eql(u8, prog, "xcodebuild")) {
        for (w) |x| if (std.mem.find(u8, x, "Simulator") != null) return true;
    }
    return false;
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

/// How a tool takes the grant: the option, and whether it goes right after the subcommand
/// (`go build -p N ./...`) or at the end of the arguments.
const Grant = struct { tool: []const u8, option: []const u8, after_sub: bool = false };

const grants = [_]Grant{
    .{ .tool = "zig", .option = "-j\"$CPUQ_CORES\"" },
    .{ .tool = "cargo", .option = "-j \"$CPUQ_CORES\"", .after_sub = true },
    .{ .tool = "swift", .option = "-j \"$CPUQ_CORES\"", .after_sub = true },
    .{ .tool = "go", .option = "-p \"$CPUQ_CORES\"", .after_sub = true },
    .{ .tool = "pytest", .option = "-n \"$CPUQ_CORES\"" },
    .{ .tool = "ninja", .option = "-j \"$CPUQ_CORES\"" },
    .{ .tool = "cmake", .option = "-j \"$CPUQ_CORES\"" },
    .{ .tool = "xcodebuild", .option = "-jobs \"$CPUQ_CORES\"" },
};

/// What to run instead: the command under cpuq, its own jobs option replaced by the grant (make
/// takes its slots from cpuq's jobserver and needs none).
fn suggest(a: std.mem.Allocator, w: []const []const u8, project: []const u8, host: ?[]const u8) []const u8 {
    const tool = toolOf(w);
    const testing = std.mem.eql(u8, tool, "pytest") or std.mem.eql(u8, tool, "py.test") or std.mem.eql(u8, tool, "ctest") or for (w[1..@min(w.len, 4)]) |x| {
        if (std.mem.eql(u8, x, "test") or std.mem.eql(u8, x, "t") or std.mem.eql(u8, x, "nextest")) break true;
    } else false;
    const label = a.print("{s}:{s}", .{ if (project.len != 0) project else "proj", if (testing) "test" else "build" }) catch "proj:build";
    // The words less their own jobs option.
    var kept: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < w.len) : (i += 1) {
        if (i > 0) if (jobsAt(tool, w, i)) |j| {
            i += j.words - 1;
            continue;
        };
        kept.append(a, w[i]) catch return "cpuq run --label P:T --cores 2-6 -- CMD";
    }
    const words = kept.items;
    // The grant goes before the redirections (`zig build >log 2>&1`), not after them.
    const k = firstRedirect(words);
    const grant: ?Grant = for (grants) |g| {
        if (std.mem.eql(u8, g.tool, tool)) break g;
    } else null;
    var line: std.ArrayList(u8) = .empty;
    for (words, 0..) |x, n| {
        if (grant) |g| if ((g.after_sub and n == 2) or (!g.after_sub and n == k)) {
            line.appendSlice(a, " ") catch {};
            line.appendSlice(a, g.option) catch {};
        };
        if (n != 0) line.appendSlice(a, " ") catch {};
        line.appendSlice(a, quoteWord(a, x)) catch {};
    }
    if (grant) |g| if ((g.after_sub and words.len <= 2) or (!g.after_sub and k == words.len)) {
        line.appendSlice(a, " ") catch {};
        line.appendSlice(a, g.option) catch {};
    };
    const inner = if (grant != null) a.print("sh -c {s}", .{singleQuoted(a, line.items)}) catch line.items else line.items;
    const opaque_opt = if (hidesWork(w)) " --opaque" else "";
    const run = a.print("cpuq run --label {s} --cores 2-6{s} -- {s}", .{ label, opaque_opt, inner }) catch "cpuq run --label P:T --cores 2-6 -- CMD";
    // On another machine: sent there by cpuq, the repo copied over, or through that machine's own.
    const sent = a.print("cpuq run --on {s} --label {s} --cores 2-6{s} -- {s}", .{ host orelse "", label, opaque_opt, inner }) catch run;
    return if (host) |h| a.print("{s} (it copies this repo to {s}; or ssh {s} 'cd … && {s}', the inner quotes as needed)", .{ sent, h, h, run }) catch run else run;
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
    return check(arena.allocator(), command, 10, "app", null) != null;
}

test "a plain cpuq run is never refused for where it runs" {
    try std.testing.expect(!refused("cpuq run --label app:test --cores 2 -- make test"));
    try std.testing.expect(!refused("cpuq run --on burst --cores 2 -- make test"));
    try std.testing.expect(!refused("ssh pup 'cd repo && cpuq run --cores 2 -- make'"));
    try std.testing.expect(!refused("cpuq lease w --host pup --exclusive -- ./bench"));
}

test "a minimum of 2 cores fits even a small machine" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(check(a, "cpuq run --cores 2-6 -- make", 3, "app", null) == null);
    try std.testing.expect(check(a, "cpuq run --cores 3 -- make", 4, "app", null) != null);
}

test "heavy commands outside cpuq are refused" {
    try std.testing.expect(refused("zig build test"));
    try std.testing.expect(refused("cd x && cargo test --release"));
    try std.testing.expect(refused("FOO=1 nice -n 5 make -j8"));
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
    try std.testing.expect(refused("pytest -n 4"));
    try std.testing.expect(!refused("cpuq lease pup-bench --host pup --exclusive --label kit -- ./bench.sh"));
    try std.testing.expect(!refused("cpuq status --json"));
    try std.testing.expect(!refused("echo 'zig build'"));
    try std.testing.expect(!refused("grep -r 'cargo build' ."));
    try std.testing.expect(!refused("zig build # cpuq: skip"));
    try std.testing.expect(!refused("cpuq run --label app:build --cores 2-6 -- sh -c 'zig build -j\"$CPUQ_CORES\" test'"));
    try std.testing.expect(!refused("cpuq run --label app:build -- make"));
    try std.testing.expect(!refused("ssh pup 'cd repo && cpuq run --label app:build -- make'"));
    try std.testing.expect(!refused("cpuq run --label lede:test --cores 4 --opaque -- nice xcodebuild test -destination 'platform=iOS Simulator,id=X' -jobs 4"));
    // A request for a bigger machine is judged by that machine, not this one.
    try std.testing.expect(!refused("cpuq run --on burst --label proj:matrix --cores 8-32 -- sh -c 'zig build -j\"$CPUQ_CORES\"'"));
    // cpuq cap limits a program but doesn't queue it: heavy work inside it is still refused.
    try std.testing.expect(refused("cpuq cap --time 600s -- zig build test"));
    try std.testing.expect(refused("cpuq cap --mem=2G -- make"));
    try std.testing.expect(!refused("cpuq cap --mem 2G --time 120s -- ./a.out"));
    try std.testing.expect(!refused("cpuq run --label app:test --cores 1 -- cpuq cap --mem 2G -- ./a.out"));
}

test "a heredoc's body is data unless a shell reads it" {
    // An apostrophe in a heredoc once opened a quote that swallowed the rest of the command.
    try std.testing.expect(!refused(
        \\python3 - <<'EOF'
        \\s = "the machine's load"
        \\EOF
        \\cpuq run --label cpuq:build --cores 2-6 -- sh -c 'zig build -j"$CPUQ_CORES" && zig build test -j"$CPUQ_CORES"'
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
    // Not heredocs: a here-string, and an arithmetic shift.
    try std.testing.expect(!refused("cat <<< 'zig build'"));
    try std.testing.expect(refused("echo $((1<<2)); zig build"));
}

test "misused cpuq runs are refused" {
    // The grant expanded by the typing shell.
    try std.testing.expect(refused("cpuq run --cores 2-6 -- make -j$CPUQ_CORES"));
    try std.testing.expect(refused("cpuq run --cores 2-6 -- sh -c \"zig build -j$CPUQ_CORES\""));
    // zig build with no -j.
    try std.testing.expect(refused("cpuq run --label a:b -- zig build"));
    try std.testing.expect(refused("cpuq run --label a:b -- sh -c 'cd x; zig build test'"));
    // Over half the CPUs, fixed or as a minimum.
    try std.testing.expect(refused("cpuq run --cores 10 -- make"));
    try std.testing.expect(refused("cpuq run --cores=8-10 -- make"));
    // Hidden work without --opaque.
    try std.testing.expect(refused("cpuq run --cores 4 -- incus exec ydb -- make"));
    try std.testing.expect(refused("cpuq run --cores 4 -- xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17'"));
}

test "a suggested jobs flag goes before the redirections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "cpuq run --label app:build --cores 2-6 -- sh -c 'zig build -j\"$CPUQ_CORES\" >/dev/null 2>&1'",
        suggest(a, &.{ "zig", "build", ">/dev/null", "2>&1" }, "app", null),
    );
    try std.testing.expectEqualStrings(
        "cpuq run --label app:test --cores 2-6 -- sh -c 'zig build test -j\"$CPUQ_CORES\" 2>log'",
        suggest(a, &.{ "zig", "build", "test", "2>log" }, "app", null),
    );
}

test "a run here is put to the advisor, with its command; one sent or pinned never is" {
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
    const r = check(a, "cpuq run --cores 2 --label rig:test -- sh -c './test/run -j \"$CPUQ_CORES\"'", 10, "app", ad);
    try std.testing.expectEqualStrings("slow here", r.?.reason);
    try std.testing.expectEqualStrings("sh -c ./test/run -j \"$CPUQ_CORES\"", seen.cmd);
    // Sent elsewhere, held for timing or hidden work: not asked.
    try std.testing.expect(check(a, "cpuq run --on burst --label rig:test -- make", 10, "app", ad) == null);
    try std.testing.expect(check(a, "cpuq run --exclusive --label rig:bench -- ./bench", 10, "app", ad) == null);
    try std.testing.expect(check(a, "cpuq run --opaque --cores 4 --label e:t -- incus exec c -- make", 10, "app", ad) == null);
    // On another machine, through its own cpuq: not this machine's history.
    try std.testing.expect(check(a, "ssh pup 'cd repo && cpuq run --label rig:test -- make'", 10, "app", ad) == null);
}

test "heavy work over ssh is pointed to --on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = check(arena.allocator(), "ssh burst 'cd repo && zig build test'", 10, "app", null).?;
    try std.testing.expect(std.mem.startsWith(u8, r.instead, "cpuq run --on burst --label app:test --cores 2-6 -- sh -c 'zig build test -j\"$CPUQ_CORES\"'"));
}

fn suggested(a: std.mem.Allocator, command: []const u8) []const u8 {
    return (check(a, command, 10, "app", null) orelse return "").instead;
}

test "a suggestion runs as typed: redirections whole, quotes kept, the tool's own grant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("cpuq run --label app:test --cores 2-6 -- sh -c 'cargo test -j \"$CPUQ_CORES\" 2>&1'", suggested(a, "cargo test 2>&1"));
    try std.testing.expectEqualStrings("cpuq run --label app:build --cores 2-6 -- sh -c 'go build -p \"$CPUQ_CORES\" ./...'", suggested(a, "go build ./..."));
    try std.testing.expectEqualStrings("cpuq run --label app:test --cores 2-6 -- sh -c 'pytest -q -n \"$CPUQ_CORES\"'", suggested(a, "pytest -n 8 -q"));
    try std.testing.expectEqualStrings("cpuq run --label app:build --cores 2-6 -- make all", suggested(a, "make -j8 all"));
    try std.testing.expectEqualStrings("cpuq run --label app:build --cores 2-6 -- sh -c 'zig build \"-Dname=a b\" -j\"$CPUQ_CORES\"'", suggested(a, "zig build -Dname='a b'"));
    try std.testing.expectEqualStrings("cpuq run --label app:build --cores 2-6 -- sh -c 'zig build '\\''-Dx=$HOME'\\'' -j\"$CPUQ_CORES\"'", suggested(a, "zig build '-Dx=$HOME'"));
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
    try std.testing.expect(refused("echo '# cpuq: skip'; zig build"));
    try std.testing.expect(refused("git log --grep='# cpuq: skip' && make"));
    try std.testing.expect(refused("ls # cpuq: skip\nmake"));
    // A comment on a heredoc's line still sets its body aside.
    try std.testing.expect(!refused("cat <<EOF # note\nmake\nEOF"));
    try std.testing.expect(refused("sh <<EOF # run it\nmake\nEOF"));
}

test "inside cpuq run, every option's value is skipped and a fixed jobs count is refused" {
    try std.testing.expect(refused("cpuq run --repo X --cores 2 -- zig build"));
    try std.testing.expect(refused("cpuq run --note x --label a:b -- zig build"));
    try std.testing.expect(refused("cpuq run --cores 2 -- make -j16"));
    try std.testing.expect(refused("cpuq run --cores 2 -- make -j"));
    try std.testing.expect(refused("cpuq run --cores 2 -- sh -c 'zig build -j16 test'"));
    try std.testing.expect(refused("cpuq run --cores 2 -- cargo build -j 16"));
    try std.testing.expect(refused("cpuq run --cores 2 -- pytest -n auto"));
    try std.testing.expect(refused("cpuq run --cores 2 -- env -u X sh -c 'zig build'"));
    try std.testing.expect(!refused("cpuq run --cores 2 -- sh -c 'pytest -n \"$CPUQ_CORES\"'"));
    try std.testing.expect(!refused("cpuq run --cores 1 -- make -j1"));
    try std.testing.expect(refused("cpuq run --cores 2 -- make -j install"));
    try std.testing.expect(refused("cpuq run --cores 2-6 -- make -j4"));
    try std.testing.expect(!refused("cpuq run --cores 4 -- make -j4"));
    try std.testing.expect(!refused("cpuq run --cores 2-6 -- sh -c 'go build -p \"$CPUQ_CORES\" ./...'"));
}
