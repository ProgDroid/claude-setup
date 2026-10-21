TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MEM="$TMP/projects"

# alpha: has a cold tier already, short hot index
mkdir -p "$MEM/G--alpha/memory"
printf '# Memory Index - alpha\n\n- [Shipped](project_shipped.md) - done\n' > "$MEM/G--alpha/memory/MEMORY.md"
printf '# Memory History - alpha (shipped milestones)\n' > "$MEM/G--alpha/memory/MEMORY-history.md"
make_memory "$MEM/G--alpha/memory" "project_shipped" "project" "Phase 2 shipped; 40 tests green."

# beta: no cold tier, one finished and one live project memory
mkdir -p "$MEM/G--beta/memory"
printf '# Memory Index - beta\n\n- [Done](project_done.md) - x\n- [Live](project_live.md) - y\n' > "$MEM/G--beta/memory/MEMORY.md"
make_memory "$MEM/G--beta/memory" "project_done" "project" "Track 4 fully complete end-to-end."
make_memory "$MEM/G--beta/memory" "project_live" "project" "Step 3 (shared composable) is next."
make_memory "$MEM/G--beta/memory" "user_taste" "user" "Prefers lean proposals."
make_memory "$MEM/G--beta/memory" "user_shipped" "user" "Shipped a big refactor; all done."

printf 'G--alpha\t%s\nG--beta\t%s\n' "$TMP/alpha" "$TMP/beta" > "$TMP/map.tsv"

OUT="$("$HERE/../scripts/scan.sh" --memory-root "$MEM" --map "$TMP/map.tsv" --threshold 2)"

assert_contains "$OUT" "## INDEX SIZES" "index sizes section present"
assert_contains "$OUT" "G--alpha	3	yes" "alpha reports line count and cold tier present"
assert_contains "$OUT" "G--beta	4	no" "beta reports no cold tier"
assert_contains "$OUT" "## DEMOTE CANDIDATES" "demote section present"

# Scoped to the DEMOTE CANDIDATES section only: later sections (e.g. SCOPE
# CANDIDATES) legitimately mention type:user memories, so checking raw $OUT
# would false-fail on content that belongs elsewhere in the report.
DEMOTE="$(printf '%s\n' "$OUT" | sed -n '/## DEMOTE CANDIDATES/,/^## SCOPE CANDIDATES/p')"
assert_contains "$DEMOTE" "project_done" "finished project memory is a demote candidate"
assert_contains "$DEMOTE" "project_shipped" "shipped project memory is a demote candidate"
assert_not_contains "$DEMOTE" "project_live" "live 'is next' memory is NOT a candidate"
assert_not_contains "$DEMOTE" "user_taste" "non-project type is NOT a demote candidate"
assert_not_contains "$DEMOTE" "user_shipped" "completion-marker description with non-project type is NOT a candidate"
