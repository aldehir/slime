//! One pane in a window: what slime draws of it, and the input it sends.
//! A pane is a terminal or a browser (`content`). slime runs the
//! terminal (cmd/slime); the session applies the frames slime sends to
//! its `screen`, and turns window messages into events
//! (internal/vt/event.zig) that slime handles against the terminal:
//! keys, mouse reports and selection, the wheel, pastes. A browser's
//! page is the window's; slime keeps its url and title, which the
//! session follows. Heap allocated, as the connection's reader holds a
//! pointer to it.
//!
//! The connection's reader hands the session frames and notices under
//! `lock`; the UI thread applies the frames when it draws. Mouse
//! positions are relative to the session's pane (`rect`).
const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");
const input = @import("input.zig");
const Daemon = @import("Daemon.zig");
const Web = @import("Web.zig");
const Config = @import("Config.zig");
const Login = @import("Login.zig");
const Placement = @import("Placement.zig");
const ProgramStatus = @import("ProgramStatus.zig");
const Frames = @import("Screen.zig");
const clipboard = @import("clipboard.zig");
const messages = @import("messages.zig");
const Renderer = @import("renderer/D3D11.zig");
const Cells = @import("renderer/cells.zig").Cells;
const image = @import("renderer/image.zig");
const Images = image.Images;
const Painter = @import("renderer/Painter.zig");
const Rect = Painter.Rect;

const log = std.log.scoped(.session);

const Events = Frames.Events;
const event = Frames.event;

/// libghostty-vt's limit on a title, in bytes, which is at least as
/// many UTF-16 units.
pub const max_title_len = 1024;

const MouseButton = ghostty_vt.input.MouseButton;
const MouseAction = ghostty_vt.input.MouseAction;

alloc: Allocator,
/// How the window is woken, and what it's asked.
wake: Wake,
env: Env,
/// Names the session in messages posted from other threads, which may
/// arrive after it's gone.
id: u32,

/// Shown while the program hasn't set a title: its name. Empty for a
/// browser, which goes by its url's host until its page has a title.
default_title: []const u16,
/// The program's title (OSC 0/2), or a browser's page title. Empty for
/// none. UI thread only.
title_buf: [max_title_len]u16 = undefined,
title_len: usize = 0,
/// The title as slime last said, for `titleUpdate` to take. Guarded by
/// `lock`.
next_title_buf: [max_title_len]u16 = undefined,
next_title_len: usize = 0,
/// Set while a WM_APP_TITLE_CHANGED is queued, so a program that
/// retitles rapidly posts one message rather than flooding the queue.
title_pending: std.atomic.Value(bool) = .init(false),

lock: win32.SRWLOCK = .{},

/// What fills the pane. Chosen when the session is made, and never
/// changes, so the reader may look at which it is.
content: Content,

transport: ?Transport = null,

/// The pane is gone, or never ran, and the session stays to say why
/// until a key closes it. UI thread only.
ended: bool = false,

/// The daemon pane was lost to us while its program ran (its workspace
/// was taken by another window, or slime went away). Written by the
/// connection's reader before it posts WM_APP_CHILD_EXITED.
daemon_loss: ?DaemonLoss = null,
/// The daemon pane's program exited, so there's nothing left to kill.
/// Written as `daemon_loss` is.
exited: bool = false,

/// Logging in to the SSH host, while there's something to show: a
/// question, the server working on an answer, or why it failed. Shown
/// as a dialog over the terminal. UI thread only.
login: ?*Login = null,

/// A frame arrived that the window hasn't drawn. Set by the reader
/// thread.
unseen: std.atomic.Value(bool) = .init(false),
/// A frame arrived while another session was shown. UI thread only.
activity: bool = false,

/// What programs in the session report doing (OSC 7501), as slime
/// keeps it. Guarded by `lock`.
program_status: ProgramStatus = .{},
/// `program_status` changed since the window last looked. Set by the
/// reader thread.
status_changed: std.atomic.Value(bool) = .init(false),

/// What fills a pane.
pub const Content = union(enum) {
    terminal: Terminal,
    browser: Browser,
};

/// A terminal pane's screen, and what drawing it and talking to its
/// program take.
pub const Terminal = struct {
    /// Frames slime sent that aren't applied yet, each u32 seq, u32
    /// length, then the frame. Guarded by `lock`.
    frames: std.ArrayList(u8) = .empty,
    /// What `applyFrames` swaps `frames` for, to apply them unlocked.
    applying: std.ArrayList(u8) = .empty,
    /// The pane as of the frames applied. UI thread only.
    screen: Frames.Screen = .{},
    /// The last frame applied, and the last acked. UI thread only.
    applied: u32 = 0,
    acked: u32 = 0,
    cells: Cells = .{},
    /// The kitty images slime sent and where the last frame placed them.
    /// UI thread only.
    images: Images = .{},
    textures: Renderer.ImageTextures = .{},
    /// The image slime is sending in pieces, until it's whole. Reader
    /// thread only.
    image_in: ImageIn = .{},
    /// Images received, inflated, for `applyFrames` to install before the
    /// frames that place them. Guarded by `lock`.
    pending_images: std.ArrayList(QueuedImage) = .empty,
    /// What `applyFrames` swaps `pending_images` for.
    installing: std.ArrayList(QueuedImage) = .empty,

    /// The grid the layout fits the pane (`resize`), which a screen no
    /// frames come to takes itself. Where the pane is on screen isn't the
    /// session's to know: the window's `Placement` has it.
    cols: u16 = 0,
    rows: u16 = 0,
    /// What slime was last told of the pane's size and geometry, so a
    /// layout that changes nothing sends nothing.
    sized: ?Daemon.Size = null,
    geometry: ?event.Geometry = null,

    /// The first half of a surrogate pair from a lone WM_CHAR.
    high_surrogate: ?u16 = null,

    /// The tag of the last copy asked for.
    copy_tag: u32 = 0,

    /// A clipboard write for the UI thread to make: the program's (OSC
    /// 52), or a copy's text. Writing on the reader thread could
    /// deadlock: emptying the clipboard sends a message to its previous
    /// owner, which is often us. Empty clears the clipboard. Guarded by
    /// `lock`.
    clipboard_write: ?[]u8 = null,

    fn deinit(self: *Terminal, alloc: Allocator) void {
        self.textures.deinit(alloc);
        self.cells.deinit(alloc);
        self.images.deinit(alloc);
        for (self.pending_images.items) |*q| Images.freePixels(alloc, &q.image);
        self.pending_images.deinit(alloc);
        for (self.installing.items) |*q| Images.freePixels(alloc, &q.image);
        self.installing.deinit(alloc);
        self.image_in.data.deinit(alloc);
        self.screen.deinit(alloc);
        self.frames.deinit(alloc);
        self.applying.deinit(alloc);
        if (self.clipboard_write) |text| alloc.free(text);
    }
};

