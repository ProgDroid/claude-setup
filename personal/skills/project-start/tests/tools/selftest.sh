#!/usr/bin/env bash
# Self-tests for differential.sh and bench.sh. Not named test-*.sh on purpose: run-all and CI must
# not run it (it costs minutes). Compares the current skill dir with itself and with a temp copy of
# itself, so it needs no 0.16.0 tree.  Run: bash personal/skills/project-start/tests/tools/selftest.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
TOOLS="$TESTS_DIR/tools"
OUT="$TMPROOT/out"; mkdir -p "$OUT"

echo "== differential: same tree =="
out="$(bash "$TOOLS/differential.sh" --jobs 3 --only python --only one-crate:fresh "$SKILL_DIR" "$SKILL_DIR" "$OUT/same" 2>&1)"; rc=$?
last="$(printf '%s\n' "$out" | tail -n 1 | tr -d '\r')"
n="$(printf '%s' "$last" | sed -n 's/^differential: \([0-9][0-9]*\) cases, 0 differ$/\1/p')"
[ "$rc" = 0 ] && [ -n "$n" ] && [ "$n" -ge 20 ] && ! printf '%s\n' "$out" | grep -q '^DIFF' \
  && ok "differential_same_tree_is_all_same" || bad "differential_same_tree_is_all_same: rc=$rc last='$last' n='$n'"

echo "== differential: a planted change =="
cp -r "$SKILL_DIR" "$TMPROOT/mutant"
anchor="$(grep -c '_DET_LINT_RE=.^(cargo clippy|ruff|' "$TMPROOT/mutant/lib/detect.sh")"
sed -i 's/^\(_DET_LINT_RE=.^(cargo clippy|\)ruff|/\1/' "$TMPROOT/mutant/lib/detect.sh"
left="$(grep -c '_DET_LINT_RE=.^(cargo clippy|ruff|' "$TMPROOT/mutant/lib/detect.sh")"
out="$(bash "$TOOLS/differential.sh" --only python:fresh:oracle "$SKILL_DIR" "$TMPROOT/mutant" "$OUT/mut" 2>&1)"; rc=$?
nd="$(printf '%s\n' "$out" | grep -c '^DIFF stdout')"
[ "$anchor" = 1 ] && [ "$left" = 0 ] && [ "$rc" = 1 ] && [ "$nd" = 1 ] \
  && ok "differential_sees_a_planted_change" || bad "differential_sees_a_planted_change: anchor=$anchor left=$left rc=$rc diffs=$nd out=[$out]"

echo "== differential and bench: no sha256sum =="
# an empty PATH holds no sha256sum (and no dirname, so only a guard that runs first can exit 2 with this message)
mkdir -p "$TMPROOT/nopath"
for t in differential bench; do
  err="$(PATH="$TMPROOT/nopath" "$ABS_BASH" "$TOOLS/$t.sh" a b c d e 2>&1 >/dev/null)"; rc=$?
  [ "$rc" = 2 ] && [ "$err" = "$t: sha256sum is required (without it a changed hook would read SAME)" ] \
    && ok "${t}_refuses_without_sha256sum" || bad "${t}_refuses_without_sha256sum: rc=$rc err='$err'"
done

echo "== differential: unmatched --only =="
bash "$TOOLS/differential.sh" --only nosuchfixture "$SKILL_DIR" "$SKILL_DIR" "$OUT/none" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "differential_unmatched_only_is_an_error" || bad "differential_unmatched_only_is_an_error: rc=$rc"


# mutate_copy <name> <file> <anchor-regex> <sed-replacement>: copy SKILL_DIR to "$TMPROOT/<name>", assert
# the anchor matches exactly once in <file> (a trailing CR tolerated) before the edit and not at all
# after it, then apply it. Sets MUT_OK=1 when both counts held.
mutate_copy() {
  local d="$TMPROOT/$1" f pre post
  cp -r "$SKILL_DIR" "$d"; f="$d/$2"
  pre="$(grep -c -e "$3" "$f")"
  sed -i "s#$3#$4#" "$f"
  post="$(grep -c -e "$3" "$f")"
  [ "$pre" = 1 ] && [ "$post" = 0 ] && MUT_OK=1 || MUT_OK=0
}
# diff_case <name> <case> -> out, rc, nd (DIFF lines) for SKILL_DIR vs the mutant copy
diff_case() {
  out="$(bash "$TOOLS/differential.sh" --only "$2" "$SKILL_DIR" "$TMPROOT/$1" "$OUT/$1" 2>&1)"; rc=$?
  nd="$(printf '%s\n' "$out" | grep -c '^DIFF')"
}

echo "== differential: each comparison category can fail =="
# pre-registered: 1 DIFF line each; files / ledger / exit named respectively
mutate_copy m-files lib/files.sh "^_TRAP_ATTR='\*\.sh text eol=lf'\r\?\$" "_TRAP_ATTR='*.sh text eol=crlf'"
diff_case m-files python:fresh:fix-traps
[ "$MUT_OK" = 1 ] && [ "$rc" = 1 ] && [ "$nd" = 1 ] && printf '%s\n' "$out" | grep '^DIFF' | grep -q 'files' \
  && ok "differential_sees_a_file_change" || bad "differential_sees_a_file_change: mut=$MUT_OK rc=$rc diffs=$nd out=[$out]"

