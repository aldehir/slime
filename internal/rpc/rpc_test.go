package rpc

import (
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"
)

// A layout tree goes as {"pane": n} and {"split": {...}}: the shape a
// tagged union takes in Zig's std.json, which the GUI parses it with.
func TestNodeJSON(t *testing.T) {
	tree := &Node{Axis: Row, Children: []Child{
		{6000, &Node{Pane: 3}},
		{4000, &Node{Axis: Column, Children: []Child{{5000, &Node{Pane: 4}}, {5000, &Node{Pane: 5}}}}},
	}}
	b, err := json.Marshal(tree)
	if err != nil {
		t.Fatal(err)
	}
	want := `{"split":{"axis":"row","children":[{"share":6000,"node":{"pane":3}},{"share":4000,"node":{"split":{"axis":"column","children":[{"share":5000,"node":{"pane":4}},{"share":5000,"node":{"pane":5}}]}}}]}}`
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
	for _, bad := range []string{`{}`, `{"pane":1,"split":{"axis":"row","children":[]}}`, `{"split":{"axis":"diagonal","children":[]}}`} {
		if err := json.Unmarshal([]byte(bad), &back); err == nil {
			t.Errorf("%s decoded", bad)
		}
	}
	// Nested past MaxDepth.
	deep := `{"pane":1}`
	for range MaxDepth + 2 {
		deep = `{"split":{"axis":"row","children":[{"share":5000,"node":` + deep + `},{"share":5000,"node":{"pane":2}}]}}`
	}
	if err := json.Unmarshal([]byte(deep), &back); !errors.Is(err, ErrTooDeep) {
		t.Errorf("deep layout: %v", err)
	}
}

func TestEnumText(t *testing.T) {
	b, _ := json.Marshal(PaneSplitParams{Pane: 3, Direction: Left, Share: 2500})
	if want := `{"pane":3,"direction":"left","share":2500}`; string(b) != want {
		t.Errorf("split params %s, want %s", b, want)
	}
	var p PaneSplitParams
	if err := json.Unmarshal([]byte(`{"pane":3,"direction":"sideways"}`), &p); err == nil || !strings.Contains(err.Error(), "direction") {
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
	n := Notification{JSONRPC: "2.0", Method: EvPaneExited, Params: json.RawMessage(`{"id":3,"status":0}`)}
	b, _ = json.Marshal(n)
	if want := `{"jsonrpc":"2.0","method":"pane.exited","params":{"id":3,"status":0}}`; string(b) != want {
		t.Errorf("notification %s, want %s", b, want)
	}
}
