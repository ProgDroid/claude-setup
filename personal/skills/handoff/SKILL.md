---
name: handoff
description: Use in a repo that carries .claude/handoff.json (or whose CLAUDE.md has a "Session routine" pointing here) at session start, at the end of session, before shipping, or whenever NEXT.md or a "handoff:" commit comes up - the NEXT.md handoff routine, how to hand off, the squash and worktree rules, and how to opt a repo in
---

# The NEXT.md handoff

A repo that opts in keeps a `NEXT.md` written **for the developer**: what to try, what to judge,
what is a known stand-in, in plain words. Each session ends with a `handoff:` commit holding
`NEXT.md` alone. That commit is the anchor for "what changed since the agent last handed off".

The remembering is done by the hooks, not by you. In an opted-in repo they put the anchor, the
changes and the question into your context at session start, and they remind you when you ship
without handing off. Everywhere else they are silent.

## The routine

1. **Session start.** Ask the developer the repo's question. It is the `ask` key of
   `.claude/handoff.json`, and defaults to "How did the last change go?". Record the answer, dated,
   in `NEXT.md`'s `## Feedback log`, newest first.
2. **Then show what changed since the last handoff.** The SessionStart hook has already computed
   it: the commits since the anchor (each tagged `[agent]` or `[other]`), the uncommitted changes,
   and the diff of the marker's `paths`. If it says the last session ended without a handoff,
   rebuild `NEXT.md` from `git log <anchor>..HEAD` and hand off before starting new work.
3. **Session end.** Update `NEXT.md` and commit it **on its own**, with a subject starting
   `handoff:`. Do the edit and the commit **in the same turn** (see "Cloud sessions" below).
4. **A squash merge to the default branch also starts with `handoff:`**, so the anchor survives the
   squash. This is the one `handoff:` commit allowed to hold more than `NEXT.md`.

The `handoff:` commit carries the generic trailer:

```
handoff: <one line on where things stand>

Co-Authored-By: Claude <noreply@anthropic.com>
```

Write the message to a file and commit with `git commit -F <file> -- NEXT.md`, so nothing else
that happens to be staged goes in with it.

## Lessons already paid for

- The anchor is a commit only the agent writes: the newest commit whose SUBJECT starts `handoff:`
  — never "the last commit touching NEXT.md", so a developer commit touching NEXT.md and other files
  together is never skipped. **Match the subject only** (`git log --format='%H %s'` filtered on the
  subject): `--grep='^handoff:'` also matches BODY lines (measured 2026-10-15, red team).
- Never `git log --since <sha>`: `--since` takes a date; given a SHA it prints nothing and exits 0.
- **No anchor → ask, never guess — as a RECOGNITION question:** list the last 10 commits (subject,
  date) and ask the developer to pick the one to diff from; never ask for a SHA.
- Never edit `NEXT.md` in a LINKED WORKTREE: hand off after the merge, in the developer's main
  checkout (it often holds uncommitted session notes, so a worktree edit conflicts). The branch does
  not matter: the reference project hands off on a `claude/*` branch in its main checkout.
- Friction is the master variable: the remembering is on the agent and the hooks; every question
  to the developer is recognition, never recall.

## Writing NEXT.md

It is for the developer, not for the next agent. Plain words, no internal jargon, no task ids
without a sentence saying what they are. The starting template has these sections, each with a
one-line hint: `Where we are`, `How to run`, `How it behaves`, `Try this`, `Things you might
notice`, `Tell me if`, `Housekeeping`, `Known rough edges`, `Feedback log`. Keep it current rather
than growing it: replace what is stale, and keep only the feedback log as a history.

- **Try this** names what is worth trying since the last handoff, as steps the developer can do.
- **Things you might notice** names stand-ins and placeholders, so they are not reported as bugs.
- **Tell me if** says what to judge. The next session's question is answered against it.

## The worktree rule

A linked worktree is one where `git rev-parse --git-dir` and `--git-common-dir` differ (the SDD
default for plan execution). There:

- never edit `NEXT.md`, and never make a `handoff:` commit;
- finish the branch, merge it, then hand off **in the main checkout**. The PostToolUse hook warns
  if `NEXT.md` is edited in a linked worktree, and its shipping reminder says "after the merge".

The branch itself does not matter. Handing off on a feature branch in the main checkout is fine.

## The squash rule

When a branch is squash-merged into the default branch, the squash commit's subject starts
`handoff:`. Otherwise the branch's own `handoff:` commits vanish in the squash, and every later
session asks the developer to pick a commit again.

