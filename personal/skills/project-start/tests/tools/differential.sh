#!/usr/bin/env bash
# differential.sh: prove two project-start skill trees behave the same.
#
#   differential.sh [--only <fixture>[:<state>[:<command>]]]... [--min-cases K]
#                   <skill-dir-A> <skill-dir-B> <out-dir> [<extra-repo>...]
#
# For every (fixture, state, command) case, A's ritual.sh and then B's run on a copy of the fixture
# rebuilt at the SAME absolute path (paths appear in output), with the same stub tools, PATH and
# environment. Prints one line per case, `SAME <case>` or `DIFF <what> <case>`, where <what> is the
# comma-joined subset of stdout|exit|files|ledger that differs, then `differential: N cases, M differ`.
# Exit 0 iff M = 0; 1 on a difference, or when --min-cases K is given and N < K (a later run over a
# shrunken case set cannot pass silently); 2 on a usage error, including an --only pattern that
# matches no case. A differing case's two outputs are kept under <out-dir>/cases/<case>/{A,B}/.
#
# Case = <fixture>:<state>:<command>. Fixtures: the FX_NAMES in fixtures.sh plus the basename of each
# <extra-repo> (copied with `git archive HEAD` into a fresh one-commit repo). States: FX_STATES.
# Commands: stack, oracle, auto, commit-plan (preflight taken before auto, wrote = auto's .wrote),
# and check-<step> / fix-<step> for every check_* / fix_* function B's libs define, enumerated at run
# time (the lib list is read from B's ritual.sh), never hard-coded. An --only field is a glob.
#
# "files" = `git status --porcelain=v1 -uall`, the raw (git hash-object --no-filters) hash of every
# path it lists, and every file under the git common dir except objects/, index, logs/, *.lock and
# ritual-ledger.json (which is its own category) -- that is where ritual.json and hooks/pre-commit
# live. "ledger" = the ledger file's bytes (or its kind when it is not a file). Stderr is kept for
# debugging but not compared. Normalised: only ritual.json's `completed_at` (today's date).
# `fix beads` runs with beads-fixture.sh's stub bd first on PATH (it models bd 1.2.2's side effects,
# which lets fix_beads reach its CLAUDE.md and template appends); every other case uses the
# make_tool_stubs bd. Git dates are fixed, so two builds of a fixture are the same commits.
# The git-dir comparison hashes files with sha256sum. Where it is missing (stock macOS) every hash
# would be empty on both sides and a changed hook would read SAME, so refuse to run at all.
command -v sha256sum >/dev/null 2>&1 || { echo "differential: sha256sum is required (without it a changed hook would read SAME)" >&2; exit 2; }
TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TOOLS_DIR/../beads-fixture.sh"   # lib.sh (TMPROOT, tool_run), the stub bd (STUBDIR, STUB_BD_LOG)
. "$TOOLS_DIR/fixtures.sh"
set -uo pipefail
die2() { echo "differential: $*" >&2; exit 2; }

ONLY=(); MIN=0; JOBS=1; SHARD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only) [ $# -ge 2 ] || die2 "--only needs a pattern"; ONLY+=("$2"); shift 2 ;;
    --min-cases) [ $# -ge 2 ] || die2 "--min-cases needs a number"; MIN="$2"; shift 2 ;;
    --jobs) [ $# -ge 2 ] || die2 "--jobs needs a number"; JOBS="$2"; shift 2 ;;
    --shard) [ $# -ge 2 ] || die2 "--shard needs i/K"; SHARD="$2"; shift 2 ;;
    --) shift; break ;;
    -*) die2 "unknown option $1" ;;
    *) break ;;
  esac
done
[ $# -ge 3 ] || die2 "usage: differential.sh [--only <fixture>[:<state>[:<command>]]]... [--min-cases K] <skill-dir-A> <skill-dir-B> <out-dir> [<extra-repo>...]"
case "$MIN" in ''|*[!0-9]*) die2 "--min-cases needs a number" ;; esac
case "$JOBS" in ''|*[!0-9]*|0) die2 "--jobs needs a positive number" ;; esac
SA="$(cd "$1" && pwd)" && SB="$(cd "$2" && pwd)" || die2 "a skill dir does not exist"
[ -f "$SA/ritual.sh" ] && [ -f "$SB/ritual.sh" ] || die2 "no ritual.sh in a skill dir"
mkdir -p "$3" || die2 "cannot make $3"; OUT="$(cd "$3" && pwd)"; shift 3
EXTRA_NAMES=(); EXTRA_SRC=()
for x in "$@"; do
  [ -d "$x" ] || die2 "extra repo $x is not a directory"
  EXTRA_NAMES+=("$(basename "$x")"); EXTRA_SRC+=("$(cd "$x" && pwd)")
