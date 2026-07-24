\---

description: Clean up local branches whose remote tracking branch is gone. Dry-run by default

argument-hint: "\[--force]"

\---



Find and optionally delete local branches whose remote tracking branch no longer exists:



\## Variables



\- \*\*MODE\*\*: If `--force` is provided, delete branches. Otherwise, dry-run (list only).



\## Protected Branches



The following branches are NEVER deleted, even with `--force`:

\- `main`

\- `master`

\- `develop`

\- `development`

\- The current branch (cannot delete checked-out branch)



\## Workflow



1\. \*\*Fetch with prune to update remote tracking info\*\*:

&#x20;  ```bash

&#x20;  git fetch --prune

&#x20;  ```



&#x20;  This removes remote-tracking references that no longer exist on the remote.



2\. \*\*Find branches with "gone" upstream\*\*:

&#x20;  ```bash

&#x20;  git branch -vv | grep ': gone]'

&#x20;  ```



&#x20;  Parse the output to extract branch names.



3\. \*\*Filter out protected branches\*\*:

&#x20;  Remove `main`, `master`, `develop`, `development`, and current branch from the list.



4\. \*\*Display stale branches\*\*:

&#x20;  If stale branches found:

&#x20;  > \*\*Stale branches found:\*\*

&#x20;  > - `feature/old-feature` (upstream was `origin/feature/old-feature`)

&#x20;  > - `bugfix/resolved-issue` (upstream was `origin/bugfix/resolved-issue`)

&#x20;  > ...



&#x20;  If no stale branches:

&#x20;  > "No stale branches found. Your local branches are in sync with remote."

&#x20;  Stop here.



5\. \*\*Handle based on mode\*\*:



&#x20;  \*\*If dry-run (no `--force`):\*\*

&#x20;  > "These branches would be deleted. Run `/git:prune --force` to delete them."



&#x20;  Stop here—do not delete anything.



&#x20;  \*\*If `--force` provided:\*\*

&#x20;  > "You are about to delete these ${N} branches. This cannot be undone.

&#x20;  > Proceed? (y/n)"



&#x20;  Wait for explicit user confirmation.



6\. \*\*Delete branches (only if --force AND user confirmed)\*\*:

&#x20;  For each branch:

&#x20;  ```bash

&#x20;  git branch -d ${BRANCH\_NAME}

&#x20;  ```



&#x20;  If `-d` fails (branch not fully merged), report:

&#x20;  > "Branch `${BRANCH\_NAME}` is not fully merged. Use `git branch -D ${BRANCH\_NAME}` to force delete."



&#x20;  Ask user if they want to force delete unmerged branches.



7\. \*\*Report results\*\*:

&#x20;  > \*\*Cleanup complete:\*\*

&#x20;  > - Deleted: `feature/old-feature`, `bugfix/resolved-issue`

&#x20;  > - Skipped (not fully merged): `feature/wip-changes`

&#x20;  > - Protected (not touched): `main`, `develop`



\## Edge Cases



\### No stale branches

> "No stale branches found. Your local branches are in sync with remote."



\### All stale branches are protected

> "Found stale branches, but they are all protected (main/master/develop). No action taken."



\### Branch not fully merged

When using `git branch -d` and it fails:

> "Branch `${BRANCH}` has unmerged commits. These commits exist only on this branch:

> ```

> git log main..${BRANCH} --oneline

> ```

> To force delete anyway: `git branch -D ${BRANCH}`

> Warning: This will permanently lose these commits."



\## Notes



\- \*\*Dry-run is the default\*\* - this command will NEVER delete branches without `--force`

\- Even with `--force`, you must confirm before any deletion

\- Protected branches are never deleted regardless of flags

\- Use this command after merging PRs to clean up feature branches

\- This only affects LOCAL branches—it does not delete anything on the remote



