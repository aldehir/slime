//! A row of the sidebar: one or more panes (sessions) laid out in a tree,
//! as slimed keeps them (ssh/internal/persist/layout.go). Splits share
//! their space between children by basis points, along a row or down a
//! column; a tab's panes and the dividers between them tile its area.
//!
//! slimed owns a split tab's layout: the window asks it to split or close
//! panes and takes the tree it sends back (`fromLayout`). A session that
//! doesn't run in slimed is a tab of its own, one pane. Each slimed, the
//! local one or a host's, numbers its own tabs.
const Tab = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const Slimed = @import("Slimed.zig");
const Rect = @import("renderer/Painter.zig").Rect;

/// slimed's id for the tab, or 0 for a session of its own.
id: u32,
/// The slimed whose tab it is, or null for a session of its own.
conn: ?*Slimed = null,
root: Node,
/// The pane that gets the keys.
focus: *Session,
/// The pane filling the tab while it's zoomed. The others keep their
/// sizes, out of sight.
zoom: ?*Session = null,
/// Its panes aren't listed under it in the sidebar.
folded: bool = false,
/// Between panes, from the last `place`.
dividers: std.ArrayList(Divider) = .empty,

pub const Axis = Slimed.Axis;

pub const Node = union(enum) {
    pane: *Session,
    split: Split,
};

pub const Split = struct {
    axis: Axis,
    /// Owned by the tab.
    children: []Child,
};

pub const Child = struct {
    /// Of the split's space, as a fraction of the children's total.
    share: u16,
    node: Node,
};

pub fn create(alloc: Allocator, conn: ?*Slimed, id: u32, root: Node, focus: *Session) !*Tab {
    const self = try alloc.create(Tab);
    self.* = .{ .id = id, .conn = conn, .root = root, .focus = focus };
    return self;
}

/// Free the tab and its tree; its sessions are the caller's.
pub fn destroy(self: *Tab, alloc: Allocator) void {
    freeNode(alloc, self.root);
    self.dividers.deinit(alloc);
    alloc.destroy(self);
}

/// Swap in a new tree from slimed, keeping focus and zoom on panes still
/// in it. Frees the old tree.
pub fn setRoot(self: *Tab, alloc: Allocator, root: Node) void {
    freeNode(alloc, self.root);
    self.root = root;
    if (!self.contains(self.focus)) self.focus = first(root);
    if (self.zoom) |z| if (!self.contains(z)) {
        self.zoom = null;
    };
}

pub fn freeNode(alloc: Allocator, node: Node) void {
    switch (node) {
        .pane => {},
        .split => |s| {
            for (s.children) |c| freeNode(alloc, c.node);
            alloc.free(s.children);
        },
    }
}

/// The panes, in layout order: left to right, top to bottom.
pub fn iterator(self: *const Tab) Iterator {
    return switch (self.root) {
        .pane => |s| .{ .single = s },
        .split => |sp| it: {
            var it: Iterator = .{};
            it.stack[0] = .{ .children = sp.children };
            it.len = 1;
            break :it it;
        },
    };
}

pub const Iterator = struct {
    single: ?*Session = null,
    /// slimed's trees are at most 32 deep.
    stack: [34]struct { children: []const Child, next: usize = 0 } = undefined,
    len: usize = 0,

    pub fn next(self: *Iterator) ?*Session {
        if (self.single) |s| {
            self.single = null;
            return s;
        }
        while (self.len > 0) {
            const top = &self.stack[self.len - 1];
            if (top.next == top.children.len) {
                self.len -= 1;
                continue;
            }
            const c = top.children[top.next];
            top.next += 1;
            switch (c.node) {
                .pane => |s| return s,
                .split => |sp| {
                    if (self.len == self.stack.len) continue;
                    self.stack[self.len] = .{ .children = sp.children };
                    self.len += 1;
                },
            }
        }
        return null;
    }
};

/// The pane showing slimed's pane `id`.
pub fn findPane(self: *const Tab, id: u32) ?*Session {
    var it = self.iterator();
    while (it.next()) |s| if (s.slimedPane() == id) return s;
    return null;
}

