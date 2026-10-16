package helper

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"

	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
)

const (
	password = "hunter2"
	otp      = "cccccbhuvtgfhkedvdibjtdldjvjrfcdhihuvdjjgerk"
	timeout  = 5 * time.Second
)

// harness plays slime: it speaks the control protocol to Serve and
// holds the slime ends of each channel's pipes.
type harness struct {
	t        *testing.T
	ctl      *proto.Writer
	ctlIn    *io.PipeWriter
	msgs     chan message
	serveErr chan error

	mu   sync.Mutex
	ends map[uint64]any
	next uint64
}

type message struct {
	id uint32
	m  proto.Message
}

func startServer(t *testing.T, opts sshtest.Options) *sshtest.Server {
	t.Helper()
	srv, err := sshtest.Start(opts)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { srv.Close() })
	return srv
}

func knownHostsFile(t *testing.T, lines ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "known_hosts")
	if len(lines) > 0 {
		if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return path
}

func newHarness(t *testing.T, srv *sshtest.Server, knownHosts string, mods ...func(*Options)) *harness {
	t.Helper()
	h := &harness{
		t:        t,
		msgs:     make(chan message, 64),
		serveErr: make(chan error, 1),
		ends:     map[uint64]any{},
	}
	ctlInR, ctlInW := io.Pipe()
	ctlOutR, ctlOutW := io.Pipe()
	h.ctlIn = ctlInW
	h.ctl = proto.NewWriter(ctlInW)
	opts := Options{
		Dest:       Destination{User: "alde", Host: "127.0.0.1", Port: srv.Port()},
		KnownHosts: []string{knownHosts},
		OpenPipes:  h.openPipes,
	}
	for _, mod := range mods {
		mod(&opts)
	}
	go func() {
		h.serveErr <- Serve(opts, ctlInR, ctlOutW)
		ctlOutW.Close()
	}()
	go func() {
		r := proto.NewReader(ctlOutR)
		for {
			f, err := r.Read()
			if err != nil {
				close(h.msgs)
				return
			}
			m, err := proto.Decode(f)
			if err != nil {
				t.Errorf("decoding from helper: %v", err)
				continue
			}
			h.msgs <- message{f.ID, m}
		}
	}()
	t.Cleanup(func() { ctlInW.Close() })

	h.send(0, &proto.Hello{Version: proto.Version})
	h.expect(0, &proto.HelloReply{Version: proto.Version})
	return h
}

func (h *harness) send(id uint32, m proto.Message) {
	h.t.Helper()
	if err := h.ctl.Send(id, m); err != nil {
		h.t.Fatalf("sending %T: %v", m, err)
	}
}

func (h *harness) expect(id uint32, want proto.Message) {
	h.t.Helper()
	select {
	case got, ok := <-h.msgs:
		if !ok {
			h.t.Fatalf("control closed, want %T on %d", want, id)
		}
		if got.id != id || !reflect.DeepEqual(got.m, want) {
			h.t.Fatalf("got %#v on %d, want %#v on %d", got.m, got.id, want, id)
		}
	case <-time.After(timeout):
		h.t.Fatalf("timed out waiting for %#v on %d", want, id)
	}
}

// expectDisconnected waits for a Disconnected whose reason mentions
// substr.
func (h *harness) expectDisconnected(substr string) {
	h.t.Helper()
	select {
	case got := <-h.msgs:
		d, ok := got.m.(*proto.Disconnected)
		if !ok || !strings.Contains(d.Reason, substr) {
			h.t.Fatalf("got %#v, want Disconnected with %q", got.m, substr)
		}
	case <-time.After(timeout):
		h.t.Fatal("timed out waiting for Disconnected")
	}
}

func (h *harness) expectServeReturn() error {
	h.t.Helper()
	select {
	case err := <-h.serveErr:
		return err
	case <-time.After(timeout):
		h.t.Fatal("Serve didn't return")
		return nil
	}
}

