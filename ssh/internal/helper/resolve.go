package helper

import (
	"fmt"
	"io"
	"log"
	"os"
	"os/user"
	"path/filepath"
	"strings"

	"github.com/aldehir/slime/ssh/internal/sshconfig"
)

// DefaultEnv is what the config files are read against: the user's
// home, their login name, and the system's config directory.
func DefaultEnv() (sshconfig.Env, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return sshconfig.Env{}, err
	}
	local, err := localUser()
	if err != nil {
		return sshconfig.Env{}, err
	}
	return sshconfig.Env{Home: home, LocalUser: local, ProgramData: os.Getenv("PROGRAMDATA")}, nil
}

// LoadConfig reads the config: file alone when given ("none" for no
// file), else the user's and then the system's. Its warnings are
// logged.
func LoadConfig(file string, env sshconfig.Env) (*sshconfig.Config, error) {
	sshDir := filepath.Join(env.Home, ".ssh")
	var cfg *sshconfig.Config
	var err error
	switch {
	case strings.EqualFold(file, "none"):
		cfg, err = sshconfig.Load(sshDir)
	case file != "":
		if _, err := os.Stat(file); err != nil {
			return nil, err
		}
		cfg, err = sshconfig.Load(sshDir, file)
	default:
		files := []string{filepath.Join(sshDir, "config")}
		if env.ProgramData != "" {
			files = append(files, filepath.Join(env.ProgramData, "ssh", "ssh_config"))
		}
		cfg, err = sshconfig.Load(sshDir, files...)
	}
	if err != nil {
		return nil, err
	}
	for _, w := range cfg.Warnings {
		log.Print(w)
	}
	return cfg, nil
}

// Resolve works out how to connect to dest from the config, as ssh
// does: dest's user and port, when set, win over the config's.
func Resolve(dest Destination, cfg *sshconfig.Config, env sshconfig.Env) (Options, error) {
	host, err := cfg.Resolve(dest.Host, env, sshconfig.Overrides{User: dest.User, Port: dest.Port})
	if err != nil {
		return Options{}, fmt.Errorf("%s: %w", dest.Host, err)
	}
	if host.ProxyCommand != "" && len(host.ProxyJump) == 0 {
		return Options{}, fmt.Errorf("%s: ProxyCommand isn't supported (%s); ProxyJump is", dest.Host, host.ProxyCommand)
	}

	opts := Options{
		Dest:                  Destination{User: host.User, Host: host.HostName, Port: host.Port},
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
			return Options{}, err
		}
		opts.Jumps = append(opts.Jumps, hop)
	}
	return opts, nil
}

// ResolveDestination resolves a destination as a user typed it
// ([user@]host[:port], ssh://..., or a Host alias) against the user's
// and the system's config.
func ResolveDestination(s string) (Options, error) {
	dest, err := ParseDestination(s)
	if err != nil {
		return Options{}, err
	}
	env, err := DefaultEnv()
	if err != nil {
		return Options{}, err
	}
	cfg, err := LoadConfig("", env)
	if err != nil {
		return Options{}, err
	}
	return Resolve(dest, cfg, env)
}

// resolveJump looks up a ProxyJump hop in the config like any host. Its
// own ProxyJump isn't followed.
func resolveJump(cfg *sshconfig.Config, env sshconfig.Env, spec string) (Hop, error) {
	d, err := ParseDestination(spec)
	if err != nil {
		return Hop{}, fmt.Errorf("ProxyJump: %w", err)
	}
	h, err := cfg.Resolve(d.Host, env, sshconfig.Overrides{User: d.User, Port: d.Port})
	if err != nil {
		return Hop{}, fmt.Errorf("jump host %s: %w", d.Host, err)
	}
	if len(h.ProxyJump) > 0 {
		log.Printf("jump host %s: its own ProxyJump is ignored", d.Host)
	}
	return Hop{
		Dest:           Destination{User: h.User, Host: h.HostName, Port: h.Port},
		Identities:     h.IdentityFiles,
		IdentitiesOnly: h.IdentitiesOnly,
	}, nil
}

func agentDialer(identityAgent string) func() (io.ReadWriteCloser, error) {
	switch identityAgent {
	case "":
		return DialAgent
	case "none":
		return nil
	}
	return func() (io.ReadWriteCloser, error) { return DialAgentAt(identityAgent) }
}

// localUser is the user name without its Windows domain, as ssh uses.
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
