#!/usr/bin/env bash
# Tests for earlier-cloud-work.sh.
#
# Run:  bash personal/hooks/test-earlier-cloud-work.sh
# Exits non-zero on any failure.

set -uo pipefail

# Each case supplies its own gate; the ambient environment must never supply it
# (this script is run inside cloud sessions, which export it).
unset CLAUDE_CLOUD_SESSION

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/earlier-cloud-work.sh"
REAL_GIT="$(command -v git)"
pass=0
fail=0

ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

has() { # has <desc> <output> <fixed string>   (VERBOSE=1 shows the hook output)
  [ -n "${VERBOSE:-}" ] && printf '%s\n' "$2" | sed 's/^/      > /'
  if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing '$3')"; echo "$2" | sed 's/^/      | /'; fi
}
lacks() { # lacks <desc> <output> <fixed string>
  if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1 (found '$3')"; echo "$2" | sed 's/^/      | /'; else ok "$1"; fi
}
empty() { # empty <desc> <output>
  if [ -z "$2" ]; then ok "$1"; else bad "$1 (got output)"; echo "$2" | sed 's/^/      | /'; fi
}
count() { # count <desc> <output> <fixed string> <n>
  local n
  n="$(printf '%s\n' "$2" | grep -cF -- "$3")"
  if [ "$n" = "$4" ]; then ok "$1"; else bad "$1 (wanted $4 lines with '$3', got $n)"; echo "$2" | sed 's/^/      | /'; fi
}

gitc() { git -c user.email=t@example.com -c user.name=Test "$@"; }

# mkproj <parent> <name>: origin at <parent>/.aux/<name>.git, a seed clone to
# add branches from, and NO working clone yet (call clone_proj after the
# branches exist). The .aux dir is a dotdir so the hook's child-repo glob
# never sees it.
mkproj() {
  local p="$1" n="$2"
  mkdir -p "$p/.aux"
  git init -q --bare -b main "$p/.aux/$n.git"
  git init -q -b main "$p/.aux/$n-seed"
  echo one > "$p/.aux/$n-seed/a.txt"
  git -C "$p/.aux/$n-seed" add -A
  gitc -C "$p/.aux/$n-seed" commit -qm init
  git -C "$p/.aux/$n-seed" remote add origin "$p/.aux/$n.git"
  git -C "$p/.aux/$n-seed" push -q origin main
}

# mkbranch <parent> <name> <branch> <ncommits> [merged] [epoch]
mkbranch() {
  local s="$1/.aux/$2-seed" b="$3" k="$4" merged="${5:-}" ts="${6:-1700000000}" i
  git -C "$s" checkout -q main
  git -C "$s" checkout -qb "$b"
  for i in $(seq 1 "$k"); do
    echo "$b $i" > "$s/f-$(echo "$b" | tr '/' '_').txt"
    git -C "$s" add -A
    GIT_COMMITTER_DATE="$ts +0000" GIT_AUTHOR_DATE="$ts +0000" \
      gitc -C "$s" commit -qm "work on $b ($i)"
  done
  git -C "$s" push -q origin "$b"
  git -C "$s" checkout -q main
  if [ "$merged" = merged ]; then
    git -C "$s" merge -q --ff-only "$b"
    git -C "$s" push -q origin main
  fi
}

# clone_proj <parent> <name> [own-branch]: the working clone the hook runs in
clone_proj() {
  git clone -q "$1/.aux/$2.git" "$1/$2" 2>/dev/null
  git -C "$1/$2" config user.email t@example.com
  git -C "$1/$2" config user.name Test
  if [ -n "${3:-}" ]; then git -C "$1/$2" checkout -q -b "$3" "origin/$3"; fi
}

run_hook() { # run_hook <cwd> [env assignments...]
  local cwd="$1"; shift
  # SWITCHBOARD_STATE_DIR defaults to a place with no state repo, never the real /home/user one.
  ( cd "$cwd" && env CLAUDE_CLOUD_SESSION=1 SWITCHBOARD_STATE_DIR="$cwd/.no-state-dir" "$@" bash "$HOOK" 2>&1 )
}

echo "== earlier-cloud-work.sh =="

# 1. Gate unset -> no output even with an unmerged branch
P="$(mktemp -d)"; mkproj "$P" proj; mkbranch "$P" proj ccr-x 2; clone_proj "$P" proj
out="$( cd "$P/proj" && bash "$HOOK" 2>&1 )"
empty "gate unset: no output" "$out"

