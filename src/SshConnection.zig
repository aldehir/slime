//! An SSH connection, held by a slime-ssh helper process (ssh/ in this
//! repository), whose session channels back our SSH sessions.
//!
//! Each channel is a pair of anonymous pipes whose far ends we move into
//! the helper, so a session reads and writes it as it does a ConPTY. The
//! control protocol (ssh/internal/proto) runs on the helper's stdin and
//! stdout. A thread reads the helper's side of it and records how each
//! channel ended, the one thing sessions need from it.
const SshConnection = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const win32 = @import("win32/win32.zig");

const log = std.log.scoped(.ssh);

/// ssh/internal/proto's Version.
const protocol_version = 1;
/// proto.FeaturePrompts: login questions come as prompts for a dialog.
const feature_prompts: u32 = 1 << 0;
const max_frame = 1 << 20;
/// Long enough for long-path-aware installs.
const max_path = 32 * 1024;
const helper_name = std.unicode.utf8ToUtf16LeStringLiteral("slime-ssh.exe");

const MsgType = enum(u8) {
    hello = 1,
    open = 2,
    resize = 3,
    close = 4,
    answer = 5,
    hello_reply = 65,
    connected = 66,
    opened = 67,
    exit = 68,
    @"error" = 69,
    disconnected = 70,
    prompt = 71,
    info = 72,
    _,
};

alloc: Allocator,
/// What the helper was given, like `ssh://user@host`. Owned.
destination: []const u16,
/// Told when logging in has something to show (`takeLogin`).
notify: Notify,
process: win32.HANDLE,
job: win32.HANDLE,
/// Our ends of the helper's stdin and stdout.
control_in: win32.HANDLE,
control_out: win32.HANDLE,
reader: ?std.Thread = null,

/// Guards `channels` and `alive`, and each channel's `ending`.
lock: win32.SRWLOCK = .{},
channels: std.ArrayList(*Channel) = .empty,
/// The helper is running, connecting or connected. Cleared when it
/// disconnects or exits, after which every channel has ended.
alive: bool = true,

/// What the helper last asked or reported while logging in, for the
/// window to take. Guarded by `lock`.
login: Login = .{},
/// Logged in. Guarded by `lock`.
connected: bool = false,

/// Channels opened and not yet released. UI thread only.
refs: u32 = 0,

/// A window message posted from the reader thread when `login` or
/// `connected` changes. WPARAM is the channel ID, 0 for the connection.
pub const Notify = struct {
    hwnd: win32.HWND,
    msg: u32,
};

/// Logging in's latest, taken at once by `takeLogin`.
pub const Login = struct {
    /// The channel it's on: the one connecting.
    channel: u32 = 0,
    prompt: ?*Prompt = null,
    /// A status line from the server. Owned, in the connection's
    /// allocator.
    info: ?[]const u16 = null,

    pub fn deinit(self: *Login, alloc: Allocator) void {
        if (self.prompt) |p| p.destroy();
        if (self.info) |i| alloc.free(i);
        self.* = .{};
    }
};

