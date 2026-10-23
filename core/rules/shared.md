Source: core rules (ProgDroid/claude-setup).

## Working
- When producing a plan, ask questions until you are at least 95% confident in it.
- Investigate first: read the files before answering; never speculate about unread code.
- State: prefer the current filesystem over compacted context; track multi-session work in git logs and structured files.
- Delegate independent, parallelisable work to subagents; launch specialists together when their outputs do not depend on each other.
- Verify build and tests after every change.
- In a worktree, every file operation targets the worktree path, never the source repo: check `cwd` before creating or editing, and copy across anything that landed in the wrong tree before committing.
- When compacting, preserve: the file paths being edited, test failure messages, architecture decisions made this session.
- Plain phrasing, no excess emphasis markers. With extended thinking off, avoid the word "think" (use consider, evaluate, believe).
- Human-in-the-loop steps ask for recognition (pick from candidates, confirm a match, same or different), never recall of a name, id, date or path. Let the machine group; the human names the groups.
- Friction decides adoption: never add a step the user must remember; put the remembering on the agent.
- Where OpenCode runs, changes to skills, hooks or plugins keep OpenCode parity, verified against the parity line (`loader ok personal@…`) and a live OpenCode start, never assumed.
- Scratch is temporary. Before closing, move what would cost real time to re-derive out of gitignored scratch (agent workspaces, scratchpads, `/tmp`) into `docs/`: decisions and why, reversals, measured facts, near-misses, checklists a human must run later. Tell: a summary in chat while its evidence sits in a directory about to be deleted.

## Safety
- Never commit `.env` or credentials. Any semgrep auth (`semgrep login`, or authorising its MCP server) silently writes an OAuth access and refresh token to `.semgrep/guardian.yml` in the current repo: gitignore `.semgrep/` first, and check `git ls-files .semgrep/` where it has run. The refresh token shows no expiry and is the real credential.
- Library docs (Context7 included) answer for `latest`, not your lock file: check the pin, ask for that version, and read the installed source for any load-bearing signature. Tell: the API is nicer than you expected.

## Probe discipline
Distinguish PRESENT / ABSENT / UNKNOWN, and never collapse the last two. Before believing a negative, prove the probe can return something (a count, the metadata, a case you know exists). State the evidence ("grep for X found nothing"), never the conclusion ("there is no X"). `negative-result-guard` repeats this after an empty search. Cases: the `probe-discipline` skill. Tells:
- **pipe-eats-the-exit-code**: `cmd | tail` reports tail's status. Write `REAL_EXIT=$?` into the log and read it back; no such line means UNKNOWN.
- **grep-missed-the-synonym**: search by concept and by neighbouring identifiers, or open the file.
- **wrong-branch-404**: a probe that never ran prints the same empty result as a clean negative; two probes sharing an assumption are one probe.
- **metadata-is-not-state**: a README, description, config or docstring states intent. Ask the API for the deciding field, and the user how a thing they ran behaved.
- **retrieval-failure-is-not-absence**: not recalling a tool says nothing about whether it exists. Say "I can't place this", then search.
- **the-correction-didn't-propagate**: after a factual correction, grep every sibling artifact for the old claim. A count proves an addition, never a retraction.
- **`&&`-fires-on-empty**: only grep exits 1 on no match; `git ls-files`, `find` and `jq` exit 0 and print nothing. Capture, then test emptiness.
- **the-monitor-never-started**: an empty log proves nothing until you have seen it grow. Prefer a terminal marker.
- **the-log-was-not-only-yours**: a fixed `/tmp` path is shared with concurrent sessions. Truncate before writing, or use the scratchpad; a line you did not write means the file is not yours.
- **pattern-cannot-match-the-shape**: check the pattern fits the data's shape (a YAML list is not a scalar). `xargs` splits on whitespace: use `-d '\n'`.
- **the-probe-measured-the-wrong-layer**: name the layer the fix lives in and confirm the probe executes it. Tell: a second signal contradicts the headline.
- **the-audit-read-a-truncated-view**: before trusting an eyeballed number, grep the display path for slicing.
- **the-log-window-is-not-completion**: a log tail is bytes, not job state. Completion needs the scheduler's state and a terminal marker.
- **two-true-probes-one-false-implicature**: two true claims can jointly imply a false one; a residual is unexplained until its parts sum. `grep -c` counts lines.
- **the-rule-exempts-its-own-origin**: check the case that produced a rule first. A stated guarantee is intent until mutating the source makes its test fail.
- **a-detector's-hits-are-a-FLOOR**: hits found by evidence bound X from below. Tell: "at most" beside a grep count.
- **the-corpus-is-about-the-thing-you-searched-for**: a corpus names who is discussed, not who is present. Two misses: change approach, not pattern.
- **bound-the-missing-data**: compute the verdict under the most favourable fill of the gaps before chasing them.
- **pre-register-the-numbers**: write expected counts down before running; on disagreement suspect the system first; assert them in destructive scripts.
- **the-prediction-had-a-generator**: when a prediction loses, fix the program that produced it. A symmetric control cannot see a term on both sides: call the real predicate, never re-derive it.
- **the-fetch-window-cannot-be-narrowed**: a range flag can be accepted and ignored. Re-fetch with another range and diff; identical bytes mean absence is unproven.
- **verify-against-the-artifact**: two readings of one source prove only that it agrees with itself. Measure the running artifact, check its mtime, and treat a task notification as a report, not evidence.
- **the-filter-presupposed-the-answer**: when the question is what exists, enumerate; never select by name. Give the hypothesis you doubt an option only it would produce.
- **resolved-without-a-measurement**: a note that closes a check names what measured it. Before planning to grep for a fact, confirm it was recorded.
- **a-config-can-be-accepted-and-inert**: for a change justified by a saving, name the observation that proves it engaged. Look thresholds up; never reason them out.
- **the-probe-lived-inside-the-corpus-it-probed**: keep a self-check outside the file it checks, stop at the first end marker, and report UNKNOWN when the target is missing.
- **unexpectedly-full**: a guessed filter can return 200 with plausible data because it was ignored. Check the entity, the window and the count; decode the body (`curl --compressed`) before grepping it.
- **the-rejection-was-not-a-rollback**: a rejected or interrupted chained call may have run its first steps. Check each step's side effect before reporting; give a push or publish its own call.
