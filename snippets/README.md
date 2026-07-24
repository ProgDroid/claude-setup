# Snippets

## `project-settings.json`

Merge into a repo's `.claude/settings.json`, preserving keys already there. **Commit and push** — cloud
sessions clone the pushed repo, not your working tree.

`claude-plugins-official` needs no `extraKnownMarketplaces` entry; it is registered by default.

⚠️ **Declaring is not installing.** Verified against a live cloud session on 2026-07-24: a repo declaring
two marketplaces and nine plugins produced `No plugins installed` and only the built-in marketplace
registered. See the root `README.md`. Pair this snippet with `cloud-setup.sh`.

## `cloud-setup.sh`

The script that actually installs what `project-settings.json` declares.

**It is not read from this repo.** Paste its contents into the **Setup script** field of a Claude Code
cloud environment: open the environment selector, hover an environment, click the settings icon. This
copy exists for version control and review.

Both CLI commands it relies on are verified non-interactive, defaulting to `user` scope — which is
`/root/.claude/` in a cloud VM:

- `claude plugin marketplace add <source>` — `--scope` defaults to `user`
- `claude plugin install <plugin@marketplace>` — `--scope` defaults to `user`

Design notes:

- **No `set -e`.** A non-zero exit makes the session fail to start, so every step is tolerant and the
  script always exits 0. A failed plugin install must degrade the session, not prevent it.
- **Everything is logged with a `[setup]` prefix.** On first run the build log is the only place the
  outcome is visible without spending another session asking.
- **Marketplaces must be public.** A cloud session's GitHub proxy is scoped to the session's own repo,
  so a private marketplace would likely fail to clone. This is why `ProgDroid/claude-setup` is public.
- **Cached.** Anthropic snapshots the filesystem after the script completes, so this cost is per
  environment, not per session. It re-runs when the script changes, when allowed network hosts change,
  or after roughly seven days.

Possible optimisation, untried: `claude plugin marketplace add --sparse .claude-plugin plugins` limits
the checkout via git sparse-checkout, which would cut clone time on large marketplace repos.

### Included, and why

| Plugin | Reason |
|---|---|
| `superpowers` | brainstorming / writing-plans / TDD workflow — the core process toolkit |
| `personal` | own agents, commands, working-style skill |
| `context7` | live library docs |
| `serena` | semantic code navigation and editing |
| `frontend-design`, `code-simplifier`, `commit-commands`, `claude-md-management`, `skill-creator`, `security-guidance` | general-purpose, cheap to carry |

### On `context7` and `serena` specifically

Both are `false` under `enabledPlugins` in user settings, and **both are actively used**. They are
registered as user-scope MCP servers in `~/.claude.json` instead, which is why the plugin flag is off.

That route does not reach cloud sessions — `claude mcp add` writes to user config, not the repo. The
plugin form is the one that travels, so both are enabled here. Enable them in user settings too, so
local and cloud use one mechanism rather than two.

**Do not read a `false` plugin flag as evidence a capability is unused.** Check `~/.claude.json`
alongside `settings.json` before concluding anything is unused; this exact inference was made wrongly
twice while assembling this list.

### Excluded

Add these per-repo only where they earn their place. Every plugin's skill descriptions load into context
each session for trigger matching, so a universal include list is a standing cost.

| Excluded | Reason |
|---|---|
| `qmd`, `obsidian` | Vault-only. The `qmd` binary and its index do not exist in a cloud VM |
| `starship-claude` | Statusline — meaningless in a cloud session with no TUI. Its config is backed up separately as `starship/starship.toml`; the plugin payload is deliberately gitignored because it is refetchable from `martinemde/starship-claude` |
| `typescript-lsp`, `gopls-lsp`, `rust-analyzer-lsp` | Add only to repos in that language |
| `playwright`, `semgrep` | Heavy installs; add where actually used |

### Secrets

Nothing credential-shaped goes in this repo or in a project's `.claude/settings.json`. Cloud environment
variables are visible to anyone who can edit the environment, and there is no secrets store. If a plugin
needs a key, it goes in the environment config with that visibility understood.
