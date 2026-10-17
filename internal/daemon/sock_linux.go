package daemon

import (
	"fmt"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// checkPeer refuses a daemon that runs as another user.
func checkPeer(c *net.UnixConn) error {
	raw, err := c.SyscallConn()
	if err != nil {
		return err
	}
	var cred *unix.Ucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
	}); err != nil {
		return err
	}
	if credErr != nil {
		return fmt.Errorf("daemon: the socket's peer: %w", credErr)
	}
	if int(cred.Uid) != os.Getuid() {
		return fmt.Errorf("daemon: the socket's server (pid %d) runs as uid %d, not us", cred.Pid, cred.Uid)
	}
	return nil
}
