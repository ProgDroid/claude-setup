---
name: code-review-standards
description: Use when reviewing code or fixing review findings - what to flag across security, performance, architecture, quality, tests and docs, how to report it, and how to remediate.
---

# Code Review Standards

What to flag when reviewing code, how to report it, and how to remediate it.

## Review dimensions

Cover each dimension, in parallel where sub-reviewers are available:

| Dimension | Focus |
|-----------|-------|
| Security | OWASP Top 10, dependency CVEs, secrets, auth |
| Performance | N+1 queries, caching, algorithmic complexity |
| Architecture | SOLID, design patterns, coupling |
| Code Quality | Naming, DRY, dead code, complexity |
| Test Coverage | Coverage gaps, edge cases, fixtures |
| Documentation | Docstrings, README, CHANGELOG |

For a narrower review, weight one dimension: security (OWASP Top 10, CVE scan, secrets),
performance (benchmarking suggestions, DB query analysis, caching strategy) or maintainability
(refactoring opportunities, technical debt, complexity).

**Process:** map the codebase (entry points, configuration, tests); review each dimension
thoroughly; deduplicate and cross-reference; prioritise by severity (Critical / High / Medium / Low).

**No speculation:** read every file you comment on. No guessing about unread code. Every finding
includes `file:line`, the impact, and remediation code.

**Report shape:** a full findings report with a health score per dimension (X/10), a short
executive summary, and an actionable checklist ordered by priority.

## Remediating findings

Decide, before changing code:
1. **Severity filter**: Critical / High / Medium / Low
2. **Category**: Security / Performance / Architecture / Quality
3. **Conflicts**: when fixes target the same files, apply sequentially, combine, or hand to the user
4. **Verification depth**: full review of the fixes, tests and linters, tests only, or none
5. **Commit strategy**: review first, a single commit, or one commit per category

Quick default: Critical and High severity, all categories, verified by tests and linters.
Verify the fixes for swallowed errors and inadequate exception handling, over-engineered fixes, and
test coverage and quality. Finish with a remediation report: fixes made, what was verified, and
what was left.

---

## Supplemental Checklists

### Performance — Caching Correctness

When reviewing caching code, verify these patterns in addition to the standard performance pass:

**Key namespacing — different types, different keys**
Check that no two endpoints share a cache key for different serialised types. A JSON struct and a rendered string (ICS, HTML, CSV) stored under the same key collide silently: `serde_json` deserialization failures return `Ok(None)`, so the cache appears functional but is permanently defeated (cache miss on every request, no error logged).
- Flag: two `cached_response` / `cache.get` calls with the same key generator but different generic `T`
- Fix: prefix by what is stored — `calendar:{id}` for JSON, `export:{id}` for ICS rendering

**Mutation completeness — all derived keys invalidated**
On every mutating endpoint (PUT, POST, PATCH, DELETE), check that ALL cache keys derived from the affected resource are invalidated:
- Primary lookup key
- Paginated list / index keys
- Derived rendering keys (export, feed, thumbnail)
- Subscription / webhook feed keys (served to external clients who may cache for hours themselves)

Look for a single invalidation helper that clears all of them. If mutation code calls invalidation inline, check whether any key type is missing.

**Delete + RETURNING — avoid pre-fetch for post-deletion cleanup**
If a DELETE needs a stored value (token, slug, email) to invalidate a secondary cache key, verify the code uses `RETURNING <col>` in the SQL DELETE rather than a separate `SELECT` before the delete. The pre-fetch pattern introduces a race window and an extra round-trip.
