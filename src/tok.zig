//! `cpuq tok`: a job that takes its CPUs as tokens, one file per CPU, by rename, and gives
//! them back when its command ends. No daemon and no lock decide who runs: a token is taken
//! by renaming it out of `free/`, which only one taker can do, as swarm takes its job files.
//!
//!   tok/free/NNNN                          a free token
//!   tok/live/NNNN-PID-START                a token a `cpuq tok` holds (its pid, and when that
//!                                          process started)
//!   tok/runs/NNNN-PID-START-LEASE          a token a `cpuq run` holds for its grant
//!   tok/wait/C-TICKET-N-PID-START          a waiter needing N tokens (C its priority class)
//!   tok/held/C-TICKET-N-PID-START          the same job once it runs
//!   tok/reserve                            flocked by the one waiter that holds some tokens
//!                                          and fights for the rest
//!   tok/made                               how many token files have been made
//!
//! A holder is alive while its pid names a process that started when its name says, so a pid
//! the kernel has reused is not trusted. Any waiter, about once a second, gives back the
//! tokens of a holder that is gone; a run's tokens go back once its cpuq and its lease are
//! both gone.
//!
//! Deadlock and starvation. Waiters are ordered by (priority class, ticket), one ticket
//! sequence shared with `cpuq run`. A *blocker* is a live `cpuq run` waiter or a live tok
//! waiter needing more than one token. A one-token waiter takes a token only while it is
//! ahead of the first blocker and fewer one-token waiters are ahead of it than tokens are
//! free; a run waiter within its `patience` doesn't hold one-token waiters back (backfill). A waiter needing N > 1 holds nothing until it is the first blocker and holds
//! `tok/reserve`; then it keeps what it takes and fights on until it has N. `cpuq run`
//! admits nobody while `tok/reserve` is held or the first blocker is a tok waiter, and its
//! grants are all or nothing. So at most one waiter ever holds part of what it needs, and
//! every token freed goes to it or to one of the finitely many one-token waiters ahead of
//! it: it completes. Tickets only grow, so each waiter in its class becomes the first
//! blocker in turn.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const c = std.c;
const policy = @import("policy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");
const cap = @import("cap.zig");

const main = @import("main.zig");
const runopts = @import("runopts.zig");
const runner = @import("runner.zig");
const admission = @import("admission.zig");

const Ctx = main.Ctx;
const fail = main.fail;
const usageError = main.usageError;

/// The most token files a pool has: their numbers are four digits.
const max_tokens = 9999;

/// How long a waiter sleeps between looks at the free tokens, and the jitter around it.
const poll_ms = 100;
const jitter_ms = 20;

/// After `--timeout`, how long the command has after SIGTERM before SIGKILL.
pub const grace_ms = 10_000;

/// Exit status of a command stopped by `--timeout`, as GNU timeout's.
pub const exit_timeout = 124;

/// A process, by its pid and when it started.
pub const Holder = struct {
    pid: i32,
    start: u64,

    pub fn self() Holder {
        const pid = sys.getpid();
        return .{ .pid = pid, .start = sys.procStart(pid) orelse 0 };
    }

    /// Whether this process still runs: its pid is live and started when the name says.
    pub fn alive(h: Holder) bool {
        if (!sys.processAlive(h.pid)) return false;
        const s = sys.procStart(h.pid) orelse return false;
        return s == h.start;
    }
};

/// A waiter's place in the order: priority class, then ticket.
pub const Key = struct {
    class: u2,
    ticket: u64,

    pub fn less(a: Key, b: Key) bool {
        if (a.class != b.class) return a.class < b.class;
        return a.ticket < b.ticket;
    }

    pub fn eql(a: Key, b: Key) bool {
        return a.class == b.class and a.ticket == b.ticket;
    }
};

/// A tok waiter or holder, as its file's name says.
pub const Job = struct {
    key: Key,
    n: u32,
    holder: Holder,
};

/// `C-TICKET-N-PID-START`.
pub fn parseJob(name: []const u8) ?Job {
    var it = std.mem.splitScalar(u8, name, '-');
    const class = std.fmt.parseInt(u2, it.next() orelse return null, 10) catch return null;
    const ticket = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const n = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const pid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const start = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    if (it.next() != null) return null;
    return .{ .key = .{ .class = class, .ticket = ticket }, .n = n, .holder = .{ .pid = pid, .start = start } };
}

pub fn jobName(buf: []u8, j: Job) []const u8 {
    return std.mem.print(buf, "{d}-{d:0>10}-{d}-{d}-{d}", .{ j.key.class, j.key.ticket, j.n, j.holder.pid, j.holder.start }) catch unreachable;
}

/// A taken token, as its name in `live/` or `runs/` says: `NNNN-PID-START[-LEASE]`.
pub const Taken = struct {
    num: u32,
    holder: Holder,
    /// A run's lease (`runs/` only); "" for a tok.
    lease: []const u8 = "",
};

pub fn parseTaken(name: []const u8) ?Taken {
    var it = std.mem.splitScalar(u8, name, '-');
    const num = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
    const pid = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    const start = std.fmt.parseInt(u64, it.next() orelse return null, 10) catch return null;
    const lease = it.rest();
    return .{ .num = num, .holder = .{ .pid = pid, .start = start }, .lease = lease };
}

/// A `cpuq run` ticket's name, `C-TICKET`: its key.
fn parseTicket(name: []const u8) ?Key {
    const class_text, const ticket_text = std.mem.cutScalar(u8, name, '-') orelse return null;
    return .{
        .class = std.fmt.parseInt(u2, class_text, 10) catch return null,
        .ticket = std.fmt.parseInt(u64, ticket_text, 10) catch return null,
    };
}

fn tokenName(buf: []u8, num: u32) []const u8 {
    return std.mem.print(buf, "{d:0>4}", .{num}) catch unreachable;
}

