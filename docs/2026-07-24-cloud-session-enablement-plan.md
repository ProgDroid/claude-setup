# Cloud Session Enablement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Claude Code cloud sessions usable with the existing toolchain, so GitHub-hosted code work can move off the unsandboxable Windows desktop.

**Architecture:** Cloud sessions clone the repo and install only what the repo declares. So the work is: (a) declare the already-public marketplaces and plugins in a reusable project settings snippet, (b) package the small genuinely-personal corpus as one GitHub-hosted plugin, (c) add a Stop hook so allowance exhaustion never strands work, (d) harden local sessions that can never be sandboxed.

**Tech Stack:** Claude Code plugins/marketplaces, `.claude/settings.json`, bash hooks, git.

## Global Constraints

- Plugin sources in cloud sessions must be **git-hosted**, never local directory paths — a `"source": {"source": "directory", ...}` entry cannot resolve in a cloud VM.
- Hooks that must run in cloud sessions must be **bash**, not PowerShell — cloud VMs are Ubuntu 24.04.
- Commit messages go through the **Bash tool, never PowerShell** (PowerShell prepends a UTF-8 BOM to commit subjects). For messages containing backticks, `$`, or `!`, use `git commit -F -` with a single-quoted heredoc.
- `python` on this machine is winpty-wrapped and fails with "stdin is not a tty" — use `py`.
- Marketplace `name` must be kebab-case and is globally unique per user: adding a second marketplace with the same name replaces the first.
- No secrets in the plugin repo. Cloud environment variables are visible to anyone who can edit the environment; there is no secrets store.

---

## File Structure

Created in a new repo `ProgDroid/claude-setup` (public or private — see Task 1 open question):

| Path | Responsibility |
|---|---|
| `.claude-plugin/marketplace.json` | Marketplace catalog listing the one personal plugin |
| `personal/.claude-plugin/plugin.json` | Personal plugin manifest |
| `personal/agents/` | `job-extractor.md`, `vue-i18n-auditor.md` |
| `personal/commands/` | `cr.md`, `cr-fx.md`, `deep-research.md`, `explore.md`, `git/` |
| `personal/skills/` | Only genuinely-authored skills (see Task 3 triage) |
| `snippets/project-settings.json` | Copy-paste block declaring marketplaces + plugins for any repo |
| `snippets/auto-commit-stop-hook.sh` | The Stop hook, sourced into repos that want it |
| `docs/` | The design spec and this plan, moved out of scratchpad |

---

### Task 0: Prune the skills corpus

Runs first, by user decision — Task 3 should package a clean set rather than migrate ~46 skills that
would then be deleted from git history.

**Critical mechanic, verified 2026-07-24:** `~/.claude/skills` is a **symlink** to
`G:/Users/Nando Ferreira/Documents/dotfiles/ai/skills/`, and that repo is `ProgDroid/dotfiles` on GitHub.
Most of `~/.claude` is symlinked the same way — `agents`, `commands`, `hooks`, `includes`, `plugins`,
and `projects` (the memory corpus). Therefore:

- Deleting from `~/.claude/skills/` deletes from the dotfiles working tree. **Never `rm -rf` blind.**
- Every deletion is recoverable from dotfiles git history, so this is safe *provided it is committed*.
- The dotfiles tree is currently dirty (10+ modified files, including memory updates). Commit those
  first so the prune lands as one isolated, reviewable commit.

**Files:**
- Delete: 46 directories under `dotfiles/ai/skills/`
- Modify: nothing else

- [ ] **Step 1: Do NOT commit the existing dirty tree**

The dotfiles tree has ~10 unrelated modified files (memory updates, plugin state, `.serena/project.yml`).
Leave them alone — they are the user's changes, unreviewed. Isolate the prune instead by committing
**only the skills path**: `git rm` stages the deletions, then `git commit -- ai/skills` commits that path
alone regardless of what else is staged.

- [ ] **Step 2: Delete group A — redundant, superseded by enabled plugins**

```bash
cd "G:/Users/Nando Ferreira/Documents/dotfiles/ai/skills"
git rm -r frontend-design skill-creator document-skills debugging/systematic-debugging claude-code
```

