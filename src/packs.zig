//! Packs: tool versions kept on each host, as mise keeps them, for the jobs that ask for them.
//!
//!     ~/cpuq/packs/zig/0.17.0/          zig's own release, checked against its sha256
//!     ~/cpuq/packs/nexus/c28bef1a9d3e/  built from that commit
//!     ~/cpuq/packs/nexus/latest -> c28bef1a9d3e
//!     ~/cpuq/packs/rig/0.2.9/           built from the tag v0.2.9
//!     ~/cpuq/packs/rig/stable -> 0.2.9
//!
//! A spec asks for packs by version: `"packs": {"zig": "0.17.0", "rig": "stable"}`. The
//! submitting machine resolves each to an exact version (`latest`: the default branch's head;
//! `stable`: the newest release tag; `0.2.9`: that tag; a hash: that commit), and its recipe
//! (~/.config/cpuq/packs.json, beside the config) says how to build it and what it needs. A
//! version is installed once, by the first job that needs it, inside that job's grant and under
//! a lock, and never changes after: `latest` and `stable` are links to what they last were.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const Map = std.json.ArrayHashMap([]const u8);

/// How to make a pack: from a git repo (`git`, cloned here at `local`), built by `build` into
/// `bin`, with the packs its build needs. zig needs no recipe: its releases are downloaded.
pub const Recipe = struct {
    git: ?[]const u8 = null,
    local: ?[]const u8 = null,
    build: ?[]const u8 = null,
    bin: []const u8 = "",
    packs: ?Map = null,
};

/// A pack as a job uses it, resolved to an exact version.
pub const Pack = struct {
    name: []const u8,
    /// Its directory under ~/cpuq/packs/NAME: a version (0.2.9) or a commit's first 12 digits.
    version: []const u8,
    /// `latest` or `stable` when it was asked for so: that link is set to it once installed.
    alias: []const u8 = "",
    /// "zig" (a release, downloaded) or "git" (built from source shipped by the submitter).
    kind: []const u8,
    build: []const u8 = "",
    /// Its binary, relative to its directory.
    bin: []const u8,
    /// The submitting machine's checkout and the commit, for shipping its source.
    local: []const u8 = "",
    commit: []const u8 = "",
};

pub const Resolved = struct { packs: []const Pack = &.{}, err: ?[]const u8 = null };

/// The recipes: packs.json beside the config file.
pub fn recipesPath(a: std.mem.Allocator, env: *const std.process.Environ.Map) []const u8 {
    if (env.get("CPUQ_CONFIG")) |c| return a.print("{s}/packs.json", .{std.fs.path.dirname(c) orelse "."}) catch "";
    return a.print("{s}/.config/cpuq/packs.json", .{env.get("HOME") orelse "."}) catch "";
}

fn loadRecipes(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map) union(enum) { ok: std.json.ArrayHashMap(Recipe), err: []const u8 } {
    const path = recipesPath(a, env);
    const text = Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch return .{ .ok = .{} };
    const r = std.json.parseFromSliceLeaky(std.json.ArrayHashMap(Recipe), a, text, .{ .ignore_unknown_fields = false, .allocate = .alloc_always }) catch |e|
        return .{ .err = a.print("{s}: {t} (each pack: git, local, build, bin, packs)", .{ path, e }) catch "" };
    return .{ .ok = r };
}

/// The packs a job asked for, and the ones their builds need, each resolved to an exact version,
/// in the order they're installed (what a build needs before it). One version of each: the
/// job's own request wins over a recipe's.
pub fn resolve(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, requested: Map) Resolved {
    const recipes = switch (loadRecipes(a, io, env)) {
        .ok => |r| r,
        .err => |e| return .{ .err = e },
    };
    var chosen: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    var it = requested.map.iterator();
    while (it.next()) |e| chosen.put(a, e.key_ptr.*, e.value_ptr.*) catch {};
    var i: usize = 0;
    while (i < chosen.count()) : (i += 1) {
        const name = chosen.keys()[i];
        const recipe = recipes.map.get(name) orelse continue;
        if (recipe.packs) |needs| {
            var n = needs.map.iterator();
            while (n.next()) |d| if (!chosen.contains(d.key_ptr.*)) chosen.put(a, d.key_ptr.*, d.value_ptr.*) catch {};
        }
    }
    // What a build needs comes first.
    var order: std.ArrayList([]const u8) = .empty;
    var state: std.StringHashMapUnmanaged(u2) = .empty;
    for (chosen.keys()) |name| if (visit(a, name, &recipes, &chosen, &state, &order)) |e| return .{ .err = e };
    var out: std.ArrayList(Pack) = .empty;
    for (order.items) |name| {
        switch (resolveOne(a, io, env, name, chosen.get(name).?, recipes.map.get(name))) {
            .ok => |p| out.append(a, p) catch {},
            .err => |e| return .{ .err = e },
        }
    }
    return .{ .packs = out.items };
}

