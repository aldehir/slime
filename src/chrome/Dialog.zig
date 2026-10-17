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
/// The field with the keyboard.
focus: usize = 0,
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

/// Escape's button.
pub fn escapeAction(self: *const Dialog) Action {
    return if (self.state == .failed) .close else .cancel;
}

/// The field with the keyboard, while the dialog asks.
pub fn focused(self: *Dialog) ?*TextField {
    if (self.state != .asking or self.focus >= self.field_count) return null;
    return &self.fields[self.focus].edit;
}

/// Move the keyboard to the next field, or back.
pub fn cycleFocus(self: *Dialog, forward: bool) void {
    const n = self.field_count;
    if (n == 0) return;
    self.focus = if (forward) (self.focus + 1) % n else (self.focus + n - 1) % n;
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

    d.state = .waiting;
    const waiting = d.buttons(&buf);
    try std.testing.expect(waiting[1].disabled);
    try std.testing.expectEqual(@as(?Action, null), d.defaultAction());
    try std.testing.expectEqual(Action.cancel, d.escapeAction());

    d.state = .failed;
    try std.testing.expectEqual(Action.close, d.defaultAction().?);
    try std.testing.expectEqual(Action.close, d.escapeAction());
}
