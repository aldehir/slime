//! One terminal in a window: the terminal state, the child process it
//! talks to, and everything about input that depends on the terminal.
//! Heap allocated so the stream's pointer to `terminal` stays valid.
//!
//! A reader thread feeds the child's output to the stream; the UI thread
//! renders and handles input. `lock` guards `terminal` and `stream`
//! between them. Mouse positions are relative to the session's pane
//! (`rect`).
const Session = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");
const input = @import("input.zig");
const Pty = @import("Pty.zig");
const SshConnection = @import("SshConnection.zig");
const Slimed = @import("Slimed.zig");
const Login = @import("Login.zig");
const ProgramStatus = @import("ProgramStatus.zig");
const clipboard = @import("clipboard.zig");
const build_options = @import("build_options");
const Window = @import("Window.zig");
const Renderer = @import("renderer/D3D11.zig");
const Cells = @import("renderer/cells.zig").Cells;
const Images = @import("renderer/image.zig").Images;
const Rect = @import("renderer/Painter.zig").Rect;

const log = std.log.scoped(.session);

/// libghostty-vt's limit on a title, in bytes, which is at least as
/// many UTF-16 units.
pub const max_title_len = 1024;

const StreamHandler = @FieldType(ghostty_vt.TerminalStream, "handler");
const MouseButton = ghostty_vt.input.MouseButton;
const MouseAction = ghostty_vt.input.MouseAction;
const MouseEvent = ghostty_vt.input.MouseEncodeEvent;
const MouseEncodeOptions = ghostty_vt.input.MouseEncodeOptions;

window: *Window,
alloc: Allocator,
/// Names the session in messages posted from other threads, which may
/// arrive after it's gone.
id: u32,

/// Shown while the child hasn't set a title: the program's name.
default_title: []const u16,
/// The child's title (OSC 0/2). Empty for none.
title_buf: [max_title_len]u16 = undefined,
title_len: usize = 0,
/// Set while a WM_APP_TITLE_CHANGED is queued, so a child that retitles
/// rapidly posts one message rather than flooding the queue.
title_pending: std.atomic.Value(bool) = .init(false),
/// A clipboard write from the child (OSC 52) for the UI thread to make.
/// Writing on the reader thread could deadlock: emptying the clipboard
/// sends a message to its previous owner, which is often us. Empty
/// clears the clipboard. Guarded by `lock`.
clipboard_write: ?[]u8 = null,

lock: win32.SRWLOCK = .{},
terminal: ghostty_vt.Terminal,
stream: ghostty_vt.TerminalStream,
render_state: ghostty_vt.RenderState = .empty,
cells: Cells = .{},
images: Images = .{},
textures: Renderer.ImageTextures = .{},

/// Where the session's pane is in the window, in client pixels: all of
/// it (`frame`, its title strip and terminal), its terminal (`rect`), and
/// the space around the grid in that. Set by the window's layout.
frame: Rect = .{},
rect: Rect = .{},
pad: Window.PaddingPx = .{ .left = 0, .right = 0, .top = 0, .bottom = 0 },

transport: ?Transport = null,
reader: ?std.Thread = null,
exit_wait: ?win32.HANDLE = null,

/// The SSH channel failed, and the session stays to say why until a key
/// closes it. UI thread only.
ended: bool = false,

/// The slimed pane was lost to us while its child ran (its workspace was
/// taken by another window, or slimed went away). Written by the
/// connection's reader before it posts WM_APP_CHILD_EXITED.
slimed_loss: ?SlimedLoss = null,

/// Logging in to the SSH host, while there's something to show: a
/// question, the server working on an answer, or why it failed. Shown
/// as a dialog over the terminal. UI thread only.
login: ?*Login = null,

/// Output arrived that the window hasn't drawn. Set by the reader thread.
unseen: std.atomic.Value(bool) = .init(false),
/// Output arrived while another session was shown. UI thread only.
activity: bool = false,

/// The first half of a surrogate pair from a lone WM_CHAR.
high_surrogate: ?u16 = null,

/// win32-input-mode (mode 9001): send keys as Win32 key events. Whoever
/// is on the other end of the VT stream asks for it, which in practice
/// is a ConPTY (ours, or a remote Windows host's), so it follows the
/// stream rather than the transport. Guarded by `lock`.
win32_input: bool = false,

/// What programs in the session report doing (OSC 7501). Guarded by
/// `lock`.
program_status: ProgramStatus = .{},
/// `program_status` changed since the window last looked. Set by the
/// reader thread.
status_changed: std.atomic.Value(bool) = .init(false),

/// The cell the last mouse event was reported in, so motion within one
/// cell is reported once.
mouse_cell: ?ghostty_vt.Coordinate = null,

/// Wheel rotation not yet turned into scrolling, vertical then
/// horizontal, in 1/WHEEL_DELTA notches times the lines per notch.
wheel_remainder: [2]i32 = .{ 0, 0 },

/// Click, drag, and multi-click state for selecting text with the left
/// button. Guarded by `lock`.
selection: ghostty_vt.SelectionGesture = .init,

/// A left button drag is selecting text rather than being reported.
selecting: bool = false,

/// Where the selection drag last was, for autoscroll ticks.
drag_pos: win32.POINT = .{ .x = 0, .y = 0 },

