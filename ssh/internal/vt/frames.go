package vt

/*
#include <ghostty/vt.h>

typedef struct SlimeFrames SlimeFrames;
extern uint64_t slime_vt_frame_layout(void);
extern SlimeFrames* slime_vt_frames_new(void);
extern void slime_vt_frames_free(SlimeFrames* f);
extern bool slime_vt_frames_encode(SlimeFrames* f, GhosttyTerminal t, bool full,
	const uint8_t** out_ptr, size_t* out_len);
*/
import "C"

import (
	"errors"
	"unsafe"
)

// FrameLayout identifies the frame encoding (frame.zig) and the cell
// and style layouts it copies. slime decodes frames only from a daemon
// whose FrameLayout matches its own.
func FrameLayout() uint64 { return uint64(C.slime_vt_frame_layout()) }

// Frames cuts frames of one terminal for slime to draw: the viewport's
// rows that changed since the last frame, with the cursor, colors, and
// selection. It isn't safe for concurrent use, and its terminal must
// not be written while it encodes.
type Frames struct {
	f *C.SlimeFrames
}

// NewFrames returns a Frames whose first frame is full.
func NewFrames() (*Frames, error) {
	f := C.slime_vt_frames_new()
	if f == nil {
		return nil, errors.New("vt: out of memory")
	}
	return &Frames{f: f}, nil
}

// Close frees the Frames.
func (f *Frames) Close() {
	if f.f != nil {
		C.slime_vt_frames_free(f.f)
		f.f = nil
	}
}

// Encode returns a frame of what changed in t since the last frame, or
// of everything if full: after a new attach, or when a frame was lost.
// The bytes are valid until the next Encode or Close.
func (f *Frames) Encode(t *Terminal, full bool) ([]byte, error) {
	var ptr *C.uint8_t
	var n C.size_t
	if !C.slime_vt_frames_encode(f.f, t.term, C.bool(full), &ptr, &n) {
		return nil, errors.New("vt: encoding a frame failed")
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(ptr)), int(n)), nil
}
