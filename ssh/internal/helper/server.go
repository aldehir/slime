// Package helper is the SSH side of slime: logging in to hosts (Dial),
// running slimed on them, and, for slime-ssh while it lasts, serving a
// connection's session channels over the control protocol (Serve).
package helper

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"maps"
	"slices"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/aldehir/slime/ssh/internal/prompt"
	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/remote"
	"github.com/aldehir/slime/ssh/internal/terminfo"
)

const defaultTerm = terminfo.Fallback

type Options struct {
	// Dest has its user and port filled in.
	Dest Destination
	// Identities are key files to offer, in order; missing files are
	// skipped. The agent signs for any it holds.
	Identities []string
	// IdentitiesOnly offers the agent's keys only when they are among
	// Identities.
	IdentitiesOnly bool
	// Jumps are hosts to go through to reach Dest, first to last
	// (ProxyJump).
	Jumps []Hop

	// KnownHosts are the user's known_hosts files, the first of which
	// gets newly accepted keys. GlobalKnownHosts are only read.
	KnownHosts       []string
	GlobalKnownHosts []string
	// StrictHostKeyChecking is "ask" (or ""), "yes", "accept-new", or
	// "no". "no" adds new keys as accept-new does but still refuses
	// changed ones.
	StrictHostKeyChecking string
	// HashKnownHosts writes accepted hosts hashed.
	HashKnownHosts bool

	// ConnectTimeout bounds the TCP connect. Zero is the system's.
	ConnectTimeout time.Duration
	// KeepaliveInterval, when set, asks the server for a reply that
	// often, and gives up on the connection after KeepaliveCountMax go
	// unanswered (ServerAliveInterval, ServerAliveCountMax).
	KeepaliveInterval time.Duration
	KeepaliveCountMax int

	// DialAgent connects to an SSH agent. Nil means no agent.
	DialAgent func() (io.ReadWriteCloser, error)
	// Remote holds the builds of slimed to install on hosts. Nil means
	// the ones beside the executable (remote.Beside).
	Remote *remote.Manifest
	// OpenPipes turns the handle values in an Open into the channel's
	// pipes: the user's input to read and the remote's output to
	// write. Nil means they are Windows handles in this process.
	OpenPipes func(in, out uint64) (io.ReadCloser, io.WriteCloser, error)
}

