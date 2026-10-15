#!/usr/bin/env bash
# Run every tests/test-*.sh; exit 1 if any suite exits non-zero or none ran.
DIR="$(cd "$(dirname "$0")" && pwd)"
n=0; failed=0
for t in "$DIR"/test-*.sh; do
  [ -e "$t" ] || continue
  n=$((n + 1)); echo "== $(basename "$t")"
  bash "$t" || { failed=$((failed + 1)); echo "SUITE FAILED: $(basename "$t")"; }
done
echo "run-all: $n suites, $failed failed"
[ "$n" -gt 0 ] && [ "$failed" -eq 0 ]
