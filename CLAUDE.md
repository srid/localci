# Project

Nim CLI tool packaged as a Nix flake via `stdenv.mkDerivation` with `nim2`. Runtime deps: git, gh, nix, openssh, process-compose.

# Dev

- Build: `nix build`
- Test: `nix run .#test`
- Quick test: `nix run . -- --system $(nix eval --raw --impure --expr builtins.currentSystem) --name test -- echo hello`

# Key details

- GitHub status context format: `giton/<name>/<system>`
- Two modes: single-step (`-- <cmd>`) and multi-step (`-f config.json` via process-compose)
- `--sha` flag pins commit and skips clean-tree check (used for self-invocation in multi-step mode)
- `flake.nix` uses flake-parts
