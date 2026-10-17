//! Where a job finishes first. A job's work is known by what it runs, not by its label (agents
//! label one suite five ways): its repo and its command, counts and core numbers as `#`. Each
//! machine's history says how long that work took there; a run sent to another machine is kept in
//! this one's history too (pool "spill", host the machine), so the time it took there, copy and
//! queue included, is known here without asking. From those, `finish` gives each place's expected
//! finish (wait + start + copy + run) and `better` says whether going elsewhere is worth it.

const std = @import("std");
const history = @import("history.zig");

/// The work a command does, for history: `repo` (the repository's name, the same for each of its
/// worktrees and copies), a NUL, then the command with quotes dropped, `$CPUQ_CORES` and every run
/// of digits as `#`, and spaces collapsed. `./test/run -j 2 --delta` and
/// `./test/run -j "$CPUQ_CORES" --delta` are the same work.
pub fn workKey(a: std.mem.Allocator, repo: []const u8, cmd: []const u8) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(a, repo) catch return repo;
    out.append(a, 0) catch return repo;
    const text = cmd[0..@min(cmd.len, history.max_cmd)];
    var i: usize = 0;
    var space = true;
    while (i < text.len) {
        const ch = text[i];
        for ([_][]const u8{ "${CPUQ_CORES}", "$CPUQ_CORES" }) |v| {
            if (std.mem.startsWith(u8, text[i..], v)) {
                hash(a, &out);
                i += v.len;
                space = false;
                break;
            }
        } else {
            if (ch == '"' or ch == '\'') {
                i += 1;
                continue;
            }
            if (std.ascii.isWhitespace(ch)) {
                if (!space) out.append(a, ' ') catch {};
                space = true;
                i += 1;
                continue;
            }
            space = false;
            if (std.ascii.isDigit(ch)) {
                hash(a, &out);
                while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
                continue;
            }
            out.append(a, ch) catch {};
            i += 1;
        }
    }
    return std.mem.trimEnd(u8, out.items, " ");
}

/// `#`, once: `-j"$CPUQ_CORES"` and `-j 2` both end `-j#` / `-j #`.
fn hash(a: std.mem.Allocator, out: *std.ArrayList(u8)) void {
    if (out.items.len != 0 and out.items[out.items.len - 1] == '#') return;
    out.append(a, '#') catch {};
}

/// Whether a command takes its width from cpuq: it passes `$CPUQ_CORES` on, or is make (which
/// takes its job slots from cpuq's jobserver). A command with `-j 2` written in runs at 2
/// wherever it goes.
pub fn scales(cmd: []const u8) bool {
    if (std.mem.find(u8, cmd, "CPUQ_CORES") != null) return true;
    var words = std.mem.tokenizeAny(u8, cmd, " \t\n;&|()'\"");
    while (words.next()) |w| {
        const base = std.fs.path.basename(w);
        if (std.mem.eql(u8, base, "make") or std.mem.eql(u8, base, "gmake")) return true;
    }
    return false;
}

/// One kind of work's finished runs in one place.
pub const Stats = struct {
    runs: u32 = 0,
    /// The middle run's seconds (for a run sent with --on, the whole trip: copy and queue too).
    ran: f64 = 0,
    /// The 75th percentile of the cores it kept busy (its peak over 2 s, else its average).
    used: f64 = 0,
    /// The middle grant.
    cores: f64 = 0,
};

/// Builds `Stats` from runs added one at a time.
pub const Runs = struct {
    ran: std.ArrayList(f64) = .empty,
    used: std.ArrayList(f64) = .empty,
    cores: std.ArrayList(f64) = .empty,

    pub fn add(r: *Runs, a: std.mem.Allocator, ran: f64, used: ?f64, cores: ?u32) void {
        r.ran.append(a, ran) catch return;
        if (used) |u| r.used.append(a, u) catch {};
        if (cores) |k| r.cores.append(a, @floatFromInt(k)) catch {};
    }

    /// The last `keep` runs' figures (sorted in copies: the runs stay in order).
    pub fn stats(r: *const Runs, a: std.mem.Allocator, keep: usize) Stats {
        const n = r.ran.items.len;
        if (n == 0) return .{};
        return .{
            .runs = @intCast(@min(n, keep)),
            .ran = history.median(last(a, r.ran.items, keep)),
            .used = p75(last(a, r.used.items, keep)),
            .cores = history.median(last(a, r.cores.items, keep)),
        };
    }
};

