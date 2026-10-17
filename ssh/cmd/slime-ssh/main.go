// slime-ssh holds one SSH connection for slime and serves its session
// channels as pipes. slime talks to it with the control protocol in
// internal/proto on stdin and stdout; logs go to stderr.
//
// Usage: slime-ssh [flags] <destination>
package main

import (
	"fmt"
	"io"
	"log"
	"os"
	"os/user"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"

	"github.com/aldehir/slime/ssh/internal/helper"
	"github.com/aldehir/slime/ssh/internal/proto"
	"github.com/aldehir/slime/ssh/internal/sshconfig"
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
	home, err := os.UserHomeDir()
	if err != nil {
		return helper.Options{}, err
	}
	local, err := localUser()
	if err != nil {
		return helper.Options{}, err
	}
	env := sshconfig.Env{Home: home, LocalUser: local, ProgramData: os.Getenv("PROGRAMDATA")}

	cfg, err := loadConfig(f.configFile, env)
	if err != nil {
		return helper.Options{}, err
	}
	for _, w := range cfg.Warnings {
		log.Print(w)
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
	ov := sshconfig.Overrides{User: dest.User, Port: dest.Port}
	if ov.User == "" && changed("login") {
		ov.User = f.login
	}
	if ov.Port == 0 && changed("port") {
		ov.Port = f.port
	}
	host, err := cfg.Resolve(dest.Host, env, ov)
	if err != nil {
		return helper.Options{}, fmt.Errorf("%s: %w", dest.Host, err)
	}
	if host.ProxyCommand != "" && len(host.ProxyJump) == 0 {
		return helper.Options{}, fmt.Errorf("%s: ProxyCommand isn't supported (%s); ProxyJump is", dest.Host, host.ProxyCommand)
	}

	opts := helper.Options{
		Dest:                  helper.Destination{User: host.User, Host: host.HostName, Port: host.Port},
		Identities:            host.IdentityFiles,
		IdentitiesOnly:        host.IdentitiesOnly,
		KnownHosts:            host.UserKnownHostsFiles,
		GlobalKnownHosts:      host.GlobalKnownHostsFiles,
		StrictHostKeyChecking: host.StrictHostKeyChecking,
		HashKnownHosts:        host.HashKnownHosts,
		ConnectTimeout:        host.ConnectTimeout,
		KeepaliveInterval:     host.ServerAliveInterval,
		KeepaliveCountMax:     host.ServerAliveCountMax,
		DialAgent:             agentDialer(host.IdentityAgent),
	}
	for _, spec := range host.ProxyJump {
		hop, err := resolveJump(cfg, env, spec)
		if err != nil {
			return helper.Options{}, err
		}
		opts.Jumps = append(opts.Jumps, hop)
	}
	return opts, nil
}

// resolveJump looks up a ProxyJump hop in the config like any host. Its
// own ProxyJump isn't followed.
func resolveJump(cfg *sshconfig.Config, env sshconfig.Env, spec string) (helper.Hop, error) {
	d, err := helper.ParseDestination(spec)
	if err != nil {
		return helper.Hop{}, fmt.Errorf("ProxyJump: %w", err)
	}
	h, err := cfg.Resolve(d.Host, env, sshconfig.Overrides{User: d.User, Port: d.Port})
	if err != nil {
		return helper.Hop{}, fmt.Errorf("jump host %s: %w", d.Host, err)
	}
	if len(h.ProxyJump) > 0 {
		log.Printf("jump host %s: its own ProxyJump is ignored", d.Host)
	}
	return helper.Hop{
		Dest:           helper.Destination{User: h.User, Host: h.HostName, Port: h.Port},
		Identities:     h.IdentityFiles,
		IdentitiesOnly: h.IdentitiesOnly,
	}, nil
}

// loadConfig reads -F's file, or the user's and then the system's.
func loadConfig(file string, env sshconfig.Env) (*sshconfig.Config, error) {
	sshDir := filepath.Join(env.Home, ".ssh")
	switch {
	case strings.EqualFold(file, "none"):
		return sshconfig.Load(sshDir)
	case file != "":
		if _, err := os.Stat(file); err != nil {
			return nil, err
		}
		return sshconfig.Load(sshDir, file)
	}
	files := []string{filepath.Join(sshDir, "config")}
	if env.ProgramData != "" {
		files = append(files, filepath.Join(env.ProgramData, "ssh", "ssh_config"))
	}
	return sshconfig.Load(sshDir, files...)
}

func agentDialer(identityAgent string) func() (io.ReadWriteCloser, error) {
	switch identityAgent {
	case "":
		return helper.DialAgent
	case "none":
		return nil
	}
	return func() (io.ReadWriteCloser, error) { return helper.DialAgentAt(identityAgent) }
}

// quote makes a value one config argument.
func quote(s string) string {
	if strings.ContainsAny(s, " \t") {
		return `"` + s + `"`
	}
	return s
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
