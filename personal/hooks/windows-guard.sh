#!/bin/bash
# windows-guard -- PreToolUse guard for Bash / PowerShell on Windows.
#
# Every rule here corresponds to a dated, verified incident in the user's global CLAUDE.md.
# These are failures where the rule was loaded in context and violated anyway, because prose
# loaded at session start does not intervene at the moment a command is composed. This does.
#
# PLATFORM GATE: exits silently off Windows. Several rules (notably the python one) describe
# MSYS/winpty behaviour and would produce false denials in a Linux cloud session.

case "$(uname -s 2>/dev/null)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) exit 0 ;;
esac

json_input=$(cat)

if command -v jq >/dev/null 2>&1; then
    tool=$(echo "$json_input" | jq -r '.tool_name // empty')
    cmd=$(echo "$json_input" | jq -r '.tool_input.command // empty')
else
    tool=$(echo "$json_input" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')
    cmd=$(echo "$json_input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')
fi

[[ -z "$cmd" ]] && exit 0
case "$tool" in Bash|PowerShell) ;; *) exit 0 ;; esac

# ---------- heredoc stripping (shared by every rule below) ----------
#
# FIXED 2026-09-01 (bug #2, recorded as a KNOWN-FAIL in test-windows-guard.sh).
# Every rule below matched the RAW command string, heredoc bodies included --
# but a heredoc body is normally data being written to a file, not commands
# bash runs. Writing a Dockerfile whose RUN line calls an interpreter, or a doc
# containing a `sed 'C:\...'` example, tripped rules that describe how bash
# EXECUTES things. Two live false denials on 2026-09-01.
#
# The body is NOT inert when the heredoc feeds a shell: `bash <<EOF ... EOF`
# and `sh -s <<EOF ... EOF` execute it, and an interpreter line in there really
# does hit winpty. So the discriminator is the OPENING line's command, NOT the
# quoting of the delimiter -- <<'EOF' suppresses expansion, not execution. That
# is why the obvious "only strip quoted heredocs" fix would have been wrong.
#
# Rule c (oversized heredoc) deliberately keeps reading "$cmd": it is a rule
# ABOUT heredocs and must see the body it is measuring.
#
# Quote characters are matched via octal escapes (\042 ", \047 ') so that no
# literal quote appears inside a pattern in this function.
strip_inert_heredocs() {
    local line probe delim trimmed in_doc=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ $in_doc -eq 1 ]]; then
            trimmed="${line#"${line%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            [[ "$trimmed" == "$delim" ]] && in_doc=0
            continue
        fi
        printf '%s\n' "$line"
        # Mask herestrings first so `<<<WORD` cannot be read as a heredoc opener.
        probe="${line//<<</@@HERESTRING@@}"
        case "$probe" in
            *"<<"*) ;;
            *) continue ;;
        esac
        delim=$(printf '%s' "$probe" \
            | grep -oE '<<-?[[:space:]]*[^[:space:];&|<>()]+' \
            | head -1 \
            | sed -E 's/^<<-?[[:space:]]*//' \
            | tr -d '\042\047')
        [[ "$delim" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # A shell on the opening line means the body IS shell source: keep it
        # in scope so the rules still see it.
        if printf '%s' "$probe" | grep -qE '(^|[;&|(]|&&)[[:space:]]*(bash|sh|zsh|dash|ksh)([[:space:]]|$)'; then
            continue
        fi
        if printf '%s' "$probe" | grep -qE '(^|[[:space:]/])wsl(\.exe)?([[:space:]]|$)'; then
            continue
        fi
        in_doc=1
    done
}

scan=$(printf '%s\n' "$cmd" | strip_inert_heredocs)

deny=""   # set to a reason string to block

# ---------- DENY rules ----------

# 1. python/node under the Bash tool -> winpty: exits non-zero with 'stdin is not a tty',
#    prints nothing, and reads like a script that ran and did nothing.
#
#    FIXED 2026-09-01. The matcher is quote-blind: it scans the raw Bash string with no notion
#    of quoting, so a ';' INSIDE `powershell.exe -Command "..."` was read as a Bash separator
#    and the two-call form was denied even though nothing runs under winpty. The rationale for
#    this rule cannot apply once the command dispatches to PowerShell, so skip it when
#    powershell/pwsh is the LEADING command. `python x.py && powershell.exe ...` stays denied,
#    because there python leads. Regression test: personal/hooks/test-windows-guard.sh.
leads_with_powershell=0
if printf '%s' "$scan" | grep -qE '^[[:space:]]*(powershell(\.exe)?|pwsh(\.exe)?)([[:space:]]|$)'; then
    leads_with_powershell=1
fi

if [[ "$tool" == "Bash" ]] && [[ "$leads_with_powershell" -eq 0 ]] \
   && echo "$scan" | grep -qE '(^|[;&|]|&&|\|\||[[:space:]]\$\()[[:space:]]*(python3?|node)[[:space:]]'; then
    deny="Bash tool cannot run python/node on this machine -- winpty makes it exit non-zero with 'stdin is not a tty' while printing nothing, so the step looks like it ran and did nothing. Write the script to a file and run: powershell.exe -NoProfile -Command \"python <script.py>\" -- or use py."
fi

# 2. sed touching a Windows drive path -> backslash escapes are live in the REPLACEMENT half.
#    \r becomes a literal CR, \f a form-feed; exits 0, corrupts quietly, and then blocks Edit
#    because the on-disk text contains bytes you never typed.
if [[ -z "$deny" ]] && echo "$scan" | grep -qE '(^|[[:space:]/|])sed([[:space:]]|$)' \
   && echo "$scan" | grep -qE '[A-Za-z]:\\'; then
    deny="Never sed a Windows path -- backslashes are live escapes in the replacement half (\\r -> CR, \\f -> form-feed), it exits 0, and only od -c reveals the corruption. Use the Edit/Write tool, or write the path with forward slashes (G:/...) which Python, Git Bash and Win32 all accept."
fi

# 3. git commit -m containing a backtick or $( -> bash command substitution silently
#    rewrites the commit message.
if [[ -z "$deny" ]] && echo "$scan" | grep -qE 'git[[:space:]]+commit' \
   && echo "$scan" | grep -qE '\-m' \
   && echo "$scan" | grep -qE '`|\$\('; then
    deny="git commit -m with a backtick or \$( triggers command substitution and mangles the message silently. Use: git commit -F - with a single-quoted heredoc (<<'EOF' ... EOF)."
fi

# 4. PowerShell (Get-Content -Raw) -replace ... | Set-Content -> BOM-less UTF-8 is read as ANSI
#    and every multibyte char is double-encoded to mojibake.
if [[ -z "$deny" ]] && echo "$scan" | grep -q 'Get-Content' \
   && echo "$scan" | grep -q '\-replace' \
   && echo "$scan" | grep -q 'Set-Content'; then
    deny="Never bulk-edit source via (Get-Content -Raw) -replace | Set-Content -- BOM-less UTF-8 is read as ANSI and every emoji/em-dash is double-encoded to mojibake. Use the Edit tool with replace_all. If already run: git checkout -- <file>."
fi

# 5. Driving WSL with an argument-form script -> a quoting layer is lost in the
#    Bash->wsl->sh chain; loop vars expand to empty and sed silently no-ops, both exiting 0.
if [[ -z "$deny" ]] && echo "$scan" | grep -qE '(^|[[:space:]/])wsl(\.exe)?([[:space:]]|$)' \
   && echo "$scan" | grep -qE 'sh[[:space:]]+-[a-z]*c'; then
    deny="Do not pass a WSL script as an argument (sh -lc '...') -- a quoting layer is lost in the Bash->wsl->sh chain: loop variables expand to empty and sed expressions fail to apply while still exiting 0. Pass it on stdin instead: wsl.exe -d <distro> -- sh -s <<'EOF' ... EOF"
fi

# 6. claude mcp add from Bash -> MSYS path conversion rewrites a bare /c to C:/ before the
#    CLI sees it, silently storing a broken launcher in ~/.claude.json.
if [[ -z "$deny" ]] && [[ "$tool" == "Bash" ]] \
   && echo "$scan" | grep -qE 'claude[[:space:]]+mcp[[:space:]]+add'; then
    deny="Run 'claude mcp add' from PowerShell, not Bash -- MSYS path conversion rewrites a bare /c argument to C:/ before the CLI sees it, silently storing a broken launcher (args: [\"C:/\", \"npx\", ...]) in ~/.claude.json."
fi

if [[ -n "$deny" ]]; then
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg r "$deny" \
          '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
    else
        printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
          "$(printf '%s' "$deny" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^/"/; s/$/"/')"
    fi
    exit 0
fi

# ---------- WARN rules (advisory; command still runs) ----------

warn=""

# a. cmd && echo FOUND || echo MISSING is only valid for grep, which exits 1 on no match.
#    git ls-files / find / jq exit 0 and print nothing, so the && branch fires on an EMPTY result.
if echo "$scan" | grep -qE '&&[[:space:]]*echo' && echo "$scan" | grep -qE '\|\|[[:space:]]*echo' \
   && ! echo "$scan" | grep -qE '(^|[[:space:]/|])(grep|rg)([[:space:]]|$)'; then
    warn="This is the grep-only idiom. Non-grep query tools (git ls-files, git log, find, jq) exit 0 and print nothing on no result, so the && branch fires on an EMPTY result and reports the opposite of the truth. Capture into a variable and test emptiness instead."
fi

# b. a chain or pipe ending in tail/head reports the WRAPPER's exit code, not the real one.
#
#    NARROWED 2026-08-29. Previously this fired on ANY pipe to tail/head, which meant ~15 firings
#    in a single session -- almost all on read-only inspection (ls / grep / cat / wc / sed -n)
#    where the exit code was never going to be consumed. That is expensive twice over: each firing
#    rides along in conversation history for the rest of the session, and a warning that is
#    usually wrong trains the model to skim it, which costs the one time it is right.
#
#    Now fires only when the exit code plausibly MATTERS: a build/test/deploy verb is in the
#    command, or the command itself consumes a status ($? / REAL_EXIT). Both historical incidents
#    this rule exists for are still caught -- `flutter test ... | tail -150` (2026-05-09) and the
#    backgrounded Gradle chain ending in `tail` (2026-08-18).
if [[ -z "$warn" ]] && echo "$scan" | grep -qE '(\||;)[[:space:]]*(tail|head)([[:space:]]|$)' \
   && echo "$scan" | grep -qE '(^|[[:space:];&|(])(npm|yarn|pnpm|bun|cargo|pytest|tox|go|make|ninja|cmake|bazel|gradle|gradlew|\./gradlew|flutter|dotnet|mvn|jest|vitest|ctest|docker|terraform|ansible)([[:space:]]|$)|\$\?|REAL_EXIT'; then
    warn="Exit code here belongs to tail/head, not to the command you care about -- this is how a FAILED build gets reported as passing. Write the real status into the artifact: cmd >> LOG 2>&1; echo \"REAL_EXIT=\$?\" >> LOG, then grep the log. A missing REAL_EXIT line means UNKNOWN, not success."
fi

# c. a very large heredoc through the Bash tool can die with a bogus 'unexpected EOF'.
#    The quoting hypotheses were all tested and ruled out; size/transport is the variable.
if [[ -z "$warn" ]] && echo "$cmd" | grep -q '<<' \
   && [[ $(echo "$cmd" | wc -l) -gt 60 ]]; then
    warn="Large heredocs through the Bash tool can fail with a bogus 'unexpected EOF while looking for matching' error and write nothing. Quoting is NOT the cause -- do not re-test that. Use the Write tool for file content over ~50 lines."
fi

# d. PowerShell Set-Content/Add-Content default to the system ANSI codepage.
if [[ -z "$warn" ]] && echo "$scan" | grep -qE '(Set|Add)-Content' \
   && ! echo "$scan" | grep -q '\-Encoding'; then
    warn="Set-Content/Add-Content default to the system ANSI codepage in PS 5.1. Pass -Encoding utf8 explicitly when other tools will read the file."
fi

if [[ -n "$warn" ]]; then
    if command -v jq >/dev/null 2>&1; then
        jq -n --arg w "$warn" \
          '{systemMessage:("windows-guard: " + $w), hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:("WINDOWS GUARD WARNING -- " + $w)}}'
    fi
fi

exit 0
