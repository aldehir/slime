// Package vt runs libghostty-vt, linked in with cgo from a static
// library built with Zig (scripts/build-vt-lib.ps1, or build.zig), for
// the daemon that holds terminal state.
//
// cgo's C compiler is `zig cc` for the target: x86_64-windows-gnu on
// Windows, x86_64-linux-musl (linked fully static) on Linux.
package vt

/*
#cgo CFLAGS: -DGHOSTTY_STATIC -I${SRCDIR}/../../../ghostty/include
#cgo windows,amd64 LDFLAGS: -L${SRCDIR}/lib/windows_amd64 -lghostty-vt -lntdll
#cgo linux,amd64 LDFLAGS: -L${SRCDIR}/lib/linux_amd64 -lghostty-vt
#include <stdlib.h>
#include <ghostty/vt.h>

// In callbacks.c, which can see the exported Go callbacks.
extern GhosttyResult slime_install_callbacks(GhosttyTerminal t, uintptr_t userdata);
extern void slime_install_log(void);
// In slime.zig.
extern void slime_vt_terminal_defaults(GhosttyTerminal t, bool fresh);
*/
import "C"

import (
	"context"
	"fmt"
	"log/slog"
	"sync"
	"unsafe"
)

// ContinuationLimit is how many bytes of an unfinished escape sequence a
// terminal keeps so a snapshot can be taken between any two writes. OSC
// and APC payloads past this make the continuation unavailable until the
// parser next reaches ground.
const ContinuationLimit = 64 * 1024

// Error is a GhosttyResult other than success.
type Error struct {
	Op   string
	Code int32
}

func (e *Error) Error() string { return fmt.Sprintf("vt: %s: result %d", e.Op, e.Code) }

func check(op string, r C.GhosttyResult) error {
	if r != C.GHOSTTY_SUCCESS {
		return &Error{Op: op, Code: int32(r)}
	}
	return nil
}

// Runtime makes terminals. It holds nothing: it's kept so callers set up
// the package once, as they did when it compiled a wasm module.
type Runtime struct{}

// registry has the open terminals, for the callbacks, which find their
// Terminal by the id in their userdata.
var registry struct {
	sync.Mutex
	nextID uint32
	terms  map[uint32]*Terminal
}

func lookup(id uint32) *Terminal {
	registry.Lock()
	defer registry.Unlock()
	return registry.terms[id]
}

// logger receives libghostty-vt's own log lines. The library's log hook
// is process-wide, so the last NewRuntime's logger wins.
var logger struct {
	sync.Mutex
	l *slog.Logger
}

// NewRuntime returns a Runtime. log receives libghostty-vt's own log
// lines; nil discards them.
func NewRuntime(_ context.Context, log *slog.Logger) (*Runtime, error) {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	logger.Lock()
	logger.l = log
	logger.Unlock()
	C.slime_install_log()
	return &Runtime{}, nil
}

// Close does nothing: each Terminal frees itself on Close.
func (r *Runtime) Close(context.Context) error { return nil }

// Terminal is one libghostty-vt terminal. It isn't safe for concurrent
// use.
type Terminal struct {
	id   uint32
	term C.GhosttyTerminal

	events Events
	pend   pending

	// For size reports, which can't call back into the terminal.
	cols, rows   uint16
	cellW, cellH uint32
}

// New creates a terminal with continuation tracking on, so Snapshot works
// whatever the last Write ended on.
func (r *Runtime) New(cols, rows uint16) (*Terminal, error) {
	var term C.GhosttyTerminal
	if err := check("terminal_new", C.ghostty_terminal_new(nil, &term, C.uint16_t(cols), C.uint16_t(rows))); err != nil {
		return nil, err
	}
	t := &Terminal{term: term}
	limit := C.size_t(ContinuationLimit)
	err := check("terminal_set", C.ghostty_terminal_set(term, C.GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, unsafe.Pointer(&limit)))
	if err == nil {
		err = t.finish(true)
	}
	if err != nil {
		t.Close()
		return nil, err
	}
	return t, nil
}

