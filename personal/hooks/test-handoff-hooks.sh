#!/usr/bin/env bash
# Tests for the handoff hooks (handoff-lib.sh, handoff-session-start.sh, handoff-post-tool.sh),
# their hooks.json registration and the handoff skill's SKILL.md.
#
# Run:  bash personal/hooks/test-handoff-hooks.sh
#
# Payloads are built with jq -n, never hand-escaped printf: a malformed fixture makes the hook
# exit early, and every "silent" case would then pass vacuously. Every silent case below is
# paired with a control in which the same repo, with the marker, DOES speak.

set -uo pipefail

HOOKS="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="$(cd "$HOOKS/.." && pwd)"
LIB="$HOOKS/handoff-lib.sh"
SS="$HOOKS/handoff-session-start.sh"
PT="$HOOKS/handoff-post-tool.sh"
SKILL="$PLUGIN/skills/handoff/SKILL.md"
RITUAL_LIB="$PLUGIN/skills/project-start/lib"

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
FIX="$TMPROOT/handoff fixtures"; mkdir -p "$FIX"

pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

AGENT='Co-Authored-By: Claude <noreply@anthropic.com>'
DEFAULT_ASK='How did the last change go?'

# --- fixtures -------------------------------------------------------------------------------

# mkrepo <name> -> path of a new repo (one seed commit) whose path contains a space
mkrepo() {
  local d="$FIX/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main >/dev/null 2>&1 || git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  git -C "$d" config core.autocrlf false
  echo seed > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -q -m seed
  printf '%s\n' "$d"
}

# cm <repo> <subject> <trailer-or-""> [path=content ...]: commit (empty unless paths are given).
# A trailer of the form "BODY:<text>" puts <text> in the body instead.
cm() {
  local r="$1" s="$2" t="$3" f p; shift 3
  for f in "$@"; do
    p="${f%%=*}"; mkdir -p "$(dirname "$r/$p")"
    printf '%s\n' "${f#*=}" > "$r/$p"; git -C "$r" add -- "$p"
  done
  {
    printf '%s\n' "$s"
    case "$t" in
      BODY:*) printf '\n%s\n' "${t#BODY:}" ;;
      ?*) printf '\n%s\n' "$t" ;;
    esac
  } > "$TMPROOT/msg"
  git -C "$r" commit -q --allow-empty -F "$TMPROOT/msg"
}

# mark <repo> [json]: write and commit the opt-in marker (default {})
mark() {
  local j="${2:-}"; [ -n "$j" ] || j='{}'
  mkdir -p "$1/.claude"; printf '%s\n' "$j" > "$1/.claude/handoff.json"
  git -C "$1" add .claude/handoff.json; git -C "$1" commit -q -m "add handoff marker"
}

sha() { git -C "$1" rev-parse "${2:-HEAD}"; }

# --- running the hooks ----------------------------------------------------------------------

p_ss()   { jq -nc --arg s "$1" --arg c "$2" '{session_id:"t", transcript_path:"t.jsonl", cwd:$c, hook_event_name:"SessionStart", source:$s}' | tr -d '\r'; }
p_cmd()  { jq -nc --arg t "$1" --arg c "$2" --arg d "$3" '{session_id:"t", transcript_path:"t.jsonl", cwd:$d, hook_event_name:"PostToolUse", tool_name:$t, tool_input:{command:$c, description:"x"}, tool_response:{stdout:"", stderr:"", interrupted:false, isImage:false}}' | tr -d '\r'; }
p_edit() { jq -nc --arg t "$1" --arg f "$2" --arg d "$3" '{session_id:"t", transcript_path:"t.jsonl", cwd:$d, hook_event_name:"PostToolUse", tool_name:$t, tool_input:{file_path:$f, old_string:"a", new_string:"b", content:"c"}, tool_response:{filePath:$f}}' | tr -d '\r'; }

RUNS=0; NONZERO=0; STDERR_RUNS=0
# run <hook> <payload>: sets OUT (raw stdout), CTX (additionalContext), EVT (hookEventName)
run() {
  OUT="$(printf '%s' "$2" | bash "$1" 2>"$TMPROOT/err")"; local rc=$?
  RUNS=$((RUNS + 1))
  [ "$rc" = 0 ] || { NONZERO=$((NONZERO + 1)); echo "    (nonzero exit $rc from $(basename "$1"))"; }
  [ -s "$TMPROOT/err" ] && { STDERR_RUNS=$((STDERR_RUNS + 1)); echo "    (stderr from $(basename "$1"): $(head -c 200 "$TMPROOT/err"))"; }
  CTX=""; EVT=""
  if [ -n "$OUT" ]; then
    CTX="$(jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$OUT" 2>/dev/null | tr -d '\r')"
    EVT="$(jq -r '.hookSpecificOutput.hookEventName // empty' <<<"$OUT" 2>/dev/null | tr -d '\r')"
  fi
}
has() { printf '%s' "$CTX" | grep -qF -- "$1"; }
silent() { [ -z "$OUT" ]; }
show() { printf '%s' "$CTX" | head -c 600; }

winpath() { cygpath -w "$1"; }

