---
name: synthesize-memories
description: "Periodic cross-session, cross-project curation of the Claude memory corpus. Use when the user says \"synthesize memories\", \"memory synthesis\", \"curate memories\", \"tidy my memories\", \"memory garden\", \"prune memories\", or when a SessionStart nudge reports an oversized memory index. Tiers shipped-milestone entries into a cold index, proposes promoting universally-true user facts to global CLAUDE.md, escalates repeat-learning clusters to a rule or hook, and flags memories naming files that no longer exist. Counterpart to capture-learnings: that skill RECORDS one session, this one SYNTHESISES across all of them. Never deletes a memory file."
---

# Synthesize Memories

`capture-learnings` is additive only — every session can append, nothing ever removes,
tiers, or promotes. This is the counter-force.

**Never delete a memory file.** The only mutation is moving an index *line* between tiers.

## Run the scan first

```bash
SKILL_DIR="${CLAUDE_PLUGIN_ROOT}/skills/synthesize-memories"
WORK="$(mktemp -d)"   # never a fixed /tmp name: concurrent sessions share /tmp
bash "$SKILL_DIR/scripts/resolve-roots.sh" > "$WORK/mem-map.tsv"
bash "$SKILL_DIR/scripts/scan.sh" --map "$WORK/mem-map.tsv" > "$WORK/mem-report.txt"
```

`resolve-roots.sh` searches `/g` when it exists (a Windows drive under Git Bash), else `$HOME`;
pass `--search-root DIR` (repeatable) for repos elsewhere, e.g. `--search-root /g --search-root
/mnt/work` or `--search-root "$HOME/code"`.

**Find the target repo before anything is written.** The current project's memory directory is
`~/.claude/projects/<key>/memory`, where `<key>` is `core_memory_key "$PWD"` from
`${CLAUDE_PLUGIN_ROOT}/hooks/lib-key.sh`. At home that directory is a symlink into a git repo:

```bash
. "${CLAUDE_PLUGIN_ROOT}/hooks/lib-key.sh"
MEM="$HOME/.claude/projects/$(core_memory_key "$PWD")/memory"
REPO=""; D="$(realpath "$MEM" 2>/dev/null)" || D=""   # git -C "" would silently use the cwd
[ -n "$D" ] && REPO="$(git -C "$D" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$REPO" ] && [ "$(cd "$REPO" && pwd -P)" = "$(cd "$HOME" && pwd -P)" ] && REPO=""   # a git-tracked $HOME is not a memory repo
```

An empty `REPO` means proposal-only.

**If that finds no repo, this run is proposal-only: print the proposals and write nothing.** That
is the normal case on a machine whose memory lives only under `~/.claude`.

On the **first ever run**, before applying anything, show the user the DEMOTE CANDIDATES
list and the count of entries you intend to move, and get approval. After that first run,
demotions apply automatically per invariant 4 (see the idempotency check under DEMOTE
CANDIDATES below — it's what keeps auto-apply safe on every run after the first).

Read `$WORK/mem-report.txt`. **Do not read the memory corpus itself** on the default path —
the report is the interface. Reading all bodies costs ~519k tokens; the report costs a few
tens of KB.

**Set expectations before you run it.** The scan now takes **over five minutes**: on 2026-10-19 it
outlived a 300 s foreground timeout. It measured ~57 s when the corpus was ~22 projects, but
scratchpad-named project dirs now inflate the map to ~38. **Run it with `run_in_background` and put
`echo SCAN_EXIT=$?` after it**, and don't assume a hang. The map and report live under the
`mktemp -d` directory above. The 2026-10-19 report
was 133 KB, with 80 demote rows, ~290 scope candidates, ~1,040 cluster rows, ~225 dead-ref rows and
no orphans (the earlier baseline: 90-95 KB, 50-60 / ~230 / ~750). These shift as the corpus grows;
treat them as a sanity range, not a spec.

**DEAD REFS is counted two ways and they are both correct**, so say which you mean. Measured
2026-07-20 on an unchanged corpus: **135 rows** but **122 distinct missing paths**. A row is
one memory-file × one reference, so a path cited by three memories produces three rows. The
scan is deterministic — if two counts of the "same" thing disagree, one of them is counting
rows and the other distinct paths, not drift.

## What you decide (the scripts decided everything else)

### INDEX SIZES → compact the fat lines (try this BEFORE demoting)

The report's first section has the most leverage and is the easiest to skip, because nothing in it
is labelled a "candidate". **Index cost is BYTES, not lines.** The SessionStart nudge measures
bytes: an index over 15,000 bytes, or any single index line over 1,000 bytes, trips it
(`memory-index-nudge.sh`). This report's `over_threshold` column still counts *lines* (threshold
60), a proxy that assumes uniform line length — and it fails on exactly the pathology worth
catching: a whole changelog crammed into one index hook. Measured 2026-07-25: one project's index
was ONE line of 7 KB and tripped nothing under the old line count.

So when an index is too big, sort by bytes and rewrite the fattest few hooks:

```bash
M="$HOME/.claude/projects/<project>/memory/MEMORY.md"
awk '{print length($0)"\t"substr($0,1,80)}' "$M" | sort -rn | head -12
wc -c "$M"
```

**Rewriting the top handful beats demoting dozens of entries.** Worked example, one project
2026-09-01: 21,161 → 17,065 bytes with **zero** entries demoted and all 56 kept hot; the fattest
single hook was 1,846 bytes and came down to 485. On the same corpus, demotion measured **0 of 23**
genuine candidates.

Two rules make the trim safe:

- **Prove the detail survives first.** Grep the linked topic file for a distinctive token from the
  part you are cutting. An index hook is a pointer; trimming it is only safe once the file it points
  at demonstrably carries what you are removing.
- **Keep the load-bearing half.** The standing guardrail ("REJECTED on evidence, don't re-propose
  X") and the NEXT pointer are what earn an index line its bytes. Commit SHAs and blow-by-blow
  detail are what the topic file is for.

Key the rewrite on the **link target**, never on the line text — same reasoning as the demote
idempotency check below. A script that matches `](<filename>.md)` and refuses to write when any
target is unmatched cannot silently half-apply.

**Collapsing several hooks into one pointer** is the third lever, and it has one rule, stated by
the user (2026-10-05): **only a hook that is purely a pointer to a page that exists elsewhere may
collapse; any hook carrying its own content stays as its own line.** Worked case (an invented
example): 5 index lines that each only pointed at a page under a recipes folder became one line
pointing at that folder's index page (each target checked to exist and to be listed there), while a
line carrying a unit-conversion convention stayed. The collapsed lines MOVE to the cold tier rather
than vanish, so every memory file stays indexed. Expect modest savings: the replacement line must
name what it absorbed to stay findable, so it is longer than a bare pointer and the saving is
smaller than the count of absorbed lines suggests.

### DEMOTE CANDIDATES → auto-apply

For each candidate, judge: **is this a finished-milestone record, or a live "what's next"
pointer?**

- `"Track 4 fully done end-to-end"` → demote.
- `"Steps 1+2 shipped; step 3 is next"` → **keep hot**. It matched the regex but it is a
  live pointer.

For entries you demote: create `MEMORY-history.md` from `references/cold-tier-format.md`
if absent (and add the pointer line to `MEMORY.md`), then move the index line into it under
an appropriate `## ` theme heading. Create the cold tier **before** removing the hot line,
so an interrupted run leaves the entry indexed twice rather than not at all. This is the
only auto-applied change.

The moved line is **not** byte-identical to the hot one: per `references/cold-tier-format.md`
the cold tier adds a date to the title — `- [Track 2 complete (2026-05-01)](file.md) — hook`
where the hot index had `- [Track 2 complete](file.md) — hook`. Keep the link target and the
hook unchanged; only the title gains the date.

**Idempotency:** the script never suppresses an entry just because it was already demoted
last run — the memory file is never deleted (invariant 1), so an already-cold entry's
description still matches the completion pattern, and it reappears in DEMOTE CANDIDATES
every time. That's deliberate, not a bug: `scan.sh` does only decidable matching, you do
the judgement, so don't "fix" the script to suppress it.

**Match on the link target, never on the line text.** Before acting on a candidate, check
whether `MEMORY-history.md` already contains a line whose link target is that file — i.e.
grep for `](<filename>.md)`. Do **not** compare whole lines: the cold tier adds a date to
the title by design, so an already-demoted entry's cold line never equals its old hot line,
and a whole-line check would report "not yet demoted" on every run and duplicate the entry
into `MEMORY-history.md` forever.

If the link target is already in the cold tier, the entry is handled. Then:
- if a line for it **still remains** in `MEMORY.md`, delete that stale hot line (a previous
  run was interrupted between the two writes, or the line was re-added) — this is the one
  case where you remove a hot line without adding a cold one, and it is safe precisely
  because the cold entry already exists;
- otherwise do nothing at all for that candidate.

Never add a second cold entry for a link target that already has one.

### SCOPE CANDIDATES → propose

Judge: **is this universally true, or specific to that project?**
`user-android-only` is universal; `myapp-sdd-test-gotcha` is not.

Then pick the destination:

| Fact is | Goes to |
|---|---|
| Home-only (this user's machine, repos, tools) | The discovered repo's global `CLAUDE.md` (one tight line; it is loaded on every turn, so brevity is the whole constraint) |
| Shared (should hold on every machine) | The **promotion flow** defined in `capture-learnings`, and only when `CLAUDE_SETUP_CLONE` is set |
| Shared, but `CLAUDE_SETUP_CLONE` is unset (work machine) | The work global `~/.claude/CLAUDE.md`, written only when it resolves (`realpath`) inside the discovered repo; otherwise proposed, not written |

A home-only fact needing more than a line goes in a home-only skill in the discovered repo, proposed, not written. With no discovered repo (proposal-only run) every promotion is proposed, not written.

Promotion **copies**, never moves:
1. Add the rule to the chosen target. For a global `CLAUDE.md`: it is prose, not frontmatter —
   match its existing style and give the new rule a trailing parenthetical provenance note, e.g.
   `(promoted_from: <project>/<file>, 2026-07-20)`, the same way existing rules there append
   dated evidence.
2. Add `promoted_to: global` — or `promoted_to: core` for the promotion flow — to the project
   memory file's own YAML frontmatter (memory files do have real frontmatter — see the memory
   format in your system prompt).
3. **If the target was a repo (the promotion flow's clone), commit and push through that flow**,
   and say so in the report. An uncommitted promotion reaches no other machine, and nothing will
   warn you.

The project memory keeps the detail and dated evidence; the target carries the actionable rule.
Propose as a diff and wait for approval.

### CLUSTERS → propose

The section lists **term, memory count, project count only** — no member list, because
emitting members made this section over 300 KB of a 400 KB report; the report is ~90-95 KB
without them. Expect a long tail (hundreds of rows); scan it, and pull members only for the
few terms worth investigating:

```bash
grep -li '<term>' "$HOME/.claude/projects"/*/memory/*.md
```

This greps full file bodies and is a superset of what the report counted — the report only
tokenizes each memory's `name` + `description` frontmatter, so a body-only mention of the
term will show up in the grep but wasn't counted toward the cluster's memory/project totals.
Treat it as a candidate list to skim, not an exact membership match.

Judge: **do these memories encode one underlying fact?** If yes, propose the next rung —
a CLAUDE.md rule, a skill, or a hook that makes the mistake impossible. Noisy clusters are
expected; say "no cluster here" freely. `powershell` (6 memories, 3 projects) is the
worked example of a real one — run the grep above on it to see the shape of a genuine find.

### DEAD REFS → propose

Judge: **is the memory now wrong, or correctly describing history?** A memory saying "we
removed `src/old.rs`" naming a file that no longer exists is correct, not stale.

**It over-reports far more than it misses — expect ~5% true positives.** Two structural causes:
metasyntactic placeholders (`path/to/thing.md`), and **cross-repo paths**. The scan resolves every
backticked path against the memory's OWN project root, so a memory in one project citing
a lessons file kept in a different repo and referenced from the global CLAUDE.md — is reported
dead while being perfectly live (for probe lessons: the `probe-discipline` skill holds the content;
at home, the queue in `learnings/probe-failures.md` if it exists). On the 2026-09-01 run, 178 rows /
147 distinct paths were almost entirely cross-repo references plus deploy-host state files
(`watchlist.json`, `state.json`) that correctly describe a *host*, not a repo. **Spot-check two or
three before proposing anything, and never bulk-edit out of this section.**

**It also has a documented blind spot in the other direction.** It only checks backticked paths whose
extension is on a known allowlist (source/config extensions like `.rs .py .ts .md .json
.yaml` etc.), plus a short list of extension-less filenames (`Dockerfile`, `Makefile`,
`LICENSE`, `Procfile`, `Justfile`, `Rakefile`, `Gemfile`, `.env`). A reference with an
extension outside that list is **silently skipped and never reported** — it is not proof
the reference is fine. This is a deliberate trade (the looser version was ~80% false
positives, and a false dead-ref report costs more than a missed one), but don't mistake
"not flagged" for "verified live."

### ORPHAN PROJECTS → report only

Never auto-archive. Just tell the user which memory dirs have no live project.

## Safety invariants

1. Never delete a memory file.
2. Create the cold tier before removing any hot line.
3. Write only inside the discovered repo.
4. Auto-apply demotions only. Everything else is a proposed diff.
5. One commit per run, via the Bash tool with `git commit -F -` and a single-quoted
   heredoc (git-standards, the Windows BOM rule: never commit from PowerShell).
   Stage only the files you changed; the repo carries unrelated uncommitted work.
6. Idempotent — a second run with nothing changed writes nothing.

## `--deep` (contradiction detection)

Requires **explicit confirmation**. Passing `--deep` requests the pass; it does not
authorise it.

State the cost first: *"This dispatches ~21 read-only subagents, roughly 500k tokens
total. Proceed?"* If declined, finish the default run normally rather than aborting.

On approval, dispatch one read-only subagent per memory dir with a live root. Each reads
only its own project's memory bodies and returns conflicts as
`{file_a, file_b, claim_a, claim_b, confidence}`. Subagents never write. Treat any
any promoted pair as a contradiction candidate — `promoted_to: global` (the rule lives in
a global `CLAUDE.md`) or `promoted_to: core` (it went through the promotion flow into `core`).
That is how promotion drift is caught, and the `core` target drifts more easily: a promotion
that was never committed and pushed is live locally and absent everywhere else, with nothing to
warn you.

## Reporting format

End with a short summary:

```
Demoted:   N entries across M projects (auto-applied, commit <sha>)
Promoted:  N proposed, N approved
Escalated: N clusters -> <target>
Dead refs: N flagged, N confirmed stale
Orphans:   <project list>
```

Silence is a valid outcome. A corpus with nothing to tier and no clusters produces
"nothing to do" — say so and stop.