/// A question while logging in (proto.Prompt), its text in UTF-16 for
/// the chrome.
pub const Prompt = struct {
    arena: std.heap.ArenaAllocator,
    kind: Kind,
    title: []const u16,
    /// The body.
    text: []const u16,
    /// For a monospace box: a key's path, fingerprints.
    detail: []const u16,
    /// Why the last answer didn't work.
    err: []const u16,
    questions: []const Question,

    pub const Kind = enum(u8) {
        password = 1,
        passphrase = 2,
        interactive = 3,
        unknown_host = 4,
        changed_host = 5,
        _,
    };

    /// A field. `label` may run over several lines; the last names the
    /// field.
    pub const Question = struct {
        label: []const u16,
        echo: bool,
    };

    /// More than any login asks at once.
    pub const max_questions = 8;

    fn parse(gpa: Allocator, payload: []const u8) !*Prompt {
        const self = try gpa.create(Prompt);
        errdefer gpa.destroy(self);
        self.arena = .init(gpa);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        var r: Reader = .{ .buf = payload };
        self.kind = @enumFromInt(try r.readU8());
        self.title = try toUtf16(a, try r.readStr());
        self.text = try toUtf16(a, try r.readStr());
        self.detail = try toUtf16(a, try r.readStr());
        self.err = try toUtf16(a, try r.readStr());
        const n = try r.readU32();
        if (n > max_questions) return error.TooManyQuestions;
        const questions = try a.alloc(Question, n);
        for (questions) |*q| q.* = .{
            .label = try toUtf16(a, try r.readStr()),
            .echo = try r.readU8() != 0,
        };
        self.questions = questions;
        return self;
    }

    pub fn destroy(self: *Prompt) void {
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// The button a prompt was answered with (proto.Choice).
pub const Choice = enum(u8) {
    cancel = 0,
    accept = 1,
    skip = 2,
};

pub const Channel = struct {
    conn: *SshConnection,
    id: u32,
    /// Our ends: keys go in `input`, the remote's output comes out of
    /// `output`.
    input: win32.HANDLE,
    output: win32.HANDLE,
    /// Set once `ending` is known.
    done: win32.HANDLE,
    /// Guarded by the connection's lock until `done` is set.
    ending: Ending = .{},

    /// Read output. Blocks until some is available; returns 0 at EOF,
    /// which comes after the helper reports how the channel ended.
    pub fn read(self: *Channel, buf: []u8) !usize {
        var n: u32 = 0;
        const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
        if (win32.ReadFile(self.output, buf.ptr, len, &n, null) == 0) {
            if (win32.GetLastError() == win32.ERROR_BROKEN_PIPE) return 0;
            return win32.lastError("ReadFile");
        }
        return n;
    }

    /// Write input. Called from both the UI thread and the reader
    /// thread (query replies), like `Pty.write`.
    pub fn write(self: *Channel, data: []const u8) void {
        writeAll(self.input, data) catch {};
    }

    pub fn resize(self: *Channel, cols: u16, rows: u16) void {
        var p: Payload = .{};
        p.putU16(cols);
        p.putU16(rows);
        self.conn.send(.resize, self.id, p.bytes()) catch {};
    }

    /// Wait for the helper to say how the channel ended, which it does
    /// just before closing the channel's output.
    pub fn waitEnded(self: *Channel, ms: u32) void {
        _ = win32.WaitForSingleObject(self.done, ms);
    }

    /// Ask the helper to close the channel. `read` returns 0 once it has.
    /// UI thread only.
    pub fn close(self: *Channel) void {
        const conn = self.conn;
        conn.send(.close, self.id, &.{}) catch {};
        win32.AcquireSRWLockExclusive(&conn.lock);
        conn.removeChannel(self);
        conn.endLocked(self, false, "closed");
        win32.ReleaseSRWLockExclusive(&conn.lock);
    }

    /// Free the channel after `close`, once nothing reads or writes it,
    /// and release the connection. UI thread only.
    pub fn deinit(self: *Channel) void {
        const conn = self.conn;
        _ = win32.CloseHandle(self.input);
        _ = win32.CloseHandle(self.output);
        _ = win32.CloseHandle(self.done);
        conn.alloc.destroy(self);
        conn.release();
    }
};

/// How a channel ended, for the session to show.
pub const Ending = struct {
    const text_buf_len = 256;

    /// The remote command ran and exited. Otherwise the channel failed:
    /// it couldn't open, or the connection broke or never came up.
    exited: bool = false,
    text_buf: [text_buf_len]u8 = undefined,
    text_len: usize = 0,

    pub fn text(self: *const Ending) []const u8 {
        return self.text_buf[0..self.text_len];
    }
};

/// Run the helper, which connects to `destination` (`ssh://...`, or
/// whatever slime-ssh takes) once the first channel opens.
pub fn spawn(alloc: Allocator, destination: []const u16, notify: Notify) !*SshConnection {
    if (std.mem.indexOfAny(u16, destination, std.unicode.utf8ToUtf16LeStringLiteral("\" \t")) != null) return error.BadDestination;

    var exe_buf: [max_path]u16 = undefined;
    const exe = try helperPath(&exe_buf);
    var cmd: std.ArrayList(u16) = .empty;
    defer cmd.deinit(alloc);
    try cmd.append(alloc, '"');
    try cmd.appendSlice(alloc, exe);
    try cmd.appendSlice(alloc, std.unicode.utf8ToUtf16LeStringLiteral("\" "));
    try cmd.appendSlice(alloc, destination);
    try cmd.append(alloc, 0);

    // The helper's ends of its stdio are inherited; ours aren't.
    var inheritable: win32.SECURITY_ATTRIBUTES = .{ .bInheritHandle = win32.TRUE };
    var stdin_read: win32.HANDLE = undefined;
    var stdin_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&stdin_read, &stdin_write, &inheritable, 0) == 0) return win32.lastError("CreatePipe");
    defer _ = win32.CloseHandle(stdin_read);
    errdefer _ = win32.CloseHandle(stdin_write);
    var stdout_read: win32.HANDLE = undefined;
    var stdout_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&stdout_read, &stdout_write, &inheritable, 0) == 0) return win32.lastError("CreatePipe");
    defer _ = win32.CloseHandle(stdout_write);
    errdefer _ = win32.CloseHandle(stdout_read);
    _ = win32.SetHandleInformation(stdin_write, win32.HANDLE_FLAG_INHERIT, 0);
    _ = win32.SetHandleInformation(stdout_read, win32.HANDLE_FLAG_INHERIT, 0);

    // Its log goes to our stderr, when we have one (the console build).
    var stderr: ?win32.HANDLE = null;
    if (win32.GetStdHandle(win32.STD_ERROR_HANDLE)) |h| {
        var dup: win32.HANDLE = undefined;
        if (win32.DuplicateHandle(win32.GetCurrentProcess(), h, win32.GetCurrentProcess(), &dup, 0, win32.TRUE, win32.DUPLICATE_SAME_ACCESS) != 0) stderr = dup;
    }
    defer if (stderr) |h| {
        _ = win32.CloseHandle(h);
    };

    const job = win32.CreateJobObjectW(null, null) orelse return win32.lastError("CreateJobObjectW");
    errdefer _ = win32.CloseHandle(job);
    const limits: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{
        .BasicLimitInformation = .{ .LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE },
    };
    if (win32.SetInformationJobObject(job, win32.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0)
        return win32.lastError("SetInformationJobObject");

    // Inherit exactly these handles, not whatever else is inheritable
    // in our process at the time.
    var handles: [3]win32.HANDLE = undefined;
    handles[0] = stdin_read;
    handles[1] = stdout_write;
    var handle_count: usize = 2;
    if (stderr) |h| {
        handles[2] = h;
        handle_count = 3;
    }
    var attrs_size: usize = 0;
    _ = win32.InitializeProcThreadAttributeList(null, 1, 0, &attrs_size);
    var attrs_buf: [128]u8 align(@alignOf(usize)) = undefined;
    std.debug.assert(attrs_size <= attrs_buf.len);
    const attrs: *anyopaque = &attrs_buf;
    if (win32.InitializeProcThreadAttributeList(attrs, 1, 0, &attrs_size) == 0)
        return win32.lastError("InitializeProcThreadAttributeList");
    defer win32.DeleteProcThreadAttributeList(attrs);
    if (win32.UpdateProcThreadAttribute(
        attrs,
        0,
        win32.PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        &handles,
        handle_count * @sizeOf(win32.HANDLE),
        null,
        null,
    ) == 0) return win32.lastError("UpdateProcThreadAttribute");

    var si: win32.STARTUPINFOEXW = .{ .lpAttributeList = attrs };
    si.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;
    si.StartupInfo.hStdInput = stdin_read;
    si.StartupInfo.hStdOutput = stdout_write;
    si.StartupInfo.hStdError = stderr;

    // CREATE_NO_WINDOW: the helper is a console program, and would
    // otherwise get a console window of its own.
    var pi: win32.PROCESS_INFORMATION = undefined;
    if (win32.CreateProcessW(
        null,
        @ptrCast(cmd.items.ptr),
        null,
        null,
        win32.TRUE,
        win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT | win32.CREATE_SUSPENDED | win32.CREATE_NO_WINDOW,
        null,
        null,
        &si,
        &pi,
    ) == 0) return win32.lastError("CreateProcessW");
    errdefer _ = win32.CloseHandle(pi.hProcess);
    defer _ = win32.CloseHandle(pi.hThread);
    if (win32.AssignProcessToJobObject(job, pi.hProcess) == 0)
        return win32.lastError("AssignProcessToJobObject");
    _ = win32.ResumeThread(pi.hThread);

    const self = try alloc.create(SshConnection);
    errdefer alloc.destroy(self);
    const owned_destination = try alloc.dupe(u16, destination);
    errdefer alloc.free(owned_destination);
    self.* = .{
        .alloc = alloc,
        .destination = owned_destination,
        .notify = notify,
        .process = pi.hProcess,
        .job = job,
        .control_in = stdin_write,
        .control_out = stdout_read,
    };
    var hello: Payload = .{};
    hello.putU32(protocol_version);
    hello.putU32(feature_prompts);
    try self.send(.hello, 0, hello.bytes());
    self.reader = try std.Thread.spawn(.{}, readLoop, .{self});
    log.info("started slime-ssh for {f}", .{std.unicode.fmtUtf16Le(destination)});
    return self;
}