/// What a session talks to.
const Transport = union(enum) {
    /// A local child in a pseudoconsole.
    conpty: Pty,
    /// A remote shell on an SSH connection.
    ssh: *SshConnection.Channel,
    /// A pane slimed holds, which outlives us. Its output comes from the
    /// connection's reader through our sink.
    slimed: struct { conn: *Slimed, pane: u32 },

    fn write(self: *Transport, data: []const u8) void {
        switch (self.*) {
            .conpty => |*pty| pty.write(data),
            .ssh => |ch| ch.write(data),
            .slimed => |s| s.conn.write(s.pane, data),
        }
    }
};

/// What a new session starts.
pub const Launch = union(enum) {
    /// A command line, CreateProcessW syntax.
    command: []const u16,
    /// A shell on `conn`, in `cwd` if set, titled `title` until it sets
    /// its own.
    ssh: struct {
        conn: *SshConnection,
        title: []const u16,
        cwd: ?[]const u8 = null,
    },
    /// A pane of the workspace slimed keeps for this window, from its
    /// snapshot. The arrival stays the caller's.
    slimed: struct {
        conn: *Slimed,
        arrival: *const Slimed.Arrival,
    },
};

/// Why a slimed session's connection ended without its child exiting,
/// for the session to show. Set by the reader thread before it posts
/// WM_APP_CHILD_EXITED.
pub const SlimedLoss = struct {
    const text_buf_len = 256;
    text_buf: [text_buf_len]u8 = undefined,
    text_len: usize = 0,

    pub fn text(self: *const SlimedLoss) []const u8 {
        return self.text_buf[0..self.text_len];
    }

    fn set(self: *SlimedLoss, comptime fmt: []const u8, args: anytype) void {
        // Too long for the buffer: keep what fit.
        self.text_len = if (std.fmt.bufPrint(&self.text_buf, fmt, args)) |s| s.len else |_| self.text_buf.len;
    }
};

/// Start `launch` in a new session with a grid of `cols` x `rows`.
pub fn create(window: *Window, id: u32, launch: Launch, cols: u16, rows: u16) !*Session {
    const alloc = window.alloc;
    const config = window.config;
    const self = try alloc.create(Session);
    errdefer alloc.destroy(self);
    const default_title = try alloc.dupe(u16, switch (launch) {
        .command => |command_line| programName(command_line),
        .ssh => |ssh| ssh.title,
        .slimed => |s| programName(s.arrival.command),
    });
    errdefer alloc.free(default_title);
    self.* = .{
        .window = window,
        .alloc = alloc,
        .id = id,
        .default_title = default_title,
        .terminal = undefined,
        .stream = undefined,
    };

    // A slimed pane's terminal comes from the daemon's snapshot of it.
    var restored: ?ghostty_vt.snapshot.Decoded = null;
    defer if (restored) |*d| d.deinit(alloc);
    if (launch == .slimed) {
        const arrival = launch.slimed.arrival;
        var reader: std.Io.Reader = .fixed(arrival.snapshot);
        restored = try ghostty_vt.snapshot.decode(alloc, window.io, &reader, .{
            // slimed's own limit (ssh/internal/vt ContinuationLimit).
            .max_continuation_bytes = 64 * 1024,
            .compress_history = true,
        });
        self.win32_input = arrival.win32_input;
        for (arrival.status) |rec| {
            const state = std.enums.fromInt(ProgramStatus.State, rec.state) orelse continue;
            self.program_status.restore(rec.id, state, rec.progress);
        }
    }

    self.terminal = if (restored) |*d| d.toOwned() else try .init(window.io, alloc, .{
        .cols = cols,
        .rows = rows,
        // Defaults that OSC 4/10/11/12 override and their resets return
        // to. A cursor colored from its cell is resolved when drawing.
        .colors = .{
            .background = .init(config.background),
            .foreground = .init(config.foreground),
            .cursor = if (config.@"cursor-color") |c| switch (c) {
                .color => |rgb| .init(rgb),
                else => .unset,
            } else .unset,
            .palette = try .init(alloc, config.palette.colors),
        },
        // Mode 2027: cluster multi-codepoint graphemes (emoji sequences,
        // combining marks) into one cell, as the Ghostty app does.
        .default_modes = .{ .grapheme_cluster = true },
        // Null blinks, as Ghostty does by default, including after a
        // DECSCUSR 0, RIS, or DECSTR. Mode 12 and DECSCUSR change it.
        .default_cursor_blink = null,
    });
    errdefer self.terminal.deinit(alloc);
    if (restored != null) try self.applyDefaults();
    // Init takes no pixel size, and kitty images and pixel size reports
    // need one before the first resize.
    try self.terminal.resize(alloc, .{
        .cols = cols,
        .rows = rows,
        .cell_size_px = window.cellSizePx(),
    });
    // An arrow until the child asks for another shape with OSC 22. An
    // I-beam (Ghostty's default) looks wrong over TUIs. An empty OSC 22
    // still resets it to the I-beam. A restored terminal can't tell the
    // default I-beam from one the child asked for, and takes the arrow.
    if (restored == null or self.terminal.mouse_shape == .text) self.terminal.mouse_shape = .default;
    self.stream = self.terminal.vtStream();
    errdefer self.stream.deinit();
    self.stream.handler.effects.write_pty = &writePty;
    self.stream.handler.effects.device_attributes = &deviceAttributes;
    self.stream.handler.effects.title_changed = &titleChanged;
    self.stream.handler.effects.clipboard_write = &clipboardWrite;
    self.stream.handler.effects.clipboard_read = &clipboardRead;
    self.stream.handler.unknown_sequence = &unknownSequence;
    // Also makes the terminal answer the protocol's support query.
    self.stream.handler.effects.program_status = &programStatus;
    self.stream.handler.effects.semantic_prompt = &semanticPrompt;
    // The snapshot was cut inside an escape sequence or codepoint: feed
    // its start so the live output continues it. Replies it causes go
    // nowhere, as the transport isn't set yet; the daemon answered.
    if (restored) |d| switch (d.continuation) {
        .ground => {},
        .bytes => |b| self.stream.nextSlice(b),
    };
    if (restored != null) self.title_len = titleToUtf16(&self.title_buf, self.terminal.getTitle() orelse "");

    switch (launch) {
        .command => |command_line| {
            // CreateProcessW may modify the command line.
            const cmd = try alloc.dupeZ(u16, command_line);
            defer alloc.free(cmd);
            self.transport = .{ .conpty = try .spawn(cmd, cols, rows) };
        },
        .ssh => |ssh| {
            const cell = window.cellSizePx();
            const term = if (config.@"ssh-terminfo") "xterm-ghostty" else "xterm-256color";
            self.transport = .{ .ssh = try ssh.conn.open(id, term, cols, rows, cols * cell.width, rows * cell.height, ssh.cwd) };
        },
        .slimed => |s| {
            // No reader of our own: the connection's feeds the sink, first
            // with what came while the pane waited for us.
            self.transport = .{ .slimed = .{ .conn = s.conn, .pane = s.arrival.pane } };
            s.conn.adopt(s.arrival.pane, .{ .ctx = self, .output = slimedOutput, .ended = slimedEnded });
            return self;
        },
    }
    errdefer self.stopTransport();
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});

    // An SSH channel has no process here; its reader reports the end.
    const pty = switch (self.transport.?) {
        .conpty => |*pty| pty,
        .ssh, .slimed => return self,
    };
    var wait: win32.HANDLE = undefined;
    if (win32.RegisterWaitForSingleObject(
        &wait,
        pty.process,
        onChildExited,
        self,
        win32.INFINITE,
        win32.WT_EXECUTEONLYONCE,
    ) == 0) return win32.lastError("RegisterWaitForSingleObject");
    self.exit_wait = wait;
    return self;
}

