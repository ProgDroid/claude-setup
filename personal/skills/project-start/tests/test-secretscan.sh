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
# CRASH exits non-zero WITHOUT a leaks line, as gitleaks does on a broken config.
CRASH="$TMPROOT/stub crash"; mkdir -p "$CRASH"
cat > "$CRASH/gitleaks" <<'STUB'
#!/usr/bin/env bash
echo "FTL unable to load gitleaks config, err: While parsing config: toml: expected character =" >&2; exit 1
STUB
chmod +x "$DET/gitleaks" "$PASSIVE/gitleaks" "$CRASH/gitleaks"

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
    'if [ -n "${SHIM_STAGE:-}" ]; then git --literal-pathspecs add -- "$SHIM_STAGE"; fi' \
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

# fix_unknown_when_unprovable (R45): the block is present but the proof cannot run -> fix is
# unknown ("not proved: <cause>"), never already, and writes nothing. Both causes.
s1="$(sha256sum "$r/.beads/hooks/pre-commit" | cut -d' ' -f1)"
out="$(N fix secret-scan "$r")"
[ "$(st "$out")" = unknown ] && [[ "$(dt "$out")" == "not proved: "*gitleaks* ]] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] \
  && [ "$(sha256sum "$r/.beads/hooks/pre-commit" | cut -d' ' -f1)" = "$s1" ] \
  && ok "fix_unknown_when_unprovable (no gitleaks)" || bad "fix_unknown_when_unprovable (no gitleaks): $out"
out="$( stub_path "$DET"; stub_path "$OLDGIT"; bash "$RITUAL" fix secret-scan "$r" )"
[ "$(st "$out")" = unknown ] && [[ "$(dt "$out")" == "not proved: "*"git hook run"* ]] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] \
  && [ "$(git -C "$r" status --porcelain)" = "$p0" ] \
  && ok "fix_unknown_when_unprovable (no git hook run)" || bad "fix_unknown_when_unprovable (no git hook run): $out"

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
grep -qF '"$_ritual_gl" git --pre-commit --staged --redact --no-banner --no-color --verbose' "$h" \
  && ok "fix_block_runs_pinned_command" || bad "pinned command missing from block"

# fix_idempotent: a second fix changes nothing and keeps one marker pair. The hook edit was never
# committed, so the rerun lists it again for the commit step (I1).
s1="$(sha256sum "$h" | cut -d' ' -f1)"
out="$(D fix secret-scan "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[".beads/hooks/pre-commit"]' ] && [ "$(sha256sum "$h" | cut -d' ' -f1)" = "$s1" ] \
  && [ "$(nmark "$h" '# >>> ritual secret-scan')" = 1 ] && [ "$(nmark "$h" '# <<< ritual secret-scan')" = 1 ] \
  && dt "$out" | grep -qF 'not yet committed' && ok "fix_idempotent" || bad "fix_idempotent: $out"
git -C "$r" add .beads/hooks/pre-commit && git -C "$r" commit -q --no-verify -m 'secret scan'
out="$(D fix secret-scan "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && ok "fix_rerun_after_the_commit_lists_nothing" || bad "rerun after commit: $out"

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

# fix_refuses_non_shell_hook: a python pre-commit is left byte-identical and the step fails,
# naming the interpreter (the detail carries the parsed name only, never the shebang line).
for pair in 'python3|#!/usr/bin/env python3' 'python|#!/usr/bin/python' 'node|#!/usr/bin/env -S node --no-warnings'; do
  want="${pair%%|*}"; sb="${pair#*|}"
  r="$(mkrepo py)"; h="$r/.git/hooks/pre-commit"; printf '%s\nprint("hi")\n' "$sb" > "$h"
  s0="$(sha256sum "$h" | cut -d' ' -f1)"
  out="$(D fix secret-scan "$r")"
  [ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"(interpreter: $want)"* ]] && [[ "$(dt "$out")" != *'#!'* ]] \
    && [ "$(sha256sum "$h" | cut -d' ' -f1)" = "$s0" ] \
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
# (here an edited block that swallows gitleaks' exit) is not a working scan. The block is in the
# hook git runs, so this is `failed` with the cause (R41), for check AND fix (never absent/already).
r="$(mkrepo swallow)"
printf '%s\n' '#!/usr/bin/env sh' '# >>> ritual secret-scan' 'gitleaks git --pre-commit --staged --redact --no-banner || true' \
  'echo >&2 "gitleaks: leak reported, ignored"' '# <<< ritual secret-scan' > "$r/.git/hooks/pre-commit"
