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
# Hit live on 2026-08-31 in G:\overleaf while pulling two compiled PDFs:
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

echo
echo "passed: $pass   failed: $fail   known-fail: $known"
[ "$fail" -eq 0 ] || exit 1
exit 0