`claude-code` is deleted by user decision 2026-07-24: it overlaps the `claude-code-guide` agent, and
live doc fetches are more current than a static skill. The four Office skills (`docx`, `pdf`, `pptx`,
`xlsx`) are **kept** by the same decision — no other skill in the set covers Office file handling.

`document-skills/` holds a second copy of docx/pdf/pptx/xlsx; the top-level copies are kept.
`debugging/systematic-debugging` duplicates `superpowers:systematic-debugging`.

- [ ] **Step 3: Delete group D — downloaded collection, not authored here**

```bash
git rm -r changelog-generator competitive-ads-extractor content-research-writer \
  developer-growth-analysis domain-name-brainstormer file-organizer image-enhancer \
  invoice-organizer lead-research-assistant meeting-insights-analyzer raffle-winner-picker \
  skill-share slack-gif-creator video-downloader notebooklm-skill shopify internal-comms \
  datadog-entity-generator google-adk-python better-auth
```

- [ ] **Step 4: Delete group E — user decision 2026-07-24**

Two were judged potentially useful but replaceable by Claude's own design skills.

```bash
git rm -r aesthetic canvas-design theme-factory brand-guidelines ui-styling \
  artifacts-builder web-artifacts-builder anthropic-architect anthropic-prompt-engineer \
  openai-prompt-engineer engineer-skill-creator backend-development frontend-development \
  databases devops web-frameworks media-processing chrome-devtools webapp-testing \
  mcp-builder sequential-thinking template-skill
```

- [ ] **Step 5: Verify what survives**

Run: `ls -1d "G:/Users/Nando Ferreira/Documents/dotfiles/ai/skills"/*/ | wc -l`
Expected: **19** (65 total minus 46 deleted). Verify by set difference against the directory listing, not
by arithmetic — an earlier hand count was wrong because `claude-code` had been omitted from every group,
and summing group sizes could never have caught that. Only the complement covers the whole set.

Expected survivor set:
`capture-learnings code-review common debugging docker-stack docs-seeker docx github-ecosystem pdf
pptx problem-solving python-deprecation-fixer python-project-skel repomix rust-openapi
rust-security-audit synthesize-memories xlsx youtube-transcript`

If the count or the names differ, stop and reconcile before committing.

- [ ] **Step 6: Confirm nothing load-bearing broke**

Start a fresh session in any directory and confirm it launches without skill-resolution errors, and that
`capture-learnings` still resolves.

- [ ] **Step 7: Commit and push**

```bash
cd "G:/Users/Nando Ferreira/Documents/dotfiles"
git commit -m "chore: prune 46 unused skills from user corpus"
git push
```

Recovery if a deletion proves wrong: `git checkout HEAD~1 -- ai/skills/<name>`.

---

### Task 1: Create the personal setup repo

**Files:**
- Create: `claude-setup/.claude-plugin/marketplace.json`
- Create: `claude-setup/README.md`
- Move: design spec + this plan from scratchpad into `claude-setup/docs/`

**Interfaces:**
- Produces: marketplace name `progdroid` and plugin name `personal`, referenced by every later task as `personal@progdroid`.

**Location decided 2026-07-24:** `G:/polyDev/claude-setup`. The earlier `~/code/claude-setup` was
invented and wrong — no repos live under the home directory on this machine. Repos sit on `G:\` by
domain (`rustDev`, `pythonDev`, `flutterDev`, …); `polyDev` is the existing catch-all for projects that
are not single-language, which this is (markdown + JSON + bash).

**Visibility decided:** private, with a verification fallback to public if a private marketplace turns
out not to resolve in cloud sessions.

- [ ] **Step 1: Create the repo locally**

```bash
mkdir -p G:/polyDev/claude-setup/{.claude-plugin,docs,snippets} \
         G:/polyDev/claude-setup/personal/{.claude-plugin,skills,agents,commands}
