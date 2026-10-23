---
name: cloud-sessions
description: Use when working with Claude Code cloud sessions, plugin marketplaces, or hooks - covers behaviour that contradicts the documentation and cost real sessions to discover
---

# Cloud sessions: what actually happens

Verified against live cloud sessions on 2026-07-24/25. Where this disagrees with the docs, the
docs are wrong — each item below was established by observing a real session, not by reading.

## Declaring a plugin does not install it

The cloud-sessions doc says plugins declared in a repo's `.claude/settings.json` are *"installed
at session start."* They are not.

A session whose repo declared two marketplaces and nine plugins reported:

- `claude plugin list` → `No plugins installed`
- `claude plugin marketplace list` → only the built-in `claude-plugins-official`

`enabledPlugins` is a declaration of intent. Something has to act on it, and an unattended session
has nobody to accept the install prompt. **Use an environment setup script** that runs
`claude plugin marketplace add` then `claude plugin install` explicitly. Both CLI commands are
non-interactive and default to `user` scope.

Add `anthropics/claude-plugins-official` explicitly too. It is registered by default but its
catalog is not fetched at setup-script time, so installs from it silently resolve to nothing —
a run that added only custom marketplaces installed both of their plugins and none of the eight
official ones.

## Editing a plugin does not change the running session

Plugins load from `~/.claude/plugins/cache/<owner>/<plugin>/<version>/`, keyed by the `version` in
`plugin.json`. **The cache is what runs. The repo working copy is not.**

Verified 2026-09-15: a skill edited in `personal/skills/` was invoked in the same session minutes
later and served the *old* text, from `.../progdroid/personal/0.11.7/`, while the repo had already
moved to 0.11.8.

- **A fix is not live until the version is bumped.** Bump `plugin.json` and `marketplace.json`
  together — a fix committed under an unchanged version sits behind a cache directory that no
  longer matches its source, and a later session loads the stale copy.
- **Never confirm plugin behaviour by reading the repo.** Read the cached path, or check which
  version the session actually loaded. They disagree exactly when you are mid-edit, which is
  exactly when you are looking.

**Exception: a marketplace added from a local directory** (`known_marketplaces.json` source
`"directory"`). Verified 2026-10-23 (cli-timer): the skill's base directory was the checkout
(`G:\rustDev\cli-timer\plugin\skills\timer`), not the cache, so the working copy IS what runs,
re-read at each session start. A resumed session kept the old path (it served a skill folder that
had since been moved); only a full restart picked up the new one.

## Installing from a local checkout copies the whole plugin folder

Install still copies the plugin's `source` folder into the cache, with no way to exclude
anything: `.gitignore` is ignored (a `"source": "./"` repo copied its 1.7 GB `target/`), though
`.git/` was left out. Give the plugin its own folder (`"source": "./plugin"`).

- A same-version reinstall reuses the cached folder: uninstall, delete
  `~/.claude/plugins/cache/<marketplace>/`, `claude plugin marketplace update <m>`, install.
- Test a branch's GitHub install without touching the real setup:
  `CLAUDE_CONFIG_DIR=<empty dir> claude plugin marketplace add 'https://github.com/<o>/<r>.git#<branch>'`,
  then `claude plugin install <p>@<m>` and inspect `<dir>/plugins/cache/`. Checksum the real
  `~/.claude/plugins/*.json` before and after to prove the test stayed isolated.

## A SessionStart hook cannot deliver files to its own session

The memory subsystem reads its index when the session starts. A `SessionStart` hook runs after
that, so **files it writes are not picked up by the session that ran it.** Locally that is
survivable — the next session sees them. A cloud VM has no next session.

A hook that copied 13 memories into place reported `Loaded 13 memories` and the session then had
none of their content. The copy succeeded; the outcome did not happen.

**A SessionStart hook's stdout IS injected into the session as context.** So a hook that wants the
model to know something must *print* it, not write it. Print an index and let the model read
bodies on demand — that keeps startup cost flat as the corpus grows.

## Project key format

`~/.claude/projects/<key>/` where the key is the absolute path with backslashes turned into `/`, a `/x/rest` path (single-letter first segment) rewritten to `X:/rest` under Git Bash/MSYS/Cygwin only (an `x:/rest` path is upper-cased to `X:/rest` on every platform), and then every character outside `[A-Za-z0-9]` (separators, spaces, underscores, dots) replaced by `-`.

| Platform | Path | Key |
|---|---|---|
| Cloud VM | `/home/user/repo` | `-home-user-repo` |
| Windows/MSYS | `/g/rustDev/aba` | `G--rustDev-aba` |
| Underscores | `/g/flutterDev/my_app` | `G--flutterDev-my-app` |
| Dotted worktree (Git Bash) | `/g/x/.claude/worktrees/y` | `G--x--claude-worktrees-y` |