fn visit(a: std.mem.Allocator, name: []const u8, recipes: *const std.json.ArrayHashMap(Recipe), chosen: *const std.StringArrayHashMapUnmanaged([]const u8), state: *std.StringHashMapUnmanaged(u2), order: *std.ArrayList([]const u8)) ?[]const u8 {
    const s = state.get(name) orelse 0;
    if (s == 2) return null;
    if (s == 1) return a.print("packs: {s} needs itself (a loop in packs.json)", .{name}) catch "";
    state.put(a, name, 1) catch {};
    if (recipes.map.get(name)) |r| if (r.packs) |needs| {
        var n = needs.map.iterator();
        while (n.next()) |d| if (chosen.contains(d.key_ptr.*)) if (visit(a, d.key_ptr.*, recipes, chosen, state, order)) |e| return e;
    };
    state.put(a, name, 2) catch {};
    order.append(a, name) catch {};
    return null;
}

const One = union(enum) { ok: Pack, err: []const u8 };

/// Packs that need no recipe: their releases, downloaded.
const builtins = [_]struct { name: []const u8, bin: []const u8, example: []const u8 }{
    .{ .name = "zig", .bin = "zig", .example = "0.17.0" },
    .{ .name = "go", .bin = "bin/go", .example = "1.27.1" },
    .{ .name = "bun", .bin = "bun", .example = "1.4.3" },
};

fn resolveOne(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, name: []const u8, ref: []const u8, recipe: ?Recipe) One {
    if (!validName(name)) return .{ .err = a.print("packs: a pack's name is lowercase letters, digits, - and _, not '{s}'", .{name}) catch "" };
    const r = recipe orelse {
        // Released tools cpuq downloads itself, each checked against its published sha256.
        for (builtins) |b| if (std.mem.eql(u8, name, b.name)) {
            if (!isVersion(ref)) return .{ .err = a.print("packs: {s} is asked for by its version ({s}), not '{s}'", .{ name, b.example, ref }) catch "" };
            return .{ .ok = .{ .name = b.name, .version = ref, .kind = b.name, .bin = b.bin } };
        };
        return .{ .err = a.print("packs: no recipe for {s} in {s}", .{ name, recipesPath(a, env) }) catch "" };
    };
    const url = r.git orelse return .{ .err = a.print("packs: {s}'s recipe has no \"git\"", .{name}) catch "" };
    const local = expandHome(a, env, r.local orelse return .{ .err = a.print("packs: {s}'s recipe has no \"local\" (its checkout here)", .{name}) catch "" });
    const build = r.build orelse return .{ .err = a.print("packs: {s}'s recipe has no \"build\"", .{name}) catch "" };
    if (!inside(r.bin)) return .{ .err = a.print("packs: {s}'s \"bin\" is relative, without .., not '{s}'", .{ name, r.bin }) catch "" };
    var p: Pack = .{ .name = name, .version = "", .kind = "git", .build = build, .bin = r.bin, .local = local };
    if (std.mem.eql(u8, ref, "latest")) {
        const sha = headOf(a, io, url) orelse return .{ .err = a.print("packs: {s} didn't answer (git ls-remote)", .{url}) catch "" };
        p.commit = sha;
        p.version = sha[0..12];
        p.alias = "latest";
    } else if (std.mem.eql(u8, ref, "stable")) {
        const t = newestTag(a, io, url) orelse return .{ .err = a.print("packs: {s} has no release tags (vX.Y.Z) at {s}", .{ name, url }) catch "" };
        p.commit = t.sha;
        p.version = t.version;
        p.alias = "stable";
    } else if (isVersion(ref)) {
        p.commit = tagOf(a, io, url, ref) orelse return .{ .err = a.print("packs: {s} has no tag v{s} at {s}", .{ name, ref, url }) catch "" };
        p.version = ref;
    } else if (isHex(ref)) {
        const got = git(a, io, &.{ "-C", local, "rev-parse", "--verify", "--quiet", a.print("{s}^{{commit}}", .{ref}) catch "" }) orelse
            return .{ .err = a.print("packs: {s} {s}: no such commit in {s}", .{ name, ref, local }) catch "" };
        p.commit = got;
        p.version = got[0..12];
    } else return .{ .err = a.print("packs: {s} is asked for as latest, stable, a version (0.2.9) or a commit, not '{s}'", .{ name, ref }) catch "" };
    // Its source ships from the checkout here: it must hold the commit.
    if (!hasCommit(a, io, local, p.commit)) {
        _ = git(a, io, &.{ "-C", local, "fetch", "--quiet", "--tags", "origin" });
        if (!hasCommit(a, io, local, p.commit)) return .{ .err = a.print("packs: {s} {s} ({s}) isn't in {s}, even after a fetch", .{ name, ref, p.commit[0..12], local }) catch "" };
    }
    return .{ .ok = p };
}

