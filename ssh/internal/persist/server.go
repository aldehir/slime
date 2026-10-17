// Package persist is slimed: a daemon that owns ptys and the terminal
// state of each (internal/vt), so sessions outlive the clients attached
// to them. A client attaches with a snapshot of the terminal and then
// gets the live output from where the snapshot ends.
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

// Server holds the sessions and serves clients.
type Server struct {
	vt    *vt.Runtime
	spawn func(pty.Options) (pty.Pty, error)
	log   *slog.Logger
	idle  time.Duration

	snapshotVersion uint16

	mu       sync.Mutex
	nextID   uint32
	sessions map[uint32]*Session
	conns    map[*conn]struct{}
	idleT    *time.Timer
	idleC    chan struct{} // closed when the idle timer fires
}

// Options configure a Server.
type Options struct {
	// Spawn starts a session's child; pty.Start if nil.
	Spawn func(pty.Options) (pty.Pty, error)
	Log   *slog.Logger
	// Idle is how long Serve waits with no sessions and no clients
	// before returning. Zero waits forever.
	Idle time.Duration
}

func NewServer(rt *vt.Runtime, opts Options) (*Server, error) {
	if opts.Spawn == nil {
		opts.Spawn = pty.Start
	}
	if opts.Log == nil {
		opts.Log = slog.New(slog.DiscardHandler)
	}
	s := &Server{
		vt:       rt,
		spawn:    opts.Spawn,
		log:      opts.Log,
		idle:     opts.Idle,
		sessions: map[uint32]*Session{},
		conns:    map[*conn]struct{}{},
		idleC:    make(chan struct{}),
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
	idle := len(s.sessions) == 0 && len(s.conns) == 0
	switch {
	case idle && s.idleT == nil:
		s.idleT = time.AfterFunc(s.idle, func() {
			s.mu.Lock()
			defer s.mu.Unlock()
			if s.idleT != nil && len(s.sessions) == 0 && len(s.conns) == 0 {
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
		for _, ss := range c.takeHeld() {
			ss.detach(c, "")
		}
		c.close()
		s.mu.Lock()
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
	switch m := m.(type) {
	case *List:
		c.sendForce(0, &Sessions{Sessions: s.list()})
	case *New:
		s.newSession(c, m)
	case *Attach:
		ss := s.session(id)
		if ss == nil {
			c.sendForce(id, &Error{Tag: m.Tag, Message: "no such session"})
			return
		}
		if err := ss.attach(c, m.Tag, m.Size); err != nil {
			c.sendForce(id, &Error{Tag: m.Tag, Message: err.Error()})
		}
	case *Detach:
		if ss := c.holding(id); ss != nil {
			ss.detach(c, "")
		}
	case *Input:
		if ss := c.holding(id); ss != nil {
			ss.input(c, m.Data)
		}
	case *Resize:
		if ss := c.holding(id); ss != nil {
			ss.resize(c, m.Size)
		}
	case *Kill:
		if ss := s.session(id); ss != nil {
			ss.kill()
		}
	default:
		s.log.Warn("unexpected message", "type", m.Type())
	}
}

func (s *Server) newSession(c *conn, m *New) {
	size := m.Size
	if size.Cols == 0 || size.Rows == 0 {
		size.Cols, size.Rows = 80, 24
	}
	term, err := s.vt.New(size.Cols, size.Rows)
	if err == nil {
		err = term.Resize(size.Cols, size.Rows, size.CellW, size.CellH)
		if err != nil {
			term.Close()
		}
	}
	if err != nil {
		c.sendForce(0, &Error{Tag: m.Tag, Message: err.Error()})
		return
	}
	p, err := s.spawn(pty.Options{Command: m.Command, Dir: m.Cwd, Cols: size.Cols, Rows: size.Rows})
	if err != nil {
		term.Close()
		c.sendForce(0, &Error{Tag: m.Tag, Message: err.Error()})
		return
	}
	s.mu.Lock()
	s.nextID++
	ss := newSession(s, s.nextID, m.Command, size, p, term)
	s.sessions[ss.id] = ss
	s.checkIdleLocked()
	s.mu.Unlock()
	s.log.Info("session started", "session", ss.id, "command", m.Command, "pid", p.PID())

	if err := ss.attach(c, m.Tag, Size{}); err != nil {
		c.sendForce(ss.id, &Error{Tag: m.Tag, Message: err.Error()})
	}
	go ss.run()
}

func (s *Server) session(id uint32) *Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sessions[id]
}

func (s *Server) remove(ss *Session) {
	s.mu.Lock()
	delete(s.sessions, ss.id)
	s.checkIdleLocked()
	s.mu.Unlock()
}

func (s *Server) list() []SessionInfo {
	s.mu.Lock()
	ss := make([]*Session, 0, len(s.sessions))
	for _, x := range s.sessions {
		ss = append(ss, x)
	}
	s.mu.Unlock()
	infos := make([]SessionInfo, len(ss))
	for i, x := range ss {
		infos[i] = x.info()
	}
	slices.SortFunc(infos, func(a, b SessionInfo) int { return cmp.Compare(a.ID, b.ID) })
	return infos
}

// Close kills every session.
func (s *Server) Close() {
	s.mu.Lock()
	ss := make([]*Session, 0, len(s.sessions))
	for _, x := range s.sessions {
		ss = append(ss, x)
	}
	s.mu.Unlock()
	for _, x := range ss {
		x.pty.Close()
	}
}
