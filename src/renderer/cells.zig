//! Converts a terminal RenderState into GPU-ready data: one background
//! color per cell, and a list of quads (glyphs and solid rectangles for
//! the cursor and text decorations). Independent of the graphics API.
//!
//! Rows are cached by content, so a frame only rebuilds the rows that
//! changed and then copies every row's quads into place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const font = @import("../font/font.zig");
const TerminalColor = @import("../Config.zig").TerminalColor;

const RenderState = ghostty_vt.RenderState;
const RGB = ghostty_vt.color.RGB;

/// Shader constants. Must match `Uniforms` in shaders.hlsl, including
/// HLSL's 16-byte register packing.
pub const Uniforms = extern struct {
    default_bg: [4]f32,
    viewport_origin: [2]f32,
    viewport_size: [2]f32,
    cell_size: [2]f32,
    grid_size: [2]u32,
    grid_offset: [2]f32,
    /// Constant buffers are a whole number of registers.
    _pad: [2]f32 = .{ 0, 0 },

    comptime {
        std.debug.assert(@sizeOf(Uniforms) % 16 == 0);
    }
};

/// One quad. Must match `Instance` in shaders.hlsl.
pub const Instance = extern struct {
    pos: [2]f32,
    size: [2]f32,
    atlas: [2]u32 = .{ 0, 0 },
    color: u32,
    kind: Kind,

    pub const Kind = enum(u32) {
        glyph = 0,
        rect = 1,
        /// A glyph from the color atlas, drawn in its own colors.
        color_glyph = 2,
        /// A glyph from the ClearType atlas.
        lcd_glyph = 3,
    };
};