pub fn destroy(self: *Session) void {
    const alloc = self.alloc;
    if (self.login) |l| l.destroy();
    self.stopTransport();
    self.textures.deinit(alloc);
    self.cells.deinit(alloc);
    self.images.deinit(alloc);
    self.render_state.deinit(alloc);
    self.selection.deinit(&self.terminal);
    self.stream.deinit();
    self.terminal.deinit(alloc);
    if (self.clipboard_write) |text| alloc.free(text);
    alloc.free(self.default_title);
    alloc.destroy(self);
}

/// Close the pseudoconsole or channel and wait for the reader to drain
/// it. Kills whatever is left of a local child's process tree.
fn stopTransport(self: *Session) void {
    if (self.exit_wait) |wait| {
        // INVALID_HANDLE_VALUE: wait for a running callback to finish.
        _ = win32.UnregisterWaitEx(wait, win32.INVALID_HANDLE_VALUE);
        self.exit_wait = null;
    }
    const transport = &(self.transport orelse return);
    switch (transport.*) {
        .conpty => |*pty| pty.close(),
        .ssh => |ch| ch.close(),
        // Only our view of it: the pane runs on in slimed. Once released,
        // the connection's reader no longer calls our sink.
        .slimed => |s| {
            s.conn.release(s.pane);
            self.transport = null;
            return;
        },
    }
    if (self.reader) |t| t.join();
    self.reader = null;
    switch (transport.*) {
        .conpty => |*pty| pty.deinit(),
        .ssh => |ch| ch.deinit(),
        .slimed => unreachable,
    }
    self.transport = null;
}

/// End a slimed pane for good, not just our view of it, before the
/// session is destroyed: the user closed it. Destroying alone leaves it
/// to slimed, as closing the window does. A pane already lost to us is
/// left alone.
pub fn kill(self: *Session) void {
    if (self.slimed_loss != null) return;
    switch (self.transport orelse return) {
        .slimed => |s| s.conn.kill(s.pane),
        else => {},
    }
}

/// Sink for a slimed pane's output. On the connection's reader thread,
/// under its lock.
fn slimedOutput(ctx: *anyopaque, data: []const u8) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    self.output(data);
}

/// Sink for a slimed pane's end. On the connection's reader thread (or
/// the UI thread, adopting a pane already lost), under its lock.
fn slimedEnded(ctx: *anyopaque, why: ?[]const u8) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    if (why) |text| {
        var loss: SlimedLoss = .{};
        loss.set("{s}", .{text});
        // Read on the UI thread only after the post, which orders it.
        self.slimed_loss = loss;
    }
    _ = win32.PostMessageW(self.window.hwnd, Window.WM_APP_CHILD_EXITED, self.id, 0);
}

/// Why the slimed pane was lost to us, once WM_APP_CHILD_EXITED says
/// it ended, if its child didn't exit.
pub fn slimedLoss(self: *const Session) ?*const SlimedLoss {
    return if (self.slimed_loss) |*l| l else null;
}

/// After restoring from a snapshot, which carries the daemon's defaults:
/// put back ours, as `create` gives a new terminal, keeping what the
/// child changed (OSC 4/10/11/12 colors, the current modes).
fn applyDefaults(self: *Session) !void {
    const config = self.window.config;
    const colors = &self.terminal.colors;
    colors.background.default = config.background;
    colors.foreground.default = config.foreground;
    colors.cursor.default = if (config.@"cursor-color") |c| switch (c) {
        .color => |rgb| rgb,
        else => null,
    } else null;
    try colors.palette.changeDefault(self.alloc, config.palette.colors);
    self.terminal.modes.default.grapheme_cluster = true;
    self.terminal.setDefaultCursorBlink(null);
}

