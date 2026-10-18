//! The containers: a `column` and a `row` that share their space among
//! their children, a `stack` whose children overlay each other, and a
//! `canvas` whose children go where the builder put them. `spacer` and
//! `hit_area` are the leaves that draw nothing.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Size = Ui.Size;
const Rect = Ui.Rect;
const Insets = @import("../Tree.zig").Insets;

pub fn measure(ui: *const Ui, node: *const Node) Size {
    switch (node.kind) {
        .column => |c| {
            // As tall as its children together, unless one takes what
            // it's given.
            var h: f32 = ui.px(c.pad.top) + ui.px(c.pad.bottom);
            for (c.children, 0..) |*child, i| {
                h += ui.measure(child).h orelse return .{};
                if (i > 0) h += ui.px(c.gap);
            }
            return .{ .h = h };
        },
        .row => |r| {
            var w: f32 = ui.px(r.pad.left) + ui.px(r.pad.right);
            var h: ?f32 = if (r.h) |dip| ui.px(dip) else null;
            var flexible = false;
            for (r.children, 0..) |*child, i| {
                const s = ui.measure(child);
                if (s.w) |cw| w += cw else flexible = true;
                if (i > 0) w += ui.px(r.gap);
                // As tall as its tallest child, if they all say and it
                // doesn't itself.
                if (r.h == null) if (s.h) |ch| {
                    h = @max(h orelse 0, ch + ui.px(r.pad.top) + ui.px(r.pad.bottom));
                };
            }
            if (r.w) |dip| return .{ .w = ui.px(dip), .h = h };
            return .{ .w = if (flexible) null else w, .h = h };
        },
        .spacer => |dip| return .{ .w = ui.px(dip), .h = ui.px(dip) },
        else => return .{},
    }
}

pub fn layout(ui: *const Ui, node: *Node) void {
    switch (node.kind) {
        .column => |c| place(ui, node.rect, c.children, c.gap, c.pad, .vertical, c.justify == .end),
        .row => |r| place(ui, node.rect, r.children, r.gap, r.pad, .horizontal, false),
        .stack => |nodes| for (nodes) |*child| {
            child.rect = node.rect;
            ui.layoutNode(child);
        },
        .canvas => |nodes| for (nodes) |*child| ui.layoutNode(child),
        else => {},
    }
}

const Axis = enum { vertical, horizontal };

/// Lay `children` along `axis` inside `rect` less `pad`: each takes the
/// length it measures, and those that measure none share what's left.
/// Across the axis a child takes the whole width (or height) unless it
/// measures one, which is then centered on whole pixels. `from_end`
/// packs them to the bottom (or right).
fn place(ui: *const Ui, rect: Rect, children: []Node, gap: f32, pad: Insets, axis: Axis, from_end: bool) void {
    const inner: Rect = .{
        .x = rect.x + ui.px(pad.left),
        .y = rect.y + ui.px(pad.top),
        .w = @max(0, rect.w - ui.px(pad.left) - ui.px(pad.right)),
        .h = @max(0, rect.h - ui.px(pad.top) - ui.px(pad.bottom)),
    };
    const along = if (axis == .vertical) inner.h else inner.w;
    var fixed: f32 = 0;
    var flexible: f32 = 0;
    for (children, 0..) |*child, i| {
        const s = ui.measure(child);
        const len = if (axis == .vertical) s.h else s.w;
        if (len) |l| fixed += l else flexible += 1;
        if (i > 0) fixed += ui.px(gap);
    }
    const share = if (flexible > 0) @max(0, along - fixed) / flexible else 0;
    var at = if (from_end) along - fixed - share * flexible else 0;
    for (children, 0..) |*child, i| {
        if (i > 0) at += ui.px(gap);
        var s = ui.measure(child);
        // A spacer is space along the axis, the whole width (or height)
        // across it.
        if (child.kind == .spacer) s = if (axis == .vertical) .{ .h = s.h } else .{ .w = s.w };
        switch (axis) {
            .vertical => {
                const h = s.h orelse share;
                const w = s.w orelse inner.w;
                child.rect = .{ .x = inner.x, .y = inner.y + at, .w = w, .h = h };
                at += h;
            },
            .horizontal => {
                const w = s.w orelse share;
                const h = s.h orelse inner.h;
                child.rect = .{ .x = inner.x + at, .y = inner.y + @round((inner.h - h) / 2), .w = w, .h = h };
                at += w;
            },
        }
        ui.layoutNode(child);
    }
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    switch (node.kind) {
        .column => |c| if (c.bg) |bg| p.fill(node.rect, bg),
        .row => |r| if (r.bg) |bg| {
            if (r.radius > 0) p.fillRounded(node.rect, ui.px(r.radius), bg) else p.fill(node.rect, bg);
        },
        else => {},
    }
    ui.paintChildren(p, node);
}

test "a column shares what's left and a row centers across" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    var row_children = [_]Node{
        .{ .kind = .{ .spacer = 10 } },
        .{ .kind = .{ .icon_button = .{ .icon = .plus, .size = 17 } } },
        .{ .kind = .{ .label = .{ .text = &.{}, .color = undefined } } },
    };
    var children = [_]Node{
        .{ .kind = .{ .spacer = 20 } },
        .{ .kind = .{ .row = .{ .children = &row_children } } },
        .{ .kind = .hit_area },
        .{ .kind = .{ .button = .{ .label = &.{} } } },
    };
    var node: Node = .{ .kind = .{ .column = .{ .children = &children, .pad = .{ .left = 12, .right = 12, .top = 4 } } }, .rect = .{ .w = 240, .h = 400 } };
    ui.layoutNode(&node);
    // The spacer, the 20-high row (its button's height), and the 32-high
    // button are fixed; the hit area takes the rest.
    try std.testing.expectEqual(Rect{ .x = 12, .y = 4, .w = 216, .h = 20 }, children[0].rect);
    try std.testing.expectEqual(Rect{ .x = 12, .y = 24, .w = 216, .h = 20 }, children[1].rect);
    try std.testing.expectEqual(Rect{ .x = 12, .y = 44, .w = 216, .h = 400 - 4 - 20 - 20 - 32 }, children[2].rect);
    try std.testing.expectEqual(@as(f32, 368), children[3].rect.y);
    try std.testing.expectEqual(@as(f32, 32), children[3].rect.h);
    // In the row: the spacer, the button, then the label takes the rest.
    try std.testing.expectEqual(Rect{ .x = 12, .y = 24, .w = 10, .h = 20 }, row_children[0].rect);
    try std.testing.expectEqual(Rect{ .x = 22, .y = 24, .w = 20, .h = 20 }, row_children[1].rect);
    try std.testing.expectEqual(Rect{ .x = 42, .y = 24, .w = 216 - 30, .h = 20 }, row_children[2].rect);

    // Packed to the bottom.
    var lines = [_]Node{.{ .kind = .{ .lines = .{ .text = std.unicode.utf8ToUtf16LeStringLiteral("a\nb"), .color = undefined } } }};
    var bottom: Node = .{ .kind = .{ .column = .{ .children = &lines, .pad = .{ .bottom = 54 }, .justify = .end } }, .rect = .{ .w = 240, .h = 400 } };
    ui.layoutNode(&bottom);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 400 - 54 - 32, .w = 240, .h = 32 }, lines[0].rect);
}
