//! The chrome's colors, derived from the terminal's default background
//! and foreground, so the chrome matches whatever theme is configured,
//! light or dark. Everything is a mix of the two, except the accent (slime
//! blue, from the app icon) and the close button's red, which is Windows'.

const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Painter = @import("../renderer/Painter.zig");

const RGB = ghostty_vt.color.RGB;
const Color = Painter.Color;

pub const Theme = struct {
    /// The background is light: dark text, dark window frame off.
    light: bool,

    /// Behind everything that isn't the terminal.
    ground: Color,
    /// A button at rest, e.g. "New session".
    surface: Color,
    surface_hover: Color,
    /// A list row under the mouse.
    row_hover: Color,
    /// The active session's row.
    row_selected: Color,
    /// Icon buttons under the mouse, and while pressed.
    button_hover: Color,
    button_pressed: Color,
    /// The close caption button under the mouse, as Windows draws it,
    /// and its glyph then.
    close_hover: Color,
    close_pressed: Color,
    close_glyph: Color,
    outline: Color,

    text: Color,
    text_strong: Color,
    text_muted: Color,
    text_inactive: Color,

    accent: Color,
    /// Selected text in a field.
    selection: Color,

    pub fn init(bg: RGB, fg: RGB) Theme {
        const b = toColor(bg);
        const f = toColor(fg);
        const light = luminance(b) > 0.5;
        // Set off from the terminal: darker in both modes, as editors'
        // side bars are, but less so on light backgrounds.
        const ground = mix(b, .{ 0, 0, 0, 1 }, if (light) 0.06 else 0.25);
        const extreme: Color = if (light) .{ 0, 0, 0, 1 } else .{ 1, 1, 1, 1 };
        // The icon's mid blue, or its deep blue on light backgrounds.
        const accent = Painter.rgb(if (light) 0x1f6fd1 else 0x3fa2f2);
        return .{
            .light = light,
            .ground = ground,
            .surface = mix(ground, f, 0.07),
            .surface_hover = mix(ground, f, 0.11),
            .row_hover = mix(ground, f, 0.05),
            .row_selected = mix(ground, f, 0.10),
            .button_hover = withAlpha(f, 0.08),
            .button_pressed = withAlpha(f, 0.05),
            .close_hover = Painter.rgb(0xc42b1c),
            .close_pressed = Painter.rgb(0xb0271a),
            .close_glyph = .{ 1, 1, 1, 1 },
            .outline = mix(ground, f, 0.18),
            .text = mix(ground, f, 0.88),
            .text_strong = mix(f, extreme, 0.3),
            .text_muted = mix(ground, f, 0.58),
            .text_inactive = mix(ground, f, 0.42),
            .accent = accent,
            .selection = withAlpha(accent, 0.35),
        };
    }
};

fn toColor(c: RGB) Color {
    return .{
        @as(f32, @floatFromInt(c.r)) / 255.0,
        @as(f32, @floatFromInt(c.g)) / 255.0,
        @as(f32, @floatFromInt(c.b)) / 255.0,
        1,
    };
}

/// `t` of the way from `a` to `b`.
fn mix(a: Color, b: Color, t: f32) Color {
    var out: Color = undefined;
    for (&out, a, b) |*o, x, y| o.* = x + (y - x) * t;
    return out;
}

fn withAlpha(c: Color, a: f32) Color {
    return .{ c[0], c[1], c[2], a };
}

/// Relative luminance (WCAG), 0 for black to 1 for white.
fn luminance(c: Color) f32 {
    var lin: [3]f32 = undefined;
    for (&lin, c[0..3]) |*l, v| {
        l.* = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    }
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2];
}

test "dark and light themes" {
    const dark: Theme = .init(.{ .r = 0x1e, .g = 0x1e, .b = 0x2e }, .{ .r = 0xcd, .g = 0xd6, .b = 0xf4 });
    try std.testing.expect(!dark.light);
    // Darker than the terminal, and text lighter than the ground.
    try std.testing.expect(dark.ground[0] < @as(f32, 0x1e) / 255.0);
    try std.testing.expect(luminance(dark.text) > luminance(dark.ground));

    const light: Theme = .init(.{ .r = 0xef, .g = 0xf1, .b = 0xf5 }, .{ .r = 0x4c, .g = 0x4f, .b = 0x69 });
    try std.testing.expect(light.light);
    try std.testing.expect(luminance(light.text) < luminance(light.ground));
    try std.testing.expect(luminance(light.text_strong) < luminance(light.text));
}
