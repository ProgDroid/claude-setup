#!/usr/bin/env bash
# Tests for lib/ledger.sh, the fingerprint ledger (<git-common-dir>/ritual-ledger.json), and its
# three write points: commit-plan marks `shown`, commit drops what it committed, record-write settles.
# Run: bash personal/skills/project-start/tests/test-ledger.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R() { bash "$RITUAL" "$@"; }
# L <fn> [args...]: one ledger function, with only common.sh and ledger.sh sourced
L() { ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/ledger.sh"; "$@" ); }
# key <dir> -> the ledger's worktree key for the work tree holding <dir>
key() { L path_norm "$(git -C "$1" rev-parse --show-toplevel | tr -d '\r')"; }
lfile() { printf '%s/ritual-ledger.json' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir | tr -d '\r')"; }
rfile() { printf '%s/ritual.json' "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir | tr -d '\r')"; }
# ent <repo> <path> <worktree-key> -> "<state> <fp>", one line per matching entry (none when absent)
ent() {
  local a b c d
  while IFS=$'\t' read -r a b c d; do
    [ "$a" = "$2" ] && [ "$b" = "$3" ] && printf '%s %s\n' "$d" "$c"
  done < <(L ledger_read "$1" | jq -r '.entries[] | [.path, .worktree, .fp, .state] | @tsv' 2>/dev/null | tr -d '\r')
}
nent() { L ledger_read "$1" | jq '.entries | length' 2>/dev/null | tr -d '\r'; }
raw() { git -C "$1" hash-object --no-filters -- "$2" | tr -d '\r'; }
msgf() { local f; f="$(mktemp -p "$TMPROOT")"; echo "ritual: test commit" > "$f"; printf '%s' "$f"; }
# plan <repo> <path>... : preflight, then commit-plan with <path>... as wrote; prints the plan
plan() {
  local r="$1"; shift
  R preflight "$r" > "$TMPROOT/pf.json"
  if [ $# -gt 0 ]; then printf '%s\n' "$@" | jq -R . | jq -sc . > "$TMPROOT/wr.json"; else echo '[]' > "$TMPROOT/wr.json"; fi
  R commit-plan "$r" "$TMPROOT/pf.json" "$TMPROOT/wr.json"
}
commit() { local r="$1"; shift; R commit "$r" --preflight "$TMPROOT/pf.json" --message-file "$(msgf)" --include-dirty -- "$@"; }
results() { local f; f="$(mktemp -p "$TMPROOT")"; printf '%s' "$1" > "$f"; printf '%s' "$f"; }
settle_with() { R record-write "$1" "$(results "{\"steps\":{\"commit\":{\"result\":\"$2\"}}}")" >/dev/null; }

echo "== ledger_file / ledger_read =="
r="$(mkrepo)"
W="$TMPROOT/ritual fixtures/wt one"
git -C "$r" worktree add -q "$W" -b wone 2>/dev/null
f="$(L ledger_file "$r" | tr -d '\r')"
[ -d "$W" ] && [ -n "$f" ] && [ "$f" = "$(lfile "$r")" ] && [ "$(L ledger_file "$W" | tr -d '\r')" = "$f" ] \
  && ok "ledger_file_in_common_dir" || bad "ledger_file_in_common_dir: '$f' vs '$(lfile "$r")', worktree '$(L ledger_file "$W")'"
out="$(L ledger_read "$r" | tr -d '\r')"; rc=$?
[ "$rc" = 0 ] && [ "$out" = '{"entries":[]}' ] && [ ! -e "$f" ] \
  && ok "ledger_read_absent_is_empty" || bad "ledger_read_absent_is_empty: rc=$rc '$out'"

echo "== ledger_fps =="
r="$(mkrepo)"
printf '* text=auto\n' > "$r/.gitattributes"
printf 'one\r\ntwo\r\n' > "$r/crlf file.txt"
fl="$(git -C "$r" hash-object -- "crlf file.txt" | tr -d '\r')"; nf="$(raw "$r" "crlf file.txt")"
got="$(L ledger_fps "$r" "crlf file.txt" | tr -d '\r')"
[ -n "$nf" ] && [ "$fl" != "$nf" ] && [ "$got" = "crlf file.txt"$'\t'"$nf" ] \
  && ok "fp_raw_bytes" || bad "fp_raw_bytes: got '$got', --no-filters '$nf', filtered '$fl'"
mkdir -p "$r/a dir"
got="$(L ledger_fps "$r" README.md "a dir" "gone.txt" "crlf file.txt" | tr -d '\r')"
# an empty directory: `dir:` and the id of the empty manifest (fix round 1: directories are
# fingerprinted by content, no longer the constant `nonfile`)
want="README.md"$'\t'"$(raw "$r" README.md)"$'\n'"a dir"$'\t'"dir:$(git -C "$r" hash-object --stdin </dev/null | tr -d '\r')"$'\n'"gone.txt"$'\t'"absent"$'\n'"crlf file.txt"$'\t'"$nf"
[ "$got" = "$want" ] && ok "fp_absent_and_nonfile" || bad "fp_absent_and_nonfile: got [$got] want [$want]"

echo "== commit-plan marks shown =="
r="$(mkrepo)"; k="$(key "$r")"
echo edit >> "$r/README.md"                       # dirty at preflight -> ask
R preflight "$r" > "$TMPROOT/pf.json"
echo 'on: push' > "$r/my ci.yml"                  # written by the ritual -> commit
printf '%s\n' '["README.md","my ci.yml"]' > "$TMPROOT/wr.json"
p="$(R commit-plan "$r" "$TMPROOT/pf.json" "$TMPROOT/wr.json")"
[ "$(jq -c . <<<"$p" | tr -d '\r')" = '{"commit":["my ci.yml"],"ask":["README.md"],"notes":{}}' ] \
  && [ "$(ent "$r" "my ci.yml" "$k")" = "shown $(raw "$r" "my ci.yml")" ] \
  && [ "$(ent "$r" README.md "$k")" = "shown $(raw "$r" README.md)" ] && [ "$(nent "$r")" = 2 ] \
  && ok "commit_plan_marks_shown" || bad "commit_plan_marks_shown: plan $p; ledger $(L ledger_read "$r")"

echo 'on: [push, pull_request]' > "$r/my ci.yml"
settle_with "$r" declined
plan "$r" "my ci.yml" >/dev/null
[ "$(ent "$r" "my ci.yml" "$k")" = "shown $(raw "$r" "my ci.yml")" ] && [ "$(nent "$r")" = 2 ] \
  && ok "last_writer_wins" || bad "last_writer_wins: $(L ledger_read "$r")"

echo "== commit drops =="
r="$(mkrepo)"; k="$(key "$r")"
echo a > "$r/a.txt"; echo b > "$r/b.txt"
plan "$r" a.txt b.txt >/dev/null
pre="$(nent "$r")"
c="$(commit "$r" a.txt)"
[ "$pre" = 2 ] && [ "$(jq -r .status <<<"$c" | tr -d '\r')" = fixed ] && [ -z "$(ent "$r" a.txt "$k")" ] \
  && [ "$(ent "$r" b.txt "$k")" = "shown $(raw "$r" b.txt)" ] \
  && ok "commit_drops_committed" || bad "commit_drops_committed: before=$pre commit $c; ledger $(L ledger_read "$r")"

r="$(mkrepo)"; k="$(key "$r")"
plan "$r" README.md >/dev/null                    # listed, but already matches HEAD
pre="$(ent "$r" README.md "$k")"
c="$(commit "$r" README.md)"
[ "$pre" = "shown $(raw "$r" README.md)" ] && [ "$(jq -r .status <<<"$c" | tr -d '\r')" = already ] \
  && [ "$(nent "$r")" = 0 ] && ok "commit_already_drops" || bad "commit_already_drops: before '$pre' commit $c; ledger $(L ledger_read "$r")"

echo "== record-write settles =="
r="$(mkrepo)"; k="$(key "$r")"
echo ci > "$r/ci.yml"
plan "$r" ci.yml >/dev/null
shown="$(ent "$r" ci.yml "$k")"
echo "ci, edited after the plan" > "$r/ci.yml"
settle_with "$r" declined
[ "$shown" != "declined $(raw "$r" ci.yml)" ] && [ "$(ent "$r" ci.yml "$k")" = "declined $(raw "$r" ci.yml)" ] \
  && ok "settle_declines_after_declined_commit" || bad "settle_declines_after_declined_commit: was '$shown'; ledger $(L ledger_read "$r")"

r="$(mkrepo)"; k="$(key "$r")"
echo a > "$r/a.txt"; echo b > "$r/left out.txt"
plan "$r" a.txt "left out.txt" >/dev/null
c="$(commit "$r" a.txt)"
settle_with "$r" done
[ "$(jq -r .status <<<"$c" | tr -d '\r')" = fixed ] && [ -z "$(ent "$r" a.txt "$k")" ] \
  && [ "$(ent "$r" "left out.txt" "$k")" = "declined $(raw "$r" "left out.txt")" ] && [ "$(nent "$r")" = 1 ] \
  && ok "settle_declines_after_done_commit" || bad "settle_declines_after_done_commit: commit $c; ledger $(L ledger_read "$r")"

r="$(mkrepo)"; k="$(key "$r")"
echo ci > "$r/ci.yml"
plan "$r" ci.yml >/dev/null
mkdir -p "$r/.git/hooks"; printf '#!/bin/sh\necho "rejected by hook" >&2\nexit 1\n' > "$r/.git/hooks/pre-commit"; chmod +x "$r/.git/hooks/pre-commit"
c="$(commit "$r" ci.yml)"
settle_with "$r" failed
p2="$(plan "$r")"   # the rerun: ci.yml is untracked, so dirty at its preflight, and comes back in ask
[ "$(jq -r .status <<<"$c" | tr -d '\r')" = failed ] && [ "$(ent "$r" ci.yml "$k")" = "shown $(raw "$r" ci.yml)" ] \
  && [ "$(jq -c . <<<"$p2" | tr -d '\r')" = '{"commit":[],"ask":["ci.yml"],"notes":{}}' ] \
  && ok "failed_commit_reoffers_on_rerun" || bad "failed_commit_reoffers_on_rerun: commit $c; rerun plan $p2; ledger $(L ledger_read "$r")"

r="$(mkrepo)"; k="$(key "$r")"
echo t > "$r/tracked.txt"; git -C "$r" add tracked.txt; git -C "$r" commit -q -m tracked
echo a > "$r/a.txt"; echo b > "$r/b.txt"; echo x >> "$r/README.md"
plan "$r" a.txt b.txt README.md tracked.txt >/dev/null
pre="$(nent "$r")"
git -C "$r" add b.txt; git -C "$r" commit -q -m "the user commits b"   # clean now
git -C "$r" checkout -q -- README.md                                  # reverted: clean now
git -C "$r" rm -q --cached tracked.txt                               # index-only change: not clean
settle_with "$r" declined
[ "$pre" = 4 ] && [ -z "$(ent "$r" b.txt "$k")" ] && [ -z "$(ent "$r" README.md "$k")" ] \
  && [ "$(ent "$r" a.txt "$k")" = "declined $(raw "$r" a.txt)" ] \
  && [ "$(ent "$r" tracked.txt "$k")" = "declined $(raw "$r" tracked.txt)" ] && [ "$(nent "$r")" = 2 ] \
  && ok "settle_drops_clean" || bad "settle_drops_clean: before=$pre; ledger $(L ledger_read "$r")"

r="$(mkrepo)"; k="$(key "$r")"
echo ci > "$r/ci.yml"
plan "$r" ci.yml >/dev/null
before="$(L ledger_read "$r" | tr -d '\r')"; same=1
for v in failed unknown interrupted ""; do
  settle_with "$r" "$v"; [ "$(L ledger_read "$r" | tr -d '\r')" = "$before" ] || same="0 ($v)"
done
R record-write "$r" "$(results '{"steps":{"stack":{"result":"done"}}}')" >/dev/null   # no commit step at all
[ "$(L ledger_read "$r" | tr -d '\r')" = "$before" ] || same="0 (no commit step)"
settle_with "$r" already; after_already="$(ent "$r" ci.yml "$k")"
[ "$same" = 1 ] && [ "$(jq '.entries | length' <<<"$before" | tr -d '\r')" = 1 ] \
  && [ "$after_already" = "declined $(raw "$r" ci.yml)" ] \
  && ok "settle_only_on_declined_done_already" || bad "settle_only_on_declined_done_already: same=$same, after already '$after_already', before $before"

r="$(mkrepo)"
R record-write "$r" "$(results '{"steps":{"commit":{"result":"declined"}}}')" >/dev/null
[ -f "$(rfile "$r")" ] && [ ! -e "$(lfile "$r")" ] && ok "settle_without_ledger_creates_none" || bad "settle_without_ledger_creates_none"

echo "== ledger_drop =="
r="$(mkrepo)"; k="$(key "$r")"
echo a > "$r/a.txt"; echo b > "$r/b c.txt"; echo d > "$r/d.txt"
plan "$r" a.txt "b c.txt" d.txt >/dev/null
L ledger_drop "$r" "b c.txt" d.txt never-listed.txt; rc=$?
[ "$rc" = 0 ] && [ "$(nent "$r")" = 1 ] && [ "$(ent "$r" a.txt "$k")" = "shown $(raw "$r" a.txt)" ] \
  && ok "drop_named_paths_only" || bad "drop_named_paths_only: rc=$rc; ledger $(L ledger_read "$r")"

echo "== worktrees =="
r="$(mkrepo)"; k="$(key "$r")"
W="$TMPROOT/ritual fixtures/wt two"; git -C "$r" worktree add -q "$W" -b wtwo 2>/dev/null; kw="$(key "$W")"
echo m > "$r/main only.txt"; echo s > "$r/shared.yml"
plan "$r" "main only.txt" shared.yml >/dev/null
echo w > "$W/shared.yml"; echo x > "$W/w only.txt"
plan "$W" shared.yml "w only.txt" >/dev/null
both="$(nent "$r")"
settle_with "$W" declined
L ledger_drop "$W" "main only.txt"
[ "$k" != "$kw" ] && [ "$both" = 4 ] && [ "$(ent "$r" "main only.txt" "$k")" = "shown $(raw "$r" "main only.txt")" ] \
  && [ "$(ent "$r" shared.yml "$k")" = "shown $(raw "$r" shared.yml)" ] \
  && [ "$(ent "$r" shared.yml "$kw")" = "declined $(raw "$W" shared.yml)" ] \
  && [ "$(ent "$r" "w only.txt" "$kw")" = "declined $(raw "$W" "w only.txt")" ] && [ "$(nent "$r")" = 4 ] \
  && ok "worktree_scoped" || bad "worktree_scoped: both=$both; ledger $(L ledger_read "$r")"

r="$(mkrepo)"; k="$(key "$r")"
W="$TMPROOT/ritual fixtures/wt three"; git -C "$r" worktree add -q "$W" -b wthree 2>/dev/null; kw="$(key "$W")"
echo x > "$W/x.txt"; plan "$W" x.txt >/dev/null
pre="$(ent "$r" x.txt "$kw")"
git -C "$r" worktree remove --force "$W"
echo y > "$r/y.txt"; plan "$r" y.txt >/dev/null
[ "$pre" = "shown $(git -C "$r" hash-object --no-filters --stdin <<<x | tr -d '\r')" ] && [ ! -e "$W" ] \
  && [ "$(nent "$r")" = 1 ] && [ -n "$(ent "$r" y.txt "$k")" ] \
  && ok "dead_worktree_pruned" || bad "dead_worktree_pruned: before '$pre'; ledger $(L ledger_read "$r")"

echo "== the ledger is not the record =="
r="$(mkrepo)"
echo ci > "$r/ci.yml"
plan "$r" ci.yml >/dev/null
n0="$(nent "$r")"; [ -e "$(rfile "$r")" ] && n0="record exists after commit-plan"
c="$(commit "$r" ci.yml)"
[ -f "$(lfile "$r")" ] && [ "$n0" = 1 ] && [ "$(jq -r .status <<<"$c" | tr -d '\r')" = fixed ] && [ ! -e "$(rfile "$r")" ] \
  && ok "ledger_never_creates_ritual_json" || bad "ledger_never_creates_ritual_json: n0=$n0 ledger $(ls -la "$(lfile "$r")" 2>&1); record $(ls "$(rfile "$r")" 2>&1)"

r="$(mkrepo)"
R record-write "$r" "$(results '{"steps":{"stack":{"result":"done"},"ci":{"result":"unknown"}}}')" >/dev/null
b0="$(sha256sum < "$(rfile "$r")")"
echo a > "$r/a.txt"; echo b > "$r/b.txt"
plan "$r" a.txt b.txt >/dev/null; commit "$r" a.txt >/dev/null
b1="$(sha256sum < "$(rfile "$r")")"
rec="$(R record-write "$r" "$(results '{"steps":{"commit":{"result":"done"}}}')" | tr -d '\r')"
[ "$b0" = "$b1" ] && [ "$(jq -c 'keys' <<<"$rec")" = '["completed_at","open_steps","ritual_version","steps"]' ] \
  && [ "$(jq -c '.steps | keys' <<<"$rec")" = '["ci","commit","stack"]' ] && [ "$(jq -c .open_steps <<<"$rec")" = '["ci"]' ] \
  && [ "$(jq -c . "$(rfile "$r")" | tr -d '\r')" = "$rec" ] \
  && ok "record_json_unchanged_by_ledger" || bad "record_json_unchanged_by_ledger: b0=$b0 b1=$b1 rec $rec"

# one_line <file>: exactly one stderr line, and it is the ledger's
one_line() { [ "$(grep -c '' "$1")" = 1 ] && grep -q '^ritual: ledger' "$1"; }

echo "== a ledger failure never changes the caller's result =="
r="$(mkrepo)"
mkdir -p "$(lfile "$r")"                           # a directory where the file goes: every write fails
R preflight "$r" > "$TMPROOT/pf.json"; echo '["a.txt"]' > "$TMPROOT/wr.json"
echo a > "$r/a.txt"
p="$(R commit-plan "$r" "$TMPROOT/pf.json" "$TMPROOT/wr.json" 2>"$TMPROOT/err1")"; rc1=$?
c="$(commit "$r" a.txt 2>"$TMPROOT/err2")"; rc2=$?
rec="$(R record-write "$r" "$(results '{"steps":{"commit":{"result":"done"}}}')" 2>"$TMPROOT/err3")"; rc3=$?
[ "$rc1" = 0 ] && [ "$(jq -c . <<<"$p" | tr -d '\r')" = '{"commit":["a.txt"],"ask":[],"notes":{}}' ] && one_line "$TMPROOT/err1" \
  && [ "$rc2" = 0 ] && [ "$(jq -r .status <<<"$c" | tr -d '\r')" = fixed ] && one_line "$TMPROOT/err2" \
  && [ "$rc3" = 0 ] && [ "$(jq -r .steps.commit.result <<<"$rec" | tr -d '\r')" = done ] && one_line "$TMPROOT/err3" \
  && ok "ledger_failure_keeps_caller_result" \
  || bad "ledger_failure_keeps_caller_result: rc=$rc1/$rc2/$rc3 plan $p commit $c; err1 [$(cat "$TMPROOT/err1")] err2 [$(cat "$TMPROOT/err2")] err3 [$(cat "$TMPROOT/err3")]"

echo "== a corrupt ledger is moved aside; an unreadable one is left alone =="
r="$(mkrepo)"; k="$(key "$r")"
printf 'not json{\r\n' > "$TMPROOT/bad.bytes"; cp "$TMPROOT/bad.bytes" "$(lfile "$r")"
echo "an older copy" > "$(lfile "$r").corrupt"
L ledger_read "$r" >/dev/null 2>&1; rrc=$?
echo a > "$r/a.txt"
plan "$r" a.txt >/dev/null 2>"$TMPROOT/err4"
[ "$rrc" != 0 ] && cmp -s "$TMPROOT/bad.bytes" "$(lfile "$r").corrupt" \
  && [ "$(ent "$r" a.txt "$k")" = "shown $(raw "$r" a.txt)" ] && [ "$(nent "$r")" = 1 ] && one_line "$TMPROOT/err4" \
  && ok "corrupt_ledger_moved_aside" \
  || bad "corrupt_ledger_moved_aside: read rc=$rrc; ledger $(cat "$(lfile "$r")"); corrupt $(od -c "$(lfile "$r").corrupt" | head -2); err [$(cat "$TMPROOT/err4")]"

# An open failure is injected: _ledger_load is the one function that opens the file, and it reports
# "could not open" as exit 1. A real one is also tried below where chmod can deny reads.
r="$(mkrepo)"; k="$(key "$r")"
echo a > "$r/a.txt"; echo b > "$r/b.txt"
plan "$r" a.txt >/dev/null
cp "$(lfile "$r")" "$TMPROOT/good.bytes"
inj() { ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/ledger.sh"; _ledger_load() { return 1; }; "$@" ); }
inj ledger_mark_shown "$r" b.txt 2>"$TMPROOT/err5"; m=$?
inj ledger_drop "$r" a.txt 2>"$TMPROOT/err6"; d=$?
inj ledger_settle "$r" declined 2>"$TMPROOT/err7"; s=$?
[ "$m$d$s" = 111 ] && cmp -s "$TMPROOT/good.bytes" "$(lfile "$r")" && [ ! -e "$(lfile "$r").corrupt" ] \
  && one_line "$TMPROOT/err5" && one_line "$TMPROOT/err6" && one_line "$TMPROOT/err7" \
  && ok "unreadable_ledger_left_alone_injected" \
  || bad "unreadable_ledger_left_alone_injected: rc=$m$d$s; ledger $(cat "$(lfile "$r")"); err [$(cat "$TMPROOT/err5" "$TMPROOT/err6" "$TMPROOT/err7")]"
chmod 000 "$(lfile "$r")"
if cat "$(lfile "$r")" >/dev/null 2>&1; then
  echo "  NOTE: unreadable_ledger_left_alone_chmod not run: chmod 000 does not deny reads here (covered by the injected case)"
else
  L ledger_mark_shown "$r" b.txt 2>"$TMPROOT/err8"; m=$?
  chmod 644 "$(lfile "$r")"
  [ "$m" = 1 ] && cmp -s "$TMPROOT/good.bytes" "$(lfile "$r")" && [ ! -e "$(lfile "$r").corrupt" ] && one_line "$TMPROOT/err8" \
    && ok "unreadable_ledger_left_alone_chmod" || bad "unreadable_ledger_left_alone_chmod: rc=$m; err [$(cat "$TMPROOT/err8")]"
fi
chmod 644 "$(lfile "$r")" 2>/dev/null

echo "== symlinks, a subdirectory as <repo>, and paths no ledger line can hold =="
r="$(mkrepo)"
echo t > "$r/target.txt"
MSYS=winsymlinks:nativestrict ln -s target.txt "$r/link.txt" 2>/dev/null
MSYS=winsymlinks:nativestrict ln -s missing.txt "$r/dangling.txt" 2>/dev/null
if [ -L "$r/link.txt" ] && [ -L "$r/dangling.txt" ]; then
  got="$(L ledger_fps "$r" link.txt dangling.txt target.txt | tr -d '\r')"
  [ "$got" = "link.txt"$'\t'"nonfile"$'\n'"dangling.txt"$'\t'"nonfile"$'\n'"target.txt"$'\t'"$(raw "$r" target.txt)" ] \
    && ok "fp_symlink_is_nonfile" || bad "fp_symlink_is_nonfile: [$got]"
else
  echo "  NOTE: fp_symlink_is_nonfile not run: this filesystem made no symlink"
fi

r="$(mkrepo)"; k="$(key "$r")"
mkdir -p "$r/sub dir"
R preflight "$r/sub dir" > "$TMPROOT/pf.json"
echo x > "$r/sub dir/x.txt"; echo '["sub dir/x.txt"]' > "$TMPROOT/wr.json"
R commit-plan "$r/sub dir" "$TMPROOT/pf.json" "$TMPROOT/wr.json" >/dev/null
st1="$(ent "$r" "sub dir/x.txt" "$k")"
R record-write "$r/sub dir" "$(results '{"steps":{"commit":{"result":"declined"}}}')" >/dev/null
st2="$(ent "$r" "sub dir/x.txt" "$k")"
echo y > "$r/sub dir/y.txt"
L ledger_mark_shown "$r/sub dir" "sub dir/y.txt"; st3="$(ent "$r" "sub dir/y.txt" "$k")"
L ledger_settle "$r/sub dir" done; st4="$(ent "$r" "sub dir/y.txt" "$k")"
[ "$st1" = "shown $(raw "$r" "sub dir/x.txt")" ] && [ "$st2" = "declined $(raw "$r" "sub dir/x.txt")" ] \
  && [ "$st3" = "shown $(raw "$r" "sub dir/y.txt")" ] && [ "$st4" = "declined $(raw "$r" "sub dir/y.txt")" ] && [ "$(nent "$r")" = 2 ] \
  && ok "subdir_repo_keyed_by_top" || bad "subdir_repo_keyed_by_top: [$st1] [$st2] [$st3] [$st4]; ledger $(L ledger_read "$r")"

r="$(mkrepo)"; k="$(key "$r")"
nl="$(printf 'new\nline.txt')"
R preflight "$r" > "$TMPROOT/pf.json"   # before the file exists: Git Bash shows git a newline as U+F00A
if ! { echo n > "$r/$nl"; } 2>/dev/null; then
  echo "  NOTE: newline_path_refused_at_plan not run: this filesystem refuses a newline in a file name"
else
  echo o > "$r/ok.txt"
  printf '%s' "$nl" | jq -Rsc '[., "ok.txt"]' > "$TMPROOT/wr.json"
  p="$(R commit-plan "$r" "$TMPROOT/pf.json" "$TMPROOT/wr.json" 2>"$TMPROOT/err9")"; rc=$?
  want="$(printf '%s' "$nl" | jq -Rsc '{commit: [., "ok.txt"], ask: [], notes: {}}' | tr -d '\r')"
  [ "$rc" = 0 ] && [ "$(jq -c . <<<"$p" | tr -d '\r')" = "$want" ] && one_line "$TMPROOT/err9" \
    && [ "$(ent "$r" ok.txt "$k")" = "shown $(raw "$r" ok.txt)" ] && [ "$(nent "$r")" = 1 ] \
    && ok "newline_path_refused_at_plan" || bad "newline_path_refused_at_plan: rc=$rc plan $p want $want; err [$(cat "$TMPROOT/err9")]; ledger $(L ledger_read "$r")"
fi

# a newline entry already in the ledger (a hand edit): record-write still prints its record and
# exits 0, with one stderr line; the entry is left as it was, the others are settled
r="$(mkrepo)"; k="$(key "$r")"
echo o > "$r/ok.txt"
printf '%s' "$k" | jq -Rc '{entries: [{path: "gone\nentry.txt", worktree: ., fp: "x", state: "shown"},
  {path: "ok.txt", worktree: ., fp: "y", state: "shown"}]}' | tr -d '\r' > "$(lfile "$r")"
rec="$(R record-write "$r" "$(results '{"steps":{"commit":{"result":"declined"}}}')" 2>"$TMPROOT/err10")"; rc=$?
[ "$rc" = 0 ] && [ "$(jq -r .steps.commit.result <<<"$rec" | tr -d '\r')" = declined ] && one_line "$TMPROOT/err10" \
  && [ "$(ent "$r" ok.txt "$k")" = "declined $(raw "$r" ok.txt)" ] \
  && [ "$(L ledger_read "$r" | jq -c '.entries[] | select(.path == "gone\nentry.txt") | [.fp, .state]' | tr -d '\r')" = '["x","shown"]' ] \
  && ok "newline_entry_refused_at_settle" || bad "newline_entry_refused_at_settle: rc=$rc rec $rec; err [$(cat "$TMPROOT/err10")]; ledger $(L ledger_read "$r")"

# ============================== the rerun rule (Task 3)
NOTE='also holds edits the ritual did not make'
V() { L ledger_verdicts "$@" | tr -d '\r'; }            # ledger_verdicts' lines, CR-free
tv() { printf '%s\t%s' "$1" "$2"; }                     # one expected verdict line
EA() { L emit_already "$@" | tr -d '\r'; }               # emit_already, with the ledger sourced
EMPTY='{"commit":[],"ask":[],"notes":{}}'
pc() { jq -c . <<<"$1" | tr -d '\r'; }

echo "== ledger_verdicts: every row of the table =="
r="$(mkrepo)"
echo ci > "$r/ci.yml"; plan "$r" ci.yml >/dev/null
v="$(V "$r" ci.yml)"; e="$(EA ci "$r" "nothing to add" ci.yml)"
[ "$v" = "$(tv ci.yml offer)" ] && [ "$(jq -c .wrote <<<"$e")" = '["ci.yml"]' ] \
  && [ "$(jq -r .detail <<<"$e")" = "nothing to add; not yet committed: ci.yml" ] \
  && ok "verdict_shown_unchanged_offer" || bad "verdict_shown_unchanged_offer: [$v] $e"
echo "my own line" >> "$r/ci.yml"
v="$(V "$r" ci.yml)"; e="$(EA ci "$r" "nothing to add" ci.yml)"
[ "$v" = "$(tv ci.yml offer-note)" ] && [ "$(jq -c .wrote <<<"$e")" = '["ci.yml"]' ] \
  && [ "$(jq -r .detail <<<"$e")" = "nothing to add; not yet committed: ci.yml ($NOTE)" ] \
  && ok "verdict_shown_changed_note" || bad "verdict_shown_changed_note: [$v] $e"

r="$(mkrepo)"
echo ci > "$r/ci.yml"; plan "$r" ci.yml >/dev/null; settle_with "$r" declined
v="$(V "$r" ci.yml)"; e="$(EA ci "$r" "nothing to add" ci.yml)"
[ "$v" = "$(tv ci.yml silent)" ] && [ "$(jq -c .wrote <<<"$e")" = '[]' ] && [ "$(jq -r .detail <<<"$e")" = "nothing to add" ] \
  && ok "verdict_declined_unchanged_silent" || bad "verdict_declined_unchanged_silent: [$v] $e; ledger $(L ledger_read "$r")"
echo "my own line" >> "$r/ci.yml"
v="$(V "$r" ci.yml)"; e="$(EA ci "$r" "nothing to add" ci.yml)"
[ "$v" = "$(tv ci.yml offer-note)" ] && [ "$(jq -c .wrote <<<"$e")" = '["ci.yml"]' ] \
  && [ "$(jq -r .detail <<<"$e")" = "nothing to add; not yet committed: ci.yml ($NOTE)" ] \
  && ok "verdict_declined_changed_note" || bad "verdict_declined_changed_note: [$v] $e"

# no entry: a tracked file's change is the user's own edit (N2); an untracked file is offered.
# No ledger file at all here (a pre-0.16 repo), and asking creates none.
r="$(mkrepo)"
echo "my own edit" >> "$r/README.md"; echo new > "$r/new file.txt"
v="$(V "$r" README.md "new file.txt")"; e="$(EA x "$r" "nothing to add" README.md "new file.txt")"
[ "$v" = "$(tv README.md silent)"$'\n'"$(tv "new file.txt" offer)" ] && [ "$(jq -c .wrote <<<"$e")" = '["new file.txt"]' ] \
  && [ ! -e "$(lfile "$r")" ] \
  && ok "verdict_none_tracked_silent" || bad "verdict_none_tracked_silent: [$v] $e"

r="$(mkrepo)"
echo a > "$r/a.txt"; plan "$r" a.txt >/dev/null
git -C "$r" add a.txt; git -C "$r" commit -q -m "the user commits a"
v="$(V "$r" a.txt README.md "never there.txt")"
[ -n "$(ent "$r" a.txt "$(key "$r")")" ] \
  && [ "$v" = "$(tv a.txt clean)"$'\n'"$(tv README.md clean)"$'\n'"$(tv "never there.txt" clean)" ] \
  && ok "verdict_clean" || bad "verdict_clean: [$v]"

echo "== ledger_verdicts: an unreadable ledger, and paths it cannot carry =="
# R5: a ledger that cannot be opened or parsed: every changed path is offered (the pre-0.16
# behaviour), with one stderr line; the callers keep their result and status; reading never moves it
r="$(mkrepo)"
echo "my own edit" >> "$r/README.md"; echo u > "$r/u.txt"
printf 'not json{' > "$TMPROOT/bad5.bytes"; cp "$TMPROOT/bad5.bytes" "$(lfile "$r")"
v1="$(L ledger_verdicts "$r" README.md u.txt 2>"$TMPROOT/e51" | tr -d '\r')"; r1=$?
e1="$(L emit_already x "$r" "nothing to add" README.md u.txt 2>"$TMPROOT/e52" | tr -d '\r')"; r2=$?
R preflight "$r" > "$TMPROOT/pf.json"; echo '[]' > "$TMPROOT/wr.json"
p1="$(R commit-plan "$r" "$TMPROOT/pf.json" "$TMPROOT/wr.json" 2>"$TMPROOT/e53")"; r3=$?
cmp -s "$TMPROOT/bad5.bytes" "$(lfile "$r")"; kept=$?
rm -f "$(lfile "$r")"; mkdir "$(lfile "$r")"                       # a directory: cannot be opened
v2="$(L ledger_verdicts "$r" README.md u.txt 2>"$TMPROOT/e54" | tr -d '\r')"; r4=$?
e2="$(L emit_already x "$r" "nothing to add" README.md u.txt 2>"$TMPROOT/e55" | tr -d '\r')"; r5=$?
echo '["u.txt"]' > "$TMPROOT/wr.json"
p2="$(R commit-plan "$r" "$TMPROOT/pf.json" "$TMPROOT/wr.json" 2>"$TMPROOT/e56")"; r6=$?
want="$(tv README.md offer)"$'\n'"$(tv u.txt offer)"
[ "$r1$r2$r3$r4$r5$r6" = 000000 ] && [ "$kept" = 0 ] && [ "$v1" = "$want" ] && [ "$v2" = "$want" ] \
  && [ "$(jq -c '[.status, .wrote]' <<<"$e1")" = '["already",["README.md","u.txt"]]' ] && [ "$e2" = "$e1" ] \
  && [ "$(pc "$p1")" = "$EMPTY" ] && [ "$(pc "$p2")" = '{"commit":[],"ask":["u.txt"],"notes":{}}' ] \
  && one_line "$TMPROOT/e51" && one_line "$TMPROOT/e52" && one_line "$TMPROOT/e53" \
  && one_line "$TMPROOT/e54" && one_line "$TMPROOT/e55" && one_line "$TMPROOT/e56" \
  && ok "verdicts_unreadable_ledger_offers_every_changed_path" \
  || bad "verdicts_unreadable_ledger_offers_every_changed_path: rc=$r1$r2$r3$r4$r5$r6 kept=$kept [$v1] [$v2] $e1 / $e2 / $p1 / $p2; err [$(cat "$TMPROOT"/e5?)]"

# R6: a path the ledger cannot carry never reaches ledger_fps (which would refuse the whole batch)
# and gets no line; a caller reads a missing line as `offer`. A hand-edited entry holding one is
# never read back.
# ok.txt is declined and unchanged, so its right verdict is `silent`, which no fallback gives: an
# unfit argument must not turn the whole call into "offer everything"
r="$(mkrepo)"; k="$(key "$r")"
echo o > "$r/ok.txt"; plan "$r" ok.txt >/dev/null; settle_with "$r" declined
v="$(L ledger_verdicts "$r" ok.txt "$(printf 'bad\nname')" "" "$(printf 'x\037y')" | tr -d '\r')"; rc=$?
echo "my own edit" >> "$r/README.md"
e="$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/ledger.sh"; ledger_verdicts() { :; }; emit_already x "$r" d README.md ok.txt )"
printf '%s' "$k" | jq -Rc '{entries: [{path: "gone\nentry.txt", worktree: ., fp: "x", state: "shown"},
  {path: "ok.txt", worktree: ., fp: "y", state: "declined"}]}' | tr -d '\r' > "$(lfile "$r")"
