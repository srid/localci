# giton

Local CI tool — run commands on specific Nix platforms and post GitHub commit statuses.

## Usage

```bash
giton --system <nix-system> --name <check-name> -- <command...>
```

### Examples

```bash
# Build on current platform
giton --system x86_64-linux --name build -- nix build

# Run tests on current platform
giton --system aarch64-darwin --name test -- nix flake check
```

## What it does

1. Validates that the git working tree is clean
2. Posts a **pending** GitHub commit status (`giton/<system>/<name>`)
3. Extracts the repo at HEAD to a temp directory via `git archive`
4. Runs the command in that clean checkout
5. Posts **success** or **failure** based on the exit code
6. Cleans up the temp directory

If the current system doesn't match `--system`, remote execution via SSH is planned but not yet implemented.

## Install

```bash
nix run github:srid/giton -- --help
```

## Requirements

- `git`, `gh` (authenticated), `nix`
- Must be run inside a git repository with a GitHub remote
