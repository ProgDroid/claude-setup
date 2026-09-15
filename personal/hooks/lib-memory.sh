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

  # Normalise a Windows-form path to the MSYS form FIRST.
  #
  # Both production callers (sync-memory.sh, auto-commit.sh) derive the root
  # from `git rev-parse --show-toplevel`, and on Git Bash that returns
  # G:/pythonDev/news-brief -- a Windows path with a drive colon, NOT the MSYS
  # /g/pythonDev/news-brief the matcher below was written for. So every real
  # call fell through to the generic branch and produced a key containing a
  # colon ('G:-pythonDev-news-brief'). No such directory can exist, both hooks
  # hit their `[ -d "$_src" ] || return 0` guard, and the whole mechanism
  # no-opped in complete silence for days. Found 2026-09-05.
  #
  # Backslashes are folded too, since some Windows tools emit G:\a\b.
  _p="$(printf '%s' "$_p" | sed -e 's|\\|/|g' -e 's|^\([a-zA-Z]\):/|/\1/|')"

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

  # -u: copy a file only when the source is NEWER than the destination.
  #
  # WHY: without it this is an unconditional overwrite that treats the local
  # memory dir as the sole authority, so anything written straight into a
  # repo's .claude/memory/ is destroyed at the next Stop -- and in a cloud
  # session auto-commit.sh then commits and pushes the rollback. Observed
  # 2026-09-15 in ProgDroid/constellation: a session restored
  # constellation-status.md in the repo, the local copy was 25 stale lines from
  # early in the session, and three consecutive Stops (29373ab, f90dca7,
  # 2be8145) each reverted the restore the session had just pushed. Silent;
  # only a whole-branch review caught it before it reached main.
  #
  # -a already preserves source mtimes, so the three cases fall out cleanly:
  # a file synced earlier compares equal and is not re-copied; a memory this
  # session actually wrote has a fresh mtime and still syncs out; and a repo
  # file edited or checked out this session is newer than a stale local copy
  # and survives.
  cp -a -u "$_src/." "$_root/.claude/memory/" 2>/dev/null || return 0
  return 0
}
