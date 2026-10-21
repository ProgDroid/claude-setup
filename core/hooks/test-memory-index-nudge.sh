#!/usr/bin/env bash
# Tests for memory-index-nudge.sh (bytes, three independent conditions) and for the shape
# of core/hooks/hooks.json.
# Run: bash core/hooks/test-memory-index-nudge.sh
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/memory-index-nudge.sh"
HOOKS_JSON="$DIR/hooks.json"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1 (got: $2)"; fail=$((fail + 1)); }
eq()  { [ "$1" = "$2" ] && ok "$3" || bad "$3" "[$1] expected [$2]"; }
has() { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "[$1] lacks [$2]" ;; esac; }
nlines() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MEM="$TMP/projects"
ERR="$TMP/err"
NOCM="$TMP/no-such-claude.md"          # nonexistent: the CLAUDE.md condition stays silent
mk() { mkdir -p "$MEM/$1/memory"; cat > "$MEM/$1/memory/MEMORY.md"; }
# rep <count> <bytes-per-line-excluding-newline>: count lines of exactly that many ASCII bytes
rep() { LC_ALL=C awk -v n="$1" -v w="$2" 'BEGIN { s = sprintf("%" w "s", ""); gsub(/ /, "x", s); for (i = 0; i < n; i++) print s }'; }
# run <args...>: sets OUT, RC and ERRV
run() { OUT="$(bash "$HOOK" "$@" 2>"$ERR")"; RC=$?; ERRV="$(cat "$ERR")"; }

[ -f "$HOOK" ] || { echo "  FAIL: hook missing: $HOOK"; echo "ran 1 assertions, 1 failed"; exit 1; }

echo "== total bytes =="
rep 200 99 | mk G--big                       # 200 lines x 100 bytes = 20000
rep 150 99 | mk G--exact                     # 15000 exactly
{ rep 150 99; printf 'x\n'; } | mk G--over1  # 15000 + 2 = 15002
printf -- '- [x](x.md) - y\n' | mk G--small
mkdir -p "$MEM/G--none/memory"
run --memory-root "$MEM" --project G--big --claude-md "$NOCM"
has "$OUT" "20000 bytes" "over-threshold index reports its byte count"
has "$OUT" "synthesize-memories" "nudge names the skill to run"
eq "$(nlines "$OUT")" "1" "total-only case prints exactly one line"
eq "$RC" "0" "over-threshold exits 0"
eq "$ERRV" "" "over-threshold is silent on stderr"
run --memory-root "$MEM" --project G--exact --claude-md "$NOCM"
eq "$OUT" "" "index of exactly 15000 bytes is silent (strictly greater)"
run --memory-root "$MEM" --project G--over1 --claude-md "$NOCM"
has "$OUT" "15002 bytes" "index of 15002 bytes fires"
run --memory-root "$MEM" --project G--small --claude-md "$NOCM"
eq "$OUT$ERRV" "" "small index is silent on both streams"
run --memory-root "$MEM" --project G--big --threshold 25000 --claude-md "$NOCM"
eq "$OUT" "" "--threshold raises the bar"

{ printf 'a\n'; rep 1 1001; printf 'b\n'; } | mk G--longline
echo "== silent, exit 0, on every missing thing =="
run --memory-root "$MEM" --project G--none --claude-md "$NOCM"
eq "$OUT$ERRV:$RC" ":0" "project with no MEMORY.md"
run --memory-root "$MEM" --project G--nonexistent --claude-md "$NOCM"
eq "$OUT$ERRV:$RC" ":0" "unknown project"
run --memory-root "$TMP/no-such-root" --project G--big --claude-md "$NOCM"
eq "$OUT$ERRV:$RC" ":0" "missing memory root"
run --memory-root "$TMP/no-such-root" --project G--big --claude-md "$TMP/no-such-dir/CLAUDE.md"
eq "$OUT$ERRV:$RC" ":0" "missing memory root and missing CLAUDE.md"
rep 101 119 > "$TMP/cm-big.md"        # 12120 bytes: over the CLAUDE.md limit
# Positive control: with these arguments the hook prints two lines.
run --memory-root "$MEM" --project G--big --claude-md "$TMP/cm-big.md"
eq "$(nlines "$OUT")" "2" "control: over-threshold index plus over-limit CLAUDE.md print two lines"
# A trailing value-less flag ends the run silently even though both conditions hold.
for flag in --memory-root --project --threshold --line-limit --claude-md --claude-md-limit; do
  run --memory-root "$MEM" --project G--big --claude-md "$TMP/cm-big.md" "$flag"
  eq "$OUT$ERRV:$RC" ":0" "trailing value-less $flag ends the run silently, exit 0"