/// slime-ssh.exe next to our executable.
fn helperPath(buf: *[max_path]u16) ![]const u16 {
    const n = win32.GetModuleFileNameW(null, buf, buf.len);
    if (n == 0 or n >= buf.len) return win32.lastError("GetModuleFileNameW");
    const dir_end = (std.mem.lastIndexOfScalar(u16, buf[0..n], '\\') orelse return error.Win32) + 1;
    if (dir_end + helper_name.len > buf.len) return error.NameTooLong;
    @memcpy(buf[dir_end..][0..helper_name.len], helper_name);
    return buf[0 .. dir_end + helper_name.len];
}

/// The destination without its `ssh://`, for showing.
pub fn label(self: *const SshConnection) []const u16 {
    return labelFor(self.destination);
}

/// `destination` without its `ssh://`.
pub fn labelFor(destination: []const u16) []const u16 {
    const scheme = std.unicode.utf8ToUtf16LeStringLiteral("ssh://");
    return if (std.mem.startsWith(u16, destination, scheme)) destination[scheme.len..] else destination;
}

/// The helper is running, so channels opened on it can work.
pub fn isAlive(self: *SshConnection) bool {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.alive;
}

/// Open a channel with a shell, in `cwd` if given. `id` must be unique
/// and nonzero. UI thread only.
pub fn open(self: *SshConnection, id: u32, cols: u16, rows: u16, cwd: ?[]const u8) !*Channel {
    std.debug.assert(id != 0);
    var input_read: win32.HANDLE = undefined;
    var input_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&input_read, &input_write, null, 0) == 0) return win32.lastError("CreatePipe");
    errdefer _ = win32.CloseHandle(input_write);
    var output_read: win32.HANDLE = undefined;
    var output_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&output_read, &output_write, null, 0) == 0) {
        _ = win32.CloseHandle(input_read);
        return win32.lastError("CreatePipe");
    }
    errdefer _ = win32.CloseHandle(output_read);

    // DUPLICATE_CLOSE_SOURCE closes our copies even on failure. Only the
    // helper may hold these ends, so each side sees EOF when the other
    // closes. If the second move fails, the helper never learns of the
    // first; it leaks there until the helper exits.
    const helper_in = self.moveHandle(input_read) catch |err| {
        _ = win32.CloseHandle(output_write);
        return err;
    };
    const helper_out = try self.moveHandle(output_write);

    const done = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return win32.lastError("CreateEventW");
    errdefer _ = win32.CloseHandle(done);
    const ch = try self.alloc.create(Channel);
    errdefer self.alloc.destroy(ch);
    ch.* = .{
        .conn = self,
        .id = id,
        .input = input_write,
        .output = output_read,
        .done = done,
    };

    win32.AcquireSRWLockExclusive(&self.lock);
    const added = self.channels.append(self.alloc, ch);
    if (!self.alive) self.endLocked(ch, false, "not connected");
    win32.ReleaseSRWLockExclusive(&self.lock);
    try added;
    errdefer {
        win32.AcquireSRWLockExclusive(&self.lock);
        self.removeChannel(ch);
        win32.ReleaseSRWLockExclusive(&self.lock);
    }

    var p: Payload = .{};
    p.putU64(@intFromPtr(helper_in));
    p.putU64(@intFromPtr(helper_out));
    p.putU16(cols);
    p.putU16(rows);
    p.putStr("xterm-256color");
    p.putStr(cwd orelse "");
    if (p.overflow) return error.NameTooLong;
    try self.send(.open, id, p.bytes());
    self.refs += 1;
    return ch;
}

