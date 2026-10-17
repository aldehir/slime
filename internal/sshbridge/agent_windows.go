package sshbridge

import (
	"io"
	"os"
	"strings"
	"time"

	"github.com/Microsoft/go-winio"
)

const defaultAgentPipe = `\\.\pipe\openssh-ssh-agent`

// DialAgent connects to the Windows OpenSSH agent, or to the pipe in
// SSH_AUTH_SOCK if that names one.
func DialAgent() (io.ReadWriteCloser, error) {
	path := defaultAgentPipe
	if sock := os.Getenv("SSH_AUTH_SOCK"); strings.HasPrefix(sock, `\\.\pipe\`) {
		path = sock
	}
	return DialAgentAt(path)
}

// DialAgentAt connects to the agent on the named pipe at path
// (IdentityAgent).
func DialAgentAt(path string) (io.ReadWriteCloser, error) {
	timeout := 2 * time.Second
	return winio.DialPipe(path, &timeout)
}
