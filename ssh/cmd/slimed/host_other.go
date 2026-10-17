//go:build !windows

package main

import (
	"github.com/spf13/cobra"

	"github.com/aldehir/slime/ssh/internal/persist"
)

// hostCommands: the daemon here is the one on a host, which connects to
// no others.
func hostCommands() []*cobra.Command { return nil }

// hostOptions: nothing to configure; --remote is ignored.
func hostOptions(string) (persist.HostOptions, error) { return persist.HostOptions{}, nil }
