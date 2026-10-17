//! One pane in a window: what slime draws of it, and the input it sends.
//! slime runs the terminal (cmd/slime); the session applies the
//! frames slime sends to `screen`, and turns window messages into events
//! (internal/vt/event.zig) that slime handles against the terminal:
//! keys, mouse reports and selection, the wheel, pastes. Heap allocated,
//! as the connection's reader holds a pointer to it.
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
const Config = @import("Config.zig");
const Login = @import("Login.zig");
const ProgramStatus = @import("ProgramStatus.zig");
const Frames = @import("Screen.zig");
const clipboard = @import("clipboard.zig");
const build_options = @import("build_options");
const Window = @import("Window.zig");
const Renderer = @import("renderer/D3D11.zig");
const Cells = @import("renderer/cells.zig").Cells;
const image = @import("renderer/image.zig");
const Images = image.Images;
const Rect = @import("renderer/Painter.zig").Rect;

const log = std.log.scoped(.session);

const Events = Frames.Events;
const event = Frames.event;

/// libghostty-vt's limit on a title, in bytes, which is at least as
/// many UTF-16 units.
pub const max_title_len = 1024;

const MouseButton = ghostty_vt.input.MouseButton;
const MouseAction = ghostty_vt.input.MouseAction;

window: *Window,
alloc: Allocator,
/// Names the session in messages posted from other threads, which may
/// arrive after it's gone.
id: u32,

/// Shown while the program hasn't set a title: its name.
default_title: []const u16,
/// The program's title (OSC 0/2). Empty for none. UI thread only.
title_buf: [max_title_len]u16 = undefined,
title_len: usize = 0,
/// The title as slime last said, for `titleUpdate` to take. Guarded by
/// `lock`.
next_title_buf: [max_title_len]u16 = undefined,
next_title_len: usize = 0,
/// Set while a WM_APP_TITLE_CHANGED is queued, so a program that
/// retitles rapidly posts one message rather than flooding the queue.
title_pending: std.atomic.Value(bool) = .init(false),
/// A clipboard write for the UI thread to make: the program's (OSC 52),
/// or a copy's text. Writing on the reader thread could deadlock:
/// emptying the clipboard sends a message to its previous owner, which
/// is often us. Empty clears the clipboard. Guarded by `lock`.
clipboard_write: ?[]u8 = null,

lock: win32.SRWLOCK = .{},
/// Frames slime sent that aren't applied yet, each u32 seq, u32 length,
/// then the frame. Guarded by `lock`.
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

/// Where the session's pane is in the window, in client pixels: all of
/// it (`frame`, its title strip and terminal), its terminal (`rect`), and
/// the space around the grid in that. Set by the window's layout.
frame: Rect = .{},
rect: Rect = .{},
pad: Window.PaddingPx = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },
/// The grid the layout fits the pane, which a screen no frames come to
/// takes itself.
cols: u16 = 0,
rows: u16 = 0,
/// What slime was last told of the pane's size and geometry, so a
/// layout that changes nothing sends nothing.
sized: ?Daemon.Size = null,
geometry: ?event.Geometry = null,

transport: ?Transport = null,

/// The pane is gone, or never ran, and the session stays to say why
/// until a key closes it. UI thread only.
ended: bool = false,

/// The daemon pane was lost to us while its program ran (its workspace
/// was taken by another window, or slime went away). Written by the
/// connection's reader before it posts WM_APP_CHILD_EXITED.
daemon_loss: ?DaemonLoss = null,

/// Logging in to the SSH host, while there's something to show: a
/// question, the server working on an answer, or why it failed. Shown
/// as a dialog over the terminal. UI thread only.
login: ?*Login = null,

/// A frame arrived that the window hasn't drawn. Set by the reader
/// thread.
unseen: std.atomic.Value(bool) = .init(false),
/// A frame arrived while another session was shown. UI thread only.
activity: bool = false,

