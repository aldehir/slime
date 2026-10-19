//! The command palette: a query, the entries it's over (every tab,
//! every hidden workspace, the window's commands, and init.lua's
//! actions; or, in the host step, the hosts to connect to), and the
//! results, the entries the query matches, best first, with the units
//! it matched marked for drawing. The app fills the entries whenever
//! the tree is built (`App.rebuildPalette`), copying their text in
//! here, so what's listed never points at a tab or workspace that has
//! since gone, and moves the focus with the keyboard;
//! `widgets/PaletteView.zig` lays it out and draws it.
const Palette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Painter = @import("../renderer/Painter.zig");
const Id = @import("Id.zig");
const TextField = @import("TextField.zig");
const binding = @import("../binding.zig");

/// Units of a label or detail kept for matching and drawing.
pub const max_text = 160;
/// Units of the query matched; the rest are ignored.
pub const max_query = 64;
/// Starts tried for the query's first unit, each followed greedily.
const max_starts = 8;

pub const Step = enum {
    /// Everything: tabs, workspaces, commands.
    commands,
    /// "Connect to host…": the hosts, and what's typed.
    host,
};

/// Listed in this order, under a caption each, while the query is empty.
pub const Section = enum { tab, workspace, command, host };

pub fn caption(s: Section) []const u16 {
    return switch (s) {
        .tab => L("Tabs"),
        .workspace => L("Workspaces"),
        .command => L("Commands"),
        .host => L("Hosts"),
    };
}

/// What choosing an entry does.
pub const Action = union(enum) {
    /// Show the tab, by `Tab.key`.
    tab: u32,
    /// Show a hidden workspace, by `App.Workspace.key`.
    show_workspace: u32,
    /// Run a key binding's action on the focused pane.
    binding: binding.Action,
    /// Click a control, as the row's button of that part would.
    part: Id,
    /// Go on to the host step.
    connect,
    /// Connect to a remembered host, by its place in the hosts list.
    host: u32,
    /// Connect to the host typed in the query.
    typed_host,
    toggle_stats,
    reload_config,
    /// Run one of init.lua's actions by name, in the daemon.
    invoke: []const u8,
};

pub const Entry = struct {
    label: []const u16,
    detail: []const u16 = &.{},
    /// At the right: the key that does the same, or a note.
    right: []const u16 = &.{},
    icon: ?Painter.Lucide = null,
    section: Section,
    action: Action,
    /// Listed whatever the query, unmarked: "Connect to <what's typed>".
    always: bool = false,
};

pub const Hits = std.StaticBitSet(max_text);

/// An entry the query matches, and how well.
pub const Result = struct {
    entry: usize,
    score: i32,
    label_hits: Hits = .initEmpty(),
    detail_hits: Hits = .initEmpty(),
};

/// The entries' text and the lists, emptied for each rebuild.
arena: std.heap.ArenaAllocator,
step: Step = .commands,
query: TextField = .{},
entries: std.ArrayList(Entry) = .empty,
results: std.ArrayList(Result) = .empty,
/// The result the keyboard is on: Enter chooses it.
focus: usize = 0,
/// The first result drawn.
scroll: usize = 0,
/// The query the results are for; a change puts the focus back at the
/// top.
matched: [max_query]u16 = undefined,
matched_len: usize = 0,
matched_step: Step = .commands,

pub fn init(gpa: Allocator) Palette {
    return .{ .arena = .init(gpa) };
}

pub fn deinit(self: *Palette) void {
    self.arena.deinit();
    self.* = undefined;
}

/// Start over: the entries go, to be added again.
pub fn beginRebuild(self: *Palette) void {
    _ = self.arena.reset(.retain_capacity);
    self.entries = .empty;
    self.results = .empty;
}

/// Add an entry, copying its text (`max_text` units of it).
pub fn add(self: *Palette, e: Entry) Allocator.Error!void {
    const a = self.arena.allocator();
    var copy = e;
    copy.label = try a.dupe(u16, e.label[0..@min(e.label.len, max_text)]);
    copy.detail = try a.dupe(u16, e.detail[0..@min(e.detail.len, max_text)]);
    copy.right = try a.dupe(u16, e.right);
    switch (e.action) {
        .invoke => |name| copy.action = .{ .invoke = try a.dupe(u8, name) },
        else => {},
    }
    try self.entries.append(a, copy);
}