p="$(plan "$r")"
[ "$rc" = 0 ] && [ "$v" = "$(tv ok.txt silent)" ] && [ "$(jq -c .wrote <<<"$e" | tr -d '\r')" = '["README.md","ok.txt"]' ] \
  && [ "$(pc "$p")" = '{"commit":[],"ask":["ok.txt"],"notes":{"ok.txt":"'"$NOTE"'"}}' ] \
  && ok "verdicts_unfit_path_gets_no_line" || bad "verdicts_unfit_path_gets_no_line: rc=$rc [$v] $e; plan $p"

echo "== reruns =="
# N2's real sequence: a normal accepted run, then the user edits CLAUDE.md, then a rerun
r="$(mkrepo)"
f="$(R fix parking-lot "$r")"; mapfile -t P < <(jq -r '.wrote[]' <<<"$f" | tr -d '\r')
plan "$r" "${P[@]}" >/dev/null; c="$(commit "$r" "${P[@]}")"; settle_with "$r" done
echo "- my own working note" >> "$r/CLAUDE.md"
o="$(R fix parking-lot "$r")"; p="$(plan "$r")"
[ "$(jq -c '[.status, (.wrote | sort)]' <<<"$f" | tr -d '\r')" = '["fixed",["CLAUDE.md","docs/parking-lot.md"]]' ] \
  && [ "$(jq -r .status <<<"$c" | tr -d '\r')" = fixed ] && [ -n "$(git -C "$r" status --porcelain -- CLAUDE.md)" ] \
  && [ "$(jq -c '[.status, .wrote, .detail]' <<<"$o" | tr -d '\r')" = '["already",[],"nothing to add"]' ] && [ "$(pc "$p")" = "$EMPTY" ] \
  && ok "n2_commit_edit_rerun_silent" || bad "n2_commit_edit_rerun_silent: fix $f; commit $c; rerun $o; plan $p"

