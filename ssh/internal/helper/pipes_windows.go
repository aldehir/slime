package helper

import (
	"fmt"
	"io"
	"os"

	"golang.org/x/sys/windows"
)

// openHandles wraps pipe handles that slime duplicated into this
// process. Anything that isn't a pipe is refused rather than trusted.
func openHandles(in, out uint64) (io.ReadCloser, io.WriteCloser, error) {
	for _, h := range []uint64{in, out} {
		t, err := windows.GetFileType(windows.Handle(h))
		if err != nil {
			return nil, nil, fmt.Errorf("handle 0x%x: %w", h, err)
		}
		if t != windows.FILE_TYPE_PIPE {
			return nil, nil, fmt.Errorf("handle 0x%x is not a pipe", h)
		}
	}
	return os.NewFile(uintptr(in), "channel input"), os.NewFile(uintptr(out), "channel output"), nil
}
