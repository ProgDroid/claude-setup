# Work machine setup prompt

For a machine that runs Claude Code only (Ubuntu or similar), where `~/.claude` is tracked in a dotfiles
repo that has drifted from the main setup. After running this one command yourself:

```bash
claude plugin marketplace add ProgDroid/claude-setup
```

start a Claude Code session and hand it this file:

> Read `~/.claude/plugins/marketplaces/progdroid/snippets/work-machine-setup.md` and follow it.

Everything below this line is the prompt, addressed to the session that executes it.

---

# Task: clean up this machine's Claude setup and wire in the `core` plugin

You are cleaning up a Linux machine whose `~/.claude` is tracked by a dotfiles git repo and has drifted.
The `core` plugin from the `progdroid` marketplace (already added) now carries the shared workflow:
shared rules, the `capture-learnings`, `synthesize-memories`, `sdd-controller` and `working-style`
skills, the standards skills, and two hooks. Your job is to retire the hand-copied versions of those
things (skills, includes and hooks) and connect the real ones. The `superpowers` plugin
(`superpowers@superpowers-dev`, upstream `obra/superpowers`) is also in scope: Step 3 installs it.

**Shell state does not persist between your Bash calls.** Start every Bash call that uses `DOT`, `MP` or
`CORE` by setting them again (Step 0 shows how and prints the values to reuse).

**Resuming.** The restart in Step 6 ends this session. If the user's first message says to continue at
Step 6, do only Step 0 and Step 6, and rebuild what happened from the repo: run
`git -C "$DOT" log --grep='^work-setup:' --format='%h %s%n%b'` after setting `DOT`.

## Ground rules (apply to every step)

1. **Report before acting.** Each step has a "SHOW, THEN WAIT" point. At that point print what you found
   and what you propose, then stop and wait for the user to approve in this conversation. Silence is not
   approval. Do nothing destructive (`git rm`, deleting files, rewriting history, editing `CLAUDE.md`,
   changing `settings.json`) before approval.
2. **Read-only until the first SHOW, THEN WAIT of each step.** Before that point a step only reads.
3. **Transcripts are a hard stop.** Never `git add` anything under `~/.claude/projects/*/*.jsonl` (session
   transcripts). The gitignore lines in step 1 must be in place before any `git add` of any kind.
4. **Ask before installing tools.** `jq` and `gitleaks` may be missing. Installing them (`sudo apt install jq`,
   or a gitleaks release binary) needs the user's go-ahead, because it may need root or network access.
5. **No private details in output you save.** If you write notes or a summary file, keep employer and
   project specifics out of anything that will be committed to a public repo.
6. Do not push anything unless the user says to. Do not run `git push --force` ever without being told.
7. If a command here fails or prints something unexpected, say so and stop at that step. Do not guess.
   (The one exception is the setup script written in Step 3, which carries on past a failed install line
   so a fresh machine ends up as complete as possible. You still report each failure it prints.)
8. Commit in the dotfiles repo from Bash, with the message on stdin (`git commit -F -` and a quoted
   heredoc). Commits are local; message prefix `work-setup:` so a later session can find them.

## Step 0: locate things

Run and print the results:

```bash
command -v git jq gitleaks claude
ls -la "$HOME/.claude"
MP="$HOME/.claude/plugins/marketplaces/progdroid"; CORE="$MP/core"
ls "$HOME/.claude/plugins/marketplaces/"
ls "$CORE/rules/shared.md" "$CORE/skills" "$CORE/hooks"
DOT="$(git -C "$(dirname "$(realpath "$HOME/.claude/CLAUDE.md")")" rev-parse --show-toplevel 2>/dev/null)"; echo "dotfiles repo: ${DOT:-NOT FOUND}"
```

`MP` assumes the marketplace directory is named after the marketplace (`progdroid`); the `ls` of
`marketplaces/` shows whether that holds. If not, set `MP` to the directory that contains `core/rules/shared.md`.

