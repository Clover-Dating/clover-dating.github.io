#!/bin/bash
# update-metrics.sh — Collect clover-app repo metrics for the landing page
#
# Usage:
#   ./update-metrics.sh --seed    Build daily history from first commit to today
#   ./update-metrics.sh           Add any missing days since last entry through today
#
# Incremental: only computes metrics for dates not already in metrics.json.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../clover-app" && pwd)"
METRICS_FILE="$SCRIPT_DIR/metrics.json"

cd "$REPO_DIR"

# Count source lines at a given git ref
count_loc() {
  local ref="$1"
  local total=0
  local files
  files=$(git ls-tree -r --name-only "$ref" -- src/ supabase/ 2>/dev/null | grep -E '\.(ts|tsx|js|jsx|sql)$' || true)
  if [ -z "$files" ]; then echo "0"; return; fi
  while IFS= read -r f; do
    lines=$(git show "$ref:$f" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    total=$((total + lines))
  done <<< "$files"
  echo "$total"
}

# Compute metrics for a single date and print the JSON entry
compute_day() {
  local d="$1"
  local commit
  commit=$(git rev-list -1 --before="${d}T23:59:59" HEAD 2>/dev/null || true)
  if [ -z "$commit" ]; then return 1; fi
  local c l
  c=$(git rev-list --count "$commit")
  l=$(count_loc "$commit")
  printf '{"date":"%s","commits":%d,"loc":%d}' "$d" "$c" "${l:-0}"
}

# Read existing entries from metrics.json (returns them, one per line, no commas)
read_existing() {
  if [ ! -f "$METRICS_FILE" ]; then return; fi
  while IFS= read -r line; do
    clean=$(echo "$line" | sed 's/^[[:space:]]*//' | sed 's/,$//')
    if [[ "$clean" == "[" ]] || [[ "$clean" == "]" ]] || [[ -z "$clean" ]]; then continue; fi
    echo "$clean"
  done < "$METRICS_FILE"
}

# Write array of entry strings to metrics.json
write_json() {
  local count=$#
  local i=0
  echo "[" > "$METRICS_FILE"
  for entry in "$@"; do
    i=$((i + 1))
    if [ "$i" -lt "$count" ]; then
      echo "  ${entry}," >> "$METRICS_FILE"
    else
      echo "  ${entry}" >> "$METRICS_FILE"
    fi
  done
  echo "]" >> "$METRICS_FILE"
}

# Collect existing dates into a lookup string
existing_dates=""
entries=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  entries+=("$line")
  # Extract date from JSON
  d=$(echo "$line" | sed 's/.*"date":"\([^"]*\)".*/\1/')
  existing_dates="${existing_dates}${d} "
done <<< "$(read_existing)"

today=$(date +%Y-%m-%d)

if [ "${1:-}" = "--seed" ]; then
  # Build daily history from first commit to today
  first_date=$(git log --reverse --format='%ad' --date=short | head -1 || true)
  echo "Seeding daily metrics from $first_date to $today..." >&2

  current="$first_date"
  while [[ "$current" < "$today" ]] || [[ "$current" == "$today" ]]; do
    if echo "$existing_dates" | grep -qw "$current"; then
      echo "  $current: (cached)" >&2
    else
      entry=$(compute_day "$current" || true)
      if [ -n "$entry" ]; then
        entries+=("$entry")
        echo "  $current: computed" >&2
      fi
    fi
    current=$(date -j -v+1d -f "%Y-%m-%d" "$current" "+%Y-%m-%d" 2>/dev/null \
              || date -d "$current + 1 day" +%Y-%m-%d)
  done

else
  # Incremental: recalculate last entry (may have gained commits) then add new days
  if [ ${#entries[@]} -gt 0 ]; then
    last_entry="${entries[${#entries[@]}-1]}"
    last_date=$(echo "$last_entry" | sed 's/.*"date":"\([^"]*\)".*/\1/')
    # Drop the last entry so it gets recomputed
    unset 'entries[${#entries[@]}-1]'
    existing_dates=$(echo "$existing_dates" | sed "s/$last_date //")
    current="$last_date"
  else
    current="$today"
  fi

  while [[ "$current" < "$today" ]] || [[ "$current" == "$today" ]]; do
    if echo "$existing_dates" | grep -qw "$current"; then
      echo "  $current: (cached)" >&2
    else
      entry=$(compute_day "$current" || true)
      if [ -n "$entry" ]; then
        entries+=("$entry")
        echo "  $current: computed" >&2
      fi
    fi
    current=$(date -j -v+1d -f "%Y-%m-%d" "$current" "+%Y-%m-%d" 2>/dev/null \
              || date -d "$current + 1 day" +%Y-%m-%d)
  done
fi

# Sort entries by date and write
IFS=$'\n' sorted=($(for e in "${entries[@]}"; do echo "$e"; done | sort -t'"' -k4))
unset IFS

write_json "${sorted[@]}"
echo "Done! ${#sorted[@]} total data points in $METRICS_FILE" >&2