fn last(a: std.mem.Allocator, xs: []const f64, keep: usize) []f64 {
    return a.dupe(f64, xs[xs.len - @min(xs.len, keep) ..]) catch &.{};
}

fn p75(xs: []f64) f64 {
    if (xs.len == 0) return 0;
    std.mem.sortUnstable(f64, xs, {}, std.sort.asc(f64));
    return xs[(xs.len - 1) * 3 / 4];
}

/// How long the work would run in a place with `cores` to give it, by that place's own runs
/// (`there`), else by this machine's (`here`): the same time, unless the command takes its width
/// from cpuq and used all it was given here, when more cores make it faster (up to 4 times what it
/// had, and no more than the place gives). Null when it has run in neither.
pub fn runTime(there: Stats, here: Stats, cores: u32, scaling: bool) ?f64 {
    if (there.runs != 0) return there.ran;
    if (here.runs == 0) return null;
    if (!scaling or here.cores < 1 or here.used < 0.8 * here.cores) return here.ran;
    const wider = @min(@as(f64, @floatFromInt(cores)), 4 * here.cores);
    return if (wider > here.cores) here.ran * here.cores / wider else here.ran;
}

/// A place a job could run: this machine or one of its remotes.
pub const Place = struct {
    name: []const u8,
    /// Expected seconds to its start: the queue there, and starting the machine when it is
    /// stopped.
    wait: f64 = 0,
    /// The copy there (0 here; less when a copy of this repo is there already).
    copy: f64 = 0,
    /// Its expected run time (`runTime`); null when unknown.
    run: ?f64 = null,

    pub fn finish(p: Place) ?f64 {
        return (p.run orelse return null) + p.wait + p.copy;
    }
};

/// Seconds to start a stopped remote: a cloud machine's boot and its cpuq answering.
pub const start_s: f64 = 120;
/// Seconds a first copy of a repo takes (Rig, 15k files: 33 s), and a repeat one.
pub const copy_first_s: f64 = 35;
pub const copy_again_s: f64 = 3;
/// A run expected to take less than this here stays here: nothing elsewhere could win enough to
/// pay for asking.
pub const short_s: f64 = 120;
/// A stopped host is started only for work expected to take longer than this here.
pub const start_worth_s: f64 = 600;
/// Work expected to take longer than this here is long: the hook asks whether it would finish
/// far sooner elsewhere.
pub const long_s: f64 = 600;

/// Whether finishing at `there` is worth leaving `here` for: sooner by at least a minute and by
/// at least 30%, so a near tie stays put (a copy, a cold cache, a guess that may be wrong).
pub fn better(here: f64, there: f64) bool {
    return there + @max(60, 0.3 * here) <= here;
}

/// The cores to ask for when a small fixed count was given for a command that takes its width
/// from cpuq: the count, widened to what the work has used, and to twice the count when it used
/// all it had (it would have used more); at most half the CPUs. Otherwise the count stands.
pub fn widen(n: u32, scaling: bool, work: Stats, cpus: u32) struct { min: u32, max: u32 } {
    const half = @max(cpus / 2, 1);
    // One core is often asked for on purpose: a serial run of a parallel tool.
    if (!scaling or work.runs < 2 or n < 2 or n >= half) return .{ .min = n, .max = n };
    const nf: f64 = @floatFromInt(n);
    const want: f64 = if (work.used >= 0.9 * nf) 2 * nf else @round(work.used + 0.3);
    const max: u32 = @intFromFloat(std.math.clamp(want, nf, @as(f64, @floatFromInt(half))));
    return .{ .min = n, .max = max };
}

/// Minutes or seconds, for a line a person reads: "~38 min", "~45 s".
pub fn approx(buf: []u8, s: f64) []const u8 {
    if (s >= 90) return std.fmt.bufPrint(buf, "~{d:.0} min", .{s / 60}) catch "?";
    return std.fmt.bufPrint(buf, "~{d:.0} s", .{s}) catch "?";
}