fn moveHandle(self: *SshConnection, h: win32.HANDLE) !win32.HANDLE {
    var target: win32.HANDLE = undefined;
    if (win32.DuplicateHandle(
        win32.GetCurrentProcess(),
        h,
        self.process,
        &target,
        0,
        win32.FALSE,
        win32.DUPLICATE_SAME_ACCESS | win32.DUPLICATE_CLOSE_SOURCE,
    ) == 0) return win32.lastError("DuplicateHandle");
    return target;
}

/// Drop a channel's reference, shutting the helper down after the last.
fn release(self: *SshConnection) void {
    self.refs -= 1;
    self.shutdownIfUnused();
}

/// Shut down and free a connection no channel uses: one that the last
/// channel was released from, or whose first `open` failed. UI thread
/// only.
pub fn shutdownIfUnused(self: *SshConnection) void {
    if (self.refs > 0) return;

    // Closing its stdin tells the helper we're gone; it closes the
    // connection and exits. Closing the job kills it if it doesn't.
    _ = win32.CloseHandle(self.control_in);
    _ = win32.WaitForSingleObject(self.process, 2000);
    _ = win32.CloseHandle(self.job);
    if (self.reader) |t| t.join();
    _ = win32.CloseHandle(self.control_out);
    _ = win32.CloseHandle(self.process);
    self.channels.deinit(self.alloc);
    self.login.deinit(self.alloc);
    self.alloc.free(self.destination);
    self.alloc.destroy(self);
}

