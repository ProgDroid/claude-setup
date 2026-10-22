#!/usr/bin/env bash
# lib-key.sh - sourced library. The rule that turns a project root into the directory
# name Claude Code uses under ~/.claude/projects exists here (core_memory_keys) and as a twin in personal/hooks/lib-memory.sh (memory_key), kept equal by core/tests/test-key-parity.sh.
#
# Rule: backslashes become '/', a Git Bash drive form '/x/rest' (SINGLE-letter first
# segment only) or 'x:/rest' becomes 'X:/rest', then every character that is not
# [A-Za-z0-9] becomes '-'.  G:/Work/a b -> G--Work-a-b ;  /home/u/r -> -home-u-r.
# The '/x/rest' form is rewritten ONLY under Git Bash / MSYS / Cygwin (uname -s MINGW*|MSYS*|CYGWIN*),
# where it undoes the shell's drive mapping. On Linux '/a/repo' is a real path and keys as '-a-repo'.
#
# core_memory_keys    paths on stdin, one per line -> one key per line, in ONE process
#                     (callers with thousands of paths must not fork per path). One path per
#                     line BY DESIGN: a newline here separates paths, it is never part of one.
# core_memory_key P   one path -> its key; returns 1 (prints nothing) on empty input. P is ONE path,
#                     so an embedded newline is an ordinary non-alphanumeric character and keys to '-'.

core_memory_keys() {
  local msys=0
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) msys=1 ;; esac
  LC_ALL=C awk -v msys="$msys" '
    {
      p = $0
      gsub(/[\\]/, "/", p)
      if (msys == 1 && match(p, /^\/[A-Za-z](\/|$)/)) {
        rest = substr(p, 3); if (rest == "") rest = "/"
        p = toupper(substr(p, 2, 1)) ":" rest
      } else if (match(p, /^[A-Za-z]:(\/|$)/)) {
        rest = substr(p, 3); if (rest == "") rest = "/"
        p = toupper(substr(p, 1, 1)) ":" rest
      }
      gsub(/[^A-Za-z0-9]/, "-", p)
      print p
    }'
}

core_memory_key() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  p="${p//$'\n'/-}"
  printf '%s\n' "$p" | core_memory_keys
}