cd G:/polyDev/claude-setup && git init -b main
```

**Deviation from the original step, applied deliberately:** the minimal `personal/.claude-plugin/plugin.json`
is created here rather than in Task 3. `marketplace.json` points at `./personal` from the first commit, so
pushing a marketplace whose only plugin does not exist would make Task 2's verification fail for an
unrelated reason. The repo is now valid at every commit.

- [ ] **Step 2: Write the marketplace manifest**

Schema verified against `~/.claude/plugins/marketplaces/obsidian-skills/.claude-plugin/marketplace.json`.
`name` and `source` are the only required plugin fields.

```json
{
  "name": "progdroid",
  "owner": {
    "name": "ProgDroid",
    "url": "https://github.com/ProgDroid"
  },
  "plugins": [
    {
      "name": "personal",
      "source": "./personal",
      "description": "Personal agents, commands, and cross-project working style",
      "version": "0.1.0"
    }
  ]
}
```

- [ ] **Step 3: Move the design docs out of scratchpad**

```bash
cp "$LOCALAPPDATA/Temp/claude/G--obsidianVaults-aegyptvault-notes"/*/scratchpad/2026-07-24-*.md G:/polyDev/claude-setup/docs/
```

- [ ] **Step 4: Verify the manifest parses**

Run: `py -c "import json;json.load(open('.claude-plugin/marketplace.json'));print('ok')"`
Expected: `ok`

- [ ] **Step 5: Push to GitHub**

```bash
gh repo create ProgDroid/claude-setup --private --source=. --remote=origin
git add -A && git commit -m "feat: personal Claude Code marketplace"
git push -u origin main
```

**Open question to resolve during this task:** whether a **private** marketplace repo resolves inside a cloud session. Cloud sessions authenticate GitHub through a proxy, so it likely works, but this is unverified. If it fails, either make the repo public (it contains no secrets by constraint) or fall back to committing the corpus per-repo. **Verify this before building on it in Task 3.**

---

### Task 2: Portable project settings snippet

This is the highest-value, lowest-effort task and it is independently useful — it makes cloud sessions work with superpowers even if every later task is abandoned.

**Files:**
- Create: `claude-setup/snippets/project-settings.json`
- Modify: one target project's `.claude/settings.json`

**Interfaces:**
- Consumes: nothing (all marketplaces below are already public and already in use).
- Produces: a block copied verbatim into each repo's `.claude/settings.json`.

- [ ] **Step 1: Write the snippet**

Values taken verbatim from the working `~/.claude/settings.json`. Third-party plugins currently vendored under
`my-plugins` are re-pointed at their upstream GitHub repos, since directory sources cannot resolve in a cloud VM.

```json
{
  "extraKnownMarketplaces": {
    "superpowers-dev": { "source": { "source": "github", "repo": "obra/superpowers" } },
    "obsidian-skills":  { "source": { "source": "github", "repo": "kepano/obsidian-skills" } },
    "progdroid":        { "source": { "source": "github", "repo": "ProgDroid/claude-setup" } }
  },
  "enabledPlugins": {
    "superpowers@superpowers-dev": true,
    "frontend-design@claude-plugins-official": true,
    "code-simplifier@claude-plugins-official": true,
    "commit-commands@claude-plugins-official": true,
    "claude-md-management@claude-plugins-official": true,
    "skill-creator@claude-plugins-official": true,
    "security-guidance@claude-plugins-official": true,
    "context7@claude-plugins-official": true,
    "personal@progdroid": true
  }
}
```

**Note on context7.** It is currently `false` in `~/.claude/settings.json`, because the working
context7 is a *separate* user-scope MCP registration in `~/.claude.json` (an HTTP server at
`https://mcp.context7.com/mcp`). User-scope MCP servers do not reach cloud sessions, so the plugin
form is the one that must be enabled here. Enable it in user settings too, so local and cloud use
the same mechanism rather than two.

**Do not commit the context7 API key.** The current MCP registration carries `ctx7sk-…` in a header.
If the plugin needs a key, it goes in the cloud environment's variables — which are visible to anyone
who can edit that environment — never in the marketplace repo. Context7 also works keyless at lower
rate limits; try that first.

Deliberately excluded, with reasons — do not add these back without cause:
- `qmd@qmd`, `obsidian@obsidian-skills` — vault-only; the qmd binary and index do not exist in a cloud VM
- `starship-claude@starship-claude` — statusline, meaningless in a cloud session
- `*-lsp@claude-plugins-official` — add per-repo only where that language is actually used
- `playwright`, `semgrep` — heavy installs; add per-repo where needed

- [ ] **Step 2: Apply it to one real target repo**

Pick a GitHub-hosted code project (not the vault). Merge the block into its `.claude/settings.json`, preserving existing keys. Commit and push — cloud sessions read the pushed repo, not your working tree.

- [ ] **Step 3: Verify in an actual cloud session**

```bash
claude --cloud "Run /help and list which skills and plugins are loaded. Do not change any files."
```

Expected: superpowers skills (`brainstorming`, `writing-plans`, …) appear. If they do not, the marketplace declaration is wrong — fix before proceeding.

- [ ] **Step 4: Commit**

```bash
git add snippets/project-settings.json && git commit -m "feat: portable project settings snippet for cloud sessions"
```

---

### Task 3: Package the personal corpus as a plugin

**Files:**
- Create: `claude-setup/personal/.claude-plugin/plugin.json`
- Create: `claude-setup/personal/agents/{job-extractor,vue-i18n-auditor}.md`
- Create: `claude-setup/personal/commands/{cr,cr-fx,deep-research,explore}.md`, `commands/git/`
- Create: `claude-setup/personal/skills/working-style/SKILL.md`

**Interfaces:**
- Consumes: `personal@progdroid` from Task 1.
- Produces: agents and commands available in any repo that enables the plugin.

- [ ] **Step 1: Write the plugin manifest**

```json
{
  "name": "personal",
  "description": "Personal agents, commands, and cross-project working style",
  "version": "0.1.0",
  "author": { "name": "ProgDroid" }
}
```

- [ ] **Step 2: Copy the authored corpus**

```bash
cd G:/polyDev/claude-setup/personal
mkdir -p agents commands skills
cp "$HOME/.claude/agents/job-extractor.md" "$HOME/.claude/agents/vue-i18n-auditor.md" agents/
cp "$HOME/.claude/commands/"{cr,cr-fx,deep-research,explore}.md commands/
cp -r "$HOME/.claude/commands/git" commands/
```

- [ ] **Step 3: Author the working-style skill**

This is the piece that carries cross-project memory into cloud sessions. Source material: the `user`-type
memories in `~/.claude/projects/*/memory/` that describe *how the user works* rather than project facts —
learning style, preference for rigour in trade-offs, build style, prune-and-offload tendency.

Write `personal/skills/working-style/SKILL.md` with frontmatter:

```markdown
---
name: working-style
description: Use when starting work on a new or unfamiliar project for this user - establishes how they prefer to work, decide, and receive proposals
---

