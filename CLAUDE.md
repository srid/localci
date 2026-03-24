# Dev

- Build: `nix build`
- Test: `nix run .#test` (20 tests)
- CI locally: `just ci` (dogfoods localci via `localci.json`)

# Architecture

- Go source in `cmd/localci/`, packaged via `buildGoModule` + `makeWrapper` for runtime PATH
- flake.nix exports two packages: `default` (wrapped with runtime deps) and `test` (unwrapped — so the test harness's mock `gh` takes precedence in PATH)
- `vendorHash` in flake.nix must be updated when Go dependencies change (set to dummy hash, build, copy correct hash from error)

# Non-obvious patterns

- Multi-step mode self-invokes the localci binary for each step with `--sha` and `--workdir` flags. These are internal — `--workdir` skips archive extraction since the parent already extracted once per system.
- Tests are bash scripts (`test/test_*.sh`) that run the binary externally with a mock `gh` that logs calls to `$GH_CALL_LOG`. The mock must shadow the real `gh` in PATH, which is why tests use the unwrapped binary.
- `git archive` output is piped directly to `tar` (or `ssh | tar` for remote) — never written to disk.
