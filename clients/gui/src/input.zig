//! Win32 keyboard and mouse messages to libghostty-vt key and mouse
//! events, which its encoders turn into the bytes a program expects
//! (legacy, xterm modifyOtherKeys, or Kitty protocol for keys; X10, SGR,
//! ... for the mouse, depending on terminal modes).

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");

const Key = ghostty_vt.input.Key;
const KeyEvent = ghostty_vt.input.KeyEvent;
pub const Mods = ghostty_vt.input.KeyMods;
const MouseButton = ghostty_vt.input.MouseButton;
const Win32Key = @import("event").Win32Key;

/// Build the event for a WM_(SYS)KEYDOWN or WM_(SYS)KEYUP. `text` is the
/// UTF-8 the key produced (from the WM_(SYS)CHAR messages TranslateMessage
/// posted for it) and `composing` is set if it produced a dead key.
pub fn keyEvent(
    msg: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
    text: []const u8,
    composing: bool,
) KeyEvent {
    const flags: usize = @bitCast(lparam);
    const vk: u32 = @truncate(wparam);
    const release = msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP;
    const mods = currentMods();

    var event: KeyEvent = .{
        .action = if (release) .release else if (flags & (1 << 30) != 0) .repeat else .press,
        .key = keyFromScancode(@truncate(flags >> 16), flags & (1 << 24) != 0, vk),
        .mods = mods,
        .composing = composing,
        .unshifted_codepoint = unshiftedCodepoint(vk),
    };

    // Windows applies ctrl to the text (ctrl+c gives 0x03). The encoder
    // derives control codes from the key itself, so drop those.
    if (text.len > 0 and !(text.len == 1 and std.ascii.isControl(text[0]))) {
        event.utf8 = text;
        // AltGr arrives as ctrl+alt; when it produced text, it's consumed.
        const altgr = mods.ctrl and mods.alt;
        event.consumed_mods = .{ .shift = mods.shift, .ctrl = altgr, .alt = altgr };
    }
    return event;
}

/// Whether a key message is for shift, ctrl, alt, or a Windows key.
pub fn isModifier(wparam: win32.WPARAM, lparam: win32.LPARAM) bool {
    const flags: usize = @bitCast(lparam);
    return keyFromScancode(@truncate(flags >> 16), flags & (1 << 24) != 0, @truncate(wparam)).modifier();
}

/// The button a WM_*BUTTONDOWN/UP/DBLCLK message is about, and whether
/// it was pressed. Null for other messages. A double click is the
/// second press: slime counts the clicks on the terminal itself, from
/// their times.
pub fn mouseButton(msg: u32, wparam: win32.WPARAM) ?struct { MouseButton, bool } {
    return switch (msg) {
        win32.WM_LBUTTONDOWN, win32.WM_LBUTTONDBLCLK => .{ .left, true },
        win32.WM_LBUTTONUP => .{ .left, false },
        win32.WM_RBUTTONDOWN, win32.WM_RBUTTONDBLCLK => .{ .right, true },
        win32.WM_RBUTTONUP => .{ .right, false },
        win32.WM_MBUTTONDOWN, win32.WM_MBUTTONDBLCLK => .{ .middle, true },
        win32.WM_MBUTTONUP => .{ .middle, false },
        // Back and forward, which xterm numbers 8 and 9.
        win32.WM_XBUTTONDOWN, win32.WM_XBUTTONUP, win32.WM_XBUTTONDBLCLK => .{
            if (win32.hiword(wparam) == win32.XBUTTON1) .eight else .nine,
            msg != win32.WM_XBUTTONUP,
        },
        else => null,
    };
}

/// The button a drag reports, from a mouse message's MK_* flags (which
/// already reflect the message's own press or release). Null when no
/// button is held.
pub fn heldButton(wparam: win32.WPARAM) ?MouseButton {
    // In Ghostty's order of preference.
    if (wparam & win32.MK_LBUTTON != 0) return .left;
    if (wparam & win32.MK_RBUTTON != 0) return .right;
    if (wparam & win32.MK_MBUTTON != 0) return .middle;
    if (wparam & win32.MK_XBUTTON1 != 0) return .eight;
    if (wparam & win32.MK_XBUTTON2 != 0) return .nine;
    return null;
}

