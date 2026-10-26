---
name: project-start
ritual_version: 1
description: Use when the user says "project start", "set up this project", "onboard this repo" or "run the ritual", or when the project dashboard's brief line says "Project-start ritual not done/behind here" - runs the project-start ritual (Beads, line-ending and ignore traps, lint policy, test oracle, secret scan, CLAUDE.md, parking lot, CI, baseline, NEXT.md handoff) and writes the ritual record
---

# The project-start ritual

One run sets a repo up the house way and leaves a record of what it did. The deterministic work is
done by `ritual.sh`, which sits beside this file: it checks, fixes and reports one JSON result per
step. You orchestrate, ask and draft.

Needs bash 4.4 or newer, git and jq.

**No step that the script can answer is answered by the model.** If `ritual.sh` has a `check` or a
`fix` for it, run that and report what it says: never judge a step's state by reading files
yourself, and never write the record by hand.

Set these at the start of the run. The skill's base directory is shown when the skill loads; quote
every expansion, since paths may contain spaces.

```bash
R="<this skill's base directory>/ritual.sh"
REPO="$(git rev-parse --show-toplevel)"   # ritual.sh resolves any path inside the repo to this
RT="$(mktemp -d)"; mkdir -p "$RT/out" "$RT/chk"; echo "$RT"   # scratch for this run, outside the repo
```

Shell variables do not survive from one tool call to the next. Start every later command block
with the same three assignments, using the literal `RT` path printed here, so the whole run shares
one scratch directory.

Every result is `{"id", "status", "detail", "wrote"}`. `status` is `present | absent | unknown` for
a check (`check secret-scan` can also say `failed`), and `fixed | already | failed | unknown |
absent` for a fix. `wrote` lists the paths the step changed. **Save every fix result (and `auto`)
to `$RT/out/<step>.json` and every check result to `$RT/chk/<step>.json`**: step 6 takes `wrote`
from those files verbatim. Never retype a path the script reported.

**Ground rules**

- Every question is a recognition question: offer a default, a yes/no, or a list to pick from.
  Never ask the user to type a name, a path or a SHA.
- Exactly one question comes up front (Beads), because it must precede every write. All the other
  asks come together, in one batch, after the automatic steps.
- `unknown` is never folded into done or not-done. It means the ritual could not look (no `bd`, no
  `gh` auth, no `qmd`, a cloud session). Report it as such; it stays open in the record so a later
  run on a fully equipped machine can clear it.
- User files are appended to, never rewritten. When you add to `CLAUDE.md` or a config file, show
  the addition as a diff first.
- The record lives in the clone's git directory. Write it only with `record-write`: never with the
  Write or Edit tool, and never by hand.

## The flow

### 1. Preflight and what is due

```bash
bash "$R" preflight "$REPO" > "$RT/preflight.json"
bash "$R" due "$REPO"
```

`preflight` (step `preflight`) records the branch and every path that is already dirty or
untracked. The ritual runs on a dirty tree; only Beads needs it clean, and it handles that itself.

`due` answers `{"offer": [ids], "skip": [{id, reason}]}`. **Offer only the asks it lists.** A step
in `skip` was declined at its current version; do not ask it again, and leave it out of this run's
results so its old record entry is kept. The automatic steps always run.

### 2. The one up-front ask: Beads

Step `beads` sets up the house Beads tracker (`bd`).

```bash
bash "$R" check beads "$REPO" > "$RT/chk/beads.json"; cat "$RT/chk/beads.json"
```

- `present`: nothing to ask; record `already`. Its fix still runs, with no flags, in step 5 (a
  `present` check still gets its fix).
- `unknown` (no `bd` on PATH): nothing to ask; tell the user and record `unknown`.
- `absent`: ask **"Set up Beads here? `bd init` makes its own commit."** If preflight listed dirty
  paths, the same question offers to set the user's changes aside for `bd init` only and restore
  them straight after. On yes:

```bash
bash "$R" fix beads "$REPO" > "$RT/out/beads.json"            # clean tree
bash "$R" fix beads "$REPO" --stash > "$RT/out/beads.json"    # dirty tree, when the user accepted the stash
cat "$RT/out/beads.json"
```

The restore is verified by the script. If `fix beads` reports `failed`, show its detail verbatim:
when a stash is still held it names the exact command that gives the user's work back, and that
command must be run as given. A plain `git stash apply` can change line endings.

### 3. The automatic steps

