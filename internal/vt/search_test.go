package vt

import (
	"encoding/binary"
	"fmt"
	"strings"
	"testing"
)

// Search (search.zig), driven by events as the window sends them.

const (
	frameSearch        = 1 << 3
	frameSearchPartial = 1 << 4
)

const (
	searchDown = 0
	searchUp   = 1
	stepNext   = 0
	stepPrev   = 1
)

func evSearch(dir byte, needle string) []byte { return append([]byte{11, dir}, needle...) }
func evSearchStep(step byte) []byte           { return []byte{12, step} }

// skipStyle skips a style at f[i] (frame.zig's writeStyle): three colors
// of varying length, then u16 flags.
func skipStyle(f []byte, i int) int {
	for range 3 {
		switch f[i] {
		case 1:
			i += 2
		case 2:
			i += 4
		default:
			i++
		}
	}
	return i + 2
}

// frameSearchCounts reads a frame's flags and search counts (frame.zig's
// header).
func frameSearchCounts(f []byte) (flags byte, matches, current uint32) {
	flags = f[0]
	i := 1 + 2 + 2 + 1 + 3 + 3 + 1 + 3
	if flags&framePalette != 0 {
		i += 256 * 3
	}
	i += 1 + 1 + 2 + 2 + 8 // cursor bits, visual style, x, y, cell
	i = skipStyle(f, i)
	matches = binary.LittleEndian.Uint32(f[i:])
	current = binary.LittleEndian.Uint32(f[i+4:])
	return
}

func wantSearch(t testing.TB, v *View, term *Terminal, on bool, matches, current uint32) {
	t.Helper()
	flags, m, c := frameSearchCounts(frame(t, v, term, false))
	if (flags&frameSearch != 0) != on {
		t.Errorf("frame flags %#x: search on %v, want %v", flags, flags&frameSearch != 0, on)
	}
	if m != matches || c != current {
		t.Errorf("search counts %d / %d, want %d / %d", c, m, current, matches)
	}
}

// TestSearch: a needle finds its matches, the newest is current and is
// the selection, steps move through them wrapping round, and an empty
// needle ends it.
func TestSearch(t *testing.T) {
	term := newTerm(t, 20, 6)
	write(t, term, "alpha one\r\nbeta\r\nalpha two\r\ngamma\r\nalpha three")
	src := newSource(t)
	v := newViewOf(t, src, term)
	event(t, v, term, false, evGeometry(20, 6))
	frame(t, v, term, true)
	wantSearch(t, v, term, false, 0, 0)

	if r := event(t, v, term, false, evSearch(searchDown, "alpha")); !r.Changed {
		t.Fatal("searching changed nothing")
	}
	wantSearch(t, v, term, true, 3, 3)
	if r := event(t, v, term, false, evCopy(1)); string(r.Text) != "alpha" {
		t.Errorf("the current match isn't the selection: copied %q", r.Text)
	}

	// Down: next is newer, wrapping from the newest to the oldest, as
	// tmux's does; previous goes up the screen.
	event(t, v, term, false, evSearchStep(stepNext))
	wantSearch(t, v, term, true, 3, 1)
	event(t, v, term, false, evSearchStep(stepPrev))
	wantSearch(t, v, term, true, 3, 3)
	event(t, v, term, false, evSearchStep(stepPrev))
	wantSearch(t, v, term, true, 3, 2)

	// A narrower needle, searched upward: next goes up.
	event(t, v, term, false, evSearch(searchUp, "alpha t"))
	wantSearch(t, v, term, true, 2, 2)
	event(t, v, term, false, evSearchStep(stepNext))
	wantSearch(t, v, term, true, 2, 1)
	if r := event(t, v, term, false, evCopy(2)); string(r.Text) != "alpha t" {
		t.Errorf("after stepping, copied %q", r.Text)
	}

	event(t, v, term, false, evSearch(searchDown, "nothing here"))
	wantSearch(t, v, term, true, 0, 0)
	if r := event(t, v, term, false, evSearch(searchDown, "")); !r.Changed {
		t.Error("ending the search changed nothing")
	}
	wantSearch(t, v, term, false, 0, 0)
	if src.SearchPending() {
		t.Error("a finished search is pending")
	}
	// The selection it made stays.
	if r := event(t, v, term, false, evCopy(3)); string(r.Text) != "alpha t" {
		t.Errorf("ending the search dropped the selection: %q", r.Text)
	}
}

