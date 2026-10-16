## Session routine

- **Handoff.** This repo follows the `handoff` skill (`NEXT.md` plus `handoff:` commits); read it for the rules.
- Session start: ask the `.claude/handoff.json` question and log the dated answer in `NEXT.md`'s feedback log.
- Then show what changed since the newest commit whose subject starts `handoff:`.
- Session end: update `NEXT.md` and commit it on its own, with a subject starting `handoff:`.
- A squash merge to the default branch also gets a subject starting `handoff:`.
