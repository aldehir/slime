//go:build !windows

package helper

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
	return net.Dial("unix", sock)
}
