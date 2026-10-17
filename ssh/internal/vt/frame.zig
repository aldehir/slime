//! Frames: what slimed sends slime to draw a pane. A frame carries the
//! grid size, colors, the cursor, the rows of the viewport that changed
//! since the last one (all of them in a full frame), with the selection
//! on each row, and the kitty images placed in the viewport.
//!
//! Both ends use this file. slimed's library (slime.zig) instantiates
//! `Codec` with libghostty-vt's root, slime with its ghostty-vt module:
//! the same source either way, so the types agree. A raw cell is a
//! `packed struct(u64)` and goes over as is; styles, whose layout isn't
//! fixed, go field by field.
//!
//! Little-endian throughout:
//!
//!     u8   flags (Flags)
//!     u16  cols, rows
//!     u8   mouse shape (OSC 22, ghostty's MouseShape)
//!     rgb  background, foreground
//!     u8   has cursor color, rgb cursor color
//!     rgb  palette[256]                     if flags.palette
//!     cursor: u8 bits (Cursor), u8 visual style, u16 x, u16 y,
//!             u64 cell, style
//!     u16  row count, then each row:
//!       u16  y
//!       u8   has selection, u16 first, u16 last
//!       runs of equal cells covering cols: u64 cell, uleb128 count
//!       u16  styles, each: u16 style id, style
//!       u16  graphemes, each: u16 x, u8 n, n * u24 extra codepoints
//!     u16  dropped images, each: u32 image id
//!     u16  placements, each: u32 image id, i32 z, u16 x, i32 y,
//!          u32 offset x, y, u32 width, height, u32 source x, y, width,
//!          height
//!
//! A style is three colors (u8 tag; palette: u8; rgb: 3 bytes), then u16
//! flags.
//!
//! An image's pixels go once, in a message of their own before the
//! first frame that places it (`ImageSender`); the frame's placements
//! name images by id. A dropped image is one the terminal no longer
//! has, which the receiver frees.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bumped with any change to the encoding. It's also derived from the
/// cell and style layouts (`layout_id`), so a slime and a slimed built
/// from different libghostty-vt versions refuse each other's frames.
pub const version = 2;

/// One kitty image placed in the viewport, as a frame carries it. Its
/// pixel sizes come from the sender's cell size (the one the receiver
/// said in Resize), its position in cells, so the receiver lays it on
/// its own grid.
pub const Placement = struct {
    image_id: u32,
    /// Kitty's z-index: below `min(i32) / 2` is under the background,
    /// below 0 under the text, the rest above it.
    z: i32,
    /// The cell its top-left is in. A placement scrolled partly out of
    /// the viewport starts on a row above it, so y can be negative.
    x: u16,
    y: i32,
    /// Pixels from that cell's top-left.
    offset_x: u32,
    offset_y: u32,
    /// Its size on screen, in pixels.
    width: u32,
    height: u32,
    /// The part of the image shown, in image pixels.
    src_x: u32,
    src_y: u32,
    src_width: u32,
    src_height: u32,
};

pub const Flags = packed struct(u8) {
    /// Every row is in the frame, and the screen takes its size.
    full: bool = false,
    palette: bool = false,
    /// The program wants mouse motion without a button held (any-event
    /// tracking, mode 1003); the client sends it only then.
    motion: bool = false,
    _pad: u5 = 0,
};

const CursorBits = packed struct(u8) {
    visible: bool = false,
    blinking: bool = false,
    password_input: bool = false,
    /// In the viewport: x and y follow.
    in_viewport: bool = false,
    wide_tail: bool = false,
    _pad: u3 = 0,
};