# --skip-tracked outranks the ledger: issues.jsonl shown and declined, then committed by bd's export
# and changed by `bd create`, is the user's data
r="$(mkrepo)"; k="$(key "$r")"
mkdir -p "$r/.beads"; echo '{"id":"b-1"}' > "$r/.beads/issues.jsonl"
plan "$r" .beads/issues.jsonl >/dev/null; settle_with "$r" declined
git -C "$r" add .beads/issues.jsonl; git -C "$r" commit -q -m "bd export"
echo '{"id":"b-2"}' >> "$r/.beads/issues.jsonl"
v="$(V "$r" .beads/issues.jsonl)"
e="$(EA --skip-tracked .beads/issues.jsonl beads "$r" "house beads setup already holds" .beads AGENTS.md)"
p="$(plan "$r")"
[ "$(ent "$r" .beads/issues.jsonl "$k" | cut -d' ' -f1)" = declined ] && [ -n "$(git -C "$r" status --porcelain -- .beads/issues.jsonl)" ] \
  && [ "$v" = "$(tv .beads/issues.jsonl silent)" ] && [ "$(jq -c '[.wrote, .detail]' <<<"$e")" = '[[],"house beads setup already holds"]' ] \
  && [ "$(pc "$p")" = "$EMPTY" ] \
  && ok "skip_tracked_beats_declined_entry" || bad "skip_tracked_beats_declined_entry: [$v] $e; plan $p; ledger $(L ledger_read "$r")"

