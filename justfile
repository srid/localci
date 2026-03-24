default:
    @just --list

# Run local CI
ci:
    nix run github:srid/giton -- -n nix -- nix build

# Run integration tests
test:
    nix run .#test
