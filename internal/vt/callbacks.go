package vt

/*
#include <ghostty/vt.h>
*/
import "C"

import (
	"bytes"
	"context"
	"image"
	"image/draw"
	"image/png"
	"log/slog"
	"unsafe"
)

// Events are what a terminal reports while it processes output. They're
// delivered after Write returns, never from inside libghostty-vt, so a
// handler may call the Terminal's methods. Nil fields are skipped.
type Events struct {
	// Reply carries bytes the terminal would send back to the program:
	// answers to DA, DSR, DECRQM, XTVERSION, size queries, and the like.
	// The slice is only valid during the call.
	Reply func(p []byte)

	Bell func()

	// TitleChanged and PwdChanged fire once per Write that changed them;
	// read the new value with Title or Pwd.
	TitleChanged func()
	PwdChanged   func()

	// UnknownMode reports each set or reset of a mode libghostty-vt
	// doesn't implement, in order: ConPTY's win32-input-mode (DEC 9001),
	// for one. ansi is false for DEC private modes (CSI ?).
	UnknownMode func(mode uint16, ansi, enabled bool)

	// ProgramStatus reports each program status report (OSC 7501),
	// already checked against the protocol, and PromptStart each new
	// shell prompt (OSC 133 A), which ends what the last command
	// reported. Both arrive in the order the output had them. A full
	// reset reports StatusClear with no id.
	ProgramStatus func(s Status)
	PromptStart   func()

	// ClipboardWrite carries a program's write to the clipboard (OSC 52,
	// 5522): its text, or empty to clear it. Only the last write of a
	// Write is delivered. The slice is only valid during the call.
	ClipboardWrite func(text []byte)
}

// StatusState is a program status report's state, numbered as
// GhosttyProgramStatusState.
type StatusState uint8

const (
	StatusIdle StatusState = iota
	StatusWorking
	StatusDone
	StatusBlocked
	StatusError
	StatusClear
)

// Status is one program status report: the record it sets (ID, empty
// for the program itself) and what it says. Progress is 0 to 100, or -1
// when the report has none.
type Status struct {
	State    StatusState
	Progress int8
	ID       string
}

// Mode is a set or reset of a mode libghostty-vt doesn't implement.
type Mode struct {
	Mode    uint16
	ANSI    bool
	Enabled bool
}

// pending is what callbacks recorded during one Write.
type pending struct {
	reply []byte
	bell  int
	title bool
	pwd   bool
	modes []Mode
	// Program status reports and new prompts, in order; a nil status is
	// a prompt.
	status []*Status
	// The last clipboard write, if hasClipboard.
	clipboard    []byte
	hasClipboard bool
}

// Primary and secondary device attributes, as slime answers them:
// libghostty-vt's defaults (VT220, ANSI color).
const (
	daConformance = 62
	daFeatureANSI = 22
	daDeviceType  = 1
)

// The callbacks run inside ghostty_terminal_vt_write (or resize), on the
// goroutine that called it. They only record, for deliver.

func termOf(ud unsafe.Pointer) *Terminal { return lookup(uint32(uintptr(ud))) }

//export goWritePty
func goWritePty(_ C.GhosttyTerminal, ud unsafe.Pointer, data *C.uint8_t, n C.size_t) {
	if t := termOf(ud); t != nil && n > 0 {
		t.pend.reply = append(t.pend.reply, unsafe.Slice((*byte)(data), int(n))...)
	}
}

//export goBell
func goBell(_ C.GhosttyTerminal, ud unsafe.Pointer) {
	if t := termOf(ud); t != nil {
		t.pend.bell++
	}
}

//export goTitleChanged
func goTitleChanged(_ C.GhosttyTerminal, ud unsafe.Pointer) {
	if t := termOf(ud); t != nil {
		t.pend.title = true
	}
}

//export goPwdChanged
func goPwdChanged(_ C.GhosttyTerminal, ud unsafe.Pointer) {
	if t := termOf(ud); t != nil {
		t.pend.pwd = true
	}
}

//export goDeviceAttributes
func goDeviceAttributes(_ C.GhosttyTerminal, ud unsafe.Pointer, out *C.GhosttyDeviceAttributes) C.bool {
	if termOf(ud) == nil {
		return false
	}
	*out = C.GhosttyDeviceAttributes{}
	out.primary.conformance_level = daConformance
	out.primary.features[0] = daFeatureANSI
	out.primary.num_features = 1
	out.secondary.device_type = daDeviceType
	return true
}

//export goSize
func goSize(_ C.GhosttyTerminal, ud unsafe.Pointer, out *C.GhosttySizeReportSize) C.bool {
	t := termOf(ud)
	if t == nil {
		return false
	}
	out.rows = C.uint16_t(t.rows)
	out.columns = C.uint16_t(t.cols)
	out.cell_width = C.uint32_t(t.cellW)
	out.cell_height = C.uint32_t(t.cellH)
	return true
}

//export goUnknownSequence
func goUnknownSequence(_ C.GhosttyTerminal, ud unsafe.Pointer, seq *C.GhosttyTerminalUnknownSequence) {
	t := termOf(ud)
	if t == nil || seq.tag != C.GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_MODE {
		return
	}
	// cgo sees the value union as bytes.
	m := (*C.GhosttyTerminalUnknownModeSequence)(unsafe.Pointer(&seq.value))
	t.pend.modes = append(t.pend.modes, Mode{uint16(m.mode), bool(m.ansi), bool(m.enabled)})
}

