//! Fonts for a terminal grid: the four style faces of one family, the
//! cell metrics derived from them at the current size, and the atlas of
//! glyphs rasterized so far.
//!
//! TODO: font fallback (IDWriteFontFallback) for codepoints the primary
//! family lacks; those currently render as the family's .notdef glyph.
const Grid = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const dwrite = win32.dwrite;
const Atlas = @import("Atlas.zig");
const Face = @import("Face.zig");

const log = std.log.scoped(.font);

/// Families tried in order until one is installed.
const default_families = [_][:0]const u16{
    std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono"),
    std.unicode.utf8ToUtf16LeStringLiteral("Consolas"),
    std.unicode.utf8ToUtf16LeStringLiteral("Courier New"),
};

pub const Style = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,

    pub fn init(bold: bool, italic: bool) Style {
        return @enumFromInt(@as(u2, @intFromBool(bold)) | @as(u2, @intFromBool(italic)) << 1);
    }
};

/// Cell metrics in whole pixels. Positions are from the top of the cell.
pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,
    baseline: u32,
    underline_position: u32,
    underline_thickness: u32,
    strikethrough_position: u32,
    strikethrough_thickness: u32,
};

/// A rasterized glyph's location in the atlas and its placement relative
/// to the top-left corner of its cell.
pub const Glyph = struct {
    region: Atlas.Region,
    offset_x: i32,
    offset_y: i32,
};

const Key = struct {
    style: Style,
    cp: u21,
};

alloc: Allocator,
factory: *dwrite.IFactory2,
faces: [4]Face,
size_pt: f32,
em_px: f32,
metrics: Metrics,
atlas: Atlas,

/// Rasterized glyphs. Null means "nothing to draw" (blank glyph).
glyphs: std.AutoHashMapUnmanaged(Key, ?Glyph) = .empty,

pub fn init(alloc: Allocator, size_pt: f32, dpi: u32) !Grid {
    var factory: ?*dwrite.IFactory2 = null;
    try com.check(
        dwrite.DWriteCreateFactory(dwrite.FACTORY_TYPE_SHARED, &dwrite.IFactory2.iid, @ptrCast(&factory)),
        "DWriteCreateFactory",
    );
    errdefer com.releaseOpt(&factory);

    var collection: ?*dwrite.IFontCollection = null;
    try com.check(factory.?.getSystemFontCollection(&collection), "IDWriteFactory::GetSystemFontCollection");
    defer com.releaseOpt(&collection);

    const family = for (default_families) |name| {
        var index: u32 = 0;
        var exists: win32.BOOL = win32.FALSE;
        if (collection.?.findFamilyName(name.ptr, &index, &exists) >= 0 and exists != win32.FALSE) break name;
    } else return error.FontNotFound;
    log.info("using font family {f}", .{std.unicode.fmtUtf16Le(family)});

    var faces: [4]Face = undefined;
    var loaded: usize = 0;
    errdefer for (faces[0..loaded]) |*f| f.deinit();
    for (std.enums.values(Style)) |style| {
        const bold = style == .bold or style == .bold_italic;
        const italic = style == .italic or style == .bold_italic;
        faces[@intFromEnum(style)] = try .init(
            collection.?,
            family,
            if (bold) .BOLD else .NORMAL,
            if (italic) .ITALIC else .NORMAL,
        );
        loaded += 1;
    }

    var atlas: Atlas = try .init(alloc, 512);
    errdefer atlas.deinit(alloc);

    var self: Grid = .{
        .alloc = alloc,
        .factory = factory.?,
        .faces = faces,
        .size_pt = size_pt,
        .em_px = undefined,
        .metrics = undefined,
        .atlas = atlas,
    };
    self.setDpi(dpi);
    return self;
}

pub fn deinit(self: *Grid) void {
    self.glyphs.deinit(self.alloc);
    self.atlas.deinit(self.alloc);
    for (&self.faces) |*f| f.deinit();
    com.release(self.factory);
    self.* = undefined;
}

/// Recompute metrics for a new DPI and drop every rasterized glyph.
pub fn setDpi(self: *Grid, dpi: u32) void {
    self.em_px = self.size_pt * @as(f32, @floatFromInt(dpi)) / 72.0;
    self.metrics = self.computeMetrics();
    self.glyphs.clearRetainingCapacity();
    self.atlas.reset();
    log.info("dpi={d} em={d:.2}px cell={d}x{d}", .{
        dpi,
        self.em_px,
        self.metrics.cell_width,
        self.metrics.cell_height,
    });
}

/// Get (rasterizing on first use) the glyph for a codepoint.
pub fn glyph(self: *Grid, cp: u21, style: Style) !?Glyph {
    const gop = try self.glyphs.getOrPut(self.alloc, .{ .style = style, .cp = cp });
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer self.glyphs.removeByPtr(gop.key_ptr);

    const face = &self.faces[@intFromEnum(style)];

    // Missing glyphs rasterize glyph 0, the font's .notdef box.
    const index = face.glyphIndex(cp) orelse 0;
    var bitmap = try face.rasterize(self.alloc, self.factory, index, self.em_px);
    defer bitmap.deinit(self.alloc);

    if (bitmap.pixels.len == 0) {
        gop.value_ptr.* = null;
        return null;
    }

    const region = try self.atlas.insert(self.alloc, bitmap.width, bitmap.height, bitmap.pixels);
    gop.value_ptr.* = .{
        .region = region,
        .offset_x = bitmap.left,
        .offset_y = @as(i32, @intCast(self.metrics.baseline)) + bitmap.top,
    };
    return gop.value_ptr.*;
}

fn computeMetrics(self: *const Grid) Metrics {
    const face = &self.faces[@intFromEnum(Style.regular)];
    const m = face.metrics;
    const scale = self.em_px / @as(f32, @floatFromInt(m.designUnitsPerEm));

    const ascent = @as(f32, @floatFromInt(m.ascent)) * scale;
    const descent = @as(f32, @floatFromInt(m.descent)) * scale;
    const line_gap = @as(f32, @floatFromInt(@max(0, m.lineGap))) * scale;

    // Monospace fonts: every glyph has the advance of "M".
    const advance = face.advance(face.glyphIndex('M') orelse 0) orelse m.designUnitsPerEm / 2;
    const cell_width = @round(@as(f32, @floatFromInt(advance)) * scale);
    const cell_height = @ceil(ascent + descent + line_gap);
    const baseline = @round(line_gap / 2 + ascent);

    // DirectWrite positions are distances above the baseline.
    const underline = baseline - @as(f32, @floatFromInt(m.underlinePosition)) * scale;
    const strikethrough = baseline - @as(f32, @floatFromInt(m.strikethroughPosition)) * scale;

    return .{
        .cell_width = @intFromFloat(@max(1, cell_width)),
        .cell_height = @intFromFloat(@max(1, cell_height)),
        .baseline = @intFromFloat(baseline),
        .underline_position = @intFromFloat(@max(0, @round(underline))),
        .underline_thickness = thickness(m.underlineThickness, scale),
        .strikethrough_position = @intFromFloat(@max(0, @round(strikethrough))),
        .strikethrough_thickness = thickness(m.strikethroughThickness, scale),
    };
}

fn thickness(design: u16, scale: f32) u32 {
    return @intFromFloat(@max(1, @round(@as(f32, @floatFromInt(design)) * scale)));
}
