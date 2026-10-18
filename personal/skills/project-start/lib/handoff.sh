#!/usr/bin/env bash
# Step: handoff (NEXT.md, the .claude/handoff.json opt-in marker, the CLAUDE.md session routine),
# and the handoff-commit subcommand that makes the first handoff: commit, holding NEXT.md alone.
# Source this file; do not execute it. Needs common.sh sourced first.

_HANDOFF_NEXT_TEMPLATE="$RITUAL_SKILL_DIR/house/NEXT.md"
_HANDOFF_ROUTINE_FILE="$RITUAL_SKILL_DIR/house/session-routine.md"
_HANDOFF_MARKER='.claude/handoff.json'
_HANDOFF_MARK='- **Handoff.**'   # opening of the house section's first bullet; detection keys on it
_HANDOFF_SUBJECT='handoff: NEXT.md created by the project-start ritual'
_HANDOFF_TRAILER='Co-Authored-By: Claude <noreply@anthropic.com>'
_HANDOFF_WORKTREE='linked worktree; run the handoff step from the main checkout'
_HANDOFF_WT_UNKNOWN='could not tell whether this is a linked worktree (git rev-parse failed); nothing written'

# _handoff_linked <top> -> status 0 linked, 1 main checkout, 2 cannot tell. A safety guard fails
# CLOSED (Ruling R49): a rev-parse that fails, or prints nothing, is 2, never "not linked".
# Spec: NEXT.md is never edited in a linked worktree.
_handoff_linked() {
  local g c
  g="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 2
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 2
  [ -n "$g" ] && [ -n "$c" ] || return 2
  [ "$g" != "$c" ]
}

