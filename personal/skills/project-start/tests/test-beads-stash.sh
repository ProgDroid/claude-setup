#!/usr/bin/env bash
# Tests: fix beads on dirty trees and the --stash round trip, with a stub bd.
. "$(dirname "${BASH_SOURCE[0]}")/beads-fixture.sh"

# ============================== fix beads: dirty trees and the stash
r="$(mkrepo "Dirty Repo")"; echo more >> "$r/README.md"; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = failed ] && [ "$(dt "$out")" = 'dirty tree; re-run with --stash' ] && [ "$(logn)" = 0 ] \
  && ok "fix_refuses_dirty_without_stash" || bad "dirty no stash: $out; log=$(cat "$LOG")"

# stash_fixture <name> -> repo with an MM file, an unstaged edit, an untracked file, a CRLF edit
stash_fixture() {
  local r; r="$(mkrepo "$1")"
  printf 'v1\n' > "$r/mm.txt"; printf 'tracked\n' > "$r/edit.txt"; printf 'one\r\ntwo\r\n' > "$r/crlf.txt"
  commit_all "$r" fixture
  printf 'v2\n' >> "$r/mm.txt"; git -C "$r" add mm.txt; printf 'v3\n' >> "$r/mm.txt"
  printf 'edit\n' >> "$r/edit.txt"; printf 'three\r\n' >> "$r/crlf.txt"; printf 'new\n' > "$r/untracked.txt"
  printf '%s\n' "$r"
}
r="$(stash_fixture "Stash Repo")"; pre="$(pf "$r")"; logclear
[ "$(jq -r '.dirty[]|select(.path=="mm.txt")|.xy' <<<"$pre")" = MM ] && [ "$(jq '.dirty|length' <<<"$pre")" = 4 ] \
  && ok "stash_fixture_has_MM_and_four_dirty (control)" || bad "fixture: $pre"
out="$(R fix beads "$r" --stash)"; post="$(pf "$r")"
[ "$(st "$out")" = fixed ] && ok "fix_stash_fixed" || bad "stash fix: $out"
[ "$(git -C "$r" log -1 --format=%s)" = 'bd init: initialize beads issue tracking' ] && same_user_state "$pre" "$post" && ok "fix_stash_roundtrip_exact" || bad "roundtrip: pre=$pre post=$post"
[ "$(st "$out")" = fixed ] && [ -z "$(git -C "$r" stash list)" ] && ok "fix_stash_list_empty_after" || bad "stash left: $(git -C "$r" stash list)"
jq -e '.wrote | map(select(. == "mm.txt" or . == "edit.txt" or . == "crlf.txt" or . == "untracked.txt")) | length == 0' <<<"$out" >/dev/null \
  && ok "fix_stash_wrote_excludes_user_paths" || bad "wrote: $out"
same_user_state "$pre" "$(pf "$(mkrepo)")" && bad "same_user_state is blind" || ok "same_user_state_discriminates (control)"

r="$(mkrepo "Autocrlf Repo")"; git -C "$r" config core.autocrlf true
printf 'a\nb\n' > "$r/lf.txt"; commit_all "$r" lf 2>/dev/null
printf 'c\n' >> "$r/lf.txt"; printf 'u\n' > "$r/untr.txt"; printf 'p\nq\r\n' > "$r/mixed.txt"
pre="$(pf "$r")"; out="$(R fix beads "$r" --stash 2>/dev/null)"; post="$(pf "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" log -1 --format=%s)" = 'bd init: initialize beads issue tracking' ]   && same_user_state "$pre" "$post" && ok "fix_stash_roundtrip_exact_under_autocrlf" || bad "autocrlf: $out pre=$pre post=$post"

r="$(stash_fixture "Mutate Repo")"; logclear
out="$(STUB_INIT_MUTATE=README.md R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && dt "$out" | grep -q 'stash@{0}' \
  && dt "$out" | grep -q 'README.md' && ! grep -q 'config set' "$LOG" \
  && ok "fix_stash_mismatch_keeps_stash" || bad "mismatch: $out; stash=$(git -C "$r" stash list)"
msha="$(git -C "$r" rev-parse -q --verify refs/stash)"
[ -n "$msha" ] && dt "$out" | grep -qF "core.autocrlf=false" && dt "$out" | grep -qF "stash apply --index $msha\`" \
  && ok "fix_stash_mismatch_prints_the_raw_mode_apply" || bad "mismatch recovery command: $(dt "$out")"

