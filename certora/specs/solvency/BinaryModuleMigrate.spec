// Dedicated solvency rules for the heavy migratePositions(bytes32[],uint256[],uint256[])
//
// Proof partitioned into three rules:
//   * solvencyPreservedLengthSmallerOrEqualThan1            — length <= 1;
//   * solvencyPreservedSameCondition     — length == 2, both elements on ONE structured condition
//   * solvencyPreservedDistinctConditions — length == 2, two distinct conditions.
// The union covers exactly length <= 2.

/*
 * MODULE
 * @module BinaryModule Global Solvency
 * @contract BinaryModule
 * @impact Holders could redeem more collateral than the module ever took in, leaving outstanding positions unbacked
 *
 * PROPERTIES
 * @property BINARY-GLOB-SOLVENCY BinaryModule preserves the collateral backing of every outstanding position it has minted, under every possible market resolution.
 */

import "BinarySolvencyBase.spec";

methods {
    function BinaryModule.getMigrationConditionId(bytes32) external returns (bytes32) envfree;
}

// The counted asset side of solvencyPreserved:
// vault_USDC + vault_USDCe + USDCe.bal(ConditionalTokens).
function countedAssets() returns mathint {
    address usdc = CollateralToken.USDC();
    address usdce = CollateralToken.USDCE();
    address vault = CollateralToken.VAULT();
    return balanceByToken[usdc][vault] + balanceByToken[usdce][vault]
        + balanceByToken[usdce][ConditionalTokens];
}

// The headline inequality: counted assets >= pUSD.totalSupply() + Σ_all_C liability(C).
function solvencyInequalityHolds() returns bool {
    return countedAssets() >= ghostPusdSupply + liabilityTotal;
}

/**
 * @title solvency preserved, binary migrate, at most one element
 * @description migratePositions preserves the backing inequality for batches of at most one element.
 * @link_property BINARY-GLOB-SOLVENCY
 * @assumption Case split covering batches of at most one element
 * @assumption Verified with loops unrolled to at most 2 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/99049f3c09c247d7b2a91d81c8c1b41a?anonymousKey=e2dbdff32ed0897edc534897e394bb27a5a501ab
 */
rule solvencyPreservedLengthSmallerOrEqualThan1(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length <= 1;
    require solvencyInequalityHolds(), "solvency holds before";

    BinaryModule.migratePositions(e, a, b, c);

    assert solvencyInequalityHolds(),
        "migratePositions broke vault+reserve >= pUSD totalSupply + liability";
}

/**
 * @title solvency preserved, binary migrate, one condition
 * @description migratePositions preserves the backing inequality when both elements resolve to one condition.
 * @link_property BINARY-GLOB-SOLVENCY
 * @assumption Case split covering two elements resolving to one condition
 * @assumption Verified with loops unrolled to at most 2 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/b34c99995bef4ec8a2c53598fddd4e3f?anonymousKey=1c626bd92e644eabe74d23b794aa0865e5ec1034
 */
rule solvencyPreservedSameCondition(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length == 2;
    require BinaryModule.getMigrationConditionId(a[0]) == BinaryModule.getMigrationConditionId(a[1]);

    mathint assetsBefore = countedAssets();
    mathint pusdBefore = ghostPusdSupply;
    mathint liabTotalBefore = liabilityTotal;
    require assetsBefore >= pusdBefore + liabTotalBefore, "solvency holds before";

    BinaryModule.migratePositions(e, a, b, c);

    mathint minted = c[0] + c[1];
    // (1) migratePositions never mints or burns pUSD.
    assert ghostPusdSupply == pusdBefore,
        "migratePositions must not change the pUSD supply";
    // (2) Minting amount_i to YES/NO raises the condition's liability by at most amount_i 
    assert liabilityTotal - liabTotalBefore <= minted,
        "liability may grow by at most the minted amounts";
    // (3) The legacy pull credits the counted CT reserve by exactly the minted amounts;
    assert countedAssets() - assetsBefore >= minted,
        "counted assets grow by at least the pulled backing";
    // (4) Linear given (1)-(3) and the pre-state inequality.
    assert solvencyInequalityHolds(),
        "migratePositions broke vault+reserve >= pUSD totalSupply + liability";
}

/**
 * @title solvency preserved, binary migrate, distinct conditions
 * @description migratePositions preserves the backing inequality when the two elements resolve to distinct conditions.
 * @link_property BINARY-GLOB-SOLVENCY
 * @assumption Case split covering two elements resolving to distinct conditions
 * @assumption Verified with loops unrolled to at most 2 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/b0c39556d464455d9afaca637aaa7ca4?anonymousKey=9f11a04f1e150226ae99c3ab765298abdeaa971a
 */
rule solvencyPreservedDistinctConditions(env e) {
    require CollateralToken.USDC() != CollateralToken.USDCE(),
        "deployment: USDC and USDCe are distinct tokens";
    bytes32[] a;
    uint256[] b;
    uint256[] c;
    require a.length == 2;
    require BinaryModule.getMigrationConditionId(a[0]) != BinaryModule.getMigrationConditionId(a[1]);
    require solvencyInequalityHolds(), "solvency holds before";

    BinaryModule.migratePositions(e, a, b, c);

    assert solvencyInequalityHolds(),
        "migratePositions broke vault+reserve >= pUSD totalSupply + liability";
}
