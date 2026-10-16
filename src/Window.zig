//! A top-level Win32 window showing one terminal. Heap allocated so that
//! its address can be stored in the HWND's user data, and so the stream's
//! pointer to `terminal` stays valid.
//!
//! A reader thread feeds the child's output to the stream; the UI thread
//! renders and handles input. `lock` guards `terminal` and `stream`
//! between them.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");
const font = @import("font/font.zig");
const input = @import("input.zig");
const Pty = @import("Pty.zig");
const clipboard = @import("clipboard.zig");
const Stats = @import("Stats.zig");
const build_options = @import("build_options");
const Renderer = @import("renderer/D3D11.zig");
const Cells = @import("renderer/cells.zig").Cells;

const log = std.log.scoped(.window);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ghostty-win");

/// Posted from a thread pool wait when the child process exits.
const WM_APP_CHILD_EXITED = win32.WM_APP + 0;

const StreamHandler = @FieldType(ghostty_vt.TerminalStream, "handler");
const MouseButton = ghostty_vt.input.MouseButton;
const MouseAction = ghostty_vt.input.MouseAction;
const MouseEvent = ghostty_vt.input.MouseEncodeEvent;
const MouseEncodeOptions = ghostty_vt.input.MouseEncodeOptions;

const stats_timer_id = 1;
/// Draws pending output while DefWindowProc's modal move/size loop runs
/// instead of ours.
const sizemove_timer_id = 2;
/// Scrolls the viewport while a selection drag is above or below it.
const autoscroll_timer_id = 3;
/// Blinks the cursor while the window has focus.
const blink_timer_id = 4;

/// How long a frame waits for a cursor that output just hid to come
/// back. See `updateHold`.
const cursor_hold_ms = 8;
/// How long synchronized output (mode 2026) can hold frames back before
/// we reset it, Ghostty's `sync_reset_ms`.
const sync_hold_ms = 1000;

/// Characters that end a word for double-click selection, Ghostty's
/// `selection-word-chars` default.
const word_boundaries = [_]u21{ 0, ' ', '\t', '\'', '"', '\u{2502}', '`', '|', ':', ';', ',', '(', ')', '[', ']', '{', '}', '<', '>', '$' };

const font_size_pt = 12;

/// Space between the window edge and the grid, in 96-DPI pixels.
const padding = 4;

/// Ghostty's default colors. Programs can override these with OSC 10/11.
const default_colors: ghostty_vt.Terminal.Colors = .{
    .background = .init(.{ .r = 0x28, .g = 0x2c, .b = 0x34 }),
    .foreground = .init(.{ .r = 0xff, .g = 0xff, .b = 0xff }),
    .cursor = .unset,
    .palette = .default,
};

alloc: Allocator,
hwnd: ?win32.HWND = null,
title: [:0]const u16,
dpi: u32 = win32.USER_DEFAULT_SCREEN_DPI,

grid: font.Grid,
lock: win32.SRWLOCK = .{},
terminal: ghostty_vt.Terminal,
stream: ghostty_vt.TerminalStream,
render_state: ghostty_vt.RenderState = .empty,
cells: Cells = .{},

/// Set last during creation; messages sent during CreateWindowExW
/// (WM_SIZE, etc.) arrive before everything else is ready.
renderer: ?Renderer = null,

pty: ?Pty = null,
reader: ?std.Thread = null,
exit_wait: ?win32.HANDLE = null,

/// Auto-reset event the reader thread sets after feeding output to the
/// terminal. The message loop waits on it alongside messages and calls
/// `outputArrived`. Not a posted message: those are retrieved before input
/// and timers, so a steady stream of them starves the keyboard.
output_event: win32.HANDLE,

/// The terminal changed since the last frame. UI thread only.
dirty: bool = false,

/// Why frames are being held back, if they are. `hold_timer` fires when
/// the hold runs out. UI thread only.
hold: Hold = .none,
hold_timer: win32.HANDLE,

/// The last frame showed the terminal's cursor (blinking aside).
cursor_shown: bool = false,

/// The window has keyboard focus.
focused: bool = false,

/// The on phase of the cursor blink.
blink_visible: bool = true,

/// The first half of a surrogate pair from a lone WM_CHAR.
high_surrogate: ?u16 = null,

/// win32-input-mode (mode 9001): send keys as Win32 key events. Whoever
/// is on the other end of the VT stream asks for it, which in practice
/// is a ConPTY (ours, or a remote Windows host's), so it follows the
/// stream rather than the transport. Guarded by `lock`.
win32_input: bool = false,

/// The cell the last mouse event was reported in, so motion within one
/// cell is reported once.
mouse_cell: ?ghostty_vt.Coordinate = null,

/// Wheel rotation not yet turned into scrolling, vertical then
/// horizontal, in 1/WHEEL_DELTA notches times the lines per notch.
wheel_remainder: [2]i32 = .{ 0, 0 },

/// Click, drag, and multi-click state for selecting text with the left
/// button. Guarded by `lock`.
selection: ghostty_vt.SelectionGesture = .init,

/// A left button drag is selecting text rather than being reported.
selecting: bool = false,

/// Where the selection drag last was, in client coordinates, for
/// autoscroll ticks.
drag_pos: win32.POINT = .{ .x = 0, .y = 0 },

/// The virtual key of the last key binding run, so its release isn't
/// sent to the child either.
bound_key: ?u32 = null,

/// Only used with `-Dstats`.
stats: Stats = .{},

const Hold = enum {
    none,
    /// The cursor the last frame showed was hidden.
    cursor,
    /// Synchronized output (mode 2026) is set.
    sync,
};

