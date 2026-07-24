# claude-setup

Personal Claude Code configuration, published as a plugin marketplace.

## Why this exists

Claude Code cloud sessions ([docs](https://code.claude.com/docs/en/claude-code-on-the-web)) run in a
fresh VM with only the repository cloned. User-scope config — `~/.claude/skills/`, `~/.claude/agents/`,
`~/.claude/commands/`, `~/.claude/CLAUDE.md` — does not travel. A repo's own `.claude/` directory does,
because it is part of the clone. Plugins sit in between: declaring them gets them *recognised*, not
installed.

So anything that should work both locally and in a cloud session lives here rather than in `~/.claude`.

## Layout

| Path | Contents |
|---|---|
| `.claude-plugin/marketplace.json` | Marketplace catalog |
| `personal/` | The one plugin: agents, commands, working-style skill |
| `snippets/project-settings.json` | Block declaring marketplaces + plugins in any repo |
| `snippets/README.md` | What is included, what is excluded, and why |

## Use it in a repo

Merge `snippets/project-settings.json` into that repo's `.claude/settings.json`, then commit and push —
cloud sessions clone the pushed repo, not your working tree.

## Declaring a plugin does not install it

Verified 2026-07-24 against a live cloud session, because the documentation is contradictory here.

The cloud-sessions page states that plugins declared in `.claude/settings.json` are *"installed at
session start."* They are not. The plugins page is the accurate one:

> A plugin that only the project's `.claude/settings.json` enables, and that comes from an external
> source such as a GitHub repository … doesn't load until the team member installs it.

Observed behaviour in a cloud session whose repo declared two marketplaces and nine plugins:

- `claude plugin list` → `No plugins installed`
- `claude plugin marketplace list` → only the built-in `claude-plugins-official`

`enabledPlugins` is a declaration of intent. Something has to act on it, and in an unattended cloud
session there is no one to accept the install prompt. Use an environment **setup script** to install
them explicitly. Setup scripts run before Claude Code launches and their filesystem output is cached,
so the cost is per-environment, not per-session.

## Conventions

- **No secrets.** Cloud environment variables are visible to anyone who can edit the environment, and
  there is no secrets store. Nothing credential-shaped belongs in this repo.
- **Hooks are bash, not PowerShell.** Cloud VMs are Linux; PowerShell hooks silently do not run there.
- **LF line endings**, enforced by `.gitattributes`. A bash script stored with CRLF fails on Linux with
  `bad interpreter: No such file or directory`, an error that names bash and not the real cause.
- **One source of truth.** A skill lives here *or* in `~/.claude/skills/`, never both — two copies drift
  and you cannot tell which one loaded.
- **A disabled plugin flag does not mean the capability is unused.** `context7` and `serena` are both
  `false` under `enabledPlugins` because they are registered as user-scope MCP servers instead. That
  route does not reach cloud sessions; the plugin route does.
