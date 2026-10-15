#!/usr/bin/env bash
# project-start ritual dispatcher.  bash ritual.sh <subcommand> <repo> [args...]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/lib/common.sh"
. "$HERE/lib/record.sh"
command -v jq >/dev/null 2>&1 || die "jq is required"

sub="${1:-}"; [ $# -gt 0 ] && shift
case "$sub" in
  record-path)  [ $# -ge 1 ] || die "usage: record-path <repo>"; record_path "$1" ;;
  record-read)  [ $# -ge 1 ] || die "usage: record-read <repo>"; record_read "$1" ;;
  record-write) [ $# -ge 2 ] || die "usage: record-write <repo> <results.json>"; record_write "$1" "$2" ;;
  due)          [ $# -ge 1 ] || die "usage: due <repo>"; record_due "$1" ;;
  *) die "unknown subcommand: ${sub:-<none>} (record-path|record-read|record-write|due)" ;;
esac
