#!/usr/bin/env bash
# Tests for core/scripts/promote-to-core.sh, against a temp bare remote and clone.
# The clone carries STUB scripts (privacy-scan, rules budget, test runner, gitleaks) so the test
# exercises promote's wiring and never recurses into the real suite.
#
# Run:  bash core/tests/test-promote.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMOTE="$REPO/core/scripts/promote-to-core.sh"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null

# gitleaks stub: records its cwd and args; fails when GL_FAIL=1
mkdir -p "$T/bin"
cat > "$T/bin/gitleaks" <<'STUB'
#!/usr/bin/env bash
echo "$PWD|$*" >> "${GL_LOG:-/dev/null}"
[ "${GL_FAIL:-0}" = 1 ] && { echo "gitleaks stub: leak" >&2; exit 1; }
exit 0
STUB
chmod +x "$T/bin/gitleaks"

# PATH with every directory that holds a real gitleaks removed
NOGL_PATH="$(printf '%s' "$PATH" | tr ':' '\n' | while IFS= read -r d; do
  [ -x "$d/gitleaks" ] || [ -x "$d/gitleaks.exe" ] || printf '%s\n' "$d"; done | paste -sd: -)"

n=0
# setup: builds $T/c<n>/{remote.git,clone}; sets REMOTE CLONE PATTERNS MSG GL_LOG OUT
setup() {
  n=$((n + 1)); local base="$T/c$n" seed="$T/c$n/seed"
  REMOTE="$base/remote.git"; CLONE="$base/clone"
  mkdir -p "$base"
  git init -q --bare -b main "$REMOTE"
  git init -q -b main "$seed"
  mkdir -p "$seed/scripts"
  cat > "$seed/scripts/privacy-scan.sh" <<'STUB'
#!/usr/bin/env bash
# stub: real grep of the pattern file over the given paths (so promote must hand it the staged content)
pf=""; paths=()
while [ $# -gt 0 ]; do case "$1" in --patterns) pf="$2"; shift 2 ;; *) paths+=("$1"); shift ;; esac; done
echo "privacy-scan stub paths: ${#paths[@]}" >> "${CLAUDE_SETUP_CLONE}/.privacy-calls"
[ -f "$pf" ] || exit 2
grep -rEqi -f "$pf" "${paths[@]}" && { echo "privacy-scan stub: hit"; exit 1; }
exit 0
STUB
  cat > "$seed/scripts/check-rules-budget.sh" <<'STUB'
#!/usr/bin/env bash
[ -e "${CLAUDE_SETUP_CLONE}/.fail-budget" ] && { echo "budget stub: over"; exit 1; }
exit 0
STUB
  cat > "$seed/scripts/run-all-tests.sh" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "${CLAUDE_SETUP_CLONE}/.tests-args"
[ -e "${CLAUDE_SETUP_CLONE}/.fail-tests" ] && { echo "tests stub: failed"; echo "REAL_EXIT=1"; exit 1; }
echo "REAL_EXIT=0"; exit 0
STUB
  printf 'seed\n' > "$seed/README.md"
  printf '[extend]\nuseDefault = true\n' > "$seed/.gitleaks.toml"
  git -C "$seed" add -A; git -C "$seed" commit -q -m seed
  git -C "$seed" remote add origin "$REMOTE"; git -C "$seed" push -q origin main
  git clone -q "$REMOTE" "$CLONE" 2>/dev/null
  printf 'canary-zq81\n' > "$base/patterns.txt"
  PATTERNS="$base/patterns.txt"
  MSG="$base/msg.txt"
  printf 'feat(core): promoted lesson\n\nbody line\n\nCo-Authored-By: X <x@example.invalid>\n' > "$MSG"
  GL_LOG="$base/gl.log"; : > "$GL_LOG"
  OUT="$base/out"; : > "$OUT"
}
stage() { mkdir -p "$(dirname "$CLONE/$1")"; printf '%s' "$2" > "$CLONE/$1"; git -C "$CLONE" add "$1"; }
head_of() { git -C "$1" rev-parse HEAD 2>/dev/null; }
remote_head() { git --git-dir="$REMOTE" rev-parse refs/heads/main; }
other_pushes() { # a second clone pushes a commit to the remote first
  git clone -q "$REMOTE" "$T/other$n" 2>/dev/null
  printf 'o\n' > "$T/other$n/o.txt"; git -C "$T/other$n" add o.txt; git -C "$T/other$n" commit -q -m other
  git -C "$T/other$n" push -q origin main
}
# run_promote [env assignments...]: runs promote from inside the clone
run_promote() {
  ( cd "$CLONE" && env "$@" bash "$PROMOTE" "$MSG" ) > "$OUT" 2>&1
}
GOODENV=()
good_env() { GOODENV=( CLAUDE_SETUP_CLONE="$CLONE" CLAUDE_SETUP_PRIVACY_PATTERNS="$PATTERNS" PATH="$T/bin:$PATH" GL_LOG="$GL_LOG" ); }

# check_refused <label> <want-rc> <rc> <clone-head-before> <remote-head-before>
check_refused() {
  local label="$1" want="$2" rc="$3" lh="$4" rh="$5"
  [ "$rc" -eq "$want" ] && ok "$label: exit $want" || bad "$label: wanted exit $want, got $rc ($(tail -n 3 "$OUT" | tr '\n' '|'))"
  [ "$(head_of "$CLONE")" = "$lh" ] && ok "$label: nothing committed" || bad "$label: clone HEAD moved"
  [ "$(remote_head)" = "$rh" ] && ok "$label: remote HEAD unchanged" || bad "$label: remote HEAD moved"
  if grep -q '^PROMOTED ' "$OUT"; then bad "$label: printed PROMOTED"; else ok "$label: no PROMOTED line"; fi
}

echo "== env =="
setup; stage core/a.md "fine"; good_env
lh=$(head_of "$CLONE"); rh=$(remote_head)
( cd "$CLONE" && env -u CLAUDE_SETUP_CLONE CLAUDE_SETUP_PRIVACY_PATTERNS="$PATTERNS" PATH="$T/bin:$PATH" bash "$PROMOTE" "$MSG" ) > "$OUT" 2>&1; rc=$?
check_refused "CLAUDE_SETUP_CLONE unset" 3 "$rc" "$lh" "$rh"
[ -n "$(git -C "$CLONE" diff --cached --name-only)" ] && ok "unset: staged change left alone" || bad "unset: staging touched"
( cd "$CLONE" && env -u CLAUDE_SETUP_PRIVACY_PATTERNS CLAUDE_SETUP_CLONE="$CLONE" PATH="$T/bin:$PATH" bash "$PROMOTE" "$MSG" ) > "$OUT" 2>&1; rc=$?
check_refused "CLAUDE_SETUP_PRIVACY_PATTERNS unset" 3 "$rc" "$lh" "$rh"
( cd "$CLONE" && env CLAUDE_SETUP_CLONE="$CLONE" CLAUDE_SETUP_PRIVACY_PATTERNS="$PATTERNS" PATH="$T/bin:$PATH" bash "$PROMOTE" "$T/no-such-msg" ) > "$OUT" 2>&1; rc=$?
check_refused "missing message file" 2 "$rc" "$lh" "$rh"

echo "== guards =="
setup; stage core/a.md "this has canary-zq81 in it"; good_env
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}"; rc=$?
check_refused "staged file with a pattern" 1 "$rc" "$lh" "$rh"
# staged content, not worktree content, is what is scanned
# Unstaged tracked edits are refused (below), so to make the worktree differ from the index without
# tripping that guard the entry is marked assume-unchanged; only the INDEX content has the pattern.
git -C "$CLONE" update-index --assume-unchanged core/a.md
printf 'clean now' > "$CLONE/core/a.md"
run_promote "${GOODENV[@]}"; rc=$?
check_refused "pattern staged, worktree since cleaned" 1 "$rc" "$lh" "$rh"
if grep -qi 'privacy' "$OUT"; then ok "that refusal came from the privacy scan"; else bad "refusal was not the privacy scan: $(cat "$OUT")"; fi