/// Create the window and run `command_line` (CreateProcessW syntax;
/// modified in place) in it.
pub fn create(alloc: Allocator, io: std.Io, title: [:0]const u16, command_line: win32.LPWSTR) !*Window {
    const instance = win32.GetModuleHandleW(null);
    try registerClass(instance);

    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);
    const output_event = win32.CreateEventW(null, win32.FALSE, win32.FALSE, null) orelse
        return win32.lastError("CreateEventW");
    errdefer _ = win32.CloseHandle(output_event);
    // Manual reset, so a hold that ran out stays due until it's handled.
    const hold_timer = win32.CreateWaitableTimerExW(
        null,
        null,
        win32.CREATE_WAITABLE_TIMER_MANUAL_RESET | win32.CREATE_WAITABLE_TIMER_HIGH_RESOLUTION,
        win32.TIMER_ALL_ACCESS,
    ) orelse return win32.lastError("CreateWaitableTimerExW");
    errdefer _ = win32.CloseHandle(hold_timer);
    self.* = .{
        .alloc = alloc,
        .title = title,
        .output_event = output_event,
        .hold_timer = hold_timer,
        .grid = undefined,
        .terminal = undefined,
        .stream = undefined,
    };

    // WS_EX_NOREDIRECTIONBITMAP: we present through a flip-model swap
    // chain, so DWM doesn't need a GDI redirection surface for us.
    _ = win32.CreateWindowExW(
        win32.WS_EX_NOREDIRECTIONBITMAP,
        class_name,
        title.ptr,
        win32.WS_OVERLAPPEDWINDOW,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        win32.CW_USEDEFAULT,
        null,
        null,
        instance,
        self,
    ) orelse return win32.lastError("CreateWindowExW");
    const hwnd = self.hwnd.?;
    errdefer _ = win32.DestroyWindow(hwnd);

    const dark: win32.BOOL = win32.TRUE;
    _ = win32.DwmSetWindowAttribute(hwnd, win32.DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, @sizeOf(win32.BOOL));

    self.dpi = win32.GetDpiForWindow(hwnd);
    self.grid = try .init(alloc, font_size_pt, self.dpi);
    errdefer self.grid.deinit();

    const size = self.clientSize();
    const grid_size = self.gridSize(size.width, size.height);
    self.terminal = try .init(io, alloc, .{
        .cols = grid_size.cols,
        .rows = grid_size.rows,
        .colors = default_colors,
        // Mode 2027: cluster multi-codepoint graphemes (emoji sequences,
        // combining marks) into one cell, as the Ghostty app does.
        .default_modes = .{ .grapheme_cluster = true },
        // Null blinks, as Ghostty does by default, including after a
        // DECSCUSR 0, RIS, or DECSTR. Mode 12 and DECSCUSR change it.
        .default_cursor_blink = null,
    });
    errdefer self.terminal.deinit(alloc);
    // An arrow until the child asks for another shape with OSC 22. An
    // I-beam (Ghostty's default) looks wrong over TUIs. An empty OSC 22
    // still resets it to the I-beam.
    self.terminal.mouse_shape = .default;
    self.stream = self.terminal.vtStream();
    errdefer self.stream.deinit();
    self.stream.handler.effects.write_pty = &writePty;
    self.stream.handler.effects.device_attributes = &deviceAttributes;
    self.stream.handler.unknown_sequence = &unknownSequence;

    self.renderer = try Renderer.init(hwnd, size.width, size.height);
    errdefer {
        self.renderer.?.deinit();
        self.renderer = null;
    }

    self.pty = try .spawn(command_line, grid_size.cols, grid_size.rows);
    errdefer self.stopPty();
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});

    var wait: win32.HANDLE = undefined;
    if (win32.RegisterWaitForSingleObject(
        &wait,
        self.pty.?.process,
        onChildExited,
        hwnd,
        win32.INFINITE,
        win32.WT_EXECUTEONLYONCE,
    ) == 0) return win32.lastError("RegisterWaitForSingleObject");
    self.exit_wait = wait;

    if (build_options.stats) {
        self.stats = .init();
        _ = win32.SetTimer(hwnd, stats_timer_id, 1000, null);
    }

    _ = win32.ShowWindow(hwnd, win32.SW_SHOWDEFAULT);
    return self;
}

/// Free the window. The HWND must already be destroyed (the message
/// loop has exited).
pub fn destroy(self: *Window) void {
    self.stopPty();
    if (self.renderer) |*r| {
        r.deinit();
        self.cells.deinit(self.alloc);
        self.render_state.deinit(self.alloc);
        self.selection.deinit(&self.terminal);
        self.stream.deinit();
        self.terminal.deinit(self.alloc);
        self.grid.deinit();
    }
    _ = win32.CloseHandle(self.output_event);
    _ = win32.CloseHandle(self.hold_timer);
    self.alloc.destroy(self);
}

/// The message loop's view of frame pacing: when `output_event` fires,
/// call `outputArrived`; while `needsFrame`, also wait on `frameGate` and
/// pass it to `frameGateFired` when it fires. Drawing then happens at most
/// once per display refresh, and right away when the terminal was idle.
pub fn outputArrived(self: *Window) void {
    self.dirty = true;
    self.updateHold();
}

pub fn needsFrame(self: *const Window) bool {
    return self.dirty;
}

pub fn frameGate(self: *const Window) win32.HANDLE {
    if (self.hold != .none) return self.hold_timer;
    return self.renderer.?.frameGate();
}

pub fn frameGateFired(self: *Window, gate: win32.HANDLE) void {
    if (gate == self.hold_timer) return self.holdExpired();
    const r = &self.renderer.?;
    // The pace timer only moves us on to waiting for the swap chain.
    if (gate != r.frame_waitable) return;
    r.frameAcquired();
    // A synchronous render (resize, WM_PAINT) may have drawn it already;
    // the acquired frame then waits for the next change.
    if (self.dirty) self.render();
}

