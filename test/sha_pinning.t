Setup
  $ export GIT_AUTHOR_NAME="Test" GIT_COMMITTER_NAME="Test" GIT_AUTHOR_EMAIL="t@t" GIT_COMMITTER_EMAIL="t@t"
  $ git init -q repo
  $ cd repo
  $ echo hello > file.txt
  $ git add .
  $ git commit -qm init
  $ N='s/[a-f0-9]\{12,\}/SHA/g; s/in [0-9][0-9hms]*/in Xs/g'

--sha skips dirty tree check and runs archived content
  $ echo dirty > file.txt
  $ localci run --sha HEAD --no-signoff -n test -- cat file.txt 2>&1 | sed "$N"
  ==> localci/test  SHA
      cat file.txt
  ==> Extracting repo...
  hello
  ==> localci/test passed in Xs

Without --sha, dirty tree fails
  $ localci run --no-signoff -n test -- echo hello 2>&1
  Error: Working tree is dirty. Commit or stash changes first.
  [1]
