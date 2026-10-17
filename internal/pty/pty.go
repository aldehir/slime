// Package pty runs a child process on a pseudoterminal: ConPTY on
// Windows, and the system's pty on Unix.
package pty

import (
	"sort"
	"strings"
)

// Pty is a child process attached to a pseudoterminal.
type Pty interface {
	// Read reads the child's output. It returns io.EOF once the child
	// has exited and its last output has been read.
	Read(p []byte) (int, error)

	// Write sends input to the child.
	Write(p []byte) (int, error)

	// Resize sets the grid, and the pixels it covers where the pty
	// keeps them (zero if unknown), which programs read to size images.
	Resize(cols, rows uint16, width, height uint32) error

	// Wait blocks until the child exits and returns its exit code.
	Wait() (uint32, error)

	// PID is the child's process id.
	PID() uint32

	// Close kills the child, and everything it started, if still
	// running, and frees the pty. Read returns EOF after it.
	Close() error
}

// mergeEnv is environ (KEY=value entries) with extra's variables set,
// replacing any of the same name. Names compare case-insensitively
// when fold is set, as Windows does.
func mergeEnv(environ []string, extra map[string]string, fold bool) []string {
	same := func(a, b string) bool {
		if fold {
			return strings.EqualFold(a, b)
		}
		return a == b
	}
	out := make([]string, 0, len(environ)+len(extra))
	for _, kv := range environ {
		name, _, _ := strings.Cut(kv, "=")
		replaced := false
		for k := range extra {
			if same(k, name) {
				replaced = true
				break
			}
		}
		if !replaced {
			out = append(out, kv)
		}
	}
	names := make([]string, 0, len(extra))
	for k := range extra {
		names = append(names, k)
	}
	sort.Strings(names)
	for _, k := range names {
		out = append(out, k+"="+extra[k])
	}
	return out
}

// Options say what to start.
type Options struct {
	// Command is the command line: CreateProcessW's syntax on Windows,
	// and run by the user's shell on Unix. Empty starts the default
	// shell (a login shell on Unix).
	Command string

	// Dir is the working directory; empty inherits ours on Windows, and
	// is the home directory on Unix.
	Dir string

	// Env is added to our environment for the child, replacing variables
	// of the same name.
	Env map[string]string

	Cols, Rows uint16
	// Width and Height are the grid's pixels, zero if unknown.
	Width, Height uint32
}
