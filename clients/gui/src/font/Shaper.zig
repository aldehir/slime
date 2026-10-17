//! Shapes runs of terminal text into positioned glyphs with DirectWrite.
//!
//! Shaping applies the font's OpenType substitutions (ligatures,
//! contextual alternates, emoji sequences, combining marks), so glyphs
//! don't map 1:1 to codepoints or cells. The output assigns each glyph to
//! the cell its cluster starts in, plus a pixel offset from that cell's
//! origin. Glyph advances only matter within a cluster: cells, not the
//! font, decide where each cluster goes, so the grid never shifts.
//!
//! Shaping is expensive relative to everything else in a frame, so
//! results are cached by run contents.
const Shaper = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("../win32/win32.zig");
const com = win32.com;
const dwrite = win32.dwrite;
const analysis = @import("analysis.zig");

const log = std.log.scoped(.shaper);

/// Cached runs are dropped once there are this many.
const max_cache_entries = 8192;

/// A glyph positioned relative to the run.
pub const Glyph = struct {
    /// Glyph index in the run's font face.
    index: u16,
    /// Cell offset from the start of the run.
    cell: u16,
    /// Pixel offset from that cell's origin (y grows down).
    x: i16,
    y: i16,
};

analyzer: *dwrite.ITextAnalyzer,

/// Scratch buffers reused across shape calls.
script_runs: std.ArrayList(analysis.ScriptRun) = .empty,
cluster_map: std.ArrayList(u16) = .empty,
text_props: std.ArrayList(dwrite.SHAPING_TEXT_PROPERTIES) = .empty,
glyph_indices: std.ArrayList(u16) = .empty,
glyph_props: std.ArrayList(dwrite.SHAPING_GLYPH_PROPERTIES) = .empty,
advances: std.ArrayList(f32) = .empty,
offsets: std.ArrayList(dwrite.GLYPH_OFFSET) = .empty,
result: std.ArrayList(Glyph) = .empty,

/// Shaped runs keyed by `runHash`. Values live in `cache_arena`.
cache: std.AutoHashMapUnmanaged(u64, []const Glyph) = .empty,
cache_arena: std.heap.ArenaAllocator,

pub fn init(alloc: Allocator, factory: *dwrite.IFactory2) com.Error!Shaper {
    var analyzer: ?*dwrite.ITextAnalyzer = null;
    try com.check(factory.createTextAnalyzer(&analyzer), "IDWriteFactory::CreateTextAnalyzer");
    return .{ .analyzer = analyzer.?, .cache_arena = .init(alloc) };
}

pub fn deinit(self: *Shaper, alloc: Allocator) void {
    self.cache.deinit(alloc);
    self.cache_arena.deinit();
    inline for (.{ "script_runs", "cluster_map", "text_props", "glyph_indices", "glyph_props", "advances", "offsets", "result" }) |field| {
        @field(self, field).deinit(alloc);
    }
    com.release(self.analyzer);
    self.* = undefined;
}

/// Drop all cached runs. Required when the font size changes.
pub fn reset(self: *Shaper) void {
    self.cache.clearRetainingCapacity();
    _ = self.cache_arena.reset(.retain_capacity);
}

/// Bound the cache. Call between frames: it invalidates slices returned
/// by `shape`.
pub fn trim(self: *Shaper) void {
    if (self.cache.count() > max_cache_entries) self.reset();
}