// Hop is a host to log in to on the way to the destination.
type Hop struct {
	Dest           Destination
	Identities     []string
	IdentitiesOnly bool
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

// Server serves one connection's channels to slime (slime-ssh).
type Server struct {
	opts Options
	w    *proto.Writer
	// features are slime's, from its Hello.
	features uint32

	mu       sync.Mutex
	state    state
	channels map[uint32]*channel
	// pending were opened while connecting; they start once connected.
	pending []*channel
	// answers takes slime's Answer to the Prompt shown, while there is
	// one.
	answers chan proto.Answer
	// cancel gives up on logging in, while that's under way.
	cancel context.CancelFunc
	conn   *Conn
	// ghosttyTerm is set when the host has xterm-ghostty, so channels
	// that ask for it get it.
	ghosttyTerm bool

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
	// slimed carries slimed's protocol rather than a terminal
	// (OpenSlimed).
	slimed bool

	// Guarded by Server.mu.
	//
	// size is the latest size slime gave.
	size winSize
	// sess is set once the remote has a pty; sl once slimed runs.
	sess *ssh.Session
	sl   *Slimed
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
	features, err := handshake(r, w)
	if err != nil {
		return err
	}

	s := &Server{
		opts:     opts,
		w:        w,
		features: features,
		channels: map[uint32]*channel{},
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

// handshake reads slime's Hello and replies with ours, returning
// slime's features. A version mismatch is an error after the reply, so
// slime learns ours.
func handshake(r *proto.Reader, w *proto.Writer) (uint32, error) {
	f, err := r.Read()
	if err != nil {
		return 0, fmt.Errorf("reading hello: %w", err)
	}
	m, err := proto.Decode(f)
	if err != nil {
		return 0, fmt.Errorf("decoding hello: %w", err)
	}
	hello, ok := m.(*proto.Hello)
	if !ok {
		return 0, fmt.Errorf("expected hello, got %T", m)
	}
	if err := w.Send(0, &proto.HelloReply{Version: proto.Version}); err != nil {
		return 0, err
	}
	if hello.Version != proto.Version {
		return 0, fmt.Errorf("slime speaks protocol %d, we speak %d", hello.Version, proto.Version)
	}
	return hello.Features, nil
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
	case *proto.OpenSlimed:
		s.openSlimed(f.ID, m)
	case *proto.Resize:
		s.resize(f.ID, winSize{m.Cols, m.Rows, m.Width, m.Height})
	case *proto.Close:
		s.close(f.ID)
	case *proto.Answer:
		s.answer(m)
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
	s.add(&channel{
		id:    id,
		in:    in,
		out:   out,
		input: bufio.NewReader(in),
		term:  m.Term,
		cwd:   m.Cwd,
		size:  winSize{m.Cols, m.Rows, m.Width, m.Height},
	})
}

func (s *Server) openSlimed(id uint32, m *proto.OpenSlimed) {
	in, out, err := s.opts.OpenPipes(m.In, m.Out)
	if err != nil {
		s.send(id, &proto.Error{Message: err.Error()})
		return
	}
	if s.features&proto.FeaturePrompts == 0 {
		// Logging in on it would ask in its pipes, which aren't a
		// terminal.
		s.send(id, &proto.Error{Message: "slimed channels need prompts in slime's dialog"})
		in.Close()
		out.Close()
		return
	}
	s.add(&channel{id: id, in: in, out: out, input: bufio.NewReader(in), term: m.Term, slimed: true})
}

// add takes a channel slime opened: it connects, waits for connecting,
// or starts.
func (s *Server) add(ch *channel) {
	if ch.term == "" {
		ch.term = defaultTerm
	}
	id := ch.id
	in, out := ch.in, ch.out

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
		go s.start(ch)
	}
}

func (s *Server) resize(id uint32, size winSize) {
	s.mu.Lock()
	ch := s.channels[id]
	if ch == nil {
		s.mu.Unlock()
		return
	}
	ch.size = size
	sess := ch.sess
	s.mu.Unlock()
	if sess != nil {
		if err := windowChange(sess, size); err != nil {
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
	sess, sl := ch.sess, ch.sl
	s.mu.Unlock()

	switch {
	case authenticating:
		s.finish(nil, "cancelled")
	case sess != nil:
		// Wait in start returns and drops the channel. Without a
		// session yet, start sees closed and stops.
		sess.Close()
	case sl != nil:
		sl.Close()
	}
}

// answer hands slime's answer to the prompt waiting for it. A cancel
// with none waiting (the server is busy with the last answer) gives up
// on logging in.
func (s *Server) answer(m *proto.Answer) {
	s.mu.Lock()
	answers := s.answers
	s.answers = nil
	connecting := s.state == stateConnecting
	s.mu.Unlock()
	switch {
	case answers != nil:
		answers <- *m
	case connecting && m.Choice == proto.ChoiceCancel:
		s.finish(nil, "cancelled")
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

// connect dials and authenticates, asking in slime's dialog or on ch's
// terminal, then starts every channel opened meanwhile.
func (s *Server) connect(ch *channel) {
	var a Asker
	switch {
	case ch.slimed:
		// Its pipes aren't a terminal to print notices in.
		a = &dialogAsker{s: s, id: ch.id}
	case s.features&proto.FeaturePrompts != 0:
		a = &dialogAsker{s: s, id: ch.id, term: prompt.New(ch.input, ch.out)}
	default:
		a = termAsker{prompt.New(ch.input, ch.out)}
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.mu.Lock()
	if s.state == stateClosing {
		s.mu.Unlock()
		return
	}
	s.cancel = cancel
	s.mu.Unlock()

	conn, err := Dial(ctx, s.opts, a)
	// Before any shell starts, so they all get the same TERM.
	ghosttyTerm := err == nil && ch.term == terminfo.Name && conn.InstallTerminfo()

	s.mu.Lock()
	if err != nil || s.state == stateClosing {
		cancelled := ch.closed || s.state == stateClosing
		s.mu.Unlock()
		if conn != nil {
			conn.Close()
		}
		if cancelled {
			s.finish(nil, "cancelled")
			return
		}
		// slime shows the reason in the channel's terminal.
		s.finish(fmt.Errorf("connecting to %s: %w", s.opts.Dest.Addr(), err), FailReason(err))
		return
	}
	s.conn = conn
	s.cancel = nil
	s.ghosttyTerm = ghosttyTerm
	s.state = stateConnected
	start := append([]*channel{ch}, s.pending...)
	s.pending = nil
	s.mu.Unlock()

	log.Printf("connected to %s", s.opts.Dest.Addr())
	s.send(0, &proto.Connected{})
	for _, c := range start {
		go s.start(c)
	}
	go s.watch(conn)
}

// start opens ch's session channel with a pty and a shell, then copies
// input to it until the remote command ends; or for a slimed channel,
// bridges it to slimed.
func (s *Server) start(ch *channel) {
	if ch.slimed {
		s.startSlimed(ch)
		return
	}
	sess, err := s.conn.Client().NewSession()
	if err != nil {
		s.fail(ch, err)
		return
	}

	s.mu.Lock()
	size := ch.size
	term := ch.term
	if term == terminfo.Name && !s.ghosttyTerm {
		term = terminfo.Fallback
	}
	s.mu.Unlock()

	modes := ssh.TerminalModes{
		ssh.ECHO:          1,
		ssh.VERASE:        0x7f,
		ssh.VINTR:         0x03,
		ssh.IUTF8:         1,
		ssh.TTY_OP_ISPEED: 38400,
		ssh.TTY_OP_OSPEED: 38400,
	}
	if err := requestPty(sess, term, size, modes); err != nil {
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
	if ch.size != size {
		windowChange(sess, ch.size)
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

	err = sess.Wait()
	exit, ok := exitMessage(err)
	var missing *ssh.ExitMissingError
	if errors.As(err, &missing) {
		// A dropped connection closes its channels just before Wait
		// returns; give it a moment to show, so the drop is reported
		// rather than an exit.
		select {
		case <-s.conn.Done():
			ok = false
		case <-time.After(100 * time.Millisecond):
		}
	}
	s.mu.Lock()
	closed := ch.closed
	s.mu.Unlock()
	if ok && !closed {
		s.send(ch.id, exit)
	}
	s.drop(ch)
	if !ok && !closed {
		// The connection failed; once it has ended, finishIfIdle says
		// why.
		<-s.conn.Done()
	}
	s.finishIfIdle()
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

// finishIfIdle ends the helper once the last channel is gone, reporting
// a disconnect if the channel ended because the connection dropped.
func (s *Server) finishIfIdle() {
	s.mu.Lock()
	idle := s.state == stateConnected && len(s.channels) == 0
	conn := s.conn
	s.mu.Unlock()
	if !idle {
		return
	}
	// A dropped connection closes its channels just before Wait returns
	// and, through a jump host, ends in the same EOF as our own close.
	// Give it a moment to show before taking the end for ours.
	select {
	case <-conn.Done():
	case <-time.After(100 * time.Millisecond):
		conn.Close()
	}
	if err := conn.Wait(); err != nil {
		s.finish(err, LostReason(err))
		return
	}
	s.finish(nil, "")
}

// watch reports the connection failing.
func (s *Server) watch(conn *Conn) {
	err := conn.Wait()
	s.mu.Lock()
	closing := s.state == stateClosing || len(s.channels) == 0
	s.mu.Unlock()
	// Otherwise finishIfIdle or finish closed it and decides.
	if closing || err == nil {
		return
	}
	s.finish(err, LostReason(err))
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
		conn, cancel := s.conn, s.cancel
		s.mu.Unlock()

		if reason != "" {
			log.Printf("disconnected: %s", reason)
			s.send(0, &proto.Disconnected{Reason: reason})
		}
		for _, ch := range chans {
			ch.out.Close()
			ch.in.Close()
		}
		if cancel != nil {
			cancel()
		}
		if conn != nil {
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

// winSize is a terminal's size in cells and, if known, pixels.
type winSize struct {
	cols, rows    uint16
	width, height uint32
}

// requestPty is Session.RequestPty with the pixel size, which that
// leaves at zero.
func requestPty(sess *ssh.Session, term string, size winSize, modes ssh.TerminalModes) error {
	var list []byte
	for _, op := range slices.Sorted(maps.Keys(modes)) {
		list = append(list, op)
		list = binary.BigEndian.AppendUint32(list, modes[op])
	}
	list = append(list, 0) // TTY_OP_END
	ok, err := sess.SendRequest("pty-req", true, ssh.Marshal(&struct {
		Term                         string
		Columns, Rows, Width, Height uint32
		Modes                        string
	}{term, uint32(size.cols), uint32(size.rows), size.width, size.height, string(list)}))
	if err == nil && !ok {
		err = errors.New("refused")
	}
	return err
}

// windowChange is Session.WindowChange with the pixel size.
func windowChange(sess *ssh.Session, size winSize) error {
	_, err := sess.SendRequest("window-change", false, ssh.Marshal(&struct {
		Columns, Rows, Width, Height uint32
	}{uint32(size.cols), uint32(size.rows), size.width, size.height}))
	return err
}

// cwdCommand starts the user's login shell in dir, or in their home if
// dir is gone.
func cwdCommand(dir string) string {
	return "cd -- " + shellQuote(dir) + ` 2>/dev/null; exec "${SHELL:-/bin/sh}" -l`
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}
