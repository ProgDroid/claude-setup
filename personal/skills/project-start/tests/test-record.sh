#!/usr/bin/env bash
# Tests for ritual.sh record-* / due and lib/common.sh.
# Run: bash personal/skills/project-start/tests/test-record.sh
. "$(dirname "$0")/lib.sh"

R() { bash "$RITUAL" "$@"; }
# results <json> -> path of a results file
results() { local f; f="$(mktemp -p "$TMPROOT")"; printf '%s' "$1" > "$f"; printf '%s\n' "$f"; }
absgit() { git -C "$1" rev-parse --path-format=absolute --git-common-dir; }

echo "== record-path =="
repo="$(mkrepo)"
p="$(R record-path "$repo" | jq -r .path)"
case "$p" in */ritual.json) ok "record_path ends in /ritual.json" ;; *) bad "record_path: '$p'" ;; esac
[ "$(dirname "$p")" = "$(absgit "$repo")" ] && ok "record_path_is_in_common_dir" || bad "record_path dir '$(dirname "$p")' != '$(absgit "$repo")'"
case "$repo" in *" "*) ok "spaced_path: fixture path contains a space" ;; *) bad "fixture path has no space: $repo" ;; esac

git -C "$repo" worktree add -q "$TMPROOT/ritual fixtures/wt" -b wtb 2>/dev/null
[ -d "$TMPROOT/ritual fixtures/wt" ] || bad "worktree was not created (test premise)"
[ "$(R record-path "$TMPROOT/ritual fixtures/wt" | jq -r .path)" = "$p" ] \
  && ok "record_shared_by_worktree" || bad "worktree record path differs"

echo "== record-read =="
[ "$(R record-read "$repo")" = "{}" ] && ok "record_read_absent_is_empty_object" || bad "absent record-read: $(R record-read "$repo")"

echo "== record-write =="
f="$(results '{"steps":{"preflight":{"result":"unknown","note":"a"},"beads":{"result":"interrupted"},"stack":{"result":"declined"},"lessons":{"result":"none"},"traps":{"result":"failed"},"stack-checks":{"result":"done"}}}')"
out="$(R record-write "$repo" "$f")"
[ "$(printf '%s' "$out" | jq -c .open_steps)" = '["preflight","beads"]' ] \
  && ok "open_steps_only_unknown_and_interrupted" || bad "open_steps: $(printf '%s' "$out" | jq -c .open_steps)"
[ "$(printf '%s' "$out" | jq -c .)" = "$(R record-read "$repo")" ] && ok "record-write prints the written record" || bad "printed != on-disk"
[ "$(R record-read "$repo" | jq -r .steps.preflight.note)" = a ] && ok "note is stored" || bad "note lost"

# open_steps follows steps.json order, not input order
f="$(results '{"steps":{"ci":{"result":"unknown"},"beads":{"result":"unknown"}}}')"
[ "$(R record-write "$(mkrepo ord)" "$f" | jq -c .open_steps)" = '["beads","ci"]' ] \
  && ok "open_steps ordered by steps.json" || bad "open_steps order wrong"

r2="$(mkrepo merge)"
R record-write "$r2" "$(results '{"steps":{"stack":{"result":"done"}}}')" >/dev/null
out="$(R record-write "$r2" "$(results '{"steps":{"traps":{"result":"declined"}}}')")"
[ "$(printf '%s' "$out" | jq -c '.steps|keys')" = '["stack","traps"]' ] \
  && ok "merge_keeps_prior_steps" || bad "merge: $(printf '%s' "$out" | jq -c '.steps|keys')"
out="$(R record-write "$r2" "$(results '{"steps":{"stack":{"result":"unknown"}}}')")"
[ "$(printf '%s' "$out" | jq -c '[.steps.stack.result,.steps.traps.result,.open_steps]')" = '["unknown","declined",["stack"]]' ] \
  && ok "a re-written step replaces its prior result and open_steps follows" || bad "overwrite: $out"

[ "$(printf '%s' "$out" | jq -c '[.steps[]|.version]|unique')" = '[1]' ] \
  && [ "$(printf '%s' "$out" | jq .ritual_version)" = 1 ] \
  && printf '%s' "$out" | jq -e '.completed_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")' >/dev/null \
  && ok "version_stamped" || bad "version stamp: $out"
