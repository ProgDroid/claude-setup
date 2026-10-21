---
name: git-standards
description: Use when committing, branching, rewriting history, writing commit messages or opening pull requests - version control conventions.
---

# Git & Version Control Standards

## Git Worktree Workflow (Preferred)

**IMPORTANT**: For any multi-branch work, feature development, or parallel task handling, use the `superpowers:using-git-worktrees` skill. It ensures an isolated workspace exists, through native tools or the plain `git worktree` fallback.

### When to Use a Worktree
- Working on a feature while needing to hotfix another branch
- Reviewing PRs while continuing development
- Running tests on one branch while coding on another
- Any scenario involving multiple branches
- Spinning up parallel Claude Code agents

## Conventional Commits

All commits MUST follow the [Conventional Commits](https://www.conventionalcommits.org/) specification.

### Format
```
<type>[optional scope]: <description>

[optional body]

[optional footer(s)]
```

### Types
| Type | Description |
|------|-------------|
| `feat` | New feature for the user |
| `fix` | Bug fix for the user |
| `docs` | Documentation only changes |
| `style` | Formatting, missing semicolons, etc. (no code change) |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `perf` | Performance improvement |
| `test` | Adding or correcting tests |
| `build` | Changes to build system or external dependencies |
| `ci` | Changes to CI configuration files and scripts |
| `chore` | Other changes that don't modify src or test files |
| `revert` | Reverts a previous commit |

### Scope
Optional, but recommended for larger projects:
```
feat(auth): add OAuth2 login support
fix(api): handle null response from external service
docs(readme): update installation instructions
```

### Breaking Changes
Indicate with `!` after type/scope or `BREAKING CHANGE:` in footer:
```
feat(api)!: change response format for user endpoint

BREAKING CHANGE: The user endpoint now returns an object instead of an array.
```

### Examples
```bash
# Feature
feat(users): add email verification flow

# Bug fix with issue reference
fix(cart): prevent negative quantities

Fixes #123

# Refactor with body
refactor(database): migrate from callbacks to async/await

Modernize database layer to use async/await pattern.
This improves readability and error handling.

# Breaking change
feat(api)!: rename endpoints to follow REST conventions

BREAKING CHANGE: All endpoints now use plural nouns.
- /user -> /users
- /product -> /products
```

## `Verified:` trailer — evidence for a claim, in the commit that makes it

When a change was verified by actually running something, record it as a trailer in the commit
body. One line per check: **the command, an arrow, and what it printed** — never "tests pass".

```
Verified: pytest -q -> 47 passed, 0 failed
Verified: git check-ignore build/cache -> non-empty (positive control)
Verified: cargo clippy --all-targets -- -D warnings -> clean
```

**Why the commit and not a doc or a tracker.** It is on a path already being walked, so it costs
nothing extra to write and cannot be forgotten separately from the change it describes. It is
immutable, it travels to cloud sessions in the clone, and `git log --grep='^Verified:'` retrieves
it. Anything requiring a *second, separate* write action to preserve evidence will not survive a
normal working day.

**Rules that make the trailer worth anything:**

- **Quote the OUTPUT, not the verdict.** "tests pass" is the claim; `47 passed, 0 failed` is the
  evidence. A trailer that restates the claim records nothing.
- **A zero needs a positive control, and the trailer must say so.** `grep -c X -> 0` is not
  evidence of absence; `grep -c X -> 0 (control: grep -c Y -> 12)` is.
- **Never write a trailer for a check you did not run.** A fabricated one is worse than none,
  because it stops the next session from re-checking.
- **Watch the wrapper trap** (core rules § Probe discipline, pipe-eats-the-exit-code): quote the
  `REAL_EXIT=` line from the log, never a piped status.

**What this deliberately does NOT do:** it cannot answer "what is currently unverified". That is
what an issue tracker is for (if the project uses one, e.g. Beads, `bd`) — an open issue *is* an unverified claim. The division of labour:
**open issues say what is not done; `Verified:` trailers say what was done and how it was proven;
a plan doc's `## Escalations & plan defects` says where a check ran and lied.** Do not build a
fourth slot; the gap that seems to need one is usually these three being conflated.

**On Windows (Git Bash):** commit through the **Bash** tool, not PowerShell (PS 5.1 prepends a UTF-8 BOM
to the subject). If the message contains backticks, `$`, or `!`, use `git commit -F -` with a
single-quoted heredoc — `-m "..."` runs command substitution and silently mangles it.

## Branch Naming

### Format
```
<type>/<ticket-id>-<short-description>
```

### Types
| Prefix | Purpose |
|--------|---------|
| `feature/` | New features |
| `fix/` | Bug fixes |
| `hotfix/` | Urgent production fixes |
| `refactor/` | Code refactoring |
| `docs/` | Documentation updates |
| `test/` | Test additions/updates |
| `chore/` | Maintenance tasks |

### Examples
```
feature/PROJ-123-user-authentication
fix/PROJ-456-cart-calculation-error
hotfix/PROJ-789-payment-gateway-timeout
refactor/PROJ-101-extract-validation-service
docs/PROJ-102-api-documentation
```

### Rules
- Use lowercase
- Use hyphens (not underscores)
- Keep descriptions short but meaningful
- Include ticket ID when available

## Linear History (Squash & Merge)

### Strategy
- **Default**: Squash merge for feature branches
- **Result**: One commit per feature/fix in main branch
- **Benefit**: Clean, readable history

### PR Merge Settings
```
[x] Allow squash merging
    Default commit message: Pull request title and description

[ ] Allow merge commits
[ ] Allow rebase merging
```

### Workflow
```bash
# Create feature branch (use superpowers:using-git-worktrees for parallel work)
git checkout -b feature/PROJ-123-new-feature

# Make commits (can be messy during development)
git commit -m "wip: initial implementation"
git commit -m "wip: add tests"
git commit -m "fix: address review feedback"

# Push and create PR
git push -u origin feature/PROJ-123-new-feature

# PR gets squash-merged with clean message:
# "feat(module): add new feature (#123)"
```

## Git Configuration Recommendations

```bash
# Rebase by default when pulling
git config --global pull.rebase true

# Auto-setup remote tracking
git config --global push.autoSetupRemote true

# Prune deleted remote branches
git config --global fetch.prune true

# Better diff algorithm
git config --global diff.algorithm histogram

# Sign commits (if using GPG)
git config --global commit.gpgsign true
```

## Pre-commit Hooks

### Setup with pre-commit
```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v6.0.0
    hooks:
      - id: trailing-whitespace
      - id: end-of-file-fixer
      - id: check-yaml
      - id: check-json
      - id: check-added-large-files
        args: ['--maxkb=1000']
      - id: check-merge-conflict
      - id: detect-private-key

  - repo: https://github.com/commitizen-tools/commitizen
    rev: v4.10.0
    hooks:
      - id: commitizen
        stages: [commit-msg]

  # Language-specific hooks added per project
```

### Installation
```bash
pip install pre-commit
pre-commit install
pre-commit install --hook-type commit-msg
```

## Protected Branch Rules

### Main/Master Branch
- Require pull request reviews (1+ approval)
- Require status checks to pass
- Require linear history
- Require signed commits (optional but recommended)
- Do not allow force pushes
- Do not allow deletions

### Release Branches
- Same as main, plus:
- Restrict who can push

## PR Guidelines

### Title
Follow Conventional Commits format:
```
feat(auth): implement SSO login
fix(api): handle rate limiting gracefully
```

### Description Template
```markdown
## Summary
Brief description of changes.

## Changes
- List of specific changes
- Another change

## Testing
- [ ] Unit tests added/updated
- [ ] Integration tests pass
- [ ] Manual testing completed

## Related Issues
Closes #123
```

### Review Checklist
- [ ] Code follows project style guidelines
- [ ] Tests cover new functionality
- [ ] Documentation updated if needed
- [ ] No sensitive data in commits
- [ ] Commit messages follow conventions

## Common Git Operations

### Sync with Main (Rebase)
```bash
git fetch origin
git rebase origin/main
# Resolve conflicts if any
git push --force-with-lease
```

### Interactive Rebase (Local Cleanup)
```bash
# Clean up last 3 commits before pushing
git rebase -i HEAD~3
```

### Undo Last Commit (Keep Changes)
```bash
git reset --soft HEAD~1
```

### Cherry-pick to Another Branch
```bash
git checkout target-branch
git cherry-pick <commit-hash>
```

### Find Commit That Introduced Bug
```bash
git bisect start
git bisect bad HEAD
git bisect good <known-good-commit>
# Test and mark each commit
git bisect good/bad
# When done
git bisect reset
```
