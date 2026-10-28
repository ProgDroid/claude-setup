#!/usr/bin/env bash
# Tests for windows-guard.sh, rule 1 (python/node under the Bash tool).
#
# Run:  bash personal/hooks/test-windows-guard.sh
#
# ---------------------------------------------------------------------------
# ✅ BUG #1 (found 2026-08-31) is FIXED as of 2026-09-01, by suggested fix 1
#    below: rule 1 now skips when powershell.exe/pwsh is the LEADING command.
#    Its test is a real assertion now, with a companion asserting that
#    `python x.py && powershell.exe ...` is STILL denied.
#
# ✅ BUG #2 (found live 2026-09-01) is FIXED as of 2026-09-01. The hook now builds
#    a heredoc-stripped copy of the command ($scan) and every rule matches THAT,
#    while rule c -- which is about heredocs -- keeps reading the raw $cmd.
#
#    The note below warned that the obvious fix was unsafe, and it was right: a
#    body fed to a SHELL (`bash <<EOF ... EOF`) really is executed, so stripping
#    unconditionally would have allowed a genuine winpty case. Note also that
#    quoting is NOT the discriminator -- <<'EOF' suppresses expansion, not
#    execution, so `bash <<'EOF'` still runs its body. The hook therefore keys on
#    the OPENING LINE's command: a shell (bash/sh/zsh/dash/ksh) or wsl keeps the
#    body in scope; anything else (cat, tee, py, docker) has its body stripped.
#    Positive controls for both directions are asserted below.
#
# THE ORIGINAL BUG (#1, kept for the record): rule 1 was QUOTE-BLIND. It scans
# the raw Bash command string for separators with
#
#     (^|[;&|]|&&|\|\||[[:space:]]\$\()[[:space:]]*(python3?|node)[[:space:]]
#
# and has no notion of quoting, so a ';' INSIDE a quoted argument to
# `powershell.exe -Command "..."` is misread as a Bash command separator.
#
# Consequence: the single-command form the deny message itself prescribes is
# correctly ALLOWED, but chaining two calls inside the same PowerShell string
# is DENIED, even though nothing runs under winpty in either case. The rule's
# whole rationale ("python under the Bash tool hits winpty and prints nothing")
# does not apply once the command dispatches to powershell.exe.
#
# Hit live on 2026-08-31 in a LaTeX repo while pulling two compiled PDFs:
#   powershell.exe -NoProfile -Command "python tools/pull_pdf.py A B; python tools/pull_pdf.py C D"
# The workaround was to move the whole invocation into a .ps1 and call it with
# -File, so the word never appears in the Bash string at all.
#
# SUGGESTED FIX (pick one, in preference order):
#   1. Skip rule 1 entirely when powershell.exe/pwsh is the LEADING command.
#      The winpty rationale cannot apply, and it keeps a genuine
#      `python x.py && powershell.exe ...` still denied because python leads.
#   2. Strip `-Command "..."` / `-c "..."` payloads from $cmd before matching.
#   3. Make the matcher quote-aware. Most correct, most work, easiest to get
#      subtly wrong in bash.
#
# Whichever is chosen, keep the positive controls below passing: a genuine bare
# `python x.py`, and a genuine `echo hi; python x.py`, MUST still be denied.
# A fix that silences the false positive by weakening those is worse than the bug.
#
# NOTE: the same quote-blind separator alternation is reused by other rules in
# this hook. Check whether they need the same treatment while you are in here.
# ---------------------------------------------------------------------------

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/windows-guard.sh"
pass=0; fail=0; known=0
ok()    { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()   { echo "  FAIL: $1"; fail=$((fail + 1)); }
xfail() { echo "  KNOWN-FAIL (quote-blind bug): $1"; known=$((known + 1)); }

case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) echo "windows-guard exits silently off Windows; nothing to test here."; exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }

# Assembled at runtime so this file's own test strings do not trip the guard
# when an agent greps or composes commands around it.
PY=$(printf 'p\x79thon')
# A literal backslash, assembled the same way: writing it inline meant the
# assertion below tested a string with no backslash in it and 'failed' against
# a hook that was working correctly.
BS=$(printf '\134')

# verdict_any <command> -> DENY if ANY rule denied (rule 1 has its own matcher below)
#
# Parsed with jq, NOT grepped for a literal '"permissionDecision":"deny"': the hook
# emits jq's PRETTY-printed JSON, which puts a space after the colon, so the compact
# spelling never matches and every command comes back ALLOW. That made the negative
# assertions here pass vacuously -- a probe that cannot return DENY proves nothing.
verdict_any() {
  local out
  out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>&1)
  case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)" in
    deny) echo DENY ;;
    *)    echo ALLOW ;;
  esac
}

# verdict <command> -> prints DENY or ALLOW
verdict() {
  local out
  out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>&1)
  if echo "$out" | grep -q 'cannot run'; then echo DENY; else echo ALLOW; fi
}

