package main

import (
	"bytes"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/spf13/cobra"
)

// shellIntegrationCommand prints what a shell in a pane evaluates to
// work with slime: completion for this command, and a hook that tells
// the pane the shell's directory (OSC 7), which a split starts in.
// It's one line in the rc file, inert outside a pane (no SLIME_EXE),
// and finds the daemon's own build wherever it is, on this machine or
// a host slime logs in to.
func shellIntegrationCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "shell-integration <bash|zsh|powershell>",
		Short: "Print the completion and directory hook a shell in a pane evaluates",
		Long: "Prints, for the shell named, completion for slime and a hook that reports\n" +
			"the shell's working directory to its pane after each prompt (OSC 7, or 9;9\n" +
			"from PowerShell), so that a pane split beside it starts there (pane.split,\n" +
			"slime pane split).\n" +
			"Evaluate it from the shell's rc file, where SLIME_EXE (slime help env)\n" +
			"makes the line do nothing outside a pane and find the daemon's own build\n" +
			"inside one, here or on a host:\n\n" +
			"  ~/.bashrc:\n" +
			"    [ -n \"$SLIME_EXE\" ] && eval \"$(\"$SLIME_EXE\" shell-integration bash)\"\n\n" +
			"  ~/.zshrc (after compinit, for the completion):\n" +
			"    [ -n \"$SLIME_EXE\" ] && eval \"$(\"$SLIME_EXE\" shell-integration zsh)\"\n\n" +
			"  $PROFILE (last, after anything that sets the prompt):\n" +
			"    if ($env:SLIME_EXE) { & $env:SLIME_EXE shell-integration powershell | Out-String | Invoke-Expression }\n\n" +
			"Bash reports at each prompt, so a cd in a script that ends without one\n" +
			"goes unreported; zsh reports the change itself. PowerShell's hook wraps\n" +
			"the prompt function, so it must come after whatever else defines it.",
		Args:      cobra.ExactArgs(1),
		ValidArgs: []string{"bash", "zsh", "powershell"},
		RunE: func(cmd *cobra.Command, args []string) error {
			return writeShellIntegration(os.Stdout, cmd.Root(), args[0])
		},
	}
}

// writeShellIntegration writes shell's completion script and hook to w.
func writeShellIntegration(w io.Writer, root *cobra.Command, shell string) error {
	var completion bytes.Buffer
	var hook string
	switch shell {
	case "bash":
		if err := root.GenBashCompletionV2(&completion, true); err != nil {
			return err
		}
		hook = bashHook
	case "zsh":
		if err := root.GenZshCompletion(&completion); err != nil {
			return err
		}
		// Cobra registers the completion with compdef, which only
		// compinit defines: without it the rest still loads.
		hook = zshHook
		completion = *bytes.NewBufferString(strings.Replace(completion.String(),
			"\ncompdef _"+root.Name()+" "+root.Name()+"\n",
			"\n(( $+functions[compdef] )) && compdef _"+root.Name()+" "+root.Name()+"\n", 1))
	case "powershell":
		if err := root.GenPowerShellCompletionWithDesc(&completion); err != nil {
			return err
		}
		hook = powershellHook
	default:
		return fmt.Errorf("no integration for %q: bash, zsh, or powershell", shell)
	}
	if _, err := w.Write(completion.Bytes()); err != nil {
		return err
	}
	_, err := io.WriteString(w, "\n"+hook)
	return err
}

// The hooks report the directory as kitty's shells do, raw after the
// host (kitty-shell-cwd://), rather than percent-encoded as OSC 7's
// file:// wants, which a shell can't do simply; the daemon takes both
// (pwdPath). Each guards against being evaluated twice in one shell.
// PowerShell's uses OSC 9;9 (ConEmu's, Windows Terminal's convention),
// a bare quoted path.
const bashHook = `# slime shell integration for bash
if [[ -z "$__slime_integration" && "$-" == *i* ]]; then
  __slime_integration=1
  __slime_pwd=""
  __slime_report_pwd() {
    if [[ "$__slime_pwd" != "$PWD" ]]; then
      __slime_pwd="$PWD"
      builtin printf '\033]7;kitty-shell-cwd://%s%s\007' "$HOSTNAME" "$PWD"
    fi
  }
  if [[ "$(declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
    PROMPT_COMMAND+=(__slime_report_pwd)
  else
    PROMPT_COMMAND="__slime_report_pwd${PROMPT_COMMAND:+; $PROMPT_COMMAND}"
  fi
fi
`

const zshHook = `# slime shell integration for zsh
if [[ -z "$__slime_integration" && -o interactive ]]; then
  __slime_integration=1
  __slime_report_pwd() { builtin print -rn -- $'\e]7;kitty-shell-cwd://'"${HOST}${PWD}"$'\a' }
  autoload -Uz add-zsh-hook
  add-zsh-hook chpwd __slime_report_pwd
  add-zsh-hook precmd __slime_report_pwd
  __slime_report_pwd
fi
`

const powershellHook = `# slime shell integration for PowerShell
if (-not $global:__slime_integration) {
  $global:__slime_integration = $true
  $global:__slime_prompt = $function:prompt
  function global:prompt {
    $loc = $ExecutionContext.SessionState.Path.CurrentLocation
    $report = ''
    if ($loc.Provider.Name -eq 'FileSystem') {
      $report = "$([char]27)]9;9;" + '"' + $loc.ProviderPath + '"' + "$([char]27)\"
    }
    $report + ((& $global:__slime_prompt) -join '')
  }
}
`
