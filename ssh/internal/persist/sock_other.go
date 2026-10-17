//go:build unix && !linux

package persist

import "net"

// checkPeer trusts the socket's directory, which only we can enter.
func checkPeer(*net.UnixConn) error { return nil }