/// The slimed pane the session shows, if it's one.
pub fn slimedPane(self: *const Session) ?u32 {
    return switch (self.transport orelse return null) {
        .slimed => |s| s.pane,
        else => null,
    };
}

/// The SSH connection the session's shell runs on, if it's remote.
pub fn sshConnection(self: *const Session) ?*SshConnection {
    return switch (self.transport orelse return null) {
        .conpty, .slimed => null,
        .ssh => |ch| ch.conn,
    };
}

/// How the session's SSH channel ended, once it has. UI thread only,
/// after WM_APP_CHILD_EXITED.
pub fn sshEnding(self: *const Session) ?*const SshConnection.Ending {
    return switch (self.transport orelse return null) {
        .conpty, .slimed => null,
        .ssh => |ch| &ch.ending,
    };
}

/// Keep the session after its SSH channel failed, saying why. Any key
/// then closes it.
pub fn showEnded(self: *Session, why: []const u8) void {
    self.ended = true;
    self.lockTerminal();
    defer self.unlockTerminal();
    self.stream.nextSlice("\r\n\x1b[0m[");
    self.stream.nextSlice(why);
    self.stream.nextSlice(". Press any key to close.]\r\n");
    self.unseen.store(true, .release);
}

/// The directory the shell last reported (OSC 7), decoded into `buf`.
pub fn pwd(self: *Session, buf: []u8) ?[]const u8 {
    self.lockTerminal();
    defer self.unlockTerminal();
    return SshConnection.pwdFromUrl(buf, self.terminal.getPwd() orelse return null);
}

pub fn lockTerminal(self: *Session) void {
    win32.AcquireSRWLockExclusive(&self.lock);
}

pub fn unlockTerminal(self: *Session) void {
    win32.ReleaseSRWLockExclusive(&self.lock);
}

/// The child's title, or the program's name if it set none.
pub fn title(self: *const Session) []const u16 {
    return if (self.title_len > 0) self.title_buf[0..self.title_len] else self.default_title;
}

/// Fit the terminal and pseudoconsole to a new grid or cell size.
pub fn resize(self: *Session, cols: u16, rows: u16) void {
    self.lockTerminal();
    const changed = cols != self.terminal.cols or rows != self.terminal.rows;
    // A new font size (e.g. on a DPI change) can keep the grid size.
    const cell = self.window.cellSizePx();
    const px_changed = self.terminal.width_px != @as(u32, cols) * cell.width or
        self.terminal.height_px != @as(u32, rows) * cell.height;
    if (changed or px_changed) {
        // Through the handler, which also sends the mode 2048 size
        // report: a child that enabled it (nvim) ignores console resizes.
        self.stream.handler.resize(.{
            .cols = cols,
            .rows = rows,
            .cell_size_px = cell,
        }) catch |err| log.err("terminal resize failed: {}", .{err});
    }
    self.unlockTerminal();

    // After the terminal, so ConPTY's redraw lands on the new grid.
    // ConPTY has no pixel size; an SSH pty does, which programs read to
    // size images, so it hears about new fonts too.
    if (self.transport) |*t| switch (t.*) {
        .conpty => |*pty| if (changed) pty.resize(cols, rows),
        .ssh => |ch| if (changed or px_changed) ch.resize(cols, rows, @as(u32, cols) * cell.width, @as(u32, rows) * cell.height),
        // The daemon's terminal answers pixel size reports while we're
        // detached, so it hears about new fonts too.
        .slimed => |s| if (changed or px_changed) s.conn.resize(s.pane, .{
            .cols = cols,
            .rows = rows,
            .cell_width = cell.width,
            .cell_height = cell.height,
        }),
    };
}

/// Reader thread: feed child output to the terminal until EOF, which
/// comes when the pseudoconsole or the SSH channel is closed.
fn readLoop(self: *Session) void {
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = switch (self.transport.?) {
            .conpty => |*pty| pty.read(&buf),
            .ssh => |ch| ch.read(&buf),
            .slimed => unreachable,
        } catch break;
        if (n == 0) break;
        self.output(buf[0..n]);
    }
    self.channelEnded();
}

fn output(self: *Session, data: []const u8) void {
    self.lockTerminal();
    self.stream.nextSlice(data);
    self.unlockTerminal();
    if (build_options.stats) _ = self.window.stats.bytes.fetchAdd(data.len, .monotonic);
    self.unseen.store(true, .release);
    _ = win32.SetEvent(self.window.output_event);
}

/// Send input (keys, pastes, query replies) to the child.
fn writeChild(self: *Session, data: []const u8) void {
    if (self.transport) |*t| t.write(data);
}

/// Reader thread, after an SSH channel's output ends: report it once the
/// control thread knows how it ended, which the helper sends first.
fn channelEnded(self: *Session) void {
    const ch = switch (self.transport.?) {
        .conpty, .slimed => return,
        .ssh => |ch| ch,
    };
    ch.waitEnded(5000);
    _ = win32.PostMessageW(self.window.hwnd, Window.WM_APP_CHILD_EXITED, self.id, 0);
}

fn onChildExited(ctx: ?*anyopaque, _: u8) callconv(.winapi) void {
    const self: *Session = @ptrCast(@alignCast(ctx));
    _ = win32.PostMessageW(self.window.hwnd, Window.WM_APP_CHILD_EXITED, self.id, 0);
}

