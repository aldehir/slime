package persist

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aldehir/slime/ssh/internal/pty"
	"github.com/aldehir/slime/ssh/internal/vt"
)

var (
	rtOnce sync.Once
	rt     *vt.Runtime
	rtErr  error
)

func runtime(t testing.TB) *vt.Runtime {
	t.Helper()
	rtOnce.Do(func() { rt, rtErr = vt.NewRuntime(context.Background(), nil) })
	if rtErr != nil {
		t.Fatal(rtErr)
	}
	return rt
}

// fakePty is a child the test plays: emit is its output, and what the
// session writes to it collects in input.
type fakePty struct {
	out     chan []byte
	pending []byte

	mu    sync.Mutex
	input bytes.Buffer
	size  [2]uint16

	exitOnce sync.Once
	exited   chan struct{}
	status   uint32
}

func newFakePty(opts pty.Options) *fakePty {
	return &fakePty{
		out:    make(chan []byte, 1024),
		exited: make(chan struct{}),
		size:   [2]uint16{opts.Cols, opts.Rows},
	}
}

func (p *fakePty) emit(s string) { p.out <- []byte(s) }

func (p *fakePty) exit(status uint32) {
	p.exitOnce.Do(func() {
		p.status = status
		close(p.out)
		close(p.exited)
	})
}

func (p *fakePty) Read(b []byte) (int, error) {
	if len(p.pending) == 0 {
		chunk, ok := <-p.out
		if !ok {
			return 0, io.EOF
		}
		p.pending = chunk
	}
	n := copy(b, p.pending)
	p.pending = p.pending[n:]
	return n, nil
}

func (p *fakePty) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.input.Write(b)
}

func (p *fakePty) Resize(cols, rows uint16) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.size = [2]uint16{cols, rows}
	return nil
}

func (p *fakePty) Wait() (uint32, error) {
	<-p.exited
	return p.status, nil
}

func (p *fakePty) PID() uint32  { return 4242 }
func (p *fakePty) Close() error { p.exit(1); return nil }

func (p *fakePty) inputString() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.input.String()
}

// harness is a server whose children are fake ptys, reachable over
// in-memory connections.
type harness struct {
	t    *testing.T
	srv  *Server
	mu   sync.Mutex
	ptys []*fakePty
}

func newHarness(t *testing.T) *harness {
	h := &harness{t: t}
	srv, err := NewServer(runtime(t), Options{Spawn: func(o pty.Options) (pty.Pty, error) {
		p := newFakePty(o)
		h.mu.Lock()
		h.ptys = append(h.ptys, p)
		h.mu.Unlock()
		return p, nil
	}})
	if err != nil {
		t.Fatal(err)
	}
	h.srv = srv
	t.Cleanup(srv.Close)
	return h
}

func (h *harness) pty(i int) *fakePty {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.ptys[i]
}

func (h *harness) connect() *Client {
	a, b := net.Pipe()
	go h.srv.handle(a)
	c, err := NewClient(b)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { c.Close() })
	return c
}

// view is a client's copy of a session's terminal.
type view struct {
	t    *testing.T
	c    *Client
	id   uint32
	term *vt.Terminal
	att  Attached
}

func (h *harness) view(c *Client) *view {
	h.t.Helper()
	a, err := c.ReadAttach()
	if err != nil {
		h.t.Fatal(err)
	}
	term, err := runtime(h.t).Decode(a.Snapshot)
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { term.Close() })
	return &view{t: h.t, c: c, id: a.ID, term: term, att: a.Attached}
}

func (h *harness) newSession(c *Client) *view {
	h.t.Helper()
	if err := c.Send(0, &New{Tag: 7, Size: Size{Cols: 40, Rows: 10}}); err != nil {
		h.t.Fatal(err)
	}
	v := h.view(c)
	if v.att.Tag != 7 {
		h.t.Errorf("tag %d, want 7", v.att.Tag)
	}
	return v
}

func (h *harness) attach(c *Client, id uint32) *view {
	h.t.Helper()
	if err := c.Send(id, &Attach{Tag: 9}); err != nil {
		h.t.Fatal(err)
	}
	return h.view(c)
}

