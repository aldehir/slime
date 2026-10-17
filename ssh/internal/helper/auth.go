package helper

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"slices"
	"strings"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"

	"github.com/aldehir/slime/ssh/internal/prompt"
)

// errSkipKey is a passphrase prompt left empty: skip the key, as ssh
// does.
var errSkipKey = errors.New("key skipped")

// deniedError is running out of login methods, worded like ssh.
type deniedError struct {
	user, host string
	allowed    []string
}

func (e *deniedError) Error() string {
	return fmt.Sprintf("%s@%s: Permission denied (%s).", e.user, e.host, strings.Join(e.allowed, ","))
}

// authenticator offers login methods in ssh's order, skipping any the
// server doesn't allow: the identity files' keys (signed by the agent
// when it holds them), then the agent's other keys, then
// keyboard-interactive, then password.
//
// x/crypto runs its own loop with this as the AuthCallback, which lets
// one method name ("publickey") come up more than once.
type authenticator struct {
	p    *prompt.Prompter
	dest Destination

	methods []ssh.AuthMethod
	names   []string
	tried   []bool
	// abort is set when the user gives up at a prompt (Ctrl+C, or the
	// input closing). x/crypto moves on to the next method after an
	// error, so we stop it at the next callback.
	abort error
}

// identitiesOnly leaves out agent keys that aren't among keys.
func newAuthenticator(p *prompt.Prompter, dest Destination, agentSigners []ssh.Signer, keys []*keyFile, identitiesOnly bool) *authenticator {
	a := &authenticator{p: p, dest: dest}

	// Keys that need no prompt go together; each locked key is its own
	// method, since a skipped passphrase fails the method it's in.
	var plain []ssh.Signer
	var locked []*keyFile
	used := make([]bool, len(agentSigners))
	for _, k := range keys {
		if i := slices.IndexFunc(agentSigners, func(s ssh.Signer) bool { return sameKey(s.PublicKey(), k.pub) }); i >= 0 {
			if !used[i] {
				plain = append(plain, agentSigners[i])
				used[i] = true
			}
			continue
		}
		switch {
		case k.signer != nil:
			plain = append(plain, k.signer)
		case !k.pubOnly:
			locked = append(locked, k)
		}
	}
	if len(plain) > 0 {
		a.add("publickey", ssh.PublicKeys(plain...))
	}
	for _, k := range locked {
		k.readLine = a.readLine
		a.add("publickey", ssh.PublicKeys(k))
	}
	if !identitiesOnly {
		var rest []ssh.Signer
		for i, s := range agentSigners {
			if !used[i] {
				rest = append(rest, s)
			}
		}
		if len(rest) > 0 {
			a.add("publickey", ssh.PublicKeys(rest...))
		}
	}
	a.add("keyboard-interactive", ssh.RetryableAuthMethod(ssh.KeyboardInteractive(a.interactive), 3))
	a.add("password", ssh.RetryableAuthMethod(ssh.PasswordCallback(a.password), 3))
	return a
}

func (a *authenticator) add(name string, m ssh.AuthMethod) {
	a.methods = append(a.methods, m)
	a.names = append(a.names, name)
	a.tried = append(a.tried, false)
}

func (a *authenticator) callback(ctx *ssh.ClientAuthContext) (ssh.AuthMethod, error) {
	if a.abort != nil {
		return nil, a.abort
	}
	for i, m := range a.methods {
		if !a.tried[i] && slices.Contains(ctx.AllowedMethods, a.names[i]) {
			a.tried[i] = true
			return m, nil
		}
	}
	return nil, &deniedError{user: a.dest.User, host: a.dest.Host, allowed: ctx.AllowedMethods}
}

// readLine prompts, noting when the user gives up.
func (a *authenticator) readLine(q string, echo bool) (string, error) {
	s, err := a.p.ReadLine(q, echo)
	if errors.Is(err, prompt.ErrInterrupted) || errors.Is(err, io.EOF) {
		a.abort = err
	}
	return s, err
}

func (a *authenticator) interactive(name, instruction string, questions []string, echos []bool) ([]string, error) {
	for _, text := range []string{name, instruction} {
		if text != "" {
			if !strings.HasSuffix(text, "\n") {
				text += "\n"
			}
			a.p.Print(text)
		}
	}
	answers := make([]string, len(questions))
	for i, q := range questions {
		ans, err := a.readLine(q, echos[i])
		if err != nil {
			return nil, err
		}
		answers[i] = ans
	}
	return answers, nil
}

