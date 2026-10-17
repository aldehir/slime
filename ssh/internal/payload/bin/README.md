`go run ./cmd/slime-pack` (build.zig runs it) writes the compressed
slimed builds here, `slimed-<os>-<arch>.gz`, for slime-ssh to install on
remote hosts. They're gitignored.
