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

Pending + success statuses posted
  $ true > "$GH_CALL_LOG"
  $ localci run --sha HEAD -n test -- echo hello >out 2>&1
  $ grep -c "state=pending" "$GH_CALL_LOG"
  1
  $ grep -c "state=success" "$GH_CALL_LOG"
  1
  $ grep -q "context=localci/test" "$GH_CALL_LOG" && echo ok
  ok

Failure status posted
  $ true > "$GH_CALL_LOG"
  $ localci run --sha HEAD -n test -- false >out 2>&1
  [1]
  $ grep -c "state=failure" "$GH_CALL_LOG"
  1

Context format without --system
  $ true > "$GH_CALL_LOG"
  $ localci run --sha HEAD -n test -- echo hello >out 2>&1
  $ grep -o 'context=[^ ]*' "$GH_CALL_LOG" | head -1
  context=localci/test

Context format with --system
  $ true > "$GH_CALL_LOG"
  $ localci run --sha HEAD -s x86_64-linux -n test -- echo hello >out 2>&1
  $ grep -o 'context=[^ ]*' "$GH_CALL_LOG" | head -1
  context=localci/test/x86_64-linux

--no-signoff skips posting
  $ true > "$GH_CALL_LOG"
  $ localci run --sha HEAD --no-signoff -n test -- echo hello >out 2>&1
  $ test ! -s "$GH_CALL_LOG" && echo ok
  ok
