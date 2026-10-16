#!/usr/bin/env bash
# Step: secret-scan (a gitleaks pre-commit block, and a proof that the hook really runs it).
# Source this file; do not execute it. Needs common.sh, workspace.sh (preflight) and beads.sh
# (_beads_norm) sourced first.
#
# Pinned against gitleaks 8.30.1 (`gitleaks git --help`); exit 1 = leaks found:
#   gitleaks git --pre-commit --staged --redact --no-banner
# It also exits 1 when it cannot load its config, so the proof requires gitleaks' own
# "leaks found:" line as well as a non-zero exit.

_SS_BEGIN='# >>> ritual secret-scan'
_SS_END='# <<< ritual secret-scan'

# The one gitleaks resolver: the hook block contains these lines verbatim and check evaluates the
# same text, so the two can never disagree. PATH first, then the directory winget links it into,
# which a session started before the install does not have on PATH. That path is executed
# directly and never put on PATH: it is a C:\... path, and its colon would split the PATH entry.
_SS_RESOLVER=(
  '_ritual_gl="$(command -v gitleaks 2>/dev/null)"'
  'if [ -z "$_ritual_gl" ] && [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/Microsoft/WinGet/Links/gitleaks.exe" ]; then'
  '  _ritual_gl="$LOCALAPPDATA/Microsoft/WinGet/Links/gitleaks.exe"'
  'fi'
)

# The block (POSIX sh). It runs first in the hook, so a leak stops the commit before anything
# else in the hook runs. Without gitleaks it warns loudly and lets the commit through.
_SS_BLOCK=(
  "$_SS_BEGIN"
  '# Managed by the project-start ritual: scan the staged changes for secrets before anything else.'
  "${_SS_RESOLVER[@]}"
  'if [ -n "$_ritual_gl" ]; then'
  '  "$_ritual_gl" git --pre-commit --staged --redact --no-banner'
  '  _ritual_rc=$?'
  '  if [ "$_ritual_rc" -ne 0 ]; then'
  '    echo >&2 "ritual secret-scan: gitleaks reported leaks (or failed) in the staged changes, exit $_ritual_rc; commit blocked"'
  '    exit "$_ritual_rc"'
  '  fi'
  'else'
  '  echo >&2 "ritual secret-scan: WARNING: gitleaks not found; staged changes were NOT scanned for secrets"'
  'fi'
  'unset _ritual_gl _ritual_rc'
  "$_SS_END"
)

# _ss_gitleaks -> the resolved gitleaks path (empty when there is none).
_ss_gitleaks() {
  local _ritual_gl=""
  eval "$(printf '%s\n' "${_SS_RESOLVER[@]}")"
  printf '%s' "$_ritual_gl"
}

# _ss_hook <top> -> path of the pre-commit hook git runs (honours core.hooksPath, relative or absolute).
_ss_hook() {
  local top="$1" hp
  hp="$(git -C "$top" rev-parse --git-path hooks)" || die "cannot resolve the hooks directory: $top"
  case "$hp" in /*|[A-Za-z]:*|\\*) ;; *) hp="$top/$hp" ;; esac
  printf '%s/pre-commit' "${hp%[/\\]}"
}

# _ss_rel <top> <path> -> <path> relative to the work tree, or empty when it lies outside the work
# tree or inside .git (then it is not something a commit can carry).
_ss_rel() {
  local t p r
  t="$(_beads_norm "$1")"; p="$(_beads_norm "$2")"
  case "$p" in "$t"/*) r="${p#"$t"/}" ;; *) return 0 ;; esac
  case "$r" in .git/*) return 0 ;; esac
  printf '%s' "$r"
}

# _ss_count <file> <line> -> how many lines of <file> are exactly <line> (CRs ignored).
_ss_count() { [ -f "$1" ] || { echo 0; return; }; tr -d '\r' < "$1" | grep -cxF -- "$2"; }

_ss_has_block() { [ "$(_ss_count "$1" "$_SS_BEGIN")" -ge 1 ] && [ "$(_ss_count "$1" "$_SS_END")" -ge 1 ]; }

# _ss_interp <shebang line> -> the interpreter's name: `#!/bin/sh` -> sh, `#!/usr/bin/env -S bash -e` -> bash.
_ss_interp() {
  local -a w; local x i
  read -r -a w <<<"${1#\#!}"
  x="${w[0]:-}"
  if [ "${x##*/}" = env ]; then
    x=""
    for i in "${w[@]:1}"; do case "$i" in -*|*=*) ;; *) x="$i"; break ;; esac; done
  fi
  printf '%s' "${x##*/}"
}

