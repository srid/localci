Setup
  $ export GIT_AUTHOR_NAME="Test" GIT_COMMITTER_NAME="Test" GIT_AUTHOR_EMAIL="t@t" GIT_COMMITTER_EMAIL="t@t"
  $ git init -q repo
  $ cd repo
  $ echo hello > file.txt
  $ git add .
  $ git commit -qm init
  $ git remote add origin https://github.com/test-owner/test-repo.git
  $ mkdir -p mock-bin
  $ cat > mock-bin/gh << 'MOCK'
  > #!/bin/sh
  > echo "$@" >> "${GH_CALL_LOG:-/dev/null}"
  > if [ "$1" = "repo" ] && [ "$2" = "view" ]; then
  >   echo "test-owner/test-repo"; exit 0
  > fi
  > exit 0
  > MOCK
  $ chmod +x mock-bin/gh
  $ export PATH="$PWD/mock-bin:$PATH"
  $ export GH_CALL_LOG="$PWD/gh-calls.log"

Two independent steps succeed
  $ cat > ci.json << 'EOF'
  > {"steps": {"alpha": {"command": "echo alpha-ok"}, "beta": {"command": "echo beta-ok"}}}
  > EOF
  $ localci -f ci.json --sha HEAD --no-signoff >out 2>&1
  $ grep "All steps passed" out >/dev/null && echo ok
  ok

Dependency ordering
  $ cat > ci.json << 'EOF'
  > {"steps": {"first": {"command": "echo first"}, "second": {"command": "echo second", "depends_on": ["first"]}}}
  > EOF
  $ localci -f ci.json --sha HEAD --no-signoff >out 2>&1
  $ grep "All steps passed" out >/dev/null && echo ok
  ok

Failure propagation
  $ cat > ci.json << 'EOF'
  > {"steps": {"good": {"command": "echo good"}, "bad": {"command": "false"}}}
  > EOF
  $ localci -f ci.json --sha HEAD --no-signoff >out 2>&1
  [1]
  $ grep "One or more steps failed" out >/dev/null && echo ok
  ok

Config file not found
  $ localci -f nonexistent.json --sha HEAD --no-signoff 2>&1
  Error: config file not found: nonexistent.json
  [1]

GitHub statuses posted for multi-step
  $ cat > ci.json << 'EOF'
  > {"steps": {"alpha": {"command": "echo ok"}, "beta": {"command": "echo ok"}}}
  > EOF
  $ true > "$GH_CALL_LOG"
  $ localci -f ci.json --sha HEAD >out 2>&1
  $ grep -c "state=pending" "$GH_CALL_LOG"
  2
  $ grep -c "state=success" "$GH_CALL_LOG"
  2