/// How a command matches a spec's `run`: the same program, and the spec's own words (`corpus`
/// in `./test/run --delta corpus "$@"`) all there.
pub const SpecMatch = struct {
    /// The spec's words matched: the more, the closer the match.
    words: usize,
    /// The command's other words, passed to the spec's `"$@"` (a test filter); "" when none.
    rest: []const u8,
};

/// Whether `cmd` (a job's command, its arguments joined) runs what a spec's `run` does, or null.
/// The spec's words and flags must all be there, but for a flag whose value is a variable (`-j
/// "$CPUQ_CORES"` is how to run it, not what) and counts (`-j 2` is the spec's `-j "$CPUQ_CORES"`).
/// A command with words or flags of its own matches only a run that takes `"$@"`.
pub fn specMatch(a: std.mem.Allocator, cmd: []const u8, run: []const u8) ?SpecMatch {
    const want = program(run) orelse return null;
    const have = program(cmd) orelse return null;
    if (!std.mem.eql(u8, want.name, have.name)) return null;
    const theirs = tokens(a, want.rest);
    const mine = tokens(a, have.rest);
    var words: usize = 0;
    for (theirs, 0..) |t, k| {
        if (!t.flag and (t.variable or t.count)) continue;
        // A flag that takes a variable's value: its own (`-j"$X"`) or the next word's.
        const takes = t.flag and (t.variable or (k + 1 < theirs.len and value(theirs[k + 1])));
        const at = for (mine, 0..) |m, i| {
            if (!m.used and m.flag == t.flag and std.mem.eql(u8, m.key, t.key)) break i;
        } else {
            if (takes) continue;
            return null;
        };
        mine[at].used = true;
        if (!t.flag) words += 1;
        if (takes and !mine[at].variable and at + 1 < mine.len) {
            const v = &mine[at + 1];
            if (!v.used and value(v.*)) v.used = true;
        }
    }
    // The rest, in order: a count only as an unmatched flag's value (`--seed 42`).
    var rest: std.ArrayList(u8) = .empty;
    for (mine, 0..) |m, i| {
        if (m.used) continue;
        if (m.count and !(i > 0 and mine[i - 1].flag and !mine[i - 1].used)) continue;
        rest.print(a, "{s}{s}", .{ if (rest.items.len == 0) "" else " ", m.word }) catch {};
    }
    if (rest.items.len != 0 and std.mem.find(u8, run, "$@") == null) return null;
    return .{ .words = words, .rest = rest.items };
}

/// A word of a command line, as specMatch compares it.
const Token = struct {
    /// Unquoted.
    word: []const u8,
    /// What is compared: the word, or a flag up to a variable joined to it (`-j"$X"` is `-j`).
    key: []const u8,
    flag: bool,
    /// It holds a `$` variable.
    variable: bool,
    /// A count or a duration: digits, '.', 'm', 's'.
    count: bool,
    used: bool = false,
};

/// A word that can be a flag's value: a count or a variable, but not `"$@"`, the command's own.
fn value(t: Token) bool {
    return !t.flag and (t.count or (t.variable and !std.mem.eql(u8, t.word, "$@") and !std.mem.eql(u8, t.word, "$*")));
}

fn tokens(a: std.mem.Allocator, text: []const u8) []Token {
    var out: std.ArrayList(Token) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\n");
    while (it.next()) |raw| {
        const w = std.mem.trim(u8, raw, "'\"");
        if (w.len == 0) continue;
        const flag = w[0] == '-' and w.len > 1;
        const cut = std.mem.findAny(u8, w, "\"'$") orelse w.len;
        const count = !flag and for (w) |ch| {
            if (!std.ascii.isDigit(ch) and ch != '.' and ch != 'm' and ch != 's') break false;
        } else true;
        out.append(a, .{ .word = w, .key = if (flag) w[0..cut] else w, .flag = flag, .variable = std.mem.findScalar(u8, w, '$') != null, .count = count }) catch {};
    }
    return out.items;
}

