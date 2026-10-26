#!/usr/bin/env bash
# The fingerprint ledger: <git-common-dir>/ritual-ledger.json, one file for all of a clone's
# worktrees. Source; do not execute. It is never ritual.json and never writes it: the project
# dashboard reads ritual.json's existence, ritual_version and open_steps as the ritual's completion
# status, so that file keeps its one writer, record-write.
#
# {"entries":[{"path","worktree","fp","state"}]}. path is relative to the work tree's top; worktree
# is that top through path_norm (the key, so one tree never reads or changes another's entries); fp
# is ledger_fps's fingerprint of the raw bytes (a directory's is that of a manifest of the files
# under it, so a change to any of them changes the directory's fp); state is `shown` (a commit-plan offered it, and its run has not
# reached record-write: interrupted, or still running) or `declined` (the run ended without
# committing it). One entry per (path, worktree): the last writer wins.
# Written at three points: commit_plan (ledger_mark_shown), the ritual's commit (ledger_drop) and
# record_write (ledger_settle). Every write drops the entries of worktrees whose directory is gone,
# and goes through a temporary file and mv. A write prints at most one stderr line, and returns 1
# when it failed or left a path out; the callers keep their own result. Values reach jq on stdin,
# never as arguments (jq.exe's ~32 KB command line, and Git Bash rewriting /-leading arguments of
# native programs). A path holding a newline, a CR or one of the \x1d-\x1f separator bytes cannot
# be carried by those lines, so it is never recorded, dropped or settled: it is left out, and said so.
#
# A ledger file that opened and that jq rejected is moved to ritual-ledger.json.corrupt (replacing
# any older copy) and the ledger starts again from empty. One that could not be opened is left as
# it is and the write is skipped: an open failure says nothing about the bytes.
#
# Read at two points, both through ledger_verdicts' rerun rule: emit_already (a step's own paths
# that still differ from HEAD) and commit_plan (ledger_readback: this work tree's earlier entries).

# ledger_file <repo> -> <git-common-dir>/ritual-ledger.json (absolute). Exit 1 outside a repository.
ledger_file() {
  local g; g="$(git_common_dir "$1" 2>/dev/null)" && [ -n "$g" ] || return 1
  printf '%s/ritual-ledger.json\n' "${g%$'\r'}"
}

# the shape every reader gets: well-formed entries only, and only their four fields
_LEDGER_JQ_NORM='{entries: [(.entries // [])[] | objects
  | select([.path, .worktree, .fp, .state] | map(type == "string") | all) | {path, worktree, fp, state}]}'

# _ledger_load <file> -> its ledger, normalised, on one line. Exit 1 (printing nothing) when the
# file cannot be opened, 2 when it opened and is not a ledger (jq rejected it, or it is empty).
_ledger_load() {
  local fd out rc
  { exec {fd}<"$1"; } 2>/dev/null || return 1
  out="$(jq -c "if (.entries | type) == \"array\" then $_LEDGER_JQ_NORM else error(\"no entries\") end" <&"$fd" 2>/dev/null)"; rc=$?
  exec {fd}<&-
  [ "$rc" -eq 0 ] && [ -n "$out" ] || return 2
  printf '%s\n' "${out%$'\r'}"
}

# ledger_read <repo> -> {"entries":[...]} on one line; {"entries":[]} when there is no ledger.
# Exit 1, printing nothing, when the ledger exists and cannot be opened or read as one. Never
# changes or moves the file.
ledger_read() {
  local f; f="$(ledger_file "$1")" || return 1
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then printf '%s\n' '{"entries":[]}'; return 0; fi
  [ -f "$f" ] || return 1
  _ledger_load "$f" || return 1
}

