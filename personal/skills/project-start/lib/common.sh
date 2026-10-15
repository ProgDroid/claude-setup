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
# present|absent|unknown by convention (not enforced here).
emit() {
  local id="$1" status="$2" detail="$3"; shift 3
  jq -nc --arg id "$id" --arg s "$status" --arg d "$detail" '$ARGS.positional as $w
    | {id:$id, status:$s, detail:$d, wrote:$w}' --args "$@"
}

die() { echo "ritual: $*" >&2; exit 2; }

# require_repo <path>: refuse (exit 2) unless <path> is inside a git repository.
require_repo() {
  local g; g="$(git_common_dir "$1" 2>/dev/null)" && [ -n "$g" ] || die "not a git repository: $1"
}

# eol_of <file> -> crlf|lf. crlf iff the first line ends in CR; empty/missing -> lf.
eol_of() {
  if [ -s "$1" ] && head -n 1 "$1" | grep -q $'\r$'; then echo crlf; else echo lf; fi
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
