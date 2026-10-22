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

for u in MINGW64_NT-10.0 Linux; do
  for c in "${cases[@]}"; do
    want="$(PATH="$T/$u:$PATH" core_memory_key "$c")"
    got="$(PATH="$T/$u:$PATH" memory_key "$c")"
    [ "$got" = "$want" ] && ok "$u: '$c' -> '$got'" || bad "$u: '$c': memory_key gave '$got', core gave '$want'"
  done
done

# Empty input: both return 1 and print nothing.
for fn in core_memory_key memory_key; do
  out="$("$fn" "")"; rc=$?
  [ "$rc" = 1 ] && [ -z "$out" ] && ok "$fn: empty input returns 1, prints nothing" || bad "$fn: empty input rc=$rc out='$out'"
done

echo "test-key-parity.sh: $pass PASS, $fail FAIL"
[ "$fail" -eq 0 ]
