//go:build unix

package pty

import (
	"bufio"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/creack/pty"
)

// term is the TERM children get.
var term = "xterm-256color"

// SetTerm sets the TERM children get: xterm-ghostty where the host has
// its terminfo. Call it before the first Start.
func SetTerm(t string) {
	if t != "" {
		term = t
	}
}

// SetConptyDir does nothing: there's no ConPTY here.
func SetConptyDir(string) {}

// lingerAfterExit is how long output is still read once the child has
// exited, for a background job that holds the pty open. The pane ends
// with its child, as with ConPTY.
const lingerAfterExit = 100 * time.Millisecond

// killGrace is how long a child closed with SIGHUP has to exit before
// it gets SIGKILL.
const killGrace = 2 * time.Second

type unixPty struct {
	master *os.File
	cmd    *exec.Cmd

	done     chan struct{} // closed once the child has exited
	exitCode uint32
	exitErr  error

	closeOnce sync.Once
}

// Start runs opts.Command under the user's shell, or the shell itself as
// a login shell, on a new pty. The child leads a session of its own, so
// closing the pty can signal everything it started.
func Start(opts Options) (Pty, error) {
	shell := userShell()
	var cmd *exec.Cmd
	if opts.Command == "" {
		cmd = exec.Command(shell)
		// A leading dash makes it a login shell, as login and sshd do.
		cmd.Args = []string{"-" + filepath.Base(shell)}
	} else {
		cmd = exec.Command(shell, "-c", opts.Command)
	}
	cmd.Dir = opts.Dir
	if cmd.Dir == "" {
		cmd.Dir, _ = os.UserHomeDir()
	}
	cmd.Env = mergeEnv(childEnv(), opts.Env, false)

	size := &pty.Winsize{Cols: opts.Cols, Rows: opts.Rows, X: clamp16(opts.Width), Y: clamp16(opts.Height)}
	master, err := pty.StartWithAttrs(cmd, size, &syscall.SysProcAttr{Setsid: true, Setctty: true})
	if err != nil {
		return nil, err
	}
	p := &unixPty{master: master, cmd: cmd, done: make(chan struct{})}
	go p.wait()
	return p, nil
}

func (p *unixPty) wait() {
	err := p.cmd.Wait()
	var exit *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exit):
		if ws, ok := exit.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			// As shells report it.
			p.exitCode = 128 + uint32(ws.Signal())
		} else {
			p.exitCode = uint32(exit.ExitCode())
		}
	default:
		p.exitErr = err
	}
	close(p.done)
	// Reading ends when the last process holding the pty closes it, which
	// on Linux is an EIO. A job left in the background would hold it
	// open, so stop reading shortly after the child is gone.
	p.master.SetReadDeadline(time.Now().Add(lingerAfterExit))
}

func (p *unixPty) Read(b []byte) (int, error) {
	n, err := p.master.Read(b)
	if err != nil && n == 0 {
		// EIO once the other side is closed, a timeout once lingering
		// is over, and ErrClosed after Close: all the end.
		return 0, io.EOF
	}
	return n, nil
}

func (p *unixPty) Write(b []byte) (int, error) { return p.master.Write(b) }

func (p *unixPty) Resize(cols, rows uint16, width, height uint32) error {
	return pty.Setsize(p.master, &pty.Winsize{Cols: cols, Rows: rows, X: clamp16(width), Y: clamp16(height)})
}

func (p *unixPty) Wait() (uint32, error) {
	<-p.done
	return p.exitCode, p.exitErr
}

func (p *unixPty) PID() uint32 { return uint32(p.cmd.Process.Pid) }

// Close hangs up on the child's session, as closing a terminal does, and
// kills it if it's still there after killGrace.
func (p *unixPty) Close() error {
	p.closeOnce.Do(func() {
		select {
		case <-p.done:
		default:
			pgid := -p.cmd.Process.Pid
			syscall.Kill(pgid, syscall.SIGHUP)
			go func() {
				select {
				case <-p.done:
				case <-time.After(killGrace):
					syscall.Kill(pgid, syscall.SIGKILL)
				}
			}()
		}
		p.master.Close()
	})
	return nil
}

func clamp16(v uint32) uint16 { return uint16(min(v, 0xffff)) }

// childEnv is ours, with the terminal's TERM.
func childEnv() []string {
	env := make([]string, 0, len(os.Environ())+2)
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "TERM=") || strings.HasPrefix(kv, "COLORTERM=") {
			continue
		}
		env = append(env, kv)
	}
	return append(env, "TERM="+term, "COLORTERM=truecolor")
}

// DefaultCommand is what an empty Options.Command runs: the user's
// shell.
func DefaultCommand() string { return userShell() }

// userShell is $SHELL, else the passwd entry's, else /bin/sh.
func userShell() string {
	if s := os.Getenv("SHELL"); s != "" {
		return s
	}
	if s := passwdShell(os.Getuid()); s != "" {
		return s
	}
	return "/bin/sh"
}

func passwdShell(uid int) string {
	f, err := os.Open("/etc/passwd")
	if err != nil {
		return ""
	}
	defer f.Close()
	want := strconv.Itoa(uid)
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		fields := strings.Split(sc.Text(), ":")
		if len(fields) >= 7 && fields[2] == want {
			return fields[6]
		}
	}
	return ""
}