# 2. A mix of branches
P="$(mktemp -d)"; mkproj "$P" proj
mkbranch "$P" proj ccr-x 2
mkbranch "$P" proj claude/y 1
mkbranch "$P" proj claude/z 1 merged
mkbranch "$P" proj dependabot/a 1
mkbranch "$P" proj claude/own 1
clone_proj "$P" proj claude/own
out="$(run_hook "$P/proj")"
has   "header names the repo and the default branch" "$out" "Earlier cloud work in proj that never landed on main; look at it before starting anything that might overlap:"
has   "unmerged ccr-x is listed with count and author" "$out" "- ccr-x (2 commits, Test, 2023-11-14): work on ccr-x (2)"
has   "unmerged claude/y is listed" "$out" "- claude/y (1 commits"
lacks "merged claude/z is absent" "$out" "claude/z"
lacks "dependabot/a is absent" "$out" "dependabot/a"
lacks "the session's own branch is absent" "$out" "claude/own"
lacks "no 'and N more' under the cap" "$out" "more"
rc=0; ( cd "$P/proj" && CLAUDE_CLOUD_SESSION=1 bash "$HOOK" >/dev/null 2>&1 ) || rc=$?
[ "$rc" -eq 0 ] && ok "exits 0" || bad "exits $rc"

# 3. Seven branches -> five lines, newest first, plus "and 2 more"
P="$(mktemp -d)"; mkproj "$P" proj
for i in 1 2 3 4 5 6 7; do mkbranch "$P" proj "claude/b$i" 1 "" "$((1700000000 + i * 86400))"; done
clone_proj "$P" proj
out="$(run_hook "$P/proj")"
count "seven branches: five listed" "$out" "- claude/b" 5
has   "seven branches: '...and 2 more'" "$out" "…and 2 more"
has   "newest branch is listed" "$out" "- claude/b7 ("
has   "fifth newest is listed" "$out" "- claude/b3 ("
lacks "the two oldest are cut" "$out" "- claude/b2 ("
first="$(printf '%s\n' "$out" | grep -F -- '- claude/b' | head -n 1)"
case "$first" in "- claude/b7 ("*) ok "newest first" ;; *) bad "newest first (first was: $first)" ;; esac

# 4. Nothing to report -> silence
P="$(mktemp -d)"; mkproj "$P" proj; mkbranch "$P" proj claude/done 1 merged; clone_proj "$P" proj
out="$(run_hook "$P/proj")"
lacks "nothing unmerged: no branch report" "$out" "Earlier cloud work"
lacks "nothing unmerged: no couldn't-check line" "$out" "couldn't check proj"

# 5. Unreachable origin -> a "couldn't check" line, exit 0
P="$(mktemp -d)"; mkproj "$P" proj; clone_proj "$P" proj
git -C "$P/proj" remote set-url origin "$P/nowhere.git"
out="$(run_hook "$P/proj")"
has "unreachable origin: couldn't check" "$out" "switchboard: couldn't check proj for earlier cloud branches ("

# 6. Resumed clone holding only main and its own branch -> still listed (ls-remote)
P="$(mktemp -d)"; mkproj "$P" proj
mkbranch "$P" proj claude/own 1
mkbranch "$P" proj claude/other 2
clone_proj "$P" proj claude/own
git -C "$P/proj" for-each-ref --format='%(refname)' refs/remotes/origin \
  | grep -v -e '/main$' -e '/HEAD$' -e '/claude/own$' \
  | while read -r r; do git -C "$P/proj" update-ref -d "$r"; done
left="$(git -C "$P/proj" for-each-ref --format='%(refname)' refs/remotes/origin | grep -c other || true)"
[ "$left" = 0 ] && ok "fixture: other remote-tracking refs are gone" || bad "fixture: other ref still present"
out="$(run_hook "$P/proj")"
has "resumed clone: unmerged branch still listed" "$out" "- claude/other (2 commits"

