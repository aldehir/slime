//! Text: a `label`, one line in one of the UI's formats, and
//! `lines`, several one under another, as the frame stats are.

const std = @import("std");
const Ui = @import("../Ui.zig");
const Painter = @import("../../renderer/Painter.zig");

const Node = Ui.Node;
const Size = Ui.Size;
const Rect = Ui.Rect;

pub fn measure(ui: *const Ui, node: *const Node) Size {
    switch (node.kind) {
        .label => |l| {
            const width = l.width orelse return .{};
            return .{ .w = switch (width) {
                .dip => |dip| ui.px(dip),
                .fit => |extra| @ceil(ui.fonts.measure(l.text, ui.fonts.get(l.font))) + ui.px(extra),
            } };
        },
        .lines => |l| {
            const n: f32 = @floatFromInt(std.mem.countScalar(u16, l.text, '\n') + 1);
            return .{ .h = n * ui.px(l.line_height) };
        },
        else => return .{},
    }
}

pub fn paint(ui: *const Ui, p: *Painter, node: *const Node) void {
    switch (node.kind) {
        .label => |l| {
            const r = node.rect.inset(ui.px(l.pad_x), 0);
            var buf: [256]u16 = undefined;
            p.text(if (l.upper) upper(&buf, l.text) else l.text, ui.fonts.get(l.font), r, l.color);
        },
        .lines => |l| {
            const line_h = ui.px(l.line_height);
            var r: Rect = .{ .x = node.rect.x, .y = node.rect.y, .w = node.rect.w, .h = line_h };
            var it = std.mem.splitScalar(u16, l.text, '\n');
            while (it.next()) |line| : (r.y += line_h) p.text(line, ui.fonts.get(l.font), r, l.color);
        },
        else => {},
    }
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

test upper {
    var buf: [8]u16 = undefined;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, L("DEV1.CAS"), upper(&buf, L("dev1.casa")));
}
