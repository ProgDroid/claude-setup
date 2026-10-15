#!/usr/bin/env bash
# Stack and oracle detection. Source this file; do not execute it.
#
# Search scope: the repo root, every immediate subdirectory (never node_modules, target, build,
# or dot-dirs such as .git/.beads), and Cargo workspace members. Nothing deeper is read, except
# .github/workflows/*.y*ml and shell suites (test-*.sh / test_*.sh, two levels from the root).
# Detection FINDS commands; it never runs them. "absent" is a finding, "unknown" is a failure to look.

# --- internals (all run with cwd = the repo) -------------------------------------------------

_det_path() { if [ "$1" = . ]; then printf '%s\n' "$2"; else printf '%s/%s\n' "$1" "$2"; fi; }

# Cargo workspace members declared in the root Cargo.toml, expanded, one per line.
_det_members() {
  [ -f Cargo.toml ] || return 0
  local m p
  awk '/^\[workspace\]/{w=1;next} /^\[/{w=0} w&&/^[[:space:]]*members[[:space:]]*=/{a=1} a{print} a&&/\]/{exit}' Cargo.toml \
    | tr -d '\r' | grep -o '"[^"]*"' | tr -d '"' | while IFS= read -r m; do
      for p in $m; do
        p="${p#./}"; p="${p%/}"
        [ -f "$p/Cargo.toml" ] && printf '%s\n' "$p"
      done
    done
}

# Candidate dirs for stack detection: ".", immediate subdirs, workspace members. Sorted, unique.
_det_dirs() {
  local d
  { printf '.\n'
    for d in */; do
      d="${d%/}"; [ -d "$d" ] || continue
      case "$d" in node_modules|target|build) continue ;; esac
      printf '%s\n' "$d"
    done
    _det_members
  } | LC_ALL=C sort -u
}

# Languages present in dir $1, one per line.
_det_langs() {
  local d="$1"
  [ -f "$(_det_path "$d" Cargo.toml)" ] && echo rust
  { [ -f "$(_det_path "$d" pyproject.toml)" ] || [ -f "$(_det_path "$d" requirements.txt)" ] \
    || [ -f "$(_det_path "$d" setup.py)" ] || [ -f "$(_det_path "$d" pytest.ini)" ]; } && echo python
  [ -f "$(_det_path "$d" pubspec.yaml)" ] && echo flutter
  [ -f "$(_det_path "$d" go.mod)" ] && echo go
  [ -f "$(_det_path "$d" package.json)" ] && echo node
  { compgen -G "$(_det_path "$d" '*.rockspec')" >/dev/null || [ -f "$(_det_path "$d" .luarc.json)" ] \
    || [ -f "$(_det_path "$d" .busted)" ] || [ -f "$(_det_path "$d" init.lua)" ]; } && echo lua
  return 0
}

# TSV entry: kind \t dir \t cmd \t source  (tabs/CR inside fields flattened)
_det_add() {
  local kind="$1" dir="$2" cmd="$3" src="$4"
  cmd="${cmd//$'\t'/ }"; cmd="${cmd//$'\r'/}"
  printf '%s\t%s\t%s\t%s\n' "$kind" "$dir" "$cmd" "$src"
}

# The ONE runner list. A command line counts only if it STARTS with a known runner invocation
# (never by substring), and never if it starts with an install/echo-style command.
_DET_NEVER='^(pip3?|apt|apt-get|brew|echo|npm (install|ci|i)|cargo install|pnpm install|yarn install|python3? -m pip)([[:space:]]|$)'
_DET_TEST_RE='^(cargo test|cargo nextest|pytest|python3? -m pytest|py -m pytest|npm test|npm run test|pnpm test|yarn test|go test|flutter test|dart test|just test[A-Za-z0-9_-]*|make test|ctest|deno test|bun test|bash [^ ]*test[^ ]*\.sh)([[:space:]]|$)'
_DET_LINT_RE='^(cargo clippy|ruff|flake8|eslint|npm run lint|go vet|golangci-lint|flutter analyze|dart analyze|just (lint|check)|make (lint|check))([[:space:]]|$)'