fn git(a: std.mem.Allocator, io: Io, args: []const []const u8) ?[]const u8 {
    const argv = std.mem.concat(a, []const u8, &.{ &.{"git"}, args }) catch return null;
    const r = std.process.run(a, io, .{ .argv = argv }) catch return null;
    if (!r.term.success()) return null;
    const out = std.mem.trim(u8, r.stdout, " \n");
    return if (out.len == 0) null else out;
}

fn hasCommit(a: std.mem.Allocator, io: Io, local: []const u8, sha: []const u8) bool {
    return git(a, io, &.{ "-C", local, "cat-file", "-t", sha }) != null;
}

/// The default branch's head at `url`.
fn headOf(a: std.mem.Allocator, io: Io, url: []const u8) ?[]const u8 {
    const out = git(a, io, &.{ "ls-remote", url, "HEAD" }) orelse return null;
    const sha = std.mem.sliceTo(out, '\t');
    return if (sha.len == 40) sha else null;
}

/// The commit a tag names (vX.Y.Z, else X.Y.Z), peeled.
fn tagOf(a: std.mem.Allocator, io: Io, url: []const u8, version: []const u8) ?[]const u8 {
    for ([_][]const u8{ "v", "" }) |prefix| {
        const out = git(a, io, &.{ "ls-remote", "--tags", url, a.print("refs/tags/{s}{s}", .{ prefix, version }) catch continue, a.print("refs/tags/{s}{s}^{{}}", .{ prefix, version }) catch continue }) orelse continue;
        var sha: ?[]const u8 = null;
        var lines = std.mem.tokenizeScalar(u8, out, '\n');
        while (lines.next()) |line| {
            const s = std.mem.sliceTo(line, '\t');
            if (s.len != 40) continue;
            // The peeled line (^{}) is the commit; the plain one is an annotated tag's object.
            if (std.mem.endsWith(u8, line, "^{}") or sha == null) sha = s;
        }
        if (sha) |s| return s;
    }
    return null;
}

/// The newest release tag at `url` (vX.Y.Z or X.Y.Z, by number) and its commit.
fn newestTag(a: std.mem.Allocator, io: Io, url: []const u8) ?struct { version: []const u8, sha: []const u8 } {
    const out = git(a, io, &.{ "ls-remote", "--tags", url }) orelse return null;
    var best: ?[3]u32 = null;
    var best_version: []const u8 = "";
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.findScalar(u8, line, '\t') orelse continue;
        var tag = line[tab + 1 ..];
        if (!std.mem.startsWith(u8, tag, "refs/tags/")) continue;
        tag = tag["refs/tags/".len..];
        if (std.mem.endsWith(u8, tag, "^{}")) tag = tag[0 .. tag.len - 3];
        const v = if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
        const n = triple(v) orelse continue;
        if (best == null or later(n, best.?)) {
            best = n;
            best_version = v;
        }
    }
    if (best == null) return null;
    const sha = tagOf(a, io, url, best_version) orelse return null;
    return .{ .version = best_version, .sha = sha };
}