[ "$(printf '%s' "$out" | jq -r .completed_at)" = "$(date +%F)" ] && ok "completed_at is today" || bad "completed_at not today"

# versions come from steps.json, per step
echo '{"ritual_version":3,"steps":[{"id":"a","kind":"ask","version":2},{"id":"b","kind":"ask","version":5}]}' > "$TMPROOT/v.json"
out="$(RITUAL_STEPS_JSON="$TMPROOT/v.json" R record-write "$(mkrepo ver)" "$(results '{"steps":{"a":{"result":"done"},"b":{"result":"done"}}}')")"
[ "$(printf '%s' "$out" | jq -c '[.ritual_version,.steps.a.version,.steps.b.version]')" = '[3,2,5]' ] \
  && ok "per-step versions and ritual_version come from steps.json" || bad "versions: $out"

# baseline block passes through; absent baseline leaves prior one alone
r3="$(mkrepo base)"
R record-write "$r3" "$(results '{"steps":{"baseline":{"result":"done"}},"baseline":{"pass":12,"seconds":3}}')" >/dev/null
R record-write "$r3" "$(results '{"steps":{"ci":{"result":"done"}}}')" >/dev/null
[ "$(R record-read "$r3" | jq -c .baseline)" = '{"pass":12,"seconds":3}' ] && ok "baseline stored and kept across writes" || bad "baseline: $(R record-read "$r3")"

# R2: any result string accepted, not in open_steps
out="$(R record-write "$(mkrepo free)" "$(results '{"steps":{"ci":{"result":"n/a"},"oracle":{"result":"anything-at-all"}}}')")"
[ "$(printf '%s' "$out" | jq -c .open_steps)" = '[]' ] && ok "arbitrary result strings accepted, none open" || bad "free-form: $out"

# record never lands in the work tree
[ -z "$(git -C "$r2" status --porcelain)" ] && ok "record_never_in_worktree" || bad "worktree dirty: $(git -C "$r2" status --porcelain)"
[ -f "$(R record-path "$r2" | jq -r .path)" ] && ok "record file exists at record-path after write" || bad "no file at record-path"

# bad input
R record-write "$r2" "$TMPROOT/nope.json" >/dev/null 2>&1 && bad "missing results file accepted" || ok "missing results file is an error"
R record-write "$r2" "$(results 'not json')" >/dev/null 2>&1 && bad "invalid json accepted" || ok "invalid results json is an error"
before="$(R record-read "$r2")"
R record-write "$r2" "$(results '{"nosteps":1}')" >/dev/null 2>&1 && bad "shape without steps accepted" || ok "results without .steps is an error"
[ "$(R record-read "$r2")" = "$before" ] && ok "failed write leaves the record untouched" || bad "record changed by failed write"
R bogus "$r2" >/dev/null 2>&1 && bad "unknown subcommand exits 0" || ok "unknown subcommand is an error"

echo "== non-git path is refused =="
ng="$TMPROOT/not a repo"; mkdir -p "$ng"
printf '{"steps":{"ci":{"result":"done"}}}' > "$TMPROOT/ng-results.json"
[ ! -e /ritual.json ] || bad "premise: /ritual.json already exists"
if git -C "$ng" rev-parse --git-dir >/dev/null 2>&1; then bad "premise: fixture is inside a git repo"; else ok "premise: fixture dir is not in a git repo"; fi
for sub in record-path record-read record-write due; do
  if [ "$sub" = record-write ]; then args=("$ng" "$TMPROOT/ng-results.json"); else args=("$ng"); fi
  out="$(R "$sub" "${args[@]}" 2>"$TMPROOT/ng.err")"; rc=$?
  [ "$rc" -ne 0 ] && ok "$sub on a non-git dir exits non-zero" || bad "$sub on a non-git dir exited 0: $out"
  grep -q 'not a git repository' "$TMPROOT/ng.err" && ok "$sub says 'not a git repository'" || bad "$sub stderr: $(cat "$TMPROOT/ng.err")"
  [ -z "$out" ] && ok "$sub prints nothing on stdout" || bad "$sub stdout: $out"
done
[ ! -e /ritual.json ] && [ ! -e "$ng/ritual.json" ] && [ ! -e "$ng/.git/ritual.json" ] \
  && ok "no ritual.json at filesystem root or in the dir after all four" || bad "a ritual.json was created"

