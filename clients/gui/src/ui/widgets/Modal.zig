//! A `dialog`, centered over the terminal area, which a scrim dims: a
//! raised, rounded box with a soft shadow holding a `Dialog`'s title,
//! text, detail, fields, status, and buttons. The node is the whole area:
//! anything over it is the dialog's, so the terminal behind takes no
//! clicks. Layout is one function, so drawing and hit testing agree.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Rect = Ui.Rect;
const Id = Ui.Id;
const Color = Ui.Color;
const mix = @import("../theme.zig").mix;
const withAlpha = @import("../theme.zig").withAlpha;
const Dialog = Ui.Dialog;

// Sizes in DIPs.
const width = 400;
const wide_width = 440;
const pad = 20;
const pad_bottom = 16;
const gap = 14;
const radius = 10;
const title_height = 22;
const icon_size = 18;
const label_height = 18;
const label_gap = 6;
const field_height = 34;
const detail_pad_x = 10;
const detail_pad_y = 7;
const status_height = 18;
const button_height = 32;
const button_pad_x = 16;
const button_gap = 8;

pub const Layout = struct {
    box: Rect,
    icon: Rect,
    title: Rect,
    text: Rect = .{},
    detail: Rect = .{},
    fields: [Dialog.max_fields]FieldRects = undefined,
    err: Rect = .{},
    status: Rect = .{},
    buttons: [Dialog.max_buttons]Rect = undefined,
    button_list: [Dialog.max_buttons]Dialog.Button = undefined,
    button_count: usize = 0,

    pub const FieldRects = struct { above: Rect, label: Rect, box: Rect };

    pub fn buttonSlice(self: *const Layout) []const Dialog.Button {
        return self.button_list[0..self.button_count];
    }
};

pub fn layoutIn(ui: *const Ui, area: Rect, d: *const Dialog) Layout {
    const f = &ui.fonts;
    const w = @min(ui.px(if (d.wide) wide_width else width), @max(0, area.w - ui.px(32)));
    const inner_w = w - 2 * ui.px(pad);
    const x = area.x + @round((area.w - w) / 2);
    const left = x + ui.px(pad);

    // Stack everything from 0, then center the box.
    var y: f32 = ui.px(pad);
    var l: Layout = .{ .box = .{}, .icon = .{}, .title = .{} };
    const title_h = ui.px(title_height);
    const icon = ui.px(icon_size);
    l.icon = .{ .x = left, .y = y + @round((title_h - icon) / 2), .w = icon, .h = icon };
    const title_x = left + icon + ui.px(10);
    l.title = .{ .x = title_x, .y = y, .w = left + inner_w - title_x, .h = title_h };
    y += title_h;

    if (d.text.len > 0) {
        y += ui.px(gap);
        l.text = .{ .x = left, .y = y, .w = inner_w, .h = f.measureHeight(d.text, f.get(.prose), inner_w) };
        y += l.text.h;
    }
    if (d.detail.len > 0) {
        y += ui.px(gap);
        const text_w = inner_w - 2 * ui.px(detail_pad_x);
        const h = f.measureHeight(d.detail, f.get(.mono_prose), text_w) + 2 * ui.px(detail_pad_y);
        l.detail = .{ .x = left, .y = y, .w = inner_w, .h = h };
        y += h;
    }
    for (d.constFields(), 0..) |field, i| {
        y += ui.px(gap);
        var above: Rect = .{ .x = left, .y = y, .w = inner_w, .h = 0 };
        if (field.above.len > 0) {
            above.h = f.measureHeight(field.above, f.get(.prose), inner_w);
            y += above.h + ui.px(label_gap);
        }
        const label: Rect = .{ .x = left, .y = y, .w = inner_w, .h = ui.px(label_height) };
        y += label.h + ui.px(label_gap);
        const box: Rect = .{ .x = left, .y = y, .w = inner_w, .h = ui.px(field_height) };
        y += box.h;
        l.fields[i] = .{ .above = above, .label = label, .box = box };
    }
    if (d.err.len > 0 and d.state == .asking) {
        y += ui.px(label_gap);
        l.err = .{ .x = left, .y = y, .w = inner_w, .h = f.measureHeight(d.err, f.get(.prose), inner_w) };
        y += l.err.h;
    }
    if (d.state != .asking) {
        y += ui.px(gap);
        const text_h = if (d.status.len > 0) f.measureHeight(d.status, f.get(.prose), inner_w - ui.px(24)) else 0;
        l.status = .{ .x = left, .y = y, .w = inner_w, .h = @max(ui.px(status_height), text_h) };
        y += l.status.h;
    }

    const buttons = d.buttons(&l.button_list);
    l.button_count = buttons.len;
    y += ui.px(gap) + ui.px(2);
    var bx = left + inner_w;
    var i = buttons.len;
    while (i > 0) {
        i -= 1;
        const font = f.get(if (buttons[i].style == .primary) .button_strong else .button);
        const bw = @ceil(f.measure(buttons[i].label, font)) + 2 * ui.px(button_pad_x);
        bx -= bw;
        l.buttons[i] = .{ .x = bx, .y = y, .w = bw, .h = ui.px(button_height) };
        bx -= ui.px(button_gap);
    }
    y += ui.px(button_height) + ui.px(pad_bottom);

    // Centered, but not above the area's top.
    const top = @max(area.y + ui.px(24), area.y + @round((area.h - y) / 2));
    l.box = .{ .x = x, .y = top, .w = w, .h = y };
    l.icon.y += top;
    l.title.y += top;
    l.text.y += top;
    l.detail.y += top;
    for (l.fields[0..d.field_count]) |*fr| {
        fr.above.y += top;
        fr.label.y += top;
        fr.box.y += top;
    }
    l.err.y += top;
    l.status.y += top;
    for (l.buttons[0..l.button_count]) |*b| b.y += top;
    return l;
}

