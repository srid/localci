# Dev workflow

Use the localci MCP tools (`mcp__localci__build`, `mcp__localci__test`) — never run `nix build` or `go build` directly.

1. Make changes, commit
2. Run localci MCP tools to verify (these use `--no-signoff` mode internally during iteration)
3. If failures: fix, amend commit, re-run MCP tools
4. Once green: push, then run localci MCP tools again to post GitHub statuses

# Architecture

- Go source in `cmd/localci/`, packaged via `buildGoModule` + `makeWrapper` for runtime PATH
- flake.nix exports two packages: `default` (wrapped with runtime deps) and `test` (unwrapped — so the test harness's mock `gh` takes precedence in PATH)
- `vendorHash` in flake.nix must be updated when Go dependencies change (set to dummy hash, build, copy correct hash from error)

# Non-obvious patterns

- Multi-step mode self-invokes the localci binary for each step with `--sha` and `--workdir` flags. These are internal — `--workdir` skips archive extraction since the parent already extracted once per system.
- Tests are bash scripts (`test/test_*.sh`) that run the binary externally with a mock `gh` that logs calls to `$GH_CALL_LOG`. The mock must shadow the real `gh` in PATH, which is why tests use the unwrapped binary.
- `git archive` output is piped directly to `tar` (or `ssh | tar` for remote) — never written to disk.
- `--mcp` mode generates process-compose config with `mcp_server: {transport: stdio}` and all processes `disabled: true` with `mcp: {type: tool}`. Process-compose stays running as an MCP server; agents invoke steps on demand.
