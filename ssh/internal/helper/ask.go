package helper

import (
	"errors"
	"log"
	"strings"

	"github.com/aldehir/slime/ssh/internal/prompt"
	"github.com/aldehir/slime/ssh/internal/proto"
)

// errCancelled is the user giving up at one of slime's prompts.
var errCancelled = errors.New("cancelled")

// asker is how logging in talks to the user: in slime's dialog when it
// takes prompts (proto.FeaturePrompts), else in the connecting
// channel's terminal, as ssh does.
type asker interface {
	// ask shows q and waits for the user's choice and answers, one per
	// question. It fails only when the user can't answer any more.
	ask(q *question) (proto.Answer, error)
	// info shows a status line from the server.
	info(text string)
	// print writes to the channel's terminal: banners and notices.
	print(text string)
	// dialog says whether ask shows slime's dialog, for checks that
	// ask a terminal differently.
	dialog() bool
}

// question is a prompt with what it shows in a terminal instead.
type question struct {
	proto.Prompt
	// termText is printed before the questions in a terminal; Title,
	// Text, Detail and Error aren't.
	termText string
	// terminal is each question's line in a terminal, where it isn't
	// its label.
	terminal []string
}

// termAsker asks in the channel's terminal.
type termAsker struct{ p *prompt.Prompter }

func (t termAsker) ask(q *question) (proto.Answer, error) {
	if q.termText != "" {
		t.info(q.termText)
	}
	answers := make([]string, len(q.Questions))
	for i, pq := range q.Questions {
		line := pq.Label
		if i < len(q.terminal) && q.terminal[i] != "" {
			line = q.terminal[i]
		}
		ans, err := t.p.ReadLine(line, pq.Echo)
		if err != nil {
			return proto.Answer{}, err
		}
		answers[i] = ans
	}
	return proto.Answer{Choice: proto.ChoiceAccept, Answers: answers}, nil
}

func (t termAsker) info(text string) {
	if !strings.HasSuffix(text, "\n") {
		text += "\n"
	}
	t.p.Print(text)
}

func (t termAsker) print(text string) { t.p.Print(text) }
func (termAsker) dialog() bool        { return false }

// dialogAsker asks through slime's dialog for channel id. Notices still
// go to the channel's terminal, or the log if it has none.
type dialogAsker struct {
	s    *Server
	id   uint32
	term *prompt.Prompter
}

func (d *dialogAsker) ask(q *question) (proto.Answer, error) {
	answers := make(chan proto.Answer, 1)
	d.s.mu.Lock()
	if d.s.state == stateClosing {
		d.s.mu.Unlock()
		return proto.Answer{}, errCancelled
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
		// One answer per question, whatever slime sent.
		a.Answers = append(a.Answers, make([]string, max(0, len(q.Questions)-len(a.Answers)))...)[:len(q.Questions)]
		return a, nil
	case <-d.s.done:
		return proto.Answer{}, errCancelled
	}
}

func (d *dialogAsker) info(text string) {
	d.s.send(d.id, &proto.Info{Text: strings.TrimRight(text, "\r\n")})
}

func (d *dialogAsker) print(text string) {
	if d.term == nil {
		log.Printf("channel %d: %s", d.id, strings.TrimRight(text, "\r\n"))
		return
	}
	d.term.Print(text)
}

func (*dialogAsker) dialog() bool { return true }
