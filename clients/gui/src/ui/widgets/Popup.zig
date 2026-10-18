//! A `menu`: a context menu's box, raised over everything with a soft
//! shadow. Its entries sit one under another, each an icon, a label, and
//! at the right the key that does the same; a separator is a line
//! between groups. The builder places the box (`place`) by the menu's
//! anchor, kept inside the window. The entry under the mouse is lit, or
//! while the mouse is off the menu, the one the keyboard is on.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Size = Ui.Size;
const Rect = Ui.Rect;
const Id = Ui.Id;
const Menu = Ui.Menu;

// Sizes in DIPs.
const pad_x = 6;
const pad_y = 6;
const entry_height = 28;
const separator_height = 9;
/// Inside an entry, before its icon and after its key.
const entry_pad_x = 8;
const icon_size = 16;
/// The icon's column, before the label.
const icon_column = 26;
/// Between the longest label and the key hints.
const key_gap = 28;
const min_width = 160;
const max_width = 280;
const radius = 8;
const entry_radius = 4;
/// The box's distance from the window's edges.
const margin = 8;
/// Between a `below` anchor and the box.
const below_gap = 4;

pub fn measure(ui: *const Ui, node: *const Node) Size {
    return size(ui, node.kind.menu.menu);
}

/// The box's size for `m`'s items: as wide as its longest entry, within
/// bounds, and as tall as them all.
pub fn size(ui: *const Ui, m: *const Menu) Size {
    const f = &ui.fonts;
    var w: f32 = 0;
    var h: f32 = 2 * ui.px(pad_y);
    for (m.constItems()) |item| switch (item) {
        .separator => h += ui.px(separator_height),
        .entry => |e| {
            h += ui.px(entry_height);
            var ew = 2 * ui.px(entry_pad_x) + ui.px(icon_column) + @ceil(f.measure(e.label, f.get(.body)));
            const key = e.key();
            if (key.len > 0) ew += ui.px(key_gap) + @ceil(f.measure(key.slice(), f.get(.tip)));
            w = @max(w, ew);
        },
    };
    w += 2 * ui.px(pad_x);
    return .{ .w = std.math.clamp(w, ui.px(min_width), ui.px(max_width)), .h = h };
}

/// Where a box of `s` goes for `m`'s anchor in `window`: at the point,
/// or under the widget, flipped to the other side of either when it
/// would leave the window, and kept a margin inside it regardless.
pub fn place(ui: *const Ui, m: *const Menu, window: Rect, s: Size) Rect {
    const w = s.w.?;
    const h = s.h.?;
    const mg = ui.px(margin);
    const right = window.right() - mg;
    const bottom = window.bottom() - mg;
    var x: f32 = undefined;
    var y: f32 = undefined;
    switch (m.anchor) {
        .point => |pt| {
            x = if (pt.x + w > right) pt.x - w else pt.x;
            y = if (pt.y + h > bottom) pt.y - h else pt.y;
        },
        .below => |r| {
            const gap = ui.px(below_gap);
            x = if (r.x + w > right) r.right() - w else r.x;
            y = if (r.bottom() + gap + h > bottom) r.y - gap - h else r.bottom() + gap;
        },
    }
    x = std.math.clamp(x, window.x + mg, @max(window.x + mg, right - w));
    y = std.math.clamp(y, window.y + mg, @max(window.y + mg, bottom - h));
    return .{ .x = @round(x), .y = @round(y), .w = w, .h = h };
}

/// An item and where it is in the box.
const Row = struct { index: usize, item: Menu.Item, rect: Rect };

/// The items top to bottom, inside the box's padding.
const Rows = struct {
    ui: *const Ui,
    m: *const Menu,
    x: f32,
    w: f32,
    y: f32,
    i: usize = 0,

    fn next(self: *Rows) ?Row {
        if (self.i == self.m.count) return null;
        const item = self.m.items[self.i];
        const h = self.ui.px(switch (item) {
            .entry => entry_height,
            .separator => separator_height,
        });
        const row: Row = .{ .index = self.i, .item = item, .rect = .{ .x = self.x, .y = self.y, .w = self.w, .h = h } };
        self.y += h;
        self.i += 1;
        return row;
    }
};

fn rows(ui: *const Ui, node: *const Node) Rows {
    const r = node.rect;
    return .{ .ui = ui, .m = node.kind.menu.menu, .x = r.x + ui.px(pad_x), .w = r.w - 2 * ui.px(pad_x), .y = r.y + ui.px(pad_y) };
}

fn entryId(i: usize) Id {
    return .{ .target = .{ .menu = @intCast(i) } };
}

