#!/usr/bin/env bash
# Tests for scripts/check-rules-budget.sh, scripts/privacy-scan.sh, scripts/run-all-tests.sh.
#
# Run:  bash core/tests/test-scripts.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUDGET="$REPO/scripts/check-rules-budget.sh"
SCAN="$REPO/scripts/privacy-scan.sh"
RUNNER="$REPO/scripts/run-all-tests.sh"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# mkfile <path> <n> <char>  -> file of exactly n chars (no newline)
mkfile() { mkdir -p "$(dirname "$1")"; local i s=""; for ((i = 0; i < $2; i++)); do s+="$3"; done; printf '%s' "$s" > "$1"; }

# expect_exit <label> <want> <cmd...>
expect_exit() {
  local label="$1" want="$2"; shift 2
  "$@" >"$T/out" 2>&1; local got=$?
  [ "$got" -eq "$want" ] && ok "$label (exit $got)" || bad "$label: wanted exit $want, got $got"
}

echo "== budget =="
mkfile "$T/b1/a.md" 8999 x
expect_exit "8999 chars passes" 0 bash "$BUDGET" "$T/b1" 9000
grep -q 'rules: 8999 chars (limit 9000)' "$T/out" && ok "output line format" || bad "output line: $(cat "$T/out")"
mkfile "$T/b2/a.md" 9000 x
expect_exit "9000 chars fails (limit exclusive)" 1 bash "$BUDGET" "$T/b2" 9000
mkfile "$T/b3/a.md" 9001 x
expect_exit "9001 chars fails" 1 bash "$BUDGET" "$T/b3" 9000
mkfile "$T/b4/a.md" 10 é
bash "$BUDGET" "$T/b4" 9000 > "$T/out" 2>&1
grep -q 'rules: 10 chars' "$T/out" && ok "multi-byte counts chars not bytes" || bad "multibyte: $(cat "$T/out")"
mkdir -p "$T/b5"
expect_exit "empty dir is UNKNOWN (2)" 2 bash "$BUDGET" "$T/b5" 9000
mkfile "$T/b6/a.md" 5000 x; mkfile "$T/b6/sub/b.md" 4000 x
expect_exit "sums across files incl. subdirs" 1 bash "$BUDGET" "$T/b6" 9000

echo "== privacy =="
printf 'canary-zq81\n' > "$T/pat.txt"
mkdir -p "$T/p1"; printf 'ok\nhas canary-zq81 here\n' > "$T/p1/f.txt"
expect_exit "hit exits 1" 1 bash "$SCAN" --patterns "$T/pat.txt" "$T/p1"
grep -q ':2:canary-zq81' "$T/out" && ok "hit names line and pattern" || bad "hit line: $(cat "$T/out")"
mkdir -p "$T/p2"; printf 'nothing here\n' > "$T/p2/f.txt"
expect_exit "clean exits 0" 0 bash "$SCAN" --patterns "$T/pat.txt" "$T/p2"
expect_exit "missing pattern file exits 2" 2 bash "$SCAN" --patterns "$T/nope.txt" "$T/p2"
printf '# only a comment\n\n' > "$T/empty.txt"
expect_exit "pattern file with no patterns exits 2" 2 bash "$SCAN" --patterns "$T/empty.txt" "$T/p2"
mkdir -p "$T/p 3/sub dir"; printf 'canary-zq81\n' > "$T/p 3/sub dir/f.txt"
expect_exit "path with spaces scanned" 1 bash "$SCAN" --patterns "$T/pat.txt" "$T/p 3"
mkdir -p "$T/p4/.git" "$T/p4/node_modules/x"; printf 'canary-zq81\n' > "$T/p4/.git/c"; printf 'canary-zq81\n' > "$T/p4/node_modules/x/c"
expect_exit ".git and node_modules skipped" 0 bash "$SCAN" --patterns "$T/pat.txt" "$T/p4"
printf '# comment\ncanary-zq81\n' > "$T/pat2.txt"
expect_exit "comments ignored, real pattern used" 1 bash "$SCAN" --patterns "$T/pat2.txt" "$T/p1"
# an unusable scan is UNKNOWN (2), never clean: invalid ERE, and a path that does not exist
printf 'a(b\n' > "$T/badpat.txt"; mkdir -p "$T/p5"; printf 'a(b\n' > "$T/p5/f.txt"
expect_exit "invalid ERE in pattern file exits 2 (not clean)" 2 bash "$SCAN" --patterns "$T/badpat.txt" "$T/p5"
grep -q 'invalid pattern: a(b' "$T/out" && ok "invalid pattern is named on stderr" || bad "invalid pattern message: $(cat "$T/out")"
printf 'canary-zq81\na(b\n' > "$T/mixpat.txt"
expect_exit "valid hit plus invalid pattern still exits 2" 2 bash "$SCAN" --patterns "$T/mixpat.txt" "$T/p1"
expect_exit "nonexistent scan path exits 2" 2 bash "$SCAN" --patterns "$T/pat.txt" "$T/no-such-dir"
expect_exit "one real path plus one missing path exits 2" 2 bash "$SCAN" --patterns "$T/pat.txt" "$T/p1" "$T/no-such-dir"
printf 'CaNaRy-ZQ81\n' > "$T/p6.txt"; printf 'canary-zq81\n' > "$T/pat-ci.txt"
expect_exit "matching is case-insensitive" 1 bash "$SCAN" --patterns "$T/pat-ci.txt" "$T/p6.txt"
grep -q 'p6.txt:1:canary-zq81' "$T/out" && ok "single-file scan names the file" || bad "single-file output: $(cat "$T/out")"

