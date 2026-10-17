package persist

import (
	"errors"
	"fmt"
)

// A tab's layout is a tree: panes at the leaves, and n-ary splits whose
// children each have a share of the split in basis points (they sum to
// Whole). Only proportions are stored, and they divide the tab's area in
// pixels: each pane has its own cell size (its own font), so its grid is
// its part of the pixels over its cell. The client measures exact sizes,
// dividers included; the daemon estimates them for panes no window
// shows.

// Whole is 100% in basis points.
const Whole = 10000

// Axis is the way a split lays out its children.
type Axis uint8

const (
	// Row lays children out left to right, sharing the width.
	Row Axis = 1
	// Column stacks children top to bottom, sharing the height.
	Column Axis = 2
)

// Direction says where a new pane goes beside an existing one.
type Direction uint8

const (
	Right Direction = 1
	Down  Direction = 2
	Left  Direction = 3
	Up    Direction = 4
)

func (d Direction) axis() Axis {
	if d == Right || d == Left {
		return Row
	}
	return Column
}

// Node is a pane (Pane != 0) or a split.
type Node struct {
	Pane     uint32
	Axis     Axis
	Children []Child
}

type Child struct {
	Share uint16 // basis points of the parent split
	Node  *Node
}

func leaf(pane uint32) *Node { return &Node{Pane: pane} }

func (n *Node) isLeaf() bool { return n.Pane != 0 }

// Panes lists the tree's panes in order: left to right, top to bottom.
func (n *Node) Panes() []uint32 {
	if n == nil {
		return nil
	}
	if n.isLeaf() {
		return []uint32{n.Pane}
	}
	var ids []uint32
	for _, c := range n.Children {
		ids = append(ids, c.Node.Panes()...)
	}
	return ids
}

// Clone copies the tree, so a copy can go out while the original changes.
func (n *Node) Clone() *Node {
	if n == nil {
		return nil
	}
	c := &Node{Pane: n.Pane, Axis: n.Axis}
	for _, ch := range n.Children {
		c.Children = append(c.Children, Child{ch.Share, ch.Node.Clone()})
	}
	return c
}

// splitNode puts pane beside target, on side dir, taking share basis points
// of target's space. It returns the new root. A split along the same
// axis as target's parent joins that split rather than nesting another.
func splitNode(root *Node, target, pane uint32, dir Direction, share uint16) (*Node, error) {
	if share == 0 || share >= Whole {
		return nil, fmt.Errorf("persist: split share %d out of range", share)
	}
	parent, i := find(root, nil, target)
	if i < 0 {
		return nil, fmt.Errorf("persist: no pane %d in the layout", target)
	}
	axis := dir.axis()
	before := dir == Left || dir == Up
	added := leaf(pane)

	if parent != nil && parent.Axis == axis {
		// Carve the new pane out of target's share.
		old := parent.Children[i].Share
		newShare := uint16(uint32(old) * uint32(share) / Whole)
		if newShare == 0 {
			newShare = 1
		}
		parent.Children[i].Share = old - newShare
		at := i + 1
		if before {
			at = i
		}
		parent.Children = append(parent.Children[:at], append([]Child{{newShare, added}}, parent.Children[at:]...)...)
		return root, nil
	}

	// Nest: target's slot becomes a split of target and the new pane.
	var t *Node
	if parent == nil {
		t = root
	} else {
		t = parent.Children[i].Node
	}
	kids := []Child{{Whole - share, t}, {share, added}}
	if before {
		kids[0], kids[1] = Child{share, added}, Child{Whole - share, t}
	}
	split := &Node{Axis: axis, Children: kids}
	if parent == nil {
		return split, nil
	}
	parent.Children[i].Node = split
	return root, nil
}

// removeNode takes pane out of the tree and returns the new root: nil if it
// was the last. Its siblings grow in proportion to fill its space, and a
// split left with one child is replaced by that child.
func removeNode(root *Node, pane uint32) *Node {
	if root == nil {
		return nil
	}
	if root.isLeaf() {
		if root.Pane == pane {
			return nil
		}
		return root
	}
	parent, i := find(root, nil, pane)
	if i < 0 {
		return root
	}
	parent.Children = append(parent.Children[:i], parent.Children[i+1:]...)
	rebalance(parent)
	return collapse(root)
}

// collapse replaces every split with one child by that child.
func collapse(n *Node) *Node {
	if n.isLeaf() {
		return n
	}
	for i := range n.Children {
		n.Children[i].Node = collapse(n.Children[i].Node)
	}
	if len(n.Children) == 1 {
		return n.Children[0].Node
	}
	return n
}

