package helper

import (
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
)

// Destination is where to connect. Zero fields take defaults later.
type Destination struct {
	User string
	Host string
	Port int
}

// ParseDestination accepts what ssh does: [user@]host, with an optional
// :port when the host isn't a bare IPv6 address ([::1]:22 is fine), or
// ssh://[user@]host[:port].
func ParseDestination(s string) (Destination, error) {
	if rest, ok := strings.CutPrefix(s, "ssh://"); ok {
		u, err := url.Parse("ssh://" + rest)
		if err != nil {
			return Destination{}, fmt.Errorf("bad destination %q: %w", s, err)
		}
		if u.Path != "" && u.Path != "/" {
			return Destination{}, fmt.Errorf("bad destination %q: unexpected path", s)
		}
		d := Destination{User: u.User.Username(), Host: u.Hostname()}
		if p := u.Port(); p != "" {
			if d.Port, err = parsePort(p); err != nil {
				return Destination{}, fmt.Errorf("bad destination %q: %w", s, err)
			}
		}
		if d.Host == "" {
			return Destination{}, fmt.Errorf("bad destination %q: no host", s)
		}
		return d, nil
	}

	var d Destination
	host := s
	if i := strings.LastIndexByte(s, '@'); i >= 0 {
		d.User, host = s[:i], s[i+1:]
	}
	switch {
	case strings.HasPrefix(host, "["):
		h, p, err := net.SplitHostPort(host)
		if err != nil {
			h, p = strings.TrimSuffix(strings.TrimPrefix(host, "["), "]"), ""
		}
		host = h
		if p != "" {
			if d.Port, err = parsePort(p); err != nil {
				return Destination{}, fmt.Errorf("bad destination %q: %w", s, err)
			}
		}
	case strings.Count(host, ":") == 1:
		h, p, _ := strings.Cut(host, ":")
		port, err := parsePort(p)
		if err != nil {
			return Destination{}, fmt.Errorf("bad destination %q: %w", s, err)
		}
		host, d.Port = h, port
	}
	if host == "" {
		return Destination{}, fmt.Errorf("bad destination %q: no host", s)
	}
	d.Host = host
	return d, nil
}

func parsePort(s string) (int, error) {
	p, err := strconv.Atoi(s)
	if err != nil || p < 1 || p > 65535 {
		return 0, fmt.Errorf("bad port %q", s)
	}
	return p, nil
}

// Addr is host:port for dialing and for known_hosts.
func (d Destination) Addr() string {
	return net.JoinHostPort(d.Host, strconv.Itoa(d.Port))
}
