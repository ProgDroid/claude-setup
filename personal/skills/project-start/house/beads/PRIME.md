# Beads Workflow Context

Overrides `bd prime`'s default, which states this repo's memory policy backwards and
bans TodoWrite. `bd prime --export` dumps the default to diff against.

# SESSION CLOSE PROTOCOL

Before saying "done" or "complete":

```
[ ] bd close <id1> <id2> ...
[ ] new follow-up work filed as beads, not left in chat or .superpowers/ scratch
```

## Core rules

- **Durable task tracking is bd.** File the issue before writing the code. Anything
  that must survive the session is a bead, never a markdown TODO.
- **TodoWrite/TaskCreate is NOT durable tracking, and is NOT banned.** It carries
  within-turn execution structure — the checklist a skill hands you. bd is *what work
  exists*; TodoWrite is *how a procedure gets followed*. Use both.
- **bd owns WORK STATE ONLY.** Memory is files (the project's memory directory and any
  committed copy of it), never `bd remember`. Decisions and rulings live in docs
  (specs, plans, reviews). Do not re-propose a memory migration.
- **Bead ids in commits:** put the id alone on its own line in the commit body when the
  commit finishes that bead, so tooling can report beads named that way but still open.
- **Sync:** `.beads/issues.jsonl` is the export that travels in git (`export.auto` +
  `export.git-add`; the pre-commit shim flushes and stages it). Dolt remote sync is
  deliberately OFF (`no-push: true`, no Dolt remote) — do not wire one without asking.
- **Git authority:** none by default. Commits and pushes are the developer's call.

## Labels

- **`bleeding`** is reserved for anything whose cost ACCRUES while it sits open — money,
  data loss, silent corruption. Priority encodes importance, not a running meter. Check
  `bd list --label bleeding` before picking work off `bd ready`.
- **`needs-decision`** marks a bead that is blocked on the user, not on code. Ask, don't
  guess.
- Theme labels group the backlog (for example `test-gaps`, `security`, `ux`, `refactor`,
  `docs`). Keep the set small and reuse it.

## Commands

**Find work:** `bd ready` · `bd blocked` · `bd list --status=open|in_progress` ·
`bd show <id>` · `bd search <query>` · `bd stats`

**Create and update**
`bd create --title="…" --description="why this exists and what to do" --type=task|bug|feature|chore|epic --priority=2`
- Priority is `0-4` (0 = critical, 2 = medium, 4 = backlog). Never "high"/"low".
- `--parent=<id>` for a child of an epic. `-l/--labels` comma-separated.
- `--acceptance=` / `--design=` / `--notes=` for the structured fields.

`bd update <id> --claim` · `bd update <id> --notes/--description/--design`
`bd close <id1> <id2> …` · `bd close <id> --reason="…"`

**Dependencies:** `bd dep add <issue> <depends-on>` — the first is blocked BY the second.

**Hygiene:** `bd defer <id> --until="date"` · `bd supersede <id> --with=<new-id>` ·
`bd stale` · `bd orphans` · `bd lint` · `bd doctor`

## Traps

- **Never `bd edit`** — it opens `$EDITOR` and blocks the agent indefinitely.
- **Several bd commands exit 255 ON SUCCESS** (`bd prime` observed). Check output, not
  the exit code.
- **Closing hides the reason:** a `--reason` is invisible to `bd search`. A veto that must
  be remembered also goes into a doc or memory file.
- Auto-export is throttled by `export.interval` (default `60s`, which drops writes inside
  the window; this repo sets `1ms`, and `0s` is accepted but does nothing). It refuses to
  overwrite a non-empty export with an empty one; the pre-commit shim flushes the tail.
