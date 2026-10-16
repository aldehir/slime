//! Sample terminal output exercising the renderer. Temporary: replaced
//! by the PTY once it exists.

const std = @import("std");

pub fn write(stream: anytype) void {
    stream.nextSlice("\x1b[1mghostty-win\x1b[0m  libghostty-vt + DirectWrite + Direct3D 11\r\n\r\n");

    // The 16 base colors as foreground and background.
    for (0..16) |i| {
        var buf: [32]u8 = undefined;
        stream.nextSlice(std.fmt.bufPrint(&buf, "\x1b[38;5;{d}m{d:>3} ", .{ i, i }) catch unreachable);
    }
    stream.nextSlice("\x1b[0m\r\n");
    for (0..16) |i| {
        var buf: [32]u8 = undefined;
        stream.nextSlice(std.fmt.bufPrint(&buf, "\x1b[48;5;{d}m    ", .{i}) catch unreachable);
    }
    stream.nextSlice("\x1b[0m\r\n");

    // A truecolor gradient.
    for (0..64) |i| {
        var buf: [32]u8 = undefined;
        const r: u8 = @intCast(255 - i * 4);
        const g: u8 = @intCast(i * 4);
        stream.nextSlice(std.fmt.bufPrint(&buf, "\x1b[48;2;{d};{d};200m ", .{ r, g }) catch unreachable);
    }
    stream.nextSlice("\x1b[0m\r\n\r\n");

    stream.nextSlice(
        "Regular \x1b[1mBold\x1b[0m \x1b[3mItalic\x1b[0m \x1b[1;3mBold Italic\x1b[0m " ++
            "\x1b[2mFaint\x1b[0m \x1b[4mUnderline\x1b[0m \x1b[9mStrikethrough\x1b[0m \x1b[7mInverse\x1b[0m\r\n",
    );
    stream.nextSlice("The quick brown fox jumps over the lazy dog. 0123456789 {}[]()<>=!~@#$%^&*\r\n");
    stream.nextSlice("Ελληνικά  Кириллица  ±×÷≠≤≥  →⇒↔  ░▒▓█  ┌─┬─┐ │ │ │ └─┴─┘\r\n");
    stream.nextSlice("Wide: 日本語 (needs font fallback)\r\n\r\n");
    stream.nextSlice("\x1b[32m~\x1b[0m $ ");
}
