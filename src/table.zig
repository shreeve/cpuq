//! A table as cpuq prints it on a terminal: a rounded box with a tab on top
//! for its title, bold headings, color on what matters, and notes under it,
//! dim. Widths are measured in terminal columns (one per code point; cpuq's
//! labels and commands are text), and the one flexible column is cut with an
//! ellipsis to fit the terminal. The look matches the `shotts` CLI's.
const std = @import("std");
const Io = std.Io;

pub const Align = enum { left, right };
pub const Tint = enum {
    none,
    bold,
    dim,
    /// cyan: names worth reading first
    accent,
    /// green: a good state
    good,
    /// yellow: a state to watch
    warn,
    /// red: a state that stops work
    bad,

    fn code(t: Tint) []const u8 {
        return switch (t) {
            .none => "",
            .bold => "1",
            .dim => "2",
            .accent => "36",
            .good => "32",
            .warn => "33",
            .bad => "31",
        };
    }
};

pub const Column = struct {
    head: []const u8,
    alignment: Align = .left,
    tint: Tint = .none,
    /// Cut to fit the terminal; at most one column should be.
    flexible: bool = false,
};

pub const Cell = struct {
    text: []const u8,
    /// Overrides the column's tint.
    tint: ?Tint = null,
};

pub const Table = struct {
    title: ?[]const u8 = null,
    columns: []const Column,
    rows: []const []const Cell,
    notes: []const []const u8 = &.{},

    /// Writes the box, with ANSI color if `color`, fitting `width` columns
    /// when given.
    pub fn boxed(t: Table, a: std.mem.Allocator, w: *Io.Writer, width: ?usize, color: bool) Io.Writer.Error!void {
        const n = t.columns.len;
        const widths = a.alloc(usize, n) catch return;
        for (t.columns, 0..) |col, i| {
            widths[i] = cols(col.head);
            for (t.rows) |r| widths[i] = @max(widths[i], cols(r[i].text));
        }
        // Each column is "│ cell " wide, and one "│" closes the row.
        if (width) |tw| {
            const total = sum(widths) + 3 * n + 1;
            for (t.columns, 0..) |col, i| if (col.flexible and total > tw) {
                const over = total - tw;
                widths[i] = @max(widths[i] -| over, @min(widths[i], 8));
            };
        }
        var tab: ?[]const u8 = null;
        if (t.title) |title| {
            tab = std.mem.concat(a, u8, &.{ " ", title, " " }) catch null;
            if (tab) |tb| {
                // The table is at least as wide as its tab.
                const need = cols(tb) + 2;
                const have = sum(widths) + 3 * n + 1;
                if (need > have) widths[n - 1] += need - have;
            }
        }
        // Column stops: where each "│" between cells falls.
        const stops = a.alloc(usize, n + 1) catch return;
        stops[0] = 0;
        for (widths, 0..) |cw, i| stops[i + 1] = stops[i] + cw + 3;
        const right = stops[n];

        if (tab) |tb| {
            const edge = cols(tb) + 1;
            try w.writeAll("╭");
            try repeat(w, "─", edge - 1);
            try w.writeAll("╮\n│");
            try paint(w, tb, .bold, color);
            try w.writeAll("│\n");
            try rule(w, stops, right, "├", "┬", "╮", edge);
        } else {
            try rule(w, stops, right, "╭", "┬", "╮", null);
        }
        try row(w, t.columns, widths, null, true, color);
        for (t.rows) |r| try row(w, t.columns, widths, r, false, color);
        try rule(w, stops, right, "╰", "┴", "╯", null);
        if (t.notes.len != 0) {
            try w.writeAll("\n");
            for (t.notes) |note| {
                try w.writeAll("  ");
                try paint(w, note, .dim, color);
                try w.writeAll("\n");
            }
        }
    }
};

fn sum(xs: []const usize) usize {
    var s: usize = 0;
    for (xs) |x| s += x;
    return s;
}

