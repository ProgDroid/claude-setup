#!/usr/bin/env bash
# Tests: check public-sweep, check ci, candidates.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# mkgh <dir> <stdout> <exit>: a stub gh that prints <stdout> and exits <exit>
mkgh() {
  mkdir -p "$1"
  printf '#!/usr/bin/env bash\nprintf "%%s\n" "%s"\nexit %s\n' "$2" "$3" > "$1/gh"
  chmod +x "$1/gh"
}
sweep() { (stub_path "$STUB"; bash "$RITUAL" check public-sweep "$1"); }
st() { jq -r '.status' <<<"$1"; }

r="$(mkrepo)"
STUB="$TMPROOT/stub-public"; mkgh "$STUB" PUBLIC 0
out="$(sweep "$r")"; [ "$(st "$out")" = present ] && [ "$(jq -r .id <<<"$out")" = public-sweep ] && ok "public_present" || bad "public_present: $out"
STUB="$TMPROOT/stub-private"; mkgh "$STUB" PRIVATE 0
out="$(sweep "$r")"; [ "$(st "$out")" = absent ] && ok "private_absent" || bad "private_absent: $out"
STUB="$TMPROOT/stub-internal"; mkgh "$STUB" INTERNAL 0
out="$(sweep "$r")"; [ "$(st "$out")" = absent ] && ok "internal_absent" || bad "internal_absent: $out"
STUB="$TMPROOT/stub-err"; mkgh "$STUB" "" 1
out="$(sweep "$r")"; [ "$(st "$out")" = unknown ] && ok "gh_error_unknown" || bad "gh_error_unknown: $out"
STUB="$TMPROOT/stub-err-public"; mkgh "$STUB" PUBLIC 1
out="$(sweep "$r")"; [ "$(st "$out")" = unknown ] && ok "gh_nonzero_with_public_text_unknown" || bad "gh_nonzero_public: $out"
STUB="$TMPROOT/stub-empty"; mkgh "$STUB" "" 0
out="$(sweep "$r")"; [ "$(st "$out")" = unknown ] && ok "gh_empty_output_unknown" || bad "gh_empty: $out"
STUB="$TMPROOT/stub-weird"; mkgh "$STUB" "SOMETHING" 0
out="$(sweep "$r")"; [ "$(st "$out")" = unknown ] && ok "gh_unknown_value_unknown" || bad "gh_weird: $out"
out="$(PATH="$(path_without gh)" bash "$RITUAL" check public-sweep "$r")"
[ "$(st "$out")" = unknown ] && ok "gh_missing_unknown" || bad "gh_missing_unknown: $out"
# gh must run from inside the repo
mkdir -p "$TMPROOT/stub-pwd"
printf '#!/usr/bin/env bash\ncase "$PWD" in *"ritual fixtures"*) echo PUBLIC;; *) echo PRIVATE;; esac\n' > "$TMPROOT/stub-pwd/gh"; chmod +x "$TMPROOT/stub-pwd/gh"
out="$(cd "$TMPROOT" && stub_path "$TMPROOT/stub-pwd" && bash "$RITUAL" check public-sweep "$r")"
[ "$(st "$out")" = present ] && ok "gh_runs_inside_repo" || bad "gh_runs_inside_repo: $out"

# --- ci
r="$(mkrepo)"
out="$(bash "$RITUAL" check ci "$r")"; [ "$(st "$out")" = absent ] && [ "$(jq -r .id <<<"$out")" = ci ] && ok "ci_absent" || bad "ci_absent: $out"
mkdir -p "$r/.github/workflows"; echo x > "$r/.github/workflows/readme.txt"
out="$(bash "$RITUAL" check ci "$r")"; [ "$(st "$out")" = absent ] && ok "ci_non_yaml_absent" || bad "ci_non_yaml: $out"
echo "on: push" > "$r/.github/workflows/ci.yml"
out="$(bash "$RITUAL" check ci "$r")"; [ "$(st "$out")" = present ] && ok "ci_present_yml" || bad "ci_present_yml: $out"
r="$(mkrepo)"; mkdir -p "$r/.github/workflows"; echo "on: push" > "$r/.github/workflows/b.yaml"
out="$(bash "$RITUAL" check ci "$r")"; [ "$(st "$out")" = present ] && ok "ci_present_yaml" || bad "ci_present_yaml: $out"

