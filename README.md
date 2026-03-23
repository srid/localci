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

# Build on a specific platform (status: giton/build/aarch64-darwin)
nix run github:srid/giton -- -s aarch64-darwin -n build -- nix build
```

## What it does

1. Validates that the git working tree is clean (staged, unstaged, and untracked files)
2. Posts a **pending** GitHub commit status
3. Extracts the repo at HEAD to a temp directory via `git archive`
4. Runs the command in that clean checkout
5. Posts **success** or **failure** based on the exit code
6. Cleans up the temp directory

Status context: `giton/<name>` without `--system`, `giton/<name>/<system>` with it.

When `--system` doesn't match the current host, giton copies the repo to a remote machine via `git archive | ssh` and runs the command there. On first use it prompts for an SSH hostname; subsequent runs reuse the saved host from `$XDG_CONFIG_HOME/giton/hosts.json`.

## Install

```bash
nix run github:srid/giton -- --help
```

## Requirements

- `git`, `gh` (authenticated), `nix`
- Must be run inside a clean git repository with a GitHub remote