/// The pool of a state directory.
pub const Pool = struct {
    io: Io,
    dir: Io.Dir,
    free: Io.Dir,
    live: Io.Dir,
    runs: Io.Dir,
    wait: Io.Dir,
    held: Io.Dir,
    /// The state directory's `queue/` and `leases/`: `cpuq run`'s waiters and holders.
    queue: Io.Dir,
    leases: Io.Dir,

    /// The pool in `base` (a state directory), made if it isn't there.
    pub fn openIn(io: Io, base: Io.Dir) !Pool {
        try base.createDirPath(io, "tok");
        const dir = try base.openDir(io, "tok", .{ .iterate = true });
        return .{
            .io = io,
            .dir = dir,
            .free = try sub(io, dir, "free"),
            .live = try sub(io, dir, "live"),
            .runs = try sub(io, dir, "runs"),
            .wait = try sub(io, dir, "wait"),
            .held = try sub(io, dir, "held"),
            .queue = try sub(io, base, "queue"),
            .leases = try sub(io, base, "leases"),
        };
    }

    pub fn of(st: *state.State) !Pool {
        return openIn(st.io, st.dir);
    }

    pub fn close(p: Pool) void {
        inline for (.{ "free", "live", "runs", "wait", "held", "queue", "leases", "dir" }) |name| @field(p, name).close(p.io);
    }

    fn sub(io: Io, dir: Io.Dir, name: []const u8) !Io.Dir {
        try dir.createDirPath(io, name);
        return dir.openDir(io, name, .{ .iterate = true });
    }

    /// How many token files have been made.
    pub fn made(p: Pool) u32 {
        var buf: [32]u8 = undefined;
        const text = p.dir.readFile(p.io, "made", &buf) catch return 0;
        return std.fmt.parseInt(u32, std.mem.trim(u8, text, " \n"), 10) catch 0;
    }

    /// Makes token files up to `limit`, with the admission lock held. Files are never
    /// removed, and only numbers never made before are made, so a token on its way between
    /// two directories is never made twice; a pool that shrinks leaves its higher numbers
    /// unused.
    pub fn ensureLocked(p: Pool, limit: u32) void {
        const want = @min(limit, max_tokens);
        const have = p.made();
        if (have >= want) return;
        var i = have;
        while (i < want) : (i += 1) {
            var buf: [8]u8 = undefined;
            const f = p.free.createFile(p.io, tokenName(&buf, i), .{ .truncate = false }) catch continue;
            f.close(p.io);
        }
        var out: [32]u8 = undefined;
        p.dir.writeFile(p.io, .{ .sub_path = "made.new", .data = std.mem.print(&out, "{d}\n", .{want}) catch return }) catch return;
        p.dir.rename("made.new", p.dir, "made", p.io) catch {};
    }

    /// `ensureLocked`, taking the admission lock only when there are tokens to make.
    pub fn ensure(p: Pool, st: *state.State, limit: u32) void {
        if (p.made() >= @min(limit, max_tokens)) return;
        st.lock() catch return;
        defer st.unlock();
        p.ensureLocked(limit);
    }

    /// The free tokens below `limit`, by number.
    pub fn freeTokens(p: Pool, a: std.mem.Allocator, limit: u32) []u32 {
        var out: std.ArrayList(u32) = .empty;
        var it = p.free.iterate();
        while (it.next(p.io) catch null) |e| {
            const num = std.fmt.parseInt(u32, e.name, 10) catch continue;
            if (num < limit) out.append(a, num) catch break;
        }
        return out.items;
    }

    /// How many entries a directory has.
    fn count(p: Pool, dir: Io.Dir) u32 {
        var n: u32 = 0;
        var it = dir.iterate();
        while (it.next(p.io) catch null) |e| {
            if (e.name[0] != '.') n += 1;
        }
        return n;
    }

    /// Tokens held by `cpuq tok` jobs.
    pub fn liveCount(p: Pool) u32 {
        return p.count(p.live);
    }

    /// Takes up to `want` free tokens below `limit` into `dest` (`live` or `runs`), each named
    /// NNNN-SUFFIX; returns the numbers taken. A token another taker renamed first is passed
    /// over. `rng` picks where in the list to start, so takers spread over the tokens.
    pub fn take(p: Pool, a: std.mem.Allocator, rng: std.Random, limit: u32, dest: Io.Dir, suffix: []const u8, want: u32) []u32 {
        var got: std.ArrayList(u32) = .empty;
        if (want == 0) return got.items;
        const free = p.freeTokens(a, limit);
        if (free.len == 0) return got.items;
        const first = rng.intRangeLessThan(usize, 0, free.len);
        for (0..free.len) |k| {
            const num = free[(first + k) % free.len];
            var from_buf: [8]u8 = undefined;
            var to_buf: [96]u8 = undefined;
            const to = std.mem.print(&to_buf, "{d:0>4}-{s}", .{ num, suffix }) catch continue;
            p.free.rename(tokenName(&from_buf, num), dest, to, p.io) catch continue;
            got.append(a, num) catch break;
            if (got.items.len >= want) break;
        }
        return got.items;
    }

    /// Gives back tokens taken into `from` under SUFFIX.
    pub fn give(p: Pool, from: Io.Dir, suffix: []const u8, nums: []const u32) void {
        for (nums) |num| {
            var from_buf: [96]u8 = undefined;
            var to_buf: [8]u8 = undefined;
            const name = std.mem.print(&from_buf, "{d:0>4}-{s}", .{ num, suffix }) catch continue;
            from.rename(name, p.free, tokenName(&to_buf, num), p.io) catch {};
        }
    }

    /// Whether the lease a run's token names is still held (by its cpuq or its command).
    fn leaseHeld(p: Pool, lease: []const u8) bool {
        if (lease.len == 0 or std.mem.findScalar(u8, lease, '/') != null) return false;
        const f = p.leases.openFile(p.io, lease, .{}) catch return false;
        defer f.close(p.io);
        const free = f.tryLock(p.io, .shared) catch return false;
        if (free) f.unlock(p.io);
        return !free;
    }

    /// Whether the command of a `cpuq tok` that is gone still runs: its process group (named by
    /// its pid, recorded in `held/`) has a process left. A cpuq killed outright leaves its
    /// command running, holding its tokens, until the command's group is gone, as `cpuq run`'s
    /// command keeps its cores. A group's id is not reused while the group exists.
    fn commandRuns(p: Pool, h: Holder) bool {
        var it = p.held.iterate();
        while (it.next(p.io) catch null) |e| {
            const j = parseJob(e.name) orelse continue;
            if (j.holder.pid != h.pid or j.holder.start != h.start) continue;
            var buf: [4096]u8 = undefined;
            const text = p.held.readFile(p.io, e.name, &buf) catch return false;
            const r = state.Record.parse(text);
            return sys.groupAlive(r.child);
        }
        return false;
    }

    /// Gives back the tokens of holders that are gone (a `cpuq tok` and its command's group,
    /// or a `cpuq run` and its lease), and removes the files of waiters and holders that are
    /// gone. Returns how many tokens went back.
    pub fn reap(p: Pool) u32 {
        var back: u32 = 0;
        inline for (.{ "live", "runs" }) |which| {
            const dir = @field(p, which);
            var it = dir.iterate();
            while (it.next(p.io) catch null) |e| {
                const t = parseTaken(e.name) orelse continue;
                if (t.holder.alive()) continue;
                if (t.lease.len != 0 and p.leaseHeld(t.lease)) continue;
                if (t.lease.len == 0 and p.commandRuns(t.holder)) continue;
                var to_buf: [8]u8 = undefined;
                var name_buf: [128]u8 = undefined;
                const name = std.mem.print(&name_buf, "{s}", .{e.name}) catch continue;
                dir.rename(name, p.free, tokenName(&to_buf, t.num), p.io) catch continue;
                back += 1;
            }
        }
        inline for (.{ "wait", "held" }) |which| {
            const dir = @field(p, which);
            var it = dir.iterate();
            while (it.next(p.io) catch null) |e| {
                const j = parseJob(e.name) orelse continue;
                if (j.holder.alive()) continue;
                if (std.mem.eql(u8, which, "held") and p.commandRuns(j.holder)) continue;
                var name_buf: [128]u8 = undefined;
                const name = std.mem.print(&name_buf, "{s}", .{e.name}) catch continue;
                dir.deleteFile(p.io, name) catch {};
            }
        }
        return back;
    }

    /// Whether a waiter holds `tok/reserve`.
    pub fn reserved(p: Pool) bool {
        const f = p.dir.openFile(p.io, "reserve", .{}) catch return false;
        defer f.close(p.io);
        const free = f.tryLock(p.io, .shared) catch return false;
        if (free) f.unlock(p.io);
        return !free;
    }

    /// Takes `tok/reserve`, or returns null when another waiter holds it.
    pub fn takeReserve(p: Pool) ?Io.File {
        const f = state.State.createShared(p.io, p.dir, "reserve") catch return null;
        const got = f.tryLock(p.io, .exclusive) catch false;
        if (got) return f;
        f.close(p.io);
        return null;
    }

    /// Who may take tokens now (see the top of this file). A `cpuq run` waiter that has waited
    /// less than `patience_s` holds back only waiters needing several tokens: one-token jobs
    /// behind it may go ahead, as backfill lets jobs go ahead of `cpuq run`'s head.
    pub fn plan(p: Pool, a: std.mem.Allocator, now_s: i64, patience_s: u32) Plan {
        const Entry = struct { key: Key, n: u32 = 0, holder: ?Holder = null, name: []const u8 };
        var list: std.ArrayList(Entry) = .empty;
        var it = p.wait.iterate();
        while (it.next(p.io) catch null) |e| {
            const j = parseJob(e.name) orelse continue;
            list.append(a, .{ .key = j.key, .n = j.n, .holder = j.holder, .name = a.dupe(u8, e.name) catch continue }) catch break;
        }
        var qi = p.queue.iterate();
        while (qi.next(p.io) catch null) |e| {
            if (e.name[0] == '.') continue;
            const key = parseTicket(e.name) orelse continue;
            list.append(a, .{ .key = key, .name = a.dupe(u8, e.name) catch continue }) catch break;
        }
        std.mem.sortUnstable(Entry, list.items, {}, struct {
            fn less(_: void, x: Entry, y: Entry) bool {
                return x.key.less(y.key);
            }
        }.less);
        var singles: std.ArrayList(Key) = .empty;
        var out: Plan = .{ .reserved = p.reserved() };
        for (list.items) |e| {
            if (e.holder) |h| {
                if (e.n <= 1) {
                    // A one-token waiter: counted by its pid alone, which is cheap; a pid reused
                    // meanwhile is caught by the next reap.
                    if (sys.processAlive(h.pid)) singles.append(a, e.key) catch {};
                    continue;
                }
                if (!h.alive()) continue;
                if (out.first == null) out.first = .{ .key = e.key, .run = false };
                out.blocker = .{ .key = e.key, .run = false };
                break;
            }
            // A `cpuq run` waiter, alive while it holds its ticket's lock.
            const f = p.queue.openFile(p.io, e.name, .{}) catch continue;
            defer f.close(p.io);
            const free = f.tryLock(p.io, .shared) catch continue;
            if (free) {
                f.unlock(p.io);
                continue;
            }
            if (out.first == null) out.first = .{ .key = e.key, .run = true };
            const r = state.readRecord(p.io, a, f) orelse state.Record{};
            if (r.since != 0 and now_s - r.since < patience_s) continue;
            out.blocker = .{ .key = e.key, .run = true };
            break;
        }
        out.singles = singles.items;
        return out;
    }
};

