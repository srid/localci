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

For projects with multiple CI steps, define them in a JSON config:

```json
{
  "steps": {
    "build": {
      "systems": ["x86_64-linux", "aarch64-darwin"],
      "command": "nix build"
    },
    "test": {
      "systems": ["x86_64-linux", "aarch64-darwin"],
      "command": "nix run .#test",
      "depends_on": ["build"]
    }
  }
}
```

```bash
nix run github:srid/localci -- -f localci.json
```

This expands into a step×system matrix: `build` and `test` each run on both systems, in parallel. Dependencies resolve per-system — `test` on x86_64-linux waits for `build` on x86_64-linux, not on aarch64-darwin. Each cell in the matrix gets its own GitHub commit status.

Under the hood, localci generates a [process-compose](https://github.com/F1bonacc1/process-compose) config and delegates orchestration to it. Each step is a self-invocation of localci with `--sha` pinning. Pass `--tui` to get the process-compose terminal UI.

## Agent integration (MCP)

localci can expose CI steps as [MCP](https://modelcontextprotocol.io/) tools via process-compose's built-in MCP server. Coding agents (Claude Code, etc.) connect over stdio and invoke steps individually.

### Setup

Add two files to your project root:

**`localci.json`** — define your CI steps:
```json
{
  "steps": {
    "build": { "command": "nix build" },
    "test": { "command": "nix run .#test", "depends_on": ["build"] }
  }
}
```

**`.mcp.json`** — register the MCP server (auto-loaded by Claude Code):
```json
{
  "mcpServers": {
    "localci": {
      "type": "stdio",
      "command": "nix",
      "args": ["run", "github:srid/localci", "--", "--mcp", "-f", "localci.json"]
    }
  }
}
```

Then in your project's `CLAUDE.md`, tell the agent to use it:

```markdown
# CI
Run CI via the localci MCP tools after making changes. If a step fails, fix the code and re-invoke.
```

Each step from `localci.json` appears as an MCP tool (named `mcp__localci__<step>`). Dependencies are respected — invoking a step auto-starts its dependencies first. Steps can be re-invoked after fixing code. Step logs are exposed as MCP resources for diagnosis.

## Reference

```
localci [options] -- <command...>    Single-step mode
localci -f <config.json>             Multi-step mode

Options:
  -s, --system <system>   Nix system to run on (remote if different from current host)
  -n, --name <name>       GitHub status check name (default: command basename)
  -f, --file <path>       Multi-step JSON config
  --sha <sha>             Pin to a commit SHA (skips clean-tree check)
  --tui                   Show process-compose TUI (multi-step only)
  --mcp                   Expose steps as MCP tools (multi-step only)
```

Requires `git`, [`gh`](https://cli.github.com/) (authenticated), and `nix`. Must be run inside a git repository with a GitHub remote.
