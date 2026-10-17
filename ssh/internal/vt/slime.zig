//! slimed's own exports, compiled into libghostty-vt (`-Dvt-extra`) next
//! to its C API. The library's Zig API is `@import("root")`; terminals
//! come in as the C API's handles. vt.go and view.go declare these.
//!
//! A View is one pane as a client sees and drives it: the render state
//! frames are cut from, and the input state events act on (the
//! selection gesture, the wheel's remainder, the pane's geometry). Its
//! event handling is what slime's Session did against its own terminal.
//! Calls on a View and its terminal must not overlap.

const std = @import("std");
const vt = @import("root");
const frame = @import("frame.zig");
const event = @import("event.zig");

const Terminal = vt.c_api.terminal.Terminal;
const Frames = frame.Codec(vt);
const Events = event.Codec(vt);
const alloc = std.heap.smp_allocator;

const MouseEncodeOptions = vt.input.MouseEncodeOptions;

/// The Zig terminal behind a C API handle.
fn zigTerminal(t: Terminal) ?*vt.Terminal {
    return (t orelse return null).terminal;
}

/// The frame codec's layout id (frame.zig), which slime checks against
/// its own.
export fn slime_vt_frame_layout() u64 {
    return Frames.layout_id;
}

/// The text of the rows a frame carries, a line each, into a buffer the
/// caller frees with free() (null when there's none): for tests and
/// debugging. A partial frame decodes against a blank screen of its
/// size. Returns false for a bad frame.
export fn slime_vt_frame_text(ptr: [*]const u8, len: usize, out_ptr: *?[*]u8, out_len: *usize) bool {
    const bytes = ptr[0..len];
    if (bytes.len < 5) return false;
    var screen: Frames.Screen = .{};
    defer screen.deinit(alloc);
    screen.resize(alloc, std.mem.readInt(u16, bytes[1..3], .little), std.mem.readInt(u16, bytes[3..5], .little)) catch return false;
    screen.apply(alloc, bytes) catch return false;
    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    screen.changedText(&out.writer) catch return false;
    // An empty slice's pointer isn't an allocation free() can take.
    out_ptr.* = null;
    out_len.* = 0;
    if (out.written().len == 0) {
        out.deinit();
        return true;
    }
    const text = out.toOwnedSlice() catch return false;
    out_ptr.* = text.ptr;
    out_len.* = text.len;
    return true;
}

const View = struct {
    // Frames.
    state: vt.RenderState = .empty,
    frame: std.Io.Writer.Allocating,
    palette: ?vt.color.Palette = null,
    /// The kitty images the client has, and the last frame's placements.
    images: Frames.ImageSender = .{},
    /// The last image's pixels handed out, until the next.
    image_rgba: ?[]u8 = null,

    // Events: what the last one produced.
    out: std.Io.Writer.Allocating,
    copied: std.Io.Writer.Allocating,
    scratch: Events.Scratch = .{},

    // Input state.
    geometry: event.Geometry = .{
        .cell_width = 1,
        .cell_height = 1,
        .padding = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
        .width = 0,
        .height = 0,
    },
    double_click_ms: u32 = 500,
    word_boundary: std.ArrayList(u21) = .empty,
    gesture: vt.SelectionGesture = .init,
    /// A left button drag is selecting text rather than being reported.
    selecting: bool = false,
    /// Where the selection drag last was, for autoscroll ticks, and
    /// whether it asked for a rectangle.
    drag: struct { x: f32 = 0, y: f32 = 0, rectangle: bool = false } = .{},
    /// The cell the last mouse event was reported in, so motion within
    /// one cell is reported once.
    mouse_cell: ?vt.Coordinate = null,
    /// Wheel rotation not yet turned into scrolling, vertical then
    /// horizontal, in 1/WHEEL_DELTA notches times the lines per notch.
    wheel_remainder: [2]i32 = .{ 0, 0 },
};

