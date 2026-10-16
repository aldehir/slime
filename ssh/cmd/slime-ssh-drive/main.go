//go:build windows

// slime-ssh-drive plays slime's part to try slime-ssh by hand: it runs
// the helper, hands it a channel's pipes the way slime will (anonymous
// pipes duplicated into the helper's process), and bridges the console
// to the channel. Ctrl+] then q closes the channel; Ctrl+] twice sends
// a Ctrl+].
//
// Usage: slime-ssh-drive [flags] [helper args...]
package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/spf13/cobra"
	"golang.org/x/sys/windows"
	"golang.org/x/term"

	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshtest"
)

const escapeKey = 0x1d // Ctrl+]

func main() {
	if err := newCommand().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "slime-ssh-drive:", err)
		os.Exit(1)
	}
}

func newCommand() *cobra.Command {
	var (
		helperPath string
		logPath    string
		testServer bool
	)
	cmd := &cobra.Command{
		Use:   "slime-ssh-drive [flags] [helper args...]",
		Short: "Drive slime-ssh from the console, as slime would",
		Long: "Runs slime-ssh with the given arguments and bridges the console to its\n" +
			"first channel. Ctrl+] then q closes the channel.\n\n" +
			"With --test-server, runs an in-process server shaped like pam_duo\n" +
			"(password \"slime\", then a 44-character modhex OTP or 1 for a push).",
		SilenceUsage: true,
		RunE: func(cmd *cobra.Command, args []string) error {
			if helperPath == "" {
				exe, err := os.Executable()
				if err != nil {
					return err
				}
				helperPath = filepath.Join(filepath.Dir(exe), "slime-ssh.exe")
			}
			if logPath == "" {
				logPath = filepath.Join(os.TempDir(), "slime-ssh-drive.log")
			}
			if testServer {
				srv, err := sshtest.Start(sshtest.Options{Password: "slime", Duo: true, PushDelay: 2 * time.Second})
				if err != nil {
					return err
				}
				defer srv.Close()
				dir, err := os.MkdirTemp("", "slime-ssh-drive")
				if err != nil {
					return err
				}
				defer os.RemoveAll(dir)
				args = []string{
					"-p", strconv.Itoa(srv.Port()),
					"--known-hosts", filepath.Join(dir, "known_hosts"),
					"tester@127.0.0.1",
				}
			} else if len(args) == 0 {
				return errors.New("give the helper's arguments, or --test-server")
			}
			return drive(helperPath, logPath, args)
		},
	}
	f := cmd.Flags()
	f.StringVar(&helperPath, "helper", "", "slime-ssh.exe to run (default: next to this program)")
	f.StringVar(&logPath, "log", "", `where the helper's log goes (default: %TEMP%\slime-ssh-drive.log)`)
	f.BoolVar(&testServer, "test-server", false, "connect to an in-process test server")
	// Everything after the first argument is the helper's.
	f.SetInterspersed(false)
	return cmd
}