echo "== due =="
r4="$(mkrepo due)"
d="$(R due "$r4")"
[ "$(printf '%s' "$d" | jq '.offer|length')" = 19 ] && [ "$(printf '%s' "$d" | jq '.skip|length')" = 0 ] \
  && ok "fresh repo: all 19 steps offered, none skipped" || bad "fresh due: $d"
R record-write "$r4" "$(results '{"steps":{"baseline":{"result":"declined"},"ci":{"result":"unknown"},"traps":{"result":"done"}}}')" >/dev/null
d="$(R due "$r4")"
[ "$(printf '%s' "$d" | jq -c '[.skip[].id]')" = '["baseline"]' ] \
  && printf '%s' "$d" | jq -e '.skip[0].reason|length>0' >/dev/null \
  && printf '%s' "$d" | jq -e '.offer|index("baseline")|not' >/dev/null \
  && ok "due_skips_declined_same_version" || bad "skip: $d"
printf '%s' "$d" | jq -e '.offer|index("ci")' >/dev/null && ok "due_offers_unknown" || bad "unknown not offered: $d"
printf '%s' "$d" | jq -e '.offer|index("traps")' >/dev/null && ok "a done step is still offered (only declined is skipped)" || bad "done step not offered"
[ "$(printf '%s' "$d" | jq '.offer|length')" = 18 ] && ok "offer + skip partition the steps (18 + 1)" || bad "offer count: $d"
jq '(.steps[]|select(.id=="baseline")|.version)=2 | .ritual_version=2' "$(RITUAL_STEPS_JSON= bash -c '. "$0"; steps_json' "$SKILL_DIR/lib/common.sh")" > "$TMPROOT/v2.json"
d="$(RITUAL_STEPS_JSON="$TMPROOT/v2.json" R due "$r4")"
printf '%s' "$d" | jq -e '.offer|index("baseline")' >/dev/null && [ "$(printf '%s' "$d" | jq '.skip|length')" = 0 ] \
  && ok "due_reoffers_declined_new_version" || bad "new version: $d"

echo "== per-run asks (I3) =="
[ "$(jq -c '[.steps[] | select(.per_run == true) | .id]' "$SKILL_DIR/steps.json" | tr -d '\r')" = '["untracked-docs","commit"]' ] \
  && ok "steps_json_marks_commit_and_untracked_docs_per_run" || bad "per_run steps: $(jq -c '[.steps[] | select(.per_run) | .id]' "$SKILL_DIR/steps.json")"
r5="$(mkrepo perrun)"
R record-write "$r5" "$(results '{"steps":{"commit":{"result":"declined"},"untracked-docs":{"result":"declined"},"baseline":{"result":"declined"}}}')" >/dev/null
d="$(R due "$r5")"
printf '%s' "$d" | jq -e '(.offer | index("commit")) and (.offer | index("untracked-docs"))' >/dev/null \
  && ok "due_offers_a_declined_commit_again" || bad "declined commit not re-offered: $d"
[ "$(printf '%s' "$d" | jq -c '[.skip[].id]')" = '["baseline"]' ] && ok "control_a_declined_step_that_is_not_per_run_is_still_skipped" || bad "per-run skip: $d"
echo '{"ritual_version":1,"steps":[{"id":"a","kind":"ask","version":1,"per_run":true},{"id":"b","kind":"ask","version":1},{"id":"c","kind":"ask","version":1,"per_run":false}]}' > "$TMPROOT/pr.json"
r6="$(mkrepo perrun2)"
RITUAL_STEPS_JSON="$TMPROOT/pr.json" R record-write "$r6" "$(results '{"steps":{"a":{"result":"declined"},"b":{"result":"declined"},"c":{"result":"declined"}}}')" >/dev/null
d="$(RITUAL_STEPS_JSON="$TMPROOT/pr.json" R due "$r6")"
[ "$(printf '%s' "$d" | jq -c '[.offer, [.skip[].id]]')" = '[["a"],["b","c"]]' ] && ok "due_never_skips_a_per_run_step_whatever_its_id" || bad "per_run registry: $d"

echo "== from another cwd =="
( cd "$TMPROOT" && bash "$RITUAL" record-read "$r4" | jq -e '.steps.baseline' >/dev/null ) \
  && ok "runs from an unrelated cwd" || bad "cwd-dependent"

finish
