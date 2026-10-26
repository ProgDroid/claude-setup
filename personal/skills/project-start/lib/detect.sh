#!/usr/bin/env bash
# Stack and oracle detection. Source this file; do not execute it.
#
# Search scope: the repo root, every immediate subdirectory (never node_modules, target, build,
# or dot-dirs such as .git/.beads), and Cargo workspace members. Nothing deeper is read, except
# .github/workflows/*.y*ml and shell suites (test-*.sh / test_*.sh, two levels from the root).
# Detection FINDS commands; it never runs them. "absent" is a finding, "unknown" is a failure to look.

# --- internals (all run with cwd = the repo) -------------------------------------------------

# _det_trace <name>: when RITUAL_TRACE names a file, log one line per scan (tests count scans with it)
_det_trace() { [ -z "${RITUAL_TRACE:-}" ] || printf '%s\n' "$1" >> "$RITUAL_TRACE"; }

_det_path() { if [ "$1" = . ]; then printf '%s\n' "$2"; else printf '%s/%s\n' "$1" "$2"; fi; }

# _det_ws_array <key>: the strings of `<key> = [...]` (possibly multi-line) in the root Cargo.toml's
# [workspace] table, one per line, quotes removed.
_det_ws_array() {
  [ -f Cargo.toml ] || return 0
  tr -d '\r' < Cargo.toml \
    | awk -v k="$1" '/^\[workspace\]/{w=1;next} /^\[/{w=0} w&&$0~("^[[:space:]]*" k "[[:space:]]*="){a=1} a{print} a&&/\]/{exit}' \
    | grep -o '"[^"]*"' | tr -d '"'
}

# _det_ws_members <in|out>: workspace `members` globs, expanded to dirs holding a Cargo.toml, then
# split by `exclude`: a member is excluded when its path IS an exclude path or lies under one (a
# path prefix, never a string prefix: "crates/skip" does not exclude "crates/skipper"). Close to
# Cargo, not the same: Cargo keeps an explicitly listed (glob-free) member that `exclude` also
# covers; here it is excluded. `in` prints the members kept, `out` the members excluded.
_det_ws_members() {
  [ -f Cargo.toml ] || return 0
  local want="$1" m p x side excl
  excl="$(_det_ws_array exclude)"
  while IFS= read -r m; do
    for p in $m; do
      p="${p#./}"; p="${p%/}"
      [ -f "$p/Cargo.toml" ] || continue
      side=in
      while IFS= read -r x; do
        x="${x#./}"; x="${x%/}"
        [ -n "$x" ] || continue
        case "$p" in "$x"|"$x"/*) side=out ;; esac
      done <<<"$excl"
      if [ "$side" = "$want" ]; then printf '%s\n' "$p"; fi
    done
  done < <(_det_ws_array members)
  return 0
}

# Cargo workspace members declared in the root Cargo.toml, expanded, minus `exclude`, one per line.
_det_members() { _det_ws_members in; }

# Members the `exclude` list removes: crates of their own, scanned as candidate dirs (_det_dirs).
_det_excluded() { _det_ws_members out; }

# Candidate dirs for stack detection: ".", immediate subdirs, workspace members, and members that
# `exclude` turned back into standalone crates (they can sit two levels down). Sorted, unique.
_det_dirs() {
  local d
  { printf '.\n'
    for d in */; do
      d="${d%/}"; [ -d "$d" ] || continue
      case "$d" in node_modules|target|build) continue ;; esac
      printf '%s\n' "$d"
    done
    _det_members
    _det_excluded
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
_DET_TEST_RE='^(cargo test|cargo nextest|pytest|(python3?|py) -m pytest|(uv|poetry|pipenv) run (python3? -m )?pytest|(npm|pnpm|yarn|bun) (run )?test[A-Za-z0-9:_-]*|go test|flutter test|dart test|just test[A-Za-z0-9_-]*|make test[A-Za-z0-9_-]*|ctest|deno test|bash [^ ]*test[^ ]*\.sh)([[:space:]]|$)'
_DET_LINT_RE='^(cargo clippy|ruff|(uv|poetry) run ruff|flake8|eslint|(npm|pnpm|yarn) run lint[A-Za-z0-9:_-]*|go vet|golangci-lint|flutter analyze|dart analyze|just (lint|check)|make (lint|check))([[:space:]]|$)'