done

export GIT_AUTHOR_DATE="$FX_DATE" GIT_COMMITTER_DATE="$FX_DATE"
make_tool_stubs "$TMPROOT"

# --- steps: B's check_*/fix_* functions, from the libs B's ritual.sh sources
steps_of() {   # steps_of <skill-dir> -> "check-x" / "fix-y" lines
  ( libs="$(grep -o 'lib/[A-Za-z_]*\.sh' "$1/ritual.sh" | awk '!s[$0]++')"
    for l in $libs; do . "$1/$l" || exit 1; done
    declare -F | awk '{print $3}' | grep -E '^(check|fix)_[a-z]' | tr '_' '-' | sort )
}
STEPS="$(steps_of "$SB")" || die2 "could not enumerate the steps of $SB"
[ -n "$STEPS" ] || die2 "no check_/fix_ functions found in $SB"

# --- the case matrix
FIXTURES=($FX_NAMES "${EXTRA_NAMES[@]}")
CMDS=(stack oracle auto commit-plan $STEPS)
match1() {   # match1 <case> <pattern>
  local c="$1" p="$2" f s m cf cs
  f="${p%%:*}"; s='*'; m='*'
  if [ "$p" != "$f" ]; then s="${p#*:}"; if [ "$s" != "${s#*:}" ]; then m="${s#*:}"; s="${s%%:*}"; fi; fi
  cf="${c%%:*}"; cs="${c#*:}"; cs="${cs%%:*}"
  # shellcheck disable=SC2053
  [[ "$cf" == $f && "$cs" == $s && "${c##*:}" == $m ]]
}
matches() {   # matches <case> -> 0 when some --only pattern admits it, or there is none
  local p; [ "${#ONLY[@]}" -gt 0 ] || return 0
  for p in "${ONLY[@]}"; do match1 "$1" "$p" && return 0; done
  return 1
}
CASES=(); declare -A SEEN=()
for f in "${FIXTURES[@]}"; do for s in $FX_STATES; do for c in "${CMDS[@]}"; do
  id="$f:$s:$c"; CASES+=("$id")
done; done; done
for p in "${ONLY[@]}"; do
  hit=0
  for id in "${CASES[@]}"; do match1 "$id" "$p" && { hit=1; break; }; done
  [ "$hit" = 1 ] || die2 "--only $p matches no case"
done

# --- --jobs K: K child runs, each on its own shard of the (fixture, state) groups and its own work
# path (A and B still share a path inside one shard, which is all the comparison needs)
if [ "$JOBS" -gt 1 ] && [ -z "$SHARD" ]; then
  ARGS_PASS=(); for p in "${ONLY[@]}"; do ARGS_PASS+=(--only "$p"); done
  pids=(); for ((k = 0; k < JOBS; k++)); do
    bash "${BASH_SOURCE[0]}" "${ARGS_PASS[@]}" --shard "$k/$JOBS" "$SA" "$SB" "$OUT/shard-$k" "${EXTRA_SRC[@]}" > "$OUT/shard-$k.log" 2>&1 &
    pids+=($!)
  done
  # E = the cases enumerated before sharding; a shard that died, or lost lines, can never read as
  # "N cases, 0 differ"
  E=0; for id in "${CASES[@]}"; do matches "$id" && E=$((E + 1)); done
  for ((k = 0; k < JOBS; k++)); do
    wait "${pids[$k]}"; src_rc=$?
    if [ "$src_rc" -gt 1 ]; then echo "differential: shard $k exited $src_rc (see $OUT/shard-$k.log)" >&2; exit 2; fi
  done
  N=0; M=0; LINES=0
  for ((k = 0; k < JOBS; k++)); do
    grep -v '^differential: ' "$OUT/shard-$k.log"
    t="$(grep '^differential: [0-9]* cases' "$OUT/shard-$k.log" | tail -n 1)"
    [ -n "$t" ] || { echo "differential: shard $k did not finish (see $OUT/shard-$k.log)" >&2; exit 2; }
    n="$(sed 's/^differential: \([0-9]*\) cases.*/\1/' <<<"$t")"; m="$(sed 's/.* cases, \([0-9]*\) differ/\1/' <<<"$t")"
    l="$(grep -c '^\(SAME\|DIFF\) ' "$OUT/shard-$k.log")"
    if [ "$l" -ne "$n" ]; then echo "differential: shard $k reported $n cases but printed $l (see $OUT/shard-$k.log)" >&2; exit 2; fi
    N=$((N + n)); M=$((M + m)); LINES=$((LINES + l))
  done
  if [ "$LINES" -ne "$E" ]; then echo "differential: collected $LINES case lines, enumerated $E" >&2; exit 2; fi
  echo "differential: $N cases, $M differ"
  if [ "$MIN" -gt 0 ] && [ "$N" -lt "$MIN" ]; then echo "differential: fewer cases than --min-cases $MIN" >&2; exit 1; fi
  [ "$M" -eq 0 ]; exit $?
