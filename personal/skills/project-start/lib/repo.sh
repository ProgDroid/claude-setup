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
  vis="$(cd "$repo" && gh repo view --json visibility -q .visibility 2>/dev/null)"; rc=$?
  vis="${vis//$'\r'/}"
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
# Unchecked "- [ ]" lines in tracked docs/**/plans/*.md, TODO/FIXME in tracked text files, and
# bullets under a "## Open" heading in tracked docs/**/*.md. Sorted by path then line, deduped
# by text (first wins), capped at 50. Tracked files only: untracked and ignored are never read.
candidates() {
  local repo="$1" f
  {
    while IFS= read -r -d '' f; do
      awk -v F="$f" '{ sub(/\r$/, "") }
        match($0, /^[ \t]*[-*][ \t]+\[ \][ \t]*/) { t = substr($0, RLENGTH + 1); sub(/[ \t]+$/, "", t);
          if (t != "") printf "%s\t%d\t%s\n", F, NR, t }' "$repo/$f"
    done < <(git -C "$repo" ls-files -z -- ':(glob)docs/**/plans/*.md')
    while IFS= read -r -d '' f; do
      awk -v F="$f" '{ sub(/\r$/, "") }
        /^#+[ \t]/ { open = ($0 ~ /^##[ \t]+Open/); next }
        open && match($0, /^[ \t]*[-*][ \t]+/) { t = substr($0, RLENGTH + 1);
          sub(/^\[ \][ \t]*/, "", t)
          if (t ~ /^\[[xX]\]/) next
          sub(/[ \t]+$/, "", t); if (t != "") printf "%s\t%d\t%s\n", F, NR, t }' "$repo/$f"
    done < <(git -C "$repo" ls-files -z -- ':(glob)docs/**/*.md')
    while IFS= read -r -d '' f; do
      awk -v F="$f" '{ sub(/\r$/, "") }
        match($0, /TODO|FIXME/) { t = substr($0, RSTART + RLENGTH); sub(/^[ \t]*:?[ \t]*/, "", t); sub(/[ \t]+$/, "", t)
          if (t != "") printf "%s\t%d\t%s\n", F, NR, t }' "$repo/$f"
    done < <(git -C "$repo" grep -l -I -z -E 'TODO|FIXME' 2>/dev/null)
  } | LC_ALL=C sort -t $'\t' -k1,1 -k2,2n -s \
    | jq -Rn '[inputs | split("\t") | {text: .[2], source: (.[0] + ":" + .[1])}]
        | reduce .[] as $i ({seen: {}, out: []};
            if .seen[$i.text] then . else .seen[$i.text] = true | .out += [$i] end)
        | {items: (.out[:50])}' -c
}