`DOT` is the work dotfiles repo, found by following the `CLAUDE.md` symlink and asking git for the repo
that holds its directory. If it prints `NOT FOUND`, `~/.claude/CLAUDE.md` is not a symlink into a repo; ask
the user where the dotfiles repo is, set `DOT` to that, and carry on. If `shared.md` is missing, stop: the
marketplace was not added.

Use `DOT` in the steps below. Confirm `git -C "$DOT" status --short` and report whether the tree is clean.
If it is dirty, tell the user and ask whether to continue.

## Step 1: inventory what the dotfiles track under `~/.claude`

1. List what is tracked and how big it is:

```bash
git -C "$DOT" ls-files | head -200
git -C "$DOT" ls-files | wc -l
(cd "$DOT" && git ls-files -z | xargs -0 -r du -k | sort -rn | head -30)
```

2. Classify every top-level path under the tracked `~/.claude` area into two lists.
   - **Keep:** `CLAUDE.md`, `settings.json`, memory directories, and the user's own skills.
   - **Never track (credentials and local state; check these first):** `.credentials.json`,
     `settings.local.json`, `.claude.json`.
   - **Drop (stop tracking):** plugin caches and marketplace clones (`plugins/`), transcripts
     (`projects/*/*.jsonl`, hard stop), `todos/`, `shell-snapshots/`, `statsig/` and other telemetry,
     `history.jsonl`, `backups/`, `cache/`, `file-history/`, `ide/`, `sessions/`, and
     anything else that is machine-generated.
   - Anything you cannot classify goes in a third list, **Unsure**, with a one-line reason each.

3. Memory must live inside the dotfiles repo: moved there, not copied, so there is one copy. For this,
   `~/.claude/projects` (or each `<key>/memory`) should be a symlink into the repo, with transcripts gitignored. Without that,
   the `synthesize-memories` skill finds no repo and stays proposal-only forever. Check the current state:

```bash
ls -la ~/.claude/projects | head -40
for m in ~/.claude/projects/*/memory; do
  [ -e "$m" ] || continue
  printf '%s -> %s | repo: %s\n' "$m" "$(realpath "$m")" "$(git -C "$(realpath "$m")" rev-parse --show-toplevel 2>/dev/null || echo NONE)"
done
```

4. Propose the layout change. Preferred: keep the real memory directories inside `$DOT` (for example
   `$DOT/claude/projects/<key>/memory`), and make each `~/.claude/projects/<key>/memory` a symlink to
   them, leaving the transcript files where Claude Code writes them, untracked. Propose these gitignore
   lines for the dotfiles repo (path prefix adjusted to where `~/.claude` content lives in the repo):

```
.credentials.json
settings.local.json
.claude.json
projects/**/*.jsonl
projects/*/*.jsonl
plugins/
todos/
shell-snapshots/
statsig/
history.jsonl
backups/
cache/
file-history/
ide/
sessions/
```

**SHOW, THEN WAIT.** Print the keep list, the drop list, the Unsure list, the current memory layout, and
the proposed symlink moves and gitignore lines. Wait for approval. After approval, in this order:
(a) add the gitignore lines and commit that alone with message `work-setup: step 1 gitignore`; (b)
`git rm -r --cached` every path from **both** the never-track list and the drop list that is currently
tracked (this stops tracking, it does not delete the files on disk; a gitignore line alone does not untrack
a file that is already tracked, and Step 2 covers whatever is already in history); (c) move memory and create the symlinks; (d) commit with message `work-setup: step 1 tracking and memory layout`.

For (c): if the memory directories already resolve inside `$DOT` (for example `~/.claude` is itself the
repo), there is nothing to move; skip to the verification. Otherwise, for each project `KEY` (do the
project of THIS session last, and write no memory while you do it), run this guarded sequence. It refuses to
overwrite, and it never uses `ln -sfn` onto a real directory:

