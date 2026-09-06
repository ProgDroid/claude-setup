#!/usr/bin/env bash
# Tests for redteam-gate.sh.
#
# Run:  bash personal/hooks/test-redteam-gate.sh
#
# The gate shipped 2026-08-26 with no test at all. That is how four gstack lenses --
# three of them wrong for the projects the gate actually fires on -- stayed wired in
# from 2026-08-27 to 2026-09-06 without anything noticing.
#
# Every absence assertion below has a presence sibling in the same case, so an empty
# or crashed hook fails loudly instead of passing every "must not mention" check.

set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
HOOK="$DIR/redteam-gate.sh"
pass=0; fail=0
ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 2; }

raw() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | HOME="$2" bash "$HOOK"; }
ctx() { raw "$1" "$2" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

has()    { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

# Two homes: one where gstack is installed, one where it is not.
GS="$(mktemp -d)"; mkdir -p "$GS/.claude/skills/gstack"
NO="$(mktemp -d)"

SPEC="/repo/docs/superpowers/specs/2026-09-06-thing-design.md"
PLAN="/repo/docs/superpowers/plans/2026-09-06-thing.md"
OTHER="/repo/docs/notes/2026-09-06-thing.md"
WINPLAN='G:\\repo\\docs\\superpowers\\plans\\2026-09-06-thing.md'

echo "== paths that must not trigger =="

out="$(raw "$OTHER" "$NO")"
[ -z "$out" ] && ok "an unrelated .md produces no output" \
              || bad "unrelated .md produced: $out"

out="$(raw "" "$NO")"
[ -z "$out" ] && ok "an empty file_path produces no output" \
              || bad "empty file_path produced: $out"

echo "== spec gate =="

s_no="$(ctx "$SPEC" "$NO")"
s_gs="$(ctx "$SPEC" "$GS")"

has "RED-TEAM GATE (spec)" "$s_no" \
  && ok "spec path fires the spec gate" \
  || bad "spec path did not fire"

has "80 percent of the value" "$s_no" \
  && ok "spec asks for the simpler-design alternative" \
  || bad "spec lost the simpler-design question"

has "assumed rather than established" "$s_no" \
  && ok "spec asks which requirement is assumed" \
  || bad "spec lost the assumed-requirement question"

has "collide with in 6 months" "$s_no" \
  && ok "spec asks about the 6-month constraint" \
  || bad "spec lost the 6-month question"

# The narrowing. These lenses rate UI/UX and push scope up; they must not return.
has "ceo-review" "$s_gs" \
  && bad "spec still delegates to gstack-plan-ceo-review" \
  || ok "spec does not delegate to ceo-review even with gstack present"

has "design-review" "$s_gs" \
  && bad "spec still delegates to gstack-plan-design-review" \
  || ok "spec does not delegate to design-review even with gstack present"

# Strongest form: gstack must make NO difference to the spec gate at all.
[ "$s_no" = "$s_gs" ] \
  && ok "spec message is identical with and without gstack" \
  || bad "spec message still varies on gstack presence"

echo "== plan gate =="

p_no="$(ctx "$PLAN" "$NO")"
p_gs="$(ctx "$PLAN" "$GS")"

has "RED-TEAM GATE (plan)" "$p_no" \
  && ok "plan path fires the plan gate" \
  || bad "plan path did not fire"

has "what breaks in 6 months" "$p_no" \
  && ok "plan keeps the inline objections without gstack" \
  || bad "plan lost its inline objections"

has "eng-review" "$p_no" \
  && bad "plan named eng-review with no gstack installed" \
  || ok "plan does not name eng-review when gstack is absent"

# Presence sibling: proves the two absence checks below are not passing vacuously.
has "eng-review" "$p_gs" \
  && ok "plan adds eng-review when gstack is present" \
  || bad "plan did not add eng-review with gstack present"

has "devex-review" "$p_gs" \
  && bad "plan still delegates to gstack-plan-devex-review" \
  || ok "plan does not delegate to devex-review"

# The lens is an ADDITION, not a replacement -- the inline objections must survive.
has "what breaks in 6 months" "$p_gs" \
  && ok "eng-review is added to the inline prompt, not swapped for it" \
  || bad "eng-review replaced the inline prompt instead of extending it"

echo "== reporting contract =="

# The subagent used to be given no size budget at all, so it wrote an essay, the
# transport clipped it, and recovering the tail cost a second round trip. The full
# review now goes to a file and only three lines come back.
for label in spec plan; do
  case "$label" in
    spec) body="$s_no" ;;
    plan) body="$p_gs" ;;
  esac

  has "docs/superpowers/reviews/" "$body" \
    && ok "$label names the reviews directory for the full write-up" \
    || bad "$label does not tell the subagent where to write the review"

  has "RETURN only" "$body" \
    && ok "$label bounds what comes back" \
    || bad "$label does not bound the returned report"

  has "redteam.md" "$body" \
    && ok "$label names the review filename suffix" \
    || bad "$label does not name the review file suffix"
done

# Safety: the review file must not itself trip the gate, or writing a review starts
# another review, which writes a review...
#
# The directory is READ OUT OF THE MESSAGE rather than hardcoded here. Hardcoding
# reviews/ would keep passing if someone repointed the instruction at plans/ -- the
# gate would loop and the test would not notice, because it would still be probing
# the safe path. This asserts the predicate the subagent will actually act on.
review_dir="$(printf '%s' "$p_gs" | sed -E 's/.*WRITE its complete review to ([^ ]+).*/\1/')"
[ -n "$review_dir" ] && [ "$review_dir" != "$p_gs" ] \
  && ok "the review directory can be read out of the message ($review_dir)" \
  || bad "could not extract the review directory from the message"

out="$(raw "/repo/${review_dir}2026-09-06-thing-redteam.md" "$GS")"
[ -z "$out" ] \
  && ok "writing a review to the instructed path does not re-trigger the gate" \
  || bad "the instructed review path re-triggers the gate - infinite loop"

echo "== shape =="

raw "$SPEC" "$NO" | jq -e . >/dev/null 2>&1 \
  && ok "spec output is valid JSON" \
  || bad "spec output is not valid JSON"

raw "$PLAN" "$GS" | jq -e . >/dev/null 2>&1 \
  && ok "plan+gstack output is valid JSON" \
  || bad "plan+gstack output is not valid JSON"

w="$(ctx "$WINPLAN" "$NO")"
has "RED-TEAM GATE (plan)" "$w" \
  && ok "a Windows backslash path still matches the plan gate" \
  || bad "backslash path did not match"

echo "-- $pass passed, $fail failed"
[ "$fail" -eq 0 ]
