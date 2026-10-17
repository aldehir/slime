package persist

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aldehir/slime/ssh/internal/vt"
)

// drawer is a client that draws frames (CapFrames).
type drawer struct {
	t    *testing.T
	c    *Client
	conn net.Conn
	pane uint32
}

// newDrawer connects a client that draws, makes a workspace with one
// pane, and returns it having read the attach.
func newDrawer(t *testing.T, h *harness) *drawer {
	a, b := net.Pipe()
	go h.srv.handle(a)
	c, err := NewClientWith(b, Hello{Caps: CapFrames, FrameInterval: 1000})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	d := &drawer{t: t, c: c, conn: b}
	tag := c.NextTag()
	c.Send(0, &WorkspaceNew{Tag: tag, Name: "test"})
	ws, err := c.Await(tag, false)
	if err != nil {
		t.Fatal(err)
	}
	tag = c.NextTag()
	c.Send(0, &TabNew{Tag: tag, WS: ws.Workspace.ID, Size: Size{Cols: 40, Rows: 10}})
	att, err := c.Await(tag, true)
	if err != nil {
		t.Fatal(err)
	}
	d.pane = att.Created.Pane
	p := att.Panes[d.pane]
	if p == nil {
		t.Fatal("no Attached for the new pane")
	}
	if len(p.Attached.Modes) != 0 || p.Attached.SnapshotLen != 0 {
		t.Errorf("attached with a snapshot (%d bytes)", p.Attached.SnapshotLen)
	}
	return d
}

// draw reads until the pane's next frame, or returns nil if none comes
// within wait.
func (d *drawer) draw(wait time.Duration) *Draw {
	d.t.Helper()
	d.conn.SetReadDeadline(time.Now().Add(wait))
	defer d.conn.SetReadDeadline(time.Time{})
	for {
		id, m, err := d.c.Recv()
		if errors.Is(err, os.ErrDeadlineExceeded) {
			return nil
		}
		if err != nil {
			d.t.Fatal(err)
		}
		if f, ok := m.(*Draw); ok && id == d.pane {
			return &Draw{Seq: f.Seq, Data: append([]byte(nil), f.Data...)}
		}
		if _, ok := m.(*Output); ok {
			d.t.Fatal("a client that draws got raw output")
		}
	}
}

func (d *drawer) ack(f *Draw) { d.c.Send(d.pane, &Ack{Seq: f.Seq}) }

// fullFrame and the size come from the frame's header (frame.zig).
func fullFrame(f *Draw) bool { return f.Data[0]&1 != 0 }