# _det_classify <cmd> -> test | lint | none
_det_classify() {
  if printf '%s' "$1" | grep -Eq "$_DET_NEVER"; then echo none
  elif printf '%s' "$1" | grep -Eq "$_DET_TEST_RE"; then echo test
  elif printf '%s' "$1" | grep -Eq "$_DET_LINT_RE"; then echo lint
  else echo none; fi
}

# _det_classify_stream <source>: reads commands on stdin, adds root-dir entries for runner matches.
_det_classify_stream() {
  local cmd
  while IFS= read -r cmd; do
    case "$(_det_classify "$cmd")" in
      test) _det_add test . "$cmd" "$1" ;;
      lint) _det_add lint . "$cmd" "$1" ;;
    esac
  done
}

# README.md: ONLY lines inside fenced code blocks that invoke a known runner. Never prose.
_det_readme() {
  [ -f README.md ] || return 0
  tr -d '\r' < README.md | awk '/^[[:space:]]*(```|~~~)/{f=!f;next} f{print}' \
    | sed -e 's/^[[:space:]]*\$[[:space:]]*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
    | _det_classify_stream README.md
}

# justfile/Makefile recipes at the root. `name := value` assignments never count.
_det_just_make() {
  local f line name
  for f in justfile Justfile .justfile; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      line="${line%$'\r'}"
      if [[ "$line" =~ ^(test[A-Za-z0-9_-]*|lint|check|clippy)([[:space:]][^:=]*)?:($|[^=]) ]]; then
        name="${BASH_REMATCH[1]}"
        case "$name" in test*) _det_add test . "just $name" "$f" ;; *) _det_add lint . "just $name" "$f" ;; esac
      fi
    done < "$f"
    break   # first existing name only (case-insensitive filesystems list one file twice)
  done
  for f in Makefile makefile GNUmakefile; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
      line="${line%$'\r'}"
      if [[ "$line" =~ ^(test|check|lint)[[:space:]]*:($|[^=]) ]]; then
        name="${BASH_REMATCH[1]}"
        if [ "$name" = test ]; then _det_add test . "make $name" "$f"; else _det_add lint . "make $name" "$f"; fi
      fi
    done < "$f"
    break   # first existing name only (case-insensitive filesystems list one file twice)
  done
  return 0
}

# Test/lint entries from CI workflows. Single-line `run: <cmd>` is taken as is; for a block
# scalar (`run: |` / `run: >`) only the FIRST non-blank line of the block is considered.
# Each line is classified by known-runner invocation (_det_classify), not by substring.
_det_ci() {
  local f
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    tr -d '\r' < "$f" | awk '
      /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", v)
        if (v ~ /^[|>][-+]?[[:space:]]*$/) { blk=1; next }
        blk=0; print v; next }
      blk && NF { sub(/^[[:space:]]+/, ""); print; blk=0 }' \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" \
    | _det_classify_stream "$f"
  done
}

# _det_rust_has_tests <dir> <Cargo.toml>: a #[test]/#[tokio::test]/#[cfg(test)] in a .rs file, or
# any file under a tests/ dir. A workspace root searches its whole tree (members live below it);
# a plain crate searches only its src/ and tests/. target/ and node_modules/ are never read.
_det_rust_has_tests() {
  local d="$1" toml="$2" re='#\[(tokio::)?test(\]|\()|#\[cfg\(test\)\]'
  if ! grep -Eq '^\[workspace\]' "$toml"; then
    grep -rEqs --include='*.rs' "$re" "$(_det_path "$d" src)" "$(_det_path "$d" tests)" 2>/dev/null && return 0
    [ -n "$(find "$(_det_path "$d" tests)" -type f -print -quit 2>/dev/null)" ] && return 0
    return 1
  fi
  grep -rEqs --include='*.rs' --exclude-dir=target --exclude-dir=node_modules "$re" "$d" 2>/dev/null && return 0
  [ -n "$(find "$d" \( -name target -o -name node_modules \) -prune -o -type f -path '*/tests/*' -print -quit 2>/dev/null)" ] && return 0
  return 1
}