fn fromHandler(handler: *StreamHandler) *Session {
    const stream: *ghostty_vt.TerminalStream = @fieldParentPtr("handler", handler);
    return @alignCast(@fieldParentPtr("stream", stream));
}

/// Stream effect for query replies (DSR, DECRQM, ...) and mode 2048
/// size reports. Runs with the terminal locked, usually on the reader
/// thread, so it must not wait on the UI thread.
fn writePty(handler: *StreamHandler, data: []const u8) void {
    const self = fromHandler(handler);
    self.writeChild(data);
}

/// Stream effect for OSC 0/2. Runs on the reader thread with the
/// terminal locked, so it posts to the UI thread rather than calling
/// SetWindowTextW, which waits on it.
fn titleChanged(handler: *StreamHandler) void {
    const self = fromHandler(handler);
    if (self.title_pending.swap(true, .acq_rel)) return;
    _ = win32.PostMessageW(self.window.hwnd, Window.WM_APP_TITLE_CHANGED, self.id, 0);
}

/// Take the child's new title. Clears the pending flag before reading,
/// so a change made after the read posts again.
pub fn titleUpdate(self: *Session) void {
    self.title_pending.store(false, .release);
    self.lockTerminal();
    self.title_len = titleToUtf16(&self.title_buf, self.terminal.getTitle() orelse "");
    self.unlockTerminal();
}

/// Stream effect for OSC 52 and OSC 5522 writes. Runs on the reader
/// thread with the terminal locked, so it hands the text to the UI
/// thread. A write that arrives before the last one is made replaces it.
fn clipboardWrite(handler: *StreamHandler, write: ghostty_vt.clipboard.Write) void {
    const self = fromHandler(handler);
    const access = self.window.config.@"clipboard-write";
    if (access != .allow) {
        log.info("denied a clipboard write (clipboard-write = {t})", .{access});
        return write.reply(.denied);
    }
    // Windows has one clipboard, so there's no selection or primary.
    if (write.location != .standard) return write.reply(.unsupported);

    // Text is the only representation we keep. No contents clears.
    const text: []const u8 = if (write.contents.len == 0) "" else for (write.contents) |c| {
        if (ghostty_vt.clipboard.isTextMime(c.mime)) break c.data;
    } else return write.reply(.unsupported);

    const copy = self.alloc.dupe(u8, text) catch return write.reply(.io_error);
    if (self.clipboard_write) |pending| {
        self.alloc.free(pending);
    } else {
        _ = win32.PostMessageW(self.window.hwnd, Window.WM_APP_CLIPBOARD_WRITE, self.id, 0);
    }
    self.clipboard_write = copy;
    write.reply(.{ .success = .{} });
}

/// Make the child's pending clipboard write.
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

/// Stream effect for OSC 52 and OSC 5522 reads. Runs on the reader
/// thread with the terminal locked, which is safe for reading: unlike
/// writing, it sends our window no messages.
fn clipboardRead(handler: *StreamHandler, read: ghostty_vt.clipboard.Read) void {
    const self = fromHandler(handler);
    const access = self.window.config.@"clipboard-read";
    if (access != .allow) {
        log.info("denied a clipboard read (clipboard-read = {t})", .{access});
        return read.reply(.denied);
    }
    if (read.location != .standard) return read.reply(.unsupported);

    const text = clipboard.get(self.alloc, null) catch |err| {
        log.warn("clipboard read failed: {}", .{err});
        return read.reply(.busy);
    };
    defer if (text) |t| self.alloc.free(t);

    // The text, under each text type asked for.
    var contents: [8]ghostty_vt.clipboard.Content = undefined;
    var n: usize = 0;
    if (text) |t| for (read.mimes) |mime| {
        if (n == contents.len) break;
        if (!ghostty_vt.clipboard.isTextMime(mime)) continue;
        contents[n] = .{ .mime = mime, .data = t };
        n += 1;
    };
    read.reply(.{ .success = .{
        .contents = contents[0..n],
        .available = if (text != null) &.{"text/plain"} else &.{},
    } });
}

/// Stream effect for program status reports (OSC 7501), and for a full
/// reset, which clears them. Runs on the reader thread with the terminal
/// locked.
fn programStatus(handler: *StreamHandler, report: ghostty_vt.osc.Command.ProgramStatus.Report) void {
    const self = fromHandler(handler);
    self.program_status.report(report);
    self.status_changed.store(true, .release);
}

/// Stream effect for shell integration (OSC 133): a new prompt means the
/// last command's program is gone, and with it its work in progress.
/// Runs on the reader thread with the terminal locked.
fn semanticPrompt(handler: *StreamHandler, event: ghostty_vt.SemanticPrompt) void {
    if (event.kind != .prompt_start) return;
    const self = fromHandler(handler);
    self.program_status.promptStarted();
    self.status_changed.store(true, .release);
}

/// The most pressing thing its programs report, for the sidebar.
pub fn statusSummary(self: *Session) ?ProgramStatus.Summary {
    self.lockTerminal();
    defer self.unlockTerminal();
    return self.program_status.summary();
}

/// ConPTY asks for DA1 at startup to learn what the terminal supports.
fn deviceAttributes(_: *StreamHandler) ghostty_vt.device_attributes.Attributes {
    return .{};
}

/// Track the modes libghostty-vt leaves to us. Runs on the reader thread
/// with the terminal locked.
fn unknownSequence(handler: *StreamHandler, seq: StreamHandler.UnknownSequence) void {
    const self = fromHandler(handler);
    switch (seq) {
        .mode => |m| if (m.mode == 9001 and !m.ansi) {
            self.win32_input = m.enabled;
        },
        else => {},
    }
}

