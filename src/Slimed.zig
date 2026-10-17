//! A session kept by slimed (ssh/cmd/slimed), the daemon that owns local
//! ptys so they outlive the window. Each of ours is its own connection to
//! the daemon's pipe, attached to one of its sessions, which the reader
//! thread reads frames from as it would read a ConPTY's output.
//!
//! Attaching returns a snapshot of the session's terminal for the session
//! to decode into its own; output after that continues from exactly where
//! the snapshot ends. The protocol is ssh/internal/persist's (wire.go).
const Slimed = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const win32 = @import("win32/win32.zig");

const log = std.log.scoped(.slimed);

const L = std.unicode.utf8ToUtf16LeStringLiteral;

/// ssh/internal/persist's Version.
const protocol_version = 1;
const max_frame = 1 << 20;
/// Long enough for long-path-aware installs.
const max_path = 32 * 1024;
const daemon_name = L("slimed.exe");

const MsgType = enum(u8) {
    hello = 1,
    list = 2,
    new = 3,
    attach = 4,
    detach = 5,
    input = 6,
    resize = 7,
    kill = 8,
    hello_reply = 65,
    sessions = 66,
    attached = 67,
    snapshot = 68,
    output = 69,
    detached = 70,
    exit = 71,
    @"error" = 72,
    _,
};

alloc: Allocator,
pipe: Pipe,
/// The daemon's id for the session.
id: u32,
/// Frames are written from the UI thread (keys, resizes) and the reader
/// thread (query replies); each goes out whole.
write_lock: win32.SRWLOCK = .{},

/// A grid size and its cell size in pixels.
pub const Size = struct {
    cols: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
};

/// The session to attach to.
pub const Target = union(enum) {
    /// A new one running a command line (CreateProcessW syntax), in
    /// `cwd` if set.
    new: struct { command: []const u16, cwd: ?[]const u8 = null },
    /// A detached one, by the daemon's id.
    attach: u32,
};

/// The session's terminal as the daemon has it.
pub const Attachment = struct {
    /// Owned, in the connection's allocator.
    snapshot: []u8,
    /// win32-input-mode, which a snapshot doesn't carry.
    win32_input: bool,
};

/// Connect and attach, starting the daemon for a new session if it isn't
/// running. Blocks until the snapshot is in: the daemon is local and the
/// snapshot a few megabytes at most. UI thread.
pub fn open(alloc: Allocator, target: Target, size: Size) !struct { *Slimed, Attachment } {
    var pipe: Pipe = try .open(target == .new);
    errdefer pipe.close();
    const buf = try alloc.alloc(u8, max_frame);
    defer alloc.free(buf);
    try handshake(&pipe, buf);

    const self = try alloc.create(Slimed);
    errdefer alloc.destroy(self);
    self.* = .{ .alloc = alloc, .pipe = pipe, .id = 0 };

    var p: Payload = .{};
    defer p.deinit(alloc);
    try p.putU32(alloc, 1); // tag
    switch (target) {
        .new => |new| {
            const cmd = std.unicode.utf16LeToUtf8Alloc(alloc, new.command) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.BadCommand,
            };
            defer alloc.free(cmd);
            try p.putStr(alloc, cmd);
            try p.putStr(alloc, new.cwd orelse "");
            try p.putSize(alloc, size);
            try self.send(.new, 0, p.bytes());
        },
        .attach => |id| {
            try p.putSize(alloc, size);
            try self.send(.attach, id, p.bytes());
        },
    }

    // Attached, then the snapshot's chunks.
    var snapshot: std.ArrayList(u8) = .empty;
    errdefer snapshot.deinit(alloc);
    var want: ?usize = null;
    var win32_input = false;
    while (want == null or snapshot.items.len < want.?) {
        const f = try self.pipe.readFrame(buf);
        var r: Reader = .{ .buf = f.payload };
        switch (f.type) {
            .attached => {
                _ = try r.readU32(); // tag
                const len = try r.readU32();
                const modes = try r.readU32();
                for (0..modes) |_| {
                    const mode = try r.readU16();
                    const ansi = try r.readU8() != 0;
                    const enabled = try r.readU8() != 0;
                    if (mode == 9001 and !ansi) win32_input = enabled;
                }
                self.id = f.id;
                want = len;
                try snapshot.ensureTotalCapacityPrecise(alloc, len);
            },
            .snapshot => {
                if (want == null or snapshot.items.len + f.payload.len > want.?) return error.BadSnapshot;
                snapshot.appendSliceAssumeCapacity(f.payload);
            },
            .@"error" => {
                _ = try r.readU32(); // tag
                log.err("slimed refused: {s}", .{try r.readStr()});
                return error.Refused;
            },
            else => log.warn("unexpected message {d} while attaching", .{@intFromEnum(f.type)}),
        }
    }
    log.info("attached to session {d} ({d} byte snapshot)", .{ self.id, snapshot.items.len });
    return .{ self, .{ .snapshot = try snapshot.toOwnedSlice(alloc), .win32_input = win32_input } };
}