/// What an event (or autoscroll tick) did. The bytes are the View's,
/// valid until the next call on it.
const Result = extern struct {
    /// Bytes for the child.
    pty_ptr: ?[*]const u8 = null,
    pty_len: usize = 0,
    /// A copy's text, when `copied`.
    copied_ptr: ?[*]const u8 = null,
    copied_len: usize = 0,
    copy_tag: u32 = 0,
    copied: bool = false,
    /// The pane looks different without new output: the selection or
    /// the viewport moved.
    changed: bool = false,
    /// A selection drag sits past an edge: tick slime_vt_view_autoscroll
    /// every autoscroll_ms while this stays set.
    autoscroll: bool = false,
};

export fn slime_vt_view_new() ?*View {
    const v = alloc.create(View) catch return null;
    v.* = .{ .frame = .init(alloc), .out = .init(alloc), .copied = .init(alloc) };
    v.word_boundary.appendSlice(alloc, &default_word_boundary) catch {};
    return v;
}

/// Selection's word boundaries until the client sends its own: Ghostty's
/// `selection-word-chars` default.
const default_word_boundary = [_]u21{ ' ', '\t', '\'', '"', '│', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };

export fn slime_vt_view_free(v: ?*View, t: Terminal) void {
    const self = v orelse return;
    if (zigTerminal(t)) |term| self.gesture.deinit(term);
    self.frame.deinit();
    self.out.deinit();
    self.copied.deinit();
    self.word_boundary.deinit(alloc);
    self.state.deinit(alloc);
    self.images.deinit(alloc);
    if (self.image_rgba) |rgba| alloc.free(rgba);
    alloc.destroy(self);
}

/// Forget the input state the last client left, for a new one: a
/// selection drag in progress (the selection it made stays), the wheel's
/// remainder, and the cell motion was last reported in.
export fn slime_vt_view_reset(v: ?*View, t: Terminal) void {
    const self = v orelse return;
    const term = zigTerminal(t) orelse return;
    self.gesture.reset(term);
    self.selecting = false;
    self.drag = .{};
    self.mouse_cell = null;
    self.wheel_remainder = .{ 0, 0 };
}

/// Give a terminal slime's defaults: mode 2027 clusters multi-codepoint
/// graphemes (emoji sequences, combining marks) into one cell, as the
/// Ghostty app does, and a null cursor blink blinks, including after a
/// DECSCUSR 0, RIS, or DECSTR. `fresh` sets the modes too, for a new
/// terminal; a restored one keeps what its program set.
///
/// The pointer is an arrow until the program asks for another shape
/// with OSC 22: an I-beam (Ghostty's default) looks wrong over TUIs. An
/// empty OSC 22 still resets it to the I-beam. A restored terminal can't
/// tell the default I-beam from one the program asked for, and takes the
/// arrow.
export fn slime_vt_terminal_defaults(t: Terminal, fresh: bool) void {
    const term = zigTerminal(t) orelse return;
    term.modes.default.grapheme_cluster = true;
    if (fresh) term.modes.set(.grapheme_cluster, true);
    term.setDefaultCursorBlink(null);
    if (fresh or term.mouse_shape == .text) term.mouse_shape = .default;
}

/// Why the next frame should wait: 0 for no reason, 1 while the program
/// is partway through an update (synchronized output, mode 2026), 2 when
/// it hid the cursor the last frame showed. ConPTY passes console writes
/// on as they're made, so PSReadLine's `?25l`, line redraw, and `?25h`
/// often arrive apart; a frame between them flashes the cursor off on
/// every key.
export fn slime_vt_view_hold(v: ?*View, t: Terminal) u8 {
    const self = v orelse return 0;
    const term = zigTerminal(t) orelse return 0;
    if (term.modes.get(.synchronized_output)) return 1;
    if (!term.modes.get(.cursor_visible) and self.state.cursor.visible) return 2;
    return 0;
}

/// End synchronized output that held frames too long, as Ghostty does,
/// so a program that never ends its update can't freeze the screen.
export fn slime_vt_end_sync(t: Terminal) void {
    const term = zigTerminal(t) orelse return;
    term.modes.set(.synchronized_output, false);
}

