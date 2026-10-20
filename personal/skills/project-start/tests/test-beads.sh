#!/usr/bin/env bash
# Tests: beads step (house files, check beads, check beads-metrics, fix beads on a clean tree, real
# bd), against a stub bd. The bd variants and the stash cases live in test-beads-variants.sh and
# test-beads-stash.sh, so the three run in parallel; beads-fixture.sh holds what they share.
. "$(dirname "${BASH_SOURCE[0]}")/beads-fixture.sh"

# ============================== house files
[ "$(grep -c 'must name the observation' "$HOUSE/beads/PRIME.md")" = 0 ] && [ "$(grep -c 'names the observation' "$HOUSE/beads/PRIME.md")" = 0 ] \
  && ok "house_prime_lacks_killed_close_rule" || bad "PRIME.md still carries the retired close rule"
[ "$(grep -c bleeding "$HOUSE/beads/PRIME.md")" -ge 1 ] && ok "house_prime_has_bleeding_label (control)" || bad "PRIME.md lacks bleeding"
[ "$(head -n 1 "$HOUSE/claude-md-override.md")" = '## Task tracking vs. execution structure' ] \
  && ok "house_override_heading_is_what_check_block_looks_for" || bad "override heading: $(head -n 1 "$HOUSE/claude-md-override.md")"
grep -qx 'interactions.jsonl' "$HOUSE/beads/gitignore" && grep -qx 'backup/' "$HOUSE/beads/gitignore" \
  && ok "house_gitignore_lines" || bad "house gitignore"
cr=0; for f in "$HOUSE/beads/PRIME.md" "$HOUSE/beads/check-block.sh" "$HOUSE/beads/gitignore" "$HOUSE/claude-md-override.md"; do
  od -An -tx1 "$f" | grep -q ' 0d' && cr=1; done
printf 'a\r\n' > "$TMPROOT/crctl"; od -An -tx1 "$TMPROOT/crctl" | grep -q ' 0d' && [ "$cr" = 0 ] \
  && ok "house_files_are_lf (control sees a CR)" || bad "house files carry CR bytes (or CR probe blind)"

# ============================== check beads
r="$(mkrepo)"
out="$(NB check beads "$r")"
[ "$(st "$out")" = unknown ] && ok "check_unknown_without_bd" || bad "no bd: $out"

r="$(mkrepo)"
out="$(R check beads "$r")"
[ "$(st "$out")" = absent ] && dt "$out" | grep -q '\.beads/' && ok "check_absent_when_no_dir" || bad "no dir: $out"
# Not a discriminating test on its own: with no .beads/ the directory gate answers before any key is
# read. The real proof that keys come from .beads/config.yaml and never from `bd config get` is the
# check_requires_* loop below, because the stub's `config get` answers `true` for every key there.
out="$(STUB_GET=true R check beads "$r")"
[ "$(st "$out")" = absent ] && ok "check_ignores_user_level_config" || bad "user-level config leaked: $out"

r="$(mkrepo)"; mkhouse "$r" .beads/hooks
out="$(R check beads "$r")"
[ "$(st "$out")" = present ] && ok "check_present_relative_hookspath" || bad "relative present: $out"
r="$(mkrepo)"; mkhouse "$r" "$(cygpath -w "$r/.beads/hooks")"
out="$(R check beads "$r")"
[ "$(st "$out")" = present ] && ok "check_absolute_hookspath_is_present" || bad "absolute windows form: $(git -C "$r" config core.hooksPath) -> $out"
r="$(mkrepo)"; mkhouse "$r" .git/hooks
out="$(R check beads "$r")"
[ "$(st "$out")" = absent ] && dt "$out" | grep -q 'core.hooksPath' && ok "check_wrong_hookspath_is_absent" || bad "wrong hooksPath: $out"

r="$(mkrepo)"; mkhouse "$r" -
printf 'no-push: true\ndolt:\n    local-only: true\nexport:\n    auto: false\n    git-add: true\n' > "$r/.beads/config.yaml"
out="$(R check beads "$r")"; d="$(dt "$out")"
[ "$(st "$out")" = absent ] && grep -q 'export.auto' <<<"$d" && grep -q 'core.hooksPath' <<<"$d" \
  && ! grep -q 'export.git-add' <<<"$d" && ! grep -q 'gitattributes' <<<"$d" && ! grep -q 'check-block' <<<"$d" \
  && ok "check_names_each_failing_condition" || bad "names: $out"

