package vt

import (
	"context"
	"fmt"

	"github.com/tetratelabs/wazero"
)

// Events are what a terminal reports while it processes output. They're
// delivered after Write returns, never from inside libghostty-vt, so a
// handler may call the Terminal's methods. Nil fields are skipped.
type Events struct {
	// Reply carries bytes the terminal would send back to the program:
	// answers to DA, DSR, DECRQM, XTVERSION, size queries, and the like.
	// The slice is only valid during the call.
	Reply func(p []byte)

	Bell func()

	// TitleChanged and PwdChanged fire once per Write that changed them;
	// read the new value with Title or Pwd.
	TitleChanged func()
	PwdChanged   func()
}

// Callback options (GhosttyTerminalOption) and the order the trampoline
// installs them in.
var callbacks = []struct {
	name string
	opt  uint64
	typ  byte // index into the trampoline's types
}{
	{"write_pty", 1, 0},
	{"bell", 2, 1},
	{"title_changed", 5, 1},
	{"pwd_changed", 25, 1},
	{"device_attributes", 8, 2},
	{"size", 6, 2},
}

const optUserdata = 0

// pending is what callbacks recorded during one Write.
type pending struct {
	reply []byte
	bell  int
	title bool
	pwd   bool
}

// Primary and secondary device attributes, as slime answers them:
// libghostty-vt's defaults (VT220, ANSI color).
const (
	daConformance = 62
	daFeatureANSI = 22
	daDeviceType  = 1

	// GhosttyDeviceAttributes, wasm32 layout (TestCallbackLayouts).
	daOffFeatures    = 2
	daOffNumFeatures = 132
	daOffSecondary   = 136
	daSize           = 148
)

// hostModule defines the callbacks libghostty-vt calls. Each finds its
// Terminal by the userdata, which is the terminal's id.
func (r *Runtime) hostModule(ctx context.Context) error {
	b := r.rt.NewHostModuleBuilder("slime")
	b.NewFunctionBuilder().
		WithFunc(func(_ context.Context, _, ud, ptr, n uint32) {
			if t := r.lookup(ud); t != nil {
				if p, ok := t.mem.Read(ptr, n); ok {
					t.pend.reply = append(t.pend.reply, p...)
				}
			}
		}).Export("write_pty")
	b.NewFunctionBuilder().
		WithFunc(func(_ context.Context, _, ud uint32) {
			if t := r.lookup(ud); t != nil {
				t.pend.bell++
			}
		}).Export("bell")
	b.NewFunctionBuilder().
		WithFunc(func(_ context.Context, _, ud uint32) {
			if t := r.lookup(ud); t != nil {
				t.pend.title = true
			}
		}).Export("title_changed")
	b.NewFunctionBuilder().
		WithFunc(func(_ context.Context, _, ud uint32) {
			if t := r.lookup(ud); t != nil {
				t.pend.pwd = true
			}
		}).Export("pwd_changed")
	b.NewFunctionBuilder().
		WithFunc(func(_ context.Context, _, ud, out uint32) uint32 {
			t := r.lookup(ud)
			if t == nil {
				return 0
			}
			t.mem.Write(out, make([]byte, daSize))
			t.mem.WriteUint16Le(out, daConformance)
			t.mem.WriteUint16Le(out+daOffFeatures, daFeatureANSI)
			t.mem.WriteUint32Le(out+daOffNumFeatures, 1)
			t.mem.WriteUint16Le(out+daOffSecondary, daDeviceType)
			return 1
		}).Export("device_attributes")
	b.NewFunctionBuilder().
		WithFunc(func(_ context.Context, _, ud, out uint32) uint32 {
			t := r.lookup(ud)
			if t == nil {
				return 0
			}
			// GhosttySizeReportSize: rows, columns, cell width, height.
			t.mem.WriteUint16Le(out, t.rows)
			t.mem.WriteUint16Le(out+2, t.cols)
			t.mem.WriteUint32Le(out+4, t.cellW)
			t.mem.WriteUint32Le(out+8, t.cellH)
			return 1
		}).Export("size")
	_, err := b.Instantiate(ctx)
	return err
}

func (r *Runtime) lookup(id uint32) *Terminal {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.terms[id]
}

