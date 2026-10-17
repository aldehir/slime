//! A modal dialog over a session's terminal: a title, body text, an
//! optional monospace box, text fields, a status line, and buttons. It
//! asks, waits while what was answered is worked on, and can end in a
//! failure with only Close left. The window owns one per session that
//! needs it and feeds it input; `modal.zig` lays it out and draws it.
const Dialog = @This();

const std = @import("std");
const TextField = @import("TextField.zig");

pub const max_fields = 8;
pub const max_buttons = 3;

pub const Icon = enum { lock, key, unknown_host, warning };

pub const State = enum {
    /// Waiting for the user.
    asking,
    /// Answered; waiting on what the answer started. Fields are
    /// disabled and a spinner shows with the status.
    waiting,
    /// It didn't work: the status says why, and Close is left.
    failed,
};

pub const Action = enum { accept, skip, cancel, close };

pub const Focus = union(enum) {
    none,
    field: usize,
    /// An index into `buttons`.
    button: usize,
};

pub const Button = struct {
    label: []const u16,
    action: Action,
    style: Style = .normal,
    disabled: bool = false,

    pub const Style = enum { normal, primary, danger };
};

pub const Field = struct {
    /// Shown above the label: a keyboard-interactive prompt's lines
    /// before its last.
    above: []const u16 = &.{},
    label: []const u16,
    echo: bool,
    edit: TextField = .{},
};

icon: Icon,
/// Draws the icon, title, and outline in the danger color.
danger: bool = false,
/// Wider, for long prompts and fingerprints.
wide: bool = false,
title: []const u16,
text: []const u16 = &.{},
detail: []const u16 = &.{},
/// Why the last answer didn't work.
err: []const u16 = &.{},
fields: [max_fields]Field = undefined,
field_count: usize = 0,
/// For `asking`; `waiting` and `failed` have their own.
asking_buttons: [max_buttons]Button = undefined,
asking_button_count: usize = 0,
/// What has the keyboard: Tab moves it through the fields and the
/// buttons.
focus: Focus = .none,
state: State = .asking,
status: []const u16 = &.{},

pub fn constFields(self: *const Dialog) []const Field {
    return self.fields[0..self.field_count];
}

pub fn addField(self: *Dialog, label: []const u16, echo: bool) void {
    if (self.field_count == max_fields) return;
    // The last line names the field; the rest go above it.
    const trimmed = std.mem.trimEnd(u16, label, &.{ ' ', '\t', '\r', '\n' });
    const nl = std.mem.lastIndexOfScalar(u16, trimmed, '\n');
    self.fields[self.field_count] = .{
        .above = if (nl) |i| std.mem.trimEnd(u16, trimmed[0..i], &.{ ' ', '\r', '\n' }) else &.{},
        .label = if (nl) |i| trimmed[i + 1 ..] else trimmed,
        .echo = echo,
    };
    self.field_count += 1;
}

