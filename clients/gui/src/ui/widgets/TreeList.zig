//! A `tree`: rows one under another, each with the rows under it set in,
//! which fold away. Rows under a row are joined to it by a guide: a
//! trunk down from the parent's fold column with a branch to each child,
//! turning into the last one with a rounded corner. Rows under a section
//! header sit flush with it, unguided. The `fold` arrow a row shows is
//! a leaf of its own, so each row colors and hit-tests its own.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");
const TreeRow = @import("../Tree.zig").TreeRow;

const Node = Ui.Node;
const Size = Ui.Size;
const Rect = Ui.Rect;
const Id = Ui.Id;

// Sizes in DIPs.
/// Between rows, and between a section header and the section before.
pub const row_gap = 2;
pub const section_gap = 10;
/// How far each level under a row is set in from it: past the row's
/// fold arrow, with room for the guide's branch.
pub const indent = 22;
/// The fold arrow's column at a row's left. The guide's trunk runs down
/// its middle.
pub const fold_width = 18;
/// The guide's thickness, the radius of its corner into the last child,
/// and how short of the child's row its branch stops.
const guide_width = 2;
const guide_radius = 6;
const guide_gap = 4;

pub fn measure(ui: *const Ui, node: *const Node) Size {
    return switch (node.kind) {
        .fold => .{ .w = ui.px(fold_width) },
        else => .{},
    };
}

pub fn layout(ui: *const Ui, node: *Node) void {
    switch (node.kind) {
        .tree => |t| {
            var y = node.rect.y;
            layoutRows(ui, t.rows, node.rect.x, node.rect.w, &y);
        },
        else => {},
    }
}

/// Place `rows` from `y` down, each as tall as it measures, and the
/// rows under each, set in, after it.
fn layoutRows(ui: *const Ui, rows: []TreeRow, x: f32, w: f32, y: *f32) void {
    for (rows, 0..) |*row, i| {
        if (row.section and i > 0) y.* += ui.px(section_gap);
        const h = ui.measure(&row.node).h orelse 0;
        row.node.rect = .{ .x = x, .y = y.*, .w = w, .h = h };
        ui.layoutNode(&row.node);
        y.* += h;
        if (!row.section) y.* += ui.px(row_gap);
        if (row.folded) continue;
        const in = if (row.section) 0 else ui.px(indent);
        layoutRows(ui, row.children, x + in, @max(0, w - in), y);
    }
}

pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    return switch (node.kind) {
        .tree => |t| hitRows(ui, t.rows, x, y),
        else => null,
    };
}

fn hitRows(ui: *const Ui, rows: []const TreeRow, x: f32, y: f32) ?Id {
    for (rows) |*row| {
        if (ui.hitNode(&row.node, x, y)) |id| return id;
        if (!row.folded) if (hitRows(ui, row.children, x, y)) |id| return id;
    }
    return null;
}

/// The node with `id` among `rows`, shown or folded away.
pub fn find(rows: []const TreeRow, id: Id) ?*const Node {
    for (rows) |*row| {
        if (Ui.findIn(&row.node, id)) |n| return n;
        if (find(row.children, id)) |n| return n;
    }
    return null;
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    switch (node.kind) {
        .tree => |t| paintRows(ui, p, t.rows),
        .fold => |f| {
            // Centered: down while open, right while folded.
            const area = node.rect;
            const h = ui.px(3);
            const cx = @round(area.x + area.w / 2);
            const cy = @round(area.y + area.h / 2);
            const w = ui.stroke();
            if (f.folded) {
                p.line(cx - h / 2, cy - h, cx + h / 2, cy, w, f.color);
                p.line(cx + h / 2, cy, cx - h / 2, cy + h, w, f.color);
            } else {
                p.line(cx - h, cy - h / 2, cx, cy + h / 2, w, f.color);
                p.line(cx, cy + h / 2, cx + h, cy - h / 2, w, f.color);
            }
        },
        else => {},
    }
}

fn paintRows(ui: *const Ui, p: *Painter, rows: []const TreeRow) void {
    for (rows) |*row| {
        ui.paintNode(p, &row.node);
        if (row.folded) continue;
        if (!row.section) paintGuides(ui, p, &row.node, row.children);
        paintRows(ui, p, row.children);
    }
}

/// The guides from `parent` into each of `children`: the trunk down
/// from the parent's bottom in its fold column, from child to child,
/// and a branch toward each, stopping short of it. Into the last child
/// the trunk turns with a rounded corner.
fn paintGuides(ui: *const Ui, p: *Painter, parent: *const Node, children: []const TreeRow) void {
    const w = ui.px(guide_width);
    const color = ui.theme.outline;
    const x = Ui.crisp(parent.rect.x + ui.px(fold_width) / 2, w);
    const radius = ui.px(guide_radius);
    var from = parent.rect.bottom();
    for (children, 0..) |*child, i| {
        const r = child.node.rect;
        const cy = Ui.crisp(r.y + r.h / 2, w);
        const end = r.x - ui.px(guide_gap);
        if (i + 1 == children.len) {
            p.elbow(x, from, cy, radius, end, w, color);
        } else {
            p.line(x, from, x, cy, w, color);
            p.line(x, cy, end, cy, w, color);
        }
        from = cy;
    }
}