/// Free the connection, which detaches from the session; the daemon keeps
/// it running. `cancel` first if a reader is blocked on it.
pub fn deinit(self: *Slimed) void {
    self.pipe.close();
    self.alloc.destroy(self);
}

/// Wake a reader blocked in `next`, which then returns an error.
pub fn cancel(self: *Slimed) void {
    _ = win32.CancelIoEx(self.pipe.h, null);
}

/// What the reader gets from the session.
pub const Event = union(enum) {
    /// The child's output, in the buffer given to `next`.
    output: []const u8,
    /// The child exited with this status.
    exit: u32,
    /// The daemon took the session from us (another client attached, or
    /// we fell too far behind).
    detached: []const u8,
};

/// The next event. Blocks; errors once the daemon or `cancel` ends the
/// connection. Reader thread.
pub fn next(self: *Slimed, buf: []u8) !Event {
    while (true) {
        const f = try self.pipe.readFrame(buf);
        if (f.id != self.id) continue;
        var r: Reader = .{ .buf = f.payload };
        switch (f.type) {
            .output => return .{ .output = f.payload },
            .exit => return .{ .exit = try r.readU32() },
            .detached => return .{ .detached = try r.readStr() },
            .@"error" => {
                _ = try r.readU32(); // tag
                log.warn("slimed: {s}", .{try r.readStr()});
            },
            else => {},
        }
    }
}

/// Send input to the child. Called from both the UI thread and the
/// reader thread (query replies), like `Pty.write`.
pub fn write(self: *Slimed, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        const n = @min(rest.len, Payload.input_chunk);
        self.send(.input, self.id, rest[0..n]) catch return;
        rest = rest[n..];
    }
}

pub fn resize(self: *Slimed, size: Size) void {
    var b: [12]u8 = undefined;
    writeSize(&b, size);
    self.send(.resize, self.id, &b) catch {};
}

/// End the session, not just our attachment to it.
pub fn kill(self: *Slimed) void {
    self.send(.kill, self.id, &.{}) catch {};
}

fn send(self: *Slimed, msg: MsgType, id: u32, payload: []const u8) !void {
    win32.AcquireSRWLockExclusive(&self.write_lock);
    defer win32.ReleaseSRWLockExclusive(&self.write_lock);
    try self.pipe.send(msg, id, payload);
}

/// A detached session, as `list` reports it.
pub const Detached = struct {
    id: u32,
    /// Owned, in the list's allocator.
    command: []const u16,
};

/// The daemon's detached sessions, oldest first: none if it isn't
/// running. Free with `freeList`.
pub fn list(alloc: Allocator) ![]Detached {
    var pipe = Pipe.open(false) catch |err| switch (err) {
        error.NotRunning => return &.{},
        else => return err,
    };
    defer pipe.close();
    const buf = try alloc.alloc(u8, max_frame);
    defer alloc.free(buf);
    try handshake(&pipe, buf);
    try pipe.send(.list, 0, &.{});
    const f = while (true) {
        const f = try pipe.readFrame(buf);
        if (f.type == .sessions) break f;
    };

    var out: std.ArrayList(Detached) = .empty;
    errdefer freeList(alloc, out.items);
    defer out.deinit(alloc);
    var r: Reader = .{ .buf = f.payload };
    const n = try r.readU32();
    for (0..n) |_| {
        const id = try r.readU32();
        const command = try r.readStr();
        _ = try r.readStr(); // title
        _ = try r.readStr(); // pwd
        _ = try r.readU16(); // cols
        _ = try r.readU16(); // rows
        const attached = try r.readU8() != 0;
        _ = try r.take(8 + 4); // created, pid
        if (attached) continue;
        const cmd = std.unicode.utf8ToUtf16LeAlloc(alloc, command) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => try alloc.dupe(u16, L("?")),
        };
        out.append(alloc, .{ .id = id, .command = cmd }) catch |err| {
            alloc.free(cmd);
            return err;
        };
    }
    return out.toOwnedSlice(alloc);
}

