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
	"slices"
	"strconv"
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

type flags struct {
	port           int
	login          string
	configFile     string
	options        []string
	jump           string
	knownHosts     []string
	identities     []string
	connectTimeout time.Duration
}

func newCommand() *cobra.Command {
	var f flags
	cmd := &cobra.Command{
		Use:   "slime-ssh [flags] <destination>",
		Short: "Serve an SSH connection's channels to slime",
		Long: "Connects to destination ([user@]host[:port] or ssh://[user@]host[:port], where\n" +
			"host may be a Host from ~/.ssh/config) and serves its session channels to\n" +
			"slime over the control protocol on stdin and stdout.",
		Version: fmt.Sprintf("protocol %d", proto.Version),
		Args:    cobra.ExactArgs(1),
		// Errors are logged by main; usage is noise once slime runs us.
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, args []string) error {
			opts, err := resolve(args[0], f, cmd.Flags().Changed)
			if err != nil {
				return err
			}
			return helper.Serve(opts, os.Stdin, os.Stdout)
		},
	}
	fl := cmd.Flags()
	fl.IntVarP(&f.port, "port", "p", 22, "port to connect to")
	fl.StringVarP(&f.login, "login", "l", "", "user to log in as")
	fl.StringVarP(&f.configFile, "config", "F", "", `config file to read instead of ~/.ssh/config and the system's ("none" for none)`)
	fl.StringArrayVarP(&f.options, "option", "o", nil, "a config line, as Key=Value; repeatable, and wins over the config files")
	fl.StringVarP(&f.jump, "jump", "J", "", "jump hosts to go through, comma-separated (ProxyJump)")
	fl.StringArrayVarP(&f.identities, "identity", "i", nil, "private key file to offer; repeatable (IdentityFile)")
	fl.StringSliceVar(&f.knownHosts, "known-hosts", nil, "known_hosts files; new keys go to the first (UserKnownHostsFile)")
	fl.DurationVar(&f.connectTimeout, "connect-timeout", 0, "TCP connect timeout (ConnectTimeout)")
	// stdout is the control pipe, so help and version go to stderr.
	cmd.SetOut(os.Stderr)
	return cmd
}

// resolve works out how to connect from the destination, the flags, and
// the config files, which ssh does in that order of precedence.
func resolve(destArg string, f flags, changed func(string) bool) (helper.Options, error) {
	dest, err := helper.ParseDestination(destArg)
	if err != nil {
		return helper.Options{}, err
	}
	env, err := helper.DefaultEnv()
	if err != nil {
		return helper.Options{}, err
	}
	cfg, err := helper.LoadConfig(f.configFile, env)
	if err != nil {
		return helper.Options{}, err
	}
	// Flags that are config settings go ahead of everything read.
	lines := slices.Clone(f.options)
	for _, id := range f.identities {
		lines = append(lines, "IdentityFile "+quote(id))
	}
	if f.jump != "" {
		lines = append(lines, "ProxyJump "+f.jump)
	}
	if len(f.knownHosts) > 0 {
		var quoted []string
		for _, kh := range f.knownHosts {
			quoted = append(quoted, quote(kh))
		}
		lines = append(lines, "UserKnownHostsFile "+strings.Join(quoted, " "))
	}
	if changed("connect-timeout") {
		lines = append(lines, "ConnectTimeout "+strconv.Itoa(int(f.connectTimeout.Seconds())))
	}
	if err := cfg.Prepend(lines...); err != nil {
		return helper.Options{}, err
	}

	// user@ and :port in the destination win over -l and -p.
	if dest.User == "" && changed("login") {
		dest.User = f.login
	}
	if dest.Port == 0 && changed("port") {
		dest.Port = f.port
	}
	return helper.Resolve(dest, cfg, env)
}

// quote makes a value one config argument.
func quote(s string) string {
	if strings.ContainsAny(s, " \t") {
		return `"` + s + `"`
	}
	return s
}
