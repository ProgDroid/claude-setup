# resolve-roots maps memory dir names to project roots, on both OS shapes.
# Expected names are built as <key of the fixture root> + a LITERAL suffix, so the
# suffix (the part that carries the dot/underscore/space rules) is checked by hand and
# only the leading, OS-specific part comes from core_memory_key.
# shellcheck source=/dev/null
. "$HERE/../../../hooks/lib-key.sh"
RR="$HERE/../scripts/resolve-roots.sh"
TAB="$(printf '\t')"
# row <tsv> <name>: the full output line for that memory dir name (empty if none)
row() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '$1 == n { print; exit }'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MEM="$TMP/projects"

# --- fixture 1: a drive-shaped tree (mixed-case names, hyphen, space, underscore, dot) ---
D="$TMP/drive"
mkdir -p "$D/pythonDev" "$D/rustDev/anime-calendar" "$D/Users/Some One/Documents/tools" \
         "$D/flutterDev/day_planner" "$D/webDev/my.app"
PD="$(core_memory_key "$D")"
mkdir -p "$MEM/${PD}-pythonDev/memory" \
         "$MEM/${PD}-rustDev-anime-calendar/memory" \
         "$MEM/${PD}-Users-Some-One-Documents-tools/memory" \
         "$MEM/${PD}-flutterDev-day-planner/memory" \
         "$MEM/${PD}-webDev-my-app/memory" \
         "$MEM/${PD}-flutterDev-gone/memory"

OUT="$(bash "$RR" --memory-root "$MEM" --search-root "$D")"
RC=$?
assert_eq "$RC" "0" "drive-shaped fixture: exit 0"
assert_eq "$(row "$OUT" "${PD}-pythonDev")" "${PD}-pythonDev$TAB$D/pythonDev" "depth-1 dir resolves"
assert_eq "$(row "$OUT" "${PD}-rustDev-anime-calendar")" "${PD}-rustDev-anime-calendar$TAB$D/rustDev/anime-calendar" "depth-2 with hyphen resolves"
assert_eq "$(row "$OUT" "${PD}-Users-Some-One-Documents-tools")" "${PD}-Users-Some-One-Documents-tools$TAB$D/Users/Some One/Documents/tools" "space in path resolves"
assert_eq "$(row "$OUT" "${PD}-flutterDev-day-planner")" "${PD}-flutterDev-day-planner$TAB$D/flutterDev/day_planner" "underscore resolves"
assert_eq "$(row "$OUT" "${PD}-webDev-my-app")" "${PD}-webDev-my-app$TAB$D/webDev/my.app" "dot in a dir name resolves"
assert_eq "$(row "$OUT" "${PD}-flutterDev-gone")" "${PD}-flutterDev-gone$TAB" "memory dir with no matching directory prints an empty root"
assert_eq "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')" "6" "one line per memory dir"

# --- fixture 2: a Linux-shaped tree ---
H="$TMP/home/me"
mkdir -p "$H/my_repo" "$H/work space"
MEM2="$TMP/projects2"
HK="$(core_memory_key "$TMP/home")"
mkdir -p "$MEM2/${HK}-me-my-repo/memory" "$MEM2/${HK}-me-work-space/memory" \
         "$MEM2/-nowhere-at-all/memory"
OUT2="$(bash "$RR" --memory-root "$MEM2" --search-root "$TMP/home")"
RC2=$?
assert_eq "$(row "$OUT2" "${HK}-me-my-repo")" "${HK}-me-my-repo$TAB$H/my_repo" "linux: underscore repo resolves"
assert_eq "$(row "$OUT2" "${HK}-me-work-space")" "${HK}-me-work-space$TAB$H/work space" "linux: space in dir name resolves"
assert_eq "$(row "$OUT2" "-nowhere-at-all")" "-nowhere-at-all$TAB" "linux: unmatched memory dir prints an empty root"
assert_eq "$RC2" "0" "linux: a memory dir no repo matches still exits 0"

