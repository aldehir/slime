package daemon

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/vt"
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
// pane writes to it collects in input.
type fakePty struct {
	out     chan []byte
	pending []byte

	mu    sync.Mutex
	input bytes.Buffer
	size  [2]uint16
	// Set by blockWrites: Write waits on block, saying so on writing.
	block   chan struct{}
	writing chan struct{}

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

// emit is the child's output. After the child exits it goes nowhere.
func (p *fakePty) emit(s string) {
	select {
	case p.out <- []byte(s):
	case <-p.exited:
	}
}

func (p *fakePty) exit(status uint32) {
	p.exitOnce.Do(func() {
		p.status = status
		close(p.exited)
	})
}

// Read returns output until the child has exited and what it wrote
// before is read.
func (p *fakePty) Read(b []byte) (int, error) {
	if len(p.pending) == 0 {
		select {
		case p.pending = <-p.out:
		case <-p.exited:
			select {
			case p.pending = <-p.out:
			default:
				return 0, io.EOF
			}
		}
	}
	n := copy(b, p.pending)
	p.pending = p.pending[n:]
	return n, nil
}

func (p *fakePty) Write(b []byte) (int, error) {
	p.mu.Lock()
	block, writing := p.block, p.writing
	p.mu.Unlock()
	if block != nil {
		select {
		case writing <- struct{}{}:
		default:
		}
		<-block
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.input.Write(b)
}

// blockWrites makes Write wait, as a full input pipe does, until the
// returned func releases it; writing takes a token when one waits.
func (p *fakePty) blockWrites() (release func()) {
	p.mu.Lock()
	defer p.mu.Unlock()
	block := make(chan struct{})
	p.block = block
	p.writing = make(chan struct{}, 1)
	var once sync.Once
	return func() { once.Do(func() { close(block) }) }
}

func (p *fakePty) Resize(cols, rows uint16, _, _ uint32) error {
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

func (p *fakePty) getSize() [2]uint16 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.size
}

// harness is a server whose children are fake ptys, in the order they
// were spawned, reachable over in-memory connections.
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

// window is a client playing the GUI: it owns workspaces and mirrors their
// panes' screens from the frames it's sent, acking each.
type window struct {
	t       *testing.T
	h       *harness
	c       *Client
	ws      *rpc.Workspace
	screens map[uint32]*vt.Screen
}

func (h *harness) window() *window {
	return &window{t: h.t, h: h, c: h.connect(), screens: map[uint32]*vt.Screen{}}
}

// PaneState is a pane as attaching delivered it, with the frames and
// notices that followed before the reply came.
type PaneState struct {
	Attached rpc.PaneAttachedParams
	Draws    []*Draw
	Notices  []*Notice
}

// Attachment collects what attaching (or a request that adds a pane to
// an attached workspace) delivered before its reply.
type Attachment struct {
	Workspace *rpc.Workspace
	Panes     map[uint32]*PaneState
}

// collect takes what c set aside before the last reply: the panes that
// attached, with their frames and notices, and the latest structure.
func collect(c *Client) *Attachment {
	a := peekBacklog(c)
	c.backlog = nil
	return a
}

// peekBacklog reads what c set aside as collect does, leaving it for
// Recv: a reply can follow the first frames of the pane it made.
func peekBacklog(c *Client) *Attachment {
	a := &Attachment{Panes: map[uint32]*PaneState{}}
	for _, p := range c.backlog {
		switch m := p.m.(type) {
		case *Draw:
			if ps := a.Panes[p.id]; ps != nil {
				ps.Draws = append(ps.Draws, &Draw{Seq: m.Seq, Data: append([]byte(nil), m.Data...)})
			}
		case *Notice:
			if ps := a.Panes[p.id]; ps != nil {
				ps.Notices = append(ps.Notices, m)
			}
		case *Notify:
			switch m.Notification.Method {
			case rpc.EvPaneAttached:
				var at rpc.PaneAttachedParams
				json.Unmarshal(m.Notification.Params, &at)
				a.Panes[at.ID] = &PaneState{Attached: at}
			case rpc.EvWorkspaceChanged:
				var ws rpc.Workspace
				json.Unmarshal(m.Notification.Params, &ws)
				a.Workspace = &ws
			}
		}
	}
	return a
}

// call makes the call and returns what came before its reply.
func (w *window) call(method string, params, result any) (*Attachment, error) {
	err := w.c.Call(method, params, result)
	return collect(w.c), err
}

// absorb takes in what an attach or a new pane delivered.
func (w *window) absorb(a *Attachment) {
	w.t.Helper()
	if a.Workspace != nil {
		w.ws = a.Workspace
	}
	for id, p := range a.Panes {
		s, err := vt.NewScreen()
		if err != nil {
			w.t.Fatal(err)
		}
		w.t.Cleanup(s.Close)
		w.screens[id] = s
		for _, d := range p.Draws {
			w.draw(id, d)
		}
	}
}

// draw applies a pane's frame to its screen and acks it.
func (w *window) draw(id uint32, d *Draw) {
	w.t.Helper()
	if s := w.screens[id]; s != nil {
		if err := s.Apply(d.Data); err != nil {
			w.t.Fatal(err)
		}
	}
	w.c.Send(id, &Ack{Seq: d.Seq})
}

// newWorkspace creates a workspace with one tab, and returns its pane.
func (w *window) newWorkspace() uint32 {
	w.t.Helper()
	var ws rpc.Workspace
	if _, err := w.call(rpc.WorkspaceNew, rpc.WorkspaceNewParams{Name: "test"}, &ws); err != nil {
		w.t.Fatal(err)
	}
	w.ws = &ws
	return w.newTab()
}

func (w *window) newTab() uint32 {
	w.t.Helper()
	var created rpc.Created
	a, err := w.call(rpc.TabNew, rpc.TabNewParams{Workspace: w.ws.ID, Size: Size{Cols: 40, Rows: 10}}, &created)
	if err != nil {
		w.t.Fatal(err)
	}
	w.absorb(a)
	return created.Pane
}

// split starts a pane beside pane and returns what came with it.
func (w *window) split(pane uint32, dir Direction, share uint16, command string) (*Attachment, rpc.Created) {
	w.t.Helper()
	var created rpc.Created
	a, err := w.call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: pane, Direction: dir, Share: share, Command: command}, &created)
	if err != nil {
		w.t.Fatal(err)
	}
	return a, created
}

