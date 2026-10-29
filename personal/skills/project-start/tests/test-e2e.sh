#!/usr/bin/env bash
# End-to-end tests: `ritual.sh auto` (the scripted auto steps) and whole-ritual properties on fixture
# repos: fresh, fully set up, nested-workspace, no-tools environment and a spaced relative path.
# Every external tool the ritual calls (bd, gh, gitleaks, cargo) is a stub here. Anything that can
# reach one, including a git commit through a hook the ritual installed, runs inside S() or N().
# A logging shadow of each tool sits first on this suite's own PATH, so a call that escapes them is
# caught rather than reaching the real tool (no_test_reached_an_unstubbed_tool).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTO_IDS='["stack","traps","stack-checks","oracle","parking-lot","beads-metrics"]'
CHECK_IDS='beads beads-metrics ci handoff parking-lot public-sweep secret-scan stack-checks traps untracked-docs'
TOOL_IDS='beads beads-metrics public-sweep secret-scan'   # the steps that need bd, gh or gitleaks
KEY_LINE='all = { level = "warn", priority = -1 }'        # a line of the include's clippy table

# --- stubs (make_tool_stubs, tests/lib.sh). Each logs its argv, so a test can prove which tools a run touched.
make_tool_stubs "$TMPROOT"
# shadows: first on this suite's PATH, so an unstubbed call logs here instead of running the real tool
SHADOW="$TMPROOT/shadow tools"; SHADOW_LOG="$TMPROOT/shadow calls.log"; mkdir -p "$SHADOW"
for t in bd gh gitleaks cargo; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" %q "$*" >> %q\nexit 0\n' "$t" "$SHADOW_LOG" > "$SHADOW/$t"
  chmod +x "$SHADOW/$t"
done
PATH="$SHADOW:$PATH"; export PATH
gitleaks shadow-control >/dev/null 2>&1
[ "$(cat "$SHADOW_LOG" 2>/dev/null)" = 'gitleaks shadow-control' ] && ok "shadow_control_an_unstubbed_call_is_logged" \
  || bad "shadow control: [$(cat "$SHADOW_LOG" 2>/dev/null)]"
: > "$SHADOW_LOG"

NOTOOLS="$(PATH="$(path_without bd)"; PATH="$(path_without gh)"; PATH="$(path_without gitleaks)"; printf '%s' "$PATH")"
# S = every tool stubbed; N = no bd, gh or gitleaks by any route (cargo stays stubbed in both)
S() { tool_run bash "$RITUAL" "$@"; }
N() { ( PATH="$CARGO_STUB:$NOTOOLS"; LOCALAPPDATA="$(cygpath -w "$EMPTY_LA")"
        export PATH LOCALAPPDATA E2E_LOGS="$LOGS" RITUAL_RUST_INCLUDE="$INC"; bash "$RITUAL" "$@" ); }
# SC <cmd...>: any other command in the stub environment (a git commit runs the installed hooks)
SC() { tool_run "$@"; }

