#!/usr/bin/env bash
# Tests: beads step (check beads, fix beads [--stash], check beads-metrics), against a stub bd.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOUSE="$SKILL_DIR/house"
STUBDIR="$TMPROOT/stub bin"
LOG="$TMPROOT/bd.log"
mkdir -p "$STUBDIR"

# --- stub bd: logs argv, models the bd 1.2.2 side effects that matter here (measured on the real
# binary: init writes .beads/, CLAUDE.md block, AGENTS.md, .codex/, .agents/, root .gitignore, sets
# an ABSOLUTE core.hooksPath and commits; `dolt remote remove origin` errors when no Dolt remote
# exists; config set writes config.yaml without committing; setup/prime exit 255 on success).
cat > "$STUBDIR/bd" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_BD_LOG:?}"
rc="${STUB_BD_EXIT:-0}"
block() {
  printf '%s\n' '<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:stub -->' '## Beads Issue Tracker' '' '### Rules' '' \
    '- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists' \
    '- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files' \
    '<!-- END BEADS INTEGRATION -->'
}
addblock() {
  if [ -f "$1" ] && grep -q 'BEGIN BEADS INTEGRATION' "$1"; then return 0; fi
  if [ -n "${STUB_CRLF:-}" ]; then
    if [ -s "$1" ]; then printf '\r\n' >> "$1"; fi
    block | sed 's/$/\r/' >> "$1"
  else
    if [ -s "$1" ]; then printf '\n' >> "$1"; fi
    block >> "$1"
  fi
}
case "$1 ${2:-}" in
  "init "*)
    mkdir -p .beads/hooks
    printf '# Dolt database\nembeddeddolt/\n' > .beads/.gitignore
    : > .beads/interactions.jsonl
    if [ -n "${STUB_INIT_FAIL:-}" ]; then echo 'Error: produces an invalid database name' >&2; exit 1; fi
    printf '# Beads Configuration File\n# export:\n#   auto: false\nsync.remote: "git+origin"\n' > .beads/config.yaml
    printf '{"database":"dolt"}\n' > .beads/metadata.json
    printf '#!/usr/bin/env sh\nexit 0\n' > .beads/hooks/pre-commit
    printf '# Beads / Dolt files (added by bd init)\n.dolt/\n' >> .gitignore
    paths=(.beads .gitignore AGENTS.md .codex .agents)
    if [ -z "${STUB_NO_SETUP:-}" ]; then
      addblock CLAUDE.md; mkdir -p .claude; printf '{}\n' > .claude/settings.json; paths+=(CLAUDE.md .claude)
    fi
    addblock AGENTS.md
    mkdir -p .codex .agents/skills/beads
    printf 'x\n' > .codex/config.toml; printf 'x\n' > .agents/skills/beads/SKILL.md
    git config core.hooksPath "$(cygpath -w "$PWD/.beads/hooks")"
    git add -- "${paths[@]}" 2>/dev/null
    git commit -q -m 'bd init: initialize beads issue tracking' 2>/dev/null
    if [ -n "${STUB_INIT_MUTATE:-}" ]; then printf 'bd was here\n' >> "$STUB_INIT_MUTATE"; fi
    exit "$rc" ;;
  "dolt remote")
    case "${3:-}" in
      remove) [ -n "${STUB_REMOTE_STUCK:-}" ] && exit 0
              echo "Error removing remote: unknown remote: 'origin'" >&2; exit 1 ;;
      list)   if [ -n "${STUB_REMOTE_STUCK:-}" ]; then echo "origin  git+origin"; else echo "No remotes configured."; fi
              exit "$rc" ;;
    esac ;;
  "config set")
    f=.beads/config.yaml; grep -v "^$3:" "$f" > "$f.tmp"; printf '%s: %s\n' "$3" "$4" >> "$f.tmp"; mv "$f.tmp" "$f"
    exit "$rc" ;;
  "config get")
    if [ "$3" = metrics.disabled ]; then printf '%s\n' "${STUB_METRICS-true}"; else printf '%s\n' "${STUB_GET-true}"; fi
    exit "$rc" ;;
  "setup claude")
    addblock CLAUDE.md; mkdir -p .claude; printf '{}\n' > .claude/settings.json; exit 255 ;;
  "prime "*) exit 255 ;;
esac
exit "$rc"
STUB
chmod +x "$STUBDIR/bd"

