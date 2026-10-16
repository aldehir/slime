//! The parts of Ghostty's font module that the vendored sprite code
//! (`canvas.zig` and `draw/`) uses, so that code only needs its imports
//! changed.

pub const Atlas = @import("../Atlas.zig");

/// Ghostty's `font.Metrics`, reduced to the fields the drawing code
/// reads. Positions are from the top of the cell.
pub const Metrics = struct {
    cell_width: u32,
    cell_height: u32,
    underline_position: u32,
    underline_thickness: u32,
    strikethrough_position: u32,
    strikethrough_thickness: u32,
    overline_position: i32,
    overline_thickness: u32,
    box_thickness: u32,
    cursor_thickness: u32 = 1,
    cursor_height: u32,
};

pub const sprite = struct {
    const canvas = @import("canvas.zig");
    pub const Canvas = canvas.Canvas;
    pub const Color = canvas.Color;
};
