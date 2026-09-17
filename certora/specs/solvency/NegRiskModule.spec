
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

// ------------------------------------------------------------
// Solvency
//
// Compared SCALED by D (= RESULT_DENOMINATOR): D·assets >= D·pUSD + liabilityScaled, where
// liabilityScaled = D · Σ_events eventLiability(E). The scaling removes integer-division
// rounding from the spec entirely.
// ------------------------------------------------------------

/**
 * @title solvency preserved
 * @description NegRiskModule preserves the backing inequality between counted assets and the sum of pUSD supply and per-event worst-case liability.
 * @link_property NEGRISK-GLOB-SOLVENCY
 * @assumption Verified with loops unrolled to at most 3 iterations
 * @status VERIFIED
 * @report https://prover.certora.com/output/10505052/c0bf9ed7378248989450955e8b019a38?anonymousKey=ebb6f892838a1de5bef92e91c6ac69b47959806d
 */
rule solvencyPreserved(env e, method f, calldataarg args)
filtered {
    f -> !f.isView
        && f.selector != sig:NegRiskModule.mintFromBridge(address,NegRiskModule.PositionId,uint256).selector
        && f.selector != sig:NegRiskModule.burnFromBridge(NegRiskModule.PositionId[],uint256[]).selector
        // Covered in dedicated specs
        && f.selector != sig:NegRiskModule.convert(address,NegRiskModule.EventId,uint256,uint256).selector
        && f.selector != sig:NegRiskModule.migratePositions(bytes32[],uint256[],uint256[]).selector
        && f.selector != sig:NegRiskModule.migratePositions(address,bytes32[],uint256[],uint256[]).selector
} {
    address usdc = CollateralToken.USDC();
    address usdce = CollateralToken.USDCE();
    address vault = CollateralToken.VAULT();
    require usdc != usdce, "deployment: USDC and USDCe are distinct tokens";

    mathint assetsBefore = balanceByToken[usdc][vault] + balanceByToken[usdce][vault]
        + balanceByToken[usdce][ConditionalTokens];
    mathint liabBefore = RESULT_DENOMINATOR() * ghostPusdSupply + liabilityScaled;
    require RESULT_DENOMINATOR() * assetsBefore >= liabBefore, "solvency holds before";

    f(e, args);

    mathint assetsAfter = balanceByToken[usdc][vault] + balanceByToken[usdce][vault]
        + balanceByToken[usdce][ConditionalTokens];
    mathint liabAfter = RESULT_DENOMINATOR() * ghostPusdSupply + liabilityScaled;
    assert RESULT_DENOMINATOR() * assetsAfter >= liabAfter,
        "method broke D*(vault+reserve) >= D*pUSD totalSupply + scaled liability";
}
