#!/usr/bin/env bash
# project-start ritual dispatcher.  bash ritual.sh <subcommand> <repo> [args...]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/record.sh"
. "$HERE/lib/workspace.sh"
. "$HERE/lib/detect.sh"
. "$HERE/lib/files.sh"
. "$HERE/lib/repo.sh"
. "$HERE/lib/parking.sh"
. "$HERE/lib/beads.sh"
. "$HERE/lib/secretscan.sh"
. "$HERE/lib/handoff.sh"
command -v jq >/dev/null 2>&1 || die "jq is required"

# The scripted auto steps, in steps.json order. stack-checks runs its fix, which writes only the
# canonical case (a single-crate root) and reports every other one absent "...: needs ask".
# lessons is model-run; no ask step ever runs here.
AUTO_STEPS=(stack traps stack-checks oracle parking-lot beads-metrics)

# _auto_stack <repo> -> the stack subcommand's output wrapped as a step result (in `output`)
_auto_stack() {
  local out; out="$(stack_json "$1")" || return $?
  printf '%s' "$out" | jq -c '(.unparsed // []) as $u
    | {id: "stack",
       status: (if ($u | length) > 0 then "unknown" elif (.stacks | length) > 0 then "present" else "absent" end),
       detail: ([if (.stacks | length) > 0 then (.stacks | map("\(.lang) (\(.dir))") | join(", ")) else "no stack detected" end]
                + (if (.includes | length) > 0 then ["includes: " + (.includes | join(", "))] else [] end)
                + (if ($u | length) > 0 then ["could not parse: " + ($u | join(", "))] else [] end) | join("; ")),
       wrote: [], output: .}'
}

# _auto_oracle <repo> -> the oracle subcommand's output wrapped as a step result (in `output`)
_auto_oracle() {
  local out; out="$(oracle_json "$1")" || return $?
  printf '%s' "$out" | jq -c 'def cmds: map(.cmd + (if .dir == "." then "" else " (in \(.dir))" end)) | join(", ");
    {id: "oracle", status: .status,
     detail: ([if (.test | length) > 0 then "test: " + (.test | cmds) else "no test command found" end]
              + (if (.lint | length) > 0 then ["lint: " + (.lint | cmds)] else [] end)
              + (if .detail then [.detail] else [] end) | join("; ")),
     wrote: [], output: .}'
}

_auto_call() {
  case "$1" in
    stack) _auto_stack "$2" ;;
    oracle) _auto_oracle "$2" ;;
    beads-metrics) check_beads_metrics "$2" ;;
    *) "fix_${1//-/_}" "$2" ;;
  esac
}

# auto <repo> -> {"results":[<step-result>...],"wrote":[<path>...]}; wrote is every result's wrote,
# first occurrence kept. Each step runs in its own subshell (oracle changes directory; a die must
# not end the run): one that exits non-zero or prints no result for its id is reported `unknown`
# with its exit code and the end of its stderr, and the remaining steps still run.
auto() {
  local repo="$1" step out rc err tail results=()
  err="$(mktemp)" || die "mktemp failed"
  for step in "${AUTO_STEPS[@]}"; do
    out="$(_auto_call "$step" "$repo" 2>"$err")"; rc=$?
    [ -s "$err" ] && cat "$err" >&2
    if [ "$rc" -ne 0 ] || ! printf '%s' "$out" | jq -e --arg id "$step" \
        'type == "object" and .id == $id and (.status | type) == "string" and (.wrote | type) == "array"' >/dev/null 2>&1; then
      tail="$(tr -d '\r' < "$err" | grep -v '^[[:space:]]*$' | tail -n 3 | paste -sd'|' -)"
      out="$(emit "$step" unknown "step ended without a result (exit $rc)${tail:+: ${tail:0:300}}")"
    fi
    results+=("$out")
  done
  rm -f "$err"
  printf '%s\n' "${results[@]}" | jq -sc '{results: ., wrote: (reduce (.[].wrote[]) as $x ([]; if index([$x]) then . else . + [$x] end))}' \
    || die "auto: jq could not assemble the results"
}

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  record-path)  [ $# -ge 1 ] || die "usage: record-path <repo>";  require_repo "$1"; record_path "$1" ;;
  record-read)  [ $# -ge 1 ] || die "usage: record-read <repo>";  require_repo "$1"; record_read "$1" ;;
  record-write) [ $# -ge 2 ] || die "usage: record-write <repo> <results.json>";  require_repo "$1"; record_write "$1" "$2" ;;
  due)          [ $# -ge 1 ] || die "usage: due <repo>";  require_repo "$1"; record_due "$1" ;;
  preflight)    [ $# -ge 1 ] || die "usage: preflight <repo>"; require_repo "$1"; preflight "$1" ;;
  commit-plan)  [ $# -ge 3 ] || die "usage: commit-plan <repo> <preflight.json> <wrote.json>"; require_repo "$1"; commit_plan "$1" "$2" "$3" ;;
  stack)        [ $# -ge 1 ] || die "usage: stack <repo>";  require_repo "$1"; stack_json "$1" ;;
  oracle)       [ $# -ge 1 ] || die "usage: oracle <repo>"; require_repo "$1"; oracle_json "$1" ;;
  auto)         [ $# -ge 1 ] || die "usage: auto <repo>";   require_repo "$1"; auto "$1" ;;
  candidates)   [ $# -ge 1 ] || die "usage: candidates <repo>"; require_repo "$1"; candidates "$1" ;;
  handoff-commit) [ $# -ge 1 ] || die "usage: handoff-commit <repo>"; require_repo "$1"; handoff_commit "$1" ;;
  check|fix)    # generic router: check_<step>/fix_<step> (hyphens -> underscores)
    [ $# -ge 2 ] || die "usage: $sub <step> <repo> [args...]"
    step="$1"; repo="$2"; shift 2
    require_repo "$repo"
    fn="${sub}_${step//-/_}"
    declare -F "$fn" >/dev/null 2>&1 || die "unknown step: $step"
    "$fn" "$repo" "$@" ;;
  *) die "unknown subcommand: ${sub:-<none>} (record-path|record-read|record-write|due|preflight|commit-plan|stack|oracle|auto|candidates|handoff-commit|check|fix)" ;;
esac
