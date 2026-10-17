package daemon

import (
	"bytes"
	"compress/flate"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/vt"
)

// drawer is a client with one pane, reading its frames one at a time.
type drawer struct {
	t    *testing.T
	c    *Client
	conn net.Conn
	pane uint32
	// The image pieces that came before the frames read.
	images []*Image
}

// newDrawer connects a client, makes a workspace with one pane, and
// returns it having read the attach.
func newDrawer(t *testing.T, h *harness) *drawer {
	a, b := net.Pipe()
	go h.srv.handle(a)
	c, err := NewClientWith(b, Hello{FrameInterval: 1000})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	d := &drawer{t: t, c: c, conn: b}
	var ws rpc.Workspace
	if err := c.Call(rpc.WorkspaceNew, rpc.WorkspaceNewParams{Name: "test"}, &ws); err != nil {
		t.Fatal(err)
	}
	var created rpc.Created
	if err := c.Call(rpc.TabNew, rpc.TabNewParams{Workspace: ws.ID, Size: Size{Cols: 40, Rows: 10}}, &created); err != nil {
		t.Fatal(err)
	}
	d.pane = created.Pane
	if att := peekBacklog(c); att.Panes[d.pane] == nil {
		t.Fatal("no pane.attached for the new pane")
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
		if im, ok := m.(*Image); ok && id == d.pane {
			piece := *im
			piece.Data = append([]byte(nil), im.Data...)
			d.images = append(d.images, &piece)
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

// TestFramesImages checks that a kitty image placed in the pane comes
// before the frame that places it, deflated, and only once.
func TestFramesImages(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	first := d.draw(5 * time.Second)
	if first == nil {
		t.Fatal("no first frame")
	}
	d.ack(first)
	// Placements have a pixel size only once the cells do.
	d.c.Send(d.pane, &Resize{Size: Size{Cols: 40, Rows: 10, CellW: 10, CellH: 20}})
	rgb := []byte{255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255}
	h.pty(0).emit("\x1b_Gf=24,s=2,v=2,i=7,a=T;" + base64.StdEncoding.EncodeToString(rgb) + "\x1b\\")
	for i := 0; len(d.images) == 0 && i < 3; i++ {
		f := d.draw(5 * time.Second)
		if f == nil {
			t.Fatal("no frame after the image")
		}
		d.ack(f)
	}
	if len(d.images) != 1 {
		t.Fatalf("got %d image pieces, want 1", len(d.images))
	}
	im := d.images[0]
	if im.ID != 7 || im.Width != 2 || im.Height != 2 || im.Offset != 0 || im.Total != uint32(len(im.Data)) || im.Generation == 0 {
		t.Errorf("image piece %+v", im)
	}
	rgba, err := io.ReadAll(flate.NewReader(bytes.NewReader(im.Data)))
	if err != nil {
		t.Fatal(err)
	}
	want := []byte{255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255}
	if !bytes.Equal(rgba, want) {
		t.Errorf("image inflates to %v, want %v", rgba, want)
	}

	// More output places it still, but it isn't sent again.
	h.pty(0).emit("x")
	next := d.draw(5 * time.Second)
	if next == nil {
		t.Fatal("no frame after more output")
	}
	if len(d.images) != 1 {
		t.Errorf("the image was sent %d times", len(d.images))
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

// TestFramesAckCovers checks that an Ack covers the frames before it,
// as a client acks only the last frame it drew.
func TestFramesAckCovers(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	p := h.pty(0)
	d.draw(5 * time.Second)
	p.emit("a")
	second := d.draw(5 * time.Second)
	if second == nil {
		t.Fatal("no second frame")
	}
	d.ack(second)
	for i, s := range []string{"b", "c"} {
		p.emit(s)
		if f := d.draw(5 * time.Second); f == nil || f.Seq != uint32(3+i) {
			t.Fatalf("frame after acking the second: %+v, want seq %d", f, 3+i)
		}
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
	h.pty(0).emit("\x1b]0;its title\x07kept")
	d.draw(5 * time.Second)
	ws := h.list().Workspaces[0].ID

	a, b := net.Pipe()
	go h.srv.handle(a)
	c, err := NewClient(b)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	if err := c.Call(rpc.WorkspaceAttach, rpc.WorkspaceAttachParams{ID: ws}, nil); err != nil {
		t.Fatal(err)
	}
	att := peekBacklog(c)
	// The title it set before, which the new client has no other way to
	// learn.
	if ns := att.Panes[d.pane].Notices; len(ns) != 1 || ns[0].Kind != NoticeTitle || ns[0].Text != "its title" {
		t.Errorf("notices at attach %+v, want the title", ns)
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

// Events, as internal/vt/event.zig lays them out; vt's tests cover
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
	eventually(t, "the viewer's input", func() bool { return strings.HasSuffix(p.inputString(), "!") })
	if strings.Contains(p.inputString(), "nope") {
		t.Error("a non-viewer's event reached the child")
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

// TestFramesReplyOutsideLock checks that a query's reply is written to
// the child outside the pane's lock: a child that stops reading its
// input while asking must not stall the pane for everyone else.
func TestFramesReplyOutsideLock(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.ack(d.draw(5 * time.Second))
	p := h.pty(0)
	release := p.blockWrites()
	defer release()
	p.emit("\x1b[c")
	select {
	case <-p.writing:
	case <-time.After(5 * time.Second):
		t.Fatal("the DA1 reply was never written")
	}
	// The reply waits on the child. The pane must still answer a lock
	// holder meanwhile.
	pane := h.srv.pane(d.pane)
	done := make(chan struct{})
	go func() {
		pane.desc(nil)
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("the pane's lock is held while the reply waits on the child")
	}
}

// evMotion is mouse motion with no button held.
func evMotion(x, y float32) []byte {
	b := []byte{5, 2, 0, 0, 0, 0}
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(x))
	b = binary.LittleEndian.AppendUint32(b, math.Float32bits(y))
	return binary.LittleEndian.AppendUint32(b, 0)
}

// attachDrawer connects a second client and attaches ws, beside any
// client attached before.
func attachDrawer(t *testing.T, h *harness, ws, pane uint32) *drawer {
	t.Helper()
	a, b := net.Pipe()
	go h.srv.handle(a)
	c, err := NewClient(b)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	if err := c.Call(rpc.WorkspaceAttach, rpc.WorkspaceAttachParams{ID: ws}, nil); err != nil {
		t.Fatal(err)
	}
	return &drawer{t: t, c: c, conn: b, pane: pane}
}

// TestFramesReattachDropsDrag checks that a client lost in the middle of
// a selection drag doesn't leave the next one selecting: its motion goes
// to a program that asks for it.
func TestFramesReattachDropsDrag(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.ack(d.draw(5 * time.Second))
	p := h.pty(0)
	p.emit("hello world")
	d.ack(d.draw(5 * time.Second))
	d.event(evGeometry(40, 10))
	d.event(evLeft(0, 15, 25))
	d.event(evLeft(2, 85, 25))
	// The drag's frame says the events are in.
	if f := d.draw(5 * time.Second); f == nil {
		t.Fatal("no frame for the drag")
	}
	ws := h.list().Workspaces[0].ID
	d.c.Close()
	eventually(t, "detach", func() bool { return !h.attached(ws) })

	d2 := attachDrawer(t, h, ws, d.pane)
	d2.ack(d2.draw(5 * time.Second))
	d2.event(evGeometry(40, 10))
	p.emit("\x1b[?1003h\x1b[?1006h")
	d2.ack(d2.draw(5 * time.Second))
	d2.event(evMotion(25, 45))
	eventually(t, "the motion report", func() bool { return strings.Contains(p.inputString(), "\x1b[<35;3;3M") })
}

// noticeOf reads until a notice of kind for the pane, acking frames on
// the way, or returns nil if none comes within wait.
func (d *drawer) noticeOf(kind NoticeKind, wait time.Duration) *Notice {
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
		switch m := m.(type) {
		case *Draw:
			d.c.Send(id, &Ack{Seq: m.Seq})
		case *Notice:
			if id == d.pane && m.Kind == kind {
				return m
			}
		}
	}
}

// TestNoticeDroppedResent checks that a status notice the client's
// backlog dropped comes once the client catches up: it's the whole
// state, so the sidebar would otherwise stay stale until the next
// change.
func TestNoticeDroppedResent(t *testing.T) {
	h := newHarness(t)
	d := newDrawer(t, h)
	d.ack(d.draw(5 * time.Second))
	p := h.pty(0)
	pane := h.srv.pane(d.pane)
	pane.mu.Lock()
	var c *conn
	for c = range pane.fr.viewers {
	}
	pane.mu.Unlock()

	// The client is as far behind as it may be.
	c.mu.Lock()
	c.queued = MaxQueued
	c.mu.Unlock()
	p.emit("\x1b]7501;state=working\x07")
	if n := d.noticeOf(NoticeStatus, 200*time.Millisecond); n != nil {
		t.Fatalf("a status notice got through a full backlog: %+v", n)
	}

	// It caught up, and acks the next frame.
	c.mu.Lock()
	c.queued = 0
	c.mu.Unlock()
	p.emit("x")
	n := d.noticeOf(NoticeStatus, 5*time.Second)
	if n == nil || len(n.Status) != 1 || n.Status[0].State != uint8(vt.StatusWorking) {
		t.Fatalf("status after catching up %+v, want working", n)
	}
}