done
# Default --claude-md and --memory-root come from HOME.
FH="$TMP/fakehome"; mkdir -p "$FH/.claude/projects/G--big/memory"
cp "$TMP/cm-big.md" "$FH/.claude/CLAUDE.md"; cp "$MEM/G--big/memory/MEMORY.md" "$FH/.claude/projects/G--big/memory/MEMORY.md"
OUT="$(HOME="$FH" bash "$HOOK" --project G--big 2>"$ERR")"; RC=$?
has "$OUT" "Global CLAUDE.md is 12120 bytes" "default --claude-md is HOME/.claude/CLAUDE.md"
has "$OUT" "20000 bytes" "default --memory-root is HOME/.claude/projects"
eq "$RC" "0" "HOME-default run exits 0"
# HOME unset: every path still exits 0 and prints nothing.
OUT="$(cd "$TMP" && env -u HOME bash "$HOOK" 2>"$ERR")"; RC=$?; ERRV="$(cat "$ERR")"
eq "$OUT$ERRV:$RC" ":0" "HOME unset: silent, exit 0"
OUT="$(env -u HOME bash "$HOOK" --memory-root "$MEM" --project G--big --claude-md "$TMP/cm-big.md" 2>"$ERR")"; RC=$?
eq "$(nlines "$OUT"):$RC" "2:0" "HOME unset with explicit flags still works"
run --bogus --nonsense x --memory-root "$MEM" --project G--small --claude-md "$NOCM"
eq "$OUT$ERRV:$RC" ":0" "unknown flags are ignored"
run --memory-root "$MEM" --project G--big --threshold abc --claude-md "$NOCM"
has "$OUT" "20000 bytes (threshold 15000)" "non-numeric --threshold falls back to the default and fires"
eq "$RC" "0" "non-numeric --threshold exits 0"
run --memory-root "$MEM" --project G--big --line-limit 1x --claude-md "$NOCM"
run --memory-root "$MEM" --project G--longline --line-limit 1x --claude-md "$NOCM"
has "$OUT" "line 2 is 1001 bytes" "non-numeric --line-limit falls back to the default and fires"
run --memory-root "$MEM" --project G--small --claude-md "$TMP/cm-big.md" --claude-md-limit 1x
has "$OUT" "limit 12000" "non-numeric --claude-md-limit falls back to the default and fires"
run --memory-root "$MEM" --project G--big --claude-md-limit "" --claude-md "$NOCM"
eq "$OUT$ERRV:$RC" ":0" "empty --claude-md-limit is silent"
mkdir -p "$MEM/G--unreadable/memory"; rep 200 99 > "$MEM/G--unreadable/memory/MEMORY.md"
chmod 000 "$MEM/G--unreadable/memory/MEMORY.md" 2>/dev/null
if [ -r "$MEM/G--unreadable/memory/MEMORY.md" ]; then
  echo "  SKIP: chmod 000 does not make the file unreadable here (Windows or root); unreadable-file case not run"
else
  run --memory-root "$MEM" --project G--unreadable --claude-md "$NOCM"
  eq "$OUT$ERRV:$RC" ":0" "unreadable index"
fi
chmod 644 "$MEM/G--unreadable/memory/MEMORY.md" 2>/dev/null

