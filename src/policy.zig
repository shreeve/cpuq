//! Pure decisions: the configuration file, the machine's gates, CPU lists and project weights.
//! Every input is a value, so the unit tests inject them.
const std = @import("std");
const builtin = @import("builtin");

/// The scheduling class a command runs in. On macOS `utility` and
/// `background` are QoS classes; on Linux they are nice 5 and 15.
/// How a command is started: as it is; at utility or background QoS (macOS) or
/// nice 5 or 15 (Linux); or at nice 10 with its QoS left alone (`niced`).
pub const Qos = enum { unchanged, utility, background, niced };

pub const Config = struct {
    /// The pool's size: the first this many of its CPUs (`budget`); null: every one.
    budget: ?u32 = null,
    /// Hand out no CPU while the OS reports memory pressure.
    pressure_check: bool = true,
    /// Hand out only the CPUs the machine has idle, judged by its busy CPUs against the CPUs
    /// held (`outside_check`). Off, the pool alone limits CPU work.
    outside_check: bool = true,
    /// Linux: the `some avg10` percentage of /proc/pressure/memory that
    /// counts as pressure.
    pressure_psi: f64 = 10,
    /// Hand out no CPU while the memory the kernel says is available falls
    /// under this, in bytes (`min_available`, e.g. 6G); 0 leaves it unchecked.
    min_available: u64 = 0,
    /// Hand out no CPU while the filesystem holding $HOME or cpuq's state
    /// directory (the temp directory) has less than this free, in bytes
    /// (`min_disk`, e.g. 5G); 0 leaves it unchecked. A full disk fails every
    /// task and every tool that writes a file; on 2026-10-11 one session's
    /// scratch files filled this Mac's disk to its last byte.
    min_disk: u64 = 5 << 30,
    /// Linux: run each test runner (`cpuq run --driver`) in a delegated cgroup of its own (a
    /// systemd user scope), its command in the scope's `job/`, so `cpuq cap` can give each
    /// program it starts a cgroup beside it, with limits the kernel enforces (`cgroups`).
    cgroups: bool = true,
    /// The pool's CPUs, in the order they are handed out, as a Linux CPU list (`cpus`, e.g.
    /// "12-19"); empty: worked out from the machine (cpus.zig).
    cpus: []const u8 = "",
    /// Each task's time limit, in seconds, when a run gives none with -t (`timeout`, e.g. 1h;
    /// off: none).
    timeout_s: u32 = 3600,
    /// Project weights for sharing the pool (`weights`, e.g. "rig:2 trig:1"); a project not
    /// named weighs 1.
    weights: []const u8 = "",
    /// Directories `cpuq submit` may ship, and take `deps` from, separated by commas or spaces
    /// (`submit_roots`; empty: ~/Data/Code).
    submit_roots: []const u8 = "",
    /// What jobs left (copies, pack versions, job records) goes once unused this long
    /// (`clean_after`, e.g. 3d; off: never), by `cpuq record` hourly and `cpuq clean`.
    clean_after_s: u32 = 3 * 86400,
    /// The machines this one can send work to, in the order tried: ssh names, separated by
    /// commas or spaces (`remotes`). `--on HOST` names one; `cpuq submit` chooses among them.
    /// Each machine lists the ones it can reach: a cloud host may list none.
    remotes: []const u8 = "",
    /// Copies of one worktree a submitted job may use on its host (`submit_slots`, 1–8): so many
    /// of a worktree's jobs run there at once; 1 runs them one after another on a single copy.
    submit_slots: u32 = 3,
    /// How to start a remote that is stopped, such as a cloud machine:
    /// `remote_start.HOST = COMMAND`, run with sh; it should return once
    /// `ssh HOST` works.
    remote_starts: [max_remote_lines]RemoteLine = @splat(.{}),
    remote_start_count: u8 = 0,
    /// What a job's shell exports on HOST before cpuq runs it there:
    /// `remote_env.HOST = PATH=$HOME/.local/go/bin:$PATH` (one or more shell
    /// assignments, expanded by HOST's shell). An ssh command's shell reads
    /// no login profile, so tools under ~/.local are off its PATH.
    remote_envs: [max_remote_lines]RemoteLine = @splat(.{}),
    remote_env_count: u8 = 0,

    /// The remotes, in order.
    pub fn remoteHosts(self: *const Config) std.mem.TokenIterator(u8, .any) {
        return std.mem.tokenizeAny(u8, self.remotes, ", \t");
    }

    /// Whether `host` is one of the remotes.
    pub fn isRemote(self: *const Config, host: []const u8) bool {
        var it = self.remoteHosts();
        while (it.next()) |h| if (std.mem.eql(u8, h, host)) return true;
        return false;
    }

    /// The command that starts `host`, if one is configured.
    pub fn remoteStart(self: *const Config, host: []const u8) ?[]const u8 {
        for (self.remote_starts[0..self.remote_start_count]) |s| if (std.mem.eql(u8, s.host, host)) return s.cmd;
        return null;
    }

    /// The assignments a job sent to `host` exports there, if any.
    pub fn remoteEnv(self: *const Config, host: []const u8) ?[]const u8 {
        for (self.remote_envs[0..self.remote_env_count]) |s| if (std.mem.eql(u8, s.host, host)) return s.cmd;
        return null;
    }
};

