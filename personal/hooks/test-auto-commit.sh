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
  # Each repo gets its OWN parent dir. The hook commits sibling repos of the
  # cwd's repo (multi-repo sessions); a repo created directly in /tmp would make
  # every other git repo under /tmp a "sibling" -- committed and pushed.
  d="$(mktemp -d)/repo"
  mkdir -p "$d"
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

# --- Multi-repo sessions (verified missing 2026-10-03) ----------------------
# A session with several repos starts in /home/user (not a repo) with each repo
# cloned beneath it, and the cwd later drifts into whichever repo is being
# worked on. The hook used to act only on the repo containing the cwd, so work
# and memories in the other repos were never committed or pushed.

# mkrepo <dir> <branch> : a repo with one commit, checked out on <branch>
mkrepo() {
  mkdir -p "$1"
  git -C "$1" init -q -b main
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
  echo one > "$1/a.txt"
  git -C "$1" add -A
  git -C "$1" commit -qm init
  [ "$2" = main ] || git -C "$1" checkout -qb "$2"
}
treestate() { [ -n "$(git -C "$1" status --porcelain)" ] && echo dirty || echo clean; }
expect() { # expect <desc> <dir> <dirty|clean>
  if [ "$(treestate "$2")" = "$3" ]; then echo "  PASS: $1"; pass=$((pass + 1))
  else echo "  FAIL: $1 (wanted $3)"; fail=$((fail + 1)); fi
}

# 8. cwd is the plain parent dir: every child repo on a feature branch commits
parent="$(mktemp -d)"
mkrepo "$parent/alpha" feature/a; echo two > "$parent/alpha/a.txt"
mkrepo "$parent/beta" feature/b;  echo two > "$parent/beta/a.txt"
mkrepo "$parent/gamma" main;      echo two > "$parent/gamma/a.txt"
mkdir -p "$parent/plain"; echo x > "$parent/plain/f.txt"
( cd "$parent" && CLAUDE_CLOUD_SESSION=1 HOME="$(mktemp -d)" bash "$HOOK" >/dev/null 2>&1 )
expect "multi-repo: cwd=parent commits child repo alpha" "$parent/alpha" clean
expect "multi-repo: cwd=parent commits child repo beta" "$parent/beta" clean
expect "multi-repo: a child repo on main is still left alone" "$parent/gamma" dirty

# 9. cwd drifted INTO one repo: sibling repos are committed too
parent="$(mktemp -d)"
mkrepo "$parent/alpha" feature/a; echo two > "$parent/alpha/a.txt"
mkrepo "$parent/beta" feature/b;  echo two > "$parent/beta/a.txt"
( cd "$parent/alpha" && CLAUDE_CLOUD_SESSION=1 HOME="$(mktemp -d)" bash "$HOOK" >/dev/null 2>&1 )
expect "multi-repo: cwd inside alpha still commits sibling beta" "$parent/beta" clean
expect "multi-repo: cwd inside alpha commits alpha" "$parent/alpha" clean

# 10. A sibling's WIP is pushed to its own remote branch
parent="$(mktemp -d)"
mkrepo "$parent/alpha" feature/a
mkrepo "$parent/beta" feature/b; echo two > "$parent/beta/a.txt"
git init -q --bare "$parent/beta-remote.git"
git -C "$parent/beta" remote add origin "$parent/beta-remote.git"
( cd "$parent/alpha" && CLAUDE_CLOUD_SESSION=1 HOME="$(mktemp -d)" bash "$HOOK" >/dev/null 2>&1 )
if [ "$(git -C "$parent/beta-remote.git" rev-parse --verify -q refs/heads/feature/b)" = \
     "$(git -C "$parent/beta" rev-parse HEAD)" ]; then
  echo "  PASS: multi-repo: sibling WIP is pushed to its own branch"; pass=$((pass + 1))
else
  echo "  FAIL: multi-repo: sibling WIP was not pushed"; fail=$((fail + 1))
fi

# 11. Each repo's memories sync back under ITS OWN key, not the cwd's
parent="$(mktemp -d)"; fh="$(mktemp -d)"
mkrepo "$parent/alpha" feature/a
mkrepo "$parent/beta" feature/b; mkdir -p "$parent/beta/.claude/memory"
echo "- [b](b.md)" > "$parent/beta/.claude/memory/MEMORY.md"
git -C "$parent/beta" add -A; git -C "$parent/beta" commit -qm mem
bkey="$(memory_key "$(git -C "$parent/beta" rev-parse --show-toplevel)")"
mkdir -p "$fh/.claude/projects/$bkey/memory"
printf -- '---\nname: learned\n---\nlearned in session\n' > "$fh/.claude/projects/$bkey/memory/learned.md"
( cd "$parent/alpha" && CLAUDE_CLOUD_SESSION=1 HOME="$fh" bash "$HOOK" >/dev/null 2>&1 )
if git -C "$parent/beta" show HEAD:.claude/memory/learned.md 2>/dev/null | grep -q 'learned in session'; then
  echo "  PASS: multi-repo: a sibling's session memory is synced and committed"; pass=$((pass + 1))
else
  echo "  FAIL: multi-repo: sibling memory not synced/committed"; fail=$((fail + 1))
fi

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