# Entries for one directory $1 (cwd = repo). $2 = "member" if it is a Cargo workspace member.
_det_dir_entries() {
  local d="$1" member="${2:-}" p t
  p="$(_det_path "$d" Cargo.toml)"
  if [ -f "$p" ] && [ -z "$member" ]; then
    if _det_rust_has_tests "$d" "$p"; then _det_add test "$d" "cargo test" "$p"; fi
    if grep -Eq '^\[(workspace\.)?lints\.clippy\]' "$p"; then
      _det_add lint "$d" "cargo clippy --all-targets -- -D warnings" "$p"
    fi
  fi
  # python: one test entry per dir, first source wins
  local pysrc=""
  if [ -f "$(_det_path "$d" pytest.ini)" ]; then pysrc="$(_det_path "$d" pytest.ini)"
  elif [ -f "$(_det_path "$d" pyproject.toml)" ] && grep -Eq '^\[tool\.pytest' "$(_det_path "$d" pyproject.toml)"; then
    pysrc="$(_det_path "$d" pyproject.toml)"
  else
    for t in tests test; do
      p="$(_det_path "$d" "$t")"
      if [ -d "$p" ] && [ -n "$(find "$p" -maxdepth 2 \( -name 'test_*.py' -o -name '*_test.py' \) -print -quit 2>/dev/null)" ]; then
        pysrc="$p/"; break
      fi
    done
  fi
  [ -n "$pysrc" ] && _det_add test "$d" "pytest" "$pysrc"
  p="$(_det_path "$d" pyproject.toml)"
  if { [ -f "$p" ] && grep -Eq '^\[tool\.ruff' "$p"; }; then _det_add lint "$d" "ruff check" "$p"
  elif [ -f "$(_det_path "$d" ruff.toml)" ]; then _det_add lint "$d" "ruff check" "$(_det_path "$d" ruff.toml)"; fi
  # node
  p="$(_det_path "$d" package.json)"
  if [ -f "$p" ]; then
    local ts ls
    if ! jq -e . "$p" >/dev/null 2>&1; then
      _det_add unparsed "$d" "" "$p"      # UNKNOWN, not absent: could not read this manifest
    else
      ts="$(jq -r '.scripts.test // empty' "$p" 2>/dev/null)"
      if [ -n "$ts" ] && ! printf '%s' "$ts" | grep -q 'no test specified'; then _det_add test "$d" "npm test" "$p"; fi
      ls="$(jq -r '.scripts.lint // empty' "$p" 2>/dev/null)"
      [ -n "$ls" ] && _det_add lint "$d" "npm run lint" "$p"
    fi
  fi
  # go: only when test files exist
  p="$(_det_path "$d" go.mod)"
  if [ -f "$p" ]; then
    _det_add lint "$d" "go vet ./..." "$p"
    if [ -n "$(find "$d" -maxdepth 4 \( -name node_modules -o -name vendor -o -name target -o -name .git \) -prune -o -name '*_test.go' -print -quit 2>/dev/null)" ]; then _det_add test "$d" "go test ./..." "$p"; fi
  fi
  # flutter: only when test/ holds *_test.dart
  p="$(_det_path "$d" pubspec.yaml)"
  if [ -f "$p" ]; then
    _det_add lint "$d" "flutter analyze" "$p"
    t="$(_det_path "$d" test)"
    if [ -d "$t" ] && [ -n "$(find "$t" -name '*_test.dart' -print -quit 2>/dev/null)" ]; then _det_add test "$d" "flutter test" "$t/"; fi
  fi
  return 0
}

