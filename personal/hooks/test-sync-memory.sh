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

# Every fixture below comes from mktemp. One root, exported as TMPDIR, catches them all (the
# hook's own scratch dirs included), so the trap removes everything; 45 dirs used to be left
# behind per run. `cd /` first: Windows cannot delete the current directory.
TROOT="$(mktemp -d)" || exit 1
export TMPDIR="$TROOT"
trap 'cd / && rm -rf "$TROOT"' EXIT

# The '/x/rest' drive rewrite depends on the shell (core's rule: only under MINGW/MSYS/CYGWIN), so
# every case names the uname it runs under. A stub `uname` first on PATH stands in for the platform.
STUBS="$(mktemp -d)"
for _u in "msys:MINGW64_NT-10.0" "linux:Linux"; do
  mkdir -p "$STUBS/${_u%%:*}"
  printf '#!/bin/sh\necho %s\n' "${_u#*:}" > "$STUBS/${_u%%:*}/uname"
  chmod +x "$STUBS/${_u%%:*}/uname"
done
# mk <msys|linux> <path>: memory_key under that platform's uname.
mk() { PATH="$STUBS/$1:$PATH" memory_key "$2"; }
# expect <msys|linux> <path> <want> <label>
expect() {
  local got; got="$(mk "$1" "$2")"
  [ "$got" = "$3" ] && ok "$4" || bad "$4 (gave '$got', want '$3')"
}

expect linux "/home/user/repo" "-home-user-repo" "linux: /home/user/repo -> -home-user-repo"
expect msys "/g/rustDev/my-tool" "G--rustDev-my-tool" "msys: /g/rustDev/... -> G--rustDev-..."
expect msys "/g/My Docs/proj" "G--My-Docs-proj" "msys with a space in the path"

# On Linux '/g/a' is a real path, not a drive mount: it keys as '-g-a'. Under MSYS the same string
# is the drive form. The uname gate is what tells them apart.
expect linux "/g/rustDev/my-tool" "-g-rustDev-my-tool" "linux: /g/... is a real path, not a drive"
expect linux "/a/repo" "-a-repo" "linux: /a/repo -> -a-repo"
expect linux "/g/My Docs/proj" "-g-My-Docs-proj" "linux: a space keys as '-' with no drive rewrite"

# Underscores are normalised to '-'. Verified against a real repo:
# /g/flutterDev/my_app keeps its memories under
# G--flutterDev-my-app. Getting this wrong writes to a directory
# nothing reads, silently -- hence a dedicated test on both platforms.
expect msys "/g/flutterDev/my_app" "G--flutterDev-my-app" "msys: underscores normalise to hyphens"
expect linux "/home/user/my_repo" "-home-user-my-repo" "linux: underscores normalise to hyphens"

# Every character outside [A-Za-z0-9] becomes '-', a dot included. Real keys show it: a temp dir
# tmp.CYKwCSUeAA keys as ...-tmp-CYKwCSUeAA, and a worktree under <repo>/.claude/worktrees/<n>
# keys as <repo>--claude-worktrees-<n> (seven such dirs on the machine this was measured on).
expect msys "/g/web/my.app" "G--web-my-app" "msys: a dot keys as '-'"
expect msys "/g/x/.claude/worktrees/y" "G--x--claude-worktrees-y" "msys: a worktree path keys with a double hyphen"
expect linux "/home/u/a+b@c" "-home-u-a-b-c" "linux: punctuation keys as '-'"
expect linux "/tmp/tmp.CYKwCSUeAA" "-tmp-tmp-CYKwCSUeAA" "linux: a mktemp directory keys without its dot"

# The form the PRODUCTION callers actually supply. sync-memory.sh and
# auto-commit.sh both derive the root from `git rev-parse --show-toplevel`,
# which on Git Bash returns a WINDOWS path (G:/a/b), never the MSYS form. Every
# case above hand-writes an MSYS or Linux path, so the one shape the real call
# site produces was the one shape never covered.
#
# Found 2026-09-05: the key came back as 'G:-pythonDev-my-service', no
# directory matched, and both hooks silently no-opped for days with no error
# anywhere -- one project's corpus had drifted two entries behind.
for _pl in msys linux; do
  expect "$_pl" "G:/pythonDev/my-service" "G--pythonDev-my-service" "$_pl: G:/a/b -> G--a-b (the git rev-parse form)"
  expect "$_pl" 'G:\pythonDev\my-service' "G--pythonDev-my-service" "$_pl: backslash form normalises identically"
  expect "$_pl" "g:/pythonDev/my-service" "G--pythonDev-my-service" "$_pl: lowercase drive letter uppercases"
done

