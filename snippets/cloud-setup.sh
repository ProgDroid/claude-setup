#!/bin/bash
# Cloud session setup script.
#
# WHERE THIS GOES: paste into the Setup script field of a Claude Code cloud
# environment (open the environment selector, hover an environment, click the
# settings icon). It is NOT read from the repo — this copy exists for version
# control and review.
#
# WHY IT EXISTS: declaring plugins in a repo's .claude/settings.json does not
# install them. Verified 2026-07-24 against a live session: a repo declaring
# two marketplaces and nine plugins produced "No plugins installed" and only
# the built-in marketplace registered. enabledPlugins is a declaration of
# intent; something has to act on it, and an unattended session has nobody to
# accept the install prompt.
#
# CONTRACT (per Anthropic docs):
#   - runs as root on Ubuntu 24.04, BEFORE Claude Code launches
#   - a non-zero exit makes the session fail to start, hence `|| true` throughout
#   - filesystem output is snapshotted and reused, so this cost is per
#     environment, not per session
#   - re-runs when this script changes, when allowed network hosts change, or
#     after roughly seven days
#   - keep total runtime under ~5 minutes
#
# NETWORK: needs to reach github.com. The default "Trusted" access level
# covers it. Under "None" this script cannot work at all.

set -u   # deliberately NOT -e: a failed install must not kill the session

log() { echo "[setup] $*"; }

if ! command -v claude >/dev/null 2>&1; then
  log "FATAL-ish: 'claude' not on PATH; cannot install plugins. Continuing so the session still starts."
  exit 0
fi

log "claude version: $(claude --version 2>&1 | head -1)"
log "HOME=$HOME"

# ---------------------------------------------------------------------------
# 1. Register marketplaces. Must precede installs.
#    Both are public: a cloud session's GitHub proxy is scoped to the session's
#    own repo, so a private marketplace here would likely fail to clone.
# ---------------------------------------------------------------------------
for m in "obra/superpowers" "ProgDroid/claude-setup"; do
  if claude plugin marketplace add "$m" >/tmp/mp.log 2>&1; then
    log "marketplace OK: $m"
  else
    log "marketplace FAILED: $m -- $(tail -2 /tmp/mp.log | tr '\n' ' ')"
  fi
done

log "registered marketplaces:"
claude plugin marketplace list 2>&1 | sed 's/^/[setup]   /' || true

# ---------------------------------------------------------------------------
# 2. Install plugins. Each is a git clone; keep the list tight.
#    Names must match the marketplace entry's `name`, not plugin.json's.
# ---------------------------------------------------------------------------
PLUGINS="
superpowers@superpowers-dev
personal@progdroid
context7@claude-plugins-official
serena@claude-plugins-official
commit-commands@claude-plugins-official
claude-md-management@claude-plugins-official
skill-creator@claude-plugins-official
security-guidance@claude-plugins-official
code-simplifier@claude-plugins-official
frontend-design@claude-plugins-official
"

fail=0
for p in $PLUGINS; do
  if claude plugin install "$p" >/tmp/pi.log 2>&1; then
    log "installed: $p"
  else
    fail=$((fail + 1))
    log "INSTALL FAILED: $p -- $(tail -2 /tmp/pi.log | tr '\n' ' ')"
  fi
done

# ---------------------------------------------------------------------------
# 3. Report. This is the whole point on first run: the build log is the only
#    place the outcome is visible without spending another session to ask.
# ---------------------------------------------------------------------------
log "install failures: $fail"
log "final plugin list:"
claude plugin list 2>&1 | sed 's/^/[setup]   /' || true

exit 0
