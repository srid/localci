# giton

Local CI for Nix projects. Run `nix build` on your laptop and the result shows up as a green check on the GitHub PR — no hosted runner needed.

```bash
nix run github:srid/giton -- -- nix build
```

giton extracts the repo at HEAD into a temp directory (via `git archive`), runs the command there, and posts a GitHub commit status. The clean extraction means your uncommitted changes can't leak into the build. The working tree must be clean, or giton refuses to run.

<img width="1220" height="1010" alt="image" src="https://github.com/user-attachments/assets/2c687668-5f08-425c-922a-7595b2bef5b0" />


## Cross-system builds

Pass `-s` to run on a different Nix platform. giton pipes the archive over SSH and executes remotely:

```bash
nix run github:srid/giton -- -s aarch64-darwin -n build -- nix build
```

On first use, giton prompts for the SSH hostname for that system. The mapping is saved to `$XDG_CONFIG_HOME/giton/hosts.json` and reused on subsequent runs.

The GitHub status context includes the system: `giton/build/aarch64-darwin`.

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
nix run github:srid/giton -- -f giton.json
```

This expands into a step×system matrix: `build` and `test` each run on both systems, in parallel. Dependencies resolve per-system — `test` on x86_64-linux waits for `build` on x86_64-linux, not on aarch64-darwin. Each cell in the matrix gets its own GitHub commit status.

Under the hood, giton generates a [process-compose](https://github.com/F1bonacc1/process-compose) config and delegates orchestration to it. Each step is a self-invocation of giton with `--sha` pinning. Pass `--tui` to get the process-compose terminal UI.

## GitHub Actions

giton works in hosted CI too. Use `--sha` to pin to the PR commit (the clean-tree check doesn't apply in CI since there's no working tree to protect):

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
      - run: nix run github:srid/giton -- --sha ${{ github.sha }} -f giton.json
```

Each step posts its own commit status (`giton/build`, `giton/test`), so the PR shows fine-grained check results even though it's a single CI job.

## Reference

```
giton [options] -- <command...>    Single-step mode
giton -f <config.json>             Multi-step mode

Options:
  -s, --system <system>   Nix system to run on (remote if different from current host)
  -n, --name <name>       GitHub status check name (default: command basename)
  -f, --file <path>       Multi-step JSON config
  --sha <sha>             Pin to a commit SHA (skips clean-tree check)
  --tui                   Show process-compose TUI (multi-step only)
```

Requires `git`, [`gh`](https://cli.github.com/) (authenticated), and `nix`. Must be run inside a git repository with a GitHub remote.
