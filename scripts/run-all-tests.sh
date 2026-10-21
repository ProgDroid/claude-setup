#!/usr/bin/env bash
# run-all-tests.sh [--scope core] [root]
# --scope core runs only the core/ suites (no personal/ tests, no OpenCode/bun) and the independent
# on-disk count covers core/ only. Used by core/scripts/promote-to-core.sh so a promotion stays quick;
# CI runs the unscoped suite on every push. The flag and the optional [root] may come in either order.
# Runs every shell test suite plus the OpenCode adapter's bun tests.
# Prints "ran N, failed M, skipped K" then "REAL_EXIT=<0|1>" as the LAST line.
# Fails (REAL_EXIT=1) when: any suite fails; nothing ran at all; or a test file on disk
# (found independently of the globs below) was neither run nor skipped.
scope=""; rootarg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      if [ $# -lt 2 ] || [ -z "$2" ]; then echo "run-all: --scope needs a value (only: core)"; echo "REAL_EXIT=2"; exit 2; fi
      scope="$2"; shift 2 ;;
    --scope=*)
      scope="${1#--scope=}"
      if [ -z "$scope" ]; then echo "run-all: --scope= needs a value (only: core)"; echo "REAL_EXIT=2"; exit 2; fi
      shift ;;
    *) rootarg="$1"; shift ;;
  esac
done
case "$scope" in
  ""|core) ;;
  *) echo "run-all: unknown --scope '$scope' (only: core)"; echo "REAL_EXIT=2"; exit 2 ;;
esac
root="${rootarg:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$root" || { echo "run-all: cannot cd to $root"; echo "REAL_EXIT=1"; exit 1; }
ran=0; failed=0; skipped=0
seen=()   # every test file the runner handled (ran or skipped), for the independent count

skiplist=""
if [ "$(uname -s)" = Linux ] && [ -f scripts/linux-skip.txt ]; then
  skiplist=$(sed -e 's/[[:space:]]*#.*$//' -e 's/\r$//' scripts/linux-skip.txt | sed '/^[[:space:]]*$/d')
fi
is_skipped() { [ -n "$skiplist" ] && printf '%s\n' "$skiplist" | grep -Fxq -- "$1"; }

run_one() {
  local t="$1"
  seen+=("$t")
  if is_skipped "$t"; then echo "SKIP $t (linux-skip.txt)"; skipped=$((skipped + 1)); return; fi
  ran=$((ran + 1))
  echo "== $t"
  if ! bash "$t"; then failed=$((failed + 1)); echo "FAILED: $t"; fi
}

shopt -s nullglob
tests=( core/hooks/test-*.sh core/tests/test-*.sh )
[ -z "$scope" ] && tests=( personal/hooks/test-*.sh personal/skills/*/tests/test-*.sh "${tests[@]}" )
[ -f core/skills/synthesize-memories/tests/run-tests.sh ] && tests+=( core/skills/synthesize-memories/tests/run-tests.sh )
for t in "${tests[@]}"; do run_one "$t"; done

if [ -z "$scope" ] && [ -d personal/opencode ]; then
  # Files named in linux-skip.txt are left out on Linux; the rest run in ONE bun invocation.
  bunfiles=()
  for f in personal/opencode/test/*.test.js; do
    seen+=("$f")
    if is_skipped "$f"; then echo "SKIP $f (linux-skip.txt)"; skipped=$((skipped + 1)); else bunfiles+=("./${f#personal/opencode/}"); fi
  done
  if ! command -v bun >/dev/null 2>&1; then
    echo "SKIP opencode: no bun"; skipped=$((skipped + 1))
  elif [ "${#bunfiles[@]}" -eq 0 ]; then
    # Never call `bun test` with no file arguments: it would run everything it can find.
    echo "SKIP opencode: no bun test files left to run"
  else
    ran=$((ran + 1)); echo "== bun test (personal/opencode, ${#bunfiles[@]} files)"
    # CCP_GUARD points the adapter's tests at this checkout's guard (core/hooks), not an installed plugin cache copy.
    if ! ( cd personal/opencode && CCP_GUARD="${CCP_GUARD:-$root/core/hooks/negative-result-guard.sh}" bun test "${bunfiles[@]}" ); then
      failed=$((failed + 1)); echo "FAILED: bun test"
    fi
  fi
fi

# Independent count: every test file on disk under the same roots, found by name rather than by the globs above.
roots=(); for d in ${scope:-personal core}; do [ -d "$d" ] && roots+=("$d"); done
ondisk=""
if [ "${#roots[@]}" -gt 0 ]; then
  ondisk=$(find "${roots[@]}" \( -name node_modules -o -name .git \) -prune -o -type f \
    \( -name 'test-*.sh' -o -name 'run-tests.sh' -o -name '*.test.js' \) -print | sort)
fi
seen_sorted=$(if [ "${#seen[@]}" -gt 0 ]; then printf '%s\n' "${seen[@]}" | sort; fi)
missed=$(comm -23 <(printf '%s\n' "$ondisk" | sed '/^$/d') <(printf '%s\n' "$seen_sorted" | sed '/^$/d'))
if [ -n "$missed" ]; then
  failed=$((failed + 1))
  echo "FAILED: test files on disk that the runner neither ran nor skipped:"
  printf '%s\n' "$missed" | sed 's/^/  /' | head -n 20
fi
if [ "$ran" -eq 0 ]; then
  failed=$((failed + 1)); echo "FAILED: ran 0 tests; an empty suite is not a pass"
fi

echo "ran $ran, failed $failed, skipped $skipped"
if [ "$failed" -eq 0 ]; then echo "REAL_EXIT=0"; exit 0; fi
echo "REAL_EXIT=1"; exit 1
