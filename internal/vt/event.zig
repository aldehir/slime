//! Events: a client's input to a pane, which slime handles against the
//! pane's terminal (slime.zig). slime turns window messages into these;
//! anything that depends on the terminal's state (its modes, the
//! selection, scrollback) is the daemon's to decide.
//!
//! Like frame.zig, both ends use this file through `Codec(vt)`.
//!
//! Little-endian; each event starts with its kind (u8):
//!
//!     key:      u8 action, u16 key, u16 mods, u16 consumed mods,
//!               u8 composing, u32 unshifted codepoint, u8 n, n utf8,
//!               u8 n, n * win32 record
//!     text:     the rest, utf8 (IME commits, alt+numpad, VK_PACKET)
//!     paste:    the rest, utf8
//!     focus:    u8 gained
//!     mouse:    u8 action, u8 button (0 none), u16 mods, u8 held,
//!               f32 x, f32 y, u32 time (ms, wrapping)
//!     wheel:    u8 horizontal, i16 rotation, u32 lines a notch
//!               (lines_page: a page), u16 mods, f32 x, f32 y
//!     copy:     u32 tag
//!     geometry: u32 cell width, cell height, padding left, top, right,
//!               bottom, pane width, height (pixels)
//!     settings: u32 double-click interval (ms), u16 n, n * u32 word
//!               boundary codepoints, then the default colors: rgb
//!               background, foreground, u8 has cursor color, rgb
//!               cursor color, rgb palette[256]
//!     cancel:   (a selection drag lost the mouse)
//!
//! A win32 record is win32-input-mode's: u16 vk, u16 scan code, u16 char,
//! u8 down, u32 control key state, u16 repeat. Mouse and wheel positions
//! are pixels from the pane's top left.

const std = @import("std");

pub const Kind = enum(u8) {
    key = 1,
    text = 2,
    paste = 3,
    focus = 4,
    mouse = 5,
    wheel = 6,
    copy = 7,
    geometry = 8,
    settings = 9,
    cancel = 10,
};

/// A wheel that scrolls a page a notch (SPI_GETWHEELSCROLLLINES).
pub const lines_page = std.math.maxInt(u32);

/// One key event in win32-input-mode (DEC 9001), as ConPTY reads them:
/// `CSI Vk ; Sc ; Uc ; Kd ; Cs ; Rc _`.
pub const Win32Key = struct {
    vk: u16 = 0,
    scancode: u16 = 0,
    /// UTF-16 code unit the key produced, or 0.
    char: u16 = 0,
    down: bool,
    control_state: u32 = 0,
    repeat: u16 = 1,

    pub fn encode(self: Win32Key, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("\x1b[{d};{d};{d};{d};{d};{d}_", .{
            self.vk,
            self.scancode,
            self.char,
            @intFromBool(self.down),
            self.control_state,
            self.repeat,
        });
    }
};

pub const Geometry = struct {
    cell_width: u32,
    cell_height: u32,
    padding: struct { left: u32, top: u32, right: u32, bottom: u32 },
    width: u32,
    height: u32,
};