func (w *window) attach(ws uint32, area Area) {
	w.t.Helper()
	var s rpc.Workspace
	a, err := w.call(rpc.WorkspaceAttach, rpc.WorkspaceAttachParams{ID: ws, Area: area}, &s)
	if err != nil {
		w.t.Fatal(err)
	}
	a.Workspace = &s
	w.absorb(a)
}

func (w *window) detach() {
	w.t.Helper()
	if err := w.c.Call(rpc.WorkspaceDetach, rpc.WorkspaceParams{ID: w.ws.ID}, nil); err != nil {
		w.t.Fatal(err)
	}
}

// until applies frames to the window's screens until pane's shows want,
// and returns the other messages it read on the way.
func (w *window) until(pane uint32, want string) []Message {
	w.t.Helper()
	var others []Message
	deadline := time.Now().Add(10 * time.Second)
	for {
		if s := w.text(pane); strings.Contains(s, want) {
			return others
		}
		if time.Now().After(deadline) {
			w.t.Fatalf("pane %d never showed %q; text %q", pane, want, w.text(pane))
		}
		id, m, err := w.c.Recv()
		if err != nil {
			w.t.Fatalf("waiting for %q: %v", want, err)
		}
		if d, ok := m.(*Draw); ok {
			w.draw(id, d)
		} else {
			others = append(others, m)
		}
	}
}

// nextEvent reads until the notification name, applying frames and
// structures on the way, and returns its params.
func nextEvent[P any](w *window, name string) P {
	w.t.Helper()
	var p P
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		id, m, err := w.c.Recv()
		if err != nil {
			w.t.Fatal(err)
		}
		if d, ok := m.(*Draw); ok {
			w.draw(id, d)
			continue
		}
		got, params, ok := Notification(m)
		if !ok {
			continue
		}
		if got == rpc.EvWorkspaceChanged {
			var ws rpc.Workspace
			json.Unmarshal(params, &ws)
			w.ws = &ws
		}
		if got == name {
			if err := json.Unmarshal(params, &p); err != nil {
				w.t.Fatalf("%s params %s: %v", name, params, err)
			}
			return p
		}
	}
	w.t.Fatalf("no %s", name)
	return p
}

