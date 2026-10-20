#!/usr/bin/env bash
# Tests: parking-lot step (docs/parking-lot.md + the house rule in the project CLAUDE.md).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R() { bash "$RITUAL" "$@"; }
st() { jq -r .status <<<"$1"; }
HOUSE_LOT="$SKILL_DIR/house/parking-lot.md"
HOUSE_RULE="$SKILL_DIR/house/parking-rule.md"
count_rule() { grep -c -F -- '- **Parking lot.**' "$1"; }

# --- steps.json placement
[ "$(jq -r '.steps|map(.id)|join(" ")' "$SKILL_DIR/steps.json" | grep -o 'untracked-docs parking-lot beads-seed')" = 'untracked-docs parking-lot beads-seed' ] \
  && [ "$(jq -c '.steps[]|select(.id=="parking-lot")|[.kind,.version]' "$SKILL_DIR/steps.json")" = '["auto",1]' ] \
  && ok "steps_json_places_parking_lot_between_untracked_docs_and_beads_seed" || bad "steps.json placement"

# --- fresh repo
r="$(mkrepo)"
out="$(R check parking-lot "$r")"
[ "$(st "$out")" = absent ] && ok "check_absent_on_fresh_repo" || bad "fresh check: $out"
jq -r .detail <<<"$out" | grep -qF 'docs/parking-lot.md' && jq -r .detail <<<"$out" | grep -qF 'CLAUDE.md' \
  && ok "check_absent_names_missing_parts" || bad "detail: $out"
out="$(R fix parking-lot "$r")"
[ "$(st "$out")" = fixed ] && [ "$(jq -c '.wrote|sort' <<<"$out")" = '["CLAUDE.md","docs/parking-lot.md"]' ] \
  && ok "fix_reports_fixed_with_exact_wrote" || bad "fix: $out"
cmp -s "$r/docs/parking-lot.md" "$HOUSE_LOT" && ok "fresh_repo_parking_lot_byte_identical_to_template" || bad "parking-lot bytes differ"
{ printf '## Working rules\n\n'; cat "$HOUSE_RULE"; } > "$TMPROOT/exp.fresh"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.fresh" && ok "fresh_repo_claude_md_is_section_plus_rule" || bad "CLAUDE.md bytes: $(od -c "$r/CLAUDE.md" | head -5)"
out="$(R check parking-lot "$r")"
[ "$(st "$out")" = present ] && ok "check_present_after_fix" || bad "check after fix: $out"

# --- the user's acceptance test
r="$(mkrepo)"
R fix parking-lot "$r" >/dev/null
cp "$r/CLAUDE.md" "$TMPROOT/claude.run1"; cp "$r/docs/parking-lot.md" "$TMPROOT/lot.run1"
out="$(R fix parking-lot "$r")"
[ "$(st "$out")" = already ] \
  && [ "$(count_rule "$r/CLAUDE.md")" = 1 ] && [ "$(find "$r" -name parking-lot.md -not -path '*/.git/*' | wc -l | tr -d ' ')" = 1 ] \
  && cmp -s "$r/CLAUDE.md" "$TMPROOT/claude.run1" && cmp -s "$r/docs/parking-lot.md" "$TMPROOT/lot.run1" \
  && ok "run_twice_no_duplicates" || bad "second run: $out; rules=$(count_rule "$r/CLAUDE.md")"
# I1: run 1 was never committed, so run 2 lists both files again for the commit step to ask about
[ "$(jq -c '.wrote|sort' <<<"$out")" = '["CLAUDE.md","docs/parking-lot.md"]' ] && jq -r .detail <<<"$out" | grep -qF 'not yet committed' \
  && ok "rerun_lists_the_files_an_uncommitted_run_left" || bad "rerun wrote: $out"
git -C "$r" add CLAUDE.md docs/parking-lot.md && git -C "$r" commit -q -m 'ritual'
out="$(R fix parking-lot "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = "[]" ] && ! jq -r .detail <<<"$out" | grep -qF 'not yet committed' \
  && ok "rerun_after_the_commit_lists_nothing" || bad "rerun after commit: $out"

# --- existing parking lot is never touched
r="$(mkrepo)"; mkdir -p "$r/docs"
printf '# Parking lot\n\n- idea one (2026-01-01, chat)\n- idea two (2026-01-02, review)\n- idea three (2026-01-03)\n' > "$r/docs/parking-lot.md"
cp "$r/docs/parking-lot.md" "$TMPROOT/lot.before"
out="$(R fix parking-lot "$r")"
cmp -s "$r/docs/parking-lot.md" "$TMPROOT/lot.before" && [ "$(jq -c '.wrote' <<<"$out")" = '["CLAUDE.md"]' ] \
  && ok "existing_parking_lot_untouched" || bad "lot changed or wrote wrong: $out"
out="$(R check parking-lot "$r")"
[ "$(st "$out")" = present ] && ok "check_present_with_user_lot_and_rule" || bad "check: $out"

