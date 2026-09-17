#!/usr/bin/env bash
set -euo pipefail

# Polygon PIP-30 runtime code size limit: 32,768 bytes (32KB)
SIZE_LIMIT=32768

# CI uses a metadata-free profile for deterministic CREATE2 assertions, while most production
# contracts are deployed with compiler metadata. Rebuild with the metadata-bearing default profile
# so the size check cannot inherit smaller CI artifacts. This is exact for the standard/script
# deployment profiles and conservative for the metadata-free oracle profile.
DEPLOYMENT_SIZE_PROFILE="${DEPLOYMENT_SIZE_PROFILE:-default}"
SIZE_BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/polymarket-v2-size-check.XXXXXX")
trap 'rm -rf "$SIZE_BUILD_DIR"' EXIT
OUT_DIR="$SIZE_BUILD_DIR/out"
FOUNDRY_PROFILE="$DEPLOYMENT_SIZE_PROFILE" \
  forge build --force --out "$OUT_DIR" --cache-path "$SIZE_BUILD_DIR/cache" >/dev/null

# Non-production paths to exclude (test, dev, mocks, legacy, external)
EXCLUDE_PATTERN="test/|dev/|mocks/|legacy/|external/"

# Auto-discover production contracts from build artifacts.
# Each artifact at out/<File>.sol/<Contract>.json embeds its source path in
# metadata.settings.compilationTarget. We extract that path, filter out
# non-production directories, then check the deployed bytecode size.

if [ ! -d "$OUT_DIR" ]; then
  echo "FAIL: Build output directory '$OUT_DIR' not found. Run 'forge build' first."
  exit 1
fi

FAILED=0
CHECKED=0

for ARTIFACT in "$OUT_DIR"/*.sol/*.json; do
  [ -f "$ARTIFACT" ] || continue

  # Extract source path and runtime bytecode size using python3 (available on all CI runners)
  RESULT=$(python3 -c "
import json, sys
with open('$ARTIFACT') as f:
    d = json.load(f)
meta = json.loads(d['rawMetadata']) if isinstance(d.get('rawMetadata'), str) else d.get('metadata', {})
if isinstance(meta, str):
    meta = json.loads(meta)
target = meta.get('settings', {}).get('compilationTarget', {})
if not target:
    sys.exit(0)
src_path = list(target.keys())[0]
contract_name = list(target.values())[0]
# deployedBytecode.object is hex-encoded (0x prefix), so (len - 2) / 2 = byte count
bc = d.get('deployedBytecode', {})
obj = bc.get('object', '') if isinstance(bc, dict) else ''
size = (len(obj) - 2) // 2 if obj.startswith('0x') and len(obj) > 2 else 0
print(f'{src_path}\t{contract_name}\t{size}')
" 2>/dev/null) || continue

  [ -z "$RESULT" ] && continue

  SRC_PATH=$(echo "$RESULT" | cut -f1)
  CONTRACT=$(echo "$RESULT" | cut -f2)
  RUNTIME_SIZE=$(echo "$RESULT" | cut -f3)

  # Skip non-src contracts (forge-std, solady, etc.)
  [[ "$SRC_PATH" != src/* ]] && continue

  # Skip non-production paths
  echo "$SRC_PATH" | grep -qE "$EXCLUDE_PATTERN" && continue

  # Skip abstract contracts / interfaces / libraries with no deployable code
  [ "$RUNTIME_SIZE" -eq 0 ] && continue

  CHECKED=$((CHECKED + 1))
  MARGIN=$((SIZE_LIMIT - RUNTIME_SIZE))

  if [ "$RUNTIME_SIZE" -gt "$SIZE_LIMIT" ]; then
    echo "FAIL: $CONTRACT ($SRC_PATH) runtime size ${RUNTIME_SIZE}B exceeds ${SIZE_LIMIT}B limit (over by $((RUNTIME_SIZE - SIZE_LIMIT))B)"
    FAILED=1
  else
    echo "  OK: $CONTRACT ${RUNTIME_SIZE}B (margin: ${MARGIN}B)"
  fi
done

echo ""

if [ "$CHECKED" -eq 0 ]; then
  echo "FAIL: No production contracts found in build artifacts."
  exit 1
fi

echo "Checked $CHECKED production contracts against ${SIZE_LIMIT}B Polygon PIP-30 limit."

if [ "$FAILED" -eq 1 ]; then
  echo "Contract size check failed."
  exit 1
fi

echo "All production contracts within size limit."
