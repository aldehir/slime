package main

import (
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"

	"github.com/spf13/cobra"

	"github.com/aldehir/slime/internal/daemon"
	"github.com/aldehir/slime/internal/lua"
	"github.com/aldehir/slime/internal/rpc"
)

// The CLI is its own manual. Each command documents itself where it's
// defined; the topics below are written beside what they describe
// (daemon.EnvDoc with the code that sets a pane's environment,
// rpc.IDsDoc with the ids, lua.Doc with the slime table, rpc.MethodDocs
// with the methods) and shown here. `slime help` prints it all in one
// piece, for a reader or an agent to learn this build from; `slime help
// <command|topic>` one part.

// rootDoc is what `slime` and `slime help` open with.
const rootDoc = `slime is a daemon that owns terminals: each pane is a program on a pty
with its terminal state; panes sit in tabs (a layout tree), tabs in
workspaces, and windows (slime-gui) attach workspaces and draw them, as
many windows on one workspace as you like. Panes outlive their windows.
On SSH hosts the same daemon runs there, and windows draw its panes too.

This command controls all of it. Everything it does is a method of the
daemon's control plane (slime call <method> does any raw), and the same
methods are Lua functions in scripts the daemon runs (slime do).

Ids are paths: workspace 1, tab 1.2, pane 1.2.3 (slime help ids). A
shell in a pane has SLIME_PANE and the rest (slime help env), so pane
commands run there act on that pane unless told another, slime tab new
adds to its workspace, and slime do runs for it.

Commands that make things (do, tab new, ws new, host connect) start the
daemon if none is running; the others say "slime isn't running".
--json on any command prints the daemon's reply as it came.

init.lua (slime config path) configures the daemon and its windows in
Lua: settings, key bindings, and actions, which slime do runs by name
(slime help lua, slime config).

slime help prints the whole manual: every command and the topics env,
ids, lua, methods, and events.`

// helpCommand replaces cobra's: without arguments it prints the manual,
// with them the help of that command or topic.
func helpCommand(root *cobra.Command) *cobra.Command {
	return &cobra.Command{
		Use:   "help [command|topic]",
		Short: "The whole manual, or help for one command or topic",
		Long: "Prints the manual: every command with its flags, and the topics (env, ids,\n" +
			"lua, methods, events), in one piece. With a command or topic, that alone.",
		Args: cobra.ArbitraryArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			if len(args) == 0 {
				return printManual(root, os.Stdout)
			}
			target, _, err := root.Find(args)
			if target == nil || err != nil || (target == root && len(args) > 0) {
				return fmt.Errorf("unknown help topic %q", strings.Join(args, " "))
			}
			return target.Help()
		},
	}
}

// topicCommands are the help topics: commands with nothing to run, which
// cobra lists apart and `slime help <topic>` prints.
func topicCommands() []*cobra.Command {
	return []*cobra.Command{
		{Use: "env", Short: "The SLIME_* variables in a pane's environment", Long: daemon.EnvDoc},
		{Use: "ids", Short: "How workspaces, tabs, and panes are named", Long: rpc.IDsDoc},
		{Use: "lua", Short: "The slime table scripts get, with examples", Long: lua.Doc},
		{Use: "methods", Short: "Every method of the control plane, its params, result, and error codes", Long: methodsDoc()},
		{Use: "events", Short: "Every notification the daemon sends", Long: eventsDoc()},
	}
}

// printManual writes the whole manual: the overview, every runnable
// command depth first with its flags, then the topics.
func printManual(root *cobra.Command, w io.Writer) error {
	fmt.Fprintf(w, "SLIME\n\n%s\n\nGlobal flags:\n%s\n", rootDoc, root.PersistentFlags().FlagUsages())
	fmt.Fprintf(w, "COMMANDS\n\n")
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		for _, sub := range c.Commands() {
			if !sub.Runnable() && !sub.HasSubCommands() || sub.Hidden || sub.Name() == "completion" || sub.Name() == "help" {
				continue
			}
			if sub.Runnable() {
				fmt.Fprintf(w, "%s\n", sub.UseLine())
				doc := sub.Long
				if doc == "" {
					doc = sub.Short
				}
				fmt.Fprintf(w, "%s\n", indent(doc))
				if flags := sub.LocalNonPersistentFlags().FlagUsages(); flags != "" {
					fmt.Fprint(w, flags)
				}
				fmt.Fprintln(w)
			}
			walk(sub)
		}
	}
	walk(root)
	for _, t := range topicCommands() {
		fmt.Fprintf(w, "%s\n\n%s\n\n", strings.ToUpper(t.Use), t.Long)
	}
	return nil
}

// wrap breaks s into lines of at most width columns, each led by prefix
// and ended by a newline.
func wrap(s, prefix string, width int) string {
	var b strings.Builder
	line := prefix
	for _, word := range strings.Fields(s) {
		if len(line) > len(prefix) && len(line)+1+len(word) > width {
			b.WriteString(line + "\n")
			line = prefix
		}
		if len(line) > len(prefix) {
			line += " "
		}
		line += word
	}
	if len(line) > len(prefix) {
		b.WriteString(line + "\n")
	}
	return b.String()
}

// indent puts two spaces before each line.
func indent(s string) string {
	return "  " + strings.ReplaceAll(strings.TrimRight(s, "\n"), "\n", "\n  ")
}

// methodsDoc renders rpc.MethodDocs, the shapes, and the error codes.
func methodsDoc() string {
	var b strings.Builder
	b.WriteString("Params and results are JSON objects; the Lua tables mirror them field for\n" +
		"field. ? marks an optional field. slime call <method> '<params>' calls any.\n\n")
	width := 0
	for _, m := range rpc.MethodDocs {
		width = max(width, len(m.Name))
	}
	for _, m := range rpc.MethodDocs {
		fmt.Fprintf(&b, "  %-*s  %s -> %s\n", width, m.Name, m.Params, m.Result)
		if m.Note != "" {
			b.WriteString(wrap(m.Note, strings.Repeat(" ", width+4), 76))
		}
	}
	b.WriteString("\nSHAPES\n\n" + rpc.ShapesDoc + "\n\nERROR CODES\n\n")
	tw := tabwriter.NewWriter(&b, 0, 4, 2, ' ', 0)
	for _, c := range rpc.CodeDocs {
		fmt.Fprintf(tw, "  %d\t%s\n", c.Code, c.Meaning)
	}
	tw.Flush()
	b.WriteString("\nThe CLI prints \"message (code N)\" and exits 1; Lua gets nil, message, code.")
	return b.String()
}

// eventsDoc renders rpc.EventDocs.
func eventsDoc() string {
	var b strings.Builder
	b.WriteString("A window gets its workspaces' events without subscribing; a script's owner\n" +
		"gets script.* for its scripts; anyone else subscribes (the subscribe method,\n" +
		"on a connection of its own). Scripts can't receive events yet.\n\n")
	tw := tabwriter.NewWriter(&b, 0, 4, 2, ' ', 0)
	for _, e := range rpc.EventDocs {
		fmt.Fprintf(tw, "  %s\t%s\n", e.Name, e.Params)
	}
	tw.Flush()
	return strings.TrimRight(b.String(), "\n")
}
