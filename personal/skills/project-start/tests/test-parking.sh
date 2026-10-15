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
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = "[]" ] \
  && [ "$(count_rule "$r/CLAUDE.md")" = 1 ] && [ "$(find "$r" -name parking-lot.md -not -path '*/.git/*' | wc -l | tr -d ' ')" = 1 ] \
  && cmp -s "$r/CLAUDE.md" "$TMPROOT/claude.run1" && cmp -s "$r/docs/parking-lot.md" "$TMPROOT/lot.run1" \
  && ok "run_twice_no_duplicates" || bad "second run: $out; rules=$(count_rule "$r/CLAUDE.md")"

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

# --- the house rule line inside a CRLF file is still detected, and docs dir existing is fine
r="$(mkrepo)"; mkdir -p "$r/docs"
R fix parking-lot "$r" >/dev/null
[ "$(st "$(R check parking-lot "$r")")" = present ] && ok "existing_docs_dir_ok" || bad "docs dir"

# --- other steps untouched: unknown step still dies
finish
