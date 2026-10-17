package vt

import (
	"encoding/binary"
	"testing"
)

func newFrames(t testing.TB) *Frames {
	t.Helper()
	f, err := NewFrames()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(f.Close)
	return f
}

func encode(t testing.TB, f *Frames, term *Terminal, full bool) []byte {
	t.Helper()
	b, err := f.Encode(term, full)
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
// own tests, in slime's, check the contents round trip.
func TestFrames(t *testing.T) {
	term := newTerm(t, 30, 5)
	write(t, term, "hello\r\n\x1b[31mworld")
	f := newFrames(t)

	first := encode(t, f, term, false)
	if first[0] != frameFull|framePalette {
		t.Errorf("first frame flags %#x, want full with the palette", first[0])
	}
	if cols, rows := binary.LittleEndian.Uint16(first[1:]), binary.LittleEndian.Uint16(first[3:]); cols != 30 || rows != 5 {
		t.Errorf("first frame is %dx%d", cols, rows)
	}

	// Nothing changed: no rows (the count ends the frame), no palette.
	idle := encode(t, f, term, false)
	if idle[0] != 0 {
		t.Errorf("idle frame flags %#x", idle[0])
	}
	if n := binary.LittleEndian.Uint16(idle[len(idle)-2:]); n != 0 {
		t.Errorf("idle frame has %d rows", n)
	}

	write(t, term, "!")
	if partial := encode(t, f, term, false); partial[0] != 0 || len(partial) <= len(idle) {
		t.Errorf("partial frame flags %#x, %d bytes", partial[0], len(partial))
	}
	if again := encode(t, f, term, true); again[0]&frameFull == 0 {
		t.Errorf("asked for full, got flags %#x", again[0])
	}
	if FrameLayout() == 0 {
		t.Error("no frame layout id")
	}
}

// BenchmarkFrameFull encodes full frames of a busy 120x40 screen: the
// most a frame costs.
func BenchmarkFrameFull(b *testing.B) {
	term := newTerm(b, 120, 40)
	term.Write(benchStream())
	f := newFrames(b)
	var n int
	for b.Loop() {
		frame, _ := f.Encode(term, true)
		n = len(frame)
	}
	b.ReportMetric(float64(n), "frame-bytes")
}
