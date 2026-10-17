package helper

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"

	"github.com/aldehir/slime/ssh/internal/prompt"
	"github.com/aldehir/slime/ssh/internal/sshtest"
)

// dialer runs Dial with a scripted Asker: each prompt lands in prompts
// for the test to read, and the test's answers go back through answers.
type dialer struct {
	t       *testing.T
	dialog  bool
	prompts chan *Query
	answers chan Answer
	fails   chan error
	infos   chan string
	cancel  context.CancelFunc
	result  chan dialResult

	mu      sync.Mutex
	printed strings.Builder
}

type dialResult struct {
	conn *Conn
	err  error
}

func (d *dialer) Ask(q *Query) (Answer, error) {
	d.prompts <- q
	select {
	case a := <-d.answers:
		return PadAnswers(a, len(q.Questions)), nil
	case err := <-d.fails:
		return Answer{}, err
	}
}

func (d *dialer) Info(text string) { d.infos <- text }

func (d *dialer) Print(text string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.printed.WriteString(text)
}

func (d *dialer) Dialog() bool { return d.dialog }

func (d *dialer) screen() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.printed.String()
}

// startDial dials srv with a terminal-style asker; startDialog with a
// dialog-style one.
func startDial(t *testing.T, srv *sshtest.Server, knownHosts string, mods ...func(*Options)) *dialer {
	t.Helper()
	return startDialer(t, srv, knownHosts, false, mods...)
}

func startDialog(t *testing.T, srv *sshtest.Server, knownHosts string, mods ...func(*Options)) *dialer {
	t.Helper()
	return startDialer(t, srv, knownHosts, true, mods...)
}

func startDialer(t *testing.T, srv *sshtest.Server, knownHosts string, dialog bool, mods ...func(*Options)) *dialer {
	t.Helper()
	d := &dialer{
		t:       t,
		dialog:  dialog,
		prompts: make(chan *Query, 16),
		answers: make(chan Answer, 16),
		fails:   make(chan error, 16),
		infos:   make(chan string, 16),
		result:  make(chan dialResult, 1),
	}
	opts := Options{
		Dest:       Destination{User: "alde", Host: "127.0.0.1", Port: srv.Port()},
		KnownHosts: []string{knownHosts},
		Remote:     testRemote(),
	}
	for _, mod := range mods {
		mod(&opts)
	}
	ctx, cancel := context.WithCancel(context.Background())
	d.cancel = cancel
	go func() {
		conn, err := Dial(ctx, opts, d)
		d.result <- dialResult{conn, err}
	}()
	t.Cleanup(func() {
		cancel()
		select {
		case r := <-d.result:
			if r.conn != nil {
				r.conn.Close()
			}
		case <-time.After(timeout):
		}
	})
	return d
}

// expectPrompt waits for the next prompt, of kind.
func (d *dialer) expectPrompt(kind PromptKind) *Query {
	d.t.Helper()
	select {
	case q := <-d.prompts:
		if q.Kind != kind {
			d.t.Fatalf("got prompt %#v, want kind %d", q.Prompt, kind)
		}
		return q
	case r := <-d.result:
		d.result <- r
		d.t.Fatalf("Dial returned (%v, %v), want a prompt of kind %d", r.conn, r.err, kind)
	case <-time.After(timeout):
		d.t.Fatalf("timed out waiting for a prompt of kind %d", kind)
	}
	return nil
}

func (d *dialer) answer(choice Choice, answers ...string) {
	d.answers <- Answer{Choice: choice, Answers: answers}
}

func (d *dialer) expectInfo(text string) {
	d.t.Helper()
	select {
	case got := <-d.infos:
		if got != text {
			d.t.Fatalf("info %q, want %q", got, text)
		}
	case <-time.After(timeout):
		d.t.Fatalf("timed out waiting for info %q", text)
	}
}