pub const max_remote_lines = 8;

pub const RemoteLine = struct {
    host: []const u8 = "",
    cmd: []const u8 = "",
    /// The config line it came from, for the error when HOST is not one of the remotes.
    line: usize = 0,
};

pub const Diagnostic = struct {
    line: usize = 0,
    key: []const u8 = "",
    message: []const u8 = "",
};

/// What a key's value is, and so how it is read.
const Kind = enum { on_off, whole, number, bytes, age, text };

/// A config key: the Config field it sets, how its value reads, and the bounds of a number.
const Key = struct {
    name: []const u8,
    field: []const u8,
    kind: Kind,
    min: f64 = 0,
    max: f64 = 0,
    unit: []const u8 = "",

    fn message(comptime k: Key) []const u8 {
        const of = if (k.unit.len == 0) "" else " of " ++ k.unit;
        return switch (k.kind) {
            .on_off => k.name ++ " must be on or off",
            .whole => std.fmt.comptimePrint("{s} must be a whole number{s}, {d} to {d}", .{ k.name, of, k.min, k.max }),
            .number => std.fmt.comptimePrint("{s} must be a number{s}, {d} to {d}", .{ k.name, of, k.min, k.max }),
            .bytes => k.name ++ " must be off or a size such as 5G or 512M",
            .age => k.name ++ " must be off or a time such as 3d, 36h or 90m",
            .text => unreachable,
        };
    }
};

const keys = [_]Key{
    .{ .name = "budget", .field = "budget", .kind = .whole, .min = 1, .max = 4096, .unit = "CPUs" },
    .{ .name = "pressure_check", .field = "pressure_check", .kind = .on_off },
    .{ .name = "outside_check", .field = "outside_check", .kind = .on_off },
    .{ .name = "pressure_psi", .field = "pressure_psi", .kind = .number, .min = 0, .max = 100 },
    .{ .name = "min_available", .field = "min_available", .kind = .bytes },
    .{ .name = "min_disk", .field = "min_disk", .kind = .bytes },
    .{ .name = "cgroups", .field = "cgroups", .kind = .on_off },
    .{ .name = "cpus", .field = "cpus", .kind = .text },
    .{ .name = "timeout", .field = "timeout_s", .kind = .age },
    .{ .name = "weights", .field = "weights", .kind = .text },
    .{ .name = "submit_roots", .field = "submit_roots", .kind = .text },
    .{ .name = "clean_after", .field = "clean_after_s", .kind = .age },
    .{ .name = "remotes", .field = "remotes", .kind = .text },
    .{ .name = "submit_slots", .field = "submit_slots", .kind = .whole, .min = 1, .max = 8 },
};

