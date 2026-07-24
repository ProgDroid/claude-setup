---
name: capture-learnings
description: End-of-task or pre-/clear or pre-/compact audit that captures session learnings into the right surface — memory file, CLAUDE.md, a new skill, or a hook. Use when the user says "capture learnings", "record learnings", "save learnings", "wrap up the session", "before I /clear", "before I /compact", "update memories", or any equivalent end-of-session or end-of-task phrasing. Goes beyond memory by also evaluating whether each learning belongs in CLAUDE.md, a new or updated skill, a hook, or nowhere. Silence is a valid outcome — routine work produces nothing worth saving.
---

# Capture Learnings

The user is about to lose conversation context (`/clear`, `/compact`, end of session, end of task) and wants any net-new, non-obvious learnings persisted to the right surface so the next session does not re-derive them.

## The core question for every candidate learning

**"Will a future-me with no memory of this conversation be worse off without this written down?"**

If no → do not save it. Silence is the right answer for routine work.
If yes → which surface? See the decision tree below.

## Decision tree: where does each learning land?

Walk this top-to-bottom for each candidate. Stop at the first match.

1. **Is it a fact about the user themselves** (role, preferences, expertise level, working style)?
   → **`user` memory**.
2. **Is it a correction or confirmed-good approach the user gave** ("don't do X because…", "yes that bundled-PR call was right")?
   → **`feedback` memory**. Lead with the rule, then **Why:** and **How to apply:**.
3. **Is it project state that changes over time** (current phase, deadlines, who-is-doing-what, decisions made)?
   → **`project` memory**. Convert relative dates to absolute. Lead with the fact, then **Why:** and **How to apply:**.
4. **Is it a pointer to where information lives in an external system** (Linear project, Grafana dashboard, internal wiki page)?
   → **`reference` memory**.
5. **Is it a workflow or convention that applies to EVERY session in this project** and is short enough to read on every turn?
   → **CLAUDE.md** (project-local). Use the `claude-md-management:revise-claude-md` or `claude-md-management:claude-md-improver` skill if available; otherwise edit directly. Keep entries tight — CLAUDE.md is always loaded.
6. **Is it a multi-step procedure that you will re-execute across multiple sessions or projects**, with reusable scripts/templates/decision trees?
   → **New or updated skill** (use the `skill-creator` skill). Project-specific → project-local skill (the repo's `.claude/skills/`). Cross-project → the **`personal` plugin** in the `claude-setup` repo, under `personal/skills/`, then commit and push.

   `~/.claude/skills/` is no longer a valid destination for anything that should be available beyond this machine. It does not reach cloud sessions — user-scope config is not part of the repo clone — and a skill that lives both there and in the plugin will drift with no way to tell which copy loaded.
7. **Is it an automated behavior tied to a specific event** (PreToolUse, Stop, SessionStart, PreCompact, etc.) that should fire without the user asking?
   → **Hook** (use the `update-config` skill to wire into `settings.json`). Strongly justify before adding — hooks fire on every matching event and burn tokens; a skill the user invokes manually is usually the better fit.
8. **None of the above** → do not save it.

## Route by audience, not just by type

The decision tree picks the *kind* of surface. This picks *where that surface lives*, which is a
different question and the one that determines whether the learning survives.

| Content | Destination | Why |
|---|---|---|
| How the user works — decision style, what they want defended, delivery preferences | `personal/skills/working-style/` in the `claude-setup` repo | Needed on brand-new projects, and reaches cloud sessions |
| Facts true only of this codebase | the repo's own `CLAUDE.md` or `.claude/` | Travels with the repo, so cloud sessions get it from the clone |
| Private observations, or anything you would not want a collaborator reading | `~/.claude/projects/<slug>/memory/` | Stays local by design, and correctly does not travel |

Two consequences worth stating explicitly:

- **A learning routed to the plugin is invisible until pushed.** Say so, and commit it — an
  uncommitted working-style change reaches no cloud session and no other machine.
- **Memories written inside a cloud session are ephemeral.** The VM is reclaimed after a period of
  inactivity, so `~/.claude/projects/.../memory/` there does not survive. In a cloud session, route
  anything worth keeping to the repo instead, where the branch push preserves it.

## The audit pass

Run this whenever the user invokes the skill:

1. **Scan the conversation for candidates.** Look for:
   - Things the user corrected ("no, do not do that because…")
   - Approaches the user explicitly approved ("yes, that is the right call")
   - Codebase conventions you discovered the hard way (failed first attempt → "oh, it is actually X")
   - Bugs whose root cause is non-obvious from the fix itself
   - Decisions made about scope, deferrals, or sequencing
   - State changes (phase complete, ticket closed, deadline shifted)
   - External-system pointers the user mentioned for the first time
   - Tooling gotchas you tripped over (lint warnings, build flags, environment quirks)
2. **Triage each candidate against the core question.** Most candidates fail it. That is normal and good.
3. **Cross-check against existing memory before writing.** Read `MEMORY.md` (project memory dir is `~/.claude/projects/<project-slug>/memory/`). Prefer **updating an existing memory** over creating a new one — fragmentation makes recall harder. The auto-memory system prompt rule "do not write duplicate memories" applies here.
4. **For each surviving candidate, route via the decision tree above** and write/update accordingly.
5. **Update `MEMORY.md`** with one-line index entries for any new memories. Keep it under 200 lines (truncation point).
6. **Report back** with a tight summary: what was saved, what was updated, what was considered and dropped.

## "Silence is fine" — when to save nothing

Routine sessions produce nothing worth saving:
- A single bug fix where the root cause is obvious from the diff
- A code-search session that just answered "where is X?"
- An implementation that followed an existing pattern without surprises
- A conversation that consisted entirely of clarifying questions and trivial commits

Saying "audited, nothing new worth saving" in one sentence is a successful outcome. Do not pad memory just to look productive.

## Anti-patterns to avoid

- **Saving the WHAT instead of the WHY.** "We added a CalendarEditorMapper" is what `git log` is for. "When writing a new mapper, every method should delegate to a static `_in_tx` helper because tests need rollback isolation" is the kind of WHY worth saving.
- **Saving plan-of-record details that belong in the plan file.** If the project has a `docs/superpowers/plans/*.md` or similar, phase progress goes there, not in memory. Memory should be the conventions and learnings the plan cannot capture.
- **Creating a new memory when you could update one.** Always grep `MEMORY.md` first. A 30-second check beats two memories saying overlapping things.
- **Adding to CLAUDE.md what belongs in memory.** CLAUDE.md is loaded on every turn — every line costs context for every future task in this repo. Memories load only when relevant. Default to memory; promote to CLAUDE.md only when truly always-applicable AND short.
- **Building a hook for what should be a skill.** Hooks fire on events the user cannot suppress; skills fire when the user wants. If the user can do without the automation 80% of the time, it is a skill, not a hook.
- **Treating skills/hooks/CLAUDE.md as afterthoughts.** The user usually expects this skill to consider all four surfaces, not just memory. State explicitly when each was considered and why memory was (or was not) the right home.

## Reporting format

End the audit with a structured summary:

```
**Saved (new memories):** [list, or "none"]
**Updated (existing memories):** [list, or "none"]
**Other surfaces touched:** [CLAUDE.md / skill / hook changes, or "none considered"]
**Considered and dropped:** [one-line reason for each, or "nothing else surfaced"]
```

This makes the audit auditable. The user can spot omissions and push back.
