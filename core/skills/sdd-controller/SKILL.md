---
name: sdd-controller
description: Use when acting as the CONTROLLER in subagent-driven development - writing implementer or reviewer dispatches, judging a subagent's report, deciding whether a task or branch is done, or checking whether a stalled-looking subagent is working. Complements superpowers:subagent-driven-development with the controller discipline this user's projects learned the hard way.
---

# SDD controller discipline

`superpowers:subagent-driven-development` says how to run the loop. This says how to avoid the
failures that kept recurring *in the controller's seat*, measured across several of this user's
projects between 2026-06 and 2026-10.

The organising fact: **the subagents mostly do exactly what they are told, and their reports are
claims, not evidence.** So the two places defects survive are the controller's own text and the
controller's acceptance of a report.

## 1. Your plan is the likeliest defect

Across ten slices of one project, the review layer's best catches were errors in the controller's plan,
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
  run before any implementer saw them. Settle documentation questions in the controller.
- **An extracted brief is a FROZEN COPY.** After any upstream correction, re-extract every brief
  already written.
- **Re-read the spec end-to-end after a mid-flight design change**, and sync it to what shipped
  before the final review. Reviewers treat the spec as authoritative.
- **Expect the dominant defect class to be tests that pass but cannot fail.** Running code, a
  mutation or a probe found them; reading never did.
- **Before trusting any RED, prove the runner fails on a test file that cannot load.** GUT 9.7.1
  logs a parse error, skips that file and still exits 0 with "All tests passed". So a RED that
  failed with "class not defined" was a silent skip, and so was a broken test file sitting in CI.
  Make a deliberately broken test file and confirm the suite fails. Add a guard that compares the
  number of scripts the runner ran with the number of test files on disk. (A Godot project,
  2026-10-06.)
- **When a task's output has an external oracle, run it on real data before you close the task.**
  Don't wait for the acceptance task. In one project (2026-10-14), the beads `ready` rule passed 9
  fixture tests and a clean review. Then a throwaway `examples/` binary on the real export gave 53,
  where `bd` itself had reported 49. The 4 extras shared one property, a blocked parent, so the
  PLAN's rule was wrong. The plan had deferred real data to acceptance, six tasks later. Fixtures
  encode the plan's understanding, and only the oracle can disagree with it.
- **A config file that sets a value explicitly pins the old behaviour past a code fix.** In one
  project (2026-10-15), moving the ritual version source from the source clone to the
  installed plugin was correct in code. But the repo's `config/sb.toml` named the clone path
  explicitly, and would have overridden the fix on the one machine that mattered. When a default
  moves, grep every config file for the key, and put deleting the stale line in the brief.
- **A rule change has copies the plan will not name.** On 2026-10-21 a change to how memory keys
  are derived left the old rule in three places: tests' hand-built expected values, a fallback
  branch, and two shipped docs. A red team found the tests and the final review found the docs.
  The same seam runs the other way. Two entries added to a data file broke a test that parses the
  real file, and nobody noticed for a day, because the suite that reads it never ran. Before
  planning a change to a rule or a shared file, grep for its SHAPE (the transform, the file name)
  across tests, fallbacks and docs, and list every hit in the brief.
- **A ruling that makes a step run on EVERY invocation must be costed with the real tool first.**
  Before ruling, ask what the step's check already does. A ruling that ran each fix whenever its
  check said `present` closed a real gap: leftovers from an interrupted run. But the secret-scan
  check already ran a live proof on every run, planting a fake key and running the commit hook.
  So the ruling added a second, identical proof: about 6.9 s and one more fake-key plant per run,
  to catch a rare case. Two scoped reviews passed it. A side agent caught it by asking what the
  change cost the user. The fix was a `--proved` flag that reuses the check's result (2026-10-18).
  "Idempotent" means safe to repeat, not cheap to repeat.
- **A defensive "also reset X" ruling is often an equivalent mutant.** Before ruling it, check
  whether X's only writer always runs before X's only reader. A ruling to clear an "aim broken"
  flag at every grab added a line no test could fail: the swap's start assigned the flag on every
  push, and the line printing it always ran later. The implementer's own mutation found 0 failures
  and it was removed a task later (2026-10-19). The same run's plan also asserted a final position
  that its own coordinates contradicted; compute a plan's geometry from its numbers before writing
  an assertion on it.
- **Run `scripts/sdd-workspace` with the PROJECT as the working directory, never the skill's.** It
  resolves the repo from cwd, so a call made from the skill directory created the workspace inside
  the repo that holds the skill instead of the project (2026-10-19). Check the printed path is under the project.
- **A plan that says HOW to measure something under engine timing is a premise; probe it first.**
  A plan offered "real time = scaled `delta` / `Engine.time_scale`" for a camera push-in. In Godot
  4.7.2 the `_process` of the frame in which the scale drops still receives the OLD scale's delta,
  so a 0.3 s push-in was used up on its first frame. All its tests passed because they set the scale
  BEFORE calling `push_in`, an order the game never uses; a reviewer's 20-line probe found it
  (2026-10-20). **A test must reproduce the production call order**, or it tests a different
  program.

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
- **Commit from Bash with `git commit -F <file>`**; on Windows see git-standards (the BOM rule). On
  machines with a command guard, `$(...)` in `-m` is denied.