# I1: a run killed after commit-plan and before record-write: its model files (an untracked CI
# draft, an edit to a tracked file) come back in the next plan's ask
r="$(mkrepo)"
echo 'on: push' > "$r/ci draft.yml"; echo "a line the ritual added" >> "$r/README.md"
plan "$r" "ci draft.yml" README.md >/dev/null
p="$(plan "$r")"
[ "$(jq -c '[.commit, (.ask | sort), .notes]' <<<"$p" | tr -d '\r')" = '[[],["README.md","ci draft.yml"],{}]' ] \
  && ok "interrupted_run_offers_again" || bad "interrupted_run_offers_again: plan $p; ledger $(L ledger_read "$r")"

r="$(mkrepo)"
echo 'on: push' > "$r/ci.yml"; plan "$r" ci.yml >/dev/null; settle_with "$r" declined
p1="$(plan "$r")"
echo '# my own edit' >> "$r/ci.yml"
p2="$(plan "$r")"
[ "$(pc "$p1")" = "$EMPTY" ] && [ "$(pc "$p2")" = '{"commit":[],"ask":["ci.yml"],"notes":{"ci.yml":"'"$NOTE"'"}}' ] \
  && ok "declined_ci_draft_silent_then_offered" || bad "declined_ci_draft_silent_then_offered: $p1 / $p2"

