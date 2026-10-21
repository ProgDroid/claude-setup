#!/usr/bin/env bash
# Minimal assertion helpers. No external test framework is installed.

TESTS_RUN=0
TESTS_FAILED=0

_pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '    ok   %s\n' "$1"; }
_fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '    FAIL %s\n' "$1"
  shift
  for line in "$@"; do printf '         %s\n' "$line"; done
}

assert_contains() { # haystack needle label
  case "$1" in
    *"$2"*) _pass "$3" ;;
    *) _fail "$3" "expected to contain: $2" "actual: $(printf '%s' "$1" | head -c 300)" ;;
  esac
}

assert_not_contains() { # haystack needle label
  case "$1" in
    *"$2"*) _fail "$3" "expected NOT to contain: $2" ;;
    *) _pass "$3" ;;
  esac
}

assert_eq() { # actual expected label
  if [ "$1" = "$2" ]; then _pass "$3"
  else _fail "$3" "expected: $2" "actual:   $1"; fi
}

# Creates a memory file with the standard frontmatter shape.
# usage: make_memory <dir> <slug> <type> <description> [body]
make_memory() {
  mkdir -p "$1"
  {
    printf -- '---\n'
    printf 'name: %s\n' "$2"
    printf 'description: %s\n' "$4"
    printf 'metadata:\n'
    printf '  type: %s\n' "$3"
    printf -- '---\n\n'
    printf '%s\n' "${5:-Body text.}"
  } > "$1/$2.md"
}