pub const Cells = struct {
    cols: u32 = 0,
    rows: u32 = 0,
    default_bg: RGB = .{},

    /// Packed RGBA per cell, row-major.
    bg: std.ArrayList(u32) = .empty,

    /// Quads in draw order.
    instances: std.ArrayList(Instance) = .empty,

    /// Each row's quads and backgrounds, keyed by a hash of everything
    /// building the row reads. Only rows whose content changed are
    /// rebuilt, a row that scrolls reuses its entry at its new position,
    /// and identical rows (blank ones, say) share one entry.
    row_cache: std.AutoHashMapUnmanaged(u64, CachedRow) = .empty,

    /// A hash of the state every cached row depends on. A change
    /// empties the cache.
    cache_key: u64 = 0,

    /// Counts builds, to evict cached rows that have gone unused.
    frame: u64 = 0,

    /// Per-row scratch: text state for each cell of the current row.
    row_text: std.ArrayList(TextCell) = .empty,

    /// Per-run scratch: UTF-16 text and each unit's cell offset.
    run_text: std.ArrayList(u16) = .empty,
    run_cells: std.ArrayList(u16) = .empty,

    const TextCell = struct {
        /// False for cells without text, including wide-char spacers.
        has_text: bool,
        face: font.Grid.FaceId,
        /// Packed text color. Zero alpha means shape but don't draw.
        color: u32,
    };

    const CachedRow = struct {
        /// Quads with y relative to the top of the row.
        instances: std.ArrayList(Instance) = .empty,
        bg: std.ArrayList(u32) = .empty,
        last_used: u64,

        fn deinit(self: *CachedRow, alloc: Allocator) void {
            self.instances.deinit(alloc);
            self.bg.deinit(alloc);
        }
    };

    /// The most codepoints of one grapheme we pass to the font system.
    const max_grapheme = 16;

    pub fn deinit(self: *Cells, alloc: Allocator) void {
        self.clearCache(alloc);
        self.row_cache.deinit(alloc);
        self.bg.deinit(alloc);
        self.instances.deinit(alloc);
        self.row_text.deinit(alloc);
        self.run_text.deinit(alloc);
        self.run_cells.deinit(alloc);
        self.* = undefined;
    }

    /// Rebuild the frame from the render state, reusing cached rows
    /// whose content hasn't changed. Rasterizes any glyphs not yet in
    /// the atlas.
    pub fn build(
        self: *Cells,
        alloc: Allocator,
        state: *const RenderState,
        grid: *font.Grid,
        cursor: CursorOptions,
        config: ColorOptions,
    ) !void {
        const m = grid.metrics;
        const colors = &state.colors;

        self.cols = state.cols;
        self.rows = state.rows;
        self.default_bg = colors.background;
        try self.bg.resize(alloc, @as(usize, self.cols) * self.rows);
        try self.row_text.resize(alloc, self.cols);
        self.instances.clearRetainingCapacity();
        grid.beginFrame();
        self.frame += 1;

        const key = cacheKey(self.cols, colors, m, grid.atlas.resets, config);
        if (key != self.cache_key) {
            self.clearCache(alloc);
            self.cache_key = key;
        }

        // OSC 12 or a configured color, then one taken from the cursor's
        // cell, which Ghostty reads from the cursor's pen style.
        const cursor_color = colors.cursor orelse if (config.cursor_color) |c| color: {
            const fg, const bg = cellColors(state.cursor.style, state.cursor.cell, colors);
            break :color c.resolve(fg, bg);
        } else colors.foreground;
        const cursor_style = cursorStyle(state, cursor);
        const cursor_pos = if (cursor_style != null) state.cursor.viewport else null;

        // A block cursor goes under the text, so it's drawn first.
        if (cursor_pos) |pos| if (cursor_style == .block) {
            try self.instances.append(alloc, rect(m, pos.x, pos.y, 0, m.cell_width, m.cell_height, cursor_color));
        };

        const rows = state.row_data.slice();
        for (
            rows.items(.cells)[0..self.rows],
            rows.items(.selection)[0..self.rows],
            0..,
        ) |row_cells, selection, y_usize| {
            const y: u32 = @intCast(y_usize);
            const cells = row_cells.slice();
            const row: Row = .{
                .raws = cells.items(.raw)[0..self.cols],
                .styles = cells.items(.style),
                .graphemes = cells.items(.grapheme),
                .selection = selection,
                .cursor_x = if (cursor_pos) |pos| (if (pos.y == y) pos.x else null) else null,
                .cursor_block = cursor_style == .block,
            };

            const gop = try self.row_cache.getOrPut(alloc, row.hash());
            const cached = gop.value_ptr;
            if (!gop.found_existing) {
                cached.* = .{ .last_used = self.frame };
                self.buildRow(alloc, cached, row, grid, colors, config) catch |err| {
                    cached.deinit(alloc);
                    self.row_cache.removeByPtr(gop.key_ptr);
                    return err;
                };
            }
            cached.last_used = self.frame;

            @memcpy(self.bg.items[y * self.cols ..][0..self.cols], cached.bg.items);
            const top: f32 = @floatFromInt(y * m.cell_height);
            const placed = try self.instances.addManyAsSlice(alloc, cached.instances.items.len);
            for (placed, cached.instances.items) |*dst, src| {
                dst.* = src;
                dst.pos[1] += top;
            }
        }

        // Non-block cursors go over the text.
        if (cursor_pos) |pos| {
            const thick = @max(1, m.underline_thickness);
            switch (cursor_style.?) {
                .block => {},
                .bar => try self.instances.append(alloc, rect(m, pos.x, pos.y, 0, @max(1, m.cell_width / 8), m.cell_height, cursor_color)),
                .underline => try self.instances.append(alloc, rect(m, pos.x, pos.y, m.cell_height - thick, m.cell_width, thick, cursor_color)),
                .block_hollow => {
                    const w = m.cell_width;
                    const h = m.cell_height;
                    try self.instances.appendSlice(alloc, &.{
                        rect(m, pos.x, pos.y, 0, w, thick, cursor_color),
                        rect(m, pos.x, pos.y, h - thick, w, thick, cursor_color),
                        rect(m, pos.x, pos.y, 0, thick, h, cursor_color),
                        rectX(m, pos.x, pos.y, w - thick, thick, h, cursor_color),
                    });
                },
            }
        }

        self.evict(alloc);
    }

    /// Build one row's backgrounds and quads into `out`, with the quads
    /// positioned as if the row were at the top of the grid.
    fn buildRow(
        self: *Cells,
        alloc: Allocator,
        out: *CachedRow,
        row: Row,
        grid: *font.Grid,
        colors: *const RenderState.Colors,
        config: ColorOptions,
    ) !void {
        const m = grid.metrics;
        try out.bg.resize(alloc, self.cols);

        // Pass 1: colors, decorations, and each cell's face.
        for (row.raws, 0..) |raw, x_usize| {
            const x: u32 = @intCast(x_usize);
            const style: ghostty_vt.Style = if (raw.hasStyling()) row.styles[x] else .{};

            // Unconfigured selection colors are the default colors
            // inverted, as in Ghostty.
            const selected = if (row.selection) |sel| x >= sel[0] and x <= sel[1] else false;
            var fg, var bg = cellColors(style, raw, colors);
            if (selected) {
                const cell_fg = fg;
                const cell_bg = bg;
                bg = if (config.selection_background) |c| c.resolve(cell_fg, cell_bg) else colors.foreground;
                fg = if (config.selection_foreground) |c| c.resolve(cell_fg, cell_bg) else colors.background;
            }
            // Default backgrounds are left transparent: the frame is
            // cleared to it, and kitty images below the background
            // show through.
            const default_bg = !selected and !style.flags.inverse and style.bg(&raw, &colors.palette) == null;
            out.bg.items[x] = if (default_bg) 0 else pack(bg, 255);

            self.row_text.items[x] = .{ .has_text = false, .face = 0, .color = 0 };
            if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
            const width: u32 = if (raw.wide == .wide) 2 else 1;

            // Text under a block cursor takes the cell's background
            // color so it stays readable, unless configured.
            const under_cursor = row.cursor_block and row.cursor_x == x;
            const cursor_text = if (config.cursor_text) |c| c.resolve(fg, bg) else bg;
            const text_color = if (under_cursor) cursor_text else fg;
            const alpha: u8 = if (style.flags.faint) 128 else 255;

            // A kitty image placeholder is drawn as the image, not a glyph.
            if (raw.hasText() and raw.codepoint() != ghostty_vt.kitty.graphics.unicode.placeholder) {
                var cp_buf: [max_grapheme]u21 = undefined;
                const cps = graphemeCodepoints(raw, row.graphemes[x], &cp_buf);
                self.row_text.items[x] = .{
                    .has_text = true,
                    .face = try grid.faceFor(.init(style.flags.bold, style.flags.italic), cps),
                    .color = if (style.flags.invisible) 0 else pack(text_color, alpha),
                };
            }

            // TODO: distinct double/curly/dotted/dashed underlines.
            if (style.flags.underline != .none) {
                try out.instances.append(alloc, rectA(m, x, 0, m.underline_position, width * m.cell_width, m.underline_thickness, text_color, alpha));
            }
            if (style.flags.strikethrough) {
                try out.instances.append(alloc, rectA(m, x, 0, m.strikethrough_position, width * m.cell_width, m.strikethrough_thickness, text_color, alpha));
            }
        }

        // Pass 2: shape runs of text sharing a face. Runs also end at
        // the cursor so a ligature never hides its position.
        var x: u32 = 0;
        while (x < self.cols) {
            const first = self.row_text.items[x];
            if (!first.has_text) {
                x += 1;
                continue;
            }

            // Sprites are drawn to fit their cells, with nothing to shape.
            if (first.face == font.Grid.sprite_face) {
                const raw = row.raws[x];
                if (first.color >> 24 != 0) {
                    if (try grid.spriteGlyph(raw.codepoint(), if (raw.wide == .wide) 2 else 1)) |g| {
                        try out.instances.append(alloc, glyphInstance(m, x, 0, 0, g, first.color));
                    }
                }
                x += 1;
                continue;
            }

            const run_start = x;
            self.run_text.clearRetainingCapacity();
            self.run_cells.clearRetainingCapacity();
            while (x < self.cols) {
                const cell = self.row_text.items[x];
                if (!cell.has_text or cell.face != first.face) break;
                if (x != run_start and row.cursor_x == x) break;

                var cp_buf: [max_grapheme]u21 = undefined;
                var utf16_buf: [2 * max_grapheme]u16 = undefined;
                const text = font.Grid.encodeUtf16(graphemeCodepoints(row.raws[x], row.graphemes[x], &cp_buf), &utf16_buf);
                try self.run_text.appendSlice(alloc, text);
                try self.run_cells.appendNTimes(alloc, @intCast(x - run_start), text.len);

                x += 1;
                if (row.cursor_x == x - 1) break;
            }

            const shaped = try grid.shape(first.face, self.run_text.items, self.run_cells.items);
            for (shaped) |sg| {
                const cell_x = run_start + sg.cell;
                const color = self.row_text.items[cell_x].color;
                if (color >> 24 == 0) continue;
                const g = try grid.glyph(first.face, sg.index) orelse continue;
                try out.instances.append(alloc, glyphInstance(m, cell_x, sg.x, sg.y, g, color));
            }
        }
    }

    /// Drop rows not drawn by this build or the last. Keeping the last
    /// build's rows means a blinking cursor's row never rebuilds.
    fn evict(self: *Cells, alloc: Allocator) void {
        var it = self.row_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_used + 1 >= self.frame) continue;
            entry.value_ptr.deinit(alloc);
            self.row_cache.removeByPtr(entry.key_ptr);
        }
    }

    fn clearCache(self: *Cells, alloc: Allocator) void {
        var it = self.row_cache.valueIterator();
        while (it.next()) |cached| cached.deinit(alloc);
        self.row_cache.clearRetainingCapacity();
    }

    /// `viewport` is x, y, width, height in render target pixels, and
    /// `offset` the grid's top-left within it.
    pub fn uniforms(self: *const Cells, m: font.Grid.Metrics, viewport: [4]f32, offset: [2]f32) Uniforms {
        return .{
            .viewport_origin = .{ viewport[0], viewport[1] },
            .viewport_size = .{ viewport[2], viewport[3] },
            .cell_size = .{ @floatFromInt(m.cell_width), @floatFromInt(m.cell_height) },
            .grid_size = .{ self.cols, self.rows },
            .grid_offset = .{ viewport[0] + offset[0], viewport[1] + offset[1] },
            .default_bg = toFloat(self.default_bg),
        };
    }
};