# --- repeatable --search-root: both roots are searched ---
MEM3="$TMP/projects3"
mkdir -p "$TMP/ra/alpha" "$TMP/rb/beta"
KA="$(core_memory_key "$TMP/ra")"; KB="$(core_memory_key "$TMP/rb")"
mkdir -p "$MEM3/${KA}-alpha/memory" "$MEM3/${KB}-beta/memory"
OUT3="$(bash "$RR" --memory-root "$MEM3" --search-root "$TMP/ra" --search-root "$TMP/rb")"
assert_eq "$(row "$OUT3" "${KA}-alpha")" "${KA}-alpha$TAB$TMP/ra/alpha" "two roots: first root searched"
assert_eq "$(row "$OUT3" "${KB}-beta")" "${KB}-beta$TAB$TMP/rb/beta" "two roots: second root searched"
OUT3B="$(bash "$RR" --memory-root "$MEM3" --search-root "$TMP/ra")"
assert_eq "$(row "$OUT3B" "${KB}-beta")" "${KB}-beta$TAB" "one root only: the second root's memory dir stays unplaced"

# --- the prefix+suffix encoding must equal core_memory_key on the whole path ---
MEM4="$TMP/projects4"
mkdir -p "$TMP/rc/x/a.b c_d@e"
WANT="$(core_memory_key "$TMP/rc/x/a.b c_d@e")"
mkdir -p "$MEM4/$WANT/memory"
OUT4="$(bash "$RR" --memory-root "$MEM4" --search-root "$TMP/rc")"
assert_eq "$(row "$OUT4" "$WANT")" "$WANT$TAB$TMP/rc/x/a.b c_d@e" "placed under the key core_memory_key gives for the full path"

# --- removed and malformed flags ---
bash "$RR" --memory-root "$MEM" --search-root "$D" --drive G >/dev/null 2>&1
assert_eq "$?" "2" "--drive is gone: rejected with exit 2"
bash "$RR" --search-root >/dev/null 2>&1
assert_eq "$?" "2" "value-less --search-root exits 2, not an unbound-variable crash"

# --- default search root: $HOME when /g does not exist ---
if [ ! -d /g ]; then
  mkdir -p "$TMP/fakehome/code/proj" "$TMP/fakehome/.claude/projects"
  KH="$(core_memory_key "$TMP/fakehome")"
  mkdir -p "$TMP/fakehome/.claude/projects/${KH}-code-proj/memory"
  OUT5="$(HOME="$TMP/fakehome" bash "$RR")"
  assert_eq "$(row "$OUT5" "${KH}-code-proj")" "${KH}-code-proj$TAB$TMP/fakehome/code/proj" "no /g: default search root is HOME"
else
  printf '    skip default-root-is-HOME case (this machine has /g)\n'
fi

# --- search root "/" has no usable prefix and takes the per-directory path ---
MEM6="$TMP/projects6"
mkdir -p "$MEM6/$(core_memory_key /tmp)/memory"
OUT6="$(bash "$RR" --memory-root "$MEM6" --search-root / --max-depth 1)"
assert_eq "$(row "$OUT6" "$(core_memory_key /tmp)")" "$(core_memory_key /tmp)$TAB/tmp" "root '/': /tmp resolves through the fallback"

# --- a directory name containing a newline is skipped, not split into two bogus rows ---
MEM7="$TMP/projects7"
NLD="$TMP/nl"
mkdir -p "$NLD"
if mkdir "$NLD/$(printf 'a\nb')" 2>/dev/null; then
  mkdir -p "$MEM7/$(core_memory_key "$NLD/a")/memory"
  OUT7="$(bash "$RR" --memory-root "$MEM7" --search-root "$NLD")"
  assert_eq "$(row "$OUT7" "$(core_memory_key "$NLD/a")")" "$(core_memory_key "$NLD/a")$TAB" "newline in a dir name: the fragment before it does not resolve"
else
  printf '    SKIP newline-name case (mkdir refused a newline name here)\n'
fi

# --- no search root, no /g, no HOME: refuse rather than scan / ---
if [ ! -d /g ]; then
  mkdir -p "$TMP/mem8/x/memory"
  START="$(date +%s)"
  ERR8="$(HOME= bash "$RR" --memory-root "$TMP/mem8" 2>&1 >/dev/null)"; RC8=$?
  ELAPSED=$(( $(date +%s) - START ))
  assert_eq "$RC8" "2" "no root, no /g, no HOME: exit 2"
  case "$ERR8" in *--search-root*) _pass "no-root refusal names --search-root" ;; *) _fail "no-root refusal names --search-root" "actual: $ERR8" ;; esac
  if [ "$ELAPSED" -lt 5 ]; then _pass "no-root refusal returns fast (no scan of /)"; else _fail "no-root refusal returns fast (no scan of /)" "took ${ELAPSED}s"; fi
else
  printf '    SKIP no-search-root case (this machine has /g)\n'
fi
