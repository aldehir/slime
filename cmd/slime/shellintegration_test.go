package main

import (
	"bytes"
	"strings"
	"testing"
)

// TestShellIntegration: each shell gets its completion and its hook,
// and zsh's completion registers only where compinit has run.
func TestShellIntegration(t *testing.T) {
	root := newCommand()
	tests := []struct {
		shell string
		want  []string
	}{
		{"bash", []string{"complete -o default -F __start_slime slime", "__slime_report_pwd", `\033]7;kitty-shell-cwd://`, "PROMPT_COMMAND+=(__slime_report_pwd)"}},
		{"zsh", []string{"#compdef slime\n(( $+functions[compdef] )) && compdef _slime slime\n", "add-zsh-hook chpwd __slime_report_pwd", `$'\e]7;kitty-shell-cwd://'`}},
		{"powershell", []string{"Register-ArgumentCompleter", "function global:prompt", "]9;9;"}},
	}
	for _, tc := range tests {
		var out bytes.Buffer
		if err := writeShellIntegration(&out, root, tc.shell); err != nil {
			t.Fatalf("%s: %v", tc.shell, err)
		}
		for _, w := range tc.want {
			if !strings.Contains(out.String(), w) {
				t.Errorf("%s: no %q in:\n%s", tc.shell, w, out.String())
			}
		}
	}
	if err := writeShellIntegration(&bytes.Buffer{}, root, "fish"); err == nil {
		t.Error("fish: no error")
	}
}