# 7. An origin that hangs -> exits in < 30 s with an out-of-time line. 30 s is the hook's own
# timeout, a requirement rather than a tuned bound; 13 s measured 2026-10-20 with all 22 suites in
# parallel, against the shim's 60 s.
P="$(mktemp -d)"; mkproj "$P" proj; mkbranch "$P" proj claude/y 1; clone_proj "$P" proj
shim="$(mktemp -d)"
cat > "$shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = ls-remote ] && exec sleep 60; done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$shim/git"
t0=$SECONDS
out="$( cd "$P/proj" && PATH="$shim:$PATH" CLAUDE_CLOUD_SESSION=1 bash "$HOOK" 2>&1 )"
dt=$((SECONDS - t0))
[ "$dt" -lt 30 ] && ok "hanging origin: exited in ${dt}s (< 30)" || bad "hanging origin: took ${dt}s"
has "hanging origin: out-of-time line" "$out" "(out of time)"

# 8. An exhausted budget -> every repo gets an out-of-time line, no silence
P="$(mktemp -d)"; mkproj "$P" proj; mkbranch "$P" proj claude/y 1; clone_proj "$P" proj
out="$(run_hook "$P/proj" EARLIER_CLOUD_WORK_BUDGET=1)"
has   "exhausted budget: out-of-time line" "$out" "couldn't check proj for earlier cloud branches (out of time)"
lacks "exhausted budget: nothing was listed" "$out" "claude/y"

# 9. Shallow clone -> listed after unshallowing, or the shallow line; never silence
P="$(mktemp -d)"; mkproj "$P" proj; mkbranch "$P" proj claude/y 1
git clone -q --depth 1 "file://$P/.aux/proj.git" "$P/proj" 2>/dev/null
out="$(run_hook "$P/proj")"
if printf '%s\n' "$out" | grep -qF -e "- claude/y (" -e "(shallow clone)"; then
  ok "shallow clone: listed or reported, not silent"
else
  bad "shallow clone: silent"; echo "$out" | sed 's/^/      | /'
fi

# 10. Multi-repo parent dir -> a header per repo with branches
P="$(mktemp -d)"
mkproj "$P" alpha; mkbranch "$P" alpha claude/a 1; clone_proj "$P" alpha
mkproj "$P" beta;  mkbranch "$P" beta claude/b 1;  clone_proj "$P" beta
mkproj "$P" gamma; clone_proj "$P" gamma
out="$(run_hook "$P")"
has   "multi-repo: header for alpha" "$out" "Earlier cloud work in alpha"
has   "multi-repo: header for beta" "$out" "Earlier cloud work in beta"
lacks "multi-repo: no header for a repo with nothing" "$out" "gamma"
out="$(run_hook "$P/alpha")"
has   "multi-repo: cwd inside alpha still reports sibling beta" "$out" "Earlier cloud work in beta"

# 11. switchboard-state verdicts: wait -> line; can_continue -> nothing
mkstate() { # mkstate <parent> <verdict>
  mkdir -p "$1/switchboard-state"
  git init -q -b main "$1/switchboard-state"
  printf '# slug\tid\tverdict\treasons\nother/thing\tx\tcan_continue\tfine\no/r\tabc\t%s\tPC has 3 unpushed commits\n' "$2" \
    > "$1/switchboard-state/verdicts.tsv"
  git -C "$1/switchboard-state" add -A
  GIT_COMMITTER_DATE="2026-10-16T12:00:00 +0000" gitc -C "$1/switchboard-state" commit -qm state
}
slugrepo() { # slugrepo <parent> <remote url>: a clean proj whose origin URL is <url>
  mkproj "$1" proj; clone_proj "$1" proj
  git -C "$1/proj" remote set-url origin "$2"
  git -C "$1/proj" config "url.$1/.aux/proj.git.insteadOf" "$2"
}
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" wait
out="$(run_hook "$P/proj")"
has "verdict wait (https .git url): switchboard line" "$out" "switchboard: o/r must wait for the PC (PC has 3 unpushed commits), as of 2026-10-16."
# Every origin URL shape must resolve to the slug o/r (I1: cloud origins may be a local proxy)
for url in "git@github.com:o/r.git" "https://github.com/o/r" "https://github.com/o/r/" \
           "http://local_proxy@127.0.0.1:43210/git/o/r" "http://local_proxy@127.0.0.1:43210/git/o/r.git/"; do
  P="$(mktemp -d)"; slugrepo "$P" "$url"; mkstate "$P" wait
  out="$(run_hook "$P/proj")"
  has "verdict wait finds o/r for origin $url" "$out" "switchboard: o/r must wait for the PC (PC has 3 unpushed commits)"
