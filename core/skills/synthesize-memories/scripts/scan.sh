#!/usr/bin/env bash
# Emits a compact report over the Claude memory corpus. Does only decidable work:
# counting, matching, and filesystem checks. All judgement lives in SKILL.md.
set -eu

MEMORY_ROOT="${HOME}/.claude/projects"
MAP=""
THRESHOLD=60

while [ $# -gt 0 ]; do
  case "$1" in
    --memory-root) MEMORY_ROOT="$2"; shift 2 ;;
    --map)         MAP="$2"; shift 2 ;;
    --threshold)   THRESHOLD="$2"; shift 2 ;;
    *) printf 'scan: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -d "$MEMORY_ROOT" ] || { printf 'scan: memory root not found: %s\n' "$MEMORY_ROOT" >&2; exit 1; }
[ -n "$MAP" ] && [ -f "$MAP" ] || { printf 'scan: --map file required and must exist\n' >&2; exit 1; }

# Memory dirs to consider, in stable order.
DIRS="$(ls -1 "$MEMORY_ROOT" 2>/dev/null | sort)"

# Single-pass frontmatter extraction. Forking sed per (file, field) call is ~50ms
# on Windows Git Bash; with hundreds of memory files and several field lookups
# each, that adds up to minutes. Instead, walk every memory file once with awk
# and load name/description/type into associative arrays; fm_field below then
# becomes a pure array lookup.
declare -A FM_NAME FM_DESC FM_TYPE FM_PROJECT
FILES=()
for d in $DIRS; do
  mdir="$MEMORY_ROOT/$d/memory"
  [ -d "$mdir" ] || continue
  for f in "$mdir"/*.md; do
    [ -f "$f" ] || continue
    FILES+=("$f")
    FM_PROJECT["$f"]="$d"
  done
done

if [ "${#FILES[@]}" -gt 0 ]; then
  while IFS=$'\t' read -r ffile fname ftype fdesc; do
    FM_NAME["$ffile"]="$fname"
    FM_TYPE["$ffile"]="$ftype"
    FM_DESC["$ffile"]="$fdesc"
  done < <(awk '
    FNR==1 { f=0; n=""; d=""; t=""; nSeen=0; dSeen=0; tSeen=0 }
    FNR==1 && $0 == "---" { f=1; next }
    f && /^---$/ { print FILENAME "\t" n "\t" t "\t" d; f=0; nextfile }
    f {
      s=$0; sub(/^[ \t]+/, "", s)
      if (!nSeen && match(s, /^name:[ \t]*/))        { n = substr(s, RSTART+RLENGTH); nSeen=1 }
      else if (!dSeen && match(s, /^description:[ \t]*/)) { d = substr(s, RSTART+RLENGTH); dSeen=1 }
      else if (!tSeen && match(s, /^type:[ \t]*/))        { t = substr(s, RSTART+RLENGTH); tSeen=1 }
    }
  ' "${FILES[@]}")
fi

# Extract a frontmatter field. Handles the indented metadata block.
fm_field() { # file field
  case "$2" in
    name)        printf '%s' "${FM_NAME[$1]-}" ;;
    description) printf '%s' "${FM_DESC[$1]-}" ;;
    type)        printf '%s' "${FM_TYPE[$1]-}" ;;
  esac
}

project_root() { # memory_dir_name
  awk -F'\t' -v n="$1" '$1 == n { print $2; exit }' "$MAP"
}

printf '## INDEX SIZES\n'
printf '# project\thot_lines\tcold_tier\tover_threshold(%s)\n' "$THRESHOLD"
for d in $DIRS; do
  mdir="$MEMORY_ROOT/$d/memory"
  [ -d "$mdir" ] || continue
  if [ ! -f "$mdir/MEMORY.md" ]; then
    printf '%s\t-\t-\tSKIP: no MEMORY.md\n' "$d"
    continue
  fi
  lines="$(wc -l < "$mdir/MEMORY.md" | tr -d ' ')"
  cold="no"; [ -f "$mdir/MEMORY-history.md" ] && cold="yes"
  over="no"; [ "$lines" -gt "$THRESHOLD" ] && over="yes"
  printf '%s\t%s\t%s\t%s\n' "$d" "$lines" "$cold" "$over"
done

printf '\n## DEMOTE CANDIDATES\n'
printf '# Claude decides: finished-milestone record (demote) vs live "what next" pointer (keep hot).\n'
printf '# project\tfile\tdescription\n'
# Iterate the pre-parsed FILES/FM_* arrays directly (built above) instead of
# re-walking the filesystem and calling fm_field per file: fm_field is a pure
# array lookup now, but wrapping it in $(...) still forks a subshell to run
# it, which is the same ~50ms-per-fork cost this rewrite exists to avoid.
for f in "${FILES[@]}"; do
  base="${f##*/}"
  case "$base" in MEMORY.md|MEMORY-*.md) continue ;; esac
  type="${FM_TYPE[$f]-}"
  [ "$type" = "project" ] || continue
  desc="${FM_DESC[$f]-}"
  lower="${desc,,}"
  case "$lower" in
    *complete*|*shipped*|*done*|*closed*|*landed*|*merged*) ;;
    *) continue ;;
  esac
  printf '%s\t%s\t%s\n' "${FM_PROJECT[$f]}" "$base" "$desc"