/// The pane whose session is `id`.
pub fn findSession(self: *const Tab, id: u32) ?*Session {
    var it = self.iterator();
    while (it.next()) |s| if (s.id == id) return s;
    return null;
}

/// Whether `s` is drawn: every pane is, unless another is zoomed.
pub fn shows(self: *const Tab, s: *const Session) bool {
    return if (self.zoom) |z| z == s else true;
}

/// Output arrived in a pane while the tab wasn't shown.
pub fn activity(self: *const Tab) bool {
    var it = self.iterator();
    while (it.next()) |s| if (s.activity) return true;
    return false;
}

pub fn contains(self: *const Tab, s: *const Session) bool {
    return containsNode(self.root, s);
}

fn containsNode(node: Node, s: *const Session) bool {
    return switch (node) {
        .pane => |p| p == s,
        .split => |sp| for (sp.children) |c| {
            if (containsNode(c.node, s)) break true;
        } else false,
    };
}

pub fn count(self: *const Tab) usize {
    return countNode(self.root);
}

fn countNode(node: Node) usize {
    return switch (node) {
        .pane => 1,
        .split => |sp| n: {
            var n: usize = 0;
            for (sp.children) |c| n += countNode(c.node);
            break :n n;
        },
    };
}

/// The first pane in layout order.
pub fn first(node: Node) *Session {
    return switch (node) {
        .pane => |s| s,
        .split => |sp| first(sp.children[0].node),
    };
}

/// Take `s` out of the tree, as slimed will once it hears: its siblings
/// share its space, and a split left with one child gives way to it.
/// Returns the pane nearest to where it was, to focus, or null if it was
/// the tab's last.
pub fn remove(self: *Tab, alloc: Allocator, s: *const Session) ?*Session {
    if (self.zoom == s) self.zoom = null;
    switch (self.root) {
        .pane => return null,
        .split => {},
    }
    const near = removeNode(alloc, &self.root, s) orelse return null;
    if (self.focus == s) self.focus = near;
    return near;
}

fn removeNode(alloc: Allocator, node: *Node, s: *const Session) ?*Session {
    const sp = &node.split;
    for (sp.children, 0..) |*c, i| switch (c.node) {
        .pane => |p| if (p == s) {
            const rest = alloc.alloc(Child, sp.children.len - 1) catch {
                // Leave it in, sharing nothing: slimed's tree replaces
                // this one soon.
                c.share = 0;
                return first(sp.children[if (i == 0) 1 else i - 1].node);
            };
            @memcpy(rest[0..i], sp.children[0..i]);
            @memcpy(rest[i..], sp.children[i + 1 ..]);
            alloc.free(sp.children);
            sp.children = rest;
            const near = first(rest[if (i == 0) 0 else i - 1].node);
            if (rest.len == 1) {
                const only = rest[0].node;
                alloc.free(rest);
                node.* = only;
            }
            return near;
        },
        .split => if (containsNode(c.node, s)) return removeNode(alloc, &c.node, s),
    };
    return null;
}

/// Where a dragged pane goes.
pub const Place = union(enum) {
    /// Where this pane is, which takes its place.
    swap: *Session,
    /// On `side` of `target`, taking half its space.
    beside: struct { target: *Session, side: Slimed.Direction },
    /// Along the tab's whole `side`, taking half the tab.
    edge: Slimed.Direction,
};

/// Move pane `s` to `to`, and focus it. The tree changes whole or not at
/// all: the move is made on a copy.
pub fn move(self: *Tab, alloc: Allocator, s: *Session, to: Place) !void {
    if (self.count() < 2 or !self.contains(s)) return;
    switch (to) {
        .swap => |t| if (t == s or !self.contains(t)) return,
        .beside => |b| if (b.target == s or !self.contains(b.target)) return,
        .edge => {},
    }
    var root = try cloneNode(alloc, self.root);
    errdefer freeNode(alloc, root);
    switch (to) {
        .swap => |t| {
            const from = leafOf(&root, s).?;
            const into = leafOf(&root, t).?;
            from.* = .{ .pane = t };
            into.* = .{ .pane = s };
        },
        .beside => |b| {
            try take(alloc, &root, s);
            try insertBeside(alloc, &root, s, b.target, b.side);
        },
        .edge => |side| {
            try take(alloc, &root, s);
            try insertEdge(alloc, &root, s, side);
        },
    }
    freeNode(alloc, self.root);
    self.root = root;
    self.zoom = null;
    self.focus = s;
}

