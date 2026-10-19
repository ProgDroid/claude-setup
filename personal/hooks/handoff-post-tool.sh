#!/usr/bin/env bash
# PostToolUse (matchers Bash|PowerShell and Edit|Write|MultiEdit) -- the in-session half of the
# NEXT.md handoff. Rules: skills/handoff/SKILL.md.
#
# WHY THIS EXISTS
#   The end of a session is invisible to hooks (Stop fires every turn; SessionEnd cannot reach the
#   agent), so the handoff reminder rides on the moments that ARE visible:
#     - a `git commit` or `git merge` that made a handoff: commit holding files other than
#       NEXT.md (a merge is compared with its first parent) -> warn, naming them (an empty
#       handoff: anchor, made after an auto-commit swept NEXT.md, is fine);
#     - shipping (`git push`, `gh pr create`, `gh pr merge`, `git merge`) with agent commits after
#       the newest handoff: commit and none since -> "hand off now" (linked worktree, or one git
#       cannot place: after the merge, in the main checkout);
#     - an Edit/Write/MultiEdit of the repo-root NEXT.md in a KNOWN linked worktree -> warn. The
#       branch is NOT checked: handing off on a feature branch in the main checkout is normal.
#
# SPEED: this runs on every Bash/PowerShell call in every project. The payload is read in one
# pass (one fork), and until the marker is found nothing else forks: the field reads and the
# marker walk are pure bash, and none of them scans the whole payload (a tool_response can be
# megabytes). Only a command mentioning `-C` (the repo may be elsewhere) reaches jq without a
# marker at the cwd.
#
# Model-facing only (additionalContext). Silent in any repo without .claude/handoff.json.
# NEVER fails the session: always exits 0.

set -uo pipefail