// Decode restores a terminal from a snapshot, with continuation tracking
// on as New leaves it. Callbacks set in the snapshot's terminal aren't
// part of it; the new terminal gets its own.
func (r *Runtime) Decode(snapshot []byte) (*Terminal, error) {
	if len(snapshot) == 0 {
		return nil, &Error{Op: "snapshot_decoder_new_buf", Code: int32(C.GHOSTTY_INVALID_VALUE)}
	}
	var dec C.GhosttySnapshotDecoder
	src := (*C.uint8_t)(unsafe.Pointer(&snapshot[0]))
	if err := check("snapshot_decoder_new_buf", C.ghostty_snapshot_decoder_new_buf(nil, &dec, src, C.size_t(len(snapshot)))); err != nil {
		return nil, err
	}
	defer C.ghostty_snapshot_decoder_free(dec)
	limit := C.size_t(ContinuationLimit)
	if err := check("snapshot_decoder_set", C.ghostty_snapshot_decoder_set(dec, C.GHOSTTY_SNAPSHOT_DECODER_OPT_MAX_CONTINUATION_BYTES, unsafe.Pointer(&limit))); err != nil {
		return nil, err
	}
	retain := C.bool(true)
	if err := check("snapshot_decoder_set", C.ghostty_snapshot_decoder_set(dec, C.GHOSTTY_SNAPSHOT_DECODER_OPT_RETAIN_CONTINUATION, unsafe.Pointer(&retain))); err != nil {
		return nil, err
	}
	var term C.GhosttyTerminal
	if err := check("snapshot_decoder_decode", C.ghostty_snapshot_decoder_decode(dec, &term)); err != nil {
		return nil, err
	}
	t := &Terminal{term: term}
	if err := t.finish(false); err != nil {
		t.Close()
		return nil, err
	}
	return t, nil
}

// finish gives a terminal slime's defaults and registers it for its
// callbacks once its handle exists. A fresh one takes the default modes
// too; a restored one keeps its program's.
func (t *Terminal) finish(fresh bool) error {
	C.slime_vt_terminal_defaults(t.term, C.bool(fresh))
	var err error
	if t.cols, t.rows, err = t.Size(); err != nil {
		return err
	}
	registry.Lock()
	if registry.terms == nil {
		registry.terms = map[uint32]*Terminal{}
	}
	registry.nextID++
	t.id = registry.nextID
	registry.terms[t.id] = t
	registry.Unlock()
	return check("terminal_set", C.slime_install_callbacks(t.term, C.uintptr_t(t.id)))
}

// SetEvents sets the handlers for what the terminal reports.
func (t *Terminal) SetEvents(e Events) { t.events = e }

// Close frees the terminal.
func (t *Terminal) Close() error {
	if t.term == nil {
		return nil
	}
	if t.id != 0 {
		registry.Lock()
		delete(registry.terms, t.id)
		registry.Unlock()
	}
	C.ghostty_terminal_free(t.term)
	t.term = nil
	return nil
}

// Write feeds pty output to the terminal, then delivers the events it
// caused.
func (t *Terminal) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	// p holds no Go pointers, so C may read it in place.
	C.ghostty_terminal_vt_write(t.term, (*C.uint8_t)(unsafe.Pointer(&p[0])), C.size_t(len(p)))
	t.deliver()
	return len(p), nil
}

// Resize changes the grid size. The cell size in pixels is the client's
// (zero if unknown); it only feeds pixel size reports.
func (t *Terminal) Resize(cols, rows uint16, cellW, cellH uint32) error {
	err := check("terminal_resize", C.ghostty_terminal_resize(t.term,
		C.uint16_t(cols), C.uint16_t(rows), C.uint32_t(cellW), C.uint32_t(cellH)))
	if err != nil {
		return err
	}
	t.cols, t.rows, t.cellW, t.cellH = cols, rows, cellW, cellH
	// Mode 2048 sends an in-band size report on resize.
	t.deliver()
	return nil
}

// Title is the title the program last set (OSC 0/2).
func (t *Terminal) Title() (string, error) { return t.getString(C.GHOSTTY_TERMINAL_DATA_TITLE) }

// Pwd is the working directory the shell last reported (OSC 7, 9, 1337),
// as sent: OSC 7's is a file:// URI.
func (t *Terminal) Pwd() (string, error) { return t.getString(C.GHOSTTY_TERMINAL_DATA_PWD) }

func (t *Terminal) getString(key C.GhosttyTerminalData) (string, error) {
	// Borrowed from the terminal.
	var s C.GhosttyString
	if err := check("terminal_get", C.ghostty_terminal_get(t.term, key, unsafe.Pointer(&s))); err != nil {
		return "", err
	}
	return goString(s), nil
}