/// Shape a run of UTF-16 `text` in one face. `text_cells[i]` is the cell
/// offset (from the run start) of `text[i]`. The result is valid until
/// the next `trim` or `reset`.
pub fn shape(
    self: *Shaper,
    alloc: Allocator,
    face: *dwrite.IFontFace,
    face_id: u16,
    em_px: f32,
    text: []const u16,
    text_cells: []const u16,
) ![]const Glyph {
    std.debug.assert(text.len == text_cells.len);
    const key = runHash(face_id, text, text_cells);
    const gop = try self.cache.getOrPut(alloc, key);
    if (gop.found_existing) return gop.value_ptr.*;
    errdefer self.cache.removeByPtr(gop.key_ptr);

    self.result.clearRetainingCapacity();
    try self.itemize(alloc, text);
    for (self.script_runs.items) |run| {
        try self.shapeScriptRun(alloc, face, em_px, run, text, text_cells);
    }

    const glyphs = try self.cache_arena.allocator().dupe(Glyph, self.result.items);
    gop.value_ptr.* = glyphs;
    return glyphs;
}

/// Split text into runs of a single script; each is shaped separately.
fn itemize(self: *Shaper, alloc: Allocator, text: []const u16) !void {
    self.script_runs.clearRetainingCapacity();
    var source: analysis.Source = .init(text);
    var sink: analysis.ScriptSink = .init(alloc, &self.script_runs);
    const hr = self.analyzer.analyzeScript(&source.iface, 0, @intCast(text.len), &sink.iface);
    if (sink.oom) return error.OutOfMemory;
    try com.check(hr, "IDWriteTextAnalyzer::AnalyzeScript");

    std.mem.sortUnstable(analysis.ScriptRun, self.script_runs.items, {}, struct {
        fn lessThan(_: void, a: analysis.ScriptRun, b: analysis.ScriptRun) bool {
            return a.pos < b.pos;
        }
    }.lessThan);
}

fn shapeScriptRun(
    self: *Shaper,
    alloc: Allocator,
    face: *dwrite.IFontFace,
    em_px: f32,
    run: analysis.ScriptRun,
    full_text: []const u16,
    full_cells: []const u16,
) !void {
    const text = full_text[run.pos..][0..run.len];
    const cells = full_cells[run.pos..][0..run.len];

    try self.cluster_map.resize(alloc, text.len);
    try self.text_props.resize(alloc, text.len);

    // DirectWrite's recommended starting estimate, grown on demand.
    var max_glyphs = 3 * text.len / 2 + 16;
    var count: u32 = 0;
    while (true) {
        try self.glyph_indices.resize(alloc, max_glyphs);
        try self.glyph_props.resize(alloc, max_glyphs);
        const hr = self.analyzer.getGlyphs(
            text,
            face,
            &run.analysis,
            analysis.locale_name,
            self.cluster_map.items,
            self.text_props.items,
            self.glyph_indices.items,
            self.glyph_props.items,
            &count,
        );
        if (hr == dwrite.E_NOT_SUFFICIENT_BUFFER) {
            max_glyphs *= 2;
            continue;
        }
        try com.check(hr, "IDWriteTextAnalyzer::GetGlyphs");
        break;
    }

    const glyphs = self.glyph_indices.items[0..count];
    try self.advances.resize(alloc, count);
    try self.offsets.resize(alloc, count);
    try com.check(self.analyzer.getGlyphPlacements(
        text,
        self.cluster_map.items,
        self.text_props.items,
        glyphs,
        self.glyph_props.items[0..count],
        face,
        em_px,
        &run.analysis,
        analysis.locale_name,
        self.advances.items,
        self.offsets.items,
    ), "IDWriteTextAnalyzer::GetGlyphPlacements");

    try placeClusters(alloc, &self.result, self.cluster_map.items, glyphs, self.advances.items, self.offsets.items, cells);
}

