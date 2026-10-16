#!/usr/bin/env bash
# Tests: secret-scan step (check secret-scan, fix secret-scan) against stub and real gitleaks.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The proof key is an AWS-access-key-shaped string that is NOT the documentation example (gitleaks
# allowlists that one). It is assembled at runtime: a contiguous literal in this public repo would
# be flagged by secret scanners on the repo itself.
KEY="AKIA""Q7RZ3MXL2KTD5VNW"

# --- stub gitleaks: DET flags any staged AWS-style key (as the real rule does), PASSIVE never flags.
DET="$TMPROOT/stub detect"; PASSIVE="$TMPROOT/stub passive"; EMPTY_LA="$TMPROOT/empty localappdata"
mkdir -p "$DET" "$PASSIVE" "$EMPTY_LA"
cat > "$DET/gitleaks" <<'STUB'
#!/usr/bin/env bash
if git diff --cached | grep -qE 'AKIA[A-Z2-7]{16}'; then echo "WRN leaks found: 1" >&2; exit 1; fi
echo "INF no leaks found" >&2; exit 0
STUB
cat > "$PASSIVE/gitleaks" <<'STUB'
#!/usr/bin/env bash
echo "INF no leaks found" >&2; exit 0
STUB
chmod +x "$DET/gitleaks" "$PASSIVE/gitleaks"

NOGL="$(path_without gitleaks)"
# runners: D = detecting stub first on PATH, P = passive stub, N = no gitleaks by either route
D() { ( stub_path "$DET"; bash "$RITUAL" "$@" ); }
P() { ( stub_path "$PASSIVE"; bash "$RITUAL" "$@" ); }
N() { ( PATH="$NOGL"; LOCALAPPDATA="$(cygpath -w "$EMPTY_LA")"; export PATH LOCALAPPDATA; bash "$RITUAL" "$@" ); }

st() { jq -r .status <<<"$1"; }
dt() { jq -r .detail <<<"$1"; }
crs() { tr -cd '\r' < "$1" | wc -c | tr -d ' '; }
lfs() { tr -cd '\n' < "$1" | wc -c | tr -d ' '; }

BEGIN_BD='# --- BEGIN BEADS INTEGRATION v1.2.2 ---'
# bd_shim <file> [crlf]: bd 1.2.2's pre-commit shape (shebang, marked block), plus one user line
# after it. The SHIM_* variables let a test make the shim stage or modify files when it runs.
bd_shim() {
  local e='\n'; [ "${2:-}" = crlf ] && e='\r\n'
  printf "%s$e" '#!/usr/bin/env sh' "$BEGIN_BD" \
    '# This section is managed by beads. Do not remove these markers.' \
    'if [ -n "${SHIM_LOG:-}" ]; then echo shim-ran >> "$SHIM_LOG"; fi' \
    'if [ -n "${SHIM_STAGE:-}" ]; then git add -- "$SHIM_STAGE"; fi' \
    'if [ -n "${SHIM_TOUCH:-}" ]; then echo touched >> "$SHIM_TOUCH"; fi' \
    '# --- END BEADS INTEGRATION v1.2.2 ---' 'true # user line after the bd block' > "$1"
  chmod +x "$1"
}
# bd_repo [crlf] -> a repo with a tracked .beads/hooks/pre-commit shim and core.hooksPath=.beads/hooks
bd_repo() {
  local r; r="$(mkrepo bd)"
  mkdir -p "$r/.beads/hooks"; bd_shim "$r/.beads/hooks/pre-commit" "${1:-}"
  printf '{"id":"x-1"}\n' > "$r/.beads/issues.jsonl"
  git -C "$r" add .beads; git -C "$r" commit -q -m 'bd init'
  git -C "$r" config core.hooksPath .beads/hooks
  printf '%s\n' "$r"
}
nmark() { tr -d '\r' < "$1" | grep -cx "$2"; }
proof_leftovers() { find "$1" -maxdepth 1 -name '.ritual-secret-scan-proof*' | wc -l | tr -d ' '; }

