#!/usr/bin/env bash
# Tests for sync-memory.sh and the shared lib-memory.sh key derivation.
#
# Run:  bash personal/hooks/test-sync-memory.sh

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/sync-memory.sh"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

echo "== lib-memory.sh: memory_key =="
. "$DIR/lib-memory.sh"

got="$(memory_key /home/user/repo)"
[ "$got" = "-home-user-repo" ] \
  && ok "linux: /home/user/repo -> -home-user-repo" \
  || bad "linux gave '$got'"

got="$(memory_key /g/rustDev/actual-budget-automation)"
[ "$got" = "G--rustDev-actual-budget-automation" ] \
  && ok "msys: /g/rustDev/... -> G--rustDev-..." \
  || bad "msys gave '$got'"

got="$(memory_key "/g/My Docs/proj")"
[ "$got" = "G--My-Docs-proj" ] \
  && ok "msys with a space in the path" \
  || bad "msys-with-space gave '$got'"

echo "== sync-memory.sh =="

setup() {
  repo="$(mktemp -d)"; fakehome="$(mktemp -d)"
  cd "$repo" || exit 1
  git init -q -b main; git config user.email t@e.com; git config user.name T
  key="$(memory_key "$(git rev-parse --show-toplevel)")"
  mkdir -p "$fakehome/.claude/projects/$key/memory"
  printf -- '---\nname: learned\n---\nbody\n' \
    > "$fakehome/.claude/projects/$key/memory/learned.md"
}

# 1. Repo opted in -> memory is copied
setup
mkdir -p "$repo/.claude/memory"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
[ -f "$repo/.claude/memory/learned.md" ] \
  && ok "copies local memories into an opted-in repo" \
  || bad "copies local memories into an opted-in repo"

# 2. Repo not opted in -> no directory is created
setup
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
[ -d "$repo/.claude/memory" ] \
  && bad "must not create .claude/memory in a repo that did not opt in" \
  || ok "leaves repos that did not opt in untouched"

# 3. Must NOT commit -- local commits belong to the developer
setup
mkdir -p "$repo/.claude/memory"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
if [ -n "$(git status --porcelain)" ]; then
  ok "syncs without committing (files left for a normal commit)"
else
  bad "syncs without committing (tree unexpectedly clean)"
fi

# 4. Cloud gate set -> defers to auto-commit.sh, does nothing here
setup
mkdir -p "$repo/.claude/memory"
CLAUDE_CLOUD_SESSION=1 HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
[ -f "$repo/.claude/memory/learned.md" ] \
  && bad "must defer to auto-commit.sh when the cloud gate is set" \
  || ok "defers to auto-commit.sh when the cloud gate is set"

# 5. Outside a git repo -> exit 0
d="$(mktemp -d)"; cd "$d" || exit 1
HOME="$(mktemp -d)" bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "exits 0 outside a git repo" || bad "non-zero outside a git repo"

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