echo "== line limit, in bytes =="
run --memory-root "$MEM" --project G--longline --claude-md "$NOCM"
eq "$OUT" "Memory index line 2 is 1001 bytes: an index line is a pointer, not the memory. Move the content into the memory file." "1001-byte line: line message only, exact text"
{ printf 'a\n'; rep 1 1000; printf 'b\n'; } | mk G--edge
run --memory-root "$MEM" --project G--edge --claude-md "$NOCM"
eq "$OUT" "" "a 1000-byte line is silent (strictly greater)"
# 600 two-byte characters = 600 characters but 1200 bytes. Counting characters would stay silent.
{ printf 'a\n'; LC_ALL=C awk 'BEGIN { for (i = 0; i < 600; i++) printf "\303\251"; printf "\n" }'; } | mk G--multibyte
run --memory-root "$MEM" --project G--multibyte --claude-md "$NOCM"
has "$OUT" "line 2 is 1200 bytes" "multibyte line is measured in bytes, not characters"
# CRLF: a trailing CR is not part of the line. 1000 bytes + CR must NOT fire; 1001 + CR must report 1001.
{ printf 'a\r\n'; rep 1 1000 | sed 's/$/\r/'; printf 'b\r\n'; } | mk G--crlf-edge
{ printf 'a\r\n'; rep 1 1001 | sed 's/$/\r/'; printf 'b\r\n'; } | mk G--crlf-over
run --memory-root "$MEM" --project G--crlf-edge --claude-md "$NOCM"
eq "$OUT" "" "CRLF: a 1000-byte line plus CR does not fire"
run --memory-root "$MEM" --project G--crlf-over --claude-md "$NOCM"
has "$OUT" "line 2 is 1001 bytes" "CRLF: a 1001-byte line plus CR reports 1001"
run --memory-root "$MEM" --project G--longline --line-limit 5000 --claude-md "$NOCM"
eq "$OUT" "" "--line-limit raises the bar"
run --memory-root "$MEM" --project G--small --line-limit 5 --claude-md "$NOCM"
has "$OUT" "line 1 is 15 bytes" "--line-limit lowers the bar"

echo "== CLAUDE.md limit =="
rep 100 119 > "$TMP/cm-over.md"     # 100 x 120 = 12000 exactly
rep 101 119 > "$TMP/cm-over2.md"    # 12120
run --memory-root "$MEM" --project G--small --claude-md "$TMP/cm-over.md"
eq "$OUT" "" "CLAUDE.md of exactly 12000 bytes is silent"
run --memory-root "$MEM" --project G--small --claude-md "$TMP/cm-over2.md"
eq "$OUT" "Global CLAUDE.md is 12120 bytes (limit 12000) and loads every session. Move what is not always-needed into a skill, memory or learnings file." "CLAUDE.md over limit: CLAUDE.md message only, exact text"
run --memory-root "$MEM" --project G--small --claude-md "$TMP/cm-over2.md" --claude-md-limit 20000
eq "$OUT" "" "--claude-md-limit raises the bar"

echo "== all three =="
{ rep 150 99; rep 1 1500; } | mk G--all
run --memory-root "$MEM" --project G--all --claude-md "$TMP/cm-over2.md"
eq "$(nlines "$OUT")" "3" "all three conditions print three lines"
has "$OUT" "Memory index for this project is" "three-line output has the total line"
has "$OUT" "Memory index line 151 is 1500 bytes" "three-line output has the line message"
has "$OUT" "Global CLAUDE.md is 12120 bytes" "three-line output has the CLAUDE.md line"

