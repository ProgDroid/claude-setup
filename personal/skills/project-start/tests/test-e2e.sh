#!/usr/bin/env bash
# End-to-end tests: `ritual.sh auto` (the scripted auto steps) and whole-ritual properties on fixture
# repos: fresh, fully set up, nested-workspace, no-tools environment and a spaced relative path.
# Every external tool the ritual calls (bd, gh, gitleaks, cargo) is a stub here; the real ones on
# this machine are never run.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTO_IDS='["stack","traps","stack-checks","oracle","parking-lot","beads-metrics"]'
CHECK_IDS='beads beads-metrics ci handoff parking-lot public-sweep secret-scan stack-checks traps untracked-docs'
TOOL_IDS='beads beads-metrics public-sweep secret-scan'   # the steps that need bd, gh or gitleaks
INC="$TESTS_DIR/fixtures/rust-include.md"
KEY_LINE='all = { level = "warn", priority = -1 }'        # a line of the include's clippy table

# --- stubs. Each logs its argv, so a test can prove which tools a run touched.
STUBS="$TMPROOT/e2e stubs"; CARGO_STUB="$TMPROOT/cargo stub"; EMPTY_LA="$TMPROOT/empty localappdata"
LOGS="$TMPROOT/stub logs"
mkdir -p "$STUBS" "$CARGO_STUB" "$EMPTY_LA" "$LOGS"
cat > "$STUBS/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_LOGS:?}/bd"
[ "$1 ${2:-} ${3:-}" = "config get metrics.disabled" ] && printf '%s\n' "${STUB_METRICS-true}"
exit 0
STUB
cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_LOGS:?}/gh"
echo PRIVATE
STUB
# flags any staged AWS-style key, as the real gitleaks rule does
cat > "$STUBS/gitleaks" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_LOGS:?}/gitleaks"
if git diff --cached | grep -qE 'AKIA[A-Z2-7]{16}'; then echo "WRN leaks found: 1" >&2; exit 1; fi
echo "INF no leaks found" >&2; exit 0
STUB
cat > "$CARGO_STUB/cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_LOGS:?}/cargo"
exit 0
STUB
chmod +x "$STUBS"/* "$CARGO_STUB/cargo"

NOTOOLS="$(PATH="$(path_without bd)"; PATH="$(path_without gh)"; PATH="$(path_without gitleaks)"; printf '%s' "$PATH")"
# S = every tool stubbed; N = no bd, gh or gitleaks by any route (cargo stays stubbed in both)
S() { ( stub_path "$CARGO_STUB"; stub_path "$STUBS"; export E2E_LOGS="$LOGS" RITUAL_RUST_INCLUDE="$INC"; bash "$RITUAL" "$@" ); }
N() { ( PATH="$CARGO_STUB:$NOTOOLS"; LOCALAPPDATA="$(cygpath -w "$EMPTY_LA")"
        export PATH LOCALAPPDATA E2E_LOGS="$LOGS" RITUAL_RUST_INCLUDE="$INC"; bash "$RITUAL" "$@" ); }

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
  commit_all "$r" 'chore: ritual setup'
  S handoff-commit "$r" >/dev/null
  printf '%s\n' "$r"
}

# to_record <auto-output> <checks-json-lines-file> <preflight-exit> -> {"steps":{...}} for every
# steps.json id, mapped as the skill maps them: fixed->done, already/present->already,
# unknown->unknown, failed->failed, oracle absent->none, ci absent with no oracle->na, any other
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
out="$(S auto "$r")"; rc=$?
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
[ "$rc" = 0 ] && [ "$(j "$out2" .wrote)" = '[]' ] && ok "fully_set_up_rerun_changes_nothing: second wrote is []" || bad "rerun wrote: $(j "$out2" .wrote)"
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
full="$(full_fixture)"
[ -z "$(git -C "$full" status --porcelain)" ] || bad "full fixture premise: tree not clean: $(git -C "$full" status --porcelain)"
ofu="$(S auto "$full")"; rc=$?
[ "$rc" = 0 ] && [ "$(j "$ofu" .wrote)" = '[]' ] && [ -z "$(git -C "$full" status --porcelain)" ] \
  && ok "fully_set_up_auto_writes_nothing_and_tree_stays_clean" || bad "full auto: $(j "$ofu" .wrote) / $(git -C "$full" status --porcelain)"

echo "== open_steps invariant =="
chk="$TMPROOT/full checks.jsonl"; : > "$chk"
for id in $CHECK_IDS; do S check "$id" "$full" >> "$chk"; done
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
[ "$ctl" = 'git jq ' ] && [ ! -e "$EMPTY_LA/Microsoft/WinGet/Links/gitleaks.exe" ] \
  && ok "no_tools_control_git_and_jq_found_tools_hidden" || bad "no-tools control: found [$ctl]"
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

finish