done

printf '\n## SCOPE CANDIDATES\n'
printf '# Claude decides: universally true (promote to global CLAUDE.md) vs project-specific.\n'
printf '# project\ttype\tfile\tdescription\n'
for f in "${FILES[@]}"; do
  base="${f##*/}"
  case "$base" in MEMORY.md|MEMORY-*.md) continue ;; esac
  type="${FM_TYPE[$f]-}"
  case "$type" in
    user|feedback) ;;
    "") printf '%s\t?\t%s\tSKIP: missing or malformed type\n' "${FM_PROJECT[$f]}" "$base"; continue ;;
    *) continue ;;
  esac
  printf '%s\t%s\t%s\t%s\n' "${FM_PROJECT[$f]}" "$type" "$base" "${FM_DESC[$f]-}"
done

printf '\n## CLUSTERS\n'
printf '# Terms in >=3 memories spanning >=2 projects. Noisy output is fine; missed clusters are not.\n'
printf '# term\tmemories\tprojects\n'
printf '# Members omitted for size. To list a term'"'"'s members:\n'
printf '#   grep -li '"'"'<term>'"'"' "%s"/*/memory/*.md\n' "$MEMORY_ROOT"
SW="$(cd "$(dirname "$0")" && pwd)/stopwords.txt"

# Single awk pass over all (project, file, name+description) rows. Forking a
# subshell pipeline or grep-per-token per memory file (hundreds of files x
# many tokens each) is the same ~50ms-per-fork trap as fm_field above, just
# multiplied by token count instead of field count. awk does the lowercasing,
# tokenising, per-file dedup, and cross-project counting in one process.
for f in "${FILES[@]}"; do
  base="${f##*/}"
  case "$base" in MEMORY.md|MEMORY-*.md) continue ;; esac
  printf '%s\t%s\t%s %s\n' "${FM_PROJECT[$f]}" "$base" "${FM_NAME[$f]-}" "${FM_DESC[$f]-}"
done | awk -F'\t' -v swfile="$SW" '
  BEGIN {
    while ((getline line < swfile) > 0) { if (line != "") SW[line] = 1 }
    close(swfile)
  }
  {
    d = $1; base = $2; text = tolower($3)
    n = split(text, rawtoks, /[^a-z0-9]+/)
    delete seen
    for (i = 1; i <= n; i++) {
      tok = rawtoks[i]
      if (tok == "" || length(tok) < 4 || (tok in SW) || (tok in seen) || tok ~ /^[0-9]+$/) continue
      seen[tok] = 1
      mem[tok]++
      key = tok SUBSEP d
      if (!(key in seenproj)) { seenproj[key] = 1; proj[tok]++ }
    }
  }
  END {
    for (t in mem) if (mem[t] >= 3 && proj[t] >= 2)
      printf "%s\t%d\t%d\n", t, mem[t], proj[t]
  }
' | sort -k2,2nr

# Live-root lookup and a per-root basename index, built once up front. DEAD
# REFS below resolves roughly a thousand references across the corpus; a
# `find` per reference would fork a process per lookup (the same trap the
# rewrites above exist to avoid). Instead each live project root is walked
# exactly once (one `find` per unique root, ~20 total) and its file
# basenames cached in BN_INDEX so each reference resolves via array lookups
# only.
declare -A ROOT_OF
for d in $DIRS; do
  ROOT_OF["$d"]="$(project_root "$d")"
done

SEP=$'\x1f'
declare -A BN_INDEX SEEN_ROOT
for d in $DIRS; do
  root="${ROOT_OF[$d]}"
  [ -n "$root" ] && [ -d "$root" ] || continue
  [ -n "${SEEN_ROOT[$root]:-}" ] && continue
  SEEN_ROOT["$root"]=1
  # -prune stops descent; "-not -path" would only filter what gets printed,
  # not what gets walked. Pruned names are deliberately conservative: only
  # dirs that are definitionally not source (VCS internals, dependency
  # installs, interpreter/tool caches). Build outputs (target/, dist/,
  # build/) are NOT pruned - a legitimate reference can live there, and a
  # false "missing" report (user sent hunting a file that exists) is worse
  # than a slow scan.
  while IFS= read -r path; do
    bn="${path##*/}"
    BN_INDEX["$root$SEP$bn"]=1
  done < <(find "$root" \( -name .git -o -name node_modules -o -name .venv -o -name venv \
    -o -name __pycache__ -o -name .mypy_cache -o -name .pytest_cache -o -name .tox \
    -o -name .ruff_cache \) -prune -o -type f -print 2>/dev/null)
done

printf '\n## DEAD REFS\n'
printf '# A path is listed ONLY if the exact path AND a repo-wide basename search both fail.\n'
printf '# Projects with no live root are skipped: their refs are uncheckable, not missing.\n'
printf '# project\tfile\tmissing_path\n'

