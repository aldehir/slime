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
	status programStatus
	done   bool
	fr     framing
	// What the terminal answered its program since the last take, for
	// the child: written outside the lock (writeReplies).
	replies []byte
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
		// reply (ConPTY asks DA1 at startup), and always for a client that
		// draws frames; a client running its own terminal answers
		// otherwise.
		Reply: func(b []byte) {
			if c := pn.client; c == nil || c.frames {
				pn.replies = append(pn.replies, b...)
			}
		},
		UnknownMode: pn.setMode,
		ProgramStatus: func(s vt.Status) {
			pn.status.report(s)
			pn.statusChanged()
		},
		PromptStart: func() {
			pn.status.promptStarted()
			pn.statusChanged()
		},
		// A client that draws has no terminal to learn these from.
		TitleChanged: func() {
			title, _ := pn.term.Title()
			pn.notify(&Notice{Kind: NoticeTitle, Text: title})
		},
		PwdChanged: func() {
			pwd, _ := pn.term.Pwd()
			pn.notify(&Notice{Kind: NoticePwd, Text: pwd})
		},
		Bell:           func() { pn.notify(&Notice{Kind: NoticeBell}) },
		ClipboardWrite: func(text []byte) { pn.notify(&Notice{Kind: NoticeClipboard, Text: string(text)}) },
	})
	pn.startFraming()
	return pn
}

// notify sends a client that draws a Notice. Runs inside term.Write,
// under p.mu. Notices count against the client's backlog, and one that
// doesn't fit is dropped: a program retitling on every write can't grow
// the queue. A dropped title, pwd, or status is the whole state, and is
// sent again once the client catches up (resendDueLocked); a bell or
// clipboard write is lost.
func (p *Pane) notify(n *Notice) {
	c := p.client
	if c == nil || !c.frames || c.send(p.id, n) {
		return
	}
	switch n.Kind {
	case NoticeTitle:
		p.fr.due |= dueTitle
	case NoticePwd:
		p.fr.due |= duePwd
	case NoticeStatus:
		p.fr.due |= dueStatus
	}
}

// statusChanged sends a client that draws every status record. Runs
// inside term.Write, under p.mu.
func (p *Pane) statusChanged() {
	p.notify(&Notice{Kind: NoticeStatus, Status: p.status.records()})
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

// takeRepliesLocked returns what the terminal answered since the last
// take, for writeReplies once the lock is released: a full input pipe
// blocks until the child reads, and the reader needs the lock to keep
// draining output.
func (p *Pane) takeRepliesLocked() []byte {
	r := p.replies
	p.replies = nil
	return r
}

func (p *Pane) writeReplies(b []byte) {
	if len(b) > 0 {
		p.pty.Write(b)
	}
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
			if c := p.client; c != nil && c.frames {
				p.changedLocked()
			} else if c != nil && !c.send(p.id, &Output{Data: buf[:n]}) {
				// Too far behind: drop the connection, which detaches its
				// workspaces. Reattaching is a snapshot away.
				p.srv.log.Info("client too slow; dropping it", "pane", p.id)
				c.close()
			}
			replies := p.takeRepliesLocked()
			p.mu.Unlock()
			p.writeReplies(replies)
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
	p.stopFramingLocked()
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
	err := p.attachLocked(c, size)
	// A resize can answer a program's size query (mode 2048).
	replies := p.takeRepliesLocked()
	p.mu.Unlock()
	p.writeReplies(replies)
	return err
}

func (p *Pane) attachLocked(c *conn, size Size) error {
	if p.done {
		return nil
	}
	if size.Cols != 0 && size.Rows != 0 && size != p.size {
		p.resizeLocked(size)
	}
	if c.frames {
		if err := p.attachFramesLocked(c); err != nil {
			return err
		}
	} else if err := p.snapshotTo(c, 0); err != nil {
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
		Status:      p.status.records(),
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
		p.autoscrollLocked(false)
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
	if p.client == c && !p.done && size.Cols != 0 && size.Rows != 0 && size != p.size {
		p.resizeLocked(size)
	}
	replies := p.takeRepliesLocked()
	p.mu.Unlock()
	p.writeReplies(replies)
}

func (p *Pane) resizeLocked(size Size) {
	if err := p.pty.Resize(size.Cols, size.Rows, uint32(size.Cols)*size.CellW, uint32(size.Rows)*size.CellH); err != nil {
		p.srv.log.Error("resizing pty", "pane", p.id, "err", err)
	}
	if err := p.term.Resize(size.Cols, size.Rows, size.CellW, size.CellH); err != nil {
		p.srv.log.Error("resizing terminal", "pane", p.id, "err", err)
	}
	p.size = size
	p.changedLocked()
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