Tell the user the automatic steps are running; they take about 7 to 15 seconds.

```bash
bash "$R" auto "$REPO" > "$RT/out/auto.json"; cat "$RT/out/auto.json"
```

`auto` detects the stack once and runs, in order: `stack`, `traps`, `stack-checks`, `oracle`,
`parking-lot` and `beads-metrics`. The parking-lot step runs here: it creates `docs/parking-lot.md`
when absent and adds the house parking-lot rule to `CLAUDE.md`. The output is
`{"results": [...], "wrote": [...]}`. Report each result in one line.

- `stack`'s `output` lists the languages (nested ones included) and the standards skills to load.
  Invoke the matching `core:<name>-standards` skills now.
- `oracle`'s `output` holds the test and lint commands it found. Nothing is run here. "No test
  command found" is a result, not a gap.
- `stack-checks` writes the canonical case itself. `absent` with "needs ask" (a Cargo workspace, a
  Python or Flutter project without a lint config) becomes an ask in step 5.
- `parking-lot` `absent` with "different rule exists (line N)" means the project has its own
  parking-lot rule; it is kept, and adding the house rule becomes an ask in step 5.
- `beads-metrics` `absent` means bd telemetry is on. It is a machine-wide setting: tell the user and
  offer to turn it off with `bd config set metrics.disabled true` (the detail names it; it writes
  the user-level bd config from any directory), then re-run `check beads-metrics` and record what
  it says.
- **A result whose detail starts "step ended without a result" is a ritual bug**, not an
  environment gap: that step crashed. Tell the user which step it was and quote its stderr from the
  detail. Do not retry it silently. Record it `unknown` so the record keeps it open.

### 4. Lessons

Search the cross-project lessons corpus for the detected languages and the project's name, with
`qmd search` only (BM25, fast; the hybrid mode takes tens of seconds and is not used here):

```bash
qmd search "<languages> <project name>"
```

Surface what applies in a few lines. Record `lessons` as `done` when the search ran, even with no
hits, and `unknown` when `qmd` is not installed.

### 5. The batched asks

Gather the state first, then put every ask that is due to the user **together**, as recognition
questions. Before running `check secret-scan`, tell the user that it runs a live proof: it stages
a temporary file holding a fake key, runs the pre-commit hook, and removes the file again.

```bash
bash "$R" check public-sweep "$REPO" > "$RT/chk/public-sweep.json"
bash "$R" check secret-scan "$REPO" > "$RT/chk/secret-scan.json"
bash "$R" check untracked-docs "$REPO" > "$RT/chk/untracked-docs.json"
bash "$R" check ci "$REPO" > "$RT/chk/ci.json"
bash "$R" check handoff "$REPO" > "$RT/chk/handoff.json"
cat "$RT"/chk/*.json
bash "$R" candidates "$REPO" > "$RT/candidates.json"; cat "$RT/candidates.json"   # only when Beads is set up
```

