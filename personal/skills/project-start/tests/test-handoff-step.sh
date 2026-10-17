#!/usr/bin/env bash
# Tests: handoff step (NEXT.md, the .claude/handoff.json marker, the CLAUDE.md session routine) and
# the handoff-commit subcommand (the first handoff: commit, holding NEXT.md alone).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R() { bash "$RITUAL" "$@"; }
st() { jq -r .status <<<"$1"; }
det() { jq -r .detail <<<"$1"; }
HOUSE_NEXT="$SKILL_DIR/house/NEXT.md"
HOUSE_ROUTINE="$SKILL_DIR/house/session-routine.md"
MARK='- **Handoff.**'
SUBJ='handoff: NEXT.md created by the project-start ritual'
anchors() { git -C "$1" log --format=%s | grep -c '^handoff:'; }
head_of() { git -C "$1" rev-parse HEAD; }
idx() { git -C "$1" ls-files -s; git -C "$1" diff --cached --name-status; }
crs() { tr -cd '\r' < "$1" | wc -c | tr -d ' '; }

# A stub git that fails one subcommand (exit 128) and passes everything else to the real git.
STUBDIR="$TMPROOT/stub bin"; mkdir -p "$STUBDIR"
{ printf '#!/usr/bin/env bash\nREAL_GIT=%q\n' "$(command -v git)"; cat <<'WRAP'
if [ "${1:-}" = -C ] && [ "${3:-}" = "${STUB_GIT_FAIL:-}" ]; then echo "stub: $3 fails" >&2; exit 128; fi
exec "$REAL_GIT" "$@"
WRAP
} > "$STUBDIR/git"; chmod +x "$STUBDIR/git"
RS() { ( stub_path "$STUBDIR"; export STUB_GIT_FAIL="$1"; shift; bash "$RITUAL" "$@" ); }

# --- house files
[ "$(head -n 1 "$HOUSE_ROUTINE")" = '## Session routine' ] && [ -z "$(sed -n 2p "$HOUSE_ROUTINE")" ] \
  && [ "$(sed -n 3p "$HOUSE_ROUTINE" | head -c ${#MARK})" = "$MARK" ] && sed -n 3p "$HOUSE_ROUTINE" | grep -qF '`handoff` skill' \
  && ok "house_routine_heading_then_marker_bullet_naming_the_skill" || bad "house routine shape: $(head -n 3 "$HOUSE_ROUTINE")"
n="$(grep -c '^- ' "$HOUSE_ROUTINE")"
[ "$n" -ge 3 ] && [ "$n" -le 5 ] && ok "house_routine_is_a_3_to_5_line_pointer" || bad "routine bullets: $n"
grep '^- ' "$HOUSE_ROUTINE" | grep -F '.claude/handoff.json' | grep -qF '(default: "How did the last change go?")' \
  && ok "house_routine_gives_the_default_question" || bad "default question missing: $(cat "$HOUSE_ROUTINE")"
[ "$(crs "$HOUSE_ROUTINE")" = 0 ] && [ "$(crs "$HOUSE_NEXT")" = 0 ] && ok "house_files_are_lf" || bad "house files carry CR"
[ "$(grep '^#' "$HOUSE_NEXT" | tr '\n' '|')" = '# NEXT|## Where we are|## How to run|## How it behaves|## Try this|## Things you might notice|## Tell me if|## Housekeeping|## Known rough edges|## Feedback log|' ] \
  && [ "$(grep -c '^_.*_$' "$HOUSE_NEXT")" = 9 ] && ok "next_md_template_has_the_spec_sections_each_with_a_hint" || bad "template sections: $(grep '^#' "$HOUSE_NEXT")"

# --- steps.json placement
[ "$(jq -r '.steps|map(.id)|join(" ")' "$SKILL_DIR/steps.json" | grep -o 'baseline handoff commit record$')" = 'baseline handoff commit record' ] \
  && [ "$(jq -c '.steps[]|select(.id=="handoff")|[.kind,.version]' "$SKILL_DIR/steps.json")" = '["ask",1]' ] \
  && ok "steps_json_places_handoff_between_baseline_and_commit" || bad "steps.json placement"

# --- ritual.sh wiring
R bogus "$(mkrepo)" 2>"$TMPROOT/usage.err"; rc=$?
[ "$rc" = 2 ] && grep -qF 'handoff-commit' "$TMPROOT/usage.err" && ok "usage_string_names_handoff_commit" || bad "usage: rc=$rc $(cat "$TMPROOT/usage.err")"
R handoff-commit >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok "handoff_commit_without_repo_exits_2" || bad "no-repo rc=$rc"
R handoff-commit "$TMPROOT" >/dev/null 2>"$TMPROOT/nr.err"; rc=$?
[ "$rc" = 2 ] && grep -q 'not a git repository' "$TMPROOT/nr.err" && ok "handoff_commit_on_non_repo_exits_2" || bad "non-repo rc=$rc"

# --- fresh repo: fix, then the ritual's commit step, then handoff-commit
r="$(mkrepo)"
out="$(R check handoff "$r")"
[ "$(st "$out")" = absent ] && det "$out" | grep -qF 'NEXT.md missing' && det "$out" | grep -qF '.claude/handoff.json missing' \
  && det "$out" | grep -qF 'CLAUDE.md missing' && det "$out" | grep -qF 'no handoff: commit' \
  && ok "check_absent_on_fresh_repo_names_each_part" || bad "fresh check: $out"
out="$(R fix handoff "$r")"
[ "$(st "$out")" = fixed ] && [ "$(jq -c '.wrote|sort' <<<"$out")" = '[".claude/handoff.json","CLAUDE.md"]' ] \
  && ok "fresh_fix_fixed_wrote_marker_and_claude_md_never_next_md" || bad "fresh fix: $out"