# A key names a directory, so anything that cannot BE a directory name is a bug
# regardless of which input produced it. This is the property the colon
# violated, and it holds for every supported input shape.
for _in in "G:/a/b" 'G:\a\b' "/g/a/b" "/home/user/repo" "/g/web/my.app" "/home/u/a+b@c"; do
  _k="$(mk msys "$_in")"
  case "$_k" in
    ''|*[!A-Za-z0-9-]*) bad "key for '$_in' is not directory-safe: '$_k'" ;;
    *)                  ok  "key for '$_in' is directory-safe" ;;
  esac
done

# The contract on empty input: return 1, print nothing.
_k="$(memory_key "")"; _rc=$?
[ "$_rc" = 1 ] && [ -z "$_k" ] && ok "empty input returns 1 and prints nothing" || bad "empty input: rc=$_rc out='$_k'"


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
  # The repo root here comes from mktemp (tmp.abc123). Claude Code keys a dot
  # as '-' (a real temp dir tmp.CYKwCSUeAA keys as ...-tmp-CYKwCSUeAA, and seven
  # real *--claude-worktrees-* keys show the same), so the strict
  # [A-Za-z0-9-] check applies here as it does to the hand-written cases above.
  case "$key" in
    ''|*[!A-Za-z0-9-]*)
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
# one project: a session had restored
# .claude/memory/project-status.md in the repo while the local copy was
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
# Measured 2026-09-22 in a notes repo: a cloud session created
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
# Measured 2026-10-03 in one project (core.autocrlf=true, no
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

# 17. A single run that exercises every branch at once: identical, overwrite,
# diverge, new (including a name with spaces) and a CRLF-only rewrite.
#
# The batched hashing pairs each local file with its repo counterpart by
# POSITION, so an off-by-one would silently compare a file against its
# neighbour. One-branch-per-fixture cases cannot see that; a mixed directory
# can. The manifest is checked byte for byte against what the per-file
# _memory_hash says each recorded state must be.
setup
mkdir -p "$repo/.claude/memory"
m="$fakehome/.claude/projects/$key/memory"; r="$repo/.claude/memory"
printf 'same\n'       > "$m/a-same.md"
printf 'v1\n'         > "$m/b-ours.md"
printf 'v1\n'         > "$m/c-theirs.md"
printf 'crlf later\n' > "$m/f-crlf.md"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1          # lineage for all of them
printf 'v2 local\n'   > "$m/b-ours.md"                 # ours to overwrite
printf 'cloud edit\n' > "$r/c-theirs.md"               # independent history
to_crlf "$r/f-crlf.md"                                 # git checkout only
cp "$r/f-crlf.md" "$m/../f-crlf.before"
printf 'new\n'        > "$m/d-new.md"
printf 'spaced\r\n'   > "$m/e new spaced.md"
out="$(HOME="$fakehome" bash "$HOOK" 2>/dev/null)"
if grep -q 'v2 local' "$r/b-ours.md" && grep -q 'cloud edit' "$r/c-theirs.md" \
   && [ -f "$r/d-new.md" ] && [ -f "$r/e new spaced.md" ]; then
  ok "mixed run: overwrite, keep, and both new files land correctly"
else
  bad "mixed run: wrong file contents after one sync"
fi
cmp -s "$r/f-crlf.md" "$m/../f-crlf.before" \
  && ok "mixed run: a CRLF-only rewrite is left byte-for-byte untouched" \
  || bad "mixed run: rewrote a file whose text had not changed"
case "$out" in
  *'kept the repo copy of c-theirs.md -- '*) ok "mixed run: exactly c-theirs.md reported as diverged" ;;
  *) bad "mixed run: wrong divergence report (got: ${out:-<empty>})" ;;
esac
want=""
for f in "$m"/*.md; do
  n="${f##*/}"
  case "$n" in c-theirs.md) src="$r/$n" ;; *) src="$f" ;; esac
  want="$want$(_memory_hash "$src")	$n
"
done
# Read it where the HOOK wrote it: under the fake HOME, at the key setup()
# derived from git's toplevel -- not memory_manifest_path, which would resolve
# against this shell's real HOME.
got="$(cat "$fakehome/.claude/projects/$key/.memory-sync-manifest" 2>/dev/null)
"
[ "$got" = "$want" ] \
  && ok "mixed run: manifest records exactly the per-file digests" \
  || bad "mixed run: manifest differs; want [$want] got [$got]"

echo "== lib-memory.sh: batched hashing =="

