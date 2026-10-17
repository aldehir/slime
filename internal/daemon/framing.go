package daemon

import (
	"bytes"
	"compress/flate"
	"time"

	"github.com/aldehir/slime/internal/vt"
)

// Framing: how a pane's frames reach its client.
//
// Output only marks the pane changed and wakes its framer goroutine,
// which cuts a frame of what changed since the last one when three
// things allow: the client's frame interval has passed since the last
// frame, fewer than maxInFlight frames await an Ack, and nothing holds
// frames back (vt.Hold). Changes pile up in the terminal's render state
// meanwhile, so a client that falls behind gets fewer, larger frames and
// nothing queues without bound.

const (
	// defaultFrameInterval is the least time between frames when the
	// client doesn't say: 60 Hz.
	defaultFrameInterval = time.Second / 60

	// maxInFlight is how many frames may await an Ack: one being drawn
	// and one on the way keep a client busy without a backlog.
	maxInFlight = 2

	// syncHold is how long synchronized output (mode 2026) can hold
	// frames back before it's ended for the program, Ghostty's
	// sync_reset_ms.
	syncHold = time.Second

	// cursorHold is how long a frame waits for a cursor that output just
	// hid to come back (vt.HoldCursor).
	cursorHold = 4 * time.Millisecond
)

// framing is a pane's frame state. Guarded by the pane's lock.
type framing struct {
	view     *vt.View // made at the first attach
	seq      uint32   // the last frame's
	acked    uint32   // the last frame acked; the ones after are in flight
	changed  bool     // the terminal changed since the last frame
	full     bool     // the next frame has everything: a new attach
	due      dueNotices
	lastSent time.Time
	holdFrom time.Time // when the current hold began; zero if none
	// Closes to stop the selection drag's autoscroll ticker; nil while
	// none runs.
	autoscroll chan struct{}

	wake  chan struct{} // buffered: the framer has something to look at
	stop  chan struct{} // closed when the pane ends
	timer *time.Timer
}

// dueNotices are the whole-state notices the client's backlog dropped,
// to send again once it catches up.
type dueNotices uint8

const (
	dueTitle dueNotices = 1 << iota
	duePwd
	dueStatus
)

// startFraming runs the pane's framer until the pane ends.
func (p *Pane) startFraming() {
	p.fr.wake = make(chan struct{}, 1)
	p.fr.stop = make(chan struct{})
	go func() {
		for {
			select {
			case <-p.fr.wake:
			case <-p.fr.stop:
				return
			}
			p.mu.Lock()
			p.frameLocked()
			p.mu.Unlock()
		}
	}()
}

// stopFramingLocked ends the framer and frees its view. Under the lock,
// once the pane is done.
func (p *Pane) stopFramingLocked() {
	close(p.fr.stop)
	if p.fr.timer != nil {
		p.fr.timer.Stop()
	}
	if p.fr.view != nil {
		p.fr.view.Close(p.term)
		p.fr.view = nil
	}
}

// wakeFramer has the framer look at the pane. Never blocks.
func (p *Pane) wakeFramer() {
	select {
	case p.fr.wake <- struct{}{}:
	default:
	}
}

// changedLocked notes that the terminal changed, for the client's next
// frame.
func (p *Pane) changedLocked() {
	if p.client != nil {
		p.fr.changed = true
		p.wakeFramer()
	}
}

// attachFramesLocked starts c's frames of the pane with a full one.
func (p *Pane) attachFramesLocked(c *conn) error {
	if p.fr.view == nil {
		v, err := vt.NewView()
		if err != nil {
			return err
		}
		p.fr.view = v
	} else {
		// The last client's drag, wheel remainder, and the like aren't
		// this one's.
		p.fr.view.Reset(p.term)
	}
	c.sendForce(p.id, &Attached{Command: p.command, Status: p.status.records()})
	// What the client would otherwise only learn when they change.
	if title, _ := p.term.Title(); title != "" {
		c.sendForce(p.id, &Notice{Kind: NoticeTitle, Text: title})
	}
	if pwd, _ := p.term.Pwd(); pwd != "" {
		c.sendForce(p.id, &Notice{Kind: NoticePwd, Text: pwd})
	}
	p.autoscrollLocked(false)
	p.fr.seq = 0
	p.fr.acked = 0
	p.fr.full = true
	p.fr.changed = true
	p.fr.due = 0
	p.fr.holdFrom = time.Time{}
	p.fr.lastSent = time.Time{}
	p.wakeFramer()
	return nil
}