logclear() { rm -f "$LOGS"/*; }
logof() { if [ -f "$LOGS/$1" ]; then tr -d '\r' < "$LOGS/$1"; fi; }
j() { printf '%s' "$1" | jq -c "$2" | tr -d '\r'; }
jr() { printf '%s' "$1" | jq -r "$2" | tr -d '\r'; }
# res <auto-output> <id> <field> -> that step result's field (raw)
res() { printf '%s' "$1" | jq -r --arg i "$2" ".results[] | select(.id == \$i) | .$3" | tr -d '\r'; }
st() { jr "$1" .status; }
# tree_sums <repo> -> sha256 of every work-tree file (outside .git), sorted: raw bytes, no filters
tree_sums() { (cd "$1" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum); }
crate() {   # crate <dir> <name>: a single-crate root with one #[test]
  mkdir -p "$1/src"
  printf '[package]\nname = "%s"\nversion = "0.1.0"\nedition = "2021"\n' "$2" > "$1/Cargo.toml"
  printf '#[test]\nfn it_works() {}\n' > "$1/src/lib.rs"
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }

# fresh_fixture -> a committed single-crate repo: no traps, no parking lot, no clippy table
fresh_fixture() { local r; r="$(mkrepo "${1:-fresh}")"; crate "$r" demo; commit_all "$r" 'crate'; printf '%s\n' "$r"; }

# full_fixture -> a repo with every scriptable step set up, committed and clean. The house beads
# state is laid down by hand (the beads step has its own suite); everything else is set up by the
# ritual itself, with stubbed tools.
full_fixture() {
  local r; r="$(fresh_fixture full)"
  mkdir -p "$r/.beads/hooks" "$r/.github/workflows"
  printf '%s\n' 'export.auto: true' 'export.git-add: true' 'no-push: true' 'dolt.local-only: true' > "$r/.beads/config.yaml"
  printf '#!/usr/bin/env sh\nexit 0\n' > "$r/.beads/hooks/pre-commit"; chmod +x "$r/.beads/hooks/pre-commit"
  cp "$SKILL_DIR/house/beads/check-block.sh" "$r/.beads/check-block.sh"
  tr -d '\r' < "$SKILL_DIR/house/beads/gitattributes" | grep -v -e '^[[:space:]]*$' -e '^#' > "$r/.gitattributes"
  printf '%s\n' '# Project' '' '<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:fixture -->' \
    '## Beads Issue Tracker' '' '- Use `bd` for durable task tracking.' '<!-- END BEADS INTEGRATION -->' '' \
    '## Task tracking vs. execution structure' '' 'TodoWrite is a different layer.' > "$r/CLAUDE.md"
  printf 'on: push\njobs:\n  test:\n    runs-on: ubuntu-latest\n    steps:\n      - run: cargo test\n' > "$r/.github/workflows/ci.yml"
  git -C "$r" config core.hooksPath .beads/hooks
  commit_all "$r" 'house beads, ci'
  S auto "$r" >/dev/null
  S fix secret-scan "$r" >/dev/null
  S fix handoff "$r" >/dev/null
  SC commit_all "$r" 'chore: ritual setup'   # the pre-commit hook now runs gitleaks
  S handoff-commit "$r" >/dev/null
  printf '%s\n' "$r"
}

# to_record <auto-output> <checks-json-lines-file> <preflight-exit> -> {"steps":{...}} for every
# steps.json id, mapped as the skill maps them: fixed->done, already/present->already,
# unknown->unknown, failed->failed, oracle absent->none, ci absent with no oracle->na,
# public-sweep absent->na, untracked-docs absent->already, stack absent->none, any other
# absent (an ask the skill would not take)->declined. lessons is model-run (done); record is this
# write (done); preflight is done when it ran; asks with no script are declined.
to_record() {
  { printf '%s\n' "$1"; cat "$2"; } | jq -sc --slurpfile reg "$SKILL_DIR/steps.json" --arg pf "$3" '
    (.[0].results | map({key: .id, value: .status}) | from_entries) as $auto
    | (.[1:] | map({key: .id, value: .status}) | from_entries) as $chk
    | ($auto.oracle // "absent") as $or
    | def m($id; $s):
        if $s == "fixed" then "done"
        elif $s == "already" or $s == "present" then "already"
        elif $s == "unknown" or $s == "failed" then $s
        elif $s == "absent" and $id == "oracle" then "none"
        elif $s == "absent" and $id == "ci" and $or != "present" then "na"
        elif $s == "absent" and $id == "public-sweep" then "na"
        elif $s == "absent" and $id == "untracked-docs" then "already"
        elif $s == "absent" and $id == "stack" then "none"
        elif $s == "absent" then "declined"
        else "unmapped:" + $s end;
    {steps: ($reg[0].steps | map(.id as $id | .kind as $k | {key: $id, value: {result: (
        if $auto[$id] then m($id; $auto[$id])
        elif $chk[$id] then m($id; $chk[$id])
        elif $id == "preflight" then (if $pf == "0" then "done" else "unknown" end)
        elif $id == "lessons" or $id == "record" then "done"
        elif $k == "ask" then "declined"
        else "unmapped:no-result" end)}}) | from_entries)}'
}

echo "== to_record follows SKILL.md's table =="
printf '%s\n' '{"id":"public-sweep","status":"absent"}' '{"id":"untracked-docs","status":"absent"}' '{"id":"ci","status":"absent"}' > "$TMPROOT/m4 checks.jsonl"
m4="$(to_record '{"results":[{"id":"stack","status":"absent"},{"id":"oracle","status":"present"}]}' "$TMPROOT/m4 checks.jsonl" 0)"
[ "$(printf '%s' "$m4" | jq -c '[.steps["public-sweep","untracked-docs","stack","ci"].result]' | tr -d '\r')" = '["na","already","none","declined"]' ] \
  && ok "to_record_maps_public_sweep_untracked_docs_and_stack_absent_like_the_skill" || bad "to_record rows: $m4"

echo "== usage =="
out="$(bash "$RITUAL" auto 2>&1)"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"usage: auto <repo>"* ]] && ok "auto_without_repo_is_usage_exit_2" || bad "no repo: rc=$rc out=$out"
mkdir -p "$TMPROOT/not a repo"
out="$(bash "$RITUAL" auto "$TMPROOT/not a repo" 2>&1)"; rc=$?
[ "$rc" = 2 ] && [[ "$out" == *"not a git repository"* ]] && [ -z "$(ls -A "$TMPROOT/not a repo")" ] \
  && ok "auto_outside_a_repo_is_exit_2_and_writes_nothing" || bad "not a repo: rc=$rc out=$out"

echo "== fresh repo =="
r="$(fresh_fixture)"; h0="$(git -C "$r" rev-parse HEAD)"
logclear
TRACE="$TMPROOT/detect trace.log"; : > "$TRACE"
out="$(RITUAL_TRACE="$TRACE" S auto "$r")"; rc=$?
tcount() { if [ -f "$TRACE" ]; then grep -cx "$1" "$TRACE"; else echo 0; fi; }
[ "$rc" = 0 ] && [ "$(j "$out" 'keys')" = '["results","wrote"]' ] && ok "auto_prints_one_object_results_and_wrote_exit_0" || bad "shape: rc=$rc $out"
[ "$(j "$out" '[.results[].id]')" = "$AUTO_IDS" ] && ok "auto_runs_exactly_the_six_scripted_steps" || bad "ids: $(j "$out" '[.results[].id]')"
[ "$(jq -c '[.steps[].id | select(IN("stack","traps","stack-checks","oracle","parking-lot","beads-metrics"))]' "$SKILL_DIR/steps.json" | tr -d '\r')" = "$AUTO_IDS" ] \
  && ok "auto_order_is_steps_json_order" || bad "steps.json order differs from $AUTO_IDS"
[ "$(j "$out" '[.results[] | (keys - ["output"]) == ["detail","id","status","wrote"] and (.wrote | type) == "array" and (.detail | type) == "string"] | all')" = true ] \
  && ok "every_result_is_a_step_result" || bad "result shape: $out"
[ "$(st "$(bash "$RITUAL" check traps "$r")")" = present ] && ok "fresh_repo: traps present after auto" || bad "traps after auto: $(bash "$RITUAL" check traps "$r")"
[ "$(st "$(bash "$RITUAL" check parking-lot "$r")")" = present ] && ok "fresh_repo_parking_lot_present_after_auto" || bad "parking after auto"
[ "$(st "$(S check stack-checks "$r")")" = present ] && tr -d '\r' < "$r/Cargo.toml" | grep -qxF "$KEY_LINE" \
  && ok "fresh_repo_canonical_clippy_table_appended" || bad "stack-checks after auto: $(S check stack-checks "$r")"
[ "$(res "$out" traps status)|$(res "$out" stack-checks status)|$(res "$out" parking-lot status)" = 'fixed|fixed|fixed' ] \
  && ok "fresh_repo_fix_steps_report_fixed" || bad "fix statuses: $out"
[ "$(j "$out" .wrote)" = '[".gitattributes",".gitignore","Cargo.toml","docs/parking-lot.md","CLAUDE.md"]' ] \
  && ok "fresh_repo_wrote_lists_every_written_path_in_step_order" || bad "wrote: $(j "$out" .wrote)"
[ "$(j "$out" .wrote)" = "$(j "$out" '[.results[].wrote[]] | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)')" ] \
  && [ "$(j "$out" '.wrote | length')" -gt 0 ] && ok "wrote_is_the_union_of_the_results_wrote" || bad "wrote vs results: $out"
miss=""; while IFS= read -r p; do git -C "$r" status --porcelain -- "$p" | grep -q . || miss="$miss $p"; done < <(jr "$out" '.wrote[]')
[ -z "$miss" ] && [ "$(j "$out" '.wrote | length')" -gt 0 ] && ok "every_wrote_path_shows_in_git_status" || bad "wrote but unchanged:$miss"
# never an ask step: nothing the ask steps write, no commit, no index change, no stash, no tool
# call but the beads-metrics read
[ ! -e "$r/NEXT.md" ] && [ ! -e "$r/.claude" ] && [ ! -e "$r/.beads" ] && [ ! -e "$r/.git/hooks/pre-commit" ] \
  && [ ! -e "$r/.github" ] && ok "auto_writes_nothing_an_ask_step_writes" || bad "ask-step files: $(ls -A "$r")"
[ "$(git -C "$r" rev-parse HEAD)" = "$h0" ] && git -C "$r" diff --cached --quiet && [ -z "$(git -C "$r" stash list)" ] \
  && ok "auto_makes_no_commit_no_staging_no_stash" || bad "git state changed"
[ "$(logof bd)" = 'config get metrics.disabled' ] && [ -z "$(logof gh)$(logof gitleaks)" ] \
  && ok "auto_calls_bd_only_for_the_metrics_read_never_gh_or_gitleaks" || bad "tool calls: bd=[$(logof bd)] gh=[$(logof gh)] gitleaks=[$(logof gitleaks)]"
[ "$(jq -c --argjson a "$AUTO_IDS" '[.steps[] | select(.id as $i | $a | index($i)) | select(.kind == "ask") | .id]' "$SKILL_DIR/steps.json" | tr -d '\r')" = '["stack-checks"]' ] \
  && ok "the_only_ask_kind_step_in_auto_is_stack_checks" || bad "ask kinds in auto list"

echo "== detection runs once per auto run =="
# RITUAL_TRACE: each language scan logs "stack_json", each oracle scan "oracle_json"
[ "$(tcount stack_json)|$(tcount oracle_json)" = '1|1' ] && ok "auto_scans_languages_once_and_the_oracle_once" \
  || bad "auto scans: stack_json=$(tcount stack_json) oracle_json=$(tcount oracle_json)"
: > "$TRACE"; RITUAL_TRACE="$TRACE" S fix stack-checks "$r" >/dev/null
[ "$(tcount stack_json)|$(tcount oracle_json)" = '1|0' ] && ok "standalone_fix_stack_checks_scans_languages_itself_no_oracle" \
  || bad "fix stack-checks scans: stack_json=$(tcount stack_json) oracle_json=$(tcount oracle_json)"
: > "$TRACE"; RITUAL_TRACE="$TRACE" S stack "$r" >/dev/null
[ "$(tcount stack_json)|$(tcount oracle_json)" = '1|1' ] && ok "standalone_stack_still_runs_the_oracle_for_testing_md" \
  || bad "stack scans: stack_json=$(tcount stack_json) oracle_json=$(tcount oracle_json)"
# after auto, the oracle step sees the lint command stack-checks just added (oracle runs after it)
[[ "$(res "$out" oracle detail)" == *"cargo clippy"* ]] && ok "oracle_step_sees_what_stack_checks_wrote" || bad "oracle lint: $(res "$out" oracle detail)"

echo "== ledger context resolves once per auto run =="
# first run on a fresh fixture: no ledger file, so no path_norm of the work tree top
lr="$(fresh_fixture ledgerrun)"
: > "$TRACE"; RITUAL_TRACE="$TRACE" S auto "$lr" >/dev/null
[ "$(tcount ledger_context)|$(tcount ledger_wt)" = '1|0' ] && ok "auto_first_run_resolves_no_wt" \
  || bad "first run: ledger_context=$(tcount ledger_context) ledger_wt=$(tcount ledger_wt)"
# give the ledger entries: preflight, commit-plan, then record-write with the commit declined
S preflight "$lr" > "$TMPROOT/lr pf.json"
j "$(S auto "$lr")" .wrote | jq -c . > "$TMPROOT/lr wrote.json"
S commit-plan "$lr" "$TMPROOT/lr pf.json" "$TMPROOT/lr wrote.json" >/dev/null
printf '%s' '{"steps":{"commit":{"result":"declined"}}}' > "$TMPROOT/lr results.json"
S record-write "$lr" "$TMPROOT/lr results.json" >/dev/null
lf="$(git -C "$lr" rev-parse --path-format=absolute --git-common-dir | tr -d '\r')/ritual-ledger.json"
[ "$(jq '.entries | length' "$lf" | tr -d '\r')" -gt 0 ] || bad "ledger premise: no entries in $lf"
: > "$TRACE"; RITUAL_TRACE="$TRACE" S auto "$lr" >/dev/null
[ "$(tcount ledger_context)|$(tcount ledger_wt)|$(tcount ledger_read)" = '1|1|3' ] \
  && ok "auto_rerun_resolves_ledger_context_once" \
  || bad "rerun: ledger_context=$(tcount ledger_context) ledger_wt=$(tcount ledger_wt) ledger_read=$(tcount ledger_read) (want 1|1|3)"
: > "$TRACE"; RITUAL_TRACE="$TRACE" S fix traps "$lr" >/dev/null
[ "$(tcount ledger_context)" = 1 ] && ok "standalone_fix_resolves_its_own_context" \
  || bad "fix traps: ledger_context=$(tcount ledger_context)"

echo "== stack and oracle wrapping =="
[ "$(res "$out" stack status)" = present ] && [[ "$(res "$out" stack detail)" == *"rust (.)"* ]] \
  && ok "stack_present_detail_names_the_language" || bad "stack: $(res "$out" stack status) $(res "$out" stack detail)"
[ "$(printf '%s' "$out" | jq -cS '.results[] | select(.id == "stack") | .output' | tr -d '\r')" = "$(S stack "$r" | jq -cS . | tr -d '\r')" ] \
  && ok "stack_output_is_the_stack_subcommand_output" || bad "stack output differs"
[ "$(res "$out" oracle status)" = present ] && [[ "$(res "$out" oracle detail)" == *"cargo test"* ]] \
  && ok "oracle_present_detail_names_the_test_command" || bad "oracle: $(res "$out" oracle status) $(res "$out" oracle detail)"
[ "$(printf '%s' "$out" | jq -cS '.results[] | select(.id == "oracle") | .output' | tr -d '\r')" = "$(S oracle "$r" | jq -cS . | tr -d '\r')" ] \
  && ok "oracle_output_is_the_oracle_subcommand_output" || bad "oracle output differs"
[ "$(res "$out" stack wrote)|$(res "$out" oracle wrote)" = '[]|[]' ] && ok "stack_and_oracle_write_nothing" || bad "stack/oracle wrote"
b="$(mkrepo bare)"
o2="$(S auto "$b")"
[ "$(res "$o2" stack status)" = absent ] && [ "$(res "$o2" stack detail)" = 'no stack detected' ] \
  && ok "stack_absent_when_no_language" || bad "bare stack: $(res "$o2" stack status) $(res "$o2" stack detail)"
[ "$(res "$o2" oracle status)" = absent ] && [ "$(res "$o2" oracle detail)" = 'no test command found' ] \
  && ok "oracle_absent_says_no_test_command_found" || bad "bare oracle: $(res "$o2" oracle status) $(res "$o2" oracle detail)"
u="$(mkrepo unparsed)"; printf '{ not json\n' > "$u/package.json"
o3="$(S auto "$u")"; rc=$?
[ "$rc" = 0 ] && [ "$(res "$o3" stack status)" = unknown ] && [[ "$(res "$o3" stack detail)" == *package.json* ]] \
  && ok "stack_unknown_when_a_manifest_cannot_be_parsed" || bad "unparsed stack: $(res "$o3" stack status) $(res "$o3" stack detail)"
[ "$(res "$o3" oracle status)" = unknown ] && [[ "$(res "$o3" oracle detail)" == *package.json* ]] \
  && ok "oracle_unknown_when_a_manifest_cannot_be_parsed" || bad "unparsed oracle: $(res "$o3" oracle status) $(res "$o3" oracle detail)"

echo "== rerun changes nothing =="
p1="$(git -C "$r" status --porcelain)"; s1="$(tree_sums "$r")"
out2="$(S auto "$r")"; rc=$?
# the first run was never committed: the rerun writes nothing, yet lists its untracked paths again
# (I1): 4 of the 5. The tracked Cargo.toml (its clippy table) goes silent since 0.16: no commit-plan
# ran, so it has no ledger entry, and a tracked file with no entry reads as the user's own edit.
# Accepted loss (spec B, globals): it shows in git status, and stack-checks' check sees the table.
[ "$rc" = 0 ] && [ "$(j "$out2" '.wrote | sort')" = "$(j "$out" '[.wrote[] | select(. != "Cargo.toml")] | sort')" ] \
  && [ "$(j "$out" '.wrote | index("Cargo.toml") != null')" = true ] && [ "$(j "$out2" '.wrote | length')" = 4 ] \
  && [ "$(j "$out2" '[.results[] | select(.status == "already" and (.wrote | length) > 0) | .detail | test("not yet committed")] | all')" = true ] \
  && ok "uncommitted_rerun_lists_the_first_runs_paths_again" || bad "rerun wrote: $(j "$out2" .wrote)"
[ "$(git -C "$r" status --porcelain)" = "$p1" ] && [ "$(tree_sums "$r")" = "$s1" ] \
  && ok "rerun_leaves_status_and_bytes_identical" || bad "rerun changed the tree"
[ "$(res "$out2" traps status)|$(res "$out2" stack-checks status)|$(res "$out2" parking-lot status)" = 'already|already|already' ] \
  && ok "rerun_fix_steps_report_already" || bad "rerun statuses: $out2"

echo "== non-canonical stack-checks (nested workspace) =="
w="$(mkrepo workspace)"
printf '[workspace]\nmembers = ["server"]\n' > "$w/Cargo.toml"; crate "$w/server" server; commit_all "$w" 'ws'
c0="$(sha256sum "$w/Cargo.toml" "$w/server/Cargo.toml")"
logclear
ow="$(S auto "$w")"
[ "$(res "$ow" stack-checks status)" = absent ] && [[ "$(res "$ow" stack-checks detail)" == *"workspace: needs ask"* ]] \
  && ok "workspace_stack_checks_absent_needs_ask" || bad "workspace stack-checks: $(res "$ow" stack-checks status) $(res "$ow" stack-checks detail)"
[ "$(sha256sum "$w/Cargo.toml" "$w/server/Cargo.toml")" = "$c0" ] && [ -z "$(logof cargo)" ] \
  && ok "workspace_manifests_untouched_and_cargo_never_run" || bad "workspace touched: cargo=[$(logof cargo)]"
[ "$(j "$ow" '[.wrote[] | select(endswith("Cargo.toml"))]')" = '[]' ] && [ "$(res "$ow" stack-checks wrote)" = '[]' ] \
  && ok "workspace_wrote_lists_no_manifest" || bad "workspace wrote: $(j "$ow" .wrote)"
[ "$(res "$ow" traps status)|$(res "$ow" parking-lot status)" = 'fixed|fixed' ] \
  && ok "workspace_other_auto_steps_still_run" || bad "workspace others: $ow"

echo "== beads-metrics =="
[ "$(res "$out" beads-metrics status)" = present ] && ok "metrics_present_when_bd_says_disabled" || bad "metrics present: $out"
om="$(STUB_METRICS=false S auto "$b")"
[ "$(res "$om" beads-metrics status)" = absent ] && [ "$(res "$om" beads-metrics wrote)" = '[]' ] \
  && ok "metrics_on_is_absent_and_auto_does_not_change_it" || bad "metrics false: $om"

echo "== a failing and a crashing step, in one run =="
f="$(mkrepo failing)"
printf '*.sh eol=crlf\n' > "$f/.git/info/attributes"   # outranks .gitattributes: the append cannot take effect
# a git that cannot name the work-tree root makes beads-metrics die (exit 2) mid-run
GITSTUB="$TMPROOT/git stub"; mkdir -p "$GITSTUB"
{ printf '#!/usr/bin/env bash\nREAL_GIT=%q\n' "$(command -v git)"; cat <<'WRAP'
for a in "$@"; do [ "$a" = --show-toplevel ] && { echo "stub: no toplevel" >&2; exit 128; }; done
exec "$REAL_GIT" "$@"
WRAP
} > "$GITSTUB/git"; chmod +x "$GITSTUB/git"
of="$( ( stub_path "$GITSTUB"; S auto "$f" ) 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(res "$of" traps status)" = failed ] && [ "$(j "$of" '[.results[].id]')" = "$AUTO_IDS" ] \
  && ok "failed_and_crashing_steps_do_not_stop_the_run_exit_0" || bad "failed step: rc=$rc $of"
[ "$(j "$of" .wrote)" = "$(j "$of" '[.results[].wrote[]] | reduce .[] as $x ([]; if index([$x]) then . else . + [$x] end)')" ] \
  && [[ "$(j "$of" .wrote)" == *.gitattributes* ]] && ok "failed_step_wrote_still_listed" || bad "failed wrote: $(j "$of" .wrote)"
[ "$(res "$of" beads-metrics status)" = unknown ] && [[ "$(res "$of" beads-metrics detail)" == *"exit 2"* ]] \
  && [[ "$(res "$of" beads-metrics detail)" == *"cannot resolve repo root"* ]] \
  && ok "crashing_step_is_unknown_naming_exit_and_cause" || bad "crash result: $(res "$of" beads-metrics status) $(res "$of" beads-metrics detail)"
[ "$(res "$of" parking-lot status)" = fixed ] && ok "steps_before_the_crash_keep_their_results" || bad "crash others: $of"

echo "== fully set up repo =="
: > "$SHADOW_LOG"
full="$(full_fixture)"
[ ! -s "$SHADOW_LOG" ] && ok "full_fixture_never_runs_an_unstubbed_tool" || bad "full_fixture reached: $(cat "$SHADOW_LOG")"
[ -z "$(git -C "$full" status --porcelain)" ] || bad "full fixture premise: tree not clean: $(git -C "$full" status --porcelain)"
ofu="$(S auto "$full")"; rc=$?
[ "$rc" = 0 ] && [ "$(j "$ofu" .wrote)" = '[]' ] && [ -z "$(git -C "$full" status --porcelain)" ] \
  && ok "fully_set_up_auto_writes_nothing_and_tree_stays_clean" || bad "full auto: $(j "$ofu" .wrote) / $(git -C "$full" status --porcelain)"

echo "== open_steps invariant =="
chk="$TMPROOT/full checks.jsonl"; : > "$chk"
for id in $CHECK_IDS; do S check "$id" "$full" >> "$chk"; done
# the fixture's premise: everything set up. public-sweep and untracked-docs are absent when nothing
# is due (a private repo; nothing untracked under docs/): present there would mean pending work.
prem="$(jq -rs 'map("\(.id)=\(.status)") | join(" ")' "$chk" | tr -d '\r')"
[ "$prem" = 'beads=present beads-metrics=present ci=present handoff=present parking-lot=present public-sweep=absent secret-scan=present stack-checks=present traps=present untracked-docs=absent' ] \
  && ok "full_fixture_premise_every_check_set_up" || bad "full premise: $prem"
S preflight "$full" >/dev/null; pfrc=$?
to_record "$ofu" "$chk" "$pfrc" > "$TMPROOT/full results.json"
rec="$(S record-write "$full" "$TMPROOT/full results.json")"
[ "$(j "$rec" '.steps | keys | length')" = "$(jq '.steps | length' "$SKILL_DIR/steps.json" | tr -d '\r')" ] \
  && ok "invariant_record_has_every_step" || bad "record steps: $(j "$rec" '.steps | keys')"
[ "$(j "$rec" '[.steps[].result | select(IN("done","already","declined","none","na") | not)]')" = '[]' ] \
  && ok "invariant_fixture_every_result_settled" || bad "unsettled: $(j "$rec" '.steps | map_values(.result)')"
[ "$(j "$rec" .open_steps)" = '[]' ] && ok "open_steps_invariant: fully set up -> open_steps []" || bad "open_steps: $(j "$rec" .open_steps)"
# converse control: one REAL unknown (beads-metrics run with no bd) must be the only open step
N check beads-metrics "$full" > "$TMPROOT/metrics unknown.json"
[ "$(st "$(cat "$TMPROOT/metrics unknown.json")")" = unknown ] || bad "converse premise: beads-metrics without bd is not unknown"
jq -c --slurpfile u "$TMPROOT/metrics unknown.json" '.steps["beads-metrics"].result = $u[0].status' "$TMPROOT/full results.json" > "$TMPROOT/flipped results.json"
rec2="$(S record-write "$full" "$TMPROOT/flipped results.json")"
[ "$(j "$rec2" .open_steps)" = '["beads-metrics"]' ] && ok "open_steps_converse: one unknown step is exactly the open step" || bad "converse open_steps: $(j "$rec2" .open_steps)"

echo "== no-tools environment =="
# controls: the stripped environment still finds git and jq, and finds none of bd/gh/gitleaks
ctl="$(N_PATH="$CARGO_STUB:$NOTOOLS"; PATH="$N_PATH"; for t in git jq bd gh gitleaks; do command -v "$t" >/dev/null 2>&1 && printf '%s ' "$t"; done)"
[ "$ctl" = 'git jq ' ] && ok "no_tools_control_git_and_jq_found_tools_hidden" || bad "no-tools control: found [$ctl]"
# the second gitleaks route (LOCALAPPDATA/Microsoft/WinGet/Links), asked of the ritual's own resolver:
# open with a gitleaks.exe there, closed with N's empty LOCALAPPDATA
OPEN_LA="$TMPROOT/open localappdata"; mkdir -p "$OPEN_LA/Microsoft/WinGet/Links"
printf '#!/usr/bin/env bash\nexit 0\n' > "$OPEN_LA/Microsoft/WinGet/Links/gitleaks.exe"; chmod +x "$OPEN_LA/Microsoft/WinGet/Links/gitleaks.exe"
resolve_gl() { ( PATH="$CARGO_STUB:$NOTOOLS"; LOCALAPPDATA="$(cygpath -w "$1")"; export PATH LOCALAPPDATA
  bash -c '. "$1/lib/common.sh"; . "$1/lib/secretscan.sh"; _ss_gitleaks' _ "$SKILL_DIR" ); }
gl_open="$(resolve_gl "$OPEN_LA")"; gl_closed="$(resolve_gl "$EMPTY_LA")"
[[ "$gl_open" == *WinGet/Links/gitleaks.exe ]] && [ -z "$gl_closed" ] \
  && ok "no_tools_control_winget_route_open_vs_closed" || bad "winget route: open=[$gl_open] closed=[$gl_closed]"
# the list of steps with a check_ function is the list this test walks
[ "$(grep -ho '^check_[a-z_]*()' "$SKILL_DIR"/lib/*.sh | sed 's/^check_//; s/()$//; s/_/-/g' | LC_ALL=C sort | paste -sd' ' -)" = "$CHECK_IDS" ] \
  && ok "no_tools_walks_every_check_function" || bad "check_ functions: $(grep -ho '^check_[a-z_]*()' "$SKILL_DIR"/lib/*.sh | paste -sd' ' -)"
fz="$(fresh_fixture notools)"
for repo in "$full" "$fz"; do
  name="$(basename "$repo")"; rcs=""; failed=""; notunk=""
  ona="$(N auto "$repo")"; rcs="$rcs auto=$?"
  [ "$(res "$ona" beads-metrics status)" = unknown ] || notunk="$notunk auto:beads-metrics"
  failed="$(jr "$ona" '[.results[] | select(.status == "failed") | .id] | join(",")')"
  for id in $CHECK_IDS; do
    o="$(N check "$id" "$repo")"; rcs="$rcs $id=$?"
    [ "$(st "$o")" = failed ] && failed="$failed $id"
    case " $TOOL_IDS " in *" $id "*) [ "$(st "$o")" = unknown ] || notunk="$notunk $id:$(st "$o")" ;; esac
  done
  [ "$(printf '%s' "$rcs" | tr ' ' '\n' | grep -v '=0$' | grep -c .)" = 0 ] && ok "no_tools_env($name): every call exits 0" || bad "no_tools_env($name) exits:$rcs"
  [ -z "$notunk" ] && ok "no_tools_env($name): every bd/gh/gitleaks step unknown" || bad "no_tools_env($name) not unknown:$notunk"
  [ -z "${failed// /}" ] && ok "no_tools_env($name): none failed" || bad "no_tools_env($name) failed: $failed"
done

echo "== spaced path, relative argument =="
mkdir -p "$TMPROOT/spaced parent (x)"
# same shape as the fresh fixture, so its results must equal the fresh run's (made with an absolute path)
sp="$TMPROOT/spaced parent (x)/my repo (copy)"
mkdir -p "$sp"; git -C "$sp" init -q -b main >/dev/null 2>&1 || git -C "$sp" init -q
git -C "$sp" config user.email t@example.com; git -C "$sp" config user.name Test; git -C "$sp" config core.autocrlf false
echo seed > "$sp/README.md"; crate "$sp" spaced; commit_all "$sp" 'crate'
osp="$( cd "$TMPROOT/spaced parent (x)" && S auto "my repo (copy)" )"; rc=$?
[ "$rc" = 0 ] && [ "$(j "$osp" '[.results[] | {id, status, wrote}]')" = "$(j "$out" '[.results[] | {id, status, wrote}]')" ] \
  && ok "spaced_repo_e2e: relative spaced path gives the same results as an absolute one" || bad "spaced: $osp // $out"
[ "$(j "$osp" '[.results[].status | select(. == "failed" or . == "unknown")]')" = '[]' ] \
  && [ -f "$sp/docs/parking-lot.md" ] && [ ! -e "$sp/my repo (copy)" ] && [ "$(ls -A "$TMPROOT/spaced parent (x)")" = 'my repo (copy)' ] \
  && ok "spaced_repo_writes_land_inside_the_repo_only" || bad "spaced writes: $(ls -A "$TMPROOT/spaced parent (x)") / $(ls -A "$sp")"
notp=""
for id in traps stack-checks parking-lot; do
  [ "$(st "$(S check "$id" "$sp")")" = present ] || notp="$notp $id:$(st "$(S check "$id" "$sp")")"
done
[ -z "$notp" ] && ok "spaced_repo_auto_steps_present_after" || bad "spaced checks not present:$notp"

echo "== a path inside the repo means the repo root =="
subrepo() { local r; r="$(fresh_fixture "$1")"; mkdir -p "$r/sub dir"; echo n > "$r/sub dir/notes.txt"; commit_all "$r" 'sub dir'; printf '%s\n' "$r"; }
a="$(subrepo subdir-auto)"
osub="$( cd "$a/sub dir" && S auto . )"; rc=$?
[ "$rc" = 0 ] && [ "$(j "$osub" '[.results[] | {id, status, wrote}]')" = "$(j "$out" '[.results[] | {id, status, wrote}]')" ] \
  && [ "$(j "$osub" .wrote)" = "$(j "$out" .wrote)" ] && ok "auto_from_a_subdirectory_equals_auto_at_the_root" || bad "subdir auto: $osub"
[ "$(ls -A "$a/sub dir")" = notes.txt ] && [ -f "$a/docs/parking-lot.md" ] && [ -f "$a/CLAUDE.md" ] \
  && ok "auto_from_a_subdirectory_creates_nothing_under_it" || bad "subdir contents: $(ls -A "$a/sub dir")"
bb="$(subrepo subdir-fix)"
ofp="$( cd "$bb" && S fix parking-lot "sub dir" )"
[ "$(j "$ofp" .wrote)" = '["docs/parking-lot.md","CLAUDE.md"]' ] && [ -f "$bb/docs/parking-lot.md" ] && [ -f "$bb/CLAUDE.md" ] \
  && [ "$(ls -A "$bb/sub dir")" = notes.txt ] && ok "fix_parking_lot_given_a_subdirectory_writes_at_the_root" || bad "subdir fix: $ofp / $(ls -A "$bb/sub dir")"
[ "$(S oracle "$bb/sub dir" | jq -cS . | tr -d '\r')" = "$(S oracle "$bb" | jq -cS . | tr -d '\r')" ] \
  && [ "$(S oracle "$bb" | jq -r .status | tr -d '\r')" = present ] && ok "oracle_given_a_subdirectory_scans_the_root" || bad "subdir oracle: $(S oracle "$bb/sub dir")"

echo "== a step that exits 0 without a result =="
# a jq wrapper that turns beads-metrics' own `present` result into $JQW_REPLY (unset: non-JSON);
# every other call is real, except that it answers emit's line-ending probe (`jq -nc 1`) with nothing,
# so emit takes the jq path that the wrapper can see rather than building the plain result itself
JQW="$TMPROOT/jq wrap"; mkdir -p "$JQW"
{ printf '#!/usr/bin/env bash\nREAL_JQ=%q\n' "$(command -v jq)"; cat <<'WRAP'
if [ "${1:-}" = -nc ] && [ "${2:-}" = 1 ]; then exit 0; fi
if [ "${1:-}" = -nRc ] && [ "${4:-}" = beads-metrics ] && [ "${7:-}" = present ]; then printf '%s\n' "${JQW_REPLY-not json}"; exit 0; fi
exec "$REAL_JQ" "$@"
WRAP
} > "$JQW/jq"; chmod +x "$JQW/jq"
[ "$( ( stub_path "$JQW"; S check beads-metrics "$b" ) )" = 'not json' ] || bad "jq wrapper premise: check beads-metrics did not print 'not json'"
ojq="$( ( stub_path "$JQW"; S auto "$b" ) 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && [ "$(j "$ojq" '[.results[].id]')" = "$AUTO_IDS" ] && [ "$(res "$ojq" beads-metrics status)" = unknown ] \
  && [[ "$(res "$ojq" beads-metrics detail)" == *"(exit 0)"* ]] && ok "step_with_exit_0_and_no_result_is_unknown" || bad "no-result step: rc=$rc $ojq"
# the guard's own output, exactly, for each way an exit-0 step's output can fail to be its result.
# Each _auto_result predicate clause has the reply only it rejects: .id (another id), .status (not a
# string), .wrote (not an array). `type == "object"` has none: without it every non-object reply
# still fails, on `.id` (jq errors) or as null != $id, so dropping it is an equivalent mutant.
GUARD_WANT='{"id":"beads-metrics","status":"unknown","detail":"step ended without a result (exit 0)","wrote":[]}'
guard_case() {   # guard_case <name> <reply>
  local o rc
  [ "$( ( stub_path "$JQW"; export JQW_REPLY="$2"; S check beads-metrics "$b" ) )" = "$2" ] \
    || { bad "guard_$1 premise: check beads-metrics did not print the reply"; return 0; }
  o="$( ( stub_path "$JQW"; export JQW_REPLY="$2"; S auto "$b" ) 2>/dev/null)"; rc=$?
  [ "$rc" = 0 ] && [ "$(j "$o" '[.results[].id]')" = "$AUTO_IDS" ] \
    && [ "$(j "$o" '[.results[] | select(.id == "beads-metrics")]')" = "[$GUARD_WANT]" ] \
    && ok "guard_$1" || bad "guard_$1: rc=$rc $o"
}
guard_case rejects_a_result_for_another_id '{"id":"other","status":"present","detail":"","wrote":[]}'
guard_case rejects_non_json 'not json'
guard_case rejects_wrote_not_an_array '{"id":"beads-metrics","status":"present","detail":"","wrote":"x"}'
guard_case rejects_status_not_a_string '{"id":"beads-metrics","status":1,"detail":"","wrote":[]}'
# two JSON values, the last one a valid result: `jq -e` alone judges only the last value, so the
# guard slurps and requires exactly one
guard_case rejects_a_stray_value_before_a_result '{"stray":1}
{"id":"beads-metrics","status":"present","detail":"","wrote":[]}'

echo "== an interrupted auto leaves no temp file =="
IT="$TMPROOT/auto tmpdir"; mkdir -p "$IT"
ir="$(fresh_fixture interrupt)"
( stub_path "$CARGO_STUB"; stub_path "$STUBS"; export E2E_LOGS="$LOGS" RITUAL_RUST_INCLUDE="$INC" TMPDIR="$IT"
  exec bash "$RITUAL" auto "$ir" ) >/dev/null 2>&1 &
pid=$!; seen=0
for _ in $(seq 1 300); do [ -n "$(ls -A "$IT")" ] && { seen=1; break; }; sleep 0.1; done
kill -TERM "$pid" 2>/dev/null; wait "$pid"; irc=$?
[ "$seen" = 1 ] && [ "$irc" != 0 ] && [ -z "$(ls -A "$IT")" ] && ok "interrupted_auto_removes_its_temp_file" \
  || bad "interrupt: seen=$seen rc=$irc left=[$(ls -A "$IT")]"
rm -rf "$IT"; mkdir -p "$IT"
( stub_path "$CARGO_STUB"; stub_path "$STUBS"; export E2E_LOGS="$LOGS" RITUAL_RUST_INCLUDE="$INC" TMPDIR="$IT"
  bash "$RITUAL" auto "$ir" ) >/dev/null 2>&1
[ -z "$(ls -A "$IT")" ] && ok "completed_auto_removes_its_temp_file" || bad "temp left: $(ls -A "$IT")"

[ ! -s "$SHADOW_LOG" ] && ok "no_test_reached_an_unstubbed_tool" || bad "unstubbed calls: $(cat "$SHADOW_LOG")"

finish
