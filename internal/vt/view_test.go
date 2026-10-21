package vt

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math"
	"strings"
	"testing"
)

func newSource(t testing.TB) *Source {
	t.Helper()
	s, err := NewSource()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close(nil) })
	return s
}

func newView(t testing.TB, term *Terminal) *View {
	t.Helper()
	return newViewOf(t, newSource(t), term)
}

// newViewOf makes a view on src, closed before src is.
func newViewOf(t testing.TB, src *Source, term *Terminal) *View {
	t.Helper()
	v, err := NewView(src)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { v.Close(term) })
	return v
}

func frame(t testing.TB, v *View, term *Terminal, full bool) []byte {
	t.Helper()
	b, err := v.Frame(term, full)
	if err != nil {
		t.Fatal(err)
	}
	return append([]byte(nil), b...)
}

// Frame header bits (frame.zig Flags).
const (
	frameFull    = 1 << 0
	framePalette = 1 << 1
)

// TestFrames checks the header of frames cut from a terminal; frame.zig's
// own tests, in the GUI's, check the contents round trip.
func TestFrames(t *testing.T) {
	term := newTerm(t, 30, 5)
	write(t, term, "hello\r\n\x1b[31mworld")
	v := newView(t, term)

	first := frame(t, v, term, false)
	if first[0] != frameFull|framePalette {
		t.Errorf("first frame flags %#x, want full with the palette", first[0])
	}
	if cols, rows := binary.LittleEndian.Uint16(first[1:]), binary.LittleEndian.Uint16(first[3:]); cols != 30 || rows != 5 {
		t.Errorf("first frame is %dx%d", cols, rows)
	}

	// Nothing changed: no rows (the count ends the frame), no palette.
	idle := frame(t, v, term, false)
	if idle[0] != 0 {
		t.Errorf("idle frame flags %#x", idle[0])
	}
	if n := binary.LittleEndian.Uint16(idle[len(idle)-2:]); n != 0 {
		t.Errorf("idle frame has %d rows", n)
	}
	// No rows, no text: once a crash, freeing an empty result.
	if text, err := FrameText(idle); err != nil || text != "" {
		t.Errorf("idle frame text %q (%v)", text, err)
	}

	write(t, term, "!")
	partial := frame(t, v, term, false)
	if partial[0] != 0 || len(partial) <= len(idle) {
		t.Errorf("partial frame flags %#x, %d bytes", partial[0], len(partial))
	}
	if text, err := FrameText(partial); err != nil || text != "world!\n" {
		t.Errorf("partial frame carries %q (%v)", text, err)
	}
	if again := frame(t, v, term, true); again[0]&frameFull == 0 {
		t.Errorf("asked for full, got flags %#x", again[0])
	}
	if FrameLayout() == 0 {
		t.Error("no frame layout id")
	}
}

// TestTwoViews: views on one source each see every change, whichever
// frames first, and each gets a full frame after a resize.
func TestTwoViews(t *testing.T) {
	term := newTerm(t, 30, 5)
	src := newSource(t)
	a := newViewOf(t, src, term)
	b := newViewOf(t, src, term)
	write(t, term, "one")
	frame(t, a, term, false)
	// a consumed the change; b, framing later, still gets it.
	first := frame(t, b, term, false)
	if first[0]&frameFull == 0 {
		t.Errorf("b's first frame flags %#x, want full", first[0])
	}
	// The row the cursor left is dirty too.
	write(t, term, "\r\ntwo")
	fa := frame(t, a, term, false)
	fb := frame(t, b, term, false)
	for name, f := range map[string][]byte{"a": fa, "b": fb} {
		if text, err := FrameText(f); err != nil || text != "one\ntwo\n" {
			t.Errorf("%s's partial frame carries %q (%v)", name, text, err)
		}
	}
	// Two changes before b frames: every row either touched comes.
	write(t, term, "\r\nthree")
	frame(t, a, term, false)
	write(t, term, "\r\nfour")
	frame(t, a, term, false)
	if text, err := FrameText(frame(t, b, term, false)); err != nil || text != "two\nthree\nfour\n" {
		t.Errorf("b's frame after two changes carries %q (%v)", text, err)
	}
	if idle := frame(t, b, term, false); binary.LittleEndian.Uint16(idle[len(idle)-2:]) != 0 {
		t.Error("b's idle frame has rows")
	}
	// A resize changes everything: full for both.
	if err := term.Resize(20, 4, 0, 0); err != nil {
		t.Fatal(err)
	}
	for name, v := range map[string]*View{"a": a, "b": b} {
		if f := frame(t, v, term, false); f[0]&frameFull == 0 {
			t.Errorf("%s's frame after a resize flags %#x, want full", name, f[0])
		}
	}
}

