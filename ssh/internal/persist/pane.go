package persist

import (
	"sync"
	"time"

	"github.com/aldehir/slime/ssh/internal/pty"
	"github.com/aldehir/slime/ssh/internal/vt"
)

// Pane is a pty and the terminal its output is fed to. Its client is the
// owner of its workspace, set by the server as workspaces are attached
// and detached.
type Pane struct {
	id      uint32
	srv     *Server
	command string
	created time.Time
	pty     pty.Pty

	// The tab it's in. Guarded by the server's lock.
	tab *tab

	mu     sync.Mutex
	term   *vt.Terminal
	client *conn
	size   Size
	modes  []Mode // the unknown modes seen, in their current state
	done   bool
}

func newPane(srv *Server, id uint32, command string, size Size, p pty.Pty, term *vt.Terminal) *Pane {
	pn := &Pane{
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
			if pn.client == nil {
				pn.pty.Write(b)
			}
		},
		UnknownMode: pn.setMode,
	})
	return pn
}

// setMode records an unknown mode's state. Runs inside term.Write,
// under p.mu.
func (p *Pane) setMode(mode uint16, ansi, enabled bool) {
	for i := range p.modes {
		if p.modes[i].Mode == mode && p.modes[i].ANSI == ansi {
			p.modes[i].Enabled = enabled
			return
		}
	}
	p.modes = append(p.modes, Mode{Mode: mode, ANSI: ansi, Enabled: enabled})
}

// run copies pty output into the terminal and to the client until the
// child is gone, then takes the pane out of its tab.
func (p *Pane) run() {
	buf := make([]byte, 32<<10)
	for {
		n, err := p.pty.Read(buf)
		if n > 0 {
			p.mu.Lock()
			p.term.Write(buf[:n])
			if c := p.client; c != nil && !c.send(p.id, &Output{Data: buf[:n]}) {
				// Too far behind: drop the connection, which detaches its
				// workspaces. Reattaching is a snapshot away.
				p.srv.log.Info("client too slow; dropping it", "pane", p.id)
				c.close()
			}
			p.mu.Unlock()
		}
		if err != nil {
			break
		}
	}
	status, err := p.pty.Wait()
	if err != nil {
		p.srv.log.Error("waiting for child", "pane", p.id, "err", err)
	}
	p.srv.log.Info("pane ended", "pane", p.id, "status", status)

	p.mu.Lock()
	p.done = true
	if c := p.client; c != nil {
		c.sendForce(p.id, &Exit{Status: status})
		p.client = nil
	}
	p.mu.Unlock()
	p.srv.paneExited(p)
	p.pty.Close()
	p.term.Close()
}

// attach gives the pane to c, resized to size if that's set, and queues
// the snapshot. Under the lock, so the live output that follows starts
// exactly where the snapshot ends.
func (p *Pane) attach(c *conn, size Size) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.done {
		return nil
	}
	if size.Cols != 0 && size.Rows != 0 && size != p.size {
		p.resizeLocked(size)
	}
	if err := p.snapshotTo(c, 0); err != nil {
		return err
	}
	p.client = c
	return nil
}

// peek sends c the pane's snapshot without attaching it.
func (p *Pane) peek(c *conn, tag uint32) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.snapshotTo(c, tag)
}

func (p *Pane) snapshotTo(c *conn, tag uint32) error {
	snap, err := p.term.Snapshot()
	if err != nil {
		return err
	}
	c.sendForce(p.id, &Attached{
		Tag:         tag,
		SnapshotLen: uint32(len(snap)),
		Modes:       append([]Mode(nil), p.modes...),
		Command:     p.command,
	})
	for len(snap) > 0 {
		n := min(len(snap), SnapshotChunk)
		c.sendForce(p.id, &Snapshot{Data: snap[:n]})
		snap = snap[n:]
	}
	return nil
}

// detach releases c's attachment, if it has one.
func (p *Pane) detach(c *conn) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.client == c {
		p.client = nil
	}
}

func (p *Pane) input(c *conn, data []byte) {
	p.mu.Lock()
	attached := p.client == c && !p.done
	p.mu.Unlock()
	// Outside the lock: a full input pipe blocks until the child reads,
	// and the reader needs the lock to keep draining output.
	if attached {
		p.pty.Write(data)
	}
}

// resize sizes the pane for c, its client; with c nil, for the daemon
// itself (a workspace no window shows).
func (p *Pane) resize(c *conn, size Size) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.client == c && !p.done && size.Cols != 0 && size.Rows != 0 && size != p.size {
		p.resizeLocked(size)
	}
}

func (p *Pane) resizeLocked(size Size) {
	if err := p.pty.Resize(size.Cols, size.Rows); err != nil {
		p.srv.log.Error("resizing pty", "pane", p.id, "err", err)
	}
	if err := p.term.Resize(size.Cols, size.Rows, size.CellW, size.CellH); err != nil {
		p.srv.log.Error("resizing terminal", "pane", p.id, "err", err)
	}
	p.size = size
}

// cell is the pane's cell size in pixels, as its window last sized it:
// panes can differ, each with its own font. Zero if never said.
func (p *Pane) cell() Size {
	p.mu.Lock()
	defer p.mu.Unlock()
	return Size{CellW: p.size.CellW, CellH: p.size.CellH}
}

// kill ends the child; run reports the exit and cleans up.
func (p *Pane) kill() { go p.pty.Close() }

func (p *Pane) info(tab uint32) PaneInfo {
	p.mu.Lock()
	defer p.mu.Unlock()
	info := PaneInfo{
		ID:      p.id,
		Tab:     tab,
		Command: p.command,
		Cols:    p.size.Cols,
		Rows:    p.size.Rows,
		Created: p.created.UnixMilli(),
		PID:     p.pty.PID(),
	}
	if !p.done {
		info.Title, _ = p.term.Title()
		info.Pwd, _ = p.term.Pwd()
	}
	return info
}