pub fn Codec(comptime vt: type) type {
    return struct {
        const KeyEvent = vt.input.KeyEvent;
        const Mods = vt.input.KeyMods;
        const MouseButton = vt.input.MouseButton;
        const MouseAction = vt.input.MouseAction;
        const ModsInt = @typeInfo(Mods).@"struct".backing_integer.?;
        const RGB = vt.color.RGB;

        /// The most win32 records one key carries: one per UTF-16 unit of
        /// its text.
        pub const max_win32 = 16;
        /// The most word boundary codepoints a settings event carries.
        pub const max_word_boundary = 256;
        /// The most bytes an event other than text or paste encodes to: a
        /// settings event with `max_word_boundary` codepoints. A fixed
        /// buffer this big takes any of them.
        pub const max_len = 1 + 4 + 2 + max_word_boundary * 4 +
            3 + 3 + 1 + 3 + @typeInfo(vt.color.Palette).array.len * 3;

        pub const Key = struct {
            event: KeyEvent,
            /// The key as win32-input-mode sends it, used instead of
            /// `event` while the program asks for that mode.
            win32: []const Win32Key,
        };

        pub const Mouse = struct {
            action: MouseAction,
            button: ?MouseButton,
            mods: Mods,
            /// A button is down (for motion: a drag).
            held: bool,
            x: f32,
            y: f32,
            /// GetMessageTime: milliseconds since boot, wrapping.
            time: u32,
        };

        pub const Wheel = struct {
            horizontal: bool,
            /// WHEEL_DELTA (120) units, positive away from the user or to
            /// the right.
            rotation: i16,
            lines_per_notch: u32,
            mods: Mods,
            x: f32,
            y: f32,
        };

        pub const Settings = struct {
            double_click_ms: u32,
            word_boundary: []const u21,
            /// The colors OSC 4/10/11/12 override and their resets
            /// return to: the window's config.
            colors: Colors,
        };

        pub const Colors = struct {
            background: RGB,
            foreground: RGB,
            /// Null takes the cursor's color from its cell.
            cursor: ?RGB,
            palette: vt.color.Palette,
        };

        pub const Event = union(Kind) {
            key: Key,
            text: []const u8,
            paste: []const u8,
            focus: bool,
            mouse: Mouse,
            wheel: Wheel,
            copy: u32,
            geometry: Geometry,
            settings: Settings,
            cancel,
        };

        pub fn encode(w: *std.Io.Writer, ev: Event) std.Io.Writer.Error!void {
            try w.writeByte(@intFromEnum(ev));
            switch (ev) {
                .key => |k| {
                    const e = k.event;
                    try w.writeByte(@intCast(@intFromEnum(e.action)));
                    try w.writeInt(u16, @intCast(@intFromEnum(e.key)), .little);
                    try w.writeInt(u16, @as(ModsInt, @bitCast(e.mods)), .little);
                    try w.writeInt(u16, @as(ModsInt, @bitCast(e.consumed_mods)), .little);
                    try w.writeByte(@intFromBool(e.composing));
                    try w.writeInt(u32, e.unshifted_codepoint, .little);
                    const text = e.utf8[0..@min(e.utf8.len, 255)];
                    try w.writeByte(@intCast(text.len));
                    try w.writeAll(text);
                    const records = k.win32[0..@min(k.win32.len, max_win32)];
                    try w.writeByte(@intCast(records.len));
                    for (records) |r| {
                        try w.writeInt(u16, r.vk, .little);
                        try w.writeInt(u16, r.scancode, .little);
                        try w.writeInt(u16, r.char, .little);
                        try w.writeByte(@intFromBool(r.down));
                        try w.writeInt(u32, r.control_state, .little);
                        try w.writeInt(u16, r.repeat, .little);
                    }
                },
                .text, .paste => |s| try w.writeAll(s),
                .focus => |gained| try w.writeByte(@intFromBool(gained)),
                .mouse => |m| {
                    try w.writeByte(@intCast(@intFromEnum(m.action)));
                    try w.writeByte(if (m.button) |b| @intCast(@intFromEnum(b)) else 0);
                    try w.writeInt(u16, @as(ModsInt, @bitCast(m.mods)), .little);
                    try w.writeByte(@intFromBool(m.held));
                    try writeF32(w, m.x);
                    try writeF32(w, m.y);
                    try w.writeInt(u32, m.time, .little);
                },
                .wheel => |m| {
                    try w.writeByte(@intFromBool(m.horizontal));
                    try w.writeInt(i16, m.rotation, .little);
                    try w.writeInt(u32, m.lines_per_notch, .little);
                    try w.writeInt(u16, @as(ModsInt, @bitCast(m.mods)), .little);
                    try writeF32(w, m.x);
                    try writeF32(w, m.y);
                },
                .copy => |tag| try w.writeInt(u32, tag, .little),
                .geometry => |g| for ([_]u32{
                    g.cell_width,    g.cell_height,
                    g.padding.left,  g.padding.top,
                    g.padding.right, g.padding.bottom,
                    g.width,         g.height,
                }) |v| try w.writeInt(u32, v, .little),
                .settings => |s| {
                    try w.writeInt(u32, s.double_click_ms, .little);
                    const n = @min(s.word_boundary.len, max_word_boundary);
                    try w.writeInt(u16, @intCast(n), .little);
                    for (s.word_boundary[0..n]) |cp| try w.writeInt(u32, cp, .little);
                    const c = &s.colors;
                    try writeRgb(w, c.background);
                    try writeRgb(w, c.foreground);
                    try w.writeByte(@intFromBool(c.cursor != null));
                    try writeRgb(w, c.cursor orelse .{});
                    for (c.palette) |p| try writeRgb(w, p);
                },
                .cancel => {},
            }
        }

        pub const DecodeError = error{ BadEvent, ReadFailed, EndOfStream };

        /// Decode an event. Its slices point into `bytes`, or into
        /// `scratch` for what needs converting: the win32 records and the
        /// word boundary codepoints.
        pub fn decode(bytes: []const u8, scratch: *Scratch) DecodeError!Event {
            var r: std.Io.Reader = .fixed(bytes);
            const kind = std.enums.fromInt(Kind, try r.takeByte()) orelse return error.BadEvent;
            return switch (kind) {
                .key => key: {
                    const action = std.enums.fromInt(@FieldType(KeyEvent, "action"), try r.takeByte()) orelse return error.BadEvent;
                    const key = std.enums.fromInt(@FieldType(KeyEvent, "key"), try r.takeInt(u16, .little)) orelse return error.BadEvent;
                    const mods: Mods = @bitCast(try r.takeInt(u16, .little));
                    const consumed: Mods = @bitCast(try r.takeInt(u16, .little));
                    const composing = try r.takeByte() != 0;
                    const unshifted = std.math.cast(u21, try r.takeInt(u32, .little)) orelse return error.BadEvent;
                    const utf8 = try r.take(try r.takeByte());
                    const n = try r.takeByte();
                    if (n > max_win32) return error.BadEvent;
                    for (scratch.win32[0..n]) |*rec| rec.* = .{
                        .vk = try r.takeInt(u16, .little),
                        .scancode = try r.takeInt(u16, .little),
                        .char = try r.takeInt(u16, .little),
                        .down = try r.takeByte() != 0,
                        .control_state = try r.takeInt(u32, .little),
                        .repeat = try r.takeInt(u16, .little),
                    };
                    break :key .{ .key = .{
                        .event = .{
                            .action = action,
                            .key = key,
                            .mods = mods,
                            .consumed_mods = consumed,
                            .composing = composing,
                            .utf8 = utf8,
                            .unshifted_codepoint = unshifted,
                        },
                        .win32 = scratch.win32[0..n],
                    } };
                },
                .text => .{ .text = bytes[1..] },
                .paste => .{ .paste = bytes[1..] },
                .focus => .{ .focus = try r.takeByte() != 0 },
                .mouse => .{ .mouse = .{
                    .action = std.enums.fromInt(MouseAction, try r.takeByte()) orelse return error.BadEvent,
                    .button = switch (try r.takeByte()) {
                        0 => null,
                        else => |b| std.enums.fromInt(MouseButton, b) orelse return error.BadEvent,
                    },
                    .mods = @bitCast(try r.takeInt(u16, .little)),
                    .held = try r.takeByte() != 0,
                    .x = try readF32(&r),
                    .y = try readF32(&r),
                    .time = try r.takeInt(u32, .little),
                } },
                .wheel => .{ .wheel = .{
                    .horizontal = try r.takeByte() != 0,
                    .rotation = try r.takeInt(i16, .little),
                    .lines_per_notch = try r.takeInt(u32, .little),
                    .mods = @bitCast(try r.takeInt(u16, .little)),
                    .x = try readF32(&r),
                    .y = try readF32(&r),
                } },
                .copy => .{ .copy = try r.takeInt(u32, .little) },
                .geometry => geometry: {
                    var v: [8]u32 = undefined;
                    for (&v) |*x| x.* = try r.takeInt(u32, .little);
                    break :geometry .{ .geometry = .{
                        .cell_width = v[0],
                        .cell_height = v[1],
                        .padding = .{ .left = v[2], .top = v[3], .right = v[4], .bottom = v[5] },
                        .width = v[6],
                        .height = v[7],
                    } };
                },
                .settings => settings: {
                    const ms = try r.takeInt(u32, .little);
                    const n = try r.takeInt(u16, .little);
                    if (n > scratch.word_boundary.len) return error.BadEvent;
                    for (scratch.word_boundary[0..n]) |*cp| {
                        cp.* = std.math.cast(u21, try r.takeInt(u32, .little)) orelse return error.BadEvent;
                    }
                    const c = &scratch.colors;
                    c.background = try readRgb(&r);
                    c.foreground = try readRgb(&r);
                    const has_cursor = try r.takeByte() != 0;
                    const cursor = try readRgb(&r);
                    c.cursor = if (has_cursor) cursor else null;
                    for (&c.palette) |*p| p.* = try readRgb(&r);
                    break :settings .{ .settings = .{
                        .double_click_ms = ms,
                        .word_boundary = scratch.word_boundary[0..n],
                        .colors = c.*,
                    } };
                },
                .cancel => .cancel,
            };
        }

        /// Room `decode` converts into.
        pub const Scratch = struct {
            win32: [max_win32]Win32Key = undefined,
            word_boundary: [max_word_boundary]u21 = undefined,
            colors: Colors = undefined,
        };

        fn writeF32(w: *std.Io.Writer, v: f32) !void {
            try w.writeInt(u32, @bitCast(v), .little);
        }

        fn readF32(r: *std.Io.Reader) !f32 {
            return @bitCast(try r.takeInt(u32, .little));
        }

        fn writeRgb(w: *std.Io.Writer, c: RGB) !void {
            try w.writeAll(&.{ c.r, c.g, c.b });
        }

        fn readRgb(r: *std.Io.Reader) !RGB {
            const b = try r.takeArray(3);
            return .{ .r = b[0], .g = b[1], .b = b[2] };
        }
    };
}