setup; stage core/a.md "fine"; good_env
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}" GL_FAIL=1; rc=$?
check_refused "gitleaks reports a leak" 1 "$rc" "$lh" "$rh"

setup; stage core/a.md "fine"
lh=$(head_of "$CLONE"); rh=$(remote_head)
( cd "$CLONE" && env CLAUDE_SETUP_CLONE="$CLONE" CLAUDE_SETUP_PRIVACY_PATTERNS="$PATTERNS" PATH="$NOGL_PATH" bash "$PROMOTE" "$MSG" ) > "$OUT" 2>&1; rc=$?
if PATH="$NOGL_PATH" command -v gitleaks >/dev/null 2>&1; then bad "control: gitleaks still on the filtered PATH"; else ok "control: filtered PATH has no gitleaks"; fi
check_refused "gitleaks absent (fail closed)" 1 "$rc" "$lh" "$rh"
if grep -qi 'gitleaks' "$OUT"; then ok "absent gitleaks is named in the message"; else bad "absent gitleaks message: $(cat "$OUT")"; fi

setup; stage core/a.md "fine"; good_env; : > "$CLONE/.fail-budget"
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}"; rc=$?
check_refused "rules budget over" 1 "$rc" "$lh" "$rh"

setup; stage core/a.md "fine"; good_env; : > "$CLONE/.fail-tests"
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}"; rc=$?
check_refused "tests fail" 1 "$rc" "$lh" "$rh"
[ -f "$CLONE/.tests-args" ] && ok "tests stub was actually run" || bad "tests stub never ran"

