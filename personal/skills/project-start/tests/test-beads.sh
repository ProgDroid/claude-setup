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
  if [ -n "${STUB_BLOCK_TOP:-}" ] && [ -s "$1" ]; then   # block first, the user's text after it
    { if [ -n "${STUB_CRLF:-}" ]; then block | sed 's/$/\r/'; else block; fi; cat "$1"; } > "$1.new"
    mv "$1.new" "$1"; return 0
  fi
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
      list)   if [ -n "${STUB_REMOTE_STUCK:-}" ]; then echo "origin  git+origin"
              elif [ -n "${STUB_REMOTE_LIST+x}" ]; then [ -n "$STUB_REMOTE_LIST" ] && printf '%s\n' "$STUB_REMOTE_LIST"
              else echo "No remotes configured."; fi   # real bd 1.2.2's answer, measured
              exit "$rc" ;;
    esac ;;
  "config set")
    [ "$3" = "${STUB_SET_IGNORE:-}" ] && exit "$rc"
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
# bare_lf <file> -> count of LF bytes not preceded by CR
bare_lf() { od -An -tx1 -v "$1" | tr -s ' ' '\n' | awk 'NF { if ($1 == "0a" && prev != "0d") n++; prev = $1 } END { print n + 0 }'; }
# same_user_state <pre> <post>: every path dirty in <pre> has the same XY, bytes and index in
# <post>. The snapshots go through stdin: on argv, two 150-file snapshots overflow jq.exe's
# command line, and an empty answer would read as a failed comparison for the wrong reason.
same_user_state() {
  printf '%s\n%s\n' "$1" "$2" | jq -s '.[0] as $a | .[1] as $b
    | [$a.dirty[] | . as $d | ($b.dirty | map(select(.path == $d.path)) | .[0]) as $e
     | ($e != null and $e.xy == $d.xy and $b.bytes[$d.path] == $a.bytes[$d.path]
        and $b.index[$d.path] == $a.index[$d.path])] | all' | tr -d '\r' | grep -qx true
}

# a jq wrapper for fail-closed tests: a call carrying the argument named in STUB_JQ_FAIL_ON
# exits 126 printing nothing (what jq.exe does on an over-long command line); one carrying
# STUB_JQ_GARBAGE_ON exits 0 printing something that is not JSON. Everything else is real jq.
JQDIR="$TMPROOT/jq wrap"; mkdir -p "$JQDIR"
{ printf '#!/usr/bin/env bash\nREAL_JQ=%q\n' "$(command -v jq)"; cat <<'WRAP'
for a in "$@"; do
  [ -n "${STUB_JQ_FAIL_ON:-}" ] && [ "$a" = "$STUB_JQ_FAIL_ON" ] && exit 126
  [ -n "${STUB_JQ_GARBAGE_ON:-}" ] && [ "$a" = "$STUB_JQ_GARBAGE_ON" ] && { echo 'not json ['; exit 0; }
done
exec "$REAL_JQ" "$@"
WRAP
} > "$JQDIR/jq"; chmod +x "$JQDIR/jq"
RJ() { ( stub_path "$STUBDIR"; stub_path "$JQDIR"; export STUB_BD_LOG="$LOG"; bash "$RITUAL" "$@" ); }