# check secret-scan <repo>: present = PROVED: with a fake AWS-style key staged in the real repo,
# `git hook run pre-commit` exits non-zero and gitleaks reports the leak. absent = no ritual block
# in the hook git runs, or the proof ran and the hook let the key through. unknown = no gitleaks,
# or a git without `git hook run`. failed = the proof could not restore the working tree/index.
check_secret_scan() {
  local repo="$1" top hook gl def h found=()
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  hook="$(_ss_hook "$top")"
  def="$(git_common_dir "$top")/hooks/pre-commit"
  # the block in a hook git does NOT run is still found, so that case goes through the proof too
  for h in "$hook" "$def"; do _ss_has_block "$h" && found+=("$h"); done
  gl="$(_ss_gitleaks)"
  if [ -z "$gl" ]; then
    emit secret-scan unknown "gitleaks not found (PATH, or LOCALAPPDATA/Microsoft/WinGet/Links); install it to prove the scan; ritual block in the hook git runs: $(_ss_has_block "$hook" && echo yes || echo no)"
    return 0
  fi
  if [ "${#found[@]}" -eq 0 ]; then
    emit secret-scan absent "no ritual secret-scan block in $hook"; return 0
  fi
  if ! git -C "$top" hook run --ignore-missing ritual-nonexistent-hook </dev/null >/dev/null 2>&1; then
    emit secret-scan unknown "this git has no 'git hook run' (needs 2.36+); the hook cannot be proved"; return 0
  fi
  ( _ss_proof "$top" "$hook" )
}

# _ss_proof <top> <hook>: run in a subshell (it sets its own EXIT trap; preflight sets one too and
# is only ever called inside $(...)). Prints one step result.
_ss_proof() {
  _SS_TOP="$1"; local hook="$2" before after out rc k diffs p last
  before="$(preflight "$_SS_TOP")" || { emit secret-scan unknown "preflight failed before the proof"; return 0; }
  _SS_F="$(mktemp "$_SS_TOP/.ritual-secret-scan-proof.XXXXXX")" || { emit secret-scan unknown "cannot create the proof file in $_SS_TOP"; return 0; }
  trap '_ss_cleanup' EXIT
  trap 'exit 130' INT TERM HUP
  k="AKIA""Q7RZ3MXL2KTD5VNW"   # never one literal: see the test no_contiguous_key_in_source
  printf 'aws_access_key_id = %s\n' "$k" > "$_SS_F"
  if ! git -C "$_SS_TOP" add -f -- "${_SS_F##*/}" >/dev/null 2>&1; then
    _ss_cleanup; emit secret-scan unknown "could not stage the proof file"; return 0
  fi
  out="$(cd "$_SS_TOP" && git hook run pre-commit </dev/null 2>&1)"; rc=$?
  _ss_cleanup; trap - EXIT

  # undo what a hook that ran past the scan may have done: unstage paths that were not staged
  # before. The snapshots reach jq as files: jq.exe prints nothing past a ~32 KB command line.
  _SS_D="$(mktemp -d)" || { emit secret-scan failed "mktemp failed after the proof; check git status"; return 0; }
  trap 'rm -rf "$_SS_D"' EXIT
  printf '%s' "$before" > "$_SS_D/before"
  after="$(preflight "$_SS_TOP")" || { emit secret-scan failed "preflight failed after the proof; check git status"; return 0; }
  printf '%s' "$after" > "$_SS_D/after"
  diffs="$(_ss_changed "$_SS_D/before" "$_SS_D/after")"
  if [ -n "$diffs" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] && git -C "$_SS_TOP" reset -q -- "$p" >/dev/null 2>&1
    done < <(_ss_changed "$_SS_D/before" "$_SS_D/after" unstaged-before)
    after="$(preflight "$_SS_TOP")" || { emit secret-scan failed "preflight failed after the proof; check git status"; return 0; }
    printf '%s' "$after" > "$_SS_D/after"
    diffs="$(_ss_changed "$_SS_D/before" "$_SS_D/after")"
    if [ -n "$diffs" ]; then
      local -a ps; mapfile -t ps <<<"$diffs"
      emit secret-scan failed "the pre-commit hook changed the work tree or index during the proof (exit $rc) and it could not be undone: $(_beads_join "${ps[@]}")"
      return 0
    fi
  fi

  last="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 2 | tr '\n' ' ')"
  if [ "$rc" -ne 0 ] && grep -qi gitleaks <<<"$out" && grep -q 'leaks found:' <<<"$out"; then
    emit secret-scan present "proved: git hook run pre-commit blocked a staged fake key (exit $rc) via $hook"
  elif _ss_has_block "$hook"; then
    emit secret-scan absent "the block is in $hook, but git hook run pre-commit let a staged fake key through (exit $rc): ${last% }"
  else
    emit secret-scan absent "the ritual block is not in the hook git runs ($hook), so it is bypassed; git hook run pre-commit let a staged fake key through (exit $rc)"
  fi
}