A single-repo cloud session starts in `/home/user/repo`. Deriving the key wrongly fails
**silently** — the write lands in a directory nothing reads, with no error. Underscore
normalisation was missed twice, in two separate files, and both times the symptom was nothing
happening.

### Multi-repo sessions start in `/home/user`, which is not a repo

Verified 2026-10-03: a session with two repos (`/home/user/cue`, `/home/user/claude-setup`) started
with cwd `/home/user`. `hydrate-memory.sh` fell back to `$PWD`, keyed `-home-user`, and hydrated
nothing — every repo's `.claude/memory/` was invisible all session.

**Fixed in personal 0.11.13:** when the cwd is not inside a repo, the hook hydrates each child git
repo under its own key (`-home-user-<repo>`) and prints each repo's index under its own heading.

**Fixed in personal 0.11.14 for the Stop side:** `auto-commit.sh` now acts on every repo of the
session: the cwd's repo plus its sibling repos (when their parent is not itself a repo), or every
child repo when the cwd is the plain parent. Each repo syncs memories under its own key and commits
and pushes its own branch; repos on `main` are still left alone. A memory written for a repo that is
on `main` is therefore still not carried back: commit it yourself on a branch.

Because the hook now scans the parent of the cwd's repo, its tests create every repo inside its own
`mktemp -d` parent. A repo created directly in `/tmp` would make every git repo in `/tmp` a sibling.

## `CLAUDE_CLOUD_SESSION=1` is exported into every process

The gate the memory hooks read is a real environment variable in the cloud environment, so
everything launched inside a session inherits it — including the test scripts for those hooks.

Verified 2026-09-15: `test-sync-memory.sh`, `test-auto-commit.sh` and `test-hydrate-memory.sh`
showed 5 failures between them in a cloud session and 0 on the same commit with the variable
unset. Every one was a case asserting *"does nothing when the gate is unset"*, failing against a
hook that was behaving correctly.

**A test for gated behaviour must `unset` the gate at the top and let each case set it.** The
failure mode is worse than a red suite: it points the investigation at the hook, which is fine,
and at a bug that is not there, which is not.

## Only what is in the clone is guaranteed

Three delivery mechanisms, not equally reliable:

1. **Part of the clone** — `.claude/skills|agents|commands|rules/`, `CLAUDE.md`, `.mcp.json`,
   and anything else committed. No fetch, no auth, no install. Guaranteed.
2. **Setup script** — runs as root pre-launch, output cached per environment. Reliable, needs
   authoring.
3. **Declared plugins** — recognised but not installed. Requires (2) to work at all.

Prefer tier 1 wherever both are possible.

User-scope config never travels: `~/.claude/CLAUDE.md`, `~/.claude/skills|agents|commands/`,
plugins enabled only in user settings, and MCP servers added with `claude mcp add`. A `false`
flag under `enabledPlugins` does **not** mean the capability is unused — it often means it is
registered as a user-scope MCP server instead, which is exactly the form that does not travel.

## Unpushed DECISIONS are the expensive half of that, and git will not flag them

The section above is about config. The costlier case is analysis: a cloud session sees the
decisions you pushed, not the ones you made.

Measured 2026-09-22, in a web-app project. A local session produced `docs/deployment-readiness.md` —
a platform analysis that superseded the April implementation plan's choices (region, Postgres
vendor, Redis vendor) and recorded a hard constraint the plan violated. It was never pushed.
Cloud sessions then executed the plan, carefully and well: they corrected seven real errors in
it, wrote tests, documented their reasoning. All of it against superseded platform choices.

**Nothing detected this, and nothing could have.** Git merged the two lines of work cleanly,
because neither side ever edited the other's file. Both documents were internally consistent.
The conflict was *semantic* — two documents asserting different things about the same decision —
and that is invisible to every tool in the chain.

What made it recoverable rather than wasted: the code the cloud sessions wrote was
vendor-neutral, so only the plan needed rewriting. That was luck, not design.

**Before launching a cloud session:**

- `git status` and `git log origin/main..HEAD`. Anything local and uncommitted, or committed and
  unpushed, is invisible to the cloud session. Decide deliberately for each one.
- Analysis documents and memory files are the ones you will forget, because they are not code
  and nothing fails without them.

**When picking up work a cloud session did:**

- Ask what the session was working *from*, and check whether anything newer supersedes it. A plan
  file with a date in its header is the thing to compare against your most recent analysis.
