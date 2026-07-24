#!/usr/bin/env bash
# Stop hook: commit and push work in progress so an exhausted cloud session
# never strands it.
#
# WHY: running a command inside a cloud session is a model turn. When the
# usage allowance runs out mid-session, there is no way to ask the session to
# commit -- the work sits on a VM that is reclaimed after a period of
# inactivity. Committing automatically at every Stop makes exhaustion
# survivable, and puts the branch on GitHub where any other agent can pick it
# up from the plan file.
#
# GATE: fires only when CLAUDE_CLOUD_SESSION=1, set in the cloud environment's
# variables. Detection of "am I in a cloud session?" is deliberately NOT
# inferred: an explicit gate fails closed, so the worst case is the hook not
# running rather than it committing local work you did not want committed.
#
# NEVER fails the session: always exits 0.

set -uo pipefail

[ "${CLAUDE_CLOUD_SESSION:-}" = "1" ] || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || exit 0

# Never auto-commit a default branch. Cloud sessions work on their own branch;
# a dirty main means something unexpected, and silently committing it is worse
# than leaving it.
case "$branch" in
  main|master|HEAD|'') exit 0 ;;
esac

# --- Persist memories back into the repo -----------------------------------
# Anything the session learned lives in ~/.claude/projects/<key>/memory/, which
# dies with the VM. Copy it into the repo BEFORE committing, so the commit below
# carries it to GitHub and a later `git pull` puts it on the developer's machine.
#
# Without this, memory is one-way: a cloud session can read what the project
# knows but can never add to it, and every session relearns the same things.
key="$(printf '%s' "$PWD" | tr '/' '-')"
memsrc="$HOME/.claude/projects/$key/memory"
if [ -d "$memsrc" ] && [ -n "$(find "$memsrc" -maxdepth 1 -name '*.md' 2>/dev/null)" ]; then
  mkdir -p "$PWD/.claude/memory" 2>/dev/null \
    && cp -a "$memsrc/." "$PWD/.claude/memory/" 2>/dev/null || true
fi

# Nothing staged, modified, or untracked -> nothing to do.
[ -n "$(git status --porcelain 2>/dev/null)" ] || exit 0

git add -A >/dev/null 2>&1 || exit 0

git commit -q -F - >/dev/null 2>&1 <<'MSG' || exit 0
chore: auto-commit work in progress

Committed by the Stop hook so this session's work survives without
another model turn. Amend or squash freely.
MSG

# Best effort. A missing remote, no upstream, or a rejected push must not
# fail the session -- the local commit already did the important job.
git push -q -u origin "$branch" >/dev/null 2>&1 || true

exit 0
