#!/usr/bin/env bash
# promote-to-core.sh <commit-message-file>
#
# Home-only promotion flow: commits what is STAGED in the dev clone of claude-setup and pushes it,
# after every guard is green. One yes from the user, nothing else to do.
#
# Needs:  CLAUDE_SETUP_CLONE            the dev clone (unset on a work machine: exit 3, nothing touched)
#         CLAUDE_SETUP_PRIVACY_PATTERNS the private pattern list (unset: exit 3)
# Exit:   0 promoted (last line "PROMOTED <sha>"); 1 a guard refused; 2 bad usage; 3 not configured.
# The message file is the caller's; this script never edits it. Every guard is an explicit
# `if ! cmd; then exit 1; fi`, so none of it depends on set -e.
#
# Limits, by design:
#   - Tracked files with UNSTAGED changes make it refuse (exit 1, "stage or stash"): the rules budget and
#     the tests read the worktree, so they could pass or fail on content that is not being committed.
#   - UNTRACKED files are not checked; they are not committed and nothing here depends on them.
#   - Only added, copied, modified and renamed paths count as staged. A deletion-only staging reports
#     "nothing is staged" and exits 1.
#   - Only core/ is tested (run-all-tests.sh --scope core). A personal/ edit promoted through here skips
#     personal's tests; CI runs the full suite on every push and is the alarm for those.

msgfile="${1:-}"

if [ -z "${CLAUDE_SETUP_CLONE:-}" ]; then
  echo "promote: CLAUDE_SETUP_CLONE is unset; promotion is home-only. Nothing was changed." >&2
  exit 3
fi
if [ -z "${CLAUDE_SETUP_PRIVACY_PATTERNS:-}" ]; then
  echo "promote: CLAUDE_SETUP_PRIVACY_PATTERNS is unset; refusing to publish without the privacy scan." >&2
  exit 3
fi
if [ -z "$msgfile" ] || [ ! -f "$msgfile" ]; then
  echo "promote: usage: promote-to-core.sh <commit-message-file> (not a file: ${msgfile:-<none>})" >&2
  exit 2
fi
case "$msgfile" in /*) ;; *) msgfile="$PWD/$msgfile" ;; esac

if ! cd "$CLAUDE_SETUP_CLONE"; then
  echo "promote: cannot cd to $CLAUDE_SETUP_CLONE" >&2
  exit 1
fi

# The push below sends the checked-out branch, and only main reaches the other machines.
branch="$(git symbolic-ref --short -q HEAD)" || branch="(detached HEAD)"
if [ "$branch" != "main" ]; then
  echo "promote: the clone is on $branch, not main; nothing committed" >&2
  exit 1
fi

# Capture the list first: a failure of git itself must stop here, not turn into an empty export below.
if ! staged="$(git -c core.quotepath=off diff --cached --name-only --diff-filter=ACMR)"; then
  echo "promote: could not list the staged files (git diff failed); nothing committed." >&2
  exit 1
fi
if [ -z "$staged" ]; then
  echo "promote: nothing is staged in $CLAUDE_SETUP_CLONE" >&2
  exit 1
fi
if ! git diff --quiet; then
  echo "promote: tracked files have unstaged changes; stage or stash them first (the budget check and the tests read the worktree)." >&2
  git -c core.quotepath=off diff --name-only | sed 's/^/  /' >&2
  exit 1
fi

if ! git pull --ff-only; then
  echo "promote: git pull --ff-only failed (diverged or offline); nothing committed." >&2
  exit 1
fi

# Scan what will be COMMITTED (the index), not the worktree, which may differ.
scan_dir="$(mktemp -d)"
trap 'rm -rf "$scan_dir"' EXIT
if ! printf '%s\n' "$staged" | tr '\n' '\0' | git checkout-index -z --stdin --prefix="$scan_dir/"; then
  echo "promote: could not export the staged content for scanning." >&2
  exit 1
fi
if [ -z "$(ls -A "$scan_dir")" ]; then
  echo "promote: the staged export is empty; refusing to scan nothing." >&2
  exit 1
fi
if ! bash scripts/privacy-scan.sh --patterns "$CLAUDE_SETUP_PRIVACY_PATTERNS" "$scan_dir"; then
  echo "promote: privacy scan refused (hit or unusable scan); nothing committed." >&2
  exit 1
fi

if ! command -v gitleaks >/dev/null 2>&1; then
  echo "promote: gitleaks is not on PATH; refusing to publish without the secret scan." >&2
  exit 1
fi
if ! gitleaks git --pre-commit --staged --config .gitleaks.toml --redact --no-banner; then
  echo "promote: gitleaks refused; nothing committed." >&2
  exit 1
fi

if ! bash scripts/check-rules-budget.sh; then
  echo "promote: rules budget refused; nothing committed." >&2
  exit 1
fi

# --scope core: the full suite takes up to an hour on Windows, which would break "seamless".
# CI runs the full suite on every push.
if ! bash scripts/run-all-tests.sh --scope core; then
  echo "promote: core tests failed; nothing committed." >&2
  exit 1
fi

if ! git commit -q -F "$msgfile"; then
  echo "promote: git commit failed." >&2
  exit 1
fi
if ! git push -q; then
  localsha="$(git rev-parse HEAD)"
  echo "promote: committed locally as $localsha but git push failed; it is NOT published." >&2
  echo "promote: run git push once the remote accepts it, or git reset --soft HEAD~1 to undo the commit and keep the changes staged." >&2
  exit 1
fi

sha="$(git rev-parse HEAD)"
echo "PROMOTED $sha"
exit 0
