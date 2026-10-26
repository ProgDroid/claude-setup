#!/usr/bin/env bash
# Step: secret-scan (a gitleaks pre-commit block, and a proof that the hook really runs it).
# Source this file; do not execute it. Needs common.sh and workspace.sh (preflight) sourced first.
#
# Pinned against gitleaks 8.30.1 (`gitleaks git --help`); exit 1 = leaks found:
#   gitleaks git --pre-commit --staged --redact --no-banner --no-color --verbose
# --verbose names the file, line and rule of each finding; --redact keeps the secret masked;
# --no-color keeps ANSI codes out of the findings the commit step quotes. It also
# exits 1 when it cannot load its config, so the proof requires gitleaks' own "leaks found:" line
# as well as a non-zero exit, and the hook tells the two apart by that line.

_SS_BEGIN='# >>> ritual secret-scan'
_SS_END='# <<< ritual secret-scan'
_SS_PROOF_PREFIX='.ritual-secret-scan-proof.'
# _ss_atomic_write's temp file: this prefix and mktemp's six letters or digits (XXXXXX), beside the
# hook. _ss_sweep removes one a kill left behind, by exactly that shape (_SS_HOOK_TMP_GLOB).
_SS_HOOK_TMP_PREFIX='.ritual-pre-commit.'
_SS_HOOK_TMP_GLOB='[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]'

# The one gitleaks resolver: the hook block contains these lines verbatim and check evaluates the
# same text, so the two can never disagree. PATH first, then the directory winget links it into,
# which a session started before the install does not have on PATH. That path is executed
# directly and never put on PATH: it is a C:\... path, and its colon would split the PATH entry.
# `|| true`: the block runs under the hook's shebang flags, and under `sh -e` a failing
# `command -v` would end the hook before it could warn.
_SS_RESOLVER=(
  '_ritual_gl="$(command -v gitleaks 2>/dev/null || true)"'
  'if [ -z "$_ritual_gl" ] && [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/Microsoft/WinGet/Links/gitleaks.exe" ]; then'
  '  _ritual_gl="$LOCALAPPDATA/Microsoft/WinGet/Links/gitleaks.exe"'
  'fi'
)

# The block's version, on its own line right after the begin marker. 0.15's block (v1) had no
# version line. v2 adds the line and the gitleaks timeout. A stale block (a lower version) is the
# one piece of installed house text the ritual upgrades in place: fix_secret_scan rewrites it.
_SS_VERSION=2
_SS_VLINE='# ritual secret-scan block v'
# The bound on gitleaks' run time, in seconds. RITUAL_TEST_GITLEAKS_TIMEOUT (tests only) is read
# HERE, when the block text is built, and substituted into it: an installed hook holds the literal
# number and never reads the knob. Anything but a positive integer gives the default.
_SS_TIMEOUT="${RITUAL_TEST_GITLEAKS_TIMEOUT:-60}"
case "$_SS_TIMEOUT" in ''|*[!0-9]*|0*) _SS_TIMEOUT=60 ;; esac
_SS_GL_CMD='"$_ritual_gl" git --pre-commit --staged --redact --no-banner --no-color --verbose'

# The block (POSIX sh, safe under `sh -e`). It runs first in the hook, so a leak stops the commit
# before anything else in the hook runs. Without gitleaks it warns loudly and lets the commit
# through. gitleaks runs under GNU timeout when that is what `timeout` is (Windows' own
# timeout.exe can come first on PATH and is a different program: then gitleaks runs plain), and
# exit 124 blocks as a timeout. That test comes BEFORE the output is read: a gitleaks cut short
# has still printed a partial "no leaks found" (measured, real gitleaks 8.30.1 under GNU timeout
# 8.32), and could have printed a "leaks found:" line. Any other non-zero gitleaks exit blocks;
# its message says whether secrets were found or gitleaks itself failed (then nothing was scanned).
_SS_BLOCK=(
  "$_SS_BEGIN"
  "$_SS_VLINE$_SS_VERSION"
  '# Managed by the project-start ritual: scan the staged changes for secrets before anything else.'
  "${_SS_RESOLVER[@]}"
  'if [ -n "$_ritual_gl" ]; then'
  '  _ritual_rc=0'
  "  if timeout --version 2>/dev/null | grep -q 'GNU coreutils'; then"
  "    _ritual_out=\"\$(timeout $_SS_TIMEOUT $_SS_GL_CMD 2>&1)\" || _ritual_rc=\$?"
  '  else'
  "    _ritual_out=\"\$($_SS_GL_CMD 2>&1)\" || _ritual_rc=\$?"
  '  fi'
  '  [ -z "$_ritual_out" ] || printf "%s\n" "$_ritual_out" >&2'
  '  if [ "$_ritual_rc" -eq 124 ]; then'
  "    echo >&2 \"ritual secret-scan: gitleaks timed out after $_SS_TIMEOUT s; nothing was scanned; commit blocked\""
  '    exit 124'
  '  fi'
  '  if [ "$_ritual_rc" -ne 0 ]; then'
  '    case "$_ritual_out" in'
  '      *"leaks found:"*) echo >&2 "ritual secret-scan: gitleaks found secrets in the staged changes (exit $_ritual_rc); commit blocked" ;;'
  '      *) echo >&2 "ritual secret-scan: gitleaks failed to run (check its config), exit $_ritual_rc; commit blocked; nothing was scanned" ;;'
  '    esac'
  '    exit "$_ritual_rc"'
  '  fi'
  'else'
  '  echo >&2 "ritual secret-scan: WARNING: gitleaks not found; staged changes were NOT scanned for secrets"'
  'fi'
  'unset _ritual_gl _ritual_rc _ritual_out'
  "$_SS_END"
)