//export goSemanticPrompt
func goSemanticPrompt(_ C.GhosttyTerminal, ud unsafe.Pointer, ev *C.GhosttyTerminalSemanticPrompt) {
	if t := termOf(ud); t != nil && ev.kind == C.GHOSTTY_SEMANTIC_PROMPT_PROMPT_START {
		t.pend.status = append(t.pend.status, nil)
	}
}

//export goProgramStatus
func goProgramStatus(_ C.GhosttyTerminal, ud unsafe.Pointer, rep *C.GhosttyTerminalProgramStatus) {
	if t := termOf(ud); t != nil {
		t.pend.status = append(t.pend.status, &Status{
			State:    StatusState(rep.state),
			Progress: int8(rep.progress),
			ID:       goString(rep.id),
		})
	}
}

//export goClipboardWrite
func goClipboardWrite(_ C.GhosttyTerminal, ud unsafe.Pointer, data *C.uint8_t, n C.size_t) {
	t := termOf(ud)
	if t == nil {
		return
	}
	t.pend.clipboard = t.pend.clipboard[:0]
	if n > 0 {
		t.pend.clipboard = append(t.pend.clipboard, unsafe.Slice((*byte)(data), int(n))...)
	}
	t.pend.hasClipboard = true
}

// maxImageDimension is the widest or tallest kitty image libghostty-vt
// takes (graphics_image.zig's max_dimension), checked before decoding
// a PNG so a tiny file can't claim gigabytes.
const maxImageDimension = 10000

// goDecodePng decodes a PNG for kitty graphics into straight RGBA, in
// memory from the library's allocator, which then owns it. libghostty-vt
// has no decoder of its own as a library; this is Go's. Runs inside
// ghostty_terminal_vt_write.
//
//export goDecodePng
func goDecodePng(_ unsafe.Pointer, allocator *C.GhosttyAllocator, data *C.uint8_t, n C.size_t, out *C.GhosttySysImage) C.bool {
	if n == 0 {
		return false
	}
	src := unsafe.Slice((*byte)(data), int(n))
	cfg, err := png.DecodeConfig(bytes.NewReader(src))
	if err != nil || cfg.Width <= 0 || cfg.Height <= 0 || cfg.Width > maxImageDimension || cfg.Height > maxImageDimension {
		return false
	}
	img, err := png.Decode(bytes.NewReader(src))
	if err != nil {
		return false
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	size := w * h * 4
	buf := C.ghostty_alloc(allocator, C.size_t(size))
	if buf == nil {
		return false
	}
	dst := unsafe.Slice((*byte)(buf), size)
	if nrgba, ok := img.(*image.NRGBA); ok && nrgba.Stride == w*4 {
		copy(dst, nrgba.Pix[:size])
	} else {
		// Paletted, gray, and 16-bit images convert pixel by pixel.
		draw.Draw(&image.NRGBA{Pix: dst, Stride: w * 4, Rect: image.Rect(0, 0, w, h)}, image.Rect(0, 0, w, h), img, b.Min, draw.Src)
	}
	out.width = C.uint32_t(w)
	out.height = C.uint32_t(h)
	out.data = buf
	out.data_len = C.size_t(size)
	return true
}

//export goLog
func goLog(_ unsafe.Pointer, level C.GhosttySysLogLevel, scope *C.uint8_t, scopeLen C.size_t, msg *C.uint8_t, msgLen C.size_t) {
	logger.Lock()
	l := logger.l
	logger.Unlock()
	if l == nil {
		return
	}
	lvl := slog.LevelDebug
	switch level {
	case C.GHOSTTY_SYS_LOG_LEVEL_ERROR:
		lvl = slog.LevelError
	case C.GHOSTTY_SYS_LOG_LEVEL_WARNING:
		lvl = slog.LevelWarn
	case C.GHOSTTY_SYS_LOG_LEVEL_INFO:
		lvl = slog.LevelInfo
	}
	text := func(p *C.uint8_t, n C.size_t) string {
		if n == 0 {
			return ""
		}
		return string(unsafe.Slice((*byte)(p), int(n)))
	}
	l.Log(context.Background(), lvl, "ghostty-vt", "scope", text(scope, scopeLen), "msg", text(msg, msgLen))
}

// deliver hands what the last Write's callbacks recorded to the handlers.
func (t *Terminal) deliver() {
	p := t.pend
	t.pend = pending{reply: p.reply[:0], modes: p.modes[:0], status: p.status[:0], clipboard: p.clipboard[:0]}
	for _, s := range p.status {
		if s == nil {
			if t.events.PromptStart != nil {
				t.events.PromptStart()
			}
		} else if t.events.ProgramStatus != nil {
			t.events.ProgramStatus(*s)
		}
	}
	for _, m := range p.modes {
		if t.events.UnknownMode != nil {
			t.events.UnknownMode(m.Mode, m.ANSI, m.Enabled)
		}
	}
	if len(p.reply) > 0 && t.events.Reply != nil {
		t.events.Reply(p.reply)
	}
	for range p.bell {
		if t.events.Bell != nil {
			t.events.Bell()
		}
	}
	if p.title && t.events.TitleChanged != nil {
		t.events.TitleChanged()
	}
	if p.pwd && t.events.PwdChanged != nil {
		t.events.PwdChanged()
	}
	if p.hasClipboard && t.events.ClipboardWrite != nil {
		t.events.ClipboardWrite(p.clipboard)
	}
}
