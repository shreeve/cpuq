//! Pure decisions: the configuration file, the effective budget, the
//! admission gates, the admission rule and the MAKEFLAGS rewrite. Every input
//! is a value, so the unit tests inject them.
const std = @import("std");
const builtin = @import("builtin");

pub const Priority = enum(u2) {
    high = 0,
    normal = 1,
    low = 2,

    pub fn parse(s: []const u8) ?Priority {
        return std.meta.stringToEnum(Priority, s);
    }
};

/// The scheduling class a command runs in. On macOS `utility` and
/// `background` are QoS classes; on Linux they are nice 5 and 15.
/// How a job is started: as it is; at utility or background QoS (macOS) or
/// nice 5 or 15 (Linux); or at nice 10 with its QoS left alone (`niced`).
pub const Qos = enum { unchanged, utility, background, niced };

pub fn qosFor(priority: Priority, exclusive: bool, qos_enabled: bool) Qos {
    if (exclusive or !qos_enabled) return .unchanged;
    return switch (priority) {
        .high => .unchanged,
        // On Apple silicon utility QoS keeps work mostly on the efficiency
        // cores: four normal jobs took about 3 of the 6 efficiency cores and
        // left the performance cores idle, and ran about 20% slower than at
        // the default class. So normal leaves the class alone on macOS; on
        // Linux, where every core is alike, nice 5 only lets high win.
        .normal => if (builtin.os.tag.isDarwin()) .unchanged else .utility,
        // Background QoS confines a job to the efficiency cores even when the
        // performance cores sit idle: a CPU-bound loop took 3.8-4.1 s at
        // background and 1.6-2.0 s at nice 10 on a loaded M5. So low is nice
        // 10 on macOS, which yields to other work without being confined.
        .low => if (builtin.os.tag.isDarwin()) .niced else .background,
    };
}

/// Whether a job started on lent cores runs at background priority, so a
/// lender that gets busy again has its CPUs back at once. Not on macOS: there
/// background QoS confines a job to the efficiency cores, with throttled I/O,
/// for its whole run. On this Mac 29% of jobs started on lent cores, all held
/// to 6 efficiency cores while the 4 performance cores sat idle. On Linux,
/// where cores are alike, nice 15 only yields.
pub fn borrowersYield() bool {
    return !builtin.os.tag.isDarwin();
}

/// How the head of the queue decides it may start: `measured` counts each
/// running job at what it uses (its expected use while it settles), and
/// starts the next while that leaves room on the CPUs; `cores` counts each
/// at the cores it holds, against the budget (cpuq before 0.8).
pub const Admit = enum { measured, cores };

pub const Config = struct {
    /// How jobs are admitted (`admit`).
    admit: Admit = .measured,
    /// Measured admission: the CPUs' worth of use to fill (`target`); null
    /// means the active CPUs.
    target: ?f64 = null,
    /// Measured admission: seconds a job counts at its expected use before
    /// its measured use takes over (`settle`).
    settle_s: u32 = 20,
    /// Cores cpuq may hand out; null means the active core count minus 2.
    /// Under measured admission, only exclusive runs and `admit = cores` use it.
    budget: ?u32 = null,
    /// Admit nothing while the 1-minute load exceeds budget + load_margin.
    load_check: bool = true,
    load_margin: f64 = 4,
    /// Admit nothing while the OS reports memory pressure.
    pressure_check: bool = true,
    /// Linux: the `some avg10` percentage of /proc/pressure/memory that
    /// counts as pressure.
    pressure_psi: f64 = 10,
    /// Cap the budget by the cores active now.
    active_cap: bool = true,
    /// Map priorities to QoS classes (macOS) or nice values (Linux).
    qos: bool = true,
    /// How often the head of the queue re-reads the gates and the tokens.
    poll_ms: u32 = 500,
    /// A waiter moves up one priority class per this many seconds of
    /// waiting; 0 turns aging off.
    aging_s: u32 = 600,
    /// Seconds between the "waiting" lines a queued run prints to stderr.
    note_s: u32 = 60,
    /// Let a waiter behind the head start on cores the head cannot use yet
    /// (`backfill`).
    backfill: bool = true,
    /// Behind a timing window waiting at the front (an --exclusive run or lease), let a job known
    /// to end before the machine drains start meanwhile (`window_backfill`). Off on a timing
    /// machine: nothing starts ahead of a waiting window, so it waits only for what already runs.
    window_backfill: bool = true,
    /// Grant `--exclusive` (`exclusive`): a run or lease that asks for it
    /// waits for the machine to drain and holds it alone. Off, it runs as an
    /// ordinary job alongside the others, and says so: for a machine shared
    /// by many jobs, where draining it for one costs everyone, and timing runs
    /// belong on another.
    exclusive: bool = true,
    /// The least time, in seconds, the head lets others go ahead when there
    /// is no run time to judge by (`patience`).
    patience_s: u32 = 30,
    /// Stop a job whose processes together use more memory than this, in
    /// bytes (`max_memory`, e.g. 16G); 0 leaves memory unwatched.
    max_memory: u64 = 0,
    /// Admit nothing while the memory the kernel says is available falls
    /// under this, in bytes (`min_available`, e.g. 6G); 0 leaves it unchecked.
    min_available: u64 = 0,
    /// Admit nothing while the filesystem holding $HOME or cpuq's state
    /// directory (the temp directory) has less than this free, in bytes
    /// (`min_disk`, e.g. 5G); 0 leaves it unchecked. A full disk fails every
    /// job and every tool that writes a file; on 2026-10-11 one session's
    /// scratch files filled this Mac's disk to its last byte.
    min_disk: u64 = 5 << 30,
    /// Lend the cores a holder has left idle for a minute to the head of the
    /// queue (`lend`).
    lend: bool = true,
    /// How long, in seconds, a core must stay idle before it is lent
    /// (`lend_after`).
    lend_after_s: u32 = 60,
    /// Cap a range request near what its label has used (`right_size`).
    right_size: bool = true,
    /// Seconds after a timing window (an exclusive run) ends during which
    /// the next waits behind other work (`window_gap`); 0 lets windows run
    /// back to back. Without it, windows one after another can hold a shared
    /// machine most of the day.
    window_gap_s: u32 = 0,
    /// A timing window held with no command (`lease --hold --exclusive`, as
    /// a remote window is held) whose owner has done nothing for this long
    /// lends the machine to waiting jobs, freezing them the moment the owner
    /// works again (`window_lend`); 0 never lends.
    window_lend_s: u32 = 0,
    /// Linux: run each job in a cgroup of its own weighted by its grant, so
    /// on a crowded machine CPU time divides by grant, however many threads
    /// a job starts; on a quiet one it limits nothing (`cpu_weights`).
    cpu_weights: bool = false,
    /// Linux: run each job in a delegated cgroup of its own (a systemd user
    /// scope), its command in the scope's `job/`, so `cpuq cap` can give each
    /// program a test runner starts a cgroup beside it, with limits the
    /// kernel enforces (`cgroups`).
    cgroups: bool = true,
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
const Kind = enum { on_off, whole, number, seconds_ms, bytes, age, text, admit };

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
            .number, .seconds_ms => std.fmt.comptimePrint("{s} must be a number{s}, {d} to {d}", .{ k.name, of, k.min, k.max }),
            .bytes => k.name ++ " must be off or a size such as 5G or 512M",
            .age => k.name ++ " must be off or a time such as 3d, 36h or 90m",
            .text => unreachable,
            .admit => k.name ++ " must be measured or cores",
        };
    }
};