/// The first half of a surrogate pair from a lone WM_CHAR.
high_surrogate: ?u16 = null,

/// The tag of the last copy asked for.
copy_tag: u32 = 0,

/// What programs in the session report doing (OSC 7501), as slime
/// keeps it. Guarded by `lock`.
program_status: ProgramStatus = .{},
/// `program_status` changed since the window last looked. Set by the
/// reader thread.
status_changed: std.atomic.Value(bool) = .init(false),

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

const Pane = struct { conn: *Daemon, pane: u32 };

/// What a new session shows.
pub const Launch = union(enum) {
    /// A pane of the workspace slime keeps for this window. The arrival
    /// stays the caller's.
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

/// Start showing `launch` in a new session with a grid of `cols` x `rows`.
pub fn create(window: *Window, id: u32, launch: Launch, cols: u16, rows: u16) !*Session {
    const alloc = window.alloc;
    const config = window.config;
    const self = try alloc.create(Session);
    errdefer alloc.destroy(self);
    const default_title = try alloc.dupe(u16, switch (launch) {
        // A host's shell, which slime lists with no command, goes by the
        // host until it sets a title.
        .daemon => |s| if (s.arrival.command.len == 0 and s.conn.host() != null)
            s.conn.hostLabel()
        else
            programName(s.arrival.command),
        .waiting => |w| w.title,
        .failed => |f| f.title,
    });
    errdefer alloc.free(default_title);
    self.* = .{
        .window = window,
        .alloc = alloc,
        .id = id,
        .default_title = default_title,
        .cols = cols,
        .rows = rows,
    };
    errdefer self.screen.deinit(alloc);
    // Until the first frame says otherwise.
    self.screen.colors.background = config.background;
    self.screen.colors.foreground = config.foreground;
    self.screen.colors.palette = config.palette.colors;

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
    alloc.free(self.default_title);
    alloc.destroy(self);
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
    if (self.daemon_loss != null) return;
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
/// under its lock.
fn daemonDraw(ctx: *anyopaque, seq: u32, data: []const u8) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    self.lockTerminal();
    const queued = self.queueFrame(seq, data);
    self.unlockTerminal();
    // The screen is wrong until the next full frame.
    queued catch return log.err("dropped frame {d}: out of memory", .{seq});
    if (build_options.stats) _ = self.window.stats.bytes.fetchAdd(data.len, .monotonic);
    self.unseen.store(true, .release);
    _ = win32.SetEvent(self.window.output_event);
}

/// Keep a frame for `applyFrames`. A full frame stands alone, so what
/// came before it goes. Call with the lock held.
fn queueFrame(self: *Session, seq: u32, data: []const u8) !void {
    if (data.len == 0) return error.BadFrame;
    const flags: Frames.Flags = @bitCast(data[0]);
    if (flags.full) self.frames.clearRetainingCapacity();
    try self.frames.ensureUnusedCapacity(self.alloc, 8 + data.len);
    var head: [8]u8 = undefined;
    std.mem.writeInt(u32, head[0..4], seq, .little);
    std.mem.writeInt(u32, head[4..8], @intCast(data.len), .little);
    self.frames.appendSliceAssumeCapacity(&head);
    self.frames.appendSliceAssumeCapacity(data);
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
    const in = &self.image_in;
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
    if (build_options.stats) _ = self.window.stats.bytes.fetchAdd(piece.data.len, .monotonic);
    if (in.data.items.len < in.total) return;

    const rgba = inflateImage(self.alloc, in) catch |err| return log.err("image {d} ({d}x{d}) dropped: {}", .{ in.id, in.width, in.height, err });
    image.premultiply(rgba);
    self.lockTerminal();
    defer self.unlockTerminal();
    self.pending_images.append(self.alloc, .{ .id = in.id, .image = .{
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
    self.lockTerminal();
    std.mem.swap(std.ArrayList(u8), &self.frames, &self.applying);
    std.mem.swap(std.ArrayList(QueuedImage), &self.pending_images, &self.installing);
    self.unlockTerminal();
    if (self.applying.items.len == 0 and self.installing.items.len == 0) return;
    defer self.applying.clearRetainingCapacity();
    defer self.installing.clearRetainingCapacity();

    // An image comes before the first frame that places it, so all of
    // them can go in first: only the last frame's placements are drawn.
    for (self.installing.items) |*q| {
        self.images.put(self.alloc, q.id, q.image) catch |err| {
            Images.freePixels(self.alloc, &q.image);
            log.err("image {d} dropped: {}", .{ q.id, err });
        };
    }
    var rest = self.applying.items;
    while (rest.len >= 8) {
        const seq = std.mem.readInt(u32, rest[0..4], .little);
        const len = std.mem.readInt(u32, rest[4..8], .little);
        const data = rest[8..][0..len];
        rest = rest[8 + len ..];
        self.applied = seq;
        // Half applied, the screen is wrong until the next full frame.
        self.screen.apply(self.alloc, data) catch |err| log.err("bad frame {d} from slime: {}", .{ seq, err });
    }
    for (self.screen.dropped.items) |id| self.images.remove(self.alloc, id);
    self.screen.dropped.clearRetainingCapacity();
    const cell = self.window.cellSizePx();
    self.images.update(self.alloc, self.screen.placements.items, cell.width, cell.height) catch |err| log.err("laying out images failed: {}", .{err});
}

/// Tell slime the frames applied are drawn, which lets more come. UI
/// thread, after drawing.
pub fn drawn(self: *Session) void {
    if (self.applied == self.acked) return;
    self.acked = self.applied;
    const s = self.live() orelse return;
    s.conn.ack(s.pane, self.applied);
}

/// Sink for what a daemon pane did besides draw. On the connection's
/// reader thread, under its lock.
fn daemonNotice(ctx: *anyopaque, n: Daemon.Notice) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    switch (n.kind) {
        // Posted for the UI thread to take: SetWindowTextW waits on it.
        .title => {
            self.lockTerminal();
            self.next_title_len = titleToUtf16(&self.next_title_buf, n.text);
            self.unlockTerminal();
            if (self.title_pending.swap(true, .acq_rel)) return;
            _ = win32.PostMessageW(self.window.hwnd, Window.WM_APP_TITLE_CHANGED, self.id, 0);
        },
        .clipboard => {
            const access = self.window.config.@"clipboard-write";
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
            _ = win32.SetEvent(self.window.output_event);
        },
        // Nothing shows these yet.
        .pwd, .bell, _ => {},
    }
}

/// Sink for a copy's text. On the connection's reader thread, under its
/// lock.
fn daemonCopied(ctx: *anyopaque, tag: u32, text: []const u8) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    // Nothing was selected by the time slime looked.
    if (text.len == 0 or tag != @atomicLoad(u32, &self.copy_tag, .monotonic)) return;
    self.queueClipboard(text);
}

/// Hand a clipboard write to the UI thread. One that comes before the
/// last is made replaces it.
fn queueClipboard(self: *Session, text: []const u8) void {
    const copy = self.alloc.dupe(u8, text) catch return log.warn("clipboard write dropped: out of memory", .{});
    self.lockTerminal();
    defer self.unlockTerminal();
    if (self.clipboard_write) |pending| {
        self.alloc.free(pending);
    } else {
        _ = win32.PostMessageW(self.window.hwnd, Window.WM_APP_CLIPBOARD_WRITE, self.id, 0);
    }
    self.clipboard_write = copy;
}

/// Make the pending clipboard write.
pub fn clipboardWriteFlush(self: *Session) void {
    self.lockTerminal();
    const pending = self.clipboard_write;
    self.clipboard_write = null;
    self.unlockTerminal();

    const text = pending orelse return;
    defer self.alloc.free(text);
    const hwnd = self.window.hwnd.?;
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
    }
    _ = win32.PostMessageW(self.window.hwnd, Window.WM_APP_CHILD_EXITED, self.id, 0);
}

/// Why the daemon pane was lost to us, once WM_APP_CHILD_EXITED says
/// it ended, if its program didn't exit.
pub fn daemonLoss(self: *const Session) ?*const DaemonLoss {
    return if (self.daemon_loss) |*l| l else null;
}

/// The daemon pane the session shows, if it's one.
pub fn daemonPane(self: *const Session) ?u32 {
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
/// why. Any key then closes it. UI thread.
pub fn showEnded(self: *Session, why: []const u8) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "[{s}. Press any key to close.]", .{why}) catch buf[0..];
    // Frames that came before the end are the last.
    self.applyFrames();
    self.ended = true;
    self.say(text) catch |err| log.err("showing why the pane ended failed: {}", .{err});
    self.unseen.store(true, .release);
}

