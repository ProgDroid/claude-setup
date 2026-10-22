#!/usr/bin/env bash
# Maps Claude memory directory names back to project roots.
#
# The encoding project-root -> memory-dir-name is lossy (every non-alphanumeric
# character becomes '-'), so decoding is ambiguous. We invert the search direction
# instead: enumerate real directories, encode each forward with core_memory_key
# (core/hooks/lib-key.sh), and match against memory dir names.
#
# Usage: resolve-roots.sh [--memory-root DIR] [--search-root DIR]... [--max-depth N]
#   --search-root is repeatable; default is /g when it exists (home), else $HOME.
# Output: TSV, one line per memory dir: <memory_dir_name>\t<project_root_or_empty>
set -eu

_lib_dir="${CLAUDE_PLUGIN_ROOT:+$CLAUDE_PLUGIN_ROOT/hooks}"
[ -f "${_lib_dir:-}/lib-key.sh" ] || _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../hooks" && pwd)"
# shellcheck source=/dev/null
. "$_lib_dir/lib-key.sh"

MEMORY_ROOT="${HOME:-}/.claude/projects"
SEARCH_ROOTS=()
MAX_DEPTH=4

need_value() { [ "$1" -ge 2 ] || { printf 'resolve-roots: %s needs a value\n' "$2" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --memory-root) need_value $# "$1"; MEMORY_ROOT="$2"; shift 2 ;;
    --search-root) need_value $# "$1"; SEARCH_ROOTS+=("$2"); shift 2 ;;
    --max-depth)   need_value $# "$1"; MAX_DEPTH="$2"; shift 2 ;;
    *) printf 'resolve-roots: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [ "${#SEARCH_ROOTS[@]}" -eq 0 ]; then
  if [ -d /g ]; then SEARCH_ROOTS=(/g)
  elif [ -n "${HOME:-}" ]; then SEARCH_ROOTS=("$HOME")
  else
    printf 'resolve-roots: no search root (no /g, HOME unset); pass --search-root\n' >&2
    exit 2
  fi
fi
[ -d "$MEMORY_ROOT" ] || { printf 'resolve-roots: memory root not found: %s\n' "$MEMORY_ROOT" >&2; exit 1; }
for r in "${SEARCH_ROOTS[@]}"; do
  [ -d "$r" ] || { printf 'resolve-roots: search root not found: %s\n' "$r" >&2; exit 1; }
done

# Names containing a newline are pruned: the one-path-per-line table cannot hold them.
# Encoded-name -> real-path table for every directory at depth 1..MAX_DEPTH of each root.
# All keys come from ONE core_memory_keys process per root (lib-key.sh owns the rule).
TABLE="$(mktemp)"
DIRS="$(mktemp)"
trap 'rm -f "$TABLE" "$DIRS"' EXIT

for root in "${SEARCH_ROOTS[@]}"; do
  find "$root" -mindepth 1 -maxdepth "$MAX_DEPTH" \( -name .git -o -name node_modules -o -name "$(printf '*\n*')" \) -prune -o -type d -print 2>/dev/null > "$DIRS" || true
  core_memory_keys < "$DIRS" | paste -d '	' - "$DIRS"
done > "$TABLE"

for path in "$MEMORY_ROOT"/*; do
  [ -d "$path/memory" ] || continue
  name="$(basename "$path")"
  # First exact match wins; earlier roots, then shallower dirs, sort first.
  root="$(awk -F'\t' -v n="$name" '$1 == n { print $2; exit }' "$TABLE")"
  printf '%s\t%s\n' "$name" "$root"
done
