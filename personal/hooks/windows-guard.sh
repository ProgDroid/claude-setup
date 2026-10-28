#!/bin/bash
# windows-guard -- PreToolUse guard for Bash / PowerShell on Windows.
#
# Every rule here corresponds to a dated, verified incident in the user's global CLAUDE.md.
# These are failures where the rule was loaded in context and violated anyway, because prose
# loaded at session start does not intervene at the moment a command is composed. This does.
#
# PLATFORM GATE: exits silently off Windows. Several rules (notably the python one) describe
# MSYS/winpty behaviour and would produce false denials in a Linux cloud session.
#
# SPEED (rewritten 2026-10-18). This runs before EVERY Bash/PowerShell call, and it used to
# cost ~2.0 s per call (~2.8 s on a warning) because each rule was its own `echo | grep`
# pipeline: ~50 process spawns per run, at 50-80 ms apiece under MSYS. 46 runs in the
# transcripts hit the hook timeout. Now the input is parsed by ONE jq call and every rule is a
# bash builtin ([[ =~ ]], globs, parameter expansion); the output JSON is printed directly.
# Behaviour is pinned by test-windows-guard.sh and was diffed byte-for-byte against the
# grep version over a ~3,900-payload corpus.
#
# Two grep semantics the builtins must reproduce, or the rules silently change meaning:
#   - grep matches per LINE. `^`/`$` anchor at line breaks and [[:space:]] never spans one,
#     whereas [[ =~ ]] sees the whole string. Rules with an anchor or a class that could
#     cross a newline therefore go through any_line; pure substrings test the whole string.
#   - jq here is a native Windows binary: it writes CRLF, so a multi-line command arrives
#     with a CR before every LF, and MSYS's $() strips a trailing (CR)LF run. Both are kept
#     exactly as the old pipelines produced them rather than "cleaned up".

if [[ "$OSTYPE" != msys* && "$OSTYPE" != cygwin* ]]; then
    # $OSTYPE answers for Git Bash / MSYS2 / Cygwin without a spawn; anything else gets the
    # original uname check.
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) ;;
        *) exit 0 ;;
    esac
fi

have_jq=0
command -v jq >/dev/null 2>&1 && have_jq=1

if [[ $have_jq -eq 1 ]]; then
    # One jq call yields the tool, jq's own line ending, and the command, separated by
    # \x1f. The command comes LAST and keeps jq -r's trailing newline, so $() strips it
    # exactly as it did when the command was extracted by a call of its own.
    _raw=$(jq -j '(.tool_name // empty), "\u001f\n\u001f", (.tool_input.command // empty), "\n"')
    tool=${_raw%%$'\x1f'*}
    _rest=${_raw#*$'\x1f'}
    eol=${_rest%%$'\x1f'*}
    cmd=${_rest#*$'\x1f'}
    [[ "$_raw" == *$'\x1f'*$'\x1f'* ]] || cmd=""
    unset _raw _rest
else
    json_input=$(cat)
    tool=$(echo "$json_input" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
        | sed 's/.*:[[:space:]]*"\([^"]*\)".*/\1/')
    cmd=$(echo "$json_input" | sed -n 's/.*"command"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p')
fi

[[ -z "$cmd" ]] && exit 0
case "$tool" in Bash|PowerShell) ;; *) exit 0 ;; esac

# The command's lines, as `printf '%s\n' "$cmd" | while read` would see them.
if [[ "$cmd" == *$'\n'* ]]; then
    mapfile -t cmd_lines <<< "$cmd"
else
    cmd_lines=("$cmd")
fi

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
# literal quote appears inside a pattern here.
re_hd_open='<<-?[[:space:]]*[^[:space:];&|<>()]+'
re_hd_shell='(^|[;&|(]|&&)[[:space:]]*(bash|sh|zsh|dash|ksh)([[:space:]]|$)'
re_wsl='(^|[[:space:]/])wsl(\.exe)?([[:space:]]|$)'

