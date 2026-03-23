# giton

Local CI tool — run commands on specific Nix platforms and post GitHub commit statuses.

## Usage

### Single-step mode

```bash
nix run github:srid/giton -- [-s <nix-system>] [-n <check-name>] -- <command...>
```

### Multi-step mode

```bash
nix run github:srid/giton -- -f giton.json
```

Define steps with systems, commands, and dependencies in a JSON config:

```json
{
  "steps": {
    "nix": {
      "systems": ["x86_64-linux", "aarch64-darwin"],
      "command": "nix build"
    },
    "e2e": {
      "systems": ["x86_64-linux", "aarch64-darwin"],
      "command": "just test",
      "depends_on": ["nix"]
    }
  }
}
```

Steps run in parallel across systems. Dependencies are resolved per-system — `e2e/x86_64-linux` waits for `nix/x86_64-linux` but not `nix/aarch64-darwin`. Orchestration is handled by [process-compose](https://github.com/F1bonacc1/process-compose).

### Examples

```bash
# Build on current system (status: giton/nix)
nix run github:srid/giton -- -- nix build

# Build on a specific platform (status: giton/build/aarch64-darwin)
nix run github:srid/giton -- -s aarch64-darwin -n build -- nix build

# Run multi-step CI from config
nix run github:srid/giton -- -f giton.json

# Pin to a specific commit (skips clean-tree check)
nix run github:srid/giton -- --sha abc123def -- nix build
```

## What it does

1. Pins the current HEAD commit SHA (or uses `--sha` if provided)
2. Validates that the git working tree is clean (unless `--sha` is given)
3. Posts a **pending** GitHub commit status
4. Extracts the repo at the pinned SHA to a temp directory via `git archive`
5. Runs the command in that clean checkout
6. Posts **success** or **failure** based on the exit code
7. Cleans up the temp directory

In multi-step mode, giton generates a process-compose config and orchestrates all steps with proper dependency ordering and parallelism. Each step gets its own GitHub commit status.

Status context: `giton/<name>` without `--system`, `giton/<name>/<system>` with it.

When `--system` doesn't match the current host, giton copies the repo to a remote machine via `git archive | ssh` and runs the command there. On first use it prompts for an SSH hostname; subsequent runs reuse the saved host from `$XDG_CONFIG_HOME/giton/hosts.json`.

## Install

```bash
nix run github:srid/giton -- --help
```

## Requirements

- `git`, `gh` (authenticated), `nix`
- Must be run inside a clean git repository with a GitHub remote
