//! The app's state as widgets: the one place that knows both what slime
//! has (workspaces, tabs, panes, hosts) and what the UI draws (`ui/Tree`).
//! `build` makes a tree each frame, in an arena: the title bar, the
//! sidebar as a tree of sections, workspaces, tabs, and panes, the
//! terminal area's pane strips, a dialog over it, and a context menu over
//! everything. What a row shows under the mouse (the buttons that
//! appear) is decided here, from the UI's hover.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const binding = @import("binding.zig");
const App = @import("App.zig");
const Hosts = @import("Hosts.zig");
const Tab = @import("Tab.zig");
const Session = @import("Session.zig");
const ProgramStatus = @import("ProgramStatus.zig");
const Painter = @import("renderer/Painter.zig");
const Ui = @import("ui/Ui.zig");
const tree = @import("ui/Tree.zig");
const TreeList = @import("ui/widgets/TreeList.zig");
const PaneStrip = @import("ui/widgets/PaneStrip.zig");
const Popup = @import("ui/widgets/Popup.zig");

const Id = Ui.Id;
const Menu = Ui.Menu;
const Tree = tree.Tree;
const Node = tree.Node;
const TreeRow = tree.TreeRow;
const Rect = Ui.Rect;
const Color = Ui.Color;
const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// The keys tooltips name.
const new_tab_key = binding.label(&binding.defaults, .new_tab);
const close_tab_key = binding.label(&binding.defaults, .close_surface);
const split_right_key = binding.label(&binding.defaults, .{ .new_split = .right });
const split_down_key = binding.label(&binding.defaults, .{ .new_split = .down });
const zoom_key = binding.label(&binding.defaults, .toggle_split_zoom);

// Sizes in DIPs.
const sidebar_pad_x = 12;
const sidebar_pad_top = 4;
const sidebar_pad_bottom = 12;
/// Between the rows and "Connect".
const connect_gap = 10;
const connect_height = 32;
/// The frame stats sit above "Connect", in line with the section
/// headers.
const stats_gap = 10;
const header_height = 28;
const workspace_height = 28;
const tab_height = 30;
const pane_height = 28;
/// A row's buttons, from the right: the last ends this far from the
/// row's edge, with this much between buttons.
const button_margin = 5;
const button_gap = 2;
/// Between a label and the first button after it.
const label_gap = 4;

/// The tree for the app's state now.
pub fn build(app: *App, arena: Allocator) Allocator.Error!Tree {
    var b: Builder = .{ .arena = arena, .app = app, .ui = app.ui, .frame = app.frame.* };
    return b.build();
}

