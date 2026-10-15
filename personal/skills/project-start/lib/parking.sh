#!/usr/bin/env bash
# Step: parking-lot (docs/parking-lot.md + the house rule in the project CLAUDE.md).
# Source this file; do not execute it. Needs common.sh sourced first.

_PARK_LOT_TEMPLATE="$RITUAL_SKILL_DIR/house/parking-lot.md"
_PARK_RULE_FILE="$RITUAL_SKILL_DIR/house/parking-rule.md"
_PARK_LOT_PATH='docs/parking-lot.md'

# _park_scan <claude-md> -> prints "rule" if the house rule bullet is present, and/or
# "other:<N>" for the first line mentioning the parking lot that is not part of that bullet.
# CRs are stripped before matching so a CRLF file is read like an LF one.
_park_scan() {
  [ -f "$1" ] || return 0
  tr -d '\r' < "$1" | awk -v p="$_PARK_LOT_PATH" '
    /^- \*\*Parking lot\.\*\*/ { rule = 1; inrule = 1; next }
    inrule && /^[ \t]/ { next }
    { inrule = 0 }
    index($0, p) && !other { other = NR }
    END { if (rule) print "rule"; if (other) print "other:" other }'
}

check_parking_lot() {
  local repo="$1" scan miss="" n
  scan="$(_park_scan "$repo/CLAUDE.md")"
  [ -f "$repo/$_PARK_LOT_PATH" ] || miss="$_PARK_LOT_PATH missing"
  if [ ! -f "$repo/CLAUDE.md" ]; then miss="${miss:+$miss; }CLAUDE.md missing"
  elif ! grep -qx 'rule' <<<"$scan"; then
    n="$(sed -n 's/^other://p' <<<"$scan")"
    if [ -n "$n" ]; then miss="${miss:+$miss; }different rule exists (line $n)"
    else miss="${miss:+$miss; }CLAUDE.md lacks the parking-lot rule"; fi
  fi
  if [ -z "$miss" ]; then emit parking-lot present "docs/parking-lot.md exists and CLAUDE.md has the rule"
  else emit parking-lot absent "$miss"; fi
}

# _park_fence <line>: track ``` / ~~~ fenced blocks in the global _PARK_FENCE (empty = outside).
# Returns 0 when <line> is a fence delimiter or is inside a fence (so it cannot be a heading).
_park_fence() {
  local l="${1%$'\r'}"
  if [[ -n "$_PARK_FENCE" ]]; then
    [[ "$l" =~ ^\ {0,3}${_PARK_FENCE}{3,}[[:space:]]*$ ]] && _PARK_FENCE=""
    return 0
  fi
  if [[ "$l" =~ ^\ {0,3}(\`\`\`|~~~) ]]; then _PARK_FENCE="${BASH_REMATCH[1]:0:1}"; return 0; fi
  return 1
}

# _park_insert_rule <claude-md>: add the house rule under ## Working rules. Existing bytes are
# kept; lines are inserted with the file's own line ending.
_park_insert_rule() {
  local f="$1" eol=$'\n' rule=() line i h=0 end last k tmp ts
  [ "$(eol_of "$f")" = crlf ] && eol=$'\r\n'
  mapfile -t rule < <(tr -d '\r' < "$_PARK_RULE_FILE")
  local -a lines
  mapfile -t lines < "$f"
  _PARK_FENCE=""
  for i in "${!lines[@]}"; do
    _park_fence "${lines[$i]}" && continue
    line="${lines[$i]%$'\r'}"
    if [[ "$line" =~ ^##[[:space:]]+Working[[:space:]]+rules[[:space:]]*$ ]]; then h=$((i + 1)); break; fi
  done
  if [ "$h" -eq 0 ]; then   # no section: append one at EOF
    if [ -s "$f" ]; then
      last="${lines[${#lines[@]}-1]%$'\r'}"
      [ -n "$last" ] && append_line "$f" ""
    fi
    append_line "$f" "## Working rules"
    append_line "$f" ""
    for line in "${rule[@]}"; do append_line "$f" "$line"; done
    return 0
  fi
  end=${#lines[@]}          # index of the next "## " heading, else EOF
  _PARK_FENCE=""
  for ((i = h; i < ${#lines[@]}; i++)); do
    _park_fence "${lines[$i]}" && continue
    if [[ "${lines[$i]}" == '## '* ]]; then end=$i; break; fi
  done
  k=$((end - 1))            # insert after the last non-blank line of the section
  while [ "$k" -ge "$h" ] && [ -z "${lines[$k]%$'\r'}" ]; do k=$((k - 1)); done
  k=$((k + 1))              # number of lines kept before the insertion
  tmp="$f.park.$$"
  head -n "$k" "$f" > "$tmp"
  if [ -s "$tmp" ] && [ "$(tail -c 1 "$tmp" | od -An -tx1 | tr -d ' \n')" != 0a ]; then printf '%s' "$eol" >> "$tmp"; fi
  [ "$k" -eq "$h" ] && printf '%s' "$eol" >> "$tmp"   # empty section: blank line after the heading
  for line in "${rule[@]}"; do printf '%s%s' "$line" "$eol" >> "$tmp"; done
  ts=$((k + 1))
  [ "$k" -eq "$h" ] && [ "$end" -gt "$h" ] && ts="$end"   # empty section: keep exactly one of its blank lines
  tail -n +"$ts" "$f" >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
}

fix_parking_lot() {
  local repo="$1" scan n wrote=() detail="" status
  if [ ! -f "$repo/$_PARK_LOT_PATH" ]; then
    mkdir -p "$repo/docs" && cp "$_PARK_LOT_TEMPLATE" "$repo/$_PARK_LOT_PATH" || { emit parking-lot failed "could not create $_PARK_LOT_PATH"; return 0; }
    wrote+=("$_PARK_LOT_PATH")
  fi
  scan="$(_park_scan "$repo/CLAUDE.md")"
  n="$(sed -n 's/^other://p' <<<"$scan")"
  if grep -qx 'rule' <<<"$scan"; then :
  elif [ -n "$n" ]; then
    emit parking-lot absent "different rule exists (line $n); house rule needs ask" "${wrote[@]}"; return 0
  elif [ ! -f "$repo/CLAUDE.md" ]; then
    { printf '## Working rules\n\n'; tr -d '\r' < "$_PARK_RULE_FILE"; } > "$repo/CLAUDE.md"
    wrote+=(CLAUDE.md)
  else
    _park_insert_rule "$repo/CLAUDE.md"; wrote+=(CLAUDE.md)
  fi
  if ! grep -qx 'rule' <<<"$(_park_scan "$repo/CLAUDE.md")"; then
    emit parking-lot failed "rule not found in CLAUDE.md after insert" "${wrote[@]}"; return 0
  fi
  if [ "${#wrote[@]}" -gt 0 ]; then emit parking-lot fixed "created: ${wrote[*]}" "${wrote[@]}"
  else emit parking-lot already "nothing to add"; fi
}
