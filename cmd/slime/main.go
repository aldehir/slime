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

	"github.com/aldehir/slime/internal/config"
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
		if errors.Is(err, errScriptFailed) || errors.Is(err, errConfigFailed) {
			os.Exit(1)
		}
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
		Long:          rootDoc,
		Version:       fmt.Sprintf("protocol %d", daemon.Version),
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	root.PersistentFlags().BoolVar(&jsonOut, "json", false, "print results as JSON, as the daemon replies")
	root.AddCommand(serveCommand(), stopCommand(), connectCommand(), lsCommand(), wsCommand(), tabCommand(),
		paneCommand(), doCommand(), actionsCommand(), scriptsCommand(), configCommand(), callCommand(), skillCommand())
	root.AddCommand(hostCommands()...)
	root.AddCommand(topicCommands()...)
	root.SetHelpCommand(helpCommand(root))
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
	srv, err := daemon.NewServer(rt, daemon.Options{Log: logger, Idle: idle, Hosts: hosts, Config: config.Path()})
	if err != nil {
		return err
	}
	logger.Info("serving", "pipe", name, "pid", os.Getpid(), "config", config.Path())
	return srv.Serve(l)
}

func stopCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "stop [instance]",
		Short: "End the daemon of an instance, and every pane it owns",
		Long: "Stops the daemon of an instance: the one named, or SLIME_INSTANCE's. Every\n" +
			"pane's program is killed, and windows showing them see slime hang up. The\n" +
			"daemon in ordinary use has no instance name and isn't stopped this way: it\n" +
			"exits by itself once nothing is left in it (slime serve --idle).",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			// The instance picks the pipe through the same variable the
			// daemon and its panes carry (slime help env).
			if len(args) == 1 {
				os.Setenv("SLIME_INSTANCE", args[0])
			} else if os.Getenv("SLIME_INSTANCE") == "" {
				return errors.New("no instance: name one, or set SLIME_INSTANCE")
			}
			return call(rpc.DaemonStop, nil, nil)
		},
	}
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
			panes := map[rpc.PaneID]rpc.PaneDesc{}
			for _, p := range l.Panes {
				panes[p.ID] = p
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			for _, ws := range l.Workspaces {
				fmt.Fprintf(w, "workspace %d\t%s\t%s\n", ws.ID, ws.Name, workspaceState(ws))
				for _, t := range ws.Tabs {
					fmt.Fprintf(w, "  tab %s%s\t%s\t%s\n", t.ID, mark(t.ID == ws.ActiveTab), t.Name, layoutString(t.Tree))
					for _, id := range t.Tree.Panes() {
						p := panes[id]
						if p.Kind == rpc.PaneBrowser {
							fmt.Fprintf(w, "    pane %s%s\tbrowser\t\t%s\n", id, mark(id == t.Focus), browserString(p))
							continue
						}
						title := p.Title
						if title == "" {
							title = p.Command
						}
						fmt.Fprintf(w, "    pane %s%s\t%dx%d\tpid %d\t%s\n", id, mark(id == t.Focus), p.Cols, p.Rows, p.PID, title)
					}
				}
			}
			return w.Flush()
		},
	}
}

// browserString shows a browser pane by its url, after its title if
// it has one.
func browserString(p rpc.PaneDesc) string {
	if p.Title == "" {
		return p.URL
	}
	return p.Title + "  " + p.URL
}

// workspaceState says whether a workspace is shown, by how many, or
// since when it isn't.
func workspaceState(ws rpc.WorkspaceDesc) string {
	if ws.Attached {
		if ws.Viewers > 1 {
			return fmt.Sprintf("attached (%d viewers)", ws.Viewers)
		}
		return "attached"
	}
	state := "detached"
	if ws.DetachedAt != 0 {
		state += " " + time.UnixMilli(ws.DetachedAt).Format("Jan 2 15:04")
	}
	return state
}

// mark flags the active tab and the focused pane in a listing.
func mark(on bool) string {
	if on {
		return "*"
	}
	return ""
}

