#!/usr/bin/env bash
# Workspace state: preflight snapshot, commit plan, untracked-docs check. Source; do not execute.

# preflight <repo> -> {"branch","dirty":[{path,xy}],"bytes":{path:sha256|DELETED},"index":{path:blob|ABSENT}}
# Parsed from `status --porcelain=v1 -z --untracked-files=all`. A rename/copy record carries a
# second NUL field (the original path); both paths are recorded as dirty entries with the same XY.
preflight() {
  local repo="$1" top branch rec xy p orig
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)"
  local dirty='[]' bytes='{}' index='{}'
  local -a paths=() xys=()
  while IFS= read -r -d '' rec; do
    xy="${rec:0:2}"; p="${rec:3}"
    paths+=("$p"); xys+=("$xy")
    case "$xy" in
      R?|C?|?R|?C) IFS= read -r -d '' orig || true; paths+=("$orig"); xys+=("$xy") ;;
    esac
  done < <(git -C "$repo" status --porcelain=v1 -z --untracked-files=all)

  local i h b
  for i in "${!paths[@]}"; do
    p="${paths[$i]}"; xy="${xys[$i]}"
    dirty="$(jq -c --arg p "$p" --arg x "$xy" '. + [{path:$p, xy:$x}]' <<<"$dirty")"
    if [ -f "$top/$p" ]; then h="$(sha256sum "$top/$p" | cut -d' ' -f1)"; else h=DELETED; fi
    bytes="$(jq -c --arg p "$p" --arg h "$h" '. + {($p):$h}' <<<"$bytes")"
    b="$(git --literal-pathspecs -C "$repo" ls-files -s -- "$top/$p" | awk -F'[ \t]' '$3==0{print $2; exit}')"
    [ -n "$b" ] || b=ABSENT
    index="$(jq -c --arg p "$p" --arg b "$b" '. + {($p):$b}' <<<"$index")"
  done
  jq -nc --arg br "$branch" --argjson d "$dirty" --argjson by "$bytes" --argjson ix "$index" \
    '{branch:$br, dirty:$d, bytes:$by, index:$ix}'
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
