#!/usr/bin/env bash
# Shared helpers for the project-start ritual. Source this file; do not execute it.

RITUAL_SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# steps_json -> path to steps.json. RITUAL_STEPS_JSON overrides it (tests use this to fake a
# version bump); otherwise it is located relative to this file, so any cwd works.
steps_json() {
  if [ -n "${RITUAL_STEPS_JSON:-}" ]; then printf '%s\n' "$RITUAL_STEPS_JSON"
  else printf '%s\n' "$RITUAL_SKILL_DIR/steps.json"; fi
}

# git_common_dir <repo> -> absolute path of the clone's shared git dir (same for all worktrees).
git_common_dir() {
  git -C "$1" rev-parse --path-format=absolute --git-common-dir
}

# emit <id> <status> <detail> [wrote...] -> one step-result object. status is one of
# present|absent|unknown by convention (not enforced here). detail and the wrote paths reach jq on
# stdin, never as arguments: jq.exe is a native Windows program, and past its ~32 KB command line
# it prints nothing. They travel base64-encoded because jq.exe's stdin drops CR bytes. The stdin
# carries the detail's base64, a "." line, then the base64 of the paths, each ended by \x1e.
emit() {
  local id="$1" status="$2" detail="$3"; shift 3
  { printf '%s' "$detail" | base64; printf '.\n'; [ $# -eq 0 ] || printf '%s\x1e' "$@" | base64; } \
    | jq -nRc --arg id "$id" --arg s "$status" '[inputs] as $l | ($l | index(".")) as $i
      | ($l[:$i] | add // "" | @base64d) as $d
      | ($l[$i + 1:] | add // "" | @base64d | split("\u001e") | .[:-1]) as $w
      | {id:$id, status:$s, detail:$d, wrote:$w}' || die "emit: jq could not build the $id result"
}

die() { echo "ritual: $*" >&2; exit 2; }

# require_repo <path>: refuse (exit 2) unless <path> is inside a git repository.
require_repo() {
  local g; g="$(git_common_dir "$1" 2>/dev/null)" && [ -n "$g" ] || die "not a git repository: $1"
}

# join_by <sep> <item...> -> the items joined with <sep> (nothing for no items).
join_by() { local sep="$1" IFS=$'\x1f' s; shift; s="$*"; printf '%s' "${s//$'\x1f'/"$sep"}"; }

# path_norm <path> -> one canonical form for comparing paths on Windows: absolute, forward
# slashes, 8.3 short names expanded (git reports the long form, mktemp the short one), then the
# unix form. cygpath only expands names that exist, so the longest existing ancestor is expanded
# and the rest re-appended. Without cygpath the path is returned as given.
path_norm() {
  local p="$1" rest=""
  if command -v cygpath >/dev/null 2>&1; then
    p="$(cygpath -m -a "$p" 2>/dev/null || printf '%s' "$p")"
    while [ ! -e "$p" ] && [ "$p" != "$(dirname "$p")" ]; do
      rest="/$(basename "$p")$rest"; p="$(dirname "$p")"
    done
    p="$(cygpath -m -l -a "$p" 2>/dev/null || printf '%s' "$p")"
    p="$(cygpath -u "${p%/}$rest" 2>/dev/null || printf '%s' "${p%/}$rest")"
  fi
  printf '%s' "${p%/}"
}

# md_fence <line>: track ``` / ~~~ fenced blocks in the global MD_FENCE (empty = outside; set it to
# "" before each scan). Returns 0 when <line> is a fence delimiter or is inside a fence (so it
# cannot be a heading). A trailing CR is ignored.
md_fence() {
  local l="${1%$'\r'}"
  if [[ -n "$MD_FENCE" ]]; then
    [[ "$l" =~ ^\ {0,3}${MD_FENCE}{3,}[[:space:]]*$ ]] && MD_FENCE=""
    return 0
  fi
  if [[ "$l" =~ ^\ {0,3}(\`\`\`|~~~) ]]; then MD_FENCE="${BASH_REMATCH[1]:0:1}"; return 0; fi
  return 1
}
MD_FENCE=""

# eol_of <file> -> crlf|lf. crlf iff the first line ends in CR; empty/missing -> lf.
eol_of() {
  # byte-level on purpose: under Git Bash, grep does not see the CR in $'\r$'
  if [ -s "$1" ] && [[ "$(head -n 1 "$1" | od -An -tx1 | tr -d ' \n')" == *0d0a ]]; then echo crlf; else echo lf; fi
}

# append_line <file> <line>: append one line using the file's own line ending. Never rewrites
# existing bytes; the only change to them is terminating an unterminated last line. Creates the
# file when missing. An empty <line> appends a blank line.
append_line() {
  local f="$1" line="$2" eol=$'\n' last
  [ "$(eol_of "$f")" = crlf ] && eol=$'\r\n'
  if [ -s "$f" ]; then
    last="$(tail -c 1 "$f" | od -An -tx1 | tr -d ' \n')"
    [ "$last" = 0a ] || printf '%s' "$eol" >> "$f"
  fi
  printf '%s%s' "$line" "$eol" >> "$f"
}
