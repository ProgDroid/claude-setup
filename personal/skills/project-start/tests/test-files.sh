#!/usr/bin/env bash
# Tests: traps (.gitattributes/.gitignore lines) and stack-checks (clippy policy).
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export RITUAL_RUST_INCLUDE="$TESTS_DIR/fixtures/rust-include.md"
R() { bash "$RITUAL" "$@"; }
st() { jq -r .status <<<"$1"; }

# --- traps: fix then check, rerun is a no-op
r="$(mkrepo)"
out="$(R check traps "$r")"
[ "$(st "$out")" = absent ] && ok "traps_check_absent_on_fresh_repo" || bad "fresh: $out"
out="$(R fix traps "$r")"
[ "$(st "$out")" = fixed ] && [ "$(jq -c '.wrote|sort' <<<"$out")" = '[".gitattributes",".gitignore"]' ] \
  && ok "traps_fix_reports_fixed_and_wrote" || bad "fix: $out"
out="$(R check traps "$r")"
[ "$(st "$out")" = present ] && ok "traps_fix_then_check_present" || bad "after fix: $out"
cp "$r/.gitignore" "$TMPROOT/gi.before"; cp "$r/.gitattributes" "$TMPROOT/ga.before"
out="$(R fix traps "$r")"
[ "$(st "$out")" = already ] \
  && cmp -s "$r/.gitignore" "$TMPROOT/gi.before" && cmp -s "$r/.gitattributes" "$TMPROOT/ga.before" \
  && ok "traps_fix_rerun_already" || bad "rerun: $out"
# I1: the first fix was never committed, so the rerun lists both files again
[ "$(jq -c '.wrote|sort' <<<"$out")" = '[".gitattributes",".gitignore"]' ] && jq -r .detail <<<"$out" | grep -qF 'not yet committed' \
  && ok "traps_rerun_lists_the_uncommitted_files" || bad "traps rerun wrote: $out"
git -C "$r" add .gitattributes .gitignore && git -C "$r" commit -q -m traps
out="$(R fix traps "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = "[]" ] && ok "traps_rerun_after_the_commit_lists_nothing" || bad "traps after commit: $out"

# --- global ignore must not count
r="$(mkrepo)"; printf '*.sh text eol=lf\n' > "$r/.gitattributes"   # attr in place: only the ignores can make check absent
printf '.semgrep/\n.env\n' > "$TMPROOT/global-ignore"
printf '[core]\n\texcludesFile = "%s"\n' "$(cygpath -m "$TMPROOT/global-ignore" 2>/dev/null || echo "$TMPROOT/global-ignore")" > "$TMPROOT/global-gitconfig"
out="$(GIT_CONFIG_GLOBAL="$TMPROOT/global-gitconfig" R check traps "$r")"
[ "$(st "$out")" = absent ] && ok "traps_global_ignore_not_counted" || bad "global: $out"
# control: the fake global really does ignore the paths when not overridden
GIT_CONFIG_GLOBAL="$TMPROOT/global-gitconfig" git -C "$r" check-ignore -q .env \
  && ok "traps_global_ignore_control_is_live" || bad "control: fake global ignore inert"
out="$(GIT_CONFIG_GLOBAL="$TMPROOT/global-gitconfig" R fix traps "$r")"
grep -qxF '.env' "$r/.gitignore" && grep -qxF '.semgrep/' "$r/.gitignore" \
  && ok "traps_fix_writes_despite_global_ignore" || bad "fix w/ global: $out"

# --- partial: only .env ignored
r="$(mkrepo)"; printf '*.sh text eol=lf\n' > "$r/.gitattributes"; printf '.env\n' > "$r/.gitignore"
out="$(R check traps "$r")"
[ "$(st "$out")" = absent ] && jq -r .detail <<<"$out" | grep -qF '.semgrep/' \
  && ! jq -r .detail <<<"$out" | grep -qF '.env' && ok "traps_partial_is_absent" || bad "partial: $out"
R fix traps "$r" >/dev/null
[ "$(printf '.env\n.semgrep/\n')" = "$(cat "$r/.gitignore")" ] && ok "traps_fix_appends_only_missing" || bad "append missing: $(cat "$r/.gitignore")"

# --- CRLF .gitignore stays CRLF
r="$(mkrepo)"; printf 'target/\r\nnode_modules/\r\n' > "$r/.gitignore"
R fix traps "$r" >/dev/null
printf 'target/\r\nnode_modules/\r\n.semgrep/\r\n.env\r\n' > "$TMPROOT/want.crlf"
cmp -s "$TMPROOT/want.crlf" "$r/.gitignore" \
  && ok "traps_crlf_file_stays_crlf" || bad "crlf: $(od -c "$r/.gitignore")"
