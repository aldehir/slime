//! Converts a terminal RenderState into GPU-ready data: one background
//! color per cell, and a list of quads (glyphs and solid rectangles for
//! the cursor and text decorations). Independent of the graphics API.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const font = @import("../font/font.zig");

const RenderState = ghostty_vt.RenderState;
const RGB = ghostty_vt.color.RGB;

/// Shader constants. Must match `Uniforms` in shaders.hlsl, including
/// HLSL's 16-byte register packing.
pub const Uniforms = extern struct {
    screen_size: [2]f32,
    cell_size: [2]f32,
    grid_size: [2]u32,
    grid_offset: [2]f32,
    default_bg: [4]f32,
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

    pub fn deinit(self: *Cells, alloc: Allocator) void {
        self.bg.deinit(alloc);
        self.instances.deinit(alloc);
        self.* = undefined;
    }

    /// Rebuild everything from the render state. Rasterizes any glyphs
    /// not yet in the atlas.
    pub fn build(self: *Cells, alloc: Allocator, state: *const RenderState, grid: *font.Grid) !void {
        const m = grid.metrics;
        const colors = &state.colors;

        self.cols = state.cols;
        self.rows = state.rows;
        self.default_bg = colors.background;
        try self.bg.resize(alloc, @as(usize, self.cols) * self.rows);
        self.instances.clearRetainingCapacity();

        const cursor_color = colors.cursor orelse colors.foreground;
        const cursor_pos = if (state.cursor.visible) state.cursor.viewport else null;

        // A block cursor goes under the text, so it's drawn first.
        if (cursor_pos) |pos| if (state.cursor.visual_style == .block) {
            try self.instances.append(alloc, rect(m, pos.x, pos.y, 0, m.cell_width, m.cell_height, cursor_color));
        };

        const rows = state.row_data.slice();
        for (rows.items(.cells)[0..self.rows], 0..) |row_cells, y_usize| {
            const y: u32 = @intCast(y_usize);
            const cells = row_cells.slice();
            const raws = cells.items(.raw);
            const styles = cells.items(.style);

            for (raws[0..self.cols], 0..) |raw, x_usize| {
                const x: u32 = @intCast(x_usize);
                const style: ghostty_vt.Style = if (raw.hasStyling()) styles[x] else .{};

                var fg = style.fg(.{ .default = colors.foreground, .palette = &colors.palette });
                var bg = style.bg(&raw, &colors.palette) orelse colors.background;
                if (style.flags.inverse) std.mem.swap(RGB, &fg, &bg);
                self.bg.items[y * self.cols + x] = pack(bg, 255);

                if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
                const width: u32 = if (raw.wide == .wide) 2 else 1;

                // Text under a block cursor takes the cell's background
                // color so it stays readable.
                const under_cursor = if (cursor_pos) |pos|
                    state.cursor.visual_style == .block and pos.x == x and pos.y == y
                else
                    false;
                const text_color = if (under_cursor) bg else fg;
                const alpha: u8 = if (style.flags.faint) 128 else 255;

                if (raw.hasText() and !style.flags.invisible) {
                    const font_style: font.Grid.Style = .init(style.flags.bold, style.flags.italic);
                    if (try grid.glyph(raw.codepoint(), font_style)) |g| {
                        const origin_x: i32 = @intCast(x * m.cell_width);
                        const origin_y: i32 = @intCast(y * m.cell_height);
                        try self.instances.append(alloc, .{
                            .pos = .{
                                @floatFromInt(origin_x + g.offset_x),
                                @floatFromInt(origin_y + g.offset_y),
                            },
                            .size = .{ @floatFromInt(g.region.width), @floatFromInt(g.region.height) },
                            .atlas = .{ g.region.x, g.region.y },
                            .color = pack(text_color, alpha),
                            .kind = .glyph,
                        });
                    }
                }

                // TODO: distinct double/curly/dotted/dashed underlines.
                if (style.flags.underline != .none) {
                    try self.instances.append(alloc, rectA(m, x, y, m.underline_position, width * m.cell_width, m.underline_thickness, text_color, alpha));
                }
                if (style.flags.strikethrough) {
                    try self.instances.append(alloc, rectA(m, x, y, m.strikethrough_position, width * m.cell_width, m.strikethrough_thickness, text_color, alpha));
                }
            }
        }

        // Non-block cursors go over the text.
        if (cursor_pos) |pos| {
            const thick = @max(1, m.underline_thickness);
            switch (state.cursor.visual_style) {
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
    }

    pub fn uniforms(self: *const Cells, m: font.Grid.Metrics, screen_width: u32, screen_height: u32, offset: [2]f32) Uniforms {
        return .{
            .screen_size = .{ @floatFromInt(screen_width), @floatFromInt(screen_height) },
            .cell_size = .{ @floatFromInt(m.cell_width), @floatFromInt(m.cell_height) },
            .grid_size = .{ self.cols, self.rows },
            .grid_offset = offset,
            .default_bg = toFloat(self.default_bg),
        };
    }
};

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