echo "== rule 1: genuine bash invocations MUST be denied (positive controls) =="

[ "$(verdict "$PY x.py")" = DENY ] \
  && ok "bare '$PY x.py' denied" \
  || bad "bare '$PY x.py' was ALLOWED - rule 1 is not firing at all"

[ "$(verdict "echo hi; $PY x.py")" = DENY ] \
  && ok "'echo hi; $PY x.py' denied" \
  || bad "semicolon-chained bash call was ALLOWED"

[ "$(verdict "node x.js")" = DENY ] \
  && ok "'node x.js' denied" \
  || bad "'node x.js' was ALLOWED"

echo "== rule 1: unrelated commands MUST be allowed (negative controls) =="

[ "$(verdict "git status --short")" = ALLOW ] \
  && ok "'git status --short' allowed" \
  || bad "'git status --short' was DENIED - rule 1 is over-matching badly"

[ "$(verdict "powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"run.ps1\" -Arg 'x'")" = ALLOW ] \
  && ok "powershell -File wrapper allowed (the current workaround)" \
  || bad "the -File workaround is now DENIED - nothing is left that works"

echo "== rule 1: dispatching to PowerShell =="

[ "$(verdict "powershell.exe -NoProfile -Command \"$PY tools/x.py\"")" = ALLOW ] \
  && ok "single -Command form allowed (this is what the deny message prescribes)" \
  || bad "the prescribed single -Command form is DENIED - the message is unreachable"

[ "$(verdict "powershell.exe -NoProfile -Command \"$PY a.py; $PY b.py\"")" = ALLOW ] \
  && ok "two -Command calls separated by ';' allowed (the 2026-08-31 quote-blind bug, fixed 2026-09-01)" \
  || bad "the quote-blind bug is BACK - a ';' inside the quoted PowerShell argument is being read as a Bash separator"

[ "$(verdict "$PY x.py && powershell.exe -NoProfile -File run.ps1")" = DENY ] \
  && ok "'$PY x.py && powershell.exe ...' still denied ($PY leads, so winpty still applies)" \
  || bad "the leading-command check is too broad - a genuine bash $PY call followed by powershell was ALLOWED"

echo "== rule 1: heredoc bodies (bug #2, fixed 2026-09-01) =="

# An INERT body: cat writes a file, so the body is data, not commands.
HEREDOC=$(printf 'cat > run.ps1 <<%sEOF%s\n%s -m pytest tests/\nEOF' "'" "'" "$PY")
[ "$(verdict "$HEREDOC")" = ALLOW ] \
  && ok "$PY inside a 'cat > file' heredoc body allowed (body is data)" \
  || bad "bug #2 is BACK - heredoc body text is being matched as a command"

# The real 2026-09-01 case: a Dockerfile RUN line written through a heredoc.
DOCKERDOC=$(printf 'cat > x.Dockerfile <<%sEOF%s\nRUN apt-get update \\\n    && %s -c "import x" \\\n    && rm -rf /var/lib/apt/lists/*\nEOF' "'" "'" "$PY")
[ "$(verdict "$DOCKERDOC")" = ALLOW ] \
  && ok "Dockerfile RUN line calling $PY, written via heredoc, allowed" \
  || bad "writing a Dockerfile that mentions $PY is DENIED - the live false positive is back"

# A NON-inert body: bash EXECUTES it, so winpty genuinely applies and it must stay denied.
# This is the case the old note correctly warned the naive fix would break.
SHELLDOC=$(printf 'bash <<%sEOF%s\n%s x.py\nEOF' "'" "'" "$PY")
[ "$(verdict "$SHELLDOC")" = DENY ] \
  && ok "'bash <<EOF ... $PY x.py ... EOF' still denied (body IS shell source)" \
  || bad "heredoc stripping is too broad - a body fed to bash was ALLOWED, and that really does hit winpty"

SHDOC=$(printf 'sh -s <<%sEOF%s\n%s x.py\nEOF' "'" "'" "$PY")
[ "$(verdict "$SHDOC")" = DENY ] \
  && ok "'sh -s <<EOF ... $PY x.py ... EOF' still denied" \
  || bad "'sh -s' heredoc body was stripped - that body is executed"

# Quoting is not the discriminator: an UNQUOTED delimiter fed to cat is still data.
UNQUOTED=$(printf 'cat > notes.txt <<EOF\n%s -m pytest\nEOF' "$PY")
[ "$(verdict "$UNQUOTED")" = ALLOW ] \
  && ok "unquoted heredoc delimiter fed to cat allowed (still data)" \
  || bad "unquoted-delimiter heredoc fed to cat was DENIED"

# A herestring must not be mistaken for a heredoc opener.
[ "$(verdict "grep -q x <<<\"$PY x.py\"")" = ALLOW ] \
  && ok "herestring body not treated as a command" \
  || bad "herestring '<<<' was parsed as a heredoc opener"

echo "== other rules also read the stripped copy =="