# The batch must agree with _memory_hash BYTE FOR BYTE. The per-machine
# manifest holds digests written by earlier runs of the per-file function, so
# any drift -- a CR kept, a trailing newline added or dropped -- would be read
# as every memory having diverged at once.
corpus="$(mktemp -d)"
printf 'one\r\ntwo\r\n'             > "$corpus/crlf.md"
printf 'one\ntwo\n'                 > "$corpus/lf.md"
printf 'one\r\ntwo\nthree\r\n'      > "$corpus/mixed.md"
printf 'no trailing newline'        > "$corpus/nonl.md"
printf 'no trailing newline\r'      > "$corpus/trailing-cr.md"
: >                                   "$corpus/empty.md"
printf 'lone\rcr mid-line\n'        > "$corpus/lonecr.md"
printf '\r\r\r'                     > "$corpus/only-crs.md"
printf 'spaced\r\nname\n'           > "$corpus/with space.md"
printf '\377\376\r\n\303\r(\n'      > "$corpus/bad-utf8.md"
printf 'nul\000byte\r\n'            > "$corpus/nul.md"
printf 'trailing\n\n\n'             > "$corpus/blank-tail.md"
printf 'back\\slash %%s\r\n'        > "$corpus/escapes.md"
awk 'BEGIN { for (i = 0; i < 20000; i++) printf "line %d of a large memory\r\n", i }' \
  > "$corpus/big.md"
mkdir "$corpus/dir.md"
eq_files=()
for f in "$corpus"/*.md; do eq_files+=("$f"); done
eq_files+=("$corpus/missing.md")

_memory_hash_batch "${eq_files[@]}" 2>/dev/null
i=0; oracle_empty=""
for f in "${eq_files[@]}"; do
  want="$(_memory_hash "$f" 2>/dev/null)" || want=""
  got="${_MEMORY_HASHES[$i]-}"
  [ -f "$f" ] && [ -z "$want" ] && oracle_empty="$oracle_empty ${f##*/}"
  [ "$got" = "$want" ] \
    && ok "batch hash matches _memory_hash: ${f##*/}" \
    || bad "batch hash for ${f##*/}: want '$want' got '$got'"
  i=$((i + 1))
done
# Control: a broken oracle would return '' everywhere and agree with a broken
# batch. Every regular file must have produced a real digest.
[ -z "$oracle_empty" ] \
  && ok "control: the per-file oracle produced a digest for every regular file" \
  || bad "control: oracle returned nothing for:$oracle_empty"

# The fallback hashers. A machine without sha256sum must get the SAME
# algorithm from the batch that _memory_hash would pick, so run both under a
# PATH holding only wrappers for the tools each branch needs.
#
# awk MUST be on that PATH: without it the batch drops to its per-file
# fallback, which agrees with the oracle trivially -- these two cases passed
# that way, testing nothing, until a mutation that broke the batch's CR
# stripping left them green (2026-10-18). equiv_under now refuses to report a
# pass when awk is missing.
mkbin() {
  _bin="$(mktemp -d)"
  for _c in "$@"; do
    _real="$(command -v "$_c" 2>/dev/null)" || continue
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$_real" > "$_bin/$_c"
    chmod +x "$_bin/$_c"
  done
  printf '%s' "$_bin"
}
equiv_under() {   # <bin-dir> <digest-shape-glob> -> "mismatch=N shape=ok|bad"
  (
    PATH="$1"
    command -v awk >/dev/null 2>&1 || { printf 'no awk on the test PATH'; exit 0; }
    _memory_hash_batch "${eq_files[@]}" 2>/dev/null
    _mm=0; _shape=ok; _i=0
    for _f in "${eq_files[@]}"; do
      _w="$(_memory_hash "$_f" 2>/dev/null)" || _w=""
      [ "${_MEMORY_HASHES[$_i]-}" = "$_w" ] || _mm=$((_mm + 1))
      if [ -f "$_f" ]; then
        case "$_w" in $2) ;; *) _shape=bad ;; esac
      fi
      _i=$((_i + 1))
    done
    printf 'mismatch=%s shape=%s' "$_mm" "$_shape"
  )
}
if command -v md5sum >/dev/null 2>&1; then
  b="$(mkbin md5sum cksum awk tr cut mktemp rm)"
  res="$(equiv_under "$b" '[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]')"
  [ "$res" = "mismatch=0 shape=ok" ] \
    && ok "md5sum fallback: batch matches _memory_hash" \
    || bad "md5sum fallback: $res"
else
  echo "  SKIP: no md5sum on this machine"
fi
if command -v cksum >/dev/null 2>&1; then
  b="$(mkbin cksum awk tr cut mktemp rm)"
  res="$(equiv_under "$b" '[0-9]*-[0-9]*')"
  [ "$res" = "mismatch=0 shape=ok" ] \
    && ok "cksum fallback: batch matches _memory_hash" \
    || bad "cksum fallback: $res"
else
  echo "  SKIP: no cksum on this machine"
fi

# seed_memory_manifest (hydrate-memory.sh's baseline) must write exactly what
# the per-file loop always wrote.
want=""
for f in "$corpus"/*.md; do
  h="$(_memory_hash "$f" 2>/dev/null)" || continue
  [ -n "$h" ] && want="$want$h	${f##*/}
