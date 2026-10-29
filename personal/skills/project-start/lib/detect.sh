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

# _det_path_v <var> <dir> <name>: sets <var> to what _det_path prints, with no $(...) and so no fork.
_det_path_v() { if [ "$2" = . ]; then printf -v "$1" '%s' "$3"; else printf -v "$1" '%s/%s' "$2" "$3"; fi; }

# _det_line_starts <file> <prefix>...: does any raw line of <file> start with one of the literal
# prefixes? Replaces `grep -Eq '^prefix'` on a small manifest: a bash read loop, no process. Lines
# are tested as they stand (a CR is not dropped), and the last line needs no newline. An unreadable
# file is no match and bash reports it on stderr, as grep did.
# A file holding a NUL byte (a UTF-16 manifest) goes to 0.16.0's own grep instead: bash's read drops
# NULs, so its lines would read as plain text where grep saw `\0[\0t...`. The probe is one read up
# to the first NUL; its stderr is muted so an unreadable file is reported once, by the loop.
_det_line_starts() {
  local f="$1" l p c re="" nul=""
  shift
  { IFS= read -r -d '' l && nul=1; } 2>/dev/null < "$f"
  if [ -n "$nul" ]; then
    for p in "$@"; do
      for c in '\' '[' ']' '.' '*' '^' '$' '(' ')' '{' '}' '+' '?' '|'; do p="${p//"$c"/\\$c}"; done
      re="${re:+$re|}$p"
    done
    grep -Eq "^($re)" "$f"; return
  fi
  _det_line_starts_scan "$f" "$@"
}

# _det_line_starts_scan <file> <prefix>...: the read loop of _det_line_starts. It reads under LC_ALL=C
# (bytes): in a UTF-8 locale bash's read does not end a line after an invalid byte such as a Latin-1
# e-acute, so `Jos\xe9<LF>[workspace]` would be one line where grep saw two. The grep fallback above
# stays in the caller's locale, as 0.16.0's grep was.
_det_line_starts_scan() {
  local LC_ALL=C f="$1" l p
  shift
  while IFS= read -r l || [ -n "$l" ]; do
    for p in "$@"; do [[ "$l" == "$p"* ]] && return 0; done
  done < "$f"
  return 1
}