/// Assign shaped glyphs to cells. `cluster_map[i]` is the index of the
/// first glyph of the cluster containing text unit `i`; a cluster is
/// the run of text units sharing that value. Each cluster's glyphs go to
/// the cell of the cluster's first text unit, laid out by their advances
/// from that cell's origin.
fn placeClusters(
    alloc: Allocator,
    out: *std.ArrayList(Glyph),
    cluster_map: []const u16,
    glyphs: []const u16,
    advances: []const f32,
    offsets: []const dwrite.GLYPH_OFFSET,
    cells: []const u16,
) Allocator.Error!void {
    var i: usize = 0;
    while (i < cluster_map.len) {
        const first_glyph = cluster_map[i];

        // Find where this cluster's text, and so its glyphs, end.
        var end = i + 1;
        while (end < cluster_map.len and cluster_map[end] == first_glyph) end += 1;
        const end_glyph = if (end < cluster_map.len) cluster_map[end] else glyphs.len;

        var pen: f32 = 0;
        for (first_glyph..end_glyph) |g| {
            try out.append(alloc, .{
                .index = glyphs[g],
                .cell = cells[i],
                .x = @intFromFloat(@round(pen + offsets[g].advanceOffset)),
                .y = @intFromFloat(@round(-offsets[g].ascenderOffset)),
            });
            pen += advances[g];
        }
        i = end;
    }
}

fn runHash(face_id: u16, text: []const u16, cells: []const u16) u64 {
    var h = std.hash.Wyhash.init(face_id);
    h.update(std.mem.sliceAsBytes(text));
    h.update(std.mem.sliceAsBytes(cells));
    return h.final();
}

const testing = std.testing;
const no_offset: dwrite.GLYPH_OFFSET = .{ .advanceOffset = 0, .ascenderOffset = 0 };

test "placeClusters one glyph per cell" {
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    try placeClusters(testing.allocator, &out, &.{ 0, 1, 2 }, &.{ 10, 11, 12 }, &.{ 8, 8, 8 }, &([_]dwrite.GLYPH_OFFSET{no_offset} ** 3), &.{ 0, 1, 2 });
    try testing.expectEqual(3, out.items.len);
    for (out.items, 0..) |g, i| {
        try testing.expectEqual(i, g.cell);
        try testing.expectEqual(@as(i16, 0), g.x);
    }
}

test "placeClusters ligature spans cells" {
    // "=>" shaped into one glyph: both text units map to glyph 0.
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    try placeClusters(testing.allocator, &out, &.{ 0, 0, 1 }, &.{ 42, 7 }, &.{ 16, 8 }, &([_]dwrite.GLYPH_OFFSET{no_offset} ** 2), &.{ 0, 1, 2 });
    try testing.expectEqual(2, out.items.len);
    try testing.expectEqual(@as(u16, 42), out.items[0].index);
    try testing.expectEqual(@as(u16, 0), out.items[0].cell);
    try testing.expectEqual(@as(u16, 2), out.items[1].cell);
}

test "placeClusters combining mark stays in its base cell" {
    // "e" + U+0301: two glyphs in one cluster, the mark positioned by
    // advance and offset.
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    const offsets = [_]dwrite.GLYPH_OFFSET{ no_offset, .{ .advanceOffset = -6, .ascenderOffset = 2 } };
    try placeClusters(testing.allocator, &out, &.{ 0, 0 }, &.{ 5, 6 }, &.{ 8, 0 }, &offsets, &.{ 0, 0 });
    try testing.expectEqual(2, out.items.len);
    try testing.expectEqual(@as(u16, 0), out.items[1].cell);
    try testing.expectEqual(@as(i16, 2), out.items[1].x);
    try testing.expectEqual(@as(i16, -2), out.items[1].y);
}

test "placeClusters surrogate pair maps to one cell" {
    // A non-BMP codepoint is two UTF-16 units in one cluster.
    var out: std.ArrayList(Glyph) = .empty;
    defer out.deinit(testing.allocator);
    try placeClusters(testing.allocator, &out, &.{ 0, 0, 1 }, &.{ 99, 3 }, &.{ 32, 8 }, &([_]dwrite.GLYPH_OFFSET{no_offset} ** 2), &.{ 0, 0, 2 });
    try testing.expectEqual(2, out.items.len);
    try testing.expectEqual(@as(u16, 0), out.items[0].cell);
    try testing.expectEqual(@as(u16, 2), out.items[1].cell);
}
