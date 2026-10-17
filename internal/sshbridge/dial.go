// Package sshbridge logs in to SSH hosts for slime (Dial) and runs slime
// on them (Conn.StartDaemon), asking the user what logging in needs
// through an Asker.
package sshbridge

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"slices"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/ssh"

	"github.com/aldehir/slime/internal/prompt"
	"github.com/aldehir/slime/internal/remote"
	"github.com/aldehir/slime/internal/terminfo"
)

const defaultTerm = terminfo.Fallback

// Options say how to connect to a host.
type Options struct {
	// Dest has its user and port filled in.
	Dest Destination
	// Identities are key files to offer, in order; missing files are
	// skipped. The agent signs for any it holds.
	Identities []string
	// IdentitiesOnly offers the agent's keys only when they are among
	// Identities.
	IdentitiesOnly bool
	// Jumps are hosts to go through to reach Dest, first to last
	// (ProxyJump).
	Jumps []Hop

	// KnownHosts are the user's known_hosts files, the first of which
	// gets newly accepted keys. GlobalKnownHosts are only read.
	KnownHosts       []string
	GlobalKnownHosts []string
	// StrictHostKeyChecking is "ask" (or ""), "yes", "accept-new", or
	// "no". "no" adds new keys as accept-new does but still refuses
	// changed ones.
	StrictHostKeyChecking string
	// HashKnownHosts writes accepted hosts hashed.
	HashKnownHosts bool

	// ConnectTimeout bounds the TCP connect. Zero is the system's.
	ConnectTimeout time.Duration
	// KeepaliveInterval, when set, asks the server for a reply that
	// often, and gives up on the connection after KeepaliveCountMax go
	// unanswered (ServerAliveInterval, ServerAliveCountMax).
	KeepaliveInterval time.Duration
	KeepaliveCountMax int

	// DialAgent connects to an SSH agent. Nil means no agent.
	DialAgent func() (io.ReadWriteCloser, error)
	// Remote holds the builds of slime to install on hosts. Nil means
	// the ones beside the executable (remote.Beside).
	Remote *remote.Manifest
}

// Hop is a host to log in to on the way to the destination.
type Hop struct {
	Dest           Destination
	Identities     []string
	IdentitiesOnly bool
}

// Conn is a connection to a host, logged in. It ends when the host hangs
// up, the keepalives go unanswered, or Close is called; Wait says which.
type Conn struct {
	opts   Options
	client *ssh.Client
	// jumps carry client, first hop first.
	jumps []*ssh.Client

	mu sync.Mutex
	// reason is why the keepalive gave up, set before it closes client.
	reason error
	// terminfo is set once InstallTerminfo has run, with its answer in
	// ghosttyTerm.
	terminfo    bool
	ghosttyTerm bool
	// daemonExe is where slime is on the host, once it's been found or
	// installed there.
	daemonExe string

	done chan struct{}
	err  error
	// closedByUs is set before we close client, so the watcher can tell
	// our close from the remote's: through a jump host both end in EOF.
	closedByUs atomic.Bool
}

// Dial connects to opts.Dest through its jump hosts and logs in to each,
// asking the user through a. Cancelling ctx gives up, closing whatever
// is half connected; Dial then fails with ErrCancelled.
func Dial(ctx context.Context, opts Options, a Asker) (*Conn, error) {
	hops := append(slices.Clone(opts.Jumps), Hop{
		Dest:           opts.Dest,
		Identities:     opts.Identities,
		IdentitiesOnly: opts.IdentitiesOnly,
	})
	signers, closeAgent := agentSigners(opts.DialAgent)
	defer closeAgent()

	var jumps []*ssh.Client
	closeJumps := func() {
		for i := len(jumps) - 1; i >= 0; i-- {
			jumps[i].Close()
		}
	}
	// Cancelling closes the first hop's connection, which ends every
	// login in progress above it.
	var first net.Conn
	stopWatch := make(chan struct{})
	defer close(stopWatch)

	for i, hop := range hops {
		addr := hop.Dest.Addr()
		var conn net.Conn
		var err error
		if i == 0 {
			dialer := net.Dialer{Timeout: opts.ConnectTimeout}
			if conn, err = dialer.DialContext(ctx, "tcp", addr); err != nil {
				if ctx.Err() != nil {
					return nil, ErrCancelled
				}
				return nil, err
			}
			first = conn
			go func() {
				select {
				case <-ctx.Done():
					first.Close()
				case <-stopWatch:
				}
			}()
		} else if conn, err = jumps[i-1].Dial("tcp", addr); err != nil {
			closeJumps()
			if ctx.Err() != nil {
				return nil, ErrCancelled
			}
			return nil, fmt.Errorf("jump host %s can't reach %s: %w", hops[i-1].Dest.Host, addr, err)
		}

		client, err := loginHop(opts, conn, hop, signers, a)
		if err != nil {
			conn.Close()
			closeJumps()
			if ctx.Err() != nil {
				return nil, ErrCancelled
			}
			if i < len(hops)-1 {
				return nil, &jumpError{host: hop.Dest.Host, err: err}
			}
			return nil, err
		}
		if i == len(hops)-1 {
			c := &Conn{opts: opts, client: client, jumps: jumps, done: make(chan struct{})}
			go c.watch()
			if opts.KeepaliveInterval > 0 {
				go c.keepalive()
			}
			return c, nil
		}
		jumps = append(jumps, client)
	}
	panic("unreachable")
}