# _ss_block_version <hook> -> the version of the ritual block in <hook>: the number on the first
# version line between the begin and end markers, 1 when there is none there (CRs ignored).
_ss_block_version() {
  local v
  v="$(tr -d '\r' < "$1" 2>/dev/null | awk -v b="$_SS_BEGIN" -v e="$_SS_END" -v p="$_SS_VLINE" '
    $0 == b { f = 1; next }
    $0 == e { if (f) exit; next }
    f && index($0, p) == 1 && substr($0, length(p) + 1) ~ /^[0-9]+$/ { print substr($0, length(p) + 1); exit }')"
  printf '%s' "${v:-1}"
}

# The v1 block texts the ritual shipped (Ruling R13): SHA-256 (`sha256sum`) of the text from the
# begin marker to the end marker, both included, CRs stripped and every line ended by LF, i.e.
# `printf '%s\n' "${_SS_BLOCK[@]}"` as built at that release. Measured by sourcing each release
# commit's lib/secretscan.sh, never retyped. sha256sum, not `git hash-object`: git hashes with the
# object format of whatever repository the cwd is in (64-hex ids in a SHA-256 repo, so a shipped
# block would never match), and a fixed algorithm needs no repository at all. Only these are
# upgraded in place; any other block without a version line is the user's edit and is left alone.
# The pre-release text at 006ce23 never shipped and is not listed.
_SS_V1_SHIPPED=(
  be06502539e6c8491f3dda473b7c735183393c9a91431f8ae0c1e98475cdabb1   # 0.14.0 (921eaf1)
  6570ed0492deb046d0257d39709c7c613975721105cb73aa25d91aea1122a0af   # 0.14.1 .. 0.15.3 (db9fef9 .. 02b1cf7); adds --no-color
)

# _ss_block_blob <hook> -> the SHA-256 of its marker-to-marker text, normalised as above.
_ss_block_blob() {
  tr -d '\r' < "$1" 2>/dev/null | awk -v b="$_SS_BEGIN" -v e="$_SS_END" '
    $0 == b { f = 1 }
    f { print }
    f && $0 == e { exit }' | sha256sum 2>/dev/null | cut -d' ' -f1
}

_SS_EDITED_NOTE='edited ritual block, no version line; fix will not upgrade it'

# _ss_block_state <hook> -> current (version line >= _SS_VERSION), stale (no version line, and
# the text is one the ritual shipped: due an upgrade), or edited (no version line, any other text:
# never rewritten).
_ss_block_state() {
  local v b s
  v="$(_ss_block_version "$1")"
  if [ "$v" -ge "$_SS_VERSION" ]; then echo current; return 0; fi
  b="$(_ss_block_blob "$1")"
  for s in "${_SS_V1_SHIPPED[@]}"; do [ -n "$b" ] && [ "$b" = "$s" ] && { echo stale; return 0; }; done
  echo edited
}

# _ss_line_of <file> <line> -> the number of the first line of <file> that is exactly <line> (CRs
# ignored); empty when there is none.
_ss_line_of() { tr -d '\r' < "$1" | grep -nxF -- "$2" | head -n 1 | cut -d: -f1; }