# Shell suites: test-*.sh / test_*.sh at the root or one directory down.
_det_shell() {
  local f
  find . -maxdepth 2 \( -name node_modules -o -name target -o -name build -o \( -name '.*' ! -name . \) \) -prune \
    -o -type f \( -name 'test-*.sh' -o -name 'test_*.sh' \) -print 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
      f="${f#./}"; _det_add test . "bash $f" "$f"
    done
}

# oracle_json <repo>: {"status","test","lint"}. Never runs a found command.
oracle_json() {
  local repo="$1" entries members d m skip
  if [ ! -d "$repo" ] || [ ! -r "$repo" ] || ! cd "$repo" 2>/dev/null; then
    printf '%s\n' '{"status":"unknown","test":[],"lint":[]}'; return 0
  fi
  members="$(_det_members)"
  entries="$( { _det_ci; _det_shell; _det_just_make; _det_readme
    while IFS= read -r d; do
      skip=""
      while IFS= read -r m; do [ -n "$m" ] && [ "$m" = "$d" ] && skip=member; done <<<"$members"
      _det_dir_entries "$d" "$skip"
    done < <(_det_dirs)
  } )"
  printf '%s' "$entries" | jq -Rnc '
    [inputs | select(length > 0) | split("\t") | {kind: .[0], e: {cmd: .[2], dir: .[1], source: .[3]}}]
    | unique
    | (map(select(.kind == "test") | .e) | sort_by([.dir, .cmd, .source])) as $t
    | (map(select(.kind == "lint") | .e) | sort_by([.dir, .cmd, .source])) as $l
    | (map(select(.kind == "unparsed") | .e.source) | unique) as $u
    | {status: (if ($t | length) > 0 then "present" elif ($u | length) > 0 then "unknown" else "absent" end),
       test: $t, lint: $l}
      + (if ($u | length) > 0 then {detail: ("could not parse: " + ($u | join(", ")))} else {} end)'
}

# stack_json <repo>: {"stacks":[{lang,dir}],"includes":[...]}
stack_json() {
  local repo="$1" lines="" d l p status
  status="$(oracle_json "$repo" | jq -r .status)"
  # An unscannable repo must not look like "no stacks": fail loudly (exit 2).
  { [ -d "$repo" ] && [ -r "$repo" ] && [ -x "$repo" ]; } || die "cannot scan: $repo"
  lines="$(cd "$repo" || exit 1; while IFS= read -r d; do
        while IFS= read -r l; do
          [ -n "$l" ] || continue
          printf 'stack\t%s\t%s\n' "$d" "$l"
          case "$l" in
            rust) printf 'include\trust.md\n' ;;
            python) printf 'include\tpython.md\n' ;;
            go) printf 'include\tgolang.md\n' ;;
            node)
              p="$(_det_path "$d" package.json)"
              if ! jq -e . "$p" >/dev/null 2>&1; then printf 'unparsed\t%s\n' "$p"   # react include undecidable
              elif jq -e '((.dependencies // {}) + (.devDependencies // {})) | has("react")' "$p" >/dev/null 2>&1; then
                printf 'include\treact.md\n'; fi ;;
          esac
        done < <(_det_langs "$d")
      done < <(_det_dirs))" || die "cannot scan: $repo"
  [ "$status" = present ] && lines="$lines"$'\n'"include	testing.md"
  printf '%s\n' "$lines" | jq -Rnc '
    [inputs | select(length > 0) | split("\t")] as $r
    | ([$r[] | select(.[0] == "unparsed") | .[1]] | unique) as $u
    | {stacks: ([$r[] | select(.[0] == "stack") | {lang: .[2], dir: .[1]}] | unique | sort_by([.dir, .lang])),
       includes: ([$r[] | select(.[0] == "include") | .[1]] | unique)}
      + (if ($u | length) > 0 then {unparsed: $u} else {} end)'
}
