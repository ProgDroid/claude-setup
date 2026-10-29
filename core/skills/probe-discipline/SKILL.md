---
name: probe-discipline
description: Use when a probe returns empty or surprising output, and before trusting a negative, a count, a log tail, a stale artifact, a "success" status or a docs answer. Case stories behind the always-on probe-discipline rules in core/rules/shared.md.
---

# Probe discipline

The always-on rule (`core/rules/shared.md`) carries the principle and a one-line tell for each trap. This skill carries the evidence: what went wrong, how it looked from the inside, and the countermeasure. Find the entry whose tell matches what you are seeing, then apply its countermeasure before you report.

## The principle

A probe that ran, exited 0 and printed something can still license a wrong inference. The principle (PRESENT / ABSENT / UNKNOWN, prove the probe can return something, state the evidence not
the conclusion) is in core rules § Probe discipline. What the rule leaves out is why it matters: a broken
thing reported as broken gets retried, but a working thing reported as broken sends you hunting a bug that
does not exist, and a real thing reported as absent is silently dropped and never rechecked.

## Entries

### pipe-eats-the-exit-code
**Tell:** a build or test is called green from a command that ended in a pipe or a `;`-chain.
**Case:** `flutter test | tail` showed exit 0 while five tests had failed. A backgrounded build chain ending in `tail` reported "completed (exit code 0)" for a release build that had died on a real error. `pipefail` does not help when there is no pipe.
**Countermeasure:** make the command write its status into the artifact (`cmd > LOG 2>&1; echo "REAL_EXIT=$?" >> LOG`) and read the log. A missing `REAL_EXIT=` line is UNKNOWN. A notification from the harness describes the chain, not the command.

### grep-missed-the-synonym
**Tell:** a claim of absence ("no test", "no caller", "no handler") rests on one pattern.
**Case:** a test asserting the exact behaviour existed under a name sharing no substring with the grep pattern. The search found nothing, the absence was reported as fact, and the false absence became a false recommendation to write a test that already existed.
**Countermeasure:** search by concept and by neighbouring identifiers, or open the file.

### wrong-branch-404
**Tell:** an API or tree query returns nothing, and no one asked how big the answer should be.
**Case:** a repository tree query against `main` returned a 404, the shell printed nothing, and the empty result read as "this project has no importer". The default branch was `master`: 4,400 blobs and a whole import subsystem. An earlier failed probe was one step from being written up as "two independent probes found nothing".
**Countermeasure:** before believing an empty result, ask for the count (`length`, blob count, row count) or the metadata (`default_branch`). Check failed probes for a shared broken assumption before their agreement counts as evidence.

### metadata-is-not-state
**Tell:** a README, description field, config file or docstring is used to say what works, who wrote it or whether it is reachable.
**Case:** `core:working-style` § Verify the effect, not the action.
**Countermeasure:** ask the API for the deciding field (`isFork`, visibility, the real compensation figure). For anything the user has personally run, ask them how it behaved, since no artefact holds that.

### retrieval-failure-is-not-absence
**Tell:** "I don't recognise this tool" is about to become "this tool probably doesn't exist".
**Case:** two real, widely used projects were dismissed as probable fabrications, and a famous author's attribution was called "a classic confabulation tell". Both were real, popular and recently updated. A quieter variant: a user wrote that they had "recently found out about" a term, and the answer mapped it to the older meaning the model knew, never leaving a slot for a sense newer than its training.
**Countermeasure:** say "I can't place this", then run a search before characterising it. When listing a term's senses, include "or something newer I can't place". Fire a search on the bare term whenever the user says "new" or "recently".

### the-correction-didn't-propagate
**Tell:** a factual correction landed in the file a review named.
**Case:** `core:capture-learnings` § The audit pass, step 6 (the correction sweep).
**Countermeasure:** grep every sibling artifact for the old claim. Counting occurrences proves an addition, never a retraction, because a retraction names what it retracts. Read the hits.

### `&&`-fires-on-empty
**Tell:** `cmd && echo FOUND || echo MISSING` around anything other than `grep`.
**Case:** `git ls-files android/key.properties && echo TRACKED` printed the alarm for a file that was never tracked, and `git log --all -- path` did the same: two false credential-leak alarms in one command. Only `grep` exits 1 on no match. `git ls-files`, `find` and `jq` exit 0 and print nothing.
**Countermeasure:** capture output in a variable and test emptiness, paired with a positive control that must find something known to be there.

### the-monitor-never-started
**Tell:** an empty log after a clean run, or silence from a background watcher.
**Case:** a GPU-temperature logger started with `&` was reaped when its wrapper shell exited, so the task "succeeded" with a dead logger. A second logger wrote to a file and buffered, leaving it at 0 bytes while running correctly.
**Countermeasure:** read line counts twice, seconds apart, before starting the work you mean to watch. For "it did not crash", check continuity (the largest gap between samples). Prefer a terminal marker the program writes last, since a hung process cannot write its own.

