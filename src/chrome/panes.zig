//! The active tab's panes, over the terminal area: each a rounded
//! rectangle on the chrome's ground, the panes without focus dimmed, and
//! icons at each pane's top right, faint until the mouse is over one,
//! which split it to the right or down and zoom it to fill the tab.

const std = @import("std");
const Chrome = @import("Chrome.zig");
const Painter = @import("../renderer/Painter.zig");

const Rect = Chrome.Rect;
const Hit = Chrome.Hit;
const Pane = Chrome.View.Pane;

// Sizes in DIPs.
/// Between panes, and around them (`Chrome.paneArea`).
pub const gap = 6;
const button_size = 24;
/// Between the icons and the pane's top and right edges.
const margin = 4;

/// The icons' opacity at rest, and while pressed.
const faint = 0.35;
const pressed = 0.7;

/// How much of a pane's background covers it while another has focus,
/// as Ghostty's `unfocused-split-opacity` of 0.7 leaves.
const dim = 0.3;

const Button = enum { split_right, split_down, zoom };

/// What's at a point in the terminal area: a pane, one of its buttons, or
/// a divider between panes.
pub fn hitTest(c: *const Chrome, view: *const Chrome.View, x: f32, y: f32) Hit {
    for (view.panes, 0..) |pane, i| {
        if (!pane.rect.contains(x, y)) continue;
        for (buttons(c, pane)) |b| {
            if (buttonRect(c, pane, b).contains(x, y)) return hitFor(b, i);
        }
        return .{ .terminal = i };
    }
    for (view.dividers, 0..) |d, i| {
        if (d.contains(x, y)) return .{ .divider = i };
    }
    return .none;
}

/// Where a pane button is, if `hit` is one on screen.
pub fn rect(c: *const Chrome, view: *const Chrome.View, hit: Hit) ?Rect {
    const b: Button, const i = switch (hit) {
        .split_right => |i| .{ .split_right, i },
        .split_down => |i| .{ .split_down, i },
        .zoom => |i| .{ .zoom, i },
        else => return null,
    };
    if (i >= view.panes.len) return null;
    const pane = view.panes[i];
    if (std.mem.indexOfScalar(Button, buttons(c, pane), b) == null) return null;
    return buttonRect(c, pane, b);
}

pub fn paint(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, view: *const Chrome.View) void {
    for (view.panes, 0..) |pane, i| {
        if (view.panes.len > 1 and !pane.focused) p.fill(pane.rect, .{ pane.bg[0], pane.bg[1], pane.bg[2], dim });
        p.cornerMasks(pane.rect, l.corner, c.theme.ground);
        for (buttons(c, pane)) |b| {
            const hit = hitFor(b, i);
            const t = c.theme.text_strong;
            const alpha: f32 = switch (c.buttonState(hit)) {
                .rest => faint,
                .hover => 1,
                .pressed => pressed,
            };
            // Each spans 18 of its 24 units: 13 DIPs in this box, whose
            // odd size centers the split's middle line on a pixel.
            const size = c.px(17);
            c.drawIcon(p, switch (b) {
                .split_right => .columns_2,
                .split_down => .rows_2,
                .zoom => if (pane.zoomed) .minimize_2 else .maximize_2,
            }, buttonRect(c, pane, b).center(size, size), .{ t[0], t[1], t[2], alpha });
        }
    }
}

/// The buttons a pane has, left to right.
/// None in a pane too small to hold them with room to spare.
fn buttons(c: *const Chrome, pane: Pane) []const Button {
    if (!pane.splittable) return &.{};
    const all: []const Button = if (pane.zoomable) &.{ .split_right, .split_down, .zoom } else &.{ .split_right, .split_down };
    const n: f32 = @floatFromInt(all.len);
    const size = c.px(button_size);
    if (pane.rect.w < (n + 1) * size + 2 * c.px(margin) or pane.rect.h < 2 * size + 2 * c.px(margin)) return &.{};
    return all;
}

fn hitFor(b: Button, i: usize) Hit {
    return switch (b) {
        .split_right => .{ .split_right = i },
        .split_down => .{ .split_down = i },
        .zoom => .{ .zoom = i },
    };
}

/// Button `b` in its bar at the pane's top right, counted from the right.
fn buttonRect(c: *const Chrome, pane: Pane, b: Button) Rect {
    const shown = buttons(c, pane);
    const index = std.mem.indexOfScalar(Button, shown, b) orelse 0;
    const from_right: f32 = @floatFromInt(shown.len - 1 - index);
    const size = c.px(button_size);
    const inset = c.px(margin);
    return .{
        .x = pane.rect.right() - inset - size - from_right * size,
        .y = pane.rect.y + inset,
        .w = size,
        .h = size,
    };
}

test "pane buttons" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const panes = [_]Pane{
        .{ .rect = .{ .w = 400, .h = 300 }, .focused = true, .splittable = true, .zoomable = true, .zoomed = false, .bg = .{ 0, 0, 0, 1 } },
        .{ .rect = .{ .x = 401, .w = 400, .h = 300 }, .focused = false, .splittable = true, .zoomable = true, .zoomed = false, .bg = .{ 0, 0, 0, 1 } },
    };
    const view: Chrome.View = .{
        .groups = &.{},
        .tabs = &.{},
        .active = 0,
        .panes = &panes,
        .dividers = &.{.{ .x = 400, .w = 1, .h = 300 }},
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    try std.testing.expectEqual(Hit{ .terminal = 0 }, hitTest(&c, &view, 10, 10));
    try std.testing.expectEqual(Hit{ .divider = 0 }, hitTest(&c, &view, 400.5, 10));
    try std.testing.expectEqual(Hit.none, hitTest(&c, &view, 400.5, 400));
    const zoom = rect(&c, &view, .{ .zoom = 1 }).?;
    try std.testing.expectEqual(@as(f32, 801 - margin), zoom.right());
    try std.testing.expectEqual(Hit{ .zoom = 1 }, hitTest(&c, &view, zoom.x + 1, zoom.y + 1));
    const split = rect(&c, &view, .{ .split_right = 1 }).?;
    try std.testing.expectEqual(Hit{ .split_right = 1 }, hitTest(&c, &view, split.x + 1, split.y + 1));
    try std.testing.expect(split.right() <= zoom.x);

    // A pane too narrow for its icons has none.
    var narrow = panes;
    narrow[1].rect.w = 80;
    var small = view;
    small.panes = &narrow;
    try std.testing.expect(rect(&c, &small, .{ .zoom = 1 }) == null);
    try std.testing.expectEqual(Hit{ .terminal = 1 }, hitTest(&c, &small, 401 + 80 - 10, 10));
}
