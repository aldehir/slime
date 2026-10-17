//go:build windows

package persist

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"

	"github.com/aldehir/slime/ssh/internal/helper"
	"github.com/aldehir/slime/ssh/internal/remote"
)

// Hosts: the SSH connections the daemon holds. Each host is logged in
// to once (HostConnect), with the prompts going to the client that
// asked, and then any client reaches the host's own daemon through a
// bridge: a connection whose first frame is Bridge, spliced to `slimed
// connect` on the host. The connection lives until the host hangs up
// or a client asks (HostDisconnect), whatever windows come and go.

// HostOptions configures connecting to SSH hosts.
type HostOptions struct {
	// Resolve turns a destination as a client gives it into how to
	// connect. Nil resolves it against the user's ssh config
	// (helper.ResolveDestination).
	Resolve func(dest string) (helper.Options, error)
	// Remote holds the builds of slimed to install on hosts, when
	// Resolve doesn't say. Nil means the ones beside the executable.
	Remote *remote.Manifest
}

// hostTable is the hosts by id. Guarded by the server's lock.
type hostTable struct {
	opts HostOptions
	byID map[uint32]*host
}

func newHostTable(opts HostOptions) hostTable {
	if opts.Resolve == nil {
		opts.Resolve = helper.ResolveDestination
	}
	return hostTable{opts: opts, byID: map[uint32]*host{}}
}

// host is one destination, with the connection to it when there is one.
// A host keeps its id across reconnects, so a window's grouping doesn't
// move.
type host struct {
	id    uint32
	dest  string
	state HostStatus
	text  string
	// gen counts attempts to connect, so a goroutine from an earlier
	// one can tell its results are stale.
	gen int

	// While connecting: cancel gives up on logging in, client is the
	// one logging in (whose prompts it takes), and answers takes its
	// reply to the Prompt shown, while there is one.
	cancel  context.CancelFunc
	client  *conn
	answers chan HostAnswer
	// disconnecting is set by a HostDisconnect while connecting, so
	// the failure that follows is reported as gone.
	disconnecting bool

	// Once connected.
	conn *helper.Conn
}

func (h *host) info() HostInfo {
	return HostInfo{ID: h.id, Dest: h.dest, State: h.state, Text: h.text}
}

// hostsActiveLocked counts the hosts that keep the daemon alive: those
// connecting or connected.
func (s *Server) hostsActiveLocked() int {
	n := 0
	for _, h := range s.hosts.byID {
		if h.state == HostConnecting || h.state == HostConnected {
			n++
		}
	}
	return n
}

// hostDispatch handles the host messages, reporting whether m was one.
func (s *Server) hostDispatch(c *conn, id uint32, m Message) bool {
	switch m := m.(type) {
	case *HostConnect:
		s.hostConnect(c, m)
	case *HostAnswer:
		s.hostAnswer(c, id, m)
	case *HostDisconnect:
		s.hostDisconnect(id)
	case *HostList:
		s.hostList(c)
	default:
		return false
	}
	return true
}

// hostConnect starts logging in to a destination, or answers with the
// state of a host already on its way or there.
func (s *Server) hostConnect(c *conn, m *HostConnect) {
	s.mu.Lock()
	var h *host
	for _, x := range s.hosts.byID {
		if x.dest == m.Dest {
			h = x
			break
		}
	}
	if h == nil {
		h = &host{id: s.newIDLocked(), dest: m.Dest}
		s.hosts.byID[h.id] = h
	}
	if h.state == HostConnecting || h.state == HostConnected {
		st := h.stateMessage(m.Tag)
		s.mu.Unlock()
		c.sendForce(h.id, st)
		return
	}
	h.gen++
	gen := h.gen
	ctx, cancel := context.WithCancel(context.Background())
	h.state, h.text = HostConnecting, "logging in"
	h.cancel, h.client, h.answers = cancel, c, nil
	h.disconnecting = false
	s.checkIdleLocked()
	s.hostChangedLocked(h, c, m.Tag)
	s.mu.Unlock()
	go s.hostLogin(h, gen, ctx)
}