fn cloneNode(alloc: Allocator, node: Node) !Node {
    switch (node) {
        .pane => return node,
        .split => |sp| {
            const children = try alloc.alloc(Child, sp.children.len);
            var made: usize = 0;
            errdefer {
                for (children[0..made]) |c| freeNode(alloc, c.node);
                alloc.free(children);
            }
            for (children, sp.children) |*out, c| {
                out.* = .{ .share = c.share, .node = try cloneNode(alloc, c.node) };
                made += 1;
            }
            return .{ .split = .{ .axis = sp.axis, .children = children } };
        },
    }
}

/// The leaf holding `s`.
fn leafOf(node: *Node, s: *const Session) ?*Node {
    switch (node.*) {
        .pane => |p| return if (p == s) node else null,
        .split => |*sp| for (sp.children) |*c| {
            if (leafOf(&c.node, s)) |n| return n;
        },
    }
    return null;
}

/// Take `s` out of `root`, which holds another pane too.
fn take(alloc: Allocator, root: *Node, s: *const Session) !void {
    _ = removeNode(alloc, root, s);
    // Removing keeps the pane, with no share, when it can't allocate.
    if (containsNode(root.*, s)) return error.OutOfMemory;
}

/// The split directly holding the leaf of `s`, and its index there.
fn parentOf(node: *Node, s: *const Session) ?struct { split: *Split, index: usize } {
    const sp = switch (node.*) {
        .pane => return null,
        .split => |*sp| sp,
    };
    for (sp.children, 0..) |*c, i| switch (c.node) {
        .pane => |p| if (p == s) return .{ .split = sp, .index = i },
        .split => if (parentOf(&c.node, s)) |found| return found,
    };
    return null;
}

fn axisOf(side: Slimed.Direction) Axis {
    return if (side == .right or side == .left) .row else .column;
}

fn after(side: Slimed.Direction) bool {
    return side == .right or side == .down;
}

/// `children` with `child` put in at `at`, in a new slice; frees the old.
fn insertChild(alloc: Allocator, sp: *Split, at: usize, child: Child) !void {
    const more = try alloc.alloc(Child, sp.children.len + 1);
    @memcpy(more[0..at], sp.children[0..at]);
    more[at] = child;
    @memcpy(more[at + 1 ..], sp.children[at..]);
    alloc.free(sp.children);
    sp.children = more;
}

/// Put `s` on `side` of `target`: into the split holding it if that runs
/// the same way, sharing its space, else in a new split with it.
fn insertBeside(alloc: Allocator, root: *Node, s: *Session, target: *Session, side: Slimed.Direction) !void {
    const axis = axisOf(side);
    if (parentOf(root, target)) |p| if (p.split.axis == axis) {
        const t = &p.split.children[p.index];
        const half = @max(1, t.share / 2);
        t.share = @max(1, t.share - half);
        return insertChild(alloc, p.split, if (after(side)) p.index + 1 else p.index, .{ .share = half, .node = .{ .pane = s } });
    };
    const leaf = leafOf(root, target).?;
    const kids = try alloc.alloc(Child, 2);
    kids[@intFromBool(!after(side))] = .{ .share = 5000, .node = .{ .pane = target } };
    kids[@intFromBool(after(side))] = .{ .share = 5000, .node = .{ .pane = s } };
    leaf.* = .{ .split = .{ .axis = axis, .children = kids } };
}