func (a *authenticator) password() (string, error) {
	return a.readLine(fmt.Sprintf("%s@%s's password: ", a.dest.User, a.dest.Host), false)
}

// keyFile is an identity file. An unencrypted one has signer set when
// loaded. An encrypted one is offered by its public key and unlocked
// only when the server accepts it, so there's no passphrase prompt for
// keys the host doesn't know. A public key file only picks a key from
// the agent, as ssh allows.
type keyFile struct {
	path     string
	pub      ssh.PublicKey
	signer   ssh.Signer
	pubOnly  bool
	readLine func(q string, echo bool) (string, error)
}

// loadKeyFile reads path. A missing file is (nil, nil): the defaults
// usually don't all exist.
func loadKeyFile(path string) (*keyFile, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	signer, err := ssh.ParsePrivateKey(data)
	if err == nil {
		return &keyFile{path: path, pub: signer.PublicKey(), signer: signer}, nil
	}
	var missing *ssh.PassphraseMissingError
	if !errors.As(err, &missing) {
		if pub, _, _, _, perr := ssh.ParseAuthorizedKey(data); perr == nil {
			return &keyFile{path: path, pub: pub, pubOnly: true}, nil
		}
		return nil, err
	}
	pub := missing.PublicKey
	if pub == nil {
		// Older PEM formats encrypt the public key too; ssh reads it
		// from the .pub file.
		pubData, err := os.ReadFile(path + ".pub")
		if err != nil {
			return nil, fmt.Errorf("encrypted key without a readable %s.pub: %w", path, err)
		}
		if pub, _, _, _, err = ssh.ParseAuthorizedKey(pubData); err != nil {
			return nil, fmt.Errorf("%s.pub: %w", path, err)
		}
	}
	return &keyFile{path: path, pub: pub}, nil
}

func (k *keyFile) PublicKey() ssh.PublicKey { return k.pub }

func (k *keyFile) Sign(rand io.Reader, data []byte) (*ssh.Signature, error) {
	return k.SignWithAlgorithm(rand, data, "")
}

// SignWithAlgorithm makes keyFile an AlgorithmSigner, so RSA keys can
// sign with SHA-2 as servers require now.
func (k *keyFile) SignWithAlgorithm(rand io.Reader, data []byte, algo string) (*ssh.Signature, error) {
	if k.signer == nil {
		if err := k.unlock(); err != nil {
			return nil, err
		}
	}
	if as, ok := k.signer.(ssh.AlgorithmSigner); ok && algo != "" {
		return as.SignWithAlgorithm(rand, data, algo)
	}
	return k.signer.Sign(rand, data)
}

// unlock asks for the passphrase, three tries as ssh gives.
func (k *keyFile) unlock() error {
	data, err := os.ReadFile(k.path)
	if err != nil {
		return err
	}
	q := fmt.Sprintf("Enter passphrase for key '%s': ", k.path)
	for range 3 {
		pass, err := k.readLine(q, false)
		if err != nil {
			return err
		}
		if pass == "" {
			return errSkipKey
		}
		signer, err := ssh.ParsePrivateKeyWithPassphrase(data, []byte(pass))
		if err == nil {
			k.signer = signer
			return nil
		}
		q = fmt.Sprintf("Bad passphrase, try again for '%s': ", k.path)
	}
	return fmt.Errorf("%s: bad passphrase", k.path)
}

// loadKeys reads the identity files that exist.
func loadKeys(paths []string) []*keyFile {
	var keys []*keyFile
	for _, path := range paths {
		k, err := loadKeyFile(path)
		if err != nil {
			log.Printf("identity %s: %v", path, err)
			continue
		}
		if k != nil {
			keys = append(keys, k)
		}
	}
	return keys
}

func sameKey(a, b ssh.PublicKey) bool {
	return bytes.Equal(a.Marshal(), b.Marshal())
}

// agentSigners lists the agent's keys. The connection stays open for
// signing until close.
func agentSigners(dial func() (io.ReadWriteCloser, error)) (signers []ssh.Signer, close func()) {
	close = func() {}
	if dial == nil {
		return nil, close
	}
	conn, err := dial()
	if err != nil {
		log.Printf("agent: %v", err)
		return nil, close
	}
	signers, err = agent.NewClient(conn).Signers()
	if err != nil {
		log.Printf("agent: %v", err)
		conn.Close()
		return nil, close
	}
	return signers, func() { conn.Close() }
}
