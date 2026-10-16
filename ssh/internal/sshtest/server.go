// Package sshtest is an in-process SSH server for testing the helper
// without a real host. Its sessions run a small fake shell, and its
// keyboard-interactive auth can mimic pam_duo.
package sshtest

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
	"golang.org/x/term"
)

type Options struct {
	// Password is accepted by password auth, or by the first Duo round
	// (which is skipped without one).
	Password string
	// Duo replaces password auth with keyboard-interactive shaped like
	// pam_duo's: a password round, then a passcode-or-option menu that
	// takes a YubiKey OTP or "1" for a push.
	Duo bool
	// PushDelay is how long a Duo push takes to be approved.
	PushDelay time.Duration
	// AuthorizedKeys log in by public key.
	AuthorizedKeys []ssh.PublicKey
	// KeyThenDuo requires an authorized key and then the Duo prompts,
	// like sshd's AuthenticationMethods publickey,keyboard-interactive.
	KeyThenDuo bool
	// MaxSessions limits open session channels per server, like sshd's
	// MaxSessions. Zero is unlimited.
	MaxSessions int
	Banner      string
}

type Server struct {
	// Addr is host:port.
	Addr   string
	Signer ssh.Signer

	opts   Options
	ln     net.Listener
	config *ssh.ServerConfig

	mu       sync.Mutex
	conns    map[net.Conn]struct{}
	sessions int
	closed   bool
	wg       sync.WaitGroup
}

// Start listens on a free loopback port with a new ed25519 host key.
func Start(opts Options) (*Server, error) {
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	signer, err := ssh.NewSignerFromKey(priv)
	if err != nil {
		return nil, err
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	s := &Server{
		Addr:   ln.Addr().String(),
		Signer: signer,
		opts:   opts,
		ln:     ln,
		conns:  map[net.Conn]struct{}{},
	}
	s.config = &ssh.ServerConfig{}
	switch {
	case opts.KeyThenDuo:
		s.config.PublicKeyCallback = s.keyThenDuo
	case opts.Duo:
		s.config.KeyboardInteractiveCallback = s.duo
	default:
		s.config.PasswordCallback = s.password
	}
	if len(opts.AuthorizedKeys) > 0 && !opts.KeyThenDuo {
		s.config.PublicKeyCallback = s.publicKey
	}
	if opts.Banner != "" {
		s.config.BannerCallback = func(ssh.ConnMetadata) string { return opts.Banner }
	}
	s.config.AddHostKey(signer)
	s.wg.Add(1)
	go s.accept()
	return s, nil
}

func (s *Server) Port() int {
	return s.ln.Addr().(*net.TCPAddr).Port
}

// KnownHostsLine is the known_hosts entry for this server.
func (s *Server) KnownHostsLine() string {
	return knownhosts.Line([]string{knownhosts.Normalize(s.Addr)}, s.Signer.PublicKey())
}

// Close stops listening and drops every connection, as a server going
// away would.
func (s *Server) Close() error {
	s.mu.Lock()
	s.closed = true
	for c := range s.conns {
		c.Close()
	}
	s.mu.Unlock()
	err := s.ln.Close()
	s.wg.Wait()
	return err
}

func (s *Server) accept() {
	defer s.wg.Done()
	for {
		c, err := s.ln.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			c.Close()
			return
		}
		s.conns[c] = struct{}{}
		s.mu.Unlock()
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			s.serveConn(c)
			s.mu.Lock()
			delete(s.conns, c)
			s.mu.Unlock()
		}()
	}
}

func (s *Server) password(_ ssh.ConnMetadata, pw []byte) (*ssh.Permissions, error) {
	if string(pw) != s.opts.Password {
		return nil, errors.New("wrong password")
	}
	return nil, nil
}

func (s *Server) publicKey(_ ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
	for _, k := range s.opts.AuthorizedKeys {
		if bytes.Equal(k.Marshal(), key.Marshal()) {
			return nil, nil
		}
	}
	return nil, errors.New("unknown key")
}

