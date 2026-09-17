#!/usr/bin/env bash
set -euo pipefail

# Use the `ci` profile (foundry.toml) so code_size_limit applies consistently
# across forge test/coverage/snapshot. CI already sets this; this ensures local
# invocations behave the same.
export FOUNDRY_PROFILE="${FOUNDRY_PROFILE:-ci}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

FAILED=0

# Filter: only data rows (skip header separators like |---+---+...|).
# The leading-name pattern must accept an underscore so reserved storage gaps
# (e.g. `__gap`) appear in the baseline — without this, `forge inspect` and the
# baseline both silently drop gap rows and the check passes vacuously.
filter_layout() {
  grep -E '^\| [a-zA-Z_]'
}

# --- PositionManager ---
forge inspect src/positionManager/PositionManager.sol:PositionManager storage-layout \
  | filter_layout > "$WORK_DIR/position-manager-layout.txt"

if ! diff -q .storage-layouts/PositionManager.md "$WORK_DIR/position-manager-layout.txt" > /dev/null 2>&1; then
  echo "Storage layout changed for PositionManager!"
  echo ""
  diff .storage-layouts/PositionManager.md "$WORK_DIR/position-manager-layout.txt" || true
  echo ""
  echo "If intentional, run: forge inspect src/positionManager/PositionManager.sol:PositionManager storage-layout | grep -E '^\| [a-zA-Z_]' > .storage-layouts/PositionManager.md"
  FAILED=1
else
  echo "PositionManager storage layout unchanged."
fi

# --- CollateralToken ---
forge inspect src/collateral/CollateralToken.sol:CollateralToken storage-layout \
  | filter_layout > "$WORK_DIR/collateral-token-layout.txt"

if ! diff -q .storage-layouts/CollateralToken.md "$WORK_DIR/collateral-token-layout.txt" > /dev/null 2>&1; then
  echo "Storage layout changed for CollateralToken!"
  echo ""
  diff .storage-layouts/CollateralToken.md "$WORK_DIR/collateral-token-layout.txt" || true
  echo ""
  echo "If intentional, run: forge inspect src/collateral/CollateralToken.sol:CollateralToken storage-layout | grep -E '^\| [a-zA-Z_]' > .storage-layouts/CollateralToken.md"
  FAILED=1
else
  echo "CollateralToken storage layout unchanged."
fi

# --- OracleAggregator ---
forge inspect src/oracle/OracleAggregator.sol:OracleAggregator storage-layout \
  | filter_layout > "$WORK_DIR/oracle-aggregator-layout.txt"

if ! diff -q .storage-layouts/OracleAggregator.md "$WORK_DIR/oracle-aggregator-layout.txt" > /dev/null 2>&1; then
  echo "Storage layout changed for OracleAggregator!"
  echo ""
  diff .storage-layouts/OracleAggregator.md "$WORK_DIR/oracle-aggregator-layout.txt" || true
  echo ""
  echo "If intentional, run: forge inspect src/oracle/OracleAggregator.sol:OracleAggregator storage-layout | grep -E '^\| [a-zA-Z_]' > .storage-layouts/OracleAggregator.md"
  FAILED=1
else
  echo "OracleAggregator storage layout unchanged."
fi

# --- OOReporterModule ---
forge inspect src/oracle/modules/OOReporterModule.sol:OOReporterModule storage-layout \
  | filter_layout > "$WORK_DIR/oo-reporter-module-layout.txt"

if ! diff -q .storage-layouts/OOReporterModule.md "$WORK_DIR/oo-reporter-module-layout.txt" > /dev/null 2>&1; then
  echo "Storage layout changed for OOReporterModule!"
  echo ""
  diff .storage-layouts/OOReporterModule.md "$WORK_DIR/oo-reporter-module-layout.txt" || true
  echo ""
  echo "If intentional, run: forge inspect src/oracle/modules/OOReporterModule.sol:OOReporterModule storage-layout | grep -E '^\| [a-zA-Z_]' > .storage-layouts/OOReporterModule.md"
  FAILED=1
else
  echo "OOReporterModule storage layout unchanged."
fi

# --- BinaryModule ---
forge inspect src/modules/BinaryModule.sol:BinaryModule storage-layout \
  | filter_layout > "$WORK_DIR/binary-module-layout.txt"

if ! diff -q .storage-layouts/BinaryModule.md "$WORK_DIR/binary-module-layout.txt" > /dev/null 2>&1; then
  echo "Storage layout changed for BinaryModule!"
  echo ""
  diff .storage-layouts/BinaryModule.md "$WORK_DIR/binary-module-layout.txt" || true
  echo ""
  echo "If intentional, run: forge inspect src/modules/BinaryModule.sol:BinaryModule storage-layout | grep -E '^\| [a-zA-Z_]' > .storage-layouts/BinaryModule.md"
  FAILED=1
else
  echo "BinaryModule storage layout unchanged."
fi

# --- NegRiskModule ---
forge inspect src/modules/NegRiskModule.sol:NegRiskModule storage-layout \
  | filter_layout > "$WORK_DIR/negrisk-module-layout.txt"

if ! diff -q .storage-layouts/NegRiskModule.md "$WORK_DIR/negrisk-module-layout.txt" > /dev/null 2>&1; then
  echo "Storage layout changed for NegRiskModule!"
  echo ""
  diff .storage-layouts/NegRiskModule.md "$WORK_DIR/negrisk-module-layout.txt" || true
  echo ""
  echo "If intentional, run: forge inspect src/modules/NegRiskModule.sol:NegRiskModule storage-layout | grep -E '^\| [a-zA-Z_]' > .storage-layouts/NegRiskModule.md"
  FAILED=1
else
  echo "NegRiskModule storage layout unchanged."
fi

# --- CombinatorialModule ---
forge inspect src/modules/CombinatorialModule.sol:CombinatorialModule storage-layout \
  | filter_layout > "$WORK_DIR/combinatorial-module-layout.txt"

if ! diff -q .storage-layouts/CombinatorialModule.md "$WORK_DIR/combinatorial-module-layout.txt" > /dev/null 2>&1; then
  echo "Storage layout changed for CombinatorialModule!"
  echo ""
  diff .storage-layouts/CombinatorialModule.md "$WORK_DIR/combinatorial-module-layout.txt" || true
  echo ""
  echo "If intentional, run: forge inspect src/modules/CombinatorialModule.sol:CombinatorialModule storage-layout | grep -E '^\| [a-zA-Z_]' > .storage-layouts/CombinatorialModule.md"
  FAILED=1
else
  echo "CombinatorialModule storage layout unchanged."
fi

# --- Custom Storage Slot Tests ---
echo ""
echo "Running custom storage slot tests..."
if ! forge test --mc StorageSlots -vvv; then
  echo "Custom storage slot tests failed!"
  FAILED=1
fi

if [ "$FAILED" -eq 1 ]; then
  echo ""
  echo "Storage layout check failed."
  exit 1
fi

echo ""
echo "All storage layout checks passed."
