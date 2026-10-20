//! Search: a needle looked for over a pane's screen and scrollback with
//! libghostty-vt's `search` module, the matches marked in frames as
//! highlights, and the current one made the selection, so a copy takes
//! it. The window keeps the text field; the search is the terminal's, so
//! every window on the pane sees the matches, as it sees the selection.
//!
//! The viewport is searched at once; the history is ticked a little
//! each frame (`refresh`), and the frame says while the count is still
//! growing (`partial`), which keeps frames coming.

const std = @import("std");
const vt = @import("root");

const Terminal = vt.Terminal;
const Screen = vt.Screen;
const Pin = vt.Pin;
const TerminalSearch = vt.search.Terminal;
const ScreenSearch = vt.search.Screen;
const RenderState = vt.RenderState;
const Selection = vt.Selection;

const alloc = std.heap.smp_allocator;

/// Which way `next` goes: down is toward newer rows.
pub const Direction = enum(u8) { down = 0, up = 1 };

pub const Step = enum(u8) { next = 0, previous = 1 };

/// Highlight tags as frames carry them.
pub const tag_match: u8 = 1;
pub const tag_current: u8 = 2;

/// History pages searched per frame: the rest waits for the next.
const ticks_per_frame = 8;

pub const State = struct {
    search: ?TerminalSearch = null,
    direction: Direction = .down,
    /// The render state's highlights are stale: matches or the current
    /// one changed, or the search ended.
    dirty: bool = false,
    /// As of the last refresh, for the frame: matches on the active
    /// screen, the current one counted from the top (0 for none), and
    /// whether the history is still being searched.
    total: u32 = 0,
    current: u32 = 0,
    partial: bool = false,

    /// Free the state. `t` is its terminal, if that's still open.
    pub fn deinit(self: *State, t: ?*Terminal) void {
        if (self.search) |*s| s.deinit(t);
        self.* = undefined;
    }

    pub fn isOn(self: *const State) bool {
        return self.search != null;
    }

    /// Whether the history is still being searched: frames should keep
    /// coming for the count.
    pub fn pending(self: *const State) bool {
        return self.search != null and self.partial;
    }

    /// Search for `needle`, replacing any search before, and select the
    /// nearest match: the newest, which the viewport most likely shows.
    /// An empty needle ends the search.
    pub fn start(self: *State, t: *Terminal, needle: []const u8, direction: Direction) !void {
        self.end(t);
        self.direction = direction;
        if (needle.len == 0) return;
        var s = try TerminalSearch.init(alloc, needle);
        errdefer s.deinit(t);
        s.feed(t, true);
        self.search = s;
        self.dirty = true;
        try self.select(t, .next);
    }

    /// End the search: the highlights go, the selection stays.
    pub fn end(self: *State, t: *Terminal) void {
        const s = &(self.search orelse return);
        s.deinit(t);
        self.search = null;
        self.dirty = true;
        self.total = 0;
        self.current = 0;
        self.partial = false;
    }

    /// To the next or previous match in the search's direction, wrapping
    /// round at the ends.
    pub fn step(self: *State, t: *Terminal, which: Step) !void {
        if (self.search == null) return;
        // The screen search orders matches newest first: its `next` is
        // older, which is up.
        const older = (self.direction == .up) == (which == .next);
        try self.select(t, if (older) .next else .prev);
    }

    /// Select a match, make it the selection, and show it.
    fn select(self: *State, t: *Terminal, to: ScreenSearch.Select) !void {
        const s = &(self.search orelse return);
        self.dirty = true;
        if (!try s.select(t, to, .none)) return;
        const ss = s.activeScreenSearch() orelse return;
        const hl = ss.selectedMatch() orelse return;
        const screen = t.screens.active;
        try screen.select(Selection.init(hl.startPin(), hl.endPin(), false));
        scrollTo(t, screen, hl.startPin());
    }

    /// Before a frame, after the render state's update and before its
    /// dirty rows are read: feed the search, tick the history a little,
    /// and put the matches in view into the state's highlights, the
    /// current one first (it wins where they overlap).
    pub fn refresh(self: *State, t: *Terminal, state: *RenderState) void {
        const s = &(self.search orelse {
            if (self.dirty) {
                clearHighlights(state);
                self.dirty = false;
            }
            return;
        });
        s.feed(t, true);
        var progressed = false;
        for (0..ticks_per_frame) |_| {
            switch (s.tick()) {
                .progress => progressed = true,
                .complete, .blocked => break,
            }
        }
        self.partial = !s.isComplete();

        const ss = s.activeScreenSearch();
        const total: u32 = if (ss) |x| @intCast(@min(x.matchesLen(), std.math.maxInt(u32))) else 0;
        // A reflow loses the search's selected match, though the selection
        // it made survives (see below): the index stays what it was.
        const current: u32 = if (ss) |x|
            (if (x.selected) |sel| total -| @as(u32, @intCast(@min(sel.idx, std.math.maxInt(u32)))) else if (t.screens.active.selection != null) @min(self.current, total) else 0)
        else
            0;
        const counts_changed = total != self.total or current != self.current;
        self.total = total;
        self.current = current;

        if (!self.dirty and !progressed and !counts_changed and state.dirty == .false) return;
        self.dirty = false;
        clearHighlights(state);
        current: {
            if (ss) |x| if (x.selectedMatch()) |m| {
                state.updateHighlightsFlattened(alloc, tag_current, &.{m}) catch {};
                break :current;
            };
            // A reflow (a resize) can lose the search's selected match
            // while the selection it made, tracked, survives: it still
            // marks the current match.
            const sel = t.screens.active.selection orelse break :current;
            var hl = flatten(sel.start(), sel.end()) catch break :current;
            defer hl.deinit(alloc);
            state.updateHighlightsFlattened(alloc, tag_current, &.{hl}) catch {};
        }
        const matches = s.viewportMatches() catch &.{};
        state.updateHighlightsFlattened(alloc, tag_match, matches) catch {};
    }
};