_ss_cleanup() {
  [ -n "${_SS_F:-}" ] || return 0
  git -C "$_SS_TOP" rm -q --cached --ignore-unmatch -- "${_SS_F##*/}" >/dev/null 2>&1
  rm -f "$_SS_F"; _SS_F=""
}

# _ss_changed <before-file> <after-file> [unstaged-before] -> paths (one per line) whose dirty
# status, bytes or index entry differ between two preflight snapshots. With unstaged-before, only
# those that had nothing staged before (clean, worktree-only change, or untracked): for them the
# index before equals HEAD, so `git reset -- <path>` restores it exactly.
_ss_changed() {
  jq -rn --slurpfile b "$1" --slurpfile a "$2" --arg only "${3:-}" '
    $b[0] as $b | $a[0] as $a
    | def xy($x; $p): $x.dirty | map(select(.path == $p)) | .[0].xy;
      def st($x; $p): [xy($x; $p), $x.bytes[$p], $x.index[$p]];
    ([$b.dirty[].path] + [$a.dirty[].path] | unique)[] | select(st($b; .) != st($a; .))
    | select($only == "" or ((xy($b; .) // "  ") | .[0:1] | IN(" ", "?")))' | tr -d '\r'
}

# fix secret-scan <repo>: put the block directly after the shebang of the pre-commit hook git
# runs (before bd's block and any user content), creating the hook when it does not exist.
# Idempotent by marker. Keeps the file's line endings and every existing byte.
fix_secret_scan() {
  local repo="$1" top hook rel first interp eol=$'\n' tmp nb ne l lastc
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  hook="$(_ss_hook "$top")"
  rel="$(_ss_rel "$top" "$hook")"
  local -a wrote=(); [ -n "$rel" ] && wrote=("$rel")
  nb="$(_ss_count "$hook" "$_SS_BEGIN")"; ne="$(_ss_count "$hook" "$_SS_END")"
  if [ "$nb" -gt 0 ] || [ "$ne" -gt 0 ]; then
    if [ "$nb" = 1 ] && [ "$ne" = 1 ]; then emit secret-scan already "ritual block already in $hook"
    else emit secret-scan failed "$hook has $nb begin and $ne end ritual secret-scan markers; fix it by hand"; fi
    return 0
  fi
  if [ ! -s "$hook" ]; then
    mkdir -p "$(dirname "$hook")" || { emit secret-scan failed "cannot create $(dirname "$hook")"; return 0; }
    { printf '%s\n' '#!/usr/bin/env sh'; printf '%s\n' "${_SS_BLOCK[@]}"; } > "$hook" \
      || { emit secret-scan failed "cannot write $hook"; return 0; }
    chmod +x "$hook"
    emit secret-scan fixed "created $hook with the gitleaks block" ${wrote[@]+"${wrote[@]}"}
    return 0
  fi
  first="$(head -n 1 "$hook" | tr -d '\r')"
  if [[ "$first" == '#!'* ]]; then
    interp="$(_ss_interp "$first")"
    case "$interp" in
      sh|bash|dash|zsh) ;;
      *) emit secret-scan failed "$hook is a ${interp:-unrecognised} script ($first), not a shell script; add the gitleaks scan by hand"; return 0 ;;
    esac
  fi
  [ "$(eol_of "$hook")" = crlf ] && eol=$'\r\n'
  tmp="$(mktemp)" || { emit secret-scan failed "mktemp failed"; return 0; }
  {
    if [[ "$first" == '#!'* ]]; then
      head -n 1 "$hook"
      lastc="$(head -n 1 "$hook" | tail -c 1 | od -An -tx1 | tr -d ' \n')"
      [ "$lastc" = 0a ] || printf '%s' "$eol"
    fi
    for l in "${_SS_BLOCK[@]}"; do printf '%s%s' "$l" "$eol"; done
    if [[ "$first" == '#!'* ]]; then tail -n +2 "$hook"; else cat "$hook"; fi
  } > "$tmp" && cat "$tmp" > "$hook" || { rm -f "$tmp"; emit secret-scan failed "cannot write $hook"; return 0; }
  rm -f "$tmp"; chmod +x "$hook"
  emit secret-scan fixed "inserted the gitleaks block after the shebang of $hook" ${wrote[@]+"${wrote[@]}"}
}