/// Encode a key message and send it to the child.
pub fn keyInput(self: *Session, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM) void {
    // TranslateMessage already posted the WM_(SYS)CHAR / WM_(SYS)DEADCHAR
    // messages this key produced. Take them so the key and its text are
    // encoded together, as one event.
    const hwnd = self.window.hwnd;
    var utf16: [16]u16 = undefined;
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
    self.lockTerminal();
    const win32_input = self.win32_input;
    const opts: ghostty_vt.input.KeyEncodeOptions = .fromTerminal(&self.terminal);
    self.unlockTerminal();
    if (win32_input) return self.win32KeyInput(msg, wparam, lparam, utf16[0..len]);

    var utf8: [64]u8 = undefined;
    const text_len = std.unicode.utf16LeToUtf8(&utf8, utf16[0..len]) catch 0;
    const event = input.keyEvent(msg, wparam, lparam, utf8[0..text_len], composing);

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ghostty_vt.input.encodeKey(&w, event, opts) catch |err| {
        log.warn("key encode failed: {}", .{err});
        return;
    };
    // Following fixterms, the legacy encoder leaves ctrl+[, ctrl+i, and
    // ctrl+m to CSI u, which it only emits with the key's plain text, so
    // they encode to nothing. Send the C0 byte Windows produced (ESC,
    // TAB, CR), as xterm and Windows Terminal do.
    if (w.buffered().len == 0 and event.action != .release and
        text_len == 1 and std.ascii.isControl(utf8[0]))
    {
        w.writeByte(utf8[0]) catch unreachable;
    }
    if (w.buffered().len == 0) return;
    if (event.action != .release and !event.key.modifier()) self.typed();
    self.writeChild(w.buffered());
}

/// Copy the selected text to the clipboard. Returns false if nothing is
/// selected.
pub fn copySelection(self: *Session) bool {
    self.lockTerminal();
    const screen = self.terminal.screens.active;
    const sel = screen.selection orelse {
        self.unlockTerminal();
        return false;
    };
    const text = screen.selectionString(self.alloc, .{ .sel = sel });
    self.unlockTerminal();

    const utf8 = text catch |err| {
        log.err("selection to text failed: {}", .{err});
        return true;
    };
    defer self.alloc.free(utf8);
    clipboard.set(self.window.hwnd.?, utf8) catch |err| log.err("copy failed: {}", .{err});
    return true;
}

/// Send the clipboard's text to the child: bracketed if it asked for
/// that (mode 2004), else with newlines as CR, as the enter key sends.
/// Either way, control bytes that could signal the child or end the
/// paste early (ESC, ^C, ...) become spaces.
pub fn paste(self: *Session) void {
    const text = (clipboard.get(self.alloc, self.window.hwnd.?) catch |err| {
        log.err("paste failed: {}", .{err});
        return;
    }) orelse return;
    defer self.alloc.free(text);
    if (text.len == 0) return;

    self.lockTerminal();
    const opts: ghostty_vt.input.PasteOptions = .fromTerminal(&self.terminal);
    self.unlockTerminal();
    self.typed();
    const parts = ghostty_vt.input.encodePaste(text, opts);
    for (parts) |part| self.writeChild(part);
}

/// Send text from a WM_CHAR that no key message claimed: IME commits,
/// alt+numpad codes, and VK_PACKET input from SendInput.
pub fn charInput(self: *Session, unit: u16) void {
    self.lockTerminal();
    const win32_input = self.win32_input;
    self.unlockTerminal();
    if (win32_input) {
        // A press and release of no key, carrying the text. Surrogate
        // halves go as they come; the console pairs them.
        var buf: [64]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for ([_]bool{ true, false }) |down| {
            (input.Win32KeyEvent{ .char = unit, .down = down }).encode(&w) catch unreachable;
        }
        self.typed();
        self.writeChild(w.buffered());
        return;
    }

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
    self.typed();
    self.writeChild(utf8[0..len]);
}

/// Send a key in win32-input-mode: one event per UTF-16 unit of text it
/// produced, or one with no text.
fn win32KeyInput(self: *Session, msg: u32, wparam: win32.WPARAM, lparam: win32.LPARAM, text: []const u16) void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    if (text.len == 0) {
        const up = msg == win32.WM_KEYUP or msg == win32.WM_SYSKEYUP;
        const char = if (up) input.releaseChar(wparam, lparam) else 0;
        input.Win32KeyEvent.fromKey(msg, wparam, lparam, char).encode(&w) catch unreachable;
    }
    for (text) |unit| {
        input.Win32KeyEvent.fromKey(msg, wparam, lparam, unit).encode(&w) catch unreachable;
    }
    if ((msg == win32.WM_KEYDOWN or msg == win32.WM_SYSKEYDOWN) and !input.isModifier(wparam, lparam)) self.typed();
    self.writeChild(w.buffered());
}

/// Drop the selection, bring the viewport back from scrollback, and show
/// the cursor, as typing does.
fn typed(self: *Session) void {
    self.window.resetBlink();
    self.lockTerminal();
    defer self.unlockTerminal();
    const screen = self.terminal.screens.active;
    if (screen.selection != null) {
        screen.clearSelection();
        self.window.dirty = true;
    }
    if (screen.pages.viewport == .active) return;
    self.terminal.scrollViewport(.bottom);
    self.window.dirty = true;
}