func frameText(t *testing.T, f *Draw) string {
	t.Helper()
	s, err := vt.FrameText(f.Data)
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestFramesOnAttach(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	first := d.draw(5 * time.Second)
	if first == nil || first.Seq != 1 || !fullFrame(first) {
		t.Fatalf("first frame %+v, want a full one, seq 1", first)
	}
	d.ack(first)

	h.pty(0).emit("hello")
	next := d.draw(5 * time.Second)
	if next == nil || next.Seq != 2 || fullFrame(next) {
		t.Fatalf("frame after output %+v, want a partial one, seq 2", next)
	}
	if text := frameText(t, next); text != "hello\n" {
		t.Errorf("partial frame carries %q, want the one row written", text)
	}
}

// TestFramesInFlight checks that at most two frames go unacked, and that
// what changed meanwhile comes in the frame an Ack lets through.
func TestFramesInFlight(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	p := h.pty(0)
	first := d.draw(5 * time.Second)
	p.emit("a")
	second := d.draw(5 * time.Second)
	if first == nil || second == nil {
		t.Fatal("no first two frames")
	}
	for _, s := range []string{"b", "c", "d"} {
		p.emit(s)
		time.Sleep(5 * time.Millisecond)
	}
	if f := d.draw(100 * time.Millisecond); f != nil {
		t.Fatalf("a third frame (seq %d) with two unacked", f.Seq)
	}
	d.ack(first)
	third := d.draw(5 * time.Second)
	if third == nil || third.Seq != 3 {
		t.Fatalf("after an ack got %+v, want seq 3", third)
	}
	if f := d.draw(100 * time.Millisecond); f != nil {
		t.Fatalf("a fourth frame (seq %d) with nothing new", f.Seq)
	}
}

// TestFramesSyncHold checks that synchronized output holds frames until
// it ends.
func TestFramesSyncHold(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.ack(d.draw(5 * time.Second))
	p := h.pty(0)
	p.emit("\x1b[?2026hhalf")
	if f := d.draw(200 * time.Millisecond); f != nil {
		t.Fatalf("frame %d during synchronized output", f.Seq)
	}
	p.emit(" done\x1b[?2026l")
	if f := d.draw(5 * time.Second); f == nil {
		t.Fatal("no frame after synchronized output ended")
	}
}

// TestFramesSyncReset checks that synchronized output left on can't hold
// frames past syncHold.
func TestFramesSyncReset(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.ack(d.draw(5 * time.Second))
	start := time.Now()
	h.pty(0).emit("\x1b[?2026hstuck")
	f := d.draw(5 * time.Second)
	if f == nil {
		t.Fatal("synchronized output held frames for good")
	}
	if held := time.Since(start); held < syncHold/2 {
		t.Errorf("frame after %v, before the hold should end", held)
	}
}

// TestFramesReplies checks that the daemon answers queries for a client
// that draws: it has no terminal of its own to.
func TestFramesReplies(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.draw(5 * time.Second)
	p := h.pty(0)
	p.emit("\x1b[c")
	eventually(t, "the DA1 reply", func() bool { return strings.Contains(p.inputString(), "\x1b[?62;22c") })
}

// TestFramesReattach checks that a client attaching a workspace another
// drew gets a full frame of its own, numbered from 1.
func TestFramesReattach(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.ack(d.draw(5 * time.Second))
	h.pty(0).emit("kept")
	d.draw(5 * time.Second)
	ws := h.list().Workspaces[0].ID

	a, b := net.Pipe()
	go h.srv.handle(a)
	c, err := NewClientWith(b, Hello{Caps: CapFrames})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	tag := c.NextTag()
	c.Send(0, &WorkspaceAttach{Tag: tag, WS: ws})
	if _, err := c.Await(tag, false); err != nil {
		t.Fatal(err)
	}
	d2 := &drawer{t: t, c: c, conn: b, pane: d.pane}
	f := d2.draw(5 * time.Second)
	if f == nil || f.Seq != 1 || !fullFrame(f) {
		t.Fatalf("reattached frame %+v, want a full one, seq 1", f)
	}
	if text := frameText(t, f); !strings.HasPrefix(text, "kept\n") {
		t.Errorf("full frame carries %q", text)
	}
}

// Events, as ssh/internal/vt/event.zig lays them out; vt's tests cover
// what each does.

func evText(s string) []byte { return append([]byte{2}, s...) }

func evCopy(tag uint32) []byte { return binary.LittleEndian.AppendUint32([]byte{7}, tag) }

// evGeometry: 10x20 cells, no padding.
func evGeometry(cols, rows uint32) []byte {
	b := []byte{8}
	for _, v := range []uint32{10, 20, 0, 0, 0, 0, cols * 10, rows * 20} {
		b = binary.LittleEndian.AppendUint32(b, v)
	}
	return b
}

// evLeft is a left button event: action 0 press, 1 release, 2 motion.
func evLeft(action byte, x, y float32) []byte {
	b := []byte{5, action, 1, 0, 0, 1}
	if action == 1 {
		b[5] = 0
	}
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(x))
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(y))
	return binary.LittleEndian.AppendUint32(b, 0)
}

func (d *drawer) event(ev []byte) { d.c.Send(d.pane, &Event{Data: ev}) }

// copied reads until the pane's Copied reply, acking frames on the way.
func (d *drawer) copied() *Copied {
	d.t.Helper()
	d.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer d.conn.SetReadDeadline(time.Time{})
	for {
		id, m, err := d.c.Recv()
		if err != nil {
			d.t.Fatal(err)
		}
		switch m := m.(type) {
		case *Draw:
			d.c.Send(id, &Ack{Seq: m.Seq})
		case *Copied:
			return m
		}
	}
}