// text is the pane's screen as the window has drawn it: the viewport,
// not the scrollback.
func (w *window) text(pane uint32) string {
	if w.screens[pane] == nil {
		return ""
	}
	s, _ := w.screens[pane].Text()
	return s
}

// serverText is the daemon's own copy of a pane's screen.
func (h *harness) serverText(id uint32) string {
	p := h.srv.pane(id)
	p.mu.Lock()
	defer p.mu.Unlock()
	s, _ := p.term.Text()
	return s
}

func (h *harness) list() *rpc.WorkspaceListResult {
	h.t.Helper()
	var l rpc.WorkspaceListResult
	if err := h.connect().Call(rpc.WorkspaceList, nil, &l); err != nil {
		h.t.Fatal(err)
	}
	return &l
}

func (h *harness) attached(ws uint32) bool {
	h.srv.mu.Lock()
	defer h.srv.mu.Unlock()
	w := h.srv.workspaces[ws]
	return w != nil && w.owner != nil
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
		&Hello{Version: 3, FrameInterval: 16667},
		&Call{Request: rpc.Request{JSONRPC: "2.0", ID: 7, Method: "tab.new", Params: json.RawMessage(`{"workspace":9,"command":"cmd.exe /k"}`)}},
		&Ack{Seq: 4},
		&Event{Data: []byte{1, 2, 3}},
		&Resize{Size: Size{1, 2, 3, 4}},
		&Bridge{Term: "xterm-ghostty"},
		&HelloReply{Version: 1, PID: 99, FrameLayout: 1 << 63},
		&Reply{Response: rpc.Response{JSONRPC: "2.0", ID: 7, Result: json.RawMessage(`{"workspace":9,"tab":2,"pane":3}`)}},
		&Reply{Response: rpc.Response{JSONRPC: "2.0", ID: 8, Error: &rpc.Error{Code: rpc.CodeNotFound, Message: "no such pane"}}},
		&Notify{Notification: rpc.Notification{JSONRPC: "2.0", Method: "pane.exited", Params: json.RawMessage(`{"id":3,"status":3221225786}`)}},
		&Error{Message: "no such host"},
		&Draw{Seq: 4, Data: []byte{1, 2, 3}},
		&Image{ID: 7, Generation: 1 << 40, Width: 2, Height: 3, Total: 10, Offset: 4, Data: []byte{9, 8, 7}},
		&Copied{Tag: 5, Text: "sel"},
		&Notice{Kind: NoticeStatus, Text: "", Status: []StatusRecord{{"", 1, 40}, {"deploy/eu", 3, -1}}},
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
		if f.ID != uint32(i) || !reflect.DeepEqual(got, want) {
			t.Errorf("frame %d: %#v, want %#v", i, got, want)
		}
	}
	if _, err := r.Read(); err != io.EOF {
		t.Errorf("after the last frame: %v", err)
	}
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
	b, _ := Encode(1, &Error{Message: "gone"})
	if _, err := NewReader(bytes.NewReader(b[:len(b)-2])).Read(); err != io.ErrUnexpectedEOF {
		t.Errorf("cut off: %v", err)
	}
	f := Frame{Type: TypeBridge, Payload: []byte{0xff, 0, 0, 0, 'x'}}
	if _, err := Decode(f); err == nil {
		t.Error("truncated string decoded")
	}
	f = Frame{Type: TypeCall, Payload: []byte(`{"jsonrpc":`)}
	if _, err := Decode(f); !errors.Is(err, ErrBadJSON) {
		t.Errorf("bad JSON call: %v", err)
	}
}

