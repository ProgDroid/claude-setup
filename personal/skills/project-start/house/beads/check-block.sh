#!/usr/bin/env sh
# Verify the Beads managed block has not clobbered the local TodoWrite override.
# Run after any `bd setup claude` or beads upgrade.
#
# It is a script, not a grep line inside CLAUDE.md, because a probe that lives
# inside the corpus it probes matches its own documentation.
#
# Exit: 0 = ok, 1 = a check FAILED, 2 = UNKNOWN (the probe could not answer).

set -u
F="${1:-CLAUDE.md}"
fail=0

# Stop at the FIRST end marker. A stray later marker (in documentation, say)
# must not be able to extend the range to EOF.
block=$(awk '/BEGIN BEADS INTEGRATION/{f=1} f{print} /END BEADS INTEGRATION/{if(f)exit}' "$F")

if [ -z "$block" ]; then
  echo "UNKNOWN: no managed block found in $F -- the probe cannot answer"
  exit 2
fi

if printf '%s\n' "$block" | grep -q "do NOT use TodoWrite"; then
  echo "FAIL: the TodoWrite ban is back inside the managed block"
  fail=1
else
  echo "ok: no TodoWrite ban inside the managed block"
fi

# The block also ships a memory imperative that contradicts this repo's policy
# (memory is files; bd owns work state only).
if printf '%s\n' "$block" | grep -q "do NOT use MEMORY.md"; then
  echo "FAIL: the bd-remember / no-MEMORY.md line is back inside the managed block"
  fail=1
else
  echo "ok: no MEMORY.md ban inside the managed block"
fi

if grep -q "^## Task tracking vs. execution structure" "$F"; then
  echo "ok: the local override section is present"
else
  echo "FAIL: the local override section is missing from $F"
  fail=1
fi

exit "$fail"