func TestEvents(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.ack(d.draw(5 * time.Second))
	p := h.pty(0)

	d.event(evText("ls\r"))
	eventually(t, "typed text reaching the child", func() bool { return p.inputString() == "ls\r" })

	p.emit("hello world")
	d.ack(d.draw(5 * time.Second))
	d.event(evGeometry(40, 10))
	d.event(evLeft(0, 1, 1))
	d.event(evLeft(2, 48, 1))
	d.event(evLeft(1, 48, 1))
	d.event(evCopy(3))
	if c := d.copied(); c.Tag != 3 || c.Text != "hello" {
		t.Errorf("copied tag %d %q, want hello", c.Tag, c.Text)
	}

	// Another client's events don't reach a pane it doesn't own.
	other := h.connect()
	other.Send(d.pane, &Event{Data: evText("nope")})
	other.Send(d.pane, &Event{Data: evCopy(4)})
	d.event(evText("!"))
	eventually(t, "the owner's input", func() bool { return strings.HasSuffix(p.inputString(), "!") })
	if strings.Contains(p.inputString(), "nope") {
		t.Error("a non-owner's event reached the child")
	}
}

// TestEventAutoscroll drags a selection above the pane and checks the
// daemon keeps scrolling it into history on its own, sending frames.
func TestEventAutoscroll(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.ack(d.draw(5 * time.Second))
	p := h.pty(0)
	for i := range 40 {
		p.emit(fmt.Sprintf("line %d\r\n", i))
	}
	eventually(t, "the output", func() bool { return strings.Contains(h.serverText(d.pane), "line 39") })
	d.ack(d.draw(5 * time.Second))

	d.event(evGeometry(40, 10))
	d.event(evLeft(0, 5, 100))
	d.event(evLeft(2, 5, -30))
	frames := 0
	for frames < 3 {
		f := d.draw(2 * time.Second)
		if f == nil {
			t.Fatalf("only %d frames while autoscrolling", frames)
		}
		d.ack(f)
		frames++
	}
	d.event(evLeft(1, 5, -30))
	d.event(evCopy(1))
	// The screen's top row was line 31; the selection reaches above it.
	if c := d.copied(); !strings.HasPrefix(c.Text, "line 30\n") && !strings.HasPrefix(c.Text, "line 2") {
		t.Errorf("autoscrolled selection copied %q", c.Text)
	}
}

// notice reads until the pane's next Notice, acking frames on the way.
func (d *drawer) notice() *Notice {
	d.t.Helper()
	d.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer d.conn.SetReadDeadline(time.Time{})
	for {
		id, m, err := d.c.Recv()
		if err != nil {
			d.t.Fatal(err)
		}
		switch m := m.(type) {
		case *Draw:
			d.c.Send(id, &Ack{Seq: m.Seq})
		case *Notice:
			if id == d.pane {
				return m
			}
		}
	}
}

func TestNotices(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	p := h.pty(0)
	cases := []struct {
		out  string
		want Notice
	}{
		{"\x1b]0;my title\x07", Notice{Kind: NoticeTitle, Text: "my title"}},
		{"\x1b]7;file://host/tmp\x07", Notice{Kind: NoticePwd, Text: "file://host/tmp"}},
		{"\x07", Notice{Kind: NoticeBell}},
		{"\x1b]52;c;aGk=\x07", Notice{Kind: NoticeClipboard, Text: "hi"}},
		{"\x1b]7501;state=working:progress=5\x07", Notice{Kind: NoticeStatus, Status: []StatusRecord{{State: 1, Progress: 5}}}},
	}
	for _, c := range cases {
		p.emit(c.out)
		got := d.notice()
		if got.Kind != c.want.Kind || got.Text != c.want.Text || fmt.Sprint(got.Status) != fmt.Sprint(c.want.Status) {
			t.Errorf("after %q: %+v, want %+v", c.out, *got, c.want)
		}
	}
}
