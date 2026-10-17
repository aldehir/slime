package main

import (
	"os"

	"golang.org/x/sys/windows"
	"golang.org/x/term"
)

// rawConsole sends keys as VT input with no line editing or echo, and
// interprets VT output, as a terminal would.
func rawConsole() (restore func(), err error) {
	stdin, stdout := windows.Handle(os.Stdin.Fd()), windows.Handle(os.Stdout.Fd())
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