/// Take what logging in last asked or reported, which the caller then
/// owns (`Login.deinit` with this connection's allocator). UI thread
/// only.
pub fn takeLogin(self: *SshConnection) Login {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    const login = self.login;
    self.login = .{};
    return login;
}

/// Logged in, so new channels open without asking anything.
pub fn isConnected(self: *SshConnection) bool {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    return self.connected;
}

/// Reply to the prompt on channel `id`, one answer per question. A
/// cancel with no prompt waiting gives up on logging in. UI thread
/// only.
pub fn sendAnswer(self: *SshConnection, id: u32, choice: Choice, answers: []const []const u16) !void {
    var p: Payload = .{};
    p.putU8(@intFromEnum(choice));
    p.putU32(@intCast(answers.len));
    for (answers) |units| {
        // A field holds at most 256 units, at most 3 bytes each.
        var buf: [1024]u8 = undefined;
        const n = std.unicode.utf16LeToUtf8(&buf, units) catch 0;
        p.putStr(buf[0..n]);
    }
    if (p.overflow) return error.NameTooLong;
    try self.send(.answer, id, p.bytes());
}

/// Send a control message. UI thread only.
fn send(self: *SshConnection, msg: MsgType, id: u32, payload: []const u8) !void {
    var header: [9]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(5 + payload.len), .little);
    header[4] = @intFromEnum(msg);
    std.mem.writeInt(u32, header[5..9], id, .little);
    // One write: the helper reads whole frames regardless, but a frame
    // split between writes is harder to follow in a pipe trace.
    var buf: [9 + Payload.capacity]u8 = undefined;
    @memcpy(buf[0..9], &header);
    @memcpy(buf[9..][0..payload.len], payload);
    try writeAll(self.control_in, buf[0 .. 9 + payload.len]);
}

