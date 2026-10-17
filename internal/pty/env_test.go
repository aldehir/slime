package pty

import (
	"reflect"
	"testing"
)

func TestMergeEnv(t *testing.T) {
	environ := []string{"PATH=/bin", "Term=dumb", "HOME=/h"}
	extra := map[string]string{"TERM": "xterm", "SLIME_PANE": "7"}
	// Case-sensitive: Term stays, TERM is added; extras come sorted.
	got := mergeEnv(environ, extra, false)
	want := []string{"PATH=/bin", "Term=dumb", "HOME=/h", "SLIME_PANE=7", "TERM=xterm"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("merged %v, want %v", got, want)
	}
	// Folding, as Windows does: Term is replaced.
	got = mergeEnv(environ, extra, true)
	want = []string{"PATH=/bin", "HOME=/h", "SLIME_PANE=7", "TERM=xterm"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("merged folding %v, want %v", got, want)
	}
	if got := mergeEnv(environ, nil, true); !reflect.DeepEqual(got, environ) {
		t.Errorf("nothing to add: %v", got)
	}
}