/// A command's program (`./` dropped) and what follows it, past variable assignments, `exec`,
/// `env`, a shell's `-c` and an interpreter (`python3 test/matrix.py` is test/matrix.py).
fn program(cmd: []const u8) ?struct { name: []const u8, rest: []const u8 } {
    var it = std.mem.tokenizeAny(u8, cmd, " \t\n");
    while (it.next()) |raw| {
        const w = std.mem.trim(u8, raw, "'\"");
        if (w.len == 0 or std.mem.findScalar(u8, w, '=') != null) continue;
        const base = std.fs.path.basename(w);
        if (std.mem.eql(u8, base, "exec") or std.mem.eql(u8, base, "env")) continue;
        const shells = [_][]const u8{ "sh", "bash", "zsh", "dash" };
        const interpreters = [_][]const u8{ "python", "python3", "node", "ruby", "perl" };
        const is_shell = for (shells) |x| {
            if (std.mem.eql(u8, base, x)) break true;
        } else false;
        const is_interp = for (interpreters) |x| {
            if (std.mem.eql(u8, base, x)) break true;
        } else false;
        if (is_shell or is_interp) {
            // `sh -c SCRIPT`, `python3 -u script.py`: past the flags to the script.
            while (it.peek()) |next| {
                if (next.len == 0 or next[0] != '-') break;
                _ = it.next();
            }
            continue;
        }
        const name = if (std.mem.startsWith(u8, w, "./")) w[2..] else w;
        return .{ .name = name, .rest = it.rest() };
    }
    return null;
}

const testing = std.testing;

test "a command matches the spec that runs the same thing" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const suite = "./test/run -j \"$CPUQ_CORES\" --delta \"$@\"";
    const corpus = "./test/run -j \"$CPUQ_CORES\" --delta corpus \"$@\"";
    const m = specMatch(a, "./test/run -j 2 --delta", suite).?;
    try testing.expectEqual(@as(usize, 0), m.words);
    try testing.expectEqualStrings("", m.rest);
    try testing.expectEqualStrings("lexer", specMatch(a, "sh -c ./test/run --delta -j \"$CPUQ_CORES\" lexer", suite).?.rest);
    // The corpus spec is the closer match for a corpus run; the suite takes it as a filter.
    try testing.expectEqual(@as(usize, 1), specMatch(a, "./test/run -j 2 --delta corpus", corpus).?.words);
    try testing.expectEqualStrings("corpus", specMatch(a, "./test/run -j 2 --delta corpus", suite).?.rest);
    try testing.expect(specMatch(a, "./test/run -j 2", corpus) == null);
    try testing.expect(specMatch(a, "zig build test", suite) == null);
    try testing.expect(specMatch(a, "python3 test/matrix.py -j 4 --delta", "python3 test/matrix.py -j \"$CPUQ_CORES\" --delta \"$@\"") != null);
    // Words of its own, for a run that takes none.
    try testing.expect(specMatch(a, "test/crash-trials extra", "test/crash-trials 20") == null);
    try testing.expect(specMatch(a, "test/crash-trials 50", "test/crash-trials 20") != null);
    // Flags are what runs: the spec's must be there, and others are words of the command's own.
    try testing.expect(specMatch(a, "./test/run --full", suite) == null);
    try testing.expectEqualStrings("--full", specMatch(a, "./test/run --delta --full", suite).?.rest);
    try testing.expect(specMatch(a, "zig build test -Doptimize=fast", "zig build test -j\"$CPUQ_CORES\"") == null);
    try testing.expect(specMatch(a, "zig build -j\"$CPUQ_CORES\" test", "zig build test -j\"$CPUQ_CORES\"") != null);
    // A flag carrying the cores may be left out; a count goes along with a flag of the command's own.
    try testing.expect(specMatch(a, "./test/run --delta", suite) != null);
    try testing.expectEqualStrings("--seed 42 lexer", specMatch(a, "./test/run -j 2 --delta --seed 42 lexer", suite).?.rest);
}

