package helper

import (
	"crypto/ed25519"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"

	"github.com/aldehir/slime/ssh/internal/prompt"
)

var errHostKeyRejected = errors.New("host key verification failed")

// hostKeys checks host keys against known_hosts files the way OpenSSH
// does: unknown hosts are asked about (per StrictHostKeyChecking),
// changed keys are refused.
type hostKeys struct {
	// files are the user's, read in order; accepted keys are added to
	// the first. global are only read.
	files  []string
	global []string
	// strict is StrictHostKeyChecking: "ask" or "", "yes",
	// "accept-new", or "no".
	strict string
	hash   bool
	p      *prompt.Prompter
}

// callback returns the check for addr and the host key algorithms to
// ask the server for. When we know keys for the host, we ask for those
// algorithms only, so a server that prefers another type of key doesn't
// trip a false "changed" warning.
func (h *hostKeys) callback(addr string) (ssh.HostKeyCallback, []string, error) {
	var existing []string
	for _, f := range slices.Concat(h.files, h.global) {
		if _, err := os.Stat(f); err == nil {
			existing = append(existing, f)
		}
	}
	check := func(string, net.Addr, ssh.PublicKey) error { return &knownhosts.KeyError{} }
	if len(existing) > 0 {
		var err error
		if check, err = knownhosts.New(existing...); err != nil {
			return nil, nil, err
		}
	}

	var algos []string
	var ke *knownhosts.KeyError
	if errors.As(check(addr, probeAddr, probeKey), &ke) {
		for _, k := range ke.Want {
			algos = appendAlgos(algos, k.Key.Type())
		}
	}

	cb := func(hostname string, remote net.Addr, key ssh.PublicKey) error {
		err := check(hostname, remote, key)
		var ke *knownhosts.KeyError
		switch {
		case err == nil:
			return nil
		case errors.As(err, &ke) && len(ke.Want) == 0:
			return h.unknown(hostname, key)
		case errors.As(err, &ke):
			h.warnChanged(hostname, key, ke.Want[0])
			return errHostKeyRejected
		}
		return err
	}
	return cb, algos, nil
}

func (h *hostKeys) unknown(hostname string, key ssh.PublicKey) error {
	switch h.strict {
	case "yes":
		h.p.Print(fmt.Sprintf("No %s host key is known for %s and you have requested strict checking.\nHost key verification failed.\n",
			keyName(key), displayHost(hostname)))
		return errHostKeyRejected
	case "accept-new", "no":
		h.add(hostname, key)
		return nil
	}

	fp := ssh.FingerprintSHA256(key)
	h.p.Print(fmt.Sprintf("The authenticity of host '%s' can't be established.\n%s key fingerprint is %s.\n",
		displayHost(hostname), keyName(key), fp))
	q := "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
	for {
		ans, err := h.p.ReadLine(q, true)
		if err != nil {
			return err
		}
		switch strings.TrimSpace(ans) {
		case "yes", fp:
			h.add(hostname, key)
			return nil
		case "no":
			h.p.Print("Host key verification failed.\n")
			return errHostKeyRejected
		}
		q = "Please type 'yes', 'no' or the fingerprint: "
	}
}

// add records an accepted key in the user's first known_hosts file.
func (h *hostKeys) add(hostname string, key ssh.PublicKey) {
	if len(h.files) == 0 {
		return
	}
	if err := appendKnownHost(h.files[0], hostname, key, h.hash); err != nil {
		h.p.Print(fmt.Sprintf("Failed to add the host to the list of known hosts (%s): %v\n", h.files[0], err))
		return
	}
	h.p.Print(fmt.Sprintf("Warning: Permanently added '%s' (%s) to the list of known hosts.\n",
		displayHost(hostname), keyName(key)))
}

func (h *hostKeys) warnChanged(hostname string, key ssh.PublicKey, known knownhosts.KnownKey) {
	h.p.Print(fmt.Sprintf(`@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
Someone could be eavesdropping on you right now (man-in-the-middle attack)!
It is also possible that a host key has just been changed.
The fingerprint for the %s key sent by the remote host is
%s.
Please contact your system administrator.
Offending %s key in %s:%d
Host key for %s has changed and you have requested strict checking.
Host key verification failed.
`, keyName(key), ssh.FingerprintSHA256(key), keyName(known.Key), known.Filename, known.Line, displayHost(hostname)))
}

func appendKnownHost(file, hostname string, key ssh.PublicKey, hash bool) error {
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(file, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	host := knownhosts.Normalize(hostname)
	if hash {
		host = knownhosts.HashHostname(host)
	}
	_, err = fmt.Fprintln(f, knownhosts.Line([]string{host}, key))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

// displayHost is how ssh names a host in messages: bare on port 22,
// [host]:port otherwise.
func displayHost(hostname string) string {
	return knownhosts.Normalize(hostname)
}

// keyName is OpenSSH's short name for a key type.
func keyName(key ssh.PublicKey) string {
	switch t := key.Type(); {
	case t == ssh.KeyAlgoED25519:
		return "ED25519"
	case t == ssh.KeyAlgoRSA:
		return "RSA"
	case strings.HasPrefix(t, "ecdsa-"):
		return "ECDSA"
	default:
		return t
	}
}

// appendAlgos adds the host key algorithms that a known key of type t
// can be verified with. RSA keys sign with SHA-2 these days.
func appendAlgos(algos []string, t string) []string {
	var add []string
	if t == ssh.KeyAlgoRSA {
		add = []string{ssh.KeyAlgoRSASHA512, ssh.KeyAlgoRSASHA256, ssh.KeyAlgoRSA}
	} else {
		add = []string{t}
	}
	for _, a := range add {
		if !contains(algos, a) {
			algos = append(algos, a)
		}
	}
	return algos
}

func contains(s []string, v string) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

// probeKey is a key no host has, checked to learn which keys we know
// for a host: the mismatch error lists them.
var probeKey = func() ssh.PublicKey {
	pub, _, err := ed25519.GenerateKey(nil)
	if err != nil {
		panic(err)
	}
	k, err := ssh.NewPublicKey(pub)
	if err != nil {
		panic(err)
	}
	return k
}()

var probeAddr = &net.TCPAddr{IP: net.IPv4zero}
