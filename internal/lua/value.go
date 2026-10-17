package lua

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strconv"

	glua "github.com/yuin/gopher-lua"
)

// Values cross between Lua and the control plane as JSON: a call's
// params table becomes the method's params object, and its result
// comes back as a table. The rules are rxi/json's, except that an
// empty table is an object, since params and specs are objects far
// more often than lists.
//
// Lua to JSON: nil, booleans, numbers, and strings are themselves (a
// number that is an integer prints as one); a table whose keys are
// exactly 1..n is an array; any other table is an object, with number
// keys as strings; functions, userdata, threads, and cycles are
// errors.
//
// JSON to Lua: null is nil, arrays are tables 1..n, and objects are
// tables keyed by string.

// maxDepth bounds a table's nesting on its way to JSON: a cycle is
// caught by the visited set, but a deep tree needn't recurse forever.
const maxDepth = 64

var errTooDeep = errors.New("nested too deep")

// toGo converts lv to what encoding/json marshals.
func toGo(lv glua.LValue) (any, error) {
	return toGoDepth(lv, map[*glua.LTable]bool{}, 0)
}

func toGoDepth(lv glua.LValue, seen map[*glua.LTable]bool, depth int) (any, error) {
	switch v := lv.(type) {
	case *glua.LNilType, nil:
		return nil, nil
	case glua.LBool:
		return bool(v), nil
	case glua.LNumber:
		return float64(v), nil
	case glua.LString:
		return string(v), nil
	case *glua.LTable:
		if depth > maxDepth {
			return nil, errTooDeep
		}
		if seen[v] {
			return nil, errors.New("a table that contains itself")
		}
		seen[v] = true
		defer delete(seen, v)
		if n := v.Len(); n > 0 && isArray(v, n) {
			out := make([]any, n)
			for i := 1; i <= n; i++ {
				x, err := toGoDepth(v.RawGetInt(i), seen, depth+1)
				if err != nil {
					return nil, err
				}
				out[i-1] = x
			}
			return out, nil
		}
		out := map[string]any{}
		var err error
		v.ForEach(func(k, val glua.LValue) {
			if err != nil {
				return
			}
			var key string
			switch k := k.(type) {
			case glua.LString:
				key = string(k)
			case glua.LNumber:
				key = numberString(float64(k))
			default:
				err = fmt.Errorf("a table key of type %s", k.Type())
				return
			}
			x, e := toGoDepth(val, seen, depth+1)
			if e != nil {
				err = e
				return
			}
			out[key] = x
		})
		return out, err
	default:
		return nil, fmt.Errorf("a %s can't be JSON", lv.Type())
	}
}

// isArray says whether t, with n sequential entries, has no other keys.
func isArray(t *glua.LTable, n int) bool {
	count := 0
	t.ForEach(func(k, _ glua.LValue) { count++ })
	return count == n
}

func numberString(f float64) string {
	if f == math.Trunc(f) && math.Abs(f) < 1e15 {
		return strconv.FormatInt(int64(f), 10)
	}
	return strconv.FormatFloat(f, 'g', -1, 64)
}

// toJSON marshals lv. nil marshals as null.
func toJSON(lv glua.LValue) (json.RawMessage, error) {
	v, err := toGo(lv)
	if err != nil {
		return nil, err
	}
	return json.Marshal(v)
}

// fromJSON unmarshals b to a Lua value.
func fromJSON(L *glua.LState, b []byte) (glua.LValue, error) {
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	return fromGo(L, v), nil
}

// fromGo converts what encoding/json unmarshals to a Lua value.
func fromGo(L *glua.LState, v any) glua.LValue {
	switch v := v.(type) {
	case nil:
		return glua.LNil
	case bool:
		return glua.LBool(v)
	case float64:
		return glua.LNumber(v)
	case string:
		return glua.LString(v)
	case []any:
		t := L.NewTable()
		for _, x := range v {
			t.Append(fromGo(L, x))
		}
		return t
	case map[string]any:
		t := L.NewTable()
		for k, x := range v {
			t.RawSetString(k, fromGo(L, x))
		}
		return t
	}
	return glua.LNil
}