# a CLAUDE.md the model drafted (holding the house rule) in a run that died in step 5: untracked,
# no entry, and offered
r="$(mkrepo)"
R fix parking-lot "$r" >/dev/null
git -C "$r" add docs/parking-lot.md; git -C "$r" commit -q -m lot
{ printf '# My project\n\n'; cat "$r/CLAUDE.md"; } > "$TMPROOT/drafted.md"; mv "$TMPROOT/drafted.md" "$r/CLAUDE.md"
echo o > "$r/other.txt"; plan "$r" other.txt >/dev/null          # a ledger exists, with no entry for CLAUDE.md
o="$(R fix parking-lot "$r")"
[ "$(jq -c '[.status, .wrote, .detail]' <<<"$o" | tr -d '\r')" = '["already",["CLAUDE.md"],"nothing to add; not yet committed: CLAUDE.md"]' ] \
  && ok "untracked_model_file_no_entry_offered" || bad "untracked_model_file_no_entry_offered: $o"

# the fingerprint is the raw bytes: a .gitattributes added after a decline does not make a CRLF
# file look changed
r="$(mkrepo)"
printf 'one\r\ntwo\r\n' > "$r/win.txt"; git -C "$r" add win.txt; git -C "$r" commit -q -m crlf
printf 'three\r\n' >> "$r/win.txt"; plan "$r" win.txt >/dev/null; settle_with "$r" declined
fl0="$(git -C "$r" hash-object -- win.txt | tr -d '\r')"
printf '* text=auto\n' > "$r/.gitattributes"
fl1="$(git -C "$r" hash-object -- win.txt | tr -d '\r')"
v="$(V "$r" win.txt)"; p="$(plan "$r")"
[ "$fl0" != "$fl1" ] && [ "$v" = "$(tv win.txt silent)" ] && [ "$(pc "$p")" = "$EMPTY" ] \
  && ok "attributes_change_does_not_reoffer" || bad "attributes_change_does_not_reoffer: filtered $fl0 -> $fl1; [$v]; plan $p"