R fix traps "$r" >/dev/null
cmp -s "$TMPROOT/want.crlf" "$r/.gitignore" \
  && ok "traps_crlf_rerun_no_duplicates" || bad "crlf dup: $(od -c "$r/.gitignore")"

# --- CRLF with an UNTERMINATED last line: terminated with CRLF, not LF
r="$(mkrepo)"; printf 'a\r\nb' > "$r/.gitignore"
R fix traps "$r" >/dev/null
printf 'a\r\nb\r\n.semgrep/\r\n.env\r\n' > "$TMPROOT/want.crlf"
cmp -s "$TMPROOT/want.crlf" "$r/.gitignore" \
  && ok "traps_crlf_unterminated_last_line_gets_crlf" || bad "crlf unterminated: $(od -c "$r/.gitignore")"

# --- eol_of directly, on exact bytes
( . "$SKILL_DIR/lib/common.sh"
  printf 'a\r\nb\r\n' > "$TMPROOT/e1"; printf 'a\nb\n' > "$TMPROOT/e2"; : > "$TMPROOT/e3"; printf 'a' > "$TMPROOT/e4"
  printf 'a\r' > "$TMPROOT/e5"   # a CR with no LF after it is not a CRLF line ending
  [ "$(eol_of "$TMPROOT/e1")" = crlf ] && [ "$(eol_of "$TMPROOT/e2")" = lf ] && [ "$(eol_of "$TMPROOT/e3")" = lf ] \
    && [ "$(eol_of "$TMPROOT/e4")" = lf ] && [ "$(eol_of "$TMPROOT/e5")" = lf ] && [ "$(eol_of "$TMPROOT/missing")" = lf ] ) \
  && ok "eol_of_detects_crlf_by_bytes" || bad "eol_of"

# --- missing trailing newline gets terminated, not glued
r="$(mkrepo)"; printf 'keepme' > "$r/.gitignore"
R fix traps "$r" >/dev/null
[ "$(sed -n 1p "$r/.gitignore")" = keepme ] && grep -qxF '.env' "$r/.gitignore" \
  && ok "traps_no_trailing_newline_not_glued" || bad "glued: $(od -c "$r/.gitignore")"

# --- committed CRLF x.sh is not renormalised
r="$(mkrepo)"; printf '#!/bin/sh\r\necho hi\r\n' > "$r/x.sh"; git -C "$r" add x.sh; git -C "$r" commit -qm sh
sh_before="$(sha256sum "$r/x.sh" | cut -d' ' -f1)"; blob_before="$(git -C "$r" rev-parse :x.sh)"
out="$(R fix traps "$r")"
# Raw bytes and the index entry are untouched. Git itself, once eol=lf exists, lists x.sh as
# modified (the attribute disagrees with the CRLF blob); the fix must REPORT that, not hide it.
[ "$(st "$out")" = fixed ] && jq -r .detail <<<"$out" | grep -qF 'x.sh' \
  && jq -r .detail <<<"$out" | grep -qF 'not renormalised' \
  && ok "traps_reports_files_now_showing_modified" || bad "modified report: $out"
r2="$(mkrepo)"; out="$(R fix traps "$r2")"
! jq -r .detail <<<"$out" | grep -qF 'modified' && ok "traps_no_modified_report_when_none" || bad "spurious report: $out"
[ "$(sha256sum "$r/x.sh" | cut -d' ' -f1)" = "$sh_before" ] && [ "$(git -C "$r" rev-parse :x.sh)" = "$blob_before" ] \
  && cmp -s <(printf '#!/bin/sh\r\necho hi\r\n') "$r/x.sh" \
  && ok "traps_no_renormalise" || bad "x.sh changed"

# --- existing user lines preserved in order
r="$(mkrepo)"; printf 'alpha\nbeta/\n*.gamma\n' > "$r/.gitignore"
R fix traps "$r" >/dev/null
[ "$(head -n 3 "$r/.gitignore")" = "$(printf 'alpha\nbeta/\n*.gamma')" ] && ok "traps_preserves_existing" || bad "preserve: $(cat "$r/.gitignore")"

# --- non-repo dies with exit 2
R check traps "$TMPROOT/not-a-repo" >/dev/null 2>&1; [ $? -eq 2 ] && ok "traps_non_repo_dies" || bad "non-repo"