R()  { ( stub_path "$STUBDIR"; export STUB_BD_LOG="$LOG"; bash "$RITUAL" "$@" ); }
NB() { ( PATH="$(path_without bd)"; export PATH STUB_BD_LOG="$LOG"; bash "$RITUAL" "$@" ); }
st() { jq -r .status <<<"$1"; }
dt() { jq -r .detail <<<"$1"; }
pf() { bash "$RITUAL" preflight "$1"; }
logclear() { : > "$LOG"; }
logn() { if [ -f "$LOG" ]; then grep -c '' "$LOG"; else echo 0; fi; }
commit_all() { git -C "$1" add -A && git -C "$1" commit -q -m "$2"; }
# same_user_state <pre> <post>: every path dirty in <pre> has the same XY, bytes and index in <post>
same_user_state() {
  jq -n --argjson a "$1" --argjson b "$2" '
    [$a.dirty[] | . as $d | ($b.dirty | map(select(.path == $d.path)) | .[0]) as $e
     | ($e != null and $e.xy == $d.xy and $b.bytes[$d.path] == $a.bytes[$d.path]
        and $b.index[$d.path] == $a.index[$d.path])] | all' | grep -qx true
}

# mkhouse <repo> <hooksPath|-> : a fully set-up beads repo built by hand (nested config.yaml,
# house .gitattributes lines, check-block.sh, a clean managed block + the override section).
mkhouse() {
  local r="$1"
  mkdir -p "$r/.beads/hooks"
  printf 'sync.remote: "git+origin"\nno-push: true\ndolt:\n    local-only: true\nexport:\n    auto: true\n    git-add: true\n' > "$r/.beads/config.yaml"
  printf '%s\n' '.beads/hooks/* text eol=lf' '.beads/*.sh text eol=lf' '.beads/issues.jsonl -text' > "$r/.gitattributes"
  cp "$HOUSE/beads/check-block.sh" "$r/.beads/check-block.sh"
  { printf '%s\n' '<!-- BEGIN BEADS INTEGRATION -->' '- Use bd for durable work.' '<!-- END BEADS INTEGRATION -->' ''
    cat "$HOUSE/claude-md-override.md"; } > "$r/CLAUDE.md"
  if [ "$2" != - ]; then git -C "$r" config core.hooksPath "$2"; fi
}

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
[ "$(st "$(STUB_METRICS=false R check beads-metrics "$r")")" = absent ] && ok "metrics_absent_when_disabled_false" || bad "metrics false"
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

# rerun
logclear; out="$(R fix beads "$r")"
[ "$(st "$out")" = already ] && [ "$(jq -c .wrote <<<"$out")" = '[]' ] && [ "$(logn)" = 0 ] \
  && ok "fix_rerun_already" || bad "rerun: $out; log=$(cat "$LOG")"

# ============================== fix beads: bd variants
r="$(mkrepo "Exit Repo")"; logclear
out="$(STUB_BD_EXIT=255 R fix beads "$r")"
[ "$(st "$out")" = fixed ] && [ "$(st "$(R check beads "$r")")" = present ] && ok "fix_exit_255_is_not_failure" || bad "exit 255: $out"

r="$(mkrepo "Setup Repo")"; logclear
out="$(STUB_NO_SETUP=1 R fix beads "$r")"
[ "$(st "$out")" = fixed ] && grep -qx 'setup claude' "$LOG" && ! grep -q 'do NOT use TodoWrite' "$r/CLAUDE.md" \
  && ok "fix_runs_setup_claude_when_marker_absent" || bad "setup claude path: $out; log=$(cat "$LOG")"

r="$(mkrepo "Stuck Repo")"; logclear
out="$(STUB_REMOTE_STUCK=1 R fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'dolt remote' && ok "fix_fails_when_dolt_remote_survives" || bad "stuck remote: $out"

r="$(mkrepo "Fail Repo")"; logclear
out="$(STUB_INIT_FAIL=1 R fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q '\.beads/\.gitignore' && [ -f "$r/.beads/.gitignore" ] \
  && ! grep -q 'config set' "$LOG" && ok "fix_init_failure_lists_leftovers_removes_nothing" || bad "init fail: $out"

r="$(mkrepo "Agents Repo")"; printf '# My agents\n' > "$r/AGENTS.md"; commit_all "$r" agents; logclear
out="$(R fix beads "$r")"
[ -f "$r/AGENTS.md" ] && head -n 1 "$r/AGENTS.md" | grep -qx '# My agents' && dt "$out" | grep -q 'AGENTS.md' \
  && [ ! -e "$r/.codex" ] && ok "fix_keeps_preexisting_agents_md_and_names_it" || bad "pre-existing AGENTS.md: $out"

r="$(mkrepo "Block Repo")"
printf '%s\n' '# Mine' '<!-- BEGIN BEADS INTEGRATION -->' '- Use `bd` for ALL task tracking — do NOT use TodoWrite' '<!-- END BEADS INTEGRATION -->' > "$r/CLAUDE.md"
commit_all "$r" claude; cp "$r/CLAUDE.md" "$TMPROOT/block.before"; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'check-block' && head -n 4 "$r/CLAUDE.md" | cmp -s - "$TMPROOT/block.before" \
  && ok "fix_never_edits_a_preexisting_block" || bad "pre-existing block: $out"

