//! Kitty graphics: the images slime sent for a pane and where its last
//! frame placed them, laid out for the renderer. Independent of the
//! graphics API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const frame = @import("frame");

const log = std.log.scoped(.image);

/// Placements with a z-index below this are drawn under cell
/// backgrounds, as in kitty; others below 0 under text, the rest above.
const below_bg_z = std.math.minInt(i32) / 2;

/// One placed image. Must match `ImagePlacement` in shaders.hlsl.
pub const Placement = extern struct {
    /// Top-left in pixels from the grid origin.
    pos: [2]f32,
    size: [2]f32,
    /// The source rectangle in image pixels.
    src_pos: [2]f32,
    src_size: [2]f32,
};

pub const Image = struct {
    generation: u64,
    width: u32,
    height: u32,
    /// Premultiplied RGBA, until the renderer has uploaded it.
    rgba: ?[]u8,
};

pub const Layer = enum { below_bg, below_text, above_text };

pub const Images = struct {
    /// Every image slime sent that no frame has dropped, by kitty image
    /// ID. The renderer keeps a texture of each.
    images: std.AutoArrayHashMapUnmanaged(u32, Image) = .empty,
    /// Placements in the viewport, in draw order (by z).
    placements: std.ArrayList(Placement) = .empty,
    /// The image of each placement, parallel to `placements`.
    placement_ids: std.ArrayList(u32) = .empty,
    /// Where the below-text and above-text layers start in `placements`.
    below_text_start: usize = 0,
    above_text_start: usize = 0,

    sorted: std.ArrayList(Sorted) = .empty,

    const Sorted = struct {
        z: i32,
        id: u32,
        placement: Placement,

        fn lessThan(_: void, a: Sorted, b: Sorted) bool {
            return a.z < b.z or (a.z == b.z and a.id < b.id);
        }
    };

    pub fn deinit(self: *Images, alloc: Allocator) void {
        for (self.images.values()) |*img| freePixels(alloc, img);
        self.images.deinit(alloc);
        self.placements.deinit(alloc);
        self.placement_ids.deinit(alloc);
        self.sorted.deinit(alloc);
    }

    /// The range of one layer's placements in `placements`.
    pub fn layer(self: *const Images, l: Layer) struct { usize, usize } {
        return switch (l) {
            .below_bg => .{ 0, self.below_text_start },
            .below_text => .{ self.below_text_start, self.above_text_start },
            .above_text => .{ self.above_text_start, self.placements.items.len },
        };
    }

    /// Free an image's pixels once the renderer has them.
    pub fn freePixels(alloc: Allocator, img: *Image) void {
        if (img.rgba) |rgba| alloc.free(rgba);
        img.rgba = null;
    }

    /// Take an image slime sent, in place of any with its id. Its
    /// pixels are owned from here, whether or not this fails.
    pub fn put(self: *Images, alloc: Allocator, id: u32, img: Image) !void {
        const gop = try self.images.getOrPut(alloc, id);
        if (gop.found_existing) freePixels(alloc, gop.value_ptr);
        gop.value_ptr.* = img;
    }

    /// Forget an image a frame dropped.
    pub fn remove(self: *Images, alloc: Allocator, id: u32) void {
        if (self.images.fetchSwapRemove(id)) |kv| {
            var img = kv.value;
            freePixels(alloc, &img);
        }
    }

    /// Lay out a frame's placements in draw order on a grid of the given
    /// cell size. One of an image that hasn't arrived is left out.
    pub fn update(self: *Images, alloc: Allocator, placements: []const frame.Placement, cell_width: u32, cell_height: u32) !void {
        self.sorted.clearRetainingCapacity();
        defer self.split(alloc) catch |err| log.warn("placements dropped: {}", .{err});
        const cw: f32 = @floatFromInt(cell_width);
        const ch: f32 = @floatFromInt(cell_height);
        for (placements) |p| {
            if (!self.images.contains(p.image_id)) continue;
            if (p.width == 0 or p.height == 0) continue;
            const col: f32 = @floatFromInt(p.x);
            const row: f32 = @floatFromInt(p.y);
            try self.sorted.append(alloc, .{ .z = p.z, .id = p.image_id, .placement = .{
                .pos = .{ col * cw + @as(f32, @floatFromInt(p.offset_x)), row * ch + @as(f32, @floatFromInt(p.offset_y)) },
                .size = .{ @floatFromInt(p.width), @floatFromInt(p.height) },
                .src_pos = .{ @floatFromInt(p.src_x), @floatFromInt(p.src_y) },
                .src_size = .{ @floatFromInt(p.src_width), @floatFromInt(p.src_height) },
            } });
        }
    }

    /// Sort the gathered placements into draw order and find the layers.
    fn split(self: *Images, alloc: Allocator) !void {
        self.placements.clearRetainingCapacity();
        self.placement_ids.clearRetainingCapacity();
        std.mem.sortUnstable(Sorted, self.sorted.items, {}, Sorted.lessThan);

        self.below_text_start = self.sorted.items.len;
        self.above_text_start = self.sorted.items.len;
        for (self.sorted.items, 0..) |s, i| {
            if (s.z >= below_bg_z) self.below_text_start = @min(self.below_text_start, i);
            if (s.z >= 0) self.above_text_start = @min(self.above_text_start, i);
        }

        try self.placements.ensureTotalCapacity(alloc, self.sorted.items.len);
        try self.placement_ids.ensureTotalCapacity(alloc, self.sorted.items.len);
        for (self.sorted.items) |s| {
            self.placements.appendAssumeCapacity(s.placement);
            self.placement_ids.appendAssumeCapacity(s.id);
        }
    }
};

