#!/usr/bin/env bash
# SessionStart hook (cloud only): warn about earlier cloud work that never
# landed, and surface switchboard's "wait for the PC" verdict.
#
# WHY: a cloud session's branch can sit on origin unmerged -- the session ran
# out of allowance, or was abandoned -- and the next session starts blind to
# it and redoes or collides with that work. Cloud branches are not only
# claude/*: any unmerged branch on origin counts, minus dependabot/*, this
# session's own branch, and anything already merged into the default branch.
#
# THE AUTHORITY is `git ls-remote --heads origin`, never local refs: a resumed
# clone holding only main and its own branch would otherwise list nothing.
#
# THE DEADLINE: the hook timeout is 30 s. Every network call runs under
# `timeout min(8, remaining)` against a 22 s overall budget, and a repo that
# cannot be checked in time gets an explicit "couldn't check ... (out of time)"
# line printed before the hook could be killed. An exhausted budget must never
# look like "nothing found".
#
# SAFETY NET: if a switchboard-state clone sits beside the project and its
# verdicts.tsv says `wait` for this project's owner/repo slug, say so.
#
# GATE: CLAUDE_CLOUD_SESSION=1 only. ALWAYS exits 0.

set -uo pipefail

[ "${CLAUDE_CLOUD_SESSION:-}" = "1" ] || exit 0

# EARLIER_CLOUD_WORK_BUDGET exists so the tests can exhaust the budget.
deadline=$(( $(date +%s) + ${EARLIER_CLOUD_WORK_BUDGET:-22} ))
work="$(mktemp -d 2>/dev/null)" || exit 0
trap 'rm -rf "$work"' EXIT

remaining() { echo $(( deadline - $(date +%s) )); }

# budget: seconds the next network call may take; empty when out of time.
budget() {
  local r
  r="$(remaining)"
  [ "$r" -lt 2 ] && return 1
  [ "$r" -gt 8 ] && r=8
  echo "$r"
}

# --- Which repos belong to this session (same set as auto-commit.sh) ---------
repos=()
add_children() {
  for d in "$1"/*/; do
    d="${d%/}"
    [ -e "$d/.git" ] && repos+=("$d")
  done
}
top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
if [ -n "$top" ]; then
  parent="$(dirname "$top")"
  if git -C "$parent" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    repos=("$top")
  else
    add_children "$parent"
    case " ${repos[*]} " in *" $top "*) ;; *) repos+=("$top") ;; esac
  fi
else
  add_children "$PWD"
fi

couldnt() { echo "switchboard: couldn't check $1 for earlier cloud branches ($2)."; }

# switchboard_line <repo>: the "wait for the PC" verdict, for `wait` only.
switchboard_line() {
  local repo="$1" sib="" url slug row reasons date
  if [ -f /home/user/switchboard-state/verdicts.tsv ]; then
    sib=/home/user/switchboard-state
  elif [ -f "$(dirname "$repo")/switchboard-state/verdicts.tsv" ]; then
    sib="$(dirname "$repo")/switchboard-state"
  fi
  [ -n "$sib" ] || return 0
  # config, not `remote get-url`: the latter expands insteadOf rewrites.
  url="$(git -C "$repo" config --get remote.origin.url 2>/dev/null)" || return 0
  # Shape-independent: the last two path segments, whatever the host or proxy
  # (https://github.com/o/r[.git][/], git@github.com:o/r.git,
  # http://user@127.0.0.1:PORT/git/o/r).
  slug="$(printf '%s\n' "$url" | sed -e 's#/*$##' -e 's/\.git$//' -e 's#/*$##' \
    | awk -F'[/:]' 'NF >= 2 { print $(NF-1) "/" $NF }')"
  [ -n "$slug" ] || return 0
  row="$(awk -F'\t' -v s="$slug" 'tolower($1) == tolower(s) && $3 == "wait" { print $1 "\t" $4; exit }' "$sib/verdicts.tsv")"
  [ -n "$row" ] || return 0
  local tab=$'\t'
  slug="${row%%"$tab"*}"   # the PC's spelling of the slug
  reasons="${row#*"$tab"}"
  date="$(git -C "$sib" log -1 --date=short --format=%cd 2>/dev/null)"
  # Every session carries the companions, so name the repo and keep theirs short.
  case "$(printf '%s' "${slug#*/}" | tr '[:upper:]' '[:lower:]')" in
    claude-setup)
      echo "switchboard: $slug (companion) is waiting for the PC; don't change it in this session (state as of ${date:-an unknown date})."
      return 0 ;;
  esac
  echo "switchboard: $slug must wait for the PC ($reasons), as of ${date:-an unknown date}."
}

# Network calls never prompt and never wait on ssh for input.
export GIT_TERMINAL_PROMPT=0