# A standard opted-in repo: seed, marker, NEXT.md, then a handoff: anchor holding NEXT.md alone.
std_repo() {
  local r; r="$(mkrepo "$1")"
  mark "$r" "${2:-}"
  cm "$r" "handoff: first" "$AGENT" "NEXT.md=# NEXT"
  printf '%s\n' "$r"
}

echo "== handoff-lib.sh =="

[ -f "$LIB" ] && bash -n "$LIB" 2>/dev/null && ok "lib_exists_and_parses" || bad "lib missing or does not parse"

r="$(std_repo lib1)"
mkdir -p "$r/sub dir/deeper"
out="$( . "$LIB"; ho_marker "$r/sub dir/deeper"; echo "rc=$?|$HO_ROOT" )"
[ "$out" = "rc=0|$(cd "$r" && pwd)" ] && ok "ho_marker_finds_the_root_from_a_subdirectory" || bad "ho_marker subdir: $out"
out="$( . "$LIB"; ho_marker "$(winpath "$r/sub dir")"; echo "rc=$?|$(cygpath -w "$HO_ROOT")" )"
[ "$out" = "rc=0|$(winpath "$r")" ] && ok "ho_marker_accepts_a_windows_backslash_path" || bad "ho_marker winpath: $out"
n="$(mkrepo lib-nomark)"
out="$( . "$LIB"; ho_marker "$n"; echo "rc=$?|${HO_ROOT:-}" )"
[ "$out" = "rc=1|" ] && ok "ho_marker_fails_without_the_marker" || bad "ho_marker no marker: $out"
# a marker ABOVE a repo that has none does not count: the walk stops at the first .git
mkdir -p "$FIX/outer/.claude"; echo '{}' > "$FIX/outer/.claude/handoff.json"
git -C "$FIX/outer" init -q 2>/dev/null; inner="$FIX/outer/inner"; mkdir -p "$inner"; git -C "$inner" init -q
out="$( . "$LIB"; ho_marker "$inner"; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_marker_stops_at_the_nearest_repo_root" || bad "ho_marker nested: $out"
mkdir -p "$FIX/plain/.claude"; echo '{}' > "$FIX/plain/.claude/handoff.json"
out="$( . "$LIB"; ho_marker "$FIX/plain"; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_marker_fails_outside_a_git_repo_even_with_a_marker_file" || bad "ho_marker plain dir: $out"
out="$( . "$LIB"; ho_marker "$FIX/does not exist"; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_marker_fails_on_a_missing_directory" || bad "ho_marker missing dir: $out"
out="$( cd "$FIX"; . "$LIB"; ho_marker "$r" >/dev/null; echo "$PWD" )"
[ "$out" = "$(cd "$FIX" && pwd)" ] && ok "ho_marker_leaves_the_callers_cwd_alone" || bad "ho_marker moved cwd to: $out"

# anchor: subject only
a1="$(sha "$r")"
cm "$r" "fix the parser" "BODY:handoff: see NEXT.md for the details"
cm "$r" "Handoff: capitalised is not the anchor" ""
out="$( . "$LIB"; ho_anchor "$r"; echo "rc=$?" )"
[ "$out" = "$a1 handoff: first"$'\n'"rc=0" ] && ok "ho_anchor_is_subject_only_body_line_and_capitalised_subject_ignored" || bad "ho_anchor: $out"
out="$( . "$LIB"; ho_anchor "$n"; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_anchor_none_returns_1_and_prints_nothing" || bad "ho_anchor none: $out"
u="$FIX/unborn"; mkdir -p "$u"; git -C "$u" init -q
out="$( . "$LIB"; ho_anchor "$u"; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_anchor_on_an_unborn_branch_returns_1" || bad "ho_anchor unborn: $out"
# the twin of the ritual's _handoff_anchor must agree with it on the same history
out_r="$( RITUAL_SKILL_DIR="$PLUGIN/skills/project-start"; . "$RITUAL_LIB/common.sh"; . "$RITUAL_LIB/handoff.sh"; _handoff_anchor "$r"; echo "rc=$?" )"
out_h="$( . "$LIB"; ho_anchor "$r"; echo "rc=$?" )"
[ -n "$out_r" ] && [ "$out_r" = "$out_h" ] && ok "ho_anchor_agrees_with_the_ritual_twin" || bad "twins disagree: ritual=[$out_r] hooks=[$out_h]"

# tagging
t="$(std_repo lib-tags)"
cm "$t" "agent generic trailer" "$AGENT"
cm "$t" "agent model trailer" "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
cm "$t" "agent lowercase key" "co-authored-by: Claude <noreply@anthropic.com>"
cm "$t" "chore: auto-commit work in progress" ""
cm "$t" "pair with a person" "Co-Authored-By: Some Person <p@example.com>"
cm "$t" "trailer in the body, not the trailer block" "BODY:Co-Authored-By: Claude <x>"$'\n\n'"closing paragraph"
cm "$t" "plain developer commit" ""
d="$(git -C "$t" log -1 --date=short --format=%ad)"
out="$( . "$LIB"; ho_commits_since "$t" "$(git -C "$t" rev-parse HEAD~7)" )"
exp="[other] $d plain developer commit
[other] $d trailer in the body, not the trailer block
[other] $d pair with a person
[agent] $d chore: auto-commit work in progress
[agent] $d agent lowercase key
[agent] $d agent model trailer
[agent] $d agent generic trailer"
[ "$out" = "$exp" ] && ok "ho_commits_since_tags_each_commit_newest_first" || bad "tags:"$'\n'"$out"
out="$( . "$LIB"; ho_commits_since "$t" "" 3 | wc -l | tr -d ' ' )"
[ "$out" = 3 ] && ok "ho_commits_since_without_anchor_lists_the_last_N" || bad "no-anchor N: $out"