det "$out" | grep -qF 'NEXT.md created; run handoff-commit after the commit step' && ok "fresh_fix_detail_says_run_handoff_commit" || bad "fresh detail: $out"
cmp -s "$r/NEXT.md" "$HOUSE_NEXT" && ok "fresh_next_md_byte_identical_to_template" || bad "NEXT.md bytes differ"
cmp -s "$r/CLAUDE.md" "$HOUSE_ROUTINE" && ok "fresh_claude_md_is_exactly_the_house_section" || bad "CLAUDE.md: $(cat "$r/CLAUDE.md")"
[ "$(tr -d '\r' < "$r/.claude/handoff.json" | jq -c .)" = '{}' ] && [ "$(crs "$r/.claude/handoff.json")" = 0 ] \
  && ok "fresh_marker_is_empty_object_lf" || bad "marker: $(cat "$r/.claude/handoff.json")"
out="$(R check handoff "$r")"
[ "$(st "$out")" = absent ] && [ "$(det "$out")" = 'no handoff: commit' ] && ok "check_after_fix_lacks_only_the_handoff_commit" || bad "check after fix: $out"
git -C "$r" add CLAUDE.md .claude/handoff.json && git -C "$r" commit -q -m 'chore: ritual setup'   # the ritual's commit step
h0="$(head_of "$r")"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" rev-list --count "$h0..HEAD")" = 1 ] && ok "handoff_commit_makes_exactly_one_commit" || bad "handoff-commit: $out"
[ "$(git -C "$r" show --name-only --format= HEAD)" = NEXT.md ] && ok "handoff_commit_holds_next_md_alone" || bad "files: $(git -C "$r" show --name-only --format= HEAD)"
printf '%s\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' "$SUBJ" > "$TMPROOT/exp.msg"
git -C "$r" cat-file commit HEAD | sed "1,/^$/d" | cmp -s - "$TMPROOT/exp.msg" && ok "handoff_commit_message_exact" || bad "message: $(git -C "$r" log -1 --format=%B)"
det "$out" | grep -qF "$(git -C "$r" rev-parse --short=7 HEAD)" && ok "handoff_commit_detail_names_the_commit" || bad "detail: $out"
[ -z "$(git -C "$r" status --porcelain)" ] && [ "$(git -C "$r" log -1 --format=%s)" = "$SUBJ" ] && ok "handoff_commit_leaves_a_clean_tree" || bad "status: $(git -C "$r" status --porcelain)"
out="$(R check handoff "$r")"
[ "$(st "$out")" = present ] && ok "check_present_after_fix_commit_and_handoff_commit" || bad "check present: $out"

# --- rerun is idempotent
cp "$r/NEXT.md" "$TMPROOT/n1"; cp "$r/CLAUDE.md" "$TMPROOT/c1"; cp "$r/.claude/handoff.json" "$TMPROOT/m1"
out="$(R fix handoff "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] \
  && cmp -s "$r/NEXT.md" "$TMPROOT/n1" && cmp -s "$r/CLAUDE.md" "$TMPROOT/c1" && cmp -s "$r/.claude/handoff.json" "$TMPROOT/m1" \
  && ok "rerun_fix_is_already_with_no_writes_and_identical_bytes" || bad "rerun fix: $out"
det "$out" | grep -qF 'NEXT.md kept' && ok "rerun_fix_detail_says_next_md_kept" || bad "rerun detail: $out"
h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = already ] && [ "$(head_of "$r")" = "$h1" ] && [ "$(anchors "$r")" = 1 ] \
  && ok "rerun_handoff_commit_is_already_one_anchor" || bad "rerun handoff-commit: $out"
r2="$(mkrepo)"; R fix handoff "$r2" >/dev/null; cp "$r2/NEXT.md" "$TMPROOT/n2"; cp "$r2/CLAUDE.md" "$TMPROOT/c2"
out="$(R fix handoff "$r2")"   # a second fix BEFORE any commit is also a no-op
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && cmp -s "$r2/NEXT.md" "$TMPROOT/n2" && cmp -s "$r2/CLAUDE.md" "$TMPROOT/c2" \
  && ok "rerun_fix_before_commit_is_already" || bad "rerun before commit: $out"

# --- an existing NEXT.md and anchor are kept
r="$(mkrepo)"
printf '# Our notes\n\nhand-written\n' > "$r/NEXT.md"
git -C "$r" add NEXT.md && git -C "$r" commit -q -m 'handoff: our own first handoff'
cp "$r/NEXT.md" "$TMPROOT/own"; h1="$(head_of "$r")"
out="$(R fix handoff "$r")"
cmp -s "$r/NEXT.md" "$TMPROOT/own" && det "$out" | grep -qF 'NEXT.md kept' && ! jq -e '.wrote|index("NEXT.md")' <<<"$out" >/dev/null \
  && ok "existing_next_md_kept_byte_identical" || bad "own NEXT.md: $out"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = already ] && [ "$(head_of "$r")" = "$h1" ] && cmp -s "$r/NEXT.md" "$TMPROOT/own" \
  && ok "existing_anchor_kept_no_new_commit" || bad "own anchor: $out"
det "$out" | grep -qF "$(git -C "$r" rev-parse --short=7 HEAD)" && ok "already_detail_names_the_existing_anchor" || bad "already detail: $out"