/// Encode a frame of what changed in `t` since the last one, or of
/// everything if `full`, which also means a client that has none of
/// the images. The bytes are the View's own, valid until the next frame
/// (slime_vt_view_image doesn't touch them). Returns false if out of
/// memory.
export fn slime_vt_view_frame(
    v: ?*View,
    t: Terminal,
    full: bool,
    out_ptr: *[*]const u8,
    out_len: *usize,
) bool {
    const self = v orelse return false;
    const term = zigTerminal(t) orelse return false;
    self.state.update(alloc, term) catch return false;
    if (full) self.images.reset();
    self.images.gather(alloc, term) catch return false;
    const palette = self.state.colors.palette;
    const palette_changed = if (self.palette) |p| !std.mem.eql(vt.color.RGB, &p, &palette) else true;
    self.frame.clearRetainingCapacity();
    Frames.encode(&self.frame.writer, &self.state, .{
        .full = full,
        .palette = palette_changed,
        .motion = term.flags.mouse_event == .any,
        .mouse_shape = std.math.cast(u8, @intFromEnum(term.mouse_shape)) orelse 0,
        .images = &self.images,
    }) catch return false;
    self.state.clean();
    self.palette = palette;
    const bytes = self.frame.written();
    out_ptr.* = bytes.ptr;
    out_len.* = bytes.len;
    return true;
}

/// An image the client needs before the last frame (view.go's Image).
const Image = extern struct {
    id: u32 = 0,
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    /// Straight RGBA, rows top-down, `width * height * 4` bytes.
    ptr: ?[*]const u8 = null,
    len: usize = 0,
};

/// The `i`th image the last frame places that the client lacks, to send
/// before it. Returns 0 past the last, 1 with the image (its pixels are
/// the View's, valid until the next image or the View's end), 2 if it's
/// gone from the terminal or won't fit in memory, to skip.
export fn slime_vt_view_image(v: ?*View, t: Terminal, i: usize, out: *Image) u8 {
    const self = v orelse return 0;
    const term = zigTerminal(t) orelse return 0;
    out.* = .{};
    if (i >= self.images.pending.items.len) return 0;
    if (self.image_rgba) |rgba| alloc.free(rgba);
    self.image_rgba = null;
    const px = (self.images.pixels(alloc, term, i) catch null) orelse return 2;
    self.image_rgba = px.rgba;
    out.* = .{
        .id = px.id,
        .generation = px.generation,
        .width = px.width,
        .height = px.height,
        .ptr = px.rgba.ptr,
        .len = px.rgba.len,
    };
    return 1;
}

/// Handle an event (event.zig) from the client. `win32_input` is whether
/// the program asked for win32-input-mode (DEC 9001), which
/// libghostty-vt leaves to us. Returns false for a bad event or no
/// memory.
export fn slime_vt_view_event(
    v: ?*View,
    t: Terminal,
    win32_input: bool,
    ptr: [*]const u8,
    len: usize,
    result: *Result,
) bool {
    const self = v orelse return false;
    const term = zigTerminal(t) orelse return false;
    result.* = .{};
    self.out.clearRetainingCapacity();
    self.copied.clearRetainingCapacity();
    const ev = Events.decode(ptr[0..len], &self.scratch) catch return false;
    handle(self, term, win32_input, ev, result) catch return false;
    finish(self, result);
    return true;
}

/// Scroll the viewport one row toward a selection drag past an edge,
/// and extend the selection there.
export fn slime_vt_view_autoscroll(v: ?*View, t: Terminal, result: *Result) bool {
    const self = v orelse return false;
    const term = zigTerminal(t) orelse return false;
    result.* = .{};
    self.out.clearRetainingCapacity();
    self.copied.clearRetainingCapacity();
    const sel = self.gesture.autoscrollTick(term, .{
        .viewport = cellAt(self, term, self.drag.x, self.drag.y),
        .xpos = self.drag.x,
        .ypos = self.drag.y,
        .rectangle = self.drag.rectangle,
        .word_boundary_codepoints = self.word_boundary.items,
        .geometry = dragGeometry(self, term),
    });
    // A reset gesture (the screen switched) leaves the selection alone.
    if (self.gesture.left_click_count != 0) {
        term.screens.active.select(sel) catch return false;
        result.changed = true;
    }
    finish(self, result);
    return true;
}