pub const Plan = struct {
    pub const Blocker = struct { key: Key, run: bool };
    /// The first blocker: a live `cpuq run` waiter, or a live tok waiter needing more than one
    /// token; null when there is none.
    first: ?Blocker = null,
    /// The first that holds back one-token waiters too: `first`, unless that is a `cpuq run`
    /// waiter still within its patience (then the next such, or a tok waiter needing several).
    blocker: ?Blocker = null,
    /// The live one-token waiters ahead of `blocker`, in order.
    singles: []const Key = &.{},
    /// Whether a waiter holds `tok/reserve` (some of its tokens, fighting for the rest).
    reserved: bool = false,

    /// Whether the one-token waiter `key` may take a token, with `free` tokens free.
    pub fn singleMay(pl: Plan, key: Key, free: usize) bool {
        if (pl.blocker) |b| if (!key.less(b.key)) return false;
        var ahead: usize = 0;
        for (pl.singles) |k| {
            if (k.less(key)) ahead += 1;
        }
        return ahead < free;
    }

    /// Whether a one-token job that has no ticket yet may take a free token at once.
    pub fn newcomerMay(pl: Plan) bool {
        return pl.blocker == null and pl.singles.len == 0 and !pl.reserved;
    }

    /// Whether the waiter `key` is the first blocker, and so may try for `tok/reserve`.
    pub fn firstBlocker(pl: Plan, key: Key) bool {
        const b = pl.first orelse return false;
        return !b.run and b.key.eql(key);
    }

    /// Whether `cpuq run` may admit now: no waiter holds `tok/reserve`, and the first
    /// blocker is a `cpuq run` waiter (or there is none).
    pub fn runsMay(pl: Plan) bool {
        if (pl.reserved) return false;
        const b = pl.first orelse return true;
        return b.run;
    }
};

/// The tokens a pool has: under `admit = cores`, the budget; under measured admission, the
/// target, rounded up.
pub fn limitFor(ctx: *Ctx) u32 {
    if (ctx.cfg.admit == .measured) return @intFromFloat(@max(@ceil(admission.targetCpus(ctx)), 1));
    return main.budgetNow(ctx, .{ .active = sys.activeCpus(ctx.io), .load1 = 0, .pressure = .off });
}

// ---- `cpuq run`'s side ----------------------------------------------------------------------

/// The CPUs `cpuq tok` jobs are confined to (Linux, `affinity`), one per token they hold:
/// where `cpuq run` places a job, they count as busy.
pub fn tokCpus(st: *state.State, a: std.mem.Allocator, online: []const u32) []u32 {
    var out: std.ArrayList(u32) = .empty;
    if (online.len == 0) return out.items;
    const dir = st.dir.openDir(st.io, "tok/live", .{ .iterate = true }) catch return out.items;
    defer dir.close(st.io);
    var it = dir.iterate();
    while (it.next(st.io) catch null) |e| {
        const t = parseTaken(e.name) orelse continue;
        out.append(a, online[t.num % online.len]) catch break;
    }
    return out.items;
}

/// Whether `cpuq run` may admit a job now (`Plan.runsMay`). Call with the admission lock
/// held.
pub fn runsMay(st: *state.State, a: std.mem.Allocator) bool {
    const p = Pool.of(st) catch return true;
    defer p.close();
    return p.plan(a, 0, 0).runsMay();
}

