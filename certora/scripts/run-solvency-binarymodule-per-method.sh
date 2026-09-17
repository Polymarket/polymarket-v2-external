#!/bin/bash
# Run the BinaryModule solvencyPreserved rule one heavy method at a time, so each parametric
# case is its own cloud job with its own timeout budget (faster / more reliable than letting
# all BinaryModule cases share the single solvencyPreserved job).
#
# Job layout:
#   * split/merge/redeem/resolveMigrationCondition — submitted here via --method on the main
#     conf (certora/confs/solvency/BinaryModule.conf), which covers every non-view
#     BinaryModule method except the two migratePositions overloads (conf exclude_method).
#   * the two migratePositions overloads (the heaviest cases) — submitted via their DEDICATED
#     confs (BinaryModuleMigrate.conf / BinaryModuleMigrateFrom.conf, conf-level method
#     filter), so they always run as individual jobs, with or without this script.
# The remaining methods (reportResult, admin/init/roles) are trivial for the ghost inequality
# and verify fine together in a plain `certoraRun <main conf>` run.
#
# Usage: certora/scripts/run-solvency-binarymodule-per-method.sh   (from the activated .venv)
# Each invocation submits a separate job (the confs have wait_for_results: none), so all jobs
# are launched back-to-back and run in parallel on the server.
set -u

CONF="certora/confs/solvency/BinaryModule.conf"

# Heavy BinaryModule methods covered by the MAIN conf. ABI signatures use the UDVT underlying
# types: ConditionId = bytes31, PositionId = uint256. Contract-qualified (BinaryModule.*) for
# clarity, even though BinaryModule is this conf's only parametric contract.
METHODS=(
    "BinaryModule.split(address[],bytes31,uint256)"
    "BinaryModule.merge(address,bytes31,uint256)"
    "BinaryModule.redeem(address,uint256,uint256)"
    "BinaryModule.resolveMigrationCondition(bytes32)"
)

for m in "${METHODS[@]}"; do
    echo "[*] solvencyPreserved --method \"$m\""
    certoraRun "$CONF" \
        --rule solvencyPreserved \
        --method "$m" \
        --msg "GLOB-SOLVENCY BinaryModule: $m" \
        --server production
done

# migratePositions overloads: dedicated confs (method filter baked into the conf).
echo "[*] solvencyPreserved migratePositions (dedicated confs)"
certoraRun certora/confs/solvency/BinaryModuleMigrate.conf --server production
certoraRun certora/confs/solvency/BinaryModuleMigrateFrom.conf --server production