// layoutString shows a tree compactly: row(60% 1.1.3, 40% col(50% 1.1.4,
// 50% 1.1.5)).
func layoutString(n *rpc.Node) string {
	if n == nil {
		return ""
	}
	if n.IsLeaf() {
		return n.Pane.String()
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
	var attach uint32
	ws := &cobra.Command{Use: "ws", Short: "Create, rename, kill, and describe workspaces"}
	newWs := &cobra.Command{
		Use:   "new [name]",
		Short: "Create a workspace with a tab running the shell, and print its id",
		Long: "Creates a workspace with a tab running the shell. Inside a pane, the windows\n" +
			"on the pane's workspace open it too ($SLIME_WORKSPACE); --attach names another\n" +
			"workspace's windows, and 0 none, leaving it detached for the next window.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var w rpc.Workspace
			// Hanging up detaches it, but an empty workspace would go:
			// give it a shell.
			p := rpc.WorkspaceNewParams{Name: strings.Join(args, ""), Tabs: []*rpc.Layout{{Pane: &rpc.PaneSpec{}}}, Attach: attach}
			if err := call(rpc.WorkspaceNew, p, &w); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(w)
			}
			fmt.Println(w.ID)
			return nil
		},
	}
	newWs.Flags().Uint32Var(&attach, "attach", envWorkspace(), "open it in the windows on this workspace (default $SLIME_WORKSPACE; 0 for none)")
	ws.AddCommand(newWs, &cobra.Command{
		Use:   "focus <tab|pane>",
		Short: "Show a tab in every window on its workspace, or a pane's tab with the pane focused",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var p rpc.WorkspaceFocusParams
			if strings.Count(args[0], ".") == 1 {
				tab, err := rpc.ParseTabID(args[0])
				if err != nil {
					return err
				}
				p.Tab = tab
			} else {
				pane, err := rpc.ParsePaneID(args[0])
				if err != nil {
					return err
				}
				p.Pane = pane
			}
			return call(rpc.WorkspaceFocus, p, nil)
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
			fmt.Printf("workspace %d\t%s\t%s\n", d.ID, d.Name, workspaceState(d))
			for _, t := range d.Tabs {
				fmt.Printf("  tab %s%s\t%s\t%s\n", t.ID, mark(t.ID == d.ActiveTab), t.Name, layoutString(t.Tree))
			}
			return nil
		},
	})
	return ws
}

func tabCommand() *cobra.Command {
	var (
		wsID    uint32
		name    string
		split   string
		browser string
	)
	newTab := &cobra.Command{
		Use:   "new [command]...",
		Short: "Start a tab; with several commands, one pane each, side by side or stacked",
		Long: "Starts a tab in a workspace: the one given, else the pane's own inside a\n" +
			"pane ($SLIME_WORKSPACE), else the most recently detached, else a new one. Each\n" +
			"command (CreateProcessW syntax; empty for the shell) gets a pane, sharing the\n" +
			"tab equally along --split. With --browser, one browser pane showing the url\n" +
			"instead, and no command.",
		RunE: func(cmd *cobra.Command, args []string) error {
			if cmd.Flags().Changed("browser") && len(args) > 0 {
				return fmt.Errorf("--browser takes no command")
			}
			var axis rpc.Axis
			switch split {
			case "right", "h":
				axis = rpc.Row
			case "down", "v":
				axis = rpc.Column
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
			layout := layoutOf(args, axis)
			if cmd.Flags().Changed("browser") {
				layout = &rpc.Layout{Pane: &rpc.PaneSpec{Kind: rpc.PaneBrowser, URL: browser}}
			}
			var created rpc.Created
			if err := c.Call(rpc.TabNew, rpc.TabNewParams{Workspace: ws, Name: name, Layout: layout}, &created); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(created)
			}
			fmt.Println(created.Pane.TabID())
			return nil
		},
	}
	newTab.Flags().Uint32VarP(&wsID, "workspace", "w", envWorkspace(), "workspace to start it in (default $SLIME_WORKSPACE)")
	newTab.Flags().StringVarP(&name, "name", "n", "", "name the tab")
	newTab.Flags().StringVar(&split, "split", "right", "how several commands share the tab: right (side by side) or down (stacked)")
	newTab.Flags().StringVar(&browser, "browser", "", "a browser pane showing this url, rather than a command's")

	tab := &cobra.Command{Use: "tab", Short: "Start, rename, close, and describe tabs"}
	tab.AddCommand(newTab, &cobra.Command{
		Use:   "rename <tab> <name>",
		Short: "Rename a tab",
		Args:  cobra.ExactArgs(2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := rpc.ParseTabID(args[0])
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
			id, err := rpc.ParseTabID(args[0])
			if err != nil {
				return err
			}
			return call(rpc.TabClose, rpc.TabParams{ID: id}, nil)
		},
	}, &cobra.Command{
		Use:   "info <tab>",
		Short: "Describe a tab: its layout and focus",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := rpc.ParseTabID(args[0])
			if err != nil {
				return err
			}
			var t rpc.Tab
			if err := call(rpc.TabInfo, rpc.TabParams{ID: id}, &t); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(t)
			}
			fmt.Printf("tab %s\t%s\t%s\n", t.ID, t.Name, layoutString(t.Tree))
			return nil
		},
	})
	return tab
}