fn finish(self: *View, result: *Result) void {
    const out = self.out.written();
    if (out.len > 0) {
        result.pty_ptr = out.ptr;
        result.pty_len = out.len;
    }
    if (result.copied) {
        const text = self.copied.written();
        result.copied_ptr = text.ptr;
        result.copied_len = text.len;
    }
    result.autoscroll = self.selecting and self.gesture.left_drag_autoscroll != .none;
}

const Error = std.Io.Writer.Error || std.mem.Allocator.Error || error{ SelectionFailed, EncodeFailed };

fn handle(self: *View, t: *vt.Terminal, win32_input: bool, ev: Events.Event, result: *Result) Error!void {
    const w = &self.out.writer;
    switch (ev) {
        .key => |k| {
            const e = k.event;
            if (win32_input) {
                for (k.win32) |rec| try rec.encode(w);
                if (e.action != .release and !e.key.modifier()) typed(t, result);
                return;
            }
            const opts: vt.input.KeyEncodeOptions = .fromTerminal(t);
            vt.input.encodeKey(w, e, opts) catch return error.EncodeFailed;
            // Following fixterms, the legacy encoder leaves ctrl+[, ctrl+i,
            // and ctrl+m to CSI u, which it only emits with the key's
            // plain text, so they encode to nothing. Send the C0 byte
            // Windows produced (ESC, TAB, CR), as xterm and Windows
            // Terminal do.
            if (self.out.written().len == 0 and e.action != .release and
                e.utf8.len == 1 and std.ascii.isControl(e.utf8[0]))
            {
                try w.writeByte(e.utf8[0]);
            }
            if (self.out.written().len > 0 and e.action != .release and !e.key.modifier()) typed(t, result);
        },
        .text => |text| {
            if (win32_input) {
                // A press and release of no key per UTF-16 unit, carrying
                // the text, as WM_CHAR delivered it.
                var it = std.unicode.Utf8View.initUnchecked(text).iterator();
                while (it.nextCodepoint()) |cp| {
                    var units: [2]u16 = undefined;
                    const len = utf16Units(cp, &units);
                    for (units[0..len]) |unit| for ([_]bool{ true, false }) |down| {
                        try (event.Win32Key{ .char = unit, .down = down }).encode(w);
                    };
                }
            } else {
                try w.writeAll(text);
            }
            typed(t, result);
        },
        .paste => |text| {
            const opts: vt.input.PasteOptions = .fromTerminal(t);
            // The encoder replaces control bytes in place.
            const copy = try alloc.dupe(u8, text);
            defer alloc.free(copy);
            for (vt.input.encodePaste(copy, opts)) |part| try w.writeAll(part);
            typed(t, result);
        },
        .focus => |gained| {
            if (!t.modes.get(.focus_event)) return;
            vt.input.encodeFocus(w, if (gained) .gained else .lost) catch return error.EncodeFailed;
        },
        .mouse => |m| try mouse(self, t, m, result),
        .wheel => |m| try wheel(self, t, m, result),
        .copy => |tag| {
            result.copy_tag = tag;
            result.copied = true;
            const screen = t.screens.active;
            const sel = screen.selection orelse return;
            const text = screen.selectionString(alloc, .{ .sel = sel }) catch return error.SelectionFailed;
            defer alloc.free(text);
            try self.copied.writer.writeAll(text);
        },
        .geometry => |g| self.geometry = g,
        .settings => |s| {
            self.double_click_ms = s.double_click_ms;
            self.word_boundary.clearRetainingCapacity();
            try self.word_boundary.appendSlice(alloc, s.word_boundary);
            // Keeping what the program changed (OSC 4/10/11/12).
            const colors = &t.colors;
            colors.background.default = s.colors.background;
            colors.foreground.default = s.colors.foreground;
            colors.cursor.default = s.colors.cursor;
            try colors.palette.changeDefault(t.gpa(), s.colors.palette);
            result.changed = true;
        },
        .cancel => if (self.selecting) endSelection(self, t, null),
    }
}

