package helper

import (
	"os"
	"strings"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"

	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
)

// nextOn returns the helper's next message on id, failing on any other.
func (h *harness) nextOn(id uint32) proto.Message {
	h.t.Helper()
	select {
	case got, ok := <-h.msgs:
		if !ok {
			h.t.Fatalf("control closed, want a message on %d", id)
		}
		if got.id != id {
			h.t.Fatalf("got %#v on %d, want a message on %d", got.m, got.id, id)
		}
		return got.m
	case <-time.After(timeout):
		h.t.Fatalf("timed out waiting for a message on %d", id)
		return nil
	}
}

// expectPrompt waits for a Prompt of kind on channel 1.
func (h *harness) expectPrompt(kind proto.PromptKind) *proto.Prompt {
	h.t.Helper()
	m := h.nextOn(1)
	p, ok := m.(*proto.Prompt)
	if !ok || p.Kind != kind {
		h.t.Fatalf("got %#v, want a Prompt of kind %d", m, kind)
	}
	return p
}

func (h *harness) answer(choice proto.Choice, answers ...string) {
	h.t.Helper()
	h.send(1, &proto.Answer{Choice: choice, Answers: answers})
}

// expectNoPrompts checks that nothing was asked in the terminal.
func expectNoPrompts(t *testing.T, tm *term) {
	t.Helper()
	if s := tm.contents(); strings.Contains(s, "password") || strings.Contains(s, "passphrase") || strings.Contains(s, "Passcode") {
		t.Errorf("prompted in the terminal:\n%s", s)
	}
}

func TestDialogPassword(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	tm := h.open(1, 80, 24, "")

	p := h.expectPrompt(proto.PromptPassword)
	want := []proto.Question{{Label: "alde@127.0.0.1's password: "}}
	if p.Title != "Sign in to 127.0.0.1" || p.Error != "" || len(p.Questions) != 1 || p.Questions[0] != want[0] {
		t.Errorf("first prompt = %#v", p)
	}
	h.answer(proto.ChoiceAccept, "wrong")
	if p := h.expectPrompt(proto.PromptPassword); p.Error == "" {
		t.Errorf("retry has no error: %#v", p)
	}
	h.answer(proto.ChoiceAccept, password)
	expectShell(t, h, tm)
	expectNoPrompts(t, tm)
}

func TestDialogCancel(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	h.open(1, 80, 24, "")
	h.expectPrompt(proto.PromptPassword)
	h.answer(proto.ChoiceCancel)
	h.expectDisconnected("cancelled")
}

// Duo's menu is one question, its status a round with none.
func TestDialogDuo(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{pub}})
	h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	tm := h.open(1, 80, 24, "")

	p := h.expectPrompt(proto.PromptInteractive)
	if p.Title != "Sign in to 127.0.0.1" || len(p.Questions) != 1 || !p.Questions[0].Echo ||
		!strings.Contains(p.Questions[0].Label, "Duo two-factor login for alde") ||
		!strings.HasSuffix(p.Questions[0].Label, "Passcode or option (1-1): ") {
		t.Errorf("prompt = %#v", p)
	}
	h.answer(proto.ChoiceAccept, "1")
	if m := h.nextOn(1); m == nil || m.Type() != proto.TypeInfo || m.(*proto.Info).Text != "Success. Logging you in..." {
		t.Errorf("got %#v, want the status", m)
	}
	expectShell(t, h, tm)
	expectNoPrompts(t, tm)
}

// Cancelling while the server works on an answer (a push waiting for
// approval) gives up on logging in.
func TestDialogCancelWhileWaiting(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{pub}, PushDelay: 2 * time.Second})
	h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	h.open(1, 80, 24, "")
	h.expectPrompt(proto.PromptInteractive)
	h.answer(proto.ChoiceAccept, "1")
	h.answer(proto.ChoiceCancel)
	h.expectDisconnected("cancelled")
}

func TestDialogPassphraseSkip(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{pub}})
	path := writeKey(t, priv, passphrase)
	h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(path))
	tm := h.open(1, 80, 24, "")

	p := h.expectPrompt(proto.PromptPassphrase)
	if p.Detail != path || p.Title != "Unlock key for 127.0.0.1" {
		t.Errorf("prompt = %#v", p)
	}
	h.answer(proto.ChoiceSkip, "")
	h.expectPrompt(proto.PromptPassword)
	h.answer(proto.ChoiceAccept, password)
	expectShell(t, h, tm)
}

func TestDialogPassphrase(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	h := newDialogHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	tm := h.open(1, 80, 24, "")
	h.expectPrompt(proto.PromptPassphrase)
	h.answer(proto.ChoiceAccept, "wrong")
	if p := h.expectPrompt(proto.PromptPassphrase); p.Error == "" {
		t.Errorf("retry has no error: %#v", p)
	}
	h.answer(proto.ChoiceAccept, passphrase)
	expectShell(t, h, tm)
}

func TestDialogUnknownHostTrusted(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	kh := knownHostsFile(t)
	h := newDialogHarness(t, srv, kh, withAgent(t, priv))
	tm := h.open(1, 80, 24, "")

	p := h.expectPrompt(proto.PromptUnknownHost)
	if fp := ssh.FingerprintSHA256(srv.Signer.PublicKey()); !strings.Contains(p.Detail, fp) || len(p.Questions) != 0 {
		t.Errorf("prompt = %#v, want fingerprint %s", p, fp)
	}
	h.answer(proto.ChoiceAccept)
	expectShell(t, h, tm)
	data, err := os.ReadFile(kh)
	if err != nil || !strings.Contains(string(data), knownhosts.Normalize(srv.Addr)) {
		t.Errorf("known_hosts = %q, %v", data, err)
	}
}

func TestDialogUnknownHostCancelled(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	h := newDialogHarness(t, srv, kh)
	h.open(1, 80, 24, "")
	h.expectPrompt(proto.PromptUnknownHost)
	h.answer(proto.ChoiceCancel)
	h.expectDisconnected("host key verification failed")
	if _, err := os.Stat(kh); err == nil {
		t.Error("known_hosts was written")
	}
}

func changedKeyHarness(t *testing.T, mods ...func(*Options)) (*harness, *sshtest.Server, string) {
	t.Helper()
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	other := startServer(t, sshtest.Options{})
	stale := knownhosts.Line([]string{knownhosts.Normalize(srv.Addr)}, other.Signer.PublicKey())
	kh := knownHostsFile(t, stale)
	return newDialogHarness(t, srv, kh, append(mods, withAgent(t, priv))...), srv, kh
}

func TestDialogChangedHostConnectAnyway(t *testing.T) {
	h, srv, kh := changedKeyHarness(t)
	before, _ := os.ReadFile(kh)
	tm := h.open(1, 80, 24, "")

	p := h.expectPrompt(proto.PromptChangedHost)
	if !strings.Contains(p.Detail, ssh.FingerprintSHA256(srv.Signer.PublicKey())) || !strings.Contains(p.Detail, kh) {
		t.Errorf("prompt = %#v", p)
	}
	h.answer(proto.ChoiceAccept)
	expectShell(t, h, tm)
	// Only this once: the warning comes back next time.
	if after, _ := os.ReadFile(kh); string(after) != string(before) {
		t.Errorf("known_hosts changed:\n%s", after)
	}
}

func TestDialogChangedHostClosed(t *testing.T) {
	h, _, _ := changedKeyHarness(t)
	h.open(1, 80, 24, "")
	h.expectPrompt(proto.PromptChangedHost)
	h.answer(proto.ChoiceCancel)
	h.expectDisconnected("host key verification failed")
}
