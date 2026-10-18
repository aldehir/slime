//! The tooltip of the button the mouse has rested on (`Ui.tip`): what
//! the button's node says it does, and the key that does the same, under
//! the button, or over it if there's no room below, kept inside the
//! window.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Rect = Ui.Rect;
const Tree = Ui.Tree;

pub fn paint(ui: *const Ui, p: *Painter, tree: *const Tree) void {
    if (ui.tip.target == .none) return;
    const node = Ui.find(tree, ui.tip) orelse return;
    const label, const key = switch (node.kind) {
        .icon_button => |b| .{ b.tip, b.key },
        else => return,
    };
    if (label.len == 0) return;
    const anchor = node.rect;
    const font = ui.fonts.get(.tip);
    const pad = ui.px(9);
    const gap = ui.px(12);
    const label_w = @ceil(ui.fonts.measure(label, font));
    const key_w = if (key.len > 0) @ceil(ui.fonts.measure(key, font)) else 0;
    const w = pad + label_w + (if (key.len > 0) gap + key_w else 0) + pad;
    const h = ui.px(26);
    const margin = ui.px(8);
    const offset = ui.px(6);
    const window = tree.frame.window;
    var r: Rect = .{
        .x = @round(std.math.clamp(anchor.x + (anchor.w - w) / 2, margin, @max(margin, window.w - margin - w))),
        .y = anchor.bottom() + offset,
        .w = w,
        .h = h,
    };
    if (r.bottom() > window.h - margin) r.y = anchor.y - offset - h;

    const radius = ui.px(6);
    ui.paintShadow(p, r, radius);
    ui.fillBordered(p, r, radius, ui.theme.dialog, ui.theme.dialog_outline);
    p.text(label, font, .{ .x = r.x + pad, .y = r.y, .w = label_w, .h = h }, ui.theme.text_strong);
    if (key.len > 0) p.text(key, font, .{ .x = r.right() - pad - key_w, .y = r.y, .w = key_w, .h = h }, ui.theme.text_muted);
}
