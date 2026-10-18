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
  local repo="$1" miss line w newmod n detail
  local wrote=()
  miss="$(_traps_missing "$repo")"
  [ -n "$miss" ] || { emit_already traps "$repo" "nothing to add" .gitattributes .gitignore; return 0; }
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
  detail="appended missing lines"
  # The new eol rule can make committed CRLF files show as modified. Report it; never renormalise.
  # git's own `status` is stat-cached and can miss a changed attribute, so ask the index directly:
  # committed files whose index copy is CRLF/mixed and that the eol=lf rule now covers.
  newmod=""
  if [[ " ${wrote[*]} " == *" .gitattributes "* ]]; then
    newmod="$(git -C "$repo" ls-files --eol 2>/dev/null | tr -d '\r' \
      | awk -F'\t' '$1 ~ /^i\/(crlf|mixed)/ && $1 ~ /eol=lf/ { print $2 }')"
  fi
  if [ -n "$newmod" ]; then
    n="$(printf '%s\n' "$newmod" | wc -l | tr -d ' ')"
    detail="$detail; $n committed file(s) now show modified (line-ending rule; not renormalised): $(printf '%s\n' "$newmod" | head -n 10 | paste -sd, - | sed 's/,/, /g')"
    [ "$n" -le 10 ] || detail="$detail, and $((n - 10)) more"
  fi
  emit traps fixed "$detail" "${wrote[@]}"
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

# _ws_list <Cargo.toml> <key> -> the quoted strings of `key = [ ... ]` (possibly multi-line)
_ws_list() {
  tr -d '\r' < "$1" | awk -v key="$2" '
    !on && $0 ~ "^[[:space:]]*" key "[[:space:]]*=[[:space:]]*[[]" { on = 1 }
    on { s = $0
         while (match(s, /"[^"]*"/)) { print substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) }
         if ($0 ~ /\]/) on = 0 }'
}

# _ws_member <repo> <dir>: true if the ROOT Cargo.toml is a workspace and <dir> is one of its
# members (members globs minus exclude). The root itself is not a "member" here.
_ws_member() {
  local root="$1/Cargo.toml" dir="${2#./}" g
  [ "$2" != . ] && [ -f "$root" ] && _cargo_has "$root" workspace || return 1
  while IFS= read -r g; do
    g="${g#./}"; g="${g%/}"
    # shellcheck disable=SC2053
    [[ "$dir" == $g ]] && { _ws_list "$root" exclude | grep -qxF -- "$dir" && return 1; return 0; }
  done < <(_ws_list "$root" members)
  return 1
}

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

# _stack_dirs <repo> -> "lang<TAB>dir" lines. Languages only, so no oracle scan. `auto` hands over
# the scan it already made in _RITUAL_STACK_MEMO (for the repo in _RITUAL_MEMO_REPO only).
_stack_dirs() {
  local s
  if [ -n "${_RITUAL_STACK_MEMO:-}" ] && [ "${_RITUAL_MEMO_REPO:-}" = "$1" ]; then s="$_RITUAL_STACK_MEMO"
  else s="$(stack_json "$1" -)" || return $?; fi
  printf '%s' "$s" | jq -r '.stacks[] | "\(.lang)\t\(.dir)"' | tr -d '\r'
}

# _stackcheck_one <repo> <lang> <dir> -> "present<TAB>" or "absent<TAB>detail"
_stackcheck_one() {
  local repo="$1" lang="$2" dir="$3" base f
  base="$repo"; [ "$dir" = . ] || base="$repo/$dir"
  case "$lang" in
    rust)
      f="$base/Cargo.toml"
      if _cargo_has_clippy "$f"; then printf 'present\t\n'
      elif _cargo_has "$f" workspace || _ws_member "$repo" "$dir"; then printf 'absent\t%s: workspace: needs ask\n' "$(_rel "$dir" Cargo.toml)"
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
  local repo="$1" lang dir base f bak res table line rel lock lockbak meta_ok
  local wrote=() have=() asks="" fails="" unk=""
  table="$(_clippy_table)"
  while IFS=$'\t' read -r lang dir; do
    case "$lang" in rust|python|flutter) ;; *) continue ;; esac
    res="$(_stackcheck_one "$repo" "$lang" "$dir")"
    if [ "${res%%$'\t'*}" = present ]; then [ "$lang" = rust ] && have+=("$(_rel "$dir" Cargo.toml)"); continue; fi
    if [ "$lang" != rust ]; then asks="${asks:+$asks; }${res#*$'\t'}"; continue; fi
    base="$repo"; [ "$dir" = . ] || base="$repo/$dir"; f="$base/Cargo.toml"; rel="$(_rel "$dir" Cargo.toml)"
    # only a single-crate root ([package], no [workspace]); anything else is the user's call
    if [[ "${res#*$'\t'}" == *"workspace: needs ask"* ]]; then asks="${asks:+$asks; }$rel: workspace: needs ask"; continue; fi
    if ! _cargo_has "$f" package; then asks="${asks:+$asks; }$rel: no [package]: needs ask"; continue; fi
    if [ -z "$table" ]; then unk="${unk:+$unk; }canonical [lints.clippy] table not found in the rust include"; continue; fi
    bak="$(mktemp)" || { unk="${unk:+$unk; }cannot make backup"; continue; }
    cp -p "$f" "$bak"
    lock="$base/Cargo.lock"; lockbak=""   # cargo metadata may create or rewrite Cargo.lock
    if [ -f "$lock" ]; then lockbak="$(mktemp)"; cp -p "$lock" "$lockbak"; fi
    append_line "$f" ""
    while IFS= read -r line; do append_line "$f" "$line"; done <<<"$table"
    if ! command -v cargo >/dev/null 2>&1; then
      cp "$bak" "$f"; rm -f "$bak" "$lockbak"; unk="${unk:+$unk; }$rel: cargo not found, edit reverted"; continue
    fi
    if (cd "$base" && cargo metadata --no-deps --format-version 1 >/dev/null 2>&1); then
      meta_ok=1
    else
      meta_ok=0
    fi
    if [ -n "$lockbak" ]; then cp "$lockbak" "$lock"; rm -f "$lockbak"; else rm -f "$lock"; fi
    if [ "$meta_ok" = 1 ]; then
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
  else emit_already stack-checks "$repo" "nothing to add" ${have[@]+"${have[@]}"}; fi
}