# _det_pkg_scripts <package.json>: one jq call for the three oracle questions about a package.json.
# Sets _DET_PKG_PARSED (1 when `jq -e .` would exit 0), _DET_PKG_TEST (1 when scripts.test is a real
# test: some output, none holding "no test specified") and _DET_PKG_LINT (1 when scripts.lint has output).
# Each value is read with `// empty` and a failing read counts as nothing, as before. The values come
# back JSON-encoded on one line, so the placeholder phrase can only match inside one value, and a value
# that is empty or only newlines (which `$(...)` strips to nothing) is told apart from real text.
_det_pkg_scripts() {
  local out l e rc spec=""
  _DET_PKG_PARSED="" _DET_PKG_TEST="" _DET_PKG_LINT=""
  out="$(jq -er '
    (try (.scripts.test // empty) catch empty | "T" + tojson),
    (try (.scripts.lint // empty) catch empty | "L" + tojson),
    (. != null and . != false)' "$1" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 0
  _DET_PKG_PARSED=1
  while IFS= read -r l; do
    l="${l%$'\r'}"
    case "$l" in
      T*) e="${l#T}"
          [ "${e//\\n/}" = '""' ] && continue
          _DET_PKG_TEST=1
          [[ "$e" == *'no test specified'* ]] && spec=1 ;;
      L*) e="${l#L}"
          [ "${e//\\n/}" = '""' ] || _DET_PKG_LINT=1 ;;
    esac
  done <<<"$out"
  [ -z "$spec" ] || _DET_PKG_TEST=""
  return 0
}

# _det_pkg_react <package.json>: sets _DET_PKG_PARSED (1 when `jq -e .` would exit 0) and _DET_PKG_REACT
# (1 when the last document's dependencies + devDependencies has "react") from one jq call.
_det_pkg_react() {
  local out l rc
  _DET_PKG_PARSED="" _DET_PKG_REACT=""
  out="$(jq -er '
    ("R" + ((try (((.dependencies // {}) + (.devDependencies // {})) | has("react")) catch false) | tostring)),
    (. != null and . != false)' "$1" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 0 ] || return 0
  _DET_PKG_PARSED=1
  while IFS= read -r l; do
    l="${l%$'\r'}"
    case "$l" in R*) _DET_PKG_REACT=""; [ "${l#R}" = true ] && _DET_PKG_REACT=1 ;; esac
  done <<<"$out"
  return 0
}

# Workspace memo: one parse of the root Cargo.toml's [workspace] table per scan. _det_ws_load fills these
# for the directory in _DET_WS_DIR; oracle_json and stack_json clear _DET_WS_DIR when a scan starts,
# in the shell that runs the scan (a memo set inside a subshell is lost when it exits).
_DET_WS_DIR="" _DET_WS_MEMBERS="" _DET_WS_EXCLUDE=""

# _det_ws_has_table: does the root Cargo.toml hold a line starting `[workspace]` (a trailing comment
# is fine, `[workspace.package]` is a different table)? A bash read loop, no process; CRs are dropped.
_det_ws_has_table() {
  local LC_ALL=C l   # bytes: see _det_line_starts_scan (an invalid byte before LF would merge two lines)
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l//$'\r'/}"
    [[ "$l" == '[workspace]'* ]] && return 0
  done < Cargo.toml
  return 1
}

# _det_ws_collect: reads awk's `m<TAB>string` / `e<TAB>string` lines on stdin into _DET_WS_MEMBERS and
# _DET_WS_EXCLUDE. Bytewise (LC_ALL=C) so a string ending in an invalid byte does not swallow the next
# line; the awk that writes them runs in the caller's locale.
_det_ws_collect() {
  local LC_ALL=C l
  while IFS= read -r l; do
    case "$l" in
      m$'\t'*) _DET_WS_MEMBERS="${_DET_WS_MEMBERS:+$_DET_WS_MEMBERS$'\n'}${l#m$'\t'}" ;;
      e$'\t'*) _DET_WS_EXCLUDE="${_DET_WS_EXCLUDE:+$_DET_WS_EXCLUDE$'\n'}${l#e$'\t'}" ;;
    esac
  done
}

# _det_ws_load: set _DET_WS_MEMBERS and _DET_WS_EXCLUDE (the strings of `members = [...]` and
# `exclude = [...]`, possibly multi-line, in the [workspace] table, one per line, quotes removed)
# for $PWD, unless they are already loaded for it. Logs "ws_parse" only when it really parses.
_det_ws_load() {
  [ "$_DET_WS_DIR" = "$PWD" ] && return 0
  _DET_WS_DIR="$PWD" _DET_WS_MEMBERS="" _DET_WS_EXCLUDE=""
  [ -f Cargo.toml ] || return 0
  _det_ws_has_table || return 0
  ritual_trace ws_parse
  _det_ws_collect < <(awk '
    function emit(tag, s) { while (match(s, /"[^"]*"/)) { print tag "\t" substr(s, RSTART + 1, RLENGTH - 2); s = substr(s, RSTART + RLENGTH) } }
    { gsub(/\r/, "") }
    /^\[workspace\]/ { w = 1; next }
    /^\[/ { w = 0 }
    {
      if (!dm && w && $0 ~ "^[[:space:]]*members[[:space:]]*=") am = 1
      if (am) { emit("m", $0); if ($0 ~ /\]/) { am = 0; dm = 1 } }
      if (!de && w && $0 ~ "^[[:space:]]*exclude[[:space:]]*=") ae = 1
      if (ae) { emit("e", $0); if ($0 ~ /\]/) { ae = 0; de = 1 } }
    }' Cargo.toml)
  return 0
}

# _det_ws_members <in|out>: workspace `members` globs, expanded to dirs holding a Cargo.toml, then
# split by `exclude`: a member is excluded when its path IS an exclude path or lies under one (a
# path prefix, never a string prefix: "crates/skip" does not exclude "crates/skipper"). Close to
# Cargo, not the same: Cargo keeps an explicitly listed (glob-free) member that `exclude` also
# covers; here it is excluded. `in` prints the members kept, `out` the members excluded.
_det_ws_members() {
  [ -f Cargo.toml ] || return 0
  _det_ws_load
  local want="$1" m p x side excl="$_DET_WS_EXCLUDE"
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
  done <<<"$_DET_WS_MEMBERS"
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

# _det_has_file <dir> <name>...: is any <dir>/<name> a regular file? No process runs.
_det_has_file() {
  local d="$1" n p
  shift
  for n in "$@"; do _det_path_v p "$d" "$n"; [ -f "$p" ] && return 0; done
  return 1
}

# _det_langs_set <dir>: the languages present in <dir>, in the array _DET_LANGS. No process runs.
_det_langs_set() {
  local d="$1" p
  _DET_LANGS=()
  _det_has_file "$d" Cargo.toml && _DET_LANGS+=(rust)
  _det_has_file "$d" pyproject.toml requirements.txt setup.py pytest.ini && _DET_LANGS+=(python)
  _det_has_file "$d" pubspec.yaml && _DET_LANGS+=(flutter)
  _det_has_file "$d" go.mod && _DET_LANGS+=(go)
  _det_has_file "$d" package.json && _DET_LANGS+=(node)
  _det_path_v p "$d" '*.rockspec'
  if compgen -G "$p" >/dev/null || _det_has_file "$d" .luarc.json .busted init.lua; then _DET_LANGS+=(lua); fi
  return 0
}

# Languages present in dir $1, one per line.
_det_langs() {
  _det_langs_set "$1"
  [ "${#_DET_LANGS[@]}" -eq 0 ] || printf '%s\n' "${_DET_LANGS[@]}"
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

# _det_classify_v <var> <cmd>: set <var> to test | lint | none. The three regexes above, tested with
# [[ =~ ]] in this shell: no grep per command.
_det_classify_v() {
  local _cv_c="$2" _cv_r=none
  if [[ "$_cv_c" =~ $_DET_NEVER ]]; then :
  elif [[ "$_cv_c" =~ $_DET_TEST_RE ]]; then _cv_r=test
  elif [[ "$_cv_c" =~ $_DET_LINT_RE ]]; then _cv_r=lint
  fi
  printf -v "$1" '%s' "$_cv_r"
}

# _det_split_into <array> <line>: set <array> to the segments of ONE command line, breaking on
# && || ; | only OUTSIDE quotes. Shell quoting rules: inside '...' nothing is special; a backslash
# escapes the next character outside quotes and inside "...", so \" does not close a string and \;
# does not split. An unterminated quote runs to the end of the line: nothing after it is split off,
# so text inside a broken string never becomes a command. A line with no separator is one segment
# (an empty line is one empty segment). It was an awk filter run once per line.
_det_split_into() {
  local -n _ds_o="$1"
  local _ds_s="$2" _ds_n="${#2}" _ds_i _ds_c _ds_seg="" _ds_q=""
  _ds_o=()
  for ((_ds_i = 0; _ds_i < _ds_n; _ds_i++)); do
    _ds_c="${_ds_s:_ds_i:1}"
    if [ "$_ds_q" = "'" ]; then
      _ds_seg+="$_ds_c"; [ "$_ds_c" = "'" ] && _ds_q=""
      continue
    fi
    if [ "$_ds_c" = '\' ] && [ $((_ds_i + 1)) -lt "$_ds_n" ]; then
      _ds_seg+="$_ds_c${_ds_s:_ds_i+1:1}"; _ds_i=$((_ds_i + 1))
      continue
    fi
    if [ "$_ds_q" = '"' ]; then
      _ds_seg+="$_ds_c"; [ "$_ds_c" = '"' ] && _ds_q=""
      continue
    fi
    if [ "$_ds_c" = "'" ] || [ "$_ds_c" = '"' ]; then _ds_q="$_ds_c"; _ds_seg+="$_ds_c"; continue; fi
    if { [ "$_ds_c" = '&' ] || [ "$_ds_c" = '|' ]; } && [ "${_ds_s:_ds_i+1:1}" = "$_ds_c" ]; then
      _ds_o+=("$_ds_seg"); _ds_seg=""; _ds_i=$((_ds_i + 1))
      continue
    fi
    if [ "$_ds_c" = ';' ] || [ "$_ds_c" = '|' ]; then _ds_o+=("$_ds_seg"); _ds_seg=""; continue; fi
    _ds_seg+="$_ds_c"
  done
  _ds_o+=("$_ds_seg")
}

# _det_shell_c_v <var> <cmd>: when <cmd> is `bash|sh [-opts] -c <script>` and the script is ONE word
# (one "..." or '...' string, or a bare word), set <var> to the script (\" \\ \$ \` unescaped for
# "...") and return 0. Anything else returns 1 and leaves <var> alone.
_det_shell_c_v() {
  local _sc_re='^(bash|sh)([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c[[:space:]]+(.+)$' _sc_rest _sc_t _sc_s _sc_pre _sc_out="" _sc_c
  [[ "$2" =~ $_sc_re ]] || return 1
  _sc_rest="${BASH_REMATCH[3]}"
  if [ "${#_sc_rest}" -ge 2 ] && [ "${_sc_rest:0:1}" = '"' ] && [ "${_sc_rest: -1}" = '"' ]; then
    _sc_t="${_sc_rest:1:${#_sc_rest}-2}"
    _sc_s="${_sc_t//\\\\/}"; _sc_s="${_sc_s//\\\"/}"
    case "$_sc_s" in *'"'*) return 1 ;; esac        # an unescaped " inside: not one word
    # \" \\ \$ \` -> the character, left to right, each pair consumed once (sed 's/\\(["\\$`])/\1/g')
    while [[ "$_sc_t" == *\\* ]]; do
      _sc_pre="${_sc_t%%\\*}"; _sc_t="${_sc_t#*\\}"; _sc_c="${_sc_t:0:1}"
      case "$_sc_c" in
        '"'|'\'|'$'|'`') _sc_out+="$_sc_pre$_sc_c"; _sc_t="${_sc_t:1}" ;;
        *) _sc_out+="$_sc_pre\\" ;;
      esac
    done
    printf -v "$1" '%s' "$_sc_out$_sc_t"; return 0
  elif [ "${#_sc_rest}" -ge 2 ] && [ "${_sc_rest:0:1}" = "'" ] && [ "${_sc_rest: -1}" = "'" ]; then
    _sc_t="${_sc_rest:1:${#_sc_rest}-2}"
    case "$_sc_t" in *"'"*) return 1 ;; esac
    printf -v "$1" '%s' "$_sc_t"; return 0
  fi
  case "$_sc_rest" in *[[:space:]\"\']*) return 1 ;; esac
  printf -v "$1" '%s' "$_sc_rest"
}

# _det_classify_line <line> <source>: classify one command line. Uses and extends the caller's
# _det_cd (the `cd` segments seen so far in this shell session) and _det_loop (the loops open in
# it); see _det_classify_stream.
#
# A line holding a byte >= 0x80 runs 0.16.0's own code (_det_classify_line_old, which asks sed and
# grep), not the bash code below. The reason is the regex engine: on Git Bash, [[ =~ ]] reads a range
# such as [A-Za-z0-9] by collation order under a locale like en_GB.UTF-8, so e, ss and n with accents
# fall inside it, where the GNU grep and sed of 0.16.0 reject them (and the other way round on a
# platform whose grep admits them). Only the program that used to decide can decide for those bytes.
# The byte test runs under LC_ALL=C (bytes, never characters) in a helper of its own, so neither
# path below runs in the C locale.
# Pure-ASCII lines, which is nearly every line, keep the bash path.
_det_has_high_byte() { local LC_ALL=C; [[ $1 == *[$'\x80'-$'\xff']* ]]; }
_det_classify_line() {
  if _det_has_high_byte "$1"; then _det_classify_line_old "$@"; else _det_classify_line_ascii "$@"; fi
}

_det_classify_line_ascii() {
  local seg stripped inner saved sl kind lead trail
  local -a segs
  local loop_re='^((if|then|else|elif|do|!)[[:space:]]+)*(for|while|until|done)([[:space:]]|$)'
  local kw_re='^((if|then|else|elif|while|until|!)[[:space:]]+)+'
  local asg_re='^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)+'
  _det_split_into segs "$1"
  for seg in "${segs[@]}"; do
    lead="${seg%%[![:space:]]*}"; seg="${seg#"$lead"}"
    trail="${seg##*[![:space:]]}"; seg="${seg%"$trail"}"
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
    stripped="$seg"
    [[ "$stripped" =~ $kw_re ]] && stripped="${stripped:${#BASH_REMATCH[0]}}"
    [[ "$stripped" =~ $asg_re ]] && stripped="${stripped:${#BASH_REMATCH[0]}}"
    case "$stripped" in
      cd\ *) _det_cd="${_det_cd:+$_det_cd && }$stripped"; continue ;;
    esac
    if _det_shell_c_v inner "$stripped"; then
      # the script runs in a child shell: it sees our cd, its own cd does not come back out
      saved="$_det_cd"; sl="${_det_loop:-0}"; _det_classify_line "$inner" "$2"; _det_cd="$saved"; _det_loop="$sl"; continue
    fi
    _det_classify_v kind "$stripped"
    case "$kind" in
      test) _det_add test . "${_det_cd:+$_det_cd && }$stripped" "$2" ;;
      lint) _det_add lint . "${_det_cd:+$_det_cd && }$stripped" "$2" ;;
    esac
  done
}

# --- 0.16.0's classifier, verbatim --------------------------------------------------------------
# What _det_classify_line runs for a line holding a byte >= 0x80 (see there): grep -E classifies,
# sed -E strips, awk splits, exactly as the released code did. Only the names carry an _old
# suffix; the recursion into _det_classify_line is 0.16.0's own.
# _det_classify_old <cmd> -> test | lint | none
_det_classify_old() {
  if printf '%s' "$1" | grep -Eq "$_DET_NEVER"; then echo none
  elif printf '%s' "$1" | grep -Eq "$_DET_TEST_RE"; then echo test
  elif printf '%s' "$1" | grep -Eq "$_DET_LINT_RE"; then echo lint
  else echo none; fi
}

# _det_split_old: reads ONE command line on stdin and prints its segments, one per line, breaking on
# && || ; | only OUTSIDE quotes (POSIX awk: gawk and mawk alike). Shell quoting rules: inside '...'
# nothing is special; a backslash escapes the next character outside quotes and inside "...", so
# \" does not close a string and \; does not split. An unterminated quote runs to the end of the
# line: nothing after it is split off, so text inside a broken string never becomes a command.
_det_split_old() {
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

# _det_shell_c_old <cmd>: when <cmd> is `bash|sh [-opts] -c <script>` and the script is ONE word (one
# "..." or '...' string, or a bare word), print the script (\" \\ \$ \` unescaped for "...") and
# return 0. Anything else returns 1 and prints nothing.
_det_shell_c_old() {
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

# _det_classify_line_old <line> <source>: classify one command line. Uses and extends the caller's
# _det_cd (the `cd` segments seen so far in this shell session) and _det_loop (the loops open in
# it); see _det_classify_stream.
_det_classify_line_old() {
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
    if inner="$(_det_shell_c_old "$stripped")"; then
      # the script runs in a child shell: it sees our cd, its own cd does not come back out
      saved="$_det_cd"; sl="${_det_loop:-0}"; _det_classify_line "$inner" "$2"; _det_cd="$saved"; _det_loop="$sl"; continue
    fi
    case "$(_det_classify_old "$stripped")" in
      test) _det_add test . "${_det_cd:+$_det_cd && }$stripped" "$2" ;;
      lint) _det_add lint . "${_det_cd:+$_det_cd && }$stripped" "$2" ;;
    esac
  done < <(printf '%s\n' "$1" | _det_split_old)
}
# --- end of 0.16.0's classifier --------------------------------------------------------------

# _det_classify_stream <source>: reads command LINES on stdin; an EMPTY line ends a shell session.
# Each line is split into segments on && || ; | outside quotes (_det_split_into); every segment is
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
  local d="$1" toml="$2" re='#\[([A-Za-z0-9_]+::)*test(\]|\()|#\[cfg\(test\)\]|#\[(rstest|test_case)' src tests
  if ! _det_line_starts "$toml" '[workspace]'; then
    _det_path_v src "$d" src; _det_path_v tests "$d" tests
    grep -rEqs --include='*.rs' "$re" "$src" "$tests" 2>/dev/null && return 0
    [ -n "$(find "$tests" -type f -print -quit 2>/dev/null)" ] && return 0
    return 1
  fi
  grep -rEqs --include='*.rs' --exclude-dir=target --exclude-dir=node_modules "$re" "$d" 2>/dev/null && return 0
  [ -n "$(find "$d" \( -name target -o -name node_modules \) -prune -o -type f -path '*/tests/*' -print -quit 2>/dev/null)" ] && return 0
  return 1
}

# Entries for one directory $1 (cwd = repo). $2 = "member" if it is a Cargo workspace member.
_det_dir_entries() {
  local d="$1" member="${2:-}" p t
  _det_path_v p "$d" Cargo.toml
  if [ -f "$p" ] && [ -z "$member" ]; then
    if _det_rust_has_tests "$d" "$p"; then _det_add test "$d" "cargo test" "$p"; fi
    if _det_line_starts "$p" '[lints.clippy]' '[workspace.lints.clippy]'; then
      _det_add lint "$d" "cargo clippy --all-targets -- -D warnings" "$p"
    fi
  fi
  # python: one test entry per dir, first source wins
  local pysrc="" pyp
  _det_path_v pyp "$d" pyproject.toml
  _det_path_v p "$d" pytest.ini
  if [ -f "$p" ]; then pysrc="$p"
  elif [ -f "$pyp" ] && _det_line_starts "$pyp" '[tool.pytest'; then
    pysrc="$pyp"
  else
    for t in tests test; do
      _det_path_v p "$d" "$t"
      if [ -d "$p" ] && [ -n "$(find "$p" -maxdepth 2 \( -name 'test_*.py' -o -name '*_test.py' \) -print -quit 2>/dev/null)" ]; then
        pysrc="$p/"; break
      fi
    done
  fi
  [ -n "$pysrc" ] && _det_add test "$d" "pytest" "$pysrc"
  if { [ -f "$pyp" ] && _det_line_starts "$pyp" '[tool.ruff'; }; then _det_add lint "$d" "ruff check" "$pyp"
  else
    _det_path_v p "$d" ruff.toml
    [ -f "$p" ] && _det_add lint "$d" "ruff check" "$p"
  fi
  # node
  _det_path_v p "$d" package.json
  if [ -f "$p" ]; then
    _det_pkg_scripts "$p"
    if [ -z "$_DET_PKG_PARSED" ]; then
      _det_add unparsed "$d" "" "$p"      # UNKNOWN, not absent: could not read this manifest
    else
      [ -n "$_DET_PKG_TEST" ] && _det_add test "$d" "npm test" "$p"
      [ -n "$_DET_PKG_LINT" ] && _det_add lint "$d" "npm run lint" "$p"
    fi
  fi
  # go: only when test files exist
  _det_path_v p "$d" go.mod
  if [ -f "$p" ]; then
    _det_add lint "$d" "go vet ./..." "$p"
    if [ -n "$(find "$d" -maxdepth 4 \( -name node_modules -o -name vendor -o -name target -o -name .git \) -prune -o -name '*_test.go' -print -quit 2>/dev/null)" ]; then _det_add test "$d" "go test ./..." "$p"; fi
  fi
  # flutter: only when test/ holds *_test.dart
  _det_path_v p "$d" pubspec.yaml
  if [ -f "$p" ]; then
    _det_add lint "$d" "flutter analyze" "$p"
    _det_path_v t "$d" test
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
  _DET_WS_DIR=""; _det_ws_load
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
  lines="$(cd "$repo" || exit 1; _DET_WS_DIR=""; _det_ws_load; while IFS= read -r d; do
        # package.json is read once per directory: parse-validity and react from one jq call
        _det_path_v p "$d" package.json
        _DET_PKG_PARSED="" _DET_PKG_REACT=""
        [ -f "$p" ] && _det_pkg_react "$p"
        _det_langs_set "$d"
        for l in ${_DET_LANGS[@]+"${_DET_LANGS[@]}"}; do
          printf 'stack\t%s\t%s\n' "$d" "$l"
          case "$l" in
            rust) printf 'include\tcore:rust-standards\n' ;;
            python) printf 'include\tcore:python-standards\n' ;;
            go) printf 'include\tcore:golang-standards\n' ;;
            node) [ -z "$_DET_PKG_REACT" ] || printf 'include\tcore:react-standards\n' ;;
          esac
        done
        # every manifest the scan tried to parse: a failure is reported, never invisible
        if [ -f "$p" ] && [ -z "$_DET_PKG_PARSED" ]; then printf 'unparsed\t%s\n' "$p"; fi
      done < <(_det_dirs))" || die "cannot scan: $repo"
  [ "$status" = present ] && lines="$lines"$'\n'"include	core:testing-standards"
  printf '%s\n' "$lines" | jq -Rnc '
    [inputs | select(length > 0) | split("\t")] as $r
    | ([$r[] | select(.[0] == "unparsed") | .[1]] | unique) as $u
    | {stacks: ([$r[] | select(.[0] == "stack") | {lang: .[2], dir: .[1]}] | unique | sort_by([.dir, .lang])),
       includes: ([$r[] | select(.[0] == "include") | .[1]] | unique)}
      + (if ($u | length) > 0 then {unparsed: $u} else {} end)'
}
