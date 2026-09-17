#!/usr/bin/env bash
set -euo pipefail

# Enforces that production code never calls `ConditionId.wrap(...)` or
# `EventId.wrap(...)` directly. These compiler-provided UDVT constructors are
# UNVALIDATED and bypass the canonicality guarantees that protect against
# alias-key attacks. The only legitimate call site is:
#
#   - src/libraries/Ids.sol — the type definitions, the validating `from`
#     constructors, and the typed encoders/decoders that produce UDVTs from
#     raw layout components that are canonical by bit construction.
#
# Tests are exempt: fuzz harnesses, expected-revert wrappers, and snapshot
# tooling legitimately need to construct non-canonical values.
#
# The check has three layers:
#   1. Paren-anchored grep, so `.unwrap(` and prose mentions like "wrap up"
#      do not match. Targets only the literal `Type.wrap(` call shape.
#   2. Strip `//` line comments before the second match so NatSpec / inline
#      comments referencing `ConditionId.wrap` do not produce false positives.
#   3. Forbid aliased imports of the UDVTs in production code so the literal
#      grep cannot be bypassed via `import { ConditionId as Cond } from "...";`.

ALLOWED=(
  "src/libraries/Ids.sol"
)

# Test/dev/mocks directories are exempt from the wrap rule.
EXCLUDE_DIRS_PATTERN="src/.*/test/|src/.*/dev/|src/.*/mocks/|src/test/|src/dev/|src/mocks/"

# Layer 1: paren-anchored candidates. `.wrap\(` excludes `.unwrap(` (the char
# before `wrap` would have to be `.`, and `unwrap` has `un` in between).
CANDIDATES=$(grep -rnE '(ConditionId|EventId)\.wrap\(' src/ --include="*.sol" 2>/dev/null \
  | grep -vE "$EXCLUDE_DIRS_PATTERN" \
  | grep -v "^src/libraries/Ids.sol:" \
  || true)

# Layer 2: strip line comments per-match before re-checking. Drops `///` NatSpec
# and `//` inline comments that mention the pattern.
MATCHES=$(echo "$CANDIDATES" | awk -F: '
  /^[[:space:]]*$/ { next }
  {
    line = $0
    sub(/^[^:]+:[0-9]+:/, "", line)   # strip file:lineno: prefix
    sub(/\/\/.*$/, "", line)          # strip line comments
    if (line ~ /(ConditionId|EventId)\.wrap\(/) print $0
  }')

# Layer 3: detect aliased UDVT imports in production code. These would let a
# caller bypass the literal-name grep by renaming the type locally.
ALIASED=$(grep -rnE 'import[[:space:]]*\{[^}]*\<(ConditionId|EventId)[[:space:]]+as[[:space:]]+' \
    src/ --include="*.sol" 2>/dev/null \
  | grep -vE "$EXCLUDE_DIRS_PATTERN" \
  | grep -v "^src/libraries/Ids.sol:" \
  || true)

FAILED=0

if [ -n "$MATCHES" ]; then
  echo "FAIL: production code must not call ConditionId.wrap / EventId.wrap directly."
  echo "These bypass the canonicality check. Use ConditionIdLib.from / EventIdLib.from"
  echo "instead. Allowed library files:"
  for f in "${ALLOWED[@]}"; do
    echo "  - $f"
  done
  echo ""
  echo "Offending lines:"
  echo "$MATCHES"
  FAILED=1
fi

if [ -n "$ALIASED" ]; then
  if [ "$FAILED" -eq 1 ]; then echo ""; fi
  echo "FAIL: production code must not alias ConditionId / EventId on import."
  echo "Aliased imports (e.g. \`import { ConditionId as Cond }\`) would let callers"
  echo "bypass the wrap-discipline grep via the renamed type. Import the UDVTs"
  echo "under their canonical names only."
  echo ""
  echo "Offending lines:"
  echo "$ALIASED"
  FAILED=1
fi

if [ "$FAILED" -eq 1 ]; then
  exit 1
fi

echo "Wrap discipline check passed: no unvalidated wrap() calls in production code."