setup; good_env
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}"; rc=$?
check_refused "nothing staged" 1 "$rc" "$lh" "$rh"

# the clone is not on main: a push would not reach the other machines
setup; stage core/a.md "fine"; good_env
git -C "$CLONE" checkout -q -b feature
git -C "$CLONE" push -q -u origin feature   # an upstream, so the ff-only pull would succeed: only the branch check can refuse
lh=$(head_of "$CLONE"); rh=$(remote_head)
fh=$(git -C "$REMOTE" rev-parse refs/heads/feature)
run_promote "${GOODENV[@]}"; rc=$?
check_refused "clone on a branch other than main" 1 "$rc" "$lh" "$rh"
[ "$(git -C "$REMOTE" rev-parse refs/heads/feature)" = "$fh" ] && ok "refused run left origin/feature unchanged" || bad "origin/feature moved on a refused run"
if grep -qF 'the clone is on feature, not main; nothing committed' "$OUT"; then ok "branch refusal names the branch"; else bad "branch refusal message: $(cat "$OUT")"; fi
[ ! -s "$CLONE/.privacy-calls" ] && ok "branch refusal came before the privacy scan" || bad "privacy scan ran on a non-main clone"

# diverged: a local unpushed commit plus a moved remote -> the ff-only pull fails
setup; good_env
printf 'local\n' > "$CLONE/local.txt"; git -C "$CLONE" add local.txt; git -C "$CLONE" commit -q -m local
other_pushes
stage core/a.md "fine"
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}"; rc=$?
check_refused "diverged history (ff-only pull fails)" 1 "$rc" "$lh" "$rh"

# unstaged edit to a TRACKED file: the budget check and the tests would read content that is not committed
setup; good_env
printf 'tracked\n' > "$CLONE/a b.txt"; git -C "$CLONE" add "a b.txt"; git -C "$CLONE" commit -q -m "add a b"
stage core/a.md "fine"
printf 'edited\n' >> "$CLONE/a b.txt"
printf 'edited\n' >> "$CLONE/README.md"
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}"; rc=$?
check_refused "unstaged change to a tracked file" 1 "$rc" "$lh" "$rh"
if grep -q 'stage or stash' "$OUT"; then ok "unstaged refusal says stage or stash"; else bad "unstaged message: $(cat "$OUT")"; fi
if grep -qx '  README.md' "$OUT"; then ok "unstaged refusal lists the unstaged file, indented"; else bad "unstaged file not listed: $(cat "$OUT")"; fi
if grep -qx '  a b.txt' "$OUT"; then ok "unstaged refusal lists a name with a space intact on one line"; else bad "spaced name not listed intact: $(cat "$OUT")"; fi

