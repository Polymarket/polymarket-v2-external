#!/bin/bash
# Run the CombinatorialPayoutEquivalence case-split rules in three jobs: the two heavy cases that
# need their own timeout budget (valueEq_no_1Leg, valueEq_no_2Legs_oneScaled) each get a dedicated
# cloud job, and all remaining rules run together in a single job (one certoraRun with repeated
# --rule flags). This is the middle ground between run-eq-combinatorial-payout-per-rule.sh (one job
# per rule) and launching the whole conf at once: the cheap cases share a job, the two expensive
# ones don't starve them.
#
# Usage: certora/scripts/run-eq-combinatorial-payout-grouped.sh   (from the activated .venv)
# Each certoraRun submits a separate job (the conf has wait_for_results: none), so the three
# jobs are launched back-to-back and run in parallel on the server.
set -u

CONF="certora/confs/eq/CombinatorialPayoutEquivalence.conf"

# Isolated: each runs on its own so its timeout budget is not shared with the cheap cases.
ISOLATED=(
    "valueEq_no_1Leg"
    "valueEq_no_2Legs_oneScaled"
)

# Everything else, run together in one job.
REST=(
    "valueEq_yes_1Leg"
    "valueEq_yes_2Legs_zeroFactor"
    "valueEq_yes_2Legs_bothFull"
    "valueEq_yes_2Legs_oneScaled"
    "valueEq_yes_2Legs_bothScaled"
    "valueEq_no_2Legs_zeroFactor"
    "valueEq_no_2Legs_bothFull"
    "valueEq_no_2Legs_bothScaled"
    "revertEq_msgValue"
    "revertEq_invalidOutcome"
    "revertEq_unprepared"
    "revertEq_unresolved"
    "revertEq_resolvedOrZero"
    "payoutGateYes"
    "payoutGateNo"
)

# --- isolated jobs (one --rule each) ---
for r in "${ISOLATED[@]}"; do
    echo "[*] isolated --rule \"$r\""
    certoraRun "$CONF" \
        --rule "$r" \
        --msg "EQ combinatorial payout isolated: $r" \
        --server production
done

# --- grouped job (all remaining rules together) ---
RULE_ARGS=()
for r in "${REST[@]}"; do
    RULE_ARGS+=(--rule "$r")
done
echo "[*] grouped: ${#REST[@]} rules in one job"
certoraRun "$CONF" \
    "${RULE_ARGS[@]}" \
    --msg "EQ combinatorial payout grouped: remaining rules" \
    --server production