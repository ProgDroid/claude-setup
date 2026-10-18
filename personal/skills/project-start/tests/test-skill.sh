#!/usr/bin/env bash
# SKILL.md against the script it drives: frontmatter, flow order, every step id, every invoked
# subcommand and flag, the status -> record-result table, and the release surface.
. "$(dirname "$0")/lib.sh"
SKILL="$SKILL_DIR/SKILL.md"
STEPS="$SKILL_DIR/steps.json"
PLUGIN_ROOT="$(cd "$SKILL_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$PLUGIN_ROOT/.." && pwd)"

if [ ! -f "$SKILL" ]; then
  bad "skill_md_exists: $SKILL missing"
  finish
fi
ok "skill_md_exists"

# frontmatter: the lines between the opening '---' and the next one, CRs stripped
FM="$(tr -d '\r' < "$SKILL" | awk 'NR == 1 { if ($0 == "---") { f = 1; next } else exit } f && $0 == "---" { exit } f')"
fm_val() { printf '%s\n' "$FM" | sed -n "s/^$1:[[:space:]]*//p" | head -n 1; }
BODY="$(tr -d '\r' < "$SKILL" | awk 'NR == 1 && $0 == "---" { f = 1; next } f == 1 && $0 == "---" { f = 2; next } f == 2')"
# lower-cased copy for case-blind matches: grep.exe core-dumps on -iF here
LBODY="${BODY,,}"
# ...and one line with runs of whitespace squeezed, so a phrase wrapped across lines still matches
FLAT="$(tr '\n' ' ' <<<"$LBODY" | tr -s ' ')"

echo "== frontmatter =="
[ "$(fm_val name)" = project-start ] && ok "frontmatter_name_is_project_start" || bad "frontmatter_name_is_project_start: name: '$(fm_val name)'"

sv="$(fm_val ritual_version)"; jv="$(jq -r .ritual_version "$STEPS" | tr -d '\r')"
[[ "$sv" =~ ^[0-9]+$ ]] && [ "$sv" = "$jv" ] && ok "frontmatter_version_matches_steps_json" \
  || bad "frontmatter_version_matches_steps_json: ritual_version: SKILL.md '$sv' vs steps.json '$jv'"

desc="$(fm_val description)"; miss=""
for t in "project start" "set up this project" "onboard this repo" "run the ritual" \
         "Project-start ritual not done/behind here"; do
  [[ "$desc" == *"$t"* ]] || miss="$miss [$t]"
done
[ -n "$desc" ] && [ -z "$miss" ] && ok "description_has_every_trigger" || bad "description_has_every_trigger: description lacks:$miss"

echo "== steps =="
miss=""; n=0
while IFS= read -r id; do
  n=$((n + 1))
  # backticked, so a common word (stack, commit, record) in prose cannot satisfy it
  grep -qF -- "\`$id\`" <<<"$BODY" || miss="$miss $id"
done < <(jq -r '.steps[].id' "$STEPS" | tr -d '\r')
[ "$n" -gt 0 ] && [ -z "$miss" ] && ok "every_step_id_mentioned_in_skill" || bad "every_step_id_mentioned_in_skill: ids missing (of $n):$miss"

# the auto section (### 3.) names every step ritual.sh's AUTO_STEPS runs, parking-lot included
auto_ids="$(sed -n 's/^AUTO_STEPS=(\(.*\))$/\1/p' "$RITUAL")"
sec3="$(awk '/^### 3\./ { f = 1; next } /^### / { f = 0 } f' <<<"$BODY")"
miss=""
for id in $auto_ids; do grep -qF -- "\`$id\`" <<<"$sec3" || miss="$miss $id"; done
[ -n "$auto_ids" ] && [ -n "$sec3" ] && [ -z "$miss" ] && ok "auto_section_names_every_auto_step" \
  || bad "auto_section_names_every_auto_step: auto ids [$auto_ids] section3 lines $(wc -l <<<"$sec3"), missing:$miss"