# check_repo <repo>: the branch check, then the local verdict. The verdict is
# printed on every path, so an unreachable or out-of-time origin never
# suppresses the "wait for the PC" warning.
check_repo() {
  [ "$(basename "$1")" = switchboard-state ] && return 0   # the data repo, not a project
  check_branches "$1"
  switchboard_line "$1"
  return 0
}

check_branches() {
  local repo="$1" name t rc default heads own line sha ref br sshv
  name="$(basename "$repo")"
  sshv="$(git -C "$repo" config --get core.sshCommand 2>/dev/null)"
  sshv="${sshv:-ssh} -o BatchMode=yes"

  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    couldnt "$name" "no origin remote"; return 0
  fi

  # 1. default branch name
  default="$(git -C "$repo" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  default="${default#origin/}"
  if [ -z "$default" ]; then
    for default in main master; do
      git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$default" && break
      default=""
    done
  fi

  # 2. the authoritative list
  t="$(budget)" || { couldnt "$name" "out of time"; return 0; }
  heads="$work/heads.$$"
  timeout "$t" git -C "$repo" -c "core.sshCommand=$sshv" ls-remote --heads origin >"$heads" 2>/dev/null
  rc=$?
  if [ "$rc" -eq 124 ]; then couldnt "$name" "out of time"; return 0; fi
  if [ "$rc" -ne 0 ]; then couldnt "$name" "origin unreachable"; return 0; fi
  if [ -z "$default" ]; then
    # fall back to whichever of main/master origin itself lists
    default="$(awk '$2 == "refs/heads/main" || $2 == "refs/heads/master" { sub("refs/heads/", "", $2); print $2; exit }' "$heads")"
  fi
  if [ -z "$default" ]; then couldnt "$name" "no default branch found"; return 0; fi
  # The default branch's REMOTE tip, not a possibly stale local ref.
  dsha="$(awk -v r="refs/heads/$default" '$2 == r { print $1; exit }' "$heads")"
  if [ -z "$dsha" ]; then couldnt "$name" "origin has no $default"; return 0; fi

  own="$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)"

  # 3. candidates: not the default, not dependabot, not our own branch
  cand="$work/cand.$$"
  awk -v d="refs/heads/$default" -v o="refs/heads/$own" \
    '$2 != d && $2 != o && $2 !~ /^refs\/heads\/dependabot\// { print $1 "\t" $2 }' "$heads" >"$cand"
  [ -s "$cand" ] || return 0

  # 4. a shallow clone cannot answer "is it merged"; unshallow first
  if [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    t="$(budget)" || { couldnt "$name" "out of time"; return 0; }
    if ! timeout "$t" git -C "$repo" -c "core.sshCommand=$sshv" fetch -q --filter=blob:none --unshallow origin >/dev/null 2>&1; then
      couldnt "$name" "shallow clone"; return 0
    fi
  fi

  # 5. fetch the tips missing locally (the default tip included)
  need=()
  git -C "$repo" cat-file -e "$dsha^{commit}" 2>/dev/null || need+=("refs/heads/$default")
  while IFS=$'\t' read -r sha ref; do
    git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || need+=("$ref")
  done <"$cand"
  if [ "${#need[@]}" -gt 0 ]; then
    t="$(budget)" || { couldnt "$name" "out of time"; return 0; }
    timeout "$t" git -C "$repo" -c "core.sshCommand=$sshv" fetch -q origin "${need[@]}" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 124 ]; then couldnt "$name" "out of time"; return 0; fi
    if [ "$rc" -ne 0 ]; then couldnt "$name" "fetch failed"; return 0; fi
  fi

  # 6. drop what is merged; describe the rest
  rows="$work/rows.$$"; : >"$rows"
  while IFS=$'\t' read -r sha ref; do
    br="${ref#refs/heads/}"
    git -C "$repo" cat-file -e "$sha^{commit}" 2>/dev/null || continue
    git -C "$repo" merge-base --is-ancestor "$sha" "$dsha" 2>/dev/null && continue
    n="$(git -C "$repo" rev-list --count "$dsha..$sha" 2>/dev/null)"
    meta="$(git -C "$repo" log -1 --date=short --format='%ct%x09%an%x09%cd%x09%s' "$sha" 2>/dev/null)"
    IFS=$'\t' read -r ct author day subject <<<"$meta"
    printf '%s\t- %s (%s commits, %s, %s): %s\n' "$ct" "$br" "${n:-?}" "$author" "$day" "$subject" >>"$rows"
  done <"$cand"

  if [ -s "$rows" ]; then
    total="$(wc -l <"$rows" | tr -d ' ')"
    echo "Earlier cloud work in $name that never landed on $default; look at it before starting anything that might overlap:"
    sort -t$'\t' -k1,1nr "$rows" | head -n 5 | cut -f2-
    [ "$total" -gt 5 ] && echo "…and $((total - 5)) more"
  fi
  return 0
}

for r in "${repos[@]}"; do
  check_repo "$r" || true
done

exit 0