- **The tell is a document's own header.** Here the plan's `**Architecture:**` line named vendors
  that a newer doc had ruled out. One read of the top of the file, held against the newer
  document, would have caught the whole thing in a minute.
- Reconcile the documents *before* merging the code, and write the superseded choices down in a
  table rather than silently overwriting them — otherwise the next person re-derives the old
  answer from an older draft.

## A cloud session cannot write `.github/workflows/`

Verified 2026-09-17. Creating or updating anything under `.github/workflows/` needs the GitHub
`workflow` token scope, and a cloud session has neither route:

```
! [remote rejected] branch -> branch (refusing to allow an OAuth App to create
  or update workflow `.github/workflows/ci.yml` without `workflow` scope)
```

The GitHub MCP server is **not** a way around it. `mcp__github__push_files` fails the same way —
`Insufficient scope: required "workflow"` — so the App carries no broader right than the git
remote here. Do not spend a round discovering this twice.

The rejection covers "create **or update**", so an existing workflow cannot be edited either; a
one-line version bump is as blocked as a new file.

**Plan for it before committing.** A commit that touches a workflow file poisons the whole push,
including the unrelated commits behind it. Either keep workflow changes out of the branch
entirely, or park them somewhere pushable (`docs/ci/`) with the `git mv` commands in a README, and
let the human install them from a local checkout.

### It compounds with the Stop hook

`stop-hook-git-check.sh` reports unpushed commits, and the work-in-progress auto-commit will
happily commit untracked files — including `.github/workflows/` left in the tree. That produces a
commit that *cannot* be pushed and a hook that asks for it to be pushed on every turn.

Breaking the loop means dropping the commit, not satisfying the hook. Verify the content is
preserved elsewhere first (`git show <sha>:<path> | sha256sum` against the parked copy), then
reset to the remote tip.

## The WIP auto-commit fires while subagents are still working

`auto-commit.sh` runs at the end of every **controller** turn. With background subagents (e.g.
subagent-driven development) that means it commits **and pushes** their half-finished edits as
`chore: auto-commit work in progress`, mid-task.

Verified 2026-10-03, nine SDD tasks: seven WIP commits landed inside task ranges. One implementer
saw them, soft-reset to squash them into its own commit, and the branch diverged from origin
(ahead 1 / behind 2) with an identical tree. It was reconciled with a no-change merge rather than
a force-push. Another found its work already committed and could only make an empty commit.

- **Every implementer dispatch must say:** never `reset` / `rebase` / `amend` / force-push; if WIP
  auto-commits appear, commit on top. (The hook's message used to say "Amend or squash freely",
  which is what invited the rewrite; it now says to squash at merge time.)
- **Build review diffs from the BASE recorded before dispatch**, never `HEAD~1`: a task's range
  includes the WIP commits.
- **When `stop-hook-git-check.sh` reports uncommitted changes while an implementer is running, do
  not commit them** — they are the implementer's in-progress edits; it commits on finishing.
- **Squash at merge is mandatory, not cosmetic, when implementers run mutation checks.** Verified
  2026-10-06 (a Godot project): a WIP auto-commit snapshotted `targeting.gd` while its cone filter was
  mutated to `if false:`, and pushed it. HEAD was correct a minute later, but a broken commit sits
  in the branch history. Tell implementers to keep a deliberate mutation in the tree only for the one
  test run it needs, and tell the human to squash.
- **Untracked scratch output is committed too.** A demo-recording run left `recordings/*.log`
  untracked, and the next controller turn would have committed it. Gitignore every directory a
  tool writes scratch output to *before* the first run, not after the hook catches it.
- **A subagent cut off by an API error leaves its partial edits behind for the next WIP commit.**
  Opus implementers died twice on HTTP 529 mid-fix, and the hook then committed the half-done fix.
  Re-dispatch a fresh implementer (a different model avoids the overload) pointed at that commit.
  Do not try to recover the dead agent's context.

## The SDD workspace is gitignored, so its ledger dies with the container

`subagent-driven-development` keeps its ledger (rulings, deferred minors, task completion lines)
under `.superpowers/sdd/`, which is git-ignored by design. In a cloud session the container is
reclaimed, so a plan paused at a checkpoint "to resume from the ledger" cannot resume from it. At
any checkpoint where work stops for the human, **commit a snapshot of the ledger** (for example
`docs/superpowers/reviews/<date>-<plan>-execution-ledger.md`). Also move any engine or tooling facts the
dispatch context file collected into the repo's `CLAUDE.md`. (A Godot project, 2026-10-06: caught
during capture-learnings, after the checkpoint message had already promised the ledger would be kept.)

