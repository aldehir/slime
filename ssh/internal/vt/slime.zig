//! slimed's own exports, compiled into libghostty-vt (`-Dvt-extra`) next
//! to its C API. The library's Zig API is `@import("root")`; terminals
//! come in as the C API's handles. vt.go declares these in its preamble.

const std = @import("std");
const vt = @import("root");
const frame = @import("frame.zig");

const Terminal = vt.c_api.terminal.Terminal;
const Codec = frame.Codec(vt);
const alloc = std.heap.smp_allocator;

/// The Zig terminal behind a C API handle.
fn zigTerminal(t: Terminal) ?*vt.Terminal {
    return (t orelse return null).terminal;
}

/// The frame codec's layout id (frame.zig), which slime checks against
/// its own.
export fn slime_vt_frame_layout() u64 {
    return Codec.layout_id;
}

/// One pane's frames: the render state frames are cut from, and the
/// buffer the last one was encoded into.
const Frames = struct {
    state: vt.RenderState = .empty,
    buf: std.Io.Writer.Allocating,
    palette: ?vt.color.Palette = null,
};

export fn slime_vt_frames_new() ?*Frames {
    const f = alloc.create(Frames) catch return null;
    f.* = .{ .buf = .init(alloc) };
    return f;
}

export fn slime_vt_frames_free(f: ?*Frames) void {
    const self = f orelse return;
    self.buf.deinit();
    self.state.deinit(alloc);
    alloc.destroy(self);
}

/// Encode a frame of what changed in `t` since the last one, or of
/// everything if `full`. The bytes are the Frames' own, valid until the
/// next call. Returns false if out of memory.
export fn slime_vt_frames_encode(
    f: ?*Frames,
    t: Terminal,
    full: bool,
    out_ptr: *[*]const u8,
    out_len: *usize,
) bool {
    const self = f orelse return false;
    const term = zigTerminal(t) orelse return false;
    self.state.update(alloc, term) catch return false;
    const palette = self.state.colors.palette;
    const palette_changed = if (self.palette) |p| !std.mem.eql(vt.color.RGB, &p, &palette) else true;
    self.buf.clearRetainingCapacity();
    Codec.encode(&self.buf.writer, &self.state, .{
        .full = full,
        .palette = palette_changed,
    }) catch return false;
    self.state.clean();
    self.palette = palette;
    const bytes = self.buf.written();
    out_ptr.* = bytes.ptr;
    out_len.* = bytes.len;
    return true;
}