func (h *harness) openPipes(in, out uint64) (io.ReadCloser, io.WriteCloser, error) {
	h.mu.Lock()
	defer h.mu.Unlock()
	r, ok1 := h.ends[in].(io.ReadCloser)
	w, ok2 := h.ends[out].(io.WriteCloser)
	if !ok1 && !ok2 {
		// Not ours: real handles.
		return openHandles(in, out)
	}
	if !ok1 || !ok2 {
		return nil, nil, fmt.Errorf("bad handles %d, %d", in, out)
	}
	return r, w, nil
}

// open sends an Open for channel id and returns slime's side of it.
func (h *harness) open(id uint32, cols, rows uint16, cwd string) *term {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	h.mu.Lock()
	h.next += 2
	in, out := h.next, h.next+1
	h.ends[in], h.ends[out] = inR, outW
	h.mu.Unlock()
	h.send(id, &proto.Open{In: in, Out: out, Cols: cols, Rows: rows, Cwd: cwd})
	return &term{t: h.t, keys: inW, screen: newScreen(outR)}
}

// term is slime's end of a channel: keys in, screen out.
type term struct {
	t    *testing.T
	keys *io.PipeWriter
	*screen
}

func (tm *term) typ(s string) {
	tm.t.Helper()
	go tm.keys.Write([]byte(s))
}

// screen collects a channel's output for expect to search.
type screen struct {
	mu  sync.Mutex
	buf strings.Builder
	pos int
	eof bool
}

func newScreen(r io.Reader) *screen {
	s := &screen{}
	go func() {
		b := make([]byte, 4096)
		for {
			n, err := r.Read(b)
			s.mu.Lock()
			s.buf.Write(b[:n])
			if err != nil {
				s.eof = true
			}
			s.mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	return s
}

// expect waits for substr to appear after the last match.
func (s *screen) expect(t *testing.T, substr string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		s.mu.Lock()
		all := s.buf.String()
		i := strings.Index(all[s.pos:], substr)
		if i >= 0 {
			s.pos += i + len(substr)
			s.mu.Unlock()
			return
		}
		eof := s.eof
		s.mu.Unlock()
		if eof || time.Now().After(deadline) {
			t.Fatalf("screen never showed %q; got:\n%s", substr, all)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (s *screen) expectEOF(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		s.mu.Lock()
		eof := s.eof
		s.mu.Unlock()
		if eof {
			return
		}
		if time.Now().After(deadline) {
			t.Fatal("channel output never closed")
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (s *screen) contents() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.buf.String()
}

// login opens channel 1 on a server with password auth and logs in.
func login(t *testing.T, h *harness) *term {
	t.Helper()
	tm := h.open(1, 100, 30, "")
	tm.expect(t, "alde@127.0.0.1's password: ")
	tm.typ(password + "\r")
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})
	tm.expect(t, "$ ")
	return tm
}

func TestShell(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := login(t, h)

	tm.typ("info\r")
	tm.expect(t, "term=xterm-256color size=100x30 cwd=~ iutf8=1 verase=127")

	h.send(1, &proto.Resize{Cols: 120, Rows: 40})
	tm.typ("size\r")
	tm.expect(t, "size=120x40")

	tm.typ("exit 3\r")
	h.expect(1, &proto.Exit{Status: 3})
	tm.expectEOF(t)
	// The last channel ending ends the helper.
	if err := h.expectServeReturn(); err != nil {
		t.Errorf("Serve = %v", err)
	}
}

func TestPasswordNotEchoed(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := login(t, h)
	if strings.Contains(tm.contents(), password) {
		t.Errorf("password was echoed:\n%s", tm.contents())
	}
}

func TestWrongPasswordRetries(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	tm.typ("wrong\r")
	tm.expect(t, "password: ")
	tm.typ(password + "\r")
	h.expect(0, &proto.Connected{})
}

func TestDuoOTP(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Duo: true})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Password: ")
	tm.typ(password + "\r")
	tm.expect(t, "Duo two-factor login for alde\r\n\r\nEnter a passcode")
	tm.expect(t, "Passcode or option (1-1): ")
	// What a YubiKey types: the OTP and Enter, echoed.
	tm.typ(otp + "\r")
	tm.expect(t, otp+"\r\n")
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})
	tm.expect(t, "$ ")
}