echo "== source hygiene =="
# no_contiguous_key_in_source: the grep must be able to find a key (control), and find none here.
printf 'aws_access_key_id = %s\n' "$KEY" > "$TMPROOT/control.txt"
ctl="$(grep -cE 'AKIA[A-Z2-7]{16}' "$TMPROOT/control.txt")"
hits="$(grep -rEl 'AKIA[A-Z2-7]{16}' "$SKILL_DIR" | wc -l | tr -d ' ')"
[ "$ctl" = 1 ] && [ "$hits" = 0 ] && ok "no_contiguous_key_in_source" \
  || bad "no_contiguous_key_in_source: control=$ctl hits=$hits ($(grep -rEl 'AKIA[A-Z2-7]{16}' "$SKILL_DIR"))"

echo "== check: unknown =="
r="$(bd_repo)"
out="$(N check secret-scan "$r")"
[ "$(st "$out")" = unknown ] && [[ "$(dt "$out")" == *gitleaks* ]] && ok "unknown_without_gitleaks_no_block" \
  || bad "unknown_without_gitleaks_no_block: $out"
D fix secret-scan "$r" >/dev/null; p0="$(git -C "$r" status --porcelain)"
out="$(N check secret-scan "$r")"
[ "$(st "$out")" = unknown ] && [[ "$(dt "$out")" == *gitleaks* ]] && ok "unknown_without_gitleaks" \
  || bad "unknown_without_gitleaks: $out"
[ "$(git -C "$r" status --porcelain)" = "$p0" ] && ok "unknown_leaves_tree_as_it_was" || bad "unknown changed: $(git -C "$r" status --porcelain)"

# unknown_when_git_hook_run_missing: a git without `git hook run` (pre-2.36) cannot run the proof.
REALGIT="$(command -v git)"; OLDGIT="$TMPROOT/old git"; mkdir -p "$OLDGIT"
cat > "$OLDGIT/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = hook ] && { echo "git: 'hook' is not a git command. See 'git --help'." >&2; exit 1; }; done
exec "$REALGIT" "\$@"
STUB
chmod +x "$OLDGIT/git"
out="$( stub_path "$DET"; stub_path "$OLDGIT"; bash "$RITUAL" check secret-scan "$r" )"
[ "$(st "$out")" = unknown ] && [[ "$(dt "$out")" == *"git hook run"* ]] && [ "$(git -C "$r" status --porcelain)" = "$p0" ] \
  && ok "unknown_when_git_hook_run_missing" || bad "unknown_when_git_hook_run_missing: $out"

echo "== fix =="
# fix_inserts_into_beads_hook: block lands in .beads/hooks/pre-commit right after the shebang; bd's
# block and the user line follow it byte-for-byte.
r="$(bd_repo)"; h="$r/.beads/hooks/pre-commit"; cp "$h" "$TMPROOT/orig"
out="$(D fix secret-scan "$r")"
tail -n +2 "$TMPROOT/orig" > "$TMPROOT/orig.rest"
end_ln="$(grep -nx '# <<< ritual secret-scan' "$h" | cut -d: -f1)"
tail -n +"$((end_ln + 1))" "$h" > "$TMPROOT/new.rest"
[ "$(st "$out")" = fixed ] && [ "$(jq -c .wrote <<<"$out")" = '[".beads/hooks/pre-commit"]' ] \
  && [ "$(head -n 1 "$h")" = '#!/usr/bin/env sh' ] && [ "$(sed -n 2p "$h")" = '# >>> ritual secret-scan' ] \
  && [ -n "$end_ln" ] && cmp -s "$TMPROOT/orig.rest" "$TMPROOT/new.rest" \
  && [ "$(grep -nxF "$BEGIN_BD" "$h" | cut -d: -f1)" -gt "$end_ln" ] \
  && ok "fix_inserts_into_beads_hook" || bad "fix_inserts_into_beads_hook: $out / end=$end_ln"
grep -qF '"$_ritual_gl" git --pre-commit --staged --redact --no-banner' "$h" \
  && ok "fix_block_runs_pinned_command" || bad "pinned command missing from block"

