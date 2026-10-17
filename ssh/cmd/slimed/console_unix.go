//go:build unix

package main

import (
	"os"

	"golang.org/x/term"
)

// rawConsole sends keys as typed, with no line editing or echo.
func rawConsole() (restore func(), err error) {
	state, err := term.MakeRaw(int(os.Stdin.Fd()))
	if err != nil {
		return nil, err
	}
	return func() { term.Restore(int(os.Stdin.Fd()), state) }, nil
}
