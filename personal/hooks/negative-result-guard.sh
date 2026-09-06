#!/usr/bin/env bash
# PostToolUse:Bash -- the negative-result guard.
#
# WHY THIS EXISTS
#   The probe-discipline section of the global CLAUDE.md is ~7k characters loaded at
#   every session start, and it is needed at exactly one moment: when a search comes
#   back empty and you are about to believe it. Prose loaded hours earlier competes
#   with everything else in context; a hook fires at the moment of the error.
#
#   The global rule says no hook can catch these, and that is true of DETECTING the
#   error -- a regex cannot know your pattern does not match the shape of the data.
#   But a hook does not need to detect the error. It only needs to notice that a
#   search-shaped command produced nothing, which is cheap and exact, and say the one
#   sentence that matters then.
#
# SCOPE, deliberately narrow
#   Fires only when ALL of these hold:
#     - the command looks like a SEARCH (grep/rg/find/git log -S/git grep/ls glob...)
#     - it was not asked to be silent (-q, --quiet, >/dev/null, redirected to a file)
#     - it did not ask for a count (-c prints 0, which is output, not absence)
#     - the captured output is empty after trimming
#
# SHAPE IS UNVERIFIED UNTIL IT FIRES
#   The exact PostToolUse payload for Bash is not documented here, so the output is
#   read from several candidate fields. If none is present the hook stays SILENT and
#   appends the payload keys to a debug log, because a guard that guesses and fires
#   wrongly is worse than one that does nothing. Read the log to learn the real shape:
#     ~/.claude/negative-result-guard.debug
#
# NEVER fails the session: always exits 0.

set -uo pipefail

DEBUG_LOG="${HOME}/.claude/negative-result-guard.debug"

json_input=$(cat)

# Cheap pre-filter before any JSON parsing. This hook runs on EVERY Bash call, and
# on Windows process creation is expensive enough that a jq parse per command is a
# real cost for a guard that only ever fires on searches. A raw grep over stdin
# costs one process and rejects the common case outright.
#
# It can only produce false POSITIVES -- a command whose OUTPUT merely mentions grep
# survives this and is then rejected by the real check below -- so correctness is
# unchanged and only the fast path moves.
printf '%s' "$json_input" | grep -qE 'grep|\brg\b|find|locate|\bag\b|\back\b|ls-files|--contains' || exit 0

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(printf '%s' "$json_input" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$cmd" ] || exit 0

# ---------- is this a search? ----------
# Anchored at a command position (start, or after ; | & && ||) so that a filename
# containing "find" or a --grep flag on an unrelated command does not qualify.
printf '%s' "$cmd" | grep -qE '(^|[;&|(]|&&|\|\|)[[:space:]]*(grep|rg|find|locate|ag|ack)([[:space:]]|$)|git[[:space:]]+(grep|ls-files)|git[[:space:]]+log[[:space:]]+.*-S|--contains' || exit 0

# ---------- was silence requested or redirected? ----------
# grep -q prints nothing BY DESIGN; -c prints 0. Neither is an empty result, and
# warning about them is the false-positive class that made the tail/head rule
# useless until it was narrowed.
#
# The -q/-c test is confined to grep/rg, where those letters mean quiet and count.
# Applied globally it would read `find . -exec ...` as a -c flag, since the cluster
# "exec" ends in c -- a suppression that would silently disable the guard for the
# most common find form.
if printf '%s' "$cmd" | grep -qE '(^|[[:space:]/|(])(grep|rg)([[:space:]]|$)'; then
    printf '%s' "$cmd" | grep -qE '(^|[[:space:]])-[a-zA-Z]*[qc]([[:space:]]|$)|--quiet|--count' && exit 0
fi

# A redirect means the output went to a file or the void, so "empty" here says
# nothing about whether the search matched. `2>&1` is not a redirect of results.
printf '%s' "$cmd" | grep -qE '>[[:space:]]*/dev/null|[^>&0-9]>[[:space:]]*[^&>[:space:]]' && exit 0

# ---------- read the output, defensively ----------
out=$(printf '%s' "$json_input" | jq -r '
  .tool_response as $r
  | if   ($r | type) == "string" then $r
    elif ($r | type) == "object" then
      (($r.stdout? // "") + ($r.output? // "") + ($r.stderr? // "") + ($r.content? // ""))
    else ""
    end
' 2>/dev/null)

# Shape unknown -> stay silent and record what we DID get, so the next real firing
# tells us the field name instead of us guessing at it.
if [ -z "$out" ]; then
  has_response=$(printf '%s' "$json_input" | jq -r 'has("tool_response")' 2>/dev/null)
  if [ "$has_response" != "true" ]; then
    exit 0
  fi
  keys=$(printf '%s' "$json_input" | jq -rc '.tool_response | if type=="object" then keys else type end' 2>/dev/null)
  # An object whose known fields are all absent means the shape moved. Log once.
  # `jq -r` strips quotes, so a bare string tool_response reports as `string`, not
  # `"string"`. Getting that wrong made the guard silently skip the string form.
  case "$keys" in
    *stdout*|*output*|*stderr*|*content*|string) ;;   # known shape, genuinely empty
    *) printf '%s  unknown tool_response shape: %s\n' "$(date -u +%FT%TZ)" "$keys" >> "$DEBUG_LOG" 2>/dev/null
       exit 0 ;;
  esac
fi

# ---------- empty? ----------
trimmed=$(printf '%s' "$out" | tr -d '[:space:]')
[ -z "$trimmed" ] || exit 0

msg="NEGATIVE RESULT. That search returned nothing, which is the moment the absent/unknown distinction gets collapsed. Before treating this as evidence of absence, prove the probe can return something -- ask for a count, query the metadata, or run it against a case you KNOW exists. State the evidence (this command found nothing), never the conclusion (there is no X). Note also that only grep exits 1 on no match: find, git ls-files and jq exit 0 and print nothing."

jq -n --arg ctx "$msg" \
  '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}'

exit 0
