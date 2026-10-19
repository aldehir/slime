//go:build windows

package daemon

import (
	"cmp"
	"context"
	"errors"
	"fmt"
	"io"
	"slices"
	"strings"

	"github.com/aldehir/slime/internal/remote"
	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/sshbridge"
)

// Hosts: the SSH connections the daemon holds. Each host is logged in
// to once (host.connect), with the prompts going to the client that
// asked (host.prompt), and then any client reaches the host's own
// daemon through a bridge: a connection whose first frame is Bridge,
// spliced to `slime connect` on the host. The connection lives until
// the host hangs up or a client asks (host.disconnect), whatever
// windows come and go. Every change of state goes to the connections
// subscribed to host.changed.

// HostOptions configures connecting to SSH hosts.
type HostOptions struct {
	// Resolve turns a destination as a client gives it into how to
	// connect. Nil resolves it against the user's ssh config
	// (sshbridge.ResolveDestination).
	Resolve func(dest string) (sshbridge.Options, error)
	// Remote holds the builds of slime to install on hosts, when
	// Resolve doesn't say. Nil means the ones beside the executable.
	Remote *remote.Manifest
}

// hostTable is the hosts by id. Guarded by the server's lock.
type hostTable struct {
	opts   HostOptions
	byID   map[uint32]*host
	nextID uint32
}