/// UTF-16 units of a codepoint.
fn utf16Units(cp: u21, out: *[2]u16) usize {
    if (cp < 0x10000) {
        out[0] = @intCast(cp);
        return 1;
    }
    const v = cp - 0x10000;
    out[0] = @intCast(0xD800 + (v >> 10));
    out[1] = @intCast(0xDC00 + (v & 0x3FF));
    return 2;
}

/// Drop the selection and bring the viewport back from scrollback, as
/// typing does.
fn typed(t: *vt.Terminal, result: *Result) void {
    const screen = t.screens.active;
    if (screen.selection != null) {
        screen.clearSelection();
        result.changed = true;
    }
    if (screen.pages.viewport == .active) return;
    t.scrollViewport(.bottom);
    result.changed = true;
}

/// Report a mouse button press or release, or motion, if the program
/// asked for mouse events; else select with the left button. Shift
/// selects even when it asked.
fn mouse(self: *View, t: *vt.Terminal, m: Events.Mouse, result: *Result) Error!void {
    if (!self.selecting and m.button == .left and m.action == .press) {
        if (t.flags.mouse_event != .none and !m.mods.shift) {
            self.gesture.reset(t);
        } else {
            self.selecting = true;
        }
    }
    if (self.selecting) return selectionInput(self, t, m, result);

    var opts: MouseEncodeOptions = .fromTerminal(t, surfaceSize(self, t));
    opts.any_button_pressed = m.held;
    opts.last_cell = &self.mouse_cell;
    vt.input.encodeMouse(&self.out.writer, .{
        .action = m.action,
        .button = m.button,
        .mods = m.mods,
        .pos = .{ .x = m.x, .y = m.y },
    }, opts) catch return error.EncodeFailed;
}

/// Start, extend, or finish a selection with the left button: a click
/// clears it, a drag selects cells (a rectangle with ctrl+alt), and
/// double and triple clicks select words and lines.
fn selectionInput(self: *View, t: *vt.Terminal, m: Events.Mouse, result: *Result) Error!void {
    const pin = t.screens.active.pages.pin(.{ .viewport = cellAt(self, t, m.x, m.y) }) orelse return;
    const sel: ?vt.Selection = sel: {
        if (m.action == .press and m.button == .left) {
            break :sel self.gesture.press(t, .{
                .time = .{ .nanoseconds = @as(i96, m.time) * std.time.ns_per_ms },
                .pin = pin,
                .xpos = m.x,
                .ypos = m.y,
                .max_distance = @floatFromInt(self.geometry.cell_width),
                .repeat_interval = @as(u64, self.double_click_ms) * std.time.ns_per_ms,
                .word_boundary_codepoints = self.word_boundary.items,
            }) catch return error.SelectionFailed;
        }
        if (m.action == .motion and m.held) {
            self.drag = .{ .x = m.x, .y = m.y, .rectangle = m.mods.ctrl and m.mods.alt };
            break :sel self.gesture.drag(t, .{
                .pin = pin,
                .xpos = m.x,
                .ypos = m.y,
                .rectangle = self.drag.rectangle,
                .word_boundary_codepoints = self.word_boundary.items,
                .geometry = dragGeometry(self, t),
            });
        }
        if (m.action == .release and m.button == .left) {
            endSelection(self, t, pin);
        }
        return;
    };
    t.screens.active.select(sel) catch return error.SelectionFailed;
    result.changed = true;
}

/// Finish a selection drag, at `pin` if the button was released over a
/// cell.
fn endSelection(self: *View, t: *vt.Terminal, pin: ?vt.Pin) void {
    self.gesture.release(t, .{ .pin = pin });
    self.selecting = false;
}

