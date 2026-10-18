package daemon

import (
	"errors"
	"strings"
	"sync"
	"time"

	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/vt"
)

// Pane is a pty and the terminal its output is fed to. Its viewers are
// its workspace's, set by the server as workspaces are attached and
// detached; each gets its own frames of the one terminal.
type Pane struct {
	// Its id, which changes when it moves tabs. Guarded by the server's
	// lock and the pane's: written under both, read under either.
	id      PaneID
	srv     *Server
	command string
	created time.Time
	pty     pty.Pty

	// The tab it's in. Guarded by the server's lock.
	tab *tab

	mu   sync.Mutex
	term *vt.Terminal
	// The size the pty and terminal have: the smallest its viewers asked
	// for, or the daemon's own while none has.
	size   Size
	modes  []mode
	status programStatus
	done   bool
	fr     framing
	// What the terminal answered its program since the last take, for
	// the child: written outside the lock (writeReplies).
	replies []byte
}

func newPane(srv *Server, id PaneID, command string, size Size, p pty.Pty, term *vt.Terminal) *Pane {
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
		// The daemon's terminal answers queries (ConPTY asks DA1 at
		// startup): the clients have none of their own to.
		Reply:       func(b []byte) { pn.replies = append(pn.replies, b...) },
		UnknownMode: pn.setMode,
		ProgramStatus: func(s vt.Status) {
			pn.status.report(s)
			pn.statusChanged()
		},
		PromptStart: func() {
			pn.status.promptStarted()
			pn.statusChanged()
		},
		// The clients have no terminal to learn these from.
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

// notify sends every viewer a Notice. Runs inside term.Write, under
// p.mu. Notices count against a viewer's backlog, and one that doesn't
// fit is dropped: a program retitling on every write can't grow the
// queue. A dropped title, pwd, or status is the whole state, and is
// sent again once the viewer catches up (resendDueLocked); a bell or
// clipboard write is lost.
func (p *Pane) notify(n *Notice) {
	for c, v := range p.fr.viewers {
		if c.send(p.id, n) {
			continue
		}
		switch n.Kind {
		case NoticeTitle:
			v.due |= dueTitle
		case NoticePwd:
			v.due |= duePwd
		case NoticeStatus:
			v.due |= dueStatus
		}
	}
}

// statusChanged sends the viewers every status record. Runs inside
// term.Write, under p.mu.
func (p *Pane) statusChanged() {
	p.notify(&Notice{Kind: NoticeStatus, Status: p.status.records()})
}

// mode is the state of a mode libghostty-vt leaves to us
// (win32-input-mode), as the program last set it.
type mode struct {
	num     uint16
	ansi    bool
	enabled bool
}

// setMode records an unknown mode's state. Runs inside term.Write,
// under p.mu.
func (p *Pane) setMode(num uint16, ansi, enabled bool) {
	for i := range p.modes {
		if p.modes[i].num == num && p.modes[i].ansi == ansi {
			p.modes[i].enabled = enabled
			return
		}
	}
	p.modes = append(p.modes, mode{num: num, ansi: ansi, enabled: enabled})
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

// run copies pty output into the terminal, framing it for the viewers,
// until the child is gone, then takes the pane out of its tab.
func (p *Pane) run() {
	buf := make([]byte, 32<<10)
	for {
		n, err := p.pty.Read(buf)
		if n > 0 {
			p.mu.Lock()
			p.term.Write(buf[:n])
			p.changedLocked()
			replies := p.takeRepliesLocked()
			p.mu.Unlock()
			p.writeReplies(replies)
		}
		if err != nil {
			break
		}
	}
	status, err := p.pty.Wait()
	p.mu.Lock()
	if err != nil {
		p.srv.log.Error("waiting for child", "pane", p.id, "err", err)
	}
	p.srv.log.Info("pane ended", "pane", p.id, "status", status)
	p.done = true
	// The viewers hear in order with the pane's frames; the subscribers
	// from paneExited.
	var told []*conn
	exited := notify(rpc.EvPaneExited, rpc.PaneExitedParams{ID: p.id, Status: status})
	for c := range p.fr.viewers {
		c.sendForce(NoPane, exited)
		told = append(told, c)
	}
	p.stopFramingLocked()
	p.mu.Unlock()
	p.srv.paneExited(p, status, told)
	p.pty.Close()
	p.term.Close()
}

// write sends b to the child as typed: pane.write. Outside the lock, as
// events' input goes.
func (p *Pane) write(b []byte) error {
	p.mu.Lock()
	done := p.done
	p.mu.Unlock()
	if done {
		return errors.New("pane ended")
	}
	_, err := p.pty.Write(b)
	return err
}

// attach adds c to the pane's viewers, asking for size if that's set,
// and starts its frames. from is the id the pane had if it just moved
// tabs (zero otherwise), for the viewer to let go of.
func (p *Pane) attach(c *conn, size Size, from PaneID) error {
	p.mu.Lock()
	err := p.attachLocked(c, size, from)
	// A resize can answer a program's size query (mode 2048).
	replies := p.takeRepliesLocked()
	p.mu.Unlock()
	p.writeReplies(replies)
	return err
}

func (p *Pane) attachLocked(c *conn, size Size, from PaneID) error {
	if p.done {
		return nil
	}
	v, err := p.attachFramesLocked(c, from)
	if err != nil {
		return err
	}
	if size.Cols != 0 && size.Rows != 0 {
		v.size = size
		p.fitLocked()
	}
	return nil
}

// text is the pane's screen and scrollback without attaching it: plain,
// or the VT that redraws it. Plain text past what a message holds loses
// its oldest lines.
func (p *Pane) text(asVT bool) (string, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.done {
		return "", errors.New("pane ended")
	}
	// JSON escaping can double the text; leave room in the frame.
	const max = MaxFrame / 4
	if asVT {
		b, err := p.term.VT()
		if err != nil {
			return "", err
		}
		if len(b) > max {
			return "", errors.New("too much to send")
		}
		return string(b), nil
	}
	s, err := p.term.Text()
	if err != nil {
		return "", err
	}
	if len(s) > max {
		s = s[len(s)-max:]
		if i := strings.IndexByte(s, '\n'); i >= 0 {
			s = s[i+1:]
		}
	}
	return s, nil
}

// detach releases c's attachment, if it has one. The pane may grow to
// the viewers left.
func (p *Pane) detach(c *conn) {
	p.mu.Lock()
	v := p.fr.viewers[c]
	if v != nil {
		p.detachFramesLocked(c, v)
		if len(p.fr.viewers) > 0 {
			p.fitLocked()
		}
	}
	replies := p.takeRepliesLocked()
	p.mu.Unlock()
	p.writeReplies(replies)
}

// resize sizes the pane for c, one of its viewers: it gets the
// smallest size its viewers ask for. With c nil, for the daemon itself
// (a workspace no window shows).
func (p *Pane) resize(c *conn, size Size) {
	p.mu.Lock()
	if !p.done && size.Cols != 0 && size.Rows != 0 {
		if c == nil {
			if len(p.fr.viewers) == 0 && size != p.size {
				p.resizeLocked(size)
			}
		} else if v := p.fr.viewers[c]; v != nil {
			v.size = size
			p.fitLocked()
		}
	}
	replies := p.takeRepliesLocked()
	p.mu.Unlock()
	p.writeReplies(replies)
}

// fitLocked sizes the pane to the smallest its viewers asked for: the
// fewest columns and the fewest rows, as tmux does, with the cell size
// of the viewer with the least room. Viewers that haven't asked don't
// count.
func (p *Pane) fitLocked() {
	var want Size
	var least uint64
	for _, v := range p.fr.viewers {
		if v.size.Cols == 0 || v.size.Rows == 0 {
			continue
		}
		room := uint64(v.size.Cols) * uint64(v.size.Rows)
		if want.Cols == 0 || room < least {
			least = room
			want.CellW, want.CellH = v.size.CellW, v.size.CellH
		}
		if want.Cols == 0 || v.size.Cols < want.Cols {
			want.Cols = v.size.Cols
		}
		if want.Rows == 0 || v.size.Rows < want.Rows {
			want.Rows = v.size.Rows
		}
	}
	if want.Cols != 0 && want != p.size {
		p.srv.log.Debug("pane fit", "pane", p.id, "size", want, "viewers", len(p.fr.viewers))
		p.resizeLocked(want)
	}
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

// cell is the pane's cell size in pixels, as its viewers last sized it:
// panes can differ, each with its own font. Zero if never said.
func (p *Pane) cell() Size {
	p.mu.Lock()
	defer p.mu.Unlock()
	return Size{CellW: p.size.CellW, CellH: p.size.CellH}
}

// kill ends the child; run reports the exit and cleans up.
func (p *Pane) kill() { go p.pty.Close() }

// renameLocked gives the pane the id it has in its new tab. Under the
// server's lock.
func (p *Pane) renameLocked(id PaneID) {
	p.mu.Lock()
	p.id = id
	p.mu.Unlock()
}

// desc describes the pane as workspace.list and pane.info do.
func (p *Pane) desc() rpc.PaneDesc {
	p.mu.Lock()
	defer p.mu.Unlock()
	d := rpc.PaneDesc{
		ID:      p.id,
		Command: p.command,
		Cols:    p.size.Cols,
		Rows:    p.size.Rows,
		Created: p.created.UnixMilli(),
		PID:     p.pty.PID(),
		Status:  p.status.records(),
	}
	if !p.done {
		d.Title, _ = p.term.Title()
		d.Pwd, _ = p.term.Pwd()
	}
	return d
}
