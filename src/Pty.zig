//! A child process attached to a pseudoconsole. We write input (VT
//! encoded keys, query replies) to one pipe and read the VT output that
//! ConPTY renders the console buffer as from another.
//!
//! The child runs in a job object that kills it, and everything it
//! spawns, when we close the job handle.
const Pty = @This();

const std = @import("std");
const win32 = @import("win32/win32.zig");
const conpty = win32.conpty;

const log = std.log.scoped(.pty);

api: conpty.Api,
hpc: conpty.HPCON,

/// Our ends of the pipes. ConPTY holds the other ends.
input: win32.HANDLE,
output: win32.HANDLE,

process: win32.HANDLE,
job: win32.HANDLE,

/// Start `command_line` (CreateProcessW syntax; modified in place by
/// CreateProcessW) in a new pseudoconsole of the given size.
pub fn spawn(command_line: win32.LPWSTR, cols: u16, rows: u16) !Pty {
    const api: conpty.Api = try .load();

    var input_read: win32.HANDLE = undefined;
    var input_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&input_read, &input_write, null, 0) == 0) return win32.lastError("CreatePipe");
    defer _ = win32.CloseHandle(input_read);
    errdefer _ = win32.CloseHandle(input_write);

    var output_read: win32.HANDLE = undefined;
    var output_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&output_read, &output_write, null, 0) == 0) return win32.lastError("CreatePipe");
    defer _ = win32.CloseHandle(output_write);
    errdefer _ = win32.CloseHandle(output_read);

    // GLYPH_WIDTH_GRAPHEMES makes ConPTY's buffer measure text the way
    // libghostty-vt does with mode 2027, so the two grids agree on where
    // the cursor is after emoji sequences.
    var hpc: conpty.HPCON = undefined;
    const hr = api.create(
        coord(cols, rows),
        input_read,
        output_write,
        conpty.PSEUDOCONSOLE_GLYPH_WIDTH_GRAPHEMES,
        &hpc,
    );
    if (hr < 0) {
        log.err("CreatePseudoConsole failed: 0x{x}", .{@as(u32, @bitCast(hr))});
        return error.Win32;
    }
    // ConPTY duplicated its pipe ends; the deferred closes of ours above
    // mean output_read sees EOF once the pseudoconsole is closed.
    errdefer api.close(hpc);

    const job = win32.CreateJobObjectW(null, null) orelse return win32.lastError("CreateJobObjectW");
    errdefer _ = win32.CloseHandle(job);
    const limits: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{
        .BasicLimitInformation = .{ .LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE },
    };
    if (win32.SetInformationJobObject(job, win32.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits))) == 0)
        return win32.lastError("SetInformationJobObject");

    const process = try createProcess(command_line, hpc);
    errdefer _ = win32.CloseHandle(process.hProcess);
    defer _ = win32.CloseHandle(process.hThread);

    // Assign before the child runs so anything it spawns lands in the
    // job too.
    if (win32.AssignProcessToJobObject(job, process.hProcess) == 0)
        return win32.lastError("AssignProcessToJobObject");
    _ = win32.ResumeThread(process.hThread);

    return .{
        .api = api,
        .hpc = hpc,
        .input = input_write,
        .output = output_read,
        .process = process.hProcess,
        .job = job,
    };
}

fn createProcess(command_line: win32.LPWSTR, hpc: conpty.HPCON) !win32.PROCESS_INFORMATION {
    // One attribute: the pseudoconsole.
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
        win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        hpc,
        @sizeOf(conpty.HPCON),
        null,
        null,
    ) == 0) return win32.lastError("UpdateProcThreadAttribute");

    // STARTF_USESTDHANDLES with null handles: otherwise a child of a
    // process with redirected stdio (e.g. our console build under the
    // smoke test) inherits those handles instead of the pseudoconsole's.
    var si: win32.STARTUPINFOEXW = .{ .lpAttributeList = attrs };
    si.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;

    var pi: win32.PROCESS_INFORMATION = undefined;
    if (win32.CreateProcessW(
        null,
        command_line,
        null,
        null,
        win32.FALSE,
        win32.EXTENDED_STARTUPINFO_PRESENT | win32.CREATE_UNICODE_ENVIRONMENT | win32.CREATE_SUSPENDED,
        null,
        null,
        &si,
        &pi,
    ) == 0) return win32.lastError("CreateProcessW");
    return pi;
}

/// Close the pseudoconsole. The child is sent CTRL_CLOSE_EVENT and
/// `read` returns 0 once ConPTY has flushed its remaining output, so a
/// reader thread must keep draining while this runs.
pub fn close(self: *Pty) void {
    self.api.close(self.hpc);
}

/// Free everything after `close` and once nothing reads or writes
/// anymore. Kills the child (and its children) if still running.
pub fn deinit(self: *Pty) void {
    _ = win32.CloseHandle(self.input);
    _ = win32.CloseHandle(self.output);
    _ = win32.CloseHandle(self.process);
    _ = win32.CloseHandle(self.job);
}

/// Read output. Blocks until some is available; returns 0 at EOF.
pub fn read(self: *Pty, buf: []u8) !usize {
    var n: u32 = 0;
    const len: u32 = @intCast(@min(buf.len, std.math.maxInt(u32)));
    if (win32.ReadFile(self.output, buf.ptr, len, &n, null) == 0) {
        if (win32.GetLastError() == win32.ERROR_BROKEN_PIPE) return 0;
        return win32.lastError("ReadFile");
    }
    return n;
}

/// Write input. Blocks if the pipe is full (the child isn't reading).
/// Called from both the UI thread (keys) and the reader thread (query
/// replies); a large write from one may interleave with the other.
pub fn write(self: *Pty, data: []const u8) void {
    var rest = data;
    while (rest.len > 0) {
        var n: u32 = 0;
        const len: u32 = @intCast(@min(rest.len, std.math.maxInt(u32)));
        if (win32.WriteFile(self.input, rest.ptr, len, &n, null) == 0) {
            win32.lastError("WriteFile") catch {};
            return;
        }
        rest = rest[n..];
    }
}

pub fn resize(self: *Pty, cols: u16, rows: u16) void {
    const hr = self.api.resize(self.hpc, coord(cols, rows));
    if (hr < 0) log.err("ResizePseudoConsole failed: 0x{x}", .{@as(u32, @bitCast(hr))});
}

fn coord(cols: u16, rows: u16) conpty.COORD {
    return .{
        .X = @intCast(@min(cols, std.math.maxInt(i16))),
        .Y = @intCast(@min(rows, std.math.maxInt(i16))),
    };
}