## Committing `.claude/` when it is gitignored

`.claude/` + `!.claude/memory/` does **not** work. Git does not descend into a fully-ignored
directory, so the negation never matches. Use:

```gitignore
.claude/*
!.claude/memory/
```

This fails quietly: `git add` stages nothing, the commit is a clean no-op, and the files sit
untracked. **Verify with `git ls-files`, not with the commit's exit status.**

## Permission rules

Under `--dangerously-skip-permissions`, `deny` and `ask` rules are the only ones still evaluated.
They are therefore the only available control in that mode, and `ask` still prompts.

Path syntax differs from sandbox settings and from intuition:

| Pattern | Resolves to |
|---|---|
| `//path` | absolute from filesystem root |
| `~/path` | home directory |
| `/path` | relative to the settings file that declares it |
| `path`, `./path`, `**/path` | relative to the current working directory |

So `Read(**/*.pem)` means `<cwd>/**/*.pem`, not "every .pem anywhere". A single leading slash is
**not** absolute.

`Write(...)` rules are not evaluated by file permission checks at all — they emit a startup
warning. `Edit(...)` covers every file-editing tool; use it.

An `Edit(~/.claude/settings.json)` deny rule works, and locks the agent out of its own settings
permanently. That is the point, but it means future settings changes are a manual operation.

## Earlier cloud work is not only `claude/*`

Cloud sessions do not always push to `claude/*`: branches arrive as `ccr-*` and other names too, so
"look for `claude/*`" misses earlier work that never landed. `hooks/earlier-cloud-work.sh` (a
cloud-only SessionStart hook) lists every unmerged branch on origin, minus `dependabot/*`, the
session's own branch and anything already merged into the default branch.

- The authority is `git ls-remote --heads origin`, not local refs: a resumed clone holds only `main`
  and its own branch. The hook runs under a 22 s budget (8 s per network call) and prints
  "couldn't check <repo> (out of time)" rather than going silent.
- If a `switchboard-state` clone sits beside the project and its `verdicts.tsv` says `wait` for this
  repo, the hook prints that verdict: the PC has work this session cannot see.
- A repo containing `.claude/no-auto-commit` is skipped by `auto-commit.sh`, so its work in progress
  stays on the PC.
- Known limitations, not built for: the merged test is ancestry (`merge-base --is-ancestor`), so a
  squash-merged or rebased cloud PR keeps listing as unmerged. Measured 2026-10-17: all 13
  `claude/*` branches in continuable projects were merged by ancestry. And `--unshallow` on a big
  repo usually exceeds the 8 s per-call cap, so a shallow clone reports "shallow clone" rather than
  a list.

## The git proxy reaches only the session's attached repos; `add_repo` attaches more

Measured 2026-10-19 (switchboard stage 4.1 gate). A session opened on one repo cannot read a
private repo it was not started with. `git ls-remote` and `git clone` of it both fail with
`fatal: could not read Username for 'https://github.com': terminal prompts disabled` (exit 128),
while the same call against the session's own repo succeeds. Earlier "it reaches the private state
repo" results had all come from sessions that had it attached as a companion, so they measured
the wrong variable.

**The model's `add_repo` tool attaches a repo mid-session, and the user saw no approval prompt.**
After it, `ls-remote` and a `--depth 1` clone of that private repo succeed. A hook cannot call it;
only the model can, so a SessionStart hook that needs another repo prints an instruction for the
model instead (switchboard's `earlier-cloud-work.sh` does this for `ProgDroid/switchboard-state`).

**`add_repo`'s result tells the model to clone, then call `register_repo_root`**, which loads that
repo's `CLAUDE.md`, skills and plugins into the session on the next turn. When the attached repo is
data for a check, not the session's subject, say explicitly "do NOT call `register_repo_root`";
otherwise its instructions take over the session. The result also caps the attached repo at 2
concurrent smart-HTTP operations (a third gets HTTP 429) and warns that `add_repo` may already have
left a checkout at `/home/user/<repo>`. Check `git rev-parse HEAD` there before cloning over it.

Measured live 2026-10-20, in two sessions opened from a `?repositories=` link with no companions:
- **The model obeyed "do NOT call `register_repo_root`"** over `add_repo`'s own instruction, 2 of
  2.
- **`add_repo` left no checkout**, 2 of 2: the `rev-parse` check after it failed, and the model
  cloned. Keep the check anyway, since "may" is the tool's own word.

The UI labels the call "Added <owner>/<repo> to project permissions", and the failed existence
check shows as a red "Failed" step. Both are expected, not errors.