/// Keys cpuq does not take, each with what does that work: a config naming one fails with
/// that line, so whoever wrote it learns what to write instead.
pub const removed_keys = [_][2][]const u8{
    .{ "admit", "admit is gone: the pool hands out one CPU per task" },
    .{ "target", "target is gone: the pool hands out one CPU per task; budget or cpus sizes the pool" },
    .{ "settle", "settle is gone: the pool hands out one CPU per task, never by measured use" },
    .{ "right_size", "right_size is gone: a run holds one CPU per running task" },
    .{ "poll", "poll is gone: a run waits for the line to wake it, not on a timer" },
    .{ "aging", "aging is gone: the line takes turns by project weight (weights)" },
    .{ "note", "note is gone: cpuq status says why each run waits" },
    .{ "backfill", "backfill is gone: a free CPU goes to the first in the line" },
    .{ "window_backfill", "window_backfill is gone: a free CPU goes to the first in the line" },
    .{ "patience", "patience is gone: a free CPU goes to the first in the line" },
    .{ "exclusive", "exclusive is gone: `cpuq drain -- CMD` empties the machine and runs CMD alone" },
    .{ "window_gap", "window_gap is gone: `cpuq drain -- CMD` empties the machine and runs CMD alone" },
    .{ "window_lend", "window_lend is gone: `cpuq drain -- CMD` empties the machine and runs CMD alone" },
    .{ "lend", "lend is gone: a run gives back each CPU it has no task for" },
    .{ "lend_after", "lend_after is gone: a run gives back each CPU it has no task for" },
    .{ "cpu_weights", "cpu_weights is gone: each task has a CPU of its own (pinned on Linux)" },
    .{ "affinity", "affinity is gone: each task is pinned to its own CPU on Linux" },
    .{ "load_check", "load_check is gone: outside load is measured, never the load average" },
    .{ "load_margin", "load_margin is gone: outside load is measured, never the load average" },
    .{ "active_cap", "active_cap is gone: the pool is the CPUs online (budget or cpus narrows it)" },
    .{ "qos", "qos is gone: tasks run as they are" },
    .{ "max_memory", "max_memory is gone: limit a task with cpuq cap --mem" },
};

/// Parses `key = value` lines. `#` starts a comment at the start of a line or after a space or
/// tab, so a value may hold one (`a#b`). Each key appears at most once; `remote_start.HOST` and
/// `remote_env.HOST` once per HOST, and HOST must be one of the remotes.
pub fn parseConfig(text: []const u8, cfg: *Config, diag: *Diagnostic) error{ConfigInvalid}!void {
    var seen: std.StaticBitSet(keys.len) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    next: while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw[0..commentStart(raw)], " \t\r");
        if (line.len == 0) continue;
        diag.line = n;
        diag.key = line;
        const key_raw, const value_raw = std.mem.cutScalar(u8, line, '=') orelse return bad(diag, "expected key = value");
        const key = std.mem.trim(u8, key_raw, " \t");
        diag.key = key;
        const value = std.mem.trim(u8, value_raw, " \t");
        inline for (keys, 0..) |k, i| if (std.mem.eql(u8, key, k.name)) {
            if (seen.isSet(i)) return bad(diag, "set twice");
            seen.set(i);
            const field = &@field(cfg, k.field);
            switch (k.kind) {
                .on_off => field.* = parseBool(value) orelse return bad(diag, comptime k.message()),
                .whole => {
                    const w = parseWhole(u32, value) orelse return bad(diag, comptime k.message());
                    if (@as(f64, @floatFromInt(w)) < k.min or @as(f64, @floatFromInt(w)) > k.max) return bad(diag, comptime k.message());
                    field.* = w;
                },
                .number => {
                    const x = parseDecimal(value) orelse return bad(diag, comptime k.message());
                    if (x < k.min or x > k.max) return bad(diag, comptime k.message());
                    field.* = x;
                },
                .bytes => field.* = parseBytes(value) orelse return bad(diag, comptime k.message()),
                .age => field.* = parseAge(value) orelse return bad(diag, comptime k.message()),
                .text => field.* = value,
            }
            continue :next;
        };
        for (removed_keys) |r| if (std.mem.eql(u8, key, r[0])) return bad(diag, r[1]);
        if (std.mem.cutPrefix(u8, key, "remote_start.")) |host| {
            if (value.len == 0) return bad(diag, "remote_start needs a command to start the host");
            try addRemoteLine(&cfg.remote_starts, &cfg.remote_start_count, host, value, n, diag);
        } else if (std.mem.cutPrefix(u8, key, "remote_env.")) |host| {
            if (std.mem.findScalar(u8, value, '=') == null) return bad(diag, "remote_env needs assignments: NAME=VALUE ...");
            try addRemoteLine(&cfg.remote_envs, &cfg.remote_env_count, host, value, n, diag);
        } else return bad(diag, "unknown key");
    }
    inline for (.{ "remote_start.", "remote_env." }, .{ cfg.remote_starts[0..cfg.remote_start_count], cfg.remote_envs[0..cfg.remote_env_count] }) |prefix, list| {
        for (list) |r| if (!cfg.isRemote(r.host)) {
            diag.line = r.line;
            diag.key = r.host;
            return bad(diag, prefix ++ "HOST must name one of the remotes");
        };
    }
}

