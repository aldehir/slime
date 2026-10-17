package daemon

import (
	"bytes"
	"compress/flate"
	"time"

	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/vt"
)

// Framing: how a pane's frames reach its viewers.
//
// Output only marks the pane changed and wakes its framer goroutine,
// which cuts each viewer a frame of what changed since its last one
// when three things allow: the viewer's frame interval has passed since
// its last frame, fewer than maxInFlight of its frames await an Ack, and
// nothing holds frames back (vt.Hold). Changes pile up in each viewer's
// View meanwhile, so a viewer that falls behind gets fewer, larger
// frames and nothing queues without bound, and a slow viewer doesn't
// slow the others.

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
	// The render state the viewers' frames are cut from; made with the
	// first viewer.
	source  *vt.Source
	viewers map[*conn]*paneViewer
	// Closes to stop the selection drag's autoscroll ticker; nil while
	// none runs. The drag is dragging's.
	autoscroll chan struct{}
	dragging   *paneViewer

	wake chan struct{} // buffered: the framer has something to look at
	stop chan struct{} // closed when the pane ends
}

// paneViewer is one viewer's hold on a pane: the View its frames and
// events go through, their pacing, and the size it asked for.
type paneViewer struct {
	c        *conn
	view     *vt.View
	seq      uint32 // the last frame's
	acked    uint32 // the last frame acked; the ones after are in flight
	changed  bool   // the terminal changed since its last frame
	full     bool   // the next frame has everything: a new attach
	due      dueNotices
	lastSent time.Time
	holdFrom time.Time // when the current hold began; zero if none
	timer    *time.Timer
	// The size it asked for (Resize, or an attach's); zero if none.
	size Size
}

// dueNotices are the whole-state notices a viewer's backlog dropped,
// to send again once it catches up.
type dueNotices uint8

const (
	dueTitle dueNotices = 1 << iota
	duePwd
	dueStatus
)

// startFraming runs the pane's framer until the pane ends.
func (p *Pane) startFraming() {
	p.fr.viewers = map[*conn]*paneViewer{}
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
			for _, v := range p.fr.viewers {
				p.frameLocked(v)
			}
			p.mu.Unlock()
		}
	}()
}

// stopFramingLocked ends the framer and frees the viewers' views. Under
// the lock, once the pane is done.
func (p *Pane) stopFramingLocked() {
	close(p.fr.stop)
	for c, v := range p.fr.viewers {
		p.detachFramesLocked(c, v)
	}
	if p.fr.source != nil {
		p.fr.source.Close()
		p.fr.source = nil
	}
}

// wakeFramer has the framer look at the pane. Never blocks.
func (p *Pane) wakeFramer() {
	select {
	case p.fr.wake <- struct{}{}:
	default:
	}
}

// changedLocked notes that the terminal changed, for every viewer's
// next frame.
func (p *Pane) changedLocked() {
	for _, v := range p.fr.viewers {
		v.changed = true
	}
	if len(p.fr.viewers) > 0 {
		p.wakeFramer()
	}
}

// attachFramesLocked starts c's frames of the pane with a full one,
// adding it to the viewers if it isn't one.
func (p *Pane) attachFramesLocked(c *conn) (*paneViewer, error) {
	v := p.fr.viewers[c]
	if v == nil {
		if p.fr.source == nil {
			src, err := vt.NewSource()
			if err != nil {
				return nil, err
			}
			p.fr.source = src
		}
		view, err := vt.NewView(p.fr.source)
		if err != nil {
			return nil, err
		}
		v = &paneViewer{c: c, view: view}
		p.fr.viewers[c] = v
	} else {
		// Attaching again starts over: its drag, wheel remainder, and the
		// like aren't kept.
		v.view.Reset(p.term)
		if p.fr.dragging == v {
			p.autoscrollLocked(v, false)
		}
	}
	c.sendForce(0, notify(rpc.EvPaneAttached, rpc.PaneAttachedParams{ID: p.id, Command: p.command, Status: p.status.records()}))
	// What the client would otherwise only learn when they change.
	if title, _ := p.term.Title(); title != "" {
		c.sendForce(p.id, &Notice{Kind: NoticeTitle, Text: title})
	}
	if pwd, _ := p.term.Pwd(); pwd != "" {
		c.sendForce(p.id, &Notice{Kind: NoticePwd, Text: pwd})
	}
	v.seq = 0
	v.acked = 0
	v.full = true
	v.changed = true
	v.due = 0
	v.holdFrom = time.Time{}
	v.lastSent = time.Time{}
	p.wakeFramer()
	return v, nil
}