/// Modifiers for a mouse event. Mouse protocols only carry shift, ctrl,
/// and alt.
pub fn mouseMods(wparam: win32.WPARAM) Mods {
    return .{
        .shift = wparam & win32.MK_SHIFT != 0,
        .ctrl = wparam & win32.MK_CONTROL != 0,
        .alt = down(win32.VK_MENU),
    };
}

/// A WM_(SYS)KEYDOWN or WM_(SYS)KEYUP as win32-input-mode (mode 9001)
/// has it, which ConPTY asks for so it can hand console programs the
/// exact KEY_EVENT_RECORD instead of guessing one from VT input. `char`
/// is one unit of the text it produced.
pub fn win32Key(msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM, char: u16) Win32Key {
    const flags: usize = @bitCast(lparam);
    return .{
        .vk = @truncate(wparam),
        .scancode = @truncate((flags >> 16) & 0xFF),
        .char = char,
        .down = msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN,
        .control_state = controlKeyState(flags & (1 << 24) != 0),
        .repeat = @max(win32.loword(lparam), 1),
    };
}

/// The character a key makes in the current layout and modifier state.
/// Releases get no WM_CHAR, but the console and Windows Terminal report
/// them with the character, and apps match presses to releases by it
/// (herdr drops a space release without one). 0 for none or a dead key.
pub fn releaseChar(wparam: win32.WPARAM, lparam: win32.LPARAM) u16 {
    var state: [256]u8 = undefined;
    if (win32.GetKeyboardState(&state) == 0) return 0;
    const flags: usize = @bitCast(lparam);
    var buf: [4]u16 = undefined;
    const n = win32.ToUnicodeEx(
        @truncate(wparam),
        @truncate((flags >> 16) & 0xFF),
        &state,
        &buf,
        buf.len,
        win32.TOUNICODE_NO_STATE_CHANGE,
        win32.GetKeyboardLayout(0),
    );
    return if (n == 1) buf[0] else 0;
}

/// The current modifiers and lock keys as KEY_EVENT_RECORD's
/// dwControlKeyState.
pub fn controlKeyState(enhanced: bool) u32 {
    var state: u32 = 0;
    if (down(win32.VK_RMENU)) state |= win32.RIGHT_ALT_PRESSED;
    if (down(win32.VK_LMENU)) state |= win32.LEFT_ALT_PRESSED;
    if (down(win32.VK_RCONTROL)) state |= win32.RIGHT_CTRL_PRESSED;
    if (down(win32.VK_LCONTROL)) state |= win32.LEFT_CTRL_PRESSED;
    if (down(win32.VK_SHIFT)) state |= win32.SHIFT_PRESSED;
    if (toggled(win32.VK_NUMLOCK)) state |= win32.NUMLOCK_ON;
    if (toggled(win32.VK_SCROLL)) state |= win32.SCROLLLOCK_ON;
    if (toggled(win32.VK_CAPITAL)) state |= win32.CAPSLOCK_ON;
    if (enhanced) state |= win32.ENHANCED_KEY;
    return state;
}

/// The modifiers held now, as of the message being handled.
pub fn currentMods() Mods {
    return .{
        .shift = down(win32.VK_SHIFT),
        .ctrl = down(win32.VK_CONTROL),
        .alt = down(win32.VK_MENU),
        .super = down(win32.VK_LWIN) or down(win32.VK_RWIN),
        .caps_lock = toggled(win32.VK_CAPITAL),
        .num_lock = toggled(win32.VK_NUMLOCK),
        .sides = .{
            .shift = if (down(win32.VK_RSHIFT)) .right else .left,
            .ctrl = if (down(win32.VK_RCONTROL)) .right else .left,
            .alt = if (down(win32.VK_RMENU)) .right else .left,
            .super = if (down(win32.VK_RWIN)) .right else .left,
        },
    };
}