fn addRemoteLine(list: *[max_remote_lines]RemoteLine, count: *u8, host: []const u8, value: []const u8, line: usize, diag: *Diagnostic) error{ConfigInvalid}!void {
    if (host.len == 0) return bad(diag, "needs a host: remote_start.HOST or remote_env.HOST");
    for (list[0..count.*]) |r| if (std.mem.eql(u8, r.host, host)) return bad(diag, "set twice");
    if (count.* == max_remote_lines) return bad(diag, std.fmt.comptimePrint("at most {d} hosts", .{max_remote_lines}));
    list[count.*] = .{ .host = host, .cmd = value, .line = line };
    count.* += 1;
}

/// Where a line's comment starts: a `#` at the start or after a space or tab; the line's length
/// when it has none.
fn commentStart(raw: []const u8) usize {
    for (raw, 0..) |ch, i| if (ch == '#' and (i == 0 or raw[i - 1] == ' ' or raw[i - 1] == '\t')) return i;
    return raw.len;
}

/// A size: off (0), or a whole number with an optional K, M or G (powers of
/// 1024); a bare number is in bytes.
pub fn parseBytes(s: []const u8) ?u64 {
    if (std.mem.eql(u8, s, "off")) return 0;
    if (s.len == 0) return null;
    const unit: u64 = switch (s[s.len - 1]) {
        'K', 'k' => 1 << 10,
        'M', 'm' => 1 << 20,
        'G', 'g' => 1 << 30,
        '0'...'9' => 1,
        else => return null,
    };
    const digits = if (unit == 1) s else s[0 .. s.len - 1];
    const n = parseWhole(u64, digits) orelse return null;
    return std.math.mul(u64, n, unit) catch null;
}

test "sizes" {
    try std.testing.expectEqual(@as(?u64, 16 << 30), parseBytes("16G"));
    try std.testing.expectEqual(@as(?u64, 512 << 20), parseBytes("512M"));
    try std.testing.expectEqual(@as(?u64, 0), parseBytes("off"));
    try std.testing.expectEqual(@as(?u64, 1000), parseBytes("1000"));
    try std.testing.expectEqual(@as(?u64, null), parseBytes("lots"));
    try std.testing.expectEqual(@as(?u64, null), parseBytes("G"));
}

fn bad(diag: *Diagnostic, message: []const u8) error{ConfigInvalid} {
    diag.message = message;
    return error.ConfigInvalid;
}