### the-log-was-not-only-yours
**Tell:** a line in your log is in a convention you do not use.
**Case:** `cmd >> /tmp/push.log`, read back, reported a push to a repository the command could not have touched. A concurrent session had written the same fixed path, and `>>` appended under it. The giveaway was a marker (`PUSH_EXIT=`) next to the author's own (`REAL_EXIT=`).
**Countermeasure:** concurrent sessions are normal, so a fixed `/tmp` filename is shared mutable state. Truncate with `>` before writing, or use the session scratchpad. Treat any line you did not write as evidence the file is not yours.

### pattern-cannot-match-the-shape
**Tell:** a count of zero over data you know is populated.
**Case:** `^type: *\S` scored 0 across 75 notes and was about to be reported as "the Type column is empty". It was populated on 69 of them, as a YAML list with the value on the following line. In the same session `xargs` split a file list on spaces, reporting 0 files when a 26 KB file was known to be in the set. In another, a test helper grepped compact JSON (`"decision":"deny"`) against a pretty-printer that writes a space after the colon, so the helper returned ALLOW for every input.
**Countermeasure:** `sed` one real file before concluding. Use `xargs -d '\n'` or `-0`. Parse JSON with `jq` rather than grepping it. A helper that gives a binary verdict needs a test in both directions.

### the-probe-measured-the-wrong-layer
**Tell:** a second signal from the same run contradicts the headline number.
**Case:** `core:sdd-controller` § 4. Verify reports, including the reviewers' (the bullet beginning "Before a number scores a fix").
**Countermeasure:** name the layer the fix lives in (prompt, parser, merge, render) and confirm the probe executes it. When two signals from one run disagree, suspect the aggregate before the system. Report a newly added layer beside the old metric, never in place of it.

### the-audit-read-a-truncated-view
**Tell:** a hand-audited figure with a pile-up of field lengths on a round number.
**Case:** a hand audit of 24 detections scored 61% precision off a display that printed 105 characters of fields already stored at 150. Re-labelled against the full text, the true figure was 33%, and the 61% had already reached a committed spec as the baseline every later fix had to beat. Nothing errored, and the sample was the right size. Only the rendering was lossy.
**Countermeasure:** grep the display path for slicing (`[:N]`, `head -c`, `cut -c`, `truncate`, `Select-Object -First`) before trusting an eyeballed number. Where the full artifact exists, judge from it.

### the-log-window-is-not-completion
**Tell:** a log tail, `docker logs`, `journalctl` window or CI console fetch is being read as job state.
**Case:** `modal app logs` exited 0 after printing 58 lines, all of them skip messages, while the app still held one running task. A job that is running, one that finished and one killed mid-write can produce byte-identical tails.
**Countermeasure:** completion needs two signals: the scheduler's state (`docker inspect`, `gh run view --json status`) AND a terminal marker the program writes last. A harness that kills the local client does not kill the remote job, so detach, then poll.

### two-true-probes-one-false-implicature
**Tell:** two verified claims sit side by side and invite a joint conclusion nobody checked.
**Case:** a spec said "the directory holds 400 of 438 and contains none of one show's episodes, verified twice". Each clause was true; the reader concluded the 38 missing files were that show. The show was seven episodes. Thirty-two of the 39 absent files were recent episodes of shows that were present, because the snapshot was stale. A stated caveat about the gap hid a second, unstated one.
**Countermeasure:** a residual is not explained until it is decomposed and the parts sum. When two probes share a sentence, write what each does not establish. "Verified twice" is a strength claim about the probes, never the conclusion. `grep -c` counts lines, so a single-line XML feed returned 1 for seven items: use `grep -o pat | wc -l`.

### the-rule-exempts-its-own-origin
**Tell:** a document states a rule and a list, and the case that produced the rule is not on the list.
**Case:** a design spec derived a rule from a field that was populated on every row yet carried no information, then listed the nine fields the rule governed. That field was not among them. The same shape fired twice more in the document. Re-reading cannot catch it, since each section is internally coherent. Two fresh-context passes found about forty defects the author's re-reads missed, and a pass that ran the code found an error class that three reading passes had missed. In the same review, a spec's "fails loudly when X lands" described a test whose fixture could not fail.
**Countermeasure:** name the case that produced a rule and check it first. A spec stating a guarantee is intent; ask which test fails if it is false, then mutate the source and watch it fail. A control that agrees with the bug proves nothing, so count the cases that can discriminate.

