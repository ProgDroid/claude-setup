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

# ritual_commit <repo> --preflight <f> --message-file <f> [--include-dirty] -- <path>...
# The ritual's own commit, holding exactly <path>... and nothing the user staged. It is built in a
# scratch index (GIT_INDEX_FILE) seeded from HEAD (empty on an unborn branch):
#   - a path on disk that is not (ignored and missing from the real index) -> its work-tree
#     content, with the real index's mode when the real index holds the same blob;
#   - a path not on disk, or ignored and missing from the real index -> a deletion (a file `fix
#     beads` untracked and ignored stays untracked: `git add` would refuse it, `-f` would re-track it).
# `git commit` (not commit-tree) runs on that index: the hooks run as usual and the secret scan's
# `--staged` reads the scratch index through GIT_INDEX_FILE, and git updates the branch with its own
# old-value check. Afterwards the real index is set to the new HEAD for every path the commit
# changed (a hook may add one, as bd's export does). A path dirty at preflight is refused unless
# --include-dirty (the user confirmed it). On failure the ref and the real index are unchanged.
# -> fixed "committed <sha>: ..." | already "nothing to commit" | failed <cause>.
ritual_commit() {
  local repo="$1"; shift
  local pf="" msg="" incl=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --preflight) [ $# -ge 2 ] || die "commit: --preflight needs a file"; pf="$2"; shift 2 ;;
      --message-file) [ $# -ge 2 ] || die "commit: --message-file needs a file"; msg="$2"; shift 2 ;;
      --include-dirty) incl=1; shift ;;
      --) shift; break ;;
      *) die "commit: unknown argument: $1" ;;
    esac
  done
  [ -n "$pf" ] && [ -f "$pf" ] || die "commit: --preflight <preflight.json> is required"
  [ -n "$msg" ] && [ -s "$msg" ] || die "commit: --message-file <non-empty file> is required"
  [ $# -gt 0 ] || { emit commit already "no paths given; nothing to commit"; return 0; }
  msg="$(cd "$(dirname "$msg")" && pwd)/$(basename "$msg")"

  local dirty
  dirty="$(printf '%s\n' "$@" | jq -Rr --slurpfile pf "$pf" \
    '($pf[0].dirty | map(.path)) as $d | select(. as $x | $d | index($x))' | tr -d '\r' | paste -sd',' -)" \
    || die "commit: could not read $pf"
  if [ -n "$dirty" ] && [ "$incl" = 0 ]; then
    emit commit failed "dirty at preflight: ${dirty//,/, }; ask the user, then pass --include-dirty (nothing was committed)"
    return 0
  fi

  local top gd p
  top="$(git -C "$repo" rev-parse --show-toplevel)" || die "cannot resolve repo root: $repo"
  gd="$(git -C "$top" rev-parse --path-format=absolute --git-dir)" || die "cannot resolve the git dir: $repo"
  for p in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    if git -C "$top" rev-parse -q --verify "$p" >/dev/null 2>&1; then
      emit commit failed "$p exists (an operation is in progress); finish or abort it first (nothing was committed)"
      return 0
    fi
  done
  # From the scratch index's creation to the real index's sync, INT/TERM/HUP are recorded, not
  # obeyed (the secret-scan proof's pattern). One that arrives before `git commit` runs stops the
  # ritual before it commits; one that arrives after git moved the branch (a slow post-commit hook)
  # lets the index sync finish, so the real index never shows the committed paths as deleted. The
  # scratch index is removed either way, then the signal is re-raised as the exit status.
  _RC_SIG=""
  trap '_RC_SIG=INT' INT; trap '_RC_SIG=TERM' TERM; trap '_RC_SIG=HUP' HUP
  _ritual_commit_in "$top" "$gd" "$msg" "$@"
  trap - INT TERM HUP
  case "$_RC_SIG" in INT) exit 130 ;; TERM) exit 143 ;; HUP) exit 129 ;; esac
}