# Eligible memory files: skip the index/history aggregates and any file
# whose project has no live root (its refs are uncheckable, not missing).
DEADREF_FILES=()
for f in "${FILES[@]}"; do
  base="${f##*/}"
  case "$base" in MEMORY.md|MEMORY-*.md) continue ;; esac
  root="${ROOT_OF[${FM_PROJECT[$f]}]}"
  [ -n "$root" ] && [ -d "$root" ] || continue
  DEADREF_FILES+=("$f")
done

if [ "${#DEADREF_FILES[@]}" -gt 0 ]; then
  # One awk pass over every eligible file extracts backticked tokens shaped
  # like a checkable path, and dedups them per file - the single-fork-for-
  # the-whole-corpus pattern used by CLUSTERS above, instead of a grep
  # pipeline per memory file.
  #
  # A token qualifies only if it survives ALL of: no leading slash (kills
  # URL routes), no "://" (kills URLs), not hostname-shaped
  # (word.tld[/...]), no "...", no YYYY/MM-DD date placeholders, no
  # ALL-CAPS directory segment (checked on segments before the final
  # component only, so a bare filename like CLAUDE.md still survives), and
  # then either its basename is a known extension-less filename (Dockerfile,
  # Makefile, ...) or a bare dotfile (.env) - or it is not a bare ".ext"
  # token and ends in a known source/config extension. This is deliberately
  # narrow: the corpus has far more backticked non-paths (URLs, git refs,
  # code expressions, doc placeholders) than real paths, and a false
  # "missing" report costs more than a missed one.
  while IFS=$'\t' read -r ffile ref; do
    root="${ROOT_OF[${FM_PROJECT[$ffile]}]}"
    [ -e "$root/$ref" ] && continue
    # Mandatory second angle: basename search before declaring absence.
    bn="${ref##*/}"
    [ -n "${BN_INDEX[$root$SEP$bn]:-}" ] && continue
    printf '%s\t%s\t%s\n' "${FM_PROJECT[$ffile]}" "${ffile##*/}" "$ref"
  done < <(awk '
    FNR == 1 { delete seen }
    {
      line = $0
      while (match(line, /`[^`]*`/)) {
        tok = substr(line, RSTART + 1, RLENGTH - 2)
        line = substr(line, RSTART + RLENGTH)
        if (tok !~ /^[A-Za-z0-9_.\/-]+$/) continue
        if (tok ~ /^\//) continue
        if (tok ~ /:\/\//) continue
        if (tok ~ /^[a-z0-9-]+\.(com|io|co|org|net|dev|ai|app|sh)(\/|$)/) continue
        if (tok ~ /\.\.\./) continue
        if (tok ~ /YYYY/ || tok ~ /MM-DD/) continue
        # Whole-basename allowlist: conventional extension-less filenames
        # and dotfiles (.env) are checkable paths that would otherwise be
        # killed by the bare-dot-extension rule below or simply never match
        # the extension allowlist at all. Matched on the final path
        # segment, same scope as the ALL-CAPS directory check below, so
        # `docker/Dockerfile` qualifies same as a bare `Dockerfile`.
        nb = split(tok, bnparts, "/")
        bn = bnparts[nb]
        if (bn ~ /^(Dockerfile|Makefile|LICENSE|Procfile|Justfile|Rakefile|Gemfile|\.env)$/) {
          # allowed - skip the bare-dot-extension and extension-allowlist checks
        } else {
          if (tok ~ /^\.[A-Za-z0-9]+$/) continue
          if (tok !~ /\.(rs|py|ts|tsx|js|jsx|vue|dart|go|sh|ps1|toml|json|yaml|yml|md|base|sql|css|html|cfg|ini|txt|lock|rb|kt|swift|tf|tfvars|gradle|java|scala|env|conf|mk|bat|cmd)$/) continue
        }
        n = split(tok, parts, "/")
        capsdir = 0
        for (i = 1; i < n; i++) if (parts[i] ~ /^[A-Z_]+$/) { capsdir = 1; break }
        if (capsdir) continue
        if (tok in seen) continue
        seen[tok] = 1
        print FILENAME "\t" tok
      }
    }
  ' "${DEADREF_FILES[@]}")
fi

printf '\n## ORPHAN PROJECTS\n'
printf '# Memory dirs with no live project root. Report only; never auto-archive.\n'
printf '# project\tmemory_files\n'
declare -A PROJECT_FILE_COUNT
for f in "${FILES[@]}"; do
  d="${FM_PROJECT[$f]}"
  PROJECT_FILE_COUNT["$d"]=$(( ${PROJECT_FILE_COUNT[$d]:-0} + 1 ))
done
for d in $DIRS; do
  mdir="$MEMORY_ROOT/$d/memory"
  [ -d "$mdir" ] || continue
  root="${ROOT_OF[$d]}"
  [ -n "$root" ] && [ -d "$root" ] && continue
  printf '%s\t%s\n' "$d" "${PROJECT_FILE_COUNT[$d]:-0}"
done
