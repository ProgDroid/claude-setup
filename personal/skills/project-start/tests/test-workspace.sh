#!/usr/bin/env bash
# Tests: preflight, commit-plan, check untracked-docs, and the generic check/fix router.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

pf() { bash "$RITUAL" preflight "$1"; }

# --- preflight_clean
r="$(mkrepo)"; out="$(pf "$r")"; rc=$?
[ $rc -eq 0 ] && [ "$(jq -c '.dirty' <<<"$out")" = "[]" ] && [ "$(jq -r '.branch' <<<"$out")" = "main" ] \
  && [ "$(jq -c '[.bytes,.index]' <<<"$out")" = "[{},{}]" ] \
  && ok "preflight_clean" || bad "preflight_clean: rc=$rc $out"

# --- staged / unstaged / untracked, with XY codes, bytes, index
r="$(mkrepo)"
echo more >> "$r/README.md"
echo s > "$r/staged.txt"; git -C "$r" add staged.txt
echo u > "$r/untracked.txt"
out="$(pf "$r")"
xy() { jq -r --arg p "$1" '.dirty[]|select(.path==$p)|.xy' <<<"$out"; }
[ "$(jq '.dirty|length' <<<"$out")" = 3 ] && [ "$(xy README.md)" = " M" ] && [ "$(xy staged.txt)" = "A " ] \
  && [ "$(xy untracked.txt)" = "??" ] && ok "preflight_lists_staged_unstaged_untracked" \
  || bad "preflight_lists_staged_unstaged_untracked: $out"
