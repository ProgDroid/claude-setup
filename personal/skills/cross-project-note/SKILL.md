---
name: cross-project-note
description: Use when you notice something that belongs to a different project than the one this session is working in - a bug, an idea, a follow-up, a fact another project needs - to file it for that project's next session instead of losing it.
---

# Cross-project note

Anything you learn about **another** project goes to that project's inbox with `sb add`. Its next
session is briefed on it at startup, so nothing is lost and you don't leave your own task. Mentioning
it in your reply, or asking the user to remember it, loses it.

## What to do

1. **Find the id.** Run `sb all` and take the project's id from that list. Never guess an id from a
   folder name or from how the user referred to it. When it's unclear which entry is meant, or
   whether any is, `sb show <id>` prints a project's path, description and open notes. If none fits,
   tell the user rather than filing it somewhere wrong.
2. **File it without asking:** `sb add --project <id> "<note>"`. It is cheap and reversible: the
   other session marks it done with `sb done <id>`. If `sb show <id>` already lists the same note,
   don't file it again; say it's already on file, with its id.
   - If `sb add` answers with an unknown-id error, choose from the candidates it lists. Never retry
     with another guess.
3. **One note per call.** Write each note so it makes sense with no context from this session: what
   is wrong or wanted, where (a command, file or behaviour), and how it showed up. For example:
   `pause command does not resume the countdown after the second pause (reported by the user while
   working in tally)`.
4. **Then carry on with your own task.** In your reply, say in one line that you filed it, with the
   id `sb add` printed.

## When `sb` is not available

If `sb` is not on PATH (`command -v sb` finds nothing), as in a cloud session, tell the user the
note in one line so they can file it, and continue.

## Not for

- Things about **this** project. Use its own tracker (Beads, a parking lot, or tell the user).
- Work the user asked you to do in the other project now. Do that instead.