const day = 86400;
const keys = [_]Key{
    .{ .name = "admit", .field = "admit", .kind = .admit },
    .{ .name = "target", .field = "target", .kind = .number, .min = 1, .max = 4096, .unit = "CPUs" },
    .{ .name = "settle", .field = "settle_s", .kind = .whole, .min = 1, .max = 3600, .unit = "seconds" },
    .{ .name = "budget", .field = "budget", .kind = .whole, .min = 1, .max = 4096, .unit = "cores" },
    .{ .name = "load_check", .field = "load_check", .kind = .on_off },
    .{ .name = "load_margin", .field = "load_margin", .kind = .number, .min = 0, .max = 4096 },
    .{ .name = "pressure_check", .field = "pressure_check", .kind = .on_off },
    .{ .name = "pressure_psi", .field = "pressure_psi", .kind = .number, .min = 0, .max = 100 },
    .{ .name = "active_cap", .field = "active_cap", .kind = .on_off },
    .{ .name = "qos", .field = "qos", .kind = .on_off },
    .{ .name = "poll", .field = "poll_ms", .kind = .seconds_ms, .min = 0.1, .max = 3600, .unit = "seconds" },
    .{ .name = "aging", .field = "aging_s", .kind = .whole, .min = 0, .max = 7 * day, .unit = "seconds" },
    .{ .name = "note", .field = "note_s", .kind = .whole, .min = 1, .max = day, .unit = "seconds" },
    .{ .name = "backfill", .field = "backfill", .kind = .on_off },
    .{ .name = "window_backfill", .field = "window_backfill", .kind = .on_off },
    .{ .name = "exclusive", .field = "exclusive", .kind = .on_off },
    .{ .name = "patience", .field = "patience_s", .kind = .whole, .min = 0, .max = day, .unit = "seconds" },
    .{ .name = "max_memory", .field = "max_memory", .kind = .bytes },
    .{ .name = "min_available", .field = "min_available", .kind = .bytes },
    .{ .name = "min_disk", .field = "min_disk", .kind = .bytes },
    .{ .name = "lend", .field = "lend", .kind = .on_off },
    .{ .name = "lend_after", .field = "lend_after_s", .kind = .whole, .min = 1, .max = day, .unit = "seconds" },
    .{ .name = "right_size", .field = "right_size", .kind = .on_off },
    .{ .name = "window_gap", .field = "window_gap_s", .kind = .whole, .min = 0, .max = day, .unit = "seconds" },
    .{ .name = "window_lend", .field = "window_lend_s", .kind = .whole, .min = 0, .max = day, .unit = "seconds" },
    .{ .name = "cpu_weights", .field = "cpu_weights", .kind = .on_off },
    .{ .name = "cgroups", .field = "cgroups", .kind = .on_off },
    .{ .name = "submit_roots", .field = "submit_roots", .kind = .text },
    .{ .name = "clean_after", .field = "clean_after_s", .kind = .age },
    .{ .name = "remotes", .field = "remotes", .kind = .text },
    .{ .name = "submit_slots", .field = "submit_slots", .kind = .whole, .min = 1, .max = 8 },
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
                .number, .seconds_ms => {
                    const x = parseDecimal(value) orelse return bad(diag, comptime k.message());
                    if (x < k.min or x > k.max) return bad(diag, comptime k.message());
                    field.* = if (k.kind == .seconds_ms) @round(x * 1000) else x;
                },
                .bytes => field.* = parseBytes(value) orelse return bad(diag, comptime k.message()),
                .age => field.* = parseAge(value) orelse return bad(diag, comptime k.message()),
                .text => field.* = value,
                .admit => field.* = std.meta.stringToEnum(Admit, value) orelse return bad(diag, comptime k.message()),
            }
            continue :next;
        };
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

