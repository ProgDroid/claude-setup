#!/usr/bin/env bash
# Steps: public-sweep, ci; and the `candidates` subcommand (beads-seed items).
# Source this file; do not execute it. Needs common.sh sourced first.

# check_public_sweep: present = repo is PUBLIC (a one-time sweep is due); absent = PRIVATE or
# INTERNAL; unknown = no gh, no auth, no GitHub remote, any gh error or unrecognised value.
check_public_sweep() {
  local repo="$1" vis rc
  if ! command -v gh >/dev/null 2>&1; then
    emit public-sweep unknown "gh not installed; visibility not checked"; return 0
  fi
  vis="$(cd "$repo" && export GH_PROMPT_DISABLED=1 && run_timeout 10 gh repo view --json visibility -q .visibility 2>/dev/null)"; rc=$?
  vis="${vis//$'\r'/}"
  if [ "$rc" -eq 124 ]; then emit public-sweep unknown "gh timed out"; return 0; fi
  if [ "$rc" -ne 0 ]; then
    emit public-sweep unknown "gh could not report visibility (exit $rc)"; return 0
  fi
  case "$vis" in
    PUBLIC)           emit public-sweep present "repository is public; sweep for secrets and personal data" ;;
    PRIVATE|INTERNAL) emit public-sweep absent "repository is ${vis,,}" ;;
    *)                emit public-sweep unknown "unrecognised visibility: ${vis:-<empty>}" ;;
  esac
}

check_ci() {
  local repo="$1" f
  for f in "$repo"/.github/workflows/*.yml "$repo"/.github/workflows/*.yaml; do
    [ -f "$f" ] && { emit ci present "workflow found: ${f##*/}"; return 0; }
  done
  emit ci absent "no .github/workflows/*.y*ml"
}

# candidates <repo> -> {"items":[{"text","source":"<path>:<line>"}]}
# Unchecked "- [ ]" lines in tracked docs/**/plans/*.md, whole-word TODO/FIXME inside a comment
# (or a markdown list item / html comment) in tracked text files, and list items under a
# "## Open" heading in tracked docs/**/*.md. Vendored/generated paths are skipped, items over
# 200 chars are dropped. Sorted by path then line, deduped by text (first wins), capped at 50.
# Tracked files only: untracked and ignored are never read. Filenames reach awk via ENVIRON.
candidates() {
  local repo="$1" f
  {
    while IFS= read -r -d '' f; do
      F="$f" awk '{ sub(/\r$/, "") }
        match($0, /^[ \t]*[-*][ \t]+\[ \][ \t]*/) { t = substr($0, RLENGTH + 1); sub(/[ \t]+$/, "", t);
          if (t != "") printf "%s\t%d\t%s\n", ENVIRON["F"], NR, t }' "$repo/$f"
    done < <(git -C "$repo" ls-files -z -- ':(glob)docs/**/plans/*.md')
    while IFS= read -r -d '' f; do
      F="$f" awk '{ sub(/\r$/, "") }
        /^[ \t]*(```|~~~)/ { fence = !fence; next }
        fence { next }
        /^#+[ \t]/ { open = ($0 ~ /^##[ \t]+Open([ \t]|$)/); next }
        open && match($0, /^[ \t]*([-*+]|[0-9]+\.)[ \t]+/) { t = substr($0, RLENGTH + 1);
          sub(/^\[ \][ \t]*/, "", t)
          if (t ~ /^\[[xX]\]/) next
          sub(/[ \t]+$/, "", t); if (t != "") printf "%s\t%d\t%s\n", ENVIRON["F"], NR, t }' "$repo/$f"
    done < <(git -C "$repo" ls-files -z -- ':(glob)docs/**/*.md')
    while IFS= read -r -d '' f; do
      F="$f" awk '{ sub(/\r$/, "") }
        match($0, /(^|[^A-Za-z0-9_])(TODO|FIXME)([^A-Za-z0-9_]|$)/) {
          s = RSTART; l = RLENGTH
          kw = substr($0, s, l); lead = (kw ~ /^(TODO|FIXME)/) ? 0 : 1
          kwlen = (substr(kw, lead + 1) ~ /^TODO/) ? 4 : 5
          pre = substr($0, 1, s - 1 + lead)
          ismd = (ENVIRON["F"] ~ /\.(md|markdown)$/)
          if (ismd) good = (pre ~ /<!--/ || pre ~ /^[ \t]*([-*+]|[0-9]+\.)[ \t]/)
          else good = (pre ~ /(\/\/|\/\*|--|;|#)/ || pre ~ /^[ \t]*\*/)
          if (!good) next
          t = substr($0, s + lead + kwlen)
          sub(/^[ \t]*[:(][ \t]*/, "", t); sub(/^[ \t]+/, "", t)
          sub(/[ \t]*(\*\/|-->)[ \t]*$/, "", t); sub(/[ \t]+$/, "", t)
          if (t != "") printf "%s\t%d\t%s\n", ENVIRON["F"], NR, t }' "$repo/$f"
    done < <(git -C "$repo" grep -l -I -z -E 'TODO|FIXME' -- . \
      ':(exclude,glob)**/vendor/**' ':(exclude,glob)**/third_party/**' ':(exclude,glob)**/node_modules/**' \
      ':(exclude,glob)**/dist/**' ':(exclude,glob)**/build/**' ':(exclude,glob)**/target/**' \
      ':(exclude,glob)**/*.min.*' ':(exclude,glob)**/*.lock' ':(exclude,glob)**/*-lock.json' \
      ':(exclude,glob)**/*.lock.json' ':(exclude,glob)**/package-lock.json' ':(exclude,glob)**/pnpm-lock.yaml' \
      ':(exclude,glob)**/yarn.lock' ':(exclude,glob)**/Cargo.lock' ':(exclude,glob)**/*.map' 2>/dev/null)
  } | LC_ALL=C sort -t $'\t' -k1,1 -k2,2n -s \
    | jq -Rn '[inputs | split("\t") | {text: .[2], source: (.[0] + ":" + .[1])} | select((.text | length) <= 200)]
        | reduce .[] as $i ({seen: {}, out: []};
            if .seen[$i.text] then . else .seen[$i.text] = true | .out += [$i] end)
        | {items: (.out[:50])}' -c
}
