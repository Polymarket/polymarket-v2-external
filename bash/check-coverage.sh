#!/usr/bin/env bash
set -euo pipefail

# Use the `ci` profile (foundry.toml) so code_size_limit applies consistently
# across forge test/coverage/snapshot. CI already sets this; this ensures local
# invocations behave the same.
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ci}"

LINE_THRESHOLD=90
BRANCH_THRESHOLD=80

# Paths to exclude from coverage enforcement (test infra, mocks, legacy, external)
EXCLUDE_PATHS="test/|dev/|mocks/|legacy/|external/"

# Files to exclude even if they appear in coverage output (known edge cases)
EXCLUDE_FILES=()

OUTPUT=$(forge coverage --report summary 2>&1)
FAILED=0
CHECKED=0

# Extract production file lines from coverage output, excluding non-production paths and Total row
FILES=$(echo "$OUTPUT" | grep -E "^\| src/" | grep -v -E "$EXCLUDE_PATHS" | grep -v "Total" || true)

while IFS= read -r LINE; do
  [ -z "$LINE" ] && continue

  FILE=$(echo "$LINE" | awk -F'|' '{gsub(/^ +| +$/,"",$2); print $2}')

  # Skip excluded files
  SKIP=0
  for EXCL in "${EXCLUDE_FILES[@]+"${EXCLUDE_FILES[@]}"}"; do
    if [ "$FILE" = "$EXCL" ]; then
      SKIP=1
      break
    fi
  done
  [ "$SKIP" -eq 1 ] && continue

  LINE_COV=$(echo "$LINE" | awk -F'|' '{split($3, a, "%"); gsub(/[^0-9.]/, "", a[1]); print a[1]}')
  BRANCH_COV=$(echo "$LINE" | awk -F'|' '{split($5, a, "%"); gsub(/[^0-9.]/, "", a[1]); print a[1]}')

  # Guard against empty values from unexpected forge output format
  if [ -z "$LINE_COV" ] || [ -z "$BRANCH_COV" ]; then
    echo "FAIL: $FILE — could not parse coverage values (line='${LINE_COV}' branch='${BRANCH_COV}')"
    FAILED=1
    continue
  fi

  echo "$FILE: lines=${LINE_COV}% branches=${BRANCH_COV}%"
  CHECKED=$((CHECKED + 1))

  if [ "$(echo "$LINE_COV < $LINE_THRESHOLD" | bc -l)" -eq 1 ]; then
    echo "FAIL: $FILE line coverage ${LINE_COV}% < ${LINE_THRESHOLD}%"
    FAILED=1
  fi

  if [ "$(echo "$BRANCH_COV < $BRANCH_THRESHOLD" | bc -l)" -eq 1 ]; then
    echo "FAIL: $FILE branch coverage ${BRANCH_COV}% < ${BRANCH_THRESHOLD}%"
    FAILED=1
  fi
done <<< "$FILES"

echo ""

# Guard against zero files checked — prevents silent pass on format changes
if [ "$CHECKED" -eq 0 ]; then
  echo "FAIL: No production files found in coverage output. forge coverage format may have changed."
  exit 1
fi

echo "Checked $CHECKED production files (line threshold: ${LINE_THRESHOLD}%, branch threshold: ${BRANCH_THRESHOLD}%)"

if [ "$FAILED" -eq 1 ]; then
  echo "Coverage check failed. One or more production files below threshold."
  exit 1
fi

echo "All production files at or above threshold."