# ledger_fps <top> <path>... -> one "<path>\t<fp>" line per <path>, in order. <path> is relative to
# the work tree top <top>. Every fp is of raw bytes (`git hash-object --no-filters`), so an
# attributes or autocrlf change cannot make an untouched path look changed:
#   a regular file: its blob id;
#   a directory: `dir:<id>`, <id> the blob id of its manifest: one NUL-ended "<fp> <path>" record
#     per path under it that git would show (tracked, or untracked and not ignored: `ls-files -co
#     --exclude-standard`), sorted by path, <fp> being the file's blob id, `nonfile` (a symlink, a
#     nested repository) or `unhashable` (a name holding a newline or a CR). A tracked file missing
#     from disk is left out, so deleting it changes the manifest. An empty directory, or one holding
#     only ignored files, gets the empty manifest's id;
#   a symlink, or any other existing path: `nonfile`; nothing there: `absent`.
# A fixed number of processes per call, however many paths and directories: for the files one
# hash-object; when there are directories, also one ls-files, one sort, one rev-parse, a temporary
# directory in the git dir and one more hash-object for all the manifests. Exit 1, printing
# nothing, when git cannot list or hash, or a <path> is empty or holds a newline or a CR (it would
# not fit on one line).
ledger_fps() {
  local top="$1" p d f out i j tmp gd; shift
  local -a reg=() h=() dirs=() under=()
  local -A fp=() seen=() ufp=()
  for p in "$@"; do
    case "$p" in ''|*[$'\n\r']*) return 1 ;; esac
    if [ -L "$top/$p" ]; then fp["$p"]=nonfile
    elif [ -f "$top/$p" ]; then [ -n "${seen[$p]:-}" ] || { reg+=("$p"); seen["$p"]=1; }
    elif [ -d "$top/$p" ]; then dirs+=("$p")
    elif [ -e "$top/$p" ]; then fp["$p"]=nonfile
    else fp["$p"]=absent; fi
  done
  if [ "${#dirs[@]}" -gt 0 ]; then   # what is under each directory, in one listing
    out="$(git -C "$top" --literal-pathspecs ls-files -co --exclude-standard -z -- "${dirs[@]%/}" 2>/dev/null \
      | LC_ALL=C sort -zu | tr '\0' '\036'; exit "${PIPESTATUS[0]}")" || return 1
    [ -z "$out" ] || mapfile -d $'\036' -t under < <(printf '%s' "$out")
    for f in "${under[@]}"; do
      case "$f" in *[$'\n\r']*) ufp["$f"]=unhashable; continue ;; esac
      if [ -L "$top/$f" ]; then ufp["$f"]=nonfile
      elif [ -f "$top/$f" ]; then [ -n "${seen[$f]:-}" ] || { reg+=("$f"); seen["$f"]=1; }
      elif [ -e "$top/$f" ]; then ufp["$f"]=nonfile
      fi                              # listed but not on disk: left out
    done
  fi
  if [ "${#reg[@]}" -gt 0 ]; then
    out="$(printf '%s\n' "${reg[@]}" | git -C "$top" hash-object --no-filters --stdin-paths 2>/dev/null)" || return 1
    mapfile -t h < <(printf '%s\n' "$out" | tr -d '\r')
    [ "${#h[@]}" -eq "${#reg[@]}" ] || return 1
    for i in "${!reg[@]}"; do fp["${reg[$i]}"]="${h[$i]}"; done
  fi
  if [ "${#dirs[@]}" -gt 0 ]; then   # each directory's manifest, then all the manifests in one call
    gd="$(git -C "$top" rev-parse --absolute-git-dir 2>/dev/null)" && gd="${gd%$'\r'}" && [ -n "$gd" ] || return 1
    tmp="$(mktemp -d "$gd/ritual-fp.XXXXXX" 2>/dev/null)" && [ -n "$tmp" ] || return 1
    for j in "${!dirs[@]}"; do
      d="${dirs[$j]%/}"; : > "$tmp/m$j"
      for f in "${under[@]}"; do
        [ "$d" = . ] || [ "${f#"$d"/}" != "$f" ] || continue
        if [ -n "${ufp[$f]:-}" ]; then printf '%s %s\0' "${ufp[$f]}" "$f" >> "$tmp/m$j"
        elif [ -n "${fp[$f]:-}" ]; then printf '%s %s\0' "${fp[$f]}" "$f" >> "$tmp/m$j"; fi
      done
    done
    out="$(for j in "${!dirs[@]}"; do printf '%s\n' "$tmp/m$j"; done \
      | git -C "$top" hash-object --no-filters --stdin-paths 2>/dev/null)" || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    mapfile -t h < <(printf '%s\n' "$out" | tr -d '\r')
    [ "${#h[@]}" -eq "${#dirs[@]}" ] || return 1
    for j in "${!dirs[@]}"; do fp["${dirs[$j]}"]="dir:${h[$j]}"; done
  fi
  for p in "$@"; do printf '%s\t%s\n' "$p" "${fp[$p]}"; done
}