/// `3d`, `36h`, `90m`, `600s` (or `600`), in seconds; `off` is 0.
pub fn parseAge(s: []const u8) ?u32 {
    if (std.mem.eql(u8, s, "off")) return 0;
    if (s.len == 0) return null;
    const unit: u32 = switch (s[s.len - 1]) {
        'd' => 86400,
        'h' => 3600,
        'm' => 60,
        's' => 1,
        '0'...'9' => 1,
        else => return null,
    };
    const digits = if (std.ascii.isDigit(s[s.len - 1])) s else s[0 .. s.len - 1];
    const n = parseWhole(u32, digits) orelse return null;
    if (n == 0) return null;
    return std.math.mul(u32, n, unit) catch null;
}

test "parseAge" {
    try std.testing.expectEqual(@as(?u32, 3 * 86400), parseAge("3d"));
    try std.testing.expectEqual(@as(?u32, 36 * 3600), parseAge("36h"));
    try std.testing.expectEqual(@as(?u32, 5400), parseAge("90m"));
    try std.testing.expectEqual(@as(?u32, 600), parseAge("600"));
    try std.testing.expectEqual(@as(?u32, 0), parseAge("off"));
    try std.testing.expectEqual(@as(?u32, null), parseAge("3x"));
    try std.testing.expectEqual(@as(?u32, null), parseAge("0d"));
}

/// A job's label: parts split by `:` (`project:task`), each of lowercase letters, digits, `.`, `_`
/// and `-`, none starting with `.`, and the first not with `-`. A project names directories on
/// the hosts a job is sent to, so it never needs quoting there and never climbs out of them.
pub fn validLabel(s: []const u8) bool {
    if (s.len == 0 or s.len > 128 or s[0] == '-') return false;
    var parts = std.mem.splitScalar(u8, s, ':');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '.') return false;
        for (part) |ch| switch (ch) {
            'a'...'z', '0'...'9', '.', '_', '-' => {},
            else => return false,
        };
    }
    return true;
}

test "labels" {
    for ([_][]const u8{ "app:build", "cpuq", "emdb:gate-linux", "a.b_c-d:x:y", "0:9" }) |s| try std.testing.expect(validLabel(s));
    for ([_][]const u8{ "", "App:build", "app:", ":x", "a::b", "../../x:y", ".git:x", "-x", "a b:c", "a$b:c", "a/b:c", "app:*" }) |s| try std.testing.expect(!validLabel(s));
}

/// A whole number, at least 1.
pub fn parseCount(s: []const u8) ?u32 {
    const n = parseWhole(u32, s) orelse return null;
    return if (n >= 1) n else null;
}

/// A whole number written in decimal digits alone: no sign, no `_`.
pub fn parseWhole(comptime T: type, s: []const u8) ?T {
    if (s.len == 0) return null;
    for (s) |ch| if (!std.ascii.isDigit(ch)) return null;
    return std.fmt.parseInt(T, s, 10) catch null;
}

/// A number written in decimal digits with at most one point (`4`, `0.5`).
fn parseDecimal(s: []const u8) ?f64 {
    var points: usize = 0;
    var digits: usize = 0;
    for (s) |ch| switch (ch) {
        '0'...'9' => digits += 1,
        '.' => points += 1,
        else => return null,
    };
    if (digits == 0 or points > 1) return null;
    return std.fmt.parseFloat(f64, s) catch null;
}

fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes")) return true;
    if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no")) return false;
    return null;
}

/// Memory pressure as the OS reports it; `unknown` when it reports nothing,
/// `off` when `pressure_check` is off.
pub const Pressure = enum { normal, high, unknown, off };

/// macOS kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical.
pub fn macPressure(level: c_int) Pressure {
    // Critical only. The warn level (2) can last many minutes with half the
    // memory free: on 2026-10-07 it shut the gate for 8 minutes with 46-49%
    // free and under 1 GB of swap, holding up to 4 jobs while the CPUs sat
    // idle. A runaway program is `cpuq cap --mem`'s to stop.
    return if (level >= 4) .high else .normal;
}

/// Linux /proc/pressure/memory: pressure when `some avg10` reaches the
/// threshold percentage.
pub fn psiPressure(text: []const u8, threshold: f64) Pressure {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "some ")) continue;
        var fields = std.mem.tokenizeScalar(u8, line[5..], ' ');
        while (fields.next()) |f| {
            const v = std.mem.cutPrefix(u8, f, "avg10=") orelse continue;
            const x = std.fmt.parseFloat(f64, v) catch return .unknown;
            return if (x >= threshold) .high else .normal;
        }
    }
    return .unknown;
}

