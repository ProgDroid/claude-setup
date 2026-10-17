#!/usr/bin/env bash
# Shared helpers for the handoff hooks (handoff-session-start.sh, handoff-post-tool.sh).
# Source this file; do not execute it. The rules these enforce live in skills/handoff/SKILL.md.
#
# SPEED: the post-tool hook runs on every Bash/PowerShell call in every project, and almost none
# of those repos carry the marker. A fork costs ~30 ms under Git Bash, so everything up to and
# including ho_marker is pure bash: no $(...), no external program. Git runs only in opted-in
# repos.

HO_MARKER_REL='.claude/handoff.json'
HO_DEFAULT_ASK='How did the last change go?'

# ho_json_field <json> <key>: set HO_FIELD to the first "<key>":"<string>" in the raw JSON,
# without jq (no fork). Unescapes \\ only, which is all a path or a short word carries. An
# escaped occurrence inside another string (\"key\") cannot match: its quote is preceded by \.
ho_json_field() {
  HO_FIELD=""
  local re="\"$2\"[[:space:]]*:[[:space:]]*\"(([^\"\\\\]|\\\\.)*)\""
  [[ $1 =~ $re ]] || return 1
  HO_FIELD="${BASH_REMATCH[1]//\\\\/\\}"
}

# ho_marker <dir>: set HO_ROOT to the repo root when that repo carries .claude/handoff.json, and
# HO_START to <dir> as cd resolved it. Walks up to the nearest .git (dir or worktree file) and
# stops there, so a marker in an enclosing repo never counts. Returns 1 otherwise. Accepts
# Windows (backslash) paths; leaves the caller's cwd unchanged.
ho_marker() {
  HO_ROOT=""; HO_START=""
  local here="$PWD" d p
  [ -n "$1" ] || return 1
  cd -- "${1//\\//}" 2>/dev/null || return 1
  d="$PWD"; cd -- "$here" 2>/dev/null
  HO_START="$d"
  while :; do
    if [ -e "$d/.git" ]; then
      [ -f "$d/$HO_MARKER_REL" ] || return 1
      HO_ROOT="$d"; return 0
    fi
    p="${d%/*}"
    { [ -z "$p" ] || [ "$p" = "$d" ]; } && return 1
    d="$p"
  done
}

# ho_anchor <root>: print "<sha> <subject>" of the newest commit whose SUBJECT starts "handoff:".
# Subject only: --grep would also match a BODY line. Returns 0 found, 1 none (an unborn branch
# has none), 2 history unreadable.
# Twin of _handoff_anchor in skills/project-start/lib/handoff.sh (hooks cannot source the skill's
# lib); test-handoff-hooks.sh asserts the two agree. Change both together.
ho_anchor() {
  local log
  if ! git -C "$1" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    git -C "$1" symbolic-ref -q HEAD >/dev/null 2>&1 && return 1
    return 2
  fi
  log="$(git -C "$1" log --format='%H %s' 2>/dev/null)" || return 2
  log="$(grep -m 1 -E '^[0-9a-f]+ handoff:' <<<"$log")" || return 1
  printf '%s\n' "$log"
}