test "sizes for max_memory" {
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

/// The budget in force now: CPUQ_BUDGET, else the configured budget, else
/// the active cores minus a reserve of 2; capped by the active cores unless
/// `active_cap` is off, which lets a budget oversubscribe the machine.
pub fn effectiveBudget(env_budget: ?u32, cfg: Config, active: u32) u32 {
    const live = @max(active, 1);
    var b = env_budget orelse cfg.budget orelse (if (live > 2) live - 2 else 1);
    if (cfg.active_cap and b > live) b = live;
    return @max(b, 1);
}

/// The class a waiter is served in: its own, promoted one class per `aging_s`
/// seconds of waiting, so a low-priority waiter is never starved.
pub fn effectiveClass(base: Priority, waited_s: i64, aging_s: u32) u2 {
    const b: u2 = @backingInt(base);
    if (aging_s == 0 or waited_s <= 0) return b;
    const steps = @divTrunc(waited_s, aging_s);
    return if (steps >= b) 0 else b - @as(u2, @intCast(steps));
}

/// The load safety valve, shared by every cpuq through the state directory.
/// It trips when the 1-minute load exceeds budget + margin. Once tripped it
/// reopens after the load has stayed at or under budget + margin/2 (10 for
/// a budget of 8 and the default margin) for `calm_s`: the load average lags,
/// so waiting for it to fall all the way to the budget kept free cores idle
/// for minutes. While the load is above the budget (tripped or not) it admits
/// at most one job per `spacing_s`, so waiters never stampede into a load
/// average that lags. A tripped valve nobody has checked for `stale_s`
/// reopens at once when the load is at or under that level: the 1-minute
/// load average already covers that calm.
pub const Valve = struct {
    tripped: bool = false,
    calm_since: i64 = 0,
    last_admit: i64 = 0,
    last_check: i64 = 0,

    pub const calm_s = 15;
    pub const spacing_s = 10;
    pub const stale_s = 60;

    pub const Verdict = enum { open, tripped, spacing };

    /// `busy` is the measured share of all CPUs busy: the load average
    /// counts threads and lags a minute, so a high load with the CPUs
    /// measurably below 90% busy does not trip the valve, and a tripped
    /// valve reopens as soon as they fall below 75%.
    pub fn check(v: *Valve, now: i64, load: f64, budget: u32, margin: f64, busy: ?f64) Verdict {
        const unchecked_s = now - v.last_check;
        v.last_check = now;
        const b: f64 = @floatFromInt(budget);
        const full = if (busy) |f| f >= 0.9 else true;
        if (v.tripped and busy != null and busy.? < 0.75) {
            v.tripped = false;
            v.calm_since = 0;
        }
        if (load > b + margin and full) {
            v.tripped = true;
            v.calm_since = 0;
            return .tripped;
        }
        if (v.tripped) {
            if (load > b + margin / 2) {
                v.calm_since = 0;
                return .tripped;
            }
            if (v.calm_since == 0) v.calm_since = now;
            if (now - v.calm_since < calm_s and unchecked_s <= stale_s) return .tripped;
            v.tripped = false;
            v.calm_since = 0;
        }
        if (load > b and now - v.last_admit < spacing_s) return .spacing;
        return .open;
    }

    pub fn parse(text: []const u8) Valve {
        var v: Valve = .{};
        var it = std.mem.tokenizeAny(u8, text, " \n");
        const t = it.next() orelse return v;
        v.tripped = std.mem.eql(u8, t, "1");
        v.calm_since = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
        v.last_admit = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
        v.last_check = std.fmt.parseInt(i64, it.next() orelse "0", 10) catch 0;
        return v;
    }
};

/// Memory pressure as the OS reports it; `unknown` when it reports nothing,
/// `off` when `pressure_check` is off.
pub const Pressure = enum { normal, high, unknown, off };

/// macOS kern.memorystatus_vm_pressure_level: 1 normal, 2 warn, 4 critical.
pub fn macPressure(level: c_int) Pressure {
    // Critical only. The warn level (2) can last many minutes with half the
    // memory free: on 2026-10-07 it shut the gate for 8 minutes with 46-49%
    // free and under 1 GB of swap, holding up to 4 jobs while the CPUs sat
    // idle. Runaway jobs are max_memory's to stop.
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

/// What the machine looks like at the moment of an admission decision.
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
    load: f64,
    spacing: f64,
};

/// Whether anything may be admitted now; `valve` is null when the load
/// check is off.
pub fn gate(cfg: Config, m: Machine, budget: u32, valve: ?*Valve, now: i64) Gate {
    if (cfg.pressure_check and m.pressure == .high) return .pressure;
    if (cfg.min_available > 0) if (m.available) |av| if (av < cfg.min_available) return .{ .low_memory = av };
    if (cfg.min_disk > 0) if (m.disk) |d| if (d.free < cfg.min_disk) return .{ .low_disk = d };
    if (valve) |v| if (cfg.load_check) switch (v.check(now, m.load1, budget, cfg.load_margin, m.busy)) {
        .open => {},
        .tripped => return .{ .load = m.load1 },
        .spacing => return .{ .spacing = m.load1 },
    };
    return .open;
}

/// A request for cores: at least `min`, and up to `max` when they are free.
/// `--cores 3` is 3-3; `--cores 2-4` is 2-4.
pub const Request = struct {
    min: u32,
    max: u32,

    pub fn parse(s: []const u8) ?Request {
        if (std.mem.cutScalar(u8, s, '-')) |range| {
            const lo = parseCount(range[0]) orelse return null;
            const hi = parseCount(range[1]) orelse return null;
            return if (hi >= lo) .{ .min = lo, .max = hi } else null;
        }
        const n = parseCount(s) orelse return null;
        return .{ .min = n, .max = n };
    }

    pub fn fixed(r: Request) bool {
        return r.min == r.max;
    }
};

/// The admission rule for the head of the queue: how many cores it takes
/// now, or null to keep waiting. A request is clamped to the budget. It is
/// admitted once its minimum fits beside the `held` cores, and takes as
/// much more as is free, up to its maximum, but leaves `reserve` (the next
/// waiter's minimum) free when it can do so and still get its own minimum.
/// An exclusive run takes the whole budget once nothing is held, and
/// nothing is admitted while an exclusive lease is alive.
pub fn admit(req: Request, exclusive: bool, budget: u32, held: u32, exclusive_running: bool, reserve: u32) ?u32 {
    if (exclusive_running) return null;
    if (exclusive) return if (held == 0) budget else null;
    const lo = @min(@max(req.min, 1), budget);
    const hi = @min(@max(req.max, lo), budget);
    if (held >= budget) return null;
    const free = budget - held;
    if (free < lo) return null;
    const room = if (free - lo >= reserve) free - reserve else free;
    return @min(hi, room);
}

/// Backfill: whether a waiter behind the head may start now, taking what is
/// free up to its maximum, on cores the head cannot use yet. `run` is the
/// waiter's typical run time and `head_eta` the seconds until the head is
/// expected to start, each null when history cannot say. With both known,
/// the waiter goes ahead only if it should be done by then, so the head
/// loses nothing. Without them, it goes ahead only while the head has
/// waited less than its `patience`; after that, cores that free up are kept
/// for the head.
pub fn backfill(run: ?f64, head_eta: ?f64, head_waited: f64, head_typical: ?f64, least: u32) bool {
    if (run) |r| if (head_eta) |eta| return r <= eta;
    return head_waited < patience(head_typical, least);
}

/// How long the head lets others go ahead without a run time to judge by:
/// half its own typical run, from `least` seconds (30 by default) to 5
/// minutes.
pub fn patience(head_typical: ?f64, least: u32) f64 {
    const lo: f64 = @floatFromInt(least);
    return std.math.clamp((head_typical orelse 0) / 2, lo, @max(lo, 300));
}

test "backfill goes ahead only when it should not delay the head" {
    // Known run times: ahead if done before the head could start.
    try std.testing.expect(backfill(60, 120, 0, null, 30));
    try std.testing.expect(!backfill(300, 120, 0, null, 30));
    // Unknown: ahead while the head's patience lasts.
    try std.testing.expect(backfill(null, 120, 10, null, 30));
    try std.testing.expect(backfill(60, null, 29, null, 30));
    try std.testing.expect(!backfill(null, null, 30, null, 30));
    // Patience is half the head's typical run, from 30 s to 5 min.
    try std.testing.expectEqual(@as(f64, 30), patience(null, 30));
    try std.testing.expectEqual(@as(f64, 30), patience(20, 30));
    try std.testing.expectEqual(@as(f64, 100), patience(200, 30));
    try std.testing.expectEqual(@as(f64, 300), patience(3600, 30));
    try std.testing.expect(backfill(null, null, 99, 200, 30));
    try std.testing.expect(!backfill(null, null, 100, 200, 30));
    // A configured least patience.
    try std.testing.expectEqual(@as(f64, 2), patience(null, 2));
    try std.testing.expectEqual(@as(f64, 600), patience(null, 600));
}

/// Lending: what a holder's command actually uses, measured by the head of
/// the queue while it waits, and shared through the state directory.
pub const Use = struct {
    /// Cores active, averaged over about half of `after_s` (it starts at
    /// the grant, so a job is taken as busy until shown otherwise).
    avg: f64 = 0,
    /// Since when at least one whole core has been idle; 0 when not.
    idle_since: i64 = 0,
    /// When last measured (ms), and the command tree's CPU then (ns).
    at_ms: i64 = 0,
    cpu_ns: u64 = 0,
    /// Threads ready to run, averaged like `avg`: what the job asks of the
    /// CPUs, which on a contended machine is more than it gets.
    runnable: f64 = 0,

    /// Takes in the runnable threads seen now, averaged over the same time as
    /// `observe` (call it after `observe`, with that `dt`).
    pub fn observeRunnable(u: *Use, n: u32, dt_s: f64, after_s: u32) void {
        const tau_s = @max(@as(f64, @floatFromInt(after_s)) / 2, 0.5);
        const r: f64 = @floatFromInt(n);
        if (dt_s <= 0) {
            u.runnable = r;
            return;
        }
        u.runnable += std.math.clamp(dt_s / tau_s, 0, 1) * (r - u.runnable);
    }

    /// Takes in a measurement: `cpu_ns` of CPU time at `now_ms`, averaging
    /// over half of `after_s`, the time a core must stay idle to be lent.
    pub fn observe(u: *Use, cpu_ns: u64, now_ms: i64, held: u32, after_s: u32) void {
        const tau_s = @max(@as(f64, @floatFromInt(after_s)) / 2, 0.5);
        const h: f64 = @floatFromInt(held);
        if (u.at_ms == 0 or now_ms <= u.at_ms or cpu_ns < u.cpu_ns) {
            u.* = .{ .avg = h, .at_ms = now_ms, .cpu_ns = cpu_ns };
            return;
        }
        const dt = @as(f64, @floatFromInt(now_ms - u.at_ms)) / 1000;
        const rate = @as(f64, @floatFromInt(cpu_ns - u.cpu_ns)) / 1e9 / dt;
        u.avg += std.math.clamp(dt / tau_s, 0, 1) * (rate - u.avg);
        u.at_ms = now_ms;
        u.cpu_ns = cpu_ns;
        if (h - u.avg >= 1) {
            if (u.idle_since == 0) u.idle_since = @divFloor(now_ms, 1000);
        } else u.idle_since = 0;
    }

    /// The whole cores it lends: those idle for `after_s`, less a quarter
    /// of a core of slack.
    pub fn lendable(u: Use, held: u32, now: i64, after_s: u32) u32 {
        if (u.idle_since == 0 or now - u.idle_since < after_s) return 0;
        const idle = @as(f64, @floatFromInt(held)) - u.avg - 0.25;
        return if (idle >= 1) @intFromFloat(@floor(idle)) else 0;
    }
};

test "a holder lends the cores it leaves idle for a minute" {
    var u: Use = .{};
    // Holds 3, uses 1: the average falls from 3 toward 1.
    var cpu: u64 = 0;
    var t: i64 = 1_000_000;
    u.observe(cpu, t, 3, 60);
    try std.testing.expectEqual(@as(f64, 3), u.avg);
    var lent: u32 = 0;
    var first: i64 = 0;
    while (t < 1_000_000 + 200_000) {
        t += 500;
        cpu += 500_000_000; // one core
        u.observe(cpu, t, 3, 60);
        lent = u.lendable(3, @divFloor(t, 1000), 60);
        if (lent > 0 and first == 0) first = t;
    }
    try std.testing.expectEqual(@as(u32, 1), lent); // 3 - 1 - 0.25: one whole core
    // Not before the idle core has been idle a minute.
    try std.testing.expect(first - 1_000_000 >= 60 * 1000);
    // Busy again: nothing lent.
    for (0..200) |_| {
        t += 500;
        cpu += 1_500_000_000; // three cores
        u.observe(cpu, t, 3, 60);
    }
    try std.testing.expectEqual(@as(u32, 0), u.lendable(3, @divFloor(t, 1000), 60));
}

/// How many cores may be lent: lending uses idle reservations, but only
/// while the machine has CPUs to spare, so it never pushes the load past
/// the CPU count.
pub fn lendRoom(load1: f64, cpus: u32) u32 {
    const spare = @as(f64, @floatFromInt(cpus)) - load1;
    return if (spare >= 1) @intFromFloat(@floor(spare)) else 0;
}

/// Right-sizing: a range request capped near what jobs with its label have
/// used. `uses` are the label's past runs' average active cores; with fewer
/// than 3 the request stands. The cap is the 75th percentile plus 0.3,
/// rounded, kept within the request: a job that uses 0.8 asking 1-4 gets
/// 1-1, one that uses 3.5 keeps 1-4. A fixed count is never changed.
/// The 75th percentile of a label's last 64 runs' average active cores;
/// null with fewer than three runs to judge by.
pub fn typicalUse(uses: []const f64) ?f64 {
    if (uses.len < 3) return null;
    var sorted: [64]f64 = undefined;
    const n: usize = @min(uses.len, sorted.len);
    @memcpy(sorted[0..n], uses[uses.len - n ..]);
    std.mem.sort(f64, sorted[0..n], {}, std.sort.asc(f64));
    return sorted[(n - 1) * 3 / 4];
}

/// What a running job counts for under measured admission: its expected use
/// (from history, else all it holds) until it has run `settle_s`, then what it
/// is measured using, however little; never less than a twentieth of a core.
pub fn charge(expected: ?f64, measured: ?f64, age_s: i64, settle_s: u32, held: u32) f64 {
    const h: f64 = @floatFromInt(held);
    if (measured) |m| if (age_s >= settle_s) return @max(m, 0.05);
    return @max(@min(expected orelse h, h), 0.05);
}

/// What settled `--opaque` jobs count for under measured admission. Their work runs where cpuq
/// cannot see it (a container, a VM), but on this machine it still shows in the CPUs' own busy
/// time: so together they count for the busy CPUs nothing else measured explains (`unexplained`,
/// outside work included, which errs toward counting them more), shared by their grants. Each
/// counts at least what its own command tree is seen to use and at most its grant. A job whose
/// work runs on another machine (ssh) holds cores it never uses here, and counts for little.
pub fn hiddenCharge(grants: []const u32, seen: []const f64, unexplained: f64) f64 {
    var total: f64 = 0;
    for (grants) |g| total += @floatFromInt(g);
    if (total == 0) return 0;
    var charged: f64 = 0;
    for (grants, seen) |g, v| {
        const grant: f64 = @floatFromInt(g);
        const share = @max(unexplained, 0) * grant / total;
        charged += std.math.clamp(@max(share, v), 0.05, grant);
    }
    return charged;
}

test "settled opaque jobs count for the busy CPUs nothing else explains" {
    // Six 4-core opaque jobs on a machine busy 1 CPU beyond what was measured: ~1, not 24.
    const g6 = [_]u32{ 4, 4, 4, 4, 4, 4 };
    const quiet = [_]f64{ 0, 0.04, 0, 0.02, 0.97, 0.02 };
    const unseen = [_]f64{ 0, 0, 0, 0, 0, 0 };
    try std.testing.expect(hiddenCharge(&g6, &quiet, 1.0) < 2.0);
    // Their containers busy (14 CPUs unexplained): they count for those 14.
    try std.testing.expectApproxEqAbs(@as(f64, 14), hiddenCharge(&g6, &unseen, 14), 1e-9);
    // Never past their grants, however busy the machine.
    try std.testing.expectEqual(@as(f64, 24), hiddenCharge(&g6, &unseen, 40));
    // What a job's own tree is seen to use stands, if more than its share.
    try std.testing.expectApproxEqAbs(@as(f64, 3.05), hiddenCharge(&[_]u32{ 4, 4 }, &[_]f64{ 3, 0 }, 0), 1e-9);
}

/// The cores to hand a job under measured admission, as a range for the
/// tokens: a fixed count asked for stands; a range is capped near the label's
/// use (as `rightSize`); with no count asked for, the label's use decides
/// (its 75th percentile plus 0.3, rounded, at most half the CPUs), else 2.
/// Short of room, the range gives way down to its minimum.
pub fn measuredGrant(req: Request, asked: bool, uses: []const f64, room: f64, cpus: u32) Request {
    var r = req;
    if (!asked) {
        r = if (typicalUse(uses)) |u| blk: {
            const k: u32 = @intFromFloat(@max(@round(u + 0.3), 1));
            break :blk .{ .min = 1, .max = std.math.clamp(k, 1, @max(cpus / 2, 1)) };
        } else .{ .min = 2, .max = 2 };
    } else if (!r.fixed()) r = rightSize(r, uses);
    if (r.fixed()) return r;
    const fit: u32 = @intFromFloat(@max(@floor(room), 0));
    return .{ .min = r.min, .max = std.math.clamp(fit, r.min, r.max) };
}

test "measured admission charges and grants" {
    // Settling: the expected use within what it holds; then the measured use.
    try std.testing.expectEqual(@as(f64, 1.5), charge(1.5, 0.2, 5, 20, 4));
    try std.testing.expectEqual(@as(f64, 4), charge(null, 0.2, 5, 20, 4));
    try std.testing.expectEqual(@as(f64, 0.2), charge(1.5, 0.2, 30, 20, 4));
    try std.testing.expectEqual(@as(f64, 0.05), charge(1.5, 0, 30, 20, 4));
    try std.testing.expectEqual(@as(f64, 2), charge(3, null, 30, 20, 2));
    // Grants: no count asked, from history; a fixed count stands; a range
    // gives way to the room, down to its minimum.
    const used = [_]f64{ 2.6, 2.8, 2.7 };
    try std.testing.expectEqual(Request{ .min = 1, .max = 3 }, measuredGrant(.{ .min = 2, .max = 2 }, false, &used, 9, 10));
    try std.testing.expectEqual(Request{ .min = 2, .max = 2 }, measuredGrant(.{ .min = 2, .max = 2 }, false, &.{}, 9, 10));
    try std.testing.expectEqual(Request{ .min = 4, .max = 4 }, measuredGrant(.{ .min = 4, .max = 4 }, true, &used, 1, 10));
    try std.testing.expectEqual(Request{ .min = 1, .max = 2 }, measuredGrant(.{ .min = 1, .max = 4 }, true, &.{}, 2.5, 10));
    try std.testing.expectEqual(Request{ .min = 2, .max = 2 }, measuredGrant(.{ .min = 2, .max = 8 }, true, &.{}, 0.5, 10));
    // At most half the CPUs from history alone.
    try std.testing.expectEqual(Request{ .min = 1, .max = 5 }, measuredGrant(.{ .min = 2, .max = 2 }, false, &.{ 9, 9, 9 }, 20, 10));
}

pub fn rightSize(req: Request, uses: []const f64) Request {
    if (req.fixed() or uses.len < 3) return req;
    var sorted: [64]f64 = undefined;
    // usize: @min with a comptime length narrows its type (u7 for 64), and
    // the percentile's index arithmetic below would overflow it.
    const n: usize = @min(uses.len, sorted.len);
    @memcpy(sorted[0..n], uses[uses.len - n ..]);
    std.mem.sort(f64, sorted[0..n], {}, std.sort.asc(f64));
    const p75 = sorted[(n - 1) * 3 / 4];
    const cap: u32 = @intFromFloat(@max(@round(p75 + 0.3), 1));
    return .{ .min = req.min, .max = std.math.clamp(cap, req.min, req.max) };
}

test "right-sizing caps a range near the label's measured use" {
    const r: Request = .{ .min = 1, .max = 4 };
    try std.testing.expectEqual(Request{ .min = 1, .max = 1 }, rightSize(r, &.{ 0.8, 0.9, 0.7 }));
    try std.testing.expectEqual(Request{ .min = 1, .max = 1 }, rightSize(r, &.{ 1.0, 0.98, 1.0 }));
    try std.testing.expectEqual(Request{ .min = 1, .max = 2 }, rightSize(r, &.{ 1.6, 1.8, 1.5 }));
    try std.testing.expectEqual(Request{ .min = 1, .max = 4 }, rightSize(r, &.{ 3.5, 3.9, 3.6 }));
    // Too few runs to judge by, a fixed count, or a minimum above the use.
    try std.testing.expectEqual(r, rightSize(r, &.{ 0.5, 0.5 }));
    try std.testing.expectEqual(Request{ .min = 3, .max = 3 }, rightSize(.{ .min = 3, .max = 3 }, &.{ 0.5, 0.5, 0.5 }));
    try std.testing.expectEqual(Request{ .min = 2, .max = 2 }, rightSize(.{ .min = 2, .max = 4 }, &.{ 0.5, 0.5, 0.5 }));
    // A long history: the last 64 runs count, and nothing overflows.
    var many: [200]f64 = undefined;
    for (&many, 0..) |*u, i| u.* = if (i < 136) 3.5 else 0.6;
    try std.testing.expectEqual(Request{ .min = 1, .max = 1 }, rightSize(r, &many));
}

test "lending only into spare CPUs" {
    try std.testing.expectEqual(@as(u32, 0), lendRoom(12.8, 10));
    try std.testing.expectEqual(@as(u32, 0), lendRoom(9.5, 10));
    try std.testing.expectEqual(@as(u32, 2), lendRoom(7.6, 10));
}

test "the valve trips only when the CPUs are measurably full" {
    const cfg: Config = .{}; // budget 8, margin 4: trips above 12
    var v: Valve = .{};
    const at = struct {
        fn m(load: f64, busy: ?f64) Machine {
            return .{ .active = 10, .load1 = load, .pressure = .normal, .busy = busy };
        }
    };
    // A high load average with CPUs to spare: open.
    try std.testing.expectEqual(Gate.open, gate(cfg, at.m(13, 0.7), 8, &v, 100));
    // High load and full CPUs: tripped.
    try std.testing.expectEqual(Gate{ .load = 13 }, gate(cfg, at.m(13, 0.95), 8, &v, 101));
    // The CPUs fall well below full: reopens at once (spacing still applies above the budget).
    v.last_admit = 0;
    try std.testing.expectEqual(Gate.open, gate(cfg, at.m(12.5, 0.6), 8, &v, 102));
    try std.testing.expect(!v.tripped);
}

/// MAKEFLAGS for a command whose jobserver pipe is (r, w): the caller's
/// flags without their -j and jobserver options, then ` -j
/// --jobserver-auth=R,W --jobserver-fds=R,W`, then any `-- VAR=value` part
/// unchanged. This is what GNU make itself hands a sub-make: make 4.2 and
/// later read --jobserver-auth, make 3.81 reads --jobserver-fds, and the bare
/// -j makes either take its job slots from the pipe.
pub fn makeflags(arena: std.mem.Allocator, existing: ?[]const u8, r: i32, w: i32) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const s = existing orelse "";
    var vars: []const u8 = "";
    var i: usize = 0;
    var first = true;
    while (i < s.len) {
        while (i < s.len and s[i] == ' ') i += 1;
        if (i >= s.len) break;
        const start = i;
        while (i < s.len and s[i] != ' ') i += 1;
        const word = s[start..i];
        if (std.mem.eql(u8, word, "--")) {
            vars = s[start..];
            break;
        }
        if (std.mem.startsWith(u8, word, "-j") or
            std.mem.startsWith(u8, word, "--jobserver-auth=") or
            std.mem.startsWith(u8, word, "--jobserver-fds=")) continue;
        if (!first) try out.append(arena, ' ');
        try out.appendSlice(arena, word);
        first = false;
    }
    try out.print(arena, " -j --jobserver-auth={d},{d} --jobserver-fds={d},{d}", .{ r, w, r, w });
    if (vars.len != 0) {
        try out.append(arena, ' ');
        try out.appendSlice(arena, vars);
    }
    return out.items;
}