# --- candidates
cand() { bash "$RITUAL" candidates "$1"; }
r="$(mkrepo)"
out="$(cand "$r")"; [ "$out" = '{"items":[]}' ] || [ "$(jq -c . <<<"$out")" = '{"items":[]}' ] && ok "candidates_empty" || bad "candidates_empty: $out"

r="$(mkrepo)"
mkdir -p "$r/docs/superpowers/plans" "$r/src"
printf '# Plan\n- [x] done thing\n- [ ] write the parser\n' > "$r/docs/superpowers/plans/p.md"
printf 'int x;\n// TODO: handle overflow\n' > "$r/src/a.c"
git -C "$r" add -A; git -C "$r" commit -q -m c
out="$(cand "$r")"
want='{"items":[{"text":"write the parser","source":"docs/superpowers/plans/p.md:3"},{"text":"handle overflow","source":"src/a.c:2"}]}'
[ "$(jq -c . <<<"$out")" = "$want" ] && ok "candidates_from_plan_and_todo" || bad "candidates_from_plan_and_todo: $out"

echo '// TODO: untracked thing' > "$r/untracked.c"
mkdir -p "$r/docs/plans"; echo '- [ ] untracked plan item' > "$r/docs/plans/u.md"
out="$(cand "$r")"
[ "$(jq -c . <<<"$out")" = "$want" ] && ok "candidates_skip_untracked" || bad "candidates_skip_untracked: $out"
echo 'ign.c' > "$r/.gitignore"; echo '// FIXME ignored' > "$r/ign.c"
out="$(cand "$r")"; [ "$(jq -c . <<<"$out")" = "$want" ] && ok "candidates_skip_ignored" || bad "candidates_skip_ignored: $out"

# FIXME without colon, trimming, spaced path, deeper plans dir, dedupe, Open section
r="$(mkrepo)"
mkdir -p "$r/docs/a/b/plans" "$r/my dir"
printf -- '- [ ] shared item\n  - [ ]   nested item  \n' > "$r/docs/a/b/plans/x.md"
printf '# x FIXME   spaced   \n' > "$r/my dir/f.txt"
printf '# Notes\n- not open\n## Open questions\n- first open\n* second open\n- [ ] shared item\n- [x] closed one\n\ntext line\n## Done\n- not this\n' > "$r/docs/n.md"
git -C "$r" add -A; git -C "$r" commit -q -m c
out="$(cand "$r")"
# order is by source path then line: docs/a/b/plans/x.md sorts before docs/n.md
want='{"items":[{"text":"shared item","source":"docs/a/b/plans/x.md:1"},{"text":"nested item","source":"docs/a/b/plans/x.md:2"},{"text":"first open","source":"docs/n.md:4"},{"text":"second open","source":"docs/n.md:5"},{"text":"spaced","source":"my dir/f.txt:1"}]}'
[ "$(jq -c . <<<"$out")" = "$want" ] && ok "candidates_open_sections_dedupe_order_spaces" || bad "candidates_mix: $out"

# cap at 50
r="$(mkrepo)"
for i in $(seq 1 60); do echo "// TODO item $i"; done > "$r/many.c"
git -C "$r" add -A; git -C "$r" commit -q -m c
out="$(cand "$r")"
[ "$(jq '.items|length' <<<"$out")" = 50 ] && [ "$(jq -r '.items[0].text' <<<"$out")" = "item 1" ] && ok "candidates_cap_50" || bad "candidates_cap: $(jq '.items|length' <<<"$out")"

# binary files skipped
r="$(mkrepo)"; printf 'TODO bin\0\0data' > "$r/b.bin"; git -C "$r" add -A; git -C "$r" commit -q -m c
out="$(cand "$r")"; [ "$(jq '.items|length' <<<"$out")" = 0 ] && ok "candidates_skip_binary" || bad "candidates_binary: $out"

# non-repo
bash "$RITUAL" candidates "$TMPROOT" >/dev/null 2>&1; [ $? -eq 2 ] && ok "candidates_requires_repo" || bad "candidates_requires_repo"
finish
