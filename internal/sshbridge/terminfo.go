package sshbridge

import (
	"io"
	"log"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/aldehir/slime/internal/terminfo"
)

// terminfoScript leaves a host that knows xterm-ghostty alone, and
// otherwise compiles the entry it's given into ~/.terminfo. It runs
// under sh because the login shell may not be POSIX (fish, csh).
const terminfoScript = `sh -c 'infocmp xterm-ghostty >/dev/null 2>&1 && exit 0; command -v tic >/dev/null 2>&1 || exit 1; tic -x - >/dev/null 2>&1'`

// terminfoTimeout bounds the check: a host that takes longer gets the
// fallback rather than holding up its first shell.
const terminfoTimeout = 10 * time.Second

// installTerminfo makes sure the host has xterm-ghostty, as Ghostty's
// ssh-terminfo does, reporting whether it does now. It doesn't when
// there's no tic, no POSIX sh (a Windows host), or no answer in time.
func installTerminfo(client *ssh.Client) bool {
	sess, err := client.NewSession()
	if err != nil {
		log.Printf("terminfo: %v", err)
		return false
	}
	defer sess.Close()
	stdin, err := sess.StdinPipe()
	if err != nil {
		log.Printf("terminfo: %v", err)
		return false
	}
	if err := sess.Start(terminfoScript); err != nil {
		log.Printf("terminfo: %v", err)
		return false
	}
	// A host that already has the entry exits without reading this.
	go func() {
		io.WriteString(stdin, terminfo.Source)
		stdin.Close()
	}()

	done := make(chan error, 1)
	go func() { done <- sess.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			log.Printf("terminfo: %s unavailable (%v); using %s", terminfo.Name, err, terminfo.Fallback)
			return false
		}
		return true
	case <-time.After(terminfoTimeout):
		log.Printf("terminfo: no answer in %v; using %s", terminfoTimeout, terminfo.Fallback)
		return false
	}
}
