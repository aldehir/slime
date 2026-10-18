package daemon

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

// The types (Node, Child, Axis, Direction, Whole) are internal/rpc's,
// shared with the control plane; the algorithms are here.

func leaf(pane PaneID) *Node { return &Node{Pane: pane} }

// splitNode puts pane beside target, on side dir, taking share basis points
// of target's space. It returns the new root. A split along the same
// axis as target's parent joins that split rather than nesting another.
func splitNode(root *Node, target, pane PaneID, dir Direction, share uint16) (*Node, error) {
	if share == 0 || share >= Whole {
		return nil, fmt.Errorf("daemon: split share %d out of range", share)
	}
	parent, i := find(root, nil, target)
	if i < 0 {
		return nil, fmt.Errorf("daemon: no pane %s in the layout", target)
	}
	axis := dir.Axis()
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
		parent.Children = append(parent.Children[:at], append([]Child{{Share: newShare, Node: added}}, parent.Children[at:]...)...)
		return root, nil
	}

	// Nest: target's slot becomes a split of target and the new pane.
	var t *Node
	if parent == nil {
		t = root
	} else {
		t = parent.Children[i].Node
	}
	kids := []Child{{Share: Whole - share, Node: t}, {Share: share, Node: added}}
	if before {
		kids[0], kids[1] = Child{Share: share, Node: added}, Child{Share: Whole - share, Node: t}
	}
	split := &Node{Axis: axis, Children: kids}
	if parent == nil {
		return split, nil
	}
	parent.Children[i].Node = split
	return root, nil
}

// joinEdge puts pane along side dir of the whole tree, taking an equal
// share of a root split that runs the same way, else half of a new
// split over the root. It returns the new root.
func joinEdge(root *Node, pane PaneID, dir Direction) *Node {
	axis := dir.Axis()
	before := dir == Left || dir == Up
	added := leaf(pane)
	if !root.IsLeaf() && root.Axis == axis {
		n := len(root.Children) + 1
		share := Whole / n
		// The others shrink to make room, keeping their proportions.
		for i := range root.Children {
			root.Children[i].Share = uint16(uint32(root.Children[i].Share) * uint32(Whole-share) / Whole)
		}
		if before {
			root.Children = append([]Child{{Share: uint16(share), Node: added}}, root.Children...)
		} else {
			root.Children = append(root.Children, Child{Share: uint16(share), Node: added})
		}
		rebalance(root)
		return root
	}
	kids := []Child{{Share: Whole / 2, Node: root}, {Share: Whole / 2, Node: added}}
	if before {
		kids[0], kids[1] = kids[1], kids[0]
	}
	return &Node{Axis: axis, Children: kids}
}

// removeNode takes pane out of the tree and returns the new root: nil if it
// was the last. Its siblings grow in proportion to fill its space, and a
// split left with one child is replaced by that child.
func removeNode(root *Node, pane PaneID) *Node {
	if root == nil {
		return nil
	}
	if root.IsLeaf() {
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
	if n.IsLeaf() {
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
func find(n, parent *Node, pane PaneID) (*Node, int) {
	if n.IsLeaf() {
		if n.Pane == pane {
			return parent, 0
		}
		return nil, -1
	}
	for i, c := range n.Children {
		if c.Node.IsLeaf() {
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
func Validate(n *Node, want []PaneID) error {
	if n == nil {
		return errors.New("daemon: empty layout")
	}
	seen := map[PaneID]bool{}
	if err := validate(n, seen); err != nil {
		return err
	}
	if len(seen) != len(want) {
		return errors.New("daemon: layout panes don't match the tab's")
	}
	for _, id := range want {
		if !seen[id] {
			return errors.New("daemon: layout panes don't match the tab's")
		}
	}
	return nil
}

func validate(n *Node, seen map[PaneID]bool) error {
	if n.IsLeaf() {
		if len(n.Children) != 0 {
			return errors.New("daemon: a pane with children")
		}
		if seen[n.Pane] {
			return fmt.Errorf("daemon: pane %s twice in the layout", n.Pane)
		}
		seen[n.Pane] = true
		return nil
	}
	if n.Axis != Row && n.Axis != Column {
		return fmt.Errorf("daemon: bad split axis %d", n.Axis)
	}
	if len(n.Children) < 2 {
		return errors.New("daemon: a split with fewer than two children")
	}
	var sum int
	for _, c := range n.Children {
		if c.Node == nil || c.Share == 0 {
			return errors.New("daemon: an empty split child")
		}
		sum += int(c.Share)
		if err := validate(c.Node, seen); err != nil {
			return err
		}
	}
	if sum != Whole {
		return fmt.Errorf("daemon: split shares sum to %d, not %d", sum, Whole)
	}
	return nil
}

// Measure estimates each pane's grid in a tab width x height pixels
// across: the shares split the pixels, and each pane divides its part
// by its own cell size (cell returns it), so panes with different fonts
// share space in proportion but get different grids. Dividers are
// ignored; the client accounts for them when it corrects the sizes. A
// split's last child takes the rounding; every pane gets at least 1x1.
func Measure(n *Node, width, height uint32, cell func(pane PaneID) (w, h uint32)) map[PaneID][2]uint16 {
	out := map[PaneID][2]uint16{}
	measure(n, max(width, 1), max(height, 1), cell, out)
	return out
}

func measure(n *Node, width, height uint32, cell func(PaneID) (uint32, uint32), out map[PaneID][2]uint16) {
	if n == nil {
		return
	}
	if n.IsLeaf() {
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