for k in export.auto export.git-add no-push dolt.local-only; do
  r="$(mkrepo)"; mkhouse "$r" .beads/hooks
  case "$k" in
    export.auto)     printf 'no-push: true\ndolt:\n    local-only: true\nexport:\n    git-add: true\n' ;;
    export.git-add)  printf 'no-push: true\ndolt:\n    local-only: true\nexport:\n    auto: true\n' ;;
    no-push)         printf '# no-push: true\ndolt:\n    local-only: true\nexport:\n    auto: true\n    git-add: true\n' ;;
    dolt.local-only) printf 'no-push: true\ndolt:\n    local-only: false\nexport:\n    auto: true\n    git-add: true\n' ;;
  esac > "$r/.beads/config.yaml"
  out="$(R check beads "$r")"
  [ "$(st "$out")" = absent ] && dt "$out" | grep -qF "$k" && ok "check_requires_$k" || bad "$k: $out"
done
r="$(mkrepo)"; mkhouse "$r" .beads/hooks
printf 'export.auto: true\nexport.git-add: "true"\nno-push: true\ndolt.local-only: true\n' > "$r/.beads/config.yaml"
out="$(R check beads "$r")"
[ "$(st "$out")" = present ] && ok "check_reads_flat_dotted_keys" || bad "flat keys: $out"
r="$(mkrepo)"; mkhouse "$r" .beads/hooks
printf '%s\n' '.beads/hooks/* text eol=lf' '.beads/issues.jsonl -text' > "$r/.gitattributes"
out="$(R check beads "$r")"
[ "$(st "$out")" = absent ] && dt "$out" | grep -q 'gitattributes' && ok "check_requires_gitattributes_lines" || bad "gitattributes: $out"
r="$(mkrepo)"; mkhouse "$r" .beads/hooks
printf '%s\n' '<!-- BEGIN BEADS INTEGRATION -->' '- Use `bd` for ALL task tracking — do NOT use TodoWrite' '<!-- END BEADS INTEGRATION -->' '' > "$r/CLAUDE.md"
cat "$HOUSE/claude-md-override.md" >> "$r/CLAUDE.md"
out="$(R check beads "$r")"
[ "$(st "$out")" = absent ] && dt "$out" | grep -q 'check-block' && ok "check_requires_check_block_pass" || bad "check-block: $out"
r="$(mkrepo)"; mkhouse "$r" .beads/hooks; rm "$r/.beads/check-block.sh"
out="$(R check beads "$r")"
[ "$(st "$out")" = absent ] && dt "$out" | grep -q 'check-block.sh missing' && ok "check_requires_check_block_file" || bad "no check-block: $out"

# ============================== check beads-metrics
r="$(mkrepo)"
[ "$(st "$(STUB_METRICS=true R check beads-metrics "$r")")" = present ] && ok "metrics_present_when_disabled_true" || bad "metrics true"
out="$(STUB_METRICS=false R check beads-metrics "$r")"
[ "$(st "$out")" = absent ] && ok "metrics_absent_when_disabled_false" || bad "metrics false"
dt "$out" | grep -qF 'bd config set metrics.disabled true' && ok "metrics_absent_names_the_command_that_turns_it_off" || bad "metrics absent detail: $out"
[ "$(st "$(STUB_METRICS=maybe R check beads-metrics "$r")")" = unknown ] && ok "metrics_unknown_on_unparseable_answer" || bad "metrics garbage"
[ "$(st "$(NB check beads-metrics "$r")")" = unknown ] && ok "metrics_unknown_without_bd" || bad "metrics no bd"

# ============================== fix beads: clean tree, full sequence
r="$(mkrepo "Beads Repo")"; logclear
head0="$(git -C "$r" rev-parse HEAD)"
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && ok "fix_clean_tree_fixed" || bad "fix clean: $out"
grep -qx 'init --non-interactive --prefix beadsrepo' "$LOG" && ok "fix_init_prefix_from_spaced_basename" || bad "init argv: $(cat "$LOG")"
grep -qx 'dolt remote remove origin' "$LOG" && ok "fix_removes_dolt_remote" || bad "no dolt remote remove"
n=0; for kv in 'export.auto true' 'export.git-add true' 'no-push true' 'dolt.local-only true' 'export.interval 1ms'; do
  grep -qx "config set $kv" "$LOG" && n=$((n + 1)); done
