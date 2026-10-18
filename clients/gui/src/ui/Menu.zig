//! A context menu: what it's about, where it opens, and its items, which
//! the app fills in when a row or pane is right-clicked (`App.openMenu`).
//! The app owns one while it's open (`App.Mode.menu`) and moves its
//! focus with the keyboard; `widgets/Popup.zig` lays it out and draws
//! it. An entry does one of two things when chosen: clicks one of its
//! target's controls, as the row's button of that part would, or runs a
//! key binding's action on the target, whose key it then names.
const Menu = @This();

const std = @import("std");
const Painter = @import("../renderer/Painter.zig");
const Id = @import("Id.zig");
const binding = @import("../binding.zig");

pub const max_items = 16;

/// What the menu is about: the row or pane it was opened on.
target: Id.Target,
/// Where it opens.
anchor: Anchor,
items: [max_items]Item = undefined,
count: usize = 0,
/// The entry the keyboard is on: Up and Down move it, and the mouse
/// over an entry puts it there. Null until either does.
focus: ?usize = null,

pub const Anchor = union(enum) {
    /// The mouse, in client pixels: the box's top-left corner, flipped
    /// to stay in the window.
    point: struct { x: f32, y: f32 },
    /// Under a widget (the Menu key on a pane), aligned with its left.
    below: Painter.Rect,
};

pub const Item = union(enum) {
    separator,
    entry: Entry,
};

pub const Entry = struct {
    label: []const u16,
    icon: ?Painter.Lucide = null,
    action: Action,
    /// Drawn in the danger color: Kill, Close.
    danger: bool = false,
    /// Shown, but can't be chosen: Copy with no selection.
    disabled: bool = false,

    /// The key that does the same, named, for a binding's action; empty
    /// for a control.
    pub fn key(self: Entry) binding.Label {
        return switch (self.action) {
            .binding => |a| binding.label(&binding.defaults, a),
            .part => .{},
        };
    }
};

/// What choosing an entry does.
pub const Action = union(enum) {
    /// Click the target's control of this part (`App.widgetClick`).
    part: Id.Part,
    /// Run a key binding's action on the target (`App.runAction`).
    binding: binding.Action,
};

pub fn add(self: *Menu, e: Entry) void {
    self.addItem(.{ .entry = e });
}

pub fn separator(self: *Menu) void {
    self.addItem(.separator);
}

fn addItem(self: *Menu, item: Item) void {
    if (self.count == max_items) return;
    self.items[self.count] = item;
    self.count += 1;
}

pub fn constItems(self: *const Menu) []const Item {
    return self.items[0..self.count];
}

/// Item `i`, if it's an entry.
pub fn entry(self: *const Menu, i: usize) ?Entry {
    if (i >= self.count) return null;
    return switch (self.items[i]) {
        .entry => |e| e,
        .separator => null,
    };
}

/// Whether item `i` can be chosen: an entry that isn't disabled.
pub fn canChoose(self: *const Menu, i: usize) bool {
    const e = self.entry(i) orelse return false;
    return !e.disabled;
}

/// Move the focus to the next entry that can be chosen, or the one
/// before, around the ends; from none, to the first or the last.
pub fn moveFocus(self: *Menu, forward: bool) void {
    if (self.count == 0) return;
    var i = self.focus orelse (if (forward) self.count - 1 else 0);
    for (0..self.count) |_| {
        i = if (forward) (i + 1) % self.count else (i + self.count - 1) % self.count;
        if (self.canChoose(i)) {
            self.focus = i;
            return;
        }
    }
}

/// Focus the first entry that can be chosen, or the last.
pub fn focusEnd(self: *Menu, first: bool) void {
    self.focus = null;
    self.moveFocus(first);
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "the focus skips separators and disabled entries, around the ends" {
    var m: Menu = .{ .target = .{ .workspace = 1 }, .anchor = .{ .point = .{ .x = 0, .y = 0 } } };
    m.add(.{ .label = L("New tab"), .action = .{ .part = .new_tab } });
    m.separator();
    m.add(.{ .label = L("Copy"), .action = .{ .binding = .copy_to_clipboard }, .disabled = true });
    m.add(.{ .label = L("Kill"), .action = .{ .part = .kill }, .danger = true });
    try std.testing.expectEqual(@as(usize, 4), m.constItems().len);
    try std.testing.expect(m.entry(1) == null);
    try std.testing.expect(!m.canChoose(2));

    m.moveFocus(true);
    try std.testing.expectEqual(@as(?usize, 0), m.focus);
    m.moveFocus(true);
    try std.testing.expectEqual(@as(?usize, 3), m.focus);
    m.moveFocus(true);
    try std.testing.expectEqual(@as(?usize, 0), m.focus);
    m.moveFocus(false);
    try std.testing.expectEqual(@as(?usize, 3), m.focus);
    m.focusEnd(true);
    try std.testing.expectEqual(@as(?usize, 0), m.focus);
    m.focusEnd(false);
    try std.testing.expectEqual(@as(?usize, 3), m.focus);

    // A binding's entry names its key; a control's doesn't.
    const copy_key = m.entry(2).?.key();
    try std.testing.expectEqualSlices(u16, L("Ctrl+Shift+C"), copy_key.slice());
    try std.testing.expectEqual(@as(usize, 0), m.entry(0).?.key().len);

    // Nothing to focus: it stays off.
    var empty: Menu = .{ .target = .none, .anchor = .{ .point = .{ .x = 0, .y = 0 } } };
    empty.separator();
    empty.moveFocus(true);
    try std.testing.expectEqual(@as(?usize, null), empty.focus);
}
