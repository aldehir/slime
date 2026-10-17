//go:build !windows

package persist

import "io"

// Hosts are connected from Windows only: the daemon here is the one on
// a host, which carries no SSH client.

// HostOptions configures connecting to SSH hosts; nothing, here.
type HostOptions struct{}

type hostTable struct{}

func newHostTable(HostOptions) hostTable { return hostTable{} }

func (s *Server) hostsActiveLocked() int { return 0 }

func (s *Server) hostClientGoneLocked(*conn) {}

const noHosts = "this slimed connects to no hosts (not Windows)"

func (s *Server) hostDispatch(c *conn, id uint32, m Message) bool {
	switch m := m.(type) {
	case *HostConnect:
		c.sendForce(0, &Error{Tag: m.Tag, Message: noHosts})
	case *HostAnswer, *HostDisconnect:
	case *HostList:
		c.sendForce(0, &Hosts{})
	default:
		return false
	}
	return true
}

func (s *Server) bridge(rw io.ReadWriteCloser, _ *Reader, _ uint32, _ *Bridge) {
	writeError(rw, noHosts)
}
