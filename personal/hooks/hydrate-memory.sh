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

# Derive the key through lib-memory.sh rather than inline. This used to be
# `tr '/' '-'`, which agrees with memory_key on a plain cloud path but NOT on
# one containing an underscore -- memory_key folds '_' to '-' and this did not.
# A repo like dynamic_day_planner would hydrate into one directory and sync out
# of another, silently. The manifest seeded below makes that agreement
# load-bearing, so the two must share a single derivation.
lib_ok=0
. "$(dirname "$0")/lib-memory.sh" 2>/dev/null && lib_ok=1

key_for() {
  if [ "$lib_ok" -eq 1 ]; then memory_key "$1"; else printf '%s' "$1" | tr '/' '-'; fi
}

# hydrate_root <key-root> <repo-memory-dir>
#
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
#
# Then record what was loaded as the sync baseline, while local and repo are
# still identical. sync_memory_to_repo overwrites a repo file only when it is
# byte-identical to this record -- proof the file is our own prior output. With
# no baseline, every memory this session edits looks like an independent
# divergence at Stop and is refused, which would silently disable cloud memory
# write-back entirely. Seeding is therefore required for correctness here, not
# a nicety.
hydrate_root() {
  _key="$(key_for "$1")" || return 0
  [ -n "$_key" ] || return 0
  _dst="$HOME/.claude/projects/$_key/memory"
  mkdir -p "$_dst" 2>/dev/null || return 0
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT/memory" ]; then
    cp -a "$CLAUDE_PLUGIN_ROOT/memory/." "$_dst/" 2>/dev/null || true
  fi
  if [ -d "$2" ]; then
    cp -a "$2/." "$_dst/" 2>/dev/null || true
  fi
  if [ "$lib_ok" -eq 1 ]; then
    seed_memory_manifest "$_dst" "$HOME/.claude/projects/$_key/.memory-sync-manifest" || true
  fi
}

# Which roots to hydrate.
#
# Single repo (the usual cloud layout, cwd /home/user/repo): key from git's
# toplevel -- the SAME source sync-memory.sh and auto-commit.sh use -- not from
# $PWD. On Linux the two agree, which is why this was invisible; on Windows
# they are wildly different ($PWD is /tmp/tmp.X, git returns C:/Users/.../Temp/
# tmp.X), so the hooks would key the same repo to two different directories.
#
# Multi-repo (verified 2026-10-03): a session with several repos starts in
# /home/user, which is NOT a repo, with each repo cloned beneath it. Keying from
# $PWD alone hydrated '-home-user' and nothing else, so every repo's committed
# memory was invisible all session. Hydrate each child git repo under its own
# key -- the key the Stop hooks derive when the cwd is inside that repo -- and
# still hydrate $PWD itself so the plugin layer lands in the session's own dir.
top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
repos=()
if [ -n "$top" ]; then
  hydrate_root "$top" "$PWD/.claude/memory"
else
  for d in "$PWD"/*/; do
    d="${d%/}"
    [ -e "$d/.git" ] && repos+=("$d")
  done
  hydrate_root "$PWD" "$PWD/.claude/memory"
  for r in "${repos[@]}"; do
    hydrate_root "$r" "$r/.claude/memory"
  done
fi

# --- Emit the index into the session ---------------------------------------
# Copying the files is NOT sufficient, and this was verified the hard way on
# 2026-07-24: a cloud session reported "Loaded 13 memories" and then had none of
# their content, because the memory subsystem reads its index at session start
# and a SessionStart hook runs too late to be picked up. Locally that is
# survivable -- the next session sees them. A cloud VM has no next session.
#
# A SessionStart hook's stdout IS injected into the session as context, so the
# hook must print what the session needs rather than rely on a re-read.
#
# Print the index only, never the bodies. That mirrors how the memory subsystem
# works normally -- index in context, individual files read on demand -- and
# keeps startup cost bounded regardless of how large the corpus grows.

emitted=0
header() {
  [ "$emitted" -eq 0 ] || return 0
  echo "## Project memory"
  echo
  echo "Committed memories, loaded because a cloud session starts with no"
  echo "user-scope memory. Read the full text of any entry below from the"
  echo "repo's \`.claude/memory/<name>.md\` when it is relevant to the task."
  echo
  emitted=1
}
for idx in "${CLAUDE_PLUGIN_ROOT:-/nonexistent}/memory/MEMORY.md" "$PWD/.claude/memory/MEMORY.md"; do
  [ -f "$idx" ] || continue
  header
  cat "$idx"
  echo
done
for r in "${repos[@]}"; do
  [ -f "$r/.claude/memory/MEMORY.md" ] || continue
  header
  echo "### ${r##*/} (\`$r/.claude/memory/\`)"
  echo
  cat "$r/.claude/memory/MEMORY.md"
  echo
done

exit 0
