//! Glyphs we draw rather than take from a font: box drawing, block
//! elements, braille, Powerline symbols, geometric shapes, and Symbols
//! for Legacy Computing. They're drawn to the exact cell size, so lines
//! and blocks join seamlessly across cells, which font glyphs rarely do.
//!
//! `canvas.zig` and `draw/` are vendored from Ghostty's src/font/sprite
//! (ghostty d0e72a3ab). Changes are limited to imports, with
//! `compat.zig` standing in for Ghostty's font module, plus the spots
//! marked "slime:".

const std = @import("std");
const Allocator = std.mem.Allocator;
const z2d = @import("z2d");
const Atlas = @import("../Atlas.zig");
const Canvas = @import("canvas.zig").Canvas;

pub const Metrics = @import("compat.zig").Metrics;

/// Where a drawn glyph landed in the atlas, and its offset from the
/// top-left corner of its cell. Null when there's nothing to draw.
pub const Placement = ?struct {
    region: Atlas.Region,
    offset_x: i32,
    offset_y: i32,
};

const DrawError =
    Allocator.Error ||
    z2d.Path.Error ||
    z2d.painter.FillError ||
    z2d.painter.StrokeError ||
    error{MathError};

const DrawFn = fn (
    cp: u32,
    canvas: *Canvas,
    width: u32,
    height: u32,
    metrics: Metrics,
) DrawError!void;

const Range = struct {
    min: u32,
    max: u32,
    draw: *const DrawFn,
};

/// Every `draw<CP>` or `draw<MIN>_<MAX>` function in the draw files, as
/// in Ghostty's sprite Face.
const ranges: []const Range = ranges: {
    @setEvalBranchQuota(1_000_000);

    const structs = [_]type{
        @import("draw/block.zig"),
        @import("draw/box.zig"),
        @import("draw/braille.zig"),
        @import("draw/branch.zig"),
        @import("draw/geometric_shapes.zig"),
        @import("draw/powerline.zig"),
        @import("draw/symbols_for_legacy_computing.zig"),
        @import("draw/symbols_for_legacy_computing_supplement.zig"),
    };

    var count = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decls) |decl| {
            if (std.mem.startsWith(u8, decl.name, "draw")) count += 1;
        }
    }

    var r: [count]Range = undefined;
    var i = 0;
    for (structs) |s| {
        for (@typeInfo(s).@"struct".decls) |decl| {
            if (!std.mem.startsWith(u8, decl.name, "draw")) continue;
            const sep = std.mem.indexOfScalar(u8, decl.name, '_') orelse decl.name.len;
            const min = std.fmt.parseInt(u21, decl.name[4..sep], 16) catch unreachable;
            const max = if (sep == decl.name.len)
                min
            else
                std.fmt.parseInt(u21, decl.name[sep + 1 ..], 16) catch unreachable;
            r[i] = .{ .min = min, .max = max, .draw = &@field(s, decl.name) };
            i += 1;
        }
    }

    std.mem.sortUnstable(Range, &r, {}, struct {
        fn lessThan(_: void, a: Range, b: Range) bool {
            return a.min < b.min;
        }
    }.lessThan);
    for (r[1..], r[0 .. r.len - 1]) |b, a| {
        if (b.min <= a.max) @compileError(std.fmt.comptimePrint(
            "sprite ranges overlap: U+{X}-U+{X} and U+{X}-U+{X}",
            .{ a.min, a.max, b.min, b.max },
        ));
    }

    const fixed = r;
    break :ranges &fixed;
};

fn drawFn(cp: u32) ?*const DrawFn {
    inline for (ranges) |range| {
        if (cp >= range.min and cp <= range.max) return range.draw;
    }
    return null;
}

pub fn hasCodepoint(cp: u21) bool {
    return drawFn(cp) != null;
}

/// Draw `cp` across `cells` cells into the atlas. `io` is only for z2d,
/// which wants one for loading fonts we never use.
pub fn render(
    alloc: Allocator,
    io: std.Io,
    atlas: *Atlas,
    metrics: Metrics,
    cp: u21,
    cells: u32,
) !Placement {
    const draw = drawFn(cp) orelse return null;
    const width = metrics.cell_width * @max(1, cells);
    const height = metrics.cell_height;

    // Room to draw past the cell, as some sprites do.
    const padding_x = width / 4;
    const padding_y = height / 4;

    var canvas: Canvas = try .init(alloc, io, width, height, padding_x, padding_y);
    defer canvas.deinit();
    try draw(cp, &canvas, width, height, metrics);

    const region = try canvas.writeAtlas(alloc, atlas);
    if (region.width == 0 or region.height == 0) return null;
    return .{
        .region = region,
        .offset_x = @as(i32, @intCast(canvas.clip_left)) - @as(i32, @intCast(padding_x)),
        .offset_y = @as(i32, @intCast(canvas.clip_top)) - @as(i32, @intCast(padding_y)),
    };
}

test "ranges cover box drawing, blocks, braille, and Powerline" {
    for ([_]u21{ 0x2500, 0x257F, 0x2580, 0x259F, 0x2800, 0x28FF, 0xE0B0 }) |cp| {
        try std.testing.expect(hasCodepoint(cp));
    }
    try std.testing.expect(!hasCodepoint('A'));
}

test "a horizontal line spans the cell" {
    const alloc = std.testing.allocator;
    var atlas: Atlas = try .init(alloc, 64, .gray);
    defer atlas.deinit(alloc);

    const m: Metrics = .{
        .cell_width = 8,
        .cell_height = 16,
        .underline_position = 14,
        .underline_thickness = 1,
        .strikethrough_position = 8,
        .strikethrough_thickness = 1,
        .overline_position = 0,
        .overline_thickness = 1,
        .box_thickness = 1,
        .cursor_height = 16,
    };
    const p = (try render(alloc, std.testing.io, &atlas, m, 0x2500, 1)).?;
    try std.testing.expectEqual(0, p.offset_x);
    try std.testing.expectEqual(8, p.region.width);
}
