//! A single DirectWrite font face (one family + weight + style).
//!
//! IDWriteFontFace is size independent; the em size is only applied
//! when rasterizing, so one Face serves every font size and DPI.
const Face = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const dwrite = win32.dwrite;
const Atlas = @import("Atlas.zig");

face: *dwrite.IFontFace,
metrics: dwrite.FONT_METRICS,
/// Whether the face has color glyphs (COLR layers), like Segoe UI Emoji.
color: bool,

pub const Error = com.Error || error{FontNotFound};

/// How glyph edges are smoothed. Color glyphs are always grayscale.
pub const Antialias = enum {
    grayscale,
    /// Per-subpixel coverage, for RGB-striped displays.
    cleartype,
    /// No smoothing: pixels are on or off.
    aliased,
};

pub fn init(
    collection: *dwrite.IFontCollection,
    family: [:0]const u16,
    weight: dwrite.FONT_WEIGHT,
    style: dwrite.FONT_STYLE,
) Error!Face {
    var index: u32 = 0;
    var exists: win32.BOOL = win32.FALSE;
    try com.check(collection.findFamilyName(family.ptr, &index, &exists), "IDWriteFontCollection::FindFamilyName");
    if (exists == win32.FALSE) return error.FontNotFound;

    var font_family: ?*dwrite.IFontFamily = null;
    try com.check(collection.getFontFamily(index, &font_family), "IDWriteFontCollection::GetFontFamily");
    defer com.releaseOpt(&font_family);

    // DirectWrite simulates bold/oblique if the family lacks that face.
    var font: ?*dwrite.IFont = null;
    try com.check(
        font_family.?.getFirstMatchingFont(weight, dwrite.FONT_STRETCH_NORMAL, style, &font),
        "IDWriteFontFamily::GetFirstMatchingFont",
    );
    defer com.releaseOpt(&font);

    return fromFont(font.?);
}

pub fn fromFont(font: *dwrite.IFont) com.Error!Face {
    var face: ?*dwrite.IFontFace = null;
    try com.check(font.createFontFace(&face), "IDWriteFont::CreateFontFace");

    var metrics: dwrite.FONT_METRICS = undefined;
    face.?.getMetrics(&metrics);
    const color = if (com.query(face.?, dwrite.IFontFace2)) |face2| color: {
        defer com.release(face2);
        break :color face2.isColorFont();
    } else false;
    return .{ .face = face.?, .metrics = metrics, .color = color };
}

/// The font's family name (first localized name), for logging.
pub fn familyName(font: *dwrite.IFont, buf: []u16) []const u16 {
    var family: ?*dwrite.IFontFamily = null;
    if (font.getFontFamily(&family) < 0) return &.{};
    defer com.releaseOpt(&family);
    var names: ?*dwrite.ILocalizedStrings = null;
    if (family.?.getFamilyNames(&names) < 0) return &.{};
    defer com.releaseOpt(&names);
    if (names.?.getString(0, buf) < 0) return &.{};
    return std.mem.sliceTo(buf, 0);
}

pub fn deinit(self: *Face) void {
    com.release(self.face);
    self.* = undefined;
}

/// The glyph index for a codepoint, or null if the face doesn't have it.
pub fn glyphIndex(self: *const Face, cp: u21) ?u16 {
    const cps = [_]u32{cp};
    var glyphs = [_]u16{0};
    if (self.face.getGlyphIndices(&cps, &glyphs) < 0) return null;
    return if (glyphs[0] == 0) null else glyphs[0];
}

/// Horizontal advance of a glyph in design units.
pub fn advance(self: *const Face, glyph: u16) ?u32 {
    const glyphs = [_]u16{glyph};
    var metrics: [1]dwrite.GLYPH_METRICS = undefined;
    if (self.face.getDesignGlyphMetrics(&glyphs, &metrics) < 0) return null;
    return metrics[0].advanceWidth;
}

pub const Bitmap = struct {
    /// Bitmap position relative to the pen position on the baseline.
    /// `top` is negative above the baseline.
    left: i32,
    top: i32,
    width: u32,
    height: u32,
    /// Coverage for most glyphs (`.lcd` with ClearType), premultiplied
    /// RGBA for color glyphs.
    format: Atlas.Format,
    /// Tightly packed rows. Empty for blank glyphs.
    pixels: []u8,

    pub fn deinit(self: *Bitmap, alloc: Allocator) void {
        alloc.free(self.pixels);
        self.* = undefined;
    }
};

