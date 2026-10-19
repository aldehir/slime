package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/aldehir/slime/internal/config"
	"github.com/aldehir/slime/internal/rpc"
)

// errConfigFailed is a config that didn't load, already printed: the
// exit status is 1 and nothing more is said.
var errConfigFailed = errors.New("config failed")

// configCommand shows, checks, and reloads the daemon's init.lua.
func configCommand() *cobra.Command {
	cfg := &cobra.Command{
		Use:   "config",
		Short: "Show, check, and reload the daemon's init.lua",
		Long: "The daemon evaluates init.lua (slime config path says where; SLIME_CONFIG\n" +
			"overrides) when it starts and on slime config reload. slime help lua describes\n" +
			"what the file can do: slime.config for the settings, slime.bind for keys, and\n" +
			"slime.action for actions that slime do and key bindings run.",
	}
	cfg.AddCommand(&cobra.Command{
		Use:   "path",
		Short: "Print the config file's path, the running daemon's if there is one",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			path := config.Path()
			if c, err := connect(false); err == nil {
				var d rpc.ConfigDesc
				if err := c.Call(rpc.ConfigGet, nil, &d); err == nil && d.Path != "" {
					path = d.Path
				}
				c.Close()
			}
			if path == "" {
				return errors.New("no config directory: set SLIME_CONFIG, APPDATA, or XDG_CONFIG_HOME")
			}
			fmt.Println(path)
			return nil
		},
	}, &cobra.Command{
		Use:   "check [file]",
		Short: "Evaluate init.lua (or another file) without applying it, and say what it would set",
		Long: "Evaluates the daemon's init.lua, or the file given (an absolute path, or one\n" +
			"relative to this console), in the daemon without keeping the result: an error\n" +
			"prints and exits 1; otherwise the settings, bindings, and actions it sets. The\n" +
			"daemon is started if none runs.",
		Args: cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			var p rpc.ConfigCheckParams
			if len(args) == 1 {
				path, err := filepath.Abs(args[0])
				if err != nil {
					return err
				}
				p.Path = path
			}
			c, err := connect(true)
			if err != nil {
				return err
			}
			defer c.Close()
			var d rpc.ConfigDesc
			if err := c.Call(rpc.ConfigCheck, p, &d); err != nil {
				return err
			}
			return printConfig(d, "ok")
		},
	}, &cobra.Command{
		Use:   "reload",
		Short: "Evaluate init.lua again; a failure keeps the config as it was",
		Long: "Evaluates init.lua again. If it fails, the error prints, the exit status is 1,\n" +
			"and the daemon keeps the settings, bindings, and actions it had; otherwise they\n" +
			"are replaced, and every window takes the new bindings (settings wait for the\n" +
			"next window).",
		Args: cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			var d rpc.ConfigDesc
			if err := call(rpc.ConfigReload, nil, &d); err != nil {
				return err
			}
			return printConfig(d, "reloaded")
		},
	}, &cobra.Command{
		Use:   "show",
		Short: "Print the config as the daemon has it: settings, bindings, actions, and errors",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			var d rpc.ConfigDesc
			if err := call(rpc.ConfigGet, nil, &d); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(d)
			}
			fmt.Printf("path\t%s\n", d.Path)
			if len(d.Errors) > 0 {
				fmt.Printf("errors\n%s\n(the settings, bindings, and actions below are the last that loaded)\n", indent(strings.Join(d.Errors, "\n")))
			}
			fmt.Printf("settings\n%s\n", indent(prettyJSON(d.Settings)))
			if len(d.Keymap) > 0 {
				fmt.Println("keymap")
				w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
				for _, b := range d.Keymap {
					fmt.Fprintf(w, "  %s\t%s\n", b.Key, bindingString(b))
				}
				w.Flush()
			}
			if len(d.Actions) > 0 {
				fmt.Println("actions")
				printActions(d.Actions, "  ")
			}
			return nil
		},
	})
	return cfg
}

// printConfig prints what a check or reload found: the errors, exiting
// 1, or what the file set, led by ok.
func printConfig(d rpc.ConfigDesc, ok string) error {
	if jsonOut {
		if err := printJSON(d); err != nil {
			return err
		}
		if len(d.Errors) > 0 {
			return errConfigFailed
		}
		return nil
	}
	if len(d.Errors) > 0 {
		fmt.Fprintln(os.Stderr, strings.Join(d.Errors, "\n"))
		return errConfigFailed
	}
	fmt.Printf("%s: %s: %d bindings, %d actions\n", ok, d.Path, len(d.Keymap), len(d.Actions))
	return nil
}

// bindingString says what a binding runs.
func bindingString(b rpc.Binding) string {
	switch {
	case b.Lua != 0:
		return fmt.Sprintf("function %d", b.Lua)
	case b.Action == "":
		return "unbound"
	case len(b.Args) > 0:
		return b.Action + " " + string(b.Args)
	}
	return b.Action
}

// printActions lists actions: name, title, and argument spec.
func printActions(actions []rpc.ActionDesc, prefix string) {
	w := tabwriter.NewWriter(os.Stdout, 0, 4, 2, ' ', 0)
	for _, a := range actions {
		args := ""
		if len(a.Args) > 0 {
			args = string(a.Args)
		}
		fmt.Fprintf(w, "%s%s\t%s\t%s\n", prefix, a.Name, a.Title, args)
	}
	w.Flush()
}

func prettyJSON(raw json.RawMessage) string {
	var b bytes.Buffer
	if err := json.Indent(&b, raw, "", "  "); err != nil {
		return string(raw)
	}
	return b.String()
}

// actionsCommand lists the actions init.lua defined.
func actionsCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "actions",
		Short: "List the actions init.lua defined, which slime do runs by name",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			var d rpc.ConfigDesc
			if err := call(rpc.ConfigGet, nil, &d); err != nil {
				return err
			}
			if jsonOut {
				return printJSON(d.Actions)
			}
			printActions(d.Actions, "")
			return nil
		},
	}
}