func drive(helperPath, logPath string, args []string) error {
	logFile, err := os.OpenFile(logPath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()
	fmt.Fprintf(logFile, "--- %s %v\n", helperPath, args)

	cmd := exec.Command(helperPath, args...)
	cmd.Stderr = logFile
	ctlIn, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	ctlOut, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	defer cmd.Wait()
	defer ctlIn.Close()

	proc, err := windows.OpenProcess(windows.PROCESS_DUP_HANDLE, false, uint32(cmd.Process.Pid))
	if err != nil {
		return fmt.Errorf("opening helper process: %w", err)
	}
	defer windows.CloseHandle(proc)

	w := proto.NewWriter(ctlIn)
	r := proto.NewReader(ctlOut)
	if err := w.Send(0, &proto.Hello{Version: proto.Version}); err != nil {
		return err
	}
	f, err := r.Read()
	if err != nil {
		return fmt.Errorf("reading hello: %w (see %s)", err, logPath)
	}
	if m, err := proto.Decode(f); err != nil {
		return err
	} else if reply, ok := m.(*proto.HelloReply); !ok || reply.Version != proto.Version {
		return fmt.Errorf("helper replied %#v, want protocol %d", m, proto.Version)
	}

	stdin, stdout := windows.Handle(os.Stdin.Fd()), windows.Handle(os.Stdout.Fd())
	cols, rows, err := term.GetSize(int(stdout))
	if err != nil {
		return fmt.Errorf("the console's size: %w", err)
	}
	keys, screen, open, err := newChannel(proc)
	if err != nil {
		return err
	}
	open.Cols, open.Rows, open.Term = uint16(cols), uint16(rows), "xterm-256color"
	if err := w.Send(1, open); err != nil {
		return err
	}

	restore, err := rawConsole(stdin, stdout)
	if err != nil {
		return err
	}

	var (
		mu     sync.Mutex
		ending string
	)
	go func() {
		for {
			f, err := r.Read()
			if err != nil {
				return
			}
			m, err := proto.Decode(f)
			if err != nil {
				fmt.Fprintf(logFile, "drive: %v\n", err)
				continue
			}
			fmt.Fprintf(logFile, "drive: channel %d: %#v\n", f.ID, m)
			mu.Lock()
			switch m := m.(type) {
			case *proto.Exit:
				if m.Signal != "" {
					ending = "killed by signal " + m.Signal
				} else {
					ending = fmt.Sprintf("exited with status %d", m.Status)
				}
			case *proto.Error:
				ending = "error: " + m.Message
			case *proto.Disconnected:
				ending = "disconnected: " + m.Reason
			}
			mu.Unlock()
		}
	}()

	go func() {
		lastCols, lastRows := cols, rows
		for range time.Tick(250 * time.Millisecond) {
			c, r, err := term.GetSize(int(stdout))
			if err != nil || (c == lastCols && r == lastRows) {
				continue
			}
			lastCols, lastRows = c, r
			w.Send(1, &proto.Resize{Cols: uint16(c), Rows: uint16(r)})
		}
	}()

	go func() {
		buf := make([]byte, 4096)
		escaped := false
		for {
			n, err := os.Stdin.Read(buf)
			if err != nil {
				return
			}
			out := make([]byte, 0, n)
			for _, b := range buf[:n] {
				switch {
				case escaped && b == 'q':
					w.Send(1, &proto.Close{})
					keys.Close()
					return
				case escaped:
					escaped = false
					if b != escapeKey {
						out = append(out, escapeKey)
					}
					out = append(out, b)
				case b == escapeKey:
					escaped = true
				default:
					out = append(out, b)
				}
			}
			if _, err := keys.Write(out); err != nil {
				return
			}
		}
	}()

	io.Copy(os.Stdout, screen)
	restore()
	keys.Close()
	screen.Close()

	// Let the last control message land.
	time.Sleep(100 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if ending == "" {
		ending = "channel closed"
	}
	fmt.Fprintf(os.Stderr, "\r\n[%s; helper log in %s]\r\n", ending, logPath)
	return nil
}

// newChannel makes a channel's two pipes and moves the helper's ends
// into its process. Closing our copies of those ends is what lets each
// side see EOF when the other closes.
func newChannel(proc windows.Handle) (keys, screen *os.File, open *proto.Open, err error) {
	var inR, inW, outR, outW windows.Handle
	if err := windows.CreatePipe(&inR, &inW, nil, 0); err != nil {
		return nil, nil, nil, err
	}
	if err := windows.CreatePipe(&outR, &outW, nil, 0); err != nil {
		windows.CloseHandle(inR)
		windows.CloseHandle(inW)
		return nil, nil, nil, err
	}
	move := func(h windows.Handle) (uint64, error) {
		var target windows.Handle
		err := windows.DuplicateHandle(windows.CurrentProcess(), h, proc, &target, 0, false,
			windows.DUPLICATE_SAME_ACCESS|windows.DUPLICATE_CLOSE_SOURCE)
		return uint64(target), err
	}
	in, err1 := move(inR)
	out, err2 := move(outW)
	keys, screen = os.NewFile(uintptr(inW), "keys"), os.NewFile(uintptr(outR), "screen")
	if err := errors.Join(err1, err2); err != nil {
		keys.Close()
		screen.Close()
		return nil, nil, nil, fmt.Errorf("duplicating pipe handles: %w", err)
	}
	return keys, screen, &proto.Open{In: in, Out: out}, nil
}

// rawConsole sends keys as VT input with no line editing or echo, and
// interprets VT output, as a terminal would.
func rawConsole(stdin, stdout windows.Handle) (restore func(), err error) {
	state, err := term.MakeRaw(int(stdin))
	if err != nil {
		return nil, err
	}
	var outMode uint32
	if err := windows.GetConsoleMode(stdout, &outMode); err != nil {
		term.Restore(int(stdin), state)
		return nil, err
	}
	windows.SetConsoleMode(stdout, outMode|windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING|windows.DISABLE_NEWLINE_AUTO_RETURN)
	return func() {
		term.Restore(int(stdin), state)
		windows.SetConsoleMode(stdout, outMode)
	}, nil
}
