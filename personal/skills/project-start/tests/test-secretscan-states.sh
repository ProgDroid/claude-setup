#!/usr/bin/env bash
# Tests: secret-scan states the main suite never reached: unmerged paths (DD, AU, UA) during the
# proof, HUP and SIGKILL during a run, and the sweep of stale hook temp files (Ruling R16).
# A separate suite because test-secretscan.sh already takes ~11 minutes.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- copied from test-secretscan.sh (not sourced: that file is a suite, not a library) ---
DET="$TMPROOT/stub detect"; PASSIVE="$TMPROOT/stub passive"
mkdir -p "$DET" "$PASSIVE"
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
D() { ( stub_path "$DET"; bash "$RITUAL" "$@" ); }
P() { ( stub_path "$PASSIVE"; bash "$RITUAL" "$@" ); }
st() { jq -r .status <<<"$1"; }
dt() { jq -r .detail <<<"$1"; }
proof_leftovers() { find "$1" -maxdepth 1 -name '.ritual-secret-scan-proof*' | wc -l | tr -d ' '; }
ss_lib() { ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/workspace.sh"; . "$SKILL_DIR/lib/secretscan.sh"; "$@" ); }
V1_BLOCK="$TESTS_DIR/fixtures/secretscan-v1-0.14.1.txt"
WT_HOOKS="tools/git hooks"
# --- end of copied helpers ---

# own helpers
idx_count() { git -C "$1" ls-files -- '.ritual-secret-scan-proof.*' | wc -l | tr -d ' '; }
hook_temps() { find "$1" -maxdepth 1 -name '.ritual-pre-commit.*' | wc -l | tr -d ' '; }
state_of() { git -C "$1" status --porcelain=v1 --untracked-files=all; printf '%s\n' '--'; git -C "$1" ls-files -s; }
# without <path>: status and stage lines of every OTHER path, so "the rest is unchanged" is checked
without() { awk -v p="$2" -F '\t' '{ if ($0 == "--") { print; next } if (NF > 1) { if ($2 != p) print } else if (substr($0, 4) != p) print }' <<<"$1"; }
# The slow stub writes its own pid to SLOW_MARK, then sleeps: the signal lands mid-proof, and a
# test can wait for an orphaned stub (Git for Windows runs hooks outside the job's process group).
SLOW="$TMPROOT/stub slow"; mkdir -p "$SLOW"
cat > "$SLOW/gitleaks" <<'STUB'
#!/usr/bin/env bash
echo "$$" > "$SLOW_MARK"; sleep 4; echo "INF no leaks found" >&2; exit 0
STUB
chmod +x "$SLOW/gitleaks"
wait_mark() { local i; for i in $(seq 1 150); do [ -s "$1" ] && return 0; sleep 0.2; done; return 1; }
wait_gone() { local i; for i in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done; return 1; }

echo "== unmerged paths during the proof (R46 guard: never written back) =="
# rr_merge -> a repo stopped in a rename/rename(1to2) conflict: base a.txt, ours renamed it to
# b.txt, theirs to c.txt. git leaves a.txt DD (both deleted), b.txt AU (added by us), c.txt UA
# (added by them). Each test checks the XY code before asserting anything else.
rr_merge() {
  local r; r="$(mkrepo "$1")"
  printf 'line1\nline2\nline3\n' > "$r/a.txt"; git -C "$r" add a.txt; git -C "$r" commit -q -m base
  git -C "$r" checkout -q -b other; git -C "$r" mv a.txt c.txt; git -C "$r" commit -q -m theirs
  git -C "$r" checkout -q main; git -C "$r" mv a.txt b.txt; git -C "$r" commit -q -m ours
  git -C "$r" merge -q other >/dev/null 2>&1
  printf '%s\n' "$r"
}
# um_hook <repo>: a pre-commit whose user lines (past the ritual block, which fix then inserts
# after the shebang) resolve $UM_PATH with new content, then record what they left in $UM_SNAP.*.
um_hook() {
  printf '%s\n' '#!/usr/bin/env sh' 'if [ -n "${UM_PATH:-}" ]; then' \
    '  echo hook-resolved > "$UM_PATH"' \
    '  git --literal-pathspecs add -- "$UM_PATH"' \
    '  git --literal-pathspecs ls-files -s -- "$UM_PATH" > "$UM_SNAP.idx"' \
    '  git --literal-pathspecs status --porcelain=v1 -- "$UM_PATH" > "$UM_SNAP.st"' \
    '  echo ran > "$UM_SNAP.ran"' 'fi' > "$1/.git/hooks/pre-commit"
  chmod +x "$1/.git/hooks/pre-commit"
}
# Prediction (read from _ss_changed before running): the path is not "unstaged" (X is D, A or U),
# and unmerged() keeps it out of the staged restore, so nothing is written back; all-with-index
# names it with the --unresolve remedy. The hook exits 0 (its last command succeeds).
um_case() {
  local code="$1" p="$2" name="unmerged_${1}_fails_closed" r snap x0 s0 out want s1 ok_fix=1
  r="$(rr_merge "um-$code")"; um_hook "$r"
  D fix secret-scan "$r" >/dev/null
  x0="$(git -C "$r" status --porcelain=v1 -- "$p")"
  if [ "$x0" != "$code $p" ]; then
    bad "$name: fixture produced '$x0', not '$code $p'; not testing the wrong state"; return 0
  fi
  [ "$(git -C "$r" ls-files -u | wc -l | tr -d ' ')" = 3 ] || ok_fix=0
  s0="$(state_of "$r")"; snap="$TMPROOT/um snap $code"; rm -f "$snap".*
  out="$( export UM_PATH="$p" UM_SNAP="$snap"; P check secret-scan "$r" )"
  want="the pre-commit hook changed the work tree or index during the proof (exit 0) and it could not be undone: \"$p\" was unmerged before the proof; the hook changed it; restore the conflict with \`git update-index --unresolve -- \"$p\"\`"
  s1="$(state_of "$r")"
  if [ "$ok_fix" = 1 ] && [ -e "$snap.ran" ] && [ "$(st "$out")" = failed ] && [ "$(dt "$out")" = "$want" ] \
    && [ "$(git -C "$r" ls-files -s -- "$p")" = "$(cat "$snap.idx")" ] && [ "$(cut -f2 "$snap.idx")" = "$p" ] \
    && [ "$(cut -d' ' -f3 "$snap.idx" | cut -f1)" = 0 ] \
    && [ "$(git -C "$r" status --porcelain=v1 -- "$p")" = "$(cat "$snap.st")" ] \
    && [ "$(without "$s1" "$p")" = "$(without "$s0" "$p")" ] \
    && [ "$(proof_leftovers "$r")" = 0 ] && [ "$(idx_count "$r")" = 0 ]; then
    ok "$name"
  else
    bad "$name: ran=$([ -e "$snap.ran" ] && echo y) out=$out / idx now [$(git -C "$r" ls-files -s -- "$p")] hook left [$(cat "$snap.idx" 2>/dev/null)] / status [$(git -C "$r" status --porcelain=v1)]"
  fi
  # the remedy the detail names brings the conflict back exactly
  git -C "$r" update-index --unresolve -- "$p"
  [ "$(state_of "$r")" = "$s0" ] && ok "unmerged_${code}_remedy_restores_conflict" \
    || bad "unmerged_${code}_remedy_restores_conflict: $(git -C "$r" status --porcelain=v1) / $(git -C "$r" ls-files -s)"
}
um_case DD a.txt
um_case AU b.txt
um_case UA c.txt

# unmerged_and_proof_fires: mid-conflict, the proof fires. The ritual block runs first in the hook,
# so the user lines that would resolve a.txt never run: present, and every unmerged stage, the
# status and the work tree are exactly as before. Prediction: present "proved: git hook run
# pre-commit blocked a staged fake key (exit 1) via <top>/.git/hooks/pre-commit".
r="$(rr_merge um-fires)"; um_hook "$r"; D fix secret-scan "$r" >/dev/null
x0="$(git -C "$r" status --porcelain=v1 | tr '\n' ' ')"
if [ "$x0" != "DD a.txt AU b.txt UA c.txt " ]; then
  bad "unmerged_and_proof_fires: fixture produced '$x0', not DD/AU/UA"
else
  s0="$(state_of "$r")"; b0="$(sha256sum "$r/b.txt" "$r/c.txt")"; snap="$TMPROOT/um snap fires"; rm -f "$snap".*
  out="$( export UM_PATH=a.txt UM_SNAP="$snap"; D check secret-scan "$r" )"
  [ "$(st "$out")" = present ] && [[ "$(dt "$out")" == "proved: git hook run pre-commit blocked a staged fake key (exit 1) via "*"/.git/hooks/pre-commit" ]] \
    && [ ! -e "$snap.ran" ] && [ "$(state_of "$r")" = "$s0" ] && [ "$(sha256sum "$r/b.txt" "$r/c.txt")" = "$b0" ] && [ ! -e "$r/a.txt" ] \
    && [ "$(proof_leftovers "$r")" = 0 ] && [ "$(idx_count "$r")" = 0 ] \
    && ok "unmerged_and_proof_fires" || bad "unmerged_and_proof_fires: ran=$([ -e "$snap.ran" ] && echo y) $out / $(git -C "$r" status --porcelain=v1)"
fi

echo "== HUP during the proof =="
# hup_during_proof_end_to_end: HUP to the whole job while the slow stub runs inside the proof. The
# ritual records it, lets the proof clean up and restore, then reports. Prediction: exit 129;
# failed "interrupted by SIGHUP during the proof; the proof file was removed; proof result: failed:
# the ritual block is in <hook>, but the proof did not fire: git hook run pre-commit exited 129 ...";
# no proof file on disk or staged; status and index exactly as before.
r="$(mkrepo hup)"; D fix secret-scan "$r" >/dev/null
echo s > "$r/staged.txt"; git -C "$r" add staged.txt; echo more >> "$r/README.md"; echo u > "$r/untracked.txt"
s0="$(state_of "$r")"; mark="$TMPROOT/hup.mark"; rm -f "$mark"
set -m
( stub_path "$SLOW"; export SLOW_MARK="$mark"; exec bash "$RITUAL" check secret-scan "$r" > "$TMPROOT/hup.out" 2>/dev/null ) &
pid=$!
set +m
if wait_mark "$mark"; then
  spid="$(cat "$mark")"; mid="$(idx_count "$r")"
  kill -HUP -- "-$pid" 2>/dev/null || kill -HUP "$pid"
  wait "$pid"; hrc=$?
  ho="$(cat "$TMPROOT/hup.out")"; hd="$(dt "$ho" 2>/dev/null)"
  left="$(proof_leftovers "$r")/$(idx_count "$r")"; s1="$(state_of "$r")"
  [ "$mid" = 1 ] && [ "$hrc" = 129 ] && [ "$(st "$ho")" = failed ] \
    && [[ "$hd" == "interrupted by SIGHUP during the proof; the proof file was removed; proof result: failed: the ritual block is in "*"exited 129"* ]] \
    && [ "$left" = 0/0 ] && [ "$s1" = "$s0" ] \
    && ok "hup_during_proof_end_to_end" || bad "hup_during_proof_end_to_end: mid=$mid rc=$hrc left=$left out=$ho / $(git -C "$r" status --porcelain=v1)"
  wait_gone "$spid" || echo "  NOTE: the slow stub ($spid) outlived the HUP test by 10 s"
else
  kill -KILL -- "-$pid" 2>/dev/null; wait "$pid"
  bad "hup_during_proof_end_to_end: the slow stub never started (no mark)"
fi

echo "== SIGKILL during fix, then a rerun =="
# sigkill_during_fix_rerun_recovers: a v1 block in a hooks path inside the work tree; fix upgrades
# it, then SIGKILL hits the job while it proves the upgraded block. Nothing can clean up.
# Prediction of what is left: exit 137, no result printed, the proof file on disk AND staged, the
# hook already v2 (the rename happened before the proof), no hook temp file. Then a hook temp file
# as a kill between _ss_atomic_write's mktemp and mv leaves it is planted (R16: it shows as
# untracked). The rerun: already "removed 1 leftover proof file(s) from an interrupted run; removed
# 1 leftover hook temp file(s) from an interrupted run; ritual block already in <hook>; proved: ...",
# block v2, and the status exactly what it was before the killed run.
r="$(mkrepo kill9)"; git -C "$r" config core.hooksPath "$WT_HOOKS"; mkdir -p "$r/$WT_HOOKS"; h="$r/$WT_HOOKS/pre-commit"
{ printf '%s\n' '#!/usr/bin/env sh'; cat "$V1_BLOCK"; } > "$h"; chmod +x "$h"
v0="$(ss_lib _ss_block_state "$h")"; p0="$(git -C "$r" status --porcelain=v1 --untracked-files=all)"
mark="$TMPROOT/kill.mark"; rm -f "$mark"
set -m
( stub_path "$SLOW"; export SLOW_MARK="$mark"; exec bash "$RITUAL" fix secret-scan "$r" > "$TMPROOT/kill.out" 2>/dev/null ) &
pid=$!
set +m
if wait_mark "$mark"; then
  spid="$(cat "$mark")"
  kill -KILL -- "-$pid" 2>/dev/null || kill -KILL "$pid"
  wait "$pid" 2>/dev/null; krc=$?
  gone=1; wait_gone "$spid" || gone=0
  left="disk=$(proof_leftovers "$r") staged=$(idx_count "$r") v=$(ss_lib _ss_block_version "$h") temps=$(hook_temps "$r/$WT_HOOKS") out=$(wc -c < "$TMPROOT/kill.out" | tr -d ' ')"
  tmpf="$(mktemp "$r/$WT_HOOKS/.ritual-pre-commit.XXXXXX")"; printf 'partial\n' > "$tmpf"
  seen_untracked="$(git -C "$r" status --porcelain=v1 --untracked-files=all | grep -c 'ritual-pre-commit\.')"
  out="$(D fix secret-scan "$r")"; d="$(dt "$out")"
  [ "$v0" = stale ] && [ "$krc" = 137 ] && [ "$gone" = 1 ] && [ "$left" = "disk=1 staged=1 v=2 temps=0 out=0" ] && [ "$seen_untracked" = 1 ] \
    && [ "$(st "$out")" = already ] \
    && [[ "$d" == "removed 1 leftover proof file(s) from an interrupted run; removed 1 leftover hook temp file(s) from an interrupted run; ritual block already in $(git -C "$r" rev-parse --show-toplevel)/$WT_HOOKS/pre-commit; proved: git hook run pre-commit blocked a staged fake key (exit 1) via "* ]] \
    && [ "$(ss_lib _ss_block_version "$h")" = 2 ] && [ ! -e "$tmpf" ] && [ "$(hook_temps "$r/$WT_HOOKS")" = 0 ] \
    && [ "$(proof_leftovers "$r")" = 0 ] && [ "$(idx_count "$r")" = 0 ] \
    && [ "$(git -C "$r" status --porcelain=v1 --untracked-files=all)" = "$p0" ] \
    && ok "sigkill_during_fix_rerun_recovers" \
    || bad "sigkill_during_fix_rerun_recovers: v0=$v0 rc=$krc gone=$gone left[$left] untracked=$seen_untracked rerun=$out / $(git -C "$r" status --porcelain=v1 --untracked-files=all)"
else
  kill -KILL -- "-$pid" 2>/dev/null; wait "$pid"
  bad "sigkill_during_fix_rerun_recovers: the slow stub never started (no mark)"
fi

echo "== sweep of stale hook temp files (R16) =="
# sweep_removes_stale_hook_temp: a temp file made by the same mktemp template _ss_atomic_write
# uses, in the default hooks dir, is removed by the sweep, and the note names it as the proof
# leftovers are named. Prediction: "removed 1 leftover hook temp file(s) from an interrupted run; ".
r="$(mkrepo sweep)"; tmpf="$(mktemp "$r/.git/hooks/.ritual-pre-commit.XXXXXX")"; echo partial > "$tmpf"
note="$(ss_lib _ss_sweep "$r")"
[ -n "$tmpf" ] && [ ! -e "$tmpf" ] && [ "$note" = "removed 1 leftover hook temp file(s) from an interrupted run; " ] \
  && ok "sweep_removes_stale_hook_temp" || bad "sweep_removes_stale_hook_temp: note=[$note] left=$(hook_temps "$r/.git/hooks")"

# sweep_pattern_matches_every_mktemp_name: 40 names from that template, all swept: the glob is
# checked against what mktemp really produces, not against a name typed here.
r="$(mkrepo sweep-many)"
for i in $(seq 1 40); do mktemp "$r/.git/hooks/.ritual-pre-commit.XXXXXX" >/dev/null; done
n0="$(hook_temps "$r/.git/hooks")"; note="$(ss_lib _ss_sweep "$r")"
[ "$n0" = 40 ] && [ "$(hook_temps "$r/.git/hooks")" = 0 ] && [ "$note" = "removed 40 leftover hook temp file(s) from an interrupted run; " ] \
  && ok "sweep_pattern_matches_every_mktemp_name" || bad "sweep_pattern_matches_every_mktemp_name: made=$n0 left=$(hook_temps "$r/.git/hooks") note=[$note]"

# sweep_keeps_user_files_in_hooks_dir: only regular files named exactly as the template names them
# go. A user's .ritual-pre-commit-notes (a dash, not the template's dot), names with 3 or 7
# characters after the dot, a directory with a template-shaped name, and the hook itself survive;
# one real temp beside them is the control that the sweep ran.
r="$(mkrepo sweep-keep)"; g="$r/.git/hooks"
for f in .ritual-pre-commit-notes .ritual-pre-commit.bak .ritual-pre-commit.abcdefg pre-commit.orig; do echo keep > "$g/$f"; done
mkdir -p "$g/.ritual-pre-commit.DIR123"; printf '#!/bin/sh\ntrue\n' > "$g/pre-commit"
tmpf="$(mktemp "$g/.ritual-pre-commit.XXXXXX")"
note="$(ss_lib _ss_sweep "$r")"
kept=0; for f in .ritual-pre-commit-notes .ritual-pre-commit.bak .ritual-pre-commit.abcdefg pre-commit.orig pre-commit; do [ -f "$g/$f" ] && kept=$((kept + 1)); done
[ ! -e "$tmpf" ] && [ "$kept" = 5 ] && [ -d "$g/.ritual-pre-commit.DIR123" ] && [ "$note" = "removed 1 leftover hook temp file(s) from an interrupted run; " ] \
  && ok "sweep_keeps_user_files_in_hooks_dir" || bad "sweep_keeps_user_files_in_hooks_dir: kept=$kept tmp=$([ -e "$tmpf" ] && echo left) note=[$note] $(ls -A "$g")"

# sweep_note_reaches_check_detail: through check, the note leads the detail of a present result.
r="$(mkrepo sweep-check)"; D fix secret-scan "$r" >/dev/null; tmpf="$(mktemp "$r/.git/hooks/.ritual-pre-commit.XXXXXX")"
out="$(D check secret-scan "$r")"
[ "$(st "$out")" = present ] && [[ "$(dt "$out")" == "removed 1 leftover hook temp file(s) from an interrupted run; proved: "* ]] && [ ! -e "$tmpf" ] \
  && ok "sweep_note_reaches_check_detail" || bad "sweep_note_reaches_check_detail: $out"

# sweep_follows_symlinked_hook: _ss_atomic_write puts its temp file beside the symlink's TARGET,
# so that is where the sweep looks. Needs real symlinks: Git Bash copies unless MSYS asks for
# native ones (which Windows grants only with developer mode or admin); Linux ignores MSYS.
r="$(mkrepo sweep-link)"; tgt="$r/real hooks"; mkdir -p "$tgt"; printf '#!/bin/sh\ntrue\n' > "$tgt/pre-commit"; chmod +x "$tgt/pre-commit"
MSYS=winsymlinks:nativestrict ln -s "$tgt/pre-commit" "$r/.git/hooks/pre-commit" 2>/dev/null
if [ -L "$r/.git/hooks/pre-commit" ]; then
  tmpf="$(mktemp "$tgt/.ritual-pre-commit.XXXXXX")"; note="$(ss_lib _ss_sweep "$r")"
  [ ! -e "$tmpf" ] && [ "$note" = "removed 1 leftover hook temp file(s) from an interrupted run; " ] \
    && ok "sweep_follows_symlinked_hook" || bad "sweep_follows_symlinked_hook: note=[$note] left=$(hook_temps "$tgt")"
else
  echo "  SKIP: sweep_follows_symlinked_hook (NOTE: ln -s made no symlink here; runs on Linux)"; skips=$((${skips:-0} + 1))
fi

echo "== writes through a symlinked hook =="
# {insert,upgrade}_through_symlinked_hook: _ss_atomic_write rewrites a symlinked hook at its
# target (mktemp and the rename there), so the link stays a link. The target's bytes are built
# from parts: the user's lines kept around the current block. No temp file is left beside the
# link or the target. Same symlink probe and SKIP as sweep_follows_symlinked_hook.
# lk_case <name> <target before> <target after> <detail prefix>
lk_case() {
  local name="$1" r tgt h l0 out
  r="$(mkrepo "$name")"; tgt="$r/real hooks"; h="$r/.git/hooks/pre-commit"; mkdir -p "$tgt"
  printf '%s' "$2" > "$tgt/pre-commit"; chmod +x "$tgt/pre-commit"
  MSYS=winsymlinks:nativestrict ln -s "$tgt/pre-commit" "$h" 2>/dev/null
  if [ ! -L "$h" ]; then
    echo "  SKIP: $name (NOTE: ln -s made no symlink here; runs on Linux)"; skips=$((${skips:-0} + 1)); return 0
  fi
  l0="$(readlink -- "$h")"; printf '%s' "$3" > "$TMPROOT/$name.want"
  out="$(D fix secret-scan "$r")"
  [ "$(st "$out")" = fixed ] && [[ "$(dt "$out")" == "$4"* ]] \
    && [ -L "$h" ] && [ "$(readlink -- "$h")" = "$l0" ] && cmp -s "$tgt/pre-commit" "$TMPROOT/$name.want" \
    && [ "$(hook_temps "$tgt")" = 0 ] && [ "$(hook_temps "$r/.git/hooks")" = 0 ] \
    && ok "$name" || bad "$name: link=$([ -L "$h" ] && echo yes || echo no) temps=$(hook_temps "$tgt")+$(hook_temps "$r/.git/hooks") $out $(diff "$tgt/pre-commit" "$TMPROOT/$name.want" | head -n 5)"
}
v2="$(ss_lib _ss_content_new | tail -n +2)"$'\n'
lk_case insert_through_symlinked_hook $'#!/bin/sh\necho user-line\n' $'#!/bin/sh\n'"$v2"$'echo user-line\n' \
  "inserted the gitleaks block after the shebang of "
lk_case upgrade_through_symlinked_hook $'#!/bin/sh\necho before\n'"$(cat "$V1_BLOCK")"$'\necho after\n' \
  $'#!/bin/sh\necho before\n'"$v2"$'echo after\n' "upgraded ritual block v1 → v2; proved: "
echo "  SKIPPED: ${skips:-0}"

finish
