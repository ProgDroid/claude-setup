\---

description: Fast-forward merge only - update branch without rebase or merge commits

argument-hint: "\[remote] \[branch]"

\---



Attempt a fast-forward merge from the remote branch (no rebase, no merge commits):



\## Variables



\- \*\*REMOTE\*\*: First argument, defaults to `origin`

\- \*\*BRANCH\*\*: Second argument, defaults to current branch's upstream tracking branch



\## Pre-flight Checks



1\. \*\*Check for uncommitted changes\*\*:

&#x20;  ```bash

&#x20;  git status --porcelain

&#x20;  ```



&#x20;  If there are uncommitted changes:

&#x20;  > "You have uncommitted changes. Fast-forward merge requires a clean working directory.

&#x20;  > Please commit or stash your changes first."



&#x20;  Do not proceed until working directory is clean.



2\. \*\*Determine target branch\*\*:

&#x20;  - If BRANCH not specified, get upstream:

&#x20;    ```bash

&#x20;    git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null

&#x20;    ```

&#x20;  - If no upstream tracking branch, ask user which branch to merge from



\## Workflow



1\. \*\*Fetch from remote\*\*:

&#x20;  ```bash

&#x20;  git fetch ${REMOTE}

&#x20;  ```



2\. \*\*Check if fast-forward is possible\*\*:

&#x20;  ```bash

&#x20;  git merge-base --is-ancestor HEAD ${REMOTE}/${BRANCH}

&#x20;  ```



&#x20;  If exit code is 0: fast-forward is possible

&#x20;  If exit code is non-0: fast-forward is NOT possible



3\. \*\*If fast-forward possible, perform merge\*\*:

&#x20;  ```bash

&#x20;  git merge --ff-only ${REMOTE}/${BRANCH}

&#x20;  ```



&#x20;  Report success:

&#x20;  > "Successfully fast-forwarded to ${REMOTE}/${BRANCH}"



&#x20;  Show new commits:

&#x20;  ```bash

&#x20;  git log --oneline -10

&#x20;  ```



4\. \*\*If fast-forward NOT possible\*\*:

&#x20;  > \*\*Fast-forward not possible\*\*

&#x20;  >

&#x20;  > Your branch has diverged from ${REMOTE}/${BRANCH}. This means you have local commits that aren't on the remote.

&#x20;  >

&#x20;  > Your options:

&#x20;  >

&#x20;  > 1. \*\*Rebase\*\* (recommended for feature branches):

&#x20;  >    ```bash

&#x20;  >    /git:fr

&#x20;  >    ```

&#x20;  >    This replays your commits on top of the remote branch.

&#x20;  >

&#x20;  > 2. \*\*Merge\*\* (creates a merge commit):

&#x20;  >    ```bash

&#x20;  >    git merge ${REMOTE}/${BRANCH}

&#x20;  >    ```

&#x20;  >    This preserves both histories with a merge commit.

&#x20;  >

&#x20;  > 3. \*\*Reset\*\* (discard local commits - destructive!):

&#x20;  >    ```bash

&#x20;  >    git reset --hard ${REMOTE}/${BRANCH}

&#x20;  >    ```

&#x20;  >    \*\*Warning\*\*: This discards your local commits permanently.



\## Notes



\- Fast-forward is the safest way to update a branch—no history rewriting, no merge commits

\- Ideal for pulling updates on branches you haven't modified locally

\- If you need to incorporate changes from a branch you've worked on, use `/git:fr` instead

\- This command never creates merge commits or rewrites history



