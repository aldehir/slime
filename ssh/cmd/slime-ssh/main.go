// slime-ssh holds one SSH connection for slime and serves its session
// channels as pipes. slime talks to it with the control protocol in
// internal/proto on stdin and stdout; logs go to stderr.
//
// Usage: slime-ssh <destination>
package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"os"

	"github.com/spf13/cobra"

	"github.com/aldehir/slime/ssh/internal/proto"
)

func main() {
	log.SetFlags(log.Ltime | log.Lmicroseconds)
	log.SetPrefix("slime-ssh: ")
	if err := newCommand().Execute(); err != nil {
		log.Fatal(err)
	}
}

func newCommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:     "slime-ssh <destination>",
		Short:   "Serve an SSH connection's channels to slime",
		Long:    "Connects to destination ([user@]host[:port] or a Host from ~/.ssh/config)\nand serves its session channels to slime over the control protocol on stdin\nand stdout.",
		Version: fmt.Sprintf("protocol %d", proto.Version),
		Args:    cobra.ExactArgs(1),
		// Errors are logged by main; usage is noise once slime runs us.
		SilenceErrors: true,
		SilenceUsage:  true,
		RunE: func(cmd *cobra.Command, args []string) error {
			return run(args[0], os.Stdin, os.Stdout)
		},
	}
	// stdout is the control pipe, so help and version go to stderr.
	cmd.SetOut(os.Stderr)
	return cmd
}

func run(dest string, in io.Reader, out io.Writer) error {
	r := proto.NewReader(in)
	w := proto.NewWriter(out)

	if err := handshake(r, w); err != nil {
		return err
	}
	log.Printf("destination %q", dest)

	for {
		f, err := r.Read()
		if err == io.EOF {
			// slime is gone.
			return nil
		}
		if err != nil {
			return fmt.Errorf("reading control: %w", err)
		}
		m, err := proto.Decode(f)
		if errors.Is(err, proto.ErrUnknownType) {
			log.Printf("ignoring message type %d", f.Type)
			continue
		}
		if err != nil {
			return err
		}
		log.Printf("channel %d: %T (not handled yet)", f.ID, m)
	}
}

// handshake reads slime's Hello and replies with ours. A version
// mismatch is an error after the reply, so slime learns ours.
func handshake(r *proto.Reader, w *proto.Writer) error {
	f, err := r.Read()
	if err != nil {
		return fmt.Errorf("reading hello: %w", err)
	}
	m, err := proto.Decode(f)
	if err != nil {
		return fmt.Errorf("decoding hello: %w", err)
	}
	hello, ok := m.(*proto.Hello)
	if !ok {
		return fmt.Errorf("expected hello, got %T", m)
	}
	if err := w.Send(0, &proto.HelloReply{Version: proto.Version}); err != nil {
		return err
	}
	if hello.Version != proto.Version {
		return fmt.Errorf("slime speaks protocol %d, we speak %d", hello.Version, proto.Version)
	}
	return nil
}