// ack frees room for more frames, if c is the pane's client: an Ack
// covers its frame and every one before it, so a client may ack only the
// last frame it drew.
func (p *Pane) ack(c *conn, seq uint32) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.client != c || seq <= p.fr.acked || seq > p.fr.seq {
		return
	}
	p.fr.acked = seq
	// Drawing a frame means the client is reading again.
	p.resendDueLocked(c)
	if p.fr.changed {
		p.wakeFramer()
	}
}

// resendDueLocked sends c the whole-state notices its backlog dropped,
// stopping at the first that still doesn't fit.
func (p *Pane) resendDueLocked(c *conn) {
	for _, d := range []struct {
		bit  dueNotices
		make func() *Notice
	}{
		{dueTitle, func() *Notice { title, _ := p.term.Title(); return &Notice{Kind: NoticeTitle, Text: title} }},
		{duePwd, func() *Notice { pwd, _ := p.term.Pwd(); return &Notice{Kind: NoticePwd, Text: pwd} }},
		{dueStatus, func() *Notice { return &Notice{Kind: NoticeStatus, Status: p.status.records()} }},
	} {
		if p.fr.due&d.bit == 0 {
			continue
		}
		if !c.send(p.id, d.make()) {
			return
		}
		p.fr.due &^= d.bit
	}
}

// frameLocked sends the client a frame if one is due and allowed, or
// arranges to look again when one will be.
func (p *Pane) frameLocked() {
	c := p.client
	if c == nil || p.done || !p.fr.changed || p.fr.seq-p.fr.acked >= maxInFlight {
		// An Ack, a change, or an attach wakes the framer again.
		return
	}
	now := time.Now()
	if wait := c.interval - now.Sub(p.fr.lastSent); wait > 0 {
		p.wakeIn(wait)
		return
	}
	switch p.fr.view.Hold(p.term) {
	case vt.HoldSync:
		if p.holdingLocked(now, syncHold) {
			return
		}
		p.term.EndSync()
	case vt.HoldCursor:
		if p.holdingLocked(now, cursorHold) {
			return
		}
	}
	data, err := p.fr.view.Frame(p.term, p.fr.full)
	if err != nil {
		p.srv.log.Error("encoding a frame", "pane", p.id, "err", err)
		return
	}
	p.sendImagesLocked(c)
	p.fr.seq++
	// Frames are bounded by maxInFlight rather than the queue's cap.
	c.sendForce(p.id, &Draw{Seq: p.fr.seq, Data: data})
	p.fr.changed = false
	p.fr.full = false
	p.fr.lastSent = now
	p.fr.holdFrom = time.Time{}
}

// sendImagesLocked sends c the kitty images the frame just cut places
// that it lacks, each deflated and in ImageChunk pieces, ahead of the
// frame. Images aren't counted against the backlog, as frames aren't.
func (p *Pane) sendImagesLocked(c *conn) {
	for i := 0; ; i++ {
		img, more := p.fr.view.Image(p.term, i)
		if !more {
			return
		}
		if img == nil {
			p.srv.log.Warn("an image placed in a frame is gone", "pane", p.id)
			continue
		}
		var buf bytes.Buffer
		// Pixels compress well enough at the fastest level, and a frame
		// waits on this.
		w, _ := flate.NewWriter(&buf, flate.BestSpeed)
		w.Write(img.RGBA)
		w.Close()
		data := buf.Bytes()
		total := uint32(len(data))
		for off := uint32(0); off < total; {
			n := min(total-off, ImageChunk)
			c.sendForce(p.id, &Image{
				ID:         img.ID,
				Generation: img.Generation,
				Width:      img.Width,
				Height:     img.Height,
				Total:      total,
				Offset:     off,
				Data:       data[off : off+n],
			})
			off += n
		}
	}
}

// holdingLocked reports whether a hold that began now or earlier still
// has time left of max, and if so wakes the framer when it runs out.
func (p *Pane) holdingLocked(now time.Time, max time.Duration) bool {
	if p.fr.holdFrom.IsZero() {
		p.fr.holdFrom = now
	}
	if left := max - now.Sub(p.fr.holdFrom); left > 0 {
		p.wakeIn(left)
		return true
	}
	return false
}

// wakeIn wakes the framer after d.
func (p *Pane) wakeIn(d time.Duration) {
	if p.fr.timer == nil {
		p.fr.timer = time.AfterFunc(d, p.wakeFramer)
	} else {
		p.fr.timer.Reset(d)
	}
}
