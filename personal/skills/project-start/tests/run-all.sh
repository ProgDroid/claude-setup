#!/usr/bin/env bash
# Run every test-*.sh in this directory (or in each DIR given) in parallel; exit 1 if any suite
# exits non-zero, leaves no exit status, or none ran.
#   run-all.sh [DIR...]     e.g. run-all.sh . ../../../hooks   (the hook suites too)
#   RITUAL_JOBS=N           suites at once (default: all of them; 1 = serial)
# Each suite's output is buffered to its own log and printed whole, in name order, so parallel runs
# read like serial ones. Bash 3.2 (macOS) has no `wait -n`, hence the jobs-count throttle.
DIR="$(cd "$(dirname "$0")" && pwd)"
[ "$#" -gt 0 ] || set -- "$DIR"
OUT="$(mktemp -d)"; trap 'rm -rf "$OUT"' EXIT
jobs_max="${RITUAL_JOBS:-0}"
suites=()
for d in "$@"; do
  for t in "$d"/test-*.sh; do [ -e "$t" ] && suites+=("$t"); done
done
start=$SECONDS; i=0
for t in "${suites[@]}"; do
  i=$((i + 1))
  if [ "$jobs_max" -gt 0 ]; then
    while [ "$(jobs -pr | wc -l)" -ge "$jobs_max" ]; do sleep 1; done
  fi
  ( s=$SECONDS; bash "$t" > "$OUT/$i.log" 2>&1; rc=$?
    printf '%s %s\n' "$rc" "$((SECONDS - s))" > "$OUT/$i.rc" ) &
done
wait
n=0; failed=0; i=0; times=""
for t in "${suites[@]}"; do
  i=$((i + 1)); n=$((n + 1)); name="$(basename "$t")"
  echo "== $name"; cat "$OUT/$i.log"
  if [ -s "$OUT/$i.rc" ]; then read -r rc secs < "$OUT/$i.rc"; else rc=unknown; secs=?; fi
  [ "$rc" = 0 ] || { failed=$((failed + 1)); echo "SUITE FAILED: $name (exit $rc)"; }
  times="$times$secs $name"$'\n'
done
echo "-- suite seconds (slowest first)"; printf '%s' "$times" | sort -rn
echo "run-all: $n suites, $failed failed, $((SECONDS - start))s wall"
[ "$n" -gt 0 ] && [ "$failed" -eq 0 ]
