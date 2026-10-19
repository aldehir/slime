//! What a point in the window is over, and what a widget is: a `Target`,
//! the thing in the window's model the widget is about, and a `Part`,
//! which of its controls. `Ui` emits ids from hit testing and keeps the
//! mouse's state (hover, pressed, tooltip) as ids; the app acts on them
//! by looking the target up in its model, so rows can reorder under the
//! mouse without a click landing on the wrong one.
const Id = @This();

const std = @import("std");

target: Target,
part: Part = .body,

/// Nothing: empty space, or no widget.
pub const none: Id = .{ .target = .none };

/// The model object a widget is about. Workspaces, tabs, and panes are
/// keyed by numbers the window hands out, not the daemon's ids: each
/// slime (the local one, and each host's) numbers its own, so those
/// repeat across connections in one window.
pub const Target = union(enum) {
    none,
    /// The window itself: the title bar and its buttons, the dialog's
    /// scrim, "Connect".
    window,
    /// The Local section's header.
    local,
    /// A remembered SSH host, by its place in the hosts list: a host that
    /// isn't connected has no id from the daemon.
    host: u32,
    /// A workspace of the local daemon or a host's, by `App.Workspace.key`.
    workspace: u32,
    /// A tab, by `Tab.key`.
    tab: u32,
    /// A pane, by its session's id, in the sidebar's rows and in the
    /// terminal area.
    pane: u32,
    /// The gap between two panes of the active tab, by its place in the
    /// tab's dividers from the last layout.
    divider: u16,
    /// A corner where the active tab's dividers meet, by its place in the
    /// tab's corners from the last layout.
    corner: u16,
    /// A dialog's field or button, by its index.
    dialog: u8,
    /// A context menu's entry, by its index into the menu's items.
    menu: u8,
};

/// Which control of the target.
pub const Part = enum {
    /// The widget itself: a row, a pane's row in the sidebar.
    body,
    /// The title bar's empty space, which moves the window.
    caption,
    minimize,
    maximize,
    /// The caption button, or a tab's close button.
    close,
    toggle_sidebar,
    /// The sidebar's right edge, which drags its width.
    sidebar_edge,
    /// The terminal area under a dialog, away from its controls; or the
    /// window under a context menu.
    scrim,
    /// A context menu's box, between its entries.
    menu,
    /// The host field, or the button that opens it.
    connect,
    /// A row's fold arrow.
    fold,
    /// A pane's title strip in the terminal area, which drags it.
    title,
    /// A pane's terminal in the terminal area.
    terminal,
    /// A header's or row's button that opens a tab (or a workspace under
    /// a section's header, or connects a host first).
    new_tab,
    forget,
    /// A host's menu entry that hangs up on it.
    disconnect,
    kill,
    rename,
    /// A workspace's menu entries that hide it, and show it.
    hide,
    show,
    split_right,
    split_down,
    /// A pane's menu entry that splits a blank browser pane off its right.
    open_browser,
    zoom,
    /// A browser pane's history and reload buttons.
    back,
    forward,
    reload,
    /// A text field: a workspace's name being edited, a dialog's field,
    /// a browser pane's URL bar.
    field,
    /// A dialog's button.
    button,
};

pub fn eql(a: Id, b: Id) bool {
    return std.meta.eql(a, b);
}

/// The same target's `part`.
pub fn with(self: Id, part: Part) Id {
    return .{ .target = self.target, .part = part };
}

/// Whether the id is about `target`, whatever its part.
pub fn on(self: Id, target: Target) bool {
    return std.meta.eql(self.target, target);
}

/// An id of the window's `part`.
pub fn window(part: Part) Id {
    return .{ .target = .window, .part = part };
}

test "ids compare by target and part" {
    const row: Id = .{ .target = .{ .workspace = 3 } };
    try std.testing.expect(row.eql(.{ .target = .{ .workspace = 3 }, .part = .body }));
    try std.testing.expect(!row.eql(row.with(.kill)));
    try std.testing.expect(row.with(.kill).on(.{ .workspace = 3 }));
    try std.testing.expect(!row.on(.{ .workspace = 4 }));
    try std.testing.expect(!row.on(.{ .tab = 3 }));
    try std.testing.expect(none.eql(.{ .target = .none }));
    try std.testing.expect(window(.close).eql(.{ .target = .window, .part = .close }));
    try std.testing.expect(window(.close).target == .window);
}
