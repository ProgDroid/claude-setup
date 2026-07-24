#!/usr/bin/env bash
# Tests for hydrate-memory.sh.
#
# Run:  bash personal/hooks/test-hydrate-memory.sh
# HOME is redirected to a temp dir so the real memory corpus is never touched.

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/hydrate-memory.sh"
pass=0
fail=0

ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }

# Creates a fake repo with committed memories, and an isolated fake HOME.
# Echoes the memory destination the hook should populate.
setup() {
  repo="$(mktemp -d)"
  fakehome="$(mktemp -d)"
  mkdir -p "$repo/.claude/memory"
  echo "- [Thing](thing.md) - a hook" > "$repo/.claude/memory/MEMORY.md"
  printf -- '---\nname: thing\n---\nbody\n' > "$repo/.claude/memory/thing.md"
  cd "$repo" || exit 1
  key="$(printf '%s' "$PWD" | tr '/' '-')"
  dest="$fakehome/.claude/projects/$key/memory"
}

echo "== hydrate-memory.sh =="

# 1. Gate set: repo memories land in the subsystem's path
setup
HOME="$fakehome" CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
if [ -f "$dest/thing.md" ] && [ -f "$dest/MEMORY.md" ]; then
  ok "copies repo memories into ~/.claude/projects/<key>/memory/"
else
  bad "copies repo memories into ~/.claude/projects/<key>/memory/ (dest=$dest)"
fi

# 2. Gate unset: must not touch anything
setup
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
if [ -e "$dest/thing.md" ]; then
  bad "does nothing when CLAUDE_CLOUD_SESSION is unset"
else
  ok "does nothing when CLAUDE_CLOUD_SESSION is unset"
fi

# 3. Repo has no .claude/memory: exit 0, no crash
repo="$(mktemp -d)"; fakehome="$(mktemp -d)"; cd "$repo" || exit 1
HOME="$fakehome" CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "exits 0 when the repo carries no memories" \
             || bad "non-zero exit when the repo carries no memories"

# 4. Project key derivation matches the verified cloud format
got="$(printf '%s' "/home/user/repo" | tr '/' '-')"
[ "$got" = "-home-user-repo" ] \
  && ok "key derivation: /home/user/repo -> -home-user-repo" \
  || bad "key derivation produced '$got', expected '-home-user-repo'"

# 5. Existing unrelated memories in the destination survive
setup
mkdir -p "$dest"
echo "keep me" > "$dest/pre-existing.md"
HOME="$fakehome" CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
if [ -f "$dest/pre-existing.md" ] && [ -f "$dest/thing.md" ]; then
  ok "merges rather than replacing the destination directory"
else
  bad "merges rather than replacing the destination directory"
fi

# 6. Plugin memories are loaded too, and a repo memory of the same name wins
setup
plug="$(mktemp -d)"
mkdir -p "$plug/memory"
printf -- '---\nname: crossproj\n---\ncross-project body\n' > "$plug/memory/crossproj.md"
printf -- '---\nname: thing\n---\nPLUGIN VERSION\n' > "$plug/memory/thing.md"
HOME="$fakehome" CLAUDE_PLUGIN_ROOT="$plug" CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1
if [ -f "$dest/crossproj.md" ]; then
  ok "loads cross-project memories shipped with the plugin"
else
  bad "loads cross-project memories shipped with the plugin"
fi
if grep -q 'PLUGIN VERSION' "$dest/thing.md" 2>/dev/null; then
  bad "repo memory must override a plugin memory of the same name"
else
  ok "repo memory overrides a plugin memory of the same name"
fi

# 7. The index is PRINTED, not merely copied. This is the regression that
#    matters most: a cloud session reported "Loaded 13 memories" and had none
#    of them in context, because copying files is invisible to a session whose
#    memory index was already read.
setup
out="$(HOME="$fakehome" CLAUDE_CLOUD_SESSION=1 bash "$HOOK" 2>/dev/null)"
if printf '%s' "$out" | grep -q 'a hook'; then
  ok "prints the repo memory index to stdout (session context)"
else
  bad "prints the repo memory index to stdout (session context)"
fi

# 8. Bodies are NOT printed - index only, so startup cost stays bounded
setup
printf -- '---\nname: big\n---\nUNIQUEBODYMARKER\n' > "$repo/.claude/memory/big.md"
out="$(HOME="$fakehome" CLAUDE_CLOUD_SESSION=1 bash "$HOOK" 2>/dev/null)"
if printf '%s' "$out" | grep -q 'UNIQUEBODYMARKER'; then
  bad "must print the index only, never memory bodies"
else
  ok "prints the index only, never memory bodies"
fi

# 9. Silent when the gate is unset (no stray output in local sessions)
setup
out="$(HOME="$fakehome" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] && ok "prints nothing when the gate is unset" \
              || bad "printed output with the gate unset: $out"

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