pub fn Codec(comptime vt: type) type {
    return struct {
        const RenderState = vt.RenderState;
        const Cell = vt.Cell;
        const Style = vt.Style;
        const Color = @FieldType(Style, "fg_color");
        const StyleFlags = @FieldType(Style, "flags");
        const RGB = vt.color.RGB;
        const Cursor = RenderState.Cursor;
        const VisualStyle = @FieldType(Cursor, "visual_style");
        const StyleId = @FieldType(Cell, "style_id");
        const kitty = vt.kitty.graphics;

        /// Placements with a z-index below this are drawn under cell
        /// backgrounds, as in kitty.
        pub const below_bg_z = std.math.minInt(i32) / 2;

        /// Identifies this codec's encoding and the layouts it copies:
        /// equal on both ends or they can't talk.
        pub const layout_id: u64 = id: {
            @setEvalBranchQuota(10_000);
            var h = std.hash.Fnv1a_64.init();
            h.update(std.fmt.comptimePrint("{d}", .{version}));
            for (.{ Cell, StyleFlags }) |T| {
                for (@typeInfo(T).@"struct".fields) |f| {
                    h.update(f.name);
                    h.update(std.fmt.comptimePrint(":{d};", .{@bitSizeOf(f.type)}));
                }
            }
            break :id h.final();
        };

        /// The sender's side of images: which the receiver has, by
        /// generation, and what the next frame carries of them, from
        /// `gather`. The pixels of `pending` go out before the frame
        /// (`pixels`); the receiver keeps every image sent until a
        /// frame drops it, placed or not, as it may be placed again.
        pub const ImageSender = struct {
            /// The generation of each image the receiver has.
            sent: std.AutoHashMapUnmanaged(u32, u64) = .empty,
            /// The placements in the viewport, in no order.
            placements: std.ArrayList(Placement) = .empty,
            /// Images the frame places that the receiver lacks, or has
            /// an older generation of.
            pending: std.ArrayList(ImageRef) = .empty,
            /// Images the receiver has that the terminal no longer does.
            dropped: std.ArrayList(u32) = .empty,

            pub const ImageRef = struct { id: u32, generation: u64 };

            /// An image's pixels, to send.
            pub const Pixels = struct {
                id: u32,
                generation: u64,
                width: u32,
                height: u32,
                /// Straight (not premultiplied) RGBA, rows top-down.
                rgba: []u8,
            };

            pub fn deinit(self: *ImageSender, alloc: Allocator) void {
                self.sent.deinit(alloc);
                self.placements.deinit(alloc);
                self.pending.deinit(alloc);
                self.dropped.deinit(alloc);
            }

            /// Forget what the receiver has: a new one attached.
            pub fn reset(self: *ImageSender) void {
                self.sent.clearRetainingCapacity();
            }

            /// Find the placements in the viewport, the images among them
            /// to send first, and the sent images the terminal dropped.
            /// Call with the terminal locked, before each `encode`.
            pub fn gather(self: *ImageSender, alloc: Allocator, t: *const vt.Terminal) !void {
                self.placements.clearRetainingCapacity();
                self.pending.clearRetainingCapacity();
                self.dropped.clearRetainingCapacity();
                const screen = t.screens.active;
                const storage = &screen.kitty_images;

                var sent = self.sent.keyIterator();
                while (sent.next()) |id| {
                    if (storage.imageById(id.*) == null) try self.dropped.append(alloc, id.*);
                }
                for (self.dropped.items) |id| _ = self.sent.remove(id);

                if (t.cols == 0 or t.rows == 0 or storage.placements.count() == 0) return;
                const cell_width = t.width_px / t.cols;
                const cell_height = t.height_px / t.rows;
                if (cell_width == 0 or cell_height == 0) return;
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
                    try self.place(alloc, image, .{
                        .image_id = image.id,
                        .z = p.z,
                        .x = pin.x,
                        .y = @intCast(@as(i64, y) - @as(i64, top_y)),
                        .offset_x = offset.x,
                        .offset_y = offset.y,
                        .width = size.width,
                        .height = size.height,
                        .src_x = src.x,
                        .src_y = src.y,
                        .src_width = src.width,
                        .src_height = src.height,
                    });
                }

                // Unicode placeholders: cells of U+10EEEE whose colors and
                // diacritics name an image and which part of it to show.
                // A program draws them as text, so they scroll and
                // redraw with it, which is what lets images work through
                // tmux. Below the text, as in Ghostty.
                if (!virtual) return;
                var v_it = kitty.unicode.placementIterator(top, bot);
                while (v_it.next()) |vp| {
                    const image = storage.imageById(vp.image_id) orelse continue;
                    if (image.data.isPending()) continue;
                    const rp = vp.renderPlacement(storage, &image, cell_width, cell_height) catch continue;
                    if (rp.dest_width == 0 or rp.dest_height == 0) continue;
                    const y = pages.pointFromPin(.viewport, rp.top_left) orelse continue;
                    try self.place(alloc, image, .{
                        .image_id = image.id,
                        .z = -1,
                        .x = rp.top_left.x,
                        .y = @intCast(y.viewport.y),
                        .offset_x = rp.offset_x,
                        .offset_y = rp.offset_y,
                        .width = rp.dest_width,
                        .height = rp.dest_height,
                        .src_x = rp.source_x,
                        .src_y = rp.source_y,
                        .src_width = rp.source_width,
                        .src_height = rp.source_height,
                    });
                }
            }

            fn place(self: *ImageSender, alloc: Allocator, image: kitty.Image, p: Placement) !void {
                try self.placements.append(alloc, p);
                const gop = try self.sent.getOrPut(alloc, image.id);
                if (gop.found_existing and gop.value_ptr.* == image.generation) return;
                errdefer if (!gop.found_existing) {
                    _ = self.sent.remove(image.id);
                };
                try self.pending.append(alloc, .{ .id = image.id, .generation = image.generation });
                gop.value_ptr.* = image.generation;
            }

            /// The pixels of `pending[i]`, or null if the terminal lost
            /// it since `gather`. The caller frees `rgba`.
            pub fn pixels(self: *const ImageSender, alloc: Allocator, t: *const vt.Terminal, i: usize) !?Pixels {
                const ref = self.pending.items[i];
                const image = t.screens.active.kitty_images.imageById(ref.id) orelse return null;
                if (image.generation != ref.generation) return null;
                // For animated images this is the current frame.
                const data = image.renderData().bytes() orelse return null;
                const rgba = try kitty.pixel.rgbaFromFormat(alloc, image.format, data);
                errdefer alloc.free(rgba);
                const len = std.math.mul(usize, std.math.mul(usize, image.width, image.height) catch return null, 4) catch return null;
                if (rgba.len != len) return null;
                return .{
                    .id = image.id,
                    .generation = image.generation,
                    .width = image.width,
                    .height = image.height,
                    .rgba = rgba,
                };
            }
        };

        /// Encode a frame from `state`: every row if `full` or the state
        /// says so, else its dirty rows. The caller cleans the state
        /// after (`RenderState.clean`), and decides whether the palette
        /// goes.
        pub fn encode(w: *std.Io.Writer, state: *const RenderState, opts: struct {
            full: bool = false,
            palette: bool = false,
            /// Terminal state the render state doesn't carry.
            motion: bool = false,
            mouse_shape: u8 = 0,
            /// The images placed, from `ImageSender.gather`; none if
            /// null.
            images: ?*const ImageSender = null,
        }) std.Io.Writer.Error!void {
            const full = opts.full or state.dirty == .full;
            const flags: Flags = .{ .full = full, .palette = opts.palette or full, .motion = opts.motion };
            try w.writeByte(@bitCast(flags));
            try w.writeInt(u16, state.cols, .little);
            try w.writeInt(u16, state.rows, .little);
            try w.writeByte(opts.mouse_shape);

            const colors = &state.colors;
            try writeRgb(w, colors.background);
            try writeRgb(w, colors.foreground);
            try w.writeByte(@intFromBool(colors.cursor != null));
            try writeRgb(w, colors.cursor orelse .{});
            if (flags.palette) for (colors.palette) |c| try writeRgb(w, c);

            const cur = &state.cursor;
            const bits: CursorBits = .{
                .visible = cur.visible,
                .blinking = cur.blinking,
                .password_input = cur.password_input,
                .in_viewport = cur.viewport != null,
                .wide_tail = if (cur.viewport) |v| v.wide_tail else false,
            };
            try w.writeByte(@bitCast(bits));
            try w.writeByte(@intFromEnum(cur.visual_style));
            const pos = cur.viewport orelse Cursor.Viewport{ .x = 0, .y = 0, .wide_tail = false };
            try w.writeInt(u16, pos.x, .little);
            try w.writeInt(u16, pos.y, .little);
            try w.writeInt(u64, @bitCast(cur.cell), .little);
            try writeStyle(w, cur.style);

            const rows = state.row_data.slice();
            const n_rows = @min(rows.len, state.rows);
            const dirty = rows.items(.dirty);
            var count: u16 = 0;
            for (0..n_rows) |y| count += @intFromBool(full or dirty[y]);
            try w.writeInt(u16, count, .little);
            for (rows.items(.cells)[0..n_rows], rows.items(.selection)[0..n_rows], 0..) |row_cells, sel, y| {
                if (!full and !dirty[y]) continue;
                try w.writeInt(u16, @intCast(y), .little);
                try w.writeByte(@intFromBool(sel != null));
                const s = sel orelse .{ 0, 0 };
                try w.writeInt(u16, s[0], .little);
                try w.writeInt(u16, s[1], .little);
                try writeCells(w, row_cells.slice(), state.cols);
            }

            const dropped: []const u32 = if (opts.images) |im| im.dropped.items else &.{};
            try w.writeInt(u16, @intCast(@min(dropped.len, std.math.maxInt(u16))), .little);
            for (dropped[0..@min(dropped.len, std.math.maxInt(u16))]) |id| try w.writeInt(u32, id, .little);
            const placements: []const Placement = if (opts.images) |im| im.placements.items else &.{};
            const n_placements = @min(placements.len, std.math.maxInt(u16));
            try w.writeInt(u16, @intCast(n_placements), .little);
            for (placements[0..n_placements]) |p| {
                try w.writeInt(u32, p.image_id, .little);
                try w.writeInt(i32, p.z, .little);
                try w.writeInt(u16, p.x, .little);
                try w.writeInt(i32, p.y, .little);
                for ([_]u32{ p.offset_x, p.offset_y, p.width, p.height, p.src_x, p.src_y, p.src_width, p.src_height }) |v| {
                    try w.writeInt(u32, v, .little);
                }
            }
        }

        fn writeCells(w: *std.Io.Writer, cells: std.MultiArrayList(RenderState.Cell).Slice, cols: u16) !void {
            const raws = cells.items(.raw)[0..cols];
            var x: usize = 0;
            while (x < raws.len) {
                const raw: u64 = @bitCast(raws[x]);
                var run: usize = 1;
                while (x + run < raws.len and @as(u64, @bitCast(raws[x + run])) == raw) run += 1;
                try w.writeInt(u64, raw, .little);
                try w.writeUleb128(run);
                x += run;
            }

            // Each style id once, at its first cell: a row is in one page,
            // so an id means one style throughout it. A gradient can give
            // every cell its own.
            const styles = cells.items(.style);
            var seen: std.StaticBitSet(std.math.maxInt(StyleId) + 1) = .initEmpty();
            var n_ids: u16 = 0;
            for (raws) |raw| {
                if (!raw.hasStyling() or seen.isSet(raw.style_id)) continue;
                seen.set(raw.style_id);
                n_ids += 1;
            }
            try w.writeInt(u16, n_ids, .little);
            for (raws, styles[0..raws.len]) |raw, style| {
                if (!raw.hasStyling() or !seen.isSet(raw.style_id)) continue;
                seen.unset(raw.style_id);
                try w.writeInt(u16, raw.style_id, .little);
                try writeStyle(w, style);
            }

            const graphemes = cells.items(.grapheme);
            var n_graphemes: u16 = 0;
            for (raws) |raw| n_graphemes += @intFromBool(raw.hasGrapheme());
            try w.writeInt(u16, n_graphemes, .little);
            for (raws, 0..) |raw, i| {
                if (!raw.hasGrapheme()) continue;
                const cps = graphemes[i];
                const n: u8 = @intCast(@min(cps.len, 255));
                try w.writeInt(u16, @intCast(i), .little);
                try w.writeByte(n);
                for (cps[0..n]) |cp| try w.writeInt(u24, cp, .little);
            }
        }

        fn writeRgb(w: *std.Io.Writer, c: RGB) !void {
            try w.writeAll(&.{ c.r, c.g, c.b });
        }

        fn writeColor(w: *std.Io.Writer, c: Color) !void {
            try w.writeByte(@intFromEnum(c));
            switch (c) {
                .none => {},
                .palette => |i| try w.writeByte(i),
                .rgb => |rgb| try writeRgb(w, rgb),
            }
        }

        fn writeStyle(w: *std.Io.Writer, s: Style) !void {
            try writeColor(w, s.fg_color);
            try writeColor(w, s.bg_color);
            try writeColor(w, s.underline_color);
            try w.writeInt(u16, @bitCast(s.flags), .little);
        }

        /// What slime draws: the last frames applied.
        pub const Screen = struct {
            cols: u16 = 0,
            rows: u16 = 0,
            colors: RenderState.Colors = RenderState.empty.colors,
            cursor: Cursor = RenderState.empty.cursor,
            row_data: std.ArrayList(Row) = .empty,
            /// The pointer the program asked for (OSC 22), as ghostty's
            /// MouseShape numbers them.
            mouse_shape: u8 = 0,
            /// Send mouse motion without a button held (Flags.motion).
            motion: bool = false,
            /// The images placed in the viewport, as of the last frame.
            placements: std.ArrayList(Placement) = .empty,
            /// Images the frames applied dropped, for the owner of the
            /// pixels to free; it clears the list.
            dropped: std.ArrayList(u32) = .empty,

            /// Scratch for decoding a row: its style table.
            style_table: std.AutoHashMapUnmanaged(StyleId, Style) = .empty,

            pub const Row = struct {
                raws: std.ArrayList(Cell) = .empty,
                /// Valid only for cells with styling.
                styles: std.ArrayList(Style) = .empty,
                /// Valid only for cells with graphemes: slices of
                /// `codepoints`.
                graphemes: std.ArrayList([]const u21) = .empty,
                codepoints: std.ArrayList(u21) = .empty,
                selection: ?[2]u16 = null,
                /// Set by `apply` for each row a frame changed.
                dirty: bool = false,

                fn deinit(self: *Row, alloc: Allocator) void {
                    self.raws.deinit(alloc);
                    self.styles.deinit(alloc);
                    self.graphemes.deinit(alloc);
                    self.codepoints.deinit(alloc);
                }
            };

            pub fn deinit(self: *Screen, alloc: Allocator) void {
                for (self.row_data.items) |*r| r.deinit(alloc);
                self.row_data.deinit(alloc);
                self.placements.deinit(alloc);
                self.dropped.deinit(alloc);
                self.style_table.deinit(alloc);
                self.* = undefined;
            }

            pub const ApplyError = Allocator.Error || error{ BadFrame, ReadFailed, EndOfStream };

            /// Apply an encoded frame. A partial frame must match the
            /// screen's size; on an error the screen may be half
            /// updated, and wants a full frame.
            pub fn apply(self: *Screen, alloc: Allocator, frame: []const u8) ApplyError!void {
                var r: std.Io.Reader = .fixed(frame);
                const flags: Flags = @bitCast(try r.takeByte());
                const cols = try r.takeInt(u16, .little);
                const rows = try r.takeInt(u16, .little);
                if (flags.full) {
                    try self.resize(alloc, cols, rows);
                } else if (cols != self.cols or rows != self.rows) {
                    return error.BadFrame;
                }
                for (self.row_data.items) |*row| row.dirty = false;
                self.mouse_shape = try r.takeByte();
                self.motion = flags.motion;

                self.colors.background = try readRgb(&r);
                self.colors.foreground = try readRgb(&r);
                const has_cursor_color = try r.takeByte() != 0;
                const cursor_color = try readRgb(&r);
                self.colors.cursor = if (has_cursor_color) cursor_color else null;
                if (flags.palette) for (&self.colors.palette) |*c| {
                    c.* = try readRgb(&r);
                };

                const bits: CursorBits = @bitCast(try r.takeByte());
                const visual = std.enums.fromInt(VisualStyle, try r.takeByte()) orelse return error.BadFrame;
                const x = try r.takeInt(u16, .little);
                const y = try r.takeInt(u16, .little);
                const cell: Cell = @bitCast(try r.takeInt(u64, .little));
                const style = try readStyle(&r);
                self.cursor.visible = bits.visible;
                self.cursor.blinking = bits.blinking;
                self.cursor.password_input = bits.password_input;
                self.cursor.visual_style = visual;
                self.cursor.viewport = if (bits.in_viewport) .{ .x = x, .y = y, .wide_tail = bits.wide_tail } else null;
                self.cursor.cell = cell;
                self.cursor.style = style;

                const count = try r.takeInt(u16, .little);
                for (0..count) |_| {
                    const row_y = try r.takeInt(u16, .little);
                    if (row_y >= self.rows) return error.BadFrame;
                    const row = &self.row_data.items[row_y];
                    const has_sel = try r.takeByte() != 0;
                    const sel = [2]u16{ try r.takeInt(u16, .little), try r.takeInt(u16, .little) };
                    row.selection = if (has_sel) sel else null;
                    try self.readCells(alloc, &r, row);
                    row.dirty = true;
                }

                const n_dropped = try r.takeInt(u16, .little);
                try self.dropped.ensureUnusedCapacity(alloc, n_dropped);
                for (0..n_dropped) |_| self.dropped.appendAssumeCapacity(try r.takeInt(u32, .little));
                const n_placements = try r.takeInt(u16, .little);
                self.placements.clearRetainingCapacity();
                try self.placements.ensureTotalCapacity(alloc, n_placements);
                for (0..n_placements) |_| {
                    self.placements.appendAssumeCapacity(.{
                        .image_id = try r.takeInt(u32, .little),
                        .z = try r.takeInt(i32, .little),
                        .x = try r.takeInt(u16, .little),
                        .y = try r.takeInt(i32, .little),
                        .offset_x = try r.takeInt(u32, .little),
                        .offset_y = try r.takeInt(u32, .little),
                        .width = try r.takeInt(u32, .little),
                        .height = try r.takeInt(u32, .little),
                        .src_x = try r.takeInt(u32, .little),
                        .src_y = try r.takeInt(u32, .little),
                        .src_width = try r.takeInt(u32, .little),
                        .src_height = try r.takeInt(u32, .little),
                    });
                }
            }

            /// Write the text of the rows the last frame changed, a line
            /// each, trailing blanks trimmed: for tests and debugging.
            pub fn changedText(self: *const Screen, w: *std.Io.Writer) std.Io.Writer.Error!void {
                for (self.row_data.items) |row| {
                    if (!row.dirty) continue;
                    var line: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
                    defer line.deinit();
                    for (row.raws.items, row.graphemes.items) |raw, extra| {
                        if (raw.wide == .spacer_tail or raw.wide == .spacer_head) continue;
                        const cp: u21 = if (raw.hasText()) raw.codepoint() else ' ';
                        try line.writer.print("{u}", .{cp});
                        if (raw.hasGrapheme()) for (extra) |e| try line.writer.print("{u}", .{e});
                    }
                    try w.writeAll(std.mem.trimEnd(u8, line.written(), " "));
                    try w.writeByte('\n');
                }
            }

            pub fn resize(self: *Screen, alloc: Allocator, cols: u16, rows: u16) Allocator.Error!void {
                for (self.row_data.items[@min(rows, self.row_data.items.len)..]) |*row| row.deinit(alloc);
                const old = self.row_data.items.len;
                try self.row_data.resize(alloc, rows);
                for (self.row_data.items[@min(old, rows)..]) |*row| row.* = .{};
                for (self.row_data.items) |*row| {
                    try row.raws.resize(alloc, cols);
                    try row.styles.resize(alloc, cols);
                    try row.graphemes.resize(alloc, cols);
                }
                self.cols = cols;
                self.rows = rows;
            }

            fn readCells(self: *Screen, alloc: Allocator, r: *std.Io.Reader, row: *Row) ApplyError!void {
                const cols = self.cols;
                const raws = row.raws.items;
                var x: usize = 0;
                while (x < cols) {
                    const raw: Cell = @bitCast(try r.takeInt(u64, .little));
                    const run = r.takeLeb128(usize) catch |err| switch (err) {
                        error.Overflow => return error.BadFrame,
                        else => |e| return e,
                    };
                    if (run == 0 or run > cols - x) return error.BadFrame;
                    @memset(raws[x..][0..run], raw);
                    x += run;
                }

                const table = &self.style_table;
                table.clearRetainingCapacity();
                const n_styles = try r.takeInt(u16, .little);
                if (n_styles > cols) return error.BadFrame;
                try table.ensureTotalCapacity(alloc, n_styles);
                for (0..n_styles) |_| {
                    const id = try r.takeInt(u16, .little);
                    table.putAssumeCapacity(id, try readStyle(r));
                }
                for (raws, row.styles.items) |raw, *style| {
                    if (!raw.hasStyling()) continue;
                    style.* = table.get(raw.style_id) orelse return error.BadFrame;
                }

                // Codepoints first, then the slices into them, as the list
                // moves while it grows.
                row.codepoints.clearRetainingCapacity();
                const n_graphemes = try r.takeInt(u16, .little);
                if (n_graphemes > cols) return error.BadFrame;
                var spans: std.ArrayList(struct { x: u16, start: u32, len: u8 }) = .empty;
                defer spans.deinit(alloc);
                try spans.ensureTotalCapacity(alloc, n_graphemes);
                for (0..n_graphemes) |_| {
                    const gx = try r.takeInt(u16, .little);
                    if (gx >= cols) return error.BadFrame;
                    const len = try r.takeByte();
                    spans.appendAssumeCapacity(.{ .x = gx, .start = @intCast(row.codepoints.items.len), .len = len });
                    for (0..len) |_| {
                        const cp = std.math.cast(u21, try r.takeInt(u24, .little)) orelse return error.BadFrame;
                        try row.codepoints.append(alloc, cp);
                    }
                }
                for (spans.items) |span| {
                    row.graphemes.items[span.x] = row.codepoints.items[span.start..][0..span.len];
                }
            }
        };

        fn readRgb(r: *std.Io.Reader) !RGB {
            const b = try r.takeArray(3);
            return .{ .r = b[0], .g = b[1], .b = b[2] };
        }

        fn readColor(r: *std.Io.Reader) Screen.ApplyError!Color {
            return switch (try r.takeByte()) {
                0 => .none,
                1 => .{ .palette = try r.takeByte() },
                2 => .{ .rgb = try readRgb(r) },
                else => error.BadFrame,
            };
        }

        fn readStyle(r: *std.Io.Reader) Screen.ApplyError!Style {
            return .{
                .fg_color = try readColor(r),
                .bg_color = try readColor(r),
                .underline_color = try readColor(r),
                .flags = @bitCast(try r.takeInt(u16, .little)),
            };
        }
    };
}