# ---------------- stack-checks ----------------
cargo_single='[package]
name = "a"
version = "0.1.0"
'
r="$(mkrepo)"; printf '%s' "$cargo_single" > "$r/Cargo.toml"
out="$(R check stack-checks "$r")"
[ "$(st "$out")" = absent ] && jq -r .detail <<<"$out" | grep -qF 'Cargo.toml' && ok "clippy_missing_is_absent" || bad "missing: $out"

# fix appends canonical (stub cargo succeeds)
stubs="$TMPROOT/stubs-ok"; mkdir -p "$stubs"
printf '#!/bin/sh\nexit 0\n' > "$stubs/cargo"; chmod +x "$stubs/cargo"
cp "$r/Cargo.toml" "$TMPROOT/cargo.before"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
n=$(wc -c < "$TMPROOT/cargo.before")
[ "$(st "$out")" = fixed ] && [ "$(jq -c .wrote <<<"$out")" = '["Cargo.toml"]' ] \
  && cmp -s <(head -c "$n" "$r/Cargo.toml") "$TMPROOT/cargo.before" \
  && grep -qxF '[lints.clippy]' "$r/Cargo.toml" && grep -qxF 'implicit_return = "allow"' "$r/Cargo.toml" \
  && ! grep -q 'trailing prose' "$r/Cargo.toml" && ! grep -q '```' "$r/Cargo.toml" \
  && ok "clippy_missing_fix_appends_canonical" || bad "append: $out / $(cat "$r/Cargo.toml")"
[ "$(st "$(R check stack-checks "$r")")" = present ] && ok "clippy_after_fix_present" || bad "after fix not present"
cp "$r/Cargo.toml" "$TMPROOT/cargo.fixed"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = already ] && cmp -s "$r/Cargo.toml" "$TMPROOT/cargo.fixed" \
  && ok "clippy_fix_rerun_already" || bad "rerun: $out"
[ "$(jq -c .wrote <<<"$out")" = '["Cargo.toml"]' ] && jq -r .detail <<<"$out" | grep -qF 'not yet committed' \
  && ok "clippy_rerun_lists_the_uncommitted_manifest" || bad "clippy rerun wrote: $out"
git -C "$r" add Cargo.toml && git -C "$r" commit -q -m clippy
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && ok "clippy_rerun_after_the_commit_lists_nothing" || bad "clippy after commit: $out"

# cargo metadata failure reverts
r="$(mkrepo)"; printf '%s' "$cargo_single" > "$r/Cargo.toml"; cp "$r/Cargo.toml" "$TMPROOT/cargo.before"
stubs="$TMPROOT/stubs-fail"; mkdir -p "$stubs"
printf '#!/bin/sh\n[ "$1" = metadata ] && exit 101\nexit 0\n' > "$stubs/cargo"; chmod +x "$stubs/cargo"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = failed ] && [ "$(jq -c .wrote <<<"$out")" = "[]" ] && cmp -s "$r/Cargo.toml" "$TMPROOT/cargo.before" \
  && ok "clippy_fix_reverts_on_cargo_failure" || bad "revert: $out"

# no cargo at all -> unknown + reverted
out="$(PATH="$(path_without cargo)" R fix stack-checks "$r")"
if PATH="$(path_without cargo)" command -v cargo >/dev/null 2>&1; then
  bad "clippy_no_cargo_is_unknown: cargo still on PATH (control)"
else
  [ "$(st "$out")" = unknown ] && cmp -s "$r/Cargo.toml" "$TMPROOT/cargo.before" \
    && ok "clippy_no_cargo_is_unknown_and_reverted" || bad "no cargo: $out"
fi

# workspace forms
r="$(mkrepo)"
printf '[workspace]\nmembers = ["a"]\n\n[workspace.lints.clippy]\nall = "warn"\n' > "$r/Cargo.toml"
[ "$(st "$(R check stack-checks "$r")")" = present ] && ok "clippy_workspace_form_is_present" || bad "ws form"

stubs="$TMPROOT/stubs-ok"
r="$(mkrepo)"; printf '[workspace]\nmembers = ["server"]\nresolver = "2"\n' > "$r/Cargo.toml"
cp "$r/Cargo.toml" "$TMPROOT/cargo.before"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = absent ] && jq -r .detail <<<"$out" | grep -qF 'workspace: needs ask' \
  && cmp -s "$r/Cargo.toml" "$TMPROOT/cargo.before" && [ "$(jq -c .wrote <<<"$out")" = "[]" ] \
  && ok "clippy_virtual_workspace_not_auto" || bad "virtual ws: $out"

