---
name: cloud-sessions
description: Use when working with Claude Code cloud sessions, plugin marketplaces, or hooks - covers behaviour that contradicts the documentation and cost real sessions to discover
---

# Cloud sessions: what actually happens

Verified against live cloud sessions on 2026-07-24/25. Where this disagrees with the docs, the
docs are wrong — each item below was established by observing a real session, not by reading.

## Declaring a plugin does not install it

The cloud-sessions doc says plugins declared in a repo's `.claude/settings.json` are *"installed
at session start."* They are not.

A session whose repo declared two marketplaces and nine plugins reported:

- `claude plugin list` → `No plugins installed`
- `claude plugin marketplace list` → only the built-in `claude-plugins-official`

`enabledPlugins` is a declaration of intent. Something has to act on it, and an unattended session
has nobody to accept the install prompt. **Use an environment setup script** that runs
`claude plugin marketplace add` then `claude plugin install` explicitly. Both CLI commands are
non-interactive and default to `user` scope.

Add `anthropics/claude-plugins-official` explicitly too. It is registered by default but its
catalog is not fetched at setup-script time, so installs from it silently resolve to nothing —
a run that added only custom marketplaces installed both of their plugins and none of the eight
official ones.

## A SessionStart hook cannot deliver files to its own session

The memory subsystem reads its index when the session starts. A `SessionStart` hook runs after
that, so **files it writes are not picked up by the session that ran it.** Locally that is
survivable — the next session sees them. A cloud VM has no next session.

A hook that copied 13 memories into place reported `Loaded 13 memories` and the session then had
none of their content. The copy succeeded; the outcome did not happen.

**A SessionStart hook's stdout IS injected into the session as context.** So a hook that wants the
model to know something must *print* it, not write it. Print an index and let the model read
bodies on demand — that keeps startup cost flat as the corpus grows.

## Project key format

`~/.claude/projects/<key>/` where the key is the absolute path with separators, spaces **and
underscores** all replaced by `-`.

| Platform | Path | Key |
|---|---|---|
| Cloud VM | `/home/user/repo` | `-home-user-repo` |
| Windows/MSYS | `/g/rustDev/aba` | `G--rustDev-aba` |
| Underscores | `/g/flutterDev/dynamic_day_planner` | `G--flutterDev-dynamic-day-planner` |

Cloud cwd is always `/home/user/repo`. Deriving the key wrongly fails **silently** — the write
lands in a directory nothing reads, with no error. Underscore normalisation was missed twice, in
two separate files, and both times the symptom was nothing happening.

## Only what is in the clone is guaranteed

Three delivery mechanisms, not equally reliable:

1. **Part of the clone** — `.claude/skills|agents|commands|rules/`, `CLAUDE.md`, `.mcp.json`,
   and anything else committed. No fetch, no auth, no install. Guaranteed.
2. **Setup script** — runs as root pre-launch, output cached per environment. Reliable, needs
   authoring.
3. **Declared plugins** — recognised but not installed. Requires (2) to work at all.

Prefer tier 1 wherever both are possible.

User-scope config never travels: `~/.claude/CLAUDE.md`, `~/.claude/skills|agents|commands/`,
plugins enabled only in user settings, and MCP servers added with `claude mcp add`. A `false`
flag under `enabledPlugins` does **not** mean the capability is unused — it often means it is
registered as a user-scope MCP server instead, which is exactly the form that does not travel.

## Committing `.claude/` when it is gitignored

`.claude/` + `!.claude/memory/` does **not** work. Git does not descend into a fully-ignored
directory, so the negation never matches. Use:

```gitignore
.claude/*
!.claude/memory/
```

This fails quietly: `git add` stages nothing, the commit is a clean no-op, and the files sit
untracked. **Verify with `git ls-files`, not with the commit's exit status.**

## Permission rules

Under `--dangerously-skip-permissions`, `deny` and `ask` rules are the only ones still evaluated.
They are therefore the only available control in that mode, and `ask` still prompts.

Path syntax differs from sandbox settings and from intuition:

| Pattern | Resolves to |
|---|---|
| `//path` | absolute from filesystem root |
| `~/path` | home directory |
| `/path` | relative to the settings file that declares it |
| `path`, `./path`, `**/path` | relative to the current working directory |

So `Read(**/*.pem)` means `<cwd>/**/*.pem`, not "every .pem anywhere". A single leading slash is
**not** absolute.

`Write(...)` rules are not evaluated by file permission checks at all — they emit a startup
warning. `Edit(...)` covers every file-editing tool; use it.

An `Edit(~/.claude/settings.json)` deny rule works, and locks the agent out of its own settings
permanently. That is the point, but it means future settings changes are a manual operation.