// kittyImage is a kitty graphics transmission of data in format f (24
// for RGB, 100 for PNG) with image id, placed at the cursor.
func kittyImage(id int, f string, data []byte) string {
	return fmt.Sprintf("\x1b_Gf=%s,i=%d,a=T;%s\x1b\\", f, id, base64.StdEncoding.EncodeToString(data))
}

// TestFrameImages checks that an image a frame places is handed out
// once, as RGBA, and again for a full frame (a new client).
func TestFrameImages(t *testing.T) {
	term := newTerm(t, 20, 5)
	// Placements have a pixel size only once the cells do.
	if err := term.Resize(20, 5, 10, 20); err != nil {
		t.Fatal(err)
	}
	v := newView(t, term)
	frame(t, v, term, false)
	if _, more := v.Image(term, 0); more {
		t.Error("an image before any was placed")
	}

	rgb := []byte{255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255}
	write(t, term, kittyImage(7, "24,s=2,v=2", rgb))
	f := frame(t, v, term, false)
	img, more := v.Image(term, 0)
	if !more || img == nil {
		t.Fatalf("image after placing one: %v, more %v", img, more)
	}
	if img.ID != 7 || img.Width != 2 || img.Height != 2 || img.Generation == 0 {
		t.Errorf("image %+v", img)
	}
	want := []byte{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}
	if !bytes.Equal(img.RGBA, want) {
		t.Errorf("RGBA %v, want %v", img.RGBA, want)
	}
	if _, more := v.Image(term, 1); more {
		t.Error("a second image")
	}
	// The frame's bytes outlive the images.
	if _, err := FrameText(f); err != nil {
		t.Errorf("frame after images: %v", err)
	}

	write(t, term, "x")
	frame(t, v, term, false)
	if _, more := v.Image(term, 0); more {
		t.Error("the image was sent again")
	}
	frame(t, v, term, true)
	if img, more := v.Image(term, 0); !more || img == nil || img.ID != 7 {
		t.Error("a full frame didn't send the image again")
	}
}

// TestFrameImagePng checks the PNG decoder installed for kitty graphics:
// a color PNG, and a gray one, which converts pixel by pixel.
func TestFrameImagePng(t *testing.T) {
	term := newTerm(t, 20, 5)
	if err := term.Resize(20, 5, 10, 20); err != nil {
		t.Fatal(err)
	}
	v := newView(t, term)
	frame(t, v, term, false)

	src := image.NewNRGBA(image.Rect(0, 0, 3, 2))
	for i := range src.Pix {
		src.Pix[i] = byte(i * 7)
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, src); err != nil {
		t.Fatal(err)
	}
	write(t, term, kittyImage(8, "100", buf.Bytes()))
	frame(t, v, term, false)
	img, more := v.Image(term, 0)
	if !more || img == nil {
		t.Fatal("no image from a PNG")
	}
	if img.ID != 8 || img.Width != 3 || img.Height != 2 || !bytes.Equal(img.RGBA, src.Pix) {
		t.Errorf("PNG image %+v, want %v", img, src.Pix)
	}

	gray := image.NewGray(image.Rect(0, 0, 2, 1))
	gray.SetGray(0, 0, color.Gray{Y: 0})
	gray.SetGray(1, 0, color.Gray{Y: 255})
	buf.Reset()
	if err := png.Encode(&buf, gray); err != nil {
		t.Fatal(err)
	}
	write(t, term, kittyImage(9, "100", buf.Bytes()))
	frame(t, v, term, false)
	img, more = v.Image(term, 0)
	if !more || img == nil {
		t.Fatal("no image from a gray PNG")
	}
	if want := []byte{0, 0, 0, 255, 255, 255, 255, 255}; img.ID != 9 || !bytes.Equal(img.RGBA, want) {
		t.Errorf("gray PNG image %+v, want %v", img, want)
	}

	// Not a PNG: rejected, so nothing to send.
	write(t, term, kittyImage(10, "100", []byte("not a png")))
	frame(t, v, term, false)
	if _, more := v.Image(term, 0); more {
		t.Error("a bad PNG was placed")
	}
}