// detachFramesLocked ends c's frames and frees its view.
func (p *Pane) detachFramesLocked(c *conn, v *paneViewer) {
	if p.fr.dragging == v {
		p.autoscrollLocked(v, false)
	}
	if v.timer != nil {
		v.timer.Stop()
	}
	v.view.Close(p.term)
	delete(p.fr.viewers, c)
}

// ack frees room for more frames to c, if it's a viewer: an Ack covers
// its frame and every one before it, so a client may ack only the last
// frame it drew.
func (p *Pane) ack(c *conn, seq uint32) {
	p.mu.Lock()
	defer p.mu.Unlock()
	v := p.fr.viewers[c]
	if v == nil || seq <= v.acked || seq > v.seq {
		return
	}
	v.acked = seq
	// Drawing a frame means the client is reading again.
	p.resendDueLocked(v)
	if v.changed {
		p.wakeFramer()
	}
}

// resendDueLocked sends v the whole-state notices its backlog dropped,
// stopping at the first that still doesn't fit.
func (p *Pane) resendDueLocked(v *paneViewer) {
	for _, d := range []struct {
		bit  dueNotices
		make func() *Notice
	}{
		{dueTitle, func() *Notice { title, _ := p.term.Title(); return &Notice{Kind: NoticeTitle, Text: title} }},
		{duePwd, func() *Notice { pwd, _ := p.term.Pwd(); return &Notice{Kind: NoticePwd, Text: pwd} }},
		{dueStatus, func() *Notice { return &Notice{Kind: NoticeStatus, Status: p.status.records()} }},
	} {
		if v.due&d.bit == 0 {
			continue
		}
		if !v.c.send(p.id, d.make()) {
			return
		}
		v.due &^= d.bit
	}
}

// frameLocked sends viewer v a frame if one is due and allowed, or
// arranges to look again when one will be.
func (p *Pane) frameLocked(v *paneViewer) {
	if p.done || !v.changed || v.seq-v.acked >= maxInFlight {
		// An Ack, a change, or an attach wakes the framer again.
		return
	}
	now := time.Now()
	if wait := v.c.interval - now.Sub(v.lastSent); wait > 0 {
		p.wakeIn(v, wait)
		return
	}
	switch v.view.Hold(p.term) {
	case vt.HoldSync:
		if p.holdingLocked(v, now, syncHold) {
			return
		}
		p.term.EndSync()
	case vt.HoldCursor:
		if p.holdingLocked(v, now, cursorHold) {
			return
		}
	}
	data, err := v.view.Frame(p.term, v.full)
	if err != nil {
		p.srv.log.Error("encoding a frame", "pane", p.id, "err", err)
		return
	}
	p.sendImagesLocked(v)
	v.seq++
	// Frames are bounded by maxInFlight rather than the queue's cap.
	v.c.sendForce(p.id, &Draw{Seq: v.seq, Data: data})
	v.changed = false
	v.full = false
	v.lastSent = now
	v.holdFrom = time.Time{}
}

// sendImagesLocked sends v the kitty images the frame just cut places
// that it lacks, each deflated and in ImageChunk pieces, ahead of the
// frame. Images aren't counted against the backlog, as frames aren't.
func (p *Pane) sendImagesLocked(v *paneViewer) {
	for i := 0; ; i++ {
		img, more := v.view.Image(p.term, i)
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
			v.c.sendForce(p.id, &Image{
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
// has time left of max, and if so wakes the framer for v when it runs
// out.
func (p *Pane) holdingLocked(v *paneViewer, now time.Time, max time.Duration) bool {
	if v.holdFrom.IsZero() {
		v.holdFrom = now
	}
	if left := max - now.Sub(v.holdFrom); left > 0 {
		p.wakeIn(v, left)
		return true
	}
	return false
}

// wakeIn wakes the framer after d, for v.
func (p *Pane) wakeIn(v *paneViewer, d time.Duration) {
	if v.timer == nil {
		v.timer = time.AfterFunc(d, p.wakeFramer)
	} else {
		v.timer.Reset(d)
	}
}