echo "== runner =="
R="$T/r1"; mkdir -p "$R/core/tests" "$R/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/core/tests/test-good.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$R/core/tests/test-bad.sh"
bash "$RUNNER" "$R" > "$T/out" 2>&1; rc=$?
[ "$(tail -n 1 "$T/out")" = "REAL_EXIT=1" ] && ok "last line REAL_EXIT=1" || bad "last line: $(tail -n 1 "$T/out")"
grep -q 'ran 2, failed 1' "$T/out" && ok "counts ran 2, failed 1" || bad "counts: $(grep '^ran' "$T/out")"
[ "$rc" -eq 1 ] && ok "process exit 1" || bad "process exit $rc"
R2="$T/r2"; mkdir -p "$R2/core/tests" "$R2/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R2/core/tests/test-good.sh"
bash "$RUNNER" "$R2" > "$T/out" 2>&1; rc=$?
[ "$(tail -n 1 "$T/out")" = "REAL_EXIT=0" ] && [ "$rc" -eq 0 ] && ok "all-pass gives REAL_EXIT=0" || bad "all-pass: rc=$rc $(tail -n 2 "$T/out")"
# ran 0 is a failure, not a pass
R0="$T/r0"; mkdir -p "$R0/scripts"
bash "$RUNNER" "$R0" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$(tail -n 1 "$T/out")" = "REAL_EXIT=1" ] && grep -q 'ran 0' "$T/out" && ok "ran 0 exits 1" || bad "ran 0: rc=$rc $(tail -n 3 "$T/out")"
# a test file on disk that the globs miss (nested deeper than any glob) is reported, not ignored
R5="$T/r5"; mkdir -p "$R5/core/tests" "$R5/core/skills/x/tests"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R5/core/tests/test-good.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R5/core/skills/x/tests/test-orphan.sh"
bash "$RUNNER" "$R5" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ "$(tail -n 1 "$T/out")" = "REAL_EXIT=1" ] && grep -q 'core/skills/x/tests/test-orphan.sh' "$T/out" \
  && ok "test file missed by the globs fails the run and is named" || bad "missed file: rc=$rc $(tail -n 5 "$T/out")"
grep -q 'ran 1, failed 1' "$T/out" && ok "missed-file run still counts what it ran" || bad "missed-file counts: $(grep '^ran' "$T/out")"
# control: the same tree without the orphan passes, so the failure above is the orphan and not the fixture
rm "$R5/core/skills/x/tests/test-orphan.sh"
expect_exit "control: no orphan, same tree passes" 0 bash "$RUNNER" "$R5"
# --scope core: only the core/ globs run, and the independent on-disk count covers core/ only
RS="$T/rs"; mkdir -p "$RS/core/tests" "$RS/personal/hooks" "$RS/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RS/core/tests/test-good.sh"
printf '#!/usr/bin/env bash\necho ran > "%s/personal-ran"\nexit 1\n' "$T" > "$RS/personal/hooks/test-bad.sh"
bash "$RUNNER" "$RS" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && [ -e "$T/personal-ran" ] && grep -q 'ran 2, failed 1' "$T/out" && ok "control: without the flag the failing personal test runs and fails the run" || bad "scope control: rc=$rc $(grep '^ran' "$T/out")"
rm -f "$T/personal-ran"
bash "$RUNNER" --scope core "$RS" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$T/personal-ran" ] && grep -q '^ran 1, failed 0, skipped 0$' "$T/out" && [ "$(tail -n 1 "$T/out")" = "REAL_EXIT=0" ] \
  && ok "--scope core does not run personal tests (ran 1, failed 0)" || bad "scope core: rc=$rc ran-marker=$([ -e "$T/personal-ran" ] && echo yes || echo no) $(grep '^ran' "$T/out")"