r="$(mkrepo "Crlf Claude")"; printf '# Mine\r\n\r\nKeep this.\r\n' > "$r/CLAUDE.md"; commit_all "$r" claude
cp "$r/CLAUDE.md" "$TMPROOT/claude.crlf"; logclear
out="$(STUB_CRLF=1 R fix beads "$r")"
bare_lf() { od -An -tx1 -v "$1" | tr -s ' ' '\n' | awk 'NF { if ($1 == "0a" && prev != "0d") n++; prev = $1 } END { print n + 0 }'; }
nlf="$(bare_lf "$r/CLAUDE.md")"
printf 'a\r\nb\nc\r\n' > "$TMPROOT/lfctl"; [ "$(bare_lf "$TMPROOT/lfctl")" = 1 ] && ok "bare_lf_counter_sees_one_lf (control)" || bad "bare_lf counter blind"
[ "$(st "$out")" = fixed ] && head -c "$(wc -c < "$TMPROOT/claude.crlf")" "$r/CLAUDE.md" | cmp -s - "$TMPROOT/claude.crlf" \
  && [ "$nlf" = 0 ] && grep -qF 'TodoWrite is a different layer' "$r/CLAUDE.md" \
  && ok "fix_unban_and_override_keep_crlf_and_user_bytes" || bad "crlf CLAUDE.md: $out; bare LF count=$nlf"

r="$(mkrepo "Have Beads")"; mkdir -p "$r/.beads"
printf 'sync.remote: "git+origin"\n' > "$r/.beads/config.yaml"; printf 'mine\n' > "$r/.beads/PRIME.md"
printf '%s\n' 'interactions.jsonl' > "$r/.beads/.gitignore"
commit_all "$r" beads; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && ! grep -q '^init' "$LOG" && grep -qx 'setup claude' "$LOG" && [ "$(cat "$r/.beads/PRIME.md")" = mine ] \
  && [ "$(grep -c 'interactions.jsonl' "$r/.beads/.gitignore")" = 1 ] \
  && ok "fix_existing_beads_skips_init_keeps_prime_appends_once" || bad "existing .beads: $out; log=$(cat "$LOG")"

r="$(mkrepo "Crlf Attr")"; printf '* text=auto\r\n' > "$r/.gitattributes"; commit_all "$r" attrs; logclear
R fix beads "$r" >/dev/null
printf '%s\r\n' '* text=auto' '' \
  '# Beads: the hook shims are POSIX sh, and issues.jsonl is compared byte-for-byte' \
  '# against `bd export` output (LF), so neither may be CRLF-converted on checkout.' \
  '.beads/hooks/* text eol=lf' '.beads/*.sh text eol=lf' '.beads/issues.jsonl -text' > "$TMPROOT/exp.ga"
cmp -s "$r/.gitattributes" "$TMPROOT/exp.ga" && ok "fix_appends_gitattributes_in_file_eol" || bad "gitattributes bytes: $(od -c "$r/.gitattributes" | head)"

r="$(mkrepo)"
[ "$(st "$(NB fix beads "$r")")" = unknown ] && ok "fix_unknown_without_bd" || bad "fix no bd"

# ============================== fix beads: dirty trees and the stash
r="$(mkrepo "Dirty Repo")"; echo more >> "$r/README.md"; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = failed ] && [ "$(dt "$out")" = 'dirty tree; re-run with --stash' ] && [ "$(logn)" = 0 ] \
  && ok "fix_refuses_dirty_without_stash" || bad "dirty no stash: $out; log=$(cat "$LOG")"

# stash_fixture <name> -> repo with an MM file, an unstaged edit, an untracked file, a CRLF edit
stash_fixture() {
  local r; r="$(mkrepo "$1")"
  printf 'v1\n' > "$r/mm.txt"; printf 'tracked\n' > "$r/edit.txt"; printf 'one\r\ntwo\r\n' > "$r/crlf.txt"
  commit_all "$r" fixture
  printf 'v2\n' >> "$r/mm.txt"; git -C "$r" add mm.txt; printf 'v3\n' >> "$r/mm.txt"
  printf 'edit\n' >> "$r/edit.txt"; printf 'three\r\n' >> "$r/crlf.txt"; printf 'new\n' > "$r/untracked.txt"
  printf '%s\n' "$r"
}
r="$(stash_fixture "Stash Repo")"; pre="$(pf "$r")"; logclear
[ "$(jq -r '.dirty[]|select(.path=="mm.txt")|.xy' <<<"$pre")" = MM ] && [ "$(jq '.dirty|length' <<<"$pre")" = 4 ] \
  && ok "stash_fixture_has_MM_and_four_dirty (control)" || bad "fixture: $pre"