/// Match the query against the entries: the results, best first; with
/// no query, every entry in its order. A query other than the last
/// one's puts the focus at the top.
pub fn endRebuild(self: *Palette) Allocator.Error!void {
    const a = self.arena.allocator();
    const query = self.queryText();
    for (self.entries.items, 0..) |e, i| {
        if (e.always) {
            try self.results.append(a, .{ .entry = i, .score = std.math.maxInt(i32) });
            continue;
        }
        if (query.len == 0) {
            try self.results.append(a, .{ .entry = i, .score = 0 });
            continue;
        }
        const label = match(e.label, query);
        const detail = match(e.detail, query);
        if (label == null and detail == null) continue;
        var r: Result = .{ .entry = i, .score = 0 };
        // A label match counts for more than one in the detail.
        if (label) |m| {
            r.score = m.score + 20;
            r.label_hits = m.hits;
        }
        if (detail) |m| {
            if (label == null) r.score = m.score;
            r.detail_hits = m.hits;
        }
        try self.results.append(a, r);
    }
    if (query.len > 0) std.sort.insertion(Result, self.results.items, {}, better);
    const changed = self.step != self.matched_step or !std.mem.eql(u16, query, self.matched[0..self.matched_len]);
    if (changed) {
        @memcpy(self.matched[0..query.len], query);
        self.matched_len = query.len;
        self.matched_step = self.step;
        self.focus = 0;
        self.scroll = 0;
    }
    // The scroll stays where the wheel put it, past the focus or not.
    if (self.results.items.len == 0) {
        self.focus = 0;
        self.scroll = 0;
    } else {
        self.focus = @min(self.focus, self.results.items.len - 1);
        self.scroll = @min(self.scroll, self.results.items.len - 1);
    }
}

fn better(_: void, a: Result, b: Result) bool {
    return a.score > b.score;
}

/// The query, as matched: its first `max_query` units.
pub fn queryText(self: *const Palette) []const u16 {
    const text = self.query.text();
    return text[0..@min(text.len, max_query)];
}

pub fn count(self: *const Palette) usize {
    return self.results.items.len;
}

/// Result `i`'s entry.
pub fn entryOf(self: *const Palette, i: usize) ?*const Entry {
    if (i >= self.results.items.len) return null;
    return &self.entries.items[self.results.items[i].entry];
}

/// The entry the keyboard is on.
pub fn focused(self: *const Palette) ?*const Entry {
    return self.entryOf(self.focus);
}

/// Move the focus `delta` results, around the ends.
pub fn move(self: *Palette, delta: isize) void {
    const n: isize = @intCast(self.results.items.len);
    if (n == 0) return;
    const at: isize = @intCast(self.focus);
    self.focus = @intCast(@mod(at + delta, n));
}

/// A page of `rows` up or down, stopping at the ends.
pub fn page(self: *Palette, rows: usize, down: bool) void {
    const n = self.results.items.len;
    if (n == 0) return;
    const step = @max(rows, 1);
    self.focus = if (down) @min(self.focus + step, n - 1) else self.focus -| step;
}

pub fn focusEnd(self: *Palette, first: bool) void {
    const n = self.results.items.len;
    self.focus = if (first or n == 0) 0 else n - 1;
}

/// Scroll so the focus is among the `rows` results drawn from `scroll`.
pub fn keepVisible(self: *Palette, rows: usize) void {
    const shown = @max(rows, 1);
    if (self.focus < self.scroll) self.scroll = self.focus;
    if (self.focus >= self.scroll + shown) self.scroll = self.focus + 1 - shown;
}

/// Scroll the list `delta` results, keeping `rows` of them in view.
pub fn scrollBy(self: *Palette, delta: isize, rows: usize) void {
    const n = self.results.items.len;
    const most = n -| @max(rows, 1);
    const at: isize = @intCast(self.scroll);
    self.scroll = @intCast(std.math.clamp(at + delta, 0, @as(isize, @intCast(most))));
}

/// Go on to the host step, or back to the commands: the query starts
/// over.
pub fn setStep(self: *Palette, step: Step) void {
    self.step = step;
    self.query = .{};
    self.focus = 0;
    self.scroll = 0;
}

/// Whether the query matches `text`: every unit of the query in order,
/// case aside. The score favors matches at the start, at the start of
/// words, and in runs, and the units matched are marked.
pub const Match = struct { score: i32, hits: Hits };

