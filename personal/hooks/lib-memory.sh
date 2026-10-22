#!/usr/bin/env bash
# Shared memory-sync helpers. Sourced by hydrate-memory.sh, sync-memory.sh and
# auto-commit.sh so the project-key derivation exists in exactly one place.
#
# Not executable on its own.

# memory_key <abs-path> -> the directory name under ~/.claude/projects/
#
# The rule (Claude Code's own; core/hooks/test-lib-key.sh pins literal keys and
# core/tests/test-key-parity.sh keeps the twins equal): backslashes become '/', a
# Git Bash drive form '/x/rest' (SINGLE-letter first segment only) or 'x:/rest' becomes 'X:/rest',
# then every character that is not [A-Za-z0-9] becomes '-'. So an underscore, a dot or a space all
# key as '-':
#
#   Linux / cloud VM   /home/user/repo        -> -home-user-repo
#   Windows via MSYS   /g/rustDev/aba         -> G--rustDev-aba
#   Windows, git form  G:/a/b  or  G:\a\b     -> G--a-b
#   a mktemp dir       /tmp/tmp.CYKwCSUeAA    -> -tmp-tmp-CYKwCSUeAA
#
# The '/x/rest' rewrite runs ONLY where `uname -s` is MINGW*/MSYS*/CYGWIN*: there it undoes the
# shell's drive mapping. On Linux '/a/repo' is a real path and keys as '-a-repo'.
#
# History worth keeping: both production callers (sync-memory.sh, auto-commit.sh) derive the root
# from `git rev-parse --show-toplevel`, which on Git Bash is the WINDOWS form G:/a/b, not /g/a/b.
# A key built without folding that form held a colon, no such directory could exist, and both hooks
# no-opped in silence for days (found 2026-09-05). An earlier version also left '.', '+' and '@'
# untouched, so a dotted path (every mktemp dir, every <repo>/.claude/worktrees/<n>) keyed to a
# directory nothing reads. Getting this wrong is silent, hence the direct test coverage.
#
# This is the TWIN of core_memory_key in core/hooks/lib-key.sh (the plugins install separately, so
# personal cannot source it); core/tests/test-key-parity.sh keeps the two equal. Change both.
#
# Prints the key with no trailing newline; returns 1, printing nothing, on empty input.
memory_key() {
  _p="${1:-}"
  [ -n "$_p" ] || return 1
  _p="${_p//$'\n'/-}"   # one path: an embedded newline keys to '-' like any other character
  _msys=0
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) _msys=1 ;; esac
  printf '%s\n' "$_p" | LC_ALL=C awk -v msys="$_msys" '
    {
      p = $0
      gsub(/[\\]/, "/", p)
      if (msys == 1 && match(p, /^\/[A-Za-z](\/|$)/)) {
        rest = substr(p, 3); if (rest == "") rest = "/"
        p = toupper(substr(p, 2, 1)) ":" rest
      } else if (match(p, /^[A-Za-z]:(\/|$)/)) {
        rest = substr(p, 3); if (rest == "") rest = "/"
        p = toupper(substr(p, 1, 1)) ":" rest
      }
      gsub(/[^A-Za-z0-9]/, "-", p)
      printf "%s", p
    }'
}

