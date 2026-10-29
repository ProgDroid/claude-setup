#!/usr/bin/env bash
# Tests: fix beads against bd variants (exit codes, markers, dolt remote answers), with a stub bd.
. "$(dirname "${BASH_SOURCE[0]}")/beads-fixture.sh"

# ============================== fix beads: bd variants
r="$(mkrepo "Exit Repo")"; logclear
out="$(STUB_BD_EXIT=255 R fix beads "$r")"
[ "$(st "$out")" = fixed ] && [ "$(st "$(R check beads "$r")")" = present ] && ok "fix_exit_255_is_not_failure" || bad "exit 255: $out"

r="$(mkrepo "Setup Repo")"; logclear
out="$(STUB_NO_SETUP=1 R fix beads "$r")"
[ "$(st "$out")" = fixed ] && grep -qx 'setup claude' "$LOG" && ! grep -q 'do NOT use TodoWrite' "$r/CLAUDE.md" \
  && ok "fix_runs_setup_claude_when_marker_absent" || bad "setup claude path: $out; log=$(cat "$LOG")"

r="$(mkrepo "Stuck Repo")"; logclear
out="$(STUB_REMOTE_STUCK=1 R fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'dolt remote' && ok "fix_fails_when_dolt_remote_survives" || bad "stuck remote: $out"

r="$(mkrepo "Fail Repo")"; logclear
out="$(STUB_INIT_FAIL=1 R fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q '\.beads/\.gitignore' && [ -f "$r/.beads/.gitignore" ] \
  && ! grep -q 'config set' "$LOG" && ok "fix_init_failure_lists_leftovers_removes_nothing" || bad "init fail: $out"

r="$(mkrepo "Agents Repo")"; printf '# My agents\n' > "$r/AGENTS.md"; commit_all "$r" agents; logclear
out="$(R fix beads "$r")"
[ -f "$r/AGENTS.md" ] && head -n 1 "$r/AGENTS.md" | grep -qx '# My agents' && dt "$out" | grep -q 'AGENTS.md' \
  && [ ! -e "$r/.codex" ] && ok "fix_keeps_preexisting_agents_md_and_names_it" || bad "pre-existing AGENTS.md: $out"

r="$(mkrepo "Block Repo")"
printf '%s\n' '# Mine' '<!-- BEGIN BEADS INTEGRATION -->' '- Use `bd` for ALL task tracking — do NOT use TodoWrite' '<!-- END BEADS INTEGRATION -->' > "$r/CLAUDE.md"
commit_all "$r" claude; cp "$r/CLAUDE.md" "$TMPROOT/block.before"; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'check-block' && head -n 4 "$r/CLAUDE.md" | cmp -s - "$TMPROOT/block.before" \
  && ok "fix_never_edits_a_preexisting_block" || bad "pre-existing block: $out"
grep -q '^init ' "$LOG" && ! grep -q 'setup claude' "$LOG" && ok "fix_setup_claude_not_run_when_marker_preexisted" || bad "setup claude ran over a pre-existing marker (or bd never ran): $(cat "$LOG")"

r="$(mkrepo "Codex Repo")"; mkdir -p "$r/.codex" "$r/.agents/skills/beads"
printf 'mine\n' > "$r/.codex/mine.toml"; printf 'my skill\n' > "$r/.agents/skills/beads/MINE.md"; commit_all "$r" codex; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && grep -q '^init ' "$LOG" && [ "$(cat "$r/.codex/mine.toml" 2>/dev/null)" = mine ] \
  && [ "$(cat "$r/.agents/skills/beads/MINE.md" 2>/dev/null)" = 'my skill' ] && [ -d "$r/.codex" ] && [ -d "$r/.agents/skills/beads" ] \
  && ok "fix_keeps_preexisting_codex_and_agents_skill" || bad "pre-existing .codex/.agents: $out; $(ls -A "$r")"

