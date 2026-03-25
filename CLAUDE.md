# Dev workflow

Use the localci MCP tools (`mcp__localci__build`, `mcp__localci__test`) — never run `nix build` or `dune build` directly.

1. Make changes, commit
2. Run localci MCP tools to verify (these use `--no-signoff` mode internally during iteration)
3. If failures: fix, amend commit, re-run MCP tools
4. Once green: push, then run localci MCP tools again to post GitHub statuses

# Architecture

- OCaml source: `bin/main.ml` (CLI via cmdliner), `lib/*.ml` (all logic)
- Built via `buildDunePackage` + `symlinkJoin`/`makeWrapper` for runtime PATH
- flake.nix exports two packages: `default` (wrapped with runtime deps) and `test` (runs dune cram tests)
- Dependencies: `cmdliner` (CLI), `yojson` (JSON), `unix` (process spawning)

# Non-obvious patterns

- Multi-step mode self-invokes the localci binary for each step with `--sha` and `--workdir` flags. These are internal — `--workdir` skips archive extraction since the parent already extracted once per system.
- Tests are dune cram tests (`test/*.t`) that use inline mock `gh` scripts logging calls to `$GH_CALL_LOG`. The unwrapped binary is used so mock gh takes precedence in PATH.
- `git archive` output is piped directly to `tar` (or `ssh | tar` for remote) — never written to disk.
- `--mcp` mode generates process-compose config with `mcp_server: {transport: stdio}` and all processes `disabled: true` with `mcp: {type: tool}`. Process-compose stays running as an MCP server; agents invoke steps on demand.