const testing = std.testing;

test "effective budget: default reserve, env, config, active-core cap" {
    const cfg: Config = .{};
    try testing.expectEqual(8, effectiveBudget(null, cfg, 10));
    try testing.expectEqual(1, effectiveBudget(null, cfg, 2));
    try testing.expectEqual(1, effectiveBudget(null, cfg, 0));
    try testing.expectEqual(9, effectiveBudget(9, cfg, 10));
    try testing.expectEqual(6, effectiveBudget(9, cfg, 6)); // only 6 cores active
    try testing.expectEqual(4, effectiveBudget(null, .{ .budget = 4 }, 10));
    try testing.expectEqual(5, effectiveBudget(5, .{ .budget = 4 }, 10)); // env wins
    try testing.expectEqual(16, effectiveBudget(16, .{ .active_cap = false }, 10)); // oversubscribed on purpose
    try testing.expectEqual(10, effectiveBudget(16, cfg, 10));
}

test "cpu lists" {
    try testing.expectEqual(8, cpuListCount("0-7\n").?);
    try testing.expectEqual(1, cpuListCount("0\n").?);
    try testing.expectEqual(7, cpuListCount("0,2-5,8,10\n").?);
    try testing.expectEqual(null, cpuListCount(""));
    try testing.expectEqual(null, cpuListCount("7-3"));
    try testing.expectEqual(null, cpuListCount("x"));
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
    try testing.expectEqual(Gate.open, gate(cfg, calm, 8, null, 0));
    const squeezed: Machine = .{ .active = 10, .load1 = 3, .pressure = .high };
    try testing.expectEqual(Gate.pressure, gate(cfg, squeezed, 8, null, 0));
    try testing.expectEqual(Gate.open, gate(.{ .pressure_check = false }, squeezed, 8, null, 0));
    try testing.expectEqual(Gate.open, gate(cfg, .{ .active = 10, .load1 = 3, .pressure = .unknown }, 8, null, 0));
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
    try testing.expectEqual(Gate.open, gate(cfg, roomy, 8, null, 0));
    const full: Disk = .{ .free = 1 << 30, .path = "/tmp" };
    const tight: Machine = .{ .active = 10, .load1 = 3, .pressure = .normal, .disk = full };
    try testing.expectEqual(Gate{ .low_disk = full }, gate(cfg, tight, 8, null, 0));
    try testing.expectEqual(Gate.open, gate(.{ .min_disk = 0 }, tight, 8, null, 0));
    // Unread (null): never closes the gate.
    try testing.expectEqual(Gate.open, gate(cfg, .{ .active = 10, .load1 = 3, .pressure = .normal }, 8, null, 0));
}