// hostLogin logs in to h and sets slimed up there, in attempt gen.
func (s *Server) hostLogin(h *host, gen int, ctx context.Context) {
	opts, err := s.hosts.opts.Resolve(h.dest)
	if err != nil {
		s.hostFailed(h, gen, err.Error())
		return
	}
	if opts.Remote == nil {
		opts.Remote = s.hosts.opts.Remote
	}
	conn, err := helper.Dial(ctx, opts, &hostAsker{s: s, h: h, gen: gen, ctx: ctx})
	if err != nil {
		s.hostFailed(h, gen, helper.FailReason(err))
		return
	}
	// Before any pane starts, so they all get the same TERM.
	conn.InstallTerminfo()
	if _, err := conn.EnsureSlimed(func(text string) { s.hostText(h, gen, text) }); err != nil {
		conn.Close()
		s.hostFailed(h, gen, err.Error())
		return
	}

	s.mu.Lock()
	if h.gen != gen || h.disconnecting {
		s.mu.Unlock()
		conn.Close()
		s.hostFailed(h, gen, "")
		return
	}
	h.conn = conn
	h.cancel, h.client, h.answers = nil, nil, nil
	h.state, h.text = HostConnected, ""
	s.hostChangedLocked(h, nil, 0)
	s.mu.Unlock()
	s.log.Info("host connected", "dest", h.dest, "addr", opts.Dest.Addr())

	err = conn.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	if h.gen != gen {
		return
	}
	h.conn = nil
	if err == nil {
		h.state, h.text = HostGone, "disconnected"
	} else {
		h.state, h.text = HostLost, helper.LostReason(err)
	}
	s.log.Info("host ended", "dest", h.dest, "state", h.state, "text", h.text)
	s.checkIdleLocked()
	s.hostChangedLocked(h, nil, 0)
}

// hostFailed ends attempt gen as failed, saying why, or as gone if a
// HostDisconnect ended it.
func (s *Server) hostFailed(h *host, gen int, why string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h.gen != gen {
		return
	}
	h.cancel, h.client, h.answers = nil, nil, nil
	if h.disconnecting {
		h.state, h.text = HostGone, "disconnected"
	} else {
		h.state, h.text = HostFailed, why
	}
	s.log.Info("host failed", "dest", h.dest, "state", h.state, "text", h.text)
	s.checkIdleLocked()
	s.hostChangedLocked(h, nil, 0)
}

// hostText updates the status line of a host still connecting in
// attempt gen.
func (s *Server) hostText(h *host, gen int, text string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if h.gen != gen || h.state != HostConnecting {
		return
	}
	h.text = text
	s.hostChangedLocked(h, nil, 0)
}

func (h *host) stateMessage(tag uint32) *HostState {
	return &HostState{Tag: tag, Dest: h.dest, State: h.state, Text: h.text}
}

// hostChangedLocked tells every client h's state; tagged gets it with
// tag, as the answer to its HostConnect.
func (s *Server) hostChangedLocked(h *host, tagged *conn, tag uint32) {
	for c := range s.conns {
		if c == tagged {
			c.sendForce(h.id, h.stateMessage(tag))
		} else {
			c.sendForce(h.id, h.stateMessage(0))
		}
	}
}

// hostAnswer hands c's answer to the prompt waiting for it, if c is the
// client logging in. A cancel with none waiting (the server is busy
// with the last answer) gives up on logging in.
func (s *Server) hostAnswer(c *conn, id uint32, m *HostAnswer) {
	s.mu.Lock()
	h := s.hosts.byID[id]
	if h == nil || h.client != c {
		s.mu.Unlock()
		return
	}
	answers := h.answers
	h.answers = nil
	cancel := h.cancel
	s.mu.Unlock()
	switch {
	case answers != nil:
		answers <- *m
	case m.Choice == ChoiceCancel && cancel != nil:
		cancel()
	}
}

