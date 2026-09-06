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

# Underscores are normalised to '-'. Verified against a real repo:
# /g/flutterDev/dynamic_day_planner keeps its memories under
# G--flutterDev-dynamic-day-planner. Getting this wrong writes to a directory
# nothing reads, silently -- hence a dedicated test on both platforms.
got="$(memory_key /g/flutterDev/dynamic_day_planner)"
[ "$got" = "G--flutterDev-dynamic-day-planner" ] \
  && ok "msys: underscores normalise to hyphens" \
  || bad "msys underscore gave '$got'"

got="$(memory_key /home/user/my_repo)"
[ "$got" = "-home-user-my-repo" ] \
  && ok "linux: underscores normalise to hyphens" \
  || bad "linux underscore gave '$got'"

# The form the PRODUCTION callers actually supply. sync-memory.sh and
# auto-commit.sh both derive the root from `git rev-parse --show-toplevel`,
# which on Git Bash returns a WINDOWS path (G:/a/b), never the MSYS form. Every
# case above hand-writes an MSYS or Linux path, so the one shape the real call
# site produces was the one shape never covered.
#
# Found 2026-09-05: the key came back as 'G:-pythonDev-news-brief', no
# directory matched, and both hooks silently no-opped for days with no error
# anywhere -- the news-brief corpus had drifted two entries behind.
got="$(memory_key "G:/pythonDev/news-brief")"
[ "$got" = "G--pythonDev-news-brief" ] \
  && ok "windows: G:/a/b -> G--a-b (the git rev-parse form)" \
  || bad "windows drive form gave '$got'"

got="$(memory_key 'G:\pythonDev\news-brief')"
[ "$got" = "G--pythonDev-news-brief" ] \
  && ok "windows: backslash form normalises identically" \
  || bad "windows backslash form gave '$got'"

got="$(memory_key "g:/pythonDev/news-brief")"
[ "$got" = "G--pythonDev-news-brief" ] \
  && ok "windows: lowercase drive letter uppercases" \
  || bad "windows lowercase drive gave '$got'"

# A key names a directory, so anything that cannot BE a directory name is a bug
# regardless of which input produced it. This is the property the colon
# violated, and it holds for every supported input shape.
for _in in "G:/a/b" 'G:\a\b' "/g/a/b" "/home/user/repo"; do
  _k="$(memory_key "$_in")"
  case "$_k" in
    ''|*[!A-Za-z0-9-]*) bad "key for '$_in' is not directory-safe: '$_k'" ;;
    *)                  ok  "key for '$_in' is directory-safe" ;;
  esac
done

echo "== sync-memory.sh =="

setup() {
  repo="$(mktemp -d)"; fakehome="$(mktemp -d)"
  cd "$repo" || exit 1
  git init -q -b main; git config user.email t@e.com; git config user.name T
  # The fixture below is built at whatever key memory_key returns, which means
  # these tests CANNOT fail on a wrong key: the fixture moves with the bug and
  # the hook still finds it. Replacing memory_key with `echo constant` used to
  # leave all four sync tests green. Assert the key is at least a name a
  # directory can have, so a malformed key fails here instead of passing
  # everywhere. (2026-09-05)
  key="$(memory_key "$(git rev-parse --show-toplevel)")"
  # Only the characters that genuinely cannot appear in a directory name. The
  # repo root here comes from mktemp (tmp.abc123), and there is no evidence on
  # this machine for how Claude Code keys a path containing a dot -- all 26 real
  # project keys derive from dot-free paths. Asserting a guess would send writes
  # to a directory nothing reads, which is the bug this test exists to catch.
  # The hand-written cases above keep the strict [A-Za-z0-9-] check.
  case "$key" in
    ''|*[:/\\]*)
      bad "setup derived an unusable project key: '$key'"
      return 1 ;;
  esac
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