out="$(D check secret-scan "$r")"
[ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"did not fire"* ]] && [[ "$(dt "$out")" == *"leak reported, ignored"* ]] \
  && [ -z "$(git -C "$r" status --porcelain)" ] && ok "proof_requires_nonzero_exit" || bad "proof_requires_nonzero_exit: $out"
out="$(D fix secret-scan "$r")"
[ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"did not fire"* ]] && ok "fix_fails_on_edited_block" \
  || bad "fix_fails_on_edited_block: $out"

# r41_no_trailing_colon: a hook that printed nothing gives a detail without a dangling ": ".
r="$(mkrepo quiet)"
printf '%s\n' '#!/usr/bin/env sh' '# >>> ritual secret-scan' 'true' '# <<< ritual secret-scan' > "$r/.git/hooks/pre-commit"
out="$(D check secret-scan "$r")"; d="$(dt "$out")"
[ "$(st "$out")" = failed ] && [[ "$d" == *"did not fire"* ]] && [[ "$d" != *: ]] && [[ "$d" != *": " ]] \
  && ok "r41_no_trailing_colon" || bad "r41_no_trailing_colon: $out"

# r43_crash_blocks_with_failed_to_run: gitleaks exiting non-zero with no leaks line (broken config)
# blocks the commit, says it failed to run and never says secrets were found; check is failed.
r="$(mkrepo crash)"; D fix secret-scan "$r" >/dev/null
echo ok > "$r/benign.txt"; git -C "$r" add benign.txt; h0="$(git -C "$r" rev-parse HEAD)"
err="$( stub_path "$CRASH"; git -C "$r" commit -q -m benign 2>&1 )"; rc=$?
[ "$rc" != 0 ] && [ "$(git -C "$r" rev-parse HEAD)" = "$h0" ] && [[ "$err" == *"failed to run"* ]] \
  && [[ "$err" == *"nothing was scanned"* ]] && [[ "$err" != *"found secrets"* ]] \
  && ok "r43_crash_blocks_with_failed_to_run" || bad "r43_crash_blocks_with_failed_to_run: rc=$rc $err"
git -C "$r" rm -q --cached benign.txt
out="$( stub_path "$CRASH"; bash "$RITUAL" check secret-scan "$r" )"
[ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"failed to run"* ]] && ok "r43_check_failed_names_cause" \
  || bad "r43_check_failed_names_cause: $out"
err="$( stub_path "$DET"; printf 'aws_access_key_id = %s\n' "$KEY" > "$r/k.txt"; git -C "$r" add k.txt; git -C "$r" commit -q -m k 2>&1 )"
[[ "$err" == *"found secrets"* ]] && [[ "$err" != *"failed to run"* ]] && ok "r43_leak_message_says_found" \
  || bad "r43_leak_message_says_found: $err"
git -C "$r" rm -q --cached k.txt; rm -f "$r/k.txt"

# block_safe_under_sh_e: the block runs under the hook's shebang flags; Git for Windows ignores
# them, so the hook is run with an explicit `sh -e` here. Three cases: no gitleaks, leak, clean.
r="$(mkrepo she)"; h="$r/.git/hooks/pre-commit"; printf '#!/bin/sh -e\necho after-block\n' > "$h"
D fix secret-scan "$r" >/dev/null
err="$( cd "$r" && PATH="$NOGL" LOCALAPPDATA="$(cygpath -w "$EMPTY_LA")" sh -e .git/hooks/pre-commit 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [[ "$err" == *WARNING*gitleaks* ]] && [[ "$err" == *after-block* ]] \
  && ok "block_safe_under_sh_e (no gitleaks: warns, continues)" || bad "block_safe_under_sh_e (absent): rc=$rc $err"
