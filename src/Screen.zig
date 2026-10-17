//! What slime draws for a pane: the frames slimed sends, applied. The
//! codec is shared with slimed (ssh/internal/vt/frame.zig).

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const frame = @import("frame");

pub const Codec = frame.Codec(ghostty_vt);
pub const Screen = Codec.Screen;

const testing = std.testing;
const RenderState = ghostty_vt.RenderState;

/// A terminal, its render state, and a screen fed frames of it.
const Harness = struct {
    alloc: std.mem.Allocator,
    t: ghostty_vt.Terminal,
    stream: ghostty_vt.TerminalStream,
    state: RenderState = .empty,
    screen: Screen = .{},
    buf: std.Io.Writer.Allocating,
    frames: usize = 0,

    fn init(h: *Harness, cols: u16, rows: u16) !void {
        const alloc = testing.allocator;
        h.* = .{
            .alloc = alloc,
            .t = try .init(testing.io, alloc, .{ .cols = cols, .rows = rows, .max_scrollback_bytes = null }),
            .stream = undefined,
            .buf = .init(alloc),
        };
        h.stream = h.t.vtStream();
    }

    fn deinit(h: *Harness) void {
        h.buf.deinit();
        h.screen.deinit(h.alloc);
        h.state.deinit(h.alloc);
        h.stream.deinit();
        h.t.deinit(h.alloc);
    }

    fn write(h: *Harness, s: []const u8) void {
        h.stream.nextSlice(s);
    }

    /// Encode a frame of what changed, apply it, and check the screen
    /// against the render state, cell by cell.
    fn sync(h: *Harness) !void {
        try h.state.update(h.alloc, &h.t);
        h.buf.clearRetainingCapacity();
        try Codec.encode(&h.buf.writer, &h.state, .{});
        h.state.clean();
        try h.screen.apply(h.alloc, h.buf.written());
        h.frames += 1;
        try h.expectSame();
    }

    fn expectSame(h: *Harness) !void {
        const s = &h.state;
        try testing.expectEqual(s.cols, h.screen.cols);
        try testing.expectEqual(s.rows, h.screen.rows);
        try testing.expectEqual(s.colors.background, h.screen.colors.background);
        try testing.expectEqual(s.colors.foreground, h.screen.colors.foreground);
        try testing.expectEqual(s.colors.cursor, h.screen.colors.cursor);
        try testing.expectEqualSlices(ghostty_vt.color.RGB, &s.colors.palette, &h.screen.colors.palette);
        try testing.expectEqual(s.cursor.visible, h.screen.cursor.visible);
        try testing.expectEqual(s.cursor.blinking, h.screen.cursor.blinking);
        try testing.expectEqual(s.cursor.visual_style, h.screen.cursor.visual_style);
        try testing.expectEqual(s.cursor.viewport, h.screen.cursor.viewport);
        try testing.expectEqual(s.cursor.cell, h.screen.cursor.cell);
        try testing.expect(s.cursor.style.eql(h.screen.cursor.style));

        const rows = s.row_data.slice();
        for (rows.items(.cells)[0..s.rows], rows.items(.selection)[0..s.rows], h.screen.row_data.items) |cells, sel, *got| {
            try testing.expectEqual(sel, got.selection);
            const c = cells.slice();
            for (c.items(.raw)[0..s.cols], c.items(.style)[0..s.cols], c.items(.grapheme)[0..s.cols], 0..) |raw, style, grapheme, x| {
                try testing.expectEqual(raw, got.raws.items[x]);
                if (raw.hasStyling()) try testing.expect(style.eql(got.styles.items[x]));
                if (raw.hasGrapheme()) try testing.expectEqualSlices(u21, grapheme, got.graphemes.items[x]);
            }
        }
    }
};

test "first frame is full and matches" {
    var h: Harness = undefined;
    try h.init(20, 5);
    defer h.deinit();
    h.write("hello\r\n\x1b[1;31mred\x1b[0m \x1b[38;2;10;20;30mrgb\x1b[0m");
    try h.sync();
}

test "partial frames carry only dirty rows" {
    var h: Harness = undefined;
    try h.init(20, 5);
    defer h.deinit();
    h.write("one\r\ntwo\r\nthree");
    try h.sync();
    h.write("\x1b[1;1Hzzz");
    try h.state.update(h.alloc, &h.t);
    h.buf.clearRetainingCapacity();
    try Codec.encode(&h.buf.writer, &h.state, .{});
    h.state.clean();
    // Header, colors, cursor, then one row.
    try h.screen.apply(h.alloc, h.buf.written());
    try h.expectSame();
    // The written row, and the one the cursor left.
    const rows = h.screen.row_data.items;
    try testing.expect(rows[0].dirty and !rows[1].dirty and rows[2].dirty and !rows[3].dirty and !rows[4].dirty);
}

test "scrolling output and the viewport in history" {
    var h: Harness = undefined;
    try h.init(30, 6);
    defer h.deinit();
    for (0..100) |i| {
        var buf: [32]u8 = undefined;
        h.write(try std.fmt.bufPrint(&buf, "\x1b[3{d}mline {d}\x1b[0m\r\n", .{ i % 8, i }));
        if (i % 7 == 0) try h.sync();
    }
    try h.sync();
    h.t.scrollViewport(.{ .delta = -40 });
    try h.sync();
    h.t.scrollViewport(.bottom);
    try h.sync();
}

test "wide characters, graphemes, and many styles in a row" {
    var h: Harness = undefined;
    try h.init(40, 4);
    defer h.deinit();
    h.t.modes.set(.grapheme_cluster, true);
    h.write("wide: \u{4e2d}\u{6587} emoji: \u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467} e\u{301}\r\n");
    // Every cell its own color.
    for (0..40) |i| {
        var buf: [40]u8 = undefined;
        h.write(try std.fmt.bufPrint(&buf, "\x1b[48;2;{d};{d};0m ", .{ i * 6, 255 - i * 6 }));
    }
    try h.sync();
}

test "selection, resize, alternate screen, and colors" {
    var h: Harness = undefined;
    try h.init(20, 5);
    defer h.deinit();
    h.write("select me please\r\nsecond line");
    try h.sync();

    const screen = h.t.screens.active;
    const a = screen.pages.pin(.{ .viewport = .{ .x = 2, .y = 0 } }).?;
    const b = screen.pages.pin(.{ .viewport = .{ .x = 4, .y = 1 } }).?;
    try screen.select(.init(a, b, false));
    try h.sync();
    try testing.expectEqual(@as(?[2]u16, .{ 2, 19 }), h.screen.row_data.items[0].selection);

    try h.t.resize(h.alloc, .{ .cols = 12, .rows = 7 });
    try h.sync();

    h.write("\x1b]4;1;rgb:12/34/56\x07\x1b]11;rgb:01/02/03\x07\x1b[?1049hon the alt screen\x1b[2 q");
    try h.sync();
    h.write("\x1b[?1049l\x1b[?25l");
    try h.sync();
}

test "a frame for another size is rejected" {
    var h: Harness = undefined;
    try h.init(10, 3);
    defer h.deinit();
    try h.sync();
    var other: Harness = undefined;
    try other.init(11, 3);
    defer other.deinit();
    try other.state.update(other.alloc, &other.t);
    other.state.clean();
    other.write("x");
    try other.state.update(other.alloc, &other.t);
    other.buf.clearRetainingCapacity();
    try Codec.encode(&other.buf.writer, &other.state, .{});
    try testing.expectError(error.BadFrame, h.screen.apply(h.alloc, other.buf.written()));
}
