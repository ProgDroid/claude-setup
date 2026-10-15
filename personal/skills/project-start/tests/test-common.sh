#!/usr/bin/env bash
# Tests for lib/common.sh and the tests/lib.sh helpers later tasks depend on.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/lib/common.sh"

echo "== steps.json =="
sj="$(steps_json)"
[ -f "$sj" ] && ok "steps_json names an existing file" || bad "steps_json: $sj"
exp='preflight beads stack lessons traps stack-checks oracle public-sweep secret-scan workspace untracked-docs parking-lot beads-seed beads-metrics ci baseline commit record'
[ "$(jq -r '.steps|map(.id)|join(" ")' "$sj")" = "$exp" ] && ok "18 step ids in spec order" || bad "ids: $(jq -r '.steps|map(.id)|join(" ")' "$sj")"
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

echo "== git_common_dir =="
repo="$(mkrepo)"
g="$(git_common_dir "$repo")"
[ -d "$g" ] && [ "$(basename "$g")" = .git ] && ok "git_common_dir is the absolute .git of a spaced repo" || bad "git_common_dir: $g"

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
