//! Sessions in a sidebar under the title bar, grouped by where they run.
//! Only local sessions exist so far, so there's one group.

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
const pad_top = 8;
const button_height = 32;
const section_gap = 10;
const header_height = 28;
const row_height = 30;
const row_gap = 4;
const close_size = 20;
const corner = 10;

const new_session_hint = L("Ctrl+Shift+T");

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
    const p: Parts = .init(c, l);
    if (p.new_session.contains(x, y)) return .new_session;
    for (0..view.sessions.len) |i| {
        const r = p.row(i);
        if (r.y >= l.list.bottom()) break;
        if (!r.contains(x, y)) continue;
        return if (closeButton(c, r).contains(x, y)) .{ .close_session = i } else .{ .session = i };
    }
    return .none;
}

pub fn paint(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, view: *const Chrome.View) void {
    p.fill(l.list, c.theme.ground);
    c.paintTitle(p, l, view);
    p.pushClip(l.list);
    defer p.popClip();

    const parts: Parts = .init(c, l);
    paintNewSession(c, p, parts.new_session);
    p.text(L("LOCAL"), c.fonts.section, parts.header.inset(c.px(2), 0), c.theme.text_muted);
    for (view.sessions, 0..) |session, i| {
        const r = parts.row(i);
        if (r.y >= l.list.bottom()) break;
        paintRow(c, p, r, i, session, i == view.active);
    }
    paintStats(c, p, l, view.stats);
}

/// The frame stats at the bottom left, in line with the section headers.
fn paintStats(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, stats: []const u16) void {
    if (stats.len == 0) return;
    const line_h = c.px(16);
    const lines: f32 = @floatFromInt(std.mem.countScalar(u16, stats, '\n') + 1);
    const x = l.list.x + c.px(pad_x) + c.px(2);
    var r: Rect = .{
        .x = x,
        .y = l.list.bottom() - c.px(10) - lines * line_h,
        .w = @max(0, l.list.right() - c.px(pad_x) - x),
        .h = line_h,
    };
    var it = std.mem.splitScalar(u16, stats, '\n');
    while (it.next()) |line| : (r.y += line_h) p.text(line, c.fonts.mono, r, c.theme.text_muted);
}

fn paintNewSession(c: *const Chrome, p: *Painter, r: Rect) void {
    const bg = switch (c.buttonState(.new_session)) {
        .rest => c.theme.surface,
        .hover, .pressed => c.theme.surface_hover,
    };
    p.fillRounded(r, c.px(6), bg);
    // Lucide's plus spans 14 of its 24 units: 12 DIPs wide in this box,
    // whose odd size centers the lines on pixels.
    const icon = c.px(21);
    c.drawIcon(p, .plus, .{ .x = r.x + c.px(6), .y = r.y + @round((r.h - icon) / 2), .w = icon, .h = icon }, c.theme.text);

    // The key hint, in an outlined chip at the right.
    const hint_w = @ceil(c.fonts.measure(new_session_hint, c.fonts.hint)) + c.px(10);
    const hint: Rect = .{
        .x = r.right() - c.px(8) - hint_w,
        .y = r.y + @round((r.h - c.px(18)) / 2),
        .w = hint_w,
        .h = c.px(18),
    };
    p.strokeRounded(hint, c.px(4), c.stroke(), c.theme.outline);
    p.text(new_session_hint, c.fonts.hint, hint, c.theme.text_muted);

    const label_x = r.x + c.px(30);
    p.text(L("New session"), c.fonts.body, .{ .x = label_x, .y = r.y, .w = hint.x - c.px(8) - label_x, .h = r.h }, c.theme.text);
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

    const close = closeButton(c, r);
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

fn closeButton(c: *const Chrome, row: Rect) Rect {
    const size = c.px(close_size);
    return .{
        .x = row.right() - c.px(5) - size,
        .y = row.y + @round((row.h - size) / 2),
        .w = size,
        .h = size,
    };
}

/// Where the list's parts go.
const Parts = struct {
    new_session: Rect,
    header: Rect,
    /// From one row's top to the next's.
    row_step: f32,
    row_h: f32,

    fn init(c: *const Chrome, l: *const Chrome.Layout) Parts {
        const x = l.list.x + c.px(pad_x);
        const w = @max(0, l.list.w - 2 * c.px(pad_x));
        const new_session: Rect = .{ .x = x, .y = l.list.y + c.px(pad_top), .w = w, .h = c.px(button_height) };
        return .{
            .new_session = new_session,
            .header = .{ .x = x, .y = new_session.bottom() + c.px(section_gap), .w = w, .h = c.px(header_height) },
            .row_step = c.px(row_height) + c.px(row_gap),
            .row_h = c.px(row_height),
        };
    }

    fn row(self: Parts, i: usize) Rect {
        return .{
            .x = self.header.x,
            .y = self.header.bottom() + @as(f32, @floatFromInt(i)) * self.row_step,
            .w = self.header.w,
            .h = self.row_h,
        };
    }
};

test "rows and their close buttons" {
    const c: Chrome = .{ .scale = 1, .fonts = undefined, .theme = undefined };
    const view: Chrome.View = .{
        .sessions = &.{ .{ .title = &.{}, .activity = false }, .{ .title = &.{}, .activity = false } },
        .active = 0,
        .focused = true,
        .maximized = false,
        .terminal_bg = .{ 0, 0, 0, 1 },
    };
    const l = c.layout(1000, 600);
    const parts: Parts = .init(&c, &l);
    const second = parts.row(1);
    try std.testing.expectEqual(Hit{ .session = 1 }, c.hitTest(&l, &view, second.x + 2, second.y + 2));
    const close = closeButton(&c, second);
    try std.testing.expectEqual(Hit{ .close_session = 1 }, c.hitTest(&l, &view, close.x + 1, close.y + 1));
    try std.testing.expectEqual(Hit.new_session, c.hitTest(&l, &view, parts.new_session.x + 1, parts.new_session.y + 1));
    // Below the last row.
    try std.testing.expectEqual(Hit.none, c.hitTest(&l, &view, second.x + 2, second.bottom() + 5));
}