// expectConnected waits for Dial to succeed, with no prompt pending.
func (d *dialer) expectConnected() *Conn {
	d.t.Helper()
	select {
	case r := <-d.result:
		d.result <- r
		if r.err != nil {
			d.t.Fatalf("Dial failed: %v", r.err)
		}
		select {
		case q := <-d.prompts:
			d.t.Fatalf("connected with a prompt pending: %#v", q.Prompt)
		default:
		}
		return r.conn
	case q := <-d.prompts:
		d.t.Fatalf("got prompt %#v, want to connect", q.Prompt)
	case <-time.After(timeout):
		d.t.Fatal("Dial didn't return")
	}
	return nil
}

// expectFailed waits for Dial to fail with a reason mentioning substr.
func (d *dialer) expectFailed(substr string) {
	d.t.Helper()
	select {
	case r := <-d.result:
		d.result <- r
		if r.err == nil {
			d.t.Fatal("Dial succeeded")
		}
		if reason := FailReason(r.err); !strings.Contains(reason, substr) {
			d.t.Fatalf("Dial failed with %q (%v), want %q", reason, r.err, substr)
		}
	case q := <-d.prompts:
		d.t.Fatalf("got prompt %#v, want to fail with %q", q.Prompt, substr)
	case <-time.After(timeout):
		d.t.Fatal("Dial didn't return")
	}
}

// expectWait waits for the connection to end with a reason mentioning
// substr.
func expectWait(t *testing.T, conn *Conn, substr string) {
	t.Helper()
	select {
	case <-conn.Done():
	case <-time.After(timeout):
		t.Fatal("the connection didn't end")
	}
	if reason := LostReason(conn.Wait()); !strings.Contains(reason, substr) {
		t.Errorf("ended with %q, want %q", reason, substr)
	}
}

// dialPassword logs in with the password, terminal style.
func dialPassword(t *testing.T, d *dialer) *Conn {
	t.Helper()
	q := d.expectPrompt(PromptPassword)
	if q.Questions[0].Label != "alde@127.0.0.1's password: " {
		t.Errorf("prompt = %#v", q.Prompt)
	}
	d.answer(ChoiceAccept, password)
	return d.expectConnected()
}

func TestDialPassword(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	q := d.expectPrompt(PromptPassword)
	want := []Question{{Label: "alde@127.0.0.1's password: "}}
	if q.Title != "Sign in to 127.0.0.1" || q.Error != "" || len(q.Questions) != 1 || q.Questions[0] != want[0] {
		t.Errorf("first prompt = %#v", q.Prompt)
	}
	d.answer(ChoiceAccept, "wrong")
	if q := d.expectPrompt(PromptPassword); q.Error == "" {
		t.Errorf("retry has no error: %#v", q.Prompt)
	}
	d.answer(ChoiceAccept, password)
	conn := d.expectConnected()
	if conn.Dest().Host != "127.0.0.1" {
		t.Errorf("dest = %+v", conn.Dest())
	}

	// A session works, and Close ends the connection cleanly.
	sess, err := conn.Client().NewSession()
	if err != nil {
		t.Fatal(err)
	}
	sess.Close()
	conn.Close()
	if err := conn.Wait(); err != nil {
		t.Errorf("Wait after Close = %v", err)
	}
}

func TestDialCancel(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	d.expectPrompt(PromptPassword)
	d.answer(ChoiceCancel)
	d.expectFailed("cancelled")
}

// Cancelling the context while a prompt waits, or while the server
// works on an answer, gives up.
func TestDialContextCancelled(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	d.expectPrompt(PromptPassword)
	d.cancel()
	// Our asker doesn't watch the context; the closed connection ends
	// the handshake instead, so the prompt has to be answered.
	d.fails <- ErrCancelled
	d.expectFailed("cancelled")

	priv, pub := newKey(t)
	srv = startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{pub}, PushDelay: 2 * time.Second})
	d = startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	d.expectPrompt(PromptInteractive)
	d.answer(ChoiceAccept, "1")
	start := time.Now()
	d.cancel()
	d.expectFailed("cancelled")
	if time.Since(start) > time.Second {
		t.Error("waited for the push")
	}
}