# Working style

[One section per durable preference, each stating the preference and why it matters.
Draw from the user-type memories; exclude anything project-specific or purely private.]
```

- [ ] **Step 4: Verify the plugin loads locally before trusting it remotely**

```bash
claude plugin marketplace add G:/polyDev/claude-setup
claude plugin install personal@progdroid
```
Expected: `/cr` and the `job-extractor` agent resolve in a fresh local session.

- [ ] **Step 5: Commit and push**

```bash
git add -A && git commit -m "feat: personal plugin with agents, commands, and working-style skill"
git push
```

- [ ] **Step 6: Re-verify in a cloud session**

```bash
claude --cloud "List available agents and slash commands. Do not change any files."
```
Expected: `job-extractor` and `/cr` present.

**Explicitly out of scope:** the ~65 directories in `~/.claude/skills/`. Nearly all are vendored third-party
collections (`docx`, `pdf`, `pptx`, `xlsx`, `shopify`, `aesthetic`, …) that duplicate marketplace plugins.
Triaging and mostly deleting them is worthwhile but is its own task — see Follow-ups.

---

### Task 4: Auto-commit Stop hook

Purpose: allowance exhaustion mid-session must not strand work on the VM, since retrieving it requires a
model turn you will not have. Also the handoff mechanism for a second agent — the branch lands on GitHub.

**Files:**
- Create: `claude-setup/snippets/auto-commit-stop-hook.sh`
- Modify: target repo `.claude/settings.json`

**Interfaces:**
- Consumes: nothing.
- Produces: a hook script path referenced from a repo's `.claude/settings.json` `hooks.Stop` block.

- [ ] **Step 1: Write the failing test**

```bash
# snippets/test-auto-commit.sh
set -euo pipefail
tmp=$(mktemp -d); cd "$tmp"
git init -q -b main && git config user.email t@t && git config user.name t
echo one > a.txt && git add -A && git commit -qm init
git checkout -qb feature/x && echo two > a.txt   # dirty, on a non-default branch