# _ledger_badpath <path>: 0 when <path> cannot be carried in the ledger's records (see the header)
_ledger_badpath() { case "$1" in ''|*[$'\n\r\x1d\x1e\x1f']*) return 0 ;; esac; return 1; }

# _ledger_err <cause>: the one stderr line of a write that did not happen
_ledger_err() {
  if [ -n "${_LG_NOTE:-}" ]; then echo "ritual: ledger: $*; $_LG_NOTE; no new ledger was written" >&2
  else echo "ritual: ledger: $*; the ledger was not changed" >&2; fi
}

# _ledger_ctx <repo>: set _LG_TOP (git's spelling of the work tree top), _LG_WT (its key), _LG_F
# (the file), _LG_HAVE (1 when the file exists), _LG_CUR (its normalised JSON), and reset _LG_NOTE
# and _LG_SKIP. A file that jq rejects is moved aside (see the header; _LG_NOTE says so). Exit 1,
# after one stderr line, when the work tree or the file cannot be resolved, the file's place holds
# something else, or the file cannot be opened.
_ledger_ctx() {
  local rc
  _LG_NOTE=""; _LG_SKIP=0
  _LG_TOP="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" && _LG_TOP="${_LG_TOP%$'\r'}" && [ -n "$_LG_TOP" ] \
    || { _ledger_err "cannot resolve the work tree of $1"; return 1; }
  _LG_WT="$(path_norm "$_LG_TOP")"
  _LG_F="$(ledger_file "$_LG_TOP")" || { _ledger_err "cannot resolve the git dir of $_LG_TOP"; return 1; }
  _LG_HAVE=0; _LG_CUR='{"entries":[]}'
  if [ -e "$_LG_F" ] || [ -L "$_LG_F" ]; then
    [ -f "$_LG_F" ] || { _ledger_err "$_LG_F is not a regular file"; return 1; }
    _LG_HAVE=1
    _LG_CUR="$(_ledger_load "$_LG_F")"; rc=$?
    case "$rc" in
      0) ;;
      1) _LG_CUR='{"entries":[]}'; _ledger_err "could not open $_LG_F"; return 1 ;;
      *) _LG_CUR='{"entries":[]}'
         mv -f "$_LG_F" "$_LG_F.corrupt" 2>/dev/null \
           || { _ledger_err "$_LG_F could not be parsed, and could not be moved aside"; return 1; }
         _LG_NOTE="$_LG_F could not be parsed, so its bytes were moved to $_LG_F.corrupt" ;;
    esac
  fi
}

