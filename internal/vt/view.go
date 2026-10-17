package vt

/*
#include <stdlib.h>
#include <ghostty/vt.h>

typedef struct SlimeView SlimeView;

// slime.zig's Result.
typedef struct {
	const uint8_t* pty_ptr;
	size_t pty_len;
	const uint8_t* copied_ptr;
	size_t copied_len;
	uint32_t copy_tag;
	bool copied;
	bool changed;
	bool autoscroll;
} SlimeResult;

extern uint64_t slime_vt_frame_layout(void);
extern bool slime_vt_frame_text(const uint8_t* ptr, size_t len, uint8_t** out_ptr, size_t* out_len);

typedef struct SlimeScreen SlimeScreen;
extern SlimeScreen* slime_vt_screen_new(void);
extern void slime_vt_screen_free(SlimeScreen* s);
extern bool slime_vt_screen_apply(SlimeScreen* s, const uint8_t* ptr, size_t len);
extern bool slime_vt_screen_text(const SlimeScreen* s, uint8_t** out_ptr, size_t* out_len);
extern SlimeView* slime_vt_view_new(void);
extern void slime_vt_view_free(SlimeView* v, GhosttyTerminal t);
extern void slime_vt_view_reset(SlimeView* v, GhosttyTerminal t);
extern uint8_t slime_vt_view_hold(SlimeView* v, GhosttyTerminal t);
extern void slime_vt_end_sync(GhosttyTerminal t);
extern bool slime_vt_view_frame(SlimeView* v, GhosttyTerminal t, bool full,
	const uint8_t** out_ptr, size_t* out_len);

// slime.zig's Image.
typedef struct {
	uint32_t id;
	uint64_t generation;
	uint32_t width;
	uint32_t height;
	const uint8_t* ptr;
	size_t len;
} SlimeImage;

extern uint8_t slime_vt_view_image(SlimeView* v, GhosttyTerminal t, size_t i, SlimeImage* out);
extern bool slime_vt_view_event(SlimeView* v, GhosttyTerminal t, bool win32_input,
	const uint8_t* ptr, size_t len, SlimeResult* result);
extern bool slime_vt_view_autoscroll(SlimeView* v, GhosttyTerminal t, SlimeResult* result);
*/
import "C"

import (
	"errors"
	"strings"
	"time"
	"unsafe"
)

// FrameLayout identifies the frame encoding (frame.zig) and the cell
// and style layouts it copies. A client decodes frames only from a daemon
// whose FrameLayout matches its own.
func FrameLayout() uint64 { return uint64(C.slime_vt_frame_layout()) }

// FrameText decodes a frame and returns the text of the rows it carries,
// a line each, trailing blanks trimmed: for tests and debugging.
func FrameText(frame []byte) (string, error) {
	if len(frame) == 0 {
		return "", errors.New("vt: empty frame")
	}
	var ptr *C.uint8_t
	var n C.size_t
	if !C.slime_vt_frame_text((*C.uint8_t)(unsafe.Pointer(&frame[0])), C.size_t(len(frame)), &ptr, &n) {
		return "", errors.New("vt: bad frame")
	}
	return takeText(ptr, n), nil
}

// takeText copies out a text buffer slime.zig allocated with malloc and
// frees it; nil is empty.
func takeText(ptr *C.uint8_t, n C.size_t) string {
	if ptr == nil {
		return ""
	}
	defer C.free(unsafe.Pointer(ptr))
	return C.GoStringN((*C.char)(unsafe.Pointer(ptr)), C.int(n))
}

// Screen is a pane as a client mirrors it from its frames, the viewport
// only: for tests and debugging. It isn't safe for concurrent use.
type Screen struct{ s *C.SlimeScreen }

func NewScreen() (*Screen, error) {
	s := C.slime_vt_screen_new()
	if s == nil {
		return nil, errors.New("vt: out of memory")
	}
	return &Screen{s: s}, nil
}

func (s *Screen) Close() {
	if s.s != nil {
		C.slime_vt_screen_free(s.s)
		s.s = nil
	}
}

// Apply draws a frame on the screen. A partial frame must fit the size
// the last full one set; after an error the screen wants a full frame.
func (s *Screen) Apply(frame []byte) error {
	if len(frame) == 0 {
		return errors.New("vt: empty frame")
	}
	if !C.slime_vt_screen_apply(s.s, (*C.uint8_t)(unsafe.Pointer(&frame[0])), C.size_t(len(frame))) {
		return errors.New("vt: bad frame")
	}
	return nil
}

// Text is the screen's rows, a line each, trailing blanks and blank rows
// trimmed.
func (s *Screen) Text() (string, error) {
	var ptr *C.uint8_t
	var n C.size_t
	if !C.slime_vt_screen_text(s.s, &ptr, &n) {
		return "", errors.New("vt: formatting the screen")
	}
	return strings.TrimRight(takeText(ptr, n), "\n"), nil
}

// AutoscrollInterval is how often a selection drag past an edge
// scrolls: Session's old timer.
const AutoscrollInterval = 15 * time.Millisecond

// View is one terminal as a client sees and drives it: frames of it to
// draw (the viewport's rows that changed since the last frame, with the
// cursor, colors, and selection) and the input state its events act on.
// It isn't safe for concurrent use, and its terminal must not be written
// while a call on it runs.
type View struct {
	v *C.SlimeView
}

