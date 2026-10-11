//! `cpuq hook`: an agent's guard. A coding agent's harness (Claude Code's
//! PreToolUse hook) passes each shell command here before running it; a
//! command that would load the machine outside cpuq, or misuse it, is refused
//! with the corrected form, so the queue is enforced where agents act rather
//! than asked for in AGENTS.md.
//!
//! It reads the command's text only: no state, no config, and nothing it
//! cannot parse is refused. A command marked `# cpuq: skip` runs as it is.

const std = @import("std");

/// Why a command is refused, and what to run instead.
pub const Refusal = struct {
    reason: []const u8,
    instead: []const u8,
};

/// Checks one shell command line. `cpus` is the machine's CPU count, for
/// requests over half of it; `project` names the job in suggested labels.
pub fn check(a: std.mem.Allocator, command: []const u8, cpus: u32, project: []const u8) ?Refusal {
    if (std.mem.find(u8, command, "# cpuq: skip") != null) return null;
    return checkScript(a, command, cpus, project, null, 0);
}

/// A simple command: its words, unquoted, and its text as written.
const Simple = struct {
    words: []const []const u8,
    text: []const u8,
};

fn checkScript(a: std.mem.Allocator, script: []const u8, cpus: u32, project: []const u8, host: ?[]const u8, depth: u32) ?Refusal {
    if (depth > 3) return null;
    const cmds = split(a, script) catch return null;
    for (cmds) |cmd| if (checkSimple(a, cmd, cpus, project, host, depth)) |r| return r;
    return null;
}

fn checkSimple(a: std.mem.Allocator, cmd: Simple, cpus: u32, project: []const u8, host: ?[]const u8, depth: u32) ?Refusal {
    const w = stripWrappers(cmd.words);
    if (w.len == 0) return null;
    const prog = std.fs.path.basename(w[0]);
    if (std.mem.eql(u8, prog, "cpuq")) return checkCpuq(a, cmd, w, cpus, project, depth);
    if (std.mem.eql(u8, prog, "ssh")) {
        const remote = sshRemote(a, w) orelse return null;
        return checkScript(a, remote.command, cpus, project, remote.host, depth + 1);
    }
    if (isShell(prog)) if (shellScript(w)) |s| return checkScript(a, s, cpus, project, host, depth + 1);
    const heavy_prog = heavyName(w) orelse return null;
    // "zig build", "cargo test": the program and its subcommand.
    const heavy = if (std.mem.eql(u8, heavy_prog, prog) and w.len > 1 and w[1].len > 0 and w[1][0] != '-' and isSubTool(prog))
        a.print("{s} {s}", .{ prog, w[1] }) catch heavy_prog
    else
        heavy_prog;
    const where = if (host) |h| a.print(" on {s}, through {s}'s cpuq", .{ h, h }) catch "" else "";
    return .{
        .reason = a.print("`{s}` runs outside cpuq{s}, so the other sessions' work can't be scheduled around it, and it uses as many CPUs as it likes", .{ heavy, where }) catch "a heavy command runs outside cpuq",
        .instead = suggest(a, w, project, host),
    };
}