**A `present` check still gets its fix**, with no flags (for `secret-scan`, only `--proved`).
There the fix writes nothing and normally returns `already`, and its `wrote` lists the step's
uncommitted files that are still the ritual's to offer ("not yet committed" in its detail), so step
6 can offer them: not one the user declined that has not changed since, nor the user's own edit to
a tracked file. Record its status by the mapping table: `already` as `already`, `failed` as
`failed` with its detail shown (a `failed` `fix beads` names a stash an earlier run still holds:
show it as in step 2), `unknown` as `unknown`. `--proved` tells `fix secret-scan` that this run's
`check secret-scan` already proved the block, so the live proof is not run a second time.
A stale block (the check's detail ends `block v1, upgrade due`) is the exception: that same fix
upgrades it in place, flag or not, then runs the proof itself: `fixed`, or `unknown`/`failed` with
the upgrade kept. On INT, HUP or TERM during a hook write or a proof, `check` and `fix secret-scan`
finish or undo that step, print one result (`failed` naming the signal, or `fixed` when a created
or inserted block had already landed), then exit 130, 129 or 143: read the JSON, not the exit
status. `wrote` lists the hook only inside the work tree (`[]` under `.git/hooks`). An edited
block ("fix will not upgrade it") is never rewritten; it stays as the check found it.

```bash
pr() { [ "$(jq -r .status "$RT/chk/$1.json" 2>/dev/null | tr -d '\r')" = present ]; }
pr beads && bash "$R" fix beads "$REPO" > "$RT/out/beads.json"
pr secret-scan && bash "$R" fix secret-scan "$REPO" --proved > "$RT/out/secret-scan.json"
pr handoff && bash "$R" fix handoff "$REPO" > "$RT/out/handoff.json"
cat "$RT"/out/*.json
```

Ask only what `due` offered and what is not already in place.

- **`public-sweep`.** `present` means the repo is PUBLIC: offer to run the
  `publishing-a-private-repo` sweep once. `absent` means private or internal: not applicable, no
  question. `unknown` (no `gh`, no auth, no GitHub remote) is never read as "private".
- **`secret-scan`.** `absent`: offer the gitleaks pre-commit scan. On yes, run
  `bash "$R" fix secret-scan "$REPO" > "$RT/out/secret-scan.json"`, then prove it with
  `bash "$R" check secret-scan "$REPO"` (announced as above). It installs where git really runs
  hooks, inside Beads' hook when Beads is set up. `unknown` with "gitleaks not found": offer to
  install gitleaks; until then the step stays open. `failed`: show the detail; the proof names what
  went wrong.
- **`stack-checks`**, when step 3 left it `absent` with "needs ask": show the policy the standards
  skill prescribes (for a Cargo workspace, `[workspace.lints.clippy]` in the root and
  `[lints] workspace = true` in each member; for Python a ruff config; for Flutter
  `analysis_options.yaml`) as a diff to append. On yes, append it and confirm with
  `bash "$R" check stack-checks "$REPO"`.
- **`workspace`.** No script answers this one. If `CLAUDE.md` is missing, draft one. If it exists
  (including one `bd init` just wrote), propose **additions** as a diff: the test command from
  `oracle`, the stack, and the decision record (`docs/superpowers/specs`). Also propose a
  `.claude/settings.json` permission allow-list covering the oracle's commands. **`bd init`
  writes a `.claude/settings.json` of its own**, holding a SessionStart hook that runs
  `bd prime --hook-json`. So read the file first and merge the `permissions` key into it, and
  check `git diff` shows additions only. A Write that reports "updated" rather than "created" has
  replaced a file you had not seen: measured 2026-10-21 in swarm-music, where it dropped bd's
  hook, which was restored before the commit.
- **`untracked-docs`.** `present` lists untracked files under `docs/`. Leave out every path this
  run already wrote (such as `docs/parking-lot.md` from `auto`: it is in the commit already), and
  offer to commit the rest with the ritual's commit.
- **`parking-lot`**, when step 3 found a different rule: offer to add the house rule (the text in
  `house/parking-rule.md` beside this file) under `## Working rules`, leaving the existing line
  alone.
- **`beads-seed`**, only when Beads is set up. Show `candidates`' items (text and source) as a list,
  and let the user pick which become issues. **Look at where the candidates come from first.**
  `candidates` lists unchecked plan boxes, and in a repo whose plans never tick their boxes those
  are finished milestones: in swarm-music on 2026-10-21, all 50 came from the shipped M1 plan.
  When that is the case, say so. Then offer the open work the records and the parent plan name, or
  a read-only sweep of the docs and memory. Have that sweep mark each item OPEN, DONE or UNKNOWN
  with what it searched, because a deferred list decays like the code it tracks. Create each picked one with `bd create`, and confirm
  it by listing the issues: bd's exit code is not evidence, since several bd commands exit 255 on
  success. When `bd create` ran, put `.beads/issues.jsonl` in `model.json` (below): neither
  `bd create` nor bd's hook stages it, and it is how the issues reach other clones.
- **`ci`.** `absent` and `oracle` found a test command: offer a minimal workflow in
  `.github/workflows/` that runs it. `absent` with no test command: not applicable, no question.
- **`baseline`.** Always an ask, never automatic. Say that it runs the whole test suite once and
  may take a while. On yes, start what the tests need (for example a database container), run the
  oracle's test command once, and note the pass count, the fail count and the duration. Then stop
  **only what you started**. A failing baseline is a result, not an open step, and its failures are
  recorded (step 7).
- **`handoff`.** `present`: already set up; no question (its no-flag fix ran in the block above).
  If the detail mentions "shallow clone", no
  `handoff:` commit is within reach and the anchor may lie beyond the cut-off: offer
  `git fetch --unshallow` first, then check again, before asking anything else. Otherwise ask
  **"Set up the NEXT.md handoff here?"** with the default session-start question, "How did the last
  change go?", which the user accepts or edits. Offer `paths` only as a pick-list of files the
  developer edited by hand: the files changed in the last 50 commits, leaving out every commit whose
  subject starts `chore: auto-commit` or that carries a `Co-Authored-By: Claude` trailer, with
  "none" as the default; never as a blank to fill. On yes:

```bash
bash "$R" fix handoff "$REPO" --ask "<question>" --paths "<glob> <glob>" > "$RT/out/handoff.json"   # each flag only when changed
cat "$RT/out/handoff.json"
```

  It writes `NEXT.md`, the `.claude/handoff.json` marker and a `## Session routine` section in
  `CLAUDE.md`. `NEXT.md` is not in its `wrote`: it gets its own `handoff:` commit after step 6.
  - `absent` with "different session routine (line N)": the project has its own routine. Show it,
    and replace it only on an explicit yes: re-run with `--replace-routine`. If the user keeps
    their own, the step is `declined`.
  - `unknown` in a linked worktree, or when git could not tell where it is: nothing was written.
    Tell the user to run it from the main checkout. The step stays open.
  - "marker is git-ignored here": the marker stays local and cloud sessions will not see it. Never
    rewrite the user's ignore rules to force it in.

Files you write yourself for an accepted ask (the `CLAUDE.md` additions, `.claude/settings.json`,
a CI workflow, the house parking-lot rule, a lint policy) and the untracked docs the user accepted
go in one more result file, so step 6 sees them too:

```bash
jq -n '{wrote: $ARGS.positional}' --args <each path you wrote or the user accepted> > "$RT/out/model.json"
```

### 6. The commit

Collect every written path from the saved results, verbatim, and ask for the plan:

```bash
jq -r '.wrote[]?' "$RT"/out/*.json | tr -d '\r' | jq -Rn '[inputs | select(length > 0)] | unique' > "$RT/wrote.json"
bash "$R" commit-plan "$REPO" "$RT/preflight.json" "$RT/wrote.json" > "$RT/plan.json"; cat "$RT/plan.json"
```

It answers `{"commit": [...], "ask": [...], "notes": {...}}`. `ask` holds the paths that were
already dirty at preflight, such as a `.gitignore` the user was editing, or files set up by an
earlier run that was not committed (a step that reports `already` lists them in `wrote`, with "not
yet committed" in its detail): name each one, and include it only if the user says so, so their own
edits never ride along unannounced. A path from an earlier run that was shown and never answered,
or whose commit failed, comes back in `ask`; one the user declined stays quiet until it changes.
`notes` names paths that also hold the user's own edits: say so when you name them. (Untracked
docs the user accepted in step 5 are in `ask` too; that yes covers them.) Show the changes as one
diff and ask whether to commit them as one commit on the current branch.

On yes, `ritual.sh commit` makes the commit. It builds it in a scratch index from `HEAD` plus
exactly these paths, so nothing the user staged goes in and the user's staged work stays staged.
A file the ritual untracked and ignored (such as `.beads/interactions.jsonl`) is committed as a
deletion and stays untracked. The pre-commit hook, the secret scan included, still runs on the
commit's content. Never commit the ritual's paths with `git add` and `git commit` by hand, and
never with `git add -f`.

```bash
printf 'chore: project-start ritual\n' > "$RT/msg"
jq -r '.commit[]' "$RT/plan.json" | tr -d '\r' > "$RT/paths.txt"   # then append each `ask` path the user confirmed
mapfile -t P < "$RT/paths.txt"   # bash 4.4+: ritual.sh's version guard has already run
INC=()   # INC=(--include-dirty) only when you appended `ask` paths the user confirmed
bash "$R" commit "$REPO" --preflight "$RT/preflight.json" --message-file "$RT/msg" "${INC[@]}" -- "${P[@]}" > "$RT/commit.json"
cat "$RT/commit.json"
```

It answers `fixed` with the new commit, `already` when there was nothing to commit, or `failed` with
the cause (a path dirty at preflight without `--include-dirty`, a hook that rejected the commit, a
merge in progress). On `failed` nothing was committed and the index is as it was: show the detail.

Then make the first `handoff:` commit, holding `NEXT.md` alone, **only when `fix handoff` returned
`fixed` or `already`**. After an `unknown` fix (a linked worktree, or git could not tell) it is not
run: it would refuse with `failed` and close a step that must stay open.

```bash
hs="$(jq -r .status "$RT/out/handoff.json" 2>/dev/null | tr -d '\r')"
case "$hs" in
  fixed|already)
    bash "$R" handoff-commit "$REPO" > "$RT/handoff-commit.json"; cat "$RT/handoff-commit.json"
    cs="$(jq -r .status "$RT/handoff-commit.json" | tr -d '\r')"
    case "$cs" in failed|unknown) hs="$cs" ;; esac ;;
  "") hs="not run here: record check handoff or the user's answer by the mapping table" ;;
esac
echo "handoff status to record: $hs"
```

`handoff-commit` answers `already` when a `handoff:` commit exists. It refuses (`failed`), touching
nothing, in a linked worktree, when git cannot tell where it is, in a shallow clone with no anchor
in reach, and when other paths are staged; say which, and never unstage the user's changes
yourself.

### 7. The record

Build the results with `jq` (never the Write tool) and write them:

```bash
jq -n '{steps: {...}, baseline: {pass: <n>, fail: <n>, seconds: <n>}}' > "$RT/results.json"   # baseline only when it ran
bash "$R" record-write "$REPO" "$RT/results.json"
```

`steps` holds `{"result": "...", "note": "..."}` for every step this run handled, `preflight`,
`lessons`, `commit` and `record` included; leave out only the steps `due` skipped. Map each status
with the table below. `record-write` merges into the existing record and prints it.

`handoff` is one step id for two commands. When the block ran `fix handoff` (a result was saved
in `$RT/out/handoff.json`), its result is the status the step-6 block printed: the `fix handoff`
outcome, and the `handoff-commit` outcome goes in that step's note. When the block printed
`not run here`, record `check handoff`'s status by the table (`present`: `already`) or the user's
answer to the ask (`declined`), never `none`. Only when
`handoff-commit` ran (after a `fixed` or `already` fix) and did not make or find the anchor does its
`failed` or `unknown` become the result. A fix `unknown` stays `unknown`, so the step stays open.
Never let the second result silently overwrite the first.

Then report the record: the date, every step's result, and `open_steps`. `open_steps` lists only
`unknown` and `interrupted` steps, the ones a later run can clear. A full run on a fully set-up
repo, on a machine with every tool, leaves it empty.

## Status to record result

| Script status | Step | Record result |
|---|---|---|
| `fixed` | any fix | `done` |
| `already` | any fix | `already` |
| `present` | any check, except the two below | `already` |
| `present` | `public-sweep` (the repo is public) | `done` once the sweep ran; `declined` otherwise |
| `present` | `untracked-docs` (docs are pending) | `done` once committed; `declined` otherwise |
| `unknown` | any, including a crashed step ("step ended without a result") | `unknown` |
| `failed` | any | `failed` |
| `absent` | `oracle` (no test command found) | `none` |
| `absent` | `ci`, when `oracle` is not `present` | `na` |
| `absent` | `public-sweep` (private or internal) | `na` |
| `absent` | `untracked-docs` (nothing to commit) | `already` |
| `absent` | `stack` (no stack detected) | `none` |
| `absent` | a check whose ask was accepted and whose fix then ran | that fix's status, by this table |
| `absent` | a fix that still reports it after the user's answer (e.g. they kept their own session routine) | `declined` |
| no script | an accepted ask you did yourself: `workspace`, a `ci` workflow, `beads-seed` issues, a `stack-checks` policy, the `parking-lot` house rule, `beads-metrics` turned off | `done`; then re-run its `check` where one exists and record what that says |
| declined (the user said no) | any ask | `declined` |
| cut off before it finished | any | `interrupted` |
| no script | `beads-seed` without Beads; with no candidates | `na`; `none` |
| exit 0 | `preflight` | `done` |
| no script | `baseline` that ran, whatever the tests said | `done`, with the note "pass N, fail M" (the failures are never dropped) |
| - | `lessons`, `commit` once done | `done` (`commit` answering `already`: `already`) |
| - | `record` (this write) | `done` |

`unknown` and `interrupted` stay open. `declined`, `none`, `na`, `failed`, `done` and `already`
never do: a declined step is offered again only when that step's own version changes. The per-run
asks (`commit` and `untracked-docs`, marked `per_run` in `steps.json`) are the exception: their
question is about this run's files, so `due` offers them on every run.

## Cloud sessions

The script is built for a machine with `bd`, `gh`, `qmd` and `gitleaks`. In a cloud session it runs
what it can, and every step it cannot do comes back `unknown`. Record them as they are: the next
full run on a fully equipped machine clears them.