/// Write `text` on the screen's line below the cursor, scrolling up if
/// that's past the bottom, and hide the cursor: nothing draws here any
/// more. UI thread, once frames have stopped.
fn say(self: *Session, text: []const u8) !void {
    try self.resizeScreen();
    const screen = &self.screen;
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
    const screen = &self.screen;
    const old_cols = screen.cols;
    const old_rows = screen.rows;
    if (old_cols == self.cols and old_rows == self.rows) return;
    try screen.resize(self.alloc, self.cols, self.rows);
    for (screen.row_data.items, 0..) |*row, y| {
        const kept: usize = if (y < old_rows) @min(old_cols, self.cols) else 0;
        @memset(row.raws.items[kept..], .{});
    }
    if (screen.cursor.viewport) |v| if (v.x >= self.cols or v.y >= self.rows) {
        screen.cursor.viewport = null;
    };
}

pub fn lockTerminal(self: *Session) void {
    win32.AcquireSRWLockExclusive(&self.lock);
}

pub fn unlockTerminal(self: *Session) void {
    win32.ReleaseSRWLockExclusive(&self.lock);
}

/// The program's title, or its name if it set none.
pub fn title(self: *const Session) []const u16 {
    return if (self.title_len > 0) self.title_buf[0..self.title_len] else self.default_title;
}