done
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r"; mkstate "$P" can_continue
out="$(run_hook "$P/proj")"
empty "verdict can_continue: nothing" "$out"
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/someone/else.git"; mkstate "$P" wait
out="$(run_hook "$P/proj")"
empty "verdict wait for ANOTHER slug: nothing" "$out"
# Slug case: GitHub owner/repo is case-insensitive, so the tsv slug and the origin may differ in case.
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/progdroid/myrepo.git"; mkstate "$P" wait
printf '# slug\tid\tverdict\treasons\nProgDroid/MyRepo\tabc\twait\tPC has 3 unpushed commits\n' > "$P/switchboard-state/verdicts.tsv"
out="$(run_hook "$P/proj")"
has "verdict wait: slug case differs (tsv ProgDroid/MyRepo, origin progdroid/myrepo)" "$out" "switchboard: ProgDroid/MyRepo must wait for the PC (PC has 3 unpushed commits)"
# Companions ride along in every session: named, short, no reason list.
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/ProgDroid/claude-setup.git"; mkstate "$P" wait
printf '# slug\tid\tverdict\treasons\nProgDroid/claude-setup\tclaude-setup\twait\tbranch feat/x: 51 commits not on GitHub\n' > "$P/switchboard-state/verdicts.tsv"
out="$(run_hook "$P/proj")"
has   "companion wait: short named line" "$out" "switchboard: ProgDroid/claude-setup (companion) is waiting for the PC; don't change it in this session (state as of"
lacks "companion wait: no reason list" "$out" "51 commits"
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"
out="$(run_hook "$P/proj")"
lacks "no switchboard-state sibling: no verdict line" "$out" "must wait for the PC"

# 12. M1: an unreachable origin must not suppress the local wait verdict
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" wait
git -C "$P/proj" config --unset-all "url.$P/.aux/proj.git.insteadOf"
git -C "$P/proj" config "url.$P/nowhere.git.insteadOf" "https://github.com/o/r.git"
out="$(run_hook "$P/proj")"
has "unreachable origin + wait: the couldn't-check line" "$out" "couldn't check proj for earlier cloud branches (origin unreachable)"
has "unreachable origin + wait: the switchboard line too" "$out" "switchboard: o/r must wait for the PC (PC has 3 unpushed commits)"

# 13. M5: the budget runs out at the FETCH step, after ls-remote succeeded.
# Budget 3 s; the shim makes ls-remote take 2 s, leaving < 2 s for the fetch.
P="$(mktemp -d)"; mkproj "$P" proj; mkbranch "$P" proj claude/y 1
git clone -q --single-branch --branch main "$P/.aux/proj.git" "$P/proj" 2>/dev/null
shim="$(mktemp -d)"
cat > "$shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = ls-remote ] && { sleep 2; break; }; done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$shim/git"
out="$( cd "$P/proj" && PATH="$shim:$PATH" EARLIER_CLOUD_WORK_BUDGET=3 CLAUDE_CLOUD_SESSION=1 bash "$HOOK" 2>&1 )"
has   "budget gone at the fetch step: out-of-time line" "$out" "couldn't check proj for earlier cloud branches (out of time)"
lacks "budget gone at the fetch step: nothing listed" "$out" "claude/y"

# 14. The state repo is not attached: the hook asks the model to attach it.
P="$(mktemp -d)"; mkproj "$P" alpha; clone_proj "$P" alpha; mkproj "$P" beta; clone_proj "$P" beta
# Invoke the hook by a RELATIVE path, so a `self="$0"` would not pass.
mkdir -p "$P/bin" && cp "$HOOK" "$P/bin/earlier-cloud-work.sh"   # a copy beside the repos, so a relative path to it exists
out="$( cd "$P" && env CLAUDE_CLOUD_SESSION=1 SWITCHBOARD_STATE_DIR="$P/.no-state-dir" bash ./bin/earlier-cloud-work.sh 2>&1 )"
count "no state repo: instruction once" "$out" "isn't attached to this session" 1
has   "instruction names add_repo" "$out" "Call add_repo for ProgDroid/switchboard-state"
has   "instruction forbids register_repo_root" "$out" "Do NOT call register_repo_root"
has   "instruction gives the re-run command: cd to the start dir, absolute script path" "$out" "cd \"$P\" && CLAUDE_CLOUD_SESSION=1 bash \"$P/bin/earlier-cloud-work.sh\" --switchboard-only"
has   "instruction skips the clone over a checkout add_repo left" "$out" "If /home/user/switchboard-state already exists and git -C /home/user/switchboard-state rev-parse HEAD succeeds, skip the clone (step 2 still applies)."

