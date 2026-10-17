package helper

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
)

// Through a jump host: two logins on the first channel, none after.
func TestJumpHost(t *testing.T) {
	jump := startServer(t, sshtest.Options{Password: "jump-pw", Forwarding: true})
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine(), jump.KnownHostsLine()), func(o *Options) {
		o.Jumps = []Hop{{Dest: Destination{User: "alde", Host: "127.0.0.1", Port: jump.Port()}}}
	})
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	tm.typ("jump-pw\r")
	tm.expect(t, "password: ")
	tm.typ(password + "\r")
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})
	tm.expect(t, "$ ")

	tm2 := h.open(2, 80, 24, "")
	h.expect(2, &proto.Opened{})
	tm2.expect(t, "$ ")
	if strings.Contains(tm2.contents(), "password") {
		t.Errorf("second channel prompted:\n%s", tm2.contents())
	}

	// Ending the last channel ends cleanly, though the connection's EOF
	// comes through the jump host.
	h.send(1, &proto.Close{})
	tm2.typ("exit\r")
	h.expect(2, &proto.Exit{Status: 0})
	if err := h.expectServeReturn(); err != nil {
		t.Errorf("Serve = %v", err)
	}
}

func TestJumpHostWithoutForwarding(t *testing.T) {
	jump := startServer(t, sshtest.Options{Password: "jump-pw"})
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine(), jump.KnownHostsLine()), func(o *Options) {
		o.Jumps = []Hop{{Dest: Destination{User: "alde", Host: "127.0.0.1", Port: jump.Port()}}}
	})
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	tm.typ("jump-pw\r")
	h.expectDisconnected("jump host 127.0.0.1 can't reach")
}

func TestJumpHostLoginFails(t *testing.T) {
	jump := startServer(t, sshtest.Options{Password: "jump-pw", Forwarding: true})
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine(), jump.KnownHostsLine()), func(o *Options) {
		o.Jumps = []Hop{{Dest: Destination{User: "alde", Host: "127.0.0.1", Port: jump.Port()}}}
	})
	tm := h.open(1, 80, 24, "")
	for range 3 {
		tm.expect(t, "password: ")
		tm.typ("wrong\r")
	}
	h.expectDisconnected("jump host 127.0.0.1: alde@127.0.0.1: Permission denied")
}

func TestKeepaliveGivesUp(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Unresponsive: true})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), func(o *Options) {
		o.KeepaliveInterval = 50 * time.Millisecond
		o.KeepaliveCountMax = 2
	})
	tm := login(t, h)
	h.expectDisconnected("Timeout, server 127.0.0.1 not responding")
	tm.expectEOF(t)
}

func TestKeepaliveAnswered(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), func(o *Options) {
		o.KeepaliveInterval = 20 * time.Millisecond
		o.KeepaliveCountMax = 1
	})
	tm := login(t, h)
	time.Sleep(300 * time.Millisecond)
	tm.typ("size\r")
	tm.expect(t, "size=100x30")
	select {
	case m := <-h.msgs:
		t.Errorf("unexpected %#v", m.m)
	default:
	}
}

func TestStrictHostKeyCheckingYes(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t), func(o *Options) { o.StrictHostKeyChecking = "yes" })
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "No ED25519 host key is known for")
	h.expectDisconnected("host key verification failed")
}

func TestStrictHostKeyCheckingAcceptNew(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	h := newHarness(t, srv, kh, func(o *Options) { o.StrictHostKeyChecking = "accept-new" })
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Permanently added")
	tm.expect(t, "password: ")
	if strings.Contains(tm.contents(), "Are you sure") {
		t.Errorf("asked:\n%s", tm.contents())
	}
	if data, _ := os.ReadFile(kh); strings.TrimSpace(string(data)) != srv.KnownHostsLine() {
		t.Errorf("known_hosts = %q", data)
	}
}

// accept-new still refuses a changed key.
func TestAcceptNewRefusesChangedKey(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	other := startServer(t, sshtest.Options{})
	stale := strings.Replace(other.KnownHostsLine(), other.Addr[strings.LastIndex(other.Addr, ":"):], srv.Addr[strings.LastIndex(srv.Addr, ":"):], 1)
	h := newHarness(t, srv, knownHostsFile(t, stale), func(o *Options) { o.StrictHostKeyChecking = "accept-new" })
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "REMOTE HOST IDENTIFICATION HAS CHANGED")
	h.expectDisconnected("host key verification failed")
}

func TestHashKnownHosts(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	opts := func(o *Options) {
		o.StrictHostKeyChecking = "accept-new"
		o.HashKnownHosts = true
	}
	h := newHarness(t, srv, kh, opts)
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	data, _ := os.ReadFile(kh)
	if !strings.HasPrefix(string(data), "|1|") || strings.Contains(string(data), "127.0.0.1") {
		t.Fatalf("known_hosts not hashed: %q", data)
	}
	h.send(1, &proto.Close{})
	h.expectServeReturn()

	// The hashed entry is recognized next time.
	h2 := newHarness(t, srv, kh, opts)
	tm2 := h2.open(1, 80, 24, "")
	tm2.expect(t, "password: ")
	if strings.Contains(tm2.contents(), "Permanently added") {
		t.Errorf("added again:\n%s", tm2.contents())
	}
}

func TestGlobalKnownHosts(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	global := knownHostsFile(t, srv.KnownHostsLine())
	before, _ := os.ReadFile(global)
	user := filepath.Join(t.TempDir(), "known_hosts")
	h := newHarness(t, srv, user, func(o *Options) { o.GlobalKnownHosts = []string{global} })
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	if strings.Contains(tm.contents(), "authenticity") {
		t.Errorf("asked about a globally known host:\n%s", tm.contents())
	}
	if after, _ := os.ReadFile(global); string(after) != string(before) {
		t.Error("global known_hosts was written")
	}
	if _, err := os.Stat(user); err == nil {
		t.Error("user known_hosts was written")
	}
}

func writePub(t *testing.T, pub ssh.PublicKey) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "id_test.pub")
	if err := os.WriteFile(path, ssh.MarshalAuthorizedKey(pub), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestIdentitiesOnlyLeavesOutOtherAgentKeys(t *testing.T) {
	agentKey, agentPub := newKey(t)
	_, otherPub := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{agentPub}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()),
		withAgent(t, agentKey), withIdentities(writePub(t, otherPub)),
		func(o *Options) { o.IdentitiesOnly = true })
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
}

// An IdentityFile naming a public key picks that key from the agent.
func TestPublicKeyIdentityUsesAgent(t *testing.T) {
	k1, _ := newKey(t)
	k2, pub2 := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{pub2}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()),
		withAgent(t, k1, k2), withIdentities(writePub(t, pub2)),
		func(o *Options) { o.IdentitiesOnly = true })
	expectShell(t, h, h.open(1, 80, 24, ""))
}
