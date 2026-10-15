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

# Test/lint entries from CI workflows. Single-line `run: <cmd>` is taken as is; for a block
# scalar (`run: |` / `run: >`) only the FIRST non-blank line of the block is considered.
# Kept only when the line matches (case-insensitive) test|check|clippy|lint|pytest|ruff|vet|analyze;
# it is a test command if it also matches test|pytest, otherwise lint.
_det_ci() {
  local f cmd
  for f in .github/workflows/*.yml .github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    tr -d '\r' < "$f" | awk '
      /^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/ {
        v=$0; sub(/^[[:space:]]*(-[[:space:]]+)?run:[[:space:]]*/, "", v)
        if (v ~ /^[|>][-+]?[[:space:]]*$/) { blk=1; next }
        blk=0; print v; next }
      blk && NF { sub(/^[[:space:]]+/, ""); print; blk=0 }' \
    | sed -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/" \
    | grep -Ei 'test|check|clippy|lint|pytest|ruff|vet|analyze' | while IFS= read -r cmd; do
        if printf '%s' "$cmd" | grep -Eiq 'test|pytest'; then _det_add test . "$cmd" "$f"
        else _det_add lint . "$cmd" "$f"; fi
      done
  done
}

# Entries for one directory $1 (cwd = repo). $2 = "member" if it is a Cargo workspace member.
_det_dir_entries() {
  local d="$1" member="${2:-}" p t
  p="$(_det_path "$d" Cargo.toml)"
  if [ -f "$p" ] && [ -z "$member" ]; then
    _det_add test "$d" "cargo test" "$p"
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
    ts="$(jq -r '.scripts.test // empty' "$p" 2>/dev/null)"
    if [ -n "$ts" ] && ! printf '%s' "$ts" | grep -q 'no test specified'; then _det_add test "$d" "npm test" "$p"; fi
    ls="$(jq -r '.scripts.lint // empty' "$p" 2>/dev/null)"
    [ -n "$ls" ] && _det_add lint "$d" "npm run lint" "$p"
  fi
  # go: only when test files exist
  p="$(_det_path "$d" go.mod)"
  if [ -f "$p" ]; then
    _det_add lint "$d" "go vet ./..." "$p"
    if [ -n "$(find "$d" -maxdepth 4 -name '*_test.go' -print -quit 2>/dev/null)" ]; then _det_add test "$d" "go test ./..." "$p"; fi
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
  entries="$( { _det_ci; _det_shell
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
    | {status: (if ($t | length) > 0 then "present" else "absent" end), test: $t, lint: $l}'
}

# stack_json <repo>: {"stacks":[{lang,dir}],"includes":[...]}
stack_json() {
  local repo="$1" lines="" d l inc="" status
  status="$(oracle_json "$repo" | jq -r .status)"
  if [ -d "$repo" ] && [ -r "$repo" ]; then
    lines="$(cd "$repo" && while IFS= read -r d; do
        while IFS= read -r l; do
          [ -n "$l" ] || continue
          printf '%s\t%s\n' "$d" "$l"
          case "$l" in
            rust) echo "include	rust.md" ;;
            python) echo "include	python.md" ;;
            go) echo "include	golang.md" ;;
            node) if jq -e '((.dependencies // {}) + (.devDependencies // {})) | has("react")' "$(_det_path "$d" package.json)" >/dev/null 2>&1; then
                    echo "include	react.md"; fi ;;
          esac
        done < <(_det_langs "$d")
      done < <(_det_dirs))"
  fi
  [ "$status" = present ] && lines="$lines"$'\n'"include	testing.md"
  printf '%s\n' "$lines" | jq -Rnc '
    [inputs | select(length > 0) | split("\t")] as $r
    | {stacks: ([$r[] | select(.[0] != "include") | {lang: .[1], dir: .[0]}] | unique | sort_by([.dir, .lang])),
       includes: ([$r[] | select(.[0] == "include") | .[1]] | unique)}'
}