/// The tokens a `cpuq run` holds for its grant, given back when it ends.
pub const Parked = struct {
    nums: []const u32 = &.{},
    suffix: []const u8 = "",
};

/// Takes `want` tokens for a `cpuq run` whose lease will be `lease`, with the admission lock
/// held. `strict`: all or none (null when fewer are free); otherwise as many as are free.
pub fn park(st: *state.State, a: std.mem.Allocator, limit: u32, lease: []const u8, want: u32, strict: bool) ?Parked {
    const p = Pool.of(st) catch return if (strict) null else Parked{};
    defer p.close();
    p.ensureLocked(limit);
    _ = p.reap();
    const me = Holder.self();
    const suffix = a.print("{d}-{d}-{s}", .{ me.pid, me.start, lease }) catch return null;
    var prng: std.Random.DefaultPrng = .init(@bitCast(@as(i64, me.pid) * 7919 +% sys.monoMs()));
    const got = p.take(a, prng.random(), limit, p.runs, suffix, want);
    if (strict and got.len < want) {
        p.give(p.runs, suffix, got);
        return null;
    }
    return .{ .nums = got, .suffix = suffix };
}

/// Gives back a run's tokens.
pub fn unpark(st: *state.State, parked: Parked) void {
    if (parked.nums.len == 0) return;
    const p = Pool.of(st) catch return;
    defer p.close();
    p.give(p.runs, parked.suffix, parked.nums);
}

// ---- `cpuq tok` ------------------------------------------------------------------------------

pub const Options = struct {
    n: u32 = 1,
    timeout_ms: ?u64 = null,
    label: []const u8 = "",
    priority: policy.Priority = .normal,
    cmd: []const [:0]const u8 = &.{},
};

pub fn parse(args: []const [:0]const u8) ?Options {
    var o: Options = .{};
    var i: usize = 0;
    if (i < args.len and args[i].len != 0 and args[i][0] != '-') {
        o.n = policy.parseCount(args[i]) orelse {
            _ = usageError("tok takes a count of tokens, a whole number of at least 1, not '{s}'", .{args[i]});
            return null;
        };
        i += 1;
    }
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            o.cmd = args[i + 1 ..];
            break;
        }
        const name, const inline_value = std.mem.cutScalar(u8, arg, '=') orelse .{ arg, null };
        const known = [_][]const u8{ "--timeout", "--label", "--priority" };
        for (known) |k| {
            if (std.mem.eql(u8, name, k)) break;
        } else {
            _ = usageError("tok: unknown option '{s}'", .{arg});
            return null;
        }
        const value = inline_value orelse blk: {
            i += 1;
            if (i >= args.len) {
                _ = usageError("{s} needs a value", .{name});
                return null;
            }
            break :blk args[i];
        };
        if (std.mem.eql(u8, name, "--timeout")) {
            o.timeout_ms = cap.parseDuration(value) orelse {
                _ = usageError("--timeout needs a duration (90, 90s, 10m, 1h), not '{s}'", .{value});
                return null;
            };
        } else if (std.mem.eql(u8, name, "--label")) {
            o.label = value;
        } else if (std.mem.eql(u8, name, "--priority")) {
            o.priority = policy.Priority.parse(value) orelse {
                _ = usageError("--priority is high, normal or low, not '{s}'", .{value});
                return null;
            };
        }
    }
    return o;
}

test "parse" {
    const o = parse(&.{ "8", "--timeout", "90s", "--label=a:b", "--", "make", "-k" }).?;
    try std.testing.expectEqual(8, o.n);
    try std.testing.expectEqual(90_000, o.timeout_ms.?);
    try std.testing.expectEqualStrings("a:b", o.label);
    try std.testing.expectEqual(2, o.cmd.len);
    const d = parse(&.{ "--", "true" }).?;
    try std.testing.expectEqual(1, d.n);
    try std.testing.expectEqual(null, d.timeout_ms);
}

/// What the wait loop does about `--timeout` now: nothing, ask the group to stop (SIGTERM), or
/// make it (SIGKILL), `grace_ms` after asking.
pub const Stop = enum { none, term, kill };

pub fn timeoutStep(now_ms: i64, started_ms: i64, timeout_ms: ?u64, termed_at: ?i64, killed: bool) Stop {
    const t = timeout_ms orelse return .none;
    if (termed_at) |at| return if (!killed and now_ms - at >= grace_ms) .kill else .none;
    return if (now_ms - started_ms >= @as(i64, @intCast(t))) .term else .none;
}

test "timeoutStep" {
    try std.testing.expectEqual(Stop.none, timeoutStep(5_000, 0, null, null, false));
    try std.testing.expectEqual(Stop.none, timeoutStep(999, 0, 1_000, null, false));
    try std.testing.expectEqual(Stop.term, timeoutStep(1_000, 0, 1_000, null, false));
    try std.testing.expectEqual(Stop.none, timeoutStep(1_000 + grace_ms - 1, 0, 1_000, 1_000, false));
    try std.testing.expectEqual(Stop.kill, timeoutStep(1_000 + grace_ms, 0, 1_000, 1_000, false));
    try std.testing.expectEqual(Stop.none, timeoutStep(1_000 + grace_ms * 2, 0, 1_000, 1_000, true));
}

/// The signal the tool was sent, for its loops to act on (0: none).
var pending = std.atomic.Value(i32).init(0);

fn onSignal(sig: c.SIG) callconv(.c) void {
    pending.store(@intCast(@backingInt(sig)), .release);
}

/// The signals the tool takes and passes to its command's group. One it was started with
/// ignored (`nohup`) stays ignored, so the command inherits it ignored.
const caught = [_]c.SIG{ .HUP, .INT, .QUIT, .TERM };

fn installSignals() void {
    var sa: c.Sigaction = .{ .handler = .{ .handler = onSignal }, .mask = undefined, .flags = c.SA.RESTART };
    _ = c.sigemptyset(&sa.mask);
    for (caught) |sig| {
        var old: c.Sigaction = undefined;
        if (c.sigaction(sig, null, &old) == 0 and old.handler.handler == c.SIG.IGN) continue;
        _ = c.sigaction(sig, &sa, null);
    }
}

/// The waiter's own state, given back however it leaves.
const Mine = struct {
    p: Pool,
    me: Holder,
    suffix: []const u8,
    held: std.ArrayList(u32) = .empty,
    reserve: ?Io.File = null,
    /// Its file in `wait/` or `held/`, once it has a ticket.
    name: ?[]const u8 = null,
    in_held: bool = false,

    fn dropReserve(m: *Mine) void {
        if (m.reserve) |f| {
            f.unlock(m.p.io);
            f.close(m.p.io);
            m.reserve = null;
        }
    }

    /// Gives back every token and removes its file.
    fn leave(m: *Mine) void {
        m.p.give(m.p.live, m.suffix, m.held.items);
        m.held.clearRetainingCapacity();
        m.dropReserve();
        if (m.name) |n| (if (m.in_held) m.p.held else m.p.wait).deleteFile(m.p.io, n) catch {};
        m.name = null;
    }
};