// loginHop checks hop's host key and logs in over conn.
func loginHop(opts Options, conn net.Conn, hop Hop, agentSigners []ssh.Signer, a Asker) (*ssh.Client, error) {
	addr := hop.Dest.Addr()
	hk := &hostKeys{
		files:  opts.KnownHosts,
		global: opts.GlobalKnownHosts,
		strict: opts.StrictHostKeyChecking,
		hash:   opts.HashKnownHosts,
		ui:     a,
	}
	check, algos, err := hk.callback(addr)
	if err != nil {
		return nil, err
	}
	auth := newAuthenticator(a, hop.Dest, agentSigners, loadKeys(hop.Identities), hop.IdentitiesOnly)
	config := &ssh.ClientConfig{
		User:              hop.Dest.User,
		AuthCallback:      auth.callback,
		HostKeyCallback:   check,
		HostKeyAlgorithms: algos,
		BannerCallback: func(msg string) error {
			a.Print(msg)
			return nil
		},
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, addr, config)
	if err != nil {
		return nil, err
	}
	return ssh.NewClient(c, chans, reqs), nil
}

// Client is the connection, for sessions of the caller's own.
func (c *Conn) Client() *ssh.Client { return c.client }

// Dest is the host the connection is to.
func (c *Conn) Dest() Destination { return c.opts.Dest }

// Done is closed when the connection has ended.
func (c *Conn) Done() <-chan struct{} { return c.done }

// Wait blocks until the connection ends and says why: nil if Close
// ended it, io.EOF if the host hung up, or the keepalive's timeout.
func (c *Conn) Wait() error {
	<-c.done
	return c.err
}

// Close hangs up, ending every session on the connection.
func (c *Conn) Close() error {
	c.closedByUs.Store(true)
	err := c.client.Close()
	for i := len(c.jumps) - 1; i >= 0; i-- {
		c.jumps[i].Close()
	}
	return err
}

// watch records how the connection ended.
func (c *Conn) watch() {
	err := c.client.Wait()
	c.mu.Lock()
	reason := c.reason
	c.mu.Unlock()
	switch {
	case reason != nil:
		err = reason
	case c.closedByUs.Load():
		err = nil
	case err == nil:
		err = io.EOF
	}
	c.err = err
	close(c.done)
}

// keepalive asks the server for a reply every KeepaliveInterval, as
// ssh's ServerAliveInterval does, and drops the connection when
// KeepaliveCountMax go unanswered. Any reply counts, even a refusal.
func (c *Conn) keepalive() {
	limit := max(c.opts.KeepaliveCountMax, 1)
	t := time.NewTicker(c.opts.KeepaliveInterval)
	defer t.Stop()
	var waiting atomic.Bool
	var missed atomic.Int32
	for {
		select {
		case <-c.done:
			return
		case <-t.C:
		}
		if waiting.Load() {
			if int(missed.Add(1)) >= limit {
				c.mu.Lock()
				c.reason = fmt.Errorf("Timeout, server %s not responding", c.opts.Dest.Host)
				c.mu.Unlock()
				c.client.Close()
				return
			}
			continue
		}
		waiting.Store(true)
		go func() {
			if _, _, err := c.client.SendRequest("keepalive@openssh.com", true, nil); err == nil {
				missed.Store(0)
				waiting.Store(false)
			}
		}()
	}
}

// InstallTerminfo makes sure the host has xterm-ghostty, the first time
// it's called, and reports whether it does. Call it before any shell
// starts, so they all get the same TERM.
func (c *Conn) InstallTerminfo() bool {
	c.mu.Lock()
	done, ok := c.terminfo, c.ghosttyTerm
	c.mu.Unlock()
	if done {
		return ok
	}
	ok = installTerminfo(c.client)
	c.mu.Lock()
	c.terminfo, c.ghosttyTerm = true, ok
	c.mu.Unlock()
	return ok
}

// Term is the TERM to give a session that asked for term: xterm-ghostty
// falls back where InstallTerminfo couldn't put it.
func (c *Conn) Term(term string) string {
	c.mu.Lock()
	defer c.mu.Unlock()
	if term == "" {
		return defaultTerm
	}
	if term == terminfo.Name && !c.ghosttyTerm {
		return terminfo.Fallback
	}
	return term
}

// jumpError is failing to log in to a jump host.
type jumpError struct {
	host string
	err  error
}

func (e *jumpError) Error() string { return "jump host " + e.host + ": " + e.err.Error() }
func (e *jumpError) Unwrap() error { return e.err }

// FailReason says why connecting failed, without x/crypto's "ssh:
// handshake failed:" wrapping where ours says it better.
func FailReason(err error) string {
	var jump *jumpError
	if errors.As(err, &jump) {
		return "jump host " + jump.host + ": " + FailReason(jump.err)
	}
	var denied *deniedError
	switch {
	case errors.As(err, &denied):
		return denied.Error()
	case errors.Is(err, errHostKeyRejected):
		return errHostKeyRejected.Error()
	case errors.Is(err, prompt.ErrInterrupted):
		return "interrupted"
	case errors.Is(err, ErrCancelled):
		return "cancelled"
	}
	return err.Error()
}

// LostReason says why a connection ended, from Wait's error.
func LostReason(err error) string {
	if err == nil || errors.Is(err, io.EOF) {
		return "connection closed by remote host"
	}
	return err.Error()
}
