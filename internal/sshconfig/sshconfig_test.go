package sshconfig

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

var env = Env{Home: `C:\Users\alde`, LocalUser: "Alde", ProgramData: `C:\ProgramData`}

func parse(t *testing.T, text string) *Config {
	t.Helper()
	c, err := Parse(strings.NewReader(text), t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func resolve(t *testing.T, c *Config, alias string) Host {
	t.Helper()
	h, err := c.Resolve(alias, env, Overrides{})
	if err != nil {
		t.Fatal(err)
	}
	return h
}

func TestSplitLine(t *testing.T) {
	cases := []struct {
		line string
		key  string
		args []string
	}{
		{"", "", nil},
		{"   # comment", "", nil},
		{"HostName example.com", "hostname", []string{"example.com"}},
		{"\tPort=2222", "port", []string{"2222"}},
		{"Port = 2222", "port", []string{"2222"}},
		{"Host a b  !c", "host", []string{"a", "b", "!c"}},
		{`IdentityFile "C:\Users\me\my key"`, "identityfile", []string{`C:\Users\me\my key`}},
		{"ForwardAgent", "forwardagent", nil},
	}
	for _, tc := range cases {
		key, args, err := splitLine(tc.line)
		if err != nil {
			t.Errorf("%q: %v", tc.line, err)
			continue
		}
		if key != tc.key || !reflect.DeepEqual(args, tc.args) {
			t.Errorf("%q = %q %q, want %q %q", tc.line, key, args, tc.key, tc.args)
		}
	}
	if _, _, err := splitLine(`IdentityFile "unterminated`); err == nil {
		t.Error("unterminated quote accepted")
	}
}

func TestMatchHost(t *testing.T) {
	cases := []struct {
		patterns []string
		host     string
		want     bool
	}{
		{[]string{"*"}, "anything", true},
		{[]string{"dev1"}, "DEV1", true},
		{[]string{"*.example.com"}, "dev1.example.com", true},
		{[]string{"*.example.com"}, "example.com", false},
		{[]string{"dev?"}, "dev1", true},
		{[]string{"dev?"}, "dev10", false},
		{[]string{"*", "!bastion"}, "bastion", false},
		{[]string{"*", "!bastion"}, "dev1", true},
		{[]string{"!bastion"}, "dev1", false},
		{[]string{"a", "b"}, "b", true},
	}
	for _, tc := range cases {
		if got := matchHost(tc.patterns, tc.host); got != tc.want {
			t.Errorf("%q vs %q = %v", tc.patterns, tc.host, got)
		}
	}
}

// The shape of a real config: aliases, a renamed host, per-host keys.
func TestResolveRealistic(t *testing.T) {
	c := parse(t, `
Host dev1.example.com
  HostName dev1.example.com
  User alde

Host home
  HostName 192.0.2.10
  IdentityFile ~/.ssh/home-id_ecdsa
  User alde

Host hf-space
  User someone
  IdentityFile ~/.ssh/id_ecdsa-huggingface
  HostName ssh.hf.space
`)
	h := resolve(t, c, "home")
	if h.HostName != "192.0.2.10" || h.User != "alde" || h.Port != 22 {
		t.Errorf("home = %s@%s:%d", h.User, h.HostName, h.Port)
	}
	if want := []string{`C:\Users\alde\.ssh\home-id_ecdsa`}; !reflect.DeepEqual(h.IdentityFiles, want) {
		t.Errorf("identities = %q", h.IdentityFiles)
	}

	h = resolve(t, c, "unlisted.example")
	if h.HostName != "unlisted.example" || h.User != "Alde" {
		t.Errorf("unlisted = %s@%s", h.User, h.HostName)
	}
	if len(h.IdentityFiles) != 3 || !strings.HasSuffix(h.IdentityFiles[2], `.ssh\id_ed25519`) {
		t.Errorf("default identities = %q", h.IdentityFiles)
	}
	if want := []string{`C:\Users\alde\.ssh\known_hosts`, `C:\Users\alde\.ssh\known_hosts2`}; !reflect.DeepEqual(h.UserKnownHostsFiles, want) {
		t.Errorf("known hosts = %q", h.UserKnownHostsFiles)
	}
	if want := []string{`C:\ProgramData\ssh\ssh_known_hosts`}; !reflect.DeepEqual(h.GlobalKnownHostsFiles, want) {
		t.Errorf("global known hosts = %q", h.GlobalKnownHostsFiles)
	}
	if h.StrictHostKeyChecking != "ask" || h.ServerAliveCountMax != 3 {
		t.Errorf("defaults = %q, %d", h.StrictHostKeyChecking, h.ServerAliveCountMax)
	}
}

func TestFirstValueWins(t *testing.T) {
	c := parse(t, `
Host dev1
  User specific
  Port 2222
Host *
  User general
  Port 22
  ServerAliveInterval 30
`)
	h := resolve(t, c, "dev1")
	if h.User != "specific" || h.Port != 2222 || h.ServerAliveInterval != 30*time.Second {
		t.Errorf("got %s:%d alive=%v", h.User, h.Port, h.ServerAliveInterval)
	}
	if h := resolve(t, c, "other"); h.User != "general" || h.Port != 22 {
		t.Errorf("other = %s:%d", h.User, h.Port)
	}
}

func TestIdentityFilesAccumulate(t *testing.T) {
	c := parse(t, `
Host dev1
  IdentityFile ~/.ssh/one
Host *
  IdentityFile ~/.ssh/two
`)
	h := resolve(t, c, "dev1")
	want := []string{`C:\Users\alde\.ssh\one`, `C:\Users\alde\.ssh\two`}
	if !reflect.DeepEqual(h.IdentityFiles, want) {
		t.Errorf("identities = %q", h.IdentityFiles)
	}
}

func TestPrependOverrides(t *testing.T) {
	c := parse(t, "Host *\n  User fromfile\n  StrictHostKeyChecking yes\n")
	if err := c.Prepend("User=fromflag", "StrictHostKeyChecking accept-new"); err != nil {
		t.Fatal(err)
	}
	h := resolve(t, c, "x")
	if h.User != "fromflag" || h.StrictHostKeyChecking != "accept-new" {
		t.Errorf("got %q, %q", h.User, h.StrictHostKeyChecking)
	}
	if err := c.Prepend("Host evil"); err == nil {
		t.Error("Host accepted as an option")
	}
}

func TestDestinationOverrides(t *testing.T) {
	c := parse(t, "Host dev1\n  User fromfile\n  Port 2222\n")
	h, err := c.Resolve("dev1", env, Overrides{User: "root", Port: 22})
	if err != nil {
		t.Fatal(err)
	}
	if h.User != "root" || h.Port != 22 {
		t.Errorf("got %s:%d", h.User, h.Port)
	}
}

func TestTokens(t *testing.T) {
	c := parse(t, `
Host *.lan
  HostName %h.example.com
  User alde
  Port 2200
  IdentityFile ~/.ssh/%r@%h-%p
  UserKnownHostsFile %d/.ssh/hosts-%n "%d/.ssh/with space"
  IdentityAgent \\.\pipe\agent-%u
`)
	h := resolve(t, c, "dev1.lan")
	if h.HostName != "dev1.lan.example.com" {
		t.Errorf("HostName = %q", h.HostName)
	}
	if want := `C:\Users\alde\.ssh\alde@dev1.lan.example.com-2200`; h.IdentityFiles[0] != want {
		t.Errorf("IdentityFile = %q", h.IdentityFiles[0])
	}
	want := []string{`C:\Users\alde\.ssh\hosts-dev1.lan`, `C:\Users\alde\.ssh\with space`}
	if !reflect.DeepEqual(h.UserKnownHostsFiles, want) {
		t.Errorf("UserKnownHostsFile = %q", h.UserKnownHostsFiles)
	}
	if h.IdentityAgent != `\\.\pipe\agent-Alde` {
		t.Errorf("IdentityAgent = %q", h.IdentityAgent)
	}
	if got := expandTokens("100%% %z", nil); got != "100% %z" {
		t.Errorf("expandTokens = %q", got)
	}
}

func TestMatchBlocksIgnored(t *testing.T) {
	c := parse(t, `
Match host dev1 exec "true"
  User frommatch
Host *
  User general
Match all
  Port 2222
`)
	h := resolve(t, c, "dev1")
	if h.User != "general" || h.Port != 2222 {
		t.Errorf("got %s:%d", h.User, h.Port)
	}
	if len(c.Warnings) != 1 {
		t.Errorf("warnings = %q", c.Warnings)
	}
}

func TestInclude(t *testing.T) {
	dir := t.TempDir()
	write := func(name, text string) {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write("10-work", "Host work\n  User worker\n")
	write("20-scoped", "Port 2222\n")
	write("loop", "Include loop\n")
	main := filepath.Join(dir, "config")
	write("config", `
Include 1*
Host dev1
  Include 20-scoped
Host *
  User general
`)
	c, err := Load(dir, main)
	if err != nil {
		t.Fatal(err)
	}
	if h := resolve(t, c, "work"); h.User != "worker" || h.Port != 22 {
		t.Errorf("work = %s:%d", h.User, h.Port)
	}
	// The included line applies only under the block it's included in.
	if h := resolve(t, c, "dev1"); h.Port != 2222 {
		t.Errorf("dev1 port = %d", h.Port)
	}
	if h := resolve(t, c, "other"); h.Port != 22 {
		t.Errorf("other port = %d", h.Port)
	}

	if _, err := Load(dir, filepath.Join(dir, "loop")); err == nil || !strings.Contains(err.Error(), "too deeply") {
		t.Errorf("Include loop: %v", err)
	}
	if _, err := Load(dir, filepath.Join(dir, "missing")); err != nil {
		t.Errorf("missing file: %v", err)
	}
}

func TestProxyJumpAndCommand(t *testing.T) {
	c := parse(t, `
Host inner
  ProxyJump bastion, admin@hop2:2200
Host direct
  ProxyJump none
Host legacy
  ProxyCommand cloudflared access ssh --hostname %h
`)
	if h := resolve(t, c, "inner"); !reflect.DeepEqual(h.ProxyJump, []string{"bastion", "admin@hop2:2200"}) {
		t.Errorf("inner = %q", h.ProxyJump)
	}
	if h := resolve(t, c, "direct"); h.ProxyJump != nil {
		t.Errorf("direct = %q", h.ProxyJump)
	}
	if h := resolve(t, c, "legacy"); !strings.HasPrefix(h.ProxyCommand, "cloudflared") {
		t.Errorf("legacy ProxyCommand = %q", h.ProxyCommand)
	}
}

func TestBadValues(t *testing.T) {
	for _, text := range []string{
		"Port seventy",
		"Port 0",
		"StrictHostKeyChecking maybe",
		"IdentitiesOnly sure",
		"ServerAliveInterval -1",
		"ServerAliveCountMax 0",
	} {
		c := parse(t, text)
		if _, err := c.Resolve("x", env, Overrides{}); err == nil {
			t.Errorf("%q accepted", text)
		}
	}
}
