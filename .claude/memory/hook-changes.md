---
name: hook-changes
---
Any change under `personal/hooks/` runs the WHOLE suite before it is committed:
`for f in personal/hooks/test-*.sh; do bash "$f"; done` — not just the suite named
after the file changed. `lib-memory.sh` is sourced by three hooks, so a one-line
edit there moves auto-commit, sync-memory and hydrate-memory at once.

**Why:** these hooks are built to fail silently — `|| return 0`, `|| exit 0`,
`2>/dev/null` everywhere — so that a broken hook can never break a session. That
is the right trade, and it means the test suite is the ONLY signal that exists.
Nothing will ever tell you a hook stopped working. Every bug found in them so far
(wrong project key, one-way overwrite) was invisible in normal use and did damage
for days.

**How to apply:** run all the suites, and read a red case before believing it.
Two failure shapes have cost real time here, in opposite directions — a suite
inheriting `CLAUDE_CLOUD_SESSION=1` from a cloud environment fails against hooks
that are correct, and a fixture derived from the code under test passes against
hooks that are broken. Both are written up in the `personal:cloud-sessions` skill
and in the test files' own comments.

Bump `personal/.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`
in the same commit as any plugin change. The plugin cache is keyed by version, so
a fix shipped under an unchanged version never loads.
