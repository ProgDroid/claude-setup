#!/usr/bin/env bash
# Parity test: personal's memory_key must equal core's core_memory_key for every input, under every
# platform gate. The rule exists in two places because personal/hooks cannot source core at run
# time (the plugins install separately); this test is what keeps the twins equal. It lives in
# core/tests so promote-to-core's --scope core run executes it.
#
# Run:  bash core/tests/test-key-parity.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CORE_LIB="$REPO/core/hooks/lib-key.sh"
PERSONAL_LIB="$REPO/personal/hooks/lib-memory.sh"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

# A missing library is a FAILURE, never a skip: a skipped parity test is a test that cannot fail.
for f in "$CORE_LIB" "$PERSONAL_LIB"; do
  if [ ! -f "$f" ]; then
    bad "library missing: $f"
    echo "test-key-parity.sh: $pass PASS, $fail FAIL"
    exit 1
  fi
done
. "$CORE_LIB"
. "$PERSONAL_LIB"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
# A stub `uname` per platform, first on PATH, so the gate is chosen by the test and not by the host.
for u in MINGW64_NT-10.0 Linux; do
  mkdir -p "$T/$u"
  printf '#!/bin/sh\necho %s\n' "$u" > "$T/$u/uname"
  chmod +x "$T/$u/uname"
done

cases=(
  'G:/a/b'
  'G:\a\b'
  'g:/a/b'
  '/g/a/b'
  '/home/user/repo'
  '/home/u/my_repo'
  '/g/My Docs/p'
  '/g/x/.claude/worktrees/y'
  '/g/web/my.app'
  '/home/u/a+b@c'
  '/a/repo'
)

# Every row: parity between the twins, AND each key non-empty and made only of [A-Za-z0-9-]. Without the
# second check, two functions that both print nothing would pass parity.
check_key() {  # <label> <uname> <input>
  local want got k pair
  want="$(PATH="$T/$2:$PATH" core_memory_key "$3")"
  got="$(PATH="$T/$2:$PATH" memory_key "$3")"
  [ "$got" = "$want" ] && ok "$1: '$3' -> '$got'" || bad "$1: '$3': memory_key gave '$got', core gave '$want'"
  for pair in "core:$want" "personal:$got"; do
    k="${pair#*:}"
    if [[ -n "$k" && "$k" =~ ^[A-Za-z0-9-]+$ ]]; then ok "$1: $pair is a non-empty [A-Za-z0-9-] key"
    else bad "$1: ${pair%%:*} key is empty or has other characters: '$k'"; fi
  done
}

for u in MINGW64_NT-10.0 Linux; do
  for c in "${cases[@]}"; do
    check_key "$u" "$u" "$c"
  done
done

# Literal rows: input|key under MSYS|key under Linux. A path holding a newline is ONE path to the single
# path entry points, so the newline keys to '-' like any other character (core_memory_keys, the stream
# form, stays one path per line by design). The drive-root rows pin the bare-drive edge.
NL=$'\n'
literals=(
  "/home/u/a${NL}b|-home-u-a-b|-home-u-a-b"
  "/g/x/a${NL}b|G--x-a-b|-g-x-a-b"
  'G:/|G--|G--'
  'g:|G--|G--'
  'G:\|G--|G--'
  '/g|G--|-g'
  '/g/|G--|-g-'
)
for row in "${literals[@]}"; do
  in="${row%%|*}"; rest="${row#*|}"; exp_msys="${rest%%|*}"; exp_linux="${rest#*|}"
  for u in MINGW64_NT-10.0 Linux; do
    [ "$u" = Linux ] && exp="$exp_linux" || exp="$exp_msys"
    check_key "$u" "$u" "$in"
    for fn in core_memory_key memory_key; do
      k="$(PATH="$T/$u:$PATH" "$fn" "$in")"
      [ "$k" = "$exp" ] && ok "$u: $fn '$in' = '$exp'" || bad "$u: $fn '$in' gave '$k', wanted '$exp'"
    done
  done
done

# Empty input: both return 1 and print nothing.
for fn in core_memory_key memory_key; do
  out="$("$fn" "")"; rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok "$fn: empty input returns 1, prints nothing" || bad "$fn: empty input rc=$rc out='$out'"
done

echo "test-key-parity.sh: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