/// The machine's gates, as they hold `cpuq run`: memory pressure, low memory, low disk, and the
/// load valve (whatever the admission mode, since work outside cpuq still runs). The valve's
/// state is read, not written: its spacing is for jobs that start many threads at once, and
/// tokens already bound how many cpuq starts.
fn gateOpen(ctx: *Ctx, st: *state.State, busy: ?f64) bool {
    var m = main.machine(ctx);
    m.busy = busy;
    var valve = st.readValve();
    const now = main.nowSeconds(ctx.io);
    return switch (policy.gate(ctx.cfg, m, main.budgetNow(ctx, m), &valve, now)) {
        .open, .spacing => true,
        else => false,
    };
}

pub fn cmdTok(ctx: *Ctx, args: []const [:0]const u8) u8 {
    const o = parse(args) orelse return main.exit_usage;
    if (o.cmd.len == 0) return usageError("tok needs a command: cpuq tok [N] -- CMD ARGS...", .{});
    const io = ctx.io;

    // Inside a running job (a `cpuq run`, or another `cpuq tok`): its tokens are this one's.
    if (runner.nestedGrant(ctx)) {
        const err = std.process.replace(io, .{ .argv = @ptrCast(o.cmd) });
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        return if (err == error.FileNotFound) main.exit_notfound else main.exit_noexec;
    }
    main.loadConfig(ctx);
    const exe = runopts.findExecutable(ctx, o.cmd[0]) orelse {
        std.debug.print("cpuq: {s}: command not found\n", .{o.cmd[0]});
        return main.exit_notfound;
    };
    var st = main.openState(ctx);
    const p = Pool.of(&st) catch |err| fail("tok pool in {s}: {t}", .{ st.path, err });
    const a = ctx.arena;
    var limit = limitFor(ctx);
    p.ensure(&st, limit);
    var n = o.n;
    if (n > limit) {
        std.debug.print("cpuq: {d} tokens asked for, {d} exist: taking {d}\n", .{ n, limit, limit });
        n = limit;
    }

    const me = Holder.self();
    if (me.start == 0) fail("can't read this process's start time", .{});
    var mine: Mine = .{ .p = p, .me = me, .suffix = a.print("{d}-{d}", .{ me.pid, me.start }) catch fail("out of memory", .{}) };
    var prng: std.Random.DefaultPrng = .init(@bitCast(@as(i64, me.pid) *% 2654435761 +% sys.monoMs()));
    const rng = prng.random();
    installSignals();

    var key: ?Key = null;
    var job: Job = undefined;
    const since = main.nowSeconds(io);
    var ticks = sys.cpuTicks(io);
    var gate_open = gateOpen(ctx, &st, null);
    var next_look: i64 = sys.monoMs() + 1000;
    var said_waiting = false;
    while (mine.held.items.len < n) {
        if (takePending()) |s| {
            mine.leave();
            sys.dieBySignal(s);
        }
        const now_ms = sys.monoMs();
        if (now_ms >= next_look) {
            next_look = now_ms + 1000;
            main.reloadConfig(ctx);
            limit = limitFor(ctx);
            p.ensure(&st, limit);
            _ = p.reap();
            const now_ticks = sys.cpuTicks(io);
            var busy: ?f64 = null;
            if (ticks) |t0| if (now_ticks) |t1| {
                busy = sys.busyBetween(t0, t1);
            };
            ticks = now_ticks;
            gate_open = gateOpen(ctx, &st, busy);
        }
        if (gate_open) {
            var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
            defer scratch.deinit();
            const sa = scratch.allocator();
            const free = p.freeTokens(sa, limit);
            if (free.len != 0 or (n > 1 and mine.reserve == null)) {
                const pl = p.plan(sa, main.nowSeconds(io), ctx.cfg.patience_s);
                if (n == 1) {
                    const may = if (key) |k| pl.singleMay(k, free.len) else pl.newcomerMay();
                    if (may and free.len != 0) {
                        const got = p.take(sa, rng, limit, p.live, mine.suffix, 1);
                        mine.held.appendSlice(a, got) catch fail("out of memory", .{});
                    }
                } else if (key) |k| {
                    if (mine.reserve == null and pl.firstBlocker(k)) mine.reserve = p.takeReserve();
                    if (mine.reserve != null and free.len != 0) {
                        const got = p.take(sa, rng, limit, p.live, mine.suffix, n - @as(u32, @intCast(mine.held.items.len)));
                        mine.held.appendSlice(a, got) catch fail("out of memory", .{});
                    }
                }
            }
        }
        if (mine.held.items.len >= n) break;
        // Not started at once: take a ticket, a place in the order.
        if (key == null) {
            admission.lockOrFail(&st);
            const ticket = st.nextTicket() catch |err| fail("ticket: {t}", .{err});
            st.unlock();
            key = .{ .class = @backingInt(o.priority), .ticket = ticket };
            job = .{ .key = key.?, .n = n, .holder = me };
            mine.name = writeJob(a, p, p.wait, job, .{ .ticket = ticket, .pid = me.pid, .cores = n, .max = n, .priority = o.priority, .since = since, .label = o.label, .cmd = runopts.joinCommand(ctx, o.cmd) });
        }
        if (!said_waiting and main.nowSeconds(io) - since >= 60) {
            std.debug.print("cpuq: {s}{s}waiting for {d} {s}\n", .{ o.label, if (o.label.len != 0) ": " else "", n, if (n == 1) "token" else "tokens" });
            said_waiting = true;
        }
        io.sleep(.fromMilliseconds(poll_ms - jitter_ms + rng.intRangeLessThan(i64, 0, 2 * jitter_ms + 1)), .awake) catch {};
    }
    // All N held: no longer part of anyone's fight.
    mine.dropReserve();
    std.mem.sortUnstable(u32, mine.held.items, {}, std.sort.asc(u32));
    if (key == null) {
        const ticket: u64 = 0;
        key = .{ .class = @backingInt(o.priority), .ticket = ticket };
        job = .{ .key = key.?, .n = n, .holder = me };
    }
    var rec: state.Record = .{ .ticket = key.?.ticket, .pid = me.pid, .cores = n, .max = n, .priority = o.priority, .since = main.nowSeconds(io), .label = o.label, .cmd = runopts.joinCommand(ctx, o.cmd) };
    rec.slots = slotText(a, mine.held.items);
    // Into `held/`: from `wait/` by rename, or made there.
    if (mine.name) |name| {
        p.wait.rename(name, p.held, name, io) catch {};
    } else {
        mine.name = writeJob(a, p, p.held, job, rec);
    }
    mine.in_held = true;
    if (pending.load(.acquire) != 0) if (takePending()) |s| {
        mine.leave();
        sys.dieBySignal(s);
    };

    // The command: in a process group of its own, with the count and the token's name.
    var num: [16]u8 = undefined;
    ctx.env.put("CPUQ_CORES", std.mem.print(&num, "{d}", .{n}) catch "1") catch fail("out of memory", .{});
    ctx.env.put("CPUQ_TOKEN", a.print("tok-{s}", .{mine.suffix}) catch fail("out of memory", .{})) catch fail("out of memory", .{});
    _ = ctx.env.swapRemove("CPUQ_CPUS");
    // A GNU make jobserver of N slots, as `cpuq run` gives its command.
    const pipe = sys.jobserverPipe(n - 1) catch |err| fail("jobserver: {t}", .{err});
    ctx.env.put("MAKEFLAGS", policy.makeflags(a, ctx.env.get("MAKEFLAGS"), pipe[0], pipe[1]) catch fail("out of memory", .{})) catch fail("out of memory", .{});
    const cpus = pinned(ctx, a, mine.held.items);
    if (cpus.len != 0) ctx.env.put("CPUQ_CPUS", policy.cpuListText(a, cpus)) catch fail("out of memory", .{});
    const envp = ctx.env.createPosixBlock(a, .{}) catch fail("out of memory", .{});
    const argv = a.allocSentinel(?[*:0]const u8, o.cmd.len, null) catch fail("out of memory", .{});
    for (o.cmd, 0..) |arg, i| argv[i] = arg.ptr;
    const qos = policy.qosFor(o.priority, false, ctx.cfg.qos);
    const spawned = sys.spawn(exe, argv.ptr, @ptrCast(envp.slice.ptr), qos, .{ .cpus = cpus, .group = true });
    sys.closeFd(pipe[0]);
    sys.closeFd(pipe[1]);
    const child = spawned catch |err| {
        mine.leave();
        std.debug.print("cpuq: {s}: {t}\n", .{ o.cmd[0], err });
        return if (err == error.FileNotFound) main.exit_notfound else main.exit_noexec;
    };
    rec.child = child;
    if (mine.name) |name| rewriteJob(a, p, p.held, name, rec);

    const started = sys.monoMs();
    var termed_at: ?i64 = null;
    var killed = false;
    const waited: sys.Waited = while (true) {
        if (sys.reapChild(child)) |w| break w;
        if (takePending()) |s| _ = sys.signalGroup(child, s);
        const now_ms = sys.monoMs();
        switch (timeoutStep(now_ms, started, o.timeout_ms, termed_at, killed)) {
            .none => {},
            .term => {
                std.debug.print("cpuq: {s}{s}timed out after {d}s: stopping it\n", .{ o.label, if (o.label.len != 0) ": " else "", @as(f64, @floatFromInt(o.timeout_ms.?)) / 1000 });
                _ = sys.signalGroup(child, .TERM);
                termed_at = now_ms;
            },
            .kill => {
                _ = sys.signalGroup(child, .KILL);
                killed = true;
            },
        }
        io.sleep(.fromMilliseconds(poll_ms), .awake) catch {};
    };
    // Timed out: whatever else of its group is left goes too.
    if (termed_at != null) _ = sys.signalGroup(child, .KILL);
    mine.leave();
    if (termed_at != null) return exit_timeout;
    switch (waited.exit) {
        .code => |code| return code,
        .signal => |sig| sys.dieBySignal(sig),
    }
}