# The hook's new contents, printed to stdout by one of these, are written by _ss_atomic_write.
# _ss_content_new: a new hook (shebang and block).
_ss_content_new() { printf '%s\n' '#!/usr/bin/env sh'; printf '%s\n' "${_SS_BLOCK[@]}"; }

# _ss_content_insert <hook> <first line, CR-stripped> <eol>: the block right after the shebang (at
# the very top when there is none); every byte of the hook kept around it.
_ss_content_insert() {
  local hook="$1" first="$2" eol="$3" l lastc
  if [[ "$first" == '#!'* ]]; then
    head -n 1 "$hook"
    lastc="$(head -n 1 "$hook" | tail -c 1 | od -An -tx1 | tr -d ' \n')"
    [ "$lastc" = 0a ] || printf '%s' "$eol"
  fi
  for l in "${_SS_BLOCK[@]}"; do printf '%s%s' "$l" "$eol"; done
  if [[ "$first" == '#!'* ]]; then tail -n +2 "$hook"; else cat "$hook"; fi
}

# _ss_content_replace <hook> <begin line> <end line>: those lines and every line between replaced
# by the current block, in the file's line ending. Bytes before the begin line and after the end
# line are copied as they are (head/tail, never re-read line by line).
_ss_content_replace() {
  local hook="$1" bl="$2" el="$3" eol=$'\n' l
  [ "$(eol_of "$hook")" = crlf ] && eol=$'\r\n'
  [ "$bl" -le 1 ] || head -n "$((bl - 1))" "$hook"
  for l in "${_SS_BLOCK[@]}"; do printf '%s%s' "$l" "$eol"; done
  tail -n +"$((el + 1))" "$hook"
}

# _ss_atomic_write <hook> <content fn> [args...]: write the hook without ever truncating it. The
# content function runs in this shell into a temp file in the hook's own directory (same
# filesystem, so the rename is atomic). The temp file gets the hook's mode (755 for a new hook)
# kept exactly, plus the owner's exec bit only (u+x: a 750 hook never widens to 751), and is then
# renamed over the hook. The rename is the only step that changes
# the hook. A failed write, or a signal recorded in _SS_SIG (fix_secret_scan sets recording traps
# before any write), removes the temp file instead and returns 1, so the hook is whole. A
# symlinked hook is rewritten at its target, as the old in-place write did, so the link survives.
_ss_atomic_write() {
  local hook="$1" fn="$2" dst dir tmp mode; shift 2
  dst="$hook"; [ -L "$hook" ] && dst="$(readlink -f -- "$hook")"
  dir="$(dirname "$dst")"
  tmp="$(mktemp "$dir/${_SS_HOOK_TMP_PREFIX}XXXXXX")" || return 1
  if ! "$fn" "$@" > "$tmp" || [ -n "${_SS_SIG:-}" ]; then rm -f "$tmp"; return 1; fi
  mode="$(stat -c %a -- "$dst" 2>/dev/null)" || mode=""
  if ! chmod "${mode:-755}" "$tmp" || ! chmod u+x "$tmp" || [ -n "${_SS_SIG:-}" ]; then rm -f "$tmp"; return 1; fi
  mv -f -- "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
}

# _ss_trap_record: record INT/TERM/HUP in _SS_SIG instead of dying, so a write or a proof always
# finishes its cleanup; the caller reports the signal and exits 128+n.
_ss_trap_record() { _SS_SIG=""; trap '_SS_SIG=INT' INT; trap '_SS_SIG=TERM' TERM; trap '_SS_SIG=HUP' HUP; }

# _ss_sig_exit: drop the recording traps; exit 128+n when a signal was recorded.
_ss_sig_exit() {
  trap - INT TERM HUP
  case "${_SS_SIG:-}" in INT) exit 130 ;; HUP) exit 129 ;; TERM) exit 143 ;; esac
}

# _ss_write_failed <note> <hook> <what>: the result of a hook write that did not happen. A recorded
# signal reports it (the hook is unchanged) and exits 128+n; otherwise "cannot write".
_ss_write_failed() {
  if [ -n "${_SS_SIG:-}" ]; then
    emit secret-scan failed "${1}interrupted by SIG$_SS_SIG before $3 was written; $2 is unchanged"
    _ss_sig_exit
  fi
  trap - INT TERM HUP
  emit secret-scan failed "${1}cannot write $2"
}

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
  t="$(path_norm "$1")"; p="$(path_norm "$2")"
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

# _ss_tail <text> -> its last 3 non-blank lines, colour codes stripped, joined with " | ", at most
# 300 characters. Empty for empty text.
_ss_tail() {
  local t
  t="$(printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 3)"
  t="${t//$'\n'/ | }"
  printf '%s' "${t:0:300}"
}

