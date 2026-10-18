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

# The block (POSIX sh, safe under `sh -e`). It runs first in the hook, so a leak stops the commit
# before anything else in the hook runs. Without gitleaks it warns loudly and lets the commit
# through. A non-zero gitleaks exit always blocks; its message says whether secrets were found or
# gitleaks itself failed (then nothing was scanned).
_SS_BLOCK=(
  "$_SS_BEGIN"
  '# Managed by the project-start ritual: scan the staged changes for secrets before anything else.'
  "${_SS_RESOLVER[@]}"
  'if [ -n "$_ritual_gl" ]; then'
  '  _ritual_rc=0'
  '  _ritual_out="$("$_ritual_gl" git --pre-commit --staged --redact --no-banner --no-color --verbose 2>&1)" || _ritual_rc=$?'
  '  [ -z "$_ritual_out" ] || printf "%s\n" "$_ritual_out" >&2'
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

# _ss_sweep <top> -> a note (empty when there was nothing to do). Removes proof files an interrupted
# run left behind: staged ones are unstaged, files on disk deleted.
_ss_sweep() {
  local top="$1" f kind n=0
  local -A seen=()
  while IFS=$'\t' read -r kind f; do [ -n "$f" ] && seen["$f"]=1; done < <(_ss_proof_files "$top")
  for f in "${!seen[@]}"; do
    git --literal-pathspecs -C "$top" rm -q --cached --ignore-unmatch -- "$f" >/dev/null 2>&1
    rm -f "$top/$f"; n=$((n + 1))
  done
  [ "$n" -eq 0 ] || printf 'removed %d leftover proof file(s) from an interrupted run; ' "$n"
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
check_secret_scan() {
  local repo="$1" top hook gl def h swept found=() res rc sig
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
  if ! git -C "$top" hook run --ignore-missing ritual-nonexistent-hook </dev/null >/dev/null 2>&1; then
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
fix_secret_scan() {
  local repo="$1" top hook rel first interp eol=$'\n' tmp nb ne l lastc swept res rc st dt
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
    # same interrupt rule as check: wait for the proof to clean up, then report
    _SS_SIG=""
    trap '_SS_SIG=INT' INT; trap '_SS_SIG=TERM' TERM; trap '_SS_SIG=HUP' HUP
    res="$(check_secret_scan "$repo")"; rc=$?
    trap - INT TERM HUP
    # check, interrupted itself, exits 128+n (its JSON then becomes the proof result here)
    if [ "$rc" -ge 128 ] || [ -n "$_SS_SIG" ]; then
      local sig="$_SS_SIG"
      [ -n "$sig" ] || case "$rc" in 130) sig=INT ;; 129) sig=HUP ;; *) sig=TERM ;; esac
      emit secret-scan failed "${swept}$(_ss_interrupt_detail "$sig" "$top" "$res" "while proving the existing block")"
      case "$sig" in INT) exit 130 ;; HUP) exit 129 ;; *) exit 143 ;; esac
    fi
    st="$(jq -r .status <<<"$res" 2>/dev/null | tr -d '\r')"; dt="$(jq -r .detail <<<"$res" 2>/dev/null | tr -d '\r')"
    case "$st" in
      present) emit_already secret-scan "$top" "${swept}ritual block already in $hook; $dt" ${wrote[@]+"${wrote[@]}"} ;;
      unknown) emit secret-scan unknown "not proved: $dt${swept:+; ${swept%; }}" ;;   # always starts "not proved:"
      *)       emit secret-scan failed "${swept}ritual block already in $hook, but ${dt:-the proof gave no result}" ;;
    esac
    return 0
  fi
  if [ ! -s "$hook" ]; then
    mkdir -p "$(dirname "$hook")" || { emit secret-scan failed "${swept}cannot create $(dirname "$hook")"; return 0; }
    { printf '%s\n' '#!/usr/bin/env sh'; printf '%s\n' "${_SS_BLOCK[@]}"; } > "$hook" \
      || { emit secret-scan failed "${swept}cannot write $hook"; return 0; }
    chmod +x "$hook"
    emit secret-scan fixed "${swept}created $hook with the gitleaks block" ${wrote[@]+"${wrote[@]}"}
    return 0
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
  tmp="$(mktemp)" || { emit secret-scan failed "${swept}mktemp failed"; return 0; }
  {
    if [[ "$first" == '#!'* ]]; then
      head -n 1 "$hook"
      lastc="$(head -n 1 "$hook" | tail -c 1 | od -An -tx1 | tr -d ' \n')"
      [ "$lastc" = 0a ] || printf '%s' "$eol"
    fi
    for l in "${_SS_BLOCK[@]}"; do printf '%s%s' "$l" "$eol"; done
    if [[ "$first" == '#!'* ]]; then tail -n +2 "$hook"; else cat "$hook"; fi
  } > "$tmp" && cat "$tmp" > "$hook" || { rm -f "$tmp"; emit secret-scan failed "${swept}cannot write $hook"; return 0; }
  rm -f "$tmp"; chmod +x "$hook"
  emit secret-scan fixed "${swept}inserted the gitleaks block after the shebang of $hook" ${wrote[@]+"${wrote[@]}"}
}
