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
};

/// The binding for a key pressed with `mods`. Lock keys and sides don't
/// matter.
pub fn find(bindings: []const Binding, vk: u32, mods: Mods) ?Binding {
    for (bindings) |b| {
        if (b.trigger.vk == vk and b.trigger.mods.int() == mods.keys().int()) return b;
    }
    return null;
}

test find {
    const plus = find(&defaults, win32.VK_OEM_PLUS, .{ .ctrl = true, .shift = true, .num_lock = true }).?;
    try std.testing.expectEqual(Action{ .increase_font_size = 1 }, plus.action);
    try std.testing.expectEqual(Action.previous_tab, find(&defaults, win32.VK_TAB, .{ .ctrl = true, .shift = true }).?.action);
    try std.testing.expectEqual(null, find(&defaults, win32.VK_OEM_PLUS, .{ .ctrl = true }));
    try std.testing.expectEqual(Action.reset_font_size, find(&defaults, '0', .{ .ctrl = true }).?.action);
    try std.testing.expectEqual(null, find(&defaults, '0', .{ .ctrl = true, .shift = true, .alt = true }));
}
