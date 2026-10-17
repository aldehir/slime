//go:build !windows

package main

import "github.com/spf13/cobra"

// hostCommands: the daemon here is the one on a host, which connects to
// no others.
func hostCommands() []*cobra.Command { return nil }