/// A `cpuq run` (or lease): the grant must reach the command, not the shell
/// that types it; a large fixed request waits for an empty machine; work in a
/// container or simulator needs --opaque.
fn checkCpuq(a: std.mem.Allocator, cmd: Simple, w: []const []const u8, cpus: u32, project: []const u8, depth: u32) ?Refusal {
    if (w.len < 2) return null;
    const sub = w[1];
    if (!std.mem.eql(u8, sub, "run") and !std.mem.eql(u8, sub, "lease")) return null;
    if (expandsEarly(cmd.text)) return .{
        .reason = "`$CPUQ_CORES` is expanded by your shell before cpuq sets it, so the command gets nothing there (and `make -j` with nothing after it has no limit)",
        .instead = quotedInside(a, cmd.text),
    };
    var opaque_flag = false;
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
        const value: ?[]const u8 = if (std.mem.startsWith(u8, o, "--cores=")) o["--cores=".len..] else if (std.mem.eql(u8, o, "--cores") and i + 1 < w.len) w[i + 1] else null;
        if (value) |v| min_cores = std.fmt.parseInt(u32, std.mem.sliceTo(v, '-'), 10) catch null;
        // Options that take a value skip it.
        for ([_][]const u8{ "--cores", "--priority", "--label", "--max-wait", "--qos", "--host", "--slots" }) |takes| {
            if (std.mem.eql(u8, o, takes)) i += 1;
        }
    }
    // Over half the CPUs, and more than 2: a minimum of 2 fits even a small machine.
    if (min_cores) |m| if (m > @max(cpus / 2, 2)) return .{
        .reason = a.print("asking for at least {d} cores on a {d}-CPU machine: a request over half the CPUs waits until the machine is nearly empty", .{ m, cpus }) catch "too many cores asked for",
        .instead = "ask for a range the job can shrink to, such as --cores 2-6, and pass \"$CPUQ_CORES\" on; run big jobs on the larger machine",
    };
    if (i >= w.len) return null;
    const inner = w[i..];
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
    }
    _ = project;
    _ = depth;
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
    const sub = if (w.len >= 2) w[1] else "";
    // Help, a version, a dry run or a listing: no work.
    const make_like = std.mem.eql(u8, prog, "make") or std.mem.eql(u8, prog, "gmake");
    const no_work: []const []const u8 = if (make_like)
        &.{ "-n", "--dry-run", "--just-print", "--recon", "-q", "--question", "-p", "--print-data-base" }
    else if (std.mem.eql(u8, prog, "ninja"))
        &.{ "-n", "-t" }
    else if (std.mem.eql(u8, prog, "xcodebuild"))
        &.{ "-list", "-showsdks", "-showBuildSettings", "-showdestinations", "-version", "-showTestPlans" }
    else
        &.{};
    for (w[1..]) |x| {
        for ([_][]const u8{ "--help", "-h", "--version", "-version" }) |q| if (std.mem.eql(u8, x, q)) return null;
        for (no_work) |q| if (std.mem.eql(u8, x, q)) return null;
    }
    const Heavy = struct { prog: []const u8, subs: []const []const u8 };
    const table = [_]Heavy{
        .{ .prog = "zig", .subs = &.{"build"} },
        .{ .prog = "cargo", .subs = &.{ "build", "b", "test", "t", "check", "c", "clippy", "run", "r", "bench", "nextest", "doc", "install", "miri" } },
        .{ .prog = "swift", .subs = &.{ "build", "test", "run" } },
        .{ .prog = "go", .subs = &.{ "build", "test", "install" } },
        .{ .prog = "bazel", .subs = &.{ "build", "test", "run", "coverage" } },
        .{ .prog = "bazelisk", .subs = &.{ "build", "test", "run", "coverage" } },
        .{ .prog = "buck2", .subs = &.{ "build", "test", "run" } },
        .{ .prog = "cmake", .subs = &.{"--build"} },
        .{ .prog = "python3", .subs = &.{"-m"} },
        .{ .prog = "python", .subs = &.{"-m"} },
    };
    for (table) |h| if (std.mem.eql(u8, prog, h.prog)) {
        for (h.subs) |s| if (std.mem.eql(u8, sub, s)) {
            if (std.mem.eql(u8, s, "-m")) {
                if (w.len >= 3 and std.mem.eql(u8, w[2], "pytest")) return "python -m pytest";
                return null;
            }
            return prog;
        };
        return null;
    };
    for ([_][]const u8{ "make", "gmake", "ninja", "xcodebuild", "pytest", "py.test", "gradle", "gradlew", "mvn", "mvnw" }) |p| {
        if (std.mem.eql(u8, prog, p)) return p;
    }
    return null;
}

