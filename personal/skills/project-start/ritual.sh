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

# _auto_stack <stack-json> -> the stack subcommand's output wrapped as a step result (in `output`)
_auto_stack() {
  printf '%s' "$1" | jq -c '(.unparsed // []) as $u
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

# _auto_run <cmd...>: run in a subshell (oracle changes directory; a die must not end the run).
# stdout -> _AUTO_OUT, exit -> _AUTO_RC; stderr is kept in $_AUTO_ERR and passed through.
_auto_run() {
  _AUTO_OUT="$("$@" 2>"$_AUTO_ERR")"; _AUTO_RC=$?
  [ -s "$_AUTO_ERR" ] && cat "$_AUTO_ERR" >&2
  return 0
}

# _auto_result <id> -> _AUTO_OUT when the call exited 0 and printed a result for <id>; otherwise an
# `unknown` result naming the exit code and the end of the call's stderr.
_auto_result() {
  local tail
  if [ "$_AUTO_RC" -eq 0 ] && printf '%s' "$_AUTO_OUT" | jq -e --arg id "$1" \
      'type == "object" and .id == $id and (.status | type) == "string" and (.wrote | type) == "array"' >/dev/null 2>&1; then
    printf '%s\n' "$_AUTO_OUT"; return 0
  fi
  tail="$(tr -d '\r' < "$_AUTO_ERR" | grep -v '^[[:space:]]*$' | tail -n 3 | paste -sd'|' -)"
  emit "$1" unknown "step ended without a result (exit $_AUTO_RC)${tail:+: ${tail:0:300}}"
}

# auto <repo> -> {"results":[<step-result>...],"wrote":[<path>...]}, results in AUTO_STEPS order;
# wrote is every result's wrote, first occurrence kept. A step that exits non-zero or prints no
# result for its id is reported `unknown`, and the remaining steps still run.
# Detection runs once per run. The languages are scanned before any write (no auto step changes
# them) and handed to stack-checks. The oracle is scanned after stack-checks, which can add a lint
# command, and the stack result then takes testing.md from it, as `ritual.sh stack` would.
auto() {
  local repo="$1" step stack_raw stack_rc
  local -A res=()
  _AUTO_ERR="$(mktemp)" || die "mktemp failed"
  trap 'rm -f "$_AUTO_ERR"' EXIT
  trap 'exit 130' INT; trap 'exit 143' TERM; trap 'exit 129' HUP   # the EXIT trap still runs

  _auto_run stack_json "$repo" -; stack_raw="$_AUTO_OUT"; stack_rc="$_AUTO_RC"
  if [ "$stack_rc" -eq 0 ]; then _RITUAL_STACK_MEMO="$stack_raw"; _RITUAL_MEMO_REPO="$repo"
  else res[stack]="$(_auto_result stack)"; fi
  _auto_run fix_traps "$repo"; res[traps]="$(_auto_result traps)"
  _auto_run fix_stack_checks "$repo"; res[stack-checks]="$(_auto_result stack-checks)"
  _auto_run _auto_oracle "$repo"; res[oracle]="$(_auto_result oracle)"
  if [ "$stack_rc" -eq 0 ]; then
    _auto_run _auto_stack "$(printf '%s' "$stack_raw" | jq -c --arg o "$(_auto_status "${res[oracle]}")" \
      'if $o == "present" then .includes = (.includes + ["testing.md"] | unique) else . end')"
    res[stack]="$(_auto_result stack)"
  fi
  _auto_run fix_parking_lot "$repo"; res[parking-lot]="$(_auto_result parking-lot)"
  _auto_run check_beads_metrics "$repo"; res[beads-metrics]="$(_auto_result beads-metrics)"

  for step in "${AUTO_STEPS[@]}"; do printf '%s\n' "${res[$step]}"; done \
    | jq -sc '{results: ., wrote: (reduce (.[].wrote[]) as $x ([]; if index([$x]) then . else . + [$x] end))}' \
    || die "auto: jq could not assemble the results"
}
_auto_status() { printf '%s' "$1" | jq -r .status | tr -d '\r'; }

# repo_root <path> -> the work tree's top when <path> lies below it, else <path> unchanged (also
# when git cannot tell: the step then meets the same git and reports it). At the top already, the
# caller's spelling of the path is kept.
repo_root() {
  local pre top
  pre="$(git -C "$1" rev-parse --show-prefix 2>/dev/null)" || { printf '%s' "$1"; return 0; }
  pre="${pre%$'\r'}"
  if [ -n "$pre" ] && top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$top" ]; then
    printf '%s' "${top%$'\r'}"
  else printf '%s' "$1"; fi
}
unset _RITUAL_STACK_MEMO _RITUAL_MEMO_REPO

sub="${1:-}"; [ $# -gt 0 ] && shift
# Every <repo> means its work tree's top, so a path below it cannot split one run's writes.
case "$sub" in
  check|fix) [ $# -ge 2 ] && set -- "$1" "$(repo_root "$2")" "${@:3}" ;;
  record-path|record-read|record-write|due|preflight|commit-plan|stack|oracle|auto|candidates|handoff-commit)
    [ $# -ge 1 ] && set -- "$(repo_root "$1")" "${@:2}" ;;
esac
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
