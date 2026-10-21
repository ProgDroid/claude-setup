#!/usr/bin/env bash
# Tests for lib-key.sh (core_memory_key).
# Run: bash core/hooks/test-lib-key.sh
# The fixtures use a neutral name: the real home name must not appear in this repo
# (privacy scan). The positive control against the REAL ~/.claude/projects covers it.
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib-key.sh
. "$DIR/lib-key.sh"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1 (got: $2)"; fail=$((fail + 1)); }
eqk() { local got; got="$(core_memory_key "$1")"; [ "$got" = "$2" ] && ok "$3" || bad "$3" "$got"; }

echo "== real-corpus control: core resolve-roots vs an inline legacy encoder =="
# WHAT THIS COVERS: the LEGACY encoder is the transform the private tool used before
# core_memory_key existed (path relative to the drive, '/', '_' and ' ' -> '-', prefix
# 'G--'), written inline and independent of lib-key.sh. Every real memory dir it can
# place must be placed by core resolve-roots at the SAME root. That checks the drive
# prefix and the '/', '_' and ' ' rules against real directories.
# WHAT IT DOES NOT COVER: any other character. Legacy leaves '.', '@' and the rest
# alone, so it places no dir that contains them. The rule for those characters is
# covered only by the fixed cases below.  Home layout only (needs /g and G--* dirs).
RR="${CORE_RESOLVE_ROOTS:-$DIR/../skills/synthesize-memories/scripts/resolve-roots.sh}"
if [ -d "$HOME/.claude/projects" ] && [ -d /g ] && [ -f "$RR" ]    && ls "$HOME"/.claude/projects/G--* >/dev/null 2>&1; then
  LEGACY="$(
    find /g -mindepth 1 -maxdepth 4 \( -name .git -o -name node_modules \) -prune -o -type d -print 2>/dev/null |
    while IFS= read -r dir; do
      rel="${dir#/g/}"; enc="${rel//\//-}"; enc="${enc//_/-}"; enc="G--${enc// /-}"
      [ -d "$HOME/.claude/projects/$enc/memory" ] && printf '%s	%s
' "$enc" "$dir"
    done
  )"
  # first match per name wins, as in resolve-roots
  LEGACY="$(printf '%s
' "$LEGACY" | awk -F'	' 'NF == 2 && !seen[$1]++')"
  CORE="$(bash "$RR" --search-root /g 2>/dev/null)"
  checked=0; mism=0
  while IFS=$'	' read -r name root; do
    [ -n "$name" ] || continue
    checked=$((checked + 1))
    got="$(printf '%s
' "$CORE" | awk -F'	' -v n="$name" '$1 == n { print $2; exit }')"
    [ "$got" = "$root" ] || { mism=$((mism + 1)); echo "    mismatch: $name legacy=$root core=${got:-<unplaced>}"; }
  done <<< "$LEGACY"
  [ "$checked" -gt 0 ] && ok "legacy encoder placed $checked real memory dirs (control can see)" || bad "legacy encoder placed none, control cannot discriminate" "0"
  [ "$mism" -eq 0 ] && ok "core resolve-roots places all $checked at the identical root" || bad "$mism of $checked legacy-placed dirs differ in core" "$mism"
else
  echo "  SKIP: not the home layout (no ~/.claude/projects/G--*, /g or resolve-roots); legacy-vs-core control not run"
fi

echo "== fixed cases =="
eqk 'G:/Work/Some One/Documents/dotfiles' 'G--Work-Some-One-Documents-dotfiles' "drive path with spaces"
eqk 'G:\Projects\notes-vault' 'G--Projects-notes-vault' "backslashes"
eqk 'G:/a.b/c' 'G--a-b-c' "dot in a path component becomes a dash"
eqk '/home/user/repo' '-home-user-repo' "linux path"
eqk '/home/me/my repo' '-home-me-my-repo' "linux path with space"
eqk '/ab/c' '-ab-c' "multi-letter first segment never converts"
eqk 'g:/x' 'G--x' "lower-case drive letter is upper-cased"
# The '/x/rest' drive rewrite is real only under MSYS/Cygwin; each branch runs on its own platform only.
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*)
    echo "  (MSYS/Cygwin: drive rewrite applies; Linux cases not run here)"
    eqk '/g/flutterDev/dynamic_day_planner' 'G--flutterDev-dynamic-day-planner' "MSYS form, underscore"
    eqk '/g/a.b/c' 'G--a-b-c' "MSYS form, dot in a component"
    eqk '/g' 'G--' "MSYS bare drive"
    eqk '/w/x' 'W--x' "MSYS: single-letter first segment is a drive"
    ;;
  *)
    echo "  (not MSYS: drive rewrite must NOT apply; MSYS cases not run here)"
    eqk '/w/x' '-w-x' "Linux: single-letter first segment is a real path"
    eqk '/a/repo' '-a-repo' "Linux: /a/repo keys as -a-repo"
    eqk '/g' '-g' "Linux: bare single letter is not a drive"
    eqk '/g/flutterDev/dynamic_day_planner' '-g-flutterDev-dynamic-day-planner' "Linux: no drive rewrite for a /g/ path"
    ;;
esac
out="$(core_memory_key '')"; rc=$?
[ "$rc" -eq 1 ] && [ -z "$out" ] && ok "empty input: exit 1, no output" || bad "empty input" "rc=$rc out=$out"

echo "ran $((pass + fail)) assertions, $fail failed"
[ "$fail" -eq 0 ]