# _handoff_scan <claude-md> -> "house:<N>" when a "## Session routine" section (heading outside
# fences, at line N, any case) holds the house bullet outside fences; else "other:<N>" for the
# first such heading; else nothing. A section ends at the next "# " or "## " heading.
_handoff_scan() {
  local f="$1" i line h=-1 first=0
  [ -f "$f" ] || return 0
  local -a lines
  mapfile -t lines < "$f"
  MD_FENCE=""
  for i in "${!lines[@]}"; do
    md_fence "${lines[$i]}" && continue
    line="${lines[$i]%$'\r'}"
    if [[ "$line" =~ ^#{1,2}\  ]]; then
      if [[ "${line,,}" =~ ^##[[:space:]]+session[[:space:]]+routine[[:space:]]*$ ]]; then
        h=$i; [ "$first" -eq 0 ] && first=$((i + 1))
      else h=-1; fi
      continue
    fi
    if [ "$h" -ge 0 ] && [[ "$line" == "$_HANDOFF_MARK"* ]]; then echo "house:$((h + 1))"; return 0; fi
  done
  [ "$first" -eq 0 ] || echo "other:$first"
}

# _handoff_append_section <claude-md>: append the house section at EOF, after one blank line,
# with the file's own line ending. Creates the file when missing.
_handoff_append_section() {
  local f="$1" line
  if [ -s "$f" ] && [ -n "$(tail -n 1 "$f" | tr -d '\r')" ]; then append_line "$f" ""; fi
  while IFS= read -r line; do append_line "$f" "$line"; done < <(tr -d '\r' < "$_HANDOFF_ROUTINE_FILE")
}

# _handoff_replace_section <claude-md> <N>: replace the section whose heading is line N (up to the
# next "# " or "## " heading outside fences, else EOF) with the house section. Bytes outside it are
# kept; one blank line separates the house section from the heading that follows it.
_handoff_replace_section() {
  local f="$1" h=$(($2 - 1)) eol=$'\n' end i tmp line
  [ "$(eol_of "$f")" = crlf ] && eol=$'\r\n'
  local -a lines
  mapfile -t lines < "$f"
  end=${#lines[@]}
  MD_FENCE=""
  for ((i = h + 1; i < ${#lines[@]}; i++)); do
    md_fence "${lines[$i]}" && continue
    if [[ "${lines[$i]}" =~ ^#{1,2}\  ]]; then end=$i; break; fi
  done
  tmp="$f.handoff.$$"
  head -n "$h" "$f" > "$tmp"
  while IFS= read -r line; do printf '%s%s' "$line" "$eol" >> "$tmp"; done < <(tr -d '\r' < "$_HANDOFF_ROUTINE_FILE")
  if [ "$end" -lt "${#lines[@]}" ]; then printf '%s' "$eol" >> "$tmp"; tail -n +"$((end + 1))" "$f" >> "$tmp"; fi
  cat "$tmp" > "$f"; rm -f "$tmp"
}

# _handoff_ignored <top> -> yes|no|unknown: is the marker path git-ignored here?
_handoff_ignored() {
  local rc
  git -C "$1" check-ignore -q -- "$_HANDOFF_MARKER" 2>/dev/null; rc=$?
  case "$rc" in 0) echo yes ;; 1) echo no ;; *) echo unknown ;; esac
}

# Twin: ho_anchor in personal/hooks/handoff-lib.sh carries this subject-only anchor rule; change both together.
# _handoff_anchor <top> -> prints "<sha> <subject>" of the newest commit whose SUBJECT starts
# "handoff:" (never --grep, which also matches body lines). Returns 0 found, 1 none (an unborn
# branch has none), 2 history unreadable (including a HEAD that is neither valid nor unborn),
# 3 none IN REACH: the clone is shallow, so the anchor may lie beyond its cut-off (unknown, never
# "none"; the hook twin returns the same 3).
_handoff_anchor() {
  local log
  if ! git -C "$1" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    git -C "$1" symbolic-ref -q HEAD >/dev/null 2>&1 && return 1   # unborn branch
    return 2
  fi
  log="$(git -C "$1" log --format='%H %s' 2>/dev/null)" || return 2
  log="$(grep -m 1 -E '^[0-9a-f]+ handoff:' <<<"$log")" || {
    case "$(git -C "$1" rev-parse --is-shallow-repository 2>/dev/null)" in
      true) return 3 ;;
      false) return 1 ;;
      *) return 2 ;;
    esac
  }
  printf '%s\n' "$log"
}

_HANDOFF_SHALLOW="shallow clone: no handoff: commit within reach (run git fetch --unshallow to check)"

_handoff_ignore_note() {
  case "$1" in
    yes) echo "marker is git-ignored here; cloud sessions won't see it" ;;
    unknown) echo "could not tell whether the marker is git-ignored" ;;
  esac
}

check_handoff() {
  local repo="$1" top scan anchor rc unk="" note miss=()
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  [ -f "$top/NEXT.md" ] || miss+=("NEXT.md missing")
  [ -f "$top/$_HANDOFF_MARKER" ] || miss+=("$_HANDOFF_MARKER missing")
  if [ ! -f "$top/CLAUDE.md" ]; then miss+=("CLAUDE.md missing")
  else
    scan="$(_handoff_scan "$top/CLAUDE.md")"
    case "$scan" in
      house:*) ;;
      other:*) miss+=("different session routine (line ${scan#other:})") ;;
      *) miss+=("CLAUDE.md lacks the session routine") ;;
    esac
  fi
  anchor="$(_handoff_anchor "$top")"; rc=$?
  case "$rc" in
    1) miss+=("no handoff: commit") ;;
    2) unk="could not read the history for a handoff: commit" ;;
    3) unk="$_HANDOFF_SHALLOW" ;;
  esac
  note="$(_handoff_ignore_note "$(_handoff_ignored "$top")")"
  if [ "${#miss[@]}" -gt 0 ]; then emit handoff absent "$(join_by '; ' "${miss[@]}" ${unk:+"$unk"} ${note:+"$note"})"
  elif [ -n "$unk" ]; then emit handoff unknown "$(join_by '; ' "$unk" ${note:+"$note"})"
  else emit handoff present "$(join_by '; ' "NEXT.md, marker, session routine and handoff: commit ${anchor:0:7} present" ${note:+"$note"})"
  fi
}