pub fn freeList(alloc: Allocator, sessions: []const Detached) void {
    for (sessions) |s| alloc.free(s.command);
    alloc.free(sessions);
}

/// Say hello, and check the daemon writes snapshots we can read.
fn handshake(pipe: *Pipe, buf: []u8) !void {
    var hello: [4]u8 = undefined;
    std.mem.writeInt(u32, &hello, protocol_version, .little);
    try pipe.send(.hello, 0, &hello);
    const f = try pipe.readFrame(buf);
    if (f.type != .hello_reply) return error.BadReply;
    var r: Reader = .{ .buf = f.payload };
    const version = try r.readU32();
    const snapshot_version = try r.readU16();
    if (version != protocol_version) {
        log.err("slimed speaks protocol {d}, we speak {d}", .{ version, protocol_version });
        return error.VersionMismatch;
    }
    if (snapshot_version != ghostty_vt.snapshot.envelope.version) {
        log.err("slimed writes snapshot format {d}, we read {d}", .{ snapshot_version, ghostty_vt.snapshot.envelope.version });
        return error.VersionMismatch;
    }
}

/// Open the daemon's pipe, first starting the daemon if `start` and none
/// is running.
fn connect(start: bool) !win32.HANDLE {
    var name_buf: [128]u16 = undefined;
    const name = try pipeName(&name_buf);
    var started = false;
    const deadline = win32.GetTickCount64() + 5000;
    while (true) {
        // SECURITY_IDENTIFICATION: the daemon may learn who we are but
        // not act as us.
        const h = win32.CreateFileW(
            name,
            win32.GENERIC_READ | win32.GENERIC_WRITE,
            0,
            null,
            win32.OPEN_EXISTING,
            win32.FILE_FLAG_OVERLAPPED | win32.SECURITY_SQOS_PRESENT | win32.SECURITY_IDENTIFICATION,
            null,
        );
        if (h != win32.INVALID_HANDLE_VALUE) {
            checkServer(h) catch |err| {
                _ = win32.CloseHandle(h);
                return err;
            };
            return h;
        }
        switch (win32.GetLastError()) {
            win32.ERROR_PIPE_BUSY => _ = win32.WaitNamedPipeW(name, 1000),
            win32.ERROR_FILE_NOT_FOUND => {
                if (!start) return error.NotRunning;
                if (!started) {
                    try startDaemon();
                    started = true;
                }
                if (win32.GetTickCount64() > deadline) return error.DaemonDidntStart;
                win32.Sleep(20);
            },
            else => return win32.lastError("CreateFileW"),
        }
        if (win32.GetTickCount64() > deadline) return error.DaemonDidntStart;
    }
}

/// `\\.\pipe\slimed-<user SID>`, NUL-terminated: one daemon per user.
fn pipeName(buf: []u16) ![:0]const u16 {
    var token_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    const sid = try currentUser(&token_buf);
    var str: ?win32.LPWSTR = null;
    if (win32.ConvertSidToStringSidW(sid, &str) == 0) return win32.lastError("ConvertSidToStringSidW");
    defer _ = win32.LocalFree(str);
    const sid_str = std.mem.span(str.?);
    const prefix = L("\\\\.\\pipe\\slimed-");
    if (prefix.len + sid_str.len + 1 > buf.len) return error.NameTooLong;
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..sid_str.len], sid_str);
    buf[prefix.len + sid_str.len] = 0;
    return buf[0 .. prefix.len + sid_str.len :0];
}

fn currentUser(buf: *align(@alignOf(win32.TOKEN_USER)) [256]u8) !*win32.SID {
    return tokenUser(win32.GetCurrentProcess(), buf);
}