// A call the daemon can't parse, or doesn't know, gets an error and the
// connection stays up.
func TestBadCalls(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	c.Send(0, &Call{Request: rpc.Request{JSONRPC: "2.0", ID: 1, Method: "no.such"}})
	_, m, err := c.Recv()
	if err != nil {
		t.Fatal(err)
	}
	if r, ok := m.(*Reply); !ok || r.Response.ID != 1 || r.Response.Error == nil || r.Response.Error.Code != rpc.CodeMethodNotFound {
		t.Errorf("unknown method got %#v", m)
	}
	c.Send(0, &Call{Request: rpc.Request{JSONRPC: "2.0", ID: 2, Method: rpc.TabNew, Params: json.RawMessage(`{"workspace":"nine"}`)}})
	_, m, _ = c.Recv()
	if r, ok := m.(*Reply); !ok || r.Response.Error == nil || r.Response.Error.Code != rpc.CodeInvalidParams {
		t.Errorf("bad params got %#v", m)
	}
	// Unparseable JSON is dropped; the next call still works.
	b, _ := Encode(0, &Bridge{Term: `{"jsonrpc":`})
	b[4] = byte(TypeCall)
	c.rw.Write(b)
	if err := c.Call(rpc.WorkspaceList, nil, nil); err != nil {
		t.Errorf("after bad JSON: %v", err)
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

// TestDetachReattach: output while detached lands in the daemon's
// terminal, which attaching again shows whole, and output after that
// continues it.
func TestDetachReattach(t *testing.T) {
	h := newHarness(t)
	w1 := h.window()
	pane := w1.newWorkspace()
	ws := w1.ws.ID
	p := h.pty(0)
	p.emit("one\r\n")
	w1.until(pane, "one")
	w1.detach()
	if h.attached(ws) {
		t.Fatal("attached after the detach replied")
	}
	p.emit("two\r\n")
	eventually(t, "detached output", func() bool { return strings.Contains(h.serverText(pane), "two") })

	l := h.list()
	if len(l.Workspaces) != 1 || l.Workspaces[0].Attached || l.Workspaces[0].DetachedAt == 0 {
		t.Fatalf("list %+v", l.Workspaces)
	}
	if len(l.Panes) != 1 || l.Panes[0].ID != pane || l.Panes[0].PID != 4242 || l.Panes[0].Workspace != ws {
		t.Fatalf("panes %+v", l.Panes)
	}
	w2 := h.window()
	w2.attach(ws, Area{})
	w2.until(pane, "two")
	if s := w2.text(pane); s != "one\ntwo" {
		t.Errorf("text after reattaching %q", s)
	}
	p.emit("three")
	w2.until(pane, "three")
	if s := w2.text(pane); s != "one\ntwo\nthree" {
		t.Errorf("text %q", s)
	}
}

func TestMostRecentDetached(t *testing.T) {
	h := newHarness(t)
	var ids []uint32
	for range 3 {
		w := h.window()
		w.newWorkspace()
		ids = append(ids, w.ws.ID)
		w.c.Close()
		eventually(t, "detach", func() bool { return !h.attached(w.ws.ID) })
		time.Sleep(2 * time.Millisecond)
	}
	if got := MostRecentDetached(h.list()); got == nil || got.ID != ids[2] {
		t.Errorf("most recent %+v, want workspace %d", got, ids[2])
	}
	// Attach that one: the next most recent is the one before it.
	w := h.window()
	w.attach(ids[2], Area{})
	if got := MostRecentDetached(h.list()); got == nil || got.ID != ids[1] {
		t.Errorf("then %+v, want workspace %d", got, ids[1])
	}
}

// TestAttachSeam attaches while output streams, then checks the client's
// screen matches the daemon's: the partial frames after the full one
// carry every change since it, nothing lost or doubled at the seam.
func TestAttachSeam(t *testing.T) {
	h := newHarness(t)
	w1 := h.window()
	pane := w1.newWorkspace()
	ws := w1.ws.ID
	w1.detach()
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
	w2 := h.window()
	w2.attach(ws, Area{})
	<-done
	w2.until(pane, "END")
	// The client has the viewport; the daemon's text has the scrollback
	// before it.
	got, want := w2.text(pane), h.serverText(pane)
	if !strings.HasSuffix(want, got) {
		t.Fatalf("client and daemon differ:\nclient ends %q\ndaemon ends %q",
			got[max(0, len(got)-200):], want[max(0, len(want)-200):])
	}
	if n := strings.Count(got, "\n"); n != 9 {
		t.Errorf("client shows %d lines, want the 10-row viewport", n+1)
	}
}

// TestRepliesWhileDetached: the daemon's terminal answers the program's
// queries attached or not, the client having no terminal of its own.
func TestRepliesWhileDetached(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	p := h.pty(0)

	p.emit("\x1b[c")
	eventually(t, "DA1 reply while attached", func() bool { return p.inputString() == "\x1b[?62;22c" })

	w.detach()
	p.emit("\x1b[c")
	eventually(t, "DA1 reply while detached", func() bool { return p.inputString() == "\x1b[?62;22c\x1b[?62;22c" })
}

func TestSteal(t *testing.T) {
	h := newHarness(t)
	w1 := h.window()
	pane := w1.newWorkspace()
	w2 := h.window()
	w2.attach(w1.ws.ID, Area{})
	p := h.pty(0)

	d := nextEvent[rpc.WorkspaceDetachedParams](w1, rpc.EvWorkspaceDetached)
	if d.ID != w1.ws.ID || d.Reason != "attached elsewhere" {
		t.Fatalf("first window got %+v", d)
	}
	w1.c.Send(pane, &Event{Data: evText("from-1")})
	w2.c.Send(pane, &Event{Data: evText("from-2")})
	eventually(t, "input", func() bool { return p.inputString() != "" })
	time.Sleep(20 * time.Millisecond)
	if s := p.inputString(); s != "from-2" {
		t.Errorf("input %q, want only the owner's", s)
	}
}

func TestAttachSizesPanes(t *testing.T) {
	h := newHarness(t)
	w1 := h.window()
	pane := w1.newWorkspace()
	w1.split(pane, Right, 2500, "")
	w1.c.Close()
	eventually(t, "detach", func() bool { return !h.attached(w1.ws.ID) })

	w2 := h.window()
	w2.attach(w1.ws.ID, Area{Width: 900, Height: 540, CellW: 9, CellH: 18})
	// Sized before the attach replies.
	if got := h.pty(0).getSize(); got != [2]uint16{75, 30} {
		t.Errorf("left pty %v, want 75x30", got)
	}
	if got := h.pty(1).getSize(); got != [2]uint16{25, 30} {
		t.Errorf("right pty %v, want 25x30", got)
	}
}

func TestResize(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	p := h.pty(0)
	w.c.Send(pane, &Resize{Size: Size{Cols: 120, Rows: 50}})
	eventually(t, "resize", func() bool { return p.getSize() == [2]uint16{120, 50} })
	// A client that doesn't own the workspace can't.
	other := h.connect()
	other.Send(pane, &Resize{Size: Size{Cols: 10, Rows: 5}})
	time.Sleep(20 * time.Millisecond)
	if got := p.getSize(); got != [2]uint16{120, 50} {
		t.Errorf("resized by a stranger: %v", got)
	}
}

// TestSplitByOwner: the owner gets the new pane and the new layout
// before the reply, and the pane works.
func TestSplitByOwner(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	a, created := w.split(first, Down, 3000, "second")
	w.absorb(a)
	second := created.Pane
	if a.Panes[second] == nil {
		t.Fatal("no pane.attached for the new pane")
	}
	if a.Workspace == nil {
		t.Fatal("no workspace.changed before the reply")
	}
	tree := w.ws.Tabs[0].Tree
	if tree.Axis != Column || fmt.Sprint(tree.Panes()) != fmt.Sprint([]uint32{first, second}) || tree.Children[1].Share != 3000 {
		t.Errorf("layout %s", show(tree))
	}
	h.pty(1).emit("in the second")
	w.until(second, "in the second")
}

// TestSplitByScript: another client splits a pane in an attached
// workspace; the owner is told, gets the pane, and sees the layout.
func TestSplitByScript(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	script := h.connect()
	var created rpc.Created
	if err := script.Call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: first, Direction: Left, Share: 5000, Command: "watch"}, &created); err != nil {
		t.Fatal(err)
	}
	var attached bool
	for {
		_, m, err := w.c.Recv()
		if err != nil {
			t.Fatal(err)
		}
		name, params, ok := Notification(m)
		if !ok {
			continue
		}
		switch name {
		case rpc.EvPaneAttached:
			var at rpc.PaneAttachedParams
			json.Unmarshal(params, &at)
			if at.ID == created.Pane && at.Command == "watch" {
				attached = true
			}
		case rpc.EvWorkspaceChanged:
			if !attached {
				t.Error("structure before the pane it refers to")
			}
			var ws rpc.Workspace
			json.Unmarshal(params, &ws)
			if got := fmt.Sprint(ws.Tabs[0].Tree.Panes()); got != fmt.Sprint([]uint32{created.Pane, first}) {
				t.Errorf("panes %s", got)
			}
			return
		}
	}
}