/// Put `s` along `side` of the whole tree, taking half of it.
fn insertEdge(alloc: Allocator, root: *Node, s: *Session, side: Slimed.Direction) !void {
    const axis = axisOf(side);
    switch (root.*) {
        .split => |*sp| if (sp.axis == axis) {
            var total: u32 = 0;
            for (sp.children) |c| total += c.share;
            const share: u16 = @intCast(@min(total, std.math.maxInt(u16)));
            return insertChild(alloc, sp, if (after(side)) sp.children.len else 0, .{ .share = share, .node = .{ .pane = s } });
        },
        .pane => {},
    }
    const kids = try alloc.alloc(Child, 2);
    kids[@intFromBool(!after(side))] = .{ .share = 5000, .node = root.* };
    kids[@intFromBool(after(side))] = .{ .share = 5000, .node = .{ .pane = s } };
    root.* = .{ .split = .{ .axis = axis, .children = kids } };
}

/// Give each pane its part of `area` (in `Session.frame`), with `gap`
/// pixel dividers between them; a zoomed pane gets all of it.
pub fn place(self: *Tab, alloc: Allocator, area: Rect, gap: f32) !void {
    self.dividers.clearRetainingCapacity();
    if (self.zoom) |z| {
        z.frame = area;
        return;
    }
    try self.placeNode(alloc, &self.root, area, gap);
}

fn placeNode(self: *Tab, alloc: Allocator, node: *Node, r: Rect, gap: f32) !void {
    const sp = switch (node.*) {
        .pane => |s| {
            s.frame = r;
            return;
        },
        .split => |*sp| sp,
    };
    const row = sp.axis == .row;
    const n: f32 = @floatFromInt(sp.children.len);
    const base = if (row) r.x else r.y;
    const span = @max(0, (if (row) r.w else r.h) - gap * (n - 1));
    var total: u32 = 0;
    for (sp.children) |c| total += c.share;
    var sum: u32 = 0;
    var start: f32 = base;
    for (sp.children, 0..) |*c, i| {
        sum += c.share;
        const last = i == sp.children.len - 1;
        // Ends on whole pixels, from the running total so rounding
        // doesn't add up; the last child takes what's left.
        const frac = if (total == 0) @as(f32, @floatFromInt(i + 1)) / n else @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(total));
        const end = if (last) base + span + gap * (n - 1) else base + @round(span * frac) + gap * @as(f32, @floatFromInt(i));
        const child: Rect = if (row)
            .{ .x = start, .y = r.y, .w = @max(0, end - start), .h = r.h }
        else
            .{ .x = r.x, .y = start, .w = r.w, .h = @max(0, end - start) };
        try self.placeNode(alloc, &c.node, child, gap);
        if (!last) try self.dividers.append(alloc, .{
            .rect = if (row)
                .{ .x = end, .y = r.y, .w = gap, .h = r.h }
            else
                .{ .x = r.x, .y = end, .w = r.w, .h = gap },
            .split = sp,
            .index = i,
            .span = span,
        });
        start = end + gap;
    }
}

/// A gap between two of a split's children, which dragging moves.
/// Points into the tree, so it's good until the tree next changes.
pub const Divider = struct {
    rect: Rect,
    split: *Split,
    /// Between children `index` and `index + 1`.
    index: usize,
    /// The split's pixels, gaps aside, which its shares divide.
    span: f32,

    pub fn axis(self: Divider) Axis {
        return self.split.axis;
    }

    /// The shares of the children on either side.
    pub fn shares(self: Divider) [2]u16 {
        return .{ self.split.children[self.index].share, self.split.children[self.index + 1].share };
    }

    /// Move the divider `delta` pixels from where the children's shares
    /// `from` had it, keeping either side at least `min` pixels where
    /// there's room. Only those two children change.
    pub fn drag(self: Divider, from: [2]u16, delta: f32, min: f32) void {
        var total: u32 = 0;
        for (self.split.children) |c| total += c.share;
        if (total == 0 or self.span <= 0) return;
        const pair = @as(u32, from[0]) + from[1];
        if (pair < 2) return;
        const per = self.span / @as(f32, @floatFromInt(total));
        const pair_px = @as(f32, @floatFromInt(pair)) * per;
        const lo = @min(min, pair_px / 2);
        const a_px = std.math.clamp(@as(f32, @floatFromInt(from[0])) * per + delta, lo, pair_px - lo);
        const a: u32 = std.math.clamp(@as(u32, @intFromFloat(@round(a_px / per))), 1, pair - 1);
        self.split.children[self.index].share = @intCast(a);
        self.split.children[self.index + 1].share = @intCast(pair - a);
    }
};

