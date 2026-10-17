// Package persist is slimed: a daemon that owns ptys and the terminal
// state of each (internal/vt), so they outlive the windows showing them.
//
// Panes (a pty and its terminal) are arranged in tabs, each a layout
// tree, and tabs are grouped in workspaces. A window attaches a whole
// workspace, getting a snapshot of each pane's terminal and then its
// live output from where the snapshot ends. The daemon owns the
// structure; a window mirrors it, asking for changes and applying the
// Workspace messages that come back.
package persist

import (
	"cmp"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"slices"
	"sync"
	"time"

	"github.com/aldehir/slime/ssh/internal/pty"
	"github.com/aldehir/slime/ssh/internal/vt"
)

// Server holds the workspaces and serves clients.
//
// Its lock guards the structure: workspaces, tabs, their trees, which
// panes exist, and who owns what. It's taken before a pane's lock,
// never inside one.
type Server struct {
	vt    *vt.Runtime
	spawn func(pty.Options) (pty.Pty, error)
	log   *slog.Logger
	idle  time.Duration

	snapshotVersion uint16

	mu         sync.Mutex
	nextID     uint32 // shared by workspaces, tabs, and panes
	workspaces map[uint32]*workspace
	tabs       map[uint32]*tab
	panes      map[uint32]*Pane
	conns      map[*conn]struct{}
	idleT      *time.Timer
	idleC      chan struct{} // closed when the idle timer fires
}

// Options configure a Server.
type Options struct {
	// Spawn starts a pane's child; pty.Start if nil.
	Spawn func(pty.Options) (pty.Pty, error)
	Log   *slog.Logger
	// Idle is how long Serve waits with no workspaces and no clients
	// before returning. Zero waits forever.
	Idle time.Duration
}

// defaultSize is a pane's size when nothing says otherwise.
var defaultSize = Size{Cols: 80, Rows: 24}

func NewServer(rt *vt.Runtime, opts Options) (*Server, error) {
	if opts.Spawn == nil {
		opts.Spawn = pty.Start
	}
	if opts.Log == nil {
		opts.Log = slog.New(slog.DiscardHandler)
	}
	s := &Server{
		vt:         rt,
		spawn:      opts.Spawn,
		log:        opts.Log,
		idle:       opts.Idle,
		workspaces: map[uint32]*workspace{},
		tabs:       map[uint32]*tab{},
		panes:      map[uint32]*Pane{},
		conns:      map[*conn]struct{}{},
		idleC:      make(chan struct{}),
	}
	// The snapshot envelope: 8 bytes of magic, then a u16 version.
	t, err := rt.New(1, 1)
	if err != nil {
		return nil, err
	}
	defer t.Close()
	snap, err := t.Snapshot()
	if err != nil || len(snap) < 10 {
		return nil, fmt.Errorf("persist: reading the snapshot version: %v", err)
	}
	s.snapshotVersion = binary.LittleEndian.Uint16(snap[8:10])
	return s, nil
}

// Serve accepts clients on l until l fails or the server has been idle
// for Options.Idle, when it closes l and returns nil.
func (s *Server) Serve(l net.Listener) error {
	s.mu.Lock()
	s.checkIdleLocked()
	s.mu.Unlock()
	errc := make(chan error, 1)
	go func() {
		for {
			rw, err := l.Accept()
			if err != nil {
				errc <- err
				return
			}
			go s.handle(rw)
		}
	}()
	select {
	case err := <-errc:
		return err
	case <-s.idleC:
		s.log.Info("idle; exiting")
		l.Close()
		return nil
	}
}

// checkIdleLocked starts the idle timer when nothing is left, and stops
// it otherwise.
func (s *Server) checkIdleLocked() {
	if s.idle == 0 {
		return
	}
	idle := len(s.workspaces) == 0 && len(s.panes) == 0 && len(s.conns) == 0
	switch {
	case idle && s.idleT == nil:
		s.idleT = time.AfterFunc(s.idle, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.idleT != nil && len(s.workspaces) == 0 && len(s.panes) == 0 && len(s.conns) == 0 {
				close(s.idleC)
			}
		})
	case !idle && s.idleT != nil:
		s.idleT.Stop()
		s.idleT = nil
	}
}

func (s *Server) handle(rw io.ReadWriteCloser) {
	c := newConn(rw, s.log)
	r := NewReader(rw)
	if !s.handshake(c, r) {
		c.closeAfterFlush()
		return
	}
	s.mu.Lock()
	s.conns[c] = struct{}{}
	s.checkIdleLocked()
	s.mu.Unlock()
	defer func() {
		c.close()
		s.mu.Lock()
		for _, ws := range c.owned {
			s.releaseLocked(ws, "")
		}
		delete(s.conns, c)
		s.checkIdleLocked()
		s.mu.Unlock()
	}()
	for {
		f, err := r.Read()
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, net.ErrClosed) {
				s.log.Info("client read", "err", err)
			}
			return
		}
		m, err := Decode(f)
		if err != nil {
			s.log.Warn("bad frame", "err", err)
			if errors.Is(err, ErrUnknownType) {
				continue
			}
			return
		}
		s.dispatch(c, f.ID, m)
	}
}