/// The user a process runs as, in `buf`.
fn tokenUser(process: win32.HANDLE, buf: *align(@alignOf(win32.TOKEN_USER)) [256]u8) !*win32.SID {
    var token: win32.HANDLE = undefined;
    if (win32.OpenProcessToken(process, win32.TOKEN_QUERY, &token) == 0) return win32.lastError("OpenProcessToken");
    defer _ = win32.CloseHandle(token);
    var len: u32 = 0;
    if (win32.GetTokenInformation(token, win32.TokenUser, buf, buf.len, &len) == 0) return win32.lastError("GetTokenInformation");
    const user: *const win32.TOKEN_USER = @ptrCast(buf);
    return user.User.Sid;
}

/// Refuse a pipe served by anyone but us: another user could have
/// created the name before our daemon did.
fn checkServer(pipe: win32.HANDLE) !void {
    var pid: u32 = 0;
    if (win32.GetNamedPipeServerProcessId(pipe, &pid) == 0) return win32.lastError("GetNamedPipeServerProcessId");
    const process = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, win32.FALSE, pid) orelse
        return win32.lastError("OpenProcess");
    defer _ = win32.CloseHandle(process);
    var theirs_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    var ours_buf: [256]u8 align(@alignOf(win32.TOKEN_USER)) = undefined;
    if (win32.EqualSid(try tokenUser(process, &theirs_buf), try currentUser(&ours_buf)) == 0) {
        log.err("slimed's pipe is served by another user's process (pid {d})", .{pid});
        return error.ForeignServer;
    }
}

/// Run slimed so it outlives us: detached, and out of any job we're in.
///
/// It runs from a copy in %LOCALAPPDATA%\slime\bin, named for the size
/// and time of the slimed.exe next to us: a running exe can't be
/// replaced, and the daemon runs as long as its sessions, so running ours
/// in place would stop the next build from installing over it. It loads
/// the ConPTY next to us (which doesn't change between builds). Its log
/// goes to %LOCALAPPDATA%\slime\slimed.log.
fn startDaemon() !void {
    var dir_buf: [max_path]u16 = undefined;
    const dir = try exeDir(&dir_buf);
    var src: WideBuf = .{};
    try src.put(dir);
    try src.put(L("\\"));
    try src.put(daemon_name);

    var exe: WideBuf = .{};
    var log_path: WideBuf = .{};
    copy: {
        var appdata: [260]u16 = undefined;
        const len = win32.GetEnvironmentVariableW(L("LOCALAPPDATA"), &appdata, appdata.len);
        if (len == 0 or len >= appdata.len) break :copy;
        var attrs: win32.WIN32_FILE_ATTRIBUTE_DATA = undefined;
        if (win32.GetFileAttributesExW(try src.z(), win32.GetFileExInfoStandard, &attrs) == 0)
            return win32.lastError("GetFileAttributesExW(slimed.exe)");

        var base: WideBuf = .{};
        try base.put(appdata[0..len]);
        try base.put(L("\\slime"));
        try makeDir(&base);
        try log_path.put(base.slice());
        try log_path.put(L("\\slimed.log"));
        try base.put(L("\\bin"));
        try makeDir(&base);

        var name_buf: [64]u8 = undefined;
        const size = @as(u64, attrs.nFileSizeHigh) << 32 | attrs.nFileSizeLow;
        const name = std.fmt.bufPrint(&name_buf, "\\slimed-{x}-{x}.exe", .{ size, attrs.ftLastWriteTime }) catch unreachable;
        try exe.put(base.slice());
        try exe.putAscii(name);
        if (win32.CopyFileW(try src.z(), try exe.z(), win32.TRUE) == 0 and win32.GetLastError() != win32.ERROR_FILE_EXISTS)
            return win32.lastError("CopyFileW(slimed.exe)");
    }
    if (exe.len == 0) try exe.put(src.slice());

    // No trailing backslash before a closing quote, which would escape
    // it.
    var cmd: WideBuf = .{};
    try cmd.put(L("\""));
    try cmd.put(exe.slice());
    try cmd.put(L("\" serve --conpty \""));
    try cmd.put(dir);
    try cmd.put(L("\""));
    if (log_path.len > 0) {
        try cmd.put(L(" --log \""));
        try cmd.put(log_path.slice());
        try cmd.put(L("\""));
    }
    const cmd_z = try cmd.z();

    const flags = win32.DETACHED_PROCESS | win32.CREATE_NEW_PROCESS_GROUP | win32.CREATE_UNICODE_ENVIRONMENT;
    // Breaking away fails when our job doesn't allow it; then the daemon
    // dies with the job, but at least it runs.
    for ([_]u32{ win32.CREATE_BREAKAWAY_FROM_JOB, 0 }) |extra| {
        var si: win32.STARTUPINFOEXW = .{ .StartupInfo = .{ .cb = @sizeOf(win32.STARTUPINFOW) } };
        var pi: win32.PROCESS_INFORMATION = undefined;
        if (win32.CreateProcessW(null, @constCast(cmd_z.ptr), null, null, win32.FALSE, flags | extra, null, null, &si, &pi) != 0) {
            _ = win32.CloseHandle(pi.hThread);
            _ = win32.CloseHandle(pi.hProcess);
            log.info("started slimed (pid {d}){s}", .{ pi.dwProcessId, if (extra == 0) " inside our job" else "" });
            return;
        }
    }
    return win32.lastError("CreateProcessW(slimed.exe)");
}