/// Write to a pipe the helper reads. Failing is expected once the helper
/// has closed its end (the channel ended, or it exited), so it isn't
/// logged.
fn writeAll(h: win32.HANDLE, data: []const u8) !void {
    var rest = data;
    while (rest.len > 0) {
        var n: u32 = 0;
        const len: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
        if (win32.WriteFile(h, rest.ptr, len, &n, null) == 0) return error.BrokenPipe;
        rest = rest[n..];
    }
}

/// Control reader thread: record what the helper reports until it
/// exits.
fn readLoop(self: *SshConnection) void {
    const buf = self.alloc.alloc(u8, max_frame) catch {
        self.endAll("out of memory");
        return;
    };
    defer self.alloc.free(buf);
    var reason: []const u8 = "slime-ssh exited";
    while (true) {
        const frame = readFrame(self.control_out, buf) catch break;
        self.handle(frame) catch |err| switch (err) {
            error.VersionMismatch => {
                reason = "slime-ssh.exe doesn't match this slime (protocol version)";
                break;
            },
            else => log.warn("bad message from slime-ssh: {}", .{err}),
        };
    }
    self.endAll(reason);
}

const Frame = struct {
    type: MsgType,
    id: u32,
    payload: []const u8,
};

fn readFrame(h: win32.HANDLE, buf: []u8) !Frame {
    var len_buf: [4]u8 = undefined;
    try readExact(h, &len_buf);
    const len = std.mem.readInt(u32, &len_buf, .little);
    if (len < 5 or len > buf.len) return error.BadFrame;
    try readExact(h, buf[0..len]);
    return .{
        .type = @enumFromInt(buf[0]),
        .id = std.mem.readInt(u32, buf[1..5], .little),
        .payload = buf[5..len],
    };
}

fn readExact(h: win32.HANDLE, buf: []u8) !void {
    var got: usize = 0;
    while (got < buf.len) {
        var n: u32 = 0;
        if (win32.ReadFile(h, buf[got..].ptr, @intCast(buf.len - got), &n, null) == 0 or n == 0)
            return error.EndOfStream;
        got += n;
    }
}

fn handle(self: *SshConnection, f: Frame) !void {
    var r: Reader = .{ .buf = f.payload };
    switch (f.type) {
        .hello_reply => {
            const version = try r.readU32();
            if (version != protocol_version) {
                log.err("slime-ssh speaks protocol {d}, we speak {d}", .{ version, protocol_version });
                return error.VersionMismatch;
            }
        },
        .connected => {
            log.info("connected", .{});
            win32.AcquireSRWLockExclusive(&self.lock);
            self.connected = true;
            win32.ReleaseSRWLockExclusive(&self.lock);
            self.post(0);
        },
        .prompt => {
            const prompt = try Prompt.parse(self.alloc, f.payload);
            win32.AcquireSRWLockExclusive(&self.lock);
            if (self.login.prompt) |old| old.destroy();
            self.login.prompt = prompt;
            self.login.channel = f.id;
            win32.ReleaseSRWLockExclusive(&self.lock);
            self.post(f.id);
        },
        .info => {
            const text = try toUtf16(self.alloc, try r.readStr());
            win32.AcquireSRWLockExclusive(&self.lock);
            if (self.login.info) |old| self.alloc.free(old);
            self.login.info = text;
            self.login.channel = f.id;
            win32.ReleaseSRWLockExclusive(&self.lock);
            self.post(f.id);
        },
        .opened => {},
        .exit => {
            const status: i32 = @bitCast(try r.readU32());
            const signal = try r.readStr();
            var buf: [Ending.text_buf_len]u8 = undefined;
            const text = if (signal.len > 0)
                std.fmt.bufPrint(&buf, "killed by signal {s}", .{signal}) catch "killed by a signal"
            else if (status >= 0)
                std.fmt.bufPrint(&buf, "exited with status {d}", .{status}) catch unreachable
            else
                "exited";
            self.end(f.id, true, text);
        },
        .@"error" => self.end(f.id, false, try r.readStr()),
        .disconnected => {
            const reason = try r.readStr();
            log.info("disconnected: {s}", .{reason});
            self.endAll(reason);
        },
        else => log.warn("unexpected message {d} from slime-ssh", .{@intFromEnum(f.type)}),
    }
}

