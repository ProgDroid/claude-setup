#!/usr/bin/env bash
# Workspace state: preflight snapshot, commit plan, untracked-docs check. Source; do not execute.

# preflight <repo> -> {"branch","dirty":[{path,xy}],"bytes":{path:sha256|DELETED|NONFILE},"index":{path:blob|ABSENT}}
# Parsed from `status --porcelain=v1 -z --untracked-files=all`. A rename/copy record carries a
# second NUL field (the original path); both paths are recorded as dirty entries with the same XY.
# Fixed process count regardless of dirty-file count: one status, one batched sha256sum, one batched
# ls-files, one jq. A failing git is a die (exit 2), never an empty `dirty`.
preflight() {
  local repo="$1" top branch rec xy p orig tmp i h
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
  tmp="$(mktemp -d)" || die "mktemp failed"
  trap "rm -rf '$tmp'" EXIT

  git -C "$repo" status --porcelain=v1 -z --untracked-files=all > "$tmp/status" \
    || die "git status failed in $repo (working-tree state unknown)"

  local -a paths=() xys=()
  while IFS= read -r -d '' rec; do
    xy="${rec:0:2}"; p="${rec:3}"
    paths+=("$p"); xys+=("$xy")
    case "$xy" in
      R?|C?|?R|?C) IFS= read -r -d '' orig || true; paths+=("$orig"); xys+=("$xy") ;;
    esac
  done < "$tmp/status"

  # classify: regular files get hashed (one batch); other existing paths are NONFILE; absent = DELETED
  local -A hash=() blob=()
  : > "$tmp/files"
  for p in "${paths[@]}"; do
    if [ -f "$top/$p" ]; then printf '%s\0' "$p" >> "$tmp/files"
    elif [ -e "$top/$p" ] || [ -L "$top/$p" ]; then hash["$p"]=NONFILE
    else hash["$p"]=DELETED; fi
  done
  if [ -s "$tmp/files" ]; then
    (cd "$top" && xargs -0 sha256sum --zero < "$tmp/files") > "$tmp/sums" || die "sha256sum failed"
    while IFS= read -r -d "" rec; do p="${rec#* }"; hash["${p:1}"]="${rec%% *}"; done < "$tmp/sums"  # "<hash> <mode-char><path>"
  fi

  if [ "${#paths[@]}" -gt 0 ]; then
    printf '%s\0' "${paths[@]}" > "$tmp/all"
    (cd "$top" && xargs -0 git --literal-pathspecs ls-files -s -z -- < "$tmp/all") > "$tmp/idx" \
      || die "git ls-files failed in $repo (index state unknown)"
    local meta stage
    while IFS= read -r -d '' rec; do
      meta="${rec%%$'\t'*}"; p="${rec#*$'\t'}"; stage="${meta##* }"
      if [ "$stage" = 0 ]; then rec="${meta#* }"; blob["$p"]="${rec%% *}"; fi
    done < "$tmp/idx"
  fi

  # one jq pass over \x1f/\x1e-delimited records: path, xy, bytes, index
  : > "$tmp/rec"
  for i in "${!paths[@]}"; do
    p="${paths[$i]}"
    printf '%s\x1f%s\x1f%s\x1f%s\x1e' "$p" "${xys[$i]}" "${hash[$p]}" "${blob[$p]:-ABSENT}" >> "$tmp/rec"
  done
  jq -nc --arg br "$branch" --rawfile r "$tmp/rec" '
    ($r | split("\u001e") | map(select(length>0) | split("\u001f"))) as $recs
    | {branch:$br,
       dirty: [$recs[] | {path:.[0], xy:.[1]}],
       bytes: ([$recs[] | {(.[0]): .[2]}] | add // {}),
       index: ([$recs[] | {(.[0]): .[3]}] | add // {})}'
}

# commit_plan <repo> <preflight.json> <wrote.json> -> {"commit":[...],"ask":[...]}
# Paths the ritual wrote that were already dirty at preflight go to `ask`; the rest to `commit`.
commit_plan() {
  local pf="$2" wr="$3"
  [ -f "$pf" ] || die "preflight file not found: $pf"
  [ -f "$wr" ] || die "wrote file not found: $wr"
  jq -nc --slurpfile pf "$pf" --slurpfile wr "$wr" '
    ($pf[0].dirty | map(.path)) as $d
    | (reduce $wr[0][] as $x ([]; if index($x) then . else . + [$x] end)) as $w
    | {commit: [$w[] | select(. as $x | $d | index($x) | not)],
       ask:    [$w[] | select(. as $x | $d | index($x))]}'
}

# check_untracked_docs <repo> -> step-result. present = untracked, non-ignored files under docs/.
check_untracked_docs() {
  local repo="$1" f list=() detail
  while IFS= read -r -d '' f; do list+=("$f"); done \
    < <(git -C "$repo" ls-files --others --exclude-standard -z -- docs)
  if [ "${#list[@]}" -gt 0 ]; then
    detail="$(printf '%s, ' "${list[@]}")"; detail="${detail%, }"
    emit untracked-docs present "$detail"
  else
    emit untracked-docs absent "no untracked files under docs/"
  fi
}