kept=()
if [[ "$cmd" == *'<<'* ]]; then
    in_doc=0
    for line in "${cmd_lines[@]}"; do
        if [[ $in_doc -eq 1 ]]; then
            trimmed="${line#"${line%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            [[ "$trimmed" == "$delim" ]] && in_doc=0
            continue
        fi
        kept+=("$line")
        # Mask herestrings first so `<<<WORD` cannot be read as a heredoc opener.
        probe="${line//<<</@@HERESTRING@@}"
        [[ "$probe" == *'<<'* ]] || continue
        # The FIRST opener on the line, minus `<<`, `-` and leading space, minus quotes.
        [[ "$probe" =~ $re_hd_open ]] || continue
        delim=${BASH_REMATCH[0]}
        delim=${delim#<<}
        delim=${delim#-}
        delim=${delim#"${delim%%[![:space:]]*}"}
        delim=${delim//[$'\042\047']/}
        [[ "$delim" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        # A shell on the opening line means the body IS shell source: keep it
        # in scope so the rules still see it.
        [[ "$probe" =~ $re_hd_shell ]] && continue
        [[ "$probe" =~ $re_wsl ]] && continue
        in_doc=1
    done
else
    kept=("${cmd_lines[@]}")
fi

# $scan was `$(... | strip_inert_heredocs)`, and $() drops trailing empty lines and the one
# CR before each dropped LF. Reproduce that on the line array, then join.
while [[ ${#kept[@]} -gt 0 ]]; do
    _last=${kept[-1]}
    _last=${_last%$'\r'}
    if [[ -n "$_last" ]]; then kept[-1]=$_last; break; fi
    unset 'kept[-1]'
done
printf -v scan '%s\n' "${kept[@]}"
scan=${scan%$'\n'}
scan_lines=("${kept[@]}")
[[ ${#scan_lines[@]} -eq 0 ]] && scan_lines=("")

# any_line RE NEEDLE... -- true when some line of $scan matches the ERE, exactly as
# `echo "$scan" | grep -qE RE` did. Only lines containing one of the literal NEEDLEs reach
# the regex; every needle is a substring RE cannot match without, so this only skips work.
any_line() {
    local re=$1 l n
    shift
    for l in "${scan_lines[@]}"; do
        for n in "$@"; do
            if [[ "$l" == *"$n"* ]]; then
                [[ "$l" =~ $re ]] && return 0
                break
            fi
        done
    done
    return 1
}

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
if any_line '^[[:space:]]*(powershell(\.exe)?|pwsh(\.exe)?)([[:space:]]|$)' powershell pwsh; then
    leads_with_powershell=1
fi

if [[ "$tool" == "Bash" ]] && [[ "$leads_with_powershell" -eq 0 ]] \
   && any_line '(^|[;&|]|&&|\|\||[[:space:]]\$\()[[:space:]]*(python3?|node)[[:space:]]' python node; then
    deny="Bash tool cannot run python/node on this machine -- winpty makes it exit non-zero with 'stdin is not a tty' while printing nothing, so the step looks like it ran and did nothing. Write the script to a file and run: powershell.exe -NoProfile -Command \"python <script.py>\" -- or use py."
fi

# 2. sed touching a Windows drive path -> backslash escapes are live in the REPLACEMENT half.
#    \r becomes a literal CR, \f a form-feed; exits 0, corrupts quietly, and then blocks Edit
#    because the on-disk text contains bytes you never typed.
#
#    NARROWED 2026-10-28 (cli-timer): the drive path was matched as any letter-colon-backslash,
#    so `grep 'runs-on\|os:\|ubuntu'` beside a read-only sed was denied for its `s:\`. A drive
#    letter starts a word: it now needs the start, whitespace, a quote, `=`, `(`, `<` or `>`
#    right before it.
drive_re='(^|[[:space:]"'\''=(<>])[A-Za-z]:\\'
if [[ -z "$deny" ]] && any_line '(^|[[:space:]/|])sed([[:space:]]|$)' sed \
   && [[ "$scan" =~ $drive_re ]]; then
    deny="Never sed a Windows path -- backslashes are live escapes in the replacement half (\\r -> CR, \\f -> form-feed), it exits 0, and only od -c reveals the corruption. Use the Edit/Write tool, or write the path with forward slashes (G:/...) which Python, Git Bash and Win32 all accept."
fi

# 3. git commit -m containing a backtick or $( -> bash command substitution silently
#    rewrites the commit message.
#
#    FIXED 2026-10-21. "-m" was a substring test, which is wrong both ways. It denied
#    `git commit -F "$M"` whose message file was handoff-msg.txt (in a command that also
#    ran $(git diff ...)), and it passed bundled flags such as -qm and -am, where a letter
#    sits between the dash and the m. Now -m must be a flag: a dash-led token at the start
#    or after whitespace, letters then m, or --message. Regression: test-windows-guard.sh.
commit_msg_flag_re='(^|[[:space:]])(-[A-Za-z]*m|--message)([[:space:]="'"'"']|$)'
if [[ -z "$deny" ]] && any_line 'git[[:space:]]+commit' commit \
   && [[ "$scan" =~ $commit_msg_flag_re ]] \
   && [[ "$scan" == *'`'* || "$scan" == *'$('* ]]; then
    deny="git commit -m with a backtick or \$( triggers command substitution and mangles the message silently. Use: git commit -F - with a single-quoted heredoc (<<'EOF' ... EOF)."
fi

# 4. PowerShell (Get-Content -Raw) -replace ... | Set-Content -> BOM-less UTF-8 is read as ANSI
#    and every multibyte char is double-encoded to mojibake.
if [[ -z "$deny" ]] && [[ "$scan" == *Get-Content* ]] \
   && [[ "$scan" == *-replace* ]] \
   && [[ "$scan" == *Set-Content* ]]; then
    deny="Never bulk-edit source via (Get-Content -Raw) -replace | Set-Content -- BOM-less UTF-8 is read as ANSI and every emoji/em-dash is double-encoded to mojibake. Use the Edit tool with replace_all. If already run: git checkout -- <file>."
fi

# 5. Driving WSL with an argument-form script -> a quoting layer is lost in the
#    Bash->wsl->sh chain; loop vars expand to empty and sed silently no-ops, both exiting 0.
if [[ -z "$deny" ]] && any_line "$re_wsl" wsl \
   && any_line 'sh[[:space:]]+-[a-z]*c' sh; then
    deny="Do not pass a WSL script as an argument (sh -lc '...') -- a quoting layer is lost in the Bash->wsl->sh chain: loop variables expand to empty and sed expressions fail to apply while still exiting 0. Pass it on stdin instead: wsl.exe -d <distro> -- sh -s <<'EOF' ... EOF"
fi

# 6. claude mcp add from Bash -> MSYS path conversion rewrites a bare /c to C:/ before the
#    CLI sees it, silently storing a broken launcher in ~/.claude.json.
if [[ -z "$deny" ]] && [[ "$tool" == "Bash" ]] \
   && any_line 'claude[[:space:]]+mcp[[:space:]]+add' mcp; then
    deny="Run 'claude mcp add' from PowerShell, not Bash -- MSYS path conversion rewrites a bare /c argument to C:/ before the CLI sees it, silently storing a broken launcher (args: [\"C:/\", \"npx\", ...]) in ~/.claude.json."
fi

# Rules 7 and 8 look at SIMPLE COMMANDS rather than lines: a line is cut at ; & | ( ) and
# backticks and each piece is split into words.
#
# for_each_command FN -- calls FN once per simple command of the lines in _fe_lines, with
# the words in _w and the index of the command word in _c (leading VAR=x assignments and
# wrapper words such as xargs, time or env skipped). Stops at the first FN that returns 0.
for_each_command() {
    local fn=$1 line seg segs
    for line in "${_fe_lines[@]}"; do
        line=${line//[;&|()\`]/$'\n'}
        mapfile -t segs <<< "$line"
        for seg in "${segs[@]}"; do
            read -ra _w <<< "$seg"
            _c=0
            while [[ $_c -lt ${#_w[@]} ]]; do
                case "${_w[_c]}" in
                    [A-Za-z_]*=*|'!'|time|command|exec|env|nice|xargs|sudo) _c=$((_c + 1)) ;;
                    timeout) _c=$((_c + 2)) ;;
                    -*) [[ $_c -gt 0 ]] || break; _c=$((_c + 1)) ;;
                    *) break ;;
                esac
            done
            [[ $_c -lt ${#_w[@]} ]] || continue
            "$fn" && return 0
        done
    done
    return 1
}

# 7. grep with -i and -F together -> Git Bash's grep 3.0 aborts: exit 134, no output even on
#    stderr, a grep.exe.stackdump in the cwd. Every spelling was measured 2026-10-20 (-iF,
#    -i -F, the long forms, -y, fgrep -i, options after the pattern). Every term reads as
#    absent, so a pre-push privacy scan reported "clean" -- three times, twice on releases
#    of a public repo. rg -iF and git grep -iF work, and are not matched.
_grep_if() {
    local k=$_c word ci=0 cf=0 j ch
    case "${_w[k]##*/}" in
        grep|egrep) ;;
        fgrep) cf=1 ;;
        *) return 1 ;;
    esac
    for (( k = k + 1; k < ${#_w[@]}; k++ )); do
        word=${_w[k]}
        case "$word" in
            --) break ;;
            --ignore-case) ci=1 ;;
            --fixed-strings) cf=1 ;;
            --regexp|--file|--max-count|--after-context|--before-context|--context|--directories|--devices|--include|--exclude|--exclude-dir|--exclude-from|--label|--binary-files)
                k=$((k + 1)) ;;
            --*) ;;
            -?*)
                # A short-option bundle. An option taking an argument swallows the rest
                # of the bundle, or the next word when it ends the bundle.
                for (( j = 1; j < ${#word}; j++ )); do
                    ch=${word:j:1}
                    case "$ch" in
                        i|y) ci=1 ;;
                        F) cf=1 ;;
                        e|f|m|A|B|C|d|D) [[ $j -eq $((${#word} - 1)) ]] && k=$((k + 1)); break ;;
                    esac
                done ;;
        esac
    done
    [[ $ci -eq 1 && $cf -eq 1 ]]
}

# mask_quotes -- fills _fe_lines with the lines of $scan, quoted LITERAL text replaced by '_'
# and each quote by a space, so a quoted pattern can be neither options nor separators. Code
# bash RUNS inside double quotes -- "$(...)" and unescaped backticks -- is kept, ending in ';'.
#
# Rule 7 needs this and the quote-blind rules do not: an 816-command transcript pass found
# six false positives, every one a command MENTIONING the trap in quotes (a search pattern
# for the notes about it, a printf writing those notes), and two true hits inside "$(...)",
# one of them the pre-push scan the rule exists for. Masking ALL double-quoted text would
# have lost that one. Quoting state is tracked as a stack in $st, carried from line to line:
# N top level, S single, D double, C "$(" inside D, B a backtick inside D, P a parenthesis
# inside C.
#
# SPEED: work is per LINE, and within a line the text up to the next character that matters
# is copied in one step. A ${s:i:1} loop over the whole command rescans the string on every
# call, so it is quadratic: ~1 s per call on an 8,800-character command, the class the
# builtin rewrite removed. Each step still copies the rest of its line, so one very long
# line is the slow case (~0.5 s at 8,800 characters with 400 quotes). Measured over the 738
# transcript commands that reach this function: no line was longer than 470 characters.
mask_quotes() {
    local LC_ALL=C
    local line st=N
    _fe_lines=()
    for line in "${scan_lines[@]}"; do
        mask_line "$line"
        _fe_lines+=("$_masked")
    done
    return 0
}

# mask_line LINE -- one line of mask_quotes, reading and updating the caller's $st.
mask_line() {
    local rest=$1 lit ch top
    _masked=""
    while [[ -n "$rest" ]]; do
        top=${st: -1}
        case "$top" in
            S) lit=${rest%%\'*} ;;
            D) lit=${rest%%[\\\"\`\$]*} ;;
            *) lit=${rest%%[\\\'\"\`\(\)]*} ;;
        esac
        if [[ "$top" == [SD] ]]; then _masked+=${lit//?/_}; else _masked+=$lit; fi
        rest=${rest:${#lit}}
        [[ -n "$rest" ]] || break
        ch=${rest:0:1}
        rest=${rest:1}
        case "$top" in
            S)
                st=${st%?}; _masked+=" " ;;
            D)
                case "$ch" in
                    \\) _masked+="__"; rest=${rest:1} ;;
                    '"') st=${st%?}; _masked+=" " ;;
                    '`') st+=B; _masked+=";" ;;
                    '$') if [[ "$rest" == '('* ]]; then st+=C; _masked+=";"; rest=${rest:1}; else _masked+="_"; fi ;;
                esac ;;
            *)
                case "$ch" in
                    \\) _masked+="__"; rest=${rest:1} ;;
                    "'") st+=S; _masked+=" " ;;
                    '"') st+=D; _masked+=" " ;;
                    '`') if [[ "$top" == B ]]; then st=${st%?}; _masked+=";"; else _masked+='`'; fi ;;
                    '(') [[ "$top" == C || "$top" == P ]] && st+=P; _masked+="(" ;;
                    ')') if [[ "$top" == C ]]; then st=${st%?}; _masked+=";"
                         elif [[ "$top" == P ]]; then st=${st%?}; _masked+=")"
                         else _masked+=")"; fi ;;
                esac ;;
        esac
    done
}

if [[ -z "$deny" ]] && [[ "$tool" == "Bash" ]] && [[ "$scan" == *grep* ]] \
   && [[ "$scan" == *-*[iy]* || "$scan" == *ignore-case* ]] \
   && [[ "$scan" == *-*F* || "$scan" == *fixed-strings* || "$scan" == *fgrep* ]] \
   && mask_quotes && for_each_command _grep_if; then
    deny="Git Bash's grep aborts on -i combined with -F, in every spelling (-iF, -i -F, --ignore-case --fixed-strings, fgrep -i): exit 134, NO output even on stderr, and a grep.exe.stackdump in the cwd. Every term then reads as absent -- that is how a pre-push privacy scan reported 'clean' three times. Lowercase both sides and drop -i (tr 'A-Z' 'a-z' < f | grep -F term), or drop -F and escape the pattern. rg -iF and git grep -iF both work."
fi

# 8. git <rev>:<path> where the rev has a slash and the path starts with a dot -> MSYS reads
#    the argument as a path list and rewrites it: origin/main:.github/x reaches git as
#    origin\main;.github\x ("ambiguous argument"). Measured 2026-10-20 over 45 shapes: only
#    that combination is rewritten (HEAD:.x and origin/main:x/.y are not), and quoting does
#    not help because the rewrite happens after bash unquotes. Hit three times, all on
#    post-release version checks; the follow-on trap is exporting MSYS_NO_PATHCONV, which
#    silently breaks every /g/... path in the same command. A quoted word needs no
#    unquoting here: a leading quote cannot change what the pattern matches.
_re_rev_dot_path='^[^:]*[/\\][^:]*:\.'
_git_rev_dot_path() {
    local k
    case "${_w[_c]##*/}" in git|git.exe) ;; *) return 1 ;; esac
    for (( k = _c + 1; k < ${#_w[@]}; k++ )); do
        [[ "${_w[k]}" =~ $_re_rev_dot_path ]] && return 0
    done
    return 1
}

if [[ -z "$deny" ]] && [[ "$tool" == "Bash" ]] && [[ "$scan" == *:.* ]] \
   && [[ "$scan" != *MSYS_NO_PATHCONV* && "$scan" != *MSYS2_ARG_CONV_EXCL* ]] \
   && _fe_lines=("${scan_lines[@]}") && for_each_command _git_rev_dot_path; then
    deny="MSYS rewrites a <rev>:<path> argument whose rev contains a slash and whose path starts with a dot: origin/main:.github/x reaches git as origin\\main;.github\\x and fails with 'ambiguous argument'. Quoting does not help. Prefix this ONE command with MSYS_NO_PATHCONV=1. Never export it: /g/... paths then stop converting and every probe in the command fails, some as plausible zeros -- write G:/... paths alongside it."
fi

# json_str S -- sets _json to S as a JSON string body, escaped as jq escapes it. Returns 1
# for a control character, whose escape form the caller leaves to jq itself.
json_str() {
    case "$1" in
        *[$'\001'-$'\037\177']*) return 1 ;;
    esac
    _json=${1//\\/\\\\}
    _json=${_json//\"/\\\"}
}

if [[ -n "$deny" ]]; then
    if [[ $have_jq -eq 1 ]]; then
        # Byte-identical to `jq -n` pretty-printing this object, jq's line ending included.
        if json_str "$deny"; then
            printf '{%s  "hookSpecificOutput": {%s    "hookEventName": "PreToolUse",%s    "permissionDecision": "deny",%s    "permissionDecisionReason": "%s"%s  }%s}%s' \
              "$eol" "$eol" "$eol" "$eol" "$_json" "$eol" "$eol" "$eol"
        else
            jq -n --arg r "$deny" \
              '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"deny", permissionDecisionReason:$r}}'
        fi
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
#
#    NARROWED 2026-09-06. The exclusion was grep|rg only, so the rule fired on every
#    `[ -d "$x" ] && echo YES || echo NO` -- twice in one measured session, wrong both
#    times. A test builtin's exit code is precisely what the idiom wants, and the rule's
#    own rationale ("query tools that exit 0 and print nothing on no result") does not
#    describe it at all. The exclusion now covers everything whose exit status IS the
#    answer: test builtins, command -v, and the comparison tools.
if any_line '&&[[:space:]]*echo' '&&' && any_line '\|\|[[:space:]]*echo' '||' \
   && ! any_line '(^|[[:space:]/|(])(grep|rg|test|\[|\[\[|diff|cmp)([[:space:]]|$)|command[[:space:]]+-v' \
        grep rg test '[' diff cmp command; then
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
#
#    NARROWED AGAIN 2026-09-06, from measurement rather than impression: across one long
#    session it fired 7 times and was right ONCE. Two changes, both from that data.
#
#    First, `$?` anywhere in the command was enough to trigger. But every false positive
#    had the SAME shape -- the status was captured BEFORE the pipe, and the tail/head was
#    on something else entirely (a log file, a listing, a byte dump). A flat regex over the
#    whole string cannot see which pipeline a `$?` belongs to, so position is now checked:
#    a `$?` AFTER the last tail/head is reading the wrapper's status and is worth warning
#    about; one before it is reading something else and is not. The single true positive
#    (`... | head -20; echo "rc=$?"`) is exactly the after case, and is still caught.
#
#    Second, REAL_EXIT was in the trigger list -- so writing `REAL_EXIT=$?`, which is
#    verbatim what the message tells you to do, produced the message telling you to do it.
#    A rule that fires on its own remedy teaches you to skim it, which is what it costs:
#    in that same session the one true positive WAS skimmed past.
#    NARROWED A THIRD TIME 2026-09-06, from a firing measured after the second pass:
#    `... | head` on one line, then `echo x; diff -rq a b; echo "DIFF_EXIT=$?"` on the
#    next. That `$?` belongs to diff, two commands downstream. Asking whether a `$?`
#    appears ANYWHERE after the last tail/head cannot see intervening commands that
#    reset the status, so only the command IMMEDIATELY after tail/head is considered
#    now -- nothing later can be reading its status.
#
#    The same pass fixed a FALSE NEGATIVE in the opposite direction, found by the
#    presence-sibling test written to prove the narrowing had not gone too far:
#    the trailing class was ([[:space:]]|$), so `| head;` matched neither branch and
#    never fired at all. Only `| head -20;` was ever caught, because the space before
#    the flag satisfied it.
if [[ -z "$warn" ]] && any_line '(\||;)[[:space:]]*(tail|head)([[:space:]]|[;&|]|$)' tail head; then
    # Newlines become ';', NOT spaces. A newline is a command separator, and
    # flattening it to a space merged `| head` with the next line's command, erasing
    # the boundary the check below depends on.
    _flat=${scan//$'\n'/;}
    # Greedy .* runs to the LAST tail/head; what follows it is kept.
    _after=$_flat
    _re_last='^.*(\||;)[[:space:]]*(tail|head)'
    if [[ "$_flat" =~ $_re_last ]]; then
        _after=${_flat:${#BASH_REMATCH[0]}}
    fi

    # Drop tail/head's own arguments, drop the separator, keep exactly one command.
    _next=${_after#"${_after%%[;&|]*}"}
    _next=${_next#"${_next%%[!;&|]*}"}
    _next=${_next#"${_next%%[![:space:]]*}"}
    _next=${_next%%[;&|]*}

    _status_after_pipe=0
    if [[ "$_next" == *'$?'* ]]; then _status_after_pipe=1; fi

    _build_verb=0
    _re_build='(^|[[:space:];&|(])(npm|yarn|pnpm|bun|cargo|pytest|tox|go|make|ninja|cmake|bazel|gradle|gradlew|\./gradlew|flutter|dotnet|mvn|jest|vitest|ctest|docker|terraform|ansible)([[:space:]]|$)'
    if [[ "$_flat" =~ $_re_build ]]; then
        _build_verb=1
    fi

    # The remedy is already applied. Saying it again is pure noise.
    _remedy_applied=0
    if [[ "$_flat" == *REAL_EXIT=* ]]; then _remedy_applied=1; fi

    if [[ "$_remedy_applied" -eq 0 ]] \
       && { [[ "$_status_after_pipe" -eq 1 ]] || [[ "$_build_verb" -eq 1 ]]; }; then
        warn="Exit code here belongs to tail/head, not to the command you care about -- this is how a FAILED build gets reported as passing. Write the real status into the artifact: cmd >> LOG 2>&1; echo \"REAL_EXIT=\$?\" >> LOG, then grep the log. A missing REAL_EXIT line means UNKNOWN, not success."
    fi
fi

# c. a very large heredoc through the Bash tool can die with a bogus 'unexpected EOF'.
#    The quoting hypotheses were all tested and ruled out; size/transport is the variable.
#    (${#cmd_lines[@]} is what `echo "$cmd" | wc -l` counted.)
if [[ -z "$warn" ]] && [[ "$cmd" == *'<<'* ]] \
   && [[ ${#cmd_lines[@]} -gt 60 ]]; then
    warn="Large heredocs through the Bash tool can fail with a bogus 'unexpected EOF while looking for matching' error and write nothing. Quoting is NOT the cause -- do not re-test that. Use the Write tool for file content over ~50 lines."
fi

# d. PowerShell Set-Content/Add-Content default to the system ANSI codepage.
if [[ -z "$warn" ]] && [[ "$scan" == *Set-Content* || "$scan" == *Add-Content* ]] \
   && [[ "$scan" != *-Encoding* ]]; then
    warn="Set-Content/Add-Content default to the system ANSI codepage in PS 5.1. Pass -Encoding utf8 explicitly when other tools will read the file."
fi

# e. a FILE LIST piped into plain xargs splits on whitespace, and this machine's home
#    path has a space in it. Added 2026-10-05 from the escalation queue (probe-failures
#    section 12): a list containing spaces reported 0 files over 1,200 bytes when a
#    26,633-byte file was known to be in the set -- a false negative, not an error.
#
#    Scoped to keep the false-positive rate down, which is what retired rules a and b's
#    first versions: fires only when the producer is a FILENAME source (find, ls, fd,
#    git ls-files / diff --name-only / status, grep -l, rg -l / --files), and stays
#    silent when xargs already has a safe delimiter (-0, --null, -d, --delimiter, -I/-i,
#    --replace). Only option-shaped tokens directly after xargs count as ITS flags, so
#    the -i in `xargs grep -i` belongs to grep and does not silence the rule.
if [[ -z "$warn" ]] \
   && any_line '(^|[;&|(][[:space:]]*)(find|ls|fd|git[[:space:]]+(ls-files|diff[^|]*--name-only|status)|grep[^|]*[[:space:]]-[a-zA-Z]*l[a-zA-Z]*|rg[^|]*[[:space:]](-[a-zA-Z]*l[a-zA-Z]*|--files))([[:space:]][^|]*)?\|[[:space:]]*xargs([[:space:]]|$)' xargs \
   && ! any_line 'xargs([[:space:]]+-[^[:space:]]*)*[[:space:]]+(-0|--null|-d|--delimiter|-I|-i|--replace)' xargs; then
    warn="xargs splits on whitespace, and the home path here contains a space: a file list piped into plain xargs turns one path into two arguments and silently drops matches. Use xargs -d '\\n' (or find -print0 / git ls-files -z with xargs -0), or -I{} to take one line at a time."
fi

if [[ -n "$warn" ]]; then
    if [[ $have_jq -eq 1 ]]; then
        if json_str "$warn"; then
            printf '{%s  "systemMessage": "windows-guard: %s",%s  "hookSpecificOutput": {%s    "hookEventName": "PreToolUse",%s    "additionalContext": "WINDOWS GUARD WARNING -- %s"%s  }%s}%s' \
              "$eol" "$_json" "$eol" "$eol" "$eol" "$_json" "$eol" "$eol" "$eol"
        else
            jq -n --arg w "$warn" \
              '{systemMessage:("windows-guard: " + $w), hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:("WINDOWS GUARD WARNING -- " + $w)}}'
        fi
    fi
fi

exit 0
