package daemon

import (
	"io"
	"log/slog"
	"sync"
	"time"
)

// MaxQueued is how far behind, in bytes, a client may be before notices
// to it are dropped (Pane.notify). Frames and images don't count: they
// pace themselves (framing.go).
const MaxQueued = 16 << 20

// conn is one client connection. Frames go out through a queue drained
// by its own goroutine, so a slow client never blocks a session's
// reader.
type conn struct {
	rw  io.ReadWriteCloser
	log *slog.Logger

	mu       sync.Mutex
	cond     *sync.Cond
	queue    []queued
	queued   int           // counted bytes in queue
	closed   bool          // nothing more is sent
	draining bool          // close once the queue is empty
	done     chan struct{} // closed when the write loop has exited

	// Workspaces this client views, and the events it subscribed to
	// beyond theirs. Guarded by the server's lock.
	viewing map[uint32]*workspace
	subs    []string

	// Set by the handshake: the least time between a pane's frames.
	interval time.Duration
}

type queued struct {
	frame   []byte
	counted bool
}

func newConn(rw io.ReadWriteCloser, log *slog.Logger) *conn {
	c := &conn{rw: rw, log: log, viewing: map[uint32]*workspace{}, done: make(chan struct{})}
	c.cond = sync.NewCond(&c.mu)
	go c.writeLoop()
	return c
}

// send queues m. It returns false, queueing nothing, if the client is
// MaxQueued behind or gone.
func (c *conn) send(id PaneID, m Message) bool { return c.enqueue(id, m, false) }

// sendForce queues m whatever the backlog: frames, images, and the
// messages that start or end an attachment.
func (c *conn) sendForce(id PaneID, m Message) { c.enqueue(id, m, true) }

func (c *conn) enqueue(id PaneID, m Message, force bool) bool {
	b, err := Encode(id, m)
	if err != nil {
		c.log.Error("encoding", "type", m.Type(), "err", err)
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.draining {
		return false
	}
	if !force {
		if c.queued+len(b) > MaxQueued {
			return false
		}
		c.queued += len(b)
	}
	c.queue = append(c.queue, queued{b, !force})
	c.cond.Signal()
	return true
}

func (c *conn) writeLoop() {
	defer close(c.done)
	for {
		c.mu.Lock()
		for len(c.queue) == 0 && !c.closed && !c.draining {
			c.cond.Wait()
		}
		if c.closed || (c.draining && len(c.queue) == 0) {
			c.mu.Unlock()
			c.close()
			return
		}
		batch := c.queue
		c.queue = nil
		c.mu.Unlock()

		for _, q := range batch {
			if _, err := c.rw.Write(q.frame); err != nil {
				c.close()
				return
			}
			if q.counted {
				c.mu.Lock()
				c.queued -= len(q.frame)
				c.mu.Unlock()
			}
		}
	}
}

// closeAfterFlush closes the connection once what's queued is written.
func (c *conn) closeAfterFlush() {
	c.mu.Lock()
	c.draining = true
	c.cond.Broadcast()
	c.mu.Unlock()
}

func (c *conn) close() {
	c.mu.Lock()
	if !c.closed {
		c.closed = true
		c.cond.Broadcast()
	}
	c.mu.Unlock()
	c.rw.Close()
}