func TestDuoPushWaits(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Duo: true, PushDelay: 300 * time.Millisecond})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Password: ")
	tm.typ(password + "\r")
	tm.expect(t, "Passcode or option (1-1): ")
	start := time.Now()
	tm.typ("1\r")
	h.expect(0, &proto.Connected{})
	if d := time.Since(start); d < 300*time.Millisecond {
		t.Errorf("connected after %v, before the push was approved", d)
	}
}

// Keys typed during the prompts reach the shell.
func TestTypeahead(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	tm.typ(password + "\rinfo\r")
	h.expect(0, &proto.Connected{})
	tm.expect(t, "term=xterm-256color")
}

func TestBanner(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Banner: "Authorized use only.\n"})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Authorized use only.\r\n")
	tm.expect(t, "password: ")
}

func TestUnknownHostAccepted(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	h := newHarness(t, srv, kh)
	tm := h.open(1, 80, 24, "")
	tm.expect(t, fmt.Sprintf("The authenticity of host '%s' can't be established.", knownhosts.Normalize(srv.Addr)))
	tm.expect(t, "ED25519 key fingerprint is "+ssh.FingerprintSHA256(srv.Signer.PublicKey()))
	tm.typ("maybe\r")
	tm.expect(t, "Please type 'yes', 'no' or the fingerprint: ")
	tm.typ("yes\r")
	tm.expect(t, "Permanently added")
	tm.expect(t, "password: ")
	tm.typ(password + "\r")
	h.expect(0, &proto.Connected{})

	data, err := os.ReadFile(kh)
	if err != nil {
		t.Fatal(err)
	}
	if strings.TrimSpace(string(data)) != srv.KnownHostsLine() {
		t.Errorf("known_hosts = %q, want %q", data, srv.KnownHostsLine())
	}

	// Next time it goes straight to the password.
	tm.typ("exit\r")
	h.expectServeReturn()
	h2 := newHarness(t, srv, kh)
	tm2 := h2.open(1, 80, 24, "")
	tm2.expect(t, "password: ")
	if strings.Contains(tm2.contents(), "authenticity") {
		t.Errorf("asked about a known host:\n%s", tm2.contents())
	}
}

func TestUnknownHostRejected(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	h := newHarness(t, srv, kh)
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "(yes/no/[fingerprint])? ")
	tm.typ("no\r")
	tm.expect(t, "Host key verification failed.")
	h.expectDisconnected("host key verification failed")
	tm.expectEOF(t)
	if err := h.expectServeReturn(); err == nil {
		t.Error("Serve succeeded")
	}
	if _, err := os.Stat(kh); err == nil {
		t.Error("known_hosts was written")
	}
}

func TestChangedHostKeyRefused(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	other := startServer(t, sshtest.Options{})
	stale := knownhosts.Line([]string{knownhosts.Normalize(srv.Addr)}, other.Signer.PublicKey())
	h := newHarness(t, srv, knownHostsFile(t, stale))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "REMOTE HOST IDENTIFICATION HAS CHANGED")
	h.expectDisconnected("host key verification failed")
	if strings.Contains(tm.contents(), "password") {
		t.Errorf("asked for a password after a changed key:\n%s", tm.contents())
	}
}

func TestCtrlCAtPrompt(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	tm.typ("\x03")
	h.expectDisconnected("interrupted")
	tm.expectEOF(t)
	h.expectServeReturn()
}

func TestCloseWhileAuthenticating(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	h.send(1, &proto.Close{})
	h.expectDisconnected("cancelled")
	tm.expectEOF(t)
	if err := h.expectServeReturn(); err != nil {
		t.Errorf("Serve = %v", err)
	}
}

func TestSecondChannelSkipsAuth(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm1 := login(t, h)

	dir := "/home/alde/it's here"
	tm2 := h.open(2, 90, 20, dir)
	h.expect(2, &proto.Opened{})
	tm2.expect(t, "$ ")
	if strings.Contains(tm2.contents(), "password") {
		t.Errorf("second channel prompted:\n%s", tm2.contents())
	}
	tm2.typ("info\r")
	tm2.expect(t, "size=90x20 cwd="+dir)

	// Closing the first keeps the connection for the second.
	h.send(1, &proto.Close{})
	tm1.expectEOF(t)
	tm2.typ("size\r")
	tm2.expect(t, "size=90x20")

	tm2.typ("kill\r")
	h.expect(2, &proto.Exit{Status: -1, Signal: "KILL"})
	if err := h.expectServeReturn(); err != nil {
		t.Errorf("Serve = %v", err)
	}
}