# _memory_hash <file> -> a content digest on stdout, non-zero if no hasher
# exists. Content, never metadata -- the whole point is to compare what a file
# SAYS, not when it was last touched.
#
# CARRIAGE RETURNS ARE STRIPPED before hashing, so LF and CRLF copies of the
# same text digest identically. Measured 2026-10-03 in one project
# (core.autocrlf=true, no .gitattributes): this sync wrote LF files, a merge
# checkout rewrote them as CRLF, and every one then failed the lineage check and
# was reported as "diverged" -- git's own conversion read as a stranger's edit.
# Line endings are not something a memory SAYS. `tr -d '\r'` rather than a
# sed `\r$` anchor because BSD sed (macOS) does not understand `\r`; a lone CR
# mid-line is not a meaningful difference in a Markdown memory either.
_memory_hash() {
  [ -f "$1" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    tr -d '\r' < "$1" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    tr -d '\r' < "$1" 2>/dev/null | shasum -a 256 2>/dev/null | cut -d' ' -f1
  elif command -v md5sum >/dev/null 2>&1; then
    tr -d '\r' < "$1" 2>/dev/null | md5sum 2>/dev/null | cut -d' ' -f1
  elif command -v cksum >/dev/null 2>&1; then
    tr -d '\r' < "$1" 2>/dev/null | cksum 2>/dev/null | tr -s ' ' | cut -d' ' -f1,2 | tr ' ' '-'
  else
    return 1
  fi
}

# _memory_hash_batch <file>... -> sets _MEMORY_HASHES[i] to the digest of the
# i-th argument (0-based), byte-identical to what _memory_hash would print for
# it, or '' where _memory_hash would fail. Returns non-zero if no hasher exists.
#
# WHY A BATCH: _memory_hash costs three processes (tr | hasher | cut) and the
# sync called it twice per memory plus an awk per lookup. Measured 2026-10-18
# under Git Bash, where a process costs ~80 ms: 108 memories took 36 s against
# the Stop hook's 20 s timeout, so the hook was killed on every turn, the
# manifest was never written, and memories after the cut-off never synced.
#
# So ONE awk strips the carriage returns of every file into numbered copies, and
# ONE hasher run digests all of them: a fixed handful of processes however many
# memories there are. Same hasher, same fallback order as _memory_hash, so each
# platform keeps the digests its manifest already holds.
#
# The awk reads with RS="\r" and prints each record with ORS="", which is
# exactly "the file minus its CRs" -- including a missing final newline, which
# a newline-record awk would add. Outputs are created up front because an empty
# file has no records. LC_ALL=C keeps invalid UTF-8 a byte stream.
#
# NOT bash `read -d ''`: tried first and correct, but bash reads one byte per
# syscall whenever the delimiter is not newline, and under Git Bash that cost
# ~14 ms per 5 KB memory -- 1.5 s for 108 files, most of the remaining budget.
#
# The copies are named by position, so the hasher's output never has to be
# parsed for a real filename.
_memory_hash_batch() {
  _MEMORY_HASHES=()
  if command -v sha256sum >/dev/null 2>&1; then _hc=(sha256sum)
  elif command -v shasum >/dev/null 2>&1; then _hc=(shasum -a 256)
  elif command -v md5sum >/dev/null 2>&1; then _hc=(md5sum)
  elif command -v cksum >/dev/null 2>&1; then _hc=(cksum)
  else return 1
  fi
  [ "$#" -gt 0 ] || return 0

  _bt="$(mktemp -d 2>/dev/null)"
  _bi=0; _bn=(); _bp=()
  for _bf in "$@"; do
    _MEMORY_HASHES+=("")
    if [ -f "$_bf" ]; then
      _bn+=("$_bi")
      # awk takes an operand shaped like `name=value` as an assignment, not a
      # file. Only a relative path can have that shape; give it a ./ prefix.
      case "$_bf" in
        *=*) case "${_bf%%=*}" in
               ''|[0-9]*|*[!A-Za-z0-9_]*) ;;
               *) _bf="./$_bf" ;;
             esac ;;
      esac
      _bp+=("$_bf")
    fi
    _bi=$((_bi + 1))
  done
  [ "${#_bn[@]}" -gt 0 ] || { [ -n "$_bt" ] && rm -rf "$_bt" 2>/dev/null; return 0; }

  # dir and idx travel through ENVIRON, not -v, which would apply escape
  # processing to a backslash in the path.
  #
  # BINMODE=3: Git Bash's gawk otherwise reads in TEXT mode and turns CRLF into
  # LF before the program sees it (measured 2026-10-18), so only lone CRs were
  # reaching RS -- the digests still matched, but the CRLF half of the work was
  # being done by an I/O layer, not by this code. Elsewhere it is an ordinary
  # unused variable.
  if [ -z "$_bt" ] || [ ! -d "$_bt" ] || ! _MH_DIR="$_bt" _MH_IDX="${_bn[*]}" LC_ALL=C awk -v BINMODE=3 '
      BEGIN {
        RS = "\r"; ORS = ""
        dir = ENVIRON["_MH_DIR"]
        n = split(ENVIRON["_MH_IDX"], slot, " ")
        for (i = 1; i <= n; i++) { o = dir "/" slot[i]; printf "" > o; close(o) }
        k = 0
      }
      # Files arrive in ARGV order. An empty file yields no records and so no
      # FILENAME change, hence the forward scan rather than a counter.
      FILENAME != cur {
        if (cur != "") close(o)
        while (k < n && ARGV[k + 1] != FILENAME) k++
        k++; cur = FILENAME; o = dir "/" slot[k]
      }
      { printf "%s", $0 > o }
    ' "${_bp[@]}" 2>/dev/null; then
    # No scratch space or no working awk: the per-file path. Slow, never wrong.
    _MEMORY_HASHES=()
    for _bf in "$@"; do
      _MEMORY_HASHES+=("$(_memory_hash "$_bf" 2>/dev/null)")
    done
    [ -n "$_bt" ] && rm -rf "$_bt" 2>/dev/null
    return 0
  fi

  ( cd "$_bt" && exec "${_hc[@]}" "${_bn[@]}" ) > "$_bt/out" 2>/dev/null
  # "<digest>  <n>" or "<digest> *<n>" (binary mode, as Git Bash prints it);
  # cksum prints "<crc> <size> <n>", which _memory_hash records as crc-size.
  while read -r _ba _bb _bd; do
    if [ "${_hc[0]}" = cksum ]; then
      _bv="$_ba-$_bb"; _bk="$_bd"
    else
      _bv="${_ba#\\}"; _bk="${_bb#\*}"
    fi
    case "$_bk" in ''|*[!0-9]*) continue ;; esac
    [ "$_bk" -lt "$#" ] && _MEMORY_HASHES[$_bk]="$_bv"
  done < "$_bt/out"
  rm -rf "$_bt" 2>/dev/null
  return 0
}