fi
SHARD_I=0; SHARD_K=1
if [ -n "$SHARD" ]; then SHARD_I="${SHARD%/*}"; SHARD_K="${SHARD#*/}"; fi
# test seam (selftest only): DIFFERENTIAL_TEST_SHARD_FAULT=<shard>:<exit|silent> makes that shard
# die with exit 9, or finish having run nothing and claiming success
case "${DIFFERENTIAL_TEST_SHARD_FAULT:-}" in
  "$SHARD_I:exit") exit 9 ;;
  "$SHARD_I:silent") [ -n "$SHARD" ] && { echo "differential: 0 cases, 0 differ"; exit 0; } ;;
esac
GIDX=-1

# --- one side's run of one command at repo path $P
P="$OUT/work space/repo"
SNAP_ROOT="$OUT/snapshots"
rm -rf "$OUT/cases" "$OUT/work space" "$SNAP_ROOT"; mkdir -p "$OUT/work space" "$SNAP_ROOT"

run_cmd() {   # run_cmd <skill-dir> <command> <repo> <outdir> -> stdout, stderr, exit in <outdir>
  local rs="$1/ritual.sh" cmd="$2" repo="$3" od="$4" w="$OUT/work space/w" rc
  rm -rf "$w"; mkdir -p "$w"
  case "$cmd" in
    commit-plan)
      tool_run bash "$rs" preflight "$repo" > "$w/pf.json" 2>/dev/null
      tool_run bash "$rs" auto "$repo" 2>/dev/null | jq -c .wrote > "$w/wr.json"
      tool_run bash "$rs" commit-plan "$repo" "$w/pf.json" "$w/wr.json" > "$od/stdout" 2> "$od/stderr"; rc=$? ;;
    check-*|fix-*)
      if [ "$cmd" = fix-beads ]; then
        tool_run env "PATH=$STUBDIR:$PATH" "STUB_BD_LOG=$w/bd.log" bash "$rs" "${cmd%%-*}" "${cmd#*-}" "$repo" > "$od/stdout" 2> "$od/stderr"; rc=$?
      else
        tool_run bash "$rs" "${cmd%%-*}" "${cmd#*-}" "$repo" > "$od/stdout" 2> "$od/stderr"; rc=$?
      fi ;;
    *) tool_run bash "$rs" "$cmd" "$repo" > "$od/stdout" 2> "$od/stderr"; rc=$? ;;
  esac
  printf '%s\n' "$rc" > "$od/exit"
}

# _mode_map <assoc-name> <path>...: one stat call; fills the associative array with path -> octal mode.
# A path stat cannot read is simply absent (the caller prints nomode, as fx_mode does).
_mode_map() {
  local -n _mm="$1"; shift
  local l
  [ "$#" -gt 0 ] || return 0
  while IFS= read -r l; do l="${l%$'\r'}"; _mm["${l#* }"]="${l%% *}"; done < <(stat -c '%a %n' -- "$@" 2>/dev/null)
}

