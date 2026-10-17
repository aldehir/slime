package sshbridge

import "errors"

// ErrCancelled is the user giving up at one of the prompts.
var ErrCancelled = errors.New("cancelled")

// Asker is how logging in talks to the user: through whatever dialog the
// client that asked to connect shows.
type Asker interface {
	// Ask shows q and waits for the user's choice and answers, one per
	// question. It fails only when the user can't answer any more.
	Ask(q *Query) (Answer, error)
	// Info shows a status line from the server.
	Info(text string)
	// Print writes to the terminal, if there is one: banners and
	// notices.
	Print(text string)
	// Dialog says whether Ask shows a dialog, for checks that would ask
	// a terminal differently.
	Dialog() bool
}

// Query is a prompt with what it shows in a terminal instead.
type Query struct {
	Prompt
	// TermText is printed before the questions in a terminal; Title,
	// Text, Detail and Error aren't.
	TermText string
	// Terminal is each question's line in a terminal, where it isn't
	// its label.
	Terminal []string
}

// PromptKind says what a Prompt asks, for the client to pick its icon
// and buttons.
type PromptKind uint8

const (
	PromptPassword PromptKind = iota + 1
	PromptPassphrase
	PromptInteractive
	PromptUnknownHost
	PromptChangedHost
)

// Question is one field to fill in. Label may run over several lines,
// as keyboard-interactive prompts do; its last line names the field.
type Question struct {
	Label string
	Echo  bool
}

// Prompt asks the user something while logging in. Text is the body,
// Detail is shown in a monospace box (a key's path, fingerprints), and
// Error says why the last answer didn't work. A prompt with no
// questions asks whether to go ahead (a host key).
type Prompt struct {
	Kind                       PromptKind
	Title, Text, Detail, Error string
	Questions                  []Question
}

// Choice is the button a prompt was answered with.
type Choice uint8

const (
	// ChoiceCancel gives up: on logging in for most prompts, on the
	// host for host key prompts.
	ChoiceCancel Choice = iota
	// ChoiceAccept submits the answers, or trusts the host key.
	ChoiceAccept
	// ChoiceSkip moves on without this key (passphrase prompts).
	ChoiceSkip
)

// Answer replies to a Prompt, one answer per question.
type Answer struct {
	Choice  Choice
	Answers []string
}

// PadAnswers makes a one answer per question, whatever the client sent.
func PadAnswers(a Answer, n int) Answer {
	a.Answers = append(a.Answers, make([]string, max(0, n-len(a.Answers)))...)[:n]
	return a
}