test "work is known by repo and command, not by counts or quoting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const k1 = workKey(a, "rig", "./test/run -j 2 --delta");
    try testing.expectEqualStrings("rig\x00./test/run -j # --delta", k1);
    try testing.expectEqualStrings(k1, workKey(a, "rig", "./test/run  -j \"$CPUQ_CORES\" --delta"));
    try testing.expectEqualStrings(k1, workKey(a, "rig", "./test/run -j ${CPUQ_CORES} --delta "));
    try testing.expectEqualStrings("app\x00sh -c zig build -j# test", workKey(a, "app", "sh -c 'zig build -j\"$CPUQ_CORES\" test'"));
    try testing.expect(!std.mem.eql(u8, k1, workKey(a, "trig", "./test/run -j 2 --delta")));
}

test "a command scales when it takes its width from cpuq" {
    try testing.expect(scales("sh -c 'zig build -j\"$CPUQ_CORES\"'"));
    try testing.expect(scales("make"));
    try testing.expect(scales("/usr/bin/make -C src"));
    try testing.expect(!scales("./test/run -j 2 --delta"));
    try testing.expect(!scales("makefile-lint"));
}

test "run time elsewhere: its own runs there, else here's, faster only if it scales" {
    const here: Stats = .{ .runs = 5, .ran = 2400, .used = 1.9, .cores = 2 };
    const burst: Stats = .{ .runs = 3, .ran = 400, .used = 6, .cores = 32 };
    try testing.expectEqual(@as(?f64, 400), runTime(burst, here, 32, true));
    // Never run there: a fixed -j 2 runs as long anywhere.
    try testing.expectEqual(@as(?f64, 2400), runTime(.{}, here, 32, false));
    // It scales and was short of cores here: up to 4x the cores it had.
    try testing.expectEqual(@as(?f64, 600), runTime(.{}, here, 32, true));
    try testing.expectEqual(@as(?f64, 1600), runTime(.{}, here, 3, true));
    // It had more than it used: no faster with more.
    try testing.expectEqual(@as(?f64, 900), runTime(.{}, .{ .runs = 2, .ran = 900, .used = 1.2, .cores = 4 }, 32, true));
    try testing.expectEqual(@as(?f64, null), runTime(.{}, .{}, 32, true));
}

test "leave only for a clear win" {
    try testing.expect(better(2400, 600));
    try testing.expect(!better(300, 250)); // a minute isn't 30% of five
    try testing.expect(!better(100, 50)); // half the time, but not a minute sooner
    try testing.expect(better(1000, 640));
    const p: Place = .{ .name = "burst", .wait = start_s, .copy = copy_first_s, .run = 400 };
    try testing.expectEqual(@as(?f64, 555), p.finish());
    try testing.expectEqual(@as(?f64, null), (Place{ .name = "x" }).finish());
}

test "a small fixed count widens only for work that takes its width from cpuq" {
    const busy: Stats = .{ .runs = 4, .ran = 600, .used = 2, .cores = 2 };
    try testing.expectEqual(@as(u32, 4), widen(2, true, busy, 10).max);
    try testing.expectEqual(@as(u32, 2), widen(2, false, busy, 10).max);
    try testing.expectEqual(@as(u32, 5), widen(4, true, .{ .runs = 4, .ran = 1, .used = 4, .cores = 4 }, 10).max);
    // It used less than it had: the count stands.
    try testing.expectEqual(@as(u32, 2), widen(2, true, .{ .runs = 4, .ran = 1, .used = 0.9, .cores = 2 }, 10).max);
    // Too little history.
    try testing.expectEqual(@as(u32, 2), widen(2, true, .{ .runs = 1, .ran = 1, .used = 2, .cores = 2 }, 10).max);
    // One core stays one.
    try testing.expectEqual(@as(u32, 1), widen(1, true, .{ .runs = 4, .ran = 1, .used = 1, .cores = 1 }, 10).max);
}

test "stats keep the last runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var r: Runs = .{};
    for (0..30) |i| r.add(a, if (i < 20) 10 else 100, 2, 4);
    const s = r.stats(a, 10);
    try testing.expectEqual(@as(u32, 10), s.runs);
    try testing.expectEqual(@as(f64, 100), s.ran);
    try testing.expectEqual(@as(f64, 4), s.cores);
}