/// Skips what only wraps a command: variable assignments, and nice, time,
/// env, exec, command, nohup, caffeinate, stdbuf and timeout with their
/// options.
fn stripWrappers(words: []const []const u8) []const []const u8 {
    var w = words;
    while (w.len > 0) {
        const x = w[0];
        if (isAssignment(x)) {
            w = w[1..];
            continue;
        }
        const prog = std.fs.path.basename(x);
        const wrapper = for ([_][]const u8{ "nice", "time", "env", "exec", "command", "nohup", "caffeinate", "stdbuf", "timeout", "nocache", "ionice", "chrt", "taskset", "unbuffer" }) |p| {
            if (std.mem.eql(u8, prog, p)) break true;
        } else false;
        if (!wrapper) break;
        w = w[1..];
        // Their options, and timeout's duration, nice's -n N.
        while (w.len > 0 and (w[0].len > 0 and (w[0][0] == '-' or isAssignment(w[0])))) {
            const opt = w[0];
            w = w[1..];
            if ((std.mem.eql(u8, opt, "-n") or std.mem.eql(u8, opt, "-c") or std.mem.eql(u8, opt, "-s") or std.mem.eql(u8, opt, "-k")) and w.len > 0) w = w[1..];
        }
        if (std.mem.eql(u8, prog, "timeout") and w.len > 0) w = w[1..];
        if ((std.mem.eql(u8, prog, "taskset") or std.mem.eql(u8, prog, "chrt")) and w.len > 0) w = w[1..];
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

fn isShell(prog: []const u8) bool {
    for ([_][]const u8{ "sh", "bash", "zsh", "dash" }) |s| if (std.mem.eql(u8, prog, s)) return true;
    return false;
}

/// The script of `sh -c SCRIPT` (or -lc, -ec …).
fn shellScript(w: []const []const u8) ?[]const u8 {
    var i: usize = 1;
    while (i < w.len) : (i += 1) {
        const x = w[i];
        if (x.len > 1 and x[0] == '-' and std.mem.findScalar(u8, x, 'c') != null and x[1] != '-') return if (i + 1 < w.len) w[i + 1] else null;
        if (x.len == 0 or x[0] != '-') return null;
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
            if (x.len == 2 and std.mem.findScalar(u8, "bcDEeFIiJLlmOoPpQRSWw", x[1]) != null) i += 1;
            continue;
        }
        if (i + 1 >= w.len) return null;
        return .{ .host = x, .command = std.mem.join(a, " ", w[i + 1 ..]) catch return null };
    }
    return null;
}

/// What to run instead: the command under cpuq, the grant passed on.
fn suggest(a: std.mem.Allocator, w: []const []const u8, project: []const u8, host: ?[]const u8) []const u8 {
    const prog = std.fs.path.basename(w[0]);
    const label = a.print("{s}:{s}", .{ if (project.len != 0) project else "proj", if (std.mem.eql(u8, prog, "pytest") or std.mem.eql(u8, prog, "xcodebuild")) "test" else "build" }) catch "proj:build";
    const original = std.mem.join(a, " ", w) catch "CMD";
    const inner = if (std.mem.eql(u8, prog, "zig") and !hasJobs(w))
        a.print("sh -c '{s} -j\"$CPUQ_CORES\"'", .{original}) catch original
    else if (std.mem.eql(u8, prog, "cargo"))
        a.print("sh -c 'CARGO_BUILD_JOBS=\"$CPUQ_CORES\" {s}'", .{original}) catch original
    else if (std.mem.eql(u8, prog, "xcodebuild"))
        a.print("sh -c '{s} -jobs \"$CPUQ_CORES\"'", .{original}) catch original
    else
        original;
    const opaque_opt = if (hidesWork(w)) " --opaque" else "";
    const run = a.print("cpuq run --label {s} --cores 2-6{s} -- {s}", .{ label, opaque_opt, inner }) catch "cpuq run --label P:T --cores 2-6 -- CMD";
    return if (host) |h| a.print("ssh {s} 'cd … && {s}' (the inner quotes as needed)", .{ h, run }) catch run else run;
}

/// Splits a script into simple commands: at unquoted ; & | && || newlines,
/// ( ) and the edges of $( … ) and backquotes, with each word unquoted.
fn split(a: std.mem.Allocator, script: []const u8) ![]Simple {
    var out: std.ArrayList(Simple) = .empty;
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
                while (i < script.len and script[i] != '\n') : (i += 1) {}
                try flushWord(a, &words, &word, &in_word);
                try flushCmd(a, &out, &words, script[start..i]);
                start = i + 1;
            } else try word.append(a, ch),
            ' ', '\t' => try flushWord(a, &words, &word, &in_word),
            ';', '&', '|', '\n', '(', ')', '`' => {
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
    return check(arena.allocator(), command, 10, "app") != null;
}

test "a minimum of 2 cores fits even a small machine" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect(check(a, "cpuq run --cores 2-6 -- make", 3, "app") == null);
    try std.testing.expect(check(a, "cpuq run --cores 3 -- make", 4, "app") != null);
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
