package sshconfig

import (
	"fmt"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Env is what defaults and %-tokens expand from.
type Env struct {
	Home      string
	LocalUser string
	// ProgramData is where Windows OpenSSH keeps its system files
	// (%PROGRAMDATA%\ssh). Empty leaves out the global known_hosts.
	ProgramData string
}

// Host is the settings for connecting to one host, with ssh's defaults
// filled in and tokens expanded.
type Host struct {
	// Alias is the name given; HostName is what to connect to.
	Alias    string
	HostName string
	User     string
	Port     int

	IdentityFiles  []string
	IdentitiesOnly bool
	// IdentityAgent is "" for the default agent, "none", or a path.
	IdentityAgent string

	UserKnownHostsFiles   []string
	GlobalKnownHostsFiles []string
	// StrictHostKeyChecking is "ask", "yes", "accept-new", or "no".
	StrictHostKeyChecking string
	HashKnownHosts        bool

	ConnectTimeout      time.Duration
	ServerAliveInterval time.Duration
	ServerAliveCountMax int

	// ProxyJump lists the hops, first to last, as given.
	ProxyJump []string
	// ProxyCommand is set but not supported; say so rather than connect
	// around it.
	ProxyCommand string
}

// Overrides are what the destination itself says (user@, :port), which
// win over the config.
type Overrides struct {
	User string
	Port int
}

// Resolve works out the settings for alias.
func (c *Config) Resolve(alias string, env Env, ov Overrides) (Host, error) {
	v := c.Lookup(alias)
	h := Host{
		Alias:                 alias,
		StrictHostKeyChecking: "ask",
		ServerAliveCountMax:   3,
	}

	h.HostName = alias
	if hn := v.Get("HostName"); hn != "" {
		h.HostName = expandTokens(hn, map[byte]string{'h': alias})
	}

	h.User = env.LocalUser
	if u := v.Get("User"); u != "" {
		h.User = u
	}
	if ov.User != "" {
		h.User = ov.User
	}

	h.Port = 22
	if p := v.Get("Port"); p != "" {
		n, err := strconv.Atoi(p)
		if err != nil || n < 1 || n > 65535 {
			return Host{}, fmt.Errorf("bad Port %q", p)
		}
		h.Port = n
	}
	if ov.Port != 0 {
		h.Port = ov.Port
	}

	tokens := map[byte]string{
		'd': env.Home,
		'u': env.LocalUser,
		'h': h.HostName,
		'n': alias,
		'r': h.User,
		'p': strconv.Itoa(h.Port),
	}
	path := func(s string) string {
		return filepath.Clean(expandTilde(expandTokens(s, tokens), env.Home))
	}
	sshDir := filepath.Join(env.Home, ".ssh")

	for _, f := range v.All("IdentityFile") {
		h.IdentityFiles = append(h.IdentityFiles, path(f))
	}
	if len(h.IdentityFiles) == 0 {
		for _, name := range []string{"id_rsa", "id_ecdsa", "id_ed25519"} {
			h.IdentityFiles = append(h.IdentityFiles, filepath.Join(sshDir, name))
		}
	}
	var err error
	if h.IdentitiesOnly, err = yesNo(v, "IdentitiesOnly", false); err != nil {
		return Host{}, err
	}
	switch a := v.Get("IdentityAgent"); {
	case a == "", a == "SSH_AUTH_SOCK":
	case strings.EqualFold(a, "none"):
		h.IdentityAgent = "none"
	default:
		h.IdentityAgent = expandTokens(a, tokens)
		if strings.HasPrefix(a, "~") {
			h.IdentityAgent = path(a)
		}
	}

	for _, f := range v.Args("UserKnownHostsFile") {
		if !strings.EqualFold(f, "none") {
			h.UserKnownHostsFiles = append(h.UserKnownHostsFiles, path(f))
		}
	}
	if v.Args("UserKnownHostsFile") == nil {
		h.UserKnownHostsFiles = []string{filepath.Join(sshDir, "known_hosts"), filepath.Join(sshDir, "known_hosts2")}
	}
	for _, f := range v.Args("GlobalKnownHostsFile") {
		if !strings.EqualFold(f, "none") {
			h.GlobalKnownHostsFiles = append(h.GlobalKnownHostsFiles, path(f))
		}
	}
	if v.Args("GlobalKnownHostsFile") == nil && env.ProgramData != "" {
		h.GlobalKnownHostsFiles = []string{filepath.Join(env.ProgramData, "ssh", "ssh_known_hosts")}
	}
	switch s := strings.ToLower(v.Get("StrictHostKeyChecking")); s {
	case "":
	case "ask", "yes", "accept-new", "no":
		h.StrictHostKeyChecking = s
	case "off":
		h.StrictHostKeyChecking = "no"
	default:
		return Host{}, fmt.Errorf("bad StrictHostKeyChecking %q", s)
	}
	if h.HashKnownHosts, err = yesNo(v, "HashKnownHosts", false); err != nil {
		return Host{}, err
	}

	if h.ConnectTimeout, err = seconds(v, "ConnectTimeout"); err != nil {
		return Host{}, err
	}
	if h.ServerAliveInterval, err = seconds(v, "ServerAliveInterval"); err != nil {
		return Host{}, err
	}
	if s := v.Get("ServerAliveCountMax"); s != "" {
		n, err := strconv.Atoi(s)
		if err != nil || n < 1 {
			return Host{}, fmt.Errorf("bad ServerAliveCountMax %q", s)
		}
		h.ServerAliveCountMax = n
	}

	// Hops may be spaced after their commas, which splits them into
	// arguments.
	if j := strings.Join(v.Args("ProxyJump"), ""); j != "" && !strings.EqualFold(j, "none") {
		for _, hop := range strings.Split(j, ",") {
			if hop = strings.TrimSpace(hop); hop != "" {
				h.ProxyJump = append(h.ProxyJump, hop)
			}
		}
	}
	if pc := strings.Join(v.Args("ProxyCommand"), " "); pc != "" && !strings.EqualFold(pc, "none") {
		h.ProxyCommand = pc
	}
	return h, nil
}

func yesNo(v Values, key string, def bool) (bool, error) {
	switch s := strings.ToLower(v.Get(key)); s {
	case "":
		return def, nil
	case "yes", "true":
		return true, nil
	case "no", "false":
		return false, nil
	default:
		return false, fmt.Errorf("bad %s %q", key, s)
	}
}

func seconds(v Values, key string) (time.Duration, error) {
	s := v.Get(key)
	if s == "" || strings.EqualFold(s, "none") {
		return 0, nil
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("bad %s %q", key, s)
	}
	return time.Duration(n) * time.Second, nil
}

// expandTokens replaces %x tokens from t, and %% with %. Unknown tokens
// are left as they are.
func expandTokens(s string, t map[byte]string) string {
	if !strings.Contains(s, "%") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '%' || i+1 == len(s) {
			b.WriteByte(s[i])
			continue
		}
		i++
		if s[i] == '%' {
			b.WriteByte('%')
		} else if v, ok := t[s[i]]; ok {
			b.WriteString(v)
		} else {
			b.WriteByte('%')
			b.WriteByte(s[i])
		}
	}
	return b.String()
}

func expandTilde(path, home string) string {
	if path == "~" || strings.HasPrefix(path, "~/") || strings.HasPrefix(path, `~\`) {
		return filepath.Join(home, path[1:])
	}
	return path
}
