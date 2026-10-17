// Package prompt talks to the user through a channel's terminal before
// the remote shell exists, as ssh does for passwords and host keys.
//
// Input is what the GUI sends for keys with no terminal modes set: plain
// bytes, CR for Enter, DEL or BS for Backspace, and VT sequences for
// cursor and function keys. Nothing translates output for us, so lines
// end in CRLF.
package prompt

import (
	"bufio"
	"errors"
	"io"
	"strings"
	"unicode/utf8"
)

// ErrInterrupted is returned when the user presses Ctrl+C at a prompt.
var ErrInterrupted = errors.New("interrupted")

// maxLine bounds a line so a runaway paste can't grow it forever.
const maxLine = 4096

type Prompter struct {
	in  *bufio.Reader
	out io.Writer
}

// New reads keys from in, which keeps whatever the user typed past the
// last line for the shell.
func New(in *bufio.Reader, out io.Writer) *Prompter {
	return &Prompter{in: in, out: out}
}

// Print writes s with its line endings made CRLF.
func (p *Prompter) Print(s string) error {
	s = strings.ReplaceAll(s, "\r\n", "\n")
	s = strings.ReplaceAll(s, "\n", "\r\n")
	_, err := io.WriteString(p.out, s)
	return err
}

// ReadLine shows prompt and reads a line. With echo off nothing appears
// as the user types, like ssh's password prompts.
func (p *Prompter) ReadLine(prompt string, echo bool) (string, error) {
	if err := p.Print(prompt); err != nil {
		return "", err
	}
	var line []byte
	for {
		b, err := p.in.ReadByte()
		if err != nil {
			return "", err
		}
		switch b {
		case '\r', '\n':
			if b == '\r' {
				p.skipByte('\n')
			}
			if err := p.Print("\n"); err != nil {
				return "", err
			}
			return string(line), nil
		case 0x03: // Ctrl+C
			p.Print("^C\n")
			return "", ErrInterrupted
		case 0x04: // Ctrl+D
			if len(line) == 0 {
				p.Print("\n")
				return "", io.EOF
			}
		case 0x7f, 0x08: // Backspace
			if len(line) == 0 {
				continue
			}
			_, size := utf8.DecodeLastRune(line)
			line = line[:len(line)-size]
			if echo {
				p.Print("\b \b")
			}
		case 0x15: // Ctrl+U
			if echo {
				p.Print(strings.Repeat("\b \b", utf8.RuneCount(line)))
			}
			line = line[:0]
		case 0x1b:
			p.skipEscape()
		default:
			if b < 0x20 || len(line) >= maxLine {
				continue
			}
			line = append(line, b)
			if echo {
				p.out.Write([]byte{b})
			}
		}
	}
}

// skipByte drops the next byte if it's already here and is b. Enter may
// arrive as CRLF; waiting for an LF that isn't coming would hang.
func (p *Prompter) skipByte(b byte) {
	if p.in.Buffered() == 0 {
		return
	}
	if next, _ := p.in.Peek(1); next[0] == b {
		p.in.ReadByte()
	}
}

// skipEscape drops the rest of a CSI or SS3 sequence (arrow keys and the
// like) after its ESC. A lone Escape is dropped by itself.
func (p *Prompter) skipEscape() {
	if p.in.Buffered() == 0 {
		return
	}
	next, _ := p.in.Peek(1)
	switch next[0] {
	case 'O':
		p.in.ReadByte()
		if p.in.Buffered() > 0 {
			p.in.ReadByte()
		}
	case '[':
		p.in.ReadByte()
		for p.in.Buffered() > 0 {
			b, _ := p.in.ReadByte()
			if b >= 0x40 && b <= 0x7e {
				return
			}
		}
	}
}
