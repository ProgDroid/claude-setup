#!/usr/bin/env bash
# Stop hook (local sessions): copy this project's memories into the repo so the
# committed copy does not go stale.
#
# WHY: memories written on this machine land in ~/.claude/projects/<key>/memory/.
# The repo carries a copy so cloud sessions can read it. Without this hook only
# cloud sessions ever write back, so local work silently drifts ahead of the
# committed copy -- and a later cloud session hydrates from the stale version.
#
# Syncing at the file level rather than teaching capture-learnings to write to
# the repo is deliberate: the memory subsystem writes to that directory on its
# own, so a skill-level fix would miss every memory the skill did not create.
#
# Does NOT commit. Local commits are the developer's to make; this only leaves
# the files staged-and-modified so they ride along with the next normal commit.
# Cloud sessions take the other path -- auto-commit.sh syncs and commits, and
# that script is gated the opposite way, so exactly one of the two runs.
#
# Opt-in per repo: does nothing unless <repo>/.claude/memory/ already exists.
#
# NEVER fails the session: always exits 0.

set -uo pipefail

# Cloud sessions are handled by auto-commit.sh, which needs the copy to happen
# before it commits. Splitting by gate avoids depending on hook ordering.
[ "${CLAUDE_CLOUD_SESSION:-}" = "1" ] && exit 0

. "$(dirname "$0")/lib-memory.sh" 2>/dev/null || exit 0

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] || exit 0

sync_memory_to_repo "$root"

exit 0
