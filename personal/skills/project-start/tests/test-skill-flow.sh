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

finish