SEDDOC=$(printf 'cat > notes.md <<%sEOF%s\nExample: sed -i s/a/b/ C:%stmp%sx.txt\nEOF' "'" "'" "$BS" "$BS")
[ "$(verdict_any "$SEDDOC")" = ALLOW ] \
  && ok "a sed-on-Windows-path EXAMPLE inside a heredoc body is allowed" \
  || bad "rule 2 fired on heredoc body text"

[ "$(verdict_any "sed -i s/a/b/ C:${BS}tmp${BS}x.txt")" = DENY ] \
  && ok "a real sed on a Windows path is still denied" \
  || bad "rule 2 no longer fires on a genuine command"

# 2026-10-28 (cli-timer): rule 2 denied a read-only sed because a grep alternation in the
# same command, 'runs-on\|os:\|ubuntu', contains s:\ -- a letter, a colon and a backslash.
# A drive letter starts a word; the s of os does not.
[ "$(verdict_any "cat f.yml | sed -n '40,200p'; grep -n 'runs-on${BS}|os:${BS}|ubuntu' check.yml")" = ALLOW ] \
  && ok "a grep alternation like os:\\| is not a drive path" \
  || bad "rule 2 read os:\\| inside a grep pattern as a drive path"
for c in "sed -i s/a/b/ \"C:${BS}tmp${BS}x.txt\"" "sed -i s/a/b/ 'D:${BS}x.txt'" \
         "sed -i s/a/b/ --in=C:${BS}x.txt" "sed -n 1p <G:${BS}x.txt"; do
  [ "$(verdict_any "$c")" = DENY ] \
    && ok "rule 2 still denies: $c" || bad "rule 2 missed a quoted or prefixed drive path: $c"
done

# ---------------------------------------------------------------------------
# WARN rules.
#
# Added 2026-09-06 after MEASURING them. Across one long session rule b fired 7
# times and was right ONCE (14% precision). Rule a fired twice, wrong both times.
# A warning that is usually wrong trains the reader to skim it, which costs you
# the one time it is right -- and in that session the true positive was in fact
# skimmed past.
#
# Both narrowings are pinned here in BOTH directions: the genuine incident each
# rule exists for must still warn, and each measured false positive must not.
# ---------------------------------------------------------------------------

# warn_kind <command> -> NONE | GREP_IDIOM | EXIT_CODE | HEREDOC | ENCODING
warn_kind() {
  local out ctx
  out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>&1)
  ctx=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)
  case "$ctx" in
    *"grep-only idiom"*)               echo GREP_IDIOM ;;
    *"belongs to tail/head"*)          echo EXIT_CODE ;;
    *"Large heredocs"*)                echo HEREDOC ;;
    *"system ANSI codepage"*)          echo ENCODING ;;
    *"xargs splits on whitespace"*)    echo XARGS ;;
    *)                                 echo NONE ;;
  esac
}

echo "== rule a: the grep-only idiom (positive controls first) =="

[ "$(warn_kind 'git ls-files x && echo FOUND || echo MISSING')" = GREP_IDIOM ] \
  && ok "git ls-files with the grep idiom warns" \
  || bad "rule a no longer fires on the case it exists for"

[ "$(warn_kind 'find . -name x && echo FOUND || echo MISSING')" = GREP_IDIOM ] \
  && ok "find with the grep idiom warns" \
  || bad "rule a did not fire on find"

echo "== rule a: exit-code-bearing tests MUST NOT warn =="

# Measured false positives, twice in one session. A test builtin's exit code is
# exactly what the idiom wants; the rule's own rationale (query tools that exit 0
# on no result) does not describe it at all.
[ "$(warn_kind '[ -d "$x" ] && echo YES || echo NO')" = NONE ] \
  && ok "[ -d ] test builtin does not warn" \
  || bad "rule a still fires on a test builtin"

[ "$(warn_kind 'test -f "$x" && echo YES || echo NO')" = NONE ] \
  && ok "test -f does not warn" \
  || bad "rule a still fires on test -f"

[ "$(warn_kind 'command -v jq && echo FOUND || echo MISSING')" = NONE ] \
  && ok "command -v does not warn" \
  || bad "rule a still fires on command -v"

[ "$(warn_kind 'diff a b && echo SAME || echo DIFFERENT')" = NONE ] \
  && ok "diff does not warn" \
  || bad "rule a still fires on diff"

[ "$(warn_kind 'grep -q x f && echo FOUND || echo MISSING')" = NONE ] \
  && ok "grep itself still does not warn" \
  || bad "rule a regressed on its original exclusion"

echo "== rule b: the real incidents MUST still warn =="

# flutter test ... | tail -150 (2026-05-09) and the Gradle chain (2026-08-18).
[ "$(warn_kind 'pytest -q | tail -20')" = EXIT_CODE ] \
  && ok "a build verb piped to tail still warns" \
  || bad "rule b no longer catches a build piped to tail"

