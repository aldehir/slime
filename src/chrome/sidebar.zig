//! Sessions in a sidebar under the title bar, grouped by where they run:
//! Local, then each SSH connection. A group's header has a button that
//! opens another session there. A "Connect" button at the bottom turns
//! into a field for a host to connect to.

const std = @import("std");
const Chrome = @import("Chrome.zig");
const Painter = @import("../renderer/Painter.zig");

const Rect = Chrome.Rect;
const Hit = Chrome.Hit;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

// Sizes in DIPs.
pub const titlebar_height = 36;
const width = 240;
const pad_x = 12;
const pad_top = 4;
const section_gap = 10;
const header_height = 28;
const row_height = 30;
const row_gap = 4;
/// Rows' close buttons and headers' new session buttons, in one column.
const button_size = 20;
const connect_height = 32;
const pad_bottom = 12;
const corner = 10;

pub fn layout(c: *const Chrome, l: *Chrome.Layout) void {
    const top = l.titlebar.bottom();
    const w = @min(c.px(width), l.window.w);
    const h = @max(0, l.window.h - top);
    l.list = .{ .y = top, .w = w, .h = h };
    l.terminal = .{ .x = w, .y = top, .w = l.window.w - w, .h = h };
    l.corner = c.px(corner);
}

pub fn hitTest(c: *const Chrome, l: *const Chrome.Layout, view: *const Chrome.View, x: f32, y: f32) ?Hit {
    if (!l.list.contains(x, y)) return null;
    if (connectRect(c, l).contains(x, y)) return .connect;
    const rows = rowsArea(c, l);
    if (!rows.contains(x, y)) return .none;
    var walk: Walk = .init(c, l, view);
    while (walk.next()) |item| {
        if (item.rect.y >= rows.bottom()) break;
        if (!item.rect.contains(x, y)) continue;
        const on_button = rowButton(c, item.rect).contains(x, y);
        return switch (item.part) {
            .header => |g| if (on_button) .{ .new_session = g } else .none,
            .row => |i| if (on_button) .{ .close_session = i } else .{ .session = i },
        };
    }
    return .none;
}

pub fn paint(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, view: *const Chrome.View) void {
    p.fill(l.list, c.theme.ground);
    c.paintTitle(p, l, view);
    p.pushClip(l.list);
    defer p.popClip();

    const rows = rowsArea(c, l);
    p.pushClip(rows);
    var walk: Walk = .init(c, l, view);
    while (walk.next()) |item| {
        if (item.rect.y >= rows.bottom()) break;
        switch (item.part) {
            .header => |g| paintHeader(c, p, item.rect, g, view.groups[g]),
            .row => |i| paintRow(c, p, item.rect, i, view.sessions[i], i == view.active),
        }
    }
    p.popClip();

    const connect = connectRect(c, l);
    if (view.connect) |field| {
        paintField(c, p, connect, field, view.focused and view.caret_visible);
    } else {
        paintConnect(c, p, connect);
    }
    paintStats(c, p, l, connect.y, view.stats);
}

/// "Connect", at the bottom of the list.
fn connectRect(c: *const Chrome, l: *const Chrome.Layout) Rect {
    const h = c.px(connect_height);
    return .{
        .x = l.list.x + c.px(pad_x),
        .y = l.list.bottom() - c.px(pad_bottom) - h,
        .w = @max(0, l.list.w - 2 * c.px(pad_x)),
        .h = h,
    };
}

/// Where groups and rows go: above "Connect".
fn rowsArea(c: *const Chrome, l: *const Chrome.Layout) Rect {
    const bottom = connectRect(c, l).y - c.px(section_gap);
    return .{ .x = l.list.x, .y = l.list.y, .w = l.list.w, .h = @max(0, bottom - l.list.y) };
}

/// The frame stats at the bottom left, above `bottom`, in line with the
/// section headers.
fn paintStats(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, bottom: f32, stats: []const u16) void {
    if (stats.len == 0) return;
    const line_h = c.px(16);
    const lines: f32 = @floatFromInt(std.mem.countScalar(u16, stats, '\n') + 1);
    const x = l.list.x + c.px(pad_x) + c.px(2);
    var r: Rect = .{
        .x = x,
        .y = bottom - c.px(10) - lines * line_h,
        .w = @max(0, l.list.right() - c.px(pad_x) - x),
        .h = line_h,
    };
    var it = std.mem.splitScalar(u16, stats, '\n');
    while (it.next()) |line| : (r.y += line_h) p.text(line, c.fonts.mono, r, c.theme.text_muted);
}