fn post(self: *SshConnection, id: u32) void {
    _ = win32.PostMessageW(self.notify.hwnd, self.notify.msg, id, 0);
}

/// `s` as UTF-16, or its bytes as Latin-1 if it isn't UTF-8, rather
/// than nothing.
fn toUtf16(a: Allocator, s: []const u8) ![]const u16 {
    return std.unicode.utf8ToUtf16LeAlloc(a, s) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const out = try a.alloc(u16, s.len);
            for (out, s) |*o, b| o.* = b;
            return out;
        },
    };
}

fn end(self: *SshConnection, id: u32, exited: bool, text: []const u8) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    for (self.channels.items) |ch| {
        if (ch.id == id) self.endLocked(ch, exited, text);
    }
}

/// End every channel still open: the helper is gone or disconnected.
fn endAll(self: *SshConnection, text: []const u8) void {
    win32.AcquireSRWLockExclusive(&self.lock);
    defer win32.ReleaseSRWLockExclusive(&self.lock);
    self.alive = false;
    for (self.channels.items) |ch| self.endLocked(ch, false, text);
}

/// Record how `ch` ended, if that isn't known yet, and wake its reader.
fn endLocked(_: *SshConnection, ch: *Channel, exited: bool, text: []const u8) void {
    if (win32.WaitForSingleObject(ch.done, 0) == win32.WAIT_OBJECT_0) return;
    const n = @min(text.len, ch.ending.text_buf.len);
    @memcpy(ch.ending.text_buf[0..n], text[0..n]);
    ch.ending.text_len = n;
    ch.ending.exited = exited;
    _ = win32.SetEvent(ch.done);
}

fn removeChannel(self: *SshConnection, ch: *Channel) void {
    for (self.channels.items, 0..) |c, i| {
        if (c == ch) {
            _ = self.channels.swapRemove(i);
            return;
        }
    }
}

/// A control message payload, built on the stack: the largest is an
/// open with a cwd (OSC 7 limits it to 4 KiB).
const Payload = struct {
    const capacity = 8192;

    buf: [capacity]u8 = undefined,
    len: usize = 0,
    overflow: bool = false,

    fn bytes(self: *const Payload) []const u8 {
        return self.buf[0..self.len];
    }

    fn put(self: *Payload, data: []const u8) void {
        if (self.len + data.len > capacity) {
            self.overflow = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..data.len], data);
        self.len += data.len;
    }

    fn putU8(self: *Payload, v: u8) void {
        self.put(&.{v});
    }

    fn putU16(self: *Payload, v: u16) void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .little);
        self.put(&b);
    }

    fn putU32(self: *Payload, v: u32) void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        self.put(&b);
    }

    fn putU64(self: *Payload, v: u64) void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .little);
        self.put(&b);
    }

    fn putStr(self: *Payload, s: []const u8) void {
        self.putU32(@intCast(s.len));
        self.put(s);
    }
};

