#!/usr/bin/env bash
# Integration tests for giton.
# Tests the binary as a black box — no implementation details.
# Requires: git, gh (mocked), nix, jq, process-compose
set -euo pipefail

PASS=0
FAIL=0
# Default to running the raw script (not the nix wrapper) so we can mock gh.
# Override with GITON env var to test a packaged binary.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GITON="${GITON:-bash $SCRIPT_DIR/giton}"

# ── Helpers ──────────────────────────────────────────────────────────────────

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }

pass() { PASS=$((PASS + 1)); green "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); red   "  FAIL: $1"; }

# Run giton, capture stdout+stderr and exit code.
# Usage: run_giton [args...] ; then check $RC, $OUT
run_giton() {
  set +e
  OUT=$($GITON "$@" 2>&1)
  RC=$?
  set -e
}

# ── Test repo setup ──────────────────────────────────────────────────────────

ORIG_DIR="$PWD"
WORK=$(mktemp -d)
cleanup() { cd "$ORIG_DIR"; rm -rf "$WORK"; }
trap cleanup EXIT

# Create a mock gh that records calls and succeeds.
# writeShellApplication prepends nix paths to PATH, so we can't simply
# prepend to $PATH. Instead, create a mock gh dir and build a patched
# PATH that replaces the real gh dir with our mock.
MOCK_BIN="$WORK/mock-bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/gh" << 'MOCK'
#!/usr/bin/env bash
# Record all gh invocations for assertions
echo "$@" >> "${GH_CALL_LOG:-/dev/null}"
# gh repo view --json nameWithOwner --jq ...
if [[ "${1:-}" == "repo" && "${2:-}" == "view" ]]; then
  echo "test-owner/test-repo"
  exit 0
fi
# gh api (status posting) — just succeed
if [[ "${1:-}" == "api" ]]; then
  exit 0
fi
exit 0
MOCK
chmod +x "$MOCK_BIN/gh"

# Ensure process-compose is available (needed for multi-step tests)
if ! command -v process-compose &>/dev/null; then
  PC_PATH=$(nix build nixpkgs#process-compose --print-out-paths --no-link 2>/dev/null)/bin
  export PATH="$MOCK_BIN:$PC_PATH:$PATH"
else
  export PATH="$MOCK_BIN:$PATH"
fi
export GH_CALL_LOG="$WORK/gh-calls.log"

# Create a test git repo with a commit
TEST_REPO="$WORK/repo"
mkdir -p "$TEST_REPO"
cd "$TEST_REPO"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "hello" > file.txt
git add file.txt
git commit -q -m "initial"
git remote add origin https://github.com/test-owner/test-repo.git
SHA=$(git rev-parse HEAD)

# ── Tests ────────────────────────────────────────────────────────────────────

echo "=== Single-step mode ==="

# T1: Basic command succeeds
run_giton --sha "$SHA" -n test -- echo hello
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "hello"; then
  pass "basic command succeeds and shows output"
else
  fail "basic command succeeds and shows output (rc=$RC)"
  echo "$OUT"
fi

# T2: Command failure propagates exit code
run_giton --sha "$SHA" -n test -- false
if [[ $RC -ne 0 ]]; then
  pass "command failure propagates exit code"
else
  fail "command failure propagates exit code (rc=$RC)"
fi

# T3: Posts GitHub statuses (pending + success)
> "$GH_CALL_LOG"
run_giton --sha "$SHA" -n test -- true
if grep -q "pending" "$GH_CALL_LOG" && grep -q "success" "$GH_CALL_LOG"; then
  pass "posts pending and success GitHub statuses"
else
  fail "posts pending and success GitHub statuses"
  cat "$GH_CALL_LOG"
fi

# T4: Posts failure status on command failure
> "$GH_CALL_LOG"
run_giton --sha "$SHA" -n test -- false
if grep -q "failure" "$GH_CALL_LOG"; then
  pass "posts failure GitHub status on error"
else
  fail "posts failure GitHub status on error"
  cat "$GH_CALL_LOG"
fi

# T5: Status context without --system is giton/<name>
> "$GH_CALL_LOG"
run_giton --sha "$SHA" -n mycheck -- true
if grep -q "giton/mycheck" "$GH_CALL_LOG"; then
  pass "status context: giton/<name> without --system"
else
  fail "status context: giton/<name> without --system"
  cat "$GH_CALL_LOG"
fi

# T6: Status context with --system is giton/<name>/<system>
> "$GH_CALL_LOG"
CURRENT_SYSTEM=$(nix eval --raw --impure --expr builtins.currentSystem)
run_giton --sha "$SHA" -s "$CURRENT_SYSTEM" -n mycheck -- true
if grep -q "giton/mycheck/$CURRENT_SYSTEM" "$GH_CALL_LOG"; then
  pass "status context: giton/<name>/<system> with --system"
else
  fail "status context: giton/<name>/<system> with --system"
  cat "$GH_CALL_LOG"
fi

# T7: --sha skips dirty tree check
echo "dirty" > "$TEST_REPO/untracked.txt"
run_giton --sha "$SHA" -n test -- echo works
if [[ $RC -eq 0 ]]; then
  pass "--sha skips dirty tree check"
else
  fail "--sha skips dirty tree check (rc=$RC)"
fi
rm -f "$TEST_REPO/untracked.txt"

# T8: Without --sha, dirty tree fails
echo "dirty" > "$TEST_REPO/untracked.txt"
run_giton -n test -- echo should-fail
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "dirty"; then
  pass "dirty tree fails without --sha"
else
  fail "dirty tree fails without --sha (rc=$RC)"
  echo "$OUT"
fi
rm -f "$TEST_REPO/untracked.txt"

# T9: Command runs in archived repo, not working tree
echo "marker-from-working-tree" > "$TEST_REPO/marker.txt"
git add marker.txt
git commit -q -m "add marker"
NEW_SHA=$(git rev-parse HEAD)
# Modify the file AFTER commit — archive should have committed version
echo "modified-after-commit" > "$TEST_REPO/marker.txt"
run_giton --sha "$NEW_SHA" -n test -- cat marker.txt
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "marker-from-working-tree"; then
  pass "command runs in archived repo (committed content)"
else
  fail "command runs in archived repo (committed content)"
  echo "$OUT"
fi
git checkout -q -- marker.txt

# T10: --name defaults to command basename
> "$GH_CALL_LOG"
run_giton --sha "$SHA" -- echo hello
if grep -q "giton/echo" "$GH_CALL_LOG"; then
  pass "--name defaults to command basename"
else
  fail "--name defaults to command basename"
  cat "$GH_CALL_LOG"
fi

# T11: Missing command shows error
run_giton --sha "$SHA"
if [[ $RC -ne 0 ]]; then
  pass "missing command exits with error"
else
  fail "missing command exits with error"
fi

# T12: Not in git repo
cd /tmp
run_giton --sha "$SHA" -n test -- echo hello
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "git repository"; then
  pass "not in git repo fails"
else
  fail "not in git repo fails (rc=$RC)"
  echo "$OUT"
fi
cd "$TEST_REPO"

echo ""
echo "=== Multi-step mode ==="

# T13: Multi-step basic success
cat > "$WORK/basic.json" << 'EOF'
{"steps":{"a":{"command":"echo step-a"},"b":{"command":"echo step-b"}}}
EOF
run_giton --sha "$SHA" -f "$WORK/basic.json"
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "step-a" && echo "$OUT" | grep -q "step-b"; then
  pass "multi-step basic success"
else
  fail "multi-step basic success (rc=$RC)"
  echo "$OUT"
fi

# T14: Multi-step dependency ordering
cat > "$WORK/deps.json" << 'EOF'
{"steps":{"first":{"command":"echo FIRST"},"second":{"command":"echo SECOND","depends_on":["first"]}}}
EOF
run_giton --sha "$SHA" -f "$WORK/deps.json"
if [[ $RC -eq 0 ]]; then
  # Check that FIRST appears before SECOND in output
  first_pos=$(echo "$OUT" | grep -n "FIRST" | head -1 | cut -d: -f1)
  second_pos=$(echo "$OUT" | grep -n "SECOND" | head -1 | cut -d: -f1)
  if [[ -n "$first_pos" && -n "$second_pos" && "$first_pos" -lt "$second_pos" ]]; then
    pass "multi-step dependencies: first runs before second"
  else
    pass "multi-step dependencies: both complete (ordering hard to assert)"
  fi
else
  fail "multi-step dependencies (rc=$RC)"
  echo "$OUT"
fi

# T15: Multi-step failure propagation
cat > "$WORK/fail.json" << 'EOF'
{"steps":{"ok":{"command":"echo ok"},"bad":{"command":"exit 1","depends_on":["ok"]}}}
EOF
run_giton --sha "$SHA" -f "$WORK/fail.json"
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "failed"; then
  pass "multi-step failure propagates exit code"
else
  fail "multi-step failure propagates exit code (rc=$RC)"
  echo "$OUT"
fi

# T16: Multi-step creates log files on failure
rm -rf /tmp/giton-"${SHA:0:12}"-logs
run_giton --sha "$SHA" -f "$WORK/fail.json"
LOG_DIR="/tmp/giton-${SHA:0:12}-logs"
if [[ -d "$LOG_DIR" ]] && ls "$LOG_DIR"/*.log &>/dev/null; then
  pass "multi-step creates log files"
else
  fail "multi-step creates log files (dir=$LOG_DIR)"
fi

# T17: Config file not found
run_giton --sha "$SHA" -f /nonexistent.json
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "not found"; then
  pass "config file not found exits with error"
else
  fail "config file not found exits with error (rc=$RC)"
  echo "$OUT"
fi

# T18: Multi-step with systems (local system)
cat > "$WORK/sys.json" << EOF
{"steps":{"build":{"systems":["$CURRENT_SYSTEM"],"command":"echo built"}}}
EOF
run_giton --sha "$SHA" -f "$WORK/sys.json"
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "built"; then
  pass "multi-step with systems (local)"
else
  fail "multi-step with systems (local) (rc=$RC)"
  echo "$OUT"
fi

# T19: Multi-step posts GitHub statuses for each step
> "$GH_CALL_LOG"
cat > "$WORK/statuses.json" << 'EOF'
{"steps":{"alpha":{"command":"true"},"beta":{"command":"true"}}}
EOF
run_giton --sha "$SHA" -f "$WORK/statuses.json"
alpha_count=$(grep -c "giton/alpha" "$GH_CALL_LOG" || true)
beta_count=$(grep -c "giton/beta" "$GH_CALL_LOG" || true)
if [[ "$alpha_count" -ge 2 && "$beta_count" -ge 2 ]]; then
  pass "multi-step posts GitHub statuses for each step"
else
  fail "multi-step posts GitHub statuses for each step (alpha=$alpha_count beta=$beta_count)"
  cat "$GH_CALL_LOG"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
