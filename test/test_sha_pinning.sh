# SHA pinning and idempotence tests

# --sha skips dirty tree check
echo "dirty" > "$TEST_REPO/untracked.txt"
run_localci --sha "$SHA" -n test -- echo works
if [[ $RC -eq 0 ]]; then
  pass "--sha skips dirty tree check"
else
  fail "--sha skips dirty tree check (rc=$RC)"
fi
rm -f "$TEST_REPO/untracked.txt"

# Without --sha, dirty tree fails
echo "dirty" > "$TEST_REPO/untracked.txt"
run_localci -n test -- echo should-fail
if [[ $RC -ne 0 ]] && echo "$OUT" | grep -qi "dirty"; then
  pass "dirty tree fails without --sha"
else
  fail "dirty tree fails without --sha (rc=$RC)"
fi
rm -f "$TEST_REPO/untracked.txt"

# Command runs in archived repo, not working tree
echo "marker-from-working-tree" > "$TEST_REPO/marker.txt"
git add marker.txt
git commit -q -m "add marker"
NEW_SHA=$(git rev-parse HEAD)
echo "modified-after-commit" > "$TEST_REPO/marker.txt"
run_localci --sha "$NEW_SHA" -n test -- cat marker.txt
if [[ $RC -eq 0 ]] && echo "$OUT" | grep -q "marker-from-working-tree"; then
  pass "command runs in archived repo (committed content)"
else
  fail "command runs in archived repo (committed content)"
fi
git checkout -q -- marker.txt