printf 'aws_access_key_id = %s\n' "$KEY" > "$r/k.txt"; git -C "$r" add k.txt
err="$( cd "$r" && stub_path "$DET" && sh -e .git/hooks/pre-commit 2>&1 )"; rc=$?
[ "$rc" != 0 ] && [[ "$err" == *"ritual secret-scan: gitleaks found secrets"* ]] && [[ "$err" != *after-block* ]] \
  && ok "block_safe_under_sh_e (leak: message, blocks)" || bad "block_safe_under_sh_e (leak): rc=$rc $err"
git -C "$r" rm -q --cached k.txt; rm -f "$r/k.txt"
err="$( cd "$r" && stub_path "$DET" && sh -e .git/hooks/pre-commit 2>&1 )"; rc=$?
[ "$rc" = 0 ] && [[ "$err" == *after-block* ]] && ok "block_safe_under_sh_e (clean: passes)" \
  || bad "block_safe_under_sh_e (clean): rc=$rc $err"

# sweep_removes_leftover_proof_file: a proof file left by a killed run (staged AND on disk) is
# removed by the next check and by fix, and reported; look-alike names are not touched.
r="$(bd_repo)"; D fix secret-scan "$r" >/dev/null
lo=".ritual-secret-scan-proof.LEFT01"
seed_leftover() {
  printf 'aws_access_key_id = %s\n' "$KEY" > "$r/$lo"; git -C "$r" add -f "$lo"
  echo keep > "$r/.ritual-secret-scan-proofX"; mkdir -p "$r/sub"; echo keep > "$r/sub/$lo"
}
seed_leftover
seeded="$(git -C "$r" ls-files -- "$lo")"
out="$(D check secret-scan "$r")"
[ "$seeded" = "$lo" ] && [ "$(st "$out")" = present ] && [[ "$(dt "$out")" == *"leftover proof file"* ]] \
  && [ -z "$(git -C "$r" ls-files -- "$lo")" ] && [ ! -e "$r/$lo" ] \
  && [ -e "$r/.ritual-secret-scan-proofX" ] && [ -e "$r/sub/$lo" ] \
  && ok "sweep_removes_leftover_proof_file (check)" || bad "sweep (check): seeded=$seeded $out"
seed_leftover
out="$(D fix secret-scan "$r")"
[[ "$(dt "$out")" == *"leftover proof file"* ]] && [ -z "$(git -C "$r" ls-files -- "$lo")" ] && [ ! -e "$r/$lo" ] \
  && [ -e "$r/sub/$lo" ] && ok "sweep_removes_leftover_proof_file (fix)" || bad "sweep (fix): $out"
rm -rf "$r/sub" "$r/.ritual-secret-scan-proofX"

# term_waits_for_cleanup: TERM to the whole job (as a harness timeout sends) while the hook runs.
# The ritual must not exit before the proof has cleaned up, and reports failed "interrupted".
SLOW="$TMPROOT/stub slow"; mkdir -p "$SLOW"
cat > "$SLOW/gitleaks" <<'STUB'
#!/usr/bin/env bash
: > "$SLOW_MARK"; sleep 5; echo "INF no leaks found" >&2; exit 0
STUB
chmod +x "$SLOW/gitleaks"
p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"
mark="$TMPROOT/slow.mark"; rm -f "$mark"
set -m
( stub_path "$SLOW"; export SLOW_MARK="$mark"; exec bash "$RITUAL" check secret-scan "$r" > "$TMPROOT/term.out" 2>/dev/null ) &
pid=$!
set +m
for i in $(seq 1 150); do [ -e "$mark" ] && break; sleep 0.2; done
mid="$(git -C "$r" ls-files -- '.ritual-secret-scan-proof.*' | wc -l | tr -d ' ')"
kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid"
wait "$pid"; trc=$?
now_left="$(proof_leftovers "$r")"; now_idx="$(git -C "$r" ls-files -- '.ritual-secret-scan-proof.*' | wc -l | tr -d ' ')"
[ -e "$mark" ] && [ "$mid" = 1 ] && [ "$trc" != 0 ] && [ "$now_left" = 0 ] && [ "$now_idx" = 0 ] \
  && [ "$(st "$(cat "$TMPROOT/term.out")")" = failed ] && [[ "$(dt "$(cat "$TMPROOT/term.out")")" == *interrupted* ]] \
  && ok "term_waits_for_cleanup" || bad "term_waits_for_cleanup: mark=$([ -e "$mark" ] && echo y) mid=$mid rc=$trc left=$now_left idx=$now_idx out=$(cat "$TMPROOT/term.out")"
