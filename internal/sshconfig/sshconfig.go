// Package sshconfig reads OpenSSH client configuration, ssh_config(5),
// as far as slime uses it.
//
// Settings come from Host blocks whose patterns match the name given
// on the command line (before HostName replaces it). For each keyword
// the first value found wins, so the most specific blocks go first and
// overrides are prepended; IdentityFile and a few others accumulate
// instead. Match blocks aren't evaluated and never apply. Include
// reads files in place, scoped to the block it appears in.
package sshconfig

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// maxIncludeDepth stops Include cycles, as ssh does.
const maxIncludeDepth = 16

// accumulate are the keywords whose values add up across matching
// lines rather than the first one winning.
var accumulate = map[string]bool{
	"identityfile":    true,
	"certificatefile": true,
	"localforward":    true,
	"remoteforward":   true,
	"dynamicforward":  true,
	"sendenv":         true,
	"setenv":          true,
}

type Config struct {
	entries []entry
	// Warnings are about things read but not supported (Match).
	Warnings []string
}

type entry struct {
	// patterns from the Host line the entry is under; nil matches every
	// host (before the first Host, or an override).
	patterns []string
	// never is set under a Match, which isn't evaluated.
	never bool
	key   string
	args  []string
}

// Load reads files in order, skipping any that don't exist. Relative
// Include paths resolve against includeDir (~/.ssh for a user's
// config).
func Load(includeDir string, files ...string) (*Config, error) {
	c := &Config{}
	for _, f := range files {
		if err := c.loadFile(f, includeDir, nil, false, 0); err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	}
	return c, nil
}

// Parse reads one config from r.
func Parse(r io.Reader, includeDir string) (*Config, error) {
	c := &Config{}
	if err := c.parse(r, "config", includeDir, nil, false, 0); err != nil {
		return nil, err
	}
	return c, nil
}

// Prepend adds lines that apply to every host ahead of everything read,
// so they win: what ssh's -o does.
func (c *Config) Prepend(lines ...string) error {
	var added []entry
	for _, line := range lines {
		key, args, err := splitLine(line)
		if err != nil {
			return fmt.Errorf("option %q: %w", line, err)
		}
		if key == "" {
			continue
		}
		switch key {
		case "host", "match", "include":
			return fmt.Errorf("option %q: %s can't be given as an option", line, key)
		}
		added = append(added, entry{key: key, args: args})
	}
	c.entries = append(added, c.entries...)
	return nil
}

func (c *Config) loadFile(path, includeDir string, patterns []string, never bool, depth int) error {
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return c.parse(f, path, includeDir, patterns, never, depth)
}

func (c *Config) parse(r io.Reader, name, includeDir string, patterns []string, never bool, depth int) error {
	sc := bufio.NewScanner(r)
	for n := 1; sc.Scan(); n++ {
		key, args, err := splitLine(sc.Text())
		if err != nil {
			return fmt.Errorf("%s:%d: %w", name, n, err)
		}
		switch key {
		case "":
		case "host":
			if len(args) == 0 {
				return fmt.Errorf("%s:%d: Host without patterns", name, n)
			}
			patterns, never = args, false
		case "match":
			// "Match all" is the one form we can honor without
			// evaluating anything.
			if len(args) == 1 && strings.EqualFold(args[0], "all") {
				patterns, never = []string{"*"}, false
				continue
			}
			patterns, never = nil, true
			c.Warnings = append(c.Warnings, fmt.Sprintf("%s:%d: Match isn't supported; its block is ignored", name, n))
		case "include":
			if depth >= maxIncludeDepth {
				return fmt.Errorf("%s:%d: Include nested too deeply", name, n)
			}
			for _, arg := range args {
				if err := c.include(arg, includeDir, patterns, never, depth+1); err != nil {
					return fmt.Errorf("%s:%d: %w", name, n, err)
				}
			}
		default:
			c.entries = append(c.entries, entry{patterns: patterns, never: never, key: key, args: args})
		}
	}
	return sc.Err()
}