test "load safety valve with hysteresis" {
    const cfg: Config = .{}; // margin 4, budget 8: trips above 12, reopens at 10
    var v: Valve = .{};
    const at = struct {
        fn m(load: f64) Machine {
            return .{ .active = 10, .load1 = load, .pressure = .normal };
        }
    };
    try testing.expectEqual(Gate.open, gate(cfg, at.m(7), 8, &v, 100));
    try testing.expectEqual(Gate{ .load = 12.5 }, gate(cfg, at.m(12.5), 8, &v, 101));
    // Back under budget + margin but over budget + margin/2: still tripped.
    try testing.expectEqual(Gate{ .load = 11 }, gate(cfg, at.m(11), 8, &v, 105));
    // At or under 10, but not yet for 15 s.
    try testing.expectEqual(Gate{ .load = 10 }, gate(cfg, at.m(10), 8, &v, 110));
    try testing.expectEqual(Gate{ .load = 9.5 }, gate(cfg, at.m(9.5), 8, &v, 120));
    // A load spike restarts the calm period.
    try testing.expectEqual(Gate{ .load = 10.5 }, gate(cfg, at.m(10.5), 8, &v, 122));
    try testing.expectEqual(Gate{ .load = 9 }, gate(cfg, at.m(9), 8, &v, 123));
    try testing.expectEqual(Gate.open, gate(cfg, at.m(9), 8, &v, 138));
    try testing.expect(!v.tripped);
    // Over the budget (not tripped): one admission per 10 s.
    v.last_admit = 138;
    try testing.expectEqual(Gate{ .spacing = 9 }, gate(cfg, at.m(9), 8, &v, 142));
    try testing.expectEqual(Gate.open, gate(cfg, at.m(9), 8, &v, 148));
    // --no-load-check (no valve) or load_check = off.
    try testing.expectEqual(Gate.open, gate(cfg, at.m(30), 8, null, 200));
    try testing.expectEqual(Gate.open, gate(.{ .load_check = false }, at.m(30), 8, &v, 200));

    const p = Valve.parse("1 150 181 191\n");
    try testing.expect(p.tripped);
    try testing.expectEqual(150, p.calm_since);
    try testing.expectEqual(181, p.last_admit);
    try testing.expectEqual(191, p.last_check);
}

