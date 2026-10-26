#!/usr/bin/env bash
# Steps: beads (house bd setup) and beads-metrics. Source this file; do not execute it.
# Needs common.sh and workspace.sh (preflight) sourced first.
#
# Never trust bd's exit code: several bd commands exit 255 on success. Every bd step below is
# judged by the state it leaves, never by its status.

_BEADS_HOUSE="$RITUAL_SKILL_DIR/house/beads"
_BEADS_OVERRIDE="$RITUAL_SKILL_DIR/house/claude-md-override.md"
_BEADS_OVERRIDE_HEADING='## Task tracking vs. execution structure'
_BEADS_MARKER='BEGIN BEADS INTEGRATION'
_BEADS_KEYS=(export.auto export.git-add no-push dolt.local-only)
# what `fix` sets: the four keys `check` requires, plus the export throttle (measured: the default
# 60s drops writes inside the window, `0s` is accepted and inert, `1ms` exports every write).
# `check` does not require the interval, because the user-level bd config may supply it.
_BEADS_SETS=("export.auto true" "export.git-add true" "no-push true" "dolt.local-only true" "export.interval 1ms")
# Paths `bd init` writes and commits. An uncommitted user change to one of them would collide with
# bd's commit when the stash is re-applied, so --stash refuses up front rather than mid-way.
_BEADS_INIT_PATHS_RE='^(CLAUDE\.md|AGENTS\.md|\.gitignore|\.claude/settings\.json|\.codex/|\.agents/|\.beads/)'
# The two imperatives bd's generated block ships that the house overrides; matched with the same
# substrings check-block.sh uses, and replaced only inside a block written during this run.
_BEADS_BAN_TODO='do NOT use TodoWrite'
_BEADS_BAN_MEM='do NOT use MEMORY.md'
_BEADS_LINE_TODO='- Use `bd` for all DURABLE task tracking: file the issue before writing the code. TodoWrite is a different layer and is NOT banned here; see "Task tracking vs. execution structure" below.'
_BEADS_LINE_MEM='- Use `bd` for WORK STATE only. Memory is files, not `bd remember`; see "Task tracking vs. execution structure" below.'