// Duo's menu is one question, its status a round with none.
func TestDialDuo(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{pub}})
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	q := d.expectPrompt(PromptInteractive)
	if q.Title != "Sign in to 127.0.0.1" || len(q.Questions) != 1 || !q.Questions[0].Echo ||
		!strings.Contains(q.Questions[0].Label, "Duo two-factor login for alde") ||
		!strings.HasSuffix(q.Questions[0].Label, "Passcode or option (1-1): ") {
		t.Errorf("prompt = %#v", q.Prompt)
	}
	d.answer(ChoiceAccept, otp)
	d.expectInfo("Success. Logging you in...")
	d.expectConnected()
}

func TestDialKeyThenDuoWithEncryptedKey(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{pub}})
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	d.expectPrompt(PromptPassphrase)
	d.answer(ChoiceAccept, passphrase)
	d.expectPrompt(PromptInteractive)
	d.answer(ChoiceAccept, "1")
	d.expectInfo("Success. Logging you in...")
	d.expectConnected()
}

func TestDialPassphrase(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	path := writeKey(t, priv, passphrase)
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(path))
	q := d.expectPrompt(PromptPassphrase)
	if q.Detail != path || q.Title != "Unlock key for 127.0.0.1" || q.Terminal[0] != "Enter passphrase for key '"+path+"': " {
		t.Errorf("prompt = %#v", q)
	}
	d.answer(ChoiceAccept, "wrong")
	q = d.expectPrompt(PromptPassphrase)
	if q.Error == "" || !strings.HasPrefix(q.Terminal[0], "Bad passphrase, try again") {
		t.Errorf("retry = %#v", q)
	}
	d.answer(ChoiceAccept, passphrase)
	d.expectConnected()
}

// An empty or skipped passphrase skips the key and moves on, as in ssh.
func TestDialPassphraseSkip(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{pub}})
	d := startDialog(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	d.expectPrompt(PromptPassphrase)
	d.answer(ChoiceSkip, "")
	d.expectPrompt(PromptPassword)
	d.answer(ChoiceAccept, password)
	d.expectConnected()

	d = startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	d.expectPrompt(PromptPassphrase)
	d.answer(ChoiceAccept, "")
	dialPassword(t, d)
}

// RSA keys must sign with SHA-2 through the lazy signer.
func TestDialEncryptedRSAKey(t *testing.T) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := ssh.NewPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	d.expectPrompt(PromptPassphrase)
	d.answer(ChoiceAccept, passphrase)
	d.expectConnected()
}

// The host doesn't know the key, so there's nothing to unlock it for.
func TestDialEncryptedKeyNotAskedWhenUnknown(t *testing.T) {
	priv, _ := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	dialPassword(t, d)
}

func TestDialCtrlCAtPassphraseAborts(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{pub}})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	d.expectPrompt(PromptPassphrase)
	d.fails <- prompt.ErrInterrupted
	d.expectFailed("interrupted")
}

func TestDialAgentKey(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	d.expectConnected()
}

func TestDialKeyFile(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	missing := filepath.Join(t.TempDir(), "id_missing")
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(missing, writeKey(t, priv, "")))
	d.expectConnected()
}

func TestDialPermissionDenied(t *testing.T) {
	priv, _ := newKey(t)
	_, other := newKey(t)
	srv := startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{other}})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	d.expectFailed("alde@127.0.0.1: Permission denied (publickey).")
}

// A key file the agent already holds isn't offered again, so a key the
// host rejected from the agent doesn't then ask for its passphrase.
func TestDialAgentKeyNotOfferedTwice(t *testing.T) {
	priv, _ := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()),
		withAgent(t, priv), withIdentities(writeKey(t, priv, passphrase)))
	dialPassword(t, d)
}

