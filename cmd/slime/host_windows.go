package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"golang.org/x/term"

	"github.com/aldehir/slime/internal/daemon"
	"github.com/aldehir/slime/internal/remote"
)

// hostOptions configures the daemon's hosts: the builds to install come
// from remoteDir, or from beside the executable.
func hostOptions(remoteDir string) (daemon.HostOptions, error) {
	if remoteDir == "" {
		return daemon.HostOptions{}, nil
	}
	m, err := remote.Load(remoteDir)
	if err != nil {
		return daemon.HostOptions{}, fmt.Errorf("--remote: %w", err)
	}
	return daemon.HostOptions{Remote: m}, nil
}

// hostCommands connect, list, and disconnect the daemon's SSH hosts.
func hostCommands() []*cobra.Command {
	host := &cobra.Command{Use: "host", Short: "Connect to SSH hosts, list them, and disconnect"}
	host.AddCommand(&cobra.Command{
		Use:   "connect <destination>",
		Short: "Log in to a host and keep the connection in the daemon",
		Long: "Logs in to destination ([user@]host[:port], ssh://[user@]host[:port], or a Host\n" +
			"from ~/.ssh/config), answering its prompts on this console, and puts slime\n" +
			"there. The daemon keeps the connection for windows to use.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := connect(true)
			if err != nil {
				return err
			}
			defer c.Close()
			return hostConnect(c, args[0])
		},
	}, &cobra.Command{
		Use:   "ls",
		Short: "List the hosts the daemon knows and their state",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			hosts, err := hostList(c)
			if err != nil {
				return err
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			for _, h := range hosts.Hosts {
				fmt.Fprintf(w, "host %d\t%s\t%s\t%s\n", h.ID, h.Dest, h.State, h.Text)
			}
			return w.Flush()
		},
	}, &cobra.Command{
		Use:   "disconnect <id|destination>",
		Short: "Hang up on a host, ending every window's panes there",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			hosts, err := hostList(c)
			if err != nil {
				return err
			}
			var id uint32
			for _, h := range hosts.Hosts {
				if strconv.FormatUint(uint64(h.ID), 10) == args[0] || h.Dest == args[0] {
					id = h.ID
				}
			}
			if id == 0 {
				return fmt.Errorf("no host %q", args[0])
			}
			if err := c.Send(id, &daemon.HostDisconnect{}); err != nil {
				return err
			}
			// Read something after it, so the daemon has it before we
			// hang up.
			_, err = hostList(c)
			return err
		},
	})
	return []*cobra.Command{host}
}

// hostList asks for the hosts.
func hostList(c *daemon.Client) (*daemon.Hosts, error) {
	if err := c.Send(0, &daemon.HostList{}); err != nil {
		return nil, err
	}
	for {
		_, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		switch m := m.(type) {
		case *daemon.Hosts:
			return m, nil
		case *daemon.Error:
			return nil, fmt.Errorf("slime: %s", m.Message)
		}
	}
}

// hostConnect asks the daemon to connect to dest and follows it there,
// answering the prompts on the console.
func hostConnect(c *daemon.Client, dest string) error {
	tag := c.NextTag()
	if err := c.Send(0, &daemon.HostConnect{Tag: tag, Dest: dest}); err != nil {
		return err
	}
	var id uint32
	lastText := ""
	for {
		got, m, err := c.Recv()
		if err != nil {
			return err
		}
		switch m := m.(type) {
		case *daemon.HostState:
			if m.Tag == tag {
				id = got
			}
			if got != id {
				continue
			}
			switch m.State {
			case daemon.HostConnecting:
				if m.Text != "" && m.Text != lastText {
					fmt.Fprintln(os.Stderr, m.Text)
					lastText = m.Text
				}
			case daemon.HostConnected:
				fmt.Fprintf(os.Stderr, "connected to %s (host %d)\n", m.Dest, id)
				return nil
			default:
				return fmt.Errorf("%s: %s", m.State, m.Text)
			}
		case *daemon.Prompt:
			if got != id {
				continue
			}
			ans, err := askConsole(m)
			if err != nil {
				c.Send(id, &daemon.HostAnswer{Choice: daemon.ChoiceCancel})
				return err
			}
			if err := c.Send(id, ans); err != nil {
				return err
			}
		case *daemon.Error:
			if m.Tag == tag {
				return errors.New(m.Message)
			}
		}
	}
}

// askConsole shows a prompt on the console and reads the answers. A
// prompt with no questions asks whether to go ahead (a host key).
func askConsole(p *daemon.Prompt) (*daemon.HostAnswer, error) {
	fd := int(os.Stdin.Fd())
	if !term.IsTerminal(fd) {
		return nil, errors.New("can't answer the host's prompts: stdin isn't a terminal")
	}
	for _, line := range []string{p.Title, p.Text, p.Detail, p.Error} {
		if line != "" {
			fmt.Fprintln(os.Stderr, line)
		}
	}
	in := bufio.NewReader(os.Stdin)
	if len(p.Questions) == 0 {
		fmt.Fprint(os.Stderr, "Continue (yes/no)? ")
		line, err := in.ReadString('\n')
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(line) != "yes" {
			return &daemon.HostAnswer{Choice: daemon.ChoiceCancel}, nil
		}
		return &daemon.HostAnswer{Choice: daemon.ChoiceAccept}, nil
	}
	ans := &daemon.HostAnswer{Choice: daemon.ChoiceAccept}
	for _, q := range p.Questions {
		fmt.Fprint(os.Stderr, q.Label)
		var line string
		if q.Echo {
			s, err := in.ReadString('\n')
			if err != nil {
				return nil, err
			}
			line = s
		} else {
			b, err := term.ReadPassword(fd)
			fmt.Fprintln(os.Stderr)
			if err != nil {
				return nil, err
			}
			line = string(b)
		}
		ans.Answers = append(ans.Answers, strings.TrimRight(line, "\r\n"))
	}
	return ans, nil
}
