# claude-setup

Personal Claude Code configuration, published as a plugin marketplace.

## Why this exists

Claude Code cloud sessions ([docs](https://code.claude.com/docs/en/claude-code-on-the-web)) run in a
fresh Anthropic-managed VM with only the repository cloned. User-scope config —
`~/.claude/skills/`, `~/.claude/agents/`, `~/.claude/commands/`, `~/.claude/CLAUDE.md` — does not
travel. Plugins declared in a repo's `.claude/settings.json` **do**: they are installed from their
marketplace at session start.

So anything that needs to work both locally and in a cloud session lives here, not in `~/.claude`.

This machine cannot run Claude Code's built-in sandbox (native Windows is unsupported, and
virtualisation BSODs here, ruling out WSL2). Cloud sessions are therefore the only available sandbox
for agentic coding work — which makes this repo the thing that keeps them usable.

## Layout

| Path | Contents |
|---|---|
| `.claude-plugin/marketplace.json` | Marketplace catalog |
| `personal/` | The one plugin: agents, commands, working-style skill |
| `snippets/project-settings.json` | Copy-paste block declaring marketplaces + plugins in any repo |
| `snippets/auto-commit-stop-hook.sh` | Stop hook that pushes WIP so an exhausted session strands nothing |
| `docs/` | Design spec and implementation plan |

## Use it in a repo

Merge `snippets/project-settings.json` into that repo's `.claude/settings.json`, then commit and push —
cloud sessions read the pushed repo, not your working tree.

## Conventions

- **No secrets.** Cloud environment variables are visible to anyone who can edit the environment, and
  there is no secrets store. Nothing credential-shaped belongs in this repo.
- **Hooks are bash, not PowerShell.** Cloud VMs are Ubuntu; PowerShell hooks silently do not run there.
- **One source of truth.** A skill lives here *or* in `~/.claude/skills/`, never both — two copies drift
  and you cannot tell which one loaded.