out="$(R fix beads "$r" --stash)"; post="$(pf "$r")"
[ "$(st "$out")" = fixed ] && ok "fix_stash_fixed" || bad "stash fix: $out"
[ "$(git -C "$r" log -1 --format=%s)" = 'bd init: initialize beads issue tracking' ] && same_user_state "$pre" "$post" && ok "fix_stash_roundtrip_exact" || bad "roundtrip: pre=$pre post=$post"
[ "$(st "$out")" = fixed ] && [ -z "$(git -C "$r" stash list)" ] && ok "fix_stash_list_empty_after" || bad "stash left: $(git -C "$r" stash list)"
jq -e '.wrote | map(select(. == "mm.txt" or . == "edit.txt" or . == "crlf.txt" or . == "untracked.txt")) | length == 0' <<<"$out" >/dev/null \
  && ok "fix_stash_wrote_excludes_user_paths" || bad "wrote: $out"
same_user_state "$pre" "$(pf "$(mkrepo)")" && bad "same_user_state is blind" || ok "same_user_state_discriminates (control)"

r="$(mkrepo "Autocrlf Repo")"; git -C "$r" config core.autocrlf true
printf 'a\nb\n' > "$r/lf.txt"; commit_all "$r" lf 2>/dev/null
printf 'c\n' >> "$r/lf.txt"; printf 'u\n' > "$r/untr.txt"; printf 'p\nq\r\n' > "$r/mixed.txt"
pre="$(pf "$r")"; out="$(R fix beads "$r" --stash 2>/dev/null)"; post="$(pf "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" log -1 --format=%s)" = 'bd init: initialize beads issue tracking' ]   && same_user_state "$pre" "$post" && ok "fix_stash_roundtrip_exact_under_autocrlf" || bad "autocrlf: $out pre=$pre post=$post"

r="$(stash_fixture "Mutate Repo")"; logclear
out="$(STUB_INIT_MUTATE=README.md R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && dt "$out" | grep -q 'stash@{0}' \
  && dt "$out" | grep -q 'README.md' && ! grep -q 'config set' "$LOG" \
  && ok "fix_stash_mismatch_keeps_stash" || bad "mismatch: $out; stash=$(git -C "$r" stash list)"

r="$(stash_fixture "Collide Repo")"; logclear
out="$(STUB_INIT_MUTATE=edit.txt R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && ok "fix_stash_apply_conflict_keeps_stash" || bad "apply conflict: $out"

r="$(mkrepo "Claude Repo")"; printf 'my notes\n' > "$r/CLAUDE.md"; logclear
out="$(R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'CLAUDE.md' && [ "$(logn)" = 0 ] && [ -z "$(git -C "$r" stash list)" ] \
  && [ "$(cat "$r/CLAUDE.md")" = 'my notes' ] && ok "fix_stash_refuses_paths_bd_init_writes" || bad "collision: $out"

r="$(mkrepo "Dirty Beads")"; mkhouse "$r" -; commit_all "$r" beads; printf 'x: y\n' >> "$r/.beads/config.yaml"; logclear
out="$(R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q '\.beads/' && [ "$(logn)" = 0 ] && ok "fix_stash_refuses_dirty_beads_dir" || bad "dirty .beads: $out"

# the measured failure: a plain `git stash pop` turns MM into " M". A mutated copy of the skill
# must report it, proving the verification can see it.
M="$TMPROOT/mutant skill"; cp -r "$SKILL_DIR" "$M"
anchor='_beads_git_raw "$top" stash apply --index "$sha"'
if [ "$(grep -cF "$anchor" "$M/lib/beads.sh")" = 1 ]; then
  sed -i "s|_beads_git_raw \"\$top\" stash apply --index \"\$sha\"|git -C \"\$top\" stash pop|" "$M/lib/beads.sh"
  [ "$(grep -cF 'git -C "$top" stash pop' "$M/lib/beads.sh")" = 1 ] || bad "mutation did not apply"
  r="$(stash_fixture "Lost Staging")"
  out="$( stub_path "$STUBDIR"; export STUB_BD_LOG="$LOG"; bash "$M/ritual.sh" fix beads "$r" --stash )"
  [ "$(st "$out")" = failed ] && dt "$out" | grep -q 'mm.txt' && ok "fix_stash_detects_lost_staging" || bad "plain pop not detected: $out"
else
  bad "fix_stash_detects_lost_staging: restore anchor not found exactly once"
fi

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
