// slimed keeps terminal sessions alive while no client is attached:
// it owns their ptys and each one's terminal state, and a client
// attaches with a snapshot of the terminal followed by live output.
// slime is the client; the other commands here manage sessions and try
// them out from a console.
package main

import (
	"context"
	"fmt"
	"log"
	"log/slog"
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
		Short:         "Keep terminal sessions alive between attaches",
		Version:       fmt.Sprintf("protocol %d", persist.Version),
		SilenceErrors: true,
		SilenceUsage:  true,
	}
	root.AddCommand(serveCommand(), listCommand(), newSessionCommand(), attachCommand(), peekCommand(), killCommand())
	return root
}

func serveCommand() *cobra.Command {
	var (
		idle      time.Duration
		logPath   string
		verbose   bool
		conptyDir string
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
			return serve(logger, idle)
		},
	}
	cmd.Flags().StringVar(&conptyDir, "conpty", "", "directory holding conpty.dll (default: next to slimed.exe, else the system's)")
	cmd.Flags().DurationVar(&idle, "idle", 10*time.Second, "exit after this long with no sessions and no clients (0 never)")
	cmd.Flags().StringVar(&logPath, "log", "", "append logs to this file instead of stderr")
	cmd.Flags().BoolVarP(&verbose, "verbose", "v", false, "log libghostty-vt's debug output too")
	return cmd
}

func serve(logger *slog.Logger, idle time.Duration) error {
	name, err := persist.PipeName()
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
	srv, err := persist.NewServer(rt, persist.Options{Log: logger, Idle: idle})
	if err != nil {
		return err
	}
	logger.Info("serving", "pipe", name, "pid", os.Getpid())
	return srv.Serve(l)
}

func listCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "list",
		Short: "List sessions",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			sessions, err := c.List()
			if err != nil {
				return err
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			fmt.Fprintln(w, "ID\tSIZE\tATTACHED\tSTARTED\tPID\tTITLE")
			for _, s := range sessions {
				title := s.Title
				if title == "" {
					title = s.Command
				}
				fmt.Fprintf(w, "%d\t%dx%d\t%v\t%s\t%d\t%s\n", s.ID, s.Cols, s.Rows, s.Attached,
					time.UnixMilli(s.Created).Format("Jan 2 15:04"), s.PID, title)
			}
			return w.Flush()
		},
	}
}

func newSessionCommand() *cobra.Command {
	var (
		detached bool
		cwd      string
	)
	cmd := &cobra.Command{
		Use:   "new [command line]",
		Short: "Start a session and attach to it",
		RunE: func(cmd *cobra.Command, args []string) error {
			c, err := connect(true)
			if err != nil {
				return err
			}
			defer c.Close()
			size := persist.Size{Cols: 80, Rows: 24}
			if cols, rows, err := consoleSize(); err == nil && !detached {
				size.Cols, size.Rows = cols, rows
			}
			err = c.Send(0, &persist.New{Command: strings.Join(args, " "), Cwd: cwd, Size: size})
			if err != nil {
				return err
			}
			a, err := c.ReadAttach()
			if err != nil {
				return err
			}
			if detached {
				fmt.Println(a.ID)
				return nil
			}
			return attach(c, a)
		},
	}
	cmd.Flags().BoolVarP(&detached, "detached", "d", false, "don't attach; print the session's id")
	cmd.Flags().StringVarP(&cwd, "cwd", "C", "", "directory to start in")
	return cmd
}

func attachCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "attach <id>",
		Short: "Attach to a session in this console (Ctrl+] detaches)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			var size persist.Size
			if cols, rows, err := consoleSize(); err == nil {
				size.Cols, size.Rows = cols, rows
			}
			if err := c.Send(id, &persist.Attach{Size: size}); err != nil {
				return err
			}
			a, err := c.ReadAttach()
			if err != nil {
				return err
			}
			return attach(c, a)
		},
	}
}

func peekCommand() *cobra.Command {
	var asVT bool
	cmd := &cobra.Command{
		Use:   "peek <id>",
		Short: "Print a session's screen and scrollback (takes it from an attached client)",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			id, err := parseID(args[0])
			if err != nil {
				return err
			}
			c, err := connect(false)
			if err != nil {
				return err
			}
			defer c.Close()
			if err := c.Send(id, &persist.Attach{}); err != nil {
				return err
			}
			a, err := c.ReadAttach()
			if err != nil {
				return err
			}
			c.Send(id, &persist.Detach{})
			ctx := context.Background()
			rt, err := vt.NewRuntime(ctx, nil)
			if err != nil {
				return err
			}
			defer rt.Close(ctx)
			t, err := rt.Decode(a.Snapshot)
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
		Use:   "kill <id>...",
		Short: "End sessions",
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
				if err := c.Send(id, &persist.Kill{}); err != nil {
					return err
				}
			}
			// List after the kills so they're read before we hang up.
			_, err = c.List()
			return err
		},
	}
}

func parseID(s string) (uint32, error) {
	id, err := strconv.ParseUint(s, 10, 32)
	if err != nil {
		return 0, fmt.Errorf("bad session id %q", s)
	}
	return uint32(id), nil
}

// connect dials the daemon. If start is set and none is running, it
// starts one.
func connect(start bool) (*persist.Client, error) {
	name, err := persist.PipeName()
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	conn, err := persist.Dial(ctx, name)
	cancel()
	if err != nil && start && isNotRunning(err) {
		if err := startDaemon(); err != nil {
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
	return persist.NewClient(conn)
}
