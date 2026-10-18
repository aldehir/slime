package daemon

import (
	"fmt"
	"strings"
	"testing"
)

// show prints a tree compactly: panes by their number in the tab,
// splits as r(share:node ...) or c(...).
func show(n *Node) string {
	if n == nil {
		return "nil"
	}
	if n.IsLeaf() {
		return fmt.Sprint(n.Pane.N)
	}
	var b strings.Builder
	if n.Axis == Row {
		b.WriteString("r(")
	} else {
		b.WriteString("c(")
	}
	for i, c := range n.Children {
		if i > 0 {
			b.WriteString(" ")
		}
		fmt.Fprintf(&b, "%d:%s", c.Share, show(c.Node))
	}
	b.WriteString(")")
	return b.String()
}

// pid is pane n of the tests' one tab.
func pid(n uint32) PaneID { return PaneID{WS: 1, Tab: 1, N: n} }

func pids(ns ...uint32) []PaneID {
	out := make([]PaneID, len(ns))
	for i, n := range ns {
		out[i] = pid(n)
	}
	return out
}

func mustSplit(t *testing.T, root *Node, target, pane uint32, dir Direction, share uint16) *Node {
	t.Helper()
	r, err := splitNode(root, pid(target), pid(pane), dir, share)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestSplit(t *testing.T) {
	r := leaf(pid(1))
	r = mustSplit(t, r, 1, 2, Right, 5000)
	if got := show(r); got != "r(5000:1 5000:2)" {
		t.Errorf("right of the root: %s", got)
	}
	// Same axis joins the split, carving from the target's share.
	r = mustSplit(t, r, 2, 3, Right, 5000)
	if got := show(r); got != "r(5000:1 2500:2 2500:3)" {
		t.Errorf("right again: %s", got)
	}
	// The other axis nests.
	r = mustSplit(t, r, 1, 4, Down, 3000)
	if got := show(r); got != "r(5000:c(7000:1 3000:4) 2500:2 2500:3)" {
		t.Errorf("down: %s", got)
	}
	// Left and up go before.
	r = mustSplit(t, r, 3, 5, Left, 4000)
	if got := show(r); got != "r(5000:c(7000:1 3000:4) 2500:2 1000:5 1500:3)" {
		t.Errorf("left: %s", got)
	}
	r = mustSplit(t, r, 2, 6, Up, 5000)
	if got := show(r); got != "r(5000:c(7000:1 3000:4) 2500:c(5000:6 5000:2) 1000:5 1500:3)" {
		t.Errorf("up: %s", got)
	}
	if err := Validate(r, pids(1, 2, 3, 4, 5, 6)); err != nil {
		t.Errorf("result invalid: %v", err)
	}
	if fmt.Sprint(r.Panes()) != fmt.Sprint(pids(1, 4, 6, 2, 5, 3)) {
		t.Errorf("order %v", r.Panes())
	}
	if _, err := splitNode(r, pid(99), pid(7), Right, 5000); err == nil {
		t.Error("split of a missing pane")
	}
	if _, err := splitNode(r, pid(1), pid(7), Right, Whole); err == nil {
		t.Error("split taking everything")
	}
}

func TestRemove(t *testing.T) {
	r := leaf(pid(1))
	r = mustSplit(t, r, 1, 2, Right, 5000)
	r = mustSplit(t, r, 2, 3, Right, 5000)
	r = mustSplit(t, r, 1, 4, Down, 5000)
	// r(5000:c(5000:1 5000:4) 2500:2 2500:3)

	r = removeNode(r, pid(2))
	if got := show(r); got != "r(6666:c(5000:1 5000:4) 3334:3)" {
		t.Errorf("siblings grow in proportion: %s", got)
	}
	r = removeNode(r, pid(4))
	if got := show(r); got != "r(6666:1 3334:3)" {
		t.Errorf("a one-child split collapses: %s", got)
	}
	r = removeNode(r, pid(99))
	if got := show(r); got != "r(6666:1 3334:3)" {
		t.Errorf("removing a missing pane: %s", got)
	}
	r = removeNode(r, pid(1))
	if got := show(r); got != "3" {
		t.Errorf("down to one pane: %s", got)
	}
	if r = removeNode(r, pid(3)); r != nil {
		t.Errorf("last pane: %s", show(r))
	}
}

// TestSharesDontDrift splits and removes many times; every split's
// shares must still sum to exactly Whole.
func TestSharesDontDrift(t *testing.T) {
	r := leaf(pid(1))
	ids := []uint32{1}
	next := uint32(2)
	for i := range 300 {
		target := ids[(i*7)%len(ids)]
		dirs := []Direction{Right, Down, Left, Up}
		r = mustSplit(t, r, target, next, dirs[i%4], uint16(1000+(i*37)%8000))
		ids = append(ids, next)
		next++
		if i%3 == 2 {
			gone := ids[(i*5)%len(ids)]
			r = removeNode(r, pid(gone))
			for j, id := range ids {
				if id == gone {
					ids = append(ids[:j], ids[j+1:]...)
					break
				}
			}
		}
		if err := Validate(r, pids(ids...)); err != nil {
			t.Fatalf("step %d: %v\n%s", i, err, show(r))
		}
	}
}

func TestValidate(t *testing.T) {
	good := &Node{Axis: Row, Children: []Child{{4000, leaf(pid(1))}, {6000, leaf(pid(2))}}}
	if err := Validate(good, pids(2, 1)); err != nil {
		t.Errorf("good tree: %v", err)
	}
	bad := map[string]*Node{
		"sum":       {Axis: Row, Children: []Child{{4000, leaf(pid(1))}, {5000, leaf(pid(2))}}},
		"one child": {Axis: Row, Children: []Child{{Whole, leaf(pid(1))}}},
		"axis":      {Axis: 9, Children: []Child{{5000, leaf(pid(1))}, {5000, leaf(pid(2))}}},
		"duplicate": {Axis: Row, Children: []Child{{5000, leaf(pid(1))}, {5000, leaf(pid(1))}}},
		"zero":      {Axis: Row, Children: []Child{{0, leaf(pid(1))}, {Whole, leaf(pid(2))}}},
	}
	for name, n := range bad {
		if err := Validate(n, pids(1, 2)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := Validate(good, pids(1, 3)); err == nil {
		t.Error("different panes accepted")
	}
}

func TestMeasure(t *testing.T) {
	r := leaf(pid(1))
	r = mustSplit(t, r, 1, 2, Right, 2500)
	r = mustSplit(t, r, 1, 3, Down, 5000)
	unit := func(PaneID) (uint32, uint32) { return 1, 1 }
	// r(7500:c(5000:1 5000:3) 2500:2) in 101x41 one-pixel cells.
	m := Measure(r, 101, 41, unit)
	want := map[PaneID][2]uint16{pid(1): {75, 20}, pid(3): {75, 21}, pid(2): {26, 41}}
	if fmt.Sprint(m) != fmt.Sprint(want) {
		t.Errorf("sizes %v, want %v", m, want)
	}
	// Too small to share: everyone still gets a cell.
	tiny := Measure(r, 1, 1, unit)
	for id, s := range tiny {
		if s[0] < 1 || s[1] < 1 {
			t.Errorf("pane %s got %v", id, s)
		}
	}
}

// TestMeasureFonts: the shares divide pixels, and each pane's grid
// follows its own cell size.
func TestMeasureFonts(t *testing.T) {
	r := mustSplit(t, leaf(pid(1)), 1, 2, Right, 5000)
	cells := map[PaneID][2]uint32{pid(1): {10, 20}, pid(2): {20, 40}}
	m := Measure(r, 1000, 800, func(id PaneID) (uint32, uint32) { return cells[id][0], cells[id][1] })
	want := map[PaneID][2]uint16{pid(1): {50, 40}, pid(2): {25, 20}}
	if fmt.Sprint(m) != fmt.Sprint(want) {
		t.Errorf("sizes %v, want %v", m, want)
	}
}