mutate_copy m-ledger lib/ledger.sh 'fp: \$o\[4\], state: \$o\[3\]}\]' 'fp: $o[4], state: ($o[3] + "x")}]'
diff_case m-ledger python:fresh:commit-plan
[ "$MUT_OK" = 1 ] && [ "$rc" = 1 ] && [ "$nd" = 1 ] && printf '%s\n' "$out" | grep '^DIFF' | grep -q 'ledger' \
  && ok "differential_sees_a_ledger_change" || bad "differential_sees_a_ledger_change: mut=$MUT_OK rc=$rc diffs=$nd out=[$out]"

mutate_copy m-exit lib/repo.sh '^\(  emit ci absent "no \.github/workflows/\*\.y\*ml"\)\r\?$' '\1; return 1'
diff_case m-exit python:fresh:check-ci
[ "$MUT_OK" = 1 ] && [ "$rc" = 1 ] && [ "$nd" = 1 ] && printf '%s\n' "$out" | grep '^DIFF' | grep -q 'exit' \
  && ! printf '%s\n' "$out" | grep '^DIFF' | grep -q 'stdout' \
  && ok "differential_sees_an_exit_change" || bad "differential_sees_an_exit_change: mut=$MUT_OK rc=$rc diffs=$nd out=[$out]"

bash "$TOOLS/differential.sh" --min-cases 999 --only go:fresh:stack "$SKILL_DIR" "$SKILL_DIR" "$OUT/min" >"$TMPROOT/min.out" 2>&1; rc=$?
grep -q '^differential: 1 cases, 0 differ' "$TMPROOT/min.out" \
  && [ "$rc" = 1 ] && ok "differential_min_cases_guards_shrinkage" || bad "differential_min_cases_guards_shrinkage: rc=$rc [$(cat "$TMPROOT/min.out")]"

echo "== differential: a dead or silent shard is never a pass =="
two="--only go:fresh:stack --only go:rerun:stack"
DIFFERENTIAL_TEST_SHARD_FAULT=1:exit bash "$TOOLS/differential.sh" --jobs 2 $two "$SKILL_DIR" "$SKILL_DIR" "$OUT/dead" >"$TMPROOT/dead.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'shard 1 exited 9' "$TMPROOT/dead.out" && ! grep -q '^differential: [0-9]* cases' "$TMPROOT/dead.out" \
  && ok "differential_dead_shard_is_an_error" || bad "differential_dead_shard_is_an_error: rc=$rc [$(cat "$TMPROOT/dead.out")]"
DIFFERENTIAL_TEST_SHARD_FAULT=1:silent bash "$TOOLS/differential.sh" --jobs 2 $two "$SKILL_DIR" "$SKILL_DIR" "$OUT/silent" >"$TMPROOT/silent.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'collected 1 case lines, enumerated 2' "$TMPROOT/silent.out" && ! grep -q '^differential: [0-9]* cases' "$TMPROOT/silent.out" \
  && ok "differential_lost_shard_cases_are_an_error" || bad "differential_lost_shard_cases_are_an_error: rc=$rc [$(cat "$TMPROOT/silent.out")]"
echo "== differential: the git-common-dir half of files, the ritual.json mask, the mode field =="
# pre-registered: the hook-text mutant (lib/secretscan.sh, the hook's "not found" warning, written only
# into .git/hooks/pre-commit) gives exactly `DIFF files python:fresh:fix-secret-scan`, stdout equal
mutate_copy m-hook lib/secretscan.sh 'WARNING: gitleaks not found; staged changes were NOT scanned' 'WARNING: gitleaks not found; staged changes were not scanned'
diff_case m-hook python:fresh:fix-secret-scan
[ "$MUT_OK" = 1 ] && [ "$rc" = 1 ] && [ "$nd" = 1 ] && [ "$(printf '%s\n' "$out" | grep '^DIFF' | tr -d '\r')" = "DIFF files python:fresh:fix-secret-scan" ] \
  && ok "differential_sees_a_git_dir_change" || bad "differential_sees_a_git_dir_change: mut=$MUT_OK rc=$rc diffs=$nd out=[$out]"

