//! A wide `button` on the chrome's surface, its label after an icon:
//! "Connect…" at the bottom of the sidebar.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Size = Ui.Size;
const Rect = Ui.Rect;

pub fn measure(ui: *const Ui, node: *const Node) Size {
    return .{ .h = ui.px(node.kind.button.h) };
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const b = node.kind.button;
    const r = node.rect;
    const bg = switch (ui.buttonState(node.id)) {
        .rest => ui.theme.surface,
        .hover, .pressed => ui.theme.surface_hover,
    };
    p.fillRounded(r, ui.px(6), bg);
    var label_x = r.x + ui.px(8);
    if (b.icon) |icon| {
        // Lucide's plug spans 16 of its 24 units: 11 DIPs in this box,
        // about the plus's size. Its prongs land on pixel edges at this
        // size, so a half pixel moves them onto centers.
        const size = ui.px(16);
        var box = (Rect{ .x = r.x + ui.px(7), .y = r.y, .w = ui.px(20), .h = r.h }).center(size, size);
        box.x += 0.5;
        ui.drawIcon(p, icon, box, ui.theme.text);
        label_x = r.x + ui.px(32);
    }
    p.text(b.label, ui.fonts.get(.body), .{ .x = label_x, .y = r.y, .w = @max(0, r.right() - ui.px(8) - label_x), .h = r.h }, ui.theme.text);
}

test "a button is as tall as it says" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const node: Node = .{ .kind = .{ .button = .{ .label = &.{}, .h = 32 } } };
    try std.testing.expectEqual(Size{ .w = null, .h = 32 }, measure(&ui, &node));
}