pub fn match(text: []const u16, query: []const u16) ?Match {
    if (query.len == 0 or text.len == 0 or query.len > text.len) return null;
    var best: ?Match = null;
    var starts: usize = 0;
    var i: usize = 0;
    while (i < text.len and starts < max_starts) : (i += 1) {
        if (fold(text[i]) != fold(query[0])) continue;
        starts += 1;
        if (matchFrom(text, query, i)) |m| {
            if (best == null or m.score > best.?.score) best = m;
        }
    }
    return best;
}

/// The query matched greedily from `start`, where its first unit is.
fn matchFrom(text: []const u16, query: []const u16, start: usize) ?Match {
    var m: Match = .{ .score = 0, .hits = .initEmpty() };
    var at = start;
    var prev: ?usize = null;
    for (query) |q| {
        const want = fold(q);
        while (at < text.len and fold(text[at]) != want) at += 1;
        if (at == text.len) return null;
        m.hits.set(at);
        m.score += 1;
        if (at == 0) m.score += 8;
        if (at > 0 and isWordStart(text[at - 1], text[at])) m.score += 6;
        if (prev) |p| {
            if (at == p + 1) m.score += 4 else m.score -= @intCast(@min(at - p - 1, 8));
        }
        prev = at;
        at += 1;
    }
    return m;
}

/// Case folded, for ASCII; other units match themselves.
fn fold(u: u16) u16 {
    return if (u < 0x80) std.ascii.toLower(@intCast(u)) else u;
}

/// Whether `cur` starts a word after `prev`: after a separator, or a
/// capital after a small letter.
fn isWordStart(prev: u16, cur: u16) bool {
    const separator = switch (prev) {
        ' ', '.', '-', '_', '/', '\\', ':', '@', '(', '[', 0xB7 => true,
        else => false,
    };
    if (separator) return true;
    return prev < 0x80 and cur < 0x80 and std.ascii.isLower(@intCast(prev)) and std.ascii.isUpper(@intCast(cur));
}

const L = std.unicode.utf8ToUtf16LeStringLiteral;

test "the query matches in order, case aside, and marks what it hit" {
    const m = match(L("Split right"), L("spr")).?;
    try std.testing.expect(m.hits.isSet(0) and m.hits.isSet(1) and m.hits.isSet(6));
    try std.testing.expectEqual(@as(usize, 3), m.hits.count());
    try std.testing.expect(match(L("Split right"), L("rs")) == null);
    try std.testing.expect(match(L("ab"), L("abc")) == null);
    try std.testing.expect(match(L(""), L("a")) == null);
    try std.testing.expect(match(L("a"), L("")) == null);
}

test "starts of words and runs score over scattered units" {
    const start = match(L("New tab"), L("new")).?.score;
    const inside = match(L("renew tab"), L("new")).?.score;
    try std.testing.expect(start > inside);
    const word = match(L("Open browser"), L("br")).?.score;
    const scattered = match(L("Toggle sidebar"), L("br")).?.score;
    try std.testing.expect(word > scattered);
    // The best start wins, not the first: "dev" in the host, not the d
    // of "default".
    const m = match(L("default · dev1.casa"), L("dev")).?;
    try std.testing.expect(m.hits.isSet(10) and m.hits.isSet(11) and m.hits.isSet(12));
}