# the batched asks (### 5.) cover every ask-kind step except the up-front beads and the commit ask
sec5="$(awk '/^### 5\./ { f = 1; next } /^### / { f = 0 } f' <<<"$BODY")"
miss=""; n=0
while IFS= read -r id; do
  n=$((n + 1)); grep -qF -- "\`$id\`" <<<"$sec5" || miss="$miss $id"
done < <(jq -r '.steps[] | select(.kind == "ask" and .id != "beads" and .id != "commit") | .id' "$STEPS" | tr -d '\r')
[ "$n" -gt 0 ] && [ -n "$sec5" ] && [ -z "$miss" ] && ok "batched_asks_cover_every_ask_step" \
  || bad "batched_asks_cover_every_ask_step: batched asks missing (of $n):$miss"

echo "== flow =="
# the first occurrence of each invocation, in the brief's order
prev=0; order_ok=1; trace=""
for m in '"$R" preflight' '"$R" due' '"$R" fix beads' '"$R" auto' 'qmd search' \
         '"$R" commit-plan' '"$R" handoff-commit' '"$R" record-write'; do
  ln="$(grep -nF -- "$m" <<<"$BODY" | head -n 1 | cut -d: -f1)"
  trace="$trace [$m@${ln:-none}]"
  if [ -z "$ln" ] || [ "$ln" -le "$prev" ]; then order_ok=0; else prev="$ln"; fi
done
[ "$order_ok" = 1 ] && ok "flow_in_order" || bad "flow_in_order: flow order:$trace"

# the scripted ritual commit comes after commit-plan and before handoff-commit (R32, R57)
cp_ln="$(grep -nF -- '"$R" commit-plan' <<<"$BODY" | head -n 1 | cut -d: -f1)"
gc_ln="$(grep -nF -- '"$R" commit "$REPO"' <<<"$BODY" | head -n 1 | cut -d: -f1)"
hc_ln="$(grep -nF -- '"$R" handoff-commit' <<<"$BODY" | head -n 1 | cut -d: -f1)"
[ -n "$cp_ln" ] && [ -n "$gc_ln" ] && [ -n "$hc_ln" ] && [ "$cp_ln" -lt "$gc_ln" ] && [ "$gc_ln" -lt "$hc_ln" ] \
  && ok "ritual_commit_between_commit_plan_and_handoff_commit" || bad "ritual_commit_between_commit_plan_and_handoff_commit: commit-plan@$cp_ln commit@$gc_ln handoff-commit@$hc_ln"
# the hand recipe that re-tracked an ignored file is gone (R57)
! grep -qE 'git (-C "\$REPO" )?add -- <paths>|git (-C "\$REPO" )?commit -F "\$RT/msg" -- ' <<<"$BODY" \
  && ok "no_hand_commit_recipe" || bad "no_hand_commit_recipe: SKILL.md still commits by hand"

grep -qF -- '"$R" fix beads "$REPO" --stash' <<<"$BODY" && ok "beads_ask_offers_stash" || bad "beads_ask_offers_stash: no --stash form of fix beads"

grep -qF 'qmd search' <<<"$BODY" && ok "lessons_use_qmd_search" || bad "lessons_use_qmd_search: no qmd search"
[ -s "$SKILL" ] && ! grep -qF 'qmd query' "$SKILL" && ok "no_qmd_query" || bad "no_qmd_query: SKILL.md mentions qmd query"

grep -qF 'No step that the script can answer is answered by the model' <<<"$BODY" \
  && ok "states_the_script_answers_rule" || bad "states_the_script_answers_rule: the script-answers rule is not stated"