/// Hold frames back while the child is partway through an update: while
/// synchronized output (mode 2026) is set, and briefly after it hides
/// the cursor the last frame showed. ConPTY passes console writes on as
/// they're made, so PSReadLine's `?25l`, line redraw, and `?25h` often
/// arrive in separate reads; drawing between them flashes a frame
/// without the cursor on every key.
fn updateHold(self: *Window) void {
    self.lockTerminal();
    const sync = self.terminal.modes.get(.synchronized_output);
    const cursor_hidden = !self.terminal.modes.get(.cursor_visible);
    self.unlockTerminal();

    const hold: Hold = if (sync) .sync else if (cursor_hidden and self.cursor_shown) .cursor else .none;
    if (hold == self.hold) return;
    self.hold = hold;
    const ms: i64 = switch (hold) {
        .none => return,
        .cursor => cursor_hold_ms,
        .sync => sync_hold_ms,
    };
    // Negative due times are relative, in 100 ns units. Setting the timer
    // also unsignals it.
    const due = -ms * 10_000;
    _ = win32.SetWaitableTimer(self.hold_timer, &due, 0, null, null, win32.FALSE);
}

/// Draw the held frame anyway.
fn holdExpired(self: *Window) void {
    // The timer may have been set again since it fired.
    if (win32.WaitForSingleObject(self.hold_timer, 0) != win32.WAIT_OBJECT_0) return;
    switch (self.hold) {
        .none => {},
        .cursor => self.cursor_shown = false,
        // Ghostty resets the mode too, so a child that never ends its
        // update can't freeze the screen.
        .sync => {
            self.lockTerminal();
            self.terminal.modes.set(.synchronized_output, false);
            self.unlockTerminal();
        },
    }
    self.hold = .none;
}

/// Close the pseudoconsole, wait for the reader to drain it, and kill
/// whatever is left of the child's process tree.
fn stopPty(self: *Window) void {
    if (self.exit_wait) |wait| {
        // INVALID_HANDLE_VALUE: wait for a running callback to finish.
        _ = win32.UnregisterWaitEx(wait, win32.INVALID_HANDLE_VALUE);
        self.exit_wait = null;
    }
    const pty = &(self.pty orelse return);
    pty.close();
    if (self.reader) |t| t.join();
    self.reader = null;
    pty.deinit();
    self.pty = null;
}

fn lockTerminal(self: *Window) void {
    win32.AcquireSRWLockExclusive(&self.lock);
}

fn unlockTerminal(self: *Window) void {
    win32.ReleaseSRWLockExclusive(&self.lock);
}

/// Reader thread: feed child output to the terminal until EOF, which
/// comes when the pseudoconsole is closed.
fn readLoop(self: *Window) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = self.pty.?.read(&buf) catch break;
        if (n == 0) break;

        self.lockTerminal();
        self.stream.nextSlice(buf[0..n]);
        self.unlockTerminal();
        if (build_options.stats) _ = self.stats.bytes.fetchAdd(n, .monotonic);
        _ = win32.SetEvent(self.output_event);
    }
}

fn onChildExited(ctx: ?*anyopaque, _: u8) callconv(.winapi) void {
    _ = win32.PostMessageW(@ptrCast(ctx), WM_APP_CHILD_EXITED, 0, 0);
}

/// Stream effect for query replies (DSR, DECRQM, ...). Runs on the
/// reader thread with the terminal locked, so it must not wait on the
/// UI thread.
fn writePty(handler: *StreamHandler, data: []const u8) void {
    const stream: *ghostty_vt.TerminalStream = @fieldParentPtr("handler", handler);
    const self: *Window = @alignCast(@fieldParentPtr("stream", stream));
    if (self.pty) |*pty| pty.write(data);
}

/// ConPTY asks for DA1 at startup to learn what the terminal supports.
fn deviceAttributes(_: *StreamHandler) ghostty_vt.device_attributes.Attributes {
    return .{};
}

/// Encode a key message and send it to the child.
/// Track the modes libghostty-vt leaves to us. Runs on the reader thread
/// with the terminal locked.
fn unknownSequence(handler: *StreamHandler, seq: StreamHandler.UnknownSequence) void {
    const stream: *ghostty_vt.TerminalStream = @fieldParentPtr("handler", handler);
    const self: *Window = @alignCast(@fieldParentPtr("stream", stream));
    switch (seq) {
        .mode => |m| if (m.mode == 9001 and !m.ansi) {
            self.win32_input = m.enabled;
        },
        else => {},
    }
}

fn keyInput(self: *Window, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    // TranslateMessage already posted the WM_(SYS)CHAR / WM_(SYS)DEADCHAR
    // messages this key produced. Take them so the key and its text are
    // encoded together, as one event.
    var utf16: [16]u16 = undefined;
    var len: usize = 0;
    var composing = false;
    if (msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) {
        var m: win32.MSG = undefined;
        while (len < utf16.len) {
            if (win32.PeekMessageW(&m, self.hwnd, win32.WM_CHAR, win32.WM_DEADCHAR, win32.PM_REMOVE) == 0 and
                win32.PeekMessageW(&m, self.hwnd, win32.WM_SYSCHAR, win32.WM_SYSDEADCHAR, win32.PM_REMOVE) == 0) break;
            if (m.message == win32.WM_DEADCHAR or m.message == win32.WM_SYSDEADCHAR) {
                composing = true;
            } else {
                utf16[len] = @truncate(m.wParam);
                len += 1;
            }
        }
    }
    self.lockTerminal();
    const win32_input = self.win32_input;
    const opts: ghostty_vt.input.KeyEncodeOptions = .fromTerminal(&self.terminal);
    self.unlockTerminal();
    if (win32_input) return self.win32KeyInput(msg, wparam, lparam, utf16[0..len]);

    var utf8: [64]u8 = undefined;
    const text_len = std.unicode.utf16LeToUtf8(&utf8, utf16[0..len]) catch 0;
    const event = input.keyEvent(msg, wparam, lparam, utf8[0..text_len], composing);

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ghostty_vt.input.encodeKey(&w, event, opts) catch |err| {
        log.warn("key encode failed: {}", .{err});
        return;
    };
    // Following fixterms, the legacy encoder leaves ctrl+[, ctrl+i, and
    // ctrl+m to CSI u, which it only emits with the key's plain text, so
    // they encode to nothing. Send the C0 byte Windows produced (ESC,
    // TAB, CR), as xterm and Windows Terminal do.
    if (w.buffered().len == 0 and event.action != .release and
        text_len == 1 and std.ascii.isControl(utf8[0]))
    {
        w.writeByte(utf8[0]) catch unreachable;
    }
    if (w.buffered().len == 0) return;
    if (event.action != .release and !event.key.modifier()) self.typed();
    if (self.pty) |*pty| pty.write(w.buffered());
}