/// Scroll with the wheel: report wheel buttons if the program asked for
/// mouse events, else send arrow keys on the alternate screen with
/// alternate scroll (mode 1007) set, else move the viewport through
/// scrollback.
fn wheel(self: *View, t: *vt.Terminal, m: Events.Wheel, result: *Result) Error!void {
    const reporting = t.flags.mouse_event != .none;
    const alternate_scroll = !reporting and
        t.screens.active_key == .alternate and
        t.modes.get(.mouse_alternate_scroll);
    if (m.horizontal and !reporting) return;

    // Reports are one per notch; programs pick how far that scrolls.
    const lines: u32 = if (reporting) 1 else if (m.lines_per_notch == event.lines_page) t.rows else @min(m.lines_per_notch, t.rows);
    const remainder = &self.wheel_remainder[@intFromBool(m.horizontal)];
    remainder.* += @as(i32, m.rotation) * @as(i32, @intCast(lines));
    const wheel_delta = 120;
    const steps = @divTrunc(remainder.*, wheel_delta);
    remainder.* -= steps * wheel_delta;
    if (steps == 0) return;
    // Positive rotation is away from the user, or to the right.
    const up = steps > 0;
    const count = @abs(steps);

    if (reporting) {
        var opts: MouseEncodeOptions = .fromTerminal(t, surfaceSize(self, t));
        opts.last_cell = &self.mouse_cell;
        const ev: vt.input.MouseEncodeEvent = .{
            .button = if (m.horizontal)
                (if (up) .seven else .six)
            else
                (if (up) .four else .five),
            .mods = m.mods,
            .pos = .{ .x = m.x, .y = m.y },
        };
        for (0..count) |_| vt.input.encodeMouse(&self.out.writer, ev, opts) catch return error.EncodeFailed;
    } else if (alternate_scroll) {
        const seq: []const u8 = if (t.modes.get(.cursor_keys))
            (if (up) "\x1bOA" else "\x1bOB")
        else
            (if (up) "\x1b[A" else "\x1b[B");
        for (0..count) |_| try self.out.writer.writeAll(seq);
    } else {
        const delta: isize = @intCast(count);
        t.scrollViewport(.{ .delta = if (up) -delta else delta });
        result.changed = true;
    }
}

fn dragGeometry(self: *const View, t: *const vt.Terminal) vt.SelectionGesture.Drag.Geometry {
    return .{
        .columns = t.cols,
        .cell_width = self.geometry.cell_width,
        .padding_left = self.geometry.padding.left,
        .screen_height = self.geometry.height,
    };
}

/// The viewport cell under a position, clamped to the grid.
fn cellAt(self: *const View, t: *const vt.Terminal, px: f32, py: f32) vt.Coordinate {
    const g = self.geometry;
    const x: i64 = @intFromFloat(@floor((px - @as(f32, @floatFromInt(g.padding.left))) / @as(f32, @floatFromInt(@max(g.cell_width, 1)))));
    const y: i64 = @intFromFloat(@floor((py - @as(f32, @floatFromInt(g.padding.top))) / @as(f32, @floatFromInt(@max(g.cell_height, 1)))));
    return .{
        .x = @intCast(std.math.clamp(x, 0, @as(i64, t.cols) - 1)),
        .y = @intCast(std.math.clamp(y, 0, @as(i64, t.rows) - 1)),
    };
}

/// The pane as the mouse encoder sees it, to map positions to cells.
fn surfaceSize(self: *const View, t: *const vt.Terminal) @FieldType(MouseEncodeOptions, "size") {
    const g = self.geometry;
    return .{
        .screen = .{ .width = g.width, .height = g.height },
        .cell = .{ .width = g.cell_width, .height = g.cell_height },
        .padding = .{
            .top = g.padding.top,
            .left = g.padding.left,
            .right = g.width -| g.padding.left -| @as(u32, t.cols) * g.cell_width,
            .bottom = g.height -| g.padding.top -| @as(u32, t.rows) * g.cell_height,
        },
    };
}
