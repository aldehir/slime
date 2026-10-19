//! A one-line text box's contents and editing: a caret, a selection
//! from `anchor` to `caret`, and the keys Windows edit controls take.
//! `Ui` draws it; the app feeds it keys, characters and the clipboard.
const TextField = @This();

const std = @import("std");

/// Room for a long URL in a browser pane's URL bar.
pub const max_len = 2048;

buf: [max_len]u16 = undefined,
len: usize = 0,
/// In UTF-16 units, never inside a surrogate pair.
caret: usize = 0,
/// The selection's other end; equal to `caret` for none.
anchor: usize = 0,
/// Units dropped from typed and pasted text.
reject: []const u16 = &.{},

pub fn text(self: *const TextField) []const u16 {
    return self.buf[0..self.len];
}

pub const Range = struct { start: usize, end: usize };

pub fn selection(self: *const TextField) Range {
    return .{ .start = @min(self.caret, self.anchor), .end = @max(self.caret, self.anchor) };
}

pub fn selected(self: *const TextField) []const u16 {
    const r = self.selection();
    return self.buf[r.start..r.end];
}

/// Replace the selection with `units`, without control characters,
/// line breaks, or `reject`ed units, and as much as fits.
pub fn insert(self: *TextField, units: []const u16) void {
    self.deleteSelection();
    for (units) |u| {
        if (u < 0x20 or u == 0x7f or std.mem.indexOfScalar(u16, self.reject, u) != null) continue;
        if (self.len == max_len) break;
        std.mem.copyBackwards(u16, self.buf[self.caret + 1 .. self.len + 1], self.buf[self.caret..self.len]);
        self.buf[self.caret] = u;
        self.len += 1;
        self.caret += 1;
    }
    self.anchor = self.caret;
}

pub const Key = enum { left, right, home, end, backspace, delete, select_all };

/// Edit or move for `key`. `word` moves by words (ctrl), and `extend`
/// moves the caret without the anchor (shift).
pub fn press(self: *TextField, key: Key, word: bool, extend: bool) void {
    switch (key) {
        .select_all => {
            self.anchor = 0;
            self.caret = self.len;
        },
        .left, .right, .home, .end => {
            const sel = self.selection();
            const to = switch (key) {
                // Without shift, an arrow first collapses a selection to
                // its side.
                .left => if (!extend and !word and sel.start != sel.end) sel.start else self.step(self.caret, false, word),
                .right => if (!extend and !word and sel.start != sel.end) sel.end else self.step(self.caret, true, word),
                .home => 0,
                .end => self.len,
                else => unreachable,
            };
            self.caret = to;
            if (!extend) self.anchor = to;
        },
        .backspace, .delete => {
            if (self.caret == self.anchor) self.anchor = self.step(self.caret, key == .delete, word);
            self.deleteSelection();
        },
    }
}

fn deleteSelection(self: *TextField) void {
    const r = self.selection();
    std.mem.copyForwards(u16, self.buf[r.start..], self.buf[r.end..self.len]);
    self.len -= r.end - r.start;
    self.caret = r.start;
    self.anchor = r.start;
}

/// Where the caret goes from `at` one character, or one word, forward
/// or back.
fn step(self: *const TextField, at: usize, forward: bool, word: bool) usize {
    var i = at;
    if (!word) return self.stepChar(i, forward);
    // Over separators, then a word, as edit controls do.
    if (forward) {
        while (i < self.len and !isWord(self.buf[i])) i += 1;
        while (i < self.len and isWord(self.buf[i])) i += 1;
    } else {
        while (i > 0 and !isWord(self.buf[i - 1])) i -= 1;
        while (i > 0 and isWord(self.buf[i - 1])) i -= 1;
    }
    return i;
}

fn stepChar(self: *const TextField, at: usize, forward: bool) usize {
    if (forward) {
        if (at >= self.len) return self.len;
        const pair = std.unicode.utf16IsHighSurrogate(self.buf[at]) and at + 1 < self.len and
            std.unicode.utf16IsLowSurrogate(self.buf[at + 1]);
        return at + @as(usize, if (pair) 2 else 1);
    }
    if (at == 0) return 0;
    const pair = at >= 2 and std.unicode.utf16IsLowSurrogate(self.buf[at - 1]) and
        std.unicode.utf16IsHighSurrogate(self.buf[at - 2]);
    return at - @as(usize, if (pair) 2 else 1);
}

/// Host names break into words at dots, `@`, `:` and the like.
fn isWord(u: u16) bool {
    return switch (u) {
        'a'...'z', 'A'...'Z', '0'...'9', '_' => true,
        else => u >= 0x80,
    };
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "typing, moving, and deleting" {
    var f: TextField = .{};
    f.insert(L("alde@host"));
    try std.testing.expectEqualSlices(u16, L("alde@host"), f.text());
    f.press(.left, true, false);
    try std.testing.expectEqual(@as(usize, 5), f.caret);
    f.press(.left, true, false);
    try std.testing.expectEqual(@as(usize, 0), f.caret);
    f.press(.delete, true, false);
    try std.testing.expectEqualSlices(u16, L("@host"), f.text());
    f.press(.end, false, false);
    f.press(.backspace, false, false);
    try std.testing.expectEqualSlices(u16, L("@hos"), f.text());
}

test "selection" {
    var f: TextField = .{};
    f.insert(L("devbox"));
    f.press(.left, false, true);
    f.press(.left, false, true);
    try std.testing.expectEqualSlices(u16, L("ox"), f.selected());
    // An arrow collapses it to its side.
    f.press(.left, false, false);
    try std.testing.expectEqual(@as(usize, 4), f.caret);
    f.press(.select_all, false, false);
    f.insert(L("pi"));
    try std.testing.expectEqualSlices(u16, L("pi"), f.text());
}

test "filters and surrogate pairs" {
    var f: TextField = .{ .reject = L(" \"") };
    f.insert(L("a b\r\n\"c\u{1F600}"));
    try std.testing.expectEqualSlices(u16, L("abc\u{1F600}"), f.text());
    f.press(.backspace, false, false);
    try std.testing.expectEqualSlices(u16, L("abc"), f.text());
}