/// Run the key binding a key press triggers, Ghostty's defaults: copy
/// with ctrl+shift+c (when there is a selection) or ctrl+insert, paste
/// with ctrl+shift+v (when the clipboard has text) or shift+insert.
/// Returns true if the key is consumed, which also holds for the release
/// of a key that ran a binding.
fn keyBinding(self: *Window, msg: u32, wparam: win32.WPARAM) bool {
    const vk: u32 = @truncate(wparam);
    if (msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP) {
        if (self.bound_key != vk) return false;
        self.bound_key = null;
        return true;
    }

    const mods = input.currentMods();
    if (mods.alt or mods.super) return false;
    if (mods.ctrl and mods.shift and vk == 'C') {
        if (!self.copySelection()) return false;
    } else if (mods.ctrl and !mods.shift and vk == win32.VK_INSERT) {
        _ = self.copySelection();
    } else if (mods.ctrl and mods.shift and vk == 'V') {
        if (!clipboard.hasText()) return false;
        self.paste();
    } else if (!mods.ctrl and mods.shift and vk == win32.VK_INSERT) {
        self.paste();
    } else return false;

    // Drop the text TranslateMessage posted for the key (ctrl+shift+c
    // gives 0x03).
    var m: win32.MSG = undefined;
    while (win32.PeekMessageW(&m, self.hwnd, win32.WM_CHAR, win32.WM_DEADCHAR, win32.PM_REMOVE) != 0) {}
    self.bound_key = vk;
    return true;
}

/// Copy the selected text to the clipboard. Returns false if nothing is
/// selected.
fn copySelection(self: *Window) bool {
    self.lockTerminal();
    const screen = self.terminal.screens.active;
    const sel = screen.selection orelse {
        self.unlockTerminal();
        return false;
    };
    const text = screen.selectionString(self.alloc, .{ .sel = sel });
    self.unlockTerminal();

    const utf8 = text catch |err| {
        log.err("selection to text failed: {}", .{err});
        return true;
    };
    defer self.alloc.free(utf8);
    clipboard.set(self.hwnd.?, utf8) catch |err| log.err("copy failed: {}", .{err});
    return true;
}

/// Send the clipboard's text to the child: bracketed if it asked for
/// that (mode 2004), else with newlines as CR, as the enter key sends.
/// Either way, control bytes that could signal the child or end the
/// paste early (ESC, ^C, ...) become spaces.
fn paste(self: *Window) void {
    const text = (clipboard.get(self.alloc, self.hwnd.?) catch |err| {
        log.err("paste failed: {}", .{err});
        return;
    }) orelse return;
    defer self.alloc.free(text);
    if (text.len == 0) return;

    self.lockTerminal();
    const opts: ghostty_vt.input.PasteOptions = .fromTerminal(&self.terminal);
    self.unlockTerminal();
    self.typed();
    const parts = ghostty_vt.input.encodePaste(text, opts);
    if (self.pty) |*pty| for (parts) |part| pty.write(part);
}

/// Send text from a WM_CHAR that no key message claimed: IME commits,
/// alt+numpad codes, and VK_PACKET input from SendInput.
fn charInput(self: *Window, unit: u16) void {
    self.lockTerminal();
    const win32_input = self.win32_input;
    self.unlockTerminal();
    if (win32_input) {
        // A press and release of no key, carrying the text. Surrogate
        // halves go as they come; the console pairs them.
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for ([_]bool{ true, false }) |down| {
            (input.Win32KeyEvent{ .char = unit, .down = down }).encode(&w) catch unreachable;
        }
        self.typed();
        if (self.pty) |*pty| pty.write(w.buffered());
        return;
    }

    var units: [2]u16 = undefined;
    const pair: []const u16 = if (std.unicode.utf16IsHighSurrogate(unit)) {
        self.high_surrogate = unit;
        return;
    } else if (std.unicode.utf16IsLowSurrogate(unit)) pair: {
        units = .{ self.high_surrogate orelse return, unit };
        break :pair &units;
    } else pair: {
        units[0] = unit;
        break :pair units[0..1];
    };
    self.high_surrogate = null;

    var utf8: [8]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8, pair) catch return;
    self.typed();
    if (self.pty) |*pty| pty.write(utf8[0..len]);
}

/// Send a key in win32-input-mode: one event per UTF-16 unit of text it
/// produced, or one with no text.
fn win32KeyInput(self: *Window, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM, text: []const u16) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (text.len == 0) {
        const up = msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP;
        const char = if (up) input.releaseChar(wparam, lparam) else 0;
        input.Win32KeyEvent.fromKey(msg, wparam, lparam, char).encode(&w) catch unreachable;
    }
    for (text) |unit| {
        input.Win32KeyEvent.fromKey(msg, wparam, lparam, unit).encode(&w) catch unreachable;
    }
    if ((msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) and !input.isModifier(wparam, lparam)) self.typed();
    if (self.pty) |*pty| pty.write(w.buffered());
}

