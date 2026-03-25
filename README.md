# localci

Local CI from your terminal. Run any command and the result shows up as a green check on the GitHub PR — no hosted runner needed.

```bash
nix run github:srid/localci -- -- make build
```

localci extracts the repo at HEAD into a temp directory (via `git archive`), runs the command there, and posts a GitHub commit status. The clean extraction means your uncommitted changes can't leak into the build. The working tree must be clean, or localci refuses to run.

With `-s`, localci can target remote Nix systems over SSH — run builds on `aarch64-darwin` from your Linux box.

<img width="1220" height="1010" alt="image" src="https://github.com/user-attachments/assets/2c687668-5f08-425c-922a-7595b2bef5b0" />


## Cross-system builds

Pass `-s` to run on a different Nix platform. localci pipes the archive over SSH and executes remotely:

```bash
nix run github:srid/localci -- -s aarch64-darwin -n build -- nix build
```

On first use, localci prompts for the SSH hostname for that system. The mapping is saved to `$XDG_CONFIG_HOME/localci/hosts.json` and reused on subsequent runs.

The GitHub status context includes the system: `localci/build/aarch64-darwin`.

> [!NOTE]
> This approach runs the entire build on the remote machine via SSH, rather than using Nix remote builders. Remote builders frequently hang during builds, making them unreliable for CI. localci sidesteps this by treating the remote as a plain execution target.

## Multi-step

For projects with multiple CI steps, define them in a `ci.just` module using [just](https://github.com/casey/just) with [metadata attributes](https://github.com/casey/just/pull/2794):

**`justfile`** (root):
```just
mod ci
```

**`ci.just`**:
```just
[metadata("systems", "x86_64-linux", "aarch64-darwin")]
build:
    nix build

[metadata("systems", "x86_64-linux", "aarch64-darwin")]
[metadata("depends_on", "build")]
test:
    nix run .#test
```

```bash
nix run github:srid/localci
```

This expands into a step×system matrix: `build` and `test` each run on both systems, in parallel. Dependencies resolve per-system — `test` on x86_64-linux waits for `build` on x86_64-linux, not on aarch64-darwin. Each cell in the matrix gets its own GitHub commit status.

Steps are invoked as `just ci::<recipe>` in the extracted archive. You can also run them manually: `just ci build`, `just ci test`.

### Metadata attributes

- `[metadata("systems", "x86_64-linux", "aarch64-darwin")]` — target Nix systems
- `[metadata("depends_on", "build")]` — dependency on another CI step

## GitHub Actions

> [!NOTE]
> Running localci in GitHub Actions defeats the purpose of *local* CI — you're back to waiting for hosted runners. Consider using the [MCP integration](#agent-integration-mcp) with a coding agent instead. That said, nothing prevents you from using both.

localci works in hosted CI too. Use `--sha` to pin to the PR commit (the clean-tree check doesn't apply in CI since there's no working tree to protect):

```yaml
jobs:
  ci:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest]
    runs-on: ${{ matrix.os }}
    env:
      GH_TOKEN: ${{ github.token }}
    steps:
      - uses: actions/checkout@v4
      - uses: nixbuild/nix-quick-install-action@v34
      - run: nix run github:srid/localci -- --sha ${{ github.sha }}
```

Each step posts its own commit status (`localci/build`, `localci/test`), so the PR shows fine-grained check results even though it's a single CI job.

## Agent integration (MCP)

localci exposes CI steps as [MCP](https://modelcontextprotocol.io/) tools. Coding agents (Claude Code, etc.) connect and invoke steps individually.

### Setup

Add two files to your project root:

**`ci.just`** — define your CI steps (with `mod ci` in your root justfile):
```just
[metadata("depends_on", "build")]
test:
    nix run .#test
build:
    nix build
```

**`.mcp.json`** — register the MCP server (auto-loaded by Claude Code):
```json
{
  "mcpServers": {
    "localci": {
      "type": "http",
      "url": "http://localhost:8417/mcp"
    }
  }
}
```

Start the persistent MCP server:
```bash
nix run github:srid/localci -- serve
```

Or use stdio mode for auto-start:
```json
{
  "mcpServers": {
    "localci": {
      "type": "stdio",
      "command": "nix",
      "args": ["run", "github:srid/localci", "--", "--mcp"]
    }
  }
}
```

Then in your project's `CLAUDE.md`, tell the agent how to use it:

```markdown
# CI workflow

To run CI, call all localci step tools in parallel (they handle dependency
ordering internally — queued steps wait for deps automatically). Then poll
`status-all` until complete. Do NOT call `status-all` before starting steps.

If a step fails, fix the issue, commit, and re-call the step tools — they
auto-detect the new SHA and re-run.
```

Each CI recipe appears as an MCP tool. A `status-all` tool polls all steps at once — showing `●` running, `◌` queued (waiting for deps), `✓` passed, `✗` failed. Steps track which SHA they ran against and automatically re-run when the commit changes.

### Branch protection

Require localci checks to pass before merging PRs. This reads the justfile ci module, expands the step×system matrix, and sets the correct status contexts as required checks on the default branch:

```bash
localci protect
```

## Reference

```
localci [run] [options] -- <command...>    Single-step mode
localci [run] [options]                    Multi-step mode (justfile ci module)
localci [run] --mcp                        MCP server (stdio)
localci serve [-p PORT]                    MCP server (HTTP, default :8417)
localci protect                            Set branch protection

Options:
  -s, --system <system>   Nix system to run on (remote if different from current host)
  -n, --name <name>       GitHub status check name (default: command basename)
  --sha <sha>             Pin to a commit SHA (skips clean-tree check)
  --mcp                   Start MCP server exposing CI steps as tools
  --no-signoff            Skip GitHub status posting (test before pushing)
```

Requires `git`, [`gh`](https://cli.github.com/) (authenticated), `nix`, and [`just`](https://github.com/casey/just). Must be run inside a git repository with a GitHub remote.
