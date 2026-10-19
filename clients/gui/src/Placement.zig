//! Where a tab's panes are on screen, from the window's last layout: each
//! pane's frame (its title strip and terminal), its terminal under the
//! strip, the space around the grid in that, and the grid that fits; and
//! the dividers between panes. Made from the tab's tree (`Tab.place`) and
//! the terminal area, and remade whenever either changes, so nothing here
//! outlives a layout: the window draws, hit-tests, and drags against it,
//! and the sessions themselves hold no geometry.
const Placement = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const Tab = @import("Tab.zig");
const Daemon = @import("Daemon.zig");
const Rect = @import("renderer/Painter.zig").Rect;

/// The panes shown, in layout order.
panes: std.ArrayList(Pane) = .empty,
/// Between them, in the order `Tab.place` meets them.
dividers: std.ArrayList(Tab.Divider) = .empty,
/// Where dividers meet, dragged to move all of them at once.
corners: std.ArrayList(Corner) = .empty,

/// Pixels around a grid, inside its terminal.
pub const Padding = struct { left: u32 = 0, right: u32 = 0, top: u32 = 0, bottom: u32 = 0 };

pub const Pane = struct {
    session: *Session,
    /// All of it: its title strip and terminal.
    frame: Rect,
    /// Its terminal, under the strip. Filled in after `Tab.place`, with
    /// the rest.
    rect: Rect = .{},
    /// The space around the grid in `rect`: the configured padding, plus
    /// what's left over of a cell at the right and bottom.
    pad: Padding = .{},
    /// The grid that fits.
    cols: u16 = 0,
    rows: u16 = 0,
};

/// A junction of dividers: one passing through it and one ending at
/// it, or two where dividers on both sides of the first line up.
pub const Corner = struct {
    /// Twice the gap square, centered on the junction.
    rect: Rect,
    /// Indices into `dividers`.
    through: u16,
    ends: [2]?u16,
};

pub fn deinit(self: *Placement, alloc: Allocator) void {
    self.panes.deinit(alloc);
    self.dividers.deinit(alloc);
    self.corners.deinit(alloc);
    self.* = undefined;
}

pub fn clear(self: *Placement) void {
    self.panes.clearRetainingCapacity();
    self.dividers.clearRetainingCapacity();
    self.corners.clearRetainingCapacity();
}

/// Find the corners among the dividers: each end of a divider that
/// meets one across it. A divider spans its split, so the one it ends
/// at is an ancestor split's, and the ends from both sides of it only
/// line up by chance.
pub fn findCorners(self: *Placement, alloc: Allocator, gap: f32) !void {
    const ds = self.dividers.items;
    for (ds, 0..) |d, i| {
        const vertical = d.axis() == .row;
        for (ds, 0..) |e, j| {
            if (e.axis() == d.axis()) continue;
            // d runs between e's long sides, and an end of it touches e.
            const within = if (vertical)
                d.rect.x >= e.rect.x and d.rect.right() <= e.rect.right()
            else
                d.rect.y >= e.rect.y and d.rect.bottom() <= e.rect.bottom();
            if (!within) continue;
            const touches = if (vertical)
                near(d.rect.y, e.rect.bottom()) or near(d.rect.bottom(), e.rect.y)
            else
                near(d.rect.x, e.rect.right()) or near(d.rect.right(), e.rect.x);
            if (!touches) continue;
            const cx = if (vertical) d.rect.x + d.rect.w / 2 else e.rect.x + e.rect.w / 2;
            const cy = if (vertical) e.rect.y + e.rect.h / 2 else d.rect.y + d.rect.h / 2;
            const rect: Rect = .{ .x = cx - gap, .y = cy - gap, .w = 2 * gap, .h = 2 * gap };
            // The end from the other side of e, if it got here first.
            for (self.corners.items) |*c| {
                if (c.through == j and near(c.rect.x, rect.x) and near(c.rect.y, rect.y)) {
                    c.ends[1] = @intCast(i);
                    break;
                }
            } else try self.corners.append(alloc, .{ .rect = rect, .through = @intCast(j), .ends = .{ @intCast(i), null } });
        }
    }
}

fn near(a: f32, b: f32) bool {
    return @abs(a - b) < 0.5;
}

/// Where `s` is, if it's shown.
pub fn find(self: *const Placement, s: *const Session) ?*const Pane {
    for (self.panes.items) |*p| {
        if (p.session == s) return p;
    }
    return null;
}

/// The pane at a client position, if one's there.
pub fn at(self: *const Placement, x: f32, y: f32) ?*const Pane {
    for (self.panes.items) |*p| {
        if (p.frame.contains(x, y)) return p;
    }
    return null;
}

/// The pane next to `from` on `side`: of those past that edge and level
/// with it, the nearest, then the one most in line with it.
pub fn neighbor(self: *const Placement, from: *const Session, side: Daemon.Direction) ?*Session {
    const f = (self.find(from) orelse return null).frame;
    const along = side == .left or side == .right;
    var best: ?*Session = null;
    var best_gap: f32 = 0;
    var best_off: f32 = 0;
    for (self.panes.items) |p| {
        if (p.session == from) continue;
        const r = p.frame;
        const gap = switch (side) {
            .left => f.x - r.right(),
            .right => r.x - f.right(),
            .up => f.y - r.bottom(),
            .down => r.y - f.bottom(),
        };
        if (gap < 0) continue;
        const level = if (along)
            @min(f.bottom(), r.bottom()) - @max(f.y, r.y)
        else
            @min(f.right(), r.right()) - @max(f.x, r.x);
        if (level <= 0) continue;
        const off = if (along) @abs((r.y + r.h / 2) - (f.y + f.h / 2)) else @abs((r.x + r.w / 2) - (f.x + f.w / 2));
        if (best == null or gap < best_gap or (gap == best_gap and off < best_off)) {
            best = p.session;
            best_gap = gap;
            best_off = off;
        }
    }
    return best;
}
