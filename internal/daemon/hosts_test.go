//go:build windows

package daemon

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/remote"
	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/sshbridge"
	"github.com/aldehir/slime/internal/sshtest"
)

const hostPassword = "hunter2"

// fakeHost answers the daemon's commands on a host: the probe, the
// install (into memory), and `slime connect`, which it bridges to a
// second in-process Server playing the host's daemon.
type fakeHost struct {
	daemon *Server

	mu        sync.Mutex
	installed []string
	connects  []string
}

func (f *fakeHost) exec(command string, stdin io.Reader, stdout, stderr io.Writer) int {
	args := shArgs(command)
	switch {
	case strings.Contains(command, "uname -sm"):
		f.mu.Lock()
		defer f.mu.Unlock()
		fmt.Fprintf(stdout, "Linux x86_64\n/home/alde/.cache/slime/bin\n")
		for _, name := range f.installed {
			fmt.Fprintln(stdout, name)
		}
		return 0
	case strings.Contains(command, "gzip -dc"):
		zr, err := gzip.NewReader(stdin)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		if _, err := io.ReadAll(zr); err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		f.mu.Lock()
		f.installed = append(f.installed, filepath.Base(filepath.Dir(args[0])))
		f.mu.Unlock()
		return 0
	case strings.Contains(command, " connect --term "):
		f.mu.Lock()
		f.connects = append(f.connects, args[1])
		f.mu.Unlock()
		a, b := net.Pipe()
		go f.daemon.handle(a)
		go func() {
			io.Copy(b, stdin)
			b.Close()
		}()
		io.Copy(stdout, b)
		return 0
	}
	fmt.Fprintf(stderr, "sh: %s: not found\n", command)
	return 127
}

// shArgs are the arguments after the script in the daemon's sh -c
// commands.
func shArgs(command string) []string {
	var args []string
	for _, q := range strings.Split(command, "' '")[1:] {
		args = append(args, strings.Trim(q, "'"))
	}
	return args
}