# --- anchor detection is subject-only
r="$(mkrepo)"
printf 'chore: tidy\n\nhandoff: this line is in the body only\n' > "$TMPROOT/body.msg"
git -C "$r" commit -q --allow-empty -F "$TMPROOT/body.msg"
cp "$HOUSE_NEXT" "$r/NEXT.md"
out="$(R check handoff "$r")"
det "$out" | grep -qF 'no handoff: commit' && ok "body_only_handoff_line_is_not_an_anchor_check" || bad "body-only check: $out"
h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" rev-list --count "$h1..HEAD")" = 1 ] && ok "body_only_handoff_line_is_not_an_anchor_commit" || bad "body-only commit: $out"

# --- a different session routine
r="$(mkrepo)"
printf '# Proj\n\n## Session routine\n\n- Read the notes file.\n- Ask how it went.\n\n## Other\n\nstuff\n' > "$r/CLAUDE.md"
cp "$r/CLAUDE.md" "$TMPROOT/before.diff"
out="$(R check handoff "$r")"
[ "$(st "$out")" = absent ] && det "$out" | grep -qF 'different session routine (line 3)' && ok "check_reports_different_routine_with_line" || bad "check diff: $out"
out="$(R fix handoff "$r")"
[ "$(st "$out")" = absent ] && det "$out" | grep -qF 'different session routine (line 3); needs --replace-routine' \
  && cmp -s "$r/CLAUDE.md" "$TMPROOT/before.diff" && [ "$(jq -c .wrote <<<"$out")" = '[".claude/handoff.json"]' ] \
  && cmp -s "$r/NEXT.md" "$HOUSE_NEXT" && ok "different_routine_left_alone" || bad "fix diff: $out"
out="$(R fix handoff "$r" --replace-routine)"
{ printf '# Proj\n\n'; cat "$HOUSE_ROUTINE"; printf '\n## Other\n\nstuff\n'; } > "$TMPROOT/exp.repl"
[ "$(st "$out")" = fixed ] && [ "$(jq -c .wrote <<<"$out")" = '["CLAUDE.md"]' ] && cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.repl" \
  && ok "different_routine_replaced_on_flag" || bad "replace: $out; $(cat "$r/CLAUDE.md")"
det "$out" | grep -qF 'session routine replaced (line 3)' && ok "replace_detail_names_the_line" || bad "replace detail: $out"
out="$(R fix handoff "$r" --replace-routine)"
[ "$(st "$out")" = already ] && cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.repl" && ok "replace_flag_on_house_section_is_a_noop" || bad "replace noop: $out"

# --- the different section is the last one: replaced to EOF
r="$(mkrepo)"
printf '# Proj\n\nintro\n\n## Session routine\n\n- Mine.' > "$r/CLAUDE.md"
R fix handoff "$r" --replace-routine >/dev/null
{ printf '# Proj\n\nintro\n\n'; cat "$HOUSE_ROUTINE"; } > "$TMPROOT/exp.last"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.last" && ok "replace_last_section_to_eof" || bad "replace last: $(cat "$r/CLAUDE.md")"

# --- a fenced "## " inside the different section does not end it; ### does not either
r="$(mkrepo)"
printf '## Session routine\n\n- Mine.\n\n```\n## not a heading\n```\n\n### Sub\n\n- more\n\n## Other\n\nstuff\n' > "$r/CLAUDE.md"
R fix handoff "$r" --replace-routine >/dev/null
{ cat "$HOUSE_ROUTINE"; printf '\n## Other\n\nstuff\n'; } > "$TMPROOT/exp.fsec"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.fsec" && ok "replace_spans_fenced_heading_and_subsection" || bad "fenced section: $(cat "$r/CLAUDE.md")"

# --- a fenced "## Session routine" is not the section
r="$(mkrepo)"
printf '# Proj\n\n```markdown\n## Session routine\n- example only\n```\n' > "$r/CLAUDE.md"
out="$(R check handoff "$r")"
det "$out" | grep -qF 'CLAUDE.md lacks the session routine' && ! det "$out" | grep -qF 'different' \
  && ok "fenced_session_routine_heading_is_not_the_section_check" || bad "fenced check: $out"
out="$(R fix handoff "$r")"
{ printf '# Proj\n\n```markdown\n## Session routine\n- example only\n```\n\n'; cat "$HOUSE_ROUTINE"; } > "$TMPROOT/exp.fhead"
[ "$(st "$out")" = fixed ] && cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.fhead" && ok "fenced_session_routine_heading_is_not_the_section_fix" || bad "fenced fix: $out; $(cat "$r/CLAUDE.md")"

# --- the marker bullet outside a ## Session routine section does not count
r="$(mkrepo)"
{ printf '# Proj\n\n## Notes\n\n'; sed -n 3p "$HOUSE_ROUTINE"; } > "$r/CLAUDE.md"
out="$(R check handoff "$r")"
det "$out" | grep -qF 'CLAUDE.md lacks the session routine' && ok "marker_bullet_outside_the_section_not_counted" || bad "stray marker: $out"
# ... nor does it count inside a fence within the section
r="$(mkrepo)"
{ printf '## Session routine\n\n```\n'; sed -n 3p "$HOUSE_ROUTINE"; printf '```\n'; } > "$r/CLAUDE.md"
out="$(R check handoff "$r")"
det "$out" | grep -qF 'different session routine (line 1)' && ok "fenced_marker_bullet_not_counted" || bad "fenced marker: $out"