# memory_manifest_path <repo-root> -> where the sync baseline for that repo lives.
# Kept beside the memory directory rather than inside it, so it is never mistaken
# for a memory and never syncs into the repo.
memory_manifest_path() {
  _k="$(memory_key "${1:-}")" || return 1
  [ -n "$_k" ] || return 1
  printf '%s/.claude/projects/%s/.memory-sync-manifest' "$HOME" "$_k"
}

# seed_memory_manifest <memory-dir> <manifest-path>
#
# Record the digests of everything currently in <memory-dir> as the sync
# baseline. Call this straight after populating the local memory dir FROM the
# repo, while the two are known to be identical -- that is what establishes the
# lineage sync_memory_to_repo checks for.
#
# WHY IT IS REQUIRED, not an optimisation: a cloud VM starts with no manifest.
# hydrate-memory.sh copies repo -> local, the session then edits a memory, and
# at Stop the local file differs from the repo's with no recorded lineage. The
# sync would read that as an independent divergence and refuse to write it
# back, silently disabling cloud memory write-back altogether -- the exact
# capability these hooks exist to provide. Seeding here means the repo copy is
# on record as ours, so a later session edit is correctly seen as a new draft
# of a file we own rather than a collision with a stranger's.
seed_memory_manifest() {
  _dir="${1:-}"; _mf="${2:-}"
  [ -n "$_dir" ] && [ -n "$_mf" ] || return 0
  [ -d "$_dir" ] || return 0
  _tmp="$(mktemp 2>/dev/null)" || return 0
  _files=()
  for _f in "$_dir"/*.md; do
    [ -f "$_f" ] && _files+=("$_f")
  done
  # ${a[@]+"${a[@]}"}: an empty array under `set -u` is an unbound-variable
  # error before bash 4.4, and these hooks run with -u.
  _memory_hash_batch ${_files[@]+"${_files[@]}"}
  _i=0
  for _f in ${_files[@]+"${_files[@]}"}; do
    _h="${_MEMORY_HASHES[$_i]-}"
    [ -n "$_h" ] && printf '%s\t%s\n' "$_h" "${_f##*/}" >> "$_tmp"
    _i=$((_i + 1))
  done
  if [ -s "$_tmp" ]; then
    mv -f "$_tmp" "$_mf" 2>/dev/null || rm -f "$_tmp" 2>/dev/null
  else
    rm -f "$_tmp" 2>/dev/null
  fi
  return 0
}