CLAUDE_CLOUD_SESSION=1 bash "$SCRIPT" || true
test -z "$(git status --porcelain)" || { echo "FAIL: changes not committed"; exit 1; }

echo three > a.txt                                # dirty, but gate off
bash "$SCRIPT" || true
test -n "$(git status --porcelain)" || { echo "FAIL: committed without gate"; exit 1; }

git checkout -q main && echo four > a.txt         # dirty on default branch
CLAUDE_CLOUD_SESSION=1 bash "$SCRIPT" || true
test -n "$(git status --porcelain)" || { echo "FAIL: committed on main"; exit 1; }
echo PASS
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `SCRIPT=snippets/auto-commit-stop-hook.sh bash snippets/test-auto-commit.sh`
Expected: FAIL — script does not exist yet.

- [ ] **Step 3: Write the hook**

Gated on an explicit env var rather than sniffing for a cloud session, so behaviour is under your control
and it never surprises you locally. Set `CLAUDE_CLOUD_SESSION=1` in the cloud environment's variables.

```bash
#!/usr/bin/env bash
# Stop hook: commit and push WIP so an exhausted session never strands work.
set -uo pipefail

[ "${CLAUDE_CLOUD_SESSION:-}" = "1" ] || exit 0          # cloud sessions only
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

branch=$(git rev-parse --abbrev-ref HEAD)
case "$branch" in main|master|HEAD) exit 0 ;; esac       # never auto-commit the default branch
[ -n "$(git status --porcelain)" ] || exit 0             # nothing to do

git add -A
git commit -q -F - <<'EOF'
chore: auto-commit work in progress

Committed by the Stop hook so the session's work is recoverable
without another model turn.
EOF
git push -q -u origin "$branch" 2>/dev/null || true      # never fail the session on push
exit 0
```

- [ ] **Step 4: Run the test to confirm it passes**

Run: `SCRIPT=snippets/auto-commit-stop-hook.sh bash snippets/test-auto-commit.sh`
Expected: `PASS`

- [ ] **Step 5: Wire it into a target repo**

```json
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "bash .claude/hooks/auto-commit.sh" } ] }
    ]
  }
}
```

Copy the script to that repo's `.claude/hooks/auto-commit.sh`, `chmod +x`, commit, push.

- [ ] **Step 6: Verify end to end in a cloud session**

```bash
claude --cloud "Create a file SCRATCH.md containing the word hello, then stop."
```
Expected: the session branch on GitHub contains `SCRATCH.md` and an auto-commit, without you asking for a commit.

- [ ] **Step 7: Commit**

```bash
git add snippets/ && git commit -m "feat: auto-commit Stop hook with tests"
```

---

### Task 5: Populate the local deny list

For vault and homelab work, which can never be sandboxed on this hardware. Deny rules are honoured in every
permission mode, including `--dangerously-skip-permissions`.

**Files:**
- Modify: `~/.claude/settings.json` (`permissions.deny`, currently `[]`)

- [ ] **Step 1: Back up current settings**

```bash
cp "$HOME/.claude/settings.json" "$HOME/.claude/settings.json.bak-$(git log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || echo manual)"
```

- [ ] **Step 2: Replace the empty deny array**

```json
{
  "permissions": {
    "deny": [
      "Read(~/.ssh/**)",
      "Read(~/.aws/**)",
      "Read(~/.gnupg/**)",
      "Read(./.env)",
      "Read(./.env.*)",
      "Read(**/credentials.json)",
      "Read(**/*.pem)",
      "Read(**/*.key)",
      "Edit(~/.ssh/**)",
      "Edit(~/.claude/settings.json)",
      "Bash(curl * | sh)",
      "Bash(curl * | bash)",
      "Bash(wget * | sh)",
      "Bash(git push --force *)",
      "Bash(git push -f *)"
    ]
  }
}
```

