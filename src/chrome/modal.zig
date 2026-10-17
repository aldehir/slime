//! Lays out and draws a `Dialog` centered over the terminal area, which
//! a scrim dims: a raised, rounded box with a soft shadow. Layout is one
//! function, so drawing and hit testing agree.

const std = @import("std");
const Chrome = @import("Chrome.zig");
const Dialog = @import("Dialog.zig");
const Painter = @import("../renderer/Painter.zig");

const Rect = Chrome.Rect;
const Hit = Chrome.Hit;

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

pub fn layout(c: *const Chrome, area: Rect, d: *const Dialog) Layout {
    const f = &c.fonts;
    const w = @min(c.px(if (d.wide) wide_width else width), @max(0, area.w - c.px(32)));
    const inner_w = w - 2 * c.px(pad);
    const x = area.x + @round((area.w - w) / 2);
    const left = x + c.px(pad);

    // Stack everything from 0, then center the box.
    var y: f32 = c.px(pad);
    var l: Layout = .{ .box = .{}, .icon = .{}, .title = .{} };
    const title_h = c.px(title_height);
    const icon = c.px(icon_size);
    l.icon = .{ .x = left, .y = y + @round((title_h - icon) / 2), .w = icon, .h = icon };
    const title_x = left + icon + c.px(10);
    l.title = .{ .x = title_x, .y = y, .w = left + inner_w - title_x, .h = title_h };
    y += title_h;

    if (d.text.len > 0) {
        y += c.px(gap);
        l.text = .{ .x = left, .y = y, .w = inner_w, .h = f.measureHeight(d.text, f.prose, inner_w) };
        y += l.text.h;
    }
    if (d.detail.len > 0) {
        y += c.px(gap);
        const text_w = inner_w - 2 * c.px(detail_pad_x);
        const h = f.measureHeight(d.detail, f.mono_prose, text_w) + 2 * c.px(detail_pad_y);
        l.detail = .{ .x = left, .y = y, .w = inner_w, .h = h };
        y += h;
    }
    for (d.constFields(), 0..) |field, i| {
        y += c.px(gap);
        var above: Rect = .{ .x = left, .y = y, .w = inner_w, .h = 0 };
        if (field.above.len > 0) {
            above.h = f.measureHeight(field.above, f.prose, inner_w);
            y += above.h + c.px(label_gap);
        }
        const label: Rect = .{ .x = left, .y = y, .w = inner_w, .h = c.px(label_height) };
        y += label.h + c.px(label_gap);
        const box: Rect = .{ .x = left, .y = y, .w = inner_w, .h = c.px(field_height) };
        y += box.h;
        l.fields[i] = .{ .above = above, .label = label, .box = box };
    }
    if (d.err.len > 0 and d.state == .asking) {
        y += c.px(label_gap);
        l.err = .{ .x = left, .y = y, .w = inner_w, .h = f.measureHeight(d.err, f.prose, inner_w) };
        y += l.err.h;
    }
    if (d.state != .asking) {
        y += c.px(gap);
        const text_h = if (d.status.len > 0) f.measureHeight(d.status, f.prose, inner_w - c.px(24)) else 0;
        l.status = .{ .x = left, .y = y, .w = inner_w, .h = @max(c.px(status_height), text_h) };
        y += l.status.h;
    }

    const buttons = d.buttons(&l.button_list);
    l.button_count = buttons.len;
    y += c.px(gap) + c.px(2);
    var bx = left + inner_w;
    var i = buttons.len;
    while (i > 0) {
        i -= 1;
        const font = if (buttons[i].style == .primary) f.button_strong else f.button;
        const bw = @ceil(f.measure(buttons[i].label, font)) + 2 * c.px(button_pad_x);
        bx -= bw;
        l.buttons[i] = .{ .x = bx, .y = y, .w = bw, .h = c.px(button_height) };
        bx -= c.px(button_gap);
    }
    y += c.px(button_height) + c.px(pad_bottom);

    // Centered, but not above the area's top.
    const top = @max(area.y + c.px(24), area.y + @round((area.h - y) / 2));
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

/// Anything over the area is the dialog's: the terminal behind it takes
/// no clicks.
pub fn hitTest(c: *const Chrome, area: Rect, d: *const Dialog, x: f32, y: f32) Hit {
    const l = layout(c, area, d);
    for (l.buttons[0..l.button_count], l.buttonSlice(), 0..) |r, b, i| {
        if (r.contains(x, y) and !b.disabled) return .{ .dialog_button = i };
    }
    if (d.state == .asking) {
        for (l.fields[0..d.field_count], 0..) |fr, i| {
            if (fr.box.contains(x, y)) return .{ .dialog_field = i };
        }
    }
    return .dialog;
}

pub const PaintOptions = struct {
    /// The window has the keyboard, so the focused field's caret shows.
    focused: bool,
    caret_visible: bool,
    /// Steps of the spinner while waiting.
    spinner: u32,
    terminal_bg: Chrome.Color,
};

pub fn paint(c: *const Chrome, p: *Painter, area: Rect, d: *const Dialog, opts: PaintOptions) void {
    const t = &c.theme;
    const f = &c.fonts;
    p.fill(area, t.scrim);
    const l = layout(c, area, d);
    const r = l.box;

    c.paintShadow(p, r, c.px(radius), 4, 1.5);
    const edge = if (d.danger) mixColor(t.dialog_outline, t.danger, 0.35) else t.dialog_outline;
    c.fillBordered(p, r, c.px(radius), t.dialog, edge);

    const accent = if (d.danger) t.danger else t.accent;
    c.drawIcon(p, switch (d.icon) {
        .lock => .lock,
        .key => .key_round,
        .unknown_host => .shield_question_mark,
        .warning => .shield_alert,
    }, l.icon, accent);
    p.text(d.title, f.heading, l.title, if (d.danger) t.danger else t.text_strong);

    const dim = d.state != .asking;
    if (d.text.len > 0) p.text(d.text, f.prose, l.text, if (dim) t.text_muted else t.text);
    if (d.detail.len > 0) {
        p.fillRounded(l.detail, c.px(6), opts.terminal_bg);
        p.text(d.detail, f.mono_prose, l.detail.inset(c.px(detail_pad_x), c.px(detail_pad_y)), t.text_strong);
    }

    for (d.constFields(), l.fields[0..d.field_count], 0..) |*field, fr, n| {
        if (field.above.len > 0) p.text(field.above, f.prose, fr.above, if (dim) t.text_muted else t.text);
        p.text(field.label, f.body, fr.label, if (dim) t.text_muted else t.text);
        const focused = !dim and std.meta.eql(d.focus, Dialog.Focus{ .field = n });
        const box = fr.box;
        if (focused) paintGlow(c, p, box, c.px(6), t.accent);
        c.fillBordered(p, box, c.px(6), if (dim) opts.terminal_bg else t.ground, if (focused) t.accent else t.outline);
        c.paintEditText(p, box.inset(c.px(10), 0), &field.edit, .{
            .caret = focused and opts.focused and opts.caret_visible,
            .mask = !field.echo,
            .color = if (dim) t.text_muted else t.text_strong,
        });
    }
    if (l.err.h > 0) p.text(d.err, f.prose, l.err, t.danger);

    if (d.state != .asking) {
        const s = l.status;
        var text_x = s.x;
        if (d.state == .waiting) {
            paintSpinner(c, p, s.x + c.px(8), s.y + c.px(status_height) / 2, opts.spinner);
            text_x += c.px(24);
        }
        const text: Rect = .{ .x = text_x, .y = s.y, .w = s.right() - text_x, .h = s.h };
        const color = if (d.state == .failed) t.danger else t.text;
        if (s.h > c.px(status_height)) {
            p.text(d.status, f.prose, text, color);
        } else {
            p.text(d.status, f.body, text, color);
        }
    }

    for (l.buttons[0..l.button_count], l.buttonSlice(), 0..) |br, b, n| {
        const focused = std.meta.eql(d.focus, Dialog.Focus{ .button = n });
        if (focused) paintGlow(c, p, br, c.px(6), if (b.style == .danger) t.danger else t.accent);
        paintButton(c, p, br, b, c.buttonState(.{ .dialog_button = n }), focused);
    }
}

/// A glow around `r`, for what has the keyboard, drawn before it: faint
/// fills a pixel apart, which add up to a fade outward.
fn paintGlow(c: *const Chrome, p: *Painter, r: Rect, rad: f32, color: Chrome.Color) void {
    const w = c.stroke();
    var k: f32 = 4;
    while (k > 0) : (k -= 1) {
        p.fillRounded(r.inset(-k * w, -k * w), rad + k * w, withAlpha(color, 0.09));
    }
}

/// `focused` gives a button with no edge of its own a crisp one.
fn paintButton(c: *const Chrome, p: *Painter, r: Rect, b: Dialog.Button, state: Chrome.ButtonState, focused: bool) void {
    const t = &c.theme;
    const rad = c.px(6);
    const lit = state != .rest and !b.disabled;
    switch (b.style) {
        .primary => {
            const bg = if (b.disabled) withAlpha(t.accent, 0.4) else if (lit) t.accent_hover else t.accent;
            p.fillRounded(r, rad, bg);
            p.text(b.label, c.fonts.button_strong, r, if (b.disabled) withAlpha(t.on_accent, 0.6) else t.on_accent);
        },
        .normal => {
            const bg = if (lit) t.surface_hover else t.surface;
            if (focused) c.fillBordered(p, r, rad, bg, t.accent) else p.fillRounded(r, rad, bg);
            p.text(b.label, c.fonts.button, r, t.text);
        },
        .danger => {
            const bg = if (lit) mixColor(t.dialog, t.danger, 0.12) else t.dialog;
            c.fillBordered(p, r, rad, bg, if (focused) t.danger else mixColor(t.dialog, t.danger, 0.55));
            p.text(b.label, c.fonts.button, r, t.danger);
        },
    }
}

/// Eight dots around a circle, the brightest moving clockwise a step at
/// a time.
fn paintSpinner(c: *const Chrome, p: *Painter, cx: f32, cy: f32, step: u32) void {
    const n = 8;
    const ring = c.px(6);
    for (0..n) |k| {
        const angle = @as(f32, @floatFromInt(k)) * std.math.tau / n - std.math.pi / 2.0;
        // How many steps behind the brightest this dot is.
        const behind = (step + n - @as(u32, @intCast(k))) % n;
        const alpha = 1.0 - @as(f32, @floatFromInt(behind)) / n;
        p.dot(cx + ring * @cos(angle), cy + ring * @sin(angle), c.px(1.6), withAlpha(c.theme.accent, alpha));
    }
}

fn withAlpha(color: Chrome.Color, a: f32) Chrome.Color {
    return .{ color[0], color[1], color[2], color[3] * a };
}

fn mixColor(a: Chrome.Color, b: Chrome.Color, t: f32) Chrome.Color {
    var out: Chrome.Color = undefined;
    for (&out, a, b) |*o, x, y| o.* = x + (y - x) * t;
    return out;
}