for i in $(seq 1 30); do
  [ "$(proof_leftovers "$r")" = 0 ] && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] && break; sleep 1
done
[ "$(proof_leftovers "$r")" = 0 ] && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] \
  && ok "term_leaves_no_key" || bad "term_leaves_no_key: $(git -C "$r" status --porcelain)"

# fix_term_waits_for_cleanup: the same, sent to `fix` while it proves the block that is already there.
p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"; rm -f "$mark"
set -m
( stub_path "$SLOW"; export SLOW_MARK="$mark"; exec bash "$RITUAL" fix secret-scan "$r" > "$TMPROOT/fterm.out" 2>/dev/null ) &
pid=$!
set +m
for i in $(seq 1 150); do [ -e "$mark" ] && break; sleep 0.2; done
mid="$(git -C "$r" ls-files -- '.ritual-secret-scan-proof.*' | wc -l | tr -d ' ')"
kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid"
wait "$pid"; trc=$?
fo="$(cat "$TMPROOT/fterm.out")"
now_left="$(proof_leftovers "$r")"; now_idx="$(git -C "$r" ls-files -- '.ritual-secret-scan-proof.*' | wc -l | tr -d ' ')"
[ -e "$mark" ] && [ "$mid" = 1 ] && [ "$trc" != 0 ] && [ "$now_left" = 0 ] && [ "$now_idx" = 0 ] \
  && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] && [ "$(st "$fo")" = failed ] \
  && [[ "$(dt "$fo")" == *"interrupted by SIGTERM while proving the existing block"* ]] \
  && [[ "$(dt "$fo")" == *"the proof file was removed"* ]] \
  && ok "fix_term_waits_for_cleanup" || bad "fix_term_waits_for_cleanup: mid=$mid rc=$trc left=$now_left idx=$now_idx out=$fo"

