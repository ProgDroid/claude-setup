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

lib_ok=0
. "$(dirname "$0")/lib-memory.sh" 2>/dev/null && lib_ok=1

# commit_repo <root>: sync memories, then commit and push WIP for ONE repo.
# Runs in a subshell so a cd or a failure in one repo never affects another.
commit_repo() (
  cd "$1" 2>/dev/null || exit 0
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" || exit 0

  # Never auto-commit a default branch. Cloud sessions work on their own branch;
  # a dirty main means something unexpected, and silently committing it is worse
  # than leaving it.
  case "$branch" in
    main|master|HEAD|'') exit 0 ;;
  esac

  # --- Persist memories back into the repo ---------------------------------
  # Anything the session learned lives in ~/.claude/projects/<key>/memory/,
  # which dies with the VM. Copy it into the repo BEFORE committing, so the
  # commit below carries it to GitHub and a later `git pull` puts it on the
  # developer's machine.
  #
  # Without this, memory is one-way: a cloud session can read what the project
  # knows but can never add to it, and every session relearns the same things.
  #
  # Shares its key derivation with hydrate-memory.sh and sync-memory.sh via
  # lib-memory.sh -- deriving the key differently in two places would send
  # writes to a directory nothing reads, silently.
  if [ "$lib_ok" -eq 1 ]; then
    root="$(git rev-parse --show-toplevel 2>/dev/null)"
    [ -n "${root:-}" ] && sync_memory_to_repo "$root"
  fi

  # Nothing staged, modified, or untracked -> nothing to do.
  [ -n "$(git status --porcelain 2>/dev/null)" ] || exit 0

  git add -A >/dev/null 2>&1 || exit 0

  git commit -q -F - >/dev/null 2>&1 <<'MSG' || exit 0
chore: auto-commit work in progress

Committed by the Stop hook so this session's work survives without
another model turn. Already pushed: squash at merge time, never amend,
reset or force-push on the branch.
MSG

  # Best effort. A missing remote, no upstream, or a rejected push must not
  # fail the session -- the local commit already did the important job.
  git push -q -u origin "$branch" >/dev/null 2>&1 || true
)

# --- Which repos belong to this session --------------------------------------
# Single repo (cwd /home/user/repo): just that repo.
#
# Multi-repo (verified 2026-10-03): the session starts in /home/user, which is
# NOT a repo, with each repo cloned beneath it, and the cwd later drifts into
# whichever repo is being worked on. Acting only on the cwd's repo left the
# others' work and memories uncommitted -- on a VM that is reclaimed. So:
#   - cwd is a plain directory  -> every child git repo of it;
#   - cwd is inside a repo      -> that repo plus its sibling repos, but only
#     when the parent is itself not a repo (so a nested checkout or submodule
#     never drags in unrelated directories).
repos=()
add_children() {
  for d in "$1"/*/; do
    d="${d%/}"
    [ -e "$d/.git" ] && repos+=("$d")
  done
}
top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
if [ -n "$top" ]; then
  parent="$(dirname "$top")"
  if git -C "$parent" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repos=("$top")
  else
    add_children "$parent"
    # The cwd's repo must be included even if the glob missed it (e.g. a
    # dot-directory checkout).
    case " ${repos[*]} " in *" $top "*) ;; *) repos+=("$top") ;; esac
  fi
else
  add_children "$PWD"
fi

for r in "${repos[@]}"; do
  commit_repo "$r"
done

exit 0