/// Reads payload fields. Bytes past the known fields are ignored, so the
/// helper can add fields to a message.
const Reader = struct {
    buf: []const u8,

    fn take(self: *Reader, n: usize) ![]const u8 {
        if (self.buf.len < n) return error.Truncated;
        const b = self.buf[0..n];
        self.buf = self.buf[n..];
        return b;
    }

    fn readU8(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }

    fn readU32(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn readStr(self: *Reader) ![]const u8 {
        return self.take(try self.readU32());
    }
};

/// The directory in an OSC 7 report (`file://host/path`, percent-encoded),
/// decoded into `buf`, for starting a new remote shell where the last one
/// was.
pub fn pwdFromUrl(buf: []u8, url: []const u8) ?[]const u8 {
    const rest = if (std.mem.startsWith(u8, url, "file://"))
        url["file://".len..]
    else if (std.mem.startsWith(u8, url, "kitty-shell-cwd://"))
        url["kitty-shell-cwd://".len..]
    else
        return null;
    const path = rest[std.mem.indexOfScalar(u8, rest, '/') orelse return null ..];
    var n: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (n += 1) {
        if (n == buf.len) return null;
        if (path[i] == '%' and i + 2 < path.len) {
            buf[n] = std.fmt.parseInt(u8, path[i + 1 .. i + 3], 16) catch return null;
            i += 3;
        } else {
            buf[n] = path[i];
            i += 1;
        }
    }
    return buf[0..n];
}

test "frames match the Go side's wire format" {
    // ssh/internal/proto TestWireFormat: Resize{0x0102, 0x0304} on 2.
    var p: Payload = .{};
    p.putU16(0x0102);
    p.putU16(0x0304);
    var header: [9]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(5 + p.len), .little);
    header[4] = @intFromEnum(MsgType.resize);
    std.mem.writeInt(u32, header[5..9], 2, .little);
    try std.testing.expectEqualSlices(u8, &.{ 9, 0, 0, 0, 3, 2, 0, 0, 0 }, &header);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01, 0x04, 0x03 }, p.bytes());
}

test Reader {
    var r: Reader = .{ .buf = &.{ 3, 0, 0, 0, 'K', 'I', 'L', 0xff } };
    try std.testing.expectEqualStrings("KIL", try r.readStr());
    try std.testing.expectError(error.Truncated, r.readU32());
    var bad: Reader = .{ .buf = &.{ 9, 0, 0, 0, 'x' } };
    try std.testing.expectError(error.Truncated, bad.readStr());
}

test "prompts parse as the Go side sends them" {
    // ssh/internal/proto Prompt{Kind: PromptPassword, Title: "T",
    // Questions: [{Label: "pw: "}]}.
    const payload = [_]u8{1} ++ [_]u8{ 1, 0, 0, 0, 'T' } ++ [_]u8{0} ** 12 ++ [_]u8{ 1, 0, 0, 0 } ++
        [_]u8{ 4, 0, 0, 0, 'p', 'w', ':', ' ', 0 };
    const p = try Prompt.parse(std.testing.allocator, &payload);
    defer p.destroy();
    try std.testing.expectEqual(Prompt.Kind.password, p.kind);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("T"), p.title);
    try std.testing.expectEqual(@as(usize, 1), p.questions.len);
    try std.testing.expectEqualSlices(u16, std.unicode.utf8ToUtf16LeStringLiteral("pw: "), p.questions[0].label);
    try std.testing.expect(!p.questions[0].echo);
    try std.testing.expectError(error.Truncated, Prompt.parse(std.testing.allocator, payload[0..20]));
}

test pwdFromUrl {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("/home/alde/it's here", pwdFromUrl(&buf, "file://dev1/home/alde/it's%20here").?);
    try std.testing.expectEqualStrings("/tmp", pwdFromUrl(&buf, "kitty-shell-cwd://dev1/tmp").?);
    try std.testing.expectEqualStrings("/", pwdFromUrl(&buf, "file:///").?);
    try std.testing.expectEqual(null, pwdFromUrl(&buf, "/tmp"));
    try std.testing.expectEqual(null, pwdFromUrl(&buf, "file://dev1/bad%zz"));
}