# --- appending to an existing CLAUDE.md
r="$(mkrepo)"
printf '# Proj\n\n## Build\n\nmake\n' > "$r/CLAUDE.md"
R fix handoff "$r" >/dev/null
{ printf '# Proj\n\n## Build\n\nmake\n\n'; cat "$HOUSE_ROUTINE"; } > "$TMPROOT/exp.app"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.app" && ok "append_after_existing_content_with_one_blank_line" || bad "append: $(cat "$r/CLAUDE.md")"
r="$(mkrepo)"
printf '# Proj\n\nlast line' > "$r/CLAUDE.md"
R fix handoff "$r" >/dev/null
{ printf '# Proj\n\nlast line\n\n'; cat "$HOUSE_ROUTINE"; } > "$TMPROOT/exp.unt"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.unt" && ok "append_after_unterminated_last_line" || bad "unterminated: $(od -c "$r/CLAUDE.md" | tail -5)"
r="$(mkrepo)"
printf '# Proj\n\n' > "$r/CLAUDE.md"
R fix handoff "$r" >/dev/null
{ printf '# Proj\n\n'; cat "$HOUSE_ROUTINE"; } > "$TMPROOT/exp.blank"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.blank" && ok "append_after_trailing_blank_line_adds_no_second_blank" || bad "blank: $(cat "$r/CLAUDE.md")"

# --- CRLF CLAUDE.md keeps its line ending, and is recognised on rerun
r="$(mkrepo)"
printf '# Proj\r\n\r\n## Build\r\n\r\nmake\r\n' > "$r/CLAUDE.md"
R fix handoff "$r" >/dev/null
{ printf '# Proj\r\n\r\n## Build\r\n\r\nmake\r\n\r\n'; sed 's/$/\r/' "$HOUSE_ROUTINE"; } > "$TMPROOT/exp.crlf"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.crlf" && ok "crlf_claude_md_appended_with_crlf" || bad "crlf bytes: $(od -c "$r/CLAUDE.md" | tail -5)"
out="$(R fix handoff "$r")"
[ "$(st "$out")" = already ] && cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.crlf" && ok "crlf_rerun_already" || bad "crlf rerun: $out"
r="$(mkrepo)"
printf '# Proj\r\n\r\n## Session routine\r\n\r\n- Mine.\r\n\r\n## Other\r\n' > "$r/CLAUDE.md"
R fix handoff "$r" --replace-routine >/dev/null
{ printf '# Proj\r\n\r\n'; sed 's/$/\r/' "$HOUSE_ROUTINE"; printf '\r\n## Other\r\n'; } > "$TMPROOT/exp.crlfr"
cmp -s "$r/CLAUDE.md" "$TMPROOT/exp.crlfr" && ok "crlf_replace_keeps_crlf" || bad "crlf replace: $(od -c "$r/CLAUDE.md" | tail -8)"

# --- marker keys only when given
r="$(mkrepo)"; R fix handoff "$r" --ask 'How did the build feel?' >/dev/null
[ "$(tr -d '\r' < "$r/.claude/handoff.json" | jq -c .)" = '{"ask":"How did the build feel?"}' ] && ok "marker_ask_only" || bad "ask only: $(cat "$r/.claude/handoff.json")"
r="$(mkrepo)"; R fix handoff "$r" --paths 'assets/** data/*.json' >/dev/null
[ "$(tr -d '\r' < "$r/.claude/handoff.json" | jq -c .)" = '{"paths":["assets/**","data/*.json"]}' ] && ok "marker_paths_only_split_on_spaces" || bad "paths only: $(cat "$r/.claude/handoff.json")"
r="$(mkrepo)"; R fix handoff "$r" --paths 'a.txt' --ask 'Comment ça va? "quoted" \ back' >/dev/null
[ "$(tr -d '\r' < "$r/.claude/handoff.json" | jq -c .)" = '{"ask":"Comment ça va? \"quoted\" \\ back","paths":["a.txt"]}' ] && [ "$(crs "$r/.claude/handoff.json")" = 0 ] \
  && ok "marker_both_keys_utf8_and_quotes_round_trip" || bad "both: $(cat "$r/.claude/handoff.json")"
r="$(mkrepo)"; mkdir -p "$r/.claude"; printf '{"ask": "theirs"}\n' > "$r/.claude/handoff.json"; cp "$r/.claude/handoff.json" "$TMPROOT/theirs"
out="$(R fix handoff "$r" --ask 'mine' --paths 'x')"
cmp -s "$r/.claude/handoff.json" "$TMPROOT/theirs" && det "$out" | grep -qF 'marker kept (--ask/--paths not applied)' \
  && ! jq -e '.wrote|index(".claude/handoff.json")' <<<"$out" >/dev/null && ok "existing_marker_kept_flags_not_applied" || bad "marker kept: $out"

# --- bad arguments write nothing
for args in "--bogus" "--ask" "--ask=" "--paths" "--paths ' '"; do
  r="$(mkrepo)"
  eval "R fix handoff \"\$r\" $args" >/dev/null 2>"$TMPROOT/arg.err"; rc=$?
  [ "$rc" = 2 ] && [ -z "$(git -C "$r" status --porcelain)" ] && grep -qF 'fix handoff:' "$TMPROOT/arg.err" && ok "fix_rejects_bad_argument_without_writing ($args)" || bad "bad arg $args: rc=$rc $(git -C "$r" status --porcelain)"
done

# --- the marker is git-ignored
r="$(mkrepo)"
printf '.claude/\n' > "$r/.gitignore"; git -C "$r" add .gitignore && git -C "$r" commit -q -m ignore
out="$(R fix handoff "$r")"
[ "$(st "$out")" = fixed ] && [ -f "$r/.claude/handoff.json" ] && [ "$(jq -c .wrote <<<"$out")" = '["CLAUDE.md"]' ] \
  && det "$out" | grep -qF "marker is git-ignored here; cloud sessions won't see it" && ok "marker_ignored_reported_and_not_in_wrote" || bad "ignored fix: $out"