# _ss_proof_files <top> -> one "staged<TAB>name" or "disk<TAB>name" line per proof file present:
# the proof's own name pattern only, at the top of the work tree only. The sweep and the
# interrupt report both read this, so they agree on what a leftover is.
_ss_proof_files() {
  local top="$1" f
  while IFS= read -r -d '' f; do printf 'staged\t%s\n' "$f"; done \
    < <(git -C "$top" ls-files -z --cached -- ":(glob)$_SS_PROOF_PREFIX*" 2>/dev/null)
  for f in "$top/$_SS_PROOF_PREFIX"*; do
    { [ -e "$f" ] || [ -L "$f" ]; } && printf 'disk\t%s\n' "${f##*/}"
  done
  return 0
}

# _ss_sweep <top> -> a note (empty when there was nothing to do). Removes what an interrupted run
# left behind: proof files (staged ones are unstaged, files on disk deleted), and hook temp files
# (Ruling R16: a kill between _ss_atomic_write's mktemp and its mv leaves one, untracked when the
# hooks directory is in the work tree). Those are looked for where that write puts them: beside
# the hook git runs, or beside its target when it is a symlink. Only regular files named exactly
# as the mktemp template names them go; any other file in the hooks directory is the user's.
_ss_sweep() {
  local top="$1" f kind n=0 m=0 h
  local -A seen=()
  while IFS=$'\t' read -r kind f; do [ -n "$f" ] && seen["$f"]=1; done < <(_ss_proof_files "$top")
  for f in "${!seen[@]}"; do
    git --literal-pathspecs -C "$top" rm -q --cached --ignore-unmatch -- "$f" >/dev/null 2>&1
    rm -f "$top/$f"; n=$((n + 1))
  done
  h="$(_ss_hook "$top")"; [ -L "$h" ] && h="$(readlink -f -- "$h")"
  for f in "$(dirname "$h")/$_SS_HOOK_TMP_PREFIX"$_SS_HOOK_TMP_GLOB; do
    [ -f "$f" ] && rm -f -- "$f" && m=$((m + 1))
  done
  [ "$n" -eq 0 ] || printf 'removed %d leftover proof file(s) from an interrupted run; ' "$n"
  [ "$m" -eq 0 ] || printf 'removed %d leftover hook temp file(s) from an interrupted run; ' "$m"
}

# _ss_interrupt_detail <sig> <top> <proof result json, may be empty> <where> -> the detail of an
# interrupted run. Whether the proof file is gone is CHECKED here, never assumed.
_ss_interrupt_detail() {
  local sig="$1" top="$2" res="$3" where="$4" left r
  left="$(_ss_proof_files "$top" | awk -F '\t' '{ printf "%s%s (%s)", (NR > 1 ? ", " : ""), $2, ($1 == "disk" ? "on disk" : "staged") }')"
  if [ -z "$left" ]; then left="the proof file was removed"; else left="proof file still present: $left"; fi
  r="$(jq -r 'select(type == "object" and has("status")) | "\(.status): \(.detail)"' <<<"$res" 2>/dev/null | tr -d '\r')"
  printf 'interrupted by SIG%s %s; %s; proof result: %s' "$sig" "$where" "$left" "${r:-none}"
}