/// Rasterize a glyph at `em_px` pixels per em: coverage, or for a color
/// glyph, its layers composited in palette 0.
pub fn rasterize(
    self: *const Face,
    alloc: Allocator,
    factory: *dwrite.IFactory2,
    glyph: u16,
    em_px: f32,
    antialias: Antialias,
) (com.Error || Allocator.Error)!Bitmap {
    const glyphs = [_]u16{glyph};
    const advances = [_]f32{0};
    const run: dwrite.GLYPH_RUN = .{
        .fontFace = self.face,
        .fontEmSize = em_px,
        .glyphCount = 1,
        .glyphIndices = &glyphs,
        .glyphAdvances = &advances,
    };

    if (self.color) {
        if (try rasterizeColor(alloc, factory, &run)) |bitmap| return bitmap;
    }

    const c = try coverage(alloc, factory, &run, 0, 0, antialias);
    var bitmap: Bitmap = .{
        .left = c.bounds.left,
        .top = c.bounds.top,
        .width = c.width(),
        .height = c.height(),
        .format = .gray,
        .pixels = c.pixels,
    };
    if (antialias != .cleartype) return bitmap;

    // Pad each pixel's three subpixels out to a texel.
    defer alloc.free(c.pixels);
    bitmap.format = .lcd;
    bitmap.pixels = try alloc.alloc(u8, c.pixels.len / 3 * 4);
    for (0..c.pixels.len / 3) |i| {
        const rgb = c.pixels[i * 3 ..][0..3];
        bitmap.pixels[i * 4 ..][0..4].* = .{ rgb[0], rgb[1], rgb[2], @max(rgb[0], rgb[1], rgb[2]) };
    }
    return bitmap;
}

const Coverage = struct {
    bounds: win32.RECT,
    pixels: []u8,

    fn width(self: Coverage) u32 {
        return @intCast(@max(0, self.bounds.right - self.bounds.left));
    }

    fn height(self: Coverage) u32 {
        return @intCast(@max(0, self.bounds.bottom - self.bounds.top));
    }
};

/// Coverage of `run` with its baseline origin at (`x`, `y`): a byte per
/// pixel, or with ClearType, three (red, green, blue subpixels).
fn coverage(
    alloc: Allocator,
    factory: *dwrite.IFactory2,
    run: *const dwrite.GLYPH_RUN,
    x: f32,
    y: f32,
    antialias: Antialias,
) (com.Error || Allocator.Error)!Coverage {
    var analysis: ?*dwrite.IGlyphRunAnalysis = null;
    try com.check(factory.createGlyphRunAnalysis(
        run,
        if (antialias == .aliased) dwrite.RENDERING_MODE_ALIASED else dwrite.RENDERING_MODE_NATURAL_SYMMETRIC,
        dwrite.MEASURING_MODE_NATURAL,
        dwrite.GRID_FIT_MODE_DEFAULT,
        if (antialias == .cleartype) dwrite.TEXT_ANTIALIAS_MODE_CLEARTYPE else dwrite.TEXT_ANTIALIAS_MODE_GRAYSCALE,
        x,
        y,
        &analysis,
    ), "IDWriteFactory2::CreateGlyphRunAnalysis");
    defer com.releaseOpt(&analysis);

    // The analysis only fills the texture type matching its modes. For
    // grayscale the 1x1 texture holds coverage values, not just on/off
    // pixels.
    const texture, const depth: usize = if (antialias == .cleartype)
        .{ dwrite.TEXTURE_CLEARTYPE_3x1, 3 }
    else
        .{ dwrite.TEXTURE_ALIASED_1x1, 1 };
    var c: Coverage = .{ .bounds = undefined, .pixels = &.{} };
    try com.check(
        analysis.?.getAlphaTextureBounds(texture, &c.bounds),
        "IDWriteGlyphRunAnalysis::GetAlphaTextureBounds",
    );

    c.pixels = try alloc.alloc(u8, @as(usize, c.width()) * c.height() * depth);
    errdefer alloc.free(c.pixels);
    if (c.pixels.len > 0) {
        try com.check(
            analysis.?.createAlphaTexture(texture, &c.bounds, c.pixels),
            "IDWriteGlyphRunAnalysis::CreateAlphaTexture",
        );
    }
    return c;
}

