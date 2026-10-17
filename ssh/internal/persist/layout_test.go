package persist

import (
	"fmt"
	"strings"
	"testing"
)

// show prints a tree compactly: panes as numbers, splits as
// r(share:node ...) or c(...).
func show(n *Node) string {
	if n == nil {
		return "nil"
	}
	if n.isLeaf() {
		return fmt.Sprint(n.Pane)
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

func mustSplit(t *testing.T, root *Node, target, pane uint32, dir Direction, share uint16) *Node {
	t.Helper()
	r, err := splitNode(root, target, pane, dir, share)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestSplit(t *testing.T) {
	r := leaf(1)
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
	if err := Validate(r, []uint32{1, 2, 3, 4, 5, 6}); err != nil {
		t.Errorf("result invalid: %v", err)
	}
	if fmt.Sprint(r.Panes()) != "[1 4 6 2 5 3]" {
		t.Errorf("order %v", r.Panes())
	}
	if _, err := splitNode(r, 99, 7, Right, 5000); err == nil {
		t.Error("split of a missing pane")
	}
	if _, err := splitNode(r, 1, 7, Right, Whole); err == nil {
		t.Error("split taking everything")
	}
}

func TestRemove(t *testing.T) {
	r := leaf(1)
	r = mustSplit(t, r, 1, 2, Right, 5000)
	r = mustSplit(t, r, 2, 3, Right, 5000)
	r = mustSplit(t, r, 1, 4, Down, 5000)
	// r(5000:c(5000:1 5000:4) 2500:2 2500:3)

	r = removeNode(r, 2)
	if got := show(r); got != "r(6666:c(5000:1 5000:4) 3334:3)" {
		t.Errorf("siblings grow in proportion: %s", got)
	}
	r = removeNode(r, 4)
	if got := show(r); got != "r(6666:1 3334:3)" {
		t.Errorf("a one-child split collapses: %s", got)
	}
	r = removeNode(r, 99)
	if got := show(r); got != "r(6666:1 3334:3)" {
		t.Errorf("removing a missing pane: %s", got)
	}
	r = removeNode(r, 1)
	if got := show(r); got != "3" {
		t.Errorf("down to one pane: %s", got)
	}
	if r = removeNode(r, 3); r != nil {
		t.Errorf("last pane: %s", show(r))
	}
}

// TestSharesDontDrift splits and removes many times; every split's
// shares must still sum to exactly Whole.
func TestSharesDontDrift(t *testing.T) {
	r := leaf(1)
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
			r = removeNode(r, gone)
			for j, id := range ids {
				if id == gone {
					ids = append(ids[:j], ids[j+1:]...)
					break
				}
			}
		}
		if err := Validate(r, ids); err != nil {
			t.Fatalf("step %d: %v\n%s", i, err, show(r))
		}
	}
}

func TestValidate(t *testing.T) {
	good := &Node{Axis: Row, Children: []Child{{4000, leaf(1)}, {6000, leaf(2)}}}
	if err := Validate(good, []uint32{2, 1}); err != nil {
		t.Errorf("good tree: %v", err)
	}
	bad := map[string]*Node{
		"sum":       {Axis: Row, Children: []Child{{4000, leaf(1)}, {5000, leaf(2)}}},
		"one child": {Axis: Row, Children: []Child{{Whole, leaf(1)}}},
		"axis":      {Axis: 9, Children: []Child{{5000, leaf(1)}, {5000, leaf(2)}}},
		"duplicate": {Axis: Row, Children: []Child{{5000, leaf(1)}, {5000, leaf(1)}}},
		"zero":      {Axis: Row, Children: []Child{{0, leaf(1)}, {Whole, leaf(2)}}},
	}
	for name, n := range bad {
		if err := Validate(n, []uint32{1, 2}); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
	if err := Validate(good, []uint32{1, 3}); err == nil {
		t.Error("different panes accepted")
	}
}

func TestMeasure(t *testing.T) {
	r := leaf(1)
	r = mustSplit(t, r, 1, 2, Right, 2500)
	r = mustSplit(t, r, 1, 3, Down, 5000)
	unit := func(uint32) (uint32, uint32) { return 1, 1 }
	// r(7500:c(5000:1 5000:3) 2500:2) in 101x41 one-pixel cells.
	m := Measure(r, 101, 41, unit)
	want := map[uint32][2]uint16{1: {75, 20}, 3: {75, 21}, 2: {26, 41}}
	if fmt.Sprint(m) != fmt.Sprint(want) {
		t.Errorf("sizes %v, want %v", m, want)
	}
	// Too small to share: everyone still gets a cell.
	tiny := Measure(r, 1, 1, unit)
	for id, s := range tiny {
		if s[0] < 1 || s[1] < 1 {
			t.Errorf("pane %d got %v", id, s)
		}
	}
}

// TestMeasureFonts: the shares divide pixels, and each pane's grid
// follows its own cell size.
func TestMeasureFonts(t *testing.T) {
	r := mustSplit(t, leaf(1), 1, 2, Right, 5000)
	cells := map[uint32][2]uint32{1: {10, 20}, 2: {20, 40}}
	m := Measure(r, 1000, 800, func(id uint32) (uint32, uint32) { return cells[id][0], cells[id][1] })
	want := map[uint32][2]uint16{1: {50, 40}, 2: {25, 20}}
	if fmt.Sprint(m) != fmt.Sprint(want) {
		t.Errorf("sizes %v, want %v", m, want)
	}
}
