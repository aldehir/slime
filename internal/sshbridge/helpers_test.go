package sshbridge

import (
	"crypto"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"

	"github.com/aldehir/slime/internal/remote"
	"github.com/aldehir/slime/internal/sshtest"
)

const (
	password   = "hunter2"
	passphrase = "correct horse"
	otp        = "cccccbhuvtgfhkedvdibjtdldjvjrfcdhihuvdjjgerk"
	timeout    = 5 * time.Second
)

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

func writePub(t *testing.T, pub ssh.PublicKey) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "id_test.pub")
	if err := os.WriteFile(path, ssh.MarshalAuthorizedKey(pub), 0o600); err != nil {
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

// testRemote is the manifest zig build wrote, or an empty one when it
// hasn't.
var testRemote = sync.OnceValue(func() *remote.Manifest {
	m, err := remote.Load(filepath.Join("..", "..", "zig-out", "bin", remote.Dir))
	if err != nil {
		return &remote.Manifest{}
	}
	return m
})

func needPayload(t *testing.T) {
	if _, ok := testRemote().For("linux", "amd64"); !ok {
		t.Skip("no slimed build to install (zig build writes zig-out/bin/remote)")
	}
}

// fakeHost answers the slimed commands as a host with uname would,
// installing builds in memory and echoing on `slimed connect`.
type fakeHost struct {
	uname string
	// installErr, if set, is what installing writes to stderr before
	// failing.
	installErr string

	mu        sync.Mutex
	probes    int
	installed map[string][]byte
	connects  []string
}

func (f *fakeHost) exec(command string, stdin io.Reader, stdout, stderr io.Writer) int {
	f.mu.Lock()
	defer f.mu.Unlock()
	args := shArgs(command)
	switch {
	case strings.Contains(command, "uname -sm"):
		f.probes++
		fmt.Fprintf(stdout, "%s\n/home/alde/.cache/slime\n", f.uname)
		for name := range f.installed {
			fmt.Fprintf(stdout, "%s\n", strings.TrimPrefix(name, "/home/alde/.cache/slime/"))
		}
		return 0
	case strings.Contains(command, "gzip -dc"):
		if f.installErr != "" {
			fmt.Fprintln(stderr, f.installErr)
			return 1
		}
		exe, err := gunzip(stdin)
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		if f.installed == nil {
			f.installed = map[string][]byte{}
		}
		f.installed[args[0]] = exe
		return 0
	case strings.Contains(command, " connect --term "):
		f.connects = append(f.connects, args[1])
		f.mu.Unlock()
		defer f.mu.Lock()
		// An echo for slimed: what comes in goes back out.
		io.Copy(stdout, stdin)
		return 0
	}
	fmt.Fprintf(stderr, "sh: %s: not found\n", command)
	return 127
}

// shArgs are the arguments after the script in a shCommand.
func shArgs(command string) []string {
	var args []string
	for _, q := range strings.Split(command, "' '")[1:] {
		args = append(args, strings.Trim(q, "'"))
	}
	return args
}