# R14: root workspace -> NOTHING written, members included
r="$(mkrepo)"; mkdir "$r/m"; printf '[workspace]\nmembers = ["m"]\n' > "$r/Cargo.toml"
printf '[package]\nname = "m"\n' > "$r/m/Cargo.toml"
cp "$r/Cargo.toml" "$TMPROOT/ws.root"; cp "$r/m/Cargo.toml" "$TMPROOT/ws.m"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = absent ] && [ "$(jq -c .wrote <<<"$out")" = "[]" ] && jq -r .detail <<<"$out" | grep -qF 'workspace: needs ask' \
  && cmp -s "$r/Cargo.toml" "$TMPROOT/ws.root" && cmp -s "$r/m/Cargo.toml" "$TMPROOT/ws.m" \
  && ok "clippy_workspace_writes_nothing_incl_members" || bad "ws members: $out"
# glob member
rm -rf "$r/m"; mkdir -p "$r/crates/c"; printf '[workspace]\nmembers = [\n  "crates/*",\n]\n' > "$r/Cargo.toml"
printf '[package]\nname = "c"\n' > "$r/crates/c/Cargo.toml"; cp "$r/crates/c/Cargo.toml" "$TMPROOT/ws.m"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(jq -c .wrote <<<"$out")" = "[]" ] && cmp -s "$r/crates/c/Cargo.toml" "$TMPROOT/ws.m" \
  && ok "clippy_workspace_glob_member_untouched" || bad "ws glob: $out"
# independent crate that is NOT a member may still be fixed
mkdir "$r/other"; printf '[package]\nname = "o"\n' > "$r/other/Cargo.toml"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(jq -c .wrote <<<"$out")" = '["other/Cargo.toml"]' ] \
  && ! grep -q 'lints.clippy' "$r/Cargo.toml" && grep -qxF '[lints.clippy]' "$r/other/Cargo.toml" && cmp -s "$r/crates/c/Cargo.toml" "$TMPROOT/ws.m" \
  && ok "clippy_nonmember_crate_beside_workspace_fixed" || bad "non-member: $out"

# R15: Cargo.lock written by cargo metadata is not left behind / is restored byte-identical
lockstub="$TMPROOT/stubs-lock"; mkdir -p "$lockstub"
printf '#!/bin/sh\nprintf "# changed by cargo\\n" > Cargo.lock\nexit 0\n' > "$lockstub/cargo"; chmod +x "$lockstub/cargo"
r="$(mkrepo)"; printf '%s' "$cargo_single" > "$r/Cargo.toml"
out="$(PATH="$lockstub:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = fixed ] && [ ! -e "$r/Cargo.lock" ] && ok "clippy_new_cargo_lock_removed" || bad "lock created: $out"
r="$(mkrepo)"; printf '%s' "$cargo_single" > "$r/Cargo.toml"; printf '# original lock\n' > "$r/Cargo.lock"
out="$(PATH="$lockstub:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = fixed ] && [ "$(cat "$r/Cargo.lock")" = "# original lock" ] && ok "clippy_existing_cargo_lock_restored" || bad "lock changed: $out"

# package + workspace (non-virtual) root is also ask
r="$(mkrepo)"; printf '[package]\nname="a"\n\n[workspace]\nmembers=["b"]\n' > "$r/Cargo.toml"
cp "$r/Cargo.toml" "$TMPROOT/cargo.before"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = absent ] && cmp -s "$r/Cargo.toml" "$TMPROOT/cargo.before" \
  && ok "clippy_package_plus_workspace_not_auto" || bad "pkg+ws: $out"

# member crate with [lints] workspace = true counts as covered
r="$(mkrepo)"; mkdir "$r/server"; printf '[package]\nname="s"\n\n[lints]\nworkspace = true\n' > "$r/server/Cargo.toml"
[ "$(st "$(R check stack-checks "$r")")" = present ] && ok "clippy_member_lints_workspace_true_present" || bad "member"

# nested crate (server/) fixed in place
r="$(mkrepo)"; mkdir "$r/server"; printf '%s' "$cargo_single" > "$r/server/Cargo.toml"
out="$(PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(jq -c .wrote <<<"$out")" = '["server/Cargo.toml"]' ] && grep -qxF '[lints.clippy]' "$r/server/Cargo.toml" \
  && ok "clippy_nested_crate_fixed" || bad "nested: $out"