[ "$n" = 5 ] && ok "fix_sets_house_config_incl_interval" || bad "config sets: $n of 5"
grep -qx 'export.interval: 1ms' "$r/.beads/config.yaml" && ok "fix_config_yaml_has_interval_1ms" || bad "interval not in config.yaml"
[ "$(git -C "$r" config core.hooksPath)" = .beads/hooks ] && ok "fix_sets_relative_hookspath" || bad "hooksPath: $(git -C "$r" config core.hooksPath)"
cmp -s "$r/.beads/PRIME.md" "$HOUSE/beads/PRIME.md" && ok "fix_copies_prime" || bad "PRIME.md"
cmp -s "$r/.beads/check-block.sh" "$HOUSE/beads/check-block.sh" && ok "fix_copies_check_block" || bad "check-block.sh"
printf '# Dolt database\nembeddeddolt/\n\n' > "$TMPROOT/exp.gi"; cat "$HOUSE/beads/gitignore" >> "$TMPROOT/exp.gi"
cmp -s "$r/.beads/.gitignore" "$TMPROOT/exp.gi" && ok "fix_appends_house_gitignore" || bad "beads gitignore: $(cat "$r/.beads/.gitignore")"
for l in '.beads/hooks/* text eol=lf' '.beads/*.sh text eol=lf' '.beads/issues.jsonl -text'; do grep -qxF "$l" "$r/.gitattributes" || cr=x; done
[ "$cr" != x ] && ok "fix_appends_gitattributes" || bad "gitattributes: $(cat "$r/.gitattributes")"
git -C "$r" cat-file -e HEAD:.beads/interactions.jsonl 2>/dev/null && ! git -C "$r" ls-files --error-unmatch .beads/interactions.jsonl >/dev/null 2>&1   && ok "fix_untracks_interactions_jsonl (bd committed it)" || bad "interactions.jsonl: still tracked, or bd never committed it"
[ -f "$r/.beads/interactions.jsonl" ] && ok "fix_keeps_interactions_file_on_disk" || bad "interactions.jsonl deleted from disk"
git -C "$r" cat-file -e HEAD:AGENTS.md 2>/dev/null && git -C "$r" cat-file -e HEAD:.codex/config.toml 2>/dev/null   && [ ! -e "$r/AGENTS.md" ] && [ ! -e "$r/.codex" ] && [ ! -e "$r/.agents/skills/beads" ] && ok "fix_removes_bd_agents_md" || bad "bd codex files left: $(ls -A "$r")"
grep -q '^## Task tracking vs. execution structure' "$r/CLAUDE.md" && ok "fix_appends_override" || bad "override missing"
! grep -q 'do NOT use TodoWrite' "$r/CLAUDE.md" && ! grep -q 'do NOT use MEMORY.md' "$r/CLAUDE.md" && grep -q 'BEGIN BEADS INTEGRATION' "$r/CLAUDE.md" \
  && ok "fix_edits_bans_out_of_new_block" || bad "bans left in block"
(cd "$r" && sh .beads/check-block.sh >/dev/null) && ok "fix_check_block_passes" || bad "check-block fails after fix"
grep -q '^init ' "$LOG" && ! grep -q 'setup claude' "$LOG" && ok "fix_setup_claude_not_rerun" || bad "setup claude rerun though init wrote the marker (or bd never ran)"
[ "$(st "$(R check beads "$r")")" = present ] && ok "fix_then_check_present" || bad "check after fix: $(R check beads "$r")"
[ "$(git -C "$r" rev-list --count "$head0"..HEAD)" = 1 ] && ok "fix_only_bd_init_committed" || bad "commits: $(git -C "$r" log --oneline "$head0"..HEAD)"
w="$(jq -c '.wrote|sort' <<<"$out")"
for p in .beads/config.yaml .beads/PRIME.md .beads/check-block.sh .beads/.gitignore .gitattributes .beads/interactions.jsonl CLAUDE.md AGENTS.md .codex/config.toml .agents/skills/beads/SKILL.md; do
  jq -e --arg p "$p" 'index($p)' <<<"$w" >/dev/null || { bad "wrote lacks $p: $w"; w=MISSING; }; done
[ "$w" != MISSING ] && [ "$(jq length <<<"$w")" = 10 ] && ok "fix_wrote_lists_exactly_the_changed_paths" || bad "wrote: $w"
grep -qx 'dolt remote list' "$LOG" && ! dt "$out" | grep -q 'unverified' && ok "fix_dolt_no_remotes_answer_is_verified" || bad "no-remotes answer: $out"

# rerun
w1="$(jq -c '.wrote|sort' <<<"$out")"
logclear; out="$(R fix beads "$r")"
[ "$(st "$out")" = already ] && [ "$(logn)" = 0 ] \
  && ok "fix_rerun_already" || bad "rerun: $out; log=$(cat "$LOG")"
# I1: the fix was never committed, so the rerun lists exactly what the fix wrote, for the commit step
[ "$(jq -c '.wrote|sort' <<<"$out")" = "$w1" ] && [ "$(jq length <<<"$w1")" = 10 ] && dt "$out" | grep -qF 'not yet committed' \
  && ok "fix_rerun_lists_the_uncommitted_house_files" || bad "rerun wrote: $(jq -c '.wrote|sort' <<<"$out") vs fix $w1"