func (s *Server) keyThenDuo(conn ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
	if _, err := s.publicKey(conn, key); err != nil {
		return nil, err
	}
	return nil, &ssh.PartialSuccessError{
		Next: ssh.ServerAuthCallbacks{KeyboardInteractiveCallback: s.duo},
	}
}

const duoMenu = `Duo two-factor login for %s

Enter a passcode or select one of the following options:

 1. Duo Push to XXX-XXX-1234

Passcode or option (1-1): `

func (s *Server) duo(conn ssh.ConnMetadata, client ssh.KeyboardInteractiveChallenge) (*ssh.Permissions, error) {
	if s.opts.Password != "" {
		ans, err := client("", "", []string{"Password: "}, []bool{false})
		if err != nil {
			return nil, err
		}
		if len(ans) != 1 || ans[0] != s.opts.Password {
			return nil, errors.New("wrong password")
		}
	}
	ans, err := client("", "", []string{fmt.Sprintf(duoMenu, conn.User())}, []bool{true})
	if err != nil {
		return nil, err
	}
	switch {
	case len(ans) != 1:
		return nil, errors.New("no answer")
	case ans[0] == "1":
		time.Sleep(s.opts.PushDelay)
		return nil, nil
	case IsOTP(ans[0]):
		return nil, nil
	}
	return nil, errors.New("wrong passcode")
}

// IsOTP reports whether s looks like a Yubico OTP: 44 modhex characters.
func IsOTP(s string) bool {
	if len(s) != 44 {
		return false
	}
	for _, c := range s {
		if !strings.ContainsRune("cbdefghijklnrtuv", c) {
			return false
		}
	}
	return true
}

func (s *Server) serveConn(c net.Conn) {
	defer c.Close()
	_, chans, reqs, err := ssh.NewServerConn(c, s.config)
	if err != nil {
		return
	}
	go ssh.DiscardRequests(reqs)
	for nc := range chans {
		if nc.ChannelType() != "session" {
			nc.Reject(ssh.UnknownChannelType, "unknown channel type")
			continue
		}
		s.mu.Lock()
		if s.opts.MaxSessions > 0 && s.sessions >= s.opts.MaxSessions {
			s.mu.Unlock()
			nc.Reject(ssh.Prohibited, "open failed")
			continue
		}
		s.sessions++
		s.mu.Unlock()
		ch, reqs, err := nc.Accept()
		if err != nil {
			s.endSession()
			continue
		}
		go func() {
			defer s.endSession()
			(&session{ch: ch}).serve(reqs)
		}()
	}
}

func (s *Server) endSession() {
	s.mu.Lock()
	s.sessions--
	s.mu.Unlock()
}

type session struct {
	ch ssh.Channel

	mu         sync.Mutex
	term       string
	cols, rows int
	modes      map[uint8]uint32
	t          *term.Terminal
	started    bool
}

func (s *session) serve(reqs <-chan *ssh.Request) {
	for req := range reqs {
		switch req.Type {
		case "pty-req":
			var p struct {
				Term                      string
				Cols, Rows, Width, Height uint32
				Modes                     string
			}
			if ssh.Unmarshal(req.Payload, &p) != nil {
				req.Reply(false, nil)
				continue
			}
			s.mu.Lock()
			s.term, s.cols, s.rows = p.Term, int(p.Cols), int(p.Rows)
			s.modes = parseModes([]byte(p.Modes))
			s.mu.Unlock()
			req.Reply(true, nil)
		case "window-change":
			var w struct{ Cols, Rows, Width, Height uint32 }
			if ssh.Unmarshal(req.Payload, &w) != nil {
				continue
			}
			s.mu.Lock()
			s.cols, s.rows = int(w.Cols), int(w.Rows)
			if s.t != nil {
				s.t.SetSize(s.cols, s.rows)
			}
			s.mu.Unlock()
		case "shell", "exec":
			cwd := "~"
			if req.Type == "exec" {
				var e struct{ Command string }
				if ssh.Unmarshal(req.Payload, &e) != nil {
					req.Reply(false, nil)
					continue
				}
				dir, ok := ParseCwdCommand(e.Command)
				if !ok {
					req.Reply(false, nil)
					continue
				}
				cwd = dir
			}
			s.mu.Lock()
			ok := !s.started
			s.started = true
			s.mu.Unlock()
			req.Reply(ok, nil)
			if ok {
				go s.run(cwd)
			}
		default:
			req.Reply(false, nil)
		}
	}
}