/// The tree as slimed's, in `arena`, for sending back after a drag. Null
/// if a pane isn't slimed's.
pub fn toLayout(self: *const Tab, arena: Allocator) !?Slimed.Node {
    return toLayoutNode(arena, self.root);
}

fn toLayoutNode(arena: Allocator, node: Node) !?Slimed.Node {
    switch (node) {
        .pane => |s| return .{ .pane = s.slimedPane() orelse return null },
        .split => |sp| {
            const children = try arena.alloc(Slimed.Child, sp.children.len);
            for (children, sp.children) |*out, c| out.* = .{
                .share = c.share,
                .node = try toLayoutNode(arena, c.node) orelse return null,
            };
            return .{ .split = .{ .axis = sp.axis, .children = children } };
        },
    }
}

/// slimed's tree for a tab as one of ours, with each pane's session from
/// `ctx.session(pane)`. Panes without one are left out, and splits that
/// leaves empty or alone collapse. Null if no pane has a session.
pub fn fromLayout(alloc: Allocator, node: Slimed.Node, ctx: anytype) !?Node {
    switch (node) {
        .pane => |id| return if (ctx.session(id)) |s| .{ .pane = s } else null,
        .split => |sp| {
            var kids: std.ArrayList(Child) = .empty;
            errdefer {
                for (kids.items) |c| freeNode(alloc, c.node);
                kids.deinit(alloc);
            }
            for (sp.children) |c| {
                const child = try fromLayout(alloc, c.node, ctx) orelse continue;
                kids.append(alloc, .{ .share = c.share, .node = child }) catch |err| {
                    freeNode(alloc, child);
                    return err;
                };
            }
            switch (kids.items.len) {
                0 => return null,
                1 => {
                    const only = kids.items[0].node;
                    kids.deinit(alloc);
                    return only;
                },
                else => return .{ .split = .{ .axis = sp.axis, .children = try kids.toOwnedSlice(alloc) } },
            }
        },
    }
}

test "placing and removing panes" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    var c: Session = undefined;
    // a | (b over c), 75/25.
    const column = try alloc.alloc(Child, 2);
    column[0] = .{ .share = 5000, .node = .{ .pane = &b } };
    column[1] = .{ .share = 5000, .node = .{ .pane = &c } };
    const row = try alloc.alloc(Child, 2);
    row[0] = .{ .share = 7500, .node = .{ .pane = &a } };
    row[1] = .{ .share = 2500, .node = .{ .split = .{ .axis = .column, .children = column } } };
    const tab = try create(alloc, null, 1, .{ .split = .{ .axis = .row, .children = row } }, &c);
    defer tab.destroy(alloc);

    try tab.place(alloc, .{ .x = 10, .y = 20, .w = 401, .h = 201 }, 1);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 300, .h = 201 }, a.frame);
    try std.testing.expectEqual(Rect{ .x = 311, .y = 20, .w = 100, .h = 100 }, b.frame);
    try std.testing.expectEqual(Rect{ .x = 311, .y = 121, .w = 100, .h = 100 }, c.frame);
    try std.testing.expectEqual(@as(usize, 2), tab.dividers.items.len);
    try std.testing.expectEqual(@as(usize, 3), tab.count());

    // Dragging the row's divider 100 of its 400 pixels left makes it
    // 50/50; past the minimum, it stops there.
    const d = tab.dividers.items[0];
    try std.testing.expectEqual(Axis.row, d.axis());
    const from = d.shares();
    d.drag(from, -100, 50);
    try std.testing.expectEqual([2]u16{ 5000, 5000 }, d.shares());
    d.drag(from, -1000, 50);
    try std.testing.expectEqual([2]u16{ 1250, 8750 }, d.shares());
    d.drag(from, 0, 50);

    // Removing c gives its space to b, which takes the focus, and the
    // column collapses.
    try std.testing.expectEqual(&b, tab.remove(alloc, &c).?);
    try std.testing.expectEqual(&b, tab.focus);
    try std.testing.expect(!tab.contains(&c));
    try tab.place(alloc, .{ .w = 401, .h = 100 }, 1);
    try std.testing.expectEqual(Rect{ .x = 301, .w = 100, .h = 100 }, b.frame);

    tab.zoom = &a;
    try tab.place(alloc, .{ .w = 401, .h = 100 }, 1);
    try std.testing.expectEqual(Rect{ .w = 401, .h = 100 }, a.frame);
    try std.testing.expectEqual(@as(usize, 0), tab.dividers.items.len);

    try std.testing.expectEqual(&b, tab.remove(alloc, &a).?);
    try std.testing.expect(tab.zoom == null);
    try std.testing.expect(tab.remove(alloc, &b) == null);
}