# pending
p="$(std_repo lib-pend)"
out="$( . "$LIB"; ho_pending "$p" "$(sha "$p")"; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_pending_false_with_nothing_after_the_anchor" || bad "pending empty: $out"
cm "$p" "developer tweak" ""
out="$( . "$LIB"; ho_pending "$p" "$(sha "$p" HEAD~1)"; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_pending_false_with_only_other_commits" || bad "pending other: $out"
cm "$p" "agent work" "$AGENT"
out="$( . "$LIB"; ho_pending "$p" "$(sha "$p" HEAD~2)"; echo "rc=$?|$HO_PENDING_N" )"
[ "$out" = "rc=0|1" ] && ok "ho_pending_true_and_counts_agent_commits" || bad "pending agent: $out"
out="$( . "$LIB"; ho_pending "$p" ""; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_pending_false_without_an_anchor" || bad "pending no anchor: $out"

# linked worktree
w="$(std_repo lib-wt)"; wt="$FIX/lib wt linked"
git -C "$w" worktree add -q -b feat "$wt" 2>/dev/null
out="$( . "$LIB"; ho_in_linked_worktree "$wt"; echo "rc=$?" )"
[ "$out" = "rc=0" ] && ok "ho_in_linked_worktree_true_in_a_linked_worktree" || bad "linked: $out"
git -C "$w" checkout -q -b other-branch
out="$( . "$LIB"; ho_in_linked_worktree "$w"; echo "rc=$?" )"
[ "$out" = "rc=1" ] && ok "ho_in_linked_worktree_false_in_the_main_checkout_on_a_feature_branch" || bad "main: $out"

# command scanner
scan() { ( . "$LIB"; ho_scan_command "$1"; printf '%s|%s' "$HO_ACTS" "$HO_CDIR" ); }
chk_scan() { local got; got="$(scan "$1")"; [ "$got" = "$2" ] && ok "scan: $3" || bad "scan $3: [$1] -> [$got], want [$2]"; }
chk_scan 'git push' ' push|' "plain_push"
chk_scan 'git push origin main' ' push|' "push_with_args"
chk_scan 'gh pr create --fill' ' prcreate|' "gh_pr_create"
chk_scan 'git merge --squash feat' ' merge|' "git_merge"
chk_scan 'git commit -m "x"' ' commit|' "commit"
chk_scan 'git add -A && git commit -F m.txt && git push' ' commit push|' "chain_commit_then_push"
chk_scan 'cd sub && git push' ' push|' "after_cd_prefix"
chk_scan $'git status\ngit push' ' push|' "after_newline"
chk_scan 'git status; git push' ' push|' "after_semicolon"
chk_scan 'git log | git push' ' push|' "after_pipe"
chk_scan 'MSYS_NO_PATHCONV=1 git push' ' push|' "env_assignment_prefix"
chk_scan 'git -C "a dir" push' ' push|a dir' "quoted_C_dir_with_space"
chk_scan 'git -C sub -c core.x=y --no-pager push' ' push|sub' "global_options_before_push"
chk_scan 'echo "git push later"' '|' "quoted_mention_is_not_a_command"
chk_scan "echo 'git push later'" '|' "single_quoted_mention_is_not_a_command"
# The quote-lifting cases need a SPACE after the inner word: without lifting, `git push"` already
# fails to match on the closing quote, so a case ending at the quote would pass either way.
chk_scan 'git commit -m "fix; git push origin later"' ' commit|' "push_inside_a_commit_message_is_not_shipping"
chk_scan 'echo "done; git push origin later"' '|' "separator_inside_quotes_is_not_a_command_boundary"
chk_scan 'git log --grep=push' '|' "push_as_an_argument_is_not_shipping"
chk_scan 'git pushy' '|' "a_longer_word_is_not_push"
chk_scan 'mygit push' '|' "a_longer_command_is_not_git"
chk_scan 'gh pr view' '|' "gh_pr_view_is_not_create"
chk_scan '& git push origin main; Write-Host done' ' push|' "powershell_call_operator"

echo "== SessionStart: silence =="

v="$(std_repo ss-silent)"
cm "$v" "agent work" "$AGENT"                  # a violation: agent commit after the anchor
for s in resume clear fork; do
  run "$SS" "$(p_ss "$s" "$v")"
  silent && ok "session_start_${s}_is_silent" || bad "$s spoke: $(show)"