r="$(mkrepo "Remote Unknown")"; logclear
out="$(STUB_REMOTE_LIST= R fix beads "$r")"
[ "$(st "$out")" = fixed ] && dt "$out" | grep -q 'dolt remote state unverified' && ok "fix_dolt_unrecognised_answer_is_reported_unverified" || bad "empty remote list: $out"
r="$(mkrepo "Remote Other")"; logclear
out="$(STUB_REMOTE_LIST='upstream  git+elsewhere' R fix beads "$r")"
[ "$(st "$out")" = fixed ] && dt "$out" | grep -q 'dolt remote state unverified' && dt "$out" | grep -q 'upstream' \
  && ok "fix_dolt_other_answer_is_reported_unverified_and_quoted" || bad "other remote list: $out"

r="$(mkrepo "Interval Repo")"; logclear
out="$(STUB_SET_IGNORE=export.interval R fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'export.interval' && grep -qx 'config set export.interval 1ms' "$LOG" \
  && ok "fix_fails_when_interval_not_written" || bad "interval unset: $out"

# _beads_unban_block, directly: the managed block first, user text AFTER it, and a final line with
# no line ending. Only the two ban lines may change; no byte is added after the last line.
unban_case() {   # <eol> -> 0 when the result is byte-exact
  ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/beads.sh"; e="$1"
    f="$TMPROOT/unban.$RANDOM"
    printf "%s$e" '<!-- BEGIN BEADS INTEGRATION v:1 -->' '- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate' \
      '- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files' '<!-- END BEADS INTEGRATION -->' '' 'my text after' > "$f"
    printf 'no final newline' >> "$f"
    { printf "%s$e" '<!-- BEGIN BEADS INTEGRATION v:1 -->' "$_BEADS_LINE_TODO" "$_BEADS_LINE_MEM" '<!-- END BEADS INTEGRATION -->' '' 'my text after'
      printf 'no final newline'; } > "$f.exp"
    [ "$(_beads_unban_block "$f")" = 2 ] && cmp -s "$f" "$f.exp" )
}
unban_case '\n' && ok "unban_keeps_user_text_after_block_and_no_final_newline" || bad "unban LF: trailing bytes changed"
unban_case '\r\n' && ok "unban_keeps_user_text_after_block_and_no_final_newline_crlf" || bad "unban CRLF: trailing bytes changed"

# end to end: bd puts its block ABOVE the user's CRLF CLAUDE.md; the user's bytes after the END
# marker survive unchanged (the override is appended after them).
r="$(mkrepo "Block Top")"; printf '# Mine\r\n\r\nKeep this.\r\n' > "$r/CLAUDE.md"; commit_all "$r" claude
cp "$r/CLAUDE.md" "$TMPROOT/top.user"; logclear
out="$(STUB_BLOCK_TOP=1 STUB_CRLF=1 R fix beads "$r")"
endm='END BEADS INTEGRATION -->'; off="$(grep -abo "$endm" "$r/CLAUDE.md" | head -n 1 | cut -d: -f1)"
[ "$(st "$out")" = fixed ] && [ -n "$off" ] && [ "$(head -n 1 "$r/CLAUDE.md" | grep -c 'BEGIN BEADS')" = 1 ] \
  && tail -c +"$((off + ${#endm} + 3))" "$r/CLAUDE.md" | head -c "$(wc -c < "$TMPROOT/top.user")" | cmp -s - "$TMPROOT/top.user" \
  && [ "$(bare_lf "$r/CLAUDE.md")" = 0 ] && ! grep -q 'do NOT use TodoWrite' "$r/CLAUDE.md" \
  && ok "fix_user_text_after_block_is_byte_identical_crlf" || bad "block-top CLAUDE.md: $out; $(od -c "$r/CLAUDE.md" | head -n 4)"

