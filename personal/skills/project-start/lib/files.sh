#!/usr/bin/env bash
# Steps: traps (.gitattributes / .gitignore lines) and stack-checks (clippy policy).
# Source this file; do not execute it. Needs common.sh and detect.sh sourced first.

_TRAP_ATTR='*.sh text eol=lf'
_TRAP_IGNORES=('.semgrep/' '.env')

# Judged by effect, repo-local only: the user's global attributes/ignore files are disabled so a
# machine-wide rule can never make a repo look covered.
_trap_attr_ok() {
  [ "$(git -C "$1" -c core.attributesFile=/dev/null check-attr eol -- x.sh 2>/dev/null | sed 's/^.*: eol: //')" = lf ]
}
_trap_ignore_ok() { # one path per call: a multi-path -q is any-of
  git -C "$1" -c core.excludesFile=/dev/null check-ignore -q --no-index -- "$2" 2>/dev/null
}

# _traps_missing <repo> -> lines: "attr" and/or the ignore patterns not in effect
_traps_missing() {
  local repo="$1" p probe
  _trap_attr_ok "$repo" || echo attr
  for p in "${_TRAP_IGNORES[@]}"; do
    case "$p" in */) probe="${p}x" ;; *) probe="$p" ;; esac   # a dir pattern is probed by a file inside it
    _trap_ignore_ok "$repo" "$probe" || echo "$p"
  done
}

check_traps() {
  local repo="$1" miss out="" line
  miss="$(_traps_missing "$repo")"
  if [ -z "$miss" ]; then emit traps present "gitattributes eol=lf and ignores in effect"; return 0; fi
  while IFS= read -r line; do
    [ "$line" = attr ] && line=".gitattributes: $_TRAP_ATTR"
    out="${out:+$out, }$line"
  done <<<"$miss"
  emit traps absent "missing: $out"
}

fix_traps() {
  local repo="$1" miss line w
  local wrote=()
  miss="$(_traps_missing "$repo")"
  [ -n "$miss" ] || { emit traps already "nothing to add"; return 0; }
  while IFS= read -r line; do
    if [ "$line" = attr ]; then append_line "$repo/.gitattributes" "$_TRAP_ATTR"; w=.gitattributes
    else append_line "$repo/.gitignore" "$line"; w=.gitignore; fi
    case " ${wrote[*]:-} " in *" $w "*) ;; *) wrote+=("$w") ;; esac
  done <<<"$miss"
  miss="$(_traps_missing "$repo")"   # verify by effect again
  if [ -n "$miss" ]; then
    emit traps failed "still not in effect after append: $(printf '%s' "$miss" | paste -sd' ' -)" "${wrote[@]}"
    return 0
  fi
  emit traps fixed "appended missing lines" "${wrote[@]}"
}

# ---------------- stack-checks ----------------

_rel() { if [ "$1" = . ]; then printf '%s' "$2"; else printf '%s/%s' "$1" "$2"; fi; }

# $1 = Cargo.toml. True if a clippy table exists (own or workspace form) or the crate inherits one.
_cargo_has_clippy() {
  grep -Eq '^[[:space:]]*\[(workspace\.)?lints\.clippy([].]|$)' "$1" && return 0
  awk '/^[[:space:]]*\[/ { in_l = ($0 ~ /^[[:space:]]*\[lints\][[:space:]]*(#.*)?$/); next }
       in_l && /^[[:space:]]*workspace[[:space:]]*=[[:space:]]*true/ { found = 1 }
       END { exit found ? 0 : 1 }' "$1"
}
_cargo_has() { grep -Eq "^[[:space:]]*\\[$2\\]" "$1"; }