# A file name holding a newline is not supported (as before: the listing and find|sort|read are
# line-based); it splits into two bogus names and prints nomode / a failed hash for them.
collect() {   # collect <repo> <outdir> -> files, ledger in <outdir>
  local repo="$1" od="$2" gd lg
  gd="$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir | tr -d '\r')"
  {
    echo "## status"; git -C "$repo" status --porcelain=v1 -uall 2>&1
    echo "## listed paths"
    local -a lp=() reg=() full=() hs=()
    local -A md=()
    local p i h
    mapfile -t lp < <(git -C "$repo" status --porcelain=v1 -uall -z 2>/dev/null | tr '\0' '\n' | awk '
      skip { skip = 0; next }
      NF { x = substr($0, 1, 2); print substr($0, 4); if (x ~ /^[RC]/ || x ~ /.[RC]$/) skip = 1 }' | tr -d '\r')
    for p in "${lp[@]}"; do
      if [ -f "$repo/$p" ] && [ ! -L "$repo/$p" ]; then reg+=("$p"); full+=("$repo/$p"); fi
    done
    if [ "${#reg[@]}" -gt 0 ]; then
      _mode_map md "${full[@]}"
      mapfile -t hs < <(printf '%s\n' "${reg[@]}" | git -C "$repo" hash-object --no-filters --stdin-paths 2>/dev/null | tr -d '\r')
      if [ "${#hs[@]}" -ne "${#reg[@]}" ]; then   # git aborts the batch on one bad path: redo per file
        hs=(); for p in "${reg[@]}"; do hs+=("$(git -C "$repo" hash-object --no-filters -- "$p" | tr -d '\r')"); done
      fi
    fi
    i=0
    for p in "${lp[@]}"; do
      if [ -f "$repo/$p" ] && [ ! -L "$repo/$p" ]; then
        printf '%s\t%s\t%s\n' "$p" "${md["$repo/$p"]:-nomode}" "${hs[$i]}"; i=$((i + 1))
      else printf '%s\tnot-a-regular-file\n' "$p"; fi
    done
    echo "## git common dir"
    (
      cd "$gd" || exit 0
      local -a fl=() sh=()
      local -A gm=()
      local f
      mapfile -t fl < <(find . \( -path ./objects -o -path ./logs \) -prune -o -type f ! -path ./index ! -name '*.lock' ! -path ./ritual-ledger.json -print | LC_ALL=C sort)
      [ "${#fl[@]}" -gt 0 ] || exit 0
      _mode_map gm "${fl[@]}"
      # sha256sum -b: the bytes as stored, as `sha256sum < file` read them (fx_sha256_lines, fixtures.sh)
      mapfile -t sh < <(fx_sha256_lines "${fl[@]}")
      i=0
      for f in "${fl[@]}"; do
        if [ "${f##*/}" = ritual.json ]; then   # hashed with `completed_at` masked, as fx_hash_file does
          h="$(sed 's/"completed_at": *"[^"]*"/"completed_at":"DATE"/g' "$f" | sha256sum | cut -d' ' -f1)"
        else h="${sh[$i]}"; fi
        i=$((i + 1))
        printf '%s\t%s\t%s\n' "$f" "${gm["$f"]:-nomode}" "$h"
      done
    )
  } > "$od/files" 2>&1
  lg="$gd/ritual-ledger.json"
  if [ -f "$lg" ]; then cat "$lg" > "$od/ledger"
  elif [ -d "$lg" ]; then echo "<directory>" > "$od/ledger"
  elif [ -e "$lg" ]; then echo "<not a regular file>" > "$od/ledger"
  else echo "<absent>" > "$od/ledger"; fi
}

N=0; M=0; GROUP=""
for id in "${CASES[@]}"; do
  matches "$id" || continue
  f="${id%%:*}"; rest="${id#*:}"; s="${rest%%:*}"; c="${rest#*:}"
  if [ "$GROUP" != "$f:$s" ]; then   # a new (fixture, state): one shard owns it; build it once per side
    GROUP="$f:$s"; GIDX=$((GIDX + 1))
    [ $((GIDX % SHARD_K)) -eq "$SHARD_I" ] || continue
    src="$f"
    for i in "${!EXTRA_NAMES[@]}"; do [ "${EXTRA_NAMES[$i]}" = "$f" ] && src="extra:${EXTRA_SRC[$i]}"; done
    for side in A B; do
      if [ "$side" = A ]; then rs="$SA/ritual.sh"; else rs="$SB/ritual.sh"; fi
      fx_snapshot "$src" "$s" "$rs" "$P" "$SNAP_ROOT/$side" || die2 "cannot build $f:$s for $side"
    done
  fi
  [ $((GIDX % SHARD_K)) -eq "$SHARD_I" ] || continue
  N=$((N + 1))
  cd="$OUT/cases/${id//[:\/]/_}"
  for side in A B; do
    mkdir -p "$cd/$side"
    fx_restore "$SNAP_ROOT/$side" "$P"
    if [ "$side" = A ]; then sd="$SA"; else sd="$SB"; fi
    run_cmd "$sd" "$c" "$P" "$cd/$side"
    collect "$P" "$cd/$side"
  done
  what=""
  cmp -s "$cd/A/stdout" "$cd/B/stdout" || what="${what:+$what,}stdout"
  cmp -s "$cd/A/exit" "$cd/B/exit" || what="${what:+$what,}exit"
  cmp -s "$cd/A/files" "$cd/B/files" || what="${what:+$what,}files"
  cmp -s "$cd/A/ledger" "$cd/B/ledger" || what="${what:+$what,}ledger"
  if [ -z "$what" ]; then echo "SAME $id"; rm -rf "$cd"
  else echo "DIFF $what $id"; M=$((M + 1)); fi
done
rm -rf "$OUT/snapshots" "$OUT/work space"
echo "differential: $N cases, $M differ"
if [ "$MIN" -gt 0 ] && [ "$N" -lt "$MIN" ]; then echo "differential: fewer cases than --min-cases $MIN" >&2; exit 1; fi
[ "$M" -eq 0 ]