fn triple(v: []const u8) ?[3]u32 {
    var out: [3]u32 = undefined;
    var parts = std.mem.splitScalar(u8, v, '.');
    for (&out) |*x| x.* = std.fmt.parseInt(u32, parts.next() orelse return null, 10) catch return null;
    return if (parts.next() == null) out else null;
}

fn later(x: [3]u32, y: [3]u32) bool {
    for (x, y) |p, q| if (p != q) return p > q;
    return false;
}

/// A version to name a directory: digits first, then digits, letters, `.`, `-` and `+`, with a dot.
fn isVersion(v: []const u8) bool {
    if (v.len == 0 or v.len > 64 or !std.ascii.isDigit(v[0]) or std.mem.findScalar(u8, v, '.') == null) return false;
    for (v) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '-' or ch == '+')) return false;
    return true;
}

fn isHex(v: []const u8) bool {
    if (v.len < 7 or v.len > 40) return false;
    for (v) |ch| if (!std.ascii.isHex(ch) or std.ascii.isUpper(ch)) return false;
    return true;
}

fn inside(p: []const u8) bool {
    if (p.len == 0 or p[0] == '/') return false;
    var parts = std.mem.splitScalar(u8, p, '/');
    while (parts.next()) |x| if (std.mem.eql(u8, x, "..")) return false;
    return true;
}

fn expandHome(a: std.mem.Allocator, env: *const std.process.Environ.Map, p: []const u8) []const u8 {
    if (std.mem.startsWith(u8, p, "~/")) return a.print("{s}/{s}", .{ env.get("HOME") orelse "", p[2..] }) catch p;
    return p;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |ch| if (!(std.ascii.isLower(ch) or std.ascii.isDigit(ch) or ch == '-' or ch == '_')) return false;
    return true;
}

/// A pack's variable: its name in capitals, - as _ (`rig` → RIG).
pub fn varName(a: std.mem.Allocator, name: []const u8) []const u8 {
    const out = a.dupe(u8, name) catch return name;
    for (out) |*ch| ch.* = if (ch.* == '-') '_' else std.ascii.toUpper(ch.*);
    return out;
}

// --- On the host: the store, and installing into it -------------------------------------------

/// The store: ~/cpuq/packs.
pub fn storeRoot(a: std.mem.Allocator, env: *const std.process.Environ.Map) []const u8 {
    return a.print("{s}/{s}", .{ env.get("HOME") orelse ".", @import("layout.zig").packs }) catch "";
}

/// Ships a git pack's source (`git archive` of its commit, from its checkout here) to the store on
/// `host` (null: this machine), unless that version is there already. The error text, or null.
pub fn ship(a: std.mem.Allocator, io: Io, host: ?[]const u8, p: Pack) ?[]const u8 {
    if (!std.mem.eql(u8, p.kind, "git")) return null;
    if (!validName(p.name) or !(isVersion(p.version) or isHex(p.version))) return "packs: a bad pack name or version";
    // Unpacked beside it, then renamed into place: a version there is always whole.
    const script = a.print(
        \\d="$HOME/cpuq/packs/{s}/{s}"; [ -e "$d" ] && exit 0
        \\mkdir -p "$HOME/cpuq/packs/{s}" && t=$(mktemp -d "$HOME/cpuq/packs/{s}/.{s}.XXXXXX") || exit 1
        \\tar -x -C "$t" && {{ [ -e "$d" ] || mv "$t" "$d"; }}; s=$?; rm -rf "$t"; exit $s
    , .{ p.name, p.version, p.name, p.name, p.version }) catch return "out of memory";
    const r = if (host) |h|
        std.process.run(a, io, .{ .argv = &.{ "/bin/sh", "-c", "git -C \"$1\" archive --format=tar \"$2\" | ssh -o BatchMode=yes -o ConnectTimeout=10 \"$3\" \"$4\"", "sh", p.local, p.commit, h, script } })
    else
        std.process.run(a, io, .{ .argv = &.{ "/bin/sh", "-c", "git -C \"$1\" archive --format=tar \"$2\" | /bin/sh -c \"$3\"", "sh", p.local, p.commit, script } });
    const ran = r catch return "packs: couldn't run git archive";
    if (ran.term.success()) return null;
    return a.print("packs: {s} {s} didn't reach {s}: {s}", .{ p.name, p.version, host orelse "here", std.mem.trim(u8, ran.stderr, " \n") }) catch "packs: shipping failed";
}

