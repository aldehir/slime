package daemon

import (
	"fmt"
	"testing"

	"github.com/aldehir/slime/internal/vt"
)

func TestProgramStatus(t *testing.T) {
	var s programStatus
	s.report(vt.Status{State: vt.StatusWorking, Progress: 40})
	s.report(vt.Status{State: vt.StatusBlocked, Progress: -1, ID: "deploy/eu"})
	s.report(vt.Status{State: vt.StatusDone, Progress: -1, ID: "deployed"})
	// A report replaces its record whole.
	s.report(vt.Status{State: vt.StatusWorking, Progress: -1})
	want := []StatusRecord{{"deploy/eu", 3, -1}, {"deployed", 2, -1}, {"", 1, -1}}
	if got := s.records(); fmt.Sprint(got) != fmt.Sprint(want) {
		t.Fatalf("records: got %v, want %v", got, want)
	}

	// Clearing a record clears those under it, and nothing else.
	s.report(vt.Status{State: vt.StatusClear, ID: "deploy"})
	if got := len(s.records()); got != 2 {
		t.Fatalf("after clear: %d records, want 2", got)
	}
	// A new prompt drops work in progress; done stays.
	s.promptStarted()
	if got := s.records(); len(got) != 1 || got[0].ID != "deployed" {
		t.Fatalf("after prompt: %v", got)
	}

	// When full, the record updated longest ago goes.
	s.report(vt.Status{State: vt.StatusClear})
	for i := range maxStatusRecords + 1 {
		s.report(vt.Status{State: vt.StatusIdle, Progress: -1, ID: fmt.Sprintf("r%d", i)})
	}
	recs := s.records()
	if len(recs) != maxStatusRecords || recs[0].ID != "r1" {
		t.Fatalf("full: %d records, first %q", len(recs), recs[0].ID)
	}
}