// hostDisconnect hangs up on a host, or gives up on logging in to it.
func (s *Server) hostDisconnect(id uint32) {
	s.mu.Lock()
	h := s.hosts.byID[id]
	if h == nil {
		s.mu.Unlock()
		return
	}
	switch h.state {
	case HostConnecting:
		h.disconnecting = true
		h.cancel()
		s.mu.Unlock()
	case HostConnected:
		conn := h.conn
		s.mu.Unlock()
		// Wait in hostLogin returns and reports it gone.
		conn.Close()
	default:
		s.mu.Unlock()
	}
}

// hostClientGoneLocked cancels logging in to any host c was answering
// the prompts for.
func (s *Server) hostClientGoneLocked(c *conn) {
	for _, h := range s.hosts.byID {
		if h.state == HostConnecting && h.client == c {
			h.cancel()
		}
	}
}

func (s *Server) hostList(c *conn) {
	s.mu.Lock()
	out := &Hosts{}
	for _, h := range s.hosts.byID {
		out.Hosts = append(out.Hosts, h.info())
	}
	s.mu.Unlock()
	slices.SortFunc(out.Hosts, func(a, b HostInfo) int { return cmp.Compare(a.ID, b.ID) })
	c.sendForce(0, out)
}

// bridge splices a connection whose first frame was Bridge to `slimed
// connect` on host id, until either end hangs up. What the client
// sends next (its Hello) is in r's buffer, and goes through.
func (s *Server) bridge(rw io.ReadWriteCloser, r *Reader, id uint32, m *Bridge) {
	s.mu.Lock()
	h := s.hosts.byID[id]
	var conn *helper.Conn
	if h != nil && h.state == HostConnected {
		conn = h.conn
	}
	s.mu.Unlock()
	switch {
	case h == nil:
		writeError(rw, fmt.Sprintf("no host %d", id))
		return
	case conn == nil:
		writeError(rw, fmt.Sprintf("%s isn't connected (%s: %s)", h.dest, h.state, h.text))
		return
	}
	sl, err := conn.StartSlimed(m.Term, r.stream(), rw, nil)
	if err != nil {
		writeError(rw, err.Error())
		return
	}
	s.log.Debug("bridge opened", "dest", h.dest)
	err = sl.Wait()
	var failed *helper.SlimedError
	if errors.As(err, &failed) {
		writeError(rw, failed.Why)
		return
	}
	rw.Close()
}

// hostAsker is how logging in to a host asks the client that asked for
// it: prompts go to it as Prompt, and its HostAnswer comes back.
type hostAsker struct {
	s   *Server
	h   *host
	gen int
	ctx context.Context
}

func (a *hostAsker) Ask(q *helper.Query) (helper.Answer, error) {
	answers := make(chan HostAnswer, 1)
	a.s.mu.Lock()
	if a.h.gen != a.gen || a.h.state != HostConnecting {
		a.s.mu.Unlock()
		return helper.Answer{}, helper.ErrCancelled
	}
	a.h.answers = answers
	client := a.h.client
	a.s.mu.Unlock()
	defer func() {
		a.s.mu.Lock()
		if a.h.answers == answers {
			a.h.answers = nil
		}
		a.s.mu.Unlock()
	}()

	p := &Prompt{
		Kind:   PromptKind(q.Kind),
		Title:  q.Title,
		Text:   q.Text,
		Detail: q.Detail,
		Error:  q.Error,
	}
	for _, pq := range q.Questions {
		p.Questions = append(p.Questions, Question{Label: pq.Label, Echo: pq.Echo})
	}
	client.sendForce(a.h.id, p)
	select {
	case ans := <-answers:
		return helper.PadAnswers(helper.Answer{Choice: helper.Choice(ans.Choice), Answers: ans.Answers}, len(q.Questions)), nil
	case <-a.ctx.Done():
		return helper.Answer{}, helper.ErrCancelled
	}
}

func (a *hostAsker) Info(text string) {
	a.s.hostText(a.h, a.gen, strings.TrimRight(text, "\r\n"))
}

// Print is a banner or a notice, which has no terminal to go to.
func (a *hostAsker) Print(text string) {
	a.s.log.Info("host", "dest", a.h.dest, "text", strings.TrimRight(text, "\r\n"))
}

func (*hostAsker) Dialog() bool { return true }