/// A color glyph's layers drawn over each other, or null if `run`'s
/// glyph has no color layers (color fonts have plain glyphs too).
fn rasterizeColor(
    alloc: Allocator,
    factory: *dwrite.IFactory2,
    run: *const dwrite.GLYPH_RUN,
) (com.Error || Allocator.Error)!?Bitmap {
    var enumerator: ?*dwrite.IColorGlyphRunEnumerator = null;
    const hr = factory.translateColorGlyphRun(0, 0, run, &enumerator);
    if (hr == dwrite.E_NOCOLOR) return null;
    try com.check(hr, "IDWriteFactory2::TranslateColorGlyphRun");
    defer com.releaseOpt(&enumerator);

    const Layer = struct { coverage: Coverage, color: [4]u8 };
    var layers: std.ArrayList(Layer) = .empty;
    defer {
        for (layers.items) |l| alloc.free(l.coverage.pixels);
        layers.deinit(alloc);
    }

    // A layer's run is only valid until the next MoveNext, so each is
    // rasterized as it comes.
    var bounds: win32.RECT = .{
        .left = std.math.maxInt(i32),
        .top = std.math.maxInt(i32),
        .right = std.math.minInt(i32),
        .bottom = std.math.minInt(i32),
    };
    while (true) {
        var has_run: win32.BOOL = win32.FALSE;
        try com.check(enumerator.?.moveNext(&has_run), "IDWriteColorGlyphRunEnumerator::MoveNext");
        if (has_run == win32.FALSE) break;
        var layer: ?*const dwrite.COLOR_GLYPH_RUN = null;
        try com.check(enumerator.?.getCurrentRun(&layer), "IDWriteColorGlyphRunEnumerator::GetCurrentRun");
        const l = layer.?;

        try layers.ensureUnusedCapacity(alloc, 1);
        const c = try coverage(alloc, factory, &l.glyphRun, l.baselineOriginX, l.baselineOriginY, .grayscale);
        layers.appendAssumeCapacity(.{ .coverage = c, .color = layerColor(l) });
        if (c.pixels.len == 0) continue;
        bounds.left = @min(bounds.left, c.bounds.left);
        bounds.top = @min(bounds.top, c.bounds.top);
        bounds.right = @max(bounds.right, c.bounds.right);
        bounds.bottom = @max(bounds.bottom, c.bounds.bottom);
    }
    if (bounds.right <= bounds.left) bounds = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };

    const out: Coverage = .{ .bounds = bounds, .pixels = &.{} };
    const w = out.width();
    const pixels = try alloc.alloc(u8, @as(usize, w) * out.height() * 4);
    @memset(pixels, 0);

    // Premultiplied source over destination, layer by layer.
    for (layers.items) |l| {
        const c = l.coverage;
        const lw = c.width();
        const dx: usize = @intCast(c.bounds.left - bounds.left);
        const dy: usize = @intCast(c.bounds.top - bounds.top);
        for (0..c.height()) |y| {
            for (0..lw) |x| {
                const a: u32 = c.pixels[y * lw + x];
                if (a == 0) continue;
                const dst = pixels[((dy + y) * w + dx + x) * 4 ..][0..4];
                const src_a = mul255(l.color[3], a);
                for (dst, l.color) |*d, s| {
                    d.* = @intCast(mul255(s, a) + mul255(d.*, 255 - src_a));
                }
            }
        }
    }

    return .{
        .left = bounds.left,
        .top = bounds.top,
        .width = w,
        .height = out.height(),
        .format = .rgba,
        .pixels = pixels,
    };
}

/// A layer's color as premultiplied RGBA bytes. Layers in the text color
/// are drawn white: glyphs are cached without their cell's colors.
fn layerColor(layer: *const dwrite.COLOR_GLYPH_RUN) [4]u8 {
    if (layer.paletteIndex == dwrite.NO_PALETTE_INDEX) return .{ 255, 255, 255, 255 };
    const c = layer.runColor;
    const a = std.math.clamp(c.a, 0, 1);
    var out: [4]u8 = undefined;
    for (out[0..3], [_]f32{ c.r, c.g, c.b }) |*o, v| {
        o.* = @intFromFloat(@round(std.math.clamp(v, 0, 1) * a * 255));
    }
    out[3] = @intFromFloat(@round(a * 255));
    return out;
}

/// `a * b / 255`, rounded.
fn mul255(a: u32, b: u32) u32 {
    const t = a * b + 128;
    return (t + (t >> 8)) >> 8;
}

test "mul255" {
    try std.testing.expectEqual(255, mul255(255, 255));
    try std.testing.expectEqual(0, mul255(0, 255));
    try std.testing.expectEqual(128, mul255(255, 128));
    try std.testing.expectEqual(64, mul255(128, 128));
}
