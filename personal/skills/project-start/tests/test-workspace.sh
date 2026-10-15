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
out="$(plan "$r" "$TMPROOT/pf.json" "$TMPROOT/w0.json")"
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

# --- commit-plan exact matching (no prefix / basename matching)
jq -n '{branch:"main",dirty:[{path:"docs/a.md",xy:" M"},{path:"x/.gitignore",xy:"??"}],bytes:{},index:{}}' > "$TMPROOT/pfx.json"
jq -n '["docs",".gitignore","docs/a.md","x/.gitignore"]' > "$TMPROOT/wx.json"
out="$(bash "$RITUAL" commit-plan "$r" "$TMPROOT/pfx.json" "$TMPROOT/wx.json")"
[ "$(jq -c '.commit' <<<"$out")" = '["docs",".gitignore"]' ] && [ "$(jq -c '.ask' <<<"$out")" = '["docs/a.md","x/.gitignore"]' ] \
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
r="$(mkrepo)"; mkdir -p "$r/node_modules/pkg"
for i in $(seq 1 2000); do : > "$r/node_modules/pkg/f$i.js"; done
t0=$SECONDS; out="$(pf "$r")"; rc=$?; el=$((SECONDS - t0))
echo "  (2000-file preflight took ${el}s)"
[ $rc -eq 0 ] && [ "$(jq '.dirty|length' <<<"$out")" = 2000 ] && [ "$(jq '.bytes|length' <<<"$out")" = 2000 ] \
  && [ "$el" -lt 20 ] && ok "preflight_2000_files_under_20s" || bad "scale: rc=$rc n=$(jq '.dirty|length' <<<"$out") ${el}s"

finish
