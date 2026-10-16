// slime-ssh holds one SSH connection for slime and serves its session
// channels as pipes. slime talks to it with the control protocol in
// internal/proto on stdin and stdout; logs go to stderr.
//
// Usage: slime-ssh [flags] <destination>
package main

import (
	"fmt"
	"log"
	"os"
	"os/user"
	"path/filepath"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/aldehir/slime/ssh/internal/helper"
	"github.com/aldehir/slime/ssh/internal/proto"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.SetPrefix("slime-ssh: ")
	if err := newCommand().Execute(); err != nil {
		log.Fatal(err)
	}
}

func newCommand() *cobra.Command {
	var (
		port           int
		login          string
		knownHosts     []string
		identities     []string
		connectTimeout time.Duration
	)
	cmd := &cobra.Command{
		Use:     "slime-ssh [flags] <destination>",
		Short:   "Serve an SSH connection's channels to slime",
		Long:    "Connects to destination ([user@]host[:port] or ssh://[user@]host[:port])\nand serves its session channels to slime over the control protocol on stdin\nand stdout.",
		Version: fmt.Sprintf("protocol %d", proto.Version),
		Args:    cobra.ExactArgs(1),
		// Errors are logged by main; usage is noise once slime runs us.
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, args []string) error {
			dest, err := helper.ParseDestination(args[0])
			if err != nil {
				return err
			}
			// Flags win over the destination, as in ssh.
			if cmd.Flags().Changed("port") {
				dest.Port = port
			}
			if cmd.Flags().Changed("login") {
				dest.User = login
			}
			if dest.Port == 0 {
				dest.Port = 22
			}
			if dest.User == "" {
				if dest.User, err = localUser(); err != nil {
					return err
				}
			}
			home, err := os.UserHomeDir()
			if err != nil {
				return err
			}
			sshDir := filepath.Join(home, ".ssh")
			if len(knownHosts) == 0 {
				knownHosts = []string{filepath.Join(sshDir, "known_hosts")}
			}
			if len(identities) == 0 {
				for _, name := range []string{"id_rsa", "id_ecdsa", "id_ed25519"} {
					identities = append(identities, filepath.Join(sshDir, name))
				}
			}
			return helper.Serve(helper.Options{
				Dest:           dest,
				KnownHosts:     knownHosts,
				ConnectTimeout: connectTimeout,
				Identities:     identities,
				DialAgent:      helper.DialAgent,
			}, os.Stdin, os.Stdout)
		},
	}
	f := cmd.Flags()
	f.IntVarP(&port, "port", "p", 22, "port to connect to")
	f.StringVarP(&login, "login", "l", "", "user to log in as")
	f.StringArrayVarP(&identities, "identity", "i", nil, "private key file to offer after the agent's keys; repeatable (default ~/.ssh/id_rsa, id_ecdsa, id_ed25519)")
	f.StringSliceVar(&knownHosts, "known-hosts", nil, "known_hosts files; new keys go to the first (default ~/.ssh/known_hosts)")
	f.DurationVar(&connectTimeout, "connect-timeout", 0, "TCP connect timeout (default: the system's)")
	// stdout is the control pipe, so help and version go to stderr.
	cmd.SetOut(os.Stderr)
	return cmd
}

// localUser is the Windows user name without its domain, as ssh uses.
func localUser() (string, error) {
	u, err := user.Current()
	if err != nil {
		return "", err
	}
	name := u.Username
	if i := strings.LastIndexByte(name, '\\'); i >= 0 {
		name = name[i+1:]
	}
	return name, nil
}