fn makeDir(path: *WideBuf) !void {
    if (win32.CreateDirectoryW(try path.z(), null) == 0 and win32.GetLastError() != win32.ERROR_ALREADY_EXISTS)
        return win32.lastError("CreateDirectoryW");
}

/// Our executable's directory, without a trailing backslash.
fn exeDir(buf: *[max_path]u16) ![]const u16 {
    const n = win32.GetModuleFileNameW(null, buf, buf.len);
    if (n == 0 or n >= buf.len) return win32.lastError("GetModuleFileNameW");
    return buf[0 .. std.mem.lastIndexOfScalar(u16, buf[0..n], '\\') orelse return error.Win32];
}

/// A path or command line being built, kept NUL-terminable. Several live
/// on the UI thread's stack at once, so they're shorter than the longest
/// path Windows allows.
const WideBuf = struct {
    buf: [4096]u16 = undefined,
    len: usize = 0,

    fn put(self: *WideBuf, s: []const u16) !void {
        if (self.len + s.len >= self.buf.len) return error.NameTooLong;
        @memcpy(self.buf[self.len..][0..s.len], s);
        self.len += s.len;
    }

    fn putAscii(self: *WideBuf, s: []const u8) !void {
        if (self.len + s.len >= self.buf.len) return error.NameTooLong;
        for (s, self.buf[self.len..][0..s.len]) |c, *d| d.* = c;
        self.len += s.len;
    }

    fn slice(self: *const WideBuf) []const u16 {
        return self.buf[0..self.len];
    }

    fn z(self: *WideBuf) ![:0]const u16 {
        self.buf[self.len] = 0;
        return self.buf[0..self.len :0];
    }
};

