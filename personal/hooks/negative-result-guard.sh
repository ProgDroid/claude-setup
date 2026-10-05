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
#     - the captured output is empty after trimming -- or, for a count (-c/--count),
#       every printed count is zero (changed 2026-10-05; counts used to be exempt)
#   The Grep and Glob TOOLS are covered too (2026-10-05): matcher Bash|Grep|Glob.
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

emit() {
  local msg="NEGATIVE RESULT. That search returned nothing, which is the moment the absent/unknown distinction gets collapsed. Before treating this as evidence of absence, prove the probe can return something -- ask for a count, query the metadata, or run it against a case you KNOW exists. State the evidence (this command found nothing), never the conclusion (there is no X). Note also that only grep exits 1 on no match: find, git ls-files and jq exit 0 and print nothing."
  jq -n --arg ctx "$msg" \
    '{hookSpecificOutput:{hookEventName:"PostToolUse", additionalContext:$ctx}}'
}

json_input=$(cat)

# Cheap pre-filter before any JSON parsing. This hook runs on EVERY Bash call, and
# on Windows process creation is expensive enough that a jq parse per command is a
# real cost for a guard that only ever fires on searches. A raw grep over stdin
# costs one process and rejects the common case outright.
#
# It can only produce false POSITIVES -- a command whose OUTPUT merely mentions grep
# survives this and is then rejected by the real check below -- so correctness is
# unchanged and only the fast path moves.
printf '%s' "$json_input" | grep -qE 'grep|\brg\b|find|locate|\bag\b|\back\b|ls-files|--contains|"tool_name" *: *"(Grep|Glob)"' || exit 0

command -v jq >/dev/null 2>&1 || exit 0

# ---------- the Grep and Glob TOOLS (added 2026-10-05) ----------
# Until 2026-10-05 this guard watched Bash only, so an empty result from the Grep or
# Glob tool -- the preferred search tools -- never reached it. Shapes MEASURED from a
# real transcript's toolUseResult, not guessed:
#   Grep content, empty : {mode:"content", numFiles:0, filenames:[], content:"", numLines:0}
#   Grep count, found   : {mode:"count", numFiles:3, filenames:[], content:"path:1\n...", numMatches:6}
#   Glob, empty         : {filenames:[], numFiles:0, totalMatches:0, truncated:false}
# Empty means every result-bearing field is empty at once, so a mode that leaves one
# field blank while another carries the hits (count mode keeps filenames:[]) still
# reads as found. An object with none of these keys is an unknown shape: silent, logged.
tool=$(printf '%s' "$json_input" | jq -r '.tool_name // empty' 2>/dev/null)
if [ "$tool" = "Grep" ] || [ "$tool" = "Glob" ]; then
  verdict=$(printf '%s' "$json_input" | jq -r '
    .tool_response as $r
    | if ($r | type) != "object" then "unknown"
      elif (($r | has("filenames")) or ($r | has("content")) or ($r | has("numFiles"))) | not then "unknown"
      elif ((($r.filenames // []) | length) == 0)
           and ((($r.content // "") | gsub("\\s"; "")) == "")
           and (($r.numMatches // 0) == 0)
           and (($r.numFiles // 0) == 0)
        then "empty"
      else "found" end' 2>/dev/null)
  case "$verdict" in
    empty) emit ;;
    unknown)
      keys=$(printf '%s' "$json_input" | jq -rc '.tool_response | if type=="object" then keys else type end' 2>/dev/null)
      printf '%s  unknown %s tool_response shape: %s\n' "$(date -u +%FT%TZ)" "$tool" "$keys" >> "$DEBUG_LOG" 2>/dev/null ;;
  esac
  exit 0
fi

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
#
# COUNT MODE CHANGED 2026-10-05. -c used to exit here on the theory that a printed 0
# is output, not absence. It is absence -- a count of zero is the same claim as an
# empty listing -- and the exemption was where a real miss came through (two exact-
# spelling `grep -c` probes read 0 for facts present under other wording). Now -c is
# remembered and judged below: it fires only when EVERY printed count is zero.
count_mode=0
if printf '%s' "$cmd" | grep -qE '(^|[[:space:]/|(])(grep|rg)([[:space:]]|$)'; then
    printf '%s' "$cmd" | grep -qE '(^|[[:space:]])-[a-zA-Z]*q[a-zA-Z]*([[:space:]]|$)|--quiet' && exit 0
    printf '%s' "$cmd" | grep -qE '(^|[[:space:]])-[a-zA-Z]*c[a-zA-Z]*([[:space:]]|$)|--count' && count_mode=1
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

if [ "$count_mode" = 1 ]; then
  # A count that printed nothing at all is not a count result; stay silent as before.
  [ -n "$trimmed" ] || exit 0
  # Fire only if every non-blank line is a zero count: `0`, or `path:0` per file.
  # One non-zero line means the search found something somewhere.
  printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | grep -qvE '(^|:)[[:space:]]*0[[:space:]]*$' && exit 0
  emit
  exit 0
fi

[ -z "$trimmed" ] || exit 0

# KNOWN BLIND SPOT, recorded rather than guessed at: a compound command that also
# prints anything else (an `echo REAL_EXIT=$?`, a label, a second probe) is never
# "empty", so an empty search inside it cannot be seen here. Attributing output to
# segments of a shell line is not reliable enough to fire on.
emit

exit 0
