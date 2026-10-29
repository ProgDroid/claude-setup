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

# make_tool_stubs <dir>: the stub bd, gh, gitleaks and cargo every end-to-end run uses, each logging
# its argv to $LOGS/<tool>. Creates "<dir>/e2e stubs", "<dir>/cargo stub", "<dir>/empty localappdata"
# and "<dir>/stub logs" (spaces on purpose) and sets STUBS, CARGO_STUB, EMPTY_LA, LOGS and INC (the
# rust include, which RITUAL_RUST_INCLUDE points at so the clippy-table append runs on any host).
# tool_run <cmd...> runs a command with them first on PATH and that environment exported.
make_tool_stubs() {
  STUBS="$1/e2e stubs"; CARGO_STUB="$1/cargo stub"; EMPTY_LA="$1/empty localappdata"
  LOGS="$1/stub logs"; INC="$TESTS_DIR/fixtures/rust-include.md"
  mkdir -p "$STUBS" "$CARGO_STUB" "$EMPTY_LA" "$LOGS"
  cat > "$STUBS/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_LOGS:?}/bd"
[ "$1 ${2:-} ${3:-}" = "config get metrics.disabled" ] && printf '%s\n' "${STUB_METRICS-true}"
exit 0
STUB
  cat > "$STUBS/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_LOGS:?}/gh"
echo PRIVATE
STUB
  # flags any staged AWS-style key, as the real gitleaks rule does
  cat > "$STUBS/gitleaks" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_LOGS:?}/gitleaks"
if git diff --cached | grep -qE 'AKIA[A-Z2-7]{16}'; then echo "WRN leaks found: 1" >&2; exit 1; fi
echo "INF no leaks found" >&2; exit 0
STUB
  cat > "$CARGO_STUB/cargo" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${E2E_LOGS:?}/cargo"
exit 0
STUB
  chmod +x "$STUBS"/* "$CARGO_STUB/cargo"
}
tool_run() { ( stub_path "$CARGO_STUB"; stub_path "$STUBS"; export E2E_LOGS="$LOGS" RITUAL_RUST_INCLUDE="$INC"; "$@" ); }

# have_locale <name>: succeeds when `locale -a` lists <name>. The spellings UTF-8 and utf8 count as
# one (glibc lists en_GB.utf8 for en_GB.UTF-8), and so do upper and lower case. A pin that runs
# under a locale calls this first, so an absent locale is counted as absent and never as a pass.
have_locale() {
  local want
  want="$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -d '-')"
  locale -a 2>/dev/null | tr 'A-Z' 'a-z' | tr -d '-' | grep -qx "$want"
}
