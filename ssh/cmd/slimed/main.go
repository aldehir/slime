// slimed keeps terminals alive while no window shows them: it owns
// each pane's pty and terminal state, arranged in tabs and workspaces,
// and a window attaches a workspace with a snapshot of each pane
// followed by live output. slime is the client; the other commands here
// script workspaces and try them out from a console.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/aldehir/slime/ssh/internal/persist"
	"github.com/aldehir/slime/ssh/internal/pty"
	"github.com/aldehir/slime/ssh/internal/vt"
)

func main() {
	log.SetFlags(0)
	log.SetPrefix("slimed: ")
	if err := newCommand().Execute(); err != nil {
		log.Fatal(err)
	}
}

func newCommand() *cobra.Command {
	root := &cobra.Command{
		Use:           "slimed",
		Short:         "Keep terminals alive between attaches",
		Version:       fmt.Sprintf("protocol %d", persist.Version),
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	root.AddCommand(serveCommand(), connectCommand(), lsCommand(), wsCommand(), tabCommand(),
		splitCommand(), attachCommand(), peekCommand(), killCommand())
	root.AddCommand(hostCommands()...)
	return root
}

func serveCommand() *cobra.Command {
	var (
		idle      time.Duration
		logPath   string
		verbose   bool
		conptyDir string
		remoteDir string
		termName  string
	)
	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Run the daemon (the other commands start it when needed)",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			out := os.Stderr
			if logPath != "" {
				if err := os.MkdirAll(filepath.Dir(logPath), 0o700); err != nil {
					return err
				}
				f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
				if err != nil {
					return err
				}
				defer f.Close()
				out = f
			}
			level := slog.LevelInfo
			if verbose {
				level = slog.LevelDebug
			}
			logger := slog.New(slog.NewTextHandler(out, &slog.HandlerOptions{Level: level}))
			if conptyDir != "" {
				pty.SetConptyDir(conptyDir)
			}
			pty.SetTerm(termName)
			hosts, err := hostOptions(remoteDir)
			if err != nil {
				return err
			}
			return serve(logger, idle, hosts)
		},
	}
	cmd.Flags().StringVar(&conptyDir, "conpty", "", "directory holding conpty.dll (default: next to slimed.exe, else the system's)")
	cmd.Flags().StringVar(&remoteDir, "remote", "", "directory holding the builds of slimed for hosts and their manifest (default: remote/ next to slimed.exe)")
	cmd.Flags().StringVar(&termName, "term", "", "TERM for panes on Unix (default xterm-256color)")
	cmd.Flags().DurationVar(&idle, "idle", 10*time.Second, "exit after this long with no workspaces and no clients (0 never)")
	cmd.Flags().StringVar(&logPath, "log", "", "append logs to this file instead of stderr")
	cmd.Flags().BoolVarP(&verbose, "verbose", "v", false, "log libghostty-vt's debug output too")
	return cmd
}

func serve(logger *slog.Logger, idle time.Duration, hosts persist.HostOptions) error {
	name, err := persist.Address()
	if err != nil {
		return err
	}
	l, err := persist.Listen(name)
	if err != nil {
		return fmt.Errorf("listening on %s (is slimed already running?): %w", name, err)
	}
	ctx := context.Background()
	rt, err := vt.NewRuntime(ctx, logger)
	if err != nil {
		return err
	}
	defer rt.Close(ctx)
	srv, err := persist.NewServer(rt, persist.Options{Log: logger, Idle: idle, Hosts: hosts})
	if err != nil {
		return err
	}
	logger.Info("serving", "pipe", name, "pid", os.Getpid())
	return srv.Serve(l)
}

func connectCommand() *cobra.Command {
	var termName string
	cmd := &cobra.Command{
		Use:   "connect",
		Short: "Bridge stdin and stdout to the daemon, starting it if needed",
		Long: "Copies stdin to the daemon and the daemon's replies to stdout, for a client\n" +
			"that can't reach the socket itself: slime runs it over an SSH exec channel.",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			var serve []string
			if termName != "" {
				serve = append(serve, "--term", termName)
			}
			conn, err := dial(true, serve...)
			if err != nil {
				return err
			}
			defer conn.Close()
			go func() {
				io.Copy(conn, os.Stdin)
				// The client hung up: so do we, once the daemon has what
				// it sent.
				if cw, ok := conn.(interface{ CloseWrite() error }); ok {
					cw.CloseWrite()
				} else {
					conn.Close()
				}
			}()
			_, err = io.Copy(os.Stdout, conn)
			return err
		},
	}
	cmd.Flags().StringVar(&termName, "term", "", "TERM for panes, if this starts the daemon")
	return cmd
}

func lsCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "ls",
		Short: "List workspaces, their tabs, and their panes",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			l, err := c.List()
			if err != nil {
				return err
			}
			panes := map[uint32]persist.PaneInfo{}
			for _, p := range l.Panes {
				panes[p.ID] = p
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			for _, ws := range l.Workspaces {
				state := "attached"
				if !ws.Attached {
					state = "detached"
					if ws.DetachedAt != 0 {
						state += " " + time.UnixMilli(ws.DetachedAt).Format("Jan 2 15:04")
					}
				}
				fmt.Fprintf(w, "workspace %d\t%s\t%s\n", ws.ID, ws.Name, state)
				for _, t := range ws.Tabs {
					fmt.Fprintf(w, "  tab %d\t%s\t%s\n", t.ID, t.Name, layoutString(t.Tree))
					for _, id := range t.Tree.Panes() {
						p := panes[id]
						title := p.Title
						if title == "" {
							title = p.Command
						}
						fmt.Fprintf(w, "    pane %d\t%dx%d\tpid %d\t%s\n", id, p.Cols, p.Rows, p.PID, title)
					}
				}
			}
			return w.Flush()
		},
	}
}

// layoutString shows a tree compactly: row(60% 3, 40% col(50% 4, 50% 5)).
func layoutString(n *persist.Node) string {
	if n == nil {
		return ""
	}
	if n.Pane != 0 {
		return strconv.FormatUint(uint64(n.Pane), 10)
	}
	var b strings.Builder
	if n.Axis == persist.Row {
		b.WriteString("row(")
	} else {
		b.WriteString("col(")
	}
	for i, c := range n.Children {
		if i > 0 {
			b.WriteString(", ")
		}
		fmt.Fprintf(&b, "%g%% %s", float64(c.Share)/100, layoutString(c.Node))
	}
	b.WriteString(")")
	return b.String()
}

func wsCommand() *cobra.Command {
	ws := &cobra.Command{Use: "ws", Short: "Create, rename, and kill workspaces"}
	ws.AddCommand(&cobra.Command{
		Use:   "new [name]",
		Short: "Create a workspace, detached, and print its id",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := connect(true)
			if err != nil {
				return err
			}
			defer c.Close()
			id, err := newWorkspace(c, strings.Join(args, ""))
			if err != nil {
				return err
			}
			// Hanging up detaches it, but an empty workspace would go:
			// give it a shell.
			if _, err := tabNew(c, id, []string{""}, persist.Right); err != nil {
				return err
			}
			fmt.Println(id)
			return nil
		},
	}, &cobra.Command{
		Use:   "rename <workspace> <name>",
		Short: "Rename a workspace",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			return send(&persist.WorkspaceRename{WS: id, Name: args[1]})
		},
	}, &cobra.Command{
		Use:   "kill <workspace>",
		Short: "End a workspace and everything in it",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			return send(&persist.WorkspaceKill{WS: id})
		},
	})
	return ws
}

func tabCommand() *cobra.Command {
	var (
		wsID  uint32
		split string
	)
	newTab := &cobra.Command{
		Use:   "new [command]...",
		Short: "Start a tab; with several commands, one pane each, side by side or stacked",
		Long: "Starts a tab in a workspace: the one given, else the most recently detached,\n" +
			"else a new one. Each command (CreateProcessW syntax; empty for the shell)\n" +
			"gets a pane, sharing the tab equally along --split.",
		RunE: func(cmd *cobra.Command, args []string) error {
			dir := persist.Right
			switch split {
			case "right", "h":
			case "down", "v":
				dir = persist.Down
			default:
				return fmt.Errorf("--split is right or down, not %q", split)
			}
			if len(args) == 0 {
				args = []string{""}
			}
			c, err := connect(true)
			if err != nil {
				return err
			}
			defer c.Close()
			ws := wsID
			if ws == 0 {
				l, err := c.List()
				if err != nil {
					return err
				}
				if w := persist.MostRecentDetached(l); w != nil {
					ws = w.ID
				} else if ws, err = newWorkspace(c, ""); err != nil {
					return err
				}
			}
			created, err := tabNew(c, ws, args, dir)
			if err != nil {
				return err
			}
			fmt.Println(created.Tab)
			return nil
		},
	}
	newTab.Flags().Uint32VarP(&wsID, "workspace", "w", 0, "workspace to start it in")
	newTab.Flags().StringVar(&split, "split", "right", "how several commands share the tab: right (side by side) or down (stacked)")

	tab := &cobra.Command{Use: "tab", Short: "Start, rename, and close tabs"}
	tab.AddCommand(newTab, &cobra.Command{
		Use:   "rename <tab> <name>",
		Short: "Rename a tab",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			return send(&persist.TabRename{Tab: id, Name: args[1]})
		},
	}, &cobra.Command{
		Use:   "close <tab>",
		Short: "End a tab's panes",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			return send(&persist.TabClose{Tab: id})
		},
	})
	return tab
}

