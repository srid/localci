mod ci

default:
    @just --list

# Run local CI (build + test with GitHub status reporting)
run-ci:
    nix run .

# Run integration tests
test:
    nix run .#test
