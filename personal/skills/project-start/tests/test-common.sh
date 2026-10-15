#!/usr/bin/env bash
# Tests for lib/common.sh and the tests/lib.sh helpers later tasks depend on.
. "$(dirname "$0")/lib.sh"
. "$SKILL_DIR/lib/common.sh"

echo "== steps.json =="
sj="$(steps_json)"
[ -f "$sj" ] && ok "steps_json names an existing file" || bad "steps_json: $sj"
exp='preflight beads stack lessons traps stack-checks oracle public-sweep secret-scan workspace untracked-docs beads-seed beads-metrics ci baseline commit record'
[ "$(jq -r '.steps|map(.id)|join(" ")' "$sj")" = "$exp" ] && ok "17 step ids in spec order" || bad "ids: $(jq -r '.steps|map(.id)|join(" ")' "$sj")"
[ "$(jq -c '[.steps[].version]|unique' "$sj")" = '[1]' ] && [ "$(jq .ritual_version "$sj")" = 1 ] && ok "all versions 1, ritual_version 1" || bad "versions"
[ "$(jq -r '.steps[]|select(.id=="stack-checks")|.kind' "$sj")" = ask ] && [ "$(jq -r '.steps[]|select(.id=="preflight")|.kind' "$sj")" = check ] \
  && [ "$(jq -r '.steps[]|select(.id=="oracle")|.kind' "$sj")" = auto ] && ok "kinds follow the spec table" || bad "kinds"
[ "$(RITUAL_STEPS_JSON=/x/y steps_json)" = /x/y ] && ok "RITUAL_STEPS_JSON overrides" || bad "override ignored"

echo "== emit =="
e="$(emit traps present "added 2 lines" .gitignore .gitattributes)"
[ "$(printf '%s' "$e" | jq -c .)" = '{"id":"traps","status":"present","detail":"added 2 lines","wrote":[".gitignore",".gitattributes"]}' ] \
  && ok "emit with wrote paths" || bad "emit: $e"
[ "$(emit oracle unknown "no tool" | jq -c .wrote)" = '[]' ] && ok "emit with no wrote gives []" || bad "emit empty wrote"
[ "$(emit x absent 'a "quoted" b' | jq -r .detail)" = 'a "quoted" b' ] && ok "emit escapes quotes" || bad "emit quoting"

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

finish