echo "== project key derivation =="
# Linux-shaped project name (explicit --project)
rep 200 99 | mk -home-user-repo
run --memory-root "$MEM" --project -home-user-repo --claude-md "$NOCM"
has "$OUT" "20000 bytes" "Linux-shaped project (-home-user-repo) over threshold prints"
# No --project: key derived from cwd. Expected key is computed WITHOUT lib-key.sh (pwd -W
# on Git Bash gives C:/..., plain pwd on Linux; every non-alphanumeric becomes '-'), and the
# directory name contains a space, so a key function that leaves spaces alone cannot match.
WORK="$TMP/my proj"; mkdir -p "$WORK"
wd="$(cd "$WORK" && { pwd -W 2>/dev/null || pwd; })"
want="$(printf '%s\n' "$wd" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g')"
rep 200 99 | mk "$want"
# On Git Bash /tmp is a mount, so run from the real drive form the harness would report.
RUNDIR="$wd"; command -v cygpath >/dev/null 2>&1 && RUNDIR="$(cygpath -u "$wd")"
OUT="$(cd "$RUNDIR" && bash "$HOOK" --memory-root "$MEM" --claude-md "$NOCM" 2>"$ERR")"; RC=$?
has "$OUT" "20000 bytes" "no --project: key derived from cwd finds the index ($want)"
eq "$RC" "0" "cwd-derived run exits 0"
OUT="$(cd "$TMP" && bash "$HOOK" --memory-root "$MEM" --claude-md "$NOCM" 2>"$ERR")"
eq "$OUT" "" "no --project: a cwd with no index is silent"

echo "== hooks.json holds exactly the two registrations =="
if command -v jq >/dev/null 2>&1; then
  got="$(jq -c '.hooks' "$HOOKS_JSON" 2>/dev/null)"
  want_json='{"PostToolUse":[{"matcher":"Bash|Grep|Glob","hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/negative-result-guard.sh\"","timeout":10}]}],"SessionStart":[{"hooks":[{"type":"command","command":"bash \"${CLAUDE_PLUGIN_ROOT}/hooks/memory-index-nudge.sh\"","timeout":10}]}]}'
  eq "$got" "$want_json" "hooks.json .hooks equals the pre-registered two entries"
  eq "$(jq -c '.hooks | keys' "$HOOKS_JSON" 2>/dev/null)" '["PostToolUse","SessionStart"]' "hooks.json registers no other event"
  eq "$(jq -c '.hooks.SessionStart[0] | has("matcher")' "$HOOKS_JSON" 2>/dev/null)" "false" "SessionStart entry has no matcher"
else
  bad "jq required for the hooks.json assertions" "missing"
fi

echo "== real corpus (home machine only, opt-in) =="
REAL="$HOME/.claude/projects"
# Expected firing set: one project dir name per line, sorted, read from the file named by CORE_REAL_CORPUS_WANT.
if [ "${CORE_REAL_CORPUS:-}" != 1 ]; then
  echo "  SKIP: real-corpus control is opt-in (CORE_REAL_CORPUS=1); it pins live data that memory curation changes"
elif [ -z "${CORE_REAL_CORPUS_WANT:-}" ] || [ ! -f "$CORE_REAL_CORPUS_WANT" ]; then
  echo "  SKIP: real-corpus control needs CORE_REAL_CORPUS_WANT set to a file of expected project dir names (one per line, sorted)"
elif [ -d "$REAL" ] && ls "$REAL"/G--* >/dev/null 2>&1; then
  seen=0; fired=""
  for d in "$REAL"/*/; do
    n="$(basename "$d")"
    [ -f "$d/memory/MEMORY.md" ] || continue
    seen=$((seen + 1))
    o="$(bash "$HOOK" --memory-root "$REAL" --project "$n" --claude-md /dev/null 2>/dev/null)"
    [ -n "$o" ] && fired="$fired$n
"
  done
  fired="$(printf '%s' "$fired" | LC_ALL=C sort)"
  want_set="$(tr -d '\r' < "$CORE_REAL_CORPUS_WANT" | LC_ALL=C sort)"
  [ "$seen" -ge 20 ] && ok "control sees $seen real indexes" || bad "too few real indexes for the control to discriminate" "$seen"
  eq "$fired" "$want_set" "the hook fires on exactly the projects in the expectation file"
else
  echo "  SKIP: no home-layout ~/.claude/projects (no G--* dirs); real-corpus control not run"
fi

echo "ran $((pass + fail)) assertions, $fail failed"
[ "$fail" -eq 0 ]