// run is the fake shell. Commands:
//
//	info       term, size, cwd, and the tty modes the helper sends
//	size       the current size
//	flood N    N numbered lines
//	exit [N]   exit with status N
//	kill       end by signal KILL
func (s *session) run(cwd string) {
	defer s.ch.Close()
	t := term.NewTerminal(s.ch, "$ ")
	s.mu.Lock()
	s.t = t
	t.SetSize(s.cols, s.rows)
	s.mu.Unlock()
	fmt.Fprintf(t, "fake shell\n")
	for {
		line, err := t.ReadLine()
		if err != nil {
			if err != io.EOF {
				log.Printf("sshtest: %v", err)
			}
			return
		}
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		s.mu.Lock()
		termName, cols, rows, modes := s.term, s.cols, s.rows, s.modes
		s.mu.Unlock()
		switch f[0] {
		case "info":
			fmt.Fprintf(t, "term=%s size=%dx%d cwd=%s iutf8=%d verase=%d\n",
				termName, cols, rows, cwd, modes[ssh.IUTF8], modes[ssh.VERASE])
		case "size":
			fmt.Fprintf(t, "size=%dx%d\n", cols, rows)
		case "flood":
			n, _ := strconv.Atoi(arg(f, 1))
			for i := range n {
				fmt.Fprintf(t, "line %d\n", i)
			}
		case "exit":
			n, _ := strconv.Atoi(arg(f, 1))
			s.ch.SendRequest("exit-status", false, ssh.Marshal(struct{ Status uint32 }{uint32(n)}))
			return
		case "kill":
			s.ch.SendRequest("exit-signal", false, ssh.Marshal(struct {
				Signal     string
				CoreDumped bool
				Error      string
				Lang       string
			}{Signal: "KILL"}))
			return
		default:
			fmt.Fprintf(t, "%s: command not found\n", f[0])
		}
	}
}

func arg(f []string, i int) string {
	if i < len(f) {
		return f[i]
	}
	return ""
}

// parseModes decodes RFC 4254 encoded terminal modes: opcode bytes each
// followed by a u32, ended by opcode 0 (or one of the 160+ that have no
// defined argument).
func parseModes(b []byte) map[uint8]uint32 {
	m := map[uint8]uint32{}
	for len(b) >= 5 && b[0] != 0 && b[0] < 160 {
		m[b[0]] = binary.BigEndian.Uint32(b[1:5])
		b = b[5:]
	}
	return m
}

// ParseCwdCommand extracts the directory from the helper's
// `cd -- '<dir>' ...` command for starting a shell in a directory.
func ParseCwdCommand(cmd string) (string, bool) {
	rest, ok := strings.CutPrefix(cmd, "cd -- ")
	if !ok {
		return "", false
	}
	// A run of single-quoted parts and \' escapes, as the helper's
	// quoting produces.
	var dir strings.Builder
	for len(rest) > 0 && rest[0] != ' ' {
		switch {
		case rest[0] == '\'':
			end := strings.IndexByte(rest[1:], '\'')
			if end < 0 {
				return "", false
			}
			dir.WriteString(rest[1 : 1+end])
			rest = rest[2+end:]
		case strings.HasPrefix(rest, `\'`):
			dir.WriteByte('\'')
			rest = rest[2:]
		default:
			return "", false
		}
	}
	return dir.String(), true
}
