#!/usr/bin/env bash
# Shared test harness. Source it. Provides ok/bad/finish, mkrepo, stub_path, path_without.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
RITUAL="$SKILL_DIR/ritual.sh"
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
finish() {
  echo "$(basename "$0"): $pass PASS, $fail FAIL"
  [ $((pass + fail)) -gt 0 ] || { echo "no assertions ran"; exit 1; }
  [ "$fail" -eq 0 ]; exit $?
}
command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

# mkrepo [name] -> prints path of a new repo with one commit, under "$TMPROOT/ritual fixtures/"
mkrepo() {
  local name="${1:-repo}" d n=1
  d="$TMPROOT/ritual fixtures/$name"
  while [ -e "$d" ]; do n=$((n + 1)); d="$TMPROOT/ritual fixtures/$name-$n"; done
  mkdir -p "$d"
  git -C "$d" init -q -b main >/dev/null 2>&1 || git -C "$d" init -q
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name Test
  git -C "$d" config commit.gpgsign false
  git -C "$d" config core.autocrlf false
  echo seed > "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -q -m seed
  printf '%s\n' "$d"
}

# stub_path <dir>: prepend dir to PATH. Call inside a subshell or restore PATH afterwards.
stub_path() { PATH="$1:$PATH"; export PATH; }

# path_without <tool>: print PATH with every directory containing <tool> (or <tool>.exe) removed.
# Use: PATH="$(path_without bd)" cmd.   CAVEAT: if the tool shares a directory with bash/git/jq
# (e.g. /usr/bin), those vanish too; the helper then prints the reduced PATH anyway.
path_without() {
  local tool="$1" d rest out="" first=1
  set -f
  rest="$PATH:"
  while [ -n "$rest" ]; do
    d="${rest%%:*}"; rest="${rest#*:}"
    if [ -n "$d" ] && { [ -x "$d/$tool" ] || [ -x "$d/$tool.exe" ]; }; then continue; fi
    if [ "$first" = 1 ]; then out="$d"; first=0; else out="$out:$d"; fi
  done
  set +f
  printf '%s\n' "$out"
}

# sealed_bin <dir> <tool>...: make <dir> hold a wrapper for each <tool>, resolved from the current
# PATH, and print <dir>. A PATH of just that directory reaches exactly those tools. Use it where
# path_without would be a trap: on GitHub's ubuntu-latest gh sits in /usr/bin with bash and
# coreutils, so dropping gh's directory drops bash. Run the script under test by absolute path
# (ABS_BASH), since bash itself is not on a sealed PATH. Fails (and prints nothing) when a tool is
# not found, so a missing tool is an error here rather than a silent hole in the test.
ABS_BASH="$(command -v bash)"
sealed_bin() {
  local dir="$1" t p; shift
  mkdir -p "$dir"
  for t in "$@"; do
    p="$(command -v "$t")" && [ -n "$p" ] && [ -x "$p" ] || { echo "sealed_bin: no $t on PATH" >&2; return 1; }
    printf '#!%s\nexec "%s" "$@"\n' "$ABS_BASH" "$p" > "$dir/$t"
    chmod +x "$dir/$t"
  done
  printf '%s\n' "$dir"
}