[ "$(warn_kind 'flutter test --coverage | tail -150')" = EXIT_CODE ] \
  && ok "flutter test piped to tail still warns" \
  || bad "rule b lost the 2026-05-09 incident"

# The one TRUE positive of the seven. Status is read AFTER the pipe, so the $?
# really does belong to head. This must survive the narrowing.
[ "$(warn_kind 'serena-hooks activate | head -20; echo "rc=$?"')" = EXIT_CODE ] \
  && ok "a status read AFTER the pipe still warns" \
  || bad "rule b lost its one true positive - the narrowing went too far"

echo "== rule b: the measured false positives MUST NOT warn =="

# Firing 4: the remedy the message itself prescribes. REAL_EXIT was in the
# trigger list, so applying the fix produced the warning telling you to apply it.
[ "$(warn_kind 'cmd > log 2>&1; echo "REAL_EXIT=$?"; tail -12 log')" = NONE ] \
  && ok "the prescribed remedy does not trigger its own warning" \
  || bad "rule b still fires on REAL_EXIT, its own fix"

# Firing 1: $? belongs to find; the pipe to head is a different command entirely.
[ "$(warn_kind 'find . -name x; echo "exit:$?"; grep -rl y . | head -20')" = NONE ] \
  && ok "a status captured before an unrelated pipe does not warn" \
  || bad "rule b still fires when \$? precedes the pipe"

# Firing 6: rc captured per iteration, tail only formats a log grep afterwards.
[ "$(warn_kind 'bash t.sh > log 2>&1; rc=$?; grep -E passed log | tail -1')" = NONE ] \
  && ok "a pre-pipe status with a later formatting tail does not warn" \
  || bad "rule b still fires on a pre-pipe status capture"

# Firing 7: same shape, with a build verb absent and od as the tail target.
[ "$(warn_kind 'git commit -F -; echo "COMMIT_EXIT=$?"; git log -1 | head -2')" = NONE ] \
  && ok "a commit status read before a display pipe does not warn" \
  || bad "rule b still fires on a display pipe after a status capture"

# Unchanged behaviour: plain read-only inspection was already quiet.
[ "$(warn_kind 'ls -la | head -40')" = NONE ] \
  && ok "plain read-only inspection stays quiet" \
  || bad "rule b fires on a bare ls"

# --- measured 2026-09-06, AFTER the first narrowing ------------------------------
# The positional check asked whether a `$?` appears ANYWHERE after the last
# tail/head. It cannot see intervening commands that reset the status, so this
# fired on a status belonging to `diff`, two commands downstream. The narrowing
# reduced the false-positive class; it did not eliminate it.
#
# Only the segment IMMEDIATELY following the tail/head command can be reading its
# status. Anything later is reading something else.
MULTI=$(printf 'bash s.sh; echo "SYNC_EXIT=$?"; git status --short | head\necho "x"; diff -rq a b; echo "DIFF_EXIT=$?"')
[ "$(warn_kind "$MULTI")" = NONE ] \
  && ok "a status two commands past the pipe does not warn" \
  || bad "rule b still fires on a status that belongs to a later command"

[ "$(warn_kind 'grep -rn x . | head -5; echo done; echo "rc=$?"')" = NONE ] \
  && ok "a status one command past the pipe does not warn" \
  || bad "rule b fires on a status separated from the pipe"

# The status here belongs to grep, not head.
[ "$(warn_kind 'cat f | head -5 | grep x; echo "rc=$?"')" = NONE ] \
  && ok "a status belonging to a later stage of the pipeline does not warn" \
  || bad "rule b claims a downstream stage's status"

# Presence sibling: the immediate case must still fire, or the three checks above
# would pass simply because rule b stopped working.
[ "$(warn_kind 'cmd --all | head; echo "rc=$?"')" = EXIT_CODE ] \
  && ok "a status read IMMEDIATELY after the pipe still warns" \
  || bad "rule b lost the immediate-status case - the narrowing went too far"

# A NEWLINE is a command separator too. Flattening it to a space made this read as
# `head echo "rc=$?"` -- the status absorbed into head's own arguments, leaving the
# next-command slot empty and the guard silent. Found by a mutation that failed zero
# tests, which is what said the newline handling was untested.
NEWLINE_STATUS=$(printf 'cmd --all | head\necho "rc=$?"')
[ "$(warn_kind "$NEWLINE_STATUS")" = EXIT_CODE ] \
  && ok "a status read on the NEXT LINE still warns" \
  || bad "a newline before the status read was absorbed as head's arguments"

# The case that distinguishes the remedy check from the positional check. Both
# suppress a bare pre-pipe `$?`, so without a BUILD VERB present the two are
# indistinguishable and disabling either one fails nothing. Here _build_verb is 1,
# so only the REAL_EXIT suppression can keep this quiet -- and this is also the
# most realistic command the rule will ever see, since it is the remedy applied
# to exactly the kind of build the rule exists to protect.
[ "$(warn_kind 'pytest -q > log 2>&1; echo "REAL_EXIT=$?"; tail -20 log')" = NONE ] \
  && ok "a build with the remedy applied does not warn" \
  || bad "rule b fires on a build that already writes REAL_EXIT"

