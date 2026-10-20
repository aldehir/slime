//! A `text_field`: a `TextField`'s text in a bordered box, scrolled to
//! keep the caret in view, with the selection behind it, and a
//! placeholder while empty. The window feeds the field keys; this only
//! draws it.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Size = Ui.Size;

pub fn measure(ui: *const Ui, node: *const Node) Size {
    const h = node.kind.text_field.h orelse return .{};
    return .{ .h = ui.px(h) };
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const f = node.kind.text_field;
    const r = node.rect;
    ui.fillBordered(p, r, ui.px(6), ui.theme.surface, ui.theme.accent);
    const inner = textRect(ui, node);
    if (f.field.len == 0) p.text(f.placeholder, ui.fonts.get(.body), inner, ui.theme.text_inactive);
    ui.paintEditText(p, inner, f.field, .{ .caret = f.caret });
}

/// Where the field has its text, inside its box.
pub fn textRect(ui: *const Ui, node: *const Node) Ui.Rect {
    return node.rect.inset(ui.px(10), 0);
}

test "a field takes the row's height unless given one" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const field: Ui.TextField = .{};
    const in_row: Node = .{ .kind = .{ .text_field = .{ .field = &field, .caret = false } } };
    try std.testing.expectEqual(Size{}, measure(&ui, &in_row));
    const alone: Node = .{ .kind = .{ .text_field = .{ .field = &field, .caret = false, .h = 32 } } };
    try std.testing.expectEqual(Size{ .w = null, .h = 32 }, measure(&ui, &alone));
}