done
run "$SS" "$(jq -nc --arg c "$v" '{session_id:"t", cwd:$c, hook_event_name:"SessionStart"}' | tr -d '\r')"
silent && ok "session_start_without_source_is_silent" || bad "no source spoke"
run "$SS" "$(p_ss startup "$v")"
[ "$EVT" = SessionStart ] && has "ended without a handoff" && ok "control_startup_speaks_with_the_marker" || bad "control startup: $(show)"
nm="$(mkrepo ss-nomark)"; cm "$nm" "handoff: x" "$AGENT"; cm "$nm" "agent" "$AGENT"
run "$SS" "$(p_ss startup "$nm")"; silent && ok "startup_silent_without_marker" || bad "startup no marker: $(show)"
run "$SS" "$(p_ss compact "$nm")"; silent && ok "compact_silent_without_marker" || bad "compact no marker: $(show)"
run "$SS" "$(p_ss startup "$FIX/plain")"; silent && ok "startup_silent_outside_a_repo" || bad "startup plain dir"
run "$SS" "$(p_ss startup "$FIX/does not exist")"; silent && ok "startup_silent_for_a_missing_cwd" || bad "startup missing cwd"
run "$SS" 'not json at all'; silent && ok "startup_silent_on_malformed_input" || bad "startup junk"

echo "== SessionStart: startup =="

# no anchor -> the last 10 commits and PICK
na="$(mkrepo ss-noanchor)"; mark "$na"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do cm "$na" "commit-$i" ""; done
run "$SS" "$(p_ss startup "$(winpath "$na")")"
lst="$(printf '%s\n' "$CTX" | grep -c 'commit-[0-9][0-9]$')"
[ "$EVT" = SessionStart ] && has "PICK" && has "never ask for a SHA" && [ "$lst" = 10 ] \
  && has "commit-12" && has "commit-03" && ! has "commit-02" \
  && ok "startup_no_anchor_lists_the_last_10_and_asks_to_PICK" || bad "no anchor ($lst listed): $(show)"
d="$(git -C "$na" log -1 --date=short --format=%ad)"
has "$d commit-12" && ok "startup_no_anchor_listing_has_date_and_subject" || bad "no anchor listing format"
has "\"$DEFAULT_ASK\"" && has "Feedback log" && ok "startup_asks_the_default_question_and_names_the_feedback_log" || bad "default ask: $(show)"
has "End of session" && ok "startup_no_anchor_still_states_the_end_of_session_duty" || bad "no duty line (no anchor)"
! has "ended without a handoff" && ! has "Uncommitted" && ok "startup_no_anchor_does_not_claim_a_missed_handoff" || bad "no-anchor extras"

# anchor + [other] + auto-commit chore + uncommitted file
s1="$(std_repo ss-mixed '{"ask":"Did the new build run well?"}')"
a="$(sha "$s1")"
cm "$s1" "developer tuning" "" "tune.cfg=x=1"
cm "$s1" "chore: auto-commit work in progress" "" "wip.txt=w"
echo dirty > "$s1/scratch-notes.txt"
run "$SS" "$(p_ss startup "$s1")"
d="$(git -C "$s1" log -1 --date=short --format=%ad)"
has "\"Did the new build run well?\"" && ! has "$DEFAULT_ASK" && ok "startup_uses_the_marker_ask" || bad "custom ask: $(show)"
has "[other] $d developer tuning" && has "[agent] $d chore: auto-commit work in progress" \
  && ok "startup_lists_commits_since_the_anchor_tagged" || bad "tagged listing: $(show)"
has "?? scratch-notes.txt" && ok "startup_lists_uncommitted_changes" || bad "uncommitted: $(show)"
has "${a:0:12}" && has "handoff: first" && ok "startup_names_the_anchor" || bad "anchor not named"
has "ended without a handoff" && ok "startup_auto_commit_after_anchor_counts_as_a_missed_handoff" || bad "auto-commit not pending"
! has "PICK" && ok "startup_with_anchor_does_not_ask_to_pick" || bad "PICK with anchor"
! has "--since" && ok "startup_output_never_contains_since" || bad "--since in output"
has "End of session" && has "handoff:" && ok "startup_states_the_end_of_session_duty" || bad "no duty line"

# only [other] commits after the anchor -> no missed-handoff claim
s2="$(std_repo ss-other)"; cm "$s2" "developer only" ""
run "$SS" "$(p_ss startup "$s2")"
has "[other]" && ! has "ended without a handoff" && ok "startup_other_commits_only_is_not_a_missed_handoff" || bad "other-only: $(show)"
# nothing since the anchor
s3="$(std_repo ss-clean)"
run "$SS" "$(p_ss startup "$s3")"
[ "$EVT" = SessionStart ] && has "(none)" && ! has "ended without a handoff" && ok "startup_clean_anchor_shows_none" || bad "clean anchor: $(show)"

# agent commit after the anchor -> missed handoff, naming the range
s4="$(std_repo ss-missed)"; a4="$(sha "$s4")"; cm "$s4" "agent feature" "$AGENT"
run "$SS" "$(p_ss startup "$s4")"
has "ended without a handoff" && has "git log ${a4:0:12}..HEAD" && ok "startup_missed_handoff_names_the_reconstruct_range" || bad "missed: $(show)"