- **Say that committing is the implementer's job; only a push needs the user.** One fix agent
  finished and tested its work, then stopped short of the commit because it believed a commit
  needed the user's approval (2026-10-26).
- **Report rather than resolve** wherever the controller made a non-obvious call, and report any
  disagreement with a pre-registered number rather than reconciling it.
- **Write the full report to a file and return verdict + path.** Long returns truncate. For long
  reviews, require appending each result to the file before starting the next.
- **List every claim you did NOT execute**, then route those to a reviewer told to RUN them.
- **Grep the staged diff for mutation markers** (`and False`, `if False`, `if True`) before every
  commit. A deliberate mutation once sat in the working tree of a security guard.
- **Keep the tracking-issue close out of the implementer's scope.** It belongs after the final
  review.
- **`scripts/task-brief` copies only the task's own section.** The plan's Global Constraints and
  Review Focus, where the exact values and rows live, are not in it, though the brief refers to
  them. Extract both once into `globals.md` in the workspace and name that file in every implementer
  and reviewer dispatch (2026-10-20: a 24-line brief pointed at constants it did not carry).

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
- **Revert a mutation with a targeted edit, never `git checkout <file>`.** The file usually also
  holds the task's uncommitted work: one implementer's checkout revert wiped two of its own fixes.
  It noticed and redid them, and the scoped re-review then had to prove the commit held them and no
  leftover mutant (2026-10-20). Put this in the dispatch whenever a fix round includes a mutation.

## 4. Verify reports, including the reviewers'

- **Run the suite yourself once, at the end.** Reviewers are told not to re-run it, so every number
  in the chain comes from the implementer it measures. One controller gate closes the chain.
- **An implementer's gate counts as yours only when three facts line up.** Every changed file's
  mtime is earlier than the gate logs' creation time. The tree is clean at the commit. Every log
  carries `REAL_EXIT=0`. Then the gates covered the exact committed tree, and re-running them adds
  nothing; on a 50-minute suite that is real time. If any of the three fails, run them yourself.
  A merge from main is a new tree and always needs a fresh gate. So does a run that stopped
  without its terminal marker: a passing tally up to the kill point is not a pass. A merge can
  also break a test that pins a total, such as a count of registered hooks, when both sides add
  one; only the gate on the merged tree finds that (2026-10-19).
- **A gate on one OS cannot see what that OS cannot represent.** Windows has no Unix file
  permissions, so a test that a hook keeps mode 750 passed there while the code turned it into
  751; only the Linux gate caught it (2026-10-26). When CI skips suites on Linux, run them there
  directly and compare the failing test names against the pre-batch tree run the same way: only
  new names belong to the branch.
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
- **A claim of INDEPENDENCE needs a perturbation control, not a green run.** "The suite no longer
  reads the developer's tuning file" passed 204/204 on the file as it stood, and that run also passes
  if the file is still read and happens to hold compatible values. The implementer listed the
  control as not executed. The controller rewrote the file with extreme values (warp 0, buffer 0,
  every new knob flipped), re-ran, then restored it from git: still 204/204. Only that run measured
  the claim. Whenever a task claims "X no longer depends on Y", change Y and run it. (A Godot
  project, 2026-10-10.)

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

- **Disjoint files is not independence.** One project's test DB drops the schema in every fixture; two
  concurrent runs produced 1 failed + 22 errors. Overlap implementers only with READ-ONLY reviewers
  told not to run the suite. If a collision happened, both results are UNKNOWN; re-run one at a time.
- **Agent toolchain runs share USER-level state with the human, not just the repo.** Headless Godot
  test runs write to the same `user://logs` directory as the developer's own play session, and Godot
  keeps five files. Within minutes the log of the developer's hang had been rotated out, and its
  evidence was gone. When the human is playing or testing while implementers run, point agent runs
  at their own log/cache path (Godot: `--log-file <tmp>`), and capture any crash evidence the
  moment it is reported. (A Godot project, 2026-10-10.)
- **After any task touching global nav, routing or always-mounted UI, run the FULL suite.** A
  wizard's global guard regressed ~16 e2e specs that per-task runs could not see.

## 7. The final whole-branch review earns its cost

Per-task review structurally cannot see cross-task seams: a number produced in three tasks and read
by none; two independently written predicates that drifted; a value re-resolved across a function
six tasks edited. Dispatch the final review on the most capable model, point it at cross-task
coherence explicitly, and give every reviewer **named risks, each with one focused check** — nearly
every Important finding in one run came from a named risk.

- **Name "every preview of an outcome against the action that produces it" as a final-review risk.**
  A debug indicator drew where a grab's swap would leave the target, computed from the player's
  position before the press; the grab warps first, so at range the line was up to 2 m off. Its
  test compared the drawn line with the same pre-warp formula, a symmetric control, and the
  per-task review approved it. The final review caught it (2026-10-19). Fix shape: one helper that
  both the action and the preview call, tested against a hand-computed value in a setup where the
  action changes the inputs.

- **Before pushing to a public repo, scan the commit messages and the WHOLE tree, not only the
  diff.** Per-task privacy scans read only the code changes. The branch's own messages, written
  mid-task, carry project names and paths just as easily. Files that were already on main were
  never in any diff at all: a full-tree scan before one release found 98 lines naming private
  projects, all older than the branch. Scan term by term, with a planted control (2026-10-19).

## Provenance

Promoted 2026-10-05 from eight private project memories in five projects; the detail and dated
evidence stay there.
