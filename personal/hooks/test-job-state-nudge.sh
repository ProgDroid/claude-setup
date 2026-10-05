#!/usr/bin/env bash
# Tests for job-state-nudge.sh.
#
# Run:  bash personal/hooks/test-job-state-nudge.sh
#
# Payloads are built with jq -n, never hand-escaped printf: a malformed fixture makes
# jq return empty, the hook exits early, and every NO case passes vacuously (the
# every-case-agreed failure recorded in learnings/probe-failures.md).

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/job-state-nudge.sh"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

# ctx <tool> <command> <bg-id or "-" for absent>  -> the additionalContext, or nothing
ctx() {
  local tool="$1" cmd="$2" bg="$3"
  if [ "$bg" = "-" ]; then
    jq -n --arg t "$tool" --arg c "$cmd" \
      '{tool_name:$t, tool_input:{command:$c}, tool_response:{stdout:"", stderr:"", interrupted:false, isImage:false, noOutputExpected:false}}'
  else
    jq -n --arg t "$tool" --arg c "$cmd" --arg b "$bg" \
      '{tool_name:$t, tool_input:{command:$c}, tool_response:{stdout:"", stderr:"", interrupted:false, isImage:false, noOutputExpected:false, backgroundTaskId:$b}}'
  fi | bash "$HOOK" 2>/dev/null | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null
}
has() { printf '%s' "$1" | grep -q "$2" && echo YES || echo NO; }

echo "== background jobs (backgroundTaskId, shape measured 2026-10-05) =="

[ "$(has "$(ctx Bash 'cargo test > log.txt 2>&1' bu13rwo6q)" 'BACKGROUND JOB')" = YES ] \
  && ok "a backgrounded command gets the nudge" || bad "no nudge on a backgrounded command"
[ "$(has "$(ctx Bash 'cargo test > log.txt 2>&1' -)" 'BACKGROUND JOB')" = NO ] \
  && ok "a foreground command does not" || bad "nudged a foreground command"
[ "$(has "$(ctx Bash 'cargo test' '')" 'BACKGROUND JOB')" = NO ] \
  && ok "an empty backgroundTaskId does not" || bad "nudged on an empty backgroundTaskId"

echo "== log-window commands =="

for c in 'docker logs app' 'docker compose logs -f web' 'kubectl logs pod/x' 'modal app logs ap-123' \
         'journalctl -u svc --since today' 'gh run view 123 --log' 'cd x && docker logs y'; do
  [ "$(has "$(ctx Bash "$c" -)" 'LOG WINDOW')" = YES ] && ok "log window: $c" || bad "missed log window: $c"
done
# The echo case is the only one that exercises the command-position ANCHOR: without
# it, "docker logs " mid-line would match. The other three stay silent either way.
for c in 'gh run view 123 --json conclusion' 'cat docker-logs.txt' 'grep error logs/app.log' 'echo run docker logs app to see it'; do
  [ "$(has "$(ctx Bash "$c" -)" 'LOG WINDOW')" = NO ] && ok "not a log window: $c" || bad "false log window: $c"
done

echo "== PowerShell tool, and both triggers at once =="

[ "$(has "$(ctx PowerShell 'docker logs app' -)" 'LOG WINDOW')" = YES ] \
  && ok "PowerShell log fetch gets the nudge" || bad "missed a PowerShell log fetch"
both=$(ctx Bash 'docker logs -f app' bx1)
[ "$(has "$both" 'BACKGROUND JOB')" = YES ] && [ "$(has "$both" 'LOG WINDOW')" = YES ] \
  && ok "a backgrounded log follow gets both" || bad "did not combine both nudges"

echo "== never fires on junk =="

out=$(printf 'not json at all' | bash "$HOOK" 2>/dev/null)
[ -z "$out" ] && ok "malformed input stays silent" || bad "fired on malformed input"
out=$(jq -n '{tool_name:"Write", tool_input:{file_path:"logs/a.md"}, tool_response:{filePath:"logs/a.md"}}' | bash "$HOOK" 2>/dev/null)
[ -z "$out" ] && ok "a Write mentioning logs stays silent" || bad "fired on a Write"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