# check secret-scan <repo>: present = PROVED: with a fake AWS-style key staged in the real repo,
# `git hook run pre-commit` exits non-zero and gitleaks reports the leak. absent = no ritual block
# in the hook git runs (a block elsewhere is proved bypassed). unknown = no gitleaks, or a git
# without `git hook run`. failed = the block is in the hook git runs but the proof did not fire
# (the cause is in detail), the proof's side effects could not be undone, or it was interrupted.
# A stale block (version below _SS_VERSION) that passes the proof is present, its detail ending
# "; block vN, upgrade due": it scans, and fix secret-scan upgrades it.
check_secret_scan() {
  local repo="$1" top hook gl def h swept found=() res rc sig hook_usage v
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  swept="$(_ss_sweep "$top")"
  hook="$(_ss_hook "$top")"
  def="$(git_common_dir "$top")/hooks/pre-commit"
  # the block in a hook git does NOT run is still found, so that case goes through the proof too
  for h in "$hook" "$def"; do _ss_has_block "$h" && found+=("$h"); done
  gl="$(_ss_gitleaks)"
  if [ -z "$gl" ]; then
    emit secret-scan unknown "${swept}gitleaks not found (PATH, or LOCALAPPDATA/Microsoft/WinGet/Links); install it to prove the scan; ritual block in the hook git runs: $(_ss_has_block "$hook" && echo yes || echo no)"
    return 0
  fi
  if [ "${#found[@]}" -eq 0 ]; then
    emit secret-scan absent "${swept}no ritual secret-scan block in $hook"; return 0
  fi
  # Ask git for the subcommand's own usage rather than running a hook by name: git 2.36+ has
  # `git hook run`, and newer git (seen on 2.55) refuses an unknown hook name outright, so the
  # old probe (a made-up hook) read as "no git hook run" and no proof ever ran. -h runs nothing.
  hook_usage="$(git -C "$top" hook run -h 2>&1 </dev/null)"   # exits 129 by design; read the text, not the status
  if [[ "$hook_usage" != *'usage: git hook run'* ]]; then
    emit secret-scan unknown "${swept}this git has no 'git hook run' (needs 2.36+); the hook cannot be proved"; return 0
  fi
  # An interrupt must not return before the proof has cleaned up: these traps only record the
  # signal, and bash runs them after the proof's subshell has finished (its own traps do the same,
  # so it completes its cleanup and restore). Then the step reports failed.
  _SS_SIG=""
  trap '_SS_SIG=INT' INT; trap '_SS_SIG=TERM' TERM; trap '_SS_SIG=HUP' HUP
  res="$( _ss_proof "$top" "$hook" "$swept" )"; rc=$?
  trap - INT TERM HUP
  sig="$_SS_SIG"
  if [ -n "$sig" ]; then
    emit secret-scan failed "$(_ss_interrupt_detail "$sig" "$top" "$res" "during the proof")"
    case "$sig" in INT) exit 130 ;; HUP) exit 129 ;; *) exit 143 ;; esac
  fi
  [ "$rc" -eq 0 ] && [ -n "$res" ] || { emit secret-scan failed "${swept}the proof ended without a result (exit $rc); check git status"; return 0; }
  # A block with no version line that works is present (it scans). A shipped v1 text says it is
  # due the upgrade fix makes; any other text is the user's edit, which fix will not rewrite, so it
  # says that instead (it never promises an upgrade fix would refuse).
  if _ss_has_block "$hook" && [ "$(jq -r .status <<<"$res" 2>/dev/null | tr -d '\r')" = present ]; then
    case "$(_ss_block_state "$hook")" in
      stale)  emit secret-scan present "$(jq -r .detail <<<"$res" | tr -d '\r'); block v$(_ss_block_version "$hook"), upgrade due"; return 0 ;;
      edited) emit secret-scan present "$(jq -r .detail <<<"$res" | tr -d '\r'); $_SS_EDITED_NOTE"; return 0 ;;
    esac
  fi
  printf '%s\n' "$res"
}

