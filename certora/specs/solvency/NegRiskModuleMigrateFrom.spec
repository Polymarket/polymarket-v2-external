// Dedicated solvency rules for migratePositions(address,bytes32[],uint256[],uint256[]).
//
// Same aliasing case-split + stepping-stone decomposition as NegRiskModuleMigrate.spec

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
function migrateFromAndCheckStones(env e, address from, bytes32[] a, uint256[] b, uint256[] c) {
    requireVaultSeparation();

    mathint assetsBefore = countedAssets();
    mathint pusdBefore = ghostPusdSupply;
    mathint liabBefore = liabilityScaled;
    require RESULT_DENOMINATOR() * assetsBefore >= RESULT_DENOMINATOR() * pusdBefore + liabBefore,
        "solvency holds before";

    NegRiskModule.migratePositions(e, from, a, b, c);

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
 * @title solvency preserved, neg-risk migrate from, at most one element
 * @description The delegated migratePositions preserves the backing inequality for batches of at most one element.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Case split covering batches of at most one element
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/5fcda9811f734d9999397ef1369f0614?anonymousKey=242a96425861684abde82a3137bf61acb68f0eff
 */
rule solvencyPreservedMigrateFromLengthSmallerOrEqualThan1(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    address from;
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length <= 1;
    migrateFromAndCheckStones(e, from, a, b, c);
}

/**
 * @title solvency preserved, neg-risk migrate from, one condition
 * @description The delegated migratePositions preserves the backing inequality when both elements map to one structured condition.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Case split covering two elements mapping to one structured condition, the complementary pair the non-strict input ordering admits
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/3c059f56c96c4fad9a5b075a685e142c?anonymousKey=2a2456899643fa201c9b6b59d94b6724ad1673ca
 */
rule solvencyPreservedMigrateFromSameCondition(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    address from;
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length == 2;
    require NegRiskModule.migrationCondKeyOf(a[0]) == NegRiskModule.migrationCondKeyOf(a[1]);
    migrateFromAndCheckStones(e, from, a, b, c);
}

/**
 * @title solvency preserved, neg-risk migrate from, one event
 * @description The delegated migratePositions preserves the backing inequality when the two elements sit on different conditions of one event.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Case split covering two elements on different conditions of one event, whose supplies couple through the shared event term
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/ed0eaf3405bb4e5db68abd5a9d3492c5?anonymousKey=fb1f7349c9e2f94818dd4256f60bd56b1d70780e
 */
rule solvencyPreservedMigrateFromSameEvent(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    address from;
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length == 2;
    require NegRiskModule.migrationCondKeyOf(a[0]) != NegRiskModule.migrationCondKeyOf(a[1]);
    require eventBaseOf(NegRiskModule.migrationCondKeyOf(a[0]))
        == eventBaseOf(NegRiskModule.migrationCondKeyOf(a[1]));
    migrateFromAndCheckStones(e, from, a, b, c);
}

/**
 * @title solvency preserved, neg-risk migrate from, distinct events
 * @description The delegated migratePositions preserves the backing inequality when the two elements sit on distinct events.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Case split covering two elements on distinct events
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/866e96fe10264ee6ac9752ca7216cfba?anonymousKey=6610b1483a8a3c226f8e1215bf12289e472e7348
 */
rule solvencyPreservedMigrateFromDistinctEvents(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    address from;
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length == 2;
    require eventBaseOf(NegRiskModule.migrationCondKeyOf(a[0]))
        != eventBaseOf(NegRiskModule.migrationCondKeyOf(a[1]));
    migrateFromAndCheckStones(e, from, a, b, c);
}