out="$(R check handoff "$r")"
det "$out" | grep -qF "marker is git-ignored here; cloud sessions won't see it" && ok "marker_ignored_reported_by_check" || bad "ignored check: $out"
git -C "$r" add CLAUDE.md && git -C "$r" commit -q -m setup && R handoff-commit "$r" >/dev/null
out="$(R check handoff "$r")"
[ "$(st "$out")" = present ] && det "$out" | grep -qF 'git-ignored' && ok "marker_ignored_check_still_present_with_note" || bad "ignored present: $out"
out="$(R fix handoff "$r")"
[ "$(st "$out")" = already ] && det "$out" | grep -qF 'git-ignored' && ok "marker_ignored_rerun_already_with_note" || bad "ignored rerun: $out"
r="$(mkrepo)"
out="$(R check handoff "$r")"
! det "$out" | grep -qF 'ignored' && ok "marker_not_ignored_no_note" || bad "spurious ignore note: $out"

# --- ignore status cannot be read
r="$(mkrepo)"
out="$(RS check-ignore fix handoff "$r")"
[ "$(st "$out")" = unknown ] && [ -f "$r/.claude/handoff.json" ] && ! jq -e '.wrote|index(".claude/handoff.json")' <<<"$out" >/dev/null \
  && det "$out" | grep -qF 'could not tell whether the marker is git-ignored' && ok "ignore_status_unreadable_fix_is_unknown" || bad "ignore unknown: $out"

# --- history cannot be read
r="$(mkrepo)"; R fix handoff "$r" >/dev/null
out="$(RS log check handoff "$r")"
[ "$(st "$out")" = unknown ] && det "$out" | grep -qF 'could not read the history' && ok "history_unreadable_check_is_unknown" || bad "log unknown: $out"
h1="$(head_of "$r")"
out="$(RS log handoff-commit "$r")"
[ "$(st "$out")" = unknown ] && [ "$(head_of "$r")" = "$h1" ] && ok "history_unreadable_handoff_commit_is_unknown_no_commit" || bad "log unknown commit: $out"
rm -f "$r/NEXT.md"
out="$(RS log check handoff "$r")"
[ "$(st "$out")" = absent ] && det "$out" | grep -qF 'NEXT.md missing' && ok "a_missing_part_beats_unknown_history" || bad "absent over unknown: $out"

# --- handoff-commit refuses other staged paths
r="$(mkrepo)"; R fix handoff "$r" >/dev/null
echo change >> "$r/README.md"; git -C "$r" add README.md
idx "$r" > "$TMPROOT/idx.before"; h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
idx "$r" > "$TMPROOT/idx.after"
[ "$(st "$out")" = failed ] && [ "$(head_of "$r")" = "$h1" ] && cmp -s "$TMPROOT/idx.before" "$TMPROOT/idx.after" \
  && [ -z "$(git -C "$r" ls-files -- NEXT.md)" ] && ok "handoff_commit_refuses_other_staged_paths" || bad "staged others: $out"
det "$out" | grep -qF 'README.md' && ok "refusal_names_the_staged_path" || bad "refusal detail: $out"
# a staged rename INTO NEXT.md stages a deletion too
r="$(mkrepo)"
git -C "$r" mv README.md NEXT.md; idx "$r" > "$TMPROOT/idx.before"; h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
idx "$r" > "$TMPROOT/idx.after"
[ "$(st "$out")" = failed ] && [ "$(head_of "$r")" = "$h1" ] && cmp -s "$TMPROOT/idx.before" "$TMPROOT/idx.after" \
  && det "$out" | grep -qF 'README.md' && ok "staged_rename_into_next_md_is_refused" || bad "rename: $out"

# --- handoff-commit with unstaged and untracked work around it
r="$(mkrepo)"; R fix handoff "$r" >/dev/null
echo edit >> "$r/README.md"; echo scratch > "$r/scratch.txt"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" show --name-only --format= HEAD)" = NEXT.md ] \
  && [ "$(git -C "$r" status --porcelain -- README.md scratch.txt | tr '\n' '|')" = ' M README.md|?? scratch.txt|' ] \
  && ok "handoff_commit_leaves_unstaged_and_untracked_work_alone" || bad "unstaged: $out; $(git -C "$r" status --porcelain)"

# --- NEXT.md already staged (and nothing else) is fine
r="$(mkrepo)"; cp "$HOUSE_NEXT" "$r/NEXT.md"; git -C "$r" add NEXT.md
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" show --name-only --format= HEAD)" = NEXT.md ] && ok "handoff_commit_with_next_md_staged" || bad "staged NEXT.md: $out"

# --- tracked, modified NEXT.md
r="$(mkrepo)"; cp "$HOUSE_NEXT" "$r/NEXT.md"; git -C "$r" add NEXT.md && git -C "$r" commit -q -m 'docs: notes'
echo '- 2026-01-01: fine' >> "$r/NEXT.md"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" show --name-only --format= HEAD)" = NEXT.md ] && [ -z "$(git -C "$r" status --porcelain)" ] \
  && ok "handoff_commit_modified_next_md" || bad "modified: $out"

# --- tracked, clean NEXT.md: an empty anchor
r="$(mkrepo)"; cp "$HOUSE_NEXT" "$r/NEXT.md"; git -C "$r" add NEXT.md && git -C "$r" commit -q -m 'docs: notes'
h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" rev-list --count "$h1..HEAD")" = 1 ] && [[ "$(git -C "$r" log -1 --format=%s)" == handoff:* ]] \
  && [ -z "$(git -C "$r" show --name-only --format= HEAD)" ] && ok "handoff_commit_empty_anchor_when_next_md_clean" || bad "empty anchor: $out"
