#!/usr/bin/env bash
# SessionStart (matcher startup|compact) -- the session-start half of the NEXT.md handoff.
#
# WHY THIS EXISTS
#   The handoff routine (skills/handoff/SKILL.md) starts every session by asking the developer how
#   the last change went and showing what changed since the last handoff: commit. An agent that
#   has to REMEMBER to do that will skip it, so this hook does the remembering: it computes the
#   anchor and the changes and puts them, with the question, into the agent's context.
#
# WHEN IT SPEAKS (only in a repo carrying .claude/handoff.json; silent everywhere else)
#   source startup  the question, then either the last 10 commits to PICK from (no anchor) or the
#                   commits since the anchor, tagged [agent]/[other], the uncommitted changes and
#                   the marker's `paths` diff; plus "the last session ended without a handoff"
#                   when agent commits sit after the anchor; plus the end-of-session duty.
#                   A shallow clone with no anchor in reach says so (unknown, never "no anchor"),
#                   and says the compact and shipping reminders cannot work in it.
#                   In a linked worktree (or one git cannot place) agent commits after the anchor
#                   are the expected state: counted, with "hand off after the merge", never MISSED.
#   source compact  only the handoff reminder, and only when agent commits sit after the anchor:
#                   a compaction means a long session is about to lose its working memory.
#   anything else   (resume, clear, fork) silent. The matcher should already keep them out; the
#                   check here makes a matcher mismatch fail safe.
#
# Output: {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":...}}, which
# reaches the agent, not the user's screen. Capped well under the 10,000-character limit.
#
# NEVER fails the session: always exits 0.

set -uo pipefail