test "a stale tripped valve reopens at once when the load is calm" {
    const cfg: Config = .{};
    const calm: Machine = .{ .active = 10, .load1 = 3, .pressure = .normal };
    const busy: Machine = .{ .active = 10, .load1 = 11, .pressure = .normal };
    // Tripped and unchecked for an hour: open at once if the load is calm.
    var v: Valve = .{ .tripped = true, .last_check = 1000 };
    try testing.expectEqual(Gate.open, gate(cfg, calm, 8, &v, 4600));
    try testing.expect(!v.tripped);
    try testing.expectEqual(4600, v.last_check);
    // Left by a file without a check time: the same.
    v = Valve.parse("1 0 0\n");
    try testing.expectEqual(Gate.open, gate(cfg, calm, 8, &v, 4600));
    // Stale, but the load is over budget + margin/2: still tripped.
    v = .{ .tripped = true, .last_check = 1000 };
    try testing.expectEqual(Gate{ .load = 11 }, gate(cfg, busy, 8, &v, 4600));
    // Checked a moment ago: the calm period still applies.
    v = .{ .tripped = true, .last_check = 4590 };
    try testing.expectEqual(Gate{ .load = 3 }, gate(cfg, calm, 8, &v, 4600));
}

test "requests" {
    try testing.expectEqual(Request{ .min = 3, .max = 3 }, Request.parse("3").?);
    try testing.expectEqual(Request{ .min = 2, .max = 4 }, Request.parse("2-4").?);
    try testing.expectEqual(Request{ .min = 2, .max = 2 }, Request.parse("2-2").?);
    try testing.expectEqual(null, Request.parse("4-2"));
    try testing.expectEqual(null, Request.parse("0-2"));
    try testing.expectEqual(null, Request.parse("2-"));
    try testing.expectEqual(null, Request.parse("x"));
}