// include reads the files a pattern names, in sorted order. Their
// lines before any Host of their own belong to the including block.
func (c *Config) include(pattern, includeDir string, patterns []string, never bool, depth int) error {
	pattern = expandHome(pattern)
	if !filepath.IsAbs(pattern) {
		pattern = filepath.Join(includeDir, pattern)
	}
	matches, err := filepath.Glob(pattern)
	if err != nil {
		return err
	}
	sort.Strings(matches)
	for _, m := range matches {
		if err := c.loadFile(m, includeDir, patterns, never, depth); err != nil {
			return err
		}
	}
	return nil
}

// splitLine splits a config line into its lowercased keyword and its
// arguments. Keyword and arguments are separated by whitespace and/or
// one "="; arguments may be double-quoted. Blank lines and comments
// give an empty keyword.
func splitLine(line string) (string, []string, error) {
	line = strings.TrimSpace(line)
	if line == "" || line[0] == '#' {
		return "", nil, nil
	}
	end := strings.IndexAny(line, " \t=")
	if end < 0 {
		return strings.ToLower(line), nil, nil
	}
	key := strings.ToLower(line[:end])
	rest := strings.TrimLeft(line[end:], " \t")
	if strings.HasPrefix(rest, "=") {
		rest = strings.TrimLeft(rest[1:], " \t")
	}
	var args []string
	for rest != "" {
		if rest[0] == '"' {
			close := strings.IndexByte(rest[1:], '"')
			if close < 0 {
				return "", nil, errors.New("unterminated quote")
			}
			args = append(args, rest[1:1+close])
			rest = rest[2+close:]
		} else {
			end := strings.IndexAny(rest, " \t")
			if end < 0 {
				end = len(rest)
			}
			args = append(args, rest[:end])
			rest = rest[end:]
		}
		rest = strings.TrimLeft(rest, " \t")
	}
	return key, args, nil
}

// Values are the settings for one host.
type Values struct {
	first map[string][]string
	all   map[string][]string
}

// Lookup gathers the settings for host, the name as given.
func (c *Config) Lookup(host string) Values {
	v := Values{first: map[string][]string{}, all: map[string][]string{}}
	for _, e := range c.entries {
		if e.never || !matchHost(e.patterns, host) {
			continue
		}
		if accumulate[e.key] {
			v.all[e.key] = append(v.all[e.key], e.args...)
			continue
		}
		if _, ok := v.first[e.key]; !ok {
			v.first[e.key] = e.args
		}
	}
	return v
}

// Get is the first argument of keyword's value, or "".
func (v Values) Get(keyword string) string {
	if args := v.first[strings.ToLower(keyword)]; len(args) > 0 {
		return args[0]
	}
	return ""
}

// Args are all the arguments of keyword's value.
func (v Values) Args(keyword string) []string {
	return v.first[strings.ToLower(keyword)]
}

// All are the values of an accumulating keyword, in order.
func (v Values) All(keyword string) []string {
	return v.all[strings.ToLower(keyword)]
}

// matchHost reports whether host matches a Host line's patterns: one
// that isn't negated matches and no negated one does. Nil patterns
// match everything.
func matchHost(patterns []string, host string) bool {
	if patterns == nil {
		return true
	}
	host = strings.ToLower(host)
	matched := false
	for _, p := range patterns {
		if neg, ok := strings.CutPrefix(p, "!"); ok {
			if matchPattern(strings.ToLower(neg), host) {
				return false
			}
		} else if matchPattern(strings.ToLower(p), host) {
			matched = true
		}
	}
	return matched
}

// matchPattern matches ssh's wildcards: * for any run, ? for one
// character.
func matchPattern(p, s string) bool {
	for len(p) > 0 {
		switch p[0] {
		case '*':
			p = strings.TrimLeft(p, "*")
			if p == "" {
				return true
			}
			for i := range len(s) + 1 {
				if matchPattern(p, s[i:]) {
					return true
				}
			}
			return false
		case '?':
			if s == "" {
				return false
			}
			p, s = p[1:], s[1:]
		default:
			if s == "" || p[0] != s[0] {
				return false
			}
			p, s = p[1:], s[1:]
		}
	}
	return s == ""
}

func expandHome(path string) string {
	if path == "~" || strings.HasPrefix(path, "~/") || strings.HasPrefix(path, `~\`) {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, path[1:])
		}
	}
	return path
}