pub fn addButton(self: *Dialog, button: Button) void {
    if (self.asking_button_count == max_buttons) return;
    self.asking_buttons[self.asking_button_count] = button;
    self.asking_button_count += 1;
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// The buttons for the current state, left to right, in `buf`.
pub fn buttons(self: *const Dialog, buf: *[max_buttons]Button) []const Button {
    switch (self.state) {
        .asking => {
            @memcpy(buf[0..self.asking_button_count], self.asking_buttons[0..self.asking_button_count]);
            return buf[0..self.asking_button_count];
        },
        .waiting => {
            buf[0] = .{ .label = L("Cancel"), .action = .cancel };
            // The button that was pressed, until something comes back.
            for (self.asking_buttons[0..self.asking_button_count]) |b| {
                if (b.style == .primary and b.action != .cancel) {
                    buf[1] = b;
                    buf[1].disabled = true;
                    return buf[0..2];
                }
            }
            return buf[0..1];
        },
        .failed => {
            buf[0] = .{ .label = L("Close"), .action = .close, .style = .primary };
            return buf[0..1];
        },
    }
}

/// Enter's button: the primary one.
pub fn defaultAction(self: *const Dialog) ?Action {
    var buf: [max_buttons]Button = undefined;
    for (self.buttons(&buf)) |b| {
        if (b.style == .primary and !b.disabled) return b.action;
    }
    return null;
}

/// Enter's button: the focused one, else the primary one.
pub fn enterAction(self: *const Dialog) ?Action {
    if (self.focusedButton()) |b| return b.action;
    return self.defaultAction();
}

/// The focused button, if it can be pressed.
pub fn focusedButton(self: *const Dialog) ?Button {
    const i = switch (self.focus) {
        .button => |i| i,
        else => return null,
    };
    var buf: [max_buttons]Button = undefined;
    const bs = self.buttons(&buf);
    if (i >= bs.len or bs[i].disabled) return null;
    return bs[i];
}

/// Escape's button.
pub fn escapeAction(self: *const Dialog) Action {
    return if (self.state == .failed) .close else .cancel;
}

/// The field with the keyboard, while the dialog asks.
pub fn focused(self: *Dialog) ?*TextField {
    if (self.state != .asking) return null;
    return switch (self.focus) {
        .field => |i| if (i < self.field_count) &self.fields[i].edit else null,
        else => null,
    };
}

/// Move the keyboard to the next field or button, or back: the fields
/// while asking, then the buttons that can be pressed, around again.
pub fn cycleFocus(self: *Dialog, forward: bool) void {
    var order: [max_fields + max_buttons]Focus = undefined;
    var n: usize = 0;
    if (self.state == .asking) {
        for (0..self.field_count) |i| {
            order[n] = .{ .field = i };
            n += 1;
        }
    }
    var buf: [max_buttons]Button = undefined;
    for (self.buttons(&buf), 0..) |b, i| {
        if (b.disabled) continue;
        order[n] = .{ .button = i };
        n += 1;
    }
    if (n == 0) return;
    const at = for (order[0..n], 0..) |f, i| {
        if (std.meta.eql(f, self.focus)) break i;
    } else null;
    const next = if (at) |i|
        (if (forward) (i + 1) % n else (i + n - 1) % n)
    else if (forward) 0 else n - 1;
    self.focus = order[next];
}

test "fields split a multi-line label" {
    var d: Dialog = .{ .icon = .lock, .title = L("t") };
    d.addField(L("Duo two-factor login\n\n 1. Push\n\nPasscode or option (1-1): "), true);
    const f = d.constFields()[0];
    try std.testing.expectEqualSlices(u16, L("Passcode or option (1-1):"), f.label);
    try std.testing.expectEqualSlices(u16, L("Duo two-factor login\n\n 1. Push"), f.above);
    d.addField(L("alde@devbox's password: "), false);
    try std.testing.expectEqualSlices(u16, L("alde@devbox's password:"), d.constFields()[1].label);
    try std.testing.expectEqual(@as(usize, 0), d.constFields()[1].above.len);
}

test "buttons follow the state" {
    var d: Dialog = .{ .icon = .lock, .title = L("t") };
    d.addButton(.{ .label = L("Cancel"), .action = .cancel });
    d.addButton(.{ .label = L("Sign in"), .action = .accept, .style = .primary });
    var buf: [max_buttons]Button = undefined;
    try std.testing.expectEqual(@as(usize, 2), d.buttons(&buf).len);
    try std.testing.expectEqual(Dialog.Action.accept, d.defaultAction().?);

    // Tab goes through the field, then the buttons, and around.
    d.addField(L("pw: "), false);
    d.focus = .{ .field = 0 };
    d.cycleFocus(true);
    try std.testing.expectEqual(Focus{ .button = 0 }, d.focus);
    try std.testing.expectEqual(Action.cancel, d.enterAction().?);
    d.cycleFocus(true);
    d.cycleFocus(true);
    try std.testing.expectEqual(Focus{ .field = 0 }, d.focus);
    d.cycleFocus(false);
    try std.testing.expectEqual(Focus{ .button = 1 }, d.focus);

    d.state = .waiting;
    // Only Cancel can be pressed, and no field.
    d.focus = .none;
    d.cycleFocus(true);
    try std.testing.expectEqual(Focus{ .button = 0 }, d.focus);
    d.cycleFocus(true);
    try std.testing.expectEqual(Focus{ .button = 0 }, d.focus);
    try std.testing.expectEqual(@as(?*TextField, null), d.focused());
    const waiting = d.buttons(&buf);
    try std.testing.expect(waiting[1].disabled);
    try std.testing.expectEqual(@as(?Action, null), d.defaultAction());
    try std.testing.expectEqual(Action.cancel, d.escapeAction());

    d.state = .failed;
    try std.testing.expectEqual(Action.close, d.defaultAction().?);
    try std.testing.expectEqual(Action.close, d.escapeAction());
}
