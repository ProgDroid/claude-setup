#!/usr/bin/env bash
# Runs every test_*.sh in this directory. Exits non-zero if any assertion failed,
# if a test file ended without reporting its counts, or if nothing ran at all.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
COUNTS_DIR="$(mktemp -d)"
trap 'rm -rf "$COUNTS_DIR"' EXIT
COUNTS="$COUNTS_DIR/counts"
TOTAL_RUN=0
TOTAL_FAILED=0

for t in "$HERE"/test_*.sh; do
  [ -f "$t" ] || continue
  printf '\n%s\n' "$(basename "$t")"
  # Removed BEFORE each file: a test that exits early must not inherit the previous
  # file's counts and look like it passed.
  rm -f "$COUNTS"
  # shellcheck disable=SC1090
  ( set -u; . "$HERE/lib.sh"; . "$t"; printf '%s %s\n' "$TESTS_RUN" "$TESTS_FAILED" > "$COUNTS" )
  if [ -f "$COUNTS" ] && read -r run failed < "$COUNTS"; then
    TOTAL_RUN=$((TOTAL_RUN + run))
    TOTAL_FAILED=$((TOTAL_FAILED + failed))
  else
    printf '    FAIL %s did not report its counts (exited early or crashed)\n' "$(basename "$t")"
    TOTAL_RUN=$((TOTAL_RUN + 1))
    TOTAL_FAILED=$((TOTAL_FAILED + 1))
  fi
done

printf '\n%s assertions, %s failed\n' "$TOTAL_RUN" "$TOTAL_FAILED"
if [ "$TOTAL_RUN" -eq 0 ]; then
  printf 'run-tests: no assertions ran, which is a failure\n' >&2
  exit 1
fi
[ "$TOTAL_FAILED" -eq 0 ]
