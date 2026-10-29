#!/usr/bin/env bash
# Fixture builders shared by differential.sh and bench.sh. Source it after tests/lib.sh (or
# beads-fixture.sh) and after make_tool_stubs, which fx_state's ritual runs need.
#   fx_build <name> <dir>               a committed repo of that shape (names: FX_NAMES)
#   fx_build_extra <src-repo> <dir>     `git archive HEAD` of <src-repo> as a one-commit repo
#   fx_state <state> <ritual.sh> <repo> put the committed repo into a ritual state (FX_STATES)
# Dates are fixed, so two builds of one fixture give the same commits.
FX_NAMES="one-crate workspace python node-react node-plain go flutter ci-heavy"
FX_STATES="fresh rerun declined unreadable-ledger"
FX_DATE='2026-01-01T00:00:00 +0000'

_fx_w() { mkdir -p "$(dirname "$1")"; printf '%s\n' "${2:-x}" > "$1"; }   # _fx_w <path> [content]

_fx_init() {
  rm -rf "$1"; mkdir -p "$1"
  git -C "$1" init -q -b main >/dev/null 2>&1 || git -C "$1" init -q
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name Test
  git -C "$1" config commit.gpgsign false
  git -C "$1" config core.autocrlf false
}
_fx_commit() {
  git -C "$1" add -A >/dev/null 2>&1
  GIT_AUTHOR_DATE="$FX_DATE" GIT_COMMITTER_DATE="$FX_DATE" git -C "$1" commit -q -m seed
}

fx_build() {
  local n="$1" d="$2"
  _fx_init "$d"
  case "$n" in
    one-crate)
      _fx_w "$d/Cargo.toml" '[package]
name = "demo"
version = "0.1.0"
edition = "2021"'
      _fx_w "$d/src/lib.rs" '#[test]
fn it_works() {}'
      _fx_w "$d/README.md" '# demo'
      _fx_w "$d/.github/workflows/ci.yml" 'on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: cargo test' ;;
    workspace)   # CRLF root manifest, nested members, an exclude, a lints table
      printf '[workspace]\r\nmembers = [\r\n  "crates/*",\r\n  "tools/cli",\r\n]\r\nexclude = ["crates/skip"]\r\n[workspace.lints.clippy]\r\npedantic = "warn"\r\n' > "$d/Cargo.toml"
      local c
      for c in crates/a crates/b crates/skip tools/cli; do
        _fx_w "$d/$c/Cargo.toml" '[package]
name = "m"
version = "0.1.0"'
        _fx_w "$d/$c/src/lib.rs" '#[test]
fn t() {}'
      done
      _fx_w "$d/crates/a/inner/Cargo.toml" '[package]'
      _fx_w "$d/crates/a/tests/it.rs" 'fn main() {}' ;;
    python)
      _fx_w "$d/pyproject.toml" '[project]
name = "demo"
[tool.ruff]
line-length = 100
[tool.pytest.ini_options]
testpaths = ["tests"]'
      _fx_w "$d/tests/test_x.py" 'def test_a(): pass'
      _fx_w "$d/README.md" '# demo

```sh
ruff check .
pytest -q
```' ;;
    node-react)
      _fx_w "$d/package.json" '{"name":"app","dependencies":{"react":"^18.0.0","react-dom":"^18.0.0"},"scripts":{"test":"jest","lint":"eslint ."}}'
      _fx_w "$d/src/App.jsx" 'export default function App() { return null }'
      _fx_w "$d/README.md" '# app' ;;
    node-plain)
      _fx_w "$d/package.json" '{"name":"lib","scripts":{"test":"node --test"}}'
      _fx_w "$d/index.js" 'module.exports = 1' ;;
    go)
      _fx_w "$d/go.mod" 'module example.com/m'
      _fx_w "$d/main.go" 'package main
func main() {}'
      _fx_w "$d/main_test.go" 'package main
import "testing"
func TestX(t *testing.T) {}' ;;
    flutter)
      _fx_w "$d/pubspec.yaml" 'name: app