# _beads_cfg <config.yaml> -> "key=value" lines. Reads flat dotted keys (`export.auto: true`) and
# one level of nesting (`export:` / `  auto: true`), which is how bd writes them. Read the file
# directly: `bd config get` answers from the user-level config even where no .beads/ exists.
_beads_cfg() {
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | awk '
    /^[ \t]*(#|$)/ { next }
    { sub(/[ \t]+#.*$/, "") }
    /^[^ \t]/ {
      parent = ""
      if (match($0, /^[^:]+:/)) {
        k = substr($0, 1, RLENGTH - 1); v = substr($0, RLENGTH + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
        if (v == "") parent = k; else print k "=" v
      }
      next
    }
    parent != "" && match($0, /^[ \t]+[^:]+:/) {
      k = substr($0, 1, RLENGTH - 1); sub(/^[ \t]+/, "", k)
      v = substr($0, RLENGTH + 1); gsub(/^[ \t]+|[ \t]+$/, "", v)
      print parent "." k "=" v
    }'
}

# _beads_cfg_get <config.yaml> <key> -> the last value given for <key>, unquoted (empty if unset).
_beads_cfg_get() {
  local v
  v="$(_beads_cfg "$1" | awk -v k="$2" 'index($0, k "=") == 1 { v = substr($0, length(k) + 2) } END { print v }')"
  v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
  printf '%s' "$v"
}

# _beads_has_line <file> <line>:the file holds <line> exactly (CRs ignored).
_beads_has_line() { [ -f "$1" ] && tr -d '\r' < "$1" | grep -qxF -- "$2"; }

_beads_has_marker() { [ -f "$1" ] && grep -q "$_BEADS_MARKER" "$1"; }

# _beads_rules <house-file> -> its non-blank, non-comment lines.
_beads_rules() { tr -d '\r' < "$1" | grep -v -e '^[[:space:]]*$' -e '^#'; }

# _beads_hooks_state <top> -> ok | unset | other. ok when core.hooksPath, relative (to the work
# tree) or absolute in any form, resolves to <top>/.beads/hooks. bd 1.2.2 writes an absolute
# Windows path; the house writes the relative form.
_beads_hooks_state() {
  local top="$1" hp abs want
  hp="$(git -C "$top" config core.hooksPath 2>/dev/null)"
  [ -n "$hp" ] || { echo unset; return; }
  case "$hp" in /*|[A-Za-z]:*|\\*) abs="$hp" ;; *) abs="$top/$hp" ;; esac
  want="$top/.beads/hooks"
  if [ "$(path_norm "$abs")" = "$(path_norm "$want")" ]; then echo ok
  elif [ -e "$want" ] && [ "$abs" -ef "$want" ]; then echo ok
  else echo other; fi
}

# _beads_conditions <top> -> one line per house condition that does NOT hold (empty = all hold).
_beads_conditions() {
  local top="$1" k v l out rc
  for k in "${_BEADS_KEYS[@]}"; do
    v="$(_beads_cfg_get "$top/.beads/config.yaml" "$k")"
    [ "$v" = true ] || echo "$k is ${v:-unset} in .beads/config.yaml (want true)"
  done
  case "$(_beads_hooks_state "$top")" in
    ok) ;;
    unset) echo "core.hooksPath is unset (want .beads/hooks)" ;;
    *) echo "core.hooksPath is '$(git -C "$top" config core.hooksPath)', not this repo's .beads/hooks" ;;
  esac
  while IFS= read -r l; do
    _beads_has_line "$top/.gitattributes" "$l" || echo ".gitattributes lacks '$l'"
  done < <(_beads_rules "$_BEADS_HOUSE/gitattributes")
  if [ ! -f "$top/.beads/check-block.sh" ]; then
    echo ".beads/check-block.sh missing"
  else
    out="$(cd "$top" && sh .beads/check-block.sh CLAUDE.md 2>&1)"; rc=$?
    [ "$rc" -eq 0 ] || echo "check-block.sh exit $rc: $(grep -E '^(FAIL|UNKNOWN)' <<<"$out" | tr '\n' ' ' | sed 's/ *$//')"
  fi
}

# check beads <repo>: present = .beads/ exists and every house condition holds; absent = no
# .beads/, or a .beads/ failing any condition (detail names each); unknown = no bd on PATH.
check_beads() {
  local repo="$1" top miss
  command -v bd >/dev/null 2>&1 || { emit beads unknown "bd not on PATH"; return 0; }
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  [ -d "$top/.beads" ] || { emit beads absent "no .beads/ directory"; return 0; }
  miss="$(_beads_conditions "$top")"
  if [ -z "$miss" ]; then emit beads present "house beads setup holds"
  else
    local -a ms; mapfile -t ms <<<"$miss"
    emit beads absent "$(join_by '; ' "${ms[@]}")"
  fi
}

# check beads-metrics <repo>: present = bd telemetry is off (metrics.disabled true). This one is
# deliberately read through bd: telemetry is a user-level setting.
check_beads_metrics() {
  local repo="$1" top v
  command -v bd >/dev/null 2>&1 || { emit beads-metrics unknown "bd not on PATH"; return 0; }
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  v="$(cd "$top" && bd config get metrics.disabled 2>/dev/null | tr -d '\r' | tail -n 1)"
  v="${v//[[:space:]]/}"
  case "$v" in
    true)  emit beads-metrics present "metrics.disabled is true (bd telemetry off)" ;;
    # Measured on bd 1.2.2: `config set` writes this key to the USER-level config from any cwd, a
    # repo included (it names the file it wrote), and never to .beads/config.yaml.
    false) emit beads-metrics absent "metrics.disabled is false (bd telemetry on); turn it off machine-wide with: bd config set metrics.disabled true" ;;
    *)     emit beads-metrics unknown "bd config get metrics.disabled answered '$v'" ;;
  esac
}

# _beads_git_raw <top> <git args...>: git with no line-ending conversion and no attributes, so a
# stash stores and restores the user's raw bytes. Measured with core.autocrlf=true: a plain stash
# round trip rewrites LF and mixed-ending files as CRLF (and eol=lf files the other way).
# --attr-source replaces only the in-tree attributes, so core.attributesFile is pointed at /dev/null
# (git for Windows accepts it from Git Bash and from PowerShell: probed, a configured eol=crlf reads
# back unspecified). $GIT_DIR/info/attributes cannot be overridden at all: fix_beads refuses
# --stash when it is non-empty. The options are shared with the recovery command printed to the
# user, so what the user is told to run is exactly what ran here.
_BEADS_RAW_OPTS=(-c core.autocrlf=false -c core.eol=lf -c core.safecrlf=false -c core.attributesFile=/dev/null)
_beads_git_raw() {
  local top="$1" empty; shift
  empty="$(git -C "$top" hash-object -t tree /dev/null)" || return 1
  git -C "$top" "${_BEADS_RAW_OPTS[@]}" --attr-source="$empty" "$@"
}

# _beads_raw_apply_cmd <top> <sha> -> the raw-mode `stash apply` for the user to run in the repo.
# A plain `git stash apply` under core.autocrlf=true gives back different bytes (measured).
_beads_raw_apply_cmd() {
  local empty; empty="$(git -C "$1" hash-object -t tree /dev/null)"
  printf 'git %s --attr-source=%s stash apply --index %s' "${_BEADS_RAW_OPTS[*]}" "${empty:-<empty-tree>}" "$2"
}

# _beads_stash_ref <top> <sha> -> stash@{N} for the stash commit <sha> (empty if gone).
_beads_stash_ref() {
  git -C "$1" stash list --format='%gd %H' 2>/dev/null | awk -v s="$2" '$2 == s { print $1; exit }'
}

# one path's state in a preflight snapshot: [XY, bytes, index], or null when it is not dirty there
_BEADS_ENT='def ent($s; $p): ($s.dirty | map(select(.path == $p)) | .[0]) as $d
  | if $d == null then null else [$d.xy, $s.bytes[$p], $s.index[$p]] end;'

# _beads_snaps <label> <filter> <snapshot...> -> the filter's answer, one JSON array, with the
# snapshots bound to $s[0], $s[1], ... They reach jq on stdin, never argv: jq.exe is a native
# Windows program, so a command line past ~32 KB (about 95 dirty files per snapshot) fails with
# "Argument list too long" and prints nothing. Status 1 and no output unless jq exits 0 AND answers
# exactly one JSON array; callers treat that as "could not compare", never as "identical".
# <label> names the call; the test shim matches it to fail one call and not the others.
_beads_snaps() {
  local why="$1" f="$2" out; shift 2
  out="$(printf '%s\n' "$@" | jq -sc --arg why "$why" --argjson n "$#" "$_BEADS_ENT"'
    if length == $n and all(.[]; type == "object" and (.dirty | type) == "array") then . as $s | '"$f"'
    else error("\($why): expected \($n) preflight snapshots") end' 2>/dev/null)" || return 1
  out="${out//$'\r'/}"
  [ "$(printf '%s\n' "$out" | jq -sc 'length == 1 and (.[0] | type) == "array"' 2>/dev/null | tr -d '\r')" = true ] || return 1
  printf '%s\n' "$out"
}

# _beads_snapdiff <pre> <post> [<excused>] -> comma-joined paths whose XY, bytes or index differ
# (or which are dirty on one side only), plus a branch change; empty = identical. Paths dirty in
# the <excused> snapshot (bd init's leftovers after a failed init) are left out unless they were
# also dirty in <pre>. Status 1 when the compare could not run: that is a mismatch, never a pass.
_beads_snapdiff() {
  local arr out x='{"dirty":[]}'
  [ -n "${3:-}" ] && x="$3"
  arr="$(_beads_snaps snapdiff '$s[0] as $a | $s[1] as $b | ([$s[2].dirty[].path] - [$a.dirty[].path]) as $x
    | ([$a.dirty[].path] + [$b.dirty[].path] | unique - $x) as $ps
    | [$ps[] | . as $p | select(ent($a; $p) != ent($b; $p))]
      + (if $a.branch != $b.branch then ["branch \($a.branch) -> \($b.branch)"] else [] end)' \
    "$1" "$2" "$x")" || return 1
  out="$(printf '%s\n' "$arr" | jq -r 'join(", ")')" || return 1
  printf '%s' "${out//$'\r'/}"
}

# _beads_changed <mid> <end> -> JSON array of paths whose state changed between them. Status 1
# when the compare could not run.
_beads_changed() {
  _beads_snaps changed '$s[0] as $a | $s[1] as $b
    | ([$a.dirty[].path] + [$b.dirty[].path] | unique) as $ps
    | [$ps[] | . as $p | select(ent($a; $p) != ent($b; $p))]' "$1" "$2"
}

# _beads_append_missing <target> <house-file>: append the house file's rule lines the target
# lacks, preceded by its comment lines and a blank separator. Existing bytes are never rewritten;
# lines use the target's own line ending. Returns 1 when nothing was missing.
_beads_append_missing() {
  local t="$1" src="$2" l last
  local -a com=() miss=()
  while IFS= read -r l || [ -n "$l" ]; do
    l="${l%$'\r'}"
    case "$l" in '') ;; '#'*) com+=("$l") ;; *) _beads_has_line "$t" "$l" || miss+=("$l") ;; esac
  done < "$src"
  [ "${#miss[@]}" -gt 0 ] || return 1
  if [ -s "$t" ]; then last="$(tail -n 1 "$t" | tr -d '\r')"; [ -n "$last" ] && append_line "$t" ""; fi
  for l in "${com[@]}" "${miss[@]}"; do append_line "$t" "$l"; done
  return 0
}

# _beads_unban_block <claude-md>: inside the FIRST managed block only, replace the two bd
# imperatives the house overrides. Every other byte, including each line's CR and a last line's
# missing line ending, is kept.
_beads_unban_block() {
  local f="$1" tmp line cr nl inb=0 done=0 n=0
  tmp="$(mktemp)" || return 1
  while :; do
    if IFS= read -r line; then nl=$'\n'
    elif [ -n "$line" ]; then nl=''
    else break; fi
    cr=""; [[ "$line" == *$'\r' ]] && { cr=$'\r'; line="${line%$'\r'}"; }
    [ "$done" = 0 ] && [[ "$line" == *"$_BEADS_MARKER"* ]] && inb=1
    if [ "$inb" = 1 ]; then
      if [[ "$line" == *"$_BEADS_BAN_TODO"* ]]; then line="$_BEADS_LINE_TODO"; n=$((n + 1))
      elif [[ "$line" == *"$_BEADS_BAN_MEM"* ]]; then line="$_BEADS_LINE_MEM"; n=$((n + 1)); fi
      [[ "$line" == *'END BEADS INTEGRATION'* ]] && { inb=0; done=1; }
    fi
    printf '%s%s%s' "$line" "$cr" "$nl"
  done < "$f" > "$tmp"
  [ "$n" -gt 0 ] && cat "$tmp" > "$f"
  rm -f "$tmp"
  echo "$n"
}

# _beads_status_paths <top> -> comma-joined paths git reports as changed or untracked.
_beads_status_paths() {
  git -C "$1" status --porcelain=v1 --untracked-files=all 2>/dev/null | cut -c4- | paste -sd ',' - | sed 's/,/, /g'
}

# fix beads <repo> [--stash]: the house bd setup. Refuses a dirty tree unless --stash, which sets
# the user's work aside (raw bytes, index included) around the steps where bd makes commits, gives
# it back with `stash apply --index`, and proves the restore against a fresh preflight on all of
# dirty (with XY), bytes and index before dropping the stash. On any mismatch the stash is kept.
fix_beads() {
  local repo="$1"; shift
  local stash=0 a
  for a in "$@"; do
    case "$a" in --stash) stash=1 ;; *) die "fix beads: unknown argument: $a" ;; esac
  done
  command -v bd >/dev/null 2>&1 || { emit beads unknown "bd not on PATH"; return 0; }
  local top; top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  # An interrupted earlier run can leave the user's work only in its stash; nothing may run on top
  # of that. Matched on the stash message alone ("On <branch>: <message>"; a branch name holds no
  # ':'), so a user's own "WIP on <branch>: <sha> <subject>" stash is never mistaken for it.
  local held
  held="$(git -C "$top" stash list --format='%gd %H %gs' 2>/dev/null | awk '{ s = $0; sub(/^[^ ]+ [^ ]+ /, "", s); sub(/^[^:]*: /, "", s) }
    s == "ritual-beads" { printf "%s%s (%s)", sep, $1, $2; sep = ", " }')"
  if [ -n "$held" ]; then
    local href="${held%% *}" hsha="${held%%)*}"; hsha="${hsha##*(}"
    emit beads failed "a previous run's stash is still held: $held; apply it in raw mode, exactly as the ritual does, with \`$(_beads_raw_apply_cmd "$top" "$hsha")\` (a plain \`git stash apply\` can change line endings), then \`git stash drop \"$href\"\` (the double quotes keep the braces intact in Git Bash, PowerShell and cmd; nothing was run)"
    return 0
  fi
  if [ "$(check_beads "$top" | jq -r .status)" = present ]; then
    # what the house setup writes or removes; .beads/ also carries the issues export, which once
    # committed changes with the user's own bd use and is no longer the ritual's to list
    local s; local -a skf=()
    for s in "${_RITUAL_SKIP_TRACKED[@]}"; do skf+=(--skip-tracked "$s"); done
    emit_already "${skf[@]}" beads "$top" "house beads setup already holds" \
      .beads .gitattributes CLAUDE.md AGENTS.md .codex .agents/skills/beads
    return 0
  fi

  local pre ndirty have_beads=0
  pre="$(preflight "$top")" || die "preflight failed in $top (working-tree state unknown)"
  ndirty="$(jq '.dirty | length' <<<"$pre" | tr -d '\r')"
  case "$ndirty" in ''|*[!0-9]*) die "preflight gave no dirty count in $top (working-tree state unknown)" ;; esac
  [ -d "$top/.beads" ] && have_beads=1
  if [ "$ndirty" -gt 0 ]; then
    [ "$stash" = 1 ] || { emit beads failed "dirty tree; re-run with --stash"; return 0; }
    local re='^\.beads/' coll
    [ "$have_beads" = 0 ] && re="$_BEADS_INIT_PATHS_RE"
    coll="$(jq -r --arg re "$re" '[.dirty[].path | select(test($re))] | unique | join(", ")' <<<"$pre")"
    if [ -n "$coll" ]; then
      emit beads failed "uncommitted changes to paths bd writes: $coll; commit or move them first (nothing was run)"
      return 0
    fi
    local ia; ia="$(git -C "$top" rev-parse --path-format=absolute --git-path info/attributes 2>/dev/null)"
    if [ -n "$ia" ] && [ -s "$ia" ]; then
      emit beads failed "$ia is not empty, and no git option sets it aside, so the stash round trip could change your bytes; empty it or commit your work first (nothing was run)"
      return 0
    fi
  fi

  local had_agents=0 had_codex=0 had_skill=0 had_marker=0 head0
  [ -e "$top/AGENTS.md" ] && had_agents=1
  [ -e "$top/.codex" ] && had_codex=1
  [ -e "$top/.agents/skills/beads" ] && had_skill=1
  _beads_has_marker "$top/CLAUDE.md" && had_marker=1
  head0="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)"
  local -a notes=() fails=()

  # --- set the user's work aside (raw bytes; untracked included)
  local sha="" before
  if [ "$ndirty" -gt 0 ]; then
    before="$(git -C "$top" rev-parse -q --verify refs/stash 2>/dev/null)"
    _beads_git_raw "$top" stash push -u -m ritual-beads >/dev/null 2>&1
    sha="$(git -C "$top" rev-parse -q --verify refs/stash 2>/dev/null)"
    if [ -z "$sha" ] || [ "$sha" = "$before" ]; then
      emit beads failed "git stash push did not create a stash; nothing was run"; return 0
    fi
    local still; still="$(_beads_status_paths "$top")"
    [ -z "$still" ] || fails+=("tree not clean after the stash ($still); bd was not run")
  fi

  # --- the steps where bd makes commits: init, then dropping the Dolt remote it wires to origin
  local out prefix left="" lo
  if [ "${#fails[@]}" -eq 0 ]; then
    if [ "$have_beads" = 0 ]; then
      prefix="$(basename "$top" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
      if [ -z "$prefix" ]; then
        fails+=("cannot derive an issue prefix from '$(basename "$top")'; bd init not run")
      else
        out="$(cd "$top" && bd init --non-interactive --prefix "$prefix" 2>&1)"
        if [ -f "$top/.beads/config.yaml" ] && [ -f "$top/.beads/metadata.json" ]; then
          notes+=("bd init (prefix $prefix)")
        else
          # with the user's work stashed, everything dirty now is bd's; the restore check excuses it
          lo="$(_beads_status_paths "$top")"
          fails+=("bd init failed: $(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -n 2 | paste -sd ' ' -) (leftovers: ${lo:-none}; nothing was removed)")
          [ -n "$sha" ] && { left="$(preflight "$top")" || left=""; }
        fi
      fi
    else
      notes+=("bd init skipped (.beads/ exists)")
    fi
  fi
  if [ "${#fails[@]}" -eq 0 ]; then
    (cd "$top" && bd dolt remote remove origin) >/dev/null 2>&1
    out="$(cd "$top" && bd dolt remote list 2>&1 | tr -d '\r')"
    if grep -qE '(^|[[:space:]])origin([[:space:]]|$)' <<<"$out"; then
      fails+=("a Dolt remote 'origin' is still configured after bd dolt remote remove origin")
    elif grep -qiE 'error|fail' <<<"$out"; then
      fails+=("bd dolt remote list could not answer: $(head -n 1 <<<"$out")")
    elif [ "$(grep -v '^[[:space:]]*$' <<<"$out")" != 'No remotes configured.' ]; then
      # bd 1.2.2's answer with no remotes, measured; anything else is not proof there is none
      notes+=("dolt remote state unverified: bd dolt remote list answered '$(head -n 1 <<<"$out")'")
    fi
  fi

  # --- give the work back, then prove it
  if [ -n "$sha" ]; then
    local aout arc post sdiff sdrc ref
    aout="$(_beads_git_raw "$top" stash apply --index "$sha" 2>&1)"; arc=$?
    post="$(preflight "$top")" || post='{"branch":"?","dirty":[],"bytes":{},"index":{}}'
    sdiff="$(_beads_snapdiff "$pre" "$post" "$left")"; sdrc=$?
    [ "$sdrc" -eq 0 ] || sdiff="unknown: the comparison itself failed, so nothing is proven"
    ref="$(_beads_stash_ref "$top" "$sha")"
    if [ "$arc" -eq 0 ] && [ "$sdrc" -eq 0 ] && [ -z "$sdiff" ]; then
      git -C "$top" stash drop -q "$ref" >/dev/null 2>&1
      if [ -n "$(_beads_stash_ref "$top" "$sha")" ]; then
        notes+=("your work was restored exactly, but its stash $ref could not be dropped")
      else
        notes+=("your uncommitted work was set aside and restored byte-for-byte")
      fi
    else
      fails+=("your uncommitted work was NOT restored exactly (apply exit $arc, differs: ${sdiff:-nothing}); it is kept in ${ref:-a stash} ($sha, 'ritual-beads') and was NOT dropped; the exact original applies onto a clean tree with \`$(_beads_raw_apply_cmd "$top" "$sha")\`")
    fi
  fi
  if [ "${#fails[@]}" -gt 0 ]; then
    emit beads failed "$(join_by '; ' "${fails[@]}" "${notes[@]}")"
    return 0
  fi

  # --- house steps on top of the user's own tree (no bd commits expected from here on)
  local head1 mid kv rc n
  head1="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)"
  mid="$(preflight "$top")" || die "preflight failed in $top"
  local -a late=()
  for kv in "${_BEADS_SETS[@]}"; do
    (cd "$top" && bd config set "${kv% *}" "${kv#* }") >/dev/null 2>&1
  done
  # `check` does not require the interval (user-level config may supply it), so read back here
  local iv; iv="$(_beads_cfg_get "$top/.beads/config.yaml" export.interval)"
  [ "$iv" = 1ms ] || late+=("export.interval is '${iv:-unset}' in .beads/config.yaml after bd config set (want 1ms)")
  # bd's pre-commit hook writes the issues export on every commit and stages nothing (measured, bd
  # 1.2.2), so the ritual's own commit would leave it untracked; exported now, it is in `wrote`.
  # Past the dirty-path gate, an existing one is tracked and clean, and the hook keeps it.
  if [ ! -e "$top/.beads/issues.jsonl" ]; then
    (cd "$top" && bd export -o .beads/issues.jsonl) >/dev/null 2>&1
    [ -f "$top/.beads/issues.jsonl" ] \
      || notes+=("bd export wrote no .beads/issues.jsonl; the first commit's hook will, and leave it untracked")
  fi
  if [ -e "$top/.beads/PRIME.md" ]; then notes+=("kept the existing .beads/PRIME.md")
  else cp "$_BEADS_HOUSE/PRIME.md" "$top/.beads/PRIME.md"; fi
  if [ ! -e "$top/.beads/check-block.sh" ]; then
    cp "$_BEADS_HOUSE/check-block.sh" "$top/.beads/check-block.sh"; chmod +x "$top/.beads/check-block.sh"
  fi
  _beads_append_missing "$top/.beads/.gitignore" "$_BEADS_HOUSE/gitignore"
  _beads_append_missing "$top/.gitattributes" "$_BEADS_HOUSE/gitattributes"
  git -C "$top" config core.hooksPath .beads/hooks
  if git -C "$top" ls-files --error-unmatch -- .beads/interactions.jsonl >/dev/null 2>&1; then
    git -C "$top" rm -q --cached -- .beads/interactions.jsonl
  fi
  if ! _beads_has_marker "$top/CLAUDE.md"; then
    (cd "$top" && bd setup claude) >/dev/null 2>&1
    notes+=("bd setup claude")
  fi
  if [ "$had_marker" = 0 ] && _beads_has_marker "$top/CLAUDE.md"; then
    n="$(_beads_unban_block "$top/CLAUDE.md")"
    [ "${n:-0}" -gt 0 ] && notes+=("replaced $n bd imperative(s) inside the new managed block")
  elif [ "$had_marker" = 1 ]; then
    notes+=("the managed block in CLAUDE.md pre-existed and was not edited")
  fi
  if ! grep -q "^$_BEADS_OVERRIDE_HEADING" "$top/CLAUDE.md" 2>/dev/null; then
    local l last
    if [ -s "$top/CLAUDE.md" ]; then
      last="$(tail -n 1 "$top/CLAUDE.md" | tr -d '\r')"; [ -n "$last" ] && append_line "$top/CLAUDE.md" ""
    fi
    while IFS= read -r l || [ -n "$l" ]; do append_line "$top/CLAUDE.md" "${l%$'\r'}"; done < "$_BEADS_OVERRIDE"
  fi
  if [ "$had_agents" = 0 ]; then
    [ -e "$top/AGENTS.md" ] && { rm -f "$top/AGENTS.md"; notes+=("removed bd's AGENTS.md"); }
  else
    notes+=("AGENTS.md existed before and was kept; check it for bd's TodoWrite ban")
  fi
  [ "$had_codex" = 0 ] && [ -e "$top/.codex" ] && rm -rf "$top/.codex"
  if [ "$had_skill" = 0 ] && [ -e "$top/.agents/skills/beads" ]; then
    rm -rf "$top/.agents/skills/beads"
    rmdir "$top/.agents/skills" 2>/dev/null && rmdir "$top/.agents" 2>/dev/null
  fi
  out="$(cd "$top" && sh .beads/check-block.sh CLAUDE.md 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && notes+=("check-block.sh ok")

  local fin end wrote head2
  local -a w=()
  end="$(preflight "$top")" || die "preflight failed in $top"
  if ! wrote="$(_beads_changed "$mid" "$end")"; then
    emit beads failed "could not work out which paths the house steps changed (the comparison failed), so none can be listed; $(join_by '; ' "${late[@]}" "${notes[@]}")"
    return 0
  fi
  mapfile -t w < <(jq -r '.[]' <<<"$wrote" | tr -d '\r')   # jq.exe ends lines with CRLF
  [ -n "$head0" ] && notes+=("bd commits: $(git -C "$top" rev-list --count "$head0..$head1" 2>/dev/null)")
  head2="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)"
  if [ "$head2" != "$head1" ]; then
    emit beads failed "a commit was made during the house steps (HEAD $head1 -> $head2); check it did not take staged changes; $(join_by '; ' "${late[@]}" "${notes[@]}")" "${w[@]}"
    return 0
  fi
  fin="$(check_beads "$top")"
  [ "$(jq -r .status <<<"$fin")" = present ] || late+=("after setup: $(jq -r .detail <<<"$fin")")
  if [ "${#late[@]}" -eq 0 ]; then
    emit beads fixed "$(join_by '; ' "${notes[@]}")" "${w[@]}"
  else
    emit beads failed "$(join_by '; ' "${late[@]}" "${notes[@]}")" "${w[@]}"
  fi
}