# paths diff: includes an uncommitted change; excludes non-matching paths
s5="$(mkrepo ss-paths)"; mark "$s5" '{"paths":["*.dat","levels/*.map"]}'
cm "$s5" "content" "" "a.dat=old-a" "levels/l1.map=old-l1" "code.rs=old-code"
cm "$s5" "handoff: first" "$AGENT" "NEXT.md=# NEXT"
echo "UNCOMMITTED-EDIT" > "$s5/a.dat"
cm "$s5" "level tweak" "" "levels/l1.map=COMMITTED-EDIT"
echo "CODE-EDIT" > "$s5/code.rs"
run "$SS" "$(p_ss startup "$s5")"
has "+UNCOMMITTED-EDIT" && has "+COMMITTED-EDIT" && ok "startup_paths_diff_shows_committed_and_uncommitted" || bad "paths diff: $(show)"
! has "+CODE-EDIT" && ok "startup_paths_diff_excludes_other_paths" || bad "paths diff leaked code.rs"
# no paths key -> no diff section
# (run in this shell, not in $(...), and require the hook to have spoken: a crashed hook prints
# nothing, which would otherwise pass this negative check)
run "$SS" "$(p_ss startup "$s1")"
[ "$EVT" = SessionStart ] && has "End of session" && ! has "Diff of" \
  && ok "startup_without_paths_has_no_diff_section" || bad "diff section without paths"

# diff cap: 200 lines, "+N more"
s6="$(mkrepo ss-cap)"; mark "$s6" '{"paths":["data/*.txt"]}'
cm "$s6" "handoff: first" "$AGENT" "NEXT.md=# NEXT"
mkdir -p "$s6/data"; seq 1 300 | sed 's/^/line/' > "$s6/data/big.txt"; git -C "$s6" add data/big.txt
total="$(git -C "$s6" diff "$(sha "$s6")" -- 'data/*.txt' | wc -l | tr -d ' ')"
run "$SS" "$(p_ss startup "$s6")"
shown="$(printf '%s\n' "$CTX" | grep -c '^+line')"
has "+$((total - 200)) more lines" && [ "$shown" -le 200 ] && [ "$shown" -ge 190 ] \
  && ok "startup_paths_diff_capped_at_200_lines_with_more_note" || bad "cap: total=$total shown=$shown $(printf '%s' "$CTX" | tail -n 3)"
# char budget: long lines keep the whole context under the 10,000-character cap
s7="$(mkrepo ss-chars)"; mark "$s7" '{"paths":["data/*.txt"]}'
cm "$s7" "handoff: first" "$AGENT" "NEXT.md=# NEXT"
mkdir -p "$s7/data"; for i in $(seq 1 300); do printf 'L%03d %0120d\n' "$i" 0; done > "$s7/data/wide.txt"; git -C "$s7" add data/wide.txt
run "$SS" "$(p_ss startup "$s7")"
[ "${#CTX}" -lt 10000 ] && has "more lines" && has "End of session" && ok "startup_context_stays_under_10000_chars" || bad "chars=${#CTX}"
# commit listing cap
s8="$(std_repo ss-many)"
for i in $(seq 1 25); do cm "$s8" "dev-$i" ""; done
run "$SS" "$(p_ss startup "$s8")"
c="$(printf '%s\n' "$CTX" | grep -c '^  \[other\]')"
[ "$c" = 20 ] && has "+5 more" && ok "startup_commit_listing_capped_at_20" || bad "listing cap: $c"
# total line budget outside the diff
[ "$(printf '%s\n' "$CTX" | wc -l)" -le 60 ] && ok "startup_listing_context_within_60_lines" || bad "lines: $(printf '%s\n' "$CTX" | wc -l)"
# malformed marker -> defaults, and says so
s9="$(std_repo ss-badmarker)"; printf 'not json\n' > "$s9/.claude/handoff.json"
run "$SS" "$(p_ss startup "$s9")"
has "\"$DEFAULT_ASK\"" && has "could not read .claude/handoff.json" && ok "startup_malformed_marker_uses_defaults_and_says_so" || bad "bad marker: $(show)"
# linked worktree: the duty line says hand off after the merge
sw="$(std_repo ss-wt)"; swt="$FIX/ss wt linked"; git -C "$sw" worktree add -q -b feat "$swt" 2>/dev/null
run "$SS" "$(p_ss startup "$swt")"
has "after the merge, in the main checkout" && ok "startup_in_linked_worktree_says_hand_off_after_the_merge" || bad "startup wt: $(show)"

echo "== SessionStart: compact =="

c1="$(std_repo cp-pending)"; cm "$c1" "agent work" "$AGENT"
run "$SS" "$(p_ss compact "$c1")"
[ "$EVT" = SessionStart ] && has "HANDOFF PENDING" && has "1 agent commit" && ! has "ended without a handoff" && ! has "Ask the developer" \
  && ok "compact_pending_gives_the_reminder_only" || bad "compact pending: $(show)"
c2="$(std_repo cp-clean)"; cm "$c2" "developer only" ""
run "$SS" "$(p_ss compact "$c2")"; silent && ok "compact_not_pending_is_silent" || bad "compact not pending: $(show)"
c3="$(mkrepo cp-noanchor)"; mark "$c3"; cm "$c3" "agent" "$AGENT"
run "$SS" "$(p_ss compact "$c3")"; silent && ok "compact_without_anchor_is_silent" || bad "compact no anchor: $(show)"
c4="$(std_repo cp-wt)"; c4t="$FIX/cp wt linked"; git -C "$c4" worktree add -q -b feat "$c4t" 2>/dev/null
cm "$c4t" "agent in worktree" "$AGENT"
run "$SS" "$(p_ss compact "$c4t")"
has "HANDOFF PENDING" && has "hand off after the merge, in the main checkout" && ok "compact_in_linked_worktree_uses_after_merge_wording" || bad "compact wt: $(show)"

