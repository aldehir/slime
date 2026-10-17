//! Kitty graphics: a snapshot of the active screen's images and the
//! placements in the viewport, taken under the terminal lock and drawn
//! by the renderer after it's released. Independent of the graphics API.
const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");

const kitty = ghostty_vt.kitty.graphics;

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
    /// Images still in the terminal's storage that a placement has
    /// shown, by kitty image ID.
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

    /// Rebuild the placements from the terminal's active screen, copying
    /// any image whose content changed. Call with the terminal locked.
    pub fn update(self: *Images, alloc: Allocator, t: *const ghostty_vt.Terminal) !void {
        const screen = t.screens.active;
        const storage = &screen.kitty_images;

        // Drop images the terminal deleted.
        var i: usize = 0;
        while (i < self.images.count()) {
            if (storage.imageById(self.images.keys()[i]) != null) {
                i += 1;
                continue;
            }
            freePixels(alloc, &self.images.values()[i]);
            self.images.swapRemoveAt(i);
        }

        self.sorted.clearRetainingCapacity();
        defer self.split(alloc) catch |err| log.warn("placements dropped: {}", .{err});
        if (t.cols == 0 or t.rows == 0 or storage.placements.count() == 0) return;

        const cell_width: f32 = @floatFromInt(t.width_px / t.cols);
        const cell_height: f32 = @floatFromInt(t.height_px / t.rows);
        const pages = &screen.pages;
        const top = pages.getTopLeft(.viewport);
        const bot = pages.getBottomRight(.viewport).?;
        const top_y = pages.pointFromPin(.screen, top).?.screen.y;
        const bot_y = pages.pointFromPin(.screen, bot).?.screen.y;

        var virtual = false;
        var it = storage.placements.iterator();
        while (it.next()) |kv| {
            const p = kv.value_ptr;
            const pin = switch (p.location) {
                .pin => |pin| pin,
                // Shown where placeholder cells are; see below.
                .virtual => {
                    virtual = true;
                    continue;
                },
                // TODO: relative placements.
                .relative => continue,
            };
            if (pin.garbage) continue;
            const image = storage.imageById(kv.key_ptr.image_id) orelse continue;
            if (image.data.isPending()) continue;

            const grid = p.gridSize(image, t);
            if (grid.cols == 0 or grid.rows == 0) continue;
            const y = pages.pointFromPin(.screen, pin.*).?.screen.y;
            if (y > bot_y or y + grid.rows - 1 < top_y) continue;

            const size = p.pixelSize(image, t);
            if (size.width == 0 or size.height == 0) continue;
            const offset = p.cellOffset(t);
            const src = p.sourceRect(image);

            try self.copyImage(alloc, image);
            const row: f32 = @floatFromInt(@as(i64, y) - @as(i64, top_y));
            const col: f32 = @floatFromInt(pin.x);
            try self.sorted.append(alloc, .{ .z = p.z, .id = image.id, .placement = .{
                .pos = .{ col * cell_width + @as(f32, @floatFromInt(offset.x)), row * cell_height + @as(f32, @floatFromInt(offset.y)) },
                .size = .{ @floatFromInt(size.width), @floatFromInt(size.height) },
                .src_pos = .{ @floatFromInt(src.x), @floatFromInt(src.y) },
                .src_size = .{ @floatFromInt(src.width), @floatFromInt(src.height) },
            } });
        }

        // Unicode placeholders: cells of U+10EEEE whose colors and
        // diacritics name an image and which part of it to show. A
        // program draws them as text, so they scroll and redraw with it,
        // which is what lets images work through tmux. Below the text,
        // as in Ghostty.
        if (!virtual) return;
        var v_it = kitty.unicode.placementIterator(top, bot);
        while (v_it.next()) |vp| {
            const image = storage.imageById(vp.image_id) orelse continue;
            if (image.data.isPending()) continue;
            const rp = vp.renderPlacement(storage, &image, t.width_px / t.cols, t.height_px / t.rows) catch |err| {
                log.debug("placeholder for image id={d} not drawn: {}", .{ vp.image_id, err });
                continue;
            };
            if (rp.dest_width == 0 or rp.dest_height == 0) continue;
            const y = pages.pointFromPin(.viewport, rp.top_left) orelse continue;

            try self.copyImage(alloc, image);
            const row: f32 = @floatFromInt(y.viewport.y);
            const col: f32 = @floatFromInt(rp.top_left.x);
            try self.sorted.append(alloc, .{ .z = -1, .id = image.id, .placement = .{
                .pos = .{ col * cell_width + @as(f32, @floatFromInt(rp.offset_x)), row * cell_height + @as(f32, @floatFromInt(rp.offset_y)) },
                .size = .{ @floatFromInt(rp.dest_width), @floatFromInt(rp.dest_height) },
                .src_pos = .{ @floatFromInt(rp.source_x), @floatFromInt(rp.source_y) },
                .src_size = .{ @floatFromInt(rp.source_width), @floatFromInt(rp.source_height) },
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

    fn copyImage(self: *Images, alloc: Allocator, image: kitty.Image) !void {
        const gop = try self.images.getOrPut(alloc, image.id);
        if (gop.found_existing) {
            if (gop.value_ptr.generation == image.generation) return;
            freePixels(alloc, gop.value_ptr);
        }
        errdefer _ = self.images.swapRemove(image.id);

        // For animated images this is the current frame.
        const data = image.renderData().bytes() orelse unreachable;
        const rgba = try kitty.pixel.rgbaFromFormat(alloc, image.format, data);
        premultiply(rgba);
        gop.value_ptr.* = .{
            .generation = image.generation,
            .width = image.width,
            .height = image.height,
            .rgba = rgba,
        };
        log.debug("copied image id={d} {d}x{d}", .{ image.id, image.width, image.height });
    }
};

fn premultiply(rgba: []u8) void {
    var i: usize = 0;
    while (i + 4 <= rgba.len) : (i += 4) {
        const a: u16 = rgba[i + 3];
        if (a == 255) continue;
        for (rgba[i..][0..3]) |*c| c.* = @intCast((@as(u16, c.*) * a + 127) / 255);
    }
}

test "unicode placeholders place their image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    // 10x10 pixel cells.
    var t = try ghostty_vt.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);
    t.width_px = 50;
    t.height_px = 50;
    t.modes.set(.grapheme_cluster, true);

    const storage = &t.screens.active.kitty_images;
    const pixels = try alloc.alloc(u8, 10 * 10 * 3);
    @memset(pixels, 0xff);
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 7,
        .width = 10,
        .height = 10,
        .format = .rgb,
        .data = .{ .complete = pixels },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 7, 1, .{ .location = .{ .virtual = {} } });

    var images: Images = .{};
    defer images.deinit(alloc);

    // No placeholder on screen yet: nothing to draw.
    try images.update(alloc, &t);
    try testing.expectEqual(0, images.placements.items.len);

    // At column 2, row 2 (0-based). The image ID is the foreground
    // color; the diacritics are row 0, column 0 of the image.
    try t.setAttribute(.{ .@"256_fg" = 7 });
    t.screens.active.cursorAbsolute(2, 2);
    try t.printString("\u{10EEEE}\u{0305}\u{0305}");
    try images.update(alloc, &t);

    try testing.expectEqual(1, images.placements.items.len);
    try testing.expectEqual(7, images.placement_ids.items[0]);
    const p = images.placements.items[0];
    try testing.expectEqual([2]f32{ 20, 20 }, p.pos);
    try testing.expectEqual([2]f32{ 10, 10 }, p.size);
    try testing.expectEqual([2]f32{ 10, 10 }, p.src_size);
    // Under the text, like Ghostty.
    const start, const end = images.layer(.below_text);
    try testing.expectEqual(.{ 0, 1 }, .{ start, end });
    try testing.expect(images.images.get(7).?.rgba != null);
}