/// A browser pane: where its page is. slime keeps the url and the page's
/// title (the session's `title`); the page itself, its history, and the
/// browser showing it are the window's (`view`).
pub const Browser = struct {
    /// Where the page is: as slime last said (pane.url), the URL bar
    /// sent, or the browser went. Owned. UI thread only.
    url: []u16 = &.{},
    /// The url slime last said, for `titleUpdate` to take. Owned.
    /// Guarded by `lock`.
    next_url: ?[]u16 = null,
    /// The url slime sent the page to, until the user takes it elsewhere
    /// here (`ownNavigation`): where the page lands, a redirect, is
    /// shown but reported as this, so two windows on a page that
    /// bounces to a fresh url don't send each other round. Owned. UI
    /// thread only, as `typed`.
    followed: ?[]u16 = null,
    /// The url the URL bar sent, until slime's echo of it comes, which
    /// is the user's and not followed. Owned.
    typed: ?[]u16 = null,
    /// What the strip's back, forward, and reload buttons go by, as the
    /// browser reports them.
    can_go_back: bool = false,
    can_go_forward: bool = false,
    loading: bool = false,
    /// The browser showing the page, while the pane is in the window
    /// and has one. UI thread only, as everything below.
    view: ?*Web.View = null,
    /// Why the pane has no browser, which its stand-in says, until a
    /// click asks for one again.
    failed: ?[]const u8 = null,
    /// The page's pointer, a copy the pane owns.
    cursor: ?win32.HCURSOR = null,
    /// The site's icon, which the URL bar shows (a globe without one).
    /// Owned, as `preview`.
    favicon: ?Painter.Image = null,
    /// A picture of the page, for the pane's while it's dragged.
    preview: ?Painter.Image = null,
    /// The page asked for a permission the window is asking about.
    asking: bool = false,

    fn deinit(self: *Browser, alloc: Allocator) void {
        if (self.view) |v| v.detach();
        if (self.cursor) |c| _ = win32.DestroyIcon(c);
        setImage(&self.favicon, null);
        setImage(&self.preview, null);
        alloc.free(self.url);
        if (self.next_url) |u| alloc.free(u);
        if (self.followed) |u| alloc.free(u);
        if (self.typed) |u| alloc.free(u);
    }

    /// Replace `slot`'s image with `img`, letting the old one go.
    pub fn setImage(slot: *?Painter.Image, img: ?Painter.Image) void {
        if (slot.*) |old| win32.com.release(old.bitmap);
        slot.* = img;
    }

    /// Its browser is up: the page draws over the stand-in.
    pub fn live(self: *const Browser) bool {
        const v = self.view orelse return false;
        return v.state == .ready;
    }
};

/// What a session shows.
const Transport = union(enum) {
    /// A pane slime holds, which outlives us. Its messages come from the
    /// connection's reader through our sink.
    daemon: Pane,
    /// Nothing yet: standing in for an SSH host's daemon panes until they
    /// come, logging in meanwhile. The host's destination, as the sidebar
    /// remembers it (borrowed from the window's list, which keeps a host
    /// while sessions use it).
    waiting: []const u16,
};

const Pane = struct { conn: *Daemon, pane: Daemon.PaneRef };

/// What a new session shows.
pub const Launch = union(enum) {
    /// A pane of the workspace slime keeps for this window: a terminal or
    /// a browser, as the arrival says. The arrival stays the caller's.
    daemon: struct {
        conn: *Daemon,
        arrival: *const Daemon.Arrival,
    },
    /// Nothing yet, on host `dest`: see `Transport.waiting`.
    waiting: struct {
        dest: []const u16,
        title: []const u16,
    },
    /// Nothing: why nothing can run, titled `title`.
    failed: struct {
        title: []const u16,
        why: []const u8,
    },
};

/// How the window is woken from the connection's reader thread: handles
/// and values any thread may use, so the reader never waits on the UI
/// thread. UI-thread code may use them too.
pub const Wake = struct {
    hwnd: win32.HWND,
    /// Set when a frame or program status came, for the message loop.
    output_event: win32.HANDLE,
    /// Child output fed to the terminal, counted for the stats, if built.
    bytes: ?*std.atomic.Value(u64),
    /// Whether a program may write the clipboard (OSC 52).
    /// Read on the reader thread, set on the UI thread (a reload).
    clipboard_write: std.atomic.Value(Config.ClipboardAccess),
};

pub const CellSize = struct { width: u32, height: u32 };

/// What the session asks the window on the UI thread only.
pub const Env = struct {
    config: *const Config,
    ctx: *anyopaque,
    /// The window's cell size, which every pane shares.
    cell_size: *const fn (*anyopaque) CellSize,
    /// The user typed or pasted into the session.
    on_input: *const fn (*anyopaque) void,

    fn cellSize(self: Env) CellSize {
        return self.cell_size(self.ctx);
    }

    fn input(self: Env) void {
        self.on_input(self.ctx);
    }
};

/// Why a daemon session's connection ended without its program exiting,
/// for the session to show. Set by the reader thread before it posts
/// WM_APP_CHILD_EXITED.
pub const DaemonLoss = struct {
    const text_buf_len = 256;
    text_buf: [text_buf_len]u8 = undefined,
    text_len: usize = 0,

    pub fn text(self: *const DaemonLoss) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn set(self: *DaemonLoss, comptime fmt: []const u8, args: anytype) void {
        // Too long for the buffer: keep what fit.
        self.text_len = if (std.fmt.bufPrint(&self.text_buf, fmt, args)) |s| s.len else |_| self.text_buf.len;
    }
};

/// Start showing `launch` in a new session; a terminal gets a grid of
/// `cols` x `rows`.
pub fn create(alloc: Allocator, wake: Wake, env: Env, id: u32, launch: Launch, cols: u16, rows: u16) !*Session {
    const config = env.config;
    const self = try alloc.create(Session);
    errdefer alloc.destroy(self);
    const browsing: ?*const Daemon.Arrival = switch (launch) {
        .daemon => |s| if (s.arrival.kind == .browser) s.arrival else null,
        else => null,
    };
    const default_title = try alloc.dupe(u16, switch (launch) {
        .daemon => |s| if (browsing != null)
            &.{}
            // A host's shell, which slime lists with no command, goes by
            // the host until it sets a title.
        else if (s.arrival.command.len == 0 and s.conn.host() != null)
            s.conn.hostLabel()
        else
            programName(s.arrival.command),
        .waiting => |w| w.title,
        .failed => |f| f.title,
    });
    errdefer alloc.free(default_title);
    self.* = .{
        .alloc = alloc,
        .wake = wake,
        .env = env,
        .id = id,
        .default_title = default_title,
        .content = .{ .terminal = .{ .cols = cols, .rows = rows } },
    };
    if (browsing) |a| {
        self.content = .{ .browser = .{ .url = try alloc.dupe(u16, a.url) } };
        // As slime last heard; kept as the next too, so the first url
        // that comes doesn't take it.
        self.title_len = @min(a.title.len, max_title_len);
        @memcpy(self.title_buf[0..self.title_len], a.title[0..self.title_len]);
        @memcpy(self.next_title_buf[0..self.title_len], a.title[0..self.title_len]);
        self.next_title_len = self.title_len;
    }
    errdefer self.deinitContent();
    if (self.term()) |t| {
        // Until the first frame says otherwise.
        t.screen.colors.background = config.background;
        t.screen.colors.foreground = config.foreground;
        t.screen.colors.palette = config.palette.colors;
    }

    switch (launch) {
        .daemon => |s| {
            for (s.arrival.status) |rec| {
                const state = std.enums.fromInt(ProgramStatus.State, rec.state) orelse continue;
                self.program_status.restore(rec.id, state, rec.progress);
            }
            self.transport = .{ .daemon = .{ .conn = s.conn, .pane = s.arrival.pane } };
            self.sendSettings();
            // What came while the pane waited for us goes to the sink
            // first, then what comes live.
            s.conn.adopt(s.arrival.pane, .{
                .ctx = self,
                .draw = daemonDraw,
                .image = daemonImage,
                .notice = daemonNotice,
                .copied = daemonCopied,
                .url = daemonUrl,
                .ended = daemonEnded,
            });
        },
        .waiting => |w| {
            try self.resizeScreen();
            self.transport = .{ .waiting = w.dest };
        },
        .failed => |f| {
            try self.resizeScreen();
            self.showEnded(f.why);
        },
    }
    return self;
}