echo "== PostToolUse: handoff: commit holding other files =="

k="$(std_repo pt-commit)"
cm "$k" "handoff: session notes" "$AGENT" "NEXT.md=# NEXT v2" "src/extra.rs=x"
run "$PT" "$(p_cmd Bash 'git add -A && git commit -m "handoff: session notes"' "$k")"
[ "$EVT" = PostToolUse ] && has "src/extra.rs" && ! has "touched: NEXT.md" && ok "commit_warning_names_the_extra_path" || bad "commit warn: $(show)"
run "$PT" "$(p_cmd PowerShell 'git commit -F msg.txt' "$(winpath "$k")")"
has "src/extra.rs" && ok "commit_warning_via_powershell_payload" || bad "ps commit warn: $(show)"
run "$PT" "$(p_cmd Bash "git -C \"$k\" commit -F m" "$FIX")"
has "src/extra.rs" && ok "commit_warning_resolves_the_repo_from_dash_C" || bad "-C commit: $(show)"
cm "$k" "handoff: notes only" "$AGENT" "NEXT.md=# NEXT v3"
run "$PT" "$(p_cmd Bash 'git commit -m x' "$k")"; silent && ok "commit_next_md_alone_is_silent" || bad "NEXT alone spoke: $(show)"
# the auto-commit sweep case: NEXT.md already committed, so the anchor is an EMPTY handoff: commit
cm "$k" "handoff: empty anchor" "$AGENT"
ef="$(git -C "$k" show --name-only --format= HEAD)"
run "$PT" "$(p_cmd Bash 'git commit --allow-empty -F m' "$k")"
[ -z "$ef" ] && silent && ok "commit_empty_handoff_is_silent" || bad "empty handoff spoke (files: [$ef]): $(show)"
cm "$k" "feature work" "$AGENT" "a.rs=1" "b.rs=2"
run "$PT" "$(p_cmd Bash 'git commit -m x' "$k")"; silent && ok "commit_non_handoff_is_silent" || bad "non-handoff spoke: $(show)"
cm "$k" "handoff: with a nested NEXT.md" "$AGENT" "docs/NEXT.md=x"
run "$PT" "$(p_cmd Bash 'git commit -m x' "$k")"; has "docs/NEXT.md" && ok "commit_only_the_root_next_md_counts" || bad "nested NEXT: $(show)"
km="$(mkrepo pt-commit-nomark)"; cm "$km" "handoff: x" "$AGENT" "NEXT.md=a" "other.txt=b"
run "$PT" "$(p_cmd Bash 'git commit -m x' "$km")"; silent && ok "commit_silent_without_marker" || bad "commit no marker spoke"

echo "== PostToolUse: shipping =="

sp="$(std_repo pt-ship)"; cm "$sp" "agent work" "$AGENT"
run "$PT" "$(p_cmd Bash 'git push -u origin main' "$sp")"
[ "$EVT" = PostToolUse ] && has "hand off now" && has "commit it alone" && has "squash merge must also start with" \
  && ok "push_with_pending_agent_commits_reminds" || bad "push: $(show)"