P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" can_continue
out="$(run_hook "$P/proj")"
lacks "state repo present (sibling): no instruction" "$out" "isn't attached"
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" can_continue
mv "$P/switchboard-state" "$P/elsewhere"
out="$(run_hook "$P/proj" SWITCHBOARD_STATE_DIR="$P/elsewhere")"
lacks "state repo present (SWITCHBOARD_STATE_DIR): no instruction" "$out" "isn't attached"

P="$(mktemp -d)"; mkproj "$P" claude-setup; clone_proj "$P" claude-setup
out="$(run_hook "$P")"
lacks "companions only: no instruction" "$out" "isn't attached"

# 15. --switchboard-only
sbo() { # sbo <cwd> [env assignments...]: the flag run, gate variable set
  local cwd="$1"; shift
  ( cd "$cwd" && env CLAUDE_CLOUD_SESSION=1 "$@" bash "$HOOK" --switchboard-only 2>&1 )
}
shim="$(mktemp -d)"
cat > "$shim/git" <<SHIM
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = ls-remote ] && { echo "ls-remote was run" >&2; exit 1; }; done
exec "$REAL_GIT" "\$@"
SHIM
chmod +x "$shim/git"
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" wait; mkbranch "$P" proj claude/y 1
out="$(sbo "$P/proj" PATH="$shim:$PATH")"
has   "switchboard-only, waiting: the wait line" "$out" "switchboard: o/r must wait for the PC (PC has 3 unpushed commits), as of 2026-10-16."
has   "switchboard-only, waiting: the checked-against line" "$out" "switchboard: checked against the PC's state of 2026-10-16."
lacks "switchboard-only, waiting: no ls-remote, no branch report" "$out" "ls-remote"
lacks "switchboard-only: no branch report" "$out" "Earlier cloud work"
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" can_continue
out="$(sbo "$P/proj")"
[ "$out" = "switchboard: checked against the PC's state of 2026-10-16." ] && ok "switchboard-only, can continue: exactly the checked-against line" || { bad "switchboard-only, can continue: wrong output"; echo "$out" | sed 's/^/      | /'; }
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"
out="$(sbo "$P/proj" SWITCHBOARD_STATE_DIR="$P/.no-state-dir")"
[ "$out" = "switchboard: couldn't check the PC's state (the state repo isn't attached)." ] && ok "switchboard-only, still absent: the couldn't-check line" || { bad "switchboard-only, still absent: wrong output"; echo "$out" | sed 's/^/      | /'; }
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" wait
out="$( cd "$P/proj" && env -u CLAUDE_CLOUD_SESSION SWITCHBOARD_STATE_DIR="$P/.no-state-dir" bash "$HOOK" --switchboard-only 2>&1 )"
has "switchboard-only without the gate variable: still prints the wait line" "$out" "switchboard: o/r must wait for the PC"
# The state repo is at SWITCHBOARD_STATE_DIR rather than beside the project.
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" wait; mv "$P/switchboard-state" "$P/elsewhere"
out="$(sbo "$P/proj" SWITCHBOARD_STATE_DIR="$P/elsewhere")"
has "switchboard-only, state at SWITCHBOARD_STATE_DIR: the wait line" "$out" "switchboard: o/r must wait for the PC"
# No project repo in sight (a shell outside any project): never an all-clear.
P="$(mktemp -d)"; slugrepo "$P" "https://github.com/o/r.git"; mkstate "$P" wait; mv "$P/switchboard-state" "$P/elsewhere"
E="$(mktemp -d)"
out="$(sbo "$E" SWITCHBOARD_STATE_DIR="$P/elsewhere")"
[ "$out" = "switchboard: couldn't check the PC's state (no project repo found from $E)." ] && ok "switchboard-only, no project repo: couldn't-check" || { bad "switchboard-only, no project repo: wrong output"; echo "$out" | sed 's/^/      | /'; }

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