// BenchmarkFrameFull encodes full frames of a busy 120x40 screen: the
// most a frame costs.
func BenchmarkFrameFull(b *testing.B) {
	term := newTerm(b, 120, 40)
	term.Write(benchStream())
	v := newView(b, term)
	var n int
	for b.Loop() {
		f, _ := v.Frame(term, true)
		n = len(f)
	}
	b.ReportMetric(float64(n), "frame-bytes")
}

// Events, encoded as event.zig lays them out. The GUI encodes them with
// event.zig itself; these are the few the tests need.

func evText(kind byte, s string) []byte { return append([]byte{kind}, s...) }

func evFocus(gained bool) []byte {
	b := []byte{4, 0}
	if gained {
		b[1] = 1
	}
	return b
}

// Mouse actions and buttons, as ghostty numbers them.
const (
	mousePress   = 0
	mouseRelease = 1
	mouseMotion  = 2
	buttonLeft   = 1
)

func evMouse(action, button byte, held bool, x, y float32, timeMs uint32) []byte {
	b := []byte{5, action, button, 0, 0, 0}
	if held {
		b[5] = 1
	}
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(x))
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(y))
	return binary.LittleEndian.AppendUint32(b, timeMs)
}

func evWheel(rotation int16, lines uint32) []byte {
	b := []byte{6, 0}
	b = binary.LittleEndian.AppendUint16(b, uint16(rotation))
	b = binary.LittleEndian.AppendUint32(b, lines)
	b = append(b, 0, 0)
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(5))
	return binary.LittleEndian.AppendUint32(b, math.Float32bits(5))
}

func evCopy(tag uint32) []byte { return binary.LittleEndian.AppendUint32([]byte{7}, tag) }

// evGeometry: 10x20 cells, no padding, cols*rows of them.
func evGeometry(cols, rows uint32) []byte {
	b := []byte{8}
	for _, v := range []uint32{10, 20, 0, 0, 0, 0, cols * 10, rows * 20} {
		b = binary.LittleEndian.AppendUint32(b, v)
	}
	return b
}

