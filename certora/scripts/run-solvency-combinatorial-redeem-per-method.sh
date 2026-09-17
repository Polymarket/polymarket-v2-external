#!/bin/bash
# Run the CombinatorialModule result-aware solvency rule one method at a time, via --method,
# so each parametric instantiation is its own cloud job. Verifying every method in a single
# job pressures the prover (the result-aware `redeem`/`compress` cases are degree-3 nonlinear
# proofs — yes*f0*f1 / no*f0*f1 — and sharing a job with split/merge + all PositionManager
# methods starves it), so we split the CombinatorialModule methods out here and let each get
# the full job budget. `compress` is `redeem` plus a residual-position case (burns Q, mints
# collateralOut pUSD + the residual conjunction Q'); it is at least as heavy as redeem.
#
# Usage: certora/scripts/run-solvency-combinatorial-redeem-per-method.sh
# Each invocation submits a separate job (the conf has wait_for_results: none), so all jobs are
# launched back-to-back and run in parallel on the server.
#
# PositionManager methods are intentionally NOT split (they touch no combinatorial ghost — the
# real PM assembly runs and the liability/pUSD ghosts are untouched — so they verify trivially;
# they are also already proven in certora/specs/solvency/PositionManager.spec).
set -u

CONF="certora/confs/solvency/CombinatorialModuleRedeem.conf"

# CombinatorialModule methods covered by solvencyPreserved's filter. Each is contract-qualified
# (CombinatorialModule.*) because BinaryModule/NegRiskModule are also in scene. ABI signatures
# use the UDVT underlying types: ConditionId = bytes31, PositionId = uint256.
METHODS=(
    "CombinatorialModule.split(address[],bytes31,uint256)"
    "CombinatorialModule.merge(address,bytes31,uint256)"
    "CombinatorialModule.redeem(address,uint256,uint256)"
)

for m in "${METHODS[@]}"; do
    echo "[*] solvencyPreserved --method \"$m\""
    certoraRun "$CONF" \
        --rule solvencyPreserved \
        --method "$m" \
        --msg "Combinatorial result-aware solvency: $m" \
        --server production
done