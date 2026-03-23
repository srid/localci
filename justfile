default:
    @just --list

# Run local CI
ci:
    nix run github:srid/giton -- -n nix -- nix build