git -C "$r" add -A && git -C "$r" commit -q --no-verify -m 'ritual'
logclear; out="$(R fix beads "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && [ "$(logn)" = 0 ] \
  && ok "fix_rerun_after_the_commit_lists_nothing" || bad "rerun after commit: $out; log=$(cat "$LOG")"
# R58: SKILL.md runs `fix beads` with no flags when check beads says present. On a set-up repo that
# is a no-op even with the user's work dirty: no bd call (so no init), no stash, no byte written.
snap() {
  git -C "$1" stash list; git -C "$1" rev-parse HEAD; git -C "$1" config --get core.hooksPath
  sha256sum "$(git -C "$1" rev-parse --absolute-git-dir | tr -d '\r')/index" | cut -d' ' -f1
  (cd "$1" && find . -path ./.git -prune -o -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)
}
echo mine >> "$r/README.md"; echo new > "$r/user note.txt"
[ "$(st "$(R check beads "$r")")" = present ] && s0="$(snap "$r")" && logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && [ "$(logn)" = 0 ] && [ "$(snap "$r")" = "$s0" ] \
  && [ -z "$(git -C "$r" stash list)" ] && [ "$(wc -l <<<"$s0")" -gt 10 ] \
  && ok "r58_fix_beads_on_a_set_up_dirty_repo_is_a_no_op" || bad "r58 no-op: $out; log=$(cat "$LOG"); stash=$(git -C "$r" stash list)"
# ...and the R36 held-stash refusal still comes before that no-op
git -C "$r" stash push -q -m ritual-beads; logclear
out="$(R fix beads "$r")"
[ "$(st "$(R check beads "$r")")" = present ] && [ "$(st "$out")" = failed ] && dt "$out" | grep -qF 'still held' && [ "$(logn)" = 0 ] \
  && [ "$(git -C "$r" stash list | grep -c '')" = 1 ] && ok "r58_held_stash_refusal_comes_before_the_no_op" || bad "r58 held stash: $out"
git -C "$r" stash pop -q

# ============================== real bd (opt-in: RITUAL_REAL_BD=1)
# The real binary on a spaced temp repo (proves --prefix) whose `origin` is a local bare repo,
# never a network remote. The tree is dirty (an MM file and an untracked file), so the run goes
# through --stash around the real bd's own commit.
if [ "${RITUAL_REAL_BD:-}" = 1 ]; then
  if ! command -v bd >/dev/null 2>&1; then
    bad "real_bd: RITUAL_REAL_BD=1 but no bd on PATH"
  else
    echo "  (real bd: $(bd version 2>&1 | head -n 1))"
    r="$(mkrepo "Real Bd Repo")"; o="$TMPROOT/ritual fixtures/origin.git"
    git init -q --bare "$o"; git -C "$r" remote add origin "$o"; git -C "$r" push -q origin main 2>/dev/null
    printf 'v1\n' > "$r/mm.txt"; commit_all "$r" mm; git -C "$r" push -q origin main 2>/dev/null
    printf 'v2\n' >> "$r/mm.txt"; git -C "$r" add mm.txt; printf 'v3\n' >> "$r/mm.txt"; printf 'n\n' > "$r/notes.txt"
    pre="$(pf "$r")"
    out="$(bash "$RITUAL" fix beads "$r" --stash)"; post="$(pf "$r")"
    echo "  (real bd fix: $out)"
    [ "$(st "$out")" = fixed ] && ok "real_bd_fix_fixed" || bad "real bd fix: $out"
    [ "$(st "$(bash "$RITUAL" check beads "$r")")" = present ] && ok "real_bd_check_present" || bad "real bd check: $(bash "$RITUAL" check beads "$r")"
    [ -n "$(git -C "$r" ls-remote origin 'refs/heads/*')" ] && [ -z "$(git -C "$r" ls-remote origin 'refs/dolt/*')" ] \
      && ok "real_bd_no_dolt_refs_on_origin (control: heads visible)" || bad "real bd ls-remote: $(git -C "$r" ls-remote origin)"
    [ "$(git -C "$r" config core.hooksPath)" = .beads/hooks ] && ok "real_bd_hookspath_relative" || bad "real bd hooksPath: $(git -C "$r" config core.hooksPath)"
    grep -q 'invalid database name' <<<"$out" && bad "real bd rejected the prefix" || ok "real_bd_prefix_accepted_in_spaced_dir"
    same_user_state "$pre" "$post" && [ -z "$(git -C "$r" stash list)" ] && ok "real_bd_stash_roundtrip_exact" || bad "real bd stash: pre=$pre post=$post"
    echo "  (real bd commits: $(git -C "$r" log --format='%h %s' -3 | paste -sd '|' -))"
  fi
else
  echo "  SKIP: real bd integration (set RITUAL_REAL_BD=1)"
fi

finish