/// `cpuq _pack NAME VERSION ALIAS KIND BIN BUILD`: a submitted job's first steps, one per pack,
/// inside its grant. Installs that version in the store unless it's there: zig's release
/// downloaded and checked, or a git pack built from the source its submitter shipped. One
/// install at a time per version; a job that finds one going waits for it.
pub fn install(a: std.mem.Allocator, io: Io, env: *const std.process.Environ.Map, args: []const [:0]const u8) u8 {
    if (args.len != 6) return 2;
    const name: []const u8 = args[0];
    const version: []const u8 = args[1];
    const alias: []const u8 = args[2];
    const kind: []const u8 = args[3];
    const bin: []const u8 = args[4];
    if (!validName(name) or !(isVersion(version) or isHex(version)) or !inside(bin)) return 2;
    const root = a.print("{s}/{s}", .{ storeRoot(a, env), name }) catch return 125;
    Io.Dir.cwd().createDirPath(io, root) catch {};
    const lock = Io.Dir.cwd().createFile(io, a.print("{s}/.{s}.lock", .{ root, version }) catch return 125, .{ .lock = .exclusive, .truncate = false }) catch {
        std.debug.print("cpuq: pack {s} {s}: its lock couldn't be taken\n", .{ name, version });
        return 125;
    };
    defer lock.close(io);
    const dir = a.print("{s}/{s}", .{ root, version }) catch return 125;
    const binary = a.print("{s}/{s}", .{ dir, bin }) catch return 125;
    const marker = a.print("{s}/.cpuq-installed", .{dir}) catch return 125;
    const there = if (Io.Dir.cwd().access(io, marker, .{})) |_| (if (Io.Dir.cwd().access(io, binary, .{})) |_| true else |_| false) else |_| false;
    if (!there) {
        const download: ?*const fn (std.mem.Allocator, Io, []const u8, []const u8) ?[]const u8 =
            if (std.mem.eql(u8, kind, "zig")) &installZig else if (std.mem.eql(u8, kind, "go")) &installGo else if (std.mem.eql(u8, kind, "bun")) &installBun else null;
        if (download) |get| {
            std.debug.print("cpuq: pack {s} {s}: downloading\n", .{ name, version });
            if (get(a, io, root, version)) |e| {
                std.debug.print("cpuq: pack {s} {s}: {s}\n", .{ name, version, e });
                return 1;
            }
        } else {
            Io.Dir.cwd().access(io, dir, .{}) catch {
                std.debug.print("cpuq: pack {s} {s}: its source never arrived\n", .{ name, version });
                return 125;
            };
            std.debug.print("cpuq: pack {s} {s}: building\n", .{ name, version });
            var child = std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", args[5] }, .cwd = .{ .path = dir }, .stdin = .ignore, .stdout = .inherit, .stderr = .inherit }) catch return 125;
            const term = child.wait(io) catch return 125;
            const code: u8 = switch (term) {
                .exited => |x| x,
                else => 1,
            };
            if (code != 0) {
                std.debug.print("cpuq: pack {s} {s}: its build failed (exit {d})\n", .{ name, version, code });
                return code;
            }
        }
        Io.Dir.cwd().access(io, binary, .{}) catch {
            std.debug.print("cpuq: pack {s} {s}: no {s} after installing\n", .{ name, version, bin });
            return 1;
        };
        const f = Io.Dir.cwd().createFile(io, marker, .{}) catch return 125;
        f.close(io);
    }
    if (alias.len != 0 and validName(alias)) setAlias(a, io, root, alias, version);
    // Used now: `cpuq clean` keeps a version jobs still use.
    if (Io.Dir.cwd().createFile(io, a.print("{s}/.cpuq-used", .{dir}) catch return 0, .{})) |f| f.close(io) else |_| {}
    return 0;
}

/// NAME/ALIAS -> VERSION, replaced whole.
fn setAlias(a: std.mem.Allocator, io: Io, root: []const u8, alias: []const u8, version: []const u8) void {
    const tmp = a.print("{s}/.{s}.link", .{ root, alias }) catch return;
    Io.Dir.cwd().deleteFile(io, tmp) catch {};
    Io.Dir.cwd().symLink(io, version, tmp, .{}) catch return;
    const cwd = Io.Dir.cwd();
    cwd.rename(tmp, cwd, a.print("{s}/{s}", .{ root, alias }) catch return, io) catch {};
}