fn down(vk: i32) bool {
    return win32.GetKeyState(vk) < 0;
}

fn toggled(vk: i32) bool {
    return win32.GetKeyState(vk) & 1 != 0;
}

/// The character the key produces with no modifiers, in the current
/// layout. Used for Kitty protocol key codes and ctrl sequences.
fn unshiftedCodepoint(vk: u32) u21 {
    // The high bit marks dead keys.
    const c = win32.MapVirtualKeyW(vk, win32.MAPVK_VK_TO_CHAR) & 0x7FFF_FFFF;
    if (c < 0x80) return std.ascii.toLower(@intCast(c));
    return std.math.cast(u21, c) orelse 0;
}

/// Map a set 1 scancode (lParam bits 16-24) to the physical key. The
/// table follows the Windows column of Chromium's DOM code table.
fn keyFromScancode(scancode: u8, extended: bool, vk: u32) Key {
    if (extended) return switch (scancode) {
        0x1C => .numpad_enter,
        0x1D => .control_right,
        0x35 => .numpad_divide,
        0x37 => .print_screen,
        0x38 => .alt_right,
        0x45 => .num_lock,
        0x47 => .home,
        0x48 => .arrow_up,
        0x49 => .page_up,
        0x4B => .arrow_left,
        0x4D => .arrow_right,
        0x4F => .end,
        0x50 => .arrow_down,
        0x51 => .page_down,
        0x52 => .insert,
        0x53 => .delete,
        0x5B => .meta_left,
        0x5C => .meta_right,
        0x5D => .context_menu,
        else => .unidentified,
    };

    // With num lock off, the numpad digits send navigation keys from the
    // same scancodes.
    const numpad_digit = (vk >= win32.VK_NUMPAD0 and vk <= win32.VK_NUMPAD9) or vk == win32.VK_DECIMAL;

    return switch (scancode) {
        0x01 => .escape,
        0x02 => .digit_1,
        0x03 => .digit_2,
        0x04 => .digit_3,
        0x05 => .digit_4,
        0x06 => .digit_5,
        0x07 => .digit_6,
        0x08 => .digit_7,
        0x09 => .digit_8,
        0x0A => .digit_9,
        0x0B => .digit_0,
        0x0C => .minus,
        0x0D => .equal,
        0x0E => .backspace,
        0x0F => .tab,
        0x10 => .key_q,
        0x11 => .key_w,
        0x12 => .key_e,
        0x13 => .key_r,
        0x14 => .key_t,
        0x15 => .key_y,
        0x16 => .key_u,
        0x17 => .key_i,
        0x18 => .key_o,
        0x19 => .key_p,
        0x1A => .bracket_left,
        0x1B => .bracket_right,
        0x1C => .enter,
        0x1D => .control_left,
        0x1E => .key_a,
        0x1F => .key_s,
        0x20 => .key_d,
        0x21 => .key_f,
        0x22 => .key_g,
        0x23 => .key_h,
        0x24 => .key_j,
        0x25 => .key_k,
        0x26 => .key_l,
        0x27 => .semicolon,
        0x28 => .quote,
        0x29 => .backquote,
        0x2A => .shift_left,
        0x2B => .backslash,
        0x2C => .key_z,
        0x2D => .key_x,
        0x2E => .key_c,
        0x2F => .key_v,
        0x30 => .key_b,
        0x31 => .key_n,
        0x32 => .key_m,
        0x33 => .comma,
        0x34 => .period,
        0x35 => .slash,
        0x36 => .shift_right,
        0x37 => .numpad_multiply,
        0x38 => .alt_left,
        0x39 => .space,
        0x3A => .caps_lock,
        0x3B => .f1,
        0x3C => .f2,
        0x3D => .f3,
        0x3E => .f4,
        0x3F => .f5,
        0x40 => .f6,
        0x41 => .f7,
        0x42 => .f8,
        0x43 => .f9,
        0x44 => .f10,
        0x45 => .pause,
        0x46 => .scroll_lock,
        0x47 => if (numpad_digit) .numpad_7 else .numpad_home,
        0x48 => if (numpad_digit) .numpad_8 else .numpad_up,
        0x49 => if (numpad_digit) .numpad_9 else .numpad_page_up,
        0x4A => .numpad_subtract,
        0x4B => if (numpad_digit) .numpad_4 else .numpad_left,
        0x4C => if (numpad_digit) .numpad_5 else .numpad_begin,
        0x4D => if (numpad_digit) .numpad_6 else .numpad_right,
        0x4E => .numpad_add,
        0x4F => if (numpad_digit) .numpad_1 else .numpad_end,
        0x50 => if (numpad_digit) .numpad_2 else .numpad_down,
        0x51 => if (numpad_digit) .numpad_3 else .numpad_page_down,
        0x52 => if (numpad_digit) .numpad_0 else .numpad_insert,
        0x53 => if (numpad_digit) .numpad_decimal else .numpad_delete,
        0x56 => .intl_backslash,
        0x57 => .f11,
        0x58 => .f12,
        0x59 => .numpad_equal,
        0x64 => .f13,
        0x65 => .f14,
        0x66 => .f15,
        0x67 => .f16,
        0x68 => .f17,
        0x69 => .f18,
        0x6A => .f19,
        0x6B => .f20,
        0x6C => .f21,
        0x6D => .f22,
        0x6E => .f23,
        0x70 => .kana_mode,
        0x73 => .intl_ro,
        0x76 => .f24,
        0x79 => .convert,
        0x7B => .non_convert,
        0x7D => .intl_yen,
        0x7E => .numpad_comma,
        else => .unidentified,
    };
}