echo "== rule e: a file list into plain xargs (added 2026-10-05) =="

for c in 'find . -name "*.md" | xargs grep -l needle' 'git ls-files | xargs wc -l' \
         'grep -rl needle . | xargs wc -c' 'find . -name "*.py" | xargs grep -i todo'; do
  [ "$(warn_kind "$c")" = XARGS ] && ok "rule e warns: $c" || bad "rule e missed: $c"
done
# The last one above is the discriminating case: the -i belongs to grep, not xargs.

for c in 'find . -print0 | xargs -0 wc -l' "git ls-files | xargs -d '\\n' wc -l" \
         'ls *.md | xargs -I{} cp {} out/' 'echo a b c | xargs -n1 echo'; do
  [ "$(warn_kind "$c")" = NONE ] && ok "rule e silent: $c" || bad "rule e false positive: $c"
done

# ---------------------------------------------------------------------------
# Added 2026-10-18, BEFORE the builtin rewrite that removed ~50 process spawns per
# run. Rules 3-6, c and d, the tool gate, and the output format had no test at
# all, so a rewrite could have broken any of them and failed nothing. Each block
# was run against the grep/sed implementation first, to pin what it actually did.
# ---------------------------------------------------------------------------

# verdict_tool <tool> <command> -> DENY | ALLOW | SILENT (no output at all)
verdict_tool() {
  local out
  out=$(jq -n --arg t "$1" --arg c "$2" '{tool_name:$t,tool_input:{command:$c}}' | bash "$HOOK" 2>&1)
  [ -z "$out" ] && { echo SILENT; return; }
  case "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)" in
    deny) echo DENY ;;
    *)    echo ALLOW ;;
  esac
}

echo "== rule 3: git commit -m with command substitution =="

[ "$(verdict_any 'git commit -m "fix $(date)"')" = DENY ] \
  && ok "git commit -m with \$( denied" \
  || bad "rule 3 missed \$( in a commit message"

[ "$(verdict_any 'git commit -m "use `make`"')" = DENY ] \
  && ok "git commit -m with a backtick denied" \
  || bad "rule 3 missed a backtick in a commit message"

[ "$(verdict_any 'git commit -m "plain message"')" = ALLOW ] \
  && ok "a plain git commit -m allowed" \
  || bad "rule 3 fires on a plain commit message"

# The remedy the message prescribes: the backtick lives in a heredoc body fed to git,
# which is data, so it is stripped before rule 3 looks.
COMMITDOC=$(printf 'git commit -F - <<%sEOF%s\nuse `make` here\nEOF' "'" "'")
[ "$(verdict_any "$COMMITDOC")" = ALLOW ] \
  && ok "git commit -F - with a backtick in the heredoc body allowed (the remedy)" \
  || bad "rule 3 denies its own remedy"

# -m is a FLAG, not a substring. Measured 2026-10-21 (swarm-music): a `git commit -F "$M"`
# whose message file was handoff-msg.txt, in a command that also ran $(git diff ...), was
# denied: "-msg" contained "-m". The three DENY cases pin what the fix must still catch.
FILEMSG='M=/tmp/handoff-msg.txt; [ -z "$(git diff --cached --name-only)" ] && git commit -q -F "$M" -- NEXT.md'
[ "$(verdict_any "$FILEMSG")" = ALLOW ] \
  && ok "git commit -F with '-m' inside a filename allowed" \
  || bad "rule 3 read '-m' inside a filename as the -m flag"
[ "$(verdict_any 'git commit -qm "fix $(date)"')" = DENY ] \
  && ok "bundled -qm with \$( denied" \
  || bad "rule 3 missed a bundled -qm"
[ "$(verdict_any 'git commit -am "fix $(date)"')" = DENY ] \
  && ok "bundled -am with \$( denied" \
  || bad "rule 3 missed a bundled -am"
[ "$(verdict_any 'git commit --message="fix $(date)"')" = DENY ] \
  && ok "--message= with \$( denied" \
  || bad "rule 3 missed --message="

# grep is per LINE: 'git' and 'commit' on different lines never matched together.
# Pinned because a whole-string regex would read the newline as [[:space:]].
SPLITGIT=$(printf 'git\ncommit -m "$(x)"')
[ "$(verdict_any "$SPLITGIT")" = ALLOW ] \
  && ok "git and commit on separate lines do not match (per-line semantics)" \
  || bad "a rule matched across a line break - per-line semantics lost"

echo "== rule 4: Get-Content -replace | Set-Content =="

[ "$(verdict_any '(Get-Content f -Raw) -replace "a","b" | Set-Content f')" = DENY ] \
  && ok "Get-Content -replace | Set-Content denied" \
  || bad "rule 4 missed the bulk-edit pipeline"

