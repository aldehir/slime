package main

import (
	"bufio"
	"encoding/json"
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
	"github.com/aldehir/slime/internal/rpc"
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
			h, err := hostConnect(c, args[0])
			if err != nil {
				return err
			}
			if jsonOut {
				return printJSON(h)
			}
			return nil
		},
	}, &cobra.Command{
		Use:   "ls",
		Short: "List the hosts the daemon knows and their state",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			var hosts rpc.HostListResult
			if err := call(rpc.HostList, nil, &hosts); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(hosts)
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
			var hosts rpc.HostListResult
			if err := c.Call(rpc.HostList, nil, &hosts); err != nil {
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
			return c.Call(rpc.HostDisconnect, rpc.HostParams{Host: id}, nil)
		},
	})
	return []*cobra.Command{host}
}

// hostConnect asks the daemon to connect to dest and follows it there,
// answering the prompts on the console, until it's connected or has
// failed.
func hostConnect(c *daemon.Client, dest string) (*rpc.Host, error) {
	// Before asking, so no change is missed.
	if err := c.Call(rpc.Subscribe, rpc.SubscribeParams{Events: []string{rpc.EvHostChanged}}, nil); err != nil {
		return nil, err
	}
	var h rpc.Host
	if err := c.Call(rpc.HostConnect, rpc.HostConnectParams{Dest: dest}, &h); err != nil {
		return nil, err
	}
	lastText := ""
	for {
		switch h.State {
		case rpc.HostConnecting:
			if h.Text != "" && h.Text != lastText {
				fmt.Fprintln(os.Stderr, h.Text)
				lastText = h.Text
			}
		case rpc.HostConnected:
			fmt.Fprintf(os.Stderr, "connected to %s (host %d)\n", h.Dest, h.ID)
			return &h, nil
		default:
			return nil, fmt.Errorf("%s: %s", h.State, h.Text)
		}
		_, m, err := c.Recv()
		if err != nil {
			return nil, err
		}
		name, params, ok := daemon.Notification(m)
		if !ok {
			continue
		}
		switch name {
		case rpc.EvHostChanged:
			var got rpc.Host
			if err := json.Unmarshal(params, &got); err != nil || got.ID != h.ID {
				continue
			}
			h = got
		case rpc.EvHostPrompt:
			var p rpc.HostPromptParams
			if err := json.Unmarshal(params, &p); err != nil || p.Host != h.ID {
				continue
			}
			ans, err := askConsole(&p)
			if err != nil {
				c.Call(rpc.HostAnswer, rpc.HostAnswerParams{Host: h.ID, Choice: rpc.ChoiceCancel}, nil)
				return nil, err
			}
			if err := c.Call(rpc.HostAnswer, ans, nil); err != nil {
				return nil, err
			}
		}
	}
}

// askConsole shows a prompt on the console and reads the answers. A
// prompt with no questions asks whether to go ahead (a host key).
func askConsole(p *rpc.HostPromptParams) (*rpc.HostAnswerParams, error) {
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
	ans := &rpc.HostAnswerParams{Host: p.Host, Choice: rpc.ChoiceAccept}
	if len(p.Questions) == 0 {
		fmt.Fprint(os.Stderr, "Continue (yes/no)? ")
		line, err := in.ReadString('\n')
		if err != nil {
			return nil, err
		}
		if strings.TrimSpace(line) != "yes" {
			ans.Choice = rpc.ChoiceCancel
		}
		return ans, nil
	}
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