```bash
MP="$HOME/.claude/plugins/marketplaces/progdroid"; CORE="$MP/core"
DOT="$(git -C "$(dirname "$(realpath "$HOME/.claude/CLAUDE.md")")" rev-parse --show-toplevel)"
PFX=claude   # the directory inside the repo that holds the ~/.claude content, the same prefix you
             # used for the gitignore lines; set PFX= (empty) if the repo root is ~/.claude itself
if [ -L "$HOME/.claude/projects" ]; then
  echo "SKIP ALL: ~/.claude/projects is itself a symlink to $(readlink -f "$HOME/.claude/projects"); confirm that resolves inside $DOT and do not move anything"
else
  . "$CORE/hooks/lib-key.sh"; CUR="$(core_memory_key "$PWD")"   # this session's project, handled last
  for KEY in $(ls "$HOME/.claude/projects" | grep -vxF -- "$CUR") "$CUR"; do
    SRC="$HOME/.claude/projects/$KEY/memory"; DST="$DOT${PFX:+/$PFX}/projects/$KEY/memory"
    if [ -L "$SRC" ]; then echo "SKIP: $SRC is already a symlink to $(readlink -f "$SRC")"
    elif [ ! -d "$SRC" ]; then echo "SKIP: no memory directory at $SRC"
    elif [ -e "$DST" ]; then echo "STOP: $DST already exists in the repo"; diff -r "$SRC" "$DST" | head -40
    else mkdir -p "$(dirname "$DST")" && mv "$SRC" "$DST" && ln -s "$DST" "$SRC" && echo "moved and linked: $KEY"
    fi
  done
fi
```

On any `STOP`, show the user the `diff` output and wait; never merge or overwrite on your own.
Then verify with one real project (`K` is the first project directory that has a memory directory):

```bash
K=""; for d in "$HOME/.claude/projects"/*/; do [ -d "${d}memory" ] && { K="$(basename "$d")"; break; }; done; echo "project: $K"
git -C "$(realpath "$HOME/.claude/projects/$K/memory")" rev-parse --show-toplevel
```

It must print the dotfiles repo path. If it errors or prints a different path, stop and report.
Also run `git -C "$DOT" ls-files | grep -c '\.jsonl$'`; it must print `0` for transcripts (if it prints a
number above 0, report which files before doing anything).

## Step 2: secret sweep

Scan the kept files, any newly tracked files, **and the full git history** of the dotfiles repo.

1. Pick the scanner and say which one ran:
   - If `command -v gitleaks` succeeds, use it.
   - Else ask the user to approve installing it (a release binary from the gitleaks GitHub releases page, or the
     distro package). If approved, install and use it.
   - Else (declined or impossible) fall back to a pattern scan and say clearly that this is weaker:

```bash
git -C "$DOT" grep -lIE '(AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{30,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-[A-Za-z0-9]{20,}|(api[_-]?key|secret|token|password)[[:space:]]*[=:][[:space:]]*[^[:space:]]{8,})' -- . ':!*.jsonl'
git -C "$DOT" log --all -G'(AKIA[0-9A-Z]{16}|BEGIN [A-Z ]*PRIVATE KEY|ghp_[A-Za-z0-9]{30,}|xox[baprs]-)' --format='commit %h' --name-only | head -100
```

   These list **file names and commit ids only**; they never print a matching line, because a matching line
   is the secret. `git grep` covers only the tracked working tree; the `git log` line is the history half.

2. With gitleaks, run both the working tree and the history, and keep the output out of the repo:

```bash
W="$(mktemp -d)"
gitleaks detect --source "$DOT" --no-git --redact -v > "$W/tree.txt" 2>&1; echo "tree exit=$?"
gitleaks detect --source "$DOT" --redact -v > "$W/history.txt" 2>&1; echo "history exit=$?"
```

   Newer gitleaks releases deprecate `detect` in favour of `gitleaks dir` (tree) and `gitleaks git`
   (history); use whichever your version has (`gitleaks --help`). The tree scan (`--no-git` / `dir`) also
   covers untracked and ignored files, so when `DOT` is `~/.claude` itself it reads transcripts too; say so
   in your report. Read the files in `$W`, then `rm -rf "$W"`.

   Exit 0 means no findings, exit 1 means findings, anything else means the scan did not run properly (report
   that as UNKNOWN, not as clean). Read the files and summarise by file and rule, never printing a secret value.
   Note that `--redact` is on; keep it on.

