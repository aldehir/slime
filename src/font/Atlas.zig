//! A texture atlas, 8-bit coverage or RGBA, using shelf packing.
//!
//! Glyphs are packed left to right into horizontal shelves. A glyph goes
//! on the first shelf that is tall enough (but not wastefully tall) and
//! has room; otherwise a new shelf is opened below the last one. When
//! the atlas is full it doubles in both dimensions. Existing regions keep
//! their coordinates when growing, so cached glyphs stay valid.
//!
//! The pixel data lives on the CPU. Renderers compare `generation` to
//! know when to re-upload it, and `size` to know when to reallocate.
const Atlas = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Empty pixels between regions so linear sampling (or rounding) never
/// bleeds a neighbor in.
const padding = 1;

/// Shelves taller than this multiple of a glyph's height won't take it.
const max_shelf_waste = 1.5;

data: []u8,
size: u32,
format: Format,
shelves: std.ArrayList(Shelf) = .empty,

/// Bumped on every modification.
generation: u64 = 0,

/// Bumped by `reset`, which invalidates every region handed out.
resets: u32 = 0,

pub const Format = enum {
    /// One byte of coverage per pixel.
    gray,
    /// Premultiplied RGBA, four bytes per pixel.
    rgba,

    pub fn depth(self: Format) u32 {
        return switch (self) {
            .gray => 1,
            .rgba => 4,
        };
    }
};

pub const Region = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const Shelf = struct {
    y: u32,
    height: u32,
    /// Next free x position.
    x: u32,
};

pub const Error = Allocator.Error || error{AtlasTooLarge};

/// Largest texture size guaranteed by D3D feature level 11.
pub const max_size = 16384;

pub fn init(alloc: Allocator, size: u32, format: Format) Allocator.Error!Atlas {
    const data = try alloc.alloc(u8, @as(usize, size) * size * format.depth());
    @memset(data, 0);
    return .{ .data = data, .size = size, .format = format };
}

pub fn deinit(self: *Atlas, alloc: Allocator) void {
    alloc.free(self.data);
    self.shelves.deinit(alloc);
    self.* = undefined;
}

/// Reserve a region for a `width` x `height` bitmap and copy `pixels`
/// (tightly packed rows, in the atlas's format) into it.
pub fn insert(
    self: *Atlas,
    alloc: Allocator,
    width: u32,
    height: u32,
    pixels: []const u8,
) Error!Region {
    const depth = self.format.depth();
    std.debug.assert(pixels.len == @as(usize, width) * height * depth);
    const region = try self.reserve(alloc, width, height);
    const row_len = width * depth;
    for (0..height) |row| {
        const dst = ((region.y + row) * self.size + region.x) * depth;
        @memcpy(self.data[dst..][0..row_len], pixels[row * row_len ..][0..row_len]);
    }
    self.generation +%= 1;
    return region;
}

/// Clear all regions, e.g. after the font size changes.
pub fn reset(self: *Atlas) void {
    @memset(self.data, 0);
    self.shelves.clearRetainingCapacity();
    self.generation +%= 1;
    self.resets +%= 1;
}

fn reserve(self: *Atlas, alloc: Allocator, width: u32, height: u32) Error!Region {
    if (width == 0 or height == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };

    const w = width + padding;
    const h = height + padding;

    while (true) {
        if (self.fit(alloc, w, h)) |r| {
            return .{ .x = r.x, .y = r.y, .width = width, .height = height };
        } else |err| switch (err) {
            error.Full => try self.grow(alloc),
            else => |e| return e,
        }
    }
}

fn fit(self: *Atlas, alloc: Allocator, w: u32, h: u32) (Allocator.Error || error{Full})!struct { x: u32, y: u32 } {
    const max_height: f32 = @as(f32, @floatFromInt(h)) * max_shelf_waste;
    for (self.shelves.items) |*shelf| {
        if (shelf.height < h) continue;
        if (@as(f32, @floatFromInt(shelf.height)) > max_height) continue;
        if (shelf.x + w > self.size) continue;
        defer shelf.x += w;
        return .{ .x = shelf.x, .y = shelf.y };
    }

    const y = if (self.shelves.items.len == 0) 0 else last: {
        const last = self.shelves.items[self.shelves.items.len - 1];
        break :last last.y + last.height;
    };
    if (y + h > self.size or w > self.size) return error.Full;

    try self.shelves.append(alloc, .{ .y = y, .height = h, .x = w });
    return .{ .x = 0, .y = y };
}

fn grow(self: *Atlas, alloc: Allocator) Error!void {
    const new_size = self.size * 2;
    if (new_size > max_size) return error.AtlasTooLarge;

    const depth = self.format.depth();
    const data = try alloc.alloc(u8, @as(usize, new_size) * new_size * depth);
    @memset(data, 0);
    const row_len = self.size * depth;
    for (0..self.size) |row| {
        @memcpy(data[row * new_size * depth ..][0..row_len], self.data[row * row_len ..][0..row_len]);
    }
    alloc.free(self.data);
    self.data = data;
    self.size = new_size;
    self.generation +%= 1;
}

test "insert places glyphs on a shared shelf" {
    const alloc = std.testing.allocator;
    var atlas: Atlas = try .init(alloc, 64, .gray);
    defer atlas.deinit(alloc);

    const a = try atlas.insert(alloc, 4, 8, &@as([32]u8, @splat(1)));
    const b = try atlas.insert(alloc, 4, 7, &@as([28]u8, @splat(2)));
    try std.testing.expectEqual(@as(u32, 0), a.y);
    try std.testing.expectEqual(a.y, b.y);
    try std.testing.expectEqual(@as(u32, 5), b.x);
    try std.testing.expectEqual(@as(u8, 2), atlas.data[b.y * atlas.size + b.x]);
}

test "tall glyph opens a new shelf" {
    const alloc = std.testing.allocator;
    var atlas: Atlas = try .init(alloc, 64, .gray);
    defer atlas.deinit(alloc);

    _ = try atlas.insert(alloc, 4, 4, &@as([16]u8, @splat(1)));
    const tall = try atlas.insert(alloc, 4, 20, &@as([80]u8, @splat(1)));
    try std.testing.expectEqual(@as(u32, 5), tall.y);
}

test "grow preserves existing regions" {
    const alloc = std.testing.allocator;
    var atlas: Atlas = try .init(alloc, 16, .gray);
    defer atlas.deinit(alloc);

    const first = try atlas.insert(alloc, 10, 10, &@as([100]u8, @splat(7)));
    _ = try atlas.insert(alloc, 10, 10, &@as([100]u8, @splat(9)));
    try std.testing.expectEqual(@as(u32, 32), atlas.size);
    try std.testing.expectEqual(@as(u8, 7), atlas.data[(first.y + 9) * atlas.size + first.x + 9]);
}

test "rgba regions hold four bytes per pixel" {
    const alloc = std.testing.allocator;
    var atlas: Atlas = try .init(alloc, 16, .rgba);
    defer atlas.deinit(alloc);

    const first = try atlas.insert(alloc, 2, 1, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    _ = try atlas.insert(alloc, 10, 10, &@as([400]u8, @splat(9)));
    _ = try atlas.insert(alloc, 10, 10, &@as([400]u8, @splat(9)));
    try std.testing.expectEqual(@as(u32, 32), atlas.size);
    const at = (first.y * atlas.size + first.x) * 4;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, atlas.data[at..][0..8]);
}
