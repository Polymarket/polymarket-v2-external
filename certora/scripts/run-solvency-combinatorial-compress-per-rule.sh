#!/bin/bash
# Run the CombinatorialRefineCompress value-conservation rules one at a time, via --rule, so each
# case is its own cloud job with its own timeout budget. The three rules partition the compress
# resolution space for a 2-leg conjunction (residual: one leg resolved with fr != 0; terminal-zero:
# one leg resolved to 0 + one unresolved; all-resolved: both legs resolved), so launching them
# separately keeps a heavier case from starving the others.
#
# Usage: certora/scripts/run-solvency-combinatorial-compress-per-rule.sh   (from the activated .venv)
# Each invocation submits a separate job (the conf has wait_for_results: none), so all
# jobs are launched back-to-back and run in parallel on the server.
set -u

CONF="certora/confs/solvency/CombinatorialRefineCompress.conf"

# All rules in certora/specs/solvency/CombinatorialRefineCompress.spec:
RULES=(
    "compressResidualValueConserving"
    "compressTerminalZeroValueConserving"
    "compressAllResolvedValueConserving"
)

for r in "${RULES[@]}"; do
    echo "[*] --rule \"$r\""
    certoraRun "$CONF" \
        --rule "$r" \
        --msg "Combinatorial compress: $r" \
        --server production
done