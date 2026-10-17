//! Key bindings: which key presses run an app action instead of going to
//! the child. Actions take Ghostty's names, so a `keybind` config can map
//! onto them later. Triggers are virtual keys, which follow the keyboard
//! layout (VK_OEM_PLUS is whichever key types '+').

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");

const Mods = ghostty_vt.input.KeyMods;

pub const Action = union(enum) {
    copy_to_clipboard,
    paste_from_clipboard,
    new_tab,
    close_surface,
    next_tab,
    previous_tab,
    /// In points.
    increase_font_size: f32,
    decrease_font_size: f32,
    reset_font_size,
    new_split: SplitDirection,
    goto_split: GotoSplit,
    /// By `amount` cells.
    resize_split: ResizeSplit,
    equalize_splits,
    toggle_split_zoom,
};

pub const SplitDirection = enum { right, down, left, up };

pub const GotoSplit = enum { previous, next, up, left, down, right };

pub const ResizeSplit = struct {
    direction: SplitDirection,
    amount: u16,
};

pub const Trigger = struct {
    vk: u32,
    mods: Mods.Keys = .{},
};

pub const Binding = struct {
    trigger: Trigger,
    action: Action,
    /// The key goes to the child when the action can't run (copy with no
    /// selection), Ghostty's `performable:` prefix.
    performable: bool = false,
};

const ctrl: Mods.Keys = .{ .ctrl = true };
const shift: Mods.Keys = .{ .shift = true };
const ctrl_shift: Mods.Keys = .{ .ctrl = true, .shift = true };
const ctrl_alt: Mods.Keys = .{ .ctrl = true, .alt = true };
const ctrl_alt_shift: Mods.Keys = .{ .ctrl = true, .alt = true, .shift = true };

/// Ghostty's defaults where it has them.
pub const defaults = [_]Binding{
    .{ .trigger = .{ .vk = 'C', .mods = ctrl_shift }, .action = .copy_to_clipboard, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_INSERT, .mods = ctrl }, .action = .copy_to_clipboard },
    .{ .trigger = .{ .vk = 'V', .mods = ctrl_shift }, .action = .paste_from_clipboard, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_INSERT, .mods = shift }, .action = .paste_from_clipboard },
    .{ .trigger = .{ .vk = 'T', .mods = ctrl_shift }, .action = .new_tab },
    .{ .trigger = .{ .vk = 'W', .mods = ctrl_shift }, .action = .close_surface },
    .{ .trigger = .{ .vk = win32.VK_TAB, .mods = ctrl }, .action = .next_tab },
    .{ .trigger = .{ .vk = win32.VK_TAB, .mods = ctrl_shift }, .action = .previous_tab },
    .{ .trigger = .{ .vk = win32.VK_NEXT, .mods = ctrl }, .action = .next_tab },
    .{ .trigger = .{ .vk = win32.VK_PRIOR, .mods = ctrl }, .action = .previous_tab },
    .{ .trigger = .{ .vk = win32.VK_OEM_PLUS, .mods = ctrl_shift }, .action = .{ .increase_font_size = 1 } },
    .{ .trigger = .{ .vk = win32.VK_OEM_MINUS, .mods = ctrl_shift }, .action = .{ .decrease_font_size = 1 } },
    .{ .trigger = .{ .vk = '0', .mods = ctrl_shift }, .action = .reset_font_size },
    // Windows' default input language hotkeys take ctrl+shift+0 (direct
    // switch to the Japanese IME), so it never arrives on most machines.
    .{ .trigger = .{ .vk = '0', .mods = ctrl }, .action = .reset_font_size },
    // Only slime's tabs split; elsewhere the keys go to the child.
    .{ .trigger = .{ .vk = 'O', .mods = ctrl_shift }, .action = .{ .new_split = .right }, .performable = true },
    .{ .trigger = .{ .vk = 'E', .mods = ctrl_shift }, .action = .{ .new_split = .down }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_RETURN, .mods = ctrl_shift }, .action = .toggle_split_zoom, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_UP, .mods = ctrl_alt }, .action = .{ .goto_split = .up }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_DOWN, .mods = ctrl_alt }, .action = .{ .goto_split = .down }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_LEFT, .mods = ctrl_alt }, .action = .{ .goto_split = .left }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_RIGHT, .mods = ctrl_alt }, .action = .{ .goto_split = .right }, .performable = true },
    // Ghostty's ctrl+super chords are the shell's on Windows (ctrl+win+
    // arrows switch desktops), so these take ctrl+shift and ctrl+alt+shift.
    .{ .trigger = .{ .vk = win32.VK_OEM_4, .mods = ctrl_shift }, .action = .{ .goto_split = .previous }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_OEM_6, .mods = ctrl_shift }, .action = .{ .goto_split = .next }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_UP, .mods = ctrl_alt_shift }, .action = .{ .resize_split = .{ .direction = .up, .amount = 1 } }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_DOWN, .mods = ctrl_alt_shift }, .action = .{ .resize_split = .{ .direction = .down, .amount = 1 } }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_LEFT, .mods = ctrl_alt_shift }, .action = .{ .resize_split = .{ .direction = .left, .amount = 1 } }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_RIGHT, .mods = ctrl_alt_shift }, .action = .{ .resize_split = .{ .direction = .right, .amount = 1 } }, .performable = true },
    .{ .trigger = .{ .vk = win32.VK_OEM_PLUS, .mods = ctrl_alt_shift }, .action = .equalize_splits, .performable = true },
};