# deletion-only staging counts as nothing staged
setup; good_env
git -C "$CLONE" rm -q README.md
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}"; rc=$?
check_refused "deletion-only staging" 1 "$rc" "$lh" "$rh"
if grep -q 'nothing is staged' "$OUT"; then ok "deletion-only reports nothing staged"; else bad "deletion-only message: $(cat "$OUT")"; fi

# a failing git diff must stop the run, not feed an empty export to the scan (git shim fails diff --cached)
setup; stage core/a.md "fine"; good_env
REALGIT="$(command -v git)"
mkdir -p "$T/gitshim$n"
cat > "$T/gitshim$n/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "--cached" ] && { echo "git shim: diff failed" >&2; exit 128; }; done
exec "$REALGIT" "\$@"
SHIM
chmod +x "$T/gitshim$n/git"
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}" PATH="$T/gitshim$n:$T/bin:$PATH"; rc=$?
check_refused "git diff fails" 1 "$rc" "$lh" "$rh"
if grep -q 'could not list the staged files' "$OUT"; then ok "git diff failure is named"; else bad "git diff failure message: $(cat "$OUT")"; fi
[ ! -s "$CLONE/.privacy-calls" ] && ok "privacy scan not reached after the git failure" || bad "privacy scan ran despite the git failure"

# an export that silently produces nothing must be refused, not scanned (git shim: checkout-index exits 0 doing nothing)
setup; stage core/a.md "fine"; good_env
REALGIT="$(command -v git)"
mkdir -p "$T/gitshim$n"
cat > "$T/gitshim$n/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "checkout-index" ] && { cat >/dev/null; exit 0; }; done
exec "$REALGIT" "\$@"
SHIM
chmod +x "$T/gitshim$n/git"
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}" PATH="$T/gitshim$n:$T/bin:$PATH"; rc=$?
check_refused "empty staged export" 1 "$rc" "$lh" "$rh"
if grep -q 'the staged export is empty' "$OUT"; then ok "empty export is named"; else bad "empty export message: $(cat "$OUT")"; fi
[ ! -s "$CLONE/.privacy-calls" ] && ok "privacy scan not reached after an empty export" || bad "privacy scan ran on an empty export"

# push rejected by the remote after a local commit
setup; stage core/a.md "fine"; good_env
printf '#!/bin/sh
echo "remote: rejected by pre-receive" >&2
exit 1
' > "$REMOTE/hooks/pre-receive"; chmod +x "$REMOTE/hooks/pre-receive"
lh=$(head_of "$CLONE"); rh=$(remote_head)
run_promote "${GOODENV[@]}"; rc=$?
[ "$rc" -eq 1 ] && ok "push rejected: exit 1" || bad "push rejected: exit $rc ($(tail -n 3 "$OUT" | tr '
' '|'))"
if grep -q '^PROMOTED ' "$OUT"; then bad "push rejected: printed PROMOTED"; else ok "push rejected: no PROMOTED line"; fi
[ "$(remote_head)" = "$rh" ] && ok "push rejected: remote HEAD unchanged" || bad "push rejected: remote HEAD moved"
newhead="$(head_of "$CLONE")"
[ "$newhead" != "$lh" ] && ok "push rejected: the commit exists locally" || bad "push rejected: no local commit"
if grep -qF "committed locally as $newhead" "$OUT"; then ok "message names the local commit sha"; else bad "message lacks the sha: $(cat "$OUT")"; fi
if grep -qF 'git push' "$OUT"; then ok "message gives the retry command"; else bad "message lacks git push"; fi
if grep -qF 'git reset --soft HEAD~1' "$OUT"; then ok "message gives the undo command"; else bad "message lacks the undo command"; fi

