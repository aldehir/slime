package socks

import (
	"encoding/binary"
	"io"
	"net"
	"strconv"
	"sync"
	"testing"
	"time"
)

// echo listens on addr ("127.0.0.1:0", "[::1]:0") and echoes each
// connection until its client half-closes, then says "bye" and closes.
func echo(t *testing.T, addr string) net.Listener {
	t.Helper()
	l, err := net.Listen("tcp", addr)
	if err != nil {
		t.Skipf("listen %s: %v", addr, err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() {
				defer c.Close()
				io.Copy(c, c)
				c.Write([]byte("bye"))
			}()
		}
	}()
	return l
}

// start runs a server whose dialer is net.Dial, recording what it was
// asked for.
func start(t *testing.T) (addr string, asked func() []string) {
	t.Helper()
	var mu sync.Mutex
	var dialed []string
	s := New(func(network, addr string) (net.Conn, error) {
		mu.Lock()
		dialed = append(dialed, addr)
		mu.Unlock()
		// Names resolve at the dialer: here, echo.test is the
		// loopback.
		host, port, _ := net.SplitHostPort(addr)
		if host == "echo.test" {
			addr = net.JoinHostPort("127.0.0.1", port)
		}
		return net.Dial(network, addr)
	})
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go s.Serve(l)
	t.Cleanup(func() { s.Close() })
	return l.Addr().String(), func() []string {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), dialed...)
	}
}

// request greets the server at proxy and sends cmd for the address
// (atyp, raw), returning the connection and the reply code.
func request(t *testing.T, proxy string, cmd, atyp byte, raw []byte, port int) (net.Conn, byte) {
	t.Helper()
	c, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(10 * time.Second))
	if _, err := c.Write([]byte{5, 1, 0}); err != nil {
		t.Fatal(err)
	}
	var greet [2]byte
	if _, err := io.ReadFull(c, greet[:]); err != nil || greet != [2]byte{5, 0} {
		t.Fatalf("greeting %v, %v", greet, err)
	}
	req := append([]byte{5, cmd, 0, atyp}, raw...)
	req = binary.BigEndian.AppendUint16(req, uint16(port))
	if _, err := c.Write(req); err != nil {
		t.Fatal(err)
	}
	var rep [4]byte
	if _, err := io.ReadFull(c, rep[:]); err != nil {
		t.Fatalf("reply: %v", err)
	}
	n := 4
	switch rep[3] {
	case atypIPv6:
		n = 16
	case atypIPv4:
	default:
		t.Fatalf("reply address type %d", rep[3])
	}
	if _, err := io.ReadFull(c, make([]byte, n+2)); err != nil {
		t.Fatalf("reply address: %v", err)
	}
	return c, rep[1]
}

// roundTrip sends text through c, half-closes, and expects it back
// followed by the echo server's goodbye.
func roundTrip(t *testing.T, c net.Conn) {
	t.Helper()
	if _, err := c.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	c.(*net.TCPConn).CloseWrite()
	got, err := io.ReadAll(c)
	if err != nil || string(got) != "hellobye" {
		t.Errorf("got %q, %v", got, err)
	}
}

func port(l net.Listener) int { return l.Addr().(*net.TCPAddr).Port }

func TestConnectIPv4(t *testing.T) {
	l := echo(t, "127.0.0.1:0")
	proxy, asked := start(t)
	c, rep := request(t, proxy, cmdConnect, atypIPv4, []byte{127, 0, 0, 1}, port(l))
	if rep != repOK {
		t.Fatalf("reply %d", rep)
	}
	roundTrip(t, c)
	if a := asked(); len(a) != 1 || a[0] != "127.0.0.1:"+strconv.Itoa(port(l)) {
		t.Errorf("dialed %q", a)
	}
}

// A name goes to the dialer as given, unresolved.
func TestConnectDomain(t *testing.T) {
	l := echo(t, "127.0.0.1:0")
	proxy, asked := start(t)
	name := "echo.test"
	c, rep := request(t, proxy, cmdConnect, atypDomain, append([]byte{byte(len(name))}, name...), port(l))
	if rep != repOK {
		t.Fatalf("reply %d", rep)
	}
	roundTrip(t, c)
	if a := asked(); len(a) != 1 || a[0] != "echo.test:"+strconv.Itoa(port(l)) {
		t.Errorf("dialed %q", a)
	}
}

func TestConnectIPv6(t *testing.T) {
	l := echo(t, "[::1]:0")
	proxy, asked := start(t)
	c, rep := request(t, proxy, cmdConnect, atypIPv6, net.IPv6loopback, port(l))
	if rep != repOK {
		t.Fatalf("reply %d", rep)
	}
	roundTrip(t, c)
	if a := asked(); len(a) != 1 || a[0] != "[::1]:"+strconv.Itoa(port(l)) {
		t.Errorf("dialed %q", a)
	}
}

func TestConnectRefused(t *testing.T) {
	// A port that was listening a moment ago, and isn't now.
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	p := port(l)
	l.Close()
	proxy, _ := start(t)
	if _, rep := request(t, proxy, cmdConnect, atypIPv4, []byte{127, 0, 0, 1}, p); rep != repRefused {
		t.Errorf("reply %d, want %d (refused)", rep, repRefused)
	}
}

// BIND (2) and UDP ASSOCIATE (3) aren't served.
func TestCommandNotSupported(t *testing.T) {
	proxy, asked := start(t)
	for _, cmd := range []byte{2, 3} {
		if _, rep := request(t, proxy, cmd, atypIPv4, []byte{127, 0, 0, 1}, 80); rep != repCommandNotSupported {
			t.Errorf("command %d: reply %d", cmd, rep)
		}
	}
	if a := asked(); len(a) != 0 {
		t.Errorf("dialed %q", a)
	}
}

// A client offering only username/password is turned away.
func TestNoAcceptableMethod(t *testing.T) {
	proxy, _ := start(t)
	c, err := net.Dial("tcp", proxy)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(10 * time.Second))
	c.Write([]byte{5, 1, 2})
	got, _ := io.ReadAll(c)
	if string(got) != "\x05\xff" {
		t.Errorf("got %q", got)
	}
}

// Close ends tunnels in flight.
func TestCloseEndsTunnels(t *testing.T) {
	l := echo(t, "127.0.0.1:0")
	s := New(net.Dial)
	pl, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	served := make(chan error, 1)
	go func() { served <- s.Serve(pl) }()
	c, rep := request(t, pl.Addr().String(), cmdConnect, atypIPv4, []byte{127, 0, 0, 1}, port(l))
	if rep != repOK {
		t.Fatalf("reply %d", rep)
	}
	s.Close()
	if err := <-served; err != nil {
		t.Errorf("Serve: %v", err)
	}
	// Ended (EOF, or a reset), not timed out.
	if _, err := io.ReadAll(c); err != nil {
		if ne, ok := err.(net.Error); ok && ne.Timeout() {
			t.Error("tunnel still open")
		}
	}
}