want="$(sha256sum "$r/untracked.txt" | cut -d' ' -f1)"
[ "$(jq -r '.bytes["untracked.txt"]' <<<"$out")" = "$want" ] && ok "preflight_bytes_is_raw_sha256" || bad "bytes sha: $out"
[ "$(jq -r '.index["untracked.txt"]' <<<"$out")" = ABSENT ] && ok "preflight_index_absent_for_untracked" || bad "index absent: $out"
sb="$(git -C "$r" ls-files -s -- staged.txt | awk '{print $2}')"
[ "$(jq -r '.index["staged.txt"]' <<<"$out")" = "$sb" ] && [ ${#sb} -ge 40 ] && ok "preflight_index_is_stage0_blob" || bad "index blob: $out"
echo more2 >> "$r/README.md"
out2="$(pf "$r")"
[ "$(jq -r '.bytes["README.md"]' <<<"$out")" != "$(jq -r '.bytes["README.md"]' <<<"$out2")" ] \
  && ok "preflight_bytes_track_edits" || bad "bytes did not change after edit"
echo x > "$r/both.txt"; git -C "$r" add both.txt; i1="$(pf "$r" | jq -r '.index["both.txt"]')"
echo y >> "$r/both.txt"; o3="$(pf "$r")"
[ "$(jq -r '.dirty[]|select(.path=="both.txt")|.xy' <<<"$o3")" = "AM" ] && [ "$(jq -r '.index["both.txt"]' <<<"$o3")" = "$i1" ] \
  && ok "preflight_staged_and_unstaged_distinguished" || bad "AM: $o3"

# --- deleted file
r="$(mkrepo)"; rm "$r/README.md"; out="$(pf "$r")"
[ "$(jq -r '.bytes["README.md"]' <<<"$out")" = DELETED ] && [ "$(jq -r '.dirty[0].xy' <<<"$out")" = " D" ] \
  && [ "$(jq -r '.index["README.md"]' <<<"$out")" != ABSENT ] && ok "preflight_deleted_file" || bad "deleted: $out"

# --- CRLF vs LF with autocrlf=true: bytes differ (the hash-object trap)
r="$(mkrepo)"; git -C "$r" config core.autocrlf true
printf 'line one\r\nline two\r\n' > "$r/crlf.txt"
printf 'line one\nline two\n' > "$r/lf.txt"
out="$(pf "$r")"
a="$(jq -r '.bytes["crlf.txt"]' <<<"$out")"; b="$(jq -r '.bytes["lf.txt"]' <<<"$out")"
[ -n "$a" ] && [ "$a" != null ] && [ "$a" != "$b" ] && ok "preflight_distinguishes_crlf" || bad "crlf: $a vs $b"

# --- unborn branch
d="$TMPROOT/ritual fixtures/unborn"; mkdir -p "$d"; git -C "$d" init -q
echo hi > "$d/f.txt"
out="$(pf "$d")"; rc=$?
want="$(git -C "$d" symbolic-ref --short HEAD)"
[ $rc -eq 0 ] && [ "$(jq -r '.branch' <<<"$out")" = "$want" ] && [ -n "$want" ] \
  && [ "$(jq -r '.dirty[0].path' <<<"$out")" = f.txt ] && ok "preflight_unborn_branch" || bad "unborn rc=$rc $out"

# --- spaced path (repo) and spaced filename
r="$(mkrepo)"; echo a > "$r/my notes.md"; mkdir -p "$r/sub dir"; echo b > "$r/sub dir/x y.txt"
out="$(pf "$r")"
[ "$(jq -r '.dirty|map(.path)|sort|join("|")' <<<"$out")" = "my notes.md|sub dir/x y.txt" ] \
  && [ "$(jq -r '.bytes["my notes.md"]' <<<"$out")" = "$(sha256sum "$r/my notes.md"|cut -d' ' -f1)" ] \
  && ok "spaced_path_and_spaced_filename" || bad "spaced: $out"

# --- rename: both paths recorded
r="$(mkrepo)"; git -C "$r" mv README.md "renamed file.md"
out="$(pf "$r")"
ps="$(jq -r '.dirty|map(.path)|sort|join("|")' <<<"$out")"
[ "$ps" = "README.md|renamed file.md" ] && [ "$(jq -r '.bytes["README.md"]' <<<"$out")" = DELETED ] \
  && [ "$(jq -r '.index["README.md"]' <<<"$out")" = ABSENT ] \
  && [ "$(jq -r '.index["renamed file.md"]' <<<"$out")" != ABSENT ] \
  && [ "$(jq -r '.dirty[]|select(.path=="renamed file.md")|.xy' <<<"$out")" = "R " ] \
  && ok "preflight_rename_records_both_paths" || bad "rename: $out"

# --- commit-plan
plan() { bash "$RITUAL" commit-plan "$1" "$2" "$3"; }
r="$(mkrepo)"; echo x > "$r/.gitignore"
pf "$r" > "$TMPROOT/pf.json"
echo '[".gitignore",".gitattributes"]' > "$TMPROOT/wrote.json"
out="$(plan "$r" "$TMPROOT/pf.json" "$TMPROOT/wrote.json")"
[ "$(jq -c '.commit' <<<"$out")" = '[".gitattributes"]' ] && [ "$(jq -c '.ask' <<<"$out")" = '[".gitignore"]' ] \
  && ok "commit_plan_splits_pre_dirty" || bad "commit-plan: $out"
echo '[]' > "$TMPROOT/w0.json"
# a repo of its own (0.16): in $r the plan above showed .gitignore and no run has answered it, so
# the rerun rule reads it back into this plan (test-ledger.sh: interrupted_run_offers_again)
r0="$(mkrepo)"; pf "$r0" > "$TMPROOT/pf0.json"
out="$(plan "$r0" "$TMPROOT/pf0.json" "$TMPROOT/w0.json")"
[ "$(jq -c '[.commit,.ask]' <<<"$out")" = '[[],[]]' ] && ok "commit_plan_empty_wrote" || bad "empty: $out"
r2="$(mkrepo)"; pf "$r2" > "$TMPROOT/pf2.json"
out="$(plan "$r2" "$TMPROOT/pf2.json" "$TMPROOT/wrote.json")"
[ "$(jq -c '.commit' <<<"$out")" = '[".gitignore",".gitattributes"]' ] && [ "$(jq -c '.ask' <<<"$out")" = '[]' ] \
  && ok "commit_plan_clean_commits_all" || bad "clean plan: $out"
r3="$(mkrepo)"; git -C "$r3" mv README.md "new name.md"; echo z > "$r3/my notes.md"; pf "$r3" > "$TMPROOT/pf3.json"
jq -n '["README.md","new name.md","my notes.md","fresh.txt"]' > "$TMPROOT/w3.json"
out="$(plan "$r3" "$TMPROOT/pf3.json" "$TMPROOT/w3.json")"
[ "$(jq -c '.commit' <<<"$out")" = '["fresh.txt"]' ] && [ "$(jq -r '.ask|sort|join("|")' <<<"$out")" = "README.md|my notes.md|new name.md" ] \
  && ok "commit_plan_spaced_and_rename" || bad "plan3: $out"
plan "$r" "$TMPROOT/nope.json" "$TMPROOT/wrote.json" >/dev/null 2>&1 && bad "commit-plan accepted missing preflight file" || ok "commit_plan_missing_file_fails"
bash "$RITUAL" commit-plan "$r" >/dev/null 2>&1 && bad "commit-plan no args" || ok "commit_plan_usage_fails"

# --- commit (the ritual's own commit, built in a scratch index)
printf 'chore: project-start ritual\n' > "$TMPROOT/msg.txt"
rc_() { bash "$RITUAL" commit "$1" --preflight "$2" --message-file "$TMPROOT/msg.txt" "${@:3}"; }
jr() { printf '%s' "$1" | jq -r "$2" | tr -d '\r'; }
headof() { git -C "$1" rev-parse -q --verify HEAD | tr -d '\r'; }
lsfs() { git -C "$1" ls-files -s | tr -d '\r'; }
intree() { git -C "$1" ls-tree -r --name-only HEAD -- "$2" | tr -d '\r'; }
leftover() { find "$(git -C "$1" rev-parse --absolute-git-dir | tr -d '\r')" -maxdepth 1 -name 'ritual-index.*' | wc -l | tr -d ' '; }
# control: the leftover probe can see a scratch index
r="$(mkrepo)"; : > "$(git -C "$r" rev-parse --absolute-git-dir | tr -d '\r')/ritual-index.ctl"
[ "$(leftover "$r")" = 1 ] && ok "leftover_probe_control_sees_a_scratch_index" || bad "leftover_probe_control_sees_a_scratch_index: $(leftover "$r")"

# the reviewer's case at unit size: a tracked file the ritual untracked (index-only deletion) and
# ignored, a new file, and the user's own staged change on another path
r="$(mkrepo)"; mkdir -p "$r/.beads"; : > "$r/.beads/interactions.jsonl"; echo a > "$r/a.txt"
git -C "$r" add -A; git -C "$r" commit -q -m two
pf "$r" > "$TMPROOT/c1.json"
printf 'interactions.jsonl\n' > "$r/.beads/.gitignore"
git -C "$r" rm -q --cached -- .beads/interactions.jsonl
echo new > "$r/my new.txt"
echo staged-by-user > "$r/user.txt"; git -C "$r" add user.txt; echo edit >> "$r/a.txt"
h0="$(headof "$r")"
out="$(rc_ "$r" "$TMPROOT/c1.json" -- .beads/.gitignore .beads/interactions.jsonl "my new.txt")"; rc=$?
[ "$rc" = 0 ] && [ "$(jr "$out" .status)" = fixed ] && [ "$(git -C "$r" rev-parse HEAD~1 | tr -d '\r')" = "$h0" ] \
  && ok "commit_fixed_on_a_child_of_head" || bad "commit_fixed_on_a_child_of_head: rc=$rc $out"
[ -z "$(intree "$r" .beads/interactions.jsonl)" ] && [ -z "$(git -C "$r" ls-files -- .beads/interactions.jsonl)" ] \
  && [ -f "$r/.beads/interactions.jsonl" ] && ok "commit_deletes_ignored_untracked_path" \
  || bad "commit_deletes_ignored_untracked_path: tree=[$(intree "$r" .beads/interactions.jsonl)] index=[$(git -C "$r" ls-files -- .beads/interactions.jsonl)]"
[ "$(git -C "$r" show --name-only --format= HEAD | tr -d '\r' | LC_ALL=C sort | paste -sd'|' -)" = ".beads/.gitignore|.beads/interactions.jsonl|my new.txt" ] \
  && ok "commit_holds_exactly_the_ritual_paths" || bad "commit_holds_exactly_the_ritual_paths: $(git -C "$r" show --name-only --format= HEAD | paste -sd'|' -)"
[ "$(git -C "$r" diff --cached --name-only | tr -d '\r')" = user.txt ] && [ -z "$(intree "$r" user.txt)" ] \
  && [ "$(git -C "$r" status --porcelain -- a.txt | tr -d '\r')" = " M a.txt" ] \
  && ok "commit_leaves_user_staged_and_unstaged_work_alone" \
  || bad "commit_leaves_user_staged_and_unstaged_work_alone: cached=[$(git -C "$r" diff --cached --name-only)] a=[$(git -C "$r" status --porcelain -- a.txt)]"
[ -z "$(git -C "$r" status --porcelain -- .beads "my new.txt" | tr -d '\r')" ] && ok "commit_syncs_real_index" \
  || bad "commit_syncs_real_index: $(git -C "$r" status --porcelain -- .beads 'my new.txt' | paste -sd'|' -)"
[ "$(leftover "$r")" = 0 ] && ok "commit_leaves_no_scratch_index" || bad "commit_leaves_no_scratch_index: $(leftover "$r")"

# nothing to commit
out="$(rc_ "$r" "$TMPROOT/c1.json" -- .beads/.gitignore "my new.txt")"
[ "$(jr "$out" .status)" = already ] && [ "$(headof "$r")" = "$(git -C "$r" rev-parse HEAD | tr -d '\r')" ] \
  && ok "commit_nothing_to_commit_is_already" || bad "commit_nothing_to_commit_is_already: $out"

# a path dirty at preflight: refused without --include-dirty, committed with it
r="$(mkrepo)"; echo mine > "$r/.gitignore"; pf "$r" > "$TMPROOT/c2.json"; echo '.env' >> "$r/.gitignore"
h0="$(headof "$r")"; i0="$(lsfs "$r")"
out="$(rc_ "$r" "$TMPROOT/c2.json" -- .gitignore)"
[ "$(jr "$out" .status)" = failed ] && [[ "$(jr "$out" .detail)" == *"--include-dirty"* ]] && [ "$(headof "$r")" = "$h0" ] \
  && [ "$(lsfs "$r")" = "$i0" ] && ok "commit_refuses_dirty_at_preflight" || bad "commit_refuses_dirty_at_preflight: $out"
out="$(rc_ "$r" "$TMPROOT/c2.json" --include-dirty -- .gitignore)"
[ "$(jr "$out" .status)" = fixed ] && [ -n "$(intree "$r" .gitignore)" ] && [ -z "$(git -C "$r" status --porcelain | tr -d '\r')" ] \
  && ok "commit_includes_dirty_when_confirmed" || bad "commit_includes_dirty_when_confirmed: $out"

# a pre-commit hook that rejects: failed, HEAD and the real index unchanged
r="$(mkrepo)"; pf "$r" > "$TMPROOT/c3.json"; echo x > "$r/x.txt"; echo s > "$r/s.txt"; git -C "$r" add s.txt
mkdir -p "$r/.git/hooks"; printf '#!/bin/sh\necho "rejected by hook" >&2\nexit 1\n' > "$r/.git/hooks/pre-commit"; chmod +x "$r/.git/hooks/pre-commit"
h0="$(headof "$r")"; i0="$(lsfs "$r")"; ib0="$(sha256sum "$r/.git/index" | cut -d' ' -f1)"
out="$(rc_ "$r" "$TMPROOT/c3.json" -- x.txt)"
[ "$(jr "$out" .status)" = failed ] && [[ "$(jr "$out" .detail)" == *"rejected by hook"* ]] && [ "$(headof "$r")" = "$h0" ] \
  && [ "$(lsfs "$r")" = "$i0" ] && [ "$(sha256sum "$r/.git/index" | cut -d' ' -f1)" = "$ib0" ] && [ "$(leftover "$r")" = 0 ] \
  && ok "commit_hook_rejection_changes_nothing" || bad "commit_hook_rejection_changes_nothing: $out"

# the hook sees the commit's content through the scratch index
printf '#!/bin/sh\ngit diff --cached --name-only > "%s"\nexit 0\n' "$TMPROOT/hook-saw.txt" > "$r/.git/hooks/pre-commit"
out="$(rc_ "$r" "$TMPROOT/c3.json" -- x.txt)"
[ "$(jr "$out" .status)" = fixed ] && [ "$(tr -d '\r' < "$TMPROOT/hook-saw.txt")" = x.txt ] \
  && ok "commit_hook_sees_only_the_ritual_paths" || bad "commit_hook_sees_only_the_ritual_paths: $out saw=[$(cat "$TMPROOT/hook-saw.txt" 2>/dev/null)]"

# a hook's own glob pathspecs still work: the ritual's literal-pathspec mode must not leak into it
r="$(mkrepo)"; pf "$r" > "$TMPROOT/c3g.json"; mkdir -p "$r/docs"; echo d > "$r/docs/notes.md"; echo t > "$r/t.txt"
mkdir -p "$r/.git/hooks"; printf '#!/bin/sh\ngit diff --cached --name-only -- "*.md" > "%s"\nexit 0\n' "$TMPROOT/hook-glob.txt" > "$r/.git/hooks/pre-commit"
chmod +x "$r/.git/hooks/pre-commit"
out="$(rc_ "$r" "$TMPROOT/c3g.json" -- docs/notes.md t.txt)"
[ "$(jr "$out" .status)" = fixed ] && [ "$(tr -d '\r' < "$TMPROOT/hook-glob.txt")" = docs/notes.md ] \
  && ok "commit_hook_globs_still_match" || bad "commit_hook_globs_still_match: $out saw=[$(cat "$TMPROOT/hook-glob.txt" 2>/dev/null)]"

# a path missing from the work tree is a deletion; the real index's mode is kept
r="$(mkrepo)"; echo h > "$r/hook.sh"; git -C "$r" add hook.sh; git -C "$r" update-index --chmod=+x hook.sh
chmod +x "$r/hook.sh"  # the work tree too: with core.fileMode=true (Linux) a 644 file against a 755 index reads as dirty
git -C "$r" commit -q -m h; pf "$r" > "$TMPROOT/c4.json"
rm "$r/README.md"; echo h2 >> "$r/hook.sh"; git -C "$r" add hook.sh
out="$(rc_ "$r" "$TMPROOT/c4.json" -- README.md hook.sh)"
[ "$(jr "$out" .status)" = fixed ] && [ -z "$(intree "$r" README.md)" ] \
  && [ "$(git -C "$r" ls-tree HEAD -- hook.sh | cut -c1-6)" = 100755 ] && [ -z "$(git -C "$r" status --porcelain | tr -d '\r')" ] \
  && ok "commit_deletion_and_mode" || bad "commit_deletion_and_mode: $out tree=$(git -C "$r" ls-tree HEAD -- hook.sh)"

# an unborn branch gets a root commit; the user's staged file stays out
d="$TMPROOT/ritual fixtures/unborn repo"; mkdir -p "$d"; git -C "$d" init -q -b main
git -C "$d" config user.email t@example.com; git -C "$d" config user.name Test; git -C "$d" config core.autocrlf false
pf "$d" > "$TMPROOT/c5.json"; echo r > "$d/ritual.txt"; echo u > "$d/user.txt"; git -C "$d" add user.txt
out="$(rc_ "$d" "$TMPROOT/c5.json" -- ritual.txt)"
[ "$(jr "$out" .status)" = fixed ] && [ "$(git -C "$d" ls-tree -r --name-only HEAD | tr -d '\r')" = ritual.txt ] \
  && [ "$(git -C "$d" diff --cached --name-only | tr -d '\r')" = user.txt ] && ok "commit_unborn_branch_root_commit" \
  || bad "commit_unborn_branch_root_commit: $out"

# an operation in progress is refused; usage errors exit 2
r="$(mkrepo)"; pf "$r" > "$TMPROOT/c6.json"; echo n > "$r/n.txt"; git -C "$r" rev-parse HEAD | tr -d '\r' > "$r/.git/MERGE_HEAD"
h0="$(headof "$r")"; out="$(rc_ "$r" "$TMPROOT/c6.json" -- n.txt)"
[ "$(jr "$out" .status)" = failed ] && [[ "$(jr "$out" .detail)" == *MERGE_HEAD* ]] && [ "$(headof "$r")" = "$h0" ] \
  && ok "commit_refuses_during_a_merge" || bad "commit_refuses_during_a_merge: $out"
rm -f "$r/.git/MERGE_HEAD"
bash "$RITUAL" commit "$r" --preflight "$TMPROOT/c6.json" -- n.txt >/dev/null 2>&1; rc1=$?
bash "$RITUAL" commit "$r" --message-file "$TMPROOT/msg.txt" -- n.txt >/dev/null 2>&1; rc2=$?
[ "$rc1" = 2 ] && [ "$rc2" = 2 ] && [ "$(headof "$r")" = "$h0" ] && ok "commit_usage_errors_exit_2" || bad "commit_usage_errors_exit_2: $rc1 $rc2"

# M1: TERM while a slow post-commit hook runs, i.e. after git moved the branch and before the real
# index is synced. Sent the way `timeout` sends it: to the ritual and its whole process group.
r="$(mkrepo)"; pf "$r" > "$TMPROOT/c7.json"; echo c > "$r/CLAUDE.md"; mkdir -p "$r/docs"; echo p > "$r/docs/parking-lot.md"
mkdir -p "$r/.git/hooks"; printf '#!/bin/sh\n: > "%s"\nsleep 3\n' "$TMPROOT/c7-post-commit-ran" > "$r/.git/hooks/post-commit"
chmod +x "$r/.git/hooks/post-commit"; h0="$(headof "$r")"
timeout -s TERM 120 bash "$RITUAL" commit "$r" --preflight "$TMPROOT/c7.json" --message-file "$TMPROOT/msg.txt" \
  -- CLAUDE.md docs/parking-lot.md > "$TMPROOT/c7.out" 2>"$TMPROOT/c7.err" & tpid=$!
for i in $(seq 1 300); do [ -e "$TMPROOT/c7-post-commit-ran" ] && break; sleep 0.1; done
kill -TERM "$tpid" 2>/dev/null; wait "$tpid"; rc=$?
moved=0; [ -e "$TMPROOT/c7-post-commit-ran" ] && [ "$(git -C "$r" rev-parse -q --verify HEAD~1 | tr -d '\r')" = "$h0" ] && moved=1
[ "$moved" = 1 ] && [ "$(git -C "$r" show --name-only --format= HEAD | tr -d '\r' | LC_ALL=C sort | paste -sd'|' -)" = "CLAUDE.md|docs/parking-lot.md" ] \
  && ok "commit_term_premise_the_signal_landed_after_the_commit_was_made" || bad "commit_term_premise: moved=$moved rc=$rc out=$(cat "$TMPROOT/c7.out")"
[ -z "$(git -C "$r" diff --cached --name-status | tr -d '\r')" ] && [ -z "$(git -C "$r" status --porcelain | tr -d '\r')" ] \
  && ok "commit_term_after_the_commit_still_syncs_the_real_index" \
  || bad "commit_term_after_the_commit_still_syncs_the_real_index: $(git -C "$r" status --porcelain | paste -sd'|' -)"
[ "$(leftover "$r")" = 0 ] && ok "commit_term_leaves_no_scratch_index" || bad "commit_term_leaves_no_scratch_index: $(leftover "$r")"
[ "$rc" -ge 128 ] && [ "$(jq -r .status "$TMPROOT/c7.out" 2>/dev/null | tr -d '\r')" = fixed ] \
  && [[ "$(jq -r .detail "$TMPROOT/c7.out" | tr -d '\r')" == *SIGTERM* ]] \
  && ok "commit_term_reports_the_commit_then_exits_by_the_signal" || bad "commit_term_reports_the_commit_then_exits_by_the_signal: rc=$rc out=$(cat "$TMPROOT/c7.out")"
# TERM before git commit runs: a git stub sends it to the ritual while the scratch tree is being
# written, after the scratch index exists. Nothing is committed and no scratch index is left.
SIGSTUB="$TMPROOT/term stub"; mkdir -p "$SIGSTUB"
{ printf '#!/usr/bin/env bash\nREAL_GIT=%q\nPIDF=%q\n' "$(command -v git)" "$TMPROOT/c8.pid"; cat <<'WRAP'
for a in "$@"; do
  if [ "$a" = write-tree ]; then
    for i in $(seq 1 100); do [ -s "$PIDF" ] && break; sleep 0.1; done
    kill -TERM "$(cat "$PIDF")"; break
  fi
done
exec "$REAL_GIT" "$@"
WRAP
} > "$SIGSTUB/git"; chmod +x "$SIGSTUB/git"
r="$(mkrepo)"; pf "$r" > "$TMPROOT/c8.json"; echo c > "$r/CLAUDE.md"; h0="$(headof "$r")"; i0="$(lsfs "$r")"
PATH="$SIGSTUB:$PATH" bash "$RITUAL" commit "$r" --preflight "$TMPROOT/c8.json" --message-file "$TMPROOT/msg.txt" \
  -- CLAUDE.md > "$TMPROOT/c8.out" 2>"$TMPROOT/c8.err" & rpid=$!
echo "$rpid" > "$TMPROOT/c8.pid"; wait "$rpid"; rc=$?
[ "$(headof "$r")" = "$h0" ] && [ "$(lsfs "$r")" = "$i0" ] && [ "$(leftover "$r")" = 0 ] && [ "$rc" = 143 ] \
  && [ "$(jq -r .status "$TMPROOT/c8.out" 2>/dev/null | tr -d '\r')" = failed ] && [[ "$(jq -r .detail "$TMPROOT/c8.out" | tr -d '\r')" == *"interrupted by SIGTERM"* ]] \
  && ok "commit_term_before_git_commit_commits_nothing_and_cleans_up" \
  || bad "commit_term_before_git_commit: rc=$rc head-moved=$([ "$(headof "$r")" = "$h0" ] && echo no || echo yes) left=$(leftover "$r") out=$(cat "$TMPROOT/c8.out") err=$(cat "$TMPROOT/c8.err")"
# TERM to the ritual's own pid (not its group, so git and its hook never see it) while a pre-commit
# hook holds git: git goes on to make the commit, and the detail must not say the signal came after
# the commit was made. The hook waits for a file this test creates after the signal (60 s bound);
# a watchdog kills the ritual after 120 s, so no step can hang the suite.
r="$(mkrepo)"; pf "$r" > "$TMPROOT/c9.json"; echo c > "$r/CLAUDE.md"; h0="$(headof "$r")"
HIN="$TMPROOT/c9 hook entered"; HGO="$TMPROOT/c9 hook release"; rm -f "$HIN" "$HGO"
mkdir -p "$r/.git/hooks"
printf '#!/bin/sh\n: > "%s"\ni=0\nwhile [ ! -e "%s" ] && [ "$i" -lt 600 ]; do sleep 0.1; i=$((i + 1)); done\nexit 0\n' "$HIN" "$HGO" > "$r/.git/hooks/pre-commit"
chmod +x "$r/.git/hooks/pre-commit"
bash "$RITUAL" commit "$r" --preflight "$TMPROOT/c9.json" --message-file "$TMPROOT/msg.txt" \
  -- CLAUDE.md > "$TMPROOT/c9.out" 2>"$TMPROOT/c9.err" & rpid=$!
( for _ in $(seq 1 1200); do kill -0 "$rpid" 2>/dev/null || exit 0; sleep 0.1; done; kill -KILL "$rpid" 2>/dev/null ) & wd=$!
for _ in $(seq 1 300); do [ -e "$HIN" ] && break; sleep 0.1; done
pre=0; [ -e "$HIN" ] && [ "$(headof "$r")" = "$h0" ] && pre=1
kill -TERM "$rpid" 2>/dev/null; sleep 1
[ "$pre" = 1 ] && [ "$(headof "$r")" = "$h0" ] || pre=0   # still uncommitted a second after the signal
: > "$HGO"; wait "$rpid"; rc=$?; wait "$wd" 2>/dev/null
d9="$(jq -r .detail "$TMPROOT/c9.out" 2>/dev/null | tr -d '\r')"
[ "$pre" = 1 ] && [ "$(git -C "$r" rev-parse -q --verify HEAD~1 | tr -d '\r')" = "$h0" ] \
  && ok "commit_pid_term_premise_the_signal_landed_while_the_hook_held_git" \
  || bad "commit_pid_term_premise: pre=$pre rc=$rc out=$(cat "$TMPROOT/c9.out") err=$(cat "$TMPROOT/c9.err")"
[ "$rc" = 143 ] && [ "$(jq -r .status "$TMPROOT/c9.out" 2>/dev/null | tr -d '\r')" = fixed ] \
  && [[ "$d9" == *"SIGTERM arrived while git commit was running"* ]] && [[ "$d9" != *"after git made the commit"* ]] \
  && ok "pid_term_during_precommit_wording" || bad "pid_term_during_precommit_wording: rc=$rc detail=[$d9]"
# git killed mid-commit, printing nothing: the detail names that instead of ending in a bare ": "
KILLSTUB="$TMPROOT/kill stub"; mkdir -p "$KILLSTUB"
{ printf '#!/usr/bin/env bash\nREAL_GIT=%q\n' "$(command -v git)"; cat <<'WRAP'
for a in "$@"; do [ "$a" = commit ] && kill -KILL $$; done
exec "$REAL_GIT" "$@"
WRAP
} > "$KILLSTUB/git"; chmod +x "$KILLSTUB/git"
r="$(mkrepo)"; pf "$r" > "$TMPROOT/c10.json"; echo c > "$r/CLAUDE.md"; h0="$(headof "$r")"; i0="$(lsfs "$r")"
out="$(PATH="$KILLSTUB:$PATH"; rc_ "$r" "$TMPROOT/c10.json" -- CLAUDE.md)"
d10="$(jr "$out" .detail)"
[ "$(jr "$out" .status)" = failed ] && [ "$(headof "$r")" = "$h0" ] && [ "$(lsfs "$r")" = "$i0" ] && [ "$(leftover "$r")" = 0 ] \
  && [[ "$d10" == "git commit failed, HEAD and the index are unchanged"* ]] && [[ "$d10" != *": " ]] \
  && [[ "$d10" == *"git printed nothing (exit 137)" ]] \
  && ok "killed_git_detail_has_no_empty_tail" || bad "killed_git_detail_has_no_empty_tail: detail=[$d10] out=$out"

# --- check untracked-docs
r="$(mkrepo)"; mkdir -p "$r/docs" "$r/src"; echo a > "$r/docs/a.md"; echo b > "$r/src/b.rs"
out="$(bash "$RITUAL" check untracked-docs "$r")"
[ "$(jq -r '.id' <<<"$out")" = untracked-docs ] && [ "$(jq -r '.status' <<<"$out")" = present ] \
  && jq -e '.detail|contains("docs/a.md") and (contains("src/b.rs")|not)' <<<"$out" >/dev/null \
  && ok "untracked_docs_lists_only_docs" || bad "docs: $out"
r="$(mkrepo)"; mkdir -p "$r/docs" "$r/src"; echo a > "$r/docs/a.md"; git -C "$r" add docs/a.md; git -C "$r" commit -qm d
echo b > "$r/src/b.rs"
out="$(bash "$RITUAL" check untracked-docs "$r")"
[ "$(jq -r '.status' <<<"$out")" = absent ] && ok "untracked_docs_absent_when_tracked" || bad "docs absent: $out"
r="$(mkrepo)"; mkdir -p "$r/docs"; echo ig > "$r/.gitignore"; echo x > "$r/docs/ig"
out="$(bash "$RITUAL" check untracked-docs "$r")"
[ "$(jq -r '.status' <<<"$out")" = absent ] && ok "untracked_docs_ignores_gitignored" || bad "docs ignored: $out"
r="$(mkrepo)"; mkdir -p "$r/docs/deep dir"; echo a > "$r/docs/deep dir/my doc.md"
out="$(bash "$RITUAL" check untracked-docs "$r")"
[ "$(jq -r '.status' <<<"$out")" = present ] && jq -e '.detail|contains("docs/deep dir/my doc.md")' <<<"$out" >/dev/null \
  && ok "untracked_docs_spaced_nested" || bad "docs spaced: $out"
r="$(mkrepo)"
[ "$(bash "$RITUAL" check untracked-docs "$r" | jq -r .status)" = absent ] && ok "untracked_docs_absent_no_docs_dir" || bad "no docs dir"

# --- router
bash "$RITUAL" check no-such-step "$r" >/dev/null 2>"$TMPROOT/err"; rc=$?
[ $rc -ne 0 ] && grep -q "unknown step: no-such-step" "$TMPROOT/err" && ok "router_check_unknown_step_dies" || bad "router check rc=$rc $(cat "$TMPROOT/err")"
bash "$RITUAL" fix no-such-step "$r" >/dev/null 2>"$TMPROOT/err"; rc=$?
[ $rc -ne 0 ] && grep -q "unknown step: no-such-step" "$TMPROOT/err" && ok "router_fix_unknown_step_dies" || bad "router fix rc=$rc"
bash "$RITUAL" check untracked-docs "$TMPROOT/not-a-repo" >/dev/null 2>&1 && bad "router accepted non-repo" || ok "router_requires_repo"
bash "$RITUAL" check >/dev/null 2>&1 && bad "check with no args" || ok "router_check_usage_fails"
bash "$RITUAL" preflight "$TMPROOT/not-a-repo" >/dev/null 2>&1 && bad "preflight non-repo" || ok "preflight_requires_repo"

# --- MM: staged version then edited again; index must be the STAGED blob, not HEAD's
r="$(mkrepo)"; echo staged1 >> "$r/README.md"; git -C "$r" add README.md; echo more >> "$r/README.md"
out="$(pf "$r")"
stg="$(git -C "$r" ls-files -s -- README.md | awk '{print $2}')"; hd="$(git -C "$r" rev-parse HEAD:README.md)"
[ "$(jq -r '.dirty[0].xy' <<<"$out")" = MM ] && [ "$(jq -r '.index["README.md"]' <<<"$out")" = "$stg" ] \
  && [ "$stg" != "$hd" ] && ok "preflight_mm_index_is_staged_blob" || bad "MM: $out"

# --- commit-plan matching: no basename matching (.gitignore is not x/.gitignore). Since R12 a
# directory holding a dirty path is dirty itself, so `docs` (holding docs/a.md) goes to ask; before
# R12 it went to commit and the user's docs/a.md edit rode along unasked
jq -n '{branch:"main",dirty:[{path:"docs/a.md",xy:" M"},{path:"x/.gitignore",xy:"??"}],bytes:{},index:{}}' > "$TMPROOT/pfx.json"
jq -n '["docs",".gitignore","docs/a.md","x/.gitignore"]' > "$TMPROOT/wx.json"
out="$(bash "$RITUAL" commit-plan "$r" "$TMPROOT/pfx.json" "$TMPROOT/wx.json")"
[ "$(jq -c '.commit' <<<"$out")" = '[".gitignore"]' ] && [ "$(jq -c '.ask' <<<"$out")" = '["docs","docs/a.md","x/.gitignore"]' ] \
  && ok "commit_plan_exact_matching" || bad "exact: $out"

# --- git failure is UNKNOWN, never a clean tree
r="$(mkrepo)"; echo dirty > "$r/d.txt"
realgit="$(command -v git)"; stubd="$TMPROOT/failgit"; mkdir -p "$stubd"
cat > "$stubd/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = status ] && { echo "fatal: simulated failure" >&2; exit 128; }; done
exec "$realgit" "\$@"
STUB
chmod +x "$stubd/git"
out="$( PATH="$stubd:$PATH"; bash "$RITUAL" preflight "$r" 2>"$TMPROOT/err")"; rc=$?
[ $rc -ne 0 ] && [ -z "$out" ] && ok "preflight_git_status_failure_dies" || bad "status failure: rc=$rc out=$out"
# positive control: the stub passes non-status git calls through
out="$( PATH="$stubd:$PATH"; bash "$RITUAL" commit-plan "$r" "$TMPROOT/pfx.json" "$TMPROOT/wx.json")"
[ -n "$out" ] && ok "stub_control_passes_through" || bad "stub control"

# --- commit-plan's output always carries notes, and its readback fails soft
r="$(mkrepo)"; pf "$r" > "$TMPROOT/pfn.json"; echo '[]' > "$TMPROOT/wn0.json"; echo '["n.txt"]' > "$TMPROOT/wn1.json"
o0="$(plan "$r" "$TMPROOT/pfn.json" "$TMPROOT/wn0.json" | tr -d '\r')"
o1="$(plan "$r" "$TMPROOT/pfn.json" "$TMPROOT/wn1.json" | jq -c . | tr -d '\r')"
[ "$o0" = '{"commit":[],"ask":[],"notes":{}}' ] && [ "$o1" = '{"commit":["n.txt"],"ask":[],"notes":{}}' ] \
  && ok "commit_plan_output_always_has_notes" || bad "commit_plan_output_always_has_notes: [$o0] [$o1]"
# git status failing in the readback: the plan is this run's paths alone, with one stderr line
r="$(mkrepo)"; echo x > "$r/x.txt"; pf "$r" > "$TMPROOT/pfs.json"
echo '["x.txt"]' > "$TMPROOT/ws1.json"; plan "$r" "$TMPROOT/pfs.json" "$TMPROOT/ws1.json" >/dev/null   # x.txt shown
echo '["y.txt"]' > "$TMPROOT/ws2.json"
out="$( PATH="$stubd:$PATH"; plan "$r" "$TMPROOT/pfs.json" "$TMPROOT/ws2.json" 2>"$TMPROOT/errs")"; rc=$?
ctl="$(plan "$r" "$TMPROOT/pfs.json" "$TMPROOT/ws2.json" 2>/dev/null)"   # control: without the stub, x.txt is read back
[ "$rc" = 0 ] && [ "$(jq -c . <<<"$out" | tr -d '\r')" = '{"commit":["y.txt"],"ask":[],"notes":{}}' ] \
  && [ "$(grep -c '' "$TMPROOT/errs")" = 1 ] && grep -q '^ritual: ledger: ' "$TMPROOT/errs" \
  && [ "$(jq -c . <<<"$ctl" | tr -d '\r')" = '{"commit":["y.txt"],"ask":["x.txt"],"notes":{}}' ] \
  && ok "readback_status_failure_keeps_plan" || bad "readback_status_failure_keeps_plan: rc=$rc $out; err [$(cat "$TMPROOT/errs")]; control $ctl"

# --- R12: a directory holding a path dirty at preflight is dirty itself, for commit-plan and commit
# alike (one predicate, _DIRTY_JQ); a sibling sharing a name prefix is not under it
r="$(mkrepo)"; mkdir -p "$r/.beads" "$r/.beads-old"
echo "the user's" > "$r/.beads/mine.txt"; echo old > "$r/.beads-old/x"
pf "$r" > "$TMPROOT/pfd.json"
echo "the fix's" > "$r/.beads/house.txt"; echo '[".beads"]' > "$TMPROOT/wd.json"
out="$(plan "$r" "$TMPROOT/pfd.json" "$TMPROOT/wd.json" | jq -c . | tr -d '\r')"
[ "$out" = '{"commit":[],"ask":[".beads"],"notes":{}}' ] \
  && ok "commit_plan_dir_holding_a_dirty_file_asks" || bad "commit_plan_dir_holding_a_dirty_file_asks: $out"
s="$(mkrepo)"; mkdir -p "$s/.beads-old"; echo old > "$s/.beads-old/x"
pf "$s" > "$TMPROOT/pfs2.json"
mkdir -p "$s/.beads"; echo "the fix's" > "$s/.beads/house.txt"
out="$(plan "$s" "$TMPROOT/pfs2.json" "$TMPROOT/wd.json" | jq -c . | tr -d '\r')"
[ "$out" = '{"commit":[".beads"],"ask":[],"notes":{}}' ] \
  && ok "commit_plan_shared_prefix_sibling_not_matched" || bad "commit_plan_shared_prefix_sibling_not_matched: $out"
c1="$(rc_ "$r" "$TMPROOT/pfd.json" -- .beads)"
t1="$(git -C "$r" ls-files -- .beads | tr -d '\r')"
c2="$(rc_ "$r" "$TMPROOT/pfd.json" --include-dirty -- .beads)"
t2="$(git -C "$r" ls-files -- .beads | tr -d '\r' | paste -sd'|' -)"
[ "$(jq -r .status <<<"$c1" | tr -d '\r')" = failed ] && [[ "$(jq -r .detail <<<"$c1")" == "dirty at preflight: .beads;"* ]] && [ -z "$t1" ] \
  && [ "$(jq -r .status <<<"$c2" | tr -d '\r')" = fixed ] && [ "$t2" = ".beads/house.txt|.beads/mine.txt" ] \
  && ok "ritual_commit_refuses_a_dir_holding_a_dirty_file_without_include_dirty" \
  || bad "ritual_commit_refuses_a_dir_holding_a_dirty_file_without_include_dirty: $c1 [$t1] / $c2 [$t2]"

# --- non-regular paths (nested repo dir) are NONFILE, not DELETED
r="$(mkrepo)"; mkdir "$r/nested"; git -C "$r/nested" init -q; echo c > "$r/nested/f"
out="$(pf "$r")"
np="$(jq -r '.dirty[]|select(.path|startswith("nested"))|.path' <<<"$out")"
[ -n "$np" ] && [ "$(jq -r --arg p "$np" '.bytes[$p]' <<<"$out")" = NONFILE ] && ok "preflight_nonfile_nested_repo" || bad "nonfile: $out"
if ln -s README.md "$r/lnk" 2>/dev/null && [ -L "$r/lnk" ]; then
  out="$(pf "$r")"; ln_b="$(jq -r '.bytes["lnk"]' <<<"$out")"
  [ -n "$ln_b" ] && [ "$ln_b" != null ] && [ "$ln_b" != DELETED ] && ok "preflight_symlink_not_deleted" || bad "symlink: $ln_b"
else echo "  NOTE: symlinks not creatable here; symlink case not tested"; fi

# --- scale: 2000 untracked files must not take minutes
# Measured 2026-10-20 under Git Bash: 8 s quiet, 11 s with all 22 suites in parallel; the pre-fix
# per-file preflight (50ed949^) had not finished after 1200 s. 60 s is >5x clear of both.
r="$(mkrepo)"; mkdir -p "$r/node_modules/pkg"
for i in $(seq 1 2000); do : > "$r/node_modules/pkg/f$i.js"; done
t0=$SECONDS; out="$(pf "$r")"; rc=$?; el=$((SECONDS - t0))
echo "  (2000-file preflight took ${el}s)"
[ $rc -eq 0 ] && [ "$(jq '.dirty|length' <<<"$out")" = 2000 ] && [ "$(jq '.bytes|length' <<<"$out")" = 2000 ] \
  && [ "$el" -lt 60 ] && ok "preflight_2000_files_under_60s" || bad "scale: rc=$rc n=$(jq '.dirty|length' <<<"$out") ${el}s"

finish