r="$(mkrepo "Crlf Claude")"; printf '# Mine\r\n\r\nKeep this.\r\n' > "$r/CLAUDE.md"; commit_all "$r" claude
cp "$r/CLAUDE.md" "$TMPROOT/claude.crlf"; logclear
out="$(STUB_CRLF=1 R fix beads "$r")"
nlf="$(bare_lf "$r/CLAUDE.md")"
printf 'a\r\nb\nc\r\n' > "$TMPROOT/lfctl"; [ "$(bare_lf "$TMPROOT/lfctl")" = 1 ] && ok "bare_lf_counter_sees_one_lf (control)" || bad "bare_lf counter blind"
[ "$(st "$out")" = fixed ] && head -c "$(wc -c < "$TMPROOT/claude.crlf")" "$r/CLAUDE.md" | cmp -s - "$TMPROOT/claude.crlf" \
  && [ "$nlf" = 0 ] && grep -qF 'TodoWrite is a different layer' "$r/CLAUDE.md" \
  && ok "fix_unban_and_override_keep_crlf_and_user_bytes" || bad "crlf CLAUDE.md: $out; bare LF count=$nlf"

r="$(mkrepo "Have Beads")"; mkdir -p "$r/.beads"
printf 'sync.remote: "git+origin"\n' > "$r/.beads/config.yaml"; printf 'mine\n' > "$r/.beads/PRIME.md"
printf '%s\n' 'interactions.jsonl' > "$r/.beads/.gitignore"
commit_all "$r" beads; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && ! grep -q '^init' "$LOG" && grep -qx 'setup claude' "$LOG" && [ "$(cat "$r/.beads/PRIME.md")" = mine ] \
  && [ "$(grep -c 'interactions.jsonl' "$r/.beads/.gitignore")" = 1 ] \
  && ok "fix_existing_beads_skips_init_keeps_prime_appends_once" || bad "existing .beads: $out; log=$(cat "$LOG")"

r="$(mkrepo "Crlf Attr")"; printf '* text=auto\r\n' > "$r/.gitattributes"; commit_all "$r" attrs; logclear
R fix beads "$r" >/dev/null
printf '%s\r\n' '* text=auto' '' \
  '# Beads: the hook shims are POSIX sh, and issues.jsonl is compared byte-for-byte' \
  '# against `bd export` output (LF), so neither may be CRLF-converted on checkout.' \
  '.beads/hooks/* text eol=lf' '.beads/*.sh text eol=lf' '.beads/issues.jsonl -text' > "$TMPROOT/exp.ga"
cmp -s "$r/.gitattributes" "$TMPROOT/exp.ga" && ok "fix_appends_gitattributes_in_file_eol" || bad "gitattributes bytes: $(od -c "$r/.gitattributes" | head)"

r="$(mkrepo)"
[ "$(st "$(NB fix beads "$r")")" = unknown ] && ok "fix_unknown_without_bd" || bad "fix no bd"

# the override section is read from the house file with `|| [ -n "$l" ]` (an unterminated last line is
# kept) and each line loses one CR; it lands in the file's own line ending. A copy of the skill with a
# CRLF, unterminated override stands in for the house file (the real one ends in a newline).
cp -r "$SKILL_DIR" "$TMPROOT/sk-ovr"
printf '## Task tracking vs. execution structure\r\nline two\r\nlast no newline' > "$TMPROOT/sk-ovr/house/claude-md-override.md"
r="$(mkrepo "Ovr Unterminated")"; printf '# Mine\r\n\r\nKeep this.\r\n' > "$r/CLAUDE.md"; commit_all "$r" claude; logclear
out="$( ( stub_path "$STUBDIR"; export STUB_BD_LOG="$LOG" STUB_CRLF=1; bash "$TMPROOT/sk-ovr/ritual.sh" fix beads "$r" ) )"
printf '## Task tracking vs. execution structure\r\nline two\r\nlast no newline\r\n' > "$TMPROOT/ovr.exp"
tail -c "$(wc -c < "$TMPROOT/ovr.exp")" "$r/CLAUDE.md" | cmp -s - "$TMPROOT/ovr.exp" && [ "$(st "$out")" = fixed ] \
  && ok "fix_override_keeps_an_unterminated_last_line_and_strips_one_cr_per_line" || bad "override tail: $out; $(tail -c 80 "$r/CLAUDE.md" | od -c | tail -n 5)"

finish