"
done
smf="$(mktemp)"; rm -f "$smf"
seed_memory_manifest "$corpus" "$smf"
got="$(cat "$smf" 2>/dev/null)
"
[ "$got" = "$want" ] \
  && ok "seed_memory_manifest writes the per-file digests unchanged" \
  || bad "seed_memory_manifest drifted; want [$want] got [$got]"

echo "== sync-memory.sh: cost does not grow with the number of memories =="

# Measured 2026-10-18: with 108 memories the per-file hashing spawned ~650
# processes, took 36 s under Git Bash (~80 ms per spawn) and was killed by the
# hook's 20 s timeout on EVERY Stop -- so the manifest was never written and the
# files after the cut-off never synced. Count external commands rather than
# time them: the count is the cause, and it is the same on every platform.
spybin="$(mktemp -d)"
for c in sha256sum shasum md5sum cksum tr cut awk cp sed find mktemp rm mv cat \
         sort head wc xargs dirname basename; do
  real="$(command -v "$c" 2>/dev/null)" || continue
  printf '#!/bin/sh\necho x >> "$SPAWN_LOG"\nexec "%s" "$@"\n' "$real" > "$spybin/$c"
  chmod +x "$spybin/$c"
done
gen_memories() {   # <count> into the current fixture's local memory dir
  _n=0
  while [ "$_n" -lt "$1" ]; do
    printf -- '---\nname: gen-%d\n---\nbody %d\r\n' "$_n" "$_n" \
      > "$fakehome/.claude/projects/$key/memory/gen-$_n.md"
    _n=$((_n + 1))
  done
}
spawns_for() {     # <count> -> "<first-sync spawns> <steady-state spawns>"
  setup
  mkdir -p "$repo/.claude/memory"
  gen_memories "$1"
  _log="$(mktemp)"
  PATH="$spybin:$PATH" SPAWN_LOG="$_log" HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
  _first="$(wc -l < "$_log" | tr -d ' ')"
  : > "$_log"
  PATH="$spybin:$PATH" SPAWN_LOG="$_log" HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
  _steady="$(wc -l < "$_log" | tr -d ' ')"
  printf '%s %s' "$_first" "$_steady"
}
small="$(spawns_for 20)"; large="$(spawns_for 150)"
[ "${small#* }" = "${large#* }" ] \
  && ok "steady-state spawns independent of file count (20 files: ${small#* }, 150: ${large#* })" \
  || bad "steady-state spawns grow with file count (20 files: ${small#* }, 150: ${large#* })"
# The first sync copies every file, in one `cp` per 30,000 characters of paths
# (lib-memory.sh, the Windows argument limit). Fixture paths hold $TMPDIR twice,
# so a long TMPDIR splits 150 files into two cp calls: 10 vs 11, which this check
# used to report as growth. Allow 2; one spawn per file adds ~130 here.
if [ "$(( ${large% *} - ${small% *} ))" -le 2 ]; then
  ok "first-sync spawns bounded, not per file (20 files: ${small% *}, 150: ${large% *})"
else
  bad "first-sync spawns grow with file count (20 files: ${small% *}, 150: ${large% *})"
fi

# And the budget itself: a first sync plus a steady-state sync of 150 memories
# inside 30 s, i.e. each one inside the hook's 20 s timeout on average.
# Measured 2026-10-18 under Git Bash: ~88 s before the fix, ~7 s after; 11.2 s on
# 2026-10-20 with all 22 suites in parallel. 30 s sits near the geometric mean of
# 11 and 88, so it discriminates by ~3x either way on a loaded machine.
# Only discriminating where process creation is slow (Git Bash), which is where
# the bug lives; the spawn counts above are the portable guard.
now_ms() {
  if [ -n "${EPOCHREALTIME:-}" ]; then _t="${EPOCHREALTIME/[.,]/}"; printf '%s' $((_t / 1000))
  else printf '%s' $((SECONDS * 1000)); fi
}
setup
mkdir -p "$repo/.claude/memory"
gen_memories 150
t0="$(now_ms)"
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
HOME="$fakehome" bash "$HOOK" >/dev/null 2>&1
el=$(( $(now_ms) - t0 ))
synced=0; for f in "$repo/.claude/memory"/gen-*.md; do [ -f "$f" ] && synced=$((synced + 1)); done
if [ "$el" -lt 30000 ] && [ "$synced" -eq 150 ]; then
  ok "150 memories: two syncs in ${el} ms, all 150 landed"
else
  bad "150 memories: two syncs took ${el} ms, $synced/150 landed (budget 30000 ms)"
fi

# 7. Outside a git repo -> exit 0
d="$(mktemp -d)"; cd "$d" || exit 1
HOME="$(mktemp -d)" bash "$HOOK" >/dev/null 2>&1
[ $? -eq 0 ] && ok "exits 0 outside a git repo" || bad "non-zero outside a git repo"

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
