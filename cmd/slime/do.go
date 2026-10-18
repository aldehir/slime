package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"

	"github.com/aldehir/slime/internal/daemon"
	"github.com/aldehir/slime/internal/rpc"
)

// errScriptFailed is a script that ended with an error, already
// printed: the exit status is 1 and nothing more is said.
var errScriptFailed = errors.New("script failed")

// doCommand runs Lua in the daemon: a file, -e code, or stdin, with
// key=value arguments as slime.args. The script's output comes back
// here as it prints, and its return value prints at the end.
func doCommand() *cobra.Command {
	var (
		code   string
		pane   uint32
		detach bool
	)
	cmd := &cobra.Command{
		Use:   "do <file.lua | -> [key=value...]",
		Short: "Run a Lua script in the daemon",
		Long: "Runs Lua in the daemon, against its workspaces (see internal/lua for the slime\n" +
			"table): a file, code given with -e, or stdin as -. Arguments are key=value pairs,\n" +
			"strings in slime.args. Inside a pane, the script runs for that pane (SLIME_PANE),\n" +
			"so calls that take a pane, tab, or workspace id default to it. What the script\n" +
			"prints comes here; its return value prints at the end; an error exits 1.\n" +
			"Ctrl+C cancels it, unless it was started with --detach.",
		Args: cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			name, source, rest, err := scriptSource(code, args)
			if err != nil {
				return err
			}
			params := rpc.ScriptRunParams{Source: source, Name: name, Pane: pane, Detach: detach}
			if params.Args, err = scriptArgs(rest); err != nil {
				return err
			}
			c, err := connect(true)
			if err != nil {
				return err
			}
			defer c.Close()
			var started rpc.ScriptRunResult
			if err := c.Call(rpc.ScriptRun, params, &started); err != nil {
				return err
			}
			if detach {
				if jsonOut {
					return printJSON(started)
				}
				fmt.Println(started.ID)
				return nil
			}
			return followScript(c, started.ID)
		},
	}
	cmd.Flags().StringVarP(&code, "eval", "e", "", "run this code instead of a file")
	cmd.Flags().Uint32VarP(&pane, "pane", "p", envPane(), "the pane the script runs for (default $SLIME_PANE)")
	cmd.Flags().BoolVar(&detach, "detach", false, "leave the script running in the daemon and print its id")
	return cmd
}

// envPane is the pane this console runs in, if it's one of slime's,
// and envWorkspace the workspace that pane is in: every pane's shell
// has SLIME_PANE and SLIME_WORKSPACE.
func envPane() uint32 { return envID("SLIME_PANE") }

func envWorkspace() uint32 { return envID("SLIME_WORKSPACE") }

func envID(name string) uint32 {
	id, err := strconv.ParseUint(os.Getenv(name), 10, 32)
	if err != nil {
		return 0
	}
	return uint32(id)
}

// scriptSource picks the script: code, else the first argument as a
// file (- for stdin). It returns the chunk name, the source, and the
// arguments left.
func scriptSource(code string, args []string) (name, source string, rest []string, err error) {
	if code != "" {
		return "(command line)", code, args, nil
	}
	if len(args) == 0 {
		return "", "", nil, errors.New("a script file, -, or -e code is needed")
	}
	path, rest := args[0], args[1:]
	if path == "-" {
		b, err := io.ReadAll(os.Stdin)
		if err != nil {
			return "", "", nil, err
		}
		return "stdin", string(b), rest, nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) && !strings.ContainsAny(path, `/\.`) {
			return "", "", nil, fmt.Errorf("no file %q (actions by name come with init.lua)", path)
		}
		return "", "", nil, err
	}
	return filepath.Base(path), string(b), rest, nil
}

// scriptArgs turns key=value arguments into the JSON object slime.args
// is made from.
func scriptArgs(args []string) (json.RawMessage, error) {
	if len(args) == 0 {
		return nil, nil
	}
	m := make(map[string]string, len(args))
	for _, a := range args {
		k, v, ok := strings.Cut(a, "=")
		if !ok || k == "" {
			return nil, fmt.Errorf("arguments are key=value, not %q", a)
		}
		m[k] = v
	}
	return json.Marshal(m)
}

// followScript relays script id's output until it's done, cancelling
// it on ctrl+c, and prints its result.
func followScript(c *daemon.Client, id uint32) error {
	interrupt := make(chan os.Signal, 1)
	signal.Notify(interrupt, os.Interrupt)
	defer signal.Stop(interrupt)
	go func() {
		<-interrupt
		req := rpc.Request{JSONRPC: "2.0", ID: c.NextID(), Method: rpc.ScriptCancel}
		req.Params, _ = json.Marshal(rpc.ScriptParams{ID: id})
		c.Send(0, &daemon.Call{Request: req})
		// A second one gives up on the script.
		<-interrupt
		os.Exit(130)
	}()
	for {
		_, m, err := c.Recv()
		if err != nil {
			return err
		}
		name, params, ok := daemon.Notification(m)
		if !ok {
			continue
		}
		switch name {
		case rpc.EvScriptOutput:
			var p rpc.ScriptOutputParams
			if err := json.Unmarshal(params, &p); err != nil || p.ID != id {
				continue
			}
			if p.Stream == "stderr" {
				os.Stderr.WriteString(p.Data)
			} else {
				os.Stdout.WriteString(p.Data)
			}
		case rpc.EvScriptDone:
			var p rpc.ScriptDoneParams
			if err := json.Unmarshal(params, &p); err != nil || p.ID != id {
				continue
			}
			if !p.OK {
				fmt.Fprintln(os.Stderr, p.Error)
				return errScriptFailed
			}
			return printResult(p.Result)
		}
	}
}

// printResult prints what a script returned: nothing for nothing, a
// string as it is, and anything else as JSON. With --json, the JSON.
func printResult(result json.RawMessage) error {
	if jsonOut {
		if len(result) == 0 {
			result = json.RawMessage("null")
		}
		return printJSON(result)
	}
	if len(result) == 0 || string(result) == "null" {
		return nil
	}
	var s string
	if json.Unmarshal(result, &s) == nil {
		fmt.Println(s)
		return nil
	}
	return printJSON(result)
}

// scriptsCommand lists and ends the scripts running in the daemon.
func scriptsCommand() *cobra.Command {
	ls := &cobra.Command{
		Use:   "ls",
		Short: "List the scripts running in the daemon",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			var l rpc.ScriptListResult
			if err := call(rpc.ScriptList, nil, &l); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(l)
			}
			w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
			for _, sc := range l.Scripts {
				state := "attached"
				if sc.Detached {
					state = "detached"
				}
				pane := ""
				if sc.Pane != 0 {
					pane = fmt.Sprintf("pane %d", sc.Pane)
				}
				fmt.Fprintf(w, "script %d\t%s\t%s\t%s\t%s\n", sc.ID, sc.Name, state, pane, time.UnixMilli(sc.Started).Format("Jan 2 15:04:05"))
			}
			return w.Flush()
		},
	}
	scripts := &cobra.Command{
		Use:   "scripts",
		Short: "List and end the scripts running in the daemon",
		Args:  cobra.NoArgs,
		RunE:  ls.RunE,
	}
	scripts.AddCommand(ls, &cobra.Command{
		Use:   "kill <script>...",
		Short: "Cancel scripts",
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
				if err := c.Call(rpc.ScriptCancel, rpc.ScriptParams{ID: id}, nil); err != nil {
					return err
				}
			}
			return nil
		},
	})
	return scripts
}