pub fn destroy(self: *Session) void {
    const alloc = self.alloc;
    if (self.login) |l| l.destroy();
    self.stopTransport();
    self.deinitContent();
    alloc.free(self.default_title);
    alloc.destroy(self);
}

pub fn deinitContent(self: *Session) void {
    switch (self.content) {
        inline else => |*c| c.deinit(self.alloc),
    }
}

/// The terminal filling the pane, if a terminal does.
pub fn term(self: *Session) ?*Terminal {
    return switch (self.content) {
        .terminal => |*t| t,
        .browser => null,
    };
}

/// The browser filling the pane, if a browser does.
pub fn browser(self: *Session) ?*Browser {
    return switch (self.content) {
        .browser => |*b| b,
        .terminal => null,
    };
}

/// Let go of the pane. It runs on in slime; once released, the
/// connection's reader no longer calls our sink.
fn stopTransport(self: *Session) void {
    const transport = self.transport orelse return;
    self.transport = null;
    switch (transport) {
        .daemon => |s| s.conn.release(s.pane),
        .waiting => {},
    }
}

/// End a daemon pane for good, not just our view of it, before the
/// session is destroyed: the user closed it. Destroying alone leaves it
/// to slime, as closing the window does. A pane already lost to us is
/// left alone.
pub fn kill(self: *Session) void {
    if (self.daemon_loss != null or self.exited) return;
    switch (self.transport orelse return) {
        .daemon => |s| s.conn.kill(s.pane),
        .waiting => {},
    }
}

/// The daemon pane the session shows, while it does: not once it's
/// ended.
fn live(self: *const Session) ?Pane {
    if (self.ended) return null;
    return switch (self.transport orelse return null) {
        .daemon => |s| s,
        .waiting => null,
    };
}

/// Sink for a daemon pane's frames. On the connection's reader thread,
/// under its lock. A browser gets none.
fn daemonDraw(ctx: *anyopaque, seq: u32, data: []const u8) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const t = self.term() orelse return;
    self.lockTerminal();
    const queued = queueFrame(self.alloc, t, seq, data);
    self.unlockTerminal();
    // The screen is wrong until the next full frame.
    queued catch return log.err("dropped frame {d}: out of memory", .{seq});
    if (self.wake.bytes) |bytes| _ = bytes.fetchAdd(data.len, .monotonic);
    self.unseen.store(true, .release);
    _ = win32.SetEvent(self.wake.output_event);
}

/// Keep a frame for `applyFrames`. A full frame stands alone, so what
/// came before it goes. Call with the lock held.
fn queueFrame(alloc: Allocator, t: *Terminal, seq: u32, data: []const u8) !void {
    if (data.len == 0) return error.BadFrame;
    const flags: Frames.Flags = @bitCast(data[0]);
    if (flags.full) t.frames.clearRetainingCapacity();
    try t.frames.ensureUnusedCapacity(alloc, 8 + data.len);
    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], seq, .little);
    std.mem.writeInt(u32, head[4..8], @intCast(data.len), .little);
    t.frames.appendSliceAssumeCapacity(&head);
    t.frames.appendSliceAssumeCapacity(data);
}

/// A kitty image on its way from slime, in pieces (Daemon.ImagePiece).
const ImageIn = struct {
    id: u32 = 0,
    generation: u64 = 0,
    width: u32 = 0,
    height: u32 = 0,
    total: u32 = 0,
    /// The deflated bytes so far.
    data: std.ArrayList(u8) = .empty,
};

const QueuedImage = struct { id: u32, image: image.Image };

/// Sink for a piece of a kitty image. On the connection's reader
/// thread, under its lock. A whole image is inflated here, off the UI
/// thread, and queued for `applyFrames`.
fn daemonImage(ctx: *anyopaque, piece: Daemon.ImagePiece) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const t = self.term() orelse return;
    const in = &t.image_in;
    if (piece.offset == 0) {
        in.* = .{
            .id = piece.id,
            .generation = piece.generation,
            .width = piece.width,
            .height = piece.height,
            .total = piece.total,
            .data = in.data,
        };
        in.data.clearRetainingCapacity();
    } else if (piece.id != in.id or piece.generation != in.generation or piece.offset != in.data.items.len) {
        return log.warn("image {d}: a piece out of order", .{piece.id});
    }
    if (@as(u64, piece.offset) + piece.data.len > in.total) return log.warn("image {d}: more than its {d} bytes", .{ piece.id, in.total });
    in.data.appendSlice(self.alloc, piece.data) catch return log.err("image {d} dropped: out of memory", .{piece.id});
    if (self.wake.bytes) |bytes| _ = bytes.fetchAdd(piece.data.len, .monotonic);
    if (in.data.items.len < in.total) return;

    const rgba = inflateImage(self.alloc, in) catch |err| return log.err("image {d} ({d}x{d}) dropped: {}", .{ in.id, in.width, in.height, err });
    image.premultiply(rgba);
    self.lockTerminal();
    defer self.unlockTerminal();
    t.pending_images.append(self.alloc, .{ .id = in.id, .image = .{
        .generation = in.generation,
        .width = in.width,
        .height = in.height,
        .rgba = rgba,
    } }) catch {
        self.alloc.free(rgba);
        log.err("image {d} dropped: out of memory", .{in.id});
    };
}

/// Inflate a whole image to its RGBA, owned by the caller.
fn inflateImage(alloc: Allocator, in: *const ImageIn) ![]u8 {
    if (in.width == 0 or in.height == 0) return error.BadImage;
    const len = try std.math.mul(usize, try std.math.mul(usize, in.width, in.height), 4);
    const rgba = try alloc.alloc(u8, len);
    errdefer alloc.free(rgba);
    var reader: std.Io.Reader = .fixed(in.data.items);
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    var inflate: std.compress.flate.Decompress = .init(&reader, .raw, window);
    inflate.reader.readSliceAll(rgba) catch return error.BadImage;
    return rgba;
}

test inflateImage {
    const alloc = std.testing.allocator;
    var in: ImageIn = .{ .width = 3, .height = 2 };
    defer in.data.deinit(alloc);
    const rgba = [_]u8{ 1, 2, 3, 4 } ** 6;
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.ensureUnusedCapacity(64);
    const window = try alloc.alloc(u8, std.compress.flate.max_window_len);
    defer alloc.free(window);
    var deflate = try std.compress.flate.Compress.init(&out.writer, window, .raw, .level_1);
    try deflate.writer.writeAll(&rgba);
    try deflate.finish();
    try in.data.appendSlice(alloc, out.written());
    in.total = @intCast(in.data.items.len);

    const got = try inflateImage(alloc, &in);
    defer alloc.free(got);
    try std.testing.expectEqualSlices(u8, &rgba, got);
    // Cut short, it's a bad image rather than a crash or a short read.
    in.data.items.len -= 2;
    try std.testing.expectError(error.BadImage, inflateImage(alloc, &in));
    in.width = 0;
    try std.testing.expectError(error.BadImage, inflateImage(alloc, &in));
}

