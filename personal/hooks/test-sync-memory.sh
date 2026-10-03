#!/usr/bin/env bash
# Tests for sync-memory.sh and the shared lib-memory.sh key derivation.
#
# Run:  bash personal/hooks/test-sync-memory.sh

set -uo pipefail

# Each case supplies its own gate; the ambient environment must never supply
# it. This script is itself run inside cloud sessions, where the environment
# exports CLAUDE_CLOUD_SESSION=1 -- inheriting it makes sync-memory.sh exit at
# its first line and fails cases that have nothing to do with the gate, which
# reads as a broken hook rather than a leaky test. (2026-09-15)
unset CLAUDE_CLOUD_SESSION

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

# 5. A repo file NEWER than its local counterpart is NOT overwritten.
#
# WHY: this copy is one-way and used to be unconditional, which made the local
# memory dir the sole authority -- anything written straight into a repo's
# .claude/memory/ was destroyed at the next Stop. Observed 2026-09-15 in
# ProgDroid/constellation: a session had restored
# .claude/memory/constellation-status.md in the repo while the local copy was
# 25 stale lines written early in the session. Every Stop copied the stale file
# back over the good one and auto-commit.sh committed the rollback -- three
# times (29373ab, f90dca7, 2be8145), each reverting a restore the session had
# just pushed. No error, no output; a whole-branch review caught it.
setup
mkdir -p "$repo/.claude/memory"
printf -- '---\nname: learned\n---\nfresh repo edit\n' \
  > "$repo/.claude/memory/learned.md"
# Age the local copy so "the repo file is newer" holds regardless of filesystem
# timestamp granularity -- both files are otherwise written within one second.
touch -t 202001010000 "$fakehome/.claude/projects/$key/memory/learned.md"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
grep -q 'fresh repo edit' "$repo/.claude/memory/learned.md" \
  && ok "leaves a repo file newer than its local counterpart alone" \
  || bad "clobbered a newer repo file with a stale local memory"

# 6. The guard must not disable the mechanism it guards: a local edit still
# syncs out.
#
# REWRITTEN 2026-09-22. It used to assert "the local file is newer than the
# repo copy, therefore overwrite" -- which is the buggy rule itself, see case 8.
# The intent was always "never let the guard turn the hook into a no-op", and
# that intent is unchanged; only the thing asserted moved, from a timestamp
# comparison to lineage. Sync once to establish lineage, edit locally, sync
# again.
setup
mkdir -p "$repo/.claude/memory"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
printf -- '---\nname: learned\n---\nsecond draft\n' \
  > "$fakehome/.claude/projects/$key/memory/learned.md"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
grep -q 'second draft' "$repo/.claude/memory/learned.md" \
  && ok "syncs a later local edit over a copy this sync itself wrote" \
  || bad "failed to sync a later local edit over its own prior output"

# 8. THE INCIDENT. A repo file with an independent history is not overwritten,
# even when the local file is unambiguously newer.
#
# Measured 2026-09-22 in ProgDroid/aegyptvault-notes: a cloud session created
# .claude/memory/ with its own MEMORY.md -- a 15-line index of 2 notes. Locally
# a 97-line MEMORY.md indexed 100 notes under the same project key. Two
# DIFFERENT documents sharing one filename. The local one was newer, so `cp -u`
# overwrote the repo's at every Stop, destroying edits made to it minutes
# earlier; in a cloud session auto-commit.sh commits that loss.
#
# Case 5 is the same rule seen from the other side and mtime could express that
# one, which is exactly why it was mistaken for the whole fix. Here the
# aggressor IS newer, so no timestamp rule can help.
setup
mkdir -p "$repo/.claude/memory"
printf -- '---\nname: learned\n---\nindependent cloud history\n' \
  > "$repo/.claude/memory/learned.md"
touch -t 202001010000 "$repo/.claude/memory/learned.md"   # repo copy is OLDER
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
grep -q 'independent cloud history' "$repo/.claude/memory/learned.md" \
  && ok "keeps an older repo file that this sync never wrote" \
  || bad "clobbered an independent repo file because the local one was newer"

# 9. ...and says so. Silence is how the old copy did its damage unnoticed, and
# a Stop hook's plain stdout only reaches the transcript view -- so the report
# has to be a systemMessage to be seen at all.
setup
mkdir -p "$repo/.claude/memory"
printf -- '---\nname: learned\n---\nindependent cloud history\n' \
  > "$repo/.claude/memory/learned.md"
touch -t 202001010000 "$repo/.claude/memory/learned.md"
out="$(HOME="$fakehome" bash "$HOOK" 2>/dev/null)"
case "$out" in
  *'"systemMessage"'*learned.md*) ok "reports the divergence as a systemMessage" ;;
  *) bad "divergence went unreported (got: ${out:-<empty>})" ;;
esac