# the beads path set: an untracked bd-generated file with no entry; a tracked AGENTS.md the ritual
# deleted with rm (fingerprint `absent`); a `git rm --cached` path, dropped once the user commits it
r="$(mkrepo)"; k="$(key "$r")"
mkdir -p "$r/.beads"; echo a > "$r/AGENTS.md"; : > "$r/.beads/interactions.jsonl"
git -C "$r" add AGENTS.md .beads/interactions.jsonl; git -C "$r" commit -q -m "bd init"
rm "$r/AGENTS.md"; printf 'interactions.jsonl\n' > "$r/.beads/.gitignore"; git -C "$r" rm -q --cached .beads/interactions.jsonl
plan "$r" AGENTS.md .beads/interactions.jsonl .beads/.gitignore >/dev/null
echo 'x: y' > "$r/.beads/config.yaml"
v1="$(V "$r" .beads/config.yaml AGENTS.md .beads/interactions.jsonl)"
e="$(EA beads "$r" "house beads setup already holds" .beads AGENTS.md)"
a1="$(ent "$r" AGENTS.md "$k")"
git -C "$r" commit -q -m "the user commits the untracking"
v2="$(V "$r" .beads/interactions.jsonl)"
settle_with "$r" declined
[ "$v1" = "$(tv .beads/config.yaml offer)"$'\n'"$(tv AGENTS.md offer)"$'\n'"$(tv .beads/interactions.jsonl offer)" ] \
  && [ "$a1" = "shown absent" ] \
  && [ "$(jq -c '.wrote | sort' <<<"$e")" = '[".beads/.gitignore",".beads/config.yaml",".beads/interactions.jsonl","AGENTS.md"]' ] \
  && [ "$v2" = "$(tv .beads/interactions.jsonl clean)" ] && [ -z "$(ent "$r" .beads/interactions.jsonl "$k")" ] \
  && [ "$(ent "$r" AGENTS.md "$k")" = "declined absent" ] \
  && ok "beads_paths" || bad "beads_paths: [$v1] $e; AGENTS.md was '$a1'; [$v2]; ledger $(L ledger_read "$r")"

