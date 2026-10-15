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
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = "[]" ] \
  && cmp -s "$r/.gitignore" "$TMPROOT/gi.before" && cmp -s "$r/.gitattributes" "$TMPROOT/ga.before" \
  && ok "traps_fix_rerun_already" || bad "rerun: $out"

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
[ "$(grep -c $'\r$' "$r/.gitignore")" = 4 ] && [ "$(wc -l < "$r/.gitignore")" = 4 ] \
  && ok "traps_crlf_file_stays_crlf" || bad "crlf: $(od -c "$r/.gitignore")"
R fix traps "$r" >/dev/null
[ "$(grep -c '^\.env' "$r/.gitignore")" = 1 ] && [ "$(grep -c '^\.semgrep/' "$r/.gitignore")" = 1 ] \
  && ok "traps_crlf_rerun_no_duplicates" || bad "crlf dup: $(od -c "$r/.gitignore")"

# --- missing trailing newline gets terminated, not glued
r="$(mkrepo)"; printf 'keepme' > "$r/.gitignore"
R fix traps "$r" >/dev/null
[ "$(sed -n 1p "$r/.gitignore")" = keepme ] && grep -qxF '.env' "$r/.gitignore" \
  && ok "traps_no_trailing_newline_not_glued" || bad "glued: $(od -c "$r/.gitignore")"

# --- committed CRLF x.sh is not renormalised
r="$(mkrepo)"; printf '#!/bin/sh\r\necho hi\r\n' > "$r/x.sh"; git -C "$r" add x.sh; git -C "$r" commit -qm sh
sh_before="$(sha256sum "$r/x.sh" | cut -d' ' -f1)"; blob_before="$(git -C "$r" rev-parse :x.sh)"
R fix traps "$r" >/dev/null
# Raw bytes and the index entry are untouched. (git itself, once eol=lf exists, may list x.sh as
# modified because the attribute now disagrees with the CRLF blob: that is git's view, not a write.)
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
[ "$(grep -c $'\r$' "$r/Cargo.toml")" = "$(wc -l < "$r/Cargo.toml")" ] && grep -q 'implicit_return' "$r/Cargo.toml" \
  && ok "clippy_crlf_cargo_stays_crlf" || bad "crlf cargo: $(od -c "$r/Cargo.toml" | head)"

# missing include -> unknown, nothing written
r="$(mkrepo)"; printf '%s' "$cargo_single" > "$r/Cargo.toml"; cp "$r/Cargo.toml" "$TMPROOT/cargo.before"
out="$(RITUAL_RUST_INCLUDE="$TMPROOT/nonexistent.md" PATH="$stubs:$PATH" R fix stack-checks "$r")"
[ "$(st "$out")" = unknown ] && cmp -s "$r/Cargo.toml" "$TMPROOT/cargo.before" \
  && ok "clippy_missing_include_is_unknown" || bad "no include: $out"

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