# 10. A clean sync stays silent. A hook that speaks every turn is a hook that
# gets switched off, so the report must be exceptional.
setup
mkdir -p "$repo/.claude/memory"
out="$(HOME="$fakehome" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] \
  && ok "says nothing when there is nothing to report" \
  || bad "spoke on a clean sync (got: $out)"

# 11. A divergence on one file must not block unrelated new memories. The
# failure mode to avoid is a single stuck file freezing the whole mechanism.
setup
mkdir -p "$repo/.claude/memory"
printf -- '---\nname: learned\n---\nindependent cloud history\n' \
  > "$repo/.claude/memory/learned.md"
printf -- '---\nname: fresh\n---\nbrand new\n' \
  > "$fakehome/.claude/projects/$key/memory/fresh.md"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
if [ -f "$repo/.claude/memory/fresh.md" ] \
   && grep -q 'independent cloud history' "$repo/.claude/memory/learned.md"; then
  ok "copies unrelated new memories while one file is diverged"
else
  bad "a diverged file blocked an unrelated new memory"
fi

# 12. Once a human reconciles the divergence, the sync resumes on its own --
# no reset step to remember. Making the two sides identical re-establishes
# lineage, and the next local edit flows again.
setup
mkdir -p "$repo/.claude/memory"
printf -- '---\nname: learned\n---\nindependent cloud history\n' \
  > "$repo/.claude/memory/learned.md"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1          # refuses, records the repo copy
cp "$repo/.claude/memory/learned.md" \
   "$fakehome/.claude/projects/$key/memory/learned.md"  # human reconciles
printf -- '---\nname: learned\n---\nafter reconciliation\n' \
  > "$fakehome/.claude/projects/$key/memory/learned.md"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
grep -q 'after reconciliation' "$repo/.claude/memory/learned.md" \
  && ok "resumes syncing once the divergence is reconciled by hand" \
  || bad "stayed stuck after the divergence was reconciled"

# 13. A file present in the repo but absent locally is left alone -- the sync
# adds and updates, it never prunes. A cloud session's memory must survive a
# local Stop that has never seen it.
setup
mkdir -p "$repo/.claude/memory"
printf -- '---\nname: cloud-only\n---\nwritten in the cloud\n' \
  > "$repo/.claude/memory/cloud-only.md"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
[ -f "$repo/.claude/memory/cloud-only.md" ] \
  && ok "never deletes a repo memory that does not exist locally" \
  || bad "removed a repo-only memory"

# 14. A line-ending-only change is not a divergence.
#
# Measured 2026-10-03 in ds-job-analysis (core.autocrlf=true, no
# .gitattributes): this sync wrote LF files into .claude/memory/, a merge
# checkout rewrote them as CRLF, and the next Stop reported every one of them as
# "diverged" and refused to update them -- twice in one session. Same text,
# different bytes: git's own conversion, not an independent history. Simulate
# the checkout by rewriting the repo copy with CRLF after lineage exists.
to_crlf() { awk '{ printf "%s\r\n", $0 }' "$1" > "$1.crlf" && mv -f "$1.crlf" "$1"; }
setup
mkdir -p "$repo/.claude/memory"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1          # establish lineage (LF)
to_crlf "$repo/.claude/memory/learned.md"              # git checkout -> CRLF
out="$(HOME="$fakehome" bash "$HOOK" 2>/dev/null)"
[ -z "$out" ] \
  && ok "a CRLF-only rewrite of a synced file is not reported as diverged" \
  || bad "reported a CRLF-only rewrite as a divergence (got: $out)"

# 15. ...and the next real local edit still flows over the CRLF copy.
printf -- '---\nname: learned\n---\nedit after checkout\n' \
  > "$fakehome/.claude/projects/$key/memory/learned.md"
out="$(HOME="$fakehome" bash "$HOOK" 2>/dev/null)"
if grep -q 'edit after checkout' "$repo/.claude/memory/learned.md" && [ -z "$out" ]; then
  ok "syncs a local edit over its own CRLF-converted prior output"
else
  bad "a CRLF checkout froze the sync (got: ${out:-<empty>})"
fi

# 16. The normalisation must not hide a REAL independent edit: a CRLF repo file
# whose text differs is still a divergence and is still left alone.
setup
mkdir -p "$repo/.claude/memory"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1          # establish lineage
printf -- '---\nname: learned\n---\nindependent cloud history\n' \
  > "$repo/.claude/memory/learned.md"
to_crlf "$repo/.claude/memory/learned.md"
printf -- '---\nname: learned\n---\nlocal draft\n' \
  > "$fakehome/.claude/projects/$key/memory/learned.md"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
grep -q 'independent cloud history' "$repo/.claude/memory/learned.md" \
  && ok "still keeps a CRLF repo file whose text was edited independently" \
  || bad "line-ending normalisation let an independent edit be clobbered"

# 7. Outside a git repo -> exit 0
d="$(mktemp -d)"; cd "$d" || exit 1
HOME="$(mktemp -d)" bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "exits 0 outside a git repo" || bad "non-zero outside a git repo"

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
