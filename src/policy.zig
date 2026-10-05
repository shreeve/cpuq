//! Pure decisions: the configuration file, the effective budget, the
//! admission gates, the admission rule and the MAKEFLAGS rewrite. Every input
//! is a value, so the unit tests inject them.
const std = @import("std");

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
        .normal => .utility,
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
        } else {
            return bad(diag, "unknown key");
        }
    }
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
/// the active cores minus a reserve of 2; capped by the active cores and by
/// the machine's cores (one token file per core).
pub fn effectiveBudget(env_budget: ?u32, cfg: Config, active: u32, cores: u32) u32 {
    const live = @max(active, 1);
    var b = env_budget orelse cfg.budget orelse (if (live > 2) live - 2 else 1);
    if (cfg.active_cap and b > live) b = live;
    if (b > cores) b = cores;
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
/// reopens only after the load has stayed at or under the budget for
/// `calm_s`; while the load is above the budget (tripped or not) it admits
/// at most one job per `spacing_s`, so waiters never stampede into a load
/// average that lags. A tripped valve nobody has checked for `stale_s`
/// reopens at once when the load is at or under the budget: the 1-minute
/// load average already covers that calm.
pub const Valve = struct {
    tripped: bool = false,
    calm_since: i64 = 0,
    last_admit: i64 = 0,
    last_check: i64 = 0,

    pub const calm_s = 30;
    pub const spacing_s = 10;
    pub const stale_s = 60;

    pub const Verdict = enum { open, tripped, spacing };

    pub fn check(v: *Valve, now: i64, load: f64, budget: u32, margin: f64) Verdict {
        const unchecked_s = now - v.last_check;
        v.last_check = now;
        const b: f64 = @floatFromInt(budget);
        if (load > b + margin) {
            v.tripped = true;
            v.calm_since = 0;
            return .tripped;
        }
        if (v.tripped) {
            if (load > b) {
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

pub const Pressure = enum { normal, high, unknown };

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
    if (valve) |v| if (cfg.load_check) switch (v.check(now, m.load1, budget, cfg.load_margin)) {
        .open => {},
        .tripped => return .{ .load = m.load1 },
        .spacing => return .{ .spacing = m.load1 },
    };
    return .open;
}

/// The cores a request is granted: an exclusive run takes the whole budget,
/// any other request is clamped to it.
pub fn grant(requested: u32, exclusive: bool, budget: u32) u32 {
    return if (exclusive) budget else @min(@max(requested, 1), budget);
}

/// The admission rule for the head of the queue. `held` counts the tokens
/// held by running work; `exclusive_running` is true while an exclusive
/// lease is alive.
pub fn fits(k: u32, exclusive: bool, budget: u32, held: u32, exclusive_running: bool) bool {
    if (exclusive_running) return false;
    if (exclusive) return held == 0;
    return held + k <= budget;
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
    try testing.expectEqual(8, effectiveBudget(null, cfg, 10, 10));
    try testing.expectEqual(1, effectiveBudget(null, cfg, 2, 2));
    try testing.expectEqual(1, effectiveBudget(null, cfg, 0, 10));
    try testing.expectEqual(9, effectiveBudget(9, cfg, 10, 10));
    try testing.expectEqual(6, effectiveBudget(9, cfg, 6, 10)); // only 6 cores active
    try testing.expectEqual(4, effectiveBudget(null, .{ .budget = 4 }, 10, 10));
    try testing.expectEqual(5, effectiveBudget(5, .{ .budget = 4 }, 10, 10)); // env wins
    try testing.expectEqual(10, effectiveBudget(16, .{ .active_cap = false }, 10, 10)); // one token per core
    try testing.expectEqual(10, effectiveBudget(16, cfg, 10, 10));
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
    const cfg: Config = .{}; // margin 4, budget 8: trips above 12
    var v: Valve = .{};
    const at = struct {
        fn m(load: f64) Machine {
            return .{ .active = 10, .load1 = load, .pressure = .normal };
        }
    };
    try testing.expectEqual(Gate.open, gate(cfg, at.m(7), 8, &v, 100));
    try testing.expectEqual(Gate{ .load = 12.5 }, gate(cfg, at.m(12.5), 8, &v, 101));
    // Back under budget + margin but over the budget: still tripped.
    try testing.expectEqual(Gate{ .load = 10 }, gate(cfg, at.m(10), 8, &v, 110));
    // Under the budget, but not yet for 30 s.
    try testing.expectEqual(Gate{ .load = 7 }, gate(cfg, at.m(7), 8, &v, 120));
    try testing.expectEqual(Gate{ .load = 7.5 }, gate(cfg, at.m(7.5), 8, &v, 149));
    // A load spike restarts the calm period.
    try testing.expectEqual(Gate{ .load = 9 }, gate(cfg, at.m(9), 8, &v, 150));
    try testing.expectEqual(Gate{ .load = 7 }, gate(cfg, at.m(7), 8, &v, 151));
    try testing.expectEqual(Gate.open, gate(cfg, at.m(7), 8, &v, 181));
    try testing.expect(!v.tripped);
    // Over the budget (not tripped): one admission per 10 s.
    v.last_admit = 181;
    try testing.expectEqual(Gate{ .spacing = 9 }, gate(cfg, at.m(9), 8, &v, 185));
    try testing.expectEqual(Gate.open, gate(cfg, at.m(9), 8, &v, 191));
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
    const busy: Machine = .{ .active = 10, .load1 = 9, .pressure = .normal };
    // Tripped and unchecked for an hour: open at once if the load is calm.
    var v: Valve = .{ .tripped = true, .last_check = 1000 };
    try testing.expectEqual(Gate.open, gate(cfg, calm, 8, &v, 4600));
    try testing.expect(!v.tripped);
    try testing.expectEqual(4600, v.last_check);
    // Left by a file without a check time: the same.
    v = Valve.parse("1 0 0\n");
    try testing.expectEqual(Gate.open, gate(cfg, calm, 8, &v, 4600));
    // Stale, but the load is over the budget: still tripped.
    v = .{ .tripped = true, .last_check = 1000 };
    try testing.expectEqual(Gate{ .load = 9 }, gate(cfg, busy, 8, &v, 4600));
    // Checked a moment ago: the calm period still applies.
    v = .{ .tripped = true, .last_check = 4590 };
    try testing.expectEqual(Gate{ .load = 3 }, gate(cfg, calm, 8, &v, 4600));
}

test "active-core cap shrinks the grant" {
    // 10 cores active, budget 8: a 9-core request is clamped to 8.
    try testing.expectEqual(8, grant(9, false, effectiveBudget(null, .{}, 10, 10)));
    // Only 6 cores active: the same request gets 6.
    try testing.expectEqual(6, grant(9, false, effectiveBudget(9, .{}, 6, 10)));
    try testing.expectEqual(1, grant(0, false, 8));
    try testing.expectEqual(8, grant(2, true, 8));
}

test "admission rule" {
    try testing.expect(fits(3, false, 9, 6, false));
    try testing.expect(!fits(3, false, 9, 7, false));
    try testing.expect(fits(9, true, 9, 0, false));
    try testing.expect(!fits(9, true, 9, 1, false));
    try testing.expect(!fits(1, false, 9, 0, true)); // an exclusive run blocks everything
    try testing.expect(!fits(2, false, 4, 3, false)); // budget lowered under running work
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
    try testing.expectEqual(Qos.utility, qosFor(.normal, false, true));
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
