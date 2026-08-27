#!/bin/bash
# red-team gate -- fires after a superpowers spec or plan is written.
# Injects a requirement to run a hostile review in a FRESH subagent before proceeding.
#
#   spec gate : docs/superpowers/specs/<date>-<topic>-design.md   (is this the right thing to build?)
#   plan gate : docs/superpowers/plans/<date>-<feature>.md        (will this plan actually produce it?)
#
# Deliberately matches Write only, not Edit -- the gate belongs at artifact creation,
# not on every subsequent touch-up.
#
# DELEGATION (2026-08-27): when gstack is installed, the fresh subagent is told to run
# Garry Tan's review lenses instead of carrying our inline prompt, so he maintains them
# and they auto-update. The FRESH-SUBAGENT requirement is preserved either way -- gstack
# lenses run inline in the calling session, which is precisely the anchoring failure this
# gate exists to prevent, so the lens is invoked BY the subagent, never by the writer.
# Falls back to the inline prompt when gstack is absent (notably in cloud sessions, where
# a user-scope skills install does not exist).

json_input=$(cat)

if command -v jq >/dev/null 2>&1; then
    file_path=$(echo "$json_input" | jq -r '.tool_response.filePath // .tool_input.file_path // empty')
else
    file_path=$(echo "$json_input" \
        | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' \
        | head -1 \
        | sed 's/.*"file_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
fi

[[ -z "$file_path" ]] && exit 0

# normalise Windows backslashes so the path patterns match
norm="${file_path//\\//}"

case "$norm" in
    */docs/superpowers/specs/*-design.md) kind="spec" ;;
    */docs/superpowers/plans/*.md)        kind="plan" ;;
    *) exit 0 ;;
esac

# gstack detection. The skills dir is created by gstack's ./setup for every host,
# prefixed or not, so it is the stable marker. Absent in cloud sessions.
gstack=0
[[ -d "$HOME/.claude/skills/gstack" ]] && gstack=1

# NOTE: message text is kept free of double quotes and newlines so the no-jq
# fallback below can emit valid JSON with a plain printf.
if [[ "$kind" == "spec" ]]; then
    short='Red-team gate: spec written -- hostile design review required before planning.'
    if [[ "$gstack" -eq 1 ]]; then
        msg="RED-TEAM GATE (spec). A design spec was just written to ${norm}. Before invoking superpowers:writing-plans, dispatch a general-purpose subagent with FRESH context and instruct it to: read ${norm}; then invoke the gstack-plan-ceo-review skill and the gstack-plan-design-review skill against it; and report the strongest objections each lens raises, plus its own answer to -- is there a simpler design that gets 80 percent of the value. Run the lenses INSIDE the subagent, not here: you wrote the spec and are anchored to it, which is the exact failure a fresh context exists to avoid. Report the objections to the user and wait for their decision before writing any plan."
    else
        msg="RED-TEAM GATE (spec). A design spec was just written to ${norm}. Before invoking superpowers:writing-plans, dispatch a general-purpose subagent with FRESH context to attack it. The subagent prompt must instruct it to: read ${norm}; act as a hostile staff engineer whose job is to find why this is the WRONG THING TO BUILD; and report its 3 strongest objections across -- (a) a simpler design that gets 80 percent of the value, (b) a requirement that is assumed rather than established, (c) the constraint this design will collide with in 6 months. Do NOT run this review inline: you wrote the spec and are anchored to it, which is the exact failure a fresh context exists to avoid. Report the objections to the user and wait for their decision before writing any plan."
    fi
else
    short='Red-team gate: plan written -- hostile execution review required before implementing.'
    if [[ "$gstack" -eq 1 ]]; then
        msg="RED-TEAM GATE (plan). An implementation plan was just written to ${norm}. Before executing it, dispatch a general-purpose subagent with FRESH context and instruct it to: read ${norm} and the spec it references; then invoke the gstack-plan-eng-review skill and the gstack-plan-devex-review skill against it; and report the strongest objections each lens raises, plus its own answer to -- what does this plan assume about the current codebase that may be false, naming specific files it should verify. Run the lenses INSIDE the subagent, not here: you wrote the plan and are anchored to it. Report the objections to the user and wait for their decision before executing."
    else
        msg="RED-TEAM GATE (plan). An implementation plan was just written to ${norm}. Before executing it, dispatch a general-purpose subagent with FRESH context to attack it. The subagent prompt must instruct it to: read ${norm} and the spec it references; act as a hostile staff engineer whose job is to find why this plan FAILS; and report its 3 strongest objections across -- (a) whether executing these tasks actually produces what the spec asked for, (b) what the plan assumes about the current codebase that may be false (name specific files it should verify), (c) what breaks in 6 months. Do NOT run this review inline: you wrote the plan and are anchored to it. Report the objections to the user and wait for their decision before executing."
    fi
fi

if command -v jq >/dev/null 2>&1; then
    jq -n --arg sm "$short" --arg ctx "$msg" \
        '{systemMessage:$sm, hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}'
else
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' \
        "$short" "$msg"
fi

exit 0