3. **SHOW, THEN WAIT.** Report findings per location (working tree vs history). For each history hit,
   present the two options and let the user choose: **rotate** the credential (usually enough, always do
   it first) or **rewrite history** (`git filter-repo`, which may itself need an ask-first install), which changes every commit hash and breaks other clones. Never rewrite
   history unasked, and never print a secret in full.

## Step 3: setup script

Write a script in the dotfiles repo (suggest `$DOT/setup-claude.sh`; ask the user to confirm the name and
location) that is idempotent and can be re-run on a fresh machine. It must do the following, and you
should show it to the user before creating it.

1. Check `jq` exists. If not, print how to install it (`sudo apt install jq`) and exit non-zero from the
   script (it is a deliberate prerequisite).
2. Make sure the tracked `settings.json` contains the marketplace with auto-update. Merge with `jq`, never
   overwrite the file:

```bash
S="$HOME/.claude/settings.json"
[ -e "$S" ] || echo '{}' > "$S"
tmp="$(mktemp)" && jq '.extraKnownMarketplaces.progdroid = {"source":{"source":"github","repo":"ProgDroid/claude-setup"},"autoUpdate":true}
  | .extraKnownMarketplaces["superpowers-dev"] = {"source":{"source":"github","repo":"obra/superpowers"}}' "$S" > "$tmp" && cat "$tmp" > "$S"; rm -f "$tmp"
```

   `cat ... >` writes **through** the file, so a `settings.json` that is a symlink into the repo stays a
   symlink (`mv` would replace the link with a plain file and silently stop tracking it). A missing file is
   created as `{}` first; if `jq` fails the original is left untouched.
3. Add the marketplaces and install the plugins; both commands are non-interactive and default to user scope:

```bash
claude plugin marketplace add ProgDroid/claude-setup
claude plugin marketplace add obra/superpowers
claude plugin install core@progdroid
claude plugin install superpowers@superpowers-dev
```

   (A "already added/installed" message is fine; any other failure should print and continue to the next line.)
4. Create the rules link **safely**:

```bash
MP="$HOME/.claude/plugins/marketplaces/progdroid"   # set here: this runs standalone on a fresh machine
if [ ! -d "$MP/core/rules" ]; then
  echo "STOP: $MP/core/rules not found. Add the marketplace first; no link was created." >&2
  exit 1
fi
mkdir -p "$HOME/.claude/rules"
if [ -e "$HOME/.claude/rules/core" ] && [ ! -L "$HOME/.claude/rules/core" ]; then
  echo "STOP: $HOME/.claude/rules/core exists and is not a symlink. Report it; do not ln into it." >&2
  exit 1
fi
ln -sfn "$MP/core/rules" "$HOME/.claude/rules/core"
```

   The guard matters: if a real directory sits at that path (for example restored from a backup),
   `ln -sfn` would create the link *inside* it and leave the stale directory in place.
5. Do **not** track `~/.claude/rules/core` itself in the dotfiles repo (it is a machine-local link into the
   marketplace clone); if the rules directory is tracked, add `rules/core` to the gitignore (same repo
   prefix as the Step 1 lines).

**SHOW, THEN WAIT.** Show the script, wait for approval, create it, run it once, and report each command's
outcome. If the rules-link guard fires, stop and tell the user; do not remove the directory yourself.
Then commit the script and the `settings.json` change together with message
`work-setup: step 3 setup script and plugin wiring`.

## Step 4: retire the hand-copied `capture-learnings` and copied includes