[ "$(verdict_any 'Get-Content f -Raw')" = ALLOW ] \
  && ok "a bare Get-Content allowed" \
  || bad "rule 4 fires on a bare Get-Content"

echo "== rule 5: WSL argument-form scripts =="

[ "$(verdict_any "wsl.exe -d nixos -- sh -lc 'ls /etc'")" = DENY ] \
  && ok "wsl sh -lc denied" \
  || bad "rule 5 missed sh -lc through wsl"

WSLDOC=$(printf 'wsl.exe -d nixos -- sh -s <<%sEOF%s\nls /etc\nEOF' "'" "'")
[ "$(verdict_any "$WSLDOC")" = ALLOW ] \
  && ok "wsl sh -s on stdin allowed (the remedy)" \
  || bad "rule 5 denies its own remedy"

echo "== rule 6: claude mcp add, and the tool gate =="

[ "$(verdict_tool Bash 'claude mcp add foo -- npx -y foo')" = DENY ] \
  && ok "claude mcp add denied under Bash" \
  || bad "rule 6 missed claude mcp add"

[ "$(verdict_tool PowerShell 'claude mcp add foo -- npx -y foo')" = SILENT ] \
  && ok "claude mcp add allowed under PowerShell" \
  || bad "rule 6 fires under PowerShell, the tool it tells you to use"

[ "$(verdict_tool PowerShell "$PY x.py")" = SILENT ] \
  && ok "rule 1 does not fire under the PowerShell tool" \
  || bad "rule 1 fires under PowerShell"

[ "$(verdict_tool PowerShell 'sed -i s/a/b/ C:\x.txt')" = DENY ] \
  && ok "tool-agnostic rules still fire under PowerShell" \
  || bad "rule 2 stopped firing under PowerShell"

[ "$(verdict_tool Read 'sed -i s/a/b/ C:\x.txt')" = SILENT ] \
  && ok "a non-shell tool is ignored entirely" \
  || bad "the hook acts on a tool that is neither Bash nor PowerShell"

[ "$(verdict_tool Bash '')" = SILENT ] \
  && ok "an empty command is ignored" \
  || bad "an empty command produced output"

echo "== rule c: oversized heredoc (boundary at 60 lines) =="

# opener + N body lines + terminator = N+2 lines; the rule fires above 60.
big_heredoc() { { printf 'cat > f.txt <<%sEOF%s\n' "'" "'"; for _ in $(seq "$1"); do echo body; done; printf 'EOF'; } ; }
[ "$(warn_kind "$(big_heredoc 59)")" = HEREDOC ] \
  && ok "a 61-line heredoc warns" \
  || bad "rule c missed a 61-line heredoc"

[ "$(warn_kind "$(big_heredoc 58)")" = NONE ] \
  && ok "a 60-line heredoc does not warn (boundary)" \
  || bad "rule c fires at exactly 60 lines"

echo "== rule d: Set-Content without -Encoding =="

[ "$(warn_kind 'Set-Content out.txt $x')" = ENCODING ] \
  && ok "Set-Content without -Encoding warns" \
  || bad "rule d missed Set-Content"

[ "$(warn_kind 'Add-Content out.txt $x')" = ENCODING ] \
  && ok "Add-Content without -Encoding warns" \
  || bad "rule d missed Add-Content"

[ "$(warn_kind 'Set-Content out.txt $x -Encoding utf8')" = NONE ] \
  && ok "Set-Content with -Encoding is quiet" \
  || bad "rule d fires when -Encoding is already passed"

# ---------------------------------------------------------------------------
# Rules 7 and 8, added 2026-10-20 from the escalation queue: two trap classes that
# recurred three times each with only prose behind them. Every DENY case below was
# measured to fail on this machine (grep 3.0 exit 134; git "ambiguous argument"), and
# every ALLOW case was measured to work, so neither list is a guess.
# ---------------------------------------------------------------------------

# deny_rule <command> -> GREP_IF | REV_PATH | OTHER | ALLOW  (which rule denied it)
# jq gets the command with MSYS_NO_PATHCONV=1: it is a native exe, so a command starting with
# / would otherwise be rewritten to C:/Program Files/Git/... before the hook ever saw it.
deny_rule() {
  local out reason
  out=$(MSYS_NO_PATHCONV=1 jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>&1)
  [ "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null)" = deny ] \
    || { echo ALLOW; return; }
  reason=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
  case "$reason" in
    *"grep aborts on -i"*)      echo GREP_IF ;;
    *"MSYS rewrites"*)          echo REV_PATH ;;
    *)                          echo OTHER ;;
  esac
}

expect_rule() {  # expect_rule <want> <command> <label>
  local got
  got=$(deny_rule "$2")
  [ "$got" = "$1" ] && ok "$3" || bad "$3 (want $1, got $got)"
}

echo "== rule 7: grep with -i and -F aborts (every spelling measured at exit 134) =="