func TestDialAgentUnavailable(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), func(o *Options) {
		o.DialAgent = func() (io.ReadWriteCloser, error) { return nil, errors.New("agent stopped") }
	})
	dialPassword(t, d)
}

func TestDialIdentitiesOnlyLeavesOutOtherAgentKeys(t *testing.T) {
	agentKey, agentPub := newKey(t)
	_, otherPub := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{agentPub}})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()),
		withAgent(t, agentKey), withIdentities(writePub(t, otherPub)),
		func(o *Options) { o.IdentitiesOnly = true })
	dialPassword(t, d)
}

// An IdentityFile naming a public key picks that key from the agent.
func TestDialPublicKeyIdentityUsesAgent(t *testing.T) {
	k1, _ := newKey(t)
	k2, pub2 := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{pub2}})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()),
		withAgent(t, k1, k2), withIdentities(writePub(t, pub2)),
		func(o *Options) { o.IdentitiesOnly = true })
	d.expectConnected()
}

func TestDialBanner(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Banner: "Authorized use only.\n"})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	dialPassword(t, d)
	if !strings.Contains(d.screen(), "Authorized use only.") {
		t.Errorf("banner not printed: %q", d.screen())
	}
}

// Unknown hosts: a dialog asks with the fingerprint and no questions; a
// terminal asks ssh's yes/no question.
func TestDialUnknownHostTrusted(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	kh := knownHostsFile(t)
	d := startDialog(t, srv, kh, withAgent(t, priv))
	q := d.expectPrompt(PromptUnknownHost)
	fp := ssh.FingerprintSHA256(srv.Signer.PublicKey())
	if !strings.Contains(q.Detail, fp) || len(q.Questions) != 0 || !strings.Contains(q.Text, kh) {
		t.Errorf("prompt = %#v, want fingerprint %s", q.Prompt, fp)
	}
	d.answer(ChoiceAccept)
	d.expectConnected()
	data, err := os.ReadFile(kh)
	if err != nil || strings.TrimSpace(string(data)) != srv.KnownHostsLine() {
		t.Errorf("known_hosts = %q, %v", data, err)
	}
}

func TestDialUnknownHostCancelled(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	d := startDialog(t, srv, kh)
	d.expectPrompt(PromptUnknownHost)
	d.answer(ChoiceCancel)
	d.expectFailed("host key verification failed")
	if _, err := os.Stat(kh); err == nil {
		t.Error("known_hosts was written")
	}
}

func TestDialUnknownHostTerminal(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	d := startDial(t, srv, kh)
	q := d.expectPrompt(0)
	if !strings.Contains(q.Questions[0].Label, "Are you sure you want to continue connecting") {
		t.Errorf("prompt = %#v", q.Prompt)
	}
	if s := d.screen(); !strings.Contains(s, "The authenticity of host '"+knownhosts.Normalize(srv.Addr)+"' can't be established.") ||
		!strings.Contains(s, "ED25519 key fingerprint is "+ssh.FingerprintSHA256(srv.Signer.PublicKey())) {
		t.Errorf("screen:\n%s", s)
	}
	d.answer(ChoiceAccept, "maybe")
	if q := d.expectPrompt(0); q.Questions[0].Label != "Please type 'yes', 'no' or the fingerprint: " {
		t.Errorf("prompt = %#v", q.Prompt)
	}
	d.answer(ChoiceAccept, "yes")
	dialPassword(t, d)
	if !strings.Contains(d.screen(), "Permanently added") {
		t.Errorf("screen:\n%s", d.screen())
	}

	// Saying no refuses.
	d = startDial(t, srv, knownHostsFile(t))
	d.expectPrompt(0)
	d.answer(ChoiceAccept, "no")
	d.expectFailed("host key verification failed")
}