/// A button that can be pressed, or a field while asking; anything else
/// over the area is the scrim.
pub fn hitTest(ui: *const Ui, node: *const Node, x: f32, y: f32) ?Id {
    const d = node.kind.dialog.dialog;
    const l = layoutIn(ui, node.rect, d);
    for (l.buttons[0..l.button_count], l.buttonSlice(), 0..) |r, b, i| {
        if (r.contains(x, y) and !b.disabled) return .{ .target = .{ .dialog = @intCast(i) }, .part = .button };
    }
    if (d.state == .asking) {
        for (l.fields[0..d.field_count], 0..) |fr, i| {
            if (fr.box.contains(x, y)) return .{ .target = .{ .dialog = @intCast(i) }, .part = .field };
        }
    }
    return node.id;
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    const v = node.kind.dialog;
    const d = v.dialog;
    const t = &ui.theme;
    const f = &ui.fonts;
    p.fill(node.rect, t.scrim);
    const l = layoutIn(ui, node.rect, d);
    const r = l.box;

    ui.paintShadow(p, r, ui.px(radius), 4, 1.5);
    const edge = if (d.danger) mix(t.dialog_outline, t.danger, 0.35) else t.dialog_outline;
    ui.fillBordered(p, r, ui.px(radius), t.dialog, edge);

    const accent = if (d.danger) t.danger else t.accent;
    ui.drawIcon(p, switch (d.icon) {
        .lock => .lock,
        .key => .key_round,
        .unknown_host => .shield_question_mark,
        .warning => .shield_alert,
    }, l.icon, accent);
    p.text(d.title, f.get(.heading), l.title, if (d.danger) t.danger else t.text_strong);

    const dim = d.state != .asking;
    if (d.text.len > 0) p.text(d.text, f.get(.prose), l.text, if (dim) t.text_muted else t.text);
    if (d.detail.len > 0) {
        p.fillRounded(l.detail, ui.px(6), v.terminal_bg);
        p.text(d.detail, f.get(.mono_prose), l.detail.inset(ui.px(detail_pad_x), ui.px(detail_pad_y)), t.text_strong);
    }

    for (d.constFields(), l.fields[0..d.field_count], 0..) |*field, fr, n| {
        if (field.above.len > 0) p.text(field.above, f.get(.prose), fr.above, if (dim) t.text_muted else t.text);
        p.text(field.label, f.get(.body), fr.label, if (dim) t.text_muted else t.text);
        const focused = !dim and std.meta.eql(d.focus, Dialog.Focus{ .field = n });
        const box = fr.box;
        if (focused) ui.paintGlow(p, box, ui.px(6), t.accent);
        ui.fillBordered(p, box, ui.px(6), if (dim) v.terminal_bg else t.ground, if (focused) t.accent else t.outline);
        ui.paintEditText(p, box.inset(ui.px(10), 0), &field.edit, .{
            .caret = focused and v.caret,
            .mask = !field.echo,
            .color = if (dim) t.text_muted else t.text_strong,
        });
    }
    if (l.err.h > 0) p.text(d.err, f.get(.prose), l.err, t.danger);

    if (d.state != .asking) {
        const s = l.status;
        var text_x = s.x;
        if (d.state == .waiting) {
            paintSpinner(ui, p, s.x + ui.px(8), s.y + ui.px(status_height) / 2, v.spinner);
            text_x += ui.px(24);
        }
        const text: Rect = .{ .x = text_x, .y = s.y, .w = s.right() - text_x, .h = s.h };
        const color = if (d.state == .failed) t.danger else t.text;
        if (s.h > ui.px(status_height)) {
            p.text(d.status, f.get(.prose), text, color);
        } else {
            p.text(d.status, f.get(.body), text, color);
        }
    }

    for (l.buttons[0..l.button_count], l.buttonSlice(), 0..) |br, b, n| {
        const focused = std.meta.eql(d.focus, Dialog.Focus{ .button = n });
        if (focused) ui.paintGlow(p, br, ui.px(6), if (b.style == .danger) t.danger else t.accent);
        paintButton(ui, p, br, b, ui.buttonState(.{ .target = .{ .dialog = @intCast(n) }, .part = .button }), focused);
    }
}

