package daemon

import (
	"encoding/json"
	"fmt"
	"io"
	"sync"

	"github.com/aldehir/slime/internal/rpc"
)

// Client is the client end of a connection, for slime's own commands
// and tests: a JSON-RPC client over the wire. The GUI speaks the
// protocol itself.
type Client struct {
	rw    io.ReadWriteCloser
	r     *Reader
	mu    sync.Mutex // writes
	id    uint32
	Hello HelloReply
	// What came while Call waited for its reply, for Recv to hand out
	// first: a client that also draws a workspace loses nothing.
	backlog []pending
}

type pending struct {
	id PaneID
	m  Message
}

// NewClient says hello over rw.
func NewClient(rw io.ReadWriteCloser) (*Client, error) {
	return NewClientWith(rw, Hello{})
}

// NewClientWith says hello over rw with hello's settings; its Version
// is filled in.
func NewClientWith(rw io.ReadWriteCloser, hello Hello) (*Client, error) {
	c := &Client{rw: rw, r: NewReader(rw)}
	hello.Version = Version
	if err := c.Send(NoPane, &hello); err != nil {
		return nil, err
	}
	_, m, err := c.Recv()
	if err != nil {
		return nil, err
	}
	switch m := m.(type) {
	case *HelloReply:
		c.Hello = *m
	case *Error:
		return nil, fmt.Errorf("daemon: %s", m.Message)
	default:
		return nil, fmt.Errorf("daemon: expected hello, got type %d", m.Type())
	}
	if c.Hello.Version != Version {
		return nil, fmt.Errorf("daemon: slime speaks version %d, not %d", c.Hello.Version, Version)
	}
	return c, nil
}

func (c *Client) Send(id PaneID, m Message) error {
	b, err := Encode(id, m)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	_, err = c.rw.Write(b)
	return err
}

// Recv reads the next message and the pane it's for: what a Call set
// aside first, then the connection.
func (c *Client) Recv() (PaneID, Message, error) {
	if len(c.backlog) > 0 {
		p := c.backlog[0]
		c.backlog = c.backlog[1:]
		return p.id, p.m, nil
	}
	return c.read()
}

func (c *Client) read() (PaneID, Message, error) {
	f, err := c.r.Read()
	if err != nil {
		return NoPane, nil, err
	}
	m, err := Decode(f)
	return f.ID, m, err
}

func (c *Client) Close() error { return c.rw.Close() }

// NextID returns an id for a call.
func (c *Client) NextID() uint32 {
	c.id++
	return c.id
}

// Call sends a method call and reads until its reply, setting aside
// what comes before it for Recv. The result goes into result (JSON
// unmarshalling; nil to drop it). A reply with an error is returned as
// an *rpc.Error.
func (c *Client) Call(method string, params, result any) error {
	id := c.NextID()
	req := rpc.Request{JSONRPC: "2.0", ID: id, Method: method}
	if params != nil {
		b, err := json.Marshal(params)
		if err != nil {
			return err
		}
		req.Params = b
	}
	if err := c.Send(NoPane, &Call{Request: req}); err != nil {
		return err
	}
	for {
		pane, m, err := c.read()
		if err != nil {
			return err
		}
		r, ok := m.(*Reply)
		if !ok || r.Response.ID != id {
			c.backlog = append(c.backlog, pending{pane, m})
			continue
		}
		if r.Response.Error != nil {
			return r.Response.Error
		}
		if result == nil || len(r.Response.Result) == 0 {
			return nil
		}
		return json.Unmarshal(r.Response.Result, result)
	}
}

// Notification returns m's event name and params, if m is one.
func Notification(m Message) (name string, params json.RawMessage, ok bool) {
	n, ok := m.(*Notify)
	if !ok {
		return "", nil, false
	}
	return n.Notification.Method, n.Notification.Params, true
}

// MostRecentDetached picks the workspace detached last, the one a new
// window takes: nil if none is detached.
func MostRecentDetached(l *rpc.WorkspaceListResult) *rpc.WorkspaceDesc {
	var best *rpc.WorkspaceDesc
	for i := range l.Workspaces {
		w := &l.Workspaces[i]
		if w.Attached {
			continue
		}
		if best == nil || w.DetachedAt > best.DetachedAt {
			best = w
		}
	}
	return best
}