### a-detector's-hits-are-a-FLOOR
**Tell:** "at most" attached to a grep result.
**Case:** a spec grepped transcripts for a co-host's surname, found 24 of 341 episodes, and wrote "at most 24 (7.0%)". The probe detects episodes where the name is spoken, so a present but never-named co-host is invisible. Hand labelling put the real rate about four times higher, and the feature failed its gate. In a later audit the records held 3 hits of each of two traps and a transcript pass found 9 and 9.
**Countermeasure:** a detector that finds X by evidence of X bounds X from below. Ask what the probe would miss, print the matches rather than counting them, and measure effort beside the count.

### the-corpus-is-about-the-thing-you-searched-for
**Tell:** a presence probe over text that discusses its subject.
**Case:** a forename search in a geopolitics podcast corpus hit 36 episodes, 27 of them a politician with that forename. A second attempt to recover speaker names from introduction frames ("joined by X") returned world leaders, a weather phenomenon and a country. The probe asked who is present and the corpus answered who is discussed, in identical grammar, with the discussed outnumbering the present by orders of magnitude.
**Countermeasure:** two probes failing the same way is a property of the corpus. Change approach, not pattern. The same trap fits a username that also appears in error strings and a symbol that is a common English word.

### bound-the-missing-data
**Tell:** a large share of labels or measurements came back blank and the metric looks unusable.
**Case:** 112 of 192 clip labels were blank. Rather than guessing, the metric was computed under the most favourable assignment of everything missing: if every unlabelled clip had been the target, precision would be 87.5%, ten points under the 98% gate.
**Countermeasure:** compute the verdict across the full range of the gap before chasing it. It often ends the question, and otherwise says exactly how much of the gap needs closing.

### pre-register-the-numbers
**Tell:** a script or plan is about to run on real data with no written prediction.
**Case:** every production bug found during a corpus repair was found by a written prediction disagreeing with a run, and none by reading code that had been reviewed repeatedly. A predicted 191 exclusions came back included. A predicted "unreachable (6)" came back 13, the extra seven being every episode of one feed: a whole feed failing to load, not items ageing off. Mutation-specific counts live in `core:sdd-controller` § 3.
**Countermeasure:** write the expected items, actions and counts into the ledger before the run, somewhere you cannot quietly revise. On disagreement, assume the prediction was right and the system is wrong. Assert the values inside destructive scripts so a world that moved causes a refusal. A pre-registration makes a result attributable, not informative: ask how probable the outcome was under the hypothesis you want to reject.

### the-prediction-had-a-generator
**Tell:** a pre-registered number lost, and a committed script produced it.
**Case:** a pre-registered 432 met a planner's 428, and the planner was right. A committed script had computed 432, and fixing the runbook would have left it re-emitting 432 at every future boundary. The script's control compared feed episodes before a boundary with the archive count, and four deliberate exclusions appear once in each, so they cancelled exactly.
**Countermeasure:** ask what produced the prediction; if a program did, the program is the defect and the number is a symptom. A stale document is inert, a stale generator re-emits the error with a fresh timestamp. Call the real predicate (`is_excluded`) instead of re-deriving it. A generator is fixed when it reproduces a number reality has already ruled on.

### the-fetch-window-cannot-be-narrowed
**Tell:** a range or filter flag on a retrieval, with no proof it took effect.
**Case:** `--since 9h` and `--since 6h --until 5h` returned the same 3,283 lines, byte-identical under `cmp -s`. Both exited 0. The server capped what it returned and the range never entered into it, so a missing log line was UNKNOWN, never ABSENT.
**Countermeasure:** re-fetch with a deliberately different range and diff. Identical bytes mean the flag is ignored and absence is unproven. Then stop narrowing and take the fact from an independent source that shares no machinery with the log path.