/// `focused` gives a button with no edge of its own a crisp one.
fn paintButton(ui: *const Ui, p: *Painter, r: Rect, b: Dialog.Button, state: Ui.ButtonState, focused: bool) void {
    const t = &ui.theme;
    const rad = ui.px(6);
    const lit = state != .rest and !b.disabled;
    switch (b.style) {
        .primary => {
            const bg = if (b.disabled) withAlpha(t.accent, 0.4) else if (lit) t.accent_hover else t.accent;
            p.fillRounded(r, rad, bg);
            p.text(b.label, ui.fonts.get(.button_strong), r, if (b.disabled) withAlpha(t.on_accent, 0.6) else t.on_accent);
        },
        .normal => {
            const bg = if (lit) t.surface_hover else t.surface;
            if (focused) ui.fillBordered(p, r, rad, bg, t.accent) else p.fillRounded(r, rad, bg);
            p.text(b.label, ui.fonts.get(.button), r, t.text);
        },
        .danger => {
            const bg = if (lit) mix(t.dialog, t.danger, 0.12) else t.dialog;
            ui.fillBordered(p, r, rad, bg, if (focused) t.danger else mix(t.dialog, t.danger, 0.55));
            p.text(b.label, ui.fonts.get(.button), r, t.danger);
        },
    }
}

/// Eight dots around a circle, the brightest moving clockwise a step at
/// a time.
fn paintSpinner(ui: *const Ui, p: *Painter, cx: f32, cy: f32, step: u32) void {
    const n = 8;
    const ring = ui.px(6);
    for (0..n) |k| {
        const angle = @as(f32, @floatFromInt(k)) * std.math.tau / n - std.math.pi / 2.0;
        // How many steps behind the brightest this dot is.
        const behind = (step + n - @as(u32, @intCast(k))) % n;
        const alpha = 1.0 - @as(f32, @floatFromInt(behind)) / n;
        p.dot(cx + ring * @cos(angle), cy + ring * @sin(angle), ui.px(1.6), withAlpha(ui.theme.accent, alpha));
    }
}

test "a dialog's buttons and fields are hit, and the rest is scrim" {
    const ui: Ui = .{ .scale = 1, .fonts = .none, .theme = undefined };
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var d: Dialog = .{ .icon = .lock, .title = L("Sign in") };
    d.addField(L("Password:"), false);
    d.addButton(.{ .label = L("Cancel"), .action = .cancel });
    d.addButton(.{ .label = L("Sign in"), .action = .accept, .style = .primary });
    const area: Rect = .{ .x = 240, .y = 36, .w = 760, .h = 564 };
    const node: Node = .{ .id = Id.window(.scrim), .kind = .{ .dialog = .{ .dialog = &d, .caret = false, .spinner = 0, .terminal_bg = undefined } }, .rect = area };
    const l = layoutIn(&ui, area, &d);
    // Centered in the area, as wide as a dialog is.
    try std.testing.expectEqual(@as(f32, 400), l.box.w);
    try std.testing.expectEqual(area.x + 180, l.box.x);
    try std.testing.expect(l.box.y >= area.y + 24);
    const field = l.fields[0].box;
    try std.testing.expectEqual(Id{ .target = .{ .dialog = 0 }, .part = .field }, hitTest(&ui, &node, field.x + 1, field.y + 1).?);
    const second = l.buttons[1];
    try std.testing.expectEqual(Id{ .target = .{ .dialog = 1 }, .part = .button }, hitTest(&ui, &node, second.x + 1, second.y + 1).?);
    try std.testing.expectEqual(Id.window(.scrim), hitTest(&ui, &node, area.x + 1, area.y + 1).?);
    // Waiting, the field is gone and the pressed button is disabled.
    d.state = .waiting;
    const waiting = layoutIn(&ui, area, &d);
    try std.testing.expectEqual(Id.window(.scrim), hitTest(&ui, &node, field.x + 1, field.y + 1).?);
    try std.testing.expectEqual(Id.window(.scrim), hitTest(&ui, &node, waiting.buttons[1].x + 1, waiting.buttons[1].y + 1).?);
    try std.testing.expectEqual(Id{ .target = .{ .dialog = 0 }, .part = .button }, hitTest(&ui, &node, waiting.buttons[0].x + 1, waiting.buttons[0].y + 1).?);
}