func newHostTable(opts HostOptions) hostTable {
	if opts.Resolve == nil {
		opts.Resolve = sshbridge.ResolveDestination
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
	// reply to the prompt shown, while there is one.
	cancel  context.CancelFunc
	client  *conn
	answers chan rpc.HostAnswerParams
	// disconnecting is set by a host.disconnect while connecting, so
	// the failure that follows is reported as gone.
	disconnecting bool

	// Once connected.
	conn *sshbridge.Conn
}

func (h *host) info() rpc.Host {
	return rpc.Host{ID: h.id, Dest: h.dest, State: h.state, Text: h.text}
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

// hostConnect starts logging in to a destination, or answers with the
// state of a host already on its way or there.
func (s *Server) hostConnect(cl *callCtx, m rpc.HostConnectParams) (*rpc.Host, error) {
	if m.Dest == "" {
		return nil, rpc.Errorf(rpc.CodeInvalidParams, "host.connect needs a destination")
	}
	// One host however it's spelled: hosts are matched by destination.
	m.Dest = rpc.NormalizeDest(m.Dest)
	s.mu.Lock()
	defer s.mu.Unlock()
	var h *host
	for _, x := range s.hosts.byID {
		if x.dest == m.Dest {
			h = x
			break
		}
	}
	if h == nil {
		s.hosts.nextID++
		h = &host{id: s.hosts.nextID, dest: m.Dest}
		s.hosts.byID[h.id] = h
	}
	if h.state == HostConnecting || h.state == HostConnected {
		info := h.info()
		return &info, nil
	}
	h.gen++
	gen := h.gen
	ctx, cancel := context.WithCancel(context.Background())
	h.state, h.text = HostConnecting, "logging in"
	h.cancel, h.client, h.answers = cancel, cl.c, nil
	h.disconnecting = false
	s.checkIdleLocked()
	s.hostChangedLocked(h)
	go s.hostLogin(h, gen, ctx)
	info := h.info()
	return &info, nil
}

// hostLogin logs in to h and sets slime up there, in attempt gen.
func (s *Server) hostLogin(h *host, gen int, ctx context.Context) {
	opts, err := s.hosts.opts.Resolve(h.dest)
	if err != nil {
		s.hostFailed(h, gen, err.Error())
		return
	}
	if opts.Remote == nil {
		opts.Remote = s.hosts.opts.Remote
	}
	conn, err := sshbridge.Dial(ctx, opts, &hostAsker{s: s, h: h, gen: gen, ctx: ctx})
	if err != nil {
		s.hostFailed(h, gen, sshbridge.FailReason(err))
		return
	}
	// Before any pane starts, so they all get the same TERM.
	conn.InstallTerminfo()
	if _, err := conn.EnsureDaemon(func(text string) { s.hostText(h, gen, text) }); err != nil {
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
	s.hostChangedLocked(h)
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
		h.state, h.text = HostLost, sshbridge.LostReason(err)
	}
	s.log.Info("host ended", "dest", h.dest, "state", h.state, "text", h.text)
	s.checkIdleLocked()
	s.hostChangedLocked(h)
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
	s.hostChangedLocked(h)
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
	s.hostChangedLocked(h)
}

// hostChangedLocked tells the connections subscribed to host.changed
// h's state.
func (s *Server) hostChangedLocked(h *host) {
	s.emitLocked(rpc.EvHostChanged, h.info(), nil, nil)
}

// hostAnswer hands the caller's answer to the prompt waiting for it, if
// the caller is the client logging in. A cancel with none waiting (the
// server is busy with the last answer) gives up on logging in.
func (s *Server) hostAnswer(cl *callCtx, m rpc.HostAnswerParams) (rpc.Empty, error) {
	s.mu.Lock()
	h := s.hosts.byID[m.Host]
	if h == nil {
		s.mu.Unlock()
		return rpc.Empty{}, errNoHost
	}
	if h.client != cl.c || cl.c == nil {
		s.mu.Unlock()
		return rpc.Empty{}, rpc.Errorf(rpc.CodeFailed, "%s isn't logging in for this connection", h.dest)
	}
	answers := h.answers
	h.answers = nil
	cancel := h.cancel
	s.mu.Unlock()
	switch {
	case answers != nil:
		answers <- m
	case m.Choice == rpc.ChoiceCancel && cancel != nil:
		cancel()
	}
	return rpc.Empty{}, nil
}

// hostDisconnect hangs up on a host, or gives up on logging in to it.
func (s *Server) hostDisconnect(_ *callCtx, m rpc.HostParams) (rpc.Empty, error) {
	s.mu.Lock()
	h := s.hosts.byID[m.Host]
	if h == nil {
		s.mu.Unlock()
		return rpc.Empty{}, errNoHost
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
	return rpc.Empty{}, nil
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

func (s *Server) hostList(_ *callCtx, _ rpc.Empty) (*rpc.HostListResult, error) {
	s.mu.Lock()
	out := &rpc.HostListResult{Hosts: []rpc.Host{}}
	for _, h := range s.hosts.byID {
		out.Hosts = append(out.Hosts, h.info())
	}
	s.mu.Unlock()
	slices.SortFunc(out.Hosts, func(a, b rpc.Host) int { return cmp.Compare(a.ID, b.ID) })
	return out, nil
}

// bridge splices a connection whose first frame was Bridge to `slime
// connect` on its host, until either end hangs up. What the client
// sends next (its Hello) is in r's buffer, and goes through.
func (s *Server) bridge(rw io.ReadWriteCloser, r *Reader, m *Bridge) {
	s.mu.Lock()
	h := s.hosts.byID[m.Host]
	var conn *sshbridge.Conn
	if h != nil && h.state == HostConnected {
		conn = h.conn
	}
	s.mu.Unlock()
	switch {
	case h == nil:
		writeError(rw, fmt.Sprintf("no host %d", m.Host))
		return
	case conn == nil:
		writeError(rw, fmt.Sprintf("%s isn't connected (%s: %s)", h.dest, h.state, h.text))
		return
	}
	sl, err := conn.StartDaemon(m.Term, r.stream(), rw, nil)
	if err != nil {
		writeError(rw, err.Error())
		return
	}
	s.log.Debug("bridge opened", "dest", h.dest)
	err = sl.Wait()
	var failed *sshbridge.DaemonError
	if errors.As(err, &failed) {
		writeError(rw, failed.Why)
		return
	}
	rw.Close()
}

// hostAsker is how logging in to a host asks the client that asked for
// it: prompts go to it as host.prompt, and its host.answer comes back.
type hostAsker struct {
	s   *Server
	h   *host
	gen int
	ctx context.Context
}

func (a *hostAsker) Ask(q *sshbridge.Query) (sshbridge.Answer, error) {
	answers := make(chan rpc.HostAnswerParams, 1)
	a.s.mu.Lock()
	if a.h.gen != a.gen || a.h.state != HostConnecting {
		a.s.mu.Unlock()
		return sshbridge.Answer{}, sshbridge.ErrCancelled
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

	p := rpc.HostPromptParams{
		Host:   a.h.id,
		Kind:   promptKinds[q.Kind],
		Title:  q.Title,
		Text:   q.Text,
		Detail: q.Detail,
		Error:  q.Error,
	}
	for _, pq := range q.Questions {
		p.Questions = append(p.Questions, rpc.Question{Label: pq.Label, Echo: pq.Echo})
	}
	client.sendForce(NoPane, notify(rpc.EvHostPrompt, p))
	select {
	case ans := <-answers:
		return sshbridge.PadAnswers(sshbridge.Answer{Choice: choices[ans.Choice], Answers: ans.Answers}, len(q.Questions)), nil
	case <-a.ctx.Done():
		return sshbridge.Answer{}, sshbridge.ErrCancelled
	}
}

// The wire's names for sshbridge's prompt kinds and choices. A choice
// the wire doesn't know cancels.
var (
	promptKinds = map[sshbridge.PromptKind]rpc.PromptKind{
		sshbridge.PromptPassword:    rpc.PromptPassword,
		sshbridge.PromptPassphrase:  rpc.PromptPassphrase,
		sshbridge.PromptInteractive: rpc.PromptInteractive,
		sshbridge.PromptUnknownHost: rpc.PromptUnknownHost,
		sshbridge.PromptChangedHost: rpc.PromptChangedHost,
	}
	choices = map[rpc.Choice]sshbridge.Choice{
		rpc.ChoiceCancel: sshbridge.ChoiceCancel,
		rpc.ChoiceAccept: sshbridge.ChoiceAccept,
		rpc.ChoiceSkip:   sshbridge.ChoiceSkip,
	}
)

func (a *hostAsker) Info(text string) {
	a.s.hostText(a.h, a.gen, strings.TrimRight(text, "\r\n"))
}

// Print is a banner or a notice, which has no terminal to go to.
func (a *hostAsker) Print(text string) {
	a.s.log.Info("host", "dest", a.h.dest, "text", strings.TrimRight(text, "\r\n"))
}

func (*hostAsker) Dialog() bool { return true }
