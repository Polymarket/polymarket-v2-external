#!/bin/bash
# Run the NegRiskModule solvency rule one method at a time, via --method, so each
# parametric instantiation is its own cloud job. Verifying every method in a single job
# exhausts the prover's resources (OOM), so we split the NegRiskModule methods out here.
# PositionManager methods are intentionally NOT split (they verify fine together).
#
# Usage: certora/scripts/run-solvency-negrisk-per-method.sh
# Each invocation submits a separate job (the conf has wait_for_results: none), so all
# jobs are launched back-to-back and run in parallel on the server.
set -u

CONF="certora/confs/solvency/NegRiskModule.conf"

# NegRiskModule methods covered by solvencyPreserved's filter. Each is contract-qualified
# (NegRiskModule.*) because BinaryModule is also in scene and shares the inherited methods
# (redeem, migratePositions, reportResult, ...) — an unqualified signature is ambiguous.
# ABI signatures use the UDVT underlying types: EventId = bytes29, ConditionId = bytes31,
# PositionId = uint256.
# convert and both migratePositions overloads are NOT listed: the conf excludes them
# (exclude_method), so submitting them here verifies nothing. They have their own confs —
# solvency/NegRiskModuleConvert, NegRiskModuleMigrate, NegRiskModuleMigrateFrom.
METHODS=(
    "NegRiskModule.horizontalSplit(address,bytes29,uint256)"
    "NegRiskModule.horizontalMerge(address,bytes29,uint256)"
    "NegRiskModule.redeem(address,uint256,uint256)"
    "NegRiskModule.resolveMigrationCondition(bytes32)"
    "NegRiskModule.reportResult(bytes31,uint256[])"
)

for m in "${METHODS[@]}"; do
    echo "[*] solvencyPreserved --method \"$m\""
    certoraRun "$CONF" \
        --rule solvencyPreserved \
        --method "$m" \
        --msg "NegRisk solvency: $m" \
        --server production \
        --prover_version master
done
