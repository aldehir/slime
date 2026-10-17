package persist

import (
	"context"
	"fmt"
	"net"

	"github.com/Microsoft/go-winio"
	"golang.org/x/sys/windows"
)

// PipeName is the current user's daemon pipe: one daemon per user.
func PipeName() (string, error) {
	sid, err := userSID()
	if err != nil {
		return "", err
	}
	return `\\.\pipe\slimed-` + sid.String(), nil
}

// Listen creates the daemon's pipe, open to the current user only. It
// fails if the name is taken, by another daemon or anyone else: go-winio
// creates the first instance with FILE_CREATE.
func Listen(name string) (net.Listener, error) {
	sid, err := userSID()
	if err != nil {
		return nil, err
	}
	return winio.ListenPipe(name, &winio.PipeConfig{
		SecurityDescriptor: "D:P(A;;GA;;;" + sid.String() + ")",
		InputBufferSize:    64 << 10,
		OutputBufferSize:   64 << 10,
	})
}

// Dial connects to a daemon's pipe and checks that the process serving
// it runs as the current user, so a pipe another user created first
// under our name isn't trusted.
func Dial(ctx context.Context, name string) (net.Conn, error) {
	c, err := winio.DialPipeContext(ctx, name)
	if err != nil {
		return nil, err
	}
	if err := checkServer(c); err != nil {
		c.Close()
		return nil, err
	}
	return c, nil
}

func checkServer(c net.Conn) error {
	f, ok := c.(interface{ Fd() uintptr })
	if !ok {
		return fmt.Errorf("persist: can't check the pipe's server")
	}
	var pid uint32
	if err := windows.GetNamedPipeServerProcessId(windows.Handle(f.Fd()), &pid); err != nil {
		return fmt.Errorf("persist: GetNamedPipeServerProcessId: %w", err)
	}
	p, err := windows.OpenProcess(windows.PROCESS_QUERY_LIMITED_INFORMATION, false, pid)
	if err != nil {
		return fmt.Errorf("persist: opening the pipe's server (pid %d): %w", pid, err)
	}
	defer windows.CloseHandle(p)
	var token windows.Token
	if err := windows.OpenProcessToken(p, windows.TOKEN_QUERY, &token); err != nil {
		return fmt.Errorf("persist: the pipe's server token: %w", err)
	}
	defer token.Close()
	user, err := token.GetTokenUser()
	if err != nil {
		return err
	}
	ours, err := userSID()
	if err != nil {
		return err
	}
	if !user.User.Sid.Equals(ours) {
		return fmt.Errorf("persist: the pipe's server (pid %d) runs as %s, not us", pid, user.User.Sid)
	}
	return nil
}

func userSID() (*windows.SID, error) {
	user, err := windows.GetCurrentProcessToken().GetTokenUser()
	if err != nil {
		return nil, fmt.Errorf("persist: current user: %w", err)
	}
	return user.User.Sid, nil
}