// evKey is a key with no identity (unidentified, so never a modifier)
// that typed text, and the win32-input-mode records for it.
func evKey(text string, win32 ...[]byte) []byte {
	// Kind, action (press), key, mods, consumed mods, composing, and the
	// unshifted codepoint, all zero but the first two.
	b := []byte{1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	b = append(b, byte(len(text)))
	b = append(b, text...)
	b = append(b, byte(len(win32)))
	for _, r := range win32 {
		b = append(b, r...)
	}
	return b
}

// evCtrlKey is ctrl (with alt, if asked) and a key, with the text it
// makes without ctrl, as the window sends it. key is libghostty-vt's
// input.Key.
func evCtrlKey(key uint16, char byte, alt bool) []byte {
	b := evKey(string(char))
	binary.LittleEndian.PutUint16(b[2:], key)
	b[4] = 2 // mods: ctrl
	if alt {
		b[4] |= 4
	}
	binary.LittleEndian.PutUint32(b[9:], uint32(char))
	return b
}

// input.Key values.
const (
	keyBracketLeft = 3
	keyC           = 22
	keyI           = 28
	keyM           = 32
)

func win32Record(vk, scancode, char uint16, down bool) []byte {
	b := binary.LittleEndian.AppendUint16(nil, vk)
	b = binary.LittleEndian.AppendUint16(b, scancode)
	b = binary.LittleEndian.AppendUint16(b, char)
	if down {
		b = append(b, 1)
	} else {
		b = append(b, 0)
	}
	b = binary.LittleEndian.AppendUint32(b, 0)
	return binary.LittleEndian.AppendUint16(b, 1)
}

func event(t testing.TB, v *View, term *Terminal, win32 bool, ev []byte) Result {
	t.Helper()
	r, err := v.Event(term, win32, ev)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestEventInput(t *testing.T) {
	term := newTerm(t, 20, 4)
	v := newView(t, term)
	frame(t, v, term, true)

	// Ctrl keys go under each keyboard protocol: none (legacy), xterm
	// modifyOtherKeys 2, and kitty's.
	const legacy, modifyOther, kitty = "\x1b[=0u\x1b[>4;0m", "\x1b[=0u\x1b[>4;2m", "\x1b[>4;0m\x1b[=1u"
	cases := []struct {
		name  string
		setup string
		win32 bool
		ev    []byte
		want  string
	}{
		{"text", "", false, evText(2, "hi"), "hi"},
		{"text in win32-input-mode", "", true, evText(2, "a"), "\x1b[0;0;97;1;0;1_\x1b[0;0;97;0;0;1_"},
		{"paste", "", false, evText(3, "one\ntwo"), "one\rtwo"},
		{"bracketed paste", "\x1b[?2004h", false, evText(3, "x"), "\x1b[200~x\x1b[201~"},
		{"focus unasked", "\x1b[?2004l", false, evFocus(true), ""},
		{"focus", "\x1b[?1004h", false, evFocus(false), "\x1b[O"},
		{"key", "", false, evKey("a"), "a"},
		{"key in win32-input-mode", "", true, evKey("a", win32Record(65, 30, 'a', true)), "\x1b[65;30;97;1;0;1_"},
		{"ctrl+c", legacy, false, evCtrlKey(keyC, 'c', false), "\x03"},
		{"ctrl+[", legacy, false, evCtrlKey(keyBracketLeft, '[', false), "\x1b"},
		{"ctrl+i", legacy, false, evCtrlKey(keyI, 'i', false), "\t"},
		{"ctrl+m", legacy, false, evCtrlKey(keyM, 'm', false), "\r"},
		{"ctrl+alt+c", legacy, false, evCtrlKey(keyC, 'c', true), "\x1b\x03"},
		{"ctrl+alt+[", legacy, false, evCtrlKey(keyBracketLeft, '[', true), "\x1b\x1b"},
		{"ctrl+c modifyOtherKeys", modifyOther, false, evCtrlKey(keyC, 'c', false), "\x1b[27;5;99~"},
		{"ctrl+[ modifyOtherKeys", modifyOther, false, evCtrlKey(keyBracketLeft, '[', false), "\x1b[27;5;91~"},
		{"ctrl+c kitty", kitty, false, evCtrlKey(keyC, 'c', false), "\x1b[99;5u"},
		{"ctrl+[ kitty", kitty, false, evCtrlKey(keyBracketLeft, '[', false), "\x1b[91;5u"},
		{"ctrl+c back to legacy", legacy, false, evCtrlKey(keyC, 'c', false), "\x03"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			write(t, term, c.setup)
			if got := string(event(t, v, term, c.win32, c.ev).Pty); got != c.want {
				t.Errorf("got %q, want %q", got, c.want)
			}
		})
	}
	if _, err := v.Event(term, false, []byte{99}); err == nil {
		t.Error("an unknown event kind was taken")
	}
}

// TestEventSelect drags a selection, double-clicks a word, copies each,
// and checks that typing clears it.
func TestEventSelect(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "hello world\r\nsecond")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)

	event(t, v, term, false, evMouse(mousePress, buttonLeft, true, 1, 1, 1000))
	if r := event(t, v, term, false, evMouse(mouseMotion, 0, true, 48, 1, 1010)); !r.Changed {
		t.Error("dragging didn't change the selection")
	}
	event(t, v, term, false, evMouse(mouseRelease, buttonLeft, false, 48, 1, 1020))
	r := event(t, v, term, false, evCopy(7))
	if !r.Copied || r.CopyTag != 7 || string(r.Text) != "hello" {
		t.Errorf("copied %v tag %d %q, want hello", r.Copied, r.CopyTag, r.Text)
	}
	if text, _ := FrameText(frame(t, v, term, false)); !strings.Contains(text, "hello world") {
		t.Errorf("the selection's row isn't in the next frame: %q", text)
	}

	// A double click selects the word under it.
	event(t, v, term, false, evMouse(mousePress, buttonLeft, true, 75, 1, 5000))
	event(t, v, term, false, evMouse(mouseRelease, buttonLeft, false, 75, 1, 5010))
	event(t, v, term, false, evMouse(mousePress, buttonLeft, true, 75, 1, 5100))
	event(t, v, term, false, evMouse(mouseRelease, buttonLeft, false, 75, 1, 5110))
	if r := event(t, v, term, false, evCopy(8)); string(r.Text) != "world" {
		t.Errorf("double click copied %q, want world", r.Text)
	}

	if r := event(t, v, term, false, evText(2, "x")); !r.Changed {
		t.Error("typing didn't clear the selection")
	}
	if r := event(t, v, term, false, evCopy(9)); !r.Copied || len(r.Text) != 0 {
		t.Errorf("copy after typing gave %q", r.Text)
	}
}

