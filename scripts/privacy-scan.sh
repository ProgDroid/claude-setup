#!/usr/bin/env bash
# privacy-scan.sh --patterns <file> [path...]
# One ERE per line in the pattern file; blank lines and '#' comments ignored. Case-insensitive.
# Prints file:line:pattern per hit.
# Exit 0 clean, 1 hits, 2 unusable: pattern file missing/empty, an invalid pattern, a scan path
# that does not exist, or grep itself failing. An unusable scan is never reported as clean.
patterns=""
paths=()
while [ $# -gt 0 ]; do
  case "$1" in
    --patterns) patterns="${2:-}"; shift 2 ;;
    *) paths+=("$1"); shift ;;
  esac
done
[ "${#paths[@]}" -eq 0 ] && paths=(.)
if [ -z "$patterns" ] || [ ! -f "$patterns" ]; then
  echo "privacy-scan: pattern file missing: ${patterns:-<none>}" >&2
  exit 2
fi
for path in "${paths[@]}"; do
  if [ ! -e "$path" ]; then
    echo "privacy-scan: scan path does not exist: $path" >&2
    exit 2
  fi
done
pats=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in ''|'#'*) continue ;; esac
  pats+=("$line")
done < "$patterns"
if [ "${#pats[@]}" -eq 0 ]; then
  echo "privacy-scan: pattern file has no patterns: $patterns" >&2
  exit 2
fi
# Validate every pattern first: grep exits 2 on an invalid ERE, and a pattern that cannot compile
# would otherwise match nothing and read as clean.
bad_pat=0
for p in "${pats[@]}"; do
  grep -E -e "$p" /dev/null 2>/dev/null
  if [ $? -eq 2 ]; then echo "privacy-scan: invalid pattern: $p" >&2; bad_pat=1; fi
done
[ "$bad_pat" -eq 0 ] || exit 2
hits=0
for p in "${pats[@]}"; do
  out=$(grep -rHnIiE --exclude-dir=.git --exclude-dir=node_modules -e "$p" -- "${paths[@]}" 2>/dev/null)
  grc=$?
  if [ "$grc" -ge 2 ]; then
    # grep -r reports unreadable files with rc 2 even when it also printed matches; either way the scan is incomplete
    echo "privacy-scan: grep failed (rc $grc) on pattern: $p" >&2
    exit 2
  fi
  if [ -n "$out" ]; then
    while IFS= read -r l; do
      f="${l%%:*}"; rest="${l#*:}"; ln="${rest%%:*}"
      printf '%s:%s:%s\n' "$f" "$ln" "$p"
      hits=$((hits + 1))
    done <<< "$out"
  fi
done
[ "$hits" -eq 0 ] && exit 0
exit 1
