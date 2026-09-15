#!/usr/bin/env bash
# Tests for auto-commit.sh.
#
# Run:  bash personal/hooks/test-auto-commit.sh
# Exits non-zero on the first failure.

set -uo pipefail

# Each case supplies its own gate; the ambient environment must never supply
# it. This script is itself run inside cloud sessions, where the environment
# exports CLAUDE_CLOUD_SESSION=1 -- inheriting it makes case 2 (gate unset ->
# must not commit) fail against a hook that is behaving correctly.
# (2026-09-15)
unset CLAUDE_CLOUD_SESSION

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/auto-commit.sh"
# Resolve paths and source the helper HERE, while the cwd is still this
# repo: every case below cds into a fresh mktemp repo, so a relative "$0"
# no longer resolves by the time a case runs.
. "$DIR/lib-memory.sh"
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

# 7. End-to-end: the memory sync must not commit a ROLLBACK of a repo file.
#
# This hook syncs before it commits, so an overwrite here is not merely lost in
# the worktree -- it is committed and pushed. That is exactly what happened in
# ProgDroid/constellation on 2026-09-15 (29373ab, f90dca7, 2be8145): a stale
# local memory kept being copied over a repo file the session had just
# restored, and each Stop pushed the revert. Main was spared only because the
# branch guard above returns first.
newrepo
git checkout -qb feature/mem
fakehome="$(mktemp -d)"
key="$(memory_key "$(git rev-parse --show-toplevel)")"
# An empty or unusable key would build the fixture somewhere the hook never
# looks, the sync would no-op, and this case would PASS for the wrong reason --
# the failure mode it exists to catch. Fail loudly instead.
case "$key" in
  ''|*[:/\\]*)
    echo "  FAIL: derived an unusable project key: '$key'"
    fail=$((fail + 1)) ;;
esac
mkdir -p "$fakehome/.claude/projects/$key/memory"
printf 'stale local copy\n' > "$fakehome/.claude/projects/$key/memory/notes.md"
touch -t 202001010000 "$fakehome/.claude/projects/$key/memory/notes.md"
mkdir -p .claude/memory
printf 'fresh repo edit\n' > .claude/memory/notes.md
CLAUDE_CLOUD_SESSION=1 HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
if git show HEAD:.claude/memory/notes.md 2>/dev/null | grep -q 'fresh repo edit'; then
  echo "  PASS: commits the repo's newer memory file, not a stale local rollback"
  pass=$((pass + 1))
else
  echo "  FAIL: committed a rollback of a repo memory file"
  fail=$((fail + 1))
fi

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
