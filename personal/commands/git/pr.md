\---

description: Create a pull request

argument-hint: "\[to-branch] \[from-branch]"

\---



\## Variables



TO\_BRANCH: $1 (defaults to `main`)

FROM\_BRANCH: $2 (defaults to current branch)



\## Workflow

\- Use `gh` command to create a pull request from {FROM\_BRANCH} to {TO\_BRANCH} branch.



\## Notes

\- If `gh` command is not available, instruct the user to install and authorize GitHub CLI first.