/// Drop the selection, bring the viewport back from scrollback, and show
/// the cursor, as typing does.
fn typed(self: *Window) void {
    self.resetBlink();
    self.lockTerminal();
    defer self.unlockTerminal();
    const screen = self.terminal.screens.active;
    if (screen.selection != null) {
        screen.clearSelection();
        self.dirty = true;
    }
    if (screen.pages.viewport == .active) return;
    self.terminal.scrollViewport(.bottom);
    self.dirty = true;
}

/// Track keyboard focus: the cursor blinks only while focused and is a
/// hollow block otherwise, and the child hears about it if it asked for
/// focus events (mode 1004). ConPTY always asks, and passes them on to
/// console programs as FOCUS_EVENT records.
fn setFocus(self: *Window, focused: bool) void {
    if (self.focused == focused) return;
    self.focused = focused;
    self.dirty = true;
    if (focused) {
        self.resetBlink();
    } else {
        _ = win32.KillTimer(self.hwnd, blink_timer_id);
    }

    self.lockTerminal();
    const report = self.terminal.modes.get(.focus_event);
    self.unlockTerminal();
    if (!report) return;
    var buf: [ghostty_vt.input.max_focus_encode_size]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ghostty_vt.input.encodeFocus(&w, if (focused) .gained else .lost) catch unreachable;
    if (self.pty) |*pty| pty.write(w.buffered());
}

/// Start the blink over in its on phase. Blinking follows the system's
/// caret blink rate, and is off when the user turned caret blinking off.
fn resetBlink(self: *Window) void {
    if (!self.blink_visible) {
        self.blink_visible = true;
        self.dirty = true;
    }
    if (!self.focused) return;
    const ms = win32.GetCaretBlinkTime();
    if (ms == 0 or ms == win32.INFINITE) {
        _ = win32.KillTimer(self.hwnd, blink_timer_id);
    } else {
        // Setting an existing timer restarts it.
        _ = win32.SetTimer(self.hwnd, blink_timer_id, ms, null);
    }
}

fn blinkTick(self: *Window) void {
    self.blink_visible = !self.blink_visible;
    // Only redraw if the last frame's cursor blinks. One that starts
    // blinking later picks up the phase from here.
    const cursor = self.render_state.cursor;
    if (cursor.visible and cursor.blinking) self.dirty = true;
}

/// Report a mouse button press or release, or motion, to the child if it
/// asked for mouse events.
fn mouseInput(self: *Window, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    const button: ?MouseButton, const action: MouseAction = if (input.mouseButton(msg, wparam)) |b|
        .{ b[0], if (b[1]) .press else .release }
    else
        .{ input.heldButton(wparam), .motion };

    // Capture the mouse while a button is down, so a drag past the edge
    // still reports and the release comes back to us.
    const held = input.heldButton(wparam) != null;
    if (action == .press) {
        _ = win32.SetCapture(self.hwnd.?);
    } else if (action == .release and !held) {
        _ = win32.ReleaseCapture();
    }

    self.lockTerminal();
    // Shift selects even when the child asks for mouse events.
    if (!self.selecting and button == .left and action == .press) {
        if (self.terminal.flags.mouse_event != .none and wparam & win32.MK_SHIFT == 0) {
            self.selection.reset(&self.terminal);
        } else {
            self.selecting = true;
        }
    }
    if (self.selecting) {
        defer self.unlockTerminal();
        return self.selectionInput(msg, wparam, lparam);
    }
    var opts: MouseEncodeOptions = .fromTerminal(&self.terminal, self.surfaceSize());
    self.unlockTerminal();
    opts.any_button_pressed = held;
    opts.last_cell = &self.mouse_cell;
    self.mouseReport(.{
        .action = action,
        .button = button,
        .mods = input.mouseMods(wparam),
        .pos = .{
            .x = @floatFromInt(win32.xLparam(lparam)),
            .y = @floatFromInt(win32.yLparam(lparam)),
        },
    }, opts);
}

/// Start, extend, or finish a selection with the left button: a click
/// clears it, a drag selects cells (a rectangle with ctrl+alt), and
/// double and triple clicks select words and lines. Call with the
/// terminal locked.
fn selectionInput(self: *Window, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    const t = &self.terminal;
    const pos: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    const pin = t.screens.active.pages.pin(.{ .viewport = self.cellAt(pos) }) orelse return;
    const sel: ?ghostty_vt.Selection = switch (msg) {
        win32.WM_LBUTTONDOWN => self.selection.press(t, .{
            .time = messageTime(),
            .pin = pin,
            .xpos = @floatFromInt(pos.x),
            .ypos = @floatFromInt(pos.y),
            .max_distance = @floatFromInt(self.grid.metrics.cell_width),
            .repeat_interval = @as(u64, win32.GetDoubleClickTime()) * std.time.ns_per_ms,
            .word_boundary_codepoints = &word_boundaries,
        }) catch |err| {
            log.err("selection failed: {}", .{err});
            return;
        },
        win32.WM_MOUSEMOVE => sel: {
            if (wparam & win32.MK_LBUTTON == 0) return;
            self.drag_pos = pos;
            const sel = self.selection.drag(t, .{
                .pin = pin,
                .xpos = @floatFromInt(pos.x),
                .ypos = @floatFromInt(pos.y),
                .rectangle = rectangleSelect(),
                .word_boundary_codepoints = &word_boundaries,
                .geometry = self.dragGeometry(),
            });
            self.updateAutoscroll();
            break :sel sel;
        },
        win32.WM_LBUTTONUP => {
            self.endSelection(pin);
            return;
        },
        else => return,
    };
    t.screens.active.select(sel) catch |err| log.err("selection failed: {}", .{err});
    self.dirty = true;
}