/// Take the program's new title. Clears the pending flag before reading,
/// so a change made after the read posts again.
pub fn titleUpdate(self: *Session) void {
    self.title_pending.store(false, .release);
    self.lockTerminal();
    defer self.unlockTerminal();
    @memcpy(self.title_buf[0..self.next_title_len], self.next_title_buf[0..self.next_title_len]);
    self.title_len = self.next_title_len;
}

/// The most pressing thing its programs report, for the sidebar.
pub fn statusSummary(self: *Session) ?ProgramStatus.Summary {
    self.lockTerminal();
    defer self.unlockTerminal();
    return self.program_status.summary();
}

/// Fit the pane to a new grid or cell size, and tell slime where the
/// grid is in it, for mapping the mouse to cells. UI thread.
pub fn resize(self: *Session, cols: u16, rows: u16) void {
    self.cols = cols;
    self.rows = rows;
    const s = self.live() orelse {
        self.resizeScreen() catch |err| log.err("resizing the screen failed: {}", .{err});
        return;
    };
    // A new font size (e.g. on a DPI change) can keep the grid size. The
    // daemon's terminal answers pixel size reports, so it hears about new
    // fonts too.
    const cell = self.window.cellSizePx();
    const size: Daemon.Size = .{ .cols = cols, .rows = rows, .cell_width = cell.width, .cell_height = cell.height };
    if (self.sized == null or !std.meta.eql(self.sized.?, size)) {
        self.sized = size;
        s.conn.resize(s.pane, size);
    }

    const width: u32 = @intFromFloat(self.rect.w);
    const height: u32 = @intFromFloat(self.rect.h);
    const g: event.Geometry = .{
        .cell_width = cell.width,
        .cell_height = cell.height,
        .padding = .{
            .left = self.pad.left,
            .top = self.pad.top,
            .right = width -| self.pad.left -| @as(u32, cols) * cell.width,
            .bottom = height -| self.pad.top -| @as(u32, rows) * cell.height,
        },
        .width = width,
        .height = height,
    };
    if (self.geometry != null and std.meta.eql(self.geometry.?, g)) return;
    self.geometry = g;
    self.send(.{ .geometry = g });
}

