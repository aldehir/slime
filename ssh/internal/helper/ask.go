package helper

import (
	"errors"
	"log"
	"strings"

	"github.com/aldehir/slime/ssh/internal/prompt"
	"github.com/aldehir/slime/ssh/internal/proto"
)

// ErrCancelled is the user giving up at one of the prompts.
var ErrCancelled = errors.New("cancelled")

// Asker is how logging in talks to the user: in a dialog (slime's, or
// the daemon's client's), or in the connecting channel's terminal, as
// ssh does.
type Asker interface {
	// Ask shows q and waits for the user's choice and answers, one per
	// question. It fails only when the user can't answer any more.
	Ask(q *Query) (proto.Answer, error)
	// Info shows a status line from the server.
	Info(text string)
	// Print writes to the terminal, if there is one: banners and
	// notices.
	Print(text string)
	// Dialog says whether Ask shows a dialog, for checks that ask a
	// terminal differently.
	Dialog() bool
}

// Query is a prompt with what it shows in a terminal instead.
type Query struct {
	proto.Prompt
	// TermText is printed before the questions in a terminal; Title,
	// Text, Detail and Error aren't.
	TermText string
	// Terminal is each question's line in a terminal, where it isn't
	// its label.
	Terminal []string
}

// termAsker asks in the channel's terminal.
type termAsker struct{ p *prompt.Prompter }

func (t termAsker) Ask(q *Query) (proto.Answer, error) {
	if q.TermText != "" {
		t.Info(q.TermText)
	}
	answers := make([]string, len(q.Questions))
	for i, pq := range q.Questions {
		line := pq.Label
		if i < len(q.Terminal) && q.Terminal[i] != "" {
			line = q.Terminal[i]
		}
		ans, err := t.p.ReadLine(line, pq.Echo)
		if err != nil {
			return proto.Answer{}, err
		}
		answers[i] = ans
	}
	return proto.Answer{Choice: proto.ChoiceAccept, Answers: answers}, nil
}

func (t termAsker) Info(text string) {
	if !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	t.p.Print(text)
}

func (t termAsker) Print(text string) { t.p.Print(text) }
func (termAsker) Dialog() bool        { return false }

// dialogAsker asks through slime's dialog for channel id. Notices still
// go to the channel's terminal, or the log if it has none.
type dialogAsker struct {
	s    *Server
	id   uint32
	term *prompt.Prompter
}

func (d *dialogAsker) Ask(q *Query) (proto.Answer, error) {
	answers := make(chan proto.Answer, 1)
	d.s.mu.Lock()
	if d.s.state == stateClosing {
		d.s.mu.Unlock()
		return proto.Answer{}, ErrCancelled
	}
	d.s.answers = answers
	d.s.mu.Unlock()
	defer func() {
		d.s.mu.Lock()
		if d.s.answers == answers {
			d.s.answers = nil
		}
		d.s.mu.Unlock()
	}()

	d.s.send(d.id, &q.Prompt)
	select {
	case a := <-answers:
		return padAnswers(a, len(q.Questions)), nil
	case <-d.s.done:
		return proto.Answer{}, ErrCancelled
	}
}

// padAnswers makes a one answer per question, whatever the client sent.
func padAnswers(a proto.Answer, n int) proto.Answer {
	a.Answers = append(a.Answers, make([]string, max(0, n-len(a.Answers)))...)[:n]
	return a
}

func (d *dialogAsker) Info(text string) {
	d.s.send(d.id, &proto.Info{Text: strings.TrimRight(text, "\r\n")})
}

func (d *dialogAsker) Print(text string) {
	if d.term == nil {
		log.Printf("channel %d: %s", d.id, strings.TrimRight(text, "\r\n"))
		return
	}
	d.term.Print(text)
}

func (*dialogAsker) Dialog() bool { return true }