# --- rule is only missing -> only CLAUDE.md is named
r="$(mkrepo)"; mkdir -p "$r/docs"; cp "$HOUSE_LOT" "$r/docs/parking-lot.md"
out="$(R check parking-lot "$r")"
[ "$(st "$out")" = absent ] && jq -r .detail <<<"$out" | grep -qF 'CLAUDE.md' && ! jq -r .detail <<<"$out" | grep -qF 'docs/parking-lot.md missing' \
  && ok "check_absent_rule_only" || bad "rule-only: $out"

# --- Working rules exists, followed by another section
r="$(mkrepo)"
printf '# Proj\n\n## Working rules\n\n- Be kind.\n- Test first.\n\n## Other\n\nstuff\n' > "$r/CLAUDE.md"
R fix parking-lot "$r" >/dev/null
{ printf '# Proj\n\n## Working rules\n\n- Be kind.\n- Test first.\n'; cat "$HOUSE_RULE"; printf '\n## Other\n\nstuff\n'; } > "$TMPROOT/exp.mid"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.mid" && ok "existing_working_rules_section_appended_at_end" || bad "mid bytes: $(cat "$r/CLAUDE.md")"

# --- Working rules is the last section, no trailing newline
r="$(mkrepo)"
printf '## Working rules\n\n- Be kind.' > "$r/CLAUDE.md"
R fix parking-lot "$r" >/dev/null
{ printf '## Working rules\n\n- Be kind.\n'; cat "$HOUSE_RULE"; } > "$TMPROOT/exp.last"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.last" && ok "working_rules_last_section_unterminated" || bad "last bytes: $(cat "$r/CLAUDE.md")"

# --- no Working rules section
r="$(mkrepo)"
printf '# Proj\n\nSome notes.\n\n## Build\n\nmake\n' > "$r/CLAUDE.md"
cp "$r/CLAUDE.md" "$TMPROOT/before.nowr"
R fix parking-lot "$r" >/dev/null
sz=$(wc -c < "$TMPROOT/before.nowr")
head -c "$sz" "$r/CLAUDE.md" | cmp -s - "$TMPROOT/before.nowr" && grep -qxF '## Working rules' "$r/CLAUDE.md" \
  && [ "$(count_rule "$r/CLAUDE.md")" = 1 ] && tail -n 7 "$r/CLAUDE.md" | cmp -s - "$HOUSE_RULE" \
  && ok "no_working_rules_section" || bad "no-WR: $(cat "$r/CLAUDE.md")"

# --- a different rule is left alone
r="$(mkrepo)"
printf '# Proj\n\n## Working rules\n\n- Be kind.\n- New ideas go to `docs/parking-lot.md`, not the current milestone.\n' > "$r/CLAUDE.md"
cp "$r/CLAUDE.md" "$TMPROOT/before.diff"
out="$(R check parking-lot "$r")"
[ "$(st "$out")" = absent ] && jq -r .detail <<<"$out" | grep -qF 'different rule exists (line 6)' \
  && ok "check_reports_different_rule_with_line" || bad "check diff: $out"
out="$(R fix parking-lot "$r")"
[ "$(st "$out")" = absent ] && jq -r .detail <<<"$out" | grep -qF 'different rule exists' \
  && jq -r .detail <<<"$out" | grep -qF 'house rule needs ask' && cmp -s "$r/CLAUDE.md" "$TMPROOT/before.diff" \
  && [ "$(jq -c .wrote <<<"$out")" = '["docs/parking-lot.md"]' ] && cmp -s "$r/docs/parking-lot.md" "$HOUSE_LOT" \
  && ok "different_rule_left_alone" || bad "fix diff: $out"

# --- CRLF CLAUDE.md
r="$(mkrepo)"
printf '# Proj\r\n\r\n## Working rules\r\n\r\n- Be kind.\r\n\r\n## Other\r\n\r\nstuff\r\n' > "$r/CLAUDE.md"
R fix parking-lot "$r" >/dev/null
{ printf '# Proj\r\n\r\n## Working rules\r\n\r\n- Be kind.\r\n'; sed 's/$/\r/' "$HOUSE_RULE"; printf '\r\n## Other\r\n\r\nstuff\r\n'; } > "$TMPROOT/exp.crlf"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.crlf" && ok "crlf_claude_md" || bad "crlf bytes: $(od -c "$r/CLAUDE.md" | head -20)"
out="$(R fix parking-lot "$r")"
[ "$(st "$out")" = already ] && cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.crlf" && ok "crlf_rerun_already" || bad "crlf rerun: $out"

# --- fenced "## " line inside Working rules does not end the section
r="$(mkrepo)"
printf '## Working rules\n\n- Be kind.\n\n```\n## not a heading\n```\n\n## Other\n\nstuff\n' > "$r/CLAUDE.md"
R fix parking-lot "$r" >/dev/null
{ printf '## Working rules\n\n- Be kind.\n\n```\n## not a heading\n```\n'; cat "$HOUSE_RULE"; printf '\n## Other\n\nstuff\n'; } > "$TMPROOT/exp.fence"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.fence" && ok "fenced_heading_does_not_end_section" || bad "fence bytes: $(cat "$r/CLAUDE.md")"

