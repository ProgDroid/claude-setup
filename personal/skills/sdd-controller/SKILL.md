---
name: sdd-controller
description: Use when acting as the CONTROLLER in subagent-driven development - writing implementer or reviewer dispatches, judging a subagent's report, deciding whether a task or branch is done, or checking whether a stalled-looking subagent is working. Complements superpowers:subagent-driven-development with the controller discipline this user's projects learned the hard way.
---

# SDD controller discipline

`superpowers:subagent-driven-development` says how to run the loop. This says how to avoid the
failures that kept recurring *in the controller's seat*, measured across cotrip, news-brief,
constellation, swarm-music and ds-job-analysis between 2026-06 and 2026-10.

The organising fact: **the subagents mostly do exactly what they are told, and their reports are
claims, not evidence.** So the two places defects survive are the controller's own text and the
controller's acceptance of a report.

## 1. Your plan is the likeliest defect

Across ten cotrip slices, the review layer's best catches were errors in the controller's plan,
spec or dispatch, not in implementer code. A brief is the implementer's entire world; it cannot
detect that its own premise is false.

- **Verify every premise before writing it as an instruction.** "Never background cargo" rested on
  an unchecked memory and stalled three agents. A dispatch saying "passing `:token` is harmless" was
  false (Vue writes fallthrough attrs to the DOM) and steered an implementer into a token leak.
  **A "this is safe" in a dispatch is an unverified claim until checked.**
- **When a reviewer flags something the plan mandated, the PLAN is the defect.** Fix the plan, then
  the code, then say so in the commit. Never let an implementer comply its way into a bug.
- **Check each brief against the code before dispatching it.** Reading load-bearing assumptions
  (column names, fixture names, prices, whether a guard has a test) found 6 plan defects in one
  news-brief run before any implementer saw them. Settle documentation questions in the controller.
- **An extracted brief is a FROZEN COPY.** After any upstream correction, re-extract every brief
  already written.
- **Re-read the spec end-to-end after a mid-flight design change**, and sync it to what shipped
  before the final review. Reviewers treat the spec as authoritative.
- **Expect the dominant defect class to be tests that pass but cannot fail.** Running code, a
  mutation or a probe found them; reading never did.

## 2. What goes in every dispatch

Put the standing items in the shared context file **before the first dispatch**. A rule that was
already written down still caused a park when it lived in a memory instead of the brief.

- **Absolute test counts, never deltas.** "The suite is at 1246 and must be 1251", not "baseline +
  5" — a fresh agent reads "baseline" as its own starting count.
- **A test for EVERY public method and state transition the task adds**, not just the brief's
  examples. Plans write illustrative tests; reviewers then flag the gap and cost a fix round.
- **"Would this test pass against a broken implementation?"** — verbatim, in implementer AND
  reviewer dispatches.
- **Run long commands in the FOREGROUND, with a long timeout.** Implementers that background a
  gate and wait on a Monitor never wake.
- **Commit from Bash with `git commit -F <file>`** (PowerShell prepends a BOM; `$(...)` in `-m` is
  denied by the guard).
- **Report rather than resolve** wherever the controller made a non-obvious call, and report any
  disagreement with a pre-registered number rather than reconciling it.
- **Write the full report to a file and return verdict + path.** Long returns truncate. For long
  reviews, require appending each result to the file before starting the next.
- **List every claim you did NOT execute**, then route those to a reviewer told to RUN them.
- **Grep the staged diff for mutation markers** (`and False`, `if False`, `if True`) before every
  commit. A deliberate mutation once sat in the working tree of a security guard.
- **Keep the tracking-issue close out of the implementer's scope.** It belongs after the final
  review.

## 3. Mutation evidence: demand a count, pre-registered

Asking "did it fail?" invites a yes. Asking **"how many failed, and which?"** audits the tests, and
repeatedly audited the controller too.

- **Name the mutation exactly** (line, from, to), state which test must fail, and write the expected
  count down first. Let implementers pre-register their own; theirs beat the plan's predictions.
- **Count the list, never derive it.** Three predictions in one session lost to mental arithmetic.
- **Assert the mutation anchor matches EXACTLY once**, CRLF included. Otherwise it widens silently
  (one `sed` hit three functions) or never applies (a zero that is really `BROKEN MUTANT`).