/// Scroll the viewport one row toward a selection drag above or below
/// it, and extend the selection there.
fn autoscrollTick(self: *Window) void {
    self.lockTerminal();
    defer self.unlockTerminal();
    const t = &self.terminal;
    const sel = self.selection.autoscrollTick(t, .{
        .viewport = self.cellAt(self.drag_pos),
        .xpos = @floatFromInt(self.drag_pos.x),
        .ypos = @floatFromInt(self.drag_pos.y),
        .rectangle = rectangleSelect(),
        .word_boundary_codepoints = &word_boundaries,
        .geometry = self.dragGeometry(),
    });
    self.updateAutoscroll();
    // A reset gesture (the screen switched) leaves the selection alone.
    if (self.selection.left_click_count == 0) return;
    t.screens.active.select(sel) catch |err| log.err("selection failed: {}", .{err});
    self.dirty = true;
}

/// Finish a selection drag, at `pin` if the button was released over a
/// cell. Call with the terminal locked.
fn endSelection(self: *Window, pin: ?ghostty_vt.Pin) void {
    self.selection.release(&self.terminal, .{ .pin = pin });
    self.selecting = false;
    self.updateAutoscroll();
}

/// Run the autoscroll timer while the drag asks for it.
fn updateAutoscroll(self: *Window) void {
    if (self.selection.left_drag_autoscroll == .none) {
        _ = win32.KillTimer(self.hwnd, autoscroll_timer_id);
    } else {
        _ = win32.SetTimer(self.hwnd, autoscroll_timer_id, 15, null);
    }
}

fn dragGeometry(self: *const Window) ghostty_vt.SelectionGesture.Drag.Geometry {
    return .{
        .columns = self.terminal.cols,
        .cell_width = self.grid.metrics.cell_width,
        .padding_left = self.paddingPx(),
        .screen_height = self.clientSize().height,
    };
}

/// The viewport cell under a client position, clamped to the grid. Call
/// with the terminal locked.
fn cellAt(self: *const Window, pos: win32.POINT) ghostty_vt.Coordinate {
    const m = self.grid.metrics;
    const pad: i32 = @intCast(self.paddingPx());
    const x = @divFloor(pos.x - pad, @as(i32, @intCast(m.cell_width)));
    const y = @divFloor(pos.y - pad, @as(i32, @intCast(m.cell_height)));
    return .{
        .x = @intCast(std.math.clamp(x, 0, @as(i32, self.terminal.cols) - 1)),
        .y = @intCast(std.math.clamp(y, 0, @as(i32, self.terminal.rows) - 1)),
    };
}

/// Ctrl+alt drags select a rectangle, as in Ghostty on Linux.
fn rectangleSelect() bool {
    const mods = input.currentMods();
    return mods.ctrl and mods.alt;
}

