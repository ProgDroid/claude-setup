#!/usr/bin/env bash
# The ritual record: $(git rev-parse --git-common-dir)/ritual.json. Written only from here, by bash.

record_file() {
  local g; g="$(git_common_dir "$1" 2>/dev/null)" && [ -n "$g" ] || return 1
  printf '%s/ritual.json\n' "$g"
}

record_path() { jq -nc --arg p "$(record_file "$1")" '{path:$p}'; }

record_read() {
  local f; f="$(record_file "$1")"
  if [ -f "$f" ]; then jq -c . "$f"; else echo '{}'; fi
}

# record_write <repo> <results.json>
record_write() {
  local repo="$1" res="$2" f cur tmp
  [ -f "$res" ] || die "results file not found: $res"
  jq -e '(.steps|type)=="object"' "$res" >/dev/null 2>&1 || die "results.json must be {\"steps\":{...}}"
  f="$(record_file "$repo")"
  cur='{}'; [ -f "$f" ] && cur="$(cat "$f")"
  tmp="$f.tmp.$$"
  printf '%s' "$cur" | jq -c --slurpfile new "$res" --slurpfile reg "$(steps_json)" --arg today "$(date +%F)" '
    ($reg[0]) as $r
    | ($r.steps | map({key:.id, value:.version}) | from_entries) as $ver
    | ($r.steps | map(.id)) as $order
    | ($new[0].steps | with_entries(.value |= (. + {version: null}))
       | with_entries(.value.version = ($ver[.key] // null))) as $stamped
    | (.steps // {}) as $old
    | ($old + $stamped) as $steps
    | ($steps | to_entries
        | map(select(.value.result == "unknown" or .value.result == "interrupted") | .key)) as $open
    | (. + {ritual_version: $r.ritual_version, completed_at: $today, steps: $steps,
            open_steps: (($order | map(select(. as $i | $open | index($i)))) + ($open - $order))}
         + (if $new[0].baseline then {baseline: $new[0].baseline} else {} end))
  ' > "$tmp" || { rm -f "$tmp"; die "record merge failed"; }
  mv "$tmp" "$f"
  jq -c . "$f"
}

# due <repo> -> {"offer":[ids],"skip":[{id,reason}]}
# Skipped only when recorded result is "declined" AND recorded version == current version. A step
# marked "per_run": true in steps.json is never skipped: its question is about this run's content
# (what to commit now), so an earlier "no" does not answer it.
record_due() {
  local cur; cur="$(record_read "$1")"
  printf '%s' "$cur" | jq -c --slurpfile reg "$(steps_json)" '
    (.steps // {}) as $s
    | ($reg[0].steps) as $st
    | ($st | map(select((.per_run != true) and ($s[.id].result // "") == "declined" and ($s[.id].version // null) == .version))) as $skip
    | {offer: ($st | map(select(. as $x | $skip | map(.id) | index($x.id) | not) | .id)),
       skip: ($skip | map({id, reason: ("declined at version " + (.version|tostring))}))}'
}