### verify-against-the-artifact
**Tell:** a configuration value is called verified because two readings of its source agree.
**Case:** two SHA-1 fingerprints read from a console were both accurate, and neither had been compared with the APK, which the device was presenting under a third key. Separately, a merged manifest dated three weeks before the feature answered "no RECORD_AUDIO" with a passing positive control. And a backgrounded build announced "completed (exit code 0)" after it had failed, because the harness reported the pipeline's status.
**Countermeasure:** two readings of one source prove only that it agrees with itself. Measure the running artifact (`apksigner --print-certs`, `grep` on the binary, the platform's own log), put the mtime beside the control so it proves it is looking at today, and escalate to the platform log early, since a generic client error is the lossy end of a relabelling chain. A task notification is a report, not evidence.

### the-filter-presupposed-the-answer
**Tell:** a diagnostic selects fields by a name pattern when the question is what exists.
**Case:** a diagnostic built to answer "what is the id field called here" selected fields with `if "id" in k.lower()`. The answer was `position_key`, which contains no "id". Twenty fields came back and five were shown, for one of three records, on every run for a month, including runs made because the question was open. A later guess of `positionId`, by convention, was also wrong: a snake_case outlier in a camelCase response.
**Countermeasure:** when the question is what exists, enumerate; print the whole key set of every record, names not values. State the claim the probe supports ("record 0 has no id-named field"), never the one you want. The same trap applies to a question put to the user: give the hypothesis you doubt an option only it would produce (options "2.00" and "2.06" both presupposed dollars; "same on every buy, or different per trade?" discriminated).

### resolved-without-a-measurement
**Tell:** a note says a check is no longer needed, or tells you not to propose it again.
**Case:** a memory said "the exit path has now run for real, so the deliberate round trip is no longer needed". Counted in the log, with controls: `LIVE OPEN` 7, a failure line 424, the success line 0. The user's confirmation was real but covered opening. The note generalised it and retired the one action that would have caught the gap.
**Countermeasure:** a note that closes a verification action must name what measured it; ask which observation would differ if it were false. A note that forbids the check removes the mechanism that would correct it. Before planning to grep for a fact, confirm it was ever recorded: a payload that was never logged can only be instrumented for.

### a-config-can-be-accepted-and-inert
**Tell:** a change is justified by a saving, and nothing has shown the feature engaged.
**Case:** prompt caching was written and about to ship. The cacheable prefix was 777 tokens against a 1,024-token minimum, below which `cache_control` is accepted and silently does nothing: no error, `cache_creation_input_tokens: 0`. It would have reviewed clean and saved zero. In another tool, a flush interval of `0s` was accepted and inert.
**Countermeasure:** name the observation that proves the feature engaged (a non-zero `cache_read_input_tokens`) and check the code can produce it. Minimums are not monotonic across model generations, so look the number up. An approved plan inherits the evidence it was made on, not the evidence that arrived since; withdraw your own proposal if the measurements moved.

### the-probe-lived-inside-the-corpus-it-probed
**Tell:** the second fix fails the same assertion as the first.
**Case:** a check written into `CLAUDE.md` to detect a restored ban matched its own documentation (line 100). The rewrite, scoped between block markers with `sed`, matched the markers inside its own code block, opening a second range that ran to EOF. Both fixes patched the pattern; the defect was the placement.
**Countermeasure:** move a self-check into a separate artifact. Stop at the first end marker, so a stray marker cannot extend the range. Report UNKNOWN (exit 2) when the target cannot be found at all, and verify against a deliberately reverted copy so it is known to discriminate, not merely to pass.

### unexpectedly-full
**Tell:** HTTP 200 with plausible data from a filter or parameter name you guessed.
**Case:** a guessed nested identifier-and-timestamp body on an events-calendar API returned a global 41-entity calendar: the target entity was absent and the date window ignored. The correct flat body returned exactly the one entity. Separately, `curl` without `--compressed` handed back gzip bytes, four content greps scored 0, and the archived page read as "never archived". With the flag, all four matched in 72 KB.
**Countermeasure:** verify the content, not the status: is the entity present, was the window respected, is the row count what one entity should return? A round-number result count is a tell, so compare `total` with the array length. Check the first bytes or the byte count before concluding a body does not contain something.

### the-rejection-was-not-a-rollback
**Tell:** a tool call comes back "rejected" or "interrupted", and it was a chain of steps.
**Case:** a single Bash call ran ledger-append, `git push -u origin <branch>`, then `gh pr create`. The user stopped it; the result said "rejected… STOP". The push and the append had both happened; only the PR had not. Treating "rejected" as "nothing ran" would have left a stray remote branch unmentioned.
**Countermeasure:** after a rejected or interrupted chain, check the side effect of every step (`git ls-remote`, `gh pr list`, the file) before reporting or retrying. Split outward-facing steps (push, publish, PR) into their own calls so a rejection lands on one action.

### the-oracle-held-one-axis-fixed
**Tell:** a large equivalence or regression suite is all green, and every case ran in the same environment.
**Case:** a differential of a rewrite against the old code ran 1,040 cases (20 commands, 13 fixture repos, 4 states) on two OSes: 0 differ. The final review found two regressions it could not see. Every case ran with the locale unset, the one setting where Git Bash's `=~` and GNU grep classify `é` alike, and no fixture held an invalid UTF-8 byte, the one input where bash `read` joins two lines.
**Countermeasure:** a case count measures one point on every axis the cases do not vary. List what the old behaviour depended on that the fixtures hold constant (locale, byte classes, NUL, CR, tool build, OS) and vary each at least once, with a guard that fails when the varied setting is unavailable.