# sync_memory_to_repo <repo-root>
#
# Copies the live memory directory into <repo-root>/.claude/memory/ so the
# knowledge is version-controlled and reaches other machines and cloud sessions.
#
# Opt-in per repo: does nothing unless .claude/memory/ already exists. A repo
# that has not opted in is never given an unexpected directory.
#
# Sets MEMORY_SYNC_DIVERGED to a space-separated list of filenames deliberately
# NOT overwritten; callers surface it. Empty after a clean sync.
#
# WHY LINEAGE, NOT TIMESTAMPS
#
# This used to be `cp -a -u`: "overwrite when the source is newer". The question
# that actually matters is "did WE write this destination?", and an mtime cannot
# answer it. The two coincide only while both directories hold the same set of
# files, and they come apart the moment a cloud session writes a memory this
# machine has never seen.
#
# Measured 2026-09-22 in a notes repo: a cloud session created
# .claude/memory/ holding its own MEMORY.md -- a 15-line index of 2 notes. The
# local machine had a 97-line MEMORY.md indexing 100 notes under the same
# project key. Two DIFFERENT documents sharing one filename, and the local one
# was newer, so `-u` overwrote the repo's on every Stop and destroyed edits made
# to it minutes earlier. In a cloud session auto-commit.sh commits that loss.
#
# The earlier fix (2026-09-15, in another project) added `-u` to stop a
# stale local copy clobbering a fresh repo edit. That was a real bug, and it is
# this same bug seen from the other side: both are "the destination is not ours
# to overwrite". A timestamp happened to express that case and cannot express
# this one, because here the aggressor is genuinely newer.
#
# So remember the digest of what we last copied out, and overwrite only when the
# destination still matches it byte for byte -- proof the destination is our own
# prior output and nothing has touched it since. Anything else has an
# independent history, and destroying that is never the safe default. A file
# absent from the destination is copied unconditionally: that is the case the
# mechanism exists for, and it can lose nothing.
sync_memory_to_repo() {
  _root="${1:-}"
  MEMORY_SYNC_DIVERGED=""
  [ -n "$_root" ] || return 0
  [ -d "$_root/.claude/memory" ] || return 0

  _key="$(memory_key "$_root")" || return 0
  _src="$HOME/.claude/projects/$_key/memory"
  _dst="$_root/.claude/memory"
  [ -d "$_src" ] || return 0
  [ -n "$(find "$_src" -maxdepth 1 -name '*.md' 2>/dev/null)" ] || return 0

  # What memory_manifest_path would return, from the key already in hand:
  # deriving it again costs another five processes.
  _manifest="$HOME/.claude/projects/$_key/.memory-sync-manifest"
  _next="$(mktemp 2>/dev/null)" || return 0
  _diverged=""
  _mnew=""
  _nl='
'

  # Every digest the loop needs, in ONE batch: local files at [0, n), their
  # repo counterparts at [n, 2n). See _memory_hash_batch for why.
  _names=()
  for _f in "$_src"/*.md; do
    [ -f "$_f" ] && _names+=("${_f##*/}")
  done
  _pairs=()
  # ${a[@]+"${a[@]}"} throughout: see seed_memory_manifest.
  for _name in ${_names[@]+"${_names[@]}"}; do _pairs+=("$_src/$_name"); done
  for _name in ${_names[@]+"${_names[@]}"}; do _pairs+=("$_dst/$_name"); done
  _memory_hash_batch ${_pairs[@]+"${_pairs[@]}"}
  _n="${#_names[@]}"

  # The previous baseline, read once. Lines are "<digest><TAB><name>"; a
  # lookup is a match on the whole line, newline-delimited on both sides.
  _mtext=""
  [ -f "$_manifest" ] && IFS= read -r -d '' _mtext < "$_manifest" 2>/dev/null
  _mtext="$_nl$_mtext$_nl"

  # Copies are collected and made in a few cp calls after the loop, for the
  # same reason as the batch: one cp per memory is one process per memory.
  _copy=()

  _i=0
  for _name in ${_names[@]+"${_names[@]}"}; do
    _f="$_src/$_name"
    _d="$_dst/$_name"
    _sh="${_MEMORY_HASHES[$_i]-}"
    _dh="${_MEMORY_HASHES[$((_n + _i))]-}"
    _i=$((_i + 1))

    # Absent from the repo: a pure addition, nothing can be lost.
    if [ ! -e "$_d" ]; then
      _copy+=("$_f")
      [ -n "$_sh" ] && _mnew="$_mnew$_sh	$_name$_nl"
      continue
    fi

    # Already identical: record the state and touch nothing.
    if [ -n "$_sh" ] && [ "$_sh" = "$_dh" ]; then
      _mnew="$_mnew$_sh	$_name$_nl"
      continue
    fi

    # Contents differ. Overwrite only when the destination is exactly what this
    # sync last put there; otherwise it changed independently, and the local
    # file is a different document rather than a newer draft of the same one.
    _known=0
    case "$_mtext" in *"$_nl$_dh	$_name$_nl"*) _known=1 ;; esac
    if [ -n "$_dh" ] && [ "$_known" = 1 ]; then
      _copy+=("$_f")
      [ -n "$_sh" ] && _mnew="$_mnew$_sh	$_name$_nl"
    else
      _diverged="$_diverged $_name"
      # Record the destination we left in place, so that once a human resolves
      # the divergence by hand, the next run sees lineage again.
      [ -n "$_dh" ] && _mnew="$_mnew$_dh	$_name$_nl"
    fi
  done

  # `cp -a a b c dir/` lands each file exactly where `cp -a a dir/a` would.
  # Chunked so a very large memory dir cannot exceed an argument-length limit.
  _chunk=(); _len=0
  for _f in ${_copy[@]+"${_copy[@]}"}; do
    _chunk+=("$_f"); _len=$((_len + ${#_f} + 1))
    if [ "$_len" -gt 30000 ]; then
      cp -a "${_chunk[@]}" "$_dst/" 2>/dev/null
      _chunk=(); _len=0
    fi
  done
  [ "${#_chunk[@]}" -gt 0 ] && cp -a "${_chunk[@]}" "$_dst/" 2>/dev/null

  # Anything that is not a top-level .md (a subdirectory, a stray asset) keeps
  # the old behaviour. Memory dirs are flat in practice, so this is a
  # compatibility path, not a supported shape.
  for _e in "$_src"/*; do
    [ -e "$_e" ] || continue
    case "$_e" in *.md) continue ;; esac
    cp -a -u "$_e" "$_dst/" 2>/dev/null
  done

  printf '%s' "$_mnew" > "$_next" 2>/dev/null
  if [ -s "$_next" ]; then
    mv -f "$_next" "$_manifest" 2>/dev/null || rm -f "$_next" 2>/dev/null
  else
    rm -f "$_next" 2>/dev/null
  fi

  MEMORY_SYNC_DIVERGED="${_diverged# }"
  return 0
}
