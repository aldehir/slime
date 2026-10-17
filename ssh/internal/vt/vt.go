// Package vt runs libghostty-vt, built as wasm (scripts/build-vt-wasm.ps1),
// under wazero, so the daemon holding terminal state needs no cgo.
//
// Each Terminal gets its own module instance: wasm linear memory only
// grows, so closing the instance is the only way to give a big
// scrollback's memory back.
//
// The module is wasm32. Pointers and size_t are u32 offsets into the
// instance's memory; out-parameters live in scratch memory allocated
// from the guest.
package vt

import (
	"context"
	_ "embed"
	"errors"
	"fmt"
	"log/slog"
	"sync"

	"github.com/tetratelabs/wazero"
	"github.com/tetratelabs/wazero/api"
)

//go:embed ghostty-vt.wasm
var wasmBin []byte

// Result codes (GhosttyResult).
const (
	resSuccess    = 0
	resOutOfSpace = -3
)

// Options and data keys from terminal.h and snapshot.h.
const (
	optContinuationMaxBytes = 31

	dataCols    = 1
	dataRows    = 2
	dataCursorX = 3
	dataCursorY = 4
	dataScreen  = 6
	dataTitle   = 12
	dataPwd     = 13

	decoderOptMaxContinuation    = 0
	decoderOptRetainContinuation = 1

	formatPlain = 0
)

// ContinuationLimit is how many bytes of an unfinished escape sequence a
// terminal keeps so a snapshot can be taken between any two writes. OSC
// and APC payloads past this make the continuation unavailable until the
// parser next reaches ground.
const ContinuationLimit = 64 * 1024

// Error is a GhosttyResult other than success.
type Error struct {
	Op   string
	Code int32
}

func (e *Error) Error() string { return fmt.Sprintf("vt: %s: result %d", e.Op, e.Code) }

// Runtime holds the compiled module. Compiling takes most of the cost of
// starting a terminal, so do it once and share the Runtime.
type Runtime struct {
	rt  wazero.Runtime
	mod wazero.CompiledModule
	log *slog.Logger

	mu     sync.Mutex
	nextID uint32
	terms  map[uint32]*Terminal // by id, for the host callbacks
}

// NewRuntime compiles the embedded module. log receives libghostty-vt's
// own log lines; nil discards them.
func NewRuntime(ctx context.Context, log *slog.Logger) (*Runtime, error) {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	rt := wazero.NewRuntime(ctx)
	r := &Runtime{rt: rt, log: log, terms: map[uint32]*Terminal{}}
	if err := r.hostModule(ctx); err != nil {
		rt.Close(ctx)
		return nil, err
	}
	_, err := rt.NewHostModuleBuilder("env").
		NewFunctionBuilder().
		WithFunc(func(ctx context.Context, m api.Module, ptr, n uint32) {
			if b, ok := m.Memory().Read(ptr, n); ok {
				r.log.Debug("ghostty-vt", "msg", string(b))
			}
		}).
		Export("log").
		Instantiate(ctx)
	if err != nil {
		rt.Close(ctx)
		return nil, err
	}
	r.mod, err = rt.CompileModule(ctx, wasmBin)
	if err != nil {
		rt.Close(ctx)
		return nil, err
	}
	return r, nil
}

// Close frees the runtime and every terminal still open on it.
func (r *Runtime) Close(ctx context.Context) error { return r.rt.Close(ctx) }

// Terminal is one libghostty-vt terminal. It isn't safe for concurrent
// use.
type Terminal struct {
	ctx   context.Context
	rt    *Runtime
	id    uint32
	mod   api.Module
	tramp api.Module // installs the callbacks; see installCallbacks
	mem   api.Memory
	fn    funcs
	term  uint32

	// Guest scratch: out-parameters (16 bytes) and Write's input.
	out     uint32
	buf     uint32
	bufSize uint32

	events Events
	pend   pending

	// For size reports, which can't call back into the terminal.
	cols, rows   uint16
	cellW, cellH uint32
}

type funcs struct {
	alloc, free                   api.Function
	allocOpaque, freeOpaque       api.Function
	ghosttyFree                   api.Function
	termNew, termFree, termResize api.Function
	termSet, termGet, termWrite   api.Function
	snapEncode                    api.Function
	decNewBuf, decSet, decDecode  api.Function
	decFree                       api.Function
	fmtNew, fmtFormat, fmtFree    api.Function
	typeJSON                      api.Function
}