/// Apply the frames slime sent since the last draw to `screen`, with
/// the images that came before them, and lay the images out for the
/// renderer. UI thread.
pub fn applyFrames(self: *Session) void {
    const t = self.term() orelse return;
    self.lockTerminal();
    std.mem.swap(std.ArrayList(u8), &t.frames, &t.applying);
    std.mem.swap(std.ArrayList(QueuedImage), &t.pending_images, &t.installing);
    self.unlockTerminal();
    if (t.applying.items.len == 0 and t.installing.items.len == 0) return;
    defer t.applying.clearRetainingCapacity();
    defer t.installing.clearRetainingCapacity();

    // An image comes before the first frame that places it, so all of
    // them can go in first: only the last frame's placements are drawn.
    for (t.installing.items) |*q| {
        t.images.put(self.alloc, q.id, q.image) catch |err| {
            Images.freePixels(self.alloc, &q.image);
            log.err("image {d} dropped: {}", .{ q.id, err });
        };
    }
    var rest = t.applying.items;
    while (rest.len >= 8) {
        const seq = std.mem.readInt(u32, rest[0..4], .little);
        const len = std.mem.readInt(u32, rest[4..8], .little);
        const data = rest[8..][0..len];
        rest = rest[8 + len ..];
        t.applied = seq;
        // Half applied, the screen is wrong until the next full frame.
        t.screen.apply(self.alloc, data) catch |err| log.err("bad frame {d} from slime: {}", .{ seq, err });
    }
    for (t.screen.dropped.items) |id| t.images.remove(self.alloc, id);
    t.screen.dropped.clearRetainingCapacity();
    const cell = self.env.cellSize();
    t.images.update(self.alloc, t.screen.placements.items, cell.width, cell.height) catch |err| log.err("laying out images failed: {}", .{err});
}

/// Tell slime the frames applied are drawn, which lets more come. UI
/// thread, after drawing.
pub fn drawn(self: *Session) void {
    const t = self.term() orelse return;
    if (t.applied == t.acked) return;
    t.acked = t.applied;
    const s = self.live() orelse return;
    s.conn.ack(s.pane, t.applied);
}

/// Sink for what a daemon pane did besides draw: a browser's title
/// comes here too. On the connection's reader thread, under its lock.
fn daemonNotice(ctx: *anyopaque, n: Daemon.Notice) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    switch (n.kind) {
        // Posted for the UI thread to take: SetWindowTextW waits on it.
        .title => {
            self.lockTerminal();
            self.next_title_len = titleToUtf16(&self.next_title_buf, n.text);
            self.unlockTerminal();
            self.postTitle();
        },
        .clipboard => {
            const access = self.wake.clipboard_write.load(.acquire);
            if (access != .allow) return log.info("denied a clipboard write (clipboard-write = {t})", .{access});
            self.queueClipboard(n.text);
        },
        .status => {
            var records = n.status;
            self.lockTerminal();
            self.program_status = .{};
            while (records.next()) |rec| {
                const state = std.enums.fromInt(ProgramStatus.State, rec.state) orelse continue;
                self.program_status.restore(rec.id, state, rec.progress);
            }
            self.unlockTerminal();
            self.status_changed.store(true, .release);
            _ = win32.SetEvent(self.wake.output_event);
        },
        // Nothing shows these yet.
        .pwd, .bell, _ => {},
    }
}

/// Have the UI thread take the title and url (`titleUpdate`), unless
/// it's been asked already.
fn postTitle(self: *Session) void {
    if (self.title_pending.swap(true, .acq_rel)) return;
    _ = win32.PostMessageW(self.wake.hwnd, messages.WM_APP_TITLE_CHANGED, self.id, 0);
}

/// Sink for a browser pane's new url (pane.url): another window's
/// browser went there, or someone sent it there. The page's title is
/// the old page's until one comes. On the connection's reader thread,
/// under its lock, and posted for the UI thread to take as a title is.
fn daemonUrl(ctx: *anyopaque, url: []const u8) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const b = self.browser() orelse return;
    const units = std.unicode.utf8ToUtf16LeAlloc(self.alloc, url) catch |err| return log.warn("pane.url dropped: {}", .{err});
    self.lockTerminal();
    if (b.next_url) |old| self.alloc.free(old);
    b.next_url = units;
    self.next_title_len = 0;
    self.unlockTerminal();
    self.postTitle();
}

/// Sink for a copy's text. On the connection's reader thread, under its
/// lock.
fn daemonCopied(ctx: *anyopaque, tag: u32, text: []const u8) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    const t = self.term() orelse return;
    // Nothing was selected by the time slime looked.
    if (text.len == 0 or tag != @atomicLoad(u32, &t.copy_tag, .monotonic)) return;
    self.queueClipboard(text);
}

/// Hand a clipboard write to the UI thread. One that comes before the
/// last is made replaces it.
fn queueClipboard(self: *Session, text: []const u8) void {
    const t = self.term() orelse return;
    const copy = self.alloc.dupe(u8, text) catch return log.warn("clipboard write dropped: out of memory", .{});
    self.lockTerminal();
    defer self.unlockTerminal();
    if (t.clipboard_write) |pending| {
        self.alloc.free(pending);
    } else {
        _ = win32.PostMessageW(self.wake.hwnd, messages.WM_APP_CLIPBOARD_WRITE, self.id, 0);
    }
    t.clipboard_write = copy;
}

/// Make the pending clipboard write.
pub fn clipboardWriteFlush(self: *Session) void {
    const t = self.term() orelse return;
    self.lockTerminal();
    const pending = t.clipboard_write;
    t.clipboard_write = null;
    self.unlockTerminal();

    const text = pending orelse return;
    defer self.alloc.free(text);
    const hwnd = self.wake.hwnd;
    const result = if (text.len == 0) clipboard.clear(hwnd) else clipboard.set(hwnd, text);
    result catch |err| log.warn("clipboard write failed: {}", .{err});
}

/// Sink for a daemon pane's end. On the connection's reader thread (or
/// the UI thread, adopting a pane already lost), under its lock.
fn daemonEnded(ctx: *anyopaque, why: ?[]const u8) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    if (why) |text| {
        var loss: DaemonLoss = .{};
        loss.set("{s}", .{text});
        // Read on the UI thread only after the post, which orders it.
        self.daemon_loss = loss;
    } else {
        self.exited = true;
    }
    _ = win32.PostMessageW(self.wake.hwnd, messages.WM_APP_CHILD_EXITED, self.id, 0);
}

/// Why the daemon pane was lost to us, once WM_APP_CHILD_EXITED says
/// it ended, if its program didn't exit.
pub fn daemonLoss(self: *const Session) ?*const DaemonLoss {
    return if (self.daemon_loss) |*l| l else null;
}

/// The daemon pane the session shows, if it's one.
pub fn daemonPane(self: *const Session) ?Daemon.PaneRef {
    return switch (self.transport orelse return null) {
        .daemon => |s| s.pane,
        .waiting => null,
    };
}

