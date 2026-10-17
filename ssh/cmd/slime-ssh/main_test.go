package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func writeConfig(t *testing.T, text string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
	return path
}

func changedSet(names ...string) func(string) bool {
	return func(name string) bool {
		for _, n := range names {
			if n == name {
				return true
			}
		}
		return false
	}
}

const testConfig = `
Host home
  HostName 192.0.2.10
  User alde
  IdentityFile ~/.ssh/home-id_ecdsa
  ServerAliveInterval 15

Host inner
  HostName 10.0.0.5
  ProxyJump bastion,root@hop2:2200

Host bastion
  HostName bastion.example.com
  User jumper
  IdentityFile ~/.ssh/bastion

Host agentless
  IdentityAgent none

Host legacy
  ProxyCommand nc %h %p
`

func TestResolveAlias(t *testing.T) {
	cfg := writeConfig(t, testConfig)
	opts, err := resolve("ssh://home", flags{configFile: cfg}, changedSet())
	if err != nil {
		t.Fatal(err)
	}
	if d := opts.Dest; d.User != "alde" || d.Host != "192.0.2.10" || d.Port != 22 {
		t.Errorf("dest = %+v", d)
	}
	if len(opts.Identities) != 1 || !strings.HasSuffix(opts.Identities[0], filepath.Join(".ssh", "home-id_ecdsa")) {
		t.Errorf("identities = %q", opts.Identities)
	}
	if opts.KeepaliveInterval != 15*time.Second || opts.KeepaliveCountMax != 3 {
		t.Errorf("keepalive = %v x%d", opts.KeepaliveInterval, opts.KeepaliveCountMax)
	}
	if opts.DialAgent == nil {
		t.Error("no agent")
	}
}

// The destination beats -l and -p, which beat the config; -o beats the
// config too.
func TestResolvePrecedence(t *testing.T) {
	cfg := writeConfig(t, testConfig)
	opts, err := resolve("root@parents:2222", flags{configFile: cfg, login: "flag", port: 3333}, changedSet("login", "port"))
	if err != nil {
		t.Fatal(err)
	}
	if opts.Dest.User != "root" || opts.Dest.Port != 2222 {
		t.Errorf("dest = %+v", opts.Dest)
	}

	opts, err = resolve("home", flags{
		configFile: cfg,
		login:      "flag",
		port:       3333,
		options:    []string{"ServerAliveInterval=0", "StrictHostKeyChecking accept-new"},
	}, changedSet("login", "port"))
	if err != nil {
		t.Fatal(err)
	}
	if opts.Dest.User != "flag" || opts.Dest.Port != 3333 {
		t.Errorf("dest = %+v", opts.Dest)
	}
	if opts.KeepaliveInterval != 0 || opts.StrictHostKeyChecking != "accept-new" {
		t.Errorf("-o ignored: %v, %q", opts.KeepaliveInterval, opts.StrictHostKeyChecking)
	}
}

func TestResolveProxyJump(t *testing.T) {
	cfg := writeConfig(t, testConfig)
	opts, err := resolve("inner", flags{configFile: cfg}, changedSet())
	if err != nil {
		t.Fatal(err)
	}
	if len(opts.Jumps) != 2 {
		t.Fatalf("jumps = %+v", opts.Jumps)
	}
	if d := opts.Jumps[0].Dest; d.User != "jumper" || d.Host != "bastion.example.com" || d.Port != 22 {
		t.Errorf("first hop = %+v", d)
	}
	if !strings.HasSuffix(opts.Jumps[0].Identities[0], "bastion") {
		t.Errorf("first hop identities = %q", opts.Jumps[0].Identities)
	}
	if d := opts.Jumps[1].Dest; d.User != "root" || d.Host != "hop2" || d.Port != 2200 {
		t.Errorf("second hop = %+v", d)
	}
	if opts.Dest.Host != "10.0.0.5" {
		t.Errorf("dest = %+v", opts.Dest)
	}

	// -J replaces the config's.
	opts, err = resolve("inner", flags{configFile: cfg, jump: "other"}, changedSet())
	if err != nil {
		t.Fatal(err)
	}
	if len(opts.Jumps) != 1 || opts.Jumps[0].Dest.Host != "other" {
		t.Errorf("-J jumps = %+v", opts.Jumps)
	}
}

func TestResolveAgentNone(t *testing.T) {
	cfg := writeConfig(t, testConfig)
	opts, err := resolve("agentless", flags{configFile: cfg}, changedSet())
	if err != nil {
		t.Fatal(err)
	}
	if opts.DialAgent != nil {
		t.Error("IdentityAgent none still dials an agent")
	}
}

func TestResolveRefusesProxyCommand(t *testing.T) {
	cfg := writeConfig(t, testConfig)
	if _, err := resolve("legacy", flags{configFile: cfg}, changedSet()); err == nil || !strings.Contains(err.Error(), "ProxyCommand") {
		t.Errorf("err = %v", err)
	}
}

func TestResolveFlagsAsConfig(t *testing.T) {
	opts, err := resolve("host", flags{
		configFile:     "none",
		identities:     []string{`C:\keys\my key`},
		knownHosts:     []string{`C:\kh\a`, `C:\kh\b c`},
		connectTimeout: 7 * time.Second,
	}, changedSet("connect-timeout"))
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{`C:\keys\my key`}; !reflect.DeepEqual(opts.Identities, want) {
		t.Errorf("identities = %q", opts.Identities)
	}
	if want := []string{`C:\kh\a`, `C:\kh\b c`}; !reflect.DeepEqual(opts.KnownHosts, want) {
		t.Errorf("known hosts = %q", opts.KnownHosts)
	}
	if opts.ConnectTimeout != 7*time.Second {
		t.Errorf("timeout = %v", opts.ConnectTimeout)
	}
}