// TestSplitDetached sizes panes from the workspace's last tab area.
func TestSplitDetached(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	if err := w.c.Call(rpc.WorkspaceResize, rpc.WorkspaceResizeParams{ID: w.ws.ID, Area: Area{Width: 1200, Height: 800, CellW: 10, CellH: 20}}, nil); err != nil {
		t.Fatal(err)
	}
	w.detach()

	script := h.connect()
	if err := script.Call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: first, Direction: Right, Share: 5000}, nil); err != nil {
		t.Fatal(err)
	}
	eventually(t, "retile", func() bool {
		return h.pty(0).getSize() == [2]uint16{60, 40} && h.pty(1).getSize() == [2]uint16{60, 40}
	})
}

// TestDetachRetiles: an owner that never sizes its panes (a script
// building a tab) leaves them to the daemon when it hangs up.
func TestDetachRetiles(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	for range 2 {
		w.split(first, Right, 5000, "")
	}
	w.c.Close()
	// The tab started at 40x10 (newTab), the workspace's size since. The
	// second split carves from the first pane's half: row(25% first, 25%
	// third, 50% second).
	eventually(t, "retile", func() bool {
		return h.pty(0).getSize() == [2]uint16{10, 10} &&
			h.pty(1).getSize() == [2]uint16{20, 10} && h.pty(2).getSize() == [2]uint16{10, 10}
	})
}

