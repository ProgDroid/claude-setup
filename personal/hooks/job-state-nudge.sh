#!/usr/bin/env bash
# PostToolUse:Bash|PowerShell -- the job-state nudge.
#
# WHY THIS EXISTS
#   Two lessons in learnings/probe-failures.md kept recurring while living only as prose
#   (routed 2026-10-05 from the escalation queue, design doc section 19):
#
#     section 10  A background job's SILENCE proves nothing until you have seen it
#                 produce output; wait for a terminal marker, not a growth curve.
#     section 17  A log fetch (docker logs, journalctl, modal app logs, gh run view
#                 --log) reports BYTES, never job state: running, finished and killed
#                 jobs can print identical tails.
#
#   Like negative-result-guard.sh, this does not try to DETECT the mistake, which no
#   regex can. It notices the moment the mistake becomes possible -- a job went to the
#   background, or a log window was fetched -- and says the one sentence that matters.
#   Model-facing only (additionalContext); nothing is shown to the user.
#
# TRIGGERS, from MEASURED shapes (a real transcript's toolUseResult, 2026-10-05):
#   - tool_response.backgroundTaskId is a non-empty string. Present for
#     run_in_background AND for a foreground command the harness moved to the
#     background at its timeout -- the second case is the one nobody plans for.
#   - tool_input.command fetches a log window, at a command position.
#
# NEVER fails the session: always exits 0.

set -uo pipefail

json_input=$(cat)

# Cheap pre-filter: this runs on every Bash call and process creation is expensive on
# Windows. Only false positives can survive it; the real checks below reject them.
printf '%s' "$json_input" | grep -qE 'backgroundTaskId|logs|journalctl|--log' || exit 0

command -v jq >/dev/null 2>&1 || exit 0

bg=$(printf '%s' "$json_input" | jq -r '(.tool_response | objects | .backgroundTaskId) // empty' 2>/dev/null)
cmd=$(printf '%s' "$json_input" | jq -r '.tool_input.command // empty' 2>/dev/null)

ctx=""

if [ -n "$bg" ]; then
  ctx="BACKGROUND JOB. Its silence proves nothing until you have seen it produce output. Wait for the completion notification, then read a terminal marker the command writes LAST (REAL_EXIT=, a done line) -- not a growth curve, and not the notification's exit code if the command was a pipeline or a chain."
fi

# Anchored at a command position (start, or after ; | & && || or an open paren) so a
# filename such as docker-logs.txt or a grep over logs/ does not qualify.
if [ -n "$cmd" ] && printf '%s' "$cmd" | grep -qE '(^|[;&|(]|&&|\|\|)[[:space:]]*((docker([[:space:]]+compose)?|docker-compose|podman|kubectl|flyctl|fly|heroku|railway)[[:space:]]+logs([[:space:]]|$)|modal[[:space:]]+app[[:space:]]+logs([[:space:]]|$)|journalctl([[:space:]]|$)|gh[[:space:]]+run[[:space:]]+view([[:space:]][^;&|]*)?[[:space:]]--log(-failed)?([[:space:]]|$))'; then
  log="LOG WINDOW. A log fetch reports bytes, not job state: a running, a finished and a killed job can print identical tails. Before calling it finished, ask the scheduler for state (docker inspect, gh run view --json status, modal app list) AND grep for a terminal marker the program writes last."
  ctx="${ctx:+$ctx }$log"
fi

[ -n "$ctx" ] || exit 0

jq -n --arg ctx "$ctx" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}'

exit 0
