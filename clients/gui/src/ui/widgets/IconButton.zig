//! An `icon`, a Lucide icon (or the app's) in a square, and an
//! `icon_button`, one that's a button: in a list row, in a bar, or over
//! a pane, each lit differently under the mouse (`Style`). Buttons that
//! are only an icon name themselves in a tooltip (`Tooltip`).

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Size = Ui.Size;
const Rect = Ui.Rect;
const Color = Ui.Color;

/// A faint button's opacity at rest, and while pressed.
const faint = 0.35;
const pressed = 0.7;

pub fn measure(ui: *const Ui, node: *const Node) Size {
    return switch (node.kind) {
        .icon => |i| .{ .w = ui.px(i.box orelse i.size), .h = ui.px(i.box orelse i.size) },
        .icon_button => |b| .{ .w = ui.px(b.w), .h = if (b.h) |h| ui.px(h) else null },
        else => .{},
    };
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    switch (node.kind) {
        .icon => |i| {
            var box = node.rect.center(ui.px(i.size), ui.px(i.size));
            box.x += i.dx;
            if (i.icon) |name| ui.drawIcon(p, name, box, i.color) else p.appIcon(box);
        },
        .icon_button => |b| {
            const t = &ui.theme;
            const state = ui.buttonState(node.id);
            const r = node.rect;
            var color: Color = undefined;
            switch (b.style) {
                .row => {
                    if (state != .rest) p.fillRounded(r, ui.px(4), if (state == .pressed) t.button_pressed else t.button_hover);
                    color = if (state != .rest) b.hover_color orelse t.text_strong else b.color orelse t.text_muted;
                },
                .bar => {
                    switch (state) {
                        .rest => {},
                        .hover => p.fill(r, t.button_hover),
                        .pressed => p.fill(r, t.button_pressed),
                    }
                    color = if (state != .rest) b.hover_color orelse b.color orelse t.text else b.color orelse t.text;
                },
                .faint => {
                    const c = b.color orelse t.text_strong;
                    const alpha: f32 = switch (state) {
                        .rest => faint,
                        .hover => 1,
                        .pressed => pressed,
                    };
                    color = .{ c[0], c[1], c[2], alpha };
                },
            }
            var box = r.center(ui.px(b.size), ui.px(b.size));
            box.x += b.dx;
            ui.drawIcon(p, b.icon, box, color);
        },
        else => {},
    }
}

test "sizes" {
    const ui: Ui = .{ .scale = 2, .fonts = .none, .theme = undefined };
    const icon: Node = .{ .kind = .{ .icon = .{ .icon = .plus, .size = 16 } } };
    try std.testing.expectEqual(Size{ .w = 32, .h = 32 }, measure(&ui, &icon));
    const bar: Node = .{ .kind = .{ .icon_button = .{ .icon = .panel_left, .size = 20, .w = 40, .h = null, .style = .bar } } };
    try std.testing.expectEqual(Size{ .w = 80, .h = null }, measure(&ui, &bar));
}
