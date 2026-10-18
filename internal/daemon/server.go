// Package daemon is slime: a daemon that owns ptys and the terminal
// state of each (internal/vt), so they outlive the windows showing them.
//
// Panes (a pty and its terminal) are arranged in tabs, each a layout
// tree, and tabs are grouped in workspaces. A window attaches a whole
// workspace, beside any other windows showing it, and draws the frames
// of each pane's screen the daemon sends (framing.go), sending input
// back as events (events.go). The daemon owns the structure and the
// focus; a window mirrors them, asking for changes (rpc.go) and
// applying the workspace.changed events that come back.
package daemon

import (
	"cmp"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"os"
	"slices"
	"sync"
	"time"

	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/vt"
)

// Server holds the workspaces and serves clients.
//
// Its lock guards the structure: workspaces, tabs, their trees and
// focus, which panes exist, and who views what. It's taken before a
// pane's lock, never inside one.
type Server struct {
	vt    *vt.Runtime
	spawn func(pty.Options) (pty.Pty, error)
	log   *slog.Logger
	idle  time.Duration

	mu         sync.Mutex
	nextID     uint32 // shared by workspaces, tabs, panes, and scripts
	workspaces map[uint32]*workspace
	tabs       map[uint32]*tab
	panes      map[uint32]*Pane
	conns      map[*conn]struct{}
	scripts    map[uint32]*script
	hosts      hostTable
	idleT      *time.Timer
	idleC      chan struct{} // closed when the idle timer fires
}

// Options configure a Server.
type Options struct {
	// Spawn starts a pane's child; pty.Start if nil.
	Spawn func(pty.Options) (pty.Pty, error)
	Log   *slog.Logger
	// Idle is how long Serve waits with no workspaces, no clients, and
	// no hosts before returning. Zero waits forever.
	Idle time.Duration
	// Hosts configures connecting to SSH hosts (Windows).
	Hosts HostOptions
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
		scripts:    map[uint32]*script{},
		hosts:      newHostTable(opts.Hosts),
		idleC:      make(chan struct{}),
	}
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
	idle := s.idleLocked()
	switch {
	case idle && s.idleT == nil:
		s.idleT = time.AfterFunc(s.idle, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.idleT != nil && s.idleLocked() {
				close(s.idleC)
			}
		})
	case !idle && s.idleT != nil:
		s.idleT.Stop()
		s.idleT = nil
	}
}

// idleLocked says whether nothing keeps the daemon alive.
func (s *Server) idleLocked() bool {
	return len(s.workspaces) == 0 && len(s.panes) == 0 && len(s.conns) == 0 && len(s.scripts) == 0 && s.hostsActiveLocked() == 0
}

func (s *Server) handle(rw io.ReadWriteCloser) {
	r := NewReader(rw)
	f, err := r.Read()
	if err != nil {
		rw.Close()
		return
	}
	m, err := Decode(f)
	if b, ok := m.(*Bridge); ok && err == nil {
		s.bridge(rw, r, f.ID, b)
		return
	}
	c := newConn(rw, s.log)
	if !s.handshake(c, m, err) {
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
		for _, ws := range c.viewing {
			s.releaseLocked(ws, c, "")
		}
		delete(s.conns, c)
		s.hostClientGoneLocked(c)
		s.scriptClientGoneLocked(c)
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
			if errors.Is(err, ErrUnknownType) || errors.Is(err, ErrBadJSON) {
				continue
			}
			return
		}
		s.dispatch(c, f.ID, m)
	}
}

// handshake answers the first frame, decoded as m (or err), which must
// be a Hello.
func (s *Server) handshake(c *conn, m Message, err error) bool {
	hello, ok := m.(*Hello)
	if err != nil || !ok {
		c.sendForce(0, &Error{Message: "expected hello"})
		return false
	}
	c.sendForce(0, &HelloReply{
		Version:     Version,
		PID:         uint32(os.Getpid()),
		FrameLayout: vt.FrameLayout(),
	})
	if hello.Version != Version {
		c.sendForce(0, &Error{Message: fmt.Sprintf("slime speaks version %d, not %d", Version, hello.Version)})
		return false
	}
	c.interval = defaultFrameInterval
	if hello.FrameInterval != 0 {
		c.interval = time.Duration(hello.FrameInterval) * time.Microsecond
	}
	return true
}

func (s *Server) dispatch(c *conn, id uint32, m Message) {
	switch m := m.(type) {
	case *Call:
		s.call(c, m.Request)
	case *Ack:
		if p := s.pane(id); p != nil {
			p.ack(c, m.Seq)
		}
	case *Event:
		if p := s.pane(id); p != nil {
			p.event(c, m.Data)
		}
	case *Resize:
		if p := s.pane(id); p != nil {
			p.resize(c, m.Size)
		}
	default:
		s.log.Warn("unexpected message", "type", m.Type())
	}
}

// writeError writes an Error straight to a connection that has no conn
// yet, and closes it once the client has hung up or a moment has
// passed: closing with its Hello unread would reset a TCP connection
// and lose the Error.
func writeError(rw io.ReadWriteCloser, msg string) {
	if b, err := Encode(0, &Error{Message: msg}); err == nil {
		rw.Write(b)
	}
	if c, ok := rw.(net.Conn); ok {
		c.SetReadDeadline(time.Now().Add(time.Second))
		io.Copy(io.Discard, c)
	}
	rw.Close()
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

// startPane starts a child and its terminal for pane id of workspace
// ws, outside the server's lock: spawning takes a while. The caller
// registers it (addPaneLocked), or closes it if what it was for is gone
// by then.
func (s *Server) startPane(id, ws uint32, spec *rpc.PaneSpec, size Size) (*started, error) {
	if size.Cols == 0 || size.Rows == 0 {
		size.Cols, size.Rows = defaultSize.Cols, defaultSize.Rows
	}
	term, err := s.vt.New(size.Cols, size.Rows)
	if err != nil {
		return nil, err
	}
	if err := term.Resize(size.Cols, size.Rows, size.CellW, size.CellH); err != nil {
		term.Close()
		return nil, err
	}
	p, err := s.spawn(pty.Options{
		Command: spec.Command,
		Dir:     spec.Cwd,
		Env:     paneEnv(id, ws, spec),
		Cols:    size.Cols,
		Rows:    size.Rows,
		Width:   uint32(size.Cols) * size.CellW,
		Height:  uint32(size.Rows) * size.CellH,
	})
	if err != nil {
		term.Close()
		return nil, err
	}
	return &started{id: id, spec: spec, size: size, pty: p, term: term}, nil
}

func (s *Server) list() *rpc.WorkspaceListResult {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := &rpc.WorkspaceListResult{Workspaces: []rpc.WorkspaceDesc{}, Panes: []rpc.PaneDesc{}}
	for _, ws := range s.workspaces {
		out.Workspaces = append(out.Workspaces, ws.desc())
		for _, t := range ws.tabs {
			for _, id := range t.root.Panes() {
				if p := s.panes[id]; p != nil {
					out.Panes = append(out.Panes, p.desc(t))
				}
			}
		}
	}
	slices.SortFunc(out.Workspaces, func(a, b rpc.WorkspaceDesc) int { return cmp.Compare(a.ID, b.ID) })
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