func (s *Server) handshake(c *conn, r *Reader) bool {
	f, err := r.Read()
	if err != nil {
		return false
	}
	m, err := Decode(f)
	hello, ok := m.(*Hello)
	if err != nil || !ok {
		c.sendForce(0, &Error{Message: "expected hello"})
		return false
	}
	c.sendForce(0, &HelloReply{
		Version:         Version,
		SnapshotVersion: s.snapshotVersion,
		PID:             uint32(os.Getpid()),
	})
	if hello.Version != Version {
		c.sendForce(0, &Error{Message: fmt.Sprintf("slimed speaks version %d, not %d", Version, hello.Version)})
		return false
	}
	return true
}

func (s *Server) dispatch(c *conn, id uint32, m Message) {
	fail := func(tag uint32, err error) {
		if err != nil {
			c.sendForce(0, &Error{Tag: tag, Message: err.Error()})
		}
	}
	switch m := m.(type) {
	case *List:
		c.sendForce(0, s.list())
	case *WorkspaceNew:
		s.workspaceNew(c, m)
	case *WorkspaceAttach:
		fail(m.Tag, s.workspaceAttach(c, m))
	case *WorkspaceDetach:
		s.workspaceDetach(c, m.WS)
	case *WorkspaceKill:
		fail(0, s.workspaceKill(m.WS))
	case *WorkspaceRename:
		fail(0, s.workspaceRename(m.WS, m.Name))
	case *WorkspaceResize:
		s.workspaceResize(c, m)
	case *TabNew:
		fail(m.Tag, s.tabNew(c, m))
	case *TabClose:
		fail(0, s.tabClose(m.Tab))
	case *TabRename:
		fail(0, s.tabRename(m.Tab, m.Name))
	case *Split:
		fail(m.Tag, s.split(c, m))
	case *Layout:
		fail(0, s.layout(m))
	case *PaneKill:
		if p := s.pane(id); p != nil {
			p.kill()
		}
	case *Input:
		if p := s.pane(id); p != nil {
			p.input(c, m.Data)
		}
	case *Resize:
		if p := s.pane(id); p != nil {
			p.resize(c, m.Size)
		}
	case *Peek:
		p := s.pane(id)
		if p == nil {
			fail(m.Tag, errors.New("no such pane"))
			return
		}
		fail(m.Tag, p.peek(c, m.Tag))
	default:
		s.log.Warn("unexpected message", "type", m.Type())
	}
}

func (s *Server) pane(id uint32) *Pane {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.panes[id]
}

func (s *Server) newIDLocked() uint32 {
	s.nextID++
	return s.nextID
}

// startPane starts a child and its terminal, outside the server's lock:
// spawning takes a while. The caller registers it, or kills it if
// what it was for is gone by then.
func (s *Server) startPane(command, cwd string, size Size) (pty.Pty, *vt.Terminal, error) {
	if size.Cols == 0 || size.Rows == 0 {
		size.Cols, size.Rows = defaultSize.Cols, defaultSize.Rows
	}
	term, err := s.vt.New(size.Cols, size.Rows)
	if err != nil {
		return nil, nil, err
	}
	if err := term.Resize(size.Cols, size.Rows, size.CellW, size.CellH); err != nil {
		term.Close()
		return nil, nil, err
	}
	// Grapheme clustering (mode 2027), as slime's terminals start with it
	// and ConPTY measures text so. Only the current value: the C API
	// can't set the default a full reset (RIS) goes back to.
	if _, err := term.Write([]byte("\x1b[?2027h")); err != nil {
		term.Close()
		return nil, nil, err
	}
	p, err := s.spawn(pty.Options{Command: command, Dir: cwd, Cols: size.Cols, Rows: size.Rows})
	if err != nil {
		term.Close()
		return nil, nil, err
	}
	return p, term, nil
}

func (s *Server) list() *Workspaces {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := &Workspaces{}
	for _, ws := range s.workspaces {
		info := WorkspaceInfo{ID: ws.id, Name: ws.name, Attached: ws.owner != nil, Tabs: ws.tabInfos()}
		if !ws.detachedAt.IsZero() && ws.owner == nil {
			info.DetachedAt = ws.detachedAt.UnixMilli()
		}
		out.Workspaces = append(out.Workspaces, info)
		for _, t := range ws.tabs {
			for _, id := range t.root.Panes() {
				if p := s.panes[id]; p != nil {
					out.Panes = append(out.Panes, p.info(t.id))
				}
			}
		}
	}
	slices.SortFunc(out.Workspaces, func(a, b WorkspaceInfo) int { return cmp.Compare(a.ID, b.ID) })
	return out
}

// Close kills every pane.
func (s *Server) Close() {
	s.mu.Lock()
	ps := make([]*Pane, 0, len(s.panes))
	for _, p := range s.panes {
		ps = append(ps, p)
	}
	s.mu.Unlock()
	for _, p := range ps {
		p.pty.Close()
	}
}