// TestPaneFonts: each pane keeps the cell size its window gave it, so
// when the daemon retiles, the shares divide pixels and each grid
// follows its pane's font.
func TestPaneFonts(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	_, created := w.split(first, Right, 5000, "")
	second := created.Pane
	w.c.Call(rpc.WorkspaceResize, rpc.WorkspaceResizeParams{ID: w.ws.ID, Area: Area{Width: 1000, Height: 800, CellW: 10, CellH: 20}}, nil)
	// The second pane's font is twice the size.
	w.c.Send(first, &Resize{Size: Size{Cols: 50, Rows: 40, CellW: 10, CellH: 20}})
	w.c.Send(second, &Resize{Size: Size{Cols: 25, Rows: 20, CellW: 20, CellH: 40}})
	eventually(t, "resizes", func() bool { return h.pty(1).getSize() == [2]uint16{25, 20} })

	// Wider: the daemon retiles once the window is gone.
	w.c.Call(rpc.WorkspaceResize, rpc.WorkspaceResizeParams{ID: w.ws.ID, Area: Area{Width: 2000, Height: 800, CellW: 10, CellH: 20}}, nil)
	w.c.Close()
	eventually(t, "retile", func() bool {
		return h.pty(0).getSize() == [2]uint16{100, 40} && h.pty(1).getSize() == [2]uint16{50, 20}
	})

	// A split takes its neighbour's font.
	script := h.connect()
	if err := script.Call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: second, Direction: Down, Share: 5000}, nil); err != nil {
		t.Fatal(err)
	}
	eventually(t, "split", func() bool { return h.pty(2).getSize() == [2]uint16{50, 10} })
}

// TestPaneExit: the tree closes over an exited pane; the last one takes
// the tab with it.
func TestPaneExit(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	a, created := w.split(first, Right, 5000, "")
	w.absorb(a)
	second := created.Pane

	h.pty(1).exit(7)
	e := nextEvent[rpc.PaneExitedParams](w, rpc.EvPaneExited)
	if e.ID != second || e.Status != 7 {
		t.Errorf("exit %d on %d", e.Status, e.ID)
	}
	nextEvent[rpc.Workspace](w, rpc.EvWorkspaceChanged)
	if tree := w.ws.Tabs[0].Tree; !tree.IsLeaf() || tree.Pane != first {
		t.Errorf("after the exit: %s", show(tree))
	}

	h.pty(0).exit(0)
	nextEvent[rpc.PaneExitedParams](w, rpc.EvPaneExited)
	nextEvent[rpc.Workspace](w, rpc.EvWorkspaceChanged)
	if len(w.ws.Tabs) != 0 {
		t.Errorf("tabs left: %+v", w.ws.Tabs)
	}
	// An empty workspace stays while attached, and goes when detached.
	if !h.attached(w.ws.ID) {
		t.Fatal("empty workspace dropped while attached")
	}
	w.detach()
	eventually(t, "removal", func() bool { return len(h.list().Workspaces) == 0 })
}