# fix_handoff <repo> [--ask "<q>"] [--paths "<glob> <glob>"] [--replace-routine]
# Never lists NEXT.md in wrote: it goes in its own handoff: commit (handoff-commit), after the
# ritual's commit step. Lists the marker only when it is not git-ignored (it could not be committed).
fix_handoff() {
  local repo="$1" ask="" paths="" given=0 replace=0; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --ask) [ $# -ge 2 ] && [ -n "$2" ] || die "fix handoff: --ask needs a question"
             ask="$2"; given=$((given | 1)); shift 2 ;;
      --paths) [ $# -ge 2 ] && [ -n "${2//[[:space:]]/}" ] || die "fix handoff: --paths needs at least one glob"
               paths="$2"; given=$((given | 2)); shift 2 ;;
      --replace-routine) replace=1; shift ;;
      *) die "fix handoff: unknown argument: $1" ;;
    esac
  done
  local top ign scan n note tmp rc changed=0 different="" wrote=() notes=()
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  _handoff_linked "$top"; rc=$?
  case "$rc" in
    0) emit handoff unknown "$_HANDOFF_WORKTREE"; return 0 ;;
    1) ;;
    *) emit handoff unknown "$_HANDOFF_WT_UNKNOWN"; return 0 ;;
  esac

  if [ -e "$top/NEXT.md" ]; then notes+=("NEXT.md kept")
  else
    cp "$_HANDOFF_NEXT_TEMPLATE" "$top/NEXT.md" || { emit handoff failed "could not create NEXT.md"; return 0; }
    notes+=("NEXT.md created; run handoff-commit after the commit step"); changed=1
  fi

  ign="$(_handoff_ignored "$top")"
  if [ -e "$top/$_HANDOFF_MARKER" ]; then
    if [ "$given" -ne 0 ]; then notes+=("marker kept (--ask/--paths not applied)"); else notes+=("marker kept"); fi
  else
    # ask and paths reach jq on stdin (\x1e-separated): jq.exe is a native program and argv
    # would cross a Windows code-page conversion. Written to a temp file then moved, so a failure
    # never leaves a partial marker that a rerun would keep.
    tmp="$top/$_HANDOFF_MARKER.tmp.$$"
    if ! { mkdir -p "$top/.claude" && printf '%s\x1e%s' "$ask" "$paths" \
      | jq -Rs --arg g "$given" '(split("\u001e")) as $v | ($g | tonumber) as $g
          | (if $g % 2 == 1 then {ask: $v[0]} else {} end)
            + (if $g >= 2 then {paths: [$v[1] | splits("[ \t\n]+") | select(length > 0)]} else {} end)' \
      | tr -d '\r' > "$tmp" && mv "$tmp" "$top/$_HANDOFF_MARKER"; }; then
      rm -f "$tmp"; emit handoff failed "could not write $_HANDOFF_MARKER"; return 0
    fi
    notes+=("marker created"); changed=1
    [ "$ign" = no ] && wrote+=("$_HANDOFF_MARKER")
  fi
  note="$(_handoff_ignore_note "$ign")"; [ -z "$note" ] || notes+=("$note")

  scan="$(_handoff_scan "$top/CLAUDE.md")"; n="${scan#*:}"
  case "$scan" in
    house:*) notes+=("session routine present") ;;
    other:*)
      if [ "$replace" = 1 ]; then
        _handoff_replace_section "$top/CLAUDE.md" "$n"; wrote+=(CLAUDE.md); changed=1
        notes+=("session routine replaced (line $n)")
      else different="different session routine (line $n); needs --replace-routine"; fi ;;
    *) _handoff_append_section "$top/CLAUDE.md"; wrote+=(CLAUDE.md); changed=1; notes+=("session routine added") ;;
  esac
  if [ -z "$different" ] && [[ "$(_handoff_scan "$top/CLAUDE.md")" != house:* ]]; then
    emit handoff failed "session routine not found in CLAUDE.md after the edit" "${wrote[@]}"; return 0
  fi

  if [ -n "$different" ]; then emit handoff absent "$(join_by '; ' "$different" "${notes[@]}")" "${wrote[@]}"
  elif [ "$ign" = unknown ]; then emit handoff unknown "$(join_by '; ' "${notes[@]}")" "${wrote[@]}"
  elif [ "$changed" = 1 ]; then emit handoff fixed "$(join_by '; ' "${notes[@]}")" "${wrote[@]}"
  else emit_already handoff "$top" "$(join_by '; ' "${notes[@]}")" "$_HANDOFF_MARKER" CLAUDE.md   # never NEXT.md
  fi
}