func paneCommand() *cobra.Command {
	var (
		percent float64
		asVT    bool
		browser string
	)
	split := &cobra.Command{
		Use:   "split [pane] right|down|left|up [command]",
		Short: "Start a pane beside another (this one, by default), and print its id",
		Long: "Starts a pane on a side of another, running command (empty for the shell),\n" +
			"taking --percent of its space; with --browser, a browser pane showing the url,\n" +
			"which a window's browser fills, and no command. Without a pane, beside the one\n" +
			"this console runs in ($SLIME_PANE).",
		Args: cobra.RangeArgs(1, 3),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, args, err := paneArg(args)
			if err != nil {
				return err
			}
			if len(args) == 0 || len(args) > 2 {
				return fmt.Errorf("a direction, then at most a command: %s", cmd.UseLine())
			}
			var dir rpc.Direction
			if err := dir.UnmarshalText([]byte(args[0])); err != nil {
				return err
			}
			if percent <= 0 || percent >= 100 {
				return fmt.Errorf("--percent must be between 0 and 100")
			}
			p := rpc.PaneSplitParams{Pane: pane, Direction: dir, Share: uint16(percent * 100)}
			if len(args) == 2 {
				p.Command = args[1]
			}
			if cmd.Flags().Changed("browser") {
				if p.Command != "" {
					return fmt.Errorf("--browser takes no command")
				}
				p.Kind, p.URL = rpc.PaneBrowser, browser
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
	split.Flags().StringVar(&browser, "browser", "", "a browser pane showing this url, rather than a command's")
	navigate := &cobra.Command{
		Use:   "navigate [pane] <url>",
		Short: "Send a browser pane (this one, by default) to a url, in every window showing it",
		Long: "Sends a browser pane to url, in every window showing it. A first argument\n" +
			"that is a pane id (workspace.tab.pane) is the pane; without one, this console's\n" +
			"($SLIME_PANE).",
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			// paneArg's rule, except that a url can have two dots too
			// (www.example.com): only an id that parses is the pane.
			id, err := rpc.ParsePaneID(args[0])
			if err == nil {
				args = args[1:]
			} else if len(args) == 2 {
				return err
			} else if id = envPane(); id.IsZero() {
				return errNoPane
			}
			if len(args) != 1 {
				return fmt.Errorf("a url: %s", cmd.UseLine())
			}
			return call(rpc.PaneNavigate, rpc.PaneNavigateParams{Pane: id, URL: args[0]}, nil)
		},
	}
	move := &cobra.Command{
		Use:   "move [pane] <tab|new> [right|down|left|up]",
		Short: "Move a pane along a side of another tab, or into a new tab of its own, and print its new id",
		Long: "Moves a pane (this console's, without one) into tab along the side given,\n" +
			"or into a new tab of its own. The pane gets a new id there, printed; its old\n" +
			"ids keep finding it.",
		Args: cobra.RangeArgs(1, 3),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, args, err := paneArg(args)
			if err != nil {
				return err
			}
			if len(args) == 0 || len(args) > 2 {
				return fmt.Errorf("a tab or new, then at most a side: %s", cmd.UseLine())
			}
			p := rpc.PaneMoveParams{Pane: pane}
			if args[0] != "new" {
				if p.Tab, err = rpc.ParseTabID(args[0]); err != nil {
					return err
				}
			}
			if len(args) == 2 {
				if err := p.Side.UnmarshalText([]byte(args[1])); err != nil {
					return err
				}
			}
			var moved rpc.Created
			if err := call(rpc.PaneMove, p, &moved); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(moved)
			}
			fmt.Println(moved.Pane)
			return nil
		},
	}
	var zoom, unzoom bool
	focus := &cobra.Command{
		Use:   "focus [pane]",
		Short: "Give a pane (this one, by default) the input in every window on its workspace, showing its tab",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, err := paneOnly(args)
			if err != nil {
				return err
			}
			if zoom && unzoom {
				return fmt.Errorf("--zoom and --unzoom are one or the other")
			}
			p := rpc.WorkspaceFocusParams{Pane: pane}
			if zoom {
				p.Zoomed = &pane
			}
			if unzoom {
				p.Zoomed = new(rpc.PaneID)
			}
			return call(rpc.WorkspaceFocus, p, nil)
		},
	}
	focus.Flags().BoolVar(&zoom, "zoom", false, "zoom it to fill its tab too")
	focus.Flags().BoolVar(&unzoom, "unzoom", false, "show every pane of its tab again")
	text := &cobra.Command{
		Use:   "text [pane]",
		Short: "Print a pane's screen and scrollback (this pane's, by default), without taking it",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			pane, err := paneOnly(args)
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

	pane := &cobra.Command{Use: "pane", Short: "Split, move, focus, kill, write to, read, and navigate panes"}
	pane.AddCommand(split, move, focus, text, navigate, &cobra.Command{
		Use:   "kill [pane]...",
		Short: "End panes (this one, with none given)",
		Args:  cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				self, err := paneOnly(nil)
				if err != nil {
					return err
				}
				args = []string{self.String()}
			}
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			for _, arg := range args {
				id, err := rpc.ParsePaneID(arg)
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
		Use:   "write [pane] <text>",
		Short: "Send text to a pane's program (this one's, by default) as if typed",
		Long: "Sends text to the pane's program as typed: no newline is added, and a\n" +
			"carriage return presses enter (\"\\r\" in most shells' double quotes, `r in\n" +
			"PowerShell's). Without a pane, the one this console runs in.",
		Args: cobra.RangeArgs(1, 2),
		RunE: func(cmd *cobra.Command, args []string) error {
			id := envPane()
			if len(args) == 2 {
				var err error
				if id, err = rpc.ParsePaneID(args[0]); err != nil {
					return err
				}
				args = args[1:]
			} else if id.IsZero() {
				return errNoPane
			}
			return call(rpc.PaneWrite, rpc.PaneWriteParams{ID: id, Text: args[0]}, nil)
		},
	}, &cobra.Command{
		Use:   "info [pane]",
		Short: "Describe a pane (this one, by default): its command, title, size, and program status",
		Long: "Describes a pane. A pane that moved tabs is found under the id it had too,\n" +
			"and described under the id it has now. Without a pane, the one this console\n" +
			"runs in ($SLIME_PANE).",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := paneOnly(args)
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
			if d.Kind == rpc.PaneBrowser {
				fmt.Fprintf(w, "pane\t%s\nkind\t%s\nurl\t%s\ntitle\t%s\ncreated\t%s\n",
					d.ID, d.Kind, d.URL, d.Title, time.UnixMilli(d.Created).Format(time.RFC3339))
				return w.Flush()
			}
			fmt.Fprintf(w, "pane\t%s\ncommand\t%s\ntitle\t%s\npwd\t%s\nsize\t%dx%d\npid\t%d\ncreated\t%s\n",
				d.ID, d.Command, d.Title, d.Pwd, d.Cols, d.Rows, d.PID, time.UnixMilli(d.Created).Format(time.RFC3339))
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
		Long: "Calls a method of the control plane with params given as JSON, and prints the\n" +
			"result; slime help methods lists them. Errors print their code and message.",
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

// layoutOf is a tab of one pane per command, sharing it equally along
// axis.
func layoutOf(commands []string, axis rpc.Axis) *rpc.Layout {
	if len(commands) == 1 {
		return &rpc.Layout{Pane: &rpc.PaneSpec{Command: commands[0]}}
	}
	l := &rpc.Layout{Axis: axis}
	for _, command := range commands {
		l.Children = append(l.Children, rpc.LayoutChild{Node: &rpc.Layout{Pane: &rpc.PaneSpec{Command: command}}})
	}
	return l
}

// parseID reads a workspace or script id: one number. Tab and pane
// ids are paths (rpc.ParseTabID, rpc.ParsePaneID).
func parseID(s string) (uint32, error) {
	id, err := strconv.ParseUint(s, 10, 32)
	if err != nil || id == 0 {
		return 0, fmt.Errorf("bad id %q", s)
	}
	return uint32(id), nil
}

// errNoPane: a pane command run outside a pane, without a pane.
var errNoPane = errors.New("which pane? none given, and this console isn't in a slime pane (no SLIME_PANE)")

// paneArg is the pane a pane command names first, when it does, and the
// arguments after it: a pane id is w.t.p, which none of the others look
// like. Without one, the pane is this console's ($SLIME_PANE), or
// errNoPane.
func paneArg(args []string) (rpc.PaneID, []string, error) {
	if len(args) > 0 && strings.Count(args[0], ".") == 2 {
		id, err := rpc.ParsePaneID(args[0])
		return id, args[1:], err
	}
	id := envPane()
	if id.IsZero() {
		return id, nil, errNoPane
	}
	return id, args, nil
}

// paneOnly is paneArg for a command that takes a pane and nothing else,
// so that an argument that isn't a pane id is an error rather than
// ignored.
func paneOnly(args []string) (rpc.PaneID, error) {
	id, rest, err := paneArg(args)
	if err == nil && len(rest) > 0 {
		return id, fmt.Errorf("bad id: a pane id is workspace.tab.pane, not %q", rest[0])
	}
	return id, err
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