# _det_classify <cmd> -> test | lint | none
_det_classify() {
  if printf '%s' "$1" | grep -Eq "$_DET_NEVER"; then echo none
  elif printf '%s' "$1" | grep -Eq "$_DET_TEST_RE"; then echo test
  elif printf '%s' "$1" | grep -Eq "$_DET_LINT_RE"; then echo lint
  else echo none; fi
}

# _det_split: reads ONE command line on stdin and prints its segments, one per line, breaking on
# && || ; | only OUTSIDE quotes (POSIX awk: gawk and mawk alike). Shell quoting rules: inside '...'
# nothing is special; a backslash escapes the next character outside quotes and inside "...", so
# \" does not close a string and \; does not split. An unterminated quote runs to the end of the
# line: nothing after it is split off, so text inside a broken string never becomes a command.
_det_split() {
  awk -v sq="'" '{
    n = length($0); seg = ""; q = ""
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (q == sq) { seg = seg c; if (c == sq) q = ""; continue }
      if (c == "\\" && i < n) { seg = seg c substr($0, i + 1, 1); i++; continue }
      if (q == "\"") { seg = seg c; if (c == "\"") q = ""; continue }
      if (c == sq || c == "\"") { q = c; seg = seg c; continue }
      if ((c == "&" || c == "|") && substr($0, i + 1, 1) == c) { print seg; seg = ""; i++; continue }
      if (c == ";" || c == "|") { print seg; seg = ""; continue }
      seg = seg c
    }
    print seg }'
}

# _det_shell_c <cmd>: when <cmd> is `bash|sh [-opts] -c <script>` and the script is ONE word (one
# "..." or '...' string, or a bare word), print the script (\" \\ \$ \` unescaped for "...") and
# return 0. Anything else returns 1 and prints nothing.
_det_shell_c() {
  local re='^(bash|sh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[[:space:]]+(.+)$' rest t s
  [[ "$1" =~ $re ]] || return 1
  rest="${BASH_REMATCH[3]}"
  if [ "${#rest}" -ge 2 ] && [ "${rest:0:1}" = '"' ] && [ "${rest: -1}" = '"' ]; then
    t="${rest:1:${#rest}-2}"
    s="${t//\\\\/}"; s="${s//\\\"/}"
    case "$s" in *'"'*) return 1 ;; esac            # an unescaped " inside: not one word
    printf '%s' "$t" | sed -E 's/\\(["\\$`])/\1/g'; return 0
  elif [ "${#rest}" -ge 2 ] && [ "${rest:0:1}" = "'" ] && [ "${rest: -1}" = "'" ]; then
    t="${rest:1:${#rest}-2}"
    case "$t" in *"'"*) return 1 ;; esac
    printf '%s' "$t"; return 0
  fi
  case "$rest" in *[[:space:]\"\']*) return 1 ;; esac
  printf '%s' "$rest"
}

