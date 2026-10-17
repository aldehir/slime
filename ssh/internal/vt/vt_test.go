package vt

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
)

var (
	sharedOnce sync.Once
	shared     *Runtime
	sharedErr  error
)

func runtime(t testing.TB) *Runtime {
	t.Helper()
	sharedOnce.Do(func() { shared, sharedErr = NewRuntime(context.Background(), nil) })
	if sharedErr != nil {
		t.Fatal(sharedErr)
	}
	return shared
}

func newTerm(t testing.TB, cols, rows uint16) *Terminal {
	t.Helper()
	term, err := runtime(t).New(cols, rows)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { term.Close() })
	return term
}

func write(t testing.TB, term *Terminal, s string) {
	t.Helper()
	if _, err := term.Write([]byte(s)); err != nil {
		t.Fatal(err)
	}
}

func text(t testing.TB, term *Terminal) string {
	t.Helper()
	s, err := term.Text()
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func roundTrip(t testing.TB, term *Terminal) *Terminal {
	t.Helper()
	snap, err := term.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasPrefix(snap, []byte("GHOSTSNP")) {
		t.Fatalf("snapshot starts %q", snap[:min(len(snap), 10)])
	}
	got, err := runtime(t).Decode(snap)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { got.Close() })
	return got
}

// sameState fails unless a and b agree on text, cursor, size, and screen.
func sameState(t testing.TB, a, b *Terminal) {
	t.Helper()
	if at, bt := text(t, a), text(t, b); at != bt {
		t.Errorf("text differs:\n%q\n%q", at, bt)
	}
	ax, ay, _ := a.Cursor()
	bx, by, _ := b.Cursor()
	if ax != bx || ay != by {
		t.Errorf("cursor (%d,%d) vs (%d,%d)", ax, ay, bx, by)
	}
	ac, ar, _ := a.Size()
	bc, br, _ := b.Size()
	if ac != bc || ar != br {
		t.Errorf("size %dx%d vs %dx%d", ac, ar, bc, br)
	}
	aa, _ := a.AltScreen()
	ba, _ := b.AltScreen()
	if aa != ba {
		t.Errorf("alt screen %v vs %v", aa, ba)
	}
}

// TestFormatterLayout checks Text's hand-written struct offsets against
// the module's own layout manifest.
func TestFormatterLayout(t *testing.T) {
	term := newTerm(t, 10, 2)
	p, err := term.call1(term.fn.typeJSON)
	if err != nil {
		t.Fatal(err)
	}
	var raw []byte
	for off := uint32(p); ; off++ {
		c, ok := term.mem.ReadByte(off)
		if !ok {
			t.Fatal("type json runs off memory")
		}
		if c == 0 {
			break
		}
		raw = append(raw, c)
	}
	type field struct {
		Offset int `json:"offset"`
	}
	type typ struct {
		Size   int              `json:"size"`
		Fields map[string]field `json:"fields"`
	}
	var manifest struct {
		Types map[string]typ `json:"types"`
	}
	if err := json.Unmarshal(raw, &manifest); err != nil {
		t.Fatal(err)
	}
	opts := manifest.Types["GhosttyFormatterTerminalOptions"]
	extra := manifest.Types["GhosttyFormatterTerminalExtra"]
	screen := manifest.Types["GhosttyFormatterScreenExtra"]
	checks := []struct {
		name      string
		got, want int
	}{
		{"options size", opts.Size, 40},
		{"emit", opts.Fields["emit"].Offset, 4},
		{"unwrap", opts.Fields["unwrap"].Offset, 8},
		{"trim", opts.Fields["trim"].Offset, 9},
		{"extra", opts.Fields["extra"].Offset, 12},
		{"extra size", extra.Size, 24},
		{"extra.screen", extra.Fields["screen"].Offset, 12},
		{"screen size", screen.Size, 12},
	}
	for _, c := range checks {
		if c.got != c.want {
			t.Errorf("%s: manifest %d, Text uses %d", c.name, c.got, c.want)
		}
	}
}

func TestWriteText(t *testing.T) {
	term := newTerm(t, 20, 5)
	write(t, term, "hello\r\n\x1b[1;31mred\x1b[0m world\x1b[3;5Hthere")
	want := "hello\nred world\n    there"
	if got := text(t, term); got != want {
		t.Errorf("text %q, want %q", got, want)
	}
	if x, y, _ := term.Cursor(); x != 9 || y != 2 {
		t.Errorf("cursor (%d,%d), want (9,2)", x, y)
	}
}

func TestResize(t *testing.T) {
	term := newTerm(t, 20, 5)
	if err := term.Resize(100, 40); err != nil {
		t.Fatal(err)
	}
	if c, r, _ := term.Size(); c != 100 || r != 40 {
		t.Errorf("size %dx%d, want 100x40", c, r)
	}
}