# worktree B never reads back worktree A's entries, even for a path of the same name
r="$(mkrepo)"
W="$TMPROOT/ritual fixtures/wt four"; git -C "$r" worktree add -q "$W" -b wfour 2>/dev/null
echo a > "$r/a.yml"; echo a > "$W/a.yml"
plan "$r" a.yml >/dev/null
pW="$(plan "$W")"; pR="$(plan "$r")"
[ -d "$W" ] && [ "$(pc "$pW")" = "$EMPTY" ] && [ "$(pc "$pR")" = '{"commit":[],"ask":["a.yml"],"notes":{}}' ] \
  && ok "readback_worktree_scoped" || bad "readback_worktree_scoped: W $pW / main $pR"

# ============================== fix round 1
echo "== a directory is fingerprinted by its content =="
# fix beads' wrote carries directories (.beads, .codex, .agents/skills/beads)
r="$(mkrepo)"; k="$(key "$r")"
mkdir -p "$r/bd dir/sub"; echo a > "$r/bd dir/a.txt"; echo b > "$r/bd dir/sub/b.txt"
printf 'bd dir/cache.db\n' > "$r/.gitignore"; echo c1 > "$r/bd dir/cache.db"
plan "$r" "bd dir" >/dev/null; settle_with "$r" declined
e0="$(ent "$r" "bd dir" "$k")"
echo c2 > "$r/bd dir/cache.db"                         # an ignored file is not part of it
v="$(V "$r" "bd dir")"; p="$(plan "$r")"
[ "${e0%% *}" = declined ] && [ "${e0#declined dir:}" != "$e0" ] && [ "$v" = "$(tv "bd dir" silent)" ] && [ "$(pc "$p")" = "$EMPTY" ] \
  && ok "dir_declined_unchanged_silent" || bad "dir_declined_unchanged_silent: entry '$e0' [$v] plan $p"
echo "my own edit" >> "$r/bd dir/sub/b.txt"
v="$(V "$r" "bd dir")"; p="$(plan "$r")"
# (in `ask`: its files are dirty at this plan's preflight, and since R12 a directory holding a dirty
# path is dirty itself)
[ "$v" = "$(tv "bd dir" offer-note)" ] && [ "$(pc "$p")" = '{"commit":[],"ask":["bd dir"],"notes":{"bd dir":"'"$NOTE"'"}}' ] \
  && ok "dir_declined_file_changed_note" || bad "dir_declined_file_changed_note: [$v] plan $p"

# raw bytes, as for a file: neither an attributes nor an autocrlf change moves a directory's fp
r="$(mkrepo)"
mkdir -p "$r/crlf dir"; printf 'one\r\ntwo\r\n' > "$r/crlf dir/w.txt"
git -C "$r" add "crlf dir"; git -C "$r" commit -q -m crlf; printf 'three\r\n' >> "$r/crlf dir/w.txt"
f0="$(L ledger_fps "$r" "crlf dir" | tr -d '\r')"; h0="$(git -C "$r" hash-object -- "crlf dir/w.txt" | tr -d '\r')"
printf '* text=auto\n' > "$r/.gitattributes"; git -C "$r" config core.autocrlf true
f1="$(L ledger_fps "$r" "crlf dir" | tr -d '\r')"; h1="$(git -C "$r" hash-object -- "crlf dir/w.txt" | tr -d '\r')"
[ "$h0" != "$h1" ] && [ "${f0#"crlf dir"$'\t'dir:}" != "$f0" ] && [ "$f1" = "$f0" ] \
  && ok "dir_fp_raw_bytes" || bad "dir_fp_raw_bytes: [$f0] -> [$f1]; filtered $h0 -> $h1"

# a tracked file deleted from disk inside a declined directory changes the directory's fp
r="$(mkrepo)"
mkdir -p "$r/trk dir"; echo a > "$r/trk dir/a.txt"; echo b > "$r/trk dir/b.txt"
git -C "$r" add "trk dir"; git -C "$r" commit -q -m trk; echo n > "$r/trk dir/new.txt"
plan "$r" "trk dir" >/dev/null; settle_with "$r" declined
v0="$(V "$r" "trk dir")"
rm "$r/trk dir/b.txt"
v1="$(V "$r" "trk dir")"
[ "$v0" = "$(tv "trk dir" silent)" ] && [ "$v1" = "$(tv "trk dir" offer-note)" ] \
  && ok "dir_deleted_tracked_file_changes_fp" || bad "dir_deleted_tracked_file_changes_fp: [$v0] -> [$v1]"