git -C "$r" cat-file commit HEAD | sed "1,/^$/d" | cmp -s - "$TMPROOT/exp.msg" && ok "empty_anchor_message_exact" || bad "empty msg: $(git -C "$r" log -1 --format=%B)"

# --- NEXT.md missing or ignored
r="$(mkrepo)"; h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = failed ] && [ "$(head_of "$r")" = "$h1" ] && det "$out" | grep -qF 'NEXT.md does not exist' && ok "handoff_commit_refuses_missing_next_md" || bad "missing: $out"
r="$(mkrepo)"; printf 'NEXT.md\n' > "$r/.gitignore"; git -C "$r" add .gitignore && git -C "$r" commit -q -m ign
cp "$HOUSE_NEXT" "$r/NEXT.md"; h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = failed ] && [ "$(head_of "$r")" = "$h1" ] && det "$out" | grep -qF 'git-ignored' && ok "handoff_commit_refuses_ignored_next_md" || bad "ignored NEXT.md: $out"

# --- a failing pre-commit hook leaves the index as it was
r="$(mkrepo)"; cp "$HOUSE_NEXT" "$r/NEXT.md"
printf '#!/bin/sh\necho blocked by hook >&2\nexit 1\n' > "$r/.git/hooks/pre-commit"; chmod +x "$r/.git/hooks/pre-commit"
idx "$r" > "$TMPROOT/idx.before"; h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
idx "$r" > "$TMPROOT/idx.after"
[ "$(st "$out")" = failed ] && [ "$(head_of "$r")" = "$h1" ] && cmp -s "$TMPROOT/idx.before" "$TMPROOT/idx.after" \
  && det "$out" | grep -qF 'blocked by hook' && ok "hook_failure_untracked_next_md_index_restored" || bad "hook untracked: $out; $(diff "$TMPROOT/idx.before" "$TMPROOT/idx.after")"
r="$(mkrepo)"; cp "$HOUSE_NEXT" "$r/NEXT.md"; git -C "$r" add NEXT.md && git -C "$r" commit -q -m 'docs: notes'
echo more >> "$r/NEXT.md"
printf '#!/bin/sh\nexit 1\n' > "$r/.git/hooks/pre-commit"; chmod +x "$r/.git/hooks/pre-commit"
idx "$r" > "$TMPROOT/idx.before"; h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
idx "$r" > "$TMPROOT/idx.after"
[ "$(st "$out")" = failed ] && [ "$(head_of "$r")" = "$h1" ] && cmp -s "$TMPROOT/idx.before" "$TMPROOT/idx.after" \
  && ok "hook_failure_modified_next_md_index_unchanged" || bad "hook modified: $out; $(diff "$TMPROOT/idx.before" "$TMPROOT/idx.after")"

# --- an unborn branch: no history is "no anchor", not unknown
d="$TMPROOT/ritual fixtures/unborn"; mkdir -p "$d"
git -C "$d" init -q -b main 2>/dev/null || git -C "$d" init -q
git -C "$d" config user.email t@example.com; git -C "$d" config user.name Test; git -C "$d" config commit.gpgsign false; git -C "$d" config core.autocrlf false
out="$(R check handoff "$d")"
[ "$(st "$out")" = absent ] && det "$out" | grep -qF 'no handoff: commit' && ok "unborn_branch_check_is_absent" || bad "unborn check: $out"
cp "$HOUSE_NEXT" "$d/NEXT.md"
out="$(R handoff-commit "$d")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$d" rev-list --count HEAD)" = 1 ] && [ "$(git -C "$d" show --name-only --format= HEAD)" = NEXT.md ] \
  && ok "unborn_branch_handoff_commit_is_the_root_commit" || bad "unborn commit: $out"

# --- a "# " H1 ends the routine section (replace keeps everything after it)
for eol in lf crlf; do
  r="$(mkrepo)"
  printf '# A\n## Session routine\n- mine\n# Appendix\nkeep me\n## Other\nx\n' > "$TMPROOT/h1.in"
  { printf '# A\n'; cat "$HOUSE_ROUTINE"; printf '\n# Appendix\nkeep me\n## Other\nx\n'; } > "$TMPROOT/h1.exp"
  if [ "$eol" = crlf ]; then sed -i 's/$/\r/' "$TMPROOT/h1.in" "$TMPROOT/h1.exp"; fi
  cp "$TMPROOT/h1.in" "$r/CLAUDE.md"
  out="$(R fix handoff "$r" --replace-routine)"
  [ "$(st "$out")" = fixed ] && cmp -s "$r/CLAUDE.md" "$TMPROOT/h1.exp" && ok "replace_routine_stops_at_h1 ($eol)" || bad "h1 $eol: $out; $(od -c "$r/CLAUDE.md" | tail -12)"
done
r="$(mkrepo)"
{ printf '## Session routine\n\n- mine\n\n# Appendix\n\n'; sed -n 3p "$HOUSE_ROUTINE"; } > "$r/CLAUDE.md"
out="$(R check handoff "$r")"
det "$out" | grep -qF 'different session routine (line 1)' && ok "marker_bullet_after_an_h1_is_not_in_the_section" || bad "h1 scan: $out"

# --- the routine heading matches in any case, and is then a DIFFERENT routine (never a second heading)
r="$(mkrepo)"
printf '# Proj\n\n## Session Routine\n\n- Ask how it went.\n' > "$r/CLAUDE.md"; cp "$r/CLAUDE.md" "$TMPROOT/case.before"
out="$(R fix handoff "$r")"
[ "$(st "$out")" = absent ] && det "$out" | grep -qF 'different session routine (line 3)' && cmp -s "$r/CLAUDE.md" "$TMPROOT/case.before" \
  && ok "session_routine_heading_any_case_is_a_different_routine" || bad "case: $out; $(cat "$r/CLAUDE.md")"

