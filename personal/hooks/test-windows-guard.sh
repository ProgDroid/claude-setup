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
# ⚠️  BUG #2 (found live 2026-09-01) is open, and is the same quote-blind matcher
#     seen from another angle: `^` anchors at every LINE, so a python line inside
#     a HEREDOC BODY is matched as though it were a command. Written as a
#     KNOWN-FAIL below, same convention as bug #1. See the note beside it for why
#     the obvious fix is not safe.
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

echo "== rule 1: heredoc bodies =="

# ---- known bug #2, found live 2026-09-01 ----
# Writing a .ps1 with a heredoc is DENIED because grep anchors '^' at every LINE, so a
# $PY line inside the heredoc BODY matches as if it were a command. The body is data being
# written to a file, not something bash executes.
#
# Hit while writing a PowerShell runner from the Bash tool:
#   cat > run.ps1 <<'EOF'
#   $PY -m pytest tests/
#   EOF
# Workaround used: write the .ps1 with the Write tool instead, which is not guarded.
#
# NOT fixed here because the safe fix is not obvious: stripping heredoc bodies before matching
# would also allow `bash <<EOF ... $PY x.py ... EOF`, which genuinely does run under winpty.
# A body is only inert when the heredoc's own command is not an interpreter. Left as a
# KNOWN-FAIL so it cannot be forgotten, same as bug #1 was.
HEREDOC=$(printf 'cat > run.ps1 <<%sEOF%s\n%s -m pytest tests/\nEOF' "'" "'" "$PY")
if [ "$(verdict "$HEREDOC")" = ALLOW ]; then
  ok "$PY inside a heredoc BODY allowed  <-- BUG IS FIXED, promote this to a real assertion and drop the xfail branch"
else
  xfail "$PY inside a heredoc body is DENIED; '^' anchors at every line, so body text is matched as a command"
fi

echo
echo "passed: $pass   failed: $fail   known-fail: $known"
[ "$fail" -eq 0 ] || exit 1
exit 0
