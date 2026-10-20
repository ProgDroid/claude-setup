#!/usr/bin/env bash
# Tests: ritual.sh's dispatcher. --help, a missing or unknown subcommand, and every subcommand that
# takes a <repo>, given a directory below the work tree's top (one table, so a new subcommand is
# one row). auto, oracle, fix parking-lot and fix handoff have their own subdirectory cases in
# test-e2e.sh and test-handoff-step.sh.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R() { bash "$RITUAL" "$@"; }
norm() { tr -d '\r'; }

echo "== help and misuse =="
for h in --help -h help; do
  out="$(R "$h" 2>"$TMPROOT/err")"; rc=$?
  [ "$rc" = 0 ] && grep -q '^usage: ritual.sh' <<<"$out" && [ ! -s "$TMPROOT/err" ] \
    && ok "help_on_stdout_exit_0 ($h)" || bad "help $h: rc=$rc out=$out err=$(cat "$TMPROOT/err")"
done
# Every arm of the dispatch case (the third `case "$sub"` in ritual.sh, read from the file itself)
# has a usage line, so a new subcommand without one fails here.
help="$(R --help | norm)"
arms="$(awk '/^case "\$sub" in$/ { n++; next } n == 3 && /^  [a-z|-]+\)/ { s = $1; sub(/\).*/, "", s); gsub(/\|/, " ", s); print s }' "$RITUAL")"
n=0; missing=""
for a in $arms; do n=$((n + 1)); grep -qE "^  $a( |\$)" <<<"$help" || missing="$missing $a"; done
[ "$n" -ge 14 ] && [ -z "$missing" ] && ok "help_lists_every_dispatch_arm ($n arms)" || bad "help lacks:$missing (arms read: $n)"
R >"$TMPROOT/out" 2>"$TMPROOT/err"; rc=$?
[ "$rc" = 2 ] && [ ! -s "$TMPROOT/out" ] && grep -q '^usage: ritual.sh' "$TMPROOT/err" \
  && ok "no_subcommand_usage_on_stderr_exit_2" || bad "no subcommand: rc=$rc err=$(cat "$TMPROOT/err")"
R bogus "$TMPROOT" >/dev/null 2>"$TMPROOT/err"; rc=$?
[ "$rc" = 2 ] && grep -q 'unknown subcommand: bogus' "$TMPROOT/err" && ok "unknown_subcommand_exit_2" || bad "bogus: rc=$rc"

echo "== a <repo> below the top means the top =="
# mkfx <name> -> a repo with a package.json and an open docs item at the top, a spaced
# subdirectory, a committed fixture and one dirty file
mkfx() {
  local r; r="$(mkrepo "$1")"
  mkdir -p "$r/sub dir" "$r/docs"
  echo n > "$r/sub dir/keep.txt"
  printf '{"name":"x","scripts":{"test":"node t.js"}}\n' > "$r/package.json"
  printf '# Notes\n\n## Open\n- an open item\n' > "$r/docs/notes.md"
  git -C "$r" add -A; git -C "$r" commit -q -m fixture
  echo dirty >> "$r/README.md"
  printf '%s\n' "$r"
}
r="$(mkfx dispatch)"; top="$(git -C "$r" rev-parse --show-toplevel | norm)"; s="$r/sub dir"
[ "$(git -C "$s" rev-parse --show-prefix | norm)" = 'sub dir/' ] && ok "fixture_subdir_is_below_the_top" || bad "fixture premise"
R preflight "$top" > "$TMPROOT/pf.json"; echo '["README.md","new.txt"]' > "$TMPROOT/wrote.json"

# read-only subcommands: the same stdout and exit code from the subdirectory as from the top
# (spelled as git spells it, which is what the subdirectory resolves to)
same() {   # same <label> <args after the repo...>
  local label="$1" sub_="$2" a b ra rb; shift 2
  a="$(R "$sub_" "$s" "$@" 2>&1 | norm)"; ra=${PIPESTATUS[0]}
  b="$(R "$sub_" "$top" "$@" 2>&1 | norm)"; rb=${PIPESTATUS[0]}
  [ "$ra" = "$rb" ] && [ "$a" = "$b" ] && [ "$rb" = 0 ] && [ -n "$b" ] \
    && ok "subdir_equals_top: $label" || bad "subdir $label: rc $ra vs $rb; sub=$a; top=$b"
}
same record-path record-path
same record-read record-read
same due due
same preflight preflight
same stack stack
same candidates candidates
same commit-plan commit-plan "$TMPROOT/pf.json" "$TMPROOT/wrote.json"
# the stack and candidates rows discriminate only if the top holds what the subdirectory lacks
jq -e '.stacks | length > 0' <<<"$(R stack "$top")" >/dev/null && jq -e '.items | length > 0' <<<"$(R candidates "$top")" >/dev/null \
  && ok "fixture_top_has_a_stack_and_a_candidate" || bad "fixture: $(R stack "$top") $(R candidates "$top")"

# writing subcommands: the effect lands at the top
w="$(mkfx dispatch-write)"
printf '{"steps":{"lessons":{"result":"none"}}}' > "$TMPROOT/results.json"
R record-write "$w/sub dir" "$TMPROOT/results.json" >/dev/null
[ "$(R record-read "$w" | jq -r '.steps.lessons.result' | norm)" = none ] && ok "record_write_from_subdir_lands_in_the_record" || bad "record-write: $(R record-read "$w")"

c="$(mkfx dispatch-commit)"
R preflight "$c" > "$TMPROOT/cpf.json"; echo new > "$c/new.txt"; printf 'ritual: add new.txt\n' > "$TMPROOT/msg.txt"
R commit "$c/sub dir" --preflight "$TMPROOT/cpf.json" --message-file "$TMPROOT/msg.txt" -- new.txt >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(git -C "$c" log -1 --format=%s | norm)" = 'ritual: add new.txt' ] \
  && [ "$(git -C "$c" ls-tree -r --name-only HEAD -- new.txt | norm)" = new.txt ] \
  && ok "commit_from_subdir_takes_paths_from_the_top" || bad "commit from subdir: rc=$rc $(git -C "$c" log --oneline -2)"

h="$(mkfx dispatch-handoff)"; git -C "$h" checkout -q -- README.md; printf '# Next\n' > "$h/NEXT.md"
R handoff-commit "$h/sub dir" >/dev/null 2>&1
[ "$(git -C "$h" log -1 --format=%s | norm)" != fixture ] && [ "$(git -C "$h" show --name-only --format= HEAD | norm)" = NEXT.md ] \
  && ok "handoff_commit_from_subdir_commits_the_top_next_md" || bad "handoff-commit from subdir: $(git -C "$h" log --oneline -2)"

finish