/// The binding for a key pressed with `mods`. Lock keys and sides don't
/// matter.
pub fn find(bindings: []const Binding, vk: u32, mods: Mods) ?Binding {
    for (bindings) |b| {
        if (b.trigger.vk == vk and b.trigger.mods.int() == mods.keys().int()) return b;
    }
    return null;
}

/// A key's name for a hint, e.g. "Ctrl+Shift+T".
pub const Label = struct {
    buf: [24]u16 = undefined,
    len: usize = 0,

    pub fn slice(self: *const Label) []const u16 {
        return self.buf[0..self.len];
    }

    fn append(self: *Label, text: []const u8) void {
        for (text) |c| {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }
};

/// The first of `bindings` that runs `action`, named. Empty if none does
/// or its key has no name here.
pub fn label(bindings: []const Binding, action: Action) Label {
    var out: Label = .{};
    const b = for (bindings) |b| {
        if (std.meta.eql(b.action, action)) break b;
    } else return out;
    var key_buf: [1]u8 = undefined;
    const key: []const u8 = switch (b.trigger.vk) {
        'A'...'Z', '0'...'9' => |vk| key: {
            key_buf[0] = @intCast(vk);
            break :key &key_buf;
        },
        win32.VK_TAB => "Tab",
        win32.VK_RETURN => "Enter",
        win32.VK_LEFT => "Left",
        win32.VK_UP => "Up",
        win32.VK_RIGHT => "Right",
        win32.VK_DOWN => "Down",
        win32.VK_INSERT => "Insert",
        win32.VK_PRIOR => "PgUp",
        win32.VK_NEXT => "PgDn",
        win32.VK_OEM_PLUS => "+",
        win32.VK_OEM_MINUS => "-",
        win32.VK_OEM_4 => "[",
        win32.VK_OEM_6 => "]",
        else => return out,
    };
    const mods = b.trigger.mods;
    if (mods.ctrl) out.append("Ctrl+");
    if (mods.shift) out.append("Shift+");
    if (mods.alt) out.append("Alt+");
    if (mods.super) out.append("Win+");
    out.append(key);
    return out;
}

test label {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+T"), label(&defaults, .new_tab).slice());
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+C"), label(&defaults, .copy_to_clipboard).slice());
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+E"), label(&defaults, .{ .new_split = .down }).slice());
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+Enter"), label(&defaults, .toggle_split_zoom).slice());
    try std.testing.expectEqual(@as(usize, 0), label(&.{}, .new_tab).len);
}

test find {
    const plus = find(&defaults, win32.VK_OEM_PLUS, .{ .ctrl = true, .shift = true, .num_lock = true }).?;
    try std.testing.expectEqual(Action{ .increase_font_size = 1 }, plus.action);
    try std.testing.expectEqual(Action.previous_tab, find(&defaults, win32.VK_TAB, .{ .ctrl = true, .shift = true }).?.action);
    try std.testing.expectEqual(null, find(&defaults, win32.VK_OEM_PLUS, .{ .ctrl = true }));
    try std.testing.expectEqual(Action.reset_font_size, find(&defaults, '0', .{ .ctrl = true }).?.action);
    try std.testing.expectEqual(null, find(&defaults, '0', .{ .ctrl = true, .shift = true, .alt = true }));
}
