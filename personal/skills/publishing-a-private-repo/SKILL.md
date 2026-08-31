---
name: publishing-a-private-repo
description: Use when making an existing private repository public - open-sourcing a personal project, publishing a portfolio piece, or flipping visibility on GitHub. Covers the secrets and personal-data sweep, whether history needs rewriting, the ordering that keeps old commits from ever being public, and verifying against the published bytes rather than local state.
---

# Publishing a private repo

Flipping a repo public is effectively irreversible. GitHub caches, forks and third-party
mirrors outlive a visibility change, so everything below happens **before** the flip.

Two failures cost the most, and neither is loud: publishing something personal that was never
meant to be read, and rewriting history *after* it was already visible.

## 1. Decide what the repo is FOR

Publishing serves one of two goals and they pull in different directions.

- **Distribution** — you want installs and users. Discovery matters, so the name, description
  and topics should match what the target community searches for.
- **Portfolio** — you want it read by employers. Framing matters more than discovery.

**These can conflict, and when they do, say so rather than pretending there is a framing that
serves both.** A repo whose discoverability comes from an association you would rather not
advertise cannot be both. Name the trade and let the owner choose.

## 2. Sweep the tree AND the full history

Working-tree-clean says nothing about commit six. Scan every reachable commit.

```bash
# Secrets, across all history
git grep -InE "(sk-[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|wk-[A-Za-z0-9]{16,})" $(git rev-list --all) --
# Internal identifiers: UUIDs, tenant/account/project ids
git grep -InE "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}" $(git rev-list --all) --
# Personal and infrastructure identifiers
git grep -InE "<owner name>|192\.168\.|10\.[0-9]+\.|/home/[a-z]+|C:\\\\Users" $(git rev-list --all) --
```

**Always pair a negative with a positive control.** An empty result and a broken query look
identical. Before believing "no secrets", run the same probe for a string you know is there
(`git grep -Inc "SOME_ENV_VAR_NAME" ...`) and confirm it returns hits.

**Never trust a result that ends in `head`.** Match lists are truncated silently and in path
order, so a capped result can stop before it reaches the directory you cared about. Capture into
a variable and test emptiness instead.

Finding an env var *name* like `MODAL_TOKEN_ID` is correct and expected. You are looking for
values.

## 3. Read the agent-written files specifically

`.claude/memory/`, `.agents/`, `.serena/`, `docs/superpowers/`, `.cursor/` and similar are
written for an agent's benefit and are rarely reviewed as publishable prose. Open every one.

They fall into two very different classes:

- **Genuinely good public content** — a hard-won library gotcha, a migration write-up, a
  measured constraint. This is often the most interesting material in the repo. If you keep it,
  **promote it out of the agent directory into `docs/`**, because a reviewer reads `docs/` and
  skips something that looks like scratch.
- **Things that must not ship** — anything profiling the owner ("X self-hosts a Y stack",
  working-style notes, personality observations), internal hostnames, or `originSessionId` and
  similar internal identifiers.

**The code is usually neutral; the metadata is what carries the risk.** A tool is a tool. A
file asserting what its author runs at home is a statement about a person.

## 4. Untrack local tool state BEFORE `git add -A`

`.agents/` and `.serena/` appear mid-session and get swept into a commit by a blanket add. One
was 208 files and 2.1 MB of vendored upstream docs.

**Both are expected byproducts, not anomalies — do not go hunting.** `.agents/` is written by
`<tool> skills install` (Modal ships one, and other vendors are adopting the same convention);
`.serena/` is created by Serena whenever a Claude Code session starts inside the repo. They are
tooling state that happens to live in the working tree, so the correct response is to ignore and
untrack them, not to investigate where they came from.

```bash
printf '\n# Local tool state\n.agents/\n.serena/\n' >> .gitignore
git rm -r --cached .agents .serena 2>/dev/null
```

Then `git ls-files` and actually read the list before committing. Prefer explicit paths over
`git add -A` at this stage.

## 5. Decide on a history rewrite by asking whether the string is ALREADY public

This is the judgement call, and the intuitive answer is often wrong in both directions.

**Scrubbing a string that is already public elsewhere is theatre.** Check the owner's other
public repos first. A hostname hardcoded as a default in a public sibling project has been
readable for as long as that project has existed, and no amount of rewriting recalls it. In
that case, fix the actual exposure (add authentication) rather than the appearance of it.

**Scrubbing a string that is genuinely nowhere public is worth doing**, because publishing is
the moment it becomes permanent.

```bash
# Is it already out? Run in each of the owner's public repos, with a positive control.
git log --oneline -S "<the string>" --all
```

When a rewrite is warranted, squashing to a single commit is simpler and more robust on Windows
than `filter-branch`, and a single "Initial public release" commit is completely normal for a
repo's first public appearance. Keep the reasoning by putting it in the commit message, code
comments and `docs/` — not only in commit history that is about to be discarded.

```bash
git tag pre-public-private-history      # local backup, do NOT push
git checkout --orphan _public -q
git add -A && git commit -F <message-file>
git branch -D main -q && git branch -m main
```

## 6. Ordering: force-push while STILL PRIVATE, then flip

This is the step whose order actually matters.

1. Force-push the rewritten history **while the repo is private**.
2. *Then* change visibility.

Done this way the old commits were never publicly visible, not even as unreachable objects
addressable by SHA. Flip first and rewrite second, and there is a window during which anyone
could read exactly what you were trying to remove — and GitHub keeps unreachable objects around.

## 7. Add what makes it usable

- **LICENSE** — GitHub will not detect a licence without the file, and its absence means
  "all rights reserved", which discourages the use you are publishing for.
- **README** that a stranger can follow: prerequisites, setup, deploy, and the gotchas you hit.
  The constraints that shaped the design are the most credible part of any README.
- **Topics** for discovery, if the goal is distribution.

```bash
gh api -X PUT repos/<owner>/<repo>/topics -f names[]=<topic> -f names[]=<topic>
```

## 8. Verify against the PUBLISHED bytes, not local state

A local `git grep` proves what you pushed. It does not prove what GitHub serves.

```bash
gh repo view <owner>/<repo> --json visibility,licenseInfo,url
# The thing you removed should 404:
curl -s -o /dev/null -w "%{http_code}\n" --compressed \
  "https://raw.githubusercontent.com/<owner>/<repo>/main/<removed-path>"
# Something you kept should 200, as a positive control that the fetch works at all:
curl -s --compressed "https://raw.githubusercontent.com/<owner>/<repo>/main/README.md" | head -5
```

## 9. Publishing is not distribution

Flipping visibility brings no users. If the goal was installs, the community post, the
issue-tracker presence and answering the first questions are what produce them, and that work is
separate. Say this out loud rather than letting a green checkmark imply the goal was met.

## Checklist

- [ ] Purpose named: distribution or portfolio, and any conflict between them surfaced
- [ ] Secrets swept across **all** history, with a positive control
- [ ] Internal identifiers (UUIDs, hosts, paths) swept the same way
- [ ] Every agent-written file read; keepers promoted to `docs/`, the rest deleted
- [ ] Local tool state gitignored and untracked; `git ls-files` read in full
- [ ] History rewrite decided by whether the string is already public elsewhere
- [ ] Backup tag created locally and NOT pushed
- [ ] Force-push completed **while private**
- [ ] LICENSE and a followable README present
- [ ] Visibility flipped, topics set
- [ ] Removal and retention verified against `raw.githubusercontent.com`
- [ ] Owner told what still needs doing to get actual users
