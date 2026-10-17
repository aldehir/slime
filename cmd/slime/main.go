// slime keeps terminals alive while no window shows them: it owns
// each pane's pty and terminal state, arranged in tabs and workspaces,
// and a window attaches a workspace to draw the frames of its panes.
// slime-gui is the window; the other commands here script workspaces and
// look at them from a console, over the same control plane
// (internal/rpc) the window uses.
package main

import (
	"context"
	"encoding/json"
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

	"github.com/aldehir/slime/internal/daemon"
	"github.com/aldehir/slime/internal/pty"
	"github.com/aldehir/slime/internal/rpc"
	"github.com/aldehir/slime/internal/vt"
)

// jsonOut prints each command's result as the daemon sent it (--json).
var jsonOut bool

func main() {
	log.SetFlags(0)
	log.SetPrefix("slime: ")
	if err := newCommand().Execute(); err != nil {
		var rerr *rpc.Error
		if errors.As(err, &rerr) {
			log.Fatalf("%s (code %d)", rerr.Message, rerr.Code)
		}
		log.Fatal(err)
	}
}

func newCommand() *cobra.Command {
	root := &cobra.Command{
		Use:           "slime",
		Short:         "Keep terminals alive between attaches",
		Version:       fmt.Sprintf("protocol %d", daemon.Version),
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	root.PersistentFlags().BoolVar(&jsonOut, "json", false, "print results as JSON, as the daemon replies")
	root.AddCommand(serveCommand(), connectCommand(), lsCommand(), wsCommand(), tabCommand(),
		paneCommand(), callCommand())
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
	cmd.Flags().StringVar(&conptyDir, "conpty", "", "directory holding conpty.dll (default: next to slime.exe, else the system's)")
	cmd.Flags().StringVar(&remoteDir, "remote", "", "directory holding the builds of slime for hosts and their manifest (default: remote/ next to slime.exe)")
	cmd.Flags().StringVar(&termName, "term", "", "TERM for panes on Unix (default xterm-256color)")
	cmd.Flags().DurationVar(&idle, "idle", 10*time.Second, "exit after this long with no workspaces and no clients (0 never)")
	cmd.Flags().StringVar(&logPath, "log", "", "append logs to this file instead of stderr")
	cmd.Flags().BoolVarP(&verbose, "verbose", "v", false, "log libghostty-vt's debug output too")
	return cmd
}

func serve(logger *slog.Logger, idle time.Duration, hosts daemon.HostOptions) error {
	name, err := daemon.Address()
	if err != nil {
		return err
	}
	l, err := daemon.Listen(name)
	if err != nil {
		return fmt.Errorf("listening on %s (is slime already running?): %w", name, err)
	}
	ctx := context.Background()
	rt, err := vt.NewRuntime(ctx, logger)
	if err != nil {
		return err
	}
	defer rt.Close(ctx)
	srv, err := daemon.NewServer(rt, daemon.Options{Log: logger, Idle: idle, Hosts: hosts})
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
			"that can't reach the socket itself: the local slime runs it over an SSH exec channel.",
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
			var l rpc.WorkspaceListResult
			if err := c.Call(rpc.WorkspaceList, nil, &l); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(l)
			}
			panes := map[uint32]rpc.PaneDesc{}
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
func layoutString(n *rpc.Node) string {
	if n == nil {
		return ""
	}
	if n.IsLeaf() {
		return strconv.FormatUint(uint64(n.Pane), 10)
	}
	var b strings.Builder
	if n.Axis == rpc.Row {
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
	ws := &cobra.Command{Use: "ws", Short: "Create, rename, kill, and describe workspaces"}
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
			var w rpc.Workspace
			if err := c.Call(rpc.WorkspaceNew, rpc.WorkspaceNewParams{Name: strings.Join(args, "")}, &w); err != nil {
				return err
			}
			// Hanging up detaches it, but an empty workspace would go:
			// give it a shell.
			created, err := tabNew(c, w.ID, []string{""}, rpc.Right)
			if err != nil {
				return err
			}
			if jsonOut {
				return printJSON(created)
			}
			fmt.Println(w.ID)
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
			return call(rpc.WorkspaceRename, rpc.WorkspaceRenameParams{ID: id, Name: args[1]}, nil)
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
			return call(rpc.WorkspaceKill, rpc.WorkspaceParams{ID: id}, nil)
		},
	}, &cobra.Command{
		Use:   "info <workspace>",
		Short: "Describe a workspace",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			var d rpc.WorkspaceDesc
			if err := call(rpc.WorkspaceInfo, rpc.WorkspaceParams{ID: id}, &d); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(d)
			}
			state := "attached"
			if !d.Attached {
				state = "detached"
			}
			fmt.Printf("workspace %d\t%s\t%s\n", d.ID, d.Name, state)
			for _, t := range d.Tabs {
				fmt.Printf("  tab %d\t%s\t%s\n", t.ID, t.Name, layoutString(t.Tree))
			}
			return nil
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
			dir := rpc.Right
			switch split {
			case "right", "h":
			case "down", "v":
				dir = rpc.Down
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
				var l rpc.WorkspaceListResult
				if err := c.Call(rpc.WorkspaceList, nil, &l); err != nil {
					return err
				}
				if w := daemon.MostRecentDetached(&l); w != nil {
					ws = w.ID
				} else {
					var w rpc.Workspace
					if err := c.Call(rpc.WorkspaceNew, rpc.WorkspaceNewParams{}, &w); err != nil {
						return err
					}
					ws = w.ID
				}
			}
			created, err := tabNew(c, ws, args, dir)
			if err != nil {
				return err
			}
			if jsonOut {
				return printJSON(created)
			}
			fmt.Println(created.Tab)
			return nil
		},
	}
	newTab.Flags().Uint32VarP(&wsID, "workspace", "w", 0, "workspace to start it in")
	newTab.Flags().StringVar(&split, "split", "right", "how several commands share the tab: right (side by side) or down (stacked)")

	tab := &cobra.Command{Use: "tab", Short: "Start, rename, close, and describe tabs"}
	tab.AddCommand(newTab, &cobra.Command{
		Use:   "rename <tab> <name>",
		Short: "Rename a tab",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			return call(rpc.TabRename, rpc.TabRenameParams{ID: id, Name: args[1]}, nil)
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
			return call(rpc.TabClose, rpc.TabParams{ID: id}, nil)
		},
	}, &cobra.Command{
		Use:   "info <tab>",
		Short: "Describe a tab: its workspace and layout",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			var t rpc.TabInfoResult
			if err := call(rpc.TabInfo, rpc.TabParams{ID: id}, &t); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(t)
			}
			fmt.Printf("tab %d\tworkspace %d\t%s\t%s\n", t.ID, t.Workspace, t.Name, layoutString(t.Tree))
			return nil
		},
	})
	return tab
}

