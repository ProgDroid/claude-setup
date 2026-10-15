## Task tracking vs. execution structure

<!-- This section sits deliberately OUTSIDE the managed Beads block: `bd setup claude`
     rewrites the lines between the BEGIN/END markers wholesale. -->

The generated Beads block bans `TodoWrite`. **That ban is overridden here**, which the block
itself sanctions: *"Explicit user or orchestrator instructions override this Beads block."*

| | Owns | Lifetime |
|---|---|---|
| **bd** | what work exists, dependencies, what is ready next | across sessions |
| **TodoWrite / TaskCreate** | how a procedure gets followed — the checklist a skill hands you | within the turn |

Banning `TodoWrite` does not move that state into bd; it deletes it, and with it the
enforcement mechanism of every skill that hands you a checklist (systematic debugging,
test-driven development, verification before completion). **File the issue before writing
the code**, then use `TodoWrite` for the procedure.

Memory is **files**, not `bd remember`: bd owns work state only. Migrating memory into bd
was evaluated and dropped (cross-machine sync would need a pinned `dolt` binary on every
machine); do not re-propose it.

### After any `bd setup claude` or beads upgrade

The managed block is regenerated and the ban comes back. Check it:

```sh
sh .beads/check-block.sh     # 0 = ok, 1 = the override was clobbered, 2 = UNKNOWN
```

It is a script rather than a grep line in this file on purpose: a probe written inside the
file it probes matches its own documentation (see the script's header).