/// The SSH host the session's pane runs on, if it's remote, as the
/// sidebar remembers it: its daemon's host, or the one it waits on.
pub fn hostDest(self: *const Session) ?[]const u16 {
    return switch (self.transport orelse return null) {
        .daemon => |s| s.conn.hostDest(),
        .waiting => |dest| dest,
    };
}

/// The TERM to ask SSH hosts for.
pub fn sshTerm(config: *const Config) []const u8 {
    return if (config.@"ssh-terminfo") "xterm-ghostty" else "xterm-256color";
}

/// Keep the session after its pane was lost, or couldn't run, saying
/// why. Any key then closes it. A browser's stand-in says why from
/// `daemonLoss`. UI thread.
pub fn showEnded(self: *Session, why: []const u8) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "[{s}. Press any key to close.]", .{why}) catch buf[0..];
    // Frames that came before the end are the last.
    self.applyFrames();
    self.ended = true;
    if (self.term() != null) self.say(text) catch |err| log.err("showing why the pane ended failed: {}", .{err});
    self.unseen.store(true, .release);
}

/// Write `text` on the screen's line below the cursor, scrolling up if
/// that's past the bottom, and hide the cursor: nothing draws here any
/// more. UI thread, once frames have stopped.
fn say(self: *Session, text: []const u8) !void {
    try self.resizeScreen();
    const screen = &(self.term() orelse return).screen;
    if (screen.rows == 0) return;
    var y: usize = if (screen.cursor.viewport) |v| @as(usize, v.y) + 1 else 0;
    if (y >= screen.rows) {
        const top = screen.row_data.orderedRemove(0);
        screen.row_data.appendAssumeCapacity(top);
        y = screen.rows - 1;
    }
    const row = &screen.row_data.items[y];
    @memset(row.raws.items, .{});
    row.selection = null;
    var it = (try std.unicode.Utf8View.init(text)).iterator();
    var x: usize = 0;
    while (it.nextCodepoint()) |cp| : (x += 1) {
        if (x == row.raws.items.len) break;
        row.raws.items[x] = .init(cp);
    }
    screen.cursor.viewport = null;
}

/// Size the screen to the grid itself, keeping what fits: for a session
/// no frames come to. UI thread.
fn resizeScreen(self: *Session) !void {
    const t = self.term() orelse return;
    const screen = &t.screen;
    const old_cols = screen.cols;
    const old_rows = screen.rows;
    if (old_cols == t.cols and old_rows == t.rows) return;
    try screen.resize(self.alloc, t.cols, t.rows);
    for (screen.row_data.items, 0..) |*row, y| {
        const kept: usize = if (y < old_rows) @min(old_cols, t.cols) else 0;
        @memset(row.raws.items[kept..], .{});
    }
    if (screen.cursor.viewport) |v| if (v.x >= t.cols or v.y >= t.rows) {
        screen.cursor.viewport = null;
    };
}

pub fn lockTerminal(self: *Session) void {
    win32.AcquireSRWLockExclusive(&self.lock);
}

pub fn unlockTerminal(self: *Session) void {
    win32.ReleaseSRWLockExclusive(&self.lock);
}

/// The program's title, or its name if it set none. A browser's page
/// title, or with none its url's host.
pub fn title(self: *const Session) []const u16 {
    if (self.title_len > 0) return self.title_buf[0..self.title_len];
    return switch (self.content) {
        .terminal => self.default_title,
        .browser => |*b| urlHost(b.url),
    };
}

/// Take the program's new title, and a browser's url. Clears the
/// pending flag before reading, so a change made after the read posts
/// again. Returns true if a url came, which the browser goes to, as
/// slime's (`Browser.followed`) unless the URL bar sent it.
pub fn titleUpdate(self: *Session) bool {
    self.title_pending.store(false, .release);
    self.lockTerminal();
    defer self.unlockTerminal();
    @memcpy(self.title_buf[0..self.next_title_len], self.next_title_buf[0..self.next_title_len]);
    self.title_len = self.next_title_len;
    const b = self.browser() orelse return false;
    const url = b.next_url orelse return false;
    b.next_url = null;
    self.alloc.free(b.url);
    b.url = url;
    if (b.followed) |old| self.alloc.free(old);
    b.followed = null;
    if (b.typed) |typed| if (std.mem.eql(u16, typed, url)) {
        self.alloc.free(typed);
        b.typed = null;
        return true;
    };
    b.followed = self.alloc.dupe(u16, url) catch null;
    return true;
}

/// The user took the pane's page elsewhere in this window (a link,
/// back or forward, a window it opened): where it lands is reported
/// again. UI thread.
pub fn ownNavigation(self: *Session) void {
    const b = self.browser() orelse return;
    if (b.followed) |old| self.alloc.free(old);
    b.followed = null;
}

/// The pane's browser went to `url`, whose page is titled `title`: the
/// pane shows them, and slime hears, for its other windows to follow;
/// on a page slime sent it to (`Browser.followed`), slime hears that
/// url, with the title. Returns the url slime is told, null if nothing
/// changed. UI thread.
pub fn visited(self: *Session, url: []const u16, page_title: []const u16) ?[]const u16 {
    const b = self.browser() orelse return null;
    const moved = !std.mem.eql(u16, b.url, url);
    const retitled = !std.mem.eql(u16, self.title_buf[0..self.title_len], page_title[0..@min(page_title.len, max_title_len)]);
    if (!moved and !retitled) return null;
    if (moved) {
        const copy = self.alloc.dupe(u16, url) catch return null;
        self.alloc.free(b.url);
        b.url = copy;
    }
    self.lockTerminal();
    self.title_len = @min(page_title.len, max_title_len);
    @memcpy(self.title_buf[0..self.title_len], page_title[0..self.title_len]);
    @memcpy(self.next_title_buf[0..self.title_len], page_title[0..self.title_len]);
    self.next_title_len = self.title_len;
    self.unlockTerminal();
    const told = b.followed orelse b.url;
    const s = self.live() orelse return told;
    s.conn.paneVisited(s.pane, told, page_title) catch |err| log.warn("telling slime where the browser went failed: {}", .{err});
    return told;
}

/// Where a browser pane's page is; null for a terminal.
pub fn pageUrl(self: *const Session) ?[]const u16 {
    return switch (self.content) {
        .browser => |*b| b.url,
        .terminal => null,
    };
}

/// Send a browser pane to `to`, as the URL bar does: slime is told, and
/// the pane shows it now rather than when slime's echo comes. Its title
/// was the last page's. UI thread.
pub fn navigate(self: *Session, to: []const u16) !void {
    const b = self.browser() orelse return;
    const s = self.live() orelse return;
    try s.conn.paneNavigate(s.pane, to);
    const copy = try self.alloc.dupe(u16, to);
    self.alloc.free(b.url);
    b.url = copy;
    self.ownNavigation();
    if (b.typed) |old| self.alloc.free(old);
    b.typed = self.alloc.dupe(u16, to) catch null;
    self.lockTerminal();
    defer self.unlockTerminal();
    self.title_len = 0;
    self.next_title_len = 0;
}