# ho_commits_since <root> <anchor-sha|""> [max]: one line per commit, newest first:
# "[agent] YYYY-MM-DD subject" or "[other] ...". With no anchor, lists HEAD's history.
# [agent] = a Co-Authored-By trailer (key in any case) whose value starts "Claude", or a subject
# starting "chore: auto-commit" (the plugin's cloud Stop hook, which carries no trailer).
# A LISTING, never an authorship claim: non-Claude tools also commit without the trailer.
ho_commits_since() {
  local root="$1" range="HEAD" rec subj date trl tag v raw
  local -a lim=()
  [ -n "$2" ] && range="$2..HEAD"
  [ -n "${3:-}" ] && lim=(-n "$3")
  raw="$(git -C "$root" log "${lim[@]}" --date=short \
    --format='%x1e%s%x1f%ad%x1f%(trailers:key=Co-Authored-By,valueonly,separator=%x1d)' "$range" 2>/dev/null)" || return 1
  raw="${raw//$'\n'/}"
  while [[ $raw == *$'\x1e'* ]]; do
    raw="${raw#*$'\x1e'}"
    rec="${raw%%$'\x1e'*}"
    subj="${rec%%$'\x1f'*}"; rec="${rec#*$'\x1f'}"
    date="${rec%%$'\x1f'*}"; trl="${rec#*$'\x1f'}"
    tag=other
    [[ $subj == "chore: auto-commit"* ]] && tag=agent
    while [ "$tag" = other ] && [ -n "$trl" ]; do
      v="${trl%%$'\x1d'*}"
      [[ ${v#"${v%%[![:space:]]*}"} == Claude* ]] && tag=agent
      [[ $trl == *$'\x1d'* ]] && trl="${trl#*$'\x1d'}" || trl=""
    done
    printf '[%s] %s %s\n' "$tag" "$date" "$subj"
  done
}

# ho_pending <root> <anchor-sha|"">: true when at least one [agent] commit sits after the anchor;
# sets HO_PENDING_N to their count. No anchor means nothing to compare against: false.
ho_pending() {
  HO_PENDING_N=0
  [ -n "$2" ] || return 1
  local list
  list="$(ho_commits_since "$1" "$2")" || return 1
  HO_PENDING_N="$(grep -c '^\[agent\]' <<<"$list")"
  [ "$HO_PENDING_N" -gt 0 ]
}

# ho_in_linked_worktree <dir>: true in a linked worktree (absolute git dir != common dir). The
# same test as _handoff_linked in skills/project-start/lib/handoff.sh. When git cannot answer, it
# returns false: these hooks only advise, so they fall back to the main-checkout wording. The
# ritual, which WRITES NEXT.md, is the side that must refuse when it cannot tell.
ho_in_linked_worktree() {
  local g c
  g="$(git -C "$1" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || return 1
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  [ "$g" != "$c" ]
}

# ho_scan_command <command>: find the git/gh commands it RUNS, as opposed to mentions inside
# quoted strings. Sets HO_ACTS to a space-led list of "commit", "push", "merge", "prcreate" (in
# order) and HO_CDIR to the -C <dir> of the first git command that names one (quotes removed).
# A command is a segment after start, newline, ; & | ( ) or {, past any VAR=value prefixes.
ho_scan_command() {
  HO_ACTS=""; HO_CDIR=""
  local s="${1//$'\r'/}" m seg rest c n=0
  local -a q=()
  # Lift quoted strings out first, so "git push later" or a ; inside a message is not a command.
  while [[ $s =~ (\"[^\"]*\"|\'[^\']*\') ]]; do
    m="${BASH_REMATCH[1]}"; q[n]="${m:1:${#m}-2}"
    s="${s/"$m"/__HOQ${n}__}"; n=$((n + 1))
  done
  s="${s//$'\n'/;}"; s="${s//&/;}"; s="${s//|/;}"; s="${s//(/;}"; s="${s//)/;}"; s="${s//\{/;}"
  local env='^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*'
  local opt='([[:space:]]+(-C[[:space:]]*[^[:space:]]+|-c[[:space:]]*[^[:space:]]+|--[A-Za-z-]+(=[^[:space:]]+)?|-[pP]))*'
  local gitre="${env}git(\.exe)?${opt}[[:space:]]+(commit|push|merge)([[:space:]]|$)"
  local ghre="${env}gh(\.exe)?[[:space:]]+pr[[:space:]]+create([[:space:]]|$)"
  local cre='(^|[[:space:]])-C[[:space:]]*([^[:space:]]+)'
  rest="$s;"
  while [ -n "$rest" ]; do
    seg="${rest%%;*}"; rest="${rest#*;}"
    seg="${seg#"${seg%%[![:space:]]*}"}"
    if [[ $seg =~ $gitre ]]; then
      HO_ACTS+=" ${BASH_REMATCH[6]}"   # group 6 = the act word (counted in the test-suite scan cases)
      if [ -z "$HO_CDIR" ] && [[ ${seg%%[[:space:]]"${BASH_REMATCH[6]}"*} =~ $cre ]]; then
        c="${BASH_REMATCH[2]}"
        [[ $c =~ ^__HOQ([0-9]+)__$ ]] && c="${q[${BASH_REMATCH[1]}]}"
        HO_CDIR="$c"
      fi
    elif [[ $seg =~ $ghre ]]; then
      HO_ACTS+=" prcreate"
    fi
  done
}

# ho_emit <event> <text>: print the hookSpecificOutput JSON. The text reaches jq on stdin, never
# as an argument (jq.exe is a native program; argv crosses a Windows code-page conversion).
ho_emit() {
  printf '%s' "$2" | jq -Rsc --arg e "$1" '{hookSpecificOutput:{hookEventName:$e, additionalContext:.}}'
}