func changedKeyDialer(t *testing.T, dialog bool, mods ...func(*Options)) (*dialer, *sshtest.Server, string) {
	t.Helper()
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	other := startServer(t, sshtest.Options{})
	stale := knownhosts.Line([]string{knownhosts.Normalize(srv.Addr)}, other.Signer.PublicKey())
	kh := knownHostsFile(t, stale)
	return startDialer(t, srv, kh, dialog, append(mods, withAgent(t, priv))...), srv, kh
}

func TestDialChangedHostConnectAnyway(t *testing.T) {
	d, srv, kh := changedKeyDialer(t, true)
	before, _ := os.ReadFile(kh)
	q := d.expectPrompt(PromptChangedHost)
	if !strings.Contains(q.Detail, ssh.FingerprintSHA256(srv.Signer.PublicKey())) || !strings.Contains(q.Detail, kh) {
		t.Errorf("prompt = %#v", q.Prompt)
	}
	d.answer(ChoiceAccept)
	d.expectConnected()
	// Only this once: the warning comes back next time.
	if after, _ := os.ReadFile(kh); string(after) != string(before) {
		t.Errorf("known_hosts changed:\n%s", after)
	}
}

func TestDialChangedHostClosed(t *testing.T) {
	d, _, _ := changedKeyDialer(t, true)
	d.expectPrompt(PromptChangedHost)
	d.answer(ChoiceCancel)
	d.expectFailed("host key verification failed")
}

// A terminal gets ssh's warning and no choice.
func TestDialChangedHostTerminal(t *testing.T) {
	d, _, _ := changedKeyDialer(t, false)
	d.expectFailed("host key verification failed")
	if !strings.Contains(d.screen(), "REMOTE HOST IDENTIFICATION HAS CHANGED") {
		t.Errorf("screen:\n%s", d.screen())
	}
}

func TestDialStrictHostKeyCheckingYes(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t), func(o *Options) { o.StrictHostKeyChecking = "yes" })
	d.expectFailed("host key verification failed")
	if !strings.Contains(d.screen(), "No ED25519 host key is known for") {
		t.Errorf("screen:\n%s", d.screen())
	}
}

func TestDialStrictHostKeyCheckingAcceptNew(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	d := startDialog(t, srv, kh, func(o *Options) { o.StrictHostKeyChecking = "accept-new" })
	dialPassword(t, d)
	if !strings.Contains(d.screen(), "Permanently added") {
		t.Errorf("screen:\n%s", d.screen())
	}
	if data, _ := os.ReadFile(kh); strings.TrimSpace(string(data)) != srv.KnownHostsLine() {
		t.Errorf("known_hosts = %q", data)
	}
}

// accept-new still refuses a changed key.
func TestDialAcceptNewRefusesChangedKey(t *testing.T) {
	d, _, _ := changedKeyDialer(t, true, func(o *Options) { o.StrictHostKeyChecking = "accept-new" })
	d.expectPrompt(PromptChangedHost)
	d.answer(ChoiceCancel)
	d.expectFailed("host key verification failed")
}

func TestDialHashKnownHosts(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	kh := knownHostsFile(t)
	opts := func(o *Options) {
		o.StrictHostKeyChecking = "accept-new"
		o.HashKnownHosts = true
	}
	d := startDial(t, srv, kh, opts)
	dialPassword(t, d).Close()
	data, _ := os.ReadFile(kh)
	if !strings.HasPrefix(string(data), "|1|") || strings.Contains(string(data), "127.0.0.1") {
		t.Fatalf("known_hosts not hashed: %q", data)
	}
	// The hashed entry is recognized next time.
	d = startDial(t, srv, kh, opts)
	dialPassword(t, d)
	if strings.Contains(d.screen(), "Permanently added") {
		t.Errorf("added again:\n%s", d.screen())
	}
}