func paneCommand() *cobra.Command {
	var (
		percent float64
		asVT    bool
	)
	split := &cobra.Command{
		Use:   "split <pane> right|down|left|up [command]",
		Short: "Start a pane beside another, and print its id",
		Args:  cobra.RangeArgs(2, 3),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, err := parseID(args[0])
			if err != nil {
				return err
			}
			var dir rpc.Direction
			if err := dir.UnmarshalText([]byte(args[1])); err != nil {
				return err
			}
			if percent <= 0 || percent >= 100 {
				return fmt.Errorf("--percent must be between 0 and 100")
			}
			p := rpc.PaneSplitParams{Pane: pane, Direction: dir, Share: uint16(percent * 100)}
			if len(args) == 3 {
				p.Command = args[2]
			}
			var created rpc.Created
			if err := call(rpc.PaneSplit, p, &created); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(created)
			}
			fmt.Println(created.Pane)
			return nil
		},
	}
	split.Flags().Float64VarP(&percent, "percent", "p", 50, "how much of the pane's space the new one takes")
	text := &cobra.Command{
		Use:   "text <pane>",
		Short: "Print a pane's screen and scrollback, without taking it",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, err := parseID(args[0])
			if err != nil {
				return err
			}
			var r rpc.PaneTextResult
			if err := call(rpc.PaneText, rpc.PaneTextParams{ID: pane, VT: asVT}, &r); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(r)
			}
			if asVT {
				_, err = os.Stdout.WriteString(r.Text)
				return err
			}
			fmt.Println(r.Text)
			return nil
		},
	}
	text.Flags().BoolVar(&asVT, "vt", false, "print the VT that redraws it rather than plain text")

	pane := &cobra.Command{Use: "pane", Short: "Split, kill, write to, and read panes"}
	pane.AddCommand(split, text, &cobra.Command{
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
				if err := c.Call(rpc.PaneKill, rpc.PaneParams{ID: id}, nil); err != nil {
					return err
				}
			}
			return nil
		},
	}, &cobra.Command{
		Use:   "write <pane> <text>",
		Short: "Send text to a pane's program as if typed (no newline is added)",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			return call(rpc.PaneWrite, rpc.PaneWriteParams{ID: id, Text: args[1]}, nil)
		},
	}, &cobra.Command{
		Use:   "info <pane>",
		Short: "Describe a pane: its tab, command, title, size, and program status",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			var d rpc.PaneDesc
			if err := call(rpc.PaneInfo, rpc.PaneParams{ID: id}, &d); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(d)
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			fmt.Fprintf(w, "pane\t%d\nworkspace\t%d\ntab\t%d\ncommand\t%s\ntitle\t%s\npwd\t%s\nsize\t%dx%d\npid\t%d\ncreated\t%s\n",
				d.ID, d.Workspace, d.Tab, d.Command, d.Title, d.Pwd, d.Cols, d.Rows, d.PID, time.UnixMilli(d.Created).Format(time.RFC3339))
			for _, r := range d.Status {
				fmt.Fprintf(w, "status\t%q state %d progress %d\n", r.ID, r.State, r.Progress)
			}
			return w.Flush()
		},
	})
	return pane
}

func callCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "call <method> [params-json]",
		Short: "Call any method on the daemon and print the raw reply",
		Long: "Calls a method of the control plane (internal/rpc) with params given as JSON,\n" +
			"and prints the result. Errors print their code and message.",
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			var params json.RawMessage
			if len(args) == 2 {
				if !json.Valid([]byte(args[1])) {
					return fmt.Errorf("params aren't valid JSON: %s", args[1])
				}
				params = json.RawMessage(args[1])
			}
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			var result json.RawMessage
			if err := c.Call(args[0], params, &result); err != nil {
				return err
			}
			return printJSON(result)
		},
	}
}

// printJSON prints v indented.
func printJSON(v any) error {
	b, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	fmt.Println(string(b))
	return nil
}

// call connects, calls one method, and hangs up.
func call(method string, params, result any) error {
	c, err := connect(false)
	if err != nil {
		return err
	}
	defer c.Close()
	return c.Call(method, params, result)
}

// tabNew starts a tab with a pane per command, sharing it equally along
// dir: each split takes its share of what the last pane has left.
func tabNew(c *daemon.Client, ws uint32, commands []string, dir rpc.Direction) (*rpc.Created, error) {
	var first rpc.Created
	if err := c.Call(rpc.TabNew, rpc.TabNewParams{Workspace: ws, Command: commands[0]}, &first); err != nil {
		return nil, err
	}
	last := first.Pane
	n := len(commands)
	for k := 1; k < n; k++ {
		share := uint16(rpc.Whole * (n - k) / (n - k + 1))
		var created rpc.Created
		if err := c.Call(rpc.PaneSplit, rpc.PaneSplitParams{Pane: last, Direction: dir, Share: share, Command: commands[k]}, &created); err != nil {
			return nil, err
		}
		last = created.Pane
	}
	return &first, nil
}

func parseID(s string) (uint32, error) {
	id, err := strconv.ParseUint(s, 10, 32)
	if err != nil || id == 0 {
		return 0, fmt.Errorf("bad id %q", s)
	}
	return uint32(id), nil
}

// connect dials the daemon and says hello. If start is set and none is
// running, it starts one.
func connect(start bool) (*daemon.Client, error) {
	conn, err := dial(start)
	if err != nil {
		return nil, err
	}
	return daemon.NewClient(conn)
}

// dial connects to the daemon. If start is set and none is running, it
// starts one with serve's extra arguments.
func dial(start bool, serve ...string) (net.Conn, error) {
	name, err := daemon.Address()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	conn, err := daemon.Dial(ctx, name)
	cancel()
	if err != nil && start && isNotRunning(err) {
		if err := startDaemon(serve...); err != nil {
			return nil, fmt.Errorf("starting slime: %w", err)
		}
		deadline := time.Now().Add(5 * time.Second)
		for {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			conn, err = daemon.Dial(ctx, name)
			cancel()
			if err == nil || !isNotRunning(err) || time.Now().After(deadline) {
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
	if err != nil {
		if isNotRunning(err) {
			return nil, fmt.Errorf("slime isn't running")
		}
		return nil, err
	}
	return conn, nil
}