expect_rule GREP_IF 'grep -iF needle file.txt'                 "grep -iF denied"
expect_rule GREP_IF 'grep -Fi needle file.txt'                 "grep -Fi denied"
expect_rule GREP_IF 'grep -i -F needle file.txt'               "grep -i -F denied"
expect_rule GREP_IF 'grep -F -i needle file.txt'               "grep -F -i denied"
expect_rule GREP_IF 'grep --ignore-case -F needle f'           "grep --ignore-case -F denied"
expect_rule GREP_IF 'grep -i --fixed-strings needle f'         "grep -i --fixed-strings denied"
expect_rule GREP_IF 'grep -ciF needle f'                       "grep -ciF denied (bundled with c)"
expect_rule GREP_IF 'grep -iFf pats f'                         "grep -iFf denied (f takes the next word)"
expect_rule GREP_IF 'grep -y -F needle f'                      "grep -y -F denied (y is -i)"
expect_rule GREP_IF 'grep needle file.txt -i -F'               "options after the pattern denied"
expect_rule GREP_IF 'fgrep -i needle f'                        "fgrep -i denied"
expect_rule GREP_IF 'git diff | grep -iF needle'               "grep -iF after a pipe denied"
expect_rule GREP_IF 'cd x && grep -ciF needle f; echo done'    "grep -iF mid-chain denied"
expect_rule GREP_IF 'n=$(grep -ciF needle f)'                  "grep -iF in a substitution denied"
expect_rule GREP_IF 'git ls-files | xargs grep -il -F needle'  "xargs grep -il -F denied"
expect_rule GREP_IF 'LC_ALL=C grep -iF needle f'               "grep -iF behind an env assignment denied"
expect_rule GREP_IF '/usr/bin/grep -iF needle f'               "grep by path denied"

expect_rule ALLOW 'grep -i needle f'                           "grep -i alone allowed"
expect_rule ALLOW 'grep -F needle f'                           "grep -F alone allowed"
expect_rule ALLOW 'grep -iE "a|b" f'                           "grep -iE allowed"
expect_rule ALLOW 'grep -i -f pats f'                          "grep -i -f (lowercase f, a file) allowed"
expect_rule ALLOW 'git grep -iF needle'                        "git grep -iF allowed (git's own grep works)"
expect_rule ALLOW 'rg -iF needle f'                            "rg -iF allowed"
expect_rule ALLOW 'grep -e -iF f'                              "-iF as the argument of -e allowed"
expect_rule ALLOW 'grep -Fe -i f'                              "-i as the argument of a bundled -e allowed"
expect_rule ALLOW 'grep -Fei f'                               "letters after a bundled -e are its argument, allowed"
expect_rule ALLOW 'grep -F --regexp -i f'                      "-i as the argument of --regexp allowed"
expect_rule ALLOW 'grep -F -- -i f'                            "-i after -- is a pattern, allowed"
expect_rule ALLOW 'grep -i needle f | grep -F other'           "-i and -F in separate greps allowed"
expect_rule ALLOW "tr 'A-Z' 'a-z' < f | grep -F needle"        "the remedy (tr, then grep -F) allowed"
expect_rule ALLOW 'echo grep -iF is broken'                    "grep as an argument, not a command, allowed"

# The corpus pass (816 transcript commands, 2026-10-20) found six false positives, every one
# a command that MENTIONS the trap inside quotes -- the docs this trap keeps generating. And
# two true hits that sit inside "$(...)", including the pre-push scan this rule exists for.
expect_rule ALLOW "grep -rn -i 'memory pressure\\|grep -iF\\|grep -qiF' dir"          "a quoted pattern naming grep -iF allowed"
expect_rule ALLOW "grep -n -e 'grep -iF' -e 'iF' *.md"                              "-e with a quoted pattern containing a space allowed"
expect_rule ALLOW "grep -c 'x | grep -qiF y' f"                                    "a pipe inside a single-quoted pattern allowed"
expect_rule ALLOW 'printf "%s\n" "use \`grep -iF\` never" >> notes.md'             "escaped backticks in double quotes allowed"
expect_rule ALLOW 'echo "never run grep -iF; it aborts" >> notes.md'                 "a double-quoted sentence allowed"
expect_rule ALLOW 'printf "%s\n" "a | grep -qiF b" > notes.md'                     "a pipe then grep -iF inside double quotes allowed"
expect_rule ALLOW "$(printf 'echo "first line\nx | grep -qiF y" > notes.md')"      "a quote spanning lines stays open on the next line"
expect_rule GREP_IF 'printf "%s=%s " "$p" "$(grep -ciF -- "$p" <<<"$D")"'           "grep -iF inside \"\$(...)\" denied (the original scan)"
expect_rule GREP_IF 'n="`grep -ciF x f`"'                                          "grep -iF in a backtick inside double quotes denied"
expect_rule GREP_IF 'grep -rlF "word sensitivity" -i dir'                          "-i after a quoted pattern denied"
expect_rule GREP_IF "grep -F \\'x -i f"                                            "an escaped quote opens no quoting, denied"
expect_rule GREP_IF 'n="$( (cd d); grep -ciF y f)"'                                "a subshell nested in \"\$(...)\" does not end it, denied"