/// The most pressing thing its programs report, for the sidebar.
pub fn statusSummary(self: *Session) ?ProgramStatus.Summary {
    self.lockTerminal();
    defer self.unlockTerminal();
    return self.program_status.summary();
}

/// The color the pane's box is filled with, under its strip: its
/// terminal's default background, or the configured one.
pub fn background(self: *const Session) ghostty_vt.color.RGB {
    return switch (self.content) {
        .terminal => |*t| t.cells.default_bg,
        .browser => self.env.config.background,
    };
}

/// Whether the screen's cursor shows and blinks.
pub fn cursorBlinks(self: *const Session) bool {
    return switch (self.content) {
        .terminal => |*t| t.screen.cursor.visible and t.screen.cursor.blinking,
        .browser => false,
    };
}

/// Fit the pane to its place `p` from the window's layout: a new grid or
/// cell size, and where the grid is in the pane, which slime is told for
/// mapping the mouse to cells. UI thread.
pub fn resize(self: *Session, p: Placement.Pane) void {
    const t = self.term() orelse return;
    const cols = p.cols;
    const rows = p.rows;
    t.cols = cols;
    t.rows = rows;
    const s = self.live() orelse {
        self.resizeScreen() catch |err| log.err("resizing the screen failed: {}", .{err});
        return;
    };
    // A new font size (e.g. on a DPI change) can keep the grid size. The
    // daemon's terminal answers pixel size reports, so it hears about new
    // fonts too.
    const cell = self.env.cellSize();
    const size: Daemon.Size = .{ .cols = cols, .rows = rows, .cell_width = cell.width, .cell_height = cell.height };
    if (t.sized == null or !std.meta.eql(t.sized.?, size)) {
        t.sized = size;
        s.conn.resize(s.pane, size);
    }

    const width: u32 = @intFromFloat(p.rect.w);
    const height: u32 = @intFromFloat(p.rect.h);
    const g: event.Geometry = .{
        .cell_width = cell.width,
        .cell_height = cell.height,
        .padding = .{
            .left = p.pad.left,
            .top = p.pad.top,
            .right = width -| p.pad.left -| @as(u32, cols) * cell.width,
            .bottom = height -| p.pad.top -| @as(u32, rows) * cell.height,
        },
        .width = width,
        .height = height,
    };
    if (t.geometry != null and std.meta.eql(t.geometry.?, g)) return;
    t.geometry = g;
    self.send(.{ .geometry = g });
}

/// Send slime an event for the pane, if it's a live terminal: a
/// browser's page takes no events through slime.
fn send(self: *Session, ev: Events.Event) void {
    if (self.content != .terminal) return;
    const s = self.live() orelse return;
    var buf: [Events.max_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    Events.encode(&w, ev) catch return log.warn("{t} event too big", .{ev});
    s.conn.event(s.pane, w.buffered());
}

/// The config was reloaded: slime takes the colors and the selection's
/// settings again, and its next frame shows them; clipboard writes go
/// by the new setting.
pub fn configChanged(self: *Session) void {
    self.wake.clipboard_write.store(self.env.config.@"clipboard-write", .release);
    self.sendSettings();
}

/// Tell slime what selection and the terminal's colors go by here.
fn sendSettings(self: *Session) void {
    const config = self.env.config;
    const words = config.@"selection-word-chars".codepoints;
    self.send(.{
        .settings = .{
            .double_click_ms = win32.GetDoubleClickTime(),
            // What slime has room for.
            .word_boundary = words[0..@min(words.len, Events.max_word_boundary)],
            .colors = .{
                .background = config.background,
                .foreground = config.foreground,
                // Another setting colors the cursor from its cell, which
                // drawing resolves.
                .cursor = if (config.@"cursor-color") |c| switch (c) {
                    .color => |rgb| rgb,
                    else => null,
                } else null,
                .palette = config.palette.colors,
            },
        },
    });
}

/// Send a key message: the key, and the same key as win32-input-mode
/// (mode 9001) has it, which slime sends instead while the program asks
/// for that. A browser pane takes none: its text, posted as WM_CHAR,
/// comes to `charInput`, which drops it too.
pub fn keyInput(self: *Session, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    if (self.content != .terminal) return;
    // TranslateMessage already posted the WM_(SYS)CHAR / WM_(SYS)DEADCHAR
    // messages this key produced. Take them so the key and its text go
    // together, as one event.
    const hwnd = self.wake.hwnd;
    var utf16: [Events.max_win32]u16 = undefined;
    var len: usize = 0;
    var composing = false;
    if (msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) {
        var m: win32.MSG = undefined;
        while (len < utf16.len) {
            if (win32.PeekMessageW(&m, hwnd, win32.WM_CHAR, win32.WM_DEADCHAR, win32.PM_REMOVE) == 0 and
                win32.PeekMessageW(&m, hwnd, win32.WM_SYSCHAR, win32.WM_SYSDEADCHAR, win32.PM_REMOVE) == 0) break;
            if (m.message == win32.WM_DEADCHAR or m.message == win32.WM_SYSDEADCHAR) {
                composing = true;
            } else {
                utf16[len] = @truncate(m.wParam);
                len += 1;
            }
        }
    }

    var utf8: [64]u8 = undefined;
    const text_len = std.unicode.utf16LeToUtf8(&utf8, utf16[0..len]) catch 0;
    const ev = input.keyEvent(msg, wparam, lparam, utf8[0..text_len], composing);

    // One win32 record per UTF-16 unit of text the key produced, or one
    // with none.
    var records: [Events.max_win32]event.Win32Key = undefined;
    for (utf16[0..len], records[0..len]) |unit, *r| r.* = input.win32Key(msg, wparam, lparam, unit);
    if (len == 0) {
        const up = msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP;
        records[0] = input.win32Key(msg, wparam, lparam, if (up) input.releaseChar(wparam, lparam) else 0);
    }

    if (ev.action != .release and !ev.key.modifier()) self.env.input();
    self.send(.{ .key = .{ .event = ev, .win32 = records[0..@max(len, 1)] } });
}

/// Whether the screen shows a selection.
pub fn hasSelection(self: *const Session) bool {
    const t = switch (self.content) {
        .terminal => |*t| t,
        .browser => return false,
    };
    for (t.screen.row_data.items) |row| {
        if (row.selection != null) return true;
    }
    return false;
}

/// Have slime copy the selected text to the clipboard: it comes back
/// through `daemonCopied`. Returns false if the screen shows no
/// selection.
pub fn copySelection(self: *Session) bool {
    if (!self.hasSelection()) return false;
    const t = self.term().?;
    const tag = t.copy_tag +% 1;
    @atomicStore(u32, &t.copy_tag, tag, .monotonic);
    self.send(.{ .copy = tag });
    return true;
}

/// Send the clipboard's text, which slime brackets if the program asked
/// for that (mode 2004) and makes safe.
pub fn paste(self: *Session) void {
    if (self.content != .terminal) return;
    const s = self.live() orelse return;
    const text = (clipboard.get(self.alloc, self.wake.hwnd) catch |err| {
        log.err("paste failed: {}", .{err});
        return;
    }) orelse return;
    defer self.alloc.free(text);
    if (text.len == 0) return;

    var w: std.Io.Writer.Allocating = .init(self.alloc);
    defer w.deinit();
    Events.encode(&w.writer, .{ .paste = text }) catch return log.err("paste failed: out of memory", .{});
    self.env.input();
    s.conn.event(s.pane, w.written());
}

/// Send text from a WM_CHAR that no key message claimed: IME commits,
/// alt+numpad codes, and VK_PACKET input from SendInput. A browser pane
/// drops it.
pub fn charInput(self: *Session, unit: u16) void {
    const t = self.term() orelse return;
    var units: [2]u16 = undefined;
    const pair: []const u16 = if (std.unicode.utf16IsHighSurrogate(unit)) {
        t.high_surrogate = unit;
        return;
    } else if (std.unicode.utf16IsLowSurrogate(unit)) pair: {
        units = .{ t.high_surrogate orelse return, unit };
        break :pair &units;
    } else pair: {
        units[0] = unit;
        break :pair units[0..1];
    };
    t.high_surrogate = null;

    var utf8: [8]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8, pair) catch return;
    self.env.input();
    self.send(.{ .text = utf8[0..len] });
}