bash "$RUNNER" "$RS" --scope core > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q '^ran 1, failed 0' "$T/out" && ok "root positional before the flag also works" || bad "root-then-flag: rc=$rc $(grep '^ran' "$T/out")"
bash "$RUNNER" --scope=core "$RS" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q '^ran 1, failed 0' "$T/out" && ok "--scope=core form works" || bad "--scope=core: rc=$rc $(grep '^ran' "$T/out")"
printf '#!/usr/bin/env bash\nexit 1\n' > "$RS/core/tests/test-corebad.sh"
bash "$RUNNER" --scope core "$RS" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q '^ran 2, failed 1' "$T/out" && ok "a failing core test fails --scope core" || bad "core fail: rc=$rc $(grep '^ran' "$T/out")"
rm "$RS/core/tests/test-corebad.sh"
# the independent count: an unreachable personal test file is not core's business, an unreachable core one is
mkdir -p "$RS/personal/skills/x/tests/deep" "$RS/core/skills/y/tests/deep"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RS/personal/skills/x/tests/deep/test-orphan.sh"
bash "$RUNNER" --scope core "$RS" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "personal orphan is outside the core on-disk count" || bad "personal orphan under scope: rc=$rc $(tail -n 4 "$T/out")"
bash "$RUNNER" "$RS" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'personal/skills/x/tests/deep/test-orphan.sh' "$T/out" && ok "control: the same personal orphan fails the unscoped run" || bad "personal orphan unscoped: rc=$rc $(tail -n 4 "$T/out")"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RS/core/skills/y/tests/deep/test-orphan.sh"
bash "$RUNNER" --scope core "$RS" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'core/skills/y/tests/deep/test-orphan.sh' "$T/out" && ok "a core orphan still fails --scope core" || bad "core orphan under scope: rc=$rc $(tail -n 4 "$T/out")"
# OpenCode (personal/opencode, bun) is not run under the flag
RB="$T/rb"; mkdir -p "$RB/core/tests" "$RB/personal/opencode/test" "$RB/fakebin" "$RB/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$RB/core/tests/test-good.sh"; : > "$RB/personal/opencode/test/a.test.js"
printf '#!/usr/bin/env bash\necho called > "%s/bun-scope-called"\nexit 0\n' "$T" > "$RB/fakebin/bun"; chmod +x "$RB/fakebin/bun"
PATH="$RB/fakebin:$PATH" bash "$RUNNER" "$RB" > "$T/out" 2>&1
[ -e "$T/bun-scope-called" ] && ok "control: unscoped run calls the fake bun" || bad "bun control: fake bun not called ($(grep -c bun "$T/out") bun lines)"
rm -f "$T/bun-scope-called"
PATH="$RB/fakebin:$PATH" bash "$RUNNER" --scope core "$RB" > "$T/out" 2>&1; rc=$?
[ ! -e "$T/bun-scope-called" ] && [ "$rc" -eq 0 ] && ok "--scope core does not call bun" || bad "bun under scope: rc=$rc called=$([ -e "$T/bun-scope-called" ] && echo yes || echo no)"
# a scope with nothing to run is still a failure, and an unknown scope is rejected
R6="$T/r6"; mkdir -p "$R6/personal/hooks" "$R6/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R6/personal/hooks/test-p.sh"
bash "$RUNNER" --scope core "$R6" > "$T/out" 2>&1; rc=$?
[ "$rc" -eq 1 ] && grep -q 'ran 0' "$T/out" && ok "--scope core with no core tests: ran 0 fails" || bad "scope ran 0: rc=$rc $(tail -n 3 "$T/out")"
expect_exit "unknown scope exits 2" 2 bash "$RUNNER" --scope bogus "$RS"
expect_exit "bare trailing --scope exits 2 (not silently unscoped)" 2 bash "$RUNNER" "$RS" --scope
expect_exit "--scope= with no value exits 2" 2 bash "$RUNNER" --scope= "$RS"
expect_exit "--scope followed by an empty value exits 2" 2 bash "$RUNNER" --scope "" "$RS"
if [ "$(uname -s)" = Linux ]; then
  R3="$T/r3"; mkdir -p "$R3/core/tests" "$R3/scripts"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$R3/core/tests/test-win.sh"
  printf 'core/tests/test-win.sh # windows only\n' > "$R3/scripts/linux-skip.txt"
  bash "$RUNNER" "$R3" > "$T/out" 2>&1
  grep -q 'ran 0, failed 1, skipped 1' "$T/out" && ok "linux-skip.txt entry skipped (and ran 0 fails)" || bad "skip: $(grep '^ran' "$T/out")"
  # every bun test file skipped: bun must not be called with no file arguments (it would run everything)
  R4="$T/r4"; mkdir -p "$R4/core/tests" "$R4/scripts" "$R4/personal/opencode/test" "$R4/fakebin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$R4/core/tests/test-good.sh"
  : > "$R4/personal/opencode/test/a.test.js"
  printf 'personal/opencode/test/a.test.js # skipped\n' > "$R4/scripts/linux-skip.txt"
  printf '#!/usr/bin/env bash\necho called > "%s/bun-called"\nexit 0\n' "$T" > "$R4/fakebin/bun"; chmod +x "$R4/fakebin/bun"
  PATH="$R4/fakebin:$PATH" bash "$RUNNER" "$R4" > "$T/out" 2>&1; rc=$?
  [ ! -e "$T/bun-called" ] && [ "$rc" -eq 0 ] && ok "bun not invoked with an empty file list" || bad "empty bunfiles: rc=$rc"
  # control: with the file not skipped, the fake bun IS invoked
  : > "$R4/scripts/linux-skip.txt"
  PATH="$R4/fakebin:$PATH" bash "$RUNNER" "$R4" > "$T/out" 2>&1
  [ -e "$T/bun-called" ] && ok "control: fake bun is invoked when a file remains" || bad "control: fake bun not invoked"
