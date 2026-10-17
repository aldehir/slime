//go:build !windows

package sshbridge

import (
	"errors"
	"io"
	"net"
	"os"
)

// DialAgent connects to the agent in SSH_AUTH_SOCK.
func DialAgent() (io.ReadWriteCloser, error) {
	sock := os.Getenv("SSH_AUTH_SOCK")
	if sock == "" {
		return nil, errors.New("SSH_AUTH_SOCK not set")
	}
	return DialAgentAt(sock)
}

// DialAgentAt connects to the agent on the socket at path.
func DialAgentAt(path string) (io.ReadWriteCloser, error) {
	return net.Dial("unix", path)
}
