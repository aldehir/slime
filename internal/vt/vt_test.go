package vt

import (
	"bytes"
	"context"
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

// TestVT redraws a terminal from its VT output onto a fresh one.
func TestVT(t *testing.T) {
	src := newTerm(t, 30, 6)
	write(t, src, "plain\r\n\x1b[1;31mbold red\x1b[0m and \x1b[4munder\x1b[0m\r\n\x1b[?7l\x1b[4;10Hmid")
	b, err := src.VT()
	if err != nil {
		t.Fatal(err)
	}
	dst := newTerm(t, 30, 6)
	write(t, dst, string(b))
	sameState(t, src, dst)
	if !bytes.Contains(b, []byte("\x1b[")) {
		t.Errorf("no escape sequences in %q", b)
	}
}

// recorder collects a terminal's events.
type recorder struct {
	reply  bytes.Buffer
	bells  int
	titles []string
	pwds   []string
}

func record(term *Terminal) *recorder {
	r := &recorder{}
	term.SetEvents(Events{
		Reply: func(p []byte) { r.reply.Write(p) },
		Bell:  func() { r.bells++ },
		TitleChanged: func() {
			s, _ := term.Title()
			r.titles = append(r.titles, s)
		},
		PwdChanged: func() {
			s, _ := term.Pwd()
			r.pwds = append(r.pwds, s)
		},
	})
	return r
}

func TestReplies(t *testing.T) {
	cases := []struct{ name, query, want string }{
		{"DA1", "\x1b[c", "\x1b[?62;22c"},
		{"DA2", "\x1b[>c", "\x1b[>1;0;0c"},
		{"DSR cursor", "ab\x1b[6n", "\x1b[1;3R"},
		{"size in cells", "\x1b[18t", "\x1b[8;24;80t"},
		{"size in pixels", "\x1b[14t", "\x1b[4;480;800t"},
		{"DECRQM", "\x1b[?25$p", "\x1b[?25;1$y"},
		// slime's defaults (slime_vt_terminal_defaults), which a full
		// reset keeps.
		{"grapheme clustering", "\x1b[?2027$p", "\x1b[?2027;1$y"},
		{"grapheme clustering after RIS", "\x1bc\x1b[?2027$p", "\x1b[?2027;1$y"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			term := newTerm(t, 20, 5)
			if err := term.Resize(80, 24, 10, 20); err != nil {
				t.Fatal(err)
			}
			r := record(term)
			write(t, term, c.query)
			if got := r.reply.String(); got != c.want {
				t.Errorf("reply %q, want %q", got, c.want)
			}
		})
	}
}

func TestTitlePwdBell(t *testing.T) {
	term := newTerm(t, 20, 5)
	r := record(term)
	write(t, term, "\x1b]2;first\x07\x07\x1b]2;second\x1b\\")
	write(t, term, "\x1b]7;file://host/home/alde\x07\x07")
	if r.bells != 2 {
		t.Errorf("bells %d, want 2", r.bells)
	}
	// Coalesced per Write: one call, after both titles were set.
	if fmt.Sprint(r.titles) != "[second]" {
		t.Errorf("titles %q", r.titles)
	}
	if fmt.Sprint(r.pwds) != "[file://host/home/alde]" {
		t.Errorf("pwds %q", r.pwds)
	}
}

func TestUnknownModes(t *testing.T) {
	term := newTerm(t, 20, 5)
	var got []Mode
	term.SetEvents(Events{UnknownMode: func(mode uint16, ansi, enabled bool) {
		got = append(got, Mode{mode, ansi, enabled})
	}})
	// 1004 is known (focus events), so only 9001 is reported from the
	// first; then an ANSI mode libghostty-vt doesn't know.
	write(t, term, "\x1b[?9001;1004h\x1b[?9001l\x1b[77h")
	want := []Mode{{9001, false, true}, {9001, false, false}, {77, true, true}}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Errorf("modes %v, want %v", got, want)
	}
}

// TestDecodedCallbacks checks a terminal restored from a snapshot answers
// queries and keeps its title.
func TestDecodedCallbacks(t *testing.T) {
	term := newTerm(t, 20, 5)
	write(t, term, "\x1b]2;kept\x07hi")
	got := roundTrip(t, term)
	if s, _ := got.Title(); s != "kept" {
		t.Errorf("title %q after decode", s)
	}
	r := record(got)
	write(t, got, "\x1b[6n")
	if s := r.reply.String(); s != "\x1b[1;3R" {
		t.Errorf("reply %q", s)
	}
}

// TestChurn opens and closes terminals to catch ones left in the
// callback registry.
func TestChurn(t *testing.T) {
	for range 200 {
		term, err := runtime(t).New(80, 24)
		if err != nil {
			t.Fatal(err)
		}
		r := record(term)
		write(t, term, "\x1b[c")
		if r.reply.Len() == 0 {
			t.Fatal("no reply")
		}
		term.Close()
	}
	registry.Lock()
	n := len(registry.terms)
	registry.Unlock()
	if n != 0 {
		t.Errorf("%d terminals still registered", n)
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
	if err := term.Resize(100, 40, 0, 0); err != nil {
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

// TestProgramStatus checks OSC 7501 reports and new prompts come through
// in order.
func TestProgramStatus(t *testing.T) {
	term := newTerm(t, 20, 4)
	var got []string
	term.SetEvents(Events{
		ProgramStatus: func(s Status) { got = append(got, fmt.Sprintf("%d:%d:%s", s.State, s.Progress, s.ID)) },
		PromptStart:   func() { got = append(got, "prompt") },
	})
	if _, err := term.Write([]byte("\x1b]7501;state=working:progress=40:id=a/b\x1b\\\x1b]133;A\x07\x1b]7501;state=done\x07")); err != nil {
		t.Fatal(err)
	}
	want := []string{"1:40:a/b", "prompt", "2:-1:"}
	if fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

// TestClipboardWrite checks OSC 52 writes reach the handler, the last of
// a Write winning, and that an empty one clears.
func TestClipboardWrite(t *testing.T) {
	term := newTerm(t, 20, 4)
	var got []string
	term.SetEvents(Events{ClipboardWrite: func(text []byte) { got = append(got, string(text)) }})
	// "aGk=" is "hi"; "eW8=" is "yo".
	write(t, term, "\x1b]52;c;aGk=\x07\x1b]52;c;eW8=\x07")
	write(t, term, "\x1b]52;c;\x07")
	write(t, term, "\x1b]52;p;aGk=\x07")
	if fmt.Sprint(got) != fmt.Sprint([]string{"yo", ""}) {
		t.Errorf("clipboard writes %q, want [yo, empty]", got)
	}
}
