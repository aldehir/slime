package daemon

import (
	"time"

	"github.com/aldehir/slime/internal/vt"
)

// Events: input from the client, which the pane's View turns into input
// for the child, selection, scrolling, and copies against the daemon's
// terminal. See internal/vt/event.zig.

// event handles an event from c, if c owns the pane.
func (p *Pane) event(c *conn, data []byte) {
	p.mu.Lock()
	if p.client != c || p.done || p.fr.view == nil {
		p.mu.Unlock()
		return
	}
	r, err := p.fr.view.Event(p.term, p.win32InputLocked(), data)
	if err != nil {
		p.mu.Unlock()
		p.srv.log.Warn("bad event", "pane", p.id, "err", err)
		return
	}
	// The View's bytes are only good until its next call.
	input := append([]byte(nil), r.Pty...)
	if r.Copied {
		text := r.Text
		if max := MaxFrame - 64; len(text) > max {
			p.srv.log.Warn("copy cut short", "pane", p.id, "bytes", len(text))
			text = text[:max]
		}
		c.sendForce(p.id, &Copied{Tag: r.CopyTag, Text: string(text)})
	}
	if r.Changed {
		p.changedLocked()
	}
	p.autoscrollLocked(r.Autoscroll)
	p.mu.Unlock()

	// Outside the lock: a full input pipe blocks until the child reads,
	// and the reader needs the lock to keep draining output. Events from
	// one client come one at a time, so their input stays in order.
	if len(input) > 0 {
		p.pty.Write(input)
	}
}

// win32InputLocked reports whether the program asked for win32-input-mode
// (DEC 9001), which libghostty-vt leaves to us: ConPTY turns it on.
func (p *Pane) win32InputLocked() bool {
	for _, m := range p.modes {
		if m.num == 9001 && !m.ansi {
			return m.enabled
		}
	}
	return false
}

// autoscrollLocked runs or stops the ticker that scrolls toward a
// selection drag past an edge.
func (p *Pane) autoscrollLocked(on bool) {
	if on == (p.fr.autoscroll != nil) {
		return
	}
	if !on {
		close(p.fr.autoscroll)
		p.fr.autoscroll = nil
		return
	}
	stop := make(chan struct{})
	p.fr.autoscroll = stop
	go func() {
		t := time.NewTicker(vt.AutoscrollInterval)
		defer t.Stop()
		for {
			select {
			case <-t.C:
			case <-stop:
				return
			case <-p.fr.stop:
				return
			}
			p.mu.Lock()
			if p.fr.autoscroll != stop || p.done {
				p.mu.Unlock()
				return
			}
			r := p.fr.view.Autoscroll(p.term)
			if r.Changed {
				p.changedLocked()
			}
			if !r.Autoscroll {
				p.fr.autoscroll = nil
				p.mu.Unlock()
				return
			}
			p.mu.Unlock()
		}
	}()
}
