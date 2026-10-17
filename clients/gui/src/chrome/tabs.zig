//! Sessions as tabs in the title bar, what the sidebar toggles to. The
//! tabs aren't drawn yet (see deferred.md): for now this is the title bar
//! alone over a full-width terminal.

const Chrome = @import("Chrome.zig");
const Painter = @import("../renderer/Painter.zig");

pub const titlebar_height = 40;

pub fn layout(_: *const Chrome, l: *Chrome.Layout) void {
    const top = l.titlebar.bottom();
    l.terminal = .{ .y = top, .w = l.window.w, .h = @max(0, l.window.h - top) };
}

pub fn hitTest(_: *const Chrome, _: *const Chrome.Layout, _: *const Chrome.View, _: f32, _: f32) ?Chrome.Hit {
    return null;
}

pub fn buttonRect(_: *const Chrome, _: *const Chrome.Layout, _: *const Chrome.View, _: Chrome.Hit) ?Chrome.Rect {
    return null;
}

pub fn paint(c: *const Chrome, p: *Painter, l: *const Chrome.Layout, view: *const Chrome.View) void {
    c.paintTitle(p, l, view);
}