/// When the message being handled was posted, for telling double clicks
/// apart. GetMessageTime is milliseconds since boot, wrapping at 2^32.
fn messageTime() std.Io.Timestamp {
    const ms: u32 = @bitCast(win32.GetMessageTime());
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

/// Scroll with the wheel: report wheel buttons if the child asked for
/// mouse events, else send arrow keys on the alternate screen with
/// alternate scroll (mode 1007) set, else move the viewport through
/// scrollback.
fn mouseWheel(self: *Window, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    const horizontal = msg == win32.WM_MOUSEHWHEEL;
    const rotation: i16 = @bitCast(win32.hiword(wparam));

    // Unlike other mouse messages, the position is in screen coordinates.
    var pt: win32.POINT = .{ .x = win32.xLparam(lparam), .y = win32.yLparam(lparam) };
    _ = win32.ScreenToClient(self.hwnd.?, &pt);

    self.lockTerminal();
    const t = &self.terminal;
    const reporting = t.flags.mouse_event != .none;
    const alternate_scroll = !reporting and
        t.screens.active_key == .alternate and
        t.modes.get(.mouse_alternate_scroll);
    const cursor_keys = t.modes.get(.cursor_keys);
    const opts: MouseEncodeOptions = .fromTerminal(t, self.surfaceSize());
    const rows = t.rows;
    self.unlockTerminal();

    if (horizontal and !reporting) return;

    // Reports are one per notch; programs pick how far that scrolls.
    const lines: u32 = if (reporting) 1 else lines: {
        var n: u32 = 3;
        _ = win32.SystemParametersInfoW(win32.SPI_GETWHEELSCROLLLINES, 0, &n, 0);
        break :lines if (n == win32.WHEEL_PAGESCROLL) rows else @min(n, rows);
    };
    const remainder = &self.wheel_remainder[@intFromBool(horizontal)];
    remainder.* += @as(i32, rotation) * @as(i32, @intCast(lines));
    const steps = @divTrunc(remainder.*, win32.WHEEL_DELTA);
    remainder.* -= steps * win32.WHEEL_DELTA;
    if (steps == 0) return;
    // Positive rotation is away from the user, or to the right.
    const up = steps > 0;
    const count = @abs(steps);

    if (reporting) {
        const event: MouseEvent = .{
            .button = if (horizontal)
                (if (up) .seven else .six)
            else
                (if (up) .four else .five),
            .mods = input.mouseMods(wparam),
            .pos = .{ .x = @floatFromInt(pt.x), .y = @floatFromInt(pt.y) },
        };
        for (0..count) |_| self.mouseReport(event, opts);
    } else if (alternate_scroll) {
        const seq: []const u8 = if (cursor_keys)
            (if (up) "\x1bOA" else "\x1bOB")
        else
            (if (up) "\x1b[A" else "\x1b[B");
        if (self.pty) |*pty| for (0..count) |_| pty.write(seq);
    } else {
        const delta: isize = @intCast(count);
        self.lockTerminal();
        self.terminal.scrollViewport(.{ .delta = if (up) -delta else delta });
        self.unlockTerminal();
        self.dirty = true;
    }
}

fn mouseReport(self: *Window, event: MouseEvent, opts: MouseEncodeOptions) void {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ghostty_vt.input.encodeMouse(&w, event, opts) catch |err| {
        log.warn("mouse encode failed: {}", .{err});
        return;
    };
    if (w.buffered().len == 0) return;
    if (self.pty) |*pty| pty.write(w.buffered());
}

/// The system cursor for a shape the child set with OSC 22.
fn mouseCursor(shape: ghostty_vt.MouseShape) usize {
    return switch (shape) {
        .text, .vertical_text => win32.IDC_IBEAM,
        .pointer, .alias, .copy, .grab, .grabbing => win32.IDC_HAND,
        .help, .context_menu => win32.IDC_HELP,
        .progress => win32.IDC_APPSTARTING,
        .wait => win32.IDC_WAIT,
        .cell, .crosshair => win32.IDC_CROSS,
        .move, .all_scroll => win32.IDC_SIZEALL,
        .no_drop, .not_allowed => win32.IDC_NO,
        .col_resize, .e_resize, .w_resize, .ew_resize => win32.IDC_SIZEWE,
        .row_resize, .n_resize, .s_resize, .ns_resize => win32.IDC_SIZENS,
        .ne_resize, .sw_resize, .nesw_resize => win32.IDC_SIZENESW,
        .nw_resize, .se_resize, .nwse_resize => win32.IDC_SIZENWSE,
        .default, .zoom_in, .zoom_out => win32.IDC_ARROW,
    };
}

const ClientSize = struct { width: u32, height: u32 };

fn clientSize(self: *const Window) ClientSize {
    var rect: win32.RECT = undefined;
    _ = win32.GetClientRect(self.hwnd.?, &rect);
    return .{
        .width = @intCast(rect.right - rect.left),
        .height = @intCast(rect.bottom - rect.top),
    };
}

/// The client area as the mouse encoder sees it, to map positions to
/// cells. Call with the terminal locked.
fn surfaceSize(self: *const Window) @FieldType(MouseEncodeOptions, "size") {
    const size = self.clientSize();
    const m = self.grid.metrics;
    const pad = self.paddingPx();
    return .{
        .screen = .{ .width = size.width, .height = size.height },
        .cell = .{ .width = m.cell_width, .height = m.cell_height },
        .padding = .{
            .top = pad,
            .left = pad,
            .right = size.width -| pad -| @as(u32, self.terminal.cols) * m.cell_width,
            .bottom = size.height -| pad -| @as(u32, self.terminal.rows) * m.cell_height,
        },
    };
}

fn paddingPx(self: *const Window) u32 {
    return padding * self.dpi / win32.USER_DEFAULT_SCREEN_DPI;
}

/// The number of whole cells that fit in a client area.
fn gridSize(self: *const Window, width: u32, height: u32) struct { cols: u16, rows: u16 } {
    const m = self.grid.metrics;
    const pad = 2 * self.paddingPx();
    return .{
        .cols = @intCast(std.math.clamp((width -| pad) / m.cell_width, 1, std.math.maxInt(u16))),
        .rows = @intCast(std.math.clamp((height -| pad) / m.cell_height, 1, std.math.maxInt(u16))),
    };
}

fn render(self: *Window) void {
    const r = &(self.renderer orelse return);
    self.renderFallible(r) catch |err| log.err("render failed: {}", .{err});
}

fn renderFallible(self: *Window, r: *Renderer) !void {
    r.waitForFrame();
    self.dirty = false;
    const stats = build_options.stats;
    var t: i64 = if (stats) Stats.now() else 0;
    {
        self.lockTerminal();
        defer self.unlockTerminal();
        try self.render_state.update(self.alloc, &self.terminal);
    }
    if (stats) t = self.stats.lap(.update, t);
    self.cursor_shown = self.render_state.cursor.visible;
    try self.cells.build(self.alloc, &self.render_state, &self.grid, .{
        .focused = self.focused,
        .blink_visible = self.blink_visible,
    });
    if (stats) t = self.stats.lap(.build, t);
    const pad: f32 = @floatFromInt(self.paddingPx());
    try r.draw(&self.cells, &self.grid.atlas, self.grid.metrics, .{ pad, pad });
    if (stats) {
        _ = self.stats.lap(.draw, t);
        self.stats.frames += 1;
    }
}

/// Show the last second's stats after the title.
fn showStats(self: *Window) void {
    var utf8: [160]u8 = undefined;
    const text = self.stats.report(&utf8);

    var title: [256]u16 = undefined;
    const sep = std.unicode.utf8ToUtf16LeStringLiteral("  \u{2014}  ");
    var len: usize = 0;
    for ([_][]const u16{ self.title, sep }) |part| {
        @memcpy(title[len..][0..part.len], part);
        len += part.len;
    }
    len += std.unicode.utf8ToUtf16Le(title[len .. title.len - 1], text) catch 0;
    title[len] = 0;
    _ = win32.SetWindowTextW(self.hwnd.?, title[0..len :0]);
}

/// Fit the swap chain and terminal grid to the client area and redraw.
fn layout(self: *Window) void {
    const r = &(self.renderer orelse return);
    const size = self.clientSize();
    if (size.width == 0 or size.height == 0) return;

    r.resize(size.width, size.height) catch |err| {
        log.err("resize failed: {}", .{err});
        return;
    };

    const grid_size = self.gridSize(size.width, size.height);
    self.lockTerminal();
    const changed = grid_size.cols != self.terminal.cols or grid_size.rows != self.terminal.rows;
    if (changed) {
        self.terminal.resize(self.alloc, .{
            .cols = grid_size.cols,
            .rows = grid_size.rows,
            .cell_size_px = .{
                .width = self.grid.metrics.cell_width,
                .height = self.grid.metrics.cell_height,
            },
        }) catch |err| log.err("terminal resize failed: {}", .{err});
    }
    self.unlockTerminal();

    // After the terminal, so ConPTY's redraw lands on the new grid.
    if (changed) if (self.pty) |*pty| pty.resize(grid_size.cols, grid_size.rows);

    // Render synchronously so live resize doesn't show stale frames.
    self.render();
}

fn registerClass(instance: ?win32.HINSTANCE) !void {
    const Static = struct {
        var registered = false;
    };
    if (Static.registered) return;

    const wc: win32.WNDCLASSEXW = .{
        .lpfnWndProc = wndProc,
        .hInstance = instance,
        .hCursor = win32.LoadCursorW(null, win32.IDC_ARROW),
        .lpszClassName = class_name,
    };
    if (win32.RegisterClassExW(&wc) == 0) return win32.lastError("RegisterClassExW");
    Static.registered = true;
}

fn wndProc(hwnd: win32.HWND, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) callconv(.winapi) win32.LRESULT {
    if (msg == win32.WM_NCCREATE) {
        const cs: *const win32.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const self: *Window = @ptrCast(@alignCast(cs.lpCreateParams.?));
        self.hwnd = hwnd;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    const ptr = win32.GetWindowLongPtrW(hwnd, win32.GWLP_USERDATA);
    if (ptr == 0) return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Window = @ptrFromInt(@as(usize, @bitCast(ptr)));

    switch (msg) {
        win32.WM_SIZE => {
            if (wparam != win32.SIZE_MINIMIZED) self.layout();
            return 0;
        },

        win32.WM_PAINT => {
            self.render();
            _ = win32.ValidateRect(hwnd, null);
            return 0;
        },

        // The swap chain covers the whole client area.
        win32.WM_ERASEBKGND => return 1,

        win32.WM_ENTERSIZEMOVE => {
            _ = win32.SetTimer(hwnd, sizemove_timer_id, 16, null);
            return 0;
        },

        win32.WM_EXITSIZEMOVE => {
            _ = win32.KillTimer(hwnd, sizemove_timer_id);
            // The window may now be on a display with another refresh rate.
            if (self.renderer) |*r| r.updateRefreshRate();
            return 0;
        },

        win32.WM_DISPLAYCHANGE => {
            if (self.renderer) |*r| r.updateRefreshRate();
            return 0;
        },

        win32.WM_TIMER => {
            switch (wparam) {
                stats_timer_id => if (build_options.stats) self.showStats(),
                autoscroll_timer_id => self.autoscrollTick(),
                blink_timer_id => self.blinkTick(),
                sizemove_timer_id => {
                    if (win32.WaitForSingleObject(self.output_event, 0) == win32.WAIT_OBJECT_0) self.dirty = true;
                    if (self.dirty) self.render();
                },
                else => {},
            }
            return 0;
        },

        win32.WM_SETFOCUS, win32.WM_KILLFOCUS => {
            if (self.renderer != null) self.setFocus(msg == win32.WM_SETFOCUS);
            return 0;
        },

        WM_APP_CHILD_EXITED => {
            _ = win32.DestroyWindow(hwnd);
            return 0;
        },

        win32.WM_KEYDOWN, win32.WM_KEYUP, win32.WM_SYSKEYDOWN, win32.WM_SYSKEYUP => {
            if (self.keyBinding(msg, wparam)) return 0;
            switch (wparam) {
                // The text arrives as WM_CHAR.
                win32.VK_PACKET, win32.VK_PROCESSKEY => {},
                // Keep alt+F4.
                win32.VK_F4 => if (msg == win32.WM_SYSKEYDOWN and win32.GetKeyState(win32.VK_MENU) < 0) {
                    return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
                } else self.keyInput(msg, wparam, lparam),
                else => self.keyInput(msg, wparam, lparam),
            }
            // Not passing WM_SYSKEYUP on also keeps a lone alt from
            // entering menu mode.
            return 0;
        },

        win32.WM_CHAR, win32.WM_SYSCHAR => {
            self.charInput(@truncate(wparam));
            return 0;
        },

        win32.WM_DEADCHAR, win32.WM_SYSDEADCHAR => return 0,

        win32.WM_MOUSEMOVE,
        win32.WM_LBUTTONDOWN,
        win32.WM_LBUTTONUP,
        win32.WM_RBUTTONDOWN,
        win32.WM_RBUTTONUP,
        win32.WM_MBUTTONDOWN,
        win32.WM_MBUTTONUP,
        => {
            self.mouseInput(msg, wparam, lparam);
            return 0;
        },

        // These alone return TRUE when handled.
        win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP => {
            self.mouseInput(msg, wparam, lparam);
            return win32.TRUE;
        },

        // Losing the capture mid-drag (alt+tab, a modal window) ends it.
        win32.WM_CAPTURECHANGED => {
            if (self.selecting and lparam != @as(isize, @bitCast(@intFromPtr(hwnd)))) {
                self.lockTerminal();
                defer self.unlockTerminal();
                self.endSelection(null);
            }
            return 0;
        },

        win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL => {
            self.mouseWheel(msg, wparam, lparam);
            return 0;
        },

        win32.WM_SETCURSOR => {
            if (win32.loword(lparam) != win32.HTCLIENT or self.renderer == null)
                return win32.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.lockTerminal();
            const shape = self.terminal.mouse_shape;
            self.unlockTerminal();
            _ = win32.SetCursor(win32.LoadCursorW(null, mouseCursor(shape)));
            return win32.TRUE;
        },

        win32.WM_DPICHANGED => {
            const rect: *const win32.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.dpi = win32.hiword(wparam);
            if (self.renderer != null) self.grid.setDpi(self.dpi);
            _ = win32.SetWindowPos(
                hwnd,
                null,
                rect.left,
                rect.top,
                rect.right - rect.left,
                rect.bottom - rect.top,
                win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
            );

            // The client size may not change (so no WM_SIZE), but the
            // cell size did.
            self.layout();
            return 0;
        },

        win32.WM_DESTROY => {
            _ = win32.SetWindowLongPtrW(hwnd, win32.GWLP_USERDATA, 0);
            self.hwnd = null;
            win32.PostQuitMessage(0);
            return 0;
        },

        else => return win32.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}