test "admission rule" {
    const three: Request = .{ .min = 3, .max = 3 };
    try testing.expectEqual(3, admit(three, false, 9, 6, false, 0).?);
    try testing.expectEqual(null, admit(three, false, 9, 7, false, 0));
    try testing.expectEqual(9, admit(three, true, 9, 0, false, 0).?);
    try testing.expectEqual(null, admit(three, true, 9, 1, false, 0));
    try testing.expectEqual(null, admit(.{ .min = 1, .max = 1 }, false, 9, 0, true, 0)); // an exclusive run blocks everything
    try testing.expectEqual(null, admit(.{ .min = 2, .max = 2 }, false, 4, 3, false, 0)); // budget lowered under running work
    try testing.expectEqual(null, admit(three, false, 4, 5, false, 0)); // more held than the budget
}

test "a request is clamped to the budget" {
    // 10 cores active, budget 8: a 9-core request gets 8.
    try testing.expectEqual(8, admit(.{ .min = 9, .max = 9 }, false, effectiveBudget(null, .{}, 10), 0, false, 0).?);
    // Only 6 cores active: the same request gets 6.
    try testing.expectEqual(6, admit(.{ .min = 9, .max = 9 }, false, effectiveBudget(9, .{}, 6), 0, false, 0).?);
    try testing.expectEqual(1, admit(.{ .min = 0, .max = 0 }, false, 8, 0, false, 0).?);
}