/// Send slime an event for the pane, if it's live.
fn send(self: *Session, ev: Events.Event) void {
    const s = self.live() orelse return;
    var buf: [Events.max_len]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    Events.encode(&w, ev) catch return log.warn("{t} event too big", .{ev});
    s.conn.event(s.pane, w.buffered());
}

/// Tell slime what selection and the terminal's colors go by here.
fn sendSettings(self: *Session) void {
    const config = self.window.config;
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
/// for that.
pub fn keyInput(self: *Session, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    // TranslateMessage already posted the WM_(SYS)CHAR / WM_(SYS)DEADCHAR
    // messages this key produced. Take them so the key and its text go
    // together, as one event.
    const hwnd = self.window.hwnd;
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

    if (ev.action != .release and !ev.key.modifier()) self.window.resetBlink();
    self.send(.{ .key = .{ .event = ev, .win32 = records[0..@max(len, 1)] } });
}

/// Have slime copy the selected text to the clipboard: it comes back
/// through `daemonCopied`. Returns false if the screen shows no
/// selection.
pub fn copySelection(self: *Session) bool {
    const selected = for (self.screen.row_data.items) |row| {
        if (row.selection != null) break true;
    } else false;
    if (!selected) return false;
    const tag = self.copy_tag +% 1;
    @atomicStore(u32, &self.copy_tag, tag, .monotonic);
    self.send(.{ .copy = tag });
    return true;
}

/// Send the clipboard's text, which slime brackets if the program asked
/// for that (mode 2004) and makes safe.
pub fn paste(self: *Session) void {
    const s = self.live() orelse return;
    const text = (clipboard.get(self.alloc, self.window.hwnd.?) catch |err| {
        log.err("paste failed: {}", .{err});
        return;
    }) orelse return;
    defer self.alloc.free(text);
    if (text.len == 0) return;

    var w: std.Io.Writer.Allocating = .init(self.alloc);
    defer w.deinit();
    Events.encode(&w.writer, .{ .paste = text }) catch return log.err("paste failed: out of memory", .{});
    self.window.resetBlink();
    s.conn.event(s.pane, w.written());
}

/// Send text from a WM_CHAR that no key message claimed: IME commits,
/// alt+numpad codes, and VK_PACKET input from SendInput.
pub fn charInput(self: *Session, unit: u16) void {
    var units: [2]u16 = undefined;
    const pair: []const u16 = if (std.unicode.utf16IsHighSurrogate(unit)) {
        self.high_surrogate = unit;
        return;
    } else if (std.unicode.utf16IsLowSurrogate(unit)) pair: {
        units = .{ self.high_surrogate orelse return, unit };
        break :pair &units;
    } else pair: {
        units[0] = unit;
        break :pair units[0..1];
    };
    self.high_surrogate = null;

    var utf8: [8]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&utf8, pair) catch return;
    self.window.resetBlink();
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
    const button: ?MouseButton, const action: MouseAction = if (input.mouseButton(msg, wparam)) |b|
        .{ b[0], if (b[1]) .press else .release }
    else
        .{ input.heldButton(wparam), .motion };
    const held = input.heldButton(wparam) != null;
    if (action == .motion and !held and !self.screen.motion) return;
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
    return std.enums.fromInt(ghostty_vt.MouseShape, self.screen.mouse_shape) orelse .default;
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