r="$(stash_fixture "Collide Repo")"; logclear
out="$(STUB_INIT_MUTATE=edit.txt R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && ok "fix_stash_apply_conflict_keeps_stash" || bad "apply conflict: $out"

r="$(mkrepo "Claude Repo")"; printf 'my notes\n' > "$r/CLAUDE.md"; logclear
out="$(R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'CLAUDE.md' && [ "$(logn)" = 0 ] && [ -z "$(git -C "$r" stash list)" ] \
  && [ "$(cat "$r/CLAUDE.md")" = 'my notes' ] && ok "fix_stash_refuses_paths_bd_init_writes" || bad "collision: $out"

r="$(mkrepo "Dirty Beads")"; mkhouse "$r" -; commit_all "$r" beads; printf 'x: y\n' >> "$r/.beads/config.yaml"; logclear
out="$(R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q '\.beads/' && [ "$(logn)" = 0 ] && ok "fix_stash_refuses_dirty_beads_dir" || bad "dirty .beads: $out"

# --- large trees: the compare must not depend on jq's command-line length
r="$(big_fixture "Big Stash")"; pre="$(pf "$r")"; logclear
[ "$(jq '.dirty|length' <<<"$pre")" -ge 150 ] && [ "$(jq '[.dirty[]|select(.xy=="MM")]|length' <<<"$pre")" = 20 ] \
  && [ "$(jq '[.dirty[]|select(.xy=="??")]|length' <<<"$pre")" = 60 ] && [ "$(jq '[.dirty[]|select(.xy=="M ")]|length' <<<"$pre")" = 50 ] \
  && [ "$(printf '%s%s' "$pre" "$pre" | wc -c)" -gt 40000 ] && ok "big_fixture_has_160_dirty_past_the_argv_limit (control)" || bad "big fixture: $(jq -c '[.dirty[].xy]|group_by(.)|map({(.[0]):length})|add' <<<"$pre")"
out="$(R fix beads "$r" --stash)"; post="$(pf "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" log -1 --format=%s)" = 'bd init: initialize beads issue tracking' ] \
  && same_user_state "$pre" "$post" && [ -z "$(git -C "$r" stash list)" ] \
  && ok "fix_stash_roundtrip_150_dirty_files" || bad "150 roundtrip: $(st "$out"); $(dt "$out" | head -c 300); stash=$(git -C "$r" stash list)"
w="$(jq -c '.wrote|sort' <<<"$out")"
[ "$(jq length <<<"$w")" = 11 ] && jq -e 'index(".beads/config.yaml") and index("CLAUDE.md") and index(".gitattributes") and index(".beads/issues.jsonl")' <<<"$w" >/dev/null \
  && ok "fix_stash_150_wrote_lists_the_bd_paths" || bad "150 wrote: $w"

r="$(big_fixture "Big Mutate")"; logclear
out="$(STUB_INIT_MUTATE=README.md R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && dt "$out" | grep -q 'README.md' \
  && dt "$out" | grep -q 'stash@{0}' && ! grep -q 'config set' "$LOG" \
  && ok "fix_stash_mismatch_detected_150_dirty_files" || bad "150 mismatch: $(st "$out"); stash=$(git -C "$r" stash list)"

# --- fail closed: a compare that cannot run, or answers garbage, is a mismatch
r="$(stash_fixture "Jq Fails")"; logclear
out="$(STUB_JQ_FAIL_ON=snapdiff RJ fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && dt "$out" | grep -q 'stash@{0}' \
  && grep -q '^init ' "$LOG" && ok "fix_stash_jq_failure_keeps_stash" || bad "jq failure: $out; stash=$(git -C "$r" stash list)"
r="$(stash_fixture "Jq Garbage")"; logclear
out="$(STUB_JQ_GARBAGE_ON=snapdiff RJ fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && grep -q '^init ' "$LOG" \
  && ok "fix_stash_unparseable_compare_keeps_stash" || bad "jq garbage: $out; stash=$(git -C "$r" stash list)"
r="$(mkrepo "Wrote Fails")"; logclear
out="$(STUB_JQ_FAIL_ON=changed RJ fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'changed' && grep -q '^init ' "$LOG" \
  && ok "fix_wrote_jq_failure_fails_the_step" || bad "wrote jq failure: $out"
