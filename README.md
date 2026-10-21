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
| `core/` | Shared plugin installed on every machine: rules, memory curation, learning capture, working style, SDD controller, the home-only promotion script (no pinned version) |
| `personal/` | Home-only plugin: agents, the OpenCode adapter; declares `core` as a dependency |
| `scripts/` | `run-all-tests.sh`, `check-rules-budget.sh`, `privacy-scan.sh`, `linux-skip.txt` |
| `.github/workflows/ci.yml` | CI: all tests on Linux, rules budget, gitleaks |
| `personal/skills/project-start/` | Project-start ritual: a script that sets a repo up the house way, and a record of what it did |
| `personal/skills/handoff/` | The NEXT.md handoff routine, with the hooks that enforce it |
| `snippets/project-settings.json` | Block declaring marketplaces + plugins in any repo |
| `snippets/README.md` | What is included, what is excluded, and why |
| `snippets/work-machine-setup.md` | The prompt a work-machine session follows to bring its `~/.claude` in line (plugins, memory, the rules link) |
| `~/.claude/rules/core` (a link, not a file in this repo) | Symlink to `~/.claude/plugins/marketplaces/progdroid/core/rules`, so the shared rules load as user rules; no hook creates or checks it |

## Upgrading from 0.14.x

`personal` 0.15.0 declares `core` as a dependency. A fresh `claude plugin install personal@progdroid`
installs both. An existing install is different: `claude plugin update personal@progdroid` moves to
0.15.0 but does not install `core`, and `personal` then shows "failed to load" (measured on claude
2.1.304). Run `claude plugin install personal@progdroid` once after updating; it reports
"+ 1 dependency: core" and both load. Cloud environments do this on their own, because the setup
script runs that install every session.

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
- **A disabled or missing plugin flag does not mean the capability is unused.** `context7` is not
  enabled as a plugin locally because it is registered as a user-scope MCP server instead. That route
  does not reach cloud sessions; the plugin route does.