/// zig's release VERSION for this machine, from ziglang.org's index.
fn installZig(a: std.mem.Allocator, io: Io, root: []const u8, version: []const u8) ?[]const u8 {
    const index = fetch(a, io, "https://ziglang.org/download/index.json") orelse return "ziglang.org's index couldn't be fetched";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, index, .{}) catch return "ziglang.org's index isn't JSON";
    const platform = a.print("{t}-{s}", .{ builtin.cpu.arch, if (builtin.os.tag == .macos) "macos" else @tagName(builtin.os.tag) }) catch return "out of memory";
    const release = (if (parsed == .object) parsed.object.get(version) else null) orelse return "no such release on ziglang.org";
    const build = (if (release == .object) release.object.get(platform) else null) orelse return a.print("no build for {s}", .{platform}) catch "no build for this machine";
    if (build != .object) return "a strange index entry";
    const url = (build.object.get("tarball") orelse return "no tarball").string;
    const want = (build.object.get("shasum") orelse return "no shasum").string;
    return unpack(a, io, root, version, url, want, .tar_xz);
}

/// Go's release VERSION for this machine, from go.dev's list.
fn installGo(a: std.mem.Allocator, io: Io, root: []const u8, version: []const u8) ?[]const u8 {
    const list = fetch(a, io, "https://go.dev/dl/?mode=json&include=all") orelse return "go.dev's list couldn't be fetched";
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, list, .{}) catch return "go.dev's list isn't JSON";
    if (parsed != .array) return "go.dev's list isn't a list";
    const os = if (builtin.os.tag == .macos) "darwin" else @tagName(builtin.os.tag);
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "amd64",
        .aarch64 => "arm64",
        else => @tagName(builtin.cpu.arch),
    };
    const want_version = a.print("go{s}", .{version}) catch return "out of memory";
    for (parsed.array.items) |rel| {
        if (rel != .object) continue;
        const v = rel.object.get("version") orelse continue;
        if (v != .string or !std.mem.eql(u8, v.string, want_version)) continue;
        const files = rel.object.get("files") orelse continue;
        if (files != .array) continue;
        for (files.array.items) |f| {
            if (f != .object) continue;
            const fo = f.object;
            if (!eqlField(fo, "os", os) or !eqlField(fo, "arch", arch) or !eqlField(fo, "kind", "archive")) continue;
            const filename = (fo.get("filename") orelse continue).string;
            const sum = (fo.get("sha256") orelse continue).string;
            return unpack(a, io, root, version, a.print("https://go.dev/dl/{s}", .{filename}) catch return "out of memory", sum, .tar_gz);
        }
        return a.print("no Go {s} archive for {s}-{s}", .{ version, os, arch }) catch "no archive for this machine";
    }
    return "no such release on go.dev";
}

/// Bun's release VERSION for this machine, from its GitHub release and that release's SHASUMS256.txt.
fn installBun(a: std.mem.Allocator, io: Io, root: []const u8, version: []const u8) ?[]const u8 {
    const os = if (builtin.os.tag == .macos) "darwin" else @tagName(builtin.os.tag);
    const arch = switch (builtin.cpu.arch) {
        .x86_64 => "x64",
        .aarch64 => "aarch64",
        else => @tagName(builtin.cpu.arch),
    };
    const zip = a.print("bun-{s}-{s}.zip", .{ os, arch }) catch return "out of memory";
    const base = a.print("https://github.com/oven-sh/bun/releases/download/bun-v{s}", .{version}) catch return "out of memory";
    const sums = fetch(a, io, a.print("{s}/SHASUMS256.txt", .{base}) catch return "out of memory") orelse return "no such release on GitHub (SHASUMS256.txt)";
    var lines = std.mem.tokenizeScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " \t*");
        const sum = parts.next() orelse continue;
        const file = parts.next() orelse continue;
        if (!std.mem.eql(u8, file, zip)) continue;
        return unpack(a, io, root, version, a.print("{s}/{s}", .{ base, zip }) catch return "out of memory", sum, .zip);
    }
    return a.print("no {s} in the release", .{zip}) catch "no build for this machine";
}

