# Snippets

## `project-settings.json`

Merge into a repo's `.claude/settings.json`, preserving any keys already there. **Commit and push** —
cloud sessions clone the pushed repo, not your working tree, so an uncommitted settings file has no
effect remotely.

`claude-plugins-official` needs no `extraKnownMarketplaces` entry; it is registered by default.

### What is included, and why

| Plugin | Reason |
|---|---|
| `superpowers` | brainstorming / writing-plans / TDD workflow — the core process toolkit |
| `personal` | own agents, commands, working-style skill |
| `context7` | live library docs. **Note:** locally this works via a user-scope MCP server in `~/.claude.json`, which does *not* reach cloud sessions. The plugin form is the one that travels — enable it in user settings too, so local and cloud use one mechanism rather than two |
| `frontend-design`, `code-simplifier`, `commit-commands`, `claude-md-management`, `skill-creator`, `security-guidance` | general-purpose, cheap to carry |

### Deliberately excluded

Add these per-repo only where they earn their place — every plugin's skill descriptions load into
context each session for trigger matching, so a universal include list is a standing tax.

| Excluded | Reason |
|---|---|
| `qmd`, `obsidian` | Vault-only. The `qmd` binary and its index do not exist in a cloud VM |
| `starship-claude` | Statusline; meaningless in a cloud session |
| `typescript-lsp`, `gopls-lsp`, `rust-analyzer-lsp` | Add only to repos in that language |
| `playwright`, `semgrep` | Heavy installs; add where actually used |
| `serena` | Currently disabled in user settings |

### Secrets

Nothing credential-shaped goes in this repo or in a project's `.claude/settings.json`. Cloud
environment variables are visible to anyone who can edit the environment, and there is no secrets
store. If a plugin needs a key, it goes in the environment config with that visibility understood.