/// Tell slime about a focus change, which it reports to a program that
/// asked (mode 1004). ConPTY always asks, and passes them on to console
/// programs as FOCUS_EVENT records.
pub fn reportFocus(self: *Session, focused: bool) void {
    self.send(.{ .focus = focused });
}

/// Send a mouse button press or release, or motion: slime reports it to
/// the program or selects with it. Motion without a button goes only to
/// a program that asked for it.
pub fn mouseInput(self: *Session, msg: u32, wparam: win32.WPARAM, pos: win32.POINT) void {
    const t = self.term() orelse return;
    const button: ?MouseButton, const action: MouseAction = if (input.mouseButton(msg, wparam)) |b|
        .{ b[0], if (b[1]) .press else .release }
    else
        .{ input.heldButton(wparam), .motion };
    const held = input.heldButton(wparam) != null;
    if (action == .motion and !held and !t.screen.motion) return;
    self.send(.{ .mouse = .{
        .action = action,
        .button = button,
        .mods = input.mouseMods(wparam),
        .held = held,
        .x = @floatFromInt(pos.x),
        .y = @floatFromInt(pos.y),
        .time = @bitCast(win32.GetMessageTime()),
    } });
}

/// End a selection drag that lost the mouse (alt+tab, a modal window, or
/// switching sessions).
pub fn cancelSelection(self: *Session) void {
    self.send(.cancel);
}

/// Send the wheel: slime reports it, sends arrow keys for alternate
/// scroll (mode 1007), or scrolls back.
pub fn mouseWheel(self: *Session, msg: u32, wparam: win32.WPARAM, pos: win32.POINT) void {
    if (self.content != .terminal) return;
    var lines: u32 = 3;
    _ = win32.SystemParametersInfoW(win32.SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    self.send(.{ .wheel = .{
        .horizontal = msg == win32.WM_MOUSEHWHEEL,
        .rotation = @bitCast(win32.hiword(wparam)),
        .lines_per_notch = if (lines == win32.WHEEL_PAGESCROLL) event.lines_page else lines,
        .mods = input.mouseMods(wparam),
        .x = @floatFromInt(pos.x),
        .y = @floatFromInt(pos.y),
    } });
}

/// The pointer the program asked for (OSC 22).
pub fn mouseShape(self: *const Session) ghostty_vt.MouseShape {
    return switch (self.content) {
        .terminal => |*t| std.enums.fromInt(ghostty_vt.MouseShape, t.screen.mouse_shape) orelse .default,
        .browser => .default,
    };
}

/// A title as UTF-16 in `out`, returning its length. libghostty-vt cuts
/// long titles at a byte limit, so a codepoint split there is dropped.
fn titleToUtf16(out: []u16, utf8: []const u8) usize {
    const whole = utf8[0..@min(utf8.len, out.len)];
    var end = whole.len;
    while (end > 0 and whole.len - end < 4) : (end -= 1) {
        if (std.unicode.utf8ToUtf16Le(out, whole[0..end])) |n| return n else |_| {}
    }
    return 0;
}

test titleToUtf16 {
    var out: [8]u16 = undefined;
    try std.testing.expectEqual(0, titleToUtf16(&out, ""));
    const n = titleToUtf16(&out, "h\u{e9}");
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("h\u{e9}"), out[0..n]);
    // A codepoint cut off after its first byte.
    const cut = "ab\u{1f600}"[0..3];
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("ab"), out[0..titleToUtf16(&out, cut)]);
}

/// What a page with no title goes by: its url's host (and port), or the
/// url itself if it has none: `https://alde@example.com:8443/a?b` is
/// `example.com:8443`, `about:blank` is itself.
pub fn urlHost(url: []const u16) []const u16 {
    const sep = std.unicode.utf8ToUtf16LeStringLiteral("://");
    const start = (std.mem.indexOf(u16, url, sep) orelse return url) + sep.len;
    var host = url[start..];
    if (std.mem.indexOfAny(u16, host, &.{ '/', '?', '#' })) |end| host = host[0..end];
    if (std.mem.lastIndexOfScalar(u16, host, '@')) |at| host = host[at + 1 ..];
    return if (host.len > 0) host else url;
}

test urlHost {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, L("example.com:8443"), urlHost(L("https://alde@example.com:8443/a?b")));
    try std.testing.expectEqualSlices(u16, L("example.com"), urlHost(L("https://example.com")));
    try std.testing.expectEqualSlices(u16, L("intranet"), urlHost(L("http://intranet#top")));
    try std.testing.expectEqualSlices(u16, L("about:blank"), urlHost(L("about:blank")));
    try std.testing.expectEqualSlices(u16, L("file:///C:/x"), urlHost(L("file:///C:/x")));
}

/// What the URL bar sends for `text`: a url as typed, or with no scheme
/// a site, over https but on this machine (`localhost:3000`), where
/// dev servers are plain http. Owned by the caller.
pub fn typedUrl(alloc: Allocator, text: []const u16) ![]u16 {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const has_scheme = std.mem.indexOf(u16, text, L("://")) != null or for ([_][]const u16{
        L("about:"), L("data:"), L("file:"), L("javascript:"), L("view-source:"), L("blob:"),
    }) |scheme| {
        if (std.mem.startsWith(u16, text, scheme)) break true;
    } else false;
    if (has_scheme) return alloc.dupe(u16, text);
    const local = for ([_][]const u16{ L("localhost"), L("127.0.0.1"), L("[::1]") }) |host| {
        if (std.mem.startsWith(u16, text, host) and (text.len == host.len or std.mem.indexOfScalar(u16, L(":/"), text[host.len]) != null)) break true;
    } else false;
    return std.mem.concat(alloc, u16, &.{ if (local) L("http://") else L("https://"), text });
}

test typedUrl {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    const alloc = std.testing.allocator;
    for ([_][2][]const u16{
        .{ L("example.com"), L("https://example.com") },
        .{ L("http://intranet/"), L("http://intranet/") },
        .{ L("localhost:3000/a"), L("http://localhost:3000/a") },
        .{ L("localhostess.com"), L("https://localhostess.com") },
        .{ L("about:blank"), L("about:blank") },
        .{ L("data:text/html,<p>hi"), L("data:text/html,<p>hi") },
    }) |case| {
        const got = try typedUrl(alloc, case[0]);
        defer alloc.free(got);
        try std.testing.expectEqualSlices(u16, case[1], got);
    }
}