test keyFromScancode {
    try std.testing.expectEqual(Key.key_c, keyFromScancode(0x2E, false, 'C'));
    try std.testing.expectEqual(Key.arrow_up, keyFromScancode(0x48, true, 0x26));
    try std.testing.expectEqual(Key.numpad_8, keyFromScancode(0x48, false, win32.VK_NUMPAD0 + 8));
    try std.testing.expectEqual(Key.numpad_up, keyFromScancode(0x48, false, 0x26));
}

test Win32Key {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    // ctrl+[ on a US layout: VK_OEM_4, scancode 0x1A, ESC, left ctrl.
    try (Win32Key{
        .vk = 0xDB,
        .scancode = 0x1A,
        .char = 0x1B,
        .down = true,
        .control_state = win32.LEFT_CTRL_PRESSED,
    }).encode(&w);
    try std.testing.expectEqualStrings("\x1b[219;26;27;1;8;1_", w.buffered());
}

test mouseButton {
    const expectEqual = std.testing.expectEqual;
    // A double click is the second press of its button.
    try expectEqual(.{ MouseButton.left, true }, mouseButton(win32.WM_LBUTTONDOWN, 0).?);
    try expectEqual(.{ MouseButton.left, true }, mouseButton(win32.WM_LBUTTONDBLCLK, 0).?);
    try expectEqual(.{ MouseButton.left, false }, mouseButton(win32.WM_LBUTTONUP, 0).?);
    try expectEqual(.{ MouseButton.right, true }, mouseButton(win32.WM_RBUTTONDBLCLK, 0).?);
    try expectEqual(.{ MouseButton.middle, true }, mouseButton(win32.WM_MBUTTONDBLCLK, 0).?);
    const x2: win32.WPARAM = @as(win32.WPARAM, win32.XBUTTON2) << 16;
    try expectEqual(.{ MouseButton.nine, true }, mouseButton(win32.WM_XBUTTONDBLCLK, x2).?);
    try expectEqual(.{ MouseButton.nine, false }, mouseButton(win32.WM_XBUTTONUP, x2).?);
    try expectEqual(null, mouseButton(win32.WM_MOUSEMOVE, 0));
}