# fix_idempotent: a second fix changes nothing and keeps one marker pair.
s1="$(sha256sum "$h" | cut -d' ' -f1)"
out="$(D fix secret-scan "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && [ "$(sha256sum "$h" | cut -d' ' -f1)" = "$s1" ] \
  && [ "$(nmark "$h" '# >>> ritual secret-scan')" = 1 ] && [ "$(nmark "$h" '# <<< ritual secret-scan')" = 1 ] \
  && ok "fix_idempotent" || bad "fix_idempotent: $out"

# fix_absolute_hookspath: bd itself writes an ABSOLUTE Windows core.hooksPath; wrote stays repo-relative.
r="$(bd_repo)"; git -C "$r" config core.hooksPath "$(cygpath -w "$r/.beads/hooks")"
out="$(D fix secret-scan "$r")"
[ "$(st "$out")" = fixed ] && [ "$(jq -c .wrote <<<"$out")" = '[".beads/hooks/pre-commit"]' ] \
  && [ "$(nmark "$r/.beads/hooks/pre-commit" '# >>> ritual secret-scan')" = 1 ] \
  && ok "fix_absolute_hookspath" || bad "fix_absolute_hookspath: $out"

# fix_creates_hook_when_absent: no hooksPath, no pre-commit -> .git/hooks/pre-commit, +x, shebang,
# block; nothing in the work tree is reported as written. The created hook then passes the proof.
r="$(mkrepo plain)"; h="$r/.git/hooks/pre-commit"
out="$(D fix secret-scan "$r")"
[ "$(st "$out")" = fixed ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && [ -x "$h" ] \
  && [ "$(head -n 1 "$h")" = '#!/usr/bin/env sh' ] && [ "$(sed -n 2p "$h")" = '# >>> ritual secret-scan' ] \
  && [ "$(nmark "$h" '# <<< ritual secret-scan')" = 1 ] && [ "$(crs "$h")" = 0 ] \
  && ok "fix_creates_hook_when_absent" || bad "fix_creates_hook_when_absent: $out"
out="$(D check secret-scan "$r")"
[ "$(st "$out")" = present ] && ok "created_hook_proves_present" || bad "created_hook_proves_present: $out"

# fix_preserves_crlf_hook: every line of a CRLF hook stays CRLF; the original bytes after the
# shebang are kept exactly.
r="$(bd_repo crlf)"; h="$r/.beads/hooks/pre-commit"; cp "$h" "$TMPROOT/orig"
out="$(D fix secret-scan "$r")"
end_ln="$(tr -d '\r' < "$h" | grep -nx '# <<< ritual secret-scan' | cut -d: -f1)"
tail -n +2 "$TMPROOT/orig" > "$TMPROOT/orig.rest"; tail -n +"$((end_ln + 1))" "$h" > "$TMPROOT/new.rest"
[ "$(st "$out")" = fixed ] && [ "$(crs "$TMPROOT/orig")" -gt 0 ] && [ "$(crs "$h")" = "$(lfs "$h")" ] \
  && [ "$(lfs "$h")" -gt "$(lfs "$TMPROOT/orig")" ] && [ -n "$end_ln" ] && cmp -s "$TMPROOT/orig.rest" "$TMPROOT/new.rest" \
  && ok "fix_preserves_crlf_hook" || bad "fix_preserves_crlf_hook: $out cr=$(crs "$h") lf=$(lfs "$h")"
out="$(D check secret-scan "$r")"
[ "$(st "$out")" = present ] && ok "crlf_hook_proves_present" || bad "crlf_hook_proves_present: $out"

# fix_refuses_non_shell_hook: a python pre-commit is left byte-identical and the step fails.
for sb in '#!/usr/bin/env python3' '#!/usr/bin/python' '#!/usr/bin/env -S node --no-warnings'; do
  r="$(mkrepo py)"; h="$r/.git/hooks/pre-commit"; printf '%s\nprint("hi")\n' "$sb" > "$h"
  s0="$(sha256sum "$h" | cut -d' ' -f1)"; want="${sb##*[/ ]}"
  out="$(D fix secret-scan "$r")"
  [ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"$want"* ]] && [ "$(sha256sum "$h" | cut -d' ' -f1)" = "$s0" ] \
    && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && ok "fix_refuses_non_shell_hook ($want)" || bad "fix_refuses_non_shell_hook ($sb): $out"
