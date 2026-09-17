#!/bin/bash
# Run the CombinatorialPayoutEquivalence case-split rules one at a time, via --rule, so each
# case is its own cloud job with its own timeout budget. The spec replaces the two monolithic
# equivalence rules (which timed out) with a family of 15 case rules; launching them separately
# keeps the heavy nonlinear cores (the *_bothScaled rules) from starving the cheap cases.
#
# Usage: certora/scripts/run-eq-combinatorial-payout-per-rule.sh   (from the activated .venv)
# Each invocation submits a separate job (the conf has wait_for_results: none), so all
# jobs are launched back-to-back and run in parallel on the server.
set -u

CONF="certora/confs/eq/CombinatorialPayoutEquivalence.conf"

# All rules in certora/specs/eq/CombinatorialPayoutEquivalence.spec:
# value family (outcome x legCount x resolved-leg status), then revert-cause partition.
RULES=(
    "valueEq_yes_1Leg"
    "valueEq_no_1Leg"
    "valueEq_yes_2Legs_zeroFactor"
    "valueEq_yes_2Legs_bothFull"
    "valueEq_yes_2Legs_oneScaled"
    "valueEq_yes_2Legs_bothScaled"
    "valueEq_no_2Legs_zeroFactor"
    "valueEq_no_2Legs_bothFull"
    "valueEq_no_2Legs_oneScaled"
    "valueEq_no_2Legs_bothScaled"
    "revertEq_msgValue"
    "revertEq_invalidOutcome"
    "revertEq_unprepared"
    "revertEq_unresolved"
    "revertEq_resolvedOrZero"
)

for r in "${RULES[@]}"; do
    echo "[*] --rule \"$r\""
    certoraRun "$CONF" \
        --rule "$r" \
        --msg "EQ combinatorial payout: $r" \
        --server production
done
