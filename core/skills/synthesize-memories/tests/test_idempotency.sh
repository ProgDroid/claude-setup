TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
MEM="$TMP/projects"
mkdir -p "$MEM/G--idem/memory"
printf '# Memory Index - idem\n\n- [Done](project_done.md) - x\n' > "$MEM/G--idem/memory/MEMORY.md"
make_memory "$MEM/G--idem/memory" "project_done" "project" "Phase 9 complete."
printf 'G--idem\t%s\n' "$TMP/idem" > "$TMP/map.tsv"
mkdir -p "$TMP/idem"

R1="$("$HERE/../scripts/scan.sh" --memory-root "$MEM" --map "$TMP/map.tsv")"
R2="$("$HERE/../scripts/scan.sh" --memory-root "$MEM" --map "$TMP/map.tsv")"
assert_eq "$R1" "$R2" "scan output is stable across runs"

# scan.sh must never mutate the corpus.
BEFORE="$(find "$MEM" -type f -exec md5sum {} + | sort)"
"$HERE/../scripts/scan.sh" --memory-root "$MEM" --map "$TMP/map.tsv" > /dev/null
AFTER="$(find "$MEM" -type f -exec md5sum {} + | sort)"
assert_eq "$AFTER" "$BEFORE" "scan.sh is read-only over the corpus"

# After the demote is applied by hand, the cold tier must be registered.
#
# project_done still appears in DEMOTE CANDIDATES on every subsequent run,
# because the memory file is never deleted and its description still
# matches the completion regex. That is expected: scan.sh does only
# decidable work (counting, matching, filesystem checks) and never reads
# the cold tier to reason about membership -- doing so would drag
# judgement into the script and break the script/Claude split the rest of
# the design rests on. SKILL.md is responsible for noticing an entry is
# already in MEMORY-history.md and no-opping on it (see the dry-run gate
# added there in this task). Do not "fix" scan.sh to suppress this, and
# do not assert here that it disappears.
printf '# Memory History - idem (shipped milestones)\n\n## Shipped\n\n- [Done](project_done.md) - x\n' > "$MEM/G--idem/memory/MEMORY-history.md"
printf '# Memory Index - idem\n\n- [Historical milestones](MEMORY-history.md) - shipped work.\n' > "$MEM/G--idem/memory/MEMORY.md"
R3="$("$HERE/../scripts/scan.sh" --memory-root "$MEM" --map "$TMP/map.tsv" | sed -n '/## INDEX SIZES/,/## DEMOTE/p')"
assert_contains "$R3" "G--idem	3	yes" "cold tier now registered for the project"
