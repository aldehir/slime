// Package socks is a SOCKS5 server (RFC 1928): no authentication, and
// CONNECT only, which is what a browser or curl pointed at it uses.
// Each request is dialed through a function the caller supplies, with
// names passed through unresolved, so a dialer that is an SSH
// connection has the host resolve them: "intranet:80" means what it
// means there.
package socks

import (
	"encoding/binary"
	"errors"
	"io"
	"net"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

// Dialer opens a connection to addr ("host:port", the host a name or an
// IP literal) for one request.
type Dialer func(network, addr string) (net.Conn, error)

// Server serves SOCKS5 on the listeners it's given, until closed.
type Server struct {
	dial Dialer

	mu     sync.Mutex
	lns    map[net.Listener]struct{}
	conns  map[net.Conn]struct{}
	closed bool
	wg     sync.WaitGroup
}

func New(dial Dialer) *Server {
	return &Server{dial: dial, lns: map[net.Listener]struct{}{}, conns: map[net.Conn]struct{}{}}
}

// Serve accepts on l until it fails or the server is closed, which
// returns nil.
func (s *Server) Serve(l net.Listener) error {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		l.Close()
		return nil
	}
	s.lns[l] = struct{}{}
	s.mu.Unlock()
	for {
		c, err := l.Accept()
		if err != nil {
			s.mu.Lock()
			closed := s.closed
			delete(s.lns, l)
			s.mu.Unlock()
			if closed {
				return nil
			}
			return err
		}
		if !s.track(c, true) {
			c.Close()
			return nil
		}
		go func() {
			defer s.track(c, false)
			s.handle(c)
		}()
	}
}

// Close stops listening and ends every connection, the tunnels too, and
// waits for them.
func (s *Server) Close() error {
	s.mu.Lock()
	s.closed = true
	for l := range s.lns {
		l.Close()
	}
	for c := range s.conns {
		c.Close()
	}
	s.mu.Unlock()
	s.wg.Wait()
	return nil
}

// track adds c to the connections Close ends and waits for, or removes
// it; adding fails once closed.
func (s *Server) track(c net.Conn, add bool) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !add {
		delete(s.conns, c)
		s.wg.Done()
		return true
	}
	if s.closed {
		return false
	}
	s.conns[c] = struct{}{}
	s.wg.Add(1)
	return true
}

const version = 5

// Commands, address types, and replies.
const (
	cmdConnect = 1

	atypIPv4   = 1
	atypDomain = 3
	atypIPv6   = 4

	repOK                  = 0
	repFailure             = 1
	repNotAllowed          = 2
	repNetworkUnreachable  = 3
	repHostUnreachable     = 4
	repRefused             = 5
	repCommandNotSupported = 7
	repAddrNotSupported    = 8
)

// handle is one client: the greeting, its request, and the tunnel.
func (s *Server) handle(c net.Conn) {
	defer c.Close()
	// Greeting: VER NMETHODS METHODS; only "no authentication" (0).
	var hdr [2]byte
	if _, err := io.ReadFull(c, hdr[:]); err != nil || hdr[0] != version {
		return
	}
	methods := make([]byte, hdr[1])
	if _, err := io.ReadFull(c, methods); err != nil {
		return
	}
	if !slices.Contains(methods, 0) {
		c.Write([]byte{version, 0xff})
		return
	}
	if _, err := c.Write([]byte{version, 0}); err != nil {
		return
	}

	// Request: VER CMD RSV ATYP DST.ADDR DST.PORT.
	var req [4]byte
	if _, err := io.ReadFull(c, req[:]); err != nil || req[0] != version {
		return
	}
	host, err := readAddr(c, req[3])
	if err != nil {
		reply(c, repAddrNotSupported, nil)
		return
	}
	var port [2]byte
	if _, err := io.ReadFull(c, port[:]); err != nil {
		return
	}
	if req[1] != cmdConnect {
		reply(c, repCommandNotSupported, nil)
		return
	}
	addr := net.JoinHostPort(host, strconv.Itoa(int(binary.BigEndian.Uint16(port[:]))))
	remote, err := s.dial("tcp", addr)
	if err != nil {
		reply(c, replyFor(err), nil)
		return
	}
	if !s.track(remote, true) {
		remote.Close()
		return
	}
	defer s.track(remote, false)
	defer remote.Close()
	if reply(c, repOK, remote.LocalAddr()) != nil {
		return
	}
	pipe(c, remote)
}

// readAddr reads DST.ADDR of type atyp: an IP's text, or the name as
// given.
func readAddr(r io.Reader, atyp byte) (string, error) {
	switch atyp {
	case atypIPv4, atypIPv6:
		ip := make(net.IP, net.IPv4len)
		if atyp == atypIPv6 {
			ip = make(net.IP, net.IPv6len)
		}
		if _, err := io.ReadFull(r, ip); err != nil {
			return "", err
		}
		return ip.String(), nil
	case atypDomain:
		var n [1]byte
		if _, err := io.ReadFull(r, n[:]); err != nil {
			return "", err
		}
		name := make([]byte, n[0])
		if _, err := io.ReadFull(r, name); err != nil {
			return "", err
		}
		return string(name), nil
	}
	return "", errors.New("unknown address type")
}

// reply sends a reply with BND.ADDR from bound if it's an IP address,
// else zeros.
func reply(w io.Writer, rep byte, bound net.Addr) error {
	b := []byte{version, rep, 0}
	var ip net.IP
	var port int
	if a, ok := bound.(*net.TCPAddr); ok {
		ip, port = a.IP, a.Port
	}
	if ip4 := ip.To4(); ip4 != nil {
		b = append(append(b, atypIPv4), ip4...)
	} else if len(ip) == net.IPv6len {
		b = append(append(b, atypIPv6), ip...)
	} else {
		b = append(b, atypIPv4, 0, 0, 0, 0)
	}
	b = binary.BigEndian.AppendUint16(b, uint16(port))
	_, err := w.Write(b)
	return err
}

// replyFor is the reply for a failed dial. A dialer over SSH fails with
// the host's words ("connect failed: Connection refused"), so the text
// counts as much as the errno.
func replyFor(err error) byte {
	var dns *net.DNSError
	text := strings.ToLower(err.Error())
	switch {
	case errors.Is(err, syscall.ECONNREFUSED) || strings.Contains(text, "refused"):
		return repRefused
	case errors.Is(err, syscall.ENETUNREACH) || strings.Contains(text, "network is unreachable"):
		return repNetworkUnreachable
	case errors.As(err, &dns) || errors.Is(err, syscall.EHOSTUNREACH) ||
		strings.Contains(text, "unreachable") || strings.Contains(text, "no such host") ||
		strings.Contains(text, "name or service not known"):
		return repHostUnreachable
	case strings.Contains(text, "prohibited"):
		return repNotAllowed
	}
	return repFailure
}

// pipe copies both ways until both are done, passing on each side's
// end of input as a half-close where the other side can take one.
func pipe(a, b net.Conn) {
	done := make(chan struct{})
	go func() {
		io.Copy(b, a)
		closeWrite(b)
		close(done)
	}()
	io.Copy(a, b)
	closeWrite(a)
	<-done
}

func closeWrite(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		cw.CloseWrite()
		return
	}
	c.Close()
}