# _ledger_op <op> <worktree> <path> [<state> <fp>] -> one record for _ledger_save, appended to _LG_OPS.
# op: set (upsert (path, worktree)), drop (remove it), dead (remove every entry of <worktree>).
_ledger_op() { _LG_OPS+="$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"${4:-}"$'\x1f'"${5:-}"$'\x1e'; }

# _ledger_save: apply _LG_OPS to _LG_CUR, after a `dead` op for every other worktree whose directory
# no longer exists, and replace _LG_F through a temporary file. Exit 1 when that fails.
_ledger_save() {
  local w tmp="$_LG_F.tmp.$$"
  local -a wts=()
  mapfile -d '' -t wts < <(printf '%s' "$_LG_CUR" | jq -j '[.entries[].worktree] | unique | .[] | . + "\u0000"' 2>/dev/null)
  for w in "${wts[@]}"; do
    [ "$w" = "$_LG_WT" ] || [ -d "$w" ] || _ledger_op dead "$w" ""
  done
  { printf '%s\x1d' "$_LG_CUR"; printf '%s' "$_LG_OPS"; } | jq -Rsc '
    split("\u001d") as $parts
    | ($parts[0] | fromjson | .entries) as $e
    | ($parts[1:] | join("\u001d") | split("\u001e") | map(select(length > 0) | split("\u001f"))) as $ops
    | reduce $ops[] as $o ($e;
        if $o[0] == "dead" then map(select(.worktree != $o[1]))
        else map(select((.worktree == $o[1] and .path == $o[2]) | not))
          + (if $o[0] == "set" then [{path: $o[2], worktree: $o[1], fp: $o[4], state: $o[3]}] else [] end)
        end)
    | {entries: .}' > "$tmp" 2>/dev/null && [ -s "$tmp" ] && mv -f "$tmp" "$_LG_F" 2>/dev/null \
    || { rm -f "$tmp"; return 1; }
}

# _ledger_finish: _ledger_save, then at most one stderr line: the failure, or what the write did
# that the caller should know (a corrupt file moved aside, paths left out). Exit 1 when the save
# failed or a path was left out.
_ledger_finish() {
  local -a m=()
  _ledger_save || { _ledger_err "could not write $_LG_F"; return 1; }
  [ -z "$_LG_NOTE" ] || m+=("$_LG_NOTE, and the ledger was started again")
  [ "$_LG_SKIP" -eq 0 ] || m+=("left out $_LG_SKIP path(s) holding a newline, a CR or a separator byte")
  [ "${#m[@]}" -gt 0 ] || return 0
  echo "ritual: ledger: $(join_by '; ' "${m[@]}")" >&2
  [ "$_LG_SKIP" -eq 0 ]
}

# ledger_mark_shown <repo> <path>...: record each <path> as `shown` at its current fingerprint, for
# this work tree (commit-plan: every path it puts in `commit` or `ask`). No paths: nothing is written.
ledger_mark_shown() {
  local repo="$1" fps line p; shift
  local -a ok=()
  [ $# -gt 0 ] || return 0
  _ledger_ctx "$repo" || return 1
  for p in "$@"; do
    if _ledger_badpath "$p"; then _LG_SKIP=$((_LG_SKIP + 1)); else ok+=("$p"); fi
  done
  _LG_OPS=""
  if [ "${#ok[@]}" -gt 0 ]; then
    fps="$(ledger_fps "$_LG_TOP" "${ok[@]}")" || { _ledger_err "could not fingerprint the plan's paths"; return 1; }
    while IFS= read -r line; do
      _ledger_op set "$_LG_WT" "${line%$'\t'*}" shown "${line##*$'\t'}"
    done <<<"$fps"
  fi
  _ledger_finish
}

# ledger_drop <repo> <path>...: remove this work tree's entries for <path>... (the ritual's commit,
# for the paths it was given, once they are committed or already match HEAD). No ledger: nothing.
ledger_drop() {
  local repo="$1" p; shift
  [ $# -gt 0 ] || return 0
  _ledger_ctx "$repo" || return 1
  [ "$_LG_HAVE" = 1 ] || return 0
  _LG_OPS=""
  for p in "$@"; do
    if _ledger_badpath "$p"; then _LG_SKIP=$((_LG_SKIP + 1)); else _ledger_op drop "$_LG_WT" "$p"; fi
  done
  _ledger_finish
}

# ledger_settle <repo> <commit-result>: record-write's half. When <commit-result> (the recorded
# result of the run's commit step) is declined, done or already, the run is over: this work tree's
# `shown` entries that are still not clean become `declined` at their current fingerprint, and the
# clean ones are dropped. Clean: `git status --porcelain=v1 --untracked-files=all -- <path>` prints
# nothing (one batched call; an index-only change such as `git rm --cached` is not clean). Any other
# result (failed, unknown, interrupted, empty) changes nothing: a commit that failed is not a no, so
# those entries stay `shown` and the next run offers them. No ledger: nothing. An entry whose path
# the ledger cannot carry (a hand edit) is left as it is.
ledger_settle() {
  case "${2:-}" in declined|done|already) ;; *) return 0 ;; esac
  _ledger_ctx "$1" || return 1
  [ "$_LG_HAVE" = 1 ] || return 0
  local rec p w s d out line i f
  local -a cand=() candw=() keep=() keepw=() dirty=()
  local -A isdirty=() fpof=()
  while IFS= read -r -d '' rec; do
    p="${rec%%$'\x1f'*}"; rec="${rec#*$'\x1f'}"; w="${rec%%$'\x1f'*}"; s="${rec#*$'\x1f'}"
    [ "$w" = "$_LG_WT" ] && [ "$s" = shown ] || continue
    if _ledger_badpath "$p"; then _LG_SKIP=$((_LG_SKIP + 1)); continue; fi
    cand+=("$p"); candw+=("$w")
  done < <(printf '%s' "$_LG_CUR" | jq -j '.entries[] | [.path, .worktree, .state] | join("\u001f") + "\u0000"' 2>/dev/null)
  _LG_OPS=""
  if [ "${#cand[@]}" -gt 0 ]; then
    out="$(pending_paths "$_LG_TOP" "${cand[@]}" | tr '\0' '\036'; exit "${PIPESTATUS[0]}")" \
      || { _ledger_err "git status failed in $_LG_TOP"; return 1; }
    [ -z "$out" ] || mapfile -d $'\036' -t dirty < <(printf '%s' "$out")
    for d in "${dirty[@]}"; do isdirty["$d"]=1; done
    for i in "${!cand[@]}"; do
      p="${cand[$i]}"
      if [ -z "${isdirty[$p]:-}" ]; then
        for d in "${dirty[@]}"; do [ "${d#"$p"/}" != "$d" ] && { isdirty["$p"]=1; break; }; done
      fi
      if [ -n "${isdirty[$p]:-}" ]; then keep+=("$p"); keepw+=("${candw[$i]}")
      else _ledger_op drop "${candw[$i]}" "$p"; fi
    done
    if [ "${#keep[@]}" -gt 0 ]; then
      out="$(ledger_fps "$_LG_TOP" "${keep[@]}")" || { _ledger_err "could not fingerprint the declined paths"; return 1; }
      while IFS= read -r line; do fpof["${line%$'\t'*}"]="${line##*$'\t'}"; done <<<"$out"
      for i in "${!keep[@]}"; do
        f="${fpof[${keep[$i]}]:-}"
        if [ -n "$f" ]; then _ledger_op set "${keepw[$i]}" "${keep[$i]}" declined "$f"; else _LG_SKIP=$((_LG_SKIP + 1)); fi
      done
    fi
  fi
  _ledger_finish
}

# What emit_already and commit_plan say of a path whose bytes changed since the ritual showed it:
# it is still the ritual's to offer, and it carries the user's own edits with it.
LEDGER_NOTE='also holds edits the ritual did not make'

# ledger_verdicts <repo> <path>... -> one "<path>\t<verdict>" line per <path>, in order: the rerun
# rule. <path> is relative to the work tree's top. The verdict, first match wins:
#   silent      a path in _RITUAL_SKIP_TRACKED that git tracks (its changes are the user's data)
#   clean       git status prints nothing for it or for anything under it
#   (entry)     this work tree's entry: unchanged since its fingerprint and `shown` -> offer (its
#               run never answered: interrupted, or its commit failed); unchanged and `declined` ->
#               silent (quiet until it changes); changed -> offer-note
#   (no entry)  untracked -> offer (a pre-0.16 leftover, a model file from a run that died before
#               step 6); tracked -> silent (the user's own edit; accepted: also a tracked leftover
#               of a run that died before commit-plan)
# One ledger read, one git status and at most one ledger_fps per call. A path the ledger cannot
# carry (_ledger_badpath) reaches neither and gets no line: a caller reads a missing line as
# `offer`. A ledger that exists and cannot be opened or parsed gives every changed path `offer`
# (the rule before 0.16), with one stderr line; it is never moved here. Exit 1, printing nothing,
# when git cannot resolve the work tree or answer the status.
ledger_verdicts() { _ledger_verdicts "$1" paths "${@:2}"; }

# ledger_readback <repo> -> "<path>\t<verdict>" for each of this work tree's entries whose verdict
# is offer or offer-note, in ledger order (commit-plan adds them to its plan). Exit 1 when git
# cannot answer, 2 when the ledger cannot be opened or parsed; neither prints anything.
ledger_readback() { _ledger_verdicts "$1" entries; }

# _ledger_verdicts <repo> paths <path>... | <repo> entries: the two functions above
_ledger_verdicts() {
  local repo="$1" mode="$2"; shift 2
  local top wt cur unread=0 fpfail=0 rec p w f s d v out line i
  local -a args=() ok=() hp=() rp=() rx=()
  local -A est=() efp=() pst=() cfp=() asked=() sk=()
  top="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" && top="${top%$'\r'}" && [ -n "$top" ] || return 1
  wt="$(path_norm "$top")"
  cur="$(ledger_read "$top")" || { cur='{"entries":[]}'; unread=1; }
  [ "$mode" = entries ] && [ "$unread" = 1 ] && return 2
  while IFS= read -r -d '' rec; do
    p="${rec%%$'\x1f'*}"; rec="${rec#*$'\x1f'}"; w="${rec%%$'\x1f'*}"; rec="${rec#*$'\x1f'}"
    f="${rec%%$'\x1f'*}"; s="${rec#*$'\x1f'}"
    [ "$w" = "$wt" ] || continue
    _ledger_badpath "$p" && continue
    est["$p"]="$s"; efp["$p"]="$f"
    [ "$mode" = entries ] && args+=("$p")
  done < <(printf '%s' "$cur" | jq -j '.entries[] | [.path, .worktree, .fp, .state] | join("\u001f") + "\u0000"' 2>/dev/null)
  [ "$mode" = entries ] || args=("$@")
  for p in "${args[@]}"; do _ledger_badpath "$p" || { ok+=("$p"); asked["$p"]=1; }; done
  if [ "${#ok[@]}" -gt 0 ]; then
    out="$(git -C "$top" --no-optional-locks --literal-pathspecs status --porcelain=v1 -z --no-renames \
      --untracked-files=all -- "${ok[@]}" 2>/dev/null | tr '\0' '\036'; exit "${PIPESTATUS[0]}")" || return 1
    while IFS= read -r -d $'\036' rec; do
      p="${rec:3}"; rp+=("$p"); rx+=("${rec:0:2}")
      if [ "${rec:0:2}" = '??' ]; then [ -n "${pst[$p]:-}" ] || pst["$p"]=u; else pst["$p"]=t; fi
    done <<<"$out"
    for p in "${ok[@]}"; do   # a path git did not name itself: what is under it (a directory)
      [ -z "${pst[$p]:-}" ] || continue
      s=clean
      for i in "${!rp[@]}"; do
        d="${rp[$i]}"; [ "${d#"$p"/}" != "$d" ] || continue
        if [ "${rx[$i]}" != '??' ]; then s=t; elif [ "$s" = clean ]; then s=u; fi
      done
      pst["$p"]="$s"
    done
    for p in "${_RITUAL_SKIP_TRACKED[@]}"; do
      [ -n "${asked[$p]:-}" ] || continue
      git -C "$top" --literal-pathspecs ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && sk["$p"]=1
    done
    for p in "${ok[@]}"; do
      [ -z "${sk[$p]:-}" ] && [ "${pst[$p]}" != clean ] && [ -n "${est[$p]+x}" ] && hp+=("$p")
    done
    if [ "${#hp[@]}" -gt 0 ]; then
      if out="$(ledger_fps "$top" "${hp[@]}")"; then
        while IFS= read -r line; do cfp["${line%$'\t'*}"]="${line##*$'\t'}"; done <<<"$out"
      else fpfail=1; fi
    fi
  fi
  for p in "${args[@]}"; do
    _ledger_badpath "$p" && continue
    if [ -n "${sk[$p]:-}" ]; then v=silent
    elif [ "${pst[$p]}" = clean ]; then v=clean
    elif [ "$unread" = 1 ]; then v=offer
    elif [ -n "${est[$p]+x}" ]; then
      f="${cfp[$p]:-}"
      if [ -z "$f" ]; then v=offer
      elif [ "$f" != "${efp[$p]}" ]; then v=offer-note
      elif [ "${est[$p]}" = declined ]; then v=silent
      else v=offer; fi
    elif [ "${pst[$p]}" = u ]; then v=offer
    else v=silent; fi
    [ "$mode" = entries ] && [ "${v#offer}" = "$v" ] && continue
    printf '%s\t%s\n' "$p" "$v"
  done
  [ "$unread" = 0 ] || echo "ritual: ledger: could not read $(ledger_file "$top"); every changed path is offered, as before 0.16" >&2
  [ "$fpfail" = 0 ] || echo "ritual: ledger: could not fingerprint the paths it holds in $top; they are offered" >&2
  return 0
}
