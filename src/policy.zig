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
pub const Qos = enum { unchanged, utility, background };

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
        .low => .background,
    };
}

pub const Config = struct {
    /// Cores cpuq may hand out; null means the active core count minus 2.
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
    /// The least time, in seconds, the head lets others go ahead when there
    /// is no run time to judge by (`patience`).
    patience_s: u32 = 30,
    /// Stop a job whose processes together use more memory than this, in
    /// bytes (`max_memory`, e.g. 16G); 0 leaves memory unwatched.
    max_memory: u64 = 0,
    /// Lend the cores a holder has left idle for a minute to the head of the
    /// queue (`lend`).
    lend: bool = true,
    /// How long, in seconds, a core must stay idle before it is lent
    /// (`lend_after`).
    lend_after_s: u32 = 60,
    /// Cap a range request near what its label has used (`right_size`).
    right_size: bool = true,
};

pub const Diagnostic = struct {
    line: usize = 0,
    key: []const u8 = "",
    message: []const u8 = "",
};

/// Parses `key = value` lines; `#` starts a comment.
pub fn parseConfig(text: []const u8, cfg: *Config, diag: *Diagnostic) error{ConfigInvalid}!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const uncommented = if (std.mem.findScalar(u8, raw, '#')) |i| raw[0..i] else raw;
        const line = std.mem.trim(u8, uncommented, " \t\r");
        if (line.len == 0) continue;
        diag.line = n;
        diag.key = line;
        const key_raw, const value_raw = std.mem.cutScalar(u8, line, '=') orelse {
            diag.message = "expected key = value";
            return error.ConfigInvalid;
        };
        const key = std.mem.trim(u8, key_raw, " \t");
        diag.key = key;
        const value = std.mem.trim(u8, value_raw, " \t");
        if (std.mem.eql(u8, key, "budget")) {
            const b = parseCount(value) orelse return bad(diag, "budget must be a whole number of cores, at least 1");
            cfg.budget = b;
        } else if (std.mem.eql(u8, key, "load_check")) {
            cfg.load_check = parseBool(value) orelse return bad(diag, "load_check must be on or off");
        } else if (std.mem.eql(u8, key, "load_margin")) {
            cfg.load_margin = parseNonNegative(value) orelse return bad(diag, "load_margin must be a number, 0 or more");
        } else if (std.mem.eql(u8, key, "pressure_check")) {
            cfg.pressure_check = parseBool(value) orelse return bad(diag, "pressure_check must be on or off");
        } else if (std.mem.eql(u8, key, "pressure_psi")) {
            cfg.pressure_psi = parseNonNegative(value) orelse return bad(diag, "pressure_psi must be a number, 0 or more");
        } else if (std.mem.eql(u8, key, "active_cap")) {
            cfg.active_cap = parseBool(value) orelse return bad(diag, "active_cap must be on or off");
        } else if (std.mem.eql(u8, key, "qos")) {
            cfg.qos = parseBool(value) orelse return bad(diag, "qos must be on or off");
        } else if (std.mem.eql(u8, key, "poll")) {
            const s = parseNonNegative(value) orelse return bad(diag, "poll must be a number of seconds");
            if (s < 0.1 or s > 3600) return bad(diag, "poll must be between 0.1 and 3600 seconds");
            cfg.poll_ms = @round(s * 1000);
        } else if (std.mem.eql(u8, key, "aging")) {
            const a = std.fmt.parseInt(u32, value, 10) catch return bad(diag, "aging must be a whole number of seconds");
            cfg.aging_s = a;
        } else if (std.mem.eql(u8, key, "note")) {
            cfg.note_s = parseCount(value) orelse return bad(diag, "note must be a whole number of seconds, at least 1");
        } else if (std.mem.eql(u8, key, "backfill")) {
            cfg.backfill = parseBool(value) orelse return bad(diag, "backfill must be on or off");
        } else if (std.mem.eql(u8, key, "right_size")) {
            cfg.right_size = parseBool(value) orelse return bad(diag, "right_size must be on or off");
        } else if (std.mem.eql(u8, key, "lend_after")) {
            cfg.lend_after_s = parseCount(value) orelse return bad(diag, "lend_after must be a whole number of seconds, at least 1");
        } else if (std.mem.eql(u8, key, "lend")) {
            cfg.lend = parseBool(value) orelse return bad(diag, "lend must be on or off");
        } else if (std.mem.eql(u8, key, "max_memory")) {
            cfg.max_memory = parseBytes(value) orelse return bad(diag, "max_memory must be off or a size such as 16G or 512M");
        } else if (std.mem.eql(u8, key, "patience")) {
            cfg.patience_s = std.fmt.parseInt(u32, value, 10) catch return bad(diag, "patience must be a whole number of seconds");
        } else {
            return bad(diag, "unknown key");
        }
    }
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
    const n = std.fmt.parseInt(u64, digits, 10) catch return null;
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

pub fn parseCount(s: []const u8) ?u32 {
    const n = std.fmt.parseInt(u32, s, 10) catch return null;
    return if (n >= 1) n else null;
}

fn parseBool(s: []const u8) ?bool {
    if (std.mem.eql(u8, s, "on") or std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "yes")) return true;
    if (std.mem.eql(u8, s, "off") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "no")) return false;
    return null;
}

fn parseNonNegative(s: []const u8) ?f64 {
    const x = std.fmt.parseFloat(f64, s) catch return null;
    return if (x >= 0 and !std.math.isNan(x) and !std.math.isInf(x)) x else null;
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
    return if (level >= 2) .high else .normal;
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
};

pub const Gate = union(enum) {
    open,
    pressure,
    load: f64,
    spacing: f64,
};

/// Whether anything may be admitted now; `valve` is null when the load
/// check is off.
pub fn gate(cfg: Config, m: Machine, budget: u32, valve: ?*Valve, now: i64) Gate {
    if (cfg.pressure_check and m.pressure == .high) return .pressure;
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
    const room = if (free >= lo + reserve) free - reserve else free;
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
    try testing.expectEqual(Pressure.high, macPressure(2));
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
    try testing.expectEqual(Qos.background, qosFor(.low, false, true));
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
    try parseConfig("# cpuq\nbudget = 6\nload_check = off # quiet\npoll = 0.5\naging = 60\n", &cfg, &diag);
    try testing.expectEqual(6, cfg.budget.?);
    try testing.expect(!cfg.load_check);
    try testing.expectEqual(500, cfg.poll_ms);
    try testing.expectEqual(60, cfg.aging_s);

    var cfg3: Config = .{};
    try testing.expectError(error.ConfigInvalid, parseConfig("budget = 6\nbudgte = 3\n", &cfg3, &diag));
    try testing.expectEqual(2, diag.line);
    try testing.expectError(error.ConfigInvalid, parseConfig("budget = 0\n", &cfg3, &diag));
}