/// The number of CPUs in a Linux CPU list such as "0-7" or "0,2-5,8\n"
/// (/sys/devices/system/cpu/present); null when it is not one.
pub fn cpuListCount(text: []const u8) ?u32 {
    var n: u32 = 0;
    var parts = std.mem.tokenizeAny(u8, text, ", \n");
    while (parts.next()) |part| {
        if (std.mem.cutScalar(u8, part, '-')) |range| {
            const lo = std.fmt.parseInt(u32, range[0], 10) catch return null;
            const hi = std.fmt.parseInt(u32, range[1], 10) catch return null;
            if (hi < lo) return null;
            n += hi - lo + 1;
        } else {
            _ = std.fmt.parseInt(u32, part, 10) catch return null;
            n += 1;
        }
    }
    return if (n > 0) n else null;
}

/// The CPUs in a Linux CPU list ("0-3,8"), in its order.
pub fn cpuList(a: std.mem.Allocator, text: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    var parts = std.mem.tokenizeAny(u8, text, ", \n");
    while (parts.next()) |part| {
        const lo_text, const hi_text = std.mem.cutScalar(u8, part, '-') orelse .{ part, part };
        const lo = try std.fmt.parseInt(u32, lo_text, 10);
        const hi = try std.fmt.parseInt(u32, hi_text, 10);
        if (hi < lo or hi - lo > 4096) return error.InvalidCpuList;
        for (lo..hi + 1) |cpu| try out.append(a, @intCast(cpu));
    }
    return out.items;
}

/// `cpus`, ascending, as a CPU list with runs as ranges ("0-3,8").
pub fn cpuListText(a: std.mem.Allocator, cpus: []const u32) []const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    var i: usize = 0;
    while (i < cpus.len) {
        var j = i;
        while (j + 1 < cpus.len and cpus[j + 1] == cpus[j] + 1) j += 1;
        const sep: []const u8 = if (i == 0) "" else ",";
        if (j == i) out.writer.print("{s}{d}", .{ sep, cpus[i] }) catch return "" else out.writer.print("{s}{d}-{d}", .{ sep, cpus[i], cpus[j] }) catch return "";
        i = j + 1;
    }
    return out.written();
}

/// What the machine looks like at the moment a CPU may be handed out.
pub const Machine = struct {
    active: u32,
    load1: f64,
    pressure: Pressure,
    /// The share of all CPUs busy since the last look, 0 to 1; null when
    /// not measured.
    busy: ?f64 = null,
    /// Memory available, in bytes (Linux MemAvailable; macOS the kernel's
    /// free share of memory); null when not read.
    available: ?u64 = null,
    /// The least free of the filesystems `min_disk` watches; null when not
    /// read.
    disk: ?Disk = null,
};

/// A filesystem's free space: the bytes an unprivileged writer may still
/// use, and a path on it.
pub const Disk = struct {
    free: u64,
    path: []const u8,
};

pub const Gate = union(enum) {
    open,
    pressure,
    /// Available memory under `min_available`: the bytes available.
    low_memory: u64,
    /// A watched filesystem with less than `min_disk` free.
    low_disk: Disk,
};

/// Whether the machine's memory and disk let a CPU be handed out now.
pub fn gate(cfg: Config, m: Machine) Gate {
    if (cfg.pressure_check and m.pressure == .high) return .pressure;
    if (cfg.min_available > 0) if (m.available) |av| if (av < cfg.min_available) return .{ .low_memory = av };
    if (cfg.min_disk > 0) if (m.disk) |d| if (d.free < cfg.min_disk) return .{ .low_disk = d };
    return .open;
}

const testing = std.testing;

