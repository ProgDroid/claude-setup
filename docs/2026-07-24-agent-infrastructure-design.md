# Always-Available Coding Agent — Design

**Date:** 2026-07-24
**Status:** design approved, pending spec review

## Problem

Running Claude Code locally on Windows with `--dangerously-skip-permissions`, because
enumerating a workable permission set across highly varied projects is impractical.
Secondary: multiple concurrent local sessions spin the desktop's fans, and the 3090 is
already thermally stressed. Tertiary: occasional desire to work while away from the desk.

A prior design proposed a Hetzner VPS plus Docker containment, Tailscale/ZeroTier ACLs,
Syncthing vault sync, an orchestrator (agentbox/amux), a fallback agent (OpenCode), a
fallback model provider (DeepInfra), LM Studio, OpenWebUI, and a Telegram wrapper.

## Constraints

These are hard and were discovered during design, not assumed:

1. **No virtualisation on the desktop.** Enabling it in BIOS causes BSODs. This means no
   WSL2, no Docker, no local VM, and therefore **no local Claude Code sandbox** — the
   built-in `/sandbox` requires bubblewrap on Linux/WSL2 and does not run on native Windows.
2. **The DIY server is critical infrastructure.** It runs Pi-hole; all household internet
   routes through it. If it breaks, internet is down until the router is reconfigured.
   ~3GB RAM free. Disqualified as an agent host on availability grounds, not capacity.
3. **Max plan allowance is a binding constraint.** The user hits the ceiling often enough
   that it limits how much they can work. Cloud sessions share the same rate limits, and
   parallel sessions consume proportionally more.
4. **Vault work is Windows-native.** `G:\` paths, PowerShell hooks, `qmd`, `obsidian-cli`.
   It cannot move to Linux without a rewrite.
5. **Homelab-touching work** (jobscraper, Readeck) requires LAN access, which no cloud
   sandbox can provide.

## Design

### Core decision

**GitHub-hosted code work moves to Claude Code cloud sessions, replacing local sessions
rather than supplementing them.**

Rationale: this is the only sandbox available given constraint 1. Each session runs in an
isolated Anthropic-managed VM (4 vCPU / 16GB / 30GB) with GitHub credentials held outside
the sandbox by a proxy, and per-environment network egress allowlists. It also removes the
build/test load from the desktop, addressing the thermal problem.

**Explicitly not adopted: parallel `--cloud` fan-out.** Given constraint 3, running several
cloud sessions concurrently accelerates allowance exhaustion. Cloud sessions are a
relocation of work, not an expansion of it.

### Supporting work

1. **Publish `~/.claude` as a personal plugin.**
   Cloud sessions clone the repo; user-scope `~/.claude/skills|agents|commands|CLAUDE.md`
   do not travel. Plugins declared in a repo's `.claude/settings.json` *are* installed at
   session start from their marketplace. Converting the cross-project corpus into a
   personal plugin on a GitHub marketplace repo gives version control, cross-machine sync,
   and cloud availability through one supported mechanism — replacing the current
   dotfiles-backup habit, which by construction cannot work remotely.

   Memory split by **audience**, not portability:
   - Working-style memories (useful on new projects) → the plugin
   - Project-specific facts → the project repo
   - Purely personal observations → stay in user scope, do not travel

   *Open question: whether a private marketplace repo resolves in cloud sessions. Needs
   verification before relying on it.*

2. **Auto-commit `Stop` hook per repo.**
   Repo `.claude/settings.json` hooks run in cloud sessions. A hook that commits and pushes
   WIP to the session branch makes allowance exhaustion harmless — otherwise, running out
   mid-session strands work on the VM, since retrieving it requires a model turn.
   Also the handoff mechanism for a second agent: the branch is on GitHub, so any agent can
   `git fetch` it and read `docs/superpowers/specs/*-plan.md`.

3. **Populate the empty `deny` list** in `~/.claude/settings.json` (currently `"deny": []`).
   For vault and homelab work, which can never be sandboxed on this hardware. Deny rules are
   honoured regardless of permission mode. Target: `~/.ssh/**`, `./.env*`, credential paths,
   `curl | sh` patterns.

4. **Second agent tier: OpenCode on a non-Anthropic provider.**
   Justified by constraint 3, not by the original "always-on" framing. Superpowers plans are
   committed markdown, so handoff needs no infrastructure — point OpenCode at the plan file
   and a phase number. Provider choice favours OpenRouter over DeepInfra: at low volume the
   markup is negligible and breadth serves both the fallback and the learning goal.

### Unchanged

Vault and homelab work stay local, on Windows, unsandboxed — as today. Not improved, but not
a regression. Mitigated only by item 3.

### Dropped from the prior design

Hetzner VPS · Docker containment · Tailscale/ZeroTier ACLs · Syncthing · agentbox as
orchestrator · Telegram wrapper · WSL2 migration · third box of any kind.

Rationale: each was either solved by cloud sessions at zero cost, blocked by a constraint,
or solving a problem a committed file already solves.

## Side quest: fix the virtualisation BSOD

Highest-leverage single item, tracked separately because it changes what the rest must cover.
Recovering virtualisation restores local `/sandbox`, Docker, and WSL2, which would close the
vault and homelab isolation gaps entirely.

Note: the issue is old and virtualisation has been disabled for a while, so **no current
crash dump exists**. Diagnosis will require re-enabling to reproduce, after confirming dump
collection is configured. Likely candidates are HVCI/Memory Integrity conflicts or a stale
anticheat/VPN filter driver, not failing hardware.

## Parking lot — separate discussions, explicitly not in scope

Motivated by wanting landscape knowledge for career reasons as well as utility. To be
researched properly rather than opined on:

- **agentbox**, **amux**, **Hermes** — no reliable knowledge held; require actual research
- **OpenWebUI** — mature self-hosted chat frontend, unrelated to the coding-agent problem
- **LM Studio vs Ollama** — choice barely matters for desktop interactive use; the real
  consideration is that local inference is the most GPU-intensive possible workload, in
  direct tension with the 3090's thermal problem
- **DeepInfra** — see item 4; wins on price at scale, which is not this situation

## Open items

- Verify private marketplace repos resolve in cloud sessions
- Confirm which of the current `~/.claude` corpus is genuinely cross-project vs. vestigial

### The vault in cloud sessions — partial, with a sharp edge

Verified 2026-07-24 against the repo rather than assumed:

**Would work.** The vault's `.claude/skills/` are committed, including `book-metadata`,
`game-metadata`, `manga-metadata` and `anime-metadata` with their Python scripts. Python is
pre-installed in cloud VMs. So the "ingest a book from holiday" case is genuinely viable,
given an environment that allows egress to `googleapis.com` / `openlibrary.org` and carries
`GOOGLE_BOOKS_API_KEY` as an environment variable.

**Would not work.** Four of the five committed hooks are PowerShell (`auto-log-daily.ps1`,
`block-state-files.ps1`, `log-order-check.ps1`, `session-context.ps1`) and cannot run on a
Linux VM. `qmd-reindex.sh` is bash but `qmd` is not installed there, so cross-link suggestion
during ingest is unavailable and the index goes stale.

**The sharp edge:** `log-order-check.ps1` exists because LOG.md ordering was violated three
times and prose guidance failed. Running vault sessions in an environment where that guard is
absent reintroduces exactly the failure it was written to stop. Before using cloud sessions on
the vault, either port the guards to a cross-platform form or accept the loss knowingly —
do not discover it after the fact.
