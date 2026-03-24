# GitHub status posting tests

CURRENT_SYSTEM=$(nix eval --raw --impure --expr builtins.currentSystem)

# Posts pending + success
true > "$GH_CALL_LOG"
run_localci --sha "$SHA" -n test -- true
if grep -q "pending" "$GH_CALL_LOG" && grep -q "success" "$GH_CALL_LOG"; then
  pass "posts pending and success statuses"
else
  fail "posts pending and success statuses"
fi

# Posts failure status
true > "$GH_CALL_LOG"
run_localci --sha "$SHA" -n test -- false
if grep -q "failure" "$GH_CALL_LOG"; then
  pass "posts failure status on error"
else
  fail "posts failure status on error"
fi

# Context without --system: localci/<name>
true > "$GH_CALL_LOG"
run_localci --sha "$SHA" -n mycheck -- true
if grep -q "localci/mycheck" "$GH_CALL_LOG"; then
  pass "context: localci/<name> without --system"
else
  fail "context: localci/<name> without --system"
fi

# Context with --system: localci/<name>/<system>
true > "$GH_CALL_LOG"
run_localci --sha "$SHA" -s "$CURRENT_SYSTEM" -n mycheck -- true
if grep -q "localci/mycheck/$CURRENT_SYSTEM" "$GH_CALL_LOG"; then
  pass "context: localci/<name>/<system> with --system"
else
  fail "context: localci/<name>/<system> with --system"
fi