test "moving panes" {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    var c: Session = undefined;
    const row = try alloc.alloc(Child, 3);
    row[0] = .{ .share = 3334, .node = .{ .pane = &a } };
    row[1] = .{ .share = 3333, .node = .{ .pane = &b } };
    row[2] = .{ .share = 3333, .node = .{ .pane = &c } };
    const tab = try create(alloc, null, 1, .{ .split = .{ .axis = .row, .children = row } }, &a);
    defer tab.destroy(alloc);

    // c along the top: a column of c over the rest.
    try tab.move(alloc, &c, .{ .edge = .up });
    try std.testing.expectEqual(Axis.column, tab.root.split.axis);
    try std.testing.expectEqual(&c, tab.root.split.children[0].node.pane);
    try std.testing.expectEqual(@as(usize, 2), tab.root.split.children[1].node.split.children.len);
    try std.testing.expectEqual(&c, tab.focus);

    // a below b: b's leaf becomes a column, and the row collapses.
    try tab.move(alloc, &a, .{ .beside = .{ .target = &b, .side = .down } });
    try std.testing.expectEqual(Axis.column, tab.root.split.axis);
    try std.testing.expectEqual(@as(usize, 3), tab.root.split.children.len);
    try std.testing.expectEqual(&b, tab.root.split.children[1].node.pane);
    try std.testing.expectEqual(&a, tab.root.split.children[2].node.pane);

    // Swapping trades leaves and keeps the shape.
    try tab.move(alloc, &a, .{ .swap = &c });
    try std.testing.expectEqual(&a, tab.root.split.children[0].node.pane);
    try std.testing.expectEqual(&c, tab.root.split.children[2].node.pane);

    // Right of b, in the column: a new row of b and c.
    try tab.move(alloc, &c, .{ .beside = .{ .target = &b, .side = .right } });
    const pair = tab.root.split.children[1].node.split;
    try std.testing.expectEqual(Axis.row, pair.axis);
    try std.testing.expectEqual(&b, pair.children[0].node.pane);
    try std.testing.expectEqual(&c, pair.children[1].node.pane);
    try std.testing.expectEqual(@as(usize, 3), tab.count());
}

test fromLayout {
    const alloc = std.testing.allocator;
    var a: Session = undefined;
    var b: Session = undefined;
    const Ctx = struct {
        a: *Session,
        b: *Session,
        pub fn session(self: @This(), id: u32) ?*Session {
            return switch (id) {
                1 => self.a,
                2 => self.b,
                else => null,
            };
        }
    };
    var inner = [_]Slimed.Child{ .{ .share = 5000, .node = .{ .pane = 2 } }, .{ .share = 5000, .node = .{ .pane = 3 } } };
    var outer = [_]Slimed.Child{ .{ .share = 5000, .node = .{ .pane = 1 } }, .{ .share = 5000, .node = .{ .split = .{ .axis = .column, .children = &inner } } } };
    // Pane 3 has no session, so the column gives way to b.
    const root = (try fromLayout(alloc, .{ .split = .{ .axis = .row, .children = &outer } }, Ctx{ .a = &a, .b = &b })).?;
    defer freeNode(alloc, root);
    try std.testing.expectEqual(@as(usize, 2), root.split.children.len);
    try std.testing.expectEqual(&b, root.split.children[1].node.pane);
}
