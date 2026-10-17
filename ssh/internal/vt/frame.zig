//! Frames: what slimed sends slime to draw a pane. A frame carries the
//! grid size, colors, the cursor, and the rows of the viewport that
//! changed since the last one (all of them in a full frame), with the
//! selection on each row.
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
//!
//! A style is three colors (u8 tag; palette: u8; rgb: 3 bytes), then u16
//! flags.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Bumped with any change to the encoding. It's also derived from the
/// cell and style layouts (`layout_id`), so a slime and a slimed built
/// from different libghostty-vt versions refuse each other's frames.
pub const version = 1;

pub const Flags = packed struct(u8) {
    /// Every row is in the frame, and the screen takes its size.
    full: bool = false,
    palette: bool = false,
    _pad: u6 = 0,
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

        /// Encode a frame from `state`: every row if `full` or the state
        /// says so, else its dirty rows. The caller cleans the state
        /// after (`RenderState.clean`), and decides whether the palette
        /// goes.
        pub fn encode(w: *std.Io.Writer, state: *const RenderState, opts: struct {
            full: bool = false,
            palette: bool = false,
        }) std.Io.Writer.Error!void {
            const full = opts.full or state.dirty == .full;
            const flags: Flags = .{ .full = full, .palette = opts.palette or full };
            try w.writeByte(@bitCast(flags));
            try w.writeInt(u16, state.cols, .little);
            try w.writeInt(u16, state.rows, .little);

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
            }

            fn resize(self: *Screen, alloc: Allocator, cols: u16, rows: u16) Allocator.Error!void {
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
