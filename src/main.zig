const std = @import("std");
const win32 = @import("win32/win32.zig");
const Window = @import("Window.zig");

pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        // libghostty-vt logs every grapheme cluster it builds at debug.
        .{ .scope = .terminal, .level = .info },
    },
};

pub fn main(init: std.process.Init) !void {
    // Per-monitor v2 gives us WM_DPICHANGED and unscaled client sizes.
    // This should eventually move to the application manifest.
    _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const command_line = try shellCommand(init.gpa);
    defer init.gpa.free(command_line);

    const window = try Window.create(
        init.gpa,
        init.io,
        std.unicode.utf8ToUtf16LeStringLiteral("ghostty-win"),
        command_line,
    );
    defer window.destroy();

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

/// The command to run in the terminal: our own command line after the
/// program name, verbatim (`ghostty-win pwsh -NoLogo`), or %COMSPEC%.
fn shellCommand(alloc: std.mem.Allocator) ![:0]u16 {
    const args = argsAfterProgram(std.mem.span(win32.GetCommandLineW()));
    if (args.len > 0) return alloc.dupeZ(u16, args);

    var buf: [260]u16 = undefined;
    const n = win32.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("COMSPEC"), &buf, buf.len);
    if (n > 0 and n < buf.len) return alloc.dupeZ(u16, buf[0..n]);
    return alloc.dupeZ(u16, std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe"));
}

/// Skip the program name the way the CRT does: up to the closing quote
/// if it starts with one, else to the first space or tab. No escapes.
fn argsAfterProgram(cmd: []const u16) []const u16 {
    var i: usize = 0;
    if (cmd.len > 0 and cmd[0] == '"') {
        i = 1;
        while (i < cmd.len and cmd[i] != '"') i += 1;
        if (i < cmd.len) i += 1;
    } else {
        while (i < cmd.len and cmd[i] != ' ' and cmd[i] != '\t') i += 1;
    }
    while (i < cmd.len and (cmd[i] == ' ' or cmd[i] == '\t')) i += 1;
    return cmd[i..];
}

test argsAfterProgram {
    const L = std.unicode.utf8ToUtf16LeStringLiteral;
    try std.testing.expectEqualSlices(u16, L("pwsh -NoLogo"), argsAfterProgram(L("\"C:/a b/g.exe\"  pwsh -NoLogo")));
    try std.testing.expectEqualSlices(u16, L("cmd /k"), argsAfterProgram(L("g.exe cmd /k")));
    try std.testing.expectEqualSlices(u16, L(""), argsAfterProgram(L("g.exe")));
}

test {
    _ = win32;
    _ = Window;
    _ = @import("font/font.zig");
    _ = @import("input.zig");
}