/// The daemon's pipe, opened for overlapped I/O. Windows serializes
/// synchronous I/O on a handle, so a blocking read, which the reader
/// thread is in most of the time, would hold up every write behind it.
/// Reads and writes each wait on their own event instead. Reads are the
/// reader's (or `open`'s, before the reader starts); writes take the
/// connection's write lock.
const Pipe = struct {
    h: win32.HANDLE,
    read_event: win32.HANDLE,
    write_event: win32.HANDLE,

    fn open(start: bool) !Pipe {
        const h = try connect(start);
        errdefer _ = win32.CloseHandle(h);
        const read_event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return win32.lastError("CreateEventW");
        errdefer _ = win32.CloseHandle(read_event);
        const write_event = win32.CreateEventW(null, win32.TRUE, win32.FALSE, null) orelse return win32.lastError("CreateEventW");
        return .{ .h = h, .read_event = read_event, .write_event = write_event };
    }

    fn close(self: *Pipe) void {
        _ = win32.CloseHandle(self.h);
        _ = win32.CloseHandle(self.read_event);
        _ = win32.CloseHandle(self.write_event);
    }

    fn send(self: *Pipe, msg: MsgType, id: u32, payload: []const u8) !void {
        var header: [9]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(5 + payload.len), .little);
        header[4] = @intFromEnum(msg);
        std.mem.writeInt(u32, header[5..9], id, .little);
        // One write for small frames, so a pipe trace shows whole frames.
        if (payload.len <= Payload.input_chunk) {
            var buf: [9 + Payload.input_chunk]u8 = undefined;
            @memcpy(buf[0..9], &header);
            @memcpy(buf[9..][0..payload.len], payload);
            return self.writeAll(buf[0 .. 9 + payload.len]);
        }
        try self.writeAll(&header);
        try self.writeAll(payload);
    }

    /// Failing is expected once the daemon has gone, so it isn't logged.
    fn writeAll(self: *Pipe, data: []const u8) !void {
        var rest = data;
        while (rest.len > 0) {
            var ov: win32.OVERLAPPED = .{ .hEvent = self.write_event };
            const len: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
            if (win32.WriteFile(self.h, rest.ptr, len, null, &ov) == 0 and win32.GetLastError() != win32.ERROR_IO_PENDING)
                return error.BrokenPipe;
            var n: u32 = 0;
            if (win32.GetOverlappedResult(self.h, &ov, &n, win32.TRUE) == 0) return error.BrokenPipe;
            rest = rest[n..];
        }
    }

    fn readFrame(self: *Pipe, buf: []u8) !Frame {
        var len_buf: [4]u8 = undefined;
        try self.readExact(&len_buf);
        const len = std.mem.readInt(u32, &len_buf, .little);
        if (len < 5 or len > buf.len) return error.BadFrame;
        try self.readExact(buf[0..len]);
        return .{
            .type = @enumFromInt(buf[0]),
            .id = std.mem.readInt(u32, buf[1..5], .little),
            .payload = buf[5..len],
        };
    }

    /// Fails at EOF, and when `cancel` aborts the read.
    fn readExact(self: *Pipe, buf: []u8) !void {
        var got: usize = 0;
        while (got < buf.len) {
            var ov: win32.OVERLAPPED = .{ .hEvent = self.read_event };
            if (win32.ReadFile(self.h, buf[got..].ptr, @intCast(buf.len - got), null, &ov) == 0 and win32.GetLastError() != win32.ERROR_IO_PENDING)
                return error.EndOfStream;
            var n: u32 = 0;
            if (win32.GetOverlappedResult(self.h, &ov, &n, win32.TRUE) == 0 or n == 0) return error.EndOfStream;
            got += n;
        }
    }
};

const Frame = struct {
    type: MsgType,
    id: u32,
    payload: []const u8,
};

fn writeSize(b: *[12]u8, size: Size) void {
    std.mem.writeInt(u16, b[0..2], size.cols, .little);
    std.mem.writeInt(u16, b[2..4], size.rows, .little);
    std.mem.writeInt(u32, b[4..8], size.cell_width, .little);
    std.mem.writeInt(u32, b[8..12], size.cell_height, .little);
}

/// A request's payload. Input goes in chunks of `input_chunk` bytes, so
/// the frames for keys and pastes build on the stack.
const Payload = struct {
    const input_chunk = 16 * 1024;

    list: std.ArrayList(u8) = .empty,

    fn deinit(self: *Payload, alloc: Allocator) void {
        self.list.deinit(alloc);
    }

    fn bytes(self: *const Payload) []const u8 {
        return self.list.items;
    }

    fn putU32(self: *Payload, alloc: Allocator, v: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try self.list.appendSlice(alloc, &b);
    }

    fn putStr(self: *Payload, alloc: Allocator, s: []const u8) !void {
        try self.putU32(alloc, @intCast(s.len));
        try self.list.appendSlice(alloc, s);
    }

    fn putSize(self: *Payload, alloc: Allocator, size: Size) !void {
        var b: [12]u8 = undefined;
        writeSize(&b, size);
        try self.list.appendSlice(alloc, &b);
    }
};

/// Reads payload fields. Bytes past the known fields are ignored, so the
/// daemon can add fields to a message.
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

    fn readU16(self: *Reader) !u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    fn readU32(self: *Reader) !u32 {
        return std.mem.readInt(u32, (try self.take(4))[0..4], .little);
    }

    fn readStr(self: *Reader) ![]const u8 {
        return self.take(try self.readU32());
    }
};

test "frames match the Go side's wire format" {
    // ssh/internal/persist: Resize{Size{0x0102, 0x0304, 0x05060708,
    // 0x090a0b0c}} on 2.
    var b: [12]u8 = undefined;
    writeSize(&b, .{ .cols = 0x0102, .rows = 0x0304, .cell_width = 0x05060708, .cell_height = 0x090a0b0c });
    try std.testing.expectEqualSlices(u8, &.{
        0x02, 0x01, 0x04, 0x03,
        0x08, 0x07, 0x06, 0x05,
        0x0c, 0x0b, 0x0a, 0x09,
    }, &b);
}