echo "== invocations exist =="
# every "$R" <sub> [<step>] the skill runs is a subcommand the dispatcher accepts; check/fix name a
# function that exists
subs="$(sed -n 's/^  \*) die "unknown subcommand: .*(\(.*\))" ;;$/\1/p' "$RITUAL" | tr '|' ' ')"
inv="$(grep -oE '"\$R" [a-z-]+( [a-z-]+)?' <<<"$BODY" | sort -u)"
miss=""; n=0
while IFS= read -r l; do
  [ -n "$l" ] || continue
  n=$((n + 1)); set -- $l; sub="$2"; step="${3:-}"
  [[ " $subs " == *" $sub "* ]] || { miss="$miss [$l: no subcommand]"; continue; }
  case "$sub" in
    check|fix) [ -n "$step" ] && grep -qE "^${sub}_${step//-/_}\(\)" "$SKILL_DIR"/lib/*.sh \
                 || miss="$miss [$l: no ${sub}_${step//-/_}]" ;;
  esac
done <<<"$inv"
[ -n "$subs" ] && [ "$n" -ge 10 ] && [ -z "$miss" ] && ok "every_invoked_subcommand_exists" \
  || bad "every_invoked_subcommand_exists: subs [$subs] invocations $n:$miss"

# every --flag on a line that runs "$R" is a case arm in the script
flags="$(grep -F -- '"$R"' <<<"$BODY" | grep -oE -- '--[a-z][a-z-]*' | sort -u)"
miss=""; n=0
for f in $flags; do
  n=$((n + 1)); grep -qE -- "(^|[[:space:]|(])${f}\)" "$RITUAL" "$SKILL_DIR"/lib/*.sh || miss="$miss $f"
done
[ "$n" -ge 1 ] && [ -z "$miss" ] && ok "every_invoked_flag_exists" || bad "every_invoked_flag_exists: flags [$flags] missing:$miss"

echo "== status -> record result =="
# rows of a markdown table: | <script status> | <step> | <record result> | ...
rows="$(grep -E '^\|' <<<"$BODY")"
has_row() { # <status cell needle> <step cell needle or ""> <result>
  awk -F'|' -v s="$1" -v st="$2" -v r="\`$3\`" \
    'index($2, s) && (st == "" || index($3, st)) && index($4, r) { found = 1 } END { exit !found }' <<<"$rows"
}
miss=""
for p in 'fixed||done' 'already||already' 'present||already' 'unknown||unknown' 'failed||failed' \
         'absent|`oracle`|none' 'absent|`ci`|na' 'declin||declined'; do
  IFS='|' read -r s st r <<<"$p"
  [ "$s" = declin ] || s="\`$s\`"
  has_row "$s" "$st" "$r" || miss="$miss [$p]"
done
[ -n "$rows" ] && [ -z "$miss" ] && ok "mapping_table_present" || bad "mapping_table_present: mapping rows missing:$miss"

has_row '`absent`' '`public-sweep`' na && ok "mapping_public_sweep_private_is_na" || bad "mapping_public_sweep_private_is_na: no public-sweep absent -> na row"
has_row '`absent`' '`untracked-docs`' already && ok "mapping_untracked_docs_none_is_already" || bad "mapping_untracked_docs_none_is_already: no untracked-docs absent -> already row"
has_row '`absent`' '`stack`' none && ok "mapping_stack_absent_is_none" || bad "mapping_stack_absent_is_none: no stack absent -> none row"

# a crashed auto step: the skill quotes the script's own detail and calls it a ritual bug
crash="$(grep -oF 'step ended without a result' "$RITUAL" | head -n 1)"
[ -n "$crash" ] && grep -qF "$crash" <<<"$BODY" && grep -qF 'ritual bug' <<<"$LBODY" \
  && ok "crashed_step_is_surfaced_as_a_ritual_bug" || bad "crashed_step_is_surfaced_as_a_ritual_bug: crash detail '$crash' / ritual bug not in SKILL.md"

echo "== handoff outcomes =="
grep -qF 'git fetch --unshallow' "$SKILL_DIR/lib/handoff.sh" && grep -qF 'git fetch --unshallow' <<<"$BODY" \
  && ok "shallow_clone_offers_unshallow" || bad "shallow_clone_offers_unshallow: unshallow offer missing"
grep -qF 'main checkout' "$SKILL_DIR/lib/handoff.sh" && grep -qF 'run it from the main checkout' <<<"$BODY" \
  && ok "linked_worktree_says_main_checkout" || bad "linked_worktree_says_main_checkout: main-checkout instruction missing"
grep -qF 'how did the last change go?' <<<"$FLAT" && grep -qF 'pick-list' <<<"$FLAT" \
  && grep -qF 'chore: auto-commit' <<<"$FLAT" \
  && ok "handoff_ask_is_recognition" || bad "handoff_ask_is_recognition: default question / pick-list / auto-commit exclusion missing"
# R56: handoff-commit runs only after a fix that succeeded, in both skills; its outcome then goes
# in the note (the executed form of this rule is test-skill-flow.sh)
HFLAT="$(tr -d '\r' < "$SKILL_DIR/../handoff/SKILL.md" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ' | tr -s ' ')"
grep -qF 'only when `fix handoff` returned `fixed` or `already`' <<<"$FLAT" \
  && grep -qF 'only after `fix handoff` returned `fixed` or `already`' <<<"$HFLAT" \
  && grep -qE 'handoff-commit.{0,40} (outcome|status|result).{0,40}note' <<<"$FLAT" \
  && ok "handoff_commit_runs_only_after_fix_success" \
  || bad "handoff_commit_runs_only_after_fix_success: the R56 condition is missing from project-start or handoff SKILL.md"
# I2: step 7 takes the block's printed status only when the block ran `fix handoff`
grep -qF 'when the block ran `fix handoff`' <<<"$FLAT" && ok "step_7_qualifies_the_printed_handoff_status" \
  || bad "step_7_qualifies_the_printed_handoff_status: no 'when the block ran \`fix handoff\`'"
# N4: a present check's no-flag fix is recorded by its own status, never an unconditional `already`
grep -qF 'record its status by the mapping table' <<<"$FLAT" && ! grep -qF 'record the step `already`.' <<<"$FLAT" \
  && ok "present_check_fix_is_recorded_by_its_status" || bad "present_check_fix_is_recorded_by_its_status: R58 paragraph still records an unconditional already"

echo "== re-runs =="
# I1: step 6's ask covers what an earlier, uncommitted run set up
grep -qF 'files set up by an earlier run that was not committed' <<<"$FLAT" && ok "commit_ask_covers_an_earlier_uncommitted_run" \
  || bad "commit_ask_covers_an_earlier_uncommitted_run: step 6 does not name them"
# M2: the issues beads-seed created ride the ritual commit (bd stages nothing itself)
sec5b="$(awk '/^- \*\*`beads-seed`\*\*/ { f = 1 } f && /^- \*\*`ci`\*\*/ { exit } f' <<<"$BODY")"
grep -qF '.beads/issues.jsonl' <<<"$sec5b" && grep -qF 'model.json' <<<"$sec5b" && grep -qF 'bd create' <<<"$sec5b" \
  && ok "beads_seed_commits_issues_jsonl" || bad "beads_seed_commits_issues_jsonl: bullet: $sec5b"

