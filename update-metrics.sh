#!/bin/bash
# update-metrics.sh — Collect multi-repo metrics for the landing page
#
# Repos counted:
#   clover-app, clover-dash, blog, branding, github, landing, questions
#
# Each day's entry stores per-repo commits/loc breakdowns so the landing
# page (or anything else) can choose which repos to include in totals.
#
# Usage:
#   ./update-metrics.sh --seed    Build daily history from first commit to today
#   ./update-metrics.sh           Add any missing days since last entry through today
#
# Incremental: only computes metrics for dates not already in metrics.json.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
METRICS_FILE="$SCRIPT_DIR/metrics.json"

# Repo definitions: name|dirs-to-scan|file-extensions
# dirs: space-separated paths (empty = all tracked files)
# extensions: comma-separated (used to build grep pattern)
REPO_DEFS=(
  "clover-app|src/ supabase/|ts,tsx,js,jsx,sql"
  "clover-dash|src/ sql/|ts,tsx,js,jsx,sql,css"
  "blog||html,scss,md,yml,sh"
  "branding|scripts/|sh,py"
  "github||md"
  "landing||html,js,sh,sql,toml"
  "questions||md,json,html,js,tex"
)

# Build a grep -E pattern from comma-separated extensions
make_ext_pattern() {
  echo '\.('"$(echo "$1" | sed 's/,/|/g')"')$'
}

# Count source lines at a given git ref for one repo
# Args: repo_dir ref dirs ext_pattern
count_loc_repo() {
  local repo_dir="$1" ref="$2" dirs="$3" ext_pattern="$4"
  local total=0 files
  if [ -n "$dirs" ]; then
    files=$(git -C "$repo_dir" ls-tree -r --name-only "$ref" -- $dirs 2>/dev/null \
            | grep -E "$ext_pattern" || true)
  else
    files=$(git -C "$repo_dir" ls-tree -r --name-only "$ref" 2>/dev/null \
            | grep -E "$ext_pattern" || true)
  fi
  if [ -z "$files" ]; then echo "0"; return; fi
  while IFS= read -r f; do
    lines=$(git -C "$repo_dir" show "$ref:$f" 2>/dev/null | wc -l | tr -d ' ' || echo "0")
    total=$((total + lines))
  done <<< "$files"
  echo "$total"
}

# Compute metrics for a single date across all repos
# Output: one JSON line with per-repo breakdowns
compute_day() {
  local d="$1"
  local any_commits=0
  local repos_json=""

  for def in "${REPO_DEFS[@]}"; do
    IFS='|' read -r name dirs exts <<< "$def"
    local repo_dir="$BASE_DIR/$name"
    [ -d "$repo_dir/.git" ] || continue

    local commit
    commit=$(git -C "$repo_dir" rev-list -1 --before="${d}T23:59:59" HEAD 2>/dev/null || true)
    if [ -z "$commit" ]; then
      # Repo had no commits yet on this date — omit from entry
      continue
    fi

    local c l ext_pattern
    c=$(git -C "$repo_dir" rev-list --count "$commit" 2>/dev/null || echo "0")
    ext_pattern=$(make_ext_pattern "$exts")
    l=$(count_loc_repo "$repo_dir" "$commit" "$dirs" "$ext_pattern")

    [ -n "$repos_json" ] && repos_json="${repos_json},"
    repos_json="${repos_json}\"${name}\":{\"commits\":${c},\"loc\":${l:-0}}"
    any_commits=1
  done

  [ "$any_commits" -eq 0 ] && return 1
  printf '{"date":"%s","repos":{%s}}' "$d" "$repos_json"
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

# Find the earliest first-commit date across all repos
earliest_first_date() {
  local earliest=""
  for def in "${REPO_DEFS[@]}"; do
    IFS='|' read -r name dirs exts <<< "$def"
    local repo_dir="$BASE_DIR/$name"
    [ -d "$repo_dir/.git" ] || continue
    local fd
    fd=$(git -C "$repo_dir" log --reverse --format='%ad' --date=short 2>/dev/null | head -1 || true)
    if [ -n "$fd" ] && { [ -z "$earliest" ] || [[ "$fd" < "$earliest" ]]; }; then
      earliest="$fd"
    fi
  done
  echo "$earliest"
}

# Collect existing dates into a lookup string
existing_dates=""
entries=()
while IFS= read -r line; do
  [ -z "$line" ] && continue
  entries+=("$line")
  d=$(echo "$line" | sed 's/.*"date":"\([^"]*\)".*/\1/')
  existing_dates="${existing_dates}${d} "
done <<< "$(read_existing)"

today=$(date +%Y-%m-%d)

if [ "${1:-}" = "--seed" ]; then
  # Build daily history from first commit to today
  first_date=$(earliest_first_date)
  if [ -z "$first_date" ]; then
    echo "No commits found in any repo" >&2
    exit 1
  fi
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
