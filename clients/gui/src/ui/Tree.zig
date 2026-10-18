//! The widget tree a frame is drawn from. `view.zig` builds one from the
//! app's state each frame, in an arena, out of generic widgets: a node is
//! an `Id` for what it's about, a `Kind` for what it is, and, once `Ui`
//! has laid the tree out, where it is. Containers place their children;
//! leaves draw themselves. Nothing here knows about tabs or workspaces:
//! the builder picks the widgets, and `Ui.widgets` lays out, hit-tests,
//! and paints them.
const std = @import("std");
const Id = @import("Id.zig");
const Painter = @import("../renderer/Painter.zig");
const TextField = @import("TextField.zig");
const Dialog = @import("Dialog.zig");
const ProgramStatus = @import("../ProgramStatus.zig");
const Ui = @import("Ui.zig");

pub const Rect = Painter.Rect;
pub const Color = Painter.Color;

pub const Tree = struct {
    root: Node,
    /// The window's regions the tree was built for.
    frame: Ui.Frame,
    /// A pane being dragged by its title strip, drawn over the frame.
    drag: ?Drag = null,

    pub const Drag = struct {
        /// Where the pane is, while it's on screen: dimmed, and copied
        /// for the picture by the mouse.
        source: ?Rect,
        /// Where it would land, highlighted.
        drop: ?Rect = null,
        /// The mouse, once it's moved enough to drag.
        mouse: ?struct { x: f32, y: f32 } = null,
    };
};

pub const Node = struct {
    /// What the node is about, and which control; `.none` for nodes the
    /// mouse passes through to their parent (an icon in a row).
    id: Id = .none,
    kind: Kind,
    /// Where it is, in client pixels: set by layout, or by the builder
    /// for a `canvas`'s children.
    rect: Rect = .{},
    /// Its children are clipped to it.
    clip: bool = false,
};

/// What a parent is told a node wants: a side is null where the node
/// takes what it's given (a label's width, a button's height in a row).
/// In pixels.
pub const Size = struct { w: ?f32 = null, h: ?f32 = null };

/// Space inside a container, in DIPs.
pub const Insets = struct { left: f32 = 0, right: f32 = 0, top: f32 = 0, bottom: f32 = 0 };

/// A text format of the UI's (`Ui.Fonts`).
pub const Font = enum { body, body_strong, title, section, hint, tip, mono, heading, prose, mono_prose, button, button_strong };

pub const Kind = union(enum) {
    /// Children top to bottom; those with no height share what's left.
    column: Column,
    /// Children left to right; those with no width share what's left.
    /// Children with a height are centered on the row's.
    row: Row,
    /// Children one over another, each the whole rect.
    stack: []Node,
    /// Children where the builder put them (`Node.rect`).
    canvas: []Node,
    /// Empty space this many DIPs along a row or column.
    spacer: f32,
    /// Nothing drawn: a place the mouse can be over, like a divider.
    hit_area,
    label: Label,
    /// Lines of text, one under another.
    lines: Lines,
    icon: Icon,
    icon_button: IconButton,
    button: Button,
    text_field: TextFieldView,
    /// What a pane's programs report, or an activity dot.
    status: Status,
    /// A fold arrow: down while open, right while folded.
    fold: Fold,
    /// Rows under rows, with fold-away children joined by guides.
    tree: TreeList,
    /// A pane's chrome in the terminal area: its title strip over the
    /// terminal the renderer draws.
    pane: Pane,
    /// A dialog over the terminal area, which it dims.
    dialog: DialogView,
    /// The title bar's minimize, maximize, and close.
    caption_button: CaptionButton,
};

pub const Column = struct {
    children: []Node,
    /// Between children, in DIPs.
    gap: f32 = 0,
    pad: Insets = .{},
    /// Children packed to the top, or to the bottom.
    justify: enum { start, end } = .start,
    bg: ?Color = null,
};

pub const Row = struct {
    children: []Node,
    gap: f32 = 0,
    pad: Insets = .{},
    /// Its width, in DIPs; none takes its children's, or what it's
    /// given. Set, the children after it start at that offset rounded
    /// once, not at the sum of their widths rounded one by one.
    w: ?f32 = null,
    /// Its height, in DIPs; none takes its tallest child's, or what
    /// it's given.
    h: ?f32 = null,
    bg: ?Color = null,
    /// The background's corners, in DIPs.
    radius: f32 = 0,
};

