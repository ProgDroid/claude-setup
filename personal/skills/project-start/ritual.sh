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
command -v jq >/dev/null 2>&1 || die "jq is required"

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
  candidates)   [ $# -ge 1 ] || die "usage: candidates <repo>"; require_repo "$1"; candidates "$1" ;;
  check|fix)    # generic router: check_<step>/fix_<step> (hyphens -> underscores)
    [ $# -ge 2 ] || die "usage: $sub <step> <repo> [args...]"
    step="$1"; repo="$2"; shift 2
    require_repo "$repo"
    fn="${sub}_${step//-/_}"
    declare -F "$fn" >/dev/null 2>&1 || die "unknown step: $step"
    "$fn" "$repo" "$@" ;;
  *) die "unknown subcommand: ${sub:-<none>} (record-path|record-read|record-write|due|preflight|commit-plan|stack|oracle|candidates|check|fix)" ;;
esac