fn takePending() ?c.SIG {
    const s = pending.swap(0, .acq_rel);
    if (s == 0) return null;
    return @fromBackingInt(@intCast(s));
}

fn slotText(a: std.mem.Allocator, nums: []const u32) []const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (nums, 0..) |num, i| out.print(a, "{s}{d}", .{ if (i == 0) "" else ",", num }) catch break;
    return out.items;
}

/// Linux, with `affinity`: the CPUs a tok job is confined to, one per token, by its number.
fn pinned(ctx: *Ctx, a: std.mem.Allocator, nums: []const u32) []const u32 {
    if (builtin.os.tag != .linux or !ctx.cfg.affinity) return &.{};
    const online = sys.onlineCpus(ctx.io, a);
    if (online.len == 0 or sys.activeCpus(ctx.io) < online.len) return &.{};
    const out = a.alloc(u32, nums.len) catch return &.{};
    for (nums, out) |num, *cpu| cpu.* = online[num % online.len];
    return out;
}

/// Writes a job's record and renames it into `dir` under its name; returns the name.
fn writeJob(a: std.mem.Allocator, p: Pool, dir: Io.Dir, j: Job, rec: state.Record) []const u8 {
    var buf: [128]u8 = undefined;
    const name = a.dupe(u8, jobName(&buf, j)) catch fail("out of memory", .{});
    const tmp = a.print(".new-{d}-{d}", .{ j.holder.pid, j.holder.start }) catch fail("out of memory", .{});
    const f = p.dir.createFile(p.io, tmp, .{ .truncate = true }) catch |err| fail("tok: {t}", .{err});
    state.writeRecord(p.io, f, rec) catch {};
    f.close(p.io);
    p.dir.rename(tmp, dir, name, p.io) catch |err| fail("tok: {t}", .{err});
    return name;
}

/// Replaces a job's record in `dir`, whole, by rename.
fn rewriteJob(a: std.mem.Allocator, p: Pool, dir: Io.Dir, name: []const u8, rec: state.Record) void {
    const tmp = a.print(".{s}", .{name}) catch return;
    const f = dir.createFile(p.io, tmp, .{ .truncate = true }) catch return;
    state.writeRecord(p.io, f, rec) catch {};
    f.close(p.io);
    dir.rename(tmp, dir, name, p.io) catch {};
}

// ---- `cpuq status` ---------------------------------------------------------------------------

/// A tok job as `cpuq status` shows it.
pub const JsonTok = struct {
    ticket: u64 = 0,
    pid: i32 = 0,
    /// False once its cpuq is gone: its command, still running, keeps the tokens.
    holder_alive: bool = true,
    child: i32 = 0,
    /// Tokens it needs.
    tokens: u32 = 0,
    /// Tokens it holds: all of them while it runs; a waiter needing several may hold some.
    holding: u32 = 0,
    slots: []const u32 = &.{},
    priority: []const u8 = "",
    label: []const u8 = "",
    command: []const u8 = "",
    since: i64 = 0,
};

/// The pool in `cpuq status --json`.
pub const JsonPool = struct {
    /// The tokens there are.
    tokens: u32 = 0,
    free: u32 = 0,
    /// Held by `cpuq tok` jobs, and by `cpuq run` jobs for their grants.
    tok: u32 = 0,
    runs: u32 = 0,
    holders: []const JsonTok = &.{},
    waiters: []const JsonTok = &.{},
};

