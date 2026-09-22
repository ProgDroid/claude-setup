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

# _memory_hash <file> -> a content digest on stdout, non-zero if no hasher
# exists. Content, never metadata -- the whole point is to compare what a file
# SAYS, not when it was last touched.
_memory_hash() {
  [ -f "$1" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v cksum >/dev/null 2>&1; then
    cksum "$1" 2>/dev/null | tr -s ' ' | cut -d' ' -f1,2 | tr ' ' '-'
  else
    return 1
  fi
}

# _manifest_get <manifest-file> <name> -> the digest recorded for <name>.
# Tab-separated, so a filename containing spaces cannot split a field.
_manifest_get() {
  [ -f "$1" ] || return 1
  awk -F'\t' -v n="$2" '$2 == n { print $1; found = 1 } END { exit !found }' "$1"
}

# memory_manifest_path <repo-root> -> where the sync baseline for that repo lives.
# Kept beside the memory directory rather than inside it, so it is never mistaken
# for a memory and never syncs into the repo.
memory_manifest_path() {
  _k="$(memory_key "${1:-}")" || return 1
  [ -n "$_k" ] || return 1
  printf '%s/.claude/projects/%s/.memory-sync-manifest' "$HOME" "$_k"
}

# seed_memory_manifest <memory-dir> <manifest-path>
#
# Record the digests of everything currently in <memory-dir> as the sync
# baseline. Call this straight after populating the local memory dir FROM the
# repo, while the two are known to be identical -- that is what establishes the
# lineage sync_memory_to_repo checks for.
#
# WHY IT IS REQUIRED, not an optimisation: a cloud VM starts with no manifest.
# hydrate-memory.sh copies repo -> local, the session then edits a memory, and
# at Stop the local file differs from the repo's with no recorded lineage. The
# sync would read that as an independent divergence and refuse to write it
# back, silently disabling cloud memory write-back altogether -- the exact
# capability these hooks exist to provide. Seeding here means the repo copy is
# on record as ours, so a later session edit is correctly seen as a new draft
# of a file we own rather than a collision with a stranger's.
seed_memory_manifest() {
  _dir="${1:-}"; _mf="${2:-}"
  [ -n "$_dir" ] && [ -n "$_mf" ] || return 0
  [ -d "$_dir" ] || return 0
  _tmp="$(mktemp 2>/dev/null)" || return 0
  for _f in "$_dir"/*.md; do
    [ -f "$_f" ] || continue
    _h="$(_memory_hash "$_f" 2>/dev/null)" || continue
    [ -n "$_h" ] && printf '%s\t%s\n' "$_h" "${_f##*/}" >> "$_tmp"
  done
  if [ -s "$_tmp" ]; then
    mv -f "$_tmp" "$_mf" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
  return 0
}

