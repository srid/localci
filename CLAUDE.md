# Project

Zig CLI tool packaged as a Nix flake via `zig.hook`. Runtime deps: git, gh, nix, openssh, process-compose.

# Dev

- Build: `nix build`
- Test: `nix run .#test`

# Key details

- Source in `src/main.zig`, build system in `build.zig`
- GitHub status context format: `giton/<name>/<system>`
- Two modes: single-step (`-- <cmd>`) and multi-step (`-f config.json` via process-compose)
- `--sha` flag pins commit and skips clean-tree check (used for self-invocation in multi-step mode)
- `flake.nix` uses flake-parts with `zig.hook` for building