dependencies:
  flutter:
    sdk: flutter'
      _fx_w "$d/lib/main.dart" 'void main() {}'
      _fx_w "$d/test/widget_test.dart" 'void main() {}' ;;
    ci-heavy)   # CI and README lines from test-detect.sh's cases: quoting, bash -c, continuations, loops, cd
      _fx_w "$d/.github/workflows/ci.yml" 'steps:
  - uses: actions/checkout@v4
  - run: pip install pytest
  - run: cd x && cargo test
  - run: RUST_LOG=1 cargo test
  - run: npm ci && npm test
  - run: make build; go test ./... | tee out.txt
  - run: pytest -k "a|b"
  - run: pytest -k '"'x;y'"'
  - run: echo "x; cargo test
  - run: if [ -f Cargo.toml ]; then cargo test; else go test ./...; fi
  - run: bash -c "cargo test"
  - run: |
      cargo test \
        --all
  - run: for f in tests/*.py; do pytest "$f"; done
  - run: ( for p in a b; do cargo test -p $p; done )
  - run: |
      cd sub
      cargo clippy --all-targets
  - run: golangci-lint run
  - run: go vet ./...
  - run: cargo test -- '"'a[1]*'"'
  - name: t
    run: |
      npm ci
      npm test
  - run: echo after'
      printf 'steps:\r\n  - run: cargo clippy --all-targets\r\n  - run: |\r\n      pytest -q\r\n      echo done\r\n' > "$d/.github/workflows/crlf.yaml"
      _fx_w "$d/README.md" '# Proj

```sh
cd server
cargo test
cargo nextest run
ruff check .
```

Please run the tests with pytest and make test.'
      _fx_w "$d/justfile" '@test:
    cargo test
test2 arg="a":
    true'
      printf '.PHONY: test\ntest-unit:\n\ttrue\n' > "$d/Makefile"
      _fx_w "$d/Cargo.toml" '[package]
name = "heavy"
[lints.clippy]
pedantic = "warn"'
      _fx_w "$d/src/lib.rs" '#[test]
fn t() {}'
      _fx_w "$d/hooks/test-a.sh" '#!/bin/sh' ;;
    *) echo "fx_build: no fixture named $n" >&2; return 1 ;;
  esac
  _fx_commit "$d"
}

# fx_build_extra <src-repo> <dir>: HEAD of <src-repo> as a fresh one-commit repo (no history, no
# remotes, nothing of the source's configuration)
fx_build_extra() {
  _fx_init "$2"
  git -C "$1" archive HEAD | tar -x -C "$2" || return 1
  _fx_commit "$2"
}

# fx_state <state> <ritual.sh> <repo>
fx_state() {
  local st="$1" rs="$2" repo="$3" t gd
  case "$st" in
    fresh) ;;
    rerun) tool_run bash "$rs" auto "$repo" >/dev/null 2>&1 ;;
    declined)   # a commit-plan that offered paths, then a record-write that settled the commit declined
      t="$(mktemp -d)" || return 1
      tool_run bash "$rs" preflight "$repo" > "$t/pf.json" 2>/dev/null
      tool_run bash "$rs" auto "$repo" 2>/dev/null | jq -c .wrote > "$t/wr.json"
      tool_run bash "$rs" commit-plan "$repo" "$t/pf.json" "$t/wr.json" >/dev/null 2>&1
      printf '%s' '{"steps":{"commit":{"result":"declined"}}}' > "$t/res.json"
      tool_run bash "$rs" record-write "$repo" "$t/res.json" >/dev/null 2>&1
      rm -rf "$t" ;;
    unreadable-ledger)
      gd="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir | tr -d '\r')"
      mkdir -p "$gd/ritual-ledger.json" ;;
    *) echo "fx_state: no state named $st" >&2; return 1 ;;
  esac
}

# fx_snapshot <name|extra:<src>> <state> <ritual.sh> <repo> <snap>: build at <repo>, put into the
# state, copy to <snap>. fx_restore <snap> <repo> puts it back at the same path.
fx_snapshot() {
  case "$1" in
    extra:*) fx_build_extra "${1#extra:}" "$4" || return 1 ;;
    *) fx_build "$1" "$4" || return 1 ;;
  esac
  fx_state "$2" "$3" "$4" || return 1
  rm -rf "$5"; cp -a "$4" "$5"
}
fx_restore() { rm -rf "$2"; cp -a "$1" "$2"; }

# fx_mode <path> -> the file's octal mode (stat). Under Git Bash the mode follows the content (a
# `#!` file reads 755), so a dropped chmod shows only on Linux; the field is printed everywhere.
fx_mode() { stat -c %a -- "$1" 2>/dev/null || echo nomode; }

# fx_sha256_lines <path>... -> one sha256 per path, in order, empty where a file cannot be read. One
# sha256sum for all paths; it skips an unreadable file with only a stderr message, so when it prints a
# different number of lines than it was given paths, redo it one file at a time rather than let every
# later hash land on the wrong path. A leading backslash (an escaped name) is dropped.
fx_sha256_lines() {
  [ "$#" -gt 0 ] || return 0
  local -a sh=()
  local f l
  mapfile -t sh < <(sha256sum -b -- "$@" 2>/dev/null)
  if [ "${#sh[@]}" -ne "$#" ]; then
    sh=(); for f in "$@"; do sh+=("$(sha256sum -b -- "$f" 2>/dev/null)"); done
  fi
  for l in "${sh[@]}"; do case "$l" in [0-9a-f]*) ;; *) l="${l#?}" ;; esac; printf '%s\n' "${l:0:64}"; done
}
# fx_hash_file <path> -> "<mode>TAB<sha256 of the bytes>"; a file named ritual.json is hashed with
# its `completed_at` value masked (today's date: the one field that differs between two runs).
fx_hash_file() {
  local h
  if [ "$(basename "$1")" = ritual.json ]; then
    h="$(sed 's/"completed_at": *"[^"]*"/"completed_at":"DATE"/g' "$1" | sha256sum | cut -d' ' -f1)"
  else h="$(sha256sum < "$1" | cut -d' ' -f1)"; fi
  printf '%s\t%s\n' "$(fx_mode "$1")" "$h"
}
