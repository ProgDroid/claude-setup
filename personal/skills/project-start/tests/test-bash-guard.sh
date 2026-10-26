#!/usr/bin/env bash
# Tests for the bash version guard in ritual.sh and hooks/handoff-session-start.sh.
# Run: bash personal/skills/project-start/tests/test-bash-guard.sh
#
# FLOOR: bash 4.4. Step 1 scan of ritual.sh, lib/*.sh and hooks/*.sh found the highest feature at
# `mapfile -d` (4.4): lib/common.sh:98 `mapfile -d $'\036' -t p` and lib/workspace.sh:190-191.
# (Also present: mapfile, local -A, ${x,,} at 4.0. windows-guard.sh has negative subscripts, 4.3,
# but is not guarded: see the task report.)
# RITUAL_TEST_BASH_VERSION ("MAJOR.MINOR") overrides the version the two guards read; tests only.
. "$(dirname "$0")/lib.sh"

HOOK="$SKILL_DIR/../../hooks/handoff-session-start.sh"

echo "== ritual.sh =="
out="$(RITUAL_TEST_BASH_VERSION=3.2 bash "$RITUAL" --help 2>"$TMPROOT/err")"; rc=$?
err="$(cat "$TMPROOT/err")"
if [ "$rc" = 2 ] && [ -z "$out" ] && [ "$(printf '%s\n' "$err" | wc -l | tr -d ' ')" = 1 ] \
   && case "$err" in *"bash 4.4"*"3.2"*) true ;; *) false ;; esac; then
  ok "ritual_guard_refuses_old_bash"
else bad "ritual_guard_refuses_old_bash: rc=$rc out='$out' err='$err'"; fi

RITUAL_TEST_BASH_VERSION=4.3 bash "$RITUAL" --help >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "ritual_guard_refuses_4_3" || bad "ritual_guard_refuses_4_3: rc=$rc"

RITUAL_TEST_BASH_VERSION=4.4 bash "$RITUAL" --help >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "ritual_guard_passes_floor_4_4" || bad "ritual_guard_passes_floor_4_4: rc=$rc"

RITUAL_TEST_BASH_VERSION=10.0 bash "$RITUAL" --help >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "ritual_guard_numeric_not_lexical" || bad "ritual_guard_numeric_not_lexical: rc=$rc"

env -u RITUAL_TEST_BASH_VERSION bash "$RITUAL" --help >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "ritual_guard_passes_current" || bad "ritual_guard_passes_current: rc=$rc"

echo "== handoff-session-start.sh =="
repo="$(mkrepo hook)"
mkdir -p "$repo/.claude"; echo '{}' > "$repo/.claude/handoff.json"
git -C "$repo" add .claude/handoff.json; git -C "$repo" commit -q -m "add handoff marker"
hook() { ( cd "$repo" && printf '{"source":"startup"}' | env "$@" bash "$HOOK" ); }

ctl="$(hook -u RITUAL_TEST_BASH_VERSION 2>&1)"
case "$ctl" in *additionalContext*) ok "session_start_control_speaks_without_knob" ;; *) bad "control: hook silent in a marker repo: '$ctl'" ;; esac

hook RITUAL_TEST_BASH_VERSION=3.2 >"$TMPROOT/o" 2>"$TMPROOT/e"; rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMPROOT/o" ] && [ ! -s "$TMPROOT/e" ]; then ok "session_start_guard_silent_exit0"
else bad "session_start_guard_silent_exit0: rc=$rc out='$(cat "$TMPROOT/o")' err='$(cat "$TMPROOT/e")'"; fi

hook RITUAL_TEST_BASH_VERSION=4.4 >"$TMPROOT/o" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && grep -q additionalContext "$TMPROOT/o"; then ok "session_start_guard_passes_floor_4_4"
else bad "session_start_guard_passes_floor_4_4: rc=$rc"; fi

finish
