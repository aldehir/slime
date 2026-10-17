// Package terminfo holds Ghostty's terminfo entry, for installing on
// hosts that don't have it.
//
// xterm-ghostty.terminfo is generated from ghostty/src/terminfo by
// `zig build terminfo`; `zig build test` checks it's current.
package terminfo

import _ "embed"

// Name is the entry's primary name, the TERM it's for.
const Name = "xterm-ghostty"

// Fallback is the TERM to use where the entry can't be installed.
const Fallback = "xterm-256color"

// Source is the entry as terminfo source, for `tic -x -`.
//
//go:embed xterm-ghostty.terminfo
var Source string