Rationale per group: credential reads are the injection payoff; `Edit(~/.claude/settings.json)` stops an
agent widening its own policy; pipe-to-shell is the standard remote-code-execution path; force-push is the
one git operation that destroys history irrecoverably.

- [ ] **Step 3: Verify the file still parses**

Run: `py -c "import json;d=json.load(open(r'$HOME/.claude/settings.json'));print(len(d['permissions']['deny']),'deny rules')"`
Expected: `15 deny rules`

- [ ] **Step 4: Verify a rule actually bites**

In a fresh session, ask Claude to read `~/.ssh/config`.
Expected: refused by permission rule, not a prompt.

---

### Task 6: Reroute capture-learnings to the plugin

Without this, Task 3's `working-style` skill is a one-time snapshot that starts decaying immediately —
every future cross-project learning would still land in `~/.claude/skills/`, which cloud sessions cannot see.

**Files:**
- Modify: `~/.claude/skills/capture-learnings/SKILL.md:32` and the memory-routing section (~line 51)

**Interfaces:**
- Consumes: the `personal@progdroid` plugin and its local clone at `G:/polyDev/claude-setup` from Tasks 1–3.

- [ ] **Step 1: Read the current routing rules**

Run: `sed -n '25,55p' "$HOME/.claude/skills/capture-learnings/SKILL.md"`
The skill already routes across four surfaces (memory / CLAUDE.md / skill / hook) and already distinguishes
project-specific from cross-project. Only the cross-project *destination* is stale.

- [ ] **Step 2: Change the cross-project skill destination**

Replace, at line 32:

> `Project-specific → project-local skill; cross-project → global skill (~/.claude/skills/).`

with:

> `Project-specific → project-local skill (the repo's .claude/skills/). Cross-project → the personal plugin at G:/polyDev/claude-setup/personal/skills/, then commit and push — ~/.claude/skills/ is NOT visible to cloud sessions and is no longer a valid destination for anything you want available remotely.`

- [ ] **Step 3: Add the three-way memory audience split**

Append to the memory-routing section:

```markdown
**Route memories by audience, not just by type:**

| Content | Destination | Why |
|---|---|---|
| How the user works — decision style, preferences, what they want defended | `G:/polyDev/claude-setup/personal/skills/working-style/` | Needed on brand-new projects and inside cloud sessions |
| Facts about this specific project | the repo's `CLAUDE.md` or `.claude/` | Travels with the repo, reaches cloud sessions |
| Private observations, or anything you would not want a collaborator reading | `~/.claude/projects/<slug>/memory/` | Stays local by design; correctly does not travel |

When a memory would go to the plugin, say so explicitly and commit+push it — an uncommitted
working-style change is invisible to every cloud session until pushed.
```

- [ ] **Step 4: Verify the skill still parses and triggers**

Run: `head -5 "$HOME/.claude/skills/capture-learnings/SKILL.md"`
Expected: frontmatter intact with `name:` and `description:` unchanged.
Then invoke `capture-learnings` in a throwaway session and confirm it names the new destinations.

- [ ] **Step 5: Commit**

capture-learnings itself is cross-project and personal, so by its own new rule it belongs in the plugin.
**Move** it — do not copy. Two copies of the same skill in `~/.claude/skills/` and in the plugin will
drift, and the one you edit will not reliably be the one that loads.

```bash
cd G:/polyDev/claude-setup
mv "$HOME/.claude/skills/capture-learnings" personal/skills/
git add -A && git commit -m "feat: reroute capture-learnings to the plugin; add audience-based memory split"
git push
```

Removing the user-scope copy means the skill is only available where the plugin is enabled. To keep it
available in every local session as well as in cloud sessions, enable the plugin in **user** settings too —
`enabledPlugins` in the project snippet covers cloud, this covers local ubiquity:

```bash
# add to ~/.claude/settings.json:
#   "extraKnownMarketplaces": { "progdroid": { "source": { "source": "github", "repo": "ProgDroid/claude-setup" } } }
#   "enabledPlugins": { "personal@progdroid": true }
```

Verify before moving on: open a fresh session in an unrelated directory and confirm `capture-learnings`
still resolves. If it does not, restore from git and fix the plugin declaration before continuing.

---