done
# ...but the shell family is accepted
for sb in '#!/bin/bash' '#!/usr/bin/env dash' '#!/bin/zsh'; do
  r="$(mkrepo sh)"; h="$r/.git/hooks/pre-commit"; printf '%s\ntrue\n' "$sb" > "$h"
  out="$(D fix secret-scan "$r")"
  [ "$(st "$out")" = fixed ] && [ "$(head -n 1 "$h")" = "$sb" ] && ok "fix_accepts_shell_hook (${sb##*[/ ]})" \
    || bad "fix_accepts_shell_hook ($sb): $out"
done

# fix_no_shebang_hook: a hook without a shebang gets the block at the very top and no shebang is
# invented (that would change how the hook is executed); its bytes follow the block unchanged.
r="$(mkrepo nosb)"; h="$r/.git/hooks/pre-commit"; printf 'true # no shebang\necho tail\n' > "$h"; cp "$h" "$TMPROOT/orig"
out="$(D fix secret-scan "$r")"
end_ln="$(grep -nx '# <<< ritual secret-scan' "$h" | cut -d: -f1)"
tail -n +"$((end_ln + 1))" "$h" > "$TMPROOT/new.rest"
[ "$(st "$out")" = fixed ] && [ "$(head -n 1 "$h")" = '# >>> ritual secret-scan' ] && [ "$(grep -c '^#!' "$h")" = 0 ] \
  && [ -n "$end_ln" ] && cmp -s "$TMPROOT/orig" "$TMPROOT/new.rest" && ok "fix_no_shebang_hook" || bad "fix_no_shebang_hook: $out"

# fix_refuses_unbalanced_markers: half a block is never "already"; the file is not touched.
r="$(mkrepo half)"; h="$r/.git/hooks/pre-commit"; printf '#!/bin/sh\n# >>> ritual secret-scan\ntrue\n' > "$h"
s0="$(sha256sum "$h" | cut -d' ' -f1)"
out="$(D fix secret-scan "$r")"
[ "$(st "$out")" = failed ] && [ "$(sha256sum "$h" | cut -d' ' -f1)" = "$s0" ] && ok "fix_refuses_unbalanced_markers" \
  || bad "fix_refuses_unbalanced_markers: $out"

echo "== check: absent / proof =="
r="$(bd_repo)"
out="$(D check secret-scan "$r")"
[ "$(st "$out")" = absent ] && [[ "$(dt "$out")" == *pre-commit* ]] && [ -z "$(git -C "$r" status --porcelain)" ] \
  && ok "check_absent_without_block" || bad "check_absent_without_block: $out"

# proof_detects_bypass: the block sits in .git/hooks/pre-commit, but core.hooksPath runs
# .beads/hooks, so the scan never runs. A file-presence check would say present.
r="$(bd_repo)"; git -C "$r" config --unset core.hooksPath
D fix secret-scan "$r" >/dev/null
git -C "$r" config core.hooksPath .beads/hooks
inplace="$(nmark "$r/.git/hooks/pre-commit" '# >>> ritual secret-scan')"
out="$(D check secret-scan "$r")"
[ "$inplace" = 1 ] && [ "$(st "$out")" != present ] && [ "$(st "$out")" = absent ] && ok "proof_detects_bypass" \
  || bad "proof_detects_bypass: block-in-.git/hooks=$inplace $out"

# proof_requires_nonzero_exit: a hook whose scan REPORTS the leak but lets the commit through
# (here an edited block that swallows gitleaks' exit) is not a working scan.
r="$(mkrepo swallow)"
printf '%s\n' '#!/usr/bin/env sh' '# >>> ritual secret-scan' 'gitleaks git --pre-commit --staged --redact --no-banner || true' \
  'echo >&2 "gitleaks: leak reported, ignored"' '# <<< ritual secret-scan' > "$r/.git/hooks/pre-commit"