# the mask: two ritual.json files that differ only in completed_at hash alike; any other field differs
. "$TOOLS/fixtures.sh"
mkdir -p "$TMPROOT/rj1" "$TMPROOT/rj2" "$TMPROOT/rj3" "$TMPROOT/rj4"
printf '%s\n' '{"completed_at":"2026-01-01","steps":{"a":1}}' > "$TMPROOT/rj1/ritual.json"
printf '%s\n' '{"completed_at":"2026-02-02","steps":{"a":1}}' > "$TMPROOT/rj2/ritual.json"
printf '%s\n' '{"completed_at":"2026-01-01","steps":{"a":2}}' > "$TMPROOT/rj3/ritual.json"
printf '%s\n' '{"completed_at":"2026-01-01","steps":{"a":1}}' > "$TMPROOT/rj4/other.json"
printf '%s\n' '{"completed_at":"2026-02-02","steps":{"a":1}}' > "$TMPROOT/rj2/other.json"
h1="$(fx_hash_file "$TMPROOT/rj1/ritual.json")"; h2="$(fx_hash_file "$TMPROOT/rj2/ritual.json")"; h3="$(fx_hash_file "$TMPROOT/rj3/ritual.json")"
o1="$(fx_hash_file "$TMPROOT/rj4/other.json")"; o2="$(fx_hash_file "$TMPROOT/rj2/other.json")"
[ -n "$h1" ] && [ "$h1" = "$h2" ] && [ "$h1" != "$h3" ] && [ "$o1" != "$o2" ] \
  && ok "differential_masks_only_completed_at" || bad "differential_masks_only_completed_at: [$h1] [$h2] [$h3] [$o1] [$o2]"
# the mode field: an octal mode precedes the hash in a hashed line (Git Bash derives it from content, so
# a dropped chmod is proved on Linux only)
printf '%s' "$h1" | grep -q '^[0-7][0-7][0-7]	[0-9a-f]\{64\}$' \
  && ok "differential_hash_line_carries_a_mode" || bad "differential_hash_line_carries_a_mode: [$h1]"
# the batched git-dir hash: one sha256sum for all files, and when it prints fewer lines than it was given
# files (it skips an unreadable one with only a stderr message), a per-file redo, so no hash lands on the
# next file's line. The shim stands in for that skip: it drops the first line of any multi-file call.
mkdir -p "$TMPROOT/shb" "$TMPROOT/shim"
for n in a b c; do printf '%s\n' "content $n" > "$TMPROOT/shb/$n"; done
want="$(for n in a b c; do sha256sum < "$TMPROOT/shb/$n" | cut -d' ' -f1; done)"
real_sha="$(command -v sha256sum)"
printf '%s\n' '#!/usr/bin/env bash' "n=0; for a in \"\$@\"; do case \"\$a\" in -*) ;; *) n=\$((n + 1)) ;; esac; done" \
  "if [ \"\$n\" -gt 1 ]; then \"$real_sha\" \"\$@\" | tail -n +2; else exec \"$real_sha\" \"\$@\"; fi" > "$TMPROOT/shim/sha256sum"
chmod +x "$TMPROOT/shim/sha256sum"
got="$(cd "$TMPROOT/shb" && fx_sha256_lines a b c)"
[ "$got" = "$want" ] && ok "sha256_batch_matches_per_file" || bad "sha256_batch_matches_per_file: [$got] want [$want]"
shim_lines="$(cd "$TMPROOT/shb" && PATH="$TMPROOT/shim:$PATH" sha256sum -b -- a b c | wc -l | tr -d ' ')"
got="$(cd "$TMPROOT/shb" && PATH="$TMPROOT/shim:$PATH" fx_sha256_lines a b c)"
[ "$shim_lines" = 2 ] && [ "$got" = "$want" ] \
  && ok "sha256_batch_redoes_per_file_when_a_line_is_missing" || bad "sha256_batch_redoes_per_file_when_a_line_is_missing: shim=$shim_lines [$got] want [$want]"

echo "== bench: a command that fails on one side is not a timing =="
# pre-registered: B's ritual.sh exits 3 first thing -> bench exits 1, names run 1, A 0 B 3
mutate_copy m-bench ritual.sh '^HERE=' 'exit 3; HERE='
out="$(bash "$TOOLS/bench.sh" "$SKILL_DIR" "$TMPROOT/m-bench" one-crate fresh 1 -- oracle '{repo}' 2>&1)"; rc=$?
[ "$MUT_OK" = 1 ] && [ "$rc" = 1 ] && printf '%s\n' "$out" | tr -d '\r' | grep -q 'bench: run 1: A exited 0, B exited 3' \
  && ! printf '%s\n' "$out" | grep -q 'paired median' \
  && ok "bench_aborts_when_the_sides_exit_differently" || bad "bench_aborts_when_the_sides_exit_differently: mut=$MUT_OK rc=$rc out=[$out]"

echo "== bench =="
out="$(bash "$TOOLS/bench.sh" "$SKILL_DIR" "$SKILL_DIR" one-crate fresh 2 -- oracle '{repo}' 2>&1)"; rc=$?
runs="$(printf '%s\n' "$out" | tr -d '\r' | grep -c '^A [0-9][0-9]* B [0-9][0-9]* d -\{0,1\}[0-9][0-9]*$')"
printf '%s\n' "$out" | tr -d '\r' | grep -q '^paired median d=-\{0,1\}[0-9][0-9]*ms (n=2)$' && med=1 || med=0
[ "$rc" = 0 ] && [ "$runs" = 2 ] && [ "$med" = 1 ] \
  && ok "bench_reports_paired_median" || bad "bench_reports_paired_median: rc=$rc runs=$runs med=$med out=[$out]"

finish