func TestLayout(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	a, _ := w.split(first, Right, 5000, "")
	w.absorb(a)
	tab := w.ws.Tabs[0]

	tree := tab.Tree.Clone()
	tree.Children[0].Share, tree.Children[1].Share = 7000, 3000
	if _, err := w.call(rpc.TabLayout, rpc.TabLayoutParams{ID: tab.ID, Tree: tree}, nil); err != nil {
		t.Fatal(err)
	}
	var d rpc.WorkspaceDesc
	w.c.Call(rpc.WorkspaceInfo, rpc.WorkspaceParams{ID: w.ws.ID}, &d)
	if got := d.Tabs[0].Tree.Children[0].Share; got != 7000 {
		t.Errorf("share %d after the drag", got)
	}

	bad := tree.Clone()
	bad.Children[1].Node.Pane = 999
	err := w.c.Call(rpc.TabLayout, rpc.TabLayoutParams{ID: tab.ID, Tree: bad}, nil)
	var rerr *rpc.Error
	if !errors.As(err, &rerr) || rerr.Code != rpc.CodeInvalidParams || !strings.Contains(rerr.Message, "match") {
		t.Errorf("bad layout: %v", err)
	}
}

func TestTabClose(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	w.newTab()
	if len(w.ws.Tabs) != 2 {
		t.Fatalf("tabs %d", len(w.ws.Tabs))
	}
	a, err := w.call(rpc.TabClose, rpc.TabParams{ID: w.ws.Tabs[0].ID}, nil)
	if err != nil {
		t.Fatal(err)
	}
	w.absorb(a)
	if len(w.ws.Tabs) != 1 {
		t.Errorf("tabs after closing one: %d", len(w.ws.Tabs))
	}
	eventually(t, "kill", func() bool {
		select {
		case <-h.pty(0).exited:
			return true
		default:
			return false
		}
	})
}

func TestWorkspaceKill(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	w.newTab()
	if err := h.connect().Call(rpc.WorkspaceKill, rpc.WorkspaceParams{ID: w.ws.ID}, nil); err != nil {
		t.Fatal(err)
	}
	d := nextEvent[rpc.WorkspaceDetachedParams](w, rpc.EvWorkspaceDetached)
	if d.Reason != "killed" {
		t.Errorf("reason %q", d.Reason)
	}
	eventually(t, "removal", func() bool { return len(h.list().Workspaces) == 0 })
}

func TestPaneTextDoesntTake(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	h.pty(0).emit("peekaboo")
	w.until(pane, "peekaboo")
	var r rpc.PaneTextResult
	if err := h.connect().Call(rpc.PaneText, rpc.PaneTextParams{ID: pane}, &r); err != nil {
		t.Fatal(err)
	}
	if r.Text != "peekaboo" {
		t.Errorf("read %q", r.Text)
	}
	if !h.attached(w.ws.ID) {
		t.Error("reading took the workspace")
	}
	h.pty(0).emit(" still mine")
	w.until(pane, "still mine")
	if err := h.connect().Call(rpc.PaneText, rpc.PaneTextParams{ID: pane, VT: true}, &r); err != nil || !strings.Contains(r.Text, "peekaboo still mine") {
		t.Errorf("read as VT %q, %v", r.Text, err)
	}
}

// TestPaneInfoAndWrite: pane.info describes a pane, and pane.write
// types into it from a client that doesn't own it.
func TestPaneInfoAndWrite(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	h.pty(0).emit("\x1b]0;my title\x07\x1b]7501;state=working:progress=40\x07")
	w.until(pane, "")
	eventually(t, "title", func() bool {
		var d rpc.PaneDesc
		h.connect().Call(rpc.PaneInfo, rpc.PaneParams{ID: pane}, &d)
		return d.Title == "my title"
	})
	var d rpc.PaneDesc
	if err := h.connect().Call(rpc.PaneInfo, rpc.PaneParams{ID: pane}, &d); err != nil {
		t.Fatal(err)
	}
	if d.ID != pane || d.Workspace != w.ws.ID || d.Tab != w.ws.Tabs[0].ID || d.Cols != 40 || d.Rows != 10 || d.PID != 4242 {
		t.Errorf("info %+v", d)
	}
	if len(d.Status) != 1 || d.Status[0].Progress != 40 {
		t.Errorf("status %+v", d.Status)
	}
	if err := h.connect().Call(rpc.PaneWrite, rpc.PaneWriteParams{ID: pane, Text: "typed\r"}, nil); err != nil {
		t.Fatal(err)
	}
	eventually(t, "input", func() bool { return h.pty(0).inputString() == "typed\r" })
	var ti rpc.TabInfoResult
	if err := h.connect().Call(rpc.TabInfo, rpc.TabParams{ID: d.Tab}, &ti); err != nil || ti.Workspace != w.ws.ID || ti.Tree.Pane != pane {
		t.Errorf("tab.info %+v, %v", ti, err)
	}
}