# interrupt_detail_*: unit calls on the helper that words an interrupted run. Whether a proof
# file remains is checked, never assumed; an empty or unparsable proof result reads "none".
idet() { ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/workspace.sh"; . "$SKILL_DIR/lib/secretscan.sh"; _ss_interrupt_detail "$@" ); }
d1="$(idet TERM "$r" "" "during the proof")"; d2="$(idet INT "$r" "not json" "during the proof")"
d3="$(idet HUP "$r" '{"id":"secret-scan","status":"present","detail":"proved"}' "while proving the existing block")"
[ "$d1" = "interrupted by SIGTERM during the proof; the proof file was removed; proof result: none" ] \
  && [ "$d2" = "interrupted by SIGINT during the proof; the proof file was removed; proof result: none" ] \
  && [ "$d3" = "interrupted by SIGHUP while proving the existing block; the proof file was removed; proof result: present: proved" ] \
  && ok "interrupt_detail_result_none_when_empty_or_unparsable" || bad "interrupt_detail: [$d1] [$d2] [$d3]"
lo=".ritual-secret-scan-proof.LEFT02"
printf 'x\n' > "$r/$lo"; git -C "$r" add -f "$lo"; printf 'y\n' > "$r/.ritual-secret-scan-proof.LEFT03"
d4="$(idet TERM "$r" "" "during the proof")"
[[ "$d4" == *"proof file still present: "* ]] && [[ "$d4" == *"$lo (staged)"* ]] && [[ "$d4" == *"$lo (on disk)"* ]] \
  && [[ "$d4" == *".ritual-secret-scan-proof.LEFT03 (on disk)"* ]] && [[ "$d4" != *"was removed"* ]] \
  && ok "interrupt_detail_names_what_remains" || bad "interrupt_detail_names_what_remains: $d4"

# r45_detail_starts_not_proved: with a leftover swept by the same run, the unknown detail still
# starts "not proved:" and carries the sweep note after the cause.
out="$(N fix secret-scan "$r")"; d="$(dt "$out")"
[ "$(st "$out")" = unknown ] && [[ "$d" == "not proved: "* ]] && [[ "$d" == *"; removed 2 leftover proof file(s) from an interrupted run" ]] \
  && [ "$(proof_leftovers "$r")" = 0 ] && [ -z "$(git -C "$r" ls-files -- "$lo")" ] \
  && ok "r45_detail_starts_not_proved" || bad "r45_detail_starts_not_proved: $out"

# restore_absent_branch_staged_deletion: the user's `git rm --cached del.txt`, re-added by the hook,
# is put back as a staged deletion; the step fails only for the R41 cause (the proof did not fire).
r="$(bd_repo)"; D fix secret-scan "$r" >/dev/null
echo d > "$r/del.txt"; git -C "$r" add del.txt; git -C "$r" commit -q --no-verify -m del -- del.txt
git -C "$r" rm -q --cached del.txt
p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"
out="$( export SHIM_STAGE=del.txt; P check secret-scan "$r" )"
[[ "$p0" == *"D  del.txt"* ]] && [ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"did not fire"* ]] \
  && [[ "$(dt "$out")" != *"could not be undone"* ]] && [ -z "$(git -C "$r" ls-files -s -- del.txt)" ] \
  && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] \
  && ok "restore_absent_branch_staged_deletion" || bad "restore_absent_branch_staged_deletion: $out / $(git -C "$r" status --porcelain)"

# restore_skips_unmerged_path (R46): mid-merge, f.txt is UU with 3 stages; the hook (past a proof
# that does not fire) runs `git add -- f.txt`, which resolves it. The ritual must not write that
# path back (its recorded "ABSENT" means conflicted, not untracked): failed, naming the path and
# the --unresolve remedy. The index stays exactly as the hook left it (stage 0 = the work tree).
r="$(mkrepo merge)"
echo base > "$r/f.txt"; git -C "$r" add f.txt; git -C "$r" commit -q -m base
git -C "$r" checkout -q -b other; echo theirs > "$r/f.txt"; git -C "$r" commit -q -am theirs
git -C "$r" checkout -q main; echo ours > "$r/f.txt"; git -C "$r" commit -q -am ours
git -C "$r" merge -q other >/dev/null 2>&1
h="$r/.git/hooks/pre-commit"; printf '%s\n' '#!/usr/bin/env sh' 'git --literal-pathspecs add -- f.txt' > "$h"
D fix secret-scan "$r" >/dev/null
u0="$(git -C "$r" ls-files -u -- f.txt | wc -l | tr -d ' ')"; x0="$(git -C "$r" status --porcelain=v1 -- f.txt)"
out="$(P check secret-scan "$r")"; d="$(dt "$out")"
want_blob="$(git -C "$r" hash-object -- f.txt)"
[ "$u0" = 3 ] && [ "$x0" = "UU f.txt" ] && [ "$(st "$out")" = failed ] && [[ "$d" == *'"f.txt" was unmerged before the proof'* ]] \
  && [[ "$d" == *'git update-index --unresolve -- "f.txt"'* ]] && [[ "$d" != *"index was ABSENT"* ]] \
  && [ -z "$(git -C "$r" ls-files -u -- f.txt)" ] && [ "$(git -C "$r" ls-files -s -- f.txt)" = "100644 $want_blob 0	f.txt" ] \
  && [ "$(proof_leftovers "$r")" = 0 ] \
  && ok "restore_skips_unmerged_path" || bad "restore_skips_unmerged_path: u0=$u0 x0=$x0 $out / $(git -C "$r" ls-files -s -- f.txt)"