The work machine may hold a hand-copied `capture-learnings` skill (for example under `~/.claude/skills/`) and
copies of the shared "includes" files (for example under `~/.claude/includes/`). `core` carries the current
versions. Do not delete anything silently.

1. Find the copies and compare each with its `core` counterpart:

```bash
MP="$HOME/.claude/plugins/marketplaces/progdroid"; CORE="$MP/core"   # set again
ls -la "$HOME/.claude/skills" "$HOME/.claude/includes" "$HOME/.claude/hooks" 2>/dev/null
for d in "$CORE"/skills/*/; do
  n="$(basename "$d")"
  [ -e "$HOME/.claude/skills/$n" ] && { echo "== copy of core skill: $n"; diff -ru "$HOME/.claude/skills/$n" "$d"; }
done
for f in "$HOME"/.claude/includes/*.md; do [ -e "$f" ] && echo "include copy: $f"; done
echo "-- core hooks:"; ls "$CORE/hooks"
echo "-- hooks configured in settings.json:"; jq '.hooks' "$HOME/.claude/settings.json" 2>/dev/null
```

   This covers every `core` skill (`capture-learnings`, `synthesize-memories`, `sdd-controller`,
   `working-style`, the standards skills) and also looks for **hand-copied hooks**: a script under
   `~/.claude/hooks/` or a `settings.json` hook that does what `memory-index-nudge.sh` or
   `negative-result-guard.sh` does would fire twice next to the `core` hooks. List each as a candidate.

   The `core` standards skills (`python-standards`, `rust-standards`, `testing-standards`, `git-standards`, and so on) replace
   the matching include files. Map each copied include to the `core` skill that replaced it and `diff` the two
   (the include is a plain file, the skill is `SKILL.md` inside a directory).
2. For each copy, list the **work-only improvements**: lines or sections present in the copy and absent from
   `core`. Do not keep any silently. If a diff hunk is something the user wrote for this machine, quote it.
   An include with **no `core` counterpart** (org-specific or tool-specific): keep it, and list it in your
   summary as "no counterpart, kept".
3. **SHOW, THEN WAIT.** Present per file: identical, only-older, or has work-only content (quoted). Ask, for
   each work-only item, whether to drop it, keep it as a work-only line in `~/.claude/CLAUDE.md`, or
   mark it "upstream". For "upstream", do nothing except write the quoted hunk into your final summary for
   the user to take to the home machine; you cannot push to the shared repo and must not try. Only after approval, remove the retired copies (`git rm` in the dotfiles repo, and delete
   the on-disk files if they are not symlinks into the repo). The expected end state: no
   `~/.claude/skills/capture-learnings`, no other copied `core` skill, no duplicate hooks, and no copied
   includes that `core` now carries. Commit with message `work-setup: step 4 retire copied skills, includes and hooks`.

## Step 5: trim the work `~/.claude/CLAUDE.md`

`core` now injects shared rules from `~/.claude/rules/core/shared.md`. Anything in the work `CLAUDE.md` that
the shared rules already say is now duplicated.

1. Read both: `cat ~/.claude/CLAUDE.md` and `cat ~/.claude/rules/core/shared.md`.
2. Build the proposed new `CLAUDE.md`: remove paragraphs and lines that `shared.md` already carries (same rule,
   even if worded differently), and keep every work-specific line. When in doubt, keep and list it as
   "possible duplicate".
3. Produce the diff without modifying the file:

```bash
cp ~/.claude/CLAUDE.md /tmp/CLAUDE.md.proposed   # edit the copy, not the original
diff -u ~/.claude/CLAUDE.md /tmp/CLAUDE.md.proposed
```

**SHOW, THEN WAIT.** Show the diff and a short list of what was removed and why (naming the `shared.md` line that covers it). Apply only after approval, with `cp /tmp/CLAUDE.md.proposed "$HOME/.claude/CLAUDE.md"` (`cp` writes through, so a symlinked `CLAUDE.md` stays a symlink; do not `mv`). Use `mktemp` instead of the fixed `/tmp` name if that file already exists.
Commit with message `work-setup: step 5 trim CLAUDE.md`.

