//! The title bar's `caption_button`s: minimize, maximize (or restore),
//! and close, drawn as Windows draws them, the close one red under the
//! mouse.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Size = Ui.Size;
const Rect = Ui.Rect;
const Color = Ui.Color;

/// A button's width, in DIPs.
pub const width = 46;

pub fn measure(ui: *const Ui, _: *const Node) Size {
    return .{ .w = ui.px(width) };
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const b = node.kind.caption_button;
    const t = &ui.theme;
    const r = node.rect;
    const glyph = if (b.focused) t.text else t.text_inactive;
    const w = ui.stroke();
    const g = ui.px(10);
    const close = b.part == .close;

    const state = ui.buttonState(node.id);
    const bg: ?Color = switch (state) {
        .rest => null,
        .hover => if (close) t.close_hover else t.button_hover,
        .pressed => if (close) t.close_pressed else t.button_pressed,
    };
    if (bg) |c| p.fill(r, c);
    const color = if (close and state != .rest) t.close_glyph else glyph;
    const box = r.center(g, g);
    switch (b.part) {
        .minimize => {
            const y = Ui.crisp(box.y + g / 2, w);
            p.line(box.x, y, box.right(), y, w, color);
        },
        .maximize => if (b.maximized) {
            // Restore: a window behind another.
            const d = ui.px(2);
            const front: Rect = .{ .x = box.x, .y = box.y + d, .w = g - d, .h = g - d };
            p.strokeRounded(.{ .x = box.x + d, .y = box.y, .w = g - d, .h = g - d }, ui.px(1.5), w, color);
            p.fill(front, bg orelse t.ground);
            p.strokeRounded(front, ui.px(1.5), w, color);
        } else {
            p.strokeRounded(box, ui.px(1.5), w, color);
        },
        .close => {
            p.line(box.x, box.y, box.right(), box.bottom(), w, color);
            p.line(box.right(), box.y, box.x, box.bottom(), w, color);
        },
        else => {},
    }
}

test "a caption button is 46 DIPs wide and as tall as the bar" {
    const ui: Ui = .{ .scale = 1.5, .fonts = .none, .theme = undefined };
    const node: Node = .{ .kind = .{ .caption_button = .{ .part = .close, .maximized = false, .focused = true } } };
    try std.testing.expectEqual(Size{ .w = 69, .h = null }, measure(&ui, &node));
}