### Task 7: Add the plugin as a synthesize-memories destination

Makes migration of the existing ~80-memory corpus an ongoing curation activity rather than a separate
big-bang project. The memory index is already over threshold (81 lines vs 60) and SessionStart is nudging
for a run, so this work is already owed.

**Files:**
- Modify: `~/.claude/skills/synthesize-memories/SKILL.md`

- [ ] **Step 1: Locate the existing promotion section**

Run: `grep -n "CLAUDE.md\|promot" "$HOME/.claude/skills/synthesize-memories/SKILL.md" | head -20`
The skill already proposes promoting universally-true user facts to global `CLAUDE.md`. Add a second target.

- [ ] **Step 2: Add the plugin promotion target**

```markdown
**Promotion targets — pick by where the fact needs to be readable:**

- **Global `CLAUDE.md`** — universally-true and short enough to load every turn
- **`G:/polyDev/claude-setup/personal/skills/working-style/`** — cross-project working style that should
  also reach cloud sessions, where user-scope config does not exist. Prefer this over global CLAUDE.md
  for anything longer than a line or two: skills load on relevance, CLAUDE.md loads always.
- **The project's own repo** — facts only true of one codebase

Promoting to the plugin requires a commit and push in that repo; report it as an explicit action rather
than assuming it landed.
```

- [ ] **Step 3: Run one real synthesis pass**

Invoke `synthesize-memories`. Expected: it proposes tiering shipped milestones into the cold index AND
identifies working-style memories as plugin promotion candidates. Approve a small first batch only —
this is the migration, done incrementally.

- [ ] **Step 4: Commit**

Move, not copy — same reasoning as Task 6 Step 5. The plugin must be enabled in user settings (done in
Task 6) for this to remain available locally.

```bash
cd G:/polyDev/claude-setup
mv "$HOME/.claude/skills/synthesize-memories" personal/skills/
git add -A && git commit -m "feat: add personal plugin as a synthesize-memories promotion target"
git push
```

---

## Self-Review

**Spec coverage.** Design item 1 (personal plugin) → Tasks 1–3. Item 2 (auto-commit Stop hook) → Task 4.
Item 3 (deny list) → Task 5. The design's memory-split subsection made three claims; Task 3 implemented
only the first (extract working style), so Tasks 6–7 were added to cover routing of future learnings and
migration of the existing corpus. Item 4 (OpenCode second tier) → **not covered here, deliberately** —
separate plan, see Follow-ups. BSOD side quest → **not covered here** — it is a diagnostic procedure, not
a software plan, and forcing it into TDD steps would be dishonest.

**Known ongoing cost, accepted knowingly.** Routing cross-project learnings to the plugin means a second
repo to keep committed and pushed. A forgotten push silently yields stale working style in cloud sessions,
with no error. Mitigation if this proves annoying in practice: apply the Task 4 auto-commit hook to
`claude-setup` itself.

**Placeholder scan.** One intentional gap: Task 3 Step 3's `SKILL.md` body is described rather than written,
because its content must be drawn from reading the actual memory files. Every other step carries literal content.

**Type consistency.** Marketplace name `progdroid` and plugin name `personal` are used identically in Tasks
1, 2, and 3. The env gate `CLAUDE_CLOUD_SESSION` is spelled the same in the hook, the test, and Step 5.

---

## Follow-ups (separate plans, not in scope here)

1. **OpenCode second tier.** Independent: different tool, different provider account, no shared code.
   Justified by the recurring Max allowance ceiling, not by an always-on requirement.
2. **BSOD diagnosis runbook.** Not a TDD plan. Sequence: confirm Windows dump collection is configured →
   re-enable virtualisation in BIOS → reproduce → read the dump for the offending driver. Must be done in
   that order; there is no existing dump to read because virtualisation has been off for a long time.
3. **`~/.claude/skills/` triage.** ~65 directories, nearly all vendored third-party collections duplicating
   marketplace plugins. Mostly a deletion exercise.
4. **Vault guard portability.** Four of the vault's five hooks are PowerShell and cannot run in a cloud VM,
   including `log-order-check.ps1`, which exists because LOG.md ordering was violated three times. Port or
   knowingly accept the loss before running vault work in the cloud.
