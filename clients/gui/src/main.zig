const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const wuffs = @import("wuffs");
const win32 = @import("win32/win32.zig");
const Window = @import("Window.zig");
const Config = @import("Config.zig");
const Daemon = @import("Daemon.zig");
const Hosts = @import("Hosts.zig");
const Shown = @import("Shown.zig");
const binding = @import("binding.zig");

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
    ghostty_vt.sys.decode_png = &decodePng;
    // A single-threaded apartment, which WebView2 (browser panes) needs
    // on the thread it calls back on, this one.
    const com_ok = win32.CoInitializeEx(null, win32.COINIT_APARTMENTTHREADED) >= 0;
    if (!com_ok) std.log.err("CoInitializeEx failed: browser panes won't work", .{});
    defer if (com_ok) win32.CoUninitialize();

    const config_dir = try Config.defaultDir(init.gpa, init.environ_map);
    defer if (config_dir) |d| init.gpa.free(d);
    var hosts: Hosts = try .load(init.gpa, init.io, config_dir);
    defer hosts.deinit();
    var shown: Shown = try .load(init.gpa, init.io, config_dir);
    defer shown.deinit();

    // The settings and key bindings are the daemon's (init.lua), so it
    // comes before the window; one that can't be reached leaves the
    // defaults, and the window's tab says why.
    const daemon = Daemon.open(init.gpa) catch |err| blk: {
        std.log.err("connecting to slime failed: {}", .{err});
        break :blk null;
    };
    var config: Config = undefined;
    var keymap: []binding.Entry = &.{};
    defer Daemon.freeKeymap(init.gpa, keymap);
    var actions: []Daemon.ConfigAction = &.{};
    defer Daemon.freeActions(init.gpa, actions);
    var source: Config.Source = .{ .dir = config_dir };
    defer init.gpa.free(source.path);
    // Why init.lua didn't load, for the window to show once it's up.
    var daemon_errors: std.ArrayList([]const u8) = .empty;
    defer {
        for (daemon_errors.items) |e| init.gpa.free(e);
        daemon_errors.deinit(init.gpa);
    }
    if (daemon) |conn| {
        var result = conn.config() catch |err| blk: {
            std.log.err("asking slime for its config failed: {}", .{err});
            break :blk null;
        };
        defer if (result) |*r| r.deinit();
        const desc: Daemon.Json.Config = if (result) |r| r.value else .{};
        for (desc.errors) |e| {
            std.log.err("init.lua: {s}", .{e});
            try daemon_errors.append(init.gpa, try init.gpa.dupe(u8, e));
        }
        source.path = try init.gpa.dupe(u8, desc.path);
        config = try Config.loadFrom(init.gpa, init.io, desc.settings, source);
        keymap = try Daemon.keymapFromJson(init.gpa, desc.keymap);
        actions = try Daemon.actionsFromJson(init.gpa, desc.actions);
    } else {
        config = .init(init.gpa);
    }
    defer config.deinit();

    const command_line = try shellCommand(init.gpa);
    defer init.gpa.free(command_line);
    // What the sidebar's "Local" runs when the command is an ssh:// URL:
    // slime's shell.
    const local_command = if (isSshUrl(command_line)) try init.gpa.dupeZ(u16, &.{}) else try init.gpa.dupeZ(u16, command_line);
    defer init.gpa.free(local_command);

    // The window owns the connection from here, failing or not.
    const window = try Window.create(init.gpa, init.io, &config, source, keymap, actions, &hosts, &shown, command_line, local_command, daemon);
    defer window.destroy();
    if (daemon_errors.items.len > 0 or config.errors.items.len > 0) try window.app.setNotice(daemon_errors.items);

    // Handle every pending message (input first) before drawing, so a
    // flood of output can't delay keys. The frame gate is only waited on
    // while there's something to draw: waiting on the swap chain's
    // waitable takes a frame.
    var handles: [2]win32.HANDLE = .{ window.output_event, undefined };
    var msg: win32.MSG = undefined;
    while (true) {
        var count: u32 = 1;
        if (window.needsFrame()) {
            handles[1] = window.frameGate();
            count = 2;
        }
        const woke = win32.MsgWaitForMultipleObjectsEx(
            count,
            &handles,
            win32.INFINITE,
            win32.QS_ALLINPUT,
            win32.MWMO_INPUTAVAILABLE,
        );
        while (win32.PeekMessageW(&msg, null, 0, 0, win32.PM_REMOVE) != 0) {
            if (msg.message == win32.WM_QUIT) return;
            _ = win32.TranslateMessage(&msg);
            _ = win32.DispatchMessageW(&msg);
        }
        // woke == count means a message, which was handled above.
        if (woke == win32.WAIT_OBJECT_0) {
            window.outputArrived();
        } else if (count == 2 and woke == win32.WAIT_OBJECT_0 + 1) {
            window.frameGateFired(handles[1]);
        }
    }
}

/// Decode PNGs for kitty graphics.
fn decodePng(alloc: std.mem.Allocator, data: []const u8) ghostty_vt.sys.DecodeError!ghostty_vt.sys.Image {
    const img = wuffs.png.decode(alloc, data) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidData,
    };
    return .{ .width = img.width, .height = img.height, .data = img.data };
}

/// The command to run in the terminal: our own command line after the
/// program name, verbatim (`slime-gui pwsh -NoLogo`), else empty for
/// slime's shell (init.lua's shell.command, else %COMSPEC%).
fn shellCommand(alloc: std.mem.Allocator) ![:0]u16 {
    return alloc.dupeZ(u16, argsAfterProgram(std.mem.span(win32.GetCommandLineW())));
}

fn isSshUrl(command_line: []const u16) bool {
    return std.mem.startsWith(u16, command_line, std.unicode.utf8ToUtf16LeStringLiteral("ssh://"));
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
    _ = @import("App.zig");
    _ = Config;
    _ = @import("Hosts.zig");
    _ = @import("Shown.zig");
    _ = @import("Screen.zig");
    _ = @import("Session.zig");
    _ = @import("Web.zig");
    _ = @import("win32/webview2.zig");
    _ = @import("Daemon.zig");
    _ = @import("Tab.zig");
    _ = @import("Placement.zig");
    _ = @import("messages.zig");
    _ = @import("ProgramStatus.zig");
    _ = @import("Login.zig");
    _ = @import("view.zig");
    _ = @import("ui/Ui.zig");
    _ = @import("ui/TextField.zig");
    _ = @import("ui/Dialog.zig");
    _ = @import("ui/theme.zig");
    _ = @import("ui/Id.zig");
    _ = @import("renderer/Painter.zig");
    _ = @import("renderer/image.zig");
    _ = @import("renderer/D3D11.zig");
    _ = @import("font/font.zig");
    _ = @import("input.zig");
    _ = @import("binding.zig");
}
