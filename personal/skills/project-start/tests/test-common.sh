#!/usr/bin/env bash
# Tests for lib/common.sh and the tests/lib.sh helpers later tasks depend on.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/lib/common.sh"

echo "== steps.json =="
sj="$(steps_json)"
[ -f "$sj" ] && ok "steps_json names an existing file" || bad "steps_json: $sj"
exp='preflight beads stack lessons traps stack-checks oracle public-sweep secret-scan workspace untracked-docs parking-lot beads-seed beads-metrics ci baseline handoff commit record'
[ "$(jq -r '.steps|map(.id)|join(" ")' "$sj")" = "$exp" ] && ok "19 step ids in spec order" || bad "ids: $(jq -r '.steps|map(.id)|join(" ")' "$sj")"
[ "$(jq -c '[.steps[].version]|unique' "$sj")" = '[1]' ] && [ "$(jq .ritual_version "$sj")" = 1 ] && ok "all versions 1, ritual_version 1" || bad "versions"
[ "$(jq -r '.steps[]|select(.id=="stack-checks")|.kind' "$sj")" = ask ] && [ "$(jq -r '.steps[]|select(.id=="preflight")|.kind' "$sj")" = check ] \
  && [ "$(jq -r '.steps[]|select(.id=="oracle")|.kind' "$sj")" = auto ] && ok "kinds follow the spec table" || bad "kinds"
[ "$(jq -c '.steps|map(select(.id=="parking-lot"))|.[0]|[.kind,.version]' "$sj")" = '["auto",1]' ] && ok "parking-lot is kind auto, version 1" || bad "parking-lot kind/version"
[ "$(RITUAL_STEPS_JSON=/x/y steps_json)" = /x/y ] && ok "RITUAL_STEPS_JSON overrides" || bad "override ignored"

echo "== emit =="
e="$(emit traps present "added 2 lines" .gitignore .gitattributes)"
[ "$(printf '%s' "$e" | jq -c .)" = '{"id":"traps","status":"present","detail":"added 2 lines","wrote":[".gitignore",".gitattributes"]}' ] \
  && ok "emit with wrote paths" || bad "emit: $e"
[ "$(emit oracle unknown "no tool" | jq -c .wrote)" = '[]' ] && ok "emit with no wrote gives []" || bad "emit empty wrote"
[ "$(emit x absent 'a "quoted" b' | jq -r .detail)" = 'a "quoted" b' ] && ok "emit escapes quotes" || bad "emit quoting"
# (built with printf -v: a $'...' string inside "$(...)" loses its CR under Git Bash)
printf -v crs 'a\r\nb\\c\037'
[ "$(emit x absent "$crs" | jq -c .detail)" = '"a\r\nb\\c\u001f"' ] && ok "emit_keeps_cr_and_control_bytes_in_detail" || bad "emit CR: $(emit x absent "$crs" | jq -c .detail)"
[ "$(emit x absent d "" "a b" | jq -c .wrote)" = '["","a b"]' ] && ok "emit_keeps_empty_and_spaced_wrote_elements" || bad "emit empty element"
# the argv limit: jq.exe is a native Windows program (~32 KB command line). A 60 KB detail and
# 2000 spaced paths must come back exactly, or every step that reports them prints nothing.
big="$(printf 'chunk "q" \\ é %04d; ' $(seq 1 3000))"; big="${big:0:61440}"
mapfile -t paths < <(seq 1 2000 | sed 's|^|some dir/file |; s|$|.txt|')
e="$(emit untracked-docs present "$big" "${paths[@]}")"
printf '%s' "$big" > "$TMPROOT/big.exp"; printf '%s' "$e" | jq -j .detail > "$TMPROOT/big.got" 2>/dev/null
printf '%s\n' "${paths[@]}" > "$TMPROOT/paths.exp"; printf '%s' "$e" | jq -r '.wrote[]' 2>/dev/null | tr -d '\r' > "$TMPROOT/paths.got"
[ "${#big}" -ge 60000 ] && [ "${#paths[@]}" = 2000 ] && cmp -s "$TMPROOT/big.exp" "$TMPROOT/big.got" && cmp -s "$TMPROOT/paths.exp" "$TMPROOT/paths.got" \
  && ok "emit_large_detail_and_wrote" || bad "emit large: detail ${#big} chars, emitted $(printf '%s' "$e" | wc -c) bytes"

echo "== md_fence =="
# fence_mask <line...> -> one char per line: F = fence or inside one, . = could be a heading
fence_mask() { local l m=""; MD_FENCE=""; for l in "$@"; do if md_fence "$l"; then m+=F; else m+=.; fi; done; printf '%s' "$m"; }
[ "$(fence_mask '## a' '```' '## b' '```' '## c')" = '.FFF.' ] && ok "md_fence_backtick_block" || bad "backtick: $(fence_mask '## a' '```' '## b' '```' '## c')"
[ "$(fence_mask '~~~md' '## b' '```' '~~~~' '## c')" = 'FFFF.' ] && ok "md_fence_tilde_block_not_closed_by_backticks" || bad "tilde: $(fence_mask '~~~md' '## b' '```' '~~~~' '## c')"
[ "$(fence_mask '    ```' '## b')" = '..' ] && ok "md_fence_four_space_indent_is_not_a_fence" || bad "indent: $(fence_mask '    ```' '## b')"
[ "$(fence_mask $'```\r' $'## b\r' $'```\r' $'## c\r')" = 'FFF.' ] && ok "md_fence_crlf_lines" || bad "crlf fence"