// until applies output to the view until its text contains want, and
// returns the other messages it read on the way.
func (v *view) until(want string) []Message {
	v.t.Helper()
	var others []Message
	deadline := time.Now().Add(10 * time.Second)
	for {
		if s, _ := v.term.Text(); strings.Contains(s, want) {
			return others
		}
		if time.Now().After(deadline) {
			s, _ := v.term.Text()
			v.t.Fatalf("never saw %q; text %q", want, s)
		}
		id, m, err := v.c.Recv()
		if err != nil {
			v.t.Fatalf("waiting for %q: %v", want, err)
		}
		if out, ok := m.(*Output); ok && id == v.id {
			v.term.Write(out.Data)
		} else {
			others = append(others, m)
		}
	}
}

func (v *view) text() string {
	s, _ := v.term.Text()
	return s
}

// serverText is the daemon's own copy of a session's screen.
func (h *harness) serverText(id uint32) string {
	ss := h.srv.session(id)
	ss.mu.Lock()
	defer ss.mu.Unlock()
	s, _ := ss.term.Text()
	return s
}

func eventually(t *testing.T, what string, f func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !f() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestWireRoundTrip(t *testing.T) {
	msgs := []Message{
		&Hello{Version: 3},
		&List{},
		&New{Tag: 1, Command: "cmd.exe /k", Cwd: `C:\src`, Size: Size{80, 24, 9, 18}},
		&Attach{Tag: 2, Size: Size{100, 40, 0, 0}},
		&Detach{},
		&Input{Data: []byte("ls\r")},
		&Resize{Size: Size{1, 2, 3, 4}},
		&Kill{},
		&HelloReply{Version: 1, SnapshotVersion: 2, PID: 99},
		&Sessions{Sessions: []SessionInfo{{ID: 1, Command: "c", Title: "t", Pwd: "p", Cols: 80, Rows: 24, Attached: true, Created: 1700000000000, PID: 5}, {ID: 2}}},
		&Attached{Tag: 3, SnapshotLen: 1234, Modes: []Mode{{9001, false, true}, {4, true, false}}},
		&Snapshot{Data: []byte("GHOSTSNP")},
		&Output{Data: []byte("\x1b[31mred")},
		&Detached{Reason: "too slow"},
		&Exit{Status: 0xc000013a},
		&Error{Tag: 4, Message: "no such session"},
	}
	var stream bytes.Buffer
	for i, m := range msgs {
		b, err := Encode(uint32(i), m)
		if err != nil {
			t.Fatal(err)
		}
		stream.Write(b)
	}
	r := NewReader(&stream)
	for i, want := range msgs {
		f, err := r.Read()
		if err != nil {
			t.Fatal(err)
		}
		got, err := Decode(f)
		if err != nil {
			t.Fatal(err)
		}
		if f.ID != uint32(i) || !reflect.DeepEqual(normalize(got), normalize(want)) {
			t.Errorf("frame %d: %#v, want %#v", i, got, want)
		}
	}
	if _, err := r.Read(); err != io.EOF {
		t.Errorf("after the last frame: %v", err)
	}
}

// normalize treats nil and empty slices alike.
func normalize(m Message) Message {
	switch m := m.(type) {
	case *Sessions:
		if len(m.Sessions) == 0 {
			m.Sessions = nil
		}
	case *Attached:
		if len(m.Modes) == 0 {
			m.Modes = nil
		}
	}
	return m
}

func TestWireBadFrames(t *testing.T) {
	big := []byte{0xff, 0xff, 0xff, 0x7f}
	if _, err := NewReader(bytes.NewReader(big)).Read(); err != ErrTooLarge {
		t.Errorf("oversized: %v", err)
	}
	short := []byte{2, 0, 0, 0, 1, 0}
	if _, err := NewReader(bytes.NewReader(short)).Read(); err != ErrShortFrame {
		t.Errorf("short: %v", err)
	}
	b, _ := Encode(1, &Detached{Reason: "gone"})
	if _, err := NewReader(bytes.NewReader(b[:len(b)-2])).Read(); err != io.ErrUnexpectedEOF {
		t.Errorf("cut off: %v", err)
	}
	f := Frame{Type: TypeNew, Payload: []byte{1, 0, 0, 0, 0xff, 0, 0, 0}}
	if _, err := Decode(f); err == nil {
		t.Error("truncated string decoded")
	}
}

func TestVersionMismatch(t *testing.T) {
	h := newHarness(t)
	a, b := net.Pipe()
	go h.srv.handle(a)
	c := &Client{rw: b, r: NewReader(b)}
	c.Send(0, &Hello{Version: Version + 1})
	_, m, err := c.Recv()
	if _, ok := m.(*HelloReply); err != nil || !ok {
		t.Fatalf("got %#v, %v", m, err)
	}
	_, m, _ = c.Recv()
	if e, ok := m.(*Error); !ok || !strings.Contains(e.Message, "version") {
		t.Errorf("got %#v", m)
	}
	if _, _, err := c.Recv(); err == nil {
		t.Error("connection still open")
	}
}

// TestDetachReattach: output while detached lands in the snapshot, and
// output after attaching continues it.
func TestDetachReattach(t *testing.T) {
	h := newHarness(t)
	c1 := h.connect()
	v := h.newSession(c1)
	p := h.pty(0)
	p.emit("one\r\n")
	v.until("one")
	c1.Send(v.id, &Detach{})
	eventually(t, "detach", func() bool { return !h.srv.session(v.id).info().Attached })
	p.emit("two\r\n")
	eventually(t, "detached output", func() bool { return strings.Contains(h.serverText(v.id), "two") })

	c2 := h.connect()
	sessions, err := c2.List()
	if err != nil || len(sessions) != 1 || sessions[0].Attached || sessions[0].PID != 4242 {
		t.Fatalf("list %+v, %v", sessions, err)
	}
	v2 := h.attach(c2, v.id)
	if s := v2.text(); s != "one\ntwo" {
		t.Errorf("snapshot text %q", s)
	}
	p.emit("three")
	v2.until("three")
	if s := v2.text(); s != "one\ntwo\nthree" {
		t.Errorf("text %q", s)
	}
}

// TestAttachSeam attaches while output streams, then checks the client's
// terminal matches the daemon's: nothing lost or doubled at the seam.
func TestAttachSeam(t *testing.T) {
	h := newHarness(t)
	c1 := h.connect()
	v := h.newSession(c1)
	c1.Send(v.id, &Detach{})
	p := h.pty(0)

	done := make(chan struct{})
	go func() {
		defer close(done)
		for i := range 3000 {
			// Split escape sequences across writes too.
			p.emit(fmt.Sprintf("\x1b[3%dmline %d\x1b", i%8, i))
			p.emit("[0m\r\n")
		}
		p.emit("END")
	}()
	time.Sleep(time.Millisecond)
	c2 := h.connect()
	v2 := h.attach(c2, v.id)
	<-done
	v2.until("END")
	// Each terminal drops old scrollback a page at a time, and the
	// client's pages were laid out by the decoder, so the oldest lines
	// can differ. Everything both still hold must match.
	got, want := v2.text(), h.serverText(v.id)
	short, long := got, want
	if len(short) > len(long) {
		short, long = long, short
	}
	if !strings.HasSuffix(long, short) {
		t.Fatalf("client and daemon differ:\nclient ends %q\ndaemon ends %q",
			got[max(0, len(got)-200):], want[max(0, len(want)-200):])
	}
	if n := strings.Count(short, "\n"); n < 1000 {
		t.Errorf("only %d lines in common", n)
	}
}

func TestRepliesWhileDetached(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	v := h.newSession(c)
	p := h.pty(0)

	// Attached: the client answers, so the daemon doesn't.
	p.emit("\x1b[c")
	p.emit("mark1")
	v.until("mark1")
	if s := p.inputString(); s != "" {
		t.Errorf("daemon answered while attached: %q", s)
	}

	c.Send(v.id, &Detach{})
	eventually(t, "detach", func() bool { return !h.srv.session(v.id).info().Attached })
	p.emit("\x1b[c")
	eventually(t, "DA1 reply", func() bool { return p.inputString() == "\x1b[?62;22c" })
}

func TestSteal(t *testing.T) {
	h := newHarness(t)
	c1 := h.connect()
	v1 := h.newSession(c1)
	c2 := h.connect()
	v2 := h.attach(c2, v1.id)
	p := h.pty(0)

	_, m, err := c1.Recv()
	if d, ok := m.(*Detached); err != nil || !ok || d.Reason != "attached elsewhere" {
		t.Fatalf("first client got %#v, %v", m, err)
	}
	c1.Send(v1.id, &Input{Data: []byte("from-1")})
	c2.Send(v2.id, &Input{Data: []byte("from-2")})
	eventually(t, "input", func() bool { return p.inputString() != "" })
	time.Sleep(20 * time.Millisecond)
	if s := p.inputString(); s != "from-2" {
		t.Errorf("input %q, want only the attached client's", s)
	}
}

func TestResize(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	v := h.newSession(c)
	p := h.pty(0)
	c.Send(v.id, &Resize{Size: Size{Cols: 120, Rows: 50}})
	eventually(t, "resize", func() bool {
		p.mu.Lock()
		defer p.mu.Unlock()
		return p.size == [2]uint16{120, 50}
	})
	if info := h.srv.session(v.id).info(); info.Cols != 120 || info.Rows != 50 {
		t.Errorf("info %dx%d", info.Cols, info.Rows)
	}
	// Attaching with a size resizes too.
	c2 := h.connect()
	c2.Send(v.id, &Attach{Size: Size{Cols: 90, Rows: 30}})
	v2 := h.view(c2)
	if cols, rows, _ := v2.term.Size(); cols != 90 || rows != 30 {
		t.Errorf("snapshot size %dx%d", cols, rows)
	}
}

func TestExit(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	v := h.newSession(c)
	h.pty(0).exit(5)
	for {
		id, m, err := c.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if e, ok := m.(*Exit); ok {
			if id != v.id || e.Status != 5 {
				t.Errorf("exit %d on %d", e.Status, id)
			}
			break
		}
	}
	eventually(t, "removal", func() bool { return h.srv.session(v.id) == nil })
	c2 := h.connect()
	c2.Send(v.id, &Attach{Tag: 3})
	if _, err := c2.ReadAttach(); err == nil || !strings.Contains(err.Error(), "no such session") {
		t.Errorf("attach to an ended session: %v", err)
	}
}

func TestKill(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	v := h.newSession(c)
	c.Send(v.id, &Kill{})
	eventually(t, "removal", func() bool { return h.srv.session(v.id) == nil })
}

func TestModesInAttach(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	v := h.newSession(c)
	h.pty(0).emit("\x1b[?9001h\x1b[?1004hmark")
	v.until("mark")
	c2 := h.connect()
	v2 := h.attach(c2, v.id)
	want := []Mode{{Mode: 9001, Enabled: true}}
	if !reflect.DeepEqual(v2.att.Modes, want) {
		t.Errorf("modes %+v, want %+v", v2.att.Modes, want)
	}
}

// TestSlowClient never reads, so its queue fills and it loses the
// session; it finds out once it does read.
func TestSlowClient(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	v := h.newSession(c)
	p := h.pty(0)
	chunk := strings.Repeat("x", 32<<10)
	go func() {
		for range MaxQueued/len(chunk) + 64 {
			p.emit(chunk)
		}
	}()
	eventually(t, "drop", func() bool { return !h.srv.session(v.id).info().Attached })
	for {
		_, m, err := c.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if d, ok := m.(*Detached); ok {
			if d.Reason != "too slow" {
				t.Errorf("reason %q", d.Reason)
			}
			break
		}
	}
}

func TestDisconnectDetaches(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	v := h.newSession(c)
	c.Close()
	eventually(t, "detach", func() bool { return !h.srv.session(v.id).info().Attached })
}

func TestIdleExit(t *testing.T) {
	srv, err := NewServer(runtime(t), Options{
		Spawn: func(o pty.Options) (pty.Pty, error) { return newFakePty(o), nil },
		Idle:  50 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error)
	go func() { done <- srv.Serve(l) }()

	conn, err := net.Dial("tcp", l.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	c, err := NewClient(conn)
	if err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
		t.Fatal("exited with a client connected")
	case <-time.After(150 * time.Millisecond):
	}
	c.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Serve: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("didn't exit when idle")
	}
}
