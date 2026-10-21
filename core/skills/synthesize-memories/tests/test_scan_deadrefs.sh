TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MEM="$TMP/projects"
ROOT="$TMP/live"

mkdir -p "$MEM/G--live/memory"
mkdir -p "$ROOT/src/deep"
printf 'fn main() {}\n' > "$ROOT/src/main.rs"
printf 'x\n' > "$ROOT/src/deep/buried.rs"
printf '# Memory Index - live\n' > "$MEM/G--live/memory/MEMORY.md"

make_memory "$MEM/G--live/memory" "refs" "project" "Notes on files." \
  'Touches `src/main.rs`, `buried.rs`, `src/vanished.rs`, `Dockerfile`, `.env` and `main.tf` today.'

# Filter cases: none of these exist under $ROOT, but only the checkable-shaped
# ones (src/really-gone.md, CLAUDE.md) should survive the extraction filter
# and reach the two-angle check. Each suppressed fixture carries an
# allow-listed extension (.md) so it is rejected by exactly the rule it is
# meant to test, not shadowed by the extension-allowlist rule rejecting it
# first: a leading-slash path, a hostname-shaped path, a date-placeholder
# path, a bare dot-extension, and a checkable-shaped path with an ALL-CAPS
# directory segment (DATA_DIR) - the filter must reject all of these before
# they ever reach the two-angle check.
make_memory "$MEM/G--live/memory" "filters" "project" "Notes on noise." \
  'See `/notes/file.md`, `example.com/file.md`, `daily-notes/YYYY-MM-DD.md`, `.md`, `DATA_DIR/sources.json`, `CLAUDE.md` and `src/really-gone.md` here.'

# Orphan: memory dir with no live root.
mkdir -p "$MEM/G--gone/memory"
printf '# Memory Index - gone\n' > "$MEM/G--gone/memory/MEMORY.md"
make_memory "$MEM/G--gone/memory" "ghost" "project" "Ghost." 'Refs `src/nothing.rs`.'

printf 'G--live\t%s\nG--gone\t\n' "$ROOT" > "$TMP/map.tsv"
OUT="$("$HERE/../scripts/scan.sh" --memory-root "$MEM" --map "$TMP/map.tsv")"

assert_contains "$OUT" "## DEAD REFS" "dead refs section present"

# Scope every dead-ref assertion to the DEAD REFS section (bounded to the
# next "## " header so ORPHAN PROJECTS content can't leak in), not raw
# $OUT: an unscoped needle can pass or fail vacuously once another section
# happens to contain a similar substring.
DEADREFS="$(printf '%s\n' "$OUT" | awk '/^## DEAD REFS/{f=1; next} f && /^## /{exit} f')"

assert_contains "$DEADREFS" "src/vanished.rs" "genuinely absent path is reported"
assert_not_contains "$DEADREFS" "src/main.rs" "exact-path hit is not reported"
# Anchored on the leading tab (the missing_path column separator), not a
# trailing one: rows end in "\t<path>\n", so a trailing-tab needle would
# never match regardless of whether buried.rs were wrongly reported and the
# assertion would be vacuous. Verified by mutation: removing the basename
# fallback makes this fail as expected (see task-4-report.md).
assert_not_contains "$DEADREFS" "	buried.rs" "basename-only hit elsewhere in repo is not reported"
assert_not_contains "$DEADREFS" "src/nothing.rs" "refs in root-less project are skipped, not reported"

# Allowlist-widening positives: an extension-less conventional filename, a
# bare dotfile matched via the whole-basename allowlist (not the extension
# list - .env alone is also a bare-dot-extension token), and a newly
# allow-listed extension must all still be reported when genuinely missing.
assert_contains "$DEADREFS" "	Dockerfile" "extension-less conventional filename is still reported when missing"
assert_contains "$DEADREFS" "	.env" "bare dotfile is reported via the whole-basename allowlist"
assert_contains "$DEADREFS" "	main.tf" "newly allow-listed extension (tf) is reported when missing"

# Extraction-filter suppression: a leading-slash path, a hostname-shaped
# path, a date-placeholder path, a bare dot-extension, and a checkable-shaped
# path with an ALL-CAPS directory segment must never reach the two-angle
# check, even though none of them exist under $ROOT either. Each fixture
# carries an allow-listed extension so only its target rule can suppress it
# (see comment above) - a mutation that removes any one of these rules must
# fail its own assertion here, not be masked by another rule rejecting the
# same fixture first.
assert_not_contains "$DEADREFS" "/notes/file.md" "leading-slash path is not extracted as a checkable path"
assert_not_contains "$DEADREFS" "example.com/file.md" "hostname-shaped token is not extracted as a checkable path"
assert_not_contains "$DEADREFS" "YYYY-MM-DD" "date-placeholder path is not extracted as a checkable path"
assert_not_contains "$DEADREFS" "	.md" "bare dot-extension is not extracted as a checkable path"
assert_not_contains "$DEADREFS" "DATA_DIR/sources.json" "ALL-CAPS directory segment is not extracted as a checkable path"

# Extraction-filter positives: genuinely missing, checkable-shaped paths are
# still reported - otherwise only the suppression half of the filter is
# under test. CLAUDE.md in particular guards rule 6 against over-reaching:
# an ALL-CAPS directory *segment* must be rejected without rejecting a real
# ALL-CAPS *filename*.
assert_contains "$DEADREFS" "src/really-gone.md" "genuine missing path with a known extension is still reported"
assert_contains "$DEADREFS" "CLAUDE.md" "genuinely missing ALL-CAPS filename is still reported"

assert_contains "$OUT" "## ORPHAN PROJECTS" "orphan section present"

# Scope the assertions to the orphan section. A needle spanning a newline would be vacuous
# here: the section header is followed by two comment lines before any data row.
ORPHANS="$(printf '%s\n' "$OUT" | sed -n '/## ORPHAN PROJECTS/,$p' | grep -v '^#' | grep -v '^$' | cut -f1)"
assert_contains "$ORPHANS" "G--gone" "root-less project reported as orphan"
assert_not_contains "$ORPHANS" "G--live" "project with a live root is not an orphan"