// rebalance rescales a split's shares to sum to Whole, keeping their
// proportions; the last child takes the rounding.
func rebalance(n *Node) {
	var sum uint32
	for _, c := range n.Children {
		sum += uint32(c.Share)
	}
	if sum == 0 {
		for i := range n.Children {
			n.Children[i].Share = uint16(Whole / len(n.Children))
		}
		sum = uint32(Whole / len(n.Children) * len(n.Children))
	}
	left := uint32(Whole)
	for i := range n.Children {
		if i == len(n.Children)-1 {
			n.Children[i].Share = uint16(left)
			break
		}
		s := uint32(n.Children[i].Share) * Whole / sum
		n.Children[i].Share = uint16(s)
		left -= s
	}
}

// find returns pane's parent and its index there; the parent is nil
// when pane is the root. The index is -1 if pane isn't in the tree.
func find(n, parent *Node, pane uint32) (*Node, int) {
	if n.isLeaf() {
		if n.Pane == pane {
			return parent, 0
		}
		return nil, -1
	}
	for i, c := range n.Children {
		if c.Node.isLeaf() {
			if c.Node.Pane == pane {
				return n, i
			}
			continue
		}
		if p, j := find(c.Node, n, pane); j >= 0 {
			return p, j
		}
	}
	return nil, -1
}

// Validate checks a tree a client sent: every split has at least two
// children of known axis whose shares sum to Whole, and its panes are
// exactly want's, each once.
func Validate(n *Node, want []uint32) error {
	if n == nil {
		return errors.New("persist: empty layout")
	}
	seen := map[uint32]bool{}
	if err := validate(n, seen); err != nil {
		return err
	}
	if len(seen) != len(want) {
		return errors.New("persist: layout panes don't match the tab's")
	}
	for _, id := range want {
		if !seen[id] {
			return errors.New("persist: layout panes don't match the tab's")
		}
	}
	return nil
}

func validate(n *Node, seen map[uint32]bool) error {
	if n.isLeaf() {
		if len(n.Children) != 0 {
			return errors.New("persist: a pane with children")
		}
		if seen[n.Pane] {
			return fmt.Errorf("persist: pane %d twice in the layout", n.Pane)
		}
		seen[n.Pane] = true
		return nil
	}
	if n.Axis != Row && n.Axis != Column {
		return fmt.Errorf("persist: bad split axis %d", n.Axis)
	}
	if len(n.Children) < 2 {
		return errors.New("persist: a split with fewer than two children")
	}
	var sum int
	for _, c := range n.Children {
		if c.Node == nil || c.Share == 0 {
			return errors.New("persist: an empty split child")
		}
		sum += int(c.Share)
		if err := validate(c.Node, seen); err != nil {
			return err
		}
	}
	if sum != Whole {
		return fmt.Errorf("persist: split shares sum to %d, not %d", sum, Whole)
	}
	return nil
}

// Measure estimates each pane's grid in a tab width x height pixels
// across: the shares split the pixels, and each pane divides its part
// by its own cell size (cell returns it), so panes with different fonts
// share space in proportion but get different grids. Dividers are
// ignored; the client accounts for them when it corrects the sizes. A
// split's last child takes the rounding; every pane gets at least 1x1.
func Measure(n *Node, width, height uint32, cell func(pane uint32) (w, h uint32)) map[uint32][2]uint16 {
	out := map[uint32][2]uint16{}
	measure(n, max(width, 1), max(height, 1), cell, out)
	return out
}

func measure(n *Node, width, height uint32, cell func(uint32) (uint32, uint32), out map[uint32][2]uint16) {
	if n == nil {
		return
	}
	if n.isLeaf() {
		cw, ch := cell(n.Pane)
		cols := min(width/max(cw, 1), 0xffff)
		rows := min(height/max(ch, 1), 0xffff)
		out[n.Pane] = [2]uint16{max(uint16(cols), 1), max(uint16(rows), 1)}
		return
	}
	total := width
	if n.Axis == Column {
		total = height
	}
	left := total
	for i, c := range n.Children {
		part := uint32(uint64(total) * uint64(c.Share) / Whole)
		if i == len(n.Children)-1 {
			part = left
		}
		part = min(part, left)
		left -= part
		if n.Axis == Row {
			measure(c.Node, part, height, cell, out)
		} else {
			measure(c.Node, width, part, cell, out)
		}
	}
}