func (r *Runtime) instantiate() (*Terminal, error) {
	ctx := context.Background()
	r.mu.Lock()
	r.nextID++
	id := r.nextID
	r.mu.Unlock()
	// Named so the callback trampoline can import its table.
	name := fmt.Sprintf("ghostty-vt-%d", id)
	mod, err := r.rt.InstantiateModule(ctx, r.mod, wazero.NewModuleConfig().WithName(name))
	if err != nil {
		return nil, err
	}
	t := &Terminal{ctx: ctx, rt: r, id: id, mod: mod, mem: mod.Memory()}
	var missing []string
	get := func(name string) api.Function {
		f := mod.ExportedFunction(name)
		if f == nil {
			missing = append(missing, name)
		}
		return f
	}
	t.fn = funcs{
		alloc:       get("ghostty_wasm_alloc"),
		free:        get("ghostty_wasm_free"),
		allocOpaque: get("ghostty_wasm_alloc_opaque"),
		freeOpaque:  get("ghostty_wasm_free_opaque"),
		ghosttyFree: get("ghostty_free"),
		termNew:     get("ghostty_terminal_new"),
		termFree:    get("ghostty_terminal_free"),
		termResize:  get("ghostty_terminal_resize"),
		termSet:     get("ghostty_terminal_set"),
		termGet:     get("ghostty_terminal_get"),
		termWrite:   get("ghostty_terminal_vt_write"),
		snapEncode:  get("ghostty_snapshot_encode_alloc"),
		decNewBuf:   get("ghostty_snapshot_decoder_new_buf"),
		decSet:      get("ghostty_snapshot_decoder_set"),
		decDecode:   get("ghostty_snapshot_decoder_decode"),
		decFree:     get("ghostty_snapshot_decoder_free"),
		fmtNew:      get("ghostty_formatter_terminal_new"),
		fmtFormat:   get("ghostty_formatter_format_alloc"),
		fmtFree:     get("ghostty_formatter_free"),
		typeJSON:    get("ghostty_type_json"),
	}
	if missing != nil {
		mod.Close(ctx)
		return nil, fmt.Errorf("vt: module lacks %v", missing)
	}
	if t.out, err = t.malloc(16); err != nil {
		mod.Close(ctx)
		return nil, err
	}
	return t, nil
}

// New creates a terminal with continuation tracking on, so Snapshot works
// whatever the last Write ended on.
func (r *Runtime) New(cols, rows uint16) (*Terminal, error) {
	t, err := r.instantiate()
	if err != nil {
		return nil, err
	}
	slot, err := t.call1(t.fn.allocOpaque)
	if err == nil {
		err = t.result("terminal_new", t.fn.termNew, 0, slot, uint64(cols), uint64(rows))
		if err == nil {
			t.term = t.u32(uint32(slot))
		}
		t.call(t.fn.freeOpaque, slot)
	}
	if err == nil {
		err = t.setSize(optContinuationMaxBytes, ContinuationLimit)
	}
	if err == nil {
		err = t.finish()
	}
	if err != nil {
		t.Close()
		return nil, err
	}
	return t, nil
}

// Decode restores a terminal from a snapshot, with continuation tracking
// on as New leaves it. Callbacks set in the snapshot's terminal aren't
// part of it; the new terminal gets its own.
func (r *Runtime) Decode(snapshot []byte) (*Terminal, error) {
	t, err := r.instantiate()
	if err != nil {
		return nil, err
	}
	err = t.decode(snapshot)
	if err == nil {
		err = t.finish()
	}
	if err != nil {
		t.Close()
		return nil, err
	}
	return t, nil
}

// finish registers a terminal for its callbacks once its handle exists.
func (t *Terminal) finish() error {
	var err error
	if t.cols, t.rows, err = t.Size(); err != nil {
		return err
	}
	t.rt.mu.Lock()
	t.rt.terms[t.id] = t
	t.rt.mu.Unlock()
	return t.installCallbacks(t.rt, fmt.Sprintf("ghostty-vt-%d", t.id))
}

// SetEvents sets the handlers for what the terminal reports.
func (t *Terminal) SetEvents(e Events) { t.events = e }