json="$(</dev/stdin)"   # one read; `read -d ''` takes a pipe a byte at a time (~5 s per MB)
case "$0" in */*) here="${0%/*}" ;; *) here=. ;; esac
. "$here/handoff-lib.sh" 2>/dev/null || exit 0

ho_json_field "$json" source || exit 0
src="$HO_FIELD"
case "$src" in startup|compact) ;; *) exit 0 ;; esac
cwd="$PWD"
ho_json_field "$json" cwd && [ -n "$HO_FIELD" ] && cwd="$HO_FIELD"
ho_marker "$cwd" || exit 0
command -v jq >/dev/null 2>&1 || exit 0
root="$HO_ROOT"

anchor_line="$(ho_anchor "$root")"; arc=$?
anchor=""; asubj=""
[ "$arc" = 0 ] && { anchor="${anchor_line%% *}"; asubj="${anchor_line#* }"; }
linked=0; ho_in_linked_worktree "$root" && linked=1
ho_wt_phrase   # HO_WT_PHRASE: "this is a linked worktree" or "git could not tell ..."

if [ "$src" = compact ]; then
  [ "$arc" = 0 ] && ho_pending "$root" "$anchor" || exit 0
  msg="HANDOFF PENDING: $HO_PENDING_N agent commit(s) since the last handoff: commit (${anchor:0:12} $asubj)."
  if [ "$linked" = 1 ]; then
    msg+=" Never edit NEXT.md here ($HO_WT_PHRASE): hand off after the merge, in the main checkout (the handoff skill)."
  else
    msg+=" Before this session ends, update NEXT.md for the developer and commit it ALONE, in the same turn, with a subject starting \"handoff:\" (the handoff skill)."
  fi
  ho_emit SessionStart "$msg"
  exit 0
fi

# --- startup ------------------------------------------------------------------------------------

ask="$HO_DEFAULT_ASK"; paths=(); mnote=""
if mj="$(jq -r 'if type == "object" then
      (if (.ask | type) == "string" and (.ask | length) > 0 then .ask else "" end)
      + "\u001e"
      + ((.paths // []) | if type == "array" then [.[] | strings] | join("\u001f") else "" end)
    else error("not an object") end' 2>/dev/null < "$root/$HO_MARKER_REL")"; then
  # (2>/dev/null comes BEFORE the <: redirections apply left to right, so the shell's own error
  # for an unreadable or vanished marker would otherwise reach stderr)
  mj="${mj//$'\r'/}"
  [ -n "${mj%%$'\x1e'*}" ] && ask="${mj%%$'\x1e'*}"
  p="${mj#*$'\x1e'}"
  [ -n "$p" ] && IFS=$'\x1f' read -r -a paths <<<"$p"
else
  mnote="(could not read .claude/handoff.json as a JSON object; using the default question and no paths)"
fi

L=()
cap() {   # cap <max> <lines...>: append "  <line>" for up to <max> lines, then a "+N more" note
  local max="$1" i=0 l; shift
  if [ $# -eq 0 ]; then L+=("  (none)"); return; fi
  for l in "$@"; do
    [ "$i" -ge "$max" ] && { L+=("  ... +$(($# - max)) more"); return; }
    L+=("  ${l%$'\r'}"); i=$((i + 1))
  done
}

L+=("HANDOFF: this repo opted in (.claude/handoff.json); the handoff skill holds the routine.")
[ -n "$mnote" ] && L+=("$mnote")
L+=("1. Ask the developer: \"$ask\" Then record the answer, dated, in NEXT.md's Feedback log (newest first).")

D=()
case "$arc" in
  1)
    L+=("2. No handoff: commit was found, so there is nothing to diff from. Show the developer these last 10 commits (newest first) and ask them to PICK the one to diff from (never ask for a SHA):")
    mapfile -t C < <(ho_commits_since "$root" "" 10)
    cap 10 "${C[@]}"
    ;;
  3)
    L+=("2. This clone's history is SHALLOW and no handoff: commit is within reach, so the last handoff may lie beyond the cut-off: what changed since it is unknown, not absent. Either deepen the clone (git fetch --unshallow) and look for the newest handoff: commit, or show the developer these last commits (newest first) and ask them to PICK the one to diff from (never ask for a SHA):")
    mapfile -t C < <(ho_commits_since "$root" "" 10)
    cap 10 "${C[@]}"
    L+=("While no handoff: commit is in reach, the compact and shipping reminders cannot tell whether a handoff is pending, so they stay OFF in this clone: the end-of-session duty below is on you alone.")
    ;;
  2)
    L+=("2. Could not read this repo's git history, so what changed since the last handoff is unknown. Say so to the developer.")
    ;;
  0)
    adate="$(git -C "$root" log -1 --date=short --format=%ad "$anchor" 2>/dev/null)"
    L+=("2. Show the developer what changed since the last handoff (${anchor:0:12} \"$asubj\", $adate):")
    mapfile -t C < <(ho_commits_since "$root" "$anchor")
    L+=("Commits since the handoff, newest first ([agent] = a Co-Authored-By: Claude trailer or an auto-commit; [other] = anything else; a listing, not an authorship claim):")
    cap 20 "${C[@]}"
    mapfile -t S < <(git -C "$root" -c core.quotepath=false status --short 2>/dev/null)
    L+=("Uncommitted changes (git status --short):")
    cap 20 "${S[@]}"
    n=0; for c in "${C[@]}"; do [[ $c == "[agent]"* ]] && n=$((n + 1)); done
    if [ "$n" -gt 0 ] && [ "$linked" = 1 ]; then
      # handing off is forbidden here, so agent commits after the anchor are the expected state
      L+=("$n agent commit(s) since the last handoff: commit; hand off after the merge, in the main checkout ($HO_WT_PHRASE).")
    elif [ "$n" -gt 0 ]; then
      L+=("MISSED HANDOFF: the last session ended without a handoff: $n agent commit(s) after the anchor. Reconstruct NEXT.md from \`git log ${anchor:0:12}..HEAD\` and hand off before starting new work.")
    fi
    if [ "${#paths[@]}" -gt 0 ]; then
      L+=("Diff of the hand-edited paths since the handoff, committed and uncommitted; new untracked files show only in the status list (git diff ${anchor:0:12} -- ${paths[*]}):")
      mapfile -t D < <(git -C "$root" -c core.quotepath=false diff --no-color --no-ext-diff "$anchor" -- "${paths[@]}" 2>/dev/null)
      [ "${#D[@]}" -gt 0 ] || L+=("  (no changes)")
    fi
    ;;
esac

if [ "$linked" = 1 ]; then
  duty="End of session: $HO_WT_PHRASE, so never edit NEXT.md here; hand off after the merge, in the main checkout (the handoff skill has the routine)."
else
  duty="End of session: update NEXT.md for the developer, in plain words, and commit it ALONE, in the same turn, with a subject starting \"handoff:\" (the handoff skill has the routine)."
fi

# The diff goes last before the duty line, capped at 200 lines AND at what fits in the
# additionalContext budget (10,000 characters, beyond which the harness swaps in a preview).
if [ "${#D[@]}" -gt 0 ]; then
  used=$(( ${#duty} + 200 )); for l in "${L[@]}"; do used=$((used + ${#l} + 1)); done
  budget=$((9000 - used)); shown=0
  for l in "${D[@]}"; do
    l="${l%$'\r'}"
    [ "$shown" -ge 200 ] && break
    [ $((${#l} + 1)) -gt "$budget" ] && break
    L+=("$l"); budget=$((budget - ${#l} - 1)); shown=$((shown + 1))
  done
  [ "$shown" -lt "${#D[@]}" ] && L+=("  ... +$((${#D[@]} - shown)) more lines")
fi
L+=("$duty")

printf -v ctx '%s\n' "${L[@]}"
ho_emit SessionStart "${ctx%$'\n'}"
exit 0
