#!/usr/bin/env bash
# Shared by test-beads*.sh: the stub bd, the jq wrapper and the fixture helpers. Source it.
# Not a suite itself (no test- prefix), so run-all.sh and detect.sh skip it.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOUSE="$SKILL_DIR/house"
STUBDIR="$TMPROOT/stub bin"
LOG="$TMPROOT/bd.log"
mkdir -p "$STUBDIR"

# --- stub bd: logs argv, models the bd 1.2.2 side effects that matter here (measured on the real
# binary: init writes .beads/, CLAUDE.md block, AGENTS.md, .codex/, .agents/, root .gitignore, sets
# an ABSOLUTE core.hooksPath and commits; `dolt remote remove origin` errors when no Dolt remote
# exists; config set writes config.yaml without committing; setup/prime exit 255 on success;
# export -o writes the issues file).
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
    # real bd 1.2.2's pre-commit exports the issues on every commit and stages nothing; its own
    # init commit leaves no issues file behind (both measured)
    printf '#!/usr/bin/env sh\nbd export -o .beads/issues.jsonl >/dev/null 2>&1\nexit 0\n' > .beads/hooks/pre-commit
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
    git commit -q --no-verify -m 'bd init: initialize beads issue tracking' 2>/dev/null
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
  "export -o")
    printf '%s' "${STUB_ISSUES:-}" > "$3"; exit "$rc" ;;
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