// TestSearchHighlights: the frame marks matches in their rows, the
// current one with its own tag.
func TestSearchHighlights(t *testing.T) {
	term := newTerm(t, 20, 4)
	write(t, term, "foo bar foo\r\nbar")
	src := newSource(t)
	v := newViewOf(t, src, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)
	event(t, v, term, false, evSearch(searchDown, "foo"))
	rows := frameRows(t, frame(t, v, term, true))
	hls := rows[0]
	if len(hls) != 3 {
		t.Fatalf("row 0 has %d highlights, want 3: %v", len(hls), hls)
	}
	// The current match (tag 2) comes first and is the newer, at the
	// right; it's among the plain matches too, which the renderer
	// resolves by the higher tag.
	want := []highlight{{2, 8, 10}, {1, 0, 2}, {1, 8, 10}}
	for i, h := range want {
		if hls[i] != h {
			t.Errorf("highlight %d is %v, want %v", i, hls[i], h)
		}
	}
	if len(rows[1]) != 0 {
		t.Errorf("row 1 has highlights %v", rows[1])
	}
	event(t, v, term, false, evSearch(searchDown, ""))
	rows = frameRows(t, frame(t, v, term, true))
	if len(rows[0]) != 0 {
		t.Errorf("after ending the search row 0 keeps %v", rows[0])
	}
	if src.SearchPending() {
		t.Error("an ended search is pending")
	}
}

type highlight struct {
	tag         byte
	first, last uint16
}

// frameRows reads a full frame's rows' highlights (frame.zig), by row.
func frameRows(t testing.TB, f []byte) map[uint16][]highlight {
	t.Helper()
	flags, _, _ := frameSearchCounts(f)
	if flags&frameFull == 0 {
		t.Fatal("not a full frame")
	}
	cols := binary.LittleEndian.Uint16(f[1:])
	i := 1 + 2 + 2 + 1 + 3 + 3 + 1 + 3
	if flags&framePalette != 0 {
		i += 256 * 3
	}
	i += 1 + 1 + 2 + 2 + 8
	i = skipStyle(f, i)
	i += 8 // the counts
	n := int(binary.LittleEndian.Uint16(f[i:]))
	i += 2
	rows := map[uint16][]highlight{}
	for range n {
		y := binary.LittleEndian.Uint16(f[i:])
		i += 2
		i += 1 + 2 + 2 // selection
		nh := int(f[i])
		i++
		var hls []highlight
		for range nh {
			hls = append(hls, highlight{f[i], binary.LittleEndian.Uint16(f[i+1:]), binary.LittleEndian.Uint16(f[i+3:])})
			i += 5
		}
		rows[y] = hls
		// Cells: runs of u64 + uleb128 count covering cols.
		covered := 0
		for covered < int(cols) {
			i += 8
			run, k := readUleb(f[i:])
			i += k
			covered += run
		}
		nStyles := int(binary.LittleEndian.Uint16(f[i:]))
		i += 2
		for range nStyles {
			i += 2
			i = skipStyle(f, i)
		}
		nGraphemes := int(binary.LittleEndian.Uint16(f[i:]))
		i += 2
		for range nGraphemes {
			i += 2
			k := int(f[i])
			i += 1 + 3*k
		}
	}
	return rows
}

func readUleb(b []byte) (int, int) {
	var v, shift uint
	for i, c := range b {
		v |= uint(c&0x7f) << shift
		if c&0x80 == 0 {
			return int(v), i + 1
		}
		shift += 7
	}
	panic("short uleb128")
}

// TestSearchScrollback: a match in scrollback scrolls into view, and the
// count covers the history once it's ticked through.
func TestSearchScrollback(t *testing.T) {
	term := newTerm(t, 20, 4)
	for i := range 40 {
		mark := ""
		if i%10 == 0 {
			mark = " mark"
		}
		write(t, term, fmt.Sprintf("row %02d%s\r\n", i, mark))
	}
	src := newSource(t)
	v := newViewOf(t, src, term)
	event(t, v, term, false, evGeometry(20, 4))
	frame(t, v, term, true)
	event(t, v, term, false, evSearch(searchDown, "mark"))
	// Frames tick the history; a few are plenty for 40 rows.
	for range 10 {
		if !src.SearchPending() {
			break
		}
		frame(t, v, term, false)
	}
	wantSearch(t, v, term, true, 4, 4)
	// The newest mark is row 30, scrolled into view.
	if text, _ := FrameText(frame(t, v, term, true)); !strings.Contains(text, "row 30 mark\n") {
		t.Errorf("viewport after the search: %q", text)
	}
	event(t, v, term, false, evSearchStep(stepPrev))
	wantSearch(t, v, term, true, 4, 3)
	if text, _ := FrameText(frame(t, v, term, true)); !strings.Contains(text, "row 20 mark\n") {
		t.Errorf("viewport after stepping to the older match: %q", text)
	}
	// Typing brings the viewport back and drops the selection, but the
	// search stays on.
	event(t, v, term, false, evText(2, "x"))
	wantSearch(t, v, term, true, 4, 3)
}