func (t *Terminal) decode(snapshot []byte) error {
	src, err := t.copyIn(snapshot)
	if err != nil {
		return err
	}
	slot, err := t.call1(t.fn.allocOpaque)
	if err != nil {
		return err
	}
	defer t.call(t.fn.freeOpaque, slot)
	err = t.result("snapshot_decoder_new_buf", t.fn.decNewBuf,
		0, slot, uint64(src), uint64(len(snapshot)))
	if err != nil {
		return err
	}
	dec := uint64(t.u32(uint32(slot)))
	defer t.call(t.fn.decFree, dec)

	t.mem.WriteUint32Le(t.out, ContinuationLimit)
	if err := t.result("snapshot_decoder_set", t.fn.decSet, dec, decoderOptMaxContinuation, uint64(t.out)); err != nil {
		return err
	}
	t.mem.WriteByte(t.out, 1)
	if err := t.result("snapshot_decoder_set", t.fn.decSet, dec, decoderOptRetainContinuation, uint64(t.out)); err != nil {
		return err
	}
	if err := t.result("snapshot_decoder_decode", t.fn.decDecode, dec, slot); err != nil {
		return err
	}
	t.term = t.u32(uint32(slot))
	return nil
}

// Close frees the terminal and its instance.
func (t *Terminal) Close() error {
	if t.mod == nil {
		return nil
	}
	t.rt.mu.Lock()
	delete(t.rt.terms, t.id)
	t.rt.mu.Unlock()
	if t.tramp != nil {
		t.tramp.Close(t.ctx)
	}
	err := t.mod.Close(t.ctx)
	t.mod = nil
	return err
}

// Write feeds pty output to the terminal, then delivers the events it
// caused.
func (t *Terminal) Write(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	src, err := t.copyIn(p)
	if err != nil {
		return 0, err
	}
	_, err = t.fn.termWrite.Call(t.ctx, uint64(t.term), uint64(src), uint64(len(p)))
	t.deliver()
	if err != nil {
		return 0, err
	}
	return len(p), nil
}

// Resize changes the grid size. The cell size in pixels is the client's
// (zero if unknown); it only feeds pixel size reports.
func (t *Terminal) Resize(cols, rows uint16, cellW, cellH uint32) error {
	err := t.result("terminal_resize", t.fn.termResize,
		uint64(t.term), uint64(cols), uint64(rows), uint64(cellW), uint64(cellH))
	if err != nil {
		return err
	}
	t.cols, t.rows, t.cellW, t.cellH = cols, rows, cellW, cellH
	// Mode 2048 sends an in-band size report on resize.
	t.deliver()
	return nil
}

// Title is the title the program last set (OSC 0/2).
func (t *Terminal) Title() (string, error) { return t.getString(dataTitle) }

// Pwd is the working directory the shell last reported (OSC 7, 9, 1337),
// as sent: OSC 7's is a file:// URI.
func (t *Terminal) Pwd() (string, error) { return t.getString(dataPwd) }

func (t *Terminal) getString(key uint64) (string, error) {
	// GhosttyString: ptr, len. Borrowed from the terminal.
	if err := t.result("terminal_get", t.fn.termGet, uint64(t.term), key, uint64(t.out)); err != nil {
		return "", err
	}
	ptr, n := t.u32(t.out), t.u32(t.out+4)
	if n == 0 {
		return "", nil
	}
	b, ok := t.mem.Read(ptr, n)
	if !ok {
		return "", errors.New("vt: string out of bounds")
	}
	return string(b), nil
}

// Size reports the grid size.
func (t *Terminal) Size() (cols, rows uint16, err error) {
	c, err := t.getU16(dataCols)
	if err != nil {
		return 0, 0, err
	}
	r, err := t.getU16(dataRows)
	return c, r, err
}

// Cursor reports the cursor position on the active screen, zero-based.
func (t *Terminal) Cursor() (x, y uint16, err error) {
	x, err = t.getU16(dataCursorX)
	if err != nil {
		return 0, 0, err
	}
	y, err = t.getU16(dataCursorY)
	return x, y, err
}

// AltScreen reports whether the alternate screen is active.
func (t *Terminal) AltScreen() (bool, error) {
	if err := t.result("terminal_get", t.fn.termGet, uint64(t.term), dataScreen, uint64(t.out)); err != nil {
		return false, err
	}
	v, _ := t.mem.ReadUint32Le(t.out)
	return v != 0, nil
}

// Snapshot encodes the terminal's complete state, scrollback included.
func (t *Terminal) Snapshot() ([]byte, error) {
	return t.allocOut("snapshot_encode_alloc", t.fn.snapEncode, uint64(t.term), 0)
}

