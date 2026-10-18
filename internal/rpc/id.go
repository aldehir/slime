package rpc

import (
	"errors"
	"fmt"
	"strconv"
	"strings"
)

// Ids are paths. A workspace is numbered by the daemon, a tab by its
// workspace, and a pane by its tab, each from a counter that starts at
// 1 and never reuses a number while the parent lives; so a path is
// never reissued in a daemon's lifetime, and reordering tabs or panes
// changes no id. On the wire a workspace is its number (1), a tab the
// workspace's number and its own ("1.2"), and a pane its tab's and its
// own ("1.2.3"); the parents are prefixes, so a method given the most
// specific id has the rest. Moving a pane to another tab gives it that
// tab's next number; the old path forwards to it (see pane.move).

// TabID names tab N of workspace WS: "WS.N" on the wire.
type TabID struct {
	WS uint32
	N  uint32
}

// PaneID names pane N of tab (WS, Tab): "WS.Tab.N" on the wire.
type PaneID struct {
	WS  uint32
	Tab uint32
	N   uint32
}

var errBadID = errors.New("rpc: bad id")

func (id TabID) IsZero() bool  { return id == TabID{} }
func (id PaneID) IsZero() bool { return id == PaneID{} }

// TabID is the tab the pane is in.
func (id PaneID) TabID() TabID { return TabID{WS: id.WS, N: id.Tab} }

func (id TabID) String() string {
	return strconv.FormatUint(uint64(id.WS), 10) + "." + strconv.FormatUint(uint64(id.N), 10)
}

func (id PaneID) String() string {
	return id.TabID().String() + "." + strconv.FormatUint(uint64(id.N), 10)
}

func (id TabID) MarshalText() ([]byte, error)  { return []byte(id.String()), nil }
func (id PaneID) MarshalText() ([]byte, error) { return []byte(id.String()), nil }

// UnmarshalText reads "WS.N"; an empty string is the zero id (none).
func (id *TabID) UnmarshalText(b []byte) error {
	if len(b) == 0 {
		*id = TabID{}
		return nil
	}
	parts, err := parsePath(string(b), 2)
	if err != nil {
		return err
	}
	*id = TabID{WS: parts[0], N: parts[1]}
	return nil
}

// UnmarshalText reads "WS.Tab.N"; an empty string is the zero id (none).
func (id *PaneID) UnmarshalText(b []byte) error {
	if len(b) == 0 {
		*id = PaneID{}
		return nil
	}
	parts, err := parsePath(string(b), 3)
	if err != nil {
		return err
	}
	*id = PaneID{WS: parts[0], Tab: parts[1], N: parts[2]}
	return nil
}

// ParseTabID reads a tab id from text, as the CLI takes one.
func ParseTabID(s string) (TabID, error) {
	var id TabID
	if err := id.UnmarshalText([]byte(s)); err != nil || id.IsZero() {
		return TabID{}, fmt.Errorf("%w: a tab id is workspace.tab, not %q", errBadID, s)
	}
	return id, nil
}

// ParsePaneID reads a pane id from text, as the CLI takes one.
func ParsePaneID(s string) (PaneID, error) {
	var id PaneID
	if err := id.UnmarshalText([]byte(s)); err != nil || id.IsZero() {
		return PaneID{}, fmt.Errorf("%w: a pane id is workspace.tab.pane, not %q", errBadID, s)
	}
	return id, nil
}

// parsePath reads n dot-separated positive numbers.
func parsePath(s string, n int) ([]uint32, error) {
	parts := strings.Split(s, ".")
	if len(parts) != n {
		return nil, fmt.Errorf("%w: %q has %d parts, not %d", errBadID, s, len(parts), n)
	}
	out := make([]uint32, n)
	for i, p := range parts {
		v, err := strconv.ParseUint(p, 10, 32)
		if err != nil || v == 0 {
			return nil, fmt.Errorf("%w: %q", errBadID, s)
		}
		out[i] = uint32(v)
	}
	return out, nil
}
