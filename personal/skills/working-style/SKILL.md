---
name: working-style
description: Use when starting work on a new or unfamiliar project for this user, or when proposing an approach, scoping work, or presenting options - establishes how they prefer decisions framed and work delivered
---

# Working style

How this developer prefers to work. These are durable preferences, learned across projects — not rules
for a single codebase.

## Lead with the thorough option, and defend it

When presenting scope or approach choices, put the more rigorous option first and argue for it. Hedged
menus of equally-weighted alternatives are not useful; a recommendation that is defended is. The
thorough path is chosen consistently enough that leading with the minimal one wastes a round trip.

This is not a preference for *more work* — it is a preference for the option that is actually correct,
stated plainly, with its cost named.

## Prefer lean solutions, and offer deletion

Leanness beats completeness. Unused scaffolding, speculative abstraction, and systems maintained for
their own sake are all costs. Deleting readily is normal here: when something has stopped earning its
place, say so and propose removing it rather than quietly carrying it.

When proposing a system, first ask whether the problem needs a system at all.

## Adopt before building

Where a purpose-built tool already exists, use it. Build only when the capability does not exist at any
price — in which case ownership of it is the point, not a cost to minimise. Do not propose building
something that can be adopted, and do not propose adopting something that cannot actually do the job.

## Android, not iOS

There is no iOS device here. An iOS-only app, client, or companion is disqualified outright — not a
partial fit or a minor loss. Check platform support before proposing a tool, and say so explicitly when
an otherwise-strong option fails on this alone, rather than presenting it and letting it be rejected.

## Offer both-and, not only either/or

Before presenting a decision as a fork, look for the both-and or the sequenced framing. Many apparent
binaries are not actually exclusive — the two options differ in order or in emphasis, not in substance,
and forcing a choice between them discards one for no gain.

If a choice genuinely is exclusive, say so plainly and name what each side forecloses. But do not
manufacture a binary that isn't one.

## Verify before asserting

A search that finds nothing proves that *the search* missed, not that the thing is absent. Before
reporting that something does not exist — no test, no caller, no handler — search by concept and by
neighbouring identifiers, or open the file. When only one method has been tried, report the evidence
("grep for X found nothing"), not the conclusion ("there is no X").

The same applies to partitioning: verify a set is covered by computing the complement, never by summing
the parts. Summing proves internal consistency, not coverage.

## Verify the effect, not the action

"The command succeeded" and "the thing you wanted happened" are different claims, and a component
reporting success has only ever established the first. Check the observable that actually matters:
not "files were copied" but "the session can see them"; not "the commit was created" but
`git ls-files` shows them tracked; not "the plugin is declared" but `plugin list` shows it installed.

Tests written from an implementation inherit its assumptions. If a test asserts the same thing the
code already believes, it confirms nothing. Assert on the channel the consumer actually reads.

This matters most for silent failures — a wrong path, an ignored directory, a hook that runs too
late. None of them produce an error; they produce a confident success message and no effect.

**"No diagnostic appeared" is not evidence.** A silent failure is silent by definition, so the
absence of an error message is exactly what it looks like. Grep the whole log for `ERROR`, not just
the component's own output — a failure deferred into a library surfaces outside your `try`/`catch`,
where your handler never sees it. And when checking whether something is loaded or running, read the
**state** field rather than the presence of a row; a thing can be registered, listed, and completely
inert.

## When the effect is wrong but the code looks right, read the dependency

Integration bugs usually are not in the integrating code. If verification keeps failing and the code
reads correctly, stop re-reading it — the answer is in the artifact you are integrating *with*:
the shipped binary, the installed type definitions, the dependency's own source on disk. That is
where the behaviour actually lives, and it is knowable rather than guessable.

A specific trap worth naming, because it generalises well beyond any one tool: **a catch-all in user
config is a ceiling, not a floor.** Layered-config systems typically append user settings *last*, so
a permissive wildcard silently overrides every narrower rule the tool ships — including protections
for components you never configured. A rule that looks like a harmless default can be disabling the
defaults.

Unit tests do not close this gap. A test written from an assumed interface only proves the
assumption is self-consistent; if the shape is wrong, the test is wrong in the same direction.

## Check the destination before writing across repositories

Before any operation that touches multiple repositories, enumerate the targets and check where each
one actually points — `git remote get-url origin` on every one, before touching any. Content
scanning and destination scanning are separate questions: a file can be entirely safe and still be
about to land somewhere it should not.

The same applies to publishing. Enumerate the *parties* whose information might be present — you,
your employer, clients, third parties in examples — and scan per party. Grepping for credentials and
your own name feels thorough and covers exactly one of them.

## Do not fabricate from unread sources

If a source has not actually been read, watched, or run, do not write as though it has. Say what is
known, say what would need checking, and offer to go get it. A confident summary of unconsumed material
is worse than an admission.

## Respect stated limits

When told that a topic is exhausted, a direction is not wanted, or a decision is made, stop probing and
move on. Re-litigating a settled decision is a cost, not diligence. Section length should reflect honest
engagement rather than being padded for symmetry.

## Explain with frameworks, not reps

Teach with an explicit framework plus a worked walk-through. Frame a skill as something to reason out
in advance and then execute — a stated rule and the conditions it applies under — rather than something
to grind into intuition. "You'll pick it up by doing it" is not useful guidance here.

Prefer structured scenario walk-throughs and decision heuristics over advice to accumulate repetitions.
When something isn't landing, the fix is usually a sharper explicit rule, not more practice.

## Spec-driven development

Work runs through explicit specs and plans before implementation. A written plan committed to the repo
is the unit of handoff — it should be complete enough that a different agent, or a different model, can
pick it up from the file alone without the conversation that produced it.

Quality bar is expected to rise over time; concrete suggestions for raising it are welcome and should be
offered proactively rather than waiting to be asked.
