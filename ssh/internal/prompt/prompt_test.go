package prompt

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"strings"
	"testing"
)

func readLine(t *testing.T, input, prompt string, echo bool) (line, shown, rest string, err error) {
	t.Helper()
	in := bufio.NewReader(strings.NewReader(input))
	var out bytes.Buffer
	line, err = New(in, &out).ReadLine(prompt, echo)
	restBytes, _ := io.ReadAll(in)
	return line, out.String(), string(restBytes), err
}

func TestReadLine(t *testing.T) {
	cases := []struct {
		name, input string
		echo        bool
		line, shown string
	}{
		{"echo", "yes\r", true, "yes", "? yes\r\n"},
		{"no echo", "hunter2\r", false, "hunter2", "? \r\n"},
		{"lf", "abc\n", true, "abc", "? abc\r\n"},
		{"crlf", "abc\r\n", true, "abc", "? abc\r\n"},
		{"backspace", "abd\x7fc\r", true, "abc", "? abd\b \bc\r\n"},
		{"ctrl+h", "abd\x08c\r", false, "abc", "? \r\n"},
		{"backspace on empty", "\x7f\x7fa\r", true, "a", "? a\r\n"},
		{"backspace utf-8", "né\x7fe\r", true, "ne", "? né\b \be\r\n"},
		{"ctrl+u", "wrong\x15ok\r", true, "ok", "? wrong" + strings.Repeat("\b \b", 5) + "ok\r\n"},
		{"arrow keys", "a\x1b[Db\x1bOAc\r", true, "abc", "? abc\r\n"},
		{"csi with params", "a\x1b[1;5Cb\r", true, "ab", "? ab\r\n"},
		{"control bytes", "a\x01\x02b\r", true, "ab", "? ab\r\n"},
		{"yubikey otp", "cccccbhuvtgfhkedvdibjtdldjvjrfcdhihuvdjjgerk\r", true,
			"cccccbhuvtgfhkedvdibjtdldjvjrfcdhihuvdjjgerk",
			"? cccccbhuvtgfhkedvdibjtdldjvjrfcdhihuvdjjgerk\r\n"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			line, shown, _, err := readLine(t, tc.input, "? ", tc.echo)
			if err != nil {
				t.Fatal(err)
			}
			if line != tc.line {
				t.Errorf("line = %q, want %q", line, tc.line)
			}
			if shown != tc.shown {
				t.Errorf("shown = %q, want %q", shown, tc.shown)
			}
		})
	}
}

// Keys typed past the line belong to the shell.
func TestTypeaheadKept(t *testing.T) {
	_, _, rest, err := readLine(t, "pw\rls -l\r", "? ", false)
	if err != nil {
		t.Fatal(err)
	}
	if rest != "ls -l\r" {
		t.Errorf("rest = %q", rest)
	}
}

func TestInterrupt(t *testing.T) {
	_, shown, _, err := readLine(t, "abc\x03def\r", "? ", true)
	if !errors.Is(err, ErrInterrupted) {
		t.Fatalf("err = %v", err)
	}
	if shown != "? abc^C\r\n" {
		t.Errorf("shown = %q", shown)
	}
}

func TestEOF(t *testing.T) {
	if _, _, _, err := readLine(t, "\x04", "? ", true); err != io.EOF {
		t.Errorf("ctrl+d: err = %v", err)
	}
	if _, _, _, err := readLine(t, "abc", "? ", true); err != io.EOF {
		t.Errorf("closed: err = %v", err)
	}
	// Ctrl+D with text is ignored, as in a shell.
	if line, _, _, err := readLine(t, "a\x04b\r", "? ", true); err != nil || line != "ab" {
		t.Errorf("ctrl+d mid-line: %q, %v", line, err)
	}
}

func TestPrint(t *testing.T) {
	var out bytes.Buffer
	New(bufio.NewReader(strings.NewReader("")), &out).Print("a\nb\r\nc")
	if got := out.String(); got != "a\r\nb\r\nc" {
		t.Errorf("Print = %q", got)
	}
}
