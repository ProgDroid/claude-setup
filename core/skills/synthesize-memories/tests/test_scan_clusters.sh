TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MEM="$TMP/projects"

for p in one two; do
  mkdir -p "$MEM/G--$p/memory"
  printf '# Memory Index - %s\n' "$p" > "$MEM/G--$p/memory/MEMORY.md"
done

# 'powershell' appears in 3 memories across 2 projects -> a cluster.
make_memory "$MEM/G--one/memory" "ps-encoding" "feedback" "PowerShell mangles UTF-8 encoding on write."
make_memory "$MEM/G--one/memory" "ps-hooks" "feedback" "PowerShell hooks must stay ASCII only."
make_memory "$MEM/G--two/memory" "ps-commit" "feedback" "PowerShell commit adds a BOM to subjects."
# 'kayak' appears in 3 memories, but all in ONE project -> not a cluster.
# (Three distinct files, not three raw mentions: clustering counts memories,
# not word occurrences, so this is what actually exercises the >=2-projects
# rule rather than tripping the >=3-memories rule on its own.)
make_memory "$MEM/G--two/memory" "kayak-a" "reference" "Kayak dashboard link."
make_memory "$MEM/G--two/memory" "kayak-b" "reference" "Kayak billing page."
make_memory "$MEM/G--two/memory" "kayak-c" "reference" "Kayak search results."
make_memory "$MEM/G--two/memory" "user-android" "user" "User is Android only, no iOS device."
# 'docker' appears in exactly 2 memories, across 2 DIFFERENT projects -> not a
# cluster. This isolates the >=3-memories rule the way kayak isolates the
# >=2-projects rule: the project count here already satisfies the filter, so
# only the memory-count threshold can be responsible for excluding it.
make_memory "$MEM/G--one/memory" "docker-a" "feedback" "Docker compose config drifted from prod."
make_memory "$MEM/G--two/memory" "docker-b" "feedback" "Docker healthcheck timeout was too short."
# '2026' meets both thresholds (3 memories, 2 projects) but is a pure-numeric
# token (date-string noise) -> must be suppressed regardless.
make_memory "$MEM/G--one/memory" "date-a" "project" "Shipped 2026 roadmap milestone."
make_memory "$MEM/G--one/memory" "date-b" "project" "Started 2026 planning cycle."
make_memory "$MEM/G--two/memory" "date-c" "project" "Closed out 2026 fiscal year work."

printf 'G--one\t%s\nG--two\t%s\n' "$TMP/one" "$TMP/two" > "$TMP/map.tsv"
OUT="$("$HERE/../scripts/scan.sh" --memory-root "$MEM" --map "$TMP/map.tsv")"

assert_contains "$OUT" "## SCOPE CANDIDATES" "scope section present"

# Scoped to the SCOPE CANDIDATES section only: "ps-encoding" also legitimately
# appears as a filename fragment elsewhere in the report (e.g. the CLUSTERS
# recovery-grep example line), so checking raw $OUT would pass even if the
# SCOPE CANDIDATES row itself were missing.
SCOPE="$(printf '%s\n' "$OUT" | sed -n '/## SCOPE CANDIDATES/,/^## CLUSTERS/p')"
assert_contains "$SCOPE" "user-android" "user-type memory listed as scope candidate"
assert_contains "$SCOPE" "ps-encoding" "feedback-type memory listed as scope candidate"
assert_not_contains "$SCOPE" "kayak-a" "reference-type memory is NOT a scope candidate"
assert_contains "$OUT" "## CLUSTERS" "clusters section present"

# Compare against the term column only. Matching raw output would be vacuous: cluster rows
# are "<term>\t<n>\t<n>" (members are omitted for size), so a needle like "\tkayak\t" can
# never match even if kayak WERE wrongly emitted.
# Bounded to the next "## " header (not just "to EOF") so a later task appending
# more sections after CLUSTERS can't leak their content into this extract.
CLUSTERS_SECTION="$(printf '%s\n' "$OUT" | awk '/^## CLUSTERS/{f=1; next} f && /^## /{exit} f')"
TERMS="$(printf '%s\n' "$CLUSTERS_SECTION" | grep -v '^#' | grep -v '^$' | cut -f1)"
assert_contains "$TERMS" "powershell" "cross-project repeated term is a cluster"
assert_not_contains "$TERMS" "kayak" "single-project repeated term is NOT a cluster"
assert_not_contains "$TERMS" "docker" "term below the memory-count threshold is NOT a cluster"
assert_not_contains "$TERMS" "2026" "pure-numeric term is NOT a cluster even when both thresholds are met"