// fakeRemote is a manifest with a tiny stand-in for the Linux build.
func fakeRemote(t *testing.T) *remote.Manifest {
	t.Helper()
	dir := t.TempDir()
	var gz bytes.Buffer
	w := gzip.NewWriter(&gz)
	w.Write([]byte("#!/bin/sh\necho fake slime\n"))
	w.Close()
	sum := sha256.Sum256(gz.Bytes())
	if err := os.WriteFile(filepath.Join(dir, remote.Name("linux", "amd64")), gz.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	line := fmt.Sprintf("linux amd64 %s %d\n", hex.EncodeToString(sum[:]), gz.Len())
	if err := os.WriteFile(filepath.Join(dir, remote.ManifestName), []byte(line), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := remote.Load(dir)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

// hostHarness is a local daemon whose hosts resolve to one fake host
// over sshtest.
type hostHarness struct {
	*harness
	ssh  *sshtest.Server
	host *fakeHost
	// builds is what the local daemon has to install on hosts.
	builds *remote.Manifest
	// remote is the host's daemon.
	remote *harness
	// ln accepts connections to the local daemon over TCP, which has
	// buffers as the pipe does: a bridge's two ends may both be writing.
	ln net.Listener
}

// dial connects to the local daemon over TCP, without saying hello.
func (h *hostHarness) dial() net.Conn {
	h.t.Helper()
	conn, err := net.Dial("tcp", h.ln.Addr().String())
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { conn.Close() })
	return conn
}

func newHostHarness(t *testing.T, sshOpts sshtest.Options, idle time.Duration) *hostHarness {
	t.Helper()
	return newHostHarnessConfig(t, sshOpts, idle, "")
}

// newHostHarnessConfig is newHostHarness whose local daemon has
// init.lua holding config.
func newHostHarnessConfig(t *testing.T, sshOpts sshtest.Options, idle time.Duration, config string) *hostHarness {
	t.Helper()
	var configPath string
	if config != "" {
		configPath = filepath.Join(t.TempDir(), "init.lua")
		if err := os.WriteFile(configPath, []byte(config), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	remoteH := newHarness(t)
	host := &fakeHost{daemon: remoteH.srv}
	sshOpts.Exec = host.exec
	if sshOpts.Password == "" {
		sshOpts.Password = hostPassword
	}
	srv, err := sshtest.Start(sshOpts)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { srv.Close() })
	kh := filepath.Join(t.TempDir(), "known_hosts")
	if err := os.WriteFile(kh, []byte(srv.KnownHostsLine()+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	builds := fakeRemote(t)

	h := &harness{t: t}
	local, err := NewServer(runtime(t), Options{
		Spawn:  func(o pty.Options) (pty.Pty, error) { return newFakePty(o), nil },
		Idle:   idle,
		Config: configPath,
		Hosts: HostOptions{Resolve: func(dest string) (sshbridge.Options, error) {
			// Named as the daemon names hosts (rpc.NormalizeDest).
			if !strings.HasPrefix(dest, "ssh://dev") {
				return sshbridge.Options{}, fmt.Errorf("no such host %q", dest)
			}
			return sshbridge.Options{
				Dest:       sshbridge.Destination{User: "alde", Host: "127.0.0.1", Port: srv.Port()},
				KnownHosts: []string{kh},
				Remote:     builds,
			}, nil
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	h.srv = local
	t.Cleanup(local.Close)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go local.handle(c)
		}
	}()
	return &hostHarness{harness: h, ssh: srv, host: host, builds: builds, remote: remoteH, ln: ln}
}

// recv reads the next message within the timeout.
func recv(t *testing.T, c *Client) (PaneID, Message) {
	t.Helper()
	type got struct {
		id PaneID
		m  Message
	}
	ch := make(chan got, 1)
	errc := make(chan error, 1)
	go func() {
		id, m, err := c.Recv()
		if err != nil {
			errc <- err
			return
		}
		ch <- got{id, m}
	}()
	select {
	case g := <-ch:
		return g.id, g.m
	case err := <-errc:
		t.Fatalf("reading: %v", err)
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for a message")
	}
	return NoPane, nil
}

// subscribeHosts has c hear every host's changes.
func subscribeHosts(t *testing.T, c *Client) {
	t.Helper()
	if err := c.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{"host.*"}}, nil); err != nil {
		t.Fatal(err)
	}
}

// hostConnect asks for dest, subscribed to what follows, and returns
// the host's id from the reply, which names the host as ssh://.
func hostConnect(t *testing.T, c *Client, dest string) uint32 {
	t.Helper()
	subscribeHosts(t, c)
	var h rpc.Host
	if err := c.Call(rpc.HostConnect, rpc.HostConnectParams{Dest: dest}, &h); err != nil {
		t.Fatal(err)
	}
	if want := rpc.NormalizeDest(dest); h.Dest != want {
		t.Fatalf("host.connect answered for %q, want %q", h.Dest, want)
	}
	return h.ID
}

// hostEvent reads until a host.changed or host.prompt for host id.
func hostEvent(t *testing.T, c *Client, id uint32) (state *rpc.Host, prompt *rpc.HostPromptParams) {
	t.Helper()
	for {
		_, m := recv(t, c)
		name, params, ok := Notification(m)
		if !ok {
			continue
		}
		switch name {
		case rpc.EvHostChanged:
			var h rpc.Host
			if err := json.Unmarshal(params, &h); err != nil {
				t.Fatal(err)
			}
			if h.ID == id {
				return &h, nil
			}
		case rpc.EvHostPrompt:
			var p rpc.HostPromptParams
			if err := json.Unmarshal(params, &p); err != nil {
				t.Fatal(err)
			}
			if p.Host == id {
				return nil, &p
			}
		}
	}
}

// awaitState reads until host id reaches want, collecting the status
// lines on the way. A terminal state other than want fails.
func awaitState(t *testing.T, c *Client, id uint32, want HostStatus) (texts []string, state *rpc.Host) {
	t.Helper()
	for {
		st, _ := hostEvent(t, c, id)
		if st == nil {
			continue
		}
		if st.State == want {
			return texts, st
		}
		if st.State != HostConnecting {
			t.Fatalf("host %d: %s (%s), want %s", id, st.State, st.Text, want)
		}
		texts = append(texts, st.Text)
	}
}

// awaitPrompt reads until a prompt for host id, applying host.changed
// to nothing.
func awaitPrompt(t *testing.T, c *Client, id uint32) *rpc.HostPromptParams {
	t.Helper()
	for {
		st, p := hostEvent(t, c, id)
		if p != nil {
			return p
		}
		if st.State != HostConnecting {
			t.Fatalf("host %d: %s (%s), want a prompt", id, st.State, st.Text)
		}
	}
}

// answer replies to host id's prompt.
func answer(c *Client, id uint32, choice rpc.Choice, answers ...string) error {
	return c.Call(rpc.HostAnswer, rpc.HostAnswerParams{Host: id, Choice: choice, Answers: answers}, nil)
}

// login connects dest with the password and returns the host's id.
func (h *hostHarness) login(c *Client, dest string) uint32 {
	h.t.Helper()
	return h.loginState(c, dest).ID
}

// loginState is login, returning the host as host.changed said it
// connected.
func (h *hostHarness) loginState(c *Client, dest string) *rpc.Host {
	h.t.Helper()
	id := hostConnect(h.t, c, dest)
	p := awaitPrompt(h.t, c, id)
	if p.Kind != rpc.PromptPassword {
		h.t.Fatalf("prompt = %#v, want a password", p)
	}
	if err := answer(c, id, rpc.ChoiceAccept, hostPassword); err != nil {
		h.t.Fatal(err)
	}
	_, st := awaitState(h.t, c, id, HostConnected)
	return st
}

// bridge opens a second connection bridged to host id and says hello
// to the host's daemon through it. A bridge the local daemon refuses
// fails with its Error.
func (h *hostHarness) bridge(id uint32, term string) (*Client, error) {
	h.t.Helper()
	b := h.dial()
	frame, _ := Encode(NoPane, &Bridge{Host: id, Term: term})
	if _, err := b.Write(frame); err != nil {
		return nil, err
	}
	c := &Client{rw: b, r: NewReader(b)}
	if err := c.Send(NoPane, &Hello{Version: Version}); err != nil {
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
		b.Close()
		return nil, fmt.Errorf("refused: %s", m.Message)
	default:
		b.Close()
		return nil, fmt.Errorf("first reply %#v", m)
	}
	h.t.Cleanup(func() { c.Close() })
	return c, nil
}

// expectBridgeClosed waits for the host's daemon to be gone from the
// other end of b: it reads EOF, or an Error saying why.
func expectBridgeClosed(t *testing.T, b *Client) {
	t.Helper()
	done := make(chan error, 1)
	go func() {
		for {
			_, m, err := b.Recv()
			if err != nil {
				done <- nil
				return
			}
			if _, ok := m.(*Error); !ok {
				done <- fmt.Errorf("got %#v", m)
				return
			}
		}
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("bridge still open: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Error("bridge still open")
	}
}

func TestHostConnectPrompts(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	c := h.connect()
	id := hostConnect(t, c, "dev1")

	p := awaitPrompt(t, c, id)
	if p.Kind != rpc.PromptPassword || p.Title != "Sign in to 127.0.0.1" || len(p.Questions) != 1 ||
		p.Questions[0].Label != "alde@127.0.0.1's password: " || p.Questions[0].Echo {
		t.Errorf("prompt = %#v", p)
	}
	answer(c, id, rpc.ChoiceAccept, "wrong")
	if p := awaitPrompt(t, c, id); p.Error == "" {
		t.Errorf("retry has no error: %#v", p)
	}
	answer(c, id, rpc.ChoiceAccept, hostPassword)
	texts, st := awaitState(t, c, id, HostConnected)
	if st.Text != "" {
		t.Errorf("connected with text %q", st.Text)
	}
	if !contains(texts, "installing slime") {
		t.Errorf("status lines %q lack the install", texts)
	}
	h.host.mu.Lock()
	installed := h.host.installed
	h.host.mu.Unlock()
	build, _ := h.builds.For("linux", "amd64")
	if len(installed) != 1 || installed[0] != build.ID {
		t.Errorf("installed %q", installed)
	}

	// Asking again answers with the state, without logging in again.
	if again := hostConnect(t, c, "dev1"); again != id {
		t.Errorf("second connect got host %d, want %d", again, id)
	}
	hosts := hostList(t, c)
	if len(hosts) != 1 || hosts[0].ID != id || hosts[0].State != HostConnected {
		t.Errorf("hosts = %+v", hosts)
	}
}

func hostList(t *testing.T, c *Client) []rpc.Host {
	t.Helper()
	var hosts rpc.HostListResult
	if err := c.Call(rpc.HostList, nil, &hosts); err != nil {
		t.Fatal(err)
	}
	return hosts.Hosts
}

func contains(ss []string, want string) bool {
	for _, s := range ss {
		if s == want {
			return true
		}
	}
	return false
}

func TestHostConnectRefused(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	c := h.connect()
	id := hostConnect(t, c, "dev1")
	for range 3 {
		awaitPrompt(t, c, id)
		answer(c, id, rpc.ChoiceAccept, "wrong")
	}
	_, st := awaitState(t, c, id, HostFailed)
	if !strings.Contains(st.Text, "Permission denied") {
		t.Errorf("failed with %q", st.Text)
	}
	// Nothing to bridge to.
	if _, err := h.bridge(id, ""); err == nil || !strings.Contains(err.Error(), "isn't connected") {
		t.Errorf("bridge to a failed host: %v", err)
	}
	// A host nobody asked for.
	nid := hostConnect(t, c, "nowhere")
	_, st = awaitState(t, c, nid, HostFailed)
	if !strings.Contains(st.Text, "no such host") {
		t.Errorf("unresolvable host failed with %q", st.Text)
	}
}

func TestHostConnectCancelled(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	c := h.connect()
	id := hostConnect(t, c, "dev1")
	awaitPrompt(t, c, id)
	answer(c, id, rpc.ChoiceCancel)
	if _, st := awaitState(t, c, id, HostFailed); st.Text != "cancelled" {
		t.Errorf("failed with %q", st.Text)
	}
}

// The bridge carries the client's Hello and requests to the host's
// daemon, and its replies back.
func TestBridge(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	c := h.connect()
	id := h.login(c, "dev1")

	b, err := h.bridge(id, "xterm-ghostty")
	if err != nil {
		t.Fatal(err)
	}
	if b.Hello.PID != uint32(os.Getpid()) {
		t.Errorf("hello from pid %d", b.Hello.PID)
	}
	var ws rpc.Workspace
	if err := b.Call(rpc.WorkspaceNew, rpc.WorkspaceNewParams{Name: "remote"}, &ws); err != nil {
		t.Fatal(err)
	}
	if l := h.remote.list(); len(l.Workspaces) != 1 || l.Workspaces[0].ID != ws.ID || l.Workspaces[0].Name != "remote" {
		t.Errorf("host daemon's workspaces = %+v", l.Workspaces)
	}
	if l := h.list(); len(l.Workspaces) != 0 {
		t.Errorf("local daemon took the workspace: %+v", l.Workspaces)
	}
	h.host.mu.Lock()
	connects := h.host.connects
	h.host.mu.Unlock()
	// The fake host has no tic, so xterm-ghostty falls back.
	if len(connects) != 1 || connects[0] != "xterm-256color" {
		t.Errorf("connects = %q", connects)
	}

	// Hanging up on the bridge hangs up on the host's daemon.
	b.Close()
	eventually(t, "detach on the host", func() bool { return !h.remote.attached(ws.ID) })
}

func TestBridgeUnknownHost(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	if _, err := h.bridge(99, ""); err == nil || !strings.Contains(err.Error(), "no host 99") {
		t.Errorf("err = %v", err)
	}
}

func TestHostLost(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	c := h.connect()
	id := h.login(c, "dev1")
	b, err := h.bridge(id, "")
	if err != nil {
		t.Fatal(err)
	}
	h.ssh.Close()
	_, st := awaitState(t, c, id, HostLost)
	if !strings.Contains(st.Text, "closed by remote host") {
		t.Errorf("lost with %q", st.Text)
	}
	expectBridgeClosed(t, b)
}

func TestHostDisconnect(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	c := h.connect()
	id := h.login(c, "dev1")
	b, err := h.bridge(id, "")
	if err != nil {
		t.Fatal(err)
	}
	c.Call(rpc.HostDisconnect, rpc.HostParams{Host: id}, nil)
	if _, st := awaitState(t, c, id, HostGone); st.Text != "disconnected" {
		t.Errorf("gone with %q", st.Text)
	}
	expectBridgeClosed(t, b)
	// Connecting again keeps the id, however the destination is spelled.
	if again := h.login(c, "ssh://dev1"); again != id {
		t.Errorf("reconnected as host %d, want %d", again, id)
	}
}

// Disconnecting while logging in gives up on it, as gone.
func TestHostDisconnectWhileConnecting(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	c := h.connect()
	id := hostConnect(t, c, "dev1")
	awaitPrompt(t, c, id)
	c.Call(rpc.HostDisconnect, rpc.HostParams{Host: id}, nil)
	awaitState(t, c, id, HostGone)
}

// The client answering the prompts hanging up cancels logging in; other
// clients see it fail.
func TestHostClientHangsUpMidLogin(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	watcher := h.connect()
	subscribeHosts(t, watcher)
	c := h.connect()
	id := hostConnect(t, c, "dev1")
	awaitPrompt(t, c, id)
	c.Close()
	if _, st := awaitState(t, watcher, id, HostFailed); st.Text != "cancelled" {
		t.Errorf("failed with %q", st.Text)
	}
}

// Another client's answers don't count.
func TestHostAnswerFromAnotherClient(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	other := h.connect()
	c := h.connect()
	id := hostConnect(t, c, "dev1")
	awaitPrompt(t, c, id)
	if err := answer(other, id, rpc.ChoiceAccept, hostPassword); err == nil {
		t.Error("another client's answer was taken")
	}
	time.Sleep(100 * time.Millisecond)
	answer(c, id, rpc.ChoiceAccept, hostPassword)
	awaitState(t, c, id, HostConnected)
}

// A connected host keeps the daemon alive with no clients.
func TestHostKeepsDaemonAlive(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 50*time.Millisecond)
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- h.srv.Serve(l) }()
	dial := func() *Client {
		conn, err := net.Dial("tcp", l.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		c, err := NewClient(conn)
		if err != nil {
			t.Fatal(err)
		}
		return c
	}
	c := dial()
	id := h.login(c, "dev1")
	c.Close()
	select {
	case <-done:
		t.Fatal("exited with a host connected")
	case <-time.After(200 * time.Millisecond):
	}
	c = dial()
	subscribeHosts(t, c)
	if err := c.Call(rpc.HostDisconnect, rpc.HostParams{Host: id}, nil); err != nil {
		t.Fatal(err)
	}
	awaitState(t, c, id, HostGone)
	c.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("Serve: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("didn't exit once the host was gone")
	}
}

// socksConnect asks the SOCKS5 proxy at url (socks5://host:port) to
// connect to name:port, and returns the tunnel and the reply code.
func socksConnect(t *testing.T, url, name string, port int) (net.Conn, byte) {
	t.Helper()
	c, err := net.Dial("tcp", strings.TrimPrefix(url, "socks5://"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(10 * time.Second))
	req := []byte{5, 1, 0, 5, 1, 0, 3, byte(len(name))}
	req = append(req, name...)
	req = append(req, byte(port>>8), byte(port))
	if _, err := c.Write(req); err != nil {
		t.Fatal(err)
	}
	// The method chosen, then the reply with an IPv4 address.
	var rep [2 + 10]byte
	if _, err := io.ReadFull(c, rep[:]); err != nil {
		t.Fatalf("reply: %v", err)
	}
	if rep[0] != 5 || rep[1] != 0 {
		t.Fatalf("method %v", rep[:2])
	}
	c.SetDeadline(time.Time{})
	return c, rep[3]
}

// A connected host has a proxy, through which a CONNECT reaches what the
// host reaches, by a name the host resolves; it's gone with the
// connection.
func TestHostProxy(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{Forwarding: true}, 0)
	c := h.connect()
	st := h.loginState(c, "dev1")
	if !strings.HasPrefix(st.Proxy, "socks5://127.0.0.1:") {
		t.Fatalf("connected with proxy %q", st.Proxy)
	}
	if hosts := hostList(t, c); len(hosts) != 1 || hosts[0].Proxy != st.Proxy {
		t.Errorf("hosts = %+v", hosts)
	}

	target, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer target.Close()
	go func() {
		conn, err := target.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		conn.Write([]byte("from the host's network:"))
		io.Copy(conn, conn)
	}()
	tunnel, rep := socksConnect(t, st.Proxy, "localhost", target.Addr().(*net.TCPAddr).Port)
	if rep != 0 {
		t.Fatalf("CONNECT replied %d", rep)
	}
	tunnel.Write([]byte("hi"))
	tunnel.(*net.TCPConn).CloseWrite()
	if got, _ := io.ReadAll(tunnel); string(got) != "from the host's network:hi" {
		t.Errorf("tunnel read %q", got)
	}
	tunnel.Close()

	if err := c.Call(rpc.HostDisconnect, rpc.HostParams{Host: st.ID}, nil); err != nil {
		t.Fatal(err)
	}
	_, gone := awaitState(t, c, st.ID, HostGone)
	if gone.Proxy != "" {
		t.Errorf("gone with proxy %q", gone.Proxy)
	}
	if conn, err := net.Dial("tcp", strings.TrimPrefix(st.Proxy, "socks5://")); err == nil {
		conn.Close()
		t.Error("proxy still listening after disconnect")
	}
}

// The tunnel is the host's: one that refuses forwarding refuses the
// CONNECT.
func TestHostProxyForwardingRefused(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{}, 0)
	c := h.connect()
	st := h.loginState(c, "dev1")
	if _, rep := socksConnect(t, st.Proxy, "localhost", 80); rep == 0 {
		t.Error("CONNECT succeeded through a host that forwards nothing")
	}
}

// A reconnect asks for the port the destination had, and takes another
// when that one is taken.
func TestHostProxyPortKept(t *testing.T) {
	h := newHostHarness(t, sshtest.Options{Forwarding: true}, 0)
	c := h.connect()
	disconnect := func(id uint32) {
		t.Helper()
		if err := c.Call(rpc.HostDisconnect, rpc.HostParams{Host: id}, nil); err != nil {
			t.Fatal(err)
		}
		awaitState(t, c, id, HostGone)
	}
	first := h.loginState(c, "dev1")
	disconnect(first.ID)
	second := h.loginState(c, "dev1")
	if second.Proxy != first.Proxy {
		t.Errorf("reconnected with proxy %q, had %q", second.Proxy, first.Proxy)
	}
	disconnect(second.ID)

	taken, err := net.Listen("tcp", strings.TrimPrefix(first.Proxy, "socks5://"))
	if err != nil {
		t.Fatal(err)
	}
	defer taken.Close()
	third := h.loginState(c, "dev1")
	if third.Proxy == "" || third.Proxy == first.Proxy {
		t.Errorf("port taken, reconnected with proxy %q", third.Proxy)
	}
}

// host.proxy = false runs none.
func TestHostProxyOff(t *testing.T) {
	h := newHostHarnessConfig(t, sshtest.Options{Forwarding: true}, 0, `slime.config{ host = { proxy = false } }`)
	c := h.connect()
	st := h.loginState(c, "dev1")
	if st.Proxy != "" {
		t.Errorf("connected with proxy %q", st.Proxy)
	}
	if hosts := hostList(t, c); len(hosts) != 1 || hosts[0].Proxy != "" {
		t.Errorf("hosts = %+v", hosts)
	}
}
