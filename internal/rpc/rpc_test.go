package rpc

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

func pane(ws, tab, n uint32) PaneID { return PaneID{WS: ws, Tab: tab, N: n} }

// A layout tree goes as {"pane": "w.t.n"} and {"split": {...}}: the
// shape a tagged union takes in Zig's std.json, which the GUI parses it
// with.
func TestNodeJSON(t *testing.T) {
	tree := &Node{Axis: Row, Children: []Child{
		{6000, &Node{Pane: pane(1, 2, 3)}},
		{4000, &Node{Axis: Column, Children: []Child{{5000, &Node{Pane: pane(1, 2, 4)}}, {5000, &Node{Pane: pane(1, 2, 5)}}}}},
	}}
	b, err := json.Marshal(tree)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"split":{"axis":"row","children":[{"share":6000,"node":{"pane":"1.2.3"}},{"share":4000,"node":{"split":{"axis":"column","children":[{"share":5000,"node":{"pane":"1.2.4"}},{"share":5000,"node":{"pane":"1.2.5"}}]}}}]}}`
	if string(b) != want {
		t.Errorf("marshalled\n%s\nwant\n%s", b, want)
	}
	var back Node
	if err := json.Unmarshal(b, &back); err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(&back, tree) {
		t.Errorf("round trip %+v, want %+v", &back, tree)
	}
	for _, bad := range []string{`{}`, `{"pane":""}`, `{"pane":1}`, `{"pane":"1.2"}`, `{"pane":"1.2.3","split":{"axis":"row","children":[]}}`, `{"split":{"axis":"diagonal","children":[]}}`} {
		if err := json.Unmarshal([]byte(bad), &back); err == nil {
			t.Errorf("%s decoded", bad)
		}
	}
	// Nested past MaxDepth.
	deep := `{"pane":"1.1.1"}`
	for range MaxDepth + 2 {
		deep = `{"split":{"axis":"row","children":[{"share":5000,"node":` + deep + `},{"share":5000,"node":{"pane":"1.1.2"}}]}}`
	}
	if err := json.Unmarshal([]byte(deep), &back); !errors.Is(err, ErrTooDeep) {
		t.Errorf("deep layout: %v", err)
	}
}

// Ids are paths: a tab is "w.n", a pane "w.t.n", and an empty string
// is none. The zero id is left out of params and results.
func TestIDs(t *testing.T) {
	id := pane(1, 2, 3)
	if id.String() != "1.2.3" || id.TabID().String() != "1.2" || id.TabID() != (TabID{WS: 1, N: 2}) {
		t.Errorf("id %s, tab %s", id, id.TabID())
	}
	b, _ := json.Marshal(Tab{ID: TabID{WS: 1, N: 2}, Tree: &Node{Pane: id}, Focus: id})
	if want := `{"id":"1.2","tree":{"pane":"1.2.3"},"focus":"1.2.3"}`; string(b) != want {
		t.Errorf("tab %s, want %s", b, want)
	}
	var tab Tab
	if err := json.Unmarshal([]byte(`{"id":"1.2","tree":{"pane":"1.2.3"},"zoomed":""}`), &tab); err != nil || tab.ID != (TabID{WS: 1, N: 2}) || tab.Focus != (PaneID{}) || tab.Zoomed != (PaneID{}) {
		t.Errorf("tab %+v: %v", tab, err)
	}
	for _, good := range []string{"1.2.3", "10.20.30"} {
		if _, err := ParsePaneID(good); err != nil {
			t.Errorf("%q: %v", good, err)
		}
	}
	for _, bad := range []string{"", "0", "1", "1.2", "1.2.0", "0.2.3", "1.2.3.4", "a.b.c", "1..3", " 1.2.3"} {
		if _, err := ParsePaneID(bad); err == nil {
			t.Errorf("%q parsed as a pane", bad)
		}
	}
	for _, bad := range []string{"", "1", "1.2.3", "1.0", "x.1"} {
		if _, err := ParseTabID(bad); err == nil {
			t.Errorf("%q parsed as a tab", bad)
		}
	}
	var p PaneParams
	if err := json.Unmarshal([]byte(`{"id":"1.2"}`), &p); err == nil {
		t.Error("a tab id decoded as a pane id")
	}
	if err := json.Unmarshal([]byte(`{"id":3}`), &p); err == nil {
		t.Error("a number decoded as a pane id")
	}
}

func TestEnumText(t *testing.T) {
	b, _ := json.Marshal(PaneSplitParams{Pane: pane(1, 1, 3), Direction: Left, Share: 2500})
	if want := `{"pane":"1.1.3","direction":"left","share":2500}`; string(b) != want {
		t.Errorf("split params %s, want %s", b, want)
	}
	var p PaneSplitParams
	if err := json.Unmarshal([]byte(`{"pane":"1.1.3","direction":"sideways"}`), &p); err == nil || !strings.Contains(err.Error(), "direction") {
		t.Errorf("bad direction: %v", err)
	}
	if Right.Axis() != Row || Up.Axis() != Column {
		t.Error("direction axes")
	}
}

func TestEnvelopes(t *testing.T) {
	req := Request{JSONRPC: "2.0", ID: 1, Method: TabNew, Params: json.RawMessage(`{"workspace":2}`)}
	b, _ := json.Marshal(req)
	if want := `{"jsonrpc":"2.0","id":1,"method":"tab.new","params":{"workspace":2}}`; string(b) != want {
		t.Errorf("request %s, want %s", b, want)
	}
	res := Response{JSONRPC: "2.0", ID: 1, Error: &Error{Code: CodeNotFound, Message: "no such workspace"}}
	b, _ = json.Marshal(res)
	if want := `{"jsonrpc":"2.0","id":1,"error":{"code":1000,"message":"no such workspace"}}`; string(b) != want {
		t.Errorf("response %s, want %s", b, want)
	}
	n := Notification{JSONRPC: "2.0", Method: EvPaneExited, Params: json.RawMessage(`{"id":"1.1.3","status":0}`)}
	b, _ = json.Marshal(n)
	if want := `{"jsonrpc":"2.0","method":"pane.exited","params":{"id":"1.1.3","status":0}}`; string(b) != want {
		t.Errorf("notification %s, want %s", b, want)
	}
}