- A local `git merge --squash`: write the squash commit's subject as `handoff: ...`, and update
  `NEXT.md` in it. The post-commit check will name the other files; this is the exception it
  mentions, so carry on.
- A squash done on GitHub uses the PR title as its subject. When you open a PR that will be
  squash-merged in an opted-in repo, tell the developer that the squash subject must start
  `handoff:`, and offer to title the PR that way.

## Cloud sessions: the auto-commit sweep

In a cloud session the plugin's Stop hook commits everything (`git add -A`) as
`chore: auto-commit work in progress` at the end of EVERY turn, on any branch but main/master. If a
turn ends between editing `NEXT.md` and committing it, `NEXT.md` is swept into that auto-commit and
the `handoff:` commit has nothing left to hold.

- **Edit `NEXT.md` and commit it as `handoff:` in the same turn.**
- If it was already swept, make the anchor anyway, as an empty commit:
  `git commit --allow-empty -F <file>` with a subject starting `handoff:`, after checking that
  `git diff --cached --name-only` is empty (anything staged would go in with it). The hooks treat
  an empty `handoff:` commit as a clean anchor.

## What the hooks do

All three exit silently in a repo without `.claude/handoff.json`.

| Hook | When | What it puts in your context |
|---|---|---|
| SessionStart, source `startup` | a new session | the question; the commits since the anchor, the uncommitted changes and the `paths` diff (or, with no anchor, the last 10 commits to PICK from); "the last session ended without a handoff" when agent commits follow the anchor; the end-of-session duty |
| SessionStart, source `compact` | after a compaction | the handoff reminder, only when agent commits follow the anchor |
| PostToolUse, Bash/PowerShell | after a `git commit` or `git merge` | a warning when the new `handoff:` commit holds files other than `NEXT.md` (a merge is compared with its first parent) |
| PostToolUse, Bash/PowerShell | after `git push`, `gh pr create`, `gh pr merge`, `git merge` | "hand off now" when agent commits follow the anchor and HEAD is not a `handoff:` commit |
| PostToolUse, Edit/Write/MultiEdit | after an edit of the repo-root `NEXT.md` | a warning in a linked worktree |

Two situations change what they say:

- **A shallow clone** with no `handoff:` commit in reach: the anchor may lie beyond the cut-off,
  so startup says the history is shallow (unknown, not "no anchor") and offers the PICK list or
  `git fetch --unshallow`. The compact and shipping reminders cannot tell whether a handoff is
  pending there, so they stay off, and startup says so: the end-of-session duty is yours alone.
- **A linked worktree, or a folder git cannot place:** agent commits after the anchor are expected
  there (handing off is not allowed), so startup counts them without calling the handoff missed,
  and every reminder says "hand off after the merge, in the main checkout". The `NEXT.md` edit
  warning needs a worktree git can confirm as linked.

`[agent]` means a `Co-Authored-By:` trailer whose value is `Claude` followed by a space, `<` or
nothing (the generic trailer and a model-name one alike), or a subject starting
`chore: auto-commit`. Everything else is `[other]`. It is a listing, not an authorship claim:
other tools commit without the trailer too.

## Opting a repo in

Run the project-start ritual's `handoff` step from the **main checkout**. In a linked worktree it
reports `unknown` and writes nothing; when it does, tell the developer to run it from the main
checkout.

1. `ritual.sh fix handoff <repo> [--ask "<question>"] [--paths "<glob> <glob>"]` creates `NEXT.md`
   from the template, writes `.claude/handoff.json`, and adds the `## Session routine` pointer to
   `CLAUDE.md`. If `.claude/` is git-ignored, the marker stays local and the step says cloud
   sessions will not see it; the ignore rules are never rewritten.
2. The ritual's commit step commits the marker and `CLAUDE.md`.
3. `ritual.sh handoff-commit <repo>` makes the first `handoff:` commit, holding `NEXT.md` alone (or
   an empty anchor when `NEXT.md` is already committed).

Both steps report under the same step id, `handoff`. Record them deliberately: the step's result is
the `fix handoff` outcome, and the `handoff-commit` outcome goes in that step's note, unless the
anchor could not be made, in which case the result is `failed`. Never let the second result
silently overwrite the first.

The marker's keys are both optional:

```json
{"ask": "Did the new build run well?", "paths": ["config/*.toml", "data/*.csv"]}
```

`"ask"` replaces the default question. `"paths"` lists hand-edited globs whose diff since the
anchor is shown at session start, committed or not.