# Canonical table from the include (RITUAL_RUST_INCLUDE overrides the path, for tests): from
# "[lints.clippy]" up to the next blank line or next "[" header. Prints nothing when the include
# or the table is missing.
_clippy_table() {
  local src="${RITUAL_RUST_INCLUDE:-$HOME/.claude/includes/rust.md}"
  [ -r "$src" ] || return 0
  tr -d '\r' < "$src" | awk '/^\[lints\.clippy\][[:space:]]*$/ { on = 1; print; next }
       on && (/^[[:space:]]*$/ || /^\[/ || /^```/) { exit }
       on { print }'
}

_stack_dirs() { stack_json "$1" | jq -r '.stacks[] | "\(.lang)\t\(.dir)"' | tr -d '\r'; }

# _stackcheck_one <repo> <lang> <dir> -> "present<TAB>" or "absent<TAB>detail"
_stackcheck_one() {
  local repo="$1" lang="$2" dir="$3" base f
  base="$repo"; [ "$dir" = . ] || base="$repo/$dir"
  case "$lang" in
    rust)
      f="$base/Cargo.toml"
      if _cargo_has_clippy "$f"; then printf 'present\t\n'
      elif _cargo_has "$f" workspace; then printf 'absent\t%s: workspace: needs ask\n' "$(_rel "$dir" Cargo.toml)"
      else printf 'absent\t%s lacks [lints.clippy]\n' "$(_rel "$dir" Cargo.toml)"; fi ;;
    python)
      if [ -f "$base/ruff.toml" ] || [ -f "$base/.ruff.toml" ] || grep -qs '^\[tool\.ruff' "$base/pyproject.toml"; then printf 'present\t\n'
      else printf 'absent\t%s: python lint config needs ask\n' "$dir"; fi ;;
    flutter)
      if [ -f "$base/analysis_options.yaml" ]; then printf 'present\t\n'
      else printf 'absent\t%s: flutter analysis_options needs ask\n' "$dir"; fi ;;
  esac
}

check_stack_checks() {
  local repo="$1" lang dir res n=0 miss=""
  while IFS=$'\t' read -r lang dir; do
    case "$lang" in rust|python|flutter) ;; *) continue ;; esac
    n=$((n + 1))
    res="$(_stackcheck_one "$repo" "$lang" "$dir")"
    [ "${res%%$'\t'*}" = present ] || miss="${miss:+$miss; }${res#*$'\t'}"
  done < <(_stack_dirs "$repo")
  if [ -n "$miss" ]; then emit stack-checks absent "missing: $miss"
  elif [ "$n" -eq 0 ]; then emit stack-checks present "no stack with a managed lint policy"
  else emit stack-checks present "lint policy in place"; fi
}

fix_stack_checks() {
  local repo="$1" lang dir base f bak res table line rel
  local wrote=() asks="" fails="" unk=""
  table="$(_clippy_table)"
  while IFS=$'\t' read -r lang dir; do
    case "$lang" in rust|python|flutter) ;; *) continue ;; esac
    res="$(_stackcheck_one "$repo" "$lang" "$dir")"
    [ "${res%%$'\t'*}" = present ] && continue
    if [ "$lang" != rust ]; then asks="${asks:+$asks; }${res#*$'\t'}"; continue; fi
    base="$repo"; [ "$dir" = . ] || base="$repo/$dir"; f="$base/Cargo.toml"; rel="$(_rel "$dir" Cargo.toml)"
    # only a single-crate root ([package], no [workspace]); anything else is the user's call
    if _cargo_has "$f" workspace; then asks="${asks:+$asks; }$rel: workspace: needs ask"; continue; fi
    if ! _cargo_has "$f" package; then asks="${asks:+$asks; }$rel: no [package]: needs ask"; continue; fi
    if [ -z "$table" ]; then unk="${unk:+$unk; }canonical [lints.clippy] table not found in the rust include"; continue; fi
    bak="$(mktemp)" || { unk="${unk:+$unk; }cannot make backup"; continue; }
    cp -p "$f" "$bak"
    append_line "$f" ""
    while IFS= read -r line; do append_line "$f" "$line"; done <<<"$table"
    if ! command -v cargo >/dev/null 2>&1; then
      cp "$bak" "$f"; rm -f "$bak"; unk="${unk:+$unk; }$rel: cargo not found, edit reverted"; continue
    fi
    if (cd "$base" && cargo metadata --no-deps --format-version 1 >/dev/null 2>&1); then
      rm -f "$bak"; wrote+=("$rel")
    else
      cp "$bak" "$f"; rm -f "$bak"; fails="${fails:+$fails; }$rel: cargo metadata failed, edit reverted"
    fi
  done < <(_stack_dirs "$repo")
  local detail="" p
  for p in "$fails" "$unk" "$asks"; do [ -z "$p" ] || detail="${detail:+$detail; }$p"; done
  if [ -n "$fails" ]; then emit stack-checks failed "$detail" "${wrote[@]}"
  elif [ -n "$unk" ]; then emit stack-checks unknown "$detail" "${wrote[@]}"
  elif [ -n "$asks" ]; then emit stack-checks absent "$detail" "${wrote[@]}"
  elif [ "${#wrote[@]}" -gt 0 ]; then emit stack-checks fixed "appended [lints.clippy]" "${wrote[@]}"
  else emit stack-checks already "nothing to add"; fi
}