fi

echo "== capture-learnings (promotion flow wording) =="
CL="$REPO/core/skills/capture-learnings/SKILL.md"
grep -q 'CLAUDE_SETUP_CLONE' "$CL" && ok "capture-learnings names CLAUDE_SETUP_CLONE" || bad "capture-learnings lacks CLAUDE_SETUP_CLONE"
grep -q 'only if .*probe-failures.md. exists' "$CL" && ok "recurred: append is conditional on probe-failures.md existing" || bad "capture-learnings lacks the only-if-exists guard"
grep -q 'Promotion flow (home only)' "$CL" && ok "promotion flow section present (the name synthesize-memories points at)" || bad "capture-learnings lacks the Promotion flow section"
for s in capture-learnings sdd-controller working-style; do
  if [ -f "$REPO/core/skills/$s/SKILL.md" ] && [ ! -e "$REPO/personal/skills/$s" ]; then ok "$s lives in core, not personal"; else bad "$s is not cleanly moved to core"; fi
done

echo "== probe-discipline (every tell in the rules has a case entry, and the reverse) =="
SH="$REPO/core/rules/shared.md"; PD="$REPO/core/skills/probe-discipline/SKILL.md"
awk '/^## /{on = ($0 == "## Probe discipline")} on && /^- \*\*/ {s = $0; sub(/^- \*\*/, "", s); sub(/\*\*.*$/, "", s); gsub(/`/, "", s); print s}' "$SH" | LC_ALL=C sort > "$T/tells.txt"
awk '/^### /{s = $0; sub(/^### /, "", s); gsub(/`/, "", s); print s}' "$PD" | LC_ALL=C sort > "$T/entries.txt"
ntell=$(wc -l < "$T/tells.txt" | tr -d ' ')
[ "$ntell" -gt 0 ] && ok "probe sees $ntell tells in shared.md (count > 0)" || bad "no tells found in shared.md: the probe cannot see"
missing=$(LC_ALL=C comm -23 "$T/tells.txt" "$T/entries.txt")
[ -z "$missing" ] && ok "every tell has a ### entry in probe-discipline" || bad "tells with no entry: $missing"
orphan=$(LC_ALL=C comm -13 "$T/tells.txt" "$T/entries.txt")
[ -z "$orphan" ] && ok "every ### entry has a tell in shared.md" || bad "entries with no tell: $orphan"
# control: the comparison can fail (a tell renamed in a copy is reported missing)
ctl=$(printf 'renamed-tell\n' | LC_ALL=C comm -23 - "$T/entries.txt")
[ "$ctl" = "renamed-tell" ] && ok "control: an unmatched tell is reported" || bad "control: comm did not report the planted tell ($ctl)"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
