Setup
  $ export GIT_AUTHOR_NAME="Test" GIT_COMMITTER_NAME="Test" GIT_AUTHOR_EMAIL="t@t" GIT_COMMITTER_EMAIL="t@t"
  $ git init -q repo
  $ cd repo
  $ echo hello > file.txt
  $ git add .
  $ git commit -qm init
  $ N='s/[a-f0-9]\{12,\}/SHA/g; s/in [0-9][0-9hms]*/in Xs/g'

Command succeeds and shows output
  $ localci run --sha HEAD --no-signoff -n test -- echo hello 2>&1 | sed "$N"
  ==> localci/test  SHA
      echo hello
  ==> Extracting repo...
  hello
  ==> localci/test passed in Xs

Command failure propagates exit code
  $ localci run --sha HEAD --no-signoff -n test -- false >out 2>&1
  [1]
  $ sed "$N" out
  ==> localci/test  SHA
      false
  ==> Extracting repo...
  ==> localci/test failed (exit 1) in Xs

Missing command shows error
  $ localci run --sha HEAD --no-signoff 2>&1
  Error: A command after -- is required (or use -f for multi-step mode).
  [1]

Not in git repo
  $ cd /tmp
  $ localci run --sha HEAD --no-signoff -n test -- echo hello 2>&1
  Error: Not inside a git repository.
  [1]
