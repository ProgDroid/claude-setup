# Cold-tier index format (`MEMORY-history.md`)

The second-tier index. Holds shipped-milestone entries demoted out of `MEMORY.md`
so the always-loaded index stays lean, without losing the done/not-done ledger.

Proven in production on the home machine's memory dirs (a live, fully-populated example: any
project's `MEMORY-history.md` beside its `MEMORY.md`).

## File shape

```markdown
# Memory History - <project> (shipped milestones)

Archived from `MEMORY.md` to keep the always-loaded index lean. These are "work shipped"
markers. **Not auto-loaded each session.** Read on demand when you need context on past
work; the full detail lives in each linked topic file and in git history.

## <Theme, e.g. "Monetisation refinement (all complete)">

- [Title (YYYY-MM-DD)](file_name.md) — one-line hook.
```

## Rules

- Entries are grouped under `## ` theme headings, not left as one flat list.
- Each line keeps the `- [Title](file.md) — hook` shape used by `MEMORY.md`, with one
  deliberate difference: the **title gains a date** (`- [Track 2 complete (2026-05-01)](…)`),
  since a cold entry is a point-in-time milestone. The link target and the hook are
  unchanged. A moved line is therefore **not** byte-identical to its hot original.
- Because of that, **identity is the link target, never the line text**. Anything checking
  whether an entry is already demoted must match `](<filename>.md)`. A whole-line comparison
  will never match a previously-demoted entry and will duplicate it on every run.
- The linked file is **never moved, renamed, or deleted** — only its index line relocates.
- When a project's cold tier is first created, add this pointer as the first list item of
  `MEMORY.md`, immediately under the H1:

  ```markdown
  - [📁 Historical milestones](MEMORY-history.md) — <themes>. NOT auto-loaded; read on demand for past-work context.
  ```

- Entries superseded by a later milestone keep a parenthetical note rather than being
  removed: `(Superseded by v1.)`