fn eqlField(o: std.json.ObjectMap, key: []const u8, want: []const u8) bool {
    const v = o.get(key) orelse return false;
    return v == .string and std.mem.eql(u8, v.string, want);
}

fn fetch(a: std.mem.Allocator, io: Io, url: []const u8) ?[]const u8 {
    const r = std.process.run(a, io, .{ .argv = &.{ "curl", "-fsSL", "--max-time", "60", url } }) catch return null;
    return if (r.term.success()) r.stdout else null;
}

const Archive = enum { tar_xz, tar_gz, zip };

/// Downloads `url` beside the store, checks its sha256 against `want`, unpacks it (its one top
/// directory dropped) and renames it into ROOT/VERSION.
fn unpack(a: std.mem.Allocator, io: Io, root: []const u8, version: []const u8, url: []const u8, want: []const u8, kind: Archive) ?[]const u8 {
    const file = a.print("{s}/.{s}.download", .{ root, version }) catch return "out of memory";
    defer Io.Dir.cwd().deleteFile(io, file) catch {};
    const got = std.process.run(a, io, .{ .argv = &.{ "curl", "-fsSL", "--max-time", "900", "-o", file, url } }) catch return "curl couldn't run";
    if (!got.term.success()) return a.print("{s} couldn't be downloaded", .{url}) catch "the download failed";
    const sum = sha256File(a, io, file) orelse return "the download couldn't be read";
    if (!std.ascii.eqlIgnoreCase(sum, want)) return a.print("its sha256 is {s}, the release says {s}: not installed", .{ sum, want }) catch "a bad sha256";
    const tmp = a.print("{s}/.{s}.unpack", .{ root, version }) catch return "out of memory";
    Io.Dir.cwd().deleteTree(io, tmp) catch {};
    Io.Dir.cwd().createDirPath(io, tmp) catch return "couldn't make a directory";
    defer Io.Dir.cwd().deleteTree(io, tmp) catch {};
    const x = switch (kind) {
        .tar_xz => std.process.run(a, io, .{ .argv = &.{ "tar", "-xJf", file, "-C", tmp } }),
        .tar_gz => std.process.run(a, io, .{ .argv = &.{ "tar", "-xzf", file, "-C", tmp } }),
        // No unzip on a minimal Linux; python3 is everywhere cpuq runs jobs. Modes are lost: the
        // files are made executable below.
        .zip => std.process.run(a, io, .{ .argv = &.{ "python3", "-m", "zipfile", "-e", file, tmp } }),
    } catch return "couldn't unpack it";
    if (!x.term.success()) return "the download couldn't be unpacked";
    // Its one top directory (zig-x86_64-linux-0.17.0/, go/, bun-linux-x64/) becomes VERSION.
    var d = Io.Dir.cwd().openDir(io, tmp, .{ .iterate = true }) catch return "couldn't read what was unpacked";
    defer d.close(io);
    var it = d.iterate();
    const top = (it.next(io) catch null) orelse return "the download was empty";
    if (top.kind != .directory or (it.next(io) catch null) != null) return "the download isn't one directory";
    const from = a.print("{s}/{s}", .{ tmp, top.name }) catch return "out of memory";
    if (kind == .zip) _ = std.process.run(a, io, .{ .argv = &.{ "chmod", "-R", "a+rX,u+x", from } }) catch {};
    const dir = a.print("{s}/{s}", .{ root, version }) catch return "out of memory";
    Io.Dir.cwd().deleteTree(io, dir) catch {};
    const cwd = Io.Dir.cwd();
    cwd.rename(from, cwd, dir, io) catch return "couldn't move it into place";
    return null;
}

fn sha256File(a: std.mem.Allocator, io: Io, path: []const u8) ?[]const u8 {
    const f = Io.Dir.cwd().openFile(io, path, .{}) catch return null;
    defer f.close(io);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [1 << 16]u8 = undefined;
    var off: u64 = 0;
    while (true) {
        const n = f.readPositionalAll(io, &buf, off) catch return null;
        if (n == 0) break;
        h.update(buf[0..n]);
        off += n;
        if (n < buf.len) break;
    }
    var out: [32]u8 = undefined;
    h.final(&out);
    return std.fmt.allocPrint(a, "{x}", .{&out}) catch null;
}