# _ss_proof <top> <hook> <note>: run in a subshell (it sets its own traps; preflight sets one too
# and is only ever called inside $(...)). Prints one step result.
_ss_proof() {
  _SS_TOP="$1"; _SS_F=""; _SS_D=""
  local hook="$2" note="$3" before after out rc k diffs p b last
  trap '_ss_cleanup; [ -z "$_SS_D" ] || rm -rf "$_SS_D"' EXIT   # set before anything exists to clean
  trap ':' INT TERM HUP                                         # finish cleanup and restore first
  before="$(preflight "$_SS_TOP")" || { emit secret-scan unknown "${note}preflight failed before the proof"; return 0; }
  _SS_F="$(mktemp "$_SS_TOP/${_SS_PROOF_PREFIX}XXXXXX")" || { emit secret-scan unknown "${note}cannot create the proof file in $_SS_TOP"; return 0; }
  k="AKIA""Q7RZ3MXL2KTD5VNW"   # never one literal: see the test no_contiguous_key_in_source
  printf 'aws_access_key_id = %s\n' "$k" > "$_SS_F"
  if ! git --literal-pathspecs -C "$_SS_TOP" add -f -- "${_SS_F##*/}" >/dev/null 2>&1; then
    _ss_cleanup; emit secret-scan unknown "${note}could not stage the proof file"; return 0
  fi
  out="$(cd "$_SS_TOP" && git hook run pre-commit </dev/null 2>&1)"; rc=$?
  _ss_cleanup

  # Undo what a hook that ran past the scan may have done. Paths with nothing staged before are
  # reset to HEAD (their index before WAS HEAD); paths that were staged get their recorded index
  # blob back. The snapshots reach jq as files: jq.exe prints nothing past a ~32 KB command line.
  _SS_D="$(mktemp -d)" || { emit secret-scan failed "${note}mktemp failed after the proof; check git status"; return 0; }
  printf '%s' "$before" > "$_SS_D/before"
  after="$(preflight "$_SS_TOP")" || { emit secret-scan failed "${note}preflight failed after the proof; check git status"; return 0; }
  printf '%s' "$after" > "$_SS_D/after"
  diffs="$(_ss_changed "$_SS_D/before" "$_SS_D/after")"
  if [ -n "$diffs" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] && git --literal-pathspecs -C "$_SS_TOP" reset -q -- "$p" >/dev/null 2>&1
    done < <(_ss_changed "$_SS_D/before" "$_SS_D/after" unstaged)
    while IFS=$'\x1f' read -r p b; do
      [ -n "$p" ] && _ss_restore_index "$_SS_TOP" "$p" "$b"
    done < <(_ss_changed "$_SS_D/before" "$_SS_D/after" staged)
    after="$(preflight "$_SS_TOP")" || { emit secret-scan failed "${note}preflight failed after the proof; check git status"; return 0; }
    printf '%s' "$after" > "$_SS_D/after"
    diffs="$(_ss_changed "$_SS_D/before" "$_SS_D/after" all-with-index)"
    if [ -n "$diffs" ]; then
      local -a ps; mapfile -t ps <<<"$diffs"
      emit secret-scan failed "${note}the pre-commit hook changed the work tree or index during the proof (exit $rc) and it could not be undone: $(join_by '; ' "${ps[@]}")"
      return 0
    fi
  fi

  last="$(_ss_tail "$out")"; [ -z "$last" ] || last=": $last"
  if [ "$rc" -ne 0 ] && grep -qi gitleaks <<<"$out" && grep -q 'leaks found:' <<<"$out"; then
    emit secret-scan present "${note}proved: git hook run pre-commit blocked a staged fake key (exit $rc) via $hook"
  elif _ss_has_block "$hook"; then
    emit secret-scan failed "${note}the ritual block is in $hook, but the proof did not fire: git hook run pre-commit exited $rc without gitleaks reporting the staged fake key$last"
  else
    emit secret-scan absent "${note}the ritual block is not in the hook git runs ($hook), so it is bypassed; git hook run pre-commit let a staged fake key through (exit $rc)"
  fi
}

_ss_cleanup() {
  [ -n "${_SS_F:-}" ] || return 0
  git --literal-pathspecs -C "$_SS_TOP" rm -q --cached --ignore-unmatch -- "${_SS_F##*/}" >/dev/null 2>&1
  rm -f "$_SS_F"; _SS_F=""
}

# _ss_restore_index <top> <path> <blob|ABSENT>: put back a path's recorded index entry. The mode
# is the entry's current one (the hook re-added the same file), else HEAD's, else 100644.
_ss_restore_index() {
  local top="$1" p="$2" b="$3" mode
  if [ "$b" = ABSENT ]; then
    git -C "$top" update-index --force-remove -- "$p" >/dev/null 2>&1; return 0
  fi
  mode="$(git --literal-pathspecs -C "$top" ls-files -s -- "$p" 2>/dev/null | head -n 1 | cut -d' ' -f1)"
  [ -n "$mode" ] || mode="$(git --literal-pathspecs -C "$top" ls-tree HEAD -- "$p" 2>/dev/null | head -n 1 | cut -d' ' -f1)"
  git -C "$top" update-index --add --cacheinfo "${mode:-100644}" "$b" "$p" >/dev/null 2>&1
}