const Builder = struct {
    arena: Allocator,
    app: *App,
    ui: *const Ui,
    frame: Ui.Frame,

    fn nodes(self: *const Builder, items: []const Node) Allocator.Error![]Node {
        return self.arena.dupe(Node, items);
    }

    fn build(self: *Builder) Allocator.Error!Tree {
        var regions: std.ArrayList(Node) = .empty;
        try regions.append(self.arena, try self.titleBar());
        if (self.ui.sidebar_shown) try regions.append(self.arena, try self.sidebar());
        try regions.append(self.arena, try self.terminal());
        // Over both, so the edge is taken hold of before anything under it.
        if (self.ui.sidebar_shown) try regions.append(self.arena, self.sidebarEdge());
        if (self.dialog()) |d| try regions.append(self.arena, d);
        // A menu is over everything: the window under it is its scrim,
        // which takes the click that closes it.
        if (self.app.mode == .menu) {
            try regions.append(self.arena, .{ .id = .window(.scrim), .kind = .hit_area, .rect = self.frame.window });
            try regions.append(self.arena, self.menu(&self.app.mode.menu));
        }
        return .{
            .root = .{ .kind = .{ .canvas = regions.items } },
            .frame = self.frame,
            .drag = self.drag(),
        };
    }

    /// The app icon, the sidebar toggle, the active tab's title, and the
    /// caption buttons. The bar itself is the caption, which moves the
    /// window.
    fn titleBar(self: *const Builder) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        const title: []const u16 = if (app.hasTabs()) app.activeTab().focus.title() else &.{};
        const maximized = app.shell.maximized();
        const children = try self.nodes(&.{
            .{ .kind = .{ .spacer = 12 } },
            .{ .kind = .{ .icon = .{ .icon = null, .size = 18 } } },
            .{ .kind = .{ .spacer = 6 } },
            .{ .id = .window(.toggle_sidebar), .kind = .{ .icon_button = .{
                .icon = .panel_left,
                .size = 20,
                .w = 40,
                .h = null,
                .style = .bar,
                .color = if (app.focused) t.text else t.text_inactive,
                .tip = if (self.ui.sidebar_shown) L("Hide sidebar") else L("Show sidebar"),
            } } },
            .{ .kind = .{ .label = .{ .text = title, .font = .title, .color = if (app.focused) t.text_muted else t.text_inactive, .pad_x = 8 } } },
            self.captionButton(.minimize, maximized),
            self.captionButton(.maximize, maximized),
            self.captionButton(.close, maximized),
        });
        return .{ .id = .window(.caption), .kind = .{ .row = .{ .children = children, .bg = t.ground } }, .rect = self.frame.titlebar };
    }

    fn captionButton(self: *const Builder, part: Id.Part, maximized: bool) Node {
        return .{ .id = .window(part), .kind = .{ .caption_button = .{ .part = part, .maximized = maximized, .focused = self.app.focused } } };
    }

    /// The sections, "Connect" (or the host field) under them, and the
    /// frame stats over the rows' bottom when built with them.
    fn sidebar(self: *const Builder) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        const connect: Node = switch (app.mode) {
            .connect => |*f| .{ .id = .window(.connect), .kind = .{ .text_field = .{
                .field = f,
                .placeholder = L("user@host:port"),
                .caret = app.focused and app.blink_visible,
                .h = connect_height,
            } } },
            else => .{ .id = .window(.connect), .kind = .{ .button = .{ .label = L("Connect…"), .icon = .plug, .h = connect_height } } },
        };
        const column: Node = .{ .kind = .{ .column = .{
            .children = try self.nodes(&.{
                .{ .kind = .{ .tree = .{ .rows = try self.sections() } }, .clip = true },
                .{ .kind = .{ .spacer = connect_gap } },
                connect,
            }),
            .pad = .{ .left = sidebar_pad_x, .right = sidebar_pad_x, .top = sidebar_pad_top, .bottom = sidebar_pad_bottom },
            .bg = t.ground,
        } } };
        const stats = app.shell.stats();
        if (stats.len == 0) {
            var alone = column;
            alone.rect = self.frame.sidebar;
            return alone;
        }
        const stats_column: Node = .{ .kind = .{ .column = .{
            .children = try self.nodes(&.{.{ .kind = .{ .lines = .{ .text = stats, .font = .mono, .color = t.text_muted } } }}),
            .pad = .{ .left = sidebar_pad_x + 2, .right = sidebar_pad_x, .bottom = sidebar_pad_bottom + connect_height + stats_gap },
            .justify = .end,
        } } };
        return .{ .kind = .{ .stack = try self.nodes(&.{ column, stats_column }) }, .rect = self.frame.sidebar };
    }

    /// The strip astride the sidebar's edge that drags its width: over
    /// the sidebar's padding and the terminal area's gap, nothing drawn.
    fn sidebarEdge(self: *const Builder) Node {
        const grip = self.ui.px(Ui.sidebar_edge_grip);
        const s = self.frame.sidebar;
        return .{ .id = .window(.sidebar_edge), .kind = .hit_area, .rect = .{ .x = s.right() - grip, .y = s.y, .w = 2 * grip, .h = s.h } };
    }

    /// Local, then each remembered host: each with its daemon's
    /// workspaces and then its tabs in no workspace (there while slime
    /// couldn't be reached, or standing in for a host's panes).
    fn sections(self: *const Builder) Allocator.Error![]TreeRow {
        const app = self.app;
        var rows: std.ArrayList(TreeRow) = .empty;
        const local = try self.sectionRows(0);
        try rows.append(self.arena, .{ .node = try self.header(.local, L("Local"), .local), .children = local, .section = true });
        for (app.hosts.items.items, 0..) |dest, h| {
            const children = try self.sectionRows(1 + h);
            const kind: HostKind = if (app.hostLive(h)) .connected else .disconnected;
            try rows.append(self.arena, .{ .node = try self.header(.{ .host = @intCast(h) }, Hosts.label(dest), kind), .children = children, .section = true });
        }
        return rows.items;
    }

    /// Section `s`'s rows: its workspaces, then its tabs in none.
    fn sectionRows(self: *const Builder, s: usize) Allocator.Error![]TreeRow {
        const app = self.app;
        var rows: std.ArrayList(TreeRow) = .empty;
        for (app.workspaces.items) |w| {
            if (app.sectionOf(w.conn) == s) try rows.append(self.arena, try self.workspaceRow(w));
        }
        const none = app.noneGroup(s);
        for (app.tabs.items) |t| {
            if (app.groupOf(t) == none) try rows.append(self.arena, try self.tabRow(t));
        }
        return rows.items;
    }

    const HostKind = enum {
        local,
        /// A host with a live connection, which new tabs join.
        connected,
        /// A remembered host that new tabs connect to.
        disconnected,
    };

    /// A section's header: its name in capitals, with a button at the
    /// right that makes a workspace on its daemon (a plug that connects
    /// a host first); a host nothing uses gets one to forget it while the
    /// mouse is over the header.
    fn header(self: *const Builder, target: Id.Target, label: []const u16, kind: HostKind) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        const id: Id = .{ .target = target };
        var items: std.ArrayList(Node) = .empty;
        try items.append(self.arena, .{ .kind = .{ .spacer = 2 } });
        try items.append(self.arena, .{ .kind = .{ .label = .{ .text = label, .font = .section, .color = t.text_muted, .upper = true } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
        // A host nothing uses can be dropped from the list.
        if (kind != .local and !app.hostInUse(target.host) and self.ui.hover.on(target)) {
            // Lucide's x spans 12 of its 24 units: 8 DIPs in this box.
            try items.append(self.arena, .{ .id = id.with(.forget), .kind = .{ .icon_button = .{ .icon = .x, .size = 16, .tip = L("Forget host") } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_gap } });
        }
        const none: []const u16 = &.{};
        const tip, const key = switch (kind) {
            .local => if (app.sectionCount(0) > 0)
                .{ L("New workspace"), none }
            else
                .{ L("New tab"), if (self.activeGroupIs(target)) new_tab_key.slice() else none },
            .disconnected => .{ L("Connect"), none },
            .connected => .{ L("New workspace"), none },
        };
        try items.append(self.arena, if (kind == .disconnected)
            // Lucide's plug spans 16 of its 24 units: 11 DIPs in this box,
            // about the plus's size. Its prongs land on pixel edges at
            // this size, so a half pixel moves them onto centers.
            .{ .id = id.with(.new_tab), .kind = .{ .icon_button = .{ .icon = .plug, .size = 16, .dx = 0.5, .tip = tip, .key = key } } }
        else
            // Lucide's plus spans 14 of its 24 units: 10 DIPs in this
            // box, whose odd size centers the lines on pixels.
            .{ .id = id.with(.new_tab), .kind = .{ .icon_button = .{ .icon = .plus, .size = 17, .tip = tip, .key = key } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        return .{ .id = id, .kind = .{ .row = .{ .children = items.items, .h = header_height } } };
    }

    /// Whether the active tab is in the group `target` names: a
    /// section's tabs in no workspace, or a workspace.
    fn activeGroupIs(self: *const Builder, target: Id.Target) bool {
        const app = self.app;
        if (!app.hasTabs()) return false;
        const g = app.groupOf(app.activeTab());
        return switch (target) {
            .local => g == app.noneGroup(0),
            .host => |h| g == app.noneGroup(1 + h),
            .workspace => |key| app.workspaceGroup(key) == g,
            else => false,
        };
    }

    /// Workspace `w`'s row: a fold arrow (its tabs are listed while
    /// shown), its name, and at the right a button to open a tab in it,
    /// before which a hidden workspace shows how many tabs it has, and
    /// one other windows show, an eye. Hiding, renaming, and killing it
    /// are in its context menu. Being renamed, the row is the field.
    fn workspaceRow(self: *const Builder, w: App.Workspace) Allocator.Error!TreeRow {
        const app = self.app;
        const t = &self.ui.theme;
        const target: Id.Target = .{ .workspace = w.key };
        const id: Id = .{ .target = target };
        const group = app.workspaceGroup(w.key);
        var tabs: std.ArrayList(TreeRow) = .empty;
        for (app.tabs.items) |tab| {
            if (app.groupOf(tab) == group) try tabs.append(self.arena, try self.tabRow(tab));
        }

        if (app.mode == .rename and app.mode.rename.ws == w.key) {
            const children = try self.nodes(&.{
                .{ .kind = .{ .fold = .{ .folded = !w.shown, .color = t.text_muted } } },
                .{ .id = id.with(.field), .kind = .{ .text_field = .{
                    .field = &app.mode.rename.field,
                    .placeholder = L("Workspace name"),
                    .caret = app.focused and app.blink_visible,
                } } },
            });
            return .{
                .node = .{ .id = id.with(.field), .kind = .{ .row = .{ .children = children, .h = workspace_height } } },
                .children = tabs.items,
                .folded = !w.shown,
            };
        }

        const hovered = self.ui.hover.on(target);
        const text = if (hovered) t.text_strong else if (w.shown) t.text_muted else t.text_inactive;
        var items: std.ArrayList(Node) = .empty;
        try items.append(self.arena, .{ .kind = .{ .fold = .{ .folded = !w.shown, .color = text } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
        try items.append(self.arena, .{ .kind = .{ .label = .{ .text = w.name, .font = .body_strong, .color = text } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
        if (!w.shown and w.tabs > 0) {
            try items.append(self.arena, .{ .kind = .{ .label = .{ .text = try self.number(w.tabs), .color = t.text_inactive, .width = .{ .fit = 4 } } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_gap } });
        }
        const others = w.viewers -| @intFromBool(w.shown);
        if (others > 0) {
            // Lucide's eye spans 18 of its 24 units: about 13 DIPs in
            // this box.
            try items.append(self.arena, .{ .kind = .{ .icon = .{ .icon = .eye, .size = 17, .box = 20, .color = t.text_muted } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_gap } });
        }
        const key: []const u16 = if (self.activeGroupIs(target)) new_tab_key.slice() else &.{};
        try items.append(self.arena, .{ .id = id.with(.new_tab), .kind = .{ .icon_button = .{ .icon = .plus, .size = 17, .tip = L("New tab"), .key = key } } });
        try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        return .{
            .node = .{ .id = id, .kind = .{ .row = .{
                .children = items.items,
                .h = workspace_height,
                .bg = if (self.ui.hover.eql(id)) t.row_hover else null,
                .radius = 6,
            } } },
            .children = tabs.items,
            .folded = !w.shown,
        };
    }

    /// `n` as text.
    fn number(self: *const Builder, n: usize) Allocator.Error![]const u16 {
        var buf: [20]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
        const units = try self.arena.alloc(u16, digits.len);
        for (digits, units) |d, *u| u.* = d;
        return units;
    }

    /// A tab's row: a fold arrow for its panes, its icon and title, and
    /// at the right its close button while the mouse is over it; else an
    /// activity dot, or folded, its panes' most pressing status.
    fn tabRow(self: *const Builder, tab: *Tab) Allocator.Error!TreeRow {
        const app = self.app;
        const t = &self.ui.theme;
        const target: Id.Target = .{ .tab = tab.key };
        const id: Id = .{ .target = target };
        const active = app.hasTabs() and app.activeTab() == tab;
        const hovered = self.ui.hover.on(target);
        var items: std.ArrayList(Node) = .empty;
        // The fold arrow and the icon in a row of their own, so the title
        // starts at their DIPs rounded once: rounded one by one they can
        // land it a pixel off.
        try items.append(self.arena, .{
            .kind = .{
                .row = .{
                    .w = TreeList.fold_width + 24,
                    .children = try self.nodes(&.{
                        .{ .id = id.with(.fold), .kind = .{ .fold = .{
                            .folded = tab.folded,
                            .color = if (self.ui.hover.eql(id.with(.fold))) t.text_strong else t.text_muted,
                        } } },
                        // Lucide's panels-top-left spans 18 of its 24 units: 12 DIPs
                        // here.
                        .{ .kind = .{ .icon = .{ .icon = .panels_top_left, .size = 16, .color = if (active) t.text_strong else t.text_muted } } },
                    }),
                },
            },
        });
        try items.append(self.arena, .{ .kind = .{ .label = .{
            .text = tab.focus.title(),
            .font = if (active) .body_strong else .body,
            .color = if (active) t.text_strong else t.text_muted,
        } } });
        // Folded, its panes' most pressing status stands in for theirs.
        const folded_status = if (tab.folded) mostPressing(tab) else null;
        if (hovered) {
            try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
            // Lucide's x spans 12 of its 24 units: 8 DIPs in this box.
            try items.append(self.arena, .{ .id = id.with(.close), .kind = .{ .icon_button = .{
                .icon = .x,
                .size = 16,
                .tip = L("Close tab"),
                .key = if (active) close_tab_key.slice() else &.{},
            } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        } else if (folded_status) |status| {
            try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
            try items.append(self.arena, .{ .kind = .{ .status = .{ .status = status, .spinner = app.spinner_step } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        } else if (tab.activity()) {
            try items.append(self.arena, .{ .kind = .{ .spacer = label_gap } });
            try items.append(self.arena, .{ .kind = .{ .status = .{ .status = null, .activity = true } } });
            try items.append(self.arena, .{ .kind = .{ .spacer = button_margin } });
        } else {
            try items.append(self.arena, .{ .kind = .{ .spacer = 8 } });
        }
        var panes: std.ArrayList(TreeRow) = .empty;
        var it = tab.iterator();
        while (it.next()) |s| try panes.append(self.arena, try self.paneRow(tab, s, active));
        return .{
            .node = .{
                .id = id,
                .kind = .{
                    .row = .{
                        .children = items.items,
                        .h = tab_height,
                        // The active tab is told by its brighter text, and its
                        // focused pane's highlight; folded, it keeps the
                        // highlight itself.
                        .bg = if (hovered or (active and tab.folded)) t.row_hover else null,
                        .radius = 6,
                    },
                },
            },
            .children = panes.items,
            .folded = tab.folded,
        };
    }

    /// A pane's row under its tab: its icon and title, and what its
    /// programs report at its right.
    fn paneRow(self: *const Builder, tab: *const Tab, s: *Session, tab_active: bool) Allocator.Error!TreeRow {
        const t = &self.ui.theme;
        const id: Id = .{ .target = .{ .pane = s.id } };
        const focused = tab_active and s == tab.focus;
        const children = try self.nodes(&.{
            .{ .kind = .{ .spacer = 6 } },
            .{ .kind = .{ .icon = .{ .icon = .terminal, .size = 14, .color = if (focused) t.accent else t.text_muted } } },
            .{ .kind = .{ .spacer = 8 } },
            .{ .kind = .{ .label = .{ .text = s.title(), .color = if (focused) t.text_strong else t.text_muted } } },
            .{ .kind = .{ .spacer = label_gap } },
            .{ .kind = .{ .status = .{
                .status = if (s.statusSummary()) |summary| summary.state else null,
                .activity = s.activity,
                .spinner = self.app.spinner_step,
            } } },
            .{ .kind = .{ .spacer = button_margin } },
        });
        return .{ .node = .{ .id = id, .kind = .{ .row = .{
            .children = children,
            .h = pane_height,
            .bg = if (focused or self.ui.hover.eql(id)) t.row_hover else null,
            .radius = 6,
        } } } };
    }

    /// The active tab's panes where the placement put them, each with
    /// its buttons, and the gaps between them; with nothing shown, what
    /// the sidebar is for.
    fn terminal(self: *const Builder) Allocator.Error!Node {
        const app = self.app;
        const t = &self.ui.theme;
        var items: std.ArrayList(Node) = .empty;
        if (app.hasTabs()) {
            const tab = app.activeTab();
            const several = tab.count() > 1;
            for (app.placed().panes.items) |p| {
                const s = p.session;
                const id: Id = .{ .target = .{ .pane = s.id } };
                const focused = s == tab.focus;
                try items.append(self.arena, .{ .id = id.with(.terminal), .kind = .{ .pane = .{
                    .title = s.title(),
                    .focused = focused,
                    .dot = several and focused,
                    .dimmed = several and !focused,
                    .bg = toColor(s.cells.default_bg),
                    .buttons = try self.paneButtons(id, s, tab, p.frame.w, several),
                } }, .rect = p.frame });
            }
            for (app.placed().dividers.items, 0..) |d, i| {
                try items.append(self.arena, .{ .id = .{ .target = .{ .divider = @intCast(i) } }, .kind = .hit_area, .rect = d.rect });
            }
        } else {
            const area = self.frame.terminal;
            const h = self.ui.px(20);
            try items.append(self.arena, .{ .kind = .{ .label = .{
                .text = if (self.ui.sidebar_shown) L("Show a workspace from the list, or make one.") else L("No tabs. Show the sidebar to pick a workspace."),
                .font = .title,
                .color = t.text_inactive,
            } }, .rect = .{ .x = area.x, .y = area.y + @round((area.h - h) / 2), .w = area.w, .h = h } });
        }
        return .{ .kind = .{ .canvas = items.items }, .rect = self.frame.terminal, .clip = true };
    }

    /// A pane's buttons: split right and down, and zoom while the tab
    /// has several panes, if it runs in slime and is wide enough to hold
    /// them with room for some title.
    fn paneButtons(self: *const Builder, id: Id, s: *const Session, tab: *const Tab, frame_w: f32, several: bool) Allocator.Error![]Node {
        if (s.daemonPane() == null) return &.{};
        const parts: []const Id.Part = if (several) &.{ .split_right, .split_down, .zoom } else &.{ .split_right, .split_down };
        if (!PaneStrip.fits(self.ui, frame_w, parts.len)) return &.{};
        const focused = s == tab.focus;
        const zoomed = tab.zoom == s;
        const buttons = try self.arena.alloc(Node, parts.len);
        for (buttons, parts) |*b, part| {
            const none: []const u16 = &.{};
            const icon: Painter.Lucide, const tip: []const u16, const key: []const u16 = switch (part) {
                .split_right => .{ .columns_2, L("Split right"), if (focused) split_right_key.slice() else none },
                .split_down => .{ .rows_2, L("Split down"), if (focused) split_down_key.slice() else none },
                .zoom => .{ if (zoomed) .minimize_2 else .maximize_2, if (zoomed) L("Unzoom") else L("Zoom"), if (focused) zoom_key.slice() else none },
                else => unreachable,
            };
            // Each spans 18 of its 24 units: 10 DIPs in this box, whose
            // odd size centers the split's middle line on a pixel.
            b.* = .{ .id = id.with(part), .kind = .{ .icon_button = .{ .icon = icon, .size = 13, .style = .faint, .tip = tip, .key = key } } };
        }
        return buttons;
    }

    /// The kill dialog, or the active session's login, over the
    /// terminal area.
    fn dialog(self: *const Builder) ?Node {
        const app = self.app;
        const focus_session = app.focusedSession();
        const d: *const Ui.Dialog = switch (app.mode) {
            .confirm => |*c| &c.dialog,
            else => if (focus_session) |s| (if (s.login) |l| &l.dialog else return null) else return null,
        };
        return .{ .id = .window(.scrim), .kind = .{ .dialog = .{
            .dialog = d,
            .caret = app.focused and app.blink_visible,
            .spinner = app.spinner_step,
            .terminal_bg = if (focus_session) |s| toColor(s.cells.default_bg) else self.ui.theme.ground,
        } }, .rect = self.frame.terminal };
    }

    /// The open context menu's box, by its anchor, inside the window.
    fn menu(self: *const Builder, m: *const Menu) Node {
        const size = Popup.size(self.ui, m);
        return .{ .id = .window(.menu), .kind = .{ .menu = .{ .menu = m } }, .rect = Popup.place(self.ui, m, self.frame.window, size) };
    }

    /// A pane being dragged, once the mouse has moved enough.
    fn drag(self: *const Builder) ?Tree.Drag {
        const d = self.app.pane_drag orelse return null;
        const at = d.at orelse return null;
        return .{
            .source = if (self.app.placed().find(d.source)) |p| p.frame else null,
            .drop = if (d.drop) |drop| drop.rect else null,
            .mouse = .{ .x = @floatFromInt(at.x), .y = @floatFromInt(at.y) },
        };
    }
};

/// The most pressing status among a tab's panes: waiting on the user,
/// then failed, working, and done. Null if none has one worth showing.
fn mostPressing(tab: *const Tab) ?ProgramStatus.State {
    var best: ?ProgramStatus.State = null;
    var best_rank: u8 = 0;
    var it = tab.iterator();
    while (it.next()) |s| {
        const summary = s.statusSummary() orelse continue;
        const r: u8 = switch (summary.state) {
            .idle => continue,
            .done => 1,
            .working => 2,
            .failed => 3,
            .blocked => 4,
        };
        if (r > best_rank) {
            best = summary.state;
            best_rank = r;
        }
    }
    return best;
}

fn toColor(c: ghostty_vt.color.RGB) Color {
    return Painter.rgb(@as(u24, c.r) << 16 | @as(u24, c.g) << 8 | c.b);
}

test "sections and their rows come in the sidebar's order, by id" {
    var shell: App.TestShell = .{};
    var t: App.TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const k10 = try t.workspace(10, L("alpha"), 3, 1, false);
    const k11 = try t.workspace(11, L("beta"), 0, 2, true);
    _ = try app.hosts.add(L("ssh://devbox"));

    const built = app.view();
    const local = Ui.find(built, .{ .target = .local }).?;
    const hidden = Ui.find(built, .{ .target = .{ .workspace = k10 } }).?;
    const shown = Ui.find(built, .{ .target = .{ .workspace = k11 } }).?;
    const host = Ui.find(built, .{ .target = .{ .host = 0 } }).?;
    // Local's header, its workspaces flush under it, then the host.
    try std.testing.expectEqual(t.frame.sidebar.x + sidebar_pad_x, local.rect.x);
    try std.testing.expectEqual(t.frame.sidebar.y + sidebar_pad_top, local.rect.y);
    try std.testing.expectEqual(local.rect.bottom(), hidden.rect.y);
    try std.testing.expectEqual(local.rect.x, hidden.rect.x);
    try std.testing.expectEqual(hidden.rect.bottom() + TreeList.row_gap, shown.rect.y);
    try std.testing.expectEqual(shown.rect.bottom() + TreeList.row_gap + TreeList.section_gap, host.rect.y);
    // Each has its tab button; the host, not yet connected, a plug.
    try std.testing.expect(Ui.find(built, .{ .target = .{ .workspace = k10 }, .part = .new_tab }) != null);
    try std.testing.expectEqual(Painter.Lucide.plug, Ui.find(built, .{ .target = .{ .host = 0 }, .part = .new_tab }).?.kind.icon_button.icon);
    try std.testing.expectEqual(Painter.Lucide.plus, Ui.find(built, .{ .target = .local, .part = .new_tab }).?.kind.icon_button.icon);
    // A host nothing uses can be forgotten, once the mouse is over it.
    try std.testing.expect(Ui.find(built, .{ .target = .{ .host = 0 }, .part = .forget }) == null);
    app.ui.hover = .{ .target = .{ .host = 0 } };
    try std.testing.expect(Ui.find(app.view(), .{ .target = .{ .host = 0 }, .part = .forget }) != null);
    // A workspace's row lights under the mouse, with no buttons but its
    // tab button: its actions are in its menu.
    app.ui.hover = .{ .target = .{ .workspace = k11 } };
    const lit = app.view();
    try std.testing.expect(Ui.find(lit, .{ .target = .{ .workspace = k11 }, .part = .kill }) == null);
    try std.testing.expect(Ui.find(lit, .{ .target = .{ .workspace = k11 }, .part = .hide }) == null);
    // Hit testing finds the row and its button where they are.
    const plus = Ui.find(lit, .{ .target = .{ .workspace = k11 }, .part = .new_tab }).?;
    try std.testing.expectEqual(Id{ .target = .{ .workspace = k11 }, .part = .new_tab }, app.ui.hitTest(lit, plus.rect.x + 1, plus.rect.y + 1));
    // (`shown` was in the tree before this one, which the arena dropped.)
    const shown_lit = Ui.find(lit, .{ .target = .{ .workspace = k11 } }).?;
    try std.testing.expectEqual(Id{ .target = .{ .workspace = k11 } }, app.ui.hitTest(lit, shown_lit.rect.x + 25, shown_lit.rect.y + 2));
    try std.testing.expectEqual(Id.window(.connect), app.ui.hitTest(lit, t.frame.sidebar.x + 20, t.frame.sidebar.bottom() - sidebar_pad_bottom - 5));
    // With nothing shown, the terminal area says what the sidebar is for.
    try std.testing.expectEqual(Id.none, app.ui.hitTest(lit, t.frame.terminal.x + 100, t.frame.terminal.y + 100));
}

test "a context menu is over everything, and the window under it is scrim" {
    var shell: App.TestShell = .{};
    var t: App.TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const key = try t.workspace(5, L("alpha"), 0, 1, true);
    var m: Menu = .{ .target = .{ .workspace = key }, .anchor = .{ .point = .{ .x = 100, .y = 100 } } };
    m.add(.{ .label = L("New tab"), .action = .{ .part = .new_tab } });
    m.add(.{ .label = L("Kill"), .action = .{ .part = .kill }, .danger = true });
    app.mode = .{ .menu = m };
    const built = app.view();
    const box = Ui.find(built, .window(.menu)).?;
    try std.testing.expectEqual(@as(f32, 100), box.rect.x);
    try std.testing.expectEqual(@as(f32, 100), box.rect.y);
    try std.testing.expectEqual(Id{ .target = .{ .menu = 0 } }, app.ui.hitTest(built, box.rect.x + 20, box.rect.y + 10));
    try std.testing.expectEqual(Id{ .target = .{ .menu = 1 } }, app.ui.hitTest(built, box.rect.x + 20, box.rect.bottom() - 10));
    // The row it's about, and the title bar, are under the scrim.
    const row = Ui.find(built, .{ .target = .{ .workspace = key } }).?;
    try std.testing.expectEqual(Id.window(.scrim), app.ui.hitTest(built, row.rect.x + 2, row.rect.y + 2));
    try std.testing.expectEqual(Id.window(.scrim), app.ui.hitTest(built, 500, 5));
}

test "a workspace being renamed is all field" {
    var shell: App.TestShell = .{};
    var t: App.TestApp = .{ .hosts = undefined, .shown = undefined, .ui = undefined, .frame = undefined };
    try t.init(&shell);
    defer t.deinit();
    const app = &t.app;
    const key = try t.workspace(5, L("alpha"), 0, 1, true);
    app.mode = .{ .rename = .{ .ws = key, .field = .{} } };
    const built = app.view();
    const field_id: Id = .{ .target = .{ .workspace = key }, .part = .field };
    const row = Ui.find(built, field_id).?;
    try std.testing.expectEqual(field_id, app.ui.hitTest(built, row.rect.x + 2, row.rect.y + 2));
    try std.testing.expectEqual(field_id, app.ui.hitTest(built, row.rect.right() - 10, row.rect.y + 5));
    try std.testing.expect(Ui.find(built, .{ .target = .{ .workspace = key }, .part = .new_tab }) == null);
}