func TestDialGlobalKnownHosts(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	global := knownHostsFile(t, srv.KnownHostsLine())
	before, _ := os.ReadFile(global)
	user := filepath.Join(t.TempDir(), "known_hosts")
	d := startDialog(t, srv, user, func(o *Options) { o.GlobalKnownHosts = []string{global} })
	dialPassword(t, d)
	if after, _ := os.ReadFile(global); string(after) != string(before) {
		t.Error("global known_hosts was written")
	}
	if _, err := os.Stat(user); err == nil {
		t.Error("user known_hosts was written")
	}
}

// Through a jump host: two logins, then a connection whose end comes
// through the jump host.
func TestDialJumpHost(t *testing.T) {
	jump := startServer(t, sshtest.Options{Password: "jump-pw", Forwarding: true})
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine(), jump.KnownHostsLine()), func(o *Options) {
		o.Jumps = []Hop{{Dest: Destination{User: "alde", Host: "127.0.0.1", Port: jump.Port()}}}
	})
	d.expectPrompt(PromptPassword)
	d.answer(ChoiceAccept, "jump-pw")
	conn := dialPassword(t, d)
	conn.Close()
	if err := conn.Wait(); err != nil {
		t.Errorf("Wait after Close = %v", err)
	}
}

func TestDialJumpHostWithoutForwarding(t *testing.T) {
	jump := startServer(t, sshtest.Options{Password: "jump-pw"})
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine(), jump.KnownHostsLine()), func(o *Options) {
		o.Jumps = []Hop{{Dest: Destination{User: "alde", Host: "127.0.0.1", Port: jump.Port()}}}
	})
	d.expectPrompt(PromptPassword)
	d.answer(ChoiceAccept, "jump-pw")
	d.expectFailed("jump host 127.0.0.1 can't reach")
}

func TestDialJumpHostLoginFails(t *testing.T) {
	jump := startServer(t, sshtest.Options{Password: "jump-pw", Forwarding: true})
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine(), jump.KnownHostsLine()), func(o *Options) {
		o.Jumps = []Hop{{Dest: Destination{User: "alde", Host: "127.0.0.1", Port: jump.Port()}}}
	})
	for range 3 {
		d.expectPrompt(PromptPassword)
		d.answer(ChoiceAccept, "wrong")
	}
	d.expectFailed("jump host 127.0.0.1: alde@127.0.0.1: Permission denied")
}

func TestDialKeepaliveGivesUp(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Unresponsive: true})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), func(o *Options) {
		o.KeepaliveInterval = 50 * time.Millisecond
		o.KeepaliveCountMax = 2
	})
	conn := dialPassword(t, d)
	expectWait(t, conn, "Timeout, server 127.0.0.1 not responding")
}

func TestDialKeepaliveAnswered(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()), func(o *Options) {
		o.KeepaliveInterval = 20 * time.Millisecond
		o.KeepaliveCountMax = 1
	})
	conn := dialPassword(t, d)
	select {
	case <-conn.Done():
		t.Errorf("connection ended: %v", conn.Wait())
	case <-time.After(300 * time.Millisecond):
	}
}

func TestDialConnectionLost(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	conn := dialPassword(t, d)
	srv.Close()
	expectWait(t, conn, "connection closed by remote host")
}

// Term falls back until the host is known to have xterm-ghostty.
func TestDialTerm(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password, Terminfo: sshtest.TerminfoTic})
	d := startDial(t, srv, knownHostsFile(t, srv.KnownHostsLine()))
	conn := dialPassword(t, d)
	if got := conn.Term("xterm-ghostty"); got != "xterm-256color" {
		t.Errorf("Term before installing = %q", got)
	}
	if !conn.InstallTerminfo() || !conn.InstallTerminfo() {
		t.Fatal("terminfo not installed")
	}
	if srv.Compiled() == "" {
		t.Error("nothing was compiled")
	}
	if got := conn.Term("xterm-ghostty"); got != "xterm-ghostty" {
		t.Errorf("Term after installing = %q", got)
	}
	if got := conn.Term(""); got != "xterm-256color" {
		t.Errorf("Term(\"\") = %q", got)
	}
}
