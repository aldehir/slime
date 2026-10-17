package daemon

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

	"github.com/aldehir/slime/internal/pty"
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

// window is a client playing slime: it owns workspaces and mirrors their
// panes' screens from the frames it's sent, acking each.
type window struct {
	t       *testing.T
	h       *harness
	c       *Client
	ws      *Workspace
	screens map[uint32]*vt.Screen
}

func (h *harness) window() *window {
	return &window{t: h.t, h: h, c: h.connect(), screens: map[uint32]*vt.Screen{}}
}

// absorb takes in what an attach or a new pane delivered.
func (w *window) absorb(a *Attachment) {
	w.t.Helper()
	w.ws = a.Workspace
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
	tag := w.c.NextTag()
	w.c.Send(0, &WorkspaceNew{Tag: tag, Name: "test"})
	a, err := w.c.Await(tag, true)
	if err != nil {
		w.t.Fatal(err)
	}
	w.absorb(a)
	return w.newTab()
}

func (w *window) newTab() uint32 {
	w.t.Helper()
	tag := w.c.NextTag()
	w.c.Send(0, &TabNew{Tag: tag, WS: w.ws.ID, Size: Size{Cols: 40, Rows: 10}})
	a, err := w.c.Await(tag, true)
	if err != nil {
		w.t.Fatal(err)
	}
	w.absorb(a)
	return a.Created.Pane
}