echo "== green =="
setup; stage core/a.md "a shared lesson"; good_env
msg_before=$(cat "$MSG")
run_promote "${GOODENV[@]}"; rc=$?
[ "$rc" -eq 0 ] && ok "green run exits 0" || bad "green run exit $rc: $(tail -n 4 "$OUT" | tr '\n' '|')"
last="$(tail -n 1 "$OUT")"
case "$last" in "PROMOTED "*) ok "PROMOTED is the last line" ;; *) bad "last line: $last" ;; esac
sha="${last#PROMOTED }"
[ "$sha" = "$(remote_head)" ] && ok "PROMOTED sha equals the remote HEAD" || bad "sha $sha vs remote $(remote_head)"
[ "$sha" = "$(head_of "$CLONE")" ] && ok "PROMOTED sha equals the clone HEAD" || bad "sha vs clone HEAD"
[ "$(git --git-dir="$REMOTE" log -1 --format=%B refs/heads/main)" = "$msg_before" ] && ok "commit message is the file verbatim" || bad "commit message differs"
[ "$(cat "$MSG")" = "$msg_before" ] && ok "message file untouched" || bad "message file edited"
[ "$(git --git-dir="$REMOTE" show refs/heads/main:core/a.md)" = "a shared lesson" ] && ok "remote has the staged file" || bad "remote lacks the file"
[ "$(cat "$CLONE/.tests-args")" = "--scope core" ] && ok "tests run with --scope core" || bad "tests args: $(cat "$CLONE/.tests-args")"
if grep -qF "|git --pre-commit --staged --config .gitleaks.toml --redact --no-banner" "$GL_LOG" && [ "$(cut -d'|' -f1 "$GL_LOG" | head -n 1)" = "$(cd "$CLONE" && pwd)" ]; then
  ok "gitleaks ran in the clone with the pinned args"; else bad "gitleaks call: $(cat "$GL_LOG")"; fi
[ -s "$CLONE/.privacy-calls" ] && ok "privacy scan ran" || bad "privacy scan never ran"

# untracked files do not block a promotion and are not committed
setup; stage core/a.md "fine"; good_env
printf 'scratch
' > "$CLONE/untracked-scratch.txt"
run_promote "${GOODENV[@]}"; rc=$?
[ "$rc" -eq 0 ] && ok "untracked file does not block" || bad "untracked blocked: exit $rc ($(tail -n 3 "$OUT" | tr '
' '|'))"
[ -z "$(git --git-dir="$REMOTE" ls-tree -r --name-only refs/heads/main | grep untracked-scratch)" ] && ok "untracked file was not committed" || bad "untracked file reached the remote"

# remote moved ahead (another clone pushed first): the ff pull brings it in, then the push lands on top
setup; good_env
other_pushes
other_sha=$(head_of "$T/other$n")
stage core/a.md "mine"
run_promote "${GOODENV[@]}"; rc=$?
[ "$rc" -eq 0 ] && ok "behind-remote run exits 0" || bad "behind-remote exit $rc: $(tail -n 4 "$OUT" | tr '\n' '|')"
[ "$(git --git-dir="$REMOTE" rev-parse refs/heads/main~1)" = "$other_sha" ] && ok "pushed commit sits on top of the other clone's commit" || bad "history: $(git --git-dir="$REMOTE" log --oneline refs/heads/main | tr '\n' '|')"
[ "$(tail -n 1 "$OUT")" = "PROMOTED $(remote_head)" ] && ok "behind-remote: PROMOTED sha equals remote HEAD" || bad "behind-remote last line: $(tail -n 1 "$OUT")"

# a message file named by a Windows drive path (C:/... or C:\...), as a Windows tool hands it over:
# Git Bash opens it, so it must not be taken as relative and prefixed with $PWD (2026-10-29)
if command -v cygpath >/dev/null 2>&1; then
  for form in -m -w; do
    setup; stage core/a.md "drive path $form"; good_env
    msg_before=$(cat "$MSG"); MSG="$(cygpath "$form" "$MSG")"
    run_promote "${GOODENV[@]}"; rc=$?
    [ "$rc" -eq 0 ] && ok "drive-path message file ($form) exits 0" || bad "drive-path message file ($form) exit $rc: $(tail -n 3 "$OUT" | tr '\n' '|')"
    [ "$(git --git-dir="$REMOTE" log -1 --format=%B refs/heads/main)" = "$msg_before" ] && ok "drive-path message file ($form) is committed verbatim" || bad "drive-path message ($form) differs"
  done
else
  echo "  SKIP: drive-path message file (no cygpath: not Windows)"
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
