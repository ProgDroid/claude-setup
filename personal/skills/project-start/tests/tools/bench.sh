#!/usr/bin/env bash
# bench.sh: paired timing of one ritual command under two skill trees.
#
#   bench.sh <skill-dir-A> <skill-dir-B> <fixture-name> <state> <n> -- <ritual args with {repo}>
#
# Builds the fixture once in the state (with A's ritual), then for each of <n> runs restores it at
# one fixed path and times the command under A and under B back to back, alternating which goes
# first (so drift and a warm cache cancel instead of favouring one side). Stubbed tools, as in
# differential.sh. Prints `A <ms> B <ms> d <ms>` per run (d = A - B: positive means B is faster),
# then `paired median d=<ms>ms (n=<n>)`. The stop rule reads that line: a paired median saving
# under 0.3 s (300 ms) means the item is reverted. An exit status that differs between A and B
# (or from $BENCH_EXPECT_RC) aborts with exit 1.
#   e.g.  bench.sh REF NEW python fresh 5 -- auto {repo}
# The git-dir comparison hashes files with sha256sum. Where it is missing (stock macOS) every hash
# would be empty on both sides and a changed hook would read SAME, so refuse to run at all.
command -v sha256sum >/dev/null 2>&1 || { echo "bench: sha256sum is required (without it a changed hook would read SAME)" >&2; exit 2; }
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TOOLS_DIR/../lib.sh"
. "$TOOLS_DIR/fixtures.sh"
set -uo pipefail
die2() { echo "bench: $*" >&2; exit 2; }
[ $# -ge 7 ] || die2 "usage: bench.sh <skill-dir-A> <skill-dir-B> <fixture-name> <state> <n> -- <ritual args with {repo}>"
SA="$(cd "$1" && pwd)" && SB="$(cd "$2" && pwd)" || die2 "a skill dir does not exist"
FX="$3"; STATE="$4"; NRUNS="$5"; shift 5
case "$NRUNS" in ''|*[!0-9]*|0) die2 "<n> must be a positive number" ;; esac
[ "$1" = -- ] || die2 "expected -- before the ritual args"; shift
[ $# -gt 0 ] || die2 "no ritual args"
ARGS=("$@")
make_tool_stubs "$TMPROOT"
export GIT_AUTHOR_DATE="$FX_DATE" GIT_COMMITTER_DATE="$FX_DATE"

P="$TMPROOT/bench space/repo"; SNAP="$TMPROOT/bench snap"
if [ -d "$FX" ] && [ -d "$FX/.git" ]; then src="extra:$FX"; else src="$FX"; fi
fx_snapshot "$src" "$STATE" "$SA/ritual.sh" "$P" "$SNAP" || die2 "cannot build $FX:$STATE"

now_ms() { if [ -n "${EPOCHREALTIME:-}" ]; then local t="${EPOCHREALTIME/[.,]/}"; echo $((t / 1000)); else echo $(($(date +%s%N) / 1000000)); fi; }
time_one() {   # time_one <skill-dir> -> "<ms> <exit status>" on stdout, on a freshly restored repo
  local a=() x t0 t1 rc
  for x in "${ARGS[@]}"; do a+=("${x//\{repo\}/$P}"); done
  fx_restore "$SNAP" "$P"
  t0="$(now_ms)"
  tool_run bash "$1/ritual.sh" "${a[@]}" >/dev/null 2>&1; rc=$?
  t1="$(now_ms)"
  echo "$((t1 - t0)) $rc"
}

# A run whose exit status differs between the sides (or from BENCH_EXPECT_RC, when set) is not a
# timing: a command that dies at once would read as a large saving. Abort, naming the run.
D=()
for ((i = 1; i <= NRUNS; i++)); do
  if [ $((i % 2)) -eq 1 ]; then ra="$(time_one "$SA")"; rb="$(time_one "$SB")"
  else rb="$(time_one "$SB")"; ra="$(time_one "$SA")"; fi
  ta="${ra% *}"; ca="${ra#* }"; tb="${rb% *}"; cb="${rb#* }"
  D+=($((ta - tb)))
  echo "A $ta B $tb d $((ta - tb))"
  if [ "$ca" != "$cb" ] || { [ -n "${BENCH_EXPECT_RC:-}" ] && [ "$ca" != "$BENCH_EXPECT_RC" ]; }; then
    echo "bench: run $i: A exited $ca, B exited $cb${BENCH_EXPECT_RC:+ (expected $BENCH_EXPECT_RC)}; the timings are not comparable" >&2
    exit 1
  fi
done
mapfile -t SORTED < <(printf '%s\n' "${D[@]}" | sort -n)
n=${#SORTED[@]}
if [ $((n % 2)) -eq 1 ]; then med="${SORTED[$((n / 2))]}"
else med=$(((SORTED[n / 2 - 1] + SORTED[n / 2]) / 2)); fi
echo "paired median d=${med}ms (n=$n)"