// TestSubscribe: a client with no workspace hears the events it asks
// for, by name or group, and no others.
func TestSubscribe(t *testing.T) {
	h := newHarness(t)
	sub := h.connect()
	if err := sub.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{rpc.EvPaneExited, "tab.*"}}, nil); err != nil {
		t.Fatal(err)
	}
	quiet := h.connect()
	w := h.window()
	pane := w.newWorkspace()
	tab := w.ws.Tabs[0].ID
	h.pty(0).exit(2)

	var names []string
	for len(names) < 3 {
		_, m, err := sub.Recv()
		if err != nil {
			t.Fatal(err)
		}
		name, params, ok := Notification(m)
		if !ok {
			continue
		}
		names = append(names, name)
		switch name {
		case rpc.EvTabCreated:
			var p rpc.TabEventParams
			json.Unmarshal(params, &p)
			if p.Workspace != w.ws.ID || p.ID != tab {
				t.Errorf("tab.created %+v", p)
			}
		case rpc.EvPaneExited:
			var p rpc.PaneExitedParams
			json.Unmarshal(params, &p)
			if p.ID != pane || p.Status != 2 {
				t.Errorf("pane.exited %+v", p)
			}
		}
	}
	if want := []string{rpc.EvTabCreated, rpc.EvPaneExited, rpc.EvTabClosed}; !reflect.DeepEqual(names, want) {
		t.Errorf("events %v, want %v", names, want)
	}
	// The quiet client heard nothing, and still answers.
	if err := quiet.Call(rpc.WorkspaceList, nil, nil); err != nil || len(quiet.backlog) != 0 {
		t.Errorf("unsubscribed client got %d messages, %v", len(quiet.backlog), err)
	}
}

// TestModesTracked: the daemon keeps the modes libghostty-vt leaves to
// it, which decide how it encodes keys.
func TestModesTracked(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	h.pty(0).emit("\x1b[?9001h\x1b[?1004hmark")
	w.until(pane, "mark")
	p := h.srv.pane(pane)
	p.mu.Lock()
	defer p.mu.Unlock()
	want := []mode{{num: 9001, enabled: true}}
	if !p.win32InputLocked() || !reflect.DeepEqual(p.modes, want) {
		t.Errorf("modes %+v, want %+v", p.modes, want)
	}
}

func TestDisconnectDetaches(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	w.newWorkspace()
	w.c.Close()
	eventually(t, "detach", func() bool { return !h.attached(w.ws.ID) })
	if l := h.list(); len(l.Workspaces) != 1 || len(l.Workspaces[0].Tabs) != 1 {
		t.Errorf("workspace lost: %+v", l.Workspaces)
	}
}

func TestErrors(t *testing.T) {
	h := newHarness(t)
	c := h.connect()
	for _, call := range []struct {
		method string
		params any
	}{
		{rpc.WorkspaceAttach, rpc.WorkspaceAttachParams{ID: 99}},
		{rpc.TabNew, rpc.TabNewParams{Workspace: 99}},
		{rpc.PaneSplit, rpc.PaneSplitParams{Pane: 99, Direction: Right}},
		{rpc.PaneText, rpc.PaneTextParams{ID: 99}},
		{rpc.TabInfo, rpc.TabParams{ID: 99}},
	} {
		err := c.Call(call.method, call.params, nil)
		var rerr *rpc.Error
		if !errors.As(err, &rerr) || rerr.Code != rpc.CodeNotFound || !strings.Contains(rerr.Message, "no such") {
			t.Errorf("%s: %v", call.method, err)
		}
	}
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