fn paintConnect(c: *const Chrome, p: *Painter, r: Rect) void {
    const bg = switch (c.buttonState(.connect)) {
        .rest => c.theme.surface,
        .hover, .pressed => c.theme.surface_hover,
    };
    p.fillRounded(r, c.px(6), bg);
    // Lucide's plug spans 16 of its 24 units: 13 DIPs in this box, which
    // puts the prongs on pixel centers.
    const icon = c.px(20);
    c.drawIcon(p, .plug, .{ .x = r.x + c.px(7), .y = r.y + @round((r.h - icon) / 2), .w = icon, .h = icon }, c.theme.text);
    const label_x = r.x + c.px(32);
    p.text(L("Connect…"), c.fonts.body, .{ .x = label_x, .y = r.y, .w = @max(0, r.right() - c.px(8) - label_x), .h = r.h }, c.theme.text);
}

/// The host field "Connect" turns into: its text scrolled to keep the
/// caret in view, with the selection behind it.
fn paintField(c: *const Chrome, p: *Painter, r: Rect, field: *const Chrome.TextField, caret: bool) void {
    const radius = c.px(6);
    p.fillRounded(r, radius, c.theme.surface);
    p.strokeRounded(r.inset(c.stroke() / 2, c.stroke() / 2), radius, c.stroke(), c.theme.accent);

    const inner = r.inset(c.px(10), 0);
    const text = field.text();
    const font = c.fonts.body;
    if (text.len == 0) p.text(L("user@host:port"), font, inner, c.theme.text_inactive);

    const caret_x = c.fonts.measure(text[0..field.caret], font);
    // Room for the caret at the right edge.
    const scroll = @max(0, caret_x - (inner.w - c.stroke()));
    const x = inner.x - scroll;
    p.pushClip(inner.inset(0, -r.h));
    defer p.popClip();
    const sel = field.selection();
    if (sel.start != sel.end) {
        const x0 = x + c.fonts.measure(text[0..sel.start], font);
        const x1 = x + c.fonts.measure(text[0..sel.end], font);
        p.fill(.{ .x = @round(x0), .y = r.y + c.px(7), .w = @round(x1) - @round(x0), .h = r.h - c.px(14) }, c.theme.selection);
    }
    // Laid out wider than it is, so it's never trimmed.
    p.text(text, font, .{ .x = x, .y = r.y, .w = c.fonts.measure(text, font) + inner.w, .h = r.h }, c.theme.text);
    if (caret) {
        const cx = Chrome.crisp(x + caret_x, c.stroke());
        p.line(cx, r.y + c.px(8), cx, r.bottom() - c.px(8), c.stroke(), c.theme.text_strong);
    }
}

fn paintHeader(c: *const Chrome, p: *Painter, r: Rect, g: usize, group: Chrome.View.Group) void {
    const button = rowButton(c, r);
    const hit: Hit = .{ .new_session = g };
    const hovered = c.hover.eql(hit);
    if (hovered) p.fillRounded(button, c.px(4), switch (c.buttonState(hit)) {
        .pressed => c.theme.button_pressed,
        else => c.theme.button_hover,
    });
    // Lucide's plus spans 14 of its 24 units: 10 DIPs in this box, whose
    // odd size centers the lines on pixels.
    const icon = c.px(17);
    c.drawIcon(p, .plus, button.center(icon, icon), if (hovered) c.theme.text_strong else c.theme.text_muted);

    const label_x = r.x + c.px(2);
    const label: Rect = .{ .x = label_x, .y = r.y, .w = @max(0, button.x - c.px(4) - label_x), .h = r.h };
    var buf: [256]u16 = undefined;
    p.text(upper(&buf, group.label), c.fonts.section, label, c.theme.text_muted);
}

/// `text` in capitals, as section headers are, cut to fit `buf`. Only
/// ASCII letters change: labels are host names.
fn upper(buf: []u16, text: []const u16) []const u16 {
    const n = @min(buf.len, text.len);
    for (buf[0..n], text[0..n]) |*out, unit| {
        out.* = if (unit >= 'a' and unit <= 'z') unit - ('a' - 'A') else unit;
    }
    return buf[0..n];
}

fn paintRow(c: *const Chrome, p: *Painter, r: Rect, i: usize, session: Chrome.View.Session, active: bool) void {
    const close_hovered = c.hover.eql(.{ .close_session = i });
    const hovered = close_hovered or c.hover.eql(.{ .session = i });
    const radius = c.px(6);
    if (active) {
        p.fillRounded(r, radius, c.theme.row_selected);
    } else if (hovered) {
        p.fillRounded(r, radius, c.theme.row_hover);
    }

    const icon = c.px(16);
    const icon_color = if (active) c.theme.text else c.theme.text_muted;
    c.drawIcon(p, .terminal, .{ .x = r.x + c.px(10), .y = r.y + @round((r.h - icon) / 2), .w = icon, .h = icon }, icon_color);

    const close = rowButton(c, r);
    const text_x = r.x + c.px(34);
    const text_right = if (hovered or active or session.activity) close.x - c.px(4) else r.right() - c.px(8);
    const text_rect: Rect = .{ .x = text_x, .y = r.y, .w = @max(0, text_right - text_x), .h = r.h };
    if (active) {
        p.text(session.title, c.fonts.body_strong, text_rect, c.theme.text_strong);
    } else {
        p.text(session.title, c.fonts.body, text_rect, c.theme.text);
    }

    if (hovered or active) {
        if (close_hovered) p.fillRounded(close, c.px(4), switch (c.buttonState(.{ .close_session = i })) {
            .pressed => c.theme.button_pressed,
            else => c.theme.button_hover,
        });
        // Lucide's x spans 12 of its 24 units: 8 DIPs in this box.
        const g = c.px(16);
        c.drawIcon(p, .x, close.center(g, g), if (close_hovered) c.theme.text_strong else c.theme.text_muted);
    } else if (session.activity) {
        p.dot(close.x + close.w / 2, close.y + close.h / 2, c.px(3), c.theme.accent);
    }
}

