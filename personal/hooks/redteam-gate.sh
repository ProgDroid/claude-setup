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
#
# NARROWED 2026-09-06. From 2026-08-27 this swapped the whole review out for four
# gstack lenses, and three of them were wrong for the projects it actually fires on:
#
#   plan-design-review  rates UI/UX dimensions 0-10 and points at live site audits
#   plan-devex-review   explores developer personas and benchmarks competitors
#   plan-ceo-review     triggers on think-bigger and expand-scope
#
# On a solo data pipeline with no UI and one user, the first two are category errors
# and the third pushes scope UP, which is the opposite of the question worth asking.
# The delegation also landed one day after the inline prompt was written, so the
# version that worked got a single day of use.
#
# Only plan-eng-review earns its place -- architecture, data flow, edge cases, test
# coverage -- and it is now an ADDITION to the inline prompt, never a replacement.
# The spec gate no longer consults gstack at all: its three questions are already
# project-agnostic and are the ones that matter before anything is built.
gstack=0
[[ -d "$HOME/.claude/skills/gstack" ]] && gstack=1

# NOTE: message text is kept free of double quotes and newlines so the no-jq
# fallback below can emit valid JSON with a plain printf.
if [[ "$kind" == "spec" ]]; then
    short='Red-team gate: spec written -- hostile design review required before planning.'
    msg="RED-TEAM GATE (spec). A design spec was just written to ${norm}. Before invoking superpowers:writing-plans, dispatch a general-purpose subagent with FRESH context to attack it. The subagent prompt must instruct it to: read ${norm}; act as a hostile staff engineer whose job is to find why this is the WRONG THING TO BUILD; and report its 3 strongest objections across -- (a) a simpler design that gets 80 percent of the value, (b) a requirement that is assumed rather than established, (c) the constraint this design will collide with in 6 months. Do NOT run this review inline: you wrote the spec and are anchored to it, which is the exact failure a fresh context exists to avoid. Report the objections to the user and wait for their decision before writing any plan."
else
    short='Red-team gate: plan written -- hostile execution review required before implementing.'
    msg="RED-TEAM GATE (plan). An implementation plan was just written to ${norm}. Before executing it, dispatch a general-purpose subagent with FRESH context to attack it. The subagent prompt must instruct it to: read ${norm} and the spec it references; act as a hostile staff engineer whose job is to find why this plan FAILS; and report its 3 strongest objections across -- (a) whether executing these tasks actually produces what the spec asked for, (b) what the plan assumes about the current codebase that may be false (name specific files it should verify), (c) what breaks in 6 months. Do NOT run this review inline: you wrote the plan and are anchored to it. Report the objections to the user and wait for their decision before executing."
    if [[ "$gstack" -eq 1 ]]; then
        msg="${msg} Then, in the SAME subagent and after forming its own objections, have it invoke the gstack-plan-eng-review skill against the plan and fold that lens's strongest architecture, edge-case and test-coverage findings into one combined report. Invoke the lens inside the subagent, never here."
    fi
fi

# Reporting contract, appended to BOTH gates.
#
# Added 2026-09-06. The prompt asked for three objections and set no size budget at
# all, so the subagent wrote an essay, the report came back truncated, and getting
# the tail cost a second round trip every time. Adding the gstack lens made it worse
# by construction, since that folds more findings into the same reply.
#
# Filing the review removes the budget from the transport entirely rather than asking
# a verbose reviewer to please be shorter, and leaves an artifact worth revisiting.
# reviews/ deliberately matches neither trigger pattern above, so writing the review
# cannot start another review -- pinned by a test.
# Fixed check, appended to BOTH gates. Added 2026-10-05 from the probe-failures
# escalation queue (section 20, routed here because a spec is where it bit): two
# verified facts in one sentence can jointly imply a third that neither establishes,
# and per-claim review cannot see it -- the original passed three review rounds.
msg="${msg} FIXED CHECK, separate from the three objections: find every sentence that sets two verified facts side by side -- a count next to an absence, a total next to a remainder -- and name the third claim a reader will infer from the pair. If neither fact establishes it, flag it as an unsupported implicature; a flagged one may displace the weakest of the three returned objections. Every residual (N total, M present, K missing) must be decomposed until its parts sum."
msg="${msg} REPORTING CONTRACT: the subagent must WRITE its complete review to docs/superpowers/reviews/ -- same date and topic as the artifact under review, with a -redteam.md suffix -- and RETURN only its three objections as one line each plus that path, nothing more. A long report does not survive the trip back: it arrives truncated, and recovering the tail costs another round trip."

# Rewrite of an artifact that already has a review. Added 2026-10-28 (cli-timer): a spec
# rewritten to fold in its own red team's findings fired the full gate again, and the user
# chose to skip a second pass on what was by then a one-line change. Since Write fires on
# every full rewrite, a review already on disk under the contract's name means this is a
# revision: the user decides whether it earns another review. The glob is the artifact's
# own stem, so a spec's -design-redteam.md never counts as its plan's review.
stem=${norm##*/}; stem=${stem%.md}
reviews="${norm%/docs/superpowers/*}/docs/superpowers/reviews"
shopt -s nullglob
prior=("$reviews/${stem}-redteam"*.md)
shopt -u nullglob
if [[ ${#prior[@]} -gt 0 ]]; then
    short="Red-team gate: ${kind} rewritten after its review -- ask before a second pass."
    msg="RED-TEAM GATE (${kind}, rewrite). ${norm} already has a red-team review: docs/superpowers/reviews/${prior[0]##*/}. If this rewrite only folds in that review's findings or decisions the user already made, do not dispatch a second review: tell the user the gate fired on a revision, recommend skipping a second pass, and ask the user. If the rewrite changes what gets built (a new approach, new scope, a reversed decision), run the full gate below, but have the second review write to a -redteam-2.md file (or the next free number) so the first review is kept. The full gate: ${msg}"
fi

if command -v jq >/dev/null 2>&1; then
    jq -n --arg sm "$short" --arg ctx "$msg" \
        '{systemMessage:$sm, hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}'
else
    printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' \
        "$short" "$msg"
fi

exit 0