// TestEventMouseReport checks that a program asking for mouse events
// gets them, and that shift still selects.
func TestEventMouseReport(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "\x1b[?1000h\x1b[?1006h")
	v := newView(t, term)
	event(t, v, term, false, evGeometry(20, 4))
	r := event(t, v, term, false, evMouse(mousePress, buttonLeft, true, 25, 45, 0))
	if got := string(r.Pty); got != "\x1b[<0;3;3M" {
		t.Errorf("press reported %q", got)
	}
	shift := evMouse(mousePress, buttonLeft, true, 25, 45, 100)
	shift[3] = 1 // mods: shift
	if r := event(t, v, term, false, shift); len(r.Pty) != 0 {
		t.Errorf("shift+press reported %q instead of selecting", r.Pty)
	}
}

// TestEventWheel scrolls the viewport through scrollback, and sends arrow
// keys on the alternate screen with alternate scroll.
func TestEventWheel(t *testing.T) {
	term := newTerm(t, 20, 4)
	for i := range 30 {
		write(t, term, fmt.Sprintf("line %d\r\n", i))
	}
	v := newView(t, term)
	frame(t, v, term, true)
	if r := event(t, v, term, false, evWheel(120, 3)); !r.Changed || len(r.Pty) != 0 {
		t.Fatalf("wheel up: changed %v, pty %q", r.Changed, r.Pty)
	}
	if text, _ := FrameText(frame(t, v, term, false)); !strings.Contains(text, "line 25") {
		t.Errorf("after scrolling up 3 the frame shows %q", text)
	}
	// Typing brings the viewport back.
	if r := event(t, v, term, false, evText(2, "x")); !r.Changed {
		t.Error("typing didn't scroll back down")
	}

	write(t, term, "\x1b[?1049h\x1b[?1007h")
	if r := event(t, v, term, false, evWheel(-240, 1)); string(r.Pty) != "\x1b[B\x1b[B" {
		t.Errorf("alternate scroll sent %q", r.Pty)
	}
}
