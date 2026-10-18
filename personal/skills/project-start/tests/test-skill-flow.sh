#!/usr/bin/env bash
# SKILL.md's own command blocks, executed. The step-6 blocks (commit-plan, the scripted commit, the
# handoff-commit decision) are cut out of SKILL.md and run as written, on fixture repos with bd, gh,
# gitleaks and cargo stubbed, so a rule that exists only as prose in SKILL.md is tested by running it.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
SKILL="$SKILL_DIR/SKILL.md"

# --- stubs. bd is test-beads.sh's model of bd 1.2.2, cut from that suite so the two never drift.
STUBDIR="$TMPROOT/flow stubs"; LOG="$TMPROOT/flow tools.log"; mkdir -p "$STUBDIR"; : > "$LOG"
awk '/^cat > "\$STUBDIR\/bd" <<'"'"'STUB'"'"'$/ { f = 1; next } f && /^STUB$/ { exit } f' "$TESTS_DIR/test-beads.sh" > "$STUBDIR/bd"
printf '#!/usr/bin/env bash\nprintf "gh %%s\\n" "$*" >> "${STUB_BD_LOG:?}"; echo PRIVATE\n' > "$STUBDIR/gh"
cat > "$STUBDIR/gitleaks" <<'STUB'
#!/usr/bin/env bash
printf 'gitleaks %s\n' "$*" >> "${STUB_BD_LOG:?}"
if git diff --cached | grep -qE 'AKIA[A-Z2-7]{16}'; then echo "WRN leaks found: 1" >&2; exit 1; fi
exit 0
STUB
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUBDIR/cargo"
chmod +x "$STUBDIR"/*
grep -q '"init "' "$STUBDIR/bd" && [ "$(wc -l < "$STUBDIR/bd")" -gt 20 ] && ok "bd_stub_cut_from_test_beads" \
  || bad "bd_stub_cut_from_test_beads: $(wc -l < "$STUBDIR/bd") lines"

# S <ritual args...>: ritual.sh with every tool stubbed
S() { ( stub_path "$STUBDIR"; export STUB_BD_LOG="$LOG"; bash "$RITUAL" "$@" ); }
jr() { printf '%s' "$1" | jq -r "$2" | tr -d '\r'; }

# snippet <needle> -> the first ```bash block of SKILL.md that contains <needle>
snippet() {
  tr -d '\r' < "$SKILL" | awk -v n="$1" '
    /^```bash[[:space:]]*$/ { inb = 1; buf = ""; next }
    inb && /^```[[:space:]]*$/ { inb = 0; if (index(buf, n)) { printf "%s", buf; found = 1; exit } next }
    inb { buf = buf $0 "\n" }
    END { exit !found }'
}
# run_snippet <needle> <repo> <rt>: run that block as written, with R, REPO and RT set
run_snippet() {
  local code; code="$(snippet "$1")" || { echo "NO SNIPPET: $1"; return 99; }
  ( stub_path "$STUBDIR"; export STUB_BD_LOG="$LOG" R="$RITUAL" REPO="$2" RT="$3"; bash -c "$code" )
}
newrt() { local d; d="$(mktemp -d "$TMPROOT/rt XXXXXX")"; mkdir -p "$d/out" "$d/chk"; printf '%s' "$d"; }

miss=""
for n in '"$R" commit-plan' '"$R" commit "$REPO"' '"$R" handoff-commit'; do
  snippet "$n" >/dev/null || miss="$miss [$n]"
done
[ -z "$miss" ] && ok "snippets_found_in_skill_md" || bad "snippets_found_in_skill_md: no block holds$miss"

echo "== R57: beads accepted, then the scripted ritual commit =="
r="$(mkrepo "flow beads")"; RT1="$(newrt)"
S preflight "$r" > "$RT1/preflight.json"
S fix beads "$r" > "$RT1/out/beads.json"
S auto "$r" > "$RT1/out/auto.json"
S fix handoff "$r" > "$RT1/out/handoff.json"
pre_tracked="$(git -C "$r" ls-tree -r --name-only HEAD -- .beads/interactions.jsonl | tr -d '\r')"
[ "$(jq -r .status "$RT1/out/beads.json" | tr -d '\r')" = fixed ] && [ "$(jq -r .status "$RT1/out/handoff.json" | tr -d '\r')" = fixed ] \
  && [ -n "$pre_tracked" ] && jq -e '.wrote | index(".beads/interactions.jsonl")' "$RT1/out/beads.json" >/dev/null \
  && ok "beads_fixture_premise_interactions_tracked_and_in_wrote" \
  || bad "beads_fixture_premise_interactions_tracked_and_in_wrote: beads=$(cat "$RT1/out/beads.json") in-HEAD=[$pre_tracked]"
run_snippet '"$R" commit-plan' "$r" "$RT1" > "$RT1/plan.out" 2>&1
out="$(run_snippet '"$R" commit "$REPO"' "$r" "$RT1" 2>&1)"; rc=$?
cst="$(jq -r .status "$RT1/commit.json" 2>/dev/null | tr -d '\r')"
[ "$rc" = 0 ] && [ "$cst" = fixed ] && [ "$(git -C "$r" log -1 --format=%s | tr -d '\r')" = 'chore: project-start ritual' ] \
  && ok "skill_commit_block_commits" || bad "skill_commit_block_commits: rc=$rc status=$cst out=$out plan=$(cat "$RT1/plan.out")"
[ -z "$(git -C "$r" ls-tree -r --name-only HEAD -- .beads/interactions.jsonl)" ] \
  && [ -z "$(git -C "$r" ls-files -- .beads/interactions.jsonl)" ] && [ -f "$r/.beads/interactions.jsonl" ] \
  && ok "skill_commit_keeps_interactions_untracked" \
  || bad "skill_commit_keeps_interactions_untracked: tree=[$(git -C "$r" ls-tree -r --name-only HEAD -- .beads/interactions.jsonl)] index=[$(git -C "$r" ls-files -- .beads/interactions.jsonl)]"
[ "$(jr "$(S check beads "$r")" .status)" = present ] && ok "skill_commit_leaves_beads_set_up" \
  || bad "skill_commit_leaves_beads_set_up: $(S check beads "$r")"
[ "$(git -C "$r" status --porcelain | tr -d '\r')" = '?? NEXT.md' ] && ok "skill_commit_leaves_only_next_md" \
  || bad "skill_commit_leaves_only_next_md: $(git -C "$r" status --porcelain | paste -sd'|' -)"
out="$(run_snippet '"$R" handoff-commit' "$r" "$RT1" 2>&1)"
[ "$(jq -r .status "$RT1/handoff-commit.json" 2>/dev/null | tr -d '\r')" = fixed ] && [[ "$out" == *"handoff status to record: fixed"* ]] \
  && [ "$(git -C "$r" show --name-only --format= HEAD | tr -d '\r')" = NEXT.md ] \
  && ok "skill_handoff_block_commits_after_a_fixed_fix" || bad "skill_handoff_block_commits_after_a_fixed_fix: $out"

echo "== R56: a linked worktree keeps the handoff step open =="
m="$(mkrepo "flow main")"; wt="$TMPROOT/ritual fixtures/flow linked wt"
git -C "$m" worktree add -q -b feature "$wt" >/dev/null 2>&1
RT2="$(newrt)"
S fix handoff "$wt" > "$RT2/out/handoff.json"
[ "$(jq -r .status "$RT2/out/handoff.json" | tr -d '\r')" = unknown ] && [ ! -e "$wt/NEXT.md" ] \
  && ok "linked_worktree_fix_handoff_is_unknown" || bad "linked_worktree_fix_handoff_is_unknown: $(cat "$RT2/out/handoff.json")"
h0="$(git -C "$wt" rev-parse HEAD | tr -d '\r')"
out="$(run_snippet '"$R" handoff-commit' "$wt" "$RT2" 2>&1)"
hs="$(printf '%s\n' "$out" | sed -n 's/^handoff status to record: //p' | tr -d '\r')"
[ ! -e "$RT2/handoff-commit.json" ] && [ "$hs" = unknown ] && [ "$(git -C "$wt" rev-parse HEAD | tr -d '\r')" = "$h0" ] \
  && ok "skill_handoff_block_skips_handoff_commit_after_unknown" \
  || bad "skill_handoff_block_skips_handoff_commit_after_unknown: hs=[$hs] ran=$([ -e "$RT2/handoff-commit.json" ] && cat "$RT2/handoff-commit.json")"
# record the status the block printed, mapped by SKILL.md's table (unknown -> unknown)
jq -n --arg r "$hs" '{steps: {handoff: {result: $r, note: "linked worktree"}}}' > "$RT2/results.json"
rec="$(S record-write "$wt" "$RT2/results.json")"
[ "$(jr "$rec" '.open_steps | tostring')" = '["handoff"]' ] && ok "linked_worktree_handoff_stays_in_open_steps" \
  || bad "linked_worktree_handoff_stays_in_open_steps: $rec"
# control: had handoff-commit run, its refusal would have closed the step
ctl="$(S handoff-commit "$wt")"
[ "$(jr "$ctl" .status)" = failed ] && ok "control_handoff_commit_in_a_worktree_is_failed" \
  || bad "control_handoff_commit_in_a_worktree_is_failed: $ctl"

echo "== I2: the handoff block when fix handoff did not run =="
NOTRUN="not run here: record check handoff or the user's answer by the mapping table"
# agent_hs <printed> <by-the-table>: what step 7 records: the printed status when the block ran
# fix handoff, else check handoff's status or the user's answer, mapped by the table
agent_hs() { case "$1" in "not run here"*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
# case A: the user declined the handoff ask, so there is no out/handoff.json
d="$(mkrepo "flow declined")"; RT3="$(newrt)"; h0="$(git -C "$d" rev-parse HEAD | tr -d '\r')"
out="$(run_snippet '"$R" handoff-commit' "$d" "$RT3" 2>&1)"
hs="$(printf '%s\n' "$out" | sed -n 's/^handoff status to record: //p' | tr -d '\r')"
[ "$hs" = "$NOTRUN" ] && [ ! -e "$RT3/handoff-commit.json" ] && [ "$(git -C "$d" rev-parse HEAD | tr -d '\r')" = "$h0" ] \
  && ok "handoff_block_without_a_fix_says_not_run_here" || bad "handoff_block_without_a_fix_says_not_run_here: [$hs]"
jq -n --arg r "$(agent_hs "$hs" declined)" '{steps: {handoff: {result: $r, note: "user declined"}}}' > "$RT3/results.json"
S record-write "$d" "$RT3/results.json" >/dev/null
due="$(S due "$d")"
[ "$(jr "$(S record-read "$d")" .steps.handoff.result)" = declined ] && [ "$(jr "$due" '[.skip[].id] | index("handoff") != null')" = true ] \
  && [ "$(jr "$due" '.offer | index("handoff") == null')" = true ] \
  && ok "declined_handoff_is_recorded_declined_and_the_next_due_skips_it" || bad "declined handoff: record=$(S record-read "$d") due=$due"
# case B: check handoff already says present, so no fix ran
p="$(mkrepo "flow present")"; S fix handoff "$p" >/dev/null
git -C "$p" add CLAUDE.md .claude/handoff.json; git -C "$p" commit -q -m setup; S handoff-commit "$p" >/dev/null
RT4="$(newrt)"; S check handoff "$p" > "$RT4/chk/handoff.json"; h1="$(git -C "$p" rev-parse HEAD | tr -d '\r')"
out="$(run_snippet '"$R" handoff-commit' "$p" "$RT4" 2>&1)"
hs="$(printf '%s\n' "$out" | sed -n 's/^handoff status to record: //p' | tr -d '\r')"
cst="$(jq -r .status "$RT4/chk/handoff.json" | tr -d '\r')"
[ "$cst" = present ] && [ "$hs" = "$NOTRUN" ] && [ "$(git -C "$p" rev-parse HEAD | tr -d '\r')" = "$h1" ] \
  && ok "handoff_block_with_check_present_says_not_run_here" || bad "handoff_block_with_check_present_says_not_run_here: check=$cst [$hs]"
jq -n --arg r "$(agent_hs "$hs" "$([ "$cst" = present ] && echo already)")" '{steps: {handoff: {result: $r}}}' > "$RT4/results.json"
S record-write "$p" "$RT4/results.json" >/dev/null
[ "$(jr "$(S record-read "$p")" .steps.handoff.result)" = already ] && ok "handoff_check_present_is_recorded_already" \
  || bad "handoff_check_present_is_recorded_already: $(S record-read "$p")"

echo "== I1: an interrupted run's setup is committed by the next run =="
i="$(mkrepo "flow interrupted")"; RT5="$(newrt)"
S preflight "$i" > "$RT5/preflight.json"; S auto "$i" > "$RT5/out/auto.json"; S fix handoff "$i" > "$RT5/out/handoff.json"
# run 1 stops here, before step 6: the marker, CLAUDE.md and docs/parking-lot.md are only on disk
RT6="$(newrt)"
S preflight "$i" > "$RT6/preflight.json"; S auto "$i" > "$RT6/out/auto.json"; S fix handoff "$i" > "$RT6/out/handoff.json"
pl="$(jq -c '.results[] | select(.id == "parking-lot")' "$RT6/out/auto.json" | tr -d '\r')"
[ "$(jr "$pl" .status)" = already ] && [ "$(jr "$pl" '.wrote | sort | tostring')" = '["CLAUDE.md","docs/parking-lot.md"]' ] \
  && [[ "$(jr "$pl" .detail)" == *"not yet committed"* ]] \
  && ok "rerun_auto_parking_lot_is_already_and_lists_its_uncommitted_files" || bad "rerun parking-lot: $pl"
ho="$(cat "$RT6/out/handoff.json")"
[ "$(jr "$ho" .status)" = already ] && [ "$(jr "$ho" '.wrote | sort | tostring')" = '[".claude/handoff.json","CLAUDE.md"]' ] \
  && ok "rerun_fix_handoff_is_already_and_lists_its_uncommitted_files" || bad "rerun fix handoff: $ho"
run_snippet '"$R" commit-plan' "$i" "$RT6" > "$RT6/plan.out" 2>&1
miss=""
for f in .claude/handoff.json CLAUDE.md docs/parking-lot.md; do
  jq -e --arg f "$f" '.ask | index($f)' "$RT6/plan.json" >/dev/null || miss="$miss $f"
done
[ -z "$miss" ] && [ "$(jq '.commit | length' "$RT6/plan.json" | tr -d '\r')" = 0 ] \
  && ok "commit_plan_routes_the_leftovers_to_ask" || bad "commit_plan_routes_the_leftovers_to_ask: missing [$miss] plan=$(cat "$RT6/plan.json")"
mapfile -t A < <(jq -r '.ask[]' "$RT6/plan.json" | tr -d '\r')   # the user confirmed every ask path
printf 'chore: project-start ritual\n' > "$RT6/msg"
c="$(S commit "$i" --preflight "$RT6/preflight.json" --message-file "$RT6/msg" --include-dirty -- "${A[@]}")"
[ "$(jr "$c" .status)" = fixed ] && [ -n "$(git -C "$i" ls-files -- .claude/handoff.json)" ] && [ -n "$(git -C "$i" ls-files -- docs/parking-lot.md)" ] \
  && [ "$(git -C "$i" status --porcelain | tr -d '\r')" = '?? NEXT.md' ] \
  && ok "include_dirty_commits_what_the_earlier_run_left" || bad "include_dirty_commits_what_the_earlier_run_left: $c / $(git -C "$i" status --porcelain | paste -sd'|' -)"
out="$(run_snippet '"$R" handoff-commit' "$i" "$RT6" 2>&1)"
# run 2's fix was `already`, so that is the step's result; handoff-commit's `fixed` goes in its note
[[ "$out" == *"handoff status to record: already"* ]] && [ "$(jq -r .status "$RT6/handoff-commit.json" | tr -d '\r')" = fixed ] \
  && [ -z "$(git -C "$i" status --porcelain | tr -d '\r')" ] \
  && ok "the_rerun_ends_with_everything_committed" || bad "the_rerun_ends_with_everything_committed: $out / $(git -C "$i" status --porcelain | paste -sd'|' -)"
# control: on the fully committed repo, already lists nothing and the plan is empty
RT7="$(newrt)"
S preflight "$i" > "$RT7/preflight.json"; S auto "$i" > "$RT7/out/auto.json"; S fix handoff "$i" > "$RT7/out/handoff.json"
run_snippet '"$R" commit-plan' "$i" "$RT7" > "$RT7/plan.out" 2>&1
[ "$(jq -c '.wrote' "$RT7/out/auto.json" | tr -d '\r')" = '[]' ] && [ "$(jq -c '[.status, .wrote]' "$RT7/out/handoff.json" | tr -d '\r')" = '["already",[]]' ] \
  && [ "$(jq -c . "$RT7/plan.json" | tr -d '\r')" = '{"commit":[],"ask":[]}' ] \
  && ok "control_a_committed_repo_lists_nothing" || bad "control_a_committed_repo_lists_nothing: auto=$(jq -c .wrote "$RT7/out/auto.json") handoff=$(cat "$RT7/out/handoff.json") plan=$(cat "$RT7/plan.json")"

echo "== R58: a declined commit, then a present check whose no-flag fix lists the leftovers =="
k="$(mkrepo "flow declined commit")"; RK1="$(newrt)"
S preflight "$k" > "$RK1/preflight.json"; S auto "$k" > "$RK1/out/auto.json"; S fix handoff "$k" > "$RK1/out/handoff.json"
# run 1 stops before step 6. Run 2 lists the leftovers, the user DECLINES the commit, and the handoff
# block still makes the anchor (the fix was `already`), so run 3's check handoff says `present`
RK2="$(newrt)"
S preflight "$k" > "$RK2/preflight.json"; S auto "$k" > "$RK2/out/auto.json"; S fix handoff "$k" > "$RK2/out/handoff.json"
run_snippet '"$R" commit-plan' "$k" "$RK2" > "$RK2/plan.out" 2>&1
jq -e '.ask | index(".claude/handoff.json")' "$RK2/plan.json" >/dev/null && ok "r58_run_2_lists_the_marker" || bad "r58_run_2_lists_the_marker: $(cat "$RK2/plan.json")"
run_snippet '"$R" handoff-commit' "$k" "$RK2" > "$RK2/hc.out" 2>&1
jq -n '{steps: {commit: {result: "declined"}, handoff: {result: "already"}}}' > "$RK2/results.json"
S record-write "$k" "$RK2/results.json" >/dev/null
[ -z "$(git -C "$k" ls-files -- .claude/handoff.json)" ] && [ -n "$(git -C "$k" ls-files -- NEXT.md)" ] \
  && ok "r58_premise_marker_uncommitted_and_the_anchor_made" || bad "r58 premise: $(git -C "$k" status --porcelain | paste -sd'|' -) $(cat "$RK2/hc.out")"
# run 3: due re-offers the commit (I3); check handoff is present; the step-5 block runs its no-flag fix
RK3="$(newrt)"
S preflight "$k" > "$RK3/preflight.json"; S auto "$k" > "$RK3/out/auto.json"
due="$(S due "$k")"; S check handoff "$k" > "$RK3/chk/handoff.json"
[ "$(jr "$due" '.offer | index("commit") != null')" = true ] && [ "$(jq -r .status "$RK3/chk/handoff.json" | tr -d '\r')" = present ] \
  && ok "r58_run_3_offers_the_commit_and_check_handoff_is_present" || bad "r58 run 3: due=$due check=$(cat "$RK3/chk/handoff.json")"
run_snippet 'pr handoff &&' "$k" "$RK3" > "$RK3/r58.out" 2>&1
ho="$(cat "$RK3/out/handoff.json" 2>/dev/null)"
[ "$(jr "$ho" .status)" = already ] && jr "$ho" '.wrote | index(".claude/handoff.json") != null' | grep -qx true \
  && ok "r58_present_check_gets_its_no_flag_fix_which_lists_the_marker" || bad "r58 no-flag fix: [$ho] $(cat "$RK3/r58.out")"
run_snippet '"$R" commit-plan' "$k" "$RK3" > "$RK3/plan.out" 2>&1
jq -e '.ask | index(".claude/handoff.json")' "$RK3/plan.json" >/dev/null \
  && ok "r58_the_re_offered_commit_offers_the_marker" || bad "r58 run 3 plan: $(cat "$RK3/plan.json" 2>/dev/null)"

echo "== N1: the R58 block's beads and secret-scan lines =="
# beads set up by an earlier run and never committed; this run's check says present
b="$(mkrepo "flow beads leftovers")"; S fix beads "$b" > /dev/null
RB="$(newrt)"; S check beads "$b" > "$RB/chk/beads.json"
run_snippet 'pr handoff &&' "$b" "$RB" > "$RB/r58.out" 2>&1
ob="$(cat "$RB/out/beads.json" 2>/dev/null)"
[ "$(jq -r .status "$RB/chk/beads.json" | tr -d '\r')" = present ] && [ "$(jr "$ob" .status)" = already ] \
  && [ "$(jr "$ob" '.wrote | index(".beads/PRIME.md") != null')" = true ] && [ "$(jr "$ob" '.wrote | index("CLAUDE.md") != null')" = true ] \
  && ok "n1_pr_beads_runs_fix_beads_on_present_and_lists_its_leftovers" || bad "n1 beads: [$ob] $(cat "$RB/r58.out")"
# a secret-scan block in a custom hooks path inside the work tree, never committed; check present
s="$(mkrepo "flow secret leftovers")"; git -C "$s" config core.hooksPath "tools/git hooks"; S fix secret-scan "$s" > /dev/null
RS="$(newrt)"; S check secret-scan "$s" > "$RS/chk/secret-scan.json"
n0="$(grep -c '^gitleaks ' "$LOG")"
run_snippet 'pr handoff &&' "$s" "$RS" > "$RS/r58.out" 2>&1
os="$(cat "$RS/out/secret-scan.json" 2>/dev/null)"
[ "$(jq -r .status "$RS/chk/secret-scan.json" | tr -d '\r')" = present ] && [ "$(jr "$os" .status)" = already ] \
  && [ "$(jr "$os" '.wrote | tostring')" = '["tools/git hooks/pre-commit"]' ] \
  && ok "n1_pr_secret_scan_runs_its_fix_on_present_and_lists_the_hook" || bad "n1 secret-scan: [$os] $(cat "$RS/r58.out")"
# R59: that fix reuses this run's proof: no second gitleaks run
[ -n "$os" ] && [ "$(grep -c '^gitleaks ' "$LOG")" = "$n0" ] && [ "$n0" -ge 1 ] \
  && ok "r59_the_block_reuses_this_runs_proof" || bad "r59: gitleaks calls before $n0, after $(grep -c '^gitleaks ' "$LOG"); [$os]"

finish
