const std = @import("std");
const win32 = @import("win32/win32.zig");
const Window = @import("Window.zig");

pub fn main(init: std.process.Init) !void {
    // Per-monitor v2 gives us WM_DPICHANGED and unscaled client sizes.
    // This should eventually move to the application manifest.
    _ = win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    const window = try Window.create(
        init.gpa,
        std.unicode.utf8ToUtf16LeStringLiteral("ghostty-win"),
    );
    defer window.destroy();

    var msg: win32.MSG = undefined;
    while (win32.GetMessageW(&msg, null, 0, 0) > 0) {
        _ = win32.TranslateMessage(&msg);
        _ = win32.DispatchMessageW(&msg);
    }
}

test {
    _ = win32;
    _ = Window;
}