echo "== rerun-rule gaps =="
# the read-back paths are marked shown at their current fingerprint, so a second decline settles them
# at that fingerprint and they go quiet again
r="$(mkrepo)"; k="$(key "$r")"
echo 'on: push' > "$r/ci.yml"; plan "$r" ci.yml >/dev/null; settle_with "$r" declined
echo '# my own edit' >> "$r/ci.yml"
plan "$r" >/dev/null; s1="$(ent "$r" ci.yml "$k")"
settle_with "$r" declined; s2="$(ent "$r" ci.yml "$k")"; p="$(plan "$r")"
[ "$s1" = "shown $(raw "$r" ci.yml)" ] && [ "$s2" = "declined $(raw "$r" ci.yml)" ] && [ "$(pc "$p")" = "$EMPTY" ] \
  && ok "readback_paths_marked_shown" || bad "readback_paths_marked_shown: [$s1] [$s2] plan $p"

# --skip-tracked joins the constant for one call, for a tracked path the constant does not name
r="$(mkrepo)"
echo k > "$r/keep.txt"; git -C "$r" add keep.txt; git -C "$r" commit -q -m keep
echo "a ritual line" >> "$r/keep.txt"; plan "$r" keep.txt >/dev/null; echo "my own line" >> "$r/keep.txt"
e1="$(EA x "$r" d keep.txt)"
e2="$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/ledger.sh"
       emit_already --skip-tracked keep.txt x "$r" d keep.txt; printf '\n%s' "${_RITUAL_SKIP_TRACKED[*]}" )"
[ "$(jq -c .wrote <<<"$e1")" = '["keep.txt"]' ] && [ "$(head -n 1 <<<"$e2" | jq -c '[.wrote, .detail]' | tr -d '\r')" = '[[],"d"]' ] \
  && [ "$(tail -n 1 <<<"$e2" | tr -d '\r')" = .beads/issues.jsonl ] \
  && ok "skip_tracked_join_outside_constant" || bad "skip_tracked_join_outside_constant: $e1 / $e2"

# ledger_fps failing inside ledger_verdicts: the entry's paths are offered (a declined, unchanged
# file would be silent), with one stderr line
r="$(mkrepo)"
echo ci > "$r/ci.yml"; plan "$r" ci.yml >/dev/null; settle_with "$r" declined
v0="$(V "$r" ci.yml)"
v="$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/ledger.sh"; ledger_fps() { return 1; }
      ledger_verdicts "$r" ci.yml 2>"$TMPROOT/efp" )"; rc=$?
[ "$v0" = "$(tv ci.yml silent)" ] && [ "$rc" = 0 ] && [ "$(tr -d '\r' <<<"$v")" = "$(tv ci.yml offer)" ] \
  && one_line "$TMPROOT/efp" && grep -q 'could not fingerprint' "$TMPROOT/efp" \
  && ok "verdicts_fps_failure_offers" || bad "verdicts_fps_failure_offers: [$v0] rc=$rc [$v]; err [$(cat "$TMPROOT/efp")]"

# emit_already's second `unknown`: pending_paths answered, ledger_verdicts could not
r="$(mkrepo)"; echo n > "$r/new.txt"
e="$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/ledger.sh"; ledger_verdicts() { return 1; }; emit_already x "$r" d new.txt )"
[ "$(jq -c '[.status, .wrote, .detail]' <<<"$e" | tr -d '\r')" = '["unknown",[],"d; could not tell whether its files are committed (git status failed)"]' ] \
  && ok "emit_already_verdicts_failure_unknown" || bad "emit_already_verdicts_failure_unknown: $e"

# skip-tracked comes first under an unreadable ledger too, as it did before 0.16
r="$(mkrepo)"
mkdir -p "$r/.beads"; echo '{"id":"u-1"}' > "$r/.beads/issues.jsonl"; git -C "$r" add .beads; git -C "$r" commit -q -m export
echo '{"id":"u-2"}' >> "$r/.beads/issues.jsonl"; echo "my own edit" >> "$r/README.md"
printf 'not json{' > "$(lfile "$r")"
v="$(L ledger_verdicts "$r" .beads/issues.jsonl README.md 2>"$TMPROOT/esk" | tr -d '\r')"
[ "$v" = "$(tv .beads/issues.jsonl silent)"$'\n'"$(tv README.md offer)" ] && one_line "$TMPROOT/esk" \
  && ok "skip_tracked_under_unreadable_ledger" || bad "skip_tracked_under_unreadable_ledger: [$v]; err [$(cat "$TMPROOT/esk")]"

# the auto-run memo (_RITUAL_LG_*) is used for its own repo only, and the content is read every call
echo "== ledger context memo =="
TR="$TMPROOT/memo trace.log"
ra="$(mkrepo)"; rb="$(mkrepo)"
echo ci > "$ra/ci.yml"; plan "$ra" ci.yml >/dev/null; settle_with "$ra" declined
echo ci > "$rb/ci.yml"
va0="$(V "$ra" ci.yml)"
topb="$(git -C "$rb" rev-parse --show-toplevel | tr -d '\r')"
fb="$(lfile "$rb")"
: > "$TR"
va="$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/ledger.sh"
       _RITUAL_LG_REPO="$rb"; _RITUAL_LG_TOP="$topb"; _RITUAL_LG_FILE="$fb"; _RITUAL_LG_WT="$(path_norm "$topb")"
       RITUAL_TRACE="$TR" ledger_verdicts "$ra" ci.yml )"
[ "$(grep -cx ledger_context "$TR")" = 1 ] && [ "$(tr -d '\r' <<<"$va")" = "$va0" ] && [ -n "$va0" ] \
  && ok "memo_for_another_repo_is_ignored" || bad "memo_for_another_repo_is_ignored: ctx=$(grep -cx ledger_context "$TR") [$va] vs [$va0]"

# with the memo set for this repo, a rewrite of the ledger between two calls shows in the second
topa="$(git -C "$ra" rev-parse --show-toplevel | tr -d '\r')"; fa="$(lfile "$ra")"
vm1="$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/ledger.sh"
        _RITUAL_LG_REPO="$ra"; _RITUAL_LG_TOP="$topa"; _RITUAL_LG_FILE="$fa"; _RITUAL_LG_WT="$(path_norm "$topa")"
        # both calls run in this shell (output to files), so a global the call sets would persist
        ledger_verdicts "$ra" ci.yml > "$TMPROOT/memo a.out"
        printf '{"entries":[]}\n' > "$fa"
        ledger_verdicts "$ra" ci.yml > "$TMPROOT/memo b.out"
        printf '%s|%s' "$(tr -d '\r' < "$TMPROOT/memo a.out")" "$(tr -d '\r' < "$TMPROOT/memo b.out")" )"
[ "$vm1" = "$va0|$(tv ci.yml offer)" ] && [ "$va0" = "$(tv ci.yml silent)" ] \
  && ok "ledger_read_every_call_sees_a_change" || bad "ledger_read_every_call_sees_a_change: [$vm1] want [$va0|$(tv ci.yml offer)]"

finish