test "cpu lists" {
    try testing.expectEqual(8, cpuListCount("0-7\n").?);
    try testing.expectEqual(1, cpuListCount("0\n").?);
    try testing.expectEqual(7, cpuListCount("0,2-5,8,10\n").?);
    try testing.expectEqual(null, cpuListCount(""));
    try testing.expectEqual(null, cpuListCount("7-3"));
    try testing.expectEqual(null, cpuListCount("x"));
}

test "CPU lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 8, 10, 11 }, try cpuList(a, "0-3,8,10-11\n"));
    try testing.expectEqualStrings("0-3,8,10-11", cpuListText(a, &.{ 0, 1, 2, 3, 8, 10, 11 }));
    try testing.expectEqualStrings("5", cpuListText(a, &.{5}));
    try testing.expectError(error.InvalidCpuList, cpuList(a, "7-3"));
}

test "memory pressure gate" {
    try testing.expectEqual(Pressure.normal, macPressure(1));
    try testing.expectEqual(Pressure.normal, macPressure(2));
    try testing.expectEqual(Pressure.high, macPressure(4));
    const psi_low = "some avg10=0.00 avg60=0.10 avg300=0.05 total=123\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=9\n";
    const psi_high = "some avg10=37.50 avg60=12.00 avg300=3.00 total=99999\nfull avg10=20.00 avg60=5.00 avg300=1.00 total=500\n";
    try testing.expectEqual(Pressure.normal, psiPressure(psi_low, 10));
    try testing.expectEqual(Pressure.high, psiPressure(psi_high, 10));
    try testing.expectEqual(Pressure.unknown, psiPressure("", 10));

    const cfg: Config = .{};
    const calm: Machine = .{ .active = 10, .load1 = 3, .pressure = .normal };
    try testing.expectEqual(Gate.open, gate(cfg, calm));
    const squeezed: Machine = .{ .active = 10, .load1 = 3, .pressure = .high };
    try testing.expectEqual(Gate.pressure, gate(cfg, squeezed));
    try testing.expectEqual(Gate.open, gate(.{ .pressure_check = false }, squeezed));
    try testing.expectEqual(Gate.open, gate(cfg, .{ .active = 10, .load1 = 3, .pressure = .unknown }));
}

test "remotes and their start commands" {
    var cfg: Config = .{};
    var diag: Diagnostic = .{};
    try parseConfig(
        \\remote_start.burst = ~/runbooks/host-gcp-burst/start  # a cloud machine
        \\remotes = pup, burst
        \\remote_env.pup = PATH=$HOME/.local/go/bin:$PATH
        \\
    , &cfg, &diag);
    var it = cfg.remoteHosts();
    try testing.expectEqualStrings("pup", it.next().?);
    try testing.expectEqualStrings("burst", it.next().?);
    try testing.expectEqual(@as(?[]const u8, null), it.next());
    try testing.expectEqualStrings("~/runbooks/host-gcp-burst/start", cfg.remoteStart("burst").?);
    try testing.expect(cfg.isRemote("pup") and !cfg.isRemote("cheese"));
    try testing.expectEqualStrings("PATH=$HOME/.local/go/bin:$PATH", cfg.remoteEnv("pup").?);
    try testing.expectEqual(@as(?[]const u8, null), cfg.remoteEnv("burst"));
    try testing.expectEqual(@as(?[]const u8, null), cfg.remoteStart("pup"));
    const refused = [_][]const u8{
        "remotes = pup\nremote_env.pup = nothing\n",
        "remotes = pup\nremote_start. = x\n",
        "remotes = pup\nremote_start.pup = a\nremote_start.pup = b\n",
        "remotes = pup\nremote_start.burst = start\n",
        "remote = pup\n",
    };
    for (refused) |text| {
        var c: Config = .{};
        try testing.expectError(error.ConfigInvalid, parseConfig(text, &c, &diag));
    }
    var c: Config = .{};
    try testing.expectError(error.ConfigInvalid, parseConfig("remotes = pup\n\nremote_env.burst = A=1\n", &c, &diag));
    try testing.expectEqual(3, diag.line);
}

