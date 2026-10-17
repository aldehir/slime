//! What slime draws for a pane: the frames slimed sends, applied. The
//! codec is shared with slimed (internal/vt/frame.zig).

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const frame = @import("frame");

pub const Codec = frame.Codec(ghostty_vt);
pub const Screen = Codec.Screen;
pub const Flags = frame.Flags;

/// Input to send slimed: the codec it decodes with (event.zig).
pub const event = @import("event");
pub const Events = event.Codec(ghostty_vt);

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

test "events round trip" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    var scratch: Events.Scratch = .{};
    const records = [_]event.Win32Key{
        .{ .vk = 65, .scancode = 30, .char = 'a', .down = true, .control_state = 8, .repeat = 2 },
        .{ .vk = 65, .scancode = 30, .char = 'b', .down = false },
    };
    var colors: Events.Colors = .{
        .background = .{ .r = 1, .g = 2, .b = 3 },
        .foreground = .{ .r = 250, .g = 251, .b = 252 },
        .cursor = .{ .r = 9, .g = 8, .b = 7 },
        .palette = ghostty_vt.color.default,
    };
    colors.palette[255] = .{ .r = 4, .g = 5, .b = 6 };
    var no_cursor = colors;
    no_cursor.cursor = null;
    const cases = [_]Events.Event{
        .{ .key = .{
            .event = .{
                .action = .repeat,
                .key = .key_a,
                .mods = .{ .ctrl = true, .shift = true },
                .consumed_mods = .{ .shift = true },
                .composing = true,
                .utf8 = "A",
                .unshifted_codepoint = 'a',
            },
            .win32 = &records,
        } },
        .{ .text = "h\u{e9}llo" },
        .{ .paste = "line\nnext" },
        .{ .focus = true },
        .{ .mouse = .{ .action = .motion, .button = .right, .mods = .{ .alt = true }, .held = true, .x = 12.5, .y = -3, .time = 0xfffffff0 } },
        .{ .mouse = .{ .action = .release, .button = null, .mods = .{}, .held = false, .x = 0, .y = 0, .time = 1 } },
        .{ .wheel = .{ .horizontal = true, .rotation = -240, .lines_per_notch = event.lines_page, .mods = .{ .super = true }, .x = 1, .y = 2 } },
        .{ .copy = 0xabcdef },
        .{ .geometry = .{ .cell_width = 9, .cell_height = 19, .padding = .{ .left = 1, .top = 2, .right = 3, .bottom = 4 }, .width = 800, .height = 600 } },
        .{ .settings = .{ .double_click_ms = 400, .word_boundary = &.{ ' ', '\u{2502}', '$' }, .colors = colors } },
        .{ .settings = .{ .double_click_ms = 500, .word_boundary = &.{}, .colors = no_cursor } },
        .cancel,
    };
    for (cases) |ev| {
        buf.clearRetainingCapacity();
        try Events.encode(&buf.writer, ev);
        const got = try Events.decode(buf.written(), &scratch);
        try testing.expectEqual(std.meta.activeTag(ev), std.meta.activeTag(got));
        switch (ev) {
            .key => |k| {
                const g = got.key;
                try testing.expectEqual(k.event.action, g.event.action);
                try testing.expectEqual(k.event.key, g.event.key);
                try testing.expectEqual(k.event.mods, g.event.mods);
                try testing.expectEqual(k.event.consumed_mods, g.event.consumed_mods);
                try testing.expectEqual(k.event.composing, g.event.composing);
                try testing.expectEqualStrings(k.event.utf8, g.event.utf8);
                try testing.expectEqual(k.event.unshifted_codepoint, g.event.unshifted_codepoint);
                try testing.expectEqualSlices(event.Win32Key, k.win32, g.win32);
            },
            .text => |s| try testing.expectEqualStrings(s, got.text),
            .paste => |s| try testing.expectEqualStrings(s, got.paste),
            .settings => |s| {
                try testing.expectEqual(s.double_click_ms, got.settings.double_click_ms);
                try testing.expectEqualSlices(u21, s.word_boundary, got.settings.word_boundary);
                try testing.expectEqualDeep(s.colors, got.settings.colors);
            },
            else => try testing.expectEqualDeep(ev, got),
        }
    }
    try testing.expectError(error.BadEvent, Events.decode(&.{0}, &scratch));
    try testing.expectError(error.EndOfStream, Events.decode(&.{@intFromEnum(event.Kind.copy)}, &scratch));
}

