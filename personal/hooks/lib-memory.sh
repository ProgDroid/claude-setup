#!/usr/bin/env bash
# Shared memory-sync helpers. Sourced by hydrate-memory.sh, sync-memory.sh and
# auto-commit.sh so the project-key derivation exists in exactly one place.
#
# Not executable on its own.

# memory_key <abs-path> -> the directory name under ~/.claude/projects/
#
# Two formats, because the same repo has a different path on each platform:
#
#   Linux / cloud VM   /home/user/repo        -> -home-user-repo
#                      (verified 2026-07-24 against a live cloud session)
#
#   Windows via MSYS   /g/rustDev/aba         -> G--rustDev-aba
#                      (drive letter uppercased, then separators -> '-')
#
# UNDERSCORES ARE NORMALISED TO '-'. Verified 2026-07-25: the repo at
# /g/flutterDev/dynamic_day_planner has its memories under
# G--flutterDev-dynamic-day-planner, and no project directory anywhere on this
# machine contains an underscore. Missing this cost nothing only because it was
# caught before shipping -- the hook would have written to a directory nothing
# reads, with no error and no output.
#
# Getting this wrong is silent, which is why it has direct test coverage.
memory_key() {
  _p="${1:-}"
  [ -n "$_p" ] || return 1

  # Single-letter first segment means an MSYS drive mount.
  _drive="$(printf '%s' "$_p" | sed -n 's:^/\([a-zA-Z]\)/.*:\1:p' | tr 'a-z' 'A-Z')"
  if [ -n "$_drive" ]; then
    _rel="$(printf '%s' "$_p" | sed -n 's:^/[a-zA-Z]/::p')"
    [ -n "$_rel" ] || return 1
    printf '%s--%s' "$_drive" "$(printf '%s' "$_rel" | tr '/ _' '---')"
    return 0
  fi

  printf '%s' "$_p" | tr '/_' '--'
}

# sync_memory_to_repo <repo-root>
#
# Copies the live memory directory into <repo-root>/.claude/memory/ so the
# knowledge is version-controlled and reaches other machines and cloud sessions.
#
# Opt-in per repo: does nothing unless .claude/memory/ already exists. A repo
# that has not opted in is never given an unexpected directory.
sync_memory_to_repo() {
  _root="${1:-}"
  [ -n "$_root" ] || return 0
  [ -d "$_root/.claude/memory" ] || return 0

  _key="$(memory_key "$_root")" || return 0
  _src="$HOME/.claude/projects/$_key/memory"
  [ -d "$_src" ] || return 0
  [ -n "$(find "$_src" -maxdepth 1 -name '*.md' 2>/dev/null)" ] || return 0

  cp -a "$_src/." "$_root/.claude/memory/" 2>/dev/null || return 0
  return 0
}
