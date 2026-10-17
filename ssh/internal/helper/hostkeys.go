package helper

import (
	"crypto/ed25519"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"

	"github.com/aldehir/slime/ssh/internal/proto"
)

var errHostKeyRejected = errors.New("host key verification failed")

// hostKeys checks host keys against known_hosts files the way OpenSSH
// does: unknown hosts are asked about (per StrictHostKeyChecking), and
// changed keys are refused, unless slime's dialog asks and the user
// connects anyway.
type hostKeys struct {
	// files are the user's, read in order; accepted keys are added to
	// the first. global are only read.
	files  []string
	global []string
	// strict is StrictHostKeyChecking: "ask" or "", "yes",
	// "accept-new", or "no".
	strict string
	hash   bool
	ui     asker
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
			return h.changed(hostname, key, ke.Want[0])
		}
		return err
	}
	return cb, algos, nil
}

func (h *hostKeys) unknown(hostname string, key ssh.PublicKey) error {
	switch h.strict {
	case "yes":
		h.ui.print(fmt.Sprintf("No %s host key is known for %s and you have requested strict checking.\nHost key verification failed.\n",
			keyName(key), displayHost(hostname)))
		return errHostKeyRejected
	case "accept-new", "no":
		h.add(hostname, key)
		return nil
	}

	fp := ssh.FingerprintSHA256(key)
	if h.ui.dialog() {
		q := &question{Prompt: proto.Prompt{
			Kind:   proto.PromptUnknownHost,
			Title:  "First connection to " + displayHost(hostname),
			Text:   "slime hasn't seen this host's key before. If you can, check the fingerprint against one from the server's admin before trusting it.",
			Detail: keyName(key) + " " + fp,
		}}
		if len(h.files) > 0 {
			q.Text += "\n\nTrusting it adds the key to " + h.files[0] + "."
		}
		ans, err := h.ui.ask(q)
		if err != nil {
			return err
		}
		if ans.Choice != proto.ChoiceAccept {
			return errHostKeyRejected
		}
		h.add(hostname, key)
		return nil
	}
	h.ui.print(fmt.Sprintf("The authenticity of host '%s' can't be established.\n%s key fingerprint is %s.\n",
		displayHost(hostname), keyName(key), fp))
	q := "Are you sure you want to continue connecting (yes/no/[fingerprint])? "
	for {
		ans, err := h.ui.ask(&question{Prompt: proto.Prompt{Questions: []proto.Question{{Label: q, Echo: true}}}})
		if err != nil {
			return err
		}
		switch strings.TrimSpace(ans.Answers[0]) {
		case "yes", fp:
			h.add(hostname, key)
			return nil
		case "no":
			h.ui.print("Host key verification failed.\n")
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
		h.ui.print(fmt.Sprintf("Failed to add the host to the list of known hosts (%s): %v\n", h.files[0], err))
		return
	}
	h.ui.print(fmt.Sprintf("Warning: Permanently added '%s' (%s) to the list of known hosts.\n",
		displayHost(hostname), keyName(key)))
}

// changed handles a key that isn't the one known for the host. slime's
// dialog lets the user connect anyway, this once: known_hosts is left
// alone, so it asks again next time.
func (h *hostKeys) changed(hostname string, key ssh.PublicKey, known knownhosts.KnownKey) error {
	if !h.ui.dialog() {
		h.warnChanged(hostname, key, known)
		return errHostKeyRejected
	}
	q := &question{Prompt: proto.Prompt{
		Kind:  proto.PromptChangedHost,
		Title: displayHost(hostname) + "'s host key has changed",
		Text:  "Someone could be intercepting the connection, or the server may have been reinstalled. Only connect if you know why it changed.",
		Detail: fmt.Sprintf("Expected (%s line %d)\n%s %s\nOffered now\n%s %s",
			known.Filename, known.Line, keyName(known.Key), ssh.FingerprintSHA256(known.Key),
			keyName(key), ssh.FingerprintSHA256(key)),
	}}
	ans, err := h.ui.ask(q)
	if err != nil {
		return err
	}
	if ans.Choice != proto.ChoiceAccept {
		return errHostKeyRejected
	}
	log.Printf("host key for %s changed; connecting anyway", displayHost(hostname))
	return nil
}

func (h *hostKeys) warnChanged(hostname string, key ssh.PublicKey, known knownhosts.KnownKey) {
	h.ui.print(fmt.Sprintf(`@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
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