# the remedy the detail names really brings the conflict back (all 3 stages)
git -C "$r" update-index --unresolve -- f.txt
[ "$(git -C "$r" ls-files -u -- f.txt | wc -l | tr -d ' ')" = 3 ] && [ "$(git -C "$r" status --porcelain=v1 -- f.txt)" = "UU f.txt" ] \
  && ok "unmerged_remedy_restores_conflict" || bad "unmerged_remedy_restores_conflict: $(git -C "$r" ls-files -u -- f.txt)"

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
# modified before. The proof unstages it again: the step is failed for the R41 cause (the proof did
# not fire), never for side effects.
echo '{"id":"x-2"}' >> "$r/.beads/issues.jsonl"
p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"
out="$( export SHIM_STAGE=.beads/issues.jsonl; P check secret-scan "$r" )"
[ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"did not fire"* ]] && [[ "$(dt "$out")" != *"could not be undone"* ]] \
  && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] \
  && [[ "$p0" == *" M .beads/issues.jsonl"* ]] && [ "$(proof_leftovers "$r")" = 0 ] \
  && ok "proof_reverts_hook_staging" || bad "proof_reverts_hook_staging: $out / $(git -C "$r" status --porcelain)"

# restore_uses_literal_pathspecs: the hook stages `a[1].txt`; restoring it must not glob onto the
# user's staged change to `a1.txt`.
echo user > "$r/a1.txt"; git -C "$r" add a1.txt; echo hook > "$r/a[1].txt"
p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"; i0="$(git -C "$r" ls-files -s -- a1.txt)"
out="$( export SHIM_STAGE='a[1].txt'; P check secret-scan "$r" )"
[[ "$p0" == *"A  a1.txt"* ]] && [[ "$(dt "$out")" != *"could not be undone"* ]] \
  && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] && [ "$(git -C "$r" ls-files -s -- a1.txt)" = "$i0" ] \
  && ok "restore_uses_literal_pathspecs" || bad "restore_uses_literal_pathspecs: $out / $(git -C "$r" status --porcelain)"
git -C "$r" rm -q --cached a1.txt; rm -f "$r/a1.txt" "$r/a[1].txt"

# restore_restaged_user_change: a path with a staged AND a further unstaged change (MM) that the
# hook re-stages gets the user's staged blob back.
echo v1 > "$r/j.txt"; git -C "$r" add j.txt; git -C "$r" commit -q -m j --no-verify -- j.txt
echo v2 > "$r/j.txt"; git -C "$r" add j.txt; echo v3 > "$r/j.txt"
p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"; i0="$(git -C "$r" ls-files -s -- j.txt)"
out="$( export SHIM_STAGE=j.txt; P check secret-scan "$r" )"
[[ "$p0" == *"MM j.txt"* ]] && [[ "$(dt "$out")" != *"could not be undone"* ]] \
  && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] && [ "$(git -C "$r" ls-files -s -- j.txt)" = "$i0" ] \
  && ok "restore_restaged_user_change" || bad "restore_restaged_user_change: $out / $(git -C "$r" status --porcelain)"
git -C "$r" reset -q -- j.txt; git -C "$r" checkout -q -- j.txt

# proof_failed_when_side_effects_remain: a hook that rewrites a file cannot be undone -> failed,
# naming the path.
out="$( export SHIM_TOUCH=README.md; P check secret-scan "$r" )"
[ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"could not be undone"*README.md* ]] && [ "$(proof_leftovers "$r")" = 0 ] \
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
# The real binary, found by the step's own resolver (never a re-derived copy of it).
REALGL="$( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/secretscan.sh"; _ss_gitleaks )"
if [ -z "$REALGL" ]; then
  for t in proof_real hook_blocks_real_commit hook_names_leak_location hook_passes_clean_real_commit \
    r41_allowlisting_config_is_failed r43_real_bad_config_blocks no_leaks_in_source_per_gitleaks; do
    echo "  SKIP: $t (gitleaks not found)"
  done