/// Window state that decides how the cursor is drawn.
pub const CursorOptions = struct {
    /// Unfocused windows show a hollow block that doesn't blink.
    focused: bool = true,
    /// The on phase of the blink. Ignored when the cursor doesn't blink.
    blink_visible: bool = true,
};

/// Configured colors for the cursor and selection. See the same-named
/// `Config` keys.
pub const ColorOptions = struct {
    cursor_color: ?TerminalColor = null,
    cursor_text: ?TerminalColor = null,
    selection_background: ?TerminalColor = null,
    selection_foreground: ?TerminalColor = null,
};

/// Everything building one row reads, apart from the state hashed by
/// `cacheKey`.
const Row = struct {
    raws: []const ghostty_vt.Cell,
    /// Valid only for cells with styling.
    styles: []const ghostty_vt.Style,
    /// Valid only for cells with graphemes.
    graphemes: []const []const u21,
    selection: @FieldType(RenderState.Row, "selection"),
    /// The cursor's column, if it's drawn on this row.
    cursor_x: ?u32,
    cursor_block: bool,

    fn hash(self: Row) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.sliceAsBytes(self.raws));

        // Style ids only mean something within one page, so also mix in
        // the style each id resolves to. A row is in one page, so once
        // per change of id is enough.
        var style_id: @FieldType(ghostty_vt.Cell, "style_id") = 0;
        for (self.raws, 0..) |raw, x| {
            if (raw.hasStyling() and raw.style_id != style_id) {
                style_id = raw.style_id;
                std.hash.autoHash(&h, x);
                std.hash.autoHash(&h, self.styles[x]);
            }
            if (raw.hasGrapheme()) {
                std.hash.autoHash(&h, x);
                h.update(std.mem.sliceAsBytes(self.graphemes[x]));
            }
        }

        std.hash.autoHash(&h, self.selection);
        std.hash.autoHash(&h, self.cursor_x);
        std.hash.autoHash(&h, self.cursor_block);
        return h.final();
    }
};