run "$PT" "$(p_cmd Bash 'gh pr create --fill' "$sp")"; has "hand off now" && ok "gh_pr_create_reminds" || bad "gh pr create: $(show)"
run "$PT" "$(p_cmd Bash 'git merge --squash feat' "$sp")"; has "hand off now" && ok "git_merge_reminds" || bad "merge: $(show)"
run "$PT" "$(p_cmd PowerShell 'git push origin main; Write-Host done' "$(winpath "$sp")")"; has "hand off now" && ok "powershell_push_reminds" || bad "ps push: $(show)"
run "$PT" "$(p_cmd Bash 'cd sub && git push' "$sp")"; has "hand off now" && ok "push_after_cd_prefix_reminds" || bad "cd push: $(show)"
run "$PT" "$(p_cmd Bash "git -C \"$sp\" push" "$FIX")"; has "hand off now" && ok "push_resolves_quoted_dash_C_dir_with_space" || bad "-C push: $(show)"
run "$PT" "$(p_cmd Bash "git -C pt-ship push" "$FIX")"; has "hand off now" && ok "push_resolves_relative_dash_C_against_cwd" || bad "rel -C push: $(show)"
run "$PT" "$(p_cmd Bash 'echo "git push later"' "$sp")"; silent && ok "quoted_mention_of_push_is_silent" || bad "echo push spoke"
run "$PT" "$(p_cmd Bash 'git commit -m "wip; git push origin later"' "$sp")"; silent && ok "push_inside_commit_message_is_silent" || bad "msg push spoke: $(show)"
run "$PT" "$(p_cmd Bash 'git status' "$sp")"; silent && ok "unrelated_git_command_is_silent" || bad "git status spoke"
run "$PT" "$(jq -nc --arg d "$sp" '{cwd:$d, hook_event_name:"PostToolUse", tool_name:"Read", tool_input:{command:"git push", file_path:"x"}}' | tr -d '\r')"
silent && ok "other_tool_names_are_silent" || bad "Read tool spoke"
cm "$sp" "handoff: fresh" "$AGENT" "NEXT.md=# NEXT fresh"
run "$PT" "$(p_cmd Bash 'git push' "$sp")"; silent && ok "push_after_fresh_handoff_is_silent" || bad "post-handoff push spoke: $(show)"
so="$(std_repo pt-ship-other)"; cm "$so" "developer only" ""
run "$PT" "$(p_cmd Bash 'git push' "$so")"; silent && ok "push_with_only_other_commits_is_silent" || bad "other push spoke"
sn="$(mkrepo pt-ship-noanchor)"; mark "$sn"; cm "$sn" "agent" "$AGENT"
run "$PT" "$(p_cmd Bash 'git push' "$sn")"; silent && ok "push_without_anchor_is_silent" || bad "no-anchor push spoke"
sx="$(mkrepo pt-ship-nomark)"; cm "$sx" "handoff: x" "$AGENT"; cm "$sx" "agent" "$AGENT"
run "$PT" "$(p_cmd Bash 'git push' "$sx")"; silent && ok "push_silent_without_marker" || bad "push no marker spoke"
run "$PT" "$(p_cmd Bash 'git push' "$FIX/plain")"; silent && ok "push_silent_outside_a_repo" || bad "push plain spoke"
sw2="$(std_repo pt-ship-wt)"; swt2="$FIX/ship wt linked"; git -C "$sw2" worktree add -q -b feat "$swt2" 2>/dev/null
cm "$swt2" "agent in worktree" "$AGENT"
run "$PT" "$(p_cmd Bash 'git push -u origin feat' "$swt2")"
has "after the merge, in the main checkout" && ! has "hand off now" && ok "push_in_linked_worktree_uses_after_merge_wording" || bad "wt push: $(show)"
# commit and push in one command: both checks run
cb="$(std_repo pt-both)"; cm "$cb" "agent work" "$AGENT"; cm "$cb" "handoff: wide" "$AGENT" "NEXT.md=n" "x.txt=x"
run "$PT" "$(p_cmd Bash 'git commit -m "handoff: wide" && git push' "$cb")"
has "x.txt" && ok "commit_and_push_together_runs_the_commit_check" || bad "both: $(show)"
run "$PT" 'not json'; silent && ok "post_tool_silent_on_malformed_input" || bad "post junk spoke"

echo "== PostToolUse: NEXT.md edits =="

e="$(std_repo pt-edit)"; et="$FIX/edit wt linked"; git -C "$e" worktree add -q -b feat "$et" 2>/dev/null
for tool in Edit Write MultiEdit; do
  run "$PT" "$(p_edit "$tool" "$(winpath "$et/NEXT.md")" "$(winpath "$et")")"
  [ "$EVT" = PostToolUse ] && has "linked worktree" && has "after the merge, in the main checkout" \
    && ok "next_md_${tool}_in_linked_worktree_warns" || bad "$tool wt: $(show)"
done
run "$PT" "$(p_edit Edit "$et/NEXT.md" "$e")"; has "linked worktree" && ok "next_md_edit_warns_with_posix_path_and_other_cwd" || bad "posix wt: $(show)"
git -C "$e" checkout -q -b feature-in-main
run "$PT" "$(p_edit Edit "$(winpath "$e/NEXT.md")" "$(winpath "$e")")"; silent && ok "next_md_edit_in_main_checkout_on_feature_branch_is_silent" || bad "main edit spoke: $(show)"
mkdir -p "$et/docs"
run "$PT" "$(p_edit Edit "$et/docs/NEXT.md" "$et")"; silent && ok "nested_next_md_in_worktree_is_silent" || bad "nested spoke"
run "$PT" "$(p_edit Edit "$et/README.md" "$et")"; silent && ok "other_file_in_worktree_is_silent" || bad "README spoke"
en="$(mkrepo pt-edit-nomark)"; ent="$FIX/edit nomark wt"; git -C "$en" worktree add -q -b feat "$ent" 2>/dev/null
run "$PT" "$(p_edit Edit "$ent/NEXT.md" "$ent")"; silent && ok "next_md_edit_silent_without_marker" || bad "no-marker edit spoke"

echo "== hooks.json registration =="