# --- handoff-commit under status.showUntrackedFiles=no: an untracked NEXT.md is not "ignored"
r="$(mkrepo)"; git -C "$r" config status.showUntrackedFiles no; cp "$HOUSE_NEXT" "$r/NEXT.md"; h1="$(head_of "$r")"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" rev-list --count "$h1..HEAD")" = 1 ] && [ "$(git -C "$r" show --name-only --format= HEAD)" = NEXT.md ] \
  && ok "untracked_next_md_with_show_untracked_no_is_committed" || bad "showUntracked=no: $out"

# --- NEXT.md partly staged (MM): the worktree version goes in, alone; index and worktree then agree
r="$(mkrepo)"; cp "$HOUSE_NEXT" "$r/NEXT.md"; git -C "$r" add NEXT.md && git -C "$r" commit -q -m 'docs: notes'
echo 'STAGED LINE' >> "$r/NEXT.md"; git -C "$r" add NEXT.md; echo 'UNSTAGED LINE' >> "$r/NEXT.md"
echo other > "$r/other.txt"
[ "$(git -C "$r" status --porcelain -- NEXT.md)" = 'MM NEXT.md' ] || bad "premise: NEXT.md is not MM"
cp "$r/NEXT.md" "$TMPROOT/mm.work"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" show --name-only --format= HEAD)" = NEXT.md ] \
  && git -C "$r" cat-file blob HEAD:NEXT.md | cmp -s - "$TMPROOT/mm.work" && cmp -s "$r/NEXT.md" "$TMPROOT/mm.work" \
  && [ -z "$(git -C "$r" status --porcelain -- NEXT.md)" ] && [ "$(git -C "$r" status --porcelain)" = '?? other.txt' ] \
  && ok "handoff_commit_mm_next_md" || bad "MM: $out; $(git -C "$r" status --porcelain)"

# --- anchor subjects: only a subject starting exactly "handoff:" counts
r="$(mkrepo)"; R fix handoff "$r" >/dev/null
git -C "$r" commit -q --allow-empty -m 'Handoff: x'
git -C "$r" commit -q --allow-empty --cleanup=verbatim -m ' handoff: x'
[ "$(git -C "$r" log -1 --format=%s)" = ' handoff: x' ] || bad "premise: leading space not kept in the subject"
out="$(R check handoff "$r")"
det "$out" | grep -qF 'no handoff: commit' && ok "anchor_subject_variants_capital_and_leading_space_are_not_anchors" || bad "variants: $out"
git -C "$r" commit -q --allow-empty -m 'handoff: x'
out="$(R check handoff "$r")"
[ "$(st "$out")" = present ] && ok "anchor_subject_variants_exact_prefix_is_an_anchor" || bad "exact: $out"

# --- a corrupt HEAD is unknown, never "no anchor"
r="$(mkrepo)"; R fix handoff "$r" >/dev/null
printf 'not a sha\n' > "$r/.git/refs/heads/main"
out="$(R check handoff "$r")"
[ "$(st "$out")" = unknown ] && det "$out" | grep -qF 'could not read the history' && ok "corrupt_head_check_is_unknown" || bad "corrupt check: $out"
out="$(R handoff-commit "$r")"
[ "$(st "$out")" = unknown ] && [ "$(cat "$r/.git/refs/heads/main")" = 'not a sha' ] && ok "corrupt_head_handoff_commit_is_unknown" || bad "corrupt commit: $out"

# --- the marker is written atomically: a failing jq leaves no file and reports failed
JQDIR="$TMPROOT/jq shim"; mkdir -p "$JQDIR"
{ printf '#!/usr/bin/env bash\nREAL_JQ=%q\n' "$(command -v jq)"; cat <<'WRAP'
for a in "$@"; do [ "$a" = -Rs ] && { echo "shim: jq fails" >&2; exit 5; }; done
exec "$REAL_JQ" "$@"
WRAP
} > "$JQDIR/jq"; chmod +x "$JQDIR/jq"
r="$(mkrepo)"
out="$( stub_path "$JQDIR"; bash "$RITUAL" fix handoff "$r" )"
[ "$(st "$out")" = failed ] && [ ! -e "$r/.claude/handoff.json" ] && [ -z "$(ls -A "$r/.claude" 2>/dev/null)" ] \
  && ok "marker_write_failure_leaves_no_file" || bad "atomic: $out; $(ls -A "$r/.claude" 2>/dev/null)"
out="$(R fix handoff "$r")"
det "$out" | grep -qF 'marker created' && [ "$(tr -d '\r' < "$r/.claude/handoff.json" | jq -c .)" = '{}' ] \
  && ok "marker_rerun_after_failure_creates_it" || bad "atomic rerun: $out"

# --- R47: a linked worktree is refused; check still reports the truth
snap() { git -C "$1" status --porcelain --untracked-files=all; (cd "$1" && find . -path ./.git -prune -o -print | sort); git -C "$1" rev-parse HEAD; git -C "$1" ls-files -s; }
r="$(mkrepo)"; wt="$TMPROOT/ritual fixtures/linked wt"
git -C "$r" worktree add -q -b side "$wt" >/dev/null 2>&1 || bad "premise: git worktree add failed"
snap "$r" > "$TMPROOT/main.before"; snap "$wt" > "$TMPROOT/wt.before"
out="$(R fix handoff "$wt" --ask q)"
snap "$r" > "$TMPROOT/main.after"; snap "$wt" > "$TMPROOT/wt.after"
[ "$(st "$out")" = unknown ] && [ "$(det "$out")" = 'linked worktree; run the handoff step from the main checkout' ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] \
  && cmp -s "$TMPROOT/wt.before" "$TMPROOT/wt.after" && cmp -s "$TMPROOT/main.before" "$TMPROOT/main.after" \
  && ok "linked_worktree_fix_is_unknown_and_writes_nothing" || bad "wt fix: $out; $(diff "$TMPROOT/wt.before" "$TMPROOT/wt.after")"