# CRLF Cargo.toml stays CRLF
r="$(mkrepo)"; printf '[package]\r\nname = "a"\r\n' > "$r/Cargo.toml"
PATH="$stubs:$PATH" R fix stack-checks "$r" >/dev/null
printf '[package]\r\nname = "a"\r\n\r\n[lints.clippy]\r\nall = { level = "warn", priority = -1 }\r\npedantic = { level = "warn", priority = -1 }\r\nimplicit_return = "allow"\r\n' > "$TMPROOT/want.cargo.crlf"
cmp -s "$TMPROOT/want.cargo.crlf" "$r/Cargo.toml" \
  && ok "clippy_crlf_cargo_stays_crlf" || bad "crlf cargo: $(od -c "$r/Cargo.toml" | head)"

# missing include -> unknown, nothing written
r="$(mkrepo)"; printf '%s' "$cargo_single" > "$r/Cargo.toml"; cp "$r/Cargo.toml" "$TMPROOT/cargo.before"
out="$(RITUAL_RUST_INCLUDE="$TMPROOT/nonexistent.md" PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = unknown ] && cmp -s "$r/Cargo.toml" "$TMPROOT/cargo.before" \
  && ok "clippy_missing_include_is_unknown" || bad "no include: $out"

# default include path (no RITUAL_RUST_INCLUDE): every test above injects a fixture, which is how
# the dependency on the real rust-standards skill file went unseen. The fixture HOME holds a copy
# of the worktree's REAL core/skills/rust-standards/SKILL.md.
REAL_RUST_SKILL="$SKILL_DIR/../../../core/skills/rust-standards/SKILL.md"
fxhome="$TMPROOT/fx home"; rel_skill=".claude/plugins/marketplaces/progdroid/core/skills/rust-standards/SKILL.md"
mkdir -p "$fxhome/$(dirname "$rel_skill")"; cp "$REAL_RUST_SKILL" "$fxhome/$rel_skill"
tbl="$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/files.sh"; unset RITUAL_RUST_INCLUDE; HOME="$fxhome" _clippy_table )"
[ -n "$tbl" ] && [ "$(printf '%s\n' "$tbl" | head -n 1)" = '[lints.clippy]' ] && printf '%s\n' "$tbl" | grep -qx 'pedantic = { level = "warn", priority = -1 }' \
  && ok "clippy_table_default_path_reads_core_rust_standards" || bad "default path table: [$tbl]"
r="$(mkrepo)"; printf '%s' "$cargo_single" > "$r/Cargo.toml"
out="$(unset RITUAL_RUST_INCLUDE; HOME="$fxhome" PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = fixed ] && grep -qxF '[lints.clippy]' "$r/Cargo.toml" && grep -qxF 'nursery = { level = "warn", priority = -1 }' "$r/Cargo.toml" \
  && ok "clippy_default_path_fix_appends_real_table" || bad "default path fix: $out"

# default path, file missing -> unknown naming the path it looked at, nothing written
nohome="$TMPROOT/no home"; mkdir -p "$nohome"
r="$(mkrepo)"; printf '%s' "$cargo_single" > "$r/Cargo.toml"; cp "$r/Cargo.toml" "$TMPROOT/cargo.before2"
out="$(unset RITUAL_RUST_INCLUDE; HOME="$nohome" PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = unknown ] && cmp -s "$r/Cargo.toml" "$TMPROOT/cargo.before2" \
  && jq -r .detail <<<"$out" | grep -qF "canonical clippy table not found at $nohome/$rel_skill" \
  && ok "clippy_missing_default_skill_is_unknown_naming_path" || bad "missing default: $out"

# python / flutter: never written
r="$(mkrepo)"; printf '[project]\nname="p"\n' > "$r/pyproject.toml"
cp "$r/pyproject.toml" "$TMPROOT/py.before"
out="$(R fix stack-checks "$r")"
[ "$(st "$out")" = absent ] && [ "$(jq -c .wrote <<<"$out")" = "[]" ] && [ ! -e "$r/ruff.toml" ] \
  && cmp -s "$r/pyproject.toml" "$TMPROOT/py.before" && ok "python_not_written_absent" || bad "python: $out"
printf '[tool.ruff]\nline-length = 100\n' >> "$r/pyproject.toml"
[ "$(st "$(R check stack-checks "$r")")" = present ] && ok "python_ruff_config_present" || bad "python ruff"
r="$(mkrepo)"; printf 'name: x\n' > "$r/pubspec.yaml"
out="$(R fix stack-checks "$r")"
[ "$(st "$out")" = absent ] && [ ! -e "$r/analysis_options.yaml" ] && ok "flutter_not_written_absent" || bad "flutter: $out"

# no applicable stack
r="$(mkrepo)"; [ "$(st "$(R check stack-checks "$r")")" = present ] && ok "stack_checks_no_stack_present" || bad "no stack"

finish
