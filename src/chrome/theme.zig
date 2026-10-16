//! The chrome's colors. Fixed and dark for now; see deferred.md.

const Painter = @import("../renderer/Painter.zig");
const rgb = Painter.rgb;
const rgba = Painter.rgba;

/// Behind everything that isn't the terminal.
pub const ground = rgb(0x121316);
/// A button at rest, e.g. "New session".
pub const surface = rgb(0x1d1f24);
pub const surface_hover = rgb(0x24272d);
/// A list row under the mouse.
pub const row_hover = rgb(0x1c1e23);
/// The active session's row.
pub const row_selected = rgb(0x262930);
/// Icon buttons under the mouse, and while pressed.
pub const button_hover = rgba(0xffffff, 0.08);
pub const button_pressed = rgba(0xffffff, 0.05);
/// The close caption button under the mouse, as Windows draws it.
pub const close_hover = rgb(0xc42b1c);
pub const close_pressed = rgb(0xb0271a);
pub const outline = rgb(0x33363e);

pub const text = rgb(0xd7dae0);
pub const text_strong = rgb(0xf0f2f5);
pub const text_muted = rgb(0x8a909c);
pub const text_inactive = rgb(0x6f7580);

/// Slime blue, from the app icon.
pub const accent = rgb(0x3fa2f2);