func splitCommand() *cobra.Command {
	var percent float64
	cmd := &cobra.Command{
		Use:   "split <pane> right|down|left|up [command]",
		Short: "Start a pane beside another, and print its id",
		Args:  cobra.RangeArgs(2, 3),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, err := parseID(args[0])
			if err != nil {
				return err
			}
			dir, err := parseDirection(args[1])
			if err != nil {
				return err
			}
			if percent <= 0 || percent >= 100 {
				return fmt.Errorf("--percent must be between 0 and 100")
			}
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			tag := c.NextTag()
			m := &persist.Split{Tag: tag, Pane: pane, Dir: dir, Share: uint16(percent * 100)}
			if len(args) == 3 {
				m.Command = args[2]
			}
			if err := c.Send(0, m); err != nil {
				return err
			}
			created, err := c.AwaitCreated(tag)
			if err != nil {
				return err
			}
			fmt.Println(created.Pane)
			return nil
		},
	}
	cmd.Flags().Float64VarP(&percent, "percent", "p", 50, "how much of the pane's space the new one takes")
	return cmd
}

func attachCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "attach <pane>",
		Short: "Show a pane in this console, taking its workspace (Ctrl+] detaches)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, err := parseID(args[0])
			if err != nil {
				return err
			}
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			l, err := c.List()
			if err != nil {
				return err
			}
			ws := workspaceOf(l, pane)
			if ws == 0 {
				return fmt.Errorf("no pane %d", pane)
			}
			var size persist.Size
			if cols, rows, err := consoleSize(); err == nil {
				size.Cols, size.Rows = cols, rows
			}
			tag := c.NextTag()
			// A console has no pixel size: its grid, in one-pixel cells.
			area := persist.Area{Width: uint32(size.Cols), Height: uint32(size.Rows), CellW: 1, CellH: 1}
			if err := c.Send(0, &persist.WorkspaceAttach{Tag: tag, WS: ws, Area: area}); err != nil {
				return err
			}
			a, err := c.Await(tag, false)
			if err != nil {
				return err
			}
			p := a.Panes[pane]
			if p == nil {
				return fmt.Errorf("no snapshot for pane %d", pane)
			}
			// The pane may share its tab; here it has the whole console.
			if size.Cols != 0 {
				c.Send(pane, &persist.Resize{Size: size})
			}
			return attach(c, ws, pane, p)
		},
	}
}

func peekCommand() *cobra.Command {
	var asVT bool
	cmd := &cobra.Command{
		Use:   "peek <pane>",
		Short: "Print a pane's screen and scrollback, without taking it",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, err := parseID(args[0])
			if err != nil {
				return err
			}
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			p, err := c.Peek(pane)
			if err != nil {
				return err
			}
			ctx := context.Background()
			rt, err := vt.NewRuntime(ctx, nil)
			if err != nil {
				return err
			}
			defer rt.Close(ctx)
			t, err := rt.Decode(p.Snapshot)
			if err != nil {
				return err
			}
			defer t.Close()
			if asVT {
				b, err := t.VT()
				if err != nil {
					return err
				}
				_, err = os.Stdout.Write(b)
				return err
			}
			s, err := t.Text()
			if err != nil {
				return err
			}
			fmt.Println(s)
			return nil
		},
	}
	cmd.Flags().BoolVar(&asVT, "vt", false, "print the VT that redraws it rather than plain text")
	return cmd
}

func killCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "kill <pane>...",
		Short: "End panes",
		Args:  cobra.MinimumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			for _, arg := range args {
				id, err := parseID(arg)
				if err != nil {
					return err
				}
				if err := c.Send(id, &persist.PaneKill{}); err != nil {
					return err
				}
			}
			// List after the kills so they're read before we hang up.
			_, err = c.List()
			return err
		},
	}
}

// send sends one message that has no reply, and waits until the daemon
// has read it.
func send(m persist.Message) error {
	c, err := connect(false)
	if err != nil {
		return err
	}
	defer c.Close()
	if err := c.Send(0, m); err != nil {
		return err
	}
	// Errors come back before the list, which the daemon answers after.
	if err := c.Send(0, &persist.List{}); err != nil {
		return err
	}
	for {
		_, reply, err := c.Recv()
		if err != nil {
			return err
		}
		switch reply := reply.(type) {
		case *persist.Error:
			return errors.New(reply.Message)
		case *persist.Workspaces:
			return nil
		}
	}
}

// newWorkspace creates a workspace, owned by c until it hangs up.
func newWorkspace(c *persist.Client, name string) (uint32, error) {
	tag := c.NextTag()
	if err := c.Send(0, &persist.WorkspaceNew{Tag: tag, Name: name}); err != nil {
		return 0, err
	}
	created, err := c.AwaitCreated(tag)
	if err != nil {
		return 0, err
	}
	return created.WS, nil
}

// tabNew starts a tab with a pane per command, sharing it equally along
// dir: each split takes its share of what the last pane has left.
func tabNew(c *persist.Client, ws uint32, commands []string, dir persist.Direction) (*persist.Created, error) {
	tag := c.NextTag()
	if err := c.Send(0, &persist.TabNew{Tag: tag, WS: ws, Command: commands[0]}); err != nil {
		return nil, err
	}
	first, err := c.AwaitCreated(tag)
	if err != nil {
		return nil, err
	}
	last := first.Pane
	n := len(commands)
	for k := 1; k < n; k++ {
		tag := c.NextTag()
		share := uint16(persist.Whole * (n - k) / (n - k + 1))
		if err := c.Send(0, &persist.Split{Tag: tag, Pane: last, Dir: dir, Share: share, Command: commands[k]}); err != nil {
			return nil, err
		}
		created, err := c.AwaitCreated(tag)
		if err != nil {
			return nil, err
		}
		last = created.Pane
	}
	return first, nil
}

func workspaceOf(l *persist.Workspaces, pane uint32) uint32 {
	for _, ws := range l.Workspaces {
		for _, t := range ws.Tabs {
			for _, id := range t.Tree.Panes() {
				if id == pane {
					return ws.ID
				}
			}
		}
	}
	return 0
}

func parseID(s string) (uint32, error) {
	id, err := strconv.ParseUint(s, 10, 32)
	if err != nil || id == 0 {
		return 0, fmt.Errorf("bad id %q", s)
	}
	return uint32(id), nil
}

func parseDirection(s string) (persist.Direction, error) {
	switch s {
	case "right":
		return persist.Right, nil
	case "down":
		return persist.Down, nil
	case "left":
		return persist.Left, nil
	case "up":
		return persist.Up, nil
	}
	return 0, fmt.Errorf("direction is right, down, left, or up, not %q", s)
}

// connect dials the daemon and says hello. If start is set and none is
// running, it starts one.
func connect(start bool) (*persist.Client, error) {
	conn, err := dial(start)
	if err != nil {
		return nil, err
	}
	return persist.NewClient(conn)
}

// dial connects to the daemon. If start is set and none is running, it
// starts one with serve's extra arguments.
func dial(start bool, serve ...string) (net.Conn, error) {
	name, err := persist.Address()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	conn, err := persist.Dial(ctx, name)
	cancel()
	if err != nil && start && isNotRunning(err) {
		if err := startDaemon(serve...); err != nil {
			return nil, fmt.Errorf("starting slimed: %w", err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			conn, err = persist.Dial(ctx, name)
			cancel()
			if err == nil || !isNotRunning(err) || time.Now().After(deadline) {
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	if err != nil {
		if isNotRunning(err) {
			return nil, fmt.Errorf("slimed isn't running")
		}
		return nil, err
	}
	return conn, nil
}
