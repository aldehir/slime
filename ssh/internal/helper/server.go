// Package helper is slime-ssh's core: it holds one SSH connection and
// serves its session channels to slime, with the control protocol on
// one pair of streams and each channel's bytes on its own pipes.
package helper

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/aldehir/slime/ssh/internal/prompt"
	"github.com/aldehir/slime/ssh/internal/proto"
)

const defaultTerm = "xterm-256color"

type Options struct {
	// Dest has its user and port filled in.
	Dest Destination
	// KnownHosts are the known_hosts files, the first of which gets
	// newly accepted keys.
	KnownHosts []string
	// ConnectTimeout bounds the TCP connect. Zero is the system's.
	ConnectTimeout time.Duration
	// Identities are private key files to offer, after the agent's
	// keys. Missing files are skipped.
	Identities []string
	// DialAgent connects to an SSH agent. Nil means no agent.
	DialAgent func() (io.ReadWriteCloser, error)
	// OpenPipes turns the handle values in an Open into the channel's
	// pipes: the user's input to read and the remote's output to
	// write. Nil means they are Windows handles in this process.
	OpenPipes func(in, out uint64) (io.ReadCloser, io.WriteCloser, error)
}

type state int

const (
	// No channel yet.
	stateIdle state = iota
	// Authenticating on the first channel's terminal.
	stateConnecting
	stateConnected
	// Shutting down; nothing new starts.
	stateClosing
)

type Server struct {
	opts Options
	w    *proto.Writer

	mu       sync.Mutex
	state    state
	channels map[uint32]*channel
	// pending were opened while connecting; they start once connected.
	pending []*channel
	netConn net.Conn
	client  *ssh.Client
	// connDone is closed when client.Wait returns, with connErr.
	connDone chan struct{}
	connErr  error

	done     chan struct{}
	doneOnce sync.Once
	err      error
}

type channel struct {
	id    uint32
	in    io.ReadCloser
	out   io.WriteCloser
	input *bufio.Reader
	term  string
	cwd   string

	// Guarded by Server.mu.
	cols, rows uint16
	// sess is set once the remote has a pty of size ptyCols×ptyRows.
	sess             *ssh.Session
	ptyCols, ptyRows uint16
	// closed is set when slime closes the channel; it no longer wants
	// to hear about it.
	closed bool
}

// Serve speaks the control protocol on in and out until slime goes away
// (in reaches EOF), the last channel ends, or the connection fails.
func Serve(opts Options, in io.Reader, out io.Writer) error {
	if opts.OpenPipes == nil {
		opts.OpenPipes = openHandles
	}
	r := proto.NewReader(in)
	w := proto.NewWriter(out)
	if err := handshake(r, w); err != nil {
		return err
	}

	s := &Server{
		opts:     opts,
		w:        w,
		channels: map[uint32]*channel{},
		connDone: make(chan struct{}),
		done:     make(chan struct{}),
	}
	frames := make(chan proto.Frame)
	readErr := make(chan error, 1)
	go func() {
		for {
			f, err := r.Read()
			if err != nil {
				readErr <- err
				return
			}
			select {
			case frames <- f:
			case <-s.done:
				return
			}
		}
	}()

	for {
		select {
		case f := <-frames:
			s.handle(f)
		case err := <-readErr:
			if err == io.EOF {
				// slime is gone.
				err = nil
			} else {
				err = fmt.Errorf("reading control: %w", err)
			}
			s.finish(err, "")
			return s.err
		case <-s.done:
			return s.err
		}
	}
}

// handshake reads slime's Hello and replies with ours. A version
// mismatch is an error after the reply, so slime learns ours.
func handshake(r *proto.Reader, w *proto.Writer) error {
	f, err := r.Read()
	if err != nil {
		return fmt.Errorf("reading hello: %w", err)
	}
	m, err := proto.Decode(f)
	if err != nil {
		return fmt.Errorf("decoding hello: %w", err)
	}
	hello, ok := m.(*proto.Hello)
	if !ok {
		return fmt.Errorf("expected hello, got %T", m)
	}
	if err := w.Send(0, &proto.HelloReply{Version: proto.Version}); err != nil {
		return err
	}
	if hello.Version != proto.Version {
		return fmt.Errorf("slime speaks protocol %d, we speak %d", hello.Version, proto.Version)
	}
	return nil
}