HJ="$HOOKS/hooks.json"
jq -e . "$HJ" >/dev/null 2>&1 && ok "hooks_json_is_valid" || bad "hooks.json invalid"
q() { jq -r "$1" "$HJ" 2>/dev/null | tr -d '\r'; }
[ "$(q '[.hooks.SessionStart[] | select(.matcher=="startup|compact") | .hooks[] | .command] | join(",")')" = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/handoff-session-start.sh"' ] \
  && ok "session_start_registered_with_startup_compact_matcher" || bad "SessionStart entry"
[ "$(q '[.hooks.PostToolUse[] | select(.matcher=="Bash|PowerShell") | .hooks[] | .command | select(test("handoff"))] | join(",")')" = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/handoff-post-tool.sh"' ] \
  && ok "post_tool_registered_for_bash_powershell" || bad "PostToolUse Bash|PowerShell entry"
[ "$(q '[.hooks.PostToolUse[] | select(.matcher=="Edit|Write|MultiEdit") | .hooks[] | .command] | join(",")')" = 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/handoff-post-tool.sh"' ] \
  && ok "post_tool_registered_for_edit_write_multiedit" || bad "PostToolUse Edit entry"
[ "$(q '[.hooks[][] | .hooks[] | select(.command | test("handoff")) | .timeout] | map(select(. > 10)) | length')" = 0 ] \
  && [ "$(q '[.hooks[][] | .hooks[] | select(.command | test("handoff"))] | length')" = 3 ] \
  && ok "handoff_hooks_three_entries_timeouts_at_most_10s" || bad "timeouts/count"
[ "$(q '[(.hooks.Stop // [])[], (.hooks.UserPromptSubmit // [])[] | .hooks[] | select(.command | test("handoff"))] | length')" = 0 ] \
  && ok "no_stop_or_user_prompt_submit_handoff_hook" || bad "Stop/UPS handoff hook present"
kept=""
for h in hydrate-memory auto-commit sync-memory redteam-gate negative-result-guard job-state-nudge windows-guard; do
  [ "$(q "[.hooks[][] | .hooks[] | select(.command | test(\"/$h.sh\"))] | length")" = 1 ] || kept="$kept $h"
done
[ -z "$kept" ] && ok "existing_hook_entries_each_still_present_once" || bad "existing entries changed:$kept"
[ "$(q '[.hooks[][] | .hooks[]] | length')" = 10 ] && ok "existing_entries_kept_total_10_commands" || bad "command count: $(q '[.hooks[][] | .hooks[]] | length')"

echo "== SKILL.md =="

# Case-insensitive matching goes through tr: GNU grep 3.0 under Git Bash aborts (exit 134) on
# ANY `grep -iF`, even `printf abc | grep -qiF b`, which would fail these checks for no reason.
lc() { tr '[:upper:]' '[:lower:]'; }
if [ -f "$SKILL" ]; then
  fm="$(sed -n '1,/^---$/{p}' "$SKILL" | sed -n '2,/^---$/p')"
  printf '%s' "$fm" | grep -qx 'name: handoff' && ok "skill_frontmatter_name" || bad "skill name"
  desc="$(printf '%s' "$fm" | grep '^description:')"
  miss=""
  for trig in 'handoff' 'NEXT.md' 'end of session' 'hand off'; do
    printf '%s' "$desc" | lc | grep -qF -- "$(printf '%s' "$trig" | lc)" || miss="$miss [$trig]"
  done
  [ -n "$desc" ] && [ -z "$miss" ] && ok "skill_description_carries_the_triggers" || bad "description lacks:$miss"
  body() { lc < "$SKILL" | grep -qF -- "$(printf '%s' "$1" | lc)"; }
  body "\"$DEFAULT_ASK\"" && ok "skill_default_question_matches_the_hooks" || bad "skill default question"
  grep -qF "\"$DEFAULT_ASK\"" "$PLUGIN/skills/project-start/house/session-routine.md" && \
    [ "$( . "$LIB"; printf '%s' "$HO_DEFAULT_ASK")" = "$DEFAULT_ASK" ] && ok "default_question_same_in_routine_lib_and_skill" || bad "default question drift"
  body "same turn" && body "--allow-empty" && ok "skill_auto_commit_sweep_rule" || bad "skill lacks same-turn / --allow-empty rule"
  body "squash" && ok "skill_squash_rule" || bad "skill squash rule"
  body "linked worktree" && body "main checkout" && ok "skill_worktree_rule" || bad "skill worktree rule"
  body "--grep" && body "--since" && body "PICK" && ok "skill_carries_the_paid_lessons" || bad "skill lessons"
  body '"ask"' && body '"paths"' && body ".claude/handoff.json" && ok "skill_names_the_marker_keys" || bad "skill marker keys"
  body "fix handoff" && body "handoff-commit" && ok "skill_names_the_ritual_opt_in" || bad "skill opt-in"
  body "same step id" && body "silently overwrite" && ok "skill_records_the_shared_step_id_deliberately" || bad "skill shared step id rule"
  body "$AGENT" && ok "skill_gives_the_generic_trailer" || bad "skill trailer"
  [ "$(tr -cd '\r' < "$SKILL" | wc -c | tr -d ' ')" = 0 ] && ok "skill_is_lf" || bad "skill has CR"
else
  bad "SKILL.md missing"
fi

echo "== hygiene =="

lfbad=""
for f in "$LIB" "$SS" "$PT" "$0"; do
  [ -f "$f" ] && [ "$(tr -cd '\r' < "$f" | wc -c | tr -d ' ')" = 0 ] || lfbad="$lfbad $(basename "$f")"
done
[ -z "$lfbad" ] && ok "hook_files_present_and_lf" || bad "missing or CR in:$lfbad"
[ "$NONZERO" = 0 ] && [ "$RUNS" -gt 50 ] && ok "every_hook_run_exited_0 ($RUNS runs)" || bad "nonzero exits: $NONZERO of $RUNS"
[ "$STDERR_RUNS" = 0 ] && ok "no_hook_run_wrote_stderr" || bad "stderr in $STDERR_RUNS runs"

echo
echo "test-handoff-hooks.sh: $pass PASS, $fail FAIL"
[ $((pass + fail)) -gt 0 ] || { echo "no assertions ran"; exit 1; }
[ "$fail" -eq 0 ] || exit 1
exit 0