out="$(R check handoff "$wt")"
[ "$(st "$out")" = absent ] && det "$out" | grep -qF 'NEXT.md missing' && ok "linked_worktree_check_reports_the_truth" || bad "wt check: $out"
cp "$HOUSE_NEXT" "$wt/NEXT.md"
snap "$r" > "$TMPROOT/main.before"; snap "$wt" > "$TMPROOT/wt.before"
out="$(R handoff-commit "$wt")"
snap "$r" > "$TMPROOT/main.after"; snap "$wt" > "$TMPROOT/wt.after"
[ "$(st "$out")" = failed ] && [ "$(det "$out")" = 'linked worktree; run the handoff step from the main checkout' ] \
  && cmp -s "$TMPROOT/wt.before" "$TMPROOT/wt.after" && cmp -s "$TMPROOT/main.before" "$TMPROOT/main.after" \
  && ok "linked_worktree_handoff_commit_fails_and_commits_nothing" || bad "wt commit: $out; $(diff "$TMPROOT/wt.before" "$TMPROOT/wt.after")"
out="$(R fix handoff "$r")"
[ "$(st "$out")" = fixed ] && [ -f "$r/NEXT.md" ] && ok "main_checkout_with_a_linked_worktree_is_not_refused" || bad "main with wt: $out"

# --- R49: the guard fails CLOSED. A git whose rev-parse fails (or prints nothing) for one of the
# guard's two flags is "cannot tell": unknown/failed, nothing written, nothing committed, in a linked
# worktree AND in a main checkout. The shim passes everything else through. --git-common-dir is also
# asked for by ritual.sh's own repo check (which would reject first), so that variant arms only after
# the shim has seen --git-dir, which only the guard asks for.
GSHIM="$TMPROOT/guard shim"; mkdir -p "$GSHIM"
{ printf '#!/usr/bin/env bash\nREAL_GIT=%q\nARMED=%q\n' "$(command -v git)" "$TMPROOT/guard.armed"; cat <<'WRAP'
for a in "$@"; do
  [ "$a" = --git-dir ] && : > "$ARMED"
  if [ "$a" = "${GUARD_FLAG:-}" ] && { [ "$a" = --git-dir ] || [ -e "$ARMED" ]; }; then
    case "${GUARD_MODE:-}" in
      fail) echo "shim: rev-parse $a fails" >&2; exit 128 ;;
      empty) exit 0 ;;
    esac
  fi
done
exec "$REAL_GIT" "$@"
WRAP
} > "$GSHIM/git"; chmod +x "$GSHIM/git"
RG() { ( stub_path "$GSHIM"; export GUARD_FLAG="$1" GUARD_MODE="$2"; shift 2; rm -f "$TMPROOT/guard.armed"; bash "$RITUAL" "$@" ); }
gsnap() { snap "$1"; git -C "$1" rev-list --count HEAD; git -C "$1" log -1 --format=%H; }
UNK='could not tell whether this is a linked worktree (git rev-parse failed); nothing written'
for case_ in "--git-dir fail guard_fails_closed_git_dir" "--git-common-dir fail guard_fails_closed_common_dir" "--git-dir empty guard_fails_closed_empty_output"; do
  set -- $case_; flag="$1"; mode="$2"; name="$3"; good=1; why=""
  r="$(mkrepo)"; wt="$TMPROOT/g fixtures/$name wt"; mkdir -p "$TMPROOT/g fixtures"
  git -C "$r" worktree add -q -b "side-$name" "$wt" >/dev/null 2>&1 || { good=0; why="premise: worktree add failed"; }
  for where in "$wt" "$r"; do
    cp "$HOUSE_NEXT" "$where/NEXT.md"
    gsnap "$r" > "$TMPROOT/gm.before"; gsnap "$wt" > "$TMPROOT/gw.before"
    out="$(RG "$flag" "$mode" fix handoff "$where" --ask q)"
    if [ "$(st "$out")" != unknown ] || [ "$(det "$out")" != "$UNK" ] || [ "$(jq -c .wrote <<<"$out")" != '[]' ]; then good=0; why="$why fix@$where: $out;"; fi
    out="$(RG "$flag" "$mode" handoff-commit "$where")"
    if [ "$(st "$out")" != failed ] || [ "$(det "$out")" != "$UNK" ]; then good=0; why="$why commit@$where: $out;"; fi
    gsnap "$r" > "$TMPROOT/gm.after"; gsnap "$wt" > "$TMPROOT/gw.after"
    cmp -s "$TMPROOT/gm.before" "$TMPROOT/gm.after" && cmp -s "$TMPROOT/gw.before" "$TMPROOT/gw.after" || { good=0; why="$why changed after $where;"; }
    rm -f "$where/NEXT.md"
  done
  [ "$good" = 1 ] && ok "$name" || bad "$name: $why"
done

# --- run from a subdirectory: paths resolve at the repo root
r="$(mkrepo)"; mkdir -p "$r/sub dir"
out="$(R fix handoff "$r/sub dir")"
[ -f "$r/NEXT.md" ] && [ -f "$r/.claude/handoff.json" ] && [ -f "$r/CLAUDE.md" ] && [ ! -e "$r/sub dir/NEXT.md" ] \
  && ok "fix_from_subdirectory_writes_at_root" || bad "subdir: $out"

finish