/// Premultiply straight RGBA, as the renderer blends it.
pub fn premultiply(rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u16 = rgba[i + 3];
        if (a == 255) continue;
        for (rgba[i..][0..3]) |*c| c.* = @intCast((@as(u16, c.*) * a + 127) / 255);
    }
}

test "placements lay out by layer, without images not yet here" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var images: Images = .{};
    defer images.deinit(alloc);
    try images.put(alloc, 1, .{ .generation = 1, .width = 4, .height = 4, .rgba = try alloc.dupe(u8, &[_]u8{0xff} ** 64) });
    try images.put(alloc, 2, .{ .generation = 1, .width = 1, .height = 1, .rgba = try alloc.dupe(u8, &[_]u8{ 1, 2, 3, 4 }) });

    const place = struct {
        fn f(id: u32, z: i32, x: u16, y: i32) frame.Placement {
            return .{ .image_id = id, .z = z, .x = x, .y = y, .offset_x = 1, .offset_y = 2, .width = 30, .height = 40, .src_x = 0, .src_y = 0, .src_width = 4, .src_height = 4 };
        }
    }.f;
    try images.update(alloc, &.{
        place(1, 5, 2, 1),
        place(2, -1, 0, -1),
        place(1, below_bg_z - 1, 3, 3),
        place(9, 0, 0, 0),
    }, 10, 20);
    try testing.expectEqual(3, images.placements.items.len);
    try testing.expectEqualSlices(u32, &.{ 1, 2, 1 }, images.placement_ids.items);
    try testing.expectEqual(.{ 0, 1 }, images.layer(.below_bg));
    try testing.expectEqual(.{ 1, 2 }, images.layer(.below_text));
    try testing.expectEqual(.{ 2, 3 }, images.layer(.above_text));
    // Above the viewport by a row.
    try testing.expectEqual([2]f32{ 1, -18 }, images.placements.items[1].pos);
    try testing.expectEqual([2]f32{ 21, 22 }, images.placements.items[2].pos);
    try testing.expectEqual([2]f32{ 30, 40 }, images.placements.items[2].size);

    // A new generation replaces the pixels; a drop frees them.
    try images.put(alloc, 2, .{ .generation = 2, .width = 1, .height = 1, .rgba = try alloc.dupe(u8, &[_]u8{ 5, 6, 7, 8 }) });
    try testing.expectEqual(2, images.images.get(2).?.generation);
    images.remove(alloc, 1);
    images.remove(alloc, 7);
    try images.update(alloc, &.{place(1, 5, 2, 1)}, 10, 20);
    try testing.expectEqual(0, images.placements.items.len);
}

test premultiply {
    var px = [_]u8{ 200, 100, 0, 128, 10, 20, 30, 255 };
    premultiply(&px);
    try std.testing.expectEqualSlices(u8, &.{ 100, 50, 0, 128, 10, 20, 30, 255 }, &px);
}