/// A browser session as `create` makes one from an arrival, without a
/// connection, for the tests.
pub fn testBrowser(alloc: Allocator, config: *const Config, url: []const u16) !Session {
    return .{
        .alloc = alloc,
        .wake = undefined,
        .env = .{ .config = config, .ctx = undefined, .cell_size = undefined, .on_input = undefined },
        .id = 1,
        .default_title = &.{},
        .content = .{ .browser = .{ .url = try alloc.dupe(u16, url) } },
    };
}

test "a browser goes by its page's title, else its host, and takes slime's url" {
    const alloc = std.testing.allocator;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var config: Config = .init(alloc);
    defer config.deinit();
    var s = try testBrowser(alloc, &config, L("https://example.com/"));
    defer s.deinitContent();
    try std.testing.expectEqualSlices(u16, L("example.com"), s.title());
    try std.testing.expectEqualSlices(u16, L("https://example.com/"), s.pageUrl().?);

    // pane.title, then pane.url from the reader: the title is the new
    // page's only once one comes for it. (Already pending: nothing's
    // posted.)
    s.title_pending.store(true, .release);
    daemonNotice(&s, .{ .kind = .title, .text = "Example", .status = undefined });
    try std.testing.expect(!s.titleUpdate());
    try std.testing.expectEqualSlices(u16, L("Example"), s.title());
    s.title_pending.store(true, .release);
    daemonUrl(&s, "https://example.org/x");
    try std.testing.expect(s.titleUpdate());
    try std.testing.expectEqualSlices(u16, L("https://example.org/x"), s.pageUrl().?);
    try std.testing.expectEqualSlices(u16, L("example.org"), s.title());
    // An update with no url leaves the url.
    s.title_pending.store(true, .release);
    daemonNotice(&s, .{ .kind = .title, .text = "Hello", .status = undefined });
    try std.testing.expect(!s.titleUpdate());
    try std.testing.expectEqualSlices(u16, L("https://example.org/x"), s.pageUrl().?);
    try std.testing.expectEqualSlices(u16, L("Hello"), s.title());

    // Its own browser went somewhere: shown at once, with no connection
    // to tell.
    s.ownNavigation();
    try std.testing.expectEqualSlices(u16, L("https://example.net/"), s.visited(L("https://example.net/"), L("Net")).?);
    try std.testing.expectEqualSlices(u16, L("https://example.net/"), s.pageUrl().?);
    try std.testing.expectEqualSlices(u16, L("Net"), s.title());
    try std.testing.expect(!s.browser().?.live());
}

test "a url slime sent that redirects elsewhere isn't reported, but its title is" {
    const alloc = std.testing.allocator;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var config: Config = .init(alloc);
    defer config.deinit();
    var s = try testBrowser(alloc, &config, L("https://example.com/"));
    defer s.deinitContent();

    s.title_pending.store(true, .release);
    daemonUrl(&s, "https://example.org/login");
    try std.testing.expect(s.titleUpdate());
    // The page lands on a fresh url: shown here, and slime hears the
    // url it sent, with the page's title.
    try std.testing.expectEqualSlices(u16, L("https://example.org/login"), s.visited(L("https://example.org/login?nonce=1"), L("Log in")).?);
    try std.testing.expectEqualSlices(u16, L("https://example.org/login?nonce=1"), s.pageUrl().?);
    try std.testing.expectEqualSlices(u16, L("Log in"), s.title());
    // Nothing new: nothing told.
    try std.testing.expectEqual(@as(?[]const u16, null), s.visited(L("https://example.org/login?nonce=1"), L("Log in")));

    // A link the user followed here is reported where it lands.
    s.ownNavigation();
    try std.testing.expectEqualSlices(u16, L("https://example.org/home"), s.visited(L("https://example.org/home"), L("Home")).?);
}

test "a browser's page is up only once its WebView is" {
    const alloc = std.testing.allocator;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var config: Config = .init(alloc);
    defer config.deinit();
    var s = try testBrowser(alloc, &config, L("https://example.com/"));
    defer s.deinitContent();
    const b = s.browser().?;
    try std.testing.expect(!b.live());
    // A view with no browser behind it, never shut: only its state is read.
    var view: Web.View = .{ .web = undefined, .session = &s, .key = s.id };
    b.view = &view;
    defer b.view = null;
    try std.testing.expect(!b.live());
    view.state = .creating;
    try std.testing.expect(!b.live());
    view.state = .ready;
    try std.testing.expect(b.live());
}

test "a terminal's methods do nothing for a browser" {
    const alloc = std.testing.allocator;
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    var config: Config = .init(alloc);
    defer config.deinit();
    var s = try testBrowser(alloc, &config, L("https://example.com/"));
    defer s.deinitContent();
    try std.testing.expect(s.term() == null);
    try std.testing.expect(s.browser() != null);
    // Nothing here reaches for a connection, a window, or a screen.
    s.resize(.{ .session = &s, .frame = .{ .w = 400, .h = 300 }, .rect = .{ .w = 400, .h = 270 }, .cols = 40, .rows = 20 });
    s.applyFrames();
    s.drawn();
    s.charInput('a');
    s.keyInput(win32.WM_KEYDOWN, 'A', 0);
    s.mouseInput(win32.WM_LBUTTONDOWN, 0, .{ .x = 5, .y = 5 });
    s.clipboardWriteFlush();
    daemonDraw(&s, 1, "x");
    daemonCopied(&s, 0, "x");
    try std.testing.expect(!s.unseen.load(.acquire));
    try std.testing.expect(!s.hasSelection());
    try std.testing.expect(!s.copySelection());
    try std.testing.expect(!s.cursorBlinks());
    try std.testing.expectEqual(ghostty_vt.MouseShape.default, s.mouseShape());
    try std.testing.expectEqual(config.background, s.background());
    try std.testing.expect(s.term() == null);
}

/// The program a command line runs, without its directory or `.exe`:
/// `"C:\Program Files\PowerShell\7\pwsh.exe" -NoLogo` is `pwsh`.
fn programName(command_line: []const u16) []const u16 {
    var program = command_line;
    if (program.len > 0 and program[0] == '"') {
        program = program[1..];
        if (std.mem.indexOfScalar(u16, program, '"')) |end| program = program[0..end];
    } else if (std.mem.indexOfAny(u16, program, &.{ ' ', '\t' })) |end| {
        program = program[0..end];
    }
    if (std.mem.lastIndexOfAny(u16, program, &.{ '\\', '/' })) |sep| program = program[sep + 1 ..];
    const exe = std.unicode.utf8ToUtf16LeStringLiteral(".exe");
    if (program.len > exe.len and std.ascii.eqlIgnoreCase(
        std.mem.sliceAsBytes(program[program.len - exe.len ..]),
        std.mem.sliceAsBytes(exe),
    )) program = program[0 .. program.len - exe.len];
    return if (program.len > 0) program else command_line;
}

test programName {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, L("pwsh"), programName(L("\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoLogo")));
    try std.testing.expectEqualSlices(u16, L("CMD"), programName(L("C:\\Windows\\system32\\CMD.EXE")));
    try std.testing.expectEqualSlices(u16, L("wsl"), programName(L("wsl ~")));
    try std.testing.expectEqualSlices(u16, L("nu"), programName(L("C:/tools/nu")));
}
