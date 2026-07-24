#!/usr/bin/env bash
# SessionStart hook: load the repo's committed memories into the path the
# memory subsystem actually reads from.
#
# WHY: a cloud session starts from a fresh VM with only the repository cloned.
# User-scope config does not travel, so ~/.claude/projects/<key>/memory/ starts
# empty and the session begins knowing nothing the project has learned. That is
# the single biggest quality gap between a cloud session and a local one.
#
# The memory subsystem reads from a fixed path. That constrains READERS, not
# writers -- a hook running before the session can populate it. So memories are
# stored in the repo, where a clone is guaranteed to deliver them, and copied
# into place here.
#
# PROJECT KEY: verified 2026-07-24 against a live cloud session. cwd is
# /home/user/repo and the key is -home-user-repo, i.e. the path with '/'
# replaced by '-'. Derived rather than hardcoded, so it survives a path change.
#
# GATE: cloud sessions only. Locally, memories already live in
# ~/.claude/projects/ (symlinked into the dotfiles repo), and copying the repo
# copy over them could overwrite newer local work.
#
# NEVER fails the session: always exits 0.

set -uo pipefail

[ "${CLAUDE_CLOUD_SESSION:-}" = "1" ] || exit 0

key="$(printf '%s' "$PWD" | tr '/' '-')"
[ -n "$key" ] || exit 0

dst="$HOME/.claude/projects/$key/memory"
mkdir -p "$dst" 2>/dev/null || exit 0

# Two layers, applied in this order so the more specific one wins:
#
#   1. Plugin memories  -- cross-project knowledge that is true everywhere
#      (harness gotchas, language-specific traps). Ships with the plugin, so it
#      reaches every cloud session regardless of which repo is open.
#
#   2. Repo memories    -- facts about THIS codebase. Copied second, so a repo
#      memory overrides a cross-project one of the same name.
#
# WARNING: the plugin repo is public. Anything placed in its memory/ directory
# is world-readable. Cross-project memories that are personal, employer-related,
# or otherwise private belong in local user-scope memory, not here.

if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/memory" ]; then
  cp -a "$CLAUDE_PLUGIN_ROOT/memory/." "$dst/" 2>/dev/null || true
fi

src="$PWD/.claude/memory"
if [ -d "$src" ]; then
  cp -a "$src/." "$dst/" 2>/dev/null || true
fi

count="$(find "$dst" -maxdepth 1 -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
[ "${count:-0}" -gt 0 ] 2>/dev/null && echo "Loaded $count memories (plugin + repository)."

exit 0
