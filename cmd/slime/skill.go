package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/spf13/cobra"

	slime "github.com/aldehir/slime"
)

// skillName is the skill's name, and the directory it lives in.
const skillName = "slime"

// skillCommand prints and installs the agent skill this build carries
// (skills/slime/SKILL.md), which tells an agent to learn slime from
// `slime help`: the skill is short because the manual is here.
func skillCommand() *cobra.Command {
	skill := &cobra.Command{
		Use:   "skill",
		Short: "Print, install, and remove the skill that teaches agents to drive slime",
		Long: "An agent skill is a directory named for it holding SKILL.md, which an agent\n" +
			"loads when its description matches the task. This slime carries one, and\n" +
			"installs it in a skills directory (for Claude Code, ~/.claude/skills or a\n" +
			"project's .claude/skills) as <path>/slime/SKILL.md. The skill points the\n" +
			"agent at this manual (slime help) and the SLIME_* variables in a pane, so\n" +
			"it suits whichever build the daemon runs.",
	}
	skill.AddCommand(&cobra.Command{
		Use:   "show",
		Short: "Print the skill",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, args []string) error {
			_, err := os.Stdout.WriteString(slime.Skill)
			return err
		},
	}, &cobra.Command{
		Use:   "install <path>",
		Short: "Write the skill to <path>/slime/SKILL.md",
		Long: "Writes the skill to <path>/slime/SKILL.md, making the directories; a path\n" +
			"already ending in slime is the skill's own directory. An older copy is\n" +
			"replaced.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			dir := skillDir(args[0])
			if err := os.MkdirAll(dir, 0o755); err != nil {
				return err
			}
			file := filepath.Join(dir, "SKILL.md")
			if err := os.WriteFile(file, []byte(slime.Skill), 0o644); err != nil {
				return err
			}
			fmt.Println(file)
			return nil
		},
	}, &cobra.Command{
		Use:   "uninstall <path>",
		Short: "Remove <path>/slime, the installed skill",
		Long: "Removes <path>/slime and everything in it; a path already ending in slime\n" +
			"is the skill's own directory. Nothing else is touched: only a directory\n" +
			"named slime is removed.",
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			dir := skillDir(args[0])
			if _, err := os.Stat(dir); err != nil {
				if errors.Is(err, os.ErrNotExist) {
					return fmt.Errorf("no skill at %s", dir)
				}
				return err
			}
			if err := os.RemoveAll(dir); err != nil {
				return err
			}
			fmt.Println(dir)
			return nil
		},
	})
	return skill
}

// skillDir is the skill's directory for a path the user gave: the path
// itself when it's named slime, else slime under it. Uninstall removes
// it whole, so it is only ever a directory named slime.
func skillDir(path string) string {
	if abs, err := filepath.Abs(path); err == nil {
		path = abs
	}
	if filepath.Base(path) == skillName {
		return path
	}
	return filepath.Join(path, skillName)
}