# _ritual_commit_in <top> <git-dir> <message-file> <path>...: ritual_commit's work, run while it
# records signals in _RC_SIG. Every return removes the scratch index.
_ritual_commit_in() {
  local top="$1" gd="$2" msg="$3"; shift 3
  local old p mode blob rmode rblob ti tree otree out crc new changed=()
  old="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)"; old="${old%$'\r'}"
  ti="$(mktemp "$gd/ritual-index.XXXXXX")" || die "mktemp failed in $gd"
  rm -f "$ti"   # git wants no file or a valid index; an empty file is neither
  _rc_fail() { rm -f "$ti" "$ti.lock"; emit commit failed "${_RC_SIG:+interrupted by SIG$_RC_SIG; }$1"; }

  local -x GIT_LITERAL_PATHSPECS=1   # every path below is literal, never a glob
  if [ -n "$old" ]; then GIT_INDEX_FILE="$ti" git -C "$top" read-tree "$old" || { _rc_fail "could not seed the scratch index from HEAD"; return 0; }
  else GIT_INDEX_FILE="$ti" git -C "$top" read-tree --empty || { _rc_fail "could not create the scratch index"; return 0; }; fi

  local ign
  for p in "$@"; do
    read -r rmode rblob _ < <(git -C "$top" ls-files -s -- "$p" | head -n 1)
    # check-ignore rejects the literal pathspec magic (fatal, 128), so it runs without it
    GIT_LITERAL_PATHSPECS=0 git -C "$top" check-ignore -q --no-index -- "$p" 2>/dev/null; ign=$?
    [ "$ign" -le 1 ] || { _rc_fail "could not tell whether $p is ignored (check-ignore exit $ign)"; return 0; }
    if { [ -e "$top/$p" ] || [ -L "$top/$p" ]; } && ! { [ -z "${rblob:-}" ] && [ "$ign" = 0 ]; }; then
      GIT_INDEX_FILE="$ti" git -C "$top" add -f -- "$p" 2>/dev/null || { _rc_fail "could not stage $p"; return 0; }
      read -r mode blob _ < <(GIT_INDEX_FILE="$ti" git -C "$top" ls-files -s -- "$p" | head -n 1)
      if [ -n "${rblob:-}" ] && [ "$rblob" = "${blob:-}" ] && [ "$rmode" != "$mode" ]; then
        GIT_INDEX_FILE="$ti" git -C "$top" update-index --cacheinfo "$rmode,$rblob,$p" || { _rc_fail "could not set the mode of $p"; return 0; }
      fi
    else
      GIT_INDEX_FILE="$ti" git -C "$top" rm -q --cached --ignore-unmatch -- "$p" >/dev/null || { _rc_fail "could not record the deletion of $p"; return 0; }
    fi
    rmode=""; rblob=""
  done

  tree="$(GIT_INDEX_FILE="$ti" git -C "$top" write-tree)" || { _rc_fail "could not write the scratch tree"; return 0; }
  if [ -n "$old" ]; then otree="$(git -C "$top" rev-parse "$old^{tree}")"; else otree="$(git -C "$top" hash-object -t tree /dev/null)"; fi
  if [ "${tree%$'\r'}" = "${otree%$'\r'}" ]; then rm -f "$ti"; emit commit already "nothing to commit: the paths already match HEAD"; return 0; fi
  [ -z "$_RC_SIG" ] || { _rc_fail "stopped before git commit ran; nothing was committed"; return 0; }

  # the hooks are the user's code: they get git's normal (glob) pathspecs, not the ritual's literal mode
  out="$(GIT_LITERAL_PATHSPECS=0 GIT_INDEX_FILE="$ti" git -C "$top" commit -q -F "$msg" 2>&1)"; crc=$?
  rm -f "$ti" "$ti.lock"
  # whether git made the commit is read from HEAD, not from the exit status: a signal can end git
  # after it moved the branch (its post-commit hook still running)
  new="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)"; new="${new%$'\r'}"
  if [ "$new" = "$old" ]; then
    _rc_fail "git commit failed, HEAD and the index are unchanged: $(printf '%s' "$out" | tr -d '\r' | grep -v '^[[:space:]]*$' | tail -n 3 | paste -sd'|' - | cut -c1-300)"
    return 0
  fi
  if [ "$(git -C "$top" rev-parse -q --verify "$new^" 2>/dev/null | tr -d '\r')" != "$old" ]; then
    emit commit failed "HEAD $new is not a child of $old after committing; check git log"; return 0
  fi
  # the real index: every path the commit changed now matches the new HEAD
  if [ -n "$old" ]; then mapfile -d '' -t changed < <(git -C "$top" diff-tree -r --no-renames --name-only -z "$old" "$new")
  else mapfile -d '' -t changed < <(git -C "$top" ls-tree -r --name-only -z "$new"); fi
  if [ "${#changed[@]}" -gt 0 ] && ! git -C "$top" reset -q "$new" -- "${changed[@]}" >/dev/null 2>&1; then
    if [ -n "$old" ]; then git -C "$top" update-ref -m "ritual commit: undo" HEAD "$old" "$new"
    else git -C "$top" update-ref -d HEAD "$new"; fi
    emit commit failed "could not update the index after committing; the commit was undone (HEAD is ${old:-unborn} again)"
    return 0
  fi
  local note=""
  [ "$crc" = 0 ] || note="; git commit exited $crc after making the commit"
  [ -z "$_RC_SIG" ] || note="$note; SIG$_RC_SIG arrived after git made the commit, so the index was synced before stopping"
  emit commit fixed "committed ${new:0:7}: ${#changed[@]} path(s)$note"
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