/// Terminal columns `text` takes: one per code point.
pub fn cols(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

fn repeat(w: *Io.Writer, s: []const u8, n: usize) Io.Writer.Error!void {
    for (0..n) |_| try w.writeAll(s);
}

fn paint(w: *Io.Writer, text: []const u8, tint: Tint, color: bool) Io.Writer.Error!void {
    if (!color or text.len == 0 or tint == .none) return w.writeAll(text);
    try w.print("\x1b[{s}m{s}\x1b[0m", .{ tint.code(), text });
}

/// A horizontal rule with `mid` at each column stop; `tab_edge` marks where
/// the title tab above ends.
fn rule(w: *Io.Writer, stops: []const usize, right: usize, left: []const u8, mid: []const u8, end: []const u8, tab_edge: ?usize) Io.Writer.Error!void {
    var x: usize = 0;
    while (x <= right) : (x += 1) {
        if (tab_edge) |e| if (x == e) {
            const at_stop = std.mem.indexOfScalar(usize, stops[1 .. stops.len - 1], x) != null;
            try w.writeAll(if (x == right) "┤" else if (at_stop) "┼" else "┴");
            continue;
        };
        if (x == 0) {
            try w.writeAll(left);
        } else if (x == right) {
            try w.writeAll(end);
        } else if (std.mem.indexOfScalar(usize, stops[1 .. stops.len - 1], x) != null) {
            try w.writeAll(mid);
        } else {
            try w.writeAll("─");
        }
    }
    try w.writeAll("\n");
}

fn row(w: *Io.Writer, columns: []const Column, widths: []const usize, cells: ?[]const Cell, heading: bool, color: bool) Io.Writer.Error!void {
    try w.writeAll("│");
    for (columns, 0..) |col, i| {
        const text = if (cells) |cs| cs[i].text else col.head;
        const tint: Tint = if (heading) .bold else if (cells.?[i].tint) |t| t else col.tint;
        var buf: [512]u8 = undefined;
        const shown = cut(&buf, text, widths[i]);
        const room = widths[i] -| cols(shown);
        try w.writeAll(" ");
        if (!heading and col.alignment == .right) try repeat(w, " ", room);
        try paint(w, shown, tint, color);
        if (heading or col.alignment == .left) try repeat(w, " ", room);
        try w.writeAll(" │");
    }
    try w.writeAll("\n");
}

/// `text` cut to `width` columns, ending in an ellipsis when cut.
fn cut(buf: []u8, text: []const u8, width: usize) []const u8 {
    if (cols(text) <= width) return text;
    if (width == 0) return "";
    var it = std.unicode.Utf8View.initUnchecked(text).iterator();
    var used: usize = 0;
    var end: usize = 0;
    while (used + 1 < width) : (used += 1) {
        const cp = it.nextCodepointSlice() orelse break;
        end += cp.len;
    }
    const keep = @min(end, buf.len - 3);
    @memcpy(buf[0..keep], text[0..keep]);
    @memcpy(buf[keep .. keep + 3], "…");
    return buf[0 .. keep + 3];
}

/// The terminal's width in columns, or null when `fd` is not a terminal.
pub fn terminalWidth(fd: std.c.fd_t) ?usize {
    var ws: std.c.winsize = undefined;
    if (std.c.ioctl(fd, std.c.T.IOCGWINSZ, &ws) != 0 or ws.col == 0) return null;
    return ws.col;
}

const testing = std.testing;

test "a boxed table with a title tab" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [2048]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const t: Table = .{
        .title = "cpuq 0.4.0",
        .columns = &.{ .{ .head = "NAME" }, .{ .head = "N", .alignment = .right } },
        .rows = &.{
            &.{ .{ .text = "alpha" }, .{ .text = "3" } },
            &.{ .{ .text = "b" }, .{ .text = "12" } },
        },
        .notes = &.{"2 rows"},
    };
    try t.boxed(arena.allocator(), &w, null, false);
    try testing.expectEqualStrings(
        \\╭────────────╮
        \\│ cpuq 0.4.0 │
        \\├───────┬────┤
        \\│ NAME  │ N  │
        \\│ alpha │  3 │
        \\│ b     │ 12 │
        \\╰───────┴────╯
        \\
        \\  2 rows
        \\
    , w.buffered());
}

test "the flexible column is cut to fit" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var buf: [1024]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    const t: Table = .{
        .columns = &.{ .{ .head = "ID" }, .{ .head = "COMMAND", .flexible = true } },
        .rows = &.{&.{ .{ .text = "1" }, .{ .text = "zig build -j4 install --summary all" } }},
    };
    try t.boxed(arena.allocator(), &w, 24, false);
    try testing.expect(std.mem.indexOf(u8, w.buffered(), "zig build -j4 …") != null);
    var lines = std.mem.splitScalar(u8, w.buffered(), '\n');
    while (lines.next()) |line| if (line.len != 0) try testing.expectEqual(24, cols(line));
}