echo "== secret-scan =="
grep -qE 'before (you run|running).{0,40}check secret-scan|check secret-scan.{0,120}(tell|warn) the user' <<<"$LBODY" \
  && ok "secret_scan_proof_is_announced" || bad "secret_scan_proof_is_announced: no announcement before the live proof"

echo "== public repo =="
# drive-letter or home paths and e-mail addresses; private names are scanned outside the repo
leaks="$(grep -nE '(^|[^A-Za-z])[A-Za-z]:[\\/]|/Users/|/home/|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}' "$SKILL" || true)"
[ -z "$leaks" ] && ok "no_paths_or_emails" || bad "no_paths_or_emails: paths/emails: $leaks"

echo "== release surface =="
pv="$(jq -r .version "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null | tr -d '\r')"
mv="$(jq -r '.plugins[] | select(.name == "personal") | .version' "$REPO_ROOT/.claude-plugin/marketplace.json" 2>/dev/null | tr -d '\r')"
[[ "$pv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && [ "$pv" = "$mv" ] && ok "plugin_and_marketplace_versions_agree" \
  || bad "plugin_and_marketplace_versions_agree: plugin.json '$pv' vs marketplace '$mv'"
for s in project-start handoff; do
  grep -qF "\`personal/skills/$s/\`" "$REPO_ROOT/README.md" && ok "readme_row_$s" || bad "readme_row_$s: README has no row for personal/skills/$s/"
done

finish