// NewView returns a View whose first frame is full.
func NewView() (*View, error) {
	v := C.slime_vt_view_new()
	if v == nil {
		return nil, errors.New("vt: out of memory")
	}
	return &View{v: v}, nil
}

// Close frees the View. t is its terminal, which must still be open: a
// selection drag holds places in it.
func (v *View) Close(t *Terminal) {
	if v.v != nil {
		C.slime_vt_view_free(v.v, t.term)
		v.v = nil
	}
}

// Reset forgets the input state the last client left: a selection drag
// in progress, the wheel's remainder, the cell motion was last reported
// in. For a new client; the frames' state stays.
func (v *View) Reset(t *Terminal) { C.slime_vt_view_reset(v.v, t.term) }

// Hold is why the next frame of a terminal should wait.
type Hold uint8

const (
	HoldNone Hold = iota
	// HoldSync: the program is partway through an update (mode 2026).
	// Past a second, EndSync ends it.
	HoldSync
	// HoldCursor: the program hid the cursor the last frame showed, and
	// likely shows it again in a moment (ConPTY splits PSReadLine's
	// redraws). Worth a few milliseconds' wait, no more.
	HoldCursor
)

// Hold says whether t's next frame should wait, and why.
func (v *View) Hold(t *Terminal) Hold { return Hold(C.slime_vt_view_hold(v.v, t.term)) }

// EndSync turns off synchronized output that held frames too long.
func (t *Terminal) EndSync() { C.slime_vt_end_sync(t.term) }

// Frame returns a frame of what changed in t since the last frame, or
// of everything if full: after a new attach, which also means the
// client has none of the images. The bytes are valid until the next
// Frame; Image may be called meanwhile.
func (v *View) Frame(t *Terminal, full bool) ([]byte, error) {
	var ptr *C.uint8_t
	var n C.size_t
	if !C.slime_vt_view_frame(v.v, t.term, C.bool(full), &ptr, &n) {
		return nil, errors.New("vt: encoding a frame failed")
	}
	return unsafe.Slice((*byte)(unsafe.Pointer(ptr)), int(n)), nil
}

// Image is a kitty image a frame places that the client lacks: sent
// before the frame, as frame.zig lays out.
type Image struct {
	ID         uint32
	Generation uint64
	Width      uint32
	Height     uint32
	// RGBA is straight (not premultiplied), rows top-down, Width *
	// Height * 4 bytes. Valid until the next Image call.
	RGBA []byte
}

// Image returns the i-th image the last Frame needs sent before it.
// more is false past the last; a nil image with more set is one the
// terminal lost meanwhile, to skip.
func (v *View) Image(t *Terminal, i int) (img *Image, more bool) {
	var out C.SlimeImage
	switch C.slime_vt_view_image(v.v, t.term, C.size_t(i), &out) {
	case 1:
		return &Image{
			ID:         uint32(out.id),
			Generation: uint64(out.generation),
			Width:      uint32(out.width),
			Height:     uint32(out.height),
			RGBA:       unsafe.Slice((*byte)(unsafe.Pointer(out.ptr)), int(out.len)),
		}, true
	case 2:
		return nil, true
	}
	return nil, false
}

// Result is what an event did. Its bytes are valid until the next call
// on the View.
type Result struct {
	// Pty is input for the child: an encoded key, report, or paste.
	Pty []byte
	// Copied is set for a copy event: its tag, and the selection's text
	// (empty with no selection).
	Copied  bool
	CopyTag uint32
	Text    []byte
	// Changed: the pane looks different with no new output (the
	// selection or viewport moved), so a frame is due.
	Changed bool
	// Autoscroll: a selection drag sits past an edge. Call Autoscroll
	// every AutoscrollInterval while it stays set.
	Autoscroll bool
}

// Event handles an event from the client (event.zig's encoding).
// win32Input is whether the program turned on win32-input-mode (DEC
// 9001), which libghostty-vt leaves to us.
func (v *View) Event(t *Terminal, win32Input bool, ev []byte) (Result, error) {
	if len(ev) == 0 {
		return Result{}, errors.New("vt: empty event")
	}
	var r C.SlimeResult
	if !C.slime_vt_view_event(v.v, t.term, C.bool(win32Input), (*C.uint8_t)(unsafe.Pointer(&ev[0])), C.size_t(len(ev)), &r) {
		return Result{}, errors.New("vt: bad event")
	}
	return result(&r), nil
}

// Autoscroll scrolls toward a selection drag past an edge and extends
// the selection there.
func (v *View) Autoscroll(t *Terminal) Result {
	var r C.SlimeResult
	if !C.slime_vt_view_autoscroll(v.v, t.term, &r) {
		return Result{}
	}
	return result(&r)
}

func result(r *C.SlimeResult) Result {
	out := Result{
		Copied:     bool(r.copied),
		CopyTag:    uint32(r.copy_tag),
		Changed:    bool(r.changed),
		Autoscroll: bool(r.autoscroll),
	}
	if r.pty_len > 0 {
		out.Pty = unsafe.Slice((*byte)(unsafe.Pointer(r.pty_ptr)), int(r.pty_len))
	}
	if r.copied_len > 0 {
		out.Text = unsafe.Slice((*byte)(unsafe.Pointer(r.copied_ptr)), int(r.copied_len))
	}
	return out
}
