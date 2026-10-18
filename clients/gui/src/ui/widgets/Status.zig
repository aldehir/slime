//! A `status`: what a pane's programs report (OSC 7501), in a square
//! slot: a turning arc while working, a glowing dot while waiting on the
//! user, a check when done, a cross when failed. With nothing reported,
//! unseen output while the pane wasn't shown is a small dot.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Size = Ui.Size;

/// The slot's side, in DIPs: a row's button.
pub const size = 20;

pub fn measure(ui: *const Ui, _: *const Node) Size {
    return .{ .w = ui.px(size), .h = ui.px(size) };
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const s = node.kind.status;
    const slot = node.rect;
    const cx = slot.x + slot.w / 2;
    const cy = slot.y + slot.h / 2;
    const status = s.status orelse {
        if (s.activity) p.dot(cx, cy, ui.px(3), ui.theme.accent);
        return;
    };
    switch (status) {
        .idle => {},
        .working => {
            const turn = @as(f32, @floatFromInt(s.spinner % 12)) * (std.math.tau / 12.0);
            p.arc(cx, cy, ui.px(5), turn, std.math.tau * 0.72, ui.px(1.5), ui.theme.accent);
        },
        .blocked => {
            const w = ui.theme.warning;
            p.dot(cx, cy, ui.px(6), .{ w[0], w[1], w[2], 0.22 });
            p.dot(cx, cy, ui.px(3.5), w);
        },
        // Lucide's check and x span 16 and 12 of their 24 units.
        .done => ui.drawIcon(p, .check, slot.center(ui.px(15), ui.px(15)), ui.theme.success),
        .failed => ui.drawIcon(p, .x, slot.center(ui.px(16), ui.px(16)), ui.theme.danger),
    }
}
