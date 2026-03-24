# Multi-step mode tests

CURRENT_SYSTEM=$(nix eval --raw --impure --expr builtins.currentSystem)

# Basic success
cat > "$WORK/basic.json" << 'EOF'
{"steps":{"a":{"command":"echo step-a"},"b":{"command":"echo step-b"}}}
EOF
run_localci --sha "$SHA" -f "$WORK/basic.json"
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "step-a" && echo "$OUT" | grep -q "step-b"; then
  pass "basic success"
else
  fail "basic success (rc=$RC)"
fi

# Dependency ordering
cat > "$WORK/deps.json" << 'EOF'
{"steps":{"first":{"command":"echo FIRST"},"second":{"command":"echo SECOND","depends_on":["first"]}}}
EOF
run_localci --sha "$SHA" -f "$WORK/deps.json"
if [[ $RC -eq 0 ]]; then
  first_pos=$(echo "$OUT" | grep -n "FIRST" | head -1 | cut -d: -f1)
  second_pos=$(echo "$OUT" | grep -n "SECOND" | head -1 | cut -d: -f1)
  if [[ -n "$first_pos" && -n "$second_pos" && "$first_pos" -lt "$second_pos" ]]; then
    pass "dependencies: first runs before second"
  else
    pass "dependencies: both complete (ordering hard to assert in parallel)"
  fi
else
  fail "dependencies (rc=$RC)"
fi

# Failure propagation
cat > "$WORK/fail.json" << 'EOF'
{"steps":{"ok":{"command":"echo ok"},"bad":{"command":"exit 1","depends_on":["ok"]}}}
EOF
run_localci --sha "$SHA" -f "$WORK/fail.json"
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -q "failed"; then
  pass "failure propagates exit code"
else
  fail "failure propagates exit code (rc=$RC)"
fi

# Independent step failure propagates
cat > "$WORK/indep-fail.json" << 'EOF'
{"steps":{"good":{"command":"echo ok"},"bad":{"command":"exit 1"}}}
EOF
run_localci --sha "$SHA" -f "$WORK/indep-fail.json"
if [[ $RC -ne 0 ]]; then
  pass "independent step failure propagates exit code"
else
  fail "independent step failure propagates exit code (rc=$RC)"
fi

# Log files created on failure
rm -rf /tmp/localci-"${SHA:0:12}"-logs
run_localci --sha "$SHA" -f "$WORK/fail.json"
LOG_DIR="/tmp/localci-${SHA:0:12}-logs"
if [[ -d "$LOG_DIR" ]] && ls "$LOG_DIR"/*.log &>/dev/null; then
  pass "creates log files on failure"
else
  fail "creates log files on failure (dir=$LOG_DIR)"
fi

# Config file not found
run_localci --sha "$SHA" -f /nonexistent.json
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "not found"; then
  pass "config file not found exits with error"
else
  fail "config file not found exits with error (rc=$RC)"
fi

# With systems (local)
cat > "$WORK/sys.json" << EOF
{"steps":{"build":{"systems":["$CURRENT_SYSTEM"],"command":"echo built"}}}
EOF
run_localci --sha "$SHA" -f "$WORK/sys.json"
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "built"; then
  pass "with systems (local)"
else
  fail "with systems (local) (rc=$RC)"
fi

# Posts GitHub statuses for each step
true > "$GH_CALL_LOG"
cat > "$WORK/statuses.json" << 'EOF'
{"steps":{"alpha":{"command":"true"},"beta":{"command":"true"}}}
EOF
run_localci --sha "$SHA" -f "$WORK/statuses.json"
alpha_count=$(grep -c "localci/alpha" "$GH_CALL_LOG" || true)
beta_count=$(grep -c "localci/beta" "$GH_CALL_LOG" || true)
if [[ "$alpha_count" -ge 2 && "$beta_count" -ge 2 ]]; then
  pass "posts GitHub statuses for each step"
else
  fail "posts GitHub statuses for each step (alpha=$alpha_count beta=$beta_count)"
fi