**Record the hand-off, then restart.** Step 6 needs a restarted session, which will not have this prompt in
memory. Leave the state in the repo, as one empty commit whose body is one generic line per step
(what was done, what was declined, anything left):

```bash
git -C "$DOT" commit --allow-empty -F - <<'EOF'
work-setup: steps 0-5 done, restart pending

step 1: <outcome>
step 2: <outcome>
step 3: <outcome>
step 4: <outcome>
step 5: <outcome>
EOF
```

(Fill in the real outcomes before running; the quoted heredoc will not substitute anything.) Then print the
following line, with the real absolute path substituted by the shell, and tell the user to restart Claude
Code and paste that one line as their first message:

```bash
echo "Read $HOME/.claude/plugins/marketplaces/progdroid/snippets/work-machine-setup.md and continue at Step 6; steps 0 to 5 are done."
```

The new session follows "Resuming" at the top: Step 0, read the `work-setup:` commits, then Step 6.

## Step 6: restart and verify by effect

You are the restarted session (see "Resuming"; hooks and the rules link are read at session start). Set
`DOT`, `MP` and `CORE` as in Step 0 and run each check and report PASS, FAIL or UNKNOWN with the evidence. A check that could not run is UNKNOWN, never PASS.

1. The rules link points at the marketplace copy, not at a stale copy:

```bash
[ "$(readlink -f ~/.claude/rules/core)" = "$(readlink -f "$MP/core/rules")" ] && echo PASS || echo FAIL
```

2. A fresh headless session quotes the canary line. The reply must contain a line starting `Source: core rules`:

```bash
claude -p 'Quote, verbatim, the one line of your loaded rules that starts with "Source: core rules". If there is none, reply NONE.'
```

3. No stale copies of the shared rules sit elsewhere (this must print nothing):

```bash
grep -RlF 'Source: core rules' "$HOME/.claude/CLAUDE.md" "$HOME/.claude/rules" --exclude-dir=core
```

   `-R` (capital) follows symlinks met while recursing; lowercase `-r` skips them, and
   `~/.claude/rules/core` is a symlink. Prove the probe can find something by running
   `grep -RlF 'Source: core rules' "$HOME/.claude/rules/core/"` (it must list `shared.md`); an empty result
   from the real check only means something if that control found it.
4. The plugin is installed: `claude plugin list` shows `core@progdroid` (and `superpowers@superpowers-dev`).
5. The old skill path is gone: `test ! -e ~/.claude/skills/capture-learnings && echo PASS || echo FAIL`.
6. The memory nudge fires on a fixture index. This builds a throwaway memory root with an index over a small
   threshold, so it touches none of the user's memory:

```bash
T="$(mktemp -d)"; mkdir -p "$T/fixture/memory"
head -c 300 /dev/zero | tr '\0' 'x' > "$T/fixture/memory/MEMORY.md"; echo >> "$T/fixture/memory/MEMORY.md"
bash "$CORE/hooks/memory-index-nudge.sh" \
  --memory-root "$T" --project fixture --threshold 100 --claude-md /dev/null
rm -rf "$T"
```

   Expected output, exactly one line: `Memory index for this project is 301 bytes (threshold 100) and loads every session. Run the synthesize-memories skill to tier shipped milestones into the cold index.`
   No output at all is a FAIL (the hook is silent when under threshold, so also confirm the file really is 301 bytes).
7. Memory is in the repo (repeat the Step 1 check for one real project): the `git rev-parse --show-toplevel`
   of the resolved memory directory prints the dotfiles repo.

Finish with a summary table of steps 1 to 5 (from the `work-setup:` commits) and the seven checks, the commits made in the dotfiles repo
(`git -C "$DOT" log --oneline -10`), and anything left undone. Do not push; tell the user the commits are
local and let them decide.