// installCallbacks puts the host callbacks into the instance's function
// table and points the terminal's options at them.
//
// wazero gives the host no way to write a guest's table, so a trampoline
// module, assembled per instance because it names the instance in its
// imports, imports the table and the host functions and grows the table
// by one entry for each. libghostty-vt patches its table to be growable
// for this.
func (t *Terminal) installCallbacks(r *Runtime, name string) error {
	compiled, err := r.rt.CompileModule(t.ctx, trampoline(name))
	if err != nil {
		return fmt.Errorf("vt: trampoline: %w", err)
	}
	defer compiled.Close(t.ctx)
	tramp, err := r.rt.InstantiateModule(t.ctx, compiled, wazero.NewModuleConfig().WithName(""))
	if err != nil {
		return fmt.Errorf("vt: trampoline: %w", err)
	}
	t.tramp = tramp
	idx, err := tramp.ExportedFunction("install").Call(t.ctx)
	if err != nil {
		return err
	}
	if err := t.termSetValue(optUserdata, uint64(t.id)); err != nil {
		return err
	}
	for i, cb := range callbacks {
		if int32(idx[i]) < 0 {
			return fmt.Errorf("vt: table.grow failed for %s", cb.name)
		}
		if err := t.termSetValue(cb.opt, idx[i]); err != nil {
			return err
		}
	}
	return nil
}

// termSetValue sets an option whose value is the pointer argument itself
// (callbacks, userdata), not something it points to.
func (t *Terminal) termSetValue(opt, v uint64) error {
	return t.result("terminal_set", t.fn.termSet, uint64(t.term), opt, v)
}

// deliver hands what the last Write's callbacks recorded to the handlers.
func (t *Terminal) deliver() {
	p := t.pend
	t.pend = pending{reply: p.reply[:0]}
	if len(p.reply) > 0 && t.events.Reply != nil {
		t.events.Reply(p.reply)
	}
	for range p.bell {
		if t.events.Bell != nil {
			t.events.Bell()
		}
	}
	if p.title && t.events.TitleChanged != nil {
		t.events.TitleChanged()
	}
	if p.pwd && t.events.PwdChanged != nil {
		t.events.PwdChanged()
	}
}

// trampoline assembles the wasm module that installs the callbacks:
//
//	(import "slime" "<cb>" (func ...))                  ;; one per callback
//	(import "<module>" "__indirect_function_table" (table 0 funcref))
//	(elem declare func 0 1 2 ...)
//	(func (export "install") (result i32 i32 ...)
//	  (table.grow (ref.func 0) (i32.const 1))           ;; old size = index
//	  ...)
func trampoline(module string) []byte {
	const (
		i32     = 0x7f
		funcref = 0x70
	)
	n := len(callbacks)

	var types []byte
	types = append(types, 4)
	types = append(types, 0x60, 4, i32, i32, i32, i32, 0) // write_pty
	types = append(types, 0x60, 2, i32, i32, 0)           // bell, title, pwd
	types = append(types, 0x60, 3, i32, i32, i32, 1, i32) // DA, size
	types = append(types, 0x60, 0, byte(n))               // install
	for range n {
		types = append(types, i32)
	}

	var imports []byte
	imports = uleb(imports, uint32(n+1))
	for _, cb := range callbacks {
		imports = name(imports, "slime")
		imports = name(imports, cb.name)
		imports = append(imports, 0x00, cb.typ)
	}
	imports = name(imports, module)
	imports = name(imports, "__indirect_function_table")
	imports = append(imports, 0x01, funcref, 0x00, 0x00) // table, min 0, no max

	funcs := []byte{1, 3} // one function of type 3

	var exports []byte
	exports = append(exports, 1)
	exports = name(exports, "install")
	exports = append(exports, 0x00)
	exports = uleb(exports, uint32(n)) // function index after the imports

	// A declarative segment lets ref.func name the imported functions.
	elems := []byte{1, 0x03, 0x00}
	elems = uleb(elems, uint32(n))
	for i := range n {
		elems = uleb(elems, uint32(i))
	}

	body := []byte{0} // no locals
	for i := range n {
		body = append(body, 0xd2) // ref.func
		body = uleb(body, uint32(i))
		body = append(body, 0x41, 1)       // i32.const 1
		body = append(body, 0xfc, 0x0f, 0) // table.grow 0
	}
	body = append(body, 0x0b)
	code := []byte{1}
	code = uleb(code, uint32(len(body)))
	code = append(code, body...)

	m := []byte{0x00, 'a', 's', 'm', 1, 0, 0, 0}
	for _, s := range []struct {
		id   byte
		data []byte
	}{{1, types}, {2, imports}, {3, funcs}, {7, exports}, {9, elems}, {10, code}} {
		m = append(m, s.id)
		m = uleb(m, uint32(len(s.data)))
		m = append(m, s.data...)
	}
	return m
}

func uleb(b []byte, v uint32) []byte {
	for {
		c := byte(v & 0x7f)
		v >>= 7
		if v == 0 {
			return append(b, c)
		}
		b = append(b, c|0x80)
	}
}

func name(b []byte, s string) []byte {
	b = uleb(b, uint32(len(s)))
	return append(b, s...)
}