/// Tell the child about a focus change if it asked for focus events
/// (mode 1004). ConPTY always asks, and passes them on to console
/// programs as FOCUS_EVENT records.
pub fn reportFocus(self: *Session, focused: bool) void {
    self.lockTerminal();
    const report = self.terminal.modes.get(.focus_event);
    self.unlockTerminal();
    if (!report) return;
    var buf: [ghostty_vt.input.max_focus_encode_size]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ghostty_vt.input.encodeFocus(&w, if (focused) .gained else .lost) catch unreachable;
    self.writeChild(w.buffered());
}

/// Report a mouse button press or release, or motion, to the child if it
/// asked for mouse events.
pub fn mouseInput(self: *Session, msg: u32, wparam: win32.WPARAM, pos: win32.POINT) void {
    const button: ?MouseButton, const action: MouseAction = if (input.mouseButton(msg, wparam)) |b|
        .{ b[0], if (b[1]) .press else .release }
    else
        .{ input.heldButton(wparam), .motion };
    const held = input.heldButton(wparam) != null;

    self.lockTerminal();
    // Shift selects even when the child asks for mouse events.
    if (!self.selecting and button == .left and action == .press) {
        if (self.terminal.flags.mouse_event != .none and wparam & win32.MK_SHIFT == 0) {
            self.selection.reset(&self.terminal);
        } else {
            self.selecting = true;
        }
    }
    if (self.selecting) {
        defer self.unlockTerminal();
        return self.selectionInput(msg, wparam, pos);
    }
    var opts: MouseEncodeOptions = .fromTerminal(&self.terminal, self.surfaceSize());
    self.unlockTerminal();
    opts.any_button_pressed = held;
    opts.last_cell = &self.mouse_cell;
    self.mouseReport(.{
        .action = action,
        .button = button,
        .mods = input.mouseMods(wparam),
        .pos = .{ .x = @floatFromInt(pos.x), .y = @floatFromInt(pos.y) },
    }, opts);
}

/// Start, extend, or finish a selection with the left button: a click
/// clears it, a drag selects cells (a rectangle with ctrl+alt), and
/// double and triple clicks select words and lines. Call with the
/// terminal locked.
fn selectionInput(self: *Session, msg: u32, wparam: win32.WPARAM, pos: win32.POINT) void {
    const t = &self.terminal;
    const config = self.window.config;
    const pin = t.screens.active.pages.pin(.{ .viewport = self.cellAt(pos) }) orelse return;
    const sel: ?ghostty_vt.Selection = switch (msg) {
        win32.WM_LBUTTONDOWN => self.selection.press(t, .{
            .time = messageTime(),
            .pin = pin,
            .xpos = @floatFromInt(pos.x),
            .ypos = @floatFromInt(pos.y),
            .max_distance = @floatFromInt(self.window.grid.metrics.cell_width),
            .repeat_interval = @as(u64, win32.GetDoubleClickTime()) * std.time.ns_per_ms,
            .word_boundary_codepoints = config.@"selection-word-chars".codepoints,
        }) catch |err| {
            log.err("selection failed: {}", .{err});
            return;
        },
        win32.WM_MOUSEMOVE => sel: {
            if (wparam & win32.MK_LBUTTON == 0) return;
            self.drag_pos = pos;
            const sel = self.selection.drag(t, .{
                .pin = pin,
                .xpos = @floatFromInt(pos.x),
                .ypos = @floatFromInt(pos.y),
                .rectangle = rectangleSelect(),
                .word_boundary_codepoints = config.@"selection-word-chars".codepoints,
                .geometry = self.dragGeometry(),
            });
            self.updateAutoscroll();
            break :sel sel;
        },
        win32.WM_LBUTTONUP => {
            self.endSelection(pin);
            return;
        },
        else => return,
    };
    t.screens.active.select(sel) catch |err| log.err("selection failed: {}", .{err});
    self.window.dirty = true;
}

/// Scroll the viewport one row toward a selection drag above or below
/// it, and extend the selection there.
pub fn autoscrollTick(self: *Session) void {
    self.lockTerminal();
    defer self.unlockTerminal();
    const t = &self.terminal;
    const sel = self.selection.autoscrollTick(t, .{
        .viewport = self.cellAt(self.drag_pos),
        .xpos = @floatFromInt(self.drag_pos.x),
        .ypos = @floatFromInt(self.drag_pos.y),
        .rectangle = rectangleSelect(),
        .word_boundary_codepoints = self.window.config.@"selection-word-chars".codepoints,
        .geometry = self.dragGeometry(),
    });
    self.updateAutoscroll();
    // A reset gesture (the screen switched) leaves the selection alone.
    if (self.selection.left_click_count == 0) return;
    t.screens.active.select(sel) catch |err| log.err("selection failed: {}", .{err});
    self.window.dirty = true;
}

/// Finish a selection drag, at `pin` if the button was released over a
/// cell. Call with the terminal locked.
fn endSelection(self: *Session, pin: ?ghostty_vt.Pin) void {
    self.selection.release(&self.terminal, .{ .pin = pin });
    self.selecting = false;
    self.updateAutoscroll();
}

/// End a selection drag that lost the mouse (alt+tab, a modal window, or
/// switching sessions).
pub fn cancelSelection(self: *Session) void {
    if (!self.selecting) return;
    self.lockTerminal();
    defer self.unlockTerminal();
    self.endSelection(null);
}

/// Run the autoscroll timer while the drag asks for it.
fn updateAutoscroll(self: *Session) void {
    const hwnd = self.window.hwnd;
    if (self.selection.left_drag_autoscroll == .none) {
        _ = win32.KillTimer(hwnd, Window.autoscroll_timer_id);
    } else {
        _ = win32.SetTimer(hwnd, Window.autoscroll_timer_id, 15, null);
    }
}