out="$(D check secret-scan "$r")"
[ "$(st "$out")" = absent ] && [ -z "$(git -C "$r" status --porcelain)" ] && ok "proof_requires_nonzero_exit" \
  || bad "proof_requires_nonzero_exit: $out"

# proof_cleans_up: a dirty tree (staged, unstaged, untracked) is exactly as it was after the proof.
r="$(bd_repo)"; D fix secret-scan "$r" >/dev/null; git -C "$r" add .beads; git -C "$r" commit -q -m scan
echo more >> "$r/README.md"; echo s > "$r/staged.txt"; git -C "$r" add staged.txt; echo u > "$r/untracked.txt"
p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"; c0="$(git -C "$r" diff --cached --raw)"
log="$TMPROOT/shim.log"; : > "$log"
out="$( export SHIM_LOG="$log"; D check secret-scan "$r" )"
[ "$(st "$out")" = present ] && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] \
  && [ "$(git -C "$r" diff --cached --raw)" = "$c0" ] && [ "$(proof_leftovers "$r")" = 0 ] && [ -n "$p0" ] \
  && ok "proof_cleans_up" || bad "proof_cleans_up: $out / $(git -C "$r" status --porcelain)"
[ "$(st "$out")" = present ] && [ ! -s "$log" ] && ok "proof_blocks_before_bd_shim" || bad "proof_blocks_before_bd_shim: $out / log=$(cat "$log")"

# proof_reverts_hook_staging: when detection fails, bd's shim runs and stages a file that was only
# modified before. The proof unstages it again and reports absent, not failed.
echo '{"id":"x-2"}' >> "$r/.beads/issues.jsonl"
p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"
out="$( export SHIM_STAGE=.beads/issues.jsonl; P check secret-scan "$r" )"
[ "$(st "$out")" = absent ] && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] \
  && [[ "$p0" == *" M .beads/issues.jsonl"* ]] && [ "$(proof_leftovers "$r")" = 0 ] \
  && ok "proof_reverts_hook_staging" || bad "proof_reverts_hook_staging: $out / $(git -C "$r" status --porcelain)"

# proof_failed_when_side_effects_remain: a hook that rewrites a file cannot be undone -> failed,
# naming the path.
out="$( export SHIM_TOUCH=README.md; P check secret-scan "$r" )"
[ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *README.md* ]] && [ "$(proof_leftovers "$r")" = 0 ] \
  && ok "proof_failed_when_side_effects_remain" || bad "proof_failed_when_side_effects_remain: $out"

# resolver_uses_localappdata_fallback: gitleaks only at $LOCALAPPDATA/Microsoft/WinGet/Links (as
# winget installs it, not on PATH): both check and the hook block must find it there.
LA="$TMPROOT/local app data"; mkdir -p "$LA/Microsoft/WinGet/Links"
cp "$DET/gitleaks" "$LA/Microsoft/WinGet/Links/gitleaks.exe"; chmod +x "$LA/Microsoft/WinGet/Links/gitleaks.exe"
r="$(bd_repo)"; D fix secret-scan "$r" >/dev/null
out="$( PATH="$NOGL"; LOCALAPPDATA="$(cygpath -w "$LA")"; export PATH LOCALAPPDATA; bash "$RITUAL" check secret-scan "$r" )"
[ "$(st "$out")" = present ] && ok "resolver_uses_localappdata_fallback" || bad "resolver_uses_localappdata_fallback: $out"
h0="$(git -C "$r" rev-parse HEAD)"
printf 'aws_access_key_id = %s\n' "$KEY" > "$r/creds.txt"; git -C "$r" add creds.txt
err="$( PATH="$NOGL"; LOCALAPPDATA="$(cygpath -w "$LA")"; export PATH LOCALAPPDATA; git -C "$r" commit -q -m leak 2>&1 )"; rc=$?
[ "$rc" != 0 ] && [ "$(git -C "$r" rev-parse HEAD)" = "$h0" ] && [[ "$err" == *"leaks found"* ]] \
  && ok "hook_uses_localappdata_fallback" || bad "hook_uses_localappdata_fallback: rc=$rc $err"