# sync_memory_to_repo <repo-root>
#
# Copies the live memory directory into <repo-root>/.claude/memory/ so the
# knowledge is version-controlled and reaches other machines and cloud sessions.
#
# Opt-in per repo: does nothing unless .claude/memory/ already exists. A repo
# that has not opted in is never given an unexpected directory.
#
# Sets MEMORY_SYNC_DIVERGED to a space-separated list of filenames deliberately
# NOT overwritten; callers surface it. Empty after a clean sync.
#
# WHY LINEAGE, NOT TIMESTAMPS
#
# This used to be `cp -a -u`: "overwrite when the source is newer". The question
# that actually matters is "did WE write this destination?", and an mtime cannot
# answer it. The two coincide only while both directories hold the same set of
# files, and they come apart the moment a cloud session writes a memory this
# machine has never seen.
#
# Measured 2026-09-22 in ProgDroid/aegyptvault-notes: a cloud session created
# .claude/memory/ holding its own MEMORY.md -- a 15-line index of 2 notes. The
# local machine had a 97-line MEMORY.md indexing 100 notes under the same
# project key. Two DIFFERENT documents sharing one filename, and the local one
# was newer, so `-u` overwrote the repo's on every Stop and destroyed edits made
# to it minutes earlier. In a cloud session auto-commit.sh commits that loss.
#
# The earlier fix (2026-09-15, ProgDroid/constellation) added `-u` to stop a
# stale local copy clobbering a fresh repo edit. That was a real bug, and it is
# this same bug seen from the other side: both are "the destination is not ours
# to overwrite". A timestamp happened to express that case and cannot express
# this one, because here the aggressor is genuinely newer.
#
# So remember the digest of what we last copied out, and overwrite only when the
# destination still matches it byte for byte -- proof the destination is our own
# prior output and nothing has touched it since. Anything else has an
# independent history, and destroying that is never the safe default. A file
# absent from the destination is copied unconditionally: that is the case the
# mechanism exists for, and it can lose nothing.
sync_memory_to_repo() {
  _root="${1:-}"
  MEMORY_SYNC_DIVERGED=""
  [ -n "$_root" ] || return 0
  [ -d "$_root/.claude/memory" ] || return 0

  _key="$(memory_key "$_root")" || return 0
  _src="$HOME/.claude/projects/$_key/memory"
  _dst="$_root/.claude/memory"
  [ -d "$_src" ] || return 0
  [ -n "$(find "$_src" -maxdepth 1 -name '*.md' 2>/dev/null)" ] || return 0

  _manifest="$(memory_manifest_path "$_root")" || return 0
  _next="$(mktemp 2>/dev/null)" || return 0
  _diverged=""

  for _f in "$_src"/*.md; do
    [ -f "$_f" ] || continue
    _name="${_f##*/}"
    _d="$_dst/$_name"
    _sh="$(_memory_hash "$_f" 2>/dev/null)" || _sh=""

    # Absent from the repo: a pure addition, nothing can be lost.
    if [ ! -e "$_d" ]; then
      cp -a "$_f" "$_d" 2>/dev/null
      [ -n "$_sh" ] && printf '%s\t%s\n' "$_sh" "$_name" >> "$_next"
      continue
    fi

    _dh="$(_memory_hash "$_d" 2>/dev/null)" || _dh=""

    # Already identical: record the state and touch nothing.
    if [ -n "$_sh" ] && [ "$_sh" = "$_dh" ]; then
      printf '%s\t%s\n' "$_sh" "$_name" >> "$_next"
      continue
    fi

    # Contents differ. Overwrite only when the destination is exactly what this
    # sync last put there; otherwise it changed independently, and the local
    # file is a different document rather than a newer draft of the same one.
    _known="$(_manifest_get "$_manifest" "$_name" 2>/dev/null)" || _known=""
    if [ -n "$_dh" ] && [ -n "$_known" ] && [ "$_dh" = "$_known" ]; then
      cp -a "$_f" "$_d" 2>/dev/null
      [ -n "$_sh" ] && printf '%s\t%s\n' "$_sh" "$_name" >> "$_next"
    else
      _diverged="$_diverged $_name"
      # Record the destination we left in place, so that once a human resolves
      # the divergence by hand, the next run sees lineage again.
      [ -n "$_dh" ] && printf '%s\t%s\n' "$_dh" "$_name" >> "$_next"
    fi
  done

  # Anything that is not a top-level .md (a subdirectory, a stray asset) keeps
  # the old behaviour. Memory dirs are flat in practice, so this is a
  # compatibility path, not a supported shape.
  for _e in "$_src"/*; do
    [ -e "$_e" ] || continue
    case "$_e" in *.md) continue ;; esac
    cp -a -u "$_e" "$_dst/" 2>/dev/null
  done

  if [ -s "$_next" ]; then
    mv -f "$_next" "$_manifest" 2>/dev/null || rm -f "$_next" 2>/dev/null
  else
    rm -f "$_next" 2>/dev/null
  fi

  MEMORY_SYNC_DIVERGED="${_diverged# }"
  return 0
}