/// The pool as `cpuq status` shows it. Read without the admission lock: tok jobs take none.
pub fn view(ctx: *Ctx, st: *state.State, a: std.mem.Allocator) JsonPool {
    const p = Pool.of(st) catch return .{};
    defer p.close();
    _ = p.reap();
    const limit = limitFor(ctx);
    var out: JsonPool = .{ .tokens = limit, .free = @intCast(p.freeTokens(a, limit).len), .tok = p.liveCount(), .runs = p.count(p.runs) };
    // Tokens by holder.
    var by: std.AutoHashMapUnmanaged(i32, std.ArrayList(u32)) = .empty;
    var it = p.live.iterate();
    while (it.next(p.io) catch null) |e| {
        const t = parseTaken(e.name) orelse continue;
        const gop = by.getOrPut(a, t.holder.pid) catch continue;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(a, t.num) catch {};
    }
    out.holders = jobsIn(a, p, p.held, &by);
    out.waiters = jobsIn(a, p, p.wait, &by);
    return out;
}

fn jobsIn(a: std.mem.Allocator, p: Pool, dir: Io.Dir, by: *std.AutoHashMapUnmanaged(i32, std.ArrayList(u32))) []JsonTok {
    const Item = struct { key: Key, j: JsonTok };
    var list: std.ArrayList(Item) = .empty;
    var it = dir.iterate();
    while (it.next(p.io) catch null) |e| {
        const j = parseJob(e.name) orelse continue;
        var buf: [4096]u8 = undefined;
        const text = dir.readFile(p.io, e.name, &buf) catch continue;
        const r = state.Record.parse(a.dupe(u8, text) catch continue);
        const slots: []const u32 = if (by.get(j.holder.pid)) |l| l.items else &.{};
        list.append(a, .{ .key = j.key, .j = .{
            .ticket = j.key.ticket,
            .pid = j.holder.pid,
            .holder_alive = j.holder.alive(),
            .child = r.child,
            .tokens = j.n,
            .holding = @intCast(slots.len),
            .slots = slots,
            .priority = @tagName(@as(policy.Priority, @fromBackingInt(j.key.class))),
            .label = r.label,
            .command = r.cmd,
            .since = r.since,
        } }) catch break;
    }
    std.mem.sortUnstable(Item, list.items, {}, struct {
        fn less(_: void, x: Item, y: Item) bool {
            return x.key.less(y.key);
        }
    }.less);
    const out = a.alloc(JsonTok, list.items.len) catch return &.{};
    for (list.items, out) |item, *o| o.* = item.j;
    return out;
}

// ---- tests -----------------------------------------------------------------------------------

extern "c" fn sleep(seconds: c_uint) c_uint;

/// A pid that has just been reaped: no process has it.
fn deadPid() i32 {
    const pid = c.fork();
    if (pid == 0) c._exit(0);
    _ = sys.waitChild(pid);
    return pid;
}

fn addWaiter(p: Pool, j: Job) !void {
    var buf: [128]u8 = undefined;
    const f = try p.wait.createFile(p.io, jobName(&buf, j), .{});
    f.close(p.io);
}

test "plan: waiters go by class and ticket; a dead waiter is passed over" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const p = try Pool.openIn(io, tmp.dir);
    defer p.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const me = Holder.self();
    const dead: Holder = .{ .pid = deadPid(), .start = 1 };

    try addWaiter(p, .{ .key = .{ .class = 1, .ticket = 5 }, .n = 1, .holder = me });
    try addWaiter(p, .{ .key = .{ .class = 1, .ticket = 9 }, .n = 1, .holder = me });
    try addWaiter(p, .{ .key = .{ .class = 1, .ticket = 7 }, .n = 8, .holder = me });
    // Older than all, but gone: its ticket is skipped.
    try addWaiter(p, .{ .key = .{ .class = 1, .ticket = 2 }, .n = 32, .holder = dead });
    var pl = p.plan(a, 0, 0);
    try std.testing.expect(pl.blocker != null and !pl.blocker.?.run and pl.blocker.?.key.ticket == 7);
    try std.testing.expect(pl.first.?.key.eql(pl.blocker.?.key));
    try std.testing.expectEqual(1, pl.singles.len);
    // Ahead of the 8-token waiter, with a token free: it may take one.
    try std.testing.expect(pl.singleMay(.{ .class = 1, .ticket = 5 }, 1));
    // Behind it: not even with every token free.
    try std.testing.expect(!pl.singleMay(.{ .class = 1, .ticket = 9 }, 100));
    try std.testing.expect(pl.firstBlocker(.{ .class = 1, .ticket = 7 }));
    try std.testing.expect(!pl.runsMay());
    try std.testing.expect(!pl.newcomerMay());

    // A high-priority waiter needing several goes first, whatever its ticket.
    try addWaiter(p, .{ .key = .{ .class = 0, .ticket = 100 }, .n = 4, .holder = me });
    pl = p.plan(a, 0, 0);
    try std.testing.expect(pl.blocker.?.key.ticket == 100);
    try std.testing.expect(!pl.firstBlocker(.{ .class = 1, .ticket = 7 }));
    try std.testing.expect(!pl.singleMay(.{ .class = 1, .ticket = 5 }, 1));

    // A `cpuq run` waiter, alive while its ticket is locked, ahead of them all: runs may admit.
    const t = try p.queue.createFile(io, "0-0000000003", .{ .lock = .exclusive });
    pl = p.plan(a, 0, 0);
    try std.testing.expect(pl.blocker.?.run and pl.runsMay());
    try std.testing.expect(!pl.firstBlocker(.{ .class = 0, .ticket = 100 }));
    t.close(io);
    // Its lock gone, it is passed over.
    pl = p.plan(a, 0, 0);
    try std.testing.expect(!pl.blocker.?.run and pl.blocker.?.key.ticket == 100);

    // While a waiter holds the reserve, runs may not admit, whoever is first.
    const r = p.takeReserve().?;
    try std.testing.expect(p.takeReserve() == null);
    pl = p.plan(a, 0, 0);
    try std.testing.expect(pl.reserved and !pl.runsMay());
    r.close(io);
    try std.testing.expect(!p.reserved());
}

test "plan: one-token jobs go ahead of a run waiter within its patience, and not after" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const p = try Pool.openIn(io, tmp.dir);
    defer p.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const now = main.nowSeconds(io);
    const t = try p.queue.createFile(io, "1-0000000004", .{ .lock = .exclusive });
    defer t.close(io);
    try state.writeRecord(io, t, .{ .ticket = 4, .cores = 4, .since = now - 5 });
    try addWaiter(p, .{ .key = .{ .class = 1, .ticket = 5 }, .n = 1, .holder = Holder.self() });
    try addWaiter(p, .{ .key = .{ .class = 1, .ticket = 6 }, .n = 4, .holder = Holder.self() });
    // Waited 5 s of a patience of 30: the one-token job may go ahead, the 4-token one may not.
    var pl = p.plan(a, now, 30);
    try std.testing.expect(pl.singleMay(.{ .class = 1, .ticket = 5 }, 1));
    try std.testing.expect(!pl.firstBlocker(.{ .class = 1, .ticket = 6 }));
    try std.testing.expect(pl.runsMay());
    // Past its patience, freed tokens are kept for it.
    pl = p.plan(a, now, 3);
    try std.testing.expect(!pl.singleMay(.{ .class = 1, .ticket = 5 }, 1));
    try std.testing.expect(pl.runsMay());
}