# --- a fenced "## Working rules" is not the section
r="$(mkrepo)"
printf '# Proj\n\n~~~\n## Working rules\n~~~\n' > "$r/CLAUDE.md"
R fix parking-lot "$r" >/dev/null
{ printf '# Proj\n\n~~~\n## Working rules\n~~~\n\n## Working rules\n\n'; cat "$HOUSE_RULE"; } > "$TMPROOT/exp.fenchead"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.fenchead" && ok "fenced_working_rules_heading_ignored" || bad "fenchead bytes: $(cat "$r/CLAUDE.md")"

# --- empty Working rules section
r="$(mkrepo)"
printf '## Working rules\n\n\n## Other\n\nstuff\n' > "$r/CLAUDE.md"
R fix parking-lot "$r" >/dev/null
{ printf '## Working rules\n\n'; cat "$HOUSE_RULE"; printf '\n## Other\n\nstuff\n'; } > "$TMPROOT/exp.empty"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.empty" && ok "empty_working_rules_section" || bad "empty bytes: $(cat "$r/CLAUDE.md")"

# --- a ### subsection does not end Working rules
r="$(mkrepo)"
printf '## Working rules\n\n- Be kind.\n\n### Sub\n\n- sub item\n\n## Other\n\nstuff\n' > "$r/CLAUDE.md"
R fix parking-lot "$r" >/dev/null
{ printf '## Working rules\n\n- Be kind.\n\n### Sub\n\n- sub item\n'; cat "$HOUSE_RULE"; printf '\n## Other\n\nstuff\n'; } > "$TMPROOT/exp.sub"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.sub" && ok "subsection_does_not_end_working_rules" || bad "sub bytes: $(cat "$r/CLAUDE.md")"

# --- after a fresh fix (LF file) the rule is detected; an existing docs dir is fine
r="$(mkrepo)"; mkdir -p "$r/docs"
R fix parking-lot "$r" >/dev/null
[ "$(st "$(R check parking-lot "$r")")" = present ] && ok "existing_docs_dir_ok" || bad "docs dir"

# --- the scan reads fences as the insert does: a rule or a parking-lot mention quoted in an example
# block is neither the rule nor a different rule. Each case pairs with the same text unfenced.
r="$(mkrepo)"; mkdir -p "$r/docs"; cp "$HOUSE_LOT" "$r/docs/parking-lot.md"
{ printf '# Proj\n\nExample of the rule:\n\n```md\n'; cat "$HOUSE_RULE"; printf '```\n'; } > "$r/CLAUDE.md"
out="$(R check parking-lot "$r")"
[ "$(st "$out")" = absent ] && jq -r .detail <<<"$out" | grep -qF 'lacks the parking-lot rule' \
  && ok "fenced_rule_is_not_the_rule" || bad "fenced rule: $out"
R fix parking-lot "$r" >/dev/null
[ "$(st "$(R check parking-lot "$r")")" = present ] && [ "$(count_rule "$r/CLAUDE.md")" = 2 ] \
  && ok "fenced_rule_fix_adds_the_real_rule" || bad "fenced rule fix: rules=$(count_rule "$r/CLAUDE.md") $(R check parking-lot "$r")"
r="$(mkrepo)"; mkdir -p "$r/docs"; cp "$HOUSE_LOT" "$r/docs/parking-lot.md"
{ printf '# Proj\n\n'; cat "$HOUSE_RULE"; } > "$r/CLAUDE.md"
[ "$(st "$(R check parking-lot "$r")")" = present ] && ok "unfenced_rule_is_the_rule (control)" || bad "unfenced rule control"
r="$(mkrepo)"; mkdir -p "$r/docs"; cp "$HOUSE_LOT" "$r/docs/parking-lot.md"
printf '# Proj\r\n\r\n~~~\r\nWe keep ideas in docs/parking-lot.md.\r\n~~~\r\n' > "$r/CLAUDE.md"
out="$(R check parking-lot "$r")"
[ "$(st "$out")" = absent ] && ! jq -r .detail <<<"$out" | grep -qF 'different rule' \
  && ok "fenced_mention_is_not_a_different_rule (crlf)" || bad "fenced mention: $out"
r="$(mkrepo)"; mkdir -p "$r/docs"; cp "$HOUSE_LOT" "$r/docs/parking-lot.md"
printf '# Proj\r\n\r\nWe keep ideas in docs/parking-lot.md.\r\n' > "$r/CLAUDE.md"
jq -r .detail <<<"$(R check parking-lot "$r")" | grep -qF 'different rule exists (line 3)' \
  && ok "unfenced_mention_is_a_different_rule (control)" || bad "unfenced mention control: $(R check parking-lot "$r")"

# --- other steps untouched: unknown step still dies
finish