/// A hash of the state shared by every row: the grid width, colors,
/// cell metrics, and the atlas regions glyphs were placed in.
fn cacheKey(
    cols: u32,
    colors: *const RenderState.Colors,
    m: font.Grid.Metrics,
    atlas_resets: u32,
    config: ColorOptions,
) u64 {
    var h = std.hash.Wyhash.init(0);
    std.hash.autoHash(&h, cols);
    std.hash.autoHash(&h, pack(colors.background, 0));
    std.hash.autoHash(&h, pack(colors.foreground, 0));
    var palette: [colors.palette.len]u32 = undefined;
    for (&palette, colors.palette) |*p, c| p.* = pack(c, 0);
    h.update(std.mem.asBytes(&palette));
    std.hash.autoHash(&h, m);
    std.hash.autoHash(&h, atlas_resets);
    std.hash.autoHash(&h, config);
    return h.final();
}

/// A cell's foreground and background, after inverse.
fn cellColors(style: ghostty_vt.Style, raw: ghostty_vt.Cell, colors: *const RenderState.Colors) struct { RGB, RGB } {
    var fg = style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
    var bg = style.bg(&raw, &colors.palette) orelse colors.background;
    if (style.flags.inverse) std.mem.swap(RGB, &fg, &bg);
    return .{ fg, bg };
}