# _det_classify_line <line> <source>: classify one command line. Uses and extends the caller's
# _det_cd (the `cd` segments seen so far in this shell session) and _det_loop (the loops open in
# it); see _det_classify_stream.
_det_classify_line() {
  local seg stripped inner saved sl
  local loop_re='^((if|then|else|elif|do|!)[[:space:]]+)*(for|while|until|done)([[:space:]]|$)'
  while IFS= read -r seg; do
    seg="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    [ -n "$seg" ] || continue
    # Nothing in a for/while/until loop is reported, from its first segment to its `done`: the
    # body runs once per value, with variables the repo root does not have (`pytest "$f"` run
    # from the root is `pytest ""`). A depth, so a nested loop or a `then` in the body stays in.
    # A loop whose keyword does not lead the segment (`( for`, `{ for`, `select`) is not seen;
    # `do` is never stripped below, so its direct body still classifies as nothing (a `then`
    # nested in such a loop is the known gap). A `cd` inside a loop is not carried either.
    if [[ "$seg" =~ $loop_re ]]; then
      if [ "${BASH_REMATCH[3]}" = done ]; then
        [ "${_det_loop:-0}" -eq 0 ] || _det_loop=$((_det_loop - 1))
      else
        _det_loop=$((${_det_loop:-0} + 1))
      fi
      continue
    fi
    [ "${_det_loop:-0}" -eq 0 ] || continue
    # shell keywords that lead a command (`then pytest`, `if ! cargo test`), then VAR=value prefixes
    stripped="$(printf '%s' "$seg" | sed -E 's/^((if|then|else|elif|while|until|!)[[:space:]]+)+//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+//')"
    case "$stripped" in
      cd\ *) _det_cd="${_det_cd:+$_det_cd && }$stripped"; continue ;;
    esac
    if inner="$(_det_shell_c "$stripped")"; then
      # the script runs in a child shell: it sees our cd, its own cd does not come back out
      saved="$_det_cd"; sl="${_det_loop:-0}"; _det_classify_line "$inner" "$2"; _det_cd="$saved"; _det_loop="$sl"; continue
    fi
    case "$(_det_classify "$stripped")" in
      test) _det_add test . "${_det_cd:+$_det_cd && }$stripped" "$2" ;;
      lint) _det_add lint . "${_det_cd:+$_det_cd && }$stripped" "$2" ;;
    esac
  done < <(printf '%s\n' "$1" | _det_split)
}

# _det_classify_stream <source>: reads command LINES on stdin; an EMPTY line ends a shell session.
# Each line is split into segments on && || ; | outside quotes (_det_split); every segment is
# trimmed, stripped of leading shell keywords and VAR=value assignments, unwrapped when it is
# `bash -c "<script>"`, and classified on its own (so `npm ci && npm test` yields npm test). Every
# `cd <dir>` segment earlier in the session is kept as a prefix, so the reported command is
# runnable as written from the repo root. Inside a for/while/until loop nothing is classified.
_det_classify_stream() {
  local line _det_cd="" _det_loop=0
  while IFS= read -r line; do
    if [ -z "$line" ]; then _det_cd=""; _det_loop=0; continue; fi
    _det_classify_line "$line" "$1"
  done
}

# README.md: ONLY lines inside fenced code blocks that invoke a known runner. Never prose. Each
# line is its own session (an empty line after every one), so a `cd` never carries to the next.
_det_readme() {
  [ -f README.md ] || return 0
  tr -d '\r' < README.md | awk '/^[[:space:]]*(```|~~~)/{f=!f;next} f{print; print ""}' \
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
      if [[ "$line" =~ ^@?(test[A-Za-z0-9_-]*|lint|check|clippy)([[:space:]]+[^:]*)?:($|[^=]) ]]; then
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
      if [[ "$line" =~ ^(test[A-Za-z0-9_-]*|check|lint)[[:space:]]*:($|[^=]) ]]; then
        name="${BASH_REMATCH[1]}"
        case "$name" in test*) _det_add test . "make $name" "$f" ;; *) _det_add lint . "make $name" "$f" ;; esac
      fi
    done < "$f"
    break   # first existing name only (case-insensitive filesystems list one file twice)
  done
  return 0
}