func goString(s C.GhosttyString) string {
	if s.len == 0 {
		return ""
	}
	return C.GoStringN((*C.char)(unsafe.Pointer(s.ptr)), C.int(s.len))
}

// Size reports the grid size.
func (t *Terminal) Size() (cols, rows uint16, err error) {
	c, err := t.getU16(C.GHOSTTY_TERMINAL_DATA_COLS)
	if err != nil {
		return 0, 0, err
	}
	r, err := t.getU16(C.GHOSTTY_TERMINAL_DATA_ROWS)
	return c, r, err
}

// Cursor reports the cursor position on the active screen, zero-based.
func (t *Terminal) Cursor() (x, y uint16, err error) {
	x, err = t.getU16(C.GHOSTTY_TERMINAL_DATA_CURSOR_X)
	if err != nil {
		return 0, 0, err
	}
	y, err = t.getU16(C.GHOSTTY_TERMINAL_DATA_CURSOR_Y)
	return x, y, err
}

// AltScreen reports whether the alternate screen is active.
func (t *Terminal) AltScreen() (bool, error) {
	var screen C.GhosttyTerminalScreen
	if err := check("terminal_get", C.ghostty_terminal_get(t.term, C.GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, unsafe.Pointer(&screen))); err != nil {
		return false, err
	}
	return screen != C.GHOSTTY_TERMINAL_SCREEN_PRIMARY, nil
}

func (t *Terminal) getU16(key C.GhosttyTerminalData) (uint16, error) {
	var v C.uint16_t
	if err := check("terminal_get", C.ghostty_terminal_get(t.term, key, unsafe.Pointer(&v))); err != nil {
		return 0, err
	}
	return uint16(v), nil
}

// Snapshot encodes the terminal's complete state, scrollback included.
func (t *Terminal) Snapshot() ([]byte, error) {
	var ptr *C.uint8_t
	var n C.size_t
	if err := check("snapshot_encode_alloc", C.ghostty_snapshot_encode_alloc(t.term, nil, &ptr, &n)); err != nil {
		return nil, err
	}
	return takeBytes(ptr, n), nil
}

// Text formats the active screen as plain text, scrollback included,
// with soft-wrapped lines joined and trailing blanks trimmed.
func (t *Terminal) Text() (string, error) {
	b, err := t.format(C.GHOSTTY_FORMATTER_FORMAT_PLAIN)
	return string(b), err
}

// VT formats the active screen, scrollback included, as the VT sequences
// that redraw it on a cleared terminal of the same size: styles, then
// the cursor, modes, scrolling region, tab stops, and keyboard state.
func (t *Terminal) VT() ([]byte, error) { return t.format(C.GHOSTTY_FORMATTER_FORMAT_VT) }

func (t *Terminal) format(emit C.GhosttyFormatterFormat) ([]byte, error) {
	var opts C.GhosttyFormatterTerminalOptions
	opts.size = C.sizeof_GhosttyFormatterTerminalOptions
	opts.emit = emit
	opts.extra.size = C.sizeof_GhosttyFormatterTerminalExtra
	opts.extra.screen.size = C.sizeof_GhosttyFormatterScreenExtra
	if emit == C.GHOSTTY_FORMATTER_FORMAT_PLAIN {
		opts.unwrap = true
		opts.trim = true
	} else {
		// Every extra but pwd (OSC 7 would claim our host's directory).
		e := &opts.extra
		e.palette, e.modes, e.scrolling_region, e.tabstops, e.keyboard = true, true, true, true, true
		s := &e.screen
		s.cursor, s.style, s.hyperlink, s.protection, s.kitty_keyboard, s.charsets = true, true, true, true, true, true
	}
	var f C.GhosttyFormatter
	if err := check("formatter_terminal_new", C.ghostty_formatter_terminal_new(nil, &f, t.term, opts)); err != nil {
		return nil, err
	}
	defer C.ghostty_formatter_free(f)
	var ptr *C.uint8_t
	var n C.size_t
	if err := check("formatter_format_alloc", C.ghostty_formatter_format_alloc(f, nil, &ptr, &n)); err != nil {
		return nil, err
	}
	return takeBytes(ptr, n), nil
}

// takeBytes copies out a buffer libghostty-vt allocated and frees it.
func takeBytes(ptr *C.uint8_t, n C.size_t) []byte {
	if ptr == nil {
		return nil
	}
	b := C.GoBytes(unsafe.Pointer(ptr), C.int(n))
	C.ghostty_free(nil, ptr, n)
	return b
}