/// The cursor to draw, or null for none. The same priority as Ghostty's
/// renderer: hidden by the terminal, then unfocused, then blink.
fn cursorStyle(state: *const RenderState, opts: CursorOptions) ?ghostty_vt.CursorStyle {
    if (state.cursor.viewport == null or !state.cursor.visible) return null;
    if (!opts.focused) return .block_hollow;
    if (state.cursor.blinking and !opts.blink_visible) return null;
    return state.cursor.visual_style;
}

/// A glyph in cell `x` of a row at the top of the grid, offset by
/// (`dx`, `dy`) from where its cell would put it.
fn glyphInstance(m: font.Grid.Metrics, x: u32, dx: i32, dy: i32, g: font.Grid.Glyph, color: u32) Instance {
    const origin_x: i32 = @intCast(x * m.cell_width);
    return .{
        .pos = .{
            @floatFromInt(origin_x + dx + g.offset_x),
            @floatFromInt(dy + g.offset_y),
        },
        .size = .{ @floatFromInt(g.region.width), @floatFromInt(g.region.height) },
        .atlas = .{ g.region.x, g.region.y },
        .color = color,
        .kind = switch (g.format) {
            .gray => .glyph,
            .rgba => .color_glyph,
            .lcd => .lcd_glyph,
        },
    };
}

/// A solid rectangle within cell (x, y), `dy` pixels below its top.
fn rect(m: font.Grid.Metrics, x: u32, y: u32, dy: u32, w: u32, h: u32, color: RGB) Instance {
    return rectA(m, x, y, dy, w, h, color, 255);
}

fn rectA(m: font.Grid.Metrics, x: u32, y: u32, dy: u32, w: u32, h: u32, color: RGB, alpha: u8) Instance {
    return .{
        .pos = .{ @floatFromInt(x * m.cell_width), @floatFromInt(y * m.cell_height + dy) },
        .size = .{ @floatFromInt(w), @floatFromInt(h) },
        .color = pack(color, alpha),
        .kind = .rect,
    };
}

/// A solid rectangle within cell (x, y), `dx` pixels right of its left.
fn rectX(m: font.Grid.Metrics, x: u32, y: u32, dx: u32, w: u32, h: u32, color: RGB) Instance {
    var r = rect(m, x, y, 0, w, h, color);
    r.pos[0] += @floatFromInt(dx);
    return r;
}

/// RGBA8, red in the low byte. Unpacked by `unpack` in shaders.hlsl.
fn pack(c: RGB, a: u8) u32 {
    return @as(u32, c.r) | @as(u32, c.g) << 8 | @as(u32, c.b) << 16 | @as(u32, a) << 24;
}

pub fn toFloat(c: RGB) [4]f32 {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
        1.0,
    };
}

/// A cell's grapheme as codepoints: the base codepoint followed by any
/// extra ones (combining marks, ZWJ sequences, variation selectors).
fn graphemeCodepoints(raw: ghostty_vt.Cell, extra: []const u21, buf: *[Cells.max_grapheme]u21) []const u21 {
    buf[0] = raw.codepoint();
    if (!raw.hasGrapheme()) return buf[0..1];
    const n = @min(extra.len, buf.len - 1);
    @memcpy(buf[1..][0..n], extra[0..n]);
    return buf[0 .. n + 1];
}
