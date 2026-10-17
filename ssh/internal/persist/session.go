package persist

import (
	"errors"
	"sync"
	"time"

	"github.com/aldehir/slime/ssh/internal/pty"
	"github.com/aldehir/slime/ssh/internal/vt"
)

// Session is a pty and the terminal its output is fed to, with at most
// one client attached.
type Session struct {
	id      uint32
	srv     *Server
	command string
	created time.Time
	pty     pty.Pty

	mu     sync.Mutex
	term   *vt.Terminal
	client *conn
	size   Size
	modes  []Mode // the unknown modes seen, in their current state
	done   bool
}

var errSessionDone = errors.New("session has ended")

func newSession(srv *Server, id uint32, command string, size Size, p pty.Pty, term *vt.Terminal) *Session {
	s := &Session{
		id:      id,
		srv:     srv,
		command: command,
		created: time.Now(),
		pty:     p,
		term:    term,
		size:    size,
	}
	term.SetEvents(vt.Events{
		// Answer queries while detached so the program doesn't wait on a
		// reply (ConPTY asks DA1 at startup); an attached client's own
		// terminal answers otherwise.
		Reply: func(b []byte) {
			if s.client == nil {
				s.pty.Write(b)
			}
		},
		UnknownMode: s.setMode,
	})
	return s
}

// setMode records an unknown mode's state. Runs inside term.Write,
// under s.mu.
func (s *Session) setMode(mode uint16, ansi, enabled bool) {
	for i := range s.modes {
		if s.modes[i].Mode == mode && s.modes[i].ANSI == ansi {
			s.modes[i].Enabled = enabled
			return
		}
	}
	s.modes = append(s.modes, Mode{Mode: mode, ANSI: ansi, Enabled: enabled})
}

// run copies pty output into the terminal and to the attached client
// until the child is gone.
func (s *Session) run() {
	buf := make([]byte, 32<<10)
	for {
		n, err := s.pty.Read(buf)
		if n > 0 {
			s.mu.Lock()
			s.term.Write(buf[:n])
			if c := s.client; c != nil && !c.send(s.id, &Output{Data: buf[:n]}) {
				s.detachLocked(c, "too slow")
			}
			s.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
	status, err := s.pty.Wait()
	if err != nil {
		s.srv.log.Error("waiting for child", "session", s.id, "err", err)
	}
	s.srv.log.Info("session ended", "session", s.id, "status", status)

	s.mu.Lock()
	s.done = true
	if c := s.client; c != nil {
		c.sendForce(s.id, &Exit{Status: status})
		c.unhold(s)
		s.client = nil
	}
	s.mu.Unlock()
	s.srv.remove(s)
	s.pty.Close()
	s.term.Close()
}

// attach gives the session to c, taking it from any other client, and
// queues the snapshot. Under the lock, so the live output that follows
// starts exactly where the snapshot ends.
func (s *Session) attach(c *conn, tag uint32, size Size) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.done {
		return errSessionDone
	}
	if old := s.client; old != nil && old != c {
		s.detachLocked(old, "attached elsewhere")
	}
	if size.Cols != 0 && size.Rows != 0 && size != s.size {
		s.resizeLocked(size)
	}
	snap, err := s.term.Snapshot()
	if err != nil {
		return err
	}
	c.sendForce(s.id, &Attached{
		Tag:         tag,
		SnapshotLen: uint32(len(snap)),
		Modes:       append([]Mode(nil), s.modes...),
	})
	for len(snap) > 0 {
		n := min(len(snap), SnapshotChunk)
		c.sendForce(s.id, &Snapshot{Data: snap[:n]})
		snap = snap[n:]
	}
	s.client = c
	c.hold(s)
	return nil
}

// detach releases c's attachment. reason, if set, tells the client why
// it lost a session it didn't let go of.
func (s *Session) detach(c *conn, reason string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.detachLocked(c, reason)
}

func (s *Session) detachLocked(c *conn, reason string) {
	if s.client != c {
		return
	}
	s.client = nil
	c.unhold(s)
	if reason != "" {
		c.sendForce(s.id, &Detached{Reason: reason})
	}
	s.srv.log.Info("detached", "session", s.id, "reason", reason)
}

func (s *Session) input(c *conn, data []byte) {
	s.mu.Lock()
	attached := s.client == c && !s.done
	s.mu.Unlock()
	// Outside the lock: a full input pipe blocks until the child reads,
	// and the reader needs the lock to keep draining output.
	if attached {
		s.pty.Write(data)
	}
}

func (s *Session) resize(c *conn, size Size) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.client == c && !s.done && size.Cols != 0 && size.Rows != 0 {
		s.resizeLocked(size)
	}
}

func (s *Session) resizeLocked(size Size) {
	if err := s.pty.Resize(size.Cols, size.Rows); err != nil {
		s.srv.log.Error("resizing pty", "session", s.id, "err", err)
	}
	if err := s.term.Resize(size.Cols, size.Rows, size.CellW, size.CellH); err != nil {
		s.srv.log.Error("resizing terminal", "session", s.id, "err", err)
	}
	s.size = size
}

// kill ends the child; run reports the exit and cleans up.
func (s *Session) kill() { go s.pty.Close() }

func (s *Session) info() SessionInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	info := SessionInfo{
		ID:       s.id,
		Command:  s.command,
		Cols:     s.size.Cols,
		Rows:     s.size.Rows,
		Attached: s.client != nil,
		Created:  s.created.UnixMilli(),
		PID:      s.pty.PID(),
	}
	if !s.done {
		info.Title, _ = s.term.Title()
		info.Pwd, _ = s.term.Pwd()
	}
	return info
}