func (w *window) attach(ws uint32, area Area) {
	w.t.Helper()
	tag := w.c.NextTag()
	w.c.Send(0, &WorkspaceAttach{Tag: tag, WS: ws, Area: area})
	a, err := w.c.Await(tag, false)
	if err != nil {
		w.t.Fatal(err)
	}
	w.absorb(a)
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

// next reads until a message of type T, applying frames on the way.
func next[T Message](w *window) (uint32, T) {
	w.t.Helper()
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
		if ws, ok := m.(*Workspace); ok {
			w.ws = ws
		}
		if t, ok := m.(T); ok {
			return id, t
		}
	}
	var zero T
	w.t.Fatalf("no %T", zero)
	return 0, zero
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

func (h *harness) list() *Workspaces {
	h.t.Helper()
	l, err := h.connect().List()
	if err != nil {
		h.t.Fatal(err)
	}
	return l
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
	tree := &Node{Axis: Row, Children: []Child{
		{6000, &Node{Pane: 3}},
		{4000, &Node{Axis: Column, Children: []Child{{5000, &Node{Pane: 4}}, {5000, &Node{Pane: 5}}}}},
	}}
	tabs := []TabInfo{{ID: 2, Name: "build", Tree: tree}, {ID: 6, Tree: &Node{Pane: 7}}}
	msgs := []Message{
		&Hello{Version: 3, FrameInterval: 16667},
		&List{},
		&WorkspaceNew{Tag: 1, Name: "main"},
		&WorkspaceAttach{Tag: 2, WS: 9, Area: Area{720, 432, 9, 18}},
		&WorkspaceDetach{WS: 9},
		&WorkspaceKill{WS: 9},
		&WorkspaceRename{WS: 9, Name: "ops"},
		&WorkspaceResize{WS: 9, Area: Area{1000, 800, 10, 20}},
		&TabNew{Tag: 3, WS: 9, Command: "cmd.exe /k", Cwd: `C:\src`, Size: Size{80, 24, 9, 18}},
		&TabClose{Tab: 2},
		&TabRename{Tab: 2, Name: "logs"},
		&Split{Tag: 4, Pane: 3, Dir: Down, Share: 3000, Command: "pwsh", Cwd: "D:\\"},
		&Layout{Tab: 2, Tree: tree},
		&PaneKill{},
		&Resize{Size: Size{1, 2, 3, 4}},
		&Peek{Tag: 5, VT: true},
		&HelloReply{Version: 1, PID: 99, FrameLayout: 1 << 63},
		&Workspaces{
			Workspaces: []WorkspaceInfo{{ID: 9, Name: "main", Attached: true, DetachedAt: 1700000000000, Tabs: tabs}, {ID: 10}},
			Panes:      []PaneInfo{{ID: 3, Tab: 2, Command: "c", Title: "t", Pwd: "p", Cols: 80, Rows: 24, Created: 1700000000000, PID: 5}},
		},
		&Workspace{Tag: 6, ID: 9, Name: "main", Tabs: tabs},
		&Attached{Command: "pwsh -NoLogo", Status: []StatusRecord{{"", 1, 40}, {"deploy/eu", 3, -1}}},
		&PaneText{Tag: 5, Data: []byte("\x1b[31mred")},
		&Exit{Status: 0xc000013a},
		&Detached{WS: 9, Reason: "too slow"},
		&Error{Tag: 8, Message: "no such pane"},
		&Created{Tag: 9, WS: 9, Tab: 2, Pane: 3},
		&Draw{Seq: 4, Data: []byte{1, 2, 3}},
		&Image{ID: 7, Generation: 1 << 40, Width: 2, Height: 3, Total: 10, Offset: 4, Data: []byte{9, 8, 7}},
		&HostConnect{Tag: 10, Dest: "ssh://alde@dev1:2222"},
		&HostAnswer{Choice: ChoiceAccept, Answers: []string{"hunter2", ""}},
		&HostDisconnect{},
		&HostList{},
		&Bridge{Term: "xterm-ghostty"},
		&Hosts{Hosts: []HostInfo{{ID: 11, Dest: "dev1", State: HostConnected}, {ID: 12, Dest: "dev2", State: HostFailed, Text: "Permission denied"}}},
		&HostState{Tag: 13, Dest: "dev1", State: HostConnecting, Text: "installing slimed"},
		&Prompt{Kind: PromptInteractive, Title: "Sign in", Text: "body", Detail: "SHA256:x", Error: "try again", Questions: []Question{{Label: "Password: "}, {Label: "Code: ", Echo: true}}},
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
	case *Workspaces:
		if len(m.Workspaces) == 0 {
			m.Workspaces = nil
		}
		for i := range m.Workspaces {
			if len(m.Workspaces[i].Tabs) == 0 {
				m.Workspaces[i].Tabs = nil
			}
		}
		if len(m.Panes) == 0 {
			m.Panes = nil
		}
	case *HostAnswer:
		if len(m.Answers) == 0 {
			m.Answers = nil
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
	f := Frame{Type: TypeTabNew, Payload: []byte{1, 0, 0, 0, 2, 0, 0, 0, 0xff, 0, 0, 0}}
	if _, err := Decode(f); err == nil {
		t.Error("truncated string decoded")
	}
	// A layout nested past maxDepth.
	deep := &Node{Pane: 1}
	for range maxDepth + 2 {
		deep = &Node{Axis: Row, Children: []Child{{5000, deep}, {5000, &Node{Pane: 2}}}}
	}
	b, _ = Encode(0, &Layout{Tab: 1, Tree: deep})
	if _, err := Decode(Frame{Type: TypeLayout, Payload: b[9:]}); err == nil {
		t.Error("deep layout decoded")
	}
	// A split claiming more children than the bytes hold.
	f = Frame{Type: TypeLayout, Payload: []byte{1, 0, 0, 0, 1, 1, 0xff, 0xff}}
	if _, err := Decode(f); err == nil {
		t.Error("oversized child count decoded")
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
	w1.c.Send(0, &WorkspaceDetach{WS: ws})
	eventually(t, "detach", func() bool { return !h.attached(ws) })
	p.emit("two\r\n")
	eventually(t, "detached output", func() bool { return strings.Contains(h.serverText(pane), "two") })

	l := h.list()
	if len(l.Workspaces) != 1 || l.Workspaces[0].Attached || l.Workspaces[0].DetachedAt == 0 {
		t.Fatalf("list %+v", l.Workspaces)
	}
	if len(l.Panes) != 1 || l.Panes[0].ID != pane || l.Panes[0].PID != 4242 {
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
	w1.c.Send(0, &WorkspaceDetach{WS: ws})
	eventually(t, "detach", func() bool { return !h.attached(ws) })
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

	w.c.Send(0, &WorkspaceDetach{WS: w.ws.ID})
	eventually(t, "detach", func() bool { return !h.attached(w.ws.ID) })
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

	_, d := next[*Detached](w1)
	if d.WS != w1.ws.ID || d.Reason != "attached elsewhere" {
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
	w1.c.Send(0, &Split{Tag: w1.c.NextTag(), Pane: pane, Dir: Right, Share: 2500})
	next[*Created](w1)
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

// TestSplitByOwner: the owner gets the new pane and the new layout, and
// the pane works.
func TestSplitByOwner(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	tag := w.c.NextTag()
	w.c.Send(0, &Split{Tag: tag, Pane: first, Dir: Down, Share: 3000, Command: "second"})
	a, err := w.c.Await(tag, true)
	if err != nil {
		t.Fatal(err)
	}
	w.absorb(a)
	second := a.Created.Pane
	if a.Panes[second] == nil {
		t.Fatal("no Attached for the new pane")
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
	tag := script.NextTag()
	script.Send(0, &Split{Tag: tag, Pane: first, Dir: Left, Share: 5000, Command: "watch"})
	created, err := script.AwaitCreated(tag)
	if err != nil {
		t.Fatal(err)
	}
	var attached bool
	for {
		id, m, err := w.c.Recv()
		if err != nil {
			t.Fatal(err)
		}
		if _, ok := m.(*Attached); ok && id == created.Pane {
			attached = true
		}
		if ws, ok := m.(*Workspace); ok {
			if !attached {
				t.Error("structure before the pane it refers to")
			}
			if got := fmt.Sprint(ws.Tabs[0].Tree.Panes()); got != fmt.Sprint([]uint32{created.Pane, first}) {
				t.Errorf("panes %s", got)
			}
			break
		}
	}
}

// TestSplitDetached sizes panes from the workspace's last tab area.
func TestSplitDetached(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	w.c.Send(0, &WorkspaceResize{WS: w.ws.ID, Area: Area{Width: 1200, Height: 800, CellW: 10, CellH: 20}})
	w.c.Send(0, &WorkspaceDetach{WS: w.ws.ID})
	eventually(t, "detach", func() bool { return !h.attached(w.ws.ID) })

	script := h.connect()
	tag := script.NextTag()
	script.Send(0, &Split{Tag: tag, Pane: first, Dir: Right, Share: 5000})
	if _, err := script.AwaitCreated(tag); err != nil {
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
		tag := w.c.NextTag()
		w.c.Send(0, &Split{Tag: tag, Pane: first, Dir: Right, Share: 5000})
		if _, err := w.c.Await(tag, true); err != nil {
			t.Fatal(err)
		}
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
	tag := w.c.NextTag()
	w.c.Send(0, &Split{Tag: tag, Pane: first, Dir: Right, Share: 5000})
	a, err := w.c.Await(tag, true)
	if err != nil {
		t.Fatal(err)
	}
	second := a.Created.Pane
	w.c.Send(0, &WorkspaceResize{WS: w.ws.ID, Area: Area{Width: 1000, Height: 800, CellW: 10, CellH: 20}})
	// The second pane's font is twice the size.
	w.c.Send(first, &Resize{Size: Size{Cols: 50, Rows: 40, CellW: 10, CellH: 20}})
	w.c.Send(second, &Resize{Size: Size{Cols: 25, Rows: 20, CellW: 20, CellH: 40}})
	eventually(t, "resizes", func() bool { return h.pty(1).getSize() == [2]uint16{25, 20} })

	// Wider: the daemon retiles once the window is gone.
	w.c.Send(0, &WorkspaceResize{WS: w.ws.ID, Area: Area{Width: 2000, Height: 800, CellW: 10, CellH: 20}})
	w.c.Close()
	eventually(t, "retile", func() bool {
		return h.pty(0).getSize() == [2]uint16{100, 40} && h.pty(1).getSize() == [2]uint16{50, 20}
	})

	// A split takes its neighbour's font.
	script := h.connect()
	tag = script.NextTag()
	script.Send(0, &Split{Tag: tag, Pane: second, Dir: Down, Share: 5000})
	if _, err := script.AwaitCreated(tag); err != nil {
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
	tag := w.c.NextTag()
	w.c.Send(0, &Split{Tag: tag, Pane: first, Dir: Right, Share: 5000})
	a, _ := w.c.Await(tag, true)
	w.absorb(a)
	second := a.Created.Pane

	h.pty(1).exit(7)
	id, e := next[*Exit](w)
	if id != second || e.Status != 7 {
		t.Errorf("exit %d on %d", e.Status, id)
	}
	next[*Workspace](w)
	if tree := w.ws.Tabs[0].Tree; !tree.isLeaf() || tree.Pane != first {
		t.Errorf("after the exit: %s", show(tree))
	}

	h.pty(0).exit(0)
	next[*Exit](w)
	next[*Workspace](w)
	if len(w.ws.Tabs) != 0 {
		t.Errorf("tabs left: %+v", w.ws.Tabs)
	}
	// An empty workspace stays while attached, and goes when detached.
	if !h.attached(w.ws.ID) {
		t.Fatal("empty workspace dropped while attached")
	}
	w.c.Send(0, &WorkspaceDetach{WS: w.ws.ID})
	eventually(t, "removal", func() bool { return len(h.list().Workspaces) == 0 })
}

func TestLayout(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	first := w.newWorkspace()
	tag := w.c.NextTag()
	w.c.Send(0, &Split{Tag: tag, Pane: first, Dir: Right, Share: 5000})
	a, _ := w.c.Await(tag, true)
	w.absorb(a)
	tab := w.ws.Tabs[0]

	tree := tab.Tree.Clone()
	tree.Children[0].Share, tree.Children[1].Share = 7000, 3000
	w.c.Send(0, &Layout{Tab: tab.ID, Tree: tree})
	next[*Workspace](w)
	if got := w.ws.Tabs[0].Tree.Children[0].Share; got != 7000 {
		t.Errorf("share %d after the drag", got)
	}

	bad := tree.Clone()
	bad.Children[1].Node.Pane = 999
	w.c.Send(0, &Layout{Tab: tab.ID, Tree: bad})
	if _, e := next[*Error](w); !strings.Contains(e.Message, "match") {
		t.Errorf("bad layout: %q", e.Message)
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
	w.c.Send(0, &TabClose{Tab: w.ws.Tabs[0].ID})
	next[*Workspace](w)
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
	h.connect().Send(0, &WorkspaceKill{WS: w.ws.ID})
	_, d := next[*Detached](w)
	if d.Reason != "killed" {
		t.Errorf("reason %q", d.Reason)
	}
	eventually(t, "removal", func() bool { return len(h.list().Workspaces) == 0 })
}

func TestPeekDoesntTake(t *testing.T) {
	h := newHarness(t)
	w := h.window()
	pane := w.newWorkspace()
	h.pty(0).emit("peekaboo")
	w.until(pane, "peekaboo")
	text, err := h.connect().Peek(pane, false)
	if err != nil {
		t.Fatal(err)
	}
	if string(text) != "peekaboo" {
		t.Errorf("peeked %q", text)
	}
	if !h.attached(w.ws.ID) {
		t.Error("peeking took the workspace")
	}
	h.pty(0).emit(" still mine")
	w.until(pane, "still mine")
	if vt, err := h.connect().Peek(pane, true); err != nil || !strings.Contains(string(vt), "peekaboo still mine") {
		t.Errorf("peeked as VT %q, %v", vt, err)
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
	for _, m := range []Message{
		&WorkspaceAttach{Tag: 1, WS: 99},
		&TabNew{Tag: 2, WS: 99},
		&Split{Tag: 3, Pane: 99, Dir: Right},
	} {
		c.Send(0, m)
		_, got, err := c.Recv()
		if e, ok := got.(*Error); err != nil || !ok || !strings.Contains(e.Message, "no such") {
			t.Errorf("%T: %#v, %v", m, got, err)
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