/// A row `h` DIPs tall about `target`, for the tests.
fn testRow(id: Id, h: f32, children: []TreeRow) TreeRow {
    return .{ .node = .{ .id = id, .kind = .{ .row = .{ .children = &.{}, .h = h } } }, .children = children };
}

test "sections, rows under rows, folding, and guides" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const local: Id = .{ .target = .local };
    const hidden: Id = .{ .target = .{ .workspace = 10 } };
    const shown: Id = .{ .target = .{ .workspace = 11 } };
    const first: Id = .{ .target = .{ .tab = 1 } };
    const second: Id = .{ .target = .{ .tab = 2 } };
    const host: Id = .{ .target = .{ .host = 0 } };
    const host_tab: Id = .{ .target = .{ .tab = 3 } };
    const forgotten: Id = .{ .target = .{ .host = 1 } };

    var first_panes = [_]TreeRow{testRow(.{ .target = .{ .pane = 1 } }, 28, &.{})};
    var second_panes = [_]TreeRow{ testRow(.{ .target = .{ .pane = 2 } }, 28, &.{}), testRow(.{ .target = .{ .pane = 3 } }, 28, &.{}) };
    var shown_tabs = [_]TreeRow{ testRow(first, 30, &first_panes), testRow(second, 30, &second_panes) };
    shown_tabs[0].folded = true;
    var local_rows = [_]TreeRow{ testRow(hidden, 28, &.{}), testRow(shown, 28, &shown_tabs) };
    local_rows[0].folded = true;
    var host_panes = [_]TreeRow{testRow(.{ .target = .{ .pane = 4 } }, 28, &.{})};
    var host_tabs = [_]TreeRow{testRow(host_tab, 30, &host_panes)};
    var sections = [_]TreeRow{ testRow(local, 28, &local_rows), testRow(host, 28, &host_tabs), testRow(forgotten, 28, &.{}) };
    for (&sections) |*s| s.section = true;
    var node: Node = .{ .kind = .{ .tree = .{ .rows = &sections } }, .rect = .{ .x = 12, .y = 40, .w = 216, .h = 500 } };
    ui.layoutNode(&node);

    // Local's header, then its workspaces flush under it; the shown
    // one's tabs set in and the open tab's panes deeper still.
    const local_r = sections[0].node.rect;
    try std.testing.expectEqual(Rect{ .x = 12, .y = 40, .w = 216, .h = 28 }, local_r);
    const hidden_r = local_rows[0].node.rect;
    try std.testing.expectEqual(Rect{ .x = 12, .y = 68, .w = 216, .h = 28 }, hidden_r);
    const shown_r = local_rows[1].node.rect;
    try std.testing.expectEqual(@as(f32, 68 + 28 + row_gap), shown_r.y);
    const first_r = shown_tabs[0].node.rect;
    try std.testing.expectEqual(shown_r.x + indent, first_r.x);
    try std.testing.expectEqual(shown_r.bottom() + row_gap, first_r.y);
    try std.testing.expectEqual(@as(f32, 216 - indent), first_r.w);
    // The folded tab's panes aren't placed; the open tab's are.
    const second_r = shown_tabs[1].node.rect;
    try std.testing.expectEqual(first_r.bottom() + row_gap, second_r.y);
    const pane_r = second_panes[0].node.rect;
    try std.testing.expectEqual(second_r.x + indent, pane_r.x);
    try std.testing.expectEqual(second_r.bottom() + row_gap, pane_r.y);
    const pane2_r = second_panes[1].node.rect;
    try std.testing.expectEqual(pane_r.bottom() + row_gap, pane2_r.y);
    // The host's header after a section gap, its tab flush under it.
    const host_r = sections[1].node.rect;
    try std.testing.expectEqual(pane2_r.bottom() + row_gap + section_gap, host_r.y);
    try std.testing.expectEqual(Rect{ .x = 12, .y = host_r.bottom(), .w = 216, .h = 30 }, host_tabs[0].node.rect);
    const forgotten_r = sections[2].node.rect;
    try std.testing.expectEqual(host_panes[0].node.rect.bottom() + row_gap + section_gap, forgotten_r.y);

    // Hit testing finds rows and skips folded ones and the gaps.
    try std.testing.expectEqual(shown, hitTest(&ui, &node, shown_r.x + 2, shown_r.y + 2).?);
    try std.testing.expectEqual(Id{ .target = .{ .pane = 2 } }, hitTest(&ui, &node, pane_r.x + 40, pane_r.y + 2).?);
    try std.testing.expect(hitTest(&ui, &node, pane_r.x - 5, pane_r.y + 2) == null);
    try std.testing.expect(hitTest(&ui, &node, second_r.x + 2, host_r.y - 5) == null);
    try std.testing.expect(hitTest(&ui, &node, 100, first_r.bottom() + 20) != null);
    try std.testing.expect(find(&sections, .{ .target = .{ .pane = 1 } }) != null);
    try std.testing.expect(find(&sections, .{ .target = .{ .pane = 9 } }) == null);
}
