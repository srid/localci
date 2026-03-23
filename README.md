# giton

Local CI tool — run commands on specific Nix platforms and post GitHub commit statuses.

## Usage

```bash
nix run github:srid/giton -- [-s <nix-system>] [-n <check-name>] -- <command...>
```

### Examples

```bash
# Build on current system (status: giton/nix)
nix run github:srid/giton -- -- nix build

# Build on a specific platform (status: giton/build/x86_64-linux)
nix run github:srid/giton -- -s x86_64-linux -n build -- nix build
```

## What it does

1. Validates that the git working tree is clean
2. Posts a **pending** GitHub commit status
3. Extracts the repo at HEAD to a temp directory via `git archive`
4. Runs the command in that clean checkout
5. Posts **success** or **failure** based on the exit code
6. Cleans up the temp directory

Status context: `giton/<name>` without `--system`, `giton/<name>/<system>` with it.

If `--system` is specified and doesn't match the current host, remote execution via SSH is planned but not yet implemented.

## Install

```bash
nix run github:srid/giton -- --help
```

## Requirements

- `git`, `gh` (authenticated), `nix`
- Must be run inside a git repository with a GitHub remote
