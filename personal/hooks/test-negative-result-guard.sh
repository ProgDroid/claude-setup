#!/usr/bin/env bash
# Tests for negative-result-guard.sh.
#
# Run:  bash personal/hooks/test-negative-result-guard.sh
#
# The payload shape for a Bash PostToolUse is NOT verified here -- these tests cover
# both plausible field names (stdout / output) plus the string form, and separately
# assert that an UNKNOWN shape stays silent rather than guessing. That is the whole
# safety property: a guard that fires on a shape it does not understand is worse
# than one that does nothing.

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/negative-result-guard.sh"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

# fired <command> <output> [field]  -> YES | NO
fired() {
  local field="${3:-stdout}"
  jq -n --arg c "$1" --arg o "$2" --arg f "$field" \
     '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{($f):$o}}' \
    | bash "$HOOK" 2>/dev/null \
    | jq -r 'if (.hookSpecificOutput.additionalContext // "") | test("NEGATIVE RESULT") then "YES" else "NO" end' 2>/dev/null \
    | grep -q YES && echo YES || echo NO
}

echo "== fires on a genuinely empty search =="

for c in 'grep -rn "needle" .' 'rg needle src/' 'find . -name "*.md"' 'git ls-files | grep x' 'git grep needle' 'git branch -r --contains abc123'; do
  [ "$(fired "$c" "")" = YES ] \
    && ok "empty result warns: $c" \
    || bad "did not warn on empty: $c"
done

echo "== does not fire when the search FOUND something =="

[ "$(fired 'grep -rn "needle" .' "src/a.py:12: needle")" = NO ] \
  && ok "a non-empty grep result does not warn" \
  || bad "warned despite output"

[ "$(fired 'find . -name "*.md"' "./README.md")" = NO ] \
  && ok "a non-empty find result does not warn" \
  || bad "warned despite output"

echo "== does not fire when silence was REQUESTED =="

# These print nothing by design; treating them as absence is the false-positive
# class this guard exists to avoid becoming.
[ "$(fired 'grep -q needle file' "")" = NO ] \
  && ok "grep -q does not warn" \
  || bad "warned on grep -q, which is silent by design"

[ "$(fired 'grep -rq needle .' "")" = NO ] \
  && ok "clustered -rq does not warn" \
  || bad "warned on clustered -rq"

[ "$(fired 'grep -c needle file' "")" = NO ] \
  && ok "grep -c does not warn" \
  || bad "warned on grep -c, which prints a count"

[ "$(fired 'rg --count needle' "")" = NO ] \
  && ok "--count does not warn" \
  || bad "warned on --count"

[ "$(fired 'grep -rn needle . > /dev/null' "")" = NO ] \
  && ok "output sent to /dev/null does not warn" \
  || bad "warned when output went to /dev/null"

[ "$(fired 'grep -rn needle . > results.txt' "")" = NO ] \
  && ok "output redirected to a file does not warn" \
  || bad "warned when output was redirected to a file"

echo "== the -q/-c heuristic must not leak outside grep/rg =="

# "exec" ends in c. Applied globally the flag test would silently disable the guard
# for the most common find form, which is exactly the kind of quiet over-suppression
# that makes a rule useless.
[ "$(fired 'find . -name "*.py" -exec ls {} ;' "")" = YES ] \
  && ok "find -exec still warns (the -c heuristic is grep-only)" \
  || bad "find -exec was suppressed by the grep -c heuristic"

echo "== 2>&1 is not a results redirect =="

[ "$(fired 'grep -rn needle . 2>&1' "")" = YES ] \
  && ok "2>&1 does not count as redirecting results" \
  || bad "2>&1 was misread as a redirect"

echo "== non-search commands are out of scope =="

for c in 'ls -la' 'cat README.md' 'echo hi' 'git status --short' 'pytest -q'; do
  [ "$(fired "$c" "")" = NO ] \
    && ok "not a search, no warning: $c" \
    || bad "warned on a non-search command: $c"
done

echo "== payload shape handling =="

[ "$(fired 'grep -rn needle .' "" "output")" = YES ] \
  && ok "reads the 'output' field too" \
  || bad "did not read an 'output' field"

# tool_response as a bare string
out=$(jq -n --arg c 'grep -rn needle .' '{tool_name:"Bash", tool_input:{command:$c}, tool_response:""}' | bash "$HOOK" 2>/dev/null)
printf '%s' "$out" | grep -q "NEGATIVE RESULT" \
  && ok "handles tool_response as a bare string" \
  || bad "did not handle a string tool_response"

# no tool_response at all -> silent
out=$(jq -n --arg c 'grep -rn needle .' '{tool_name:"Bash", tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null)
[ -z "$out" ] \
  && ok "no tool_response at all stays silent" \
  || bad "fired with no tool_response present"

# UNKNOWN shape -> silent AND logged. This is the safety property.
tmphome="$(mktemp -d)"; mkdir -p "$tmphome/.claude"
out=$(jq -n --arg c 'grep -rn needle .' \
        '{tool_name:"Bash", tool_input:{command:$c}, tool_response:{someNewField:"x"}}' \
      | HOME="$tmphome" bash "$HOOK" 2>/dev/null)
[ -z "$out" ] \
  && ok "an unrecognised tool_response shape stays silent" \
  || bad "fired on a shape it does not understand"

[ -s "$tmphome/.claude/negative-result-guard.debug" ] \
  && ok "an unrecognised shape is logged for diagnosis" \
  || bad "unrecognised shape was not logged"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
