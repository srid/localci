#!/usr/bin/env bash
# Test runner — executes all test_*.sh files in this directory.
set -euo pipefail

PASS=0
FAIL=0
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Shared setup (sourced by each test file) ─────────────────────────────────

export LOCALCI="${LOCALCI:-bash ./giton}"
export WORK=$(mktemp -d)
ORIG_DIR="$PWD"
cleanup() { cd "$ORIG_DIR"; rm -rf "$WORK"; }
trap cleanup EXIT

# Mock gh
MOCK_BIN="$WORK/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
echo "$@" >> "${GH_CALL_LOG:-/dev/null}"
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "test-owner/test-repo"; exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/gh"

# Ensure process-compose is available
if ! command -v process-compose &>/dev/null; then
  PC_PATH=$(nix build nixpkgs#process-compose --print-out-paths --no-link 2>/dev/null)/bin
  export PATH="$MOCK_BIN:$PC_PATH:$PATH"
else
  export PATH="$MOCK_BIN:$PATH"
fi
export GH_CALL_LOG="$WORK/gh-calls.log"

# Test git repo
export TEST_REPO="$WORK/repo"
mkdir -p "$TEST_REPO"
cd "$TEST_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "hello" > file.txt
git add file.txt
git commit -q -m "initial"
git remote add origin https://github.com/test-owner/test-repo.git
export SHA=$(git rev-parse HEAD)

# ── Helpers (available to test files) ────────────────────────────────────────

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

pass() { PASS=$((PASS + 1)); green "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); red   "  FAIL: $1"; }

run_localci() {
  set +e
  OUT=$($LOCALCI "$@" 2>&1)
  RC=$?
  set -e
}

export -f red green pass fail run_localci

# ── Run test files ───────────────────────────────────────────────────────────

for test_file in "$TEST_DIR"/test_*.sh; do
  echo "=== $(basename "$test_file" .sh) ==="
  cd "$TEST_REPO"
  true > "$GH_CALL_LOG"
  # Source the test file so it shares our functions and variables
  source "$test_file"
done

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
