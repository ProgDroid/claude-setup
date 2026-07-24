#!/usr/bin/env bash
# Tests for auto-commit.sh.
#
# Run:  bash personal/hooks/test-auto-commit.sh
# Exits non-zero on the first failure.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/auto-commit.sh"
pass=0
fail=0

check() { # check <description> <expected: dirty|clean>
  local desc="$1" want="$2" got
  if [ -n "$(git status --porcelain)" ]; then got=dirty; else got=clean; fi
  if [ "$got" = "$want" ]; then
    echo "  PASS: $desc"
    pass=$((pass + 1))
  else
    echo "  FAIL: $desc (wanted tree $want, got $got)"
    fail=$((fail + 1))
  fi
}

newrepo() {
  local d
  d="$(mktemp -d)"
  cd "$d" || exit 1
  git init -q -b main
  git config user.email t@example.com
  git config user.name Test
  echo one > a.txt
  git add -A
  git commit -qm init
}

echo "== auto-commit.sh =="

# 1. Gate on, feature branch, dirty -> commits (tree becomes clean)
newrepo
git checkout -qb feature/x
echo two > a.txt
CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
check "commits WIP on a feature branch when the gate is set" clean

# 2. Gate unset, dirty -> must NOT commit
newrepo
git checkout -qb feature/y
echo two > a.txt
bash "$HOOK" >/dev/null 2>&1
check "does nothing when CLAUDE_CLOUD_SESSION is unset" dirty

# 3. Gate on, default branch, dirty -> must NOT commit
newrepo
echo two > a.txt
CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
check "refuses to auto-commit on the default branch" dirty

# 4. Gate on, clean tree -> no-op, exit 0
newrepo
git checkout -qb feature/z
CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  PASS: exits 0 on a clean tree"; pass=$((pass + 1))
else
  echo "  FAIL: exits $rc on a clean tree"; fail=$((fail + 1))
fi

# 5. Not a git repo -> exit 0, never fail the session
d="$(mktemp -d)"; cd "$d" || exit 1
CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "  PASS: exits 0 outside a git repo"; pass=$((pass + 1))
else
  echo "  FAIL: exits $rc outside a git repo"; fail=$((fail + 1))
fi

# 6. Untracked files are included, not just modifications
newrepo
git checkout -qb feature/w
echo new > untracked.txt
CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
check "commits untracked files too" clean

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