test "disk gate" {
    const cfg: Config = .{}; // min_disk 5G
    const roomy: Machine = .{ .active = 10, .load1 = 3, .pressure = .normal, .disk = .{ .free = 80 << 30, .path = "/home/u" } };
    try testing.expectEqual(Gate.open, gate(cfg, roomy));
    const full: Disk = .{ .free = 1 << 30, .path = "/tmp" };
    const tight: Machine = .{ .active = 10, .load1 = 3, .pressure = .normal, .disk = full };
    try testing.expectEqual(Gate{ .low_disk = full }, gate(cfg, tight));
    try testing.expectEqual(Gate.open, gate(.{ .min_disk = 0 }, tight));
    // Unread (null): never closes the gate.
    try testing.expectEqual(Gate.open, gate(cfg, .{ .active = 10, .load1 = 3, .pressure = .normal }));
}

test "config file" {
    var cfg: Config = .{};
    var diag: Diagnostic = .{};
    try parseConfig("# cpuq\nbudget = 6\ntimeout = 30m # tasks\nsubmit_roots = ~/a#b\n", &cfg, &diag);
    try testing.expectEqual(6, cfg.budget.?);
    try testing.expectEqual(1800, cfg.timeout_s);
    try testing.expectEqualStrings("~/a#b", cfg.submit_roots);

    var cfg3: Config = .{};
    try testing.expectError(error.ConfigInvalid, parseConfig("budget = 6\nbudgte = 3\n", &cfg3, &diag));
    try testing.expectEqual(2, diag.line);
    const refused = [_][]const u8{
        "budget = 0\n",             "budget = +5\n",        "budget = 1_000\n",   "budget = 5000\n",
        "budget = 4\nbudget = 5\n", "pressure_psi = 101\n", "submit_slots = 9\n",
    };
    for (refused) |text| {
        var c: Config = .{};
        try testing.expectError(error.ConfigInvalid, parseConfig(text, &c, &diag));
    }
    try testing.expectError(error.ConfigInvalid, parseConfig("budget = 4\n# two\nbudget = 5\n", &cfg3, &diag));
    try testing.expectEqualStrings("set twice", diag.message);
    try testing.expectEqual(3, diag.line);
}

test "a removed key says what replaces it" {
    var diag: Diagnostic = .{};
    var c: Config = .{};
    try testing.expectError(error.ConfigInvalid, parseConfig("budget = 4\nmax_memory = 16G\n", &c, &diag));
    try testing.expectEqual(2, diag.line);
    try testing.expectEqualStrings("max_memory is gone: limit a task with cpuq cap --mem", diag.message);
    for (removed_keys) |r| {
        var c2: Config = .{};
        try testing.expectError(error.ConfigInvalid, parseConfig(r[0], &c2, &diag));
        const line = std.fmt.allocPrint(testing.allocator, "{s} = on", .{r[0]}) catch unreachable;
        defer testing.allocator.free(line);
        try testing.expectError(error.ConfigInvalid, parseConfig(line, &c2, &diag));
        try testing.expectEqualStrings(r[1], diag.message);
        try testing.expect(std.mem.startsWith(u8, r[1], r[0]));
    }
}

/// A project's weight in the pool (`weights`), 1 unless the config names it.
pub fn weightFor(cfg: Config, project: []const u8) u32 {
    var it = std.mem.tokenizeAny(u8, cfg.weights, ", \t");
    while (it.next()) |item| {
        const name, const w = std.mem.cutScalar(u8, item, ':') orelse continue;
        if (std.mem.eql(u8, name, project)) return @max(1, parseWhole(u32, w) orelse 1);
    }
    return 1;
}

test "weightFor" {
    const cfg: Config = .{ .weights = "rig:2, trig:3 x:0" };
    try std.testing.expectEqual(2, weightFor(cfg, "rig"));
    try std.testing.expectEqual(3, weightFor(cfg, "trig"));
    try std.testing.expectEqual(1, weightFor(cfg, "x"));
    try std.testing.expectEqual(1, weightFor(cfg, "emdb"));
}