test "elastic grants" {
    const two_four: Request = .{ .min = 2, .max = 4 };
    // Budget 8, 6 held: 2 free, so a 2-4 request starts at once with 2.
    try testing.expectEqual(2, admit(two_four, false, 8, 6, false, 0).?);
    // All free: it takes its maximum.
    try testing.expectEqual(4, admit(two_four, false, 8, 0, false, 0).?);
    // 1 free: it waits for its minimum.
    try testing.expectEqual(null, admit(two_four, false, 8, 7, false, 0));
    // A wide request leaves the next waiter's minimum free...
    try testing.expectEqual(6, admit(.{ .min = 2, .max = 8 }, false, 8, 0, false, 2).?);
    // ...unless that would cut it below its own minimum: then it takes all.
    try testing.expectEqual(3, admit(.{ .min = 2, .max = 8 }, false, 8, 5, false, 2).?);
    // A maximum above the budget is clamped to it.
    try testing.expectEqual(8, admit(.{ .min = 2, .max = 20 }, false, 8, 0, false, 0).?);
}

test "aging promotes one class per period" {
    try testing.expectEqual(2, effectiveClass(.low, 0, 600));
    try testing.expectEqual(2, effectiveClass(.low, 599, 600));
    try testing.expectEqual(1, effectiveClass(.low, 600, 600));
    try testing.expectEqual(0, effectiveClass(.low, 1200, 600));
    try testing.expectEqual(0, effectiveClass(.low, 99999, 600));
    try testing.expectEqual(0, effectiveClass(.normal, 600, 600));
    try testing.expectEqual(2, effectiveClass(.low, 99999, 0)); // aging off
}

test "qos classes" {
    try testing.expectEqual(Qos.unchanged, qosFor(.high, false, true));
    try testing.expectEqual(if (builtin.os.tag.isDarwin()) Qos.unchanged else Qos.utility, qosFor(.normal, false, true));
    try testing.expectEqual(if (builtin.os.tag.isDarwin()) Qos.niced else Qos.background, qosFor(.low, false, true));
    try testing.expectEqual(Qos.unchanged, qosFor(.low, true, true));
    try testing.expectEqual(Qos.unchanged, qosFor(.low, false, false));
}

test "makeflags keeps the caller's flags" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try testing.expectEqualStrings(" -j --jobserver-auth=5,6 --jobserver-fds=5,6", try makeflags(a, null, 5, 6));
    try testing.expectEqualStrings("k -j --jobserver-auth=5,6 --jobserver-fds=5,6", try makeflags(a, "k", 5, 6));
    try testing.expectEqualStrings(
        "ks --no-print-directory -j --jobserver-auth=5,6 --jobserver-fds=5,6 -- CC=gcc X=a\\ b",
        try makeflags(a, "ks -j8 --jobserver-auth=fifo:/old --no-print-directory --jobserver-fds=3,4 -- CC=gcc X=a\\ b", 5, 6),
    );
}

test "config file" {
    var cfg: Config = .{};
    var diag: Diagnostic = .{};
    try parseConfig("# cpuq\nbudget = 6\nload_check = off # quiet\npoll = 0.5\naging = 60\nsubmit_roots = ~/a#b\n", &cfg, &diag);
    try testing.expectEqual(6, cfg.budget.?);
    try testing.expect(!cfg.load_check);
    try testing.expectEqual(500, cfg.poll_ms);
    try testing.expectEqual(60, cfg.aging_s);
    try testing.expectEqualStrings("~/a#b", cfg.submit_roots);

    var cfg3: Config = .{};
    try testing.expectError(error.ConfigInvalid, parseConfig("budget = 6\nbudgte = 3\n", &cfg3, &diag));
    try testing.expectEqual(2, diag.line);
    const refused = [_][]const u8{
        "budget = 0\n",             "budget = +5\n",      "budget = 1_000\n",   "budget = 5000\n",
        "budget = 4\nbudget = 5\n", "poll = 0.05\n",      "poll = 1e3\n",       "target = 0\n",
        "pressure_psi = 101\n",     "submit_slots = 9\n", "load_margin = -1\n", "aging = 1.5\n",
    };
    for (refused) |text| {
        var c: Config = .{};
        try testing.expectError(error.ConfigInvalid, parseConfig(text, &c, &diag));
    }
    try testing.expectError(error.ConfigInvalid, parseConfig("budget = 4\n# two\nbudget = 5\n", &cfg3, &diag));
    try testing.expectEqualStrings("set twice", diag.message);
    try testing.expectEqual(3, diag.line);
}

test "admit leaves the reserve without overflowing" {
    const r: Request = .{ .min = 2, .max = 8 };
    try testing.expectEqual(@as(?u32, 6), admit(r, false, 10, 0, false, 4));
    try testing.expectEqual(@as(?u32, 8), admit(r, false, 10, 0, false, std.math.maxInt(u32)));
}
