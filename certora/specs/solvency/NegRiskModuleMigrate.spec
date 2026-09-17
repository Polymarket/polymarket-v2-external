// Dedicated solvency rules for migratePositions(bytes32[],uint256[],uint256[]).
//
// Proof is partitioned into four rules:
//   * solvencyPreservedMigrateLengthSmallerOrEqualThan1         — length <= 1;
//   * solvencyPreservedMigrateSameCondition  — length == 2, both legacy ids mapping to
//     one structured condition (the YES+NO mergeable pair);
//   * solvencyPreservedMigrateSameEvent      — length == 2, two DIFFERENT conditions of
//     one event (NegRisk-only case: the two supplies couple through the same
//     (D − S)·max term);
//   * solvencyPreservedMigrateDistinctEvents — length == 2, two distinct events.
// The union covers exactly length <= 2

/*
 * MODULE
 * @module NegRiskModule Global Solvency
 * @contract NegRiskModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 * GLOBAL ASSUMPTIONS
 * @global_assumption Loops are unrolled to between 3 and 5 iterations, stated per rule where it is not the upper bound
 * @global_assumption The legacy condition-id helpers are summarized in CVL
 * @global_assumption PositionManager mint, burn and transfer are replaced by an equivalent CVL model
 *
 * PROPERTIES
 * @property NEGRISK-GLOB-SOLVENCY NegRiskModule preserves the collateral backing of every outstanding position it has minted, under every possible market resolution.
 */

import "NegRiskSolvencyBase.spec";

methods {
    function NegRiskModule.migrationCondKeyOf(bytes32) external returns (uint256) envfree;
}

// Shared pre-state snapshot requires + call + stones.
function migrateAndCheckStones(env e, bytes32[] a, uint256[] b, uint256[] c) {
    requireVaultSeparation();

    mathint assetsBefore = countedAssets();
    mathint pusdBefore = ghostPusdSupply;
    mathint liabBefore = liabilityScaled;
    require RESULT_DENOMINATOR() * assetsBefore >= RESULT_DENOMINATOR() * pusdBefore + liabBefore,
        "solvency holds before";

    NegRiskModule.migratePositions(e, a, b, c);

    // On surviving (non-reverting) paths the contract has validated b.length == a.length
    // == c.length, so the guarded reads below are in-bounds.
    mathint minted = (a.length > 0 ? to_mathint(c[0]) : 0) + (a.length > 1 ? to_mathint(c[1]) : 0);

    // (1) migratePositions never mints or burns pUSD.
    assert ghostPusdSupply == pusdBefore,
        "migratePositions must not change the pUSD supply";
    // (2) The nonlinear kernel, isolated: minting amount_i on one leg moves the scaled
    //     liability by at most D·amount_i (YES leg: linear coeff <= D plus (D − S) <= D
    //     on the max term; NO leg: (D − coeff) <= D and the max term never increases).
    assert liabilityScaled - liabBefore <= RESULT_DENOMINATOR() * minted,
        "scaled liability may grow by at most D times the minted amounts";
    // (3) The legacy pull credits the counted CT reserve by exactly the minted amounts;
    //     nothing else leaves the counted set.
    assert countedAssets() - assetsBefore >= minted,
        "counted assets grow by at least the pulled backing";
    // (4) Linear given (1)-(3) and the pre-state inequality.
    assert solvencyScaledHolds(),
        "migratePositions broke D*(vault+reserve) >= D*pUSD totalSupply + scaled liability";
}

/**
 * @title solvency preserved, neg-risk migrate, at most one element
 * @description migratePositions preserves the backing inequality for batches of at most one element.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Case split covering batches of at most one element
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/9f419236f990477a941144b5ab5cfecb?anonymousKey=0c8addd732e955554fd40a571b31a0a79330be95
 */
rule solvencyPreservedMigrateLengthSmallerOrEqualThan1(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length <= 1;
    migrateAndCheckStones(e, a, b, c);
}

/**
 * @title solvency preserved, neg-risk migrate, one condition
 * @description migratePositions preserves the backing inequality when both elements map to one structured condition.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Case split covering two elements mapping to one structured condition, the complementary pair the non-strict input ordering admits
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/547d2b4c93ed4f06a03c633807d31dee?anonymousKey=1cff41b44b43cee8133c50d0b09c8c1e6c22834f
 */
rule solvencyPreservedMigrateSameCondition(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length == 2;
    require NegRiskModule.migrationCondKeyOf(a[0]) == NegRiskModule.migrationCondKeyOf(a[1]);
    migrateAndCheckStones(e, a, b, c);
}

/**
 * @title solvency preserved, neg-risk migrate, one event
 * @description migratePositions preserves the backing inequality when the two elements sit on different conditions of one event.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Case split covering two elements on different conditions of one event, whose supplies couple through the shared event term
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/18d851931231476d8fce3c6b0df6ab62?anonymousKey=a7dd9222c9542f9f5493c3fe72b9f559894f1922
 */
rule solvencyPreservedMigrateSameEvent(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length == 2;
    require NegRiskModule.migrationCondKeyOf(a[0]) != NegRiskModule.migrationCondKeyOf(a[1]);
    require eventBaseOf(NegRiskModule.migrationCondKeyOf(a[0]))
        == eventBaseOf(NegRiskModule.migrationCondKeyOf(a[1]));
    migrateAndCheckStones(e, a, b, c);
}

/**
 * @title solvency preserved, neg-risk migrate, distinct events
 * @description migratePositions preserves the backing inequality when the two elements sit on distinct events.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Case split covering two elements on distinct events
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/24614704b8c04d539db1cec80b73bef7?anonymousKey=f9202129601dcdd4ae0c9afab74088bf00dd0914
 */
rule solvencyPreservedMigrateDistinctEvents(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length == 2;
    require eventBaseOf(NegRiskModule.migrationCondKeyOf(a[0]))
        != eventBaseOf(NegRiskModule.migrationCondKeyOf(a[1]));
    migrateAndCheckStones(e, a, b, c);
}