- **A mutation must leave the code runnable and must change behaviour.** Breaking a SQL placeholder
  "failed" 22 tests and tested nothing. Rewording a log message tests your phrasing.
- **Read disagreements by direction:**
  - **Overshoot** → suspect the mutant first (crash, wider match), then the test's name.
  - **Undershoot** → suspect the tests; a survivor is often the headline assertion.
  - **Zero** → before calling the test weak, check for a duplicated guard, a lower layer (DB, type
    system) enforcing the same rule, a boundary literal the code has since moved, or inputs on
    which the two constants agree.
- **Run mutations against whole modules.** A `-k` filtered zero is UNKNOWN.
- **When a fix adds a test, recount every pre-registered mutation on the lines it touches.**
- Fail-first where possible: against the broken code before the fix lands.

## 4. Verify reports, including the reviewers'

- **Run the suite yourself once, at the end.** Reviewers are told not to re-run it, so every number
  in the chain comes from the implementer it measures. One controller gate closes the chain.
- **A count moving the wrong way is the tell** — "40 tests" right after adding two, when the true
  number was 60.
- **Before a number scores a fix, name the layer the fix lives in** — prompt, parser, merge,
  render — and confirm the probe actually executes that layer. A well-formed, correctly computed
  number can answer an adjacent question: a scorer that read the model's raw reply could not see
  enforcement inside `merge_ledger`. **Verification done inside subagents is invisible from the
  controller's transcript**, so anything that reads only that transcript measures the controller,
  not the work — the 2026-10-05 Tier 2 read found 0 genuine unverified claims in 50 once this was
  accounted for. Tell: a second signal from the same run that the headline cannot explain.
- **A reviewer's suggested fix is a hypothesis.** Twice, applying one verbatim would have introduced
  a bug. The problem is the finding; the cure is a suggestion. A claim about framework behaviour
  needs the framework's source opened.

## 5. Judge progress by artefacts, never liveness

Liveness and progress are independent in both directions: a live agent can have stopped, and a
finished run leaves no process.

- **Pick the artefact the current phase writes:** source and commits while editing, the build/test
  log's mtime while compiling, the report file when finishing. A frozen tree during a 16-minute
  compile is not a stall.
- **"Idle" is not "finished".** Check `git status` too — one agent finished everything except the
  commit, and judging by commits alone would have re-dispatched over a finished sweep.
- **Never run the toolchain while an implementer holds the worktree.** One build directory, one
  lock — a controller "quick check" is contention.
- **Default to dispatching.** True stalls are rare (24/24 and 15/15 completed in measured runs). If
  one hangs, review its diff inline from the base SHA you recorded before dispatch. A subagent that
  died mid-task left its edits in the tree: read the diff, run the gate, dispatch only the rest.

## 6. Shared state is not visible from the file list

- **Disjoint files is not independence.** news-brief's test DB drops the schema in every fixture; two
  concurrent runs produced 1 failed + 22 errors. Overlap implementers only with READ-ONLY reviewers
  told not to run the suite. If a collision happened, both results are UNKNOWN; re-run one at a time.
- **After any task touching global nav, routing or always-mounted UI, run the FULL suite.** A
  wizard's global guard regressed ~16 e2e specs that per-task runs could not see.

## 7. The final whole-branch review earns its cost

Per-task review structurally cannot see cross-task seams: a number produced in three tasks and read
by none; two independently written predicates that drifted; a value re-resolved across a function
six tasks edited. Dispatch the final review on the most capable model, point it at cross-task
coherence explicitly, and give every reviewer **named risks, each with one focused check** — nearly
every Important finding in one run came from a named risk.

## Provenance

Promoted 2026-10-05 from project memories (the detail and dated evidence stay there):
`polyDev-cotrip/controller-plan-errors-outnumber-implementer-errors`,
`polyDev-constellation/verify-subagent-reports`, `polyDev-constellation/sdd-mandate-full-test-coverage`,
`pythonDev-news-brief/mutation-diagnostic-demands-a-count`,
`pythonDev-news-brief/parallel-implementers-share-test-db`,
`pythonDev-news-brief/subagent-review-stalls`,
`rustDev-swarm-music/judge-subagent-progress-by-artefacts-not-liveness`,
`pythonDev-ds-job-analysis/feedback_verify_guards_by_deleting_them`.
