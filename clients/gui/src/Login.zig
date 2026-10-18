//! Logging in to an SSH host as the stand-in session's dialog shows it:
//! the daemon's prompts and status lines (`Daemon.HostEvent`) turned into
//! a `Dialog` for the user to answer, waiting while the server works on
//! an answer, and failing with the reason if logging in doesn't work.
const Login = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Daemon = @import("Daemon.zig");
const Dialog = @import("ui/Dialog.zig");

const L = std.unicode.utf8ToUtf16LeStringLiteral;

alloc: Allocator,
/// The host, for titles and "Waiting for". Borrowed from the window's
/// host table, which outlives it.
host: []const u16,
/// The prompt shown, which the dialog's strings point into.
prompt: ?*Daemon.Prompt = null,
dialog: Dialog,
status_buf: [512]u16 = undefined,
title_buf: [160]u16 = undefined,

/// A login with nothing asked yet: waiting, with a Cancel button.
pub fn create(alloc: Allocator, host: []const u16) !*Login {
    const self = try alloc.create(Login);
    self.* = .{ .alloc = alloc, .host = host, .dialog = undefined };
    self.dialog = .{ .icon = .lock, .title = self.signInTitle(), .state = .waiting };
    self.setStatus(&.{ L("Waiting for "), host, L("\u{2026}") });
    return self;
}

pub fn destroy(self: *Login) void {
    if (self.prompt) |p| p.destroy();
    self.alloc.destroy(self);
}

/// Show `prompt`, which the login now owns.
pub fn ask(self: *Login, prompt: *Daemon.Prompt) void {
    const old = self.prompt;
    self.prompt = prompt;
    var d: Dialog = .{
        .icon = .lock,
        .title = if (prompt.title.len > 0) prompt.title else self.signInTitle(),
        .text = prompt.text,
        .detail = prompt.detail,
        .err = prompt.err,
    };
    const cancel: Dialog.Button = .{ .label = L("Cancel"), .action = .cancel };
    switch (prompt.kind) {
        .password => {
            d.addButton(cancel);
            d.addButton(.{ .label = L("Sign in"), .action = .accept, .style = .primary });
        },
        .passphrase => {
            d.icon = .key;
            d.addButton(cancel);
            d.addButton(.{ .label = L("Skip key"), .action = .skip });
            d.addButton(.{ .label = L("Unlock"), .action = .accept, .style = .primary });
        },
        .unknown_host => {
            d.icon = .unknown_host;
            d.wide = true;
            d.addButton(cancel);
            d.addButton(.{ .label = L("Trust and connect"), .action = .accept, .style = .primary });
        },
        .changed_host => {
            d.icon = .warning;
            d.danger = true;
            d.wide = true;
            // Close is Enter's: connecting anyway takes a click.
            d.addButton(.{ .label = L("Connect anyway"), .action = .accept, .style = .danger });
            d.addButton(.{ .label = L("Close"), .action = .cancel, .style = .primary });
        },
        .interactive, _ => {
            d.wide = true;
            d.addButton(cancel);
            d.addButton(.{ .label = L("Continue"), .action = .accept, .style = .primary });
        },
    }
    for (prompt.questions) |q| d.addField(q.label, q.echo);
    if (d.field_count > 0) d.focus = .{ .field = 0 };
    self.dialog = d;
    if (old) |o| o.destroy();
}

/// A status line while waiting: the server's, or the daemon's
/// ("installing slime").
pub fn info(self: *Login, text: []const u16) void {
    self.setStatus(&.{text});
}

/// The user answered: wait for what comes back.
pub fn answered(self: *Login) void {
    self.dialog.state = .waiting;
    self.dialog.focus = .none;
    self.setStatus(&.{ L("Waiting for "), self.host, L("\u{2026}") });
}

/// Logging in failed for `why`.
pub fn fail(self: *Login, why: []const u8) void {
    self.dialog.state = .failed;
    self.dialog.focus = .none;
    if (why.len == 0) return;
    var buf: [256]u16 = undefined;
    const n = std.unicode.utf8ToUtf16Le(&buf, why[0..@min(why.len, buf.len)]) catch 0;
    self.setStatus(&.{buf[0..n]});
}

/// The fields' text, one answer per question, in `buf`.
pub fn answers(self: *const Login, buf: *[Dialog.max_fields][]const u16) []const []const u16 {
    const fields = self.dialog.constFields();
    for (fields, 0..) |*f, i| buf[i] = f.edit.text();
    return buf[0..fields.len];
}

fn signInTitle(self: *Login) []const u16 {
    return self.join(&self.title_buf, &.{ L("Sign in to "), self.host });
}

fn setStatus(self: *Login, parts: []const []const u16) void {
    self.dialog.status = self.join(&self.status_buf, parts);
}

fn join(_: *Login, buf: []u16, parts: []const []const u16) []const u16 {
    var n: usize = 0;
    for (parts) |part| {
        const k = @min(part.len, buf.len - n);
        @memcpy(buf[n..][0..k], part[0..k]);
        n += k;
    }
    return buf[0..n];
}