test "plan: one-token waiters ahead of the first blocker take tokens in ticket order" {
    const pl: Plan = .{ .singles = &.{ .{ .class = 1, .ticket = 3 }, .{ .class = 1, .ticket = 5 }, .{ .class = 1, .ticket = 8 } } };
    try std.testing.expect(pl.singleMay(.{ .class = 1, .ticket = 3 }, 1));
    try std.testing.expect(!pl.singleMay(.{ .class = 1, .ticket = 8 }, 2));
    try std.testing.expect(pl.singleMay(.{ .class = 1, .ticket = 8 }, 3));
    try std.testing.expect(pl.runsMay());
}

test "take: every token goes to one taker, and back" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const p = try Pool.openIn(io, tmp.dir);
    defer p.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    p.ensureLocked(6);
    p.ensureLocked(4); // a smaller pool makes nothing and removes nothing
    try std.testing.expectEqual(6, p.made());
    var prng: std.Random.DefaultPrng = .init(1);
    // A pool of 4 out of the 6 files: numbers 4 and 5 go unused.
    const x = p.take(a, prng.random(), 4, p.live, "1-1", 3);
    const y = p.take(a, prng.random(), 4, p.live, "2-2", 3);
    try std.testing.expectEqual(3, x.len);
    try std.testing.expectEqual(1, y.len);
    for (x) |n| try std.testing.expect(n != y[0] and n < 4);
    try std.testing.expectEqual(0, p.freeTokens(a, 4).len);
    try std.testing.expectEqual(4, p.liveCount());
    p.give(p.live, "1-1", x);
    p.give(p.live, "2-2", y);
    try std.testing.expectEqual(4, p.freeTokens(a, 4).len);
    try std.testing.expectEqual(6, p.freeTokens(a, 6).len);
}

test "reap: a dead holder's tokens go back, and a reused pid's; a live holder's stay" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const p = try Pool.openIn(io, tmp.dir);
    defer p.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    p.ensureLocked(8);
    var prng: std.Random.DefaultPrng = .init(2);
    const me = Holder.self();
    const dead = deadPid();
    const live_suffix = try a.print("{d}-{d}", .{ me.pid, me.start });
    const dead_suffix = try a.print("{d}-{d}", .{ dead, me.start });
    // This process's pid, but a start time that isn't its own: a pid the kernel reused.
    const reused_suffix = try a.print("{d}-{d}", .{ me.pid, me.start + 1 });
    _ = p.take(a, prng.random(), 8, p.live, live_suffix, 2);
    _ = p.take(a, prng.random(), 8, p.live, dead_suffix, 2);
    _ = p.take(a, prng.random(), 8, p.live, reused_suffix, 1);
    // A run's tokens: kept while its lease is held, though its cpuq is gone.
    const lease = try p.leases.createFile(io, "0000000042", .{ .lock = .exclusive });
    _ = p.take(a, prng.random(), 8, p.runs, try a.print("{d}-1-0000000042", .{dead}), 1);
    _ = p.take(a, prng.random(), 8, p.runs, try a.print("{d}-1-0000000043", .{dead}), 1);
    try addWaiter(p, .{ .key = .{ .class = 1, .ticket = 1 }, .n = 1, .holder = .{ .pid = dead, .start = 1 } });
    try addWaiter(p, .{ .key = .{ .class = 1, .ticket = 2 }, .n = 1, .holder = me });
    try std.testing.expectEqual(1, p.freeTokens(a, 8).len);

    try std.testing.expectEqual(4, p.reap());
    try std.testing.expectEqual(5, p.freeTokens(a, 8).len);
    try std.testing.expectEqual(2, p.liveCount());
    try std.testing.expectEqual(1, p.count(p.runs));
    try std.testing.expectEqual(1, p.count(p.wait));
    lease.close(io);
    try std.testing.expectEqual(1, p.reap());
    try std.testing.expectEqual(0, p.count(p.runs));
}

test "names" {
    var buf: [128]u8 = undefined;
    const j: Job = .{ .key = .{ .class = 2, .ticket = 77 }, .n = 32, .holder = .{ .pid = 123, .start = 456 } };
    const name = jobName(&buf, j);
    try std.testing.expectEqualStrings("2-0000000077-32-123-456", name);
    const back = parseJob(name).?;
    try std.testing.expect(back.key.eql(j.key) and back.n == 32 and back.holder.pid == 123 and back.holder.start == 456);
    const t = parseTaken("0007-123-456-0000000042.x").?;
    try std.testing.expect(t.num == 7 and t.holder.pid == 123 and t.holder.start == 456);
    try std.testing.expectEqualStrings("0000000042.x", t.lease);
    try std.testing.expectEqualStrings("", parseTaken("0007-123-456").?.lease);
    try std.testing.expect(parseJob("1-2-3") == null);
}

test "reap: a killed cpuq's tokens stay while its command's group runs" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const p = try Pool.openIn(io, tmp.dir);
    defer p.close();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    p.ensureLocked(4);
    // The command: a process group of its own that outlives its cpuq.
    const cmd = c.fork();
    if (cmd == 0) {
        _ = c.setpgid(0, 0);
        while (true) _ = sleep(1000);
    }
    _ = c.setpgid(cmd, cmd);
    const gone: Holder = .{ .pid = deadPid(), .start = 5 };
    var prng: std.Random.DefaultPrng = .init(3);
    _ = p.take(a, prng.random(), 4, p.live, try a.print("{d}-{d}", .{ gone.pid, gone.start }), 2);
    var buf: [128]u8 = undefined;
    const name = jobName(&buf, .{ .key = .{ .class = 1, .ticket = 9 }, .n = 2, .holder = gone });
    const f = try p.held.createFile(io, name, .{});
    try state.writeRecord(io, f, .{ .ticket = 9, .pid = gone.pid, .child = cmd, .cores = 2 });
    f.close(io);
    try std.testing.expectEqual(0, p.reap());
    try std.testing.expectEqual(2, p.liveCount());
    try std.testing.expectEqual(1, p.count(p.held));
    _ = c.kill(-cmd, .KILL);
    var tries: u32 = 0;
    while (sys.groupAlive(cmd) and tries < 100) : (tries += 1) {
        if (sys.reapChild(cmd) != null) break;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    try std.testing.expectEqual(2, p.reap());
    try std.testing.expectEqual(0, p.count(p.held));
}

test "a killed process its parent has not reaped yet is not alive" {
    const pid = c.fork();
    if (pid == 0) {
        while (true) _ = sleep(1000);
    }
    const h: Holder = .{ .pid = pid, .start = sys.procStart(pid).? };
    try std.testing.expect(h.alive());
    _ = c.kill(pid, .KILL);
    // A zombie until waited for: dead to the pool already.
    var tries: u32 = 0;
    while (h.alive() and tries < 200) : (tries += 1) std.testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    try std.testing.expect(!h.alive());
    _ = sys.waitChild(pid);
}