pub const Label = struct {
    text: []const u16,
    font: Font = .body,
    color: Color,
    /// Space before and after the text, in DIPs.
    pad_x: f32 = 0,
    /// Drawn in capitals, as section headers are.
    upper: bool = false,
    width: ?Width = null,

    pub const Width = union(enum) {
        dip: f32,
        /// The text's own width, plus this many DIPs.
        fit: f32,
    };
};

pub const Lines = struct {
    /// Lines end with LF.
    text: []const u16,
    font: Font = .mono,
    color: Color,
    /// Each line's height, in DIPs.
    line_height: f32 = 16,
};

pub const Icon = struct {
    /// A Lucide icon, or null for the app's.
    icon: ?Painter.Lucide,
    /// The square it's drawn in, in DIPs.
    size: f32,
    /// The square it sits in, centered, in DIPs: a row's button slot.
    /// Its own size by default.
    box: ?f32 = null,
    color: Color = .{ 0, 0, 0, 1 },
    /// Moved right this many pixels, where an icon's lines land on pixel
    /// edges at its size.
    dx: f32 = 0,
};

pub const IconButton = struct {
    icon: Painter.Lucide,
    /// The square the icon is drawn in, in DIPs.
    size: f32,
    /// The button's own size, in DIPs; no height takes the row's.
    w: f32 = 20,
    h: ?f32 = 20,
    style: Style = .row,
    /// Overrides for the icon's color at rest and under the mouse; by
    /// default the theme's for the style.
    color: ?Color = null,
    hover_color: ?Color = null,
    dx: f32 = 0,
    /// What its tooltip says, and the key that does the same, if any.
    /// No tip for an empty one.
    tip: []const u16 = &.{},
    key: []const u16 = &.{},

    pub const Style = enum {
        /// In a list row: a rounded background under the mouse, the
        /// icon muted at rest and strong under the mouse.
        row,
        /// In a bar: the whole button fills under the mouse, the icon's
        /// color as given.
        bar,
        /// Over a pane: no background; faint at rest, solid under the
        /// mouse.
        faint,
    };
};

/// A wide button with a label after an optional icon, like "Connect".
pub const Button = struct {
    label: []const u16,
    icon: ?Painter.Lucide = null,
    /// Its height, in DIPs.
    h: f32 = 32,
};

pub const TextFieldView = struct {
    field: *const TextField,
    placeholder: []const u16 = &.{},
    /// The caret shows: the field has the keyboard, in the on phase of
    /// the blink.
    caret: bool,
    /// Its height, in DIPs; none takes the row's.
    h: ?f32 = null,
};

pub const Status = struct {
    status: ?ProgramStatus.State,
    /// Output arrived while the pane wasn't shown: a dot, when there's
    /// no status to show.
    activity: bool = false,
    /// Steps of the spinner while working.
    spinner: u32 = 0,
};

pub const Fold = struct {
    folded: bool,
    color: Color,
};

pub const TreeList = struct {
    rows: []TreeRow,
};

/// A row of a `TreeList`, with the rows under it.
pub const TreeRow = struct {
    /// The row itself, usually a `row`; its height is its measure's.
    node: Node,
    children: []TreeRow = &.{},
    /// Its children aren't shown.
    folded: bool = false,
    /// A section header: its children sit flush under it with no guide,
    /// nothing comes between it and them, and a gap sets it off from the
    /// section before.
    section: bool = false,
};

pub const Pane = struct {
    title: []const u16,
    /// It gets the keys: its title is strong, and a dot marks it while
    /// `dot`.
    focused: bool,
    /// Several panes share the tab: the focused one gets a dot.
    dot: bool = false,
    /// Another pane has focus: covered with its own background, faintly.
    dimmed: bool = false,
    /// Its terminal's default background.
    bg: Color,
    /// Its buttons at the right of the strip, left to right.
    buttons: []Node = &.{},
};

pub const DialogView = struct {
    dialog: *const Dialog,
    /// The focused field's caret shows.
    caret: bool,
    /// Steps of the spinner while waiting.
    spinner: u32,
    /// The terminal's default background, behind the detail box and
    /// disabled fields.
    terminal_bg: Color,
};

pub const CaptionButton = struct {
    /// `.minimize`, `.maximize`, or `.close`.
    part: Id.Part,
    maximized: bool,
    /// The window has keyboard focus: the glyph isn't dimmed.
    focused: bool,
};
