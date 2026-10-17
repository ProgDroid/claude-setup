---
name: project-start
ritual_version: 1
description: Use when the user says "project start", "set up this project", "onboard this repo" or "run the ritual", or when the project dashboard's brief line says "Project-start ritual not done/behind here" - runs the project-start ritual (Beads, line-ending and ignore traps, lint policy, test oracle, secret scan, CLAUDE.md, parking lot, CI, baseline, NEXT.md handoff) and writes the ritual record
---

# The project-start ritual

One run sets a repo up the house way and leaves a record of what it did. The deterministic work is
done by `ritual.sh`, which sits beside this file: it checks, fixes and reports one JSON result per
step. You orchestrate, ask and draft.

**No step that the script can answer is answered by the model.** If `ritual.sh` has a `check` or a
`fix` for it, run that and report what it says: never judge a step's state by reading files
yourself, and never write the record by hand.

Set these once per run. The skill's base directory is shown when the skill loads; quote every
expansion, since paths may contain spaces.

```bash
R="<this skill's base directory>/ritual.sh"
REPO="$(git rev-parse --show-toplevel)"   # ritual.sh resolves any path inside the repo to this
RT="$(mktemp -d)"                          # scratch for this run, outside the repo
```

Every result is `{"id", "status", "detail", "wrote"}`. `status` is `present | absent | unknown` for
a check, and `fixed | already | failed | unknown | absent` for a fix. `wrote` lists the paths the
step changed; keep every one of them for the commit step.

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
bash "$R" check beads "$REPO"
```

- `present`: nothing to ask; record `already`.
- `unknown` (no `bd` on PATH): nothing to ask; tell the user and record `unknown`.
- `absent`: ask **"Set up Beads here? `bd init` makes its own commit."** If preflight listed dirty
  paths, the same question offers to set the user's changes aside for `bd init` only and restore
  them straight after. On yes:

```bash
bash "$R" fix beads "$REPO"            # clean tree
bash "$R" fix beads "$REPO" --stash    # dirty tree, when the user accepted the stash
```

The restore is verified by the script. If `fix beads` reports `failed`, show its detail verbatim:
when a stash is still held it names the exact command that gives the user's work back, and that
command must be run as given. A plain `git stash apply` can change line endings.

### 3. The automatic steps

Tell the user the automatic steps are running; they take about 7 to 15 seconds.

```bash
bash "$R" auto "$REPO" > "$RT/auto.json"
```

`auto` detects the stack once and runs, in order: `stack`, `traps`, `stack-checks`, `oracle`,
`parking-lot` and `beads-metrics`. The parking-lot step runs here: it creates `docs/parking-lot.md`
when absent and adds the house parking-lot rule to `CLAUDE.md`. The output is
`{"results": [...], "wrote": [...]}`. Report each result in one line.

- `stack`'s `output` lists the languages (nested ones included) and the include files to load.
  Read the matching `~/.claude/includes/<name>.md` files now.
- `oracle`'s `output` holds the test and lint commands it found. Nothing is run here. "No test
  command found" is a result, not a gap.
- `stack-checks` writes the canonical case itself. `absent` with "needs ask" (a Cargo workspace, a
  Python or Flutter project without a lint config) becomes an ask in step 5.
- `parking-lot` `absent` with "different rule exists (line N)" means the project has its own
  parking-lot rule; it is kept, and adding the house rule becomes an ask in step 5.
- `beads-metrics` `absent` means bd telemetry is on. It is a machine-wide setting: tell the user and
  offer to turn it off.
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
bash "$R" check public-sweep "$REPO"
bash "$R" check secret-scan "$REPO"
bash "$R" check untracked-docs "$REPO"
bash "$R" check ci "$REPO"
bash "$R" check handoff "$REPO"
bash "$R" candidates "$REPO"            # only when Beads is set up
```

Ask only what `due` offered and what is not already in place.

- **`public-sweep`.** `present` means the repo is PUBLIC: offer to run the
  `publishing-a-private-repo` sweep once. `absent` means private or internal: not applicable, no
  question. `unknown` (no `gh`, no auth, no GitHub remote) is never read as "private".
- **`secret-scan`.** `absent`: offer the gitleaks pre-commit scan. On yes, run
  `bash "$R" fix secret-scan "$REPO"`, then prove it with `bash "$R" check secret-scan "$REPO"`
  (announced as above). It installs where git really runs hooks, inside Beads' hook when Beads is
  set up. `unknown` with "gitleaks not found": offer to install gitleaks; until then the step stays
  open. `failed`: show the detail; the proof names what went wrong.
- **`stack-checks`**, when step 3 left it `absent` with "needs ask": show the policy the include
  file prescribes (for a Cargo workspace, `[workspace.lints.clippy]` in the root and
  `[lints] workspace = true` in each member; for Python a ruff config; for Flutter
  `analysis_options.yaml`) as a diff to append. On yes, append it and confirm with
  `bash "$R" check stack-checks "$REPO"`.
- **`workspace`.** No script answers this one. If `CLAUDE.md` is missing, draft one. If it exists
  (including one `bd init` just wrote), propose **additions** as a diff: the test command from
  `oracle`, the stack, and the decision record (`docs/superpowers/specs`). Also propose a
  `.claude/settings.json` permission allow-list covering the oracle's commands. Add what is accepted
  to the list of written paths.
- **`untracked-docs`.** `present` lists untracked files under `docs/`: offer to commit them with the
  ritual's commit. Accepted paths join the written paths.