# handoff_commit <repo>: when no handoff: commit exists, make the first one holding NEXT.md alone.
# NEXT.md untracked or changed -> commit it alone; tracked and clean -> an empty commit (the anchor
# still holds no file but NEXT.md). Refuses, touching nothing, when any other path is staged. A
# hook that stages another file during the commit makes an anchor holding more than NEXT.md: that is
# `failed` (spec 5b: NEXT.md alone), and the detail names the files and the undo.
handoff_commit() {
  local repo="$1" top anchor rc raw p tracked=0 added=0 st msg out kind head files others=()
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  _handoff_linked "$top"; rc=$?
  case "$rc" in
    0) emit handoff failed "$_HANDOFF_WORKTREE"; return 0 ;;
    1) ;;
    *) emit handoff failed "$_HANDOFF_WT_UNKNOWN"; return 0 ;;
  esac
  anchor="$(_handoff_anchor "$top")"; rc=$?
  case "$rc" in
    0) emit handoff already "a handoff: commit exists: ${anchor:0:7} ${anchor#* }"; return 0 ;;
    2) emit handoff unknown "could not read the history for a handoff: commit"; return 0 ;;
    3) emit handoff failed "$_HANDOFF_SHALLOW"; return 0 ;;
  esac
  [ -f "$top/NEXT.md" ] || { emit handoff failed "NEXT.md does not exist; run fix handoff first"; return 0; }
  # --no-renames: a staged rename into NEXT.md also stages a deletion, which must count as other
  raw="$(git -C "$top" diff --cached --no-renames --name-only -z | tr '\0' '\036')" \
    || { emit handoff unknown "could not read the index"; return 0; }
  while IFS= read -r -d $'\036' p; do [ "$p" = NEXT.md ] || others+=("$p"); done <<<"$raw"
  if [ "${#others[@]}" -gt 0 ]; then
    emit handoff failed "other paths are staged ($(join_by ', ' "${others[@]}")); a handoff: commit holds NEXT.md alone, so unstage or commit them first"
    return 0
  fi
  git -C "$top" ls-files --error-unmatch -- NEXT.md >/dev/null 2>&1 && tracked=1
  if [ "$tracked" = 0 ]; then
    # ask git directly: an empty status line also means "untracked" under status.showUntrackedFiles=no
    git -C "$top" check-ignore -q -- NEXT.md 2>/dev/null; rc=$?
    case "$rc" in
      0) emit handoff failed "NEXT.md is git-ignored here; a handoff: commit cannot hold it"; return 0 ;;
      1) st='?? NEXT.md' ;;
      *) emit handoff unknown "could not tell whether NEXT.md is git-ignored"; return 0 ;;
    esac
  else
    st="$(git -C "$top" status --porcelain -- NEXT.md)" || { emit handoff unknown "could not read the status of NEXT.md"; return 0; }
  fi

  msg="$(mktemp)" || die "mktemp failed"
  printf '%s\n\n%s\n' "$_HANDOFF_SUBJECT" "$_HANDOFF_TRAILER" > "$msg"
  if [ -n "$st" ]; then
    if [ "$tracked" = 0 ]; then
      git -C "$top" add -- NEXT.md || { rm -f "$msg"; emit handoff failed "git add NEXT.md failed"; return 0; }
      added=1
    fi
    out="$(git -C "$top" commit -q -F "$msg" -- NEXT.md 2>&1)" || {
      [ "$added" = 1 ] && git -C "$top" rm -q --cached -- NEXT.md >/dev/null 2>&1
      rm -f "$msg"; emit handoff failed "git commit failed: $out"; return 0; }
    kind="committed NEXT.md"
  else
    out="$(git -C "$top" commit -q --allow-empty -F "$msg" 2>&1)" || { rm -f "$msg"; emit handoff failed "git commit failed: $out"; return 0; }
    kind="NEXT.md was already committed; made an empty handoff: anchor"
  fi
  rm -f "$msg"

  head="$(git -C "$top" log -1 --format='%H %s')"
  files="$(git -C "$top" -c core.quotePath=false show --name-only --format= HEAD)"
  if [[ "${head#* }" == handoff:* ]] && [ -n "$files" ] && [ "$files" != NEXT.md ]; then
    local added; added="$(grep -vxF NEXT.md <<<"$files" | paste -sd ',' - | sed 's/,/, /g')"
    emit handoff failed "committed, but a hook added $added: handoff: commit ${head:0:7} holds more than NEXT.md; \`git reset --soft HEAD~1\` undoes the commit and keeps its changes"
    return 0
  fi
  if [[ "${head#* }" != handoff:* ]] || { [ -n "$files" ] && [ "$files" != NEXT.md ]; }; then
    emit handoff failed "HEAD is not a NEXT.md-only handoff: commit after committing: ${head:0:7} ($files)"; return 0
  fi
  emit handoff fixed "$kind: ${head:0:7}"
}
