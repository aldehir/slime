package main

import (
	"context"
	"fmt"
	"os"
	"sync"
	"time"

	"golang.org/x/sys/windows"
	"golang.org/x/term"

	"github.com/aldehir/slime/ssh/internal/persist"
	"github.com/aldehir/slime/ssh/internal/vt"
)

// detachKey is Ctrl+].
const detachKey = 0x1d

func consoleSize() (uint16, uint16, error) {
	cols, rows, err := term.GetSize(int(os.Stdout.Fd()))
	return uint16(cols), uint16(rows), err
}

// attach bridges this console to one pane of an attached workspace
// until the pane ends, the workspace is taken away, or Ctrl+] detaches.
// A dev harness, as slime-ssh-drive is: the console redraws from the
// snapshot through the VT formatter, then gets the live output. The
// console answers the program's queries itself, being a real terminal.
func attach(c *persist.Client, ws, pane uint32, p *persist.PaneState) error {
	redraw, err := redrawSequence(p.Snapshot)
	if err != nil {
		return err
	}
	stdin, stdout := windows.Handle(os.Stdin.Fd()), windows.Handle(os.Stdout.Fd())
	restore, err := rawConsole(stdin, stdout)
	if err != nil {
		return err
	}
	// Clear the screen and scrollback, then redraw both, then what came
	// after the snapshot while attaching.
	os.Stdout.WriteString("\x1b[H\x1b[2J\x1b[3J")
	os.Stdout.Write(redraw)
	for _, b := range p.Output {
		os.Stdout.Write(b)
	}

	var (
		mu     sync.Mutex
		ending string
		done   = make(chan struct{})
		once   sync.Once
	)
	finish := func(why string) {
		once.Do(func() {
			mu.Lock()
			ending = why
			mu.Unlock()
			close(done)
		})
	}

	go func() {
		for {
			id, m, err := c.Recv()
			if err != nil {
				finish("lost slimed: " + err.Error())
				return
			}
			switch m := m.(type) {
			case *persist.Output:
				if id == pane {
					os.Stdout.Write(m.Data)
				}
			case *persist.Exit:
				if id == pane {
					finish(fmt.Sprintf("pane %d exited with status %d", pane, m.Status))
					return
				}
			case *persist.Detached:
				if m.WS == ws {
					finish(fmt.Sprintf("detached from workspace %d: %s", ws, m.Reason))
					return
				}
			case *persist.Error:
				finish("slimed: " + m.Message)
				return
			}
		}
	}()

	go func() {
		cols, rows, _ := consoleSize()
		for {
			select {
			case <-done:
				return
			case <-time.After(250 * time.Millisecond):
			}
			c2, r2, err := consoleSize()
			if err != nil || (c2 == cols && r2 == rows) {
				continue
			}
			cols, rows = c2, r2
			c.Send(pane, &persist.Resize{Size: persist.Size{Cols: cols, Rows: rows}})
		}
	}()

	go func() {
		buf := make([]byte, 4096)
		for {
			n, err := os.Stdin.Read(buf)
			if err != nil {
				finish("console input: " + err.Error())
				return
			}
			in := buf[:n]
			for i, b := range in {
				if b == detachKey {
					if i > 0 {
						c.Send(pane, &persist.Input{Data: append([]byte(nil), in[:i]...)})
					}
					c.Send(0, &persist.WorkspaceDetach{WS: ws})
					finish(fmt.Sprintf("detached from workspace %d", ws))
					return
				}
			}
			c.Send(pane, &persist.Input{Data: append([]byte(nil), in...)})
		}
	}()

	<-done
	// Leave the console as a shell expects it: main screen, cursor shown,
	// default attributes, and no mouse or focus reporting left on.
	os.Stdout.WriteString("\x1b[?1049l\x1b[?25h\x1b[0m\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1006l\x1b[?1004l\x1b[?2004l\r\n")
	restore()
	mu.Lock()
	defer mu.Unlock()
	fmt.Fprintf(os.Stderr, "[%s]\n", ending)
	return nil
}

// redrawSequence decodes a snapshot and formats it as the VT that
// redraws it.
func redrawSequence(snapshot []byte) ([]byte, error) {
	ctx := context.Background()
	rt, err := vt.NewRuntime(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer rt.Close(ctx)
	t, err := rt.Decode(snapshot)
	if err != nil {
		return nil, fmt.Errorf("decoding the snapshot: %w", err)
	}
	defer t.Close()
	return t.VT()
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