test "results follow the query, best first, and the focus moves around them" {
    var p: Palette = .init(std.testing.allocator);
    defer p.deinit();
    p.beginRebuild();
    try p.add(.{ .label = L("cmd"), .detail = L("default"), .section = .tab, .action = .{ .tab = 1 } });
    try p.add(.{ .label = L("zsh"), .detail = L("default · dev1"), .section = .tab, .action = .{ .tab = 2 } });
    try p.add(.{ .label = L("New tab"), .section = .command, .action = .{ .binding = .new_tab } });
    try p.add(.{ .label = L("Dev layout"), .detail = L("init.lua"), .section = .command, .action = .{ .invoke = "dev" } });
    try p.endRebuild();
    // No query: everything, in order.
    try std.testing.expectEqual(@as(usize, 4), p.count());
    try std.testing.expectEqual(Action{ .tab = 1 }, p.focused().?.action);
    p.move(-1);
    try std.testing.expectEqual(@as(usize, 3), p.focus);
    p.move(1);
    try std.testing.expectEqual(@as(usize, 0), p.focus);
    p.page(10, true);
    try std.testing.expectEqual(@as(usize, 3), p.focus);
    p.focusEnd(true);
    try std.testing.expectEqual(@as(usize, 0), p.focus);

    // "dev": the Lua action by its label, then the tab by its host.
    p.move(2);
    p.query.insert(L("dev"));
    p.beginRebuild();
    try p.add(.{ .label = L("cmd"), .detail = L("default"), .section = .tab, .action = .{ .tab = 1 } });
    try p.add(.{ .label = L("zsh"), .detail = L("default · dev1"), .section = .tab, .action = .{ .tab = 2 } });
    try p.add(.{ .label = L("New tab"), .section = .command, .action = .{ .binding = .new_tab } });
    try p.add(.{ .label = L("Dev layout"), .detail = L("init.lua"), .section = .command, .action = .{ .invoke = "dev" } });
    try p.endRebuild();
    try std.testing.expectEqual(@as(usize, 2), p.count());
    // The focus went back to the top for the new query.
    try std.testing.expectEqual(@as(usize, 0), p.focus);
    try std.testing.expectEqualStrings("dev", p.focused().?.action.invoke);
    try std.testing.expect(p.results.items[0].label_hits.isSet(0));
    try std.testing.expectEqual(Action{ .tab = 2 }, p.entryOf(1).?.action);
    try std.testing.expect(p.entryOf(1).?.label.len == 3);
    try std.testing.expect(p.results.items[1].detail_hits.isSet(10));
    // The same query again leaves the focus where it is.
    p.move(1);
    p.beginRebuild();
    try p.add(.{ .label = L("Dev layout"), .section = .command, .action = .{ .invoke = "dev" } });
    try p.add(.{ .label = L("zsh"), .detail = L("dev1"), .section = .tab, .action = .{ .tab = 2 } });
    try p.endRebuild();
    try std.testing.expectEqual(@as(usize, 1), p.focus);
    // Nothing matches: no focus.
    p.query.insert(L("zzz"));
    p.beginRebuild();
    try p.add(.{ .label = L("Dev layout"), .section = .command, .action = .{ .invoke = "dev" } });
    try p.endRebuild();
    try std.testing.expectEqual(@as(usize, 0), p.count());
    try std.testing.expect(p.focused() == null);
}

test "an entry marked always is listed first whatever the query" {
    var p: Palette = .init(std.testing.allocator);
    defer p.deinit();
    p.setStep(.host);
    p.query.insert(L("alde@"));
    p.beginRebuild();
    try p.add(.{ .label = L("devbox"), .section = .host, .action = .{ .host = 0 } });
    try p.add(.{ .label = L("Connect to alde@"), .section = .host, .action = .typed_host, .always = true });
    try p.add(.{ .label = L("alde@pi"), .section = .host, .action = .{ .host = 1 } });
    try p.endRebuild();
    try std.testing.expectEqual(@as(usize, 2), p.count());
    try std.testing.expectEqual(Action.typed_host, p.entryOf(0).?.action);
    try std.testing.expectEqual(Action{ .host = 1 }, p.entryOf(1).?.action);
    // Back to the commands, the query starts over.
    p.setStep(.commands);
    try std.testing.expectEqual(@as(usize, 0), p.query.len);
}

test "the scroll keeps the focus in view" {
    var p: Palette = .init(std.testing.allocator);
    defer p.deinit();
    p.beginRebuild();
    for (0..10) |_| try p.add(.{ .label = L("x"), .section = .command, .action = .{ .binding = .new_tab } });
    try p.endRebuild();
    p.focus = 7;
    p.keepVisible(3);
    try std.testing.expectEqual(@as(usize, 5), p.scroll);
    p.focus = 2;
    p.keepVisible(3);
    try std.testing.expectEqual(@as(usize, 2), p.scroll);
    p.scrollBy(100, 3);
    try std.testing.expectEqual(@as(usize, 7), p.scroll);
    // A rebuild with the same query leaves the scroll past the focus.
    p.beginRebuild();
    for (0..10) |_| try p.add(.{ .label = L("x"), .section = .command, .action = .{ .binding = .new_tab } });
    try p.endRebuild();
    try std.testing.expectEqual(@as(usize, 7), p.scroll);
    try std.testing.expectEqual(@as(usize, 2), p.focus);
    p.scrollBy(-100, 3);
    try std.testing.expectEqual(@as(usize, 0), p.scroll);
}
