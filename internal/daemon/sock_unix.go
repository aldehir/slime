//go:build unix

package daemon

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"
)

// Address is the current user's daemon socket, /tmp/slimed-<uid>/sock:
// one daemon per user, or per user and SLIMED_INSTANCE when that's set
// (sock-<instance>), so tests can run a daemon beside the one in use.
//
// Not under $XDG_RUNTIME_DIR, which logind removes when the user's last
// session ends: the daemon outlives their sessions. tmux keeps its
// socket in /tmp for the same reason.
func Address() (string, error) {
	name := "sock"
	if inst := os.Getenv("SLIMED_INSTANCE"); inst != "" {
		name += "-" + inst
	}
	return filepath.Join(os.TempDir(), fmt.Sprintf("slimed-%d", os.Getuid()), name), nil
}

// Listen creates the daemon's socket, in a directory only the current
// user can enter. It fails if another daemon serves it: the daemon holds
// a lock beside it for as long as it listens, so a socket left by one
// that died can be replaced.
func Listen(addr string) (net.Listener, error) {
	dir := filepath.Dir(addr)
	if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, err
	}
	if err := checkDir(dir); err != nil {
		return nil, err
	}
	lock, err := os.OpenFile(addr+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, fmt.Errorf("daemon: another slimed serves %s", addr)
		}
		return nil, fmt.Errorf("daemon: locking %s: %w", lock.Name(), err)
	}
	if err := os.Remove(addr); err != nil && !errors.Is(err, os.ErrNotExist) {
		lock.Close()
		return nil, err
	}
	l, err := net.Listen("unix", addr)
	if err != nil {
		lock.Close()
		return nil, err
	}
	// Closing removes the socket; it's ours, as the lock says.
	l.(*net.UnixListener).SetUnlinkOnClose(true)
	return &lockedListener{Listener: l, lock: lock}, nil
}

type lockedListener struct {
	net.Listener
	lock *os.File
}

func (l *lockedListener) Close() error {
	err := l.Listener.Close()
	l.lock.Close()
	return err
}

// Dial connects to a daemon's socket, after checking that its directory
// is the current user's alone, and where the system says, that the
// daemon runs as the current user.
func Dial(ctx context.Context, addr string) (net.Conn, error) {
	if err := checkDir(filepath.Dir(addr)); err != nil {
		return nil, err
	}
	var d net.Dialer
	c, err := d.DialContext(ctx, "unix", addr)
	if err != nil {
		return nil, err
	}
	if err := checkPeer(c.(*net.UnixConn)); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

// checkDir refuses a socket directory that isn't a real directory, owned
// by us, and closed to everyone else: another user could have made it
// first to serve a socket of their own.
func checkDir(dir string) error {
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	switch {
	case !fi.IsDir():
		return fmt.Errorf("daemon: %s isn't a directory", dir)
	case !ok || int(st.Uid) != os.Getuid():
		return fmt.Errorf("daemon: %s belongs to another user", dir)
	case fi.Mode().Perm()&0o077 != 0:
		return fmt.Errorf("daemon: %s is open to other users (%v)", dir, fi.Mode().Perm())
	}
	return nil
}