git -C "$r" rm -q --cached creds.txt; rm -f "$r/creds.txt"

# hook_fails_open_without_gitleaks: no gitleaks by either route -> loud warning, commit proceeds.
echo ok > "$r/benign.txt"; git -C "$r" add benign.txt
err="$( PATH="$NOGL"; LOCALAPPDATA="$(cygpath -w "$EMPTY_LA")"; export PATH LOCALAPPDATA; git -C "$r" commit -q -m benign 2>&1 >/dev/null )"; rc=$?
[ "$rc" = 0 ] && [[ "$err" == *WARNING* ]] && [[ "$err" == *gitleaks* ]] && [ -z "$(git -C "$r" status --porcelain -- benign.txt)" ] && [ "$(git -C "$r" log -1 --format=%s)" = benign ] \
  && ok "hook_fails_open_without_gitleaks" || bad "hook_fails_open_without_gitleaks: rc=$rc err=$err"

echo "== real gitleaks =="
# The real binary, found the way the step finds it (PATH, then the WinGet Links directory).
REALGL="$(command -v gitleaks 2>/dev/null)"
[ -z "$REALGL" ] && [ -n "${LOCALAPPDATA:-}" ] && [ -x "$LOCALAPPDATA/Microsoft/WinGet/Links/gitleaks.exe" ] \
  && REALGL="$LOCALAPPDATA/Microsoft/WinGet/Links/gitleaks.exe"
if [ -z "$REALGL" ]; then
  echo "  SKIP: proof_real (gitleaks not found)"
  echo "  SKIP: hook_blocks_real_commit (gitleaks not found)"
  echo "  SKIP: hook_passes_clean_real_commit (gitleaks not found)"
  echo "  SKIP: no_leaks_in_source_per_gitleaks (gitleaks not found)"
else
  r="$(bd_repo)"
  bash "$RITUAL" fix secret-scan "$r" >/dev/null
  p0="$(git -C "$r" status --porcelain)"; out="$(bash "$RITUAL" check secret-scan "$r")"
  [ "$(st "$out")" = present ] && [ "$(git -C "$r" status --porcelain)" = "$p0" ] && ok "proof_real" || bad "proof_real: $out"

  git -C "$r" add .beads; git -C "$r" commit -q -m scan
  h0="$(git -C "$r" rev-parse HEAD)"
  printf 'aws_access_key_id = %s\n' "$KEY" > "$r/creds.txt"; git -C "$r" add creds.txt
  err="$(git -C "$r" commit -q -m leak 2>&1)"; rc=$?
  [ "$rc" != 0 ] && [ "$(git -C "$r" rev-parse HEAD)" = "$h0" ] && [[ "$err" == *gitleaks* ]] \
    && ok "hook_blocks_real_commit" || bad "hook_blocks_real_commit: rc=$rc $err"
  git -C "$r" rm -q --cached creds.txt; rm -f "$r/creds.txt"
  echo ok > "$r/benign.txt"; git -C "$r" add benign.txt
  git -C "$r" commit -q -m benign 2>/dev/null && [ "$(git -C "$r" rev-parse HEAD)" != "$h0" ] \
    && [ "$(nmark "$r/.beads/hooks/pre-commit" '# >>> ritual secret-scan')" = 1 ] \
    && ok "hook_passes_clean_real_commit" || bad "hook_passes_clean_real_commit"

  # the source of this skill (lib and tests) must not trip gitleaks itself (it is committed publicly)
  gout="$("$REALGL" dir "$SKILL_DIR" --no-banner --redact 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [[ "$gout" == *"no leaks found"* ]] && ok "no_leaks_in_source_per_gitleaks" \
    || bad "no_leaks_in_source_per_gitleaks: rc=$rc $gout"
fi

finish