# One read via cat: `read -d ''` takes a pipe a byte at a time (~5 s per MB), and `$(</dev/stdin)`
# fails on the native Windows pipe Claude Code hands a hook ("No such file or directory").
json="$(cat)"
case "$0" in */*) here="${0%/*}" ;; *) here=. ;; esac
. "$here/handoff-lib.sh" 2>/dev/null || exit 0

ho_json_field "$json" tool_name || exit 0
tool="$HO_FIELD"
cwd="$PWD"
ho_json_field "$json" cwd && [ -n "$HO_FIELD" ] && cwd="$HO_FIELD"
cwd="${cwd//\\//}"
msgs=()

# abs <path>: set ABS to <path> made absolute against the payload cwd (no fork)
abs() { case "$1" in /*|[A-Za-z]:*) ABS="$1" ;; *) ABS="$cwd/$1" ;; esac; }

commit_check() {
  local head subj f extras=()
  head="$(git -C "$HO_ROOT" log -1 --format='%H %s' 2>/dev/null)" || return
  subj="${head#* }"
  [[ $subj == handoff:* ]] || return
  while IFS= read -r f; do
    f="${f%$'\r'}"
    [ -n "$f" ] && [ "$f" != NEXT.md ] && extras+=("$f")
  done < <(git -C "$HO_ROOT" -c core.quotepath=false show --name-only --format= --diff-merges=first-parent HEAD 2>/dev/null)
  # (first-parent: a merge's default combined diff lists only conflicted files, so a clean
  # handoff: merge bringing in other files would look like NEXT.md alone)
  [ "${#extras[@]}" -gt 0 ] || return
  local list=""
  for f in "${extras[@]}"; do list+="${list:+, }$f"; done
  msgs+=("HANDOFF COMMIT HOLDS MORE THAN NEXT.md: ${head:0:12} \"$subj\" also touched: $list. A handoff: commit holds NEXT.md alone, so the anchor marks the handoff and nothing else. Unless this is the squash merge to the default branch (the one exception), and if it is not pushed yet: undo it with \`git reset --soft HEAD~1\`, commit the other files on their own, then commit NEXT.md alone as handoff:.")
}

ship_check() {
  local line anchor head
  # no anchor in reach (none, unreadable, or a shallow clone's cut-off) -> nothing to compare
  # against; for a shallow clone the startup context already said these reminders are off
  line="$(ho_anchor "$HO_ROOT")" || return
  anchor="${line%% *}"
  head="$(git -C "$HO_ROOT" log -1 --format=%s 2>/dev/null)" || return
  [[ $head == handoff:* ]] && return
  ho_pending "$HO_ROOT" "$anchor" || return
  if ho_in_linked_worktree "$HO_ROOT"; then
    ho_wt_phrase
    msgs+=("HAND OFF AFTER THE MERGE: $HO_PENDING_N agent commit(s) since the last handoff: commit (${anchor:0:12}), shipped from here ($HO_WT_PHRASE). Never edit NEXT.md here: hand off after the merge, in the main checkout (update NEXT.md for the developer and commit it alone as handoff:). A squash merge to the default branch must also start with \`handoff:\`.")
  else
    msgs+=("Shipping with $HO_PENDING_N agent commit(s) since the last handoff: commit (${anchor:0:12}), so hand off now: update NEXT.md (for the developer) and commit it alone as \`handoff: ...\`; a squash merge must also start with \`handoff:\` (the handoff skill).")
  fi
}

shell_call() {
  local found=0 cmd
  # Cheapest exits first, and none that scans the whole payload: a Bash call's tool_response can
  # be megabytes, while tool_input.command sits near the start (the regex stops at its match).
  ho_json_field "$json" command || return
  [[ $HO_FIELD == *git* || $HO_FIELD == *gh* ]] || return
  ho_marker "$cwd" && found=1
  [ "$found" = 1 ] || [[ $HO_FIELD == *-C* ]] || return
  command -v jq >/dev/null 2>&1 || return
  cmd="$(jq -r '.tool_input.command // empty' <<<"$json" 2>/dev/null)" || return
  ho_scan_command "$cmd"
  [ -n "$HO_ACTS" ] || return
  if [ -n "$HO_CDIR" ]; then
    abs "${HO_CDIR//\\//}"
    ho_marker "$ABS" || return
  elif [ "$found" != 1 ]; then
    return
  fi
  # a merge commits too (`git merge --no-ff -m "handoff: ..."`), so it gets the same check
  [[ $HO_ACTS == *" commit"* || $HO_ACTS == *" merge"* ]] && commit_check
  [[ $HO_ACTS == *" push"* || $HO_ACTS == *" merge"* || $HO_ACTS == *" prcreate"* || $HO_ACTS == *" prmerge"* ]] && ship_check
}

edit_call() {
  local fp dir
  ho_json_field "$json" file_path || return   # before anything that scans a Write's whole content
  fp="${HO_FIELD//\\//}"
  [ "${fp##*/}" = NEXT.md ] || return
  dir="${fp%/*}"; [ "$dir" = "$fp" ] && dir=.
  abs "$dir"
  ho_marker "$ABS" || return
  [ "$HO_ROOT" = "$HO_START" ] || return      # the repo-root NEXT.md only
  # a KNOWN linked worktree only: when git cannot tell, stay silent (fail closed toward silence)
  ho_worktree "$HO_ROOT"; [ "$HO_WT" = linked ] || return
  msgs+=("NEXT.md EDITED IN A LINKED WORKTREE ($HO_ROOT/NEXT.md). Never edit NEXT.md in a linked worktree: hand off after the merge, in the main checkout, where the developer often keeps uncommitted session notes. Undo this edit here.")
}

case "$tool" in
  Bash|PowerShell) shell_call ;;
  Edit|Write|MultiEdit) edit_call ;;
esac

[ "${#msgs[@]}" -gt 0 ] || exit 0
printf -v ctx '%s\n\n' "${msgs[@]}"
ho_emit PostToolUse "${ctx%$'\n\n'}"
exit 0
