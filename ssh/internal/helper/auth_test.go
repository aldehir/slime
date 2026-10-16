package helper

import (
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"

	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
)

const passphrase = "correct horse"

func newKey(t *testing.T) (ed25519.PrivateKey, ssh.PublicKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	sshPub, err := ssh.NewPublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	return priv, sshPub
}

// writeKey writes key as an OpenSSH private key file, encrypted when
// pass is set.
func writeKey(t *testing.T, key crypto.PrivateKey, pass string) string {
	t.Helper()
	var block *pem.Block
	var err error
	if pass == "" {
		block, err = ssh.MarshalPrivateKey(key, "test")
	} else {
		block, err = ssh.MarshalPrivateKeyWithPassphrase(key, "test", []byte(pass))
	}
	if err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(t.TempDir(), "id_test")
	if err := os.WriteFile(path, pem.EncodeToMemory(block), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

// withAgent serves keys from an in-process agent.
func withAgent(t *testing.T, keys ...crypto.PrivateKey) func(*Options) {
	t.Helper()
	keyring := agent.NewKeyring()
	for _, k := range keys {
		if err := keyring.Add(agent.AddedKey{PrivateKey: k}); err != nil {
			t.Fatal(err)
		}
	}
	return func(o *Options) {
		o.DialAgent = func() (io.ReadWriteCloser, error) {
			c, s := net.Pipe()
			go agent.ServeAgent(keyring, s)
			return c, nil
		}
	}
}

func withIdentities(paths ...string) func(*Options) {
	return func(o *Options) { o.Identities = paths }
}

// expectShell waits for the login to finish with no prompts on screen.
func expectShell(t *testing.T, h *harness, tm *term) {
	t.Helper()
	h.expect(0, &proto.Connected{})
	h.expect(1, &proto.Opened{})
	tm.expect(t, "$ ")
	if s := tm.contents(); strings.Contains(s, "password") || strings.Contains(s, "passphrase") {
		t.Errorf("prompted:\n%s", s)
	}
}

func TestAgentKey(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	expectShell(t, h, h.open(1, 80, 24, ""))
}

func TestKeyFile(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	missing := filepath.Join(t.TempDir(), "id_missing")
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()),
		withIdentities(missing, writeKey(t, priv, "")))
	expectShell(t, h, h.open(1, 80, 24, ""))
}

func TestEncryptedKeyFile(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	path := writeKey(t, priv, passphrase)
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(path))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Enter passphrase for key '"+path+"': ")
	tm.typ("wrong\r")
	tm.expect(t, "Bad passphrase, try again for '"+path+"': ")
	tm.typ(passphrase + "\r")
	h.expect(0, &proto.Connected{})
	tm.expect(t, "$ ")
	if strings.Contains(tm.contents(), passphrase) {
		t.Errorf("passphrase was echoed:\n%s", tm.contents())
	}
}

// RSA keys must sign with SHA-2 through the lazy signer.
func TestEncryptedRSAKeyFile(t *testing.T) {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	pub, err := ssh.NewPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	srv := startServer(t, sshtest.Options{AuthorizedKeys: []ssh.PublicKey{pub}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Enter passphrase for key")
	tm.typ(passphrase + "\r")
	h.expect(0, &proto.Connected{})
}

// The host doesn't know the key, so there's nothing to unlock it for.
func TestEncryptedKeyNotAskedWhenUnknown(t *testing.T) {
	priv, _ := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	if strings.Contains(tm.contents(), "passphrase") {
		t.Errorf("asked for a passphrase:\n%s", tm.contents())
	}
}

// An empty passphrase skips the key and moves on, as in ssh.
func TestSkippedPassphraseFallsBack(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{pub}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Enter passphrase for key")
	tm.typ("\r")
	tm.expect(t, "password: ")
	tm.typ(password + "\r")
	h.expect(0, &proto.Connected{})
}

func TestCtrlCAtPassphraseAborts(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password, AuthorizedKeys: []ssh.PublicKey{pub}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Enter passphrase for key")
	tm.typ("\x03")
	h.expectDisconnected("interrupted")
	if strings.Contains(tm.contents(), "password") {
		t.Errorf("went on to the password after Ctrl+C:\n%s", tm.contents())
	}
}

// The target setup: an authorized key, then Duo with a YubiKey OTP.
func TestKeyThenDuo(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{pub}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Duo two-factor login for alde")
	tm.expect(t, "Passcode or option (1-1): ")
	tm.typ(otp + "\r")
	h.expect(0, &proto.Connected{})
	tm.expect(t, "$ ")
	if strings.Contains(tm.contents(), "Password: ") {
		t.Errorf("asked for a password:\n%s", tm.contents())
	}
}

func TestKeyThenDuoWithEncryptedKey(t *testing.T) {
	priv, pub := newKey(t)
	srv := startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{pub}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withIdentities(writeKey(t, priv, passphrase)))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "Enter passphrase for key")
	tm.typ(passphrase + "\r")
	tm.expect(t, "Passcode or option (1-1): ")
	tm.typ(otp + "\r")
	h.expect(0, &proto.Connected{})
}

func TestPermissionDenied(t *testing.T) {
	priv, _ := newKey(t)
	_, other := newKey(t)
	srv := startServer(t, sshtest.Options{KeyThenDuo: true, AuthorizedKeys: []ssh.PublicKey{other}})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), withAgent(t, priv))
	tm := h.open(1, 80, 24, "")
	h.expectDisconnected("alde@127.0.0.1: Permission denied (publickey).")
	tm.expectEOF(t)
	if strings.Contains(tm.contents(), "handshake") {
		t.Errorf("x/crypto's wrapping reached the screen:\n%s", tm.contents())
	}
}

// A key file the agent already holds isn't offered again, so a key the
// host rejected from the agent doesn't then ask for its passphrase.
func TestAgentKeyNotOfferedTwice(t *testing.T) {
	priv, _ := newKey(t)
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()),
		withAgent(t, priv), withIdentities(writeKey(t, priv, passphrase)))
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
	if strings.Contains(tm.contents(), "passphrase") {
		t.Errorf("asked for a passphrase:\n%s", tm.contents())
	}
}

func TestAgentUnavailable(t *testing.T) {
	srv := startServer(t, sshtest.Options{Password: password})
	h := newHarness(t, srv, knownHostsFile(t, srv.KnownHostsLine()), func(o *Options) {
		o.DialAgent = func() (io.ReadWriteCloser, error) { return nil, errors.New("agent stopped") }
	})
	tm := h.open(1, 80, 24, "")
	tm.expect(t, "password: ")
}