test "kitty images are placed in frames, their pixels sent once" {
    var h: Harness = undefined;
    try h.init(10, 5);
    defer h.deinit();
    // 10x20 pixel cells.
    h.t.width_px = 100;
    h.t.height_px = 100;
    h.t.modes.set(.grapheme_cluster, true);
    var sender: Codec.ImageSender = .{};
    defer sender.deinit(h.alloc);

    // A 2x2 RGB image, id 7, placed at the cursor: row 2, column 3.
    const rgb = [_]u8{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 };
    var b64: [16]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&b64, &rgb);
    h.write("\x1b[2;3H\x1b_Gf=24,s=2,v=2,i=7,a=T;" ++ b64 ++ "\x1b\\");
    try sender.gather(h.alloc, &h.t);
    try testing.expectEqual(1, sender.pending.items.len);
    try testing.expectEqual(1, sender.placements.items.len);
    try testing.expectEqual(0, sender.dropped.items.len);
    const px = (try sender.pixels(h.alloc, &h.t, 0)).?;
    defer h.alloc.free(px.rgba);
    try testing.expectEqual(7, px.id);
    try testing.expectEqual(.{ 2, 2 }, .{ px.width, px.height });
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, px.rgba[0..8]);

    try h.state.update(h.alloc, &h.t);
    h.buf.clearRetainingCapacity();
    try Codec.encode(&h.buf.writer, &h.state, .{ .images = &sender });
    h.state.clean();
    try h.screen.apply(h.alloc, h.buf.written());
    try h.expectSame();
    try testing.expectEqual(1, h.screen.placements.items.len);
    const p = h.screen.placements.items[0];
    try testing.expectEqual(7, p.image_id);
    try testing.expectEqual(.{ 2, 1 }, .{ p.x, p.y });
    try testing.expectEqual(.{ 2, 2 }, .{ p.width, p.height });
    try testing.expectEqual(.{ 0, 0, 2, 2 }, .{ p.src_x, p.src_y, p.src_width, p.src_height });
    try testing.expectEqual(0, h.screen.dropped.items.len);

    // Still placed, but sent already.
    try sender.gather(h.alloc, &h.t);
    try testing.expectEqual(0, sender.pending.items.len);
    try testing.expectEqual(1, sender.placements.items.len);

    // A placeholder cell shows part of the image under the text.
    try h.t.screens.active.kitty_images.addPlacement(testing.io, h.alloc, h.t.screens.active, 7, 1, .{ .location = .{ .virtual = {} } });
    try h.t.setAttribute(.{ .@"256_fg" = 7 });
    h.t.screens.active.cursorAbsolute(4, 3);
    try h.t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try sender.gather(h.alloc, &h.t);
    try testing.expectEqual(2, sender.placements.items.len);
    const v = sender.placements.items[1];
    try testing.expectEqual(-1, v.z);
    try testing.expectEqual(.{ 4, 3 }, .{ v.x, v.y });
    try testing.expectEqual(.{ 10, 10 }, .{ v.width, v.height });

    // Deleted, the image is dropped in the next frame and gone from it.
    h.write("\x1b_Ga=d,d=I,i=7\x1b\\");
    try sender.gather(h.alloc, &h.t);
    try testing.expectEqualSlices(u32, &.{7}, sender.dropped.items);
    try testing.expectEqual(0, sender.placements.items.len);
    try h.state.update(h.alloc, &h.t);
    h.buf.clearRetainingCapacity();
    try Codec.encode(&h.buf.writer, &h.state, .{ .images = &sender });
    h.state.clean();
    try h.screen.apply(h.alloc, h.buf.written());
    try testing.expectEqualSlices(u32, &.{7}, h.screen.dropped.items);
    try testing.expectEqual(0, h.screen.placements.items.len);
    // Placed again, it's sent again.
    h.write("\x1b_Gf=24,s=2,v=2,i=7,a=T;" ++ b64 ++ "\x1b\\");
    try sender.gather(h.alloc, &h.t);
    try testing.expectEqual(1, sender.pending.items.len);
}

test "frames carry the mouse shape and whether to send motion" {
    var h: Harness = undefined;
    try h.init(10, 3);
    defer h.deinit();
    try h.state.update(h.alloc, &h.t);
    h.buf.clearRetainingCapacity();
    try Codec.encode(&h.buf.writer, &h.state, .{ .motion = true, .mouse_shape = 3 });
    try h.screen.apply(h.alloc, h.buf.written());
    try testing.expect(h.screen.motion);
    try testing.expectEqual(3, h.screen.mouse_shape);
}

test "max_len is the largest event" {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();
    // A settings event with every word boundary codepoint slimed has
    // room for; more are cut.
    var words: [Events.max_word_boundary + 1]u21 = undefined;
    @memset(&words, 0x10FFFF);
    try Events.encode(&buf.writer, .{ .settings = .{
        .double_click_ms = 500,
        .word_boundary = &words,
        .colors = .{ .background = .{}, .foreground = .{}, .cursor = .{}, .palette = ghostty_vt.color.default },
    } });
    try testing.expectEqual(Events.max_len, buf.written().len);

    // A key with the most text and win32 records.
    buf.clearRetainingCapacity();
    const records = [_]event.Win32Key{.{ .down = true }} ** (Events.max_win32 + 1);
    try Events.encode(&buf.writer, .{ .key = .{
        .event = .{ .action = .press, .key = .key_a, .mods = .{}, .consumed_mods = .{}, .composing = false, .utf8 = "x" ** 300, .unshifted_codepoint = 'a' },
        .win32 = &records,
    } });
    try testing.expect(buf.written().len <= Events.max_len);
}