/// The rows from `start` to `end` as a flattened highlight, the form the
/// render state takes.
fn flatten(start: Pin, end: Pin) std.mem.Allocator.Error!vt.highlight.Flattened {
    const Flattened = vt.highlight.Flattened;
    var chunks: std.MultiArrayList(Flattened.Chunk) = .empty;
    errdefer chunks.deinit(alloc);
    var it = start.pageIterator(.right_down, end);
    while (it.next()) |chunk| try chunks.append(alloc, .{
        .node = chunk.node,
        .serial = chunk.node.serial,
        .start = chunk.start,
        .end = chunk.end,
    });
    return .{ .chunks = chunks, .top_x = start.x, .bot_x = end.x };
}

/// Drop every row's highlights, marking the rows that had any dirty, so
/// the frame carries them without.
fn clearHighlights(state: *RenderState) void {
    const rows = state.row_data.slice();
    var any = false;
    for (rows.items(.highlights), rows.items(.dirty)) |*hls, *dirty| {
        if (hls.items.len == 0) continue;
        hls.clearRetainingCapacity();
        dirty.* = true;
        any = true;
    }
    if (any and state.dirty == .false) state.dirty = .partial;
}

/// Scroll the viewport the least that shows `pin`'s row.
fn scrollTo(t: *Terminal, screen: *Screen, pin: Pin) void {
    if (inView(screen, pin)) return;
    const cur = screen.pages.pointFromPin(.screen, pin) orelse return;
    const top = screen.pages.pointFromPin(.screen, screen.pages.getTopLeft(.viewport)) orelse return;
    const rows: i64 = screen.pages.rows;
    const y: i64 = cur.screen.y;
    const top_y: i64 = top.screen.y;
    const delta = if (y < top_y) y - top_y else y - (top_y + rows - 1);
    t.scrollViewport(.{ .delta = @intCast(delta) });
}

/// Whether a pin's row is in the viewport. pointFromPin gives a pin
/// below the viewport a row past its bottom rather than null.
fn inView(screen: *const Screen, p: Pin) bool {
    const pt = screen.pages.pointFromPin(.viewport, p) orelse return false;
    return pt.viewport.y < screen.pages.rows;
}
