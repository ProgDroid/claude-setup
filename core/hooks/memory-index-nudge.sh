#!/usr/bin/env bash
# SessionStart nudge, measured in BYTES (what loads into context), not lines. Prints up to
# three lines, each only when its condition holds: the project's MEMORY.md total is over
# --threshold, any one of its lines is over --line-limit, or the global CLAUDE.md is over
# --claude-md-limit. Silent on every other path (missing root, index, CLAUDE.md, bad flags);
# always exits 0 (HOME unset included); never writes to stderr.
# A flag with no value ends the run silently. A non-numeric value falls back to the default.
# A trailing CR is not counted in a line's bytes (CRLF and LF indexes measure the same).
# Kill criterion (as 2026-08-10): if a synthesize-memories run on a fired project finds nothing
# to demote, the threshold rises; it never stays where curation cannot satisfy it.
set -u
exec 2>/dev/null

MEMORY_ROOT=""
CLAUDE_MD=""
[ -n "${HOME:-}" ] && { MEMORY_ROOT="${HOME}/.claude/projects"; CLAUDE_MD="${HOME}/.claude/CLAUDE.md"; }
PROJECT=""
THRESHOLD=15000
LINE_LIMIT=1000
CLAUDE_MD_LIMIT=12000

while [ $# -gt 0 ]; do
  case "$1" in
    --memory-root)     val="${2:-}"; [ -n "$val" ] || exit 0; MEMORY_ROOT="$val"; shift 2 ;;
    --project)         val="${2:-}"; [ -n "$val" ] || exit 0; PROJECT="$val"; shift 2 ;;
    --threshold)       val="${2:-}"; [ -n "$val" ] || exit 0; THRESHOLD="$val"; shift 2 ;;
    --line-limit)      val="${2:-}"; [ -n "$val" ] || exit 0; LINE_LIMIT="$val"; shift 2 ;;
    --claude-md)       val="${2:-}"; [ -n "$val" ] || exit 0; CLAUDE_MD="$val"; shift 2 ;;
    --claude-md-limit) val="${2:-}"; [ -n "$val" ] || exit 0; CLAUDE_MD_LIMIT="$val"; shift 2 ;;
    *) shift ;;
  esac
done

isnum() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
isnum "$THRESHOLD" || THRESHOLD=15000
isnum "$LINE_LIMIT" || LINE_LIMIT=1000
isnum "$CLAUDE_MD_LIMIT" || CLAUDE_MD_LIMIT=12000

if [ -z "$PROJECT" ]; then
  # shellcheck source=lib-key.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib-key.sh" 2>/dev/null || exit 0
  PROJECT="$(core_memory_key "$(pwd)")" || PROJECT=""
fi

INDEX="$MEMORY_ROOT/$PROJECT/memory/MEMORY.md"
if [ -n "$MEMORY_ROOT" ] && [ -n "$PROJECT" ] && [ -f "$INDEX" ] && [ -r "$INDEX" ]; then
  total="$(wc -c < "$INDEX" 2>/dev/null | tr -d ' ')"
  if isnum "$total" && [ "$total" -gt "$THRESHOLD" ]; then
    printf 'Memory index for this project is %s bytes (threshold %s) and loads every session. Run the synthesize-memories skill to tier shipped milestones into the cold index.\n' "$total" "$THRESHOLD"
  fi
  # LC_ALL=C: awk length() counts bytes only in the C locale. First offending line only.
  hit="$(LC_ALL=C awk -v lim="$LINE_LIMIT" '{ sub(/\r$/, "") } length($0) > lim { print NR, length($0); exit }' "$INDEX" 2>/dev/null)"
  if [ -n "$hit" ]; then
    k="${hit%% *}"; n="${hit##* }"
    printf 'Memory index line %s is %s bytes: an index line is a pointer, not the memory. Move the content into the memory file.\n' "$k" "$n"
  fi
fi

if [ -n "$CLAUDE_MD" ] && [ -f "$CLAUDE_MD" ] && [ -r "$CLAUDE_MD" ]; then
  cm="$(wc -c < "$CLAUDE_MD" 2>/dev/null | tr -d ' ')"
  if isnum "$cm" && [ "$cm" -gt "$CLAUDE_MD_LIMIT" ]; then
    printf 'Global CLAUDE.md is %s bytes (limit %s) and loads every session. Move what is not always-needed into a skill, memory or learnings file.\n' "$cm" "$CLAUDE_MD_LIMIT"
  fi
fi
exit 0