func (s *Server) send(id uint32, m proto.Message) {
	if err := s.w.Send(id, m); err != nil {
		log.Printf("sending %T: %v", m, err)
	}
}

func (s *Server) handle(f proto.Frame) {
	m, err := proto.Decode(f)
	if err != nil {
		log.Printf("channel %d: %v", f.ID, err)
		return
	}
	switch m := m.(type) {
	case *proto.Open:
		s.open(f.ID, m)
	case *proto.Resize:
		s.resize(f.ID, m.Cols, m.Rows)
	case *proto.Close:
		s.close(f.ID)
	default:
		log.Printf("channel %d: unexpected %T", f.ID, m)
	}
}

func (s *Server) open(id uint32, m *proto.Open) {
	in, out, err := s.opts.OpenPipes(m.In, m.Out)
	if err != nil {
		s.send(id, &proto.Error{Message: err.Error()})
		return
	}
	ch := &channel{
		id:    id,
		in:    in,
		out:   out,
		input: bufio.NewReader(in),
		term:  m.Term,
		cwd:   m.Cwd,
		cols:  m.Cols,
		rows:  m.Rows,
	}
	if ch.term == "" {
		ch.term = defaultTerm
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if _, dup := s.channels[id]; dup || id == 0 || s.state == stateClosing {
		s.send(id, &proto.Error{Message: fmt.Sprintf("can't open channel %d", id)})
		in.Close()
		out.Close()
		return
	}
	s.channels[id] = ch
	switch s.state {
	case stateIdle:
		s.state = stateConnecting
		go s.connect(ch)
	case stateConnecting:
		s.pending = append(s.pending, ch)
	case stateConnected:
		go s.start(s.client, ch)
	}
}

func (s *Server) resize(id uint32, cols, rows uint16) {
	s.mu.Lock()
	ch := s.channels[id]
	if ch == nil {
		s.mu.Unlock()
		return
	}
	ch.cols, ch.rows = cols, rows
	sess := ch.sess
	if sess != nil {
		ch.ptyCols, ch.ptyRows = cols, rows
	}
	s.mu.Unlock()
	if sess != nil {
		if err := sess.WindowChange(int(rows), int(cols)); err != nil {
			log.Printf("channel %d: window-change: %v", id, err)
		}
	}
}

// close is slime closing a channel. While connecting on it, that gives
// up on the connection.
func (s *Server) close(id uint32) {
	s.mu.Lock()
	ch := s.channels[id]
	if ch == nil {
		s.mu.Unlock()
		return
	}
	ch.closed = true
	if s.isPending(ch) {
		s.removePending(ch)
		s.dropLocked(ch)
		s.mu.Unlock()
		return
	}
	// While connecting, the only channel that isn't pending is the one
	// prompting.
	authenticating := s.state == stateConnecting
	sess := ch.sess
	s.mu.Unlock()

	switch {
	case authenticating:
		s.finish(nil, "cancelled")
	case sess != nil:
		// Wait in start returns and drops the channel. Without a
		// session yet, start sees closed and stops.
		sess.Close()
	}
}

func (s *Server) isPending(ch *channel) bool {
	for _, p := range s.pending {
		if p == ch {
			return true
		}
	}
	return false
}

func (s *Server) removePending(ch *channel) {
	for i, p := range s.pending {
		if p == ch {
			s.pending = append(s.pending[:i], s.pending[i+1:]...)
			return
		}
	}
}

// connect dials and authenticates, prompting on ch's terminal, then
// starts every channel opened meanwhile.
func (s *Server) connect(ch *channel) {
	p := prompt.New(ch.input, ch.out)
	client, err := s.dial(p)

	s.mu.Lock()
	if err != nil || s.state == stateClosing {
		cancelled := ch.closed || s.state == stateClosing
		s.mu.Unlock()
		if client != nil {
			client.Close()
		}
		if cancelled {
			s.finish(nil, "cancelled")
			return
		}
		var denied *deniedError
		if errors.As(err, &denied) {
			p.Print(denied.Error() + "\n")
		} else {
			p.Print(fmt.Sprintf("slime-ssh: %v\n", err))
		}
		s.finish(fmt.Errorf("connecting to %s: %w", s.opts.Dest.Addr(), err), err.Error())
		return
	}
	s.client = client
	s.state = stateConnected
	start := append([]*channel{ch}, s.pending...)
	s.pending = nil
	s.mu.Unlock()

	log.Printf("connected to %s", s.opts.Dest.Addr())
	s.send(0, &proto.Connected{})
	for _, c := range start {
		go s.start(client, c)
	}
	go s.watch(client)
}

func (s *Server) dial(p *prompt.Prompter) (*ssh.Client, error) {
	d := s.opts.Dest
	addr := d.Addr()
	dialer := net.Dialer{Timeout: s.opts.ConnectTimeout}
	conn, err := dialer.Dial("tcp", addr)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	if s.state == stateClosing {
		s.mu.Unlock()
		conn.Close()
		return nil, errors.New("cancelled")
	}
	s.netConn = conn
	s.mu.Unlock()

	hk := &hostKeys{files: s.opts.KnownHosts, p: p}
	check, algos, err := hk.callback(addr)
	if err != nil {
		conn.Close()
		return nil, err
	}
	signers, closeAgent := agentSigners(s.opts.DialAgent)
	defer closeAgent()
	auth := newAuthenticator(p, d, signers, loadKeys(s.opts.Identities, signers))
	config := &ssh.ClientConfig{
		User:              d.User,
		AuthCallback:      auth.callback,
		HostKeyCallback:   check,
		HostKeyAlgorithms: algos,
		BannerCallback: func(msg string) error {
			return p.Print(msg)
		},
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, addr, config)
	if err != nil {
		conn.Close()
		return nil, err
	}
	return ssh.NewClient(c, chans, reqs), nil
}

// start opens ch's session channel with a pty and a shell, then copies
// input to it until the remote command ends.
func (s *Server) start(client *ssh.Client, ch *channel) {
	sess, err := client.NewSession()
	if err != nil {
		s.fail(ch, err)
		return
	}

	s.mu.Lock()
	cols, rows := ch.cols, ch.rows
	s.mu.Unlock()

	modes := ssh.TerminalModes{
		ssh.ECHO:          1,
		ssh.VERASE:        0x7f,
		ssh.VINTR:         0x03,
		ssh.IUTF8:         1,
		ssh.TTY_OP_ISPEED: 38400,
		ssh.TTY_OP_OSPEED: 38400,
	}
	if err := sess.RequestPty(ch.term, int(rows), int(cols), modes); err != nil {
		sess.Close()
		s.fail(ch, fmt.Errorf("pty request: %w", err))
		return
	}

	// Resizes and closes from here on go to the remote; catch up on any
	// that came while the pty was being set up.
	s.mu.Lock()
	if ch.closed || s.state == stateClosing {
		s.mu.Unlock()
		sess.Close()
		s.drop(ch)
		s.finishIfIdle()
		return
	}
	ch.sess = sess
	ch.ptyCols, ch.ptyRows = cols, rows
	if ch.cols != cols || ch.rows != rows {
		ch.ptyCols, ch.ptyRows = ch.cols, ch.rows
		sess.WindowChange(int(ch.rows), int(ch.cols))
	}
	s.mu.Unlock()

	stdin, err := sess.StdinPipe()
	if err != nil {
		sess.Close()
		s.fail(ch, err)
		return
	}
	sess.Stdout = ch.out
	sess.Stderr = ch.out
	if ch.cwd != "" {
		err = sess.Start(cwdCommand(ch.cwd))
	} else {
		err = sess.Shell()
	}
	if err != nil {
		sess.Close()
		s.fail(ch, fmt.Errorf("starting shell: %w", err))
		return
	}
	s.send(ch.id, &proto.Opened{})

	go func() {
		// Includes anything typed ahead during the prompts.
		io.Copy(stdin, ch.input)
		stdin.Close()
	}()

	exit, ok := exitMessage(sess.Wait())
	s.mu.Lock()
	closed := ch.closed
	s.mu.Unlock()
	if ok && !closed {
		s.send(ch.id, exit)
	}
	s.drop(ch)
	// Otherwise the connection failed, and watch reports that.
	if ok || closed {
		s.finishIfIdle()
	}
}

// fail reports that ch couldn't start and drops it.
func (s *Server) fail(ch *channel, err error) {
	log.Printf("channel %d: %v", ch.id, err)
	s.mu.Lock()
	report := !ch.closed && s.state != stateClosing
	s.mu.Unlock()
	if report {
		s.send(ch.id, &proto.Error{Message: err.Error()})
	}
	s.drop(ch)
	s.finishIfIdle()
}

// drop forgets ch and closes its pipes, which slime sees as EOF.
func (s *Server) drop(ch *channel) {
	s.mu.Lock()
	s.dropLocked(ch)
	s.mu.Unlock()
}

func (s *Server) dropLocked(ch *channel) {
	if s.channels[ch.id] != ch {
		return
	}
	delete(s.channels, ch.id)
	ch.out.Close()
	ch.in.Close()
}

// finishIfIdle ends the helper once the last channel is gone.
//
// A channel can end because the remote dropped the connection: the
// connection closes its channels before client.Wait returns. Closing
// the client ourselves and seeing what Wait says tells the two apart.
func (s *Server) finishIfIdle() {
	s.mu.Lock()
	idle := s.state == stateConnected && len(s.channels) == 0
	client := s.client
	s.mu.Unlock()
	if !idle {
		return
	}
	client.Close()
	<-s.connDone
	if s.connErr != nil && !errors.Is(s.connErr, net.ErrClosed) {
		s.finish(s.connErr, connReason(s.connErr))
		return
	}
	s.finish(nil, "")
}

// watch reports the connection failing.
func (s *Server) watch(client *ssh.Client) {
	s.connErr = client.Wait()
	close(s.connDone)
	s.mu.Lock()
	closing := s.state == stateClosing || len(s.channels) == 0
	s.mu.Unlock()
	// Otherwise finishIfIdle or finish closed it and decides.
	if closing || errors.Is(s.connErr, net.ErrClosed) {
		return
	}
	s.finish(s.connErr, connReason(s.connErr))
}

func connReason(err error) string {
	if err == nil || errors.Is(err, io.EOF) {
		return "connection closed by remote host"
	}
	return err.Error()
}

// finish shuts down, once: it tells slime why if reason is set, ends
// every channel, and makes Serve return err.
func (s *Server) finish(err error, reason string) {
	s.doneOnce.Do(func() {
		s.mu.Lock()
		s.state = stateClosing
		var chans []*channel
		for _, ch := range s.channels {
			chans = append(chans, ch)
		}
		s.channels = map[uint32]*channel{}
		s.pending = nil
		client, conn := s.client, s.netConn
		s.mu.Unlock()

		if reason != "" {
			log.Printf("disconnected: %s", reason)
			s.send(0, &proto.Disconnected{Reason: reason})
		}
		for _, ch := range chans {
			ch.out.Close()
			ch.in.Close()
		}
		if client != nil {
			client.Close()
		} else if conn != nil {
			conn.Close()
		}
		s.err = err
		close(s.done)
	})
}

// exitMessage turns Session.Wait's result into an Exit. ok is false
// when the session ended without one because the connection failed.
func exitMessage(err error) (m *proto.Exit, ok bool) {
	var exitErr *ssh.ExitError
	var missing *ssh.ExitMissingError
	switch {
	case err == nil:
		return &proto.Exit{Status: 0}, true
	case errors.As(err, &exitErr):
		if sig := exitErr.Signal(); sig != "" {
			return &proto.Exit{Status: -1, Signal: sig}, true
		}
		return &proto.Exit{Status: int32(exitErr.ExitStatus())}, true
	case errors.As(err, &missing):
		return &proto.Exit{Status: -1}, true
	}
	return nil, false
}

// cwdCommand starts the user's login shell in dir, or in their home if
// dir is gone.
func cwdCommand(dir string) string {
	return "cd -- " + shellQuote(dir) + ` 2>/dev/null; exec "${SHELL:-/bin/sh}" -l`
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