- **`parking-lot`**, when step 3 found a different rule: offer to add the house rule (the text in
  `house/parking-rule.md` beside this file) under `## Working rules`, leaving the existing line
  alone.
- **`beads-seed`**, only when Beads is set up. Show `candidates`' items (text and source) as a list,
  and let the user pick which become issues. Create each picked one with `bd create`, and confirm
  it by listing the issues: bd's exit code is not evidence, since several bd commands exit 255 on
  success.
- **`ci`.** `absent` and `oracle` found a test command: offer a minimal workflow in
  `.github/workflows/` that runs it. `absent` with no test command: not applicable, no question.
- **`baseline`.** Always an ask, never automatic. Say that it runs the whole test suite once and
  may take a while. On yes, start what the tests need (for example a database container), run the
  oracle's test command once, record the pass count and the duration, then stop **only what you
  started**. A failing baseline is a result, not an open step.
- **`handoff`.** `present`: already set up; no question. Otherwise ask **"Set up the NEXT.md handoff
  here?"** with the default session-start question, "How did the last change go?", which the user
  accepts or edits. Offer `paths` only as a pick-list of hand-edited files seen in recent history
  (files changed by commits without a `Co-Authored-By: Claude` trailer), with "none" as the
  default; never as a blank to fill. On yes:

```bash
bash "$R" fix handoff "$REPO" --ask "<question>" --paths "<glob> <glob>"   # each flag only when changed
```

  It writes `NEXT.md`, the `.claude/handoff.json` marker and a `## Session routine` section in
  `CLAUDE.md`. `NEXT.md` is not in its `wrote`: it gets its own `handoff:` commit after step 6.
  - `absent` with "different session routine (line N)": the project has its own routine. Show it,
    and replace it only on an explicit yes: re-run with `--replace-routine`.
  - `unknown` in a linked worktree, or when git could not tell where it is: nothing was written.
    Tell the user to run it from the main checkout.
  - `unknown` (from `check handoff`) in a shallow clone: no `handoff:` commit is within reach, so
    the anchor may lie beyond the cut-off. Offer `git fetch --unshallow`, then check again.
  - "marker is git-ignored here": the marker stays local and cloud sessions will not see it. Never
    rewrite the user's ignore rules to force it in.

### 6. The commit

Collect every written path into one JSON array (`auto`'s `wrote`, each fix's `wrote`, and the files
you wrote for an accepted ask), then ask for the plan:

```bash
{ jq -r '.wrote[]' "$RT/auto.json"; printf '%s\n' <other written paths>; } \
  | tr -d '\r' | jq -Rn '[inputs | select(length > 0)]' > "$RT/wrote.json"
bash "$R" commit-plan "$REPO" "$RT/preflight.json" "$RT/wrote.json"
```

It answers `{"commit": [...], "ask": [...]}`. `ask` holds the paths that were already dirty at
preflight, such as a `.gitignore` the user was editing: name each one, and include it only if the
user says so, so their own edits never ride along unannounced. (Untracked docs the user accepted in
step 5 are in `ask` too; that yes covers them.) Show the changes as one diff and ask whether to
commit them as one commit on the current branch. On yes, commit only those paths:

```bash
printf 'chore: project-start ritual\n' > "$RT/msg"
git -C "$REPO" add -- <paths>
git -C "$REPO" commit -F "$RT/msg" -- <paths>
```

The commit runs the pre-commit hook, the secret scan included.

Then, when the handoff was accepted, make the first `handoff:` commit, holding `NEXT.md` alone:

```bash
bash "$R" handoff-commit "$REPO"
```

It answers `already` when a `handoff:` commit exists. It refuses (`failed`), touching nothing, in a
linked worktree, when git cannot tell where it is, in a shallow clone with no anchor in reach, and
when other paths are staged; say which, and never unstage the user's changes yourself.

### 7. The record

Build the results with `jq` (never the Write tool) and write them:

```bash
jq -n '{steps: {...}, baseline: {pass: <n>, seconds: <n>}}' > "$RT/results.json"   # baseline only when it ran
bash "$R" record-write "$REPO" "$RT/results.json"
```

`steps` holds `{"result": "...", "note": "..."}` for every step this run handled, `preflight`,
`lessons`, `commit` and `record` included; leave out only the steps `due` skipped. Map each status
with the table below. `record-write` merges into the existing record and prints it.

`handoff` is one step id for two commands. Its result is the `fix handoff` outcome, and the
`handoff-commit` outcome goes in that step's note. When `handoff-commit` did not make or find the
anchor, record its status (`failed` or `unknown`) as the result instead. Never let the second
result silently overwrite the first.

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
| `absent` | any other step whose ask was accepted | the result of the fix that followed |
| declined (the user said no) | any ask | `declined` |
| cut off before it finished | any | `interrupted` |
| no script | `beads-seed` without Beads; with no candidates | `na`; `none` |
| exit 0 | `preflight` | `done` |
| - | `lessons`, `workspace`, `baseline`, `commit` once done | `done` (`commit` with nothing to commit: `already`) |
| - | `record` (this write) | `done` |

`unknown` and `interrupted` stay open. `declined`, `none`, `na`, `failed`, `done` and `already`
never do: a declined step is offered again only when that step's own version changes.

## Cloud sessions

The script is built for a machine with `bd`, `gh`, `qmd` and `gitleaks`. In a cloud session it runs
what it can, and every step it cannot do comes back `unknown`. Record them as they are: the next
full run on a fully equipped machine clears them.