func TestSnapshotRoundTrip(t *testing.T) {
	term := newTerm(t, 40, 10)
	write(t, term, "\x1b[1mbold\x1b[0m line one\r\nline two\x1b[5;7H*")
	got := roundTrip(t, term)
	sameState(t, term, got)
}

func TestSnapshotScrollback(t *testing.T) {
	term := newTerm(t, 30, 5)
	for i := range 200 {
		write(t, term, fmt.Sprintf("line %d\r\n", i))
	}
	got := roundTrip(t, term)
	sameState(t, term, got)
	if s := text(t, got); !strings.Contains(s, "line 0\n") || !strings.Contains(s, "line 199") {
		t.Errorf("scrollback lost: %q...", s[:min(len(s), 80)])
	}
}

func TestSnapshotAltScreen(t *testing.T) {
	term := newTerm(t, 30, 5)
	write(t, term, "primary\r\n\x1b[?1049h\x1b[Halternate")
	got := roundTrip(t, term)
	sameState(t, term, got)
	if alt, _ := got.AltScreen(); !alt {
		t.Error("decoded terminal isn't on the alternate screen")
	}
	// Leaving it must bring back the primary screen's contents.
	write(t, term, "\x1b[?1049l")
	write(t, got, "\x1b[?1049l")
	sameState(t, term, got)
	if s := text(t, got); !strings.Contains(s, "primary") {
		t.Errorf("primary screen lost: %q", s)
	}
}

// TestSnapshotMidSequence splits writes inside an SGR sequence and inside
// a UTF-8 codepoint; the snapshot must carry the unfinished part.
func TestSnapshotMidSequence(t *testing.T) {
	cases := []struct{ before, after string }{
		{"abc\x1b[3", "1mred"},
		{"x\x1b]0;ti", "tle\x07y"},
		{"caf\xc3", "\xa9!"},
	}
	for _, c := range cases {
		t.Run(fmt.Sprintf("%q", c.before), func(t *testing.T) {
			term := newTerm(t, 20, 3)
			write(t, term, c.before)
			got := roundTrip(t, term)
			write(t, term, c.after)
			write(t, got, c.after)
			sameState(t, term, got)
		})
	}
}

func TestTerminalsIndependent(t *testing.T) {
	a := newTerm(t, 10, 2)
	b := newTerm(t, 10, 2)
	write(t, a, "aaa")
	write(t, b, "bbb")
	if text(t, a) != "aaa" || text(t, b) != "bbb" {
		t.Errorf("a %q, b %q", text(t, a), text(t, b))
	}
}

// benchStream is shell-ish output: prompts, colored ls, plain text.
func benchStream() []byte {
	var b bytes.Buffer
	for b.Len() < 1<<20 {
		b.WriteString("\x1b[1;32muser@host\x1b[0m:\x1b[1;34m~/src\x1b[0m$ ls -la\r\n")
		for i := range 20 {
			fmt.Fprintf(&b, "-rw-r--r-- 1 user user %6d Oct 16 12:00 \x1b[0;3%dmfile%02d.go\x1b[0m\r\n", i*1234, i%8, i)
		}
		b.WriteString("func main() { fmt.Println(\"hello, world\") } // the quick brown fox jumps over the lazy dog\r\n")
	}
	return b.Bytes()
}

func BenchmarkWrite(b *testing.B) {
	term := newTerm(b, 120, 40)
	data := benchStream()
	b.SetBytes(int64(len(data)))
	for b.Loop() {
		// Chunks the size of a typical pty read.
		for p := data; len(p) > 0; {
			n := min(len(p), 4096)
			term.Write(p[:n])
			p = p[n:]
		}
	}
}

func BenchmarkSnapshot(b *testing.B) {
	term := newTerm(b, 120, 40)
	term.Write(benchStream())
	snap, _ := term.Snapshot()
	b.ReportMetric(float64(len(snap)), "snapshot-bytes")
	for b.Loop() {
		term.Snapshot()
	}
}

func BenchmarkNew(b *testing.B) {
	r := runtime(b)
	for b.Loop() {
		term, err := r.New(80, 24)
		if err != nil {
			b.Fatal(err)
		}
		term.Close()
	}
}

// TestIdleMemory logs a fresh terminal's linear memory, the floor per
// session.
func TestIdleMemory(t *testing.T) {
	term := newTerm(t, 80, 24)
	t.Logf("idle terminal: %d KiB linear memory", term.mem.Size()/1024)
	term.Write(benchStream())
	t.Logf("after 1 MiB of output: %d KiB", term.mem.Size()/1024)
}