# the same call answering garbage with exit 0: _beads_snaps' own validator must refuse it, or the
# step reports fixed with an empty `wrote` (jq -r '.[]' over garbage yields nothing)
r="$(mkrepo "Wrote Garbage")"; logclear
out="$(STUB_JQ_GARBAGE_ON=changed RJ fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'changed' && grep -q '^init ' "$LOG"   && ok "fix_wrote_unparseable_compare_fails_the_step" || bad "wrote jq garbage: $out"

# --- a previous run's stash still held: refuse before running anything
r="$(mkrepo "Held Stash")"; echo held >> "$r/README.md"; git -C "$r" stash push -q -m ritual-beads
hsha="$(git -C "$r" rev-parse refs/stash)"; logclear
out="$(R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'stash@{0}' && dt "$out" | grep -q "$hsha" \
  && dt "$out" | grep -qF "core.autocrlf=false -c core.eol=lf -c core.safecrlf=false -c core.attributesFile=/dev/null --attr-source=" \
  && dt "$out" | grep -qF "stash apply --index $hsha\`" && dt "$out" | grep -qF 'git stash drop "stash@{0}"' && [ "$(logn)" = 0 ] \
  && [ "$(git -C "$r" stash list | grep -c '')" = 1 ] && ok "fix_refuses_while_ritual_stash_held (prints the raw-mode apply)" || bad "held stash: $out; log=$(cat "$LOG")"

# a user's own stash (no -m) made while HEAD's subject mentions ritual-beads is "WIP on <branch>: <sha>
# <subject>", not the ritual's "On <branch>: ritual-beads": it must not be refused as the ritual's
r="$(mkrepo "User Stash")"; echo mine >> "$r/README.md"; git -C "$r" add README.md; git -C "$r" commit -q -m 'notes about ritual-beads'
echo more >> "$r/README.md"; git -C "$r" stash push -q; logclear
git -C "$r" stash list | grep -q '^stash@{0}: WIP on .*ritual-beads' || bad "user stash fixture: $(git -C "$r" stash list)"
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && ! dt "$out" | grep -q 'still held' && grep -q '^init ' "$LOG"   && [ "$(git -C "$r" stash list | grep -c '')" = 1 ] && ok "fix_ignores_users_own_wip_stash_naming_ritual_beads" || bad "user wip stash: $out"

# the printed recovery command, run literally, gives back the exact bytes under core.autocrlf=true,
# where a plain `git stash apply --index` does not (control, on a copy of the same repo)
r="$(mkrepo "Raw Recover")"; git -C "$r" config core.autocrlf true
printf 'a\nb\n' > "$r/lf.txt"; commit_all "$r" lf 2>/dev/null
printf 'c\n' >> "$r/lf.txt"; printf 'p\nq\r\n' > "$r/mixed.txt"
pre="$(pf "$r")"; mkdir -p "$TMPROOT/rawexp"; cp "$r/lf.txt" "$r/mixed.txt" "$TMPROOT/rawexp/"
( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/beads.sh"; _beads_git_raw "$r" stash push -q -u -m ritual-beads ) >/dev/null 2>&1   # what an interrupted run leaves
hsha="$(git -C "$r" rev-parse -q --verify refs/stash)"; cp -r "$r" "$r plain"; logclear
out="$(R fix beads "$r" --stash)"
cmd="$(dt "$out" | sed -n 's/^[^`]*`\([^`]*\)`.*/\1/p')"
(cd "$r" && eval "$cmd") >/dev/null 2>&1
(cd "$r plain" && git stash apply --index "$hsha") >/dev/null 2>&1
[ -n "$hsha" ] && [ "$(st "$out")" = failed ] && grep -qF 'core.autocrlf=false' <<<"$cmd" && grep -qF "$hsha" <<<"$cmd" \
  && cmp -s "$r/lf.txt" "$TMPROOT/rawexp/lf.txt" && cmp -s "$r/mixed.txt" "$TMPROOT/rawexp/mixed.txt" && same_user_state "$pre" "$(pf "$r")" \
  && ! cmp -s "$r plain/lf.txt" "$TMPROOT/rawexp/lf.txt" \
  && ok "printed_raw_apply_command_restores_exact_bytes_under_autocrlf (control: plain apply differs)" \
  || bad "raw recovery: cmd=[$cmd]; lf=$(od -c "$r/lf.txt" | head -n 1); plain=$(od -c "$r plain/lf.txt" | head -n 1)"
r="$(mkrepo "Other Stash")"; echo other >> "$r/README.md"; git -C "$r" stash push -q -m 'my own work'; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && git -C "$r" stash list | grep -q 'my own work' && ok "fix_ignores_an_unrelated_stash (control)" || bad "unrelated stash: $out"

# --- attributes the raw stash cannot neutralise by itself
r="$(stash_fixture "Info Attrs")"
ia="$(git -C "$r" rev-parse --path-format=absolute --git-path info/attributes)"; mkdir -p "$(dirname "$ia")"
printf '*.txt text eol=crlf\n' > "$ia"; pre="$(pf "$r")"; logclear
out="$(R fix beads "$r" --stash)"; post="$(pf "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'info/attributes' && [ "$(logn)" = 0 ] && [ -z "$(git -C "$r" stash list)" ] \
  && same_user_state "$pre" "$post" && ok "fix_stash_refuses_nonempty_info_attributes" || bad "info/attributes: $out"
r="$(stash_fixture "Empty Info Attrs")"; ia="$(git -C "$r" rev-parse --path-format=absolute --git-path info/attributes)"
mkdir -p "$(dirname "$ia")"; : > "$ia"; logclear
[ "$(st "$(R fix beads "$r" --stash)")" = fixed ] && ok "fix_stash_allows_empty_info_attributes (control)" || bad "empty info/attributes refused"

r="$(mkrepo "Attrs File")"; git -C "$r" config core.autocrlf true
printf 'a\nb\n' > "$r/lf.txt"; commit_all "$r" lf 2>/dev/null
printf '*.txt text eol=crlf\n' > "$TMPROOT/user-attributes"; git -C "$r" config core.attributesFile "$(cygpath -m "$TMPROOT/user-attributes")"
printf 'c\n' >> "$r/lf.txt"; printf 'u\n' > "$r/untr.txt"
pre="$(pf "$r")"; out="$(R fix beads "$r" --stash 2>/dev/null)"; post="$(pf "$r")"
[ "$(st "$out")" = fixed ] && same_user_state "$pre" "$post" && ok "fix_stash_neutralises_core_attributesfile" || bad "attributesFile: $out"

# --- init failure under --stash: bd's failure and the restore are reported separately
r="$(stash_fixture "Init Fail Stash")"; pre="$(pf "$r")"; logclear
out="$(STUB_INIT_FAIL=1 R fix beads "$r" --stash)"; post="$(pf "$r")"; d="$(dt "$out")"
[ "$(st "$out")" = failed ] && grep -q 'bd init failed' <<<"$d" && grep -q 'leftovers: [^;]*\.beads/\.gitignore' <<<"$d" \
  && grep -q 'restored byte-for-byte' <<<"$d" && ! grep -qi 'NOT restored\|did not verify' <<<"$d" \
  && [ -z "$(git -C "$r" stash list)" ] && same_user_state "$pre" "$post" && [ -f "$r/.beads/.gitignore" ] \
  && ok "fix_stash_init_failure_separates_leftovers_from_restore" || bad "init fail under stash: $out; stash=$(git -C "$r" stash list)"

# the measured failure: a plain `git stash pop` turns MM into " M". A mutated copy of the skill
# must report it, proving the verification can see it.
M="$TMPROOT/mutant skill"; cp -r "$SKILL_DIR" "$M"
anchor='_beads_git_raw "$top" stash apply --index "$sha"'
if [ "$(grep -cF "$anchor" "$M/lib/beads.sh")" = 1 ]; then
  sed -i "s|_beads_git_raw \"\$top\" stash apply --index \"\$sha\"|git -C \"\$top\" stash pop|" "$M/lib/beads.sh"
  [ "$(grep -cF 'git -C "$top" stash pop' "$M/lib/beads.sh")" = 1 ] || bad "mutation did not apply"
  r="$(stash_fixture "Lost Staging")"
  out="$( stub_path "$STUBDIR"; export STUB_BD_LOG="$LOG"; bash "$M/ritual.sh" fix beads "$r" --stash )"
  [ "$(st "$out")" = failed ] && dt "$out" | grep -q 'mm.txt' && ok "fix_stash_detects_lost_staging" || bad "plain pop not detected: $out"
else
  bad "fix_stash_detects_lost_staging: restore anchor not found exactly once"
fi

finish