/// An entry, by its index; anywhere else in the box is the box.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    var it = rows(ui, node);
    while (it.next()) |row| {
        if (row.item == .entry and row.rect.contains(x, y)) return entryId(row.index);
    }
    return node.id;
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const m = node.kind.menu.menu;
    const t = &ui.theme;
    const f = &ui.fonts;
    const r = node.rect;
    ui.paintShadow(p, r, ui.px(radius));
    ui.fillBordered(p, r, ui.px(radius), t.dialog, t.dialog_outline);

    const mouse_on_menu = ui.hover.target == .menu;
    const stroke = ui.stroke();
    var it = rows(ui, node);
    while (it.next()) |row| {
        const er = row.rect;
        const inner = er.inset(ui.px(entry_pad_x), 0);
        const e = switch (row.item) {
            .separator => {
                const y = Ui.crisp(er.y + er.h / 2, stroke);
                p.line(inner.x, y, inner.right(), y, stroke, t.dialog_outline);
                continue;
            },
            .entry => |e| e,
        };
        const id = entryId(row.index);
        const state = ui.buttonState(id);
        const lit = !e.disabled and (state != .rest or (!mouse_on_menu and m.focus == row.index));
        if (lit) p.fillRounded(er, ui.px(entry_radius), if (state == .pressed) t.button_pressed else t.button_hover);

        const color = if (e.disabled) t.text_inactive else if (e.danger) t.danger else if (lit) t.text_strong else t.text;
        if (e.icon) |icon| {
            const column: Rect = .{ .x = inner.x, .y = inner.y, .w = ui.px(icon_column), .h = inner.h };
            const icon_color = if (e.disabled) t.text_inactive else if (e.danger) t.danger else if (lit) t.text_strong else t.text_muted;
            ui.drawIcon(p, icon, column.center(ui.px(icon_size), ui.px(icon_size)), icon_color);
        }
        const label_x = inner.x + ui.px(icon_column);
        var label_w = inner.right() - label_x;
        const key = e.key();
        if (key.len > 0) {
            const key_w = @ceil(f.measure(key.slice(), f.get(.tip)));
            p.text(key.slice(), f.get(.tip), .{ .x = inner.right() - key_w, .y = inner.y, .w = key_w, .h = inner.h }, if (e.disabled) t.text_inactive else t.text_muted);
            label_w -= key_w + ui.px(key_gap);
        }
        p.text(e.label, f.get(.body), .{ .x = label_x, .y = inner.y, .w = @max(0, label_w), .h = inner.h }, color);
    }
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "the box fits its items, flips to stay in the window, and its entries are hit" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    var m: Menu = .{ .target = .{ .workspace = 3 }, .anchor = .{ .point = .{ .x = 100, .y = 100 } } };
    m.add(.{ .label = L("New tab"), .icon = .plus, .action = .{ .part = .new_tab } });
    m.separator();
    m.add(.{ .label = L("Kill"), .icon = .trash, .action = .{ .part = .kill }, .danger = true });
    const s = size(&ui, &m);
    // Without fonts every label is 0 wide: the narrowest box.
    try std.testing.expectEqual(@as(f32, min_width), s.w.?);
    try std.testing.expectEqual(@as(f32, 2 * pad_y + 2 * entry_height + separator_height), s.h.?);

    const window: Rect = .{ .w = 1000, .h = 600 };
    try std.testing.expectEqual(Rect{ .x = 100, .y = 100, .w = s.w.?, .h = s.h.? }, place(&ui, &m, window, s));
    // Near the right and bottom edges it opens up and to the left.
    m.anchor = .{ .point = .{ .x = 990, .y = 590 } };
    try std.testing.expectEqual(Rect{ .x = 990 - min_width, .y = 590 - s.h.?, .w = s.w.?, .h = s.h.? }, place(&ui, &m, window, s));
    // Under a strip at the bottom, it goes above it.
    m.anchor = .{ .below = .{ .x = 300, .y = 580, .w = 400, .h = 20 } };
    try std.testing.expectEqual(@as(f32, 300), place(&ui, &m, window, s).x);
    try std.testing.expectEqual(580 - below_gap - s.h.?, place(&ui, &m, window, s).y);
    // Anchored past the window it's kept at the margin.
    m.anchor = .{ .point = .{ .x = -50, .y = -50 } };
    try std.testing.expectEqual(Rect{ .x = margin, .y = margin, .w = s.w.?, .h = s.h.? }, place(&ui, &m, window, s));

    m.anchor = .{ .point = .{ .x = 100, .y = 100 } };
    const node: Node = .{ .id = Id.window(.menu), .kind = .{ .menu = .{ .menu = &m } }, .rect = place(&ui, &m, window, s) };
    const first_y = 100 + pad_y + 1;
    try std.testing.expectEqual(Id{ .target = .{ .menu = 0 } }, hitTest(&ui, &node, 110, first_y).?);
    // The separator is the box, and so is the padding.
    try std.testing.expectEqual(Id.window(.menu), hitTest(&ui, &node, 110, first_y + entry_height + 2).?);
    try std.testing.expectEqual(Id.window(.menu), hitTest(&ui, &node, 110, 101).?);
    try std.testing.expectEqual(Id{ .target = .{ .menu = 2 } }, hitTest(&ui, &node, 110, first_y + entry_height + separator_height + 2).?);
}