# Test/lint entries from CI workflows. Single-line `run: <cmd>` is taken as is; for a block
# scalar (`run: |` / `run: >`) EVERY non-blank line indented deeper than the `run` key is read.
# Each line is classified by known-runner invocation (_det_classify_stream), not by substring.
# Every `run:` starts a new shell session (an empty line), as each CI step is a fresh shell; the
# lines of one block share it, so a `cd` carries down the block. A line ending in an odd number of
# backslashes continues onto the next line of the same step and is joined to it; a blank line in
# the block ends the continuation (the first awk marks it with a \001 sentinel, which the join awk
# drops without ending the session, so a `cd` still carries past it). YAML outer quotes are taken
# off a single-line `run:` value only: a block line is shell text, and its quotes are the shell's.
_det_ci() {
  local f sent
  sent="$(printf '\001')"
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    tr -d '\r' < "$f" | awk -v sq="'" -v sent="$sent" '
      function ind(s) { match(s, /^ */); return RLENGTH }
      blk && NF && ind($0) > kc { l=$0; sub(/^ +/, "", l); print l; next }
      blk && !NF { print sent; next }
      blk && NF { blk=0 }
      /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/ {
        print ""
        v=$0; sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", v)
        kc=index($0, "run:") - 1
        if (v ~ /^[|>][-+]?[[:space:]]*$/) { blk=1; next }
        blk=0; sub(/[[:space:]]+$/, "", v)
        if (length(v) >= 2 && (v ~ /^".*"$/ || (substr(v, 1, 1) == sq && substr(v, length(v), 1) == sq))) v = substr(v, 2, length(v) - 2)
        print v; next }' \
    | sed -e 's/[[:space:]]*$//' \
    | awk -v sent="$sent" '
      $0 == sent { if (p != "") print p; p = ""; next }
      $0 == "" { if (p != "") print p; p = ""; print ""; next }
      { s = (p == "" ? $0 : p " " $0) }
      match(s, /\\+$/) && RLENGTH % 2 == 1 { s = substr(s, 1, length(s) - 1); sub(/[[:space:]]+$/, "", s); p = s; next }
      { p = ""; print s }
      END { if (p != "") print p }' \
    | _det_classify_stream "$f"
  done
}

# _det_rust_has_tests <dir> <Cargo.toml>: a #[test]/#[tokio::test]/#[cfg(test)] in a .rs file, or
# any file under a tests/ dir. A workspace root searches its whole tree (members live below it);
# a plain crate searches only its src/ and tests/. target/ and node_modules/ are never read.
_det_rust_has_tests() {
  local d="$1" toml="$2" re='#\[([A-Za-z0-9_]+::)*test(\]|\()|#\[cfg\(test\)\]|#\[(rstest|test_case)'
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
  _det_trace oracle_json
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

# stack_json <repo> [oracle-status]: {"stacks":[{lang,dir}],"includes":[...]} (core skill names).
# core:testing-standards is included when the oracle's status is present. A caller that already knows that status, or that
# needs only the languages ("-"), passes it, and the oracle is not scanned again.
stack_json() {
  local repo="$1" lines="" d l p status
  _det_trace stack_json
  if [ $# -ge 2 ]; then status="$2"; else status="$(oracle_json "$repo" | jq -r .status | tr -d '\r')"; fi
  # An unscannable repo must not look like "no stacks": fail loudly (exit 2).
  { [ -d "$repo" ] && [ -r "$repo" ] && [ -x "$repo" ]; } || die "cannot scan: $repo"
  lines="$(cd "$repo" || exit 1; while IFS= read -r d; do
        while IFS= read -r l; do
          [ -n "$l" ] || continue
          printf 'stack\t%s\t%s\n' "$d" "$l"
          case "$l" in
            rust) printf 'include\tcore:rust-standards\n' ;;
            python) printf 'include\tcore:python-standards\n' ;;
            go) printf 'include\tcore:golang-standards\n' ;;
            node)
              p="$(_det_path "$d" package.json)"
              if jq -e '((.dependencies // {}) + (.devDependencies // {})) | has("react")' "$p" >/dev/null 2>&1; then
                printf 'include\tcore:react-standards\n'; fi ;;
          esac
        done < <(_det_langs "$d")
        # every manifest the scan tried to parse: a failure is reported, never invisible
        p="$(_det_path "$d" package.json)"
        if [ -f "$p" ] && ! jq -e . "$p" >/dev/null 2>&1; then printf 'unparsed\t%s\n' "$p"; fi
      done < <(_det_dirs))" || die "cannot scan: $repo"
  [ "$status" = present ] && lines="$lines"$'\n'"include	core:testing-standards"
  printf '%s\n' "$lines" | jq -Rnc '
    [inputs | select(length > 0) | split("\t")] as $r
    | ([$r[] | select(.[0] == "unparsed") | .[1]] | unique) as $u
    | {stacks: ([$r[] | select(.[0] == "stack") | {lang: .[2], dir: .[1]}] | unique | sort_by([.dir, .lang])),
       includes: ([$r[] | select(.[0] == "include") | .[1]] | unique)}
      + (if ($u | length) > 0 then {unparsed: $u} else {} end)'
}
