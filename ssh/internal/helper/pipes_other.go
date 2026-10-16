//go:build !windows

package helper

import (
	"errors"
	"io"
)

func openHandles(in, out uint64) (io.ReadCloser, io.WriteCloser, error) {
	return nil, nil, errors.New("channel handles need Windows")
}
