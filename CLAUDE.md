# Project

Single Python script (`giton.py`) packaged as a Nix flake via `writeShellApplication` wrapping `python3`. Runtime deps: python3, git, gh, nix, openssh, process-compose.

# Dev

- Build: `nix build`
- Test: `nix run ./test`
- Quick check: `nix run . -- --system $(nix eval --raw --impure --expr builtins.currentSystem) --name test -- echo hello`

# Key details

- GitHub status context format: `giton/<name>/<system>`
- Two modes: single-step (`-- <cmd>`) and multi-step (`-f config.json` via process-compose)
- `--sha` flag pins commit and skips clean-tree check (used for self-invocation in multi-step mode)
- `flake.nix` uses flake-parts
