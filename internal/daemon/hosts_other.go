//go:build !windows

package daemon

import (
	"io"

	"github.com/aldehir/slime/internal/rpc"
)

// Hosts are connected from Windows only: the daemon here is the one on
// a host, which carries no SSH client.

// HostOptions configures connecting to SSH hosts; nothing, here.
type HostOptions struct{}

type hostTable struct{}

func newHostTable(HostOptions) hostTable { return hostTable{} }

func (s *Server) hostsActiveLocked() int { return 0 }

func (s *Server) hostClientGoneLocked(*conn) {}

const noHosts = "this slime connects to no hosts (not Windows)"

func noHostsError() error { return rpc.Errorf(rpc.CodeUnsupported, "%s", noHosts) }

func (s *Server) hostConnect(*callCtx, rpc.HostConnectParams) (*rpc.Host, error) {
	return nil, noHostsError()
}

func (s *Server) hostAnswer(*callCtx, rpc.HostAnswerParams) (rpc.Empty, error) {
	return rpc.Empty{}, noHostsError()
}

func (s *Server) hostDisconnect(*callCtx, rpc.HostParams) (rpc.Empty, error) {
	return rpc.Empty{}, noHostsError()
}

func (s *Server) hostList(*callCtx, rpc.Empty) (*rpc.HostListResult, error) {
	return &rpc.HostListResult{Hosts: []rpc.Host{}}, nil
}

func (s *Server) bridge(rw io.ReadWriteCloser, _ *Reader, _ uint32, _ *Bridge) {
	writeError(rw, noHosts)
}
