package persist

import (
	"strings"

	"github.com/aldehir/slime/ssh/internal/vt"
)

// maxStatusRecords is the Program Status Protocol's minimum. When it's
// full, the record updated longest ago makes way.
const maxStatusRecords = 64

// programStatus keeps what the programs in a pane say they're doing
// (OSC 7501), as slime does (src/ProgramStatus.zig), so a window
// attaching later sees it: each report sets one record by its id,
// replacing it whole; clear removes a record and those under it; a new
// shell prompt drops what was in progress.
type programStatus struct {
	recs  []statusRecord
	clock uint64
}

type statusRecord struct {
	StatusRecord
	updated uint64
}

func (s *programStatus) report(r vt.Status) {
	if r.State == vt.StatusClear {
		s.clear(r.ID)
		return
	}
	if r.State > vt.StatusError {
		return
	}
	s.clock++
	rec := StatusRecord{ID: r.ID, State: uint8(r.State), Progress: r.Progress}
	for i := range s.recs {
		if s.recs[i].ID == r.ID {
			s.recs[i] = statusRecord{rec, s.clock}
			return
		}
	}
	if len(s.recs) < maxStatusRecords {
		s.recs = append(s.recs, statusRecord{rec, s.clock})
		return
	}
	oldest := 0
	for i := range s.recs {
		if s.recs[i].updated < s.recs[oldest].updated {
			oldest = i
		}
	}
	s.recs[oldest] = statusRecord{rec, s.clock}
}

// clear removes the record id and those under it, or all with no id.
func (s *programStatus) clear(id string) {
	if id == "" {
		s.recs = s.recs[:0]
		return
	}
	s.recs = deleteIf(s.recs, func(r statusRecord) bool {
		return r.ID == id || strings.HasPrefix(r.ID, id+"/")
	})
}

// promptStarted drops work in progress: its program has exited.
func (s *programStatus) promptStarted() {
	s.recs = deleteIf(s.recs, func(r statusRecord) bool {
		switch vt.StatusState(r.State) {
		case vt.StatusWorking, vt.StatusBlocked, vt.StatusIdle:
			return true
		}
		return false
	})
}

// records copies the records, oldest update first, so a client
// restoring them in order ends with the same order.
func (s *programStatus) records() []StatusRecord {
	recs := append([]statusRecord(nil), s.recs...)
	for i := 1; i < len(recs); i++ {
		for j := i; j > 0 && recs[j].updated < recs[j-1].updated; j-- {
			recs[j], recs[j-1] = recs[j-1], recs[j]
		}
	}
	out := make([]StatusRecord, len(recs))
	for i, r := range recs {
		out[i] = r.StatusRecord
	}
	return out
}

func deleteIf(recs []statusRecord, gone func(statusRecord) bool) []statusRecord {
	kept := recs[:0]
	for _, r := range recs {
		if !gone(r) {
			kept = append(kept, r)
		}
	}
	return kept
}
