\---

description: Full sync - fetch, rebase onto remote branch, and push

argument-hint: "\[remote] \[branch]"

\---



Perform a full sync cycle: fetch from remote, rebase current branch, and push:



\## Variables



\- \*\*REMOTE\*\*: First argument, defaults to `origin`

\- \*\*BRANCH\*\*: Second argument, defaults to current branch's upstream tracking branch



If user previously specified a different remote in this session, use that as the default instead of `origin`.



\## Pre-flight Checks



1\. \*\*Check for uncommitted changes\*\*:

&#x20;  ```bash

&#x20;  git status --porcelain

&#x20;  ```



&#x20;  If there are uncommitted changes, display a warning with the file list and ask the user:

&#x20;  > "You have uncommitted changes. How would you like to proceed?

&#x20;  > A) Stash changes, proceed with sync, then pop stash

&#x20;  > B) Abort and let me commit/stash manually first

&#x20;  > C) Proceed anyway (risky - changes may conflict)"



&#x20;  Wait for user choice before continuing.



2\. \*\*Check for existing rebase in progress\*\*:

&#x20;  ```bash

&#x20;  ls .git/rebase-merge .git/rebase-apply 2>/dev/null

&#x20;  ```



&#x20;  If rebase is in progress, inform user and offer:

&#x20;  > "A rebase is already in progress. Options:

&#x20;  > - `git rebase --continue` (after resolving conflicts)

&#x20;  > - `git rebase --abort` (to cancel and restore original state)"



3\. \*\*Determine target branch\*\*:

&#x20;  - If BRANCH not specified, get upstream:

&#x20;    ```bash

&#x20;    git rev-parse --abbrev-ref --symbolic-full-name @{upstream} 2>/dev/null

&#x20;    ```

&#x20;  - If no upstream tracking branch, ask user which branch to sync with



\## Workflow



1\. \*\*Fetch from remote\*\*:

&#x20;  ```bash

&#x20;  git fetch ${REMOTE}

&#x20;  ```

&#x20;  Display fetch output to show what was retrieved.



2\. \*\*Show divergence\*\* (informational):

&#x20;  ```bash

&#x20;  git log --oneline HEAD..${REMOTE}/${BRANCH} | head -10

&#x20;  ```

&#x20;  Display incoming commits (if any).



3\. \*\*Rebase onto remote branch\*\*:

&#x20;  ```bash

&#x20;  git rebase ${REMOTE}/${BRANCH}

&#x20;  ```



&#x20;  If conflicts occur, stop and provide conflict resolution guidance (see below).



4\. \*\*Confirm before push\*\*:

&#x20;  After successful rebase, show what will be pushed:

&#x20;  ```bash

&#x20;  git log --oneline ${REMOTE}/${BRANCH}..HEAD

&#x20;  ```



&#x20;  Ask user:

&#x20;  > "Ready to push these commits to ${REMOTE}/${BRANCH}? (y/n)"



&#x20;  Only proceed with push if user confirms.



5\. \*\*Push to remote\*\*:

&#x20;  ```bash

&#x20;  git push ${REMOTE} HEAD

&#x20;  ```



&#x20;  If push fails due to non-fast-forward:

&#x20;  > "Push rejected - remote has new commits. This can happen if someone else pushed while you were rebasing.

&#x20;  > Options:

&#x20;  > - Run `/git:sync` again to incorporate new remote changes

&#x20;  > - Use `git push --force-with-lease` (only if you're certain)"



6\. \*\*Report success\*\*:

&#x20;  > "Successfully synced with ${REMOTE}/${BRANCH}"



&#x20;  Show final status:

&#x20;  ```bash

&#x20;  git status

&#x20;  ```



\## Conflict Resolution



If the rebase encounters conflicts:



> \*\*Rebase Conflict Detected\*\*

>

> The rebase stopped due to conflicts. To resolve:

>

> 1. Open each conflicted file and resolve the conflicts

>    - Look for `<<<<<<<`, `=======`, and `>>>>>>>` markers

>    - Keep the changes you want, remove the markers

>

> 2. After resolving each file:

>    ```bash

>    git add <resolved-file>

>    ```

>

> 3. Continue the rebase:

>    ```bash

>    git rebase --continue

>    ```

>

> 4. After rebase completes, I'll continue with the push step.

>

> \*\*To abort and restore original state:\*\*

> ```bash

> git rebase --abort

> ```

>

> Tell me which file you need help with and I'll analyze the conflicting changes.



\## Notes



\- If user specifies a custom REMOTE, remember it for subsequent `/git:fr` or `/git:sync` calls in this session

\- Always confirm before pushing to avoid accidental pushes to shared branches

\- \*\*DO NOT\*\* use `--force` push unless explicitly requested by user

\- This command performs a full sync cycle; use `/git:fr` if you only want fetch+rebase without push



