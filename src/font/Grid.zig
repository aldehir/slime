//! Fonts for a terminal grid: the primary family's four style faces plus
//! any fallback faces discovered along the way, cell metrics at the
//! current size, the shaper, and the atlas of rasterized glyphs.
//!
//! Faces are identified by `FaceId`, an index into `faces`. Glyphs are
//! cached by (face, glyph index), never by codepoint: after shaping, one
//! codepoint can become different glyphs depending on its neighbors.
const Grid = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const dwrite = win32.dwrite;
const analysis = @import("analysis.zig");
const Atlas = @import("Atlas.zig");
const Face = @import("Face.zig");
const Shaper = @import("Shaper.zig");

const log = std.log.scoped(.font);

/// Families tried in order until one is installed. Cascadia Code is
/// Cascadia Mono with programming ligatures.
const default_families = [_][:0]const u16{
    std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Code"),
    std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono"),
    std.unicode.utf8ToUtf16LeStringLiteral("Consolas"),
    std.unicode.utf8ToUtf16LeStringLiteral("Courier New"),
};

/// Preferred for graphemes requesting emoji presentation (U+FE0F).
const emoji_family = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji");

pub const FaceId = u16;

pub const Style = enum(u2) {
    regular,
    bold,
    italic,
    bold_italic,

    pub fn init(bold: bool, italic: bool) Style {
        return @enumFromInt(@as(u2, @intFromBool(bold)) | @as(u2, @intFromBool(italic)) << 1);
    }

    fn weight(self: Style) dwrite.FONT_WEIGHT {
        return if (self == .bold or self == .bold_italic) .BOLD else .NORMAL;
    }

    fn fontStyle(self: Style) dwrite.FONT_STYLE {
        return if (self == .italic or self == .bold_italic) .ITALIC else .NORMAL;
    }

    /// The primary family's face for this style.
    fn primary(self: Style) FaceId {
        return @intFromEnum(self);
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
/// to the pen position at the top-left corner of its cell.
pub const Glyph = struct {
    region: Atlas.Region,
    offset_x: i32,
    offset_y: i32,
};

const GlyphKey = struct {
    face: FaceId,
    index: u16,
};

const FaceKey = struct {
    style: Style,
    cp: u21,
    emoji: bool,
};

alloc: Allocator,
factory: *dwrite.IFactory2,
collection: *dwrite.IFontCollection,
fallback: *dwrite.IFontFallback,
family: [:0]const u16,

/// The primary family's styles occupy the first four entries, in `Style`
/// order. Fallback faces are appended as they are discovered.
faces: std.ArrayList(Face) = .empty,

shaper: Shaper,
size_pt: f32,
em_px: f32,
metrics: Metrics,
atlas: Atlas,

/// Which face renders a grapheme, keyed by its first codepoint.
face_for: std.AutoHashMapUnmanaged(FaceKey, FaceId) = .empty,

/// Rasterized glyphs. Null means "nothing to draw" (blank glyph).
glyphs: std.AutoHashMapUnmanaged(GlyphKey, ?Glyph) = .empty,

/// `families` are tried in order (UTF-8), then the defaults.
pub fn init(alloc: Allocator, families: []const []const u8, size_pt: f32, dpi: u32) !Grid {
    var factory: ?*dwrite.IFactory2 = null;
    try com.check(
        dwrite.DWriteCreateFactory(dwrite.FACTORY_TYPE_SHARED, &dwrite.IFactory2.iid, @ptrCast(&factory)),
        "DWriteCreateFactory",
    );
    errdefer com.releaseOpt(&factory);

    var collection: ?*dwrite.IFontCollection = null;
    try com.check(factory.?.getSystemFontCollection(&collection), "IDWriteFactory::GetSystemFontCollection");
    errdefer com.releaseOpt(&collection);

    var fallback: ?*dwrite.IFontFallback = null;
    try com.check(factory.?.getSystemFontFallback(&fallback), "IDWriteFactory2::GetSystemFontFallback");
    errdefer com.releaseOpt(&fallback);

    const family = try findFamily(alloc, collection.?, families);
    errdefer alloc.free(family);
    log.info("using font family {f}", .{std.unicode.fmtUtf16Le(family)});

    var shaper: Shaper = try .init(alloc, factory.?);
    errdefer shaper.deinit(alloc);

    var atlas: Atlas = try .init(alloc, 512);
    errdefer atlas.deinit(alloc);

    var self: Grid = .{
        .alloc = alloc,
        .factory = factory.?,
        .collection = collection.?,
        .fallback = fallback.?,
        .family = family,
        .shaper = shaper,
        .size_pt = size_pt,
        .em_px = undefined,
        .metrics = undefined,
        .atlas = atlas,
    };
    errdefer self.deinitFaces();

    for (std.enums.values(Style)) |style| {
        try self.faces.ensureUnusedCapacity(alloc, 1);
        self.faces.appendAssumeCapacity(try .init(collection.?, family, style.weight(), style.fontStyle()));
    }

    self.setDpi(dpi);
    return self;
}

pub fn deinit(self: *Grid) void {
    self.glyphs.deinit(self.alloc);
    self.face_for.deinit(self.alloc);
    self.atlas.deinit(self.alloc);
    self.shaper.deinit(self.alloc);
    self.deinitFaces();
    com.release(self.fallback);
    com.release(self.collection);
    com.release(self.factory);
    self.alloc.free(self.family);
    self.* = undefined;
}

/// The first installed family of `families`, then of the defaults, as an
/// owned UTF-16 string.
fn findFamily(alloc: Allocator, collection: *dwrite.IFontCollection, families: []const []const u8) ![:0]const u16 {
    for (families) |utf8| {
        const name = std.unicode.utf8ToUtf16LeAllocZ(alloc, utf8) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        if (familyExists(collection, name)) return name;
        alloc.free(name);
        log.warn("font family \"{s}\" not found", .{utf8});
    }
    for (default_families) |name| {
        if (familyExists(collection, name)) return alloc.dupeZ(u16, name);
    }
    return error.FontNotFound;
}

fn familyExists(collection: *dwrite.IFontCollection, name: [:0]const u16) bool {
    var index: u32 = 0;
    var exists: win32.BOOL = win32.FALSE;
    return collection.findFamilyName(name.ptr, &index, &exists) >= 0 and exists != win32.FALSE;
}

fn deinitFaces(self: *Grid) void {
    for (self.faces.items) |*f| f.deinit();
    self.faces.deinit(self.alloc);
}

/// Recompute metrics for a new DPI and drop everything size dependent.
/// Face assignments stay valid: they don't depend on size.
pub fn setDpi(self: *Grid, dpi: u32) void {
    self.em_px = self.size_pt * @as(f32, @floatFromInt(dpi)) / 72.0;
    self.metrics = self.computeMetrics();
    self.glyphs.clearRetainingCapacity();
    self.atlas.reset();
    self.shaper.reset();
    log.info("dpi={d} em={d:.2}px cell={d}x{d}", .{
        dpi,
        self.em_px,
        self.metrics.cell_width,
        self.metrics.cell_height,
    });
}

/// Call once per frame before shaping.
pub fn beginFrame(self: *Grid) void {
    self.shaper.trim();
}

/// The face that renders a grapheme, given all its codepoints. The
/// primary face is used whenever it has the first codepoint, unless the
/// grapheme asks for emoji presentation; otherwise DirectWrite's system
/// fallback picks one.
pub fn faceFor(self: *Grid, style: Style, cps: []const u21) !FaceId {
    const emoji = std.mem.indexOfScalar(u21, cps, 0xFE0F) != null;
    const gop = try self.face_for.getOrPut(self.alloc, .{ .style = style, .cp = cps[0], .emoji = emoji });
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer self.face_for.removeByPtr(gop.key_ptr);

    gop.value_ptr.* = if (!emoji and self.faces.items[style.primary()].glyphIndex(cps[0]) != null)
        style.primary()
    else
        try self.resolveFallback(style, cps, emoji);
    return gop.value_ptr.*;
}

fn resolveFallback(self: *Grid, style: Style, cps: []const u21, emoji: bool) !FaceId {
    var buf: [32]u16 = undefined;
    const text = encodeUtf16(cps, &buf);

    var source: analysis.Source = .init(text);
    var mapped_len: u32 = 0;
    var font: ?*dwrite.IFont = null;
    var scale: f32 = 1;
    try com.check(self.fallback.mapCharacters(
        &source.iface,
        0,
        @intCast(text.len),
        self.collection,
        if (emoji) emoji_family else self.family,
        style.weight(),
        style.fontStyle(),
        &mapped_len,
        &font,
        &scale,
    ), "IDWriteFontFallback::MapCharacters");
    defer com.releaseOpt(&font);

    // Nothing installed covers it: the primary face draws .notdef.
    const f = font orelse return style.primary();
    var face: Face = try .fromFont(f);
    errdefer face.deinit();

    // DirectWrite hands out the same IDWriteFontFace for the same font,
    // so different codepoints resolving to one font share a FaceId.
    for (self.faces.items, 0..) |existing, i| {
        if (existing.face == face.face) {
            face.deinit();
            return @intCast(i);
        }
    }

    const id: FaceId = @intCast(self.faces.items.len);
    try self.faces.append(self.alloc, face);
    var name_buf: [64]u16 = undefined;
    log.info("fallback face {d}: {f} (for U+{X:0>4})", .{
        id,
        std.unicode.fmtUtf16Le(Face.familyName(f, &name_buf)),
        cps[0],
    });
    return id;
}

/// Shape a run of text in one face. See `Shaper.shape`.
pub fn shape(self: *Grid, face: FaceId, text: []const u16, text_cells: []const u16) ![]const Shaper.Glyph {
    return self.shaper.shape(self.alloc, self.faces.items[face].face, face, self.em_px, text, text_cells);
}

/// Get (rasterizing on first use) a glyph by face and glyph index.
pub fn glyph(self: *Grid, face_id: FaceId, index: u16) !?Glyph {
    const gop = try self.glyphs.getOrPut(self.alloc, .{ .face = face_id, .index = index });
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer self.glyphs.removeByPtr(gop.key_ptr);

    var bitmap = try self.faces.items[face_id].rasterize(self.alloc, self.factory, index, self.em_px);
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
    const face = &self.faces.items[Style.regular.primary()];
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

/// Encode codepoints as UTF-16 into `buf`, truncating at a codepoint
/// boundary if it doesn't fit.
pub fn encodeUtf16(cps: []const u21, buf: []u16) []const u16 {
    var len: usize = 0;
    for (cps) |cp| {
        const units: usize = if (cp > 0xFFFF) 2 else 1;
        if (len + units > buf.len) break;
        if (cp > 0xFFFF) {
            const v = cp - 0x10000;
            buf[len] = @intCast(0xD800 + (v >> 10));
            buf[len + 1] = @intCast(0xDC00 + (v & 0x3FF));
        } else {
            buf[len] = @intCast(cp);
        }
        len += units;
    }
    return buf[0..len];
}

test "encodeUtf16 surrogate pairs" {
    var buf: [8]u16 = undefined;
    const out = encodeUtf16(&.{ 'a', 0x1F600, 0xFE0F }, &buf);
    try std.testing.expectEqualSlices(u16, &.{ 'a', 0xD83D, 0xDE00, 0xFE0F }, out);
}

test "Style.init" {
    try std.testing.expectEqual(Style.bold_italic, Style.init(true, true));
    try std.testing.expectEqual(Style.italic, Style.init(false, true));
}
