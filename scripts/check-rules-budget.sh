#!/usr/bin/env bash
# check-rules-budget.sh [rules_dir=core/rules] [limit=9000]
# Prints "rules: <n> chars (limit <limit>)". Exit 0 when n < limit, 1 when over,
# 2 when the directory holds no .md files (UNKNOWN, never a pass).
dir="${1:-core/rules}"
limit="${2:-9000}"
export LC_ALL=C.UTF-8
if [ "$(printf 'é' | wc -m | tr -d ' ')" != 1 ]; then export LC_ALL=C.utf8; fi

files=()
while IFS= read -r -d '' f; do files+=("$f"); done < <(find "$dir" -type f -name '*.md' -print0 2>/dev/null | sort -z)
if [ "${#files[@]}" -eq 0 ]; then
  echo "rules: no .md files under $dir (UNKNOWN)" >&2
  exit 2
fi
n=$(cat "${files[@]}" | wc -m | tr -d ' ')
echo "rules: $n chars (limit $limit)"
if [ "$n" -lt "$limit" ]; then exit 0; fi
exit 1