# big_fixture <name> -> repo with 160 dirty files: 50 staged edits, 20 MM (staged, then edited
# again), 30 unstaged edits, 60 untracked files in a spaced directory. Two such snapshots are
# about 55 KB, past jq.exe's ~32 KB command line.
big_fixture() {
  local r i; r="$(mkrepo "$1")"
  mkdir -p "$r/src" "$r/new stuff"
  for i in $(seq 1 100); do printf 'line %s\n' "$i" > "$r/src/f$i.txt"; done
  commit_all "$r" big
  for i in $(seq 1 70); do printf 'staged\n' >> "$r/src/f$i.txt"; done
  git -C "$r" add src
  for i in $(seq 51 100); do printf 'again\n' >> "$r/src/f$i.txt"; done
  for i in $(seq 1 60); do printf 'new %s\n' "$i" > "$r/new stuff/n $i.txt"; done
  printf '%s\n' "$r"
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
grep -q '^init ' "$LOG" && ! grep -q 'setup claude' "$LOG" && ok "fix_setup_claude_not_run_when_marker_preexisted" || bad "setup claude ran over a pre-existing marker (or bd never ran): $(cat "$LOG")"

r="$(mkrepo "Codex Repo")"; mkdir -p "$r/.codex" "$r/.agents/skills/beads"
printf 'mine\n' > "$r/.codex/mine.toml"; printf 'my skill\n' > "$r/.agents/skills/beads/MINE.md"; commit_all "$r" codex; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && grep -q '^init ' "$LOG" && [ "$(cat "$r/.codex/mine.toml" 2>/dev/null)" = mine ] \
  && [ "$(cat "$r/.agents/skills/beads/MINE.md" 2>/dev/null)" = 'my skill' ] && [ -d "$r/.codex" ] && [ -d "$r/.agents/skills/beads" ] \
  && ok "fix_keeps_preexisting_codex_and_agents_skill" || bad "pre-existing .codex/.agents: $out; $(ls -A "$r")"

r="$(mkrepo "Remote Unknown")"; logclear
out="$(STUB_REMOTE_LIST= R fix beads "$r")"
[ "$(st "$out")" = fixed ] && dt "$out" | grep -q 'dolt remote state unverified' && ok "fix_dolt_unrecognised_answer_is_reported_unverified" || bad "empty remote list: $out"
r="$(mkrepo "Remote Other")"; logclear
out="$(STUB_REMOTE_LIST='upstream  git+elsewhere' R fix beads "$r")"
[ "$(st "$out")" = fixed ] && dt "$out" | grep -q 'dolt remote state unverified' && dt "$out" | grep -q 'upstream' \
  && ok "fix_dolt_other_answer_is_reported_unverified_and_quoted" || bad "other remote list: $out"

r="$(mkrepo "Interval Repo")"; logclear
out="$(STUB_SET_IGNORE=export.interval R fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'export.interval' && grep -qx 'config set export.interval 1ms' "$LOG" \
  && ok "fix_fails_when_interval_not_written" || bad "interval unset: $out"

# _beads_unban_block, directly: the managed block first, user text AFTER it, and a final line with
# no line ending. Only the two ban lines may change; no byte is added after the last line.
unban_case() {   # <eol> -> 0 when the result is byte-exact
  ( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/beads.sh"; e="$1"
    f="$TMPROOT/unban.$RANDOM"
    printf "%s$e" '<!-- BEGIN BEADS INTEGRATION v:1 -->' '- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate' \
      '- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files' '<!-- END BEADS INTEGRATION -->' '' 'my text after' > "$f"
    printf 'no final newline' >> "$f"
    { printf "%s$e" '<!-- BEGIN BEADS INTEGRATION v:1 -->' "$_BEADS_LINE_TODO" "$_BEADS_LINE_MEM" '<!-- END BEADS INTEGRATION -->' '' 'my text after'
      printf 'no final newline'; } > "$f.exp"
    [ "$(_beads_unban_block "$f")" = 2 ] && cmp -s "$f" "$f.exp" )
}
unban_case '\n' && ok "unban_keeps_user_text_after_block_and_no_final_newline" || bad "unban LF: trailing bytes changed"
unban_case '\r\n' && ok "unban_keeps_user_text_after_block_and_no_final_newline_crlf" || bad "unban CRLF: trailing bytes changed"

# end to end: bd puts its block ABOVE the user's CRLF CLAUDE.md; the user's bytes after the END
# marker survive unchanged (the override is appended after them).
r="$(mkrepo "Block Top")"; printf '# Mine\r\n\r\nKeep this.\r\n' > "$r/CLAUDE.md"; commit_all "$r" claude
cp "$r/CLAUDE.md" "$TMPROOT/top.user"; logclear
out="$(STUB_BLOCK_TOP=1 STUB_CRLF=1 R fix beads "$r")"
endm='END BEADS INTEGRATION -->'; off="$(grep -abo "$endm" "$r/CLAUDE.md" | head -n 1 | cut -d: -f1)"
[ "$(st "$out")" = fixed ] && [ -n "$off" ] && [ "$(head -n 1 "$r/CLAUDE.md" | grep -c 'BEGIN BEADS')" = 1 ] \
  && tail -c +"$((off + ${#endm} + 3))" "$r/CLAUDE.md" | head -c "$(wc -c < "$TMPROOT/top.user")" | cmp -s - "$TMPROOT/top.user" \
  && [ "$(bare_lf "$r/CLAUDE.md")" = 0 ] && ! grep -q 'do NOT use TodoWrite' "$r/CLAUDE.md" \
  && ok "fix_user_text_after_block_is_byte_identical_crlf" || bad "block-top CLAUDE.md: $out; $(od -c "$r/CLAUDE.md" | head -n 4)"

r="$(mkrepo "Crlf Claude")"; printf '# Mine\r\n\r\nKeep this.\r\n' > "$r/CLAUDE.md"; commit_all "$r" claude
cp "$r/CLAUDE.md" "$TMPROOT/claude.crlf"; logclear
out="$(STUB_CRLF=1 R fix beads "$r")"
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
msha="$(git -C "$r" rev-parse -q --verify refs/stash)"
[ -n "$msha" ] && dt "$out" | grep -qF "core.autocrlf=false" && dt "$out" | grep -qF "stash apply --index $msha\`" \
  && ok "fix_stash_mismatch_prints_the_raw_mode_apply" || bad "mismatch recovery command: $(dt "$out")"

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

# --- large trees: the compare must not depend on jq's command-line length
r="$(big_fixture "Big Stash")"; pre="$(pf "$r")"; logclear
[ "$(jq '.dirty|length' <<<"$pre")" -ge 150 ] && [ "$(jq '[.dirty[]|select(.xy=="MM")]|length' <<<"$pre")" = 20 ] \
  && [ "$(jq '[.dirty[]|select(.xy=="??")]|length' <<<"$pre")" = 60 ] && [ "$(jq '[.dirty[]|select(.xy=="M ")]|length' <<<"$pre")" = 50 ] \
  && [ "$(printf '%s%s' "$pre" "$pre" | wc -c)" -gt 40000 ] && ok "big_fixture_has_160_dirty_past_the_argv_limit (control)" || bad "big fixture: $(jq -c '[.dirty[].xy]|group_by(.)|map({(.[0]):length})|add' <<<"$pre")"
out="$(R fix beads "$r" --stash)"; post="$(pf "$r")"
[ "$(st "$out")" = fixed ] && [ "$(git -C "$r" log -1 --format=%s)" = 'bd init: initialize beads issue tracking' ] \
  && same_user_state "$pre" "$post" && [ -z "$(git -C "$r" stash list)" ] \
  && ok "fix_stash_roundtrip_150_dirty_files" || bad "150 roundtrip: $(st "$out"); $(dt "$out" | head -c 300); stash=$(git -C "$r" stash list)"
w="$(jq -c '.wrote|sort' <<<"$out")"
[ "$(jq length <<<"$w")" = 10 ] && jq -e 'index(".beads/config.yaml") and index("CLAUDE.md") and index(".gitattributes")' <<<"$w" >/dev/null \
  && ok "fix_stash_150_wrote_lists_the_bd_paths" || bad "150 wrote: $w"

r="$(big_fixture "Big Mutate")"; logclear
out="$(STUB_INIT_MUTATE=README.md R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && dt "$out" | grep -q 'README.md' \
  && dt "$out" | grep -q 'stash@{0}' && ! grep -q 'config set' "$LOG" \
  && ok "fix_stash_mismatch_detected_150_dirty_files" || bad "150 mismatch: $(st "$out"); stash=$(git -C "$r" stash list)"

# --- fail closed: a compare that cannot run, or answers garbage, is a mismatch
r="$(stash_fixture "Jq Fails")"; logclear
out="$(STUB_JQ_FAIL_ON=snapdiff RJ fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && dt "$out" | grep -q 'stash@{0}' \
  && grep -q '^init ' "$LOG" && ok "fix_stash_jq_failure_keeps_stash" || bad "jq failure: $out; stash=$(git -C "$r" stash list)"
r="$(stash_fixture "Jq Garbage")"; logclear
out="$(STUB_JQ_GARBAGE_ON=snapdiff RJ fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && git -C "$r" stash list | grep -q 'ritual-beads' && grep -q '^init ' "$LOG" \
  && ok "fix_stash_unparseable_compare_keeps_stash" || bad "jq garbage: $out; stash=$(git -C "$r" stash list)"
r="$(mkrepo "Wrote Fails")"; logclear
out="$(STUB_JQ_FAIL_ON=changed RJ fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'changed' && grep -q '^init ' "$LOG" \
  && ok "fix_wrote_jq_failure_fails_the_step" || bad "wrote jq failure: $out"
# the same call answering garbage with exit 0: _beads_snaps' own validator must refuse it, or the
# step reports fixed with an empty `wrote` (jq -r '.[]' over garbage yields nothing)
r="$(mkrepo "Wrote Garbage")"; logclear
out="$(STUB_JQ_GARBAGE_ON=changed RJ fix beads "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'changed' && grep -q '^init ' "$LOG"   && ok "fix_wrote_unparseable_compare_fails_the_step" || bad "wrote jq garbage: $out"

# --- a previous run's stash still held: refuse before running anything
r="$(mkrepo "Held Stash")"; echo held >> "$r/README.md"; git -C "$r" stash push -q -m ritual-beads
hsha="$(git -C "$r" rev-parse refs/stash)"; logclear
out="$(R fix beads "$r" --stash)"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'stash@{0}' && dt "$out" | grep -q "$hsha" \
  && dt "$out" | grep -qF "core.autocrlf=false -c core.eol=lf -c core.safecrlf=false -c core.attributesFile=/dev/null --attr-source=" \
  && dt "$out" | grep -qF "stash apply --index $hsha\`" && dt "$out" | grep -qF 'git stash drop "stash@{0}"' && [ "$(logn)" = 0 ] \
  && [ "$(git -C "$r" stash list | grep -c '')" = 1 ] && ok "fix_refuses_while_ritual_stash_held (prints the raw-mode apply)" || bad "held stash: $out; log=$(cat "$LOG")"

# a user's own stash (no -m) made while HEAD's subject mentions ritual-beads is "WIP on <branch>: <sha>
# <subject>", not the ritual's "On <branch>: ritual-beads": it must not be refused as the ritual's
r="$(mkrepo "User Stash")"; echo mine >> "$r/README.md"; git -C "$r" add README.md; git -C "$r" commit -q -m 'notes about ritual-beads'
echo more >> "$r/README.md"; git -C "$r" stash push -q; logclear
git -C "$r" stash list | grep -q '^stash@{0}: WIP on .*ritual-beads' || bad "user stash fixture: $(git -C "$r" stash list)"
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && ! dt "$out" | grep -q 'still held' && grep -q '^init ' "$LOG"   && [ "$(git -C "$r" stash list | grep -c '')" = 1 ] && ok "fix_ignores_users_own_wip_stash_naming_ritual_beads" || bad "user wip stash: $out"

# the printed recovery command, run literally, gives back the exact bytes under core.autocrlf=true,
# where a plain `git stash apply --index` does not (control, on a copy of the same repo)
r="$(mkrepo "Raw Recover")"; git -C "$r" config core.autocrlf true
printf 'a\nb\n' > "$r/lf.txt"; commit_all "$r" lf 2>/dev/null
printf 'c\n' >> "$r/lf.txt"; printf 'p\nq\r\n' > "$r/mixed.txt"
pre="$(pf "$r")"; mkdir -p "$TMPROOT/rawexp"; cp "$r/lf.txt" "$r/mixed.txt" "$TMPROOT/rawexp/"
( . "$SKILL_DIR/lib/common.sh"; . "$SKILL_DIR/lib/beads.sh"; _beads_git_raw "$r" stash push -q -u -m ritual-beads ) >/dev/null 2>&1   # what an interrupted run leaves
hsha="$(git -C "$r" rev-parse -q --verify refs/stash)"; cp -r "$r" "$r plain"; logclear
out="$(R fix beads "$r" --stash)"
cmd="$(dt "$out" | sed -n 's/^[^`]*`\([^`]*\)`.*/\1/p')"
(cd "$r" && eval "$cmd") >/dev/null 2>&1
(cd "$r plain" && git stash apply --index "$hsha") >/dev/null 2>&1
[ -n "$hsha" ] && [ "$(st "$out")" = failed ] && grep -qF 'core.autocrlf=false' <<<"$cmd" && grep -qF "$hsha" <<<"$cmd" \
  && cmp -s "$r/lf.txt" "$TMPROOT/rawexp/lf.txt" && cmp -s "$r/mixed.txt" "$TMPROOT/rawexp/mixed.txt" && same_user_state "$pre" "$(pf "$r")" \
  && ! cmp -s "$r plain/lf.txt" "$TMPROOT/rawexp/lf.txt" \
  && ok "printed_raw_apply_command_restores_exact_bytes_under_autocrlf (control: plain apply differs)" \
  || bad "raw recovery: cmd=[$cmd]; lf=$(od -c "$r/lf.txt" | head -n 1); plain=$(od -c "$r plain/lf.txt" | head -n 1)"
r="$(mkrepo "Other Stash")"; echo other >> "$r/README.md"; git -C "$r" stash push -q -m 'my own work'; logclear
out="$(R fix beads "$r")"
[ "$(st "$out")" = fixed ] && git -C "$r" stash list | grep -q 'my own work' && ok "fix_ignores_an_unrelated_stash (control)" || bad "unrelated stash: $out"

# --- attributes the raw stash cannot neutralise by itself
r="$(stash_fixture "Info Attrs")"
ia="$(git -C "$r" rev-parse --path-format=absolute --git-path info/attributes)"; mkdir -p "$(dirname "$ia")"
printf '*.txt text eol=crlf\n' > "$ia"; pre="$(pf "$r")"; logclear
out="$(R fix beads "$r" --stash)"; post="$(pf "$r")"
[ "$(st "$out")" = failed ] && dt "$out" | grep -q 'info/attributes' && [ "$(logn)" = 0 ] && [ -z "$(git -C "$r" stash list)" ] \
  && same_user_state "$pre" "$post" && ok "fix_stash_refuses_nonempty_info_attributes" || bad "info/attributes: $out"
r="$(stash_fixture "Empty Info Attrs")"; ia="$(git -C "$r" rev-parse --path-format=absolute --git-path info/attributes)"
mkdir -p "$(dirname "$ia")"; : > "$ia"; logclear
[ "$(st "$(R fix beads "$r" --stash)")" = fixed ] && ok "fix_stash_allows_empty_info_attributes (control)" || bad "empty info/attributes refused"

r="$(mkrepo "Attrs File")"; git -C "$r" config core.autocrlf true
printf 'a\nb\n' > "$r/lf.txt"; commit_all "$r" lf 2>/dev/null
printf '*.txt text eol=crlf\n' > "$TMPROOT/user-attributes"; git -C "$r" config core.attributesFile "$(cygpath -m "$TMPROOT/user-attributes")"
printf 'c\n' >> "$r/lf.txt"; printf 'u\n' > "$r/untr.txt"
pre="$(pf "$r")"; out="$(R fix beads "$r" --stash 2>/dev/null)"; post="$(pf "$r")"
[ "$(st "$out")" = fixed ] && same_user_state "$pre" "$post" && ok "fix_stash_neutralises_core_attributesfile" || bad "attributesFile: $out"

# --- init failure under --stash: bd's failure and the restore are reported separately
r="$(stash_fixture "Init Fail Stash")"; pre="$(pf "$r")"; logclear
out="$(STUB_INIT_FAIL=1 R fix beads "$r" --stash)"; post="$(pf "$r")"; d="$(dt "$out")"
[ "$(st "$out")" = failed ] && grep -q 'bd init failed' <<<"$d" && grep -q 'leftovers: [^;]*\.beads/\.gitignore' <<<"$d" \
  && grep -q 'restored byte-for-byte' <<<"$d" && ! grep -qi 'NOT restored\|did not verify' <<<"$d" \
  && [ -z "$(git -C "$r" stash list)" ] && same_user_state "$pre" "$post" && [ -f "$r/.beads/.gitignore" ] \
  && ok "fix_stash_init_failure_separates_leftovers_from_restore" || bad "init fail under stash: $out; stash=$(git -C "$r" stash list)"

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