echo "== git_common_dir =="
repo="$(mkrepo)"
g="$(git_common_dir "$repo")"
[ -d "$g" ] && [ "$(basename "$g")" = .git ] && ok "git_common_dir is the absolute .git of a spaced repo" || bad "git_common_dir: $g"

echo "== pending_paths =="
# pp <repo> <path>... -> what pending_paths printed (NUL-separated), one path per line, sorted
pp() { pending_paths "$@" | tr '\0' '\n' | LC_ALL=C sort | paste -sd'|' -; }
r="$(mkrepo pend)"
printf 'ign.txt\n' > "$r/.gitignore"
for f in tracked kept gone staged moved; do echo "$f" > "$r/$f.txt"; done
git -C "$r" add -A; git -C "$r" commit -q -m files
echo more >> "$r/tracked.txt"; rm "$r/gone.txt"; echo s2 >> "$r/staged.txt"; git -C "$r" add staged.txt
git -C "$r" mv moved.txt "re named.txt"
mkdir -p "$r/sub dir"; echo n > "$r/sub dir/new file.txt"; echo i > "$r/ign.txt"
got="$(pp "$r" tracked.txt kept.txt gone.txt staged.txt moved.txt "re named.txt" "sub dir" ign.txt missing.txt)"
[ "$got" = "gone.txt|moved.txt|re named.txt|staged.txt|sub dir/new file.txt|tracked.txt" ] \
  && ok "pending_paths_lists_modified_deleted_staged_renamed_and_untracked_files_only" || bad "pending_paths_lists_modified_deleted_staged_renamed_and_untracked_files_only: [$got]"
# never a name pattern: '*.txt' is a literal path here (a glob would match six files), and an
# ignored file is not pending even when named
got="$(pp "$r" '*.txt' ign.txt)"
[ -z "$got" ] && ok "pending_paths_takes_paths_literally_and_skips_ignored" || bad "pending_paths_takes_paths_literally_and_skips_ignored: [$got]"
pending_paths "$r" > "$TMPROOT/pp-none.out"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$TMPROOT/pp-none.out" ] && ok "pending_paths_with_no_paths_prints_nothing_never_every_change" \
  || bad "pending_paths_with_no_paths_prints_nothing_never_every_change: rc=$rc [$(tr '\0' '|' < "$TMPROOT/pp-none.out")]"
c="$(mkrepo pend-clean)"; pending_paths "$c" README.md > "$TMPROOT/pp-clean.out"; rc=$?
[ "$rc" = 0 ] && [ ! -s "$TMPROOT/pp-clean.out" ] && ok "pending_paths_committed_path_prints_nothing" || bad "pending_paths_committed_path_prints_nothing: rc=$rc"
u="$TMPROOT/ritual fixtures/pend unborn"; mkdir -p "$u"; git -C "$u" init -q; echo a > "$u/a b.txt"
[ "$(pp "$u" "a b.txt")" = "a b.txt" ] && ok "pending_paths_on_an_unborn_branch_lists_the_untracked_file" || bad "pending_paths unborn: [$(pp "$u" "a b.txt")]"
mkdir -p "$TMPROOT/pend not a repo"
pending_paths "$TMPROOT/pend not a repo" x > "$TMPROOT/pp-ng.out" 2>/dev/null; rc=$?
[ "$rc" != 0 ] && [ ! -s "$TMPROOT/pp-ng.out" ] && ok "pending_paths_fails_when_git_cannot_answer" || bad "pending_paths_fails_when_git_cannot_answer: rc=$rc"

echo "== tests/lib.sh helpers =="
[ -d "$TMPROOT" ] && ok "TMPROOT exists" || bad "no TMPROOT"
a="$(mkrepo x)"; b="$(mkrepo x)"
[ "$a" != "$b" ] && [ "$(git -C "$a" rev-list --count HEAD)" = 1 ] && ok "mkrepo: unique paths, one commit" || bad "mkrepo uniqueness"
mkdir "$TMPROOT/stubs"; printf '#!/usr/bin/env bash\necho STUB\n' > "$TMPROOT/stubs/fakegh"; chmod +x "$TMPROOT/stubs/fakegh"
[ "$( stub_path "$TMPROOT/stubs"; fakegh )" = STUB ] && ok "stub_path makes a stub runnable" || bad "stub_path"
command -v fakegh >/dev/null 2>&1 && bad "stub_path leaked (subshell test)" || ok "stub_path in a subshell does not leak"
[ "$( stub_path "$TMPROOT/stubs"; PATH="$(path_without fakegh)"; command -v fakegh || echo GONE )" = GONE ] \
  && ok "path_without removes the dir holding a tool" || bad "path_without"
[ "$(path_without definitely-not-a-tool-xyz)" = "$PATH" ] && ok "path_without an absent tool leaves PATH unchanged" || bad "path_without absent"
[ "$(PATH="/usr/bin::/bin:*:" path_without definitely-not-a-tool-xyz)" = "/usr/bin::/bin:*:" ] \
  && ok "path_without keeps empty segments and glob chars byte-identical" || bad "path_without mangled PATH"

finish