// Channels opened while the first is still prompting start after it.
func TestOpenWhileAuthenticating(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm1 := h.open(1, 80, 24, "")
	tm1.expect(t, "password: ")
	tm2 := h.open(2, 80, 24, "")
	tm1.typ(password + "\r")
	h.expect(0, &proto.Connected{})
	tm1.expect(t, "$ ")
	tm2.expect(t, "$ ")
}

func TestMaxSessions(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, MaxSessions: 1})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	login(t, h)
	tm2 := h.open(2, 80, 24, "")
	select {
	case got := <-h.msgs:
		e, ok := got.m.(*proto.Error)
		if !ok || got.id != 2 || !strings.Contains(e.Message, "open failed") {
			t.Fatalf("got %#v on %d, want Error on 2", got.m, got.id)
		}
	case <-time.After(timeout):
		t.Fatal("no error for the refused channel")
	}
	tm2.expectEOF(t)
}

func TestConnectionLost(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := login(t, h)
	srv.Close()
	// The channel may report its end first; it has no exit status.
	got := <-h.msgs
	if _, ok := got.m.(*proto.Exit); ok {
		if !reflect.DeepEqual(got.m, &proto.Exit{Status: -1}) {
			t.Errorf("exit = %#v", got.m)
		}
		h.expectDisconnected("closed by remote host")
	} else if d, ok := got.m.(*proto.Disconnected); !ok || !strings.Contains(d.Reason, "closed by remote host") {
		t.Fatalf("got %#v, want Disconnected", got.m)
	}
	tm.expectEOF(t)
	if err := h.expectServeReturn(); err == nil {
		t.Error("Serve succeeded after the connection dropped")
	}
}

// slime going away ends everything.
func TestControlEOF(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := login(t, h)
	h.ctlIn.Close()
	tm.expectEOF(t)
	if err := h.expectServeReturn(); err != nil {
		t.Errorf("Serve = %v", err)
	}
}

// A flood on one channel doesn't hold up another.
func TestFloodDoesNotBlockOthers(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm1 := login(t, h)
	tm2 := h.open(2, 80, 24, "")
	h.expect(2, &proto.Opened{})
	tm2.expect(t, "$ ")

	tm1.typ("flood 20000\r")
	tm2.typ("size\r")
	tm2.expect(t, "size=80x24")
	tm1.expect(t, "line 19999")
}

func TestUnknownChannelIgnored(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := login(t, h)
	h.send(9, &proto.Resize{Cols: 1, Rows: 1})
	h.send(9, &proto.Close{})
	tm.typ("size\r")
	tm.expect(t, "size=100x30")
}

func TestHandshakeVersionMismatch(t *testing.T) {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	errc := make(chan error, 1)
	go func() { errc <- Serve(Options{}, inR, outW); outW.Close() }()
	go proto.NewWriter(inW).Send(0, &proto.Hello{Version: 99})
	// The reply still goes out so slime can say which side is stale.
	f, err := proto.NewReader(outR).Read()
	if err != nil {
		t.Fatal(err)
	}
	if m, _ := proto.Decode(f); !reflect.DeepEqual(m, &proto.HelloReply{Version: proto.Version}) {
		t.Errorf("reply = %#v", m)
	}
	if err := <-errc; err == nil || !strings.Contains(err.Error(), "protocol 99") {
		t.Errorf("Serve = %v", err)
	}
}

func TestNoHello(t *testing.T) {
	if err := Serve(Options{}, strings.NewReader(""), io.Discard); err == nil {
		t.Error("Serve succeeded without a hello")
	}
}

func TestCwdCommand(t *testing.T) {
	for _, dir := range []string{"/tmp", "/home/alde/it's here", "/a b/'c'/d"} {
		got, ok := sshtest.ParseCwdCommand(cwdCommand(dir))
		if !ok || got != dir {
			t.Errorf("%q: round trip = %q, %v", dir, got, ok)
		}
	}
}
