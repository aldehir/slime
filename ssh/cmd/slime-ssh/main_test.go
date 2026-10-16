package main

import (
	"bytes"
	"io"
	"strings"
	"testing"

	"github.com/aldehir/slime/ssh/internal/proto"
)

func TestHandshake(t *testing.T) {
	var in, out bytes.Buffer
	if err := proto.NewWriter(&in).Send(0, &proto.Hello{Version: proto.Version}); err != nil {
		t.Fatal(err)
	}
	if err := run("example", &in, &out); err != nil {
		t.Fatalf("run: %v", err)
	}
	f, err := proto.NewReader(&out).Read()
	if err != nil {
		t.Fatal(err)
	}
	m, err := proto.Decode(f)
	if err != nil {
		t.Fatal(err)
	}
	if reply, ok := m.(*proto.HelloReply); !ok || reply.Version != proto.Version {
		t.Errorf("reply = %#v", m)
	}
}

func TestHandshakeVersionMismatch(t *testing.T) {
	var in, out bytes.Buffer
	if err := proto.NewWriter(&in).Send(0, &proto.Hello{Version: 99}); err != nil {
		t.Fatal(err)
	}
	err := run("example", &in, &out)
	if err == nil || !strings.Contains(err.Error(), "protocol 99") {
		t.Fatalf("run = %v, want version error", err)
	}
	// The reply still goes out so slime can say which side is stale.
	if _, err := proto.NewReader(&out).Read(); err != nil {
		t.Errorf("no reply: %v", err)
	}
}

func TestNoHello(t *testing.T) {
	var out bytes.Buffer
	if err := run("example", strings.NewReader(""), &out); err == nil {
		t.Fatal("run succeeded without a hello")
	}
	if _, err := proto.NewReader(&out).Read(); err != io.EOF {
		t.Errorf("wrote a reply without a hello: %v", err)
	}
}