HDGREP=$(printf 'cat > notes.md <<%sEOF%s\nuse grep -iF here\nEOF' "'" "'")
expect_rule ALLOW "$HDGREP"                                    "grep -iF inside a heredoc body allowed"

[ "$(verdict_tool PowerShell 'grep -iF needle f')" != DENY ] \
  && ok "rule 7 is Bash-only" \
  || bad "rule 7 denied under the PowerShell tool"

echo "== rule 8: MSYS rewrites <rev>:<path> when the rev has a slash and the path starts with a dot =="

expect_rule REV_PATH 'git show origin/main:.claude-plugin/marketplace.json'       "the recorded incident denied"
expect_rule REV_PATH 'git -C G:/repo show origin/main:.github/workflows/ci.yml'  "with -C denied"
expect_rule REV_PATH "git show 'origin/main:.gitignore'"                         "single-quoted denied (rewrite is after unquoting)"
expect_rule REV_PATH 'git show "origin/main:.gitignore"'                         "double-quoted denied"
expect_rule REV_PATH 'git cat-file -p refs/heads/main:.x'                        "cat-file denied"
expect_rule REV_PATH 'git show origin/main~2:.github/x'                          "rev with ~N denied"
expect_rule REV_PATH 'git diff origin/main:.x HEAD:.x'                           "diff denied"
expect_rule REV_PATH 'git show origin/main:..'                                   "path .. denied"

expect_rule ALLOW 'git show origin/main:personal/.claude-plugin/plugin.json'     "path not starting with a dot allowed (measured unchanged)"
expect_rule ALLOW 'git show HEAD:.gitignore'                                     "rev without a slash allowed (measured unchanged)"
expect_rule ALLOW 'git show HEAD~1:.x'                                           "HEAD~1 allowed"
expect_rule ALLOW 'git show origin/main:a/.b'                                    "dot later in the path allowed"
expect_rule ALLOW 'MSYS_NO_PATHCONV=1 git show origin/main:.gitignore'           "the remedy (one-command prefix) allowed"
expect_rule ALLOW 'git show origin/main:README.md'                               "a plain rev:path allowed"
expect_rule ALLOW 'git show origin/main:README.md && echo a:.b'                  "a plain rev:path allowed when :. appears elsewhere"
expect_rule ALLOW 'git clone git@github.com:org/.dotfiles'                       "scp-style URL allowed (no slash before the colon)"
expect_rule ALLOW 'ls origin/main:.x'                                            "not a git command, allowed"

HDREV=$(printf 'cat > notes.md <<%sEOF%s\ngit show origin/main:.gitignore\nEOF' "'" "'")
expect_rule ALLOW "$HDREV"                                                       "inside a heredoc body allowed"

[ "$(verdict_tool PowerShell 'git show origin/main:.gitignore')" != DENY ] \
  && ok "rule 8 is Bash-only (PowerShell does no MSYS conversion)" \
  || bad "rule 8 denied under the PowerShell tool"

echo "== output format =="

# The hook's JSON must be exactly what jq would pretty-print for the same object,
# key order and line endings included -- consumers were written against jq's output.
canon_ok() {
  local out
  out=$(jq -n --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null)
  [ -n "$out" ] && [ "$out" = "$(printf '%s' "$out" | jq .)" ]
}
canon_ok "node x.js" && ok "deny output is canonical jq pretty-print" \
  || bad "deny output is not byte-identical to jq's rendering"
canon_ok 'pytest -q | tail -20' && ok "warn output is canonical jq pretty-print" \
  || bad "warn output is not byte-identical to jq's rendering"

# A deny wins outright: the warning stage is never reached.
DW=$(jq -n --arg c 'node x.js | tail -3; echo "rc=$?"' '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null)
[ "$(printf '%s' "$DW" | jq -r '[.hookSpecificOutput.permissionDecision, (.systemMessage // "none")] | join(",")')" = "deny,none" ] \
  && ok "a deny suppresses any warning" \
  || bad "a deny and a warning were emitted together"

WM=$(jq -n --arg c 'pytest -q | tail -20' '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK" 2>/dev/null)
case "$(printf '%s' "$WM" | jq -r '.systemMessage + "|" + .hookSpecificOutput.additionalContext + "|" + .hookSpecificOutput.hookEventName')" in
  "windows-guard: Exit code"*"|WINDOWS GUARD WARNING -- Exit code"*"|PreToolUse") ok "warning carries both prefixes and the event name" ;;
  *) bad "warning JSON lost a prefix or the event name" ;;
esac

echo
echo "passed: $pass   failed: $fail   known-fail: $known"
[ "$fail" -eq 0 ] || exit 1
exit 0