/// The button at the right of a row or header.
fn rowButton(c: *const Chrome, row: Rect) Rect {
    const size = c.px(button_size);
    return .{
        .x = row.right() - c.px(5) - size,
        .y = row.y + @round((row.h - size) / 2),
        .w = size,
        .h = size,
    };
}

/// The list's parts from the top: each group's header, then its rows.
const Walk = struct {
    groups: []const Chrome.View.Group,
    x: f32,
    w: f32,
    /// The top of the next part.
    y: f32,
    header_h: f32,
    row_h: f32,
    row_gap: f32,
    section_gap: f32,
    group: usize = 0,
    /// Parts given out of the current group, its header first.
    in_group: usize = 0,
    session: usize = 0,

    const Item = struct {
        part: union(enum) { header: usize, row: usize },
        rect: Rect,
    };

    fn init(c: *const Chrome, l: *const Chrome.Layout, view: *const Chrome.View) Walk {
        return .{
            .groups = view.groups,
            .x = l.list.x + c.px(pad_x),
            .w = @max(0, l.list.w - 2 * c.px(pad_x)),
            .y = l.list.y + c.px(pad_top),
            .header_h = c.px(header_height),
            .row_h = c.px(row_height),
            .row_gap = c.px(row_gap),
            .section_gap = c.px(section_gap),
        };
    }

    fn next(self: *Walk) ?Item {
        while (self.group < self.groups.len) {
            if (self.in_group == 0) {
                self.in_group = 1;
                return .{ .part = .{ .header = self.group }, .rect = self.take(self.header_h, 0) };
            }
            if (self.in_group <= self.groups[self.group].sessions) {
                self.in_group += 1;
                self.session += 1;
                return .{ .part = .{ .row = self.session - 1 }, .rect = self.take(self.row_h, self.row_gap) };
            }
            self.group += 1;
            self.in_group = 0;
            self.y += self.section_gap;
        }
        return null;
    }

    /// The next `h` of the list, with `gap` after it.
    fn take(self: *Walk, h: f32, gap: f32) Rect {
        const r: Rect = .{ .x = self.x, .y = self.y, .w = self.w, .h = h };
        self.y += h + gap;
        return r;
    }
};

test "groups, rows, and their buttons" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const view: Chrome.View = .{
        .groups = &.{ .{ .label = &.{}, .sessions = 0 }, .{ .label = &.{}, .sessions = 2 } },
        .sessions = &.{ .{ .title = &.{}, .activity = false }, .{ .title = &.{}, .activity = false } },
        .active = 0,
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    const l = c.layout(1000, 600);
    var walk: Walk = .init(&c, &l, &view);
    const local = walk.next().?;
    try std.testing.expectEqual(@as(usize, 0), local.part.header);
    const remote = walk.next().?;
    try std.testing.expectEqual(@as(usize, 1), remote.part.header);
    try std.testing.expect(remote.rect.y > local.rect.bottom());
    _ = walk.next().?;
    const second = walk.next().?.rect;
    try std.testing.expect(walk.next() == null);
    const connect = connectRect(&c, &l);
    try std.testing.expectEqual(l.list.bottom() - pad_bottom, connect.bottom());
    try std.testing.expectEqual(Hit.connect, c.hitTest(&l, &view, connect.x + 1, connect.y + 1));

    try std.testing.expectEqual(Hit{ .session = 1 }, c.hitTest(&l, &view, second.x + 2, second.y + 2));
    const close = rowButton(&c, second);
    try std.testing.expectEqual(Hit{ .close_session = 1 }, c.hitTest(&l, &view, close.x + 1, close.y + 1));
    const plus = rowButton(&c, remote.rect);
    try std.testing.expectEqual(Hit{ .new_session = 1 }, c.hitTest(&l, &view, plus.x + 1, plus.y + 1));
    try std.testing.expectEqual(Hit.none, c.hitTest(&l, &view, remote.rect.x + 2, remote.rect.y + 2));
    // Below the last row.
    try std.testing.expectEqual(Hit.none, c.hitTest(&l, &view, second.x + 2, second.bottom() + 5));
}