fn dragGeometry(self: *const Session) ghostty_vt.SelectionGesture.Drag.Geometry {
    return .{
        .columns = self.terminal.cols,
        .cell_width = self.window.grid.metrics.cell_width,
        .padding_left = self.pad.left,
        .screen_height = @intFromFloat(self.rect.h),
    };
}

/// The viewport cell under a position, clamped to the grid. Call with
/// the terminal locked.
fn cellAt(self: *const Session, pos: win32.POINT) ghostty_vt.Coordinate {
    const m = self.window.grid.metrics;
    const pad = self.pad;
    const x = @divFloor(pos.x - @as(i32, @intCast(pad.left)), @as(i32, @intCast(m.cell_width)));
    const y = @divFloor(pos.y - @as(i32, @intCast(pad.top)), @as(i32, @intCast(m.cell_height)));
    return .{
        .x = @intCast(std.math.clamp(x, 0, @as(i32, self.terminal.cols) - 1)),
        .y = @intCast(std.math.clamp(y, 0, @as(i32, self.terminal.rows) - 1)),
    };
}

/// Ctrl+alt drags select a rectangle, as in Ghostty on Linux.
fn rectangleSelect() bool {
    const mods = input.currentMods();
    return mods.ctrl and mods.alt;
}

/// When the message being handled was posted, for telling double clicks
/// apart. GetMessageTime is milliseconds since boot, wrapping at 2^32.
fn messageTime() std.Io.Timestamp {
    const ms: u32 = @bitCast(win32.GetMessageTime());
    return .{ .nanoseconds = @as(i96, ms) * std.time.ns_per_ms };
}

/// Scroll with the wheel: report wheel buttons if the child asked for
/// mouse events, else send arrow keys on the alternate screen with
/// alternate scroll (mode 1007) set, else move the viewport through
/// scrollback.
pub fn mouseWheel(self: *Session, msg: u32, wparam: win32.WPARAM, pos: win32.POINT) void {
    const horizontal = msg == win32.WM_MOUSEHWHEEL;
    const rotation: i16 = @bitCast(win32.hiword(wparam));

    self.lockTerminal();
    const t = &self.terminal;
    const reporting = t.flags.mouse_event != .none;
    const alternate_scroll = !reporting and
        t.screens.active_key == .alternate and
        t.modes.get(.mouse_alternate_scroll);
    const cursor_keys = t.modes.get(.cursor_keys);
    const opts: MouseEncodeOptions = .fromTerminal(t, self.surfaceSize());
    const rows = t.rows;
    self.unlockTerminal();

    if (horizontal and !reporting) return;

    // Reports are one per notch; programs pick how far that scrolls.
    const lines: u32 = if (reporting) 1 else lines: {
        var n: u32 = 3;
        _ = win32.SystemParametersInfoW(win32.SPI_GETWHEELSCROLLLINES, 0, &n, 0);
        break :lines if (n == win32.WHEEL_PAGESCROLL) rows else @min(n, rows);
    };
    const remainder = &self.wheel_remainder[@intFromBool(horizontal)];
    remainder.* += @as(i32, rotation) * @as(i32, @intCast(lines));
    const steps = @divTrunc(remainder.*, win32.WHEEL_DELTA);
    remainder.* -= steps * win32.WHEEL_DELTA;
    if (steps == 0) return;
    // Positive rotation is away from the user, or to the right.
    const up = steps > 0;
    const count = @abs(steps);

    if (reporting) {
        const event: MouseEvent = .{
            .button = if (horizontal)
                (if (up) .seven else .six)
            else
                (if (up) .four else .five),
            .mods = input.mouseMods(wparam),
            .pos = .{ .x = @floatFromInt(pos.x), .y = @floatFromInt(pos.y) },
        };
        for (0..count) |_| self.mouseReport(event, opts);
    } else if (alternate_scroll) {
        const seq: []const u8 = if (cursor_keys)
            (if (up) "\x1bOA" else "\x1bOB")
        else
            (if (up) "\x1b[A" else "\x1b[B");
        for (0..count) |_| self.writeChild(seq);
    } else {
        const delta: isize = @intCast(count);
        self.lockTerminal();
        self.terminal.scrollViewport(.{ .delta = if (up) -delta else delta });
        self.unlockTerminal();
        self.window.dirty = true;
    }
}

fn mouseReport(self: *Session, event: MouseEvent, opts: MouseEncodeOptions) void {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    ghostty_vt.input.encodeMouse(&w, event, opts) catch |err| {
        log.warn("mouse encode failed: {}", .{err});
        return;
    };
    if (w.buffered().len == 0) return;
    self.writeChild(w.buffered());
}

/// The pane as the mouse encoder sees it, to map positions to cells.
/// Call with the terminal locked.
fn surfaceSize(self: *const Session) @FieldType(MouseEncodeOptions, "size") {
    const size: struct { width: u32, height: u32 } = .{ .width = @intFromFloat(self.rect.w), .height = @intFromFloat(self.rect.h) };
    const m = self.window.grid.metrics;
    const pad = self.pad;
    return .{
        .screen = .{ .width = size.width, .height = size.height },
        .cell = .{ .width = m.cell_width, .height = m.cell_height },
        .padding = .{
            .top = pad.top,
            .left = pad.left,
            .right = size.width -| pad.left -| @as(u32, self.terminal.cols) * m.cell_width,
            .bottom = size.height -| pad.top -| @as(u32, self.terminal.rows) * m.cell_height,
        },
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
