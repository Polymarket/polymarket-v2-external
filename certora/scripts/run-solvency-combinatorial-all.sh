#!/bin/bash
# Run the entire CombinatorialModule solvency suite. Most confs launch whole (one cloud job each);
# the result-aware split/merge/redeem proofs are handled by their own per-method runner (they are
# degree-3 nonlinear and starve the prover if they share a single job).
#
# Split out to dedicated runners (invoked / referenced here, NOT launched whole):
#   * split / merge / redeem  -> run-solvency-combinatorial-redeem-per-method.sh (one --method/job),
#     invoked at the end of this script.
#   * payout-equivalence conf (confs/eq/CombinatorialPayoutEquivalence.conf) -> validates the
#     positionPayoutCVL model the solvency proofs rely on; launch it via
#     run-eq-combinatorial-payout-grouped.sh (two heavy rules isolated + the rest grouped). Not a
#     solvency conf, so it is not launched here.
#
# Usage: certora/scripts/run-solvency-combinatorial-all.sh   (from the activated .venv)
# Each certoraRun submits a separate job (the confs have wait_for_results: none), so all jobs are
# launched back-to-back and run in parallel on the server; follow them on the prover dashboard.
# Append --wait_for_results all to the certoraRun calls if you want each to block on its verdict.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Confs launched whole (one job each).
CONFS=(
    "CombinatorialWellFormed"      # Phase 0    — storedConjunctionsWellFormed invariant
    "CombinatorialCanonical"       # Phase 0.5  — storedConjunctionsCanonical invariant
    "CombinatorialLegStore"        # COMBI-SL-FIX-1/2/3 — mismatch revert, unique writer, immutability
    "CombinatorialRefineForward"   # splitOnCondition / extract / convertToYesBasket (per-omega)
    "CombinatorialRefineInverse"   # mergeOnCondition / inject / mergeFromYesBasket (bounded dust)
    "CombinatorialRefineWrap"      # wrap / unwrap (exact value equality)
    "CombinatorialRoundTrip"       # forward-then-inverse pairs (value neutral, no dust)
    "CombinatorialRefineCompress"  # compress (residual + all-resolved)
    "CombinatorialModule"          # collateral neutrality of the position-only transforms
)

for name in "${CONFS[@]}"; do
    echo "[*] launching $name"
    certoraRun "certora/confs/solvency/${name}.conf" \
        --msg "Combinatorial solvency suite: $name" \
        --server production
done

# split / merge / redeem: one job per method via the dedicated runner (must not share a job).
echo "[*] delegating split/merge/redeem to run-solvency-combinatorial-redeem-per-method.sh"
"$HERE/run-solvency-combinatorial-redeem-per-method.sh"