# _ss_changed <before-file> <after-file> [unstaged|staged|all-with-index] -> paths (one per line)
# whose dirty status, bytes or index entry differ between two preflight snapshots.
#   unstaged: only those with nothing staged before (clean, worktree-only change, or untracked);
#             for them the index before equals HEAD, so `git reset -- <path>` restores it exactly.
#   staged: the others, as "<path>\x1f<index blob before>", EXCEPT paths that were unmerged
#             (DD AU UD UA DU AA UU): preflight records only stage 0, so their "ABSENT" means
#             "conflicted", and writing it back would turn a conflict into a staged deletion.
#             They are never written; the ritual reports them and the user decides.
#   all-with-index: every path; staged ones followed by " (index was <blob>)" so the user's staged
#             version can be recovered by hand, unmerged ones with the command that restores the
#             conflict (`git update-index --unresolve`, measured to bring back all 3 stages).
_ss_changed() {
  jq -rn --slurpfile b "$1" --slurpfile a "$2" --arg mode "${3:-}" '
    $b[0] as $b | $a[0] as $a
    | def xy($x; $p): $x.dirty | map(select(.path == $p)) | .[0].xy;
      def st($x; $p): [xy($x; $p), $x.bytes[$p], $x.index[$p]];
      def unmerged($p): (xy($b; $p) // "  ") | IN("DD", "AU", "UD", "UA", "DU", "AA", "UU");
      def unstaged($p): (xy($b; $p) // "  ") | .[0:1] | IN(" ", "?");
    ([$b.dirty[].path] + [$a.dirty[].path] | unique)[] | select(st($b; .) != st($a; .))
    | if $mode == "unstaged" then select(unstaged(.))
      elif $mode == "staged" then select((unstaged(.) or unmerged(.)) | not) | "\(.)\u001f\($b.index[.] // "ABSENT")"
      elif $mode == "all-with-index" then
        (if unmerged(.) then "\"\(.)\" was unmerged before the proof; the hook changed it; restore the conflict with `git update-index --unresolve -- \"\(.)\"`"
         elif unstaged(.) then . else "\(.) (index was \($b.index[.] // "ABSENT"))" end)
      else . end' | tr -d '\r'
}

# fix secret-scan <repo>: put the block directly after the shebang of the pre-commit hook git
# runs (before bd's block and any user content), creating the hook when it does not exist.
# Idempotent by marker. Keeps the file's line endings and every existing byte. A block that is
# already there is proved like check does: if the proof does not fire, fix fails with the cause.
# --proved (Ruling R59): the caller asserts that this run's `check secret-scan` returned present,
# so an existing block is not proved a second time (no gitleaks run, no fake key staged); the result
# is `already`, with the hook in `wrote` while it differs from HEAD. With --proved and no block in
# the hook git runs, the caller's claim is false: `failed`, and nothing is installed.
# A stale block (no version line, and a v1 text the ritual shipped: _ss_block_state) is upgraded
# in place, with or without --proved (the text changed, so an earlier proof no longer covers it):
# its marker lines and everything between are replaced, every byte outside them is kept, then the
# fix runs the proof itself (Ruling R7). present -> `fixed` "upgraded ritual block vN → v2; <proof
# detail>"; otherwise the existing-block mapping (unknown "not proved: ...", else failed), naming
# the upgrade. The rewritten hook is in `wrote` for every one of those results (R14). The upgrade
# is never rolled back: v2 does everything v1 did, plus the timeout. A block with no version line
# whose text the ritual never shipped is the user's edit (R13): never rewritten, it is proved as
# before (R41/R59), and a present or already result says fix will not upgrade it.
fix_secret_scan() {
  local repo="$1" top hook rel first interp eol=$'\n' tmp nb ne l lastc swept res rc st dt proved=0 bl el v up="" state edited
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --proved) proved=1; shift ;;
      *) die "fix secret-scan: unknown argument: $1" ;;
    esac
  done
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  swept="$(_ss_sweep "$top")"
  hook="$(_ss_hook "$top")"
  rel="$(_ss_rel "$top" "$hook")"
  local -a wrote=(); [ -n "$rel" ] && wrote=("$rel")
  nb="$(_ss_count "$hook" "$_SS_BEGIN")"; ne="$(_ss_count "$hook" "$_SS_END")"
  if [ "$nb" -gt 0 ] || [ "$ne" -gt 0 ]; then
    if [ "$nb" != 1 ] || [ "$ne" != 1 ]; then
      emit secret-scan failed "${swept}$hook has $nb begin and $ne end ritual secret-scan markers; fix it by hand"; return 0
    fi
    bl="$(_ss_line_of "$hook" "$_SS_BEGIN")"; el="$(_ss_line_of "$hook" "$_SS_END")"
    if [ "$el" -lt "$bl" ]; then
      emit secret-scan failed "${swept}$hook has its ritual secret-scan markers out of order (end on line $el, begin on line $bl); fix it by hand"; return 0
    fi
    state="$(_ss_block_state "$hook")"
    # an edited block (R13) is never rewritten: it is proved like a current one, and says so
    edited=""; [ "$state" = edited ] && edited="; $_SS_EDITED_NOTE"
    # the same interrupt rule as check, from before the rewrite to the end of the proof: a signal
    # is recorded, the step in progress finishes or is undone, then it is reported
    _ss_trap_record
    if [ "$state" = stale ]; then
      v="$(_ss_block_version "$hook")"
      _ss_atomic_write "$hook" _ss_content_replace "$hook" "$bl" "$el" \
        || { _ss_write_failed "$swept" "$hook" "the upgrade of the ritual block"; return 0; }
      up="upgraded ritual block v$v → v$_SS_VERSION"
    elif [ "$proved" = 1 ]; then
      trap - INT TERM HUP
      emit_already secret-scan "$top" "${swept}ritual block already in $hook; proved by this run's check secret-scan$edited" ${wrote[@]+"${wrote[@]}"}
      return 0
    fi
    res="$(check_secret_scan "$repo")"; rc=$?
    trap - INT TERM HUP
    # check, interrupted itself, exits 128+n (its JSON then becomes the proof result here)
    if [ "$rc" -ge 128 ] || [ -n "$_SS_SIG" ]; then
      local sig="$_SS_SIG"
      [ -n "$sig" ] || case "$rc" in 130) sig=INT ;; 129) sig=HUP ;; *) sig=TERM ;; esac
      if [ -n "$up" ]; then   # the hook was rewritten: it is in wrote whatever happened next (R14)
        emit secret-scan failed "${swept}$up in $hook; $(_ss_interrupt_detail "$sig" "$top" "$res" "while proving the upgraded block")" ${wrote[@]+"${wrote[@]}"}
      else
        emit secret-scan failed "${swept}$(_ss_interrupt_detail "$sig" "$top" "$res" "while proving the existing block")"
      fi
      case "$sig" in INT) exit 130 ;; HUP) exit 129 ;; *) exit 143 ;; esac
    fi
    st="$(jq -r .status <<<"$res" 2>/dev/null | tr -d '\r')"; dt="$(jq -r .detail <<<"$res" 2>/dev/null | tr -d '\r')"
    if [ -n "$up" ]; then   # R14: the rewritten hook is in wrote for every result
      case "$st" in
        present) emit secret-scan fixed "${swept}$up; $dt" ${wrote[@]+"${wrote[@]}"} ;;
        unknown) emit secret-scan unknown "not proved: $dt; $up in $hook${swept:+; ${swept%; }}" ${wrote[@]+"${wrote[@]}"} ;;   # still starts "not proved:"
        *)       emit secret-scan failed "${swept}$up in $hook, but ${dt:-the proof gave no result}" ${wrote[@]+"${wrote[@]}"} ;;
      esac
      return 0
    fi
    case "$st" in
      present) emit_already secret-scan "$top" "${swept}ritual block already in $hook; $dt" ${wrote[@]+"${wrote[@]}"} ;;
      unknown) emit secret-scan unknown "not proved: $dt${swept:+; ${swept%; }}" ;;   # always starts "not proved:"
      *)       emit secret-scan failed "${swept}ritual block already in $hook, but ${dt:-the proof gave no result}" ;;
    esac
    return 0
  fi
  if [ "$proved" = 1 ]; then
    emit secret-scan failed "${swept}--proved, but $hook holds no ritual block: the hook changed since this run's check secret-scan; run check secret-scan again (nothing was written)"
    return 0
  fi
  if [ ! -s "$hook" ]; then
    mkdir -p "$(dirname "$hook")" || { emit secret-scan failed "${swept}cannot create $(dirname "$hook")"; return 0; }
    _ss_trap_record
    _ss_atomic_write "$hook" _ss_content_new || { _ss_write_failed "$swept" "$hook" "the new hook"; return 0; }
    emit secret-scan fixed "${swept}created $hook with the gitleaks block" ${wrote[@]+"${wrote[@]}"}
    _ss_sig_exit; return 0
  fi
  first="$(head -n 1 "$hook" | tr -d '\r')"
  if [[ "$first" == '#!'* ]]; then
    interp="$(_ss_interp "$first")"
    case "$interp" in
      sh|bash|dash|zsh) ;;
      *) emit secret-scan failed "${swept}$hook is not a shell script (interpreter: ${interp:-unrecognised}); add the gitleaks scan by hand"; return 0 ;;
    esac
  fi
  [ "$(eol_of "$hook")" = crlf ] && eol=$'\r\n'
  _ss_trap_record
  _ss_atomic_write "$hook" _ss_content_insert "$hook" "$first" "$eol" \
    || { _ss_write_failed "$swept" "$hook" "the gitleaks block"; return 0; }
  emit secret-scan fixed "${swept}inserted the gitleaks block after the shebang of $hook" ${wrote[@]+"${wrote[@]}"}
  _ss_sig_exit
}