// Text formats the active screen as plain text, scrollback included,
// with soft-wrapped lines joined and trailing blanks trimmed.
func (t *Terminal) Text() (string, error) {
	// GhosttyFormatterTerminalOptions, wasm32 layout (formatterOptions in
	// vt_test.go checks it against ghostty_type_json).
	const (
		optsSize   = 40
		offEmit    = 4
		offUnwrap  = 8
		offTrim    = 9
		offExtra   = 12
		offScreen  = offExtra + 12
		extraSize  = 24
		screenSize = 12
	)
	opts, err := t.malloc(optsSize)
	if err != nil {
		return "", err
	}
	defer t.call(t.fn.free, uint64(opts), optsSize)
	zero := make([]byte, optsSize)
	t.mem.Write(opts, zero)
	t.mem.WriteUint32Le(opts, optsSize)
	t.mem.WriteUint32Le(opts+offEmit, formatPlain)
	t.mem.WriteByte(opts+offUnwrap, 1)
	t.mem.WriteByte(opts+offTrim, 1)
	t.mem.WriteUint32Le(opts+offExtra, extraSize)
	t.mem.WriteUint32Le(opts+offScreen, screenSize)

	slot, err := t.call1(t.fn.allocOpaque)
	if err != nil {
		return "", err
	}
	defer t.call(t.fn.freeOpaque, slot)
	// Structs passed by value go by pointer in the wasm32 C ABI.
	if err := t.result("formatter_terminal_new", t.fn.fmtNew, 0, slot, uint64(t.term), uint64(opts)); err != nil {
		return "", err
	}
	f := uint64(t.u32(uint32(slot)))
	defer t.call(t.fn.fmtFree, f)
	b, err := t.allocOut("formatter_format_alloc", t.fn.fmtFormat, f, 0)
	return string(b), err
}

// allocOut calls an `_alloc` function whose last two parameters are
// `uint8_t **out_ptr, size_t *out_len`, copies the result out, and frees
// it.
func (t *Terminal) allocOut(op string, f api.Function, args ...uint64) ([]byte, error) {
	args = append(args, uint64(t.out), uint64(t.out+4))
	if err := t.result(op, f, args...); err != nil {
		return nil, err
	}
	ptr, n := t.u32(t.out), t.u32(t.out+4)
	if ptr == 0 {
		return nil, nil
	}
	b, ok := t.mem.Read(ptr, n)
	if !ok {
		return nil, fmt.Errorf("vt: %s: result out of bounds", op)
	}
	b = append([]byte(nil), b...)
	t.call(t.fn.ghosttyFree, 0, uint64(ptr), uint64(n))
	return b, nil
}

func (t *Terminal) setSize(opt uint64, v uint32) error {
	t.mem.WriteUint32Le(t.out, v)
	return t.result("terminal_set", t.fn.termSet, uint64(t.term), opt, uint64(t.out))
}

func (t *Terminal) getU16(key uint64) (uint16, error) {
	if err := t.result("terminal_get", t.fn.termGet, uint64(t.term), key, uint64(t.out)); err != nil {
		return 0, err
	}
	v, _ := t.mem.ReadUint16Le(t.out)
	return v, nil
}

// copyIn copies p into the reusable input buffer, growing it as needed.
func (t *Terminal) copyIn(p []byte) (uint32, error) {
	if uint32(len(p)) > t.bufSize {
		if t.buf != 0 {
			t.call(t.fn.free, uint64(t.buf), uint64(t.bufSize))
			t.buf, t.bufSize = 0, 0
		}
		size := max(uint32(len(p)), 64*1024)
		buf, err := t.malloc(size)
		if err != nil {
			return 0, err
		}
		t.buf, t.bufSize = buf, size
	}
	if !t.mem.Write(t.buf, p) {
		return 0, errors.New("vt: input buffer out of bounds")
	}
	return t.buf, nil
}

func (t *Terminal) malloc(n uint32) (uint32, error) {
	p, err := t.call1(t.fn.alloc, uint64(n))
	if err != nil {
		return 0, err
	}
	if p == 0 {
		return 0, errors.New("vt: out of memory")
	}
	return uint32(p), nil
}

func (t *Terminal) u32(ptr uint32) uint32 {
	v, _ := t.mem.ReadUint32Le(ptr)
	return v
}

func (t *Terminal) call(f api.Function, args ...uint64) ([]uint64, error) {
	return f.Call(t.ctx, args...)
}

func (t *Terminal) call1(f api.Function, args ...uint64) (uint64, error) {
	r, err := f.Call(t.ctx, args...)
	if err != nil {
		return 0, err
	}
	return r[0], nil
}

func (t *Terminal) result(op string, f api.Function, args ...uint64) error {
	r, err := f.Call(t.ctx, args...)
	if err != nil {
		return err
	}
	if code := int32(r[0]); code != resSuccess {
		return &Error{Op: op, Code: code}
	}
	return nil
}
