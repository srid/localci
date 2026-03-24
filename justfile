default:
    @just --list

# Run local CI (build + test with GitHub status reporting)
ci:
    nix run . -- -f localci.json

# Run integration tests
test:
    nix run .#test