else
  r="$(bd_repo)"
  bash "$RITUAL" fix secret-scan "$r" >/dev/null
  p0="$(git -C "$r" status --porcelain)"; out="$(bash "$RITUAL" check secret-scan "$r")"
  [ "$(st "$out")" = present ] && [ "$(git -C "$r" status --porcelain)" = "$p0" ] && ok "proof_real" || bad "proof_real: $out"

  git -C "$r" add .beads; git -C "$r" commit -q -m scan
  h0="$(git -C "$r" rev-parse HEAD)"
  printf 'aws_access_key_id = %s\n' "$KEY" > "$r/creds.txt"; git -C "$r" add creds.txt
  err="$(git -C "$r" commit -q -m leak 2>&1)"; rc=$?
  [ "$rc" != 0 ] && [ "$(git -C "$r" rev-parse HEAD)" = "$h0" ] && [[ "$err" == *"gitleaks found secrets"* ]] \
    && ok "hook_blocks_real_commit" || bad "hook_blocks_real_commit: rc=$rc $err"
  # --verbose: the blocked user sees where the leak is; --redact: never the secret itself
  [[ "$err" == *creds.txt* ]] && [[ "$err" == *aws-access-token* ]] && [[ "$err" != *"$KEY"* ]] \
    && ok "hook_names_leak_location" || bad "hook_names_leak_location: $err"
  git -C "$r" rm -q --cached creds.txt; rm -f "$r/creds.txt"
  echo ok > "$r/benign.txt"; git -C "$r" add benign.txt
  git -C "$r" commit -q -m benign 2>/dev/null && [ "$(git -C "$r" rev-parse HEAD)" != "$h0" ] \
    && [ "$(nmark "$r/.beads/hooks/pre-commit" '# >>> ritual secret-scan')" = 1 ] \
    && ok "hook_passes_clean_real_commit" || bad "hook_passes_clean_real_commit"

  # R41 with the real tool: a repo config allowlisting the proof file means the scan cannot fire;
  # check and fix are both failed (never absent/already), naming the cause.
  printf '[extend]\nuseDefault = true\n\n[allowlist]\npaths = [%s]\n' "'''\.ritual-secret-scan-proof\..*'''" > "$r/.gitleaks.toml"
  out="$(bash "$RITUAL" check secret-scan "$r")"; out2="$(bash "$RITUAL" fix secret-scan "$r")"
  [ "$(st "$out")" = failed ] && [[ "$(dt "$out")" == *"did not fire"* ]] && [[ "$(dt "$out")" == *"no leaks found"* ]] \
    && [ "$(st "$out2")" = failed ] && [ "$(proof_leftovers "$r")" = 0 ] \
    && ok "r41_allowlisting_config_is_failed" || bad "r41_allowlisting_config_is_failed: $out / $out2"

  # R43 with the real tool: a malformed .gitleaks.toml blocks the commit as "failed to run".
  printf 'garbage[[[\n' > "$r/.gitleaks.toml"
  echo ok2 > "$r/benign2.txt"; git -C "$r" add benign2.txt; h1="$(git -C "$r" rev-parse HEAD)"
  err="$(git -C "$r" commit -q -m benign2 2>&1)"; rc=$?
  [ "$rc" != 0 ] && [ "$(git -C "$r" rev-parse HEAD)" = "$h1" ] && [[ "$err" == *"failed to run"* ]] \
    && [[ "$err" != *"found secrets"* ]] && ok "r43_real_bad_config_blocks" || bad "r43_real_bad_config_blocks: rc=$rc $err"
  rm -f "$r/.gitleaks.toml"

  # the source of this skill (lib and tests) must not trip gitleaks itself (it is committed publicly)
  gout="$("$REALGL" dir "$SKILL_DIR" --no-banner --redact 2>&1)"; rc=$?
  [ "$rc" = 0 ] && [[ "$gout" == *"no leaks found"* ]] && ok "no_leaks_in_source_per_gitleaks" \
    || bad "no_leaks_in_source_per_gitleaks: rc=$rc $gout"
fi

finish
