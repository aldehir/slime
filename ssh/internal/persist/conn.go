package persist

import (
	"io"
	"log/slog"
	"sync"
)

// MaxQueued is how far behind, in bytes, a client may fall before it
// loses its attachments. Snapshots don't count.
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
	queued   int  // counted bytes in queue
	closed   bool // nothing more is sent
	draining bool // close once the queue is empty

	// Workspaces this client is attached to. Guarded by the server's
	// lock.
	owned map[uint32]*workspace
}

type queued struct {
	frame   []byte
	counted bool
}

func newConn(rw io.ReadWriteCloser, log *slog.Logger) *conn {
	c := &conn{rw: rw, log: log, owned: map[uint32]*workspace{}}
	c.cond = sync.NewCond(&c.mu)
	go c.writeLoop()
	return c
}

// send queues m. It returns false, queueing nothing, if the client is
// MaxQueued behind or gone.
func (c *conn) send(id uint32, m Message) bool { return c.enqueue(id, m, false) }

// sendForce queues m whatever the backlog: snapshots, and the messages
// that end an attachment.
func (c *conn) sendForce(id uint32, m Message) { c.enqueue(id, m, true) }

func (c *conn) enqueue(id uint32, m Message, force bool) bool {
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
